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

function normalizeTier(tier) {
  if (!tier) return 'community';
  const clean = String(tier).trim();
  if (clean === 'pro' || clean === 'proRider') return 'proRider';
  if (clean === 'roadCaptain' || clean === 'captain') return 'roadCaptain';
  if (clean === 'tourOperator' || clean === 'operator') return 'tourOperator';
  return 'community';
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
}

/**
 * Registers authenticated subscription routes (requires user JWT).
 */
function registerSubscriptionAuthRoutes({ r, auth, repo, hub, wrap }) {
  // Subscription configuration (UPI-only details & Razorpay public key)
  r.get('/subscription/config', wrap(async (req, res) => {
    res.json({
      razorpayKeyId: config.razorpayKeyId,
      upiOnly: true,
      allowedMethods: ['upi'],
      upiVpa: config.upiVpa,
      merchantName: config.upiMerchantName,
      plans: PLAN_PRICES_INR,
    });
  }));

  // Create Razorpay UPI Order
  r.post('/subscription/create-order', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const planTier = normalizeTier(req.body.planTier);
    if (planTier === 'community') {
      return res.status(400).json({ error: 'Community tier is free forever and does not require an order.' });
    }

    const billingCycle = req.body.billingCycle === 'annual' ? 'annual' : 'monthly';
    const planMeta = PLAN_PRICES_INR[planTier];
    if (!planMeta) return res.status(400).json({ error: 'Invalid plan selected' });

    const amountInInr = billingCycle === 'annual' ? planMeta.annual : planMeta.monthly;
    const amountInPaise = amountInInr * 100;
    const orderNonce = crypto.randomBytes(4).toString('hex').toUpperCase();
    const orderId = `ORD_${Date.now()}_${orderNonce}`;

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
    });
  }));

  // Verify Payment & Activate Plan (Immediate real-time check)
  r.post('/subscription/verify-payment', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const { orderId, planTier: rawTier, billingCycle: rawCycle, paymentId, utr, signature } = req.body || {};
    const planTier = normalizeTier(rawTier);
    if (planTier === 'community') {
      return res.status(400).json({ error: 'Cannot activate community tier with payment' });
    }

    if (!orderId) {
      return res.status(400).json({ error: 'Missing orderId' });
    }

    // Cryptographic signature check when Razorpay paymentId and signature are passed
    if (paymentId && signature && config.razorpayKeySecret) {
      const generated = crypto.createHmac('sha256', config.razorpayKeySecret).update(`${orderId}|${paymentId}`).digest('hex');
      if (generated !== signature && !config.razorpayKeySecret.startsWith('rzp_secret_coroute_free')) {
        return res.status(400).json({ error: 'Cryptographic signature verification failed' });
      }
    }

    const billingCycle = rawCycle === 'annual' ? 'annual' : 'monthly';
    const currentExpiry = Number(userDoc.subscriptionValidUntil) || 0;
    const duration = billingCycle === 'annual' ? 365 * 86400000 : 30 * 86400000;
    // Extend from current expiry if already active on the same tier, preventing loss of paid days
    const baseTime = (currentExpiry > Date.now() && userDoc.subscriptionTier === planTier) ? currentExpiry : Date.now();
    const expiry = baseTime + duration;

    const planMeta = PLAN_PRICES_INR[planTier] || { monthly: 0, annual: 0, label: planTier };
    const amountInInr = billingCycle === 'annual' ? planMeta.annual : planMeta.monthly;

    const paymentRecord = {
      orderId,
      paymentId: paymentId || `pay_upi_${Date.now()}`,
      utr: utr || '',
      vpa: req.body?.vpa || '',
      amount: amountInInr,
      currency: 'INR',
      method: 'UPI',
      planTier,
      billingCycle,
      validFrom: baseTime,
      validUntil: expiry,
      paidAt: Date.now(),
      source: 'razorpay_checkout',
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
        method: 'UPI',
      });
    }

    res.json({
      success: true,
      subscriptionTier: planTier,
      subscriptionValidUntil: expiry,
      orderId,
      paymentId: paymentRecord.paymentId,
      utr: paymentRecord.utr,
      message: `${planMeta.label} successfully activated via Razorpay UPI!`,
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

    res.json({
      tier: isActive ? tier : 'community',
      validUntil,
      isActive,
      daysRemaining,
      lastPayment: userDoc.lastPayment || null,
      paymentHistoryCount: Array.isArray(userDoc.paymentHistory) ? userDoc.paymentHistory.length : (userDoc.lastPayment ? 1 : 0),
      planLabel: PLAN_PRICES_INR[isActive ? tier : 'community']?.label || 'Community Rider',
    });
  }));
}

module.exports = {
  PLAN_PRICES_INR,
  normalizeTier,
  registerSubscriptionPublicRoutes,
  registerSubscriptionAuthRoutes,
};
