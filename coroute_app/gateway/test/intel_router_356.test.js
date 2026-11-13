'use strict';
/**
 * Round 4 router adapter (feature 13): ROUTER_KIND=osrm|valhalla, request building, response normalisation from
 * fixtures in each router's documented answer format (test/fixtures/intel/), and GeoProxy end to end with Valhalla.
 * The default stays OSRM.
 */
process.env.NODE_ENV = 'test';
process.env.GEO_ROUTE_URL = 'http://router.test';
process.env.GEO_MIN_INTERVAL_MS = '0';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const A = require('../src/intel/router_adapter');
const { GeoProxy } = require('../src/geo');
const { decodePolyline } = require('../src/geo_math');

const fx = (f) => JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'intel', f), 'utf8'));
const WP = [{ lat: 12.9716, lng: 77.5946 }, { lat: 12.9802, lng: 77.6105 }, { lat: 13.0012, lng: 77.63 }];

test('requests: OSRM driving URL (unchanged) and Valhalla motorcycle costing', () => {
  const o = A.buildRequest('osrm', 'http://o', WP, { bearing: 90 });
  assert.equal(o.url, 'http://o/route/v1/driving/77.5946,12.9716;77.6105,12.9802;77.63,13.0012?overview=full&geometries=geojson&steps=true&bearings=90,60;;');
  const v = A.buildRequest('valhalla', 'http://v', WP, { bearing: 90 });
  const json = JSON.parse(decodeURIComponent(v.url.split('json=')[1]));
  assert.equal(json.costing, 'motorcycle');
  assert.deepEqual(json.locations[0], { lat: 12.9716, lon: 77.5946, type: 'break', heading: 90, heading_tolerance: 60 });
  assert.equal(json.locations[1].type, 'through');
  assert.equal(json.locations[2].type, 'break');
});

test('normalisation: both answers come out in the same shape', () => {
  const o = A.normalise('osrm', fx('osrm_route.json'));
  const v = A.normalise('valhalla', fx('valhalla_route.json'));
  for (const r of [o, v]) {
    assert.deepEqual(Object.keys(r).sort(), ['distanceM', 'durationS', 'legs', 'line', 'router', 'steps']);
    assert.equal(r.legs.length, 2);
    assert.equal(r.line.length, 5, 'legs joined without repeating the shared point');
    assert.ok(Math.abs(r.line[0].lat - 12.9716) < 1e-6 && Math.abs(r.line[4].lng - 77.63) < 1e-6);
  }
  assert.deepEqual([v.distanceM, v.durationS], [4980, 446]);
  assert.deepEqual(v.legs, [{ distanceM: 1960, durationS: 205 }, { distanceM: 3020, durationS: 240 }]);
  assert.deepEqual(v.steps.map((s) => s.name), ['MG Road', 'Old Airport Road', 'Outer Ring Road']);
  assert.deepEqual([o.distanceM, o.durationS, o.steps.length], [4980, 398, 3]);
  assert.equal(A.errorCode('valhalla', fx('valhalla_no_route.json')), 'NoRoute');
  assert.equal(A.errorCode('osrm', fx('osrm_no_route.json')), 'NoRoute');
  assert.equal(A.normalise('valhalla', fx('valhalla_no_route.json')), null);
  assert.equal(A.errorCode('valhalla', { error_code: 171 }), 'NoSegment');
  assert.match(A.ATTRIBUTION.valhalla, /OpenStreetMap/);
});

function fakeRepo() {
  const m = new Map();
  return { geoCacheGet: async (k) => (m.has(k) ? { value: m.get(k), createdAt: Date.now() } : null), geoCachePut: async (k, v) => { m.set(k, v); } };
}

test('GeoProxy: ROUTER_KIND=valhalla routes through Valhalla with the same answer shape; default is OSRM', async () => {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    const body = url.includes('/route?json=') ? fx('valhalla_route.json') : fx('osrm_route.json');
    return { ok: true, status: 200, json: async () => body };
  };
  delete process.env.ROUTER_KIND;
  const g1 = new GeoProxy({ repo: fakeRepo(), fetchImpl, logger: { warn() {}, info() {} } });
  const o = await g1.routeResult(WP);
  assert.ok(o.route);
  assert.match(calls[0], /\/route\/v1\/driving\//, 'default: OSRM');
  assert.equal(o.route.durationS, 398);

  process.env.ROUTER_KIND = 'valhalla';
  const g2 = new GeoProxy({ repo: fakeRepo(), fetchImpl, logger: { warn() {}, info() {} } });
  const v = await g2.routeResult(WP);
  assert.match(calls[1], /\/route\?json=/);
  assert.equal(v.route.router, 'valhalla');
  assert.equal(v.route.durationS, 446);
  assert.equal(decodePolyline(v.route.polyline).length, 5);
  assert.deepEqual(v.route.legs.map((l) => l.durationS), [205, 240]);
  // Cached: no second upstream call.
  await g2.routeResult(WP);
  assert.equal(calls.length, 2);

  const g3 = new GeoProxy({ repo: fakeRepo(), fetchImpl: async () => ({ ok: false, status: 400, json: async () => fx('valhalla_no_route.json') }), logger: { warn() {}, info() {} } });
  assert.deepEqual(await g3.routeResult(WP), { error: 'NO_ROUTE' });
  process.env.ROUTER_KIND = 'nonsense';
  assert.equal(require('../src/intel/config').intelConfig().routerKind, 'osrm', 'unknown kinds fall back to OSRM');
  delete process.env.ROUTER_KIND;
});

test('safety network road distances stay on OSRM when ROUTER_KIND=valhalla', async () => {
  const urls = [];
  const fetchImpl = async (url) => { urls.push(url); return { ok: true, status: 200, json: async () => ({ code: 'Ok', distances: [[1200]], durations: [[90]] }) }; };
  process.env.ROUTER_KIND = 'valhalla';
  process.env.OSRM_TABLE_URL = 'http://osrm.table.test/';
  const g = new GeoProxy({ repo: fakeRepo(), fetchImpl, logger: { warn() {}, info() {} } });
  const out = await g.table([{ lat: 12.97, lng: 77.59 }], { lat: 12.98, lng: 77.6 });
  assert.deepEqual(out, [{ distanceM: 1200, durationS: 90 }]);
  assert.match(urls[0], /^http:\/\/osrm\.table\.test\/table\/v1\/driving\//);
  delete process.env.ROUTER_KIND; delete process.env.OSRM_TABLE_URL;
});
