'use strict';
/**
 * Geometry for the rider safety network and rider discovery (3.15). Pure, no I/O.
 *
 *  - A coarse grid (cells of G degrees) for "who is near this point" without scanning every rider.
 *  - A route index per convoy route: the decoded, simplified polyline packed as
 *    Float64Array [lat, lng, cumulativeMetres] plus a cell -> segment map, so a point is projected
 *    onto the route by looking only at the segments of its own cell and the 8 neighbours.
 *  - Small flat-earth helpers (bearing, angle difference, cross / along track), accurate to well
 *    under 1 % at the distances used here (< 30 km).
 */
const { haversine, decodePolyline } = require('./geo_math');

const EARTH_R = 6371008.8;
const rad = (d) => (d * Math.PI) / 180;
const deg = (r) => (r * 180) / Math.PI;
const M_PER_DEG = (Math.PI / 180) * EARTH_R; // about 111 195 m

// ------------------------------------------------------------------ basic helpers
/** Initial bearing from point 1 to point 2, degrees 0..360. */
function bearing(lat1, lng1, lat2, lng2) {
  const y = Math.sin(rad(lng2 - lng1)) * Math.cos(rad(lat2));
  const x = Math.cos(rad(lat1)) * Math.sin(rad(lat2)) - Math.sin(rad(lat1)) * Math.cos(rad(lat2)) * Math.cos(rad(lng2 - lng1));
  return (deg(Math.atan2(y, x)) + 360) % 360;
}

/** Smallest absolute difference between two headings, degrees 0..180. */
function angleDiff(a, b) {
  const d = Math.abs((((a - b) % 360) + 540) % 360 - 180);
  return d;
}

/**
 * Cross-track and along-track distance (metres) of point P relative to the directed line A -> B
 * (local flat projection around A). along > 0 means P lies in the direction of travel from A.
 * cross is unsigned. `lineLength` is the A -> B length.
 */
function crossAlong(aLat, aLng, bLat, bLng, pLat, pLng) {
  const k = Math.cos(rad(aLat));
  const bx = (bLng - aLng) * M_PER_DEG * k, by = (bLat - aLat) * M_PER_DEG;
  const px = (pLng - aLng) * M_PER_DEG * k, py = (pLat - aLat) * M_PER_DEG;
  const len = Math.hypot(bx, by);
  if (len < 1e-6) return { cross: Math.hypot(px, py), along: 0, lineLength: 0 };
  const ux = bx / len, uy = by / len;
  return { cross: Math.abs(px * uy - py * ux), along: px * ux + py * uy, lineLength: len };
}

/** Same as crossAlong but for a line through A with heading `hdg` (degrees). */
function crossAlongHeading(aLat, aLng, hdg, pLat, pLng) {
  const k = Math.cos(rad(aLat));
  const ux = Math.sin(rad(hdg)), uy = Math.cos(rad(hdg));
  const px = (pLng - aLng) * M_PER_DEG * k, py = (pLat - aLat) * M_PER_DEG;
  return { cross: Math.abs(px * uy - py * ux), along: px * ux + py * uy };
}

// ------------------------------------------------------------------ grid
function gridSize(millideg) { return millideg / 1000; }

function cellKey(lat, lng, G) { return `${Math.floor(lat / G)}:${Math.floor(lng / G)}`; }

/** Cell rings needed to cover radius R metres around latitude `lat`. */
function ringFor(R, lat, G) {
  const c = Math.max(0.05, Math.cos(rad(lat)));
  return Math.max(1, Math.ceil(R / (G * M_PER_DEG * c)));
}

/** Every cell key within `n` cells of the point (a (2n+1)^2 square). */
function cellsAround(lat, lng, G, n) {
  const ci = Math.floor(lat / G), cj = Math.floor(lng / G);
  const out = [];
  for (let i = -n; i <= n; i++) for (let j = -n; j <= n; j++) out.push(`${ci + i}:${cj + j}`);
  return out;
}

/**
 * Members (strings) placed on the grid. update() is O(1) and only touches the maps when the
 * member changes cell.
 */
class SpatialGrid {
  constructor(G) { this.G = G; this.cells = new Map(); this.where = new Map(); }

  update(member, lat, lng) {
    const k = cellKey(lat, lng, this.G);
    const prev = this.where.get(member);
    if (prev === k) return false;
    if (prev !== undefined) this._out(member, prev);
    let set = this.cells.get(k);
    if (!set) { set = new Set(); this.cells.set(k, set); }
    set.add(member);
    this.where.set(member, k);
    return true;
  }

  remove(member) {
    const prev = this.where.get(member);
    if (prev === undefined) return;
    this._out(member, prev);
    this.where.delete(member);
  }

  _out(member, k) {
    const set = this.cells.get(k);
    if (!set) return;
    set.delete(member);
    if (set.size === 0) this.cells.delete(k);
  }

  /** Members in the cells covering radius R around the point (a superset of the circle). */
  query(lat, lng, R) {
    const out = [];
    for (const k of cellsAround(lat, lng, this.G, ringFor(R, lat, this.G))) {
      const set = this.cells.get(k);
      if (set) for (const m of set) out.push(m);
    }
    return out;
  }

  get size() { return this.where.size; }
}

// ------------------------------------------------------------------ route index
/**
 * Douglas-Peucker on a flat local projection (metres), iterative, typed arrays: fast enough to index
 * a 3000-point route in about a millisecond.
 */
function simplifyFlat(raw, toleranceM) {
  const n = raw.length;
  if (!toleranceM || n <= 2) return raw.slice();
  const k = Math.cos(rad(raw[0].lat));
  const xs = new Float64Array(n), ys = new Float64Array(n);
  for (let i = 0; i < n; i++) { xs[i] = raw[i].lng * M_PER_DEG * k; ys[i] = raw[i].lat * M_PER_DEG; }
  const keep = new Uint8Array(n);
  keep[0] = 1; keep[n - 1] = 1;
  const stack = [0, n - 1];
  const tol2 = toleranceM * toleranceM;
  while (stack.length) {
    const e = stack.pop(), st = stack.pop();
    const ax = xs[st], ay = ys[st], dx = xs[e] - ax, dy = ys[e] - ay;
    const len2 = dx * dx + dy * dy;
    let maxD = -1, idx = -1;
    for (let i = st + 1; i < e; i++) {
      let t = len2 > 0 ? ((xs[i] - ax) * dx + (ys[i] - ay) * dy) / len2 : 0;
      t = t < 0 ? 0 : t > 1 ? 1 : t;
      const ex = ax + t * dx - xs[i], ey = ay + t * dy - ys[i];
      const d = ex * ex + ey * ey;
      if (d > maxD) { maxD = d; idx = i; }
    }
    if (idx >= 0 && maxD > tol2) { keep[idx] = 1; stack.push(st, idx, idx, e); }
  }
  const out = [];
  for (let i = 0; i < n; i++) if (keep[i]) out.push(raw[i]);
  return out;
}

/**
 * Decodes, simplifies and packs a route. Returns null for anything unusable (fewer than 2 points).
 * index = { n, pts: Float64Array(3n) [lat, lng, cumM], cells: Map<cellKey, Int32Array>, G, length, stamp: Int32Array(n) }
 */
function buildRouteIndex(polyline, { simplifyM = 15, maxPoints = 3000, G = 0.05 } = {}) {
  const raw = Array.isArray(polyline) ? polyline : decodePolyline(polyline, 200000);
  if (!raw || raw.length < 2) return null;
  let pts = simplifyFlat(raw, simplifyM);
  let tol = simplifyM || 1;
  for (let i = 0; pts.length > maxPoints && i < 8; i++) { tol *= 2; pts = simplifyFlat(raw, tol); }
  if (pts.length > maxPoints) {
    // Still too many (pathological input): keep evenly spread points, first and last kept.
    const step = (pts.length - 1) / (maxPoints - 1);
    const kept = [];
    for (let i = 0; i < maxPoints; i++) kept.push(pts[Math.round(i * step)]);
    pts = kept;
  }
  const n = pts.length;
  const arr = new Float64Array(n * 3);
  let cum = 0;
  for (let i = 0; i < n; i++) {
    if (i > 0) cum += haversine(pts[i - 1].lat, pts[i - 1].lng, pts[i].lat, pts[i].lng);
    arr[i * 3] = pts[i].lat; arr[i * 3 + 1] = pts[i].lng; arr[i * 3 + 2] = cum;
  }
  // Each segment is registered in every cell it passes through (sampled at a quarter cell).
  const lists = new Map();
  const add = (k, s) => {
    let l = lists.get(k);
    if (!l) { l = []; lists.set(k, l); }
    if (l[l.length - 1] !== s) l.push(s);
  };
  const stepDeg = G / 4;
  for (let s = 0; s < n - 1; s++) {
    const la1 = arr[s * 3], ln1 = arr[s * 3 + 1], la2 = arr[s * 3 + 3], ln2 = arr[s * 3 + 4];
    const span = Math.max(Math.abs(la2 - la1), Math.abs(ln2 - ln1));
    const k = Math.max(1, Math.ceil(span / stepDeg));
    let last = null;
    for (let q = 0; q <= k; q++) {
      const key = cellKey(la1 + ((la2 - la1) * q) / k, ln1 + ((ln2 - ln1) * q) / k, G);
      if (key !== last) { add(key, s); last = key; }
    }
  }
  const cells = new Map();
  for (const [k, l] of lists) cells.set(k, Int32Array.from(l));
  return { n, pts: arr, cells, G, length: cum, stamp: new Int32Array(Math.max(1, n)), stampNo: 0 };
}

/** Squared flat distance (m^2) and t of the point to segment s; writes into `out` (no allocation). */
function segDist(index, s, lat, lng, k, out) {
  const a = index.pts;
  const ax = (a[s * 3 + 1] - lng) * M_PER_DEG * k, ay = (a[s * 3] - lat) * M_PER_DEG;
  const bx = (a[s * 3 + 4] - lng) * M_PER_DEG * k, by = (a[s * 3 + 3] - lat) * M_PER_DEG;
  const dx = bx - ax, dy = by - ay;
  const len2 = dx * dx + dy * dy;
  let t = len2 > 0 ? (-ax * dx - ay * dy) / len2 : 0;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  const cx = ax + t * dx, cy = ay + t * dy;
  out.d2 = cx * cx + cy * cy; out.t = t;
}

/** The public projection object for segment s at parameter t. */
function projection(index, s, t, d2) {
  const a = index.pts;
  return {
    lateralM: Math.sqrt(d2), alongM: a[s * 3 + 2] + t * (a[s * 3 + 5] - a[s * 3 + 2]), segIndex: s,
    segBearing: bearing(a[s * 3], a[s * 3 + 1], a[s * 3 + 3], a[s * 3 + 4]),
  };
}

/** Projection of a point onto segment s of the index: { lateralM, alongM, segIndex, segBearing }. */
function projectSegment(index, s, lat, lng) {
  const o = { d2: 0, t: 0 };
  segDist(index, s, lat, lng, Math.cos(rad(lat)), o);
  return projection(index, s, o.t, o.d2);
}

/** Segment indices registered in the point's cell and its 8 neighbours (unique, unsorted). */
function nearbySegments(index, lat, lng) {
  const out = [];
  if (++index.stampNo > 2e9) { index.stamp.fill(0); index.stampNo = 1; }
  const no = index.stampNo, stamp = index.stamp;
  const ci = Math.floor(lat / index.G), cj = Math.floor(lng / index.G);
  for (let i = -1; i <= 1; i++) {
    for (let j = -1; j <= 1; j++) {
      const l = index.cells.get(`${ci + i}:${cj + j}`);
      if (!l) continue;
      for (let q = 0; q < l.length; q++) { const s = l[q]; if (stamp[s] !== no) { stamp[s] = no; out.push(s); } }
    }
  }
  return out;
}

/**
 * Every pass of the route near the point: for each run of consecutive segments within
 * `maxLateralM`, the closest projection. An out-and-back road gives two passes.
 */
function projectAll(index, lat, lng, maxLateralM = Infinity) {
  if (!index) return [];
  const k = Math.cos(rad(lat));
  const max2 = maxLateralM * maxLateralM;
  const o = { d2: 0, t: 0 };
  const hits = [];
  for (const s of nearbySegments(index, lat, lng)) {
    segDist(index, s, lat, lng, k, o);
    if (o.d2 <= max2) hits.push([s, o.t, o.d2]);
  }
  hits.sort((x, y) => x[0] - y[0]);
  const out = [];
  let best = null, prev = -2;
  for (const h of hits) {
    if (best && h[0] === prev + 1) { if (h[2] < best[2]) best = h; } else { if (best) out.push(best); best = h; }
    prev = h[0];
  }
  if (best) out.push(best);
  return out.map((h) => projection(index, h[0], h[1], h[2]));
}

/** Closest projection over the whole route (cell lookup), or null when the route is out of the cells. */
function projectNearest(index, lat, lng) {
  const k = Math.cos(rad(lat));
  const o = { d2: 0, t: 0 };
  let bs = -1, bt = 0, bd = Infinity;
  for (const s of nearbySegments(index, lat, lng)) {
    segDist(index, s, lat, lng, k, o);
    if (o.d2 < bd) { bd = o.d2; bs = s; bt = o.t; }
  }
  return bs < 0 ? null : projection(index, bs, bt, bd);
}

/**
 * Projection of a moving rider: looks at segments lastSeg - back .. lastSeg + fwd first (the rider
 * is usually there), and uses the cell lookup only when nothing in that window is within `onRouteM`.
 */
function projectWindow(index, lat, lng, lastSeg = null, { back = 20, fwd = 200, onRouteM = 300 } = {}) {
  if (!index) return null;
  if (Number.isInteger(lastSeg) && lastSeg >= 0 && lastSeg < index.n - 1) {
    const k = Math.cos(rad(lat));
    const o = { d2: 0, t: 0 };
    let bs = -1, bt = 0, bd = Infinity;
    const from = Math.max(0, lastSeg - back), to = Math.min(index.n - 2, lastSeg + fwd);
    for (let s = from; s <= to; s++) {
      segDist(index, s, lat, lng, k, o);
      if (o.d2 < bd) { bd = o.d2; bs = s; bt = o.t; }
    }
    if (bs >= 0 && bd <= onRouteM * onRouteM) return projection(index, bs, bt, bd);
  }
  return projectNearest(index, lat, lng);
}

/** Brute-force projection over every segment (tests compare the index against it). */
function projectBrute(index, lat, lng) {
  let best = null;
  for (let s = 0; s < index.n - 1; s++) {
    const p = projectSegment(index, s, lat, lng);
    if (!best || p.lateralM < best.lateralM) best = p;
  }
  return best;
}

/** The point at `alongM` metres along the route (clamped), with the segment index. */
function pointAt(index, alongM) {
  const a = index.pts;
  if (alongM <= 0) return { lat: a[0], lng: a[1], segIndex: 0 };
  if (alongM >= index.length) return { lat: a[(index.n - 1) * 3], lng: a[(index.n - 1) * 3 + 1], segIndex: index.n - 2 };
  let lo = 0, hi = index.n - 1;
  while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (a[mid * 3 + 2] <= alongM) lo = mid; else hi = mid; }
  const c1 = a[lo * 3 + 2], c2 = a[hi * 3 + 2];
  const t = c2 > c1 ? (alongM - c1) / (c2 - c1) : 0;
  return { lat: a[lo * 3] + t * (a[hi * 3] - a[lo * 3]), lng: a[lo * 3 + 1] + t * (a[hi * 3 + 1] - a[lo * 3 + 1]), segIndex: lo };
}

/**
 * Route indexes by polyline string, shared by the safety network and discovery (geometry only,
 * no rider state). A room's entry is rebuilt only when its polyline changes; forget() on room end.
 */
class RouteIndexCache {
  constructor(opts = {}) { this.opts = opts; this.byRoom = new Map(); }

  /** Index for a convoy meta, or null when the route is missing or approximate (straight lines). */
  forMeta(gid, meta) {
    const r = meta && meta.route;
    if (!r || r.approximate || typeof r.polyline !== 'string' || !r.polyline) {
      this.byRoom.delete(gid);
      return null;
    }
    const cur = this.byRoom.get(gid);
    if (cur && cur.polyline === r.polyline) return cur.index;
    const index = buildRouteIndex(r.polyline, this.opts);
    this.byRoom.set(gid, { polyline: r.polyline, index });
    return index;
  }

  forget(gid) { this.byRoom.delete(gid); }
  get size() { return this.byRoom.size; }
}

module.exports = {
  bearing, angleDiff, crossAlong, crossAlongHeading, gridSize, cellKey, ringFor, cellsAround, SpatialGrid,
  buildRouteIndex, simplifyFlat, projectSegment, projectAll, projectNearest, projectWindow, projectBrute, pointAt, RouteIndexCache, M_PER_DEG,
};
