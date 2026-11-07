'use strict';
process.env.NODE_ENV = 'test';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_analytics1';
process.env.RAZORPAY_TEST_KEY_SECRET = 'analytics_secret_2';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_analytics_3';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

// Admin analytics, per-rider configuration, public usage stats and the coupon <-> plan binding.
const test = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

const DAY = 86400000;
const now = Date.now();

test('admin analytics, rider config, public usage stats, coupon plan binding', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const { api, soda, gw } = env;
  const repo = gw.repo;

  // ---- empty database: honest zeros, null rating, no PII ----
  await t.test('public usage stats on an empty database are zeros and a null rating', async () => {
    const res = await api('GET', '/public/usage-stats');
    assert.equal(res.status, 200);
    assert.equal(res.json.ok, true);
    assert.deepEqual(Object.keys(res.json.stats).sort(), ['avgRating', 'avgSpeedKmh', 'groupsRidden', 'kmRidden', 'movingHours', 'riders', 'ridesCompleted', 'sosResolved', 'updatedAt', 'weeklyKm']);
    const imp = await api('GET', '/public/impact-stats');
    assert.equal(imp.status, 200);
    assert.equal(imp.json.stats.longestTripKm, 0, 'no records shown on an empty database');
    assert.equal(imp.json.stats.safety.medianResponseSec, null);
    assert.equal(res.json.stats.riders, 0);
    assert.equal(res.json.stats.ridesCompleted, 0);
    assert.equal(res.json.stats.kmRidden, 0);
    assert.equal(res.json.stats.avgRating, null);
    assert.match(res.headers.get('cache-control'), /max-age=300/);
  });

  const admin = await env.register('Asha Admin', 'admin@coroute.test');
  const r1 = await env.register('Ravi Rider', 'ravi@coroute.test');
  const r2 = await env.register('Meera Rider', 'meera@coroute.test');
  const A = admin.token;
  const u1 = r1.user.userId;
  const u2 = r2.user.userId;

  // ---- seed real-shaped documents ----
  const userDoc1 = await repo.findUserById(u1);
  await repo.updateUser(userDoc1.key, { lastActiveAt: now - 2 * DAY });
  const userDoc2 = await repo.findUserById(u2);
  await repo.updateUser(userDoc2.key, { lastActiveAt: now - 20 * DAY });

  await repo.saveTrip({ tripId: 'TRIP-A1', userId: u1, groupId: 'GRP-ONE', totalDistanceKm: 120, movingMs: 2 * 3600000, topSpeedKmh: 88, endTimeEpochMs: now - DAY, startTimeEpochMs: now - DAY - 3 * 3600000, source: 'server' });
  await repo.saveTrip({ tripId: 'TRIP-A2', userId: u1, groupId: 'GRP-TWO', totalDistanceKm: 30, movingMs: 3600000, topSpeedKmh: 70, endTimeEpochMs: now - 40 * DAY, startTimeEpochMs: now - 40 * DAY - 3600000, source: 'server' });
  await repo.saveTrip({ tripId: 'TRIP-B1', userId: u2, groupId: 'GRP-ONE', totalDistanceKm: 118, movingMs: 2 * 3600000, topSpeedKmh: 80, endTimeEpochMs: now - DAY, startTimeEpochMs: now - DAY - 3 * 3600000, source: 'server' });

  await soda.insert('convoys', {
    groupId: 'GRP-ONE', name: 'Coastal run', tripStatus: 'ENDED', createdByUserName: 'Ravi Rider', createdAtEpochMs: now - DAY - 4 * 3600000, endedAtEpochMs: now - DAY,
    members: { [u1]: { userId: u1, name: 'Ravi Rider', role: 'LEAD' }, [u2]: { userId: u2, name: 'Meera Rider', role: 'SWEEPER' } },
    stopPoints: [{ id: 's1', isVisited: true }, { id: 's2', isVisited: false }],
    report: { version: 1, group: { distanceM: 120000, durationMs: 4 * 3600000, sos: 1, arrived: 2, members: 2 },
      members: [
        { userId: u1, name: 'Ravi Rider', role: 'LEAD', trackAvailable: true, distanceM: 120000, movingMs: 7200000, avgMovingKmh: 60, maxKmh: 88, sos: 1, separatedMs: 0, offRouteMs: 0, reachedDestination: true },
        { userId: u2, name: 'Meera Rider', role: 'SWEEPER', trackAvailable: true, distanceM: 118000, movingMs: 7200000, avgMovingKmh: 59, maxKmh: 80, sos: 0, separatedMs: 60000, offRouteMs: 0, reachedDestination: true },
      ] },
    updatedAt: now - DAY,
  });
  await soda.insert('convoys', {
    groupId: 'GRP-TWO', name: 'Solo hills', tripStatus: 'ENDED', createdAtEpochMs: now - 40 * DAY - 3600000, endedAtEpochMs: now - 40 * DAY,
    members: { [u1]: { userId: u1, name: 'Ravi Rider', role: 'LEAD' } }, updatedAt: now - 40 * DAY,
  });
  for (const [i, type] of ['REGROUP_INITIATED', 'REGROUP_INITIATED', 'SEPARATED', 'POSSIBLE_INCIDENT', 'OVERSPEED'].entries()) {
    await soda.insert('trip_events', { eventId: `EV-${i}`, groupId: 'GRP-ONE', userId: u2, type, startedAt: now - DAY - 3600000 + i });
  }
  // SOS: one answered after 90 s and resolved after 10 min, one false alarm.
  await soda.insert('alerts', { alertId: 'SOS-1', groupId: 'GRP-ONE', userId: u1, alertType: 'MANUAL', timestamp: now - DAY - 7200000, resolved: true, resolvedAt: now - DAY - 7200000 + 600000, resolveReason: 'RESOLVED', status: 'RESOLVED',
    responders: { [u2]: { userId: u2, name: 'Meera Rider', kind: 'GOING', at: now - DAY - 7200000 + 90000 } } });
  await soda.insert('alerts', { alertId: 'SOS-2', groupId: 'GRP-TWO', userId: u1, alertType: 'MANUAL', timestamp: now - 40 * DAY, resolved: true, resolvedAt: now - 40 * DAY + 30000, resolveReason: 'FALSE_ALARM', status: 'FALSE_ALARM', responders: {} });

  await repo.saveRazorpayOrder({ orderId: 'order_live_1', userId: u1, planTier: 'proRider', billingCycle: 'monthly', amountInPaise: 14900, status: 'PAID', mode: 'live', couponCode: 'WELCOME50', createdAt: now - 3 * DAY, paidAt: now - 3 * DAY });
  await repo.saveRazorpayOrder({ orderId: 'order_test_1', userId: u2, planTier: 'roadCaptain', billingCycle: 'monthly', amountInPaise: 59900, status: 'PAID', mode: 'test', createdAt: now - 2 * DAY, paidAt: now - 2 * DAY });
  await repo.saveRazorpayOrder({ orderId: 'order_created_1', userId: u2, planTier: 'roadCaptain', billingCycle: 'monthly', amountInPaise: 59900, status: 'CREATED', mode: 'test', createdAt: now - DAY });
  await repo.submitDiagnostic({ diagnosticId: 'DIAG-A1', riderId: u1, deviceInfo: { manufacturer: 'Samsung', model: 'SM-A546', osVersion: '14' }, appVersion: '3.53.0', overallResult: 'PASS', timestamp: now - DAY, categories: {} });
  await soda.insert('feedback', { feedbackId: 'FB-1', tripId: 'TRIP-A1', userId: u1, status: 'APPROVED', rating: 5, submittedAt: now, createdAt: now });
  await soda.insert('feedback', { feedbackId: 'FB-2', tripId: 'TRIP-B1', userId: u2, status: 'APPROVED', rating: 4, submittedAt: now, createdAt: now });
  await soda.insert('feedback', { feedbackId: 'FB-3', tripId: 'TRIP-B1', userId: u2, status: 'PENDING_REVIEW', rating: 1, submittedAt: now, createdAt: now });

  await t.test('every new admin endpoint is admin-only', async () => {
    const paths = [
      ['GET', '/admin/analytics/overview'], ['GET', '/admin/analytics/riders'], ['GET', `/admin/analytics/riders/${u1}`],
      ['GET', '/admin/analytics/groups'], ['GET', '/admin/analytics/groups/GRP-ONE'], ['GET', `/admin/users/${u1}/config`],
      ['PATCH', `/admin/users/${u1}/config`, { role: 'MASTER_ADMIN' }], ['GET', '/admin/coupons/plan-options'],
    ];
    for (const [m, p, body] of paths) {
      assert.equal((await api(m, p, body, r1.token)).status, 403, `${m} ${p} as rider`);
      assert.equal((await api(m, p, body)).status, 401, `${m} ${p} without a token`);
    }
    assert.equal((await repo.findUserById(u1)).role, 'RIDER');
  });

  await t.test('overview counts what is stored', async () => {
    const res = await api('GET', '/admin/analytics/overview?days=30', null, A);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    const o = res.json;
    assert.equal(o.truncated, false);
    // The admin is staff, not a rider: Ravi and Meera only.
    assert.equal(o.riders.total, 2);
    assert.equal(o.riders.staff, 1);
    assert.equal(o.riders.excludesStaff, true);
    assert.equal(o.riders.active7d, 1); // Ravi (the just-registered admin is not counted)
    assert.equal(o.riders.active30d, 2);
    assert.equal(o.riders.paying, 1); // only the live paid order counts
    assert.equal(o.riders.conversionPct, 50);
    assert.equal(o.rides.completedTrips, 3);
    assert.equal(o.rides.tripsInPeriod, 2);
    assert.equal(o.rides.kmRidden, 268);
    assert.equal(o.rides.kmInPeriod, 238);
    assert.equal(o.rides.groupsCompleted, 2);
    assert.equal(o.rides.groupsInPeriod, 1);
    assert.equal(o.rides.groupKm, 120);
    assert.equal(o.rides.ridingHours, 5);
    assert.equal(o.rides.avgGroupSize, 1.5);
    assert.equal(o.safety.sosTotal, 2);
    assert.equal(o.safety.resolved, 1);
    assert.equal(o.safety.falseAlarms, 1);
    assert.equal(o.safety.open, 0);
    assert.equal(o.safety.medianResponseSec, 90);
    assert.equal(o.safety.medianResolveSec, 600);
    assert.equal(o.payments.paidOrders, 1);
    assert.equal(o.payments.revenueInr, 149);
    assert.equal(o.payments.testRevenueInr, 599);
    assert.equal(o.payments.couponOrders, 1);
  });

  await t.test('riders list: search, sort, filter and paging', async () => {
    const all = await api('GET', '/admin/analytics/riders?sort=km&limit=1', null, A);
    assert.equal(all.status, 200);
    assert.equal(all.json.total, 2); // the admin is staff: listed under staff=1, not in the total
    assert.equal(all.json.staffCount, 1);
    assert.equal(all.json.riders.length, 1);
    assert.equal(all.json.nextCursor, 1);
    assert.equal(all.json.riders[0].userId, u1);
    assert.equal(all.json.riders[0].km, 150);
    assert.equal(all.json.riders[0].trips, 2);
    assert.equal(all.json.riders[0].sos, 2);
    const next = await api('GET', '/admin/analytics/riders?sort=km&limit=1&cursor=1', null, A);
    assert.equal(next.json.riders.length, 1);
    assert.equal(next.json.nextCursor, null);
    const q = await api('GET', '/admin/analytics/riders?q=meera', null, A);
    assert.deepEqual(q.json.riders.map((x) => x.userId), [u2]);
  });

  await t.test('rider drill-down: trips, km, hours, speed, SOS, plan, payments, devices, last seen', async () => {
    const res = await api('GET', `/admin/analytics/riders/${u1}`, null, A);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    const d = res.json;
    assert.equal(d.rider.name, 'Ravi Rider');
    assert.equal(d.stats.trips, 2);
    assert.equal(d.stats.km, 150);
    assert.equal(d.stats.ridingHours, 3);
    assert.equal(d.stats.avgSpeedKmh, 50);
    assert.equal(d.stats.topSpeedKmh, 88);
    assert.equal(d.stats.groups, 2);
    assert.equal(d.stats.sos, 2);
    assert.equal(d.stats.falseAlarms, 1);
    assert.equal(d.plan.tier, 'community');
    assert.equal(d.payments.paid, 1);
    assert.equal(d.payments.totalPaidInr, 149);
    assert.equal(d.payments.recent[0].couponCode, 'WELCOME50');
    assert.equal(d.devices.length, 1);
    assert.equal(d.devices[0].model, 'SM-A546');
    assert.ok(d.rider.lastSeenAt >= now - 2 * DAY);
    assert.equal((await api('GET', '/admin/analytics/riders/usr_missing', null, A)).status, 404);
  });

  await t.test('groups list and group drill-down: members, distance, duration, regroups, alerts, incidents', async () => {
    const list = await api('GET', '/admin/analytics/groups?status=ended', null, A);
    assert.equal(list.status, 200);
    assert.equal(list.json.total, 2);
    assert.equal(list.json.groups[0].groupId, 'GRP-ONE'); // newest first
    assert.equal(list.json.groups[0].distanceKm, 120);
    const res = await api('GET', '/admin/analytics/groups/GRP-ONE', null, A);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    const g = res.json;
    assert.equal(g.stats.members, 2);
    assert.equal(g.stats.distanceKm, 120);
    assert.equal(g.stats.durationMs, 4 * 3600000);
    assert.equal(g.stats.regroups, 2);
    assert.equal(g.stats.separations, 1);
    assert.equal(g.stats.incidents, 1);
    assert.equal(g.stats.overspeed, 1);
    assert.equal(g.stats.stopsPlanned, 2);
    assert.equal(g.stats.stopsVisited, 1);
    assert.equal(g.stats.alerts.total, 1);
    assert.equal(g.stats.alerts.resolved, 1);
    assert.equal(g.stats.alerts.medianResponseSec, 90);
    assert.equal(g.members.length, 2);
    assert.equal(g.members[0].distanceKm, 120);
    assert.equal((await api('GET', '/admin/analytics/groups/GRP-NONE', null, A)).status, 404);
  });

  await t.test('rider config: validation codes and self-protection', async () => {
    const bad = async (body, code) => {
      const r = await api('PATCH', `/admin/users/${u2}/config`, body, A);
      assert.equal(r.status, 400, JSON.stringify(r.json));
      assert.equal(r.json.code, code);
    };
    await bad({ role: 'GOD' }, 'BAD_ROLE');
    await bad({ status: 'GONE' }, 'BAD_STATUS');
    await bad({ plan: { tier: 'platinum' } }, 'BAD_TIER');
    await bad({ plan: { tier: 'proRider', days: 0 } }, 'BAD_DAYS');
    await bad({ limits: { maxTrips: -1 } }, 'BAD_LIMIT');
    await bad({}, 'NOTHING_TO_CHANGE');
    const self = await api('PATCH', `/admin/users/${admin.user.userId}/config`, { status: 'BLOCKED' }, A);
    assert.equal(self.status, 409);
    assert.equal(self.json.code, 'SELF_CHANGE');
    assert.equal((await api('PATCH', '/admin/users/usr_missing/config', { status: 'ACTIVE' }, A)).status, 404);
  });

  await t.test('rider config: plan grant and revoke, trip limit enforced, block, role; every change audited', async () => {
    // 3.55: the console assigns the plans riders have, as a real membership the rider's app reads.
    const grant = await api('PATCH', `/admin/users/${u2}/config`, { plan: { tier: 'group_large', days: 30, note: 'club lead' } }, A);
    assert.equal(grant.status, 200, JSON.stringify(grant.json));
    assert.equal(grant.json.config.plan.tier, 'group_large');
    assert.equal(grant.json.config.plan.source, 'membership');
    assert.ok(grant.json.config.plan.daysRemaining >= 29);
    const mine = await api('GET', '/membership/my', null, r2.token);
    assert.equal(mine.json.plan.category, 'group_large', 'the rider sees the plan the admin gave');
    assert.equal(mine.json.plan.canHostGroup, true);
    // Same plan again: the days add to the time left.
    const more = await api('PATCH', `/admin/users/${u2}/config`, { plan: { tier: 'group_large', days: 10 } }, A);
    assert.ok(more.json.config.plan.daysRemaining >= 39, JSON.stringify(more.json.config.plan));
    // A legacy name from an older console maps to its plan (roadCaptain -> Large Group).
    const legacyName = await api('PATCH', `/admin/users/${u2}/config`, { plan: { tier: 'roadCaptain', days: 1 } }, A);
    assert.equal(legacyName.json.config.plan.tier, 'group_large');
    const listed = await api('GET', '/admin/analytics/riders?tier=group_large&staff=all', null, A);
    assert.ok(listed.json.riders.some((x) => x.userId === u2 && x.planName), JSON.stringify(listed.json.riders.map((x) => [x.userId, x.tier])));

    const limit = await api('PATCH', `/admin/users/${u2}/config`, { limits: { maxTrips: 1 } }, A);
    assert.equal(limit.status, 200);
    assert.equal(limit.json.config.limits.maxTrips, 1);
    // Meera already has one trip stored: a new one is refused with the admin's cap.
    const trip = await api('POST', '/trips', { tripId: 'TRIP-NEW-1', tripName: 'x', endTimeEpochMs: now }, r2.token);
    assert.equal(trip.status, 409);
    assert.equal(trip.json.code, 'TOO_MANY_TRIPS');
    assert.match(trip.json.error, /up to 1 trips/);
    const reset = await api('PATCH', `/admin/users/${u2}/config`, { limits: { maxTrips: null } }, A);
    assert.equal(reset.json.config.limits.maxTrips, null);
    assert.equal((await api('POST', '/trips', { tripId: 'TRIP-NEW-1', tripName: 'x', endTimeEpochMs: now }, r2.token)).status, 201);

    const revoke = await api('PATCH', `/admin/users/${u2}/config`, { plan: { tier: 'community' } }, A);
    assert.equal(revoke.json.config.plan.tier, 'community');
    assert.equal((await api('GET', '/membership/my', null, r2.token)).json.plan.category, 'community', 'removed for the rider too');
    const bad = await api('PATCH', `/admin/users/${u2}/config`, { plan: { tier: 'diamond', days: 3 } }, A);
    assert.equal(bad.status, 400);
    assert.equal(bad.json.code, 'BAD_TIER');

    const block = await api('PATCH', `/admin/users/${u2}/config`, { status: 'BLOCKED', reason: 'chargeback' }, A);
    assert.equal(block.status, 200);
    assert.equal(block.json.config.status, 'BLOCKED');
    assert.equal((await api('GET', '/me', null, r2.token)).status, 403);
    assert.equal((await api('PATCH', `/admin/users/${u2}/config`, { status: 'ACTIVE' }, A)).json.config.status, 'ACTIVE');

    const role = await api('PATCH', `/admin/users/${u1}/config`, { role: 'MASTER_ADMIN' }, A);
    assert.equal(role.json.config.role, 'MASTER_ADMIN');
    assert.deepEqual(role.json.changed, ['role']);
    await api('PATCH', `/admin/users/${u1}/config`, { role: 'RIDER' }, A);

    const audit = await api('GET', '/admin/audit?limit=100', null, A);
    const actions = audit.json.entries.filter((e) => e.target === u2).map((e) => e.action);
    for (const a of ['subscription.grant', 'user.limits', 'subscription.revoke', 'user.status']) assert.ok(actions.includes(a), `${a} in ${actions}`);
    assert.ok(audit.json.entries.some((e) => e.target === u1 && e.action === 'user.role' && e.details.to === 'MASTER_ADMIN'));
    const detail = await api('GET', `/admin/analytics/riders/${u2}`, null, A);
    assert.ok(detail.json.audit.length >= 4);
  });

  await t.test('coupon plan binding: options, unknown plan, wrong plan, expired, per-rider limit', async () => {
    const opts = await api('GET', '/admin/coupons/plan-options', null, A);
    assert.equal(opts.status, 200);
    const ids = opts.json.plans.map((p) => p.id);
    // Only the paid plans can be bound (Community is free); legacy tiers are not offered any more.
    assert.deepEqual(ids, ['group_small', 'group_large']);

    const unknown = await api('POST', '/admin/coupons', { code: 'BADPLAN10', discountType: 'percentage', discountValue: 10, applicablePlans: ['group_small', 'diamond'] }, A);
    assert.equal(unknown.status, 400);
    assert.equal(unknown.json.reason, 'UNKNOWN_PLAN');
    assert.deepEqual(unknown.json.unknown, ['diamond']);
    const legacyOnly = await api('POST', '/admin/coupons', { code: 'PROONLY20', discountType: 'percentage', discountValue: 20, applicablePlans: ['pro'] }, A);
    assert.equal(legacyOnly.status, 400);
    assert.equal(legacyOnly.json.reason, 'UNKNOWN_PLAN');

    const window = await api('POST', '/admin/coupons', { code: 'BADWIN10', discountType: 'percentage', discountValue: 10, validFrom: now, expiresAt: now - 1000 }, A);
    assert.equal(window.status, 400);
    assert.equal(window.json.reason, 'BAD_WINDOW');

    const ok = await api('POST', '/admin/coupons', { code: 'SMALLONLY20', discountType: 'percentage', discountValue: 20, applicablePlans: ['group_small', 'pro'], maxUsagePerUser: 1, maxUsageTotal: 10 }, A);
    assert.equal(ok.status, 201, JSON.stringify(ok.json));
    assert.deepEqual(ok.json.coupon.applicableTiers, ['group_small']); // a legacy alias is dropped, never stored

    const right = await api('POST', '/membership/validate-coupon', { code: 'SMALLONLY20', category: 'group_small' }, r1.token);
    assert.equal(right.status, 200, JSON.stringify(right.json));
    assert.equal(right.json.finalAmount, 39);
    const wrong = await api('POST', '/membership/validate-coupon', { code: 'SMALLONLY20', category: 'group_large' }, r1.token);
    assert.equal(wrong.status, 400);
    assert.equal(wrong.json.reason, 'TIER_MISMATCH');
    // A legacy order is refused before any coupon is looked at.
    const legacyOrder = await api('POST', '/subscription/create-order', { planTier: 'roadCaptain', billingCycle: 'monthly', couponCode: 'SMALLONLY20' }, r1.token);
    assert.equal(legacyOrder.status, 410);
    assert.equal(legacyOrder.json.code, 'LEGACY_PLAN');

    // Patch the binding; unknown ids are refused on edit too, legacy ids are dropped.
    assert.equal((await api('PATCH', '/admin/coupons/SMALLONLY20', { applicablePlans: ['nope'] }, A)).json.reason, 'UNKNOWN_PLAN');
    const patched = await api('PATCH', '/admin/coupons/SMALLONLY20', { applicablePlans: ['proRider', 'group_large'] }, A);
    assert.equal(patched.status, 200);
    assert.deepEqual(patched.json.coupon.applicableTiers, ['group_large']);

    // Expired.
    await api('POST', '/admin/coupons', { code: 'OLDNEWS5', discountType: 'fixed', discountValue: 5, validFrom: now - 10 * DAY, expiresAt: now - DAY }, A);
    const memExpired = await api('POST', '/membership/order', { category: 'group_small', offerCode: 'OLDNEWS5' }, r1.token);
    assert.equal(memExpired.status, 400);
    assert.equal(memExpired.json.reason, 'COUPON_EXPIRED');

    // Per-rider limit: a used coupon is refused for that rider only.
    await repo.recordCouponUsage('SMALLONLY20', { userId: u1, orderId: 'order_x', discountAmount: 10 });
    const memAgain = await api('POST', '/membership/order', { category: 'group_large', offerCode: 'SMALLONLY20' }, r1.token);
    assert.equal(memAgain.status, 400);
    assert.equal(memAgain.json.reason, 'PER_USER_LIMIT_REACHED');
    const other = await api('POST', '/membership/validate-coupon', { code: 'SMALLONLY20', category: 'group_large' }, r2.token);
    assert.equal(other.status, 200);

    // A code that matches nothing is refused at membership checkout (never silently full price).
    const nothing = await api('POST', '/membership/order', { category: 'group_small', offerCode: 'NOSUCHCODE' }, r1.token);
    assert.equal(nothing.status, 404);
    assert.equal(nothing.json.reason, 'COUPON_NOT_FOUND');
    // A free activation must name its coupon.
    const noCoupon = await api('POST', '/membership/activate-free', { category: 'group_small' }, r1.token);
    assert.equal(noCoupon.status, 400);
    assert.equal(noCoupon.json.reason, 'COUPON_REQUIRED');
  });

  await t.test('plans: features and the on-sale toggle', async () => {
    const put = await api('PUT', '/admin/subscription/pricing', { plans: { tourOperator: { features: ['Fleet view', 'Priority support'], isActive: false } } }, A);
    assert.equal(put.status, 200, JSON.stringify(put.json));
    assert.deepEqual(put.json.plans.tourOperator.features, ['Fleet view', 'Priority support']);
    assert.equal(put.json.plans.tourOperator.isActive, false);
    // Legacy tiers are not sold at all any more (old builds get 410 LEGACY_PLAN).
    const order = await api('POST', '/subscription/create-order', { planTier: 'tourOperator', billingCycle: 'monthly' }, r1.token);
    assert.equal(order.status, 410);
    assert.equal(order.json.reason, 'LEGACY_PLAN');

    const catalog = await repo.getMembershipCatalog();
    catalog.group_large.isActive = false;
    assert.equal((await api('PUT', '/admin/membership/catalog', { catalog }, A)).status, 200);
    const pub = await api('GET', '/membership/catalog', null, r1.token);
    assert.equal(pub.json.categories.group_large, undefined);
    assert.ok(pub.json.categories.group_small);
    assert.equal(pub.json.categories.individual, undefined, 'the retired Individual plan is not listed');
    assert.equal(pub.json.categories.community.monthlyPriceInr, 0, 'Community is listed (free, not sold)');
    assert.equal(pub.json.categories.community.purchasable, false);
    const mo = await api('POST', '/membership/order', { category: 'group_large' }, r1.token);
    assert.equal(mo.status, 400);
    assert.equal(mo.json.reason, 'PLAN_INACTIVE');

    const badCatalog = await api('PUT', '/admin/membership/catalog', { catalog: { individual: { name: 'Solo', monthlyPriceInr: -1 } } }, A);
    assert.equal(badCatalog.status, 400);
    assert.equal(badCatalog.json.reason, 'INVALID_CATALOG');
  });

  await t.test('payments list filters by plan, coupon and id search', async () => {
    const byPlan = await api('GET', '/admin/payments?plan=roadCaptain', null, A);
    assert.equal(byPlan.status, 200);
    assert.ok(byPlan.json.payments.length >= 2);
    assert.ok(byPlan.json.payments.every((p) => p.planTier === 'roadCaptain'));
    const byCoupon = await api('GET', '/admin/payments?coupon=welcome50', null, A);
    assert.deepEqual(byCoupon.json.payments.map((p) => p.orderId), ['order_live_1']);
    const byQ = await api('GET', '/admin/payments?q=order_test', null, A);
    assert.deepEqual(byQ.json.payments.map((p) => p.orderId), ['order_test_1']);
  });

  await t.test('public usage stats: aggregated, cached, no personal data, can be switched off', async () => {
    // The empty answer above is cached for 5 minutes; the aggregate itself is checked directly.
    const { publicUsage } = require('../src/admin_analytics');
    const s = await publicUsage(repo);
    assert.equal(s.riders, 2); // the admin is staff
    assert.equal(s.ridesCompleted, 4); // three seeded + the one Meera saved above
    assert.equal(s.kmRidden, 268);
    assert.equal(s.groupsRidden, 1); // only rides with two or more riders
    assert.equal(s.sosResolved, 1); // the false alarm is not counted
    assert.equal(s.avgRating, 4.5); // approved reviews only
    const res = await api('GET', '/usage-stats');
    assert.equal(res.status, 200);
    const text = JSON.stringify(res.json);
    for (const pii of ['Ravi', 'Meera', '@coroute.test', u1, u2, 'GRP-ONE', 'lat']) assert.ok(!text.includes(pii), `no ${pii}`);
    await api('PUT', '/admin/community-stats/config', { showPublicStats: false }, A);
    const off = await api('GET', '/public/usage-stats');
    assert.equal(off.json.enabled, false);
    assert.equal(off.json.stats, null);
    await api('PUT', '/admin/community-stats/config', { showPublicStats: true }, A);
  });
});
