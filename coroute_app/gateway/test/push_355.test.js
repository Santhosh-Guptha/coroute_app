'use strict';
/**
 * 3.55 push notifications (src/push.js, docs/features_355/push_notifications.md): token registry
 * (register, 5-token limit, delete, erase), disabled when FCM is not configured, privacy of the
 * payload, pruning of invalid tokens, retries, the admin switch, no push when a live socket got the
 * event, and the friend request / crew invite / poll hooks. FCM is a fake transport (no network).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'pushadmin@coroute.test';
delete process.env.FCM_SERVICE_ACCOUNT_JSON;
delete process.env.FCM_SERVICE_ACCOUNT_FILE;

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const F = require('../src/friends');
const P = require('../src/push');

const sent = [];
let nextReply = null; // (message) => {status, body} for the next calls, null = 200
const transport = async (message) => {
  sent.push(message);
  return nextReply ? nextReply(message) : { status: 200, body: { name: 'projects/x/messages/1' } };
};
const tok = (n) => `fcmtoken_${String(n).padStart(4, '0')}_${'x'.repeat(40)}`;

let t, admin;
before(async () => {
  t = await boot({ pushTransport: transport });
  const ips = new Map();
  const call = t.api;
  t.api = (m, p, b, token, h = {}) => {
    if (!ips.has(token)) ips.set(token, `198.51.${100 + (ips.size >> 8)}.${ips.size % 256}`);
    return call(m, p, b, token, { 'X-Forwarded-For': ips.get(token), ...h });
  };
  admin = await t.register('Push Console', 'pushadmin@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

let seq = 0;
async function rider(name) {
  seq++;
  const r = await t.api('POST', '/auth/register', {
    name, email: `push${seq}_${Date.now()}@coroute.test`, password: 'Password#123',
    phone: `+9196${String(10000000 + seq).slice(-8)}`, vehicleType: 'Motorcycle', vehicleNo: `KA02PU${String(1000 + seq).slice(-4)}`,
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  }, null, { 'X-Forwarded-For': `203.0.113.${(seq % 250) + 1}` });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}
const register = (u, token, extra = {}) => t.api('POST', '/me/push-tokens', { token, platform: 'android', appVersion: '3.55.0', ...extra }, u.token);
const waitFor = async (pred, ms = 2000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (pred()) return true; await sleep(10); }
  return pred();
};
const forToken = (token) => sent.filter((m) => m.message.token === token);

test('register, validation, 5 tokens per rider (oldest dropped), delete', async () => {
  const a = await rider('Asha Token');
  assert.equal((await register(a, 'short')).status, 400);
  assert.equal((await register(a, tok(1), { platform: 'symbian' })).status, 400);
  assert.equal((await register(a, tok(1), { appVersion: '<script>' })).status, 400);
  assert.equal((await t.api('POST', '/me/push-tokens', { token: tok(1) }, null)).status, 401);
  assert.equal((await register(a, tok(1))).status, 200);
  for (let i = 2; i <= 7; i++) {
    await sleep(2);
    await t.gw.push.registerToken(a.user.userId, { token: tok(i), platform: 'android', appVersion: '3.55.0' });
  }
  let mine = (await t.gw.push.tokensOf(a.user.userId)).map((x) => x.token).sort();
  assert.deepEqual(mine, [3, 4, 5, 6, 7].map(tok).sort(), 'the newest five are kept');
  // Same token again: updated, not duplicated.
  assert.equal((await register(a, tok(7))).status, 200);
  assert.equal((await t.gw.push.tokensOf(a.user.userId)).length, 5);
  // Another rider cannot delete my token; I can.
  const b = await rider('Bala Other');
  assert.equal((await t.api('DELETE', '/me/push-tokens', { token: tok(7) }, b.token)).json.removed, 0);
  assert.equal((await t.api('DELETE', '/me/push-tokens', { token: tok(7) }, a.token)).json.removed, 1);
  mine = (await t.gw.push.tokensOf(a.user.userId)).map((x) => x.token);
  assert.ok(!mine.includes(tok(7)));
  // A token signed in on another account moves to that account.
  assert.equal((await register(b, tok(6))).status, 200);
  assert.ok(!(await t.gw.push.tokensOf(a.user.userId)).some((x) => x.token === tok(6)));
  // Sign-out: DELETE without a token removes all of mine.
  await t.api('DELETE', '/me/push-tokens', {}, a.token);
  assert.equal((await t.gw.push.tokensOf(a.user.userId)).length, 0);
  // Rate limited (10 a minute per rider).
  let limited = false;
  for (let i = 0; i < 12 && !limited; i++) limited = (await register(b, tok(400 + i))).status === 429;
  assert.ok(limited, 'token writes are rate limited');
});

test('disabled when FCM is not configured: no-op, logged once, never throws', async () => {
  const logs = [];
  const logger = { info: (m) => logs.push(m), warn: (m) => logs.push(m), error() {} };
  const svc = new P.PushService({ soda: new MemorySoda(), logger, env: {} });
  assert.equal(svc.enabled, false);
  await svc.registerToken('u1', { token: tok(50) });
  const r1 = await svc.notifyUsers(['u1'], { type: 'FRIEND_REQUEST', title: 'x', body: 'y' });
  const r2 = await svc.notifyUsers(['u1'], { type: 'FRIEND_REQUEST', title: 'x', body: 'y' });
  assert.equal(r1.disabled, 'unconfigured');
  assert.equal(r1.sent + r2.sent, 0);
  assert.equal(logs.filter((m) => /not configured/.test(m)).length, 1, 'logged once');
  // A broken soda never makes notifyUsers throw.
  const broken = new P.PushService({ soda: { ensureCollection: async () => { throw new Error('db down'); } }, transport, logger });
  const out = await broken.notifyUsers(['u1'], { type: 'FRIEND_REQUEST', title: 'x', body: 'y' });
  assert.equal(out.sent, 0);
  // Incomplete service account -> disabled.
  assert.equal(P.serviceAccountFromEnv({ FCM_SERVICE_ACCOUNT_JSON: '{"client_email":"a@b"}' }, logger), null);
  assert.equal(P.serviceAccountFromEnv({ FCM_SERVICE_ACCOUNT_JSON: 'not json' }, logger), null);
});

test('payload: data-only, no sensitive fields, priority / TTL / collapse by type', () => {
  const m = P.buildMessage(tok(1), {
    type: 'FRIEND_REQUEST', title: 'Friend request', body: 'SwiftFalcon482 (call +91 98765 43210, a@b.com) sent you a friend request',
    data: { requestId: 'fr_0123456789abcdef0123', phone: '+919876543210', email: 'a@b.com', userId: 'u_1', homeLat: 12.9, location: 'x',
      medicalInfo: 'O+', emergencyContact: '+91900', note: 'mail me at x@y.org', nested: { a: 1 } },
  });
  assert.equal(m.message.notification, undefined, 'data-only');
  const d = m.message.data;
  assert.deepEqual(Object.keys(d).sort(), ['body', 'requestId', 'title', 'type']);
  for (const v of Object.values(d)) assert.equal(typeof v, 'string');
  assert.ok(!/98765|@/.test(d.body), d.body);
  assert.match(d.body, /SwiftFalcon482/);
  assert.equal(m.message.android.priority, 'NORMAL');
  assert.equal(m.message.android.ttl, `${3 * 24 * 3600}s`);
  const ride = P.buildMessage(tok(1), { type: 'RIDE_INVITE', title: 'Ride invite', body: 'x', data: { inviteId: 'ri_1' }, collapseKey: 'ride_ri_1' });
  assert.equal(ride.message.android.priority, 'HIGH');
  assert.equal(ride.message.android.ttl, '1800s');
  assert.equal(ride.message.android.collapse_key, 'ride_ri_1');
  assert.ok(P.HOSTS.has('fcm.googleapis.com') && P.HOSTS.size === 1);
});

test('invalid tokens are pruned; 429 / 5xx retried with backoff; throttle per user', async () => {
  const soda = new MemorySoda();
  const waits = [];
  let calls = 0;
  const svc = new P.PushService({ soda, logger: { info() {}, warn() {} }, sleep: async (ms) => { waits.push(ms); },
    transport: async (msg) => {
      calls++;
      if (msg.message.token === tok(60)) return { status: 404, body: { error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } } };
      if (msg.message.token === tok(61)) return { status: 400, body: { error: { status: 'INVALID_ARGUMENT' } } };
      if (msg.message.token === tok(62) && calls < 5) return { status: 503, body: null };
      return { status: 200, body: {} };
    } });
  await svc.registerToken('u1', { token: tok(60) });
  await svc.registerToken('u1', { token: tok(61) });
  await svc.registerToken('u1', { token: tok(62) });
  const out = await svc.notifyUsers(['u1'], { type: 'FRIEND_ACCEPTED', title: 'New friend', body: 'x' });
  assert.equal(out.sent, 1);
  assert.deepEqual((await svc.tokensOf('u1')).map((x) => x.token), [tok(62)], 'unregistered and invalid tokens pruned');
  assert.deepEqual(waits, [1000, 2000], 'exponential backoff on 503');
  // Throttle: a small limit stops a flood.
  const svc2 = new P.PushService({ soda, transport: async () => ({ status: 200 }), perUserLimit: 2, logger: { info() {}, warn() {} } });
  const res = [];
  for (let i = 0; i < 4; i++) res.push(await svc2.notifyUsers(['u1'], { type: 'POLL_CREATED', title: 't', body: 'b' }));
  assert.equal(res.reduce((n, r) => n + r.sent, 0), 2);
});

test('friend request and accept push the other rider when offline; nothing when a socket got it', async () => {
  const a = await rider('Arun Sender');
  const b = await rider('Bina Target');
  assert.equal((await register(b, tok(100))).status, 200);
  assert.equal((await register(a, tok(101))).status, 200);
  sent.length = 0;
  const req = await t.api('POST', '/friends/requests', { username: b.user.username }, a.token);
  assert.equal(req.status, 202, JSON.stringify(req.json));
  assert.ok(await waitFor(() => forToken(tok(100)).length === 1), 'push sent to the offline rider');
  const msg = forToken(tok(100))[0].message;
  assert.equal(msg.data.type, 'FRIEND_REQUEST');
  assert.equal(msg.data.body, `${a.user.username} sent you a friend request`);
  assert.match(msg.data.requestId, /^fr_/);
  const raw = JSON.stringify(msg);
  for (const needle of [a.user.userId, b.user.userId, a.user.email, a.user.phone, 'Family Contact', '+919000000001']) {
    if (needle) assert.ok(!raw.includes(needle), `payload leaks ${needle}`);
  }
  // b is online now: the accept notification reaches a's socket? a is offline -> push to a.
  const wsB = await t.connect(b.token);
  await sleep(50);
  const list = await t.api('GET', '/friends/requests', null, b.token);
  const rid = (list.json.incoming || list.json.requests || []).map((x) => x.requestId).find(Boolean) || msg.data.requestId;
  assert.equal((await t.api('POST', `/friends/requests/${rid}/accept`, null, b.token)).status, 200);
  assert.ok(await waitFor(() => forToken(tok(101)).some((m) => m.message.data.type === 'FRIEND_ACCEPTED')));

  // a connected: a friend request from c reaches a's socket, so no push.
  const c = await rider('Chetan Third');
  const wsA = await t.connect(a.token);
  await sleep(50);
  sent.length = 0;
  assert.equal((await t.api('POST', '/friends/requests', { username: a.user.username }, c.token)).status, 202);
  await wsA.next((m) => m.type === 'FRIEND_REQUEST');
  await sleep(100);
  assert.equal(forToken(tok(101)).length, 0, 'socket delivered: no push');
  wsA.close(); wsB.close();
});

test('crew invite and poll created push offline members', async () => {
  const owner = await rider('Owner Crew');
  const mate = await rider('Mate Crew');
  const out = await F.sendRequest(t.soda, owner.user.userId, mate.user.userId);
  await F.respond(t.soda, mate.user.userId, out.edge.requestId, true);
  assert.equal((await register(mate, tok(200))).status, 200);
  const crew = (await t.api('POST', '/crews', { name: 'Push Riders', description: 'Test' }, owner.token)).json.crew;
  assert.ok(crew && crew.crewId);
  sent.length = 0;
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/invites`, { username: mate.user.username }, owner.token)).status, 201);
  assert.ok(await waitFor(() => forToken(tok(200)).some((m) => m.message.data.type === 'CREW_INVITE')));
  const inv = forToken(tok(200)).find((m) => m.message.data.type === 'CREW_INVITE').message.data;
  assert.equal(inv.crewId, crew.crewId);
  assert.ok(inv.inviteId);
  assert.equal((await t.api('POST', `/crews/invites/${inv.inviteId}/accept`, null, mate.token)).status, 200);
  sent.length = 0;
  const poll = await t.api('POST', `/crews/${crew.crewId}/polls`, { question: 'Sunday ride time?', options: ['6 am', '7 am'] }, owner.token);
  assert.equal(poll.status, 201, JSON.stringify(poll.json));
  assert.ok(await waitFor(() => forToken(tok(200)).some((m) => m.message.data.type === 'POLL_CREATED')));
  const p = forToken(tok(200)).find((m) => m.message.data.type === 'POLL_CREATED').message.data;
  assert.equal(p.pollId, poll.json.poll.pollId);
  assert.equal(p.crewId, crew.crewId);
});

test('RIDE_INVITE always pushes (even when connected); admin switch stops pushes; erase removes tokens', async () => {
  const r = await rider('Ride Invitee');
  assert.equal((await register(r, tok(300))).status, 200);
  const ws = await t.connect(r.token);
  await sleep(50);
  sent.length = 0;
  const out = await t.gw.push.onSocketEvent(r.user.userId, { type: 'RIDE_INVITE', inviteId: 'ri_abc', username: 'SwiftFalcon482' }, { delivered: 1 });
  assert.equal(out.sent, 1);
  assert.equal(forToken(tok(300))[0].message.android.priority, 'HIGH');
  const skip = await t.gw.push.onSocketEvent(r.user.userId, { type: 'FRIEND_REQUEST', requestId: 'fr_x', username: 'X' }, { delivered: 1 });
  assert.equal(skip, null);
  ws.close();

  assert.equal((await t.api('PUT', '/admin/features/pushNotifications', { enabled: false, reason: 'test' }, admin.token)).status, 200);
  const off = await t.gw.push.notifyUsers([r.user.userId], { type: 'RIDE_INVITE', title: 'x', body: 'y' });
  assert.equal(off.disabled, 'switch');
  assert.equal(off.sent, 0);
  assert.equal((await t.api('PUT', '/admin/features/pushNotifications', { enabled: true }, admin.token)).status, 200);

  assert.equal((await t.api('DELETE', '/me', null, r.token)).status, 200);
  await sleep(50);
  assert.equal((await t.gw.push.tokensOf(r.user.userId)).length, 0, 'tokens erased with the account');
});
