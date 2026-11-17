'use strict';
/**
 * v3.62 phones stay signed in (docs/features_355/communities_chat_v360.md section 14):
 *  - the 6-hourly sweep never removes a live phone session (a phone unused for 30 days was signed out);
 *  - a reply lost on a bad network (previous refresh token sent again hours later) never signs the rider out;
 *    a token two rotations old still counts as theft;
 *  - an expired long token (older builds) naming a live phone session is renewed, not signed out;
 *  - the admin phone sign-in rule applies to NEW phone sign-ins only.
 */
process.env.NODE_ENV = 'test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const config = require('../src/config');
const { boot } = require('./_helpers');
const { validate, clean } = require('../src/session_settings');

let env; let ipSeq = 0;
const ip = () => `10.88.${Math.floor(++ipSeq / 250)}.${ipSeq % 250}`;
const APP2 = { 'X-CoRoute-Session': '2', 'X-CoRoute-Client': 'app' };
before(async () => { env = await boot(); });
after(async () => { await env.gw.shutdown(); });
const call = (method, path, body, token, headers = {}) => env.api(method, path, body, token, { 'X-Forwarded-For': ip(), ...headers });
async function rider(tag) {
  const r = await call('POST', '/auth/register', {
    name: `Stay ${tag}`, email: `stay.${tag}@coroute.test`, password: 'Password#123', phone: '+919876543210',
    vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return { ...r.json, email: `stay.${tag}@coroute.test` };
}
const login = (email, headers = {}) => call('POST', '/auth/login', { identifier: email, password: 'Password#123' }, null, headers);
async function patch(sid, p) {
  const row = await env.gw.soda.findOne('auth_sessions', { sessionId: sid });
  await env.gw.soda.replace('auth_sessions', row.key, { ...row.value, ...p });
  env.gw.sessions.cache.delete(sid);
}

test('sweep: a live phone session unused for 400 days stays; ended records 30+ days old go', async () => {
  const u = await rider('sweep');
  const app = await login(u.email, APP2);
  const web = await login(u.email, { 'X-CoRoute-Client': 'web' });
  const gone = await login(u.email, APP2);
  const long = Date.now() - 400 * 86400000;
  await patch(app.json.sessionId, { lastSeenAt: long });
  await patch(web.json.sessionId, { lastSeenAt: long });
  await patch(gone.json.sessionId, { lastSeenAt: long, revokedAt: long, revokeReason: 'SIGNED_OUT' });
  await env.gw.sessions.sweep();
  assert.ok(await env.gw.soda.findOne('auth_sessions', { sessionId: app.json.sessionId }), 'live phone session kept');
  assert.equal(await env.gw.soda.findOne('auth_sessions', { sessionId: web.json.sessionId }), null, 'idle web session removed');
  assert.equal(await env.gw.soda.findOne('auth_sessions', { sessionId: gone.json.sessionId }), null, 'signed-out session removed');
  assert.equal((await call('GET', '/me', null, app.json.token)).status, 200, 'still signed in');
});

test('lost reply hours later: the previous refresh token still works on a phone; two rotations old is theft', async () => {
  const u = await rider('lost');
  const s = await login(u.email, APP2);
  const r1 = await call('POST', '/auth/refresh', { refreshToken: s.json.refreshToken });
  assert.equal(r1.status, 200);
  // The phone never got (or could not save) r1: it sends the old token 3 hours later.
  await patch(s.json.sessionId, { rotatedAt: Date.now() - 3 * 3600000 });
  const again = await call('POST', '/auth/refresh', { refreshToken: s.json.refreshToken });
  assert.equal(again.status, 200, JSON.stringify(again.json));
  assert.equal((await call('GET', '/me', null, again.json.token)).status, 200);
  const r3 = await call('POST', '/auth/refresh', { refreshToken: again.json.refreshToken });
  const r4 = await call('POST', '/auth/refresh', { refreshToken: r3.json.refreshToken });
  assert.equal(r4.status, 200);
  const theft = await call('POST', '/auth/refresh', { refreshToken: again.json.refreshToken });
  assert.equal(theft.status, 401, 'two rotations old');
  assert.equal(theft.json.code, 'SESSION_INVALID');
});

test('web sessions keep the 60 s grace', async () => {
  const s = env.gw.sessions;
  assert.equal(s._withinGrace({ kind: 'web', rotatedAt: Date.now() - 120000 }, Date.now()), false);
  assert.equal(s._withinGrace({ kind: 'app', rotatedAt: Date.now() - 30 * 86400000 }, Date.now()), true);
});

test('older builds: an expired long token of a live phone session is renewed; a signed-out one is not', async () => {
  const u = await rider('longexp');
  const s = await login(u.email);
  const c = jwt.decode(s.json.token);
  // Same claims, but already past its date (as a phone left unused longer than JWT_TTL_DAYS).
  const expired = jwt.sign({ ...c, exp: c.iat + 1 }, config.jwtSecret);
  await new Promise((r) => setTimeout(r, 2100));
  const r = await call('GET', '/me', null, expired);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  const fresh = r.headers.get('x-coroute-token');
  assert.ok(fresh, 'new token in X-CoRoute-Token');
  assert.ok(jwt.decode(fresh).exp > Date.now() / 1000);
  await env.gw.sessions.revoke(c.sid, 'SIGNED_OUT');
  const after2 = await call('GET', '/me', null, expired);
  assert.equal(after2.status, 401);
  assert.equal(after2.json.code, 'SESSION_INVALID');
});

test('admin phone sign-in rule: only new phone sign-ins get it; riders already signed in never do', async () => {
  const u = await rider('policy');
  const before1 = await login(u.email, APP2);
  const settings = env.gw.sessions.settings;
  assert.ok(settings, 'settings attached');
  await settings.save({ appIdleDays: 30, appAbsoluteDays: 0 }, 'test');
  try {
    const after1 = await login(u.email, APP2);
    const row = await env.gw.soda.findOne('auth_sessions', { sessionId: after1.json.sessionId });
    assert.deepEqual({ i: row.value.appPol.idleDays, a: row.value.appPol.absDays }, { i: 30, a: 0 });
    const old = await env.gw.soda.findOne('auth_sessions', { sessionId: before1.json.sessionId });
    assert.equal(old.value.appPol, undefined, 'existing session untouched');
    await patch(before1.json.sessionId, { lastSeenAt: Date.now() - 400 * 86400000 });
    await patch(after1.json.sessionId, { lastSeenAt: Date.now() - 31 * 86400000 });
    assert.equal((await call('GET', '/me', null, before1.json.token)).status, 200, 'signed in before the rule: no limit');
    const cut = await call('GET', '/me', null, after1.json.token);
    assert.equal(cut.status, 401, 'signed in after the rule: 30 days idle');
  } finally {
    await settings.save({ appIdleDays: 0, appAbsoluteDays: 0 }, 'test');
  }
  const none = await login(u.email, APP2);
  const row = await env.gw.soda.findOne('auth_sessions', { sessionId: none.json.sessionId });
  assert.equal(row.value.appPol, undefined, '0 / 0: no limit stored');
});

test('admin rule: validation and access', async () => {
  assert.throws(() => validate({ appIdleDays: -1, appAbsoluteDays: 0 }));
  assert.throws(() => validate({ appIdleDays: 1.5, appAbsoluteDays: 0 }));
  assert.throws(() => validate({ appIdleDays: 0, appAbsoluteDays: 4000 }));
  assert.deepEqual(validate({ appIdleDays: 0, appAbsoluteDays: 0 }), { appIdleDays: 0, appAbsoluteDays: 0 });
  assert.equal(clean(null).saved, false);
  const u = await rider('notadmin');
  const s = await login(u.email, APP2);
  assert.equal((await call('GET', '/admin/session-settings', null, s.json.token)).status, 403);
  assert.equal((await call('PUT', '/admin/session-settings', { appIdleDays: 1, appAbsoluteDays: 0 }, s.json.token)).status, 403);
});
