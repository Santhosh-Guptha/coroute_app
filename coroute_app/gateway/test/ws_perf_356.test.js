'use strict';
/**
 * v3.56 WebSocket efficiency: per-rider position throttle in small rooms (WS_POS_MIN_MS), one RIDER_UPDATES frame
 * per flush for sockets with the 'posbatch1' cap (legacy sockets keep per-rider messages), SOS never waits behind
 * coalesced positions, slow peers lose positions but never alerts, the heartbeat setting, and the hot-path
 * account check that never waits for the database.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.WS_POS_MIN_MS = '400';
process.env.WS_COALESCE_ABOVE = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { UserGate } = require('../src/auth');

let t;
before(async () => { t = await boot({ emergencyFetch: async () => { throw new Error('offline in tests'); } }); });
after(async () => { await t.gw.shutdown(); });

let n = 0;
const ip = () => ({ 'X-Forwarded-For': `10.56.${(n >> 8) & 255}.${n & 255}` });
async function rider(tag) {
  n++;
  const r = await t.api('POST', '/auth/register', {
    name: `${tag}${n}`, email: `wsperf-${tag.toLowerCase()}${n}@coroute.test`, password: 'Password#123',
    phone: `+9198767${String(10000 + n).slice(-5)}`, vehicleType: 'Motorcycle', vehicleNo: `TS11AB${String(1000 + n).slice(-4)}`,
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  }, null, ip());
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}

/** A convoy of `count` riders; returns { riders, groupId }. */
async function convoy(tag, count) {
  const riders = [];
  for (let i = 0; i < count; i++) riders.push(await rider(`${tag}${i}`));
  const c = await t.api('POST', '/convoys', { name: `Perf ${tag}` }, riders[0].token, ip());
  assert.ok(c.status === 200 || c.status === 201, JSON.stringify(c.json));
  for (const r of riders.slice(1)) {
    const j = await t.api('POST', '/convoys/join', { code: c.json.joinCode }, r.token, ip());
    assert.equal(j.status, 200, JSON.stringify(j.json));
  }
  return { riders, groupId: c.json.groupId };
}

async function join(token, groupId, caps) {
  const ws = await t.connect(token);
  ws.sendJson({ type: 'JOIN', groupId, ...(caps ? { caps } : {}) });
  await ws.next((m) => m.type === 'SNAPSHOT');
  return ws;
}

const updatesOf = (ws, userId) => ws.inbox.filter((m) => (m.type === 'RIDER_UPDATE' && m.rider.userId === userId)
  || (m.type === 'RIDER_UPDATES' && m.riders.some((r) => r.userId === userId)));

test('small room: a rider sending faster than WS_POS_MIN_MS is relayed at once, then coalesced (latest wins)', async () => {
  const { riders, groupId } = await convoy('Thr', 2);
  const a = await join(riders[0].token, groupId);
  const b = await join(riders[1].token, groupId);
  b.inbox.length = 0;
  a.sendJson({ type: 'TELEMETRY', lat: 12.9001, lng: 77.6001, speedKmh: 40 });
  const first = await b.next((m) => m.type === 'RIDER_UPDATE');
  assert.equal(first.rider.lat, 12.9001);
  await sleep(150); // inside the window: the telemetry budget (3/s) is not the limit here
  a.sendJson({ type: 'TELEMETRY', lat: 12.9002, lng: 77.6002, speedKmh: 40 });
  await sleep(30);
  a.sendJson({ type: 'TELEMETRY', lat: 12.9003, lng: 77.6003, speedKmh: 40 });
  await sleep(100);
  assert.equal(updatesOf(b, riders[0].user.userId).length, 0, 'nothing more inside the window');
  const last = await b.next((m) => m.type === 'RIDER_UPDATE', 2000);
  assert.equal(last.rider.lat, 12.9003, 'the newest position wins');
  await sleep(500);
  assert.equal(updatesOf(b, riders[0].user.userId).length, 0, 'the coalesced one went out once');
  a.close(); b.close();
});

test('posbatch1 sockets get one RIDER_UPDATES frame per flush; legacy sockets keep per-rider messages', async () => {
  const { riders, groupId } = await convoy('Bat', 4);
  const [a, b] = [await join(riders[0].token, groupId), await join(riders[1].token, groupId)];
  const c = await join(riders[2].token, groupId, ['net1', 'posbatch1']);
  const d = await join(riders[3].token, groupId, ['net1']);
  // First fixes go out at once; the second ones fall in the window and are flushed together.
  a.sendJson({ type: 'TELEMETRY', lat: 12.91, lng: 77.61 });
  b.sendJson({ type: 'TELEMETRY', lat: 12.92, lng: 77.62 });
  await sleep(120);
  c.inbox.length = 0; d.inbox.length = 0;
  a.sendJson({ type: 'TELEMETRY', lat: 12.911, lng: 77.611 });
  b.sendJson({ type: 'TELEMETRY', lat: 12.921, lng: 77.621 });
  const batch = await c.next((m) => m.type === 'RIDER_UPDATES', 2000);
  const ids = batch.riders.map((r) => r.userId).sort();
  assert.deepEqual(ids, [riders[0].user.userId, riders[1].user.userId].sort());
  assert.equal(batch.riders.find((r) => r.userId === riders[0].user.userId).lat, 12.911);
  assert.ok(Number.isFinite(batch.ts));
  await sleep(100);
  assert.equal(d.inbox.filter((m) => m.type === 'RIDER_UPDATES').length, 0, 'a legacy socket never gets the batch frame');
  assert.equal(d.inbox.filter((m) => m.type === 'RIDER_UPDATE').length, 2, 'it gets one message per rider');
  assert.ok(t.gw.hub.stats.batchFrames >= 1);
  for (const w of [a, b, c, d]) w.close();
});

test('a batch never contains the receiving rider\'s own position', async () => {
  const { riders, groupId } = await convoy('Own', 3);
  const a = await join(riders[0].token, groupId, ['posbatch1']);
  const b = await join(riders[1].token, groupId, ['posbatch1']);
  const c = await join(riders[2].token, groupId, ['posbatch1']);
  for (const w of [a, b, c]) w.sendJson({ type: 'TELEMETRY', lat: 12.93, lng: 77.63 });
  await sleep(120);
  for (const w of [a, b, c]) w.inbox.length = 0;
  a.sendJson({ type: 'TELEMETRY', lat: 12.931, lng: 77.631 });
  b.sendJson({ type: 'TELEMETRY', lat: 12.932, lng: 77.632 });
  c.sendJson({ type: 'TELEMETRY', lat: 12.933, lng: 77.633 });
  await sleep(800);
  for (const [w, r] of [[a, riders[0]], [b, riders[1]], [c, riders[2]]]) {
    const own = updatesOf(w, r.user.userId);
    assert.equal(own.length, 0, 'own position never echoed');
    const others = w.inbox.filter((m) => m.type === 'RIDER_UPDATES' || m.type === 'RIDER_UPDATE');
    assert.ok(others.length >= 1);
  }
  for (const w of [a, b, c]) w.close();
});

test('SOS is never held back by position coalescing', async () => {
  const { riders, groupId } = await convoy('Sos', 2);
  const a = await join(riders[0].token, groupId);
  const b = await join(riders[1].token, groupId);
  a.sendJson({ type: 'TELEMETRY', lat: 12.94, lng: 77.64 });
  await sleep(50);
  a.sendJson({ type: 'TELEMETRY', lat: 12.941, lng: 77.641 }); // queued in the window
  const t0 = Date.now();
  a.sendJson({ type: 'SOS', clientId: 'perf-sos-1', lat: 12.941, lng: 77.641 });
  const alert = await b.next((m) => m.type === 'ALERT', 3000);
  assert.ok(Date.now() - t0 < 350, `SOS arrived after ${Date.now() - t0} ms (window is 400 ms)`);
  assert.equal(alert.alert.userId, riders[0].user.userId);
  a.close(); b.close();
});

test('a backlogged peer loses positions but still gets the ALERT', async () => {
  const { riders, groupId } = await convoy('Slow', 2);
  const a = await join(riders[0].token, groupId);
  const b = await join(riders[1].token, groupId);
  const hub = t.gw.hub;
  const peer = [...hub.rooms.get(groupId)].find((w) => w.user.userId === riders[1].user.userId);
  // Pretend the link to B is congested (300 KB unsent: above the position drop line, below the kick line).
  let fake = 300 * 1024;
  Object.defineProperty(peer, 'bufferedAmount', { configurable: true, get: () => fake });
  const dropped0 = hub.stats.posDropped;
  await sleep(450);
  a.sendJson({ type: 'TELEMETRY', lat: 12.95, lng: 77.65 });
  await sleep(150);
  assert.ok(hub.stats.posDropped > dropped0, 'the stale position was dropped for the slow peer');
  a.sendJson({ type: 'SOS', clientId: 'perf-sos-2', lat: 12.95, lng: 77.65 });
  await sleep(150);
  fake = 0; // the link recovers: the queued alert drains
  const alert = await b.next((m) => m.type === 'ALERT', 3000);
  assert.equal(alert.alert.userId, riders[0].user.userId);
  delete peer.bufferedAmount;
  a.close(); b.close();
});

test('HELLO announces the heartbeat interval (default 30 s)', async () => {
  const r = await rider('Hb');
  const ws = await t.connect(r.token);
  const hello = await ws.next((m) => m.type === 'HELLO');
  assert.equal(hello.heartbeatSec, 30);
  ws.close();
});

test('UserGate hot path: an older entry answers at once and is refreshed in the background (stale-while-revalidate)', async () => {
  let reads = 0; let release;
  const user = { userId: 'usr_g', status: 'ACTIVE', role: 'RIDER' };
  const repo = { findUserById: async () => { reads++; if (reads > 1) await new Promise((r) => { release = r; }); return { ...user, name: `v${reads}` }; } };
  let now = 1000;
  const gate = new UserGate(repo, { ttlMs: 30000, clock: () => now });
  assert.equal((await gate.check({ sub: 'usr_g' })).name, 'v1');
  now += 40000; // older than USER_GATE_TTL_MS, younger than the hot bound
  assert.equal((await gate.checkDetailed({ sub: 'usr_g' }, { maxAgeMs: 120000, swr: true })).user.name, 'v1');
  assert.equal(reads, 1, 'no database read inside the hot bound');
  now += 100000; // 140 s: past the hot bound, within twice it: answered now, refreshed behind
  const quick = await Promise.race([gate.checkDetailed({ sub: 'usr_g' }, { maxAgeMs: 120000, swr: true }).then((x) => x.user.name), sleep(200).then(() => 'waited')]);
  assert.equal(quick, 'v1', 'the stale entry answered without waiting for the database');
  assert.equal(reads, 2, 'one background refresh started');
  release();
  await sleep(10);
  assert.equal((await gate.check({ sub: 'usr_g' })).name, 'v2');
  // invalidate() still removes the entry at once (hold / block / delete never fall back to old data).
  gate.invalidate('usr_g');
  assert.equal(gate.cache.has('usr_g'), false);
});

test('UserGate without swr keeps the strict USER_GATE_TTL_MS for ordinary messages', async () => {
  let reads = 0;
  const repo = { findUserById: async () => { reads++; return { userId: 'usr_h', status: 'ACTIVE', role: 'RIDER' }; } };
  let now = 0;
  const gate = new UserGate(repo, { ttlMs: 30000, clock: () => now });
  await gate.check({ sub: 'usr_h' });
  now += 31000;
  await gate.check({ sub: 'usr_h' });
  assert.equal(reads, 2);
});
