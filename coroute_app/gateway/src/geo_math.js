'use strict';
/**
 * Small, dependency-free geodesy helpers shared by the track store, the
 * timeline engine and the trip report. The Flutter app has a Dart twin
 * (lib/domain/tracking/geo_math.dart) tested against the same values.
 */
const R = 6371008.8; // mean Earth radius, metres
const rad = (d) => (d * Math.PI) / 180;

/** Great-circle distance in metres. */
function haversine(lat1, lng1, lat2, lng2) {
  const dLat = rad(lat2 - lat1);
  const dLng = rad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
}

/** Local equirectangular projection (metres) around a reference latitude; accurate to <0.5% under ~50 km. */
function project(lat, lng, refLat) {
  const k = Math.cos(rad(refLat));
  return { x: rad(lng) * R * k, y: rad(lat) * R };
}

/** Distance in metres from point P to segment AB. */
function pointToSegment(p, a, b) {
  const ref = p.lat;
  const P = project(p.lat, p.lng, ref), A = project(a.lat, a.lng, ref), B = project(b.lat, b.lng, ref);
  const dx = B.x - A.x, dy = B.y - A.y;
  const len2 = dx * dx + dy * dy;
  let t = len2 > 0 ? ((P.x - A.x) * dx + (P.y - A.y) * dy) / len2 : 0;
  t = Math.max(0, Math.min(1, t));
  const cx = A.x + t * dx, cy = A.y + t * dy;
  return { dist: Math.hypot(P.x - cx, P.y - cy), t };
}

/**
 * Distance from a point to a polyline, plus how far along the line the closest
 * point lies (metres from the first vertex). Returns { dist, along } or null.
 */
function distanceToPolyline(p, line) {
  if (!Array.isArray(line) || line.length < 2) return null;
  let best = { dist: Infinity, along: 0 };
  let acc = 0;
  for (let i = 0; i < line.length - 1; i++) {
    const a = line[i], b = line[i + 1];
    const seg = haversine(a.lat, a.lng, b.lat, b.lng);
    const r = pointToSegment(p, a, b);
    if (r.dist < best.dist) best = { dist: r.dist, along: acc + r.t * seg };
    acc += seg;
  }
  return best;
}

/** Cumulative segment lengths of a polyline (metres from the first vertex), cached per line array. */
const cumCache = new WeakMap();
function cumulative(line) {
  let cum = cumCache.get(line);
  if (cum) return cum;
  cum = new Float64Array(line.length);
  for (let i = 1; i < line.length; i++) cum[i] = cum[i - 1] + haversine(line[i - 1].lat, line[i - 1].lng, line[i].lat, line[i].lng);
  cumCache.set(line, cum);
  return cum;
}

/**
 * Where a point projects on a route (3.16 sweeper rule): the nearest segment within `maxLateralM`
 * (300 m), returned as { alongM, segIndex, lateralM } or null. With `fromIndex` (the rider's last
 * segment) only a window of segments around it is searched first, like the route-following code
 * paths; the whole line is scanned only when the window has nothing within reach. Cumulative
 * lengths are cached per line array, so repeated calls cost one small loop.
 */
function alongRoute(p, line, { fromIndex = null, maxLateralM = 300, window = 150 } = {}) {
  if (!Array.isArray(line) || line.length < 2 || !p) return null;
  const cum = cumulative(line);
  const scan = (from, to) => {
    let best = null;
    for (let i = from; i < to; i++) {
      const r = pointToSegment(p, line[i], line[i + 1]);
      if (r.dist <= maxLateralM && (!best || r.dist < best.lateralM)) {
        best = { alongM: cum[i] + r.t * (cum[i + 1] - cum[i]), segIndex: i, lateralM: r.dist };
      }
    }
    return best;
  };
  const last = line.length - 1;
  if (Number.isInteger(fromIndex) && fromIndex >= 0 && fromIndex < last) {
    const hit = scan(Math.max(0, fromIndex - window), Math.min(last, fromIndex + window + 1));
    if (hit) return hit;
  }
  return scan(0, last);
}

function polylineLength(line) {
  let d = 0;
  for (let i = 1; i < line.length; i++) d += haversine(line[i - 1].lat, line[i - 1].lng, line[i].lat, line[i].lng);
  return d;
}

// ---- Google encoded polyline (precision 1e5) ----
function encodeSigned(v) {
  let s = v < 0 ? ~(v << 1) : v << 1;
  let out = '';
  while (s >= 0x20) { out += String.fromCharCode((0x20 | (s & 0x1f)) + 63); s >>= 5; }
  return out + String.fromCharCode(s + 63);
}

function encodePolyline(points) {
  let lat = 0, lng = 0, out = '';
  for (const p of points) {
    const la = Math.round(p.lat * 1e5), ln = Math.round(p.lng * 1e5);
    out += encodeSigned(la - lat) + encodeSigned(ln - lng);
    lat = la; lng = ln;
  }
  return out;
}

/** Decodes an encoded polyline; returns null on malformed input. */
function decodePolyline(str, maxPoints = 100000) {
  if (typeof str !== 'string') return null;
  const pts = [];
  let i = 0, lat = 0, lng = 0;
  const next = () => {
    let result = 0, shift = 0, b;
    do {
      if (i >= str.length) return null;
      b = str.charCodeAt(i++) - 63;
      if (b < 0 || b > 63) return null;
      result |= (b & 0x1f) << shift;
      shift += 5;
      if (shift > 30) return null;
    } while (b >= 0x20);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };
  while (i < str.length) {
    const dLat = next(); if (dLat === null) return null;
    const dLng = next(); if (dLng === null) return null;
    lat += dLat; lng += dLng;
    pts.push({ lat: lat / 1e5, lng: lng / 1e5 });
    if (pts.length > maxPoints) return null;
  }
  return pts;
}

/** Douglas–Peucker simplification with a tolerance in metres. Keeps every other field on kept points. */
function simplify(points, toleranceM) {
  if (!toleranceM || points.length <= 2) return points.slice();
  const keep = new Uint8Array(points.length);
  keep[0] = 1; keep[points.length - 1] = 1;
  const stack = [[0, points.length - 1]];
  while (stack.length) {
    const [s, e] = stack.pop();
    let maxD = 0, idx = -1;
    for (let i = s + 1; i < e; i++) {
      const d = pointToSegment(points[i], points[s], points[e]).dist;
      if (d > maxD) { maxD = d; idx = i; }
    }
    if (idx >= 0 && maxD > toleranceM) { keep[idx] = 1; stack.push([s, idx], [idx, e]); }
  }
  return points.filter((_, i) => keep[i]);
}

/** Robust convoy centre: per-axis median of the given positions. */
function medianCentre(points) {
  if (!points.length) return null;
  const med = (arr) => {
    const s = [...arr].sort((a, b) => a - b);
    const m = s.length >> 1;
    return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
  };
  return { lat: med(points.map((p) => p.lat)), lng: med(points.map((p) => p.lng)) };
}

module.exports = { haversine, pointToSegment, distanceToPolyline, alongRoute, polylineLength, encodePolyline, decodePolyline, simplify, medianCentre };
