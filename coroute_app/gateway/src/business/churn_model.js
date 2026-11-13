'use strict';
/**
 * Round 6 business brain: the churn warning score (docs/intelligence/BUSINESS_ANALYTICS.md).
 *
 * Two parts, both small and transparent:
 *
 *  1. RULES (always on). Points for plain facts the owner can read: days since the last ride, riding less than
 *     before, a plan that ends soon or has ended, days since the app was last opened. 0-100, and every score comes
 *     with the rules that produced it ("top factors").
 *
 *  2. A small LOGISTIC REGRESSION in pure JS (like the crash brain, src/intel/crash_brain.js), used only when there
 *     is enough history: at least MIN_SAMPLES riders with both outcomes and a held-out AUC of MIN_AUC or better.
 *     It is trained from the riders' own past: "what did a rider look like 28 days ago, and did they ride in the
 *     28 days since?". Inputs are ride counts and dates only (no position, no speed, no personal text).
 *     When it is in use the list shows its probability next to the rule score, with the inputs that pushed it up.
 *
 * Pure functions; bounded work: at most MAX_SAMPLES rows, ITER passes, FEATURES.length weights.
 */
const DAY = 86400000;

const FEATURES = Object.freeze(['recencyDays', 'rideDays30', 'rideDaysPrev60', 'tenureWeeks', 'groupShare']);
/** Plain words for one input of one rider (shown as a "top factor" when it pushed the probability up). */
const FEATURE_LABEL = Object.freeze({
  recencyDays: (v) => `No ride for ${v} days`,
  rideDays30: (v) => `${v} ride ${v === 1 ? 'day' : 'days'} in the last 30 days`,
  rideDaysPrev60: (v) => `${v} ride ${v === 1 ? 'day' : 'days'} in the 60 days before`,
  tenureWeeks: (v) => `Joined ${v} weeks ago`,
  groupShare: (v) => `${Math.round(v * 100)}% of rides in a group`,
});
const MIN_SAMPLES = 200;
const MIN_PER_CLASS = 30;
const MIN_AUC = 0.65;
const MAX_SAMPLES = 5000;
const ITER = 300;
const LR = 0.3;
const L2 = 0.001;
const HORIZON_DAYS = 28;

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const sigmoid = (z) => 1 / (1 + Math.exp(-clamp(z, -30, 30)));

/**
 * The features of one rider at time `at`, from their ride days (epoch-day numbers, any order).
 * Returns null when the rider had no ride in the 90 days before `at` (not an active rider then).
 */
function featuresAt(rideDays, at, { createdAt = 0, groupDays = null } = {}) {
  const today = Math.floor(at / DAY);
  let last = -1; let d30 = 0; let prev60 = 0; let group = 0; let seen = 0;
  for (const d of rideDays) {
    if (d >= today) continue;
    const age = today - d;
    if (age > 90) continue;
    seen++;
    if (d > last) last = d;
    if (age <= 30) d30++; else prev60++;
    if (groupDays && groupDays.has(d)) group++;
  }
  if (last < 0) return null;
  return {
    recencyDays: clamp(today - last, 0, 90),
    rideDays30: Math.min(d30, 30),
    rideDaysPrev60: Math.min(prev60, 60),
    tenureWeeks: createdAt > 0 ? clamp(Math.floor((at - createdAt) / (7 * DAY)), 0, 260) : 26,
    groupShare: seen ? Math.round((group / seen) * 100) / 100 : 0,
  };
}

/** One training row for a rider: the features 28 days ago and whether they stayed away since (1 = churned). */
function sampleOf(rideDays, now, opts = {}) {
  const t0 = now - HORIZON_DAYS * DAY;
  const f = featuresAt(rideDays, t0, opts);
  if (!f) return null;
  const from = Math.floor(t0 / DAY);
  const to = Math.floor(now / DAY);
  let rodeSince = false;
  for (const d of rideDays) if (d >= from && d <= to) { rodeSince = true; break; }
  return { f, y: rodeSince ? 0 : 1 };
}

function scaler(rows) {
  const mean = {}; const sd = {};
  for (const k of FEATURES) {
    let s = 0; for (const r of rows) s += r.f[k];
    mean[k] = rows.length ? s / rows.length : 0;
    let v = 0; for (const r of rows) v += (r.f[k] - mean[k]) ** 2;
    sd[k] = Math.sqrt(rows.length ? v / rows.length : 0) || 1;
  }
  return { mean, sd };
}
const zOf = (f, sc) => FEATURES.map((k) => (Number(f[k] || 0) - sc.mean[k]) / sc.sd[k]);

/** Area under the ROC curve of scores against 0/1 labels (rank based; ties count half). */
function auc(scores, labels) {
  const idx = scores.map((s, i) => i).sort((a, b) => scores[a] - scores[b]);
  let pos = 0; let neg = 0; let rankSum = 0;
  for (let i = 0; i < idx.length;) {
    let j = i;
    while (j < idx.length && scores[idx[j]] === scores[idx[i]]) j++;
    const avg = (i + 1 + j) / 2;
    for (let k = i; k < j; k++) { if (labels[idx[k]] === 1) { pos++; rankSum += avg; } else neg++; }
    i = j;
  }
  if (!pos || !neg) return 0.5;
  return (rankSum - (pos * (pos + 1)) / 2) / (pos * neg);
}

/**
 * Trains on rows [{ f, y }]. Every 5th row (by position) is held out for the AUC. Returns
 * { ok, reason?, n, churned, auc, w, mean, sd, trainedAt } ; ok = false when there is not enough data or the model
 * is not better than the threshold (the rules are then used alone).
 */
function train(rows, { now = Date.now(), minSamples = MIN_SAMPLES, minAuc = MIN_AUC } = {}) {
  const all = rows.slice(0, MAX_SAMPLES);
  const churned = all.filter((r) => r.y === 1).length;
  const base = { n: all.length, churned, trainedAt: now };
  if (all.length < minSamples) return { ok: false, reason: `Needs ${minSamples} riders with history; has ${all.length}.`, ...base };
  if (churned < MIN_PER_CLASS || all.length - churned < MIN_PER_CLASS) return { ok: false, reason: 'Needs at least 30 riders who stayed and 30 who left.', ...base };
  const fit = all.filter((_, i) => i % 5 !== 0);
  const held = all.filter((_, i) => i % 5 === 0);
  const sc = scaler(fit);
  const X = fit.map((r) => zOf(r.f, sc));
  const d = FEATURES.length;
  const w = new Array(d + 1).fill(0);
  for (let it = 0; it < ITER; it++) {
    const g = new Array(d + 1).fill(0);
    for (let i = 0; i < X.length; i++) {
      let z = w[0];
      for (let j = 0; j < d; j++) z += w[j + 1] * X[i][j];
      const e = sigmoid(z) - fit[i].y;
      g[0] += e;
      for (let j = 0; j < d; j++) g[j + 1] += e * X[i][j];
    }
    w[0] -= (LR * g[0]) / X.length;
    for (let j = 0; j < d; j++) w[j + 1] -= LR * (g[j + 1] / X.length + L2 * w[j + 1]);
  }
  const model = { w: w.map((x) => Math.round(x * 1e5) / 1e5), mean: sc.mean, sd: sc.sd };
  const a = auc(held.map((r) => predict(model, r.f).p), held.map((r) => r.y));
  const out = { ...base, ...model, auc: Math.round(a * 1000) / 1000, heldOut: held.length };
  if (!(a >= minAuc)) return { ok: false, reason: `Not reliable enough yet (AUC ${out.auc}, needs ${minAuc}).`, ...out };
  return { ok: true, ...out };
}

/** { p, factors: [{ key, label, weight }] } : the probability and the inputs that pushed it up, largest first. */
function predict(model, f) {
  const z = zOf(f, model);
  let s = model.w[0];
  const parts = [];
  for (let j = 0; j < FEATURES.length; j++) { const c = model.w[j + 1] * z[j]; s += c; parts.push({ key: FEATURES[j], label: FEATURE_LABEL[FEATURES[j]](Number(f[FEATURES[j]] || 0)), weight: Math.round(c * 100) / 100 }); }
  return { p: sigmoid(s), factors: parts.filter((x) => x.weight > 0.05).sort((a, b) => b.weight - a.weight).slice(0, 3) };
}

/**
 * The rule score of one rider now. `r`: { lastRideAt, rideDays30, rideDaysPrev60, everRode, planEndsAt (0 = no paid
 * plan), planEndedAt (0 = none ended recently), lastOpenAt }. Returns { score 0-100, factors: [{ key, label, points }] }.
 */
function ruleScore(r, now = Date.now()) {
  const factors = [];
  const add = (key, points, label) => factors.push({ key, points, label });
  const days = (t) => (t > 0 ? Math.floor((now - t) / DAY) : null);
  const since = days(r.lastRideAt);
  if (since !== null) {
    if (since > 60) add('recency', 40, `No ride for ${since} days`);
    else if (since > 30) add('recency', 30, `No ride for ${since} days`);
    else if (since > 14) add('recency', 15, `No ride for ${since} days`);
  }
  const prevAvg = (Number(r.rideDaysPrev60) || 0) / 2;
  const d30 = Number(r.rideDays30) || 0;
  if (prevAvg >= 1 && d30 === 0) add('frequency', 25, `Rode about ${Math.round(prevAvg)} days a month before, none in the last 30 days`);
  else if (prevAvg >= 1 && d30 <= prevAvg / 2) add('frequency', 20, `Riding less: ${d30} ride days in 30 days, about ${Math.round(prevAvg)} a month before`);
  const ends = Number(r.planEndsAt) || 0;
  const ended = Number(r.planEndedAt) || 0;
  if (ends > now && ends - now <= 14 * DAY) add('plan', 15, `Plan ends in ${Math.max(1, Math.ceil((ends - now) / DAY))} days`);
  else if (ended > 0 && now - ended <= 30 * DAY) add('plan', 20, `Plan ended ${Math.max(1, days(ended))} days ago and was not renewed`);
  const open = days(r.lastOpenAt);
  if (open !== null) {
    if (open > 30) add('app', 20, `App not opened for ${open} days`);
    else if (open > 14) add('app', 10, `App not opened for ${open} days`);
  }
  factors.sort((a, b) => b.points - a.points);
  return { score: Math.min(100, factors.reduce((s, f) => s + f.points, 0)), factors };
}

module.exports = { FEATURES, FEATURE_LABEL, MIN_SAMPLES, MIN_AUC, MAX_SAMPLES, HORIZON_DAYS, featuresAt, sampleOf, train, predict, auc, ruleScore };
