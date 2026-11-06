'use strict';
/**
 * Map places by grid cell: a lean proxy and cache in front of Overpass (OpenStreetMap).
 *
 * The phone decides which cells it needs (its route corridor ahead, or a small area around the
 * rider), and does all the filtering, fuel type matching, ranking and decluttering itself. The
 * gateway only:
 *   - fetches a cell from Overpass once (one bounded query for every category),
 *   - keeps a whitelist of tags so the answer stays small,
 *   - caches it in memory (LRU) and in geo_cache (durable) for 7 days, shared by every rider,
 *   - spends a small upstream budget per minute and per request; cells over budget come back as
 *     "pending" so the phone asks again later (never a busy loop: the phone waits minutes).
 */
const config = require('./config');

const CELL_DEG = 0.05; // about 5.5 km; must match lib/domain/places/poi_cells.dart
const KEY = /^(-?\d{1,5}):(-?\d{1,5})$/;
const MAX_LAT_IDX = Math.floor(85 / CELL_DEG);
const MAX_LNG_IDX = Math.floor(180 / CELL_DEG);
const TAGS = new Set(['name', 'name:en', 'brand', 'operator', 'amenity', 'shop', 'tourism', 'healthcare', 'craft',
  'emergency', 'opening_hours', 'phone', 'contact:phone', 'healthcare:speciality', 'service:vehicle:tyres',
  'service:motorcycle:repair', 'motorcycle', 'access']);
const TAG_PREFIXES = ['fuel:', 'socket:'];

class PoiCellError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}

/** "latIdx:lngIdx" list from the query string; throws 400 for anything else. */
function parseCells(raw, max) {
  const list = String(raw || '').split(',').map((s) => s.trim()).filter(Boolean);
  const uniq = [...new Set(list)];
  if (!uniq.length || uniq.length > max || list.length > max * 2) throw new PoiCellError(400, 'INVALID_CELLS');
  for (const k of uniq) {
    const m = KEY.exec(k);
    if (!m) throw new PoiCellError(400, 'INVALID_CELLS');
    const la = Number(m[1]), lo = Number(m[2]);
    if (la < -MAX_LAT_IDX || la >= MAX_LAT_IDX || lo < -MAX_LNG_IDX || lo >= MAX_LNG_IDX) throw new PoiCellError(400, 'INVALID_CELLS');
  }
  return uniq;
}

function bboxOf(key) {
  const [la, lo] = key.split(':').map(Number);
  const r = (n) => Math.round(n * 1e5) / 1e5;
  return { s: r(la * CELL_DEG), w: r(lo * CELL_DEG), n: r((la + 1) * CELL_DEG), e: r((lo + 1) * CELL_DEG) };
}

/** One bounded Overpass query per cell. Safety places first, so food never crowds them out. */
function overpassQuery(key) {
  const b = bboxOf(key);
  return `[out:json][timeout:25][bbox:${b.s},${b.w},${b.n},${b.e}];`
    + '(nwr["amenity"~"^(fuel|charging_station|hospital|clinic|doctors|police|pharmacy)$"];'
    + 'nwr["healthcare"~"^(hospital|clinic|centre)$"];'
    + 'nwr["shop"~"^(motorcycle|motorcycle_repair|car_repair|tyres|tyre_repair)$"];'
    + 'nwr["craft"="mechanic"];nwr["service:vehicle:tyres"="yes"];);out center tags 800;'
    + '(nwr["amenity"~"^(restaurant|cafe|fast_food|food_court)$"];);out center tags 300;'
    + '(nwr["tourism"~"^(hotel|motel|hostel|guest_house|chalet|viewpoint)$"];nwr["amenity"~"^(atm|toilets)$"];);out center tags 300;';
}

/** An Overpass element reduced to {i, a, o, t}; null when it has no position. Tags are only trimmed. */
function compact(e) {
  const lat = e.lat ?? e.center?.lat, lng = e.lon ?? e.center?.lon;
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) return null;
  const t = {};
  for (const [k, v] of Object.entries(e.tags || {})) {
    if (typeof v !== 'string') continue;
    if (TAGS.has(k) || TAG_PREFIXES.some((p) => k.startsWith(p))) t[k] = v.slice(0, 120);
  }
  return { i: `${String(e.type || 'n')[0]}${e.id}`, a: Math.round(lat * 1e5) / 1e5, o: Math.round(lng * 1e5) / 1e5, t };
}

class PoiCellService {
  constructor({ repo, url = null, fetchImpl = globalThis.fetch, clock = Date.now, logger = console,
    ttlMs = 7 * 86400000, staleMs = 30 * 86400000, memMax = 1500, maxCells = 12, maxUpstreamPerRequest = 3,
    upstreamPerMin = 12, concurrency = 2, timeoutMs = 25000 } = {}) {
    Object.assign(this, { repo, url, fetch: fetchImpl, clock, log: logger, ttlMs, staleMs, memMax, maxCells,
      maxUpstreamPerRequest, upstreamPerMin, concurrency, timeoutMs });
    this.mem = new Map(); // key -> { at, p }
    this.inflight = new Map();
    this.started = []; // upstream start times in the last minute
    this.running = 0;
    this.waiters = [];
    this.stats = { memHits: 0, diskHits: 0, upstream: 0, upstreamFailed: 0, pending: 0 };
  }

  get configured() { return !!this.url; }

  _remember(k, v) {
    this.mem.delete(k); this.mem.set(k, v);
    while (this.mem.size > this.memMax) this.mem.delete(this.mem.keys().next().value);
  }

  async _slot() {
    if (this.running < this.concurrency) { this.running++; return; }
    await new Promise((r) => this.waiters.push(r));
    this.running++;
  }

  _release() { this.running--; const w = this.waiters.shift(); if (w) w(); }

  _budget() {
    const now = this.clock();
    this.started = this.started.filter((t) => now - t < 60000);
    if (this.started.length >= this.upstreamPerMin) return false;
    this.started.push(now);
    return true;
  }

  async _upstream(key) {
    await this._slot();
    try {
      const endpoints = [this.url, 'https://overpass.kumi.systems/api/interpreter'].filter((u, i, a) => u && a.indexOf(u) === i);
      const body = 'data=' + encodeURIComponent(overpassQuery(key));
      for (const ep of endpoints) {
        try {
          const res = await this.fetch(ep, {
            method: 'POST', body,
            headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': config.providerUserAgent },
            signal: AbortSignal.timeout(this.timeoutMs),
          });
          if (!res.ok) continue;
          const j = await res.json();
          if (!Array.isArray(j?.elements) || j.remark) continue;
          const seen = new Set(), p = [];
          for (const e of j.elements.slice(0, 1500)) {
            const c = compact(e);
            if (c && !seen.has(c.i)) { seen.add(c.i); p.push(c); }
          }
          return { at: this.clock(), p };
        } catch (_) { /* next endpoint */ }
      }
      return null;
    } finally { this._release(); }
  }

  async _fetchCell(key) {
    if (this.inflight.has(key)) return this.inflight.get(key);
    const run = (async () => {
      this.stats.upstream++;
      const v = await this._upstream(key);
      if (!v) { this.stats.upstreamFailed++; return null; }
      this._remember(key, v);
      await this.repo.geoCachePut(`poi:v1:${key}`, v).catch(() => {});
      return v;
    })().finally(() => this.inflight.delete(key));
    this.inflight.set(key, run);
    return run;
  }

  /** Answers every cached cell; fetches at most a few missing ones; the rest are pending. */
  async cells(raw) {
    const keys = parseCells(raw, this.maxCells);
    const now = this.clock();
    const out = {}, pending = [], missing = [];
    for (const k of keys) {
      const m = this.mem.get(k);
      if (m && now - m.at < this.ttlMs) { this._remember(k, m); out[k] = m; this.stats.memHits++; continue; }
      const hit = await this.repo.geoCacheGet(`poi:v1:${k}`).catch(() => null);
      const v = hit?.value;
      if (v && Array.isArray(v.p) && Number.isFinite(v.at) && now - v.at < this.ttlMs) { this._remember(k, v); out[k] = v; this.stats.diskHits++; continue; }
      missing.push({ k, stale: v && Array.isArray(v.p) && Number.isFinite(v.at) && now - v.at < this.staleMs ? v : (m || null) });
    }
    if (missing.length && !this.configured && !Object.keys(out).length && !missing.some((x) => x.stale)) {
      throw new PoiCellError(503, 'PLACES_NOT_CONFIGURED');
    }
    let allowed = this.configured ? this.maxUpstreamPerRequest : 0;
    const jobs = [];
    for (const x of missing) {
      if (allowed > 0 && (this.inflight.has(x.k) || this._budget())) {
        allowed--;
        jobs.push(this._fetchCell(x.k).then((v) => ({ x, v }), () => ({ x, v: null })));
      } else if (x.stale) {
        out[x.k] = { ...x.stale, stale: true }; pending.push(x.k);
      } else pending.push(x.k);
    }
    for (const { x, v } of await Promise.all(jobs)) {
      if (v) out[x.k] = v;
      else { if (x.stale) out[x.k] = { ...x.stale, stale: true }; pending.push(x.k); }
    }
    this.stats.pending += pending.length;
    return { version: 1, cellDeg: CELL_DEG, ttlS: Math.round(this.ttlMs / 1000), cells: out, pending, attribution: '(C) OpenStreetMap contributors' };
  }
}

module.exports = { PoiCellService, PoiCellError, parseCells, bboxOf, overpassQuery, compact, CELL_DEG };
