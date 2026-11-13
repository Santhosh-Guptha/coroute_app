'use strict';
/**
 * Privacy base of the road & safety intelligence (docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md §Privacy).
 *
 *  - ConsentStore: "Help make roads safer" (opt-in, off by default), one document per rider in `intel_consent`
 *    with the time of every change. Only consenting riders feed the aggregates; everyone reads the warnings.
 *  - riderHash: keyed HMAC of the rider id per India month (INTEL_HASH_KEY). Used only to count distinct riders
 *    and to find a rider's own raw rows for "delete my contributions"; never reversible, never cross-month.
 *  - RideTrimmer: drops the first and last INTEL_TRIM_M (300 m) of every ride and anything within that distance of
 *    a privacy zone (saved home / work, when the rider has them).
 */
const crypto = require('crypto');
const { haversine, monthKey, Lru } = require('./math');

const CONSENT = 'intel_consent';

class ConsentStore {
  constructor({ soda, logger = console, clock = Date.now, ttlMs = 60000, max = 5000 }) {
    Object.assign(this, { soda, log: logger, clock, ttlMs });
    this.cache = new Lru(max); // userId -> { on, at, readAt }
    this.loading = new Map();
    this.mirror = null;
  }

  async init() {
    await this.soda.ensureCollection(CONSENT);
    await this.soda.ensureIndex(CONSENT, { name: `${CONSENT}_user_ux`, unique: true, fields: [{ path: 'userId' }] });
  }

  /** Synchronous peek: true / false when known and fresh, undefined otherwise (a load is started). */
  peek(userId) {
    if (!userId) return false;
    const c = this.cache.get(userId);
    if (c && this.clock() - c.readAt < this.ttlMs) return c.on;
    this.get(userId).catch(() => {});
    return c ? c.on : undefined;
  }

  async get(userId) {
    if (!userId) return false;
    const c = this.cache.get(userId);
    if (c && this.clock() - c.readAt < this.ttlMs) return c.on;
    if (this.loading.has(userId)) return this.loading.get(userId);
    const p = (async () => {
      const row = await this.soda.findOne(CONSENT, { userId: String(userId) });
      const on = !!(row && row.value && row.value.on === true);
      this.cache.set(userId, { on, at: row?.value?.at || 0, readAt: this.clock() });
      return on;
    })().finally(() => this.loading.delete(userId));
    this.loading.set(userId, p);
    return p;
  }

  /** The rider's consent record for the app / website: { on, at, promptedAt }. */
  async view(userId) {
    const row = await this.soda.findOne(CONSENT, { userId: String(userId) });
    const v = row?.value || {};
    return { on: v.on === true, at: v.at || null, promptedAt: v.promptedAt || null, source: v.source || null };
  }

  /** Turns consent on / off (source 'app' | 'web' | 'prompt'); `prompted` records that the one-time prompt was answered. */
  async set(userId, on, { source = 'app', prompted = false } = {}) {
    const now = this.clock();
    const row = await this.soda.findOne(CONSENT, { userId: String(userId) });
    const prev = row?.value || null;
    const history = [...((prev && Array.isArray(prev.history)) ? prev.history : []), { on: !!on, at: now, source }].slice(-20);
    const doc = { userId: String(userId), on: !!on, at: now, source, history,
      promptedAt: prompted ? now : (prev?.promptedAt || null) };
    if (row) await this.soda.replace(CONSENT, row.key, doc);
    else await this.soda.insert(CONSENT, doc);
    this.cache.set(userId, { on: !!on, at: now, readAt: now });
    try { this.mirror?.ext('ic', { userId: String(userId) }); } catch { /* the peer's cache expires within a minute */ }
    return { on: !!on, at: now, promptedAt: doc.promptedAt, source };
  }

  async forget(userId) {
    await this.soda.removeWhere(CONSENT, { userId: String(userId) }).catch(() => 0);
    this.cache.delete(userId);
  }

  /** Admin: how many riders said yes / no. Bounded scan (Always Free scale). */
  async counts({ limit = 20000 } = {}) {
    let on = 0, off = 0, page = 0;
    for (;;) {
      const rows = await this.soda.query(CONSENT, {}, { limit: 500, offset: page * 500 });
      for (const r of rows) { if (r.value?.on === true) on++; else off++; }
      if (rows.length < 500 || (page + 1) * 500 >= limit) break;
      page++;
    }
    return { on, off, total: on + off };
  }

  // Two nodes: a change on one node drops the cached answer on the other (src/mirror.js extension 'ic').
  exportState() { return {}; }
  importState() { this.cache.clear(); }
  applyRemote(op) { if (op && op.userId) this.cache.delete(String(op.userId)); }
}

/** The HMAC key: INTEL_HASH_KEY, else derived from JWT_SECRET (a warning in production; set the Vault key). */
function hashKeyOf(cfg, jwtSecret, logger) {
  if (cfg.hashKey && cfg.hashKey.length >= 16) return cfg.hashKey;
  if (process.env.NODE_ENV === 'production' && logger && !hashKeyOf.warned) {
    hashKeyOf.warned = true;
    logger.warn('[intel] INTEL_HASH_KEY is not set: rider hashes use a key derived from JWT_SECRET. Add INTEL_HASH_KEY to the Vault.');
  }
  return Buffer.from(crypto.hkdfSync('sha256', String(jwtSecret || 'coroute-test'), 'coroute-intel', 'rider-hash-v1', 32)).toString('hex');
}

/** 16 hex chars of HMAC-SHA256(key, month|userId). One-way; a new value every India month. */
function riderHash(key, userId, month) {
  return crypto.createHmac('sha256', key).update(`${month}|${userId}`).digest('hex').slice(0, 16);
}

/** The rider's hashes for the last n months (raw rows older than INTEL_RAW_DAYS are already gone). */
function riderHashes(key, userId, t, months = 4) {
  const { recentMonths } = require('./math');
  return recentMonths(t, months).map((m) => ({ m, rh: riderHash(key, userId, m) }));
}

/**
 * Per ride, per rider. push(point) returns the points that are now safe to count (in order):
 *   - nothing within trimM of the ride's first point (the start), ever;
 *   - a point is held until the rider has ridden trimM further (path distance), so the last trimM before the ride
 *     ends (the destination) are never counted: finish() throws the held points away;
 *   - nothing within trimM of a privacy zone.
 */
class RideTrimmer {
  constructor({ trimM = 300, zones = [], maxHeld = 150 } = {}) {
    this.trimM = trimM; this.zones = (zones || []).filter((z) => z && Number.isFinite(z.lat) && Number.isFinite(z.lng)).slice(0, 4);
    this.start = null; this.held = []; this.heldPath = 0; this.maxHeld = maxHeld;
  }

  /** May an event at this point be counted (start and privacy zones only; used for app-sent and SOS events)? */
  allowed(lat, lng) {
    if (this.start && haversine(this.start.lat, this.start.lng, lat, lng) < this.trimM) return false;
    return !this.zones.some((z) => haversine(z.lat, z.lng, lat, lng) < this.trimM);
  }

  push(p) {
    if (!this.start) this.start = { lat: p.lat, lng: p.lng };
    const last = this.held[this.held.length - 1];
    const step = last ? haversine(last.lat, last.lng, p.lat, p.lng) : 0;
    const out = [];
    // Standing still: one held point with its first and last time (a parked phone never fills the FIFO).
    if (last && step < 10) { last.t2 = p.t; return out; }
    this.held.push({ ...p, step });
    this.heldPath += step;
    // Release the oldest held points while the rider is trimM of road beyond them.
    while (this.held.length > 1 && this.heldPath >= this.trimM) {
      const q = this.held.shift();
      this.heldPath -= this.held[0].step;
      if (this.allowed(q.lat, q.lng)) {
        out.push(q);
        if (q.t2) out.push({ ...q, t: q.t2, t2: undefined, step: 0 });
      }
    }
    // Memory cap (GPS jitter): the oldest held point is dropped, never released early.
    while (this.held.length > this.maxHeld) { this.held.shift(); this.heldPath -= this.held[0].step; this.held[0].step = 0; }
    return out;
  }

  /** End of the ride: the last trimM are dropped. */
  finish() { const n = this.held.length; this.held = []; this.heldPath = 0; return n; }
}

module.exports = { ConsentStore, RideTrimmer, riderHash, riderHashes, hashKeyOf, CONSENT, monthKey };
