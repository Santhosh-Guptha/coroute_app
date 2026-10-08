'use strict';
/**
 * 3.14 outbox: CHAT, WAIT, STATUS, STOP_VISITED and CHECK_IN with a clientId are applied once and
 * answered with ACK; errors carry the clientId; an invalid clientId behaves like none.
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
  const lead = await t.register(`Out Lead ${tag}`, `olead.${tag}@coroute.test`);
  const rider = await t.register(`Out Rider ${tag}`, `orider.${tag}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Outbox ${tag}`, stops: [{ name: 'Tea', lat: 17.4, lng: 78.4 }] }, lead.token)).json;
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, rider.token)).status, 200);
  const wl = await t.joinRoom(lead.token, c.groupId);
  const wr = await t.joinRoom(rider.token, c.groupId);
  return { c, lead, rider, wl, wr };
}

const ackOf = (ws, cid) => ws.next((m) => m.type === 'ACK' && m.clientId === cid);

test('each outbox message type is applied once per clientId and acknowledged', async () => {
  const r = await ride('once');
  const sentAt = Date.now() - 60000;

  // CHAT
  r.wr.sendJson({ type: 'CHAT', text: 'Fuel in 5', clientId: 'c-1', sentAt });
  assert.equal((await ackOf(r.wr, 'c-1')).duplicate, false);
  const m1 = await r.wl.next((m) => m.type === 'MESSAGE');
  assert.equal(m1.message.clientId, 'c-1');
  assert.equal(m1.message.sentAt, sentAt);
  r.wr.sendJson({ type: 'CHAT', text: 'Fuel in 5', clientId: 'c-1', sentAt });
  const dup = await ackOf(r.wr, 'c-1');
  assert.equal(dup.duplicate, true);
  assert.ok(dup.ts > 0);
  // sentAt is clamped to the last 6 hours and never in the future.
  r.wr.sendJson({ type: 'CHAT', text: 'From the future', clientId: 'c-2', sentAt: Date.now() + 3600000 });
  await ackOf(r.wr, 'c-2');
  const m2 = await r.wl.next((m) => m.type === 'MESSAGE');
  assert.ok(m2.message.sentAt <= Date.now());

  // WAIT
  r.wr.sendJson({ type: 'WAIT', clientId: 'w-1' });
  await ackOf(r.wr, 'w-1');
  r.wr.sendJson({ type: 'WAIT', clientId: 'w-1' });
  assert.equal((await ackOf(r.wr, 'w-1')).duplicate, true);

  // STATUS
  r.wr.sendJson({ type: 'STATUS', statusReason: 'FUELING', clientId: 's-1' });
  await ackOf(r.wr, 's-1');
  r.wr.sendJson({ type: 'STATUS', statusReason: 'FUELING', clientId: 's-1' });
  assert.equal((await ackOf(r.wr, 's-1')).duplicate, true);

  // STOP_VISITED
  const stopId = r.wl.snapshot.stopPoints[0].stopId;
  r.wr.sendJson({ type: 'STOP_VISITED', stopId, isVisited: true, clientId: 'v-1' });
  await ackOf(r.wr, 'v-1');
  r.wr.sendJson({ type: 'STOP_VISITED', stopId, isVisited: true, clientId: 'v-1' });
  assert.equal((await ackOf(r.wr, 'v-1')).duplicate, true);

  // CHECK_IN
  r.wr.sendJson({ type: 'CHECK_IN', result: 'NO_REPLY', awayM: 3000, clientId: 'k-1' });
  await ackOf(r.wr, 'k-1');
  r.wr.sendJson({ type: 'CHECK_IN', result: 'NO_REPLY', awayM: 3000, clientId: 'k-1' });
  assert.equal((await ackOf(r.wr, 'k-1')).duplicate, true);

  await sleep(100);
  await t.gw.timeline.idle();
  const msgs = (await t.gw.repo.listMessages(r.c.groupId));
  assert.equal(msgs.filter((m) => m.text === 'Fuel in 5').length, 1, 'chat stored once');
  assert.equal(msgs.filter((m) => m.cardType === 'WAIT_2MIN').length, 1, 'one wait card');
  const events = await t.gw.repo.listEvents(r.c.groupId);
  assert.equal(events.filter((e) => e.type === 'STATUS').length, 1);
  assert.equal(events.filter((e) => e.type === 'NO_REPLY').length, 1);
  assert.equal(r.wl.inbox.filter((m) => m.type === 'ACK').length, 0, 'ACK goes to the sender only');
  // The same clientId from another rider is a different message.
  r.wl.sendJson({ type: 'CHAT', text: 'Fuel in 5', clientId: 'c-1' });
  assert.equal((await ackOf(r.wl, 'c-1')).duplicate, false);
  r.wl.close(); r.wr.close();
});

test('errors carry the clientId; an invalid clientId is treated as absent', async () => {
  const r = await ride('err');
  r.wr.sendJson({ type: 'CHAT', text: '   ', clientId: 'e-1' });
  const err = await r.wr.next((m) => m.type === 'ERROR');
  assert.equal(err.code, 400);
  assert.equal(err.clientId, 'e-1');

  await sleep(1100); // chat budget: 5 per second
  for (const bad of ['has space', 'x'.repeat(65), 12, { a: 1 }, 'semi;colon']) {
    r.wr.sendJson({ type: 'CHAT', text: 'No id', clientId: bad });
  }
  await sleep(150);
  assert.equal(r.wr.inbox.filter((m) => m.type === 'ACK').length, 0, 'no ACK without a valid clientId');
  const errs = r.wr.inbox.filter((m) => m.type === 'ERROR');
  assert.deepEqual(errs, []);
  assert.equal((await t.gw.repo.listMessages(r.c.groupId)).filter((m) => m.text === 'No id').length, 5, 'applied every time, as before (chat budget 5/s)');
  // Old-style messages without a clientId keep working and get no ACK.
  await sleep(1000);
  r.wr.sendJson({ type: 'WAIT' });
  await r.wl.next((m) => m.type === 'WAIT_REQUESTS');
  await sleep(50);
  assert.equal(r.wr.inbox.filter((m) => m.type === 'ACK').length, 0);
  r.wl.close(); r.wr.close();
});

test('chat dedupe survives a reload of the convoy from the database', async () => {
  const r = await ride('reload');
  r.wr.sendJson({ type: 'CHAT', text: 'Before restart', clientId: 'r-1' });
  await ackOf(r.wr, 'r-1');
  const room = t.gw.convoys.rooms.get(r.c.groupId);
  await t.gw.convoys.flushRoom(room);
  t.gw.convoys.rooms.delete(r.c.groupId); // as after a gateway restart
  r.wr.sendJson({ type: 'CHAT', text: 'Before restart', clientId: 'r-1' });
  assert.equal((await ackOf(r.wr, 'r-1')).duplicate, true);
  assert.equal((await t.gw.repo.listMessages(r.c.groupId)).filter((m) => m.text === 'Before restart').length, 1);
  r.wl.close(); r.wr.close();
});

test('CHECK_IN has its own budget, separate from SOS; a refused one keeps its clientId (429)', async () => {
  const r = await ride('budget');
  for (let i = 0; i < 3; i++) r.wr.sendJson({ type: 'SOS', lat: 1, lng: 1, clientId: `sos-b-${i}` });
  await sleep(150);
  r.wr.sendJson({ type: 'SOS', lat: 1, lng: 1, clientId: 'sos-b-x' });
  assert.equal((await r.wr.next((m) => m.type === 'ERROR')).code, 429, 'the SOS budget is used up');
  for (let i = 0; i < 3; i++) {
    r.wr.sendJson({ type: 'CHECK_IN', result: 'OK', clientId: `ci-${i}` });
    await ackOf(r.wr, `ci-${i}`);
  }
  r.wr.sendJson({ type: 'CHECK_IN', result: 'OK', clientId: 'ci-x' });
  const err = await r.wr.next((m) => m.type === 'ERROR');
  assert.equal(err.code, 429);
  assert.equal(err.clientId, 'ci-x');
  r.wl.close(); r.wr.close();
});
