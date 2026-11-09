'use strict';
/**
 * 3.55 bike / pillion swap: a rider asks another rider of the group ride to swap bikes (BIKES), or
 * a rider and their pillion change places (PILLION). Only the asked rider answers, within 2
 * minutes; the change applies to this ride's rider records (never the profile), goes out as
 * RIDER_UPDATE + SWAP_DONE, and the timeline gets VEHICLE_SWAP.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

const T0 = Date.UTC(2026, 10, 7, 6, 0, 0);
let t, gw, now = T0;
before(async () => { mock.timers.enable({ apis: ['Date'], now: T0 }); t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); mock.timers.reset(); });
const advance = (ms) => { now += ms; mock.timers.setTime(now); };

let n = 0;
async function ride() {
  n++;
  const lead = await t.register(`Owner ${n}`, `swapowner${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Swap ${n}` }, lead.token)).json;
  const members = [];
  for (const tag of ['Ravi', 'Kiran', 'Arjun']) {
    n++;
    const u = await t.register(`${tag} ${n}`, `swap${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  return { lead, c, gid: c.groupId, room: gw.convoys.rooms.get(c.groupId), members };
}
const uid = (u) => u.user.userId;
const rider = (R, u) => R.room.riders.get(uid(u));
const end = (R) => t.api('POST', `/convoys/${R.gid}/status`, { status: 'ENDED' }, R.lead.token);

test('bikes swap: the asked rider gets SWAP_ASK; on accept both rider records swap, SWAP_DONE and the timeline follow', async () => {
  const R = await ride();
  const [ravi, kiran] = R.members;
  const bikeRavi = rider(R, ravi).vehicleNo, bikeKiran = rider(R, kiran).vehicleNo;
  assert.ok(bikeRavi && bikeKiran && bikeRavi !== bikeKiran);
  const wr = await t.joinRoom(ravi.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  const wl = await t.joinRoom(R.lead.token, R.gid);

  wr.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'BIKES', clientId: 's1' });
  await wr.next((m) => m.type === 'ACK' && m.clientId === 's1');
  const ask = await wk.next((m) => m.type === 'SWAP_ASK');
  assert.equal(ask.fromUserId, uid(ravi));
  assert.equal(ask.kind, 'BIKES');
  assert.equal(ask.groupId, R.gid);
  assert.match(ask.requestId, /^SWP-[0-9A-F]{12}$/);
  assert.ok(!wl.inbox.some((m) => m.type === 'SWAP_ASK'), 'only the asked rider hears the ask');

  // A second ask for the same pair while one waits is refused.
  wk.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(ravi), kind: 'BIKES', clientId: 's2' });
  assert.equal((await wk.next((m) => m.type === 'ERROR' && m.clientId === 's2')).reason, 'SWAP_PENDING');

  wk.sendJson({ type: 'SWAP_ANSWER', requestId: ask.requestId, accept: true, clientId: 's3' });
  const done = await wl.next((m) => m.type === 'SWAP_DONE');
  assert.equal(done.kind, 'BIKES');
  assert.deepEqual([done.a.userId, done.b.userId], [uid(ravi), uid(kiran)]);
  assert.equal(done.a.vehicleNo, bikeKiran);
  assert.equal(rider(R, ravi).vehicleNo, bikeKiran);
  assert.equal(rider(R, kiran).vehicleNo, bikeRavi);
  const upd = await wl.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(ravi) && m.rider.vehicleNo === bikeKiran);
  assert.equal(upd.rider.rideVehicle, undefined, 'server-only field never leaves the gateway');
  // The account profile is unchanged.
  const prof = await gw.repo.findUserById(uid(ravi));
  assert.equal(prof.vehicleNo, bikeRavi);

  // A re-join (app restart) keeps the swapped bike for this ride.
  assert.equal((await t.api('POST', '/convoys/join', { code: R.c.joinCode }, ravi.token)).status, 200);
  assert.equal(rider(R, ravi).vehicleNo, bikeKiran);

  await gw.timeline.idle();
  const events = await gw.repo.listEvents(R.gid, { limit: 500 });
  const sw = events.find((e) => e.type === 'VEHICLE_SWAP');
  assert.ok(sw, 'timeline entry');
  assert.equal(sw.userId, uid(ravi));
  assert.equal(sw.data.withUserId, uid(kiran));
  assert.equal(sw.data.kind, 'BIKES');

  // Answering again: the request is gone.
  wk.sendJson({ type: 'SWAP_ANSWER', requestId: ask.requestId, accept: true, clientId: 's4' });
  assert.equal((await wk.next((m) => m.type === 'ERROR' && m.clientId === 's4')).reason, 'SWAP_EXPIRED');
  for (const w of [wr, wk, wl]) w.close();
  await end(R);
});

test('decline tells the requester; nothing changes', async () => {
  const R = await ride();
  const [ravi, kiran] = R.members;
  const before = [rider(R, ravi).vehicleNo, rider(R, kiran).vehicleNo];
  const wr = await t.joinRoom(ravi.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  wr.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'BIKES', clientId: 'd1' });
  const ask = await wk.next((m) => m.type === 'SWAP_ASK');
  wk.sendJson({ type: 'SWAP_ANSWER', requestId: ask.requestId, accept: false, clientId: 'd2' });
  const res = await wr.next((m) => m.type === 'SWAP_RESULT');
  assert.equal(res.requestId, ask.requestId);
  assert.equal(res.accepted, false);
  assert.deepEqual([rider(R, ravi).vehicleNo, rider(R, kiran).vehicleNo], before);

  // Asks are rate limited per rider: four per 10 minutes (one used above).
  let limited = 0;
  for (let i = 0; i < 4; i++) {
    advance(1100); // the per-second action budget is not what this checks
    wr.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'BIKES', clientId: `r${i}` });
    const m = await wr.next((x) => (x.type === 'ACK' || x.type === 'ERROR') && x.clientId === `r${i}`);
    if (m.type === 'ERROR') { assert.equal(m.reason, 'SWAP_RATE'); limited++; continue; }
    const a = await wk.next((x) => x.type === 'SWAP_ASK');
    wk.sendJson({ type: 'SWAP_ANSWER', requestId: a.requestId, accept: false, clientId: `ra${i}` });
    await wr.next((x) => x.type === 'SWAP_RESULT' && x.requestId === a.requestId);
  }
  assert.equal(limited, 1, 'the fifth ask within 10 minutes is refused');
  for (const w of [wr, wk]) w.close();
  await end(R);
});

test('an unanswered ask expires after 2 minutes: the requester hears it, a late answer is refused', async () => {
  const R = await ride();
  const [ravi, kiran] = R.members;
  const wr = await t.joinRoom(ravi.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  wr.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'BIKES', clientId: 'e1' });
  const ask = await wk.next((m) => m.type === 'SWAP_ASK');
  advance(2 * 60000 + 1000);
  wk.sendJson({ type: 'SWAP_ANSWER', requestId: ask.requestId, accept: true, clientId: 'e2' });
  assert.equal((await wk.next((m) => m.type === 'ERROR' && m.clientId === 'e2')).reason, 'SWAP_EXPIRED');
  const res = await wr.next((m) => m.type === 'SWAP_RESULT');
  assert.equal(res.accepted, false);
  assert.equal(res.expired, true);
  for (const w of [wr, wk]) w.close();
  await end(R);
});

test('only the asked rider can answer; bad input and self swaps are refused', async () => {
  const R = await ride();
  const [ravi, kiran, arjun] = R.members;
  const wr = await t.joinRoom(ravi.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  const wa = await t.joinRoom(arjun.token, R.gid);
  wr.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'BIKES', clientId: 'n1' });
  const ask = await wk.next((m) => m.type === 'SWAP_ASK');
  for (const w of [wa, wr]) {
    w.sendJson({ type: 'SWAP_ANSWER', requestId: ask.requestId, accept: true, clientId: 'n2' });
    assert.equal((await w.next((m) => m.type === 'ERROR' && m.clientId === 'n2')).reason, 'NOT_SWAP_TARGET');
  }
  wa.sendJson({ type: 'SWAP_ANSWER', requestId: 'nope', accept: true, clientId: 'n3' });
  assert.equal((await wa.next((m) => m.type === 'ERROR' && m.clientId === 'n3')).reason, 'SWAP_EXPIRED');
  wa.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(arjun), kind: 'BIKES', clientId: 'n4' });
  assert.equal((await wa.next((m) => m.type === 'ERROR' && m.clientId === 'n4')).reason, 'BAD_SWAP');
  wa.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'CARS', clientId: 'n5' });
  assert.equal((await wa.next((m) => m.type === 'ERROR' && m.clientId === 'n5')).reason, 'BAD_SWAP');
  wa.sendJson({ type: 'SWAP_REQUEST', withUserId: { $ne: 1 }, kind: 'BIKES', clientId: 'n6' });
  assert.equal((await wa.next((m) => m.type === 'ERROR' && m.clientId === 'n6')).reason, 'NOT_MEMBER');
  // PILLION needs the two to ride together.
  wa.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'PILLION', clientId: 'n7' });
  assert.equal((await wa.next((m) => m.type === 'ERROR' && m.clientId === 'n7')).reason, 'NOT_PAIRED');
  // Still pending and still Kiran's to answer.
  assert.equal(R.room.swaps.size, 1);
  for (const w of [wr, wk, wa]) w.close();
  await end(R);
});

test('a rider outside the ride is refused (another ride, or not joined)', async () => {
  const R = await ride();
  const R2 = await ride();
  const [ravi] = R.members;
  const [other] = R2.members;
  const wr = await t.joinRoom(ravi.token, R.gid);
  wr.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(other), kind: 'BIKES', clientId: 'o1' });
  assert.equal((await wr.next((m) => m.type === 'ERROR' && m.clientId === 'o1')).reason, 'NOT_MEMBER');
  // A socket not bound to a ride cannot ask at all.
  const loose = await t.connect(other.token);
  loose.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(ravi), kind: 'BIKES', clientId: 'o2' });
  assert.equal((await loose.next((m) => m.type === 'ERROR' && m.clientId === 'o2')).reason, 'NOT_JOINED');
  for (const w of [wr, loose]) w.close();
  await end(R); await end(R2);
});

test('rider and pillion change places: the pillion takes the bike and rides, the former rider rides pillion', async () => {
  const R = await ride();
  const [ravi, kiran, arjun] = R.members;
  const wr = await t.joinRoom(ravi.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  // Kiran rides pillion with Ravi.
  wk.sendJson({ type: 'CORIDER', ridingWithUserId: uid(ravi) });
  await wr.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(kiran) && m.rider.isCoRiding);
  const bike = rider(R, ravi).vehicleNo;

  // A pillion has no bike to swap.
  wk.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(arjun), kind: 'BIKES', clientId: 'p0' });
  assert.equal((await wk.next((m) => m.type === 'ERROR' && m.clientId === 'p0')).reason, 'PILLION_RIDER');

  wk.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(ravi), kind: 'PILLION', clientId: 'p1' });
  const ask = await wr.next((m) => m.type === 'SWAP_ASK');
  assert.equal(ask.kind, 'PILLION');
  wr.sendJson({ type: 'SWAP_ANSWER', requestId: ask.requestId, accept: true, clientId: 'p2' });
  const done = await wk.next((m) => m.type === 'SWAP_DONE');
  assert.equal(done.kind, 'PILLION');
  const k = rider(R, kiran), r = rider(R, ravi);
  assert.equal(k.vehicleNo, bike, 'the former pillion rides the bike');
  assert.equal(k.isCoRiding, false);
  assert.equal(k.ridingWithUserId, '');
  assert.equal(r.vehicleNo, 'PILLION');
  assert.equal(r.vehicleType, 'Pillion Rider');
  assert.equal(r.isCoRiding, true);
  assert.equal(r.ridingWithUserId, uid(kiran));
  await gw.timeline.idle();
  const events = await gw.repo.listEvents(R.gid, { limit: 500 });
  assert.ok(events.some((e) => e.type === 'VEHICLE_SWAP' && e.data.kind === 'PILLION'));
  const coride = events.filter((e) => e.type === 'CORIDE');
  assert.ok(coride.some((e) => e.userId === uid(ravi) && e.data.withUserId === uid(kiran)), 'Ravi now rides pillion with Kiran');
  for (const w of [wr, wk]) w.close();
  await end(R);
});

test('a pending ask survives a restart: stored with the convoy meta, reloaded, still answerable; then it expires and is gone', async () => {
  advance(16 * 60000); // past the sign-up limiter window of the earlier tests
  const R = await ride();
  const [ravi, kiran, arjun] = R.members;
  const bikeKiran = rider(R, kiran).vehicleNo;
  const wr = await t.joinRoom(ravi.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  wr.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'BIKES', clientId: 'p1' });
  const ask = await wk.next((m) => m.type === 'SWAP_ASK');
  // Stored (server only): in the DB meta, never in a snapshot.
  const stored = await gw.repo.getConvoyMeta(R.gid);
  assert.equal(stored.pendingSwaps[ask.requestId].toUserId, uid(kiran));
  assert.equal(stored.pendingSwaps[ask.requestId].timer, undefined, 'no timer object in the stored copy');
  assert.equal(JSON.stringify(gw.convoys.snapshot(R.room)).includes(ask.requestId), false);

  // The gateway restarts: the room is loaded again from the database.
  for (const x of R.room.swaps.values()) clearTimeout(x.timer);
  gw.convoys.rooms.delete(R.gid);
  const room2 = await gw.convoys.getRoom(R.gid);
  assert.notEqual(room2, R.room);
  assert.ok(room2.swaps.has(ask.requestId), 'the ask is back');
  const res = await gw.convoys.answerSwap(R.gid, { userId: uid(kiran), name: 'Kiran' }, ask.requestId, true);
  assert.equal(res.accepted, true);
  assert.equal(room2.riders.get(uid(ravi)).vehicleNo, bikeKiran);
  assert.equal((await gw.repo.getConvoyMeta(R.gid)).pendingSwaps, undefined, 'answered: removed from the meta');

  // A second ask, restart, and the 2 minutes pass: the requester hears it expired, the meta is cleaned.
  const ask2 = await gw.convoys.requestSwap(R.gid, { userId: uid(ravi), name: 'Ravi' }, uid(arjun), 'BIKES');
  for (const x of room2.swaps.values()) clearTimeout(x.timer);
  gw.convoys.rooms.delete(R.gid);
  advance(2 * 60000 + 1000);
  const wr2 = await t.joinRoom(ravi.token, R.gid); // loads the room again
  const room3 = gw.convoys.rooms.get(R.gid);
  await assert.rejects(gw.convoys.answerSwap(R.gid, { userId: uid(arjun) }, ask2.requestId, true), (e) => e.reason === 'SWAP_EXPIRED');
  assert.equal(room3.swaps.size, 0);
  await sleep(20);
  assert.equal((await gw.repo.getConvoyMeta(R.gid)).pendingSwaps, undefined);
  for (const w of [wr, wk, wr2]) w.close();
  await end(R);
  assert.equal((await gw.repo.getConvoyMeta(R.gid)).pendingSwaps, undefined, 'nothing pending after the ride');
});
