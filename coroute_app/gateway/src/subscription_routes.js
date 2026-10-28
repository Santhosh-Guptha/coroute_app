'use strict';
const express = require('express');
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { createRazorpayGateway, RazorpayError } = require('./razorpay_gateway');
const { effectiveSubscription, isPaidTier } = require('./subscription_lifecycle');

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

// ---------------------------------------------------------------------------
// OFFERS: automatic discounts an admin schedules per tier / cycle. Stored in
// subscription_config (k='offer'). An offer without a linked couponCode is
// applied automatically when the rider gives no coupon; an offer WITH a
// couponCode only advertises that code (the rider enters it). A coupon, when
// given, always wins over an offer: there is no stacking.
// ---------------------------------------------------------------------------
const OFFER_DISCOUNT_TYPES = ['percentage', 'fixed', 'price'];

function offerView(o) {
  return {
    id: o.id, title: o.title || '', description: o.description || '',
    planTier: o.planTier || 'all', billingCycle: o.billingCycle || 'all',
    discountType: o.discountType || 'percentage', discountValue: Number(o.discountValue) || 0,
    startsAt: Number(o.startsAt) || 0, endsAt: Number(o.endsAt) || 0,
    isActive: o.isActive !== false, showOnCheckout: o.showOnCheckout !== false,
    couponCode: o.couponCode || null,
    maxRedemptions: Number(o.maxRedemptions) || 0, redemptions: Number(o.redemptions) || 0,
    createdAt: Number(o.createdAt) || 0, updatedAt: Number(o.updatedAt) || 0, createdBy: o.createdBy || null,
  };
}
/** Public shape (no counters, no author). */
function publicOfferView(o) {
  const v = offerView(o);
  return {
    id: v.id, title: v.title, description: v.description, planTier: v.planTier, billingCycle: v.billingCycle,
    discountType: v.discountType, discountValue: v.discountValue, startsAt: v.startsAt, endsAt: v.endsAt,
    couponCode: v.couponCode, autoApplied: !v.couponCode,
  };
}
/** Active, inside its dates, and not sold out. */
function offerIsLive(o, nowMs = Date.now()) {
  if (!o || o.isActive === false) return false;
  if (Number(o.startsAt) && nowMs < Number(o.startsAt)) return false;
  if (Number(o.endsAt) && nowMs > Number(o.endsAt)) return false;
  if (Number(o.maxRedemptions) > 0 && (Number(o.redemptions) || 0) >= Number(o.maxRedemptions)) return false;
  return true;
}
function offerApplies(o, planTier, billingCycle) {
  const t = o.planTier || 'all';
  const c = o.billingCycle || 'all';
  return (t === 'all' || t === planTier) && (c === 'all' || c === billingCycle);
}
/** Discount in INR for a base amount. An offer never makes an order free (at least ₹1 stays payable). */
function offerDiscount(o, amountInInr) {
  const base = Math.max(0, Number(amountInInr) || 0);
  const v = Math.max(0, Number(o.discountValue) || 0);
  let d = 0;
  if (o.discountType === 'percentage') d = Math.round((base * Math.min(100, v)) / 100);
  else if (o.discountType === 'fixed') d = Math.round(v);
  else if (o.discountType === 'price') d = Math.round(base - v);
  return Math.max(0, Math.min(d, Math.max(0, base - 1)));
}
/** Live, auto-applicable offers for a tier/cycle (newest ending first is irrelevant: we pick the biggest discount). */
async function liveOffers(repo, nowMs = Date.now()) {
  if (!repo || typeof repo.listOffers !== 'function') return [];
  try { return (await repo.listOffers(500)).filter((o) => offerIsLive(o, nowMs)); } catch { return []; }
}
/** The best automatic offer for this order, or null. */
async function bestOffer(repo, { planTier, billingCycle, amountInInr }) {
  if (!isPaidTier(planTier) || !(Number(amountInInr) > 0)) return null;
  const candidates = (await liveOffers(repo)).filter((o) => !o.couponCode && offerApplies(o, planTier, billingCycle));
  let best = null;
  for (const o of candidates) {
    const discountAmount = offerDiscount(o, amountInInr);
    if (discountAmount <= 0) continue;
    if (!best || discountAmount > best.discountAmount) {
      best = { id: o.id, title: o.title || '', discountType: o.discountType, discountValue: Number(o.discountValue) || 0,
        originalAmount: Number(amountInInr), discountAmount, finalAmount: Number(amountInInr) - discountAmount };
    }
  }
  return best;
}
/** What create-order responses carry when an offer was applied. */
function offerResponse(applied) {
  return applied ? { id: applied.id, title: applied.title, discountAmount: applied.discountAmount } : undefined;
}
/** Validates + normalizes an offer document; throws { status: 400, message } on bad input. */
function normalizeOfferInput(body, existing = null) {
  const b = body || {};
  const bad = (m) => { const e = new Error(m); e.status = 400; throw e; };
  const pick = (k, dflt) => (b[k] !== undefined ? b[k] : (existing ? existing[k] : dflt));
  const title = String(pick('title', '') || '').trim();
  if (!title || title.length > 120) bad('title is required (max 120 characters)');
  const description = String(pick('description', '') || '').trim().slice(0, 500);
  const rawTier = pick('planTier', 'all');
  const planTier = rawTier === 'all' || !rawTier ? 'all' : normalizeTier(rawTier);
  if (planTier !== 'all' && !isPaidTier(planTier)) bad('planTier must be all, proRider, roadCaptain or tourOperator');
  const billingCycle = pick('billingCycle', 'all') || 'all';
  if (!['all', 'monthly', 'annual'].includes(billingCycle)) bad('billingCycle must be all, monthly or annual');
  const discountType = pick('discountType', 'percentage') || 'percentage';
  if (!OFFER_DISCOUNT_TYPES.includes(discountType)) bad('discountType must be percentage, fixed or price');
  const discountValue = Number(pick('discountValue', 0));
  if (!Number.isFinite(discountValue) || discountValue <= 0) bad('discountValue must be a positive number');
  if (discountType === 'percentage' && discountValue > 100) bad('Percentage discount cannot exceed 100%');
  const startsAt = Number(pick('startsAt', 0)) || (existing ? Number(existing.startsAt) || Date.now() : Date.now());
  const endsAt = Number(pick('endsAt', 0)) || (existing ? Number(existing.endsAt) || 0 : startsAt + 30 * 86400000);
  if (endsAt && endsAt <= startsAt) bad('endsAt must be after startsAt');
  const isActive = pick('isActive', true) !== false;
  const showOnCheckout = pick('showOnCheckout', true) !== false;
  const rawCoupon = pick('couponCode', null);
  const couponCode = rawCoupon ? String(rawCoupon).trim().toUpperCase() : null;
  if (couponCode && !/^[A-Z0-9_-]{3,20}$/.test(couponCode)) bad('couponCode must be 3-20 alphanumeric characters');
  const maxRedemptions = Math.max(0, Math.round(Number(pick('maxRedemptions', 0)) || 0));
  return { title, description, planTier, billingCycle, discountType, discountValue, startsAt, endsAt, isActive, showOnCheckout, couponCode, maxRedemptions };
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

/** One ledger order as the app / admin sees it (no gateway secrets, no raw payloads). */
function orderView(o) {
  return {
    orderId: o.orderId, userId: o.userId || null, status: o.status || 'CREATED',
    amount: (Number(o.amountInPaise) || 0) / 100, amountInPaise: Number(o.amountInPaise) || 0, currency: o.currency || 'INR',
    mode: o.mode || null, paymentId: o.paymentId || '', utr: o.utr || '', planTier: o.planTier || null, billingCycle: o.billingCycle || null,
    couponCode: o.couponCode || null, offerId: o.offerId || null, offerTitle: o.offerTitle || null, discountAmount: Number(o.discountAmount) || 0,
    channel: o.channel || null, isFree: Boolean(o.isFree), isTest: o.mode === 'test',
    failureReason: o.failureReason || null,
    refundStatus: o.refundStatus || null, refundId: o.refundId || null,
    refundedAmount: (Number(o.refundedAmountInPaise) || 0) / 100, refundedAmountInPaise: Number(o.refundedAmountInPaise) || 0,
    fullyRefunded: Boolean(o.fullyRefunded), refundReason: o.refundReason || null, refundedBy: o.refundedBy || null,
    prorationCreditDays: Number(o.prorationCreditDays) || 0, scheduledStartsAt: Number(o.scheduledStartsAt) || 0,
    createdAt: Number(o.createdAt) || 0, paidAt: Number(o.paidAt) || 0, expiredAt: Number(o.expiredAt) || 0, updatedAt: Number(o.updatedAt) || 0,
  };
}
/** The rider's ledger orders, newest first (who refunded is for admins only). */
async function riderOrders(repo, userId) {
  const rows = await repo.listRazorpayOrders({ userId }, 100);
  return rows.map((o) => { const v = orderView(o); delete v.refundedBy; return v; }).sort((a, b) => b.createdAt - a.createdAt);
}
/** Tier periods (expired / revoked / granted entries), oldest first. */
function periodsOf(userDoc) { return Array.isArray(userDoc?.subscriptionHistory) ? [...userDoc.subscriptionHistory] : []; }

const DAY_MS = 86400000;
const MAX_PRORATION_MS = 365 * DAY_MS;
/** A web checkout link handed out by the app works for this long after the order was created. */
const WEB_CHECKOUT_TTL_MS = 30 * 60 * 1000;

function cyclePeriodMs(cycle) { return cycle === 'annual' ? 365 * DAY_MS : 30 * DAY_MS; }
function cyclePrice(plans, tier, cycle) {
  const m = plans && plans[tier];
  return m ? Number(cycle === 'annual' ? m.annual : m.monthly) || 0 : 0;
}
/** INR per millisecond of [tier] bought on [cycle]. */
function tierRate(plans, tier, cycle) {
  const c = cycle === 'annual' ? 'annual' : 'monthly';
  const p = cyclePrice(plans, tier, c);
  return p > 0 ? p / cyclePeriodMs(c) : 0;
}
/** The cycle the rider last paid [tier] on (monthly when unknown). */
function lastCycleOf(userDoc, tier) {
  const h = Array.isArray(userDoc.paymentHistory) ? userDoc.paymentHistory : [];
  for (let i = h.length - 1; i >= 0; i--) {
    if (h[i].planTier === tier && !h[i].scheduled) return h[i].billingCycle === 'annual' ? 'annual' : 'monthly';
  }
  return 'monthly';
}

/**
 * Grants the plan to the user once per order (idempotent).
 *  - same tier as the running one  -> extends from the current expiry
 *  - dearer tier while one runs    -> the unused value of the running tier becomes extra days on the new one:
 *                                     credit = remainingMs x oldPrice/oldPeriodMs; extraMs = credit / (newPrice/newPeriodMs), max 365 days
 *  - cheaper tier while one runs   -> scheduled: stored as `pendingTier`, starts when the running tier ends (sweeper)
 *  - manual grants never prorate or schedule
 * Prices come from getEffectivePlans (admin pricing).
 */
async function activatePlan({ repo, auth, hub, userDoc, order, paymentId, utr, vpa, method, source }) {
  const planTier = order.planTier;
  const billingCycle = order.billingCycle === 'annual' ? 'annual' : (order.billingCycle === 'manual' ? 'manual' : 'monthly');
  const history = Array.isArray(userDoc.paymentHistory) ? [...userDoc.paymentHistory] : [];
  const prior = history.find((p) => p.orderId === order.orderId);
  if (prior) {
    return {
      tier: userDoc.subscriptionTier, validUntil: userDoc.subscriptionValidUntil, record: prior, already: true,
      scheduled: prior.scheduled ? { tier: prior.planTier, startsAt: prior.validFrom, validUntil: prior.validUntil } : null,
      prorationCreditDays: Number(prior.prorationCreditDays) || 0,
    };
  }
  const now = Date.now();
  if (order.status === 'EXPIRED') {
    // The money was taken and the signature is valid: honour it, but leave a trace.
    console.warn(`[payments] order ${order.orderId} had EXPIRED; signed payment ${paymentId || '-'} accepted via ${source}`);
  }
  const currentExpiry = Number(userDoc.subscriptionValidUntil) || 0;
  const manualDays = billingCycle === 'manual' && Number.isInteger(order.durationDays) && order.durationDays > 0 ? order.durationDays : 0;
  const duration = billingCycle === 'annual' ? 365 * DAY_MS : (manualDays || 30) * DAY_MS;
  const currentTier = isPaidTier(userDoc.subscriptionTier) && currentExpiry > now ? userDoc.subscriptionTier : null;
  const pending = userDoc.pendingTier && isPaidTier(userDoc.pendingTier.tier) ? { ...userDoc.pendingTier } : null;
  let baseTime = now;
  let extraMs = 0;
  let scheduled = null;
  if (currentTier && currentTier === planTier) {
    // Renewing the same tier: paid days are never lost.
    baseTime = currentExpiry;
  } else if (currentTier && billingCycle !== 'manual') {
    const plans = await getEffectivePlans(repo);
    const newRate = tierRate(plans, planTier, billingCycle);
    if (cyclePrice(plans, planTier, 'monthly') < cyclePrice(plans, currentTier, 'monthly')) {
      // Downgrade: the dearer tier keeps running; this one starts when it ends.
      let durationMs = duration;
      if (pending && pending.tier === planTier) {
        durationMs += Number(pending.durationMs) || 0;
      } else if (pending) {
        const pendingRate = tierRate(plans, pending.tier, pending.billingCycle);
        if (pendingRate > 0 && newRate > 0) durationMs += Math.min(MAX_PRORATION_MS, Math.round(((Number(pending.durationMs) || 0) * pendingRate) / newRate));
      }
      scheduled = { tier: planTier, billingCycle, durationMs, startsAt: currentExpiry, orderId: order.orderId, scheduledAt: now };
    } else {
      const oldRate = tierRate(plans, currentTier, lastCycleOf(userDoc, currentTier));
      if (oldRate > 0 && newRate > 0) extraMs = Math.min(MAX_PRORATION_MS, Math.round(((currentExpiry - now) * oldRate) / newRate));
    }
  }
  const prorationCreditDays = Math.round((extraMs / DAY_MS) * 100) / 100;
  const expiry = scheduled ? currentExpiry : baseTime + duration + extraMs;
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
    validFrom: scheduled ? scheduled.startsAt : baseTime,
    validUntil: scheduled ? scheduled.startsAt + scheduled.durationMs : expiry,
    paidAt: now,
    source,
    mode: order.mode || null,
    couponCode: order.couponCode || null,
    offerId: order.offerId || null,
    discountAmount: Number(order.discountAmount) || 0,
    prorationCreditDays,
    scheduled: Boolean(scheduled),
    userSnapshot: {
      userId: userDoc.userId,
      name: userDoc.name || '',
      email: userDoc.email || '',
      phone: userDoc.phone || '',
      callsign: userDoc.callsign || '',
    },
  };
  history.push(record);
  let patch;
  if (scheduled) {
    patch = { lastPayment: record, paymentHistory: history, pendingTier: scheduled };
  } else {
    // A downgrade already queued now starts when the new period ends.
    if (pending) pending.startsAt = expiry;
    patch = {
      subscriptionTier: planTier,
      subscriptionValidUntil: expiry,
      lastPayment: record,
      paymentHistory: history,
      subscriptionWarnedAt: {}, // a fresh period gets fresh 7/3/1-day warnings
      pendingTier: pending || null,
    };
  }
  await repo.updateUser(userDoc.key, patch);
  await repo.updateRazorpayOrder(order.orderId, {
    status: 'PAID', paymentId: paymentId || '', paidAt: now, prorationCreditDays,
    ...(scheduled ? { scheduledStartsAt: scheduled.startsAt } : {}),
    ...(order.status === 'EXPIRED' ? { paidAfterExpiry: true } : {}),
  });
  if (order.couponCode && typeof repo.recordCouponUsage === 'function') {
    await repo.recordCouponUsage(order.couponCode, {
      userId: userDoc.userId, orderId: order.orderId, discountAmount: order.discountAmount || 0,
    }).catch(() => {});
  }
  if (order.offerId && typeof repo.recordOfferRedemption === 'function') {
    await repo.recordOfferRedemption(order.offerId).catch(() => {});
  }
  if (auth && auth.gate) auth.gate.invalidate(userDoc.userId);
  if (hub) {
    if (scheduled) {
      hub.sendToUser(userDoc.userId, { type: 'SUBSCRIPTION_SCHEDULED', tier: planTier, startsAt: scheduled.startsAt, validUntil: record.validUntil, orderId: order.orderId, method });
    } else {
      hub.sendToUser(userDoc.userId, { type: 'SUBSCRIPTION_ACTIVATED', tier: planTier, validUntil: expiry, orderId: order.orderId, method, prorationCreditDays });
    }
  }
  return {
    tier: scheduled ? currentTier : planTier, validUntil: expiry, record, already: false,
    scheduled: scheduled ? { tier: planTier, startsAt: scheduled.startsAt, validUntil: record.validUntil } : null,
    prorationCreditDays,
  };
}

/**
 * Community from now, with a history entry. Used by the admin revoke and by a full refund
 * (reason 'refunded'). keepPending: a scheduled tier the rider paid for separately starts now.
 */
async function revokePlan({ repo, auth, hub, userDoc, by, reason = 'revoked', note = '', keepPending = false }) {
  const now = Date.now();
  const current = effectiveSubscription(userDoc, now);
  const periods = periodsOf(userDoc);
  periods.push({ tier: current.rawTier, validFrom: Number(userDoc.lastPayment?.validFrom) || 0, validUntil: Number(userDoc.subscriptionValidUntil) || 0, endedAt: now, reason, note, by });
  const p = userDoc.pendingTier;
  await repo.updateUser(userDoc.key, {
    subscriptionTier: 'community', subscriptionValidUntil: 0,
    subscriptionExpiredAt: now, previousTier: current.rawTier !== 'community' ? current.rawTier : (userDoc.previousTier || null),
    subscriptionWarnedAt: {}, subscriptionHistory: periods,
    pendingTier: keepPending && p && isPaidTier(p.tier) ? { ...p, startsAt: now } : null,
  });
  if (auth?.gate) auth.gate.invalidate(userDoc.userId);
  if (hub && current.rawTier !== 'community') {
    hub.sendToUser(userDoc.userId, { type: 'SUBSCRIPTION_REVOKED', previousTier: current.rawTier, revokedAt: now, reason: note || reason });
  }
  return current;
}

const REFUND_STATES = { processed: 'PROCESSED', pending: 'PENDING', created: 'PENDING', failed: 'FAILED' };

/**
 * Records one Razorpay refund on the ledger order (idempotent per refund id; a PROCESSED refund
 * never goes back to PENDING). When the order becomes fully refunded the plan it bought is
 * revoked once (history reason 'refunded'); a partial refund keeps the plan.
 * The rider's own payment record gets the refund fields too.
 */
async function recordRefund({ repo, auth, hub, order, refundId, amountInPaise, status, by, reason }) {
  const fresh = (await repo.findRazorpayOrder(order.orderId)) || order;
  const refunds = Array.isArray(fresh.refunds) ? fresh.refunds.map((x) => ({ ...x })) : [];
  let st = REFUND_STATES[String(status || '').toLowerCase()] || 'PENDING';
  let i = refunds.findIndex((x) => x.id === refundId);
  if (i >= 0) {
    if (refunds[i].status === 'PROCESSED' && st === 'PENDING') st = 'PROCESSED';
    refunds[i] = { ...refunds[i], status: st, amountInPaise: Number(amountInPaise) || refunds[i].amountInPaise, updatedAt: Date.now() };
  } else {
    refunds.push({ id: refundId, amountInPaise: Number(amountInPaise) || 0, status: st, at: Date.now(), by: by || null, reason: reason || '' });
    i = refunds.length - 1;
  }
  const counted = refunds.filter((x) => x.status !== 'FAILED');
  const refundedAmountInPaise = counted.reduce((sum, x) => sum + (Number(x.amountInPaise) || 0), 0);
  const fullyRefunded = refundedAmountInPaise > 0 && refundedAmountInPaise >= (Number(fresh.amountInPaise) || 0);
  const refundStatus = refunds.some((x) => x.status === 'PENDING') ? 'PENDING' : (counted.length ? 'PROCESSED' : 'FAILED');
  const latest = refunds[i];
  const patch = {
    refunds, refundId: latest.id, refundStatus, refundedAmountInPaise, refundedAmount: refundedAmountInPaise / 100, fullyRefunded,
    refundedBy: latest.by || fresh.refundedBy || null, refundReason: latest.reason || fresh.refundReason || '',
  };
  let planRevoked = Boolean(fresh.planRevoked);
  if (fullyRefunded && !fresh.refundRevokedAt && fresh.userId) {
    const userDoc = await repo.findUserById(fresh.userId);
    if (userDoc) {
      if (userDoc.pendingTier && userDoc.pendingTier.orderId === fresh.orderId) {
        await repo.updateUser(userDoc.key, { pendingTier: null }); // the scheduled tier never starts
        planRevoked = true;
      } else if (isPaidTier(userDoc.subscriptionTier) && userDoc.subscriptionTier === fresh.planTier) {
        await revokePlan({ repo, auth, hub, userDoc, by: patch.refundedBy || 'razorpay', reason: 'refunded', note: patch.refundReason, keepPending: true });
        planRevoked = true;
      }
    }
    patch.refundRevokedAt = Date.now();
    patch.planRevoked = planRevoked;
  }
  if (fresh.userId) {
    const u = await repo.findUserById(fresh.userId);
    if (u && Array.isArray(u.paymentHistory)) {
      const mirror = { refundStatus, refundId: patch.refundId, refundedAmount: patch.refundedAmount, refundReason: patch.refundReason, fullyRefunded };
      const up = { paymentHistory: u.paymentHistory.map((x) => (x.orderId === fresh.orderId ? { ...x, ...mirror } : x)) };
      if (u.lastPayment && u.lastPayment.orderId === fresh.orderId) up.lastPayment = { ...u.lastPayment, ...mirror };
      await repo.updateUser(u.key, up);
    }
  }
  const updated = await repo.updateRazorpayOrder(fresh.orderId, patch);
  return { ...(updated || { ...fresh, ...patch }), planRevoked };
}

/** Short HMAC that lets the web checkout page load one app order without a login, until expiresAt. */
function webCheckoutToken(orderId, expiresAt) {
  return crypto.createHmac('sha256', config.jwtSecret).update(`web-checkout:${orderId}:${expiresAt}`).digest('hex').slice(0, 32);
}
function webCheckoutTokenValid(orderId, expiresAt, t) {
  const a = Buffer.from(webCheckoutToken(orderId, expiresAt));
  const b = Buffer.from(String(t || ''));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function webCheckoutUrl(req, orderId, expiresAt) {
  const origin = config.publicOrigin || `${req.protocol}://${req.get('host')}`;
  return `${origin}/checkout.html?order=${encodeURIComponent(orderId)}&t=${webCheckoutToken(orderId, expiresAt)}&e=${expiresAt}`;
}

/** After a verified payment: grants the plan to the rider who created the order. */
async function settleVerifiedOrder({ repo, auth, hub, order, paymentId, source }) {
  const userDoc = order.userId ? await repo.findUserById(order.userId) : null;
  if (userDoc) return activatePlan({ repo, auth, hub, userDoc, order, paymentId, method: 'RAZORPAY', source });
  // The account is gone but the money was taken: the ledger still says PAID.
  if (order.status !== 'PAID') await repo.updateRazorpayOrder(order.orderId, { status: 'PAID', paymentId, paidAt: Date.now(), orphaned: true });
  return null;
}

/** One admin write in the audit trail (subscription_config k='audit'). Never throws, never stores a secret. */
async function addAudit(repo, req, action, target, details = {}) {
  if (!repo || typeof repo.addAuditEntry !== 'function') return;
  try {
    await repo.addAuditEntry({
      at: Date.now(), by: req.user?.email || req.user?.userId || 'admin', byUserId: req.user?.userId || null,
      action, target: target == null ? null : String(target), details,
    });
  } catch (e) {
    console.warn('[audit] write failed:', e.message);
  }
}

/**
 * Registers public endpoints: the Razorpay webhook (HMAC-authenticated, deduplicated), coupon
 * check, public config (prices + the active key id, never a secret), the tokenised lookup of an
 * order the app created (web checkout), and the verify / redirect-callback pair that page uses.
 * Orders are only ever created by a signed-in rider (POST /subscription/create-order); the
 * endpoints here accept only those ledger orders (order.userId present).
 */
function registerSubscriptionPublicRoutes({ r, auth, repo, hub, wrap }) {
  const gateway = gatewayFor(repo);
  const perIp = (limit) => rateLimit({ windowMs: 60 * 1000, limit, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests. Try again in a minute.', code: 'RATE_LIMITED' } });
  const checkoutLimiter = perIp(30);
  const callbackLimiter = perIp(30);
  const verifyLimiter = perIp(30);

  // Webhook event ids already handled: the last 1000 in memory, and per ledger order in `webhookEvents`.
  const WEBHOOK_MAX_BYTES = 1024 * 1024;
  const seenIds = new Set();
  const seenQueue = [];
  const remember = (id) => {
    if (!id || seenIds.has(id)) return;
    seenIds.add(id);
    seenQueue.push(id);
    while (seenQueue.length > 1000) seenIds.delete(seenQueue.shift());
  };

  r.post('/subscription/webhook', wrap(async (req, res) => {
    // app.js hands this route the raw bytes (1 MB cap); the signature is over exactly those bytes.
    const rawBuf = Buffer.isBuffer(req.body)
      ? req.body
      : Buffer.from(typeof req.body === 'string' ? req.body : JSON.stringify(req.body || {}), 'utf8');
    if (rawBuf.length > WEBHOOK_MAX_BYTES) return res.status(413).json({ error: 'Payload too large' });
    const rawBody = rawBuf.toString('utf8');
    const signature = req.get('x-razorpay-signature') || '';

    // Always required: an unsigned or wrongly signed webhook is never trusted.
    const mode = await gateway.verifyWebhook(rawBody, signature);
    if (!mode) return res.status(400).json({ error: 'Invalid webhook signature' });

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return res.status(400).json({ error: 'Invalid JSON payload' });
    }
    const eventId = String(req.get('x-razorpay-event-id') || '').trim().slice(0, 100);
    if (eventId && seenIds.has(eventId)) return res.status(200).json({ status: 'duplicate' });

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
      remember(eventId);
      return res.status(200).json({ status: 'duplicate' });
    }

    let handled = false;
    if (order && order.userId && order.mode === mode) {
      if (eventType === 'payment.captured' || eventType === 'order.paid') {
        if (order.status !== 'PAID') {
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
        handled = true;
      } else if (eventType === 'payment.failed') {
        // One failed attempt never overrides a payment that went through.
        if (order.status !== 'PAID') {
          await repo.updateRazorpayOrder(order.orderId, {
            status: 'FAILED',
            failureReason: String(payment.error_description || payment.error_reason || 'Payment failed').slice(0, 300),
            failureCode: String(payment.error_code || '').slice(0, 60),
            lastPaymentId: payment.id || '',
            failedAt: Date.now(),
          });
        }
        handled = true;
      } else if ((eventType === 'refund.processed' || eventType === 'refund.created') && refund && refund.id) {
        await recordRefund({
          repo, auth, hub, order, refundId: refund.id, amountInPaise: Number(refund.amount) || 0,
          status: eventType === 'refund.processed' ? 'processed' : (refund.status || 'pending'),
          by: 'razorpay', reason: String(refund.notes?.reason || '').slice(0, 500),
        });
        handled = true;
      }
    }
    if (order && eventId) {
      const fresh = (await repo.findRazorpayOrder(order.orderId)) || order;
      const events = [...(Array.isArray(fresh.webhookEvents) ? fresh.webhookEvents : []), eventId].slice(-50);
      await repo.updateRazorpayOrder(order.orderId, { webhookEvents: events });
    }
    remember(eventId);
    res.status(200).json({ status: 'ok', handled });
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

  // Public config: plans + the ACTIVE mode's key id (never a secret, no payee details).
  const handleGetConfig = wrap(async (req, res) => {
    const plans = await getEffectivePlans(repo);
    const keys = await gateway.keysFor();
    res.json({
      razorpayKeyId: keys.keyId,
      mode: keys.mode,
      upiOnly: true,
      allowedMethods: ['upi'],
      plans,
    });
  });

  r.get('/subscription/config', handleGetConfig);
  r.get('/api/subscription/config', handleGetConfig);

  // An order the app created, opened on the website to pay by UPI
  // (checkout.html?order=…&t=…&e=…). The token is the only credential: it is bound to the
  // order and to its expiry (30 minutes after the order was created), and reveals plan,
  // amount and the rider's own prefill, never anything else about the account.
  const handleWebOrder = wrap(async (req, res) => {
    const orderId = String(req.params.orderId || '');
    const rawE = String(req.query.e || '');
    const expiresAt = /^\d{10,16}$/.test(rawE) ? Number(rawE) : NaN;
    if (!Number.isFinite(expiresAt) || !webCheckoutTokenValid(orderId, expiresAt, req.query.t)) {
      return res.status(403).json({ error: 'Invalid checkout link' });
    }
    if (Date.now() > expiresAt) return res.status(410).json({ error: 'Link expired — start again in the app' });
    const order = await repo.findRazorpayOrder(orderId);
    if (!order || !order.userId) return res.status(404).json({ error: 'Unknown order' });
    const plans = await getEffectivePlans(repo);
    const keys = await gateway.keysFor(order.mode);
    let prefill = {};
    const u = await repo.findUserById(order.userId);
    if (u) prefill = { name: u.name || '', email: u.email || '', contact: u.phone || '' };
    res.set('Cache-Control', 'no-store').set('Referrer-Policy', 'no-referrer').json({
      order_id: order.orderId,
      amount: order.amountInPaise,
      currency: order.currency || 'INR',
      key_id: keys.keyId,
      mode: order.mode,
      status: order.status,
      planTier: order.planTier,
      planLabel: plans[order.planTier]?.label || order.planTier,
      billingCycle: order.billingCycle,
      merchantName: config.upiMerchantName,
      upiOnly: true,
      expiresAt,
      prefill,
    });
  });
  r.get('/checkout/order/:orderId', checkoutLimiter, handleWebOrder);
  r.get('/api/checkout/order/:orderId', checkoutLimiter, handleWebOrder);

  // ---------------------------------------------------------------------------
  // Verify Signature   POST /api/verify-payment   (web checkout, Razorpay handler)
  // HMAC-SHA256(order_id + "|" + payment_id, KEY_SECRET of the order's mode).
  // Only ledger orders created by a signed-in rider; anything else is a 400.
  // ---------------------------------------------------------------------------
  const handleVerifyPayment = wrap(async (req, res) => {
    const b = req.body || {};
    const orderId = b.razorpay_order_id || b.order_id;
    const paymentId = b.razorpay_payment_id || b.payment_id;
    const signature = b.razorpay_signature || b.signature;

    if (!orderId) return res.status(400).json({ success: false, error: 'Missing required field: order_id is required' });
    const order = await repo.findRazorpayOrder(orderId);
    if (!order || !order.userId) return res.status(400).json({ success: false, error: 'Unknown order' });
    if (order.isFree) return res.status(400).json({ success: false, error: 'Free orders are confirmed in the CoRoute app' });

    if (!paymentId || !signature) {
      return res.status(400).json({ success: false, error: 'Missing required fields: order_id, payment_id, and signature are required' });
    }
    const ok = await gateway.verifySignature({ orderId, paymentId, signature, mode: order.mode });
    // Signature mismatch: 400, NOT marked paid
    if (!ok) {
      if (order.status !== 'PAID') await repo.updateRazorpayOrder(orderId, { status: 'SIGNATURE_MISMATCH', lastPaymentId: paymentId });
      return res.status(400).json({ success: false, error: 'Signature verification failed' });
    }
    const settled = await settleVerifiedOrder({ repo, auth, hub, order, paymentId, source: 'razorpay_checkout_web' });
    return res.status(200).json({
      success: true, message: 'Payment verified successfully', order_id: orderId, payment_id: paymentId, mode: order.mode,
      activated: settled ? { tier: settled.tier, validUntil: settled.validUntil, scheduled: settled.scheduled || undefined } : undefined,
    });
  });

  r.post('/verify-payment', verifyLimiter, handleVerifyPayment);
  r.post('/api/verify-payment', verifyLimiter, handleVerifyPayment);

  // ---------------------------------------------------------------------------
  // Redirect-mode return URL (Checkout `redirect: true` + `callback_url`).
  // Razorpay POSTs the same three fields as a form after the bank page, so a
  // browser that blocks pop-ups (in-app browsers, kiosks) still completes.
  // The signature is checked exactly as above; the user lands back on the
  // checkout page with ?paid=<order> or ?failed=<reason>.
  // ---------------------------------------------------------------------------
  const handleCallback = wrap(async (req, res) => {
    const b = req.body || {};
    const back = (q) => res.redirect(303, `/checkout.html?${q}`);
    const orderId = b.razorpay_order_id || b['error[metadata][order_id]'] || (b.error && b.error.metadata && b.error.metadata.order_id) || '';
    const paymentId = b.razorpay_payment_id || '';
    const signature = b.razorpay_signature || '';
    const errDesc = b['error[description]'] || (b.error && b.error.description) || '';
    if (!orderId || !paymentId || !signature) {
      return back(`failed=${encodeURIComponent(String(errDesc || 'Payment was not completed').slice(0, 200))}&order=${encodeURIComponent(String(orderId).slice(0, 60))}`);
    }
    const order = await repo.findRazorpayOrder(orderId);
    if (!order || !order.userId) return res.status(400).json({ error: 'Unknown order' });
    const ok = await gateway.verifySignature({ orderId, paymentId, signature, mode: order.mode });
    if (!ok) {
      if (order.status !== 'PAID') await repo.updateRazorpayOrder(orderId, { status: 'SIGNATURE_MISMATCH', lastPaymentId: paymentId });
      return back(`failed=${encodeURIComponent('Signature verification failed')}&order=${encodeURIComponent(orderId)}`);
    }
    const settled = await settleVerifiedOrder({ repo, auth, hub, order, paymentId, source: 'razorpay_callback' });
    return back(`paid=${encodeURIComponent(orderId)}&payment=${encodeURIComponent(paymentId)}&mode=${encodeURIComponent(order.mode || '')}` +
      (settled ? `&app=1&tier=${encodeURIComponent(settled.scheduled ? settled.scheduled.tier : settled.tier)}` : '') +
      (settled && settled.scheduled ? `&starts=${settled.scheduled.startsAt}` : ''));
  });
  r.post('/razorpay/callback', callbackLimiter, express.urlencoded({ extended: false, limit: '20kb' }), handleCallback);
  r.post('/api/razorpay/callback', callbackLimiter, express.urlencoded({ extended: false, limit: '20kb' }), handleCallback);
}

/**
 * Registers authenticated subscription routes (requires user JWT)
 * and admin pricing / coupon / payment-gateway routes.
 */
function registerSubscriptionAuthRoutes({ r, auth, repo, hub, wrap, requireAdmin }) {
  const gateway = gatewayFor(repo);

  // Create a Razorpay order for a plan (price decided here, optional coupon). 10 per minute per rider.
  const createOrderLimiter = rateLimit({
    windowMs: 60 * 1000, limit: 10, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => `co:${req.user.userId}`, message: { error: 'Too many orders. Try again in a minute.', code: 'RATE_LIMITED' },
  });
  r.post('/subscription/create-order', createOrderLimiter, wrap(async (req, res) => {
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
    // No coupon: the best live offer for this plan is applied automatically (a coupon always wins; no stacking).
    let appliedOffer = null;
    if (!couponResult) {
      appliedOffer = await bestOffer(repo, { planTier, billingCycle, amountInInr });
      if (appliedOffer) amountInInr = appliedOffer.finalAmount;
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
          offerId: appliedOffer?.id || '',
          discountAmount: couponResult?.discountAmount || appliedOffer?.discountAmount || 0,
          app: 'CoRoute Motorcycle Safety',
        },
      });
    } catch (e) {
      return sendRzpError(res, e);
    }
    const checkoutExpiresAt = Date.now() + WEB_CHECKOUT_TTL_MS;
    await saveOrder(repo, {
      orderId: order.id, userId, planTier, billingCycle, amountInPaise: order.amount,
      couponCode: couponResult?.code || null, discountAmount: couponResult?.discountAmount || appliedOffer?.discountAmount || 0,
      offerId: appliedOffer?.id || null, offerTitle: appliedOffer?.title || null,
      isFree: false, mode: order.mode, channel: 'app', webCheckoutExpiresAt: checkoutExpiresAt,
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

    res.json({
      orderId: order.id,
      amount: amountInInr,
      amountInPaise: order.amount,
      currency: 'INR',
      mode: order.mode,
      // Same order, paid on the website by UPI when the in-app SDK is not usable (link valid 30 minutes).
      webCheckoutUrl: webCheckoutUrl(req, order.id, checkoutExpiresAt),
      webCheckoutExpiresAt: checkoutExpiresAt,
      planTier,
      billingCycle,
      planLabel: planMeta.label,
      razorpayOptions,
      coupon: couponResult || undefined,
      offer: offerResponse(appliedOffer),
    });
  }));

  /**
   * Verify & activate. Plan, cycle and amount come from the order ledger.
   *  - free coupon order          → activated
   *  - paymentId + signature      → HMAC checked with the order's mode secret, then activated
   *                                 (an upgrade is prorated, a downgrade is scheduled; see activatePlan)
   *  - utr only (direct UPI app)  → 410: that path was removed, pay through Razorpay
   */
  r.post('/subscription/verify-payment', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const { orderId, paymentId, signature, utr } = req.body || {};
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
      prorationCreditDays: Number(result.prorationCreditDays) || 0,
      scheduledTier: result.scheduled ? result.scheduled.tier : undefined,
      scheduledStartsAt: result.scheduled ? result.scheduled.startsAt : undefined,
      scheduledValidUntil: result.scheduled ? result.scheduled.validUntil : undefined,
      message: result.scheduled
        ? `${label} starts when your current plan ends.`
        : `${label} successfully activated!`,
    });

    if (order.isFree) {
      const result = await activatePlan({ repo, auth, hub, userDoc, order, paymentId: `coupon_${order.couponCode}`, method: 'COUPON_FREE', source: 'coupon' });
      return done(result, 'COUPON_FREE');
    }

    if (paymentId && signature) {
      const ok = await gateway.verifySignature({ orderId, paymentId, signature, mode: order.mode });
      if (!ok) {
        if (order.status !== 'PAID') await repo.updateRazorpayOrder(orderId, { status: 'SIGNATURE_MISMATCH', lastPaymentId: paymentId });
        return res.status(400).json({ error: 'Payment signature verification failed' });
      }
      const result = await activatePlan({ repo, auth, hub, userDoc, order, paymentId, method: 'RAZORPAY', source: 'razorpay_checkout' });
      return done(result, 'RAZORPAY');
    }

    if (utr) return res.status(410).json({ error: 'Pay with UPI through Razorpay in the app or on the website' });

    return res.status(400).json({ error: 'Missing required fields: paymentId and signature are required' });
  }));

  // Fetch full payment history / audit receipts, tier periods and the rider's orders from the ledger
  r.get('/subscription/history', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const history = Array.isArray(userDoc.paymentHistory)
      ? userDoc.paymentHistory
      : (userDoc.lastPayment ? [userDoc.lastPayment] : []);
    const status = effectiveSubscription(userDoc);
    const orders = await riderOrders(repo, userId);

    res.json({
      userId,
      history,
      totalPayments: history.length,
      currentTier: status.tier,
      validUntil: status.validUntil,
      subscriptionStatus: status,
      subscriptionHistory: periodsOf(userDoc),
      orders,
    });
  }));

  // The rider's orders from the ledger alone, newest first
  r.get('/subscription/orders', wrap(async (req, res) => {
    res.json({ userId: req.user.userId, orders: await riderOrders(repo, req.user.userId) });
  }));

  // Fetch current user subscription status
  r.get('/subscription/status', wrap(async (req, res) => {
    const userId = req.user.userId;
    const userDoc = req.dbUser || (await repo.findUserById(userId));
    if (!userDoc) return res.status(404).json({ error: 'User not found' });

    const status = effectiveSubscription(userDoc);
    const plans = await getEffectivePlans(repo);
    res.json({
      tier: status.tier,
      validUntil: status.validUntil,
      isActive: status.isActive,
      isExpired: status.isExpired,
      daysRemaining: status.daysRemaining,
      expiringSoon: status.expiringSoon,
      previousTier: status.previousTier,
      subscriptionStatus: status,
      lastPayment: userDoc.lastPayment || null,
      paymentHistoryCount: Array.isArray(userDoc.paymentHistory) ? userDoc.paymentHistory.length : (userDoc.lastPayment ? 1 : 0),
      planLabel: plans[status.tier]?.label || 'Community Rider',
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
        const before = await gateway.publicView();
        const view = await gateway.update(req.body || {}, req.user?.email || req.user?.userId || 'admin');
        const b = req.body || {};
        // The audit trail records WHAT changed, never a secret value.
        const changed = (m) => (b[m] && typeof b[m] === 'object' ? {
          keyId: String(b[m].keyId || '').trim() || undefined,
          keySecretChanged: Boolean(String(b[m].keySecret || '').trim()),
          webhookSecretChanged: Boolean(String(b[m].webhookSecret || '').trim()),
        } : undefined);
        await addAudit(repo, req, 'gateway.update', 'razorpay', { modeBefore: before.mode, mode: view.mode, test: changed('test'), live: changed('live') });
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
  }

  // ===========================================================================
  // ADMIN PAYMENTS LEDGER, PER-USER HISTORY, MANUAL GRANT / REVOKE
  // ===========================================================================
  if (requireAdmin) {
    // GET /api/admin/payments?userId=&status=&limit=  -> ledger orders joined with the rider's name/email
    r.get('/admin/payments', requireAdmin, wrap(async (req, res) => {
      const filter = {};
      if (typeof req.query.userId === 'string' && req.query.userId.trim()) filter.userId = req.query.userId.trim();
      if (typeof req.query.status === 'string' && req.query.status.trim()) filter.status = req.query.status.trim().toUpperCase();
      if (typeof req.query.mode === 'string' && ['test', 'live', 'manual'].includes(req.query.mode.trim())) filter.mode = req.query.mode.trim();
      const limit = Math.min(1000, Math.max(1, parseInt(req.query.limit, 10) || 200));
      const offset = Math.max(0, parseInt(req.query.offset, 10) || 0);
      const all = (await repo.listRazorpayOrders(filter, 10000)).sort((a, b) => (Number(b.createdAt) || 0) - (Number(a.createdAt) || 0));
      const rows = all.slice(offset, offset + limit);
      const users = new Map();
      for (const o of rows) {
        if (!o.userId || users.has(o.userId)) continue;
        const u = await repo.findUserById(o.userId).catch(() => null);
        users.set(o.userId, u ? { name: u.name || '', email: u.email || '', callsign: u.callsign || '' } : null);
      }
      res.set('Cache-Control', 'no-store').json({
        payments: rows.map((o) => ({ ...orderView(o), user: users.get(o.userId) || null })),
        total: all.length, offset, limit, hasMore: offset + rows.length < all.length,
      });
    }));

    // GET /api/admin/payments/users/:userId -> paymentHistory + subscriptionHistory + effective status
    r.get('/admin/payments/users/:userId', requireAdmin, wrap(async (req, res) => {
      const userDoc = await repo.findUserById(req.params.userId);
      if (!userDoc) return res.status(404).json({ error: 'User not found' });
      res.set('Cache-Control', 'no-store').json({
        userId: userDoc.userId, name: userDoc.name || '', email: userDoc.email || '',
        subscriptionTier: userDoc.subscriptionTier || 'community',
        subscriptionValidUntil: Number(userDoc.subscriptionValidUntil) || 0,
        subscriptionStatus: effectiveSubscription(userDoc),
        lastPayment: userDoc.lastPayment || null,
        paymentHistory: Array.isArray(userDoc.paymentHistory) ? userDoc.paymentHistory : [],
        subscriptionHistory: periodsOf(userDoc),
        subscriptionWarnedAt: userDoc.subscriptionWarnedAt || {},
        orders: await riderOrders(repo, userDoc.userId),
      });
    }));

    // POST /api/admin/subscription/users/:userId/grant { planTier, days, reason } -> grants / extends manually
    r.post('/admin/subscription/users/:userId/grant', requireAdmin, wrap(async (req, res) => {
      const body = req.body || {};
      const planTier = normalizeTier(body.planTier);
      const days = Number.isInteger(body.days) ? body.days : parseInt(body.days, 10);
      if (!isPaidTier(planTier)) return res.status(400).json({ error: 'planTier must be proRider, roadCaptain or tourOperator' });
      if (!Number.isInteger(days) || days < 1 || days > 3660) return res.status(400).json({ error: 'days must be an integer between 1 and 3660' });
      const reason = typeof body.reason === 'string' ? body.reason.trim().slice(0, 500) : '';
      const userDoc = await repo.findUserById(req.params.userId);
      if (!userDoc) return res.status(404).json({ error: 'User not found' });
      const adminId = req.user?.userId || 'admin';
      const order = {
        orderId: `manual_${Date.now()}_${crypto.randomBytes(3).toString('hex')}`,
        userId: userDoc.userId, planTier, billingCycle: 'manual', durationDays: days,
        amountInPaise: 0, currency: 'INR', mode: 'manual', grantedBy: adminId, reason,
      };
      await saveOrder(repo, order);
      const result = await activatePlan({ repo, auth, hub, userDoc, order, paymentId: order.orderId, method: 'MANUAL', source: `admin_grant:${adminId}` });
      const after = await repo.findUserById(userDoc.userId);
      const periods = periodsOf(after);
      periods.push({ tier: planTier, validFrom: result.record.validFrom, validUntil: result.validUntil, startedAt: Date.now(), reason: 'granted', days, note: reason, by: adminId, orderId: order.orderId });
      await repo.updateUser(after.key, { subscriptionHistory: periods, subscriptionExpiredAt: 0 });
      if (auth?.gate) auth.gate.invalidate(userDoc.userId);
      await addAudit(repo, req, 'subscription.grant', userDoc.userId, { planTier, days, reason, orderId: order.orderId, validUntil: result.validUntil });
      res.json({ success: true, userId: userDoc.userId, orderId: order.orderId, subscriptionTier: result.tier, subscriptionValidUntil: result.validUntil,
        subscriptionStatus: effectiveSubscription({ ...after, subscriptionTier: result.tier, subscriptionValidUntil: result.validUntil }) });
    }));

    // POST /api/admin/subscription/users/:userId/revoke { reason } -> community now
    r.post('/admin/subscription/users/:userId/revoke', requireAdmin, wrap(async (req, res) => {
      const reason = typeof req.body?.reason === 'string' ? req.body.reason.trim().slice(0, 500) : '';
      const userDoc = await repo.findUserById(req.params.userId);
      if (!userDoc) return res.status(404).json({ error: 'User not found' });
      const adminId = req.user?.userId || 'admin';
      const current = await revokePlan({ repo, auth, hub, userDoc, by: adminId, reason: 'revoked', note: reason });
      await addAudit(repo, req, 'subscription.revoke', userDoc.userId, { previousTier: current.rawTier, reason });
      res.json({ success: true, userId: userDoc.userId, subscriptionTier: 'community', previousTier: current.rawTier, subscriptionStatus: effectiveSubscription(await repo.findUserById(userDoc.userId)) });
    }));

    // POST /api/admin/payments/:orderId/refund { amountInPaise?, reason } -> Razorpay refund of the order's payment.
    // Default amount: everything not yet refunded. A FULL refund revokes the plan the order bought; a partial one keeps it.
    r.post('/admin/payments/:orderId/refund', requireAdmin, wrap(async (req, res) => {
      const order = await repo.findRazorpayOrder(req.params.orderId);
      if (!order) return res.status(404).json({ error: 'Order not found' });
      if (order.status !== 'PAID' || !order.paymentId || !['test', 'live'].includes(order.mode) || !(Number(order.amountInPaise) > 0)) {
        return res.status(400).json({ error: 'Only a paid Razorpay order can be refunded' });
      }
      const already = Number(order.refundedAmountInPaise) || 0;
      const remaining = (Number(order.amountInPaise) || 0) - already;
      if (order.fullyRefunded || remaining <= 0) return res.status(400).json({ error: 'This order is already fully refunded' });
      const body = req.body || {};
      const reason = typeof body.reason === 'string' ? body.reason.trim().slice(0, 500) : '';
      const raw = body.amountInPaise;
      const amount = raw === undefined || raw === null || raw === '' ? remaining : Number(raw);
      if (!Number.isInteger(amount) || amount < 100 || amount > remaining) {
        return res.status(400).json({ error: `amountInPaise must be a whole number between 100 and ${remaining}` });
      }
      const by = req.user?.email || req.user?.userId || 'admin';
      let refund;
      try {
        refund = await gateway.refundPayment(order.paymentId, amount, { orderId: order.orderId, reason: reason.slice(0, 250), by }, order.mode);
      } catch (e) {
        return sendRzpError(res, e);
      }
      const updated = await recordRefund({ repo, auth, hub, order, refundId: refund.id, amountInPaise: refund.amount || amount, status: refund.status, by, reason });
      await addAudit(repo, req, 'payment.refund', order.orderId, {
        userId: order.userId || null, amountInPaise: amount, refundId: refund.id, refundStatus: updated.refundStatus,
        full: Boolean(updated.fullyRefunded), planRevoked: Boolean(updated.planRevoked), reason,
      });
      res.set('Cache-Control', 'no-store').json({
        success: true, orderId: order.orderId, refundId: refund.id, refundStatus: updated.refundStatus,
        refundedAmount: (Number(updated.refundedAmountInPaise) || 0) / 100, refundedAmountInPaise: Number(updated.refundedAmountInPaise) || 0,
        fullyRefunded: Boolean(updated.fullyRefunded), planRevoked: Boolean(updated.planRevoked), payment: orderView(updated),
      });
    }));

    // GET /api/admin/payments/export.csv?from=&to= (epoch ms or ISO date, on createdAt) -> the ledger as CSV, oldest first.
    r.get('/admin/payments/export.csv', requireAdmin, wrap(async (req, res) => {
      const parseTime = (v) => {
        if (v === undefined || v === '') return null;
        const s = String(v).trim();
        if (/^\d+$/.test(s)) return Number(s);
        const t = Date.parse(s);
        return Number.isFinite(t) ? t : NaN;
      };
      const from = parseTime(req.query.from);
      const to = parseTime(req.query.to);
      if (Number.isNaN(from) || Number.isNaN(to)) return res.status(400).json({ error: 'from and to must be epoch milliseconds or ISO dates' });
      const rows = (await repo.listRazorpayOrders({}, 100000))
        .filter((o) => (from === null || (Number(o.createdAt) || 0) >= from) && (to === null || (Number(o.createdAt) || 0) <= to))
        .sort((a, b) => (Number(a.createdAt) || 0) - (Number(b.createdAt) || 0));
      const cols = ['orderId', 'userId', 'email', 'planTier', 'billingCycle', 'amount', 'mode', 'status', 'paymentId', 'refundStatus', 'refundedAmount', 'offerId', 'couponCode', 'createdAt', 'paidAt'];
      // Quote every text cell; a leading = + - @ is neutralised so spreadsheets never run it as a formula.
      const cell = (v) => {
        if (v === null || v === undefined) return '';
        if (typeof v === 'number') return String(v);
        let s = String(v);
        if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
        return `"${s.replace(/"/g, '""')}"`;
      };
      const iso = (ms) => (Number(ms) > 0 ? new Date(Number(ms)).toISOString() : '');
      const emails = new Map();
      res.status(200).set({
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': `attachment; filename="coroute-payments-${new Date().toISOString().slice(0, 10)}.csv"`,
        'Cache-Control': 'no-store',
      });
      res.write(cols.join(',') + '\r\n');
      for (const o of rows) {
        if (o.userId && !emails.has(o.userId)) {
          const u = await repo.findUserById(o.userId).catch(() => null);
          emails.set(o.userId, u ? u.email || '' : '');
        }
        const v = orderView(o);
        res.write([
          cell(v.orderId), cell(v.userId), cell(emails.get(o.userId) || ''), cell(v.planTier), cell(v.billingCycle), v.amount, cell(v.mode),
          cell(v.status), cell(v.paymentId), cell(v.refundStatus), v.refundedAmount, cell(v.offerId), cell(v.couponCode), cell(iso(v.createdAt)), cell(iso(v.paidAt)),
        ].join(',') + '\r\n');
      }
      res.end();
    }));

    // GET /api/admin/audit?limit=&action= -> admin writes, newest first.
    r.get('/admin/audit', requireAdmin, wrap(async (req, res) => {
      const limit = Math.min(1000, Math.max(1, parseInt(req.query.limit, 10) || 100));
      const action = typeof req.query.action === 'string' ? req.query.action.trim() : '';
      let entries = typeof repo.listAuditEntries === 'function' ? await repo.listAuditEntries(action ? 5000 : limit) : [];
      if (action) entries = entries.filter((e) => e.action === action || String(e.action || '').startsWith(`${action}.`));
      entries = entries.slice(0, limit).map((e) => ({
        id: e.id, at: Number(e.at) || 0, by: e.by || null, byUserId: e.byUserId || null, action: e.action, target: e.target ?? null, details: e.details || {},
      }));
      res.set('Cache-Control', 'no-store').json({ entries, total: entries.length, limit });
    }));
  }

  // ===========================================================================
  // ADMIN PRICING & COUPON MANAGEMENT ROUTES (Fully Configurable by Admin)
  // ===========================================================================
  if (requireAdmin) {
    // GET /api/admin/subscription/pricing - View current plans & overrides
    r.get('/admin/subscription/pricing', requireAdmin, wrap(async (req, res) => {
      const plans = await getEffectivePlans(repo);
      const doc = typeof repo.getSubscriptionPricingDoc === 'function'
        ? await repo.getSubscriptionPricingDoc().catch(() => null)
        : null;
      const custom = doc ? doc.prices : await repo.getSubscriptionPricing().catch(() => null);
      const history = Array.isArray(doc?.history) ? doc.history.slice(-20).reverse() : [];
      res.set('Cache-Control', 'no-store').json({
        plans,
        isCustomized: Boolean(custom),
        defaultPlans: PLAN_PRICES_INR,
        history,
        updatedAt: Number(doc?.updatedAt) || 0,
        updatedBy: doc?.updatedBy || null,
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

      for (const tier of ['proRider', 'roadCaptain', 'tourOperator']) {
        const m = updated[tier];
        if (!m) continue;
        if (!Number.isFinite(m.monthly) || !Number.isFinite(m.annual) || m.monthly < 1 || m.annual < 1) {
          return res.status(400).json({ error: `${tier}: monthly and annual prices must be positive numbers` });
        }
        if (m.annual < m.monthly) {
          return res.status(400).json({ error: `${tier}: annual price (₹${m.annual}) must be at least the monthly price (₹${m.monthly})` });
        }
      }

      await repo.setSubscriptionPricing(updated, req.user?.email || req.user?.userId || 'admin');
      await addAudit(repo, req, 'pricing.update', 'pricing', { plans: updated });
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
      await addAudit(repo, req, 'coupon.create', cleanCode, { discountType: couponDoc.discountType, discountValue: couponDoc.discountValue, maxUsageTotal: couponDoc.maxUsageTotal, expiresAt: couponDoc.expiresAt });
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
      const changes = { ...patch };
      delete changes.usages; delete changes.key;
      await addAudit(repo, req, 'coupon.update', code, { changes });
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
      await addAudit(repo, req, 'coupon.delete', code, {});
      res.json({
        success: true,
        message: `Coupon ${code} deleted successfully`,
      });
    }));
  }

  // ===========================================================================
  // ADMIN CONSOLE: OVERVIEW, SUBSCRIBERS LIST, OFFERS
  // ===========================================================================
  if (requireAdmin) {
    const DAY = 86400000;
    const emptyRevenue = () => ({ today: 0, last7Days: 0, last30Days: 0, allTime: 0 });
    const startOfToday = (now) => { const d = new Date(now); d.setHours(0, 0, 0, 0); return d.getTime(); };
    const addRevenue = (bucket, amountInr, at, now) => {
      bucket.allTime += amountInr;
      if (at >= now - 30 * DAY) bucket.last30Days += amountInr;
      if (at >= now - 7 * DAY) bucket.last7Days += amountInr;
      if (at >= startOfToday(now)) bucket.today += amountInr;
    };
    const allUsers = async () => (typeof repo.listUsersBySubscription === 'function' ? repo.listUsersBySubscription(null, 10000) : repo.listUsers(10000));
    /** One subscribers-table row. */
    const subscriberRow = (u, now) => {
      const st = effectiveSubscription(u, now);
      const history = Array.isArray(u.paymentHistory) ? u.paymentHistory : (u.lastPayment ? [u.lastPayment] : []);
      const lp = u.lastPayment || null;
      const totalPaid = history.reduce((sum, p) => sum + (Number(p.amount) || 0), 0);
      const state = st.isExpired ? 'expired' : (st.tier === 'community' ? 'community' : (st.expiringSoon ? 'expiring' : 'active'));
      return {
        userId: u.userId, name: u.name || '', email: u.email || '', phone: u.phone || '', callsign: u.callsign || '',
        tier: st.tier, rawTier: st.rawTier, state, previousTier: st.previousTier,
        validUntil: st.validUntil, daysRemaining: st.daysRemaining, expiredAt: st.expiredAt,
        lastPayment: lp ? { paidAt: Number(lp.paidAt) || 0, amount: Number(lp.amount) || 0, method: lp.method || '', orderId: lp.orderId || '', mode: lp.mode || null } : null,
        totalPaid, paymentsCount: history.length, createdAt: Number(u.createdAt) || 0,
      };
    };

    // GET /api/admin/subscription/overview
    r.get('/admin/subscription/overview', requireAdmin, wrap(async (req, res) => {
      const now = Date.now();
      const users = await allUsers();
      const subscribers = { community: 0, proRider: 0, roadCaptain: 0, tourOperator: 0 };
      let active = 0; let expiringIn7Days = 0; let expiredLast30Days = 0;
      for (const u of users) {
        const st = effectiveSubscription(u, now);
        subscribers[st.tier] = (subscribers[st.tier] || 0) + 1;
        if (st.tier !== 'community') { active++; if (st.expiringSoon) expiringIn7Days++; }
        if (st.isExpired && st.expiredAt >= now - 30 * DAY) expiredLast30Days++;
      }
      const orders = await repo.listRazorpayOrders({}, 10000);
      const revenue = emptyRevenue(); const testRevenue = emptyRevenue();
      const pendingClaims = 0; // the direct UPI / UTR path was removed; kept at 0 for older app builds
      let failedSignatures = 0; let paidOrders = 0; let failedPayments = 0; let expiredOrders = 0; let refundedOrders = 0;
      const refunds = { allTime: 0, testAllTime: 0 };
      for (const o of orders) {
        if (o.status === 'SIGNATURE_MISMATCH') failedSignatures++;
        if (o.status === 'FAILED') failedPayments++;
        if (o.status === 'EXPIRED') expiredOrders++;
        if (o.status !== 'PAID') continue;
        const amountInr = (Number(o.amountInPaise) || 0) / 100;
        if (amountInr <= 0) continue;
        paidOrders++;
        const refundedInr = (Number(o.refundedAmountInPaise) || 0) / 100;
        if (refundedInr > 0) {
          refundedOrders++;
          if (o.mode === 'test') refunds.testAllTime += refundedInr; else refunds.allTime += refundedInr;
        }
        // Revenue is net of refunds.
        addRevenue(o.mode === 'test' ? testRevenue : revenue, amountInr - refundedInr, Number(o.paidAt) || Number(o.createdAt) || 0, now);
      }
      const sweep = typeof repo.getSubscriptionSweepStatus === 'function' ? await repo.getSubscriptionSweepStatus().catch(() => null) : null;
      res.set('Cache-Control', 'no-store').json({
        subscribers, totalUsers: users.length, active, expiringIn7Days, expiredLast30Days,
        revenue, testRevenue, paidOrders, pendingClaims, failedSignatures, failedPayments, expiredOrders, refundedOrders, refunds,
        lastSweepAt: Number(sweep?.lastSweepAt) || 0, lastSweep: sweep ? { scanned: sweep.scanned || 0, expired: sweep.expired || 0, warned: sweep.warned || 0 } : null,
        generatedAt: now,
      });
    }));

    // GET /api/admin/subscriptions?tier=&state=active|expiring|expired|community&q=&limit=&cursor=
    r.get('/admin/subscriptions', requireAdmin, wrap(async (req, res) => {
      const now = Date.now();
      const q = String(req.query.q || '').trim().toLowerCase();
      const state = String(req.query.state || '').trim();
      const rawTier = String(req.query.tier || '').trim();
      const tier = rawTier ? (rawTier === 'community' ? 'community' : normalizeTier(rawTier)) : '';
      const limit = Math.min(500, Math.max(1, parseInt(req.query.limit, 10) || 50));
      const cursor = Math.max(0, parseInt(req.query.cursor, 10) || 0);
      let rows = (await allUsers()).map((u) => subscriberRow(u, now));
      if (state === 'active') rows = rows.filter((x) => x.state === 'active' || x.state === 'expiring');
      else if (state === 'expiring') rows = rows.filter((x) => x.state === 'expiring');
      else if (state === 'expired') rows = rows.filter((x) => x.state === 'expired');
      else if (state === 'community') rows = rows.filter((x) => x.state === 'community');
      if (tier) rows = rows.filter((x) => (x.state === 'expired' && tier !== 'community' ? x.previousTier === tier : x.tier === tier));
      if (q) rows = rows.filter((x) => [x.name, x.email, x.phone, x.userId, x.callsign].some((v) => String(v || '').toLowerCase().includes(q)));
      const rank = { expiring: 0, active: 1, expired: 2, community: 3 };
      rows.sort((a, b) => (rank[a.state] - rank[b.state]) || (a.state === 'expired' ? b.expiredAt - a.expiredAt : (a.validUntil - b.validUntil) || (b.createdAt - a.createdAt)));
      const page = rows.slice(cursor, cursor + limit);
      res.set('Cache-Control', 'no-store').json({
        subscribers: page, total: rows.length, cursor, limit,
        nextCursor: cursor + page.length < rows.length ? String(cursor + page.length) : null,
      });
    }));

    // Offers CRUD
    r.get('/admin/offers', requireAdmin, wrap(async (req, res) => {
      const now = Date.now();
      const offers = (await repo.listOffers(500)).map((o) => ({ ...offerView(o), isLive: offerIsLive(o, now) }))
        .sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
      res.set('Cache-Control', 'no-store').json({ offers, total: offers.length });
    }));

    r.post('/admin/offers', requireAdmin, wrap(async (req, res) => {
      let input;
      try { input = normalizeOfferInput(req.body); } catch (e) { if (e.status === 400) return res.status(400).json({ error: e.message }); throw e; }
      const offer = {
        ...input, id: `offer_${Date.now().toString(36)}_${crypto.randomBytes(3).toString('hex')}`,
        redemptions: 0, createdAt: Date.now(), createdBy: req.user?.email || req.user?.userId || 'admin',
      };
      const saved = await repo.saveOffer(offer);
      await addAudit(repo, req, 'offer.create', offer.id, { title: input.title, planTier: input.planTier, billingCycle: input.billingCycle, discountType: input.discountType, discountValue: input.discountValue });
      res.status(201).json({ success: true, message: `Offer "${input.title}" created`, offer: { ...offerView(saved), isLive: offerIsLive(saved) } });
    }));

    r.patch('/admin/offers/:id', requireAdmin, wrap(async (req, res) => {
      const existing = await repo.findOffer(req.params.id);
      if (!existing) return res.status(404).json({ error: 'Offer not found' });
      let input;
      try { input = normalizeOfferInput(req.body, existing); } catch (e) { if (e.status === 400) return res.status(400).json({ error: e.message }); throw e; }
      const saved = await repo.saveOffer({ ...existing, ...input, id: existing.id, updatedBy: req.user?.email || req.user?.userId || 'admin' });
      await addAudit(repo, req, 'offer.update', existing.id, { changes: req.body || {} });
      res.json({ success: true, message: 'Offer updated', offer: { ...offerView(saved), isLive: offerIsLive(saved) } });
    }));

    r.delete('/admin/offers/:id', requireAdmin, wrap(async (req, res) => {
      const existing = await repo.findOffer(req.params.id);
      if (!existing) return res.status(404).json({ error: 'Offer not found' });
      await repo.deleteOffer(existing.id);
      await addAudit(repo, req, 'offer.delete', existing.id, { title: existing.title || '' });
      res.json({ success: true, message: 'Offer deleted', id: existing.id });
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
  revokePlan,
  recordRefund,
  webCheckoutToken,
  orderView,
  offerView,
  offerIsLive,
  offerDiscount,
  bestOffer,
  registerSubscriptionPublicRoutes,
  registerSubscriptionAuthRoutes,
};
