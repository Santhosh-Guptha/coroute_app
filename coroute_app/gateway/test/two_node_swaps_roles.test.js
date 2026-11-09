'use strict';
/**
 * Two gateways mirrored over localhost (same helpers as two_node_failover.test.js):
 *  - a pending bike / pillion swap ask survives a failover (stored with the replicated meta);
 *  - automatic / merged roles never leave two LEADs (single writer, invariant on merge).
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


const { publicRider } = require('../src/convoys');

test('failover: a pending swap ask made on the live node is answered on the web node after the live node dies', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'swp', 2);
    const [ravi, kiran] = R.members;
    const bikeKiran = A.gw.convoys.rooms.get(R.gid).riders.get(uid(kiran)).vehicleNo;
    const ar = await A.joinRoom(ravi.token, R.gid);
    const ak = await A.joinRoom(kiran.token, R.gid);
    ar.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'BIKES', clientId: 'sw-1' });
    const ask = await ak.next((m) => m.type === 'SWAP_ASK');
    // Replicated to B with the meta (and stored in the shared DB).
    await until(() => B.gw.convoys.rooms.get(R.gid)?.meta.pendingSwaps?.[ask.requestId], 'ask on B');
    assert.equal((await B.gw.repo.getConvoyMeta(R.gid)).pendingSwaps[ask.requestId].fromUserId, uid(ravi));

    kill(A);
    await until(() => !B.gw.mirror.linked(), 'link down');
    const br = await B.joinRoom(ravi.token, R.gid);
    const bk = await B.joinRoom(kiran.token, R.gid);
    bk.sendJson({ type: 'SWAP_ANSWER', requestId: ask.requestId, accept: true, clientId: 'sw-2' });
    const doneMsg = await br.next((m) => m.type === 'SWAP_DONE');
    assert.equal(doneMsg.requestId, ask.requestId);
    assert.equal(B.gw.convoys.rooms.get(R.gid).riders.get(uid(ravi)).vehicleNo, bikeKiran);
    assert.equal((await B.gw.repo.getConvoyMeta(R.gid)).pendingSwaps, undefined, 'answered: gone from the stored meta');
    for (const w of [ar, ak, br, bk]) w.close();
  } finally { await done(A, B); }
});

test('failover: an unanswered ask still expires on the node that took over, and the requester is told once', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'swx', 2);
    const [ravi, kiran] = R.members;
    const ar = await A.joinRoom(ravi.token, R.gid);
    const ak = await A.joinRoom(kiran.token, R.gid);
    ar.sendJson({ type: 'SWAP_REQUEST', withUserId: uid(kiran), kind: 'BIKES', clientId: 'sx-1' });
    const ask = await ak.next((m) => m.type === 'SWAP_ASK');
    const roomB = await until(() => { const r = B.gw.convoys.rooms.get(R.gid); return r?.swaps?.has(ask.requestId) && r; }, 'ask adopted on B');
    // B does not own the room: its timer does not tell anyone.
    assert.equal(B.gw.convoys.passive(R.gid), true);
    kill(A);
    await until(() => !B.gw.mirror.linked(), 'link down');
    const br = await B.joinRoom(ravi.token, R.gid);
    // The 2 minutes are over (moved forward here instead of waiting).
    const p = roomB.swaps.get(ask.requestId);
    p.expiresAt = Date.now() - 1;
    roomB.meta.pendingSwaps[ask.requestId].expiresAt = p.expiresAt;
    B.gw.convoys._swapsOf(roomB, Date.now());
    const res = await br.next((m) => m.type === 'SWAP_RESULT' && m.requestId === ask.requestId);
    assert.equal(res.expired, true);
    assert.equal(roomB.swaps.size, 0);
    await sleep(50);
    assert.equal(br.inbox.filter((m) => m.type === 'SWAP_RESULT').length, 0, 'told once (no second result)');
    for (const w of [ar, ak, br]) w.close();
  } finally { await done(A, B); }
});

test('two leads from a split: the merged state keeps the earlier lead on both nodes', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'lead', 2);
    const [asha, kiran] = R.members;
    const wl = await A.joinRoom(R.lead.token, R.gid);
    wl.sendJson({ type: 'ROLE_SET', userId: uid(asha), role: 'LEAD', clientId: 'l-1' });
    await wl.next((m) => m.type === 'ACK' && m.clientId === 'l-1');
    const roomA = A.gw.convoys.rooms.get(R.gid);
    const roomB = await until(() => { const r = B.gw.convoys.rooms.get(R.gid); return r?.riders.get(uid(asha))?.role === 'LEAD' && r; }, 'role on B');
    // During a split B (wrongly) made Kiran lead later and replicates it.
    await sleep(5);
    const next = B.gw.convoys._applyRole(roomB, uid(kiran), 'LEAD');
    B.gw.mirror.local(R.gid, { type: 'RIDER_UPDATE', rider: publicRider(next) });
    // A (owner of the room) restores one lead and announces it; B follows.
    const fixMsg = await wl.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(kiran) && m.rider.role === 'PACK');
    assert.equal(fixMsg.rider.role, 'PACK');
    const leads = (room) => [...room.riders.values()].filter((r) => r.role === 'LEAD').map((r) => r.userId);
    assert.deepEqual(leads(roomA), [uid(asha)]);
    await until(() => JSON.stringify(leads(roomB)) === JSON.stringify([uid(asha)]), 'B has one lead');
    wl.close();
  } finally { await done(A, B); }
});
