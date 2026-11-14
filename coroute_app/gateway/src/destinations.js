'use strict';
/**
 * v3.58 curated destinations for the app's Explore tab ("Rides near you").
 *
 * An admin-managed list of places riders ride to: name, region, coordinates, category, extra tags, a short
 * description, an optional photo the ADMIN uploads, and an active switch. No distances are stored: the app works
 * out "~65 km, 1.5 h" from the rider's own position on the phone, so the rider's location never reaches us here.
 *
 *   GET    /api/public/destinations                    active places, admin order (cached 60 s per node, ETag)
 *   GET    /api/public/destinations/:id/photo          the photo of an active place (404 otherwise)
 *   GET    /api/admin/destinations                     every place, inactive too (MASTER_ADMIN)
 *   POST   /api/admin/destinations                     create
 *   PATCH  /api/admin/destinations/:id                 change any field
 *   DELETE /api/admin/destinations/:id                 delete (its photo too)
 *   POST   /api/admin/destinations/:id/photo           raw JPEG / PNG / WebP bytes (review photo pipeline: magic bytes,
 *                                                      2 MB, EXIF / GPS stripped; disk or Object Storage)
 *   DELETE /api/admin/destinations/:id/photo           remove the photo (the app draws its gradient card)
 *
 * Photos come only from the admin. Third-party image URLs are never stored or served.
 * First read on an empty store seeds 10 well-known South India destinations (name, coordinates, category only;
 * no photos, no copied descriptions). A "seeded" marker keeps an admin's deletions from coming back.
 * DESTINATIONS_ENABLED=0 answers an empty list (the app then shows its empty state).
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const reviewPhotos = require('./review_photos');

const COLL = 'destinations';
const CACHE_MS = 60 * 1000;
const ID_RE = /^ds_[a-f0-9]{12}$/;
const CATEGORIES = Object.freeze(['breakfast', 'night', 'one_day', 'weekend', 'twisty', 'ghats']);
const LIMITS = Object.freeze({ nameMax: 60, regionMax: 40, descriptionMax: 160, tagsMax: 3, maxPlaces: 200 });

/** Names, coordinates and categories only (owner: photos come from the admin, nothing else is copied). */
const SEED = Object.freeze([
  { name: 'Nandi Hills', region: 'Karnataka', lat: 13.3702, lng: 77.6835, category: 'breakfast', tags: ['twisty'] },
  { name: 'Savandurga', region: 'Karnataka', lat: 12.9196, lng: 77.2929, category: 'breakfast', tags: [] },
  { name: 'Lepakshi', region: 'Andhra Pradesh', lat: 13.8037, lng: 77.6087, category: 'one_day', tags: [] },
  { name: 'Mysuru Palace', region: 'Karnataka', lat: 12.3052, lng: 76.6552, category: 'night', tags: ['one_day'] },
  { name: 'Horsley Hills', region: 'Andhra Pradesh', lat: 13.66, lng: 78.399, category: 'one_day', tags: ['twisty'] },
  { name: 'Yercaud', region: 'Tamil Nadu', lat: 11.7753, lng: 78.2093, category: 'one_day', tags: ['ghats', 'twisty'] },
  { name: 'Madikeri, Coorg', region: 'Karnataka', lat: 12.4244, lng: 75.7382, category: 'weekend', tags: ['ghats'] },
  { name: 'Mullayanagiri, Chikkamagaluru', region: 'Karnataka', lat: 13.3907, lng: 75.7208, category: 'weekend', tags: ['twisty', 'ghats'] },
  { name: 'Ooty', region: 'Tamil Nadu', lat: 11.4102, lng: 76.695, category: 'weekend', tags: ['ghats', 'twisty'] },
  { name: 'Munnar', region: 'Kerala', lat: 10.0889, lng: 77.0595, category: 'weekend', tags: ['ghats', 'twisty'] },
]);

class DestinationError extends Error {
  constructor(message, field, status = 400, code = 'INVALID') { super(message); this.name = 'DestinationError'; this.field = field; this.status = status; this.code = code; }
}

const newId = () => `ds_${crypto.randomBytes(6).toString('hex')}`;
const isId = (v) => typeof v === 'string' && ID_RE.test(v);

/** Plain text: control characters out, whitespace collapsed. */
function cleanText(v, max, field, { required = false } = {}) {
  if (v == null) v = '';
  if (typeof v !== 'string') throw new DestinationError(`${field} must be text.`, field);
  // eslint-disable-next-line no-control-regex
  const s = v.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  if (required && s.length < 2) throw new DestinationError(`${field} needs at least 2 characters.`, field);
  if (s.length > max) throw new DestinationError(`${field} can have at most ${max} characters.`, field);
  return s;
}

function cleanCoord(v, lim, field) {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isFinite(n) || Math.abs(n) > lim) throw new DestinationError(`${field} must be a number between -${lim} and ${lim}.`, field);
  return Math.round(n * 1e5) / 1e5;
}

/**
 * The fields of a create (prev = null: name, lat, lng and category required) or a change (prev = the stored
 * place: only the fields present are checked). Throws DestinationError.
 */
function cleanFields(body, prev = null) {
  const b = body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  const has = (k) => Object.prototype.hasOwnProperty.call(b, k);
  const out = {};
  if (!prev || has('name')) out.name = cleanText(b.name, LIMITS.nameMax, 'name', { required: true });
  if (!prev || has('region')) out.region = cleanText(b.region, LIMITS.regionMax, 'region');
  if (!prev || has('lat')) out.lat = cleanCoord(b.lat, 90, 'lat');
  if (!prev || has('lng')) out.lng = cleanCoord(b.lng, 180, 'lng');
  if (!prev || has('category')) {
    if (!CATEGORIES.includes(b.category)) throw new DestinationError(`category must be one of ${CATEGORIES.join(', ')}.`, 'category');
    out.category = b.category;
  }
  if (!prev || has('tags')) {
    const t = b.tags == null ? [] : b.tags;
    if (!Array.isArray(t) || t.some((x) => !CATEGORIES.includes(x))) throw new DestinationError(`tags must be a list of ${CATEGORIES.join(', ')}.`, 'tags');
    const cat = out.category || (prev && prev.category);
    out.tags = [...new Set(t)].filter((x) => x !== cat).slice(0, LIMITS.tagsMax);
  }
  if (!prev || has('description')) out.description = cleanText(b.description, LIMITS.descriptionMax, 'description');
  if (!prev || has('active')) {
    if (b.active != null && typeof b.active !== 'boolean') throw new DestinationError('active must be true or false.', 'active');
    out.active = b.active !== false;
  }
  if (!prev || has('order')) {
    const o = b.order == null ? 0 : Number(b.order);
    if (!Number.isInteger(o) || o < 0 || o > 10000) throw new DestinationError('order must be a whole number from 0 to 10000.', 'order');
    out.order = o;
  }
  if (prev && !Object.keys(out).length) throw new DestinationError('Nothing to change.', null);
  return out;
}

const photoUrlOf = (d) => (d.photo && reviewPhotos.isPhotoId(d.photo.id) ? `/api/public/destinations/${d.destId}/photo?v=${d.photo.id.slice(-8)}` : null);
const byOrder = (a, b) => (a.order || 0) - (b.order || 0) || (a.createdAt || 0) - (b.createdAt || 0) || a.name.localeCompare(b.name);

/** What the app sees: no admin names, no storage details. */
function publicView(d) {
  return { id: d.destId, name: d.name, region: d.region || '', lat: d.lat, lng: d.lng, category: d.category, tags: d.tags || [], description: d.description || '', photoUrl: photoUrlOf(d) };
}
function adminView(d) {
  return { ...publicView(d), active: d.active !== false, order: d.order || 0, createdAt: d.createdAt || 0, updatedAt: d.updatedAt || 0, by: d.by || null,
    photo: d.photo ? { width: d.photo.width || null, height: d.photo.height || null, bytes: d.photo.bytes || 0, url: `/api/admin/destinations/${d.destId}/photo` } : null };
}

function createStore(repo) {
  const soda = repo.soda;
  let ready = null;
  const ensure = () => (ready ||= (async () => {
    await soda.ensureCollection(COLL);
    await soda.ensureIndex(COLL, { name: 'destinations_id_ux', unique: true, fields: [{ path: 'destId' }] }).catch(() => {});
  })());
  const store = {
    async list() {
      await ensure();
      return (await soda.query(COLL, { type: 'dest' }, { limit: LIMITS.maxPlaces + 20 })).map((r) => r.value).sort(byOrder);
    },
    async get(id) {
      if (!isId(id)) return null;
      await ensure();
      const r = await soda.findOne(COLL, { type: 'dest', destId: id });
      return r ? r.value : null;
    },
    async save(doc) {
      await ensure();
      const d = { ...doc, type: 'dest' };
      delete d.key;
      await soda.upsertBy(COLL, { type: 'dest', destId: d.destId }, d);
      return d;
    },
    async remove(id) { await ensure(); return soda.removeWhere(COLL, { type: 'dest', destId: id }); },
    /** Seeds the starter list once per database (the marker survives an admin deleting every place). */
    async seedOnce(now = Date.now()) {
      await ensure();
      if (await soda.findOne(COLL, { type: 'meta', id: 'seeded' })) return false;
      await soda.upsertBy(COLL, { type: 'meta', id: 'seeded' }, { type: 'meta', id: 'seeded', at: now });
      if ((await soda.query(COLL, { type: 'dest' }, { limit: 1 })).length) return false;
      let order = 0;
      for (const s of SEED) {
        await store.save({ destId: newId(), ...cleanFields(s), order: (order += 10), createdAt: now, updatedAt: now, by: 'seed', photo: null });
      }
      return true;
    },
  };
  return store;
}

/** The public list, cached CACHE_MS per node; an admin write on this node clears it at once. */
function createReader(store, { enabled = () => config.destinationsEnabled !== false } = {}) {
  let cache = null;
  return {
    clear() { cache = null; },
    async visible(now = Date.now()) {
      if (!enabled()) return { list: [], etag: '"off"' };
      if (cache && now - cache.at < CACHE_MS) return cache;
      await store.seedOnce(now).catch(() => false);
      const list = (await store.list()).filter((d) => d.active !== false).map(publicView);
      const etag = `"${crypto.createHash('sha1').update(JSON.stringify(list)).digest('hex').slice(0, 16)}"`;
      cache = { list, etag, at: now };
      return cache;
    },
  };
}

const states = new WeakMap();
function stateFor(repo) {
  if (!states.has(repo)) {
    const store = createStore(repo);
    states.set(repo, { store, reader: createReader(store) });
  }
  return states.get(repo);
}

/** GET /api/public/destinations and the photo route (registered before the auth gate). */
function registerDestinationPublicRoutes({ r, repo, wrap }) {
  const { store, reader } = stateFor(repo);
  const photos = reviewPhotos.createPhotoStore(config.reviewPhotoDir);
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 120, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests. Try again in a minute.', code: 'RATE_LIMITED' } });
  r.get('/public/destinations', limiter, wrap(async (req, res) => {
    const v = await reader.visible();
    res.set({ 'Cache-Control': 'public, max-age=300', ETag: v.etag, 'X-Content-Type-Options': 'nosniff' });
    if (req.headers['if-none-match'] === v.etag) return res.status(304).end();
    res.json({ destinations: v.list, categories: CATEGORIES, distance: 'Worked out on your phone from your own position.' });
  }));
  r.get('/public/destinations/:id/photo', limiter, wrap(async (req, res) => {
    const d = await store.get(String(req.params.id || ''));
    const enabled = config.destinationsEnabled !== false;
    const data = enabled && d && d.active !== false && d.photo ? await photos.read(d.photo) : null;
    if (!data) return res.status(404).set('Cache-Control', 'no-store').json({ error: 'Not found' });
    res.set({
      'Content-Type': d.photo.mime, 'Cache-Control': 'public, max-age=86400', 'X-Content-Type-Options': 'nosniff',
      'Content-Disposition': 'inline', 'Cross-Origin-Resource-Policy': 'same-origin', 'Content-Security-Policy': "default-src 'none'; sandbox",
    }).send(data);
  }));
}

/** Admin CRUD + photo (behind the auth gate; MASTER_ADMIN via requireAdmin). */
function registerDestinationAdminRoutes({ r, repo, wrap, requireAdmin }) {
  const { store, reader } = stateFor(repo);
  const photos = reviewPhotos.createPhotoStore(config.reviewPhotoDir);
  const writeLimit = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `dest:${req.user ? req.user.userId : req.ip}`, message: { error: 'Too many changes. Try again in a minute.', code: 'RATE_LIMITED' } });
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  const audit = async (req, action, target, details) => {
    if (typeof repo.addAuditEntry !== 'function') return;
    await repo.addAuditEntry({ by: by(req), byUserId: req.user ? req.user.userId : null, action, target, details, at: Date.now() }).catch(() => {});
  };
  const fail = (res, e) => {
    if (e instanceof DestinationError) return res.status(e.status).json({ error: e.message, code: e.code, field: e.field });
    throw e;
  };
  const notFound = (res) => res.status(404).json({ error: 'Destination not found.', code: 'NOT_FOUND' });

  r.get('/admin/destinations', requireAdmin, wrap(async (req, res) => {
    await store.seedOnce().catch(() => false);
    res.set('Cache-Control', 'no-store').json({ destinations: (await store.list()).map(adminView), categories: CATEGORIES, limits: LIMITS, enabled: config.destinationsEnabled !== false });
  }));
  r.post('/admin/destinations', requireAdmin, writeLimit, wrap(async (req, res) => {
    let fields;
    try { fields = cleanFields(req.body); } catch (e) { return fail(res, e); }
    if ((await store.list()).length >= LIMITS.maxPlaces) return res.status(409).json({ error: `At most ${LIMITS.maxPlaces} destinations.`, code: 'TOO_MANY' });
    const now = Date.now();
    const doc = await store.save({ destId: newId(), ...fields, createdAt: now, updatedAt: now, by: by(req), photo: null });
    reader.clear();
    await audit(req, 'destination.create', doc.destId, { name: doc.name, category: doc.category });
    res.status(201).json({ destination: adminView(doc) });
  }));
  r.patch('/admin/destinations/:id', requireAdmin, writeLimit, wrap(async (req, res) => {
    const prev = await store.get(String(req.params.id || ''));
    if (!prev) return notFound(res);
    let fields;
    try { fields = cleanFields(req.body, prev); } catch (e) { return fail(res, e); }
    const doc = await store.save({ ...prev, ...fields, updatedAt: Date.now(), by: by(req) });
    reader.clear();
    await audit(req, 'destination.update', doc.destId, { fields: Object.keys(fields) });
    res.json({ destination: adminView(doc) });
  }));
  r.delete('/admin/destinations/:id', requireAdmin, writeLimit, wrap(async (req, res) => {
    const prev = await store.get(String(req.params.id || ''));
    if (!prev) return notFound(res);
    if (prev.photo) await photos.remove(prev.photo).catch(() => {});
    await store.remove(prev.destId);
    reader.clear();
    await audit(req, 'destination.delete', prev.destId, { name: prev.name });
    res.json({ ok: true });
  }));

  const rawImage = express.raw({ type: () => true, limit: reviewPhotos.MAX_BYTES });
  r.post('/admin/destinations/:id/photo', requireAdmin, writeLimit, (req, res, next) => {
    if (req.is('application/json') || req.is('multipart/form-data')) {
      return res.status(415).json({ error: 'Send the image bytes as image/jpeg, image/png or image/webp.', code: 'UNSUPPORTED_PHOTO' });
    }
    rawImage(req, res, (err) => {
      if (!err) return next();
      if (err.type === 'entity.too.large') return res.status(413).json({ error: 'This image is too large (up to 2 MB).', code: 'PHOTO_TOO_LARGE' });
      return res.status(400).json({ error: 'The image did not arrive complete. Please try again.', code: 'NO_PHOTO' });
    });
  }, wrap(async (req, res) => {
    const prev = await store.get(String(req.params.id || ''));
    if (!prev) return notFound(res);
    let prepared;
    try { prepared = reviewPhotos.preparePhoto(req.body); } catch (e) {
      if (!(e instanceof reviewPhotos.PhotoError)) throw e;
      return res.status(e.status).json({ error: e.message, code: e.code });
    }
    const meta = await photos.save(prepared);
    const doc = await store.save({ ...prev, photo: { id: meta.id, mime: meta.mime, ext: meta.ext, bytes: meta.bytes, width: meta.width, height: meta.height }, updatedAt: Date.now(), by: by(req) });
    if (prev.photo) await photos.remove(prev.photo).catch(() => {});
    reader.clear();
    await audit(req, 'destination.photo', doc.destId, { bytes: meta.bytes, mime: meta.mime });
    res.status(201).json({ destination: adminView(doc) });
  }));
  r.get('/admin/destinations/:id/photo', requireAdmin, wrap(async (req, res) => {
    const d = await store.get(String(req.params.id || ''));
    const data = d && d.photo ? await photos.read(d.photo) : null;
    if (!data) return res.status(404).json({ error: 'Photo not found.', code: 'NOT_FOUND' });
    res.set({ 'Content-Type': d.photo.mime, 'Cache-Control': 'private, max-age=3600', 'X-Content-Type-Options': 'nosniff' }).send(data);
  }));
  r.delete('/admin/destinations/:id/photo', requireAdmin, writeLimit, wrap(async (req, res) => {
    const prev = await store.get(String(req.params.id || ''));
    if (!prev) return notFound(res);
    if (prev.photo) await photos.remove(prev.photo).catch(() => {});
    const doc = await store.save({ ...prev, photo: null, updatedAt: Date.now(), by: by(req) });
    reader.clear();
    await audit(req, 'destination.photo.remove', doc.destId, {});
    res.json({ destination: adminView(doc) });
  }));
}

module.exports = {
  COLL, CATEGORIES, LIMITS, SEED, DestinationError, cleanFields, publicView, isId,
  registerDestinationPublicRoutes, registerDestinationAdminRoutes,
};
