'use strict';
process.env.NODE_ENV = 'test';
process.env.RAZORPAY_KEY_ID = 'rzp_test_sample_123';
process.env.RAZORPAY_KEY_SECRET = 'rzp_secret_sample_456';
process.env.RAZORPAY_WEBHOOK_SECRET = 'whsec_sample_789';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { boot } = require('./_helpers');

test('Subscription Razorpay UPI Payment Suite', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());

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

  await t.test('GET /api/subscription/config returns Razorpay UPI-only configuration', async () => {
    const res = await env.api('GET', '/subscription/config', null, riderToken);
    assert.equal(res.status, 200);
    assert.equal(res.json.upiOnly, true);
    assert.deepEqual(res.json.allowedMethods, ['upi']);
    assert.equal(res.json.razorpayKeyId, 'rzp_test_sample_123');
    assert.ok(res.json.upiVpa);
    assert.ok(res.json.plans.roadCaptain);
    assert.equal(res.json.plans.roadCaptain.monthly, 599);
  });

  let orderData = null;

  await t.test('POST /api/subscription/create-order creates UPI order and intent URI', async () => {
    const res = await env.api('POST', '/subscription/create-order', {
      planTier: 'roadCaptain',
      billingCycle: 'monthly',
    }, riderToken);

    assert.equal(res.status, 200);
    orderData = res.json;
    assert.ok(orderData.orderId.startsWith('order_') || orderData.orderId.startsWith('ORD_'));
    assert.equal(orderData.amount, 599);
    assert.equal(orderData.amountInPaise, 59900);
    assert.equal(orderData.planTier, 'roadCaptain');
    assert.equal(orderData.billingCycle, 'monthly');
    assert.ok(orderData.upiUri.startsWith('upi://pay?'));
    assert.equal(orderData.razorpayOptions.method.upi, true);
    assert.equal(orderData.razorpayOptions.method.card, false);
    assert.equal(orderData.razorpayOptions.method.netbanking, false);
  });

  await t.test('POST /api/subscription/verify-payment activates Road Captain tier in DB and notifies via WS', async () => {
    const ws = await env.connect(riderToken);

    const paymentId = 'pay_test_upi_12345';
    const sig = crypto.createHmac('sha256', process.env.RAZORPAY_KEY_SECRET)
      .update(`${orderData.orderId}|${paymentId}`)
      .digest('hex');

    // Start waiting for the WebSocket notification before triggering the verify request
    const pActivated = ws.next((m) => m.type === 'SUBSCRIPTION_ACTIVATED', 2000);

    const res = await env.api('POST', '/subscription/verify-payment', {
      orderId: orderData.orderId,
      planTier: 'roadCaptain',
      billingCycle: 'monthly',
      paymentId,
      signature: sig,
      utr: '123456789012',
    }, riderToken);

    assert.equal(res.status, 200);
    assert.equal(res.json.success, true);
    assert.equal(res.json.subscriptionTier, 'roadCaptain');
    assert.ok(res.json.subscriptionValidUntil > Date.now());

    // Verify /me now reflects Road Captain
    const me = await env.api('GET', '/me', null, riderToken);
    assert.equal(me.json.subscriptionTier, 'roadCaptain');

    // Verify status endpoint
    const status = await env.api('GET', '/subscription/status', null, riderToken);
    assert.equal(status.status, 200);
    assert.equal(status.json.tier, 'roadCaptain');
    assert.equal(status.json.isActive, true);
    assert.ok(status.json.daysRemaining >= 29);
    assert.equal(status.json.paymentHistoryCount, 1);
    assert.equal(status.json.lastPayment.orderId, orderData.orderId);
    assert.equal(status.json.lastPayment.utr, '123456789012');

    // Verify /subscription/history endpoint
    const historyRes = await env.api('GET', '/subscription/history', null, riderToken);
    assert.equal(historyRes.status, 200);
    assert.equal(historyRes.json.totalPayments, 1);
    assert.equal(historyRes.json.history[0].orderId, orderData.orderId);
    assert.equal(historyRes.json.history[0].utr, '123456789012');
    assert.equal(historyRes.json.history[0].paymentId, paymentId);
    assert.equal(historyRes.json.history[0].method, 'UPI');
    assert.equal(historyRes.json.history[0].userSnapshot.userId, riderUser.userId);

    // Verify WebSocket event
    const activated = await pActivated;
    assert.ok(activated);
    assert.equal(activated.tier, 'roadCaptain');

    ws.close();
  });

  await t.test('POST /api/subscription/webhook handles Razorpay server webhook securely with HMAC check', async () => {
    const reg2 = await env.register('ProRider2', 'pro2@test.com');
    const token2 = reg2.token;
    const userId2 = reg2.user.userId;

    const payloadObj = {
      event: 'payment.captured',
      payload: {
        payment: {
          entity: {
            id: 'pay_rzp_webhook_999',
            order_id: 'ORD_WEBHOOK_123',
            amount: 14900,
            notes: {
              userId: userId2,
              planTier: 'proRider',
              billingCycle: 'monthly',
            },
          },
        },
      },
    };
    const webhookPayload = JSON.stringify(payloadObj);

    const signature = crypto.createHmac('sha256', process.env.RAZORPAY_WEBHOOK_SECRET)
      .update(webhookPayload)
      .digest('hex');

    const hookRes = await env.api('POST', '/subscription/webhook', payloadObj, null, {
      'x-razorpay-signature': signature,
    });

    assert.equal(hookRes.status, 200);

    // Verify user2 got upgraded to proRider via webhook
    const me2 = await env.api('GET', '/me', null, token2);
    assert.equal(me2.json.subscriptionTier, 'proRider');
    assert.ok(me2.json.subscriptionValidUntil > Date.now());
  });

  await t.test('POST /api/create-order validates minimum amount >= 100 paise', async () => {
    // 0 paise -> 400
    const res0 = await env.api('POST', '/create-order', { amount: 0 });
    assert.equal(res0.status, 400);
    assert.ok(res0.json.error.includes('100 paise'));

    // 99 paise -> 400
    const res99 = await env.api('POST', '/create-order', { amount: 99 });
    assert.equal(res99.status, 400);
  });

  await t.test('POST /api/verify-payment validates missing fields', async () => {
    // Missing payment_id & signature -> 400
    const res = await env.api('POST', '/verify-payment', {
      order_id: 'order_12345',
    });
    assert.equal(res.status, 400);
    assert.ok(res.json.error.includes('required'));
  });

  await t.test('POST /api/verify-payment rejects signature mismatch (returns 400)', async () => {
    const res = await env.api('POST', '/verify-payment', {
      order_id: 'order_test_999',
      payment_id: 'pay_test_888',
      signature: 'invalid_sha256_hex_signature',
    });
    assert.equal(res.status, 400);
    assert.equal(res.json.success, false);
    assert.ok(res.json.error.includes('Signature verification failed'));
  });

  await t.test('POST /api/verify-payment verifies valid HMAC-SHA256 signature and returns success', async () => {
    const orderId = 'order_test_verified_123';
    const paymentId = 'pay_test_verified_456';
    const validSignature = crypto.createHmac('sha256', process.env.RAZORPAY_KEY_SECRET)
      .update(`${orderId}|${paymentId}`)
      .digest('hex');

    const res = await env.api('POST', '/verify-payment', {
      razorpay_order_id: orderId,
      razorpay_payment_id: paymentId,
      razorpay_signature: validSignature,
    });

    assert.equal(res.status, 200);
    assert.equal(res.json.success, true);
    assert.equal(res.json.message, 'Payment verified successfully');
    assert.equal(res.json.order_id, orderId);
    assert.equal(res.json.payment_id, paymentId);
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
    const adminReg = await env.register('Site Admin', 'admin@coroute.test');
    const adminToken = adminReg.token;

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
