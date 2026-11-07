'use strict';
/**
 * What a rider may do, from one source: the plans (Community, free for every rider; Small Group and
 * Large Group, paid) and, only until it ends, a legacy plan bought before them (the paid ₹9
 * Individual membership, or a legacy subscription tier).
 *
 * Gating map (server):
 *   - Safety (SOS, crash alerts, emergency texts, medical ID, guardians, offline maps, re-routing,
 *     trip history): never gated. Nothing here is consulted for them.
 *   - Community (default, free forever): starts SOLO rides (capacity 1: nobody else can join,
 *     409 SOLO_TRIP_ONLY; talk, messages, regroup and lead/sweep roles answer 403 SOLO_RIDE).
 *   - Joining someone else's ride: free for every rider. The only limit is the host's seats
 *     (409 CONVOY_FULL); inside a group ride every rider has the group features (they follow the
 *     ride's host plan, not the joiner's).
 *   - Hosting a group: a group plan. The convoy's capacity is the host's seats, host included
 *     (Small Group 6, Large Group 12), never more than the server ceiling MAX_CONVOY_RIDERS.
 *   - Legacy: an active Individual membership is honoured until its validUntil (solo rides, like
 *     Community), then the rider is simply Community. Legacy tiers keep equivalent access until
 *     their validUntil: proRider maps to hosting up to 6; roadCaptain and tourOperator map to 12.
 *     No new legacy purchase is possible (410 LEGACY_PLAN).
 *   - A downgrade bought during a paid period starts when that period ends (`scheduledChange` on
 *     the membership document; see effectiveMembership).
 * With payments switched off (PAYMENTS_ENABLED=false) nothing is gated and the capacity is the ceiling.
 */
const config = require('./config');
const { effectiveSubscription, isPaidTier } = require('./subscription_lifecycle');

/** The only plans sold (paid), in price order. */
const MEMBERSHIP_PLANS = Object.freeze(['group_small', 'group_large']);
const PAID_PLANS = MEMBERSHIP_PLANS;

/** Every plan of the catalog: the free Community plan first, then the paid plans. */
const CATALOG_PLANS = Object.freeze(['community', 'group_small', 'group_large']);

/** The free default plan every rider has (not purchasable). */
const COMMUNITY_PLAN = 'community';

/** Membership plans no longer sold; an active one is honoured until it ends (410 LEGACY_PLAN for new orders). */
const LEGACY_MEMBERSHIP_PLANS = Object.freeze(['individual']);

/**
 * The retired paid Individual plan as it was sold (₹9 a month, one seat, 30 days): only used to
 * honour an order paid before it was retired. Never offered, never in the catalog.
 */
const LEGACY_INDIVIDUAL_PLAN = Object.freeze({ id: 'individual', name: 'Individual', monthlyPriceInr: 9, capacity: 1, minCapacity: 1, maxCapacity: 1, billingPeriodDays: 30 });

/** Seats of each plan when a stored membership or catalog does not say (host included). */
const DEFAULT_SEATS = Object.freeze({ community: 1, individual: 1, group_small: 6, group_large: 12 });

/** Legacy tier -> the membership plan whose access it keeps until it ends. */
const LEGACY_PLAN_MAP = Object.freeze({
  proRider: Object.freeze({ category: 'group_small', seats: 6, name: 'CoRoute Pro' }),
  roadCaptain: Object.freeze({ category: 'group_large', seats: 12, name: 'Road Captain' }),
  tourOperator: Object.freeze({ category: 'group_large', seats: 12, name: 'Tour Operator' }),
});

const isMembershipPlan = (id) => MEMBERSHIP_PLANS.includes(id);
const isLegacyTier = (id) => Object.hasOwn(LEGACY_PLAN_MAP, id);
const isLegacyMembershipPlan = (id) => LEGACY_MEMBERSHIP_PLANS.includes(id);

/**
 * A plan id as riders, admins and older records spell it, mapped to a catalog id ('community',
 * 'group_small', 'group_large') or null. Case and spaces never matter ("Group_Small ", "small
 * group"). The retired paid Individual plan maps to Small Group, the entry paid plan that replaced
 * it (so an older coupon bound to it still works today). Legacy subscription tiers (proRider,
 * roadCaptain, tourOperator) map to nothing: a coupon bound only to them covers no plan. 'all' stays 'all'.
 */
function normalizePlanId(raw) {
  const s = String(raw == null ? '' : raw).trim().toLowerCase().replace(/[\s-]+/g, '_');
  if (!s) return null;
  if (s === 'all') return 'all';
  if (['community', 'free', 'community_rider'].includes(s)) return 'community';
  if (['group_small', 'small_group', 'small', 'smallgroup', 'groupsmall', 'individual'].includes(s)) return 'group_small';
  if (['group_large', 'large_group', 'large', 'largegroup', 'grouplarge'].includes(s)) return 'group_large';
  return null;
}

/**
 * The membership as it is NOW: a downgrade bought during a paid period (`scheduledChange`) starts
 * when that period ends. Before then the current plan ends at the change; after it, the document
 * reads as the new plan. The stored document keeps the final end date (so it stays "active").
 */
function effectiveMembership(m, now = Date.now()) {
  if (!m || !m.scheduledChange || typeof m.scheduledChange !== 'object') return m;
  const s = m.scheduledChange;
  const at = Number(s.startsAt) || 0;
  if (now >= at) {
    return {
      ...m,
      category: s.category,
      categoryName: s.categoryName || s.category,
      capacity: s.capacity,
      priceInr: s.priceInr,
      creditBasisInr: s.creditBasisInr,
      billingPeriodDays: s.billingPeriodDays,
      validFrom: at,
      validUntil: Number(s.endsAt) || Number(m.validUntil) || 0,
      scheduledChange: null,
    };
  }
  return { ...m, validUntil: at };
}

/** Seats clamped to 1..MAX_CONVOY_RIDERS (the absolute safety ceiling). */
function clampSeats(n) {
  const v = Math.floor(Number(n));
  if (!Number.isFinite(v) || v < 1) return 1;
  return Math.min(v, Math.max(1, Number(config.maxConvoyRiders) || 1));
}

/** Seats of a stored membership document (what the host bought). */
function membershipSeats(m) {
  const cap = Number(m && m.capacity);
  if (Number.isFinite(cap) && cap >= 1) return clampSeats(cap);
  return clampSeats(DEFAULT_SEATS[m && m.category] || 1);
}

const NONE = Object.freeze({
  source: 'none', category: null, name: 'No plan', seats: 0, validUntil: 0,
  canStartTrip: false, canHostGroup: false, legacyTier: null, membershipId: null,
});

/** The free plan every rider has when nothing else applies: solo rides, never expires. */
const COMMUNITY = Object.freeze({
  source: 'community', category: COMMUNITY_PLAN, name: 'Community', seats: 1, validUntil: 0,
  canStartTrip: true, canHostGroup: false, legacyTier: null, membershipId: null,
});

/** True when the membership document is ACTIVE and inside its period. */
function membershipActive(m, now = Date.now()) {
  return !!m && m.status === 'ACTIVE' && (Number(m.validUntil) || 0) > now;
}

/** The legacy plan a rider still holds (paid tier inside its period), or null. Pure. */
function legacyPlanOf(userDoc, now = Date.now()) {
  if (!userDoc) return null;
  const st = effectiveSubscription(userDoc, now);
  if (!st.isActive || !isPaidTier(st.tier) || !isLegacyTier(st.tier) || !(st.validUntil > now)) return null;
  const map = LEGACY_PLAN_MAP[st.tier];
  return {
    source: 'legacy', category: map.category, name: map.name, seats: clampSeats(map.seats),
    validUntil: st.validUntil, legacyTier: st.tier, membershipId: null,
  };
}

/**
 * Pure: the plan from an active membership document and/or a user document. A rider without a paid
 * plan (or whose plan ended) is on Community: solo rides, free, no end date.
 */
/**
 * False for a membership left behind by an earlier account that had the same userId (created more
 * than a minute before this account). Such a plan was never this rider's (3.55 data cleanup).
 */
function belongsToAccount(m, userDoc) {
  if (!m || !userDoc) return true;
  const made = Number(m.createdAt) || 0;
  const born = Number(userDoc.createdAt) || 0;
  return !(made && born && made + 60000 < born);
}

function planFrom({ membership = null, userDoc = null, now = Date.now() } = {}) {
  let best = null;
  const m = belongsToAccount(membership, userDoc) ? effectiveMembership(membership, now) : null;
  if (membershipActive(m, now)) {
    best = {
      source: 'membership', category: m.category,
      name: m.categoryName || m.category, seats: membershipSeats(m),
      validUntil: Number(m.validUntil) || 0, legacyTier: null, membershipId: m.membershipId || null,
    };
    if (m.scheduledChange && typeof m.scheduledChange === 'object') {
      const s = m.scheduledChange;
      best.nextPlan = { category: s.category, name: s.categoryName || s.category, startsAt: Number(s.startsAt) || 0, endsAt: Number(s.endsAt) || 0 };
    }
  }
  const legacy = legacyPlanOf(userDoc, now);
  // A legacy tier only wins when it gives more seats than the membership (never a loss).
  if (legacy && (!best || legacy.seats > best.seats)) best = legacy;
  if (!best) return { ...COMMUNITY };
  return { ...best, canStartTrip: best.seats >= 1, canHostGroup: best.seats >= 2 };
}

/** The rider's plan now: { source, category, name, seats, validUntil, canStartTrip, canHostGroup, legacyTier }. */
async function resolvePlan(repo, userId, { userDoc = null, now = Date.now() } = {}) {
  if (!userId) return { ...NONE };
  const membership = await repo.findMembershipByOwner(userId).catch(() => null);
  const user = userDoc || (await repo.findUserById(userId).catch(() => null));
  return planFrom({ membership, userDoc: user, now });
}

/** Group-ride entitlements of a plan (the catalog's, or the mapped plan's for a legacy tier). */
function entitlementsFor(plan, catalog) {
  const base = { ptt: false, convoy: false, groupSafety: false, personalTracking: true, basicNav: true, sharedTrip: false };
  if (!plan || plan.source === 'none') return base;
  const fromCatalog = catalog && catalog[plan.category] && catalog[plan.category].entitlements;
  if (fromCatalog) return { ...base, ...fromCatalog };
  if (plan.canHostGroup) return { ...base, ptt: true, convoy: true, groupSafety: true, sharedTrip: true };
  return base;
}

module.exports = {
  MEMBERSHIP_PLANS, PAID_PLANS, CATALOG_PLANS, COMMUNITY_PLAN, LEGACY_MEMBERSHIP_PLANS, DEFAULT_SEATS, LEGACY_PLAN_MAP,
  LEGACY_INDIVIDUAL_PLAN, isMembershipPlan, isLegacyTier, isLegacyMembershipPlan, normalizePlanId, effectiveMembership,
  clampSeats, membershipSeats, membershipActive, legacyPlanOf, planFrom, belongsToAccount, resolvePlan, entitlementsFor,
};
