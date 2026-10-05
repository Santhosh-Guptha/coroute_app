'use strict';
process.env.NODE_ENV = 'test';
process.env.GEO_PHOTON_URL = 'http://photon.test';
process.env.GEO_SEARCH_URL = 'http://nominatim.test';
process.env.GEO_PHOTON_MIN_INTERVAL_MS = '0';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { GeoProxy } = require('../src/geo');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');

const feat = (name, lat, lng, props = {}) => ({ geometry: { coordinates: [lng, lat] }, properties: { name, countrycode: 'IN', state: 'Telangana', ...props } });

test('search: India first, nearest first, the world only when India has nothing', async () => {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    const u = new URL(url);
    const q = u.searchParams.get('q');
    const inIndia = u.searchParams.has('bbox');
    let features = [];
    if (q === 'Kothur') {
      features = inIndia
        ? [feat('Kothur', 17.03, 78.28, { county: 'Rangareddy' }), feat('Kothur', 17.031, 78.281, { county: 'Rangareddy' }), feat('Kothur Lake', 13.0, 77.6, { state: 'Karnataka' }),
          feat('Kothur', 40.0, -75.0, { countrycode: 'US', country: 'United States', state: 'Pennsylvania' })]
        : [];
    } else if (q === 'Eiffel Tower') {
      features = inIndia ? [] : [feat('Eiffel Tower', 48.858, 2.294, { countrycode: 'FR', country: 'France', state: 'Ile-de-France' })];
    }
    return { ok: true, json: async () => ({ features }) };
  };
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  const geo = new GeoProxy({ repo, fetchImpl, logger: { warn() {} } });

  const r = await geo.search('Kothur', { lat: 17.24, lng: 78.43 });
  assert.equal(calls.length, 1);
  const u = new URL(calls[0]);
  assert.equal(u.searchParams.get('bbox'), '68,6.4,97.6,37.1');
  assert.equal(u.searchParams.get('lat'), '17.24');
  assert.equal(u.searchParams.get('lang'), 'en');
  assert.equal(r.length, 2, 'duplicate merged, other country dropped');
  assert.equal(r[0].displayName, 'Rangareddy, Telangana');
  assert.equal(r[0].outside, false);
  assert.ok(r[0].distanceM > 20000 && r[0].distanceM < 30000);
  assert.ok(r.every((x) => !x.outside));

  const w = await geo.search('Eiffel Tower', { lat: 17.24, lng: 78.43 });
  assert.equal(w.length, 1);
  assert.equal(w[0].outside, true);
  assert.match(w[0].displayName, /France/);

  // Cached: no new upstream calls.
  const before = calls.length;
  await geo.search('kothur', { lat: 17.24, lng: 78.43 });
  assert.equal(calls.length, before);
});
