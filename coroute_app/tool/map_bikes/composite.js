// Composites the generated layers exactly like the app's painter (lib/presentation/rider/widgets/
// bike_rider_marker.dart, Bike3dPainter / BikeMarker3d): used by preview.mjs for contact sheets
// and the owner previews. Layer order and maths:
//   1. ground halo (state cue, does not rotate)
//   2. shadow   (rotated with the bike, offset in screen space by (0.8, 2.0) × size/64, alpha 0.9)
//   3. base     (rotated)
//   4. paint    (rotated, tinted: rgb × vehicleColour, alpha kept  == BlendMode.modulate)
//   5. gloss    (rotated, src-over)
//   stale: 1-5 desaturated (luma) at 55 % opacity; then status dot + role chip (upright).
const imgCache = new Map();
export function loadImg(src) {
  if (!imgCache.has(src)) {
    imgCache.set(src, new Promise((res, rej) => {
      const i = new Image();
      i.onload = () => res(i);
      i.onerror = () => rej(new Error('load ' + src));
      i.src = src;
    }));
  }
  return imgCache.get(src);
}

const tintCache = new Map();
export function tinted(img, argb, key) {
  const k = key + '|' + argb;
  if (tintCache.has(k)) return tintCache.get(k);
  const c = document.createElement('canvas');
  c.width = img.width;
  c.height = img.height;
  const x = c.getContext('2d');
  x.drawImage(img, 0, 0);
  const d = x.getImageData(0, 0, c.width, c.height);
  const p = d.data;
  const r = (argb >> 16) & 255, g = (argb >> 8) & 255, b = argb & 255;
  for (let i = 0; i < p.length; i += 4) {
    p[i] = (p[i] * r) / 255;
    p[i + 1] = (p[i + 1] * g) / 255;
    p[i + 2] = (p[i + 2] * b) / 255;
  }
  x.putImageData(d, 0, 0);
  tintCache.set(k, c);
  return c;
}

// Same as BikeSprite.paintArgb in Dart: very dark paints are lifted a little so the panels keep
// some shading (black stays black, but not a flat hole).
export function paintArgb(argb) {
  const r = (argb >> 16) & 255, g = (argb >> 8) & 255, b = argb & 255;
  const lift = (v) => Math.round(38 + (v * (255 - 38)) / 255);
  return (lift(r) << 16) | (lift(g) << 8) | lift(b);
}

const hex = (argb, a = 1) => `rgba(${(argb >> 16) & 255},${(argb >> 8) & 255},${argb & 255},${a})`;

// m: {type, riders, argb, heading (deg, screen), size, cue:'normal'|'stopped'|'warning'|'stale'|'sos',
//     me, selected, ring (argb), status (argb), role:'L'|'S'|'', label, base:'assets/map_bikes', scale:3}
export async function drawMarker(ctx, cx, cy, m) {
  const scale = m.scale ?? 3;
  const dir = `${m.base ?? '/assets/map_bikes'}${scale === 1 ? '' : `/${scale}.0x`}`;
  const name = `${m.type}_${m.riders}`;
  const [shadow, base, paint, gloss] = await Promise.all(['shadow', 'base', 'paint', 'gloss'].map((l) => loadImg(`${dir}/${name}_${l}.png`)));
  const box = m.size ?? 56;
  const S = box * (m.selected ? 1.12 : 1);
  const k = S / 64;
  const ring = m.ring ?? 0x1e63d6;
  // 1. halo == HaloPainter (Dart)
  const R = box * 0.44 * (m.selected ? 1.12 : 1);
  const halo = (color, a, w, rr = R) => {
    ctx.beginPath();
    ctx.arc(cx, cy, rr, 0, Math.PI * 2);
    ctx.strokeStyle = hex(color, a);
    ctx.lineWidth = w;
    ctx.stroke();
  };
  const fill = (color, a0, a1, rr = R) => {
    const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, rr * 1.05);
    g.addColorStop(0.2, hex(color, a0));
    g.addColorStop(1, hex(color, a1));
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.arc(cx, cy, rr * 1.05, 0, Math.PI * 2);
    ctx.fill();
  };
  const t = m.pulse ?? 0.5;
  if (m.cue === 'sos') {
    fill(0xe53935, 0.0, 0.32, R * 1.25);
    halo(0xe53935, 0.6 * (1 - t), 2.5, R * (1 + 0.45 * t));
    halo(0xe53935, 0.95, 3);
  } else if (m.cue === 'warning') {
    fill(0xf59e0b, 0.05, 0.22);
    halo(0xf59e0b, 0.95, 2.5);
  } else if (m.cue === 'stopped' && !m.me) {
    fill(0xf59e0b, 0.04, 0.14);
    halo(0xf59e0b, 0.8, 2);
  } else if (m.me) {
    fill(0x2f7cf6, 0.32, 0.0, R * 1.3);
    halo(0x2f7cf6, 0.9, 2.5);
  } else if (m.cue === 'stale') {
    halo(ring, 0.35, 1.5);
  } else {
    fill(ring, 0.03, 0.14);
    halo(ring, 0.7, 2);
  }
  if (m.selected) halo(0x000000, 0.18, 1, R + 4.6), halo(0xffffff, 1, 2.5, R + 3);
  ctx.save();
  if (m.cue === 'stale') {
    ctx.globalAlpha = 0.55;
    ctx.filter = 'grayscale(1)';
  }
  // 2-5. the bike
  const a = (m.heading * Math.PI) / 180;
  const draw = (img, dx = 0, dy = 0, alpha = 1) => {
    ctx.save();
    ctx.globalAlpha *= alpha;
    ctx.translate(cx + dx, cy + dy);
    ctx.rotate(a);
    ctx.drawImage(img, -S / 2, -S / 2, S, S);
    ctx.restore();
  };
  draw(shadow, 0.8 * k, 2.0 * k, 0.9);
  draw(base);
  draw(tinted(paint, paintArgb(m.argb), `${dir}/${name}`));
  draw(gloss);
  ctx.restore();
  // status dot + role chip: upright
  if (m.status != null) {
    const x = cx + box * 0.3, y = cy + box * 0.3;
    ctx.beginPath();
    ctx.arc(x, y, 6, 0, Math.PI * 2);
    ctx.fillStyle = '#fff';
    ctx.fill();
    ctx.beginPath();
    ctx.arc(x, y, 4.5, 0, Math.PI * 2);
    ctx.fillStyle = hex(m.status);
    ctx.fill();
  }
  if (m.role) {
    const x = cx - box * 0.36, y = cy - box * 0.36;
    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.3)';
    ctx.shadowBlur = 3;
    ctx.shadowOffsetY = 1;
    ctx.beginPath();
    ctx.roundRect(x - 9, y - 8, 18, 16, 6);
    ctx.fillStyle = '#0e7c86';
    ctx.fill();
    ctx.restore();
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = '#fff';
    ctx.beginPath();
    ctx.roundRect(x - 9, y - 8, 18, 16, 6);
    ctx.stroke();
    ctx.fillStyle = '#fff';
    ctx.font = '900 10px sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(m.role, x, y + 0.5);
  }
  if (m.label) {
    ctx.font = '800 11px sans-serif';
    const w = ctx.measureText(m.label).width + 16;
    const y = cy + box * 0.5 + 8;
    ctx.beginPath();
    ctx.roundRect(cx - w / 2, y, w, 18, 8);
    ctx.fillStyle = m.labelColor ?? '#1f2937';
    ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(m.label, cx, y + 9.5);
  }
}

export async function drawHero(ctx, x, y, w, h, m) {
  const scale = m.scale ?? 3;
  const dir = `/assets/garage_bikes${scale === 1 ? '' : `/${scale}.0x`}`;
  const name = `${m.type}_${m.riders ?? 0}`;
  const [base, paint, gloss] = await Promise.all(['base', 'paint', 'gloss'].map((l) => loadImg(`${dir}/${name}_${l}.png`)));
  ctx.drawImage(base, x, y, w, h);
  ctx.drawImage(tinted(paint, paintArgb(m.argb), `${dir}/${name}`), x, y, w, h);
  ctx.drawImage(gloss, x, y, w, h);
}

// A light / dark map-like background (roads, blocks, a park, water).
export function mapBackground(ctx, w, h, dark, seed = 3) {
  let s = seed;
  const rnd = () => ((s = (s * 16807) % 2147483647) / 2147483647);
  const C = dark
    ? { bg: '#1f2329', block: '#262b32', park: '#1f3326', water: '#16273a', road: '#3a414b', major: '#4b5563', edge: '#15181c' }
    : { bg: '#eef0ea', block: '#e4e6e0', park: '#d3ead0', water: '#b9d7f0', road: '#ffffff', major: '#fde7a6', edge: '#d6d8d2' };
  ctx.fillStyle = C.bg;
  ctx.fillRect(0, 0, w, h);
  for (let i = 0; i < 40; i++) {
    ctx.fillStyle = C.block;
    ctx.fillRect(rnd() * w, rnd() * h, 40 + rnd() * 120, 30 + rnd() * 90);
  }
  ctx.fillStyle = C.park;
  ctx.beginPath();
  ctx.ellipse(w * 0.78, h * 0.25, w * 0.14, h * 0.12, 0.3, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = C.water;
  ctx.beginPath();
  ctx.moveTo(0, h * 0.82);
  ctx.bezierCurveTo(w * 0.3, h * 0.74, w * 0.5, h * 0.95, w, h * 0.86);
  ctx.lineTo(w, h);
  ctx.lineTo(0, h);
  ctx.fill();
  const road = (pts, width, color) => {
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    for (const [lw, c] of [[width + 3, C.edge], [width, color]]) {
      ctx.beginPath();
      ctx.moveTo(pts[0][0] * w, pts[0][1] * h);
      for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0] * w, pts[i][1] * h);
      ctx.strokeStyle = c;
      ctx.lineWidth = lw;
      ctx.stroke();
    }
  };
  for (let i = 0; i < 7; i++) road([[rnd(), 0], [rnd(), 1]], 7, C.road);
  for (let i = 0; i < 6; i++) road([[0, rnd()], [1, rnd()]], 7, C.road);
  road([[0, 0.62], [0.25, 0.55], [0.55, 0.6], [0.8, 0.42], [1, 0.38]], 16, C.major);
}
