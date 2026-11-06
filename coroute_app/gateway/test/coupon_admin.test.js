'use strict';
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_coupon123';
process.env.RAZORPAY_TEST_KEY_SECRET = 'unit_coupon_secret_456';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_coupon_789';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { setRazorpayFetch } = require('../src/razorpay_gateway');
const { boot } = require('./_helpers');

// Fake Razorpay Orders and Refund API
setRazorpayFetch(async (url, opts = {}) => {
  const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
  if (opts.method === 'POST' && url.endsWith('/orders')) {
    const b = JSON.parse(opts.body);
    return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, receipt: b.receipt, status: 'created' });
  }
  if (opts.method === 'POST' && url.includes('/refund')) {
    const b = opts.body ? JSON.parse(opts.body) : {};
    return reply(200, { id: `rfnd_${crypto.randomBytes(6).toString('hex')}`, amount: b.amount || 4900, status: 'processed' });
  }
  return reply(404, {});
});

const sign = (secret, orderId, paymentId) =>
  crypto.createHmac('sha256', secret).update(`${orderId}|${paymentId}`).digest('hex');

test('Admin Console Coupon Management, Redemption Tracking & Payment Analytics Suite', async (t) => {
  const env = await boot();
  t.after(() => {
    setRazorpayFetch(null);
    env.gw.shutdown();
  });

  let adminUser, adminToken;
  let riderUser, riderToken;
  let secondRider, secondToken;

  await t.test('setup admin and test riders', async () => {
    const adm = await env.register('Admin User', 'admin@coroute.test');
    adminUser = adm.user;
    adminToken = adm.token;

    const rdr = await env.register('Rider One', 'rider1@coroute.test');
    riderUser = rdr.user;
    riderToken = rdr.token;

    const rdr2 = await env.register('Rider Two', 'rider2@coroute.test');
    secondRider = rdr2.user;
    secondToken = rdr2.token;
  });

  await t.test('POST /api/admin/coupons creates coupon with full configuration', async () => {
    const payload = {
      code: 'DIWALI50',
      name: 'Diwali Rider Fest 50% Off',
      campaignName: 'Diwali 2026',
      description: 'Get 50% discount up to ₹30 on small and large group memberships.',
      internalNotes: 'Approved by marketing for festival blitz.',
      status: 'ACTIVE',
      discountType: 'percentage',
      discountValue: 50,
      maxDiscountCap: 30,
      minOrderAmount: 20,
      maxUsageTotal: 2,
      maxUsagePerUser: 1,
      applicableTiers: ['group_small', 'group_large'],
      timezone: 'Asia/Kolkata',
      validFrom: Date.now() - 3600000,
      expiresAt: Date.now() + 7 * 86400000,
    };

    const res = await env.api('POST', '/admin/coupons', payload, adminToken);
    assert.equal(res.status, 201);
    assert.equal(res.json.success, true);
    assert.equal(res.json.coupon.code, 'DIWALI50');
    assert.equal(res.json.coupon.status, 'ACTIVE');
    assert.equal(res.json.coupon.maxDiscountCap, 30);
  });

  await t.test('POST /api/admin/coupons/:code/pause and resume', async () => {
    const pauseRes = await env.api('POST', '/admin/coupons/DIWALI50/pause', {}, adminToken);
    assert.equal(pauseRes.status, 200);
    assert.equal(pauseRes.json.coupon.status, 'PAUSED');

    // Attempting to order with paused coupon fails
    const orderFail = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: 'DIWALI50' }, riderToken);
    assert.equal(orderFail.status, 400);
    assert.equal(orderFail.json.reason, 'COUPON_PAUSED');

    // Resume coupon
    const resumeRes = await env.api('POST', '/admin/coupons/DIWALI50/resume', {}, adminToken);
    assert.equal(resumeRes.status, 200);
    assert.equal(resumeRes.json.coupon.status, 'ACTIVE');
  });

  await t.test('Coupon tier restriction enforcement', async () => {
    // The retired Individual plan cannot be ordered at all (Community is free), coupon or not.
    const orderWrongTier = await env.api('POST', '/membership/order', { category: 'individual', offerCode: 'DIWALI50' }, riderToken);
    assert.equal(orderWrongTier.status, 410);
    assert.equal(orderWrongTier.json.reason, 'LEGACY_PLAN');
    const community = await env.api('POST', '/membership/order', { category: 'community', offerCode: 'DIWALI50' }, riderToken);
    assert.equal(community.status, 400);
    assert.equal(community.json.reason, 'FREE_PLAN');
  });

  await t.test('Order creation reserves coupon slot & caps discount', async () => {
    // Group small ₹49 with 50% = ₹24.50 capped at maxDiscountCap ₹30 -> final ₹24.50 (rounded to ₹24 or ₹25)
    const orderRes = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: 'DIWALI50' }, riderToken);
    assert.equal(orderRes.status, 201);
    assert.ok(orderRes.json.orderId);
    assert.equal(orderRes.json.amountInr, 24); // 49 - 25 = 24

    // Verify payment with HMAC signature
    const payId = `pay_${crypto.randomBytes(6).toString('hex')}`;
    const sig = sign('unit_coupon_secret_456', orderRes.json.orderId, payId);
    const verifyRes = await env.api('POST', '/membership/verify', {
      orderId: orderRes.json.orderId,
      paymentId: payId,
      signature: sig,
    }, riderToken);
    assert.equal(verifyRes.status, 200);
    assert.equal(verifyRes.json.success, true);
  });

  await t.test('Enforces per-rider usage limit', async () => {
    // Rider 1 attempts to use DIWALI50 a second time
    const repeatOrder = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: 'DIWALI50' }, riderToken);
    assert.equal(repeatOrder.status, 400);
    assert.ok(['PER_USER_LIMIT_REACHED', 'COUPON_RESERVATION_FAILED'].includes(repeatOrder.json.reason), JSON.stringify(repeatOrder.json));
  });

  await t.test('Total usage limit enforcement', async () => {
    // Rider 2 uses 2nd slot (maxUsageTotal = 2)
    const order2 = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: 'DIWALI50' }, secondToken);
    assert.equal(order2.status, 201);
    const payId2 = `pay_${crypto.randomBytes(6).toString('hex')}`;
    const sig2 = sign('unit_coupon_secret_456', order2.json.orderId, payId2);
    await env.api('POST', '/membership/verify', { orderId: order2.json.orderId, paymentId: payId2, signature: sig2 }, secondToken);

    // 3rd user attempts: total usage limit reached
    const thirdUser = (await env.register('Rider Three', 'rider3@coroute.test')).token;
    const order3 = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: 'DIWALI50' }, thirdUser);
    assert.equal(order3.status, 400);
    assert.ok(order3.json.error.includes('limit') || order3.json.reason === 'COUPON_LIMIT_REACHED');
  });

  await t.test('GET /api/admin/coupons/usage returns detailed tracking & summary', async () => {
    const res = await env.api('GET', '/admin/coupons/usage', null, adminToken);
    assert.equal(res.status, 200);
    assert.ok(res.json.summary);
    assert.ok(res.json.summary.totalRedemptions >= 2);
    assert.ok(res.json.summary.totalDiscountGivenInr > 0);
    assert.ok(res.json.summary.revenueGeneratedInr > 0);
    assert.ok(Array.isArray(res.json.redemptions));
    assert.ok(res.json.redemptions.length >= 2);

    const firstRedemption = res.json.redemptions[0];
    assert.ok(firstRedemption.redemptionId);
    assert.ok(firstRedemption.couponCode);
    assert.ok(firstRedemption.orderId);
    assert.equal(firstRedemption.status, 'SUCCESS');
  });

  await t.test('GET /api/admin/payments/analytics returns KPIs, plan breakdown, coupon ROI & timeline', async () => {
    const res = await env.api('GET', '/admin/payments/analytics?range=30d', null, adminToken);
    assert.equal(res.status, 200);
    assert.ok(res.json.summary);
    assert.ok(res.json.summary.grossSalesInr > 0);
    assert.ok(res.json.summary.discountsInr > 0);
    assert.ok(res.json.summary.netRevenueInr > 0);
    assert.ok(res.json.summary.paidOrders >= 2);

    // Plan breakdown
    assert.ok(res.json.byPlan.individual);
    assert.ok(res.json.byPlan.group_small);
    assert.ok(res.json.byPlan.group_large);
    assert.ok(res.json.byPlan.group_small.units >= 2);

    // Coupon ROI
    assert.ok(res.json.couponAnalytics);
    assert.ok(res.json.couponAnalytics.totalRedemptions >= 2);
    assert.ok(res.json.couponAnalytics.topCoupons.length > 0);
    assert.equal(res.json.couponAnalytics.topCoupons[0].code, 'DIWALI50');

    // Daily Timeline
    assert.ok(Array.isArray(res.json.timeline));
    assert.ok(res.json.timeline.length > 0);
  });

  await t.test('GET /api/admin/payments/history returns searchable ledger without credentials', async () => {
    const res = await env.api('GET', '/admin/payments/history?status=PAID', null, adminToken);
    assert.equal(res.status, 200);
    assert.ok(Array.isArray(res.json.transactions));
    assert.ok(res.json.transactions.length >= 2);

    const tx = res.json.transactions[0];
    assert.ok(tx.orderId);
    assert.ok(tx.paymentId);
    assert.ok(tx.amountInr);
    assert.equal(tx.status, 'PAID');

    // Security invariant: NO credentials, secrets or keys
    const jsonStr = JSON.stringify(res.json);
    assert.ok(!jsonStr.includes('unit_coupon_secret_456'));
    assert.ok(!jsonStr.includes('whsec_coupon_789'));
    assert.ok(!jsonStr.includes('private_key'));
    assert.ok(!jsonStr.includes('cvv'));
  });

  await t.test('DELETE /api/admin/coupons/:code archives coupon', async () => {
    const delRes = await env.api('DELETE', '/admin/coupons/DIWALI50', null, adminToken);
    assert.equal(delRes.status, 200);

    const couponAfter = await env.gw.repo.findCoupon('DIWALI50');
    assert.equal(couponAfter.status, 'ARCHIVED');
    assert.equal(couponAfter.isActive, false);
  });
});
