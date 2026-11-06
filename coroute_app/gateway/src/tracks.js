'use strict';
/**
 * Track storage and analysis.
 *
 * Phones record every accepted GPS fix locally and upload them in small
 * chunks over the WebSocket (`TRACK`). A chunk is
 *
 *   { seq, startTs, enc, t[], v[], acc[] }
 *
 *   enc  Google encoded polyline (1e5) of the chunk's points
 *   t    per-point offset in ms from startTs (non-decreasing)
 *   v    per-point GPS speed, km/h (integer)
 *   acc  per-point horizontal accuracy, metres (integer)
 *
 * Chunks are idempotent on (groupId, userId, seq), so a phone can safely
 * resend after a lost ACK. When loading, points are merged by timestamp,
 * which also absorbs overlapping chunks after an app restart.
 *
 * Writes are micro-batched: chunks saved within TRACK_BATCH_FLUSH_MS (or until
 * TRACK_BATCH_MAX are queued) go to the database in ONE bulk insert. Every
 * caller still waits for the write of its own chunk: an ACK (HTTP 200 /
 * TRACK_ACK) is only sent once the chunk is durably stored, and a failed batch
 * rejects every caller, so the phone keeps the chunk and sends it again.
 *
 * Old tracks: after TRACK_DETAIL_DAYS the retention job merges a rider's chunks
 * into one simplified document (Douglas-Peucker, `simplified: true`, negative
 * seq) of the same shape, so loading, GPX export, replay and trip reports read
 * both kinds alike.
 */
const config = require('./config');
const { haversine, decodePolyline, encodePolyline, simplify } = require('./geo_math');

const envInt = (name, def) => { const n = parseInt(process.env[name], 10); return Number.isFinite(n) ? n : def; };
/** A config value, or the environment variable when config.js does not define it (yet). */
const setting = (key, envName, def) => (Number.isFinite(config[key]) ? config[key] : envInt(envName, def));

class TrackError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; this.name = 'TrackError'; }
}

const isInt = (n) => Number.isInteger(n);

/** Validates a TRACK message and returns normalised points. Throws TrackError. */
function validateChunk(msg, { nowMs = Date.now(), tripStartMs = 0, maxPoints = config.trackMaxPoints } = {}) {
  const seq = Number(msg?.seq);
  const startTs = Number(msg?.startTs);
  if (!isInt(seq) || seq < 0 || seq > 1e13) throw new TrackError('Invalid seq.');
  if (!isInt(startTs)) throw new TrackError('Invalid startTs.');
  if (typeof msg.enc !== 'string' || msg.enc.length === 0 || msg.enc.length > maxPoints * 24) throw new TrackError('Invalid track encoding.');
  const { t, v, acc } = msg;
  if (!Array.isArray(t) || !Array.isArray(v) || !Array.isArray(acc)) throw new TrackError('Invalid track arrays.');
  const pts = decodePolyline(msg.enc, maxPoints);
  if (!pts || pts.length === 0) throw new TrackError('Invalid track encoding.');
  const n = pts.length;
  if (n > maxPoints) throw new TrackError('Too many points in one chunk.');
  if (t.length !== n || v.length !== n || acc.length !== n) throw new TrackError('Track arrays do not match.');

  if (startTs < tripStartMs - 10 * 60000) throw new TrackError('Track is older than this trip.');
  if (startTs > nowMs + 2 * 60000) throw new TrackError('Track is in the future.');

  const out = [];
  let prev = -1;
  for (let i = 0; i < n; i++) {
    const off = Number(t[i]);
    if (!isInt(off) || off < 0 || off > 6 * 3600000 || off < prev) throw new TrackError('Invalid point times.');
    prev = off;
    const p = pts[i];
    if (!(Math.abs(p.lat) <= 90 && Math.abs(p.lng) <= 180)) throw new TrackError('Invalid coordinates.');
    const sp = Number(v[i]);
    const ac = Number(acc[i]);
    out.push({
      ts: startTs + off, lat: p.lat, lng: p.lng,
      v: Number.isFinite(sp) ? Math.max(0, Math.min(300, Math.round(sp))) : 0,
      acc: Number.isFinite(ac) ? Math.max(0, Math.min(5000, Math.round(ac))) : 0,
    });
  }
  if (out[n - 1].ts > nowMs + 2 * 60000) throw new TrackError('Track is in the future.');
  return { seq, startTs, endTs: out[n - 1].ts, points: out, raw: { enc: msg.enc, t: t.map(Number), v: out.map((p) => p.v), acc: out.map((p) => p.acc) } };
}

class TrackStore {
  /**
   * @param {object} repo
   * @param {{flushMs?:number, maxBatch?:number, logger?:object}} [opts]
   */
  constructor(repo, opts = {}) {
    this.repo = repo;
    this.flushMs = Math.max(0, opts.flushMs ?? setting('trackBatchFlushMs', 'TRACK_BATCH_FLUSH_MS', 250));
    this.maxBatch = Math.max(1, opts.maxBatch ?? setting('trackBatchMax', 'TRACK_BATCH_MAX', 50));
    this.log = opts.logger || console;
    this.queue = []; // [{ k, doc, resolve, reject }]
    this.timer = null;
    this.inflight = new Map(); // "gid|uid|seq" -> promise of the queued / writing chunk
    this.flushing = new Set();
    this.stats = { batches: 0, chunks: 0, fallbacks: 0, failures: 0 };
  }

  /**
   * Stores a validated chunk. Resolves to { seq, duplicate } only after the chunk is in the
   * database; rejects when it could not be written (the caller must not ACK it then).
   */
  save(groupId, userId, chunk) {
    const k = `${groupId}\u0000${userId}\u0000${chunk.seq}`;
    const same = this.inflight.get(k);
    // The same chunk sent again while its first copy is still being written (retry after a lost ACK).
    if (same) return same.then(() => ({ seq: chunk.seq, duplicate: true }));
    const doc = {
      groupId, userId, seq: chunk.seq, startTs: chunk.startTs, endTs: chunk.endTs, count: chunk.points.length,
      ...chunk.raw, createdAt: Date.now(),
    };
    const p = new Promise((resolve, reject) => this.queue.push({ k, doc, resolve, reject }));
    this.inflight.set(k, p);
    const done = () => { if (this.inflight.get(k) === p) this.inflight.delete(k); };
    p.then(done, done);
    if (this.queue.length >= this.maxBatch) this._flushNow();
    else if (!this.timer) {
      // Not unref'd: it only exists while chunks wait (at most flushMs), and they must be written.
      this.timer = setTimeout(() => this._flushNow(), this.flushMs);
    }
    return p;
  }

  /** Writes everything queued now; resolves when every batch in progress has finished. */
  async flush() {
    this._flushNow();
    await Promise.all([...this.flushing]);
  }

  _flushNow() {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    while (this.queue.length) {
      const batch = this.queue.splice(0, this.maxBatch);
      const run = this._writeBatch(batch);
      this.flushing.add(run);
      run.finally(() => this.flushing.delete(run));
    }
  }

  async _writeBatch(batch) {
    const results = new Map(); // item -> { duplicate } | Error
    try {
      // 1. Which of these are stored already (resent after a lost ACK)? One query per rider.
      const byRider = new Map();
      for (const it of batch) {
        const rk = `${it.doc.groupId}\u0000${it.doc.userId}`;
        if (!byRider.has(rk)) byRider.set(rk, []);
        byRider.get(rk).push(it);
      }
      const fresh = [];
      for (const items of byRider.values()) {
        const { groupId, userId } = items[0].doc;
        const have = await this.repo.existingTrackSeqs(groupId, userId, items.map((it) => it.doc.seq));
        for (const it of items) {
          if (have.has(it.doc.seq)) results.set(it, { duplicate: true });
          else fresh.push(it);
        }
      }
      // 2. One bulk insert for the rest.
      if (fresh.length) {
        try {
          await this.repo.insertTrackChunks(fresh.map((it) => it.doc));
          for (const it of fresh) results.set(it, { duplicate: false });
        } catch (bulkErr) {
          // A concurrent writer stored one of them, or the bulk write failed part way: one by one,
          // and a chunk that is in the database after a failed insert counts as stored.
          this.stats.fallbacks++;
          for (const it of fresh) {
            try {
              await this.repo.insertTrackChunk(it.doc);
              results.set(it, { duplicate: false });
            } catch (e) {
              const stored = await this.repo.findTrackChunk(it.doc.groupId, it.doc.userId, it.doc.seq).catch(() => null);
              results.set(it, stored ? { duplicate: true } : e);
            }
          }
        }
      }
      this.stats.batches++;
    } catch (e) {
      for (const it of batch) if (!results.has(it)) results.set(it, e);
    }
    for (const it of batch) {
      const r = results.get(it);
      if (r instanceof Error || !r) {
        this.stats.failures++;
        it.reject(r || new Error('Track chunk was not stored.'));
      } else {
        this.stats.chunks++;
        it.resolve({ seq: it.doc.seq, duplicate: r.duplicate });
      }
    }
  }

  /** Loads, decodes and merges points for one rider (or all riders) of a convoy. */
  async load(groupId, { userId, from = 0, to = Number.MAX_SAFE_INTEGER } = {}) {
    const chunks = await this.repo.listTrackChunks(groupId, { userId, from, to });
    const byUser = new Map();
    for (const c of chunks) {
      const pts = decodePolyline(c.enc) || [];
      const list = byUser.get(c.userId) || [];
      for (let i = 0; i < pts.length; i++) {
        const ts = c.startTs + (c.t?.[i] ?? 0);
        if (ts < from || ts > to) continue;
        list.push({ ts, lat: pts[i].lat, lng: pts[i].lng, v: c.v?.[i] ?? 0, acc: c.acc?.[i] ?? 0 });
      }
      byUser.set(c.userId, list);
    }
    for (const [uid, list] of byUser) {
      list.sort((a, b) => a.ts - b.ts);
      const dedup = [];
      for (const p of list) if (!dedup.length || dedup[dedup.length - 1].ts !== p.ts) dedup.push(p);
      byUser.set(uid, dedup);
    }
    return byUser;
  }
}

/**
 * Simplified copy of a merged, time-sorted point list for long-term storage: Douglas-Peucker with
 * `toleranceM`, always keeping the first and last point, and at least one point every `maxGapMs`
 * (so stops keep their length and are not mistaken for signal gaps by analyseTrack).
 */
function simplifyTrack(points, { toleranceM = 5, maxGapMs = 60000 } = {}) {
  if (points.length <= 2) return points.slice();
  const dp = simplify(points, toleranceM);
  const keepTs = new Set(dp.map((p) => p.ts));
  const out = [];
  let last = null;
  for (let i = 0; i < points.length; i++) {
    const p = points[i];
    const next = points[i + 1];
    const keep = keepTs.has(p.ts) || i === 0 || i === points.length - 1 ||
      (last && next && next.ts - last.ts > maxGapMs);
    if (keep) { out.push(p); last = p; }
  }
  return out;
}

/** Encodes time-sorted points as a stored chunk body ({ startTs, endTs, count, enc, t, v, acc }). */
function encodeChunkBody(points) {
  const startTs = points[0].ts;
  return {
    startTs, endTs: points[points.length - 1].ts, count: points.length,
    enc: encodePolyline(points),
    t: points.map((p) => p.ts - startTs),
    v: points.map((p) => p.v || 0),
    acc: points.map((p) => p.acc || 0),
  };
}

/** Decodes stored chunks into one time-sorted point list without duplicate timestamps. */
function mergeChunkPoints(chunks) {
  const list = [];
  for (const c of chunks) {
    const pts = decodePolyline(c.enc) || [];
    for (let i = 0; i < pts.length; i++) {
      list.push({ ts: c.startTs + (c.t?.[i] ?? 0), lat: pts[i].lat, lng: pts[i].lng, v: c.v?.[i] ?? 0, acc: c.acc?.[i] ?? 0 });
    }
  }
  list.sort((a, b) => a.ts - b.ts);
  const out = [];
  for (const p of list) if (!out.length || out[out.length - 1].ts !== p.ts) out.push(p);
  return out;
}

/** Segment rules shared with the app (lib/domain/tracking/track_cleaner.dart): keep them in step. */
const SEGMENT_GAP_MS = 2 * 60000; // no fix for longer than this while moving: a signal gap
const SEGMENT_GAP_MOVE_M = 50; // ... but only when the rider moved at least this far meanwhile
const SEGMENT_JUMP_M = 500; // a jump this long ...
const SEGMENT_JUMP_KMH = 250; // ... faster than this is never a ridden line

/** True when going from a to b is physically impossible (a teleport, not a ride). */
function impossibleLink(a, b, { maxKmh = 250, minJumpM = 200 } = {}) {
  const d = haversine(a.lat, a.lng, b.lat, b.lng);
  if (d <= minJumpM) return false;
  const dt = (b.ts - a.ts) / 1000;
  return dt <= 0 || (d / dt) * 3.6 > maxKmh;
}

/**
 * The cleaned track the trip summary, the map, the replay and the GPX are all built from:
 * valid and accurate fixes only (accuracy 0 = not reported), sorted by time, one per timestamp,
 * without bad fixes. A bad fix is a short run (at most `maxOutlierRun` points) that is only
 * reachable from the rest by an impossible jump: a single wild fix in the middle, a wrong first
 * fix after a cold start, a stray last fix. Unlike a plain "compare with the last kept point"
 * filter, one wrong first fix can not throw away the whole ride.
 */
function filterPoints(points, { maxAccuracyM = 50, maxKmh = 250, minJumpM = 200, maxOutlierRun = 2 } = {}) {
  const list = [];
  for (const p of points || []) {
    if (!p || !Number.isFinite(p.ts) || !Number.isFinite(p.lat) || !Number.isFinite(p.lng)) continue;
    if (Math.abs(p.lat) > 90 || Math.abs(p.lng) > 180 || (p.lat === 0 && p.lng === 0)) continue;
    if (p.acc && p.acc > maxAccuracyM) continue;
    list.push(p);
  }
  list.sort((a, b) => a.ts - b.ts);
  const sorted = [];
  for (const p of list) if (!sorted.length || sorted[sorted.length - 1].ts !== p.ts) sorted.push(p);
  // Runs of mutually plausible points, cut at every impossible jump.
  const opts = { maxKmh, minJumpM };
  let runs = [];
  let cur = [];
  for (const p of sorted) {
    if (cur.length && impossibleLink(cur[cur.length - 1], p, opts)) { runs.push(cur); cur = []; }
    cur.push(p);
  }
  if (cur.length) runs.push(cur);
  if (runs.length <= 1) return runs[0] || [];
  // Short runs cut off by impossible jumps are bad fixes (unless the whole track is like that).
  if (runs.some((r) => r.length > maxOutlierRun)) runs = runs.filter((r) => r.length > maxOutlierRun);
  const out = [];
  for (const r of runs) for (const p of r) out.push(p);
  return out;
}

/**
 * Splits a cleaned, time-sorted track into the stretches that were really recorded. A new
 * segment starts after a signal gap (no fix for more than 2 minutes while the rider moved) or an
 * impossible jump (more than 500 m at more than 250 km/h). Between segments nothing was recorded,
 * so maps draw that as a dotted link (or not at all), never as a ridden line.
 */
function splitSegments(points, { gapMs = SEGMENT_GAP_MS, gapMoveM = SEGMENT_GAP_MOVE_M, jumpM = SEGMENT_JUMP_M, jumpKmh = SEGMENT_JUMP_KMH } = {}) {
  const segs = [];
  let cur = [];
  for (const p of points || []) {
    if (cur.length) {
      const a = cur[cur.length - 1];
      const d = haversine(a.lat, a.lng, p.lat, p.lng);
      const dt = p.ts - a.ts;
      const jump = d > jumpM && (dt <= 0 || (d / (dt / 1000)) * 3.6 > jumpKmh);
      if (jump || (dt > gapMs && d > gapMoveM)) { segs.push(cur); cur = []; }
    }
    cur.push(p);
  }
  if (cur.length) segs.push(cur);
  return segs;
}

/**
 * A cleaned track simplified segment by segment (so a gap is never simplified away) for maps and
 * the stored trip trail: at most `maxPoints` points, the tolerance doubling until it fits. The
 * first point of every segment after the first carries `gap: true`.
 */
function segmentedTrail(points, { toleranceM = 20, maxPoints = 4000 } = {}) {
  const segs = splitSegments(points);
  let tol = Math.max(0, toleranceM);
  let out = [];
  for (let round = 0; round < 12; round++) {
    out = [];
    segs.forEach((seg, i) => {
      const pts = tol > 0 && seg.length > 2 ? simplify(seg, tol) : seg;
      pts.forEach((p, j) => out.push(i > 0 && j === 0 ? { ...p, gap: true } : p));
    });
    if (out.length <= maxPoints) break;
    tol = tol > 0 ? tol * 2 : 5;
  }
  return out.length > maxPoints ? out.slice(0, maxPoints) : out;
}

/**
 * Finds stops: the rider stays within `radiusM` of a moving centre for at
 * least `minStopMs`. Leaves the stop when a fix is more than `exitM` away.
 * Slow traffic never qualifies (it leaves the radius long before the minimum).
 */
function detectStops(points, { radiusM = config.stopRadiusM, exitM = config.stopExitM, minStopMs = 120000 } = {}) {
  const stops = [];
  let cluster = null; // { first, last, sumLat, sumLng, n }
  const centre = (c) => ({ lat: c.sumLat / c.n, lng: c.sumLng / c.n });
  const close = () => {
    if (cluster && cluster.last.ts - cluster.first.ts >= minStopMs) {
      const c = centre(cluster);
      stops.push({ startTs: cluster.first.ts, endTs: cluster.last.ts, durationMs: cluster.last.ts - cluster.first.ts, lat: c.lat, lng: c.lng, points: cluster.n });
    }
  };
  for (const p of points) {
    if (!cluster) { cluster = { first: p, last: p, sumLat: p.lat, sumLng: p.lng, n: 1 }; continue; }
    const c = centre(cluster);
    const d = haversine(c.lat, c.lng, p.lat, p.lng);
    if (d <= radiusM || (d <= exitM && cluster.last.ts - cluster.first.ts >= minStopMs)) {
      cluster.last = p; cluster.sumLat += p.lat; cluster.sumLng += p.lng; cluster.n++;
    } else {
      close();
      cluster = { first: p, last: p, sumLat: p.lat, sumLng: p.lng, n: 1 };
    }
  }
  if (cluster) {
    close();
    // An unfinished stop at the end of the track is still a stop (the rider is parked now).
    if (stops.length && stops[stops.length - 1].endTs === cluster.last.ts) stops[stops.length - 1].open = true;
  }
  return stops;
}

/**
 * Full per-rider analysis used by the trip report.
 * Returns distance, moving/rest/gap time, stops and moving segments.
 */
function analyseTrack(rawPoints, { minStopMs = 120000, gapMs = config.offlineAlertMinutes * 60000 } = {}) {
  const points = filterPoints(rawPoints);
  if (points.length === 0) {
    return { points, distanceM: 0, recordedDistanceM: 0, gapDistanceM: 0, pieces: 0, firstTs: 0, lastTs: 0, spanMs: 0, restMs: 0, gapMs: 0, movingMs: 0, maxKmh: 0, avgMovingKmh: 0, stops: [], segments: [], gaps: [] };
  }
  const stops = detectStops(points, { minStopMs });
  const inStop = (ts) => stops.some((s) => ts > s.startTs && ts <= s.endTs);

  let distanceM = 0, maxKmh = 0;
  const gaps = [];
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1], b = points[i];
    const d = haversine(a.lat, a.lng, b.lat, b.lng);
    const dt = b.ts - a.ts;
    if (inStop(b.ts) && inStop(a.ts + 1)) continue; // jitter while parked
    if (impossibleLink(a, b)) continue; // two plausible runs joined by a teleport: never ridden
    if (dt > gapMs && d > config.stopExitM) gaps.push({ startTs: a.ts, endTs: b.ts, durationMs: dt, distanceM: d });
    distanceM += d;
    const implied = dt > 0 ? (d / (dt / 1000)) * 3.6 : 0;
    // Trust the GPS speed only when the positions roughly agree with it.
    const v = Math.min(b.v || 0, implied * 1.5 + 15);
    if (v > maxKmh) maxKmh = v;
  }
  const firstTs = points[0].ts, lastTs = points[points.length - 1].ts;
  const spanMs = lastTs - firstTs;
  // What was really recorded (inside segments) and the straight lines across signal gaps between them.
  const segs = splitSegments(points);
  let recordedDistanceM = 0;
  for (const seg of segs) {
    for (let i = 1; i < seg.length; i++) {
      const a = seg[i - 1], b = seg[i];
      if (inStop(b.ts) && inStop(a.ts + 1)) continue;
      recordedDistanceM += haversine(a.lat, a.lng, b.lat, b.lng);
    }
  }
  const restMs = stops.reduce((s, x) => s + x.durationMs, 0);
  const gapTotal = gaps.reduce((s, x) => s + x.durationMs, 0);
  const gapDistance = gaps.reduce((s, x) => s + x.distanceM, 0);
  const movingMs = Math.max(0, spanMs - restMs - gapTotal);

  // Moving segments between stops (and from start / to end).
  const segments = [];
  let segStart = firstTs;
  const segFor = (from, to) => {
    if (to - from < 30000) return;
    let d = 0, top = 0;
    for (let i = 1; i < points.length; i++) {
      const a = points[i - 1], b = points[i];
      if (b.ts <= from || a.ts >= to) continue;
      d += haversine(a.lat, a.lng, b.lat, b.lng);
      if ((b.v || 0) > top) top = b.v;
    }
    if (d < 50) return;
    segments.push({ startTs: from, endTs: to, durationMs: to - from, distanceM: d, avgKmh: d / ((to - from) / 3600000) / 1000, maxKmh: top });
  };
  for (const s of stops) { segFor(segStart, s.startTs); segStart = s.endTs; }
  segFor(segStart, lastTs);

  return {
    points, distanceM, firstTs, lastTs, spanMs, restMs, gapMs: gapTotal, movingMs,
    recordedDistanceM, gapDistanceM: Math.max(0, distanceM - recordedDistanceM), pieces: segs.length,
    // Average while moving: the straight line across a signal gap is not riding time, so it is left out.
    maxKmh: Math.round(maxKmh), avgMovingKmh: movingMs > 0 ? +(Math.max(0, distanceM - gapDistance) / 1000 / (movingMs / 3600000)).toFixed(1) : 0,
    stops, segments, gaps,
  };
}

/**
 * Compact wire form for the maps and the replay: [[ts, lat, lng, v], ...], optionally simplified
 * (segment by segment). The first point after a signal gap or a jump has a fifth element 1
 * ("break": the line is cut there). Old apps read the first four elements only.
 */
function toWire(points, simplifyM = 0) {
  const out = [];
  splitSegments(points).forEach((seg, i) => {
    const pts = simplifyM > 0 && seg.length > 2 ? simplify(seg, simplifyM) : seg;
    pts.forEach((p, j) => {
      const row = [p.ts, +p.lat.toFixed(5), +p.lng.toFixed(5), p.v || 0];
      if (i > 0 && j === 0) row.push(1);
      out.push(row);
    });
  });
  return out;
}

function toGpx({ name, tracks }) {
  const esc = (s) => String(s).replace(/[<>&"']/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c]));
  // One <trkseg> per recorded segment: other apps do not join a signal gap with a straight line either.
  const seg = (pts) => `<trkseg>\n${pts.map((p) =>
    `    <trkpt lat="${p.lat.toFixed(6)}" lon="${p.lng.toFixed(6)}"><time>${new Date(p.ts).toISOString()}</time></trkpt>`).join('\n')}\n  </trkseg>`;
  const trk = tracks.map((t) => `  <trk><name>${esc(t.name)}</name>${splitSegments(t.points).map(seg).join('')}</trk>`).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="CoRoute" xmlns="http://www.topografix.com/GPX/1/1">\n  <metadata><name>${esc(name)}</name></metadata>\n${trk}\n</gpx>\n`;
}

/**
 * May this user upload points into this convoy? Members may, while the convoy is
 * active and for a grace period after they left or it ended (to send the backlog
 * from a dead zone). Returns { ok, tripStartMs, ended } .
 */
function uploadPermission(meta, userId, nowMs = Date.now()) {
  const m = meta?.members?.[userId];
  if (!m) return { ok: false };
  const grace = config.trackUploadGraceMinutes * 60000;
  const ended = meta.tripStatus === 'ENDED';
  const left = m.leftAt && m.leftAt >= (m.joinedAt || 0) ? m.leftAt : 0;
  const closedAt = Math.min(ended ? (meta.endedAtEpochMs || nowMs) : Infinity, left || Infinity);
  if (Number.isFinite(closedAt) && nowMs - closedAt > grace) return { ok: false, tooLate: true };
  return { ok: true, tripStartMs: meta.createdAtEpochMs || 0, ended };
}

module.exports = {
  uploadPermission, TrackStore, TrackError, validateChunk, filterPoints, detectStops, analyseTrack, toWire, toGpx, simplifyTrack, encodeChunkBody, mergeChunkPoints,
  splitSegments, segmentedTrail, impossibleLink, SEGMENT_GAP_MS, SEGMENT_JUMP_M,
};
