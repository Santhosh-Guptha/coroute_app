'use strict';
/**
 * v3.62 QA: end-to-end ride scenarios through the real gateway, duplicate taps (double submit) and response times.
 * Budgets are generous (MemorySoda on a shared CI box): they catch regressions of an order of magnitude, not noise.
 * The measured p50 / p95 are printed (QA report) with QA_TIMING=1.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDE_JOIN_APPROVAL = 'true';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const F = require('../src/friends');
const { boot, sleep } = require('./_helpers');

let t; let seq = 0; let ipSeq = 0;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });
const rider = (name) => { seq++; return t.register(name, `qa362_${seq}@coroute.test`); };

async function timed(n, fn) {
  const out = [];
  for (let i = 0; i < n; i++) { const t0 = performance.now(); await fn(i); out.push(performance.now() - t0); }
  out.sort((a, b) => a - b);
  return { p50: out[Math.floor(n * 0.5)], p95: out[Math.min(n - 1, Math.floor(n * 0.95))] };
}
const report = {};
after(() => { if (process.env.QA_TIMING) console.log('QA_TIMING', JSON.stringify(report)); });

test('sign-in, join with approval, SOS, chat send: correct and fast', async () => {
  const host = await rider('Qa Host');
  const guest = await rider('Qa Guest');
  report.signIn = await timed(10, () => t.api('POST', '/auth/login', { identifier: `qa362_1@coroute.test`, password: 'Password#123' }, null, { 'X-Forwarded-For': `10.9.0.${ipSeq++ % 250}` }));
  const c = (await t.api('POST', '/convoys', { name: 'QA ride' }, host.token)).json;
  assert.match(c.joinCode, /^[A-Z0-9]{6}$/);
  // Join by code waits for the host (202), double tap on Join is the same pending request.
  const j1 = await t.api('POST', '/convoys/join', { code: c.joinCode }, guest.token);
  const j2 = await t.api('POST', '/convoys/join', { code: c.joinCode }, guest.token);
  assert.equal(j1.status, 202, JSON.stringify(j1.json));
  assert.equal(j2.status, 202);
  const room = t.gw.convoys.rooms.get(c.groupId);
  assert.equal([...(room.pending || new Map()).keys()].filter((k) => k === guest.user.userId).length <= 1, true, 'one pending entry');
  // Host taps "Let in" twice: one member, second tap harmless.
  const a1 = await t.api('POST', `/convoys/${c.groupId}/join-requests/${guest.user.userId}`, { approve: true }, host.token);
  const a2 = await t.api('POST', `/convoys/${c.groupId}/join-requests/${guest.user.userId}`, { approve: true }, host.token);
  assert.ok(a1.status < 300, JSON.stringify(a1.json));
  assert.ok(a2.status < 500, `second tap: ${a2.status}`);
  const again = await t.api('POST', '/convoys/join', { code: c.joinCode }, guest.token);
  assert.equal(again.status, 200, 'approved rider joins at once');
  assert.ok(room.riders.has(guest.user.userId));
  report.join = await timed(5, async (i) => { const g = await rider(`Qa Extra ${'abcdefghij'[i]}`); await t.api('POST', '/convoys/join', { code: c.joinCode }, g.token); });

  // SOS: a double tap (same clientId twice, at once) raises ONE alert.
  const sosTimes = [];
  const [s1, s2] = await Promise.all([1, 2].map(async () => {
    const t0 = performance.now();
    const r = await t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: 'qa-dbl', lat: 17.4, lng: 78.4 }, guest.token);
    sosTimes.push(performance.now() - t0);
    return r;
  }));
  assert.equal(s1.json.alertId, s2.json.alertId, 'one alert for a double tap');
  assert.equal([...room.alerts.values()].filter((a) => a.clientId === 'qa-dbl').length, 1);
  report.sos = await timed(8, (i) => t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: `qa-sos-${i}`, lat: 17.4, lng: 78.4 }, host.token));
  assert.ok(report.sos.p95 < 1500, `SOS p95 ${report.sos.p95} ms`);

  // Chat between friends; a double tap with the same clientId is one message.
  const out = await F.sendRequest(t.soda, host.user.userId, guest.user.userId);
  if (out.status === 'REQUESTED') await F.respond(t.soda, guest.user.userId, out.edge.requestId, true);
  const dm = await t.api('POST', '/chats/dm', { username: guest.user.username }, host.token);
  assert.equal(dm.status, 200, JSON.stringify(dm.json));
  const id = dm.json.chat.chatId;
  const [m1, m2] = await Promise.all([1, 2].map(() => t.api('POST', `/chats/${id}/messages`, { text: 'On my way', clientId: 'qa-msg-1' }, host.token)));
  assert.ok(m1.status < 300 && m2.status < 300, `${m1.status} ${m2.status}`);
  const list = await t.api('GET', `/chats/${id}/messages`, null, guest.token);
  assert.equal(list.json.messages.filter((m) => m.text === 'On my way').length, 1, 'double tap sends one message');
  report.chatSend = await timed(10, (i) => t.api('POST', `/chats/${id}/messages`, { text: `m${i}`, clientId: `qa-m-${i}` }, host.token));
  report.chats = await timed(10, () => t.api('GET', '/chats', null, guest.token));
  for (const k of ['signIn', 'join', 'chatSend', 'chats']) assert.ok(report[k].p95 < 3000, `${k} p95 ${report[k].p95}`);
});

test('same account on two phones: both sockets get the ride; SOS reaches every phone of every member', async () => {
  const host = await rider('Qa Two Host');
  const g = await rider('Qa Two Guest');
  const c = (await t.api('POST', '/convoys', { name: 'Two phones' }, host.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, g.token);
  await t.api('POST', `/convoys/${c.groupId}/join-requests/${g.user.userId}`, { approve: true }, host.token);
  await t.api('POST', '/convoys/join', { code: c.joinCode }, g.token);
  // Second phone of the host signs in separately.
  const second = await t.api('POST', '/auth/login', { identifier: host.user.email || `qa362_${seq - 1}@coroute.test`, password: 'Password#123' }, null, { 'X-Forwarded-For': '10.9.9.9' });
  const tok2 = second.json.token || host.token;
  const p1 = await t.joinRoom(host.token, c.groupId);
  const p2 = await t.joinRoom(tok2, c.groupId);
  const gw = await t.joinRoom(g.token, c.groupId);
  gw.sendJson({ type: 'SOS', clientId: 'qa-two', lat: 17.41, lng: 78.41 });
  const [x, y] = await Promise.all([p1.next((m) => m.type === 'ALERT'), p2.next((m) => m.type === 'ALERT')]);
  assert.equal(x.alert.alertId, y.alert.alertId);
  for (const s of [p1, p2, gw]) s.close();
  await sleep(20);
});

test('reconnect mid-ride: a rider whose socket dropped gets the open SOS in the snapshot when back', async () => {
  const host = await rider('Qa Re Host');
  const g = await rider('Qa Re Guest');
  const c = (await t.api('POST', '/convoys', { name: 'Reconnect' }, host.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, g.token);
  await t.api('POST', `/convoys/${c.groupId}/join-requests/${g.user.userId}`, { approve: true }, host.token);
  await t.api('POST', '/convoys/join', { code: c.joinCode }, g.token);
  const gs = await t.joinRoom(g.token, c.groupId);
  gs.close();
  await sleep(50);
  const r = await t.api('POST', `/convoys/${c.groupId}/sos`, { clientId: 'qa-re', lat: 17.42, lng: 78.42 }, host.token);
  assert.equal(r.status, 201);
  const back = await t.joinRoom(g.token, c.groupId);
  const open = (back.snapshot.activeAlerts || []).filter((a) => a.alertId === r.json.alertId);
  assert.equal(open.length, 1, 'open SOS in the snapshot after reconnect');
  back.close();
  await sleep(20);
});
