'use strict';
/**
 * Subscription lifecycle, all on the server:
 *   - effectiveSubscription(): what a rider's tier IS right now (a paid tier past its
 *     subscriptionValidUntil is community, even before the sweeper rolled the document back).
 *   - expireIfDue(): persists that rollback once (history entry, gate invalidation, WS push).
 *   - SubscriptionSweeper: hourly pass over paid subscribers for 7/3/1-day warnings and expiry.
 */
const DAY = 86400000;
const PAID_TIERS = Object.freeze(['proRider', 'roadCaptain', 'tourOperator']);
const WARN_DAYS = Object.freeze([7, 3, 1]);

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

function historyOf(user) { return Array.isArray(user?.subscriptionHistory) ? [...user.subscriptionHistory] : []; }

/**
 * Rolls an expired paid tier back to community, once. Returns the updated document, or null
 * when nothing was due. Cheap and idempotent: safe on every login and /me.
 */
async function expireIfDue({ repo, auth, hub, notify }, user, nowMs = Date.now()) {
  if (!user || !user.key) return null;
  const s = effectiveSubscription(user, nowMs);
  if (!(s.rawTier !== 'community' && !s.isActive)) return null;
  const history = historyOf(user);
  history.push({ tier: s.rawTier, validFrom: Number(user.lastPayment?.validFrom) || 0, validUntil: s.validUntil, endedAt: nowMs, reason: 'expired' });
  const updated = await repo.updateUser(user.key, {
    subscriptionTier: 'community',
    subscriptionValidUntil: 0,
    subscriptionExpiredAt: s.validUntil,
    previousTier: s.rawTier,
    subscriptionWarnedAt: {},
    subscriptionHistory: history,
  });
  if (!updated) return null;
  if (auth?.gate) auth.gate.invalidate(user.userId);
  const payload = { type: 'SUBSCRIPTION_EXPIRED', previousTier: s.rawTier, expiredAt: s.validUntil };
  if (hub) hub.sendToUser(user.userId, payload);
  if (notify) await Promise.resolve(notify(user.userId, payload)).catch(() => {});
  return { ...updated, key: user.key };
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
    const stats = { scanned: 0, expired: 0, warned: 0 };
    const users = await this.repo.listPaidSubscribers(2000);
    for (const user of users) {
      stats.scanned++;
      try {
        if (await expireIfDue(this, user, nowMs)) { stats.expired++; continue; }
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
    this.log.info('[subscriptions] sweep', JSON.stringify(stats));
    this.lastSweepAt = nowMs;
    this.lastStats = stats;
    if (typeof this.repo.setSubscriptionSweepStatus === 'function') {
      await this.repo.setSubscriptionSweepStatus({ lastSweepAt: nowMs, ...stats }).catch(() => {});
    }
    return stats;
  }
}

module.exports = { DAY, PAID_TIERS, WARN_DAYS, isPaidTier, effectiveSubscription, expireIfDue, warningDue, SubscriptionSweeper };
