'use strict';
/**
 * Geohash (public domain algorithm, own code): base-32 cell ids for the road & safety intelligence.
 *   precision 4 ≈ 39 km × 20 km (regions, read tiles), 6 ≈ 1.2 km × 0.6 km (stretches), 7 ≈ 153 m × 153 m (spots).
 * Must match lib/domain/intel/geohash.dart.
 */
const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
const DECODE = Object.fromEntries([...BASE32].map((c, i) => [c, i]));
const VALID = /^[0-9b-hjkmnp-z]{1,12}$/;

function encode(lat, lng, precision = 7) {
  lat = Number(lat); lng = Number(lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) return null;
  let latLo = -90, latHi = 90, lngLo = -180, lngHi = 180;
  let out = '', bit = 0, ch = 0, even = true;
  while (out.length < precision) {
    if (even) {
      const mid = (lngLo + lngHi) / 2;
      if (lng >= mid) { ch = (ch << 1) | 1; lngLo = mid; } else { ch <<= 1; lngHi = mid; }
    } else {
      const mid = (latLo + latHi) / 2;
      if (lat >= mid) { ch = (ch << 1) | 1; latLo = mid; } else { ch <<= 1; latHi = mid; }
    }
    even = !even;
    if (++bit === 5) { out += BASE32[ch]; bit = 0; ch = 0; }
  }
  return out;
}

function isValid(h) { return typeof h === 'string' && VALID.test(h); }

/** { s, w, n, e } of a cell. */
function bbox(hash) {
  let latLo = -90, latHi = 90, lngLo = -180, lngHi = 180, even = true;
  for (const c of String(hash)) {
    const v = DECODE[c];
    if (v === undefined) return null;
    for (let b = 4; b >= 0; b--) {
      const on = (v >> b) & 1;
      if (even) { const mid = (lngLo + lngHi) / 2; if (on) lngLo = mid; else lngHi = mid; }
      else { const mid = (latLo + latHi) / 2; if (on) latLo = mid; else latHi = mid; }
      even = !even;
    }
  }
  return { s: latLo, w: lngLo, n: latHi, e: lngHi };
}

function center(hash) {
  const b = bbox(hash);
  if (!b) return null;
  const r = (x) => Math.round(x * 1e5) / 1e5;
  return { lat: r((b.s + b.n) / 2), lng: r((b.w + b.e) / 2) };
}

/** Cell size in degrees at a precision: { dLat, dLng }. */
function cellSize(precision) {
  const bits = precision * 5;
  const lngBits = Math.ceil(bits / 2), latBits = Math.floor(bits / 2);
  return { dLat: 180 / 2 ** latBits, dLng: 360 / 2 ** lngBits };
}

/**
 * Cells of `precision` covering a bbox, or null when more than `max` would be needed (the caller answers 400).
 */
function cover({ s, w, n, e }, precision = 4, max = 64) {
  if (![s, w, n, e].every(Number.isFinite) || s > n || w > e) return null;
  const { dLat, dLng } = cellSize(precision);
  const rows = Math.floor(n / dLat) - Math.floor(s / dLat) + 1;
  const cols = Math.floor(e / dLng) - Math.floor(w / dLng) + 1;
  if (rows * cols > max) return null;
  const out = new Set();
  for (let i = 0; i < rows; i++) {
    const lat = Math.min(89.9999, Math.max(-89.9999, (Math.floor(s / dLat) + i + 0.5) * dLat));
    for (let j = 0; j < cols; j++) {
      const lng = Math.min(179.9999, Math.max(-179.9999, (Math.floor(w / dLng) + j + 0.5) * dLng));
      out.add(encode(lat, lng, precision));
    }
  }
  return [...out];
}

function inBbox(p, b) { return p.lat >= b.s && p.lat <= b.n && p.lng >= b.w && p.lng <= b.e; }

module.exports = { encode, bbox, center, cover, cellSize, isValid, inBbox, BASE32 };
