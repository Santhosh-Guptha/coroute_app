'use strict';
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { PoiCellService, parseCells, bboxOf, overpassQuery, compact } = require('../src/poi_cells');
const { boot } = require('./_helpers');

function memRepo() {
  const m = new Map();
  return { m, geoCacheGet: async (k) => m.get(k) || null, geoCachePut: async (k, value) => { m.set(k, { k, value, createdAt: Date.now() }); } };
}
function overpass(elements = [{ type: 'node', id: 1, lat: 17.01, lon: 78.01, tags: { amenity: 'fuel', name: 'HP', 'fuel:diesel': 'yes', wheelchair: 'no', 'addr:full': 'x' } }]) {
  const calls = [];
  const fetchImpl = async (url, init) => { calls.push({ url, body: decodeURIComponent(String(init.body).slice(5)) }); return { ok: true, json: async () => ({ elements }) }; };
  return { calls, fetchImpl };
}

test('cell keys are validated, bounded and deduplicated', () => {
  assert.deepEqual(parseCells('340:1560,340:1560,341:1560', 12), ['340:1560', '341:1560']);
  for (const bad of ['', 'x', '1:2:3', '1700:0', '0:3600', '-1701:0', 'a:b', Array.from({ length: 13 }, (_, i) => `1:${i}`).join(',')]) {
    assert.throws(() => parseCells(bad, 12), (e) => e.status === 400 && e.code === 'INVALID_CELLS', bad);
  }
  assert.deepEqual(bboxOf('340:1560'), { s: 17, w: 78, n: 17.05, e: 78.05 });
  const q = overpassQuery('340:1560');
  assert.match(q, /\[bbox:17,78,17.05,78.05\]/);
  assert.match(q, /fuel\|charging_station/);
  assert.ok(q.indexOf('fuel|charging_station') < q.indexOf('restaurant'), 'safety places are queried before food');
});

test('compact keeps positions and a tag whitelist only (fuel:* kept, address dropped)', () => {
  const c = compact({ type: 'way', id: 9, center: { lat: 17.123456, lon: 78.654321 }, tags: { name: 'Pump', 'fuel:cng': 'yes', 'addr:street': 'Main', opening_hours: '24/7' } });
  assert.deepEqual(c, { i: 'w9', a: 17.12346, o: 78.65432, t: { name: 'Pump', 'fuel:cng': 'yes', opening_hours: '24/7' } });
  assert.equal(compact({ type: 'node', id: 1, tags: {} }), null);
});

test('a cell is fetched once, then served from memory and from geo_cache after a restart', async () => {
  const repo = memRepo(); const up = overpass();
  const s = new PoiCellService({ repo, url: 'http://overpass.test', fetchImpl: up.fetchImpl, logger: { warn() {} } });
  const a = await s.cells('340:1560');
  assert.equal(up.calls.length, 1);
  assert.equal(a.cells['340:1560'].p.length, 1);
  assert.deepEqual(a.cells['340:1560'].p[0].t, { amenity: 'fuel', name: 'HP', 'fuel:diesel': 'yes' });
  assert.deepEqual(a.pending, []);
  await s.cells('340:1560');
  assert.equal(up.calls.length, 1, 'memory hit');
  assert.equal(s.stats.memHits, 1);
  const s2 = new PoiCellService({ repo, url: 'http://overpass.test', fetchImpl: up.fetchImpl });
  const b = await s2.cells('340:1560');
  assert.equal(up.calls.length, 1, 'durable cache hit, no upstream');
  assert.equal(s2.stats.diskHits, 1);
  assert.equal(b.cells['340:1560'].p[0].i, 'n1');
});

test('expired cells are refetched; stale data is served while upstream fails', async () => {
  let now = 1_000_000; const repo = memRepo();
  let fail = false; const calls = [];
  const fetchImpl = async () => { calls.push(1); if (fail) throw new Error('down'); return { ok: true, json: async () => ({ elements: [{ type: 'node', id: 2, lat: 17.02, lon: 78.02, tags: { amenity: 'police' } }] }) }; };
  const s = new PoiCellService({ repo, url: 'http://o.test', fetchImpl, clock: () => now });
  await s.cells('340:1560');
  now += 8 * 86400000; fail = true;
  const r = await s.cells('340:1560');
  assert.equal(r.cells['340:1560'].stale, true);
  assert.deepEqual(r.pending, ['340:1560']);
  assert.ok(calls.length >= 2);
});

test('upstream budget: at most N new cells per request and per minute; the rest are pending', async () => {
  let now = 5_000_000; const up = overpass();
  const s = new PoiCellService({ repo: memRepo(), url: 'http://o.test', fetchImpl: up.fetchImpl, clock: () => now, maxUpstreamPerRequest: 3, upstreamPerMin: 4 });
  const keys = Array.from({ length: 8 }, (_, i) => `340:${1560 + i}`).join(',');
  const a = await s.cells(keys);
  assert.equal(Object.keys(a.cells).length, 3);
  assert.equal(a.pending.length, 5);
  const b = await s.cells(keys);
  assert.equal(Object.keys(b.cells).length, 4, 'one more fits in this minute');
  assert.equal(up.calls.length, 4);
  now += 61000;
  const c = await s.cells(keys);
  assert.equal(Object.keys(c.cells).length, 7);
});

test('concurrent requests for one cell share a single upstream call', async () => {
  let release; const gate = new Promise((r) => { release = r; }); let calls = 0;
  const fetchImpl = async () => { calls++; await gate; return { ok: true, json: async () => ({ elements: [] }) }; };
  const s = new PoiCellService({ repo: memRepo(), url: 'http://o.test', fetchImpl });
  const p = Promise.all([s.cells('1:1'), s.cells('1:1'), s.cells('1:1')]);
  await new Promise((r) => setImmediate(r)); release();
  const out = await p;
  assert.equal(calls, 1);
  for (const r of out) assert.deepEqual(r.cells['1:1'].p, []);
});

test('memory LRU is bounded', async () => {
  const up = overpass([]);
  const s = new PoiCellService({ repo: memRepo(), url: 'http://o.test', fetchImpl: up.fetchImpl, memMax: 3, upstreamPerMin: 100, maxUpstreamPerRequest: 12 });
  await s.cells('1:1,1:2,1:3,1:4,1:5');
  assert.equal(s.mem.size, 3);
  assert.deepEqual([...s.mem.keys()], ['1:3', '1:4', '1:5']);
});

test('an Overpass error remark is not cached as an empty cell', async () => {
  const repo = memRepo();
  const fetchImpl = async () => ({ ok: true, json: async () => ({ elements: [], remark: 'runtime error: timeout' }) });
  const s = new PoiCellService({ repo, url: 'http://o.test', fetchImpl });
  const r = await s.cells('2:2');
  assert.deepEqual(r.pending, ['2:2']);
  assert.equal(repo.m.size, 0);
});

test('GET /geo/poi-cells: auth, validation, proxy + cache, not configured', async () => {
  const up = overpass();
  process.env.POI_OVERPASS_URL = 'http://overpass.test/api/interpreter';
  let t = await boot({ geoFetch: up.fetchImpl });
  try {
    assert.equal((await t.api('GET', '/geo/poi-cells?cells=340:1560')).status, 401);
    const u = await t.register('Places Rider', 'places-rider@test.example');
    assert.equal((await t.api('GET', '/geo/poi-cells?cells=nope', undefined, u.token)).status, 400);
    const r = await t.api('GET', '/geo/poi-cells?cells=340:1560', undefined, u.token);
    assert.equal(r.status, 200, JSON.stringify(r.json));
    assert.equal(r.json.cells['340:1560'].p[0].t.name, 'HP');
    assert.match(r.headers.get('cache-control') || '', /max-age/);
    await t.api('GET', '/geo/poi-cells?cells=340:1560', undefined, u.token);
    assert.equal(up.calls.filter((c) => c.url.includes('overpass.test')).length, 1, 'second answer from the gateway cache');
  } finally { await t.gw.shutdown(); delete process.env.POI_OVERPASS_URL; }
  const saved = process.env.ESSENTIALS_OVERPASS_URL; delete process.env.ESSENTIALS_OVERPASS_URL;
  t = await boot();
  try {
    const u = await t.register('Places Rider 2', 'places-rider2@test.example');
    const r = await t.api('GET', '/geo/poi-cells?cells=1:1', undefined, u.token);
    assert.equal(r.status, 503); assert.equal(r.json.code, 'PLACES_NOT_CONFIGURED');
  } finally { await t.gw.shutdown(); if (saved !== undefined) process.env.ESSENTIALS_OVERPASS_URL = saved; }
});

test('GET /geo/poi-cells is rate limited per rider', async () => {
  process.env.POI_OVERPASS_URL = 'http://overpass.test/api/interpreter';
  const up = overpass([]);
  const t = await boot({ geoFetch: up.fetchImpl });
  try {
    const u = await t.register('Places Burst', 'places-burst@test.example');
    let limited = 0;
    for (let i = 0; i < 25; i++) {
      const r = await t.api('GET', `/geo/poi-cells?cells=5:${i}`, undefined, u.token);
      if (r.status === 429) limited++;
    }
    assert.ok(limited >= 1, 'burst over the per-minute limit is refused');
  } finally { await t.gw.shutdown(); delete process.env.POI_OVERPASS_URL; }
});
