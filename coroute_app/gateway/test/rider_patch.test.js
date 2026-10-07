'use strict';
process.env.NODE_ENV = 'test';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('riders cannot change role or profile over the socket; telemetry still flows; the lead can end the trip', async () => {
  const lead = await t.register('Patch Lead', 'patchlead@coroute.test');
  const pack = await t.register('Patch Pack', 'patchpack@coroute.test', { phone: '+919811111111' });

  const created = await t.api('POST', '/convoys', { name: 'Patch ride', rider: { lat: 17.3, lng: 78.4, phone: '+910000000000' } }, lead.token);
  assert.equal(created.status, 201, JSON.stringify(created.json));
  const gid = created.json.groupId;
  assert.equal(created.json.riders[lead.user.userId].phone, lead.user.phone, 'create uses the account phone, not the request');

  // Join with a fake phone and emergency contact: the snapshot shows the account values.
  const joined = await t.api('POST', '/convoys/join', { code: created.json.joinCode, rider: { lat: 17.31, lng: 78.41, phone: '+911234567890', emergencyContact: 'fake', role: 'LEAD', vehicleColor: 'Red' } }, pack.token);
  assert.equal(joined.status, 200, JSON.stringify(joined.json));
  const packRider = joined.json.riders[pack.user.userId];
  assert.equal(packRider.phone, '+919811111111');
  assert.equal(packRider.emergencyContact, '+919000000001');
  assert.equal(packRider.role, 'PACK');
  assert.equal(packRider.vehicleColor, 'Red');

  const wsLead = await t.joinRoom(lead.token, gid);
  const wsPack = await t.joinRoom(pack.token, gid);

  // Escalation attempt: TELEMETRY carrying role, phone (object) and a 5 KB emergency contact.
  wsPack.sendJson({
    type: 'TELEMETRY', lat: 17.32, lng: 78.42, speedKmh: 30, role: 'LEAD',
    phone: { evil: true }, emergencyContact: 'x'.repeat(5000), vehicleNo: 'HACKED', isCoRiding: true,
  });
  const seen = await wsLead.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === pack.user.userId);
  assert.equal(seen.rider.lat, 17.32, 'normal telemetry still broadcasts');
  assert.equal(seen.rider.role, 'PACK');
  assert.equal(seen.rider.phone, '+919811111111');
  assert.equal(seen.rider.emergencyContact, '+919000000001');
  assert.equal(seen.rider.isCoRiding, false);

  const room = await t.gw.convoys.getRoom(gid);
  const stored = room.riders.get(pack.user.userId);
  assert.equal(stored.role, 'PACK');
  assert.equal(stored.phone, '+919811111111');
  assert.equal(stored.vehicleNo, pack.user.vehicleNo);

  // Junk types are coerced and sizes capped.
  wsPack.sendJson({ type: 'TELEMETRY', lat: 17.33, lng: 78.43, statusMessage: 'y'.repeat(1000), statusReason: { a: 1 }, isCharging: 'yes', stoppedSince: 9e15 });
  const coerced = await wsLead.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === pack.user.userId && m.rider.lat === 17.33);
  assert.equal(coerced.rider.statusMessage.length, 140);
  assert.equal(typeof coerced.rider.statusReason, 'string');
  assert.equal(coerced.rider.isCharging, true);
  assert.ok(coerced.rider.stoppedSince <= Date.now() + 60000);

  // The would-be lead still cannot end the trip.
  wsPack.sendJson({ type: 'TRIP_STATUS', status: 'ENDED' });
  const err = await wsPack.next((m) => m.type === 'ERROR');
  assert.equal(err.code, 403);
  assert.equal((await t.gw.repo.getConvoyMeta(gid)).tripStatus, 'STARTED');

  // CORIDER is the one path that sets co-riding (server-trusted).
  wsPack.sendJson({ type: 'CORIDER', ridingWithUserId: lead.user.userId });
  const co = await wsLead.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === pack.user.userId && m.rider.isCoRiding === true);
  assert.equal(co.rider.ridingWithUserId, lead.user.userId);

  await sleep(60);
  const persisted = (await t.gw.repo.listRiders(gid)).find((r) => r.userId === pack.user.userId);
  assert.equal(persisted.role, 'PACK');
  assert.equal(persisted.phone, '+919811111111');

  // Existing behaviour: the real lead can end the trip.
  wsLead.sendJson({ type: 'TRIP_STATUS', status: 'ENDED' });
  await wsPack.next((m) => m.type === 'TRIP_STATUS' && m.tripStatus === 'ENDED');
  assert.equal((await t.gw.repo.getConvoyMeta(gid)).tripStatus, 'ENDED');
  wsLead.close(); wsPack.close();
});
