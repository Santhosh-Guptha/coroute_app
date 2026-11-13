'use strict';
/**
 * Round 10 offline link bridge (src/mesh_bridge.js): the ride key, capability map, frames forwarded by a bridge phone
 * (positions with the via-bridge flag, direct wins, SOS stored like any SOS and deduplicated by clientId, replay and
 * outsider frames refused, the admin switch keeps SOS), and the wire format shared with the app
 * (lib/domain/mesh/mesh_frame.dart: the vectors below were sealed by the Dart code).
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { boot, sleep } = require('./_helpers');
const { shortId, rideKey, groupTag, openFrame, decodeSos, decodePos, meshSecret, VIA_BRIDGE_MS } = require('../src/mesh_bridge');
const { FEATURES } = require('../src/ws');
const RL = require('../src/ws_limits');

// Sealed by lib/domain/mesh (key = bytes 0..31): an SOS and a position from 'u_ravi'.
const DART_KEY = Buffer.from([...Array(32).keys()]);
const DART_SOS = 'c5213e51006ff8bc7d00000007000000016b49d20008060000000502a7b00bfa68c361b99f74856cefda22966b9af5cdc89da49d45e29e8dee81d5b9e01506943ce60650eab3e7bff22a1a205262590d64a1e7b5d14f341373844673c21762206905992695ecd8929fb0086068bdc9f8c4d4c3a30737d6201b6e8993fcc328c8ae';
const DART_POS = 'c5213e51026ff8bc7d00000007000000026b49d200050500000000800000800000e8c025aff414d83c6fadf9bc9389ac3cb9688d911155f89469871947b58101455c2e38';

/** Test-side sealer with the app's layout (header 33 bytes, AAD = first 22, AES-256-GCM, 16-byte tag). */
function seal(key, { cls, origin, boot: b = 1, seq, t = Math.floor(Date.now() / 1000), ttl = 4, payload, proxied = false }) {
  const h = Buffer.alloc(33);
  h[0] = 0xc5; h[1] = 0x21; h.writeUInt16BE(groupTag(key), 2); h[4] = (cls & 7) | (proxied ? 8 : 0);
  h.writeUInt32BE(origin >>> 0, 5); h.writeUInt32BE(b >>> 0, 9); h.writeUInt32BE(seq >>> 0, 13); h.writeUInt32BE(t >>> 0, 17);
  h[21] = ttl; h[22] = ttl; h.writeUInt32BE(origin >>> 0, 23); h[27] = 0x80; h[30] = 0x80;
  const nonce = Buffer.alloc(12); nonce.writeUInt32BE(origin >>> 0, 0); nonce.writeUInt32BE(b >>> 0, 4); nonce.writeUInt32BE(seq >>> 0, 8);
  const c = crypto.createCipheriv('aes-256-gcm', key, nonce);
  c.setAAD(h.subarray(0, 22));
  const ct = Buffer.concat([c.update(payload), c.final()]);
  return Buffer.concat([h, ct, c.getAuthTag()]).toString('base64');
}
const lp = (s) => { const b = Buffer.from(s, 'utf8'); return Buffer.concat([Buffer.from([b.length]), b]); };
function sosPayload({ clientId, lat = 17.4, lng = 78.4, type = 0, resolved = false, auto = true }) {
  const head = Buffer.alloc(20);
  head[0] = 0x01; head[1] = (auto ? 1 : 0) | (resolved ? 2 : 0); head[2] = type;
  head.writeInt32BE(Math.round(lat * 1e6), 3); head.writeInt32BE(Math.round(lng * 1e6), 7);
  head.writeUInt32BE(Math.floor(Date.now() / 1000), 11);
  return Buffer.concat([head, lp(auto ? 'CRASH_AUTO' : 'MANUAL'), lp(clientId), lp(''), lp('Ravi')]);
}
function posPayload({ lat = 17.41, lng = 78.42, speedKmh = 54, battery = 55 }) {
  const p = Buffer.alloc(19);
  p[0] = 0x20; p.writeInt32BE(Math.round(lat * 1e5), 1); p.writeInt32BE(Math.round(lng * 1e5), 5);
  p.writeUInt16BE(Math.round(speedKmh / 0.36), 9); p.writeUInt16BE(90, 11); p[13] = battery; p[14] = 0; p.writeUInt16BE(0xffff, 15); p.writeUInt16BE(0, 17);
  return p;
}

let env;
before(async () => { env = await boot(); });
after(async () => { await env.gw.shutdown(); });

let seq = 0;
async function ride(n, name) {
  const users = [];
  for (let i = 0; i < n; i++) users.push(await env.register(`${name} ${i}`, `mesh-r10-${++seq}@coroute.test`));
  const c = (await env.api('POST', '/convoys', { name: `${name} ride` }, users[0].token)).json;
  for (const u of users.slice(1)) await env.api('POST', '/convoys/join', { code: c.joinCode }, u.token);
  return { users, groupId: c.groupId };
}
async function keyOf(ws) {
  ws.sendJson({ type: 'MESH_HELLO', caps: 0x07 });
  const k = await ws.next((m) => m.type === 'MESH_KEY');
  return Buffer.from(k.key, 'base64');
}

test('wire format: Dart-sealed frames open in Node; short ids match the app', () => {
  assert.ok(FEATURES.includes('mesh1'));
  assert.equal(shortId('u_ravi'), 0x6ff8bc7d);
  assert.equal(shortId('rider-1'), 0x751f7b3d);
  assert.equal(groupTag(DART_KEY), 0x3e51);
  const f = openFrame(DART_KEY, 0x3e51, Buffer.from(DART_SOS, 'hex'));
  assert.ok(f);
  assert.deepEqual([f.cls, f.origin, f.boot, f.seq, f.t, f.initialTtl, f.ttl], [0, 0x6ff8bc7d, 7, 1, 1800000000, 8, 6]);
  const s = decodeSos(f.payload);
  assert.deepEqual([s.clientId, s.alertType, s.auto, s.resolved, s.source, s.linkToken, s.name, s.accuracyM, s.speedKmh, s.heading],
    ['u_ravi-1800000000000', 'CRASH', true, false, 'CRASH_AUTO', 'abcdefghijklmnopqrstuv', 'Ravi', 8, 42, 271]);
  assert.ok(Math.abs(s.lat - 17.385044) < 1e-6);
  const p = decodePos(openFrame(DART_KEY, 0x3e51, Buffer.from(DART_POS, 'hex')).payload);
  assert.deepEqual([p.speedKmh, p.heading, p.batteryLevel, p.isCharging, p.fuelUsableKm, p.fixAgeSec], [58.3, 90, 64, true, null, 2]);
  const bad = Buffer.from(DART_SOS, 'hex'); bad[40] ^= 1;
  assert.equal(openFrame(DART_KEY, 0x3e51, bad), null, 'tampered');
  assert.equal(openFrame(Buffer.alloc(32, 9), groupTag(Buffer.alloc(32, 9)), Buffer.from(DART_SOS, 'hex')), null, 'other ride');
  assert.equal(RL.classOf('MESH_BRIDGE'), 'safety', 'a bridge message can carry an SOS: never dropped by the generic limiter');
});

test('MESH_HELLO: the ride key (per group and ride) and the room capability map', async () => {
  const { users, groupId } = await ride(2, 'Caps');
  const [a, b] = await Promise.all(users.map((u) => env.joinRoom(u.token, groupId)));
  const ka = await keyOf(a);
  assert.equal(ka.length, 32);
  const room = await env.gw.convoys.getRoom(groupId);
  assert.deepEqual(ka, rideKey(meshSecret(), groupId, room.meta.createdAtEpochMs || 0));
  const capsOnB = await b.next((m) => m.type === 'MESH_CAPS');
  assert.equal(capsOnB.caps[users[0].user.userId], 7);
  b.sendJson({ type: 'MESH_HELLO', caps: 0x03 });
  assert.deepEqual(Buffer.from((await b.next((m) => m.type === 'MESH_KEY')).key, 'base64'), ka, 'same ride, same key');
  const both = await a.next((m) => m.type === 'MESH_CAPS' && Object.keys(m.caps).length === 2);
  assert.equal(both.caps[users[1].user.userId], 3);
  const other = await ride(1, 'Other');
  const o = await env.joinRoom(other.users[0].token, other.groupId);
  assert.notDeepEqual(await keyOf(o), ka, 'another ride has another key');
  a.close(); b.close(); o.close();
});

test('bridged position: the offline rider shows as connected via the bridge; replay ignored; direct wins', async () => {
  const { users, groupId } = await ride(3, 'Bridge');
  const [a, c] = await Promise.all([env.joinRoom(users[0].token, groupId), env.joinRoom(users[2].token, groupId)]);
  const key = await keyOf(a);
  const offline = users[1].user.userId;
  const frame = seal(key, { cls: 2, origin: shortId(offline), seq: 1, payload: posPayload({ lat: 17.41, lng: 78.42 }) });
  a.sendJson({ type: 'MESH_BRIDGE', f: [frame] });
  const ack = await a.next((m) => m.type === 'MESH_BRIDGE_ACK');
  assert.equal(ack.n, 1);
  const up = await c.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === offline && m.rider.viaBridge);
  assert.equal(up.rider.viaBridge, users[0].user.userId);
  assert.ok(Math.abs(up.rider.lat - 17.41) < 1e-4);
  const room = await env.gw.convoys.getRoom(groupId);
  assert.equal(room.riders.get(offline).presence, 'ONLINE');
  const replays = env.gw.hub.stats.meshReplay;
  a.sendJson({ type: 'MESH_BRIDGE', f: [frame] });
  assert.equal((await a.next((m) => m.type === 'MESH_BRIDGE_ACK')).n, 0);
  assert.equal(env.gw.hub.stats.meshReplay, replays + 1);
  // The rider gets signal back: a direct socket. A bridged copy of its position is no longer applied.
  const b = await env.joinRoom(users[1].token, groupId);
  const wins = env.gw.hub.stats.meshDirectWins;
  a.sendJson({ type: 'MESH_BRIDGE', f: [seal(key, { cls: 2, origin: shortId(offline), seq: 2, payload: posPayload({ lat: 17.5 }) })] });
  await a.next((m) => m.type === 'MESH_BRIDGE_ACK');
  assert.equal(env.gw.hub.stats.meshDirectWins, wins + 1);
  assert.ok(Math.abs(room.riders.get(offline).lat - 17.41) < 1e-4, 'not doubled / not overwritten by the bridge');
  a.close(); b.close(); c.close();
});

test('bridged presence falls back to NO_SIGNAL when the bridge stops hearing the rider', async () => {
  const { users, groupId } = await ride(2, 'Sweep');
  const a = await env.joinRoom(users[0].token, groupId);
  const key = await keyOf(a);
  const offline = users[1].user.userId;
  a.sendJson({ type: 'MESH_BRIDGE', f: [seal(key, { cls: 2, origin: shortId(offline), seq: 1, payload: posPayload({}) })] });
  await a.next((m) => m.type === 'MESH_BRIDGE_ACK');
  const room = await env.gw.convoys.getRoom(groupId);
  assert.equal(room.riders.get(offline).presence, 'ONLINE');
  const mb = env.gw.hub.meshBridge;
  const real = mb.clock;
  mb.clock = () => real() + VIA_BRIDGE_MS + 1000;
  try { mb.sweep(); } finally { mb.clock = real; }
  assert.equal(room.riders.get(offline).presence, 'NO_SIGNAL');
  a.close();
});

test('bridged SOS: stored like any SOS, acknowledged to the bridge, one alert whichever copy comes first', async () => {
  const { users, groupId } = await ride(4, 'Sos');
  const [a, d, c] = await Promise.all([env.joinRoom(users[0].token, groupId), env.joinRoom(users[3].token, groupId), env.joinRoom(users[2].token, groupId)]);
  const key = await keyOf(a);
  const offline = users[1].user.userId;
  const cid = `${offline}-${Date.now()}`;
  a.sendJson({ type: 'MESH_BRIDGE', f: [seal(key, { cls: 0, origin: shortId(offline), seq: 10, payload: sosPayload({ clientId: cid }) })] });
  const ack = await a.next((m) => m.type === 'MESH_BRIDGE_ACK');
  assert.equal(ack.acks.length, 1);
  assert.equal(ack.acks[0].o, shortId(offline));
  assert.equal(ack.acks[0].cid, cid);
  assert.match(ack.acks[0].alertId, /^SOS-/);
  const alert = await c.next((m) => m.type === 'ALERT' && m.alert.userId === offline);
  assert.equal(alert.alert.alertId, ack.acks[0].alertId);
  assert.equal(alert.alert.alertType, 'CRASH');
  // A resend from the origin (new seq) through another bridge: the same alert.
  d.sendJson({ type: 'MESH_BRIDGE', f: [seal(key, { cls: 0, origin: shortId(offline), boot: 1, seq: 11, payload: sosPayload({ clientId: cid }) })] });
  const ack2 = await d.next((m) => m.type === 'MESH_BRIDGE_ACK');
  assert.equal(ack2.acks[0].alertId, ack.acks[0].alertId);
  // The rider's own socket comes back and resends its SOS with the same clientId: still one alert.
  const b = await env.joinRoom(users[1].token, groupId);
  b.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, alertType: 'CRASH', clientId: cid });
  const echo = await b.next((m) => m.type === 'ALERT' && m.duplicate === true);
  assert.equal(echo.alert.alertId, ack.acks[0].alertId);
  const room = await env.gw.convoys.getRoom(groupId);
  assert.equal([...room.alerts.values()].filter((x) => x.userId === offline && !x.resolved).length, 1);
  // "Resolved" over the mesh is acknowledged but never closes the SOS (any rider holds the ride key).
  d.sendJson({ type: 'MESH_BRIDGE', f: [seal(key, { cls: 0, origin: shortId(offline), boot: 1, seq: 12, payload: sosPayload({ clientId: cid, resolved: true }) })] });
  const ack3 = await d.next((m) => m.type === 'MESH_BRIDGE_ACK');
  assert.equal(ack3.acks[0].cid, cid);
  assert.equal(room.alerts.get(ack.acks[0].alertId).resolved, false);
  a.close(); b.close(); c.close(); d.close();
});

test('outsiders, proxied frames, unknown riders and garbage are refused; the admin switch keeps SOS', async () => {
  const { users, groupId } = await ride(3, 'Guard');
  const [a, c] = await Promise.all([env.joinRoom(users[0].token, groupId), env.joinRoom(users[2].token, groupId)]);
  const key = await keyOf(a);
  const offline = users[1].user.userId;
  const rejected = env.gw.hub.stats.meshRejected;
  a.sendJson({ type: 'MESH_BRIDGE', f: [
    seal(crypto.randomBytes(32), { cls: 2, origin: shortId(offline), seq: 1, payload: posPayload({}) }), // another ride's key
    seal(key, { cls: 2, origin: shortId(offline), seq: 2, payload: posPayload({}), proxied: true }), // a bridge's own proxy copy
    seal(key, { cls: 2, origin: shortId('not-a-member'), seq: 3, payload: posPayload({}) }),
    seal(key, { cls: 2, origin: shortId(users[0].user.userId), seq: 4, payload: posPayload({}) }), // the bridge itself
    'not base64 at all!!', 42,
  ] });
  assert.equal((await a.next((m) => m.type === 'MESH_BRIDGE_ACK')).n, 0);
  assert.equal(env.gw.hub.stats.meshRejected, rejected + 6);
  // Stale position (6 minutes old) is refused as a replay / stale frame.
  a.sendJson({ type: 'MESH_BRIDGE', f: [seal(key, { cls: 2, origin: shortId(offline), seq: 5, t: Math.floor(Date.now() / 1000) - 360, payload: posPayload({}) })] });
  assert.equal((await a.next((m) => m.type === 'MESH_BRIDGE_ACK')).n, 0);
  await env.gw.featureFlags.set('offlineMesh', false, { reason: 'test' });
  try {
    a.sendJson({ type: 'MESH_BRIDGE', f: [
      seal(key, { cls: 2, origin: shortId(offline), seq: 6, payload: posPayload({}) }),
      seal(key, { cls: 0, origin: shortId(offline), seq: 7, payload: sosPayload({ clientId: `guard-${Date.now()}` }) }),
    ] });
    const ack = await a.next((m) => m.type === 'MESH_BRIDGE_ACK');
    assert.equal(ack.n, 1, 'switch off: only the SOS');
    assert.equal(ack.acks.length, 1);
    await c.next((m) => m.type === 'ALERT' && m.alert.userId === offline);
  } finally {
    await env.gw.featureFlags.set('offlineMesh', true);
  }
  await sleep(20);
  a.close(); c.close();
});
