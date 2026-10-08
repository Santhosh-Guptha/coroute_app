'use strict';
/**
 * 3.14 presence: "app closed" (BYE before the close) vs "no signal" (no BYE), and the
 * "Android closed the app" flag sent with the next JOIN. Also the HELLO feature list.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

async function ride(tag) {
  const lead = await t.register(`Pres Lead ${tag}`, `plead.${tag}@coroute.test`);
  const rider = await t.register(`Pres Rider ${tag}`, `prider.${tag}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Presence ${tag}` }, lead.token)).json;
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, rider.token)).status, 200);
  const room = await t.gw.convoys.getRoom(c.groupId);
  t.gw.convoys.patchRider(room, rider.user.userId, { lat: 17.3, lng: 78.4, speedKmh: 40 }, { emit: false });
  return { c, lead, rider, room };
}

const openOffline = async (gid, uid) => (await t.gw.repo.listOpenEvents(gid)).find((e) => e.type === 'OFFLINE' && e.userId === uid);

test('HELLO offers protocol 2 and the 3.14 features', async () => {
  const u = await t.register('Hello Rider', 'hello.pres@coroute.test');
  const ws = await t.connect(u.token);
  const hello = await ws.next((m) => m.type === 'HELLO');
  assert.equal(hello.protocol, 2);
  assert.deepEqual(hello.features, ['ack', 'sos2', 'respond', 'presence', 'checkin', 'roster']);
  assert.equal(hello.heartbeatSec, 30, 'old fields unchanged');
  ws.close();
});

test('BYE then close: PRESENCE APP_CLOSED and OFFLINE (cause APP_CLOSED) at once; JOIN brings ONLINE back', async () => {
  const r = await ride('bye');
  const wl = await t.joinRoom(r.lead.token, r.c.groupId);
  const wr = await t.joinRoom(r.rider.token, r.c.groupId);
  const on = await wl.next((m) => m.type === 'PRESENCE' && m.userId === r.rider.user.userId);
  assert.equal(on.presence, 'ONLINE');
  wr.sendJson({ type: 'BYE', reason: 'APP_CLOSED' });
  wr.sendJson({ type: 'BYE', reason: 'LEFT' }); // repeats are ignored
  await sleep(30);
  wr.close();
  const p = await wl.next((m) => m.type === 'PRESENCE' && m.userId === r.rider.user.userId);
  assert.equal(p.presence, 'APP_CLOSED');
  assert.ok(p.at > 0);
  await t.gw.timeline.idle();
  const off = await openOffline(r.c.groupId, r.rider.user.userId);
  assert.ok(off, 'OFFLINE opened without waiting 5 minutes');
  assert.equal(off.data.cause, 'APP_CLOSED');
  const snap = (await t.api('GET', `/convoys/${r.c.groupId}`, null, r.lead.token)).json;
  const rider = snap.riders[r.rider.user.userId];
  assert.equal(rider.presence, 'APP_CLOSED');
  assert.ok(rider.presenceAt > 0);
  assert.equal(rider.smsOptOut, undefined, 'the opt-out is never sent to others');

  const again = await t.joinRoom(r.rider.token, r.c.groupId);
  assert.equal((await wl.next((m) => m.type === 'PRESENCE' && m.userId === r.rider.user.userId)).presence, 'ONLINE');
  // Telemetry closes the OFFLINE entry as before.
  t.gw.convoys.patchRider(r.room, r.rider.user.userId, { lat: 17.31, lng: 78.4, speedKmh: 30 }, { emit: false });
  await t.gw.timeline.idle();
  assert.equal(await openOffline(r.c.groupId, r.rider.user.userId), undefined);
  again.close(); wl.close();
});

test('a socket that drops without BYE reads as NO_SIGNAL (no OFFLINE yet); a second socket keeps the rider ONLINE; LEFT changes nothing', async () => {
  const r = await ride('drop');
  const wl = await t.joinRoom(r.lead.token, r.c.groupId);
  const w1 = await t.joinRoom(r.rider.token, r.c.groupId);
  const w2 = await t.joinRoom(r.rider.token, r.c.groupId);
  await sleep(50);
  wl.inbox.length = 0;
  w1.sendJson({ type: 'BYE', reason: 'APP_CLOSED' });
  await sleep(30);
  w1.close();
  await sleep(100);
  assert.equal(wl.inbox.filter((m) => m.type === 'PRESENCE').length, 0, 'the other socket is still open');
  assert.equal(t.gw.convoys.rooms.get(r.c.groupId).riders.get(r.rider.user.userId).presence, 'ONLINE');

  w2.terminate(); // network drop / process killed: no BYE
  const p = await wl.next((m) => m.type === 'PRESENCE' && m.userId === r.rider.user.userId);
  assert.equal(p.presence, 'NO_SIGNAL');
  await t.gw.timeline.idle();
  assert.equal(await openOffline(r.c.groupId, r.rider.user.userId), undefined, 'the 5 minute rule still applies');

  const w3 = await t.joinRoom(r.rider.token, r.c.groupId);
  await wl.next((m) => m.type === 'PRESENCE' && m.presence === 'ONLINE');
  w3.sendJson({ type: 'BYE', reason: 'LEFT' });
  await sleep(30);
  w3.close();
  await sleep(100);
  assert.equal(wl.inbox.filter((m) => m.type === 'PRESENCE').length, 0, 'LEFT: the LEAVE path handles it');
  wl.close();
});

test('JOIN with prevExit KILLED marks the open OFFLINE entry; other values are ignored', async () => {
  const r = await ride('killed');
  // The rider went quiet more than 5 minutes ago: the tick opens OFFLINE (no signal).
  const rider = r.room.riders.get(r.rider.user.userId);
  r.room.riders.set(r.rider.user.userId, { ...rider, lastSeenEpochMs: Date.now() - 6 * 60000 });
  await t.gw.timeline.tick();
  await t.gw.timeline.idle();
  const off = await openOffline(r.c.groupId, r.rider.user.userId);
  assert.equal(off.data.cause, 'NO_SIGNAL');

  const ws = await t.connect(r.rider.token);
  ws.sendJson({ type: 'JOIN', groupId: r.c.groupId, prevExit: 'NONSENSE', prevAliveAt: 1 });
  await ws.next((m) => m.type === 'SNAPSHOT');
  await t.gw.timeline.idle();
  assert.equal((await openOffline(r.c.groupId, r.rider.user.userId)).data.cause, 'NO_SIGNAL');

  const aliveAt = Date.now() - 7 * 60000;
  ws.sendJson({ type: 'JOIN', groupId: r.c.groupId, prevExit: 'KILLED', prevAliveAt: aliveAt });
  await ws.next((m) => m.type === 'SNAPSHOT');
  const upd = await ws.next((m) => m.type === 'TIMELINE_UPDATE' && m.event.type === 'OFFLINE');
  assert.equal(upd.event.data.cause, 'KILLED');
  assert.equal(upd.event.data.downFrom, aliveAt);
  // prevAliveAt is clamped to the last 48 hours.
  ws.sendJson({ type: 'JOIN', groupId: r.c.groupId, prevExit: 'KILLED', prevAliveAt: 5 });
  const upd2 = await ws.next((m) => m.type === 'TIMELINE_UPDATE' && m.event.type === 'OFFLINE');
  assert.ok(upd2.event.data.downFrom >= Date.now() - 48 * 3600000 - 5000);
  ws.close();
});
