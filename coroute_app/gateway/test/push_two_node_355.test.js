'use strict';
/**
 * 3.55 follow-up: no duplicate notice across the two nodes (src/push.js, src/mirror.js). A rider whose
 * socket is on the OTHER gateway gets the socket notice (forwarded over the mirror) and no FCM push;
 * the socket message and the push data share one eventId (the app's dedupe safety net).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.NET_TICK_MS = '3600000';
process.env.DISCOVERY_TICK_MS = '3600000';
delete process.env.FCM_SERVICE_ACCOUNT_JSON;
delete process.env.FCM_SERVICE_ACCOUNT_FILE;

const test = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const P = require('../src/push');

const KEY = 'test-mirror-key-0123456789-abcdefghijklmnop';
const sent = [];
const transport = async (message) => { sent.push(message); return { status: 200, body: { name: 'projects/x/messages/1' } }; };
const tok = (n) => `fcmtoken_${String(n).padStart(4, '0')}_${'y'.repeat(40)}`;
const forToken = (token) => sent.filter((m) => m.message.token === token);

async function node(soda, name, role, extra = {}) {
  const t = await boot({
    soda, pushTransport: transport,
    mirror: {
      node: name, role, listenHost: '127.0.0.1', listenPort: 0, key: KEY, ackTimeoutMs: 400,
      startupWaitMs: 400, heartbeatMs: 100, deadMs: 800, reconnectMinMs: 50, reconnectMaxMs: 200,
      handbackDelayMs: 60000, handbackPerSec: 25, ...extra,
    },
  });
  t.mirrorUrl = `ws://127.0.0.1:${t.gw.mirror.port}/mirror`;
  return t;
}

async function until(fn, what = 'condition', ms = 4000) {
  const end = Date.now() + ms;
  for (;;) {
    let v; try { v = await fn(); } catch { v = false; }
    if (v) return v;
    if (Date.now() > end) throw new Error(`timeout: ${what}`);
    await sleep(20);
  }
}

test('stampEvent: stable ids from the notice, kept when set', () => {
  assert.equal(P.stampEvent({ type: 'FRIEND_REQUEST', requestId: 'fr_1' }).eventId, 'FRIEND_REQUEST:fr_1');
  assert.equal(P.stampEvent({ type: 'CREW_INVITE', inviteId: 'ci_9', crewId: 'c1' }).eventId, 'CREW_INVITE:ci_9');
  assert.equal(P.stampEvent({ type: 'POLL_CREATED', pollId: 'p_2', crewId: 'c1' }).eventId, 'POLL_CREATED:p_2');
  assert.equal(P.stampEvent({ type: 'RIDE_INVITE', eventId: 'RIDE_INVITE:ri_1', inviteId: 'other' }).eventId, 'RIDE_INVITE:ri_1');
  const a = P.stampEvent({ type: 'FRIEND_ACCEPTED' }).eventId, b = P.stampEvent({ type: 'FRIEND_ACCEPTED' }).eventId;
  assert.match(a, /^FRIEND_ACCEPTED:/);
  assert.notEqual(a, b, 'no id in the notice: still unique');
});

test('a rider connected to the peer node gets the socket notice, not a push; offline riders still get one', async () => {
  const soda = new MemorySoda();
  const A = await node(soda, 'vm1', 'live');
  const B = await node(soda, 'vm2', 'web', { peerUrl: A.mirrorUrl });
  A.gw.mirror.setPeer(B.mirrorUrl);
  try {
    await until(() => A.gw.mirror.linked() && B.gw.mirror.linked(), 'link up');
    const sender = await A.register('Sender Two', 'sender@twopush.test');
    const target = await A.register('Target Two', 'target@twopush.test');
    const offline = await A.register('Offline Two', 'offline@twopush.test');
    for (const [u, n] of [[target, 1], [offline, 2]]) {
      assert.equal((await A.api('POST', '/me/push-tokens', { token: tok(n), platform: 'android', appVersion: '3.55.0' }, u.token)).status, 200);
    }

    // The target's app is on the home screen, connected to vm2 (no ride room).
    const ws = await B.connect(target.token);
    await until(() => A.gw.mirror.userOnPeer(target.user.userId), 'vm1 learns the target is online on vm2');
    assert.equal(A.gw.mirror.userOnPeer(offline.user.userId), false);
    assert.equal(A.gw.push._connected(target.user.userId), true, 'connected = on either node');

    sent.length = 0;
    const r = await A.api('POST', '/friends/requests', { username: target.user.username }, sender.token);
    assert.equal(r.status, 202, JSON.stringify(r.json));
    const notice = await ws.next((m) => m.type === 'FRIEND_REQUEST');
    assert.match(notice.eventId, /^FRIEND_REQUEST:fr_/, 'the socket notice carries the eventId');
    await sleep(150);
    assert.equal(forToken(tok(1)).length, 0, 'connected on the peer node: no push');

    // skipConnected (notifyUsers) checks the peer too.
    const out = await A.gw.push.notifyUsers([target.user.userId, offline.user.userId], { type: 'POLL_CREATED', title: 't', body: 'b', skipConnected: true });
    assert.equal(out.skipped, 1);
    assert.equal(forToken(tok(2)).length, 1, 'the offline rider still gets a push');
    assert.equal(forToken(tok(1)).length, 0);

    // The target goes offline: the next request is pushed, with the same eventId as the socket notice would carry.
    ws.close();
    await until(() => !A.gw.mirror.userOnPeer(target.user.userId), 'vm1 learns the target left');
    sent.length = 0;
    const other = await A.register('Third Two', 'third@twopush.test');
    assert.equal((await A.api('POST', '/friends/requests', { username: target.user.username }, other.token)).status, 202);
    await until(() => forToken(tok(1)).length === 1, 'push to the offline target');
    assert.match(forToken(tok(1))[0].message.data.eventId, /^FRIEND_REQUEST:fr_/);
  } finally {
    await B.gw.shutdown().catch(() => {});
    await A.gw.shutdown().catch(() => {});
  }
});

test('RIDE_INVITE push data and socket message share the eventId (the app drops the second notice)', async () => {
  const t = await boot({ pushTransport: transport });
  try {
    const r = await t.register('Invitee One', 'invitee@twopush.test');
    assert.equal((await t.api('POST', '/me/push-tokens', { token: tok(3), platform: 'android', appVersion: '3.55.0' }, r.token)).status, 200);
    const ws = await t.connect(r.token);
    await sleep(50);
    sent.length = 0;
    const payload = P.stampEvent({ type: 'RIDE_INVITE', inviteId: 'ri_same', username: 'SwiftFalcon482' });
    t.gw.hub.sendToUser(r.user.userId, payload);
    const msg = await ws.next((m) => m.type === 'RIDE_INVITE');
    const out = await t.gw.push.onSocketEvent(r.user.userId, payload, { delivered: 1 });
    assert.equal(out.sent, 1, 'RIDE_INVITE always pushes');
    assert.equal(forToken(tok(3))[0].message.data.eventId, msg.eventId);
    assert.equal(msg.eventId, 'RIDE_INVITE:ri_same');
    ws.close();
  } finally {
    await t.gw.shutdown().catch(() => {});
  }
});
