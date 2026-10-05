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
 */
const config = require('./config');
const { haversine, decodePolyline, simplify } = require('./geo_math');

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
  constructor(repo) { this.repo = repo; }

  /** Stores a validated chunk. Returns { seq, duplicate }. */
  async save(groupId, userId, chunk) {
    const existing = await this.repo.findTrackChunk(groupId, userId, chunk.seq);
    if (existing) return { seq: chunk.seq, duplicate: true };
    await this.repo.insertTrackChunk({
      groupId, userId, seq: chunk.seq, startTs: chunk.startTs, endTs: chunk.endTs, count: chunk.points.length,
      ...chunk.raw, createdAt: Date.now(),
    });
    return { seq: chunk.seq, duplicate: false };
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

/** Drops fixes that are inaccurate, out of order or physically impossible. */
function filterPoints(points, { maxAccuracyM = 50, maxKmh = 250 } = {}) {
  const out = [];
  for (const p of points) {
    if (p.acc && p.acc > maxAccuracyM) continue;
    const last = out[out.length - 1];
    if (last) {
      const dt = (p.ts - last.ts) / 1000;
      if (dt <= 0) continue;
      const d = haversine(last.lat, last.lng, p.lat, p.lng);
      if ((d / dt) * 3.6 > maxKmh && d > 200) continue; // teleport
    }
    out.push(p);
  }
  return out;
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
    return { points, distanceM: 0, firstTs: 0, lastTs: 0, spanMs: 0, restMs: 0, gapMs: 0, movingMs: 0, maxKmh: 0, avgMovingKmh: 0, stops: [], segments: [], gaps: [] };
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
    if (dt > gapMs && d > config.stopExitM) gaps.push({ startTs: a.ts, endTs: b.ts, durationMs: dt, distanceM: d });
    distanceM += d;
    const implied = dt > 0 ? (d / (dt / 1000)) * 3.6 : 0;
    // Trust the GPS speed only when the positions roughly agree with it.
    const v = Math.min(b.v || 0, implied * 1.5 + 15);
    if (v > maxKmh) maxKmh = v;
  }
  const firstTs = points[0].ts, lastTs = points[points.length - 1].ts;
  const spanMs = lastTs - firstTs;
  const restMs = stops.reduce((s, x) => s + x.durationMs, 0);
  const gapTotal = gaps.reduce((s, x) => s + x.durationMs, 0);
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
    maxKmh: Math.round(maxKmh), avgMovingKmh: movingMs > 0 ? +(distanceM / 1000 / (movingMs / 3600000)).toFixed(1) : 0,
    stops, segments, gaps,
  };
}

/** Compact wire form for the replay view: [[ts, lat, lng, v], ...], optionally simplified. */
function toWire(points, simplifyM = 0) {
  const pts = simplifyM > 0 ? simplify(points, simplifyM) : points;
  return pts.map((p) => [p.ts, +p.lat.toFixed(5), +p.lng.toFixed(5), p.v || 0]);
}

function toGpx({ name, tracks }) {
  const esc = (s) => String(s).replace(/[<>&"']/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c]));
  const trk = tracks.map((t) => `  <trk><name>${esc(t.name)}</name><trkseg>\n${t.points.map((p) =>
    `    <trkpt lat="${p.lat.toFixed(6)}" lon="${p.lng.toFixed(6)}"><time>${new Date(p.ts).toISOString()}</time></trkpt>`).join('\n')}\n  </trkseg></trk>`).join('\n');
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

module.exports = { uploadPermission, TrackStore, TrackError, validateChunk, filterPoints, detectStops, analyseTrack, toWire, toGpx };
