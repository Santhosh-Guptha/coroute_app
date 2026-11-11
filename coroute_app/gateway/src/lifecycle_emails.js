'use strict';
/**
 * 3.57 lifecycle e-mails: the welcome e-mail for every new account and the ride summary ("memory") e-mail
 * after a ride, plus the rider's e-mail categories. Docs: docs/features_355/lifecycle_emails.md.
 *
 * E-mail is outside the Play app, so Play's in-app payment rules do not apply here; marketing and
 * transactional mail are still kept apart for consent (India DPDP Act):
 *
 *   Category         Default   What                                                   Turn off
 *   Account&receipts always    receipts, refunds, the welcome e-mail's account part   never (transactional)
 *   Ride summaries   on        the summary of the rider's own ride                    account page, link in each one
 *   Tips and news    on        the welcome e-mail's group rides / plans block, news   account page, link in each one
 *   Offers           off       plan offers and coupons (offer_emails.js, opt-in)       account page, link in each one
 *
 * Every lifecycle e-mail carries a signed per-category unsubscribe link (/email/unsubscribe?u=&c=&t=,
 * HMAC, no expiry), List-Unsubscribe and List-Unsubscribe-Post (RFC 8058 one-click). GET shows a page with
 * one button (link scanners never unsubscribe anyone), POST turns the category off. Every change of a
 * category is kept with its time and source (collection email_preferences, last 20 changes).
 * Suppression (offer_emails.js email_suppression): an address suppressed for a bounce, a complaint or by
 * an admin gets no lifecycle e-mail. An "unsubscribe" entry (written by the offers unsubscribe) stops
 * offer e-mails only.
 *
 * Sending: rows in mail_log (the purchase e-mail log) with a unique key, inserted BEFORE anything is sent:
 *   welcome:<userId>                once per account (password and Google sign-up alike)
 *   trip_memory:<groupId>:<userId>  once per rider per ride
 * A row is QUEUED with a due time; it is claimed (compare-and-replace to SENDING with a lease) by the
 * process that sends it, so two nodes never both send. The welcome is sent right away in the background
 * (never on the registration request); the ride summary waits TRIP_MEMORY_DELAY_MIN (default 10) after the
 * report, so late track uploads are in it. The leased job 'lifecycle-mail' (every minute) sends what is due
 * in rate-limited batches (LIFECYCLE_EMAIL_RATE per second, default 5) and retries failed sends (3 tries).
 * No SMTP (src/mailer.js disabled): nothing is queued or sent. No valid account e-mail: nothing is queued.
 *
 * Ride summary rules: rides of at least 2 km and 10 minutes, the rider's own trip document only (a trip
 * the rider deleted is skipped). No other rider's name, position or numbers; the route picture (pure-JS
 * PNG, route_png.js) leaves the first and the last 300 m off, and has no map, coordinates or place names.
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { validEmail } = require('./mailer');
const { istDate } = require('./purchase_email');
const { renderRoutePng } = require('./route_png');

const LOG = 'mail_log';
const PREFS = 'email_preferences';
const SETTINGS = 'email_settings';
const KINDS = Object.freeze(['welcome', 'trip_memory']);
const MAX_ATTEMPTS = 3;
const HISTORY_MAX = 20;
const MIN_TRIP_KM = 2;
const MIN_TRIP_MS = 10 * 60000;
const TRIM_M = 300;
/** Categories with a per-category unsubscribe link: link code -> preference field. */
const LINK_CATEGORIES = Object.freeze({ ride_summaries: 'rideSummaries', tips_news: 'tipsNews' });
const CATEGORY_LABEL = Object.freeze({ ride_summaries: 'ride summary e-mails', tips_news: 'tips and news e-mails' });
const HARD_SUPPRESSION = Object.freeze(['bounce', 'complaint', 'admin']);

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const maskEmail = (e) => String(e || '').trim().replace(/^(.).*?(@.*)$/, '$1***$2');
const emailHash = (e) => crypto.createHash('sha256').update(String(e || '').trim().toLowerCase()).digest('hex');
const firstName = (n) => String(n || '').trim().split(/\s+/)[0].slice(0, 40) || 'there';

function categoryToken(secret, category, userId) {
  return crypto.createHmac('sha256', String(secret || '')).update(`email-unsubscribe:v1:${category}:${userId}`).digest('base64url').slice(0, 32);
}
function categoryTokenOk(secret, category, userId, token) {
  if (!LINK_CATEGORIES[category]) return false;
  if (typeof userId !== 'string' || !/^[A-Za-z0-9_.:-]{1,80}$/.test(userId) || typeof token !== 'string' || token.length !== 32) return false;
  const want = Buffer.from(categoryToken(secret, category, userId));
  const got = Buffer.from(token);
  return want.length === got.length && crypto.timingSafeEqual(want, got);
}

/** "128 km", "4.6 km". */
function kmText(km) {
  const v = Math.max(0, Number(km) || 0);
  return v >= 100 ? `${Math.round(v)} km` : `${v.toFixed(1).replace(/\.0$/, '')} km`;
}
/** "3 h 25 min", "42 min". */
function durText(ms) {
  const m = Math.max(0, Math.round((Number(ms) || 0) / 60000));
  const h = Math.floor(m / 60);
  return h ? `${h} h ${m % 60} min` : `${m} min`;
}

/** The calm, branded layout shared by both e-mails (every value escaped; table layout for mail apps). */
function layout({ title, heading, blocks, footerHtml }) {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light">'
    + `<title>${esc(title)}</title></head>`
    + '<body style="margin:0;padding:0;background:#f4f5f7;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">'
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:24px 12px;"><tr><td align="center">'
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:12px;padding:28px 28px 20px;">'
    + '<tr><td style="font-size:15px;font-weight:700;color:#5b4bd6;letter-spacing:.2px;padding-bottom:18px;">CoRoute</td></tr>'
    + `<tr><td style="font-size:22px;font-weight:700;color:#111827;padding-bottom:10px;">${esc(heading)}</td></tr>`
    + blocks.join('')
    + `<tr><td style="font-size:12px;line-height:1.55;color:#6b7280;padding-top:16px;border-top:1px solid #f0f1f3;">${footerHtml}</td></tr>`
    + '</table></td></tr></table></body></html>';
}
const para = (t, style = 'font-size:15px;line-height:1.55;color:#3b4151;padding-bottom:14px;') => `<tr><td style="${style}">${esc(t).replace(/\n/g, '<br>')}</td></tr>`;
const button = (url, label) => `<tr><td style="padding:6px 0 16px;"><a href="${esc(url)}" style="display:inline-block;background:#5b4bd6;color:#ffffff;text-decoration:none;font-weight:600;font-size:14px;padding:11px 18px;border-radius:8px;">${esc(label)}</a></td></tr>`;

class LifecycleEmails {
  constructor({ soda, repo, mailer, templates, offers = null, accessMode = null, config = {}, secret = '', logger = console, clock = Date.now,
    sleep, ratePerSec, tripDelayMs, batchSize = 50, leaseMs = 2 * 60000, env = process.env } = {}) {
    this.soda = soda; this.repo = repo; this.mailer = mailer; this.templates = templates; this.offers = offers; this.accessMode = accessMode;
    this.config = config; this.logger = logger; this.clock = clock;
    this.secret = secret || 'lifecycle-unsubscribe-dev-secret';
    this.sleep = sleep || ((ms) => new Promise((r) => { const t = setTimeout(r, ms); t.unref?.(); }));
    this.ratePerSec = Math.max(1, Number(ratePerSec || env.LIFECYCLE_EMAIL_RATE) || 5);
    const delayMin = env.TRIP_MEMORY_DELAY_MIN !== undefined && env.TRIP_MEMORY_DELAY_MIN !== '' ? Number(env.TRIP_MEMORY_DELAY_MIN) : 10;
    this.tripDelayMs = tripDelayMs !== undefined ? Math.max(0, Number(tripDelayMs) || 0) : Math.max(0, (Number.isFinite(delayMin) ? delayMin : 10) * 60000);
    this.batchSize = Math.max(1, batchSize);
    this.leaseMs = leaseMs;
    this.worker = `${require('os').hostname()}:${process.pid}:${crypto.randomBytes(3).toString('hex')}`;
    this.pending = new Set();
    this.ready = null;
    this.running = false;
  }

  origin() { return String(this.config.publicOrigin || this.config.linkOrigin || '').replace(/\/+$/, ''); }
  get enabled() { return !!(this.mailer && this.mailer.enabled); }

  async ensureStore() {
    if (!this.ready) {
      this.ready = (async () => {
        for (const c of [LOG, PREFS, SETTINGS]) await this.soda.ensureCollection(c);
        await this.soda.ensureIndex(LOG, { name: `${LOG}_key_ux`, unique: true, fields: [{ path: 'key' }] });
        await this.soda.ensureIndex(PREFS, { name: `${PREFS}_user_ux`, unique: true, fields: [{ path: 'userId' }] });
        await this.soda.ensureIndex(SETTINGS, { name: `${SETTINGS}_k_ux`, unique: true, fields: [{ path: 'k' }] });
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  /** Background work (never on the registration / trip request); idle() waits for all of it. */
  _later(fn) {
    const p = new Promise((r) => setImmediate(r)).then(fn).catch((e) => this.logger.warn?.(`[lifecycle-mail] ${e.message}`)).finally(() => this.pending.delete(p));
    this.pending.add(p);
    return p;
  }
  async idle() { while (this.pending.size) await Promise.allSettled([...this.pending]); }

  // ------------------------------------------------------------ links
  unsubscribeUrl(category, userId) {
    return `${this.origin()}/email/unsubscribe?u=${encodeURIComponent(userId)}&c=${category}&t=${categoryToken(this.secret, category, userId)}`;
  }
  accountUrl() { return `${this.origin()}/account#emails`; }
  _headers(kind, category, userId) {
    return { 'X-CoRoute-Mail': kind, 'X-CoRoute-Category': category, 'List-Unsubscribe': `<${this.unsubscribeUrl(category, userId)}>`, 'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click' };
  }

  // ------------------------------------------------------------ preferences
  async prefsOf(userId) {
    await this.ensureStore();
    const row = await this.soda.findOne(PREFS, { userId });
    const v = row ? row.value : {};
    return { rideSummaries: v.rideSummaries !== false, tipsNews: v.tipsNews !== false, updatedAt: v.updatedAt || 0 };
  }

  /** Changes some categories; every change is kept with its time and source. */
  async setPrefs(userId, patch, { source = 'website' } = {}) {
    await this.ensureStore();
    const row = await this.soda.findOne(PREFS, { userId });
    const prev = row ? row.value : { userId, history: [] };
    const now = this.clock();
    const next = { userId, rideSummaries: prev.rideSummaries !== false, tipsNews: prev.tipsNews !== false };
    const history = Array.isArray(prev.history) ? prev.history.slice() : [];
    for (const k of ['rideSummaries', 'tipsNews']) {
      if (typeof patch[k] !== 'boolean' || patch[k] === next[k]) continue;
      next[k] = patch[k];
      history.push({ category: k, on: patch[k], at: now, source: String(source).slice(0, 30) });
    }
    const doc = { ...next, updatedAt: now, history: history.slice(-HISTORY_MAX) };
    await this.soda.upsertBy(PREFS, { userId }, doc);
    return { rideSummaries: doc.rideSummaries, tipsNews: doc.tipsNews, updatedAt: now };
  }

  /** The unsubscribe link / one-click POST of a category. False for a bad token. */
  async unsubscribe(userId, category, token) {
    if (!categoryTokenOk(this.secret, category, userId, token)) return false;
    await this.setPrefs(userId, { [LINK_CATEGORIES[category]]: false }, { source: 'unsubscribe' });
    return true;
  }

  /** Suppressed for a bounce, a complaint or by an admin (an offers "unsubscribe" entry does not count here). */
  async hardSuppressed(email) {
    if (!this.offers || !this.offers.soda) return false;
    try {
      await this.offers.ensureStore();
      const row = await this.offers.soda.findOne('email_suppression', { emailHash: emailHash(email) });
      return !!(row && HARD_SUPPRESSION.includes(row.value.reason));
    } catch { return false; }
  }

  async forgetUser(userId) {
    await this.ensureStore();
    await this.soda.removeWhere(PREFS, { userId }).catch(() => {});
    for (const kind of KINDS) await this.soda.removeWhere(LOG, { userId, kind }).catch(() => {});
  }

  // ------------------------------------------------------------ settings (welcome coupon)
  async settings() {
    await this.ensureStore();
    const row = await this.soda.findOne(SETTINGS, { k: 'lifecycle' });
    const v = row ? row.value : {};
    return { welcomeCoupon: v.welcomeCoupon || '', updatedAt: v.updatedAt || 0, updatedBy: v.updatedBy || null };
  }

  /** The coupon a welcome e-mail may carry: it exists, is ACTIVE now and is public (no rider list). */
  async couponProblem(code) {
    const found = this.repo && typeof this.repo.findCoupon === 'function' ? await this.repo.findCoupon(code).catch(() => null) : null;
    if (!found) return `There is no coupon ${code}. Create it in Coupons first.`;
    if (found.status !== 'ACTIVE') return `Coupon ${code} is not active (${String(found.status || '').toLowerCase().replace(/_/g, ' ')}).`;
    if (Array.isArray(found.allowedUserIds) && found.allowedUserIds.length) return `Coupon ${code} is for chosen riders only. The welcome coupon must be a public coupon.`;
    return null;
  }

  async setSettings(body, { by = 'admin' } = {}) {
    const { cleanCouponCode } = require('./web_shop');
    const b = body && typeof body === 'object' ? body : {};
    const raw = typeof b.welcomeCoupon === 'string' ? b.welcomeCoupon.trim() : '';
    let code = '';
    if (raw) {
      code = cleanCouponCode(raw);
      if (!code) throw Object.assign(new Error('A coupon code has only letters, digits, - and _ (at most 24).'), { status: 400, code: 'BAD_COUPON' });
      const problem = await this.couponProblem(code);
      if (problem) throw Object.assign(new Error(problem), { status: 400, code: 'COUPON_UNUSABLE' });
    }
    await this.ensureStore();
    const row = await this.soda.findOne(SETTINGS, { k: 'lifecycle' });
    const prev = row ? row.value : {};
    const now = this.clock();
    const history = (Array.isArray(prev.history) ? prev.history : []).concat([{ welcomeCoupon: code, at: now, by: String(by).slice(0, 120) }]).slice(-HISTORY_MAX);
    await this.soda.upsertBy(SETTINGS, { k: 'lifecycle' }, { k: 'lifecycle', welcomeCoupon: code, updatedAt: now, updatedBy: String(by).slice(0, 120), history });
    return this.settings();
  }

  // ------------------------------------------------------------ queueing
  /** Inserts the claim row; false when it already exists. */
  async _claimKey(key, meta) {
    await this.ensureStore();
    const now = this.clock();
    try {
      await this.soda.insert(LOG, { key, ...meta, status: 'QUEUED', attempts: 0, dueAt: meta.dueAt || now, createdAt: now, updatedAt: now });
      return true;
    } catch (e) {
      if (e && (e.status === 409 || /unique/i.test(e.message || ''))) return false;
      throw e;
    }
  }

  /** auth hook: a new account (password or Google). Never blocks or fails registration. */
  queueWelcome(user) {
    if (!user || !user.userId) return null;
    return this._later(() => this.enqueueWelcome(user));
  }

  async enqueueWelcome(user) {
    if (!this.enabled) return { skipped: 'MAIL_DISABLED' };
    if (!validEmail(user.email)) return { skipped: 'NO_EMAIL' };
    const key = `welcome:${user.userId}`;
    if (!(await this._claimKey(key, { kind: 'welcome', userId: user.userId, to: maskEmail(user.email) }))) return { skipped: 'ALREADY_QUEUED' };
    return this.process(key);
  }

  /** Timeline hook after a trip report is built: one ride summary per analysed rider, sent after the delay. */
  onTripFinished({ meta, perMember } = {}) {
    if (!meta || !Array.isArray(perMember) || !this.enabled) return null;
    return this._later(async () => {
      const due = this.clock() + this.tripDelayMs;
      const keys = [];
      for (const pm of perMember) {
        const t = pm && pm.tripDoc;
        if (!t || !pm.userId || !this.tripQualifies(t)) continue;
        const key = `trip_memory:${meta.groupId}:${pm.userId}`;
        if (await this._claimKey(key, { kind: 'trip_memory', userId: pm.userId, groupId: meta.groupId, tripId: t.tripId, dueAt: due })) keys.push(key);
      }
      if (!this.tripDelayMs) for (const k of keys) await this.process(k);
      return keys.length;
    });
  }

  tripQualifies(t) {
    const km = Number(t.totalDistanceKm) || 0;
    const ms = Math.max(0, (Number(t.endTimeEpochMs) || 0) - (Number(t.startTimeEpochMs) || 0));
    return km >= MIN_TRIP_KM && ms >= MIN_TRIP_MS;
  }

  // ------------------------------------------------------------ sending
  /** Claims one row (QUEUED / RETRY due, or a SENDING row whose lease ran out) and sends it. */
  async process(key) {
    const row = await this.soda.findOne(LOG, { key });
    if (!row) return { skipped: 'NO_ROW' };
    const v = row.value;
    const now = this.clock();
    const claimable = ((v.status === 'QUEUED' || v.status === 'RETRY') && (Number(v.dueAt) || 0) <= now) || (v.status === 'SENDING' && (Number(v.leaseUntil) || 0) < now);
    if (!claimable) return { skipped: v.status === 'SENT' ? 'ALREADY_SENT' : 'NOT_DUE' };
    const claimed = { ...v, status: 'SENDING', leaseUntil: now + this.leaseMs, worker: this.worker, updatedAt: now };
    if (!(await this.soda.compareAndReplace(LOG, row.key, v, claimed))) return { skipped: 'TAKEN' };
    let result;
    try { result = await this._deliver(claimed); } catch (e) { result = { sent: false, error: String((e && e.code) || 'BUILD_FAILED').slice(0, 40) }; }
    const attempts = (v.attempts || 0) + (result.skipped ? 0 : 1);
    const status = result.skipped ? 'SKIPPED' : result.sent ? 'SENT' : (attempts >= MAX_ATTEMPTS ? 'FAILED' : 'RETRY');
    const done = { ...claimed, status, attempts, leaseUntil: 0, worker: null, reason: result.skipped || null, messageId: result.messageId || null,
      error: result.error || null, to: result.to || claimed.to || null, dueAt: status === 'RETRY' ? this.clock() + 5 * 60000 * attempts : claimed.dueAt, updatedAt: this.clock() };
    await this.soda.compareAndReplace(LOG, row.key, claimed, done);
    return result.skipped ? { skipped: result.skipped } : result.sent ? { sent: true } : { sent: false, error: result.error };
  }

  async _deliver(row) {
    if (!this.enabled) return { sent: false, error: 'MAIL_DISABLED' };
    const user = await this.repo.findUserById(row.userId).catch(() => null);
    if (!user || user.deletedAt) return { skipped: 'USER_GONE' };
    if (!validEmail(user.email)) return { skipped: 'NO_EMAIL' };
    if (await this.hardSuppressed(user.email)) return { skipped: 'SUPPRESSED' };
    let msg;
    if (row.kind === 'welcome') {
      msg = await this.buildWelcome(user);
    } else if (row.kind === 'trip_memory') {
      const prefs = await this.prefsOf(user.userId);
      if (!prefs.rideSummaries) return { skipped: 'OPTED_OUT' };
      const trip = await this.repo.getTrip(row.tripId).catch(() => null);
      if (!trip || trip.userId !== user.userId) return { skipped: 'TRIP_GONE' };
      if (!this.tripQualifies(trip)) return { skipped: 'TOO_SHORT' };
      const meta = trip.groupId ? await this.repo.getConvoyMeta(trip.groupId).catch(() => null) : null;
      msg = await this.buildTripMemory(user, trip, meta);
    } else {
      return { skipped: 'UNKNOWN_KIND' };
    }
    const r = await this.mailer.send({ to: user.email.trim(), subject: msg.subject, html: msg.html, text: msg.text, headers: msg.headers, attachments: msg.attachments });
    return { ...r, to: maskEmail(user.email) };
  }

  /** Leased job: what is due, in batches at ratePerSec. Returns the number sent. */
  async processDue() {
    if (this.running || !this.enabled) return 0;
    this.running = true;
    let sent = 0;
    try {
      await this.ensureStore();
      const now = this.clock();
      const rows = [
        ...(await this.soda.query(LOG, { status: { $in: ['QUEUED', 'RETRY'] }, kind: { $in: KINDS }, dueAt: { $lte: now } }, { limit: this.batchSize })),
        ...(await this.soda.query(LOG, { status: 'SENDING', kind: { $in: KINDS }, leaseUntil: { $lt: now } }, { limit: 10 })),
      ];
      const started = this.clock();
      let n = 0;
      for (const row of rows) {
        const r = await this.process(row.value.key);
        if (r.sent) sent++;
        if (r.sent || r.error) {
          n++;
          // Stay at ratePerSec: sleep when the batch got ahead of the rate.
          const want = Math.ceil((n / this.ratePerSec) * 1000);
          const spent = this.clock() - started;
          if (want > spent) await this.sleep(Math.min(want - spent, 5000));
        }
      }
    } catch (e) {
      this.logger.warn?.(`[lifecycle-mail] job failed: ${e.message}`);
    } finally { this.running = false; }
    return sent;
  }

  // ------------------------------------------------------------ building
  supportText() {
    return String(this.config.supportEmail || '').trim() || `the contact form at ${this.origin()}/#feedback`;
  }

  /** The group rides block: { kind: 'free' | 'plans', text, url? } or null (Tips and news off). */
  async plansBlock(user, words) {
    const prefs = await this.prefsOf(user.userId);
    if (!prefs.tipsNews) return null;
    let mode = 'paid';
    try { mode = this.accessMode ? this.accessMode.publicView().mode : 'paid'; } catch { mode = 'paid'; }
    if (mode === 'free') return { kind: 'free', text: words.freeLine };
    const { plansLink } = require('./web_shop');
    const { welcomeCoupon } = await this.settings();
    // The coupon is checked again at send time: an expired or paused one is simply left out.
    const code = welcomeCoupon && !(await this.couponProblem(welcomeCoupon)) ? welcomeCoupon : '';
    const url = code ? `${plansLink(this.origin(), code)}&utm_source=welcome` : `${this.origin()}/plans?utm_source=welcome`;
    return { kind: 'plans', text: words.plansLine, url, coupon: code || null };
  }

  async buildWelcome(user, { override = null } = {}) {
    const o = this.origin();
    const vars = { name: firstName(user.name), username: String(user.username || '').replace(/^@/, '') || firstName(user.name),
      guideUrl: `${o}/guide`, accountUrl: `${o}/account`, supportEmail: this.supportText() };
    const w = await this.templates.render('welcome', vars, override ? { override } : {});
    const block = await this.plansBlock(user, w);
    const unsub = this.unsubscribeUrl('tips_news', user.userId);
    const steps = [w.step1, w.step2, w.step3];
    const stepsHtml = '<tr><td style="padding:0 0 14px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:15px;line-height:1.5;color:#3b4151;">'
      + steps.map((s, i) => `<tr><td valign="top" style="width:30px;padding:6px 0;"><span style="display:inline-block;width:22px;height:22px;line-height:22px;text-align:center;border-radius:11px;background:#ece9fb;color:#5b4bd6;font-weight:700;font-size:13px;">${i + 1}</span></td><td style="padding:6px 0;">${esc(s)}</td></tr>`).join('')
      + '</table></td></tr>';
    const blocks = [para(w.intro), stepsHtml,
      `<tr><td style="padding:2px 0 16px;"><div style="background:#eef7f2;border-radius:10px;padding:12px 14px;font-size:14px;line-height:1.5;color:#1f5f43;">${esc(w.safetyLine)}</div></td></tr>`,
      para(w.guideLine, 'font-size:14px;line-height:1.55;color:#3b4151;padding-bottom:4px;'), button(vars.guideUrl, 'Open the quick start guide')];
    if (block) {
      blocks.push('<tr><td style="padding:6px 0 0;border-top:1px solid #f0f1f3;"></td></tr>');
      blocks.push(`<tr><td style="font-size:16px;font-weight:700;color:#111827;padding:10px 0 6px;">Group rides</td></tr>`);
      blocks.push(para(block.text, 'font-size:14px;line-height:1.55;color:#3b4151;padding-bottom:6px;'));
      if (block.url) blocks.push(button(block.url, 'See group plans'));
    }
    const footerHtml = `${esc(w.footer).replace(/\n/g, '<br>')}<br><br>You get this e-mail because you created a CoRoute account.`
      + (block ? ` <a href="${esc(unsub)}" style="color:#6b7280;">Unsubscribe from tips and news</a> ·` : '')
      + ` <a href="${esc(this.accountUrl())}" style="color:#6b7280;">Manage e-mails</a>`;
    const html = layout({ title: w.subject, heading: w.heading, blocks, footerHtml });
    const text = [w.heading, '', w.intro, '', ...steps.map((s, i) => `${i + 1}. ${s}`), '', w.safetyLine, '', w.guideLine, `Quick start guide: ${vars.guideUrl}`]
      .concat(block ? ['', 'Group rides', block.text, ...(block.url ? [`See group plans: ${block.url}`] : [])] : [])
      .concat(['', w.footer, '', 'You get this e-mail because you created a CoRoute account.', ...(block ? [`Unsubscribe from tips and news: ${unsub}`] : []), `Manage e-mails: ${this.accountUrl()}`, '', '-- CoRoute'])
      .join('\n');
    return { subject: w.subject, html, text, headers: this._headers('welcome', 'tips_news', user.userId), plans: block };
  }

  async buildTripMemory(user, trip, meta, { override = null, inlineImage = false } = {}) {
    const o = this.origin();
    const start = Number(trip.startTimeEpochMs) || 0;
    const end = Number(trip.endTimeEpochMs) || 0;
    const riding = Number(trip.movingMs) > 0 ? Number(trip.movingMs) : Math.max(0, end - start);
    const groupName = String((meta && (meta.crewName || meta.groupName)) || '').slice(0, 80);
    const vars = {
      name: firstName(user.name), rideName: String(trip.tripName || (meta && meta.name) || 'Your ride').slice(0, 80), distance: kmText(trip.totalDistanceKm),
      ridingTime: durText(riding), date: istDate(start || end, false), stops: String(Math.max(0, Number(trip.stopCount) || 0)),
      riders: String(Math.max(1, Number(trip.riderCount) || 1)), groupName,
      reportUrl: `${o}/trip/${encodeURIComponent(trip.tripId)}?utm_source=ride_summary`,
    };
    const w = await this.templates.render('trip_memory', vars, override ? { override } : {});
    const unsub = this.unsubscribeUrl('ride_summaries', user.userId);
    let pic = null;
    try { pic = renderRoutePng(trip.breadcrumbTrail, { trimM: TRIM_M }); } catch { pic = null; }
    const cid = `route-${crypto.createHash('sha256').update(String(trip.tripId)).digest('hex').slice(0, 12)}@coroute`;
    const facts = [['Date', vars.date], ['Distance', vars.distance], ['Riding time', vars.ridingTime], ['Stops', vars.stops],
      ['Riders', vars.riders], groupName ? ['Group', groupName] : null].filter(Boolean);
    const blocks = [para(w.intro)];
    if (pic) {
      const src = inlineImage ? `data:image/png;base64,${pic.png.toString('base64')}` : `cid:${cid}`;
      blocks.push(`<tr><td style="padding:0 0 16px;"><img src="${esc(src)}" alt="Your route (start and end left off)" width="504" style="display:block;width:100%;max-width:504px;height:auto;border-radius:10px;border:1px solid #e5e7eb;"></td></tr>`);
    }
    blocks.push(`<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;border-top:1px solid #e5e7eb;border-bottom:1px solid #e5e7eb;margin-bottom:14px;">${
      facts.map(([l, v]) => `<tr><td style="padding:8px 0;color:#6b7280;">${esc(l)}</td><td style="padding:8px 0;text-align:right;color:#111827;font-weight:600;">${esc(v)}</td></tr>`).join('')}</table></td></tr>`);
    blocks.push(button(vars.reportUrl, 'View trip report'));
    blocks.push(para(w.rateLine, 'font-size:14px;line-height:1.55;color:#3b4151;padding-bottom:6px;'));
    const footerHtml = `${esc(w.footer).replace(/\n/g, '<br>')}<br><br>You get ride summaries because you ride with CoRoute.`
      + ` <a href="${esc(unsub)}" style="color:#6b7280;">Unsubscribe from ride summaries</a> · <a href="${esc(this.accountUrl())}" style="color:#6b7280;">Manage e-mails</a>`;
    const html = layout({ title: w.subject, heading: w.heading, blocks, footerHtml });
    const text = [w.heading, '', w.intro, '', ...facts.map(([l, v]) => `${l}: ${v}`), '', `View trip report: ${vars.reportUrl}`, '', w.rateLine, '', w.footer, '',
      'You get ride summaries because you ride with CoRoute.', `Unsubscribe from ride summaries: ${unsub}`, `Manage e-mails: ${this.accountUrl()}`, '', '-- CoRoute'].join('\n');
    const attachments = pic && !inlineImage ? [{ filename: 'route.png', content: pic.png, contentType: 'image/png', cid, contentDisposition: 'inline' }] : [];
    return { subject: w.subject, html, text, headers: this._headers('trip_memory', 'ride_summaries', user.userId), attachments, image: pic ? { width: pic.width, height: pic.height, bytes: pic.png.length } : null };
  }

  /** Admin template preview: the whole e-mail with sample data (image inline as data:). */
  async previewMail(id, rendered) {
    const sampleUser = { userId: 'usr_sample', name: 'Asha Rao', username: 'SwiftFalcon482', email: 'asha@example.com' };
    if (id === 'welcome') {
      const m = await this.buildWelcome(sampleUser, { override: rendered, preview: true });
      return { subject: m.subject, html: m.html, text: m.text };
    }
    if (id === 'trip_memory') {
      const now = this.clock();
      // A made-up loop (not a real place) for the picture.
      const trail = [];
      for (let i = 0; i <= 120; i++) { const a = (i / 120) * Math.PI * 1.6; trail.push({ lat: 13.0 + 0.12 * Math.sin(a) + i * 0.0006, lng: 77.5 + 0.18 * Math.cos(a) * (1 - i / 300) }); }
      const trip = { tripId: 'TRIP-SAMPLE-usr_sample', userId: 'usr_sample', tripName: 'Nandi Hills sunrise ride', totalDistanceKm: 128.4, startTimeEpochMs: now - 4 * 3600000,
        endTimeEpochMs: now, movingMs: 3 * 3600000 + 25 * 60000, stopCount: 3, riderCount: 5, breadcrumbTrail: trail };
      const m = await this.buildTripMemory(sampleUser, trip, null, { override: rendered, inlineImage: true });
      return { subject: m.subject, html: m.html, text: m.text };
    }
    return null;
  }
}

// ------------------------------------------------------------ routers
/** GET / PUT /api/web/email-preferences (website account page, Bearer). */
function preferencesRouter({ lifecycle, offers, repo }) {
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => req.user?.userId || req.ip,
    message: { error: 'Too many requests. Wait a minute.', code: 'RATE_LIMITED' } });
  const view = async (userId, u) => {
    const [p, c] = await Promise.all([lifecycle.prefsOf(userId), offers ? offers.consentOf(userId) : { offersEmail: false }]);
    const hasEmail = !!(u && validEmail(u.email));
    return {
      categories: { account: true, rideSummaries: p.rideSummaries, tipsNews: p.tipsNews, offers: !!c.offersEmail },
      locked: ['account'], hasEmail, suppressed: hasEmail ? await lifecycle.hardSuppressed(u.email) : false,
    };
  };
  r.get('/', limiter, async (req, res, next) => {
    try {
      const u = req.dbUser || (await repo.findUserById(req.user.userId).catch(() => null));
      res.set('Cache-Control', 'no-store').json(await view(req.user.userId, u));
    } catch (e) { next(e); }
  });
  r.put('/', limiter, async (req, res, next) => {
    try {
      const b = req.body && typeof req.body === 'object' ? req.body : {};
      const keys = Object.keys(b);
      if (!keys.length) return res.status(400).json({ error: 'Nothing to change.', code: 'BAD_PREF' });
      for (const k of keys) {
        if (k === 'account') return res.status(400).json({ error: 'Account and receipt e-mails are always sent.', code: 'LOCKED' });
        if (!['rideSummaries', 'tipsNews', 'offers'].includes(k)) return res.status(400).json({ error: `Unknown e-mail category: ${k.slice(0, 30)}.`, code: 'BAD_PREF' });
        if (typeof b[k] !== 'boolean') return res.status(400).json({ error: `${k} must be true or false.`, code: 'BAD_PREF' });
      }
      const u = req.dbUser || (await repo.findUserById(req.user.userId).catch(() => null));
      if (b.offers === true && !(u && validEmail(u.email))) return res.status(409).json({ error: 'Add an e-mail address to your account first.', code: 'NO_ADDRESS' });
      await lifecycle.setPrefs(req.user.userId, b, { source: 'website' });
      if (typeof b.offers === 'boolean' && offers) await offers.setConsent(req.user.userId, b.offers, { source: 'website', email: u && u.email });
      res.set('Cache-Control', 'no-store').json(await view(req.user.userId, u));
    } catch (e) { next(e); }
  });
  return r;
}

/** /api/admin/email/lifecycle/* (admin): the welcome coupon setting and the job's numbers. */
function adminLifecycleRouter({ lifecycle, audit = null }) {
  const r = express.Router();
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  r.get('/settings', async (req, res, next) => {
    try {
      res.json({ ...(await lifecycle.settings()), enabled: lifecycle.enabled, origin: lifecycle.origin(), ratePerSec: lifecycle.ratePerSec,
        tripDelayMinutes: Math.round(lifecycle.tripDelayMs / 60000), thresholds: { minKm: MIN_TRIP_KM, minMinutes: MIN_TRIP_MS / 60000, trimMetres: TRIM_M } });
    } catch (e) { next(e); }
  });
  r.put('/settings', async (req, res, next) => {
    try {
      const out = await lifecycle.setSettings(req.body, { by: by(req) });
      if (audit) audit({ by: by(req), action: 'email.lifecycle.settings', target: 'welcomeCoupon', details: { welcomeCoupon: out.welcomeCoupon || null }, at: Date.now() });
      res.json({ ok: true, ...out });
    } catch (e) {
      if (e && e.status === 400) return res.status(400).json({ error: e.message, code: e.code });
      next(e);
    }
  });
  return r;
}

const PAGE_HEADERS = { 'Cache-Control': 'no-store', 'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'", 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff', 'X-Robots-Tag': 'noindex' };
function page(title, bodyHtml) {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">'
    + `<title>${esc(title)} | CoRoute</title></head><body style="margin:0;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:#f4f5f7;color:#111827;">`
    + `<main style="max-width:480px;margin:48px auto;background:#fff;border-radius:12px;padding:28px;"><p style="color:#5b4bd6;font-weight:700;margin:0 0 16px;">CoRoute</p>${bodyHtml}</main></body></html>`;
}

/**
 * /email/unsubscribe?u=&c=<ride_summaries|tips_news>&t=  (before the offers router, which handles links
 * without c or with c=offers). GET: a page with one button; POST (the button or RFC 8058 one-click): off.
 */
function categoryUnsubscribeRouter({ lifecycle }) {
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false, message: 'Too many requests.' });
  const params = (req) => ({ u: String(req.query.u || (req.body && req.body.u) || ''), c: String(req.query.c || (req.body && req.body.c) || ''), t: String(req.query.t || (req.body && req.body.t) || '') });
  const mine = (req) => { const c = String(req.query.c || ''); return c && c !== 'offers'; };
  const bad = (res) => res.status(400).type('html').send(page('Link not valid', '<h1 style="font-size:20px;">This link is not valid</h1><p>Choose which e-mails you get on your CoRoute account page at any time.</p>'));
  r.get('/email/unsubscribe', (req, res, next) => (mine(req) ? next() : next('router')), limiter, (req, res) => {
    const { u, c, t } = params(req);
    res.set(PAGE_HEADERS);
    if (!categoryTokenOk(lifecycle.secret, c, u, t)) return bad(res);
    return res.type('html').send(page('Unsubscribe', `<h1 style="font-size:20px;">Stop ${esc(CATEGORY_LABEL[c])}?</h1><p>You will not get CoRoute ${esc(CATEGORY_LABEL[c])} any more. Receipts, account messages and safety alerts are not affected.</p>`
      + `<form method="post" action="/email/unsubscribe?u=${encodeURIComponent(u)}&amp;c=${encodeURIComponent(c)}&amp;t=${encodeURIComponent(t)}"><button type="submit" style="background:#5b4bd6;color:#fff;border:0;border-radius:8px;padding:11px 18px;font-size:15px;font-weight:600;">Unsubscribe</button></form>`));
  });
  r.post('/email/unsubscribe', (req, res, next) => (mine(req) ? next() : next('router')), limiter, express.urlencoded({ extended: false, limit: '2kb' }), async (req, res, next) => {
    try {
      const { u, c, t } = params(req);
      res.set(PAGE_HEADERS);
      if (!(await lifecycle.unsubscribe(u, c, t))) return bad(res);
      return res.type('html').send(page('Unsubscribed', `<h1 style="font-size:20px;">You are unsubscribed</h1><p>You will not get CoRoute ${esc(CATEGORY_LABEL[c])} any more. You can turn them on again on your account page.</p>`));
    } catch (e) { next(e); }
  });
  return r;
}

module.exports = {
  LifecycleEmails, preferencesRouter, adminLifecycleRouter, categoryUnsubscribeRouter, categoryToken, categoryTokenOk,
  kmText, durText, LINK_CATEGORIES, MIN_TRIP_KM, MIN_TRIP_MS, TRIM_M, KINDS,
};
