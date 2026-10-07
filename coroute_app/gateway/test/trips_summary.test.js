'use strict';
process.env.NODE_ENV = 'test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('trip list without trails, trail on demand, owner only', async () => {
  const a = await t.register('Sum Owner', 'sumowner@coroute.test');
  const b = await t.register('Sum Other', 'sumother@coroute.test');
  const trail = Array.from({ length: 30 }, (_, i) => ({ lat: 17 + i / 1000, lng: 78, speedKmh: 40, heading: 0, timestamp: i * 1000 }));
  for (let i = 0; i < 3; i++) {
    assert.equal((await t.api('POST', '/trips', { tripId: `TRIP-SUM-${i}`, tripName: `Ride ${i}`, endTimeEpochMs: Date.now() - i * 1000, breadcrumbTrail: trail }, a.token)).status, 201);
  }

  const summary = await t.api('GET', '/trips?summary=1', null, a.token);
  assert.equal(summary.status, 200);
  assert.equal(summary.json.trips.length, 3);
  for (const trip of summary.json.trips) {
    assert.equal(trip.breadcrumbTrail, undefined, 'no trail arrays in the summary');
    assert.equal(trip.trailPoints, 30);
    assert.ok(trip.tripName);
  }

  // Older builds (no flag) still get trails.
  const full = await t.api('GET', '/trips', null, a.token);
  assert.equal(full.json.trips[0].breadcrumbTrail.length, 30);

  const one = await t.api('GET', '/trips/TRIP-SUM-1', null, a.token);
  assert.equal(one.status, 200);
  assert.equal(one.json.trip.breadcrumbTrail.length, 30);
  assert.equal(one.json.trip.trailPoints, 30);

  assert.equal((await t.api('GET', '/trips/TRIP-SUM-1', null, b.token)).status, 404, 'another rider cannot read it');
  assert.equal((await t.api('GET', '/trips/TRIP-NOPE', null, a.token)).status, 404);
  // The report route still works next to the new one.
  assert.equal((await t.api('GET', '/trips/TRIP-SUM-1/report', null, a.token)).status, 200);
});
