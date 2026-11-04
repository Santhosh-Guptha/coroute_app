'use strict';
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true'; // Enable monetization gating for this test suite
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_unitKey123';
process.env.RAZORPAY_TEST_KEY_SECRET = 'unit_test_secret_456';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_unit_789';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { setRazorpayFetch } = require('../src/razorpay_gateway');
const { boot } = require('./_helpers');

// Fake Razorpay Orders and Refund API
const rzpCalls = [];
setRazorpayFetch(async (url, opts = {}) => {
  const auth = Buffer.from(String(opts.headers?.Authorization || '').replace('Basic ', ''), 'base64').toString();
  rzpCalls.push({ url, method: opts.method, auth, body: opts.body ? JSON.parse(opts.body) : null });
  const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
  if (opts.method === 'POST' && url.endsWith('/orders')) {
    const b = JSON.parse(opts.body);
    return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, receipt: b.receipt, status: 'created' });
  }
  if (opts.method === 'GET' && url.includes('/orders')) return reply(200, { items: [] });
  if (opts.method === 'POST' && url.includes('/refund')) {
    const b = opts.body ? JSON.parse(opts.body) : {};
    return reply(200, { id: `rfnd_${crypto.randomBytes(6).toString('hex')}`, amount: b.amount || 4900, status: 'processed' });
  }
  return reply(404, {});
});

const sign = (secret, orderId, paymentId) =>
  crypto.createHmac('sha256', secret).update(`${orderId}|${paymentId}`).digest('hex');

test('Membership, Monetization, Ownership & Trip Management Suite', async (t) => {
  const env = await boot();
  t.after(() => {
    setRazorpayFetch(null);
    env.gw.shutdown();
  });

  let adminUser, adminToken;
  let ownerUser, ownerToken;
  let headUser, headToken;
  let riderA, riderAToken;
  let riderB, riderBToken;
  let riderC, riderCToken;

  await t.test('setup users: admin, owner, head, riders', async () => {
    const adm = await env.register('Admin', 'admin@coroute.test');
    adminUser = adm.user;
    adminToken = adm.token;

    const own = await env.register('Trip Owner', 'owner@coroute.test');
    ownerUser = own.user;
    ownerToken = own.token;

    const hd = await env.register('Trip Head', 'head@coroute.test');
    headUser = hd.user;
    headToken = hd.token;

    const ra = await env.register('Rider A', 'ra@coroute.test');
    riderA = ra.user;
    riderAToken = ra.token;

    const rb = await env.register('Rider B', 'rb@coroute.test');
    riderB = rb.user;
    riderBToken = rb.token;

    const rc = await env.register('Rider C', 'rc@coroute.test');
    riderC = rc.user;
    riderCToken = rc.token;
  });

  // =========================================================================
  // 1. Catalog & Initial Values
  // =========================================================================

  await t.test('GET /api/membership/catalog returns initial categories: ₹9, ₹49, ₹99 and keyId', async () => {
    const res = await env.api('GET', '/membership/catalog');
    assert.equal(res.status, 200);
    assert.ok(res.json.categories);

    const ind = res.json.categories.individual;
    assert.equal(ind.monthlyPriceInr, 9);
    assert.equal(ind.capacity, 1);
    assert.equal(ind.entitlements.ptt, false);
    assert.equal(ind.entitlements.convoy, false);

    const sm = res.json.categories.group_small;
    assert.equal(sm.monthlyPriceInr, 49);
    assert.equal(sm.capacity, 6);
    assert.equal(sm.entitlements.ptt, true);
    assert.equal(sm.entitlements.convoy, true);

    const lg = res.json.categories.group_large;
    assert.equal(lg.monthlyPriceInr, 99);
    assert.equal(lg.capacity, 12);
    assert.equal(lg.entitlements.ptt, true);
    assert.equal(lg.entitlements.convoy, true);

    assert.equal(res.json.keyId, 'rzp_test_unitKey123');
    assert.equal(res.json.mode, 'test');
  });

  // =========================================================================
  // 2. Membership Purchase & Permanent Ownership
  // =========================================================================

  await t.test('POST /api/membership/purchase requires payment or valid offer', async () => {
    const failRes = await env.api('POST', '/membership/purchase', { category: 'group_small' }, ownerToken);
    assert.equal(failRes.status, 402);
    assert.equal(failRes.json.reason, 'PAYMENT_REQUIRED');
    assert.equal(failRes.json.amountInr, 49);

    const invalidRes = await env.api('POST', '/membership/purchase', { category: 'non_existent_tier' }, ownerToken);
    assert.equal(invalidRes.status, 400);
    assert.equal(invalidRes.json.reason, 'INVALID_CATEGORY');
  });

  await t.test('POST /api/membership/purchase activates with introductory 100% offer RIDERFREE', async () => {
    const res = await env.api('POST', '/membership/purchase', {
      category: 'group_small',
      offerCode: 'RIDERFREE',
    }, ownerToken);

    assert.equal(res.status, 201);
    assert.equal(res.json.membership.ownerUserId, ownerUser.userId);
    assert.equal(res.json.membership.category, 'group_small');
    assert.equal(res.json.membership.capacity, 6);
    assert.equal(res.json.membership.status, 'ACTIVE');
    assert.equal(res.json.membership.offerApplied, 'RIDERFREE');
  });

  await t.test('GET /api/membership/my reflects owned membership and group entitlements', async () => {
    const res = await env.api('GET', '/membership/my', null, ownerToken);
    assert.equal(res.status, 200);
    assert.ok(res.json.owned);
    assert.equal(res.json.owned.category, 'group_small');
    assert.equal(res.json.effectiveEntitlements.ptt, true);
    assert.equal(res.json.effectiveEntitlements.convoy, true);
    assert.equal(res.json.effectiveEntitlements.sharedTrip, true);
  });

  // =========================================================================
  // 3. Member Invitations & Seat Capacity
  // =========================================================================

  await t.test('POST /api/membership/members/invite: owner invites group participants', async () => {
    const invResA = await env.api('POST', '/membership/members/invite', { email: 'ra@coroute.test' }, ownerToken);
    assert.equal(invResA.status, 200);
    assert.equal(invResA.json.ok, true);
    assert.equal(invResA.json.remainingSeats, 4); // 6 total - (1 owner + 1 invited) = 4

    const invResHead = await env.api('POST', '/membership/members/invite', { email: 'head@coroute.test' }, ownerToken);
    assert.equal(invResHead.status, 200);
    assert.equal(invResHead.json.remainingSeats, 3);

    const failSelf = await env.api('POST', '/membership/members/invite', { email: 'owner@coroute.test' }, ownerToken);
    assert.equal(failSelf.status, 400);
    assert.equal(failSelf.json.reason, 'OWNER_CANNOT_INVITE_SELF');

    const failDuplicate = await env.api('POST', '/membership/members/invite', { email: 'ra@coroute.test' }, ownerToken);
    assert.equal(failDuplicate.status, 409);
    assert.equal(failDuplicate.json.reason, 'ALREADY_MEMBER');
  });

  await t.test('Group seat capacity enforcement: cannot exceed purchased capacity of 6', async () => {
    const r3 = await env.register('Rider 3', 'r3@coroute.test');
    const r4 = await env.register('Rider 4', 'r4@coroute.test');
    const r5 = await env.register('Rider 5', 'r5@coroute.test');
    const r6 = await env.register('Rider 6', 'r6@coroute.test');

    const i3 = await env.api('POST', '/membership/members/invite', { email: 'r3@coroute.test' }, ownerToken);
    assert.equal(i3.status, 200); // 1 owner + 3 = 4
    const i4 = await env.api('POST', '/membership/members/invite', { email: 'r4@coroute.test' }, ownerToken);
    assert.equal(i4.status, 200); // 1 owner + 4 = 5
    const i5 = await env.api('POST', '/membership/members/invite', { email: 'r5@coroute.test' }, ownerToken);
    assert.equal(i5.status, 200); // 1 owner + 5 = 6 (Full)

    const i6 = await env.api('POST', '/membership/members/invite', { email: 'r6@coroute.test' }, ownerToken);
    assert.equal(i6.status, 409);
    assert.equal(i6.json.reason, 'MEMBERSHIP_CAPACITY_EXCEEDED');

    await env.api('DELETE', `/membership/members/${r3.user.userId}`, null, ownerToken);
    await env.api('DELETE', `/membership/members/${r4.user.userId}`, null, ownerToken);
    await env.api('DELETE', `/membership/members/${r5.user.userId}`, null, ownerToken);
  });

  await t.test('POST /api/membership/members/respond: invited rider accepts invitation', async () => {
    const ownerMem = await env.gw.repo.findMembershipByOwner(ownerUser.userId);
    const respondRes = await env.api('POST', '/membership/members/respond', {
      membershipId: ownerMem.membershipId,
      action: 'ACCEPT',
    }, riderAToken);

    assert.equal(respondRes.status, 200);
    assert.equal(respondRes.json.accepted, true);

    await env.api('POST', '/membership/members/respond', {
      membershipId: ownerMem.membershipId,
      action: 'ACCEPT',
    }, headToken);

    const memAfter = await env.gw.repo.findMembershipById(ownerMem.membershipId);
    assert.equal(memAfter.members[riderA.userId].status, 'ACCEPTED');
    assert.equal(memAfter.members[headUser.userId].status, 'ACCEPTED');

    const riderAMy = await env.api('GET', '/membership/my', null, riderAToken);
    assert.equal(riderAMy.status, 200);
    assert.equal(riderAMy.json.effectiveEntitlements.convoy, true);
    assert.equal(riderAMy.json.effectiveEntitlements.ptt, true);
  });

  // =========================================================================
  // 4. Trip Creation, Two-Role Governance & Single Active Trip Concurrency
  // =========================================================================

  let activeGroupId = '';

  await t.test('Owner creates convoy: assigned Trip Owner & Trip Head; active trip locked', async () => {
    const createRes = await env.api('POST', '/convoys', {
      name: 'Himalayan Ridge Expedition',
      startPoint: 'Manali Mall Road',
      destination: 'Leh Main Bazaar',
    }, ownerToken);

    assert.equal(createRes.status, 201);
    activeGroupId = createRes.json.groupId;
    assert.ok(activeGroupId);

    const room = await env.gw.convoys.getRoom(activeGroupId);
    assert.equal(room.meta.tripOwnerUserId, ownerUser.userId);
    assert.equal(room.meta.tripHeadUserId, ownerUser.userId);

    const lock = await env.gw.repo.getActiveTrip(ownerUser.userId);
    assert.ok(lock);
    assert.equal(lock.groupId, activeGroupId);
    assert.equal(lock.role, 'OWNER');
  });

  await t.test('Single Active Trip Concurrency Lock: Owner cannot create second trip simultaneously', async () => {
    const failCreate = await env.api('POST', '/convoys', {
      name: 'Second Conflicting Trip',
    }, ownerToken);

    assert.equal(failCreate.status, 409);
    assert.equal(failCreate.json.reason, 'ACTIVE_TRIP_CONFLICT');
  });

  await t.test('Invited members join active trip; active trip locked for participants', async () => {
    const room = await env.gw.convoys.getRoom(activeGroupId);
    const joinCode = room.meta.joinCode;

    const joinA = await env.api('POST', '/convoys/join', { code: joinCode }, riderAToken);
    assert.equal(joinA.status, 200);

    const joinHead = await env.api('POST', '/convoys/join', { code: joinCode }, headToken);
    assert.equal(joinHead.status, 200);

    const lockA = await env.gw.repo.getActiveTrip(riderA.userId);
    assert.ok(lockA);
    assert.equal(lockA.groupId, activeGroupId);
    assert.equal(lockA.role, 'PARTICIPANT');
  });

  await t.test('Single Active Trip Concurrency Lock: Participant cannot join another trip simultaneously', async () => {
    const room = await env.gw.convoys.getRoom(activeGroupId);
    const failJoin = await env.api('POST', '/convoys/join', { code: room.meta.joinCode }, riderAToken);
    assert.equal(failJoin.status, 200); // re-joining the same trip returns snapshot
  });

  await t.test('Two-Role Model: Trip Owner assigns Trip Head; Trip Head is operational leader', async () => {
    const assignRes = await env.api('POST', `/convoys/${activeGroupId}/trip-head`, {
      targetUserId: headUser.userId,
    }, ownerToken);

    assert.equal(assignRes.status, 200);
    assert.equal(assignRes.json.tripHeadUserId, headUser.userId);

    const room = await env.gw.convoys.getRoom(activeGroupId);
    assert.equal(room.meta.tripHeadUserId, headUser.userId);
    assert.equal(room.riders.get(headUser.userId).role, 'LEAD');
  });

  await t.test('Two-Role Model: Trip Head CANNOT remove participants; Trip Owner CAN', async () => {
    const failRemove = await env.api('DELETE', `/convoys/${activeGroupId}/riders/${riderA.userId}`, null, headToken);
    assert.equal(failRemove.status, 403);
    assert.equal(failRemove.json.reason, 'OWNER_ONLY');

    const roomBefore = await env.gw.convoys.getRoom(activeGroupId);
    assert.ok(roomBefore.riders.has(riderA.userId));

    const successRemove = await env.api('DELETE', `/convoys/${activeGroupId}/riders/${riderA.userId}`, null, ownerToken);
    assert.equal(successRemove.status, 200);

    const roomAfter = await env.gw.convoys.getRoom(activeGroupId);
    assert.ok(!roomAfter.riders.has(riderA.userId));

    const lockA = await env.gw.repo.getActiveTrip(riderA.userId);
    assert.equal(lockA, null);
  });

  await t.test('Two-Role Model: Trip Head CANNOT end trip; Trip Owner CAN', async () => {
    // Trip Head attempts to send status: 'ENDED' -> MUST FAIL with 403 ONLY_OWNER_CAN_END_TRIP
    const failEnd = await env.api('POST', `/convoys/${activeGroupId}/status`, { status: 'ENDED' }, headToken);
    assert.equal(failEnd.status, 403);
    assert.equal(failEnd.json.reason, 'ONLY_OWNER_CAN_END_TRIP');

    // Room is still active
    const room = await env.gw.convoys.getRoom(activeGroupId);
    assert.equal(room.meta.tripStatus, 'STARTED');
  });

  await t.test('Two-Role Model: Trip Owner cannot remove themselves (must end trip)', async () => {
    const failSelf = await env.api('DELETE', `/convoys/${activeGroupId}/riders/${ownerUser.userId}`, null, ownerToken);
    assert.equal(failSelf.status, 400);
    assert.equal(failSelf.json.reason, 'CANNOT_REMOVE_OWNER');
  });

  // =========================================================================
  // 5. Safety-First Mid-Trip Expiry Continuity
  // =========================================================================

  await t.test('Mid-trip expiry: active trip continues uninterrupted, but new trip is blocked after end', async () => {
    const ownerMem = await env.gw.repo.findMembershipByOwner(ownerUser.userId);
    ownerMem.validUntil = Date.now() - 1000; // Expired 1 second ago
    await env.gw.repo.saveMembership(ownerMem);

    const room = await env.gw.convoys.getRoom(activeGroupId);
    assert.equal(room.meta.tripStatus, 'STARTED');
    assert.ok(room.riders.has(ownerUser.userId));
    assert.ok(room.riders.has(headUser.userId));

    const statusRes = await env.api('POST', `/convoys/${activeGroupId}/status`, { status: 'PAUSED' }, headToken);
    assert.equal(statusRes.status, 200);

    // Trip Owner ends the trip
    const endRes = await env.api('POST', `/convoys/${activeGroupId}/status`, { status: 'ENDED' }, ownerToken);
    assert.equal(endRes.status, 200);

    const lockOwner = await env.gw.repo.getActiveTrip(ownerUser.userId);
    assert.equal(lockOwner, null);
    const lockHead = await env.gw.repo.getActiveTrip(headUser.userId);
    assert.equal(lockHead, null);

    const newTripRes = await env.api('POST', '/convoys', { name: 'Expired Owner Trip' }, ownerToken);
    assert.equal(newTripRes.status, 402);
    assert.equal(newTripRes.json.reason, 'MEMBERSHIP_EXPIRED');
  });

  // =========================================================================
  // 6. Secure Razorpay Order Creation & Verification Lifecycle
  // =========================================================================

  let testOrderId = '';
  const testPaymentId = `pay_${crypto.randomBytes(6).toString('hex')}`;

  await t.test('POST /api/membership/order creates paid Razorpay order with ledger entry', async () => {
    const orderRes = await env.api('POST', '/membership/order', {
      category: 'group_large',
    }, ownerToken);

    assert.equal(orderRes.status, 201);
    assert.ok(orderRes.json.orderId);
    assert.equal(orderRes.json.amountInPaise, 9900); // ₹99
    assert.equal(orderRes.json.amountInr, 99);
    assert.equal(orderRes.json.keyId, 'rzp_test_unitKey123');
    assert.equal(orderRes.json.isFree, false);
    testOrderId = orderRes.json.orderId;

    // Verify order in DB
    const dbOrder = await env.gw.repo.findRazorpayOrder(testOrderId);
    assert.ok(dbOrder);
    assert.equal(dbOrder.status, 'CREATED');
    assert.equal(dbOrder.amountInPaise, 9900);
  });

  await t.test('POST /api/membership/verify rejects invalid HMAC signature', async () => {
    const badVerify = await env.api('POST', '/membership/verify', {
      orderId: testOrderId,
      paymentId: testPaymentId,
      signature: 'invalid_tampered_signature_hex',
    }, ownerToken);

    assert.equal(badVerify.status, 400);
    assert.equal(badVerify.json.reason, 'INVALID_PAYMENT_SIGNATURE');

    const dbOrder = await env.gw.repo.findRazorpayOrder(testOrderId);
    assert.equal(dbOrder.status, 'FAILED');
  });

  await t.test('POST /api/membership/verify succeeds with valid cryptographic HMAC signature', async () => {
    const validSignature = sign(process.env.RAZORPAY_TEST_KEY_SECRET, testOrderId, testPaymentId);
    const verifyRes = await env.api('POST', '/membership/verify', {
      orderId: testOrderId,
      paymentId: testPaymentId,
      signature: validSignature,
    }, ownerToken);

    assert.equal(verifyRes.status, 200);
    assert.equal(verifyRes.json.success, true);
    assert.equal(verifyRes.json.membership.category, 'group_large');
    assert.equal(verifyRes.json.membership.status, 'ACTIVE');
    assert.equal(verifyRes.json.membership.capacity, 12);

    const dbOrder = await env.gw.repo.findRazorpayOrder(testOrderId);
    assert.equal(dbOrder.status, 'PAID');
    assert.equal(dbOrder.paymentId, testPaymentId);
  });

  await t.test('POST /api/membership/verify is idempotent on repeated calls', async () => {
    const validSignature = sign(process.env.RAZORPAY_TEST_KEY_SECRET, testOrderId, testPaymentId);
    const retryRes = await env.api('POST', '/membership/verify', {
      orderId: testOrderId,
      paymentId: testPaymentId,
      signature: validSignature,
    }, ownerToken);

    assert.equal(retryRes.status, 200);
    assert.equal(retryRes.json.success, true);
    assert.equal(retryRes.json.membership.category, 'group_large');
  });

  await t.test('POST /api/membership/verify detects and blocks payment replay attacks', async () => {
    // Create a new distinct order
    const order2 = await env.api('POST', '/membership/order', {
      category: 'individual',
    }, riderBToken);
    assert.equal(order2.status, 201);
    const orderId2 = order2.json.orderId;

    // Attacker tries to reuse the already credited testPaymentId
    const replayRes = await env.api('POST', '/membership/verify', {
      orderId: orderId2,
      paymentId: testPaymentId, // Replayed payment ID!
      signature: sign(process.env.RAZORPAY_TEST_KEY_SECRET, orderId2, testPaymentId),
    }, riderBToken);

    assert.equal(replayRes.status, 409);
    assert.equal(replayRes.json.reason, 'REPLAY_ATTACK_DETECTED');
  });

  await t.test('GET /api/membership/payments returns rider payment ledger history', async () => {
    const historyRes = await env.api('GET', '/membership/payments', null, ownerToken);
    assert.equal(historyRes.status, 200);
    assert.ok(Array.isArray(historyRes.json.payments));
    const paid = historyRes.json.payments.find((p) => p.orderId === testOrderId);
    assert.ok(paid);
    assert.equal(paid.amountInr, 99);
    assert.equal(paid.status, 'PAID');
  });

  // =========================================================================
  // 7. Webhook Handling
  // =========================================================================

  await t.test('POST /api/membership/webhook rejects bad signature and processes valid event', async () => {
    // Bad signature
    const badRes = await env.api('POST', '/membership/webhook', { event: 'payment.captured' }, null, {
      'x-razorpay-signature': 'bad_sig',
    });
    assert.equal(badRes.status, 400);

    // Create another order for webhook test
    const r3 = await env.register('Rider Webhook', 'rwebhook@test.com');
    const ord = await env.api('POST', '/membership/order', { category: 'individual' }, r3.token);
    assert.equal(ord.status, 201);
    const targetOrderId = ord.json.orderId;
    const webhookPaymentId = `pay_hook_${Date.now()}`;

    const webhookBody = JSON.stringify({
      event: 'payment.captured',
      payload: {
        payment: {
          entity: {
            id: webhookPaymentId,
            order_id: targetOrderId,
            amount: 900,
            method: 'upi',
          },
        },
      },
    });

    const hookSig = crypto.createHmac('sha256', process.env.RAZORPAY_TEST_WEBHOOK_SECRET)
      .update(webhookBody)
      .digest('hex');

    const hookRes = await env.api('POST', '/membership/webhook', webhookBody, null, {
      'content-type': 'application/json',
      'x-razorpay-signature': hookSig,
      'x-razorpay-event-id': `evt_${Date.now()}`,
    });

    assert.equal(hookRes.status, 200);
    assert.equal(hookRes.json.status, 'ok');

    // Verify membership was activated for r3
    const r3Mem = await env.gw.repo.findMembershipByOwner(r3.user.userId);
    assert.ok(r3Mem);
    assert.equal(r3Mem.status, 'ACTIVE');
    assert.equal(r3Mem.category, 'individual');
  });

  // =========================================================================
  // 8. Platform Admin Membership Catalog, Analytics, Ledger & Refund
  // =========================================================================

  await t.test('Platform Admin updates membership catalog dynamically', async () => {
    const catalog = await env.gw.repo.getMembershipCatalog();
    catalog.individual.monthlyPriceInr = 12;

    const updateRes = await env.api('PUT', '/admin/membership/catalog', { catalog }, adminToken);
    assert.equal(updateRes.status, 200);

    const checkRes = await env.api('GET', '/membership/catalog');
    assert.equal(checkRes.json.categories.individual.monthlyPriceInr, 12);
  });

  await t.test('Platform Admin lists all memberships and payment transactions', async () => {
    const memList = await env.api('GET', '/admin/membership/memberships', null, adminToken);
    assert.equal(memList.status, 200);
    assert.ok(Array.isArray(memList.json.memberships));
    assert.ok(memList.json.total >= 1);

    const payList = await env.api('GET', '/admin/membership/payments', null, adminToken);
    assert.equal(payList.status, 200);
    assert.ok(Array.isArray(payList.json.payments));
    assert.ok(payList.json.total >= 1);
  });

  await t.test('Platform Admin executes Razorpay refund and updates ledger', async () => {
    const refundRes = await env.api('POST', `/admin/membership/payments/${testOrderId}/refund`, {
      reason: 'Customer requested refund within 24h',
    }, adminToken);

    assert.equal(refundRes.status, 200);
    assert.equal(refundRes.json.ok, true);
    assert.equal(refundRes.json.fullyRefunded, true);

    const updatedOrder = await env.gw.repo.findRazorpayOrder(testOrderId);
    assert.equal(updatedOrder.refundStatus, 'PROCESSED');
    assert.equal(updatedOrder.fullyRefunded, true);

    // Active membership revoked upon full refund
    const activeMem = await env.gw.repo.findMembershipByOwner(ownerUser.userId);
    assert.equal(activeMem, null);
  });

  await t.test('Platform Admin views privacy-safe aggregate analytics (zero raw GPS)', async () => {
    const res = await env.api('GET', '/admin/membership/analytics', null, adminToken);
    assert.equal(res.status, 200);
    assert.ok(res.json.activeMemberships);
    assert.ok(res.json.seatUtilization);
    assert.ok(res.json.financialMetrics);
    assert.ok(res.json.concurrency);

    const jsonStr = JSON.stringify(res.json);
    assert.ok(!jsonStr.includes('lat'));
    assert.ok(!jsonStr.includes('lng'));
    assert.ok(!jsonStr.includes('routeBreadcrumbs'));
  });
});
