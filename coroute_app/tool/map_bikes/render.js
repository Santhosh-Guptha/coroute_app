// Renders the map-bike and garage-hero layers in the browser (headless Chromium via generate.mjs).
// window.renderTop(type, riders, px)        -> {base, paint, gloss, shadow} PNG data URLs (px × px)
// window.renderHero(type, riders, w, h)     -> {base, paint, gloss} PNG data URLs (w × h)
// Layers (see README): base = everything not painted (+ a thin light rim so dark bikes read on dark
// maps), paint = the painted panels in white/grey shading (tinted at runtime: rgb × colour),
// gloss = the clear-coat reflections of the painted panels as white with alpha (drawn on top),
// shadow = soft ground shadow (black with alpha, top view only; the app offsets it in screen space).
import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { buildBike, PAINT } from './bikes.js';

const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true, premultipliedAlpha: false });
renderer.setPixelRatio(1);
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.NeutralToneMapping;
renderer.toneMappingExposure = 1.0;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
document.body.appendChild(renderer.domElement);

const pmrem = new THREE.PMREMGenerator(renderer);
const envTex = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;

function makeScene(hero) {
  const scene = new THREE.Scene();
  scene.environment = envTex;
  scene.environmentIntensity = hero ? 0.75 : 0.5;
  const hemi = new THREE.HemisphereLight(0xffffff, 0x4a4f56, hero ? 0.55 : 0.5);
  scene.add(hemi);
  const key = new THREE.DirectionalLight(0xfffaf0, hero ? 2.3 : 2.7);
  // Top view: light from the upper left of the screen (front-left of the bike), high in the sky.
  if (hero) key.position.set(1.6, 5, -1.2);
  else key.position.set(-1.4, 5, -1.8);
  key.castShadow = true;
  key.shadow.mapSize.set(2048, 2048);
  key.shadow.camera.left = -1.8;
  key.shadow.camera.right = 1.8;
  key.shadow.camera.top = 1.8;
  key.shadow.camera.bottom = -1.8;
  key.shadow.camera.near = 0.5;
  key.shadow.camera.far = 12;
  key.shadow.radius = 4;
  key.shadow.bias = -0.0004;
  key.shadow.normalBias = 0.01;
  scene.add(key);
  const rim = new THREE.DirectionalLight(0xdfe8ff, hero ? 0.9 : 0.6);
  rim.position.set(hero ? -2 : 1.8, 3, hero ? 1.5 : 1.6);
  scene.add(rim);
  return scene;
}

const HOLDOUT = new THREE.MeshBasicMaterial({ colorWrite: false });
const MASK = new THREE.MeshBasicMaterial({ color: 0x000000 });
// In the base layer the painted panels are filled with a dark neutral: where a panel edge is only
// partly covered by the tinted paint layer this reads as a natural panel gap, never as a hole.
const PAINT_FILL = new THREE.MeshStandardMaterial({ color: 0x34373b, roughness: 0.55 });
const PAINT_WHITE = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 0.62, metalness: 0, envMapIntensity: 0.85 });
const PAINT_GLOSS = new THREE.MeshPhysicalMaterial({ color: 0x000000, roughness: 0.35, metalness: 0, clearcoat: 1, clearcoatRoughness: 0.12, envMapIntensity: 1.3 });

function setPass(group, pass) {
  group.traverse((m) => {
    if (!m.isMesh) return;
    const paint = m.userData.layer === 'paint';
    if (m.userData.isGround) {
      m.visible = pass === 'base';
      return;
    }
    switch (pass) {
      case 'base':
        m.material = paint ? PAINT_FILL : m.userData.mat;
        break;
      case 'paint':
        m.material = paint ? PAINT_WHITE : HOLDOUT;
        break;
      case 'gloss':
        m.material = paint ? PAINT_GLOSS : HOLDOUT;
        break;
      case 'mask':
        m.material = MASK;
        break;
    }
  });
}

function snap() {
  return renderer.domElement.toDataURL('image/png');
}

function canvas(w, h) {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return c;
}

function imageOf(url) {
  return new Promise((res) => {
    const i = new Image();
    i.onload = () => res(i);
    i.src = url;
  });
}

// gloss render (reflections on black) -> white with alpha = brightness
function glossToAlpha(img, w, h, gain = 1.25) {
  const c = canvas(w, h);
  const x = c.getContext('2d');
  x.drawImage(img, 0, 0);
  const d = x.getImageData(0, 0, w, h);
  const p = d.data;
  for (let i = 0; i < p.length; i += 4) {
    const a = p[i + 3] / 255;
    const l = Math.max(p[i], p[i + 1], p[i + 2]) / 255;
    // soft knee: keep only real highlights
    const v = Math.min(1, Math.max(0, (l - 0.06) / 0.94) * gain);
    p[i] = p[i + 1] = p[i + 2] = 255;
    p[i + 3] = Math.round(255 * a * Math.pow(v, 1.15));
  }
  x.putImageData(d, 0, 0);
  return c.toDataURL('image/png');
}

// Top view: perspective straight down with a narrow lens (tall parts look a little closer, so the
// rider's helmet and shoulders read as 3D), screen up = bike forward.
const TOP_SPAN = 2.42; // metres across the square image at ground level (the longest bike fits with its shadow)

window.renderTop = async function (type, riders, px, opt = {}) {
  const scene = makeScene(false);
  const bike = buildBike(type, riders);
  const box = new THREE.Box3().setFromObject(bike);
  const len = box.max.z - box.min.z;
  // Partly normalise the length so small bikes stay legible and long ones fit when rotated.
  const s = Math.min(1.12, Math.pow(2.2 / len, 0.55));
  bike.scale.setScalar(s);
  const c = box.getCenter(new THREE.Vector3());
  bike.position.set(-c.x * s, 0, -c.z * s);
  scene.add(bike);
  const fov = 22;
  const dist = TOP_SPAN / 2 / Math.tan(THREE.MathUtils.degToRad(fov / 2));
  const cam = new THREE.PerspectiveCamera(fov, 1, 0.5, 40);
  cam.position.set(0, dist, 0);
  cam.up.set(0, 0, -1);
  cam.lookAt(0, 0, 0);
  cam.updateMatrixWorld();
  // Fit: tall parts (top box, pillion helmet) project outwards; keep the whole bike, its rim and
  // shadow inside 88 % of the image (the shadow blur needs the margin).
  for (let it = 0; it < 3; it++) {
    bike.updateMatrixWorld(true);
    let m = 0;
    const p = new THREE.Vector3();
    bike.traverse((o) => {
      if (!o.isMesh) return;
      const pos = o.geometry.attributes.position;
      for (let i = 0; i < pos.count; i += 2) {
        p.fromBufferAttribute(pos, i).applyMatrix4(o.matrixWorld).project(cam);
        m = Math.max(m, Math.abs(p.x), Math.abs(p.y));
      }
    });
    if (m <= 0.88) break;
    const f = 0.88 / m;
    bike.scale.multiplyScalar(f);
    bike.position.multiplyScalar(f);
  }
  renderer.setSize(px, px, false);
  const out = {};
  for (const pass of ['mask', 'base', 'paint', 'gloss']) {
    setPass(bike, pass);
    renderer.render(scene, cam);
    out[pass] = snap();
  }
  const ppl = px / 64; // pixels per logical px of the 64-px marker box
  const mask = await imageOf(out.mask);
  // shadow: a tight contact shadow plus a wide soft one
  const sh = canvas(px, px);
  const sx = sh.getContext('2d');
  sx.filter = `blur(${(2.6 * ppl).toFixed(1)}px)`;
  sx.globalAlpha = 0.62;
  sx.drawImage(mask, 0, 0);
  sx.filter = `blur(${(1.0 * ppl).toFixed(1)}px)`;
  sx.globalAlpha = 0.55;
  sx.drawImage(mask, 0, 0);
  // base: a thin light rim (dilated silhouette) behind the model
  const base = await imageOf(out.base);
  const bc = canvas(px, px);
  const bx = bc.getContext('2d');
  const rimPx = (opt.rim ?? 0.5) * ppl;
  const tint = canvas(px, px);
  const tx = tint.getContext('2d');
  tx.drawImage(mask, 0, 0);
  tx.globalCompositeOperation = 'source-in';
  tx.fillStyle = opt.rimColor ?? 'rgba(255,255,255,1)';
  tx.fillRect(0, 0, px, px);
  bx.globalAlpha = opt.rimAlpha ?? 0.3;
  bx.filter = `blur(${(0.35 * ppl).toFixed(1)}px)`;
  for (let i = 0; i < 16; i++) {
    const a = (i / 16) * Math.PI * 2;
    bx.drawImage(tint, Math.cos(a) * rimPx, Math.sin(a) * rimPx);
  }
  bx.filter = 'none';
  bx.globalAlpha = 1;
  // the rim must be one flat alpha (overlapping copies would stack): flatten
  const flat = bx.getImageData(0, 0, px, px);
  const fa = flat.data;
  const ra = Math.round(255 * (opt.rimAlpha ?? 0.3));
  for (let i = 3; i < fa.length; i += 4) fa[i] = Math.min(fa[i] * 4, ra);
  bx.putImageData(flat, 0, 0);
  bx.drawImage(base, 0, 0);
  const gloss = glossToAlpha(await imageOf(out.gloss), px, px);
  scene.remove(bike);
  return { base: bc.toDataURL('image/png'), paint: out.paint, gloss, shadow: sh.toDataURL('image/png') };
};

// Hero: a 3/4 front-right view for the garage (bike faces right), framed to fill w × h.
window.renderHero = async function (type, riders, w, h) {
  const scene = makeScene(true);
  // Side view: true proportions (the map's widening is only for the top view).
  const bike = buildBike(type, riders, { hero: true, riderScale: 1 });
  const box = new THREE.Box3().setFromObject(bike);
  const c = box.getCenter(new THREE.Vector3());
  bike.position.set(-c.x, 0, -c.z);
  scene.add(bike);
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(8, 8), new THREE.ShadowMaterial({ opacity: 0.32 }));
  ground.rotation.x = -Math.PI / 2;
  ground.receiveShadow = true;
  ground.userData.isGround = true;
  scene.add(ground);
  // soft contact blob under the wheels
  const blobTex = (() => {
    const cv = canvas(256, 256);
    const g = cv.getContext('2d');
    const gr = g.createRadialGradient(128, 128, 0, 128, 128, 128);
    gr.addColorStop(0, 'rgba(0,0,0,0.55)');
    gr.addColorStop(0.55, 'rgba(0,0,0,0.25)');
    gr.addColorStop(1, 'rgba(0,0,0,0)');
    g.fillStyle = gr;
    g.fillRect(0, 0, 256, 256);
    return new THREE.CanvasTexture(cv);
  })();
  const blen = box.max.z - box.min.z;
  const blob = new THREE.Mesh(new THREE.PlaneGeometry(0.75, blen * 1.08), new THREE.MeshBasicMaterial({ map: blobTex, transparent: true, depthWrite: false }));
  blob.rotation.x = -Math.PI / 2;
  blob.position.y = 0.002;
  blob.userData.isGround = true;
  scene.add(blob);

  const cam = new THREE.PerspectiveCamera(22, w / h, 0.3, 60);
  const target = new THREE.Vector3(0, (box.max.y - box.min.y) * 0.45, 0);
  cam.position.copy(target).add(new THREE.Vector3(5.2, 1.6, -2.4));
  cam.lookAt(target);
  cam.updateMatrixWorld();
  cam.updateProjectionMatrix();
  // fit: project the model's bounding box, then crop the view to it (same lens, exact framing)
  const b2 = new THREE.Box3().setFromObject(bike);
  b2.min.y = 0;
  let x0 = 1, x1 = -1, y0 = 1, y1 = -1;
  for (const X of [b2.min.x, b2.max.x]) for (const Y of [b2.min.y, b2.max.y]) for (const Z of [b2.min.z, b2.max.z]) {
    const p = new THREE.Vector3(X, Y, Z).project(cam);
    x0 = Math.min(x0, p.x); x1 = Math.max(x1, p.x); y0 = Math.min(y0, p.y); y1 = Math.max(y1, p.y);
  }
  // NDC -> virtual pixels of a w × h full view
  let rx0 = ((x0 + 1) / 2) * w, rx1 = ((x1 + 1) / 2) * w, ry0 = ((1 - y1) / 2) * h, ry1 = ((1 - y0) / 2) * h;
  let rw = rx1 - rx0, rh = ry1 - ry0;
  const m = 0.04;
  rx0 -= rw * m; rx1 += rw * m; ry0 -= rh * m; ry1 += rh * m * 1.5;
  rw = rx1 - rx0; rh = ry1 - ry0;
  const asp = w / h;
  if (rw / rh > asp) {
    const nh = rw / asp;
    ry0 -= (nh - rh) * 0.6;
    rh = nh;
  } else {
    const nw = rh * asp;
    rx0 -= (nw - rw) / 2;
    rw = nw;
  }
  cam.setViewOffset(w, h, rx0, ry0, rw, rh);
  renderer.setSize(w, h, false);
  const out = {};
  for (const pass of ['base', 'paint', 'gloss']) {
    setPass(scene, pass);
    renderer.render(scene, cam);
    out[pass] = snap();
  }
  setPass(scene, 'base');
  out.gloss = glossToAlpha(await imageOf(out.gloss), w, h);
  scene.remove(bike);
  return out;
};

window.ready = true;
