'use strict';
/**
 * 3.16 sweeper role: ROLE_SET (lead only, one sweeper per room, RIDER_UPDATE + ROLE_CHANGED, restored after a
 * reload) and the BEHIND_SWEEPER rule (a rider behind the sweeper on the route for 60 s).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

const T0 = Date.UTC(2026, 9, 9, 5, 0, 0);
let t, gw, now = T0;
before(async () => { mock.timers.enable({ apis: ['Date'], now: T0 }); t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); mock.timers.reset(); });
const advance = (ms) => { now += ms; mock.timers.setTime(now); };

let n = 0;
async function ride(body = {}) {
  n++;
  const lead = await t.register(`Lead ${n}`, `sweeplead${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Sweep ${n}`, ...body }, lead.token)).json;
  const members = [];
  for (const tag of ['Sweeper', 'Kiran', 'Arjun']) {
    n++;
    const u = await t.register(`${tag} ${n}`, `sweep${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30); // the (straight-line) route is computed in the background
  const room = gw.convoys.rooms.get(c.groupId);
  return { lead, c, gid: c.groupId, room, members };
}
const uid = (u) => u.user.userId;
const events = async (gid, type) => (await gw.repo.listEvents(gid, { limit: 1000 })).filter((e) => e.type === type);
async function fix(room, u, lat, lng, speedKmh = 50) {
  gw.convoys.patchRider(room, uid(u), { lat, lng, speedKmh }, { emit: false });
  await gw.timeline.idle();
}

test('ROLE_SET: lead only, not the lead, unknown rider, SWEEPER then PACK, one sweeper per room, ACK, RIDER_UPDATE, ROLE_CHANGED, reload', async () => {
  const R = await ride();
  const [s1, s2, pack] = R.members;
  const wl = await t.joinRoom(R.lead.token, R.gid);
  const wp = await t.joinRoom(pack.token, R.gid);
  const frames = [];
  wp.on('message', (d, bin) => { if (!bin) frames.push(JSON.parse(d.toString())); });
  // A pack rider may not set roles.
  wp.sendJson({ type: 'ROLE_SET', userId: uid(s1), role: 'SWEEPER', clientId: 'r-pack' });
  const err = await wp.next((m) => m.type === 'ERROR');
  assert.equal(err.code, 403);
  assert.equal(err.clientId, 'r-pack');
  // The lead cannot be made sweeper; unknown riders are 404; bad roles 400.
  wl.sendJson({ type: 'ROLE_SET', userId: uid(R.lead), role: 'SWEEPER', clientId: 'r-lead' });
  assert.equal((await wl.next((m) => m.type === 'ERROR' && m.clientId === 'r-lead')).reason, 'NOT_ALLOWED');
  wl.sendJson({ type: 'ROLE_SET', userId: 'nobody', role: 'SWEEPER', clientId: 'r-none' });
  assert.equal((await wl.next((m) => m.type === 'ERROR' && m.clientId === 'r-none')).code, 404);
  wl.sendJson({ type: 'ROLE_SET', userId: uid(s1), role: 'LEAD', clientId: 'r-bad' });
  assert.equal((await wl.next((m) => m.type === 'ERROR' && m.clientId === 'r-bad')).reason, 'BAD_ROLE');
  // Make s1 the sweeper: ACK, RIDER_UPDATE for everyone, ROLE_CHANGED on the timeline.
  wl.sendJson({ type: 'ROLE_SET', userId: uid(s1), role: 'SWEEPER', clientId: 'r-1' });
  const ack = await wl.next((m) => m.type === 'ACK' && m.clientId === 'r-1');
  assert.equal(ack.duplicate, false);
  const up = await wp.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(s1));
  assert.equal(up.rider.role, 'SWEEPER');
  assert.equal(R.room.riders.get(uid(s1)).role, 'SWEEPER');
  assert.equal(R.room.meta.members[uid(s1)].role, 'SWEEPER');
  await gw.timeline.idle();
  let changed = await events(R.gid, 'ROLE_CHANGED');
  assert.equal(changed.length, 1);
  assert.equal(changed[0].userId, uid(s1));
  assert.deepEqual(changed[0].data, { role: 'SWEEPER', byUserId: uid(R.lead) });
  // The same clientId again is a duplicate, applied once.
  wl.sendJson({ type: 'ROLE_SET', userId: uid(s1), role: 'SWEEPER', clientId: 'r-1' });
  assert.equal((await wl.next((m) => m.type === 'ACK' && m.clientId === 'r-1')).duplicate, true);
  // s2 replaces s1: both riders are updated.
  frames.length = 0;
  wl.sendJson({ type: 'ROLE_SET', userId: uid(s2), role: 'SWEEPER', clientId: 'r-2' });
  await wl.next((m) => m.type === 'ACK' && m.clientId === 'r-2');
  await sleep(30);
  const ups = frames.filter((f) => f.type === 'RIDER_UPDATE');
  assert.equal(ups.find((f) => f.rider.userId === uid(s1))?.rider.role, 'PACK');
  assert.equal(ups.find((f) => f.rider.userId === uid(s2))?.rider.role, 'SWEEPER');
  assert.equal([...R.room.riders.values()].filter((r) => r.role === 'SWEEPER').length, 1);
  // Back to PACK.
  wl.sendJson({ type: 'ROLE_SET', userId: uid(s2), role: 'PACK', clientId: 'r-3' });
  await wl.next((m) => m.type === 'ACK' && m.clientId === 'r-3');
  assert.equal(R.room.riders.get(uid(s2)).role, 'PACK');
  await gw.timeline.idle();
  changed = await events(R.gid, 'ROLE_CHANGED');
  assert.equal(changed.length, 3);
  assert.equal(changed[2].data.role, 'PACK');
  // Restored after a reload (rider record and member record).
  wl.sendJson({ type: 'ROLE_SET', userId: uid(s1), role: 'SWEEPER', clientId: 'r-4' });
  await wl.next((m) => m.type === 'ACK' && m.clientId === 'r-4');
  await gw.convoys.flushRoom(R.room);
  gw.convoys.rooms.delete(R.gid);
  const again = await gw.convoys.getRoom(R.gid);
  assert.equal(again.riders.get(uid(s1)).role, 'SWEEPER');
  assert.equal(again.meta.members[uid(s1)].role, 'SWEEPER');
  assert.equal(again.riders.get(uid(s2)).role, 'PACK');
  // Roster rank and incident notify include the sweeper.
  const roster = (await t.api('GET', `/convoys/${R.gid}/emergency-roster`, undefined, pack.token)).json;
  assert.deepEqual(roster.members.map((m) => m.role), ['LEAD', 'SWEEPER', 'PACK']);
  assert.equal(roster.members[1].userId, uid(s1));
  const notify = gw.timeline._incidentNotify(again, uid(pack), { lat: 17, lng: 78 }, Date.now());
  assert.ok(notify.includes(uid(R.lead)) && notify.includes(uid(s1)));
  wl.close(); wp.close();
  await t.api('POST', `/convoys/${R.gid}/status`, { status: 'ENDED' }, R.lead.token);
});

test('BEHIND_SWEEPER: 500 m behind on the route for 60 s opens; passing the sweeper closes; removing the sweeper closes all', async () => {
  const R = await ride({ start: { lat: 17.0, lng: 78.0, name: 'Start' }, destination: 'End', destLat: 17.2, destLng: 78.0 });
  assert.ok(R.room.meta.route && R.room.meta.route.polyline, 'a straight route exists');
  const [sw, kiran, arjun] = R.members;
  await gw.convoys.setRole(R.gid, { userId: uid(R.lead), name: 'Lead', role: 'RIDER' }, uid(sw), 'SWEEPER');
  const behind = async () => events(R.gid, 'BEHIND_SWEEPER');
  // Sweeper at 17.100 (11.1 km along), Kiran 555 m behind, Arjun 200 m behind, the lead ahead. Fixes every 10 s.
  for (let i = 0; i < 5; i++) {
    advance(10000);
    await fix(R.room, R.lead, 17.12, 78.0);
    await fix(R.room, sw, 17.100, 78.0);
    await fix(R.room, kiran, 17.095, 78.0);
    await fix(R.room, arjun, 17.0982, 78.0);
  }
  assert.equal((await behind()).length, 0, 'held for 60 s first');
  for (let i = 0; i < 3; i++) {
    advance(10000);
    await fix(R.room, R.lead, 17.12, 78.0);
    await fix(R.room, sw, 17.100, 78.0);
    await fix(R.room, kiran, 17.095, 78.0);
    await fix(R.room, arjun, 17.0982, 78.0);
  }
  let list = await behind();
  assert.equal(list.length, 1, 'Kiran only (Arjun is 200 m behind, within the limit)');
  assert.equal(list[0].userId, uid(kiran));
  assert.equal(list[0].open, true);
  assert.ok(list[0].data.distanceM >= 500 && list[0].data.distanceM <= 600, `distance ${list[0].data.distanceM}`);
  assert.equal(list[0].data.sweeperId, uid(sw));
  assert.equal(list[0].data.sweeperName, R.room.riders.get(uid(sw)).name);
  assert.deepEqual(list[0].data.notify, [uid(sw), uid(R.lead)]);
  // Falls further behind: maxDistanceM grows; then passes the sweeper: closed.
  advance(10000); await fix(R.room, kiran, 17.090, 78.0); await fix(R.room, sw, 17.100, 78.0);
  for (let i = 0; i < 2; i++) { advance(10000); await fix(R.room, kiran, 17.101, 78.0); await fix(R.room, sw, 17.100, 78.0); }
  list = await behind();
  assert.equal(list[0].open, false);
  assert.ok(list[0].data.maxDistanceM >= 1000, `max ${list[0].data.maxDistanceM}`);
  // Behind again, then the sweeper is removed: everything closes at once and nothing reopens.
  for (let i = 0; i < 8; i++) { advance(10000); await fix(R.room, sw, 17.100, 78.0); await fix(R.room, kiran, 17.094, 78.0); }
  list = await behind();
  assert.equal(list.length, 2);
  assert.equal(list[1].open, true);
  await gw.convoys.setRole(R.gid, { userId: uid(R.lead), name: 'Lead', role: 'RIDER' }, uid(sw), 'PACK');
  for (let i = 0; i < 8; i++) { advance(10000); await fix(R.room, sw, 17.100, 78.0); await fix(R.room, kiran, 17.094, 78.0); }
  list = await behind();
  assert.equal(list.length, 2);
  assert.equal(list[1].open, false);
  assert.equal(list[1].data.result, 'SWEEPER_CHANGED');
  await t.api('POST', `/convoys/${R.gid}/status`, { status: 'ENDED' }, R.lead.token);
});

test('BEHIND_SWEEPER: nothing without a route or a destination; by distance to the destination without a route', async () => {
  // No route, no destination: never.
  const A = await ride();
  const [swA, kA] = A.members;
  await gw.convoys.setRole(A.gid, { userId: uid(A.lead), name: 'Lead', role: 'RIDER' }, uid(swA), 'SWEEPER');
  for (let i = 0; i < 8; i++) { advance(10000); await fix(A.room, swA, 17.100, 78.0); await fix(A.room, kA, 17.090, 78.0); }
  assert.equal((await events(A.gid, 'BEHIND_SWEEPER')).length, 0);
  await t.api('POST', `/convoys/${A.gid}/status`, { status: 'ENDED' }, A.lead.token);
  // A destination but no route (no start): distance to the destination decides.
  const B = await ride({ destination: 'End', destLat: 17.2, destLng: 78.0 });
  B.room.meta.route = null;
  const [swB, kB] = B.members;
  await gw.convoys.setRole(B.gid, { userId: uid(B.lead), name: 'Lead', role: 'RIDER' }, uid(swB), 'SWEEPER');
  for (let i = 0; i < 8; i++) { advance(10000); await fix(B.room, swB, 17.100, 78.0); await fix(B.room, kB, 17.094, 78.0); }
  const list = await events(B.gid, 'BEHIND_SWEEPER');
  assert.equal(list.length, 1);
  assert.equal(list[0].userId, uid(kB));
  await t.api('POST', `/convoys/${B.gid}/status`, { status: 'ENDED' }, B.lead.token);
});
