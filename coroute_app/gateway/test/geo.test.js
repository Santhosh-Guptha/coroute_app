'use strict';
process.env.NODE_ENV = 'test';
process.env.GEO_SEARCH_URL = 'http://geo.test';
process.env.GEO_ROUTE_URL = 'http://route.test';
process.env.GEO_MIN_INTERVAL_MS = '150';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { GeoProxy, shortName } = require('../src/geo');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { decodePolyline } = require('../src/geo_math');

function fakeFetch(log) {
  return async (url, opts) => {
    log.push({ url, at: Date.now(), ua: opts.headers['User-Agent'] });
    if (url.startsWith('http://geo.test/reverse')) {
      return { ok: true, json: async () => ({ name: 'HP Petrol Pump', address: { road: 'NH44', suburb: 'Shamshabad' } }) };
    }
    if (url.startsWith('http://geo.test/search')) {
      return { ok: true, json: async () => ([{ display_name: 'Kurnool, Andhra Pradesh, India', lat: '15.83', lon: '78.04', address: { city: 'Kurnool' } }]) };
    }
    if (url.startsWith('http://route.test/route/v1/driving/')) {
      return { ok: true, json: async () => ({ routes: [{ distance: 210400.4, duration: 12600.2, geometry: { coordinates: [[78.4, 17.4], [78.3, 16.9], [78.04, 15.83]] }, legs: [{ distance: 100000, duration: 6000 }, { distance: 110400, duration: 6600 }] }] }) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
}

test('geo proxy: cached, spaced out, identifies itself', async () => {
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  const log = [];
  const geo = new GeoProxy({ repo, fetchImpl: fakeFetch(log), logger: { warn() {} } });

  const [a, b] = await Promise.all([geo.reverse(17.24051, 78.42977), geo.search('Kurnool')]);
  assert.equal(a, 'HP Petrol Pump, Shamshabad');
  assert.equal(b[0].name, 'Kurnool');
  assert.equal(log.length, 2);
  assert.ok(log[1].at - log[0].at >= 140, 'upstream calls are spaced out');
  assert.match(log[0].ua, /^CoRoute\/3\.1 /);

  // Same place (within ~11 m) and same query come from the cache.
  assert.equal(await geo.reverse(17.24049, 78.42981), 'HP Petrol Pump, Shamshabad');
  assert.equal((await geo.search('kurnool'))[0].lat, 15.83);
  assert.equal(log.length, 2);

  const r = await geo.route([{ lat: 17.4, lng: 78.4 }, { lat: 16.9, lng: 78.3 }, { lat: 15.83, lng: 78.04 }]);
  assert.equal(r.distanceM, 210400);
  assert.equal(r.legs.length, 2);
  assert.equal(decodePolyline(r.polyline).length, 3);
  assert.equal(await geo.route([{ lat: 99, lng: 0 }, { lat: 1, lng: 1 }]), null);
  assert.equal(await geo.route([{ lat: 1, lng: 1 }]), null);
  assert.deepEqual(await geo.search('ab'), []);
});

test('short place names', () => {
  assert.equal(shortName({ address: { amenity: 'Cafe Niloufer', suburb: 'Lakdikapul', city: 'Hyderabad' } }), 'Cafe Niloufer, Lakdikapul');
  assert.equal(shortName({ display_name: 'Somewhere far' }), 'Somewhere far');
  assert.equal(shortName(null), null);
});
