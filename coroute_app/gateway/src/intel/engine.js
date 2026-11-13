'use strict';
/**
 * Road & safety intelligence engine (round 4; docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md).
 *
 * Runs inside the gateway process with tiny memory and CPU (docs/intelligence/CAPABILITY_v3.56.md):
 *
 *   telemetry (WS positions the gateway already gets) ─┐            ┌─ intel-aggregate (job lease, one node, 5 min)
 *   app event batches (POST /api/intel/events) ────────┼─► intel_raw ┤   folds rows into intel_cells (decayed)
 *   SOS / crash alerts (convoys 'emergency') ──────────┘  (90 days)  └─ intel-daily: retention, pruning, crash brain
 *
 * Only riders who turned on "Help make roads safer" feed anything (ConsentStore). Everyone reads the warnings.
 *
 * Memory bounds (tested in test/intel_memory_356.test.js):
 *   accumulators   ≤ INTEL_MAX_ACCUMULATORS (500) riders on a ride, each ≤ INTEL_MAX_CELLS_PER_RIDE (200) cells
 *                  plus a ≤ 400-point trimming FIFO; an evicted or idle (30 min) accumulator is flushed as one row
 *   raw queue      ≤ 500 rows waiting for the next insert (oldest dropped and counted)
 *   read cache     ≤ 200 geohash-4 tiles per layer set, 10 minutes
 *
 * Cells (collection intel_cells, unique id = `${layer}:${cell}`):
 *   hz  geohash-7 hazards   s: {'type:hb': decayed weighted score}, c: {type: count}
 *   rq  geohash-7 road quality (pothole / rough), same shape
 *   rd  geohash-6 road      dist (m), mov (s), turn (deg), sv[12]/st[12] speed×time / time per time bucket (decayed)
 *   st  geohash-7 stops     n (decayed count), dur (min sum), tod[6], place {name, cat} (cache-only match)
 *   dt  geohash-4 dangerous times  h: {'w18': decayed score}, c: {type: count}
 * Every cell: g4 (read tile), at (decay reference time), rm (month), rs (≤ 64 short rider hashes of month rm, used
 * only for distinct counting, dropped at month change), rk (best distinct count of a past month), upd.
 */
const crypto = require('crypto');
const zlib = require('zlib');
const gh = require('./geohash');
const M = require('./math');
const { intelConfig, collecting } = require('./config');
const { ConsentStore, RideTrimmer, riderHash, riderHashes, hashKeyOf } = require('./privacy');
const CB = require('./crash_brain');

const RAW = 'intel_raw';
const CELLS = 'intel_cells';
const META = 'intel_meta';
const TRAIN = 'intel_crash_train';

/** Hazard signal weights (crash / SOS above hard brakes). */
const WEIGHTS = { crash: 5, sos: 4, skid: 3, swerve: 2, hard_brake: 1, pothole: 1, rough: 0.5 };
const HAZARD_TYPES = new Set(['crash', 'sos', 'skid', 'swerve', 'hard_brake']);
const ROAD_TYPES = new Set(['pothole', 'rough']);
const EVENT_TYPES = new Set([...HAZARD_TYPES, ...ROAD_TYPES]);
const RS_CAP = 64;
const RAW_QUEUE_MAX = 500;
const IDLE_MS = 30 * 60000;
const MOVING_KMH = 8;
const STOP_RADIUS_M = 60;
const STOP_MIN_MS = 4 * 60000;
const STOP_MAX_MS = 90 * 60000;

const r5 = (x) => Math.round(x * 1e5) / 1e5;
const short = (rh) => String(rh).slice(0, 10);

class IntelEngine {
  constructor({ soda, repo = null, logger = console, clock = Date.now, jwtSecret = '', poiCells = null, configFn = intelConfig }) {
    Object.assign(this, { soda, repo, log: logger, clock, poiCells, cfgFn: configFn });
    // v3.56: INTEL_CONSENT_TTL_MS (default 60 s): how long a node trusts its cached consent answer when the mirror
    // link (which drops it at once on a change) is down. Longer = fewer database reads per live rider.
    this.consent = new ConsentStore({ soda, logger, clock, ttlMs: Math.max(5000, Number(process.env.INTEL_CONSENT_TTL_MS) || 60000) });
    this.jwtSecret = jwtSecret;
    this.acc = new M.Lru(this.cfg.maxAccumulators); // `${gid}|${uid}` -> accumulator
    this.rawQueue = [];
    this.cache = new M.Lru(200); // `${layer}:${g4}` -> { at, cells }
    this.metaCache = { at: 0, value: null };
    this.stats = { telemetry: 0, committed: 0, rowsQueued: 0, rowsDropped: 0, rowsWritten: 0, flushes: 0, evicted: 0,
      eventsAccepted: 0, eventsRejected: 0, aggregateRuns: 0, rowsFolded: 0, cellsWritten: 0, lastAggregateAt: 0, lastDailyAt: 0 };
    this.timers = [];
    this._flushing = null;
  }

  get cfg() { return this.cfgFn(); }

  /** The telemetry hot path reads its settings at most once a second (process.env reads are not free). */
  get _hotCfg() {
    const t = this.clock();
    if (!this._hot || t - this._hotAt > 1000 || t < this._hotAt) { this._hot = this.cfgFn(); this._hotAt = t; }
    return this._hot;
  }
  get key() { return (this._key ||= hashKeyOf(this.cfg, this.jwtSecret, this.log)); }
  _rh(userId, t) { return riderHash(this.key, userId, M.monthKey(t)); }

  async init() {
    for (const c of [RAW, CELLS, META, TRAIN]) await this.soda.ensureCollection(c);
    await this.soda.ensureIndex(CELLS, { name: `${CELLS}_id_ux`, unique: true, fields: [{ path: 'id' }] });
    await this.soda.ensureIndex(CELLS, { name: `${CELLS}_tile_ix`, fields: [{ path: 'layer' }, { path: 'g4' }] });
    await this.soda.ensureIndex(RAW, { name: `${RAW}_p_ix`, fields: [{ path: 'p', datatype: 'number' }, { path: 't', datatype: 'number' }] });
    await this.soda.ensureIndex(RAW, { name: `${RAW}_rh_ix`, fields: [{ path: 'rh' }] });
    await this.soda.ensureIndex(META, { name: `${META}_id_ux`, unique: true, fields: [{ path: 'id' }] });
    await this.consent.init();
  }

  /** Per-node timers: the raw queue is written every 30 s, idle accumulators are closed every 5 min. */
  start() {
    const t1 = setInterval(() => { this.flushRaw().catch(() => {}); }, 30000);
    const t2 = setInterval(() => { this.sweepIdle(); }, 5 * 60000);
    for (const t of [t1, t2]) { t.unref?.(); this.timers.push(t); }
  }

  /** Leased jobs: aggregates are written by the lease holder only (both nodes read). */
  startJobs(lease) {
    const min = 60000;
    lease.run('intel-aggregate', this.cfg.jobEveryMin * min, ({ signal } = {}) => this.aggregate({ signal }), { firstDelayMs: 2 * min });
    lease.run('intel-daily', 24 * 60 * min, ({ signal } = {}) => this.daily({ signal }), { firstDelayMs: 25 * min });
  }

  async stop() {
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
    for (const k of [...this.acc.keys()]) this._closeAcc(k, { ended: true });
    await this.flushRaw().catch(() => {});
  }

  // ================================================================== ingest: telemetry (live node, synchronous, cheap)
  /** convoys 'telemetry' (groupId, rider). Never throws, never awaits. */
  onTelemetry(groupId, rider) {
    try {
      const cfg = this._hotCfg;
      if (!collecting(cfg) || !rider || !rider.userId) return;
      this.stats.telemetry++;
      const lat = Number(rider.lat), lng = Number(rider.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng) || (lat === 0 && lng === 0)) return;
      const k = `${groupId}|${rider.userId}`;
      const on = this.consent.peek(rider.userId);
      if (on !== true) { if (on === false && this.acc.has(k)) this._closeAcc(k, { ended: true, discard: true }); return; }
      const t = this.clock();
      let a = this.acc.get(k);
      if (!a) {
        a = { k, uid: rider.userId, gid: groupId, trim: new RideTrimmer({ trimM: cfg.trimM }), last: null, heading: null,
          cells: new Map(), stops: [], still: null, startedAt: t, lastAt: t, chunkAt: t };
        for (const [ek, ea] of this.acc.set(k, a)) { this.stats.evicted++; this._closeAcc(ek, { evicted: true }, ea); }
      }
      a.lastAt = t;
      for (const p of a.trim.push({ lat, lng, t, v: Number(rider.speedKmh) || 0 })) this._commit(a, p);
      if (a.cells.size >= cfg.maxCellsPerRide) this._flushAcc(a);
    } catch (e) {
      this.log.warn?.(`[intel] telemetry: ${e.message}`);
    }
  }

  /** One trimmed point: road counters and stop detection. */
  _commit(a, p) {
    this.stats.committed++;
    const q = a.last;
    a.last = p;
    // Stop detection on the committed (already trimmed) track.
    if (a.still) {
      const d0 = M.haversine(a.still.lat, a.still.lng, p.lat, p.lng);
      if (d0 <= STOP_RADIUS_M) { a.still.lastT = p.t; } else {
        const end = Math.max(a.still.lastT, p.t - (d0 / 8.3) * 1000); // a phone with a distance filter sends nothing while parked
        const dur = end - a.still.t;
        if (dur >= STOP_MIN_MS && dur <= STOP_MAX_MS && a.stops.length < 50) {
          a.stops.push([gh.encode(a.still.lat, a.still.lng, 7), Math.round(dur / 60000), M.istParts(a.still.t).hour]);
        }
        a.still = null;
      }
    }
    if (!q) { a.still = { lat: p.lat, lng: p.lng, t: p.t, lastT: p.t }; return; }
    const dt = (p.t - q.t) / 1000;
    if (dt <= 0) return;
    const d = M.haversine(q.lat, q.lng, p.lat, p.lng);
    if (dt > 120) { a.heading = null; if (!a.still && d <= STOP_RADIUS_M) a.still = { lat: q.lat, lng: q.lng, t: q.t, lastT: p.t }; return; }
    if (d / dt > 70) return; // > 250 km/h: a bad fix
    const kmh = (d / dt) * 3.6;
    if (kmh < 3 && !a.still) a.still = { lat: q.lat, lng: q.lng, t: q.t, lastT: p.t };
    if (kmh < MOVING_KMH) return;
    const mid = gh.encode((q.lat + p.lat) / 2, (q.lng + p.lng) / 2, 6);
    const tb = M.timeBucket(p.t);
    const key = `${mid}|${tb}`;
    let c = a.cells.get(key);
    if (!c) { c = [0, 0, 0, 0]; a.cells.set(key, c); }
    c[0] += d; c[1] += dt; c[3] += kmh * dt;
    if (d >= 15 && kmh >= 20) {
      const h = M.bearing(q.lat, q.lng, p.lat, p.lng);
      if (a.heading !== null) { const turn = M.angleDiff(a.heading, h); if (turn < 120) c[2] += turn; }
      a.heading = h;
    }
  }

  /** Writes the accumulator's counters as one raw row and clears them (the ride goes on). */
  _flushAcc(a) {
    if (!a.cells.size && !a.stops.length) return;
    const t = this.clock();
    const c = [];
    for (const [key, v] of a.cells) {
      const [g6, tb] = key.split('|');
      if (v[0] < 20) continue;
      c.push([g6, Number(tb), Math.round(v[0]), Math.round(v[1]), Math.round(v[2]), Math.round(v[3])]);
    }
    const s = a.stops.slice();
    a.cells.clear(); a.stops = [];
    if (!c.length && !s.length) return;
    // Consent is checked again when the row is written (a rider who switched off mid-ride contributes nothing).
    this._queueRaw({ uid: a.uid, k: 'ride', t: a.chunkAt, te: t, d: { c, s } });
    a.chunkAt = t;
    this.stats.flushes++;
  }

  _closeAcc(k, { discard = false } = {}, evicted = null) {
    const a = evicted || this.acc.peek(k);
    if (!a) return;
    this.acc.delete(k);
    a.trim.finish(); // the last 300 m are never counted
    if (!discard) this._flushAcc(a);
  }

  /** convoys 'roomEnded': every rider's ride in that room ends (their last 300 m are dropped). */
  onRoomEnded(groupId) {
    for (const k of [...this.acc.keys()]) if (k.startsWith(`${groupId}|`)) this._closeAcc(k, { ended: true });
  }

  /** A rider left a ride. */
  onRiderLeft(groupId, userId) { this._closeAcc(`${groupId}|${userId}`, { ended: true }); }

  sweepIdle(now = this.clock()) {
    for (const [k, a] of [...this.acc.entries()]) if (now - a.lastAt > IDLE_MS) this._closeAcc(k, { ended: true });
  }

  // ================================================================== ingest: SOS / crash alerts (server-observed)
  /** convoys 'emergency' (gid, alert, kind): a RAISED SOS or crash alert of a consenting rider is a hazard signal. */
  onEmergency(groupId, alert, kind) {
    try {
      if (kind !== 'RAISED' || !alert || !alert.userId || !collecting(this.cfg)) return;
      const lat = Number(alert.lat), lng = Number(alert.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng) || (lat === 0 && lng === 0)) return;
      const src = String(alert.source || '');
      if (['MEMBER_REPORT', 'NEARBY_REPORT'].includes(src)) return; // reported by someone else: not this rider's signal
      const ty = src === 'CRASH_AUTO' || src === 'NEED_HELP' || src === 'WEARABLE' || /CRASH|RIDER_DOWN/.test(String(alert.type || '')) ? 'crash' : 'sos';
      const a = this.acc.peek(`${groupId}|${alert.userId}`);
      // Start trimming applies (end trimming does not: a crash often ends the ride where it happened; documented).
      if (a && !a.trim.allowed(lat, lng)) return;
      if (!a) return; // no consented, trimmed ride seen yet (e.g. an SOS in the first 300 m): not counted
      const t = Number(alert.raisedAt || alert.createdAt) || this.clock();
      const hb = Number.isFinite(Number(alert.heading)) ? M.headingBucket(alert.heading) : -1;
      this._queueRaw({ uid: alert.userId, k: 'evs', t, d: { e: [[ty, gh.encode(lat, lng, 7), hb, M.speedBucket(alert.speedKmh), t, 1]] } });
    } catch (e) {
      this.log.warn?.(`[intel] emergency: ${e.message}`);
    }
  }

  // ================================================================== ingest: app event batches
  /**
   * POST /api/intel/events { events: [{ type, gh, hb, sb, how?, ts, conf? }] } (the app trims the first / last 300 m and
   * its privacy zones before sending). Consent is required; without it nothing is stored (202 with accepted 0).
   */
  async ingestEvents(userId, events, { now = this.clock() } = {}) {
    const cfg = this.cfg;
    if (!collecting(cfg)) return { accepted: 0, reason: 'OFF' };
    if (!(await this.consent.get(userId))) return { accepted: 0, reason: 'NO_CONSENT' };
    const list = Array.isArray(events) ? events.slice(0, 200) : [];
    const out = [];
    const perCell = new Map();
    for (const e of list) {
      if (!e || typeof e !== 'object') { this.stats.eventsRejected++; continue; }
      const ty = String(e.type || '');
      const g7 = String(e.gh || '');
      const ts = Number(e.ts);
      if (!EVENT_TYPES.has(ty) || ty === 'sos' || ty === 'crash' || !gh.isValid(g7) || g7.length !== 7 || !Number.isFinite(ts)
        || ts > now + 10 * 60000 || ts < now - cfg.rawDays * M.DAY) { this.stats.eventsRejected++; continue; }
      // One rider adds at most 3 events of a type to one cell per batch (no flooding a spot).
      const pc = `${ty}:${g7}`;
      const n = (perCell.get(pc) || 0) + 1;
      perCell.set(pc, n);
      if (n > 3) { this.stats.eventsRejected++; continue; }
      const hb = Number.isInteger(e.hb) && e.hb >= 0 && e.hb <= 7 ? e.hb : -1;
      const sb = Number.isInteger(e.sb) && e.sb >= 0 && e.sb <= 4 ? e.sb : -1;
      const conf = Number.isFinite(Number(e.conf)) ? Math.min(1, Math.max(0.1, Number(e.conf))) : 1;
      out.push([ty, g7, hb, sb, Math.round(ts), Math.round(conf * 100) / 100]);
    }
    if (out.length) this._queueRaw({ uid: userId, k: 'evs', t: now, d: { e: out } });
    this.stats.eventsAccepted += out.length;
    return { accepted: out.length };
  }

  /**
   * POST /api/intel/crash { id, features, outcome } and POST /api/intel/crash/feedback { id, real }.
   * Crash alarm features (no position) for the crash brain; consenting riders only (documented owner decision).
   */
  async ingestCrash(userId, body, { now = this.clock() } = {}) {
    if (!collecting(this.cfg)) return { accepted: false, reason: 'OFF' };
    if (!(await this.consent.get(userId))) return { accepted: false, reason: 'NO_CONSENT' };
    const id = String(body?.id || '');
    if (!/^[A-Za-z0-9_-]{8,64}$/.test(id)) return { accepted: false, reason: 'INVALID' };
    const f = CB.cleanFeatures(body?.features);
    const o = ['ok', 'sent'].includes(body?.outcome) ? body.outcome : null;
    if (!f || !o) return { accepted: false, reason: 'INVALID' };
    const shadow = await this._shadowVerdict(f).catch(() => null);
    this._queueRaw({ uid: userId, k: 'crash', t: now, cid: id, d: { f, o, ...(shadow ? { sh: shadow } : {}) } });
    await this.flushRaw();
    return { accepted: true, shadow: shadow ? { wouldStillAlarm: shadow.fires } : null };
  }

  async crashFeedback(userId, body) {
    const id = String(body?.id || '');
    if (!/^[A-Za-z0-9_-]{8,64}$/.test(id) || typeof body?.real !== 'boolean') return { updated: false, reason: 'INVALID' };
    await this.flushRaw();
    const hashes = riderHashes(this.key, userId, this.clock(), 2).map((x) => x.rh);
    const row = await this.soda.findOne(RAW, { cid: id, rh: { $in: hashes } });
    if (!row) return { updated: false, reason: 'NOT_FOUND' };
    const v = row.value;
    v.d = { ...(v.d || {}), fb: body.real ? 'real' : 'false' };
    if (v.p === 1) v.p = 0; // folded again (the training copy is replaced by id)
    await this.soda.replace(RAW, row.key, v);
    return { updated: true };
  }

  async _shadowVerdict(f) {
    const meta = await this._meta('crash_brain');
    const g = CB.modelGroup(f.dm);
    const res = meta?.groups?.[g]?.ready ? meta.groups[g] : meta?.global;
    if (!res || !res.ready || !res.model) return null;
    const s = res.suggestion?.impactScale || 1;
    return { p: Math.round(CB.predict(res.model, f) * 1000) / 1000, scale: s, fires: CB.stillFires(f, s), v: meta.version || 0 };
  }

  // ================================================================== raw rows (any node: insert only)
  _queueRaw(row) {
    this.rawQueue.push(row);
    this.stats.rowsQueued++;
    while (this.rawQueue.length > RAW_QUEUE_MAX) { this.rawQueue.shift(); this.stats.rowsDropped++; }
    if (this.rawQueue.length >= 50) this.flushRaw().catch(() => {});
  }

  /** Writes the queued rows (consent re-checked per rider; the user id is replaced by the monthly hash). */
  flushRaw() {
    if (this._flushing) return this._flushing;
    this._flushing = (async () => {
      while (this.rawQueue.length) {
        const batch = this.rawQueue.splice(0, 50);
        const docs = [];
        for (const r of batch) {
          if (!(await this.consent.get(r.uid).catch(() => false))) continue;
          const m = M.monthKey(r.t);
          docs.push({ k: r.k, rh: riderHash(this.key, r.uid, m), m, t: r.t, ...(r.te ? { te: r.te } : {}), ...(r.cid ? { cid: r.cid } : {}), p: 0, d: r.d });
        }
        if (!docs.length) continue;
        try {
          await this.soda.insertMany(RAW, docs);
          this.stats.rowsWritten += docs.length;
        } catch (e) {
          this.log.warn?.(`[intel] raw write failed: ${e.message}`);
          this.stats.rowsDropped += docs.length;
          break;
        }
      }
    })().finally(() => { this._flushing = null; });
    return this._flushing;
  }

  // ================================================================== aggregation (lease holder only)
  /**
   * Folds unprocessed raw rows into the cells: ≤ jobMaxCells cell writes per run, yields to live traffic every 10 rows.
   * Rows marked for deletion (p = 2) are subtracted (decay-aware, exact for the scores) and removed.
   */
  async aggregate({ signal, now = this.clock() } = {}) {
    const cfg = this.cfg;
    if (cfg.killed) return { folded: 0, killed: true };
    await this.flushRaw();
    const rows = [
      ...(await this.soda.query(RAW, { p: 2 }, { limit: 100 })),
      ...(await this.soda.query(RAW, { p: 0 }, { limit: 200, orderBy: [{ path: 't', datatype: 'number', order: 'asc' }] })),
    ];
    const ctx = { now, cells: new Map(), dirty: new Set(), budget: cfg.jobMaxCells, cfg };
    const done = [];
    let i = 0;
    for (const row of rows) {
      if (signal?.aborted) break;
      const sign = row.value.p === 2 ? -1 : 1;
      const ids = this._cellIdsOf(row.value);
      if (ctx.dirty.size + ids.length > ctx.budget && done.length) break; // next run
      await this._load(ctx, ids);
      this._fold(ctx, row.value, sign);
      done.push(row);
      if (++i % 10 === 0) await M.yieldNow();
    }
    await this._writeCells(ctx, signal);
    for (const row of done) {
      if (row.value.p === 2) await this.soda.remove(RAW, row.key).catch(() => {});
      else await this.soda.replace(RAW, row.key, { ...row.value, p: 1 }).catch(() => {});
      if (row.value.k === 'crash' && row.value.p !== 2) await this._trainCopy(row.value).catch(() => {});
    }
    this.stats.aggregateRuns++; this.stats.rowsFolded += done.length; this.stats.lastAggregateAt = now;
    if (done.length) this.cache.clear();
    await this._setMeta('status', { lastAggregateAt: now, lastFolded: done.length, lastCells: ctx.dirty.size, node: process.pid }).catch(() => {});
    return { folded: done.length, cells: ctx.dirty.size };
  }

  _cellIdsOf(row) {
    const ids = new Set();
    if (row.k === 'evs') {
      for (const [ty, g7] of (row.d?.e || [])) {
        if (HAZARD_TYPES.has(ty)) { ids.add(`hz:${g7}`); ids.add(`dt:${g7.slice(0, 4)}`); }
        else if (ROAD_TYPES.has(ty)) ids.add(`rq:${g7}`);
      }
    } else if (row.k === 'ride') {
      for (const c of (row.d?.c || [])) ids.add(`rd:${c[0]}`);
      for (const s of (row.d?.s || [])) ids.add(`st:${s[0]}`);
    }
    return [...ids];
  }

  async _load(ctx, ids) {
    const need = ids.filter((id) => !ctx.cells.has(id));
    for (let i = 0; i < need.length; i += 50) {
      const part = need.slice(i, i + 50);
      const rows = await this.soda.query(CELLS, { id: { $in: part } }, { limit: 100 });
      const got = new Map(rows.map((r) => [r.value.id, r]));
      for (const id of part) {
        const r = got.get(id);
        if (r) ctx.cells.set(id, { key: r.key, v: r.value });
        else {
          const [layer, cell] = id.split(':');
          const c = gh.center(cell);
          ctx.cells.set(id, { key: null, v: { id, layer, cell, g4: cell.slice(0, 4), lat: c.lat, lng: c.lng, at: ctx.now, rm: null, rs: [], rk: 0, n: 0 } });
        }
      }
    }
  }

  /** Distinct riders this month; a new month keeps only the best past count. */
  _rider(v, row, sign) {
    if (sign < 0) { const s = short(row.rh); v.rs = (v.rs || []).filter((x) => x !== s); return; }
    if (!v.rm || row.m > v.rm) { v.rk = Math.max(v.rk || 0, (v.rs || []).length); v.rs = []; v.rm = row.m; }
    if (row.m === v.rm) { const s = short(row.rh); if (!v.rs.includes(s) && v.rs.length < RS_CAP) v.rs.push(s); }
    else v.rk = Math.max(v.rk || 0, 1);
  }

  _decayAll(v, now, H) {
    const f = M.decay(1, v.at || now, now, H);
    if (f === 1) return;
    const scale = (o) => { if (o) for (const k of Object.keys(o)) o[k] *= f; };
    scale(v.s); scale(v.h);
    for (const k of ['dist', 'mov', 'turn', 'n', 'dur']) if (v[k]) v[k] *= f;
    for (const k of ['sv', 'st', 'tod']) if (Array.isArray(v[k])) v[k] = v[k].map((x) => x * f);
    v.at = now;
  }

  _fold(ctx, row, sign) {
    const H = ctx.cfg.halfLifeDays;
    const now = ctx.now;
    const touch = (id) => {
      const c = ctx.cells.get(id);
      this._decayAll(c.v, now, H);
      this._rider(c.v, row, sign); // idempotent per row and cell
      ctx.dirty.add(id);
      c.v.upd = now;
      return c.v;
    };
    const clamp0 = (x) => (x < 1e-9 ? 0 : x);
    if (row.k === 'evs') {
      for (const [ty, g7, hb, , ts, conf] of (row.d?.e || [])) {
        const w = (WEIGHTS[ty] || 1) * (conf || 1) * M.decay(1, ts, now, H) * sign;
        const layer = HAZARD_TYPES.has(ty) ? 'hz' : ROAD_TYPES.has(ty) ? 'rq' : null;
        if (!layer) continue;
        const v = touch(`${layer}:${g7}`);
        v.s = v.s || {}; v.c = v.c || {};
        const key = `${ty}:${hb}`;
        v.s[key] = clamp0((v.s[key] || 0) + w);
        v.c[ty] = Math.max(0, (v.c[ty] || 0) + sign);
        v.n = Math.max(0, (v.n || 0) + sign);
        if (layer === 'hz') {
          const d = touch(`dt:${g7.slice(0, 4)}`);
          d.h = d.h || {}; d.c = d.c || {};
          const slot = `${M.dayType(ts)}${M.istParts(ts).hour}`;
          d.h[slot] = clamp0((d.h[slot] || 0) + w);
          d.c[ty] = Math.max(0, (d.c[ty] || 0) + sign);
        }
      }
    } else if (row.k === 'ride') {
      const f = M.decay(1, row.te || row.t, now, H) * sign;
      for (const [g6, tb, dist, mov, turn, svt] of (row.d?.c || [])) {
        const v = touch(`rd:${g6}`);
        v.sv = v.sv || new Array(12).fill(0); v.st = v.st || new Array(12).fill(0);
        v.dist = clamp0((v.dist || 0) + dist * f); v.mov = clamp0((v.mov || 0) + mov * f); v.turn = clamp0((v.turn || 0) + turn * f);
        if (tb >= 0 && tb < 12) { v.sv[tb] = clamp0(v.sv[tb] + svt * f); v.st[tb] = clamp0(v.st[tb] + mov * f); }
      }
      for (const [g7, durMin, hour] of (row.d?.s || [])) {
        const v = touch(`st:${g7}`);
        v.tod = v.tod || new Array(6).fill(0);
        v.n = clamp0((v.n || 0) + f); v.dur = clamp0((v.dur || 0) + durMin * f);
        const b = Math.floor((Number(hour) || 0) / 4);
        v.tod[b] = clamp0(v.tod[b] + f);
      }
    }
  }

  async _writeCells(ctx, signal) {
    let i = 0;
    const pending = [];
    for (const id of ctx.dirty) {
      if (signal?.aborted) break;
      const c = ctx.cells.get(id);
      const v = { ...c.v };
      for (const k of ['dist', 'mov', 'turn', 'n', 'dur']) if (typeof v[k] === 'number') v[k] = Math.round(v[k] * 1000) / 1000;
      const op = c.key ? this.soda.replace(CELLS, c.key, v) : this.soda.insert(CELLS, v).then((key) => { c.key = key; });
      pending.push(op.catch((e) => this.log.warn?.(`[intel] cell write ${id}: ${e.message}`)));
      if (pending.length >= 4) { await Promise.all(pending.splice(0)); }
      if (++i % 20 === 0) await M.yieldNow();
    }
    await Promise.all(pending);
    this.stats.cellsWritten += i;
  }

  /** Crash rows get a de-identified training copy (no rider hash, no time finer than the month, no position). */
  async _trainCopy(row) {
    const y = CB.labelOf(row.d?.o, row.d?.fb);
    const doc = { id: crypto.createHash('sha1').update(`${row.cid}|${row.rh}`).digest('hex').slice(0, 20), m: row.m,
      f: row.d.f, y, g: CB.modelGroup(row.d.f?.dm), ...(row.d?.sh ? { sh: row.d.sh } : {}) };
    const hit = await this.soda.findOne(TRAIN, { id: doc.id });
    if (hit) await this.soda.replace(TRAIN, hit.key, doc); else await this.soda.insert(TRAIN, doc);
  }

  // ================================================================== daily: retention, pruning, crash brain
  async daily({ signal, now = this.clock() } = {}) {
    const cfg = this.cfg;
    const purged = await this.purgeRaw(now);
    let pruned = 0;
    if (!signal?.aborted) pruned = await this.pruneCells(now, signal);
    let brain = null;
    if (!signal?.aborted) brain = await this.trainCrashBrain({ now }).catch((e) => { this.log.warn?.(`[intel] crash brain: ${e.message}`); return null; });
    if (!signal?.aborted && this.poiCells) await this.tagStops({ now, signal }).catch(() => {});
    const counts = await this._counts().catch(() => null);
    this.stats.lastDailyAt = now;
    await this._setMeta('status', { lastDailyAt: now, purged, pruned, counts, kMin: cfg.kMin, rawDays: cfg.rawDays }).catch(() => {});
    return { purged, pruned, brain: brain ? { total: brain.total } : null, counts };
  }

  /** Raw rows older than INTEL_RAW_DAYS (90) are deleted; training copies older than 2 years too. */
  async purgeRaw(now = this.clock()) {
    const cut = now - this.cfg.rawDays * M.DAY;
    const n = await this.soda.removeWhere(RAW, { t: { $lt: cut } });
    const oldMonth = M.monthKey(now - 730 * M.DAY);
    await this.soda.removeWhere(TRAIN, { m: { $lt: oldMonth } }).catch(() => 0);
    return n;
  }

  /** Cells whose every counter decayed to almost nothing are removed. */
  async pruneCells(now = this.clock(), signal) {
    const H = this.cfg.halfLifeDays;
    let removed = 0;
    const old = now - 2 * H * M.DAY;
    const rows = await this.soda.query(CELLS, { upd: { $lt: old } }, { limit: 500 });
    for (const r of rows) {
      if (signal?.aborted) break;
      const v = r.value;
      this._decayAll(v, now, H);
      const total = Object.values(v.s || {}).reduce((a, b) => a + b, 0) + Object.values(v.h || {}).reduce((a, b) => a + b, 0) + (v.dist || 0) / 1000 + (v.n || 0);
      if (total < 0.05) { await this.soda.remove(CELLS, r.key).catch(() => {}); removed++; }
    }
    return removed;
  }

  async _counts() {
    const layers = ['hz', 'rq', 'rd', 'st', 'dt'];
    const out = {};
    for (const l of layers) out[l] = (await this.soda.query(CELLS, { layer: l }, { limit: 1000, fields: 'id' })).length;
    out.raw = (await this.soda.query(RAW, {}, { limit: 1000, fields: 'id' })).length;
    return out; // capped at 1000 each: "1000" means "1000 or more" on the health page
  }

  // ================================================================== crash brain
  async trainCrashBrain({ now = this.clock() } = {}) {
    const rows = [];
    for (let page = 0; page < 40; page++) {
      const part = await this.soda.query(TRAIN, {}, { limit: 500, offset: page * 500 });
      rows.push(...part.map((r) => r.value));
      if (part.length < 500) break;
    }
    const res = CB.trainAll(rows, { minLabels: this.cfg.crashBrainMinLabels });
    const prev = (await this._meta('crash_brain')) || {};
    const version = (prev.version || 0) + 1;
    const shadow = { total: 0, wouldStillAlarm: 0, wouldSkipFalse: 0, wouldSkipReal: 0 };
    for (const r of rows) {
      if (!r.sh) continue;
      shadow.total++;
      if (r.sh.fires) shadow.wouldStillAlarm++;
      else if (r.y === 1) shadow.wouldSkipReal++;
      else shadow.wouldSkipFalse++;
    }
    await this._setMeta('crash_brain', { ...prev, version, trainedAt: now, global: res.global, groups: res.groups, total: res.total, shadow,
      approved: prev.approved || null, history: prev.history || [] });
    this.metaCache.value = null;
    return res;
  }

  /** MASTER_ADMIN approval of the current version (only when CRASH_BRAIN_MODE=approved). */
  async approveCrashBrain({ version, by }) {
    if (this.cfg.crashBrainMode !== 'approved') { const e = new Error('Crash brain runs in shadow mode. Set CRASH_BRAIN_MODE=approved to allow approvals.'); e.status = 409; e.code = 'SHADOW_MODE'; throw e; }
    const meta = await this._meta('crash_brain');
    if (!meta || meta.version !== Number(version)) { const e = new Error('That version is not the latest training.'); e.status = 409; e.code = 'VERSION_CONFLICT'; throw e; }
    const params = { global: meta.global?.ready ? { impactScale: Math.min(CB.SCALE_MAX, meta.global.suggestion.impactScale) } : null, groups: {} };
    for (const [g, r] of Object.entries(meta.groups || {})) if (r.ready && r.suggestion) params.groups[g] = { impactScale: Math.min(CB.SCALE_MAX, r.suggestion.impactScale) };
    if (!params.global && !Object.keys(params.groups).length) { const e = new Error('No group has 200 labelled alarms yet.'); e.status = 409; e.code = 'NOT_ENOUGH_LABELS'; throw e; }
    const approved = { version: meta.version, params, approvedBy: by || 'admin', approvedAt: this.clock() };
    const history = [...(meta.history || []), ...(meta.approved ? [meta.approved] : [])].slice(-10);
    await this._setMeta('crash_brain', { ...meta, approved, history });
    this.metaCache.value = null;
    return approved;
  }

  /** Back to the previous approval, or to none (the app's defaults). */
  async rollbackCrashBrain({ by }) {
    const meta = (await this._meta('crash_brain')) || {};
    const history = [...(meta.history || [])];
    const approved = history.pop() || null;
    await this._setMeta('crash_brain', { ...meta, approved, history, rolledBackBy: by || 'admin', rolledBackAt: this.clock() });
    this.metaCache.value = null;
    return approved;
  }

  /** What the app gets: params only when approved mode and an approval exist; always with version and checksum. */
  async crashParams(deviceModel) {
    const cfg = this.cfg;
    const group = CB.modelGroup(deviceModel);
    const meta = await this._meta('crash_brain').catch(() => null);
    const approved = cfg.crashBrainMode === 'approved' && !cfg.killed ? meta?.approved : null;
    const params = approved ? CB.paramsFor(approved, group) : null;
    const version = params ? approved.version : 0;
    return { mode: cfg.crashBrainMode, version, group, params, checksum: CB.checksum(version, group, params) };
  }

  // ================================================================== reads (both nodes; cached per geohash-4 tile)
  async _tile(layer, g4) {
    const k = `${layer}:${g4}`;
    const hit = this.cache.get(k);
    const now = this.clock();
    if (hit && now - hit.at < this.cfg.cacheTtlMs) return hit.cells;
    const cells = [];
    for (let page = 0; page < 4; page++) {
      const rows = await this.soda.query(CELLS, { layer, g4 }, { limit: 1000, offset: page * 1000 });
      cells.push(...rows.map((r) => r.value));
      if (rows.length < 1000) break;
    }
    this.cache.set(k, { at: now, cells });
    return cells;
  }

  /** Distinct riders of a cell for k-anonymity: this month's set or the best past month. */
  riders(v, now = this.clock()) {
    const cur = v.rm === M.monthKey(now) ? (v.rs || []).length : Math.max((v.rs || []).length, 0);
    return Math.max(cur, v.rk || 0);
  }

  /** Tiles for a bbox (≤ 64 geohash-4 tiles) or a list of geohash-4 ids. Throws 400 otherwise. */
  tilesOf({ bbox, tiles }) {
    if (Array.isArray(tiles) && tiles.length) {
      const t = [...new Set(tiles.map(String))].filter((x) => gh.isValid(x) && x.length === 4);
      if (!t.length || t.length > 64) throw Object.assign(new Error('Ask for 1 to 64 tiles.'), { status: 400, code: 'INVALID_TILES' });
      return t;
    }
    const t = bbox ? gh.cover(bbox, 4, 64) : null;
    if (!t) throw Object.assign(new Error('The area is too large or invalid.'), { status: 400, code: 'INVALID_BBOX' });
    return t;
  }

  async _cellsIn(layer, area, now = this.clock()) {
    if (!collecting(this.cfg)) return []; // switched off or killed: warnings answer empty
    if (area.all) {
      // Admin only (India-wide map): walk the layer in pages, capped at 10,000 cells, no cache.
      const out = [];
      for (let page = 0; page < 10; page++) {
        const rows = await this.soda.query(CELLS, { layer }, { limit: 1000, offset: page * 1000 });
        for (const r of rows) if (!area.bbox || gh.inBbox(r.value, area.bbox)) out.push(r.value);
        if (rows.length < 1000) break;
      }
      return out;
    }
    const tiles = this.tilesOf(area);
    const out = [];
    for (const t of tiles) for (const v of await this._tile(layer, t)) {
      if (area.bbox && !gh.inBbox(v, area.bbox)) continue;
      out.push(v);
    }
    return out;
  }

  _scored(v, now) {
    const f = M.decay(1, v.at || now, now, this.cfg.halfLifeDays);
    const byType = {}, byDir = new Array(8).fill(0);
    let total = 0, undirected = 0;
    for (const [key, s] of Object.entries(v.s || {})) {
      const [ty, hbS] = key.split(':');
      const x = s * f;
      total += x; byType[ty] = (byType[ty] || 0) + x;
      const hb = Number(hbS);
      if (hb >= 0 && hb < 8) byDir[hb] += x; else undirected += x;
    }
    return { total, byType, byDir, undirected };
  }

  /** Hazard hotspots above k-min and the score threshold. Public answer: no counts, no hashes. */
  async hazards(area, { now = this.clock(), minScore = 3, admin = false } = {}) {
    const k = this.cfg.kMin;
    const out = [];
    for (const v of await this._cellsIn('hz', area, now)) {
      const riders = this.riders(v, now);
      if (riders < k) continue;
      const s = this._scored(v, now);
      if (s.total < minScore) continue;
      const top = Object.entries(s.byType).sort((a, b) => b[1] - a[1])[0]?.[0] || 'hard_brake';
      // Directions carrying ≥ 25 % of the directed score (empty = both / unknown directions).
      const dirTotal = s.byDir.reduce((a, b) => a + b, 0);
      const dirs = dirTotal > 0 && s.undirected < dirTotal ? s.byDir.map((x, i) => [x, i]).filter(([x]) => x >= dirTotal * 0.25).map(([, i]) => i) : [];
      const cell = { id: v.id, gh: v.cell, lat: r5(v.lat), lng: r5(v.lng), score: Math.min(100, Math.round(s.total * 5)), level: s.total >= 10 ? 'high' : 'medium', kind: top, dirs };
      if (admin) Object.assign(cell, { riders, counts: v.c || {}, rawScore: Math.round(s.total * 100) / 100, types: Object.fromEntries(Object.entries(s.byType).map(([a, b]) => [a, Math.round(b * 100) / 100])), updatedAt: v.upd || 0 });
      out.push(cell);
    }
    out.sort((a, b) => b.score - a.score);
    return out.slice(0, admin ? 5000 : 2000);
  }

  async roadQuality(area, { now = this.clock(), minScore = 2, admin = false } = {}) {
    const k = this.cfg.kMin;
    const out = [];
    for (const v of await this._cellsIn('rq', area, now)) {
      const riders = this.riders(v, now);
      if (riders < k) continue;
      const s = this._scored(v, now);
      if (s.total < minScore) continue;
      const dirTotal = s.byDir.reduce((a, b) => a + b, 0);
      const dirs = dirTotal > 0 ? s.byDir.map((x, i) => [x, i]).filter(([x]) => x >= dirTotal * 0.25).map(([, i]) => i) : [];
      const kind = (s.byType.pothole || 0) >= (s.byType.rough || 0) ? 'pothole' : 'rough';
      const cell = { id: v.id, gh: v.cell, lat: r5(v.lat), lng: r5(v.lng), score: Math.min(100, Math.round(s.total * 8)), kind, dirs };
      if (admin) Object.assign(cell, { riders, counts: v.c || {} });
      out.push(cell);
    }
    return out.sort((a, b) => b.score - a.score).slice(0, 2000);
  }

  /** Twistiness 0-100 from heading change per km (≥ 2 km of decayed riding in the cell, ≥ k riders). Ghat ≥ 50. */
  twistScore(v, now = this.clock()) {
    const f = M.decay(1, v.at || now, now, this.cfg.halfLifeDays);
    const km = ((v.dist || 0) * f) / 1000;
    if (km < 2) return null;
    const degPerKm = ((v.turn || 0) * f) / km;
    return { score: Math.min(100, Math.round(degPerKm / 3)), degPerKm: Math.round(degPerKm), km: Math.round(km * 10) / 10 };
  }

  async twisty(area, { now = this.clock(), minScore = 30, admin = false } = {}) {
    const k = this.cfg.kMin;
    const out = [];
    for (const v of await this._cellsIn('rd', area, now)) {
      if (this.riders(v, now) < k) continue;
      const t = this.twistScore(v, now);
      if (!t || t.score < minScore) continue;
      out.push({ id: v.id, gh: v.cell, lat: r5(v.lat), lng: r5(v.lng), score: t.score, ghat: t.score >= 50, ...(admin ? { degPerKm: t.degPerKm, km: t.km, riders: this.riders(v, now) } : {}) });
    }
    return out.sort((a, b) => b.score - a.score).slice(0, 3000);
  }

  async stops(area, { now = this.clock(), admin = false } = {}) {
    const k = this.cfg.kMin;
    const out = [];
    for (const v of await this._cellsIn('st', area, now)) {
      const riders = this.riders(v, now);
      if (riders < k) continue;
      const f = M.decay(1, v.at || now, now, this.cfg.halfLifeDays);
      const n = (v.n || 0) * f;
      if (n < 1) continue;
      const tod = (v.tod || []).map((x) => x * f);
      const peak = tod.indexOf(Math.max(...tod, 0));
      out.push({ id: v.id, gh: v.cell, lat: r5(v.lat), lng: r5(v.lng), typicalMin: Math.round(((v.dur || 0) * f) / n), peakHours: peak >= 0 ? [peak * 4, peak * 4 + 4] : null,
        place: v.place || null, fuel: v.place?.cat === 'fuel', popularity: Math.min(100, Math.round(n * 5)), ...(admin ? { riders, stops: Math.round(n * 10) / 10 } : {}) });
    }
    return out.sort((a, b) => b.popularity - a.popularity).slice(0, 2000);
  }

  /** Dangerous times per region: geohash-4 × (weekday/weekend × hour), with the best 2-hour window. */
  async dangerousTimes({ area = null, now = this.clock(), limit = 50 } = {}) {
    const k = this.cfg.kMin;
    let cells;
    if (area) cells = await this._cellsIn('dt', area, now);
    else cells = (await this.soda.query(CELLS, { layer: 'dt' }, { limit: 1000 })).map((r) => r.value);
    const out = [];
    for (const v of cells) {
      if (this.riders(v, now) < k) continue;
      const f = M.decay(1, v.at || now, now, this.cfg.halfLifeDays);
      const h = Object.fromEntries(Object.entries(v.h || {}).map(([a, b]) => [a, b * f]));
      const total = Object.values(h).reduce((a, b) => a + b, 0);
      if (total < 3) continue;
      let best = null;
      for (const dtp of ['w', 'e']) for (let hr = 0; hr < 24; hr++) {
        const s = (h[`${dtp}${hr}`] || 0) + (h[`${dtp}${(hr + 1) % 24}`] || 0);
        if (!best || s > best.s) best = { s, dtp, hr };
      }
      const types = Object.entries(v.c || {}).sort((a, b) => b[1] - a[1]);
      out.push({ region: v.cell, lat: r5(v.lat), lng: r5(v.lng), score: Math.round(total * 10) / 10,
        window: { dayType: best.dtp === 'e' ? 'weekend' : 'weekday', from: best.hr, to: (best.hr + 2) % 24, share: Math.round((best.s / total) * 100) },
        topType: types[0]?.[0] || 'hard_brake', hours: h });
    }
    return out.sort((a, b) => b.score - a.score).slice(0, limit);
  }

  /** Pre-ride tip for the region and hour (app shows at most one per day). Null when nothing stands out. */
  async rideTip(lat, lng, now = this.clock()) {
    const g4 = gh.encode(lat, lng, 4);
    if (!g4) return null;
    const list = await this.dangerousTimes({ area: { tiles: [g4] }, now, limit: 1 });
    const r = list[0];
    if (!r) return null;
    const slot = `${M.dayType(now)}${M.istParts(now).hour}`;
    const total = Object.values(r.hours).reduce((a, b) => a + b, 0);
    const here = r.hours[slot] || 0;
    // This hour carries at least twice its share (1/48) and at least 8 % of the region's signals.
    if (here < total / 24 || here < total * 0.08) return null;
    const hr = M.istParts(now).hour;
    const when = hr >= 17 && hr < 21 ? 'Evening rides' : hr >= 21 || hr < 5 ? 'Night rides' : hr < 11 ? 'Morning rides' : 'Rides at this time';
    const what = r.topType === 'hard_brake' ? 'more hard braking' : r.topType === 'crash' || r.topType === 'sos' ? 'more incidents' : 'more sudden swerves';
    return { tip: `${when} here see ${what}. Ride safe.`, region: g4 };
  }

  // ================================================================== motorcycle ETAs
  /** Learned speed (km/h) of a road cell for a time bucket (or all buckets), with ≥ k riders and ≥ 120 s of data. */
  cellSpeed(v, tb, now = this.clock()) {
    if (this.riders(v, now) < this.cfg.kMin) return null;
    const pick = (sv, st) => (st >= 120 ? sv / st : null);
    if (tb >= 0 && v.st?.[tb] >= 120) return pick(v.sv[tb], v.st[tb]);
    const sv = (v.sv || []).reduce((a, b) => a + b, 0), st = (v.st || []).reduce((a, b) => a + b, 0);
    return pick(sv, st);
  }

  /**
   * Multiplies each router leg's duration by a learned factor (riders' time / router time over the covered part),
   * when ≥ 50 % of the leg's distance has learned speeds; factor capped to [0.6, 1.6]. Returns a NEW route object
   * (the cached one is never mutated) with etaSource 'riders' when used; the plain route otherwise.
   */
  async etaAdjust(route, { now = this.clock() } = {}) {
    const cfg = this.cfg;
    if (!route || !route.polyline || !Array.isArray(route.legs) || !route.legs.length || !cfg.enabled || cfg.killed) return route;
    const { decodePolyline } = require('../geo_math');
    const line = decodePolyline(route.polyline, 20000);
    if (line.length < 2) return route;
    const tb = M.timeBucket(now);
    // Split the line into legs by cumulative distance.
    const cum = [0];
    for (let i = 1; i < line.length; i++) cum.push(cum[i - 1] + M.haversine(line[i - 1].lat, line[i - 1].lng, line[i].lat, line[i].lng));
    const total = cum[cum.length - 1] || 1;
    const scale = total / Math.max(1, route.legs.reduce((a, l) => a + (l.distanceM || 0), 0));
    const tiles = [...new Set(line.filter((_, i) => i % 5 === 0).map((p) => gh.encode(p.lat, p.lng, 4)))].slice(0, 64);
    const cellMap = new Map();
    for (const t of tiles) for (const v of await this._tile('rd', t)) cellMap.set(v.cell, v);
    if (!cellMap.size) return route;
    let used = false;
    let legStart = 0;
    const legs = route.legs.map((leg) => {
      const legEnd = legStart + (leg.distanceM || 0) * scale;
      const routerKmh = leg.durationS > 0 ? ((leg.distanceM / 1000) / (leg.durationS / 3600)) : null;
      let covered = 0, learnedS = 0, coveredRouterS = 0;
      for (let i = 1; i < line.length; i++) {
        const mid = (cum[i] + cum[i - 1]) / 2;
        if (mid < legStart || mid > legEnd) continue;
        const d = cum[i] - cum[i - 1];
        const v = cellMap.get(gh.encode((line[i].lat + line[i - 1].lat) / 2, (line[i].lng + line[i - 1].lng) / 2, 6));
        const kmh = v ? this.cellSpeed(v, tb, now) : null;
        if (kmh && kmh >= 5 && routerKmh) { covered += d; learnedS += d / (kmh / 3.6); coveredRouterS += d / (routerKmh / 3.6); }
      }
      legStart = legEnd;
      const legLen = (leg.distanceM || 0) * scale;
      if (!routerKmh || legLen <= 0 || covered < legLen * 0.5 || coveredRouterS <= 0) return { ...leg };
      const factor = Math.min(cfg.etaMax, Math.max(cfg.etaMin, learnedS / coveredRouterS));
      used = true;
      return { ...leg, durationS: Math.round(leg.durationS * factor), routerDurationS: leg.durationS, etaFactor: Math.round(factor * 100) / 100 };
    });
    if (!used) return route;
    return { ...route, legs, durationS: legs.reduce((a, l) => a + l.durationS, 0), routerDurationS: route.durationS, etaSource: 'riders' };
  }

  // ================================================================== no-fuel gaps
  /**
   * Stretches longer than gapKm without known fuel along a line [{lat,lng}]: client-known fuel points, learned stops
   * matched to fuel stations (≥ k riders), and fuel stations in the cached places cells (cache only, never upstream).
   */
  async fuelGaps(line, { fuel = [], gapKm = this.cfg.fuelGapKm, now = this.clock(), useCache = true } = {}) {
    if (!Array.isArray(line) || line.length < 2) return { gaps: [], fuelCount: 0 };
    const pts = [];
    for (const f of (Array.isArray(fuel) ? fuel.slice(0, 2000) : [])) {
      const lat = Number(f?.lat), lng = Number(f?.lng);
      if (Number.isFinite(lat) && Number.isFinite(lng)) pts.push({ lat, lng, name: String(f.name || '').slice(0, 60) });
    }
    if (useCache) {
      const tiles = [...new Set(line.filter((_, i) => i % 10 === 0).map((p) => gh.encode(p.lat, p.lng, 4)))].slice(0, 64);
      for (const t of tiles) for (const v of await this._tile('st', t).catch(() => [])) {
        if (v.place?.cat === 'fuel' && this.riders(v, now) >= this.cfg.kMin) pts.push({ lat: v.lat, lng: v.lng, name: v.place.name || '' });
      }
      if (this.poiCells) pts.push(...(await this._cachedFuelAlong(line).catch(() => [])));
    }
    return fuelGapsOf(line, pts, gapKm);
  }

  /** Fuel stations from the places cells already cached (memory or geo_cache). Never asks Overpass. ≤ 150 cells. */
  async _cachedFuelAlong(line) {
    const { CELL_DEG, CACHE_KEY, LEGACY_CACHE_KEYS } = require('../poi_cells');
    const keys = new Set();
    for (const p of line) keys.add(`${Math.floor(p.lat / CELL_DEG)}:${Math.floor(p.lng / CELL_DEG)}`);
    const out = [];
    for (const k of [...keys].slice(0, 150)) {
      let v = this.poiCells.mem?.get(k);
      if (!v && this.repo) {
        for (const prefix of [CACHE_KEY, ...LEGACY_CACHE_KEYS]) {
          const hit = await this.repo.geoCacheGet(`${prefix}${k}`).catch(() => null);
          if (hit?.value?.p) { v = hit.value; break; }
        }
      }
      for (const e of (v?.p || [])) if (e.t?.amenity === 'fuel') out.push({ lat: e.a, lng: e.o, name: e.t.name || e.t.brand || '' });
    }
    return out;
  }

  /** Daily: learned stops get the nearest cached fuel / food place within 150 m (cache only). ≤ 200 per run. */
  async tagStops({ now = this.clock(), signal } = {}) {
    const rows = await this.soda.query(CELLS, { layer: 'st', place: { $exists: false } }, { limit: 200 });
    let tagged = 0;
    for (const r of rows) {
      if (signal?.aborted) break;
      const v = r.value;
      const places = await this._cachedPlacesNear(v.lat, v.lng).catch(() => []);
      let best = null;
      for (const p of places) {
        const d = M.haversine(v.lat, v.lng, p.lat, p.lng);
        if (d <= 150 && (!best || d < best.d)) best = { ...p, d };
      }
      v.place = best ? { name: best.name, cat: best.cat } : null;
      await this.soda.replace(CELLS, r.key, v).catch(() => {});
      if (best) tagged++;
    }
    return tagged;
  }

  async _cachedPlacesNear(lat, lng) {
    const { CELL_DEG, CACHE_KEY } = require('../poi_cells');
    const k = `${Math.floor(lat / CELL_DEG)}:${Math.floor(lng / CELL_DEG)}`;
    let v = this.poiCells?.mem?.get(k);
    if (!v && this.repo) v = (await this.repo.geoCacheGet(`${CACHE_KEY}${k}`).catch(() => null))?.value;
    const cat = (t) => (t.amenity === 'fuel' ? 'fuel' : ['restaurant', 'cafe', 'fast_food', 'food_court'].includes(t.amenity) ? 'food' : t.amenity === 'toilets' ? 'rest' : null);
    return (v?.p || []).map((e) => ({ lat: e.a, lng: e.o, name: e.t?.name || e.t?.brand || '', cat: cat(e.t || {}) })).filter((p) => p.cat);
  }

  // ================================================================== rider rights
  /**
   * Delete my contributions: unprocessed raw rows go at once; processed rows (≤ INTEL_RAW_DAYS) are marked and the
   * next aggregation subtracts them from the cells (exact for scores, decay-aware) and deletes them. Older
   * contributions live only inside anonymous decayed totals and cannot be told apart (explained to the rider).
   */
  async deleteContributions(userId, { now = this.clock() } = {}) {
    this.rawQueue = this.rawQueue.filter((r) => r.uid !== userId);
    for (const [k, a] of [...this.acc.entries()]) if (a.uid === userId) this._closeAcc(k, { discard: true });
    const hashes = riderHashes(this.key, userId, now, Math.ceil(this.cfg.rawDays / 30) + 2).map((x) => x.rh);
    const removed = await this.soda.removeWhere(RAW, { rh: { $in: hashes }, p: 0 });
    let marked = 0;
    for (;;) {
      const rows = await this.soda.query(RAW, { rh: { $in: hashes }, p: 1 }, { limit: 200 });
      for (const r of rows) {
        if (r.value.k === 'crash') { await this.soda.remove(RAW, r.key); continue; }
        await this.soda.replace(RAW, r.key, { ...r.value, p: 2 });
        marked++;
      }
      if (rows.length < 200) break;
    }
    return { removedNow: removed, subtractingSoon: marked };
  }

  /** Export my contributions (raw rows within INTEL_RAW_DAYS, without the hash). */
  async exportContributions(userId, { now = this.clock() } = {}) {
    await this.flushRaw();
    const hashes = riderHashes(this.key, userId, now, Math.ceil(this.cfg.rawDays / 30) + 2).map((x) => x.rh);
    const rows = await this.soda.query(RAW, { rh: { $in: hashes } }, { limit: 1000, orderBy: [{ path: 't', datatype: 'number', order: 'asc' }] });
    return rows.filter((r) => r.value.p !== 2).map((r) => ({ kind: r.value.k, at: r.value.t, month: r.value.m, data: r.value.d }));
  }

  // ================================================================== meta, health
  async _meta(id) {
    const now = this.clock();
    if (id === 'crash_brain' && this.metaCache.value && now - this.metaCache.at < 60000) return this.metaCache.value;
    const row = await this.soda.findOne(META, { id });
    const v = row?.value || null;
    if (id === 'crash_brain') this.metaCache = { at: now, value: v };
    return v;
  }

  async _setMeta(id, value) {
    const row = await this.soda.findOne(META, { id });
    // 'status' is written by two jobs (aggregate, daily): merge so neither wipes the other's fields.
    const doc = id === 'status' ? { ...(row?.value || {}), ...value, id } : { ...value, id };
    if (row) await this.soda.replace(META, row.key, doc); else await this.soda.insert(META, doc);
  }

  /** Rough heap use of the in-memory parts (bytes): accumulators, queue, caches. */
  memoryEstimate() {
    let n = 0;
    for (const a of this.acc.values()) n += 400 + a.cells.size * 120 + a.trim.held.length * 90 + a.stops.length * 60;
    n += this.rawQueue.length * 600;
    for (const c of this.cache.values()) n += 200 + c.cells.length * 400;
    n += this.consent.cache.size * 120;
    return n;
  }

  async health() {
    const cfg = this.cfg;
    const status = await this._meta('status').catch(() => null);
    return {
      enabled: cfg.enabled && !cfg.killed, killed: cfg.killed, kMin: cfg.kMin, rawDays: cfg.rawDays, crashBrainMode: cfg.crashBrainMode, router: cfg.routerKind,
      lastAggregateAt: status?.lastAggregateAt || 0, lastDailyAt: status?.lastDailyAt || 0, aggregates: status?.counts || null,
      accumulators: this.acc.size, rawQueue: this.rawQueue.length, memoryKB: Math.round(this.memoryEstimate() / 1024),
    };
  }

  /** gzip-aware JSON (cached answers are small; the CPU cost is paid once per answer). */
  static sendJson(req, res, obj, { maxAge = 300 } = {}) {
    const body = Buffer.from(JSON.stringify(obj));
    res.set('Cache-Control', `private, max-age=${maxAge}`);
    res.set('Vary', 'Accept-Encoding');
    // v3.56: ETag over the JSON itself; a matching If-None-Match is a 304 before any compression work.
    res.set('ETag', `W/"${body.length.toString(16)}-${require('crypto').createHash('sha1').update(body).digest('base64').slice(0, 27)}"`);
    if (req.fresh) return res.status(304).end();
    // Behind Caddy (NODE_COMPRESSION=off) the proxy compresses off the event loop.
    if (require('../config').nodeCompression && body.length > 1024 && /\bgzip\b/.test(String(req.get('accept-encoding') || ''))) {
      res.set('Content-Encoding', 'gzip').type('application/json').send(zlib.gzipSync(body, { level: 6 }));
    } else {
      res.type('application/json').send(body);
    }
  }
}

/** Pure: gaps along `line` longer than gapKm between known fuel points within 1.5 km of the line. */
function fuelGapsOf(line, fuel, gapKm) {
  const cum = [0];
  for (let i = 1; i < line.length; i++) cum.push(cum[i - 1] + M.haversine(line[i - 1].lat, line[i - 1].lng, line[i].lat, line[i].lng));
  const total = cum[cum.length - 1];
  const along = [];
  const seen = new Set();
  for (const f of fuel) {
    const key = `${f.lat.toFixed(4)},${f.lng.toFixed(4)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const a = alongOf(line, cum, f);
    if (a && a.off <= 1500) along.push({ at: a.along, name: f.name || '' });
  }
  along.sort((a, b) => a.at - b.at);
  const marks = [{ at: 0, name: '', start: true }, ...along, { at: total, name: '', end: true }];
  const gaps = [];
  for (let i = 1; i < marks.length; i++) {
    const len = marks[i].at - marks[i - 1].at;
    if (len > gapKm * 1000) {
      gaps.push({ fromKm: Math.round(marks[i - 1].at / 100) / 10, toKm: Math.round(marks[i].at / 100) / 10, lengthKm: Math.round(len / 1000),
        after: marks[i - 1].start ? 'start' : (marks[i - 1].name || 'the last fuel station'), toEnd: !!marks[i].end });
    }
  }
  return { gaps, fuelCount: along.length, routeKm: Math.round(total / 1000), gapKm };
}

/** Nearest projection of p onto the line: { along (m), off (m) } (flat-earth per segment; fine at these sizes). */
function alongOf(line, cum, p) {
  let best = null;
  for (let i = 0; i < line.length - 1; i++) {
    const a = line[i], b = line[i + 1];
    const kx = Math.cos((a.lat * Math.PI) / 180) * 111320, ky = 110540;
    const bx = (b.lng - a.lng) * kx, by = (b.lat - a.lat) * ky;
    const px = (p.lng - a.lng) * kx, py = (p.lat - a.lat) * ky;
    const len2 = bx * bx + by * by;
    const t = len2 > 0 ? Math.max(0, Math.min(1, (px * bx + py * by) / len2)) : 0;
    const dx = px - t * bx, dy = py - t * by;
    const off = Math.sqrt(dx * dx + dy * dy);
    if (!best || off < best.off) best = { off, along: cum[i] + t * (cum[i + 1] - cum[i]) };
  }
  return best;
}

module.exports = { IntelEngine, fuelGapsOf, WEIGHTS, HAZARD_TYPES, ROAD_TYPES, EVENT_TYPES, RAW, CELLS, META, TRAIN, RAW_QUEUE_MAX };
