'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END } = require('../src/ws');

let gw, base, wsBase, soda;

before(async () => {
  soda = new MemorySoda();
  gw = await createApp({ soda, logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const { port } = gw.server.address();
  base = `http://127.0.0.1:${port}/api`;
  wsBase = `ws://127.0.0.1:${port}/ws`;
});
after(async () => { await gw.shutdown(); });

async function api(method, path, body, token) {
  const res = await fetch(base + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json };
}

async function register(name, email, password = 'Password#123') {
  // A complete safety profile: every rider needs one before creating or joining a convoy.
  const r = await api('POST', '/auth/register', {
    name, email, password, phone: '9999999999', vehicleType: 'Motorcycle', vehicleNo: 'TS09AB1234',
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}

function connect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsBase}?token=${token}`);
    ws.inbox = [];
    ws.waiters = [];
    ws.on('message', (data, isBinary) => {
      const item = isBinary ? { binary: decodeVoice(Buffer.from(data)) } : JSON.parse(data.toString());
      const w = ws.waiters.findIndex((wt) => wt.pred(item));
      if (w >= 0) ws.waiters.splice(w, 1)[0].resolve(item); else ws.inbox.push(item);
    });
    ws.next = (pred, timeout = 1500) => new Promise((res, rej) => {
      const i = ws.inbox.findIndex(pred);
      if (i >= 0) return res(ws.inbox.splice(i, 1)[0]);
      const t = setTimeout(() => rej(new Error('timeout waiting for message')), timeout);
      ws.waiters.push({ pred, resolve: (v) => { clearTimeout(t); res(v); } });
    });
    ws.sendJson = (o) => ws.send(JSON.stringify(o));
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------------ tests

test('health endpoint reports DB up', async () => {
  const r = await fetch(base + '/health');
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.db, 'UP');
});

test('register / login / token / profile; passwords are hashed; admin role by allow-list', async () => {
  const a = await register('Alice Rider', 'alice@coroute.test');
  assert.ok(a.token);
  assert.equal(a.user.role, 'RIDER');
  assert.equal(a.user.userId, 'usr_alice_rider');

  const stored = await soda.findOne('users', { email: 'alice@coroute.test' });
  assert.ok(stored.value.passwordHash.startsWith('$2'));
  assert.equal(stored.value.password, undefined);

  const dup = await api('POST', '/auth/register', { name: 'Alice Two', email: 'alice@coroute.test', password: 'Password#123', phone: '9999999999' });
  assert.equal(dup.status, 409);

  const bad = await api('POST', '/auth/login', { identifier: 'alice@coroute.test', password: 'nope' });
  assert.equal(bad.status, 401);
  const byCallsign = await api('POST', '/auth/login', { identifier: 'Alice Rider', password: 'Password#123' });
  assert.equal(byCallsign.status, 200);

  const me = await api('GET', '/me', null, a.token);
  assert.equal(me.json.email, 'alice@coroute.test');
  const upd = await api('PATCH', '/me', { vehicleNo: 'ts09ab1234' }, a.token);
  assert.equal(upd.json.vehicleNo, 'TS09AB1234');

  const noAuth = await api('GET', '/me');
  assert.equal(noAuth.status, 401);

  const admin = await register('Fleet Admin', 'admin@coroute.test');
  assert.equal(admin.user.role, 'MASTER_ADMIN');
  const forbidden = await api('GET', '/admin/fleet', null, a.token);
  assert.equal(forbidden.status, 403);
  const allowed = await api('GET', '/admin/fleet', null, admin.token);
  assert.equal(allowed.status, 200);

  // Roles are managed in the database, not in code.
  const promoted = await api('PATCH', `/admin/users/${a.user.userId}/role`, { role: 'MASTER_ADMIN' }, admin.token);
  assert.equal(promoted.json.role, 'MASTER_ADMIN');
  const relogin = await api('POST', '/auth/login', { identifier: 'alice@coroute.test', password: 'Password#123' });
  assert.equal(relogin.json.user.role, 'MASTER_ADMIN');
  const demoted = await api('PATCH', `/admin/users/${a.user.userId}/role`, { role: 'RIDER' }, admin.token);
  assert.equal(demoted.json.role, 'RIDER');
  const lastAdmin = await api('PATCH', `/admin/users/${admin.user.userId}/role`, { role: 'RIDER' }, admin.token);
  assert.equal(lastAdmin.status, 409);
  const users = await api('GET', '/admin/users', null, admin.token);
  assert.ok(users.json.users.length >= 2);
  assert.equal(users.json.users[0].passwordHash, undefined);
});

test('callsigns are unique; callsigns with the same slug get unique userIds', async () => {
  const b1 = await register('Bob', 'bob1@coroute.test');
  const taken = await api('POST', '/auth/register', { name: 'bob', email: 'bob3@coroute.test', password: 'Password#123', phone: '9999999999' });
  assert.equal(taken.status, 409);
  assert.equal(taken.json.code, 'CALLSIGN_TAKEN');
  const b2 = await register('Bob.', 'bob2@coroute.test');
  assert.equal(b1.user.userId, 'usr_bob');
  assert.notEqual(b2.user.userId, 'usr_bob');
  assert.ok(b2.user.userId.startsWith('usr_bob_'));
});

test('convoy lifecycle: create, join by code, per-rider telemetry (no overwrite), leave, auto-end', async () => {
  const lead = await register('Lead One', 'lead1@coroute.test');
  const pack = await register('Pack One', 'pack1@coroute.test');

  const created = await api('POST', '/convoys', { name: 'Hyd → Goa', destination: 'Goa', rider: { lat: 17.3, lng: 78.4 } }, lead.token);
  assert.equal(created.status, 201);
  const convoy = created.json;
  assert.match(convoy.joinCode, /^\d{6}$/);
  assert.equal(convoy.riders[lead.user.userId].role, 'LEAD');

  const notMember = await api('GET', `/convoys/${convoy.groupId}`, null, pack.token);
  assert.equal(notMember.status, 403);

  const joined = await api('POST', '/convoys/join', { code: convoy.joinCode, rider: { lat: 17.31, lng: 78.41 } }, pack.token);
  assert.equal(joined.status, 200);
  assert.equal(Object.keys(joined.json.riders).length, 2);

  const badCode = await api('POST', '/convoys/join', { code: '000000' }, pack.token);
  assert.equal(badCode.status, 404);

  // Two riders push telemetry concurrently; each only changes its own record.
  const wsLead = await connect(lead.token);
  const wsPack = await connect(pack.token);
  wsLead.sendJson({ type: 'JOIN', groupId: convoy.groupId });
  wsPack.sendJson({ type: 'JOIN', groupId: convoy.groupId });
  await wsLead.next((m) => m.type === 'SNAPSHOT');
  await wsPack.next((m) => m.type === 'SNAPSHOT');

  wsLead.sendJson({ type: 'TELEMETRY', lat: 1, lng: 1, speedKmh: 40 });
  wsPack.sendJson({ type: 'TELEMETRY', lat: 2, lng: 2, speedKmh: 50 });
  const seenByPack = await wsPack.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === lead.user.userId);
  assert.equal(seenByPack.rider.lat, 1);
  const seenByLead = await wsLead.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === pack.user.userId);
  assert.equal(seenByLead.rider.lat, 2);

  await sleep(80); // write-behind flush
  const stored = await gw.repo.listRiders(convoy.groupId);
  const byId = Object.fromEntries(stored.map((r) => [r.userId, r]));
  assert.equal(byId[lead.user.userId].lat, 1);
  assert.equal(byId[pack.user.userId].lat, 2);

  // Chat + SOS round trip.
  wsPack.sendJson({ type: 'CHAT', text: 'Fuel stop ahead' });
  const chat = await wsLead.next((m) => m.type === 'MESSAGE');
  assert.equal(chat.message.text, 'Fuel stop ahead');
  wsPack.sendJson({ type: 'SOS', lat: 2, lng: 2, alertType: 'MEDICAL' });
  const sos = await wsLead.next((m) => m.type === 'ALERT');
  assert.equal(sos.alert.alertType, 'MEDICAL');
  wsLead.sendJson({ type: 'SOS_RESOLVE', alertId: sos.alert.alertId });
  await wsPack.next((m) => m.type === 'ALERT_RESOLVED');

  // Only the lead can change the trip status.
  wsPack.sendJson({ type: 'TRIP_STATUS', status: 'PAUSED' });
  const err = await wsPack.next((m) => m.type === 'ERROR');
  assert.equal(err.code, 403);

  // Leaving: pack leaves, lead is notified; lead leaves → convoy auto-ends.
  await api('POST', `/convoys/${convoy.groupId}/leave`, null, pack.token);
  const left = await wsLead.next((m) => m.type === 'RIDER_LEFT');
  assert.equal(left.userId, pack.user.userId);
  await api('POST', `/convoys/${convoy.groupId}/leave`, null, lead.token);
  const meta = await gw.repo.getConvoyMeta(convoy.groupId);
  assert.equal(meta.tripStatus, 'ENDED');
  assert.equal(meta.memberSummary.length, 2); assert.ok(meta.memberSummary.every((m) => m.leftAt));

  wsLead.close(); wsPack.close();
});

test('ISOLATION: data and audio never cross between two convoys; 1:1 voice reaches only the target', async () => {
  const a1 = await register('A One', 'a1@coroute.test');
  const a2 = await register('A Two', 'a2@coroute.test');
  const a3 = await register('A Three', 'a3@coroute.test');
  const b1 = await register('B One', 'b1@coroute.test');
  const b2 = await register('B Two', 'b2@coroute.test');

  const ca = (await api('POST', '/convoys', { name: 'Group A' }, a1.token)).json;
  const cb = (await api('POST', '/convoys', { name: 'Group B' }, b1.token)).json;
  await api('POST', '/convoys/join', { code: ca.joinCode }, a2.token);
  await api('POST', '/convoys/join', { code: ca.joinCode }, a3.token);
  await api('POST', '/convoys/join', { code: cb.joinCode }, b2.token);

  const [w1, w2, w3, x1, x2] = await Promise.all([a1, a2, a3, b1, b2].map((u) => connect(u.token)));
  w1.sendJson({ type: 'JOIN', groupId: ca.groupId });
  w2.sendJson({ type: 'JOIN', groupId: ca.groupId });
  w3.sendJson({ type: 'JOIN', groupId: ca.groupId });
  x1.sendJson({ type: 'JOIN', groupId: cb.groupId });
  x2.sendJson({ type: 'JOIN', groupId: cb.groupId });
  await Promise.all([w1, w2, w3, x1, x2].map((w) => w.next((m) => m.type === 'SNAPSHOT')));

  // A member of B tries to JOIN A's room → refused.
  x2.sendJson({ type: 'JOIN', groupId: ca.groupId });
  const refused = await x2.next((m) => m.type === 'ERROR');
  assert.equal(refused.code, 403);

  // Chat in A is not seen in B.
  w1.sendJson({ type: 'CHAT', text: 'only for A' });
  await w2.next((m) => m.type === 'MESSAGE' && m.message.text === 'only for A');
  await sleep(100);
  assert.equal(x1.inbox.filter((m) => m.type === 'MESSAGE').length, 0);
  assert.equal(x2.inbox.filter((m) => m.type === 'MESSAGE').length, 0);

  // Group voice from a1 reaches a2 and a3, never b1/b2, never back to a1.
  const pcm = Buffer.alloc(640, 7);
  w1.send(encodeVoice(VOICE_START, { sampleRate: 16000, codec: 'pcm16' }));
  w1.send(encodeVoice(VOICE_FRAME, { seq: 1 }, pcm));
  w1.send(encodeVoice(VOICE_END, {}));
  const f2 = await w2.next((m) => m.binary && m.binary.kind === VOICE_FRAME);
  const f3 = await w3.next((m) => m.binary && m.binary.kind === VOICE_FRAME);
  assert.equal(f2.binary.header.from, a1.user.userId);
  assert.equal(f2.binary.header.to, null);
  assert.equal(f2.binary.payload.length, 640);
  assert.equal(f3.binary.payload[0], 7);
  await w2.next((m) => m.binary && m.binary.kind === VOICE_END);
  await sleep(100);
  assert.equal(x1.inbox.filter((m) => m.binary).length, 0, 'group B received audio from group A');
  assert.equal(x2.inbox.filter((m) => m.binary).length, 0, 'group B received audio from group A');
  assert.equal(w1.inbox.filter((m) => m.binary).length, 0, 'sender echoed its own audio');

  // 1:1 voice from a2 to a3 — a1 must hear nothing.
  w2.send(encodeVoice(VOICE_START, { to: a3.user.userId, sampleRate: 16000 }));
  w2.send(encodeVoice(VOICE_FRAME, { to: a3.user.userId, seq: 1 }, pcm));
  w2.send(encodeVoice(VOICE_END, { to: a3.user.userId }));
  const p3 = await w3.next((m) => m.binary && m.binary.kind === VOICE_START && m.binary.header.from === a2.user.userId);
  assert.equal(p3.binary.header.to, a3.user.userId);
  await w3.next((m) => m.binary && m.binary.kind === VOICE_FRAME);
  await sleep(100);
  assert.equal(w1.inbox.filter((m) => m.binary).length, 0, 'private audio leaked to a third rider');

  // 1:1 to someone outside the convoy is rejected.
  w2.send(encodeVoice(VOICE_START, { to: b1.user.userId }));
  const notOnline = await w2.next((m) => m.type === 'ERROR');
  assert.equal(notOnline.code, 404);

  // Floor control: while a1 is speaking to the group, a3 gets VOICE_BUSY.
  w1.send(encodeVoice(VOICE_START, {}));
  w1.send(encodeVoice(VOICE_FRAME, { seq: 1 }, pcm));
  await w3.next((m) => m.binary && m.binary.kind === VOICE_FRAME);
  w3.send(encodeVoice(VOICE_START, {}));
  const busy = await w3.next((m) => m.type === 'VOICE_BUSY');
  assert.equal(busy.speaker, 'A One');
  w1.send(encodeVoice(VOICE_END, {}));

  // Joining another convoy auto-leaves the previous one (one active group per rider).
  await api('POST', '/convoys/join', { code: cb.joinCode }, a3.token);
  const left = await w1.next((m) => m.type === 'RIDER_LEFT');
  assert.equal(left.userId, a3.user.userId);
  assert.equal(await gw.convoys.isMember(ca.groupId, a3.user.userId), false);
  assert.equal(await gw.convoys.isMember(cb.groupId, a3.user.userId), true);

  for (const w of [w1, w2, w3, x1, x2]) w.close();
});

test('admin: fleet view, broadcast reaches everyone, dissolve removes room', async () => {
  const admin = (await api('POST', '/auth/login', { identifier: 'admin@coroute.test', password: 'Password#123' })).json;
  const lead = await register('Lead Two', 'lead2@coroute.test');
  const c = (await api('POST', '/convoys', { name: 'Admin Test' }, lead.token)).json;
  const wsLead = await connect(lead.token);
  wsLead.sendJson({ type: 'JOIN', groupId: c.groupId });
  await wsLead.next((m) => m.type === 'SNAPSHOT');

  const fleet = await api('GET', '/admin/fleet', null, admin.token);
  assert.ok(fleet.json.convoys.some((x) => x.groupId === c.groupId));

  await api('POST', '/admin/broadcast', { message: 'Heavy rain on NH44' }, admin.token);
  const b = await wsLead.next((m) => m.type === 'BROADCAST');
  assert.equal(b.message, 'Heavy rain on NH44');

  await api('DELETE', `/admin/convoys/${c.groupId}`, null, admin.token);
  await wsLead.next((m) => m.type === 'DISSOLVED');
  assert.equal(await gw.repo.getConvoyMeta(c.groupId), null);
  wsLead.close();
});

test('retention keeps accounts and trip records, strips only GPS traces', async () => {
  const u = await register('Hist Rider', 'hist@coroute.test');
  const old = Date.now() - 400 * 86400000;
  await api('POST', '/trips', { tripId: 'TRIP-OLD', tripName: 'Old ride', endTimeEpochMs: old, startTimeEpochMs: old - 3600000, breadcrumbTrail: [{ lat: 1, lng: 1 }], riderCount: 3 }, u.token);
  await api('POST', '/trips', { tripId: 'TRIP-NEW', tripName: 'New ride', endTimeEpochMs: Date.now(), breadcrumbTrail: [{ lat: 1, lng: 1 }] }, u.token);

  // An ended convoy from long ago with rider GPS docs.
  const meta = await gw.repo.createConvoyMeta({ groupId: 'GRP-OLD', name: 'Old convoy', joinCode: '111111', createdByUserId: u.user.userId, createdByUserName: 'Hist Rider', tripStatus: 'ENDED', createdAtEpochMs: old, routeBreadcrumbs: [{ lat: 1, lng: 1 }], memberSummary: [{ userId: u.user.userId, name: 'Hist Rider' }] });
  await soda.replace('convoys', meta.key, { ...meta, key: undefined, updatedAt: old });
  await gw.repo.upsertRider('GRP-OLD', { userId: u.user.userId, name: 'Hist Rider', lat: 1, lng: 1 });

  const stats = await gw.retention.runOnce();
  assert.equal(stats.convoysStripped, 1);
  assert.equal(stats.riderDocsRemoved, 1);
  assert.equal(stats.tripsStripped, 1);

  const kept = await gw.repo.getConvoyMeta('GRP-OLD');
  assert.equal(kept.name, 'Old convoy');
  assert.equal(kept.memberSummary.length, 1);
  assert.deepEqual(kept.routeBreadcrumbs, []);
  assert.equal((await gw.repo.listRiders('GRP-OLD')).length, 0);

  const trips = (await api('GET', '/trips', null, u.token)).json.trips;
  const oldTrip = trips.find((t) => t.tripId === 'TRIP-OLD');
  const newTrip = trips.find((t) => t.tripId === 'TRIP-NEW');
  assert.equal(oldTrip.tripName, 'Old ride');
  assert.equal(oldTrip.riderCount, 3);
  assert.deepEqual(oldTrip.breadcrumbTrail, []);
  assert.equal(newTrip.breadcrumbTrail.length, 1);
  assert.ok(await gw.repo.findUserByEmail('hist@coroute.test'));
});

test('websocket without a valid token is rejected', async () => {
  const code = await new Promise((resolve) => {
    const ws = new WebSocket(`${wsBase}?token=garbage`);
    ws.on('close', (c) => resolve(c));
    ws.on('error', () => {});
  });
  assert.equal(code, 4401);
});
