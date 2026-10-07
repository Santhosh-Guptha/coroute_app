'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const WebSocket = require('ws');
const config = require('../src/config');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { encodeVoice, VOICE_START } = require('../src/ws');

let gw, base, wsBase;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const { port } = gw.server.address();
  base = `http://127.0.0.1:${port}/api`;
  wsBase = `ws://127.0.0.1:${port}/ws`;
});
after(async () => { await gw.shutdown(); });

async function api(method, path, body, token) {
  const res = await fetch(base + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return { status: res.status, json: await res.json().catch(() => ({})), headers: res.headers };
}

function wsConnect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsBase}?token=${token}`);
    ws.inbox = [];
    ws.on('message', (d, bin) => { if (!bin) ws.inbox.push(JSON.parse(d.toString())); });
    ws.wait = async (pred, ms = 1500) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const i = ws.inbox.findIndex(pred);
        if (i >= 0) return ws.inbox.splice(i, 1)[0];
        await new Promise((r) => setTimeout(r, 10));
      }
      throw new Error('timeout');
    };
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

test('the app is told exactly when a session really ended, and never otherwise', async () => {
  const reg = await api('POST', '/auth/register', { name: 'Session Sam', email: 'sam@coroute.test', password: 'Password#123', phone: '9999999999', vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' });
  assert.equal(reg.status, 201);

  // Invalid token: 401 with the SESSION_INVALID code (the only 401 the app signs out on).
  const bad = await api('GET', '/me', null, 'not-a-token');
  assert.equal(bad.status, 401);
  assert.equal(bad.json.code, 'SESSION_INVALID');

  // Wrong password at sign-in is a 401 too, but without that code.
  const wrong = await api('POST', '/auth/login', { identifier: 'sam@coroute.test', password: 'nope-nope' });
  assert.equal(wrong.status, 401);
  assert.notEqual(wrong.json.code, 'SESSION_INVALID');

  // Fresh token: no refresh header. Day-old token: a new token comes back, built from the database user.
  const fresh = await api('GET', '/me', null, reg.json.token);
  assert.equal(fresh.status, 200);
  assert.equal(fresh.headers.get('x-coroute-token'), null);
  // (The account must be older than the token: a token older than its account is refused.)
  const stored = await gw.repo.findUserById(reg.json.user.userId);
  await gw.repo.updateUser(stored.key, { createdAt: Date.now() - 3 * 86400000 });
  gw.gate.invalidate(reg.json.user.userId);
  const old = jwt.sign({ sub: reg.json.user.userId, name: 'Session Sam', role: 'RIDER', email: 'sam@coroute.test', iat: Math.floor(Date.now() / 1000) - 2 * 86400 },
    config.jwtSecret, { expiresIn: '28d', issuer: 'coroute-gateway' });
  const refreshed = await api('GET', '/me', null, old);
  assert.equal(refreshed.status, 200);
  const next = refreshed.headers.get('x-coroute-token');
  assert.ok(next, 'refresh header present');
  const claims = jwt.verify(next, config.jwtSecret);
  assert.equal(claims.sub, reg.json.user.userId);
  assert.ok(claims.exp - claims.iat >= 29 * 86400);

  // Non-session errors carry no sign-out code.
  const notMember = await api('GET', '/convoys/GRP-NOPE', null, reg.json.token);
  assert.equal(notMember.status, 403);
  assert.notEqual(notMember.json.code, 'SESSION_INVALID');

  // Over the socket: a 1:1 call to someone offline is an error without a reason (the app must stay in the convoy);
  // joining a convoy you are not in carries NOT_MEMBER.
  const conv = await api('POST', '/convoys', { name: 'Session ride' }, reg.json.token);
  const ws = await wsConnect(reg.json.token);
  ws.send(JSON.stringify({ type: 'JOIN', groupId: conv.json.groupId }));
  await ws.wait((m) => m.type === 'SNAPSHOT');
  ws.send(encodeVoice(VOICE_START, { to: 'u_offline_rider', sampleRate: 16000 }, null));
  const voiceErr = await ws.wait((m) => m.type === 'ERROR');
  assert.equal(voiceErr.code, 404);
  assert.equal(voiceErr.reason, undefined);
  ws.send(JSON.stringify({ type: 'CONFIG', distanceThresholdMeters: 500 }));
  ws.send(JSON.stringify({ type: 'JOIN', groupId: 'GRP-NOT-MINE' }));
  const joinErr = await ws.wait((m) => m.type === 'ERROR');
  assert.equal(joinErr.reason, 'NOT_MEMBER');
  ws.close();

  // Deleted account: ACCOUNT_GONE.
  await api('DELETE', '/me', null, reg.json.token);
  const gone = await api('GET', '/me', null, reg.json.token);
  assert.equal(gone.status, 404);
  assert.equal(gone.json.code, 'ACCOUNT_GONE');
});
