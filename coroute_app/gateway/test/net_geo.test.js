'use strict';
/** 3.15 geometry: grid cells, route index projection (vs brute force), passes, windowed projection, caps. */
process.env.NODE_ENV = 'test';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  cellKey, ringFor, SpatialGrid, buildRouteIndex, projectAll, projectWindow, projectBrute, projectNearest, angleDiff, bearing, crossAlong, pointAt,
} = require('../src/net_geo');
const { encodePolyline, haversine } = require('../src/geo_math');

test('cell math: keys, rings for 5 km and 10 km, grid moves only on a cell change', () => {
  const G = 0.05;
  assert.equal(cellKey(17.5, 78.0, G), `${Math.floor(17.5 / G)}:${Math.floor(78.0 / G)}`);
  assert.equal(cellKey(-0.01, -0.01, G), '-1:-1');
  assert.equal(ringFor(5000, 17.5, G), 1, '3x3 for 5 km');
  assert.equal(ringFor(10000, 17.5, G), 2, '5x5 for 10 km');
  const g = new SpatialGrid(G);
  assert.equal(g.update('a|1', 17.5, 78.0), true);
  assert.equal(g.update('a|1', 17.5001, 78.0001), false, 'same cell: nothing to do');
  g.update('b|2', 17.6, 78.0); // 11 km north
  const near = g.query(17.5, 78.0, 5000);
  assert.ok(near.includes('a|1'));
  assert.ok(!near.includes('b|2'));
  assert.ok(g.query(17.5, 78.0, 15000).includes('b|2'));
  g.remove('a|1');
  assert.equal(g.size, 1);
  assert.equal(g.query(17.5, 78.0, 5000).length, 0);
});

test('helpers: bearing, angle difference, cross / along track', () => {
  assert.ok(Math.abs(bearing(17.4, 78, 17.5, 78) - 0) < 0.01);
  assert.ok(Math.abs(bearing(17.5, 78, 17.4, 78) - 180) < 0.01);
  assert.equal(angleDiff(350, 10), 20);
  assert.equal(angleDiff(0, 180), 180);
  assert.equal(angleDiff(90, 90), 0);
  const ca = crossAlong(17.4, 78.0, 17.45, 78.0, 17.5, 78.0095);
  assert.ok(Math.abs(ca.cross - 1007) < 15, `cross ${ca.cross}`);
  assert.ok(ca.along > ca.lineLength);
});

function rand(seed) { let s = seed; return () => { s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648; }; }

test('route index projection equals brute force on random lines', () => {
  const r = rand(42);
  for (let k = 0; k < 20; k++) {
    const pts = [];
    let lat = 17 + r(), lng = 78 + r();
    for (let i = 0; i < 60; i++) { lat += (r() - 0.3) * 0.01; lng += (r() - 0.5) * 0.01; pts.push({ lat, lng }); }
    const idx = buildRouteIndex(encodePolyline(pts), { simplifyM: 0, maxPoints: 3000, G: 0.05 });
    for (let q = 0; q < 30; q++) {
      const p = pts[Math.floor(r() * pts.length)];
      const qlat = p.lat + (r() - 0.5) * 0.004, qlng = p.lng + (r() - 0.5) * 0.004;
      const brute = projectBrute(idx, qlat, qlng);
      const fast = projectNearest(idx, qlat, qlng);
      assert.ok(fast, 'found through the cells');
      assert.ok(Math.abs(fast.lateralM - brute.lateralM) < 0.01, `lateral ${fast.lateralM} vs ${brute.lateralM}`);
      // Along may differ only when two segments are equally close (a tie); then lateral is the same.
      if (fast.segIndex === brute.segIndex) assert.ok(Math.abs(fast.alongM - brute.alongM) < 0.5);
    }
  }
});

test('a long straight segment is found from every cell it crosses', () => {
  const idx = buildRouteIndex(encodePolyline([{ lat: 17.4, lng: 78 }, { lat: 17.7, lng: 78 }]), { simplifyM: 15, G: 0.05 });
  assert.equal(idx.n, 2);
  for (const lat of [17.41, 17.5, 17.62, 17.69]) {
    const p = projectAll(idx, lat, 78.001, 300);
    assert.equal(p.length, 1);
    assert.ok(p[0].lateralM < 120);
    assert.ok(Math.abs(p[0].alongM - haversine(17.4, 78, lat, 78)) < 5);
  }
  assert.equal(projectAll(idx, 17.5, 78.0095, 300).length, 0, 'parallel road 1 km away is not on the route');
});

test('all passes on an out-and-back line', () => {
  const out = [{ lat: 17.4, lng: 78 }, { lat: 17.6, lng: 78 }];
  const back = [{ lat: 17.6, lng: 78.0005 }, { lat: 17.4, lng: 78.0005 }];
  const idx = buildRouteIndex(encodePolyline([...out, ...back]), { simplifyM: 1, G: 0.05 });
  const passes = projectAll(idx, 17.5, 78.0002, 150);
  assert.equal(passes.length, 2, 'out and back');
  assert.ok(passes[0].alongM < passes[1].alongM);
  assert.ok(Math.abs(passes[0].segBearing - 0) < 1 && Math.abs(passes[1].segBearing - 180) < 1);
});

test('windowed rider projection follows the rider and falls back to the cells', () => {
  const pts = [];
  for (let i = 0; i <= 600; i++) pts.push({ lat: 17.4 + i * 0.0005, lng: 78 + (i % 2) * 0.0002 });
  const idx = buildRouteIndex(encodePolyline(pts), { simplifyM: 0, G: 0.05 });
  const a = projectWindow(idx, 17.45, 78.0001, null);
  assert.ok(a.lateralM < 30);
  const b = projectWindow(idx, 17.4505, 78.0001, a.segIndex);
  assert.ok(Math.abs(b.segIndex - a.segIndex) <= 2);
  // A jump far beyond the window: the cell lookup finds it.
  const c = projectWindow(idx, 17.69, 78.0001, a.segIndex);
  assert.ok(c.lateralM < 30, `lateral ${c.lateralM}`);
  const brute = projectBrute(idx, 17.69, 78.0001);
  assert.ok(Math.abs(c.alongM - brute.alongM) < 30);
  const p = pointAt(idx, 1000);
  assert.ok(Math.abs(projectBrute(idx, p.lat, p.lng).alongM - 1000) < 1, 'pointAt is the inverse of along');
});

test('simplify and point cap keep the index small', () => {
  const pts = [];
  for (let i = 0; i < 20000; i++) pts.push({ lat: 17 + i * 0.0001, lng: 78 + Math.sin(i / 3) * 0.002 });
  const idx = buildRouteIndex(encodePolyline(pts), { simplifyM: 15, maxPoints: 3000, G: 0.05 });
  assert.ok(idx.n <= 3000, `${idx.n} points`);
  assert.equal(idx.pts.length, idx.n * 3);
  assert.equal(buildRouteIndex('', {}), null);
  assert.equal(buildRouteIndex(encodePolyline([{ lat: 1, lng: 1 }]), {}), null);
});
