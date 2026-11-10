'use strict';
/**
 * 3.56 admin push campaigns, "News and updates" (docs/features_355/notifications_admin.md).
 *
 * The web admin composes a push (title <= 65, body <= 240, optional big image, optional deep-link
 * target from a fixed list), picks an audience (all riders, riders active in the last N days, plan
 * type, a list of usernames, or a test send to the admin's own phone), and sends it now or at a
 * date / time (India time). History shows delivery counts.
 *
 * Rules:
 *  - Play payments policy guard (policy_terms.js): no prices, coupons, discounts, offers or buying
 *    words, and no link to the plans page, in the title or body: refused with a message pointing to
 *    the website board / e-mail. No links at all in the text (a push opens an app screen, not a URL).
 *  - Riders can turn "News and updates" off in the app (PUT /api/me/push-prefs {news:false}); safety,
 *    ride and social pushes are not part of this category and cannot be turned off here.
 *  - At most DAILY_CAP (2) campaign pushes per rider per India day (collection push_news_caps).
 *    A test send ignores the cap and the opt-out (it only reaches the admin's own phones).
 *  - Scheduled sending runs in a leased job (one node), claims a campaign with a compare-and-replace
 *    lease (a crashed worker's campaign is taken over after the lease ends and resumes at its cursor),
 *    and sends in batches at PUSH_CAMPAIGN_RATE tokens per second (default 50, far under FCM's quota).
 *  - Images: JPEG / PNG / WebP up to 1 MB, recognised by their bytes, metadata (EXIF, GPS) removed by
 *    the review photo pipeline (review_photos.preparePhoto), random names, served publicly over the
 *    site's https origin at /media/push/pi_<id>.<ext> (the phone downloads it without a session).
 *
 * Collections: push_campaigns, push_images (metadata), push_prefs, push_news_caps.
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { preparePhoto, PhotoError } = require('./review_photos');
const { forbiddenTermIn, policyRefusal } = require('./policy_terms');
const { NEWS_TARGETS } = require('./push');

const C = Object.freeze({ campaigns: 'push_campaigns', images: 'push_images', prefs: 'push_prefs', caps: 'push_news_caps', tokens: 'push_tokens' });
const MAX_TITLE = 65;
const MAX_BODY = 240;
const MAX_IMAGE_BYTES = 1024 * 1024;
const DAY = 86400000;
const IST = 330 * 60000;
const PLAN_TARGETS = Object.freeze(['community', 'group_small', 'group_large']);
const AUDIENCES = Object.freeze(['all', 'active', 'plan', 'users']);
const CAMPAIGN_ID = /^pc_[a-f0-9]{20}$/;
const IMAGE_ID = /^pi_[a-f0-9]{24}$/;
const IMAGE_TYPES = { jpg: 'image/jpeg', png: 'image/png', webp: 'image/webp' };

class CampaignError extends Error {
  constructor(message, code = 'BAD_CAMPAIGN', status = 400) { super(message); this.code = code; this.status = status; }
}

const istDay = (ms) => new Date(ms + IST).toISOString().slice(0, 10);
const oneLine = (s) => String(s == null ? '' : s).replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
const textBlock = (s) => String(s == null ? '' : s).replace(/\r\n/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f]+/g, ' ').replace(/[ \t]{2,}/g, ' ').trim();

/** Disk (PUSH_IMAGE_DIR) or Object Storage (REVIEW_PHOTO_STORE=par, prefix push-images/) for push images. */
function createImageStore({ dir, objectStore = null } = {}) {
  const fileOf = (id, ext) => (IMAGE_ID.test(id) && IMAGE_TYPES[ext] ? path.join(dir, `${id}.${ext}`) : null);
  if (objectStore) {
    const name = (id, ext) => (IMAGE_ID.test(id) && IMAGE_TYPES[ext] ? `push-images/${id}.${ext}` : null);
    return {
      async save(id, ext, data) { await objectStore.put(name(id, ext), data, IMAGE_TYPES[ext]); },
      async read(id, ext) { const n = name(id, ext); return n ? objectStore.get(n).catch(() => null) : null; },
    };
  }
  return {
    async save(id, ext, data) {
      await fs.promises.mkdir(dir, { recursive: true, mode: 0o700 });
      await fs.promises.writeFile(fileOf(id, ext), data, { flag: 'wx', mode: 0o600 });
    },
    async read(id, ext) { const f = fileOf(id, ext); return f ? fs.promises.readFile(f).catch(() => null) : null; },
  };
}

function defaultImageStore() {
  const config = require('./config');
  const dir = (process.env.PUSH_IMAGE_DIR || '').trim() || path.join(path.dirname(config.reviewPhotoDir), 'push-images');
  if (config.reviewPhotoStore === 'par' && config.reviewPhotoParUrl) {
    return createImageStore({ dir, objectStore: require('./object_store').createParStore(config.reviewPhotoParUrl) });
  }
  return createImageStore({ dir });
}

class PushCampaigns {
  /**
   * @param {object} o
   * @param {object} o.soda
   * @param {object} o.repo
   * @param {object} o.push            PushService (notifyUsers)
   * @param {string} [o.origin]        public https origin for image URLs (config.publicOrigin)
   */
  constructor({ soda, repo, push, origin = '', logger = console, clock = Date.now, sleep, imageStore, ratePerSec, batchSize = 100,
    dailyCap, leaseMs = 2 * 60000, env = process.env } = {}) {
    this.soda = soda; this.repo = repo; this.push = push; this.origin = String(origin || '').replace(/\/+$/, '');
    this.logger = logger; this.clock = clock;
    this.sleep = sleep || ((ms) => new Promise((r) => { const t = setTimeout(r, ms); t.unref?.(); }));
    this.images = imageStore || null;
    this.ratePerSec = Math.max(1, Number(ratePerSec || env.PUSH_CAMPAIGN_RATE) || 50);
    this.batchSize = Math.max(1, batchSize);
    this.dailyCap = Math.max(1, Number(dailyCap || env.PUSH_NEWS_DAILY_CAP) || 2);
    this.leaseMs = leaseMs;
    this.worker = `${require('os').hostname()}:${process.pid}:${crypto.randomBytes(3).toString('hex')}`;
    this.ready = null;
    this.running = false;
  }

  _imageStore() { if (!this.images) this.images = defaultImageStore(); return this.images; }

  async ensureStore() {
    if (!this.ready) {
      this.ready = (async () => {
        for (const c of Object.values(C)) await this.soda.ensureCollection(c);
        const idx = (c, name, fields, unique = false) => this.soda.ensureIndex(c, { name, unique, fields: fields.map((p) => ({ path: p })) });
        await idx(C.campaigns, 'push_campaigns_id_ux', ['campaignId'], true);
        await idx(C.campaigns, 'push_campaigns_status_ix', ['status']);
        await idx(C.images, 'push_images_id_ux', ['imageId'], true);
        await idx(C.prefs, 'push_prefs_user_ux', ['userId'], true);
        await idx(C.caps, 'push_news_caps_key_ux', ['key'], true);
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  // ------------------------------------------------------------ rider preference
  async newsEnabled(userId) {
    await this.ensureStore();
    const row = await this.soda.findOne(C.prefs, { userId });
    return !(row && row.value.news === false);
  }
  async setNews(userId, on) {
    await this.ensureStore();
    await this.soda.upsertBy(C.prefs, { userId }, { userId, news: !!on, updatedAt: this.clock() });
    return { news: !!on };
  }
  async forgetUser(userId) {
    await this.ensureStore();
    await this.soda.removeWhere(C.prefs, { userId }).catch(() => {});
    await this.soda.removeWhere(C.caps, { userId }).catch(() => {});
  }

  // ------------------------------------------------------------ images
  imageUrlOf(meta) { return meta && this.origin ? `${this.origin}/media/push/${meta.imageId}.${meta.ext}` : ''; }

  /** Checks, cleans (EXIF / GPS removed) and stores one image. Throws CampaignError. */
  async saveImage(buf, by = 'admin') {
    if (!Buffer.isBuffer(buf) || !buf.length) throw new CampaignError('No image was received.', 'NO_IMAGE');
    if (buf.length > MAX_IMAGE_BYTES) throw new CampaignError('The image is larger than 1 MB. Please use a smaller one.', 'IMAGE_TOO_LARGE', 413);
    let prepared;
    try { prepared = preparePhoto(buf); } catch (e) {
      if (e instanceof PhotoError) throw new CampaignError(e.code === 'UNSUPPORTED_PHOTO' ? 'Please choose a JPEG, PNG or WebP image.' : e.message, e.code, e.status);
      throw e;
    }
    if (prepared.data.length > MAX_IMAGE_BYTES) throw new CampaignError('The image is larger than 1 MB. Please use a smaller one.', 'IMAGE_TOO_LARGE', 413);
    await this.ensureStore();
    const imageId = `pi_${crypto.randomBytes(12).toString('hex')}`;
    await this._imageStore().save(imageId, prepared.ext, prepared.data);
    const meta = { imageId, ext: prepared.ext, mime: prepared.mime, bytes: prepared.data.length, width: prepared.width || null, height: prepared.height || null, createdAt: this.clock(), createdBy: String(by).slice(0, 120) };
    await this.soda.insert(C.images, meta);
    return { ...meta, url: this.imageUrlOf(meta) };
  }

  /** { data, mime } of a public image file name "pi_<id>.<ext>", or null. */
  async readImage(file) {
    const m = /^(pi_[a-f0-9]{24})\.(jpg|png|webp)$/.exec(String(file || ''));
    if (!m) return null;
    await this.ensureStore();
    const row = await this.soda.findOne(C.images, { imageId: m[1] });
    if (!row || row.value.ext !== m[2]) return null;
    const data = await this._imageStore().read(m[1], m[2]);
    return data ? { data, mime: IMAGE_TYPES[m[2]] } : null;
  }

  // ------------------------------------------------------------ validation
  /** A clean campaign from admin input. Throws CampaignError (400 / 422 policy). */
  async validate(input, { test = false } = {}) {
    const b = input && typeof input === 'object' ? input : {};
    const title = oneLine(b.title);
    const body = textBlock(b.body);
    if (!title) throw new CampaignError('Write a title.', 'TITLE_REQUIRED');
    if (title.length > MAX_TITLE) throw new CampaignError(`The title is longer than ${MAX_TITLE} characters.`, 'TITLE_TOO_LONG');
    if (!body) throw new CampaignError('Write the message.', 'BODY_REQUIRED');
    if (body.length > MAX_BODY) throw new CampaignError(`The message is longer than ${MAX_BODY} characters.`, 'BODY_TOO_LONG');
    const term = forbiddenTermIn(`${title}\n${body}`);
    if (term) throw new CampaignError(policyRefusal(term), 'PLAY_POLICY', 422);
    if (/(https?:\/\/|www\.)/i.test(`${title} ${body}`)) throw new CampaignError('Links are not allowed in a push. Choose the screen it opens instead.', 'NO_LINKS', 422);
    if (/[^\s@]+@[^\s@]+\.[^\s@]+/.test(`${title} ${body}`) || /(?:\+?\d[\s-]?){9,}/.test(`${title} ${body}`)) {
      throw new CampaignError('A push must not contain an e-mail address or a phone number.', 'PERSONAL_DATA', 422);
    }
    const target = b.target == null || b.target === '' ? 'home' : String(b.target);
    if (!NEWS_TARGETS.includes(target)) throw new CampaignError(`Choose a screen to open: ${NEWS_TARGETS.join(', ')}.`, 'BAD_TARGET');
    let image = null;
    if (b.imageId != null && b.imageId !== '') {
      if (!IMAGE_ID.test(String(b.imageId))) throw new CampaignError('Unknown image.', 'BAD_IMAGE');
      await this.ensureStore();
      const row = await this.soda.findOne(C.images, { imageId: String(b.imageId) });
      if (!row) throw new CampaignError('Unknown image. Upload it again.', 'BAD_IMAGE');
      if (!/^https:\/\//.test(this.origin)) throw new CampaignError('Images need the site to run on https (PUBLIC_ORIGIN). Send it without an image.', 'IMAGE_NEEDS_HTTPS');
      image = { imageId: row.value.imageId, ext: row.value.ext, url: this.imageUrlOf(row.value) };
    }
    const out = { title, body, target, image };
    if (test) return out;
    out.audience = await this.validateAudience(b.audience);
    const now = this.clock();
    let sendAt = Number(b.sendAt) || 0;
    if (!sendAt || sendAt < now) {
      if (sendAt && sendAt < now - 5 * 60000) throw new CampaignError('The send time is in the past.', 'BAD_TIME');
      sendAt = now;
    }
    if (sendAt > now + 60 * DAY) throw new CampaignError('Schedule at most 60 days ahead.', 'BAD_TIME');
    out.sendAt = sendAt;
    return out;
  }

  async validateAudience(a) {
    const aud = a && typeof a === 'object' ? a : { kind: 'all' };
    const kind = String(aud.kind || 'all');
    if (!AUDIENCES.includes(kind)) throw new CampaignError('Unknown audience.', 'BAD_AUDIENCE');
    if (kind === 'active') {
      const days = Math.round(Number(aud.days));
      if (!(days >= 1 && days <= 365)) throw new CampaignError('Active in the last N days: N must be 1 to 365.', 'BAD_AUDIENCE');
      return { kind, days };
    }
    if (kind === 'plan') {
      const plans = [...new Set((Array.isArray(aud.plans) ? aud.plans : []).map(String))];
      if (!plans.length || plans.some((p) => !PLAN_TARGETS.includes(p))) throw new CampaignError(`Choose plan types from: ${PLAN_TARGETS.join(', ')}.`, 'BAD_AUDIENCE');
      return { kind, plans };
    }
    if (kind === 'users') {
      const raw = Array.isArray(aud.usernames) ? aud.usernames : String(aud.usernames || '').split(/[\s,]+/);
      const names = [...new Set(raw.map((s) => String(s).trim().replace(/^@/, '').toLowerCase()).filter(Boolean))];
      if (!names.length) throw new CampaignError('Enter at least one username.', 'BAD_AUDIENCE');
      if (names.length > 200) throw new CampaignError('At most 200 usernames at once.', 'BAD_AUDIENCE');
      if (names.some((n) => !/^[a-z0-9_.]{3,30}$/.test(n))) throw new CampaignError('A username can only have letters, digits, _ and .', 'BAD_AUDIENCE');
      return { kind, usernames: names };
    }
    return { kind: 'all' };
  }

  // ------------------------------------------------------------ audience
  async _tokenUsers() {
    const ids = new Set();
    for await (const page of this.soda.scan(C.tokens)) for (const r of page) if (r.value && r.value.userId) ids.add(r.value.userId);
    return ids;
  }

  /** userIds of the audience (riders with a push token), before opt-out and caps. */
  async resolveAudience(aud) {
    await this.ensureStore();
    await this.soda.ensureCollection(C.tokens);
    const withTokens = await this._tokenUsers();
    if (aud.kind === 'users') {
      const { findUserByUsername } = require('./usernames');
      const out = [];
      for (const n of aud.usernames) {
        const u = await findUserByUsername(this.repo, n).catch(() => null);
        if (u && u.userId && withTokens.has(u.userId)) out.push(u.userId);
      }
      return [...new Set(out)];
    }
    if (aud.kind === 'active') {
      const since = this.clock() - aud.days * DAY;
      const out = [];
      for (const uid of withTokens) {
        const u = await this.repo.findUserById(uid).catch(() => null);
        if (u && Math.max(Number(u.lastActiveAt) || 0, Number(u.lastLoginAt) || 0) >= since) out.push(uid);
      }
      return out;
    }
    if (aud.kind === 'plan') {
      const { COLLECTIONS } = require('./oracle/repo');
      const now = this.clock();
      const planOf = new Map();
      const rows = await this.soda.query(COLLECTIONS.memberships, { status: 'ACTIVE' }, { limit: 100000 }).catch(() => []);
      for (const r of rows) {
        const m = r.value;
        if (m && m.ownerUserId && Number(m.validUntil) > now && m.category) planOf.set(m.ownerUserId, m.category);
      }
      const want = new Set(aud.plans);
      return [...withTokens].filter((uid) => want.has(planOf.get(uid) || 'community'));
    }
    return [...withTokens];
  }

  async audienceCount(input) {
    const aud = await this.validateAudience(input);
    const ids = await this.resolveAudience(aud);
    let optedOut = 0;
    for (const uid of ids) if (!(await this.newsEnabled(uid))) optedOut++;
    return { riders: ids.length - optedOut, optedOut };
  }

  // ------------------------------------------------------------ campaigns
  _public(doc) {
    if (!doc) return null;
    const { recipients, leaseUntil, worker, ...rest } = doc; // eslint-disable-line no-unused-vars
    return { ...rest, recipients: Array.isArray(recipients) ? recipients.length : 0 };
  }

  async create(input, { by = 'admin' } = {}) {
    const c = await this.validate(input);
    await this.ensureStore();
    const now = this.clock();
    const doc = {
      campaignId: `pc_${crypto.randomBytes(10).toString('hex')}`, title: c.title, body: c.body, target: c.target,
      imageId: c.image ? c.image.imageId : null, imageUrl: c.image ? c.image.url : null, audience: c.audience,
      sendAt: c.sendAt, status: 'SCHEDULED', test: false, createdAt: now, createdBy: String(by).slice(0, 120), updatedAt: now,
      stats: { targeted: 0, reached: 0, optedOut: 0, capped: 0, noToken: 0, sent: 0, failed: 0, pruned: 0 }, cursor: 0, recipients: null,
      leaseUntil: 0, worker: null, error: null, startedAt: null, finishedAt: null,
    };
    await this.soda.insert(C.campaigns, doc);
    return this._public(doc);
  }

  async list({ limit = 50 } = {}) {
    await this.ensureStore();
    const rows = await this.soda.query(C.campaigns, {}, { orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }], limit: Math.min(200, Math.max(1, limit)) });
    return rows.map((r) => this._public(r.value));
  }

  async get(campaignId) {
    if (!CAMPAIGN_ID.test(String(campaignId))) return null;
    await this.ensureStore();
    const row = await this.soda.findOne(C.campaigns, { campaignId });
    return row ? this._public(row.value) : null;
  }

  async cancel(campaignId, { by = 'admin' } = {}) {
    if (!CAMPAIGN_ID.test(String(campaignId))) throw new CampaignError('Campaign not found.', 'NOT_FOUND', 404);
    await this.ensureStore();
    for (let i = 0; i < 3; i++) {
      const row = await this.soda.findOne(C.campaigns, { campaignId });
      if (!row) throw new CampaignError('Campaign not found.', 'NOT_FOUND', 404);
      if (row.value.status !== 'SCHEDULED') throw new CampaignError('Only a scheduled campaign that has not started can be cancelled.', 'NOT_CANCELLABLE', 409);
      const next = { ...row.value, status: 'CANCELLED', cancelledBy: String(by).slice(0, 120), updatedAt: this.clock(), finishedAt: this.clock() };
      if (await this.soda.compareAndReplace(C.campaigns, row.key, row.value, next)) return this._public(next);
    }
    throw new CampaignError('The campaign changed. Try again.', 'CONFLICT', 409);
  }

  /** Test send to the admin's own phones (no opt-out, no cap). Recorded in the history. */
  async testSend(input, { userId, by = 'admin' } = {}) {
    const c = await this.validate(input, { test: true });
    if (!this.push) throw new CampaignError('Push is not available.', 'PUSH_OFF', 503);
    const r = await this.push.notifyUsers([userId], this._message(c, `pt_${crypto.randomBytes(6).toString('hex')}`));
    await this.ensureStore();
    const now = this.clock();
    const doc = {
      campaignId: `pc_${crypto.randomBytes(10).toString('hex')}`, title: c.title, body: c.body, target: c.target,
      imageId: c.image ? c.image.imageId : null, imageUrl: c.image ? c.image.url : null, audience: { kind: 'test' }, sendAt: now,
      status: r.disabled ? 'FAILED' : 'SENT', test: true, createdAt: now, createdBy: String(by).slice(0, 120), updatedAt: now, startedAt: now, finishedAt: now,
      stats: { targeted: 1, reached: r.sent > 0 ? 1 : 0, optedOut: 0, capped: 0, noToken: r.sent || r.failed ? 0 : 1, sent: r.sent, failed: r.failed - (r.pruned || 0), pruned: r.pruned || 0 },
      cursor: 1, recipients: null, leaseUntil: 0, worker: null, error: r.disabled ? this._disabledText(r.disabled) : null,
    };
    await this.soda.insert(C.campaigns, doc);
    return { ...this._public(doc), result: r };
  }

  _disabledText(reason) {
    return reason === 'switch' ? 'Push notifications are switched off (admin switch "Push notifications").' : 'Push is not configured on this server (FCM_SERVICE_ACCOUNT_JSON).';
  }

  _message(c, id) {
    const image = c.image ? c.image.url : c.imageUrl;
    return {
      type: 'NEWS', title: c.title, body: c.body, data: { campaignId: id, eventId: `NEWS:${id}` },
      imageUrl: image || undefined, target: c.target || 'home', collapseKey: `news_${id}`, skipConnected: false,
    };
  }

  // ------------------------------------------------------------ sending job
  /** The leased job: sends every due campaign (one at a time). Returns how many were worked on. */
  async tick() {
    if (this.running) return 0;
    this.running = true;
    let n = 0;
    try {
      await this.ensureStore();
      for (let guard = 0; guard < 20; guard++) {
        const claimed = await this._claimNext();
        if (!claimed) break;
        n++;
        await this._run(claimed);
      }
    } catch (e) {
      this.logger.warn?.(`[push-campaigns] tick failed: ${e.message}`);
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

  /** Saves progress and renews the lease; false when another worker took the campaign over. */
  async _save(state, patch) {
    const next = { ...state.doc, ...patch, updatedAt: this.clock() };
    if (next.status === 'SENDING') next.leaseUntil = this.clock() + this.leaseMs;
    const ok = await this.soda.compareAndReplace(C.campaigns, state.key, state.doc, next);
    if (ok) state.doc = next;
    return ok;
  }

  async _capOk(userId, day) {
    const row = await this.soda.findOne(C.caps, { key: `${userId}:${day}` });
    return !row || (row.value.count || 0) < this.dailyCap;
  }
  async _capAdd(userId, day) {
    const key = `${userId}:${day}`;
    const row = await this.soda.findOne(C.caps, { key });
    const doc = { key, userId, day, count: ((row && row.value.count) || 0) + 1, expiresAt: this.clock() + 3 * DAY };
    if (row) await this.soda.replace(C.caps, row.key, doc); else await this.soda.insert(C.caps, doc).catch(() => this.soda.upsertBy(C.caps, { key }, doc));
  }

  async _run(state) {
    const d = state.doc;
    if (!this.push || !this.push.enabled) {
      await this._save(state, { status: 'FAILED', error: this._disabledText('unconfigured'), finishedAt: this.clock() });
      return;
    }
    if (!Array.isArray(d.recipients)) {
      let ids;
      try { ids = await this.resolveAudience(d.audience); } catch (e) {
        await this._save(state, { status: 'FAILED', error: `Audience could not be read: ${e.message}`.slice(0, 200), finishedAt: this.clock() });
        return;
      }
      if (!(await this._save(state, { recipients: ids, cursor: 0, stats: { ...d.stats, targeted: ids.length } }))) return;
    }
    const message = this._message(state.doc, state.doc.campaignId);
    while (state.doc.cursor < state.doc.recipients.length) {
      const started = this.clock();
      const slice = state.doc.recipients.slice(state.doc.cursor, state.doc.cursor + this.batchSize);
      const stats = { ...state.doc.stats };
      const day = istDay(this.clock());
      let tokensSent = 0;
      for (const uid of slice) {
        if (!(await this.newsEnabled(uid))) { stats.optedOut++; continue; }
        if (!(await this._capOk(uid, day))) { stats.capped++; continue; }
        const r = await this.push.notifyUsers([uid], message);
        if (r.disabled) {
          await this._save(state, { status: 'FAILED', error: this._disabledText(r.disabled), stats, finishedAt: this.clock() });
          return;
        }
        stats.sent += r.sent; stats.pruned += r.pruned || 0; stats.failed += r.failed - (r.pruned || 0);
        tokensSent += r.sent + r.failed;
        if (r.sent > 0) { stats.reached++; await this._capAdd(uid, day); } else if (!r.failed) stats.noToken++;
      }
      // A cancelled-from-elsewhere or taken-over campaign stops here (the other worker continues).
      if (!(await this._save(state, { cursor: state.doc.cursor + slice.length, stats }))) return;
      const wantMs = Math.ceil((tokensSent / this.ratePerSec) * 1000);
      const spent = this.clock() - started;
      if (state.doc.cursor < state.doc.recipients.length && wantMs > spent) await this.sleep(wantMs - spent);
    }
    await this._save(state, { status: 'SENT', finishedAt: this.clock(), recipients: [], leaseUntil: 0 });
  }

  /** Old cap rows (older than 3 days) are dropped. */
  async cleanup() {
    await this.ensureStore();
    return this.soda.removeWhere(C.caps, { expiresAt: { $lt: this.clock() } }).catch(() => 0);
  }
}

// ------------------------------------------------------------ routers
function adminPushRouter({ campaigns, push }) {
  const r = express.Router();
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  const fail = (res, e, next) => (e instanceof CampaignError ? res.status(e.status).json({ error: e.message, code: e.code }) : next(e));
  r.get('/config', (req, res) => {
    res.json({
      enabled: !!(push && push.enabled), targets: NEWS_TARGETS, plans: PLAN_TARGETS, dailyCap: campaigns.dailyCap, ratePerSec: campaigns.ratePerSec,
      limits: { title: MAX_TITLE, body: MAX_BODY, imageBytes: MAX_IMAGE_BYTES }, imagesAllowed: /^https:\/\//.test(campaigns.origin),
    });
  });
  r.get('/campaigns', async (req, res, next) => { try { res.json({ campaigns: await campaigns.list({ limit: Number(req.query.limit) || 50 }) }); } catch (e) { fail(res, e, next); } });
  r.get('/campaigns/:id', async (req, res, next) => {
    try { const c = await campaigns.get(req.params.id); if (!c) return res.status(404).json({ error: 'Campaign not found.', code: 'NOT_FOUND' }); res.json({ campaign: c }); } catch (e) { fail(res, e, next); }
  });
  r.post('/campaigns', async (req, res, next) => {
    try {
      const c = await campaigns.create(req.body, { by: by(req) });
      if (c.sendAt <= Date.now() + 1000) setImmediate(() => campaigns.tick().catch(() => {}));
      res.status(201).json({ campaign: c });
    } catch (e) { fail(res, e, next); }
  });
  r.post('/campaigns/:id/cancel', async (req, res, next) => { try { res.json({ campaign: await campaigns.cancel(req.params.id, { by: by(req) }) }); } catch (e) { fail(res, e, next); } });
  r.post('/test', async (req, res, next) => { try { res.json(await campaigns.testSend(req.body, { userId: req.user.userId, by: by(req) })); } catch (e) { fail(res, e, next); } });
  r.post('/check', async (req, res, next) => {
    try { await campaigns.validate(req.body, { test: true }); res.json({ ok: true }); } catch (e) { fail(res, e, next); }
  });
  r.post('/audience-count', async (req, res, next) => { try { res.json(await campaigns.audienceCount(req.body && req.body.audience)); } catch (e) { fail(res, e, next); } });
  r.post('/images', express.raw({ type: () => true, limit: MAX_IMAGE_BYTES + 1024 }), async (req, res, next) => {
    try { res.status(201).json({ image: await campaigns.saveImage(Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0), by(req)) }); } catch (e) {
      if (e && e.type === 'entity.too.large') return res.status(413).json({ error: 'The image is larger than 1 MB. Please use a smaller one.', code: 'IMAGE_TOO_LARGE' });
      fail(res, e, next);
    }
  });
  // express.raw's own size refusal.
  r.use((err, req, res, next) => (err && err.type === 'entity.too.large' ? res.status(413).json({ error: 'The image is larger than 1 MB. Please use a smaller one.', code: 'IMAGE_TOO_LARGE' }) : next(err)));
  return r;
}

/** GET /media/push/:file (public: the phone downloads the big picture without a session). */
function pushMediaRouter({ campaigns }) {
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 600, standardHeaders: 'draft-7', legacyHeaders: false, message: 'Too many requests.' });
  r.get('/media/push/:file', limiter, async (req, res, next) => {
    try {
      const img = await campaigns.readImage(req.params.file);
      res.set({ 'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "default-src 'none'", 'Cross-Origin-Resource-Policy': 'cross-origin' });
      if (!img) return res.status(404).set('Cache-Control', 'no-store').type('text/plain').send('Not found');
      res.set({ 'Content-Type': img.mime, 'Cache-Control': 'public, max-age=2592000, immutable' }).send(img.data);
    } catch (e) { next(e); }
  });
  return r;
}

/** GET / PUT /api/me/push-prefs {news} (authenticated). */
function pushPrefsRouter({ campaigns }) {
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 20, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => req.user?.userId || req.ip,
    message: { error: 'Too many requests. Wait a minute.', code: 'RATE_LIMITED' } });
  r.get('/', limiter, async (req, res, next) => { try { res.set('Cache-Control', 'no-store').json({ news: await campaigns.newsEnabled(req.user.userId), safety: true }); } catch (e) { next(e); } });
  r.put('/', limiter, async (req, res, next) => {
    try {
      const b = req.body && typeof req.body === 'object' ? req.body : {};
      if (typeof b.news !== 'boolean') return res.status(400).json({ error: 'news must be true or false.', code: 'BAD_PREF' });
      res.set('Cache-Control', 'no-store').json({ ...(await campaigns.setNews(req.user.userId, b.news)), safety: true });
    } catch (e) { next(e); }
  });
  return r;
}

module.exports = { PushCampaigns, CampaignError, adminPushRouter, pushMediaRouter, pushPrefsRouter, createImageStore, C, MAX_TITLE, MAX_BODY, MAX_IMAGE_BYTES, PLAN_TARGETS };
