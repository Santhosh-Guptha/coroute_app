// CoRoute 3D map bikes: procedural, original low-poly-but-smooth motorcycles and riders (no brand
// designs). Browser ES module, used by render.html. Units are metres; the bike faces -Z (screen up
// in the top view), Y is up, X is the rider's right. Every mesh is tagged with a layer:
//   'paint'  the bike's painted panels (tinted at runtime with the rider's vehicleColor),
//   'base'   everything else (tyres, chrome, seat, rider gear, helmets, lights).
import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';

export const TYPES = ['commuter', 'scooter', 'sport', 'cruiser', 'adventure', 'offroad', 'electric', 'retro'];

// ---------------------------------------------------------------- materials (base layer)
const std = (color, roughness = 0.6, metalness = 0, extra = {}) => new THREE.MeshStandardMaterial({ color, roughness, metalness, ...extra });
const phys = (color, extra) => new THREE.MeshPhysicalMaterial({ color, ...extra });

export const MAT = {
  tyre: std(0x1a1b1d, 0.92),
  tread: std(0x111214, 0.95),
  rim: std(0x8f969d, 0.32, 1),
  chrome: std(0xf0f3f6, 0.1, 1),
  black: std(0x1e2024, 0.55, 0.1),
  satin: std(0x2a2d32, 0.45, 0.3),
  seat: std(0x17181a, 0.62, 0, { }),
  seatStitch: std(0x2b2724, 0.7),
  engine: std(0x55595f, 0.38, 0.75),
  alu: std(0xc9ced4, 0.42, 0.55),
  aluDark: std(0x3a3e44, 0.5, 0.6),
  jacket: std(0x555c66, 0.78),
  jacket2: std(0x7a6f74, 0.78),
  pants: std(0x30343a, 0.85),
  glove: std(0x121315, 0.7),
  boot: std(0x101113, 0.6),
  helmet: phys(0x22262c, { roughness: 0.32, metalness: 0.15, clearcoat: 1, clearcoatRoughness: 0.08 }),
  helmet2: phys(0xc9ced6, { roughness: 0.3, metalness: 0.15, clearcoat: 1, clearcoatRoughness: 0.08 }),
  visor: phys(0x07090c, { roughness: 0.04, metalness: 0.4, clearcoat: 1, clearcoatRoughness: 0.02 }),
  glass: phys(0x24323c, { roughness: 0.04, metalness: 0.2, clearcoat: 1, clearcoatRoughness: 0.02 }),
  lens: std(0xfff7dc, 0.15, 0, { emissive: 0xfff2c8, emissiveIntensity: 1.6 }),
  tail: std(0xff2a2a, 0.3, 0, { emissive: 0xff1a1a, emissiveIntensity: 1.2 }),
  amber: std(0xffa31a, 0.3, 0, { emissive: 0xff8c00, emissiveIntensity: 0.8 }),
  glow: std(0x29e6ff, 0.2, 0, { emissive: 0x18dcff, emissiveIntensity: 2.4 }),
  mirror: phys(0x9fb3c2, { roughness: 0.02, metalness: 1 }),
  plate: std(0xe9e9e4, 0.5),
  // 3.55 follow-up (type legibility at marker size): a tan stitching band on the retro bench,
  // a light grey carrier rack on the commuter.
  stitch: std(0xc8a273, 0.6),
  rack: std(0xb9bfc6, 0.35, 0.8),
};

// The painted panels share one material that the renderer swaps per pass.
export const PAINT = std(0xffffff, 0.5, 0);

// ---------------------------------------------------------------- geometry helpers
const V = (x, y, z) => new THREE.Vector3(x, y, z);
const UP = V(0, 1, 0);

class Kit {
  constructor() {
    this.root = new THREE.Group();
  }
  add(geo, mat, layer, pos, rot, scale) {
    const m = new THREE.Mesh(geo, mat);
    m.userData.layer = layer;
    m.userData.mat = mat;
    m.castShadow = true;
    m.receiveShadow = true;
    if (pos) m.position.copy(pos);
    if (rot) m.rotation.set(rot[0], rot[1], rot[2]);
    if (scale) m.scale.copy(scale);
    this.root.add(m);
    return m;
  }
  base(geo, mat, pos, rot, scale) {
    return this.add(geo, mat, 'base', pos, rot, scale);
  }
  paint(geo, pos, rot, scale) {
    return this.add(geo, PAINT, 'paint', pos, rot, scale);
  }
  // Ellipsoid with radii (rx, ry, rz).
  ell(layer, mat, c, rx, ry, rz, rot) {
    return this.add(new THREE.SphereGeometry(1, 40, 28), layer === 'paint' ? PAINT : mat, layer, c, rot, V(rx, ry, rz));
  }
  // Capsule from a to b with radius r.
  cap(layer, mat, a, b, r, scaleX = 1) {
    const d = b.clone().sub(a);
    const len = Math.max(d.length() - 0, 1e-4);
    const g = new THREE.CapsuleGeometry(r, len, 10, 20);
    const m = this.add(g, layer === 'paint' ? PAINT : mat, layer, a.clone().add(b).multiplyScalar(0.5));
    m.quaternion.setFromUnitVectors(UP, d.normalize());
    if (scaleX !== 1) m.scale.set(scaleX, 1, 1);
    return m;
  }
  // Cylinder from a to b.
  cyl(layer, mat, a, b, r1, r2 = r1, seg = 24) {
    const d = b.clone().sub(a);
    const g = new THREE.CylinderGeometry(r2, r1, d.length(), seg);
    const m = this.add(g, layer === 'paint' ? PAINT : mat, layer, a.clone().add(b).multiplyScalar(0.5));
    m.quaternion.setFromUnitVectors(UP, d.normalize());
    return m;
  }
  // A smooth tube through points.
  tube(layer, mat, pts, r, seg = 40) {
    const curve = new THREE.CatmullRomCurve3(pts, false, 'centripetal');
    return this.add(new THREE.TubeGeometry(curve, seg, r, 12, false), layer === 'paint' ? PAINT : mat, layer);
  }
  box(layer, mat, c, sx, sy, sz, radius, rot) {
    const g = new RoundedBoxGeometry(sx, sy, sz, 4, Math.min(radius, Math.min(sx, sy, sz) / 2 - 1e-3));
    return this.add(g, layer === 'paint' ? PAINT : mat, layer, c, rot);
  }
  // A body panel: a lathe-like loft through cross sections [{z, y, w, h}] (ellipses), capped.
  loft(layer, mat, secs, segs = 28) {
    const pos = [];
    const idx = [];
    const ring = segs;
    for (const s of secs) {
      for (let i = 0; i < ring; i++) {
        const a = (i / ring) * Math.PI * 2;
        const ca = Math.cos(a), sa = Math.sin(a);
        // superellipse for a slightly boxy panel
        const p = s.p ?? 2.4;
        const cx = Math.sign(ca) * Math.pow(Math.abs(ca), 2 / p);
        const sy = Math.sign(sa) * Math.pow(Math.abs(sa), 2 / p);
        const yTop = sy > 0 ? s.h * (s.top ?? 1) : s.h * (s.bot ?? 1);
        pos.push((s.x ?? 0) + cx * s.w, s.y + sy * yTop, s.z);
      }
    }
    for (let j = 0; j < secs.length - 1; j++) {
      for (let i = 0; i < ring; i++) {
        const a = j * ring + i, b = j * ring + ((i + 1) % ring), c = (j + 1) * ring + i, d = (j + 1) * ring + ((i + 1) % ring);
        idx.push(a, b, c, b, d, c);
      }
    }
    // caps
    const capOf = (j, flip) => {
      const s = secs[j];
      const ci = pos.length / 3;
      pos.push(s.x ?? 0, s.y, s.z);
      for (let i = 0; i < ring; i++) {
        const a = j * ring + i, b = j * ring + ((i + 1) % ring);
        if (flip) idx.push(ci, b, a);
        else idx.push(ci, a, b);
      }
    };
    capOf(0, true);
    capOf(secs.length - 1, false);
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setIndex(idx);
    g.computeVertexNormals();
    return this.add(g, layer === 'paint' ? PAINT : mat, layer);
  }
}

// ---------------------------------------------------------------- parts
function wheel(k, z, R, w, opt = {}) {
  const y = R;
  const t = new THREE.TorusGeometry(R - w / 2, w / 2, 20, 64);
  k.base(t, MAT.tyre, V(0, y, z), [0, Math.PI / 2, 0], V(1, 1, opt.squash ?? 1));
  // rim + hub
  k.cyl('base', opt.rimMat ?? MAT.rim, V(-w * 0.32, y, z), V(w * 0.32, y, z), R - w * 0.95, R - w * 0.95, 40);
  k.cyl('base', MAT.satin, V(-w * 0.55, y, z), V(w * 0.55, y, z), R * 0.22, R * 0.22, 20);
  if (opt.disc) k.cyl('base', MAT.chrome, V(-w * 0.62, y, z), V(-w * 0.56, y, z), R * 0.62, R * 0.62, 40);
  if (opt.knobby) {
    const n = 26;
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2;
      const rr = R - w * 0.08;
      const kz = z + Math.cos(a) * rr, ky = y + Math.sin(a) * rr;
      for (const sx of [-1, 1]) {
        const b = k.box('base', MAT.tread, V(sx * w * 0.24 * (i % 2 ? 1 : 0.55), ky, kz), w * 0.36, w * 0.28, w * 0.34, 0.006);
        b.rotation.x = -a;
      }
    }
  }
}

function fork(k, zAxle, R, topZ, topY, spread, r = 0.024, mat = MAT.chrome) {
  for (const sx of [-1, 1]) k.cyl('base', mat, V(sx * spread, R, zAxle), V(sx * spread, topY, topZ), r, r * 1.15);
}

// Handlebar through grip points, clamp at (0, y, z).
function bars(k, o) {
  const { half, y, z, rise = 0.04, sweep = 0.06, mat = MAT.black, gripMat = MAT.glove } = o;
  const L = V(-half, y + rise, z + sweep), R = V(half, y + rise, z + sweep);
  k.tube('base', mat, [L, V(-half * 0.55, y + rise * 0.6, z + sweep * 0.2), V(0, y, z), V(half * 0.55, y + rise * 0.6, z + sweep * 0.2), R], 0.014);
  for (const g of [L, R]) {
    const s = Math.sign(g.x);
    k.cap('base', MAT.black, V(g.x - s * 0.02, g.y, g.z), V(g.x + s * 0.06, g.y, g.z + 0.005), 0.019);
  }
  if (o.levers !== false) {
    for (const s of [-1, 1]) k.tube('base', MAT.satin, [V(s * half * 0.7, y + rise * 0.8, z + sweep * 0.5 - 0.02), V(s * half * 0.88, y + rise, z + sweep - 0.06), V(s * half * 1.02, y + rise, z + sweep - 0.05)], 0.006, 8);
  }
  if (o.mirrors) {
    const m = o.mirrors;
    for (const s of [-1, 1]) {
      const base = V(s * half * 0.72, y + rise * 0.7, z + sweep * 0.3);
      const head = V(s * (half * 0.72 + m.out), y + m.up, z + m.fwd);
      k.tube('base', MAT.black, [base, base.clone().lerp(head, 0.5).add(V(0, 0.03, 0)), head], 0.006, 10);
      k.ell('base', m.mat ?? MAT.black, head, m.w ?? 0.055, 0.035, 0.022);
      k.ell('base', MAT.mirror, head.clone().add(V(0, 0, 0.012)), (m.w ?? 0.055) * 0.82, 0.028, 0.014);
    }
  }
  if (o.guards) {
    for (const s of [-1, 1]) {
      k.tube('base', o.guardMat ?? MAT.black, [V(s * half * 0.7, y + rise, z + sweep - 0.02), V(s * (half + 0.02), y + rise + 0.02, z + sweep - 0.1), V(s * (half + 0.07), y + rise, z + sweep - 0.02)], 0.022, 16);
    }
  }
  return { L, R };
}

function headlight(k, z, y, r, opt = {}) {
  const x = opt.x ?? 0;
  if (opt.bucket !== false) k.ell(opt.bucketLayer ?? 'base', opt.bucketMat ?? MAT.black, V(x, y, z + r * 0.35), r * 1.08, r * 1.08, r * 0.9);
  if (opt.ring) k.add(new THREE.TorusGeometry(r * 1.0, r * 0.12, 10, 40), MAT.chrome, 'base', V(x, y, z - r * 0.15));
  k.ell('base', MAT.lens, V(x, y, z - r * 0.12), r * 0.9, r * 0.9, r * 0.35);
}

function tailLight(k, z, y, w = 0.06) {
  k.box('base', MAT.tail, V(0, y, z), w, 0.028, 0.03, 0.01);
}

function indicators(k, zF, yF, wF, zR, yR, wR) {
  for (const s of [-1, 1]) {
    k.ell('base', MAT.amber, V(s * wF, yF, zF), 0.022, 0.018, 0.03);
    k.ell('base', MAT.amber, V(s * wR, yR, zR), 0.02, 0.016, 0.028);
  }
}

function exhaust(k, pts, r, tipR, mat = MAT.chrome) {
  k.tube('base', mat, pts, r, 32);
  const a = pts[pts.length - 2], b = pts[pts.length - 1];
  const d = b.clone().sub(a).normalize();
  k.cyl('base', mat, b.clone().sub(d.clone().multiplyScalar(0.28)), b, tipR, tipR * 0.92);
  k.cyl('base', MAT.black, b.clone().sub(d.clone().multiplyScalar(0.01)), b.clone().add(d.clone().multiplyScalar(0.003)), tipR * 0.7, tipR * 0.7);
}

function engineBlock(k, z, y, w, h, l) {
  k.box('base', MAT.engine, V(0, y, z), w, h, l, 0.04);
  // cylinder + head, leaning forward, finned (gives the side view its mass)
  const cz = z - l * 0.12, cy = y + h * 0.62;
  k.box('base', MAT.engine, V(0, cy, cz), w * 0.72, h * 0.62, l * 0.5, 0.03, [-0.22, 0, 0]);
  for (let i = 0; i < 5; i++) k.box('base', MAT.aluDark, V(0, cy - h * 0.22 + i * h * 0.11, cz - i * 0.006), w * 0.82, 0.008, l * 0.56, 0.003, [-0.22, 0, 0]);
  k.cyl('base', MAT.chrome, V(-w * 0.52, y - h * 0.05, z + l * 0.1), V(-w * 0.5, y - h * 0.05, z + l * 0.1), h * 0.32, h * 0.32, 30);
  for (let i = 0; i < 4; i++) k.box('base', MAT.aluDark, V(0, y + h / 2 - 0.02 - i * 0.03, z - l * 0.1), w * 1.12, 0.012, l * 0.55, 0.004);
}

// ---------------------------------------------------------------- riders
// pose: {hip:[y,z], lean (rad, + forward), torso, grips:{L,R}, knee:[x,y,z], foot:[x,y,z], helmet, jacket, elbowsOut}
function rider(k, p) {
  const hip = V(0, p.hip[0], p.hip[1]);
  const lean = p.lean;
  const tl = p.torso ?? 0.5;
  const dir = V(0, Math.cos(lean), -Math.sin(lean));
  const sh = hip.clone().add(dir.clone().multiplyScalar(tl));
  const jacket = p.jacket ?? MAT.jacket;
  // Torso: a tapered body from hips to chest, flattened front to back.
  const chest = hip.clone().add(dir.clone().multiplyScalar(tl * 0.62));
  k.ell('base', jacket, chest, 0.19 * (p.bulk ?? 1), tl * 0.5, 0.13, [-lean, 0, 0]);
  k.ell('base', jacket, hip.clone().add(dir.clone().multiplyScalar(tl * 0.18)), 0.17 * (p.bulk ?? 1), 0.13, 0.12, [-lean, 0, 0]);
  // Shoulders: a rounded yoke.
  const sw = 0.2 * (p.bulk ?? 1);
  k.cap('base', jacket, sh.clone().add(V(-sw, -0.03, 0)), sh.clone().add(V(sw, -0.03, 0)), 0.075);
  // Back hump (protector) reads as a 3D back from above.
  k.ell('base', p.back ?? jacket, sh.clone().add(dir.clone().multiplyScalar(-0.14)).add(V(0, 0.02, 0.05)), 0.15, 0.17, 0.07, [-lean, 0, 0]);
  // Arms to the grips.
  for (const s of [-1, 1]) {
    const S = sh.clone().add(V(s * sw, -0.04, 0.01));
    const G = s < 0 ? p.grips.L.clone() : p.grips.R.clone();
    G.x -= s * 0.01;
    const mid = S.clone().lerp(G, 0.5).add(V(s * (p.elbowsOut ?? 0.05), -0.05 + (p.elbowUp ?? 0), 0.02));
    k.cap('base', jacket, S, mid, 0.055);
    k.cap('base', jacket, mid, G.clone().add(V(-s * 0.005, 0.01, 0.03)), 0.048);
    k.ell('base', MAT.glove, G.clone().add(V(0, 0.012, 0.0)), 0.04, 0.035, 0.05);
  }
  // Legs.
  for (const s of [-1, 1]) {
    const H = hip.clone().add(V(s * 0.11, -0.02, 0.02));
    const K = V(s * p.knee[0], p.knee[1], p.knee[2]);
    const F = V(s * p.foot[0], p.foot[1], p.foot[2]);
    k.cap('base', MAT.pants, H, K, 0.075);
    k.cap('base', MAT.pants, K, F, 0.058);
    k.ell('base', MAT.boot, F.clone().add(V(0, 0.0, -0.05)), 0.05, 0.05, 0.11);
  }
  // Neck + helmet.
  const head = sh.clone().add(V(0, 0.17 + (p.headUp ?? 0), -0.04 - (p.headFwd ?? 0)));
  k.cap('base', MAT.pants, sh.clone().add(V(0, 0.02, 0)), head.clone().add(V(0, -0.08, 0.02)), 0.05);
  const hm = p.helmet ?? MAT.helmet;
  k.ell('base', hm, head, 0.128, 0.135, 0.152);
  // Visor: the front-upper cap of a slightly larger sphere.
  const vis = new THREE.SphereGeometry(1, 40, 24, Math.PI * 0.62, Math.PI * 0.76, Math.PI * 0.3, Math.PI * 0.32);
  const vm = k.add(vis, MAT.visor, 'base', head.clone().add(V(0, 0.004, 0)), [0, 0, 0], V(0.134, 0.14, 0.158));
  vm.rotation.y = Math.PI; // gap faces back => visor faces -Z
  // Helmet crest line (a subtle ridge catches light from above).
  k.ell('base', hm, head.clone().add(V(0, 0.11, 0.02)), 0.022, 0.03, 0.11);
  return { hip, sh, head };
}

// ---------------------------------------------------------------- bikes
// Every builder returns {k, seatTop:[y,z] for rider hip, pillionHip:[y,z], grips, pose}
const builders = {
  commuter(k) {
    const wb = 1.27, R = 0.3, zf = -wb / 2, zr = wb / 2;
    wheel(k, zf, R, 0.095, { disc: true });
    wheel(k, zr, R, 0.11);
    fork(k, zf, R, zf + 0.2, 0.86, 0.075);
    // frame & engine
    k.tube('base', MAT.black, [V(0, 0.84, zf + 0.22), V(0, 0.76, -0.25), V(0, 0.5, 0.05), V(0, 0.38, 0.12)], 0.03);
    engineBlock(k, -0.02, 0.36, 0.24, 0.24, 0.36);
    for (const s of [-1, 1]) k.cyl('base', MAT.satin, V(s * 0.1, R, zr), V(s * 0.1, 0.42, 0.1), 0.02);
    // paint: tank with knee recesses, side covers, tail, front fender, headlamp cowl
    // Slim tank (a commuter's narrow teardrop, much narrower than the retro / electric bodies).
    k.loft('paint', null, [
      { z: -0.42, y: 0.8, w: 0.05, h: 0.06 },
      { z: -0.33, y: 0.83, w: 0.1, h: 0.09 },
      { z: -0.16, y: 0.84, w: 0.11, h: 0.1, bot: 0.8 },
      { z: 0.0, y: 0.8, w: 0.09, h: 0.08, bot: 0.8 },
      { z: 0.06, y: 0.77, w: 0.06, h: 0.05 },
    ]);
    k.loft('paint', null, [
      { z: 0.12, y: 0.68, w: 0.1, h: 0.07 },
      { z: 0.35, y: 0.73, w: 0.1, h: 0.06 },
      { z: 0.52, y: 0.77, w: 0.075, h: 0.045 },
      { z: 0.58, y: 0.78, w: 0.05, h: 0.03 },
    ]);
    k.loft('paint', null, [
      { z: zf - 0.22, y: 0.44, w: 0.07, h: 0.012, p: 2 },
      { z: zf - 0.05, y: 0.5, w: 0.075, h: 0.014, p: 2 },
      { z: zf + 0.15, y: 0.43, w: 0.07, h: 0.012, p: 2 },
    ]);
    k.ell('paint', null, V(0, 0.9, zf + 0.14), 0.12, 0.1, 0.11);
    headlight(k, zf + 0.05, 0.88, 0.075, { bucket: false });
    // Simple flat seat: one even slab, narrow, square ends.
    k.box('base', MAT.seat, V(0, 0.86, 0.26), 0.2, 0.05, 0.56, 0.022);
    // Rear carrier rack (the commuter's mark from above): a light frame with cross bars behind the
    // seat, wider than the tail, on two struts.
    {
      const y = 0.9, z0 = 0.5, z1 = 0.94, hw = 0.16;
      k.tube('base', MAT.rack, [V(-hw, y, z0), V(-hw, y, z1 - 0.03), V(-hw + 0.03, y, z1), V(hw - 0.03, y, z1), V(hw, y, z1 - 0.03), V(hw, y, z0)], 0.017, 48);
      for (const z of [0.62, 0.74, 0.86]) k.cyl('base', MAT.rack, V(-hw, y, z), V(hw, y, z), 0.016, 0.016, 12);
      k.cyl('base', MAT.rack, V(0, y, z0), V(0, y, z1), 0.012, 0.012, 12);
      for (const sx of [-1, 1]) k.cyl('base', MAT.satin, V(sx * hw, y, z0 + 0.05), V(sx * 0.1, 0.62, 0.62), 0.012, 0.012, 10);
    }
    tailLight(k, 0.96, 0.84, 0.07);
    indicators(k, zf + 0.12, 0.86, 0.15, 0.94, 0.82, 0.2);
    exhaust(k, [V(0.06, 0.28, -0.12), V(0.12, 0.24, 0.1), V(0.16, 0.35, 0.45), V(0.17, 0.42, 0.68)], 0.025, 0.045);
    const g = bars(k, { half: 0.36, y: 0.98, z: zf + 0.24, rise: 0.03, sweep: 0.06, mirrors: { out: 0.06, up: 0.2, fwd: -0.02 } });
    return { mid: [0.0, 0.5, 0.82, 0.5, 0.17], sideCover: true, grips: g, pose: { hip: [0.92, 0.18], lean: 0.18, knee: [0.17, 0.78, -0.18], foot: [0.16, 0.35, 0.02], grips: g, elbowsOut: 0.06 }, pillion: [0.97, 0.47] };
  },

  scooter(k) {
    const wb = 1.3, R = 0.22, zf = -wb / 2, zr = wb / 2;
    wheel(k, zf, R, 0.11, { disc: true });
    wheel(k, zr, R, 0.125);
    fork(k, zf, R, zf + 0.12, 0.85, 0.06, 0.022, MAT.black);
    // floorboard
    k.box('base', MAT.black, V(0, 0.27, -0.06), 0.36, 0.05, 0.6, 0.02);
    k.box('base', MAT.satin, V(0, 0.3, -0.06), 0.3, 0.012, 0.52, 0.004);
    // apron (leg shield): wide paint shell curving round the front
    k.loft('paint', null, [
      { z: zf - 0.02, y: 0.62, w: 0.12, h: 0.34, top: 1, bot: 1, p: 2.6 },
      { z: zf + 0.1, y: 0.62, w: 0.22, h: 0.36, top: 1, bot: 1, p: 3 },
      { z: zf + 0.2, y: 0.6, w: 0.25, h: 0.35, top: 1, bot: 1, p: 3.2 },
      { z: zf + 0.24, y: 0.6, w: 0.22, h: 0.3, p: 3 },
    ]);
    // headset cover (painted) with lamp
    k.loft('paint', null, [
      { z: zf + 0.06, y: 1.0, w: 0.12, h: 0.05 },
      { z: zf + 0.16, y: 1.01, w: 0.2, h: 0.06 },
      { z: zf + 0.3, y: 1.0, w: 0.17, h: 0.05 },
    ]);
    headlight(k, zf + 0.06, 1.0, 0.055, { bucket: false });
    // front fender over the small wheel
    k.loft('paint', null, [
      { z: zf - 0.18, y: 0.3, w: 0.08, h: 0.03 },
      { z: zf, y: 0.34, w: 0.09, h: 0.035 },
      { z: zf + 0.12, y: 0.3, w: 0.08, h: 0.03 },
    ]);
    // rear body: bulbous side panels
    k.loft('paint', null, [
      { z: 0.08, y: 0.45, w: 0.13, h: 0.16 },
      { z: 0.25, y: 0.52, w: 0.21, h: 0.22 },
      { z: 0.5, y: 0.55, w: 0.2, h: 0.2 },
      { z: 0.72, y: 0.6, w: 0.13, h: 0.13 },
      { z: 0.8, y: 0.62, w: 0.06, h: 0.07 },
    ]);
    // step-through tunnel
    k.loft('paint', null, [
      { z: -0.36, y: 0.38, w: 0.08, h: 0.08 },
      { z: -0.1, y: 0.36, w: 0.07, h: 0.06 },
      { z: 0.1, y: 0.42, w: 0.1, h: 0.1 },
    ]);
    // seat: long, wide
    k.loft('base', MAT.seat, [
      { z: 0.08, y: 0.76, w: 0.15, h: 0.04, bot: 1.6 },
      { z: 0.3, y: 0.77, w: 0.19, h: 0.055, bot: 1.6 },
      { z: 0.58, y: 0.8, w: 0.16, h: 0.05, bot: 1.6 },
      { z: 0.7, y: 0.79, w: 0.09, h: 0.03 },
    ]);
    // grab rail
    k.tube('base', MAT.satin, [V(-0.17, 0.75, 0.56), V(-0.16, 0.79, 0.75), V(0, 0.8, 0.82), V(0.16, 0.79, 0.75), V(0.17, 0.75, 0.56)], 0.014);
    tailLight(k, 0.82, 0.64, 0.09);
    indicators(k, zf + 0.06, 0.92, 0.19, 0.8, 0.62, 0.12);
    exhaust(k, [V(0.1, 0.22, 0.15), V(0.15, 0.24, 0.4), V(0.17, 0.3, 0.7)], 0.02, 0.04, MAT.satin);
    const g = bars(k, { half: 0.33, y: 1.02, z: zf + 0.2, rise: 0.0, sweep: 0.03, levers: false, mirrors: { out: 0.08, up: 0.17, fwd: -0.02 } });
    return { grips: g, pose: { hip: [0.83, 0.28], lean: -0.02, knee: [0.13, 0.66, -0.12], foot: [0.1, 0.31, -0.2], grips: g, elbowsOut: 0.04 }, pillion: [0.88, 0.57] };
  },

  sport(k) {
    const wb = 1.38, R = 0.31, zf = -wb / 2, zr = wb / 2;
    wheel(k, zf, R, 0.12, { disc: true });
    wheel(k, zr, R, 0.18);
    fork(k, zf, R, zf + 0.26, 0.8, 0.085, 0.028, MAT.alu);
    // twin-spar frame
    for (const s of [-1, 1]) k.tube('base', MAT.alu, [V(s * 0.1, 0.8, zf + 0.3), V(s * 0.15, 0.72, -0.1), V(s * 0.1, 0.55, 0.15)], 0.03);
    engineBlock(k, 0.0, 0.42, 0.26, 0.26, 0.36);
    // swingarm
    for (const s of [-1, 1]) k.tube('base', MAT.alu, [V(s * 0.1, 0.45, 0.15), V(s * 0.12, R + 0.03, zr - 0.05)], 0.028);
    // fairing: narrow pointed nose widening at the knees
    k.loft('paint', null, [
      { z: zf - 0.07, y: 0.72, w: 0.04, h: 0.04 },
      { z: zf + 0.05, y: 0.71, w: 0.13, h: 0.1 },
      { z: zf + 0.22, y: 0.66, w: 0.19, h: 0.2, top: 0.9 },
      { z: zf + 0.42, y: 0.6, w: 0.2, h: 0.24 },
      { z: -0.06, y: 0.56, w: 0.17, h: 0.22, top: 1.1 },
      { z: 0.06, y: 0.5, w: 0.12, h: 0.12 },
    ]);
    // tank: tall, under the tucked chest
    k.loft('paint', null, [
      { z: -0.36, y: 0.86, w: 0.08, h: 0.06 },
      { z: -0.26, y: 0.9, w: 0.16, h: 0.09 },
      { z: -0.08, y: 0.91, w: 0.17, h: 0.1 },
      { z: 0.06, y: 0.86, w: 0.12, h: 0.08 },
    ]);
    // tail: sharp, kicked up
    k.loft('paint', null, [
      { z: 0.14, y: 0.8, w: 0.12, h: 0.06 },
      { z: 0.4, y: 0.88, w: 0.11, h: 0.06 },
      { z: 0.62, y: 0.95, w: 0.06, h: 0.04 },
      { z: 0.72, y: 0.98, w: 0.02, h: 0.02 },
    ]);
    // screen (smoked bubble)
    k.loft('base', MAT.glass, [
      { z: zf + 0.06, y: 0.82, w: 0.1, h: 0.012, p: 2 },
      { z: zf + 0.2, y: 0.9, w: 0.13, h: 0.014, p: 2 },
      { z: zf + 0.3, y: 0.92, w: 0.11, h: 0.012, p: 2 },
    ]);
    // twin headlights in the nose
    for (const s of [-1, 1]) k.ell('base', MAT.lens, V(s * 0.06, 0.73, zf + 0.02), 0.035, 0.022, 0.03, [0, s * 0.4, 0]);
    // front fender
    k.loft('paint', null, [
      { z: zf - 0.2, y: 0.45, w: 0.07, h: 0.012, p: 2 },
      { z: zf - 0.02, y: 0.48, w: 0.075, h: 0.012, p: 2 },
      { z: zf + 0.14, y: 0.42, w: 0.07, h: 0.012, p: 2 },
    ]);
    // seats: rider + pillion step
    k.loft('base', MAT.seat, [
      { z: 0.06, y: 0.84, w: 0.12, h: 0.025 },
      { z: 0.22, y: 0.85, w: 0.13, h: 0.03 },
      { z: 0.3, y: 0.86, w: 0.1, h: 0.025 },
    ]);
    k.loft('base', MAT.seat, [
      { z: 0.36, y: 0.92, w: 0.08, h: 0.025 },
      { z: 0.5, y: 0.95, w: 0.08, h: 0.025 },
      { z: 0.56, y: 0.95, w: 0.05, h: 0.02 },
    ]);
    tailLight(k, 0.72, 0.96, 0.04);
    exhaust(k, [V(0.05, 0.25, -0.15), V(0.14, 0.25, 0.1), V(0.17, 0.4, 0.35), V(0.17, 0.5, 0.52)], 0.025, 0.05, MAT.aluDark);
    // clip-ons: low and narrow, mirrors on the fairing
    const g = bars(k, { half: 0.29, y: 0.86, z: zf + 0.33, rise: -0.02, sweep: 0.04, mat: MAT.satin, mirrors: { out: 0.09, up: 0.06, fwd: -0.16, w: 0.06, mat: PAINT } });
    // mirror housings painted: retag
    k.root.children.filter((m) => m.userData.mat === PAINT && m.userData.layer === 'base').forEach((m) => ((m.userData.layer = 'paint'), (m.userData.noWiden = true)));
    return { mid: [0.05, 0.45, 0.84, 0.55, 0.15], grips: g, pose: { hip: [0.9, 0.23], lean: 0.95, torso: 0.52, knee: [0.18, 0.72, -0.12], foot: [0.17, 0.48, 0.15], grips: g, elbowsOut: 0.1, elbowUp: 0.04, headFwd: 0.08, headUp: -0.04 }, pillion: [1.0, 0.47] };
  },

  cruiser(k) {
    const wb = 1.62, Rf = 0.33, Rr = 0.32, zf = -wb / 2, zr = wb / 2;
    wheel(k, zf, Rf, 0.13, { disc: true, rimMat: MAT.chrome });
    wheel(k, zr, Rr, 0.19, { rimMat: MAT.chrome });
    fork(k, zf, Rf, zf + 0.35, 0.9, 0.1, 0.03, MAT.chrome);
    // V-twin
    engineBlock(k, -0.08, 0.38, 0.26, 0.22, 0.42);
    for (const s of [-1, 1]) k.cyl('base', MAT.chrome, V(0, 0.42, -0.08 + s * 0.12), V(s * 0.05, 0.62, -0.08 + s * 0.2), 0.07, 0.065);
    // frame
    k.tube('base', MAT.black, [V(0, 0.92, zf + 0.36), V(0, 0.68, -0.2), V(0, 0.42, 0.25), V(0, 0.42, zr - 0.1)], 0.03);
    // teardrop tank, long
    k.loft('paint', null, [
      { z: -0.5, y: 0.76, w: 0.06, h: 0.05 },
      { z: -0.4, y: 0.79, w: 0.14, h: 0.09 },
      { z: -0.2, y: 0.8, w: 0.17, h: 0.1, bot: 0.8 },
      { z: -0.02, y: 0.76, w: 0.13, h: 0.08 },
      { z: 0.04, y: 0.74, w: 0.06, h: 0.05 },
    ]);
    // big fenders
    k.loft('paint', null, [
      { z: zf - 0.26, y: 0.38, w: 0.1, h: 0.02, p: 2 },
      { z: zf - 0.1, y: 0.62, w: 0.11, h: 0.025, p: 2 },
      { z: zf + 0.12, y: 0.62, w: 0.11, h: 0.025, p: 2 },
      { z: zf + 0.26, y: 0.45, w: 0.1, h: 0.02, p: 2 },
    ]);
    k.loft('paint', null, [
      { z: zr - 0.32, y: 0.62, w: 0.15, h: 0.03, p: 2 },
      { z: zr - 0.05, y: 0.68, w: 0.155, h: 0.035, p: 2 },
      { z: zr + 0.22, y: 0.6, w: 0.15, h: 0.03, p: 2 },
      { z: zr + 0.34, y: 0.45, w: 0.13, h: 0.025, p: 2 },
    ]);
    // stepped seat, low and wide
    k.loft('base', MAT.seat, [
      { z: 0.02, y: 0.68, w: 0.14, h: 0.04, bot: 1.5 },
      { z: 0.2, y: 0.66, w: 0.2, h: 0.055, bot: 1.5 },
      { z: 0.36, y: 0.7, w: 0.16, h: 0.05, bot: 1.5 },
      { z: 0.52, y: 0.75, w: 0.12, h: 0.04 },
      { z: 0.66, y: 0.77, w: 0.11, h: 0.04 },
      { z: 0.72, y: 0.76, w: 0.06, h: 0.025 },
    ]);
    // round headlight with chrome ring + spotlights
    headlight(k, zf + 0.22, 0.86, 0.09, { ring: true, bucketMat: MAT.chrome });
    for (const s of [-1, 1]) headlight(k, zf + 0.24, 0.7, 0.04, { ring: true, bucketMat: MAT.chrome, x: s * 0.15 });
    tailLight(k, zr + 0.3, 0.6, 0.07);
    indicators(k, zf + 0.25, 0.82, 0.2, zr + 0.25, 0.6, 0.18);
    // twin chrome pipes on the right
    exhaust(k, [V(0.1, 0.5, -0.24), V(0.17, 0.3, -0.05), V(0.2, 0.3, 0.4), V(0.2, 0.33, 0.95)], 0.028, 0.045);
    exhaust(k, [V(0.1, 0.5, 0.02), V(0.17, 0.4, 0.1), V(0.23, 0.42, 0.4), V(0.23, 0.45, 0.92)], 0.028, 0.045);
    // forward controls
    for (const s of [-1, 1]) k.cyl('base', MAT.chrome, V(s * 0.16, 0.38, -0.38), V(s * 0.24, 0.38, -0.38), 0.016);
    // wide pull-back bars
    const g = bars(k, { half: 0.45, y: 1.0, z: zf + 0.42, rise: 0.08, sweep: 0.2, mat: MAT.chrome, mirrors: { out: 0.02, up: 0.22, fwd: -0.0, mat: MAT.chrome } });
    return { mid: [0.0, 0.48, 0.66, 0.44, 0.17], grips: g, pose: { hip: [0.73, 0.22], lean: -0.17, knee: [0.21, 0.6, -0.32], foot: [0.21, 0.4, -0.45], grips: g, elbowsOut: 0.05, bulk: 1.05 }, pillion: [0.82, 0.58] };
  },

  adventure(k) {
    const wb = 1.5, Rf = 0.34, Rr = 0.32, zf = -wb / 2, zr = wb / 2;
    wheel(k, zf, Rf, 0.11, { disc: true, knobby: false });
    wheel(k, zr, Rr, 0.15);
    fork(k, zf, Rf, zf + 0.3, 1.0, 0.09, 0.03, MAT.aluDark);
    engineBlock(k, -0.05, 0.42, 0.3, 0.26, 0.4);
    k.box('base', MAT.alu, V(0, 0.25, -0.05), 0.24, 0.03, 0.5, 0.01); // bash plate
    for (const s of [-1, 1]) k.tube('base', MAT.black, [V(s * 0.17, 0.55, -0.38), V(s * 0.26, 0.5, -0.2), V(s * 0.22, 0.35, -0.02)], 0.016); // crash bars
    // tall beak fender
    k.loft('paint', null, [
      { z: zf - 0.24, y: 0.74, w: 0.04, h: 0.015, p: 2 },
      { z: zf - 0.1, y: 0.82, w: 0.08, h: 0.02, p: 2 },
      { z: zf + 0.08, y: 0.88, w: 0.1, h: 0.025, p: 2 },
    ]);
    // big tank + side shrouds
    k.loft('paint', null, [
      { z: zf + 0.16, y: 0.9, w: 0.1, h: 0.1 },
      { z: zf + 0.3, y: 0.92, w: 0.21, h: 0.15 },
      { z: -0.24, y: 0.94, w: 0.24, h: 0.15 },
      { z: -0.05, y: 0.94, w: 0.21, h: 0.12, bot: 1.2 },
      { z: 0.06, y: 0.92, w: 0.13, h: 0.08 },
    ]);
    // tall screen
    k.loft('base', MAT.glass, [
      { z: zf + 0.14, y: 1.08, w: 0.14, h: 0.014, p: 2 },
      { z: zf + 0.22, y: 1.24, w: 0.17, h: 0.014, p: 2 },
      { z: zf + 0.3, y: 1.34, w: 0.16, h: 0.012, p: 2 },
    ]);
    // headlight pair under the screen
    for (const s of [-1, 1]) k.ell('base', MAT.lens, V(s * 0.055, 0.96, zf + 0.12), 0.04, 0.035, 0.03);
    // seat: tall, flat, two-level
    k.loft('base', MAT.seat, [
      { z: 0.03, y: 0.94, w: 0.13, h: 0.035, bot: 1.6 },
      { z: 0.25, y: 0.95, w: 0.17, h: 0.045, bot: 1.6 },
      { z: 0.38, y: 0.96, w: 0.14, h: 0.04, bot: 1.6 },
      { z: 0.6, y: 1.0, w: 0.14, h: 0.045, bot: 1.6 },
      { z: 0.68, y: 0.99, w: 0.08, h: 0.03 },
    ]);
    // rear rack + top box + panniers (aluminium, black lids)
    k.box('base', MAT.black, V(0, 0.96, 0.78), 0.28, 0.03, 0.3, 0.01);
    k.box('base', MAT.alu, V(0, 1.1, 0.86), 0.38, 0.28, 0.34, 0.035);
    k.box('base', MAT.aluDark, V(0, 1.245, 0.86), 0.39, 0.03, 0.35, 0.012);
    for (const s of [-1, 1]) {
      k.box('base', MAT.alu, V(s * 0.31, 0.68, 0.55), 0.18, 0.38, 0.48, 0.03);
      k.box('base', MAT.aluDark, V(s * 0.31, 0.88, 0.55), 0.19, 0.03, 0.49, 0.01);
      k.box('base', MAT.aluDark, V(s * 0.405, 0.68, 0.55), 0.008, 0.3, 0.38, 0.003);
    }
    tailLight(k, 1.04, 1.02, 0.08);
    exhaust(k, [V(0.08, 0.3, -0.2), V(0.18, 0.4, 0.2), V(0.2, 0.6, 0.38), V(0.2, 0.66, 0.5)], 0.026, 0.05, MAT.aluDark);
    const g = bars(k, { half: 0.44, y: 1.12, z: zf + 0.36, rise: 0.03, sweep: 0.05, guards: true, mirrors: { out: 0.02, up: 0.24, fwd: 0.0 } });
    return { mid: [0.0, 0.55, 0.93, 0.56, 0.19], grips: g, pose: { hip: [1.0, 0.2], lean: 0.12, knee: [0.2, 0.86, -0.2], foot: [0.18, 0.4, 0.0], grips: g, elbowsOut: 0.07, bulk: 1.05 }, pillion: [1.06, 0.53] };
  },

  offroad(k) {
    const wb = 1.46, Rf = 0.36, Rr = 0.34, zf = -wb / 2, zr = wb / 2;
    wheel(k, zf, Rf, 0.085, { knobby: true, disc: true });
    wheel(k, zr, Rr, 0.11, { knobby: true });
    fork(k, zf, Rf, zf + 0.3, 1.05, 0.075, 0.03, MAT.aluDark);
    engineBlock(k, 0.0, 0.48, 0.2, 0.24, 0.3);
    for (const s of [-1, 1]) k.tube('base', MAT.alu, [V(s * 0.08, 0.5, 0.15), V(s * 0.09, Rr + 0.02, zr - 0.04)], 0.022);
    // high front fender
    k.loft('paint', null, [
      { z: zf - 0.32, y: 0.74, w: 0.04, h: 0.01, p: 2 },
      { z: zf - 0.12, y: 0.88, w: 0.075, h: 0.014, p: 2 },
      { z: zf + 0.12, y: 0.9, w: 0.08, h: 0.016, p: 2 },
    ]);
    // number plate
    k.box('base', MAT.plate, V(0, 1.02, zf + 0.22), 0.2, 0.18, 0.03, 0.02, [-0.5, 0, 0]);
    // slim tank + radiator shrouds
    k.loft('paint', null, [
      { z: -0.36, y: 0.93, w: 0.07, h: 0.06 },
      { z: -0.28, y: 0.95, w: 0.12, h: 0.08 },
      { z: -0.12, y: 0.96, w: 0.12, h: 0.08 },
      { z: -0.02, y: 0.95, w: 0.08, h: 0.06 },
    ]);
    for (const s of [-1, 1]) k.loft('paint', null, [
      { x: s * 0.13, z: -0.4, y: 0.84, w: 0.025, h: 0.08 },
      { x: s * 0.16, z: -0.25, y: 0.8, w: 0.03, h: 0.12 },
      { x: s * 0.13, z: -0.08, y: 0.75, w: 0.02, h: 0.08 },
    ]);
    // long flat seat
    k.loft('base', MAT.seat, [
      { z: -0.12, y: 0.98, w: 0.07, h: 0.03 },
      { z: 0.15, y: 1.0, w: 0.11, h: 0.04, bot: 1.6 },
      { z: 0.5, y: 1.0, w: 0.1, h: 0.04, bot: 1.6 },
      { z: 0.6, y: 0.99, w: 0.06, h: 0.03 },
    ]);
    // tail / rear fender
    k.loft('paint', null, [
      { z: 0.42, y: 0.97, w: 0.11, h: 0.03 },
      { z: 0.7, y: 0.98, w: 0.08, h: 0.02 },
      { z: 0.98, y: 0.93, w: 0.05, h: 0.015 },
    ]);
    tailLight(k, 0.86, 0.97, 0.04);
    exhaust(k, [V(0.05, 0.6, -0.3), V(0.14, 0.5, -0.1), V(0.15, 0.7, 0.25), V(0.15, 0.82, 0.52)], 0.022, 0.04, MAT.aluDark);
    const g = bars(k, { half: 0.4, y: 1.13, z: zf + 0.34, rise: 0.04, sweep: 0.03, mat: MAT.aluDark, guards: true, guardMat: PAINT });
    k.root.children.filter((m) => m.userData.mat === PAINT && m.userData.layer === 'base').forEach((m) => ((m.userData.layer = 'paint'), (m.userData.noWiden = true)));
    return { mid: [-0.05, 0.45, 0.97, 0.62, 0.13], sideCover: true, grips: g, pose: { hip: [1.04, 0.12], lean: 0.22, knee: [0.15, 0.94, -0.16], foot: [0.16, 0.45, 0.02], grips: g, elbowsOut: 0.13, elbowUp: 0.06 }, pillion: [1.06, 0.44] };
  },

  electric(k) {
    // No engine block, no exhaust: a sleek one-piece shell over a dark battery, a cyan light strip
    // along each flank (the silhouette edge seen from above), a cyan light bar across the nose and
    // a wide hub motor in the rear wheel (3.55 follow-up: tells it apart at marker size).
    const wb = 1.32, R = 0.29, zf = -wb / 2, zr = wb / 2;
    wheel(k, zf, R, 0.11, { disc: true, rimMat: MAT.aluDark });
    wheel(k, zr, R, 0.14, { rimMat: MAT.aluDark });
    fork(k, zf, R, zf + 0.22, 0.86, 0.08, 0.026, MAT.satin);
    // battery pack (dark, smooth)
    k.box('base', MAT.satin, V(0, 0.44, -0.04), 0.26, 0.26, 0.5, 0.06);
    // single sculpted shell from a pointed nose to a tapered tail
    const shell = [
      { z: zf + 0.08, y: 0.86, w: 0.035, h: 0.04 },
      { z: zf + 0.22, y: 0.88, w: 0.14, h: 0.1 },
      { z: -0.24, y: 0.86, w: 0.19, h: 0.12, bot: 1.6 },
      { z: -0.02, y: 0.8, w: 0.17, h: 0.12, bot: 1.6 },
      { z: 0.24, y: 0.79, w: 0.13, h: 0.08 },
      { z: 0.55, y: 0.84, w: 0.08, h: 0.05 },
      { z: 0.74, y: 0.86, w: 0.03, h: 0.02 },
    ];
    k.loft('paint', null, shell);
    // cyan light strips just outside the (map-widened) shell edge, nose to tail
    const pts = (s) => shell.slice(1, 6).map((c) => V(s * (c.w * curWiden + 0.022), c.y + 0.012, c.z));
    for (const s of [-1, 1]) k.tube('base', MAT.glow, pts(s), 0.025, 48);
    // nose light bar
    k.box('base', MAT.glow, V(0, 0.93, zf + 0.2), 0.2, 0.03, 0.035, 0.012);
    k.ell('base', MAT.lens, V(0, 0.86, zf + 0.1), 0.05, 0.035, 0.02);
    // front fender
    k.loft('paint', null, [
      { z: zf - 0.2, y: 0.44, w: 0.07, h: 0.012, p: 2 },
      { z: zf - 0.02, y: 0.47, w: 0.075, h: 0.012, p: 2 },
      { z: zf + 0.14, y: 0.41, w: 0.07, h: 0.012, p: 2 },
    ]);
    // seat: thin floating slab
    k.loft('base', MAT.seat, [
      { z: 0.02, y: 0.9, w: 0.12, h: 0.025 },
      { z: 0.3, y: 0.91, w: 0.13, h: 0.03 },
      { z: 0.56, y: 0.93, w: 0.09, h: 0.025 },
      { z: 0.62, y: 0.92, w: 0.05, h: 0.02 },
    ]);
    // light bar tail
    k.box('base', MAT.tail, V(0, 0.88, 0.75), 0.14, 0.018, 0.022, 0.006);
    // hub motor: a wide drum in the rear wheel with cyan end rings (reads past the tail from above)
    k.cyl('base', MAT.aluDark, V(-0.15, R, zr), V(0.15, R, zr), 0.11, 0.11, 40);
    for (const s of [-1, 1]) k.add(new THREE.TorusGeometry(0.1, 0.018, 10, 40), MAT.glow, 'base', V(s * 0.15, R, zr), [0, Math.PI / 2, 0]);
    const g = bars(k, { half: 0.35, y: 0.97, z: zf + 0.26, rise: 0.02, sweep: 0.04, mat: MAT.satin, mirrors: { out: 0.05, up: 0.18, fwd: -0.02 } });
    return { mid: [0.1, 0.5, 0.8, 0.56, 0.15], grips: g, pose: { hip: [0.95, 0.2], lean: 0.25, knee: [0.18, 0.8, -0.17], foot: [0.16, 0.38, 0.03], grips: g, elbowsOut: 0.06 }, pillion: [1.0, 0.47] };
  },

  retro(k) {
    // Classic standard (3.55 follow-up: tells it apart at marker size): a big round headlight with a
    // chrome ring seen from above, twin round mirrors on stalks, a round tank with a chrome centre
    // strip, a wide flat bench seat with a tan stitching band, an upright rider on a tall bar.
    const wb = 1.37, R = 0.31, zf = -wb / 2, zr = wb / 2;
    wheel(k, zf, R, 0.1, { rimMat: MAT.chrome, disc: true });
    wheel(k, zr, R, 0.12, { rimMat: MAT.chrome });
    fork(k, zf, R, zf + 0.24, 0.86, 0.08, 0.026, MAT.chrome);
    k.tube('base', MAT.black, [V(0, 0.84, zf + 0.25), V(0, 0.76, -0.2), V(0, 0.46, 0.1), V(0, 0.46, zr - 0.15)], 0.028);
    engineBlock(k, -0.04, 0.4, 0.26, 0.26, 0.36);
    k.cyl('base', MAT.chrome, V(0, 0.5, -0.06), V(0, 0.66, -0.12), 0.08, 0.075);
    // round tank (classic teardrop with knee pads) and its chrome centre strip
    const tz = -0.22, trz = 0.26, ty = 0.84, try_ = 0.115;
    k.ell('paint', null, V(0, ty, tz), 0.165, try_, trz);
    for (const s of [-1, 1]) k.ell('base', MAT.black, V(s * 0.145, 0.8, -0.06), 0.03, 0.05, 0.07);
    const strip = [];
    for (let i = 0; i <= 8; i++) {
      const z = tz - trz * 0.92 + (i / 8) * trz * 1.7;
      const u = (z - tz) / trz;
      strip.push(V(0, ty + try_ * Math.sqrt(Math.max(0, 1 - u * u)) + 0.008, z));
    }
    k.tube('base', MAT.chrome, strip, 0.022, 32);
    // wide flat bench seat, tan stitching band across it and piping round the edge
    const sz0 = 0.0, sz1 = 0.66, sy = 0.87, sw = 0.3;
    k.box('base', MAT.seat, V(0, sy, (sz0 + sz1) / 2), sw, 0.06, sz1 - sz0, 0.028);
    for (const z of [0.3, 0.36]) k.box('base', MAT.stitch, V(0, sy + 0.031, z), sw * 0.94, 0.008, 0.022, 0.004);
    k.tube('base', MAT.stitch, [
      V(-sw / 2 + 0.01, sy + 0.03, sz0 + 0.04), V(-sw / 2 + 0.01, sy + 0.03, sz1 - 0.04), V(0, sy + 0.03, sz1 - 0.012),
      V(sw / 2 - 0.01, sy + 0.03, sz1 - 0.04), V(sw / 2 - 0.01, sy + 0.03, sz0 + 0.04),
    ], 0.008, 40);
    // short rear fender
    k.loft('paint', null, [
      { z: sz1 - 0.04, y: 0.78, w: 0.09, h: 0.03, p: 2 },
      { z: zr + 0.08, y: 0.7, w: 0.085, h: 0.025, p: 2 },
      { z: zr + 0.2, y: 0.58, w: 0.07, h: 0.02, p: 2 },
    ]);
    k.loft('paint', null, [
      { z: zf - 0.2, y: 0.44, w: 0.07, h: 0.012, p: 2 },
      { z: zf - 0.02, y: 0.47, w: 0.075, h: 0.012, p: 2 },
      { z: zf + 0.14, y: 0.42, w: 0.07, h: 0.012, p: 2 },
    ]);
    // big round headlight: dark bucket inside a bright chrome ring lying flat (an "O" from above)
    const hz = zf + 0.08, hy = 0.9, hr = 0.105;
    k.ell('base', MAT.black, V(0, hy, hz), hr, hr * 0.85, hr);
    k.add(new THREE.TorusGeometry(hr, 0.026, 12, 48), MAT.chrome, 'base', V(0, hy + 0.02, hz), [Math.PI / 2, 0, 0]);
    k.ell('base', MAT.lens, V(0, hy, hz - hr * 0.8), hr * 0.75, hr * 0.7, hr * 0.3);
    k.ell('base', MAT.tail, V(0, 0.74, zr + 0.18), 0.035, 0.03, 0.03);
    indicators(k, zf + 0.1, 0.88, 0.17, zr + 0.14, 0.72, 0.12);
    // peashooter pipe
    exhaust(k, [V(0.06, 0.4, -0.3), V(0.13, 0.28, -0.05), V(0.17, 0.32, 0.3), V(0.18, 0.4, 0.7)], 0.024, 0.04);
    // tall chrome bar, pulled back (upright seat) with twin round mirrors on stalks
    const g = bars(k, { half: 0.36, y: 1.0, z: zf + 0.3, rise: 0.05, sweep: 0.1, mat: MAT.chrome });
    for (const s of [-1, 1]) {
      const base = V(s * 0.27, 1.04, zf + 0.36);
      const head = V(s * 0.42, 1.2, zf + 0.3);
      k.tube('base', MAT.chrome, [base, base.clone().lerp(head, 0.5).add(V(s * 0.01, 0.02, 0)), head], 0.008, 10);
      k.cyl('base', MAT.chrome, head.clone().add(V(0, -0.012, 0)), head.clone().add(V(0, 0.012, 0)), 0.062, 0.062, 32);
      k.cyl('base', MAT.mirror, head.clone().add(V(0, 0.012, 0)), head.clone().add(V(0, 0.016, 0)), 0.048, 0.048, 32);
    }
    return { mid: [0.0, 0.4, 0.85, 0.5, 0.17], sideCover: true, grips: g, pose: { hip: [0.95, 0.24], lean: 0.24, knee: [0.18, 0.76, -0.14], foot: [0.16, 0.4, 0.04], grips: g, elbowsOut: 0.07 }, pillion: [0.98, 0.54] };
  },
};

/// Builds a bike of [type] with [riders] people (0, 1 or 2). Returns a THREE.Group.
// Map legibility: painted panels are drawn a little wider than life and the riders a little
// slimmer, so the bike's colour shows around the rider at marker size (like a map icon).
export const PAINT_WIDEN = 1.32;
export const RIDER_SCALE = 0.86;

function scaleAbout(k, from, pivot, s) {
  for (const m of k.root.children.slice(from)) {
    m.position.sub(pivot).multiplyScalar(s).add(pivot);
    m.scale.multiplyScalar(s);
  }
}

// The paint widening of the bike being built (parts that sit on a panel's edge follow it).
let curWiden = PAINT_WIDEN;

export function buildBike(type, riders = 1, opt = {}) {
  const k = new Kit();
  curWiden = opt.hero ? 1 : (opt.widen ?? PAINT_WIDEN);
  const b = (builders[type] ?? builders.commuter)(k);
  if (b.mid) {
    const [z0, z1, yTop, yBot, w] = b.mid;
    k.box('base', MAT.black, V(0, (yTop + yBot) / 2, (z0 + z1) / 2), w, yTop - yBot, z1 - z0, 0.04);
    if (b.sideCover) for (const sx of [-1, 1]) k.box('paint', null, V(sx * (w / 2 + 0.012), (yTop + yBot) / 2 + 0.03, (z0 + z1) / 2 + 0.02), 0.03, (yTop - yBot) * 0.62, (z1 - z0) * 0.62, 0.012);
  }
  const widen = opt.widen ?? PAINT_WIDEN;
  for (const m of k.root.children) {
    if (m.userData.layer !== 'paint' || m.userData.noWiden || opt.hero) continue;
    m.scale.x *= widen;
    m.position.x *= widen;
  }
  const rs = opt.riderScale ?? RIDER_SCALE;
  if (riders >= 1) {
    const from = k.root.children.length;
    // Grips are moved out by 1/scale first, so the scaled rider's hands land on the bars.
    const pivot = V(0, b.pose.hip[0] - 0.1, b.pose.hip[1]);
    const inv = (g) => g.clone().sub(pivot).multiplyScalar(1 / rs).add(pivot);
    const r = rider(k, { ...b.pose, grips: { L: inv(b.pose.grips.L), R: inv(b.pose.grips.R) } });
    scaleAbout(k, from, pivot, rs);
    r.hip.sub(pivot).multiplyScalar(rs).add(pivot);
    if (riders >= 2) {
      // The pillion: lighter helmet and jacket, hands on the rider's waist, sitting upright behind.
      const [py, pz] = b.pillion;
      const hipY = py, hipZ = pz;
      const from2 = k.root.children.length;
      const hands = { L: V(-0.19, r.hip.y + 0.12, r.hip.z + 0.02), R: V(0.19, r.hip.y + 0.12, r.hip.z + 0.02) };
      rider(k, {
        hip: [hipY, hipZ],
        lean: Math.max(0.08, b.pose.lean * 0.45),
        torso: 0.47,
        grips: hands,
        knee: [b.pose.knee[0] + 0.02, hipY - 0.08, hipZ - 0.3],
        foot: [b.pose.foot[0] + 0.02, hipY - 0.42, hipZ - 0.12],
        helmet: MAT.helmet2,
        jacket: MAT.jacket2,
        elbowsOut: 0.07,
        bulk: 0.95,
      });
      scaleAbout(k, from2, V(0, hipY - 0.1, hipZ), rs);
    }
  }
  return k.root;
}
