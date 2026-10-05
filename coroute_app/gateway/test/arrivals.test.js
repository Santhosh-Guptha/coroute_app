'use strict';
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

let gw;
after(async () => gw && gw.shutdown());

test('riding past a stop is logged as passed, not reached; the stop stays open until everyone arrives', async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  const a = await gw.auth.register({ name: 'Arun', email: 'arun@coroute.test', password: 'Password#123', phone: '9999999999' });
  const b = await gw.auth.register({ name: 'Bindu', email: 'bindu@coroute.test', password: 'Password#123', phone: '9999999999' });
  const ua = { userId: a.user.userId, name: 'Arun', role: 'RIDER' };
  const ub = { userId: b.user.userId, name: 'Bindu', role: 'RIDER' };
  const snap = await gw.convoys.createConvoy(ua, { name: 'Pass test', stops: [{ name: 'Dhaba', lat: 17.1, lng: 78.0 }] });
  await gw.convoys.joinByCode(ub, snap.joinCode);
  const room = await gw.convoys.getRoom(snap.groupId);
  const step = async (u, lat, kmh) => { gw.convoys.patchRider(room, u.userId, { lat, lng: 78.0, speedKmh: kmh }, { emit: false }); await gw.timeline.idle(); };

  // Arun rides straight through at 70 km/h.
  await step(ua, 17.097, 70);
  await step(ua, 17.1, 70);
  await step(ua, 17.103, 70);
  // Bindu pulls in and stops.
  await step(ub, 17.1001, 8);
  let stop = (await gw.convoys.getRoom(snap.groupId)).meta.stopPoints[0];
  assert.ok(stop.arrivals[ua.userId].passedAt, 'Arun passed');
  assert.equal(stop.arrivals[ua.userId].arrivedAt, undefined);
  assert.ok(stop.arrivals[ub.userId].arrivedAt, 'Bindu reached');
  assert.equal(stop.isVisited, false, 'not everyone has reached it');

  const ev = await gw.repo.listEvents(snap.groupId, { limit: 100 });
  assert.equal(ev.filter((e) => e.type === 'STOP_PASSED' && e.userId === ua.userId).length, 1);
  const atStop = ev.filter((e) => e.type === 'STOP_REACHED' && e.userId === ub.userId);
  assert.equal(atStop.length, 1);
  assert.equal(atStop[0].open, true, 'still at the stop');
  assert.equal(ev.filter((e) => e.type === 'STOP_ALL_REACHED').length, 0);
});
