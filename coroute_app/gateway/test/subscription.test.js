'use strict';
process.env.NODE_ENV = 'test';
process.env.RAZORPAY_KEY_ID = 'rzp_test_sample_123';
process.env.RAZORPAY_KEY_SECRET = 'rzp_secret_sample_456';
process.env.RAZORPAY_WEBHOOK_SECRET = 'whsec_sample_789';

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
    assert.ok(orderData.orderId.startsWith('ORD_'));
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
});
