'use strict';
/**
 * Round 4 intelligence, hazard hotspots (feature 6), road quality (7) and dangerous times (17):
 * severity weights, direction-aware cells, the score threshold, SOS / crash alerts as signals, the API (bbox, tiles,
 * gzip, caching), dangerous-time windows and the pre-ride tip.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'hz.admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('zlib');
const gh = require('../src/intel/geohash');
const M = require('../src/intel/math');
const { makeEngine, ride, consentAll } = require('./_intel_helpers');
const { boot } = require('./_helpers');

async function send(env, ids, ev) {
  await consentAll(env, ids);
  for (const id of ids) await env.engine.ingestEvents(id, [{ ts: env.clock.now, ...ev }]);
  await env.engine.flushRaw();
}
const ids = (p, n) => Array.from({ length: n }, (_, i) => `${p}${i}`);

test('geohash: encode / bbox / cover round trip', () => {
  const h = gh.encode(12.9716, 77.5946, 7);
  const b = gh.bbox(h);
  assert.ok(b.s <= 12.9716 && b.n >= 12.9716 && b.w <= 77.5946 && b.e >= 77.5946);
  assert.equal(gh.encode(57.64911, 10.40744, 11), 'u4pruydqqvj', 'reference value');
  const cover = gh.cover({ s: 12.9, w: 77.5, n: 13.1, e: 77.8 }, 4, 64);
  assert.ok(cover.includes(h.slice(0, 4)));
  assert.equal(gh.cover({ s: 5, w: 67, n: 38, e: 99 }, 4, 64), null, 'too big for one request');
});

test('severity weights: crash and SOS outrank hard brakes; the threshold hides weak cells', async () => {
  const env = makeEngine();
  const a = gh.encode(12.97, 77.59, 7), b = gh.encode(12.99, 77.61, 7);
  await send(env, ids('a', 5), { type: 'hard_brake', gh: a, hb: 0 });
  await send(env, ids('b', 5), { type: 'swerve', gh: b, hb: 0 });
  await env.engine.aggregate();
  const area = { tiles: [a.slice(0, 4)] };
  const list = await env.engine.hazards(area, { minScore: 0, admin: true });
  const ca = list.find((c) => c.gh === a), cb = list.find((c) => c.gh === b);
  assert.equal(ca.rawScore, 5);
  assert.equal(cb.rawScore, 10, 'swerve weighs 2');
  assert.equal(list[0].gh, b, 'sorted by score');
  const pub = await env.engine.hazards(area, { minScore: 6 });
  assert.deepEqual(pub.map((c) => c.gh), [b], 'below the threshold: hidden');
  assert.equal(pub[0].kind, 'swerve');
  assert.equal(pub[0].level, 'high');
});

test('direction aware: a cell remembers which way riders were going', async () => {
  const env = makeEngine();
  const a = gh.encode(12.97, 77.59, 7);
  await send(env, ids('n', 6), { type: 'hard_brake', gh: a, hb: 0 }); // northbound
  await send(env, ids('s', 1), { type: 'hard_brake', gh: a, hb: 4 });
  await env.engine.aggregate();
  const [c] = await env.engine.hazards({ tiles: [a.slice(0, 4)] }, { minScore: 0 });
  assert.deepEqual(c.dirs, [0], 'mostly northbound');
  assert.equal(M.headingBucket(350), 0);
  assert.equal(M.headingBucket(181), 4);
  assert.equal(M.headingBucket(-5), -1);
});

test('SOS and crash alerts of consenting riders on a trimmed ride become hazard signals; reports by others do not', async () => {
  const env = makeEngine();
  await consentAll(env, ['r1', 'r2']);
  const end = ride(env, { userId: 'r1', legs: [{ deg: 90, km: 3, kmh: 40 }] });
  env.engine.onEmergency('G1', { userId: 'r1', lat: end.lat, lng: end.lng, source: 'CRASH_AUTO', heading: 90, speedKmh: 40 }, 'RAISED');
  env.engine.onEmergency('G1', { userId: 'r1', lat: end.lat, lng: end.lng, source: 'MEMBER_REPORT' }, 'RAISED');
  env.engine.onEmergency('G1', { userId: 'r1', lat: end.lat, lng: end.lng, source: 'MANUAL' }, 'RESOLVED');
  // r2 raises SOS 100 m from where their ride started: inside the start trim, not counted.
  ride(env, { userId: 'r2', gid: 'G2', start: { lat: 13.1, lng: 77.7 }, legs: [{ deg: 0, km: 0.1, kmh: 20 }] });
  env.engine.onEmergency('G2', { userId: 'r2', lat: 13.1, lng: 77.7, source: 'MANUAL' }, 'RAISED');
  await env.engine.flushRaw();
  const rows = await env.soda.query('intel_raw', { k: 'evs' }, { limit: 10 });
  assert.equal(rows.length, 1);
  const [ty, g7, hb, sb] = rows[0].value.d.e[0];
  assert.deepEqual([ty, hb, sb], ['crash', 2, 2]);
  assert.equal(g7, gh.encode(end.lat, end.lng, 7));
});

test('road quality: potholes and rough road go to their own layer; hazards do not include them', async () => {
  const env = makeEngine();
  const a = gh.encode(12.97, 77.59, 7);
  await send(env, ids('p', 5), { type: 'pothole', gh: a, hb: 2, conf: 0.9 });
  await env.engine.aggregate();
  const area = { tiles: [a.slice(0, 4)] };
  assert.equal((await env.engine.hazards(area, { minScore: 0 })).length, 0);
  const rq = await env.engine.roadQuality(area, { minScore: 0 });
  assert.equal(rq.length, 1);
  assert.equal(rq[0].kind, 'pothole');
  assert.deepEqual(rq[0].dirs, [2]);
});

test('dangerous times: region x hour windows and the pre-ride tip (no weather)', async () => {
  const env = makeEngine();
  const evening = Date.UTC(2026, 10, 10, 12, 45); // Tue 18:15 IST
  const a = gh.encode(12.97, 77.59, 7);
  env.clock.now = evening + 2 * 3600000;
  await consentAll(env, ids('d', 6));
  for (const id of ids('d', 6)) {
    await env.engine.ingestEvents(id, [{ type: 'hard_brake', gh: a, hb: 1, ts: evening }, { type: 'hard_brake', gh: gh.encode(12.98, 77.6, 7), hb: 1, ts: evening + 3600000 }]);
  }
  await env.engine.consent.set('m0', true);
  await env.engine.ingestEvents('m0', [{ type: 'hard_brake', gh: a, hb: 1, ts: Date.UTC(2026, 10, 10, 3, 30) }]); // 09:00
  await env.engine.flushRaw();
  await env.engine.aggregate();
  const list = await env.engine.dangerousTimes();
  assert.equal(list.length, 1);
  assert.equal(list[0].region, a.slice(0, 4));
  assert.deepEqual([list[0].window.dayType, list[0].window.from, list[0].window.to], ['weekday', 18, 20]);
  assert.ok(list[0].window.share > 80);
  env.clock.now = evening + 10 * 60000;
  const tip = await env.engine.rideTip(12.97, 77.59);
  assert.equal(tip.tip, 'Evening rides here see more hard braking. Ride safe.');
  env.clock.now = Date.UTC(2026, 10, 11, 6, 30); // noon next day
  assert.equal(await env.engine.rideTip(12.97, 77.59), null, 'quiet hour: no tip');
  assert.equal(await env.engine.rideTip(28.6, 77.2), null, 'other region: no tip');
});

test('gateway API: bbox / tiles validation, k-min applied, gzip, CSV export for admins', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown().catch(() => {}));
  const admin = await env.register('Hz Admin', 'hz.admin@coroute.test');
  const intel = env.gw.intel;
  const cells = [];
  for (let i = 0; i < 40; i++) cells.push(gh.encode(12.9 + i * 0.002, 77.55 + i * 0.002, 7));
  for (let r = 0; r < 6; r++) {
    await intel.consent.set(`fake${r}`, true);
    await intel.ingestEvents(`fake${r}`, cells.map((g) => ({ type: 'hard_brake', gh: g, hb: 1, ts: Date.now() })).slice(0, 40));
  }
  // 3 per cell per batch max: each rider gave one event per cell here.
  await intel.flushRaw();
  await intel.aggregate();

  let r = await env.api('GET', '/intel/hazards?bbox=12.8,77.4,13.1,77.8', null, admin.token);
  assert.equal(r.status, 200);
  assert.equal(r.json.kMin, 5);
  assert.equal(r.json.cells.length, 40);
  assert.ok(r.json.cells.every((c) => c.riders === undefined && c.counts === undefined));
  r = await env.api('GET', `/intel/hazards?tiles=${cells[0].slice(0, 4)}`, null, admin.token);
  assert.equal(r.json.cells.length, 40);
  assert.equal((await env.api('GET', '/intel/hazards', null, admin.token)).status, 400);
  assert.equal((await env.api('GET', '/intel/hazards?bbox=5,67,38,99', null, admin.token)).status, 400, 'all of India in one ask: refused');
  assert.equal((await env.api('GET', '/intel/hazards?bbox=12,77,13,78')).status, 401);

  // gzip
  const res = await fetch(`${env.base}/intel/hazards?bbox=12.8,77.4,13.1,77.8`, { headers: { Authorization: `Bearer ${admin.token}`, 'Accept-Encoding': 'gzip' } });
  assert.equal(res.headers.get('content-encoding'), 'gzip');
  const raw = Buffer.from(await res.arrayBuffer());
  // fetch decodes gzip itself; either way the body is JSON.
  const text = raw[0] === 0x1f ? zlib.gunzipSync(raw).toString() : raw.toString();
  assert.equal(JSON.parse(text).cells.length, 40);

  // Admin: list with counts, filters and CSV.
  r = await env.api('GET', '/admin/intel/hazards', null, admin.token);
  assert.equal(r.json.cells.length, 40);
  assert.equal(r.json.cells[0].riders, 6);
  r = await env.api('GET', '/admin/intel/hazards?type=crash', null, admin.token);
  assert.equal(r.json.cells.length, 0);
  const csv = await fetch(`${env.base}/admin/intel/hazards?format=csv`, { headers: { Authorization: `Bearer ${admin.token}` } });
  assert.match(csv.headers.get('content-type'), /text\/csv/);
  const lines = (await csv.text()).trim().split('\n');
  assert.equal(lines[0], 'gh,lat,lng,kind,level,score,rawScore,riders,counts,dirs,updatedAt');
  assert.equal(lines.length, 41);
  r = await env.api('GET', '/intel/info');
  assert.equal(r.status, 200);
  assert.match(r.json.weather, /not used/);
});
