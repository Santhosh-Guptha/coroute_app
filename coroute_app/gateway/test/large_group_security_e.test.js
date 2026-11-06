'use strict';
/**
 * Large convoy fan-out (coalescing, leave during a flush window, binary telemetry identity) and
 * security hardening (SOS dispatch identity/limits, JWT algorithm, login and guardian PIN limits,
 * membership removal never drops a rider mid-ride).
 */
process.env.NODE_ENV = 'test';
process.env.GUARDIAN_ENABLED = 'true';
process.env.PUBLIC_ORIGIN = 'https://guardian.example';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '50';
process.env.MAX_CONVOY_RIDERS = '100';
process.env.WS_COALESCE_ABOVE = '5';
process.env.WS_COALESCE_MS = '150';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const { boot, sleep } = require('./_helpers');
const { redactPhones } = require('../src/emergency_sms_gateway');

let t;
before(async () => { t = await boot({ emergencyFetch: async () => { throw new Error('offline in tests'); } }); });
after(async () => { await t.gw.shutdown(); });

let n = 0;
// Each registration from its own address (the per-IP sign-up limit is not what these tests are about).
const ip = () => ({ 'X-Forwarded-For': `10.9.${(n >> 8) & 255}.${n & 255}` });
async function rider(tag, extra = {}) {
  n++;
  const r = await t.api('POST', '/auth/register', {
    name: `${tag}${n}`, email: `lgs-${tag.toLowerCase()}${n}@coroute.test`, password: 'Password#123',
    phone: `+9198766${String(10000 + n).slice(-5)}`, vehicleType: 'Motorcycle', vehicleNo: `TS10AB${String(1000 + n).slice(-4)}`,
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact', ...extra,
  }, null, ip());
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}
const uid = (u) => u.user.userId;

function binFrame(lat, lng, speed = 50) {
  const b = Buffer.alloc(24);
  b[0] = 0x10; b.writeUInt32BE(1, 1);
  b.writeInt32BE(Math.round(lat * 1e6), 5); b.writeInt32BE(Math.round(lng * 1e6), 9);
  b.writeUInt16BE(speed * 10, 13); b.writeUInt16BE(900, 15); b.writeUInt8(80, 17);
  return b;
}

test('LARGE: 24 riders, coalesced fan-out delivers every rider\'s latest position, never a departed rider', async () => {
  const lead = await rider('Big');
  const c = (await t.api('POST', '/convoys', { name: 'Big ride' }, lead.token)).json;
  const users = [lead];
  for (let i = 0; i < 23; i++) {
    const u = await rider('Big');
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    users.push(u);
  }
  const socks = [];
  for (const u of users) socks.push(await t.joinRoom(u.token, c.groupId));
  for (const s of socks) s.inbox.length = 0;
  const statsBefore = { ...t.gw.hub.stats };
  // Every rider sends 3 positions within one window; peers must end up with the LAST one.
  for (let k = 0; k < 3; k++) {
    socks.forEach((s, i) => s.sendJson({ type: 'TELEMETRY', lat: 17 + i / 1000, lng: 78 + k / 1000, speedKmh: 40 + k }));
    await sleep(20);
  }
  // Rider 23 leaves inside the window: no late RIDER_UPDATE may bring them back.
  const leaver = users[23];
  await t.api('POST', `/convoys/${c.groupId}/leave`, null, leaver.token);
  await sleep(400);
  const watcher = socks[0];
  const updates = watcher.inbox.filter((m) => m.type === 'RIDER_UPDATE');
  const latest = new Map();
  const leftAt = watcher.inbox.findIndex((m) => m.type === 'RIDER_LEFT' && m.userId === uid(leaver));
  assert.ok(leftAt >= 0, 'RIDER_LEFT seen');
  watcher.inbox.forEach((m, i) => {
    if (m.type !== 'RIDER_UPDATE') return;
    latest.set(m.rider.userId, m.rider);
    if (m.rider.userId === uid(leaver)) assert.ok(i < leftAt, 'no position of a departed rider after RIDER_LEFT');
  });
  for (let i = 1; i < 23; i++) assert.equal(latest.get(uid(users[i])).lng, 78.002, `rider ${i} latest`);
  assert.ok(!latest.has(uid(lead)) || latest.get(uid(lead)).userId === uid(lead));
  // Coalescing: far fewer than 3 updates per rider per watcher.
  assert.ok(updates.length < 3 * 22, `coalesced (${updates.length} updates)`);
  assert.ok(t.gw.hub.stats.posCoalesced > statsBefore.posCoalesced);
  for (const s of socks) s.close();
});

test('Binary telemetry reaches peers as JSON with the sender id; corrupt coordinates are ignored', async () => {
  const lead = await rider('Bin');
  const c = (await t.api('POST', '/convoys', { name: 'Bin ride' }, lead.token)).json;
  const mate = await rider('Bin');
  await t.api('POST', '/convoys/join', { code: c.joinCode }, mate.token);
  const L = await t.joinRoom(lead.token, c.groupId);
  const M = await t.connect(mate.token);
  M.sendJson({ type: 'JOIN', groupId: c.groupId, caps: ['bin1', 'net1'] });
  await M.next((m) => m.type === 'SNAPSHOT');
  L.send(binFrame(17.25, 78.5));
  const up = await M.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(lead));
  assert.equal(up.rider.lat, 17.25);
  const bad = binFrame(0, 0); bad.writeInt32BE(2000000000, 5); // 2000 degrees
  L.send(bad);
  await sleep(100);
  assert.equal(t.gw.convoys.rooms.get(c.groupId).riders.get(uid(lead)).lat, 17.25);
  L.close(); M.close();
});

test('SOS dispatch: own identity only, contacts capped, foreign links dropped, retries deduped, rate limited', async () => {
  const victim = await rider('Victim', { emergencyContact: '+919111111111', emergencyContactName: 'Victim Mum' });
  const attacker = await rider('Attacker');
  const before = t.gw.emergencyGateway.getOutbox({ limit: 5000 }).length;
  const r1 = await t.api('POST', '/v1/sos/dispatch-external', { riderId: uid(victim), riderName: 'Victim', lat: 17, lng: 78 }, attacker.token);
  assert.equal(r1.status, 200);
  const sent = t.gw.emergencyGateway.getOutbox({ limit: 5000 }).slice(0, t.gw.emergencyGateway.getOutbox({ limit: 5000 }).length - before);
  assert.ok(!sent.some((e) => e.to === '+919111111111'), "never texts another account's contact");
  assert.ok(sent.every((e) => !String(e.body).includes('Victim')), 'name comes from the signed-in account');

  const many = Array.from({ length: 12 }, (_, i) => ({ phone: `+9198000000${String(i).padStart(2, '0')}`, name: `C${i}` }));
  const r2 = await t.api('POST', '/v1/sos/dispatch-external', { lat: 17, lng: 78, contacts: many, trackingUrl: 'https://evil.example/phish' }, attacker.token);
  assert.equal(r2.status, 200);
  assert.equal(r2.json.results.length, 2 * 5, 'at most 5 contacts (SMS + WhatsApp each)');
  assert.ok(r2.json.trackingUrl.startsWith('https://guardian.example/e/'), 'own live page only');
  const r3 = await t.api('POST', '/v1/sos/dispatch-external', { lat: 17, lng: 78, contacts: many }, attacker.token);
  assert.equal(r3.json.duplicate, true, 'a retry within a minute is not sent again');
  let last;
  for (let i = 0; i < 8; i++) last = await t.api('POST', '/v1/sos/dispatch-external', { lat: 17, lng: 78, contacts: [{ phone: `+91970000000${i}` }] }, attacker.token);
  assert.equal(last.status, 429);
  // Standalone links are revocable by their rider.
  const rv = await t.api('DELETE', '/v1/sos/live-links', null, attacker.token);
  assert.ok(rv.json.revoked >= 1);
  const token = r2.json.trackingUrl.split('/e/')[1];
  assert.equal((await t.api('GET', `/public/live/${token}`)).status, 410);
});

test('Logs never carry full phone numbers', () => {
  assert.equal(redactPhones('Twilio error: To +91 98765 43210 invalid'), 'Twilio error: To ***210 invalid');
  assert.ok(!redactPhones('to +919876543210').includes('9876543210'));
});

test('JWT: other algorithms are refused', async () => {
  const u = await rider('Jwt');
  const claims = jwt.decode(u.token);
  const none = jwt.sign({ sub: claims.sub, name: 'x', role: 'MASTER_ADMIN' }, null, { algorithm: 'none', issuer: 'coroute-gateway' });
  assert.equal((await t.api('GET', '/me', null, none)).status, 401);
  const hs512 = jwt.sign({ sub: claims.sub, name: 'x', role: 'RIDER' }, require('../src/config').jwtSecret, { algorithm: 'HS512', issuer: 'coroute-gateway' });
  assert.equal((await t.api('GET', '/me', null, hs512)).status, 401);
  assert.equal((await t.api('GET', '/me', null, u.token)).status, 200);
});

test('Login: wrong passwords are limited per account', async () => {
  const u = await rider('Lock');
  let last;
  // From rotating addresses: the per-IP limit alone would never trigger.
  for (let i = 0; i < 11; i++) last = await t.api('POST', '/auth/login', { identifier: u.user.email, password: `wrong-${i}-pass` }, null, { 'X-Forwarded-For': `10.8.0.${i + 1}` });
  assert.equal(last.status, 429);
});

test('Guardian PIN: wrong PINs lock the link per grant (not per IP or token spelling)', async () => {
  const { GuardianService } = require('../src/guardians');
  let clock = Date.now();
  const svc = new GuardianService({ repo: t.gw.repo, convoys: t.gw.convoys, clock: () => clock });
  const u = await rider('Pin');
  const ride = await t.api('POST', '/convoys', { name: 'Pin ride' }, u.token);
  const link = await svc.create(uid(u), ride.json.groupId, { level: 'LIVE', acknowledged: true, pin: '4821' });
  const wrong = async (p) => assert.rejects(svc.exchange(link.token, p), (e) => e.status === 401);
  for (let i = 0; i < 10; i++) await wrong(`00${10 + i}`);
  await assert.rejects(svc.exchange(link.token, '4821'), (e) => e.status === 429 && e.code === 'GUARDIAN_PIN_LOCKED');
  clock += 16 * 60000; // the window passes: the right PIN works again
  assert.ok((await svc.exchange(link.token, '4821')).credential);
  // 50 wrong PINs over the link's life lock it for good.
  for (let w = 0; w < 5; w++) {
    for (let i = 0; i < 10; i++) await wrong(`11${10 + i}`);
    clock += 16 * 60000;
  }
  await assert.rejects(svc.exchange(link.token, '4821'), (e) => e.status === 429);
});

test('Membership removal never drops a rider mid-ride; it only blocks a new join', async () => {
  const owner = await rider('Own');
  const c = (await t.api('POST', '/convoys', { name: 'Owner ride' }, owner.token)).json;
  const inRide = await rider('In');
  const outside = await rider('Outside');
  await t.api('POST', '/convoys/join', { code: c.joinCode }, inRide.token);
  assert.equal(await t.gw.convoys.blockFutureJoin(c.groupId, uid(inRide)), true);
  assert.equal(await t.gw.convoys.blockFutureJoin(c.groupId, uid(outside)), true);
  assert.ok(t.gw.convoys.rooms.get(c.groupId).riders.has(uid(inRide)), 'still riding (keeps the SOS network)');
  const j = await t.api('POST', '/convoys/join', { code: c.joinCode }, outside.token);
  assert.equal(j.status, 403); assert.equal(j.json.reason || j.json.code, 'JOIN_BLOCKED');
  // The rider who is in it can still re-sync (join by code again while a member) without being dropped.
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, inRide.token)).status, 200);
  const snap = await t.api('GET', `/convoys/${c.groupId}`, null, inRide.token);
  assert.equal(snap.json.joinBlocked, undefined, 'block list is never sent to riders');
});

test('Backpressure: slow peers skip positions, hopeless ones are closed, healthy ones get every update', () => {
  const hub = t.gw.hub;
  const mk = (id, buffered) => ({ readyState: 1, bufferedAmount: buffered, user: { userId: id }, got: 0, closed: 0,
    send() { this.got++; }, close() { this.closed++; }, terminate() {} });
  const ok = mk('a', 0), slow = mk('b', 300 * 1024), dead = mk('c', 64 * 1024 * 1024), self = mk('d', 0);
  const s0 = { ...hub.stats };
  hub._sendPosition(new Set([ok, slow, dead, self]), '{}', 'd', null);
  assert.equal(ok.got, 1); assert.equal(slow.got, 0); assert.equal(dead.got, 0); assert.equal(self.got, 0, 'never echoed to the sender');
  assert.equal(dead.closed, 1, 'a hopeless link is closed (the app reconnects and gets a SNAPSHOT)');
  assert.equal(hub.stats.posDropped - s0.posDropped, 1);
  assert.equal(hub.stats.slowKicked - s0.slowKicked, 1);
});

test('Sockets per account are bounded: the oldest makes room', async () => {
  const u = await rider('Many');
  const socks = [];
  for (let i = 0; i < 9; i++) { const s = await t.connect(u.token); await s.next((m) => m.type === 'HELLO'); socks.push(s); }
  assert.equal(await socks[0].closed, 1008);
  assert.equal(socks[8].readyState, 1);
  for (const s of socks) s.close();
});
