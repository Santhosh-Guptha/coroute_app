'use strict';
/**
 * The membership plans are the single source of truth for hosting (Individual, Small Group 2-6,
 * Large Group 7-12): the convoy's capacity is the host's seats (not MAX_CONVOY_RIDERS), joining an
 * invited ride is free, a legacy paid tier keeps equivalent access until it ends, legacy plans are
 * no longer sold (410 LEGACY_PLAN) and coupons bind to the three plans only.
 */
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.MAX_CONVOY_RIDERS = '50';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_planKey';
process.env.RAZORPAY_TEST_KEY_SECRET = 'plan_secret_123';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_plan_123';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const config = require('../src/config');
const { planFrom, clampSeats, LEGACY_PLAN_MAP } = require('../src/entitlements');
const { boot } = require('./_helpers');

const DAY = 86400000;

test('entitlements: one plan from membership or legacy tier, never above the server ceiling', () => {
  const now = Date.now();
  // Every rider has Community (free, solo rides) when nothing else applies.
  assert.deepEqual([planFrom({ now }).source, planFrom({ now }).seats, planFrom({ now }).canStartTrip, planFrom({ now }).canHostGroup], ['community', 1, true, false]);
  const small = planFrom({ membership: { category: 'group_small', capacity: 6, status: 'ACTIVE', validUntil: now + DAY }, now });
  assert.deepEqual([small.source, small.seats, small.canHostGroup], ['membership', 6, true]);
  const solo = planFrom({ membership: { category: 'individual', capacity: 1, status: 'ACTIVE', validUntil: now + DAY }, now });
  assert.deepEqual([solo.seats, solo.canStartTrip, solo.canHostGroup], [1, true, false]);
  const lapsed = planFrom({ membership: { category: 'group_large', capacity: 12, status: 'ACTIVE', validUntil: now - 1 }, now });
  assert.equal(lapsed.source, 'community');
  // Legacy: proRider hosted up to 4 bikes before, so it keeps hosting up to 6; captains get 12.
  assert.equal(LEGACY_PLAN_MAP.proRider.seats, 6);
  const pro = planFrom({ userDoc: { subscriptionTier: 'proRider', subscriptionValidUntil: now + 5 * DAY }, now });
  assert.deepEqual([pro.source, pro.seats, pro.legacyTier, pro.name], ['legacy', 6, 'proRider', 'CoRoute Pro']);
  const cap = planFrom({ userDoc: { subscriptionTier: 'roadCaptain', subscriptionValidUntil: now + 5 * DAY }, now });
  assert.equal(cap.seats, 12);
  assert.equal(planFrom({ userDoc: { subscriptionTier: 'tourOperator', subscriptionValidUntil: now - 1 }, now }).source, 'community');
  // A legacy tier wins only when it gives more seats (never a loss for the rider).
  const both = planFrom({ membership: { category: 'individual', capacity: 1, status: 'ACTIVE', validUntil: now + DAY }, userDoc: { subscriptionTier: 'roadCaptain', subscriptionValidUntil: now + DAY }, now });
  assert.deepEqual([both.source, both.seats], ['legacy', 12]);
  // MAX_CONVOY_RIDERS stays only as the absolute ceiling.
  const before = config.maxConvoyRiders;
  config.maxConvoyRiders = 8;
  try { assert.equal(clampSeats(12), 8); assert.equal(planFrom({ membership: { category: 'group_large', capacity: 12, status: 'ACTIVE', validUntil: now + DAY }, now }).seats, 8); } finally { config.maxConvoyRiders = before; }
});

test('membership plans drive hosting, capacity and the legacy cut-over', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const repo = env.gw.repo;
  const admin = await env.register('Plans Admin', 'admin@coroute.test');
  const giveMembership = async (user, category, capacity, validUntil = Date.now() + 30 * DAY) => {
    await repo.saveMembership({ membershipId: `mem_${user.userId}`, ownerUserId: user.userId, category, categoryName: category, capacity, status: 'ACTIVE', validFrom: Date.now(), validUntil, members: {} });
  };
  const riders = [];
  for (let i = 0; i < 8; i++) riders.push(await env.register(`Plan Rider ${i}`, `plan.rider${i}@coroute.test`));
  const endRide = async (token, groupId) => assert.equal((await env.api('POST', `/convoys/${groupId}/status`, { status: 'ENDED' }, token)).status, 200);

  await t.test('Community (free, default): starts a solo ride of 1; joins an invited ride for free', async () => {
    const host = await env.register('Small Host', 'small.host@coroute.test');
    const solo = await env.api('POST', '/convoys', { name: 'Community ride' }, host.token);
    assert.equal(solo.status, 201, JSON.stringify(solo.json));
    assert.equal(solo.json.capacity, 1);
    assert.equal(solo.json.soloRide, true);
    assert.equal(solo.json.capacityPlan, 'community');
    const my = await env.api('GET', '/membership/my', null, host.token);
    assert.deepEqual([my.json.plan.source, my.json.plan.category, my.json.plan.seats, my.json.plan.canStartTrip, my.json.plan.canHostGroup, my.json.plan.isFree], ['community', 'community', 1, true, false, true]);
    assert.equal(my.json.effectiveEntitlements.ptt, false);
    await endRide(host.token, solo.json.groupId);
    t.host = host;
  });

  await t.test('Small Group (Rs 49): capacity 6 stored at creation, 7th rider gets 409 CONVOY_FULL', async () => {
    const host = t.host;
    await giveMembership(host.user, 'group_small', 6);
    const created = await env.api('POST', '/convoys', { name: 'Six pack' }, host.token);
    assert.equal(created.status, 201, JSON.stringify(created.json));
    assert.equal(created.json.capacity, 6, 'the host membership seats, not MAX_CONVOY_RIDERS');
    assert.equal(created.json.capacityPlan, 'group_small');
    const room = await env.gw.convoys.getRoom(created.json.groupId);
    assert.equal(room.meta.capacity, 6);
    // Riders without any plan join free; host + 5 = 6.
    for (let i = 0; i < 5; i++) {
      const j = await env.api('POST', '/convoys/join', { code: created.json.joinCode }, riders[i].token);
      assert.equal(j.status, 200, JSON.stringify(j.json));
      assert.equal(j.json.capacity, 6);
      assert.equal(Object.keys(j.json.riders).length, i + 2);
    }
    const seventh = await env.api('POST', '/convoys/join', { code: created.json.joinCode }, riders[5].token);
    assert.equal(seventh.status, 409);
    assert.equal(seventh.json.code, 'CONVOY_FULL');
    // A rider already in the ride can always re-join.
    assert.equal((await env.api('POST', '/convoys/join', { code: created.json.joinCode }, riders[0].token)).status, 200);
    // One member with a plan hosts; the planless joiner keeps no plan of their own but gets the
    // group features of the host's ride (no paywall for joiners).
    const joinerMy = await env.api('GET', '/membership/my', null, riders[0].token);
    assert.deepEqual([joinerMy.json.plan.source, joinerMy.json.plan.canHostGroup], ['community', false]);
    assert.equal(joinerMy.json.effectiveEntitlements.ptt, true, 'group talk comes with the host plan');
    assert.equal(joinerMy.json.effectiveEntitlements.convoy, true);
    t.smallRide = created.json;
  });

  await t.test('upgrading to Large Group during the ride raises the capacity at once (CONFIG + snapshot)', async () => {
    const ws = await env.joinRoom(riders[0].token, t.smallRide.groupId);
    assert.equal(ws.snapshot.capacity, 6);
    const c = await env.api('POST', '/admin/coupons', { code: 'UPTO12FREE', discountType: 'free', discountValue: 100, applicablePlans: ['group_large'], maxUsageTotal: 5, maxUsagePerUser: 1 }, admin.token);
    assert.equal(c.status, 201, JSON.stringify(c.json));
    const up = await env.api('POST', '/membership/activate-free', { category: 'group_large', couponCode: 'UPTO12FREE' }, t.host.token);
    assert.ok([200, 201].includes(up.status), JSON.stringify(up.json));
    const cfg = await ws.next((m) => m.type === 'CONFIG' && m.capacity === 12, 3000);
    assert.equal(cfg.capacityPlan, 'group_large');
    const snap = await env.api('GET', `/convoys/${t.smallRide.groupId}`, null, riders[0].token);
    if (snap.status === 200) assert.equal(snap.json.capacity, 12);
    const seventh = await env.api('POST', '/convoys/join', { code: t.smallRide.joinCode }, riders[5].token);
    assert.equal(seventh.status, 200, 'the 7th rider fits after the upgrade');
    ws.close();
    await endRide(t.host.token, t.smallRide.groupId);
  });

  await t.test('concurrent joins never overfill a Small Group ride', async () => {
    const host = await env.register('Busy Host', 'busy.host@coroute.test');
    await giveMembership(host.user, 'group_small', 6);
    const created = await env.api('POST', '/convoys', { name: 'Rush' }, host.token);
    assert.equal(created.status, 201);
    const res = await Promise.all(riders.map((r) => env.api('POST', '/convoys/join', { code: created.json.joinCode }, r.token)));
    const room = await env.gw.convoys.getRoom(created.json.groupId);
    assert.equal(room.riders.size, 6, `riders ${room.riders.size}`);
    assert.equal(res.filter((r) => r.status === 200).length, 5);
    assert.ok(res.filter((r) => r.status !== 200).every((r) => r.status === 409 && r.json.code === 'CONVOY_FULL'));
    await endRide(host.token, created.json.groupId);
    // The ride is over: a planless joiner is back on Community (solo) entitlements.
    const joined = riders.find((r, i) => res[i].status === 200);
    const after = await env.api('GET', '/membership/my', null, joined.token);
    assert.equal(after.json.effectiveEntitlements.ptt, false, 'no host ride, no group features');
  });

  await t.test('Individual: a solo trip of 1; nobody else can join (409 SOLO_TRIP_ONLY)', async () => {
    const solo = await env.register('Solo Host', 'solo.host@coroute.test');
    await giveMembership(solo.user, 'individual', 1);
    const created = await env.api('POST', '/convoys', { name: 'Just me' }, solo.token);
    assert.equal(created.status, 201);
    assert.equal(created.json.capacity, 1);
    const j = await env.api('POST', '/convoys/join', { code: created.json.joinCode }, riders[7].token);
    assert.equal(j.status, 409);
    assert.equal(j.json.code, 'SOLO_TRIP_ONLY');
    const my = await env.api('GET', '/membership/my', null, solo.token);
    assert.deepEqual([my.json.plan.category, my.json.plan.seats, my.json.plan.canHostGroup], ['individual', 1, false]);
    await endRide(solo.token, created.json.groupId);
  });

  await t.test('legacy Road Captain keeps Large Group access until validUntil, shown as its plan', async () => {
    const cap = await env.register('Legacy Captain', 'legacy.captain@coroute.test');
    const until = Date.now() + 10 * DAY;
    const doc = await repo.findUserById(cap.user.userId);
    await repo.updateUser(doc.key, { subscriptionTier: 'roadCaptain', subscriptionValidUntil: until });
    env.gw.gate.invalidate(cap.user.userId);
    const my = await env.api('GET', '/membership/my', null, cap.token);
    assert.equal(my.status, 200);
    assert.deepEqual([my.json.plan.source, my.json.plan.name, my.json.plan.seats, my.json.plan.validUntil, my.json.plan.legacyTier], ['legacy', 'Road Captain', 12, until, 'roadCaptain']);
    assert.equal(my.json.effectiveEntitlements.convoy, true);
    const created = await env.api('POST', '/convoys', { name: 'Captain ride' }, cap.token);
    assert.equal(created.status, 201, JSON.stringify(created.json));
    assert.equal(created.json.capacity, 12);
    await endRide(cap.token, created.json.groupId);
    // After the end date: no grace, the rider is on Community (solo rides only).
    await repo.updateUser(doc.key, { subscriptionValidUntil: Date.now() - 1000 });
    env.gw.gate.invalidate(cap.user.userId);
    const after = await env.api('POST', '/convoys', { name: 'Too late' }, cap.token);
    assert.equal(after.status, 201);
    assert.equal(after.json.capacity, 1);
    await endRide(cap.token, after.json.groupId);
  });

  await t.test('legacy CoRoute Pro hosts up to 6 (it hosted up to 4 bikes before)', async () => {
    const pro = await env.register('Legacy Pro', 'legacy.pro@coroute.test');
    const doc = await repo.findUserById(pro.user.userId);
    await repo.updateUser(doc.key, { subscriptionTier: 'proRider', subscriptionValidUntil: Date.now() + 3 * DAY });
    env.gw.gate.invalidate(pro.user.userId);
    const created = await env.api('POST', '/convoys', { name: 'Pro ride' }, pro.token);
    assert.equal(created.status, 201, JSON.stringify(created.json));
    assert.equal(created.json.capacity, 6);
    await endRide(pro.token, created.json.groupId);
  });

  await t.test('no new legacy purchases: 410 LEGACY_PLAN; status and history still answer old builds', async () => {
    for (const planTier of ['proRider', 'roadCaptain', 'tourOperator']) {
      const o = await env.api('POST', '/subscription/create-order', { planTier, billingCycle: 'monthly' }, riders[6].token);
      assert.equal(o.status, 410, planTier);
      assert.equal(o.json.code, 'LEGACY_PLAN');
    }
    assert.equal((await env.api('GET', '/subscription/status', null, riders[6].token)).status, 200);
    assert.equal((await env.api('GET', '/subscription/history', null, riders[6].token)).status, 200);
  });

  await t.test('coupons: plan options are the paid plans; legacy-only bindings are refused', async () => {
    const opts = await env.api('GET', '/admin/coupons/plan-options', null, admin.token);
    assert.deepEqual(opts.json.plans.map((p) => p.id), ['group_small', 'group_large']);
    const bad = await env.api('POST', '/admin/coupons', { code: 'CAPTAIN10', discountType: 'percentage', discountValue: 10, applicablePlans: ['roadCaptain', 'tourOperator'] }, admin.token);
    assert.equal(bad.status, 400);
    assert.equal(bad.json.reason, 'UNKNOWN_PLAN');
    const mixed = await env.api('POST', '/admin/coupons', { code: 'GROUP10', discountType: 'percentage', discountValue: 10, applicablePlans: ['group_small', 'roadCaptain'] }, admin.token);
    assert.equal(mixed.status, 201);
    assert.deepEqual(mixed.json.coupon.applicableTiers, ['group_small']);
    // The admin cannot add a fourth plan to the catalog.
    const catalog = await repo.getMembershipCatalog();
    assert.deepEqual(Object.keys(catalog), ['community', 'group_small', 'group_large']);
    const extra = await env.api('PUT', '/admin/membership/catalog', { catalog: { ...catalog, roadCaptain: { name: 'Road Captain', monthlyPriceInr: 599, capacity: 40 } } }, admin.token);
    assert.equal(extra.status, 400);
  });

  await t.test('website: "Up to N riders" is the largest plan, not the server ceiling', async () => {
    const res = await fetch(`${env.origin}/get`);
    const html = await res.text();
    assert.ok(html.includes('Up to 12 riders'), 'Large Group seats');
    assert.ok(!html.includes(`Up to ${config.maxConvoyRiders} riders`));
  });
});
