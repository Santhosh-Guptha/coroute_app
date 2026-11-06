'use strict';
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_sec123';
process.env.RAZORPAY_TEST_KEY_SECRET = 'unit_sec_secret_456';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_sec_789';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { setRazorpayFetch } = require('../src/razorpay_gateway');
const { boot } = require('./_helpers');

setRazorpayFetch(async (url, opts = {}) => {
  const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
  if (opts.method === 'POST' && url.endsWith('/orders')) {
    const b = JSON.parse(opts.body);
    return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, receipt: b.receipt, status: 'created' });
  }
  return reply(404, {});
});

const sign = (secret, orderId, paymentId) =>
  crypto.createHmac('sha256', secret).update(`${orderId}|${paymentId}`).digest('hex');

test('CoRoute Payment Security, Zero-Amount Activation & Idempotency Suite', async (t) => {
  const env = await boot();
  t.after(() => {
    try { env.gw.server.close(); } catch (_) {}
  });

  let adminToken, riderToken, riderUser;

  await t.test('1. Setup admin and rider', async () => {
    const adminReg = await env.register('Security Admin', 'admin@coroute.test');
    adminToken = adminReg.token;

    const riderReg = await env.register('Vikram Rider', 'vikram.rider@coroute.test');
    riderToken = riderReg.token;
    riderUser = riderReg.user;
    assert.ok(adminToken);
    assert.ok(riderToken);
  });

  await t.test('2. Dynamic coupon validation endpoint POST /api/membership/validate-coupon', async () => {
    // Create test coupon via admin
    const cRes = await env.api('POST', '/admin/coupons', {
      code: 'HALFOFF',
      name: '50% Discount',
      discountType: 'percentage',
      discountValue: 50,
      applicableTiers: ['group_small'],
      maxUsageTotal: 10,
    }, adminToken);
    assert.equal(cRes.status, 201);

    // Validate RIDERFREE (default 100% free)
    const vFree = await env.api('POST', '/membership/validate-coupon', {
      code: 'RIDERFREE',
      category: 'group_small',
    }, riderToken);
    assert.equal(vFree.status, 200);
    assert.equal(vFree.json.valid, true);
    assert.equal(vFree.json.isFree, true);
    assert.equal(vFree.json.finalAmount, 0);

    // Validate HALFOFF on group_small (₹49 -> ₹25 discount, ₹24 final)
    const vHalf = await env.api('POST', '/membership/validate-coupon', {
      code: 'HALFOFF',
      category: 'group_small',
    }, riderToken);
    assert.equal(vHalf.status, 200);
    assert.equal(vHalf.json.valid, true);
    assert.equal(vHalf.json.discountAmount, 25);
    assert.equal(vHalf.json.finalAmount, 24);
    assert.equal(vHalf.json.isFree, false);

    // Validate HALFOFF on group_large (tier mismatch)
    const vMismatch = await env.api('POST', '/membership/validate-coupon', {
      code: 'HALFOFF',
      category: 'group_large',
    }, riderToken);
    assert.equal(vMismatch.status, 400);
    assert.equal(vMismatch.json.valid, false);
    assert.equal(vMismatch.json.reason, 'TIER_MISMATCH');

    // The retired Individual plan is not sold any more (Community is free).
    const vLegacy = await env.api('POST', '/membership/validate-coupon', { code: 'HALFOFF', category: 'individual' }, riderToken);
    assert.equal(vLegacy.status, 410);
    assert.equal(vLegacy.json.reason, 'LEGACY_PLAN');
  });

  await t.test('3. Zero-amount membership activation POST /api/membership/activate-free', async () => {
    const actRes = await env.api('POST', '/membership/activate-free', {
      category: 'group_small',
      couponCode: 'RIDERFREE',
    }, riderToken);

    assert.equal(actRes.status, 201);
    assert.equal(actRes.json.success, true);
    assert.equal(actRes.json.membership.category, 'group_small');
    assert.equal(actRes.json.membership.status, 'ACTIVE');

    // Verify GET /api/membership/my
    const myRes = await env.api('GET', '/membership/my', null, riderToken);
    assert.equal(myRes.status, 200);
    assert.equal(myRes.json.owned.category, 'group_small');
    assert.equal(myRes.json.owned.status, 'ACTIVE');
  });

  await t.test('4. Idempotency: repeated ₹0 activation does NOT stack validUntil or duplicate records', async () => {
    const before = await env.api('GET', '/membership/my', null, riderToken);
    const validUntilBefore = before.json.owned.validUntil;

    // Call activate-free again for identical category
    const actAgain = await env.api('POST', '/membership/activate-free', {
      category: 'group_small',
      couponCode: 'RIDERFREE',
    }, riderToken);

    assert.equal(actAgain.status, 200);
    assert.equal(actAgain.json.isAlreadyActive, true);
    assert.equal(actAgain.json.membership.validUntil, validUntilBefore, 'validUntil must not be extended repeatedly for free');

    // User payment history should not have duplicated entries
    const paymentsRes = await env.api('GET', '/membership/payments', null, riderToken);
    assert.equal(paymentsRes.status, 200);
    assert.equal(paymentsRes.json.payments.length, 1, 'Only 1 record should exist in payment history');
  });

  await t.test('5. RIDERFREE is once per rider; a legitimate upgrade (another free coupon) updates tier and records upgradeHistory', async () => {
    // Changed with the coupon hardening: RIDERFREE used to be a hard-coded shortcut that the same
    // rider could redeem again and again, for any plan. It is now a seeded coupon record with a
    // per-rider limit of 1, so this rider's second redemption (here for an upgrade) is refused.
    const reuse = await env.api('POST', '/membership/activate-free', {
      category: 'group_large',
      couponCode: 'RIDERFREE',
    }, riderToken);
    assert.equal(reuse.status, 400);
    assert.equal(reuse.json.reason, 'PER_USER_LIMIT_REACHED');

    // The upgrade itself is still exercised, paid for by an admin-made 100% coupon bound to group_large.
    const cRes = await env.api('POST', '/admin/coupons', {
      code: 'GROUPFREE',
      discountType: 'free',
      applicablePlans: ['group_large'],
      maxUsageTotal: 5,
      maxUsagePerUser: 1,
    }, adminToken);
    assert.equal(cRes.status, 201);

    // Upgrade from group_small (6) to group_large (12)
    const upgRes = await env.api('POST', '/membership/activate-free', {
      category: 'group_large',
      couponCode: 'GROUPFREE',
    }, riderToken);

    assert.equal(upgRes.status, 201);
    assert.equal(upgRes.json.membership.category, 'group_large');
    assert.equal(upgRes.json.membership.capacity, 12);
    assert.ok(Array.isArray(upgRes.json.membership.upgradeHistory));
    assert.equal(upgRes.json.membership.upgradeHistory.length, 1);
    assert.equal(upgRes.json.membership.upgradeHistory[0].fromCategory, 'group_small');
    assert.equal(upgRes.json.membership.upgradeHistory[0].toCategory, 'group_large');
  });

  await t.test('6. Removal of sandbox activation loophole from POST /api/membership/purchase', async () => {
    // Attempt fake sandbox activation with unverified paymentId and NO signature
    const fakeSandbox = await env.api('POST', '/membership/purchase', {
      category: 'group_large',
      orderId: 'fake_order_123',
      paymentId: 'pay_test_sandbox_spoof',
      // NO SIGNATURE
    }, riderToken);

    // Must be rejected with 400 PAYMENT_SIGNATURE_REQUIRED
    assert.equal(fakeSandbox.status, 400);
    assert.equal(fakeSandbox.json.reason, 'PAYMENT_SIGNATURE_REQUIRED');
  });

  await t.test('7. Admin reconciliation endpoint POST /api/admin/membership/reconcile', async () => {
    const recRes = await env.api('POST', '/admin/membership/reconcile', {}, adminToken);
    assert.equal(recRes.status, 200);
    assert.equal(recRes.json.success, true);
  });
});
