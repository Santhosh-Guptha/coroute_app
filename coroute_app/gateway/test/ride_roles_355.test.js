'use strict';
/**
 * 3.55 riding roles: LEAD (front) / PACK (middle) / SWEEPER (back). The lead hands the front to
 * another rider (a swap), two riders swap roles, ROLE_CHANGE tells the riders concerned to change
 * position, and automatic roles (off by default) follow the ride's order along the route.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

const T0 = Date.UTC(2026, 10, 7, 5, 0, 0);
let t, gw, now = T0;
before(async () => { mock.timers.enable({ apis: ['Date'], now: T0 }); t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); mock.timers.reset(); });
const advance = (ms) => { now += ms; mock.timers.setTime(now); };

let n = 0;
async function ride(body = {}) {
  n++;
  const lead = await t.register(`Owner ${n}`, `roleowner${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Roles ${n}`, ...body }, lead.token)).json;
  const members = [];
  for (const tag of ['Asha', 'Kiran', 'Arjun']) {
    n++;
    const u = await t.register(`${tag} ${n}`, `role${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  return { lead, c, gid: c.groupId, room: gw.convoys.rooms.get(c.groupId), members };
}
const uid = (u) => u.user.userId;
const role = (R, u) => R.room.riders.get(uid(u)).role;
async function fix(room, u, lat, lng, speedKmh = 50) {
  gw.convoys.patchRider(room, uid(u), { lat, lng, speedKmh }, { emit: false });
  await gw.timeline.idle();
}

test('HELLO advertises ride355; the lead hands the front to a rider and they swap; ROLE_CHANGE lists both', async () => {
  const R = await ride();
  const [asha, kiran] = R.members;
  const wl = await t.joinRoom(R.lead.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  assert.equal(R.room.meta.autoRoles, undefined, 'automatic roles are off by default');

  // Asha sweeps, then Kiran takes the lead: the owner moves to the middle and keeps the owner's rights.
  wl.sendJson({ type: 'ROLE_SET', userId: uid(asha), role: 'SWEEPER', clientId: 'x1' });
  await wl.next((m) => m.type === 'ACK' && m.clientId === 'x1');
  wl.sendJson({ type: 'ROLE_SET', userId: uid(kiran), role: 'LEAD', clientId: 'x2' });
  const change = await wk.next((m) => m.type === 'ROLE_CHANGE' && m.changes.some((c) => c.userId === uid(kiran)));
  assert.deepEqual(change.changes.map((c) => [c.userId, c.from, c.to]).sort(), [[uid(R.lead), 'LEAD', 'PACK'], [uid(kiran), 'PACK', 'LEAD']].sort());
  assert.equal(change.auto, false);
  assert.equal(role(R, kiran), 'LEAD');
  assert.equal(role(R, R.lead), 'PACK');
  assert.equal(gw.convoys.isLead(R.room, { userId: uid(R.lead), role: 'RIDER' }), true, 'the owner keeps the owner rights');

  // The lead and the sweeper swap places in one step.
  wl.sendJson({ type: 'ROLE_SWAP', userId: uid(kiran), withUserId: uid(asha), clientId: 'x3' });
  await wl.next((m) => m.type === 'ACK' && m.clientId === 'x3');
  assert.equal(role(R, kiran), 'SWEEPER');
  assert.equal(role(R, asha), 'LEAD');

  // Making the sweeping rider the lead swaps with the current lead (Asha goes to the back).
  wl.sendJson({ type: 'ROLE_SET', userId: uid(kiran), role: 'LEAD', clientId: 'x4' });
  await wl.next((m) => m.type === 'ACK' && m.clientId === 'x4');
  assert.equal(role(R, kiran), 'LEAD');
  assert.equal(role(R, asha), 'SWEEPER');
  assert.equal([...R.room.riders.values()].filter((r) => r.role === 'LEAD').length, 1, 'always one lead');

  // A pack rider cannot change roles.
  const [, , arjun] = R.members;
  const wa = await t.joinRoom(arjun.token, R.gid);
  wa.sendJson({ type: 'ROLE_SWAP', userId: uid(kiran), withUserId: uid(arjun), clientId: 'x5' });
  assert.equal((await wa.next((m) => m.type === 'ERROR' && m.clientId === 'x5')).code, 403);
  for (const w of [wl, wk, wa]) w.close();
  await t.api('POST', `/convoys/${R.gid}/status`, { status: 'ENDED' }, R.lead.token);
});

test('automatic roles: off by default; when on, the front rider leads and the last one sweeps after the hold', async () => {
  const R = await ride({ start: { lat: 17.0, lng: 78.0, name: 'Start' }, destination: 'End', destLat: 17.3, destLng: 78.0 });
  assert.ok(R.room.meta.route && R.room.meta.route.polyline, 'a straight route exists');
  const [asha, kiran, arjun] = R.members;
  const place = async () => {
    advance(10000);
    await fix(R.room, kiran, 17.150, 78.0); // front
    await fix(R.room, R.lead, 17.120, 78.0);
    await fix(R.room, asha, 17.110, 78.0);
    await fix(R.room, arjun, 17.090, 78.0); // back
  };
  for (let i = 0; i < 8; i++) await place();
  assert.equal(role(R, kiran), 'PACK', 'nothing changes while automatic roles are off');

  const wl = await t.joinRoom(R.lead.token, R.gid);
  wl.sendJson({ type: 'ROLE_AUTO', on: true, clientId: 'a1' });
  const on = await wl.next((m) => m.type === 'AUTO_ROLES');
  assert.equal(on.autoRoles, true);
  assert.equal(R.room.meta.autoRoles, true);
  // The order must hold for 45 s before roles move.
  await place();
  assert.equal(role(R, kiran), 'PACK', 'held first');
  for (let i = 0; i < 6; i++) await place();
  assert.equal(role(R, kiran), 'LEAD');
  assert.equal(role(R, arjun), 'SWEEPER');
  assert.equal(role(R, R.lead), 'PACK');
  // An automatic (front-rider) lead gets no lead rights; the owner keeps them.
  assert.equal(gw.convoys.isLead(R.room, { userId: uid(kiran), role: 'RIDER' }), false);
  assert.equal(gw.convoys.isLead(R.room, { userId: uid(R.lead), role: 'RIDER' }), true);
  const snap = gw.convoys.snapshot(R.room);
  assert.equal(snap.autoRoles, true);

  // Riding close behind the lead (under 150 m) never takes the lead.
  for (let i = 0; i < 20; i++) {
    advance(10000);
    await fix(R.room, kiran, 17.200, 78.0);
    await fix(R.room, R.lead, 17.2008, 78.0); // ~90 m ahead of Kiran
    await fix(R.room, asha, 17.19, 78.0);
    await fix(R.room, arjun, 17.18, 78.0);
  }
  assert.equal(role(R, kiran), 'LEAD', 'a tight pack does not flicker');

  wl.sendJson({ type: 'ROLE_AUTO', on: false, clientId: 'a2' });
  assert.equal((await wl.next((m) => m.type === 'AUTO_ROLES' && m.autoRoles === false)).autoRoles, false);
  wl.close();
  await t.api('POST', `/convoys/${R.gid}/status`, { status: 'ENDED' }, R.lead.token);
});
