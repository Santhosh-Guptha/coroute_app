'use strict';
/**
 * Round 4 ride lock (src/ride_lock.js, docs/features_355/sessions_and_security.md §9): no sign-in on another device
 * while this account's device is on a live ride; same device allowed; stale heartbeat and ended rides unlock; the
 * e-mail code override hands the ride over (SOS kept, old session revoked to safety-only); rate limits; no
 * enumeration; other sessions cannot start / join a ride; admin "End ride lock"; two nodes sharing the database.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'lock.admin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
process.env.BLIND_INDEX_KEY = Buffer.alloc(32, 5).toString('base64');

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const config = require('../src/config');
const { boot, sleep } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');

let env; let ipSeq = 0;
const mails = [];
const mailTransport = { sendMail: async (m) => { mails.push(m); return { messageId: `m${mails.length}` }; } };
const googleVerifier = { verifyIdToken: async ({ idToken }) => ({ getPayload: () => ({ email: idToken, email_verified: true, sub: `g-${idToken}`, iss: 'accounts.google.com', name: 'G Rider' }) }) };
const ip = () => `10.88.${Math.floor(++ipSeq / 250)}.${ipSeq % 250}`;
const APP2 = { 'X-CoRoute-Session': '2', 'X-CoRoute-Client': 'app', 'X-CoRoute-Build': '10025' };
const DEV_A = { id: 'devA-0123456789abcdef', installId: 'instA-0123456789abcdef', label: 'Pixel 7', platform: 'android' };
const DEV_B = { id: 'devB-0123456789abcdef', installId: 'instB-0123456789abcdef', label: 'Galaxy S24', platform: 'android' };

before(async () => { env = await boot({ mailTransport, googleVerifier }); });
after(async () => { await env.gw.shutdown(); });

const call = (method, path, body, token, headers = {}, e = env) => e.api(method, path, body, token, { 'X-Forwarded-For': ip(), ...headers });
async function rider(tag, e = env) {
  const r = await call('POST', '/auth/register', {
    name: `Lock ${tag}`, email: `lock.${tag}@coroute.test`, password: 'Password#123', phone: '+919876543210',
    vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  }, null, {}, e);
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return { ...r.json, email: `lock.${tag}@coroute.test` };
}
const login = (email, device, { password = 'Password#123', headers = APP2, client, e = env } = {}) =>
  call('POST', '/auth/login', { identifier: email, password, ...(device ? { device } : {}), ...(client ? { client } : {}) }, null, client ? {} : headers, e);
const mailsTo = (to, subject) => mails.filter((m) => m.to === to && (!subject || String(m.subject).includes(subject)));
const codeIn = (m) => /\b(\d{6})\b/.exec(m.text)[1];

/** A rider whose phone (device A) is on a solo ride with its socket joined. */
async function onRide(tag, e = env) {
  const u = await rider(tag, e);
  const phone = await login(u.email, DEV_A, { e });
  assert.equal(phone.status, 200, JSON.stringify(phone.json));
  const c = await call('POST', '/convoys', { name: `Ride ${tag}` }, phone.json.token, {}, e);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  const ws = await e.joinRoom(phone.json.token, c.json.groupId);
  return { u, phone, groupId: c.json.groupId, joinCode: c.json.joinCode, ws };
}

async function auditRows(e = env) {
  await e.gw.audit.flush();
  return (await e.gw.soda.query('safety_audit', { kind: 'AUTH' }, { limit: 500 })).map((r) => r.value);
}

test('a sign-in on another device during an active ride answers 423 with the device label only; the password is checked first', async () => {
  const { u, ws } = await onRide('block');
  const b = await login(u.email, DEV_B);
  assert.equal(b.status, 423, JSON.stringify(b.json));
  assert.equal(b.json.code, 'RIDE_ACTIVE_ELSEWHERE');
  assert.equal(b.json.error, "You're on a ride on Pixel 7. End the ride on that phone to sign in here.");
  assert.equal(b.json.device, 'Pixel 7');
  assert.ok(b.json.lockToken, 'override token');
  const body = JSON.stringify(b.json);
  assert.ok(!/GRP-|lat|lng|groupId|Ride block/.test(body), 'no ride details or location');
  // Every sign-in route: the website, /account, admin and operator consoles, old builds (no headers), Google.
  for (const client of ['web', 'admin', 'operator']) {
    const r = await login(u.email, null, { client });
    assert.equal(r.status, 423, `${client}: ${JSON.stringify(r.json)}`);
  }
  const old = await login(u.email, null, { headers: {} });
  assert.equal(old.status, 423);
  assert.equal(typeof old.json.error, 'string', 'old builds show `error` as is');
  const g = await call('POST', '/auth/google', { idToken: u.email, device: DEV_B }, null, APP2);
  assert.equal(g.status, 423, JSON.stringify(g.json));
  // No enumeration: a wrong password is the usual 401, exactly as for an unknown account.
  const wrong = await login(u.email, DEV_B, { password: 'Wrong#Password1' });
  const unknown = await login('nobody.lock@coroute.test', DEV_B, { password: 'Wrong#Password1' });
  assert.equal(wrong.status, 401);
  assert.deepEqual(wrong.json, unknown.json);
  const rows = await auditRows();
  assert.ok(rows.some((r) => r.subjectId === u.user.userId && /^RIDE_LOCK_BLOCK/.test(r.detail)), 'blocks are audited');
  ws.close();
});

test('the same device signs in again (same device id after a reinstall, or same install id); the ride stays locked for others', async () => {
  const { u, ws } = await onRide('same');
  const reinstall = await login(u.email, { ...DEV_A, installId: 'instNEW-0123456789abcdef' });
  assert.equal(reinstall.status, 200, JSON.stringify(reinstall.json));
  const sameInstall = await login(u.email, { ...DEV_A, id: 'devOTHER-0123456789abcd' });
  assert.equal(sameInstall.status, 200);
  assert.equal((await login(u.email, DEV_B)).status, 423);
  ws.close();
});

test('a stale heartbeat unlocks (RIDE_LOCK_STALE_MIN), and a fresh one locks again', async () => {
  const { u, phone, ws } = await onRide('stale');
  assert.equal((await login(u.email, DEV_B)).status, 423);
  const r = await env.gw.soda.findOne('auth_sessions', { sessionId: phone.json.sessionId });
  const old = Date.now() - (config.rideLockStaleMin + 1) * 60000;
  await env.gw.soda.replace('auth_sessions', r.key, { ...r.value, lastSeenAt: old, rideSeenAt: old });
  env.gw.sessions.invalidateLocal({ sids: [phone.json.sessionId] });
  const ok = await login(u.email, DEV_B);
  assert.equal(ok.status, 200, 'a silent phone does not lock the account');
  ws.close();
});

test('a ride that ended normally unlocks at once', async () => {
  const { u, phone, groupId, ws } = await onRide('ended');
  assert.equal((await login(u.email, DEV_B)).status, 423);
  assert.equal((await call('POST', `/convoys/${groupId}/status`, { status: 'ENDED' }, phone.json.token)).status, 200);
  assert.equal((await login(u.email, DEV_B)).status, 200);
  ws.close();
});

test('sessions signed in before the ride stay signed in but cannot start or join a second ride (409); the riding phone can', async () => {
  const u = await rider('second');
  const tablet = await login(u.email, DEV_B);
  const phone = await login(u.email, DEV_A);
  const c = await call('POST', '/convoys', { name: 'Ride second' }, phone.json.token);
  assert.equal(c.status, 201);
  const ws = await env.joinRoom(phone.json.token, c.json.groupId);
  assert.equal((await call('GET', '/me', null, tablet.json.token)).status, 200, 'still signed in');
  const start = await call('POST', '/convoys', { name: 'Second ride' }, tablet.json.token);
  assert.equal(start.status, 409, JSON.stringify(start.json));
  assert.equal(start.json.code, 'RIDE_ACTIVE_ELSEWHERE');
  const other = await rider('secondhost');
  const oc = await call('POST', '/convoys', { name: 'Other ride' }, other.token);
  const join = await call('POST', '/convoys/join', { code: oc.json.joinCode }, tablet.json.token);
  assert.equal(join.status, 409);
  assert.equal(join.json.code, 'RIDE_ACTIVE_ELSEWHERE');
  // The tablet's socket cannot join the ride either.
  const tws = await env.connect(tablet.json.token);
  await tws.next((m) => m.type === 'HELLO');
  tws.sendJson({ type: 'JOIN', groupId: c.json.groupId });
  const err = await tws.next((m) => m.type === 'ERROR');
  assert.equal(err.reason, 'RIDE_ACTIVE_ELSEWHERE');
  tws.close(); ws.close();
});

test('e-mail code override: code mailed, wrong tries counted, the right code signs in, the ride is handed over, an open SOS stays, the old session is revoked to safety-only', async () => {
  const { u, phone, groupId, joinCode, ws } = await onRide('override');
  // A group member to watch what the group sees (the ride was solo-sized; use a group host instead).
  void joinCode;
  ws.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4, clientId: 'sos-before-handover' });
  const own = await ws.next((m) => m.type === 'ALERT');
  const alertId = own.alert.alertId;
  const b = await login(u.email, DEV_B);
  assert.equal(b.status, 423);
  mails.length = 0;
  const sent = await call('POST', '/auth/ride-lock/code', { lockToken: b.json.lockToken });
  assert.equal(sent.status, 202, JSON.stringify(sent.json));
  assert.equal(sent.json.resendAfterSec, 60);
  const m = mailsTo(u.email, 'Ride sign-in code')[0];
  assert.ok(m, 'code e-mail sent');
  assert.match(m.text, /Someone \(hopefully you\) is trying to sign in on Galaxy S24 while you're on a ride on Pixel 7\./);
  assert.match(m.text, /If this wasn't you, change your password\./);
  assert.ok(m.html.includes(codeIn(m)), 'HTML part carries the code');
  const code = codeIn(m);
  // Resend inside 60 s: refused (rate limited per account).
  const again = await call('POST', '/auth/ride-lock/code', { lockToken: b.json.lockToken });
  assert.equal(again.status, 429);
  // A wrong code counts a try.
  const wrongCode = code === '000000' ? '111111' : '000000';
  const w = await call('POST', '/auth/ride-lock/verify', { lockToken: b.json.lockToken, code: wrongCode });
  assert.equal(w.status, 401);
  assert.equal(w.json.code, 'CODE_WRONG');
  assert.equal(w.json.triesLeft, config.emailCodeMaxTries - 1);
  // The right code: signed in on device B.
  const ok = await call('POST', '/auth/ride-lock/verify', { lockToken: b.json.lockToken, code }, null, APP2);
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.ok(ok.json.token && ok.json.refreshToken);
  assert.equal(ok.json.handedOver, true);
  // Single use.
  assert.equal((await call('POST', '/auth/ride-lock/verify', { lockToken: b.json.lockToken, code })).status, 401);
  // The old phone: REST refused, its socket kept in safety-only mode for the ride.
  assert.equal((await call('GET', '/me', null, phone.json.token)).status, 401);
  await ws.next((x) => x.type === 'SAFETY_ONLY');
  // The group hears "<rider> switched phones"; the SOS is still open (memory and database).
  const room = env.gw.convoys.rooms.get(groupId);
  assert.ok(room.messages.some((x) => x.text === 'Lock override switched phones'), 'system card in the ride chat');
  assert.equal(room.alerts.get(alertId).resolved, false, 'open SOS untouched');
  const stored = await env.gw.soda.findOne('alerts', { alertId });
  assert.equal(stored.value.resolved, false);
  // Notice e-mail and audit.
  assert.ok(mailsTo(u.email, 'Signed in during a ride').length === 1, 'notice e-mail');
  const rows = await auditRows();
  assert.ok(rows.some((r) => r.subjectId === u.user.userId && /^RIDE_LOCK_OVERRIDE/.test(r.detail)));
  // The new phone is not locked out by the old one any more; it can join the ride and becomes the riding phone.
  const nws = await env.joinRoom(ok.json.token, groupId);
  await sleep(50);
  assert.equal((await login(u.email, { ...DEV_A, id: 'devC-0123456789abcdef', installId: 'instC-0123456789abcdef' })).status, 423, 'locked to the new phone now');
  nws.close(); ws.close();
});

test('the group sees the handover (another rider in the ride)', async () => {
  const host = await rider('hohost');
  const u = await rider('homember');
  const phone = await login(u.email, DEV_A);
  const c = await call('POST', '/convoys', { name: 'Handover group' }, host.token);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  const j = await call('POST', '/convoys/join', { code: c.json.joinCode }, phone.json.token);
  assert.equal(j.status, 200, JSON.stringify(j.json));
  const hws = await env.joinRoom(host.token, c.json.groupId);
  const pws = await env.joinRoom(phone.json.token, c.json.groupId);
  const b = await login(u.email, DEV_B);
  assert.equal(b.status, 423);
  mails.length = 0;
  await call('POST', '/auth/ride-lock/code', { lockToken: b.json.lockToken });
  const code = codeIn(mailsTo(u.email, 'Ride sign-in code')[0]);
  assert.equal((await call('POST', '/auth/ride-lock/verify', { lockToken: b.json.lockToken, code })).status, 200);
  const ho = await hws.next((m) => m.type === 'RIDER_HANDOVER');
  assert.equal(ho.userId, u.user.userId);
  const msg = await hws.next((m) => m.type === 'MESSAGE' && m.message && /switched phones/.test(m.message.text));
  assert.equal(msg.message.text, 'Lock homember switched phones');
  hws.close(); pws.close();
});

test('five wrong codes end the code; codes are rate limited per account and expire', async () => {
  const { u, ws } = await onRide('tries');
  const b = await login(u.email, DEV_B);
  mails.length = 0;
  await call('POST', '/auth/ride-lock/code', { lockToken: b.json.lockToken });
  const code = codeIn(mailsTo(u.email, 'Ride sign-in code')[0]);
  const wrongCode = code === '123456' ? '654321' : '123456';
  let last;
  for (let i = 0; i < config.emailCodeMaxTries; i++) last = await call('POST', '/auth/ride-lock/verify', { lockToken: b.json.lockToken, code: wrongCode });
  assert.equal(last.json.code, 'CODE_EXPIRED');
  assert.equal((await call('POST', '/auth/ride-lock/verify', { lockToken: b.json.lockToken, code })).json.code, 'CODE_EXPIRED', 'the right code no longer works');
  // An invalid / forged lock token is refused.
  assert.equal((await call('POST', '/auth/ride-lock/code', { lockToken: 'nope' })).status, 401);
  ws.close();
});

test('refresh: a session that never passed the lock check, created after the ride began on another device, cannot mint tokens', async () => {
  const { u, ws } = await onRide('refresh');
  const user = await env.gw.repo.findUserById(u.user.userId);
  const { session, refreshToken } = await env.gw.sessions.create({ user, kind: 'app', device: DEV_B, lockChecked: false });
  assert.ok(session.createdAt);
  const r = await call('POST', '/auth/refresh', { refreshToken });
  assert.equal(r.status, 423, JSON.stringify(r.json));
  assert.equal(r.json.code, 'RIDE_ACTIVE_ELSEWHERE');
  ws.close();
});

test('admin rider page: "On a ride (device)" and "End ride lock" (MASTER_ADMIN, reason required, audited)', async () => {
  const { u, ws } = await onRide('adminlock');
  const admin = await call('POST', '/auth/register', {
    name: 'Lock Admin', email: 'lock.admin@coroute.test', password: 'Password#123', phone: '+919876543211',
    vehicleNo: 'TS09AB9999', emergencyContact: '+919000000002', emergencyContactName: 'Family Contact',
  });
  const view = await call('GET', `/admin/riders/${u.user.userId}/ride-lock`, null, admin.json.token);
  assert.equal(view.status, 200, JSON.stringify(view.json));
  assert.equal(view.json.onRide, true);
  assert.equal(view.json.device, 'Pixel 7');
  const detail = await call('GET', `/admin/riders/${u.user.userId}`, null, admin.json.token);
  assert.equal(detail.json.rideLock.onRide, true);
  // A rider may not.
  const other = await rider('adminother');
  assert.equal((await call('POST', `/admin/riders/${u.user.userId}/ride-lock/end`, { reason: 'phone stolen' }, other.token)).status, 403);
  const noReason = await call('POST', `/admin/riders/${u.user.userId}/ride-lock/end`, {}, admin.json.token);
  assert.equal(noReason.status, 400);
  const end = await call('POST', `/admin/riders/${u.user.userId}/ride-lock/end`, { reason: 'Rider phoned support: phone broken' }, admin.json.token);
  assert.equal(end.status, 200, JSON.stringify(end.json));
  assert.equal(end.json.ended, true);
  assert.equal((await login(u.email, DEV_B)).status, 200, 'sign-in allowed after the admin ended the lock');
  // The ride goes on; its socket traffic does not bring the lock back for this ride.
  ws.sendJson({ type: 'PING' });
  await sleep(50);
  assert.equal((await call('GET', `/admin/riders/${u.user.userId}/ride-lock`, null, admin.json.token)).json.onRide, false);
  const rows = await auditRows();
  assert.ok(rows.some((r) => r.subjectId === u.user.userId && /^RIDE_LOCK_ADMIN_END/.test(r.detail)));
  ws.close();
});

test('RIDE_LOCK=off switches the rule off (rollback switch)', async () => {
  const { u, ws } = await onRide('off');
  config.rideLockEnabled = false;
  try { assert.equal((await login(u.email, DEV_B)).status, 200); } finally { config.rideLockEnabled = true; }
  ws.close();
});

test('two nodes sharing the database: the lock set on the live node blocks a sign-in on the web node; the handover reaches the group through the mirror', async () => {
  const KEY = 'test-mirror-key-0123456789-abcdefghijklmnop';
  const soda = new MemorySoda();
  const mk = (name, role, extra = {}) => boot({ soda, mailTransport, googleVerifier, mirror: { node: name, role, listenHost: '127.0.0.1', listenPort: 0, key: KEY, ackTimeoutMs: 400, startupWaitMs: 400, heartbeatMs: 100, deadMs: 800, reconnectMinMs: 50, reconnectMaxMs: 200, ...extra } });
  const A = await mk('vm1', 'live');
  const B = await mk('vm2', 'web', { peerUrl: `ws://127.0.0.1:${A.gw.mirror.port}/mirror` });
  A.gw.mirror.setPeer(`ws://127.0.0.1:${B.gw.mirror.port}/mirror`);
  try {
    const end = Date.now() + 4000;
    while (!(A.gw.mirror.linked() && B.gw.mirror.linked())) { if (Date.now() > end) throw new Error('link'); await sleep(20); }
    const u = await rider('twonode', A);
    const phone = await login(u.email, DEV_A, { e: A });
    const c = await call('POST', '/convoys', { name: 'Two node ride' }, phone.json.token, {}, A);
    assert.equal(c.status, 201);
    const ws = await A.joinRoom(phone.json.token, c.json.groupId);
    const b = await login(u.email, DEV_B, { e: B });
    assert.equal(b.status, 423, `web node sees the lock: ${JSON.stringify(b.json)}`);
    mails.length = 0;
    assert.equal((await call('POST', '/auth/ride-lock/code', { lockToken: b.json.lockToken }, null, {}, B)).status, 202);
    const code = codeIn(mailsTo(u.email, 'Ride sign-in code')[0]);
    const ok = await call('POST', '/auth/ride-lock/verify', { lockToken: b.json.lockToken, code }, null, APP2, B);
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
    // The revoke reaches the live node (mirror 'ss'): the old phone drops to safety-only; the group is told.
    await ws.next((m) => m.type === 'SAFETY_ONLY', 4000);
    const roomA = A.gw.convoys.rooms.get(c.json.groupId);
    const told = Date.now() + 3000;
    while (!roomA.messages.some((x) => /switched phones/.test(x.text))) { if (Date.now() > told) throw new Error('handover not told on the live node'); await sleep(20); }
    ws.close();
  } finally {
    await B.gw.shutdown(); await A.gw.shutdown();
  }
});
