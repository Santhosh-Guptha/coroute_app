'use strict';
/**
 * 3.55 risky-stretch heads-up: "Many riders brake hard on this stretch."
 *
 * Phones count their own hard brakes (SafetyService / HardBrakeCounter) and send them anonymously,
 * in batches (every 10 min and at ride end):
 *   POST /api/road-risk/brakes   { events: [{ lat, lng, h }] }   (h = heading bucket 0..7, 45 deg each)
 * The server keeps per ~200 m grid cell and heading bucket ONLY: the cell, the heading bucket, the
 * first/last day bucket, an event count and a capped list (<= 200) of salted reporter hashes used to
 * count distinct riders (the hash is salted per cell, so two cells cannot be linked to one rider).
 * No user id, no exact position, no time finer than a day is stored.
 *
 *   GET /api/road-risk/near?groupId=   cells along the ride's route (120 m either side) that at
 *                                      least K_MIN distinct riders reported, rounded cell centres.
 * Cells with no new event for RETENTION_DAYS are removed by the retention job (purgeOld).
 * Switch id: riskyStretch (403 FEATURE_OFF while off).
 *
 * 3.56 consent: hard brakes are COLLECTED only from riders who turned on "Help make roads safer"
 * (the opt-in of the road hazard layer, collection `intel_consent`). Without it the batch is
 * answered `{ ok: true, cells: 0, reason: 'NO_CONSENT' }` and nothing is stored (older apps keep
 * working). The WARNINGS (GET /road-risk/near) are still shown to every rider. Cells counted before
 * 3.56 hold no rider id and age out after RETENTION_DAYS.
 */
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { decodePolyline, pointToSegment } = require('./geo_math');

const COLLECTION = 'road_risk';
const DAY = 86400000;
/** Grid step in degrees (~220 m of latitude; ~200-220 m of longitude across India). */
const STEP = 0.002;
const K_MIN = 10;
const MAX_REPORTERS = 200;
const MAX_EVENTS = 200;
const MAX_CELLS_PER_POST = 50;
/** One rider adds at most this many events to one cell per batch. */
const MAX_PER_CELL_PER_POST = 3;
const ROUTE_SIDE_M = 120;
const RETENTION_DAYS = 180;

const dayOf = (t) => Math.floor(t / DAY);
const round5 = (x) => Math.round(x * 1e5) / 1e5;

/** The grid cell of a point: { cell: 'i:j', lat, lng } with the rounded cell centre. */
function cellOf(lat, lng) {
  const i = Math.round(lat / STEP), j = Math.round(lng / STEP);
  return { cell: `${i}:${j}`, lat: round5(i * STEP), lng: round5(j * STEP) };
}

/** Salted, one-way, per-cell reporter key (never the id; not linkable across cells). */
function reporterHash(userId, riskId) {
  return crypto.createHmac('sha256', String(config.jwtSecret || 'coroute')).update(`brake:${riskId}:${userId}`).digest('hex').slice(0, 16);
}

/** Valid events of a batch grouped by cell and heading bucket: [{ riskId, cell, hb, lat, lng, n }]. */
function groupEvents(events) {
  const by = new Map();
  for (const e of Array.isArray(events) ? events.slice(0, MAX_EVENTS) : []) {
    if (!e || typeof e !== 'object') continue;
    const lat = Number(e.lat), lng = Number(e.lng), hb = Number(e.h);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 85 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) continue;
    if (!Number.isInteger(hb) || hb < 0 || hb > 7) continue;
    const c = cellOf(lat, lng);
    const riskId = `${c.cell}:${hb}`;
    const g = by.get(riskId);
    if (g) g.n = Math.min(MAX_PER_CELL_PER_POST, g.n + 1);
    else if (by.size < MAX_CELLS_PER_POST) by.set(riskId, { riskId, cell: c.cell, hb, lat: c.lat, lng: c.lng, n: 1 });
  }
  return [...by.values()];
}

class RoadRiskStore {
  constructor(soda) { this.soda = soda; }

  async ensure() {
    await this.soda.ensureCollection(COLLECTION);
    const idx = (name, fields, unique = false) => this.soda.ensureIndex(COLLECTION, { name, unique, fields });
    await idx('road_risk_id_ux', [{ path: 'riskId' }], true);
    await idx('road_risk_lat_ix', [{ path: 'lat', datatype: 'number' }]);
    await idx('road_risk_day_ix', [{ path: 'lastDay', datatype: 'number' }]);
  }

  /** Adds one rider's batch. Returns how many cells were touched. */
  async record(userId, events, now = Date.now()) {
    if (!userId) return 0;
    const today = dayOf(now);
    const groups = groupEvents(events);
    for (const g of groups) {
      const h = reporterHash(userId, g.riskId);
      const hit = await this.soda.findOne(COLLECTION, { riskId: g.riskId });
      if (hit && hit.value) {
        const v = hit.value;
        const reporters = Array.isArray(v.reporters) ? v.reporters : [];
        const next = reporters.includes(h) || reporters.length >= MAX_REPORTERS ? reporters : [...reporters, h];
        await this.soda.replace(COLLECTION, hit.key, {
          riskId: v.riskId, cell: v.cell, hb: v.hb, lat: v.lat, lng: v.lng,
          count: (Number(v.count) || 0) + g.n, reporters: next, reporterCount: next.length,
          firstDay: Number(v.firstDay) || today, lastDay: today,
        });
      } else {
        await this.soda.upsertBy(COLLECTION, { riskId: g.riskId }, {
          riskId: g.riskId, cell: g.cell, hb: g.hb, lat: g.lat, lng: g.lng,
          count: g.n, reporters: [h], reporterCount: 1, firstDay: today, lastDay: today,
        });
      }
    }
    return groups.length;
  }

  /** Cells with at least K_MIN distinct riders within the box. */
  async confirmedIn({ s, w, n, e }, { limit = 1000 } = {}) {
    const rows = await this.soda.query(COLLECTION, { lat: { $gte: s, $lte: n }, reporterCount: { $gte: K_MIN } }, { limit: Math.min(4000, limit * 4) });
    return rows.map((r) => r.value).filter((c) => c && c.lng >= w && c.lng <= e && (Number(c.reporterCount) || 0) >= K_MIN).slice(0, limit);
  }

  /** Retention: cells with no event for RETENTION_DAYS. */
  async purgeOld(now = Date.now()) {
    return this.soda.removeWhere(COLLECTION, { lastDay: { $lt: dayOf(now) - RETENTION_DAYS } });
  }
}

/** What a rider gets: the rounded cell centre and the direction, never counts or hashes. */
function publicCell(c) {
  return { id: c.riskId, lat: round5(c.lat), lng: round5(c.lng), headingBucket: c.hb, headingDeg: c.hb * 45 };
}

function bboxOfLine(line, padM) {
  let s = 90, n = -90, w = 180, e = -180;
  for (const p of line) { s = Math.min(s, p.lat); n = Math.max(n, p.lat); w = Math.min(w, p.lng); e = Math.max(e, p.lng); }
  const pad = padM / 111320;
  const padLng = padM / (111320 * Math.max(0.2, Math.cos((((s + n) / 2) * Math.PI) / 180)));
  return { s: s - pad, n: n + pad, w: w - padLng, e: e + padLng };
}

function nearLine(list, line, sideM = ROUTE_SIDE_M) {
  return list.filter((c) => {
    for (let i = 0; i < line.length - 1; i++) {
      if (pointToSegment({ lat: c.lat, lng: c.lng }, line[i], line[i + 1]).dist <= sideM) return true;
    }
    return false;
  });
}

/** The opt-in of the hazard layer (src/intel/privacy.js CONSENT collection); cached for a minute. */
const CONSENT_COLLECTION = 'intel_consent';
function consentReader(soda, { ttlMs = 60000, max = 5000, clock = Date.now } = {}) {
  const cache = new Map(); // userId -> { on, at }
  return async (userId) => {
    if (!userId) return false;
    const hit = cache.get(userId);
    if (hit && clock() - hit.at < ttlMs) return hit.on;
    let on = false;
    try {
      const row = await soda.findOne(CONSENT_COLLECTION, { userId: String(userId) });
      on = !!(row && row.value && row.value.on === true);
    } catch { on = false; } // no collection yet = nobody opted in
    cache.delete(userId);
    if (!on) return false; // "no" is never cached: an opt-in counts from the next batch
    cache.set(userId, { on, at: clock() });
    while (cache.size > max) cache.delete(cache.keys().next().value);
    return on;
  };
}

function registerRoadRiskRoutes({ r, repo, convoys, wrap, store, consentOf }) {
  const risk = store || new RoadRiskStore(repo.soda);
  // 3.56: collection needs the rider's "Help make roads safer" opt-in (short cache: a rider who
  // just switched it on is counted within seconds, one who switched it off within a minute).
  const hasConsent = consentOf || consentReader(repo.soda, { ttlMs: 15000 });
  let ready = null;
  const ensure = () => (ready ||= risk.ensure().catch((e) => { ready = null; throw e; }));
  const limit = (windowMs, n) => rateLimit({ windowMs, limit: n, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => req.user?.userId || req.ip, validate: false, message: { error: 'Too many requests. Try again later.', code: 'RATE_LIMITED' } });
  const postLimiter = limit(60 * 60 * 1000, 30);
  const readLimiter = limit(60 * 1000, 60);
  const off = (res) => {
    const ff = convoys && convoys.featureFlags;
    if (ff && !ff.isOn('riskyStretch')) {
      res.status(403).set('Cache-Control', 'no-store').json({ error: 'This feature is turned off for now.', code: 'FEATURE_OFF', feature: 'riskyStretch' });
      return true;
    }
    return false;
  };

  r.post('/road-risk/brakes', postLimiter, wrap(async (req, res) => {
    if (off(res)) return;
    const b = req.body && typeof req.body === 'object' && !Array.isArray(req.body) ? req.body : {};
    if (!Array.isArray(b.events)) return res.status(400).json({ error: 'Send events.', code: 'BAD_REQUEST' });
    if (!(await hasConsent(req.user.userId))) return res.json({ ok: true, cells: 0, reason: 'NO_CONSENT' });
    await ensure();
    const cells = await risk.record(req.user.userId, b.events);
    res.json({ ok: true, cells });
  }));

  r.get('/road-risk/near', readLimiter, wrap(async (req, res) => {
    if (off(res)) return;
    const gid = String(req.query.groupId || '').slice(0, 64);
    if (!gid) return res.status(400).json({ error: 'Send groupId.', code: 'BAD_REQUEST' });
    const room = convoys && convoys.rooms ? convoys.rooms.get(gid) : null;
    const meta = room ? room.meta : await repo.getConvoyMeta(gid).catch(() => null);
    if (!meta) return res.status(404).json({ error: 'Ride not found.', code: 'NOT_FOUND' });
    const member = (room && room.riders.has(req.user.userId)) || (meta.members && meta.members[req.user.userId]);
    if (!member) return res.status(403).json({ error: 'Not a member of this ride.', code: 'NOT_MEMBER' });
    await ensure();
    const poly = meta.route && meta.route.polyline;
    let line = typeof poly === 'string' && poly ? decodePolyline(poly, 20000) : null;
    let side = ROUTE_SIDE_M;
    if (!line || line.length < 2) {
      const s = meta.start || {};
      line = [s.lat ? { lat: s.lat, lng: s.lng } : null, meta.destinationLat || meta.destinationLng ? { lat: meta.destinationLat, lng: meta.destinationLng } : null].filter(Boolean);
      side = 3000;
    }
    let list = [];
    if (line.length >= 2) list = nearLine(await risk.confirmedIn(bboxOfLine(line, side)), line, side);
    res.set('Cache-Control', 'private, max-age=300').json({ ok: true, cells: list.slice(0, 500).map(publicCell) });
  }));
  return risk;
}

module.exports = { RoadRiskStore, registerRoadRiskRoutes, consentReader, cellOf, groupEvents, reporterHash, publicCell, K_MIN, STEP, RETENTION_DAYS, COLLECTION };
