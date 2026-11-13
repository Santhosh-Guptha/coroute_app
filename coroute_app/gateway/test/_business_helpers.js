'use strict';
/**
 * Synthetic data for the round 6 business tests (not a test file). Everything is written straight into the
 * in-memory store in the shapes the gateway itself writes: users, rider_scores, memberships, orders, coupon
 * redemptions, sessions.
 */
const DAY = 86400000;
const IST = 330 * 60000;
const WEEK = 7 * DAY;

/** Monday 12:00 IST of the week `weeksAgo` weeks before `now`. */
function monday(now, weeksAgo = 0) {
  const w = Math.floor((now + IST + 3 * DAY) / WEEK) - weeksAgo;
  return w * WEEK - 3 * DAY - IST + 12 * 3600000;
}

function seeder(soda, now) {
  let n = 0;
  const api = {
    async user(o = {}) {
      n++;
      const userId = o.userId || `usr_b${String(n).padStart(5, '0')}`;
      const doc = { userId, name: o.name || `Rider ${n}`, username: o.username || `rider_${n}`, email: o.email === undefined ? `rider${n}@coroute.test` : o.email, emailLower: `rider${n}@coroute.test`,
        role: o.role || 'RIDER', status: 'ACTIVE', createdAt: o.createdAt || now - 30 * DAY, emailVerified: o.verified !== false,
        lastActiveAt: o.lastActiveAt === undefined ? now - DAY : o.lastActiveAt, lastLoginAt: 0, subscriptionTier: 'community' };
      doc.usernameKey = doc.username.toLowerCase();
      await soda.insert('users', doc);
      await soda.insert('usernames', { usernameKey: doc.usernameKey, userId, at: now }).catch(() => {});
      if (o.rides) await api.rides(userId, o.rides);
      if (o.plan) await api.plan(userId, o.plan);
      if (o.consent) await soda.insert('marketing_consent', { userId, offersEmail: true, updatedAt: now, history: [] });
      return doc;
    },
    /** rides: [{ at, group }] or timestamps. */
    async rides(userId, rides) {
      await soda.insert('rider_scores', { userId, rides: rides.map((r, i) => (typeof r === 'number' ? { rideId: `R-${userId}-${i}`, endedAt: r, km: 40, groupSize: 1 } : { rideId: `R-${userId}-${i}`, endedAt: r.at, km: 40, groupSize: r.group ? 5 : 1 })), pending: {}, archived: null });
    },
    async plan(userId, { until, category = 'group_small', status = 'ACTIVE' }) {
      await soda.insert('memberships', { membershipId: `mem_${userId}`, ownerUserId: userId, category, status, validFrom: until - 30 * DAY, validUntil: until, priceInr: 199 });
    },
    async order(o) {
      n++;
      await soda.insert('subscription_config', { k: 'rzp_order', orderId: o.orderId || `order_b${n}`, userId: o.userId, status: o.status || 'PAID', amountInPaise: o.amountInPaise === undefined ? 19900 : o.amountInPaise,
        category: o.category || 'group_small', mode: o.mode || 'live', createdAt: o.at || now - DAY, paidAt: (o.status || 'PAID') === 'PAID' ? (o.at || now - DAY) : 0, updatedAt: o.at || now - DAY,
        couponCode: o.couponCode || null, refundedAmountInPaise: o.refundedInPaise || 0, refunds: o.refunds || [], ...(o.extra || {}) });
    },
    async redemption(o) {
      n++;
      await soda.insert('subscription_config', { k: 'coupon_redemption', redemptionId: `red_b${n}`, couponCode: o.code, userId: o.userId, status: o.status || 'SUCCESS', discountAmount: o.discount || 0,
        finalAmount: o.final === undefined ? 100 : o.final, isFree: !!o.free, reservedAt: o.at || now - DAY, redeemedAt: o.status && o.status !== 'SUCCESS' ? null : (o.at || now - DAY), createdAt: o.at || now - DAY });
    },
    async session(o) {
      n++;
      await soda.insert('auth_sessions', { sessionId: `ses_b${n}`, userId: o.userId, kind: 'app', createdAt: o.at || now - DAY, lastSeenAt: o.at || now - DAY, deviceKey: o.deviceKey || '', ipHash: o.ipHash || '', revokedAt: 0 });
    },
  };
  return api;
}

module.exports = { seeder, monday, DAY, WEEK, IST };
