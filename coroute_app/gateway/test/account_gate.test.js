'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'gateadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const WebSocket = require('ws');
const config = require('../src/config');
const { boot } = require('./_helpers');

let t, admin;
before(async () => {
  t = await boot();
  admin = await t.register('Gate Admin', 'gateadmin@coroute.test');
  assert.equal(admin.user.role, 'MASTER_ADMIN');
});
after(async () => { await t.gw.shutdown(); });

/** Opens a socket and resolves with its close code (or 'open' after HELLO). */
function socketOutcome(token, ms = 1000) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${t.wsBase}?token=${token}`);
    const timer = setTimeout(() => { resolve('open'); ws.close(); }, ms);
    ws.on('message', (d) => { if (JSON.parse(d.toString()).type === 'HELLO') { clearTimeout(timer); resolve('open'); ws.close(); } });
    ws.on('close', (code) => { clearTimeout(timer); resolve(code); });
    ws.on('error', () => {});
  });
}

test('a blocked rider is stopped on REST and on the socket at once', async () => {
  const u = await t.register('Gate Blocked', 'gateblocked@coroute.test');
  const ws = await t.connect(u.token);
  await ws.next((m) => m.type === 'HELLO');

  const r = await t.api('PATCH', `/admin/users/${u.user.userId}/status`, { status: 'BLOCKED', reason: 'test' }, admin.token);
  assert.equal(r.status, 200);
  const started = Date.now();
  assert.equal(await ws.closed, 4403);
  assert.ok(Date.now() - started < 1000, 'open socket closed within 1 s');

  const create = await t.api('POST', '/convoys', { name: 'Blocked ride' }, u.token);
  assert.equal(create.status, 403);
  assert.equal(create.json.code, 'ACCOUNT_BLOCKED');
  assert.equal(await socketOutcome(u.token), 4403, 'a new socket is refused');

  // On hold behaves the same; back to ACTIVE restores access at once.
  await t.api('PATCH', `/admin/users/${u.user.userId}/status`, { status: 'ON_HOLD' }, admin.token);
  const held = await t.api('GET', '/me', null, u.token);
  assert.equal(held.status, 403);
  assert.equal(held.json.code, 'ACCOUNT_ON_HOLD');
  await t.api('PATCH', `/admin/users/${u.user.userId}/status`, { status: 'ACTIVE' }, admin.token);
  assert.equal((await t.api('GET', '/me', null, u.token)).status, 200);
  assert.equal(await socketOutcome(u.token), 'open');
});

test('a deleted account is gone everywhere; its sockets are closed', async () => {
  const u = await t.register('Gate Deleted', 'gatedeleted@coroute.test');
  const ws = await t.connect(u.token);
  await ws.next((m) => m.type === 'HELLO');
  const del = await t.api('DELETE', `/admin/users/${u.user.userId}`, null, admin.token);
  assert.equal(del.status, 200);
  assert.equal(await ws.closed, 4401);
  const create = await t.api('POST', '/convoys', { name: 'Ghost ride' }, u.token);
  assert.equal(create.json.code, 'ACCOUNT_GONE');
  assert.equal(await socketOutcome(u.token), 4401);

  // Someone registering the same callsign later gets the same userId; the old token must not open the new account.
  const again = await t.register('Gate Deleted', 'gatedeleted2@coroute.test');
  assert.equal(again.user.userId, u.user.userId);
  const old = jwt.sign({ sub: u.user.userId, name: 'Gate Deleted', role: 'RIDER', email: 'gatedeleted@coroute.test', iat: Math.floor(Date.now() / 1000) - 60 },
    config.jwtSecret, { expiresIn: '30d', issuer: 'coroute-gateway' });
  const reuse = await t.api('GET', '/me', null, old);
  assert.equal(reuse.status, 401);
  assert.equal(reuse.json.code, 'SESSION_INVALID');
  assert.equal((await t.api('GET', '/me', null, again.token)).status, 200);
});

test('a demoted admin loses admin access at once (role comes from the database)', async () => {
  const a2 = await t.register('Second Admin', 'secondadmin@coroute.test');
  assert.equal((await t.api('PATCH', `/admin/users/${a2.user.userId}/role`, { role: 'MASTER_ADMIN' }, admin.token)).status, 200);
  // The token still says RIDER; the database says admin.
  assert.equal((await t.api('GET', '/admin/fleet', null, a2.token)).status, 200);
  assert.equal((await t.api('PATCH', `/admin/users/${a2.user.userId}/role`, { role: 'RIDER' }, admin.token)).status, 200);
  assert.equal((await t.api('GET', '/admin/fleet', null, a2.token)).status, 403);
});

test('a password change ends other sessions and keeps this device signed in', async () => {
  const u = await t.register('Gate Password', 'gatepassword@coroute.test');
  const other = await t.api('POST', '/auth/login', { identifier: 'gatepassword@coroute.test', password: 'Password#123' });
  const ws = await t.connect(other.json.token);
  await ws.next((m) => m.type === 'HELLO');

  const ch = await t.api('POST', '/me/password', { currentPassword: 'Password#123', newPassword: 'Changed#Pass42' }, u.token);
  assert.equal(ch.status, 200);
  assert.ok(ch.json.token);

  for (const oldToken of [u.token, other.json.token]) {
    const r = await t.api('GET', '/me', null, oldToken);
    assert.equal(r.status, 401);
    assert.equal(r.json.code, 'SESSION_INVALID');
  }
  assert.equal((await t.api('GET', '/me', null, ch.json.token)).status, 200);
  // The other device's open socket is closed on its next message.
  ws.sendJson({ type: 'PING' });
  assert.equal(await ws.closed, 4401);
  assert.equal(await socketOutcome(ch.json.token), 'open');

  // Admin reset ends sessions too; the temporary-password login works.
  const reset = await t.api('POST', `/admin/users/${u.user.userId}/reset-password`, null, admin.token);
  assert.equal((await t.api('GET', '/me', null, ch.json.token)).json.code, 'SESSION_INVALID');
  const tmp = await t.api('POST', '/auth/login', { identifier: 'gatepassword@coroute.test', password: reset.json.temporaryPassword });
  assert.equal((await t.api('GET', '/me', null, tmp.json.token)).status, 200);
});

test('an active rider costs at most one users read per TTL', async () => {
  const u = await t.register('Gate Cached', 'gatecached@coroute.test');
  t.gw.gate.invalidate(u.user.userId);
  const before = t.gw.gate.reads;
  await Promise.all([1, 2, 3].map(() => t.api('GET', '/trips', null, u.token)));
  for (let i = 0; i < 5; i++) await t.api('GET', '/trips', null, u.token);
  const ws = await t.connect(u.token);
  await ws.next((m) => m.type === 'HELLO');
  for (let i = 0; i < 5; i++) ws.sendJson({ type: 'PING' });
  for (let i = 0; i < 5; i++) await ws.next((m) => m.type === 'PONG');
  ws.close();
  assert.equal(t.gw.gate.reads - before, 1);
});
