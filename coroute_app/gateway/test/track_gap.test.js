'use strict';
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { analyseTrack } = require('../src/tracks');

test('average speed ignores the straight line across a signal gap', () => {
  const T0 = Date.UTC(2026, 9, 5, 4, 0, 0);
  const pts = [];
  // 60 km/h north for 10 min = 10 km (1 km per minute), one fix every 10 s.
  const degPerKm = 1 / 111.2;
  let lat = 17.0, t = T0;
  for (let i = 0; i <= 60; i++) { pts.push({ ts: t, lat, lng: 78.4, v: 60, acc: 8 }); lat += degPerKm / 6; t += 10000; }
  // No signal for 20 min while 5 km further on (a slow crawl through a dead zone).
  t += 20 * 60000; lat += 5 * degPerKm;
  for (let i = 0; i <= 60; i++) { pts.push({ ts: t, lat, lng: 78.4, v: 60, acc: 8 }); lat += degPerKm / 6; t += 10000; }
  const a = analyseTrack(pts, { minStopMs: 180000 });
  assert.equal(a.gaps.length, 1);
  assert.ok(Math.abs(a.avgMovingKmh - 60) < 3, `avg ${a.avgMovingKmh}`);
  assert.ok(a.distanceM > 24000, 'the gap still counts towards distance');
});
