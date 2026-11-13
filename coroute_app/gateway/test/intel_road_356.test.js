'use strict';
/**
 * Round 4 intelligence from telemetry: rider stops (feature 9), no-fuel gaps, motorcycle ETAs (feature 10) with their
 * caps and accuracy on synthetic data, and twistiness / ghat score (feature 8).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'road.admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const gh = require('../src/intel/geohash');
const M = require('../src/intel/math');
const { encodePolyline } = require('../src/geo_math');
const { fuelGapsOf } = require('../src/intel/engine');
const { makeEngine, ride, consentAll, move } = require('./_intel_helpers');
const { boot } = require('./_helpers');

const START = { lat: 12.95, lng: 77.5 };
const riders = (p, n) => Array.from({ length: n }, (_, i) => `${p}${i}`);

async function everyoneRides(env, ids, legs, { start = START, gapMin = 20 } = {}) {
  await consentAll(env, ids);
  let end;
  for (const [i, id] of ids.entries()) {
    end = ride(env, { userId: id, gid: `R${i}`, start, legs });
    env.engine.onRoomEnded(`R${i}`);
    env.clock.now += gapMin * 60000;
  }
  await env.engine.flushRaw();
  await env.engine.aggregate();
  env.engine.cache.clear();
  return end;
}

test('stops: 4-90 min stops cluster to a cell with typical duration; short, long and start / end stops do not count', async () => {
  const env = makeEngine();
  const ids = riders('s', 5);
  await everyoneRides(env, ids, [{ deg: 90, km: 3, kmh: 40 }, { stopMin: 12 }, { deg: 90, km: 3, kmh: 40 }, { stopMin: 2 }, { deg: 90, km: 2, kmh: 40 }, { stopMin: 120 }, { deg: 90, km: 2, kmh: 40 }, { stopMin: 15 }]);
  const stopAt = move(START.lat, START.lng, 90, 3000);
  const area = { bbox: { s: 12.8, w: 77.4, n: 13.1, e: 77.7 } };
  const list = await env.engine.stops(area, { admin: true });
  assert.equal(list.length, 1, JSON.stringify(list));
  assert.ok(M.haversine(list[0].lat, list[0].lng, stopAt.lat, stopAt.lng) < 200);
  assert.ok(list[0].typicalMin >= 11 && list[0].typicalMin <= 13, `typical ${list[0].typicalMin}`);
  assert.equal(list[0].riders, 5);
  assert.equal(list[0].peakHours[1] - list[0].peakHours[0], 4, 'a four-hour time-of-day band');
  // Fewer than k riders: hidden.
  const env2 = makeEngine();
  await everyoneRides(env2, riders('t', 4), [{ deg: 90, km: 3, kmh: 40 }, { stopMin: 12 }, { deg: 90, km: 3, kmh: 40 }]);
  assert.equal((await env2.engine.stops(area)).length, 0);
});

test('no-fuel gaps: stretches over FUEL_GAP_KM between known fuel', () => {
  const line = [];
  let p = { lat: 15.0, lng: 75.0 };
  for (let i = 0; i <= 300; i++) { line.push(p); p = move(p.lat, p.lng, 0, 1000); }
  const at = (km) => ({ ...move(15.0, 75.0, 0, km * 1000), name: `Pump ${km}` });
  const out = fuelGapsOf(line, [at(10), at(150), at(160), { ...move(15.0, 75.5, 0, 50000), name: 'far away' }], 80);
  assert.equal(out.fuelCount, 3, 'a station 50 km off the road is not on the route');
  assert.deepEqual(out.gaps.map((g) => [Math.round(g.fromKm), Math.round(g.toKm), g.lengthKm, g.after, g.toEnd]), [[10, 150, 140, 'Pump 10', false], [160, 300, 140, 'Pump 160', true]]);
  assert.equal(fuelGapsOf(line, [at(10), at(150), at(160)], 150).gaps.length, 0, 'configurable');
  assert.equal(fuelGapsOf(line, [], 80).gaps[0].after, 'start');
});

test('no-fuel gaps use learned stops matched to fuel stations (k riders) and the app\'s known fuel', async () => {
  const env = makeEngine();
  const line = [];
  let p = { lat: 15.0, lng: 75.0 };
  for (let i = 0; i <= 200; i++) { line.push(p); p = move(p.lat, p.lng, 0, 1000); }
  const mid = move(15.0, 75.0, 0, 100000);
  const g7 = gh.encode(mid.lat, mid.lng, 7);
  const c = gh.center(g7);
  await env.soda.insert('intel_cells', { id: `st:${g7}`, layer: 'st', cell: g7, g4: g7.slice(0, 4), lat: c.lat, lng: c.lng, at: env.clock.now, rm: M.monthKey(env.clock.now), rs: ['a', 'b', 'c', 'd', 'e'], rk: 0, n: 6, dur: 60, tod: [0, 0, 6, 0, 0, 0], place: { name: 'HP Highway', cat: 'fuel' } });
  const out = await env.engine.fuelGaps(line, { fuel: [] });
  assert.deepEqual(out.gaps.map((g) => [Math.round(g.fromKm), Math.round(g.toKm), g.after]), [[0, 100, 'start'], [100, 200, 'HP Highway']]);
  const out2 = await env.engine.fuelGaps(line, { fuel: [{ ...move(15.0, 75.0, 0, 50000), name: 'IOCL' }, { ...move(15.0, 75.0, 0, 150000), name: 'BPCL' }] });
  assert.equal(out2.gaps.length, 0);
});

test('twistiness: heading change per km gives a 0-100 score; ghats are labelled; straight roads score low', async () => {
  const env = makeEngine();
  await everyoneRides(env, riders('w', 5), [{ deg: 90, km: 6, kmh: 40 }, { deg: 0, km: 6, kmh: 35, wiggle: 12 }]);
  const area = { bbox: { s: 12.8, w: 77.4, n: 13.1, e: 77.7 } };
  const list = await env.engine.twisty(area, { minScore: 0, admin: true });
  const twisty = list.filter((x) => x.ghat);
  const straight = list.filter((x) => x.score < 10);
  assert.ok(twisty.length >= 2, JSON.stringify(list.map((x) => x.score)));
  assert.ok(straight.length >= 2);
  for (const x of twisty) assert.ok(x.lng > START.lng + 0.04, 'the twisty part is the northbound leg');
  assert.ok((await env.engine.twisty(area)).every((x) => x.score >= 30), 'public answer: from 30 up');
});

function routeAlong(start, deg, km, routerKmh) {
  const line = [];
  let p = start;
  for (let i = 0; i <= km * 10; i++) { line.push(p); p = move(p.lat, p.lng, deg, 100); }
  return { distanceM: km * 1000, durationS: Math.round((km / routerKmh) * 3600), polyline: encodePolyline(line), legs: [{ distanceM: km * 1000, durationS: Math.round((km / routerKmh) * 3600) }] };
}

test('motorcycle ETAs: factor from riders\' speeds, capped to 0.6-1.6, only with k riders, never mutating the route', async () => {
  const env = makeEngine();
  await everyoneRides(env, riders('e', 5), [{ deg: 90, km: 12, kmh: 48 }]);
  const route = routeAlong(START, 90, 10, 60);
  const frozen = JSON.stringify(route);
  const adj = await env.engine.etaAdjust(route);
  assert.equal(JSON.stringify(route), frozen, 'the cached route object is untouched');
  assert.equal(adj.etaSource, 'riders');
  assert.equal(adj.routerDurationS, 600);
  const f = adj.legs[0].etaFactor;
  assert.ok(f > 1.2 && f < 1.3, `60 / 48 = 1.25, got ${f}`);
  assert.ok(Math.abs(adj.durationS - 750) / 750 < 0.05, `accuracy within 5 % on synthetic data (${adj.durationS} s vs 750 s)`);
  // Caps.
  const slowRouter = routeAlong(START, 90, 10, 20);
  assert.equal((await env.engine.etaAdjust(slowRouter)).legs[0].etaFactor, 0.6);
  const fastRouter = routeAlong(START, 90, 10, 120);
  assert.equal((await env.engine.etaAdjust(fastRouter)).legs[0].etaFactor, 1.6);
  // Elsewhere: the plain router answer.
  const other = routeAlong({ lat: 20, lng: 80 }, 0, 10, 60);
  assert.equal(await env.engine.etaAdjust(other), other);
  // Fewer than k riders: plain.
  const env2 = makeEngine();
  await everyoneRides(env2, riders('f', 4), [{ deg: 90, km: 12, kmh: 48 }]);
  assert.equal((await env2.engine.etaAdjust(route)).etaSource, undefined);
});

test('gateway: stops, twisty and fuel gaps endpoints; route endpoint keeps working without learned data', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown().catch(() => {}));
  const admin = await env.register('Road Admin', 'road.admin@coroute.test');
  for (const p of ['/intel/stops?bbox=12.8,77.4,13.1,77.7', '/intel/twisty?bbox=12.8,77.4,13.1,77.7', '/intel/road-quality?bbox=12.8,77.4,13.1,77.7']) {
    const r = await env.api('GET', p, null, admin.token);
    assert.equal(r.status, 200, p);
    assert.deepEqual(r.json.cells, []);
  }
  const line = [START, move(START.lat, START.lng, 0, 120000)];
  const r = await env.api('POST', '/intel/fuel-gaps', { points: line, gapKm: 80 }, admin.token);
  assert.equal(r.status, 200);
  assert.equal(r.json.gaps.length, 1);
  assert.equal(r.json.gaps[0].lengthKm, 120);
  assert.equal((await env.api('POST', '/intel/fuel-gaps', { points: [START] }, admin.token)).status, 400);
  const tip = await env.api('GET', '/intel/ride-tip?lat=12.9&lng=77.6', null, admin.token);
  assert.deepEqual(tip.json, { tip: null });
});
