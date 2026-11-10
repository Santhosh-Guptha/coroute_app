'use strict';
/**
 * 3.56 website payments and coupons: the security rules shared by the order, verify, webhook and
 * coupon code paths (docs/features_355/web_payments_security.md).
 *
 *   ORDER_TTL_MS / COUPON_HOLD_MS  an order is payable for 30 minutes; its coupon use is held as long
 *   couponTime / istTime           admin times: epoch ms, ISO with a zone, or India-time dates / times
 *   couponRefusal                  the rider-facing answer for a refused code: a code that does not exist,
 *                                  is a draft, archived, scheduled or private reads exactly the same
 *   CouponGuard                    brute-force brake: 10 unknown codes per rider and per IP in 15 minutes,
 *                                  then every code lookup answers 429 until the window ends
 *   paymentMismatch                a captured Razorpay payment must match the ledger order (order id,
 *                                  amount in paise, currency) before anything is activated
 *   webhookUrlActive               only one Razorpay webhook URL is live (RAZORPAY_WEBHOOK_URL)
 */

const ORDER_TTL_MS = 30 * 60 * 1000;
const COUPON_HOLD_MS = ORDER_TTL_MS;
/** Razorpay Checkout closes itself after this many seconds (website). */
const CHECKOUT_TIMEOUT_S = 15 * 60;
const IST_OFFSET_MS = 330 * 60 * 1000;

/**
 * An admin time as epoch ms (or 0 when empty / unreadable).
 *   number or digits         epoch ms
 *   'YYYY-MM-DD'             India time: 00:00 of that day ('start'), or 00:00 of the NEXT day ('end',
 *                            exclusive, so "until 30 Nov" includes all of 30 Nov)
 *   'YYYY-MM-DDTHH:mm[:ss]'  India time when no zone is given
 *   ISO with Z / +hh:mm      as written
 */
function istTime(v, edge = 'start') {
  if (v === undefined || v === null || v === '') return 0;
  if (typeof v === 'number') return Number.isFinite(v) && v > 0 ? Math.floor(v) : 0;
  const s = String(v).trim();
  if (/^\d{10,16}$/.test(s)) return Number(s);
  let m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (m) {
    const t = Date.UTC(+m[1], +m[2] - 1, +m[3]) - IST_OFFSET_MS;
    return edge === 'end' ? t + 86400000 : t;
  }
  m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$/.exec(s);
  if (m) return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)) - IST_OFFSET_MS;
  const t = Date.parse(s);
  return Number.isFinite(t) && /(?:Z|[+-]\d{2}:?\d{2})$/i.test(s) ? t : 0;
}
const couponTime = istTime;

/** "30 Nov 2026" in India time. */
function istDate(ms) {
  return new Date(Number(ms)).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' });
}

const NOT_FOUND = Object.freeze({ error: "We couldn't find that code", reason: 'COUPON_NOT_FOUND' });
/** Refusals that would tell a guesser a code exists before it is public (or that it is private). */
const HIDDEN_REASONS = new Set(['COUPON_NOT_FOUND', 'COUPON_SCHEDULED', 'COUPON_INACTIVE', 'COUPON_ARCHIVED', 'NOT_ELIGIBLE']);

/**
 * The answer a rider sees for a refused code ({ error, reason } from plan_pricing.checkCoupon or the
 * legacy evaluateCoupon). Draft, archived, scheduled and allow-listed codes read like a missing one.
 */
function couponRefusal(chk) {
  if (!chk || HIDDEN_REASONS.has(chk.reason)) return { ...NOT_FOUND };
  return { error: chk.error, reason: chk.reason };
}
/** True when the refusal counts as a guess (the code is not one this rider can know). */
const isGuess = (chk) => !chk || HIDDEN_REASONS.has(chk.reason);

/**
 * Brute-force brake on coupon codes, per rider and per client IP (memory; per gateway node).
 * `blocked(req)` -> seconds to wait or 0; `failed(req)` counts one unknown code.
 */
class CouponGuard {
  constructor({ limit = 10, windowMs = 15 * 60 * 1000, now = () => Date.now() } = {}) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    this.hits = new Map(); // key -> { n, resetAt }
  }
  keys(req) {
    const out = [];
    const uid = req && req.user && req.user.userId;
    if (uid) out.push(`u:${uid}`);
    const ip = req && (req.ip || (req.socket && req.socket.remoteAddress));
    if (ip) out.push(`ip:${ip}`);
    return out;
  }
  blocked(req) {
    const now = this.now();
    let wait = 0;
    for (const k of this.keys(req)) {
      const h = this.hits.get(k);
      if (!h) continue;
      if (h.resetAt <= now) { this.hits.delete(k); continue; }
      if (h.n >= this.limit) wait = Math.max(wait, Math.ceil((h.resetAt - now) / 1000));
    }
    return wait;
  }
  failed(req) {
    const now = this.now();
    for (const k of this.keys(req)) {
      const h = this.hits.get(k);
      if (!h || h.resetAt <= now) this.hits.set(k, { n: 1, resetAt: now + this.windowMs });
      else h.n += 1;
    }
    if (this.hits.size > 50000) for (const [k, h] of this.hits) if (h.resetAt <= now) this.hits.delete(k);
  }
  reset() { this.hits.clear(); }
}
const couponGuard = new CouponGuard();

/** Sends 429 when this rider / IP is braked; true when sent. */
function refuseCouponGuessing(res, req, guard = couponGuard) {
  const wait = guard.blocked(req);
  if (!wait) return false;
  res.set('Retry-After', String(wait)).status(429).json({
    valid: false, error: 'Too many codes tried. Try again in a few minutes.', reason: 'COUPON_ATTEMPTS', code: 'RATE_LIMITED', retryAfterSeconds: wait,
  });
  return true;
}

/**
 * Why a Razorpay payment entity cannot settle `order` (null when it matches). Fields Razorpay always
 * sends (order_id, amount, currency) are compared when present; a status other than captured /
 * authorized is refused.
 */
function paymentMismatch(payment, order) {
  if (!payment || typeof payment !== 'object' || !order) return null;
  if (payment.order_id && payment.order_id !== order.orderId) return 'ORDER_MISMATCH';
  if (payment.amount !== undefined && payment.amount !== null && Number(payment.amount) !== Number(order.amountInPaise)) return 'AMOUNT_MISMATCH';
  if (payment.currency && String(payment.currency).toUpperCase() !== String(order.currency || 'INR').toUpperCase()) return 'CURRENCY_MISMATCH';
  if (payment.status && !['captured', 'authorized'].includes(String(payment.status).toLowerCase())) return 'NOT_CAPTURED';
  return null;
}

/** Razorpay ids as Razorpay writes them. */
const RZP_ID = /^[A-Za-z0-9_]{6,64}$/;
const SIGNATURE = /^[a-f0-9]{64}$/i;

/**
 * Which webhook URL is live: RAZORPAY_WEBHOOK_URL = 'subscription' (default, the URL in the Razorpay
 * dashboard: /api/subscription/webhook) or 'membership' (/api/membership/webhook). The other one answers
 * 410 WEBHOOK_URL_INACTIVE (Razorpay shows the failure in its dashboard, so a wrong setup is visible)
 * and never settles anything.
 */
function webhookUrlActive(which) {
  const v = String(process.env.RAZORPAY_WEBHOOK_URL || 'subscription').trim().toLowerCase();
  const active = v === 'membership' ? 'membership' : 'subscription';
  return which === active;
}
function refuseInactiveWebhook(res, which) {
  if (webhookUrlActive(which)) return false;
  res.status(410).json({ error: 'This webhook URL is not active. Configure the other CoRoute webhook URL in Razorpay.', code: 'WEBHOOK_URL_INACTIVE' });
  return true;
}

/** An e-mail address for a log line: first letter and domain only. */
function maskEmail(e) {
  const s = String(e || '');
  const at = s.indexOf('@');
  return at > 0 ? `${s[0]}***${s.slice(at)}` : (s ? '***' : '');
}

module.exports = {
  ORDER_TTL_MS, COUPON_HOLD_MS, CHECKOUT_TIMEOUT_S, IST_OFFSET_MS,
  istTime, couponTime, istDate, couponRefusal, isGuess, CouponGuard, couponGuard, refuseCouponGuessing,
  paymentMismatch, RZP_ID, SIGNATURE, webhookUrlActive, refuseInactiveWebhook, maskEmail,
};
