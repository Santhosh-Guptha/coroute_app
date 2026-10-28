'use strict';
/**
 * Subscription lifecycle, all on the server:
 *   - effectiveSubscription(): what a rider's tier IS right now (a paid tier past its
 *     subscriptionValidUntil is community, even before the sweeper rolled the document back).
 *   - expireIfDue(): persists that rollback once (history entry, gate invalidation, WS push).
 *   - startPendingIfDue(): a downgrade bought while a dearer tier was running is stored as
 *     `pendingTier` and starts when the running tier ends.
 *   - SubscriptionSweeper: hourly pass over paid subscribers for 7/3/1-day warnings and expiry,
 *     scheduled downgrades, and ledger orders left CREATED for 24 hours (marked EXPIRED).
 */
const DAY = 86400000;
const PAID_TIERS = Object.freeze(['proRider', 'roadCaptain', 'tourOperator']);
const WARN_DAYS = Object.freeze([7, 3, 1]);
/** A ledger order nobody paid within this time is marked EXPIRED by the sweeper. */
const ORDER_TTL_MS = 24 * 60 * 60 * 1000;

function isPaidTier(tier) { return PAID_TIERS.includes(tier); }

/**
 * Pure. Returns { tier, rawTier, validUntil, isActive, isExpired, daysRemaining, expiringSoon, previousTier }.
 *   tier       : the effective tier ('community' when the paid period has passed)
 *   isActive   : true for community (always) and for a paid tier still inside its period
 *   isExpired  : a paid tier whose validUntil has passed (document not yet rolled back), or a
 *                document already rolled back by expireIfDue (subscriptionExpiredAt set)
 */
function effectiveSubscription(user, nowMs = Date.now()) {
  const u = user || {};
  // A scheduled (already paid) downgrade counts from the moment the running tier ends,
  // even before the sweeper or a login has switched the document over.
  const pending = pendingDue(u, nowMs);
  if (pending) {
    return effectiveSubscription({ ...u, subscriptionTier: pending.tier, subscriptionValidUntil: pending.validUntil, pendingTier: null }, nowMs);
  }
  const rawTier = isPaidTier(u.subscriptionTier) ? u.subscriptionTier : 'community';
  const validUntil = Number(u.subscriptionValidUntil) || 0;
  const paid = rawTier !== 'community';
  const stillValid = paid && validUntil > nowMs;
  const lapsed = paid && !stillValid;
  const tier = stillValid ? rawTier : 'community';
  const daysRemaining = stillValid ? Math.max(0, Math.ceil((validUntil - nowMs) / DAY)) : 0;
  const rolledBack = !paid && Number(u.subscriptionExpiredAt) > 0 && isPaidTier(u.previousTier);
  return {
    tier,
    rawTier,
    validUntil: stillValid || lapsed ? validUntil : 0,
    isActive: !lapsed,
    isExpired: lapsed || rolledBack,
    daysRemaining,
    expiringSoon: stillValid && daysRemaining <= 7,
    previousTier: lapsed ? rawTier : (isPaidTier(u.previousTier) ? u.previousTier : null),
    expiredAt: lapsed ? validUntil : (Number(u.subscriptionExpiredAt) || 0),
  };
}

/** The pending tier when it should be running now: { tier, startsAt, validUntil } or null. */
function pendingDue(u, nowMs) {
  const p = u && u.pendingTier;
  if (!p || !isPaidTier(p.tier)) return null;
  const startsAt = Number(p.startsAt) || 0;
  const validUntil = startsAt + (Number(p.durationMs) || 0);
  const currentRunning = isPaidTier(u.subscriptionTier) && Number(u.subscriptionValidUntil) > nowMs;
  if (currentRunning || startsAt > nowMs || validUntil <= nowMs) return null;
  return { tier: p.tier, startsAt, validUntil };
}

function historyOf(user) { return Array.isArray(user?.subscriptionHistory) ? [...user.subscriptionHistory] : []; }

/**
 * Rolls an expired paid tier back to community, once. Returns the updated document, or null
 * when nothing was due. Cheap and idempotent: safe on every login and /me.
 */
async function expireIfDue(ctx, input, nowMs = Date.now()) {
  if (!input || !input.key) return null;
  const { repo, auth, hub, notify } = ctx;
  const started = await startPendingIfDue(ctx, input, nowMs);
  const user = started || input;
  const s = effectiveSubscription(user, nowMs);
  if (started && !(s.rawTier !== 'community' && !s.isActive)) return started;
  if (!(s.rawTier !== 'community' && !s.isActive)) return null;
  if (user.pendingTier && isPaidTier(user.pendingTier.tier) && (Number(user.pendingTier.startsAt) || 0) > nowMs) return started; // gap: wait for it
  const history = historyOf(user);
  history.push({ tier: s.rawTier, validFrom: Number(user.lastPayment?.validFrom) || 0, validUntil: s.validUntil, endedAt: nowMs, reason: 'expired' });
  const updated = await repo.updateUser(user.key, {
    subscriptionTier: 'community',
    subscriptionValidUntil: 0,
    subscriptionExpiredAt: s.validUntil,
    previousTier: s.rawTier,
    subscriptionWarnedAt: {},
    subscriptionHistory: history,
    pendingTier: null,
  });
  if (!updated) return null;
  if (auth?.gate) auth.gate.invalidate(user.userId);
  const payload = { type: 'SUBSCRIPTION_EXPIRED', previousTier: s.rawTier, expiredAt: s.validUntil };
  if (hub) hub.sendToUser(user.userId, payload);
  if (notify) await Promise.resolve(notify(user.userId, payload)).catch(() => {});
  return { ...updated, key: user.key };
}

/**
 * Starts a scheduled downgrade once the running tier has ended. Returns the updated document,
 * or null when nothing was due. The rider paid for it, so it is never dropped.
 */
async function startPendingIfDue({ repo, auth, hub, notify }, user, nowMs = Date.now()) {
  const p = user && user.pendingTier;
  if (!p || !user.key || !isPaidTier(p.tier)) return null;
  const currentUntil = Number(user.subscriptionValidUntil) || 0;
  const startsAt = Number(p.startsAt) || 0;
  if ((isPaidTier(user.subscriptionTier) && currentUntil > nowMs) || startsAt > nowMs) return null;
  const validUntil = startsAt + (Number(p.durationMs) || 0);
  const history = historyOf(user);
  if (isPaidTier(user.subscriptionTier)) {
    const prev = [...(Array.isArray(user.paymentHistory) ? user.paymentHistory : [])].reverse()
      .find((x) => x.planTier === user.subscriptionTier && !x.scheduled);
    history.push({ tier: user.subscriptionTier, validFrom: Number(prev?.validFrom) || 0, validUntil: currentUntil, endedAt: Math.min(nowMs, Math.max(currentUntil, startsAt)), reason: 'expired' });
  }
  history.push({ tier: p.tier, validFrom: startsAt, validUntil, startedAt: nowMs, reason: 'scheduled', orderId: p.orderId || null });
  const updated = await repo.updateUser(user.key, {
    subscriptionTier: p.tier,
    subscriptionValidUntil: validUntil,
    subscriptionExpiredAt: 0,
    previousTier: isPaidTier(user.subscriptionTier) ? user.subscriptionTier : (user.previousTier || null),
    subscriptionWarnedAt: {},
    subscriptionHistory: history,
    pendingTier: null,
  });
  if (!updated) return null;
  if (auth?.gate) auth.gate.invalidate(user.userId);
  const payload = { type: 'SUBSCRIPTION_ACTIVATED', tier: p.tier, validUntil, orderId: p.orderId || null, method: 'SCHEDULED' };
  if (hub) hub.sendToUser(user.userId, payload);
  if (notify) await Promise.resolve(notify(user.userId, payload)).catch(() => {});
  return { ...updated, key: user.key };
}

/** Marks ledger orders still CREATED after ORDER_TTL_MS as EXPIRED. Returns how many. */
async function expireStaleOrders(repo, nowMs = Date.now(), log = console) {
  if (!repo || typeof repo.listRazorpayOrders !== 'function') return 0;
  const stale = await repo.listRazorpayOrders({ status: 'CREATED', createdAt: { $lt: nowMs - ORDER_TTL_MS } }, 1000);
  let n = 0;
  for (const o of stale) {
    try {
      await repo.updateRazorpayOrder(o.orderId, { status: 'EXPIRED', expiredAt: nowMs });
      n++;
    } catch (e) {
      log.warn('[subscriptions] order expiry failed:', o.orderId, e.message);
    }
  }
  return n;
}

/** Which of the 7/3/1-day warnings is due now (the smallest matching bucket not yet sent), or 0. */
function warningDue(user, nowMs) {
  const s = effectiveSubscription(user, nowMs);
  if (!s.isActive || s.tier === 'community') return 0;
  const sent = user.subscriptionWarnedAt || {};
  for (const d of [...WARN_DAYS].sort((a, b) => a - b)) {
    if (s.daysRemaining <= d && !sent['d' + d]) return d;
  }
  return 0;
}

class SubscriptionSweeper {
  constructor({ repo, auth, hub, notify = null, logger = console, everyMinutes = 60 }) {
    this.repo = repo; this.auth = auth; this.hub = hub; this.notify = notify; this.log = logger;
    this.everyMs = everyMinutes * 60000; this.timers = [];
  }
  start() {
    const run = () => this.runOnce().catch((e) => this.log.warn('[subscriptions] sweep failed:', e.message));
    this.timers.push(setInterval(run, this.everyMs));
    const first = setTimeout(run, 90000);
    this.timers.push(first);
    for (const t of this.timers) if (t.unref) t.unref();
  }
  stop() { for (const t of this.timers) { clearInterval(t); clearTimeout(t); } this.timers = []; }

  async runOnce(nowMs = Date.now()) {
    const stats = { scanned: 0, expired: 0, warned: 0, scheduledStarted: 0, ordersExpired: 0 };
    const users = await this.repo.listPaidSubscribers(2000);
    for (const input of users) {
      stats.scanned++;
      let user = input;
      try {
        const started = await startPendingIfDue(this, input, nowMs);
        if (started) { stats.scheduledStarted++; user = started; }
        if (await expireIfDue(this, user, nowMs)) { stats.expired++; continue; }
        if (started) continue;
        const d = warningDue(user, nowMs);
        if (!d) continue;
        const s = effectiveSubscription(user, nowMs);
        // Mark every bucket at or above the one sent, so a 2-day-old document never gets d7 after d3.
        const warnedAt = { ...(user.subscriptionWarnedAt || {}) };
        for (const b of WARN_DAYS) if (b >= d) warnedAt['d' + b] = warnedAt['d' + b] || nowMs;
        await this.repo.updateUser(user.key, { subscriptionWarnedAt: warnedAt });
        const payload = { type: 'SUBSCRIPTION_EXPIRING', tier: s.tier, validUntil: s.validUntil, daysRemaining: s.daysRemaining, warning: 'd' + d };
        if (this.hub) this.hub.sendToUser(user.userId, payload);
        if (this.notify) await Promise.resolve(this.notify(user.userId, payload)).catch(() => {});
        stats.warned++;
      } catch (e) {
        this.log.warn('[subscriptions] user failed:', user.userId, e.message);
      }
    }
    try {
      stats.ordersExpired = await expireStaleOrders(this.repo, nowMs, this.log);
    } catch (e) {
      this.log.warn('[subscriptions] order expiry failed:', e.message);
    }
    this.log.info('[subscriptions] sweep', JSON.stringify(stats));
    this.lastSweepAt = nowMs;
    this.lastStats = stats;
    if (typeof this.repo.setSubscriptionSweepStatus === 'function') {
      await this.repo.setSubscriptionSweepStatus({ lastSweepAt: nowMs, ...stats }).catch(() => {});
    }
    return stats;
  }
}

module.exports = {
  DAY, PAID_TIERS, WARN_DAYS, ORDER_TTL_MS, isPaidTier, effectiveSubscription, expireIfDue, startPendingIfDue,
  expireStaleOrders, warningDue, SubscriptionSweeper,
};
