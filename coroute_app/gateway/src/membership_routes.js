'use strict';
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { createRazorpayGateway } = require('./razorpay_gateway');
const reviews = require('./trip_reviews');
const { safeCommunityStats } = require('./public_privacy');
const reviewPhotos = require('./review_photos');
const { CATALOG_PLANS, COMMUNITY_PLAN, LEGACY_INDIVIDUAL_PLAN, planFrom, entitlementsFor, effectiveMembership, isLegacyMembershipPlan } = require('./entitlements');
const pricing = require('./plan_pricing');

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
  const chk = pricing.checkCoupon(coupon, { uid, userDoc, planId: category, baseInr: plan.monthlyPriceInr });
  if (!chk.ok) return { error: chk.error, reason: chk.reason };
  if (!couponMakesFree(coupon, plan.monthlyPriceInr)) {
    return { error: `Coupon ${coupon.code} does not provide a 100% discount. Payment required.`, reason: 'PARTIAL_COUPON' };
  }
  return null;
}

/** A catalog plan that is switched off is not sold (the admin "active" toggle). Community is never sold. */
const planOnSale = (plan) => !!plan && plan.isActive !== false && plan.id !== COMMUNITY_PLAN && plan.purchasable !== false;

/** Sends the refusal for a plan that cannot be ordered (legacy Individual 410, Community, unknown); true when sent. */
function refusePlan(res, category, catalog) {
  const block = pricing.orderBlock(category, catalog);
  if (!block) return false;
  const { status, ...body } = block;
  res.status(status).json(body);
  return true;
}

/**
 * The price of `category` for this rider now, with the coupon `rawCode` when it applies: the single
 * computation behind the quote, the validation answer and the order. Returns
 * { quote, coupon, couponError } (couponError: { error, reason } when a typed code was refused).
 */
async function priceFor(repo, { uid, userDoc, category, rawCode, catalog, now = Date.now() }) {
  const plan = catalog[category];
  const membership = await repo.findMembershipByOwner(uid).catch(() => null);
  let coupon = null;
  let couponError = null;
  let couponDiscount = 0;
  const clean = typeof rawCode === 'string' ? rawCode.trim().toUpperCase() : '';
  if (clean) {
    const found = typeof repo.findCoupon === 'function' ? await repo.findCoupon(clean).catch(() => null) : null;
    const chk = pricing.checkCoupon(found, { uid, userDoc, planId: category, baseInr: plan.monthlyPriceInr });
    if (chk.ok) { coupon = found; couponDiscount = chk.discountInr; } else couponError = { code: clean, error: chk.error, reason: chk.reason };
  }
  const quote = pricing.computeQuote({ catalog, planId: category, membership, coupon, couponDiscount, now });
  return { quote, coupon, couponError, membership };
}

/**
 * Activates or extends a membership from a verified or free order.
 * Records the transaction in the user's payment history and updates the ledger order.
 */
async function activateMembershipFromOrder({ repo, order, paymentId, method = 'RAZORPAY', source = 'checkout', userDoc = null, convoys = null }) {
  const uid = order.userId;
  const category = order.category || order.planTier || 'group_small';
  const catalog = await repo.getMembershipCatalog();
  // A legacy Individual order paid before the change still activates (honoured as bought).
  const plan = catalog[category] || (isLegacyMembershipPlan(category)
    ? { ...LEGACY_INDIVIDUAL_PLAN, id: category, monthlyPriceInr: Number(order.amount) || LEGACY_INDIVIDUAL_PLAN.monthlyPriceInr }
    : catalog.group_small);
  const now = Date.now();

  const rawExisting = await repo.findMembershipByOwner(uid);
  const existing = effectiveMembership(rawExisting, now);
  const membershipId = existing ? existing.membershipId : `mem_${crypto.randomUUID()}`;
  const members = existing ? (existing.members || {}) : {};

  const durationDays = plan.billingPeriodDays || 30;
  const isRenewal = existing && existing.status === 'ACTIVE' && existing.category === category;
  const isUpgrade = existing && existing.status === 'ACTIVE' && existing.category !== category;
  // Orders priced by the quote (plan_pricing.js): the period is the quote's, counted from activation.
  const q = order.quote && typeof order.quote === 'object' ? order.quote : null;
  const isDowngrade = !!(q && q.kind === 'downgrade' && existing && existing.status === 'ACTIVE' && existing.validUntil > now);

  let validUntil;
  if (q) {
    validUntil = isDowngrade
      ? (Number(q.endsAt) || existing.validUntil + durationDays * 86400000)
      : now + ((Number(q.billingDays) || durationDays) + (Number(q.extraDays) || 0)) * 86400000;
  } else if (isRenewal) {
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
      ...(q ? { kind: q.kind, creditInr: Number(q.creditInr) || 0, effectiveAt: isDowngrade ? existing.validUntil : now } : {}),
    });
  }
  // What this period cost (list price less coupon): the base of a later upgrade credit.
  const creditBasisInr = q
    ? Math.max(0, (Number(q.basePriceInr) || 0) - (Number(q.couponDiscountInr) || 0))
    : (order.isFree ? 0 : Math.max(0, Number(plan.monthlyPriceInr) || 0));

  if (isDowngrade) {
    // Fewer seats bought during a paid period: the current plan runs to its end, then this one starts.
    const membershipDoc = {
      ...rawExisting,
      validUntil,
      scheduledChange: {
        category,
        categoryName: plan.name,
        capacity: plan.capacity,
        priceInr: plan.monthlyPriceInr,
        creditBasisInr,
        billingPeriodDays: durationDays,
        startsAt: existing.validUntil,
        endsAt: validUntil,
        orderId: order.orderId,
      },
      upgradeHistory,
      updatedAt: now,
    };
    delete membershipDoc.key;
    await repo.saveMembership(membershipDoc);
    await repo.updateRazorpayOrder(order.orderId, {
      status: 'PAID', paymentId: paymentId || order.paymentId, paidAt: now, method, transactionType: 'DOWNGRADE', activatedAt: now, updatedAt: now,
    });
    const user = userDoc || (await repo.findUserById(uid));
    if (user) {
      const history = Array.isArray(user.paymentHistory) ? [...user.paymentHistory] : [];
      const entry = {
        orderId: order.orderId, paymentId: paymentId || order.paymentId || '', amountInr: (Number(order.amountInPaise) || 0) / 100,
        category, categoryName: plan.name, method, status: 'PAID', paidAt: now, validUntil, source, isFree: Boolean(order.isFree),
        transactionType: 'DOWNGRADE', startsAt: existing.validUntil,
      };
      const idx = history.findIndex((h) => h.orderId === order.orderId);
      if (idx >= 0) history[idx] = entry; else history.push(entry);
      await repo.updateUser(user.key, { lastPayment: entry, paymentHistory: history });
    }
    return effectiveMembership(membershipDoc, now);
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
    creditBasisInr,
    billingPeriodDays: durationDays,
    status: 'ACTIVE',
    validFrom: (isUpgrade || q) ? now : (existing ? existing.validFrom : now),
    validUntil,
    scheduledChange: null,
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

  // A host who buys or upgrades during a ride gets the new seats on that ride at once.
  if (convoys && typeof convoys.refreshHostCapacity === 'function') {
    await convoys.refreshHostCapacity(uid).catch(() => {});
  }
  return membershipDoc;
}

/**
 * Public membership routes: catalog, categories and HMAC webhook.
 */
function registerMembershipPublicRoutes({ r, repo, wrap, convoys = null }) {
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
    // Community (free, every rider has it) is listed for display; it is never sold.
    for (const [id, c] of Object.entries(catalog || {})) if (planOnSale(c) || id === COMMUNITY_PLAN) onSale[id] = c;
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
   * Cached for 60s, rate-limited, privacy-safe, zero PII or coordinates: totals only, rounded down with nothing below 10
   * (public_privacy.js), and no per-ride list (the longest trips stay in the admin view).
   */
  let cachedCommunityStats = null;
  let cachedStatsExpiry = 0;

  const handleCommunityStats = wrap(async (req, res) => {
    res.set('Cache-Control', 'public, max-age=60');
    const now = Date.now();
    if (cachedCommunityStats && now < cachedStatsExpiry) {
      return res.json(cachedCommunityStats);
    }
    const stats = safeCommunityStats(await repo.getCommunityStats());
    cachedCommunityStats = stats;
    cachedStatsExpiry = now + 60000;
    res.json(stats);
  });

  const statsLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  r.get('/public/community-stats', statsLimiter, handleCommunityStats);
  r.get('/community-stats', statsLimiter, handleCommunityStats);

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
            convoys,
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
    // The membership as it is now (a downgrade bought earlier starts when the current period ends).
    const owned = effectiveMembership(await repo.findMembershipByOwner(uid), Date.now());
    const allMemberships = await repo.findMembershipsForUser(uid);
    const participating = allMemberships.filter((m) => m.ownerUserId !== uid);
    const activeTrip = await repo.getActiveTrip(uid);
    // One answer for "what may I do": seats to host (host included), until when, and from where.
    const plan = planFrom({ membership: owned, userDoc: req.dbUser || (await repo.findUserById(uid)) });

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
    } else if (plan.canHostGroup || !participating.some((m) => m.status === 'ACTIVE' && m.validUntil > Date.now())) {
      // The rider's own plan: Community (solo), a membership, or a legacy tier until it ends.
      effectiveEntitlements = entitlementsFor(plan, await repo.getMembershipCatalog());
    } else {
      // A Community rider in someone's group: the group features come with that host's plan.
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
      plan: {
        source: plan.source, category: plan.category, name: plan.name, seats: plan.seats,
        validUntil: plan.validUntil, canStartTrip: plan.canStartTrip, canHostGroup: plan.canHostGroup,
        legacyTier: plan.legacyTier, isFree: plan.source === 'community',
        ...(plan.nextPlan ? { nextPlan: plan.nextPlan } : {}),
      },
      effectiveEntitlements,
      paymentsEnabled: config.paymentsEnabled,
    });
  }));

  /**
   * GET /api/membership/quote?plan=group_large&coupon=WELCOME50
   * The price of a plan for this rider now: list price, coupon, upgrade credit for the unused days
   * of the current paid plan, what to pay, and when the new period starts and ends (plan_pricing.js).
   * The order uses the same computation. A refused coupon never blocks the quote: the answer is the
   * full price with `couponError` ({ code, error, reason }) so the app can show it under the field.
   */
  r.get('/membership/quote', wrap(async (req, res) => {
    const uid = req.user.userId;
    const category = String(req.query.plan || req.query.category || '').trim();
    const catalog = await repo.getMembershipCatalog();
    if (refusePlan(res, category, catalog)) return;
    if (!planOnSale(catalog[category])) {
      return res.status(400).json({ error: `${catalog[category].name || category} is not on sale right now`, reason: 'PLAN_INACTIVE' });
    }
    const { quote, couponError } = await priceFor(repo, { uid, userDoc: req.dbUser, category, rawCode: req.query.coupon || req.query.code, catalog });
    res.set('Cache-Control', 'no-store').json({ ...quote, couponError, paymentsEnabled: config.paymentsEnabled });
  }));

  /**
   * POST /api/membership/validate-coupon { code, category }
   * Checks a coupon for a plan and this rider (the same rules as the order) and answers the coupon
   * discount plus the full quote (credit included) the order would charge. A refused code answers
   * 400 { valid: false, error, reason } (404 when the code does not exist).
   */
  r.post('/membership/validate-coupon', wrap(async (req, res) => {
    const uid = req.user.userId;
    const { code } = req.body || {};
    const category = String((req.body || {}).category || (req.body || {}).categoryId || '').trim();
    if (!code || !String(code).trim() || !category) {
      return res.status(400).json({ valid: false, error: 'code and category are required', reason: 'BAD_REQUEST' });
    }
    const catalog = await repo.getMembershipCatalog();
    const block = pricing.orderBlock(category, catalog);
    if (block) {
      const { status, ...body } = block;
      return res.status(status).json({ valid: false, ...body });
    }
    const { quote, coupon, couponError } = await priceFor(repo, { uid, userDoc: req.dbUser, category, rawCode: String(code), catalog });
    if (couponError) {
      return res.status(couponError.reason === 'COUPON_NOT_FOUND' ? 404 : 400).json({ valid: false, error: couponError.error, reason: couponError.reason, quote });
    }
    const base = quote.basePriceInr;
    const discountAmount = quote.couponDiscountInr;
    const finalAmount = Math.max(0, base - discountAmount);
    return res.json({
      valid: true,
      code: coupon.code,
      name: coupon.name || coupon.code,
      campaignName: coupon.campaignName || '',
      discountType: coupon.discountType,
      discountValue: coupon.discountValue,
      maxDiscountCap: coupon.maxDiscountCap,
      discountAmount,
      originalPrice: base,
      finalAmount,
      isFree: finalAmount === 0,
      payableInr: quote.payableInr,
      quote,
      message: discountAmount > 0 ? `${coupon.code}: ₹${discountAmount} off` : `${coupon.code} applied`,
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
    if (refusePlan(res, category, catalog)) return;
    const plan = catalog[category];
    if (!planOnSale(plan)) {
      return res.status(400).json({ error: `${plan.name || category} is not on sale right now`, reason: 'PLAN_INACTIVE' });
    }

    if (!acquireUserTransactionLock(uid, 'activate_free')) {
      return res.status(409).json({ error: 'A membership transaction is already in progress. Please wait.', reason: 'CONCURRENT_TRANSACTION' });
    }

    try {
      const now = Date.now();
      const cleanCoupon = String(couponCode).trim().toUpperCase();

      const existing = effectiveMembership(await repo.findMembershipByOwner(uid), now);
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
      // The same price computation as the order: the coupon pays the whole price, any upgrade credit
      // left over adds days, a downgrade starts when the current paid period ends.
      const quote = pricing.computeQuote({ catalog, planId: category, membership: existing, coupon: matchedCoupon, couponDiscount: plan.monthlyPriceInr, now });

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
        originalPrice: plan.monthlyPriceInr,
        discountAmount: plan.monthlyPriceInr,
        quote,
        createdAt: now,
        paidAt: now,
      };
      await repo.saveRazorpayOrder(orderDoc);
      const membershipDoc = await activateMembershipFromOrder({
        repo, order: orderDoc, paymentId: `free_${orderId}`, method: 'COUPON', source: 'zero_amount_activation', userDoc: req.dbUser, convoys,
      });
      if (isUpgrade && Array.isArray(membershipDoc.upgradeHistory) && membershipDoc.upgradeHistory.length) {
        membershipDoc.upgradeHistory[membershipDoc.upgradeHistory.length - 1].couponCode = cleanCoupon;
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
   * POST /api/membership/order { category, offerCode? }
   * Creates the payment order at the server's own price (plan_pricing.js: list price - coupon -
   * upgrade credit, the same as GET /membership/quote; a client amount is never used). An order
   * that comes to ₹0 (a 100% coupon, or credit covering it) is activated at once, with no payment.
   * A typed code that is refused answers 400/404 with its reason (the app then drops the code and
   * the rider can pay the normal price).
   */
  r.post('/membership/order', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const body = req.body || {};
    const category = String(body.category || body.categoryId || '').trim();
    const offerCode = typeof body.offerCode === 'string' ? body.offerCode : (typeof body.couponCode === 'string' ? body.couponCode : '');

    const catalog = await repo.getMembershipCatalog();
    if (refusePlan(res, category, catalog)) return;
    const plan = catalog[category];
    if (!planOnSale(plan)) {
      return res.status(400).json({ error: `${plan.name || category} is not on sale right now`, reason: 'PLAN_INACTIVE' });
    }

    const now = Date.now();
    const existingRaw = await repo.findMembershipByOwner(uid);
    const existing = effectiveMembership(existingRaw, now);
    // Capacity conflict check on downgrade
    if (existing && existing.members && Object.keys(existing.members).length + 1 > plan.capacity) {
      return res.status(409).json({
        error: `Cannot switch to ${plan.name}: current group has ${Object.keys(existing.members).length + 1} members which exceeds new capacity of ${plan.capacity}. Please remove members first.`,
        reason: 'CAPACITY_CONFLICT',
      });
    }

    let appliedOffer = null;
    let matchedCoupon = null;
    let couponDiscount = 0;
    const cleanOffer = offerCode.trim().toUpperCase();
    if (cleanOffer) {
      const coup = typeof repo.findCoupon === 'function' ? await repo.findCoupon(cleanOffer) : null;
      if (coup) {
        const chk = pricing.checkCoupon(coup, { uid, userDoc: req.dbUser, planId: category, baseInr: plan.monthlyPriceInr });
        if (!chk.ok) return res.status(400).json({ error: chk.error, reason: chk.reason });
        matchedCoupon = coup;
        appliedOffer = coup.code;
        couponDiscount = chk.discountInr;
      } else if (typeof repo.findOffer === 'function') {
        const off = await repo.findOffer(cleanOffer);
        if (off && off.isActive !== false && (!off.expiresAt || off.expiresAt > now)) {
          if (off.discountPercent === 100 || off.discountType === 'free') {
            appliedOffer = off.id;
            couponDiscount = Number(plan.monthlyPriceInr) || 0;
          } else if (off.discountPercent) {
            appliedOffer = off.id;
            couponDiscount = Math.round(((Number(plan.monthlyPriceInr) || 0) * Number(off.discountPercent)) / 100);
          }
        }
      }
      // A code the rider typed that matches no coupon or live offer is refused, never ignored
      // (the rider must not pay full price believing a discount applied).
      if (!appliedOffer) {
        return res.status(404).json({ error: "We couldn't find that code", reason: 'COUPON_NOT_FOUND' });
      }
    }

    let quote = pricing.computeQuote({
      catalog, planId: category, membership: existingRaw, coupon: matchedCoupon || (appliedOffer ? { code: appliedOffer } : null), couponDiscount, now,
    });
    if (config.paymentsEnabled === false) quote = { ...quote, payableInr: 0, isFree: true };
    const finalAmountInr = quote.payableInr;
    const orderId = `mem_ord_${now}_${crypto.randomBytes(4).toString('hex')}`;
    const amountInPaise = finalAmountInr * 100;

    // Already on this plan and nothing to pay: neither stacks months nor spends a coupon redemption.
    if (finalAmountInr === 0 && existing && existing.status === 'ACTIVE' && existing.category === category && existing.validUntil > now) {
      return res.json({
        orderId: `mem_free_active`,
        isFree: true,
        amountInr: 0,
        currency: 'INR',
        membership: existing,
        isAlreadyActive: true,
        quote,
        message: `You already have an active ${existing.categoryName} membership.`,
      });
    }

    const reservation = (rid, final) => ({
      userId: uid,
      orderId: rid,
      category,
      categoryName: plan.name,
      originalPrice: plan.monthlyPriceInr,
      discountAmount: quote.couponDiscountInr,
      finalAmount: final,
      userDoc: req.dbUser,
    });

    if (finalAmountInr === 0) {
      // Concurrency-safe coupon reservation (a ₹0 reservation also counts the usage).
      if (matchedCoupon && typeof repo.reserveCouponSlot === 'function') {
        const resv = await repo.reserveCouponSlot(matchedCoupon.code, reservation(orderId, 0));
        if (!resv.reserved) {
          return res.status(400).json({ error: resv.error || "This code couldn't be applied", reason: 'COUPON_RESERVATION_FAILED' });
        }
      }
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
        method: appliedOffer ? 'COUPON' : 'CREDIT',
        originalPrice: plan.monthlyPriceInr,
        discountAmount: quote.couponDiscountInr,
        creditInr: quote.creditInr,
        quote,
        transactionType: existing && existing.status === 'ACTIVE' && existing.category !== category ? 'UPGRADE' : 'COUPON_ACTIVATION',
        createdAt: now,
        paidAt: now,
      };
      await repo.saveRazorpayOrder(orderDoc);

      const membership = await activateMembershipFromOrder({
        repo,
        order: orderDoc,
        paymentId: `free_${orderId}`,
        method: orderDoc.method,
        source: 'free_offer',
        userDoc: req.dbUser,
        convoys,
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
        quote,
      });
    }

    const gateway = getRazorpayGateway(repo);
    let rzpOrder;
    try {
      rzpOrder = await gateway.createOrder({
        amountInPaise,
        currency: 'INR',
        receipt: orderId.slice(0, 40),
        notes: { userId: uid, category, offerCode: appliedOffer || '', kind: quote.kind, creditInr: String(quote.creditInr) },
      });
    } catch (e) {
      return res.status(e.status || 500).json({ error: e.message, code: e.code || 'GATEWAY_ERROR' });
    }

    // Concurrency-safe coupon reservation for paid orders using rzpOrder.id
    if (matchedCoupon && typeof repo.reserveCouponSlot === 'function') {
      const resv = await repo.reserveCouponSlot(matchedCoupon.code, reservation(rzpOrder.id, finalAmountInr));
      if (!resv.reserved) {
        return res.status(400).json({ error: resv.error || "This code couldn't be applied", reason: 'COUPON_RESERVATION_FAILED' });
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
      originalPrice: plan.monthlyPriceInr,
      discountAmount: quote.couponDiscountInr,
      creditInr: quote.creditInr,
      quote,
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
      quote,
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
      convoys,
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
    // A legacy order paid before the change (orderId + signature) is still credited below.
    const paidLegacyOrder = isLegacyMembershipPlan(category) && orderId && paymentId && signature;
    if (!paidLegacyOrder && refusePlan(res, category, catalog)) return;
    const plan = catalog[category] || { ...LEGACY_INDIVIDUAL_PLAN, id: category };
    if (!paidLegacyOrder && !planOnSale(plan)) {
      return res.status(400).json({ error: `${plan.name || category} is not on sale right now`, reason: 'PLAN_INACTIVE' });
    }

    const now = Date.now();
    const existing = effectiveMembership(await repo.findMembershipByOwner(uid), now);
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
      const membership = await activateMembershipFromOrder({ repo, order, paymentId, method: 'RAZORPAY', source: 'purchase', userDoc: req.dbUser, convoys });
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
      quote: pricing.computeQuote({ catalog, planId: category, membership: await repo.findMembershipByOwner(uid), couponDiscount: plan.monthlyPriceInr, now }),
      createdAt: now,
    };
    await repo.saveRazorpayOrder(orderDoc);
    const membership = await activateMembershipFromOrder({
      repo, order: orderDoc, paymentId: `free_${freeOrderId}`, method: 'COUPON', source: 'purchase', userDoc: req.dbUser, convoys,
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
    // The retired Individual plan sent back by an older admin build is dropped, never stored again.
    delete catalog.individual;
    if (!Object.keys(catalog).length) return res.status(400).json({ error: 'Valid catalog object required.', reason: 'INVALID_CATALOG' });
    const current = await repo.getMembershipCatalog();
    for (const [id, c] of Object.entries(catalog)) {
      const bad = (field) => res.status(400).json({ error: `Plan ${id}: invalid ${field}.`, reason: 'INVALID_CATALOG', plan: id, field });
      // The plans: Community (free, not sold), Small Group and Large Group (legacy tiers are not sold any more).
      if (!CATALOG_PLANS.includes(id) || !c || typeof c !== 'object') return bad('id');
      if (id === COMMUNITY_PLAN) {
        // Community is free for every rider: only its name, description and feature list are editable.
        if (c.description !== undefined && (typeof c.description !== 'string' || c.description.length > 300)) return bad('description');
        if (c.features !== undefined && (!Array.isArray(c.features) || c.features.length > 30 || c.features.some((f) => typeof f !== 'string' || f.length > 80))) return bad('features');
        const base = current.community || {};
        catalog[id] = {
          ...base,
          name: typeof c.name === 'string' && c.name.trim() ? c.name.trim().slice(0, 40) : base.name,
          ...(c.description !== undefined ? { description: c.description.trim() } : {}),
          ...(c.features !== undefined ? { features: c.features.map((f) => f.trim()).filter(Boolean) } : {}),
          id: COMMUNITY_PLAN, monthlyPriceInr: 0, capacity: 1, minCapacity: 1, maxCapacity: 1, purchasable: false, isActive: true,
        };
        continue;
      }
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
    // staffOwner: the plan belongs to a staff account (admin / STAFF_EMAILS), left out of member analytics.
    const staffIds = typeof repo.staffUserIds === 'function' ? await repo.staffUserIds().catch(() => new Set()) : new Set();
    const memberships = all.map((r) => ({ ...r.value, key: r.key, staffOwner: staffIds.has(r.value?.ownerUserId) }))
      .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))
      .slice(0, limit);
    const staffOwned = all.filter((r) => staffIds.has(r.value?.ownerUserId)).length;
    res.json({ memberships, total: all.length, staffOwned });
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
    // Staff redemptions (checkout tests by admins / STAFF_EMAILS) are not counted in the summary.
    const staffIds = typeof repo.staffUserIds === 'function' ? await repo.staffUserIds().catch(() => new Set()) : new Set();
    const successful = allRedemptions.filter((r) => r.status === 'SUCCESS' && !staffIds.has(r.userId));
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
        excludesStaff: true,
        staffRedemptions: allRedemptions.filter((r) => r.status === 'SUCCESS' && staffIds.has(r.userId)).length,
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
