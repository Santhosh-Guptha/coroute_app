'use strict';
const express = require('express');
const crypto = require('crypto');
const config = require('./config');
const { createRazorpayGateway, RazorpayError } = require('./razorpay_gateway');

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


// One gateway (keys + mode + API client) per repository.
const gateways = new WeakMap();
function gatewayFor(repo) {
  const k = repo || gatewayFor;
  if (!gateways.has(k)) gateways.set(k, createRazorpayGateway({ repo }));
  return gateways.get(k);
}

function sendRzpError(res, e) {
  if (e instanceof RazorpayError) return res.status(e.status).json({ error: e.message, code: e.code });
  throw e;
}

/**
 * Order ledger: every order the server issues is recorded with the plan,
 * amount and mode decided on the server. Verification and the webhook trust
 * only this record, never plan/amount values sent back by a client.
 */
async function saveOrder(repo, order) {
  await repo.saveRazorpayOrder({ ...order, createdAt: Date.now(), status: order.status || 'CREATED' });
}

/** Grants the plan to the user once per order (idempotent). */
async function activatePlan({ repo, auth, hub, userDoc, order, paymentId, utr, vpa, method, source }) {
  const planTier = order.planTier;
  const billingCycle = order.billingCycle === 'annual' ? 'annual' : 'monthly';
  const history = Array.isArray(userDoc.paymentHistory) ? [...userDoc.paymentHistory] : [];
  const prior = history.find((p) => p.orderId === order.orderId);
  if (prior) {
    return { tier: userDoc.subscriptionTier, validUntil: userDoc.subscriptionValidUntil, record: prior, already: true };
  }
  const currentExpiry = Number(userDoc.subscriptionValidUntil) || 0;
  const duration = billingCycle === 'annual' ? 365 * 86400000 : 30 * 86400000;
  // Extend from current expiry when renewing the same tier, so paid days are never lost.
  const baseTime = (currentExpiry > Date.now() && userDoc.subscriptionTier === planTier) ? currentExpiry : Date.now();
  const expiry = baseTime + duration;
  const record = {
    orderId: order.orderId,
    paymentId: paymentId || '',
    utr: utr || '',
    vpa: vpa || '',
    amount: (Number(order.amountInPaise) || 0) / 100,
    currency: 'INR',
    method,
    planTier,
    billingCycle,
    validFrom: baseTime,
    validUntil: expiry,
    paidAt: Date.now(),
    source,
    mode: order.mode || null,
    couponCode: order.couponCode || null,
    userSnapshot: {
      userId: userDoc.userId,
      name: userDoc.name || '',
      email: userDoc.email || '',
      phone: userDoc.phone || '',
      callsign: userDoc.callsign || '',
    },
  };
  history.push(record);
  await repo.updateUser(userDoc.key, {
    subscriptionTier: planTier,
    subscriptionValidUntil: expiry,
    lastPayment: record,
    paymentHistory: history,
  });
  await repo.updateRazorpayOrder(order.orderId, { status: 'PAID', paymentId: paymentId || '', paidAt: Date.now() });
  if (order.couponCode && typeof repo.recordCouponUsage === 'function') {
    await repo.recordCouponUsage(order.couponCode, {
      userId: userDoc.userId, orderId: order.orderId, discountAmount: order.discountAmount || 0,
    }).catch(() => {});
  }
  if (auth && auth.gate) auth.gate.invalidate(userDoc.userId);
  if (hub) {
    hub.sendToUser(userDoc.userId, { type: 'SUBSCRIPTION_ACTIVATED', tier: planTier, validUntil: expiry, orderId: order.orderId, method });
  }
  return { tier: planTier, validUntil: expiry, record, already: false };
}

/**
 * Registers public endpoints: webhook (HMAC-authenticated), coupon check,
 * public config, and the generic create-order / verify-payment pair used by
 * the web checkout page. The generic pair never grants a plan by itself.
 */
function registerSubscriptionPublicRoutes({ r, auth, repo, hub, wrap }) {
  const gateway = gatewayFor(repo);

  r.post('/subscription/webhook', wrap(async (req, res) => {
    const rawBody = typeof req.body === 'string'
      ? req.body
      : (Buffer.isBuffer(req.body) ? req.body.toString('utf8') : JSON.stringify(req.body || {}));
    const signature = req.get('x-razorpay-signature') || '';

    // Always required: an unsigned or wrongly signed webhook is never trusted.
    const mode = await gateway.verifyWebhook(rawBody, signature);
    if (!mode) return res.status(400).json({ error: 'Invalid webhook signature' });

    let event;
    try {
      event = typeof req.body === 'object' && !Buffer.isBuffer(req.body) ? req.body : JSON.parse(rawBody);
    } catch {
      return res.status(400).json({ error: 'Invalid JSON payload' });
    }

    const eventType = event.event || '';
    if (eventType === 'payment.captured' || eventType === 'order.paid') {
      const payment = event.payload?.payment?.entity || {};
      const orderId = payment.order_id || event.payload?.order?.entity?.id || '';
      const order = orderId ? await repo.findRazorpayOrder(orderId) : null;
      if (order && order.userId && order.mode === mode && order.status !== 'PAID') {
        const userDoc = await repo.findUserById(order.userId);
        if (userDoc) {
          await activatePlan({
            repo, auth, hub, userDoc, order,
            paymentId: payment.id || '',
            utr: payment.acquirer_data?.rrn || payment.acquirer_data?.upi_transaction_id || '',
            vpa: payment.vpa || '',
            method: String(payment.method || 'upi').toUpperCase(),
            source: 'razorpay_webhook',
          });
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

  // Public config: plans + the ACTIVE mode's key id (never a secret).
  const handleGetConfig = wrap(async (req, res) => {
    const plans = await getEffectivePlans(repo);
    const keys = await gateway.keysFor();
    res.json({
      razorpayKeyId: keys.keyId,
      mode: keys.mode,
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
  // STEP 1: BACKEND - Create Order   POST /api/create-order
  // Body: { amount (paise) | planTier+billingCycle, currency, receipt, coupon_code }
  // ---------------------------------------------------------------------------
  const handleCreateOrder = wrap(async (req, res) => {
    const { amount, currency = 'INR', receipt, notes, coupon_code, couponCode } = req.body || {};
    const planTier = normalizeTier(req.body?.planTier || notes?.planTier);
    const billingCycle = (req.body?.billingCycle || notes?.billingCycle) === 'annual' ? 'annual' : 'monthly';

    // A known plan is priced on the server; otherwise the given amount is used.
    let finalAmountPaise = Number(amount);
    if (planTier !== 'community') {
      const plans = await getEffectivePlans(repo);
      const meta = plans[planTier];
      if (meta) finalAmountPaise = (billingCycle === 'annual' ? meta.annual : meta.monthly) * 100;
    }

    const rawCoupon = coupon_code || couponCode;
    let couponResult = null;
    if (rawCoupon) {
      const coupon = await resolveCoupon(rawCoupon, repo);
      if (!coupon) return res.status(400).json({ error: `Coupon '${rawCoupon}' not found or invalid` });
      couponResult = evaluateCoupon(coupon, {
        userId: req.user?.userId,
        planTier,
        billingCycle,
        amountInInr: finalAmountPaise ? finalAmountPaise / 100 : 0,
      });
      if (!couponResult.valid) return res.status(400).json({ error: couponResult.error });
      finalAmountPaise = couponResult.finalAmountPaise;
    }

    if (couponResult && couponResult.isFree) {
      const freeOrderId = `order_free_${Date.now()}_${crypto.randomBytes(4).toString('hex')}`;
      await saveOrder(repo, {
        orderId: freeOrderId, userId: null, planTier, billingCycle, amountInPaise: 0,
        couponCode: couponResult.code, discountAmount: couponResult.discountAmount, isFree: true, mode: null, channel: 'public',
      });
      return res.status(200).json({ order_id: freeOrderId, amount: 0, currency: 'INR', is_free: true, coupon: couponResult });
    }

    if (!Number.isFinite(finalAmountPaise) || finalAmountPaise < 100) {
      return res.status(400).json({ error: 'Amount must be at least 100 paise' });
    }

    let order;
    try {
      order = await gateway.createOrder({
        amountInPaise: finalAmountPaise,
        currency: String(currency || 'INR').toUpperCase(),
        receipt: receipt || `rcpt_${Date.now()}`,
        notes: { ...(notes || {}), planTier, billingCycle, couponCode: couponResult?.code || '' },
      });
    } catch (e) {
      return sendRzpError(res, e);
    }
    await saveOrder(repo, {
      orderId: order.id, userId: null, planTier, billingCycle, amountInPaise: order.amount,
      couponCode: couponResult?.code || null, discountAmount: couponResult?.discountAmount || 0,
      isFree: false, mode: order.mode, channel: 'public',
    });
    return res.status(200).json({
      order_id: order.id,
      amount: order.amount,
      currency: order.currency,
      key_id: order.keyId,
      mode: order.mode,
      coupon: couponResult || undefined,
    });
  });

  r.post('/create-order', handleCreateOrder);
  r.post('/api/create-order', handleCreateOrder);

  // ---------------------------------------------------------------------------
  // STEP 3: BACKEND - Verify Signature   POST /api/verify-payment
  // HMAC-SHA256(order_id + "|" + payment_id, KEY_SECRET of the order's mode)
  // ---------------------------------------------------------------------------
  const handleVerifyPayment = wrap(async (req, res) => {
    const b = req.body || {};
    const orderId = b.razorpay_order_id || b.order_id;
    const paymentId = b.razorpay_payment_id || b.payment_id;
    const signature = b.razorpay_signature || b.signature;

    if (!orderId) return res.status(400).json({ success: false, error: 'Missing required field: order_id is required' });
    const order = await repo.findRazorpayOrder(orderId);
    if (!order) return res.status(400).json({ success: false, error: 'Unknown order' });

    if (order.isFree) {
      if (order.status !== 'PAID') {
        await repo.updateRazorpayOrder(orderId, { status: 'PAID', paidAt: Date.now() });
        if (order.couponCode && typeof repo.recordCouponUsage === 'function') {
          await repo.recordCouponUsage(order.couponCode, { userId: 'guest', orderId, discountAmount: order.discountAmount || 0 }).catch(() => {});
        }
      }
      return res.status(200).json({ success: true, message: 'Free coupon order confirmed', order_id: orderId, is_free: true });
    }

    // Missing fields: 400
    if (!paymentId || !signature) {
      return res.status(400).json({ success: false, error: 'Missing required fields: order_id, payment_id, and signature are required' });
    }
    const ok = await gateway.verifySignature({ orderId, paymentId, signature, mode: order.mode });
    // Signature mismatch: 400, NOT marked paid
    if (!ok) {
      await repo.updateRazorpayOrder(orderId, { status: 'SIGNATURE_MISMATCH', lastPaymentId: paymentId });
      return res.status(400).json({ success: false, error: 'Signature verification failed' });
    }
    if (order.status !== 'PAID') {
      await repo.updateRazorpayOrder(orderId, { status: 'PAID', paymentId, paidAt: Date.now() });
      if (order.couponCode && typeof repo.recordCouponUsage === 'function') {
        await repo.recordCouponUsage(order.couponCode, { userId: 'guest', orderId, discountAmount: order.discountAmount || 0 }).catch(() => {});
      }
    }
    return res.status(200).json({ success: true, message: 'Payment verified successfully', order_id: orderId, payment_id: paymentId, mode: order.mode });
  });

  r.post('/verify-payment', handleVerifyPayment);
  r.post('/api/verify-payment', handleVerifyPayment);
}

/**
 * Registers authenticated subscription routes (requires user JWT)
 * and admin pricing / coupon / payment-gateway routes.
 */
function registerSubscriptionAuthRoutes({ r, auth, repo, hub, wrap, requireAdmin }) {
  const gateway = gatewayFor(repo);

  // Create a Razorpay order for a plan (price decided here, optional coupon).
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
      if (!coupon) return res.status(400).json({ error: `Coupon '${rawCoupon}' not found` });
      couponResult = evaluateCoupon(coupon, { userId, planTier, billingCycle, amountInInr });
      if (!couponResult.valid) return res.status(400).json({ error: couponResult.error });
      amountInInr = couponResult.finalAmount;
    }

    if (amountInInr === 0 && couponResult && couponResult.isFree) {
      const freeOrderId = `order_free_${crypto.randomBytes(8).toString('hex')}`;
      await saveOrder(repo, {
        orderId: freeOrderId, userId, planTier, billingCycle, amountInPaise: 0,
        couponCode: couponResult.code, discountAmount: couponResult.discountAmount, isFree: true, mode: null, channel: 'app',
      });
      return res.json({
        orderId: freeOrderId, amount: 0, amountInPaise: 0, currency: 'INR',
        planTier, billingCycle, planLabel: planMeta.label, isFree: true, coupon: couponResult,
      });
    }

    const amountInPaise = Math.round(amountInInr * 100);
    if (amountInPaise < 100) return res.status(400).json({ error: 'Amount must be at least 100 paise' });

    let order;
    try {
      order = await gateway.createOrder({
        amountInPaise,
        receipt: `rcpt_${userId}_${Date.now()}`,
        notes: {
          userId, planTier, billingCycle,
          couponCode: couponResult?.code || '',
          discountAmount: couponResult?.discountAmount || 0,
          app: 'CoRoute Motorcycle Safety',
        },
      });
    } catch (e) {
      return sendRzpError(res, e);
    }
    await saveOrder(repo, {
      orderId: order.id, userId, planTier, billingCycle, amountInPaise: order.amount,
      couponCode: couponResult?.code || null, discountAmount: couponResult?.discountAmount || 0,
      isFree: false, mode: order.mode, channel: 'app',
    });

    // Razorpay Checkout options (UPI only)
    const razorpayOptions = {
      key: order.keyId,
      amount: order.amount,
      currency: 'INR',
      name: config.upiMerchantName,
      description: `${planMeta.label} (${billingCycle === 'annual' ? 'Annual' : 'Monthly'})`,
      order_id: order.id,
      prefill: {
        name: userDoc.name || req.user.name || '',
        email: userDoc.email || req.user.email || '',
        contact: userDoc.phone || '',
      },
      notes: { userId, planTier, billingCycle, couponCode: couponResult?.code || '', app: 'CoRoute Motorcycle Safety' },
      method: { upi: true, card: false, netbanking: false, wallet: false, emi: false },
      config: {
        display: {
          blocks: { banks: { name: 'Pay via UPI', instruments: [{ method: 'upi' }] } },
          sequence: ['block.banks'],
          preferences: { show_default_blocks: false },
        },
      },
      theme: { color: '#FF5722' },
    };

    // Direct UPI intent (paid outside Razorpay; confirmed by an admin from the UTR).
    const upiUri = `upi://pay?pa=${encodeURIComponent(config.upiVpa)}&pn=${encodeURIComponent(config.upiMerchantName)}&am=${amountInInr}.00&cu=INR&tn=${encodeURIComponent('CoRoute ' + planMeta.label + ' ' + order.id)}&tr=${order.id}`;

    res.json({
      orderId: order.id,
      amount: amountInInr,
      amountInPaise: order.amount,
      currency: 'INR',
      mode: order.mode,
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

  /**
   * Verify & activate. Plan, cycle and amount come from the order ledger.
   *  - free coupon order          → activated
   *  - paymentId + signature      → HMAC checked with the order's mode secret, then activated
   *  - utr only (direct UPI app)  → recorded as a claim (202); an admin approves it
   */
  r.post('/subscription/verify-payment', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const { orderId, paymentId, signature, utr, vpa } = req.body || {};
    if (!orderId) return res.status(400).json({ error: 'Missing orderId' });

    const order = await repo.findRazorpayOrder(orderId);
    if (!order || order.userId !== userId) return res.status(400).json({ error: 'Unknown order for this account' });

    const plans = await getEffectivePlans(repo);
    const label = plans[order.planTier]?.label || order.planTier;
    const done = (result, method) => res.json({
      success: true,
      subscriptionTier: result.tier,
      subscriptionValidUntil: result.validUntil,
      orderId,
      paymentId: result.record.paymentId,
      utr: result.record.utr,
      method,
      message: `${label} successfully activated!`,
    });

    if (order.isFree) {
      const result = await activatePlan({ repo, auth, hub, userDoc, order, paymentId: `coupon_${order.couponCode}`, method: 'COUPON_FREE', source: 'coupon' });
      return done(result, 'COUPON_FREE');
    }

    if (paymentId && signature) {
      const ok = await gateway.verifySignature({ orderId, paymentId, signature, mode: order.mode });
      if (!ok) {
        await repo.updateRazorpayOrder(orderId, { status: 'SIGNATURE_MISMATCH', lastPaymentId: paymentId });
        return res.status(400).json({ error: 'Payment signature verification failed' });
      }
      const result = await activatePlan({ repo, auth, hub, userDoc, order, paymentId, utr, vpa, method: 'RAZORPAY', source: 'razorpay_checkout' });
      return done(result, 'RAZORPAY');
    }

    if (utr && String(utr).trim().length >= 8) {
      if (order.status === 'PAID') {
        const prior = (userDoc.paymentHistory || []).find((p) => p.orderId === orderId);
        if (prior) return done({ tier: userDoc.subscriptionTier, validUntil: userDoc.subscriptionValidUntil, record: prior }, prior.method);
      }
      await repo.updateRazorpayOrder(orderId, { status: 'UTR_CLAIMED', utr: String(utr).trim(), vpa: vpa || '', claimedAt: Date.now() });
      return res.status(202).json({
        success: false,
        pending: true,
        orderId,
        message: 'UTR received. Your plan is activated once the payment is confirmed (usually within a few hours).',
      });
    }

    return res.status(400).json({ error: 'Missing required fields: paymentId and signature (or a UPI UTR) are required' });
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


  if (requireAdmin) {
    // ---------------------------------------------------------------------------
    // PAYMENT GATEWAY (Razorpay test/live keys + active mode)
    // ---------------------------------------------------------------------------
    r.get('/admin/payment-gateway', requireAdmin, wrap(async (req, res) => {
      res.set('Cache-Control', 'no-store').json(await gateway.publicView());
    }));

    // Body: { mode?, test?: {keyId, keySecret, webhookSecret}, live?: {...} } — blank keeps saved values.
    r.put('/admin/payment-gateway', requireAdmin, wrap(async (req, res) => {
      try {
        const view = await gateway.update(req.body || {}, req.user?.email || req.user?.userId || 'admin');
        res.set('Cache-Control', 'no-store').json({ success: true, ...view });
      } catch (e) {
        sendRzpError(res, e);
      }
    }));

    // Checks a mode's keys against Razorpay (GET /v1/orders?count=1).
    r.post('/admin/payment-gateway/test', requireAdmin, wrap(async (req, res) => {
      try {
        const mode = req.body?.mode === 'live' ? 'live' : (req.body?.mode === 'test' ? 'test' : undefined);
        res.json({ success: true, ...(await gateway.testKeys(mode)) });
      } catch (e) {
        sendRzpError(res, e);
      }
    }));

    // Direct-UPI claims waiting for a person to match the UTR to the bank statement.
    r.get('/admin/payment-claims', requireAdmin, wrap(async (req, res) => {
      res.json({ claims: await repo.listRazorpayOrders({ status: 'UTR_CLAIMED' }, 200) });
    }));

    r.post('/admin/payment-claims/:orderId/approve', requireAdmin, wrap(async (req, res) => {
      const order = await repo.findRazorpayOrder(req.params.orderId);
      if (!order || order.status !== 'UTR_CLAIMED' || !order.userId) return res.status(404).json({ error: 'No pending claim for this order' });
      const userDoc = await repo.findUserById(order.userId);
      if (!userDoc) return res.status(404).json({ error: 'User not found' });
      const result = await activatePlan({
        repo, auth, hub, userDoc, order,
        paymentId: `utr_${order.utr}`, utr: order.utr, vpa: order.vpa, method: 'UPI', source: `admin_utr:${req.user?.userId || 'admin'}`,
      });
      res.json({ success: true, subscriptionTier: result.tier, subscriptionValidUntil: result.validUntil });
    }));

    r.post('/admin/payment-claims/:orderId/reject', requireAdmin, wrap(async (req, res) => {
      const order = await repo.findRazorpayOrder(req.params.orderId);
      if (!order || order.status !== 'UTR_CLAIMED') return res.status(404).json({ error: 'No pending claim for this order' });
      await repo.updateRazorpayOrder(order.orderId, { status: 'UTR_REJECTED', rejectedAt: Date.now(), rejectedBy: req.user?.userId || 'admin' });
      res.json({ success: true });
    }));
  }

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
  gatewayFor,
  activatePlan,
  registerSubscriptionPublicRoutes,
  registerSubscriptionAuthRoutes,
};
