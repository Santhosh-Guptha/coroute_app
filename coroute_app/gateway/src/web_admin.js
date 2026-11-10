'use strict';
/**
 * 3.55 web admin (docs/features_355/web_admin.md): the money and marketing parts of the admin console
 * moved out of the mobile app (Google Play policy) into a browser page at /admin.
 *
 *   GET /admin, /admin/                 the single-page console (public/admin/index.html)
 *   GET /admin/<file>.js|.css|.svg      its scripts and styles (public/admin/)
 *   GET /api/admin/web/config           what the page needs at start (public origin, payments switch)
 *   GET /api/admin/web/revenue          read-only aggregates for the Revenue charts
 *
 * The page itself holds no data: it signs in with POST /api/auth/login (rate limited per IP and per
 * account) and calls the existing admin APIs with a Bearer token; every one of them is behind
 * requireAuth + requireAdmin (MASTER_ADMIN), so a rider token gets 403 whatever the page does.
 *
 * Headers on every /admin response: a strict CSP of its own (no inline script or style, no third
 * party, frame-ancestors 'none', form-action 'none'), X-Robots-Tag noindex, no-referrer, no-store.
 */
const fs = require('fs');
const path = require('path');
const express = require('express');

const ADMIN_CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self' data: blob:",
  "font-src 'self'",
  "connect-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
  "object-src 'none'",
  "manifest-src 'none'",
  "worker-src 'none'",
].join('; ');

const ASSET_TYPES = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };

function adminHeaders(res) {
  res.set({
    'Content-Security-Policy': ADMIN_CSP,
    'X-Robots-Tag': 'noindex, nofollow, noarchive',
    'Referrer-Policy': 'no-referrer',
    'Cross-Origin-Opener-Policy': 'same-origin',
    'X-Frame-Options': 'DENY',
    'X-Content-Type-Options': 'nosniff',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=()',
  });
}

/**
 * Pages router, mounted at the app root BEFORE the website's static files. Files are read once at
 * start; index.html gets ?v=<hash> on its asset links so the assets can be cached safely.
 */
function webAdminPages({ publicDir }) {
  const dir = path.join(publicDir, 'admin');
  const r = express.Router();
  if (!fs.existsSync(path.join(dir, 'index.html'))) return r;
  const crypto = require('crypto');
  const assets = new Map();
  for (const f of fs.readdirSync(dir)) {
    const ext = path.extname(f);
    if (!ASSET_TYPES[ext] || !/^[a-z0-9_-]+\.[a-z]+$/.test(f)) continue;
    const buf = fs.readFileSync(path.join(dir, f));
    assets.set(f, { buf, type: ASSET_TYPES[ext], hash: crypto.createHash('sha256').update(buf).digest('hex').slice(0, 10) });
  }
  const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8')
    .replace(/(\/admin\/)([a-z0-9_-]+\.[a-z]+)(?=")/g, (m, p, f) => (assets.has(f) ? `${p}${f}?v=${assets.get(f).hash}` : m));

  r.get(['/admin', '/admin/'], (req, res) => {
    adminHeaders(res);
    res.set('Cache-Control', 'no-store').type('html').send(html);
  });
  r.get('/admin/:file', (req, res, next) => {
    const a = assets.get(req.params.file);
    adminHeaders(res);
    if (!a) return res.status(404).set('Cache-Control', 'no-store').type('text/plain').send('Not found');
    res.set({ 'Content-Type': a.type, 'Cache-Control': req.query.v === a.hash ? 'public, max-age=604800, immutable' : 'no-cache' }).send(a.buf);
    void next;
  });
  // Anything deeper under /admin is not a page.
  r.all('/admin/*', (req, res) => { adminHeaders(res); res.status(404).set('Cache-Control', 'no-store').type('text/plain').send('Not found'); });
  return r;
}

// ------------------------------------------------------------------ revenue aggregates
const DAY = 86400000;
const IST = 330 * 60000;
const istDay = (ms) => new Date(ms + IST).toISOString().slice(0, 10);
const istMonth = (ms) => new Date(ms + IST).toISOString().slice(0, 7);
const round2 = (n) => Math.round(n * 100) / 100;

/** Month keys 'YYYY-MM' (India time), oldest first, ending with the current month. */
function monthKeys(now, months) {
  const d = new Date(now + IST);
  let y = d.getUTCFullYear(); let m = d.getUTCMonth();
  const out = [];
  for (let i = 0; i < months; i++) {
    out.unshift(`${y}-${String(m + 1).padStart(2, '0')}`);
    m--; if (m < 0) { m = 11; y--; }
  }
  return out;
}
/** End of a month key in epoch ms (India time). */
function monthEnd(key) {
  const [y, m] = key.split('-').map(Number);
  return Date.UTC(m === 12 ? y + 1 : y, m === 12 ? 0 : m, 1) - IST - 1;
}

/**
 * Revenue for the web admin charts. Staff accounts (admins, STAFF_EMAILS) are left out of every
 * figure, like the app's dashboards; Razorpay test-mode money is reported apart from live money.
 * Net = paid amount minus refunds, by the day / month the order was paid (India time).
 */
async function revenueSummary(repo, { days = 30, months = 12, now = Date.now() } = {}) {
  const staff = typeof repo.staffUserIds === 'function' ? await repo.staffUserIds().catch(() => new Set()) : new Set();
  const orders = typeof repo.listRazorpayOrders === 'function' ? await repo.listRazorpayOrders({}, 100000) : [];
  const dayKeys = [];
  for (let i = days - 1; i >= 0; i--) dayKeys.push(istDay(now - i * DAY));
  const mKeys = monthKeys(now, months);
  const daily = new Map(dayKeys.map((k) => [k, { date: k, netInr: 0, refundsInr: 0, orders: 0, testNetInr: 0 }]));
  const monthly = new Map(mKeys.map((k) => [k, { month: k, netInr: 0, refundsInr: 0, orders: 0, testNetInr: 0, couponRedemptions: 0, couponDiscountInr: 0, activePaidPlans: 0 }]));
  const totals = { netInr: 0, refundsInr: 0, orders: 0, testNetInr: 0, staffOrdersExcluded: 0 };
  const byPlan = {};
  for (const o of orders) {
    if (String(o.status || '').toUpperCase() !== 'PAID') continue;
    const paise = Number(o.amountInPaise) || 0;
    if (paise <= 0) continue;
    if (o.userId && staff.has(o.userId)) { totals.staffOrdersExcluded++; continue; }
    const at = Number(o.paidAt) || Number(o.createdAt) || 0;
    const refunded = (Number(o.refundedAmountInPaise) || 0) / 100;
    const net = paise / 100 - refunded;
    const test = o.mode === 'test';
    const d = daily.get(istDay(at)); const m = monthly.get(istMonth(at));
    if (test) {
      totals.testNetInr += net;
      if (d) d.testNetInr += net;
      if (m) m.testNetInr += net;
      continue;
    }
    totals.netInr += net; totals.refundsInr += refunded; totals.orders++;
    if (d) { d.netInr += net; d.refundsInr += refunded; d.orders++; }
    if (m) { m.netInr += net; m.refundsInr += refunded; m.orders++; }
    const plan = o.category || o.planTier || 'other';
    byPlan[plan] = byPlan[plan] || { plan, orders: 0, netInr: 0 };
    byPlan[plan].orders++; byPlan[plan].netInr += net;
  }

  // Paid plans: active now (by plan), and active at each month end (from validFrom / validUntil).
  const memberships = repo.soda ? await repo.soda.query(require('./oracle/repo').COLLECTIONS.memberships, {}, { limit: 20000 }).then((r) => r.map((x) => x.value)).catch(() => []) : [];
  const activeNow = {};
  for (const mem of memberships) {
    if (!mem || staff.has(mem.ownerUserId)) continue;
    const cat = mem.category || 'other';
    if (cat === 'community' || !(Number(mem.priceInr) > 0 || cat.startsWith('group'))) continue;
    const from = Number(mem.validFrom) || Number(mem.createdAt) || 0;
    const until = Number(mem.validUntil) || 0;
    if (mem.status === 'ACTIVE' && until > now) activeNow[cat] = (activeNow[cat] || 0) + 1;
    for (const k of mKeys) {
      const end = Math.min(monthEnd(k), now);
      if (from && from <= end && until > end && mem.statusReason !== 'REFUNDED') monthly.get(k).activePaidPlans++;
    }
  }

  // Coupon usage: successful redemptions by month (non-staff) and the top codes over the window.
  const redemptions = typeof repo.listCouponRedemptions === 'function' ? await repo.listCouponRedemptions({}, 20000).catch(() => []) : [];
  const top = new Map();
  const windowStart = monthEnd(mKeys[0]) - 40 * DAY;
  for (const rd of redemptions) {
    if (rd.status !== 'SUCCESS' || (rd.userId && staff.has(rd.userId))) continue;
    const at = Number(rd.redeemedAt || rd.reservedAt || rd.createdAt) || 0;
    const m = monthly.get(istMonth(at));
    if (m) { m.couponRedemptions++; m.couponDiscountInr += Number(rd.discountAmount) || 0; }
    if (at < windowStart) continue;
    const code = String(rd.couponCode || 'UNKNOWN');
    const t = top.get(code) || { code, redemptions: 0, discountInr: 0, netInr: 0 };
    t.redemptions++; t.discountInr += Number(rd.discountAmount) || 0; t.netInr += Number(rd.finalAmount) || 0;
    top.set(code, t);
  }

  const fix = (o) => { for (const k of Object.keys(o)) if (typeof o[k] === 'number' && !Number.isInteger(o[k])) o[k] = round2(o[k]); return o; };
  return {
    currency: 'INR',
    timezone: 'Asia/Kolkata',
    excludesStaff: true,
    generatedAt: now,
    totals: fix({ ...totals, activePaidPlans: Object.values(activeNow).reduce((s, n) => s + n, 0) }),
    activePaidPlans: activeNow,
    byPlan: Object.values(byPlan).map(fix).sort((a, b) => b.netInr - a.netInr),
    daily: [...daily.values()].map(fix),
    monthly: [...monthly.values()].map(fix),
    topCoupons: [...top.values()].map(fix).sort((a, b) => b.redemptions - a.redemptions).slice(0, 10),
  };
}

/** API router for /api/admin/web (mounted behind requireAuth + requireAdmin). */
function webAdminApi({ repo, config }) {
  const r = express.Router();
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  r.get('/config', (req, res) => {
    const origin = config.publicOrigin || `${req.protocol}://${req.get('host')}`;
    res.json({
      publicOrigin: origin,
      plansUrl: `${origin}/plans`,
      paymentsEnabled: config.paymentsEnabled !== false,
      version: require('../package.json').version,
      user: { userId: req.user.userId, name: req.user.name || '', email: req.user.email || '', role: req.user.role },
    });
  });
  r.get('/revenue', async (req, res, next) => {
    try {
      const days = Math.min(366, Math.max(7, parseInt(req.query.days, 10) || 30));
      const months = Math.min(36, Math.max(3, parseInt(req.query.months, 10) || 12));
      res.json(await revenueSummary(repo, { days, months }));
    } catch (e) { next(e); }
  });
  return r;
}

module.exports = { ADMIN_CSP, webAdminPages, webAdminApi, revenueSummary, monthKeys };
