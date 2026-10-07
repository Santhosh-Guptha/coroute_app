'use strict';
process.env.NODE_ENV = 'test';
process.env.TRIP_MAX_TRAIL_POINTS = '50';
process.env.MAX_TRIPS_PER_USER = '3';
process.env.PV_MAX_REFERRERS = '2';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const bcrypt = require('bcryptjs');
const { boot, sleep } = require('./_helpers');
const { profileFields, sitePath, tripRecord } = require('../src/validate');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('profile rules: lengths, phone pattern, bike number, no @ in callsigns', () => {
  assert.deepEqual(profileFields({ phone: ' +91 98765-43210 ' }), { phone: '+91 98765 43210' });
  assert.equal(profileFields({ vehicleNo: 'ka-01-ab-1234' }).vehicleNo, 'KA-01-AB-1234');
  assert.equal(profileFields({ vehicleNo: 'pillion' }).vehicleNo, 'PILLION');
  for (const bad of [{ name: 'x' }, { name: 'a'.repeat(41) }, { name: 'me@home' }, { name: 'bad\u0000name' }, { phone: '12' }, { phone: 'call me' },
    { vehicleNo: 'TS09<script>' }, { vehicleNo: 'A'.repeat(17) }, { emergencyContactName: 'x' }, { vehicleType: 'v'.repeat(31) }, { email: 'nope' }]) {
    assert.throws(() => profileFields(bad), (e) => e.status === 422 && Object.keys(e.fields).length === 1, JSON.stringify(bad));
  }
});

test('register and profile updates are validated; callsigns stay unique', async () => {
  const bad = await t.api('POST', '/auth/register', { name: 'Val Rider', email: 'valbad@coroute.test', password: 'Password#123', phone: 'abc' });
  assert.equal(bad.status, 422);
  assert.ok(bad.json.fields.phone);

  const a = await t.register('Val Alpha', 'valalpha@coroute.test');
  await t.register('Val Beta', 'valbeta@coroute.test');

  const huge = await t.api('PATCH', '/me', { name: 'x'.repeat(100000) }, a.token);
  assert.equal(huge.status, 422);
  assert.equal((await t.api('PATCH', '/me', { name: '' }, a.token)).status, 422);
  const clash = await t.api('PATCH', '/me', { name: 'val beta' }, a.token);
  assert.equal(clash.status, 409);
  assert.equal(clash.json.code, 'CALLSIGN_TAKEN');
  // Your own callsign (any capitals) is never "taken".
  const own = await t.api('PATCH', '/me', { name: 'VAL ALPHA' }, a.token);
  assert.equal(own.status, 200);
  assert.equal(own.json.name, 'VAL ALPHA');
  const objectPhone = await t.api('PATCH', '/me', { phone: { evil: true } }, a.token);
  assert.equal(objectPhone.status, 422);
});

test('riders with details that predate the rules are never locked out', async () => {
  // An old account: duplicate-ish callsign with an @, a short phone, a messy bike number.
  await t.gw.repo.createUser({
    userId: 'usr_legacy', name: 'old@rider', email: 'legacy@coroute.test', passwordHash: await bcrypt.hash('Password#123', 4),
    role: 'RIDER', provider: 'password', phone: '12345', vehicleType: 'Motorcycle', vehicleNo: 'ts 09 / 1234',
    emergencyContact: '1234567', emergencyContactName: 'Mum', createdAt: Date.now() - 86400000,
  });
  const login = await t.api('POST', '/auth/login', { identifier: 'legacy@coroute.test', password: 'Password#123' });
  assert.equal(login.status, 200);
  // The app sends every field; only the changed one is checked.
  const upd = await t.api('PATCH', '/me', {
    name: 'old@rider', phone: '12345', vehicleType: 'Scooter', vehicleNo: 'TS 09 / 1234', emergencyContact: '1234567', emergencyContactName: 'Mum',
  }, login.json.token);
  assert.equal(upd.status, 200, JSON.stringify(upd.json));
  assert.equal(upd.json.vehicleType, 'Scooter');
  assert.equal(upd.json.phone, '12345');
  // A new value must pass.
  assert.equal((await t.api('PATCH', '/me', { phone: '999' }, login.json.token)).status, 422);
  assert.equal((await t.api('PATCH', '/me', { phone: '+919811122233' }, login.json.token)).json.phone, '+919811122233');
});

test('every non-admin needs the safety profile to ride, with or without the app header', async () => {
  const r = await t.api('POST', '/auth/register', { name: 'Val Partial', email: 'valpartial@coroute.test', password: 'Password#123', phone: '9999999999' });
  assert.equal(r.status, 201);
  const create = await t.api('POST', '/convoys', { name: 'No profile' }, r.json.token);
  assert.equal(create.status, 400);
  assert.equal(create.json.code, 'PROFILE_INCOMPLETE');
  const join = await t.api('POST', '/convoys/join', { code: '123456' }, r.json.token);
  assert.equal(join.status, 400);
  assert.equal(join.json.code, 'PROFILE_INCOMPLETE');
});

test('trips: known fields only, trail capped, size and count limits', async () => {
  const u = await t.register('Val Tripper', 'valtrip@coroute.test');
  const trail = Array.from({ length: 200 }, (_, i) => ({ lat: 17 + i / 1000, lng: 78, speedKmh: 40, heading: 90, timestamp: i * 1000, junk: 'x' }));
  const ok = await t.api('POST', '/trips', { tripId: 'TRIP-VAL-1', tripName: 'n'.repeat(500), endTimeEpochMs: Date.now(), junkField: 'y'.repeat(1000), breadcrumbTrail: trail, userId: 'someone_else', source: 'server' }, u.token);
  assert.equal(ok.status, 201);
  const stored = await t.gw.repo.getTrip('TRIP-VAL-1');
  assert.equal(stored.junkField, undefined);
  assert.equal(stored.tripName.length, 120);
  assert.equal(stored.userId, u.user.userId);
  assert.equal(stored.source, 'device');
  assert.equal(stored.breadcrumbTrail.length, 50);
  assert.equal(stored.breadcrumbTrail[0].junk, undefined);
  assert.equal(stored.breadcrumbTrail[49].timestamp, 199000, 'the last point is kept');

  const big = await t.api('POST', '/trips', { tripId: 'TRIP-VAL-BIG', blob: 'z'.repeat(1500000) }, u.token);
  assert.equal(big.status, 413);
  assert.equal(await t.gw.repo.getTrip('TRIP-VAL-BIG'), null);
  assert.equal((await t.api('POST', '/trips', { tripId: 'a b' }, u.token)).status, 400);

  assert.equal((await t.api('POST', '/trips', { tripId: 'TRIP-VAL-2' }, u.token)).status, 201);
  assert.equal((await t.api('POST', '/trips', { tripId: 'TRIP-VAL-3' }, u.token)).status, 201);
  const fourth = await t.api('POST', '/trips', { tripId: 'TRIP-VAL-4' }, u.token);
  assert.equal(fourth.status, 409);
  assert.equal(fourth.json.code, 'TOO_MANY_TRIPS');
  // Updating a trip you already have is always allowed.
  assert.equal((await t.api('POST', '/trips', { tripId: 'TRIP-VAL-3', tripName: 'Renamed' }, u.token)).status, 201);
});

test('page views: only site pages are counted, referrers are capped', async () => {
  assert.equal(sitePath('/'), '/');
  assert.equal(sitePath('/privacy.html'), '/privacy');
  assert.equal(sitePath('/join/483921'), '/join');
  assert.equal(sitePath('/random-' + Math.random()), null);
  assert.equal(sitePath('https://evil.example/'), null);

  const pv = (body) => fetch(t.base + '/pv', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify(body) });
  for (const path of ['/x1', '/x2', '/wp-admin', '/terms/../../etc']) assert.equal((await pv({ path })).status, 204);
  for (const host of ['a.example', 'b.example', 'c.example', 'd.example']) await pv({ path: '/terms', ref: `https://${host}/` });
  await pv({ path: '/join/123456' });
  await sleep(80);
  const rows = await t.gw.repo.listPageviews(new Date().toISOString().slice(0, 10));
  assert.deepEqual(rows.map((r) => r.path).sort(), ['/join', '/terms']);
  const terms = rows.find((r) => r.path === '/terms');
  assert.equal(terms.count, 4);
  assert.equal(Object.keys(terms.referrers).length, 3, 'two hosts plus "other"');
  assert.equal(terms.referrers.other, 2);
});

test('socket write budget: STATUS bursts and repeated WAIT/SOS are slowed down', async () => {
  const lead = await t.register('Val Burst', 'valburst@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Burst ride' }, lead.token)).json;
  const ws = await t.joinRoom(lead.token, c.groupId);
  for (let i = 0; i < 20; i++) ws.sendJson({ type: 'STATUS', statusReason: i % 2 ? 'FUELING' : 'REST_BREAK' });
  await sleep(300);
  const slowed = ws.inbox.filter((m) => m.type === 'ERROR' && m.code === 429).length;
  assert.ok(slowed >= 10, `slowed ${slowed}`);
  await t.gw.timeline.idle();
  const statusEvents = (await t.gw.repo.listEvents(c.groupId)).filter((e) => e.type === 'STATUS').length;
  assert.ok(statusEvents >= 1 && statusEvents <= 10, `status events ${statusEvents}`);

  ws.inbox.length = 0;
  for (let i = 0; i < 4; i++) ws.sendJson({ type: 'WAIT' });
  await sleep(300);
  assert.equal(ws.inbox.filter((m) => m.type === 'ERROR' && m.code === 429).length, 1, 'the 4th WAIT in 10 s is refused');
  ws.close();
});

test('tripRecord keeps a trip from a phone usable', () => {
  const r = tripRecord({ tripId: 'TRIP-ABCD-usr_x', totalDistanceKm: '12.5', riderCount: 'NaN', breadcrumbTrail: [{ lat: 'a', lng: 1 }, { lat: 1, lng: 2 }] });
  assert.equal(r.totalDistanceKm, 12.5);
  assert.equal(r.riderCount, 0);
  assert.equal(r.breadcrumbTrail.length, 1);
});
