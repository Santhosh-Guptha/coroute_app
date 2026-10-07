'use strict';
/**
 * Adversarial checks added by QA for 3.11.0: account gate edge cases, socket whitelist,
 * input types, admin and membership guards, account deletion of renamed riders,
 * and recycled user ids.
 */
process.env.NODE_ENV = 'test';
process.env.REPORT_DELAY_MS = '0';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.MAX_CONVOY_RIDERS = '3';
process.env.WS_ACTIONS_PER_SEC = '10';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const WebSocket = require('ws');
const config = require('../src/config');
const { requireAdmin } = require('../src/auth');
const { boot, sleep } = require('./_helpers');

let t, admin;
let ipSeq = 0;
let phoneSeq = 0;
/** Registers a complete rider from its own address (the auth limiter allows 30 per address). */
async function reg(name, email, extra = {}) {
  phoneSeq++;
  const r = await t.api('POST', '/auth/register', {
    name, email, password: 'Password#123', phone: `+9197000${String(10000 + phoneSeq).slice(-5)}`,
    vehicleType: 'Motorcycle', vehicleNo: `TS10QA${String(1000 + phoneSeq).slice(-4)}`,
    emergencyContact: '+919000000002', emergencyContactName: 'Qa Family', ...extra,
  }, null, { 'X-Forwarded-For': `10.9.${Math.floor(++ipSeq / 200)}.${ipSeq % 200}` });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}
before(async () => {
  t = await boot();
  t.register = reg;
  admin = await t.register('Qa Admin', 'qaadmin@coroute.test');
  await t.gw.auth.setRole({ userId: 'system' }, admin.user.userId, 'MASTER_ADMIN');
});
after(async () => { await t.gw.shutdown(); });

function everything() {
  const out = [];
  for (const [name, coll] of t.soda.collections) for (const doc of coll.values()) out.push([name, JSON.stringify(doc)]);
  return out;
}

// ------------------------------------------------------------------ account gate

test('gate: a hold applies to the very next request even when the account is cached', async () => {
  const u = await t.register('Qa Held', 'qaheld@coroute.test');
  assert.equal((await t.api('GET', '/trips', null, u.token)).status, 200); // primes the cache
  const ws = await t.connect(u.token);
  await ws.next((m) => m.type === 'HELLO');
  assert.equal((await t.api('PATCH', `/admin/users/${u.user.userId}/status`, { status: 'ON_HOLD' }, admin.token)).status, 200);
  const r = await t.api('POST', '/convoys', { name: 'Held ride' }, u.token);
  assert.equal(r.status, 403);
  assert.equal(r.json.code, 'ACCOUNT_ON_HOLD');
  assert.equal(await ws.closed, 4403);
  await t.api('PATCH', `/admin/users/${u.user.userId}/status`, { status: 'ACTIVE' }, admin.token);
});

test('gate: the role in the token is never trusted (forged MASTER_ADMIN claim on a rider)', async () => {
  const u = await t.register('Qa Forged', 'qaforged@coroute.test');
  const token = jwt.sign({ sub: u.user.userId, name: 'x', role: 'MASTER_ADMIN', email: 'qaforged@coroute.test', pv: 0 }, config.jwtSecret, { expiresIn: '1d', issuer: 'coroute-gateway' });
  assert.equal((await t.api('GET', '/admin/users', null, token)).status, 403);
  const ws = await t.connect(token);
  await ws.next((m) => m.type === 'HELLO');
  ws.sendJson({ type: 'ADMIN_SUBSCRIBE' });
  const err = await ws.next((m) => m.type === 'ERROR');
  assert.equal(err.code, 403);
  ws.close();
});

test('gate: tokens without pv follow iat; a token issued after the change still works', async () => {
  const u = await t.register('Qa Legacy', 'qalegacy@coroute.test');
  const ch = await t.api('POST', '/me/password', { currentPassword: 'Password#123', newPassword: 'Another#Pass1' }, u.token);
  assert.equal(ch.status, 200);
  const sign = (iat) => jwt.sign({ sub: u.user.userId, name: 'x', role: 'RIDER', iat }, config.jwtSecret, { expiresIn: '1d', issuer: 'coroute-gateway' });
  const old = await t.api('GET', '/me', null, sign(Math.floor(Date.now() / 1000) - 120));
  assert.equal(old.json.code, 'SESSION_INVALID');
  assert.equal((await t.api('GET', '/me', null, sign(Math.floor(Date.now() / 1000) + 5))).status, 200);
});

test('gate: a demoted admin stops receiving the fleet feed on an idle socket', async () => {
  const a2 = await t.register('Qa Second Admin', 'qasecondadmin@coroute.test');
  await t.api('PATCH', `/admin/users/${a2.user.userId}/role`, { role: 'MASTER_ADMIN' }, admin.token);
  const ws = await t.connect(a2.token);
  await ws.next((m) => m.type === 'HELLO');
  ws.sendJson({ type: 'ADMIN_SUBSCRIBE' });
  await ws.next((m) => m.type === 'FLEET');
  assert.equal((await t.api('PATCH', `/admin/users/${a2.user.userId}/role`, { role: 'RIDER' }, admin.token)).status, 200);
  // Something happens in the fleet; the demoted socket sends nothing.
  const rider = await t.register('Qa Fleet Rider', 'qafleetrider@coroute.test');
  await t.api('POST', '/convoys', { name: 'Fleet ride' }, rider.token);
  await sleep(1400);
  assert.equal(ws.inbox.filter((m) => m.type === 'FLEET').length, 0, 'no fleet data after demotion');
  ws.close();
});

test('gate: a short database error does not drop riders already connected', async () => {
  const u = await t.register('Qa Flaky', 'qaflaky@coroute.test');
  const ws = await t.connect(u.token);
  await ws.next((m) => m.type === 'HELLO');
  const gate = t.gw.gate;
  const realTtl = gate.ttlMs;
  const realFind = t.gw.repo.findUserById.bind(t.gw.repo);
  gate.ttlMs = 0; // every check goes to the database
  t.gw.repo.findUserById = async () => { throw new Error('ORDS 503'); };
  try {
    ws.sendJson({ type: 'PING' });
    const pong = await ws.next((m) => m.type === 'PONG').catch(() => null);
    assert.ok(pong, 'still connected');
    assert.equal(ws.closeCode, null);
    // A blocked account is still refused: invalidate() leaves nothing stale to fall back on.
    gate.invalidate(u.user.userId);
    ws.sendJson({ type: 'PING' });
    assert.equal(await ws.closed, 1011);
  } finally {
    t.gw.repo.findUserById = realFind;
    gate.ttlMs = realTtl;
  }
});

// ---------------------------------------------------------- socket whitelist

test('telemetry cannot rename, re-id or re-attach a rider; junk numbers are coerced', async () => {
  const lead = await t.register('Qa Tele Lead', 'qatelelead@coroute.test');
  const pack = await t.register('Qa Tele Pack', 'qatelepack@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Tele ride' }, lead.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, pack.token);
  const wl = await t.joinRoom(lead.token, c.groupId);
  const wp = await t.joinRoom(pack.token, c.groupId);
  wp.send(JSON.stringify({ type: 'TELEMETRY', lat: 'abc', lng: 1e9, heading: -90, batteryLevel: 'x', speedKmh: -5, name: 'Lead Impostor', userId: lead.user.userId, ridingWithUserId: lead.user.userId, isCoRiding: true, vehicleNo: 'X', joinedAt: 1, lastSeenEpochMs: 1 }));
  const m = await wl.next((x) => x.type === 'RIDER_UPDATE');
  assert.equal(m.rider.userId, pack.user.userId);
  assert.equal(m.rider.name, 'Qa Tele Pack');
  assert.equal(m.rider.ridingWithUserId, '');
  assert.equal(m.rider.isCoRiding, false);
  assert.equal(m.rider.lat, 0);
  assert.equal(m.rider.lng, 180);
  assert.equal(m.rider.heading, 270);
  assert.equal(m.rider.speedKmh, 0);
  assert.ok(m.rider.batteryLevel >= 0 && m.rider.batteryLevel <= 100);
  const room = await t.gw.convoys.getRoom(c.groupId);
  assert.ok(room.riders.get(lead.user.userId).name === 'Qa Tele Lead');
  assert.ok(room.riders.get(pack.user.userId).joinedAt > 1);
  // Prototype keys in a message are harmless.
  wp.send('{"type":"TELEMETRY","lat":17.1,"lng":78.1,"__proto__":{"role":"LEAD"},"constructor":{"x":1}}');
  const p = await wl.next((x) => x.type === 'RIDER_UPDATE' && x.rider.lat === 17.1);
  assert.equal(p.rider.role, 'PACK');
  assert.equal(({}).role, undefined);
  wl.close(); wp.close();
});

test('JOIN and other socket messages that read the database are budgeted', async () => {
  const u = await t.register('Qa Join Spam', 'qajoinspam@coroute.test');
  const ws = await t.connect(u.token);
  await ws.next((m) => m.type === 'HELLO');
  const reads = { n: 0 };
  const real = t.gw.repo.getConvoyMeta.bind(t.gw.repo);
  t.gw.repo.getConvoyMeta = async (g) => { reads.n++; return real(g); };
  try {
    for (let i = 0; i < 40; i++) ws.sendJson({ type: 'JOIN', groupId: `GRP-NOPE${i}` });
    await sleep(400);
  } finally { t.gw.repo.getConvoyMeta = real; }
  assert.ok(reads.n <= 12, `database reads ${reads.n}`);
  assert.ok(ws.inbox.some((m) => m.type === 'ERROR' && m.code === 429));
  ws.close();
});

test('SOS clientIds are per rider: two riders with the same clientId get two alerts', async () => {
  const a = await t.register('Qa Sos One', 'qasosone@coroute.test');
  const b = await t.register('Qa Sos Two', 'qasostwo@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Two SOS' }, a.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, b.token);
  const wa = await t.joinRoom(a.token, c.groupId);
  const wb = await t.joinRoom(b.token, c.groupId);
  wa.sendJson({ type: 'SOS', lat: 1, lng: 1, clientId: 'same' });
  await wb.next((m) => m.type === 'ALERT' && m.alert.userId === a.user.userId);
  wb.sendJson({ type: 'SOS', lat: 1, lng: 1, clientId: 'same' });
  const second = await wa.next((m) => m.type === 'ALERT' && m.alert.userId === b.user.userId);
  assert.notEqual(second.duplicate, true);
  assert.equal((await t.gw.repo.listAlerts(c.groupId)).length, 2);
  wa.close(); wb.close();
});

// ---------------------------------------------------------------- size cap

test('the convoy size cap holds under concurrent joins', async () => {
  const lead = await t.register('Qa Cap Lead', 'qacaplead@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Cap ride' }, lead.token)).json;
  const riders = [];
  for (let i = 0; i < 5; i++) riders.push(await t.register(`Qa Cap ${i}`, `qacap${i}@coroute.test`));
  const res = await Promise.all(riders.map((r) => t.api('POST', '/convoys/join', { code: c.joinCode }, r.token)));
  const ok = res.filter((r) => r.status === 200).length;
  const room = await t.gw.convoys.getRoom(c.groupId);
  assert.ok(room.riders.size <= config.maxConvoyRiders, `riders ${room.riders.size}, joined ${ok}`);
  assert.ok(res.filter((r) => r.status === 409).every((r) => r.json.code === 'CONVOY_FULL'));
});

// ------------------------------------------------------------ input types

test('wrong types and odd text never cause a 500', async () => {
  const bad = [
    ['POST', '/auth/login', { identifier: 12345, password: 'x' }],
    ['POST', '/auth/login', { identifier: { $ne: 1 }, password: 'Password#123' }],
    ['POST', '/auth/login', { identifier: 'qaadmin@coroute.test', password: { a: 1 } }],
    ['POST', '/auth/login', { identifier: ['qaadmin@coroute.test'], password: ['Password#123'] }],
    ['POST', '/auth/register', { name: ['A', 'B'], email: 'x1@coroute.test', password: 'Password#123', phone: '+919876543210' }],
    ['POST', '/auth/register', { name: 'Qa Types', email: { a: 1 }, password: 'Password#123', phone: '+919876543210' }],
    ['POST', '/auth/register', { name: 'Qa Types', email: 'x2@coroute.test', password: 'Password#123', phone: 9876543210, vehicleNo: 123 }],
    ['POST', '/auth/google', { idToken: { a: 1 } }],
  ];
  for (const [m, p, body] of bad) {
    const r = await t.api(m, p, body);
    assert.ok(r.status < 500 || r.status === 501, `${p} ${JSON.stringify(body)} -> ${r.status}`);
  }
  const u = await t.register('Qa Types User', 'qatypes@coroute.test');
  for (const body of [
    { newPassword: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'], currentPassword: 'Password#123' },
    { newPassword: { length: 9 }, currentPassword: 'Password#123' },
    { newPassword: 'Valid#Pass99', currentPassword: { a: 1 } },
  ]) {
    const r = await t.api('POST', '/me/password', body, u.token);
    assert.ok(r.status >= 400 && r.status < 500, `password ${JSON.stringify(body)} -> ${r.status}`);
  }
  for (const body of [{ name: { a: 1 } }, { name: ['Qa', 'Arr'] }, { phone: { a: 1 } }, { vehicleNo: [] }, { name: 12 }, { name: true }]) {
    const r = await t.api('PATCH', '/me', body, u.token);
    assert.ok(r.status === 422 || r.status === 200, `PATCH ${JSON.stringify(body)} -> ${r.status}`);
    if (body.name && typeof body.name === 'object') assert.equal(r.status, 422, `object callsign refused: ${JSON.stringify(body)}`);
  }
  const me = (await t.api('GET', '/me', null, u.token)).json;
  assert.ok(!String(me.name).includes('[object'), me.name);
  assert.ok(!String(me.phone).includes('[object'), me.phone);
});

test('callsigns: unicode names work; invisible and direction-override characters are refused', async () => {
  const u = await t.register('रवि कुमार', 'qaunicode@coroute.test');
  assert.equal(u.user.name, 'रवि कुमार');
  const login = await t.api('POST', '/auth/login', { identifier: 'रवि कुमार', password: 'Password#123' });
  assert.equal(login.status, 200);
  for (const name of ['Ravi\u202Egnp', 'Ra\u200Bvi', '\u2066Ravi\u2069', 'Ra\u200Fvi']) {
    const r = await t.api('PATCH', '/me', { name }, u.token);
    assert.equal(r.status, 422, `${JSON.stringify(name)} -> ${r.status}`);
  }
  // Zero-width joiner is part of Indian scripts and stays allowed.
  const zwj = await t.api('PATCH', '/me', { name: '\u0915\u094D\u200D\u0937 Rider' }, u.token);
  assert.equal(zwj.status, 200, JSON.stringify(zwj.json));
  const long = await t.api('PATCH', '/me', { name: 'x'.repeat(100000) }, u.token);
  assert.equal(long.status, 422);
});

test('a rider whose stored callsign predates the rules can still sign in and edit other fields', async () => {
  const u = await t.register('Qa Legacy Name', 'qalegacyname@coroute.test');
  const doc = await t.gw.repo.findUserById(u.user.userId);
  const legacyName = 'L'; // too short for today's rule
  await t.gw.repo.updateUser(doc.key, { name: legacyName, phone: '12345', vehicleNo: 'old/no.1' });
  t.gw.gate.invalidate(u.user.userId);
  const login = await t.api('POST', '/auth/login', { identifier: legacyName, password: 'Password#123' });
  assert.equal(login.status, 200, JSON.stringify(login.json));
  const r = await t.api('PATCH', '/me', { name: legacyName, phone: '12345', vehicleNo: 'old/no.1', emergencyContactName: 'New Contact', emergencyContact: '+919111111111', vehicleType: 'Motorcycle' }, login.json.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.emergencyContactName, 'New Contact');
  assert.equal(r.json.name, legacyName);
});

// ---------------------------------------------------- admin and membership guards

test('every /admin route is guarded by requireAdmin and refuses a rider', async () => {
  const { buildRouter } = require('../src/routes');
  const router = buildRouter({ auth: t.gw.auth, convoys: t.gw.convoys, repo: t.gw.repo, soda: t.soda, hub: null, startedAt: 0, tracks: t.gw.tracks, timeline: t.gw.timeline, geo: t.gw.geo, gate: t.gw.gate });
  const adminRoutes = router.stack.filter((l) => l.route && l.route.path.startsWith('/admin'));
  assert.ok(adminRoutes.length >= 15, `found ${adminRoutes.length}`);
  for (const l of adminRoutes) {
    assert.ok(l.route.stack.some((s) => s.handle === requireAdmin), `${l.route.path} has requireAdmin`);
  }
  const rider = await t.register('Qa Not Admin', 'qanotadmin@coroute.test');
  for (const l of adminRoutes) {
    for (const method of Object.keys(l.route.methods)) {
      const path = l.route.path.replace(':userId', admin.user.userId).replace(':groupId', 'GRP-X');
      const r = await t.api(method.toUpperCase(), path, method === 'get' ? undefined : {}, rider.token);
      assert.equal(r.status, 403, `${method} ${path}`);
    }
  }
});

test('convoy routes: strangers get nothing; a rider who left sees only their window', async () => {
  const lead = await t.register('Qa Win Lead', 'qawinlead@coroute.test');
  const member = await t.register('Qa Win Member', 'qawinmember@coroute.test');
  const stranger = await t.register('Qa Stranger', 'qastranger@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Window ride' }, lead.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, member.token);
  const g = c.groupId;
  for (const [m, p] of [['GET', `/convoys/${g}`], ['GET', `/convoys/${g}/timeline`], ['GET', `/convoys/${g}/tracks`], ['GET', `/convoys/${g}/summary`],
    ['GET', `/convoys/${g}/report`], ['GET', `/convoys/${g}/gpx`], ['POST', `/convoys/${g}/status`], ['POST', `/convoys/${g}/tracks`]]) {
    const r = await t.api(m, p, m === 'POST' ? { status: 'ENDED', chunks: [{}] } : undefined, stranger.token);
    assert.equal(r.status, 403, `${m} ${p} -> ${r.status}`);
  }
  // Strangers cannot end, leave others, or post into the room over the socket.
  const ws = await t.connect(stranger.token);
  await ws.next((m) => m.type === 'HELLO');
  ws.sendJson({ type: 'JOIN', groupId: g });
  assert.equal((await ws.next((m) => m.type === 'ERROR')).code, 403);
  ws.sendJson({ type: 'CHAT', text: 'hi' });
  assert.equal((await ws.next((m) => m.type === 'ERROR')).code, 409);
  ws.close();
  // The member leaves: the live snapshot is closed to them.
  await t.api('POST', `/convoys/${g}/leave`, {}, member.token);
  assert.equal((await t.api('GET', `/convoys/${g}`, null, member.token)).status, 403);
  // A PACK rider cannot end the trip over REST.
  const pack = await t.register('Qa Win Pack', 'qawinpack@coroute.test');
  await t.api('POST', '/convoys/join', { code: c.joinCode }, pack.token);
  assert.equal((await t.api('POST', `/convoys/${g}/status`, { status: 'ENDED' }, pack.token)).status, 403);
});

// --------------------------------------------------------------- deletion

test('deleting a renamed rider (who created the convoy) also removes the old name', async () => {
  const B = await t.register('Qa Old Name', 'qaoldname@coroute.test', { phone: '+919833333333', vehicleNo: 'AP09QA1234', emergencyContact: '+919844444444', emergencyContactName: 'Qa Kin' });
  const A = await t.register('Qa Other Rider', 'qaotherrider@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Rename ride', start: { lat: 17.3, lng: 78.4, name: 'S' }, destination: 'E', destLat: 17.5, destLng: 78.4 }, B.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, A.token);
  const wb = await t.joinRoom(B.token, c.groupId);
  const wa = await t.joinRoom(A.token, c.groupId);
  wb.sendJson({ type: 'STOP_ADD', name: 'Fuel', lat: 17.4, lng: 78.4 });
  await wa.next((m) => m.type === 'STOPS');
  wa.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4, clientId: 'qa-a' });
  const sos = await wb.next((m) => m.type === 'ALERT');
  wb.sendJson({ type: 'SOS_RESOLVE', alertId: sos.alert.alertId });
  await wa.next((m) => m.type === 'ALERT_RESOLVED');
  wa.sendJson({ type: 'CORIDER', ridingWithUserId: B.user.userId });
  await sleep(50);
  wb.sendJson({ type: 'TRIP_STATUS', status: 'ENDED' });
  await wa.next((m) => m.type === 'TRIP_STATUS');
  await t.gw.timeline.idle();
  wa.close(); wb.close();
  // B renames after the ride, then deletes the account.
  const ren = await t.api('PATCH', '/me', { name: 'Qa New Name' }, B.token);
  assert.equal(ren.status, 200, JSON.stringify(ren.json));
  assert.equal((await t.api('DELETE', '/me', null, B.token)).status, 200);
  await t.gw.timeline.idle();
  const needles = [B.user.userId, 'Qa Old Name', 'Qa New Name', 'qaoldname@coroute.test', '+919833333333', 'AP09QA1234', '+919844444444', 'Qa Kin'];
  const leaks = [];
  for (const [coll, json] of everything()) for (const n of needles) if (json.includes(n)) leaks.push(`${coll}: ${n}`);
  assert.deepEqual(leaks, []);
  // A's history still loads.
  assert.equal((await t.api('GET', `/convoys/${c.groupId}/summary`, null, A.token)).status, 200);
});

test('a new account never inherits the convoys of an older account with the same callsign', async () => {
  // Simulates a rider deleted by an older build: the convoy still lists the old userId.
  const lead = await t.register('Qa Recycle Lead', 'qarecyclelead@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Recycle ride' }, lead.token)).json;
  const meta = await t.gw.repo.getConvoyMeta(c.groupId);
  meta.members.usr_qa_recycled = { userId: 'usr_qa_recycled', name: 'Qa Recycled', role: 'PACK', joinedAt: 1 };
  await t.gw.repo.saveConvoyMeta(meta);
  const room = t.gw.convoys.rooms.get(c.groupId);
  if (room) room.meta.members = meta.members;
  const fresh = await t.register('Qa Recycled', 'qarecycled@coroute.test');
  assert.notEqual(fresh.user.userId, 'usr_qa_recycled');
  assert.equal((await t.api('GET', `/convoys/${c.groupId}/timeline`, null, fresh.token)).status, 403);
});

// ------------------------------------------------------------- website

test('website: odd beacon paths are not stored; dashes, emoji and hosts absent in every public text file', async () => {
  for (const path of ['/PRIVACY', '/privacy/', '/index.html', '//evil.com', '/join/../admin', '/api/me', '/docs', '/%2e%2e/']) {
    const r = await fetch(`${t.origin}/api/pv`, { method: 'POST', body: JSON.stringify({ path }) });
    assert.equal(r.status, 204);
  }
  await sleep(50);
  const rows = await t.gw.repo.listPageviews('2000-01-01');
  for (const row of rows) assert.ok(['/', '/privacy', '/terms', '/join'].includes(row.path), row.path);

  const fs = require('fs');
  const path = require('path');
  const dir = path.join(__dirname, '..', 'public');
  const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
  for (const f of walk(dir).filter((x) => /\.(html|js|css|json|txt|xml|webmanifest)$/.test(x))) {
    const s = fs.readFileSync(f, 'utf8');
    assert.ok(!/[–—]/.test(s), `${f}: en or em dash`);
    assert.ok(!/(?![\u00a9\u00ae\u2122])\p{Extended_Pictographic}/u.test(s), `${f}: emoji`);
    assert.ok(!/oraclecloudapps/i.test(s), `${f}: database host`);
    assert.ok(!/\b(?:\d{1,3}\.){3}\d{1,3}\b/.test(s), `${f}: IPv4`);
  }
  for (const p of ['/docs', '/docs/', '/docs.html', '/architecture', '/COROUTE_SYSTEM_DOCUMENTATION.html', '/.env', '/package.json', '/src/config.js']) {
    assert.equal((await fetch(`${t.origin}${p}`, { redirect: 'manual' })).status, 404, p);
  }
  const d = await fetch(`${t.origin}/download/32bit`, { redirect: 'manual' });
  assert.equal(d.status, 302);
  assert.ok(d.headers.get('location').endsWith('/coroute-32bit.apk'));
});

test('unknown socket messages and malformed frames are answered without side effects', async () => {
  const u = await t.register('Qa Frames', 'qaframes@coroute.test');
  const ws = await t.connect(u.token);
  await ws.next((m) => m.type === 'HELLO');
  ws.send('not json');
  assert.equal((await ws.next((m) => m.type === 'ERROR')).code, 400);
  ws.send('null');
  assert.equal((await ws.next((m) => m.type === 'ERROR')).code, 400);
  ws.send('[1,2]');
  assert.equal((await ws.next((m) => m.type === 'ERROR')).code, 400);
  ws.send(Buffer.from([1, 0xff, 0xff]), { binary: true }); // voice before JOIN: dropped
  ws.sendJson({ type: 'PING' });
  await ws.next((m) => m.type === 'PONG');
  assert.equal(ws.readyState, WebSocket.OPEN);
  ws.close();
});

test('deleting a rider with an open SOS and an open co-ride in a live convoy writes nothing back when the trip ends', async () => {
  const lead = await t.register('Qa Open Lead', 'qaopenlead@coroute.test');
  const gone = await t.register('Qa Open Gone', 'qaopengone@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Open slots ride' }, lead.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, gone.token);
  const wl = await t.joinRoom(lead.token, c.groupId);
  const wg = await t.joinRoom(gone.token, c.groupId);
  wg.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4, clientId: 'open-1' });
  await wl.next((m) => m.type === 'ALERT');
  wl.sendJson({ type: 'CORIDER', ridingWithUserId: gone.user.userId });
  await wl.next((m) => m.type === 'RIDER_UPDATE' && m.rider.ridingWithUserId === gone.user.userId);
  await t.gw.timeline.idle();
  assert.equal((await t.api('DELETE', `/admin/users/${gone.user.userId}`, null, admin.token)).status, 200);
  await t.gw.timeline.idle();
  wl.sendJson({ type: 'CORIDER', ridingWithUserId: '' });
  await sleep(50);
  wl.sendJson({ type: 'TRIP_STATUS', status: 'ENDED' });
  await wl.next((m) => m.type === 'TRIP_STATUS');
  await sleep(50);
  await t.gw.timeline.idle();
  await t.gw.convoys.flushAll();
  const leaks = [];
  for (const [coll, json] of everything()) for (const n of [gone.user.userId, 'Qa Open Gone']) if (json.includes(n)) leaks.push(`${coll}: ${n}`);
  assert.deepEqual(leaks, []);
  wl.close();
});

test('asking the group to wait never uses up the SOS budget', async () => {
  const u = await t.register('Qa Wait Then Sos', 'qawaitsos@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Wait then SOS' }, u.token)).json;
  const ws = await t.joinRoom(u.token, c.groupId);
  for (let i = 0; i < 4; i++) ws.sendJson({ type: 'WAIT' });
  await sleep(200);
  ws.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4, clientId: 'after-wait' });
  const alert = await ws.next((m) => m.type === 'ALERT');
  assert.equal(alert.alert.clientId, 'after-wait');
  ws.close();
});
