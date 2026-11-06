'use strict';
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { createRazorpayGateway } = require('./razorpay_gateway');
const reviews = require('./trip_reviews');
const reviewPhotos = require('./review_photos');

// Review photos live outside public/ (config.reviewPhotoDir); every read goes through a checked route.
const photoStore = reviewPhotos.createPhotoStore(config.reviewPhotoDir);
/** Sends one stored review photo, or a bare 404 (never says why a photo is not available). */
async function sendReviewPhoto(res, meta, cacheControl) {
  const data = meta ? await photoStore.read(meta) : null;
  if (!data) return res.status(404).set('Cache-Control', 'no-store').json({ error: 'Not found' });
  res.set('Cache-Control', cacheControl)
    .set('Content-Type', meta.mime)
    .set('Content-Disposition', 'inline')
    .set('Cross-Origin-Resource-Policy', 'same-origin')
    .set('X-Robots-Tag', 'noindex')
    .send(data);
}

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

const activeUserTransactions = new Map(); // userId -> { timestamp, op }
function acquireUserTransactionLock(userId, op = 'tx') {
  const now = Date.now();
  const existing = activeUserTransactions.get(userId);
  if (existing && (now - existing.timestamp < 10000)) {
    return false;
  }
  activeUserTransactions.set(userId, { timestamp: now, op });
  return true;
}
function releaseUserTransactionLock(userId) {
  activeUserTransactions.delete(userId);
}

/**
 * Rider-level coupon rules shared by checkout and free activation: per-rider redemption
 * limit, new-members-only, first-payment-only and an allow-list. Null when the rider may use it,
 * otherwise { error, reason } for a 400 answer.
 */
function couponRiderBlock(coupon, uid, userDoc) {
  const hist = Array.isArray(userDoc?.paymentHistory) ? userDoc.paymentHistory : [];
  if (coupon.newMembersOnly && hist.some((p) => p.status === 'PAID')) {
    return { error: 'This coupon is valid for new members only', reason: 'NEW_MEMBERS_ONLY' };
  }
  if (coupon.firstPaymentOnly && hist.length > 0) {
    return { error: 'This coupon is valid for your first payment only', reason: 'FIRST_PAYMENT_ONLY' };
  }
  if (Array.isArray(coupon.allowedUserIds) && coupon.allowedUserIds.length > 0 && !coupon.allowedUserIds.includes(uid)) {
    return { error: 'This coupon is restricted to select members', reason: 'NOT_ELIGIBLE' };
  }
  const maxPerUser = Number(coupon.maxUsagePerUser) || 1;
  const used = (coupon.usages || []).filter((u) => u.userId === uid).length;
  if (used >= maxPerUser) {
    return { error: `You have already redeemed coupon ${coupon.code} (limit ${maxPerUser} per rider)`, reason: 'PER_USER_LIMIT_REACHED' };
  }
  return null;
}

/** True when the coupon covers the whole monthly price of a ₹`priceInr` plan. */
function couponMakesFree(coupon, priceInr) {
  const v = Number(coupon.discountValue) || 0;
  if (coupon.discountType === 'free') return true;
  if (coupon.discountType === 'percentage') return v >= 100;
  if (coupon.discountType === 'fixed') return v >= (Number(priceInr) || 0) && (!coupon.maxDiscountCap || coupon.maxDiscountCap >= priceInr);
  return false;
}

/**
 * Why `coupon` cannot pay in full for membership `category` for this rider: status, a 100% discount,
 * plan binding, then the rider rules. Null when it can.
 */
function freeCouponBlock(coupon, { uid, userDoc, category, plan }) {
  if (coupon.status !== 'ACTIVE') {
    const st = String(coupon.status || 'INACTIVE');
    return { error: `Coupon is ${st.toLowerCase().replace(/_/g, ' ')}`, reason: `COUPON_${st}` };
  }
  if (!couponMakesFree(coupon, plan.monthlyPriceInr)) {
    return { error: `Coupon ${coupon.code} does not provide a 100% discount. Payment required.`, reason: 'PARTIAL_COUPON' };
  }
  const tiers = Array.isArray(coupon.applicableTiers) ? coupon.applicableTiers : ['all'];
  if (!tiers.includes('all') && !tiers.includes(category)) {
    return { error: `Coupon ${coupon.code} is not valid for ${plan.name || category}`, reason: 'TIER_MISMATCH' };
  }
  return couponRiderBlock(coupon, uid, userDoc);
}

/** A catalog plan that is switched off is not sold (the admin "active" toggle). */
const planOnSale = (plan) => !!plan && plan.isActive !== false;

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
  const isRenewal = existing && existing.status === 'ACTIVE' && existing.category === category;
  const isUpgrade = existing && existing.status === 'ACTIVE' && existing.category !== category;

  let validUntil;
  if (isRenewal) {
    // Paid renewal adds duration, capped at 1 year from now
    validUntil = order.isFree
      ? Math.max(existing.validUntil, now + durationDays * 86400000)
      : Math.min(existing.validUntil + durationDays * 86400000, now + 365 * 86400000);
  } else if (isUpgrade) {
    // Upgrade takes effect immediately, preserving remaining time or setting 30 days
    validUntil = order.isFree
      ? now + durationDays * 86400000
      : Math.max(existing.validUntil, now + durationDays * 86400000);
  } else {
    validUntil = now + durationDays * 86400000;
  }

  const user = userDoc || (await repo.findUserById(uid));
  const transactionType = isUpgrade ? 'UPGRADE' : (isRenewal ? 'RENEWAL' : (order.isFree ? 'COUPON_ACTIVATION' : 'NEW'));

  const upgradeHistory = Array.isArray(existing?.upgradeHistory) ? [...existing.upgradeHistory] : [];
  if (isUpgrade) {
    upgradeHistory.push({
      fromCategory: existing.category,
      toCategory: category,
      upgradedAt: now,
      orderId: order.orderId,
      paymentId: paymentId || order.paymentId || '',
      method,
    });
  }

  const membershipDoc = {
    membershipId,
    ownerUserId: uid,
    ownerName: user?.name || existing?.ownerName || 'Rider',
    ownerEmail: user?.email || existing?.ownerEmail || '',
    category,
    categoryName: plan.name,
    capacity: plan.capacity,
    minCapacity: plan.minCapacity || 1,
    maxCapacity: plan.maxCapacity || plan.capacity,
    priceInr: plan.monthlyPriceInr,
    status: 'ACTIVE',
    validFrom: isUpgrade ? now : (existing ? existing.validFrom : now),
    validUntil,
    members,
    offerApplied: order.offerCode || null,
    paymentId: paymentId || order.paymentId || null,
    orderId: order.orderId,
    upgradeHistory,
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
    transactionType,
    activatedAt: now,
    updatedAt: now,
  });

  // Mirror to user paymentHistory with deduplication by orderId
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
      isFree: Boolean(order.isFree),
      transactionType,
    };
    const existingIdx = history.findIndex((h) => h.orderId === order.orderId);
    if (existingIdx >= 0) {
      history[existingIdx] = entry;
    } else {
      history.push(entry);
    }
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
    const onSale = {};
    for (const [id, c] of Object.entries(catalog || {})) if (planOnSale(c)) onSale[id] = c;
    res.json({
      categories: onSale,
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
   * GET /api/public/community-stats (and /api/community-stats)
   * Public read-only riding statistics for website ("CoRoute Community in Motion").
   * Cached for 60s, rate-limited, privacy-safe, zero PII or coordinates.
   */
  let cachedCommunityStats = null;
  let cachedStatsExpiry = 0;

  const handleCommunityStats = wrap(async (req, res) => {
    res.set('Cache-Control', 'public, max-age=60');
    const now = Date.now();
    if (cachedCommunityStats && now < cachedStatsExpiry) {
      return res.json(cachedCommunityStats);
    }
    const stats = await repo.getCommunityStats();
    cachedCommunityStats = stats;
    cachedStatsExpiry = now + 60000;
    res.json(stats);
  });

  r.get('/public/community-stats', handleCommunityStats);
  r.get('/community-stats', handleCommunityStats);

  // Approved rider reviews for the website. Never invented: an empty list when nothing is approved.
  // Public, cached for 30 s (an approval shows up quickly), rate-limited; no names, emails, phones, ids or coordinates.
  const storiesLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  r.get('/public/community-stories', storiesLimiter, wrap(async (req, res) => {
    res.set('Cache-Control', 'public, max-age=30');
    res.json(await reviews.communityStories(repo, req.query.limit));
  }));
  // Legacy shape (a bare array of the same stories) for older website builds.
  r.get('/community-stories', storiesLimiter, wrap(async (req, res) => {
    res.set('Cache-Control', 'public, max-age=30');
    res.json((await reviews.communityStories(repo, req.query.limit)).stories);
  }));
  // A rider's photo on the website. Served ONLY while the review is APPROVED with publication consent,
  // the rider ticked the photo consent and an admin selected this photo; anything else is a plain 404
  // (pending, rejected, withdrawn, deleted, unselected). Short cache so a withdrawal takes effect fast.
  const mediaLimiter = rateLimit({ windowMs: 60 * 1000, limit: 300, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  r.get('/public/review-photos/:feedbackId/:photoId', mediaLimiter, wrap(async (req, res) => {
    const photoId = String(req.params.photoId || '');
    const feedbackId = String(req.params.feedbackId || '');
    if (!reviewPhotos.isPhotoId(photoId) || !/^FB-[A-Za-z0-9-]{4,60}$/.test(feedbackId)) return sendReviewPhoto(res, null);
    const doc = await repo.getTripFeedback(feedbackId).catch(() => null);
    const visible = doc && reviews.isPublic(doc) && reviews.publicPhotos(doc).includes(photoId);
    const meta = visible ? reviews.uploadsOf(doc).find((u) => u.id === photoId) : null;
    return sendReviewPhoto(res, meta, 'public, max-age=60');
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
   * POST /api/membership/validate-coupon
   * Validates a promotional coupon code against a specific category for the authenticated user.
   * Returns calculated discount and final payable amount without creating orders.
   */
  r.post('/membership/validate-coupon', wrap(async (req, res) => {
    const uid = req.user.userId;
    const { code, category } = req.body || {};
    if (!code || !category) {
      return res.status(400).json({ valid: false, error: 'code and category are required', reason: 'BAD_REQUEST' });
    }

    const cleanCode = String(code).trim().toUpperCase();
    const catalog = await repo.getMembershipCatalog();
    const plan = catalog[category];
    if (!plan) {
      return res.status(400).json({ valid: false, error: 'Invalid membership category', reason: 'INVALID_CATEGORY' });
    }

    const coupon = await repo.findCoupon(cleanCode);
    if (!coupon) {
      return res.status(404).json({ valid: false, error: `Coupon ${cleanCode} does not exist`, reason: 'COUPON_NOT_FOUND' });
    }

    // Dynamic status check
    if (coupon.status === 'USAGE_LIMIT_REACHED') {
      return res.status(400).json({ valid: false, error: 'This coupon has reached its maximum total redemptions', reason: 'COUPON_LIMIT_REACHED' });
    }
    if (coupon.status === 'EXPIRED') {
      return res.status(400).json({ valid: false, error: 'This coupon has expired', reason: 'COUPON_EXPIRED' });
    }
    if (coupon.status === 'SCHEDULED') {
      return res.status(400).json({ valid: false, error: 'This coupon is scheduled for a future campaign and is not active yet', reason: 'COUPON_SCHEDULED' });
    }
    if (coupon.status === 'PAUSED' || coupon.isActive === false) {
      return res.status(400).json({ valid: false, error: 'This coupon is currently paused by administrator', reason: 'COUPON_PAUSED' });
    }
    if (coupon.status === 'ARCHIVED') {
      return res.status(400).json({ valid: false, error: 'This coupon is archived and no longer valid', reason: 'COUPON_ARCHIVED' });
    }

    // Tier matching
    const tiers = Array.isArray(coupon.applicableTiers) ? coupon.applicableTiers : ['all'];
    if (!tiers.includes('all') && !tiers.includes(category)) {
      return res.status(400).json({ valid: false, error: `Coupon ${cleanCode} is only applicable to ${tiers.join(', ')}`, reason: 'TIER_MISMATCH' });
    }

    // Min order amount check
    const minAmt = Number(coupon.minOrderAmount) || 0;
    if (minAmt > 0 && plan.monthlyPriceInr < minAmt) {
      return res.status(400).json({ valid: false, error: `Minimum order amount of ₹${minAmt} required to apply ${cleanCode}`, reason: 'MIN_ORDER_NOT_MET' });
    }

    // User eligibility restrictions
    if (coupon.newMembersOnly && req.dbUser) {
      const hist = Array.isArray(req.dbUser.paymentHistory) ? req.dbUser.paymentHistory : [];
      if (hist.some((p) => p.status === 'PAID')) {
        return res.status(400).json({ valid: false, error: 'This coupon is valid for new riders only', reason: 'NEW_MEMBERS_ONLY' });
      }
    }
    if (coupon.firstPaymentOnly && req.dbUser) {
      const hist = Array.isArray(req.dbUser.paymentHistory) ? req.dbUser.paymentHistory : [];
      if (hist.length > 0) {
        return res.status(400).json({ valid: false, error: 'This coupon is valid on first payment only', reason: 'FIRST_PAYMENT_ONLY' });
      }
    }
    if (Array.isArray(coupon.allowedUserIds) && coupon.allowedUserIds.length > 0) {
      if (!coupon.allowedUserIds.includes(uid)) {
        return res.status(400).json({ valid: false, error: 'This coupon is restricted to select members', reason: 'NOT_ELIGIBLE' });
      }
    }

    // Per user usage limit
    const maxPerUser = Number(coupon.maxUsagePerUser) || 1;
    const userRedemptions = (coupon.usages || []).filter((u) => u.userId === uid).length;
    if (userRedemptions >= maxPerUser) {
      return res.status(400).json({ valid: false, error: `You have reached the redemption limit (${maxPerUser}) for coupon ${cleanCode}`, reason: 'PER_USER_LIMIT_REACHED' });
    }

    // Calculate discount
    let discountAmount = 0;
    if (couponMakesFree(coupon, plan.monthlyPriceInr)) {
      discountAmount = plan.monthlyPriceInr;
    } else if (coupon.discountType === 'percentage') {
      let raw = (plan.monthlyPriceInr * Number(coupon.discountValue)) / 100;
      if (coupon.maxDiscountCap && raw > coupon.maxDiscountCap) raw = coupon.maxDiscountCap;
      discountAmount = Math.round(raw);
    } else if (coupon.discountType === 'fixed') {
      let raw = Math.min(plan.monthlyPriceInr, Number(coupon.discountValue) || 0);
      if (coupon.maxDiscountCap && raw > coupon.maxDiscountCap) raw = coupon.maxDiscountCap;
      discountAmount = Math.round(raw);
    }

    const finalAmount = Math.max(0, plan.monthlyPriceInr - discountAmount);
    return res.json({
      valid: true,
      code: coupon.code,
      name: coupon.name || coupon.code,
      campaignName: coupon.campaignName || '',
      discountType: coupon.discountType,
      discountValue: coupon.discountValue,
      maxDiscountCap: coupon.maxDiscountCap,
      discountAmount,
      originalPrice: plan.monthlyPriceInr,
      finalAmount,
      isFree: finalAmount === 0,
      message: `Discount of ₹${discountAmount} applied. Final payable: ₹${finalAmount}`,
    });
  }));

  /**
   * POST /api/membership/activate-free
   * Dedicated, secure zero-payment activation for a 100% coupon record (bound to the plan, once per rider).
   * Does NOT create a Razorpay order or invoke gateway checkout.
   */
  r.post('/membership/activate-free', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { category, couponCode } = req.body || {};

    if (!category) {
      return res.status(400).json({ error: 'category is required', reason: 'BAD_REQUEST' });
    }
    // A free activation always names the coupon that pays for it (no implicit default).
    if (typeof couponCode !== 'string' || !couponCode.trim()) {
      return res.status(400).json({ error: 'couponCode is required for a free activation', reason: 'COUPON_REQUIRED' });
    }

    const catalog = await repo.getMembershipCatalog();
    const plan = catalog[category];
    if (!plan) {
      return res.status(400).json({ error: 'Invalid membership category', reason: 'INVALID_CATEGORY' });
    }
    if (!planOnSale(plan)) {
      return res.status(400).json({ error: `${plan.name || category} is not on sale right now`, reason: 'PLAN_INACTIVE' });
    }

    if (!acquireUserTransactionLock(uid, 'activate_free')) {
      return res.status(409).json({ error: 'A membership transaction is already in progress. Please wait.', reason: 'CONCURRENT_TRANSACTION' });
    }

    try {
      const now = Date.now();
      const cleanCoupon = String(couponCode).trim().toUpperCase();

      const existing = await repo.findMembershipByOwner(uid);
      // Idempotency first: a repeat tap for the plan the rider already has neither stacks months nor
      // spends another redemption of the coupon.
      if (existing && existing.status === 'ACTIVE' && existing.category === category && existing.validUntil > now) {
        return res.json({
          success: true,
          message: `You already have an active ${existing.categoryName} membership.`,
          membership: existing,
          isAlreadyActive: true,
        });
      }

      // Every free activation is paid for by a real coupon record (no built-in shortcut codes).
      const matchedCoupon = await repo.findCoupon(cleanCoupon);
      if (!matchedCoupon) {
        return res.status(404).json({ error: `Coupon ${cleanCoupon} not found`, reason: 'COUPON_NOT_FOUND' });
      }
      const block = freeCouponBlock(matchedCoupon, { uid, userDoc: req.dbUser, category, plan });
      if (block) return res.status(400).json(block);

      if (existing && existing.members && Object.keys(existing.members).length + 1 > plan.capacity) {
        return res.status(409).json({
          error: `Cannot switch to ${plan.name}: current group has ${Object.keys(existing.members).length + 1} members which exceeds new capacity of ${plan.capacity}. Please remove members first.`,
          reason: 'CAPACITY_CONFLICT',
        });
      }

      const isUpgrade = existing && existing.status === 'ACTIVE' && existing.category !== category;
      const orderId = `mem_free_${now}_${crypto.randomBytes(4).toString('hex')}`;
      const durationDays = plan.billingPeriodDays || 30;
      const validUntil = now + durationDays * 86400000;

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
        offerCode: cleanCoupon,
        method: 'COUPON',
        transactionType: isUpgrade ? 'UPGRADE' : 'COUPON_ACTIVATION',
        createdAt: now,
        paidAt: now,
      };
      await repo.saveRazorpayOrder(orderDoc);

      const membershipId = existing ? existing.membershipId : `mem_${crypto.randomUUID()}`;
      const upgradeHistory = Array.isArray(existing?.upgradeHistory) ? [...existing.upgradeHistory] : [];
      if (isUpgrade) {
        upgradeHistory.push({
          fromCategory: existing.category,
          toCategory: category,
          upgradedAt: now,
          orderId,
          method: 'COUPON',
          couponCode: cleanCoupon,
        });
      }

      const membershipDoc = {
        membershipId,
        ownerUserId: uid,
        ownerName: req.dbUser?.name || existing?.ownerName || 'Rider',
        ownerEmail: req.dbUser?.email || existing?.ownerEmail || '',
        category,
        categoryName: plan.name,
        capacity: plan.capacity,
        minCapacity: plan.minCapacity || 1,
        maxCapacity: plan.maxCapacity || plan.capacity,
        priceInr: plan.monthlyPriceInr,
        status: 'ACTIVE',
        validFrom: now,
        validUntil,
        members: existing ? (existing.members || {}) : {},
        offerApplied: cleanCoupon,
        paymentId: `free_${orderId}`,
        orderId,
        upgradeHistory,
        createdAt: existing ? existing.createdAt : now,
        updatedAt: now,
      };
      await repo.saveMembership(membershipDoc);

      if (req.dbUser) {
        const history = Array.isArray(req.dbUser.paymentHistory) ? [...req.dbUser.paymentHistory] : [];
        const entry = {
          orderId,
          paymentId: `free_${orderId}`,
          amountInr: 0,
          category,
          categoryName: plan.name,
          method: 'COUPON',
          status: 'PAID',
          paidAt: now,
          validUntil,
          isFree: true,
          transactionType: isUpgrade ? 'UPGRADE' : 'COUPON_ACTIVATION',
          source: 'zero_amount_activation',
        };
        history.push(entry);
        await repo.updateUser(req.dbUser.key, {
          lastPayment: entry,
          paymentHistory: history,
        });
      }

      // Counts the redemption (redemption row + coupon usage) so the per-rider and total limits hold.
      if (typeof repo.confirmCouponRedemption === 'function') {
        await repo.confirmCouponRedemption(orderId, {
          paymentId: `free_${orderId}`,
          method: 'COUPON',
          paidAt: now,
          userDoc: req.dbUser,
        });
      } else if (typeof repo.recordCouponUsage === 'function') {
        await repo.recordCouponUsage(matchedCoupon.code, { userId: uid, orderId, discountAmount: plan.monthlyPriceInr });
      }

      return res.status(201).json({
        success: true,
        message: 'Membership activated successfully',
        membership: membershipDoc,
        orderId,
        transactionType: isUpgrade ? 'UPGRADE' : 'NEW',
      });
    } finally {
      releaseUserTransactionLock(uid);
    }
  }));

  /**
   * POST /api/membership/order
   * Initiates payment order creation on backend. Orders a 100% coupon pays for in full are activated immediately.
   */
  r.post('/membership/order', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { category, offerCode } = req.body || {};

    const catalog = await repo.getMembershipCatalog();
    const plan = catalog[category];
    if (!plan) {
      return res.status(400).json({ error: 'Invalid membership category', reason: 'INVALID_CATEGORY' });
    }
    if (!planOnSale(plan)) {
      return res.status(400).json({ error: `${plan.name || category} is not on sale right now`, reason: 'PLAN_INACTIVE' });
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

    let matchedCoupon = null;
    if (offerCode) {
      const cleanOffer = String(offerCode).trim().toUpperCase();
      if (typeof repo.findCoupon === 'function') {
        const coup = await repo.findCoupon(cleanOffer);
        if (coup) {
          matchedCoupon = coup;
          // Validate status
          if (coup.status === 'USAGE_LIMIT_REACHED') {
            return res.status(400).json({ error: 'This coupon has reached its total usage limit', reason: 'COUPON_LIMIT_REACHED' });
          }
          if (coup.status === 'EXPIRED') {
            return res.status(400).json({ error: 'This coupon has expired', reason: 'COUPON_EXPIRED' });
          }
          if (coup.status === 'SCHEDULED') {
            return res.status(400).json({ error: 'This coupon is not active yet', reason: 'COUPON_SCHEDULED' });
          }
          if (coup.status === 'ARCHIVED') {
            return res.status(400).json({ error: 'This coupon is no longer available', reason: 'COUPON_ARCHIVED' });
          }
          if (coup.status === 'PAUSED' || coup.isActive === false) {
            return res.status(400).json({ error: 'This coupon is currently paused', reason: 'COUPON_PAUSED' });
          }

          // Plan tier validation
          const tiers = Array.isArray(coup.applicableTiers) ? coup.applicableTiers : ['all'];
          if (!tiers.includes('all') && !tiers.includes(category)) {
            return res.status(400).json({ error: `Coupon ${cleanOffer} is not valid for ${plan.name}`, reason: 'TIER_MISMATCH' });
          }

          // Min order amount
          const minAmt = Number(coup.minOrderAmount) || 0;
          if (minAmt > 0 && plan.monthlyPriceInr < minAmt) {
            return res.status(400).json({ error: `Minimum order amount of ₹${minAmt} required for coupon ${cleanOffer}`, reason: 'MIN_ORDER_NOT_MET' });
          }

          // New members only
          if (coup.newMembersOnly && req.dbUser) {
            const hist = Array.isArray(req.dbUser.paymentHistory) ? req.dbUser.paymentHistory : [];
            if (hist.some((p) => p.status === 'PAID')) {
              return res.status(400).json({ error: 'This coupon is valid for new members only', reason: 'NEW_MEMBERS_ONLY' });
            }
          }

          // First payment only
          if (coup.firstPaymentOnly && req.dbUser) {
            const hist = Array.isArray(req.dbUser.paymentHistory) ? req.dbUser.paymentHistory : [];
            if (hist.length > 0) {
              return res.status(400).json({ error: 'This coupon is valid for your first payment only', reason: 'FIRST_PAYMENT_ONLY' });
            }
          }

          // Allowed users restriction
          if (Array.isArray(coup.allowedUserIds) && coup.allowedUserIds.length > 0) {
            if (!coup.allowedUserIds.includes(uid)) {
              return res.status(400).json({ error: 'This coupon is restricted to select members', reason: 'NOT_ELIGIBLE' });
            }
          }

          // Per-rider redemption limit
          const block = couponRiderBlock(coup, uid, req.dbUser);
          if (block) return res.status(400).json(block);

          appliedOffer = coup.code;
          if (couponMakesFree(coup, plan.monthlyPriceInr)) {
            isFreeActivation = true;
          } else if (coup.discountType === 'percentage') {
            discountPercent = Number(coup.discountValue) || 0;
          } else if (coup.discountType === 'fixed') {
            discountAmountInr = Number(coup.discountValue) || 0;
          }
        }
      }

      if (!appliedOffer && typeof repo.findOffer === 'function') {
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
      // A code the rider typed that matches no coupon or live offer is refused, never ignored
      // (the rider must not pay full price believing a discount applied).
      if (!appliedOffer) {
        return res.status(404).json({ error: `Coupon ${cleanOffer} does not exist or is no longer valid`, reason: 'COUPON_NOT_FOUND' });
      }
    }

    if (config.paymentsEnabled === false) {
      isFreeActivation = true;
    }

    let finalAmountInr = plan.monthlyPriceInr;
    let actualDiscountInr = 0;

    if (isFreeActivation) {
      finalAmountInr = 0;
      actualDiscountInr = plan.monthlyPriceInr;
    } else if (discountPercent > 0) {
      let rawDiscount = (plan.monthlyPriceInr * discountPercent) / 100;
      if (matchedCoupon && matchedCoupon.maxDiscountCap && rawDiscount > matchedCoupon.maxDiscountCap) {
        rawDiscount = matchedCoupon.maxDiscountCap;
      }
      actualDiscountInr = Math.round(rawDiscount);
      finalAmountInr = Math.max(0, plan.monthlyPriceInr - actualDiscountInr);
    } else if (discountAmountInr > 0) {
      let rawDiscount = Math.min(plan.monthlyPriceInr, discountAmountInr);
      if (matchedCoupon && matchedCoupon.maxDiscountCap && rawDiscount > matchedCoupon.maxDiscountCap) {
        rawDiscount = matchedCoupon.maxDiscountCap;
      }
      actualDiscountInr = Math.round(rawDiscount);
      finalAmountInr = Math.max(0, plan.monthlyPriceInr - actualDiscountInr);
    }

    const orderId = `mem_ord_${Date.now()}_${crypto.randomBytes(4).toString('hex')}`;
    const amountInPaise = finalAmountInr * 100;

    // Already on this plan: a free order neither stacks months nor spends a coupon redemption.
    if (finalAmountInr === 0 && existing && existing.status === 'ACTIVE' && existing.category === category && existing.validUntil > now) {
      return res.json({
        orderId: `mem_free_active`,
        isFree: true,
        amountInr: 0,
        currency: 'INR',
        membership: existing,
        isAlreadyActive: true,
        message: `You already have an active ${existing.categoryName} membership.`,
      });
    }

    // Concurrency-safe coupon reservation for free orders (a ₹0 reservation also counts the usage)
    if (finalAmountInr === 0 && appliedOffer && matchedCoupon && typeof repo.reserveCouponSlot === 'function') {
      const resv = await repo.reserveCouponSlot(matchedCoupon.code, {
        userId: uid,
        orderId,
        category,
        categoryName: plan.name,
        originalPrice: plan.monthlyPriceInr,
        discountAmount: actualDiscountInr,
        finalAmount: 0,
        userDoc: req.dbUser,
      });
      if (!resv.reserved) {
        return res.status(400).json({ error: resv.error || 'Failed to apply coupon', reason: 'COUPON_RESERVATION_FAILED' });
      }
    }

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
        method: 'COUPON',
        transactionType: existing && existing.status === 'ACTIVE' && existing.category !== category ? 'UPGRADE' : 'COUPON_ACTIVATION',
        createdAt: now,
        paidAt: now,
      };
      await repo.saveRazorpayOrder(orderDoc);

      const membership = await activateMembershipFromOrder({
        repo,
        order: orderDoc,
        paymentId: `free_${orderId}`,
        method: 'COUPON',
        source: 'free_offer',
        userDoc: req.dbUser,
      });

      // A coupon's usage was counted by its ₹0 reservation above; an offer counts one redemption.
      if (appliedOffer && !matchedCoupon && typeof repo.recordOfferRedemption === 'function') {
        await repo.recordOfferRedemption(appliedOffer).catch(() => {});
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

    // Concurrency-safe coupon reservation for paid orders using rzpOrder.id
    if (appliedOffer && matchedCoupon && typeof repo.reserveCouponSlot === 'function') {
      const resv = await repo.reserveCouponSlot(matchedCoupon.code, {
        userId: uid,
        orderId: rzpOrder.id,
        category,
        categoryName: plan.name,
        originalPrice: plan.monthlyPriceInr,
        discountAmount: actualDiscountInr,
        finalAmount: finalAmountInr,
        userDoc: req.dbUser,
      });
      if (!resv.reserved) {
        return res.status(400).json({ error: resv.error || 'Failed to apply coupon', reason: 'COUPON_RESERVATION_FAILED' });
      }
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
      if (order.offerCode && typeof repo.releaseCouponReservation === 'function') {
        await repo.releaseCouponReservation(order.orderId);
      }
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

    if (order.offerCode) {
      if (typeof repo.confirmCouponRedemption === 'function') {
        await repo.confirmCouponRedemption(orderId, {
          paymentId,
          method: 'RAZORPAY',
          paidAt: Date.now(),
          userDoc: req.dbUser,
        });
      } else if (typeof repo.recordCouponUsage === 'function') {
        await repo.recordCouponUsage(order.offerCode, {
          userId: uid,
          orderId,
          discountAmount: order.discountAmount || 0,
        });
      }
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
    if (!planOnSale(plan)) {
      return res.status(400).json({ error: `${plan.name || category} is not on sale right now`, reason: 'PLAN_INACTIVE' });
    }

    const now = Date.now();
    const existing = await repo.findMembershipByOwner(uid);
    if (existing && existing.members && Object.keys(existing.members).length + 1 > plan.capacity) {
      return res.status(409).json({
        error: `Cannot switch to ${plan.name}: current group has ${Object.keys(existing.members).length + 1} members which exceeds new capacity of ${plan.capacity}. Please remove members first.`,
        reason: 'CAPACITY_CONFLICT',
      });
    }

    // Paid activation: the same checks as /membership/verify. The order must be this rider's, for this
    // plan and not yet credited; a replayed signature never extends the membership again.
    if (paymentId || orderId || signature) {
      if (!signature || !orderId || !paymentId) {
        return res.status(400).json({
          error: 'Paid membership activation requires verified Razorpay orderId, paymentId and signature',
          reason: 'PAYMENT_SIGNATURE_REQUIRED',
        });
      }
      const order = await repo.findRazorpayOrder(orderId);
      if (!order) return res.status(404).json({ error: 'Order not found in ledger', reason: 'ORDER_NOT_FOUND' });
      if (order.userId !== uid) return res.status(403).json({ error: 'Order does not belong to this user', reason: 'ORDER_USER_MISMATCH' });
      if (order.category !== category) return res.status(400).json({ error: 'Order was created for a different plan', reason: 'ORDER_PLAN_MISMATCH' });
      if (order.status === 'PAID') {
        return res.json({ message: 'Order already processed and membership active', membership: existing, isAlreadyActive: true });
      }
      if (typeof repo.findRazorpayOrderByPaymentId === 'function') {
        const byPayment = await repo.findRazorpayOrderByPaymentId(paymentId);
        if (byPayment && byPayment.orderId !== order.orderId) {
          return res.status(409).json({ error: 'This payment has already been credited to another order. Replay rejected.', reason: 'REPLAY_ATTACK_DETECTED' });
        }
      }
      const isValid = await getRazorpayGateway(repo).verifySignature({ orderId, paymentId, signature, mode: order.mode });
      if (!isValid) {
        return res.status(400).json({ error: 'Invalid payment signature. Verification failed.', reason: 'INVALID_PAYMENT_SIGNATURE' });
      }
      const membership = await activateMembershipFromOrder({ repo, order, paymentId, method: 'RAZORPAY', source: 'purchase', userDoc: req.dbUser });
      if (order.offerCode && typeof repo.confirmCouponRedemption === 'function') {
        await repo.confirmCouponRedemption(orderId, { paymentId, method: 'RAZORPAY', paidAt: Date.now(), userDoc: req.dbUser });
      }
      return res.status(existing ? 200 : 201).json({ message: 'Membership activated successfully', membership });
    }

    // Free activation: a 100% coupon record or free offer (or payments switched off). Never stacks months.
    if (existing && existing.status === 'ACTIVE' && existing.category === category && existing.validUntil > now) {
      return res.json({ message: `You already have an active ${existing.categoryName} membership.`, membership: existing, isAlreadyActive: true });
    }
    let coupon = null;
    let offerId = null;
    if (offerCode) {
      const cleanOffer = String(offerCode).trim().toUpperCase();
      coupon = typeof repo.findCoupon === 'function' ? await repo.findCoupon(cleanOffer) : null;
      if (coupon) {
        const block = freeCouponBlock(coupon, { uid, userDoc: req.dbUser, category, plan });
        if (block) return res.status(400).json(block);
      } else if (typeof repo.findOffer === 'function') {
        const off = await repo.findOffer(cleanOffer);
        if (off && off.isActive !== false && (!off.expiresAt || off.expiresAt > now) && (off.discountPercent === 100 || off.discountType === 'free')) {
          offerId = off.id;
        }
      }
      if (!coupon && !offerId) {
        return res.status(404).json({ error: `Coupon ${cleanOffer} does not exist or is no longer valid`, reason: 'COUPON_NOT_FOUND' });
      }
    } else if (config.paymentsEnabled !== false && plan.monthlyPriceInr > 0) {
      return res.status(402).json({
        error: 'Payment required to activate this membership category',
        reason: 'PAYMENT_REQUIRED',
        amountInr: plan.monthlyPriceInr,
      });
    }

    const appliedOffer = coupon ? coupon.code : offerId;
    const freeOrderId = `mem_free_${now}_${crypto.randomBytes(4).toString('hex')}`;
    const orderDoc = {
      orderId: freeOrderId,
      userId: uid,
      category,
      amountInPaise: 0,
      amount: 0,
      currency: 'INR',
      status: 'CREATED',
      mode: 'free',
      isFree: true,
      offerCode: appliedOffer || null,
      originalPrice: plan.monthlyPriceInr,
      discountAmount: plan.monthlyPriceInr,
      method: 'COUPON',
      createdAt: now,
    };
    await repo.saveRazorpayOrder(orderDoc);
    const membership = await activateMembershipFromOrder({
      repo, order: orderDoc, paymentId: `free_${freeOrderId}`, method: 'COUPON', source: 'purchase', userDoc: req.dbUser,
    });
    if (coupon && typeof repo.confirmCouponRedemption === 'function') {
      await repo.confirmCouponRedemption(freeOrderId, { paymentId: `free_${freeOrderId}`, method: 'COUPON', paidAt: now, userDoc: req.dbUser });
    } else if (offerId && typeof repo.recordOfferRedemption === 'function') {
      await repo.recordOfferRedemption(offerId).catch(() => {});
    }

    res.status(existing ? 200 : 201).json({
      message: 'Membership activated successfully',
      membership,
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

    // Safety first: a rider who is on the owner's ride right now is NEVER dropped from it (that would cut
    // them out of the group's SOS network mid-ride). Removal from the membership only stops them joining
    // the owner's live ride again (a rider who is in it stays until they leave or the ride ends).
    const ownerActiveTrip = await repo.getActiveTrip(uid);
    if (ownerActiveTrip && ownerActiveTrip.groupId && convoys && typeof convoys.blockFutureJoin === 'function') {
      try {
        await convoys.blockFutureJoin(ownerActiveTrip.groupId, targetUserId);
      } catch {
        // never in the way of the membership change
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

  const auditAdmin = async (action, target, details = {}) => {
    try {
      if (typeof repo.addAuditEntry === 'function') {
        await repo.addAuditEntry({
          by: req.user?.email || req.user?.userId || 'admin',
          action,
          target,
          details,
          at: Date.now(),
        });
      }
    } catch {
      // ignore
    }
  };

  r.post('/admin/membership/reconcile', requireAdmin, wrap(async (req, res) => {
    const result = await repo.reconcileDuplicateMembershipsAndOrders();
    if (typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({
        by: req.user?.email || req.user?.userId || 'admin',
        action: 'membership.reconcile',
        target: 'all',
        details: result,
        at: Date.now(),
      });
    }
    res.json(result);
  }));

  r.get('/admin/membership/catalog', requireAdmin, wrap(async (req, res) => {
    const catalog = await repo.getMembershipCatalog();
    res.json({ catalog });
  }));

  r.put('/admin/membership/catalog', requireAdmin, wrap(async (req, res) => {
    const { catalog } = req.body || {};
    if (!catalog || typeof catalog !== 'object' || Array.isArray(catalog) || !Object.keys(catalog).length) {
      return res.status(400).json({ error: 'Valid catalog object required.', reason: 'INVALID_CATALOG' });
    }
    // Every plan: an id-like key, a name, a price of ₹0 or more, a duration of 1 to 3660 days,
    // a capacity of 1 or more; features (short strings) and the on-sale toggle are optional.
    for (const [id, c] of Object.entries(catalog)) {
      const bad = (field) => res.status(400).json({ error: `Plan ${id}: invalid ${field}.`, reason: 'INVALID_CATALOG', plan: id, field });
      if (!/^[a-z0-9_]{2,40}$/.test(id) || !c || typeof c !== 'object') return bad('id');
      if (typeof c.name !== 'string' || !c.name.trim()) return bad('name');
      if (!Number.isFinite(Number(c.monthlyPriceInr)) || Number(c.monthlyPriceInr) < 0) return bad('monthlyPriceInr');
      if (c.billingPeriodDays !== undefined && (!Number.isInteger(Number(c.billingPeriodDays)) || Number(c.billingPeriodDays) < 1 || Number(c.billingPeriodDays) > 3660)) return bad('billingPeriodDays');
      if (c.capacity !== undefined && (!Number.isInteger(Number(c.capacity)) || Number(c.capacity) < 1)) return bad('capacity');
      if (c.features !== undefined && (!Array.isArray(c.features) || c.features.length > 30 || c.features.some((f) => typeof f !== 'string' || f.length > 80))) return bad('features');
      if (c.isActive !== undefined && typeof c.isActive !== 'boolean') return bad('isActive');
      c.monthlyPriceInr = Number(c.monthlyPriceInr);
      if (c.billingPeriodDays !== undefined) c.billingPeriodDays = Number(c.billingPeriodDays);
      if (c.capacity !== undefined) c.capacity = Number(c.capacity);
    }
    await repo.setMembershipCatalog(catalog, req.user.email || req.user.userId);
    if (typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({ by: req.user?.email || req.user?.userId || 'admin', action: 'membership.catalog_update', target: 'catalog', details: { catalog }, at: Date.now() });
    }
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

  // ---------- COUPON MANAGEMENT (CRUD, PAUSE, RESUME, STATS) ----------

  // GET/POST/PATCH/DELETE /admin/coupons[/:code] live in subscription_routes.js (registered first,
  // with plan-binding validation and audit). Only pause / resume and the usage report are here.

  r.post('/admin/coupons/:code/pause', requireAdmin, wrap(async (req, res) => {
    const code = String(req.params.code || '').trim().toUpperCase();
    const paused = await repo.pauseCoupon(code, req.user?.email || req.user?.userId || 'admin');
    if (!paused) return res.status(404).json({ error: 'Coupon not found' });

    if (typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({ by: req.user?.email || req.user?.userId || 'admin', action: 'coupon.pause', target: code, at: Date.now() });
    }
    res.json({ success: true, message: `Coupon ${code} paused`, coupon: paused });
  }));

  r.post('/admin/coupons/:code/resume', requireAdmin, wrap(async (req, res) => {
    const code = String(req.params.code || '').trim().toUpperCase();
    const resumed = await repo.resumeCoupon(code, req.user?.email || req.user?.userId || 'admin');
    if (!resumed) return res.status(404).json({ error: 'Coupon not found' });

    if (typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({ by: req.user?.email || req.user?.userId || 'admin', action: 'coupon.resume', target: code, at: Date.now() });
    }
    res.json({ success: true, message: `Coupon ${code} resumed`, coupon: resumed });
  }));

  // ---------- COUPON USAGE & REDEMPTION TRACKING ----------

  r.get('/admin/coupons/usage', requireAdmin, wrap(async (req, res) => {
    const filter = {
      couponCode: req.query.code || req.query.couponCode,
      userId: req.query.userId,
      orderId: req.query.orderId,
      category: req.query.category,
      status: req.query.status,
      from: req.query.from,
      to: req.query.to,
    };
    const limit = Math.min(500, Math.max(1, parseInt(req.query.limit, 10) || 100));
    const allCoupons = await repo.listCoupons(500);
    const redemptions = await repo.listCouponRedemptions(filter, limit);

    // Calculate aggregated metrics
    const allRedemptions = await repo.listCouponRedemptions({}, 5000);
    const successful = allRedemptions.filter((r) => r.status === 'SUCCESS');
    const totalDiscount = successful.reduce((sum, r) => sum + (Number(r.discountAmount) || 0), 0);
    const totalRevenue = successful.reduce((sum, r) => sum + (Number(r.finalAmount) || 0), 0);
    const uniqueUsers = new Set(successful.map((r) => r.userId)).size;

    res.json({
      summary: {
        totalCoupons: allCoupons.length,
        activeCoupons: allCoupons.filter((c) => c.status === 'ACTIVE').length,
        totalRedemptions: successful.length,
        totalDiscountGivenInr: Math.round(totalDiscount * 100) / 100,
        revenueGeneratedInr: Math.round(totalRevenue * 100) / 100,
        uniqueUsersCount: uniqueUsers,
      },
      redemptions,
      total: redemptions.length,
    });
  }));

  // ---------- PAYMENT ANALYTICS DASHBOARD ----------

  const handleAnalytics = wrap(async (req, res) => {
    const range = String(req.query.range || '30d');
    const analytics = await repo.getMembershipPaymentAnalytics({
      range,
      from: req.query.from,
      to: req.query.to,
    });
    res.json(analytics);
  });
  r.get('/admin/payments/analytics', requireAdmin, handleAnalytics);
  r.get('/admin/membership/analytics', requireAdmin, handleAnalytics);

  // ---------- SEARCHABLE TRANSACTION HISTORY ----------

  const handleTransactions = wrap(async (req, res) => {
    const search = String(req.query.q || req.query.search || '');
    const status = String(req.query.status || 'ALL');
    const category = String(req.query.category || '');
    const from = req.query.from;
    const to = req.query.to;
    const limit = Math.min(200, Math.max(1, parseInt(req.query.limit, 10) || 50));
    const cursor = Math.max(0, parseInt(req.query.cursor, 10) || 0);

    const result = await repo.listTransactions({
      search,
      status,
      category,
      from,
      to,
      limit,
      cursor,
    });
    // For backwards compatibility with older admin tests that expect { payments: [...] }
    res.json({
      ...result,
      payments: result.transactions,
    });
  });
  r.get('/admin/payments/history', requireAdmin, handleTransactions);
  r.get('/admin/membership/payments', requireAdmin, handleTransactions);

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

    if (typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({
        by: req.user?.email || req.user?.userId || 'admin',
        action: 'payment.refund',
        target: order.orderId,
        details: { refundId: refund.id, amountInPaise, fullyRefunded, reason },
        at: Date.now(),
      });
    }

    res.json({
      ok: true,
      refundId: refund.id,
      refundStatus: refund.status || 'PROCESSED',
      fullyRefunded,
      orderId: order.orderId,
    });
  }));

  // ---------- POST-TRIP REVIEWS (rider) ----------
  // Only a rider who took part in a trip that has ended may review it; one review per rider per
  // trip (a second submission updates the first and sends it back to moderation).
  const reviewLimiter = rateLimit({
    windowMs: 60 * 60 * 1000,
    limit: 12,
    skipFailedRequests: true, // refused attempts are covered by the general API limit
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    keyGenerator: (req) => `review:${req.user?.userId || req.ip}`,
    message: { error: 'Too many review updates. Please try again later.', code: 'RATE_LIMITED' },
  });
  const sendReviewError = (res, e) => {
    if (!(e instanceof reviews.ReviewError)) throw e;
    return res.status(e.status).json({ error: e.message, code: e.code, ...(e.fields ? { fields: e.fields } : {}) });
  };

  r.post('/trips/:tripId/feedback', reviewLimiter, wrap(async (req, res) => {
    const tripId = String(req.params.tripId || '').trim();
    const userId = req.user.userId;
    let trip, input, reviewTripId, reviewIds;
    try {
      ({ trip, reviewTripId, reviewIds } = await reviews.checkEligibility({ repo, convoys }, tripId, userId));
      input = reviews.validateSubmission(req.body);
    } catch (e) { return sendReviewError(res, e); }

    // The convoy id and the rider's trip record id name the same ride: one review for both.
    const existing = await reviews.findOwnReview(repo, reviewIds, userId);
    const storedTripId = existing ? existing.tripId : reviewTripId;
    const now = Date.now();
    const history = existing ? [...(existing.reviewHistory || [])] : [];
    if (existing) history.push({ action: 'RIDER_UPDATE', by: 'rider', at: now, fromStatus: existing.status, toStatus: reviews.STATUS.PENDING });
    // Uploaded photos the rider keeps (only their own, and only with photo consent); the rest are deleted.
    const { keepUploads, ...fields } = input;
    const oldUploads = existing ? reviews.uploadsOf(existing) : [];
    const uploads = oldUploads.filter((u) => keepUploads.includes(u.id));
    for (const u of oldUploads) if (!uploads.includes(u)) photoStore.remove(u);
    const doc = {
      feedbackId: existing ? existing.feedbackId : reviews.stableReviewId(storedTripId, userId),
      tripId: storedTripId,
      userId,
      userName: String(req.user.name || existing?.userName || 'CoRoute Rider').slice(0, 80),
      userEmail: req.user.email || existing?.userEmail || null,
      ...trip,
      ...fields,
      photos: [...fields.photos, ...uploads.map((u) => u.id)].slice(0, reviews.LIMITS.photos),
      uploads,
      photoUrl: fields.photos[0] || null,
      // A changed review goes back to moderation; the admin's earlier excerpt and photo pick were for the old text.
      status: reviews.STATUS.PENDING,
      statusReason: '',
      formattedText: null,
      selectedPhotos: [],
      template: existing?.template || null,
      templateLayout: existing?.templateLayout || null,
      approvedAt: null,
      submittedAt: existing ? existing.submittedAt : now,
      updatedAt: now,
      reviewHistory: history,
    };
    const saved = await repo.addTripFeedback(doc);
    res.status(existing ? 200 : 201).json({ ok: true, updated: !!existing, feedback: reviews.riderView(saved) });
  }));

  // The rider's own review of a trip (status and the admin's reason), and whether they may review it.
  r.get('/trips/:tripId/feedback', wrap(async (req, res) => {
    const tripId = String(req.params.tripId || '').trim();
    const userId = req.user.userId;
    let canReview = true;
    let code = null;
    let ids = reviews.relatedReviewIds(tripId, userId);
    try { ({ reviewIds: ids } = await reviews.checkEligibility({ repo, convoys }, tripId, userId)); }
    catch (e) {
      if (!(e instanceof reviews.ReviewError)) throw e;
      canReview = false;
      code = e.code;
    }
    const mine = await reviews.findOwnReview(repo, ids, userId);
    if (!mine && code === 'NOT_PARTICIPANT') return res.status(403).json({ error: 'Only riders who took part in this trip can review it.', code });
    res.set('Cache-Control', 'no-store').json({ ok: true, canReview, code, feedback: reviews.riderView(mine) });
  }));

  // ---------- Review photos (rider) ----------
  // POST /api/trips/:tripId/feedback/photos with the raw image bytes as the body (Content-Type
  // image/jpeg, image/png, image/webp or application/octet-stream), one photo per request, after the
  // review itself was sent with consentPhoto: true. Same eligibility as the review; at most
  // MAX_PER_REVIEW photos, 2 MB each; JPEG/PNG/WebP recognised by their bytes; location and camera
  // metadata removed before the file is stored. The review goes back to moderation.
  const photoLimiter = rateLimit({
    windowMs: 60 * 60 * 1000,
    limit: 30,
    skipFailedRequests: true,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    keyGenerator: (req) => `review-photo:${req.user?.userId || req.ip}`,
    message: { error: 'Too many photo uploads. Please try again later.', code: 'RATE_LIMITED' },
  });
  const rawPhoto = require('express').raw({ type: () => true, limit: reviewPhotos.MAX_BYTES });
  const photoBody = (req, res, next) => {
    if (req.is('application/json') || req.is('multipart/form-data')) {
      return res.status(415).json({ error: 'Send the photo bytes as image/jpeg, image/png or image/webp.', code: 'UNSUPPORTED_PHOTO' });
    }
    rawPhoto(req, res, (err) => {
      if (!err) return next();
      if (err.type === 'entity.too.large') return res.status(413).json({ error: 'This photo is too large. Please pick a smaller one (up to 2 MB).', code: 'PHOTO_TOO_LARGE' });
      return res.status(400).json({ error: 'The photo did not arrive complete. Please try again.', code: 'NO_PHOTO' });
    });
  };
  r.post('/trips/:tripId/feedback/photos', photoLimiter, photoBody, wrap(async (req, res) => {
    const tripId = String(req.params.tripId || '').trim();
    const userId = req.user.userId;
    let reviewIds;
    try { ({ reviewIds } = await reviews.checkEligibility({ repo, convoys }, tripId, userId)); }
    catch (e) { return sendReviewError(res, e); }
    const mine = await reviews.findOwnReview(repo, reviewIds, userId);
    if (!mine || mine.status === reviews.STATUS.WITHDRAWN) {
      return res.status(409).json({ error: 'Send your review first, then add photos.', code: 'REVIEW_REQUIRED' });
    }
    if (mine.consentPhoto !== true || !reviews.publishConsent(mine)) {
      return res.status(409).json({ error: 'Tick the box that lets CoRoute publish your photo and story first.', code: 'PHOTO_CONSENT_REQUIRED' });
    }
    const current = reviews.uploadsOf(mine);
    const allPhotos = Array.isArray(mine.photos) ? mine.photos : [];
    if (current.length >= reviewPhotos.MAX_PER_REVIEW || allPhotos.length >= reviews.LIMITS.photos) {
      return res.status(409).json({ error: `You can add up to ${reviewPhotos.MAX_PER_REVIEW} photos.`, code: 'TOO_MANY_PHOTOS' });
    }
    let prepared;
    try { prepared = reviewPhotos.preparePhoto(req.body); }
    catch (e) {
      if (!(e instanceof reviewPhotos.PhotoError)) throw e;
      return res.status(e.status).json({ error: e.message, code: e.code });
    }
    const meta = await photoStore.save(prepared);
    const now = Date.now();
    const patch = {
      photos: [...allPhotos, meta.id],
      uploads: [...current, meta],
      status: reviews.STATUS.PENDING,
      statusReason: '',
      approvedAt: null,
    };
    const updated = await repo.updateTripFeedbackReview(mine.feedbackId, patch,
      { action: 'RIDER_PHOTO', by: 'rider', at: now, fromStatus: mine.status, toStatus: reviews.STATUS.PENDING });
    if (!updated) { await photoStore.remove(meta); return res.status(404).json({ error: 'No review for this trip.', code: 'NO_REVIEW' }); }
    res.status(201).json({
      ok: true,
      photo: { id: meta.id, mime: meta.mime, bytes: meta.bytes, width: meta.width, height: meta.height },
      feedback: reviews.riderView(updated),
    });
  }));

  // The rider's own uploaded photo (to show it while editing the review). Never cached.
  r.get('/trips/:tripId/feedback/photos/:photoId', wrap(async (req, res) => {
    const photoId = String(req.params.photoId || '');
    if (!reviewPhotos.isPhotoId(photoId)) return sendReviewPhoto(res, null);
    const userId = req.user.userId;
    const mine = await reviews.findOwnReview(repo, reviews.relatedReviewIds(String(req.params.tripId || '').trim(), userId), userId);
    const meta = mine && mine.userId === userId ? reviews.uploadsOf(mine).find((u) => u.id === photoId) : null;
    return sendReviewPhoto(res, meta, 'private, no-store');
  }));

  // The rider takes their review down (it leaves the website at once).
  r.delete('/trips/:tripId/feedback', reviewLimiter, wrap(async (req, res) => {
    const mine = await reviews.findOwnReview(repo, reviews.relatedReviewIds(String(req.params.tripId || '').trim(), req.user.userId), req.user.userId);
    if (!mine) return res.status(404).json({ error: 'No review for this trip.', code: 'NO_REVIEW' });
    const updated = await repo.updateTripFeedbackReview(mine.feedbackId, { status: reviews.STATUS.WITHDRAWN, statusReason: 'Withdrawn by you.' },
      { action: 'RIDER_WITHDRAW', by: 'rider', at: Date.now(), fromStatus: mine.status, toStatus: reviews.STATUS.WITHDRAWN });
    res.json({ ok: true, feedback: reviews.riderView(updated) });
  }));

  // ---------- ADMIN COMMUNITY STATS CONFIGURATION ----------
  r.get('/admin/community-stats/config', requireAdmin, wrap(async (req, res) => {
    const config = await repo.getCommunityStatsConfig();
    const stats = await repo.getCommunityStats();
    res.json({ config, stats });
  }));

  r.put('/admin/community-stats/config', requireAdmin, wrap(async (req, res) => {
    const body = req.body || {};
    const updated = await repo.setCommunityStatsConfig({
      showPublicStats: body.showPublicStats !== undefined ? Boolean(body.showPublicStats) : true,
      showLongestTrips: body.showLongestTrips !== undefined ? Boolean(body.showLongestTrips) : true,
      showAnonymousLabels: body.showAnonymousLabels !== undefined ? Boolean(body.showAnonymousLabels) : true,
      labelPrefix: body.labelPrefix ? String(body.labelPrefix).slice(0, 30) : 'Rider',
    }, req.user?.email || req.user?.userId || 'admin');

    if (typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({
        by: req.user?.email || req.user?.userId || 'admin',
        action: 'community_stats.config_update',
        target: 'community_stats_config',
        details: { config: updated },
        at: Date.now(),
      });
    }

    res.json({ ok: true, config: updated });
  }));

  // ---------- ADMIN REVIEW MODERATION ----------
  // GET /admin/feedback (website messages and reviews together, for older admin builds) lives in routes.js.
  const reviewSummary = (items) => ({
    total: items.length,
    pending: items.filter((f) => f.status === reviews.STATUS.PENDING).length,
    approved: items.filter((f) => f.status === reviews.STATUS.APPROVED).length,
    rejected: items.filter((f) => f.status === reviews.STATUS.REJECTED).length,
    changesRequested: items.filter((f) => f.status === reviews.STATUS.CHANGES_REQUESTED || f.status === 'NEEDS_CLARIFICATION').length,
    withdrawn: items.filter((f) => f.status === reviews.STATUS.WITHDRAWN).length,
    withPhotos: items.filter((f) => Array.isArray(f.photos) && f.photos.length > 0).length,
  });

  r.get('/admin/reviews', requireAdmin, wrap(async (req, res) => {
    const all = await repo.listTripFeedback(500);
    const status = String(req.query.status || '').toUpperCase();
    const items = status ? all.filter((f) => f.status === status || (status === reviews.STATUS.CHANGES_REQUESTED && f.status === 'NEEDS_CLARIFICATION')) : all;
    res.set('Cache-Control', 'no-store').json({ ok: true, summary: reviewSummary(all), templates: reviews.TEMPLATES, reviews: items.map(reviews.adminView) });
  }));

  // Admin: any uploaded photo of a review, whatever its status (to moderate it). Never cached.
  r.get('/admin/reviews/:feedbackId/photos/:photoId', requireAdmin, wrap(async (req, res) => {
    const photoId = String(req.params.photoId || '');
    if (!reviewPhotos.isPhotoId(photoId)) return sendReviewPhoto(res, null);
    const doc = await repo.getTripFeedback(String(req.params.feedbackId || '').trim()).catch(() => null);
    const meta = doc ? reviews.uploadsOf(doc).find((u) => u.id === photoId) : null;
    return sendReviewPhoto(res, meta, 'private, no-store');
  }));

  const moderate = wrap(async (req, res) => {
    const feedbackId = String(req.params.feedbackId || '').trim();
    let m;
    try { m = reviews.validateModeration(req.body); } catch (e) { return sendReviewError(res, e); }
    const current = await repo.getTripFeedback(feedbackId);
    if (!current) return res.status(404).json({ error: 'Review not found.', code: 'NO_REVIEW' });

    const own = Array.isArray(current.photos) ? current.photos : [];
    if (m.selectedPhotos) {
      const unknown = m.selectedPhotos.filter((p) => !own.includes(p));
      if (unknown.length) return res.status(422).json({ error: 'Only the rider\'s own photos can be selected.', code: 'INVALID_MODERATION', fields: { selectedPhotos: 'Pick from the rider\'s photos.' } });
      if (m.selectedPhotos.length && current.consentPhoto !== true) {
        return res.status(409).json({ error: 'The rider did not agree to show their photos.', code: 'PHOTO_CONSENT_REQUIRED' });
      }
    }
    if (m.action === 'APPROVE') {
      if (!reviews.publishConsent(current)) {
        return res.status(409).json({ error: 'The rider did not agree to publish this review, so it cannot be approved for the website.', code: 'CONSENT_REQUIRED' });
      }
      const text = m.formattedText !== undefined ? m.formattedText : (current.formattedText || current.writtenFeedback || '');
      if (!reviews.plainText(text)) return res.status(409).json({ error: 'Add a public excerpt before approving.', code: 'NOTHING_TO_PUBLISH' });
      // The excerpt goes on the public website: no e-mail addresses or phone numbers, even the rider's own.
      const contact = reviews.contactInfoIn(text);
      if (contact) {
        return res.status(422).json({
          error: contact === 'email' ? 'The excerpt contains an e-mail address. Remove it before approving.' : 'The excerpt contains a phone number. Remove it before approving.',
          code: 'EXCERPT_HAS_CONTACT',
          fields: { formattedText: contact === 'email' ? 'Remove the e-mail address.' : 'Remove the phone number.' },
        });
      }
      // A template chosen now must have the photos it shows.
      if (m.template) {
        const def = reviews.templateOf(m.template);
        const sel = (m.selectedPhotos || current.selectedPhotos || []).filter((p) => (current.photos || []).includes(p));
        const usable = current.consentPhoto === true ? sel.length : 0;
        if (usable < def.minPhotos) {
          return res.status(422).json({
            error: `"${def.label}" needs ${def.minPhotos === 1 ? 'a selected photo' : `${def.minPhotos} selected photos`}. Select ${def.minPhotos === 1 ? 'one' : 'more'} or pick another template.`,
            code: 'TEMPLATE_NEEDS_PHOTOS',
            fields: { template: `Needs ${def.minPhotos} selected photo${def.minPhotos === 1 ? '' : 's'}.` },
          });
        }
      }
    }

    const by = req.user?.email || req.user?.userId || 'admin';
    const now = Date.now();
    const patch = {};
    if (m.nextStatus) patch.status = m.nextStatus;
    if (m.formattedText !== undefined) patch.formattedText = m.formattedText;
    if (m.selectedPhotos) patch.selectedPhotos = [...new Set(m.selectedPhotos)];
    if (m.templateLayout) patch.templateLayout = m.templateLayout;
    if (m.template) patch.template = m.template;
    if (m.showTripDetails !== undefined) patch.showTripDetails = m.showTripDetails;
    if (m.action === 'APPROVE') { patch.approvedAt = now; patch.approvedBy = by; patch.statusReason = ''; }
    if (m.action === 'REJECT' || m.action === 'REQUEST_CHANGES' || m.action === 'REQUEST_CLARIFICATION') patch.statusReason = m.reason;
    if (m.action === 'WITHDRAW') patch.statusReason = m.reason || 'Removed from the website by CoRoute.';
    if (m.adminNotes) patch.adminNotes = m.adminNotes;

    const entry = {
      action: m.action,
      by,
      at: now,
      adminNotes: m.adminNotes,
      reason: m.reason,
      fromStatus: current.status,
      toStatus: patch.status || current.status,
    };
    const updated = await repo.updateTripFeedbackReview(feedbackId, patch, entry);
    if (!updated) return res.status(404).json({ error: 'Review not found.', code: 'NO_REVIEW' });

    if (typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({
        by,
        action: `feedback.${m.action.toLowerCase()}`,
        target: feedbackId,
        details: { action: m.action, reason: m.reason, fromStatus: entry.fromStatus, newStatus: updated.status },
        at: now,
      }).catch(() => {});
    }
    res.json({ ok: true, feedback: reviews.adminView(updated) });
  });
  r.put('/admin/feedback/:feedbackId/review', requireAdmin, moderate);
  r.put('/admin/reviews/:feedbackId', requireAdmin, moderate);
}

module.exports = {
  registerMembershipPublicRoutes,
  registerMembershipAuthRoutes,
};
