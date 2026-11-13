'use strict';
/**
 * Round 8 abuse limits (src/ws_limits.js + src/ws.js): per-IP concurrent sockets (HTTP 429 at the upgrade), per-user
 * connect rate, per-socket token buckets with a warning frame and then a 4429 close, JOIN flood, invalid frames,
 * schema / size checks, idle and slow-reader timeouts, metrics for every limit, and above all: SOS frames are never
 * rate-limited below their floor, never dropped and never schema-rejected.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.WS_MAX_CONN_PER_IP = '3';
process.env.WS_RL_CHAT = '1/3';
process.env.WS_RL_KICK_DROPS = '10';
process.env.WS_JOIN_FAIL_MAX = '3';
process.env.WS_ALARMS_PER_10S = '3';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { boot, sleep } = require('./_helpers');
const RL = require('../src/ws_limits');

let t;
before(async () => { t = await boot({ emergencyFetch: async () => { throw new Error('offline in tests'); } }); });
after(async () => { await t.gw.shutdown(); });

let n = 0;
async function ride(tag, members = 1) {
  n++;
  const lead = await t.register(`Rl Lead ${tag}`, `rl8-lead-${tag}-${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Rl ${tag}` }, lead.token)).json;
  const riders = [];
  for (let i = 0; i < members; i++) {
    const r = await t.register(`Rl Rider ${tag}${i}`, `rl8-r${i}-${tag}-${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, r.token)).status, 200);
    riders.push(r);
  }
  return { lead, riders, gid: c.groupId };
}

/** A raw upgrade with X-Forwarded-For (the test talks to the gateway over loopback, a trusted proxy). */
function rawConnect(token, xff) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${t.wsBase}?token=${token}`, { headers: xff ? { 'X-Forwarded-For': xff } : {} });
    ws.on('open', () => resolve({ ws, status: 101 }));
    ws.on('unexpected-response', (req, res) => { resolve({ ws: null, status: res.statusCode, retryAfter: res.headers['retry-after'] }); req.destroy(); });
    ws.on('error', () => {});
  });
}

const closeOf = (ws) => new Promise((res) => {
  if (ws.readyState === WebSocket.CLOSED) return res({ code: ws.closeCode, reason: ws.closeReason });
  ws.on('close', (code, reason) => res({ code, reason: String(reason) }));
});

// ------------------------------------------------------------------ units
test('token bucket, classes and the safety exemption', () => {
  let now = 1000;
  const b = new RL.TokenBucket(2, 4, now);
  for (let i = 0; i < 4; i++) assert.equal(b.take(now), true);
  assert.equal(b.take(now), false);
  assert.equal(b.waitMs(now), 500);
  now += 500;
  assert.equal(b.take(now), true);
  for (const s of ['SOS', 'SOS_RESPOND', 'SOS_RESOLVE', 'WAIT', 'CHECK_IN', 'REPORT_DOWN', 'LAST_GASP_BEACON', 'ASSIST_ANSWER']) assert.equal(RL.classOf(s), 'safety', s);
  assert.equal(RL.classOf('TELEMETRY'), 'pos');
  assert.equal(RL.classOf('P2'), 'pos');
  assert.equal(RL.classOf('PR_SAY'), 'chat');
  assert.equal(RL.classOf('JOIN'), 'join');
  assert.equal(RL.classOf('STOP_ADD'), 'other');
  const sl = new RL.SocketLimiter({ ...RL.limitsConfig({}), kickDrops: 5 }, () => now);
  for (let i = 0; i < 1000; i++) assert.equal(sl.check('safety'), 'ok', 'safety is never limited');
});

test('per-socket limiter: drops cost strikes, a flood is kicked, a warning at most every 5 s', () => {
  let now = 0;
  const cfg = { ...RL.limitsConfig({}), chat: { rate: 1, burst: 2 }, kickDrops: 5 };
  const sl = new RL.SocketLimiter(cfg, () => now);
  assert.equal(sl.check('chat'), 'ok'); assert.equal(sl.check('chat'), 'ok');
  const seen = [];
  for (let i = 0; i < 6; i++) seen.push(sl.check('chat'));
  assert.deepEqual(seen, ['drop', 'drop', 'drop', 'drop', 'drop', 'kick']);
  assert.ok(sl.warn('chat') > 0); assert.equal(sl.warn('chat'), 0);
  now += 5000; assert.ok(sl.warn('chat') > 0);
});

test('schema check: structural only, safety always passes', () => {
  assert.equal(RL.validateInbound({ type: 'SOS', message: 'x'.repeat(100000) }, 100100), '', 'a huge SOS is never refused here');
  assert.equal(RL.validateInbound({ type: 'TELEMETRY', lat: 'abc' }, 40), '', 'junk numbers are coerced later, as before');
  assert.equal(RL.validateInbound({ type: 'TELEMETRY', pad: 'x'.repeat(5000) }, 5030), '', 'up to 16 KB: junk fields are coerced later');
  assert.equal(RL.validateInbound({ type: 'TELEMETRY', pad: 'x'.repeat(20000) }, 20030), 'too_big');
  assert.equal(RL.validateInbound({ type: 12 }, 20), 'bad_type');
  assert.equal(RL.validateInbound({ type: 'JOIN', groupId: 'G', caps: 'net1' }, 30), 'bad_caps');
  const many = { type: 'STATUS' }; for (let i = 0; i < 70; i++) many[`k${i}`] = 1;
  assert.equal(RL.validateInbound(many, 700), 'too_many_keys');
  assert.equal(RL.validateInbound({ type: 'P2', a: '1' }, 20), 'bad_number');
});

test('client IP: X-Forwarded-For only through trusted proxies; direct loopback without it is not counted', () => {
  const trusted = RL.trustFn(['loopback', '10.0.0.70']);
  const req = (addr, xff) => ({ socket: { remoteAddress: addr }, headers: xff ? { 'x-forwarded-for': xff } : {} });
  assert.deepEqual(RL.clientIpOf(req('127.0.0.1', '198.51.100.9'), trusted), { ip: '198.51.100.9', key: '198.51.100.9' });
  assert.deepEqual(RL.clientIpOf(req('::ffff:10.0.0.70', '198.51.100.9, 127.0.0.1'), trusted).ip, '198.51.100.9');
  assert.equal(RL.clientIpOf(req('198.51.100.5', '1.2.3.4'), trusted).ip, '198.51.100.5', 'an untrusted peer cannot claim an address');
  assert.equal(RL.clientIpOf(req('127.0.0.1'), trusted).key, null);
  assert.equal(RL.clientIpOf(req('203.0.113.4'), trusted).key, '203.0.113.4');
  const lim = new RL.IpConnLimiter({ maxPerIp: 2, perMin: 3 }, () => 0);
  assert.ok(lim.admit('a').ok); assert.ok(lim.admit('a').ok);
  assert.equal(lim.admit('a').reason, 'concurrent');
  lim.release('a');
  assert.equal(lim.admit('a').reason, 'rate', 'the 4th connect within the minute');
  assert.ok(lim.admit(null).ok);
});

// ------------------------------------------------------------------ live gateway
test('per-IP limit: the 4th socket from one address gets HTTP 429 at the upgrade; other addresses and loopback are not affected', async () => {
  const u = await t.register('Rl Ip', 'rl8-ip@coroute.test');
  const before = t.gw.hub.stats.rlIpConcurrent;
  const open = [];
  for (let i = 0; i < 3; i++) { const r = await rawConnect(u.token, '198.51.100.77'); assert.equal(r.status, 101); open.push(r.ws); }
  const refused = await rawConnect(u.token, '198.51.100.77');
  assert.equal(refused.status, 429);
  assert.ok(Number(refused.retryAfter) >= 5);
  assert.equal(t.gw.hub.stats.rlIpConcurrent, before + 1);
  const other = await rawConnect(u.token, '198.51.100.78');
  assert.equal(other.status, 101, 'another address');
  const local = await rawConnect(u.token, null);
  assert.equal(local.status, 101, 'direct loopback (tools on the VM) is not counted');
  open[0].close();
  await sleep(150);
  const again = await rawConnect(u.token, '198.51.100.77');
  assert.equal(again.status, 101, 'a closed socket frees its slot');
  for (const w of [...open, other.ws, local.ws, again.ws]) w.close();
});

test('per-user connect rate: a token opening sockets in a loop is closed 4429 TOO_MANY_CONNECTS', async () => {
  const u = await t.register('Rl Loop', 'rl8-loop@coroute.test');
  const hub = t.gw.hub;
  const saved = hub.userConnLimiter;
  hub.userConnLimiter = new RL.UserConnLimiter({ perMin: 2 });
  try {
    const a = await t.connect(u.token); const b = await t.connect(u.token);
    const c = await t.connect(u.token);
    const closed = await closeOf(c);
    assert.equal(closed.code, 4429);
    assert.equal(closed.reason, 'TOO_MANY_CONNECTS');
    assert.ok(hub.stats.rlUserConnect >= 1);
    a.close(); b.close();
  } finally { hub.userConnLimiter = saved; }
});

test('chat flood: dropped with ERROR 429 and a RATE_LIMIT warning, then closed 4429 RATE_LIMIT_CHAT', async () => {
  const R = await ride('chat');
  const ws = await t.joinRoom(R.lead.token, R.gid);
  for (let i = 0; i < 40; i++) ws.sendJson({ type: 'CHAT', text: `flood ${i}`, clientId: `fl-${i}` });
  const warn = await ws.next((m) => m.type === 'RATE_LIMIT');
  assert.equal(warn.class, 'chat');
  assert.ok(warn.retryMs > 0);
  const err = await ws.next((m) => m.type === 'ERROR' && m.code === 429);
  assert.equal(err.reason, 'RATE_LIMITED');
  assert.match(err.clientId, /^fl-/, 'the outbox keeps its clientId for a later retry');
  const closed = await closeOf(ws);
  assert.equal(closed.code, 4429);
  assert.equal(closed.reason, 'RATE_LIMIT_CHAT');
  assert.equal(ws.inbox.filter((m) => m.type === 'RATE_LIMIT').length, 0, 'one warning per 5 s (the first was consumed above)');
});

test('SOS is never limited: a socket that exhausted every bucket still raises and resends SOS; nothing is dropped or closed', async () => {
  const R = await ride('sos', 1);
  const ws = await t.joinRoom(R.riders[0].token, R.gid);
  const lead = await t.joinRoom(R.lead.token, R.gid);
  const kickedBefore = t.gw.hub.stats.rlKicked;
  // Spend the chat bucket and most strikes (kick at 10 drops): 3 pass, 8 dropped.
  for (let i = 0; i < 11; i++) ws.sendJson({ type: 'CHAT', text: `c ${i}` });
  await sleep(150);
  ws.inbox.length = 0;
  // 25 SOS presses with new clientIds in a burst: far above WS_ALARMS_PER_10S (3) and the floor (10).
  for (let i = 0; i < 25; i++) ws.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: `rl-sos-${i}` });
  const alert = await lead.next((m) => m.type === 'ALERT' && m.alert.userId === R.riders[0].user.userId);
  assert.ok(alert.alert.alertId);
  await sleep(600);
  assert.equal(ws.readyState, WebSocket.OPEN, 'never closed for SOS');
  assert.equal(t.gw.hub.stats.rlKicked, kickedBefore);
  assert.deepEqual(ws.inbox.filter((m) => m.type === 'ERROR'), [], 'no SOS is answered with an error');
  assert.ok(t.gw.hub.stats.sosOverBudget >= 15, 'presses above the floor were seen');
  assert.ok(ws.inbox.filter((m) => m.type === 'ALERT' && m.duplicate).length >= 15, 'each one above the floor got the open alert back');
  // A resend of the first SOS (same clientId) is still answered.
  ws.inbox.length = 0;
  ws.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'rl-sos-0' });
  const echo = await ws.next((m) => m.type === 'ALERT' && m.alert.alertId === alert.alert.alertId);
  assert.equal(echo.duplicate, true);
  // A huge SOS (fields far beyond any other type's size) is not schema-rejected either.
  const R2 = await ride('sosbig', 1);
  const w2 = await t.joinRoom(R2.riders[0].token, R2.gid);
  const l2 = await t.joinRoom(R2.lead.token, R2.gid);
  w2.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'rl-big', note: 'x'.repeat(60000) });
  assert.ok((await l2.next((m) => m.type === 'ALERT')).alert.alertId);
  for (const s of [ws, lead, w2, l2]) s.close();
});

test('SOS floor: up to WS_SOS_FLOOR_PER_10S presses on one socket are raised normally even when WS_ALARMS_PER_10S is 3', async () => {
  const R = await ride('floor', 1);
  const ws = await t.joinRoom(R.riders[0].token, R.gid);
  const before = t.gw.hub.stats.sosOverBudget;
  for (let i = 0; i < 10; i++) { ws.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: `fl-sos-${i}` }); await sleep(20); }
  await sleep(400);
  assert.equal(t.gw.hub.stats.sosOverBudget, before, 'ten presses stay under the floor');
  assert.deepEqual(ws.inbox.filter((m) => m.type === 'ERROR'), []);
  ws.close();
});

test('JOIN flood: refused JOINs close the socket 4429 JOIN_FLOOD', async () => {
  const u = await t.register('Rl Joiner', 'rl8-join@coroute.test');
  const ws = await t.connect(u.token);
  await ws.next((m) => m.type === 'HELLO');
  for (let i = 0; i < 5; i++) ws.sendJson({ type: 'JOIN', groupId: `GRP-NOPE00${i}` });
  const closed = await closeOf(ws);
  assert.equal(closed.code, 4429);
  assert.equal(closed.reason, 'JOIN_FLOOD');
  assert.ok(t.gw.hub.stats.rlJoinFlood >= 1);
});

test('invalid frames: ERROR 400 each, then 4400 INVALID_FRAMES; an oversized TELEMETRY is refused', async () => {
  const R = await ride('inv');
  const ws = await t.joinRoom(R.lead.token, R.gid);
  ws.sendJson({ type: 'TELEMETRY', lat: 17.4, lng: 78.4, pad: 'x'.repeat(20000) });
  const e = await ws.next((m) => m.type === 'ERROR' && m.code === 400);
  assert.equal(e.reason, 'INVALID_MESSAGE');
  for (let i = 0; i < 12; i++) ws.send('{not json');
  const closed = await closeOf(ws);
  assert.equal(closed.code, 4400);
  assert.equal(closed.reason, 'INVALID_FRAMES');
});

test('timeouts: an idle socket outside a ride closes 4408; a socket in a ride never does; a stalled reader closes 1013', async () => {
  const R = await ride('idle');
  const hub = t.gw.hub;
  const home = await t.connect(R.riders[0].token);
  await home.next((m) => m.type === 'HELLO');
  const inRide = await t.joinRoom(R.lead.token, R.gid);
  await sleep(50);
  const server = (uid) => [...hub.wss.clients].find((c) => c.user && c.user.userId === uid && c.readyState === WebSocket.OPEN);
  const sHome = server(R.riders[0].user.userId); const sRide = server(R.lead.user.userId);
  const saved = hub.limits;
  hub.limits = { ...saved, idleMs: 10, slowReaderMs: 10 };
  try {
    const later = Date.now() + 1000;
    assert.equal(hub._idleOrSlow(sRide, later), false, 'a rider in a ride is never idle-closed');
    assert.equal(hub._idleOrSlow(sHome, later), true);
    assert.deepEqual(await closeOf(home), { code: 4408, reason: 'IDLE_TIMEOUT' });
    // A reader that stopped: its buffer stays above the soft limit.
    Object.defineProperty(sRide, 'bufferedAmount', { get: () => 10 * 1024 * 1024, configurable: true });
    assert.equal(hub._idleOrSlow(sRide, later), false, 'first seen slow');
    assert.equal(hub._idleOrSlow(sRide, later + 50), true);
    assert.equal((await closeOf(inRide)).code, 1013);
  } finally { hub.limits = saved; }
});

test('metrics: every limit has a counter on /metrics', async () => {
  const text = await (await fetch(`${t.origin}/metrics`)).text();
  for (const k of ['rlIpConcurrent', 'rlIpRate', 'rlUserConnect', 'rlUserEvicted', 'rlWarned', 'rlKicked', 'rlInvalid', 'rlInvalidKicked', 'rlJoinFlood',
    'rlIdleClosed', 'rlSlowReader', 'rlDropChat', 'rlDropPos', 'sosOverBudget', 'sosOverFloorEcho', 'pos2In', 'interestHeld']) {
    assert.match(text, new RegExp(`coroute_ws_events_total\\{kind="${k}"\\} \\d+`), k);
  }
  assert.match(text, /coroute_ws_events_total\{kind="rlKicked"\} [1-9]/);
  assert.match(text, /coroute_ws_events_total\{kind="rlIpConcurrent"\} [1-9]/);
});
