'use strict';
/**
 * v3.63 privacy zones (server side): a rider near a saved place sends telemetry with zoneHidden and no position;
 * the gateway stores no coordinate (one sent anyway is dropped), shows the flag to the group, closes offline / stale
 * entries but runs no position rule, and the next real position (JSON or P2) clears it. An SOS always carries the
 * exact position.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('hidden near a saved place: no coordinate stored or relayed; flag shown; SOS exact; cleared by the next fix', async () => {
  const A = await t.register('Zone Lead', 'zonelead@coroute.test');
  const B = await t.register('Zone Rider', 'zonerider@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Zone ride', start: { lat: 17.3, lng: 78.4, name: 'Start' } }, A.token)).json;
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, B.token)).status, 200);
  const wa = await t.joinRoom(A.token, c.groupId);
  const wb = await t.joinRoom(B.token, c.groupId);
  const room = t.gw.convoys.rooms.get(c.groupId);

  wb.sendJson({ type: 'TELEMETRY', lat: 17.31, lng: 78.41, speedKmh: 20, heading: 90, zoneHidden: false });
  await sleep(80);
  assert.equal(room.riders.get(B.user.userId).lat, 17.31);

  // Hidden: a (buggy) coordinate sent with the flag is dropped by the server too.
  wb.sendJson({ type: 'TELEMETRY', lat: 17.4, lng: 78.5, speedKmh: 12, heading: 45, zoneHidden: true });
  await sleep(80);
  const hid = room.riders.get(B.user.userId);
  assert.equal(hid.zoneHidden, true);
  assert.deepEqual([hid.lat, hid.lng, hid.heading], [0, 0, 0]);
  const snap = await t.gw.convoys.getSnapshot(c.groupId);
  const riders = Array.isArray(snap.riders) ? snap.riders : Object.values(snap.riders || {});
  const rb = riders.find((r) => r.userId === B.user.userId);
  assert.ok(rb, 'rider in the snapshot');
  assert.deepEqual([rb.zoneHidden, rb.lat, rb.lng], [true, 0, 0], 'the group gets the flag and no position');

  // SAFETY: an SOS from inside the zone carries the exact position.
  wb.sendJson({ type: 'SOS', lat: 17.4001, lng: 78.5001, clientId: 'zone-sos-1' });
  const sos = await wa.next((m) => m.type === 'ALERT');
  assert.equal(sos.alert.lat, 17.4001);
  assert.equal(sos.alert.lng, 78.5001);

  // The next real position clears the flag (JSON).
  wb.sendJson({ type: 'TELEMETRY', lat: 17.42, lng: 78.52, speedKmh: 30, zoneHidden: false });
  await sleep(80);
  assert.equal(room.riders.get(B.user.userId).zoneHidden, false);
  assert.equal(room.riders.get(B.user.userId).lat, 17.42);
  wa.close(); wb.close();
});

test('timeline: a hidden rider closes STALE / OFFLINE and builds no stop, off-route or separation entry', async () => {
  const tl = t.gw.timeline || t.gw.convoys.timeline;
  assert.ok(tl && typeof tl._hiddenAlive === 'function');
  const A = await t.register('Zone TL', 'zonetl@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Zone TL ride' }, A.token)).json;
  const st = await tl._state(c.groupId);
  st.open.set(`STALE:${A.user.userId}`, { slot: `STALE:${A.user.userId}`, data: {} });
  const closed = [];
  const realClose = tl._close.bind(tl);
  tl._close = async (gid, s, slot, ...rest) => { closed.push(slot); return realClose(gid, s, slot, ...rest).catch(() => {}); };
  const opened = [];
  const realOpen = tl._open.bind(tl);
  tl._open = async (gid, s, slot, ...rest) => { opened.push(slot); return realOpen(gid, s, slot, ...rest); };
  try {
    await tl.onTelemetry(c.groupId, { userId: A.user.userId, name: 'Zone TL', lat: 0, lng: 0, zoneHidden: true, speedKmh: 0, batteryLevel: 80, lastSeenEpochMs: Date.now() });
    assert.ok(closed.includes(`STALE:${A.user.userId}`), 'stale entry closed: the rider is alive');
    assert.equal(opened.filter((s) => /STOPPED|OFF_ROUTE|SEPARAT|INCIDENT/.test(s)).length, 0);
  } finally { tl._close = realClose; tl._open = realOpen; }
});
