'use strict';
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const {
  computeScore, rideSpeed, rideSafety, rideSmooth, rideFactsFromReport, longestStretch, phoneCounts, levelOf, MIN_RIDES, NO_SPEED_CAP,
} = require('../src/rider_score');
const { Leaderboard } = require('../src/leaderboard');
const { boot } = require('./_helpers');

const DAY = 864e5;
const H = 3600000;
const NOW = Date.UTC(2026, 10, 9, 12, 0, 0);

/** A clean 2 h, 100 km ride under a known limit, `daysAgo` before NOW. */
const ride = (i, daysAgo = i * 7, extra = {}) => ({
  rideId: `TRIP-R${i}-U`, endedAt: NOW - daysAgo * DAY, km: 100, movingMs: 2 * H, source: 'server', speedKnown: true,
  episodes: [], separatedCount: 0, separatedMs: 0, groupSize: 4, longestStretchMs: 1.5 * H, phone: { hb: 1, br: 1, fp: 30, fn: 0, ol: 0 }, ...extra,
});
const ep = (limitKmh, maxKmh, min) => ({ limitKmh, maxKmh, durMs: min * 60000 });

// ---------------------------------------------------------------- scoring math (pure)

test('overspeed lowers the speed component; 40%+ over weighs far more than a little over', () => {
  const clean = rideSpeed(ride(1));
  assert.equal(clean, 100);
  const mild = rideSpeed(ride(1, 0, { episodes: [ep(80, 86, 2)] }));
  const far = rideSpeed(ride(1, 0, { episodes: [ep(80, 120, 2)] }));
  assert.ok(mild < clean, 'a little over still lowers it');
  assert.ok(far < mild - 20, `40%+ over weighs heavily (${far} vs ${mild})`);
  // Longer over = lower.
  assert.ok(rideSpeed(ride(1, 0, { episodes: [ep(80, 86, 10)] })) < mild);
  // The overall score follows.
  const base = [ride(1), ride(2), ride(3)];
  const bad = [ride(1, 7, { episodes: [ep(80, 120, 5)] }), ride(2), ride(3)];
  assert.ok(computeScore(bad, NOW).score < computeScore(base, NOW).score);
});

test('speed is never rewarded: average / top speed are not inputs and a faster ride under the limit scores the same', () => {
  const meta = { groupId: 'GRP-X', speedLimitKmh: 80, members: { U: {}, V: {} }, endedAtEpochMs: NOW };
  const stats = (avg, max) => ({ userId: 'U', distanceM: 100000, movingMs: 2 * H, lastFixAt: NOW, statsSource: 'server', avgMovingKmh: avg, maxKmh: max });
  const slow = rideFactsFromReport({ meta, stats: stats(40, 60), analysis: null, events: [], tripId: 'T' });
  const fast = rideFactsFromReport({ meta, stats: stats(78, 80), analysis: null, events: [], tripId: 'T' });
  assert.deepEqual(slow, { ...fast, endedAt: slow.endedAt });
  assert.ok(!('avgMovingKmh' in fast) && !('maxKmh' in fast), 'speeds are not even stored');
  // No limit violation can push a component above 100, and riding under the limit never adds points.
  for (let v = 0; v < 5; v++) assert.ok(rideSpeed(ride(1, 0, { episodes: v ? [ep(80, 81 + v, 1)] : [] })) <= 100);
});

test('SOS, crash alarms, possible incidents and false alarms never lower the score', () => {
  const meta = { groupId: 'GRP-X', speedLimitKmh: 80, members: { U: {}, V: {} }, endedAtEpochMs: NOW };
  const stats = { userId: 'U', distanceM: 100000, movingMs: 2 * H, lastFixAt: NOW, statsSource: 'server', sos: 3 };
  const calm = rideFactsFromReport({ meta, stats: { ...stats, sos: 0 }, analysis: null, events: [], tripId: 'T' });
  const events = [
    { userId: 'U', type: 'SOS', durationMs: 600000, data: { kind: 'CRASH' } },
    { userId: 'U', type: 'POSSIBLE_INCIDENT', data: { reason: 'HARD_STOP' } },
    { userId: 'U', type: 'SOS', data: { falseAlarm: true } },
  ];
  const sos = rideFactsFromReport({ meta, stats, analysis: null, events, tripId: 'T' });
  assert.deepEqual(sos, calm);
  // The phone's crash alarm / bike-down counts are not even accepted.
  assert.deepEqual(Object.keys(phoneCounts({ hardBrakes: 2, crashAlarms: 5, bikeDownChecks: 2, sos: 1, lat: 17 })).sort(), ['br', 'fn', 'fp', 'hb', 'ol']);
});

test('breaks never lower safety; a long stretch without one does; separated repeatedly does', () => {
  assert.equal(rideSafety(ride(1)), 100);
  assert.ok(rideSafety(ride(1, 0, { longestStretchMs: 4 * H })) < 100);
  assert.equal(rideSafety(ride(1, 0, { phone: { hb: 0, br: 9, fp: 0, fn: 0, ol: 0 } })), 100, 'many breaks are fine');
  assert.equal(rideSafety(ride(1, 0, { separatedCount: 1 })), 100, 'once happens');
  assert.ok(rideSafety(ride(1, 0, { separatedCount: 4 })) < 100);
  assert.equal(rideSafety(ride(1, 0, { separatedCount: 4, groupSize: 1 })), 100, 'solo rides are not judged on the group');
  // Stretch from report stops: breaks of 10 min or more split the ride.
  const t0 = 0;
  assert.equal(longestStretch(t0, t0 + 4 * H, [{ startTs: 2 * H, endTs: 2 * H + 15 * 60000, durationMs: 15 * 60000 }]), 2 * H);
  assert.equal(longestStretch(t0, t0 + 4 * H, [{ startTs: 2 * H, endTs: 2 * H + 5 * 60000, durationMs: 5 * 60000 }]), 4 * H, 'a 5 min stop is not a break');
});

test('smoothness from hard brakes per 100 km; unknown without the phone counts', () => {
  assert.equal(rideSmooth(ride(1, 0, { phone: null })), null);
  assert.equal(rideSmooth(ride(1, 0, { phone: { hb: 0 } })), 100);
  assert.ok(rideSmooth(ride(1, 0, { phone: { hb: 10 } })) < rideSmooth(ride(1, 0, { phone: { hb: 2 } })));
  // Same count over a longer ride is smoother.
  assert.ok(rideSmooth(ride(1, 0, { km: 300, phone: { hb: 3 } })) > rideSmooth(ride(1, 0, { km: 100, phone: { hb: 3 } })));
});

test('minRides: no score until 3 rides of 10 km or more; short rides do not count', () => {
  const two = computeScore([ride(1), ride(2)], NOW);
  assert.equal(two.score, null); assert.equal(two.level, null); assert.equal(two.ridesCounted, 2); assert.equal(two.minRides, MIN_RIDES);
  assert.equal(computeScore([ride(1), ride(2), ride(3, 21, { km: 9 })], NOW).score, null);
  const three = computeScore([ride(1), ride(2), ride(3)], NOW);
  assert.ok(three.score >= 0 && three.score <= 100);
  assert.equal(three.level, levelOf(three.score));
  for (const k of ['smoothness', 'speedDiscipline', 'safety', 'consistency']) assert.ok(three.components[k] >= 0 && three.components[k] <= 100, k);
  assert.ok(Array.isArray(three.tips) && three.tips.length >= 1);
  assert.deepEqual(['Learner', 'Steady', 'Skilled', 'Ace Rider'], [levelOf(10), levelOf(55), levelOf(75), levelOf(90)]);
});

test('recent rides weigh more (half-life 60 days) and consistency rewards regular riding', () => {
  const bad = { episodes: [ep(80, 120, 10)] };
  const recentBad = computeScore([ride(1, 1, bad), ride(2, 200), ride(3, 210)], NOW);
  const oldBad = computeScore([ride(1, 220, bad), ride(2, 1), ride(3, 2)], NOW);
  assert.ok(oldBad.components.speedDiscipline > recentBad.components.speedDiscipline + 20);
  const regular = computeScore(Array.from({ length: 13 }, (_, i) => ride(i, i * 14 + 1)), NOW);
  const rare = computeScore([ride(1, 1), ride(2, 2), ride(3, 3)], NOW);
  assert.ok(regular.components.consistency > rare.components.consistency);
  assert.equal(regular.components.consistency, 100);
});

test('without any speed information the score is capped (no reward for hiding speed)', () => {
  const unknown = [1, 2, 3].map((i) => ride(i, i * 7, { speedKnown: false, phone: null }));
  const s = computeScore(unknown, NOW);
  assert.equal(s.components.speedDiscipline, null);
  assert.ok(s.score <= NO_SPEED_CAP);
  // The phone's minutes over its limit make speed measurable and can only lower it.
  const withPhone = [1, 2, 3].map((i) => ride(i, i * 7, { speedKnown: false, phone: { hb: 0, ol: 20 } }));
  assert.ok(computeScore(withPhone, NOW).components.speedDiscipline < 100);
  // The phone never erases what the server saw.
  assert.equal(rideSpeed(ride(1, 0, { episodes: [ep(80, 120, 5)], phone: { hb: 0, ol: 0 } })), rideSpeed(ride(1, 0, { episodes: [ep(80, 120, 5)], phone: null })));
});

// ---------------------------------------------------------------- API + leaderboard

let gw;
after(async () => { mock.timers.reset(); if (gw) await gw.gw.shutdown(); });

test('GET /me/score, phone counts, leaderboard privacy, opt-out, rounding, caching and switches', async () => {
  gw = await boot();
  const { api, register } = gw;
  const repo = gw.gw.repo;
  const rs = gw.gw.riderScore;
  const users = [];
  for (const [i, name] of ['Asha Real', 'Bala Real', 'Chitra Real', 'Dev Real', 'Esha Real'].entries()) {
    const r = await register(name, `lb${i}@coroute.test`);
    users.push({ ...r, name });
  }
  const setUser = async (u, patch) => { const doc = await repo.findUserById(u.user.userId); await repo.updateUser(doc.key, patch); };
  await setUser(users[0], { username: 'asha_rides' });
  await setUser(users[1], { username: 'bala', publicLeaderboard: false }); // opted out
  await setUser(users[2], { username: null }); // no username (registration may assign one): never shown
  await setUser(users[3], { username: 'dev.r' });
  await setUser(users[4], { username: 'esha' }); // only 2 rides: not eligible

  const now = Date.now();
  const add = async (u, n, extra = {}) => {
    for (let i = 0; i < n; i++) {
      await rs.recordRide(u.user.userId, { ...ride(i, i * 5), endedAt: now - i * 5 * DAY, rideId: `TRIP-${u.user.userId}-${i}`, ...extra });
    }
  };
  await add(users[0], 4, { km: 123.46, movingMs: 2.26 * H });
  await add(users[1], 5, { km: 500, movingMs: 8 * H });
  await add(users[2], 5, { km: 400, movingMs: 6 * H });
  await add(users[3], 3, { km: 80.4, movingMs: 1.04 * H, episodes: [ep(80, 120, 3)] });
  await add(users[4], 2, { km: 900, movingMs: 12 * H });

  // Own score.
  const me = await api('GET', '/me/score', null, users[0].token);
  assert.equal(me.status, 200);
  assert.ok(me.json.score >= 0 && me.json.score <= 100);
  assert.equal(me.json.ridesCounted, 4);
  assert.equal(me.json.minRides, 3);
  assert.ok(me.json.level);
  assert.deepEqual(Object.keys(me.json.components).sort(), ['consistency', 'safety', 'smoothness', 'speedDiscipline']);
  assert.ok(me.json.updatedAt > 0 && Array.isArray(me.json.tips));
  const devScore = (await api('GET', '/me/score', null, users[3].token)).json;
  assert.ok(devScore.score < me.json.score, 'the rider who went 50% over scores lower');
  assert.equal((await api('GET', '/me/score', null, users[4].token)).json.score, null, 'below minRides');
  assert.equal((await api('GET', '/me/score')).status, 401);

  // Phone counts: before the report (kept pending) and after (merged into the ride).
  const gid = 'GRP-PHONE1';
  assert.equal((await api('POST', '/me/score/rides', { groupId: gid, hardBrakes: 40, breaks: 1, lat: 17.1, track: [1, 2] }, users[0].token)).status, 202);
  await rs.recordRide(users[0].user.userId, { ...ride(9, 0), phone: null, endedAt: now, rideId: `TRIP-PHONE1-${users[0].user.userId}` });
  let doc = (await gw.gw.soda.findOne('rider_scores', { userId: users[0].user.userId })).value;
  const merged = doc.rides.find((r) => r.rideId === `TRIP-PHONE1-${users[0].user.userId}`);
  assert.equal(merged.phone.hb, 40);
  assert.ok(!JSON.stringify(doc).includes('17.1'), 'no position stored');
  assert.equal((await api('POST', '/me/score/rides', { groupId: 'nope' }, users[0].token)).status, 400);
  // Setting switched off: the phone counts are forgotten.
  assert.equal((await api('DELETE', '/me/score/phone', null, users[0].token)).status, 200);
  doc = (await gw.gw.soda.findOne('rider_scores', { userId: users[0].user.userId })).value;
  assert.ok(doc.rides.every((r) => r.phone === null));

  // Leaderboard.
  const lb = await api('GET', '/public/leaderboard');
  assert.equal(lb.status, 200);
  assert.match(lb.headers.get('cache-control'), /max-age=300/);
  const body = lb.json;
  for (const k of ['topScore', 'longestRide', 'mostKm', 'mostHours', 'mostRides']) assert.ok(Array.isArray(body[k]), k);
  const text = JSON.stringify(body);
  for (const u of users) {
    assert.ok(!text.includes(u.user.userId), 'no userIds');
    assert.ok(!text.includes(u.name) && !text.includes(u.name.split(' ')[0]), 'no real names');
    assert.ok(!text.includes(u.user.email), 'no emails');
  }
  assert.ok(!text.includes('bala'), 'opted-out rider not shown');
  assert.ok(!text.includes('esha'), 'rider below minRides not shown');
  // An implausible ride (1000 km in 2 h) never reaches the public totals.
  assert.equal((await rs.recordRide(users[3].user.userId, { ...ride(8, 0), endedAt: now, km: 1000, movingMs: 2 * H, rideId: 'TRIP-FAKE' })).lbKm, Math.round(80.4 * 3));
  assert.ok(!/rideId|endedAt|lat|lng|TRIP-/.test(text), 'no rides, places or dates');
  const names = body.mostKm.map((r) => r.username);
  assert.deepEqual(names, ['asha_rides', 'dev.r']);
  const asha = body.mostKm[0];
  assert.equal(asha.km, Math.round(123.46 * 4 + 100), 'km rounded to 1 km (4 rides of 123.46 + one of 100)');
  assert.ok(Number.isInteger(asha.km));
  const hrs = body.mostHours.find((r) => r.username === 'asha_rides').hours;
  assert.equal(hrs, Math.round(((4 * 2.26 + 2) * 10)) / 10, 'hours rounded to 0.1');
  assert.equal(body.longestRide[0].km, 123);
  assert.equal(body.mostRides.find((r) => r.username === 'asha_rides').rides, 5);
  assert.equal(body.topScore[0].username, 'asha_rides');
  for (const row of body.topScore) assert.deepEqual(Object.keys(row).sort(), ['rides', 'score', 'username']);

  // Cached for 5 minutes: a new rider does not appear until the cache expires.
  await setUser(users[4], { username: 'esha' });
  await add(users[4], 3, { km: 900, movingMs: 12 * H });
  const cached = (await api('GET', '/public/leaderboard')).json;
  assert.equal(cached.updatedAt, body.updatedAt);
  assert.ok(!JSON.stringify(cached).includes('esha'));
  const builds = gw.gw.leaderboard.builds;
  gw.gw.leaderboard.cache.at -= 5 * 60 * 1000 + 1;
  const fresh = (await api('GET', '/public/leaderboard')).json;
  assert.equal(gw.gw.leaderboard.builds, builds + 1);
  assert.equal(fresh.mostKm[0].username, 'esha');

  // The rider's own places ("You: #2"); opted-out and below-minRides riders get none and never count above others.
  const mine = (await api('GET', '/me/leaderboard', null, users[0].token)).json;
  assert.equal(mine.username, 'asha_rides');
  assert.equal(mine.onLeaderboard, true);
  assert.equal(mine.ranks.mostKm, 2, 'esha above; bala (opted out, more km) is not counted');
  assert.equal(mine.ranks.topScore >= 1, true);
  const hidden = (await api('GET', '/me/leaderboard', null, users[1].token)).json;
  assert.equal(hidden.onLeaderboard, false);
  assert.equal(hidden.ranks.mostKm, null);
  assert.ok(!JSON.stringify(mine).includes(users[0].user.userId));

  // Switches: leaderboard off -> empty lists; rider score off -> no score.
  await gw.gw.featureFlags.set('leaderboard', false, { reason: 'test' });
  const off = (await api('GET', '/public/leaderboard')).json;
  for (const k of ['topScore', 'longestRide', 'mostKm', 'mostHours', 'mostRides']) assert.deepEqual(off[k], []);
  await gw.gw.featureFlags.set('riderScore', false, { reason: 'test' });
  const noScore = (await api('GET', '/me/score', null, users[0].token)).json;
  assert.equal(noScore.enabled, false); assert.equal(noScore.score, null);
  await gw.gw.featureFlags.set('leaderboard', true);
  await gw.gw.featureFlags.set('riderScore', true);

  // Admin view and the daily recompute.
  const adminView = await rs.adminView(users[3].user.userId);
  assert.equal(adminView.recentRides.length, 4);
  assert.equal(adminView.recentRides.filter((r) => r.overspeedEpisodes === 1).length, 3);
  assert.ok(adminView.score != null && adminView.components);
  assert.ok((await rs.recomputeAll()) >= 5);

  // Account erase removes the score document.
  await repo.deleteUserCascade(await repo.findUserById(users[2].user.userId));
  assert.equal(await gw.gw.soda.findOne('rider_scores', { userId: users[2].user.userId }), null);
});

test('handleOf: hides opted-out, blocked and missing usernames', () => {
  assert.equal(Leaderboard.handleOf({ username: 'ok_1' }), 'ok_1');
  assert.equal(Leaderboard.handleOf({ username: 'ok_1', publicLeaderboard: false }), null);
  assert.equal(Leaderboard.handleOf({ username: 'ok_1', status: 'BLOCKED' }), null);
  assert.equal(Leaderboard.handleOf({ name: 'Real Name' }), null);
  assert.equal(Leaderboard.handleOf({ username: '<script>' }), null);
});

test('a finished trip report records the ride with its overspeed episodes (timeline hook)', async () => {
  const T0 = Date.UTC(2026, 9, 5, 4, 0, 0);
  const { createApp } = require('../src/app');
  const { MemorySoda } = require('../src/oracle/memory_soda');
  mock.timers.enable({ apis: ['Date'], now: T0 });
  const app = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  try {
    const a = await app.auth.register({ name: 'Arun', email: 'arun-rs@coroute.test', password: 'Password#123', phone: '9999999999' });
    const b = await app.auth.register({ name: 'Bindu', email: 'bindu-rs@coroute.test', password: 'Password#123', phone: '9999999998' });
    const ua = { userId: a.user.userId, name: 'Arun', role: 'RIDER' };
    const ub = { userId: b.user.userId, name: 'Bindu', role: 'RIDER' };
    const snap = await app.convoys.createConvoy(ua, { name: 'Score test', speedLimitKmh: 80 });
    await app.convoys.joinByCode(ub, snap.joinCode);
    const room = await app.convoys.getRoom(snap.groupId);
    let t = T0, lat = 17.0;
    const step = async (u, kmh) => {
      t += 5000; lat += 0.0003; mock.timers.setTime(t);
      app.convoys.patchRider(room, u.userId, { lat, lng: 78.0, speedKmh: kmh }, { emit: false });
      await app.timeline.idle();
    };
    for (const v of [70, 120, 122, 121, 120, 119, 70, 70, 70, 70, 70, 70]) await step(ua, v);
    await app.timeline.finishTrip(snap.groupId);
    const doc = (await app.soda.findOne('rider_scores', { userId: ua.userId })).value;
    assert.equal(doc.rides.length, 1);
    assert.equal(doc.rides[0].rideId, `TRIP-${snap.groupId.replace('GRP-', '')}-${ua.userId}`);
    assert.equal(doc.rides[0].speedKnown, true);
    assert.equal(doc.rides[0].episodes.length, 1);
    assert.equal(doc.rides[0].episodes[0].limitKmh, 80);
    assert.ok(doc.rides[0].episodes[0].maxKmh >= 120);
    assert.ok(!JSON.stringify(doc).includes('Arun'), 'no names stored');
    // Rebuilt report (late uploads): the same ride is replaced, never doubled.
    await app.timeline.finishTrip(snap.groupId);
    assert.equal((await app.soda.findOne('rider_scores', { userId: ua.userId })).value.rides.length, 1);
  } finally {
    await app.shutdown();
    mock.timers.reset();
  }
});
