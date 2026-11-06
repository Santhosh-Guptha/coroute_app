'use strict';
// New routes from a rider's position (auto re-route): direction of travel, fallback, clear
// errors, caching and the per-user limit of POST /geo/route.
process.env.NODE_ENV = 'test';
process.env.GEO_ROUTE_URL = 'http://route.test';
process.env.GEO_MIN_INTERVAL_MS = '5';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { GeoProxy } = require('../src/geo');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { boot } = require('./_helpers');

const OK = { code: 'Ok', routes: [{ distance: 5200.4, duration: 420.2, geometry: { coordinates: [[78.4, 17.4], [78.41, 17.42], [78.42, 17.45]] }, legs: [{ distance: 5200, duration: 420, steps: [{ name: 'MG Road', ref: '', distance: 5200, duration: 420 }] }] }] };

/** OSRM stand-in: answers by URL; `noSegmentWithBearing` refuses any request with bearings. */
function osrm(log, { noSegmentWithBearing = false, noRoute = false, down = false } = {}) {
  return async (url) => {
    log.push(url);
    if (down) return { ok: false, status: 503, json: async () => { throw new Error('html'); } };
    if (noRoute) return { ok: false, status: 400, json: async () => ({ code: 'NoRoute', message: 'Impossible route' }) };
    if (noSegmentWithBearing && url.includes('bearings=')) return { ok: false, status: 400, json: async () => ({ code: 'NoSegment', message: 'Could not find a matching segment' }) };
    return { ok: true, status: 200, json: async () => OK };
  };
}

async function proxy(opts) {
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  const log = [];
  return { log, geo: new GeoProxy({ repo, fetchImpl: osrm(log, opts), logger: { warn() {} } }) };
}

const from = { lat: 17.400004, lng: 78.400004 };
const to = { lat: 17.45, lng: 78.42 };

test('a start bearing goes to OSRM for the first point only; the start is rounded and shared from the cache', async () => {
  const { geo, log } = await proxy();
  const r = await geo.routeResult([from, { lat: 17.42, lng: 78.41 }, to], { startBearing: 93 });
  assert.equal(r.route.distanceM, 5200);
  assert.equal(log.length, 1);
  assert.match(log[0], /bearings=90,60;;$/);
  assert.match(log[0], /\/78\.4,17\.4;/, 'start rounded to 4 decimals (about 11 m)');
  // Another rider a few metres away, heading about the same way: same answer, no upstream call.
  await geo.routeResult([{ lat: 17.40002, lng: 78.40001 }, { lat: 17.42, lng: 78.41 }, to], { startBearing: 88 });
  assert.equal(log.length, 1);
  // The opposite direction is another route.
  await geo.routeResult([from, { lat: 17.42, lng: 78.41 }, to], { startBearing: 270 });
  assert.equal(log.length, 2);
  // A planned route (no bearing) keeps 5 decimals and asks without bearings.
  await geo.route([from, to]);
  assert.equal(log.length, 3);
  assert.ok(!log[2].includes('bearings='));
  assert.match(log[2], /78\.4,17\.4;/);
});

test('no road in that direction near the rider: the plain route is used', async () => {
  const { geo, log } = await proxy({ noSegmentWithBearing: true });
  const r = await geo.routeResult([from, to], { startBearing: 180 });
  assert.equal(r.route.distanceM, 5200);
  assert.equal(log.length, 2);
  assert.ok(log[0].includes('bearings=') && !log[1].includes('bearings='));
});

test('clear reasons: invalid waypoints, no route (remembered for a minute), upstream down', async () => {
  const { geo } = await proxy();
  assert.deepEqual(await geo.routeResult([from]), { error: 'INVALID_WAYPOINTS' });
  assert.deepEqual(await geo.routeResult([from, { lat: 95, lng: 0 }]), { error: 'INVALID_WAYPOINTS' });
  assert.deepEqual(await geo.routeResult([from, { lat: 'x', lng: 1 }]), { error: 'INVALID_WAYPOINTS' });
  assert.deepEqual(await geo.routeResult([from, to], { startBearing: 'north' }), { error: 'INVALID_WAYPOINTS' });
  assert.deepEqual(await geo.routeResult(new Array(26).fill(from)), { error: 'INVALID_WAYPOINTS' });

  const none = await proxy({ noRoute: true });
  assert.deepEqual(await none.geo.routeResult([from, to]), { error: 'NO_ROUTE' });
  assert.deepEqual(await none.geo.routeResult([from, to]), { error: 'NO_ROUTE' });
  assert.equal(none.log.length, 1, 'a known dead end is not asked again within a minute');
  assert.equal(await none.geo.route([from, to]), null);

  const down = await proxy({ down: true });
  assert.deepEqual(await down.geo.routeResult([from, to], { startBearing: 10 }), { error: 'UPSTREAM' });
});

let t;
let mode = {};
const upstream = [];
before(async () => {
  t = await boot({ geoFetch: (url, opts) => osrm(upstream, mode)(url, opts) });
});
after(async () => { await t.gw.shutdown(); });

test('POST /geo/route: route from my position with my heading; errors with a code; at most 12 a minute per rider', async () => {
  const A = await t.register('Route Rider', 'routerider@coroute.test');
  const ok = await t.api('POST', '/geo/route', { waypoints: [from, to], startBearing: 45 }, A.token);
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.equal(ok.json.distanceM, 5200);
  assert.ok(typeof ok.json.polyline === 'string' && ok.json.polyline.length > 0);
  assert.ok(upstream.some((u) => u.includes('bearings=50,60;')));

  const bad = await t.api('POST', '/geo/route', { waypoints: [from] }, A.token);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.code, 'INVALID_WAYPOINTS');

  mode = { noRoute: true };
  const none = await t.api('POST', '/geo/route', { waypoints: [from, { lat: 10.1, lng: 76.2 }] }, A.token);
  assert.equal(none.status, 422);
  assert.equal(none.json.code, 'NO_ROUTE');

  mode = { down: true };
  const down = await t.api('POST', '/geo/route', { waypoints: [from, { lat: 10.2, lng: 76.3 }] }, A.token);
  assert.equal(down.status, 502);
  assert.equal(down.json.code, 'UPSTREAM');
  mode = {};

  assert.equal((await t.api('POST', '/geo/route', { waypoints: [from, to] })).status, 401, 'signed in only');

  let limited = null;
  for (let i = 0; i < 12 && !limited; i++) {
    const r = await t.api('POST', '/geo/route', { waypoints: [from, to], startBearing: 45 }, A.token);
    if (r.status === 429) limited = r;
  }
  assert.ok(limited, 'the 13th request in a minute is refused');
  assert.equal(limited.json.code, 'RATE_LIMITED');
});
