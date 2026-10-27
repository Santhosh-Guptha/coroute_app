'use strict';
const crypto = require('crypto');

async function runLiveVerification() {
  const base = 'https://coroute.duckdns.org';
  console.log('=== VERIFYING LIVE PRODUCTION DEPLOYMENT AT ' + base + ' ===\n');

  // 1. Config
  const cfgRes = await fetch(base + '/api/subscription/config');
  const cfg = await cfgRes.json();
  console.log('1. Config Status:', cfgRes.status, '| Razorpay Key ID:', cfg.razorpayKeyId, '| Plans:', Object.keys(cfg.plans || {}));
  if (cfg.razorpayKeyId !== 'rzp_test_TstfWWwQUC19Pv') throw new Error('Key ID mismatch');

  // 2. Validate Coupon WELCOME50
  const c1Res = await fetch(base + '/api/subscription/validate-coupon', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code: 'WELCOME50', planTier: 'proRider', amount: 149 })
  });
  const c1 = await c1Res.json();
  console.log('2. WELCOME50 Validation:', c1Res.status, '| Valid:', c1.valid, '| Discount:', c1.discountAmount, '| Final:', c1.finalAmount);
  if (!c1.valid || c1.finalAmount !== 74) throw new Error('WELCOME50 validation failed');

  // 3. Validate Coupon CAPTAIN100
  const c2Res = await fetch(base + '/api/subscription/validate-coupon', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code: 'CAPTAIN100', planTier: 'roadCaptain', amount: 599 })
  });
  const c2 = await c2Res.json();
  console.log('3. CAPTAIN100 Validation:', c2Res.status, '| Valid:', c2.valid, '| Discount:', c2.discountAmount, '| Final:', c2.finalAmount);
  if (!c2.valid || c2.finalAmount !== 499) throw new Error('CAPTAIN100 validation failed');

  // 4. Validate Coupon RIDERFREE
  const c3Res = await fetch(base + '/api/subscription/validate-coupon', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code: 'RIDERFREE', planTier: 'proRider', billingCycle: 'monthly', amount: 149 })
  });
  const c3 = await c3Res.json();
  console.log('4. RIDERFREE Validation:', c3Res.status, '| Valid:', c3.valid, '| isFree:', c3.isFree, '| Final:', c3.finalAmount);
  if (!c3.valid || !c3.isFree) throw new Error('RIDERFREE validation failed');

  // 5. Create Order with amount < 100 paise (should fail with 400)
  const badOrderRes = await fetch(base + '/api/create-order', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ amount: 50, currency: 'INR' })
  });
  const badOrder = await badOrderRes.json();
  console.log('5. Minimum Amount Check (<100 paise): Status:', badOrderRes.status, '| Error:', badOrder.error);
  if (badOrderRes.status !== 400) throw new Error('Minimum amount check failed');

  // 6. Create Order with Standard Amount (14900 paise)
  const orderRes = await fetch(base + '/api/create-order', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ amount: 14900, currency: 'INR', receipt: 'rcpt_test_live_01', simulate_test: true })
  });
  const order = await orderRes.json();
  console.log('6. Create Order (14900 paise): Status:', orderRes.status, '| Order ID:', order.order_id, '| Amount:', order.amount);
  if (!order.order_id) throw new Error('Order creation failed');

  // 7. Verify Signature with Mismatched Signature (should return 400)
  const badVerifyRes = await fetch(base + '/api/verify-payment', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      order_id: order.order_id,
      payment_id: 'pay_test_live_mismatch',
      razorpay_signature: 'bad_signature_12345'
    })
  });
  console.log('7. Signature Mismatch Check: Status:', badVerifyRes.status);
  if (badVerifyRes.status !== 400) throw new Error('Signature mismatch check failed');

  // 8. Verify Payment with Valid HMAC-SHA256 Signature
  const keySecret = 'JXXsWsUF1z2XX3CREz4k10Ix';
  const testPaymentId = 'pay_test_' + Date.now();
  const validSignature = crypto.createHmac('sha256', keySecret)
    .update(order.order_id + '|' + testPaymentId)
    .digest('hex');

  const verifyRes = await fetch(base + '/api/verify-payment', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      order_id: order.order_id,
      payment_id: testPaymentId,
      razorpay_signature: validSignature,
      coupon_code: 'WELCOME50'
    })
  });
  const verifyData = await verifyRes.json();
  console.log('8. Valid Payment Verification: Status:', verifyRes.status, '| Success:', verifyData.success, '| Message:', verifyData.message);
  if (!verifyData.success) throw new Error('Valid payment verification failed');

  // 9. Free Coupon Order Creation & Verification
  const freeOrderRes = await fetch(base + '/api/create-order', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      amount: 14900,
      currency: 'INR',
      coupon_code: 'RIDERFREE',
      planTier: 'proRider',
      billingCycle: 'monthly'
    })
  });
  const freeOrder = await freeOrderRes.json();
  console.log('9. Free Coupon Order: Status:', freeOrderRes.status, '| Order ID:', freeOrder.order_id, '| isFree:', freeOrder.is_free);
  if (!freeOrder.is_free) throw new Error('Free order creation failed: ' + JSON.stringify(freeOrder));

  const freeVerifyRes = await fetch(base + '/api/verify-payment', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      order_id: freeOrder.order_id,
      coupon_code: 'RIDERFREE',
      planTier: 'proRider',
      billingCycle: 'monthly',
      is_free: true
    })
  });
  const freeVerify = await freeVerifyRes.json();
  console.log('10. Free Coupon Verification: Status:', freeVerifyRes.status, '| Success:', freeVerify.success, '| isFree:', freeVerify.is_free);
  if (!freeVerify.success) throw new Error('Free payment verification failed: ' + JSON.stringify(freeVerify));

  console.log('\n================================================================');
  console.log('SUCCESS: ALL 10 LIVE PRODUCTION TESTS PASSED WITH 100% ACCURACY!');
  console.log('================================================================');
}

runLiveVerification().catch(err => {
  console.error('\nVerification failed:', err);
  process.exit(1);
});
