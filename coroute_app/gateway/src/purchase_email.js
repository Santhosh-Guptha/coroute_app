'use strict';
/**
 * Receipt and refund e-mails for website purchases (docs/features_355/purchase_email.md).
 *
 * Trigger: every write of a ledger order goes through repo.updateRazorpayOrder. attachPurchaseEmail()
 * wraps it (like push.js wraps deleteUserCascade), so ALL paths are covered without touching them:
 * the payment check (/membership/verify), both Razorpay webhooks, downgrades, and the admin refund.
 *   - patch.status === 'PAID'                  -> receipt e-mail (once per order)
 *   - patch.refundedAmountInPaise / refundStatus -> refund e-mail (once per refunded amount)
 * Exactly once across retries, webhooks and both gateway nodes: a row in `mail_log` with a unique
 * `key` (receipt:<orderId> / refund:<orderId>:<paise>) is inserted BEFORE sending; a second insert
 * fails and nothing is sent. A failed SMTP send is retried by the leased job (3 tries).
 *
 * Address: the order's `receiptEmail` (the optional "Email for your receipt" field on /plans, stored
 * on the order only, POST /api/web/receipt-email), else the account e-mail. No address: skipped (no
 * row is written, so a receipt e-mail given right after a ₹0 activation still gets one).
 * SMTP not configured: nothing is claimed or sent (src/mailer.js).
 *
 * Words come from the admin-editable templates (templates.js: purchase_receipt, refund); the layout
 * and the payment lines are built here and every value is HTML-escaped.
 */
const express = require('express');
const rateLimit = require('express-rate-limit');
const { validEmail } = require('./mailer');

const COLLECTION = 'mail_log';
const MAX_ATTEMPTS = 3;

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
function inr(n) {
  const v = Number(n) || 0;
  const s = Math.abs(v).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return `${v < 0 ? '−' : ''}₹${s}`;
}
/** "10 Nov 2026, 14:05 IST" (or "10 Nov 2026" with time=false). */
function istDate(ms, time = true) {
  const t = Number(ms);
  if (!Number.isFinite(t) || t <= 0) return '';
  const o = { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' };
  if (time) Object.assign(o, { hour: '2-digit', minute: '2-digit', hour12: false });
  const s = new Intl.DateTimeFormat('en-GB', o).format(new Date(t));
  return time ? `${s} IST` : s;
}
const maskEmail = (e) => String(e || '').replace(/^(.).*?(@.*)$/, '$1***$2');

/** The branded, calm HTML e-mail around the template words and the payment lines. */
function layoutHtml({ heading, intro, rows = [], totalLabel, totalValue, details = [], buttonUrl, buttonLabel, footer }) {
  const para = (t) => esc(t).replace(/\n/g, '<br>');
  const row = (l, v, strong) => `<tr><td style="padding:8px 0;color:#3b4151;${strong ? 'font-weight:700;color:#111827;' : ''}">${esc(l)}</td><td style="padding:8px 0;text-align:right;white-space:nowrap;${strong ? 'font-weight:700;color:#111827;' : 'color:#3b4151;'}">${esc(v)}</td></tr>`;
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>CoRoute</title></head>'
    + '<body style="margin:0;padding:0;background:#f4f5f7;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">'
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:24px 12px;"><tr><td align="center">'
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:12px;padding:28px 28px 20px;">'
    + '<tr><td style="font-size:15px;font-weight:700;color:#5b4bd6;letter-spacing:.2px;padding-bottom:18px;">CoRoute</td></tr>'
    + `<tr><td style="font-size:22px;font-weight:700;color:#111827;padding-bottom:10px;">${esc(heading)}</td></tr>`
    + `<tr><td style="font-size:15px;line-height:1.55;color:#3b4151;padding-bottom:18px;">${para(intro)}</td></tr>`
    + (rows.length || totalLabel ? `<tr><td><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;border-top:1px solid #e5e7eb;border-bottom:1px solid #e5e7eb;">${rows.map((r) => row(r[0], r[1])).join('')}${totalLabel ? row(totalLabel, totalValue, true) : ''}</table></td></tr>` : '')
    + (details.length ? `<tr><td style="padding-top:14px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:13px;color:#6b7280;">${details.map((d) => `<tr><td style="padding:3px 0;">${esc(d[0])}</td><td style="padding:3px 0;text-align:right;word-break:break-all;">${esc(d[1])}</td></tr>`).join('')}</table></td></tr>` : '')
    + (buttonUrl ? `<tr><td style="padding:22px 0 6px;"><a href="${esc(buttonUrl)}" style="display:inline-block;background:#5b4bd6;color:#ffffff;text-decoration:none;font-weight:600;font-size:14px;padding:11px 18px;border-radius:8px;">${esc(buttonLabel || 'View receipt')}</a></td></tr>` : '')
    + `<tr><td style="font-size:13px;line-height:1.5;color:#6b7280;padding-top:16px;border-top:1px solid #f0f1f3;margin-top:12px;">${para(footer)}</td></tr>`
    + '</table><p style="font-size:12px;color:#9ca3af;margin:14px 0 0;">CoRoute ride safety. You get this e-mail because of a payment on your CoRoute account.</p>'
    + '</td></tr></table></body></html>';
}

function layoutText({ heading, intro, rows = [], totalLabel, totalValue, details = [], buttonUrl, footer }) {
  const lines = [heading, '', intro, ''];
  for (const [l, v] of rows) lines.push(`${l}: ${v}`);
  if (totalLabel) lines.push(`${totalLabel}: ${totalValue}`);
  if (rows.length || totalLabel) lines.push('');
  for (const [l, v] of details) lines.push(`${l}: ${v}`);
  if (buttonUrl) lines.push('', `Receipt: ${buttonUrl}`);
  lines.push('', footer, '', '-- CoRoute');
  return lines.join('\n');
}

class PurchaseEmail {
  constructor({ repo, mailer, templates, config = {}, logger = console, clock = Date.now } = {}) {
    this.repo = repo; this.mailer = mailer; this.templates = templates; this.config = config; this.logger = logger; this.clock = clock;
    this.pending = new Set();
    this.ready = null;
  }

  get soda() { return this.repo && this.repo.soda; }
  origin() { return this.config.publicOrigin || this.config.linkOrigin || ''; }

  async _ensure() {
    if (!this.ready) {
      this.ready = (async () => {
        await this.soda.ensureCollection(COLLECTION);
        await this.soda.ensureIndex(COLLECTION, { name: `${COLLECTION}_key_ux`, unique: true, fields: [{ path: 'key' }] });
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  /** Runs `fn` in the background (never on the payment path); idle() waits for all of them. */
  _later(fn) {
    const p = new Promise((r) => setImmediate(r)).then(fn).catch((e) => this.logger.warn?.(`[mail] ${e.message}`)).finally(() => this.pending.delete(p));
    this.pending.add(p);
    return p;
  }
  async idle() { while (this.pending.size) await Promise.allSettled([...this.pending]); }

  /** Hook after repo.updateRazorpayOrder(orderId, patch) -> next. */
  onOrderUpdated(next, patch) {
    if (!next || !patch || typeof patch !== 'object') return;
    if (patch.status === 'PAID') this._later(() => this.sendReceipt(next.orderId));
    if (patch.refundedAmountInPaise !== undefined || (patch.refundStatus && patch.refundedAmount !== undefined)) this._later(() => this.sendRefund(next.orderId));
  }

  async _addressFor(order) {
    if (order.receiptEmail && validEmail(order.receiptEmail)) return order.receiptEmail.trim();
    const user = order.userId ? await this.repo.findUserById(order.userId).catch(() => null) : null;
    return user && validEmail(user.email) ? user.email.trim() : '';
  }

  /** Inserts the claim row; false when it already exists (sent, or being sent, elsewhere). */
  async _claim(key, meta) {
    await this._ensure();
    try {
      await this.soda.insert(COLLECTION, { key, ...meta, status: 'SENDING', attempts: 0, createdAt: this.clock(), updatedAt: this.clock() });
      return true;
    } catch (e) {
      if (e && (e.status === 409 || /unique/i.test(e.message || ''))) return false;
      throw e;
    }
  }

  async _finish(key, result) {
    const row = await this.soda.findOne(COLLECTION, { key });
    if (!row) return;
    const attempts = (row.value.attempts || 0) + 1;
    const status = result.sent ? 'SENT' : (attempts >= MAX_ATTEMPTS ? 'FAILED' : 'RETRY');
    await this.soda.replace(COLLECTION, row.key, { ...row.value, status, attempts, messageId: result.messageId || null, error: result.error || null,
      nextAttemptAt: status === 'RETRY' ? this.clock() + 5 * 60000 * attempts : null, updatedAt: this.clock() });
  }

  async _context(order) {
    const { receiptOf } = require('./web_shop');
    const user = order.userId ? await this.repo.findUserById(order.userId).catch(() => null) : null;
    const catalog = await this.repo.getMembershipCatalog().catch(() => ({}));
    const rc = receiptOf(order, { user, catalog });
    const origin = this.origin();
    const receiptUrl = origin ? `${origin}/receipt?order=${encodeURIComponent(order.orderId)}` : '';
    const start = rc.periodStartsAt || rc.paidAt;
    const end = rc.periodEndsAt || (start ? start + (rc.billingDays || 30) * 86400000 : 0);
    const firstName = String((user && user.name) || '').trim().split(/\s+/)[0] || 'there';
    return { rc, user, receiptUrl, firstName, period: start && end ? `${istDate(start, false)} to ${istDate(end, false)}` : '' };
  }

  async buildReceipt(order) {
    const { rc, receiptUrl, firstName, period } = await this._context(order);
    const supportEmail = this.config.supportEmail || '';
    const vars = { name: firstName, plan: rc.planName, period, amount: inr(rc.amountInr), orderId: rc.orderId, paymentId: rc.paymentId || '-',
      date: istDate(rc.paidAt || this.clock()), receiptUrl, supportEmail };
    const t = await this.templates.render('purchase_receipt', vars);
    // Plan line, list price, offer, coupon, credit and tax lines exactly as the server priced the order.
    const rows = rc.lines.filter((l) => !/^to pay now$/i.test(l.label)).map((l) => [l.label, inr(l.amountInr)]);
    const details = [['Plan', rc.planName], period ? ['Period', period] : null, ['Payment id', rc.paymentId || '-'], ['Order id', rc.orderId],
      ['Receipt no.', rc.receiptNo], ['Date', vars.date], ['Paid with', String(rc.method || '').toUpperCase() === 'RAZORPAY' ? 'Razorpay' : String(rc.method || '-')]].filter(Boolean);
    const parts = { heading: t.heading, intro: t.intro, rows, totalLabel: 'Amount charged', totalValue: inr(rc.amountInr), details, buttonUrl: receiptUrl, buttonLabel: 'View receipt', footer: t.footer };
    return { subject: t.subject, html: layoutHtml(parts), text: layoutText(parts) };
  }

  async buildRefund(order) {
    const { rc, receiptUrl, firstName } = await this._context(order);
    const refunded = Number(rc.refundedInr) || ((Number(order.refundedAmountInPaise) || 0) / 100);
    const vars = { name: firstName, plan: rc.planName, amount: inr(refunded), orderId: rc.orderId, paymentId: rc.paymentId || '-',
      refundId: String(order.refundId || '-'), date: istDate(order.updatedAt || this.clock()), receiptUrl, supportEmail: this.config.supportEmail || '' };
    const t = await this.templates.render('refund', vars);
    const rows = [['Paid', inr(rc.amountInr)]];
    const details = [['Plan', rc.planName], ['Payment id', vars.paymentId], ['Order id', rc.orderId], ['Refund id', vars.refundId], ['Date', vars.date],
      ['Status', order.fullyRefunded ? 'Full refund' : 'Part refund']];
    const parts = { heading: t.heading, intro: t.intro, rows, totalLabel: 'Refunded', totalValue: inr(refunded), details, buttonUrl: receiptUrl, buttonLabel: 'View receipt', footer: t.footer };
    return { subject: t.subject, html: layoutHtml(parts), text: layoutText(parts) };
  }

  /** Sends the receipt once. Returns { sent } or { skipped: reason }. */
  async sendReceipt(orderId) {
    const order = await this.repo.findRazorpayOrder(orderId);
    if (!order || order.status !== 'PAID') return { skipped: 'NOT_PAID' };
    if (order.isFree || !(Number(order.amountInPaise) > 0)) return { skipped: 'FREE' };
    return this._deliver(`receipt:${order.orderId}`, order, 'receipt', () => this.buildReceipt(order));
  }

  async sendRefund(orderId) {
    const order = await this.repo.findRazorpayOrder(orderId);
    const paise = order ? Number(order.refundedAmountInPaise) || Math.round((Number(order.refundedAmount) || 0) * 100) : 0;
    if (!order || !(paise > 0)) return { skipped: 'NO_REFUND' };
    if (order.refundStatus && !/^(PROCESSED|SUCCESS|COMPLETED)$/i.test(String(order.refundStatus))) return { skipped: 'REFUND_PENDING' };
    return this._deliver(`refund:${order.orderId}:${paise}`, order, 'refund', () => this.buildRefund(order));
  }

  async _deliver(key, order, kind, build) {
    if (!this.mailer || !this.mailer.enabled) return { skipped: 'MAIL_DISABLED' };
    const to = await this._addressFor(order);
    if (!to) return { skipped: 'NO_EMAIL' };
    if (!(await this._claim(key, { kind, orderId: order.orderId, userId: order.userId || null, to: maskEmail(to) }))) return { skipped: 'ALREADY_SENT' };
    let result;
    try {
      const msg = await build();
      result = await this.mailer.send({ to, ...msg, headers: { 'X-CoRoute-Mail': kind } });
    } catch (e) { result = { sent: false, error: String(e.code || 'BUILD_FAILED').slice(0, 40) }; }
    await this._finish(key, result);
    return result.sent ? { sent: true } : { sent: false, error: result.error };
  }

  /** Leased job: retries RETRY rows whose time has come. */
  async retryDue() {
    if (!this.mailer || !this.mailer.enabled) return 0;
    await this._ensure();
    // Receipts and refunds only: the lifecycle e-mails in the same log have their own job (lifecycle_emails.js).
    const rows = await this.soda.query(COLLECTION, { status: 'RETRY', kind: { $in: ['receipt', 'refund'] }, nextAttemptAt: { $lte: this.clock() } }, { limit: 50 });
    let n = 0;
    for (const row of rows) {
      const order = await this.repo.findRazorpayOrder(row.value.orderId);
      if (!order) continue;
      const to = await this._addressFor(order);
      if (!to) continue;
      let result;
      try {
        const msg = row.value.kind === 'refund' ? await this.buildRefund(order) : await this.buildReceipt(order);
        result = await this.mailer.send({ to, ...msg, headers: { 'X-CoRoute-Mail': row.value.kind } });
      } catch (e) { result = { sent: false, error: 'BUILD_FAILED' }; }
      await this._finish(row.value.key, result);
      if (result.sent) n++;
    }
    return n;
  }
}

/** Wraps repo.updateRazorpayOrder once so every order write reaches the service. */
function attachPurchaseEmail({ repo, mailer, templates, config, logger = console, clock } = {}) {
  const svc = new PurchaseEmail({ repo, mailer, templates, config, logger, ...(clock ? { clock } : {}) });
  if (!repo.__purchaseEmailHook) {
    repo.__purchaseEmailHook = true;
    const original = repo.updateRazorpayOrder.bind(repo);
    repo.updateRazorpayOrder = async (orderId, patch) => {
      const next = await original(orderId, patch);
      try { (repo.__purchaseEmail || svc).onOrderUpdated(next, patch); } catch { /* never in the payment's way */ }
      return next;
    };
  }
  repo.__purchaseEmail = svc;
  return svc;
}

/** POST /api/web/receipt-email {orderId, email}: the optional receipt address of the rider's own order. */
function receiptEmailRouter({ repo, gate, service }) {
  const { requireAuth } = require('./auth');
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 10, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests. Try again in a minute.', code: 'RATE_LIMITED' } });
  r.post('/receipt-email', limiter, requireAuth(gate), async (req, res, next) => {
    try {
      res.set('Cache-Control', 'no-store');
      const b = req.body && typeof req.body === 'object' ? req.body : {};
      const orderId = String(b.orderId || '');
      const email = typeof b.email === 'string' ? b.email.trim() : '';
      if (!/^[A-Za-z0-9_.:-]{4,80}$/.test(orderId)) return res.status(404).json({ error: 'Order not found', code: 'NOT_FOUND' });
      if (email && !validEmail(email)) return res.status(400).json({ error: 'Enter a valid e-mail address.', code: 'BAD_EMAIL' });
      const order = await repo.findRazorpayOrder(orderId);
      if (!order || order.userId !== req.user.userId) return res.status(404).json({ error: 'Order not found', code: 'NOT_FOUND' });
      await repo.updateRazorpayOrder(order.orderId, { receiptEmail: email || null });
      // Already paid (a ₹0 or very fast payment): send now if it was skipped for lack of an address.
      if (order.status === 'PAID' && email) service._later(() => service.sendReceipt(order.orderId));
      res.json({ ok: true });
    } catch (e) { next(e); }
  });
  return r;
}

module.exports = { PurchaseEmail, attachPurchaseEmail, receiptEmailRouter, layoutHtml, layoutText, inr, istDate, COLLECTION };
