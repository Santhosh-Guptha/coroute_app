'use strict';
/**
 * A small static picture of a ride's route for the ride summary e-mail (docs/features_355/lifecycle_emails.md).
 * Pure JavaScript (node:zlib only, no image library): the rider's own cleaned trail is drawn as one line on a
 * plain background with a start and an end marker, and encoded as an RGB PNG.
 *
 * Privacy: no map tiles, no coordinates, no place names. The first and the last `trimM` metres (default
 * 300 m) of the trail are left out before drawing, so the picture never shows the exact point where a
 * ride started or ended (often a home or a workplace). A trail shorter than twice that has no picture.
 * Signal gaps (a point with gap: true) are never bridged by a drawn line.
 */
const zlib = require('zlib');

const R_EARTH = 6371000;
const toRad = (d) => (d * Math.PI) / 180;
function haversine(a, b) {
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R_EARTH * Math.asin(Math.min(1, Math.sqrt(s)));
}

/** Valid trail points [{lat, lng, gap?}] from a trip document's breadcrumbTrail. */
function cleanTrail(trail) {
  const out = [];
  for (const p of Array.isArray(trail) ? trail : []) {
    const lat = Number(p && p.lat), lng = Number(p && p.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) continue;
    out.push({ lat, lng, gap: !!(p && p.gap) });
  }
  return out;
}

/** Cuts `m` metres off both ends (a point is interpolated at each cut). [] when too short. */
function trimEnds(points, m = 300) {
  if (points.length < 2) return [];
  const cum = [0];
  for (let i = 1; i < points.length; i++) cum.push(cum[i - 1] + haversine(points[i - 1], points[i]));
  const total = cum[cum.length - 1];
  if (!(total > 2 * m + 50)) return [];
  const at = (d) => {
    let i = 1;
    while (i < cum.length - 1 && cum[i] < d) i++;
    const seg = cum[i] - cum[i - 1] || 1;
    const f = Math.min(1, Math.max(0, (d - cum[i - 1]) / seg));
    return { i, p: { lat: points[i - 1].lat + (points[i].lat - points[i - 1].lat) * f, lng: points[i - 1].lng + (points[i].lng - points[i - 1].lng) * f, gap: false } };
  };
  const a = at(m);
  const b = at(total - m);
  const mid = points.slice(a.i, b.i).filter((p, k) => cum[a.i + k] > m && cum[a.i + k] < total - m);
  // The end cut lies on the segment (b.i-1 -> b.i): it is a gap when that segment is one.
  return [a.p, ...mid, { ...b.p, gap: !!points[b.i].gap }];
}

// ------------------------------------------------------------------ PNG
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
/** RGB pixels (Uint8Array w*h*3) -> PNG bytes. */
function encodePng(width, height, rgb) {
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width * 3 + 1)] = 0; // filter: none
    Buffer.from(rgb.buffer, rgb.byteOffset + y * width * 3, width * 3).copy(raw, y * (width * 3 + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0; // 8-bit RGB
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

const hex = (s) => [parseInt(s.slice(1, 3), 16), parseInt(s.slice(3, 5), 16), parseInt(s.slice(5, 7), 16)];

/**
 * The route picture: { png: Buffer, width, height, points } or null (no usable trail).
 * `trail`: the trip's breadcrumbTrail. Options: width, height, trimM, colours.
 */
function renderRoutePng(trail, { width = 600, height = 300, trimM = 300, pad = 28, line = '#5b4bd6', bg = '#f4f5f7', start = '#2f9e6b', end = '#e9a55b', lineWidth = 4 } = {}) {
  const pts = trimEnds(cleanTrail(trail), trimM);
  if (pts.length < 2) return null;
  // Equirectangular projection around the middle latitude, fitted into the box (aspect kept).
  const midLat = pts.reduce((s, p) => s + p.lat, 0) / pts.length;
  const kx = Math.cos(toRad(midLat));
  const xs = pts.map((p) => p.lng * kx), ys = pts.map((p) => -p.lat);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const spanX = Math.max(maxX - minX, 1e-6), spanY = Math.max(maxY - minY, 1e-6);
  const scale = Math.min((width - 2 * pad) / spanX, (height - 2 * pad) / spanY);
  const offX = (width - spanX * scale) / 2, offY = (height - spanY * scale) / 2;
  const P = pts.map((p, i) => ({ x: offX + (xs[i] - minX) * scale, y: offY + (ys[i] - minY) * scale, gap: p.gap }));

  // Coverage buffer (max of each shape's anti-aliased coverage), composited once per colour.
  const n = width * height;
  const rgb = new Uint8Array(n * 3);
  const [br, bgc, bb] = hex(bg);
  for (let i = 0; i < n; i++) { rgb[i * 3] = br; rgb[i * 3 + 1] = bgc; rgb[i * 3 + 2] = bb; }
  const paint = (cov, colour) => {
    const [r, g, b] = hex(colour);
    for (let i = 0; i < n; i++) {
      const a = cov[i];
      if (!a) continue;
      rgb[i * 3] = Math.round(rgb[i * 3] * (1 - a) + r * a);
      rgb[i * 3 + 1] = Math.round(rgb[i * 3 + 1] * (1 - a) + g * a);
      rgb[i * 3 + 2] = Math.round(rgb[i * 3 + 2] * (1 - a) + b * a);
    }
  };
  const capsule = (cov, a, b, r) => {
    const x0 = Math.max(0, Math.floor(Math.min(a.x, b.x) - r - 1)), x1 = Math.min(width - 1, Math.ceil(Math.max(a.x, b.x) + r + 1));
    const y0 = Math.max(0, Math.floor(Math.min(a.y, b.y) - r - 1)), y1 = Math.min(height - 1, Math.ceil(Math.max(a.y, b.y) + r + 1));
    const dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy;
    for (let y = y0; y <= y1; y++) {
      for (let x = x0; x <= x1; x++) {
        const px = x + 0.5, py = y + 0.5;
        const t = len2 ? Math.max(0, Math.min(1, ((px - a.x) * dx + (py - a.y) * dy) / len2)) : 0;
        const ex = a.x + t * dx - px, ey = a.y + t * dy - py;
        const c = Math.max(0, Math.min(1, r + 0.5 - Math.sqrt(ex * ex + ey * ey)));
        const i = y * width + x;
        if (c > cov[i]) cov[i] = c;
      }
    }
  };
  const lineCov = new Float32Array(n);
  for (let i = 1; i < P.length; i++) if (!P[i].gap) capsule(lineCov, P[i - 1], P[i], lineWidth / 2);
  paint(lineCov, line);
  const dot = (p, colour) => {
    const ring = new Float32Array(n); capsule(ring, p, p, 8); paint(ring, '#ffffff');
    const fill = new Float32Array(n); capsule(fill, p, p, 6); paint(fill, colour);
  };
  dot(P[0], start);
  dot(P[P.length - 1], end);
  return { png: encodePng(width, height, rgb), width, height, points: P.length };
}

module.exports = { renderRoutePng, trimEnds, cleanTrail, encodePng, haversine, crc32 };
