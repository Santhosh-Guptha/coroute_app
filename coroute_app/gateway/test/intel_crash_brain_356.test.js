'use strict';
/**
 * Round 4 crash brain (feature 14): deterministic training, the 200-label minimum with global fallback, the hard
 * safety floor (never above default x 1.15, never a scale that would miss a labelled real crash), shadow mode vs an
 * approved version, rollback, the app params with checksum, and the labelled data path (features, outcome, feedback).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
delete process.env.CRASH_BRAIN_MODE;
process.env.BOOTSTRAP_ADMIN_EMAILS = 'cb.admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const CB = require('../src/intel/crash_brain');
const { makeEngine, consentAll } = require('./_intel_helpers');
const { boot } = require('./_helpers');

function rng(seed) { let a = seed >>> 0; return () => { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

/** n labelled alarms: false alarms are mild impacts just over the threshold, real crashes hard impacts with stillness. */
function rows(n, { seed = 7, dm = 'samsung SM-A515F', realMin = 5.0, falseMax = 4.55 } = {}) {
  const r = rng(seed);
  const out = [];
  for (let i = 0; i < n; i++) {
    const real = r() < 0.3;
    const f = CB.cleanFeatures({ pg: real ? realMin + r() * 6 : 4.0 + r() * (falseMax - 4.0), dur: real ? 80 + r() * 200 : 10 + r() * 40, v: 20 + r() * 60,
      still: real ? 20 + r() * 40 : r() * 8, rot: real ? 2 + r() * 6 : r() * 2, mount: r() < 0.3 ? 'pocket' : 'mounted', path: 'impact', thr: 4.0, dm });
    out.push({ id: `row${seed}-${i}`, f, y: real ? 1 : 0, g: CB.modelGroup(dm) });
  }
  return out;
}

test('training is deterministic (same rows in any order give the same model)', () => {
  const data = rows(300);
  const a = CB.trainAll(data);
  const b = CB.trainAll([...data].reverse());
  assert.deepEqual(a, b);
  assert.equal(a.global.ready, true);
  assert.equal(a.global.model.w.length, CB.FEATURES.length + 1);
  // The model separates the two kinds on held-out rows.
  const m = a.global.metrics.confusion;
  assert.ok((m.tp + m.tn) / (m.tp + m.tn + m.fp + m.fn) > 0.9, JSON.stringify(m));
});

test('200 labelled alarms are needed; a small device group falls back to the global model', () => {
  assert.equal(CB.trainAll(rows(199)).global.ready, false);
  assert.equal(CB.trainAll(rows(199)).global.suggestion, null);
  assert.equal(CB.trainAll(rows(200)).global.ready, true);
  assert.equal(CB.trainAll(rows(300), { minLabels: 50 }).global.ready, true, 'never below 200 even if asked');
  assert.equal(CB.trainAll(rows(150), { minLabels: 50 }).global.ready, false);
  const mixed = [...rows(250, { dm: 'samsung A51' }), ...rows(120, { seed: 9, dm: 'Redmi Note 10' })];
  const res = CB.trainAll(mixed);
  assert.equal(res.groups.samsung.ready, true);
  assert.equal(res.groups.xiaomi.ready, false);
  const approved = { version: 3, params: { global: { impactScale: 1.1 }, groups: { samsung: { impactScale: 1.05 } } } };
  assert.deepEqual(CB.paramsFor(approved, 'xiaomi'), { impactScale: 1.1 }, 'fallback to global');
  assert.deepEqual(CB.paramsFor(approved, 'samsung'), { impactScale: 1.05 });
  assert.equal(CB.paramsFor(null, 'samsung'), null);
});

test('safety floor: never above default x 1.15, never a scale that misses a labelled real crash', () => {
  const easy = CB.trainAll(rows(300));
  assert.equal(easy.global.suggestion.impactScale, 1.15, 'clear separation: at most the cap');
  assert.equal(easy.global.metrics.realMissed, 0);
  assert.ok(easy.global.metrics.falseAlarmRateAfter < easy.global.metrics.falseAlarmRateBefore);
  // Even if every false alarm were far above the threshold, the cap holds.
  assert.ok(CB.suggestScale(rows(300, { falseMax: 9, realMin: 30 })) <= CB.SCALE_MAX);
  // A real crash at 4.3 g: any scale that would hide it (with a 5 % margin) is refused.
  const close = rows(300);
  close.push({ id: 'real-close', f: CB.cleanFeatures({ pg: 4.3, path: 'impact', thr: 4.0, still: 40 }), y: 1, g: 'samsung' });
  assert.equal(CB.suggestScale(close), 1.0);
  // Severe impacts and other paths always still alarm.
  assert.equal(CB.stillFires({ pg: 4.1, thr: 4, path: 'impact', sev: true }, 1.15), true);
  assert.equal(CB.stillFires({ pg: 2.1, thr: 4, path: 'slide' }, 1.15), true);
  assert.equal(CB.clampScale(2), 1.15);
  assert.equal(CB.clampScale(0.5), 0.9);
  assert.equal(CB.clampScale('x'), 1);
  assert.deepEqual(CB.paramsFor({ version: 1, params: { global: { impactScale: 1.5 } } }, 'x'), { impactScale: 1.15 }, 'a bad stored value is clamped');
});

test('labels: outcome and the rider\'s later answer', () => {
  assert.equal(CB.labelOf('ok'), 0);
  assert.equal(CB.labelOf('sent'), 1);
  assert.equal(CB.labelOf('sent', 'false'), 0, 'marked false later');
  assert.equal(CB.labelOf('ok', 'real'), 1, '"Was this a real crash?" yes');
  assert.equal(CB.labelOf(null), null);
  assert.equal(CB.modelGroup('Redmi Note 12 Pro'), 'xiaomi');
  assert.equal(CB.modelGroup(''), 'other');
});

test('engine: consenting riders only, feedback relabels, nightly training, shadow vs approved, rollback', async () => {
  const env = makeEngine();
  const e = env.engine;
  const feat = { pg: 4.2, dur: 20, v: 40, still: 3, rot: 0.5, mount: 'pocket', path: 'impact', thr: 4, dm: 'samsung SM-A515F' };
  assert.equal((await e.ingestCrash('nobody', { id: 'alarm-0001', features: feat, outcome: 'ok' })).reason, 'NO_CONSENT');
  await consentAll(env, ['c1']);
  assert.equal((await e.ingestCrash('c1', { id: 'bad', features: feat, outcome: 'ok' })).reason, 'INVALID');
  assert.equal((await e.ingestCrash('c1', { id: 'alarm-0001', features: feat, outcome: 'ok' })).accepted, true);
  assert.deepEqual(await e.crashFeedback('c1', { id: 'alarm-0001', real: true }), { updated: true });
  assert.equal((await e.crashFeedback('c2', { id: 'alarm-0001', real: true })).updated, false, 'only my own alarm');
  await e.aggregate();
  const copy = await env.soda.query('intel_crash_train', {}, { limit: 10 });
  assert.equal(copy.length, 1);
  assert.equal(copy[0].value.y, 1, 'the rider said it was real');
  assert.ok(!('rh' in copy[0].value) && !('t' in copy[0].value), 'the training copy is de-identified');

  // 300 labelled rows -> a suggestion; shadow mode never serves it.
  await env.soda.insertMany('intel_crash_train', rows(300).map((r) => ({ id: r.id, m: '2026-11', f: r.f, y: r.y, g: r.g })));
  await e.trainCrashBrain();
  let meta = await e._meta('crash_brain');
  assert.equal(meta.global.ready, true);
  assert.equal(meta.global.suggestion.impactScale, 1.0, 'the rider\'s real crash at 4.2 g keeps the default threshold');
  // The rider corrects the answer: not a real crash. Folded again, retrained: now the threshold may rise (capped).
  assert.deepEqual(await e.crashFeedback('c1', { id: 'alarm-0001', real: false }), { updated: true });
  await e.aggregate();
  await e.trainCrashBrain();
  meta = await e._meta('crash_brain');
  assert.equal(meta.global.suggestion.impactScale, 1.15);
  await assert.rejects(e.approveCrashBrain({ version: meta.version, by: 'a@x' }), (err) => err.code === 'SHADOW_MODE');
  let p = await e.crashParams('samsung SM-A515F');
  assert.deepEqual([p.mode, p.version, p.params], ['shadow', 0, null]);
  assert.equal(p.checksum, CB.checksum(0, 'samsung', null));

  // Shadow verdicts are logged for new alarms.
  const sh = await e.ingestCrash('c1', { id: 'alarm-0002', features: feat, outcome: 'ok' });
  assert.equal(sh.shadow.wouldStillAlarm, false, 'the suggested scale would have skipped this mild false alarm');

  process.env.CRASH_BRAIN_MODE = 'approved';
  await assert.rejects(e.approveCrashBrain({ version: meta.version + 5, by: 'a@x' }), (err) => err.code === 'VERSION_CONFLICT');
  const ap = await e.approveCrashBrain({ version: meta.version, by: 'a@x' });
  assert.equal(ap.params.groups.samsung.impactScale, 1.15);
  p = await e.crashParams('samsung SM-A515F');
  assert.deepEqual(p.params, { impactScale: 1.15 });
  assert.equal(p.version, meta.version);
  assert.equal(p.checksum, CB.checksum(meta.version, 'samsung', { impactScale: 1.15 }));
  assert.deepEqual((await e.crashParams('Nokia 5')).params, { impactScale: 1.15 }, 'unknown group: global');

  // A second training + approval, then rollback restores the first.
  await e.trainCrashBrain();
  const v2 = (await e._meta('crash_brain')).version;
  await e.approveCrashBrain({ version: v2, by: 'a@x' });
  assert.equal((await e.crashParams('samsung')).version, v2);
  await e.rollbackCrashBrain({ by: 'a@x' });
  assert.equal((await e.crashParams('samsung')).version, meta.version);
  await e.rollbackCrashBrain({ by: 'a@x' });
  assert.equal((await e.crashParams('samsung')).params, null, 'rolled back to the app defaults');
  process.env.CRASH_BRAIN_MODE = 'off';
  assert.equal((await e.crashParams('samsung')).params, null);
  delete process.env.CRASH_BRAIN_MODE;
});

test('gateway: crash params endpoint and admin crash brain page API', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown().catch(() => {}));
  const admin = await env.register('Cb Admin', 'cb.admin@coroute.test');
  const r = await env.api('GET', '/intel/crash-params?model=Pixel%207', null, admin.token);
  assert.equal(r.status, 200);
  assert.deepEqual([r.json.mode, r.json.group, r.json.params], ['shadow', 'google', null]);
  let a = await env.api('POST', '/admin/intel/crash-brain/train', {}, admin.token);
  assert.equal(a.status, 200);
  a = await env.api('GET', '/admin/intel/crash-brain', null, admin.token);
  assert.equal(a.json.mode, 'shadow');
  assert.equal(a.json.minLabels, 200);
  assert.equal(a.json.scaleMax, 1.15);
  assert.equal(a.json.brain.global.ready, false);
  a = await env.api('POST', '/admin/intel/crash-brain/approve', { version: a.json.brain.version }, admin.token);
  assert.equal(a.status, 409);
  assert.equal(a.json.code, 'SHADOW_MODE');
});
