'use strict';
process.env.NODE_ENV = 'test';
process.env.WS_ALARMS_PER_10S = '20'; // this test sends many SOS on purpose; the limit has its own test

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('an SOS retried with the same clientId is delivered once; the sender gets the existing alert back', async () => {
  const lead = await t.register('Sos Lead', 'soslead@coroute.test');
  const rider = await t.register('Sos Rider', 'sosrider@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'SOS ride' }, lead.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, rider.token);
  const wl = await t.joinRoom(lead.token, c.groupId);
  let wr = await t.joinRoom(rider.token, c.groupId);

  wr.sendJson({ type: 'SOS', lat: 12.9, lng: 77.6, alertType: 'CRASH_OR_EMERGENCY', clientId: 'sos-a-1' });
  const first = await wl.next((m) => m.type === 'ALERT');
  assert.equal(first.alert.clientId, 'sos-a-1');
  const echo = await wr.next((m) => m.type === 'ALERT');
  assert.equal(echo.alert.alertId, first.alert.alertId);

  // Same clientId again (the phone never saw the echo): no second alert, the sender gets it back.
  wr.sendJson({ type: 'SOS', lat: 12.9, lng: 77.6, alertType: 'CRASH_OR_EMERGENCY', clientId: 'sos-a-1' });
  const again = await wr.next((m) => m.type === 'ALERT');
  assert.equal(again.alert.alertId, first.alert.alertId);
  assert.equal(again.duplicate, true);
  await sleep(100);
  assert.equal(wl.inbox.filter((m) => m.type === 'ALERT').length, 0, 'the rest of the convoy is not alerted twice');

  // After a reconnect (new socket, JOIN, resend) it is still the same SOS.
  wr.close();
  wr = await t.joinRoom(rider.token, c.groupId);
  wr.sendJson({ type: 'SOS', lat: 12.9, lng: 77.6, clientId: 'sos-a-1' });
  const afterReconnect = await wr.next((m) => m.type === 'ALERT' && m.duplicate === true);
  assert.equal(afterReconnect.alert.alertId, first.alert.alertId);

  // A different clientId is a new SOS.
  wr.sendJson({ type: 'SOS', lat: 12.9, lng: 77.6, clientId: 'sos-a-2' });
  const second = await wl.next((m) => m.type === 'ALERT');
  assert.notEqual(second.alert.alertId, first.alert.alertId);

  let stored = await t.gw.repo.listAlerts(c.groupId, { includeResolved: true });
  assert.equal(stored.length, 2);

  // Resolved, and the room reloaded from the database: a late retry still creates nothing.
  wl.sendJson({ type: 'SOS_RESOLVE', alertId: first.alert.alertId });
  await wr.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === first.alert.alertId);
  const room = t.gw.convoys.rooms.get(c.groupId);
  room.alerts.delete(first.alert.alertId);
  wr.sendJson({ type: 'SOS', lat: 12.9, lng: 77.6, clientId: 'sos-a-1' });
  const late = await wr.next((m) => m.type === 'ALERT' && m.duplicate === true);
  assert.equal(late.alert.alertId, first.alert.alertId);
  stored = await t.gw.repo.listAlerts(c.groupId, { includeResolved: true });
  assert.equal(stored.length, 2);

  // Old clients without clientId keep working (one alert per message).
  wr.sendJson({ type: 'SOS', lat: 1, lng: 1 });
  await wl.next((m) => m.type === 'ALERT' && !m.alert.clientId);
  wl.close(); wr.close();
});
