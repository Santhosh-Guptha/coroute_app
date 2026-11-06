'use strict';
/**
 * Public ride on two gateway nodes (src/mirror.js extension 'pr'): the coarse index, preferences,
 * contact requests, blocks and road warnings made on one node are on the other; a restarted peer gets
 * them in the snapshot (XS). Riders split across the nodes see each other's public rides and talk.
 */
process.env.NODE_ENV = 'test';
process.env.PUBLIC_RIDE_TICK_MS = '3600000';
const test = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { publicRideOf } = require('../src/public_ride_settings');

const KEY = 'test-mirror-key-0123456789-abcdefghijklmnop';
const uid = (u) => u.user.userId;

async function node(soda, name, role, extra = {}) {
  const t = await boot({
    soda,
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
async function sock(t, token, gid) {
  const ws = await t.connect(token);
  await ws.next((m) => m.type === 'HELLO');
  ws.sendJson({ type: 'JOIN', groupId: gid, caps: ['net1', 'pubride1'] });
  await ws.next((m) => m.type === 'SNAPSHOT');
  return ws;
}
const place = (t, gid, u, lat, lng, heading, speedKmh) => t.gw.convoys.patchRider(t.gw.convoys.rooms.get(gid), uid(u), { lat, lng, heading, speedKmh });

test('two nodes: index, prefs, requests, blocks and road warnings replicate; a restarted peer gets them in the snapshot', async () => {
  const soda = new MemorySoda();
  const A = await node(soda, 'vm1', 'live');
  let B = await node(soda, 'vm2', 'web', { peerUrl: A.mirrorUrl });
  A.gw.mirror.setPeer(B.mirrorUrl);
  try {
    await until(() => A.gw.mirror.linked() && B.gw.mirror.linked(), 'link up');
    // Host ride on vm1 (public), viewer ride on vm2 (not public, "Show public rides near me").
    const host = await A.register('Host Rider', 'host@pr2.test');
    const hc = (await A.api('POST', '/convoys', { name: 'Coast Ride' }, host.token)).json;
    const viewer = await B.register('View Rider', 'view@pr2.test');
    await until(() => B.gw.convoys.rooms.has(hc.groupId), 'room mirrored');
    const vc = (await B.api('POST', '/convoys', { name: 'Solo' }, viewer.token)).json;
    const hws = await sock(A, host.token, hc.groupId);
    const vws = await sock(B, viewer.token, vc.groupId);
    hws.sendJson({ type: 'CONFIG', publicRide: { on: true, radiusKm: 25 } });
    await hws.next((m) => m.type === 'CONFIG');
    const rideId = publicRideOf(A.gw.convoys.rooms.get(hc.groupId).meta.publicRide).id;
    await until(() => publicRideOf(B.gw.convoys.rooms.get(hc.groupId)?.meta.publicRide).id === rideId, 'meta replicated');
    place(A, hc.groupId, host, 12.95, 80.25, 0, 50);
    place(B, vc.groupId, viewer, 12.90, 80.25, 0, 50);
    vws.sendJson({ type: 'PR_PREFS', showNearby: true, radiusKm: 10, roadWarnings: true });
    await vws.next((m) => m.type === 'PR_PREFS_OK');
    await until(() => A.gw.publicRides.prefs.get(uid(viewer))?.showNearby === true, 'prefs replicated');
    // vm1 runs the host's room: its entry reaches vm2 (vm2 never computes it: the room is passive there).
    await until(() => B.gw.mirror.peer?.rooms.has(hc.groupId), 'peer rooms known');
    B.gw.publicRides.tick();
    assert.equal(B.gw.publicRides.index.has(rideId), false);
    A.gw.publicRides.tick();
    const e = await until(() => B.gw.publicRides.index.get(rideId), 'index replicated');
    assert.equal(e.local, false);
    assert.equal(e.label, 'Rider');
    assert.deepEqual(Object.keys(e).sort(), ['at', 'cell', 'destRegion', 'gid', 'heading', 'hostId', 'label', 'lat', 'lng', 'local', 'radiusKm', 'rideId', 'riders'].sort());
    // The viewer on vm2 sees it and asks; the host on vm1 gets the request and accepts there.
    B.gw.publicRides.tick();
    const list = await vws.next((m) => m.type === 'PUBLIC_RIDES');
    assert.deepEqual(list.rides.map((r) => r.rideId), [rideId]);
    vws.sendJson({ type: 'PR_CONTACT', rideId, kind: 'HI', quick: 'HI' });
    const sent = await vws.next((m) => m.type === 'PR_SENT');
    const req = await hws.next((m) => m.type === 'PR_REQUEST');
    assert.equal(req.requestId, sent.requestId);
    await until(() => A.gw.publicRides.requests.has(sent.requestId), 'request replicated');
    hws.sendJson({ type: 'PR_REPLY', requestId: sent.requestId, action: 'ACCEPT' });
    const up = await vws.next((m) => m.type === 'PR_UPDATE');
    assert.equal(up.state, 'ACCEPTED');
    await until(() => B.gw.publicRides.channels.has(up.channelId), 'channel replicated');
    // A road warning from vm1 and a block on vm1 are on vm2.
    hws.sendJson({ type: 'ROAD_WARN', kind: 'ANIMALS' });
    const w = await hws.next((m) => m.type === 'ROAD_WARN_SENT');
    await until(() => B.gw.publicRides.warnings.has(w.warnId), 'warning replicated');
    hws.sendJson({ type: 'PR_BLOCK', ref: up.channelId });
    await hws.next((m) => m.type === 'PR_BLOCK_OK');
    await until(() => B.gw.publicRides.blocked(uid(host), uid(viewer)), 'block replicated');
    // vm2 restarts: the snapshot from vm1 carries the public ride state.
    vws.close();
    await B.gw.shutdown().catch(() => {});
    B = await node(soda, 'vm2', 'web', { peerUrl: A.mirrorUrl });
    A.gw.mirror.setPeer(B.mirrorUrl);
    await until(() => B.gw.mirror.linked() && B.gw.mirror.snapshotApplied, 'relinked with snapshot', 6000);
    const pr2 = B.gw.publicRides;
    await until(() => pr2.index.has(rideId) && pr2.warnings.has(w.warnId) && pr2.blocked(uid(host), uid(viewer)) && pr2.requests.has(sent.requestId), 'snapshot state');
    assert.equal(pr2.prefs.get(uid(viewer)).roadWarnings, true);
    hws.close();
  } finally {
    for (const t of [A, B]) await t.gw.shutdown().catch(() => {});
  }
});
