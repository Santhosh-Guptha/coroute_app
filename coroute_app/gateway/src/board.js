'use strict';
/**
 * 3.56 marketing board: "Latest from CoRoute" on the website (home page top 3, /updates all).
 * Admins post updates, offers, safety tips and events in the web admin (Board section); riders read
 * them on the website. Website only: nothing here is ever pushed to the app (no push, no socket event).
 * Docs: docs/features_355/marketing_board.md.
 *
 * Collection `board_posts` (repo COLLECTIONS.boardPosts), two document types:
 *   { type: 'post', postId: 'bp_<hex>', kind, title, body, link, imageId, couponCode, startAt, endAt,
 *     pinned, status: 'draft' | 'published' | 'archived', publishedAt, createdAt/By, updatedAt/By }
 *   { type: 'image', postId: 'rp_<hex>' (the image id), mime, ext, bytes, width, height, at, by }
 * Images go through the review photo pipeline (review_photos.preparePhoto: JPEG / PNG / WebP by magic
 * bytes, 2 MB, EXIF / XMP / IPTC removed; stored on disk outside public/ or in Object Storage).
 *
 * Endpoints
 *   GET    /api/public/board?kind=&limit=           published posts in their window: pinned first, newest
 *                                                    first; cached 60 s; only whitelisted plain fields
 *   GET    /api/public/board/images/:imageId        the image of a visible post (404 otherwise)
 *   GET    /api/admin/board                          every post (MASTER_ADMIN)
 *   POST   /api/admin/board                          create
 *   PATCH  /api/admin/board/:postId                  edit / publish / archive (status)
 *   DELETE /api/admin/board/:postId                  delete
 *   POST   /api/admin/board/images                   raw image bytes -> { image: { id } }
 *   GET    /api/admin/board/images/:imageId          image for the editor preview (drafts too)
 *   GET    /api/admin/board/coupons                  coupons a post may show (active or scheduled)
 * Every admin write is in the audit log (board.create / board.update / board.publish / board.archive /
 * board.delete / board.image.upload).
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const reviewPhotos = require('./review_photos');
const { istTime } = require('./payment_security');

const COLL = 'board_posts';
const KINDS = Object.freeze(['update', 'offer', 'safety_tip', 'event']);
const KIND_LABELS = Object.freeze({ update: 'Update', offer: 'Offer', safety_tip: 'Safety tip', event: 'Event' });
const STATUSES = Object.freeze(['draft', 'published', 'archived']);
const LIMITS = Object.freeze({ titleMax: 80, bodyMax: 600, linkMax: 200, maxPosts: 300, maxImages: 200, publicMax: 50 });
const CACHE_MS = 60 * 1000;
const POST_ID = /^bp_[a-f0-9]{20}$/;
/** Internal pages a post may link to (no other site, no /api, no /admin). */
const LINK = /^\/(?!\/)(?!api(?:\/|$))(?!admin(?:\/|$))[A-Za-z0-9\-._~/]*(?:\?[A-Za-z0-9\-._~=&%]*)?(?:#[A-Za-z0-9\-_]*)?$/;

class BoardError extends Error {
  constructor(message, field, status = 400, code = 'BAD_POST') {
    super(message);
    this.field = field;
    this.status = status;
    this.code = code;
  }
}

/** One line of plain text: control characters and line breaks removed, spaces collapsed. */
function oneLine(v) {
  return String(v == null ? '' : v).replace(/[\u0000-\u001f\u007f\u2028\u2029]+/g, ' ').replace(/\s+/g, ' ').trim();
}
/** Plain text with line breaks kept (at most two in a row), other control characters removed. */
function plainText(v) {
  return String(v == null ? '' : v)
    .replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0009\u000b-\u001f\u007f\u2028\u2029]/g, '')
    .split('\n').map((l) => l.replace(/[ \t]+/g, ' ').trimEnd()).join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** A link to a page of this site, or '' (throws on anything else). */
function cleanLink(v) {
  const s = String(v == null ? '' : v).trim();
  if (!s) return '';
  if (s.length > LIMITS.linkMax || !LINK.test(s) || s.includes('..') || /%2f|%5c|%00/i.test(s)) {
    throw new BoardError('The link must be a page of this website, like /plans or /safety.', 'link');
  }
  return s;
}

/**
 * Checks an admin's post fields (create: every field; patch: `prev` holds the rest). Returns the clean
 * fields or throws BoardError. Coupon and image references are checked by the caller.
 */
function cleanPost(body, prev = null) {
  const b = body && typeof body === 'object' ? body : {};
  const out = {};
  const has = (k) => Object.prototype.hasOwnProperty.call(b, k);
  if (!prev || has('title')) {
    const t = oneLine(b.title);
    if (!t) throw new BoardError('A title is needed.', 'title');
    if (t.length > LIMITS.titleMax) throw new BoardError(`The title can be at most ${LIMITS.titleMax} characters.`, 'title');
    out.title = t;
  }
  if (!prev || has('body')) {
    const t = plainText(b.body);
    if (!t) throw new BoardError('Write a few words for the post.', 'body');
    if (t.length > LIMITS.bodyMax) throw new BoardError(`The text can be at most ${LIMITS.bodyMax} characters.`, 'body');
    out.body = t;
  }
  if (!prev || has('kind')) {
    const k = String(b.kind || 'update');
    if (!KINDS.includes(k)) throw new BoardError(`kind must be one of ${KINDS.join(', ')}.`, 'kind');
    out.kind = k;
  }
  if (!prev || has('link')) out.link = cleanLink(b.link) || null;
  if (!prev || has('linkLabel')) {
    const l = oneLine(b.linkLabel).slice(0, 40);
    out.linkLabel = l || null;
  }
  if (!prev || has('pinned')) {
    if (has('pinned') && typeof b.pinned !== 'boolean') throw new BoardError('pinned must be true or false.', 'pinned');
    out.pinned = b.pinned === true;
  }
  if (!prev || has('status')) {
    const s = String(b.status || 'draft');
    if (!STATUSES.includes(s)) throw new BoardError('status must be draft, published or archived.', 'status');
    out.status = s;
  }
  for (const [f, edge] of [['startAt', 'start'], ['endAt', 'end']]) {
    if (prev && !has(f)) continue;
    const raw = b[f];
    if (raw === undefined || raw === null || raw === '') { out[f] = null; continue; }
    const t = istTime(raw, edge);
    if (!t) throw new BoardError(`${f === 'startAt' ? 'The start' : 'The end'} is not a valid date.`, f);
    out[f] = t;
  }
  const start = out.startAt !== undefined ? out.startAt : (prev && prev.startAt) || null;
  const end = out.endAt !== undefined ? out.endAt : (prev && prev.endAt) || null;
  if (start && end && end <= start) throw new BoardError('The post must end after it starts.', 'endAt');
  if (!prev || has('couponCode')) {
    const c = String(b.couponCode == null ? '' : b.couponCode).trim().toUpperCase();
    if (c && !/^[A-Z0-9_-]{3,32}$/.test(c)) throw new BoardError('That is not a coupon code.', 'couponCode');
    out.couponCode = c || null;
  }
  if (!prev || has('imageId')) {
    const i = b.imageId == null || b.imageId === '' ? null : String(b.imageId);
    if (i && !reviewPhotos.isPhotoId(i)) throw new BoardError('That is not an uploaded image.', 'imageId');
    out.imageId = i;
  }
  return out;
}

/** True when a published post is inside its window at `now`. */
function isVisible(p, now = Date.now()) {
  return !!p && p.type === 'post' && p.status === 'published' && (!p.startAt || now >= p.startAt) && (!p.endAt || now < p.endAt);
}

/** Pinned first, then the newest (start of its window, else when it was published). */
function boardOrder(a, b) {
  if (!!b.pinned !== !!a.pinned) return b.pinned ? 1 : -1;
  const ta = Number(a.startAt || a.publishedAt || a.createdAt) || 0;
  const tb = Number(b.startAt || b.publishedAt || b.createdAt) || 0;
  return tb - ta;
}

/** "20% off", "₹30 off", "Free month", "Pay ₹19". */
function couponText(c) {
  const v = Number(c.discountValue) || 0;
  if (c.discountType === 'free' || (c.discountType === 'percentage' && v >= 100)) return 'Free month';
  if (c.discountType === 'fixed') return `₹${Math.round(v)} off`;
  if (c.discountType === 'price') return `Pay ₹${Math.round(v)}`;
  return `${Math.round(v * 100) / 100}% off`;
}

/** The coupon chip of a public post: only a coupon that is usable now and public (no allow-list). */
function publicCoupon(coupon, repo, now) {
  if (!coupon) return null;
  const status = typeof repo.computeCouponStatus === 'function' ? repo.computeCouponStatus(coupon, now) : String(coupon.status || '');
  if (status !== 'ACTIVE') return null;
  if (Array.isArray(coupon.allowedUserIds) && coupon.allowedUserIds.length) return null;
  const code = String(coupon.code || '').toUpperCase();
  if (!/^[A-Z0-9_-]{3,32}$/.test(code)) return null;
  return {
    code,
    text: couponText(coupon),
    validUntil: Number(coupon.expiresAt) || null,
    plansUrl: `/plans?coupon=${encodeURIComponent(code)}`,
  };
}

/** A post as the website shows it: whitelisted fields only, all plain values. */
function publicPost(p, coupon) {
  return {
    id: p.postId,
    kind: p.kind,
    kindLabel: KIND_LABELS[p.kind] || 'Update',
    title: p.title,
    body: p.body,
    link: p.link || null,
    linkLabel: p.link ? (p.linkLabel || null) : null,
    image: p.imageId ? { url: `/api/public/board/images/${p.imageId}`, width: p.imageWidth || null, height: p.imageHeight || null } : null,
    coupon: coupon || null,
    pinned: !!p.pinned,
    date: Number(p.startAt || p.publishedAt || p.createdAt) || null,
    endsAt: Number(p.endAt) || null,
  };
}

/** Admin view: everything about the post plus where its image can be previewed. */
function adminPost(p) {
  const { key, type, ...rest } = p;
  void key; void type;
  return { ...rest, id: p.postId, imageUrl: p.imageId ? `/api/admin/board/images/${p.imageId}` : null };
}

function createBoardStore(repo) {
  const soda = repo.soda;
  return {
    async listPosts() {
      const rows = await soda.query(COLL, { type: 'post' }, { limit: LIMITS.maxPosts + 50 });
      return rows.map((r) => r.value);
    },
    async getPost(postId) {
      if (!POST_ID.test(String(postId || ''))) return null;
      const r = await soda.findOne(COLL, { type: 'post', postId: String(postId) });
      return r ? r.value : null;
    },
    async savePost(doc) {
      const d = { ...doc, type: 'post' };
      delete d.key;
      await soda.upsertBy(COLL, { type: 'post', postId: d.postId }, d);
      return d;
    },
    async removePost(postId) { return soda.removeWhere(COLL, { type: 'post', postId: String(postId) }); },
    async getImage(id) {
      if (!reviewPhotos.isPhotoId(String(id || ''))) return null;
      const r = await soda.findOne(COLL, { type: 'image', postId: String(id) });
      return r ? { ...r.value, id: r.value.postId } : null;
    },
    async saveImage(meta) {
      const d = { ...meta, type: 'image', postId: meta.id };
      delete d.id;
      await soda.insert(COLL, d);
      return meta;
    },
    async countImages() { return (await soda.query(COLL, { type: 'image' }, { limit: LIMITS.maxImages + 10 })).length; },
    async removeImage(id) { return soda.removeWhere(COLL, { type: 'image', postId: String(id) }); },
  };
}

/** Public board: the visible posts, cached 60 s per node (an admin write on this node clears it). */
function createBoardReader(repo, store) {
  let cache = null;
  let cacheAt = 0;
  return {
    clear() { cache = null; cacheAt = 0; },
    async visible(now = Date.now()) {
      if (cache && now - cacheAt < CACHE_MS) return cache;
      const posts = (await store.listPosts()).filter((p) => isVisible(p, now)).sort(boardOrder).slice(0, LIMITS.publicMax);
      const out = [];
      for (const p of posts) {
        let coupon = null;
        if (p.couponCode && typeof repo.findCoupon === 'function') coupon = publicCoupon(await repo.findCoupon(p.couponCode).catch(() => null), repo, now);
        out.push(publicPost(p, coupon));
      }
      cache = out;
      cacheAt = now;
      return out;
    },
  };
}

const readers = new WeakMap();
function readerFor(repo) {
  if (!readers.has(repo)) {
    const store = createBoardStore(repo);
    readers.set(repo, { store, reader: createBoardReader(repo, store) });
  }
  return readers.get(repo);
}

/** GET /api/public/board, GET /api/public/board/images/:imageId (before the auth gate). */
function registerBoardPublicRoutes({ r, repo, wrap }) {
  const { store, reader } = readerFor(repo);
  const photos = reviewPhotos.createPhotoStore(config.reviewPhotoDir);
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 120, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests. Try again in a minute.', code: 'RATE_LIMITED' } });
  r.get('/public/board', limiter, wrap(async (req, res) => {
    const kind = typeof req.query.kind === 'string' && KINDS.includes(req.query.kind) ? req.query.kind : null;
    const limit = Math.min(LIMITS.publicMax, Math.max(1, parseInt(req.query.limit, 10) || 20));
    const all = await reader.visible();
    const posts = (kind ? all.filter((p) => p.kind === kind) : all).slice(0, limit);
    res.set('Cache-Control', 'public, max-age=60').set('X-Content-Type-Options', 'nosniff')
      .json({ posts, kinds: KINDS.map((k) => ({ id: k, label: KIND_LABELS[k] })) });
  }));
  r.get('/public/board/images/:imageId', limiter, wrap(async (req, res) => {
    const id = String(req.params.imageId || '');
    const visible = reviewPhotos.isPhotoId(id) && (await reader.visible()).some((p) => p.image && p.image.url.endsWith(`/${id}`));
    const meta = visible ? await store.getImage(id) : null;
    const data = meta ? await photos.read(meta) : null;
    if (!data) return res.status(404).set('Cache-Control', 'no-store').json({ error: 'Not found' });
    res.set({
      'Content-Type': meta.mime, 'Cache-Control': 'public, max-age=300', 'X-Content-Type-Options': 'nosniff',
      'Content-Disposition': 'inline', 'Cross-Origin-Resource-Policy': 'same-origin', 'Content-Security-Policy': "default-src 'none'; sandbox",
    }).send(data);
  }));
}

/** Admin board routes (behind the auth gate; MASTER_ADMIN via requireAdmin). */
function registerBoardAdminRoutes({ r, repo, wrap, requireAdmin }) {
  const { store, reader } = readerFor(repo);
  const photos = reviewPhotos.createPhotoStore(config.reviewPhotoDir);
  const writeLimit = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `board:${req.user ? req.user.userId : req.ip}`, message: { error: 'Too many changes. Try again in a minute.', code: 'RATE_LIMITED' } });
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  const audit = async (req, action, target, details) => {
    if (typeof repo.addAuditEntry !== 'function') return;
    await repo.addAuditEntry({ by: by(req), byUserId: req.user ? req.user.userId : null, action, target, details, at: Date.now() }).catch(() => {});
  };
  const fail = (res, e) => {
    if (e instanceof BoardError) return res.status(e.status).json({ error: e.message, code: e.code, field: e.field });
    throw e;
  };
  /** Coupon and image references of a post: a new coupon must be usable or scheduled; the image must exist. */
  const checkRefs = async (fields, prev) => {
    if (fields.couponCode && fields.couponCode !== (prev && prev.couponCode)) {
      const c = typeof repo.findCoupon === 'function' ? await repo.findCoupon(fields.couponCode) : null;
      if (!c || !['ACTIVE', 'SCHEDULED'].includes(c.status)) throw new BoardError('Choose an active or scheduled coupon.', 'couponCode');
    }
    if (fields.imageId && fields.imageId !== (prev && prev.imageId)) {
      const img = await store.getImage(fields.imageId);
      if (!img) throw new BoardError('That image is not uploaded.', 'imageId');
      fields.imageWidth = img.width || null;
      fields.imageHeight = img.height || null;
    }
  };

  r.get('/admin/board', requireAdmin, wrap(async (req, res) => {
    const posts = (await store.listPosts()).sort((a, b) => (Number(b.updatedAt) || 0) - (Number(a.updatedAt) || 0));
    const now = Date.now();
    res.set('Cache-Control', 'no-store').json({
      posts: posts.map((p) => ({ ...adminPost(p), visibleNow: isVisible(p, now) })),
      kinds: KINDS.map((k) => ({ id: k, label: KIND_LABELS[k] })),
      limits: LIMITS,
    });
  }));

  r.post('/admin/board', requireAdmin, writeLimit, wrap(async (req, res) => {
    let fields;
    try { fields = cleanPost(req.body); await checkRefs(fields, null); } catch (e) { return fail(res, e); }
    if ((await store.listPosts()).length >= LIMITS.maxPosts) return res.status(409).json({ error: `At most ${LIMITS.maxPosts} posts. Delete old ones first.`, code: 'TOO_MANY_POSTS' });
    const now = Date.now();
    const doc = {
      ...fields, postId: `bp_${crypto.randomBytes(10).toString('hex')}`,
      publishedAt: fields.status === 'published' ? now : null,
      createdAt: now, createdBy: by(req), updatedAt: now, updatedBy: by(req),
    };
    await store.savePost(doc);
    reader.clear();
    await audit(req, 'board.create', doc.postId, { title: doc.title, kind: doc.kind, status: doc.status, couponCode: doc.couponCode });
    res.status(201).set('Cache-Control', 'no-store').json({ post: adminPost(doc) });
  }));

  r.patch('/admin/board/:postId', requireAdmin, writeLimit, wrap(async (req, res) => {
    const prev = await store.getPost(req.params.postId);
    if (!prev) return res.status(404).json({ error: 'Post not found.', code: 'NOT_FOUND' });
    const base = req.body && Number(req.body.baseUpdatedAt);
    if (base && Number(prev.updatedAt) !== base) return res.status(409).json({ error: 'Someone else saved this post meanwhile. Reload it first.', code: 'CONFLICT' });
    let fields;
    try { fields = cleanPost(req.body, prev); await checkRefs(fields, prev); } catch (e) { return fail(res, e); }
    const now = Date.now();
    const doc = { ...prev, ...fields, updatedAt: Math.max(now, (Number(prev.updatedAt) || 0) + 1), updatedBy: by(req) };
    if (doc.status === 'published' && !prev.publishedAt) doc.publishedAt = now;
    await store.savePost(doc);
    reader.clear();
    const action = fields.status && fields.status !== prev.status ? (fields.status === 'published' ? 'board.publish' : fields.status === 'archived' ? 'board.archive' : 'board.unpublish') : 'board.update';
    await audit(req, action, doc.postId, { title: doc.title, changed: Object.keys(fields) });
    res.set('Cache-Control', 'no-store').json({ post: adminPost(doc) });
  }));

  r.delete('/admin/board/:postId', requireAdmin, writeLimit, wrap(async (req, res) => {
    const prev = await store.getPost(req.params.postId);
    if (!prev) return res.status(404).json({ error: 'Post not found.', code: 'NOT_FOUND' });
    await store.removePost(prev.postId);
    reader.clear();
    // The image goes too when no other post uses it.
    if (prev.imageId && !(await store.listPosts()).some((p) => p.imageId === prev.imageId)) {
      const meta = await store.getImage(prev.imageId);
      if (meta) { await photos.remove(meta).catch(() => {}); await store.removeImage(meta.id); }
    }
    await audit(req, 'board.delete', prev.postId, { title: prev.title });
    res.json({ ok: true, id: prev.postId });
  }));

  const rawImage = express.raw({ type: () => true, limit: reviewPhotos.MAX_BYTES });
  r.post('/admin/board/images', requireAdmin, writeLimit, (req, res, next) => {
    if (req.is('application/json') || req.is('multipart/form-data')) {
      return res.status(415).json({ error: 'Send the image bytes as image/jpeg, image/png or image/webp.', code: 'UNSUPPORTED_PHOTO' });
    }
    rawImage(req, res, (err) => {
      if (!err) return next();
      if (err.type === 'entity.too.large') return res.status(413).json({ error: 'This image is too large (up to 2 MB).', code: 'PHOTO_TOO_LARGE' });
      return res.status(400).json({ error: 'The image did not arrive complete. Please try again.', code: 'NO_PHOTO' });
    });
  }, wrap(async (req, res) => {
    let prepared;
    try { prepared = reviewPhotos.preparePhoto(req.body); } catch (e) {
      if (!(e instanceof reviewPhotos.PhotoError)) throw e;
      return res.status(e.status).json({ error: e.message, code: e.code });
    }
    if ((await store.countImages()) >= LIMITS.maxImages) return res.status(409).json({ error: `At most ${LIMITS.maxImages} images. Delete old posts first.`, code: 'TOO_MANY_IMAGES' });
    const meta = await photos.save(prepared);
    const doc = { id: meta.id, mime: meta.mime, ext: meta.ext, bytes: meta.bytes, width: meta.width, height: meta.height, at: Date.now(), by: by(req) };
    await store.saveImage(doc);
    await audit(req, 'board.image.upload', doc.id, { bytes: doc.bytes, mime: doc.mime });
    res.status(201).json({ image: { id: doc.id, mime: doc.mime, width: doc.width, height: doc.height, bytes: doc.bytes, url: `/api/admin/board/images/${doc.id}` } });
  }));

  r.get('/admin/board/images/:imageId', requireAdmin, wrap(async (req, res) => {
    const meta = await store.getImage(String(req.params.imageId || ''));
    const data = meta ? await photos.read(meta) : null;
    if (!data) return res.status(404).json({ error: 'Image not found.', code: 'NOT_FOUND' });
    res.set({ 'Content-Type': meta.mime, 'Cache-Control': 'private, max-age=3600', 'X-Content-Type-Options': 'nosniff' }).send(data);
  }));

  r.get('/admin/board/coupons', requireAdmin, wrap(async (req, res) => {
    const list = typeof repo.listCoupons === 'function' ? await repo.listCoupons(500) : [];
    const coupons = list.filter((c) => ['ACTIVE', 'SCHEDULED'].includes(c.status)).map((c) => ({
      code: c.code, name: c.name || c.code, status: c.status, text: couponText(c),
      validFrom: Number(c.validFrom) || null, expiresAt: Number(c.expiresAt) || null,
      private: Array.isArray(c.allowedUserIds) && c.allowedUserIds.length > 0,
    }));
    res.set('Cache-Control', 'no-store').json({ coupons });
  }));
}

module.exports = {
  KINDS, KIND_LABELS, STATUSES, LIMITS, BoardError, cleanPost, cleanLink, plainText, oneLine, isVisible, boardOrder,
  couponText, publicCoupon, publicPost, createBoardStore, registerBoardPublicRoutes, registerBoardAdminRoutes, readerFor,
};
