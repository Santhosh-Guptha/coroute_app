'use strict';
/**
 * Round 7: road-geometry cells (src/road_cells.js): cell build from an Overpass fixture, cache / TTL / stale,
 * upstream budget + backoff + concurrency, memory bound, the cell API (authz, gzip, ETag, 202 pending),
 * "wrong limit" votes (k-min, never upward, consent) and the admin list.
 */
process.env.NODE_ENV = 'test';
process.env.ADMIN_EMAILS = 'roads.admin@coroute.test';
process.env.ROAD_CELLS_OVERPASS_URL = 'http://overpass.test/api/interpreter';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('zlib');
const fixture = require('./fixtures/overpass_roads_cell.json');
const { RoadCellService, buildCell, overpassQuery, decideCorrection, numericKmh, simplify, CLASSES, MOTORCYCLE_MAX_KMH } = require('../src/road_cells');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { boot } = require('./_helpers');

const CELL = 'tepffh';
function memRepo() {
  const m = new Map();
  return { m, geoCacheGet: async (k) => m.get(k) || null, geoCachePut: async (k, value) => { m.set(k, { k, value }); } };
}
function upstream({ status = 200, elements = fixture.elements, delay = 0 } = {}) {
  const u = { calls: [], status, elements, running: 0, maxRunning: 0 };
  u.fetchImpl = async (url, init) => {
    u.calls.push({ url, headers: init.headers, body: decodeURIComponent(String(init.body).slice(5)) });
    u.running++; u.maxRunning = Math.max(u.maxRunning, u.running);
    if (delay) await new Promise((r) => setTimeout(r, delay));
    u.running--;
    return { ok: u.status === 200, status: u.status, json: async () => ({ elements: u.elements }) };
  };
  return u;
}
const decodeLine = (g) => { const out = []; let a = 0, o = 0; for (let i = 0; i < g.length; i += 2) { a += g[i]; o += g[i + 1]; out.push([a / 1e5, o / 1e5]); } return out; };

test('the Overpass query is one bounded request: road classes, zones, two counts, timeout and maxsize', () => {
  const q = overpassQuery(CELL);
  assert.match(q, /^\[out:json\]\[timeout:25\]\[maxsize:\d+\]\[bbox:17\.37887,78\.48483,17\.38736,78\.49881\];/);
  assert.match(q, /way\["highway"~"\^\(motorway\|trunk\|primary/);
  assert.match(q, /out tags geom qt 1500;/);
  assert.match(q, /school\|college\|kindergarten\|hospital/);
  assert.equal((q.match(/out count;/g) || []).length, 2);
});

test('cell build from the fixture: classes, tags, one-way, clipping, zones, urban hint; unusable roads dropped', () => {
  const doc = buildCell(CELL, fixture.elements);
  assert.equal(doc.v, 1); assert.equal(doc.c, CELL);
  const ids = doc.w.map((w) => w.i);
  assert.deepEqual(ids, [1003, 1001, 1007, 1002], 'most important class first; parking aisle, private road and footway are not there');
  const ghat = doc.w.find((w) => w.i === 1001);
  assert.equal(CLASSES[ghat.h], 'primary'); assert.equal(ghat.ms, '40'); assert.equal(ghat.n, 'Ghat Road'); assert.equal(ghat.lit, 1); assert.equal(ghat.ln, 2);
  const line = decodeLine(ghat.g);
  assert.deepEqual(line[0], [17.385, 78.486]);
  assert.equal(line.length, 5, 'the straight middle point is simplified away, the bend points stay');
  const nh = doc.w.find((w) => w.i === 1003);
  assert.equal(nh.ow, 1); assert.equal(nh.ms, '100'); assert.equal(nh.mt, 'sign'); assert.equal(nh.n, 'NH 44');
  assert.equal(doc.w.find((w) => w.i === 1002).ow, 1);
  const sec = doc.w.find((w) => w.i === 1007);
  assert.equal(sec.mt, 'IN:urban'); assert.equal(sec.ms, undefined);
  assert.equal(decodeLine(sec.g).length, 2, 'clipped at the cell margin: one point outside is kept, the far one is cut');
  assert.deepEqual(doc.z, [[1738570, 7848660, 's'], [1738620, 7848690, 'h']]);
  assert.deepEqual(doc.u, { b: 240, lu: 2 });
  assert.deepEqual(doc.fx, {});
  assert.ok(JSON.stringify(doc).length < 1200, 'compact');
});

test('helpers: numeric limits only, Douglas-Peucker keeps a hairpin', () => {
  assert.equal(numericKmh('50'), 50); assert.equal(numericKmh('30 mph'), 48); assert.equal(numericKmh('IN:urban'), null);
  assert.equal(numericKmh('none'), null); assert.equal(numericKmh('60;40'), 60); assert.equal(numericKmh('400'), null);
  const hairpin = [];
  for (let i = 0; i <= 18; i++) { const a = (i * 10) * Math.PI / 180; hairpin.push([17 + 0.00015 * Math.sin(a), 78 + 0.00015 * (1 - Math.cos(a))]); }
  const s = simplify(hairpin, 2);
  assert.ok(s.length >= 5 && s.length < hairpin.length, `${s.length} points keep the arc`);
});

test('cache: one upstream call, then memory, then geo_cache; refreshed after the TTL and served stale meanwhile', async () => {
  let now = 1_800_000_000_000; const repo = memRepo(); const up = upstream();
  const s = new RoadCellService({ repo, url: 'http://o.test', fetchImpl: up.fetchImpl, clock: () => now, env: {} });
  const a = await s.cell(CELL);
  assert.equal(a.status, 'ok'); assert.equal(up.calls.length, 1);
  assert.match(up.calls[0].headers['User-Agent'], /^CoRoute\/\d/);
  assert.equal((await s.cell(CELL)).etag, a.etag); assert.equal(up.calls.length, 1); assert.equal(s.stats.memHits, 1);
  // Another node (empty memory) reads the stored copy: no upstream call.
  const s2 = new RoadCellService({ repo, url: 'http://o.test', fetchImpl: up.fetchImpl, clock: () => now, env: {} });
  assert.equal((await s2.cell(CELL)).etag, a.etag); assert.equal(up.calls.length, 1); assert.equal(s2.stats.diskHits, 1);
  // 29 days: still fresh. 31 days: the old answer now (stale), a refresh in the background.
  now += 29 * 86400000; await s.cell(CELL); assert.equal(up.calls.length, 1);
  now += 2 * 86400000;
  const old = await s.cell(CELL);
  assert.equal(old.stale, true); assert.equal(old.etag, a.etag);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(up.calls.length, 2);
  const fresh = await s.cell(CELL);
  assert.equal(fresh.stale, undefined); assert.equal(fresh.at, now);
  await assert.rejects(() => s.cell('zzzzzzz'), (e) => e.status === 400 && e.code === 'INVALID_CELL');
  await assert.rejects(() => s.cell('aaaaaa'), (e) => e.status === 400);
  const none = new RoadCellService({ repo: memRepo(), url: null, env: {} });
  await assert.rejects(() => none.cell(CELL), (e) => e.status === 503 && e.code === 'ROADS_NOT_CONFIGURED');
});

test('rate limit, backoff and concurrency: over budget answers pending, never a busy loop', async () => {
  let now = 1_800_000_000_000;
  const cells = ['tepffh', 'tepffj', 'tepffk', 'tepffm', 'tepffn'];
  const up = upstream();
  const s = new RoadCellService({ repo: memRepo(), url: 'http://o.test', fetchImpl: up.fetchImpl, clock: () => now, env: {}, perMin: 2, perDay: 3 });
  assert.equal((await s.cell(cells[0])).status, 'ok');
  assert.equal((await s.cell(cells[1])).status, 'ok');
  const p = await s.cell(cells[2]);
  assert.equal(p.status, 'pending'); assert.ok(p.retryAfterS >= 1 && p.retryAfterS <= 60); assert.equal(up.calls.length, 2);
  now += 61000;
  assert.equal((await s.cell(cells[2])).status, 'ok');
  now += 61000;
  const day = await s.cell(cells[3]);
  assert.equal(day.status, 'pending'); assert.equal(day.retryAfterS, 3600, 'the daily budget is spent');
  assert.equal(up.calls.length, 3);

  // Backoff: a refusal (429) stops upstream calls for 30 s, then 60 s, ... (at most 15 min).
  now = 1_900_000_000_000;
  const bad = upstream({ status: 429 });
  const b = new RoadCellService({ repo: memRepo(), url: 'http://o.test', fetchImpl: bad.fetchImpl, clock: () => now, env: {} });
  const r1 = await b.cell(cells[0]);
  assert.equal(r1.status, 'pending'); assert.equal(r1.retryAfterS, 30);
  assert.equal((await b.cell(cells[1])).status, 'pending'); assert.equal(bad.calls.length, 1, 'no call during the backoff');
  now += 31000;
  assert.equal((await b.cell(cells[1])).retryAfterS, 60); assert.equal(bad.calls.length, 2);
  for (let i = 0; i < 8; i++) { now += 16 * 60000; await b.cell(cells[2]); }
  assert.ok(b.backoffUntil - now <= 15 * 60000);
  bad.status = 200; now += 16 * 60000;
  assert.equal((await b.cell(cells[3])).status, 'ok'); assert.equal(b.fails, 0);

  // Concurrency: one upstream call at a time per node; the same cell asked twice shares one call.
  const slow = upstream({ delay: 30 });
  const c = new RoadCellService({ repo: memRepo(), url: 'http://o.test', fetchImpl: slow.fetchImpl, clock: Date.now, env: {} });
  const out = await Promise.all([c.cell(cells[0]), c.cell(cells[0]), c.cell(cells[1])]);
  assert.equal(slow.maxRunning, 1);
  assert.deepEqual(out.map((x) => x.status), ['ok', 'ok', 'pending']);
  assert.equal(slow.calls.length, 1);
});

test('memory bound: the cache holds at most ROAD_CELLS_MEM_MB of gzip bytes (LRU)', async () => {
  const up = upstream();
  const s = new RoadCellService({ repo: memRepo(), url: 'http://o.test', fetchImpl: up.fetchImpl, env: {}, memBytes: 1500, perMin: 60 });
  const B = '0123456789bcdefghjkmnpqrstuvwxyz';
  for (let i = 0; i < 20; i++) assert.equal((await s.cell(`tepf${B[i]}h`)).status, 'ok');
  assert.ok(s.memUsed <= 1500, `${s.memUsed} bytes`);
  assert.ok(s.mem.size >= 1 && s.mem.size < 20);
  assert.equal([...s.mem.values()].reduce((n, v) => n + v.gz.length, 0), s.memUsed, 'the byte count is exact');
  assert.ok(s.mem.has('tepfmh'), 'the newest cell stays');
  const big = Array.from({ length: 3000 }, (_, i) => ({ type: 'way', id: 5000 + i, tags: { highway: 'residential' },
    geometry: Array.from({ length: 12 }, (_, k) => ({ lat: 17.381 + (i % 50) * 0.00008 + k * 0.00001 * (k % 2), lon: 78.487 + k * 0.0006 + (i % 7) * 0.00001 })) }));
  const doc = buildCell(CELL, big);
  assert.ok(doc.w.length <= 1200 && doc.tr === 1, 'ways are capped and the cut is marked');
  assert.ok(doc.w.reduce((n, w) => n + w.g.length / 2, 0) <= 14000);
});

test('votes: k distinct riders, a tie takes the lower value, never raises a tagged limit, never above the motorcycle maximum', () => {
  const v = (h, kmh) => ({ h, kmh });
  assert.equal(decideCorrection([v('a', 40), v('b', 40)], null, 3), null, 'two riders are not enough');
  assert.equal(decideCorrection([v('a', 40), v('b', 40), v('c', 40)], null, 3), 40);
  assert.equal(decideCorrection([v('a', 40), v('a', 40), v('a', 40)], null, 3), null, 'one rider voting three times is one rider');
  assert.equal(decideCorrection([v('a', 40), v('b', 40), v('c', 40)], null, 1), 40, 'k is never below 3');
  assert.equal(decideCorrection([v('a', 40), v('b', 40)], null, 1), null);
  assert.equal(decideCorrection([v('a', 50), v('b', 50), v('c', 50), v('d', 30), v('e', 30), v('f', 30)], null, 3), 30);
  assert.equal(decideCorrection([v('a', 60), v('b', 60), v('c', 60)], 40, 3), null, 'never upward over an OSM tag');
  assert.equal(decideCorrection([v('a', 40), v('b', 40), v('c', 40)], 40, 3), null);
  assert.equal(decideCorrection([v('a', 30), v('b', 30), v('c', 30)], 40, 3), 30, 'downward is allowed');
  assert.equal(decideCorrection([v('a', 100), v('b', 100), v('c', 100)], null, 3), null);
  assert.equal(MOTORCYCLE_MAX_KMH, 80);
  assert.equal(decideCorrection([v('a', 42), v('b', 42), v('c', 42)], null, 3), null, 'not a multiple of 5');
});

// ------------------------------------------------------------------ HTTP
let env, up, riders = [], admin;
before(async () => {
  up = upstream();
  env = await boot({ geoFetch: up.fetchImpl });
  for (let i = 0; i < 4; i++) { const j = await env.register(`Road Rider ${i}`, `roads.r${i}@coroute.test`); riders.push({ token: j.token, userId: (j.user || j).userId }); }
  admin = await env.register('Roads Admin', 'roads.admin@coroute.test');
});
after(async () => { await env.gw.shutdown(); });

const raw = (path, token, headers = {}) => fetch(`${env.base}${path}`, { headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers } });

test('GET /api/geo/roads: sign-in needed, gzip, ETag / 304, plain JSON for a client without gzip, 400 for a bad cell', async () => {
  assert.equal((await raw(`/geo/roads?cell=${CELL}`)).status, 401);
  assert.equal((await raw('/geo/roads?cell=nope', riders[0].token)).status, 400);
  const res = await raw(`/geo/roads?cell=${CELL}`, riders[0].token, { 'Accept-Encoding': 'gzip' });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-encoding'), 'gzip');
  assert.match(res.headers.get('cache-control'), /private, max-age=86400/);
  const etag = res.headers.get('etag');
  assert.match(etag, /^"r1-/);
  const doc = await res.json();
  assert.equal(doc.c, CELL); assert.equal(doc.w.length, 4);
  // The stored copy is gzip (base64) under roads:v1:<cell>.
  const stored = await env.gw.repo.geoCacheGet(`roads:v1:${CELL}`);
  assert.equal(JSON.parse(zlib.gunzipSync(Buffer.from(stored.value.gz, 'base64')).toString()).c, CELL);
  const not = await raw(`/geo/roads?cell=${CELL}`, riders[1].token, { 'If-None-Match': etag });
  assert.equal(not.status, 304);
  const plain = await raw(`/geo/roads?cell=${CELL}`, riders[1].token, { 'Accept-Encoding': 'identity' });
  assert.equal(plain.headers.get('content-encoding'), null);
  assert.equal((await plain.json()).c, CELL);
  assert.equal(up.calls.length, 1, 'three riders, one upstream call');
  const health = await env.api('GET', '/health');
  assert.equal(health.json.roads.configured, true); assert.equal(health.json.roads.memCells, 1);
});

test('GET /api/geo/roads: 202 pending with Retry-After while Overpass refuses (the phone stays silent)', async () => {
  up.status = 504;
  const res = await raw('/geo/roads?cell=tepffj', riders[0].token);
  assert.equal(res.status, 202);
  assert.equal(res.headers.get('retry-after'), '30');
  assert.deepEqual(await res.json(), { pending: true, retryAfterS: 30 });
  up.status = 200; env.gw.roadCells.backoffUntil = 0; env.gw.roadCells.fails = 0;
});

test('wrong-limit votes over HTTP: consent, k = 3, the cell gets the correction and a new ETag; admin list and reject', async () => {
  const vote = (r, body) => env.api('POST', '/geo/limit-corrections', body, r.token);
  // 1002 (Colony Lane) has no tag: the phone showed an estimate.
  const body = { way: 1002, cell: CELL, kmh: 20, shownKmh: 30, shownSource: 'estimate' };
  const no = await vote(riders[0], body);
  assert.equal(no.status, 202); assert.deepEqual(no.json, { accepted: false, reason: 'NO_CONSENT' });
  for (const r of riders) await env.gw.intel.consent.set(r.userId, true);
  assert.equal((await vote(riders[0], { ...body, kmh: 22 })).status, 400);
  assert.equal((await vote(riders[0], { ...body, way: 999999 })).status, 404);
  assert.equal((await env.api('POST', '/geo/limit-corrections', body)).status, 401);
  const before = (await raw(`/geo/roads?cell=${CELL}`, riders[0].token)).headers.get('etag');
  assert.equal((await vote(riders[0], body)).json.applied, null);
  assert.equal((await vote(riders[0], body)).json.riders, 1, 'a second vote of the same rider replaces the first');
  assert.equal((await vote(riders[1], body)).json.applied, null);
  const third = await vote(riders[2], body);
  assert.equal(third.json.applied, 20);
  const res = await raw(`/geo/roads?cell=${CELL}`, riders[3].token);
  assert.notEqual(res.headers.get('etag'), before);
  assert.deepEqual((await res.json()).fx, { 1002: 20 });
  // 1001 is tagged 40: three riders saying 60 change nothing; three saying 30 lower it.
  for (const r of riders.slice(0, 3)) await vote(r, { way: 1001, cell: CELL, kmh: 60, shownKmh: 40, shownSource: 'osm' });
  assert.deepEqual((await (await raw(`/geo/roads?cell=${CELL}`, riders[3].token)).json()).fx, { 1002: 20 });
  for (const r of riders.slice(0, 3)) await vote(r, { way: 1001, cell: CELL, kmh: 30 });
  assert.deepEqual((await (await raw(`/geo/roads?cell=${CELL}`, riders[3].token)).json()).fx, { 1001: 30, 1002: 20 });
  // The stored votes hold a keyed hash, never the rider id.
  const docs = await env.soda.query('road_limit_votes', {}, { limit: 10 });
  assert.equal(docs.length, 2);
  assert.ok(!JSON.stringify(docs).includes(riders[0].userId));

  assert.equal((await env.api('GET', '/admin/geo/limit-corrections', null, riders[0].token)).status, 403);
  const list = await env.api('GET', '/admin/geo/limit-corrections', null, admin.token);
  assert.equal(list.status, 200);
  const row = list.json.items.find((x) => x.way === 1001);
  assert.equal(row.status, 'applied'); assert.equal(row.applied, 30); assert.equal(row.tagKmh, 40); assert.deepEqual(row.values, { 30: 3 });
  assert.equal((await env.api('POST', '/admin/geo/limit-corrections/1001', { action: 'apply', kmh: 60 }, admin.token)).status, 409, 'not even an admin raises a tagged limit');
  const rej = await env.api('POST', '/admin/geo/limit-corrections/1001', { action: 'reject' }, admin.token);
  assert.equal(rej.json.status, 'rejected');
  assert.deepEqual((await (await raw(`/geo/roads?cell=${CELL}`, riders[3].token)).json()).fx, { 1002: 20 });
  // A rebuild from Overpass keeps the correction that still holds.
  env.gw.roadCells.mem.clear(); env.gw.roadCells.memUsed = 0; await env.gw.repo.geoCachePut(`roads:v1:${CELL}`, null);
  assert.deepEqual((await (await raw(`/geo/roads?cell=${CELL}`, riders[3].token)).json()).fx, { 1002: 20 });
  // Account deletion removes the rider's vote: two riders left, the correction goes.
  await env.gw.roadCells.forgetRider(riders[2].userId);
  assert.deepEqual((await (await raw(`/geo/roads?cell=${CELL}`, riders[3].token)).json()).fx, {});
});
