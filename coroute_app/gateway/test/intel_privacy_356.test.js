'use strict';
/**
 * Round 4 intelligence, privacy base (docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md §Privacy):
 * consent gating, ride trimming (first / last 300 m, privacy zones), k-anonymity (INTEL_K_MIN), decay, retention purge,
 * delete / export my contributions, account erase, and admin authorisation.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'intel.admin@coroute.test';
delete process.env.INTEL_K_MIN;

const test = require('node:test');
const assert = require('node:assert/strict');
const { RideTrimmer, riderHash } = require('../src/intel/privacy');
const M = require('../src/intel/math');
const gh = require('../src/intel/geohash');
const { makeEngine, ride, consentAll, move, T0 } = require('./_intel_helpers');
const { boot } = require('./_helpers');

const RAW = 'intel_raw';
const all = async (soda, c, f = {}) => soda.query(c, f, { limit: 10000 });

/** n consenting riders each send one hard brake at the same cell. */
async function brakes(env, n, { g7 = 'tdr1y4b', prefix = 'u', ts } = {}) {
  const ids = Array.from({ length: n }, (_, i) => `${prefix}${i}`);
  await consentAll(env, ids);
  for (const id of ids) await env.engine.ingestEvents(id, [{ type: 'hard_brake', gh: g7, hb: 2, sb: 3, ts: ts || env.clock.now }]);
  await env.engine.flushRaw();
  return ids;
}

test('consent gating: nothing is stored without "Help make roads safer"; switching it off stops collection', async () => {
  const env = makeEngine();
  const r1 = await env.engine.ingestEvents('nobody', [{ type: 'hard_brake', gh: 'tdr1y4b', hb: 1, ts: env.clock.now }]);
  assert.deepEqual(r1, { accepted: 0, reason: 'NO_CONSENT' });
  ride(env, { userId: 'nobody', legs: [{ deg: 90, km: 3, kmh: 40 }] });
  env.engine.onRoomEnded('G1');
  await env.engine.flushRaw();
  assert.equal((await all(env.soda, RAW)).length, 0, 'no consent: no raw rows at all');
  assert.equal(env.engine.acc.size, 0);

  await env.engine.consent.set('yes', true);
  assert.equal((await env.engine.ingestEvents('yes', [{ type: 'hard_brake', gh: 'tdr1y4b', hb: 1, ts: env.clock.now }])).accepted, 1);
  await env.engine.flushRaw();
  const rows = await all(env.soda, RAW);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].value.rh, riderHash(env.engine.key, 'yes', M.monthKey(env.clock.now)), 'stored under the monthly hash');
  assert.ok(!JSON.stringify(rows[0].value).includes('"yes"'), 'never the rider id');

  // Off mid-ride: the open ride counters are discarded, no ride row appears.
  ride(env, { userId: 'yes', gid: 'G2', legs: [{ deg: 0, km: 2, kmh: 40 }] });
  assert.equal(env.engine.acc.size, 1);
  await env.engine.consent.set('yes', false);
  ride(env, { userId: 'yes', gid: 'G2', legs: [{ deg: 0, km: 0.5, kmh: 40 }] });
  assert.equal(env.engine.acc.size, 0, 'consent off: accumulator dropped at the next fix');
  env.engine.onRoomEnded('G2');
  await env.engine.flushRaw();
  assert.equal((await all(env.soda, RAW)).filter((r) => r.value.k === 'ride').length, 0);
});

test('consent is per rider and recorded with time and history; the one-time prompt is remembered', async () => {
  const env = makeEngine();
  assert.deepEqual(await env.engine.consent.view('r1'), { on: false, at: null, promptedAt: null, source: null }, 'off by default');
  await env.engine.consent.set('r1', true, { source: 'prompt', prompted: true });
  env.clock.now += 1000;
  await env.engine.consent.set('r1', false, { source: 'web' });
  const v = await env.engine.consent.view('r1');
  assert.equal(v.on, false);
  assert.equal(v.source, 'web');
  assert.equal(v.promptedAt, T0, 'the prompt time stays');
  const doc = (await env.soda.findOne('intel_consent', { userId: 'r1' })).value;
  assert.deepEqual(doc.history.map((h) => [h.on, h.source]), [[true, 'prompt'], [false, 'web']]);
  assert.deepEqual(await env.engine.consent.counts(), { on: 0, off: 1, total: 1 });
});

test('trimming: first and last 300 m of a ride are never counted; privacy zones are skipped', () => {
  const t = new RideTrimmer({ trimM: 300 });
  const start = { lat: 12.9, lng: 77.6 };
  const out = [];
  let p = start;
  for (let i = 0; i <= 100; i++) { // 2 km north in 20 m steps
    out.push(...t.push({ ...p, t: i }));
    p = move(p.lat, p.lng, 0, 20);
  }
  const dropped = t.finish();
  assert.ok(out.length > 0);
  for (const q of out) assert.ok(M.haversine(start.lat, start.lng, q.lat, q.lng) >= 300, 'nothing within 300 m of the start');
  const end = p;
  for (const q of out) assert.ok(M.haversine(end.lat, end.lng, q.lat, q.lng) >= 300 - 20, 'nothing within the last 300 m');
  assert.ok(dropped >= 14, 'the held last 300 m are thrown away at the end');

  const home = move(start.lat, start.lng, 0, 1000);
  const z = new RideTrimmer({ trimM: 300, zones: [home] });
  const out2 = [];
  p = start;
  for (let i = 0; i <= 150; i++) { out2.push(...z.push({ ...p, t: i })); p = move(p.lat, p.lng, 0, 20); }
  assert.ok(out2.length > 0);
  for (const q of out2) assert.ok(M.haversine(home.lat, home.lng, q.lat, q.lng) >= 300, 'nothing within 300 m of a privacy zone');
  assert.equal(z.allowed(home.lat, home.lng), false);
});

test('trimming on the gateway: a ride shorter than 600 m contributes nothing; a longer one only its middle', async () => {
  const env = makeEngine();
  await consentAll(env, ['a']);
  ride(env, { userId: 'a', legs: [{ deg: 90, km: 0.55, kmh: 30 }] });
  env.engine.onRoomEnded('G1');
  await env.engine.flushRaw();
  assert.equal((await all(env.soda, RAW)).length, 0);

  const start = { lat: 13.0, lng: 77.5 };
  const end = ride(env, { userId: 'a', gid: 'G3', start, legs: [{ deg: 90, km: 5, kmh: 40 }] });
  env.engine.onRoomEnded('G3');
  await env.engine.flushRaw();
  const rows = await all(env.soda, RAW, { k: 'ride' });
  assert.equal(rows.length, 1);
  const dist = rows[0].value.d.c.reduce((s, c) => s + c[2], 0);
  assert.ok(dist > 3500 && dist < 4500, `about 5 km - 2 x 300 m counted (${dist})`);
  for (const c of rows[0].value.d.c) {
    const b = gh.bbox(c[0]);
    assert.ok(b.e > start.lng - 0.01 && b.w < end.lng + 0.01);
  }
});

test('k-anonymity: a hotspot shows only once INTEL_K_MIN (5) distinct riders contributed', async () => {
  const env = makeEngine();
  const area = { bbox: { s: 12.5, w: 77.2, n: 13.5, e: 78.2 } };
  const g7 = gh.encode(12.97, 77.59, 7);
  await brakes(env, 4, { g7 });
  // The same rider many times does not count as more riders.
  for (let i = 0; i < 5; i++) await env.engine.ingestEvents('u0', [{ type: 'hard_brake', gh: g7, hb: 2, ts: env.clock.now }]);
  await env.engine.aggregate();
  assert.equal((await env.engine.hazards(area, { minScore: 0 })).length, 0, '4 riders: hidden');
  await brakes(env, 1, { g7, prefix: 'v' });
  await env.engine.aggregate();
  const cells = await env.engine.hazards(area, { minScore: 0 });
  assert.equal(cells.length, 1, '5 riders: shown');
  assert.equal(cells[0].gh, g7);
  assert.equal(cells[0].riders, undefined, 'public answers carry no rider counts');

  process.env.INTEL_K_MIN = '8';
  env.engine.cache.clear();
  assert.equal((await env.engine.hazards(area, { minScore: 0 })).length, 0, 'configurable k-min');
  delete process.env.INTEL_K_MIN;
});

test('distinct counting uses monthly hashes only; a new month keeps just the best past count', async () => {
  const env = makeEngine();
  const g7 = gh.encode(12.97, 77.59, 7);
  await brakes(env, 5, { g7 });
  await env.engine.aggregate();
  const before = (await env.soda.findOne('intel_cells', { id: `hz:${g7}` })).value;
  assert.equal(before.rs.length, 5);
  assert.ok(before.rs.every((h) => /^[0-9a-f]{10}$/.test(h)));
  env.clock.now += 35 * M.DAY; // next month
  await brakes(env, 1, { g7, prefix: 'w' });
  await env.engine.aggregate();
  const after = (await env.soda.findOne('intel_cells', { id: `hz:${g7}` })).value;
  assert.equal(after.rs.length, 1, 'last month\'s hashes are dropped');
  assert.equal(after.rk, 5, 'only the count is kept');
  assert.equal(env.engine.riders(after, env.clock.now), 5);
});

test('decay: half-life 90 days (INTEL_HALF_LIFE_DAYS)', async () => {
  assert.equal(M.decay(8, 0, 90 * M.DAY, 90), 4);
  assert.equal(M.decay(8, 0, 180 * M.DAY, 90), 2);
  assert.equal(M.decay(8, 100, 0, 90), 8, 'never grows backwards');
  const env = makeEngine();
  const g7 = gh.encode(12.97, 77.59, 7);
  await brakes(env, 6, { g7 });
  await env.engine.aggregate();
  const area = { tiles: [g7.slice(0, 4)] };
  const s0 = (await env.engine.hazards(area, { minScore: 0, admin: true }))[0].rawScore;
  env.clock.now += 90 * M.DAY;
  env.engine.cache.clear();
  const s1 = (await env.engine.hazards(area, { minScore: 0, admin: true }))[0].rawScore;
  assert.ok(Math.abs(s1 - s0 / 2) < 0.02, `${s0} -> ${s1}`);
});

test('retention: raw rows older than INTEL_RAW_DAYS (90) are purged; cells stay', async () => {
  const env = makeEngine();
  await brakes(env, 5);
  await env.engine.aggregate();
  assert.equal((await all(env.soda, RAW)).length, 5);
  env.clock.now += 89 * M.DAY;
  assert.equal(await env.engine.purgeRaw(), 0);
  env.clock.now += 2 * M.DAY;
  assert.equal(await env.engine.purgeRaw(), 5);
  assert.equal((await all(env.soda, RAW)).length, 0);
  assert.equal((await all(env.soda, 'intel_cells')).length, 2, 'the hazard cell and its region stay (decayed)');
  process.env.INTEL_RAW_DAYS = '30';
  await brakes(env, 1, { prefix: 'z' });
  env.clock.now += 31 * M.DAY;
  assert.equal(await env.engine.purgeRaw(), 1, 'configurable');
  delete process.env.INTEL_RAW_DAYS;
});

test('delete my contributions: unprocessed rows at once, processed rows subtracted by the next run, export lists them', async () => {
  const env = makeEngine();
  const g7 = gh.encode(12.97, 77.59, 7);
  await brakes(env, 6, { g7 });
  await env.engine.aggregate();
  const area = { tiles: [g7.slice(0, 4)] };
  const before = (await env.engine.hazards(area, { minScore: 0, admin: true }))[0];
  assert.equal(before.riders, 6);
  // One more, not yet folded.
  await env.engine.ingestEvents('u0', [{ type: 'swerve', gh: g7, hb: 2, ts: env.clock.now }]);
  const exp = await env.engine.exportContributions('u0');
  assert.equal(exp.length, 2);
  assert.ok(exp.every((r) => !('rh' in r)));
  const out = await env.engine.deleteContributions('u0');
  assert.deepEqual(out, { removedNow: 1, subtractingSoon: 1 });
  await env.engine.aggregate();
  env.engine.cache.clear();
  const after = (await env.engine.hazards(area, { minScore: 0, admin: true }))[0];
  assert.equal(after.riders, 5, 'my hash left the distinct set');
  assert.ok(Math.abs(after.rawScore - before.rawScore * (5 / 6)) < 0.02, 'my score was subtracted exactly');
  assert.equal((await env.engine.exportContributions('u0')).length, 0);
  assert.equal((await all(env.soda, RAW)).length, 5);
});

test('gateway: consent API, events gated, delete / export, account erase, admin authorisation', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown().catch(() => {}));
  const admin = await env.register('Intel Admin', 'intel.admin@coroute.test');
  const rider = await env.register('Road Rider', 'road.rider@coroute.test');

  let r = await env.api('GET', '/intel/consent', null, rider.token);
  assert.equal(r.status, 200);
  assert.equal(r.json.on, false, 'off by default');
  r = await env.api('POST', '/intel/events', { events: [{ type: 'hard_brake', gh: 'tdr1y4b', hb: 1, ts: Date.now() }] }, rider.token);
  assert.equal(r.status, 202);
  assert.equal(r.json.accepted, 0);
  r = await env.api('PUT', '/intel/consent', { on: 'yes' }, rider.token);
  assert.equal(r.status, 400);
  r = await env.api('PUT', '/intel/consent', { on: true, prompted: true }, rider.token);
  assert.equal(r.json.on, true);
  assert.ok(r.json.promptedAt);
  r = await env.api('POST', '/intel/events', { events: [{ type: 'hard_brake', gh: 'tdr1y4b', hb: 1, ts: Date.now() }, { type: 'sos', gh: 'tdr1y4b', ts: Date.now() }, { type: 'x', gh: 'bad' }] }, rider.token);
  assert.equal(r.json.accepted, 1, 'SOS / crash come from the alert itself, not from the app; junk is dropped');
  r = await env.api('GET', '/intel/me/contributions', null, rider.token);
  assert.equal(r.status, 200);
  assert.equal(r.json.rows.length, 1);
  r = await env.api('DELETE', '/intel/me/contributions', null, rider.token);
  assert.equal(r.json.removedNow, 1);
  assert.match(r.json.message, /anonymous totals/);

  // Admin pages' API: riders get 403, admins 200.
  for (const p of ['/admin/intel/overview', '/admin/intel/hazards', '/admin/intel/crash-brain', '/admin/intel/dangerous-times', '/admin/intel/stops']) {
    assert.equal((await env.api('GET', p, null, rider.token)).status, 403, p);
    assert.equal((await env.api('GET', p, null)).status, 401, p);
    assert.equal((await env.api('GET', p, null, admin.token)).status, 200, p);
  }
  assert.equal((await env.api('POST', '/admin/intel/purge', {}, rider.token)).status, 403);
  assert.equal((await env.api('POST', '/admin/intel/crash-brain/approve', { version: 1 }, rider.token)).status, 403);
  const ov = await env.api('GET', '/admin/intel/overview', null, admin.token);
  assert.equal(ov.json.settings.kMin, 5);
  assert.equal(ov.json.settings.crashBrainMode, 'shadow');
  assert.equal(ov.json.consent.on, 1);

  // Health shows the intelligence block.
  const h = await env.api('GET', '/health');
  assert.ok(h.json.intel && typeof h.json.intel.memoryKB === 'number' && 'lastAggregateAt' in h.json.intel);

  // Account erase removes the consent record.
  await env.gw.repo.deleteUserCascade({ userId: rider.user.userId }, {});
  assert.equal(await env.gw.soda.findOne('intel_consent', { userId: rider.user.userId }), null);

  // Kill switch: reads answer empty and nothing is collected.
  process.env.INTEL_KILL = 'true';
  r = await env.api('GET', '/intel/hazards?bbox=12,77,13,78', null, admin.token);
  assert.deepEqual(r.json.cells, []);
  r = await env.api('PUT', '/intel/consent', { on: true }, admin.token);
  r = await env.api('POST', '/intel/events', { events: [{ type: 'hard_brake', gh: 'tdr1y4b', hb: 1, ts: Date.now() }] }, admin.token);
  assert.equal(r.json.reason, 'OFF');
  delete process.env.INTEL_KILL;
});
