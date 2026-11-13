'use strict';
/**
 * Round 7: compact road-geometry cells for curve prediction and speed limits on the phone
 * (docs/features_355/curve_and_speed_limit.md).
 *
 *   GET  /api/geo/roads?cell=<geohash-6>          one cell: roads (class, simplified geometry, limit tags, one-way),
 *                                                school / hospital points, an urban hint. gzip + ETag. 202 = not yet.
 *   POST /api/geo/limit-corrections               { way, cell, kmh, shownKmh?, shownSource? }  one "wrong limit" vote
 *   GET  /api/admin/geo/limit-corrections         review list (MASTER_ADMIN)
 *   POST /api/admin/geo/limit-corrections/:way    { action: apply | reject | reopen, kmh? }
 *
 * The gateway is only a polite cache in front of Overpass (OpenStreetMap, ODbL):
 *  - one bounded query per cell, answer reduced to what the phone needs, gzip once, stored in geo_cache for 30 days
 *    (served stale for up to 180 days while a refresh waits for budget);
 *  - memory: an LRU of gzip buffers bounded in BYTES (ROAD_CELLS_MEM_MB), one upstream call at a time per node
 *    (ROAD_CELLS_CONCURRENCY), a per-minute and a per-day budget, exponential backoff after a refusal (429 / 504 /
 *    timeout). Over budget = 202 "pending" with Retry-After; the phone stays silent without data and asks later;
 *  - a fair-use User-Agent with the site and contact (config.providerUserAgent).
 *
 * "Wrong limit" votes: one per rider per road (a stable keyed hash, never the rider id), consenting riders only
 * (the same "Help make roads safer" switch as the other road intelligence). A value needs k distinct riders
 * (ROAD_LIMIT_K_MIN, at least 3). It may replace an ESTIMATE, or LOWER an explicit OpenStreetMap tag; it never
 * raises a tagged limit and never goes above the motorcycle maximum.
 */
const crypto = require('crypto');
const zlib = require('zlib');
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const gh = require('./intel/geohash');
const { requireAuth, requireAdmin } = require('./auth');

const PRECISION = 6;
const CACHE_KEY = 'roads:v1:';
const VOTES = 'road_limit_votes';
const MARGIN_DEG = 0.0015; // about 165 m around the cell, so a road continues into the next cell without a gap
const MAX_WAYS = 1200;
const MAX_POINTS = 14000;
const SIMPLIFY_M = 2; // Douglas-Peucker tolerance: keeps bends true to about 2 m
const MOTORCYCLE_MAX_KMH = 80; // MoRTH S.O. 1522(E), 6 April 2018: no road allows a motorcycle more
/** Road classes, most important first. The index is the wire value `h`; must match lib/domain/road/road_cell.dart. */
const CLASSES = ['motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified', 'residential', 'living_street',
  'service', 'road', 'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link'];
const CLASS_RANK = [0, 1, 2, 3, 4, 5, 6, 7, 9, 6, 1, 2, 3, 4, 5];
const SKIP_SERVICE = new Set(['parking_aisle', 'driveway', 'drive-through', 'emergency_access']);

class RoadCellError extends Error {
  constructor(status, code, message) { super(message || code); this.status = status; this.code = code; }
}

function overpassQuery(cell) {
  const b = gh.bbox(cell);
  const r = (n) => Math.round(n * 1e5) / 1e5;
  const box = `${r(b.s - MARGIN_DEG)},${r(b.w - MARGIN_DEG)},${r(b.n + MARGIN_DEG)},${r(b.e + MARGIN_DEG)}`;
  return `[out:json][timeout:25][maxsize:67108864][bbox:${box}];`
    + `way["highway"~"^(${CLASSES.join('|')})$"];out tags geom qt ${MAX_WAYS + 300};`
    + 'nwr["amenity"~"^(school|college|kindergarten|hospital)$"];out center tags 120;'
    + 'way["building"];out count;'
    + 'way["landuse"~"^(residential|commercial|retail|industrial)$"];out count;';
}

/** km/h of a plain numeric maxspeed value ("50", "30 mph"); null for implicit / unknown values. */
function numericKmh(raw) {
  if (typeof raw !== 'string') return null;
  const m = /^\s*(\d{1,3}(?:\.\d+)?)\s*(km\/h|kmh|kph|mph)?\s*$/i.exec(raw.split(';')[0]);
  if (!m) return null;
  const v = Math.round(Number(m[1]) * (String(m[2] || '').toLowerCase() === 'mph' ? 1.609344 : 1));
  return v >= 5 && v <= 140 ? v : null;
}

/** Douglas-Peucker on [lat, lng] points, tolerance in metres (flat-earth metres near the line: cells are tiny). */
function simplify(pts, tolM) {
  if (pts.length <= 2) return pts;
  const k = Math.cos(pts[0][0] * Math.PI / 180) * 111320, kl = 110540;
  const keep = new Uint8Array(pts.length); keep[0] = 1; keep[pts.length - 1] = 1;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    const ax = pts[a][1] * k, ay = pts[a][0] * kl, bx = pts[b][1] * k, by = pts[b][0] * kl;
    const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
    let worst = -1, wd = tolM;
    for (let i = a + 1; i < b; i++) {
      const px = pts[i][1] * k, py = pts[i][0] * kl;
      let t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0;
      t = Math.max(0, Math.min(1, t));
      const d = Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
      if (d > wd) { wd = d; worst = i; }
    }
    if (worst > 0) { keep[worst] = 1; stack.push([a, worst], [worst, b]); }
  }
  return pts.filter((_, i) => keep[i]);
}

/** The runs of a way inside the box (one point outside kept at each end, so the line reaches the edge). */
function clip(pts, box) {
  const inside = (p) => p[0] >= box.s && p[0] <= box.n && p[1] >= box.w && p[1] <= box.e;
  const out = [];
  let run = null;
  for (let i = 0; i < pts.length; i++) {
    if (inside(pts[i])) {
      if (!run) { run = []; if (i > 0) run.push(pts[i - 1]); }
      run.push(pts[i]);
    } else if (run) { run.push(pts[i]); out.push(run); run = null; }
  }
  if (run) out.push(run);
  return out.filter((r) => r.length >= 2);
}

/** [lat0, lng0, dLat, dLng, ...] in 1e-5 degrees. */
function deltaEncode(pts) {
  const g = [];
  let pa = 0, po = 0;
  for (const [la, lo] of pts) {
    const a = Math.round(la * 1e5), o = Math.round(lo * 1e5);
    g.push(a - pa, o - po); pa = a; po = o;
  }
  return g;
}

/**
 * An Overpass answer reduced to the cell document the phone reads:
 * { v, c, w: [{ i, h, g, n?, ms?, mm?, mt?, ow?, lit?, ln?, br?, tn? }], z: [[lat5, lng5, 's'|'h']], u: { b, lu }, fx: {} }
 */
function buildCell(cell, elements) {
  const b = gh.bbox(cell);
  const box = { s: b.s - MARGIN_DEG, w: b.w - MARGIN_DEG, n: b.n + MARGIN_DEG, e: b.e + MARGIN_DEG };
  const ways = [], zones = [];
  const counts = [];
  for (const e of Array.isArray(elements) ? elements : []) {
    if (!e || typeof e !== 'object') continue;
    if (e.type === 'count') { counts.push(Number(e.tags?.ways ?? e.tags?.total) || 0); continue; }
    const t = e.tags || {};
    if (e.type === 'way' && typeof t.highway === 'string' && Array.isArray(e.geometry)) {
      const h = CLASSES.indexOf(t.highway);
      if (h < 0) continue;
      if (t.highway === 'service' && SKIP_SERVICE.has(t.service)) continue;
      if (t.access === 'private' || t.access === 'no' || t.motorcycle === 'no' || t.motor_vehicle === 'no') continue;
      const pts = e.geometry.filter((p) => p && Number.isFinite(p.lat) && Number.isFinite(p.lon) && Math.abs(p.lat) <= 90 && Math.abs(p.lon) <= 180).map((p) => [p.lat, p.lon]);
      const str = (k, n = 40) => (typeof t[k] === 'string' && t[k].trim() ? t[k].trim().slice(0, n) : null);
      const base = { i: Number(e.id) || 0, h };
      const name = str('name:en') || str('name') || str('ref');
      if (name) base.n = name;
      const ms = str('maxspeed', 24); if (ms) base.ms = ms;
      const mm = str('maxspeed:motorcycle', 24); if (mm) base.mm = mm;
      const mt = str('maxspeed:type', 24) || str('source:maxspeed', 24) || str('zone:maxspeed', 24); if (mt) base.mt = mt;
      if (t.oneway === 'yes' || t.oneway === '1' || t.oneway === 'true' || t.junction === 'roundabout' || (t.highway === 'motorway' && t.oneway !== 'no')) base.ow = 1;
      else if (t.oneway === '-1' || t.oneway === 'reverse') base.ow = -1;
      if (t.lit === 'yes' || t.lit === '24/7' || t.lit === 'automatic') base.lit = 1;
      const ln = Number(t.lanes); if (Number.isInteger(ln) && ln >= 1 && ln <= 12) base.ln = ln;
      if (t.bridge && t.bridge !== 'no') base.br = 1;
      if (t.tunnel && t.tunnel !== 'no') base.tn = 1;
      for (const run of clip(pts, box)) {
        const s = simplify(run, SIMPLIFY_M);
        if (s.length >= 2) ways.push({ ...base, _p: s });
      }
    } else if (['school', 'college', 'kindergarten', 'hospital'].includes(t.amenity)) {
      const lat = e.lat ?? e.center?.lat, lng = e.lon ?? e.center?.lon;
      if (Number.isFinite(lat) && Number.isFinite(lng) && zones.length < 80) zones.push([Math.round(lat * 1e5), Math.round(lng * 1e5), t.amenity === 'hospital' ? 'h' : 's']);
    }
  }
  // Bounded: the most important classes first, then the rest until the way / point caps.
  ways.sort((x, y) => CLASS_RANK[x.h] - CLASS_RANK[y.h] || x.i - y.i);
  const w = [];
  let points = 0, truncated = false;
  for (const x of ways) {
    if (w.length >= MAX_WAYS || points + x._p.length > MAX_POINTS) { truncated = true; break; }
    points += x._p.length;
    const { _p, ...rest } = x;
    w.push({ ...rest, g: deltaEncode(_p) });
  }
  const doc = { v: 1, c: cell, w, z: zones, u: { b: counts[0] || 0, lu: counts[1] || 0 }, fx: {} };
  if (truncated) doc.tr = 1;
  return doc;
}

/**
 * The value a road's votes agree on, or null. `votes`: [{ h, kmh }] (one per rider). `tagKmh`: the explicit numeric
 * OpenStreetMap limit of the road (null when the phone showed an estimate).
 */
function decideCorrection(votes, tagKmh, kMin = 3) {
  const k = Math.max(3, Number(kMin) || 3);
  const by = new Map();
  const seen = new Set();
  for (const v of Array.isArray(votes) ? votes : []) {
    if (!v || typeof v.h !== 'string' || seen.has(v.h)) continue;
    const kmh = Number(v.kmh);
    if (!validKmh(kmh)) continue;
    seen.add(v.h);
    by.set(kmh, (by.get(kmh) || 0) + 1);
  }
  let best = null, bestN = 0;
  for (const [kmh, n] of by) if (n > bestN || (n === bestN && best !== null && kmh < best)) { best = kmh; bestN = n; } // a tie: the lower value
  if (best === null || bestN < k) return null;
  if (best > MOTORCYCLE_MAX_KMH) return null;
  if (Number.isFinite(tagKmh) && tagKmh > 0 && best >= tagKmh) return null; // never raises (or repeats) a tagged limit
  return best;
}

function validKmh(v) { return Number.isInteger(v) && v >= 5 && v <= 120 && v % 5 === 0; }

class RoadCellService {
  constructor({ repo, soda = null, url = null, fetchImpl = globalThis.fetch, clock = Date.now, logger = console, env = process.env,
    ttlMs, staleMs, memBytes, perMin, perDay, concurrency, timeoutMs = 25000, kMin, hashKey = 'coroute-test' } = {}) {
    const num = (v, d, lo, hi) => { const n = Number(v); return Number.isFinite(n) && n >= lo && n <= hi ? n : d; };
    this.repo = repo; this.soda = soda; this.url = url; this.fetch = fetchImpl; this.clock = clock; this.log = logger;
    this.ttlMs = ttlMs ?? num(env.ROAD_CELLS_TTL_DAYS, 30, 1, 365) * 86400000;
    this.staleMs = staleMs ?? Math.max(this.ttlMs, 180 * 86400000);
    this.memBytes = memBytes ?? num(env.ROAD_CELLS_MEM_MB, 12, 1, 64) * 1024 * 1024;
    this.perMin = perMin ?? num(env.ROAD_CELLS_UPSTREAM_PER_MIN, 6, 1, 60);
    this.perDay = perDay ?? num(env.ROAD_CELLS_UPSTREAM_PER_DAY, 2000, 10, 9000);
    this.concurrency = concurrency ?? num(env.ROAD_CELLS_CONCURRENCY, 1, 1, 4);
    this.kMin = Math.max(3, kMin ?? num(env.ROAD_LIMIT_K_MIN, 3, 3, 50));
    this.timeoutMs = timeoutMs; this.hashKey = hashKey;
    this.mem = new Map(); // cell -> { at, etag, gz, seenAt }
    this.memUsed = 0;
    this.memRecheckMs = 3600000; // a node re-reads the stored cell hourly (a correction applied on the other node)
    this.inflight = new Map();
    this.running = 0;
    this.started = [];
    this.day = { key: '', n: 0 };
    this.fails = 0;
    this.backoffUntil = 0;
    this.stats = { memHits: 0, diskHits: 0, upstream: 0, upstreamFailed: 0, pending: 0, votes: 0, applied: 0 };
    this.jobs = null; // round 8: set by src/jobs/producers.js
  }

  get configured() { return !!this.url; }

  async init() { if (this.soda) { await this.soda.ensureCollection(VOTES); await this.soda.ensureIndex?.(VOTES, { name: `${VOTES}_id_ux`, unique: true, fields: [{ path: 'id' }] }).catch(() => {}); } }

  health() {
    return { configured: this.configured, memCells: this.mem.size, memBytes: this.memUsed, memMaxBytes: this.memBytes, running: this.running,
      backoffS: Math.max(0, Math.round((this.backoffUntil - this.clock()) / 1000)), today: this.day.n, perDay: this.perDay, kMin: this.kMin, ...this.stats };
  }

  // ------------------------------------------------------------------ memory (bounded in bytes)
  _remember(cell, v) {
    const old = this.mem.get(cell);
    if (old) { this.memUsed -= old.gz.length; this.mem.delete(cell); }
    if (v.gz.length > this.memBytes) return;
    this.mem.set(cell, { ...v, seenAt: this.clock() });
    this.memUsed += v.gz.length;
    while (this.memUsed > this.memBytes && this.mem.size > 1) {
      const k = this.mem.keys().next().value;
      this.memUsed -= this.mem.get(k).gz.length;
      this.mem.delete(k);
    }
  }

  static pack(doc, at) {
    const json = Buffer.from(JSON.stringify(doc), 'utf8');
    const gz = zlib.gzipSync(json, { level: 9 });
    const etag = `"r1-${crypto.createHash('sha1').update(json).digest('base64url').slice(0, 20)}"`;
    return { at, etag, gz };
  }

  static unpack(v) { return JSON.parse(zlib.gunzipSync(v.gz, { maxOutputLength: 8 * 1024 * 1024 }).toString('utf8')); }

  async _load(cell) {
    const hit = await this.repo.geoCacheGet(`${CACHE_KEY}${cell}`).catch(() => null);
    const v = hit?.value;
    if (!v || typeof v.gz !== 'string' || !Number.isFinite(v.at) || typeof v.etag !== 'string') return null;
    try { return { at: v.at, etag: v.etag, gz: Buffer.from(v.gz, 'base64') }; } catch { return null; }
  }

  async _save(cell, v) {
    this._remember(cell, v);
    await this.repo.geoCachePut(`${CACHE_KEY}${cell}`, { at: v.at, etag: v.etag, gz: v.gz.toString('base64') }).catch(() => {});
  }

  // ------------------------------------------------------------------ upstream budget
  /** Milliseconds until an upstream call may start (0 = now). Spends one unit of budget when it answers 0. */
  _budget() {
    const now = this.clock();
    if (now < this.backoffUntil) return this.backoffUntil - now;
    if (this.running >= this.concurrency) return 5000;
    const dayKey = new Date(now).toISOString().slice(0, 10);
    if (this.day.key !== dayKey) this.day = { key: dayKey, n: 0 };
    if (this.day.n >= this.perDay) return 3600000;
    this.started = this.started.filter((t) => now - t < 60000);
    if (this.started.length >= this.perMin) return Math.max(1000, 60000 - (now - this.started[0]));
    this.started.push(now);
    this.day.n++;
    return 0;
  }

  _failed() {
    this.fails = Math.min(this.fails + 1, 6);
    this.backoffUntil = this.clock() + Math.min(15 * 60000, 30000 * 2 ** (this.fails - 1));
    this.stats.upstreamFailed++;
  }

  async _upstream(cell) {
    this.running++;
    this.stats.upstream++;
    try {
      const res = await this.fetch(this.url, {
        method: 'POST', body: 'data=' + encodeURIComponent(overpassQuery(cell)),
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': config.providerUserAgent, 'Accept-Encoding': 'gzip' },
        signal: AbortSignal.timeout(this.timeoutMs),
      });
      if (!res.ok) { this._failed(); return null; }
      const j = await res.json();
      // A "remark" is Overpass saying the query ran out of time or memory: not a usable answer.
      if (!Array.isArray(j?.elements) || j.remark) { this._failed(); return null; }
      this.fails = 0; this.backoffUntil = 0;
      const doc = buildCell(cell, j.elements);
      await this._applyStoredCorrections(cell, doc).catch(() => {});
      return RoadCellService.pack(doc, this.clock());
    } catch (_) { this._failed(); return null; } finally { this.running--; }
  }

  _refresh(cell) {
    if (this.inflight.has(cell)) return this.inflight.get(cell);
    const run = (async () => {
      const v = await this._upstream(cell);
      if (v) await this._save(cell, v);
      return v;
    })().finally(() => this.inflight.delete(cell));
    this.inflight.set(cell, run);
    return run;
  }

  /**
   * { status: 'ok', at, etag, gz, stale? } or { status: 'pending', retryAfterS }.
   * Throws RoadCellError (400 invalid cell, 503 not configured and nothing cached).
   */
  async cell(raw) {
    const cell = String(raw || '').trim().toLowerCase();
    if (cell.length !== PRECISION || !gh.isValid(cell)) throw new RoadCellError(400, 'INVALID_CELL', 'cell must be a 6-character geohash.');
    const now = this.clock();
    let v = this.mem.get(cell) || null;
    if (v && now - v.seenAt < this.memRecheckMs && now - v.at < this.ttlMs) {
      this.mem.delete(cell); this.mem.set(cell, v); // LRU touch
      this.stats.memHits++;
      return { status: 'ok', ...v };
    }
    const stored = await this._load(cell);
    if (stored) { v = stored; this._remember(cell, stored); }
    if (v && now - v.at < this.ttlMs) { this.stats.diskHits++; return { status: 'ok', ...v }; }
    const stale = v && now - v.at < this.staleMs ? v : null;
    if (!this.configured) {
      if (stale) return { status: 'ok', ...stale, stale: true };
      throw new RoadCellError(503, 'ROADS_NOT_CONFIGURED', 'Road data is unavailable.');
    }
    // Round 8 (src/jobs/): with the job queue on, the upstream fetch runs on a worker under ITS budget; this request
    // answers at once with the stale copy or 202 "pending" (the phone asks again after Retry-After).
    if (this._jobsOn()) {
      this._enqueueFetch(cell);
      if (stale) return { status: 'ok', ...stale, stale: true };
      this.stats.pending++;
      return { status: 'pending', retryAfterS: 30 };
    }
    const waitMs = this.inflight.has(cell) ? 0 : this._budget();
    if (waitMs > 0) {
      this.stats.pending++;
      return stale ? { status: 'ok', ...stale, stale: true } : { status: 'pending', retryAfterS: Math.min(3600, Math.ceil(waitMs / 1000)) };
    }
    if (stale) { this._refresh(cell).catch(() => {}); return { status: 'ok', ...stale, stale: true }; } // old data now, new data next time
    const fresh = await this._refresh(cell);
    if (fresh) return { status: 'ok', ...fresh };
    this.stats.pending++;
    return { status: 'pending', retryAfterS: Math.max(30, Math.ceil((this.backoffUntil - this.clock()) / 1000)) };
  }

  // ------------------------------------------------------------------ round 8 job queue (src/jobs/producers.js)
  _jobsOn() { return !!(this.jobs && this.jobs.enabled && !require('./jobs/context').inJob()); }

  /** One roads.fetch job per cell (key roads:<cell>, rearmed once done); a node asks at most once a minute per cell. */
  _enqueueFetch(cell) {
    const now = this.clock();
    if (!this.enqueuedAt) this.enqueuedAt = new Map();
    const last = this.enqueuedAt.get(cell);
    if (last && now - last < 60000) return;
    this.enqueuedAt.set(cell, now);
    while (this.enqueuedAt.size > 5000) this.enqueuedAt.delete(this.enqueuedAt.keys().next().value);
    this.jobs.enqueue('roads.fetch', { cell }, { key: `roads:${cell}`, rearm: true, priority: 5 }).catch((e) => {
      this.enqueuedAt.delete(cell);
      this.log.warn?.(`[roads] enqueue failed: ${String(e.code || e.message).slice(0, 60)}`);
    });
  }

  /**
   * The roads.fetch handler (on a worker): fresh in the database already -> nothing to do; no budget -> { deferMs }
   * (no attempt spent); upstream refused -> { retryMs }; else fetched and stored (geo_cache) for every node.
   */
  async fetchForJob(raw) {
    const cell = String(raw || '').trim().toLowerCase();
    if (cell.length !== PRECISION || !gh.isValid(cell) || !this.configured) return { skipped: true };
    const now = this.clock();
    const stored = await this._load(cell);
    if (stored && now - stored.at < this.ttlMs) { this._remember(cell, stored); return { cached: true }; }
    const waitMs = this.inflight.has(cell) ? 0 : this._budget();
    if (waitMs > 0) return { deferMs: Math.min(3600000, waitMs) };
    const v = await this._refresh(cell);
    if (!v) return { retryMs: Math.max(30000, this.backoffUntil - this.clock()) };
    return { fetched: true };
  }

  // ------------------------------------------------------------------ "wrong limit" votes
  riderKey(userId) { return crypto.createHmac('sha256', String(this.hashKey)).update(`limit-vote|${userId}`).digest('hex').slice(0, 16); }

  async _voteDoc(way) {
    const r = await this.soda.findOne(VOTES, { id: `w${way}` });
    return r ? r.value : null;
  }

  /** The numeric OSM limit and whether the road is in the cached cell: { known, tagKmh }. */
  async _tagOf(cell, way) {
    const v = this.mem.get(cell) || await this._load(cell);
    if (!v) return { known: false, tagKmh: null };
    try {
      const w = RoadCellService.unpack(v).w.find((x) => x.i === way);
      if (!w) return { known: false, tagKmh: null };
      return { known: true, tagKmh: numericKmh(w.mm) ?? numericKmh(w.ms) };
    } catch { return { known: false, tagKmh: null }; }
  }

  /** One vote. Returns { accepted, applied } or { accepted: false, reason }. */
  async vote(userId, body) {
    const way = Number(body?.way), kmh = Number(body?.kmh);
    const cell = String(body?.cell || '').toLowerCase();
    if (!Number.isInteger(way) || way <= 0 || way > 2 ** 53 || !validKmh(kmh) || cell.length !== PRECISION || !gh.isValid(cell)) {
      throw new RoadCellError(400, 'INVALID', 'way, cell and kmh (5 to 120, a multiple of 5) are required.');
    }
    const { known, tagKmh } = await this._tagOf(cell, way);
    if (!known) throw new RoadCellError(404, 'UNKNOWN_ROAD', 'That road is not in the road data.');
    const h = this.riderKey(userId);
    const now = this.clock();
    const doc = (await this._voteDoc(way)) || { id: `w${way}`, way, cell, votes: [], status: 'open', applied: null, createdAt: now };
    doc.cell = cell; doc.tagKmh = tagKmh;
    const shown = Number(body?.shownKmh);
    doc.votes = doc.votes.filter((x) => x.h !== h).slice(-49);
    doc.votes.push({ h, kmh, at: now, ...(validKmh(shown) || (Number.isInteger(shown) && shown > 0 && shown <= 140) ? { shown } : {}), ...(typeof body?.shownSource === 'string' ? { src: body.shownSource.slice(0, 12) } : {}) });
    doc.updatedAt = now;
    this.stats.votes++;
    let applied = null;
    if (doc.status !== 'rejected') {
      applied = decideCorrection(doc.votes, tagKmh, this.kMin);
      if (applied !== doc.applied) { doc.applied = applied; doc.status = applied === null ? 'open' : 'applied'; await this._patchCell(cell, way, applied); if (applied !== null) this.stats.applied++; }
    }
    await this.soda.upsertBy(VOTES, { id: doc.id }, doc);
    return { accepted: true, applied: doc.status === 'applied' ? doc.applied : null, riders: doc.votes.length, needed: this.kMin };
  }

  /** Sets (or removes, kmh null) the corrected limit of one road in the stored cell; a new ETag follows. */
  async _patchCell(cell, way, kmh) {
    const v = await this._load(cell) || this.mem.get(cell);
    if (!v) return false;
    const doc = RoadCellService.unpack(v);
    doc.fx = doc.fx && typeof doc.fx === 'object' ? doc.fx : {};
    if (kmh === null) delete doc.fx[way]; else doc.fx[way] = kmh;
    await this._save(cell, RoadCellService.pack(doc, v.at));
    return true;
  }

  /** After a rebuild from Overpass: the corrections that still hold are put back (never above a tag that appeared). */
  async _applyStoredCorrections(cell, doc) {
    if (!this.soda) return;
    const rows = await this.soda.query(VOTES, { cell, status: 'applied' }, { limit: 200 });
    for (const r of rows) {
      const d = r.value;
      const w = doc.w.find((x) => x.i === d.way);
      if (!w || !validKmh(d.applied)) continue;
      const tag = numericKmh(w.mm) ?? numericKmh(w.ms);
      if (d.byAdmin ? (tag === null || d.applied < tag) : decideCorrection(d.votes, tag, this.kMin) === d.applied) doc.fx[d.way] = d.applied;
    }
  }

  async adminList({ status = '', limit = 200 } = {}) {
    const q = status ? { status: String(status) } : {};
    const rows = await this.soda.query(VOTES, q, { limit: Math.min(500, Math.max(1, Number(limit) || 200)) });
    return rows.map((r) => r.value).sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0)).map((d) => {
      const by = {};
      for (const v of d.votes || []) by[v.kmh] = (by[v.kmh] || 0) + 1;
      return { way: d.way, cell: d.cell, status: d.status, applied: d.applied ?? null, tagKmh: d.tagKmh ?? null, riders: (d.votes || []).length, values: by,
        shown: [...new Set((d.votes || []).map((v) => v.shown).filter(Boolean))], updatedAt: d.updatedAt, byAdmin: !!d.byAdmin,
        osm: `https://www.openstreetmap.org/way/${d.way}` };
    });
  }

  async adminAct(way, { action, kmh } = {}, by = 'admin') {
    const doc = await this._voteDoc(Number(way));
    if (!doc) throw new RoadCellError(404, 'NOT_FOUND', 'No votes for that road.');
    if (action === 'reject') { doc.status = 'rejected'; doc.applied = null; doc.byAdmin = false; await this._patchCell(doc.cell, doc.way, null); }
    else if (action === 'reopen') {
      doc.byAdmin = false;
      doc.applied = decideCorrection(doc.votes, doc.tagKmh, this.kMin); doc.status = doc.applied === null ? 'open' : 'applied';
      await this._patchCell(doc.cell, doc.way, doc.applied);
    } else if (action === 'apply') {
      const v = Number(kmh);
      if (!validKmh(v) || v > MOTORCYCLE_MAX_KMH) throw new RoadCellError(400, 'INVALID', `kmh must be 5 to ${MOTORCYCLE_MAX_KMH}, a multiple of 5.`);
      const { tagKmh } = await this._tagOf(doc.cell, doc.way);
      if (Number.isFinite(tagKmh) && tagKmh !== null && v >= tagKmh) throw new RoadCellError(409, 'ABOVE_OSM_TAG', 'A correction never raises a limit tagged in OpenStreetMap. Fix the tag in OpenStreetMap instead.');
      doc.status = 'applied'; doc.applied = v; doc.byAdmin = true;
      await this._patchCell(doc.cell, doc.way, v);
    } else throw new RoadCellError(400, 'INVALID', 'action must be apply, reject or reopen.');
    doc.reviewedBy = String(by).slice(0, 80); doc.updatedAt = this.clock();
    await this.soda.upsertBy(VOTES, { id: doc.id }, doc);
    return { way: doc.way, status: doc.status, applied: doc.applied };
  }

  /** Account deletion: the rider's votes go; roads are re-decided. */
  async forgetRider(userId) {
    if (!this.soda) return 0;
    const h = this.riderKey(userId);
    const rows = await this.soda.query(VOTES, {}, { limit: 5000 }).catch(() => []); // a small collection: filtered here
    let n = 0;
    for (const r of rows) {
      const d = r.value;
      const before = (d.votes || []).length;
      d.votes = (d.votes || []).filter((v) => v.h !== h);
      if (d.votes.length === before) continue;
      n++;
      if (d.status !== 'rejected' && !d.byAdmin) {
        const a = decideCorrection(d.votes, d.tagKmh, this.kMin);
        if (a !== d.applied) { d.applied = a; d.status = a === null ? 'open' : 'applied'; await this._patchCell(d.cell, d.way, a).catch(() => {}); }
      }
      await this.soda.upsertBy(VOTES, { id: d.id }, d);
    }
    return n;
  }
}

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function attachRoadCells({ app, repo, soda, gate, intel = null, logger = console, audit = null, fetchImpl = null, clock = null, hashKey }) {
  const roads = new RoadCellService({ repo, soda, logger, hashKey,
    url: process.env.ROAD_CELLS_OVERPASS_URL || process.env.POI_OVERPASS_URL || process.env.ESSENTIALS_OVERPASS_URL || null,
    ...(fetchImpl ? { fetchImpl } : {}), ...(clock ? { clock } : {}) });
  const per = (windowMs, limit, tag) => rateLimit({ windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, validate: false,
    keyGenerator: (req) => `${tag}:${req.user?.userId || req.ip}`, message: { error: 'Too many requests. Try again in a moment.', code: 'RATE_LIMITED' } });
  const fail = (res, e) => res.status(e.status || 503).json({ error: e instanceof RoadCellError ? e.message : 'Road data is unavailable.', code: e.code || 'ROADS_UNAVAILABLE' });

  const r = express.Router();
  r.get('/roads', requireAuth(gate), per(60000, 90, 'roads'), wrap(async (req, res) => {
    let out;
    try { out = await roads.cell(req.query.cell); } catch (e) { if (e instanceof RoadCellError) return fail(res, e); throw e; }
    if (out.status === 'pending') {
      return res.status(202).set('Retry-After', String(out.retryAfterS)).set('Cache-Control', 'no-store').json({ pending: true, retryAfterS: out.retryAfterS });
    }
    res.set('ETag', out.etag).set('Vary', 'Accept-Encoding').set('Cache-Control', out.stale ? 'private, max-age=3600' : 'private, max-age=86400')
      .set('X-Road-Cell-Age-S', String(Math.max(0, Math.round((roads.clock() - out.at) / 1000))));
    if (String(req.headers['if-none-match'] || '').split(',').map((s) => s.trim()).includes(out.etag)) return res.status(304).end();
    res.type('application/json');
    if (/\bgzip\b/.test(String(req.headers['accept-encoding'] || ''))) return res.set('Content-Encoding', 'gzip').send(out.gz);
    res.send(zlib.gunzipSync(out.gz));
  }));
  r.post('/limit-corrections', requireAuth(gate), per(24 * 3600000, 30, 'limitvote'), wrap(async (req, res) => {
    // Consent as for the other road intelligence: without "Help make roads safer" nothing is stored.
    const consent = intel ? await intel.consent.get(req.user.userId).catch(() => false) : false;
    if (!consent) return res.status(202).json({ accepted: false, reason: 'NO_CONSENT' });
    try { res.status(202).json(await roads.vote(req.user.userId, req.body)); } catch (e) { if (e instanceof RoadCellError) return fail(res, e); throw e; }
  }));
  app.use('/api/geo', r);

  const a = express.Router();
  a.use(requireAuth(gate), requireAdmin);
  a.get('/limit-corrections', wrap(async (req, res) => res.json({ kMin: roads.kMin, health: roads.health(), items: await roads.adminList({ status: req.query.status, limit: req.query.limit }),
    attribution: 'Road data (C) OpenStreetMap contributors, ODbL' })));
  a.post('/limit-corrections/:way', wrap(async (req, res) => {
    try {
      const by = req.user.email || req.user.userId;
      const out = await roads.adminAct(req.params.way, req.body || {}, by);
      try { audit?.record?.('ROAD_LIMIT_CORRECTION', { by, way: out.way, status: out.status, applied: out.applied }); } catch { /* audit is best effort */ }
      res.json(out);
    } catch (e) { if (e instanceof RoadCellError) return fail(res, e); throw e; }
  }));
  app.use('/api/admin/geo', a);

  if (repo && !repo.__roadVoteCascade && typeof repo.deleteUserCascade === 'function') {
    repo.__roadVoteCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await roads.forgetRider(user.userId).catch(() => {});
      return out;
    };
  }
  return roads;
}

module.exports = { RoadCellService, RoadCellError, attachRoadCells, buildCell, overpassQuery, decideCorrection, numericKmh, simplify, clip, deltaEncode,
  CLASSES, PRECISION, CACHE_KEY, VOTES, MOTORCYCLE_MAX_KMH, MAX_WAYS, MAX_POINTS };
