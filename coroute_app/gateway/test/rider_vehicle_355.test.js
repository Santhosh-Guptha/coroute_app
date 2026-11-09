'use strict';
/**
 * 3.55 live bike change: RIDER_VEHICLE {vehicleColor?, vehicleModel?} when the rider picks another
 * garage bike mid-ride. Validated, one per rider per 10 s, refused for a pillion or a swapped bike,
 * broadcast as RIDER_UPDATE and kept in the snapshot; HELLO advertises 'vehicle1'; the admin
 * switch riderVehicleLive turns it off (403 FEATURE_OFF).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { riderVehicleInput, VEHICLE_RATE_MS } = require('../src/convoys');

const T0 = Date.UTC(2026, 10, 9, 6, 0, 0);
let t, gw, now = T0;
before(async () => { mock.timers.enable({ apis: ['Date'], now: T0 }); t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); mock.timers.reset(); });
const advance = (ms) => { now += ms; mock.timers.setTime(now); };

let n = 0;
async function ride(count = 2) {
  n++;
  const lead = await t.register(`Veh Owner ${n}`, `vehowner${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Vehicle ${n}`, rider: { vehicleColor: 'Red' } }, lead.token)).json;
  const members = [];
  for (let i = 0; i < count; i++) {
    n++;
    const u = await t.register(`Veh Rider ${n}`, `vehrider${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode, rider: { vehicleColor: 'Blue', vehicleModel: 'Classic 350' } }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  return { lead, c, gid: c.groupId, room: gw.convoys.rooms.get(c.groupId), members };
}
const uid = (u) => u.user.userId;

test('riderVehicleInput: colour names and #RRGGBB, a model of at most 40 characters, nothing else', () => {
  assert.deepEqual(riderVehicleInput({ vehicleColor: 'Kaza Brown' }), { vehicleColor: 'Kaza Brown' });
  assert.deepEqual(riderVehicleInput({ vehicleColor: '#a1b2c3', vehicleModel: '  Himalayan\n 450 ' }), { vehicleColor: '#A1B2C3', vehicleModel: 'Himalayan 450' });
  assert.deepEqual(riderVehicleInput({ vehicleColor: '' }), { vehicleColor: '' }, 'empty = no colour (default shown)');
  assert.deepEqual(riderVehicleInput({ vehicleModel: 'm'.repeat(40) }), { vehicleModel: 'm'.repeat(40) });
  assert.deepEqual(riderVehicleInput({ vehicleModel: 'Duke\u202E 390' }), { vehicleModel: 'Duke 390' }, 'direction overrides stripped');
  const bad = [
    {}, { vehicleColor: null, vehicleModel: null }, { vehicleColor: 5 }, { vehicleColor: '#12345' }, { vehicleColor: '#GGGGGG' },
    { vehicleColor: 'c'.repeat(21) }, { vehicleColor: '<script>' }, { vehicleColor: '1Red' }, { vehicleColor: 'red\u0000' },
    { vehicleModel: 'm'.repeat(41) }, { vehicleModel: { a: 1 } },
  ];
  for (const b of bad) assert.throws(() => riderVehicleInput(b), (e) => e.reason === 'BAD_VEHICLE', JSON.stringify(b));
  assert.equal(VEHICLE_RATE_MS, 10000);
});

test('HELLO advertises vehicle1; the join model is kept; a bike change mid-ride reaches the group and the snapshot', async () => {
  const R = await ride();
  const [ravi] = R.members;
  assert.equal(R.room.riders.get(uid(ravi)).vehicleModel, 'Classic 350', 'join carries the model');
  const wl = await t.joinRoom(R.lead.token, R.gid);
  const wr = await t.joinRoom(ravi.token, R.gid);
  const hello = wr.inbox.find((m) => m.type === 'HELLO') || await wr.next((m) => m.type === 'HELLO');
  assert.ok(hello.features.includes('vehicle1'));

  wr.sendJson({ type: 'RIDER_VEHICLE', vehicleColor: 'Gunmetal Grey', vehicleModel: 'Interceptor 650' });
  const upd = await wl.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(ravi) && m.rider.vehicleColor === 'Gunmetal Grey');
  assert.equal(upd.rider.vehicleModel, 'Interceptor 650');
  assert.equal(upd.rider.rideVehicle, undefined);

  // The snapshot (a late joiner, a reconnect) has it too; the profile is unchanged.
  const snap = gw.convoys.snapshot(R.room);
  assert.equal(snap.riders[uid(ravi)].vehicleColor, 'Gunmetal Grey');
  assert.equal(snap.riders[uid(ravi)].vehicleModel, 'Interceptor 650');
  const again = await t.api('POST', '/convoys/join', { code: R.c.joinCode }, R.members[1].token);
  assert.equal(again.json.riders[uid(ravi)].vehicleColor, 'Gunmetal Grey');

  // A second change within 10 s is refused (409, the app sends the latest after the window).
  wr.sendJson({ type: 'RIDER_VEHICLE', vehicleColor: 'Black' });
  assert.equal((await wr.next((m) => m.type === 'ERROR' && m.reason === 'VEHICLE_RATE')).code, 409);
  assert.equal(R.room.riders.get(uid(ravi)).vehicleColor, 'Gunmetal Grey');
  advance(VEHICLE_RATE_MS + 1);
  wr.sendJson({ type: 'RIDER_VEHICLE', vehicleColor: '#112233' });
  await wl.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(ravi) && m.rider.vehicleColor === '#112233');
  assert.equal(R.room.riders.get(uid(ravi)).vehicleModel, 'Interceptor 650', 'a colour-only update keeps the model');

  // Invalid values are refused and change nothing.
  advance(VEHICLE_RATE_MS + 1);
  wr.sendJson({ type: 'RIDER_VEHICLE', vehicleColor: 'x'.repeat(50) });
  assert.equal((await wr.next((m) => m.type === 'ERROR' && m.reason === 'BAD_VEHICLE')).code, 400);
  assert.equal(R.room.riders.get(uid(ravi)).vehicleColor, '#112233');

  // Saved with the rider record (the room flush).
  await sleep(80);
  const saved = (await gw.repo.listRiders(R.gid)).find((r) => r.userId === uid(ravi));
  if (saved) assert.equal(saved.vehicleColor, '#112233');
  wl.close(); wr.close();
});

test('a pillion or a swapped bike is refused; the admin switch turns it off; an ended ride refuses', async () => {
  const R = await ride(3);
  const [ravi, kiran, arjun] = R.members;
  const wr = await t.joinRoom(ravi.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  const wa = await t.joinRoom(arjun.token, R.gid);

  // Arjun rides pillion with Ravi.
  wa.sendJson({ type: 'CORIDER', ridingWithUserId: uid(ravi) });
  await sleep(30);
  wa.sendJson({ type: 'RIDER_VEHICLE', vehicleColor: 'Green' });
  assert.equal((await wa.next((m) => m.type === 'ERROR' && m.reason === 'PILLION_RIDER')).code, 409);

  // Ravi and Kiran swap bikes: the swap decides their bikes in this ride.
  wr.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'BIKES', clientId: 'v1' });
  const ask = await wk.next((m) => m.type === 'SWAP_ASK');
  wk.sendJson({ type: 'SWAP_ANSWER', requestId: ask.requestId, accept: true, clientId: 'v2' });
  await wk.next((m) => m.type === 'ACK' && m.clientId === 'v2');
  wr.sendJson({ type: 'RIDER_VEHICLE', vehicleColor: 'White' });
  assert.equal((await wr.next((m) => m.type === 'ERROR' && m.reason === 'BIKE_SWAPPED')).code, 409);

  // Admin switch off: 403 FEATURE_OFF, nothing changes.
  const ff = gw.convoys.featureFlags;
  assert.ok(ff, 'feature switches are wired');
  ff._apply({ flags: { riderVehicleLive: false }, updatedAt: now });
  const before = R.room.riders.get(uid(R.lead)).vehicleColor;
  const wl = await t.joinRoom(R.lead.token, R.gid);
  wl.sendJson({ type: 'RIDER_VEHICLE', vehicleColor: 'Yellow' });
  assert.equal((await wl.next((m) => m.type === 'ERROR' && m.reason === 'FEATURE_OFF')).code, 403);
  assert.equal(R.room.riders.get(uid(R.lead)).vehicleColor, before);
  ff._apply({ flags: {}, updatedAt: now + 1 });
  wl.sendJson({ type: 'RIDER_VEHICLE', vehicleColor: 'Yellow' });
  await wk.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(R.lead) && m.rider.vehicleColor === 'Yellow');

  // An ended ride refuses.
  advance(VEHICLE_RATE_MS + 1);
  await assert.rejects(async () => {
    R.room.meta.tripStatus = 'ENDED';
    try { await gw.convoys.setRiderVehicle(R.gid, R.lead.user, { vehicleColor: 'Blue' }); } finally { R.room.meta.tripStatus = 'STARTED'; }
  }, (e) => e.reason === 'TRIP_ENDED');
  wr.close(); wk.close(); wa.close(); wl.close();
});
