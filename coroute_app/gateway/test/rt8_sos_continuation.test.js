'use strict';
/**
 * Round 8 SOS fan-out continuation on the twin (src/mirror.js SP records, ConvoyManager._storeAlert): the live node
 * announces a new alert to its peer BEFORE storing and fanning it out. If it dies in between, the peer delivers it:
 * room, database (once), its sockets, the SNAPSHOT of riders who reconnect there, the safety network / SMS round.
 * The normal path clears the record and never delivers twice.
 */
process.env.NODE_ENV = 'test';
process.env.RIDER_PERSIST_INTERVAL_MS = '50';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.NET_TICK_MS = '3600000';
process.env.DISCOVERY_TICK_MS = '3600000';

const test = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');

const KEY = 'test-mirror-key-0123456789-abcdefghijklmnop';
const uid = (u) => u.user.userId;

async function node(soda, name, role, extra = {}) {
  const t = await boot({
    soda,
    emergencyFetch: async () => { throw new Error('offline in tests'); },
    mirror: { node: name, role, listenHost: '127.0.0.1', listenPort: 0, key: KEY, ackTimeoutMs: 400, startupWaitMs: 400, heartbeatMs: 100, deadMs: 800,
      reconnectMinMs: 50, reconnectMaxMs: 200, handbackDelayMs: 60000, handbackPerSec: 25, ...extra },
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
async function pair() {
  const soda = new MemorySoda();
  const A = await node(soda, 'vm1', 'live');
  const B = await node(soda, 'vm2', 'web', { peerUrl: A.mirrorUrl });
  A.gw.mirror.setPeer(B.mirrorUrl);
  await until(() => A.gw.mirror.linked() && B.gw.mirror.linked() && A.gw.mirror.state === 'serving', 'link up');
  return { soda, A, B };
}
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
async function done(...nodes) { for (const x of nodes) if (x && !x.dead) await x.gw.shutdown().catch(() => {}); }

async function convoy(t, tag, n = 2) {
  const lead = await t.register(`Lead ${tag}`, `lead-${tag}@rt8.test`);
  const c = (await t.api('POST', '/convoys', { name: `Ride ${tag}` }, lead.token)).json;
  const members = [];
  for (let i = 0; i < n; i++) {
    const m = await t.register(`Rider ${tag}${i}`, `r${i}-${tag}@rt8.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, m.token)).status, 200);
    members.push(m);
  }
  return { gid: c.groupId, lead, members };
}

test('crash between store and fan-out: the twin delivers the SOS (its sockets, snapshot, database once, safety network)', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'cont', 2);
    const [victim, watcher] = R.members;
    const wl = await A.joinRoom(R.lead.token, R.gid);
    const wv = await A.joinRoom(victim.token, R.gid);
    // A rider already on the twin (hand-back window), so the twin has a socket in the room.
    const ww = await B.joinRoom(watcher.token, R.gid);
    await until(() => B.gw.convoys.rooms.get(R.gid)?.riders.size === 3, 'room mirrored');
    // The live node stores the alert (it reaches the database) and then hangs before its fan-out: the process is
    // about to die (the hang stands in for the crash point).
    const realAdd = A.gw.repo.addAlert.bind(A.gw.repo);
    let stored = null;
    A.gw.repo.addAlert = async (gid, alert) => { await realAdd(gid, alert); stored = alert.alertId; return new Promise(() => {}); };
    const raised = [];
    B.gw.convoys.on('emergency', (gid, alert, kind) => { if (kind === 'RAISED') raised.push(alert.alertId); });
    wv.sendJson({ type: 'SOS', lat: 17.41, lng: 78.41, alertType: 'CRASH_OR_EMERGENCY', clientId: 'cont-sos-1' });
    await until(() => stored && B.gw.mirror.sosPend.size === 1, 'the twin holds the pending SOS');
    assert.equal(wl.inbox.filter((m) => m.type === 'ALERT').length, 0, 'the live node never fanned it out');
    assert.equal(ww.inbox.filter((m) => m.type === 'ALERT').length, 0);
    const t0 = Date.now();
    kill(A);
    const alert = (await ww.next((m) => m.type === 'ALERT', 3000)).alert;
    const ms = Date.now() - t0;
    assert.equal(alert.alertId, stored);
    assert.equal(alert.userId, uid(victim));
    assert.ok(ms < 2000, `delivered by the twin ${ms} ms after the crash (dead-link detection ${800} ms)`);
    assert.equal(B.gw.mirror.stats.sosContinued, 1);
    assert.deepEqual(raised, [stored], 'safety network / SMS round started once on the twin');
    // The database has it exactly once (the live node had stored it: not stored again).
    const rows = (await B.gw.repo.listAlerts(R.gid, { includeResolved: true })).filter((a) => a.alertId === stored);
    assert.equal(rows.length, 1);
    // Riders reconnecting to the twin see it in the SNAPSHOT; the victim's resend is a duplicate of the same alert.
    const bl = await B.joinRoom(R.lead.token, R.gid);
    assert.ok(bl.snapshot.activeAlerts.some((a) => a.alertId === stored));
    const bv = await B.joinRoom(victim.token, R.gid);
    bv.sendJson({ type: 'SOS', lat: 17.41, lng: 78.41, alertType: 'CRASH_OR_EMERGENCY', clientId: 'cont-sos-1' });
    const echo = await bv.next((m) => m.type === 'ALERT' && m.duplicate);
    assert.equal(echo.alert.alertId, stored);
    assert.equal((await B.gw.repo.listAlerts(R.gid, { includeResolved: true })).filter((a) => a.clientId === 'cont-sos-1').length, 1);
  } finally { await done(A, B); }
});

test('crash before the store finished: the twin stores the SOS itself, then delivers it', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'nost', 1);
    const [victim] = R.members;
    await A.joinRoom(R.lead.token, R.gid);
    const wv = await A.joinRoom(victim.token, R.gid);
    const wb = await B.joinRoom(R.lead.token, R.gid); // the lead's second phone, on the twin
    await until(() => B.gw.convoys.rooms.get(R.gid)?.riders.size === 2, 'room mirrored');
    A.gw.repo.addAlert = () => new Promise(() => {}); // the database write never completes on A
    wv.sendJson({ type: 'SOS', lat: 17.5, lng: 78.5, clientId: 'nost-sos-1' });
    await until(() => B.gw.mirror.sosPend.size === 1, 'pending on the twin');
    kill(A);
    const a = (await wb.next((m) => m.type === 'ALERT', 3000)).alert;
    assert.equal(a.userId, uid(victim));
    const rows = (await B.gw.repo.listAlerts(R.gid, { includeResolved: true })).filter((x) => x.clientId === 'nost-sos-1');
    assert.equal(rows.length, 1, 'stored by the twin');
  } finally { await done(A, B); }
});

test('normal path: the pending record is cleared by the ALERT event; the twin never delivers twice, even after a later link loss', async () => {
  const { A, B } = await pair();
  try {
    const R = await convoy(A, 'norm', 2);
    const [victim, watcher] = R.members;
    await A.joinRoom(R.lead.token, R.gid);
    const wv = await A.joinRoom(victim.token, R.gid);
    const ww = await B.joinRoom(watcher.token, R.gid);
    await until(() => B.gw.convoys.rooms.get(R.gid)?.riders.size === 3, 'room mirrored');
    wv.sendJson({ type: 'SOS', lat: 17.6, lng: 78.6, clientId: 'norm-sos-1' });
    const first = await ww.next((m) => m.type === 'ALERT');
    await until(() => B.gw.mirror.stats.sosPendingRecv === 1 && B.gw.mirror.sosPend.size === 0, 'cleared by the ALERT event');
    assert.equal(B.gw.mirror.stats.sosPendingCleared, 1);
    kill(A);
    await until(() => !B.gw.mirror.linked(), 'link down');
    await sleep(300);
    assert.equal(B.gw.mirror.stats.sosContinued, 0);
    assert.equal(ww.inbox.filter((m) => m.type === 'ALERT' && m.alert.alertId === first.alert.alertId).length, 0, 'exactly one ALERT');
    assert.equal(A.gw.mirror.stats.sosPendingSent, 1);
  } finally { await done(A, B); }
});
