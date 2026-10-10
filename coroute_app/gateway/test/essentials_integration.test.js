'use strict';
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { sanitizeTelemetry, publicRider } = require('../src/convoys');
const { encodePolyline } = require('../src/geo_math');
const { boot } = require('./_helpers');

test('fuel telemetry is opt-in, bounded and contains no private tank data', () => {
  assert.equal(Object.hasOwn(sanitizeTelemetry({}), 'fuelEstimate'), false);
  const confirmedAt = Date.now() - 1000;
  const out = sanitizeTelemetry({ fuelEstimate: { usableKm: 54.9, confirmedAt, litres: 2, mileage: 30, updatedAt: 9999999999999 }, role: 'LEAD' });
  assert.deepEqual(Object.keys(out.fuelEstimate).sort(), ['confirmedAt', 'updatedAt', 'usableKm']);
  assert.equal(out.fuelEstimate.usableKm, 54);
  assert.ok(out.fuelEstimate.updatedAt <= Date.now());
  assert.equal(out.role, undefined);
  for (const fuelEstimate of [null, {}, { usableKm: -1, confirmedAt }, { usableKm: Infinity, confirmedAt }, { usableKm: 99, confirmedAt: Date.now() + 120000 }, { usableKm: '54', confirmedAt }]) {
    assert.equal(sanitizeTelemetry({ fuelEstimate }).fuelEstimate, null);
  }
});
test('old group fuel estimates expire independently of rider heartbeat', () => {
  const fresh = { usableKm: 54, confirmedAt: Date.now() - 60000, updatedAt: Date.now() };
  assert.equal(publicRider({ fuelEstimate: fresh }).fuelEstimate.usableKm, 54);
  assert.equal(publicRider({ fuelEstimate: { ...fresh, updatedAt: Date.now() - 120001 }, lastSeenEpochMs: Date.now() }).fuelEstimate, null);
  assert.equal(publicRider({ fuelEstimate: null }).fuelEstimate, null);
});
test('essentials endpoint requires auth; invalid requests and disabled provider are explicit', async () => {
  const t = await boot();
  try {
    const body = { polyline: encodePolyline([{ lat: 17, lng: 78 }, { lat: 18, lng: 78 }]), category: 'FUEL', fromM: 0 };
    assert.equal((await t.api('POST', '/geo/essentials', body)).status, 401);
    const user = await t.register('Fuel Rider', 'fuel-route@test.example');
    assert.equal((await t.api('POST', '/geo/essentials', { ...body, category: 'INVALID' }, user.token)).status, 400);
    const reply = await t.api('POST', '/geo/essentials', body, user.token);
    assert.equal(reply.status, 503); assert.equal(reply.json.code, 'ESSENTIALS_NOT_CONFIGURED');
  } finally { await t.gw.shutdown(); }
});
test('group websocket shares only own fuel estimate and withdraws it on opt-out', async () => {
  const t = await boot(); let a, b;
  try {
    const lead = await t.register('Fuel Lead', 'fuel-lead@test.example');
    const member = await t.register('Fuel Member', 'fuel-member@test.example');
    const c = await t.api('POST', '/convoys', { name: 'Fuel group' }, lead.token);
    assert.equal(c.status, 201);
    await t.api('POST', '/convoys/join', { code: c.json.joinCode }, member.token);
    a = await t.joinRoom(lead.token, c.json.groupId); b = await t.joinRoom(member.token, c.json.groupId);
    const confirmedAt = Date.now();
    b.sendJson({ type: 'TELEMETRY', userId: lead.user?.userId, fuelEstimate: { usableKm: 61, confirmedAt, litres: 3 } });
    const update = await a.next(m => m.type === 'RIDER_UPDATE' && m.rider.fuelEstimate?.usableKm === 61);
    assert.equal(update.rider.name, 'Fuel Member'); assert.equal(update.rider.fuelEstimate.litres, undefined);
    b.sendJson({ type: 'TELEMETRY', fuelEstimate: null });
    const withdrawn = await a.next(m => m.type === 'RIDER_UPDATE' && m.rider.fuelEstimate === null);
    assert.equal(withdrawn.rider.name, 'Fuel Member');
    b.sendJson({ type: 'STOP_ADD', name: 'Mapped hospital', lat: 17.1, lng: 78, category: 'HOSPITAL' });
    const suggestion = await a.next(m => m.type === 'STOPS' && m.stopPoints.some(s => s.name === 'Mapped hospital'));
    const stop = suggestion.stopPoints.find(s => s.name === 'Mapped hospital');
    assert.equal(stop.category, 'HOSPITAL'); assert.equal(stop.status, 'SUGGESTED');
  } finally { a?.close(); b?.close(); await t.gw.shutdown(); }
});
