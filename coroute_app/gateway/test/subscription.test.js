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
const { webCheckoutToken } = require('../src/subscription_routes');
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
    assert.equal(res.json.upiVpa, undefined, 'no direct VPA');
    assert.equal(res.json.merchantName, undefined);
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
    for (const k of ['upiUri', 'upiVpa', 'merchantName']) assert.equal(orderData[k], undefined, k);
    const link = new URL(orderData.webCheckoutUrl);
    assert.ok(Number(link.searchParams.get('e')) > Date.now());
  });

  await t.test('verify-payment with only a UPI UTR is refused (410): there is no direct VPA path', async () => {
    const res = await env.api('POST', '/subscription/verify-payment', {
      orderId: orderData.orderId, planTier: 'tourOperator', utr: '123456789012',
    }, riderToken);
    assert.equal(res.status, 410);
    assert.equal(res.json.error, 'Pay with UPI through Razorpay in the app or on the website');
    const me = await env.api('GET', '/me', null, riderToken);
    assert.equal(me.json.subscriptionTier, 'community');
    assert.equal((await env.gw.repo.findRazorpayOrder(orderData.orderId)).status, 'CREATED');

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

  await t.test('public order creation is gone: POST /create-order and /api/create-order are 404', async () => {
    for (const p of ['/create-order', '/api/create-order']) {
      const signedIn = await env.api('POST', p, { amount: 500, planTier: 'proRider' }, riderToken);
      assert.equal(signedIn.status, 404, p);
      const anon = await env.api('POST', p, { amount: 500 });
      assert.ok([401, 404].includes(anon.status), `${p} -> ${anon.status}`);
      assert.ok(!anon.json.order_id);
    }
    const offers = await env.api('GET', '/subscription/offers', null, riderToken);
    assert.equal(offers.status, 404, 'public offers route removed (the app reads offers from create-order)');
  });

  let webRider = null;
  const appOrder = async () => {
    const r = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly' }, webRider.token);
    assert.equal(r.status, 200, JSON.stringify(r.json));
    return r.json;
  };

  await t.test("POST /api/verify-payment accepts only a signed-in rider's ledger order", async () => {
    webRider = await env.register('WebVerify', 'webverify@test.com');
    const created = await appOrder();
    const missing = await env.api('POST', '/verify-payment', { order_id: created.orderId });
    assert.equal(missing.status, 400);
    assert.ok(missing.json.error.includes('required'));
    const unknown = await env.api('POST', '/verify-payment', { order_id: 'order_nope', payment_id: 'p', signature: 's' });
    assert.equal(unknown.status, 400);
    const testMode = await env.api('POST', '/verify-payment', { order_id: created.orderId, payment_id: 'p', signature: 'test_verified', test_mode: true });
    assert.equal(testMode.status, 400, 'no test-mode bypass');

    // A ledger order without a rider (left over from the removed public flow) is refused even when correctly signed.
    await env.gw.repo.saveRazorpayOrder({ orderId: 'order_guest_legacy', userId: null, planTier: 'proRider', billingCycle: 'monthly', amountInPaise: 14900, mode: 'test', status: 'CREATED', createdAt: Date.now() });
    const guest = await env.api('POST', '/verify-payment', { razorpay_order_id: 'order_guest_legacy', razorpay_payment_id: 'pay_g', razorpay_signature: sign('unit_test_secret_456', 'order_guest_legacy', 'pay_g') });
    assert.equal(guest.status, 400);
    assert.equal((await env.gw.repo.findRazorpayOrder('order_guest_legacy')).status, 'CREATED');

    const bad = await env.api('POST', '/verify-payment', { razorpay_order_id: created.orderId, razorpay_payment_id: 'pay_1', razorpay_signature: 'invalid' });
    assert.equal(bad.status, 400);
    assert.equal(bad.json.success, false);
    assert.ok(bad.json.error.includes('Signature verification failed'));

    const res = await env.api('POST', '/verify-payment', {
      razorpay_order_id: created.orderId, razorpay_payment_id: 'pay_1',
      razorpay_signature: sign('unit_test_secret_456', created.orderId, 'pay_1'),
    });
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.equal(res.json.success, true);
    assert.equal(res.json.message, 'Payment verified successfully');
    assert.equal(res.json.activated.tier, 'proRider');
  });

  await t.test('POST /api/razorpay/callback (redirect mode) verifies the form post and redirects back; a non-rider order is 400', async () => {
    const created = await appOrder();
    const orderId = created.orderId;
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
    const guest = await post({ razorpay_order_id: 'order_guest_legacy', razorpay_payment_id: 'pay_cb2', razorpay_signature: sign('unit_test_secret_456', 'order_guest_legacy', 'pay_cb2') });
    assert.equal(guest.status, 400);
  });

  await t.test('app order can be paid on the website: link signed with its expiry, UPI-only lookup, callback activates the rider', async () => {
    const reg = await env.register('WebPayer', 'webpayer@test.com');
    const created = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly' }, reg.token);
    assert.equal(created.status, 200);
    const url = new URL(created.json.webCheckoutUrl);
    assert.equal(url.pathname, '/checkout.html');
    const orderId = url.searchParams.get('order');
    const t = url.searchParams.get('t');
    const e = Number(url.searchParams.get('e'));
    assert.equal(orderId, created.json.orderId);
    assert.equal(t.length, 32);
    assert.equal(e, created.json.webCheckoutExpiresAt);
    assert.ok(e > Date.now() + 29 * 60000 && e <= Date.now() + 30 * 60000 + 1000, 'expires 30 minutes after the order');

    const bad = await env.api('GET', `/checkout/order/${orderId}?t=wrong&e=${e}`);
    assert.equal(bad.status, 403);
    const noExpiry = await env.api('GET', `/checkout/order/${orderId}?t=${t}`);
    assert.equal(noExpiry.status, 403);
    const stretched = await env.api('GET', `/checkout/order/${orderId}?t=${t}&e=${e + 3600000}`);
    assert.equal(stretched.status, 403, 'the expiry is signed: it cannot be extended');
    const past = Date.now() - 1000;
    const expired = await env.api('GET', `/checkout/order/${orderId}?t=${webCheckoutToken(orderId, past)}&e=${past}`);
    assert.equal(expired.status, 410);
    assert.equal(expired.json.error, 'Link expired — start again in the app');

    const look = await env.api('GET', `/checkout/order/${orderId}?t=${t}&e=${e}`);
    assert.equal(look.status, 200, JSON.stringify(look.json));
    assert.equal(look.json.amount, 14900);
    assert.equal(look.json.upiOnly, true);
    assert.equal(look.json.expiresAt, e);
    assert.equal(look.json.planLabel, 'CoRoute Pro');
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
    const again = await env.api('GET', `/checkout/order/${orderId}?t=${t}&e=${e}`);
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
    const liveRider = await env.register('LiveRider', 'live.rider@test.com');
    const order = await env.api('POST', '/subscription/create-order', { planTier: 'proRider' }, liveRider.token);
    assert.equal(order.json.mode, 'live');
    assert.equal(rzpCalls.at(-1).auth, 'rzp_live_unitLive9:live_secret_abc');
    const wrong = await env.api('POST', '/verify-payment', { razorpay_order_id: order.json.orderId, razorpay_payment_id: 'p9', razorpay_signature: sign('unit_test_secret_456', order.json.orderId, 'p9') });
    assert.equal(wrong.status, 400);
    const right = await env.api('POST', '/verify-payment', { razorpay_order_id: order.json.orderId, razorpay_payment_id: 'p9', razorpay_signature: sign('live_secret_abc', order.json.orderId, 'p9') });
    assert.equal(right.status, 200);

    const check = await env.api('POST', '/admin/payment-gateway/test', { mode: 'live' }, admin.token);
    assert.equal(check.status, 200);

    const back = await env.api('PUT', '/admin/payment-gateway', { mode: 'test' }, admin.token);
    assert.equal(back.json.mode, 'test');
  });

  await t.test('the direct-UPI claim routes are gone', async () => {
    const list = await env.api('GET', '/admin/payment-claims', null, adminToken);
    assert.equal(list.status, 404);
    const approve = await env.api('POST', '/admin/payment-claims/order_x/approve', {}, adminToken);
    assert.equal(approve.status, 404);
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

  await t.test('a 100% free coupon order from the app activates without Razorpay; the public verify refuses it', async () => {
    const free = await env.register('FreeRider', 'free.rider@test.com');
    const before = rzpCalls.length;
    const order = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly', couponCode: 'RIDERFREE' }, free.token);
    assert.equal(order.status, 200, JSON.stringify(order.json));
    assert.equal(order.json.isFree, true);
    assert.equal(order.json.amount, 0);
    assert.ok(order.json.orderId.startsWith('order_free_'));
    assert.equal(rzpCalls.length, before, 'no Razorpay order for a free coupon');
    const pub = await env.api('POST', '/verify-payment', { order_id: order.json.orderId, is_free: true });
    assert.equal(pub.status, 400);
    const ok = await env.api('POST', '/subscription/verify-payment', { orderId: order.json.orderId }, free.token);
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
    assert.equal(ok.json.method, 'COUPON_FREE');
    assert.equal(ok.json.subscriptionTier, 'proRider');
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

test('Admin console: overview, subscribers list, offers (auto-apply, coupon wins, redemptions), pricing history, 403s', async (t) => {
  const env = await boot();
  // The first suite resets the Razorpay fake in its t.after(); this suite needs its own.
  setRazorpayFetch(async (url, opts = {}) => {
    const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
    if (opts.method === 'POST' && url.endsWith('/orders')) {
      const b = JSON.parse(opts.body);
      return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, receipt: b.receipt, status: 'created' });
    }
    if (opts.method === 'GET' && url.includes('/orders')) return reply(200, { items: [] });
    return reply(404, {});
  });
  t.after(() => { setRazorpayFetch(null); env.gw.shutdown(); });
  const DAY = 86400000;
  const repo = env.gw.repo;

  const admin = await env.register('ConsoleAdmin', 'admin@coroute.test');
  const paid = await env.register('PaidRider', 'console.paid@test.com');
  const lapsed = await env.register('LapsedRider', 'console.lapsed@test.com');
  const buyer = await env.register('OfferBuyer', 'console.buyer@test.com');
  const A = admin.token;

  await t.test('non-admin gets 403 on every console endpoint', async () => {
    const calls = [
      ['GET', '/admin/subscription/overview'], ['GET', '/admin/subscriptions'],
      ['GET', '/admin/offers'], ['POST', '/admin/offers', { title: 'x', discountValue: 10 }],
      ['PATCH', '/admin/offers/nope', { title: 'y' }], ['DELETE', '/admin/offers/nope'],
      ['GET', '/admin/subscription/pricing'], ['PUT', '/admin/subscription/pricing', { plans: { proRider: { monthly: 1 } } }],
      ['GET', '/admin/payments'], ['GET', `/admin/payments/users/${paid.user.userId}`],
    ];
    for (const [m, path, body] of calls) {
      const res = await env.api(m, path, body || null, paid.token);
      assert.equal(res.status, 403, `${m} ${path} -> ${res.status}`);
    }
  });

  let paidOrderId = '';
  await t.test('one paid rider (signed verify), one lapsed rider, one bad signature, one UTR claim', async () => {
    const order = await env.api('POST', '/subscription/create-order', { planTier: 'roadCaptain', billingCycle: 'monthly' }, paid.token);
    assert.equal(order.status, 200, JSON.stringify(order.json));
    assert.equal(order.json.offer, undefined);
    paidOrderId = order.json.orderId;
    const bad = await env.api('POST', '/subscription/verify-payment', { orderId: paidOrderId, paymentId: 'pay_bad', signature: 'nope' }, paid.token);
    assert.equal(bad.status, 400);
    const ok = await env.api('POST', '/subscription/verify-payment', {
      orderId: paidOrderId, paymentId: 'pay_ok_1', signature: sign('unit_test_secret_456', paidOrderId, 'pay_ok_1'),
    }, paid.token);
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
    assert.equal(ok.json.subscriptionTier, 'roadCaptain');

    const d = await repo.findUserById(lapsed.user.userId);
    await repo.updateUser(d.key, { subscriptionTier: 'proRider', subscriptionValidUntil: Date.now() - 2 * DAY, lastPayment: { validFrom: Date.now() - 32 * DAY, amount: 149, method: 'RAZORPAY', paidAt: Date.now() - 32 * DAY } });
    env.gw.gate.invalidate(lapsed.user.userId);

    const claimOrder = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly' }, buyer.token);
    const claim = await env.api('POST', '/subscription/verify-payment', { orderId: claimOrder.json.orderId, utr: '999888777666' }, buyer.token);
    assert.equal(claim.status, 410, 'the UTR path was removed');
  });

  await t.test('overview counts subscribers, revenue (test mode separate), claims and failed signatures', async () => {
    const res = await env.api('GET', '/admin/subscription/overview', null, A);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    const o = res.json;
    assert.equal(o.subscribers.roadCaptain, 1);
    assert.equal(o.subscribers.proRider, 0);
    assert.equal(o.subscribers.community, 3); // admin, lapsed (effective community), buyer
    assert.equal(o.active, 1);
    assert.equal(o.expiringIn7Days, 0);
    assert.equal(o.expiredLast30Days, 1);
    assert.equal(o.revenue.allTime, 0); // test-mode orders are not real revenue
    assert.equal(o.testRevenue.today, 599);
    assert.equal(o.testRevenue.last7Days, 599);
    assert.equal(o.testRevenue.allTime, 599);
    assert.equal(o.pendingClaims, 0); // kept at 0 for older app builds
    assert.equal(o.failedPayments, 0);
    assert.equal(o.refundedOrders, 0);
    assert.equal(o.failedSignatures, 0); // the bad signature was followed by a good one on the same order (now PAID)
    assert.equal(typeof o.lastSweepAt, 'number');
    // A sweep records lastSweepAt
    await env.gw.subscriptions.runOnce();
    const again = await env.api('GET', '/admin/subscription/overview', null, A);
    assert.ok(again.json.lastSweepAt > 0);
    assert.equal(again.json.lastSweep.scanned >= 1, true);
  });

  await t.test('subscribers list: state/tier filters, search, rows shape', async () => {
    const active = await env.api('GET', '/admin/subscriptions?state=active', null, A);
    assert.equal(active.status, 200);
    assert.equal(active.json.subscribers.length, 1);
    const row = active.json.subscribers[0];
    assert.equal(row.userId, paid.user.userId);
    assert.equal(row.tier, 'roadCaptain');
    assert.equal(row.email, 'console.paid@test.com');
    assert.ok(row.phone);
    assert.ok(row.validUntil > Date.now());
    assert.equal(row.daysRemaining, 30);
    assert.equal(row.lastPayment.amount, 599);
    assert.equal(row.lastPayment.method, 'RAZORPAY');
    assert.ok(row.lastPayment.paidAt > 0);
    assert.equal(row.totalPaid, 599);

    const expired = await env.api('GET', '/admin/subscriptions?state=expired', null, A);
    assert.equal(expired.json.subscribers.length, 1);
    assert.equal(expired.json.subscribers[0].userId, lapsed.user.userId);
    assert.equal(expired.json.subscribers[0].tier, 'community');
    assert.equal(expired.json.subscribers[0].previousTier, 'proRider');

    const expiring = await env.api('GET', '/admin/subscriptions?state=expiring', null, A);
    assert.equal(expiring.json.subscribers.length, 0);

    const byTier = await env.api('GET', '/admin/subscriptions?tier=roadCaptain', null, A);
    assert.equal(byTier.json.subscribers.length, 1);
    const expiredPro = await env.api('GET', '/admin/subscriptions?tier=proRider&state=expired', null, A);
    assert.equal(expiredPro.json.subscribers.length, 1);

    const search = await env.api('GET', '/admin/subscriptions?q=console.buyer', null, A);
    assert.equal(search.json.subscribers.length, 1);
    assert.equal(search.json.subscribers[0].userId, buyer.user.userId);

    const all = await env.api('GET', '/admin/subscriptions?limit=2', null, A);
    assert.equal(all.json.subscribers.length, 2);
    assert.equal(all.json.total, 4);
    assert.equal(all.json.nextCursor, '2');
    const page2 = await env.api('GET', '/admin/subscriptions?limit=2&cursor=2', null, A);
    assert.equal(page2.json.subscribers.length, 2);
    assert.equal(page2.json.nextCursor, null);
  });

  let offerId = '';
  await t.test('offers: validation, create, list, patch, public listing', async () => {
    const bad = await env.api('POST', '/admin/offers', { title: '', discountValue: 10 }, A);
    assert.equal(bad.status, 400);
    const badPct = await env.api('POST', '/admin/offers', { title: 'Too much', discountType: 'percentage', discountValue: 150 }, A);
    assert.equal(badPct.status, 400);
    const badDates = await env.api('POST', '/admin/offers', { title: 'Dates', discountValue: 10, startsAt: Date.now(), endsAt: Date.now() - 1 }, A);
    assert.equal(badDates.status, 400);

    const created = await env.api('POST', '/admin/offers', {
      title: 'Diwali 20% off Pro', description: 'Festive', planTier: 'proRider', billingCycle: 'all',
      discountType: 'percentage', discountValue: 20, endsAt: Date.now() + 10 * DAY, showOnCheckout: true,
    }, A);
    assert.equal(created.status, 201, JSON.stringify(created.json));
    offerId = created.json.offer.id;
    assert.ok(offerId.startsWith('offer_'));
    assert.equal(created.json.offer.redemptions, 0);
    assert.equal(created.json.offer.isLive, true);

    // A hidden (showOnCheckout=false) and an inactive offer must not reach the public list
    const hidden = await env.api('POST', '/admin/offers', { title: 'Hidden fixed', discountType: 'fixed', discountValue: 5, planTier: 'proRider', showOnCheckout: false }, A);
    assert.equal(hidden.status, 201);
    const off = await env.api('POST', '/admin/offers', { title: 'Paused', discountType: 'fixed', discountValue: 100, planTier: 'proRider', isActive: false }, A);
    assert.equal(off.status, 201);

    const list = await env.api('GET', '/admin/offers', null, A);
    assert.equal(list.json.total, 3);

    const patched = await env.api('PATCH', `/admin/offers/${offerId}`, { title: 'Diwali 20% off CoRoute Pro' }, A);
    assert.equal(patched.status, 200);
    assert.equal(patched.json.offer.title, 'Diwali 20% off CoRoute Pro');
    assert.equal(patched.json.offer.discountValue, 20);
    const missing = await env.api('PATCH', '/admin/offers/offer_nope', { title: 'x' }, A);
    assert.equal(missing.status, 404);

    // There is no public offers listing any more: the app sees the applied offer in create-order's `offer`.
    const pub = await env.api('GET', '/subscription/offers', null, buyer.token);
    assert.equal(pub.status, 404);
  });

  let offerOrderId = '';
  await t.test('create-order applies the best live offer automatically (both paths); a coupon wins over the offer', async () => {
    const app = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly' }, buyer.token);
    assert.equal(app.status, 200, JSON.stringify(app.json));
    assert.equal(app.json.amount, 119); // 149 - 20% (30), the fixed ₹5 offer is hidden but live: 30 > 5
    assert.equal(app.json.amountInPaise, 11900);
    assert.deepEqual(app.json.offer, { id: offerId, title: 'Diwali 20% off CoRoute Pro', discountAmount: 30 });
    assert.equal(app.json.coupon, undefined);
    offerOrderId = app.json.orderId;
    const ledger = await repo.findRazorpayOrder(offerOrderId);
    assert.equal(ledger.offerId, offerId);
    assert.equal(ledger.discountAmount, 30);

    // Other tier: no offer
    const captain = await env.api('POST', '/subscription/create-order', { planTier: 'roadCaptain', billingCycle: 'monthly' }, buyer.token);
    assert.equal(captain.json.amount, 599);
    assert.equal(captain.json.offer, undefined);

    // Annual cycle
    const annual = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'annual' }, buyer.token);
    assert.equal(annual.status, 200, JSON.stringify(annual.json));
    assert.equal(annual.json.amountInPaise, Math.round(1199 * 0.8) * 100);
    assert.equal(annual.json.offer.id, offerId);
    assert.equal(annual.json.offer.discountAmount, Math.round(1199 * 0.2));

    // Coupon given: the coupon applies, the offer does not (no stacking)
    const withCoupon = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly', couponCode: 'WELCOME50' }, buyer.token);
    assert.equal(withCoupon.status, 200, JSON.stringify(withCoupon.json));
    assert.equal(withCoupon.json.amount, 74); // 149 - round(74.5) = 74
    assert.equal(withCoupon.json.coupon.code, 'WELCOME50');
    assert.equal(withCoupon.json.offer, undefined);
    const couponLedger = await repo.findRazorpayOrder(withCoupon.json.orderId);
    assert.equal(couponLedger.offerId, null);
  });

  await t.test('a verified redirect callback settles the offer order and counts one redemption', async () => {
    const paymentId = 'pay_offer_1';
    const form = new URLSearchParams({ razorpay_order_id: offerOrderId, razorpay_payment_id: paymentId, razorpay_signature: sign('unit_test_secret_456', offerOrderId, paymentId) });
    const res = await fetch(env.base + '/razorpay/callback', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: form, redirect: 'manual' });
    assert.equal(res.status, 303);
    assert.ok(res.headers.get('location').includes('paid=' + encodeURIComponent(offerOrderId)));
    const me = await env.api('GET', '/subscription/status', null, buyer.token);
    assert.equal(me.json.tier, 'proRider');
    const list = await env.api('GET', '/admin/offers', null, A);
    const offer = list.json.offers.find((o) => o.id === offerId);
    assert.equal(offer.redemptions, 1);
    // Replaying the callback does not count twice
    await fetch(env.base + '/razorpay/callback', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: form, redirect: 'manual' });
    const again = (await env.api('GET', '/admin/offers', null, A)).json.offers.find((o) => o.id === offerId);
    assert.equal(again.redemptions, 1);
    // Ledger / payments table carries the offer and the TEST flag
    const pay = await env.api('GET', `/admin/payments?userId=${buyer.user.userId}&status=PAID`, null, A);
    assert.equal(pay.json.payments.length, 1);
    assert.equal(pay.json.payments[0].offerId, offerId);
    assert.equal(pay.json.payments[0].isTest, true);
    assert.equal(pay.json.payments[0].discountAmount, 30);
    const paged = await env.api('GET', '/admin/payments?limit=1&offset=0', null, A);
    assert.equal(paged.json.payments.length, 1);
    assert.equal(paged.json.hasMore, true);
    const testOnly = await env.api('GET', '/admin/payments?mode=manual', null, A);
    assert.equal(testOnly.json.total, 0);
  });

  await t.test('sold-out and deleted offers stop applying', async () => {
    const capped = await env.api('PATCH', `/admin/offers/${offerId}`, { maxRedemptions: 1 }, A);
    assert.equal(capped.json.offer.isLive, false);
    const full = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly' }, buyer.token);
    assert.equal(full.json.amount, 144); // only the hidden ₹5 fixed offer remains
    assert.equal(full.json.offer.discountAmount, 5);
    const del = await env.api('DELETE', `/admin/offers/${offerId}`, null, A);
    assert.equal(del.status, 200);
    assert.equal((await env.api('DELETE', `/admin/offers/${offerId}`, null, A)).status, 404);
    assert.equal((await env.api('GET', '/admin/offers', null, A)).json.total, 2);
  });

  await t.test('pricing: annual must be >= monthly; every change is recorded in history', async () => {
    const bad = await env.api('PUT', '/admin/subscription/pricing', { plans: { proRider: { monthly: 500, annual: 400 } } }, A);
    assert.equal(bad.status, 400);
    assert.match(bad.json.error, /annual/);
    const before = await env.api('GET', '/admin/subscription/pricing', null, A);
    assert.equal(before.status, 200);
    assert.deepEqual(before.json.history, []);
    const ok = await env.api('PUT', '/admin/subscription/pricing', { plans: { proRider: { monthly: 179, annual: 1499 } } }, A);
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
    const ok2 = await env.api('PUT', '/admin/subscription/pricing', { plans: { roadCaptain: { monthly: 649 } } }, A);
    assert.equal(ok2.status, 200);
    const after = await env.api('GET', '/admin/subscription/pricing', null, A);
    assert.equal(after.json.isCustomized, true);
    assert.equal(after.json.history.length, 2);
    assert.equal(after.json.history[0].prices.roadCaptain.monthly, 649); // newest first
    assert.equal(after.json.history[1].prices.proRider.monthly, 179);
    assert.equal(after.json.history[0].by, 'admin@coroute.test');
    assert.ok(after.json.history[0].at >= after.json.history[1].at);
    assert.equal(after.json.updatedBy, 'admin@coroute.test');
  });
});

test('Payments hardening: refunds, failed payments, webhook dedupe, proration, scheduled downgrade, order expiry, audit, CSV, rate limit', async (t) => {
  const env = await boot();
  const refundCalls = [];
  setRazorpayFetch(async (url, opts = {}) => {
    const auth = Buffer.from(String(opts.headers?.Authorization || '').replace('Basic ', ''), 'base64').toString();
    const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
    if (opts.method === 'POST' && url.endsWith('/orders')) {
      const b = JSON.parse(opts.body);
      return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, receipt: b.receipt, status: 'created' });
    }
    const m = url.match(/\/payments\/([^/]+)\/refund$/);
    if (opts.method === 'POST' && m) {
      const b = JSON.parse(opts.body);
      refundCalls.push({ paymentId: decodeURIComponent(m[1]), amount: b.amount, auth, notes: b.notes });
      return reply(200, { id: `rfnd_${crypto.randomBytes(6).toString('hex')}`, entity: 'refund', payment_id: decodeURIComponent(m[1]), amount: b.amount, status: 'processed' });
    }
    if (opts.method === 'GET' && url.includes('/orders')) return reply(200, { items: [] });
    return reply(404, {});
  });
  t.after(() => { setRazorpayFetch(null); env.gw.shutdown(); });
  const DAY = 86400000;
  const repo = env.gw.repo;
  const SECRET = 'unit_test_secret_456';
  const admin = await env.register('HardAdmin', 'admin@coroute.test');
  const A = admin.token;
  const hook = (obj, eventId) => {
    const body = JSON.stringify(obj);
    const signature = crypto.createHmac('sha256', 'whsec_unit_789').update(body).digest('hex');
    return env.api('POST', '/subscription/webhook', body, null, { 'x-razorpay-signature': signature, ...(eventId ? { 'x-razorpay-event-id': eventId } : {}) });
  };
  /** Creates and pays (signed verify) an app order. */
  const buy = async (rider, planTier, billingCycle = 'monthly') => {
    const o = await env.api('POST', '/subscription/create-order', { planTier, billingCycle }, rider.token);
    assert.equal(o.status, 200, JSON.stringify(o.json));
    const paymentId = `pay_${crypto.randomBytes(5).toString('hex')}`;
    const v = await env.api('POST', '/subscription/verify-payment', { orderId: o.json.orderId, paymentId, signature: sign(SECRET, o.json.orderId, paymentId) }, rider.token);
    assert.equal(v.status, 200, JSON.stringify(v.json));
    return { orderId: o.json.orderId, paymentId, verify: v.json };
  };
  const tierOf = async (rider) => (await env.api('GET', '/subscription/status', null, rider.token)).json.tier;

  await t.test('admin refund: 403 for riders, 404 unknown, 400 for unpaid and manual orders', async () => {
    const r1 = await env.register('RefundCheck', 'refund.check@test.com');
    const created = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly' }, r1.token);
    const forbidden = await env.api('POST', `/admin/payments/${created.json.orderId}/refund`, { reason: 'x' }, r1.token);
    assert.equal(forbidden.status, 403);
    const notPaid = await env.api('POST', `/admin/payments/${created.json.orderId}/refund`, { reason: 'x' }, A);
    assert.equal(notPaid.status, 400);
    assert.equal((await env.api('POST', '/admin/payments/order_nope/refund', {}, A)).status, 404);
    const grant = await env.api('POST', `/admin/subscription/users/${r1.user.userId}/grant`, { planTier: 'proRider', days: 5 }, A);
    const manual = await env.api('POST', `/admin/payments/${grant.json.orderId}/refund`, {}, A);
    assert.equal(manual.status, 400);
    assert.equal(refundCalls.length, 0, 'Razorpay is never called for a refused refund');
  });

  await t.test('partial refund keeps the plan; refunding the rest is a full refund that revokes it', async () => {
    const r = await env.register('PartialRefund', 'partial.refund@test.com');
    const { orderId, paymentId } = await buy(r, 'roadCaptain'); // Rs 599
    assert.equal((await env.api('POST', `/admin/payments/${orderId}/refund`, { amountInPaise: 60000 }, A)).status, 400);
    assert.equal((await env.api('POST', `/admin/payments/${orderId}/refund`, { amountInPaise: 99 }, A)).status, 400);
    assert.equal((await env.api('POST', `/admin/payments/${orderId}/refund`, { amountInPaise: 100.5 }, A)).status, 400);
    const part = await env.api('POST', `/admin/payments/${orderId}/refund`, { amountInPaise: 20000, reason: 'late start' }, A);
    assert.equal(part.status, 200, JSON.stringify(part.json));
    assert.equal(part.json.refundStatus, 'PROCESSED');
    assert.equal(part.json.refundedAmount, 200);
    assert.equal(part.json.fullyRefunded, false);
    assert.equal(part.json.planRevoked, false);
    assert.ok(part.json.refundId.startsWith('rfnd_'));
    assert.equal(refundCalls.at(-1).paymentId, paymentId);
    assert.equal(refundCalls.at(-1).amount, 20000);
    assert.equal(refundCalls.at(-1).auth, 'rzp_test_unitKey123:unit_test_secret_456', 'refunded with the keys of the order mode');
    assert.equal(await tierOf(r), 'roadCaptain');
    const hist = await env.api('GET', '/subscription/history', null, r.token);
    const rec = hist.json.history.find((h) => h.orderId === orderId);
    assert.equal(rec.refundStatus, 'PROCESSED');
    assert.equal(rec.refundedAmount, 200);
    assert.equal(rec.refundReason, 'late start');
    const o = hist.json.orders.find((x) => x.orderId === orderId);
    assert.equal(o.refundedAmount, 200);
    assert.equal(o.refundStatus, 'PROCESSED');
    assert.equal(o.refundedBy, undefined, 'riders do not see which admin refunded');

    const rest = await env.api('POST', `/admin/payments/${orderId}/refund`, { reason: 'cancelled' }, A);
    assert.equal(rest.status, 200, JSON.stringify(rest.json));
    assert.equal(refundCalls.at(-1).amount, 39900, 'default amount is what is left');
    assert.equal(rest.json.fullyRefunded, true);
    assert.equal(rest.json.planRevoked, true);
    assert.equal(rest.json.refundedAmountInPaise, 59900);
    assert.equal(await tierOf(r), 'community');
    const d = await repo.findUserById(r.user.userId);
    assert.equal(d.subscriptionHistory.at(-1).reason, 'refunded');
    assert.equal(d.subscriptionHistory.at(-1).tier, 'roadCaptain');
    const again = await env.api('POST', `/admin/payments/${orderId}/refund`, {}, A);
    assert.equal(again.status, 400);
    assert.match(again.json.error, /fully refunded/);
  });

  await t.test('a full refund in one go revokes the plan with WS SUBSCRIPTION_REVOKED; the ledger shows it', async () => {
    const r = await env.register('FullRefund', 'full.refund@test.com');
    const { orderId } = await buy(r, 'proRider');
    const ws = await env.connect(r.token);
    const res = await env.api('POST', `/admin/payments/${orderId}/refund`, { reason: 'duplicate payment' }, A);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.equal(res.json.refundedAmountInPaise, 14900);
    assert.equal(res.json.planRevoked, true);
    const m = await ws.next((x) => x.type === 'SUBSCRIPTION_REVOKED');
    assert.equal(m.previousTier, 'proRider');
    ws.close();
    const pay = await env.api('GET', `/admin/payments?userId=${r.user.userId}`, null, A);
    assert.equal(pay.json.payments[0].fullyRefunded, true);
    assert.equal(pay.json.payments[0].refundReason, 'duplicate payment');
    assert.equal(pay.json.payments[0].refundedBy, 'admin@coroute.test');
    const ov = await env.api('GET', '/admin/subscription/overview', null, A);
    assert.ok(ov.json.refundedOrders >= 2);
    assert.ok(ov.json.refunds.testAllTime >= 599 + 149);
  });

  await t.test('webhook payment.failed marks the order FAILED with the reason; a later capture still activates', async () => {
    const r = await env.register('FailRider', 'fail.rider@test.com');
    const o = await env.api('POST', '/subscription/create-order', { planTier: 'proRider' }, r.token);
    const orderId = o.json.orderId;
    const failed = await hook({ event: 'payment.failed', payload: { payment: { entity: { id: 'pay_fail_1', order_id: orderId, status: 'failed', error_code: 'BAD_REQUEST_ERROR', error_description: 'Payment was declined by the bank', error_reason: 'payment_declined' } } } }, 'evt_fail_1');
    assert.equal(failed.status, 200);
    assert.equal(failed.json.handled, true);
    const ledger = await repo.findRazorpayOrder(orderId);
    assert.equal(ledger.status, 'FAILED');
    assert.equal(ledger.failureReason, 'Payment was declined by the bank');
    const pay = await env.api('GET', '/admin/payments?status=FAILED', null, A);
    assert.ok(pay.json.payments.some((p) => p.orderId === orderId && p.failureReason === 'Payment was declined by the bank'));
    assert.equal((await env.api('GET', '/admin/subscription/overview', null, A)).json.failedPayments, 1);
    const cap = await hook({ event: 'payment.captured', payload: { payment: { entity: { id: 'pay_ok_2', order_id: orderId, amount: 14900, method: 'upi' } } } }, 'evt_cap_2');
    assert.equal(cap.status, 200);
    assert.equal(await tierOf(r), 'proRider');
    await hook({ event: 'payment.failed', payload: { payment: { entity: { id: 'pay_fail_3', order_id: orderId, error_description: 'late' } } } }, 'evt_fail_3');
    assert.equal((await repo.findRazorpayOrder(orderId)).status, 'PAID', 'a failure event never undoes a capture');
  });

  await t.test('webhook: duplicate event ids are ignored; refund.processed is recorded once per refund; bodies over 1 MB are refused', async () => {
    const r = await env.register('HookRider', 'hook.rider@test.com');
    const { orderId, paymentId } = await buy(r, 'proRider');
    const refundEvt = { event: 'refund.processed', payload: { refund: { entity: { id: 'rfnd_dash_1', payment_id: paymentId, amount: 5000, status: 'processed', notes: { reason: 'goodwill' } } } } };
    const first = await hook(refundEvt, 'evt_refund_1');
    assert.equal(first.json.status, 'ok');
    assert.equal(first.json.handled, true);
    const dup = await hook(refundEvt, 'evt_refund_1');
    assert.equal(dup.status, 200);
    assert.equal(dup.json.status, 'duplicate');
    const ledger = await repo.findRazorpayOrder(orderId);
    assert.equal(ledger.refundStatus, 'PROCESSED');
    assert.equal(ledger.refundedAmount, 50);
    assert.equal(ledger.refundId, 'rfnd_dash_1');
    assert.equal(ledger.refundReason, 'goodwill');
    assert.ok(ledger.webhookEvents.includes('evt_refund_1'));
    await hook(refundEvt, 'evt_refund_1b'); // same refund, new delivery id
    assert.equal((await repo.findRazorpayOrder(orderId)).refundedAmount, 50);
    await hook({ event: 'refund.created', payload: { refund: { entity: { id: 'rfnd_dash_1', payment_id: paymentId, amount: 5000, status: 'pending' } } } }, 'evt_refund_1c');
    assert.equal((await repo.findRazorpayOrder(orderId)).refundStatus, 'PROCESSED', 'a processed refund never goes back to pending');
    assert.equal(await tierOf(r), 'proRider', 'a partial refund keeps the plan');
    const hist = await env.api('GET', '/subscription/history', null, r.token);
    assert.equal(hist.json.history.find((h) => h.orderId === orderId).refundedAmount, 50);

    // The ledger copy of the ids catches a redelivery the in-memory list no longer has (e.g. after a restart).
    const cur = await repo.findRazorpayOrder(orderId);
    await repo.updateRazorpayOrder(orderId, { webhookEvents: [...cur.webhookEvents, 'evt_before_restart'] });
    const old = await hook({ event: 'payment.captured', payload: { payment: { entity: { id: paymentId, order_id: orderId } } } }, 'evt_before_restart');
    assert.equal(old.json.status, 'duplicate');

    const unsigned = await env.api('POST', '/subscription/webhook', refundEvt, null, { 'x-razorpay-event-id': 'evt_refund_1' });
    assert.equal(unsigned.status, 400, 'the signature is checked before deduplication');

    const big = JSON.stringify({ event: 'payment.captured', pad: 'x'.repeat(1024 * 1024 + 10) });
    const tooBig = await env.api('POST', '/subscription/webhook', big, null, { 'x-razorpay-signature': crypto.createHmac('sha256', 'whsec_unit_789').update(big).digest('hex') });
    assert.equal(tooBig.status, 413);
  });

  await t.test('upgrade: the unused value of the running tier becomes extra days on the new tier (prorationCreditDays)', async () => {
    const r = await env.register('Upgrader', 'upgrader@test.com');
    await buy(r, 'proRider'); // Rs 149 / 30 days
    const before = await repo.findUserById(r.user.userId);
    const remainingMs = before.subscriptionValidUntil - Date.now();
    const up = await buy(r, 'roadCaptain'); // Rs 599 / 30 days
    const expected = ((remainingMs * (149 / (30 * DAY))) / (599 / (30 * DAY))) / DAY; // about 7.46 days
    assert.equal(up.verify.subscriptionTier, 'roadCaptain');
    assert.ok(Math.abs(up.verify.prorationCreditDays - expected) < 0.02, `${up.verify.prorationCreditDays} vs ${expected}`);
    const after = await repo.findUserById(r.user.userId);
    const rec = after.paymentHistory.at(-1);
    assert.equal(rec.prorationCreditDays, up.verify.prorationCreditDays);
    const days = (after.subscriptionValidUntil - Date.now()) / DAY;
    assert.ok(Math.abs(days - (30 + expected)) < 0.05, String(days));
    assert.equal((await repo.findRazorpayOrder(up.orderId)).prorationCreditDays, rec.prorationCreditDays);
    // Renewing the same tier extends from the current expiry, with no proration.
    const renew = await buy(r, 'roadCaptain');
    assert.equal(renew.verify.prorationCreditDays, 0);
    assert.ok(Math.abs(renew.verify.subscriptionValidUntil - (after.subscriptionValidUntil + 30 * DAY)) < 1000);
  });

  await t.test('create-order is limited to 10 per minute per rider (429); other riders are not affected', async () => {
    const r = await env.register('Spammer', 'spammer@test.com');
    const codes = [];
    for (let i = 0; i < 11; i++) codes.push((await env.api('POST', '/subscription/create-order', { planTier: 'proRider' }, r.token)).status);
    assert.deepEqual(codes.slice(0, 10), Array(10).fill(200));
    assert.equal(codes[10], 429);
    const other = await env.register('NotSpammer', 'not.spammer@test.com');
    assert.equal((await env.api('POST', '/subscription/create-order', { planTier: 'proRider' }, other.token)).status, 200);
  });

  await t.test('every admin write is in the audit trail, newest first; no response carries a secret', async () => {
    await env.api('PUT', '/admin/subscription/pricing', { plans: { tourOperator: { monthly: 2099, annual: 15999 } } }, A);
    await env.api('POST', '/admin/coupons', { code: 'AUDIT10', discountType: 'percentage', discountValue: 10 }, A);
    await env.api('PATCH', '/admin/coupons/AUDIT10', { isActive: false }, A);
    await env.api('DELETE', '/admin/coupons/AUDIT10', null, A);
    const offer = await env.api('POST', '/admin/offers', { title: 'Audit offer', discountValue: 5, discountType: 'fixed', planTier: 'tourOperator' }, A);
    await env.api('PATCH', `/admin/offers/${offer.json.offer.id}`, { title: 'Audit offer 2' }, A);
    await env.api('DELETE', `/admin/offers/${offer.json.offer.id}`, null, A);
    const gw = await env.api('PUT', '/admin/payment-gateway', { test: { keySecret: SECRET, webhookSecret: 'whsec_unit_789' } }, A);
    assert.equal(gw.status, 200, JSON.stringify(gw.json));
    const r = await env.register('AuditRider', 'audit.rider@test.com');
    await env.api('POST', `/admin/subscription/users/${r.user.userId}/grant`, { planTier: 'proRider', days: 3, reason: 'audit' }, A);
    await env.api('POST', `/admin/subscription/users/${r.user.userId}/revoke`, { reason: 'audit' }, A);

    const res = await env.api('GET', '/admin/audit?limit=500', null, A);
    assert.equal(res.status, 200);
    const actions = res.json.entries.map((e) => e.action);
    for (const a of ['pricing.update', 'coupon.create', 'coupon.update', 'coupon.delete', 'offer.create', 'offer.update', 'offer.delete',
      'gateway.update', 'subscription.grant', 'subscription.revoke', 'payment.refund']) {
      assert.ok(actions.includes(a), a);
    }
    const ats = res.json.entries.map((e) => e.at);
    assert.deepEqual(ats, [...ats].sort((x, y) => y - x), 'newest first');
    const revoke = res.json.entries.find((e) => e.action === 'subscription.revoke');
    assert.equal(revoke.by, 'admin@coroute.test');
    assert.equal(revoke.target, r.user.userId);
    assert.equal(revoke.details.reason, 'audit');
    const refund = res.json.entries.find((e) => e.action === 'payment.refund');
    assert.ok(refund.target.startsWith('order_') && refund.details.amountInPaise > 0);
    const gwEntry = res.json.entries.find((e) => e.action === 'gateway.update');
    assert.equal(gwEntry.details.test.keySecretChanged, true);
    assert.equal((await env.api('GET', '/admin/audit?limit=1', null, A)).json.entries.length, 1);
    assert.equal((await env.api('GET', '/admin/audit?action=coupon', null, A)).json.entries.length, 3);
    assert.equal((await env.api('GET', '/admin/audit', null, r.token)).status, 403);

    for (const [path, tok] of [['/admin/audit?limit=1000', A], ['/admin/payment-gateway', A], ['/admin/payments?limit=1000', A],
      ['/admin/subscription/overview', A], [`/admin/payments/users/${r.user.userId}`, A], ['/subscription/config', r.token], ['/subscription/history', r.token]]) {
      const x = await env.api('GET', path, null, tok);
      assert.equal(x.status, 200, path);
      const text = JSON.stringify(x.json);
      assert.ok(!text.includes(SECRET) && !text.includes('whsec_unit_789'), `${path}: secret value`);
      assert.ok(!/"keySecret"|"webhookSecret"|SecretEnc"/.test(text), `${path}: secret field`);
    }
  });

  await t.test('ledger CSV export: headers, one row per order, from/to filter, admin only', async () => {
    const get = (q, tok = A) => fetch(`${env.base}/admin/payments/export.csv${q}`, { headers: { Authorization: `Bearer ${tok}` } });
    const res = await get('');
    assert.equal(res.status, 200);
    assert.match(res.headers.get('content-type'), /text\/csv/);
    assert.match(res.headers.get('content-disposition'), /attachment; filename="coroute-payments-\d{4}-\d{2}-\d{2}\.csv"/);
    const text = await res.text();
    assert.ok(!text.includes(SECRET));
    const lines = text.trim().split('\r\n');
    assert.equal(lines[0], 'orderId,userId,email,planTier,billingCycle,amount,mode,status,paymentId,refundStatus,refundedAmount,offerId,couponCode,createdAt,paidAt');
    const all = await env.api('GET', '/admin/payments?limit=1000', null, A);
    assert.equal(lines.length - 1, all.json.total);
    assert.ok(lines.some((l) => l.includes('"full.refund@test.com"') && l.includes('"PROCESSED"') && l.includes(',149,')));
    const future = await get(`?from=${Date.now() + DAY}`);
    assert.equal((await future.text()).trim().split('\r\n').length, 1);
    const past = await get(`?to=${Date.now() - DAY}`);
    assert.equal((await past.text()).trim().split('\r\n').length, 1);
    assert.equal((await get('?from=not-a-date')).status, 400);
    const rider = await env.register('CsvRider', 'csv.rider@test.com');
    assert.equal((await get('', rider.token)).status, 403);
  });

  await t.test('order expiry: the sweeper marks CREATED orders older than 24 h EXPIRED; a valid signature still activates (logged)', async () => {
    const r = await env.register('LatePayer', 'late.payer@test.com');
    const o = await env.api('POST', '/subscription/create-order', { planTier: 'proRider' }, r.token);
    const orderId = o.json.orderId;
    await env.gw.subscriptions.runOnce(Date.now());
    assert.equal((await repo.findRazorpayOrder(orderId)).status, 'CREATED');
    const stats = await env.gw.subscriptions.runOnce(Date.now() + 25 * 3600000);
    assert.ok(stats.ordersExpired >= 1, JSON.stringify(stats));
    assert.equal((await repo.findRazorpayOrder(orderId)).status, 'EXPIRED');
    const pay = await env.api('GET', `/admin/payments?status=EXPIRED&userId=${r.user.userId}`, null, A);
    assert.equal(pay.json.payments.length, 1);
    assert.ok(pay.json.payments[0].expiredAt > 0);
    const warn = console.warn;
    const logged = [];
    console.warn = (...a) => logged.push(a.join(' '));
    try {
      const v = await env.api('POST', '/subscription/verify-payment', { orderId, paymentId: 'pay_late', signature: sign(SECRET, orderId, 'pay_late') }, r.token);
      assert.equal(v.status, 200, JSON.stringify(v.json));
    } finally {
      console.warn = warn;
    }
    assert.ok(logged.some((l) => l.includes(orderId) && l.includes('EXPIRED')), 'the late payment is logged');
    const ledger = await repo.findRazorpayOrder(orderId);
    assert.equal(ledger.status, 'PAID');
    assert.equal(ledger.paidAfterExpiry, true);
    assert.equal(await tierOf(r), 'proRider');
  });

  await t.test('a downgrade while a dearer tier runs is scheduled; the sweeper starts it when the current tier ends', async () => {
    const r = await env.register('Downgrader', 'downgrader@test.com');
    await buy(r, 'roadCaptain');
    const cur = await repo.findUserById(r.user.userId);
    const down = await buy(r, 'proRider');
    assert.equal(down.verify.subscriptionTier, 'roadCaptain');
    assert.equal(down.verify.scheduledTier, 'proRider');
    assert.equal(down.verify.scheduledStartsAt, cur.subscriptionValidUntil);
    assert.equal(down.verify.scheduledValidUntil, cur.subscriptionValidUntil + 30 * DAY);
    const mid = await repo.findUserById(r.user.userId);
    assert.equal(mid.subscriptionTier, 'roadCaptain');
    assert.equal(mid.subscriptionValidUntil, cur.subscriptionValidUntil);
    assert.equal(mid.pendingTier.tier, 'proRider');
    assert.equal(mid.pendingTier.startsAt, cur.subscriptionValidUntil);
    assert.equal(await tierOf(r), 'roadCaptain');
    assert.equal((await repo.findRazorpayOrder(down.orderId)).scheduledStartsAt, cur.subscriptionValidUntil);

    const stats = await env.gw.subscriptions.runOnce(cur.subscriptionValidUntil + 3600000);
    assert.ok(stats.scheduledStarted >= 1, JSON.stringify(stats));
    const after = await repo.findUserById(r.user.userId);
    assert.equal(after.subscriptionTier, 'proRider');
    assert.equal(after.subscriptionValidUntil, cur.subscriptionValidUntil + 30 * DAY);
    assert.equal(after.pendingTier, null);
    assert.equal(after.subscriptionHistory.at(-1).reason, 'scheduled');
    assert.equal(after.subscriptionHistory.at(-2).reason, 'expired');
    assert.equal(after.subscriptionHistory.at(-2).tier, 'roadCaptain');
  });
});
