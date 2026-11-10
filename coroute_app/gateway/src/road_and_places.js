'use strict';
/**
 * 3.55: what riders leave behind for the riders who come after them.
 *
 *  - Road reports: potholes, speed breakers and rough stretches felt by a group's lead (FEAT-02
 *    ROAD_HAZARD) are saved without any rider id and served to later rides along their route:
 *      GET /api/road-hazards/near?groupId=...   (the ride's planned route, 120 m either side)
 *      GET /api/road-hazards/near?lat=&lng=     (10 km around a point, no route)
 *      POST /api/road-hazards/:hazardId/clear   ("it is fixed / not there")
 *    A report expires on its own (pothole 45 days, rough road 30, speed breaker a year), renewed
 *    by every new report of the same spot.
 *
 *  - CoRoute rider place reviews: a rider who spent a while at a restaurant, stay or any place is
 *    asked (politely, once) to rate it for the next riders. Shown in the place card with a rating
 *    and photos:
 *      POST /api/places/reviews            { placeId, placeName, category, lat, lng, rating, text, dwellMin, chips? }
 *      POST /api/places/reviews/:id/photo   (image bytes, up to 2 MB; shown after an admin check)
 *      GET  /api/places/reviews?placeId=    { summary: { avg, count }, reviews: [...] }
 *      GET  /api/places/review-summary?s=&w=&n=&e=   per-place averages for the map
 *      GET  /api/places/reviews/:id/photo/:photoId    an approved photo
 *      admin: GET /api/admin/place-reviews, PUT /api/admin/place-reviews/:id { action }
 *    Text uses the public ride text rules (no links, numbers or handles). One review per rider and
 *    place (a new one replaces it). A first name only is shown, never the account.
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { decodePolyline, pointToSegment } = require('./geo_math');
const reviewPhotos = require('./review_photos');
const { cleanText } = require('./public_ride');

const DAY = 86400000;
const KINDS = Object.freeze(['POTHOLE', 'SPEED_BREAKER', 'ROUGH_ROAD', 'SEVERE_RIDGE', 'TRANSVERSE_JOINT', 'UNCERTAIN_SURFACE_ANOMALY']);
const TTL_DAYS = Object.freeze({ POTHOLE: 45, SEVERE_RIDGE: 45, ROUGH_ROAD: 30, SPEED_BREAKER: 365, TRANSVERSE_JOINT: 90, UNCERTAIN_SURFACE_ANOMALY: 14 });
const SEVERITIES = Object.freeze(['LOW', 'MEDIUM', 'HIGH', 'CRITICAL']);
const PLACE_CATEGORIES = Object.freeze(['food', 'stay', 'fuel', 'ev', 'mechanic', 'hospital', 'pharmacy', 'police', 'atm', 'toilet', 'viewpoint', 'heritage', 'other']);
const PLACE_ID = /^[a-zA-Z0-9:_-]{1,80}$/;
const REVIEW_ID = /^pr_[a-f0-9]{24}$/;
const ROUTE_SIDE_M = 120;

/** The spoken line for a road report (by kind), used by the live broadcast too. */
function spokenWarningFor(classification) {
  switch (String(classification || '').toUpperCase()) {
    case 'SPEED_BREAKER': return 'Caution: speed breaker 300 meters ahead';
    case 'ROUGH_ROAD': return 'Caution: rough road 300 meters ahead';
    case 'POTHOLE': return 'Caution: pothole 300 meters ahead';
    default: return 'Caution: severe road hazard 300 meters ahead';
  }
}

/** A salted, one-way key per reporter so separate reports are counted without storing who sent them. */
function reporterKeyOf(userId) {
  if (!userId) return '';
  return crypto.createHmac('sha256', String(config.jwtSecret || 'coroute')).update(`road:${userId}`).digest('hex').slice(0, 16);
}

/** The record saved for a live road report (no rider ids). */
function roadRecordOf(pin, now = Date.now()) {
  const kind = KINDS.includes(String(pin.classification || '').toUpperCase()) ? String(pin.classification).toUpperCase() : 'UNCERTAIN_SURFACE_ANOMALY';
  return {
    hazardId: String(pin.hazardId || `rh_${now}`).slice(0, 64),
    lat: Math.round(Number(pin.lat) * 1e5) / 1e5,
    lng: Math.round(Number(pin.lng) * 1e5) / 1e5,
    heading: Math.round(Number(pin.heading) || 0),
    severity: SEVERITIES.includes(String(pin.severity || '').toUpperCase()) ? String(pin.severity).toUpperCase() : 'MEDIUM',
    classification: kind,
    expiresAt: now + (TTL_DAYS[kind] || 30) * DAY,
  };
}

/** What a rider gets for a saved report. */
function publicRoad(h) {
  return {
    hazardId: h.hazardId, lat: h.lat, lng: h.lng, heading: h.heading || 0, severity: h.severity, classification: h.classification,
    corroborationCount: Number(h.reports) || 1, reportedAt: Number(h.lastReportedAt) || 0, expiresAt: Number(h.expiresAt) || 0,
    fromHistory: true, spokenWarning: spokenWarningFor(h.classification),
  };
}

function bboxAround(lat, lng, km) {
  const dLat = km / 111.32;
  const dLng = km / (111.32 * Math.max(0.2, Math.cos((lat * Math.PI) / 180)));
  return { s: lat - dLat, n: lat + dLat, w: lng - dLng, e: lng + dLng };
}

function bboxOfLine(line, padM) {
  let s = 90, n = -90, w = 180, e = -180;
  for (const p of line) { s = Math.min(s, p.lat); n = Math.max(n, p.lat); w = Math.min(w, p.lng); e = Math.max(e, p.lng); }
  const pad = padM / 111320;
  const padLng = padM / (111320 * Math.max(0.2, Math.cos((((s + n) / 2) * Math.PI) / 180)));
  return { s: s - pad, n: n + pad, w: w - padLng, e: e + padLng };
}

/** Saved reports within ROUTE_SIDE_M of the route line (checked segment by segment). */
function nearLine(list, line) {
  return list.filter((h) => {
    for (let i = 0; i < line.length - 1; i++) {
      if (pointToSegment({ lat: h.lat, lng: h.lng }, line[i], line[i + 1]).dist <= ROUTE_SIDE_M) return true;
    }
    return false;
  });
}

function firstName(name) {
  const f = String(name || '').trim().split(/\s+/)[0] || 'Rider';
  return f.slice(0, 20);
}

function reviewView(r, { mine = false } = {}) {
  const approved = (Array.isArray(r.uploads) ? r.uploads : []).filter((u) => u && u.approved === true);
  return {
    reviewId: r.reviewId, placeId: r.placeId, placeName: r.placeName, category: r.category, rating: r.rating, text: r.text || '',
    chips: Array.isArray(r.chips) ? r.chips : [],
    firstName: firstName(r.userName), createdAt: r.createdAt, dwellMin: r.dwellMin || 0,
    photos: approved.map((u) => `/api/places/reviews/${r.reviewId}/photo/${u.id}`),
    ...(mine ? { photosPending: (Array.isArray(r.uploads) ? r.uploads : []).filter((u) => u && u.approved !== true).length, status: r.status } : {}),
  };
}

function summaryOf(list) {
  const ratings = list.map((r) => Number(r.rating)).filter((x) => x >= 1 && x <= 5);
  return { count: ratings.length, avg: ratings.length ? Math.round((ratings.reduce((a, b) => a + b, 0) / ratings.length) * 10) / 10 : null };
}

function registerRoadAndPlaceRoutes({ r, repo, convoys, wrap, requireAdmin }) {
  const photoStore = reviewPhotos.createPhotoStore(config.reviewPhotoDir);
  const limit = (windowMs, n) => rateLimit({ windowMs, limit: n, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => req.user?.userId || req.ip, validate: false, message: { error: 'Too many requests. Try again later.', code: 'RATE_LIMITED' } });
  const readLimiter = limit(60 * 1000, 120);
  const reviewLimiter = limit(24 * 60 * 60 * 1000, 30);
  const photoLimiter = limit(60 * 60 * 1000, 20);
  const clearLimiter = limit(60 * 60 * 1000, 30);

  // ---------------- road reports ----------------
  r.get('/road-hazards/near', readLimiter, wrap(async (req, res) => {
    const now = Date.now();
    const gid = String(req.query.groupId || '').slice(0, 64);
    let list = [];
    if (gid) {
      const room = convoys && convoys.rooms ? convoys.rooms.get(gid) : null;
      const meta = room ? room.meta : await repo.getConvoyMeta(gid).catch(() => null);
      if (!meta) return res.status(404).json({ error: 'Ride not found.', code: 'NOT_FOUND' });
      const member = (room && room.riders.has(req.user.userId)) || (meta.members && meta.members[req.user.userId]);
      if (!member) return res.status(403).json({ error: 'Not a member of this ride.', code: 'NOT_MEMBER' });
      const poly = meta.route && meta.route.polyline;
      const line = typeof poly === 'string' && poly ? decodePolyline(poly, 20000) : null;
      if (line && line.length >= 2) {
        list = nearLine(await repo.roadHazardsIn(bboxOfLine(line, ROUTE_SIDE_M), { now, limit: 1500 }), line);
      } else if (meta.destinationLat || meta.destinationLng) {
        const s = meta.start || {};
        const pts = [s.lat ? { lat: s.lat, lng: s.lng } : null, { lat: meta.destinationLat, lng: meta.destinationLng }].filter(Boolean);
        if (pts.length === 2) list = nearLine(await repo.roadHazardsIn(bboxOfLine(pts, 3000), { now, limit: 1500 }), pts);
      }
    } else {
      const lat = Number(req.query.lat), lng = Number(req.query.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 85 || Math.abs(lng) > 180) {
        return res.status(400).json({ error: 'Send groupId, or lat and lng.', code: 'BAD_REQUEST' });
      }
      list = await repo.roadHazardsIn(bboxAround(lat, lng, 10), { now, limit: 500 });
    }
    res.set('Cache-Control', 'private, max-age=60').json({ ok: true, hazards: list.slice(0, 500).map(publicRoad) });
  }));

  r.post('/road-hazards/:hazardId/clear', clearLimiter, wrap(async (req, res) => {
    const id = String(req.params.hazardId || '');
    if (!/^[\w:-]{1,64}$/.test(id)) return res.status(400).json({ error: 'Unknown report.', code: 'BAD_REQUEST' });
    // One vote per rider (salted key, no rider id stored).
    const out = await repo.clearRoadHazard(id, { clearerKey: reporterKeyOf(req.user.userId) });
    if (!out) return res.status(404).json({ error: 'Unknown report.', code: 'NOT_FOUND' });
    res.json({ ok: true, removed: Number(out.expiresAt) <= Date.now() });
  }));

  // ---------------- place reviews ----------------
  r.post('/places/reviews', reviewLimiter, wrap(async (req, res) => {
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    const placeId = String(b.placeId || '');
    const rating = Number(b.rating);
    const lat = Number(b.lat), lng = Number(b.lng);
    const bad = (error, code = 'BAD_REQUEST') => res.status(400).json({ error, code });
    if (!PLACE_ID.test(placeId)) return bad('Unknown place.');
    if (!Number.isInteger(rating) || rating < 1 || rating > 5) return bad('Pick 1 to 5 stars.', 'BAD_RATING');
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 85 || Math.abs(lng) > 180) return bad('The place has no position.');
    const t = cleanText(typeof b.text === 'string' ? b.text.slice(0, 600) : '', 300);
    if (!t.ok) {
      const why = { TOO_LONG: 'Keep it under 300 characters.', LINK: 'Links, e-mail addresses and handles are not allowed.', NUMBER: 'Phone numbers are not allowed.' }[t.reason] || 'Please change the wording.';
      return bad(why, `TEXT_${t.reason}`);
    }
    const name = String(b.placeName || '').replace(/[\u0000-\u001F\u007F]/g, ' ').trim().slice(0, 80);
    const category = PLACE_CATEGORIES.includes(String(b.category || '').toLowerCase()) ? String(b.category).toLowerCase() : 'other';
    const now = Date.now();
    const user = req.dbUser || (await repo.findUserById(req.user.userId));
    const prev = await repo.findPlaceReviewBy(req.user.userId, placeId);
    const doc = {
      reviewId: prev ? prev.reviewId : `pr_${crypto.randomBytes(12).toString('hex')}`,
      placeId, placeName: name || prev?.placeName || 'Place', category,
      lat: Math.round(lat * 1e5) / 1e5, lng: Math.round(lng * 1e5) / 1e5,
      rating, text: t.text,
      // 3.55 quick chips per category ("Clean", "Bike parking"...; ids from the engagement config).
      chips: (Array.isArray(b.chips) ? b.chips : []).map((x) => (typeof x === 'string' ? x.trim() : '')).filter((x, i, a) => /^[a-z][a-z0-9_]{0,31}$/.test(x) && a.indexOf(x) === i).slice(0, 10),
      dwellMin: Math.max(0, Math.min(24 * 60, Math.round(Number(b.dwellMin) || 0))),
      userId: req.user.userId, userName: user?.name || 'Rider',
      status: 'PUBLISHED', uploads: prev && Array.isArray(prev.uploads) ? prev.uploads : [],
      createdAt: now, updatedAt: now,
    };
    await repo.savePlaceReview(doc);
    res.status(prev ? 200 : 201).json({ ok: true, review: reviewView(doc, { mine: true }) });
  }));

  const rawPhoto = express.raw({ type: () => true, limit: reviewPhotos.MAX_BYTES });
  r.post('/places/reviews/:reviewId/photo', photoLimiter, (req, res, next) => {
    if (req.is('application/json') || req.is('multipart/form-data')) {
      return res.status(415).json({ error: 'Send the photo bytes as image/jpeg, image/png or image/webp.', code: 'UNSUPPORTED_PHOTO' });
    }
    rawPhoto(req, res, (err) => {
      if (!err) return next();
      if (err.type === 'entity.too.large') return res.status(413).json({ error: 'This photo is too large (up to 2 MB).', code: 'PHOTO_TOO_LARGE' });
      return res.status(400).json({ error: 'The photo did not arrive complete. Please try again.', code: 'NO_PHOTO' });
    });
  }, wrap(async (req, res) => {
    const id = String(req.params.reviewId || '');
    const rev = REVIEW_ID.test(id) ? await repo.findPlaceReview(id) : null;
    if (!rev || rev.userId !== req.user.userId) return res.status(404).json({ error: 'Send your review first.', code: 'NO_REVIEW' });
    const uploads = Array.isArray(rev.uploads) ? rev.uploads : [];
    if (uploads.length >= reviewPhotos.MAX_PER_REVIEW) return res.status(409).json({ error: `Up to ${reviewPhotos.MAX_PER_REVIEW} photos.`, code: 'TOO_MANY_PHOTOS' });
    let prepared;
    try { prepared = reviewPhotos.preparePhoto(req.body); } catch (e) {
      if (!(e instanceof reviewPhotos.PhotoError)) throw e;
      return res.status(e.status).json({ error: e.message, code: e.code });
    }
    const meta = await photoStore.save(prepared);
    const { key, ...clean } = rev;
    void key;
    // Photos are shown once an admin checked them (text and stars are shown at once).
    const next = { ...clean, uploads: [...uploads, { ...meta, approved: false, at: Date.now() }], updatedAt: Date.now() };
    await repo.savePlaceReview(next);
    res.status(201).json({ ok: true, photo: { id: meta.id }, review: reviewView(next, { mine: true }) });
  }));

  r.get('/places/reviews', readLimiter, wrap(async (req, res) => {
    const placeId = String(req.query.placeId || '');
    if (!PLACE_ID.test(placeId)) return res.status(400).json({ error: 'Unknown place.', code: 'BAD_REQUEST' });
    const list = await repo.placeReviewsFor(placeId, { limit: 50 });
    const mine = await repo.findPlaceReviewBy(req.user.userId, placeId);
    res.set('Cache-Control', 'private, max-age=30').json({
      ok: true, summary: summaryOf(list), reviews: list.slice(0, 20).map((x) => reviewView(x)),
      mine: mine ? reviewView(mine, { mine: true }) : null,
    });
  }));

  r.get('/places/review-summary', readLimiter, wrap(async (req, res) => {
    const s = Number(req.query.s), w = Number(req.query.w), n = Number(req.query.n), e = Number(req.query.e);
    if (![s, w, n, e].every(Number.isFinite) || n < s || e < w || n - s > 1.5 || e - w > 1.5) {
      return res.status(400).json({ error: 'Send a box of at most 1.5 degrees.', code: 'BAD_REQUEST' });
    }
    const rows = await repo.placeReviewsIn({ s, w, n, e });
    const by = new Map();
    for (const x of rows) {
      const cur = by.get(x.placeId) || { placeId: x.placeId, placeName: x.placeName, category: x.category, lat: x.lat, lng: x.lng, list: [] };
      cur.list.push(x);
      by.set(x.placeId, cur);
    }
    const places = [...by.values()].map((p) => ({ placeId: p.placeId, placeName: p.placeName, category: p.category, lat: p.lat, lng: p.lng, ...summaryOf(p.list) }));
    res.set('Cache-Control', 'private, max-age=120').json({ ok: true, places });
  }));

  r.get('/places/reviews/:reviewId/photo/:photoId', readLimiter, wrap(async (req, res) => {
    const id = String(req.params.reviewId || ''), pid = String(req.params.photoId || '');
    const rev = REVIEW_ID.test(id) && reviewPhotos.isPhotoId(pid) ? await repo.findPlaceReview(id) : null;
    const meta = rev ? (rev.uploads || []).find((u) => u && u.id === pid && (u.approved === true || rev.userId === req.user.userId || req.user.role === 'MASTER_ADMIN')) : null;
    const visible = !!meta && (rev.status === 'PUBLISHED' || req.user.role === 'MASTER_ADMIN');
    const data = visible ? await photoStore.read(meta) : null;
    if (!data) return res.status(404).set('Cache-Control', 'no-store').json({ error: 'Not found' });
    res.set('Cache-Control', meta.approved ? 'private, max-age=86400' : 'private, no-store').set('Content-Type', meta.mime)
      .set('Content-Disposition', 'inline').set('X-Robots-Tag', 'noindex').send(data);
  }));

  // ---------------- admin moderation ----------------
  r.get('/admin/place-reviews', requireAdmin, wrap(async (req, res) => {
    const status = ['PUBLISHED', 'HIDDEN'].includes(String(req.query.status || '')) ? String(req.query.status) : null;
    const list = await repo.listPlaceReviews({ status, limit: 300 });
    const pendingOnly = String(req.query.pending || '') === '1';
    const rows = list.filter((x) => !pendingOnly || (x.uploads || []).some((u) => u && u.approved !== true && !u.rejected));
    res.set('Cache-Control', 'no-store').json({
      ok: true,
      reviews: rows.map((x) => ({
        ...reviewView(x, { mine: true }), userId: x.userId, userName: x.userName,
        uploads: (x.uploads || []).map((u) => ({ id: u.id, approved: u.approved === true, rejected: u.rejected === true, url: `/api/places/reviews/${x.reviewId}/photo/${u.id}` })),
      })),
    });
  }));

  r.put('/admin/place-reviews/:reviewId', requireAdmin, wrap(async (req, res) => {
    const id = String(req.params.reviewId || '');
    const rev = REVIEW_ID.test(id) ? await repo.findPlaceReview(id) : null;
    if (!rev) return res.status(404).json({ error: 'Review not found.', code: 'NOT_FOUND' });
    const action = String(req.body?.action || '');
    const photoId = String(req.body?.photoId || '');
    const { key, ...clean } = rev;
    void key;
    let next = { ...clean, updatedAt: Date.now(), moderatedBy: req.user.userId };
    if (action === 'hide') next.status = 'HIDDEN';
    else if (action === 'publish') next.status = 'PUBLISHED';
    else if (action === 'approvePhoto' || action === 'rejectPhoto') {
      const uploads = (rev.uploads || []).map((u) => (u && u.id === photoId ? { ...u, approved: action === 'approvePhoto', rejected: action === 'rejectPhoto' } : u));
      if (!uploads.some((u) => u && u.id === photoId)) return res.status(404).json({ error: 'Photo not found.', code: 'NOT_FOUND' });
      if (action === 'rejectPhoto') {
        const gone = uploads.find((u) => u && u.id === photoId);
        await photoStore.remove(gone).catch(() => {});
        next.uploads = uploads.filter((u) => u && u.id !== photoId);
      } else next.uploads = uploads;
    } else return res.status(400).json({ error: 'action must be hide, publish, approvePhoto or rejectPhoto', code: 'BAD_ACTION' });
    await repo.savePlaceReview(next);
    res.json({ ok: true, review: reviewView(next, { mine: true }) });
  }));
}

module.exports = { registerRoadAndPlaceRoutes, roadRecordOf, publicRoad, spokenWarningFor, reporterKeyOf, KINDS, TTL_DAYS, nearLine };
