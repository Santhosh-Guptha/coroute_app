'use strict';
/**
 * Plan prices, coupons and upgrades: ONE computation for the quote the app shows
 * (GET /api/membership/quote) and the order the rider pays (POST /api/membership/order), so
 * the amount charged is always the amount shown and never what a client sends.
 *
 * Proration (owner's rule):
 *   credit     = unused days of the current paid plan x (what that period cost / its billing days),
 *                rounded to the rupee, never negative. "Unused days" are the days left, rounded to
 *                the nearest whole day (bought this morning = all 30 days; the last few hours = 0).
 *                What that period cost is its list price, less any coupon (a free coupon month gives
 *                no credit). A downgrade already paid for (scheduled) is credited in full.
 *   payable    = max(0, price_new - coupon - credit). Coupon first (on the list price), then credit.
 *   Upgrade, Community -> paid, or renewing early: the new plan starts NOW with a full period.
 *   Credit larger than what is left to pay is never lost: it adds whole days to the new period.
 *   Downgrade (fewer seats) during a paid period: no credit and no refund; the new plan starts when
 *   the current one ends (startsAt = its end) and runs a full period from there.
 *   payable 0 -> the order activates without a payment.
 */
const {
  PAID_PLANS, COMMUNITY_PLAN, isLegacyMembershipPlan, normalizePlanId, effectiveMembership, DEFAULT_SEATS,
} = require('./entitlements');

const DAY_MS = 86400000;

const rupees = (v) => {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : 0;
};

/** Billing days of a catalog plan or membership document (30 when it does not say). */
function billingDaysOf(p) {
  const d = Math.floor(Number(p && p.billingPeriodDays));
  return Number.isFinite(d) && d >= 1 ? d : 30;
}

/** "₹31" */
const inr = (n) => `₹${Math.round(Number(n) || 0)}`;

/** Seats of a plan (catalog entry or membership document). */
function seatsOf(p, id) {
  const c = Math.floor(Number(p && p.capacity));
  if (Number.isFinite(c) && c >= 1) return c;
  return DEFAULT_SEATS[id] || 1;
}

/**
 * "Up to N riders" for the website: the most seats of a paid plan on sale in the catalog
 * (`maxCapacity`, else `capacity`), DEFAULT_SEATS.group_large (12) when the catalog says nothing.
 * The server ceiling MAX_CONVOY_RIDERS ([ceiling]) only caps it; it is never the advertised number.
 */
function siteMaxRiders(catalog, ceiling) {
  let most = 0;
  for (const id of PAID_PLANS) {
    const p = catalog && catalog[id];
    if (!p || typeof p !== 'object' || p.isActive === false) continue;
    const seats = Math.floor(Number(p.maxCapacity)) || Math.floor(Number(p.capacity)) || 0;
    if (seats > most) most = seats;
  }
  if (most < 1) most = DEFAULT_SEATS.group_large;
  const cap = Math.floor(Number(ceiling));
  return Number.isFinite(cap) && cap >= 1 ? Math.min(most, cap) : most;
}

/** Plan ids a coupon is bound to, normalised ('all' when it names every plan or none). */
function couponPlans(coupon) {
  const raw = Array.isArray(coupon && coupon.applicableTiers) ? coupon.applicableTiers : ['all'];
  if (!raw.length) return ['all'];
  const out = new Set();
  for (const t of raw) {
    const id = normalizePlanId(t);
    if (id) out.add(id);
  }
  if (out.has('all')) return ['all'];
  // A binding made only of legacy tier ids covers no plan sold today.
  return [...out];
}

/** True when the coupon may be used on plan `planId`. */
function couponFitsPlan(coupon, planId) {
  const plans = couponPlans(coupon);
  return plans.includes('all') || plans.includes(planId);
}

/** Rupees a coupon takes off a ₹`baseInr` plan (never more than the price, rounded to the rupee). */
function couponDiscountInr(coupon, baseInr) {
  const base = rupees(baseInr);
  if (!coupon || base <= 0) return 0;
  const v = Number(coupon.discountValue) || 0;
  const cap = Number(coupon.maxDiscountCap) > 0 ? Number(coupon.maxDiscountCap) : Infinity;
  let d = 0;
  if (coupon.discountType === 'free') d = base;
  else if (coupon.discountType === 'percentage') d = Math.min((base * Math.min(100, Math.max(0, v))) / 100, cap);
  else if (coupon.discountType === 'fixed') d = Math.min(Math.max(0, v), cap);
  else if (coupon.discountType === 'price') d = Math.max(0, base - Math.max(0, v)); // "pay ₹X"
  return Math.max(0, Math.min(base, Math.round(d)));
}

const COUPON_STATUS_ERRORS = {
  USAGE_LIMIT_REACHED: ['This code has been fully used', 'COUPON_LIMIT_REACHED'],
  EXPIRED: ['This code has expired', 'COUPON_EXPIRED'],
  SCHEDULED: ["This code isn't active yet", 'COUPON_SCHEDULED'],
  PAUSED: ['This code is paused right now', 'COUPON_PAUSED'],
  ARCHIVED: ['This code is no longer active', 'COUPON_ARCHIVED'],
  DRAFT: ["This code isn't active yet", 'COUPON_INACTIVE'],
};

/** Paid (money) purchases in a rider's payment history; free coupon activations are not purchases. */
function paidPurchases(userDoc) {
  const hist = Array.isArray(userDoc && userDoc.paymentHistory) ? userDoc.paymentHistory : [];
  return hist.filter((p) => p && p.status === 'PAID' && !p.isFree && (Number(p.amountInr ?? p.amount) || 0) > 0);
}

/**
 * Every coupon rule in one place, for one rider and plan: status (expiry, limits, pause), plan
 * binding (case-insensitive, retired ids mapped), minimum order (on the plan's list price), new
 * members / first payment, allow-list and the per-rider limit. Billing cycles do not apply: every
 * plan is one billing period. Returns { ok: true, discountInr } or { ok: false, error, reason }.
 */
function checkCoupon(coupon, { uid = null, userDoc = null, planId, baseInr }) {
  if (!coupon) return { ok: false, error: "We couldn't find that code", reason: 'COUPON_NOT_FOUND' };
  const status = String(coupon.status || (coupon.isActive === false ? 'PAUSED' : 'ACTIVE')).toUpperCase();
  if (status !== 'ACTIVE') {
    const [error, reason] = COUPON_STATUS_ERRORS[status] || ['This code is no longer active', 'COUPON_INACTIVE'];
    return { ok: false, error, reason };
  }
  const now = Date.now();
  if (coupon.validFrom && Number(coupon.validFrom) > now) return { ok: false, error: "This code isn't active yet", reason: 'COUPON_SCHEDULED' };
  if (coupon.expiresAt && Number(coupon.expiresAt) < now) return { ok: false, error: 'This code has expired', reason: 'COUPON_EXPIRED' };
  if (!couponFitsPlan(coupon, planId)) return { ok: false, error: "This code isn't for this plan", reason: 'TIER_MISMATCH' };
  const minAmt = Number(coupon.minOrderAmount) || 0;
  if (minAmt > 0 && rupees(baseInr) < minAmt) {
    return { ok: false, error: `This code needs a plan of ₹${minAmt} or more`, reason: 'MIN_ORDER_NOT_MET' };
  }
  if (coupon.newMembersOnly && paidPurchases(userDoc).length > 0) {
    return { ok: false, error: 'This code is for your first purchase only', reason: 'NEW_MEMBERS_ONLY' };
  }
  const hist = Array.isArray(userDoc && userDoc.paymentHistory) ? userDoc.paymentHistory : [];
  if (coupon.firstPaymentOnly && hist.length > 0) {
    return { ok: false, error: 'This code is for your first payment only', reason: 'FIRST_PAYMENT_ONLY' };
  }
  if (Array.isArray(coupon.allowedUserIds) && coupon.allowedUserIds.length > 0 && !coupon.allowedUserIds.includes(uid)) {
    return { ok: false, error: "This code isn't available for your account", reason: 'NOT_ELIGIBLE' };
  }
  const maxPerUser = Number(coupon.maxUsagePerUser) || 1;
  const used = (coupon.usages || []).filter((u) => u.userId === uid).length;
  if (uid && used >= maxPerUser) return { ok: false, error: "You've already used this code", reason: 'PER_USER_LIMIT_REACHED' };
  return { ok: true, discountInr: couponDiscountInr(coupon, baseInr) };
}

/** The paid membership a rider holds now (effective view), or null (Community, ended, free plan). */
function currentPaidPeriod(membership, now) {
  const m = effectiveMembership(membership, now);
  if (!m || m.status !== 'ACTIVE' || !((Number(m.validUntil) || 0) > now)) return null;
  if (!PAID_PLANS.includes(m.category) && !isLegacyMembershipPlan(m.category)) return null;
  return m;
}

/** What the current period cost (list price less coupon), the base of the credit. */
function creditBasisOf(m, catalog) {
  if (m.creditBasisInr !== undefined && m.creditBasisInr !== null && Number.isFinite(Number(m.creditBasisInr))) return rupees(m.creditBasisInr);
  if (m.priceInr !== undefined && m.priceInr !== null) return rupees(m.priceInr);
  const c = catalog && catalog[m.category];
  return rupees(c && c.monthlyPriceInr);
}

/** Days and rupees of credit the rider has now (pure). */
function creditOf({ membership, catalog, now, includeCurrent = true }) {
  const out = { creditInr: 0, unusedDays: 0, fromCategory: null, fromName: null, scheduledInr: 0 };
  const cur = currentPaidPeriod(membership, now);
  if (!cur) return out;
  out.fromCategory = cur.category;
  out.fromName = String(cur.categoryName || (catalog && catalog[cur.category] && catalog[cur.category].name) || cur.category).replace(/\s*\([^)]*\)\s*$/, '');
  let raw = 0;
  if (includeCurrent) {
    const unusedDays = Math.max(0, Math.round(((Number(cur.validUntil) || 0) - now) / DAY_MS));
    const days = billingDaysOf(cur.billingPeriodDays ? cur : (catalog && catalog[cur.category]) || cur);
    out.unusedDays = unusedDays;
    raw += (unusedDays * creditBasisOf(cur, catalog)) / days;
  }
  // A downgrade bought earlier and not started yet was paid in full: all of it is credit.
  const s = membership && membership.scheduledChange;
  if (s && typeof s === 'object' && now < (Number(s.startsAt) || 0)) {
    out.scheduledInr = rupees(s.creditBasisInr);
    raw += out.scheduledInr;
  }
  out.creditInr = Math.max(0, Math.round(raw));
  return out;
}

/** "19 Nov" in India time (for the plain-words notes). */
function shortDate(ms) {
  try {
    return new Date(ms).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', timeZone: 'Asia/Kolkata' });
  } catch {
    return new Date(ms).toISOString().slice(0, 10);
  }
}

/**
 * The price of plan `planId` for this rider now. `coupon` is a coupon record that already passed
 * checkCoupon (or null). Pure: no I/O. Throws { status, reason } for a plan that cannot be bought.
 */
function computeQuote({ catalog, planId, membership = null, coupon = null, couponDiscount = null, now = Date.now() }) {
  const plan = catalog && catalog[planId];
  if (!plan) throw Object.assign(new Error('Invalid membership category'), { status: 400, reason: 'INVALID_CATEGORY' });
  const days = billingDaysOf(plan);
  const base = rupees(plan.monthlyPriceInr);
  const name = plan.name || planId;
  // "Large Group (7–12)" reads as "Large Group" in the breakdown (the seats are shown elsewhere).
  const shortName = String(name).replace(/\s*\([^)]*\)\s*$/, '') || name;
  const cur = currentPaidPeriod(membership, now);
  const newSeats = seatsOf(plan, planId);

  let kind = 'new';
  if (cur) {
    const curSeats = seatsOf(cur, cur.category);
    if (cur.category === planId) kind = 'renewal';
    else if (newSeats < curSeats) kind = 'downgrade';
    else kind = 'upgrade';
  }

  const discount = Math.min(base, couponDiscount !== null ? Math.max(0, Math.round(couponDiscount)) : couponDiscountInr(coupon, base));
  const afterCoupon = base - discount;
  const credit = creditOf({ membership, catalog, now, includeCurrent: kind !== 'downgrade' });
  const creditUsed = Math.min(credit.creditInr, afterCoupon);
  const leftover = credit.creditInr - creditUsed;
  const extraDays = leftover > 0 && base > 0 ? Math.floor(leftover / (base / days)) : 0;
  const payable = Math.max(0, afterCoupon - creditUsed);
  const startsAt = kind === 'downgrade' ? Number(cur.validUntil) : now;
  const endsAt = startsAt + (days + extraDays) * DAY_MS;

  const lines = [{ label: `${shortName} (${days} days)`, amountInr: base }];
  if (discount > 0) lines.push({ label: `Coupon ${coupon && coupon.code ? coupon.code : ''}`.trim(), amountInr: -discount });
  if (credit.creditInr > 0) {
    const what = credit.unusedDays > 0
      ? `Credit for ${credit.unusedDays} unused ${credit.unusedDays === 1 ? 'day' : 'days'} of ${credit.fromName}`
      : 'Credit for your plan already paid';
    lines.push({ label: what, amountInr: -creditUsed });
  }
  lines.push({ label: 'To pay now', amountInr: payable });

  let summary = `${shortName} ${inr(base)}`;
  if (discount > 0) summary += ` − ${inr(discount)} coupon`;
  if (creditUsed > 0) {
    summary += credit.unusedDays > 0
      ? ` − ${inr(creditUsed)} credit for ${credit.unusedDays} unused ${credit.unusedDays === 1 ? 'day' : 'days'}`
      : ` − ${inr(creditUsed)} credit`;
  }
  summary += ` = ${inr(payable)}`;

  const notes = [];
  if (kind === 'downgrade') notes.push(`Starts when your ${credit.fromName} ends on ${shortDate(startsAt)}. No refund for the current period.`);
  else if (cur) notes.push(`Starts now and runs ${days} days, until ${shortDate(endsAt - extraDays * DAY_MS)}.`);
  if (extraDays > 0) notes.push(`Your extra credit adds ${extraDays} ${extraDays === 1 ? 'day' : 'days'} (until ${shortDate(endsAt)}).`);

  return {
    plan: planId,
    planName: name,
    kind,
    seats: newSeats,
    billingDays: days,
    basePriceInr: base,
    couponCode: discount > 0 && coupon ? coupon.code : null,
    couponDiscountInr: discount,
    creditInr: creditUsed,
    creditAvailableInr: credit.creditInr,
    unusedDays: credit.unusedDays,
    fromPlan: credit.fromCategory,
    fromPlanName: credit.fromName,
    extraDays,
    payableInr: payable,
    isFree: payable === 0,
    startsAt,
    endsAt,
    breakdown: lines,
    summary,
    notes,
    computedAt: now,
  };
}

/** Why plan `planId` cannot be ordered (legacy, free or unknown), or null. */
function orderBlock(planId, catalog) {
  if (isLegacyMembershipPlan(planId)) {
    return { status: 410, error: 'The Individual plan is no longer sold. Community is free and covers solo rides.', reason: 'LEGACY_PLAN', code: 'LEGACY_PLAN' };
  }
  if (planId === COMMUNITY_PLAN) {
    return { status: 400, error: 'Community is free for every rider. Nothing to buy.', reason: 'FREE_PLAN' };
  }
  if (!catalog || !catalog[planId] || !PAID_PLANS.includes(planId)) {
    return { status: 400, error: 'Invalid membership category', reason: 'INVALID_CATEGORY' };
  }
  return null;
}

module.exports = {
  DAY_MS, billingDaysOf, couponPlans, couponFitsPlan, couponDiscountInr, checkCoupon, paidPurchases,
  currentPaidPeriod, creditOf, computeQuote, orderBlock, siteMaxRiders,
};
