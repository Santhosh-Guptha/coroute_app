'use strict';
/**
 * 3.56 rider website shop: plans, payments and the rider's account move from the Play app to the
 * website (Google Play policy: the app sells nothing). Docs: docs/features_355/web_payments.md.
 *
 * Pages (public/, rendered through the shared shell by pages.js SITE_PAGES):
 *   /signin   same CoRoute account as the app (email or callsign + password; Google when GOOGLE_WEB_CLIENT_ID is set)
 *   /plans    plan cards from GET /api/membership/catalog, quote, coupon, Razorpay Checkout (web JS)
 *   /account  plan, status, end date, payment history, receipts, sign out
 *   /receipt  one printable receipt (?order=<orderId>, the rider's own paid orders only)
 * The browser keeps the session token in sessionStorage and sends it as a Bearer header; it is never
 * in a URL or a cookie, so CSRF does not apply. Prices, coupons and proration are never computed here:
 * the pages call the same membership endpoints the app used (membership_routes.js / plan_pricing.js).
 *
 * Every shop page gets a strict Content-Security-Policy (no inline script, frame-ancestors 'none'),
 * no-store caching and no referrer. Only /plans and /checkout may load Razorpay Checkout, only
 * /signin may load Google Identity Services (and only when configured).
 *
 * Also here:
 *   GET /api/web/config                     public: Google web client id (when set), support e-mail, payments on/off
 *   GET /api/web/receipt/:orderId           Bearer: one paid order of this rider, for the receipt page
 *   /get?coupon=CODE                        -> 302 /plans?coupon=CODE (marketing QR / {link} of older templates)
 *   /checkout without an app order          -> 302 /plans (old app orders: ?order=&t=&e= and ?paid= / ?failed= stay)
 *   notifyPlanActivated(...)                SUBSCRIPTION_ACTIVATED to the rider's sockets + a push when the app is closed
 */
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { requireAuth } = require('./auth');

/** Shop routes -> page files (merged into pages.js SITE_PAGES). */
const SHOP_PAGES = Object.freeze({
  '/plans': 'plans.html',
  '/account': 'account.html',
  '/signin': 'signin.html',
  '/receipt': 'receipt.html',
});

/** Third-party origins, one place. Razorpay Checkout (web): the script, its frames and its calls. */
const RAZORPAY = Object.freeze({
  script: ['https://checkout.razorpay.com'],
  frame: ['https://api.razorpay.com', 'https://checkout.razorpay.com'],
  connect: ['https://api.razorpay.com', 'https://lumberjack.razorpay.com'],
  img: ['https://cdn.razorpay.com'],
  // Redirect mode (old app orders on /checkout) posts a form to Razorpay from this page.
  form: ['https://api.razorpay.com'],
});
/** Google Identity Services ("Sign in with Google" button). */
const GOOGLE = Object.freeze({
  script: ['https://accounts.google.com/gsi/client'],
  frame: ['https://accounts.google.com/gsi/'],
  connect: ['https://accounts.google.com/gsi/'],
  style: ['https://accounts.google.com/gsi/style'],
});

/** A coupon code as the marketing links carry it: A-Z 0-9 - _, at most 24 (uppercased), else ''. */
function cleanCouponCode(raw) {
  const s = String(raw == null ? '' : raw).trim().toUpperCase();
  return /^[A-Z0-9_-]{1,24}$/.test(s) ? s : '';
}

/** `<origin>/plans?coupon=CODE` (the marketing studio QR / {link}); `<origin>/plans` for a bad code. */
function plansLink(origin, code) {
  const o = String(origin || '').replace(/\/+$/, '');
  const c = cleanCouponCode(code);
  return c ? `${o}/plans?coupon=${encodeURIComponent(c)}` : `${o}/plans`;
}

/** Google web client id when it looks like one (`<digits>-<id>.apps.googleusercontent.com`), else ''. */
function googleWebClientId() {
  const id = String(config.googleWebClientId || '').trim();
  return /^[0-9]{6,}-[a-z0-9]{8,}\.apps\.googleusercontent\.com$/.test(id) ? id : '';
}

/**
 * The Content-Security-Policy of one shop page. Scripts only from this site (plus Razorpay / Google
 * where the page needs them); inline style attributes stay allowed (the shared header uses a few).
 */
function shopCsp({ razorpay = false, google = false } = {}) {
  const src = (base, ...extra) => [...base, ...extra.flat()].join(' ');
  const r = razorpay ? RAZORPAY : { script: [], frame: [], connect: [], img: [], form: [] };
  const g = google ? GOOGLE : { script: [], frame: [], connect: [], style: [] };
  const frames = [...r.frame, ...g.frame];
  return [
    "default-src 'self'",
    `script-src ${src(["'self'"], r.script, g.script)}`,
    `style-src ${src(["'self'", "'unsafe-inline'"], g.style)}`,
    `img-src ${src(["'self'", 'data:'], r.img)}`,
    "font-src 'self'",
    `connect-src ${src(["'self'"], r.connect, g.connect)}`,
    `frame-src ${frames.length ? frames.join(' ') : "'none'"}`,
    "object-src 'none'",
    "base-uri 'none'",
    `form-action ${src(["'self'"], r.form)}`,
    "frame-ancestors 'none'",
    "manifest-src 'self'",
  ].join('; ');
}

/** Which third parties each shop page may load. */
function cspFor(route) {
  if (route === '/plans' || route === '/checkout') return shopCsp({ razorpay: true });
  if (route === '/signin') return shopCsp({ google: Boolean(googleWebClientId()) });
  return shopCsp();
}

/** Headers for a shop page: strict CSP, never cached (it shows account state), never indexed, no referrer. */
function shopPageHeaders(route) {
  return (req, res, next) => {
    res.set('Content-Security-Policy', cspFor(route))
      .set('X-Frame-Options', 'DENY')
      .set('Referrer-Policy', 'no-referrer')
      .set('X-Robots-Tag', route === '/plans' ? 'index, follow' : 'noindex, nofollow')
      // app.js sendPage keeps a Cache-Control that is already set.
      .set('Cache-Control', 'no-store');
    next();
  };
}

/**
 * Tells the rider's app at once that a plan became active (the app re-reads /membership/my on it):
 * the socket event every app build handles, and a push only when no app socket received it.
 * Never throws.
 */
function notifyPlanActivated({ hub = null, push = null, userId, membership = null, order = null, source = '' }) {
  if (!userId) return;
  const payload = {
    type: 'SUBSCRIPTION_ACTIVATED',
    plan: (membership && membership.category) || (order && order.category) || null,
    validUntil: (membership && Number(membership.validUntil)) || null,
    orderId: (order && order.orderId) || null,
    source: source || null,
    at: Date.now(),
  };
  try { if (hub && typeof hub.sendToUser === 'function') hub.sendToUser(userId, payload); } catch { /* never in the way */ }
  const p = push || (hub && hub.push) || null;
  if (p && typeof p.notifyUsers === 'function') {
    const name = String((membership && membership.categoryName) || 'Your plan').replace(/\s*\([^)]*\)\s*$/, '');
    Promise.resolve(p.notifyUsers([userId], {
      type: 'SUBSCRIPTION_ACTIVATED',
      title: 'Plan active',
      body: `${name} is active. Thank you for riding with CoRoute.`,
      data: { orderId: payload.orderId || '', eventId: `SUBSCRIPTION_ACTIVATED:${payload.orderId || payload.at}` },
      skipConnected: true,
    })).catch(() => {});
  }
}

/** One paid order as the receipt page shows it (the rider's own; never the store key or webhook ids). */
function receiptOf(order, { user, catalog }) {
  const plan = (catalog && catalog[order.category]) || {};
  const q = order.quote && typeof order.quote === 'object' ? order.quote : {};
  const amountInr = (Number(order.amountInPaise) || 0) / 100;
  const lines = Array.isArray(q.breakdown) && q.breakdown.length
    ? q.breakdown.filter((l) => l && typeof l.label === 'string').map((l) => ({ label: l.label.slice(0, 120), amountInr: Number(l.amountInr) || 0 }))
    : [{ label: String(plan.name || order.category || 'Plan'), amountInr: Number(order.originalPrice) || amountInr }, { label: 'To pay now', amountInr }];
  const refundedInr = Number(order.refundedAmount) || ((Number(order.refundedAmountInPaise) || 0) / 100) || 0;
  return {
    receiptNo: String(order.internalOrderId || order.orderId),
    orderId: order.orderId,
    paymentId: order.paymentId && !String(order.paymentId).startsWith('free_') ? String(order.paymentId) : '',
    status: order.status,
    planId: order.category || null,
    planName: String(q.planName || plan.name || order.category || 'Plan'),
    seats: Number(q.seats || plan.capacity) || null,
    billingDays: Number(q.billingDays || plan.billingPeriodDays) || 30,
    kind: q.kind || null,
    couponCode: order.offerCode || q.couponCode || null,
    // 3.56: the plan offer that was running when the order was priced (the charged amount is amountInr).
    listPriceInr: Number(q.listPriceInr || order.listPriceInr) || null,
    offerLabel: (q.offer && q.offer.label) || order.offerLabel || null,
    lines,
    amountInr,
    currency: order.currency || 'INR',
    method: order.method || (order.isFree ? 'COUPON' : 'RAZORPAY'),
    isFree: Boolean(order.isFree),
    paidAt: Number(order.paidAt) || null,
    createdAt: Number(order.createdAt) || null,
    periodStartsAt: Number(q.startsAt) || null,
    periodEndsAt: Number(q.endsAt) || null,
    refundStatus: order.refundStatus || null,
    refundedInr,
    channel: order.channel || null,
    billedTo: { name: (user && user.name) || '', username: (user && user.username) || '', email: (user && user.email) || '' },
    seller: { name: config.upiMerchantName || 'CoRoute', site: config.publicOrigin || '', supportEmail: config.supportEmail || '' },
  };
}

/**
 * Mounts the shop on the express app, BEFORE the SITE_PAGES loop of app.js: page headers, the
 * /get coupon forward, the /checkout fallback, /api/web/*.
 */
function attachWebShop({ app, repo, gate, logger = console }) {
  void logger;
  for (const route of [...Object.keys(SHOP_PAGES), '/checkout']) {
    app.use([route, `${route}.html`], (req, res, next) => (req.method === 'GET' || req.method === 'HEAD' ? shopPageHeaders(route)(req, res, next) : next()));
  }

  // Marketing QR / {link} printed before 3.56 point at /get?coupon=CODE: buying is on /plans now.
  // Only a well-formed code is carried over; a malformed one lands on /plans without it.
  app.get(['/get', '/get.html'], (req, res, next) => {
    if (req.query.coupon === undefined) return next();
    const code = cleanCouponCode(req.query.coupon);
    res.set('Cache-Control', 'no-store');
    return res.redirect(302, code ? `/plans?coupon=${encodeURIComponent(code)}` : '/plans');
  });

  // /checkout: old app builds (3.54 / 3.55) open checkout.html?order=&t=&e= for an order they created, and
  // Razorpay's redirect comes back with ?paid= / ?failed=. Those keep working; a plain visit goes to /plans.
  app.get(['/checkout', '/checkout.html'], (req, res, next) => {
    const q = req.query;
    if (q.order || q.paid || q.failed) return next();
    res.set('Cache-Control', 'no-store');
    return res.redirect(302, '/plans');
  });

  const r = express.Router();
  const perIp = (limit) => rateLimit({ windowMs: 60 * 1000, limit, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests. Try again in a minute.', code: 'RATE_LIMITED' } });
  r.get('/config', perIp(60), (req, res) => {
    res.set('Cache-Control', 'no-store').json({
      googleClientId: googleWebClientId() || null,
      supportEmail: config.supportEmail || '',
      paymentsEnabled: config.paymentsEnabled !== false,
      merchantName: config.upiMerchantName || 'CoRoute',
    });
  });
  r.get('/receipt/:orderId', perIp(60), requireAuth(gate), async (req, res, next) => {
    try {
      res.set('Cache-Control', 'no-store');
      const id = String(req.params.orderId || '');
      if (!/^[A-Za-z0-9_.:-]{4,80}$/.test(id)) return res.status(404).json({ error: 'Receipt not found', code: 'NOT_FOUND' });
      const order = await repo.findRazorpayOrder(id);
      // Someone else's order reads exactly like a missing one.
      if (!order || order.userId !== req.user.userId) return res.status(404).json({ error: 'Receipt not found', code: 'NOT_FOUND' });
      if (order.status !== 'PAID') return res.status(409).json({ error: 'This order is not paid, so there is no receipt.', code: 'NOT_PAID' });
      const user = req.dbUser || (await repo.findUserById(req.user.userId));
      const catalog = await repo.getMembershipCatalog().catch(() => ({}));
      res.json({ receipt: receiptOf(order, { user, catalog }) });
    } catch (e) { next(e); }
  });
  app.use('/api/web', r);
}

module.exports = {
  SHOP_PAGES, RAZORPAY, GOOGLE, cleanCouponCode, plansLink, googleWebClientId, shopCsp, cspFor, shopPageHeaders,
  notifyPlanActivated, receiptOf, attachWebShop,
};
