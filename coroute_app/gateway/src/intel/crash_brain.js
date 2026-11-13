'use strict';
/**
 * Crash brain (feature 14): fewer false crash alarms, learned from labelled alarms. Own code, pure JS, deterministic.
 *
 * Data: one row per crash alarm of a consenting rider (features, no position, no identity in the training copy):
 *   pg peak g, dur impact ms, v pre-impact km/h, still post-impact stillness s, rot rotation (rad/s), mount
 *   ('mounted'|'pocket'|'loose'|'unknown'), path ('impact'|'highside'|'slide'|'lowfall'|'riderdown'|'external'),
 *   thr the raw impact threshold in effect (g), dm device model.
 * Label: 1 = real crash (SOS sent and never marked false, or the rider said "yes, it was real"),
 *        0 = false alarm ("I'm OK" within the countdown, or later marked false). Unlabelled rows are skipped.
 *
 * Training (nightly, leased): logistic regression per device-model group with ≥ minLabels (200) rows, else the global
 * model (≥ 200 rows), else nothing. Batch gradient descent from zero weights, fixed iterations: same data → same model.
 * Held-out: every 5th row by a stable hash of its id.
 *
 * SAFETY RULES (enforced here AND in the app; tested in test/intel_crash_brain_356.test.js):
 *   - suggestion = a multiplier of the raw high-impact threshold only, in [SCALE_MIN, SCALE_MAX] = [1.0, 1.15]
 *     (never above default × 1.15); the severe-impact fast path, the slide / low-speed / high-side paths and the
 *     countdown are never touched (the countdown is never skipped);
 *   - a scale is only suggested when it would have missed NO labelled real crash (all data) with a 5 % margin;
 *   - ≥ 200 labelled alarms in the group (global fallback) before anything is suggested;
 *   - shadow by default: suggestions are logged only; the app gets params only when CRASH_BRAIN_MODE=approved AND a
 *     MASTER_ADMIN approved that version; rollback restores the previous approval (or none = defaults).
 */
const crypto = require('crypto');

const SCALE_MIN = 1.0;
const SCALE_MAX = 1.15; // hard safety floor: never raise the impact threshold above default × 1.15
const APP_SCALE_MIN = 0.9; // what the app accepts (more sensitive is always allowed)
const GRID = [1.0, 1.025, 1.05, 1.075, 1.1, 1.125, 1.15];
const MARGIN = 1.05;
const ITER = 600;
const LR = 0.5;
const L2 = 1e-3;
const FEATURES = ['pg', 'dur', 'v', 'still', 'rot', 'pocket', 'unknownMount'];

function clampScale(s) {
  const v = Number(s);
  if (!Number.isFinite(v)) return 1;
  return Math.min(SCALE_MAX, Math.max(APP_SCALE_MIN, v));
}

/** Device model group: the maker family, lower case ('samsung', 'xiaomi', ...) or 'other'. */
function modelGroup(dm) {
  const s = String(dm || '').trim().toLowerCase();
  if (!s) return 'other';
  const w = s.split(/[\s_-]+/)[0].replace(/[^a-z0-9]/g, '');
  const alias = { redmi: 'xiaomi', poco: 'xiaomi', mi: 'xiaomi', iqoo: 'vivo', realme: 'realme', oneplus: 'oneplus', google: 'google', pixel: 'google', sm: 'samsung', galaxy: 'samsung' };
  return (alias[w] || w || 'other').slice(0, 24);
}

/** Cleans one feature row from the app; null when unusable. */
function cleanFeatures(f) {
  if (!f || typeof f !== 'object') return null;
  const n = (v, lo, hi) => { const x = Number(v); return Number.isFinite(x) ? Math.min(hi, Math.max(lo, x)) : null; };
  const pg = n(f.pg, 0, 50);
  if (pg === null) return null;
  const mounts = ['mounted', 'pocket', 'loose', 'unknown'];
  const paths = ['impact', 'highside', 'slide', 'lowfall', 'riderdown', 'external', 'unknown'];
  return {
    pg, dur: n(f.dur, 0, 5000) ?? 0, v: n(f.v, 0, 250) ?? 0, still: n(f.still, 0, 600) ?? 0, rot: n(f.rot, 0, 50) ?? 0,
    mount: mounts.includes(f.mount) ? f.mount : 'unknown', path: paths.includes(f.path) ? f.path : 'unknown',
    thr: n(f.thr, 1, 20) ?? 4.0, dm: String(f.dm || '').slice(0, 40), sev: f.sev === true,
  };
}

/** 1 real, 0 false, null unknown. */
function labelOf(outcome, feedback) {
  if (feedback === 'false') return 0;
  if (feedback === 'real') return 1;
  if (outcome === 'ok') return 0;
  if (outcome === 'sent') return 1;
  return null;
}

function vec(f) {
  return [f.pg / 10, f.dur / 500, f.v / 100, f.still / 60, f.rot / 10, f.mount === 'pocket' || f.mount === 'loose' ? 1 : 0, f.mount === 'unknown' ? 1 : 0];
}

const sigmoid = (z) => 1 / (1 + Math.exp(-Math.max(-30, Math.min(30, z))));

/** Logistic regression by batch gradient descent: { w: [bias, ...weights] }. Deterministic. */
function train(rows) {
  const X = rows.map((r) => vec(r.f));
  const y = rows.map((r) => r.y);
  const d = FEATURES.length;
  const w = new Array(d + 1).fill(0);
  const n = X.length || 1;
  for (let it = 0; it < ITER; it++) {
    const g = new Array(d + 1).fill(0);
    for (let i = 0; i < X.length; i++) {
      let z = w[0];
      for (let j = 0; j < d; j++) z += w[j + 1] * X[i][j];
      const e = sigmoid(z) - y[i];
      g[0] += e;
      for (let j = 0; j < d; j++) g[j + 1] += e * X[i][j];
    }
    w[0] -= (LR * g[0]) / n;
    for (let j = 0; j < d; j++) w[j + 1] -= LR * (g[j + 1] / n + L2 * w[j + 1]);
  }
  return { w: w.map((x) => Math.round(x * 1e6) / 1e6) };
}

function predict(model, f) {
  const x = vec(f);
  let z = model.w[0];
  for (let j = 0; j < x.length; j++) z += model.w[j + 1] * x[j];
  return sigmoid(z);
}

function heldOut(id) { return crypto.createHash('sha1').update(String(id)).digest()[0] % 5 === 0; }

/** Would this alarm still fire with the impact threshold scaled by s? Only the plain high-impact path is affected. */
function stillFires(f, s) {
  if (f.path !== 'impact' || f.sev) return true;
  return f.pg >= f.thr * s;
}

function confusion(model, rows) {
  const m = { tp: 0, fp: 0, tn: 0, fn: 0 };
  for (const r of rows) {
    const p = predict(model, r.f) >= 0.5 ? 1 : 0;
    if (p === 1 && r.y === 1) m.tp++; else if (p === 1) m.fp++; else if (r.y === 0) m.tn++; else m.fn++;
  }
  return m;
}

/** The largest grid scale that misses no labelled real crash (with margin) and avoids at least one false alarm. */
function suggestScale(rows) {
  const real = rows.filter((r) => r.y === 1 && r.f.path === 'impact' && !r.f.sev);
  let best = 1.0;
  for (const s of GRID) {
    if (real.some((r) => r.f.pg < r.f.thr * s * MARGIN)) break; // grid ascends: a bigger scale misses at least as much
    const avoided = rows.filter((r) => r.y === 0 && !stillFires(r.f, s)).length;
    if (avoided > 0) best = s;
  }
  return Math.min(SCALE_MAX, Math.max(SCALE_MIN, best));
}

function falseAlarmRate(rows, s) {
  const fired = rows.filter((r) => stillFires(r.f, s));
  if (!fired.length) return null;
  return Math.round((fired.filter((r) => r.y === 0).length / fired.length) * 1000) / 1000;
}

/**
 * Trains every group. rows: [{ id, f, y, g }]. Returns { groups: {g: result}, global: result|null } where a result is
 * { n, ready, suggestion|null, model, metrics } and ready = n ≥ minLabels.
 */
function trainAll(rows, { minLabels = 200 } = {}) {
  const min = Math.max(200, minLabels);
  const labelled = rows.filter((r) => r && r.f && (r.y === 0 || r.y === 1)).sort((a, b) => String(a.id).localeCompare(String(b.id)));
  const one = (list) => {
    const n = list.length;
    if (n < min) return { n, ready: false, suggestion: null, model: null, metrics: null };
    const test = list.filter((r) => heldOut(r.id));
    const trainSet = list.filter((r) => !heldOut(r.id));
    const model = train(trainSet.length ? trainSet : list);
    const scale = suggestScale(list);
    const evalSet = test.length ? test : list;
    return {
      n, ready: true, model, suggestion: { impactScale: scale },
      metrics: {
        heldOut: evalSet.length, confusion: confusion(model, evalSet),
        falseAlarmRateBefore: falseAlarmRate(evalSet, 1.0), falseAlarmRateAfter: falseAlarmRate(evalSet, scale),
        realMissed: evalSet.filter((r) => r.y === 1 && !stillFires(r.f, scale)).length,
      },
    };
  };
  const byGroup = new Map();
  for (const r of labelled) { const g = r.g || 'other'; if (!byGroup.has(g)) byGroup.set(g, []); byGroup.get(g).push(r); }
  const groups = {};
  for (const [g, list] of [...byGroup.entries()].sort()) groups[g] = one(list);
  return { global: one(labelled), groups, total: labelled.length };
}

/** The approved parameters the app may use for its group (falls back to global, then none). */
function paramsFor(approved, group) {
  if (!approved || !approved.params) return null;
  const g = approved.params.groups?.[group] || approved.params.global;
  if (!g || !Number.isFinite(g.impactScale)) return null;
  return { impactScale: clampScale(Math.min(SCALE_MAX, g.impactScale)) };
}

/** What the app verifies: sha256 of the canonical string. */
function checksum(version, group, params) {
  const s = `${version}|${group}|${params ? params.impactScale.toFixed(4) : 'none'}`;
  return crypto.createHash('sha256').update(s).digest('hex');
}

module.exports = { trainAll, train, predict, suggestScale, stillFires, cleanFeatures, labelOf, modelGroup, paramsFor, checksum, clampScale, heldOut, SCALE_MIN, SCALE_MAX, APP_SCALE_MIN, FEATURES };
