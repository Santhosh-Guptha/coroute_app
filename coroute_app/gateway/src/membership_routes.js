'use strict';
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { createRazorpayGateway, RazorpayError } = require('./razorpay_gateway');

const actionLimiter = rateLimit({
  windowMs: 60 * 1000,
  limit: 60,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: 'Too many requests. Please slow down.', reason: 'RATE_LIMITED' },
});

let gwInstance = null;
function getRazorpayGateway(repo) {
  if (!gwInstance) gwInstance = createRazorpayGateway({ repo });
  return gwInstance;
}

/**
 * Activates or extends a membership from a verified or free order.
 * Records the transaction in the user's payment history and updates the ledger order.
 */
async function activateMembershipFromOrder({ repo, order, paymentId, method = 'RAZORPAY', source = 'checkout', userDoc = null }) {
  const uid = order.userId;
  const category = order.category || order.planTier || 'individual';
  const catalog = await repo.getMembershipCatalog();
  const plan = catalog[category] || catalog.individual;
  const now = Date.now();

  const existing = await repo.findMembershipByOwner(uid);
  const membershipId = existing ? existing.membershipId : `mem_${crypto.randomUUID()}`;
  const members = existing ? (existing.members || {}) : {};

  const durationDays = plan.billingPeriodDays || 30;
  const validUntil = existing && existing.validUntil > now
    ? existing.validUntil + durationDays * 86400000
    : now + durationDays * 86400000;

  const user = userDoc || (await repo.findUserById(uid));

  const membershipDoc = {
    membershipId,
    ownerUserId: uid, // Permanent non-transferable owner
    ownerName: user?.name || existing?.ownerName || 'Rider',
    ownerEmail: user?.email || existing?.ownerEmail || '',
    category,
    categoryName: plan.name,
    capacity: plan.capacity,
    minCapacity: plan.minCapacity || 1,
    maxCapacity: plan.maxCapacity || plan.capacity,
    priceInr: plan.monthlyPriceInr,
    status: 'ACTIVE',
    validFrom: existing ? existing.validFrom : now,
    validUntil,
    members,
    offerApplied: order.offerCode || null,
    paymentId: paymentId || order.paymentId || null,
    orderId: order.orderId,
    createdAt: existing ? existing.createdAt : now,
    updatedAt: now,
  };

  await repo.saveMembership(membershipDoc);

  // Update order in ledger
  await repo.updateRazorpayOrder(order.orderId, {
    status: 'PAID',
    paymentId: paymentId || order.paymentId,
    paidAt: now,
    method,
    updatedAt: now,
  });

  // Mirror to user paymentHistory
  if (user) {
    const history = Array.isArray(user.paymentHistory) ? [...user.paymentHistory] : [];
    const entry = {
      orderId: order.orderId,
      paymentId: paymentId || order.paymentId || '',
      amountInr: (Number(order.amountInPaise) || 0) / 100,
      category,
      categoryName: plan.name,
      method,
      status: 'PAID',
      paidAt: now,
      validUntil,
      source,
    };
    history.push(entry);
    await repo.updateUser(user.key, {
      lastPayment: entry,
      paymentHistory: history,
    });
  }

  return membershipDoc;
}

/**
 * Public membership routes: catalog, categories and HMAC webhook.
 */
function registerMembershipPublicRoutes({ r, repo, wrap }) {
  const WEBHOOK_MAX_BYTES = 1024 * 1024;
  const seenWebhookIds = new Set();
  const seenWebhookQueue = [];
  const rememberWebhook = (id) => {
    if (!id || seenWebhookIds.has(id)) return;
    seenWebhookIds.add(id);
    seenWebhookQueue.push(id);
    while (seenWebhookQueue.length > 1000) seenWebhookIds.delete(seenWebhookQueue.shift());
  };

  /**
   * GET /api/membership/catalog
   */
  r.get('/membership/catalog', wrap(async (req, res) => {
    const catalog = await repo.getMembershipCatalog();
    const offers = typeof repo.listOffers === 'function' ? await repo.listOffers(20) : [];
    const activeOffers = offers.filter((o) => o.isActive !== false && (!o.expiresAt || o.expiresAt > Date.now()));
    const gateway = getRazorpayGateway(repo);
    let keyId = '';
    let mode = 'test';
    try {
      const keys = await gateway.keysFor();
      keyId = keys.keyId || '';
      mode = keys.mode || 'test';
    } catch {
      // Keys might not be configured in offline or initial setup
    }
    res.json({
      categories: catalog,
      offers: activeOffers.map((o) => ({
        id: o.id,
        name: o.name || o.id,
        discountType: o.discountType,
        discountPercent: o.discountPercent || o.discountValue,
        description: o.description,
      })),
      paymentsEnabled: config.paymentsEnabled,
      keyId,
      mode,
    });
  }));

  /**
   * POST /api/membership/webhook
   * Public webhook endpoint from Razorpay with cryptographic HMAC signature verification.
   */
  r.post('/membership/webhook', wrap(async (req, res) => {
    const rawBuf = Buffer.isBuffer(req.body)
      ? req.body
      : Buffer.from(typeof req.body === 'string' ? req.body : JSON.stringify(req.body || {}), 'utf8');
    if (rawBuf.length > WEBHOOK_MAX_BYTES) return res.status(413).json({ error: 'Payload too large' });
    const rawBody = rawBuf.toString('utf8');
    const signature = req.get('x-razorpay-signature') || '';

    const gateway = getRazorpayGateway(repo);
    const mode = await gateway.verifyWebhook(rawBody, signature);
    if (!mode) return res.status(400).json({ error: 'Invalid webhook signature' });

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return res.status(400).json({ error: 'Invalid JSON payload' });
    }
    const eventId = String(req.get('x-razorpay-event-id') || '').trim().slice(0, 100);
    if (eventId && seenWebhookIds.has(eventId)) return res.status(200).json({ status: 'duplicate' });

    const eventType = String(event.event || '');
    const payment = event.payload?.payment?.entity || {};
    const refund = event.payload?.refund?.entity || null;
    const orderId = payment.order_id || event.payload?.order?.entity?.id || '';
    let order = orderId ? await repo.findRazorpayOrder(orderId) : null;
    const refundPaymentId = refund?.payment_id || payment.id || '';
    if (!order && refund && refundPaymentId && typeof repo.findRazorpayOrderByPaymentId === 'function') {
      order = await repo.findRazorpayOrderByPaymentId(refundPaymentId);
    }

    if (order && eventId && Array.isArray(order.webhookEvents) && order.webhookEvents.includes(eventId)) {
      rememberWebhook(eventId);
      return res.status(200).json({ status: 'duplicate' });
    }

    if (order && order.userId) {
      if (eventType === 'payment.captured' || eventType === 'order.paid') {
        if (order.status !== 'PAID') {
          await activateMembershipFromOrder({
            repo,
            order,
            paymentId: payment.id || '',
            method: String(payment.method || 'upi').toUpperCase(),
            source: 'razorpay_webhook',
          });
        }
      } else if (eventType === 'payment.failed') {
        if (order.status !== 'PAID') {
          await repo.updateRazorpayOrder(order.orderId, {
            status: 'FAILED',
            failureReason: String(payment.error_description || payment.error_reason || 'Payment failed').slice(0, 300),
            failureCode: String(payment.error_code || '').slice(0, 60),
            lastPaymentId: payment.id || '',
            updatedAt: Date.now(),
          });
        }
      } else if (eventType === 'refund.processed') {
        const refundAmount = (refund?.amount || payment.amount_refunded || 0) / 100;
        const fullyRefunded = (refund?.amount || 0) >= (order.amountInPaise || 0);
        await repo.updateRazorpayOrder(order.orderId, {
          refundStatus: 'PROCESSED',
          refundedAmount: refundAmount,
          refundedAmountInPaise: (refund?.amount || 0),
          fullyRefunded,
          updatedAt: Date.now(),
        });
        if (fullyRefunded) {
          const mem = await repo.findMembershipByOwner(order.userId);
          if (mem && mem.category === order.category) {
            mem.status = 'EXPIRED';
            mem.validUntil = Date.now();
            mem.statusReason = 'REFUNDED';
            await repo.saveMembership(mem);
          }
        }
      }
      if (eventId) {
        const events = Array.isArray(order.webhookEvents) ? [...order.webhookEvents, eventId] : [eventId];
        await repo.updateRazorpayOrder(order.orderId, { webhookEvents: events });
        rememberWebhook(eventId);
      }
    }

    res.json({ status: 'ok' });
  }));
}

/**
 * Authenticated membership routes: purchase, invitations, seat management, admin.
 */
function registerMembershipAuthRoutes({ r, repo, convoys, wrap, requireAdmin }) {
  /**
   * GET /api/membership/my
   */
  r.get('/membership/my', wrap(async (req, res) => {
    const uid = req.user.userId;
    const owned = await repo.findMembershipByOwner(uid);
    const allMemberships = await repo.findMembershipsForUser(uid);
    const participating = allMemberships.filter((m) => m.ownerUserId !== uid);
    const activeTrip = await repo.getActiveTrip(uid);

    let effectiveEntitlements = {
      ptt: false,
      convoy: false,
      groupSafety: false,
      personalTracking: true,
      basicNav: true,
      sharedTrip: false,
    };

    if (config.paymentsEnabled === false) {
      effectiveEntitlements = {
        ptt: true,
        convoy: true,
        groupSafety: true,
        personalTracking: true,
        basicNav: true,
        sharedTrip: true,
      };
    } else if (owned && owned.status === 'ACTIVE' && owned.validUntil > Date.now()) {
      const catalog = await repo.getMembershipCatalog();
      const cat = catalog[owned.category];
      if (cat?.entitlements) effectiveEntitlements = { ...effectiveEntitlements, ...cat.entitlements };
    } else if (participating.some((m) => m.status === 'ACTIVE' && m.validUntil > Date.now())) {
      effectiveEntitlements = {
        ptt: true,
        convoy: true,
        groupSafety: true,
        personalTracking: true,
        basicNav: true,
        sharedTrip: true,
      };
    }

    res.json({
      owned: owned || null,
      participating,
      activeTrip: activeTrip || null,
      effectiveEntitlements,
      paymentsEnabled: config.paymentsEnabled,
    });
  }));

  /**
   * POST /api/membership/order
   * Initiates payment order creation on backend. Free orders (e.g. RIDERFREE) are activated immediately.
   */
  r.post('/membership/order', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { category, offerCode } = req.body || {};

    const catalog = await repo.getMembershipCatalog();
    const plan = catalog[category];
    if (!plan) {
      return res.status(400).json({ error: 'Invalid membership category', reason: 'INVALID_CATEGORY' });
    }

    // Capacity conflict check on downgrade
    const existing = await repo.findMembershipByOwner(uid);
    if (existing && existing.members && Object.keys(existing.members).length + 1 > plan.capacity) {
      return res.status(409).json({
        error: `Cannot switch to ${plan.name}: current group has ${Object.keys(existing.members).length + 1} members which exceeds new capacity of ${plan.capacity}. Please remove members first.`,
        reason: 'CAPACITY_CONFLICT',
      });
    }

    const now = Date.now();
    let isFreeActivation = false;
    let appliedOffer = null;
    let discountPercent = 0;
    let discountAmountInr = 0;

    if (offerCode) {
      const cleanOffer = String(offerCode).trim().toUpperCase();
      if (typeof repo.findOffer === 'function') {
        const off = await repo.findOffer(cleanOffer);
        if (off && off.isActive !== false && (!off.expiresAt || off.expiresAt > now)) {
          if (off.discountPercent === 100 || off.discountType === 'free') {
            isFreeActivation = true;
            appliedOffer = off.id;
          } else if (off.discountPercent) {
            discountPercent = off.discountPercent;
            appliedOffer = off.id;
          }
        }
      }
      if (!isFreeActivation && typeof repo.findCoupon === 'function') {
        const coup = await repo.findCoupon(cleanOffer);
        if (coup && coup.isActive !== false && (!coup.expiresAt || coup.expiresAt > now)) {
          if (coup.discountType === 'free' || coup.discountValue === 100) {
            isFreeActivation = true;
            appliedOffer = coup.code;
          } else if (coup.discountType === 'percentage') {
            discountPercent = coup.discountValue;
            appliedOffer = coup.code;
          } else if (coup.discountType === 'fixed') {
            discountAmountInr = coup.discountValue;
            appliedOffer = coup.code;
          }
        }
      }
      if (!isFreeActivation && cleanOffer === 'RIDERFREE') {
        isFreeActivation = true;
        appliedOffer = 'RIDERFREE';
      }
    }

    if (config.paymentsEnabled === false) {
      isFreeActivation = true;
    }

    let finalAmountInr = plan.monthlyPriceInr;
    if (isFreeActivation) {
      finalAmountInr = 0;
    } else if (discountPercent > 0) {
      finalAmountInr = Math.max(0, Math.round(plan.monthlyPriceInr * (1 - discountPercent / 100)));
    } else if (discountAmountInr > 0) {
      finalAmountInr = Math.max(0, plan.monthlyPriceInr - discountAmountInr);
    }

    const orderId = `mem_ord_${Date.now()}_${crypto.randomBytes(4).toString('hex')}`;
    const amountInPaise = finalAmountInr * 100;

    if (finalAmountInr === 0) {
      const orderDoc = {
        orderId,
        userId: uid,
        category,
        amountInPaise: 0,
        amount: 0,
        currency: 'INR',
        status: 'PAID',
        mode: 'free',
        isFree: true,
        offerCode: appliedOffer,
        createdAt: now,
        paidAt: now,
      };
      await repo.saveRazorpayOrder(orderDoc);

      const membership = await activateMembershipFromOrder({
        repo,
        order: orderDoc,
        paymentId: `free_${orderId}`,
        method: 'OFFER',
        source: 'free_offer',
        userDoc: req.dbUser,
      });

      if (appliedOffer && typeof repo.recordCouponUsage === 'function') {
        await repo.recordCouponUsage(appliedOffer, { userId: uid, orderId, discountAmount: plan.monthlyPriceInr });
      }

      return res.status(201).json({
        orderId,
        isFree: true,
        amountInr: 0,
        currency: 'INR',
        membership,
      });
    }

    const gateway = getRazorpayGateway(repo);
    let rzpOrder;
    try {
      rzpOrder = await gateway.createOrder({
        amountInPaise,
        currency: 'INR',
        receipt: orderId.slice(0, 40),
        notes: { userId: uid, category, offerCode: appliedOffer || '' },
      });
    } catch (e) {
      return res.status(e.status || 500).json({ error: e.message, code: e.code || 'GATEWAY_ERROR' });
    }

    const orderDoc = {
      orderId: rzpOrder.id,
      internalOrderId: orderId,
      userId: uid,
      category,
      amountInPaise,
      amount: finalAmountInr,
      currency: 'INR',
      status: 'CREATED',
      mode: rzpOrder.mode,
      keyId: rzpOrder.keyId,
      offerCode: appliedOffer,
      discountAmount: plan.monthlyPriceInr - finalAmountInr,
      createdAt: now,
    };
    await repo.saveRazorpayOrder(orderDoc);

    res.status(201).json({
      orderId: rzpOrder.id,
      amountInPaise,
      amountInr: finalAmountInr,
      currency: 'INR',
      keyId: rzpOrder.keyId,
      mode: rzpOrder.mode,
      category,
      categoryName: plan.name,
      isFree: false,
    });
  }));

  /**
   * POST /api/membership/verify
   * Cryptographically verifies HMAC signature of payment, validates idempotency & replay protection, activates membership.
   */
  r.post('/membership/verify', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { orderId, paymentId, signature } = req.body || {};

    if (!orderId || !paymentId) {
      return res.status(400).json({ error: 'orderId and paymentId are required', reason: 'BAD_REQUEST' });
    }

    const order = await repo.findRazorpayOrder(orderId);
    if (!order) {
      return res.status(404).json({ error: 'Order not found in ledger', reason: 'ORDER_NOT_FOUND' });
    }

    if (order.userId !== uid && req.user.role !== 'MASTER_ADMIN') {
      return res.status(403).json({ error: 'Order does not belong to this user', reason: 'ORDER_USER_MISMATCH' });
    }

    // Idempotency: if already paid, return active membership
    if (order.status === 'PAID') {
      const existing = await repo.findMembershipByOwner(uid);
      return res.json({
        success: true,
        message: 'Order already processed and membership active',
        membership: existing,
        order,
      });
    }

    // Replay attack protection: ensure this paymentId was not credited to any other order
    if (typeof repo.findRazorpayOrderByPaymentId === 'function') {
      const existingByPayment = await repo.findRazorpayOrderByPaymentId(paymentId);
      if (existingByPayment && existingByPayment.orderId !== order.orderId) {
        return res.status(409).json({
          error: 'This payment has already been credited to another order. Replay rejected.',
          reason: 'REPLAY_ATTACK_DETECTED',
        });
      }
    }

    // Cryptographic HMAC signature check
    const gateway = getRazorpayGateway(repo);
    const isValid = await gateway.verifySignature({
      orderId,
      paymentId,
      signature,
      mode: order.mode,
    });

    if (!isValid) {
      await repo.updateRazorpayOrder(order.orderId, {
        status: 'FAILED',
        failureReason: 'Invalid cryptographic HMAC signature',
        lastPaymentId: paymentId,
        updatedAt: Date.now(),
      });
      return res.status(400).json({
        error: 'Invalid payment signature. Verification failed.',
        reason: 'INVALID_PAYMENT_SIGNATURE',
      });
    }

    const membership = await activateMembershipFromOrder({
      repo,
      order,
      paymentId,
      method: 'RAZORPAY',
      source: 'app_verification',
      userDoc: req.dbUser,
    });

    if (order.offerCode && typeof repo.recordCouponUsage === 'function') {
      await repo.recordCouponUsage(order.offerCode, {
        userId: uid,
        orderId,
        discountAmount: order.discountAmount || 0,
      });
    }

    res.json({
      success: true,
      message: 'Payment verified and membership activated successfully',
      membership,
      order: await repo.findRazorpayOrder(orderId),
    });
  }));

  /**
   * POST /api/membership/purchase
   * Backward-compatible purchase route: supports immediate free activation and verifies payments.
   */
  r.post('/membership/purchase', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { category, offerCode, paymentId, orderId, signature } = req.body || {};

    const catalog = await repo.getMembershipCatalog();
    const plan = catalog[category];
    if (!plan) {
      return res.status(400).json({ error: 'Invalid membership category', reason: 'INVALID_CATEGORY' });
    }

    const now = Date.now();
    let isFreeActivation = false;
    let appliedOffer = null;

    if (offerCode) {
      const cleanOffer = String(offerCode).trim().toUpperCase();
      if (typeof repo.findOffer === 'function') {
        const off = await repo.findOffer(cleanOffer);
        if (off && off.isActive !== false && (!off.expiresAt || off.expiresAt > now)) {
          if (off.discountPercent === 100 || off.discountType === 'free') {
            isFreeActivation = true;
            appliedOffer = off.id;
          }
        }
      }
      if (!isFreeActivation && typeof repo.findCoupon === 'function') {
        const coup = await repo.findCoupon(cleanOffer);
        if (coup && coup.isActive !== false && (!coup.expiresAt || coup.expiresAt > now)) {
          if (coup.discountType === 'free' || coup.discountValue === 100) {
            isFreeActivation = true;
            appliedOffer = coup.code;
          }
        }
      }
      if (!isFreeActivation && cleanOffer === 'RIDERFREE') {
        isFreeActivation = true;
        appliedOffer = 'RIDERFREE';
      }
    }

    if (config.paymentsEnabled === false) {
      isFreeActivation = true;
    }

    if (!isFreeActivation && plan.monthlyPriceInr > 0 && !paymentId) {
      return res.status(402).json({
        error: 'Payment required to activate this membership category',
        reason: 'PAYMENT_REQUIRED',
        amountInr: plan.monthlyPriceInr,
      });
    }

    // Capacity conflict check
    const existing = await repo.findMembershipByOwner(uid);
    let membershipId = existing ? existing.membershipId : `mem_${crypto.randomUUID()}`;
    let members = existing ? (existing.members || {}) : {};

    if (Object.keys(members).length + 1 > plan.capacity) {
      return res.status(409).json({
        error: `Cannot switch to ${plan.name}: current group has ${Object.keys(members).length + 1} members which exceeds new capacity of ${plan.capacity}. Please remove members first.`,
        reason: 'CAPACITY_CONFLICT',
      });
    }

    // If payment verification signature was provided, run cryptographic verification
    if (orderId && paymentId && signature) {
      const gateway = getRazorpayGateway(repo);
      const order = await repo.findRazorpayOrder(orderId);
      const isValid = await gateway.verifySignature({
        orderId,
        paymentId,
        signature,
        mode: order?.mode || 'test',
      });
      if (!isValid) {
        return res.status(400).json({
          error: 'Invalid payment signature. Verification failed.',
          reason: 'INVALID_PAYMENT_SIGNATURE',
        });
      }
    }

    const durationDays = plan.billingPeriodDays || 30;
    const validUntil = existing && existing.validUntil > now
      ? existing.validUntil + durationDays * 86400000
      : now + durationDays * 86400000;

    const membershipDoc = {
      membershipId,
      ownerUserId: uid, // Permanent owner, non-transferable
      ownerName: req.user.name,
      ownerEmail: req.user.email,
      category,
      categoryName: plan.name,
      capacity: plan.capacity,
      minCapacity: plan.minCapacity || 1,
      maxCapacity: plan.maxCapacity || plan.capacity,
      priceInr: plan.monthlyPriceInr,
      status: 'ACTIVE',
      validFrom: existing ? existing.validFrom : now,
      validUntil,
      members,
      offerApplied: appliedOffer || null,
      paymentId: paymentId || null,
      orderId: orderId || null,
      createdAt: existing ? existing.createdAt : now,
      updatedAt: now,
    };

    await repo.saveMembership(membershipDoc);

    // Save order in ledger
    if (orderId) {
      await repo.saveRazorpayOrder({
        orderId,
        userId: uid,
        category,
        amountInPaise: (isFreeActivation ? 0 : plan.monthlyPriceInr) * 100,
        amount: isFreeActivation ? 0 : plan.monthlyPriceInr,
        currency: 'INR',
        status: 'PAID',
        paymentId: paymentId || null,
        mode: isFreeActivation ? 'free' : 'test',
        isFree: isFreeActivation,
        offerCode: appliedOffer,
        createdAt: now,
        paidAt: now,
      });
    }

    res.status(existing ? 200 : 201).json({
      message: 'Membership activated successfully',
      membership: membershipDoc,
    });
  }));

  /**
   * GET /api/membership/payments
   * Returns authenticated user's payment and order history.
   */
  r.get('/membership/payments', wrap(async (req, res) => {
    const uid = req.user.userId;
    const orders = await repo.listRazorpayOrders({ userId: uid }, 100);
    const sorted = orders.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
    const user = await repo.findUserById(uid);
    res.json({
      payments: sorted.map((o) => ({
        orderId: o.orderId,
        paymentId: o.paymentId || '',
        amountInr: (o.amountInPaise || 0) / 100,
        currency: o.currency || 'INR',
        category: o.category,
        status: o.status,
        mode: o.mode,
        isFree: Boolean(o.isFree),
        offerCode: o.offerCode || null,
        paidAt: o.paidAt || 0,
        createdAt: o.createdAt || 0,
        refundStatus: o.refundStatus || null,
        refundedAmount: o.refundedAmount || 0,
      })),
      paymentHistory: user?.paymentHistory || [],
    });
  }));

  /**
   * POST /api/membership/members/invite
   */
  r.post('/membership/members/invite', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { email, phone, userId: targetUserIdInput, identifier } = req.body || {};

    const membership = await repo.findMembershipByOwner(uid);
    if (!membership || membership.status !== 'ACTIVE' || membership.validUntil <= Date.now()) {
      return res.status(403).json({
        error: 'You do not own an active group membership.',
        reason: 'NO_ACTIVE_MEMBERSHIP',
      });
    }

    if (membership.capacity <= 1) {
      return res.status(400).json({
        error: 'Individual memberships do not support group member invitations.',
        reason: 'INDIVIDUAL_TIER_NO_INVITES',
      });
    }

    const members = membership.members || {};
    const occupiedSeats = 1 + Object.keys(members).length; // 1 for owner

    if (occupiedSeats >= membership.capacity) {
      return res.status(409).json({
        error: `Cannot invite more members. Purchased capacity of ${membership.capacity} seats reached.`,
        reason: 'MEMBERSHIP_CAPACITY_EXCEEDED',
        capacity: membership.capacity,
        occupiedSeats,
      });
    }

    let targetUser = null;
    const ident = (identifier || email || phone || targetUserIdInput || '').trim();
    if (targetUserIdInput) {
      targetUser = await repo.findUserById(String(targetUserIdInput));
    }
    if (!targetUser && email) {
      targetUser = await repo.findUserByEmail(String(email).trim().toLowerCase());
    }
    if (!targetUser && ident) {
      if (ident.includes('@')) {
        targetUser = await repo.findUserByEmail(ident.toLowerCase());
      } else {
        targetUser = (await repo.findUserById(ident)) || (await repo.findUserByName(ident));
      }
    }

    if (!targetUser) {
      return res.status(404).json({
        error: 'Rider account not found for that email, username or user ID.',
        reason: 'USER_NOT_FOUND',
      });
    }

    if (targetUser.userId === uid) {
      return res.status(400).json({
        error: 'You are the membership owner and already have a seat.',
        reason: 'OWNER_CANNOT_INVITE_SELF',
      });
    }

    if (members[targetUser.userId]) {
      return res.status(409).json({
        error: 'This rider has already been added to your membership.',
        reason: 'ALREADY_MEMBER',
        member: members[targetUser.userId],
      });
    }

    members[targetUser.userId] = {
      userId: targetUser.userId,
      name: targetUser.name,
      email: targetUser.email,
      phone: targetUser.phone || '',
      status: 'INVITED',
      invitedAt: Date.now(),
    };

    membership.members = members;
    await repo.saveMembership(membership);

    res.json({
      ok: true,
      message: `Invitation sent to ${targetUser.name}`,
      members: Object.values(members),
      capacity: membership.capacity,
      remainingSeats: membership.capacity - (1 + Object.keys(members).length),
    });
  }));

  /**
   * POST /api/membership/members/respond
   */
  r.post('/membership/members/respond', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { membershipId, action: rawAction, accept } = req.body || {};
    const action = rawAction || (accept === true ? 'ACCEPT' : accept === false ? 'DECLINE' : null);

    if (!membershipId || !['ACCEPT', 'DECLINE'].includes(action)) {
      return res.status(400).json({ error: 'membershipId and valid action (ACCEPT or DECLINE) are required.', reason: 'BAD_REQUEST' });
    }

    const membership = await repo.findMembershipById(membershipId);
    if (!membership || !membership.members || !membership.members[uid]) {
      return res.status(404).json({ error: 'No invitation found for your account in this membership.', reason: 'INVITATION_NOT_FOUND' });
    }

    if (action === 'ACCEPT') {
      membership.members[uid].status = 'ACCEPTED';
      membership.members[uid].acceptedAt = Date.now();
    } else {
      membership.members[uid].status = 'DECLINED';
      membership.members[uid].declinedAt = Date.now();
    }

    await repo.saveMembership(membership);

    res.json({
      ok: true,
      message: action === 'ACCEPT' ? 'Membership invitation accepted' : 'Membership invitation declined',
      action,
      membershipId,
      ownerName: membership.ownerName,
      accepted: action === 'ACCEPT',
    });
  }));

  /**
   * DELETE /api/membership/members/:targetUserId
   */
  r.delete('/membership/members/:targetUserId', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const targetUserId = req.params.targetUserId;

    const membership = await repo.findMembershipByOwner(uid);
    if (!membership) {
      return res.status(403).json({ error: 'You do not own an active membership.', reason: 'NOT_OWNER' });
    }

    if (!membership.members || !membership.members[targetUserId]) {
      return res.status(404).json({ error: 'Member not found in your group membership.', reason: 'MEMBER_NOT_FOUND' });
    }

    delete membership.members[targetUserId];
    await repo.saveMembership(membership);

    // If removed member is in owner's active trip, remove them from that convoy
    const ownerActiveTrip = await repo.getActiveTrip(uid);
    if (ownerActiveTrip && convoys && typeof convoys.leaveConvoy === 'function') {
      try {
        await convoys.leaveConvoy(ownerActiveTrip.groupId, targetUserId, { reason: 'REMOVED_BY_MEMBERSHIP_OWNER' });
      } catch {
        // ignore
      }
    }

    res.json({
      ok: true,
      message: 'Member removed successfully.',
      members: Object.values(membership.members),
      capacity: membership.capacity,
      remainingSeats: membership.capacity - (1 + Object.keys(membership.members).length),
    });
  }));

  // =========================================================================
  // PLATFORM ADMIN ENDPOINTS
  // =========================================================================

  r.get('/admin/membership/catalog', requireAdmin, wrap(async (req, res) => {
    const catalog = await repo.getMembershipCatalog();
    res.json({ catalog });
  }));

  r.put('/admin/membership/catalog', requireAdmin, wrap(async (req, res) => {
    const { catalog } = req.body || {};
    if (!catalog || typeof catalog !== 'object') {
      return res.status(400).json({ error: 'Valid catalog object required.', reason: 'INVALID_CATALOG' });
    }
    await repo.setMembershipCatalog(catalog, req.user.email || req.user.userId);
    res.json({ message: 'Membership catalog updated successfully.', catalog });
  }));

  r.get('/admin/membership/memberships', requireAdmin, wrap(async (req, res) => {
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 100, 1), 500);
    const all = await repo.soda.query(repo.soda.collections?.memberships || 'memberships', {}, { limit: 5000 });
    const memberships = all.map((r) => ({ ...r.value, key: r.key }))
      .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))
      .slice(0, limit);
    res.json({ memberships, total: all.length });
  }));

  r.get('/admin/membership/payments', requireAdmin, wrap(async (req, res) => {
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 100, 1), 500);
    const orders = await repo.listRazorpayOrders({}, 5000);
    const sorted = orders.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0)).slice(0, limit);
    res.json({ payments: sorted, total: orders.length });
  }));

  r.post('/admin/membership/payments/:orderId/refund', requireAdmin, wrap(async (req, res) => {
    const order = await repo.findRazorpayOrder(req.params.orderId);
    if (!order) return res.status(404).json({ error: 'Order not found' });
    if (order.status !== 'PAID' || !order.paymentId) {
      return res.status(400).json({ error: 'Only paid orders can be refunded' });
    }
    const gateway = getRazorpayGateway(repo);
    const body = req.body || {};
    const amountInPaise = body.amountInPaise || order.amountInPaise;
    const reason = String(body.reason || 'Admin refund').slice(0, 200);

    let refund;
    try {
      refund = await gateway.refundPayment(order.paymentId, amountInPaise, { reason }, order.mode || 'test');
    } catch (e) {
      return res.status(e.status || 500).json({ error: e.message, code: e.code || 'REFUND_FAILED' });
    }

    const refundedAmountInPaise = (order.refundedAmountInPaise || 0) + (refund.amount || amountInPaise);
    const fullyRefunded = refundedAmountInPaise >= order.amountInPaise;
    const refundStatus = String(refund.status || 'PROCESSED').toUpperCase();

    await repo.updateRazorpayOrder(order.orderId, {
      refundId: refund.id,
      refundStatus,
      refundedAmountInPaise,
      refundedAmount: refundedAmountInPaise / 100,
      fullyRefunded,
      refundReason: reason,
      refundedBy: req.user.email || req.user.userId,
      updatedAt: Date.now(),
    });

    if (fullyRefunded && order.userId) {
      const mem = await repo.findMembershipByOwner(order.userId);
      if (mem && mem.category === order.category) {
        mem.status = 'EXPIRED';
        mem.validUntil = Date.now();
        mem.statusReason = 'REFUNDED';
        await repo.saveMembership(mem);
      }
    }

    res.json({
      ok: true,
      refundId: refund.id,
      refundStatus: refund.status || 'PROCESSED',
      fullyRefunded,
      orderId: order.orderId,
    });
  }));

  r.get('/admin/membership/analytics', requireAdmin, wrap(async (req, res) => {
    const allMemberships = await repo.soda.query(repo.soda.collections?.memberships || 'memberships', {}, { limit: 10000 });
    const now = Date.now();

    let individualActive = 0;
    let groupSmallActive = 0;
    let groupLargeActive = 0;
    let totalMRR = 0;
    let totalSeatsAllocated = 0;
    let totalSeatsOccupied = 0;

    for (const r of allMemberships) {
      const m = r.value;
      if (m.status === 'ACTIVE' && m.validUntil > now) {
        if (m.category === 'individual') {
          individualActive++;
          totalMRR += (m.priceInr || 9);
          totalSeatsAllocated += 1;
          totalSeatsOccupied += 1;
        } else if (m.category === 'group_small') {
          groupSmallActive++;
          totalMRR += (m.priceInr || 49);
          totalSeatsAllocated += (m.capacity || 6);
          totalSeatsOccupied += (1 + Object.keys(m.members || {}).length);
        } else if (m.category === 'group_large') {
          groupLargeActive++;
          totalMRR += (m.priceInr || 99);
          totalSeatsAllocated += (m.capacity || 12);
          totalSeatsOccupied += (1 + Object.keys(m.members || {}).length);
        }
      }
    }

    const activeTripsCount = await repo.soda.query(repo.soda.collections?.activeTrips || 'active_trips', {}, { limit: 10000 });

    res.json({
      activeMemberships: {
        individual: individualActive,
        groupSmall: groupSmallActive,
        groupLarge: groupLargeActive,
        total: individualActive + groupSmallActive + groupLargeActive,
      },
      seatUtilization: {
        totalAllocated: totalSeatsAllocated,
        totalOccupied: totalSeatsOccupied,
        utilizationRate: totalSeatsAllocated > 0 ? (totalSeatsOccupied / totalSeatsAllocated).toFixed(2) : 0,
      },
      financialMetrics: {
        estimatedMRR: totalMRR,
        currency: 'INR',
      },
      concurrency: {
        currentActiveTrips: activeTripsCount.length,
      },
      timestamp: now,
    });
  }));
}

module.exports = {
  registerMembershipPublicRoutes,
  registerMembershipAuthRoutes,
};
