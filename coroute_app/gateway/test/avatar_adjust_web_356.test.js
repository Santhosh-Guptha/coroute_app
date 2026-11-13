'use strict';
/**
 * 3.56 /account "Adjust your picture" (public/assets/account.js): the crop numbers are the same as
 * in the app (test/avatar_crop_356_test.dart uses the same cases), and the page keeps its strict
 * CSP rules (no inline script or handlers, canvas only, keyboard reachable controls).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const js = fs.readFileSync(path.join(__dirname, '../public/assets/account.js'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, '../public/account.html'), 'utf8');
const sandbox = { window: {} };
vm.runInNewContext(js, sandbox);
const M = sandbox.window.CoAvatarCrop;
const near = (a, b, m) => assert.ok(Math.abs(a - b) < 1e-6, `${m || ''} ${a} != ${b}`);
const W = 1600, H = 1200;
const start = { cx: 0.5, cy: 0.5, zoom: 1, rot: 0 };

test('transform -> source square (same numbers as the app)', () => {
  assert.ok(M, 'the numbers are exported for tests');
  let s = M.sourceSquare(W, H, start);
  assert.deepEqual([s.left, s.top, s.side], [200, 0, 1200]);
  s = M.sourceSquare(W, H, { cx: 0.25, cy: 0.5, zoom: 2, rot: 0 });
  near(s.left, 100); near(s.top, 300); near(s.side, 600);
  assert.equal(M.outputSize(W, H, start), 512);
  assert.equal(M.outputSize(W, H, { ...start, zoom: 4 }), 300);
  assert.equal(M.outputSize(100, 80, start), 80);
});

test('rotation: seen square maps to the right file pixels; four turns come home', () => {
  assert.deepEqual(Array.from(M.rotatedSize(W, H, 1)), [1200, 1600]);
  let s = M.sourceSquare(W, H, { cx: 0.25, cy: 0.1875, zoom: 2, rot: 1 });
  near(s.left, 0); near(s.top, 600);
  s = M.sourceSquare(W, H, { cx: 0.1875, cy: 0.25, zoom: 2, rot: 2 });
  near(s.left, 1000); near(s.top, 600);
  s = M.sourceSquare(W, H, { cx: 0.25, cy: 0.1875, zoom: 2, rot: 3 });
  near(s.left, 1000); near(s.top, 0);
  const first = { cx: 0.3, cy: 0.6, zoom: 2.5, rot: 0 };
  const a = M.sourceSquare(W, H, first);
  let c = first;
  for (let i = 1; i <= 4; i++) {
    c = M.rotate(W, H, c, 1);
    assert.equal(c.rot, i % 4);
    const q = M.sourceSquare(W, H, c);
    near(q.left, a.left, `turn ${i}`); near(q.top, a.top, `turn ${i}`);
  }
  near(c.cx, first.cx); near(c.cy, first.cy);
  assert.equal(M.rotate(W, H, first, -1).rot, 3);
});

test('bounds, drag, zoom, original size, wire format', () => {
  for (const c of [{ cx: 0, cy: 0, zoom: 3, rot: 0 }, { cx: 1, cy: 1, zoom: 3, rot: 0 }, { cx: -5, cy: 9, zoom: 1.5, rot: 1 }, { cx: NaN, cy: Infinity, zoom: NaN, rot: 7 }]) {
    const s = M.sourceSquare(W, H, c);
    assert.ok(s.left >= -1e-9 && s.top >= -1e-9 && s.left + s.side <= W + 1e-9 && s.top + s.side <= H + 1e-9, JSON.stringify(c));
  }
  assert.equal(M.clamp(W, H, { ...start, zoom: 40 }).zoom, 8);
  assert.equal(M.maxZoomFor(96, 96), 3);
  let c = M.pan(W, H, start, -30, 0, 300);
  near(M.sourceSquare(W, H, c).left, 320);
  c = M.pan(W, H, c, -10000, 500, 300);
  near(M.sourceSquare(W, H, c).left + 1200, 1600);
  const corner = M.zoomTo(W, H, start, 2, 0, 0);
  near(M.rotatedSquare(W, H, corner).left, M.rotatedSquare(W, H, start).left);
  assert.deepEqual(Array.from(M.originalSize(4000, 3000)), [2048, 1536]);
  assert.deepEqual(Array.from(M.originalSize(800, 600)), [800, 600]);
  assert.equal(M.query({ cx: 0.123456, cy: 0.5, zoom: 2.00004, rot: 3 }), 'cx=0.1235&cy=0.5&zoom=2&rot=3');
  // What the page sends is what the gateway accepts.
  const A = require('../src/avatars');
  const q = Object.fromEntries(new URLSearchParams(M.query({ cx: 0.3, cy: 0.6, zoom: 2.5, rot: 1 })));
  assert.deepEqual(A.normaliseCrop(q), { cx: 0.3, cy: 0.6, zoom: 2.5, rot: 1 });
  assert.equal(M.parse({ cx: 0.5, cy: 0.5, zoom: 9, rot: 0 }), null);
  assert.equal(M.parse(null), null);
  assert.deepEqual({ ...M.parse({ cx: 0.5, cy: 0.5, zoom: 2, rot: 1 }) }, { cx: 0.5, cy: 0.5, zoom: 2, rot: 1 });
});

test('page: no inline script or handlers, canvas only, labelled and keyboard reachable controls', () => {
  assert.ok(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), 'no inline script');
  assert.ok(!/\son[a-z]+\s*=/i.test(html), 'no inline event handlers');
  assert.ok(!/style\s*=\s*"/i.test(html.slice(html.indexOf('id="ac-crop"'), html.indexOf('</dialog>'))), 'no inline styles in the dialog');
  const d = html.slice(html.indexOf('<dialog'), html.indexOf('</dialog>'));
  assert.match(d, /aria-labelledby="ac-crop-title"/);
  assert.match(d, /<canvas[^>]*id="ac-crop-canvas"[^>]*tabindex="0"[^>]*role="img"[^>]*\s+aria-label="[^"]*Arrow keys/s);
  assert.match(d, /<label[^>]*for="ac-crop-zoom"/);
  assert.match(d, /type="range" id="ac-crop-zoom"/);
  assert.match(d, /accept="image\/jpeg,image\/png,image\/webp"/);
  for (const id of ['ac-crop-left', 'ac-crop-right', 'ac-crop-reset', 'ac-crop-save', 'ac-crop-cancel', 'ac-crop-remove']) {
    assert.match(d, new RegExp(`<button[^>]*type="button"[^>]*id="${id}"`), id);
  }
  assert.match(d, /aria-live="polite"/);
  // The script: no library, no eval, no innerHTML, no blob: URL (the CSP has no blob: source).
  const mine = js.slice(js.indexOf('3.56 "Adjust your profile picture"'));
  for (const bad of ['innerHTML', 'eval(', 'new Function', 'createObjectURL', 'document.write', 'http://', 'https://']) {
    assert.ok(!mine.includes(bad), `account.js picture section uses ${bad}`);
  }
  for (const key of ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', "'['", "']'", "'0'"]) assert.ok(mine.includes(key), `keyboard: ${key}`);
});
