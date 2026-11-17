'use strict';
/**
 * v3.62 security hardening (pen test round):
 *  1. query strings never carry objects (`?q[$ne]=x` is a literal key), JSON bodies and socket messages lose "$"
 *     operator keys and prototype keys (database filter operator injection, prototype pollution);
 *  2. two racing 2-step checks with the same recovery code / TOTP step: only one passes;
 *  3. a phone's late previous refresh token (lost reply) rotates a few times only, then counts as theft.
 */
process.env.NODE_ENV = 'test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { sanitize } = require('../src/input_guard');
const totp = require('../src/totp');
const { PREV_LATE_MAX } = require('../src/sessions');

let env; let ipSeq = 0;
const ip = () => `10.99.${Math.floor(++ipSeq / 250)}.${ipSeq % 250}`;
const APP2 = { 'X-CoRoute-Session': '2', 'X-CoRoute-Client': 'app' };
before(async () => { env = await boot(); });
after(async () => { await env.gw.shutdown(); });
const call = (m, p, b, t, h = {}) => env.api(m, p, b, t, { 'X-Forwarded-For': ip(), ...h });
async function rider(tag) {
  const r = await call('POST', '/auth/register', { name: `Sec ${tag}`, email: `sec362.${tag}@coroute.test`, password: 'Password#123', phone: '+919876543210',
    vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return { ...r.json, email: `sec362.${tag}@coroute.test` };
}

test('sanitize drops operator and prototype keys at every depth, keeps the rest', () => {
  const o = JSON.parse('{"a":1,"$ne":2,"b":{"$gt":0,"c":"x","__proto__":{"polluted":true}},"constructor":{"prototype":{"p":1}},"arr":[{"$in":[1]},{"ok":true}]}');
  sanitize(o);
  assert.deepEqual(o, { a: 1, b: { c: 'x' }, arr: [{}, { ok: true }] });
  assert.equal({}.polluted, undefined);
});

test('HTTP: query values are strings only; bodies lose "$" keys', async () => {
  assert.equal(env.gw.app.get('query parser'), 'simple');
  const u = await rider('qs');
  const s = await call('POST', '/auth/login', { identifier: u.email, password: 'Password#123' }, null, APP2);
  const r = await call('GET', '/communities/discover?q[$ne]=zzz', null, s.json.token);
  assert.equal(r.status, 200);
  // A login with an operator object instead of a string never matches an account.
  const inj = await call('POST', '/auth/login', { identifier: { $ne: '' }, password: 'Password#123' });
  assert.ok(inj.status >= 400 && inj.status < 500, String(inj.status));
  const dm = await call('POST', '/chats/dm', { username: { $ne: '' } }, s.json.token);
  assert.notEqual(dm.status, 200);
});

test('2-step: the same recovery code sent twice at once works only once; the same TOTP step only once', async () => {
  const u = await rider('mfa');
  const doc = await env.gw.repo.findUserById(u.user.userId);
  const secret = totp.newSecret();
  const rc = totp.newRecoveryCodes(3);
  await env.gw.repo.updateUser(doc.key, { mfaEnabled: true, mfaSecret: secret, mfaRecovery: rc.hashes });
  env.gw.gate.invalidate(u.user.userId);
  const auth = env.gw.auth;
  const both = await Promise.allSettled([1, 2].map(() => auth.mfaCheck({ userId: u.user.userId }, { recoveryCode: rc.codes[0] })));
  assert.deepEqual(both.map((x) => x.status).sort(), ['fulfilled', 'rejected']);
  const code = totp.totp(secret);
  const two = await Promise.allSettled([1, 2].map(() => auth.mfaCheck({ userId: u.user.userId }, { code })));
  assert.deepEqual(two.map((x) => x.status).sort(), ['fulfilled', 'rejected'], 'TOTP step replay refused');
});

test(`phone: a late previous refresh token rotates at most ${PREV_LATE_MAX} times, then the session ends (stolen token)`, async () => {
  const u = await rider('late');
  const s = await call('POST', '/auth/login', { identifier: u.email, password: 'Password#123' }, null, APP2);
  const r1 = await call('POST', '/auth/refresh', { refreshToken: s.json.refreshToken });
  assert.equal(r1.status, 200);
  const old = s.json.refreshToken;
  for (let i = 0; i < PREV_LATE_MAX; i++) {
    const row = await env.gw.soda.findOne('auth_sessions', { sessionId: s.json.sessionId });
    await env.gw.soda.replace('auth_sessions', row.key, { ...row.value, rotatedAt: Date.now() - 2 * 3600000 });
    env.gw.sessions.cache.delete(s.json.sessionId);
    const again = await call('POST', '/auth/refresh', { refreshToken: old });
    assert.equal(again.status, 200, `late use ${i + 1}`);
  }
  const row = await env.gw.soda.findOne('auth_sessions', { sessionId: s.json.sessionId });
  await env.gw.soda.replace('auth_sessions', row.key, { ...row.value, rotatedAt: Date.now() - 2 * 3600000 });
  env.gw.sessions.cache.delete(s.json.sessionId);
  const theft = await call('POST', '/auth/refresh', { refreshToken: old });
  assert.equal(theft.status, 401);
  assert.equal(theft.json.code, 'SESSION_INVALID');
});

test('closed-app SOS pushes: at most 6 per rider per 10 min (raise/close loop cannot flood phones); every SOS still raised', async () => {
  const a = await rider('loopa'); const b = await rider('loopb');
  const c = (await call('POST', '/convoys', { name: 'Loop ride' }, a.token)).json;
  assert.equal((await call('POST', '/convoys/join', { code: c.joinCode }, b.token)).status, 200);
  const calls = [];
  const real = env.gw.convoys.push;
  env.gw.convoys.push = { notifyUsers: async (ids, opts) => { calls.push(opts.type); return { sent: 1 }; } };
  try {
    for (let i = 0; i < 9; i++) {
      const r = await call('POST', `/convoys/${c.groupId}/sos`, { clientId: `loop-${i}`, lat: 17.4, lng: 78.4 }, a.token);
      assert.equal(r.status, 201, `SOS ${i + 1} raised`);
      await env.gw.convoys.resolveSos(c.groupId, a.user, r.json.alertId);
    }
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(calls.filter((x) => x === 'GROUP_SOS').length, 6);
    assert.equal(calls.filter((x) => x === 'GROUP_SOS_RESOLVED').length, 6, 'a close is pushed only for a pushed SOS');
  } finally { env.gw.convoys.push = real; }
});

test('admin page polling: the live phone session count is cached (no 5000-row scan every 15 s)', async () => {
  const s = env.gw.sessions;
  s._liveAppCount = null;
  const real = s.soda.query.bind(s.soda);
  let scans = 0;
  s.soda.query = async (coll, filter, opts) => { if (coll === 'auth_sessions' && filter && filter.revokedAt === 0) scans++; return real(coll, filter, opts); };
  try {
    await s.countLiveApp(); await s.countLiveApp(); await s.countLiveApp();
    assert.equal(scans, 1);
  } finally { s.soda.query = real; }
});
