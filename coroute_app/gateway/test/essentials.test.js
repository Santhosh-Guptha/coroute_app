'use strict';
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EssentialsService, OverpassPlacesProvider, requestOf, visits } = require('../src/essentials');
const { encodePolyline, haversine } = require('../src/geo_math');
const line = [{ lat: 17, lng: 78 }, { lat: 18, lng: 78 }, { lat: 19, lng: 78 }];
const body = { polyline: encodePolyline(line), category: 'FUEL', fromM: 0 };
function setup({ list, complete = true, maxCandidates = 12 } = {}) {
  let now = 1700000000000, fail = false, calls = 0;
  const cache = new Map();
  const repo = { geoCacheGet: async k => cache.get(k), geoCachePut: async (k, value) => cache.set(k, { value }) };
  const places = { corridor: async () => {
    calls++; if (fail) throw Error('offline');
    return { complete, places: list || [{ placeId: 'osm:node:1', name: 'Pump', category: 'FUEL', source: 'OpenStreetMap', lat: 17.1, lng: 78.001 }] };
  } };
  const routing = async pts => {
    const legs = pts.slice(1).map((p, i) => ({ distanceM: haversine(pts[i].lat, pts[i].lng, p.lat, p.lng), durationS: 60 }));
    return { distanceM: legs.reduce((s, l) => s + l.distanceM, 0), durationS: legs.length * 60, legs };
  };
  const service = new EssentialsService({ repo, places, routing, clock: () => now, maxCandidates });
  return { service, cache, repo, places, routing, get calls() { return calls; }, set fail(v) { fail = v; }, advance(ms) { now += ms; } };
}
test('validates malformed, approximate, oversized and invalid category inputs', () => {
  for (const patch of [{ polyline: '?' }, { polyline: 'x'.repeat(100001) }, { category: '__proto__' }, { fromM: -1 }, { fromM: NaN }, { fromM: 9999999 }, { approximate: true }]) {
    assert.throws(() => requestOf({ ...body, ...patch }), e => e.status === 400);
  }
});
test('window is bounded and advances every 5 km to avoid exhausting dense-city candidates', () => {
  assert.equal(requestOf(body).toM, 150000);
  assert.equal(requestOf({ ...body, fromM: 4999 }).fromM, 0);
  assert.equal(requestOf({ ...body, fromM: 5001 }).fromM, 5000);
});
test('road detour includes return and provides separate access distance', async () => {
  const t = setup(); const r = await t.service.query(body);
  assert.equal(r.places.length, 1); assert.equal(r.complete, true);
  assert.ok(r.places[0].detourDistanceM > 0); assert.ok(r.places[0].accessDistanceM > 1000);
  assert.equal(r.places[0].openStatus, 'unknown');
});
test('duplicate place ids are deduplicated within a pass, not across loops', () => {
  const loop = [{ lat: 17, lng: 78 }, { lat: 17.1, lng: 78 }, { lat: 17.2, lng: 78 }, { lat: 17.1, lng: 78 }, { lat: 17, lng: 78 }];
  const r = requestOf({ ...body, polyline: encodePolyline(loop) });
  assert.equal(visits(r, { lat: 17.05, lng: 78 }).length, 2);
});
test('fresh cache and concurrent clients share a discovery request', async () => {
  const t = setup();
  const [a, b] = await Promise.all([t.service.query(body), t.service.query(body)]);
  assert.deepEqual(a, b); await t.service.query(body); assert.equal(t.calls, 1);
});
test('outage serves old cache with original timestamp, never fresh empty data', async () => {
  const t = setup(); const old = await t.service.query(body);
  t.advance(1800001); t.fail = true;
  const result = await t.service.query(body);
  assert.equal(result.stale, true); assert.equal(result.fetchedAt, old.fetchedAt); assert.equal(result.places.length, 1);
});
test('outage without cache and cache older than seven days fail explicitly', async () => {
  const t = setup(); t.fail = true; await assert.rejects(t.service.query(body));
  t.fail = false; await t.service.query(body); t.advance(8 * 86400000); t.fail = true;
  await assert.rejects(t.service.query(body));
});
test('routing failure produces partial coverage and no invented detour', async () => {
  const t = setup(); t.service.routing = async () => null;
  await assert.rejects(t.service.query(body), e => e.code === 'ESSENTIALS_ROAD_ACCESS_UNAVAILABLE');
});
test('routing shortcuts and non-finite results are rejected', async () => {
  const t = setup(); t.service.routing = async () => ({ distanceM: 1, durationS: 1, legs: [{ distanceM: 1 }, { distanceM: 1 }] });
  await assert.rejects(t.service.query(body));
  const u = setup(); u.service.routing = async () => ({ distanceM: NaN, durationS: 1, legs: [{ distanceM: 1 }, { distanceM: 1 }] });
  await assert.rejects(u.service.query(body));
});
test('bounded candidates remain partial; empty complete provider results stay non-exhaustive', async () => {
  const t = setup({ maxCandidates: 0 }); assert.equal((await t.service.query(body)).complete, false);
  const u = setup({ list: [] }); const r = await u.service.query(body); assert.equal(r.complete, true); assert.deepEqual(r.places, []);
});
test('route/category changes do not share stale results', async () => {
  const t = setup(); await t.service.query(body); t.fail = true;
  await assert.rejects(t.service.query({ ...body, category: 'FOOD' }));
  await assert.rejects(t.service.query({ ...body, polyline: encodePolyline([{ lat: 18, lng: 78 }, { lat: 19, lng: 78 }]) }));
});
test('storage failure does not prevent a successful live response', async () => {
  const t = setup(); t.repo.geoCacheGet = async () => { throw Error('db down'); }; t.repo.geoCachePut = async () => { throw Error('db down'); };
  assert.equal((await t.service.query(body)).places.length, 1);
});
test('provider disabled fails without upstream work', async () => {
  const t = setup(); t.service.places = null;
  await assert.rejects(t.service.query(body), e => e.code === 'ESSENTIALS_NOT_CONFIGURED'); assert.equal(t.calls, 0);
});
test('Overpass errors, timeout remarks and malformed replies fail explicitly', async () => {
  for (const reply of [{ remark: 'timeout', elements: [] }, {}, { elements: null }]) {
    const p = new OverpassPlacesProvider({ url: 'https://provider.invalid', fetchImpl: async () => ({ ok: true, json: async () => reply }) });
    await assert.rejects(p.corridor(requestOf(body)));
  }
});
test('Overpass sends fixed category query and preserves unknown opening status', async () => {
  let request;
  const p = new OverpassPlacesProvider({ url: 'https://provider.invalid', fetchImpl: async (_, opts) => {
    request = decodeURIComponent(opts.body);
    return { ok: true, json: async () => ({ elements: [{ type: 'node', id: 1, lat: 17.1, lon: 78, tags: { name: 'Pump', opening_hours: '24/7' } }] }) };
  } });
  const result = await p.corridor(requestOf(body));
  assert.match(request, /amenity=fuel/); assert.match(request, /around:1500/);
  assert.equal(result.places[0].openingHours, '24/7'); assert.equal(result.complete, true);
});
test('Overpass expands tags for roadside puncture repair, welders, and CHC trauma centres', async () => {
  let tyreRequest, hospitalRequest;
  const pTyre = new OverpassPlacesProvider({ url: 'https://provider.invalid', fetchImpl: async (_, opts) => {
    tyreRequest = decodeURIComponent(opts.body);
    return { ok: true, json: async () => ({ elements: [
      { type: 'node', id: 10, lat: 17.1, lon: 78, tags: { name: 'Raju Puncture Works', shop: 'tyres' } },
      { type: 'node', id: 11, lat: 17.2, lon: 78, tags: { name: 'Highway Welder', craft: 'welder' } },
    ] }) };
  } });
  const tyreResult = await pTyre.corridor(requestOf({ ...body, category: 'TYRE' }));
  assert.match(tyreRequest, /tyres/);
  assert.match(tyreRequest, /craft=welder/);
  assert.match(tyreRequest, /amenity=vehicle_inspection/);
  assert.equal(tyreResult.places.length, 2);

  const pHospital = new OverpassPlacesProvider({ url: 'https://provider.invalid', fetchImpl: async (_, opts) => {
    hospitalRequest = decodeURIComponent(opts.body);
    return { ok: true, json: async () => ({ elements: [
      { type: 'node', id: 20, lat: 17.1, lon: 78, tags: { name: 'CHC Shoolagiri', amenity: 'clinic' } },
      { type: 'node', id: 21, lat: 17.2, lon: 78, tags: { name: 'District Trauma Centre', healthcare: 'hospital', 'healthcare:speciality': 'trauma' } },
    ] }) };
  } });
  const hospitalResult = await pHospital.corridor(requestOf({ ...body, category: 'HOSPITAL' }));
  assert.match(hospitalRequest, /healthcare/);
  assert.equal(hospitalResult.places[0].isTraumaCenter, true);
  assert.equal(hospitalResult.places[1].isTraumaCenter, true);
});
test('Overpass identifies and prioritizes COCO and verified Indian fuel pumps (IOCL, BPCL, HPCL, Shell)', async () => {
  const p = new OverpassPlacesProvider({ url: 'https://provider.invalid', fetchImpl: async () => ({
    ok: true,
    json: async () => ({ elements: [
      { type: 'node', id: 1, lat: 17.1, lon: 78, tags: { name: 'BPCL COCO Shoolagiri', operator: 'BPCL', 'fuel:coco': 'yes' } },
      { type: 'node', id: 2, lat: 17.2, lon: 78, tags: { name: 'IOCL Retail Outlet', operator: 'Indian Oil Corporation' } },
      { type: 'node', id: 3, lat: 17.3, lon: 78, tags: { name: 'Local Village Pump' } },
    ] })
  }) });
  const result = await p.corridor(requestOf(body));
  assert.equal(result.places[0].isCoco, true);
  assert.equal(result.places[0].priority, 1);
  assert.equal(result.places[1].isCoco, undefined);
  assert.equal(result.places[1].priority, 1); // verified Indian brand
  assert.equal(result.places[2].priority, 2); // unbranded
});
