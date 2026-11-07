'use strict';
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_staff1';
process.env.RAZORPAY_TEST_KEY_SECRET = 'staff_secret_2';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_staff_3';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'boss@coroute.test';
process.env.STAFF_EMAILS = 'Ops@CoRoute.test, qa@coroute.test';

// Staff accounts (admins, BOOTSTRAP_ADMIN_EMAILS, STAFF_EMAILS) are never counted as riders, members
// or revenue in the admin console or on the public website; they stay findable with the Staff filter.
// Rides they join still count, flagged hasStaff. Guests keep their own handling.
const test = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { isStaffAccount, isStaffRole, isGuestAccount, staffIdsOf } = require('../src/staff');

const DAY = 86400000;
const now = Date.now();

test('isStaffAccount: admin roles, bootstrap admin emails, STAFF_EMAILS; never guests or riders', () => {
  assert.equal(isStaffAccount({ role: 'MASTER_ADMIN', email: 'a@x.test' }), true);
  assert.equal(isStaffAccount({ role: 'ADMIN' }), true);
  assert.equal(isStaffAccount({ role: 'support_admin' }), true, 'any admin role');
  assert.equal(isStaffRole('RIDER'), false);
  assert.equal(isStaffRole('ROAD_CAPTAIN'), false);
  assert.equal(isStaffAccount({ role: 'RIDER', email: 'boss@coroute.test' }), true, 'bootstrap admin email');
  assert.equal(isStaffAccount({ role: 'RIDER', email: 'OPS@coroute.TEST' }), true, 'STAFF_EMAILS, any case');
  assert.equal(isStaffAccount({ role: 'RIDER', email: 'qa@coroute.test' }), true);
  assert.equal(isStaffAccount({ role: 'RIDER', email: 'rider@coroute.test' }), false);
  assert.equal(isStaffAccount({ provider: 'guest', email: 'guest_1_2@guest.coroute.local' }), false);
  assert.equal(isStaffAccount(null), false);
  assert.equal(isStaffAccount(undefined), false);
  assert.equal(isGuestAccount({ provider: 'guest' }), true);
  assert.deepEqual([...staffIdsOf([{ userId: 'a', role: 'MASTER_ADMIN' }, { userId: 'b', role: 'RIDER' }, { userId: 'c', email: 'qa@coroute.test' }])], ['a', 'c']);
});

test('staff are excluded from rider, member and revenue counts end to end', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const { api, soda, gw } = env;
  const repo = gw.repo;

  const boss = await env.register('Boss Admin', 'boss@coroute.test');
  const ops = await env.register('Ops Staff', 'ops@coroute.test');
  const rider = await env.register('Ravi Rider', 'ravi.staff@coroute.test');
  // Guest mode is retired (3.55); an account an older gateway created is still counted apart.
  const guestDoc = await repo.createUser({ userId: 'usr_quick_guest', name: 'Quick Guest', email: 'guest_9_1@guest.coroute.local', role: 'RIDER', provider: 'guest', createdAt: Date.now() });
  const guest = { json: { user: { userId: guestDoc.userId } } };
  const A = boss.token;
  const bossId = boss.user.userId;
  const opsId = ops.user.userId;
  const riderId = rider.user.userId;
  const guestId = guest.json.user.userId;
  assert.equal(boss.user.role, 'MASTER_ADMIN');
  assert.equal(ops.user.role, 'RIDER', 'STAFF_EMAILS does not grant admin rights');

  // A test ride the admin joined with a rider, and a rider-only ride.
  await soda.insert('convoys', {
    groupId: 'GRP-STAFF', name: 'Test ride', tripStatus: 'ENDED', createdAtEpochMs: now - DAY - 3600000, endedAtEpochMs: now - DAY,
    members: { [bossId]: { userId: bossId, name: 'Boss Admin', role: 'LEAD' }, [riderId]: { userId: riderId, name: 'Ravi Rider', role: 'PACK' } },
    updatedAt: now - DAY,
  });
  await soda.insert('convoys', {
    groupId: 'GRP-RIDERS', name: 'Real ride', tripStatus: 'ENDED', createdAtEpochMs: now - 2 * DAY - 3600000, endedAtEpochMs: now - 2 * DAY,
    members: { [riderId]: { userId: riderId, name: 'Ravi Rider', role: 'LEAD' }, [guestId]: { userId: guestId, name: 'Quick Guest', role: 'PACK' } },
    updatedAt: now - 2 * DAY,
  });
  // Staff checkout test (live mode) and a rider's real payment.
  await repo.saveRazorpayOrder({ orderId: 'order_staff_live', userId: opsId, planTier: 'proRider', billingCycle: 'monthly', amountInPaise: 14900, status: 'PAID', mode: 'live', couponCode: 'STAFFTEST', createdAt: now - DAY, paidAt: now - DAY });
  await repo.saveRazorpayOrder({ orderId: 'order_rider_live', userId: riderId, planTier: 'proRider', billingCycle: 'monthly', amountInPaise: 14900, status: 'PAID', mode: 'live', createdAt: now - DAY, paidAt: now - DAY });
  // A plan the admin granted themselves to test.
  const bossDoc = await repo.findUserById(bossId);
  await repo.updateUser(bossDoc.key, { subscriptionTier: 'roadCaptain', subscriptionValidUntil: now + 10 * DAY });

  await t.test('repo.staffUserIds finds the admin and the STAFF_EMAILS account only', async () => {
    const ids = await repo.staffUserIds();
    assert.deepEqual([...ids].sort(), [bossId, opsId].sort());
  });

  await t.test('admin overview: riders exclude staff, guests stay separate, staff payments apart, rides flagged', async () => {
    const res = await api('GET', '/admin/analytics/overview?days=30&fresh=1', null, A);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    const o = res.json;
    assert.equal(o.riders.total, 1, 'only Ravi');
    assert.equal(o.riders.staff, 2);
    assert.equal(o.riders.guests, 1);
    assert.equal(o.riders.active7d, 1);
    assert.equal(o.riders.newInPeriod, 1);
    assert.equal(o.riders.paying, 1);
    assert.equal(o.riders.conversionPct, 100);
    assert.equal(o.riders.planHolders, 0, 'the admin\'s own plan is not a rider plan');
    assert.equal(o.payments.paidOrders, 1);
    assert.equal(o.payments.revenueInr, 149);
    assert.equal(o.payments.staffPaidOrders, 1);
    assert.equal(o.payments.staffRevenueInr, 149);
    assert.equal(o.payments.couponOrders, 0, 'the staff coupon test is not counted');
    assert.equal(o.rides.groupsCompleted, 2, 'a ride with staff still counts as a ride');
    assert.equal(o.rides.withStaff, 1);
    assert.equal(o.rides.avgGroupSize, 1.5, 'group size counts riders only (1 and 2)');
  });

  await t.test('riders list: staff hidden from the list and total, found with staff=1, all with staff=all', async () => {
    const def = await api('GET', '/admin/analytics/riders?fresh=1', null, A);
    assert.equal(def.status, 200);
    assert.deepEqual(def.json.riders.map((x) => x.userId).sort(), [riderId, guestId].sort(), 'guests stay in the list as before');
    assert.equal(def.json.total, 2);
    assert.equal(def.json.staffCount, 2);
    assert.equal(def.json.excludesStaff, true);
    assert.ok(def.json.riders.every((x) => x.staff === false));
    assert.equal(def.json.riders.find((x) => x.userId === guestId).guest, true);
    const staff = await api('GET', '/admin/analytics/riders?staff=1', null, A);
    assert.deepEqual(staff.json.riders.map((x) => x.userId).sort(), [bossId, opsId].sort());
    assert.ok(staff.json.riders.every((x) => x.staff === true));
    assert.equal(staff.json.total, 2);
    const q = await api('GET', '/admin/analytics/riders?staff=1&q=ops', null, A);
    assert.deepEqual(q.json.riders.map((x) => x.userId), [opsId]);
    assert.equal((await api('GET', '/admin/analytics/riders?staff=all', null, A)).json.total, 4);
    const detail = await api('GET', `/admin/analytics/riders/${opsId}`, null, A);
    assert.equal(detail.json.rider.staff, true);
    assert.equal((await api('GET', `/admin/analytics/riders/${riderId}`, null, A)).json.rider.staff, false);
  });

  await t.test('groups: the ride with staff is listed and flagged hasStaff; members flagged', async () => {
    const list = await api('GET', '/admin/analytics/groups?status=ended', null, A);
    assert.equal(list.json.total, 2);
    const byId = Object.fromEntries(list.json.groups.map((g) => [g.groupId, g]));
    assert.equal(byId['GRP-STAFF'].hasStaff, true);
    assert.equal(byId['GRP-STAFF'].members, 2, 'the live member list is unchanged');
    assert.equal(byId['GRP-RIDERS'].hasStaff, false);
    const d = await api('GET', '/admin/analytics/groups/GRP-STAFF', null, A);
    assert.equal(d.json.group.hasStaff, true);
    assert.equal(d.json.members.find((m) => m.userId === bossId).staff, true);
    assert.equal(d.json.members.find((m) => m.userId === riderId).staff, false);
    const legacy = await api('GET', '/admin/groups', null, A);
    assert.equal(legacy.json.completed.find((c) => c.groupId === 'GRP-STAFF').hasStaff, true);
  });

  await t.test('/admin/stats and /admin/users: server counts exclude staff, guests as before', async () => {
    const s = await api('GET', '/admin/stats?days=30', null, A);
    assert.equal(s.status, 200);
    assert.equal(s.json.riders, 2, 'Ravi and the guest (guest handling unchanged), not the two staff');
    assert.equal(s.json.staff, 2);
    assert.equal(s.json.excludesStaff, true);
    assert.equal(s.json.newRiders, 2);
    assert.equal(s.json.rides.all, 2);
    assert.equal(s.json.ridesWithStaff, 1);
    assert.equal(s.json.avgGroupSize, 1.5);
    const u = await api('GET', '/admin/users', null, A);
    assert.equal(u.status, 200);
    assert.deepEqual(u.json.counts, { accounts: 4, riders: 1, staff: 2, guests: 1, onHold: 0, ridersOnHold: 0 });
    assert.equal(u.json.users.find((x) => x.userId === bossId).staff, true);
    assert.equal(u.json.users.find((x) => x.userId === opsId).staff, true);
    assert.equal(u.json.users.find((x) => x.userId === riderId).staff, false);
    assert.equal(u.json.users.find((x) => x.userId === guestId).staff, false);
  });

  await t.test('public usage stats and community stats leave staff out', async () => {
    const { publicUsage } = require('../src/admin_analytics');
    const p = await publicUsage(repo);
    assert.equal(p.riders, 1, 'Ravi only (guests were never counted here)');
    const res = await api('GET', '/public/usage-stats');
    assert.equal(res.json.stats.riders, 0, 'the public number is rounded down: below 10 reads as 0');
    const c = await api('GET', '/public/community-stats');
    assert.equal(c.status, 200);
    assert.equal(c.json.totalRiders, 0, 'public: rounded down');
    assert.equal((await repo.getCommunityStats()).totalRiders, 2, 'Ravi and the guest (guest handling unchanged), not the two staff');
  });

  await t.test('subscription overview, subscribers list and payment analytics leave staff out', async () => {
    const o = await api('GET', '/admin/subscription/overview', null, A);
    assert.equal(o.status, 200, JSON.stringify(o.json));
    assert.equal(o.json.totalUsers, 2);
    assert.equal(o.json.staffAccounts, 2);
    assert.equal(o.json.subscribers.roadCaptain, 0, 'the admin\'s own test plan is not a subscriber');
    assert.equal(o.json.paidOrders, 1);
    assert.equal(o.json.revenue.allTime, 149);
    assert.equal(o.json.staffPaidOrders, 1);
    assert.equal(o.json.staffRevenue.allTime, 149);
    const subs = await api('GET', '/admin/subscriptions', null, A);
    assert.ok(subs.json.subscribers.every((x) => x.staff === false));
    assert.equal(subs.json.total, 2);
    const staffSubs = await api('GET', '/admin/subscriptions?staff=1', null, A);
    assert.deepEqual(staffSubs.json.subscribers.map((x) => x.userId).sort(), [bossId, opsId].sort());

    const a = await api('GET', '/admin/payments/analytics?range=30d', null, A);
    assert.equal(a.status, 200, JSON.stringify(a.json));
    assert.equal(a.json.summary.paidOrders, 1);
    assert.equal(a.json.summary.netRevenueInr, 149);
    assert.equal(a.json.summary.staffPaidOrders, 1);
    assert.equal(a.json.summary.staffAmountInr, 149);
    assert.equal(a.json.summary.excludesStaff, true);
    const h = await api('GET', '/admin/payments/history', null, A);
    assert.equal(h.status, 200);
    const tx = Object.fromEntries(h.json.transactions.map((x) => [x.orderId, x]));
    assert.equal(tx.order_staff_live.staff, true);
    assert.equal(tx.order_rider_live.staff, false);
  });
});
