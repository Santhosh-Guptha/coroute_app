'use strict';
/**
 * Admin plan assignment (3.55): the console's "Change plan" now gives one of the plans riders
 * actually have (Community, Small Group 2–6, Large Group 7–12) as a real membership, so the
 * rider's app shows it at once (GET /membership/my reads memberships). Before 3.55 the console
 * granted a legacy tier (proRider / roadCaptain / tourOperator) on the user document: the admin
 * saw "plan taken" while the rider's plan screen kept showing Community.
 *
 *  - assign(group_small|group_large, days): a ₹0 ledger order (mode 'manual', method 'ADMIN'),
 *    the membership activated from it (same code as a paid order), any active legacy tier ended
 *    (it would otherwise outrank a smaller assigned plan), an audit entry.
 *    Assigning the plan the rider already has adds the days to the time left.
 *  - assign(community): ends the rider's own membership and any legacy tier now.
 *  - Legacy tier names sent by an older console are mapped to their plan (LEGACY_PLAN_MAP).
 * Members already in the rider's group are kept; a plan with fewer seats than the group is refused.
 */
const crypto = require('crypto');
const { MEMBERSHIP_PLANS, LEGACY_PLAN_MAP, effectiveMembership, planFrom, belongsToAccount } = require('./entitlements');
const { effectiveSubscription, isPaidTier } = require('./subscription_lifecycle');
const { activateMembershipFromOrder } = require('./membership_routes');
const { revokePlan, addAudit } = require('./subscription_routes');

const DAY = 86400000;
/** Every value the console may send for a plan. */
const ADMIN_PLAN_CHOICES = Object.freeze(['community', ...MEMBERSHIP_PLANS]);

class AdminPlanError extends Error {
  constructor(message, status = 400, code = 'BAD_PLAN') { super(message); this.status = status; this.code = code; }
}

/** 'group_small' for 'group_small', 'proRider' (legacy, mapped) or 'Small Group'; null when unknown. */
function adminPlanId(raw) {
  const v = String(raw || '').trim();
  if (!v) return null;
  if (ADMIN_PLAN_CHOICES.includes(v)) return v;
  if (Object.hasOwn(LEGACY_PLAN_MAP, v)) return LEGACY_PLAN_MAP[v].category;
  const k = v.toLowerCase().replace(/[^a-z]/g, '');
  if (k === 'community' || k === 'free' || k === 'none') return 'community';
  if (k === 'smallgroup' || k === 'groupsmall') return 'group_small';
  if (k === 'largegroup' || k === 'grouplarge') return 'group_large';
  return null;
}

const activeMembers = (m) => Object.values((m && m.members) || {}).filter((x) => x && x.status !== 'REMOVED').length;

/** Ends an active legacy tier (subscriptionTier on the user document); no-op without one. */
async function endLegacyTier({ repo, auth, hub, userDoc, by, note }) {
  if (!userDoc) return false;
  const st = effectiveSubscription(userDoc);
  if (st.tier === 'community' && !isPaidTier(userDoc.subscriptionTier)) return false;
  await revokePlan({ repo, auth, hub, userDoc, by, reason: 'replaced_by_plan', note });
  return true;
}

/** The plan the rider has now, as the console shows it (the same answer as GET /membership/my). */
async function planView(repo, userDoc, now = Date.now()) {
  const membership = await repo.findMembershipByOwner(userDoc.userId).catch(() => null);
  const plan = planFrom({ membership, userDoc, now });
  const validUntil = Number(plan.validUntil) || 0;
  return {
    tier: plan.category || 'community', name: plan.name || 'Community', source: plan.source || 'community',
    validUntil, daysRemaining: validUntil > now ? Math.ceil((validUntil - now) / DAY) : 0,
    legacyTier: plan.legacyTier || null, seats: plan.seats || 1,
  };
}

async function assignPlan({ repo, auth, hub, convoys = null, req, userDoc, plan, days, note = '' }) {
  const category = adminPlanId(plan);
  if (!category) throw new AdminPlanError(`plan must be one of ${ADMIN_PLAN_CHOICES.join(', ')}`, 400, 'BAD_TIER');
  const adminId = req.user?.userId || 'admin';
  const now = Date.now();
  const rawExisting = await repo.findMembershipByOwner(userDoc.userId);
  // 3.55 safety review: a leftover of an earlier account with this userId is not this rider's
  // group (its seats must not block the grant with CAPACITY_CONFLICT, nor its days be extended).
  const existing = belongsToAccount(rawExisting, userDoc) ? effectiveMembership(rawExisting, now) : null;

  if (category === 'community') {
    const before = await planView(repo, userDoc, now);
    let changed = false;
    if (existing && existing.status === 'ACTIVE' && Number(existing.validUntil) > now) {
      await repo.saveMembership({
        ...existing, status: 'EXPIRED', statusReason: 'ADMIN_REVOKED', validUntil: now, scheduledChange: null,
        revokedAt: now, revokedBy: adminId, revokeNote: note,
      });
      changed = true;
    }
    if (await endLegacyTier({ repo, auth, hub, userDoc, by: adminId, note })) changed = true;
    if (convoys && typeof convoys.refreshHostCapacity === 'function') await convoys.refreshHostCapacity(userDoc.userId).catch(() => {});
    if (changed) {
      await addAudit(repo, req, 'subscription.revoke', userDoc.userId, { previousPlan: existing?.category || null, reason: note });
      if (hub) hub.sendToUser(userDoc.userId, { type: 'SUBSCRIPTION_REVOKED', previousTier: before.legacyTier || before.tier, plan: 'community', revokedAt: now, reason: note || 'admin' });
    }
    if (auth?.gate) auth.gate.invalidate(userDoc.userId);
    return { changed, plan: await planView(repo, await repo.findUserById(userDoc.userId) || userDoc) };
  }

  const n = Number(days);
  if (!Number.isInteger(n) || n < 1 || n > 3660) throw new AdminPlanError('days must be a whole number from 1 to 3660', 400, 'BAD_DAYS');
  const catalog = await repo.getMembershipCatalog();
  const catPlan = catalog[category];
  if (!catPlan) throw new AdminPlanError(`${category} is not in the plan catalog`, 400, 'BAD_TIER');
  if (existing && activeMembers(existing) + 1 > (Number(catPlan.capacity) || 1)) {
    throw new AdminPlanError(`${catPlan.name || category} has ${catPlan.capacity} seats but this rider's group has ${activeMembers(existing) + 1} riders. Remove members first or pick a larger plan.`, 409, 'CAPACITY_CONFLICT');
  }
  // The same plan: the new days add to the time left. Another plan: starts now for `days`.
  const sameActive = existing && existing.status === 'ACTIVE' && existing.category === category && Number(existing.validUntil) > now;
  const keepMs = sameActive ? Number(existing.validUntil) - now : 0;
  const order = {
    orderId: `admin_${now}_${crypto.randomBytes(4).toString('hex')}`,
    userId: userDoc.userId, category, planTier: category, billingCycle: 'manual', durationDays: n,
    amountInPaise: 0, amount: 0, currency: 'INR', status: 'CREATED', mode: 'manual', isFree: true,
    method: 'ADMIN', transactionType: 'ADMIN_GRANT', grantedBy: adminId, reason: note,
    quote: { kind: 'admin', billingDays: n + keepMs / DAY, extraDays: 0, basePriceInr: 0, couponDiscountInr: 0 },
    createdAt: now,
  };
  await repo.saveRazorpayOrder(order);
  const membership = await activateMembershipFromOrder({
    repo, order, paymentId: order.orderId, method: 'ADMIN', source: `admin_grant:${adminId}`, userDoc, convoys,
  });
  // A legacy tier with more seats would outrank the plan just given: it ends now.
  await endLegacyTier({ repo, auth, hub, userDoc: await repo.findUserById(userDoc.userId), by: adminId, note: `Replaced by ${catPlan.name || category}` });
  if (auth?.gate) auth.gate.invalidate(userDoc.userId);
  await addAudit(repo, req, 'subscription.grant', userDoc.userId, { plan: category, days: n, reason: note, orderId: order.orderId, validUntil: membership.validUntil });
  // Every app build re-reads its plan on this event (older builds included).
  if (hub) hub.sendToUser(userDoc.userId, { type: 'SUBSCRIPTION_ACTIVATED', plan: category, validUntil: membership.validUntil, at: now });
  return { changed: true, orderId: order.orderId, membership, plan: await planView(repo, await repo.findUserById(userDoc.userId) || userDoc) };
}

module.exports = { ADMIN_PLAN_CHOICES, AdminPlanError, adminPlanId, assignPlan, planView };
