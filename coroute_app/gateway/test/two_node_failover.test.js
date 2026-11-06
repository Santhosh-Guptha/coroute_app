'use strict';
/**
 * Two gateways in one process sharing one MemorySoda, mirrored over localhost (src/mirror.js):
 * failover, durable SOS across nodes, hand-back, link drop and recovery, the live-rider cap,
 * room snapshot persistence and mirror authentication.
 */
process.env.NODE_ENV = 'test';
process.env.RIDER_PERSIST_INTERVAL_MS = '50';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.NET_TICK_MS = '3600000';
process.env.DISCOVERY_TICK_MS = '3600000';

const test = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { boot, sleep } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Link } = require('../src/mirror');

const KEY = 'test-mirror-key-0123456789-abcdefghijklmnop';
const uid = (u) => u.user.userId;

/** Boots one gateway node with a mirror listening on an ephemeral localhost port. */
async function node(soda, name, role, extra = {}) {
  const t = await boot({
    soda,
    mirror: {
      node: name, role, listenHost: '127.0.0.1', listenPort: 0, key: KEY, ackTimeoutMs: 400,
      startupWaitMs: 400, heartbeatMs: 100, deadMs: 800, reconnectMinMs: 50, reconnectMaxMs: 200,
      handbackDelayMs: 300, handbackPerSec: 25, ...extra,
    },
  });
  t.mirrorUrl = `ws://127.0.0.1:${t.gw.mirror.port}/mirror`;
  return t;
}

/** A pair: vm1 (live) and vm2 (web), dialing each other. */
async function pair(extraA = {}, extraB = {}) {
  const soda = new MemorySoda();
  const A = await node(soda, 'vm1', 'live', extraA);
  const B = await node(soda, 'vm2', 'web', { peerUrl: A.mirrorUrl, ...extraB });
  A.gw.mirror.setPeer(B.mirrorUrl);
  await until(() => A.gw.mirror.linked() && B.gw.mirror.linked() && A.gw.mirror.state === 'serving', 'link up');
  return { soda, A, B };
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

/** The process dies: no goodbye on the mirror, sockets dropped, nothing flushed. */
function kill(t) {
  const gw = t.gw;
  gw.mirror.kill();
  for (const room of gw.convoys.rooms.values()) clearTimeout(room.persistTimer);
  gw.convoys.persistIntervalMs = 3600000;
  gw.hub.close();
  for (const ws of gw.hub.wss.clients) ws.terminate();
  gw.server.closeAllConnections?.();
  gw.server.close();
  for (const x of [gw.timeline, gw.network, gw.discovery, gw.audit, gw.retention]) { try { x.stop(); } catch { /* stopped */ } }
  gw.lease?.stopAll?.({ waitMs: 0 })?.catch?.(() => {});
  t.dead = true;
}

async function done(...nodes) {
  for (const t of nodes) if (t && !t.dead) await t.gw.shutdown().catch(() => {});
}

/** Lead + n members in a convoy created through `t`. */
async function convoy(t, tag, n = 2) {
  const lead = await t.register(`Lead ${tag}`, `lead-${tag}@two.test`);
  const c = (await t.api('POST', '/convoys', { name: `Ride ${tag}` }, lead.token)).json;
  assert.ok(c.groupId, JSON.stringify(c));
  const members = [];
  for (let i = 0; i < n; i++) {
    const m = await t.register(`Rider ${tag}${i}`, `r${i}-${tag}@two.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, m.token)).status, 200);
    members.push(m);
  }
  return { c, gid: c.groupId, lead, members };
}

const isUpdateOf = (u, pred = () => true) => (m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(u) && pred(m.rider);

test('failover: the web node mirrors the ride; after the live node dies riders find group, roles, open SOS and positions on it', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'fo', 2);
    const [sweep, pack] = R.members;
    const wl = await A.joinRoom(R.lead.token, R.gid);
    const ws = await A.joinRoom(sweep.token, R.gid);
    const wp = await A.joinRoom(pack.token, R.gid);
    wl.sendJson({ type: 'ROLE_SET', userId: uid(sweep), role: 'SWEEPER', clientId: 'role-1' });
    await wl.next((m) => m.type === 'ACK' && m.clientId === 'role-1');
    wl.sendJson({ type: 'TELEMETRY', lat: 17.40, lng: 78.40, speedKmh: 50 });
    wp.sendJson({ type: 'TELEMETRY', lat: 17.41, lng: 78.41, speedKmh: 45 });
    ws.sendJson({ type: 'TELEMETRY', lat: 17.39, lng: 78.39, speedKmh: 40 });
    wp.sendJson({ type: 'SOS', lat: 17.41, lng: 78.41, alertType: 'CRASH_OR_EMERGENCY', clientId: 'sos-fo-1' });
    const alert = (await wl.next((m) => m.type === 'ALERT')).alert;

    // B holds the same ride in memory: roster, roles, positions, open SOS.
    const mirrored = await until(() => {
      const room = B.gw.convoys.rooms.get(R.gid);
      return room && room.riders.size === 3 && room.riders.get(uid(R.lead))?.lat === 17.40
        && room.riders.get(uid(pack))?.lat === 17.41 && room.alerts.has(alert.alertId) && room;
    }, 'mirrored room');
    assert.equal(mirrored.riders.get(uid(sweep)).role, 'SWEEPER');
    assert.equal(mirrored.riders.get(uid(R.lead)).role, 'LEAD');
    assert.equal(B.gw.convoys.passive(R.gid), true, 'the live node runs the room while it holds its sockets');

    kill(A);
    await until(() => !B.gw.mirror.linked(), 'B sees the link down');
    // Riders reconnect through the load balancer: now to B.
    const bl = await B.joinRoom(R.lead.token, R.gid);
    const bp = await B.joinRoom(pack.token, R.gid);
    const bs = await B.joinRoom(sweep.token, R.gid);
    const snap = bl.snapshot;
    assert.equal(snap.groupId, R.gid);
    assert.equal(Object.keys(snap.riders).length, 3);
    assert.equal(snap.riders[uid(sweep)].role, 'SWEEPER');
    assert.equal(snap.riders[uid(R.lead)].lat, 17.40);
    assert.ok(snap.activeAlerts.some((a) => a.alertId === alert.alertId), 'open SOS present');
    assert.equal(B.gw.convoys.passive(R.gid), false);
    // Positions continue on B.
    bl.sendJson({ type: 'TELEMETRY', lat: 17.45, lng: 78.45, speedKmh: 55 });
    assert.equal((await bp.next(isUpdateOf(R.lead, (r) => r.lat === 17.45))).rider.lat, 17.45);
    assert.equal((await bs.next(isUpdateOf(R.lead, (r) => r.lat === 17.45))).rider.lat, 17.45);
    // The SOS can still be resolved there (and the DB has exactly one alert).
    bp.sendJson({ type: 'SOS_RESOLVE', alertId: alert.alertId });
    await bl.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === alert.alertId);
    const stored = (await B.gw.repo.listAlerts(R.gid, { includeResolved: true })).filter((a) => a.clientId === 'sos-fo-1');
    assert.equal(stored.length, 1);
    assert.equal(stored[0].resolved, true);
    for (const w of [bl, bp, bs, wl, ws, wp]) w.close();
  } finally { await done(A, B); }
});

test('durable SOS: the echo waits for the DB write and the peer; a resend to the other node after a crash is one alert, confirmed', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'sos', 2);
    const [p1, p2] = R.members;
    const wl = await A.joinRoom(R.lead.token, R.gid);
    const w1 = await A.joinRoom(p1.token, R.gid);
    await until(() => B.gw.convoys.rooms.get(R.gid), 'room on B');

    // 1) Linked: the store is slow; the sender's echo comes only after it and after B has the alert.
    const addAlert = A.gw.repo.addAlert.bind(A.gw.repo);
    let storedAt = 0;
    A.gw.repo.addAlert = async (...a) => { await sleep(150); const r = await addAlert(...a); storedAt = Date.now(); return r; };
    const sentAt = Date.now();
    w1.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'sos-d-1' });
    const echo = await w1.next((m) => m.type === 'ALERT');
    const echoAt = Date.now();
    assert.ok(storedAt > 0 && echoAt >= storedAt, 'echo after the DB write');
    assert.ok(echoAt - sentAt >= 150);
    assert.ok(B.gw.convoys.rooms.get(R.gid).alerts.has(echo.alert.alertId), 'peer has it before the echo');
    await wl.next((m) => m.type === 'ALERT' && m.alert.alertId === echo.alert.alertId);

    // 2) The live node dies right after storing an SOS, before the peer hears of it.
    A.gw.repo.addAlert = async (...a) => { const r = await addAlert(...a); kill(A); return r; };
    const w2 = await A.joinRoom(p2.token, R.gid);
    w2.sendJson({ type: 'SOS', lat: 17.5, lng: 78.5, clientId: 'sos-d-2' });
    await w2.closed;
    assert.equal(w2.inbox.filter((m) => m.type === 'ALERT').length, 0, 'no echo from a dead node');
    await until(() => !B.gw.mirror.linked(), 'link down');
    // The phone resends with the same clientId, now through B.
    const bl = await B.joinRoom(R.lead.token, R.gid);
    const b2 = await B.joinRoom(p2.token, R.gid);
    b2.sendJson({ type: 'SOS', lat: 17.5, lng: 78.5, clientId: 'sos-d-2' });
    const conf = await b2.next((m) => m.type === 'ALERT');
    assert.equal(conf.duplicate, true, 'answered as the stored SOS');
    assert.equal(conf.alert.clientId, 'sos-d-2');
    // The group on B hears it (it was never broadcast by the dead node), and it is one alert only.
    const heard = await bl.next((m) => m.type === 'ALERT' && m.alert.alertId === conf.alert.alertId);
    assert.ok(heard);
    b2.sendJson({ type: 'SOS', lat: 17.5, lng: 78.5, clientId: 'sos-d-2' });
    assert.equal((await b2.next((m) => m.type === 'ALERT')).duplicate, true);
    const rows = (await B.gw.repo.listAlerts(R.gid, { includeResolved: true })).filter((a) => a.clientId === 'sos-d-2');
    assert.equal(rows.length, 1, 'no duplicate alert');
    assert.ok(B.gw.convoys.rooms.get(R.gid).alerts.has(conf.alert.alertId));
    for (const w of [wl, w1, w2, bl, b2]) w.close();
  } finally { await done(A, B); }
});

test('durable SOS: a failed DB write still alerts the room but never confirms the sender; the resend stores and confirms it', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'dbf', 1);
    const [p1] = R.members;
    const wl = await A.joinRoom(R.lead.token, R.gid);
    const w1 = await A.joinRoom(p1.token, R.gid);
    const addAlert = A.gw.repo.addAlert.bind(A.gw.repo);
    let fail = true;
    A.gw.repo.addAlert = async (...a) => { if (fail) throw new Error('db down'); return addAlert(...a); };
    w1.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'sos-f-1' });
    const toLead = await wl.next((m) => m.type === 'ALERT');
    await until(() => B.gw.convoys.rooms.get(R.gid)?.alerts.has(toLead.alert.alertId), 'replicated');
    await sleep(100);
    assert.equal(w1.inbox.filter((m) => m.type === 'ALERT' || m.type === 'ERROR').length, 0, 'sender not confirmed');
    // Still failing: the resend is not confirmed either.
    w1.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'sos-f-1' });
    await sleep(150);
    assert.equal(w1.inbox.filter((m) => m.type === 'ALERT').length, 0);
    fail = false;
    w1.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'sos-f-1' });
    const conf = await w1.next((m) => m.type === 'ALERT');
    assert.equal(conf.alert.alertId, toLead.alert.alertId);
    assert.equal((await A.gw.repo.listAlerts(R.gid)).filter((a) => a.clientId === 'sos-f-1').length, 1);
    await until(() => !B.gw.convoys.rooms.get(R.gid).unsaved?.has(toLead.alert.alertId), 'peer knows it is stored');
    // Chat: same rule, the ACK only once stored.
    const addMessage = A.gw.repo.addMessage.bind(A.gw.repo);
    fail = true;
    A.gw.repo.addMessage = async (...a) => { if (fail) throw new Error('db down'); return addMessage(...a); };
    w1.sendJson({ type: 'CHAT', text: 'Need fuel', clientId: 'c-f-1' });
    await wl.next((m) => m.type === 'MESSAGE' && m.message.text === 'Need fuel');
    await sleep(100);
    assert.equal(w1.inbox.filter((m) => m.type === 'ACK' || m.type === 'ERROR').length, 0);
    fail = false;
    w1.sendJson({ type: 'CHAT', text: 'Need fuel', clientId: 'c-f-1' });
    assert.equal((await w1.next((m) => m.type === 'ACK' && m.clientId === 'c-f-1')).duplicate, false);
    assert.equal((await A.gw.repo.listMessages(R.gid)).filter((m) => m.clientId === 'c-f-1').length, 1);
    assert.equal(A.gw.convoys.rooms.get(R.gid).messages.filter((m) => m.clientId === 'c-f-1').length, 1);
    wl.close(); w1.close();
  } finally { await done(A, B); }
});

test('hand-back: a restarted live node is 503 syncing until it has the snapshot, then the web node hands riders back in batches; split riders see and hear each other', async () => {
  const soda = new MemorySoda();
  const A = await node(soda, 'vm1', 'live');
  const B = await node(soda, 'vm2', 'web', { peerUrl: A.mirrorUrl, handbackPerSec: 1, heartbeatMs: 150 });
  A.gw.mirror.setPeer(B.mirrorUrl);
  let A2 = null;
  try {
    await until(() => A.gw.mirror.linked() && A.gw.mirror.state === 'serving', 'link');
    const R = await convoy(A, 'hb', 2);
    const [p1, p2] = R.members;
    const socks = [await A.joinRoom(R.lead.token, R.gid), await A.joinRoom(p1.token, R.gid), await A.joinRoom(p2.token, R.gid)];
    socks[0].sendJson({ type: 'TELEMETRY', lat: 17.3, lng: 78.3 });
    await until(() => B.gw.convoys.rooms.get(R.gid)?.riders.get(uid(R.lead))?.lat === 17.3, 'mirrored');
    kill(A);
    for (const s of socks) s.close();
    const onB = [await B.joinRoom(R.lead.token, R.gid), await B.joinRoom(p1.token, R.gid), await B.joinRoom(p2.token, R.gid)];
    onB[0].sendJson({ type: 'TELEMETRY', lat: 17.31, lng: 78.31 });
    await onB[1].next(isUpdateOf(R.lead, (r) => r.lat === 17.31));
    // B's live health stays 200 (it is the backup the balancer may use).
    assert.equal((await fetch(`${B.base}/health/live`)).status, 200);

    // VM1 comes back (new process): syncing (503) until B's snapshot is applied.
    A2 = await node(soda, 'vm1', 'live', { peerUrl: B.mirrorUrl, startupWaitMs: 2000 });
    B.gw.mirror.setPeer(A2.mirrorUrl);
    const h0 = await fetch(`${A2.base}/health/live`);
    const b0 = await h0.json();
    assert.equal(h0.status, 503);
    assert.equal(b0.state, 'syncing');
    assert.equal(b0.ok, false);
    assert.equal(b0.node, 'vm1');
    assert.equal(b0.role, 'live');
    await until(async () => (await fetch(`${A2.base}/health/live`)).status === 200, 'A2 serving');
    const room = A2.gw.convoys.rooms.get(R.gid);
    assert.ok(room, 'snapshot applied before serving');
    assert.equal(room.riders.get(uid(R.lead)).lat, 17.31, 'fresh state from B');
    const body = await (await fetch(`${A2.base}/health/live`)).json();
    assert.deepEqual(Object.keys(body).sort(), ['cap', 'eventLoopLagMs', 'liveRiders', 'mirror', 'node', 'ok', 'role', 'state'].sort());
    assert.equal(body.mirror.connected, true);
    assert.equal(body.liveRiders, 3, 'riders live on B are counted');

    // B hands back: RECONNECT {reason handback}, one rider per tick here (batches), with jitter.
    const rc = await Promise.all(onB.map((w) => w.next((m) => m.type === 'RECONNECT', 4000).then((m) => ({ m, at: Date.now() }))));
    for (const { m } of rc) {
      assert.equal(m.reason, 'handback');
      assert.ok(Number.isInteger(m.delayMs) && m.delayMs >= 0 && m.delayMs <= 3000);
    }
    const ats = rc.map((x) => x.at).sort((a, b) => a - b);
    assert.ok(ats[2] - ats[0] >= 200, 'not all at once');

    // Rider 1 moves to A2, rider 2 is still on B: they see each other's positions and chat.
    const a1 = await A2.joinRoom(p1.token, R.gid);
    const b2 = onB[2];
    await until(() => B.gw.mirror.peer?.rooms.has(R.gid) && A2.gw.mirror.peer?.rooms.has(R.gid), 'both nodes hold sockets');
    a1.sendJson({ type: 'TELEMETRY', lat: 17.5, lng: 78.5 });
    await b2.next(isUpdateOf(p1, (r) => r.lat === 17.5));
    b2.sendJson({ type: 'TELEMETRY', lat: 17.6, lng: 78.6 });
    await a1.next(isUpdateOf(p2, (r) => r.lat === 17.6));
    b2.sendJson({ type: 'CHAT', text: 'from B side', clientId: 'hb-c1' });
    assert.equal((await a1.next((m) => m.type === 'MESSAGE')).message.text, 'from B side');
    await b2.next((m) => m.type === 'ACK' && m.clientId === 'hb-c1');
    a1.sendJson({ type: 'CHAT', text: 'from A side' });
    assert.equal((await b2.next((m) => m.type === 'MESSAGE' && m.message.text === 'from A side')).message.senderId, uid(p1));
    // Voice across the split: rider 1 talks on A2, rider 2 on B hears it.
    const { encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END } = require('../src/ws');
    const heard = [];
    b2.on('message', (d, bin) => { if (bin) heard.push(decodeVoice(Buffer.from(d))); });
    a1.send(encodeVoice(VOICE_START, { sampleRate: 16000 }));
    await sleep(80);
    a1.send(encodeVoice(VOICE_FRAME, { seq: 1 }, Buffer.alloc(320, 7)));
    a1.send(encodeVoice(VOICE_END, {}));
    await until(() => heard.some((v) => v.kind === VOICE_END), 'voice relayed');
    assert.ok(heard.some((v) => v.kind === VOICE_FRAME && v.payload.length === 320 && v.header.from === uid(p1)));
    // While p1 holds the floor on A2, a rider on B gets VOICE_BUSY... (floor ended above, so it is free again).
    assert.equal(A2.gw.mirror.state, 'serving');
    // Everyone ends up on A2.
    const a2 = await A2.joinRoom(p2.token, R.gid);
    const al = await A2.joinRoom(R.lead.token, R.gid);
    assert.equal(Object.keys(al.snapshot.riders).length, 3);
    for (const w of [...onB, a1, a2, al]) w.close();
  } finally { await done(A, B, A2); }
});

test('mirror link drop and recovery: events sent while it was down arrive once, nothing is duplicated', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'drop', 1);
    const [p1] = R.members;
    const wl = await A.joinRoom(R.lead.token, R.gid);
    const b1 = await B.joinRoom(p1.token, R.gid); // a rider on B (hand-back window)
    await until(() => A.gw.mirror.peer?.rooms.has(R.gid), 'A knows B has a socket');
    wl.sendJson({ type: 'CHAT', text: 'before drop', clientId: 'd-1' });
    await b1.next((m) => m.type === 'MESSAGE' && m.message.text === 'before drop');
    await sleep(300); // acknowledged by heartbeats
    const seq0 = A.gw.mirror.seq;
    A.gw.mirror.link.ws.terminate();
    await until(() => !A.gw.mirror.linked(), 'down');
    wl.sendJson({ type: 'CHAT', text: 'during drop', clientId: 'd-2' });
    await wl.next((m) => m.type === 'ACK' && m.clientId === 'd-2'); // peer down: acked after the DB write, no wait
    assert.ok(A.gw.mirror.seq > seq0);
    await until(() => A.gw.mirror.linked() && B.gw.mirror.linked(), 'relinked');
    await b1.next((m) => m.type === 'MESSAGE' && m.message.text === 'during drop', 3000);
    await sleep(300);
    const texts = b1.inbox.filter((m) => m.type === 'MESSAGE').map((m) => m.message.text);
    assert.equal(texts.filter((x) => x === 'before drop').length, 0, 'not repeated');
    assert.equal(texts.filter((x) => x === 'during drop').length, 0, 'delivered once (already taken above)');
    const room = B.gw.convoys.rooms.get(R.gid);
    assert.equal(room.messages.filter((m) => m.text === 'during drop').length, 1);
    assert.equal(room.messages.filter((m) => m.text === 'before drop').length, 1);
    // A second drop/recovery replays nothing already seen.
    const dupes0 = B.gw.mirror.stats.dupes;
    B.gw.mirror.link.ws.terminate();
    await until(() => A.gw.mirror.linked() && B.gw.mirror.linked(), 'relinked again');
    await sleep(200);
    assert.equal(B.gw.mirror.stats.dupes - dupes0, 0);
    assert.equal(b1.inbox.filter((m) => m.type === 'MESSAGE').length, 0);
    wl.close(); b1.close();
  } finally { await done(A, B); }
});

test('ack timeout: a peer that never acknowledges delays the SOS echo by at most MIRROR_ACK_TIMEOUT_MS; a dead peer not at all', async () => {
  const { A, B } = await pair({ ackTimeoutMs: 300 });
  try {
    const R = await convoy(A, 'ack', 1);
    const w1 = await A.joinRoom(R.members[0].token, R.gid);
    B.gw.mirror._onEvent = () => {}; // alive (heartbeats) but never acknowledges
    let t0 = Date.now();
    w1.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'ack-1' });
    await w1.next((m) => m.type === 'ALERT');
    let took = Date.now() - t0;
    assert.ok(took >= 280 && took < 1500, `waited ${took} ms`);
    kill(B);
    await until(() => !A.gw.mirror.linked(), 'down');
    const w2 = await A.joinRoom(R.lead.token, R.gid);
    t0 = Date.now();
    w2.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'ack-2' });
    await w2.next((m) => m.type === 'ALERT' && m.alert.clientId === 'ack-2');
    took = Date.now() - t0;
    assert.ok(took < 250, `no wait with the peer down (${took} ms)`);
    w1.close(); w2.close();
  } finally { await done(A, B); }
});

test('LIVE_RIDER_CAP: riders live on both nodes count; new riders get 503 SERVER_BUSY (HTTP and socket JOIN), riders in a ride and SOS never', async () => {
  const { A, B } = await pair({ liveRiderCap: 2 }, { liveRiderCap: 2 });
  try {
    const R = await convoy(A, 'cap', 2);
    const [p1, idle] = R.members;
    const wl = await A.joinRoom(R.lead.token, R.gid);
    const b1 = await B.joinRoom(p1.token, R.gid);
    await until(() => A.gw.mirror.liveSet().size === 2 && B.gw.mirror.liveSet().size === 2, 'live riders shared');
    assert.equal((await (await fetch(`${A.base}/health/live`)).json()).liveRiders, 2);
    // A new rider: create and join refused on either node.
    const newbie = await A.register('New Rider', 'new-cap@two.test');
    const c1 = await A.api('POST', '/convoys', { name: 'Another ride' }, newbie.token);
    assert.equal(c1.status, 503);
    assert.equal(c1.json.code, 'SERVER_BUSY');
    assert.equal(c1.json.error, 'Server busy, try in a few minutes');
    const j1 = await B.api('POST', '/convoys/join', { code: R.c.joinCode }, newbie.token);
    assert.equal(j1.status, 503);
    assert.equal(j1.json.code, 'SERVER_BUSY');
    // A member not live for a long time is a new live rider for the cap: socket JOIN refused.
    const room = A.gw.convoys.rooms.get(R.gid);
    const old = Date.now() - 3600000;
    room.riders.set(uid(idle), { ...room.riders.get(uid(idle)), lastSeenEpochMs: old, joinedAt: old, presenceAt: old });
    const wi = await A.connect(idle.token);
    wi.sendJson({ type: 'JOIN', groupId: R.gid });
    const err = await wi.next((m) => m.type === 'ERROR');
    assert.equal(err.code, 503);
    assert.equal(err.reason, 'SERVER_BUSY');
    // Riders already in a ride: a second socket, a re-join by code, all fine.
    const wl2 = await A.joinRoom(R.lead.token, R.gid);
    assert.equal((await A.api('POST', '/convoys/join', { code: R.c.joinCode }, p1.token)).status, 200);
    // SOS is never refused (cap reached).
    b1.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'cap-sos' });
    assert.equal((await wl.next((m) => m.type === 'ALERT')).alert.clientId, 'cap-sos');
    // A member with an open SOS rejoins even when idle.
    room.alerts.set('SOS-cap-idle', { alertId: 'SOS-cap-idle', userId: uid(idle), userName: 'x', lat: 0, lng: 0, alertType: 'EMERGENCY', timestamp: Date.now(), resolved: false });
    wi.sendJson({ type: 'JOIN', groupId: R.gid });
    await wi.next((m) => m.type === 'SNAPSHOT');
    for (const w of [wl, wl2, b1, wi]) w.close();
  } finally { await done(A, B); }
});

test('DB writes: a 10-rider room is written as one room snapshot per interval, not one write per rider', async () => {
  const t = await boot({ soda: new MemorySoda() });
  try {
    const R = await convoy(t, 'dbw', 9);
    const riders = [R.lead, ...R.members];
    const socks = [];
    for (const r of riders) socks.push(await t.joinRoom(r.token, R.gid));
    await sleep(200); // join-time writes and presence flushes settle
    t.gw.convoys.persistIntervalMs = 1000; // RIDER_PERSIST_INTERVAL_MS scaled: 15 s -> 1 s, 30 s -> 2 s
    const counts = new Map();
    const soda = t.gw.soda;
    for (const fn of ['insert', 'replace', 'upsertBy', 'compareAndReplace']) {
      const orig = soda[fn].bind(soda);
      soda[fn] = (coll, ...rest) => { counts.set(coll, (counts.get(coll) || 0) + 1); return orig(coll, ...rest); };
    }
    const t0 = Date.now();
    let k = 0;
    while (Date.now() - t0 < 2050) {
      k++;
      socks.forEach((s, i) => s.sendJson({ type: 'TELEMETRY', lat: 17 + i / 100 + k / 10000, lng: 78, speedKmh: 40 }));
      await sleep(500);
    }
    await sleep(100);
    const snapWrites = (counts.get('room_snapshots') || 0);
    const riderWrites = counts.get('convoy_riders') || 0;
    assert.equal(riderWrites, 0, 'no per-rider writes for telemetry');
    assert.ok(snapWrites >= 1 && snapWrites <= 3, `room snapshot writes: ${snapWrites}`);
    assert.equal(counts.get('convoys') || 0, 0, 'convoy document not rewritten for telemetry');
    // Restore from the database (both nodes restarted): the latest positions come back.
    await t.gw.convoys.flushRoom(t.gw.convoys.rooms.get(R.gid));
    t.gw.convoys.rooms.delete(R.gid);
    const again = await t.gw.convoys.getRoom(R.gid);
    assert.equal(again.riders.size, 10);
    assert.ok(Math.abs(again.riders.get(uid(R.lead)).lat - (17 + k / 10000)) < 1e-9);
    for (const s of socks) s.close();
  } finally { await t.gw.shutdown(); }
});

test('mirror auth: a peer with the wrong MIRROR_KEY is refused; frames are encrypted and replays rejected', async () => {
  const soda = new MemorySoda();
  const A = await node(soda, 'vm1', 'live');
  const C = await node(soda, 'vm3', 'web', { peerUrl: A.mirrorUrl, key: 'another-key-another-key-another-key-0000' });
  try {
    await until(() => A.gw.mirror.stats.authFailed > 0, 'refused');
    await sleep(200);
    assert.equal(A.gw.mirror.linked(), false);
    assert.equal(C.gw.mirror.linked(), false);
    // A raw client that does not know the key.
    const raw = new WebSocket(A.mirrorUrl);
    const chal = await new Promise((r) => raw.once('message', (d) => r(JSON.parse(d.toString()))));
    assert.equal(chal.t, 'CHAL');
    raw.send(JSON.stringify({ t: 'AUTH', node: 'x', n: 'a'.repeat(64), mac: 'b'.repeat(64) }));
    const code = await new Promise((r) => raw.once('close', (c) => r(c)));
    assert.equal(code, 4401);
    // Session crypto: what one side seals only the other side opens, once.
    const fakeWs = { readyState: 1, send() {} };
    const m = { key: KEY };
    const d = new Link(m, fakeWs, true), l = new Link(m, fakeWs, false);
    const nS = Buffer.alloc(32, 1), nC = Buffer.alloc(32, 2);
    d.keys(nS, nC); l.keys(nS, nC);
    const sealed = d.seal(Buffer.from('hello'));
    assert.ok(!sealed.includes(Buffer.from('hello')));
    assert.equal(l.open(sealed).toString(), 'hello');
    assert.throws(() => l.open(sealed), /replayed/);
    const tampered = Buffer.from(d.seal(Buffer.from('x'))); tampered[tampered.length - 1] ^= 1;
    assert.throws(() => l.open(tampered));
    // No mirror without a long enough key.
    const { Mirror } = require('../src/mirror');
    assert.throws(() => new Mirror({ convoys: A.gw.convoys, listenHost: '127.0.0.1', key: 'short' }), /MIRROR_KEY/);
  } finally { await done(A, C); }
});

test('single node: /api/health/live is 200 serving with no mirror', async () => {
  const t = await boot({ soda: new MemorySoda() });
  try {
    const r = await fetch(`${t.base}/health/live`);
    assert.equal(r.status, 200);
    const b = await r.json();
    assert.equal(b.ok, true);
    assert.equal(b.state, 'serving');
    assert.equal(b.mirror.connected, false);
    assert.equal(b.cap, 0);
    assert.equal((await fetch(`${t.base}/health`)).status, 200, 'the existing health endpoint is unchanged');
  } finally { await t.gw.shutdown(); }
});

test('graceful shutdown: final state to the peer, then RECONNECT {reason shutdown} to every socket', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'shut', 1);
    const wl = await A.joinRoom(R.lead.token, R.gid);
    const w1 = await A.joinRoom(R.members[0].token, R.gid);
    wl.sendJson({ type: 'TELEMETRY', lat: 18.1, lng: 79.1 });
    await w1.next(isUpdateOf(R.lead));
    const p = A.gw.shutdown();
    const [m1, m2] = await Promise.all([wl.next((m) => m.type === 'RECONNECT'), w1.next((m) => m.type === 'RECONNECT')]);
    assert.equal(m1.reason, 'shutdown'); assert.equal(m2.reason, 'shutdown');
    assert.ok(m1.delayMs >= 0 && m1.delayMs <= 3000);
    await p;
    A.dead = true;
    assert.equal(B.gw.convoys.rooms.get(R.gid).riders.get(uid(R.lead)).lat, 18.1);
    wl.close(); w1.close();
  } finally { await done(A, B); }
});

test('talk floor across nodes: a rider talking on the web node holds the floor for riders on the live node', async () => {
  const { A, B } = await pair();
  try {
    const { encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END } = require('../src/ws');
    const R = await convoy(A, 'floor', 1);
    const wl = await A.joinRoom(R.lead.token, R.gid);
    const b1 = await B.joinRoom(R.members[0].token, R.gid);
    await until(() => A.gw.mirror.peer?.rooms.has(R.gid) && B.gw.mirror.peer?.rooms.has(R.gid), 'split');
    const got = [];
    wl.on('message', (d, bin) => { if (bin) got.push(decodeVoice(Buffer.from(d))); });
    b1.send(encodeVoice(VOICE_START, { sampleRate: 16000 }));
    await until(() => got.some((v) => v.kind === VOICE_START), 'start relayed');
    b1.send(encodeVoice(VOICE_FRAME, { seq: 1 }, Buffer.alloc(320, 1)));
    await until(() => got.some((v) => v.kind === VOICE_FRAME), 'frame relayed');
    wl.send(encodeVoice(VOICE_START, { sampleRate: 16000 }));
    const busy = await wl.next((m) => m.type === 'VOICE_BUSY');
    assert.equal(busy.speaker, `Rider floor0`);
    b1.send(encodeVoice(VOICE_END, {}));
    await until(() => got.some((v) => v.kind === VOICE_END), 'end relayed');
    wl.send(encodeVoice(VOICE_START, { sampleRate: 16000 }));
    await b1.next((m) => m.type === 'MIC_STATUS' && m.userId === uid(R.lead) && m.isSpeaking === true);
    wl.close(); b1.close();
  } finally { await done(A, B); }
});
