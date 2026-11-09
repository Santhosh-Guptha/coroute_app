'use strict';
/**
 * 3.55b website ALL-TIME numbers:
 * - communityTotals counts every stored trip (not the last 7 days), riders with at least one ride (no staff,
 *   no guests, no rider without a ride), and keeps the last 7 days only as a secondary `thisWeek`;
 * - safeAllTime applies the privacy floor (nothing below 10) and rounds down (counts to 10 / 100, km to 100 / 1,000);
 * - GET /api/public/alltime-stats answers from ONE shared aggregate: computed once, cached, stored for other
 *   nodes, recomputed only when stale, refreshed by the job lease; no ids, names or per-ride figures.
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { communityTotals } = require('../src/admin_analytics');
const { safeAllTime, PRIVACY_NOTE } = require('../src/public_privacy');
const { PublicStatsStore, DOC_KEY } = require('../src/public_stats');

const DAY = 86400000;
const HOUR = 3600000;
const NOW = Date.UTC(2026, 10, 9, 12, 30);

/** n riders, each with `perRider` trips: half of them a year old, plus one recent trip each for the first `recent`. */
async function seed(soda, { riders = 12, perRider = 2, km = 37, recent = 0, prefix = 'r', now = NOW } = {}) {
  for (let i = 0; i < riders; i++) {
    const uid = `usr_${prefix}${i}`;
    await soda.insert('users', { userId: uid, email: `${prefix}${i}@ride.test`, name: `Rider ${prefix}${i}`, provider: 'email', vehicleNo: `KA0${i}AB${1000 + i}` });
    for (let k = 0; k < perRider; k++) {
      const end = now - 365 * DAY - k * DAY;
      await soda.insert('trips', { tripId: `T-${prefix}${i}-${k}`, userId: uid, totalDistanceKm: km, movingMs: 2 * HOUR, startTimeEpochMs: end - 3 * HOUR, endTimeEpochMs: end });
    }
    if (i < recent) {
      const end = now - 2 * DAY;
      await soda.insert('trips', { tripId: `T-${prefix}${i}-w`, userId: uid, totalDistanceKm: km, movingMs: HOUR, startTimeEpochMs: end - 2 * HOUR, endTimeEpochMs: end });
    }
  }
}

test('communityTotals: all-time totals, riders with a ride, this week as a secondary figure', async () => {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  await seed(soda, { riders: 12, perRider: 2, km: 37, recent: 11 });
  // Not riders with a ride: a guest with a trip, staff with a trip, a registered rider without any trip.
  await soda.insert('users', { userId: 'usr_guest', email: 'x@guest.coroute.local', provider: 'guest' });
  await soda.insert('trips', { tripId: 'T-guest', userId: 'usr_guest', totalDistanceKm: 5, movingMs: HOUR, endTimeEpochMs: NOW - 400 * DAY });
  await soda.insert('users', { userId: 'usr_staff', email: 'ops@ride.test', role: 'MASTER_ADMIN' });
  await soda.insert('trips', { tripId: 'T-staff', userId: 'usr_staff', totalDistanceKm: 5, movingMs: HOUR, endTimeEpochMs: NOW - 400 * DAY });
  await soda.insert('users', { userId: 'usr_new', email: 'new@ride.test', provider: 'email' });
  await soda.insert('convoys', { groupId: 'G1', tripStatus: 'ENDED', members: Object.fromEntries(Array.from({ length: 7 }, (_, i) => [`usr_r${i}`, {}])) });

  const t = await communityTotals(repo, NOW);
  assert.equal(t.scope, 'all-time');
  assert.equal(t.ridersWithRide, 12, 'riders with at least one ride: no guest, no staff, not the rider without a trip');
  assert.equal(t.riders, 13, 'registered riders (not guests, not staff)');
  assert.equal(t.ridesCompleted, 12 * 2 + 11 + 2, 'every stored trip, a year old included');
  assert.equal(t.kmRidden, Math.round(35 * 37 + 10));
  assert.equal(t.movingHours, 24 * 2 + 11 * 1 + 2, 'moving hours over all time');
  assert.equal(t.longestTripKm, 37);
  assert.equal(t.groupRides, 1);
  assert.equal(t.largestGroup, 7);
  assert.equal(t.bikes, 12);
  assert.deepEqual(t.thisWeek, { rides: 11, km: 11 * 37, movingHours: 11, riders: 11 }, 'the last 7 days only in thisWeek');
  assert.equal(t.truncated, false);
});

test('safeAllTime: privacy floor and rounding down', () => {
  const s = safeAllTime({
    riders: 1234, ridersWithRide: 987, ridesCompleted: 4567, kmRidden: 123456.7, movingHours: 8765.4,
    groupRides: 57, largestGroup: 23, longestTripKm: 1847.9, bikes: 456,
    safety: { sosResolved: 12, crashAlerts: 3, alertsAnswered: 44, medianResponseSec: 95.4, responsesCounted: 20, roadReports: 9 },
    thisWeek: { rides: 57, km: 2345, movingHours: 123, riders: 41 },
    updatedAt: Date.UTC(2026, 10, 9, 12, 37),
    weeklyKm: [{ weekStart: 1, km: 5, rides: 1 }], ratingsCount: 3, truncated: false,
  });
  assert.equal(s.scope, 'all-time');
  assert.equal(s.ridersWithRide, 980, 'tens below 1,000');
  assert.equal(s.registeredRiders, 1200, 'hundreds from 1,000');
  assert.equal(s.ridesCompleted, 4500);
  assert.equal(s.kmRidden, 123000, 'km to 1,000 from 10,000');
  assert.equal(s.movingHours, 8700, 'hours rounded down like counts');
  assert.equal(s.groupRides, 50);
  assert.equal(s.largestGroup, 23);
  assert.equal(s.longestTripKm, 1840);
  assert.equal(s.bikes, 450);
  assert.deepEqual(s.safety, { sosResolved: 10, crashAlerts: 0, alertsAnswered: 40, medianResponseSec: 95, roadReports: 0 });
  assert.deepEqual(s.thisWeek, { rides: 50, km: 2300, movingHours: 120, riders: 40 });
  assert.equal(s.updatedAt, Date.UTC(2026, 10, 9, 12), 'time to the hour');
  for (const k of ['weeklyKm', 'ratingsCount', 'truncated', 'riders', 'responsesCounted']) assert.ok(!(k in s) && !(k in s.safety), `${k} not published`);

  const small = safeAllTime({ riders: 9, ridersWithRide: 9, ridesCompleted: 9, kmRidden: 99, movingHours: 9, groupRides: 9, largestGroup: 5, longestTripKm: 400, bikes: 9, thisWeek: { rides: 9, km: 900, movingHours: 30, riders: 9 } });
  assert.equal(small.ridersWithRide, 0);
  assert.equal(small.registeredRiders, 0);
  assert.equal(small.ridesCompleted, 0);
  assert.equal(small.kmRidden, 0);
  assert.equal(small.movingHours, 0);
  assert.equal(small.largestGroup, 0, 'no record without 10 group rides');
  assert.equal(small.longestTripKm, 0, 'no record without 10 rides');
  assert.deepEqual(small.thisWeek, { rides: 0, km: 0, movingHours: 0, riders: 0 }, 'a quiet week shows nothing, km and hours included');
  assert.deepEqual(safeAllTime(null).thisWeek, { rides: 0, km: 0, movingHours: 0, riders: 0 });
});

test('PublicStatsStore: computed once, cached, shared through one document, recomputed only when stale', async () => {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  let now = NOW;
  let calls = 0;
  const compute = async () => { calls++; return { ridesCompleted: 100 + calls, updatedAt: now }; };
  const a = new PublicStatsStore({ repo, compute, clock: () => now, memoryMs: 60000, staleMs: 15 * 60000 });
  const [x, y] = await Promise.all([a.get(), a.get()]);
  assert.equal(calls, 1, 'two requests at once: one computation');
  assert.equal(x.ridesCompleted, 101);
  assert.equal(y.ridesCompleted, 101);
  now += 30000;
  assert.equal((await a.get()).ridesCompleted, 101, 'memory copy');
  const doc = await soda.findOne('subscription_config', { k: DOC_KEY });
  assert.equal(doc.value.totals.ridesCompleted, 101, 'stored for the other nodes');
  assert.equal(doc.value.computedAt, NOW);

  // Another node: reads the stored totals, computes nothing.
  let otherCalls = 0;
  const b = new PublicStatsStore({ repo, compute: async () => { otherCalls++; return {}; }, clock: () => now });
  assert.equal((await b.get()).ridesCompleted, 101);
  assert.equal(otherCalls, 0);

  // The lease job refreshes; the other node sees it once its memory copy expires.
  await a.refresh();
  assert.equal(calls, 2);
  assert.equal((await b.get()).ridesCompleted, 101, 'b still within its memory time');
  now += 61000;
  assert.equal((await b.get()).ridesCompleted, 102, 'b re-read the shared document');
  assert.equal(otherCalls, 0);

  // Nobody refreshed for longer than staleMs: the next request computes once.
  now += 16 * 60000;
  assert.equal((await b.get()).ridesCompleted, undefined, 'b computed fresh totals itself');
  assert.equal(otherCalls, 1);

  // start() registers one leased job.
  const runs = [];
  a.start({ run: (name, every, fn, opts) => runs.push({ name, every, fn, opts }) });
  assert.equal(runs.length, 1);
  assert.equal(runs[0].name, 'public-stats');
  assert.ok(runs[0].every >= 5 * 60000 && runs[0].every <= 10 * 60000, 'refreshed every 5 to 10 minutes');
  assert.equal(a.start(null), null);
});

/* ---------- the endpoint ---------- */
let gw, base;
before(async () => {
  const soda = new MemorySoda();
  gw = await createApp({ soda, logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
  await seed(soda, { riders: 23, perRider: 3, km: 41.6, recent: 12, now: Date.now() });
});
after(async () => { await gw.shutdown(); });

test('GET /api/public/alltime-stats: all-time, coarse, cached, no personal fields', async () => {
  const r = await fetch(base + '/api/public/alltime-stats');
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('set-cookie'), null);
  assert.match(r.headers.get('cache-control'), /public, max-age=60/);
  const j = await r.json();
  assert.equal(j.ok, true);
  assert.equal(j.enabled, true);
  assert.equal(j.scope, 'all-time');
  assert.deepEqual(j.privacy, { ...PRIVACY_NOTE });
  const st = j.stats;
  // 23 riders x 3 year-old trips + 12 recent = 81 trips, 3,369.6 km, 23 x 3 x 2 h + 12 h = 150 h.
  assert.equal(st.ridersWithRide, 20, '23 riders with a ride, rounded down');
  assert.equal(st.registeredRiders, 20);
  assert.equal(st.ridesCompleted, 80, 'year-old rides count: all-time, not 7 days');
  assert.equal(st.kmRidden, 3300);
  assert.equal(st.movingHours, 150);
  assert.equal(st.longestTripKm, 40);
  assert.equal(st.bikes, 20);
  assert.deepEqual(st.thisWeek, { rides: 10, km: 400, movingHours: 10, riders: 10 });
  assert.equal(st.updatedAt % HOUR, 0);
  assert.ok(!JSON.stringify(j).match(/usr_|Rider |@ride\.test|KA0|"(?:userId|name|email|lat|lng|trips|tripId)"/), 'no per-rider or per-ride fields');

  // Cached: new rides do not change the answer until the shared aggregate is refreshed.
  await seed(gw.soda, { riders: 30, perRider: 1, km: 50, prefix: 'n', now: Date.now() });
  const again = (await (await fetch(base + '/api/public/alltime-stats')).json()).stats;
  assert.equal(again.ridesCompleted, 80, 'served from the cached aggregate');
  const computed = gw.publicStats.computeCount;
  await (await fetch(base + '/api/public/impact-stats')).json();
  await (await fetch(base + '/api/public/usage-stats')).json();
  assert.equal(gw.publicStats.computeCount, computed, 'impact-stats and usage-stats share the same aggregate');
  await gw.publicStats.refresh();
  const fresh = (await (await fetch(base + '/api/public/alltime-stats')).json()).stats;
  assert.equal(fresh.ridesCompleted, 110);
  assert.equal(fresh.ridersWithRide, 50);
  const imp = (await (await fetch(base + '/api/public/impact-stats')).json()).stats;
  assert.equal(imp.ridesCompleted, 110, 'impact-stats is all-time too');
  assert.equal(imp.movingHours, fresh.movingHours);
});

test('GET /api/public/alltime-stats: hidden when the admin hides website numbers', async () => {
  await gw.repo.setCommunityStatsConfig({ showPublicStats: false });
  const off = await (await fetch(base + '/api/alltime-stats')).json();
  assert.equal(off.enabled, false);
  assert.equal(off.stats, null);
  await gw.repo.setCommunityStatsConfig({ showPublicStats: true });
  assert.equal((await (await fetch(base + '/api/alltime-stats')).json()).enabled, true);
});
