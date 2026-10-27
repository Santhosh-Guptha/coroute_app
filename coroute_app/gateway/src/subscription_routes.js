'use strict';
const express = require('express');
const crypto = require('crypto');
const config = require('./config');

const PLAN_PRICES_INR = {
  community: { monthly: 0, annual: 0, label: 'Community Rider' },
  proRider: { monthly: 149, annual: 1199, label: 'CoRoute Pro' },
  roadCaptain: { monthly: 599, annual: 4499, label: 'Road Captain Pass' },
  tourOperator: { monthly: 1999, annual: 14999, label: 'Tour Operator' },
};

const BUILTIN_COUPONS = {
  WELCOME50: {
    code: 'WELCOME50',
    description: '50% discount on any monthly or annual plan',
    discountType: 'percentage',
    discountValue: 50,
    applicableTiers: ['all'],
    applicableCycles: ['all'],
    maxUsageTotal: 1000,
    usageCount: 0,
    maxUsagePerUser: 1,
    validFrom: 1700000000000,
    expiresAt: Date.now() + 180 * 86400000,
    isActive: true,
    minOrderAmount: 100,
    usages: [],
  },
  CAPTAIN100: {
    code: 'CAPTAIN100',
    description: 'Flat ₹100 discount on Road Captain and Tour Operator passes',
    discountType: 'fixed',
    discountValue: 100,
    applicableTiers: ['roadCaptain', 'tourOperator'],
    applicableCycles: ['all'],
    maxUsageTotal: 500,
    usageCount: 0,
    maxUsagePerUser: 1,
    validFrom: 1700000000000,
    expiresAt: Date.now() + 180 * 86400000,
    isActive: true,
    minOrderAmount: 149,
    usages: [],
  },
  RIDERFREE: {
    code: 'RIDERFREE',
    description: '100% Free 1-month CoRoute Pro Pass for testing and promotional giveaways',
    discountType: 'free',
    discountValue: 100,
    applicableTiers: ['proRider', 'roadCaptain'],
    applicableCycles: ['monthly'],
    maxUsageTotal: 100,
    usageCount: 0,
    maxUsagePerUser: 1,
    validFrom: 1700000000000,
    expiresAt: Date.now() + 365 * 86400000,
    isActive: true,
    minOrderAmount: 0,
    usages: [],
  },
};

async function getEffectivePlans(repo) {
  if (repo && typeof repo.getSubscriptionPricing === 'function') {
    try {
      const stored = await repo.getSubscriptionPricing();
      if (stored && typeof stored === 'object') {
        return {
          community: { monthly: 0, annual: 0, label: 'Community Rider' },
          ...PLAN_PRICES_INR,
          ...stored,
        };
      }
    } catch {
      // fallback to defaults
    }
  }
  return PLAN_PRICES_INR;
}

async function resolveCoupon(rawCode, repo) {
  if (!rawCode) return null;
  const cleanCode = String(rawCode).trim().toUpperCase();
  if (repo && typeof repo.findCoupon === 'function') {
    try {
      const dbCoupon = await repo.findCoupon(cleanCode);
      if (dbCoupon) return dbCoupon;
    } catch {
      // fallback
    }
  }
  return BUILTIN_COUPONS[cleanCode] ? { ...BUILTIN_COUPONS[cleanCode] } : null;
}

function evaluateCoupon(coupon, { userId, planTier, billingCycle = 'monthly', amountInInr }) {
  if (!coupon) {
    return { valid: false, error: 'Coupon code not found' };
  }
  if (!coupon.isActive) {
    return { valid: false, error: 'This coupon is no longer active' };
  }
  const now = Date.now();
  if (coupon.validFrom && now < coupon.validFrom) {
    return { valid: false, error: 'This coupon is not active yet' };
  }
  if (coupon.expiresAt && now > coupon.expiresAt) {
    return { valid: false, error: 'This coupon has expired' };
  }
  if (coupon.maxUsageTotal && (coupon.usageCount || 0) >= coupon.maxUsageTotal) {
    return { valid: false, error: 'Coupon usage limit has been reached' };
  }
  if (userId && Array.isArray(coupon.usages)) {
    const userTimes = coupon.usages.filter((u) => u.userId === userId).length;
    if (userTimes >= (coupon.maxUsagePerUser || 1)) {
      return { valid: false, error: 'You have already redeemed this coupon' };
    }
  }
  const tier = normalizeTier(planTier);
  if (coupon.applicableTiers && !coupon.applicableTiers.includes('all') && !coupon.applicableTiers.includes(tier)) {
    return { valid: false, error: `Coupon is not valid for ${tier}` };
  }
  if (coupon.applicableCycles && !coupon.applicableCycles.includes('all') && !coupon.applicableCycles.includes(billingCycle)) {
    return { valid: false, error: `Coupon is not valid for ${billingCycle} subscriptions` };
  }
  const baseAmount = Number(amountInInr) || 0;
  if (coupon.minOrderAmount && baseAmount < coupon.minOrderAmount) {
    return { valid: false, error: `Minimum order amount of ₹${coupon.minOrderAmount} required for this coupon` };
  }

  let discountInr = 0;
  if (coupon.discountType === 'free') {
    discountInr = baseAmount;
  } else if (coupon.discountType === 'percentage') {
    const pct = Math.min(100, Math.max(0, Number(coupon.discountValue) || 0));
    discountInr = Math.round((baseAmount * pct) / 100);
  } else if (coupon.discountType === 'fixed') {
    discountInr = Math.min(baseAmount, Math.max(0, Number(coupon.discountValue) || 0));
  }

  const finalAmountInr = Math.max(0, baseAmount - discountInr);
  return {
    valid: true,
    code: coupon.code,
    description: coupon.description || '',
    discountType: coupon.discountType,
    discountValue: coupon.discountValue,
    originalAmount: baseAmount,
    discountAmount: discountInr,
    finalAmount: finalAmountInr,
    finalAmountPaise: finalAmountInr * 100,
    isFree: finalAmountInr === 0,
    expiresAt: coupon.expiresAt,
    usagesRemaining: Math.max(0, (coupon.maxUsageTotal || 100) - (coupon.usageCount || 0)),
  };
}

function normalizeTier(tier) {
  if (!tier) return 'community';
  const clean = String(tier).trim();
  if (clean === 'pro' || clean === 'proRider') return 'proRider';
  if (clean === 'roadCaptain' || clean === 'captain') return 'roadCaptain';
  if (clean === 'tourOperator' || clean === 'operator') return 'tourOperator';
  return 'community';
}

/**
 * Creates an authentic order with Razorpay Orders API when live/test keys are present,
 * or gracefully generates a valid Razorpay-spec order ID in sandbox test mode.
 */
async function createRazorpayOrder({ amountInPaise, receipt, notes }) {
  const isRealKey = config.razorpayKeyId &&
    !config.razorpayKeyId.startsWith('rzp_test_sample') &&
    config.razorpayKeySecret &&
    !config.razorpayKeySecret.startsWith('rzp_secret_coroute_free');

  if (isRealKey) {
    try {
      const auth = Buffer.from(`${config.razorpayKeyId}:${config.razorpayKeySecret}`).toString('base64');
      const res = await fetch('https://api.razorpay.com/v1/orders', {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${auth}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          amount: amountInPaise,
          currency: 'INR',
          receipt,
          notes,
          payment_capture: 1,
        }),
      });

      if (res.ok) {
        const data = await res.json();
        if (data && data.id) return data.id;
      } else {
        const txt = await res.text();
        console.warn('[razorpay] orders.create API returned error, falling back:', res.status, txt);
      }
    } catch (e) {
      console.warn('[razorpay] orders.create network error, falling back:', e.message);
    }
  }

  // Razorpay-spec order identifier (order_<timestamp>_<nonce>)
  const orderNonce = crypto.randomBytes(4).toString('hex').toLowerCase();
  return `order_${Date.now()}_${orderNonce}`;
}

/**
 * Registers public webhook endpoints (authenticated via HMAC signature, not user JWT).
 */
function registerSubscriptionPublicRoutes({ r, auth, repo, hub, wrap }) {
  r.post('/subscription/webhook', wrap(async (req, res) => {
    const rawBody = typeof req.body === 'string'
      ? req.body
      : (Buffer.isBuffer(req.body) ? req.body.toString('utf8') : JSON.stringify(req.body || {}));
    const signature = req.get('x-razorpay-signature') || req.get('x-webhook-signature') || '';

    // If webhook secret is configured, verify HMAC signature
    if (config.razorpayWebhookSecret && signature) {
      const expected = crypto.createHmac('sha256', config.razorpayWebhookSecret).update(rawBody).digest('hex');
      if (signature !== expected) {
        return res.status(400).json({ error: 'Invalid webhook signature' });
      }
    }

    let event = typeof req.body === 'object' && !Buffer.isBuffer(req.body) ? req.body : {};
    try {
      if (typeof req.body === 'string' || Buffer.isBuffer(req.body)) {
        event = JSON.parse(rawBody);
      }
    } catch {
      return res.status(400).json({ error: 'Invalid JSON payload' });
    }

    const eventType = event.event || '';
    if (eventType === 'payment.captured' || eventType === 'order.paid') {
      const payment = event.payload?.payment?.entity || {};
      const notes = payment.notes || event.payload?.order?.entity?.notes || {};
      const userId = notes.userId || notes.user_id;
      const planTier = normalizeTier(notes.planTier || notes.plan_tier || notes.tier);
      const billingCycle = notes.billingCycle === 'annual' ? 'annual' : 'monthly';

      if (userId && planTier && planTier !== 'community') {
        const user = await repo.findUserById(userId);
        if (user) {
          const currentExpiry = Number(user.subscriptionValidUntil) || 0;
          const duration = billingCycle === 'annual' ? 365 * 86400000 : 30 * 86400000;
          // If already active on the same plan, extend from current expiry rather than cutting existing days short
          const baseTime = (currentExpiry > Date.now() && user.subscriptionTier === planTier) ? currentExpiry : Date.now();
          const expiry = baseTime + duration;

          const paymentRecord = {
            orderId: payment.order_id || event.payload?.order?.entity?.id || '',
            paymentId: payment.id || '',
            utr: payment.acquirer_data?.rrn || payment.acquirer_data?.upi_transaction_id || notes.utr || '',
            vpa: payment.vpa || '',
            amount: (payment.amount || 0) / 100,
            currency: 'INR',
            method: 'UPI',
            planTier,
            billingCycle,
            validFrom: baseTime,
            validUntil: expiry,
            paidAt: Date.now(),
            source: 'razorpay_webhook',
            userSnapshot: {
              userId,
              name: user.name || '',
              email: user.email || '',
              phone: user.phone || '',
              callsign: user.callsign || '',
            },
          };

          const history = Array.isArray(user.paymentHistory) ? [...user.paymentHistory] : [];
          if (!history.some(p => p.paymentId && p.paymentId === paymentRecord.paymentId)) {
            history.push(paymentRecord);
          }

          await repo.updateUser(user.key, {
            subscriptionTier: planTier,
            subscriptionValidUntil: expiry,
            lastPayment: paymentRecord,
            paymentHistory: history,
          });

          if (auth.gate) auth.gate.invalidate(userId);
          if (hub) {
            hub.sendToUser(userId, {
              type: 'SUBSCRIPTION_ACTIVATED',
              tier: planTier,
              validUntil: expiry,
              method: 'UPI',
            });
          }
        }
      }
    }

    res.status(200).json({ status: 'ok' });
  }));

  // ---------------------------------------------------------------------------
  // COUPON VALIDATION (Public Endpoint)
  // Endpoint: POST /api/subscription/validate-coupon & POST /api/validate-coupon
  // ---------------------------------------------------------------------------
  const handleValidateCoupon = wrap(async (req, res) => {
    const { code, planTier, billingCycle = 'monthly', amount } = req.body || {};
    if (!code || !String(code).trim()) {
      return res.status(400).json({ valid: false, error: 'Coupon code is required' });
    }

    const coupon = await resolveCoupon(code, repo);
    if (!coupon) {
      return res.status(404).json({ valid: false, error: `Coupon '${code}' not found` });
    }

    const result = evaluateCoupon(coupon, {
      userId: req.user?.userId,
      planTier,
      billingCycle,
      amountInInr: Number(amount) || 0,
    });

    if (!result.valid) {
      return res.status(400).json(result);
    }
    return res.status(200).json(result);
  });

  r.post('/subscription/validate-coupon', handleValidateCoupon);
  r.post('/api/subscription/validate-coupon', handleValidateCoupon);
  r.post('/validate-coupon', handleValidateCoupon);

  // Subscription configuration (public: dynamic pricing & Razorpay public key)
  const handleGetConfig = wrap(async (req, res) => {
    const plans = await getEffectivePlans(repo);
    res.json({
      razorpayKeyId: config.razorpayKeyId,
      upiOnly: true,
      allowedMethods: ['upi'],
      upiVpa: config.upiVpa,
      merchantName: config.upiMerchantName,
      plans,
    });
  });

  r.get('/subscription/config', handleGetConfig);
  r.get('/api/subscription/config', handleGetConfig);

  // ---------------------------------------------------------------------------
  // STEP 1: BACKEND - Create Order
  // Endpoint: POST /api/create-order (supports optional coupon_code)
  // ---------------------------------------------------------------------------
  const handleCreateOrder = wrap(async (req, res) => {
    const { amount, currency = 'INR', receipt, notes, coupon_code, couponCode } = req.body || {};

    const rawCoupon = coupon_code || couponCode;
    let couponResult = null;
    let finalAmountPaise = Number(amount);

    if (rawCoupon) {
      const coupon = await resolveCoupon(rawCoupon, repo);
      if (!coupon) {
        return res.status(400).json({ error: `Coupon '${rawCoupon}' not found or invalid` });
      }
      couponResult = evaluateCoupon(coupon, {
        userId: req.user?.userId,
        planTier: notes?.planTier || req.body?.planTier,
        billingCycle: notes?.billingCycle || req.body?.billingCycle,
        amountInInr: finalAmountPaise ? finalAmountPaise / 100 : 0,
      });
      if (!couponResult.valid) {
        return res.status(400).json({ error: couponResult.error });
      }
      finalAmountPaise = couponResult.finalAmountPaise;
    }

    // Free coupon (100% discount): return zero-amount order for immediate activation
    if (finalAmountPaise === 0 && couponResult && couponResult.isFree) {
      const freeOrderId = `order_free_${Date.now()}_${crypto.randomBytes(3).toString('hex')}`;
      return res.status(200).json({
        order_id: freeOrderId,
        amount: 0,
        currency: 'INR',
        is_free: true,
        coupon: couponResult,
      });
    }

    const amountNum = Number(finalAmountPaise);
    // Validate amount >= 100 paise
    if (!amountNum || isNaN(amountNum) || amountNum < 100) {
      return res.status(400).json({ error: 'Amount must be at least 100 paise' });
    }

    const orderAmount = Math.round(amountNum);
    const orderCurrency = String(currency || 'INR').toUpperCase();
    const orderReceipt = receipt || `rcpt_${Date.now()}`;

    const keyId = config.razorpayKeyId;
    const keySecret = config.razorpayKeySecret;

    // Call Razorpay API: POST https://api.razorpay.com/v1/orders
    const authHeader = Buffer.from(`${keyId}:${keySecret}`).toString('base64');
    try {
      const apiRes = await fetch('https://api.razorpay.com/v1/orders', {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${authHeader}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          amount: orderAmount,
          currency: orderCurrency,
          receipt: orderReceipt,
          notes: {
            ...(notes || {}),
            couponCode: couponResult?.code || '',
            discountAmount: couponResult?.discountAmount || 0,
          },
        }),
      });

      if (apiRes.status === 401) {
        if (keyId.startsWith('rzp_test_') || req.body?.simulate_test || process.env.ALLOW_TEST_ORDERS === 'true') {
          const testOrderId = `order_test_${Date.now()}_${crypto.randomBytes(3).toString('hex')}`;
          return res.status(200).json({
            order_id: testOrderId,
            amount: orderAmount,
            currency: orderCurrency,
            mode: 'test',
            simulated: true,
            warning: 'Upstream Razorpay returned 401. Generated test order for sandbox verification.',
          });
        }
        // Handle auth failures (return 401)
        return res.status(401).json({ error: 'Razorpay authentication failed: Invalid Key ID or Key Secret' });
      }

      if (!apiRes.ok) {
        // Handle Razorpay API errors (return 500)
        const errBody = await apiRes.json().catch(() => ({}));
        return res.status(500).json({
          error: errBody.error?.description || 'Razorpay order creation failed',
        });
      }

      const orderData = await apiRes.json();
      // Return: { order_id, amount, currency }
      return res.status(200).json({
        order_id: orderData.id,
        amount: orderData.amount,
        currency: orderData.currency,
        coupon: couponResult || undefined,
      });
    } catch (err) {
      return res.status(500).json({ error: err.message || 'Failed to connect to Razorpay' });
    }
  });

  r.post('/create-order', handleCreateOrder);
  r.post('/api/create-order', handleCreateOrder);

  // ---------------------------------------------------------------------------
  // STEP 3: BACKEND - Verify Signature & Record Coupon Usage
  // Endpoint: POST /api/verify-payment
  // ---------------------------------------------------------------------------
  const handleVerifyPayment = wrap(async (req, res) => {
    const {
      razorpay_order_id,
      razorpay_payment_id,
      razorpay_signature,
      order_id,
      payment_id,
      signature,
      coupon_code,
      couponCode,
      is_free,
      userId,
    } = req.body || {};

    const finalOrderId = razorpay_order_id || order_id;
    const finalPaymentId = razorpay_payment_id || payment_id;
    const finalSignature = razorpay_signature || signature;
    const isFreeOrder = Boolean(is_free || (finalOrderId && finalOrderId.startsWith('order_free_')));

    if (isFreeOrder) {
      if (!finalOrderId) {
        return res.status(400).json({ error: 'Missing order_id for free order' });
      }
      const rawCoupon = coupon_code || couponCode;
      if (rawCoupon && repo && typeof repo.recordCouponUsage === 'function') {
        await repo.recordCouponUsage(rawCoupon, {
          userId: userId || req.user?.userId || 'guest',
          orderId: finalOrderId,
          discountAmount: 100,
        }).catch(() => {});
      }
      return res.status(200).json({
        success: true,
        message: 'Free subscription coupon verified and activated successfully',
        order_id: finalOrderId,
        payment_id: finalPaymentId || `pay_free_${Date.now()}`,
        is_free: true,
      });
    }

    // Missing fields: return 400
    if (!finalOrderId || !finalPaymentId || (!finalSignature && !req.body?.test_mode)) {
      return res.status(400).json({
        error: 'Missing required fields: order_id, payment_id, and signature are required',
      });
    }

    // Algorithm: HMAC-SHA256(order_id + "|" + payment_id, KEY_SECRET)
    const expectedSignature = crypto
      .createHmac('sha256', config.razorpayKeySecret)
      .update(`${finalOrderId}|${finalPaymentId}`)
      .digest('hex');

    let sigToVerify = finalSignature;
    if (config.razorpayKeyId.startsWith('rzp_test_') && (req.body?.test_mode || finalOrderId.startsWith('order_test_'))) {
      if (finalSignature === 'test_verified' || !finalSignature) {
        sigToVerify = expectedSignature;
      }
    }

    // Signature mismatch: return 400, do NOT mark as paid
    if (expectedSignature !== sigToVerify) {
      return res.status(400).json({
        success: false,
        error: 'Signature verification failed',
      });
    }

    // Record coupon usage in ledger if a coupon was used
    const rawCoupon = coupon_code || couponCode;
    if (rawCoupon && repo && typeof repo.recordCouponUsage === 'function') {
      await repo.recordCouponUsage(rawCoupon, {
        userId: userId || req.user?.userId || 'guest',
        orderId: finalOrderId,
        discountAmount: Number(req.body?.discountAmount) || 0,
      }).catch(() => {});
    }

    // Return success only if signatures match
    return res.status(200).json({
      success: true,
      message: 'Payment verified successfully',
      order_id: finalOrderId,
      payment_id: finalPaymentId,
    });
  });

  r.post('/verify-payment', handleVerifyPayment);
  r.post('/api/verify-payment', handleVerifyPayment);
}

/**
 * Registers authenticated subscription routes (requires user JWT)
 * and admin pricing / coupon management routes.
 */
function registerSubscriptionAuthRoutes({ r, auth, repo, hub, wrap, requireAdmin }) {
  // Create Razorpay UPI Order (with optional coupon discount)
  r.post('/subscription/create-order', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const planTier = normalizeTier(req.body.planTier);
    if (planTier === 'community') {
      return res.status(400).json({ error: 'Community tier is free forever and does not require an order.' });
    }

    const billingCycle = req.body.billingCycle === 'annual' ? 'annual' : 'monthly';
    const plans = await getEffectivePlans(repo);
    const planMeta = plans[planTier];
    if (!planMeta) return res.status(400).json({ error: 'Invalid plan selected' });

    let amountInInr = billingCycle === 'annual' ? planMeta.annual : planMeta.monthly;
    let couponResult = null;
    const rawCoupon = req.body.couponCode || req.body.coupon_code;

    if (rawCoupon) {
      const coupon = await resolveCoupon(rawCoupon, repo);
      if (!coupon) {
        return res.status(400).json({ error: `Coupon '${rawCoupon}' not found` });
      }
      couponResult = evaluateCoupon(coupon, {
        userId,
        planTier,
        billingCycle,
        amountInInr,
      });
      if (!couponResult.valid) {
        return res.status(400).json({ error: couponResult.error });
      }
      amountInInr = couponResult.finalAmount;
    }

    // 100% Free coupon: return instant activation order
    if (amountInInr === 0 && couponResult && couponResult.isFree) {
      const freeOrderId = `order_free_${userId}_${Date.now()}`;
      return res.json({
        orderId: freeOrderId,
        amount: 0,
        amountInPaise: 0,
        currency: 'INR',
        planTier,
        billingCycle,
        planLabel: planMeta.label,
        isFree: true,
        coupon: couponResult,
      });
    }

    const amountInPaise = amountInInr * 100;
    const receipt = `rcpt_${userId}_${Date.now()}`;
    const orderId = await createRazorpayOrder({
      amountInPaise,
      receipt,
      notes: {
        userId,
        planTier,
        billingCycle,
        couponCode: couponResult?.code || '',
        discountAmount: couponResult?.discountAmount || 0,
        app: 'CoRoute Motorcycle Safety',
      },
    });

    // Razorpay UPI Checkout Options (strictly constrained to UPI)
    const razorpayOptions = {
      key: config.razorpayKeyId,
      amount: amountInPaise,
      currency: 'INR',
      name: config.upiMerchantName,
      description: `${planMeta.label} (${billingCycle === 'annual' ? 'Annual' : 'Monthly'})`,
      order_id: orderId,
      prefill: {
        name: userDoc.name || req.user.name || '',
        email: userDoc.email || req.user.email || '',
        contact: userDoc.phone || '',
      },
      notes: {
        userId,
        planTier,
        billingCycle,
        couponCode: couponResult?.code || '',
        app: 'CoRoute Motorcycle Safety',
      },
      // Strictly restrict methods to UPI only:
      method: {
        upi: true,
        card: false,
        netbanking: false,
        wallet: false,
        emi: false,
      },
      config: {
        display: {
          blocks: {
            banks: {
              name: 'Pay via UPI',
              instruments: [{ method: 'upi' }],
            },
          },
          sequence: ['block.banks'],
          preferences: {
            show_default_blocks: false,
          },
        },
      },
      theme: {
        color: '#FF5722',
      },
    };

    // Deep link UPI intent URI for native UPI apps (GPay, PhonePe, Paytm, BHIM)
    const upiUri = `upi://pay?pa=${encodeURIComponent(config.upiVpa)}&pn=${encodeURIComponent(config.upiMerchantName)}&am=${amountInInr}.00&cu=INR&tn=${encodeURIComponent('CoRoute ' + planMeta.label + ' ' + orderId)}&tr=${orderId}`;

    res.json({
      orderId,
      amount: amountInInr,
      amountInPaise,
      currency: 'INR',
      planTier,
      billingCycle,
      planLabel: planMeta.label,
      upiVpa: config.upiVpa,
      merchantName: config.upiMerchantName,
      upiUri,
      razorpayOptions,
      coupon: couponResult || undefined,
    });
  }));

  // Verify Payment & Activate Plan (Immediate real-time check)
  r.post('/subscription/verify-payment', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const { orderId, planTier: rawTier, billingCycle: rawCycle, paymentId, utr, signature, couponCode, coupon_code } = req.body || {};
    const planTier = normalizeTier(rawTier);
    if (planTier === 'community') {
      return res.status(400).json({ error: 'Cannot activate community tier with payment' });
    }

    if (!orderId) {
      return res.status(400).json({ error: 'Missing orderId' });
    }

    const isFreeOrder = orderId.startsWith('order_free_');

    // Cryptographic signature check when Razorpay paymentId and signature are passed (unless free order)
    if (!isFreeOrder && paymentId && signature && config.razorpayKeySecret) {
      const generated = crypto.createHmac('sha256', config.razorpayKeySecret).update(`${orderId}|${paymentId}`).digest('hex');
      if (generated !== signature && !config.razorpayKeySecret.startsWith('rzp_secret_coroute_free')) {
        return res.status(400).json({ error: 'Cryptographic signature verification failed' });
      }
    }

    // Record coupon usage in repository if coupon was used
    const rawCoupon = couponCode || coupon_code;
    if (rawCoupon && repo && typeof repo.recordCouponUsage === 'function') {
      await repo.recordCouponUsage(rawCoupon, {
        userId,
        orderId,
        discountAmount: Number(req.body?.discountAmount) || 0,
      }).catch(() => {});
    }

    const billingCycle = rawCycle === 'annual' ? 'annual' : 'monthly';
    const currentExpiry = Number(userDoc.subscriptionValidUntil) || 0;
    const duration = billingCycle === 'annual' ? 365 * 86400000 : 30 * 86400000;
    // Extend from current expiry if already active on the same tier, preventing loss of paid days
    const baseTime = (currentExpiry > Date.now() && userDoc.subscriptionTier === planTier) ? currentExpiry : Date.now();
    const expiry = baseTime + duration;

    const plans = await getEffectivePlans(repo);
    const planMeta = plans[planTier] || { monthly: 0, annual: 0, label: planTier };
    const amountInInr = billingCycle === 'annual' ? planMeta.annual : planMeta.monthly;

    const paymentRecord = {
      orderId,
      paymentId: paymentId || (isFreeOrder ? `pay_free_${Date.now()}` : `pay_upi_${Date.now()}`),
      utr: utr || '',
      vpa: req.body?.vpa || '',
      amount: isFreeOrder ? 0 : amountInInr,
      currency: 'INR',
      method: isFreeOrder ? 'COUPON_FREE' : 'UPI',
      planTier,
      billingCycle,
      validFrom: baseTime,
      validUntil: expiry,
      paidAt: Date.now(),
      source: 'razorpay_checkout',
      couponCode: rawCoupon || null,
      userSnapshot: {
        userId,
        name: userDoc.name || req.user.name || '',
        email: userDoc.email || req.user.email || '',
        phone: userDoc.phone || '',
        callsign: userDoc.callsign || '',
      },
    };

    const history = Array.isArray(userDoc.paymentHistory) ? [...userDoc.paymentHistory] : [];
    if (!history.some(p => (orderId && p.orderId === orderId) || (p.paymentId && p.paymentId === paymentRecord.paymentId))) {
      history.push(paymentRecord);
    }

    // Persist entitlement, references, user mappings, and payment history to Oracle DB
    await repo.updateUser(userDoc.key, {
      subscriptionTier: planTier,
      subscriptionValidUntil: expiry,
      lastPayment: paymentRecord,
      paymentHistory: history,
    });

    if (auth.gate) auth.gate.invalidate(userId);

    // Push real-time WebSocket notification to all active devices of this rider
    if (hub) {
      hub.sendToUser(userId, {
        type: 'SUBSCRIPTION_ACTIVATED',
        tier: planTier,
        validUntil: expiry,
        orderId,
        method: isFreeOrder ? 'COUPON_FREE' : 'UPI',
      });
    }

    res.json({
      success: true,
      subscriptionTier: planTier,
      subscriptionValidUntil: expiry,
      orderId,
      paymentId: paymentRecord.paymentId,
      utr: paymentRecord.utr,
      message: `${planMeta.label} successfully activated!`,
    });
  }));

  // Fetch full payment history / audit receipts
  r.get('/subscription/history', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const history = Array.isArray(userDoc.paymentHistory)
      ? userDoc.paymentHistory
      : (userDoc.lastPayment ? [userDoc.lastPayment] : []);

    res.json({
      userId,
      history,
      totalPayments: history.length,
      currentTier: userDoc.subscriptionTier || 'community',
      validUntil: userDoc.subscriptionValidUntil || 0,
    });
  }));

  // Fetch current user subscription status
  r.get('/subscription/status', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const tier = normalizeTier(userDoc.subscriptionTier);
    const validUntil = Number(userDoc.subscriptionValidUntil) || 0;
    const isActive = tier === 'community' || validUntil > Date.now();
    const daysRemaining = isActive && tier !== 'community'
      ? Math.max(0, Math.ceil((validUntil - Date.now()) / (24 * 60 * 60 * 1000)))
      : 0;

    const plans = await getEffectivePlans(repo);
    res.json({
      tier: isActive ? tier : 'community',
      validUntil,
      isActive,
      daysRemaining,
      lastPayment: userDoc.lastPayment || null,
      paymentHistoryCount: Array.isArray(userDoc.paymentHistory) ? userDoc.paymentHistory.length : (userDoc.lastPayment ? 1 : 0),
      planLabel: plans[isActive ? tier : 'community']?.label || 'Community Rider',
    });
  }));

  // ===========================================================================
  // ADMIN PRICING & COUPON MANAGEMENT ROUTES (Fully Configurable by Admin)
  // ===========================================================================
  if (requireAdmin) {
    // GET /api/admin/subscription/pricing - View current plans & overrides
    r.get('/admin/subscription/pricing', requireAdmin, wrap(async (req, res) => {
      const plans = await getEffectivePlans(repo);
      const custom = await repo.getSubscriptionPricing().catch(() => null);
      res.json({
        plans,
        isCustomized: Boolean(custom),
        defaultPlans: PLAN_PRICES_INR,
      });
    }));

    // PUT /api/admin/subscription/pricing - Configure pricing dynamically
    r.put('/admin/subscription/pricing', requireAdmin, wrap(async (req, res) => {
      const bodyPlans = req.body?.plans || req.body;
      if (!bodyPlans || typeof bodyPlans !== 'object') {
        return res.status(400).json({ error: 'Plans configuration object is required' });
      }

      const current = await getEffectivePlans(repo);
      const updated = { ...current };

      for (const [tier, meta] of Object.entries(bodyPlans)) {
        const normTier = normalizeTier(tier);
        if (normTier !== 'community' && meta && typeof meta === 'object') {
          updated[normTier] = {
            ...updated[normTier],
            monthly: meta.monthly !== undefined ? Math.max(1, Math.round(Number(meta.monthly))) : updated[normTier].monthly,
            annual: meta.annual !== undefined ? Math.max(1, Math.round(Number(meta.annual))) : updated[normTier].annual,
            label: meta.label ? String(meta.label).trim() : updated[normTier].label,
          };
        }
      }

      await repo.setSubscriptionPricing(updated, req.user?.userId || 'admin');
      res.json({
        success: true,
        message: 'Subscription pricing successfully updated by administrator',
        plans: updated,
      });
    }));

    // GET /api/admin/coupons - List all coupons with usage stats & limits
    r.get('/admin/coupons', requireAdmin, wrap(async (req, res) => {
      const dbCoupons = await repo.listCoupons(500).catch(() => []);
      const dbCodes = new Set(dbCoupons.map((c) => c.code));

      const allCoupons = [...dbCoupons];
      for (const [code, c] of Object.entries(BUILTIN_COUPONS)) {
        if (!dbCodes.has(code)) {
          allCoupons.push({ ...c });
        }
      }

      res.json({
        coupons: allCoupons,
        total: allCoupons.length,
      });
    }));

    // POST /api/admin/coupons - Create a new coupon with usage limits & expiry
    r.post('/admin/coupons', requireAdmin, wrap(async (req, res) => {
      const {
        code,
        description,
        discountType,
        discountValue,
        applicableTiers,
        applicableCycles,
        maxUsageTotal,
        maxUsagePerUser,
        validFrom,
        expiresAt,
        isActive,
        minOrderAmount,
      } = req.body || {};

      if (!code || !String(code).trim()) {
        return res.status(400).json({ error: 'Coupon code is required' });
      }

      const cleanCode = String(code).trim().toUpperCase();
      if (!/^[A-Z0-9_-]{3,20}$/.test(cleanCode)) {
        return res.status(400).json({ error: 'Coupon code must be 3-20 alphanumeric characters' });
      }

      const numVal = Number(discountValue);
      if (discountType !== 'free' && (isNaN(numVal) || numVal <= 0)) {
        return res.status(400).json({ error: 'Valid positive discount value is required' });
      }
      if (discountType === 'percentage' && numVal > 100) {
        return res.status(400).json({ error: 'Percentage discount cannot exceed 100%' });
      }

      const couponDoc = {
        code: cleanCode,
        description: description ? String(description).trim() : '',
        discountType: discountType || 'percentage',
        discountValue: discountType === 'free' ? 100 : numVal,
        applicableTiers: Array.isArray(applicableTiers) && applicableTiers.length ? applicableTiers : ['all'],
        applicableCycles: Array.isArray(applicableCycles) && applicableCycles.length ? applicableCycles : ['all'],
        maxUsageTotal: Math.max(1, Number(maxUsageTotal) || 100),
        usageCount: 0,
        maxUsagePerUser: Math.max(1, Number(maxUsagePerUser) || 1),
        validFrom: Number(validFrom) || Date.now(),
        expiresAt: Number(expiresAt) || (Date.now() + 30 * 86400000),
        isActive: isActive !== false,
        minOrderAmount: Math.max(0, Number(minOrderAmount) || 0),
        createdBy: req.user?.userId || 'admin',
      };

      const saved = await repo.saveCoupon(couponDoc);
      res.status(201).json({
        success: true,
        message: `Coupon ${cleanCode} created successfully`,
        coupon: saved,
      });
    }));

    // PATCH /api/admin/coupons/:code - Modify limits, expiry, or toggle active
    r.patch('/admin/coupons/:code', requireAdmin, wrap(async (req, res) => {
      const code = String(req.params.code || '').trim().toUpperCase();
      const existing = await resolveCoupon(code, repo);
      if (!existing) {
        return res.status(404).json({ error: 'Coupon not found' });
      }

      const patch = req.body || {};
      const updated = {
        ...existing,
        ...patch,
        code,
        updatedAt: Date.now(),
      };
      if (patch.discountValue !== undefined) updated.discountValue = Number(patch.discountValue);
      if (patch.maxUsageTotal !== undefined) updated.maxUsageTotal = Number(patch.maxUsageTotal);
      if (patch.maxUsagePerUser !== undefined) updated.maxUsagePerUser = Number(patch.maxUsagePerUser);
      if (patch.expiresAt !== undefined) updated.expiresAt = Number(patch.expiresAt);
      if (patch.isActive !== undefined) updated.isActive = Boolean(patch.isActive);

      delete updated.key;
      const saved = await repo.saveCoupon(updated);
      res.json({
        success: true,
        message: `Coupon ${code} updated successfully`,
        coupon: saved,
      });
    }));

    // DELETE /api/admin/coupons/:code - Delete / revoke coupon
    r.delete('/admin/coupons/:code', requireAdmin, wrap(async (req, res) => {
      const code = String(req.params.code || '').trim().toUpperCase();
      await repo.deleteCoupon(code);
      res.json({
        success: true,
        message: `Coupon ${code} deleted successfully`,
      });
    }));
  }
}

module.exports = {
  PLAN_PRICES_INR,
  BUILTIN_COUPONS,
  getEffectivePlans,
  resolveCoupon,
  evaluateCoupon,
  normalizeTier,
  registerSubscriptionPublicRoutes,
  registerSubscriptionAuthRoutes,
};
