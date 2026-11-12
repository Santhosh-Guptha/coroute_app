'use strict';
/**
 * 3.57 round 3: Riders in the web admin (docs/features_355/web_riders_admin.md). The app admin had a riders list;
 * the browser console now has one too, with a rider page and three actions an admin takes for one person:
 * assign a plan, give a personal coupon, send an e-mail. Every action reuses the existing code path:
 *
 *   assign plan  -> admin_plans.assignPlan (the app console's "Change plan": a ₹0 ADMIN order + membership)
 *   coupon       -> EmailStudio.issueUniqueCode (single-use, only this rider, the e-mail studio's unique codes)
 *   e-mail       -> EmailStudio.sendDirect (the studio renderer, footer, suppression, idempotent mail_log row)
 *
 * Routes (requireAuth + requireAdmin = MASTER_ADMIN; rate limited per admin; every write audited, target = userId):
 *   GET  /api/admin/riders                       list: search, filters, sort, pages (no phone, no medical data)
 *   GET  /api/admin/riders/:userId               rider page (emergency contact: present or not, never the number)
 *   POST /api/admin/riders/:userId/preview       an e-mail as this rider gets it (sandboxed preview frame)
 *   POST /api/admin/riders/:userId/email/check   consent / suppression / classification of a draft
 *   POST /api/admin/riders/:userId/assign-plan   { plan, days | until, reason, sendEmail }
 *   POST /api/admin/riders/:userId/coupon        { parentCode | quick, validDays, reason, sendEmail, service, serviceNote }
 *   POST /api/admin/riders/:userId/email         { design, category, templateId, uniqueCoupon, service, serviceNote }
 *   GET  /api/admin/email-wizard/templates       "Plan assigned", "Coupon for you", "Welcome" as studio designs
 *   GET  /api/admin/search?q=                    global search: riders, orders, coupon codes
 *   GET  /api/me/coupons                         (rider) personal coupons given to me, for /account
 *
 * Consent (India DPDP Act): a coupon or price is marketing. A 1:1 marketing e-mail goes only to a rider with the
 * Offers consent, or when the admin ticks "service message (rider asked for it)" with a note (audited); a bounce,
 * complaint or admin suppression always blocks. Transactional e-mails (plan assigned, account messages) need no
 * consent and skip only hard-suppressed addresses.
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { COLLECTIONS: C } = require('./oracle/repo');
const { scan, riderTotals, ownedMembershipMap, riderRow } = require('./admin_analytics');
const { assignPlan, planView, AdminPlanError } = require('./admin_plans');
const { StudioError, discountText, C: STUDIO_C } = require('./email_marketing');
const { cleanCouponCode } = require('./web_shop');
const { staffEmails } = require('./staff');

const DAY = 86400000;
const IST = 330 * 60000;
const USER_ID = /^[A-Za-z0-9_.:-]{3,80}$/;
const REQUEST_ID = /^[A-Za-z0-9_-]{8,40}$/;
const PLANS = Object.freeze(['group_small', 'group_large', 'community']);
const SORTS = Object.freeze({
  lastActive: (a, b) => b.lastSeenAt - a.lastSeenAt,
  joined: (a, b) => b.createdAt - a.createdAt,
  rides: (a, b) => b.rides - a.rides || b.lastSeenAt - a.lastSeenAt,
  name: (a, b) => (a.username || a.name).localeCompare(b.username || b.name),
  planEnds: (a, b) => (a.planValidUntil || Infinity) - (b.planValidUntil || Infinity),
});
const LAST_RIDE = Object.freeze({ '7d': [7, 'within'], '30d': [30, 'within'], '90d': [90, 'within'], over30d: [30, 'over'], over90d: [90, 'over'], never: [0, 'never'] });

class RiderActionError extends Error {
  constructor(message, code = 'BAD_REQUEST', status = 400, extra = {}) { super(message); this.code = code; this.status = status; Object.assign(this, extra); }
}

const oneLine = (s) => String(s == null ? '' : s).replace(/[\u0000-\u001f\u007f\u2028\u2029]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const clampInt = (v, lo, hi, d) => { const n = parseInt(v, 10); return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : d; };
const hasEmergencyContact = (u) => !!(String(u.emergencyContact || '').trim() || (Array.isArray(u.emergencyContacts) && u.emergencyContacts.length));
function istDate(ms) {
  const t = Number(ms);
  if (!Number.isFinite(t) || t <= 0) return '';
  return new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' }).format(new Date(t));
}
/** 'YYYY-MM-DD' (India day) or epoch ms -> ms; `end` = the end of that India day. */
function dayOrMs(v, end = false) {
  if (v === undefined || v === null || v === '') return 0;
  if (/^\d{4}-\d{2}-\d{2}$/.test(String(v))) {
    const [y, m, d] = String(v).split('-').map(Number);
    return Date.UTC(y, m - 1, d) - IST + (end ? DAY - 1 : 0);
  }
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : NaN;
}
function reasonOf(b, { required = true } = {}) {
  const r = oneLine(b.reason).slice(0, 500);
  if (required && r.length < 3) throw new RiderActionError('Write a short reason (at least 3 characters). It goes in the audit log.', 'REASON_REQUIRED');
  return r;
}

// ------------------------------------------------------------------ system e-mail designs (templates.js words)
/** templates.js {{var}} -> e-mail studio {var}, per template. Anything else is replaced by its constant or removed. */
const VAR_MAP = Object.freeze({
  plan_assigned: { name: 'firstName', username: 'username', plan: 'planName', validUntil: 'planEndsOn' },
  coupon_gift: { name: 'firstName', username: 'username', code: 'couponCode', discount: 'discount', validUntil: 'validUntil' },
  welcome: { name: 'firstName', username: 'username' },
});
function toStudio(text, map, consts = {}) {
  return String(text || '').replace(/[{}](?![{}])/g, (c, i, s) => ((s[i - 1] === c) ? c : ''))
    .replace(/\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}/g, (m, k) => (map[k] ? `{${map[k]}}` : String(consts[k] == null ? '' : consts[k])));
}

/**
 * The words of the editable "Plan assigned", "Coupon for you" and "Welcome" templates (Settings > Templates) as
 * e-mail studio designs, so one renderer lays out every e-mail. Returns { id, name, category, description, design }.
 */
async function systemDesign(templates, id, { origin = '', supportEmail = '' } = {}) {
  const f = await templates.fields(id);
  const map = VAR_MAP[id];
  const consts = { guideUrl: `${origin}/guide`, accountUrl: `${origin}/account`, supportEmail: supportEmail || 'the website contact form' };
  const t = (k) => toStudio(f[k], map, consts);
  const footer = { type: 'footer', note: t('footer') };
  if (id === 'plan_assigned') {
    return { id, name: 'Plan assigned', category: 'account', description: 'Tells a rider the plan you gave them and when it ends. Account e-mail: no offer consent needed.',
      design: { subject: t('subject'), preheader: 'Active now, until {planEndsOn}.', blocks: [{ type: 'heading', text: t('heading'), level: 1 }, { type: 'text', text: t('intro') },
        { type: 'button', label: t('buttonLabel').slice(0, 40), path: '/account', style: 'primary' }, footer] } };
  }
  if (id === 'coupon_gift') {
    return { id, name: 'Coupon for you', category: 'marketing', description: 'A personal coupon with a "Use on plans" button. Offer e-mail: only riders who agreed to offers.',
      design: { subject: t('subject'), preheader: '{discount}, until {validUntil}.', blocks: [{ type: 'heading', text: t('heading'), level: 1 }, { type: 'text', text: t('intro') },
        { type: 'coupon', code: '', headline: 'Your personal code', note: 'One use, only on your account.', buttonLabel: t('buttonLabel').slice(0, 40) }, footer] } };
  }
  if (id === 'welcome') {
    return { id, name: 'Welcome', category: 'account', description: 'The welcome e-mail words: three first steps and the quick start guide.',
      design: { subject: t('subject'), preheader: 'Three quick steps before your first ride.', blocks: [{ type: 'heading', text: t('heading'), level: 1 }, { type: 'text', text: t('intro') },
        { type: 'text', text: [t('step1'), t('step2'), t('step3')].map((x) => `- ${x}`).join('\n') }, { type: 'text', text: t('safetyLine') }, { type: 'text', text: t('guideLine') },
        { type: 'button', label: 'Open the quick start guide', path: '/guide', style: 'primary' }, footer] } };
  }
  throw new RiderActionError('Unknown template.', 'NOT_FOUND', 404);
}
const SYSTEM_IDS = Object.freeze(['welcome', 'plan_assigned', 'coupon_gift']);

// ------------------------------------------------------------------ service
class RiderAdmin {
  constructor({ repo, auth = null, hub = null, convoys = null, studio, templates, lifecycle = null, diagLogs = null, config = {}, clock = Date.now, cacheMs = 30000 } = {}) {
    this.repo = repo; this.soda = repo.soda; this.auth = auth; this.hub = hub; this.convoys = convoys; this.lifecycle = lifecycle;
    this.studio = studio; this.templates = templates; this.diagLogs = diagLogs; this.config = config; this.clock = clock; this.cacheMs = cacheMs;
    this.cache = null;
  }

  origin() { return this.studio && typeof this.studio.origin === 'function' ? this.studio.origin() : String(this.config.publicOrigin || '').replace(/\/+$/, ''); }
  design(id) { return systemDesign(this.templates, id, { origin: this.origin(), supportEmail: String(this.config.supportEmail || '').trim() }); }
  invalidate() { this.cache = null; }

  /** Every rider as a list row (cached for a short time: one pass over users, trips, alerts, memberships). */
  async rows() {
    const now = this.clock();
    if (this.cache && this.cache.until > now) return this.cache.value;
    const [users, totals, memberships, crewAdmins, operators] = await Promise.all([
      scan(this.soda, C.users), riderTotals(this.repo), scan(this.soda, C.memberships, {}, { cap: 20000 }),
      this.soda.query('crew_members', { role: { $in: ['ADMIN', 'CO_ADMIN'] } }, { limit: 100000 }).catch(() => []),
      this.soda.query('operators', { status: 'APPROVED' }, { limit: 20000 }).catch(() => []),
    ]);
    const owned = ownedMembershipMap(memberships.rows, now);
    const emails = staffEmails();
    const crew = new Set(crewAdmins.map((r) => r.value && r.value.userId).filter(Boolean));
    const ops = new Set();
    for (const r of operators) {
      const op = r.value || {};
      if (num(op.validUntil) > 0 && num(op.validUntil) <= now) continue;
      if (op.ownerId) ops.add(op.ownerId);
      for (const c of op.coOrganisers || []) ops.add(c);
    }
    const value = users.rows.filter((u) => u && u.userId && !u.deletedAt).map((u) => {
      const x = riderRow(u, totals.by, new Map(), now, emails, owned);
      const t = totals.by.get(u.userId) || {};
      // PII minimisation: no phone, no medical data, emergency contact only as present / not present.
      return {
        userId: x.userId, username: x.username, name: x.name, email: x.email, avatarUrl: x.avatarUrl || null,
        role: x.role, status: x.status, staff: x.staff, guest: x.guest,
        plan: x.tier, planName: x.planName, planSource: x.planSource, planValidUntil: x.planValidUntil,
        rides: x.trips, km: x.km, lastRideAt: num(t.lastTripAt), lastSeenAt: x.lastSeenAt, createdAt: x.createdAt,
        hasEmergencyContact: hasEmergencyContact(u), crewAdmin: crew.has(u.userId), operator: ops.has(u.userId),
      };
    });
    this.cache = { value, until: now + this.cacheMs, truncated: users.truncated || totals.truncated };
    return value;
  }

  async list(q = {}) {
    const now = this.clock();
    let rows = await this.rows();
    const text = oneLine(q.q).toLowerCase().replace(/^@/, '').slice(0, 100);
    if (text) rows = rows.filter((x) => x.userId === text || [x.username, x.name, x.email].some((v) => String(v || '').toLowerCase().includes(text)));
    const plan = String(q.plan || '');
    if (plan === 'paid') rows = rows.filter((x) => x.plan !== 'community');
    else if (PLANS.includes(plan)) rows = rows.filter((x) => x.plan === plan);
    const status = String(q.status || '').toUpperCase();
    if (['ACTIVE', 'ON_HOLD', 'BLOCKED'].includes(status)) rows = rows.filter((x) => x.status === status);
    const from = dayOrMs(q.joinedFrom); const to = dayOrMs(q.joinedTo, true);
    if (from > 0) rows = rows.filter((x) => x.createdAt >= from);
    if (to > 0) rows = rows.filter((x) => x.createdAt <= to);
    const lr = LAST_RIDE[String(q.lastRide || '')];
    if (lr) {
      const [d, kind] = lr;
      if (kind === 'within') rows = rows.filter((x) => x.lastRideAt >= now - d * DAY);
      else if (kind === 'over') rows = rows.filter((x) => x.lastRideAt > 0 && x.lastRideAt < now - d * DAY);
      else rows = rows.filter((x) => !x.rides);
    }
    const role = String(q.role || '');
    if (role === 'operator') rows = rows.filter((x) => x.operator);
    else if (role === 'crew_admin') rows = rows.filter((x) => x.crewAdmin);
    else if (role === 'admin') rows = rows.filter((x) => x.role === 'MASTER_ADMIN');
    if (q.emergency === 'yes') rows = rows.filter((x) => x.hasEmergencyContact);
    else if (q.emergency === 'no') rows = rows.filter((x) => !x.hasEmergencyContact);
    const staffMode = String(q.staff || '0');
    const staffCount = rows.filter((x) => x.staff).length;
    if (staffMode === '0') rows = rows.filter((x) => !x.staff);
    else if (staffMode === '1') rows = rows.filter((x) => x.staff);
    const sort = Object.hasOwn(SORTS, q.sort) ? q.sort : 'lastActive';
    rows = rows.slice().sort(SORTS[sort]);
    if (q.dir === 'asc') rows.reverse();
    const limit = clampInt(q.limit, 1, 100, 25);
    const pages = Math.max(1, Math.ceil(rows.length / limit));
    const page = clampInt(q.page, 1, pages, 1);
    return { riders: rows.slice((page - 1) * limit, page * limit), total: rows.length, page, pages, limit, sort, staffCount, excludesStaff: staffMode === '0', truncated: !!(this.cache && this.cache.truncated) };
  }

  async user(userId) {
    if (!USER_ID.test(String(userId || ''))) throw new RiderActionError('Rider not found.', 'NOT_FOUND', 404);
    const u = await this.repo.findUserById(String(userId));
    if (!u || u.deletedAt) throw new RiderActionError('Rider not found.', 'NOT_FOUND', 404);
    return u;
  }

  /** The rider page. Nothing medical; the emergency contact only as present / not present. */
  async detail(userId) {
    const u = await this.user(userId);
    const now = this.clock();
    const uid = u.userId;
    const [plan, orders, redemptions, codes, trips, audit, consent, prefs, diags, crewRows, emails] = await Promise.all([
      planView(this.repo, u, now),
      scan(this.soda, C.subscriptionConfig, { k: 'rzp_order', userId: uid }, { cap: 2000 }).then((r) => r.rows),
      typeof this.repo.listCouponRedemptions === 'function' ? this.repo.listCouponRedemptions({ userId: uid }, 200).catch(() => []) : [],
      this.soda.query(STUDIO_C.codes, { userId: uid }, { limit: 200 }).then((r) => r.map((x) => x.value)).catch(() => []),
      scan(this.soda, C.trips, { userId: uid }, { cap: 5000 }).then((r) => r.rows),
      scan(this.soda, C.subscriptionConfig, { k: 'audit', target: uid }, { cap: 500 }).then((r) => r.rows),
      this.studio && this.studio.offers ? this.studio.offers.consentOf(uid).catch(() => ({ offersEmail: false })) : { offersEmail: false },
      this.lifecycle && typeof this.lifecycle.prefsOf === 'function' ? this.lifecycle.prefsOf(uid).catch(() => null) : null,
      this.diagLogs && typeof this.diagLogs.list === 'function' ? this.diagLogs.list({ userId: uid, days: 30, limit: 10 }).catch(() => []) : [],
      this.soda.query('crew_members', { userId: uid }, { limit: 50 }).then((r) => r.map((x) => x.value)).catch(() => []),
      this.studio && typeof this.studio.directLog === 'function' ? this.studio.directLog(uid).catch(() => []) : [],
    ]);
    const check = this.studio ? await this.studio.directCheck(u, 'marketing').catch(() => null) : null;
    const rideLock = this.rideLock ? await this.rideLock.view(uid).catch(() => ({ onRide: false })) : { onRide: false };
    const assigned = [];
    for (const c of codes.sort((a, b) => num(b.createdAt) - num(a.createdAt)).slice(0, 50)) {
      const doc = await this.repo.findCoupon(c.code).catch(() => null);
      assigned.push({
        code: c.code, parentCode: c.parentCode || null, source: String(c.campaignId || '').startsWith('gift_') ? 'personal' : String(c.campaignId || '').startsWith('dm_') ? 'direct e-mail' : String(c.campaignId || '').startsWith('test_') ? 'test send' : 'e-mail campaign',
        discount: doc ? discountText(doc) : '', status: doc ? doc.status : 'MISSING', used: doc ? num(doc.usageCount) > 0 : false, createdAt: num(c.createdAt), expiresAt: num(c.expiresAt),
      });
    }
    const tripEnds = trips.map((t) => num(t.endTimeEpochMs)).filter((x) => x > 0);
    const km = trips.reduce((s, t) => s + (num(t.totalDistanceKm) || num(t.distanceM) / 1000), 0);
    const ops = await this.soda.query('operators', { status: 'APPROVED' }, { limit: 20000 }).catch(() => []);
    const operator = ops.some((r) => r.value && (r.value.ownerId === uid || (r.value.coOrganisers || []).includes(uid)));
    return {
      ok: true,
      rider: {
        userId: uid, username: u.username || '', name: u.name || '', email: u.email || '', avatarUrl: require('./avatars').avatarUrlOf(u.avatarId) || null,
        role: u.role || 'RIDER', status: u.status || 'ACTIVE', statusReason: u.statusReason || '', provider: u.provider || 'password',
        createdAt: num(u.createdAt), lastSeenAt: Math.max(num(u.lastActiveAt || u.lastLoginAt), tripEnds.length ? Math.max(...tripEnds) : 0), appBuild: num(u.appBuild) || null,
        hasEmergencyContact: hasEmergencyContact(u), crewAdmin: crewRows.some((m) => m && ['ADMIN', 'CO_ADMIN'].includes(m.role)), crews: crewRows.length, operator,
      },
      plan,
      rideLock,
      payments: orders.sort((a, b) => num(b.createdAt) - num(a.createdAt)).slice(0, 50).map((o) => ({
        orderId: o.orderId, status: o.status || 'CREATED', amountInr: num(o.amountInPaise) / 100, refundedInr: num(o.refundedAmountInPaise) / 100, mode: o.mode || null,
        method: o.method || null, plan: o.category || o.planTier || null, couponCode: o.couponCode || o.offerCode || null, createdAt: num(o.createdAt), paidAt: num(o.paidAt),
        grantedBy: o.grantedBy || null, reason: o.transactionType === 'ADMIN_GRANT' ? (o.reason || '') : undefined, receipt: o.status === 'PAID' && num(o.amountInPaise) > 0,
      })),
      coupons: {
        used: redemptions.sort((a, b) => num(b.redeemedAt || b.createdAt) - num(a.redeemedAt || a.createdAt)).slice(0, 30)
          .map((r) => ({ code: r.couponCode, status: r.status, discountInr: num(r.discountAmount), paidInr: num(r.finalAmount), orderId: r.orderId || null, at: num(r.redeemedAt || r.reservedAt || r.createdAt) })),
        assigned,
      },
      emails: {
        hasEmail: !!(check && check.hasEmail), offersConsent: !!consent.offersEmail, consentUpdatedAt: num(consent.updatedAt),
        rideSummaries: prefs ? prefs.rideSummaries : null, tipsNews: prefs ? prefs.tipsNews : null, suppressed: check ? check.suppressed : null, recent: emails,
      },
      rides: {
        count: trips.length, km: Math.round(km * 10) / 10, lastRideAt: tripEnds.length ? Math.max(...tripEnds) : 0,
        recent: trips.sort((a, b) => num(b.endTimeEpochMs) - num(a.endTimeEpochMs)).slice(0, 8).map((t) => ({
          tripId: t.tripId, name: oneLine(t.tripName || t.name || 'Ride').slice(0, 80), endedAt: num(t.endTimeEpochMs), km: Math.round((num(t.totalDistanceKm) || num(t.distanceM) / 1000) * 10) / 10,
          minutes: Math.round(Math.max(0, num(t.endTimeEpochMs) - num(t.startTimeEpochMs)) / 60000), group: !!t.groupId,
        })),
      },
      diagnostics: (diags || []).map((d) => ({ id: d.id || d.logId, at: num(d.at || d.createdAt), reason: d.reason || '', build: d.build || '', bytes: num(d.bytes || d.size) })),
      audit: audit.sort((a, b) => num(b.at) - num(a.at)).slice(0, 50).map((e) => ({ at: num(e.at), by: e.by || null, action: e.action || '', details: e.details || {} })),
    };
  }

  // ---------------------------------------------------------------- actions
  async assignPlan(req, userId, body = {}) {
    const b = body && typeof body === 'object' ? body : {};
    const u = await this.user(userId);
    const plan = String(b.plan || '');
    if (!PLANS.includes(plan)) throw new RiderActionError(`Choose a plan: ${PLANS.join(', ')}.`, 'BAD_PLAN');
    const reason = reasonOf(b);
    const now = this.clock();
    let days = 0;
    if (plan !== 'community') {
      if (b.until !== undefined && b.until !== null && b.until !== '') {
        const until = dayOrMs(b.until, true);
        if (!(until > now)) throw new RiderActionError('"Until" must be a date in the future.', 'BAD_DAYS');
        days = Math.ceil((until - now) / DAY);
      } else days = Number(b.days);
      if (!Number.isInteger(days) || days < 1 || days > 3660) throw new RiderActionError('Days: a whole number from 1 to 3660 (or pick an end date).', 'BAD_DAYS');
    }
    let out;
    try {
      out = await assignPlan({ repo: this.repo, auth: this.auth, hub: this.hub, convoys: this.convoys, req, userDoc: u, plan, days, note: reason });
    } catch (e) {
      if (e instanceof AdminPlanError) throw new RiderActionError(e.message, e.code, e.status);
      throw e;
    }
    this.invalidate();
    await this.audit(req, 'rider.assign_plan', u.userId, { plan, days, reason, orderId: out.orderId || null, validUntil: out.plan ? out.plan.validUntil : null, sendEmail: b.sendEmail !== false && plan !== 'community' });
    let email = null;
    if (b.sendEmail !== false && plan !== 'community' && out.orderId) {
      email = await this.sendSystem(req, u, 'plan_assigned', { key: `plan_assigned:${out.orderId}`, why: 'You get this e-mail because the CoRoute team changed your plan.' });
    }
    return { ok: true, changed: out.changed, orderId: out.orderId || null, plan: out.plan, email };
  }

  async giveCoupon(req, userId, body = {}) {
    const b = body && typeof body === 'object' ? body : {};
    const u = await this.user(userId);
    const reason = reasonOf(b);
    const validDays = Math.round(Number(b.validDays === undefined ? 14 : b.validDays));
    if (!(validDays >= 1 && validDays <= 90)) throw new RiderActionError('Valid for 1 to 90 days.', 'BAD_DAYS');
    if (b.requestId !== undefined && !REQUEST_ID.test(String(b.requestId))) throw new RiderActionError('Bad request id.', 'BAD_REQUEST');
    let parent; let prefix;
    if (b.parentCode) {
      const code = cleanCouponCode(b.parentCode);
      if (!code) throw new RiderActionError('A coupon code has letters, digits, - and _ only.', 'BAD_COUPON');
      const r = await this.studio.couponProblem(code, { unique: true });
      if (r.problem) throw new RiderActionError(r.problem, 'BAD_COUPON', 409);
      parent = r.coupon;
      // The parent's letters (DIWALI40 -> DIWALI), so the personal code reads like its coupon.
      prefix = code.replace(/[^A-Z]/g, '').slice(0, 6);
      if (prefix.length < 2) prefix = 'GIFT';
    } else if (b.quick && typeof b.quick === 'object') {
      const type = b.quick.discountType === 'fixed' ? 'fixed' : b.quick.discountType === 'percentage' ? 'percentage' : null;
      const value = Number(b.quick.discountValue);
      if (!type) throw new RiderActionError('Quick coupon: percent or amount off.', 'BAD_COUPON');
      if (type === 'percentage' && !(Number.isInteger(value) && value >= 1 && value <= 100)) throw new RiderActionError('Percent off: a whole number from 1 to 100.', 'BAD_COUPON');
      if (type === 'fixed' && !(Number.isFinite(value) && value >= 1 && value <= 100000)) throw new RiderActionError('Amount off: ₹1 to ₹100000.', 'BAD_COUPON');
      const plans = Array.isArray(b.quick.plans) ? [...new Set(b.quick.plans.map(String))] : [];
      if (plans.some((p) => !['group_small', 'group_large'].includes(p))) throw new RiderActionError('Plans: group_small and / or group_large.', 'BAD_COUPON');
      parent = { code: 'PERSONAL', name: 'Personal coupon', description: '', discountType: type, discountValue: type === 'percentage' ? value : Math.round(value),
        maxDiscountCap: null, minOrderAmount: 0, applicableTiers: plans.length ? plans : ['all'], expiresAt: this.clock() + validDays * DAY, newMembersOnly: false, firstPaymentOnly: false };
      prefix = 'GIFT';
    } else {
      throw new RiderActionError('Pick a coupon, or make a quick one.', 'BAD_COUPON');
    }
    const by = (req.user && (req.user.email || req.user.userId)) || 'admin';
    const campaignId = `gift_${crypto.createHash('sha256').update(`${u.userId}:${b.requestId || crypto.randomBytes(8).toString('hex')}`).digest('hex').slice(0, 16)}`;
    const code = await this.studio.issueUniqueCode(parent, { campaignId, userId: u.userId, prefix, validDays, campaignName: 'Personal coupon (web admin)',
      createdBy: `web-admin:${by}`, notes: `Personal coupon for one rider from the web admin by ${by}. Reason: ${reason}`.slice(0, 500) });
    const coupon = await this.repo.findCoupon(code);
    const view = { code, discount: discountText(coupon), expiresAt: num(coupon.expiresAt), validUntil: istDate(coupon.expiresAt), parentCode: parent.code, plansUrl: `${this.origin()}/plans?coupon=${encodeURIComponent(code)}` };
    const service = b.service === true;
    const serviceNote = oneLine(b.serviceNote).slice(0, 300);
    await this.audit(req, 'rider.coupon', u.userId, { code, parent: parent.code, discount: view.discount, validUntil: view.expiresAt, reason, sendEmail: b.sendEmail === true, service, serviceNote: service ? serviceNote : undefined });
    let email = null;
    if (b.sendEmail === true) {
      email = await this.sendSystem(req, u, 'coupon_gift', { key: `coupon_gift:${code}`, couponDoc: coupon, service, serviceNote });
      if (service && email && email.sent) await this.audit(req, 'rider.email.service', u.userId, { template: 'coupon_gift', code, serviceNote });
    }
    return { ok: true, coupon: view, email };
  }

  /** Sends one of the system templates; a refusal (consent, suppression, no SMTP) is reported, never thrown. */
  async sendSystem(req, u, id, { key, couponDoc = null, service = false, serviceNote = '', why = null } = {}) {
    const sys = await this.design(id);
    try {
      const r = await this.studio.sendDirect(u.userId, { design: sys.design, category: sys.category, couponDoc, service, serviceNote, key, why, meta: { template: id } }, { by: byOf(req) });
      if (!r.duplicate) await this.audit(req, 'rider.email', u.userId, { template: id, subject: sys.design.subject, category: r.category, classification: r.classification, sent: r.sent, error: r.error || undefined });
      return { sent: r.sent, duplicate: !!r.duplicate, to: r.to, classification: r.classification, error: r.error || null };
    } catch (e) {
      if (e instanceof StudioError) return { sent: false, code: e.code, reason: e.message, classification: e.check ? e.check.classification : null };
      throw e;
    }
  }

  async sendEmail(req, userId, body = {}) {
    const b = body && typeof body === 'object' ? body : {};
    const u = await this.user(userId);
    if (b.requestId !== undefined && !REQUEST_ID.test(String(b.requestId))) throw new RiderActionError('Bad request id.', 'BAD_REQUEST');
    if (!b.design || typeof b.design !== 'object') throw new RiderActionError('Write the e-mail first.', 'BAD_EMAIL');
    const service = b.service === true;
    const serviceNote = oneLine(b.serviceNote).slice(0, 300);
    const templateId = b.templateId ? String(b.templateId).slice(0, 40) : null;
    const key = `email:${u.userId}:${b.requestId || crypto.randomBytes(8).toString('hex')}`;
    const r = await this.studio.sendDirect(u.userId, { design: b.design, category: b.category, uniqueCoupon: b.uniqueCoupon, service, serviceNote, key, meta: { template: templateId } }, { by: byOf(req) });
    if (!r.duplicate) {
      await this.audit(req, 'rider.email', u.userId, { template: templateId, subject: oneLine(b.design.subject).slice(0, 150), category: r.category, classification: r.classification, sent: r.sent,
        service, serviceNote: service ? serviceNote : undefined, couponCode: r.couponCode || undefined });
    }
    return { ok: true, sent: r.sent, duplicate: !!r.duplicate, to: r.to, classification: r.classification, category: r.category, couponCode: r.couponCode || null, error: r.error || null };
  }

  /** A preview as this rider gets it: rider name, the plan / coupon the action will give (vars), the footer. */
  async preview(userId, body = {}) {
    const b = body && typeof body === 'object' ? body : {};
    const u = await this.user(userId);
    let design = b.design; let category = b.category === 'account' ? 'account' : 'marketing';
    let couponDoc = null; const vars = {};
    if (SYSTEM_IDS.includes(String(b.system || ''))) {
      const sys = await this.design(String(b.system));
      design = sys.design; category = sys.category;
    }
    if (b.coupon && typeof b.coupon === 'object') {
      const type = b.coupon.discountType === 'fixed' ? 'fixed' : 'percentage';
      couponDoc = { code: cleanCouponCode(b.coupon.code) || 'GIFT-SAMPLE01', discountType: type, discountValue: Number(b.coupon.discountValue) || 0, maxDiscountCap: Number(b.coupon.maxDiscountCap) || null, expiresAt: Number(b.coupon.expiresAt) || this.clock() + 14 * DAY };
    }
    if (b.planName) vars.planName = oneLine(b.planName).slice(0, 60);
    if (b.planEndsOn) vars.planEndsOn = istDate(dayOrMs(b.planEndsOn, true)) || oneLine(b.planEndsOn).slice(0, 30);
    const prep = await this.studio.prepare({ design, category, uniqueCoupon: b.uniqueCoupon }, { forSend: !!couponDoc, couponDoc });
    const unique = prep.unique && prep.coupon ? `${prep.unique.prefix}-SAMPLE01` : null;
    const check = await this.studio.directCheck(u, prep.category, { service: b.service === true, serviceNote: b.serviceNote });
    const why = prep.category === 'account' ? (b.system === 'plan_assigned' ? 'You get this e-mail because the CoRoute team changed your plan.' : require('./email_marketing').SERVICE_WHY)
      : check.classification === 'service' ? 'You get this e-mail because you asked the CoRoute team for it.' : null;
    const opts = { couponCode: couponDoc ? couponDoc.code : unique, couponExpiresAt: couponDoc ? couponDoc.expiresAt : null, previewImages: true, vars, why, omitMissingAddress: prep.category === 'account', mailKind: 'direct' };
    const m = await this.studio.build(prep, u, opts);
    const token = await this.studio.storePreview(m.html);
    const dark = await this.studio.storePreview((await this.studio.build(prep, u, { ...opts, forceDark: true })).html);
    return { subject: m.subject, preheader: m.preheader, text: m.text, category: prep.category, warnings: prep.warnings, check, design: prep.design,
      previewUrl: `/email/preview/${token}`, darkPreviewUrl: `/email/preview/${dark}`, postalAddressSet: !!this.studio.postalAddress() };
  }

  async check(userId, body = {}) {
    const u = await this.user(userId);
    const b = body && typeof body === 'object' ? body : {};
    return this.studio.directCheck(u, b.category === 'account' ? 'account' : 'marketing', { service: b.service === true, serviceNote: b.serviceNote });
  }

  /** Round 4 ride lock: "On a ride (device)" on the rider page (no ride details, no place). */
  async rideLockView(userId) {
    const u = await this.user(userId);
    return this.rideLock ? this.rideLock.view(u.userId) : { onRide: false };
  }

  /** Round 4 "End ride lock" (MASTER_ADMIN, reason required, audited in both audit trails). */
  async endRideLock(req, userId, body = {}) {
    const u = await this.user(userId);
    if (!this.rideLock) throw new RiderActionError('Ride lock is not available on this server.', 'UNAVAILABLE', 503);
    const reason = String((body && body.reason) || '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 300);
    if (reason.length < 3) throw new RiderActionError('Give a reason (at least 3 characters).', 'REASON_REQUIRED');
    const out = await this.rideLock.adminEnd(u.userId, { by: byOf(req), reason });
    await this.audit(req, 'rider.ride_lock_end', u.userId, { reason, ended: out.ended, device: out.device || null });
    return out;
  }

  async audit(req, action, target, details) {
    if (typeof this.repo.addAuditEntry !== 'function') return;
    try { await this.repo.addAuditEntry({ at: Date.now(), by: byOf(req), byUserId: req.user ? req.user.userId : null, action, target, details }); } catch { /* never in the way */ }
  }

  // ---------------------------------------------------------------- global search
  async search(qRaw) {
    const q = oneLine(qRaw).slice(0, 80);
    if (q.length < 2) return { riders: [], orders: [], coupons: [] };
    const low = q.toLowerCase().replace(/^@/, '');
    const riders = (await this.rows()).filter((x) => [x.username, x.email, x.name].some((v) => String(v || '').toLowerCase().includes(low)) || x.userId === q)
      .sort((a, b) => (String(b.username).toLowerCase() === low) - (String(a.username).toLowerCase() === low) || b.lastSeenAt - a.lastSeenAt)
      .slice(0, 6).map((x) => ({ userId: x.userId, username: x.username, name: x.name, email: x.email, avatarUrl: x.avatarUrl, planName: x.planName }));
    const orders = [];
    if (/^[A-Za-z0-9_-]{6,80}$/.test(q)) {
      const hits = [
        ...(await this.soda.query(C.subscriptionConfig, { k: 'rzp_order', orderId: q }, { limit: 3 }).catch(() => [])),
        ...(await this.soda.query(C.subscriptionConfig, { k: 'rzp_order', paymentId: q }, { limit: 3 }).catch(() => [])),
      ];
      const seen = new Set();
      for (const r of hits) {
        const o = r.value; if (!o || seen.has(o.orderId)) continue; seen.add(o.orderId);
        const u = o.userId ? await this.repo.findUserById(o.userId).catch(() => null) : null;
        orders.push({ orderId: o.orderId, status: o.status, amountInr: num(o.amountInPaise) / 100, userId: o.userId || null, username: u ? u.username || '' : '', createdAt: num(o.createdAt) });
      }
    }
    const coupons = [];
    const code = cleanCouponCode(q);
    if (code && code.length >= 3) {
      const all = await this.repo.listCoupons(2000, { includeChildren: true }).catch(() => []);
      for (const c of all.filter((x) => x.code === code || x.code.startsWith(code)).slice(0, 6)) {
        coupons.push({ code: c.code, status: c.status, discount: discountText(c), parentCode: c.parentCode || null, personal: Array.isArray(c.allowedUserIds) && c.allowedUserIds.length === 1 ? c.allowedUserIds[0] : null });
      }
    }
    return { riders, orders, coupons };
  }

  // ---------------------------------------------------------------- the rider's own coupons
  async myCoupons(userId) {
    const rows = await this.soda.query(STUDIO_C.codes, { userId: String(userId) }, { limit: 200 }).then((r) => r.map((x) => x.value)).catch(() => []);
    const now = this.clock();
    const out = [];
    for (const r of rows.sort((a, b) => num(b.createdAt) - num(a.createdAt))) {
      if (String(r.campaignId || '').startsWith('test_')) continue;
      const c = await this.repo.findCoupon(r.code).catch(() => null);
      if (!c || !Array.isArray(c.allowedUserIds) || !c.allowedUserIds.includes(String(userId))) continue;
      const used = num(c.usageCount) > 0;
      const state = used ? 'USED' : c.status === 'ACTIVE' ? 'ACTIVE' : c.status === 'SCHEDULED' ? 'SCHEDULED' : (num(c.expiresAt) && num(c.expiresAt) <= now ? 'EXPIRED' : 'NOT_ACTIVE');
      out.push({ code: c.code, discount: discountText(c), expiresAt: num(c.expiresAt), validUntil: istDate(c.expiresAt), state,
        plans: Array.isArray(c.applicableTiers) && !c.applicableTiers.includes('all') ? c.applicableTiers : [], plansPath: `/plans?coupon=${encodeURIComponent(c.code)}` });
    }
    return out.slice(0, 50);
  }
}

const byOf = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';

// ------------------------------------------------------------------ routers
function wrapFor() {
  return (fn) => async (req, res, next) => {
    try { await fn(req, res); } catch (e) {
      if (e instanceof RiderActionError || e instanceof StudioError) {
        return res.status(e.status || 400).json({ error: e.message, code: e.code, errors: e.errors || undefined, warnings: e.warnings || undefined, check: e.check || undefined });
      }
      next(e);
    }
  };
}
const limiter = (limit, name) => rateLimit({ windowMs: 60 * 1000, limit, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `${name}:${(req.user && req.user.userId) || req.ip}`,
  message: { error: 'Too many requests. Wait a minute.', code: 'RATE_LIMITED' } });

/** /api/admin/riders (mounted behind requireAuth + requireAdmin). */
function adminRidersRouter({ riders }) {
  const r = express.Router();
  const h = wrapFor();
  const read = limiter(120, 'riders-read');
  const write = limiter(30, 'riders-write');
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  r.get('/', read, h(async (req, res) => { if (req.query.fresh === '1') riders.invalidate(); res.json(await riders.list(req.query)); }));
  r.get('/:userId', read, h(async (req, res) => { res.json(await riders.detail(req.params.userId)); }));
  r.post('/:userId/preview', read, h(async (req, res) => { res.json(await riders.preview(req.params.userId, req.body)); }));
  r.post('/:userId/email/check', read, h(async (req, res) => { res.json({ check: await riders.check(req.params.userId, req.body) }); }));
  r.post('/:userId/assign-plan', write, h(async (req, res) => { res.json(await riders.assignPlan(req, req.params.userId, req.body)); }));
  r.post('/:userId/coupon', write, h(async (req, res) => { res.status(201).json(await riders.giveCoupon(req, req.params.userId, req.body)); }));
  r.post('/:userId/email', write, h(async (req, res) => { res.json(await riders.sendEmail(req, req.params.userId, req.body)); }));
  // Round 4 ride lock: view and "End ride lock" (MASTER_ADMIN: this router sits behind requireAdmin).
  r.get('/:userId/ride-lock', read, h(async (req, res) => { res.json(await riders.rideLockView(req.params.userId)); }));
  r.post('/:userId/ride-lock/end', write, h(async (req, res) => { res.json(await riders.endRideLock(req, req.params.userId, req.body)); }));
  return r;
}

/** /api/admin/search and /api/admin/email-wizard (behind requireAuth + requireAdmin). */
function adminSearchRouter({ riders }) {
  const r = express.Router();
  const h = wrapFor();
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  r.get('/', limiter(120, 'search'), h(async (req, res) => { res.json(await riders.search(req.query.q)); }));
  return r;
}
function emailWizardRouter({ riders }) {
  const r = express.Router();
  const h = wrapFor();
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  r.get('/templates', limiter(60, 'wizard'), h(async (req, res) => {
    const system = [];
    for (const id of SYSTEM_IDS) system.push(await riders.design(id));
    res.json({ system });
  }));
  return r;
}

/** GET /api/me/coupons (rider, behind requireAuth): personal codes given to me (never someone else's). */
function meCouponsRouter({ riders }) {
  const r = express.Router();
  r.get('/', limiter(30, 'me-coupons'), async (req, res, next) => {
    try { res.set('Cache-Control', 'no-store').json({ coupons: await riders.myCoupons(req.user.userId) }); } catch (e) { next(e); }
  });
  return r;
}

module.exports = { RiderAdmin, RiderActionError, adminRidersRouter, adminSearchRouter, emailWizardRouter, meCouponsRouter, systemDesign, toStudio, SYSTEM_IDS, VAR_MAP };
