'use strict';
/**
 * 3.56 "Offers" e-mail campaigns: prices, coupons and offers for CoRoute plans never go in a push
 * (Google Play payments policy, push_campaigns.js) but may go by e-mail to riders who asked for them.
 * Docs: docs/features_355/notifications_admin.md (Offers e-mail), play_payments_policy.md.
 *
 * Consent (India DPDP Act friendly):
 *  - Off by default. A rider turns "Offer e-mails" on (and off) on the website account page
 *    (GET / PUT /api/web/marketing-consent {offersEmail}). Every change is kept with its time and source.
 *  - Every offer e-mail has an unsubscribe link (/email/unsubscribe?u=<userId>&t=<HMAC>) and the
 *    List-Unsubscribe / List-Unsubscribe-Post (RFC 8058 one-click) headers. Unsubscribing turns consent
 *    off AND puts the address on the suppression list.
 *  - Suppression list (collection email_suppression): addresses never mailed again, stored as a SHA-256
 *    of the lower-cased address (plus a masked form for the admin). Reasons: unsubscribe, bounce,
 *    complaint, admin. Turning consent on again on the account page lifts an "unsubscribe" entry only.
 *
 * Composer (web admin, Notifications > Compose, Channel "Email"): subject, heading, rich content
 * (paragraphs, "- " bullets, **bold**, [links](/path) to this site only; everything else is escaped
 * text), optional image (the push image store), optional coupon block (code + headline + note, the
 * code must exist) with a button to <origin>/plans?coupon=CODE, audience (all consenting riders,
 * plan type, active in the last N days), now or scheduled (India time). Test send to the admin's own
 * account e-mail. Sending: leased job 'offer-emails' (one node), batches at OFFER_EMAIL_RATE e-mails
 * per second (default 5), compare-and-replace lease like push campaigns.
 *
 * Collections: marketing_consent, email_suppression, offer_email_campaigns.
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { validEmail } = require('./mailer');
const { cleanCouponCode, plansLink } = require('./web_shop');
const { brandHeaderRow } = require('./email_brand');

const C = Object.freeze({ consent: 'marketing_consent', suppression: 'email_suppression', campaigns: 'offer_email_campaigns' });
const SUPPRESSION_REASONS = Object.freeze(['unsubscribe', 'bounce', 'complaint', 'admin']);
const MAX_SUBJECT = 120;
const MAX_HEADING = 120;
const MAX_CONTENT = 5000;
const CAMPAIGN_ID = /^oe_[a-f0-9]{20}$/;
const IMAGE_ID = /^pi_[a-f0-9]{24}$/;
const DAY = 86400000;
const HISTORY_MAX = 20;

class OfferEmailError extends Error {
  constructor(message, code = 'BAD_EMAIL', status = 400) { super(message); this.code = code; this.status = status; }
}

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const oneLine = (s) => String(s == null ? '' : s).replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
const textBlock = (s) => String(s == null ? '' : s).replace(/\r\n/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f]+/g, ' ').trim();
const emailHash = (e) => crypto.createHash('sha256').update(String(e || '').trim().toLowerCase()).digest('hex');
const maskEmail = (e) => String(e || '').trim().replace(/^(.).*?(@.*)$/, '$1***$2');

/** HMAC unsubscribe token of a rider (no expiry: an old e-mail's link must keep working). */
function unsubscribeToken(secret, userId) {
  return crypto.createHmac('sha256', String(secret || '')).update(`offer-unsubscribe:v1:${userId}`).digest('base64url').slice(0, 32);
}
function tokenOk(secret, userId, token) {
  if (typeof userId !== 'string' || !/^[A-Za-z0-9_.:-]{1,80}$/.test(userId) || typeof token !== 'string' || token.length !== 32) return false;
  const want = Buffer.from(unsubscribeToken(secret, userId));
  const got = Buffer.from(token);
  return want.length === got.length && crypto.timingSafeEqual(want, got);
}

/**
 * Rich content -> { html, text }. Input is plain text with a tiny markup: blank line = paragraph,
 * "- " = bullet, **bold**, [label](/path or <origin>/path). Everything is HTML-escaped first; a link
 * to another site is refused (no phishing-shaped links in a CoRoute e-mail).
 */
function renderContent(content, origin) {
  const o = String(origin || '').replace(/\/+$/, '');
  const errors = [];
  const inline = (raw) => {
    let s = esc(raw);
    s = s.replace(/\*\*([^*]{1,200})\*\*/g, '<strong>$1</strong>');
    s = s.replace(/\[([^\]]{1,80})\]\(([^)\s]{1,300})\)/g, (m, label, href) => {
      const h = href.replace(/&amp;/g, '&');
      let url = null;
      if (/^\/(?!\/)[A-Za-z0-9/_\-.?=&%]*$/.test(h)) url = o + h;
      else if (o && h.startsWith(`${o}/`)) url = h;
      if (!url) { errors.push(`Links may only point to this site (${o || 'PUBLIC_ORIGIN'}): ${h.slice(0, 60)}`); return label; }
      return `<a href="${esc(url)}" style="color:#2B7A8C;">${label}</a>`;
    });
    return s;
  };
  const plain = (raw) => raw.replace(/\*\*([^*]{1,200})\*\*/g, '$1').replace(/\[([^\]]{1,80})\]\(([^)\s]{1,300})\)/g, (m, l, h) => `${l} (${h.startsWith('/') ? o + h : h})`);
  const blocks = String(content || '').split(/\n{2,}/).map((b) => b.trim()).filter(Boolean);
  const html = [];
  const text = [];
  for (const b of blocks) {
    const lines = b.split('\n');
    if (lines.every((l) => /^\s*-\s+/.test(l))) {
      html.push(`<ul style="margin:0 0 14px 18px;padding:0;">${lines.map((l) => `<li style="margin:0 0 6px;">${inline(l.replace(/^\s*-\s+/, ''))}</li>`).join('')}</ul>`);
      text.push(lines.map((l) => `* ${plain(l.replace(/^\s*-\s+/, ''))}`).join('\n'));
    } else {
      html.push(`<p style="margin:0 0 14px;">${lines.map(inline).join('<br>')}</p>`);
      text.push(lines.map(plain).join('\n'));
    }
  }
  return { html: html.join(''), text: text.join('\n\n'), errors };
}

/** The whole offer e-mail (pure). */
function buildOfferEmail({ subject, heading, content, imageUrl, coupon, origin, unsubscribeUrl, accountUrl }) {
  const o = String(origin || '').replace(/\/+$/, '');
  const body = renderContent(content, o);
  const ctaUrl = coupon ? plansLink(o, coupon.code) : `${o}/plans`;
  const ctaLabel = coupon ? `Use code ${coupon.code}` : 'See plans';
  const couponHtml = coupon ? '<tr><td style="padding:6px 0 18px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:2px dashed #2B7A8C;border-radius:10px;">'
    + '<tr><td style="padding:16px;text-align:center;">'
    + (coupon.headline ? `<div style="font-size:16px;font-weight:700;color:#111827;padding-bottom:8px;">${esc(coupon.headline)}</div>` : '')
    + `<div style="font-family:SFMono-Regular,Consolas,monospace;font-size:24px;font-weight:700;letter-spacing:2px;color:#2B7A8C;">${esc(coupon.code)}</div>`
    + (coupon.note ? `<div style="font-size:13px;color:#6b7280;padding-top:8px;">${esc(coupon.note)}</div>` : '')
    + '</td></tr></table></td></tr>' : '';
  const html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light">'
    + `<title>${esc(subject)}</title></head>`
    + '<body style="margin:0;padding:0;background:#f4f5f7;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">'
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:24px 12px;"><tr><td align="center">'
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:12px;padding:28px 28px 20px;">'
    + brandHeaderRow(o)
    + (imageUrl ? `<tr><td style="padding-bottom:18px;"><img src="${esc(imageUrl)}" alt="" width="504" style="display:block;width:100%;max-width:504px;height:auto;border-radius:10px;"></td></tr>` : '')
    + `<tr><td style="font-size:22px;font-weight:700;color:#111827;padding-bottom:12px;">${esc(heading || subject)}</td></tr>`
    + `<tr><td style="font-size:15px;line-height:1.55;color:#3b4151;">${body.html}</td></tr>`
    + couponHtml
    + `<tr><td style="padding:4px 0 10px;"><a href="${esc(ctaUrl)}" style="display:inline-block;background:#2B7A8C;color:#ffffff;text-decoration:none;font-weight:600;font-size:14px;padding:11px 18px;border-radius:8px;">${esc(ctaLabel)}</a></td></tr>`
    + '<tr><td style="font-size:12px;line-height:1.5;color:#6b7280;padding-top:16px;border-top:1px solid #f0f1f3;">'
    + 'You get this e-mail because you turned on offer e-mails in your CoRoute account. '
    + `<a href="${esc(unsubscribeUrl)}" style="color:#6b7280;">Unsubscribe</a> · <a href="${esc(accountUrl)}" style="color:#6b7280;">Manage e-mails</a>`
    + '</td></tr></table></td></tr></table></body></html>';
  const text = [heading || subject, '', body.text, '']
    .concat(coupon ? [`Code: ${coupon.code}${coupon.headline ? ` (${coupon.headline})` : ''}`, ...(coupon.note ? [coupon.note] : []), ''] : [])
    .concat([`${ctaLabel}: ${ctaUrl}`, '', 'You get this e-mail because you turned on offer e-mails in your CoRoute account.', `Unsubscribe: ${unsubscribeUrl}`, `Manage e-mails: ${accountUrl}`, '', '-- CoRoute'])
    .join('\n');
  return { subject, html, text, ctaUrl, errors: body.errors };
}

class OfferEmails {
  constructor({ soda, repo, mailer, origin = '', secret = '', logger = console, clock = Date.now, sleep, ratePerSec, batchSize = 50,
    leaseMs = 2 * 60000, imagesCollection = 'push_images', env = process.env } = {}) {
    this.soda = soda; this.repo = repo; this.mailer = mailer;
    this.origin = String(origin || '').replace(/\/+$/, '');
    this.secret = secret || 'offer-unsubscribe-dev-secret';
    this.logger = logger; this.clock = clock;
    this.sleep = sleep || ((ms) => new Promise((r) => { const t = setTimeout(r, ms); t.unref?.(); }));
    this.ratePerSec = Math.max(1, Number(ratePerSec || env.OFFER_EMAIL_RATE) || 5);
    this.batchSize = Math.max(1, batchSize);
    this.leaseMs = leaseMs;
    this.imagesCollection = imagesCollection;
    this.worker = `${require('os').hostname()}:${process.pid}:${crypto.randomBytes(3).toString('hex')}`;
    this.ready = null;
    this.running = false;
  }

  async ensureStore() {
    if (!this.ready) {
      this.ready = (async () => {
        for (const c of Object.values(C)) await this.soda.ensureCollection(c);
        const idx = (c, name, fields, unique = false) => this.soda.ensureIndex(c, { name, unique, fields: fields.map((p) => ({ path: p })) });
        await idx(C.consent, 'marketing_consent_user_ux', ['userId'], true);
        await idx(C.suppression, 'email_suppression_hash_ux', ['emailHash'], true);
        await idx(C.campaigns, 'offer_email_campaigns_id_ux', ['campaignId'], true);
        await idx(C.campaigns, 'offer_email_campaigns_status_ix', ['status']);
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  unsubscribeUrl(userId) { return `${this.origin}/email/unsubscribe?u=${encodeURIComponent(userId)}&t=${unsubscribeToken(this.secret, userId)}`; }

  // ------------------------------------------------------------ consent
  async consentOf(userId) {
    await this.ensureStore();
    const row = await this.soda.findOne(C.consent, { userId });
    const v = row ? row.value : null;
    return { offersEmail: !!(v && v.offersEmail === true), updatedAt: (v && v.updatedAt) || 0 };
  }

  async setConsent(userId, on, { source = 'website', email = '' } = {}) {
    await this.ensureStore();
    const row = await this.soda.findOne(C.consent, { userId });
    const now = this.clock();
    const prev = row ? row.value : { userId, history: [] };
    const history = Array.isArray(prev.history) ? prev.history.slice(-(HISTORY_MAX - 1)) : [];
    history.push({ offersEmail: !!on, at: now, source: String(source).slice(0, 30) });
    const doc = { userId, offersEmail: !!on, updatedAt: now, consentAt: on ? now : (prev.consentAt || null), source: String(source).slice(0, 30), history };
    await this.soda.upsertBy(C.consent, { userId }, doc);
    // Opting in again lifts the rider's own "unsubscribe" entry (never a bounce / complaint / admin one).
    if (on && validEmail(email)) {
      const s = await this.soda.findOne(C.suppression, { emailHash: emailHash(email) });
      if (s && s.value.reason === 'unsubscribe') await this.soda.removeWhere(C.suppression, { emailHash: emailHash(email) });
    }
    return { offersEmail: !!on, updatedAt: now };
  }

  // ------------------------------------------------------------ suppression
  async isSuppressed(email) {
    await this.ensureStore();
    return !!(await this.soda.findOne(C.suppression, { emailHash: emailHash(email) }));
  }

  async suppress(email, reason = 'admin', by = 'system') {
    if (!validEmail(email)) throw new OfferEmailError('Enter a valid e-mail address.', 'BAD_ADDRESS');
    if (!SUPPRESSION_REASONS.includes(reason)) throw new OfferEmailError(`Reason must be one of: ${SUPPRESSION_REASONS.join(', ')}.`, 'BAD_REASON');
    await this.ensureStore();
    const doc = { emailHash: emailHash(email), masked: maskEmail(email), reason, at: this.clock(), by: String(by).slice(0, 120) };
    await this.soda.upsertBy(C.suppression, { emailHash: doc.emailHash }, doc);
    return doc;
  }

  async unsuppress(hash) {
    if (!/^[a-f0-9]{64}$/.test(String(hash))) throw new OfferEmailError('Unknown entry.', 'NOT_FOUND', 404);
    await this.ensureStore();
    return this.soda.removeWhere(C.suppression, { emailHash: hash });
  }

  async listSuppression({ limit = 200 } = {}) {
    await this.ensureStore();
    const rows = await this.soda.query(C.suppression, {}, { orderBy: [{ path: 'at', datatype: 'number', order: 'desc' }], limit: Math.min(1000, Math.max(1, limit)) });
    return rows.map((r) => ({ emailHash: r.value.emailHash, masked: r.value.masked, reason: r.value.reason, at: r.value.at, by: r.value.by }));
  }

  /** The unsubscribe link / one-click POST: consent off + suppression. False for a bad token. */
  async unsubscribe(userId, token, { campaignId = '' } = {}) {
    if (!tokenOk(this.secret, userId, token)) return false;
    await this.setConsent(userId, false, { source: 'unsubscribe' });
    const user = await this.repo.findUserById(userId).catch(() => null);
    if (user && validEmail(user.email)) await this.suppress(user.email, 'unsubscribe', 'rider');
    // 3.57 e-mail studio: count the unsubscribe against the campaign whose link was used (reporting only).
    if (campaignId && typeof this.onUnsubscribe === 'function') { try { await this.onUnsubscribe(userId, String(campaignId)); } catch { /* reporting only */ } }
    return true;
  }

  async forgetUser(userId) {
    await this.ensureStore();
    await this.soda.removeWhere(C.consent, { userId }).catch(() => {});
    // The suppression entry (a hash) stays: an erased account's address must not be mailed again.
  }

  // ------------------------------------------------------------ validation
  async validate(input, { test = false } = {}) {
    const b = input && typeof input === 'object' ? input : {};
    const subject = oneLine(b.subject);
    const heading = oneLine(b.heading);
    const content = textBlock(b.content);
    if (!subject) throw new OfferEmailError('Write a subject.', 'SUBJECT_REQUIRED');
    if (subject.length > MAX_SUBJECT) throw new OfferEmailError(`The subject is longer than ${MAX_SUBJECT} characters.`, 'SUBJECT_TOO_LONG');
    if (heading.length > MAX_HEADING) throw new OfferEmailError(`The heading is longer than ${MAX_HEADING} characters.`, 'HEADING_TOO_LONG');
    if (!content) throw new OfferEmailError('Write the e-mail.', 'CONTENT_REQUIRED');
    if (content.length > MAX_CONTENT) throw new OfferEmailError(`The e-mail is longer than ${MAX_CONTENT} characters.`, 'CONTENT_TOO_LONG');
    if (!/^https?:\/\//.test(this.origin)) throw new OfferEmailError('Offer e-mails need the site address (PUBLIC_ORIGIN) for their links.', 'NO_ORIGIN', 503);
    const rendered = renderContent(content, this.origin);
    if (rendered.errors.length) throw new OfferEmailError(rendered.errors[0], 'BAD_LINK');
    let coupon = null;
    if (b.coupon && typeof b.coupon === 'object' && (b.coupon.code || '').toString().trim()) {
      const code = cleanCouponCode(b.coupon.code);
      if (!code) throw new OfferEmailError('A coupon code has only letters, digits, - and _ (at most 24).', 'BAD_COUPON');
      const found = this.repo && typeof this.repo.findCoupon === 'function' ? await this.repo.findCoupon(code).catch(() => null) : null;
      if (!found) throw new OfferEmailError(`There is no coupon ${code}. Create it in Coupons first.`, 'UNKNOWN_COUPON');
      if (['EXPIRED', 'ARCHIVED', 'USAGE_LIMIT_REACHED'].includes(found.status)) throw new OfferEmailError(`Coupon ${code} can no longer be used (${String(found.status).toLowerCase().replace(/_/g, ' ')}).`, 'COUPON_UNUSABLE');
      coupon = { code, headline: oneLine(b.coupon.headline).slice(0, 80), note: oneLine(b.coupon.note).slice(0, 160) };
    }
    let image = null;
    if (b.imageId != null && b.imageId !== '') {
      if (!IMAGE_ID.test(String(b.imageId))) throw new OfferEmailError('Unknown image.', 'BAD_IMAGE');
      await this.soda.ensureCollection(this.imagesCollection);
      const row = await this.soda.findOne(this.imagesCollection, { imageId: String(b.imageId) });
      if (!row) throw new OfferEmailError('Unknown image. Upload it again.', 'BAD_IMAGE');
      image = { imageId: row.value.imageId, url: `${this.origin}/media/push/${row.value.imageId}.${row.value.ext}` };
    }
    const out = { subject, heading, content, coupon, image };
    if (test) return out;
    out.audience = this.validateAudience(b.audience);
    const now = this.clock();
    let sendAt = Number(b.sendAt) || 0;
    if (!sendAt || sendAt < now) {
      if (sendAt && sendAt < now - 5 * 60000) throw new OfferEmailError('The send time is in the past.', 'BAD_TIME');
      sendAt = now;
    }
    if (sendAt > now + 60 * DAY) throw new OfferEmailError('Schedule at most 60 days ahead.', 'BAD_TIME');
    out.sendAt = sendAt;
    return out;
  }

  validateAudience(a) {
    const aud = a && typeof a === 'object' ? a : { kind: 'all' };
    const kind = String(aud.kind || 'all');
    if (kind === 'active') {
      const days = Math.round(Number(aud.days));
      if (!(days >= 1 && days <= 365)) throw new OfferEmailError('Active in the last N days: N must be 1 to 365.', 'BAD_AUDIENCE');
      return { kind, days };
    }
    if (kind === 'plan') {
      const ok = ['community', 'group_small', 'group_large'];
      const plans = [...new Set((Array.isArray(aud.plans) ? aud.plans : []).map(String))];
      if (!plans.length || plans.some((p) => !ok.includes(p))) throw new OfferEmailError(`Choose plan types from: ${ok.join(', ')}.`, 'BAD_AUDIENCE');
      return { kind, plans };
    }
    if (kind !== 'all') throw new OfferEmailError('Unknown audience.', 'BAD_AUDIENCE');
    return { kind: 'all' };
  }

  /** The e-mail of one rider (or a preview for `userId` null). */
  render(c, userId) {
    return buildOfferEmail({
      subject: c.subject, heading: c.heading, content: c.content, imageUrl: c.image ? c.image.url : c.imageUrl, coupon: c.coupon,
      origin: this.origin, unsubscribeUrl: userId ? this.unsubscribeUrl(userId) : `${this.origin}/email/unsubscribe`, accountUrl: `${this.origin}/account`,
    });
  }

  // ------------------------------------------------------------ audience
  /** [{userId, email}] of riders who opted in, with a valid, unsuppressed e-mail, in the audience. */
  async resolveAudience(aud) {
    await this.ensureStore();
    const ids = [];
    for await (const page of this.soda.scan(C.consent)) for (const r of page) if (r.value && r.value.offersEmail === true && r.value.userId) ids.push(r.value.userId);
    let planOf = null;
    if (aud.kind === 'plan') {
      const { COLLECTIONS } = require('./oracle/repo');
      const now = this.clock();
      planOf = new Map();
      const rows = await this.soda.query(COLLECTIONS.memberships, { status: 'ACTIVE' }, { limit: 100000 }).catch(() => []);
      for (const r of rows) { const m = r.value; if (m && m.ownerUserId && Number(m.validUntil) > now && m.category) planOf.set(m.ownerUserId, m.category); }
    }
    const out = [];
    const since = aud.kind === 'active' ? this.clock() - aud.days * DAY : 0;
    for (const uid of ids) {
      const u = await this.repo.findUserById(uid).catch(() => null);
      if (!u || u.deletedAt || !validEmail(u.email)) continue;
      if (await this.isSuppressed(u.email)) continue;
      if (planOf && !aud.plans.includes(planOf.get(uid) || 'community')) continue;
      if (since && Math.max(Number(u.lastActiveAt) || 0, Number(u.lastLoginAt) || 0) < since) continue;
      out.push({ userId: uid, email: u.email.trim() });
    }
    return out;
  }

  async audienceCount(input) { return { riders: (await this.resolveAudience(this.validateAudience(input))).length }; }

  // ------------------------------------------------------------ campaigns
  _public(doc) {
    if (!doc) return null;
    const { recipients, leaseUntil, worker, ...rest } = doc; // eslint-disable-line no-unused-vars
    return { ...rest, recipients: Array.isArray(recipients) ? recipients.length : 0 };
  }

  async create(input, { by = 'admin' } = {}) {
    const c = await this.validate(input);
    const now = this.clock();
    const doc = {
      campaignId: `oe_${crypto.randomBytes(10).toString('hex')}`, channel: 'email', subject: c.subject, heading: c.heading, content: c.content,
      coupon: c.coupon, imageId: c.image ? c.image.imageId : null, imageUrl: c.image ? c.image.url : null, audience: c.audience, sendAt: c.sendAt,
      status: 'SCHEDULED', test: false, createdAt: now, createdBy: String(by).slice(0, 120), updatedAt: now,
      stats: { targeted: 0, sent: 0, failed: 0, skipped: 0 }, cursor: 0, recipients: null, leaseUntil: 0, worker: null, error: null, startedAt: null, finishedAt: null,
    };
    await this.soda.insert(C.campaigns, doc);
    return this._public(doc);
  }

  async list({ limit = 50 } = {}) {
    await this.ensureStore();
    const rows = await this.soda.query(C.campaigns, {}, { orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }], limit: Math.min(200, Math.max(1, limit)) });
    return rows.map((r) => this._public(r.value));
  }

  async get(id) {
    if (!CAMPAIGN_ID.test(String(id))) return null;
    await this.ensureStore();
    const row = await this.soda.findOne(C.campaigns, { campaignId: id });
    return row ? this._public(row.value) : null;
  }

  async cancel(id, { by = 'admin' } = {}) {
    if (!CAMPAIGN_ID.test(String(id))) throw new OfferEmailError('Campaign not found.', 'NOT_FOUND', 404);
    await this.ensureStore();
    const row = await this.soda.findOne(C.campaigns, { campaignId: id });
    if (!row) throw new OfferEmailError('Campaign not found.', 'NOT_FOUND', 404);
    if (row.value.status !== 'SCHEDULED') throw new OfferEmailError('Only a scheduled campaign that has not started can be cancelled.', 'NOT_CANCELLABLE', 409);
    const next = { ...row.value, status: 'CANCELLED', cancelledBy: String(by).slice(0, 120), updatedAt: this.clock(), finishedAt: this.clock() };
    if (!(await this.soda.compareAndReplace(C.campaigns, row.key, row.value, next))) throw new OfferEmailError('The campaign changed. Try again.', 'CONFLICT', 409);
    return this._public(next);
  }

  /** Test send to the admin's own account e-mail (consent and suppression do not apply). */
  async testSend(input, { userId }) {
    const c = await this.validate(input, { test: true });
    const u = await this.repo.findUserById(userId).catch(() => null);
    if (!u || !validEmail(u.email)) throw new OfferEmailError('Your admin account has no e-mail address.', 'NO_ADDRESS');
    const mail = this.render(c, userId);
    const r = await this.mailer.send({ to: u.email, subject: `[Test] ${mail.subject}`, html: mail.html, text: mail.text, headers: this._headers(userId) });
    if (r.disabled) throw new OfferEmailError('E-mail is not configured on this server (SMTP_HOST / MAIL_FROM).', 'MAIL_OFF', 503);
    return { sent: !!r.sent, to: maskEmail(u.email), error: r.error || null };
  }

  _headers(userId) {
    return { 'List-Unsubscribe': `<${this.unsubscribeUrl(userId)}>`, 'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click', 'X-CoRoute-Category': 'offers' };
  }

  // ------------------------------------------------------------ sending job
  async tick() {
    if (this.running) return 0;
    this.running = true;
    let n = 0;
    try {
      await this.ensureStore();
      for (let guard = 0; guard < 10; guard++) {
        const claimed = await this._claimNext();
        if (!claimed) break;
        n++;
        await this._run(claimed);
      }
    } catch (e) {
      this.logger.warn?.(`[offer-emails] tick failed: ${e.message}`);
    } finally { this.running = false; }
    return n;
  }

  async _claimNext() {
    const now = this.clock();
    const due = [
      ...(await this.soda.query(C.campaigns, { status: 'SCHEDULED', sendAt: { $lte: now } }, { limit: 5 })),
      ...(await this.soda.query(C.campaigns, { status: 'SENDING', leaseUntil: { $lt: now } }, { limit: 5 })),
    ];
    for (const row of due) {
      const next = { ...row.value, status: 'SENDING', worker: this.worker, leaseUntil: now + this.leaseMs, startedAt: row.value.startedAt || now, updatedAt: now };
      if (await this.soda.compareAndReplace(C.campaigns, row.key, row.value, next)) return { key: row.key, doc: next };
    }
    return null;
  }

  async _save(state, patch) {
    const next = { ...state.doc, ...patch, updatedAt: this.clock() };
    if (next.status === 'SENDING') next.leaseUntil = this.clock() + this.leaseMs;
    const ok = await this.soda.compareAndReplace(C.campaigns, state.key, state.doc, next);
    if (ok) state.doc = next;
    return ok;
  }

  async _run(state) {
    if (!this.mailer || !this.mailer.enabled) {
      await this._save(state, { status: 'FAILED', error: 'E-mail is not configured on this server (SMTP_HOST / MAIL_FROM).', finishedAt: this.clock() });
      return;
    }
    if (!Array.isArray(state.doc.recipients)) {
      let list;
      try { list = (await this.resolveAudience(state.doc.audience)).map((x) => x.userId); } catch (e) {
        await this._save(state, { status: 'FAILED', error: `Audience could not be read: ${e.message}`.slice(0, 200), finishedAt: this.clock() });
        return;
      }
      if (!(await this._save(state, { recipients: list, cursor: 0, stats: { ...state.doc.stats, targeted: list.length } }))) return;
    }
    while (state.doc.cursor < state.doc.recipients.length) {
      const started = this.clock();
      const slice = state.doc.recipients.slice(state.doc.cursor, state.doc.cursor + this.batchSize);
      const stats = { ...state.doc.stats };
      for (const uid of slice) {
        // Consent and suppression are checked again at send time (a rider may have unsubscribed since).
        const [consent, u] = await Promise.all([this.consentOf(uid), this.repo.findUserById(uid).catch(() => null)]);
        if (!consent.offersEmail || !u || !validEmail(u.email) || (await this.isSuppressed(u.email))) { stats.skipped++; continue; }
        const mail = this.render(state.doc, uid);
        const r = await this.mailer.send({ to: u.email, subject: mail.subject, html: mail.html, text: mail.text, headers: this._headers(uid) });
        if (r.sent) stats.sent++; else stats.failed++;
      }
      if (!(await this._save(state, { cursor: state.doc.cursor + slice.length, stats }))) return;
      const wantMs = Math.ceil((slice.length / this.ratePerSec) * 1000);
      const spent = this.clock() - started;
      if (state.doc.cursor < state.doc.recipients.length && wantMs > spent) await this.sleep(wantMs - spent);
    }
    await this._save(state, { status: 'SENT', finishedAt: this.clock(), recipients: [], leaseUntil: 0 });
  }
}

// ------------------------------------------------------------ routers
function adminOfferEmailRouter({ offers }) {
  const r = express.Router();
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  const fail = (res, e, next) => (e instanceof OfferEmailError ? res.status(e.status).json({ error: e.message, code: e.code }) : next(e));
  const h = (fn) => async (req, res, next) => { try { await fn(req, res); } catch (e) { fail(res, e, next); } };
  r.get('/config', h(async (req, res) => {
    res.json({ enabled: !!(offers.mailer && offers.mailer.enabled), origin: offers.origin, ratePerSec: offers.ratePerSec,
      limits: { subject: MAX_SUBJECT, heading: MAX_HEADING, content: MAX_CONTENT }, suppressionReasons: SUPPRESSION_REASONS });
  }));
  r.post('/offers/check', h(async (req, res) => { await offers.validate(req.body, { test: true }); res.json({ ok: true }); }));
  r.post('/offers/preview', h(async (req, res) => { const c = await offers.validate(req.body, { test: true }); const m = offers.render(c, null); res.json({ subject: m.subject, html: m.html, text: m.text, ctaUrl: m.ctaUrl }); }));
  r.post('/offers/audience-count', h(async (req, res) => { res.json(await offers.audienceCount(req.body && req.body.audience)); }));
  r.post('/offers/test', h(async (req, res) => { res.json(await offers.testSend(req.body, { userId: req.user.userId })); }));
  r.post('/offers/campaigns', h(async (req, res) => {
    const c = await offers.create(req.body, { by: by(req) });
    if (c.sendAt <= Date.now() + 1000) setImmediate(() => offers.tick().catch(() => {}));
    res.status(201).json({ campaign: c });
  }));
  r.get('/offers/campaigns', h(async (req, res) => { res.json({ campaigns: await offers.list({ limit: Number(req.query.limit) || 50 }) }); }));
  r.get('/offers/campaigns/:id', h(async (req, res) => {
    const c = await offers.get(req.params.id);
    if (!c) return res.status(404).json({ error: 'Campaign not found.', code: 'NOT_FOUND' });
    res.json({ campaign: c });
  }));
  r.post('/offers/campaigns/:id/cancel', h(async (req, res) => { res.json({ campaign: await offers.cancel(req.params.id, { by: by(req) }) }); }));
  r.get('/suppression', h(async (req, res) => { res.json({ entries: await offers.listSuppression({ limit: Number(req.query.limit) || 200 }) }); }));
  r.post('/suppression', h(async (req, res) => {
    const b = req.body || {};
    const e = await offers.suppress(String(b.email || ''), b.reason ? String(b.reason) : 'admin', by(req));
    res.status(201).json({ entry: { emailHash: e.emailHash, masked: e.masked, reason: e.reason, at: e.at } });
  }));
  r.delete('/suppression/:hash', h(async (req, res) => { await offers.unsuppress(req.params.hash); res.json({ ok: true }); }));
  return r;
}

/** GET / PUT /api/web/marketing-consent {offersEmail} (website account page, Bearer). */
function consentRouter({ offers, repo }) {
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 20, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => req.user?.userId || req.ip,
    message: { error: 'Too many requests. Wait a minute.', code: 'RATE_LIMITED' } });
  r.get('/', limiter, async (req, res, next) => {
    try {
      const c = await offers.consentOf(req.user.userId);
      const u = req.dbUser || (await repo.findUserById(req.user.userId).catch(() => null));
      const suppressed = u && validEmail(u.email) ? await offers.isSuppressed(u.email) : false;
      res.set('Cache-Control', 'no-store').json({ ...c, hasEmail: !!(u && validEmail(u.email)), suppressed });
    } catch (e) { next(e); }
  });
  r.put('/', limiter, async (req, res, next) => {
    try {
      const b = req.body && typeof req.body === 'object' ? req.body : {};
      if (typeof b.offersEmail !== 'boolean') return res.status(400).json({ error: 'offersEmail must be true or false.', code: 'BAD_PREF' });
      const u = req.dbUser || (await repo.findUserById(req.user.userId).catch(() => null));
      if (b.offersEmail && !(u && validEmail(u.email))) return res.status(409).json({ error: 'Add an e-mail address to your account first.', code: 'NO_ADDRESS' });
      res.set('Cache-Control', 'no-store').json(await offers.setConsent(req.user.userId, b.offersEmail, { source: 'website', email: u && u.email }));
    } catch (e) { next(e); }
  });
  return r;
}

const PAGE_HEADERS = { 'Cache-Control': 'no-store', 'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'", 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff' };
function page(title, bodyHtml) {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">'
    + `<title>${esc(title)} | CoRoute</title></head><body style="margin:0;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:#f4f5f7;color:#111827;">`
    + `<main style="max-width:480px;margin:48px auto;background:#fff;border-radius:12px;padding:28px;"><p style="color:#2B7A8C;font-weight:700;margin:0 0 16px;">CoRoute</p>${bodyHtml}</main></body></html>`;
}

/**
 * /email/unsubscribe?u=&t=  GET: a page with one "Unsubscribe" button (link scanners never unsubscribe
 * anyone); POST (the button, or a mail client's RFC 8058 one-click): consent off + suppression.
 */
function unsubscribeRouter({ offers }) {
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false, message: 'Too many requests.' });
  const params = (req) => ({ u: String(req.query.u || (req.body && req.body.u) || ''), t: String(req.query.t || (req.body && req.body.t) || ''),
    cid: /^e[ca]_[a-f0-9]{16,20}$/.test(String(req.query.cid || '')) ? String(req.query.cid) : '' });
  r.get('/email/unsubscribe', limiter, (req, res) => {
    const { u, t, cid } = params(req);
    res.set(PAGE_HEADERS);
    if (!tokenOk(offers.secret, u, t)) return res.status(400).type('html').send(page('Link not valid', '<h1 style="font-size:20px;">This link is not valid</h1><p>Turn offer e-mails off on your account page at any time.</p>'));
    return res.type('html').send(page('Unsubscribe', '<h1 style="font-size:20px;">Stop offer e-mails?</h1><p>You will not get CoRoute offer e-mails any more. Receipts and safety messages are not affected.</p>'
      + `<form method="post" action="/email/unsubscribe?u=${encodeURIComponent(u)}&amp;t=${encodeURIComponent(t)}${cid ? `&amp;cid=${cid}` : ''}"><button type="submit" style="background:#2B7A8C;color:#fff;border:0;border-radius:8px;padding:11px 18px;font-size:15px;font-weight:600;">Unsubscribe</button></form>`));
  });
  r.post('/email/unsubscribe', limiter, express.urlencoded({ extended: false, limit: '2kb' }), async (req, res, next) => {
    try {
      const { u, t, cid } = params(req);
      res.set(PAGE_HEADERS);
      const ok = await offers.unsubscribe(u, t, { campaignId: cid });
      if (!ok) return res.status(400).type('html').send(page('Link not valid', '<h1 style="font-size:20px;">This link is not valid</h1>'));
      return res.type('html').send(page('Unsubscribed', '<h1 style="font-size:20px;">You are unsubscribed</h1><p>You will not get CoRoute offer e-mails any more. You can turn them on again on your account page.</p>'));
    } catch (e) { next(e); }
  });
  return r;
}

module.exports = {
  OfferEmails, OfferEmailError, adminOfferEmailRouter, consentRouter, unsubscribeRouter, buildOfferEmail, renderContent,
  unsubscribeToken, tokenOk, emailHash, maskEmail, C, SUPPRESSION_REASONS,
};
