'use strict';
process.env.NODE_ENV = 'test';
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

// Fake Razorpay Orders API: records calls, answers like the real one.
const rzpCalls = [];
let rzpAuthFails = false;
setRazorpayFetch(async (url, opts = {}) => {
  const auth = Buffer.from(String(opts.headers?.Authorization || '').replace('Basic ', ''), 'base64').toString();
  rzpCalls.push({ url, method: opts.method, auth, body: opts.body ? JSON.parse(opts.body) : null });
  const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
  if (rzpAuthFails) return reply(401, { error: { code: 'BAD_REQUEST_ERROR', description: 'Authentication failed' } });
  if (opts.method === 'POST' && url.endsWith('/orders')) {
    const b = JSON.parse(opts.body);
    return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, receipt: b.receipt, status: 'created' });
  }
  if (opts.method === 'GET' && url.includes('/orders')) return reply(200, { items: [] });
  return reply(404, {});
});

const sign = (secret, orderId, paymentId) =>
  crypto.createHmac('sha256', secret).update(`${orderId}|${paymentId}`).digest('hex');

test('Subscription Razorpay Payment Suite', async (t) => {
  const env = await boot();
  t.after(() => { setRazorpayFetch(null); env.gw.shutdown(); });

  let riderToken = '';
  let riderUser = null;

  await t.test('register rider and verify baseline subscription is community', async () => {
    const reg = await env.register('TestRider', 'rider@test.com');
    riderToken = reg.token;
    riderUser = reg.user;
    assert.equal(reg.user.subscriptionTier, 'community');
    const me = await env.api('GET', '/me', null, riderToken);
    assert.equal(me.status, 200);
    assert.equal(me.json.subscriptionTier, 'community');
  });

  await t.test('GET /api/subscription/config returns the active mode key id, never a secret', async () => {
    const res = await env.api('GET', '/subscription/config', null, riderToken);
    assert.equal(res.status, 200);
    assert.equal(res.json.razorpayKeyId, 'rzp_test_unitKey123');
    assert.equal(res.json.mode, 'test');
    assert.ok(!JSON.stringify(res.json).includes('unit_test_secret_456'));
    assert.equal(res.json.plans.roadCaptain.monthly, 599);
  });

  let orderData = null;
  let adminToken = '';

  await t.test('POST /api/subscription/create-order creates a real Razorpay order priced on the server', async () => {
    const res = await env.api('POST', '/subscription/create-order', {
      planTier: 'roadCaptain', billingCycle: 'monthly', amount: 1, // client amount is ignored
    }, riderToken);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    orderData = res.json;
    assert.ok(orderData.orderId.startsWith('order_'));
    assert.equal(orderData.amountInPaise, 59900);
    assert.equal(orderData.mode, 'test');
    assert.equal(orderData.razorpayOptions.key, 'rzp_test_unitKey123');
    const call = rzpCalls.at(-1);
    assert.equal(call.body.amount, 59900);
    assert.equal(call.auth, 'rzp_test_unitKey123:unit_test_secret_456');
  });

  await t.test('verify-payment without a signature does NOT activate (UTR becomes a pending claim)', async () => {
    const res = await env.api('POST', '/subscription/verify-payment', {
      orderId: orderData.orderId, planTier: 'tourOperator', utr: '123456789012',
    }, riderToken);
    assert.equal(res.status, 202);
    assert.equal(res.json.pending, true);
    const me = await env.api('GET', '/me', null, riderToken);
    assert.equal(me.json.subscriptionTier, 'community');

    const bare = await env.api('POST', '/subscription/verify-payment', { orderId: orderData.orderId }, riderToken);
    assert.equal(bare.status, 400);
  });

  await t.test('verify-payment rejects a wrong signature and an order of another account', async () => {
    const bad = await env.api('POST', '/subscription/verify-payment', {
      orderId: orderData.orderId, paymentId: 'pay_x', signature: 'deadbeef',
    }, riderToken);
    assert.equal(bad.status, 400);

    const other = await env.register('Other', 'other@test.com');
    const stolen = await env.api('POST', '/subscription/verify-payment', {
      orderId: orderData.orderId, paymentId: 'pay_x',
      signature: sign('unit_test_secret_456', orderData.orderId, 'pay_x'),
    }, other.token);
    assert.equal(stolen.status, 400);
  });

  await t.test('verify-payment with a valid signature activates the ORDERED plan and notifies via WS', async () => {
    const ws = await env.connect(riderToken);
    const paymentId = 'pay_test_upi_12345';
    const pActivated = ws.next((m) => m.type === 'SUBSCRIPTION_ACTIVATED', 2000);

    const res = await env.api('POST', '/subscription/verify-payment', {
      orderId: orderData.orderId,
      planTier: 'tourOperator', // ignored: the ledger says roadCaptain
      paymentId,
      signature: sign('unit_test_secret_456', orderData.orderId, paymentId),
    }, riderToken);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.equal(res.json.subscriptionTier, 'roadCaptain');

    const status = await env.api('GET', '/subscription/status', null, riderToken);
    assert.equal(status.json.tier, 'roadCaptain');
    assert.ok(status.json.daysRemaining >= 29);
    assert.equal(status.json.paymentHistoryCount, 1);

    const historyRes = await env.api('GET', '/subscription/history', null, riderToken);
    assert.equal(historyRes.json.history[0].orderId, orderData.orderId);
    assert.equal(historyRes.json.history[0].paymentId, paymentId);
    assert.equal(historyRes.json.history[0].amount, 599);
    assert.equal(historyRes.json.history[0].mode, 'test');
    assert.equal(historyRes.json.history[0].userSnapshot.userId, riderUser.userId);

    const activated = await pActivated;
    assert.equal(activated.tier, 'roadCaptain');
    ws.close();

    // Replaying the same order does not add days again.
    const again = await env.api('POST', '/subscription/verify-payment', {
      orderId: orderData.orderId, paymentId,
      signature: sign('unit_test_secret_456', orderData.orderId, paymentId),
    }, riderToken);
    assert.equal(again.status, 200);
    assert.equal(again.json.subscriptionValidUntil, res.json.subscriptionValidUntil);
  });

  await t.test('webhook: unsigned or wrongly signed events are rejected; signed payment.captured activates from the ledger', async () => {
    const reg2 = await env.register('ProRider2', 'pro2@test.com');
    const order = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly' }, reg2.token);
    assert.equal(order.status, 200);

    const payloadObj = {
      event: 'payment.captured',
      payload: { payment: { entity: { id: 'pay_rzp_webhook_999', order_id: order.json.orderId, amount: 14900, method: 'upi', notes: { userId: reg2.user.userId, planTier: 'tourOperator' } } } },
    };
    const body = JSON.stringify(payloadObj);

    const unsigned = await env.api('POST', '/subscription/webhook', payloadObj);
    assert.equal(unsigned.status, 400);
    const forged = await env.api('POST', '/subscription/webhook', payloadObj, null, { 'x-razorpay-signature': 'abc' });
    assert.equal(forged.status, 400);

    const signature = crypto.createHmac('sha256', 'whsec_unit_789').update(body).digest('hex');
    const hookRes = await env.api('POST', '/subscription/webhook', body, null, { 'x-razorpay-signature': signature });
    assert.equal(hookRes.status, 200);

    const me2 = await env.api('GET', '/me', null, reg2.token);
    assert.equal(me2.json.subscriptionTier, 'proRider');
    assert.ok(me2.json.subscriptionValidUntil > Date.now());
  });

  await t.test('POST /api/create-order validates minimum amount >= 100 paise', async () => {
    const res0 = await env.api('POST', '/create-order', { amount: 0 });
    assert.equal(res0.status, 400);
    assert.ok(res0.json.error.includes('100 paise'));
    const res99 = await env.api('POST', '/create-order', { amount: 99 });
    assert.equal(res99.status, 400);
  });

  await t.test('POST /api/create-order returns 401 when Razorpay rejects the keys (no simulated order)', async () => {
    rzpAuthFails = true;
    try {
      const res = await env.api('POST', '/create-order', { amount: 500 });
      assert.equal(res.status, 401);
      assert.ok(!res.json.order_id);
    } finally {
      rzpAuthFails = false;
    }
  });

  await t.test('POST /api/verify-payment validates missing fields and unknown orders', async () => {
    const created = await env.api('POST', '/create-order', { amount: 500 });
    assert.equal(created.status, 200);
    const res = await env.api('POST', '/verify-payment', { order_id: created.json.order_id });
    assert.equal(res.status, 400);
    assert.ok(res.json.error.includes('required'));

    const unknown = await env.api('POST', '/verify-payment', { order_id: 'order_nope', payment_id: 'p', signature: 's' });
    assert.equal(unknown.status, 400);

    const testMode = await env.api('POST', '/verify-payment', { order_id: created.json.order_id, payment_id: 'p', signature: 'test_verified', test_mode: true });
    assert.equal(testMode.status, 400, 'no test-mode bypass');
  });

  await t.test('POST /api/verify-payment: mismatch 400, valid HMAC 200', async () => {
    const created = await env.api('POST', '/create-order', { amount: 500 });
    const orderId = created.json.order_id;
    assert.equal(created.json.key_id, 'rzp_test_unitKey123');

    const bad = await env.api('POST', '/verify-payment', { razorpay_order_id: orderId, razorpay_payment_id: 'pay_1', razorpay_signature: 'invalid' });
    assert.equal(bad.status, 400);
    assert.equal(bad.json.success, false);
    assert.ok(bad.json.error.includes('Signature verification failed'));

    const res = await env.api('POST', '/verify-payment', {
      razorpay_order_id: orderId, razorpay_payment_id: 'pay_1',
      razorpay_signature: sign('unit_test_secret_456', orderId, 'pay_1'),
    });
    assert.equal(res.status, 200);
    assert.equal(res.json.success, true);
    assert.equal(res.json.message, 'Payment verified successfully');
  });

  await t.test('POST /api/razorpay/callback (redirect mode) verifies the form post and redirects back', async () => {
    const created = await env.api('POST', '/create-order', { amount: 500 });
    const orderId = created.json.order_id;
    const post = (fields) => fetch(`${env.origin}/api/razorpay/callback`, {
      method: 'POST', redirect: 'manual',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams(fields).toString(),
    });
    const bad = await post({ razorpay_order_id: orderId, razorpay_payment_id: 'pay_cb', razorpay_signature: 'nope' });
    assert.equal(bad.status, 303);
    assert.ok(bad.headers.get('location').includes('failed='));
    const good = await post({ razorpay_order_id: orderId, razorpay_payment_id: 'pay_cb', razorpay_signature: sign('unit_test_secret_456', orderId, 'pay_cb') });
    assert.equal(good.status, 303);
    assert.ok(good.headers.get('location').startsWith(`/checkout.html?paid=${orderId}`), good.headers.get('location'));
    const cancelled = await post({ 'error[description]': 'Payment cancelled', 'error[metadata][order_id]': orderId });
    assert.equal(cancelled.status, 303);
    assert.ok(cancelled.headers.get('location').includes('failed=Payment%20cancelled'));
  });

  await t.test('app order can be paid on the website: tokenised link, UPI-only lookup, callback activates the rider', async () => {
    const reg = await env.register('WebPayer', 'webpayer@test.com');
    const created = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly' }, reg.token);
    assert.equal(created.status, 200);
    const url = new URL(created.json.webCheckoutUrl);
    assert.equal(url.pathname, '/checkout.html');
    const orderId = url.searchParams.get('order');
    const t = url.searchParams.get('t');
    assert.equal(orderId, created.json.orderId);

    const bad = await env.api('GET', `/checkout/order/${orderId}?t=wrong`);
    assert.equal(bad.status, 403);
    const look = await env.api('GET', `/checkout/order/${orderId}?t=${t}`);
    assert.equal(look.status, 200, JSON.stringify(look.json));
    assert.equal(look.json.amount, 14900);
    assert.equal(look.json.upiOnly, true);
    assert.equal(look.json.prefill.email, 'webpayer@test.com');
    assert.ok(!JSON.stringify(look.json).includes('unit_test_secret_456'));

    const cb = await fetch(`${env.origin}/api/razorpay/callback`, {
      method: 'POST', redirect: 'manual',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ razorpay_order_id: orderId, razorpay_payment_id: 'pay_web', razorpay_signature: sign('unit_test_secret_456', orderId, 'pay_web') }).toString(),
    });
    assert.equal(cb.status, 303);
    assert.ok(cb.headers.get('location').includes('app=1&tier=proRider'), cb.headers.get('location'));
    const me = await env.api('GET', '/me', null, reg.token);
    assert.equal(me.json.subscriptionTier, 'proRider');
    const again = await env.api('GET', `/checkout/order/${orderId}?t=${t}`);
    assert.equal(again.json.status, 'PAID');
  });

  await t.test('admin: configure live keys, switch modes, secrets never returned; non-admin refused', async () => {
    const admin = await env.register('Admin', 'admin@coroute.test');
    adminToken = admin.token;
    const rider = await env.api('GET', '/admin/payment-gateway', null, riderToken);
    assert.equal(rider.status, 403);

    const view = await env.api('GET', '/admin/payment-gateway', null, admin.token);
    assert.equal(view.status, 200, JSON.stringify(view.json));
    assert.equal(view.json.mode, 'test');
    assert.equal(view.json.test.keyId, 'rzp_test_unitKey123');
    assert.equal(view.json.test.keySecretSet, true);
    assert.equal(view.json.live.keySecretSet, false);

    const early = await env.api('PUT', '/admin/payment-gateway', { mode: 'live' }, admin.token);
    assert.equal(early.status, 400, 'cannot go live without live keys');

    const wrongPrefix = await env.api('PUT', '/admin/payment-gateway', { live: { keyId: 'rzp_test_x' } }, admin.token);
    assert.equal(wrongPrefix.status, 400);

    const saved = await env.api('PUT', '/admin/payment-gateway', {
      live: { keyId: 'rzp_live_unitLive9', keySecret: 'live_secret_abc', webhookSecret: 'whsec_live' },
      mode: 'live',
    }, admin.token);
    assert.equal(saved.status, 200, JSON.stringify(saved.json));
    assert.equal(saved.json.mode, 'live');
    assert.equal(saved.json.live.source, 'admin');
    assert.ok(!JSON.stringify(saved.json).includes('live_secret_abc'));

    const cfg = await env.api('GET', '/subscription/config');
    assert.equal(cfg.json.razorpayKeyId, 'rzp_live_unitLive9');
    assert.equal(cfg.json.mode, 'live');

    // A live order is signed with the live secret; a test-secret signature fails.
    const order = await env.api('POST', '/create-order', { amount: 500 });
    assert.equal(order.json.mode, 'live');
    assert.equal(rzpCalls.at(-1).auth, 'rzp_live_unitLive9:live_secret_abc');
    const wrong = await env.api('POST', '/verify-payment', { razorpay_order_id: order.json.order_id, razorpay_payment_id: 'p9', razorpay_signature: sign('unit_test_secret_456', order.json.order_id, 'p9') });
    assert.equal(wrong.status, 400);
    const right = await env.api('POST', '/verify-payment', { razorpay_order_id: order.json.order_id, razorpay_payment_id: 'p9', razorpay_signature: sign('live_secret_abc', order.json.order_id, 'p9') });
    assert.equal(right.status, 200);

    const check = await env.api('POST', '/admin/payment-gateway/test', { mode: 'live' }, admin.token);
    assert.equal(check.status, 200);

    const back = await env.api('PUT', '/admin/payment-gateway', { mode: 'test' }, admin.token);
    assert.equal(back.json.mode, 'test');
  });

  await t.test('admin approves a pending UTR claim', async () => {
    const reg = await env.register('UtrRider', 'utr@test.com');
    const order = await env.api('POST', '/subscription/create-order', { planTier: 'proRider' }, reg.token);
    const claim = await env.api('POST', '/subscription/verify-payment', { orderId: order.json.orderId, utr: '998877665544' }, reg.token);
    assert.equal(claim.status, 202);
    const adminTok = adminToken;
    const list = await env.api('GET', '/admin/payment-claims', null, adminTok);
    assert.equal(list.status, 200, JSON.stringify(list.json));
    assert.ok(list.json.claims.some((c) => c.orderId === order.json.orderId));
    const ok = await env.api('POST', `/admin/payment-claims/${order.json.orderId}/approve`, {}, adminTok);
    assert.equal(ok.status, 200);
    const me = await env.api('GET', '/me', null, reg.token);
    assert.equal(me.json.subscriptionTier, 'proRider');
  });

  await t.test('POST /api/subscription/validate-coupon evaluates discount rules, limits and expiry', async () => {
    // 1. WELCOME50 (50% off Rs 149 = Rs 75 discount, payable Rs 74)
    const res50 = await env.api('POST', '/subscription/validate-coupon', {
      code: 'WELCOME50',
      planTier: 'proRider',
      billingCycle: 'monthly',
      amount: 149,
    });
    assert.equal(res50.status, 200);
    assert.equal(res50.json.valid, true);
    assert.equal(res50.json.discountAmount, 75);
    assert.equal(res50.json.finalAmount, 74);
    assert.equal(res50.json.finalAmountPaise, 7400);
    assert.equal(res50.json.isFree, false);
    assert.ok(res50.json.usagesRemaining >= 900);

    // 2. CAPTAIN100 (Flat Rs 100 off on Road Captain Rs 599 -> payable Rs 499)
    const resCap = await env.api('POST', '/subscription/validate-coupon', {
      code: 'CAPTAIN100',
      planTier: 'roadCaptain',
      billingCycle: 'monthly',
      amount: 599,
    });
    assert.equal(resCap.status, 200);
    assert.equal(resCap.json.valid, true);
    assert.equal(resCap.json.discountAmount, 100);
    assert.equal(resCap.json.finalAmount, 499);

    // 3. RIDERFREE (100% Free Pass -> payable Rs 0)
    const resFree = await env.api('POST', '/subscription/validate-coupon', {
      code: 'RIDERFREE',
      planTier: 'proRider',
      billingCycle: 'monthly',
      amount: 149,
    });
    assert.equal(resFree.status, 200);
    assert.equal(resFree.json.valid, true);
    assert.equal(resFree.json.isFree, true);
    assert.equal(resFree.json.finalAmount, 0);

    // 4. Invalid coupon returns 404
    const resInv = await env.api('POST', '/subscription/validate-coupon', {
      code: 'NON_EXISTENT_COUPON',
      planTier: 'proRider',
      billingCycle: 'monthly',
      amount: 149,
    });
    assert.equal(resInv.status, 404);
    assert.equal(resInv.json.valid, false);
  });

  await t.test('POST /api/create-order and /api/verify-payment handle 100% free coupons without payment gateway', async () => {
    // Create order with RIDERFREE coupon
    const freeOrderRes = await env.api('POST', '/create-order', {
      amount: 14900,
      coupon_code: 'RIDERFREE',
      notes: { planTier: 'proRider', billingCycle: 'monthly' },
    });
    assert.equal(freeOrderRes.status, 200);
    assert.equal(freeOrderRes.json.is_free, true);
    assert.equal(freeOrderRes.json.amount, 0);
    assert.ok(freeOrderRes.json.order_id.startsWith('order_free_'));

    // Verify free order
    const freeVerifyRes = await env.api('POST', '/verify-payment', {
      order_id: freeOrderRes.json.order_id,
      is_free: true,
      coupon_code: 'RIDERFREE',
      userId: riderUser.userId,
    });
    assert.equal(freeVerifyRes.status, 200);
    assert.equal(freeVerifyRes.json.success, true);
    assert.equal(freeVerifyRes.json.is_free, true);
  });

  await t.test('Admin can dynamically configure subscription pricing and coupons with limits', async () => {
    // 1. Register admin
    // Admin registered in the payment-gateway test above (adminToken).

    // 2. Non-admin is refused admin endpoints
    const nonAdminRes = await env.api('PUT', '/admin/subscription/pricing', {
      plans: { proRider: { monthly: 199 } },
    }, riderToken);
    assert.equal(nonAdminRes.status, 403);

    // 3. Admin updates pricing
    const putRes = await env.api('PUT', '/admin/subscription/pricing', {
      plans: {
        proRider: { monthly: 199, annual: 1599, label: 'CoRoute Pro Max' },
      },
    }, adminToken);
    assert.equal(putRes.status, 200);
    assert.equal(putRes.json.success, true);
    assert.equal(putRes.json.plans.proRider.monthly, 199);
    assert.equal(putRes.json.plans.proRider.label, 'CoRoute Pro Max');

    // 4. Verify public GET /api/subscription/config immediately reflects the customized pricing
    const cfgRes = await env.api('GET', '/subscription/config', null, riderToken);
    assert.equal(cfgRes.json.plans.proRider.monthly, 199);
    assert.equal(cfgRes.json.plans.proRider.label, 'CoRoute Pro Max');

    // 5. Admin creates a new coupon with usage limit and expiry
    const newCouponRes = await env.api('POST', '/admin/coupons', {
      code: 'FESTIVE25',
      description: 'Festive Season 25% Off',
      discountType: 'percentage',
      discountValue: 25,
      applicableTiers: ['proRider', 'roadCaptain'],
      maxUsageTotal: 250,
      maxUsagePerUser: 1,
      expiresAt: Date.now() + 60 * 86400000,
    }, adminToken);
    assert.equal(newCouponRes.status, 201);
    assert.equal(newCouponRes.json.success, true);
    assert.equal(newCouponRes.json.coupon.code, 'FESTIVE25');
    assert.equal(newCouponRes.json.coupon.maxUsageTotal, 250);

    // 6. Admin lists coupons and verifies FESTIVE25 is present
    const listRes = await env.api('GET', '/admin/coupons', null, adminToken);
    assert.equal(listRes.status, 200);
    assert.ok(listRes.json.coupons.some((c) => c.code === 'FESTIVE25'));

    // 7. Validate FESTIVE25 via public endpoint
    const testValidate = await env.api('POST', '/subscription/validate-coupon', {
      code: 'FESTIVE25',
      planTier: 'proRider',
      billingCycle: 'monthly',
      amount: 200,
    });
    assert.equal(testValidate.status, 200);
    assert.equal(testValidate.json.discountAmount, 50); // 25% of 200
    assert.equal(testValidate.json.finalAmount, 150);

    // 8. Admin patches coupon (e.g. adjusts limit or pauses)
    const patchRes = await env.api('PATCH', '/admin/coupons/FESTIVE25', {
      isActive: false,
    }, adminToken);
    assert.equal(patchRes.status, 200);
    assert.equal(patchRes.json.coupon.isActive, false);

    // 9. When paused, validation rejects with 400
    const pausedValidate = await env.api('POST', '/subscription/validate-coupon', {
      code: 'FESTIVE25',
      planTier: 'proRider',
      amount: 200,
    });
    assert.equal(pausedValidate.status, 400);
    assert.equal(pausedValidate.json.valid, false);

    // 10. Admin deletes coupon
    const delRes = await env.api('DELETE', '/admin/coupons/FESTIVE25', null, adminToken);
    assert.equal(delRes.status, 200);
  });
});

test('Subscription lifecycle: effective tier, expiry rollback, warnings, history, admin grant/revoke', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const { effectiveSubscription } = require('../src/subscription_lifecycle');
  const DAY = 86400000;
  const repo = env.gw.repo;
  const sweeper = env.gw.subscriptions;

  const admin = await env.register('LifeAdmin', 'admin@coroute.test');
  const rider = await env.register('LifeRider', 'life.rider@test.com');
  const other = await env.register('LifeOther', 'life.other@test.com');
  const riderId = rider.user.userId;
  const doc = async () => repo.findUserById(riderId);

  await t.test('effectiveSubscription is pure and reads a lapsed paid tier as community', () => {
    const now = Date.now();
    const live = effectiveSubscription({ subscriptionTier: 'proRider', subscriptionValidUntil: now + 5 * DAY }, now);
    assert.equal(live.tier, 'proRider'); assert.equal(live.isActive, true); assert.equal(live.isExpired, false);
    assert.equal(live.daysRemaining, 5); assert.equal(live.expiringSoon, true);
    const gone = effectiveSubscription({ subscriptionTier: 'roadCaptain', subscriptionValidUntil: now - 1000 }, now);
    assert.equal(gone.tier, 'community'); assert.equal(gone.isActive, false); assert.equal(gone.isExpired, true);
    assert.equal(gone.previousTier, 'roadCaptain'); assert.equal(gone.daysRemaining, 0);
    const free = effectiveSubscription({}, now);
    assert.equal(free.tier, 'community'); assert.equal(free.isActive, true); assert.equal(free.isExpired, false);
  });

  await t.test('login and register responses carry subscriptionStatus', async () => {
    assert.equal(rider.user.subscriptionStatus.tier, 'community');
    const login = await env.api('POST', '/auth/login', { identifier: 'life.rider@test.com', password: 'Password#123' });
    assert.equal(login.status, 200);
    assert.equal(login.json.user.subscriptionStatus.tier, 'community');
    assert.equal(login.json.user.subscriptionStatus.isActive, true);
  });

  await t.test('expired rider: /me shows community + isExpired, document rolled back with history, WS SUBSCRIPTION_EXPIRED', async () => {
    const d = await doc();
    const expiredAt = Date.now() - 2 * DAY;
    await repo.updateUser(d.key, { subscriptionTier: 'proRider', subscriptionValidUntil: expiredAt, lastPayment: { validFrom: expiredAt - 30 * DAY } });
    env.gw.gate.invalidate(riderId);
    const ws = await env.connect(rider.token);
    const me = await env.api('GET', '/me', null, rider.token);
    assert.equal(me.status, 200);
    assert.equal(me.json.subscriptionTier, 'community');
    assert.equal(me.json.subscriptionStatus.tier, 'community');
    assert.equal(me.json.subscriptionStatus.isExpired, true);
    assert.equal(me.json.subscriptionStatus.previousTier, 'proRider');
    const msg = await ws.next((m) => m.type === 'SUBSCRIPTION_EXPIRED');
    assert.equal(msg.previousTier, 'proRider');
    assert.equal(msg.expiredAt, expiredAt);
    const after = await doc();
    assert.equal(after.subscriptionTier, 'community');
    assert.equal(after.subscriptionValidUntil, 0);
    assert.equal(after.subscriptionExpiredAt, expiredAt);
    assert.equal(after.previousTier, 'proRider');
    assert.equal(after.subscriptionHistory.length, 1);
    assert.equal(after.subscriptionHistory[0].reason, 'expired');
    assert.equal(after.subscriptionHistory[0].tier, 'proRider');
    assert.equal(after.subscriptionHistory[0].validUntil, expiredAt);
    // Idempotent: a second /me adds nothing.
    await env.api('GET', '/me', null, rider.token);
    assert.equal((await doc()).subscriptionHistory.length, 1);
    const status = await env.api('GET', '/subscription/status', null, rider.token);
    assert.equal(status.json.tier, 'community'); assert.equal(status.json.isExpired, true);
    ws.close();
  });

  await t.test('sweeper warns at 7, 3 and 1 days once each, then expires with WS SUBSCRIPTION_EXPIRED', async () => {
    const d = await doc();
    const start = Date.now();
    const validUntil = start + 10 * DAY;
    await repo.updateUser(d.key, { subscriptionTier: 'roadCaptain', subscriptionValidUntil: validUntil, subscriptionWarnedAt: {}, subscriptionHistory: [] });
    env.gw.gate.invalidate(riderId);
    const ws = await env.connect(rider.token);
    // (ws.next on timeout would leave a waiter behind that eats the next message; poll the inbox instead)
    const noMsg = async () => {
      await new Promise((r) => setTimeout(r, 250));
      assert.ok(!ws.inbox.some((m) => m.type === 'SUBSCRIPTION_EXPIRING' || m.type === 'SUBSCRIPTION_EXPIRED'), 'unexpected subscription message');
    };

    let s = await sweeper.runOnce(start + 1 * DAY); // 9 days left: nothing
    assert.equal(s.warned, 0); await noMsg();

    s = await sweeper.runOnce(start + 3.5 * DAY); // 6.5 -> 7 days left: d7
    assert.equal(s.warned, 1);
    let m = await ws.next((x) => x.type === 'SUBSCRIPTION_EXPIRING');
    assert.equal(m.warning, 'd7'); assert.equal(m.tier, 'roadCaptain'); assert.equal(m.validUntil, validUntil); assert.equal(m.daysRemaining, 7);
    s = await sweeper.runOnce(start + 3.5 * DAY); assert.equal(s.warned, 0); await noMsg();
    assert.ok((await doc()).subscriptionWarnedAt.d7 > 0);

    s = await sweeper.runOnce(start + 7.5 * DAY); // 3 days left: d3
    assert.equal(s.warned, 1);
    m = await ws.next((x) => x.type === 'SUBSCRIPTION_EXPIRING'); assert.equal(m.warning, 'd3'); assert.equal(m.daysRemaining, 3);
    s = await sweeper.runOnce(start + 7.6 * DAY); assert.equal(s.warned, 0); await noMsg();

    s = await sweeper.runOnce(start + 9.5 * DAY); // 1 day left: d1
    assert.equal(s.warned, 1);
    m = await ws.next((x) => x.type === 'SUBSCRIPTION_EXPIRING'); assert.equal(m.warning, 'd1'); assert.equal(m.daysRemaining, 1);
    s = await sweeper.runOnce(start + 9.9 * DAY); assert.equal(s.warned, 0); await noMsg();
    const warned = (await doc()).subscriptionWarnedAt;
    assert.ok(warned.d7 && warned.d3 && warned.d1);

    s = await sweeper.runOnce(start + 11 * DAY); // expired
    assert.equal(s.expired, 1); assert.equal(s.warned, 0);
    m = await ws.next((x) => x.type === 'SUBSCRIPTION_EXPIRED');
    assert.equal(m.previousTier, 'roadCaptain'); assert.equal(m.expiredAt, validUntil);
    const after = await doc();
    assert.equal(after.subscriptionTier, 'community');
    assert.equal(after.subscriptionHistory.at(-1).reason, 'expired');
    s = await sweeper.runOnce(start + 12 * DAY); assert.equal(s.expired, 0); assert.equal(s.scanned, 0);
    ws.close();
  });

  await t.test('non-admin gets 403 on admin subscription endpoints', async () => {
    for (const [method, path, body] of [
      ['GET', '/admin/payments', null], ['GET', `/admin/payments/users/${riderId}`, null],
      ['POST', `/admin/subscription/users/${riderId}/grant`, { planTier: 'proRider', days: 10 }],
      ['POST', `/admin/subscription/users/${riderId}/revoke`, { reason: 'x' }],
    ]) {
      const r = await env.api(method, path, body, other.token);
      assert.equal(r.status, 403, `${method} ${path}`);
    }
  });

  let grantOrderId = '';
  await t.test('admin grant extends the rider, writes a ledger order and an audited history entry', async () => {
    const bad = await env.api('POST', `/admin/subscription/users/${riderId}/grant`, { planTier: 'community', days: 10 }, admin.token);
    assert.equal(bad.status, 400);
    const ws = await env.connect(rider.token);
    const r = await env.api('POST', `/admin/subscription/users/${riderId}/grant`, { planTier: 'tourOperator', days: 45, reason: 'goodwill' }, admin.token);
    assert.equal(r.status, 200, JSON.stringify(r.json));
    assert.equal(r.json.subscriptionTier, 'tourOperator');
    assert.ok(r.json.subscriptionValidUntil > Date.now() + 44 * DAY && r.json.subscriptionValidUntil <= Date.now() + 45 * DAY + 5000);
    assert.equal(r.json.subscriptionStatus.tier, 'tourOperator');
    grantOrderId = r.json.orderId;
    assert.ok(grantOrderId.startsWith('manual_'));
    const act = await ws.next((x) => x.type === 'SUBSCRIPTION_ACTIVATED');
    assert.equal(act.tier, 'tourOperator'); assert.equal(act.method, 'MANUAL');
    const order = await repo.findRazorpayOrder(grantOrderId);
    assert.equal(order.status, 'PAID'); assert.equal(order.mode, 'manual'); assert.equal(order.userId, riderId);
    const d = await doc();
    assert.equal(d.subscriptionTier, 'tourOperator');
    assert.equal(d.subscriptionExpiredAt, 0);
    const entry = d.subscriptionHistory.at(-1);
    assert.equal(entry.reason, 'granted'); assert.equal(entry.by, admin.user.userId); assert.equal(entry.days, 45); assert.equal(entry.tier, 'tourOperator');
    assert.equal(d.paymentHistory.at(-1).billingCycle, 'manual');
    const me = await env.api('GET', '/me', null, rider.token);
    assert.equal(me.json.subscriptionStatus.tier, 'tourOperator'); assert.equal(me.json.subscriptionStatus.isExpired, false);
    ws.close();
  });

  await t.test('rider history returns orders (newest first) and tier periods; /subscription/orders is the ledger alone', async () => {
    const h = await env.api('GET', '/subscription/history', null, rider.token);
    assert.equal(h.status, 200);
    assert.equal(h.json.currentTier, 'tourOperator');
    assert.ok(Array.isArray(h.json.subscriptionHistory) && h.json.subscriptionHistory.some((p) => p.reason === 'expired'));
    assert.ok(h.json.subscriptionHistory.some((p) => p.reason === 'granted'));
    assert.equal(h.json.orders.length, 1);
    const o = h.json.orders[0];
    assert.equal(o.orderId, grantOrderId); assert.equal(o.status, 'PAID'); assert.equal(o.amount, 0); assert.equal(o.mode, 'manual');
    assert.equal(o.paymentId, grantOrderId); assert.equal(o.planTier, 'tourOperator'); assert.ok(o.createdAt > 0 && o.paidAt > 0);
    assert.equal(h.json.subscriptionStatus.tier, 'tourOperator');
    const orders = await env.api('GET', '/subscription/orders', null, rider.token);
    assert.equal(orders.status, 200);
    assert.deepEqual(orders.json.orders.map((x) => x.orderId), [grantOrderId]);
    const none = await env.api('GET', '/subscription/orders', null, other.token);
    assert.deepEqual(none.json.orders, []);
  });

  await t.test('admin payments list joins user name/email; per-user view returns both histories', async () => {
    const all = await env.api('GET', '/admin/payments?limit=50', null, admin.token);
    assert.equal(all.status, 200);
    const row = all.json.payments.find((p) => p.orderId === grantOrderId);
    assert.ok(row); assert.equal(row.user.email, 'life.rider@test.com'); assert.equal(row.user.name, 'LifeRider');
    const byUser = await env.api('GET', `/admin/payments?userId=${riderId}&status=paid`, null, admin.token);
    assert.equal(byUser.json.payments.length, 1);
    const byStatus = await env.api('GET', `/admin/payments?status=CREATED`, null, admin.token);
    assert.equal(byStatus.json.payments.length, 0);
    const u = await env.api('GET', `/admin/payments/users/${riderId}`, null, admin.token);
    assert.equal(u.status, 200);
    assert.equal(u.json.paymentHistory.length, 1);
    assert.equal(u.json.subscriptionHistory.length, 2);
    assert.equal(u.json.subscriptionStatus.tier, 'tourOperator');
    assert.equal(u.json.orders.length, 1);
    const missing = await env.api('GET', '/admin/payments/users/nobody', null, admin.token);
    assert.equal(missing.status, 404);
  });

  await t.test('admin revoke sets community now with an audited history entry and WS SUBSCRIPTION_REVOKED', async () => {
    const ws = await env.connect(rider.token);
    const r = await env.api('POST', `/admin/subscription/users/${riderId}/revoke`, { reason: 'chargeback' }, admin.token);
    assert.equal(r.status, 200, JSON.stringify(r.json));
    assert.equal(r.json.subscriptionTier, 'community'); assert.equal(r.json.previousTier, 'tourOperator');
    const m = await ws.next((x) => x.type === 'SUBSCRIPTION_REVOKED');
    assert.equal(m.previousTier, 'tourOperator'); assert.equal(m.reason, 'chargeback');
    const d = await doc();
    assert.equal(d.subscriptionTier, 'community'); assert.equal(d.subscriptionValidUntil, 0);
    const entry = d.subscriptionHistory.at(-1);
    assert.equal(entry.reason, 'revoked'); assert.equal(entry.by, admin.user.userId); assert.equal(entry.tier, 'tourOperator');
    const me = await env.api('GET', '/me', null, rider.token);
    assert.equal(me.json.subscriptionTier, 'community');
    assert.equal(me.json.subscriptionStatus.tier, 'community');
    assert.equal(me.json.subscriptionStatus.previousTier, 'tourOperator');
    ws.close();
  });
});
