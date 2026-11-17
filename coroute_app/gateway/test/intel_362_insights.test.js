'use strict';
/**
 * v3.62 intelligence insights (src/intel/insights.js): corridors, route difficulty, stop demand, monthly trends,
 * rider risk (aggregate with k, one rider MASTER_ADMIN + audited), and the API access rules.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'insights.admin@coroute.test';
delete process.env.INTEL_K_MIN;

const test = require('node:test');
const assert = require('node:assert/strict');
const I = require('../src/intel/insights');
const { makeEngine, ride, consentAll, move } = require('./_intel_helpers');

test('pure: difficulty levels, night share, risk buckets, corridors need k-filtered neighbouring cells', () => {
  assert.equal(I.difficultyOf({ km: 100, twistyKm: 0, ghatKm: 0, roughKm: 0, hazards: 0, nightShare: 0 }).level, 'easy');
  const hard = I.difficultyOf({ km: 200, twistyKm: 80, ghatKm: 30, roughKm: 40, hazards: 8, nightShare: 0.5 });
  assert.equal(hard.level, 'challenging');
  assert.ok(hard.reasons.length >= 3 && hard.reasons.length <= 4);
  assert.equal(I.difficultyOf({ km: 100, twistyKm: 12, ghatKm: 0, roughKm: 6, hazards: 0, nightShare: 0 }).level, 'moderate');
  const at = Date.UTC(2026, 10, 10, 14, 30); // 20:00 IST
  assert.equal(I.nightShareOf(at, 2), 1);
  assert.equal(I.nightShareOf(Date.UTC(2026, 10, 10, 4, 30), 2), 0);
  assert.equal(I.riskBucket(5, 20), null, 'under 50 km: no bucket');
  assert.equal(I.riskBucket(1, 100).bucket, 'low');
  assert.equal(I.riskBucket(4, 100).bucket, 'medium');
  assert.equal(I.riskBucket(9, 100).bucket, 'high');
  const gh = require('../src/intel/geohash');
  const cells = [];
  let p = { lat: 12.97, lng: 77.59 };
  for (let i = 0; i < 6; i++) { cells.push({ cell: gh.encode(p.lat, p.lng, 6), km: 20, riders: 6, weekend: 1, total: 2 }); p = move(p.lat, p.lng, 90, 1100); }
  cells.push({ cell: gh.encode(20, 80, 6), km: 50, riders: 6, weekend: 0, total: 1 }); // isolated
  const out = I.corridorsOf(cells);
  assert.equal(out.length, 1);
  assert.ok(out[0].cells >= 5);
  assert.equal(out[0].weekendShare, 50);
  assert.ok(out[0].path.length >= 2);
});

async function sixRiders(env, { wiggle = 35 } = {}) {
  const ids = ['r1', 'r2', 'r3', 'r4', 'r5', 'r6'];
  await consentAll(env, ids);
  for (const [i, id] of ids.entries()) {
    ride(env, { gid: `G${i}`, userId: id, legs: [{ deg: 90, km: 0.5, kmh: 40 }, { deg: 90, km: 12, kmh: 40, wiggle }, { stopMin: 20 }, { deg: 90, km: 1, kmh: 40 }] });
    env.engine.onRoomEnded(`G${i}`);
  }
  await env.engine.flushRaw();
  for (let n = 0; n < 10; n++) { const r = await env.engine.aggregate(); if (!r.folded) break; }
}

test('engine: corridors, trends, stop demand and the difficulty of a twisty line from six consenting riders', async () => {
  const env = makeEngine();
  env.engine.insights = new I.IntelInsights({ engine: env.engine, soda: env.soda, clock: () => env.clock.now });
  await env.engine.init();
  await sixRiders(env);
  const trends = await env.engine.insights.get('trends');
  const m = Object.keys(trends.months)[0];
  assert.ok(trends.months[m].km > 50, `km counted while folding: ${trends.months[m].km}`);
  const cor = await env.engine.insights.computeCorridors();
  assert.ok(cor.length >= 1, 'a corridor from the shared road');
  assert.ok(cor[0].minRiders >= 5, 'every cell seen by at least 5 riders');
  assert.ok(cor.every((c) => !('rs' in c) && !('rh' in c) && !('userId' in c)), 'no rider ids or hashes');
  const stops = await env.engine.insights.computeStopDemand();
  assert.ok(Array.isArray(stops));
  // A line along the same road.
  const line = [];
  let p = { lat: 12.9716, lng: 77.5946 };
  for (let i = 0; i < 30; i++) { line.push(p); p = move(p.lat, p.lng, 90, 450); }
  const d = await env.engine.insights.routeDifficulty(line, { departAt: Date.UTC(2026, 10, 10, 4, 30) });
  assert.ok(['easy', 'moderate', 'challenging'].includes(d.level));
  assert.ok(d.parts.twistyKm >= 1, `twisty km seen: ${JSON.stringify(d.parts)}`);
  assert.equal(d.coverage, 'riders');
  // Fewer than k riders: nothing.
  const env2 = makeEngine();
  env2.engine.insights = new I.IntelInsights({ engine: env2.engine, soda: env2.soda, clock: () => env2.clock.now });
  await consentAll(env2, ['a1', 'a2']);
  for (const [i, id] of ['a1', 'a2'].entries()) { ride(env2, { gid: `H${i}`, userId: id, legs: [{ deg: 90, km: 0.5, kmh: 40 }, { deg: 90, km: 12, kmh: 40, wiggle: 35 }] }); env2.engine.onRoomEnded(`H${i}`); }
  await env2.engine.flushRaw(); await env2.engine.aggregate();
  assert.equal((await env2.engine.insights.computeCorridors()).length, 0, 'k-anonymity: no corridor from 2 riders');
  const risk2 = await env2.engine.insights.computeRisk();
  assert.equal(risk2, 0);
  assert.equal((await env2.engine.insights.get('risk')).counts, null, 'fewer than k riders: counts hidden');
});

test('API: route difficulty for riders; insights and one-rider risk for admins only (audited)', async () => {
  const { boot } = require('./_helpers');
  const t = await boot();
  try {
    const u = await t.register('Ins Rider', 'ins.rider@coroute.test');
    const line = [{ lat: 12.97, lng: 77.59 }, { lat: 12.98, lng: 77.62 }, { lat: 13.0, lng: 77.66 }];
    const d = await t.api('POST', '/intel/route-difficulty', { points: line }, u.token);
    assert.equal(d.status, 200, JSON.stringify(d.json));
    assert.equal(d.json.level, 'easy');
    assert.equal(d.json.coverage, 'little data yet');
    assert.equal((await t.api('POST', '/intel/route-difficulty', { points: [] }, u.token)).status, 400);
    assert.equal((await t.api('GET', '/admin/intel/insights', null, u.token)).status, 403);
    assert.equal((await t.api('GET', `/admin/intel/rider-risk/${u.user.userId}`, null, u.token)).status, 403);
    const a = await t.register('Ins Admin', 'insights.admin@coroute.test');
    const ins = await t.api('GET', '/admin/intel/insights', null, a.token);
    if (ins.status === 200) {
      assert.equal(ins.json.database.separate, false);
      const rr = await t.api('GET', `/admin/intel/rider-risk/${u.user.userId}`, null, a.token);
      assert.equal(rr.status, 200, JSON.stringify(rr.json));
      assert.equal(rr.json.bucket, 'not enough riding');
      const log = await t.gw.repo.listAuditEntries(50);
      assert.ok(log.some((e) => e.action === 'intel.rider_risk.view' && e.target === u.user.userId), 'audited');
    } else {
      assert.ok([401, 403].includes(ins.status), 'admin needs 2-step on this client');
    }
  } finally { await t.gw.shutdown(); }
});
