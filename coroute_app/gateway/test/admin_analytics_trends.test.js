'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

// Admin overview charts: GET /api/admin/analytics/trends (daily series, previous period,
// plan mix, needs-attention counts) and the pure day bucketing behind it.
const test = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { bucketDays } = require('../src/admin_analytics');

const DAY = 86400000;

test('bucketDays: local days, oldest first, sums, distinct keys, out-of-range ignored', () => {
  // 2026-11-09 12:00 UTC; tz +330 (IST) keeps it on the 9th.
  const now = Date.UTC(2026, 10, 9, 12, 0, 0);
  const items = [
    { at: now }, { at: now - 1000 }, // today x2
    { at: now - DAY }, // yesterday
    { at: now - 5 * DAY }, // outside a 3-day window
    { at: 0 }, // no timestamp
  ];
  assert.deepEqual(bucketDays(items, { days: 3, now, tzMin: 330 }), [0, 1, 2]);
  assert.deepEqual(bucketDays([{ at: now, value: 12.5 }, { at: now, value: 7.5 }], { days: 2, now }), [0, 20]);
  const keyed = [{ at: now, key: 'a' }, { at: now, key: 'a' }, { at: now, key: 'b' }, { at: now - DAY, key: 'a' }];
  assert.deepEqual(bucketDays(keyed, { days: 2, now, distinct: true }), [1, 2]);
  // 20:00 UTC is already the next day in IST.
  const late = Date.UTC(2026, 10, 8, 20, 0, 0);
  assert.deepEqual(bucketDays([{ at: late }], { days: 2, now, tzMin: 330 }), [0, 1]);
  assert.deepEqual(bucketDays([{ at: late }], { days: 2, now, tzMin: 0 }), [1, 0]);
});

test('GET /admin/analytics/trends', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const { api, soda, gw } = env;
  const repo = gw.repo;
  const now = Date.now();

  const admin = await env.register('Asha Admin', 'admin@coroute.test');
  const r1 = await env.register('Ravi Rider', 'ravi@coroute.test');
  const r2 = await env.register('Meera Rider', 'meera@coroute.test');
  const u1 = r1.user.userId;
  const u2 = r2.user.userId;

  await t.test('riders cannot read it', async () => {
    const res = await api('GET', '/admin/analytics/trends', null, r1.token);
    assert.equal(res.status, 403);
  });

  await repo.saveTrip({ tripId: 'T1', userId: u1, groupId: 'G1', totalDistanceKm: 40.4, endTimeEpochMs: now - 1000, startTimeEpochMs: now - 3600000, source: 'server' });
  await repo.saveTrip({ tripId: 'T2', userId: u1, groupId: 'G2', totalDistanceKm: 10, endTimeEpochMs: now - 2000, startTimeEpochMs: now - 3600000, source: 'server' });
  await repo.saveTrip({ tripId: 'T3', userId: u2, groupId: 'G1', totalDistanceKm: 39.6, endTimeEpochMs: now - 1000, startTimeEpochMs: now - 3600000, source: 'server' });
  // Previous period (8 days ago with days=7) and a staff trip that never counts.
  await repo.saveTrip({ tripId: 'T4', userId: u2, groupId: 'G3', totalDistanceKm: 25, endTimeEpochMs: now - 8 * DAY, startTimeEpochMs: now - 8 * DAY - 3600000, source: 'server' });
  await repo.saveTrip({ tripId: 'T5', userId: admin.user.userId, groupId: 'G1', totalDistanceKm: 500, endTimeEpochMs: now - 1000, startTimeEpochMs: now - 3600000, source: 'server' });
  await soda.insert('convoys', { groupId: 'G1', name: 'Coastal', tripStatus: 'ENDED', endedAtEpochMs: now - 1000, members: {} });
  await soda.insert('convoys', { groupId: 'G3', name: 'Old', tripStatus: 'ENDED', endedAtEpochMs: now - 8 * DAY, members: {} });
  await soda.insert('alerts', { alertId: 'S1', groupId: 'G1', userId: u1, timestamp: now - 1000, resolved: false });
  await soda.insert('alerts', { alertId: 'S2', groupId: 'G1', userId: u1, timestamp: now - 2 * DAY, resolved: true });
  await soda.insert('public_ride', { k: 'report', reportId: 'RPT-1', status: 'OPEN', at: now });
  await soda.insert('public_ride', { k: 'report', reportId: 'RPT-2', status: 'REVIEWED', at: now });
  const d2 = await repo.findUserById(u2);
  await repo.updateUser(d2.key, { status: 'ON_HOLD', lastActiveAt: now });

  await t.test('daily series, previous period, plans and attention', async () => {
    const res = await api('GET', '/admin/analytics/trends?days=7&tz=0&fresh=1', null, admin.token);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    const j = res.json;
    assert.equal(j.days, 7);
    assert.equal(j.labels.length, 7);
    assert.equal(j.labels[6], new Date(now).toISOString().slice(0, 10));
    for (const k of ['rides', 'km', 'activeRiders', 'signups', 'sos']) {
      assert.equal(j.series[k].length, 7, k);
      assert.equal(j.previous[k].length, 7, k);
    }
    assert.equal(j.series.rides[6], 1);
    assert.equal(j.series.km[6], 90, 'staff km left out, rounded');
    assert.equal(j.series.activeRiders[6], 2, 'distinct riders; staff left out');
    assert.equal(j.previous.rides.reduce((a, b) => a + b, 0), 1);
    assert.equal(j.previous.km.reduce((a, b) => a + b, 0), 25);
    assert.equal(j.series.sos.reduce((a, b) => a + b, 0), 2);
    assert.equal(j.series.signups[6], 2, 'two riders signed up today; the admin is staff');
    assert.equal(j.riders.total, 2);
    assert.ok(j.riders.activeToday >= 1);
    assert.deepEqual(j.plans, [{ id: 'community', count: 2 }]);
    assert.equal(j.attention.openSos, 1);
    assert.equal(j.attention.reportsOpen, 1);
    assert.equal(j.attention.onHold, 1);
    assert.equal(j.attention.reviewsPending, 0);
    assert.equal(j.attention.photosPending, 0);
  });

  await t.test('unsupported periods fall back to 30 days', async () => {
    const res = await api('GET', '/admin/analytics/trends?days=12', null, admin.token);
    assert.equal(res.status, 200);
    assert.equal(res.json.days, 30);
    assert.equal(res.json.series.rides.length, 30);
  });
});
