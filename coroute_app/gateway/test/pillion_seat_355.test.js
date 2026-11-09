'use strict';
/**
 * 3.55 pillion seat: a pillion confirms which bike they ride on (PILLION_SEAT {withUserId}); the
 * gateway checks the target (a rider of this ride with a bike, no pillion yet, not themselves),
 * links pillion -> rider on this ride's records, tells everyone (RIDER_UPDATE + PILLION_SEATED);
 * the rider may decline within 60 s or remove the pillion any time (PILLION_UNSEAT), the pillion may
 * get off; a rider who leaves unlinks the pillion. The link is in the room snapshot. HELLO
 * advertises 'pillion2'; older apps keep using CORIDER. The admin switch pillionSeat turns the
 * seat message off (403 FEATURE_OFF); getting off is never switched off.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { PILLION_DECLINE_MS, PILLION_RATE_MAX, riderVehicleInput } = require('../src/convoys');
const { wsFeaturesFor } = require('../src/feature_flags');

const T0 = Date.UTC(2026, 10, 9, 7, 0, 0);
let t, gw, now = T0;
before(async () => { mock.timers.enable({ apis: ['Date'], now: T0 }); t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); mock.timers.reset(); });
const advance = (ms) => { now += ms; mock.timers.setTime(now); };

let n = 0;
async function ride() {
  n++;
  const lead = await t.register(`Seat Owner ${n}`, `seatowner${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Seat ${n}`, rider: { vehicleColor: 'Red', vehicleModel: 'Classic 350', vehicleKind: 'retro', bikeComplete: true } }, lead.token)).json;
  const members = [];
  for (const tag of ['Asha', 'Kiran', 'Arjun']) {
    n++;
    const u = await t.register(`${tag} ${n}`, `seat${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode, rider: { vehicleColor: 'Blue', vehicleModel: 'Himalayan 450', vehicleKind: 'adventure' } }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  return { lead, c, gid: c.groupId, room: gw.convoys.rooms.get(c.groupId), members };
}
const uid = (u) => u.user.userId;
const rec = (R, u) => R.room.riders.get(uid(u));
const end = (R) => t.api('POST', `/convoys/${R.gid}/status`, { status: 'ENDED' }, R.lead.token);
const result = (w, cid) => w.next((m) => (m.type === 'ACK' || m.type === 'ERROR') && m.clientId === cid);

test('bike type and bikeComplete ride with the rider record; old apps sending nothing are accepted (incomplete)', async () => {
  const R = await ride();
  const lead = rec(R, R.lead);
  assert.equal(lead.vehicleKind, 'retro');
  assert.equal(lead.bikeComplete, true);
  const asha = rec(R, R.members[0]);
  assert.equal(asha.vehicleKind, 'adventure');
  assert.equal(asha.bikeComplete, false, 'no claim = incomplete, never refused');
  // An old app: no vehicle at all.
  n++;
  const old = await t.register(`Old ${n}`, `seatold${n}@coroute.test`);
  const j = await t.api('POST', '/convoys/join', { code: R.c.joinCode }, old.token);
  assert.equal(j.status, 200);
  assert.equal(j.json.riders[uid(old)].vehicleKind, '');
  assert.equal(j.json.riders[uid(old)].bikeComplete, false);
  // Junk bike types are dropped at join and refused live.
  n++;
  const junk = await t.register(`Junk ${n}`, `seatjunk${n}@coroute.test`);
  const jj = await t.api('POST', '/convoys/join', { code: R.c.joinCode, rider: { vehicleKind: '<b>tank</b>' } }, junk.token);
  assert.equal(jj.json.riders[uid(junk)].vehicleKind, '');
  assert.deepEqual(riderVehicleInput({ vehicleKind: 'scooter', bikeComplete: true }), { vehicleKind: 'scooter', bikeComplete: true });
  assert.throws(() => riderVehicleInput({ vehicleKind: 'tank' }), (e) => e.reason === 'BAD_VEHICLE');
  assert.throws(() => riderVehicleInput({ bikeComplete: true }), (e) => e.reason === 'BAD_VEHICLE', 'a claim alone is not a bike');
  await end(R);
});

test('seat: validated, broadcast to all, persisted in the snapshot; rider declines within 60 s', async () => {
  const R = await ride();
  const [asha, kiran, arjun] = R.members;
  const wa = await t.joinRoom(asha.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  const wj = await t.joinRoom(arjun.token, R.gid);
  const wl = await t.joinRoom(R.lead.token, R.gid);
  const hello = wk.inbox.find((m) => m.type === 'HELLO') || await wk.next((m) => m.type === 'HELLO');
  assert.ok(hello.features.includes('pillion2'));

  // Not themselves; not a stranger; not empty.
  wk.sendJson({ type: 'PILLION_SEAT', withUserId: uid(kiran), clientId: 'p0' });
  assert.equal((await result(wk, 'p0')).reason, 'BAD_PILLION');
  wk.sendJson({ type: 'PILLION_SEAT', withUserId: 'nobody', clientId: 'p0b' });
  assert.equal((await result(wk, 'p0b')).reason, 'NOT_MEMBER');
  wk.sendJson({ type: 'PILLION_SEAT', clientId: 'p0c' });
  assert.equal((await result(wk, 'p0c')).reason, 'BAD_PILLION');

  wk.sendJson({ type: 'PILLION_SEAT', withUserId: uid(asha), clientId: 'p1' });
  assert.equal((await result(wk, 'p1')).type, 'ACK');
  for (const w of [wa, wj, wl, wk]) {
    const ev = await w.next((m) => m.type === 'PILLION_SEATED');
    assert.equal(ev.pillion.userId, uid(kiran));
    assert.equal(ev.rider.userId, uid(asha));
    assert.equal(ev.rider.vehicleModel, 'Himalayan 450');
    assert.equal(ev.rider.vehicleKind, 'adventure');
    assert.equal(ev.declineBy, ev.at + PILLION_DECLINE_MS);
  }
  const upd = await wl.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(kiran) && m.rider.isCoRiding);
  assert.equal(upd.rider.ridingWithUserId, uid(asha));
  assert.equal(upd.rider.pillionSeatAt, now);

  // Snapshot (late joiner / reconnect) and the stored room snapshot carry the link.
  const snap = gw.convoys.snapshot(R.room);
  assert.equal(snap.riders[uid(kiran)].ridingWithUserId, uid(asha));
  await sleep(60);
  const stored = await gw.repo.listRiders(R.gid);
  const ks = (Array.isArray(stored) ? stored : Object.values(stored)).find((r) => r.userId === uid(kiran));
  assert.equal(ks.ridingWithUserId, uid(asha));
  assert.equal(ks.isCoRiding, true);

  // Seat taken; a pillion is no target; a rider carrying a pillion cannot become one.
  wj.sendJson({ type: 'PILLION_SEAT', withUserId: uid(asha), clientId: 'p2' });
  assert.equal((await result(wj, 'p2')).reason, 'SEAT_TAKEN');
  wj.sendJson({ type: 'PILLION_SEAT', withUserId: uid(kiran), clientId: 'p3' });
  assert.equal((await result(wj, 'p3')).reason, 'TARGET_PILLION');
  wa.sendJson({ type: 'PILLION_SEAT', withUserId: uid(arjun), clientId: 'p4' });
  assert.equal((await result(wa, 'p4')).reason, 'HAS_PILLION');
  // A pillion has no bike of their own to change.
  wk.sendJson({ type: 'RIDER_VEHICLE', vehicleColor: 'Green' });
  assert.equal((await wk.next((m) => m.type === 'ERROR' && m.reason === 'PILLION_RIDER')).code, 409);
  // Only the rider of that bike may remove the pillion.
  wj.sendJson({ type: 'PILLION_UNSEAT', userId: uid(kiran), clientId: 'p5' });
  assert.equal((await result(wj, 'p5')).reason, 'NOT_YOUR_PILLION');

  // Asha declines within the window: everyone hears it, Kiran is a rider on their own again.
  advance(20000);
  wa.sendJson({ type: 'PILLION_UNSEAT', userId: uid(kiran), clientId: 'p6' });
  assert.equal((await result(wa, 'p6')).type, 'ACK');
  for (const w of [wk, wj, wl]) {
    const ev = await w.next((m) => m.type === 'PILLION_UNSEATED');
    assert.equal(ev.reason, 'DECLINED');
    assert.equal(ev.pillion.userId, uid(kiran));
    assert.equal(ev.rider.userId, uid(asha));
  }
  assert.equal(rec(R, kiran).isCoRiding, false);
  assert.equal(rec(R, kiran).ridingWithUserId, '');
  for (const w of [wa, wk, wj, wl]) w.close();
  await end(R);
});

test('remove after the window, pillion gets off, rider leaves, rate limit, ride end', async () => {
  const R = await ride();
  const [asha, kiran, arjun] = R.members;
  const wa = await t.joinRoom(asha.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  const wl = await t.joinRoom(R.lead.token, R.gid);

  wk.sendJson({ type: 'PILLION_SEAT', withUserId: uid(asha), clientId: 'q1' });
  await result(wk, 'q1');
  advance(PILLION_DECLINE_MS + 1000);
  wa.sendJson({ type: 'PILLION_UNSEAT', userId: uid(kiran), clientId: 'q2' });
  await result(wa, 'q2');
  assert.equal((await wl.next((m) => m.type === 'PILLION_UNSEATED')).reason, 'REMOVED');

  // The pillion gets off by themselves.
  advance(1100);
  wk.sendJson({ type: 'PILLION_SEAT', withUserId: uid(asha), clientId: 'q3' });
  await result(wk, 'q3');
  advance(1100);
  wk.sendJson({ type: 'PILLION_UNSEAT', clientId: 'q4' });
  await result(wk, 'q4');
  assert.equal((await wl.next((m) => m.type === 'PILLION_UNSEATED' && m.reason === 'PILLION_LEFT')).pillion.userId, uid(kiran));
  wk.sendJson({ type: 'PILLION_UNSEAT', clientId: 'q5' });
  assert.equal((await result(wk, 'q5')).reason, 'NOT_SEATED');

  // Moving to another bike: the first rider is told (MOVED).
  advance(1100);
  wk.sendJson({ type: 'PILLION_SEAT', withUserId: uid(asha), clientId: 'q6' });
  await result(wk, 'q6');
  advance(1100);
  wk.sendJson({ type: 'PILLION_SEAT', withUserId: uid(arjun), clientId: 'q7' });
  await result(wk, 'q7');
  const moved = await wl.next((m) => m.type === 'PILLION_UNSEATED' && m.reason === 'MOVED');
  assert.equal(moved.rider.userId, uid(asha));
  assert.equal(rec(R, kiran).ridingWithUserId, uid(arjun));

  // Rate limit: PILLION_RATE_MAX seat changes per 10 minutes (4 used).
  let limited = 0;
  for (let i = 0; i < 3; i++) {
    advance(1100);
    wk.sendJson({ type: 'PILLION_SEAT', withUserId: i % 2 ? uid(arjun) : uid(asha), clientId: `rl${i}` });
    const m = await result(wk, `rl${i}`);
    if (m.type === 'ERROR') { assert.equal(m.reason, 'PILLION_RATE'); limited++; }
  }
  assert.equal(PILLION_RATE_MAX, 6);
  assert.equal(limited, 1);
  advance(10 * 60000);

  // The rider leaves: the pillion is unlinked and told to pick again.
  const host = rec(R, kiran).ridingWithUserId;
  const hostUser = host === uid(asha) ? asha : arjun;
  assert.equal((await t.api('POST', `/convoys/${R.gid}/leave`, {}, hostUser.token)).status, 200);
  const gone = await wk.next((m) => m.type === 'PILLION_UNSEATED' && m.reason === 'RIDER_LEFT');
  assert.equal(gone.rider.userId, host);
  assert.equal(rec(R, kiran).isCoRiding, false);

  // A pillion who leaves frees the seat.
  const other = hostUser === asha ? arjun : asha;
  const wo = await t.joinRoom(other.token, R.gid);
  wk.sendJson({ type: 'PILLION_SEAT', withUserId: uid(other), clientId: 'q8' });
  assert.equal((await result(wk, 'q8')).type, 'ACK');
  wk.close();
  assert.equal((await t.api('POST', `/convoys/${R.gid}/leave`, {}, kiran.token)).status, 200);
  assert.equal((await wo.next((m) => m.type === 'PILLION_UNSEATED' && m.reason === 'PILLION_LEFT')).rider.userId, uid(other));

  for (const w of [wa, wl, wo]) w.close();
  await end(R);
  // An ended ride refuses.
  await assert.rejects(() => gw.convoys.seatPillion(R.gid, other.user, uid(R.lead)), (e) => ['TRIP_ENDED', 'RIDE_ENDED'].includes(e.reason) || e.status === 404 || e.status === 409);
});

test('old clients: CORIDER still links (no self link); admin switch pillionSeat off refuses the seat, never the getting off', async () => {
  assert.deepEqual(wsFeaturesFor({ type: 'PILLION_SEAT' }), ['pillionSeat']);
  assert.deepEqual(wsFeaturesFor({ type: 'PILLION_UNSEAT' }), []);
  const R = await ride();
  const [asha, kiran, arjun] = R.members;
  const wk = await t.joinRoom(kiran.token, R.gid);
  const wj = await t.joinRoom(arjun.token, R.gid);
  const wl = await t.joinRoom(R.lead.token, R.gid);
  // Old app: CORIDER, as before (an old app sees the pillion as a normal rider with isCoRiding).
  wj.sendJson({ type: 'CORIDER', ridingWithUserId: uid(asha) });
  const up = await wl.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(arjun) && m.rider.isCoRiding);
  assert.equal(up.rider.ridingWithUserId, uid(asha));
  wk.sendJson({ type: 'CORIDER', ridingWithUserId: uid(kiran) });
  assert.equal((await wk.next((m) => m.type === 'ERROR' && m.reason === 'BAD_PILLION')).code, 400);

  const ff = gw.convoys.featureFlags;
  ff._apply({ flags: { pillionSeat: false }, updatedAt: now });
  wk.sendJson({ type: 'PILLION_SEAT', withUserId: uid(R.lead), clientId: 'f1' });
  const off = await result(wk, 'f1');
  assert.equal(off.reason, 'FEATURE_OFF');
  assert.equal(rec(R, kiran).isCoRiding, false);
  wj.sendJson({ type: 'PILLION_UNSEAT', clientId: 'f2' });
  assert.equal((await result(wj, 'f2')).type, 'ACK', 'getting off works while the switch is off');
  ff._apply({ flags: {}, updatedAt: now + 1 });
  for (const w of [wk, wj, wl]) w.close();
  await end(R);
});

// ---------------------------------------------------------------- 3.55 group checks once per bike
const { TimelineEngine, oncePerBike } = require('../src/timeline');

test('oncePerBike: a seated pillion is left out while their rider is counted; stands for the bike otherwise', () => {
  const rider = { userId: 'R', isCoRiding: false };
  const pillion = { userId: 'P', isCoRiding: true, ridingWithUserId: 'R' };
  const solo = { userId: 'S' };
  assert.deepEqual(oncePerBike([rider, pillion, solo]).map((r) => r.userId), ['R', 'S']);
  // Rider not fresh (not in the list): the pillion carries the bike.
  assert.deepEqual(oncePerBike([pillion, solo]).map((r) => r.userId), ['P', 'S']);
  // A link to oneself or to another pillion is no seat.
  assert.equal(oncePerBike([{ userId: 'X', isCoRiding: true, ridingWithUserId: 'X' }]).length, 1);
  assert.equal(oncePerBike([pillion, { userId: 'R', isCoRiding: true, ridingWithUserId: 'Q' }]).length, 2);
  // keep(): a pillion holding a role stays.
  assert.equal(oncePerBike([rider, { ...pillion, role: 'SWEEPER' }], (r) => r.role === 'SWEEPER').length, 2);
});

function fakeEngine() {
  const opened = [];
  const closed = [];
  return {
    opened, closed,
    _rs: TimelineEngine.prototype._rs,
    _route: () => null,
    _leadsAndSweeper: () => [],
    async _open(gid, st, slot, ev) { st.open.set(slot, { ...ev, data: { ...ev.data } }); opened.push(slot); },
    async _close(gid, st, slot) { if (st.open.delete(slot)) closed.push(slot); },
  };
}
const st0 = () => ({ riders: new Map(), open: new Map() });
const at = (userId, lat, extra = {}) => ({ userId, name: userId, lat, lng: 78.4, lastSeenEpochMs: T0, ...extra });

test('separation: a pair two-up that drops back raises one alert (the rider), never one for the pillion', async () => {
  const eng = fakeEngine();
  const st = st0();
  // Front pack of two bikes at 17.0; the pair (rider R + pillion P) 5 km back.
  const room = {
    meta: { distanceThresholdMeters: 1000 },
    riders: new Map([
      ['A', at('A', 17.0)], ['B', at('B', 17.0005)], ['C', at('C', 17.001)],
      ['R', at('R', 16.955)], ['P', at('P', 16.955, { isCoRiding: true, ridingWithUserId: 'R' })],
    ]),
  };
  await TimelineEngine.prototype._checkSeparation.call(eng, 'G', st, room, T0);
  await TimelineEngine.prototype._checkSeparation.call(eng, 'G', st, room, T0 + 61000);
  assert.deepEqual(eng.opened, ['SEPARATED:R']);
  // A pillion's entry opened before the seat (older app, no link) is closed once seated.
  st.open.set('SEPARATED:P', { data: {} });
  await TimelineEngine.prototype._checkSeparation.call(eng, 'G', st, room, T0 + 62000);
  assert.ok(eng.closed.includes('SEPARATED:P'));
  // Two people on one bike are never "separated" from each other.
  const eng2 = fakeEngine();
  const st2 = st0();
  const pair = { meta: { distanceThresholdMeters: 1000 }, riders: new Map([['R', at('R', 17)], ['P', at('P', 17.02, { isCoRiding: true, ridingWithUserId: 'R' })]]) };
  await TimelineEngine.prototype._checkSeparation.call(eng2, 'G', st2, pair, T0);
  await TimelineEngine.prototype._checkSeparation.call(eng2, 'G', st2, pair, T0 + 61000);
  assert.deepEqual(eng2.opened, []);
});

test('behind the sweeper: one alert per bike', async () => {
  const eng = fakeEngine();
  const st = st0();
  // Destination north; the sweeper at 17.0, the pair 2 km further back.
  const room = {
    meta: { destinationLat: 17.5, destinationLng: 78.4 },
    riders: new Map([
      ['S', at('S', 17.0, { role: 'SWEEPER' })],
      ['R', at('R', 16.98)], ['P', at('P', 16.98, { isCoRiding: true, ridingWithUserId: 'R' })],
    ]),
  };
  await TimelineEngine.prototype._checkSweeper.call(eng, 'G', st, room, T0);
  await TimelineEngine.prototype._checkSweeper.call(eng, 'G', st, room, T0 + 61000);
  assert.deepEqual(eng.opened, ['BEHIND:R']);
});

test('pillion pair, missing-rider check: one bike, one answer; one "no answer" per bike; an OK closes the partner too', async () => {
  const R = await ride();
  const [asha, kiran, arjun] = R.members;
  // Kiran rides pillion on Asha's bike.
  const seat = await gw.convoys.seatPillion(R.gid, { userId: uid(kiran), name: 'Kiran' }, uid(asha));
  assert.ok(seat);
  assert.equal(rec(R, kiran).ridingWithUserId, uid(asha));
  const user = (u) => ({ userId: uid(u), role: 'RIDER', name: u.user.name });
  const open = async () => { const st = await gw.timeline._state(R.gid); return [...st.open.keys()].filter((k) => k.startsWith('NO_REPLY:')); };

  // Both phones time out: only the first "no answer" goes to the lead.
  assert.deepEqual(await gw.timeline.checkIn(R.gid, user(asha), { result: 'NO_REPLY', context: 'MISSING_RIDER', awayM: 1500 }), { opened: true });
  const second = await gw.timeline.checkIn(R.gid, user(kiran), { result: 'NO_REPLY', context: 'MISSING_RIDER', awayM: 1500 });
  assert.equal(second.opened, false);
  assert.equal(second.sameBike, uid(asha));
  assert.deepEqual(await open(), [`NO_REPLY:${uid(asha)}`]);

  // The pillion answers I'm OK on their phone: the rider's entry closes too (one answer for the bike).
  const ok = await gw.timeline.checkIn(R.gid, user(kiran), { result: 'OK' });
  assert.equal(ok.closed, 1);
  assert.deepEqual(await open(), []);
  const evs = await gw.repo.listEvents(R.gid, { limit: 500 });
  const closed = evs.find((e) => e.type === 'NO_REPLY' && e.userId === uid(asha));
  assert.equal(closed.open, false);
  assert.equal(closed.data.answeredBy, 'BIKE_PARTNER');

  // The rider answered this stop (status "I'm OK"): the pillion's late "no answer" is dropped.
  const a = rec(R, asha);
  a.statusReason = 'CUSTOM'; a.statusMessage = "I'm OK"; a.stoppedSince = Date.now();
  const late = await gw.timeline.checkIn(R.gid, user(kiran), { result: 'NO_REPLY', context: 'MISSING_RIDER' });
  assert.equal(late.opened, false);
  assert.equal(late.answeredOnBike, uid(asha));
  assert.deepEqual(await open(), []);
  // An old answer (an earlier stop) does not count.
  a.stoppedSince = Date.now() - 60 * 60000;
  assert.equal((await gw.timeline.checkIn(R.gid, user(kiran), { result: 'NO_REPLY', context: 'MISSING_RIDER' })).opened, true);
  await gw.timeline.checkIn(R.gid, user(kiran), { result: 'OK' });

  // A rider riding alone is never affected; a plain solo check-in NO_REPLY is not deduped.
  assert.equal((await gw.timeline.checkIn(R.gid, user(arjun), { result: 'NO_REPLY', context: 'MISSING_RIDER' })).opened, true);
  assert.equal((await gw.timeline.checkIn(R.gid, user(asha), { result: 'NO_REPLY' })).opened, true);
  assert.equal((await gw.timeline.checkIn(R.gid, user(kiran), { result: 'NO_REPLY' })).opened, true);
  await end(R);
});
