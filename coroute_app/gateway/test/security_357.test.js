'use strict';
/**
 * 3.57 sessions & security (docs/features_355/sessions_and_security.md, docs/security/SECURITY_AUDIT_v3.55.md):
 * session rotation + reuse detection, logout everywhere (HTTP + sockets), idle / absolute expiry (never mid-ride
 * for the app), revoke on password change / reset, lockout, no enumeration, reset links, CSRF, headers, cookies,
 * field encryption + lazy migration + blind index, log redaction, 2-step verification for admins, old tokens.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'sec.admin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
// Field encryption on for this whole file (every route below runs with encrypted phones / medical fields).
process.env.DATA_ENC_KEY = Buffer.alloc(32, 7).toString('base64');
process.env.DATA_ENC_KEY_ID = 'k2';
process.env.DATA_ENC_KEYS_PREVIOUS = `k1:${Buffer.alloc(32, 3).toString('base64')}`;
process.env.BLIND_INDEX_KEY = Buffer.alloc(32, 9).toString('base64');

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const WebSocket = require('ws');
const config = require('../src/config');
const { boot, sleep } = require('./_helpers');
const { FieldCrypto } = require('../src/field_crypto');
const { redact, redactString, redactingLogger } = require('../src/redact');
const totp = require('../src/totp');
const { passwordProblem } = require('../src/password_policy');
const { uaSummary } = require('../src/sessions');

let env; let ipSeq = 0;
const mails = [];
const mailTransport = { sendMail: async (m) => { mails.push(m); return { messageId: `m${mails.length}` }; } };
const ip = () => `10.77.${Math.floor(++ipSeq / 250)}.${ipSeq % 250}`;
const APP2 = { 'X-CoRoute-Session': '2', 'X-CoRoute-Client': 'app' };

before(async () => { env = await boot({ mailTransport }); });
after(async () => { await env.gw.shutdown(); });

/** api() with a fresh client IP per call (the per-IP sign-in limiter is not what these tests are about). */
const call = (method, path, body, token, headers = {}) => env.api(method, path, body, token, { 'X-Forwarded-For': ip(), ...headers });
async function rider(tag, extra = {}) {
  const r = await call('POST', '/auth/register', {
    name: `Sec ${tag}`, email: `sec.${tag}@coroute.test`, password: 'Password#123', phone: '+919876543210',
    vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact', ...extra,
  });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return { ...r.json, email: `sec.${tag}@coroute.test` };
}
const login = (identifier, password = 'Password#123', headers = {}, body = {}) => call('POST', '/auth/login', { identifier, password, ...body }, null, headers);
const cookieOf = (res, name) => {
  const all = typeof res.headers.getSetCookie === 'function' ? res.headers.getSetCookie() : [res.headers.get('set-cookie') || ''];
  return all.find((c) => c.startsWith(`${name}=`)) || '';
};
function socket(token, headers = {}) {
  return new Promise((resolve0) => {
    let t = null;
    const resolve = (v) => { clearInterval(t); resolve0(v); };
    const ws = new WebSocket(`${env.wsBase}?token=${token}`, { headers });
    ws.inbox = [];
    ws.closed = new Promise((res) => ws.on('close', (code, reason) => res({ code, reason: String(reason) })));
    ws.on('message', (d) => ws.inbox.push(JSON.parse(d.toString())));
    ws.on('error', () => {});
    ws.on('unexpected-response', (req, res) => { req.destroy(); res.destroy(); resolve({ refused: res.statusCode }); });
    t = setInterval(() => { if (ws.inbox.some((m) => m.type === 'HELLO')) resolve(ws); }, 10);
    ws.closed.then((c) => resolve({ closedEarly: c }));
  });
}

// ------------------------------------------------------------------ sessions & rotation
test('app >= 10025: short access token + rotating refresh token; reuse of an old refresh token revokes the session', async () => {
  const u = await rider('rot');
  const s = await login(u.email, 'Password#123', APP2);
  assert.equal(s.status, 200);
  assert.ok(s.json.refreshToken && s.json.sessionId);
  const claims = jwt.decode(s.json.token);
  assert.equal(claims.typ, 'at');
  assert.equal(claims.sid, s.json.sessionId);
  assert.ok(claims.exp - claims.iat <= config.accessTokenTtlMin * 60);
  assert.equal(s.headers.get('set-cookie'), null, 'the app gets no cookie');

  const r1 = await call('POST', '/auth/refresh', { refreshToken: s.json.refreshToken });
  assert.equal(r1.status, 200, JSON.stringify(r1.json));
  assert.notEqual(r1.json.refreshToken, s.json.refreshToken);
  assert.equal((await call('GET', '/me', null, r1.json.token)).status, 200);
  const r2 = await call('POST', '/auth/refresh', { refreshToken: r1.json.refreshToken });
  assert.equal(r2.status, 200);

  // The first token is two rotations old: reuse = theft. The whole session ends, every token of it too.
  const reuse = await call('POST', '/auth/refresh', { refreshToken: s.json.refreshToken });
  assert.equal(reuse.status, 401);
  assert.equal(reuse.json.code, 'SESSION_INVALID');
  assert.equal((await call('POST', '/auth/refresh', { refreshToken: r2.json.refreshToken })).status, 401, 'the newest token dies with the family');
  const me = await call('GET', '/me', null, r2.json.token);
  assert.equal(me.status, 401);
  assert.equal(me.json.code, 'SESSION_INVALID');
  await env.gw.audit.flush();
  const rows = (await env.gw.soda.query('safety_audit', { kind: 'AUTH' }, { limit: 50 })).map((r) => r.value);
  assert.ok(rows.some((r) => r.detail === 'REFRESH_REUSE' && r.subjectId === u.user.userId), 'audited');
});

test('a refresh token used again within the grace window (lost reply, second tab) never signs the rider out', async () => {
  const u = await rider('grace');
  const s = await login(u.email, 'Password#123', APP2);
  const r1 = await call('POST', '/auth/refresh', { refreshToken: s.json.refreshToken });
  assert.equal(r1.status, 200);
  // The reply to r1 was "lost": the phone sends the previous token again.
  const again = await call('POST', '/auth/refresh', { refreshToken: s.json.refreshToken });
  assert.equal(again.status, 200, JSON.stringify(again.json));
  assert.equal((await call('GET', '/me', null, again.json.token)).status, 200);
  assert.equal((await call('POST', '/auth/refresh', { refreshToken: again.json.refreshToken })).status, 200);
  // Two refreshes at the same moment both succeed (compare-and-replace, then the grace rule).
  const cur = (await call('POST', '/auth/refresh', { refreshToken: (await call('POST', '/auth/refresh', { refreshToken: again.json.refreshToken })).json.refreshToken }));
  const [a, b] = await Promise.all([1, 2].map(() => call('POST', '/auth/refresh', { refreshToken: cur.json.refreshToken })));
  assert.deepEqual([a.status, b.status], [200, 200]);
});

test('an expired short access token answers TOKEN_EXPIRED (refresh, not sign-out); an expired long token is a session that ended', async () => {
  const u = await rider('exp');
  const s = await login(u.email, 'Password#123', APP2);
  const past = Math.floor(Date.now() / 1000) - 3600;
  const expired = jwt.sign({ sub: u.user.userId, sid: s.json.sessionId, typ: 'at', pv: 0, iat: past, exp: past + 900 }, config.jwtSecret, { issuer: 'coroute-gateway' });
  const r = await call('GET', '/me', null, expired);
  assert.equal(r.status, 401);
  assert.equal(r.json.code, 'TOKEN_EXPIRED');
  const ws = await socket(expired);
  assert.equal(ws.closedEarly.code, 4401);
  assert.equal(ws.closedEarly.reason, 'TOKEN_EXPIRED');
  const longExpired = jwt.sign({ sub: u.user.userId, pv: 0, iat: past - 86400 * 40, exp: past }, config.jwtSecret, { issuer: 'coroute-gateway' });
  assert.equal((await call('GET', '/me', null, longExpired)).json.code, 'SESSION_INVALID');
  // A 2-step token is never a session.
  const mfa = jwt.sign({ sub: u.user.userId, typ: 'mfa' }, config.jwtSecret, { issuer: 'coroute-gateway', expiresIn: '5m' });
  assert.equal((await call('GET', '/me', null, mfa)).status, 401);
});

test('logout ends the session at once: REST 401 and the open socket closes 4401 SIGNED_OUT; other devices stay signed in', async () => {
  const u = await rider('out');
  const phone = await login(u.email, 'Password#123', APP2);
  const tablet = await login(u.email);
  const ws = await socket(phone.json.token);
  assert.ok(ws.inbox, 'socket open');
  const out = await call('POST', '/auth/logout', { refreshToken: phone.json.refreshToken }, phone.json.token);
  assert.equal(out.status, 200);
  assert.equal(out.json.revoked, 1);
  const closed = await ws.closed;
  assert.equal(closed.code, 4401);
  assert.equal(closed.reason, 'SIGNED_OUT');
  assert.equal((await call('GET', '/me', null, phone.json.token)).json.code, 'SESSION_INVALID');
  assert.equal((await call('POST', '/auth/refresh', { refreshToken: phone.json.refreshToken })).status, 401);
  assert.equal((await call('GET', '/me', null, tablet.json.token)).status, 200, 'the other device is untouched');
  // Logging out twice, or with nothing, is harmless.
  assert.equal((await call('POST', '/auth/logout', {}, phone.json.token)).status, 200);
  assert.equal((await call('POST', '/auth/logout', {})).status, 200);
});

test('sign out of all devices ends every session and every pre-3.57 token; sockets close', async () => {
  const u = await rider('all');
  const a = await login(u.email, 'Password#123', APP2);
  const b = await login(u.email);
  const legacy = jwt.sign({ sub: u.user.userId, name: 'x', role: 'RIDER', email: u.email, pv: 0, iat: Math.floor(Date.now() / 1000) - 5 }, config.jwtSecret, { issuer: 'coroute-gateway', expiresIn: '30d' });
  const ws = await socket(b.json.token);
  const all = await call('POST', '/auth/logout-all', {}, a.json.token);
  assert.equal(all.status, 200);
  assert.ok(all.json.revoked >= 2);
  assert.equal((await ws.closed).code, 4401);
  for (const t of [a.json.token, b.json.token, legacy]) assert.equal((await call('GET', '/me', null, t)).status, 401);
  assert.equal((await login(u.email)).status, 200, 'signing in again works');
});

test('sessions list ("Where you are signed in") and signing out one; another rider\'s session reads as not found', async () => {
  const u = await rider('list');
  const v = await rider('listother');
  const a = await login(u.email, 'Password#123', { ...APP2, 'User-Agent': 'Dart/3.7 (dart:io)' }, { device: { label: 'Pixel 8', platform: 'android' } });
  const web = await login(u.email, 'Password#123', { 'X-CoRoute-Client': 'web', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0) Chrome/130.0 Safari/537.36' });
  const list = await call('GET', '/me/sessions', null, a.json.token);
  assert.equal(list.status, 200);
  const mine = list.json.sessions;
  assert.ok(mine.find((s) => s.current && s.deviceLabel === 'Pixel 8'));
  assert.ok(mine.find((s) => s.kind === 'web' && s.deviceLabel === 'Chrome on Windows'));
  assert.ok(!JSON.stringify(list.json).includes('refreshHash') && !JSON.stringify(list.json).includes('ipHash'));
  const other = await login(v.email);
  assert.equal((await call('DELETE', `/me/sessions/${other.json.sessionId}`, null, a.json.token)).status, 404, 'IDOR: not my session');
  assert.equal((await call('GET', '/me', null, other.json.token)).status, 200);
  assert.equal((await call('DELETE', `/me/sessions/${web.json.sessionId}`, null, a.json.token)).status, 200);
  assert.equal((await call('GET', '/me', null, web.json.token)).status, 401);
  assert.equal(uaSummary('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Version/17.0 Mobile Safari/604.1'), 'Safari on iPhone');
});

test('idle and absolute expiry: web 60 min idle / 7 days, admin 30 min; the app is extended past its limit while riding', async () => {
  const u = await rider('idle');
  const web = await login(u.email, 'Password#123', { 'X-CoRoute-Client': 'web' });
  const sid = web.json.sessionId;
  const row = await env.gw.soda.findOne('auth_sessions', { sessionId: sid });
  await env.gw.soda.replace('auth_sessions', row.key, { ...row.value, lastSeenAt: Date.now() - 61 * 60000 });
  env.gw.sessions.cache.delete(sid);
  const idle = await call('GET', '/me', null, web.json.token);
  assert.equal(idle.status, 401);
  assert.match(idle.json.error, /expired/i);

  const web2 = await login(u.email, 'Password#123', { 'X-CoRoute-Client': 'web' });
  const row2 = await env.gw.soda.findOne('auth_sessions', { sessionId: web2.json.sessionId });
  await env.gw.soda.replace('auth_sessions', row2.key, { ...row2.value, absoluteExpiresAt: Date.now() - 1 });
  env.gw.sessions.cache.delete(web2.json.sessionId);
  assert.equal((await call('GET', '/me', null, web2.json.token)).status, 401, 'absolute limit (web) is hard');

  // App: past its absolute lifetime, a refresh while riding extends it (audited); not riding ends it.
  const app = await login(u.email, 'Password#123', APP2);
  const row3 = await env.gw.soda.findOne('auth_sessions', { sessionId: app.json.sessionId });
  await env.gw.soda.replace('auth_sessions', row3.key, { ...row3.value, absoluteExpiresAt: Date.now() - 1 });
  env.gw.sessions.cache.delete(app.json.sessionId);
  assert.equal((await call('GET', '/me', null, app.json.token)).status, 200, 'an app session is never cut by the absolute limit between refreshes');
  await env.gw.repo.setActiveTrip(u.user.userId, { groupId: 'GRP-RIDING' });
  const ext = await call('POST', '/auth/refresh', { refreshToken: app.json.refreshToken });
  assert.equal(ext.status, 200, 'riding: extended');
  const s3 = await env.gw.sessions.get(app.json.sessionId);
  assert.ok(s3.absoluteExpiresAt > Date.now() + 23 * 3600000);
  await env.gw.repo.releaseActiveTrip(u.user.userId);
  await env.gw.soda.replace('auth_sessions', s3.key, { ...s3, key: undefined, absoluteExpiresAt: Date.now() - 1 });
  env.gw.sessions.cache.delete(app.json.sessionId);
  assert.equal((await call('POST', '/auth/refresh', { refreshToken: ext.json.refreshToken })).status, 401, 'not riding: ended');
});

test('password change: every other session ends (socket too), this device continues; reset by e-mail is single use', async () => {
  const u = await rider('pw');
  const other = await login(u.email);
  const ws = await socket(other.json.token);
  const me = await login(u.email, 'Password#123', APP2);
  const weak = await call('POST', '/me/password', { currentPassword: 'Password#123', newPassword: 'password123' }, me.json.token);
  assert.equal(weak.status, 422);
  const ch = await call('POST', '/me/password', { currentPassword: 'Password#123', newPassword: 'Changed#Pass57' }, me.json.token);
  assert.equal(ch.status, 200);
  assert.equal((await ws.closed).code, 4401);
  assert.equal((await call('GET', '/me', null, other.json.token)).status, 401);
  assert.equal((await call('GET', '/me', null, ch.json.token)).status, 200);
  assert.equal((await call('POST', '/auth/refresh', { refreshToken: me.json.refreshToken })).status, 200, 'this session continues');
  assert.ok(mails.some((m) => m.to === u.email && /password was changed/i.test(m.subject)));

  // Reset by e-mail.
  mails.length = 0;
  const unknown = await call('POST', '/auth/password/forgot', { email: 'nobody.at.all@coroute.test' });
  const known = await call('POST', '/auth/password/forgot', { email: u.email });
  assert.deepEqual([unknown.status, unknown.json], [known.status, known.json], 'no enumeration');
  assert.equal(mails.length, 1);
  assert.ok(!/reset=/.test(mails[0].subject));
  const token = /#reset=([A-Za-z0-9_-]+)/.exec(mails[0].text)[1];
  const stored = await env.gw.repo.findUserByEmail(u.email);
  assert.notEqual(stored.pwResetHash, token, 'only a hash is stored');
  const done = await call('POST', '/auth/password/reset', { token, newPassword: 'Reset#Pass2026' });
  assert.equal(done.status, 200, JSON.stringify(done.json));
  assert.equal((await call('GET', '/me', null, ch.json.token)).status, 401, 'reset ends every session');
  const twice = await call('POST', '/auth/password/reset', { token, newPassword: 'Another#Pass2026' });
  assert.equal(twice.status, 400);
  assert.equal(twice.json.code, 'RESET_INVALID');
  assert.equal((await login(u.email, 'Reset#Pass2026')).status, 200);
  // Expired link.
  await call('POST', '/auth/password/forgot', { email: u.email });
  const t2 = /#reset=([A-Za-z0-9_-]+)/.exec(mails[mails.length - 1].text)[1];
  const doc = await env.gw.repo.findUserByEmail(u.email);
  await env.gw.repo.updateUser(doc.key, { pwResetExp: Date.now() - 1 });
  assert.equal((await call('POST', '/auth/password/reset', { token: t2, newPassword: 'Later#Pass2026' })).status, 400);
});

test('lockout: 10 wrong passwords lock the account (429 even with the right one), one e-mail; errors never reveal accounts', async () => {
  const u = await rider('lock');
  mails.length = 0;
  const wrong = await login(u.email, 'Wrong#12345');
  const none = await login('nobody.lock@coroute.test', 'Wrong#12345');
  assert.deepEqual([wrong.status, wrong.json.error], [none.status, none.json.error]);
  for (let i = 0; i < 9; i++) await login(u.email, 'Wrong#12345');
  const locked = await login(u.email, 'Password#123');
  assert.equal(locked.status, 429);
  assert.equal(locked.json.code, 'RATE_LIMITED');
  assert.equal(mails.filter((m) => m.to === u.email && /paused/i.test(m.subject)).length, 1);
  const doc = await env.gw.repo.findUserByEmail(u.email);
  assert.ok(doc.lockUntil > Date.now() + 14 * 60000);
  await env.gw.repo.updateUser(doc.key, { lockUntil: Date.now() - 1 });
  // (The per-account request limiter of this node still answers 429 for its window; the account lock itself is over.)
  assert.ok((await env.gw.auth.login({ identifier: u.email, password: 'Password#123' })).token, 'unlocks after the lock time');
  // Register: same answer shape for a taken address (409 so the app can offer "Sign in"), no detail.
  const dup = await call('POST', '/auth/register', { name: 'Sec Dup', email: u.email, password: 'Password#123', phone: '+919876543211', vehicleNo: 'TS09AB9999' });
  assert.equal(dup.status, 409);
  assert.doesNotMatch(dup.json.error, /already registered/i);
});

test('password rules: common, too short, e-mail / callsign refused; long passphrases accepted', () => {
  assert.ok(passwordProblem('password1'));
  assert.ok(passwordProblem('Sunshine!'));
  assert.ok(passwordProblem('12345678'));
  assert.ok(passwordProblem('short'));
  assert.ok(passwordProblem('ravi.kumar', { email: 'ravi.kumar@x.in' }));
  assert.ok(passwordProblem('RoadKing99', { name: 'Road King' }));
  assert.equal(passwordProblem('correct horse battery staple ride'), null);
  assert.equal(passwordProblem('x'.repeat(150) + 'Q1!'), null, 'no maximum below 64');
  assert.equal(passwordProblem('Password#123'), null);
});

// ------------------------------------------------------------------ website cookies, CSRF, headers
test('website sign-in: refresh token only in an httpOnly __Host- cookie (Lax for the site, Strict for consoles); CSRF guard', async () => {
  const u = await rider('cookie');
  const web = await login(u.email, 'Password#123', { 'X-CoRoute-Client': 'web' });
  assert.equal(web.status, 200);
  assert.equal(web.json.refreshToken, undefined, 'never in the body');
  const c = cookieOf(web, '__Host-cr_rt');
  assert.match(c, /HttpOnly/i); assert.match(c, /Secure/i); assert.match(c, /SameSite=Lax/i); assert.match(c, /Path=\//);
  assert.doesNotMatch(c, /Domain=/i);
  const value = c.split(';')[0];

  const noHeader = await call('POST', '/auth/refresh', {}, null, { Cookie: value, 'X-CoRoute-Client': 'web' });
  assert.equal(noHeader.status, 403);
  assert.equal(noHeader.json.code, 'CSRF');
  const foreign = await call('POST', '/auth/refresh', {}, null, { Cookie: value, 'X-CoRoute-Client': 'web', 'X-CoRoute-CSRF': '1', Origin: 'https://evil.example' });
  assert.equal(foreign.status, 403);
  const ok = await call('POST', '/auth/refresh', {}, null, { Cookie: value, 'X-CoRoute-Client': 'web', 'X-CoRoute-CSRF': '1', Origin: 'https://coroute.example' });
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.equal(ok.json.refreshToken, undefined);
  const rotated = cookieOf(ok, '__Host-cr_rt').split(';')[0];
  assert.ok(rotated && rotated !== value);
  assert.equal(ok.json.user.userId, u.user.userId);

  // A web cookie is never accepted as a console cookie (and the reverse).
  const asAdmin = await call('POST', '/auth/refresh', {}, null, { Cookie: value.replace('__Host-cr_rt', '__Host-cr_adm'), 'X-CoRoute-Client': 'admin', 'X-CoRoute-CSRF': '1' });
  assert.equal(asAdmin.status, 401);

  // Logout clears the cookie server-side and asks the browser to drop cached pages.
  const out = await call('POST', '/auth/logout', {}, ok.json.token, { Cookie: rotated, 'X-CoRoute-Client': 'web', 'X-CoRoute-CSRF': '1' });
  assert.equal(out.status, 200);
  assert.match(cookieOf(out, '__Host-cr_rt'), /Expires=Thu, 01 Jan 1970/);
  assert.equal(out.headers.get('clear-site-data'), '"cache"');
  assert.equal((await call('POST', '/auth/refresh', {}, null, { Cookie: rotated, 'X-CoRoute-Client': 'web', 'X-CoRoute-CSRF': '1' })).status, 401);

  const op = await login(u.email, 'Password#123', { 'X-CoRoute-Client': 'operator' });
  assert.match(cookieOf(op, '__Host-cr_op'), /SameSite=Strict/i);
});

test('headers: HSTS with includeSubDomains, strict default CSP, frame / referrer / permissions policies, no-store on APIs and private pages', async () => {
  const u = await rider('hdr');
  const me = await call('GET', '/me', null, u.token);
  assert.match(me.headers.get('cache-control'), /no-store/);
  assert.match(me.headers.get('strict-transport-security'), /max-age=\d+; includeSubDomains/);
  const csp = me.headers.get('content-security-policy');
  assert.doesNotMatch(csp, /script-src[^;]*unsafe-inline/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.equal(me.headers.get('x-frame-options'), 'DENY');
  assert.ok(me.headers.get('referrer-policy'));
  assert.match(me.headers.get('permissions-policy'), /camera=\(\)/);
  assert.equal(me.headers.get('x-content-type-options'), 'nosniff');
  for (const p of ['/account', '/signin', '/receipt', '/admin', '/operator']) {
    const res = await fetch(env.origin + p);
    await res.arrayBuffer();
    assert.match(res.headers.get('cache-control') || '', /no-store/, `${p}: no-store`);
    assert.doesNotMatch(res.headers.get('content-security-policy') || '', /script-src[^;]*unsafe-inline/, `${p}: no inline script`);
  }
  const live = await fetch(`${env.origin}/join/ABCD12`);
  await live.arrayBuffer();
  assert.doesNotMatch(live.headers.get('content-security-policy'), /unsafe-inline'[^;]*;?\s*$|script-src[^;]*unsafe-inline/);
  // Public statistics keep their own caching.
  const stats = await fetch(`${env.base}/public/usage-stats`);
  await stats.arrayBuffer();
  assert.match(stats.headers.get('cache-control'), /max-age|public/);
});

test('sockets: a browser from another site is refused at the upgrade; same site and the app (no Origin) connect', async () => {
  const u = await rider('origin');
  const evil = await socket(u.token, { Origin: 'https://evil.example' });
  assert.equal(evil.refused, 401);
  const same = await socket(u.token, { Origin: env.origin });
  assert.ok(same.inbox); same.close();
  const site = await socket(u.token, { Origin: 'https://coroute.example' });
  assert.ok(site.inbox); site.close();
  const app = await socket(u.token);
  assert.ok(app.inbox); app.close();
});

// ------------------------------------------------------------------ compatibility with older app builds
test('older app builds: no new headers -> a long sliding token bound to a session; a pre-3.57 token keeps working and is migrated silently', async () => {
  const u = await rider('legacy');
  const s = await login(u.email);
  assert.equal(s.json.refreshToken, undefined);
  const c = jwt.decode(s.json.token);
  assert.equal(c.typ, undefined);
  assert.ok(c.sid);
  assert.ok(c.exp - c.iat >= 29 * 86400, 'long token as before');
  // A token from before 3.57 (no sid): accepted, and the reply carries a session-bound replacement.
  const doc = await env.gw.repo.findUserById(u.user.userId);
  await env.gw.repo.updateUser(doc.key, { createdAt: Date.now() - 86400000 });
  env.gw.gate.invalidate(u.user.userId);
  const old = jwt.sign({ sub: u.user.userId, name: 'Sec legacy', role: 'RIDER', email: u.email, pv: 0, iat: Math.floor(Date.now() / 1000) - 3600 }, config.jwtSecret, { issuer: 'coroute-gateway', expiresIn: '20d' });
  const r = await call('GET', '/me', null, old);
  assert.equal(r.status, 200);
  const next = r.headers.get('x-coroute-token');
  assert.ok(next);
  assert.ok(jwt.decode(next).sid);
  // Parallel calls with the same old token share one migrated session.
  const many = await Promise.all([1, 2, 3].map(() => call('GET', '/trips', null, old)));
  assert.equal(new Set(many.map((x) => jwt.decode(x.headers.get('x-coroute-token')).sid)).size, 1);
  const ws = await socket(old);
  assert.ok(ws.inbox, 'old token opens the socket'); ws.close();
  // Round 4: old builds without a password get an e-mailed confirmation link (202 + readable message), never an
  // immediate delete; the link deletes the account once (see 'legacy delete confirmation' below).
  const gone = await rider('legacydel');
  const legacyLogin = await login(gone.email);
  const del = await call('DELETE', '/me', null, legacyLogin.json.token);
  assert.equal(del.status, 202, JSON.stringify(del.json));
  assert.match(del.json.message, /confirm deleting your account/i);
  assert.ok(await env.gw.repo.findUserById(gone.user.userId), 'not deleted yet');
  // With the password in the body an old build still deletes at once.
  assert.equal((await call('DELETE', '/me', { currentPassword: 'Password#123' }, legacyLogin.json.token)).status, 200);
  assert.equal((await env.gw.soda.query('auth_sessions', { userId: gone.user.userId })).length, 0, 'session records erased with the account');
});

test('sensitive actions need a recent re-authentication: account deletion (new clients), e-mail change, 2-step changes', async () => {
  const u = await rider('reauth');
  const s = await login(u.email, 'Password#123', APP2);
  // Signing in counts as authenticating for REAUTH_WINDOW_MIN; an older session must confirm again.
  const row = await env.gw.soda.findOne('auth_sessions', { sessionId: s.json.sessionId });
  await env.gw.soda.replace('auth_sessions', row.key, { ...row.value, reauthAt: Date.now() - 11 * 60000 });
  env.gw.sessions.cache.delete(s.json.sessionId);
  const del = await call('DELETE', '/me', null, s.json.token);
  assert.equal(del.status, 403);
  assert.equal(del.json.code, 'REAUTH_REQUIRED');
  assert.equal((await call('POST', '/auth/reauth', { password: 'nope-nope' }, s.json.token)).status, 403, 'a wrong password is not a session end');
  assert.equal((await call('POST', '/auth/reauth', { password: 'Password#123' }, s.json.token)).status, 200);

  // E-mail change: link to the new address, notice to the old one, sessions end when confirmed.
  mails.length = 0;
  const ch = await call('POST', '/me/email', { newEmail: 'sec.reauth.new@coroute.test' }, s.json.token);
  assert.equal(ch.status, 202);
  const toNew = mails.find((m) => m.to === 'sec.reauth.new@coroute.test');
  assert.ok(toNew && mails.find((m) => m.to === u.email), 'both addresses are told');
  const tk = /#confirm-email=([A-Za-z0-9_-]+)/.exec(toNew.text)[1];
  assert.equal((await call('POST', '/auth/email/confirm', { token: tk })).status, 200);
  assert.equal((await call('POST', '/auth/email/confirm', { token: tk })).status, 400, 'single use');
  assert.equal((await call('GET', '/me', null, s.json.token)).status, 401, 'sessions end after an e-mail change');
  assert.equal((await login('sec.reauth.new@coroute.test')).status, 200);
  // A taken address gets the same answer and no mail.
  const v = await rider('reauth2');
  mails.length = 0;
  const taken = await call('POST', '/me/email', { newEmail: 'sec.reauth.new@coroute.test', currentPassword: 'Password#123' }, v.token);
  assert.equal(taken.status, 202);
  assert.equal(mails.length, 0);

  const s2 = await login('sec.reauth.new@coroute.test', 'Password#123', APP2);
  assert.equal((await call('DELETE', '/me', null, s2.json.token)).status, 200);
});

// ------------------------------------------------------------------ 2-step verification
test('admin 2-step: enrolment forced at the first web admin sign-in, codes single use, recovery codes once, wrong codes count', async () => {
  const reg = await call('POST', '/auth/register', { name: 'Sec Admin', email: 'sec.admin@coroute.test', password: 'Password#123', phone: '+919876500000', vehicleNo: 'TS09AB0001', emergencyContact: '+919000000002', emergencyContactName: 'Family Contact' });
  assert.equal(reg.status, 201);
  const ADM = { 'X-CoRoute-Client': 'admin' };
  const first = await login('sec.admin@coroute.test', 'Password#123', ADM);
  assert.equal(first.status, 200);
  assert.equal(first.json.mfa, 'enroll');
  assert.equal(first.json.token, undefined, 'no session before the second step');
  assert.equal(cookieOf(first, '__Host-cr_adm'), '');
  const start = await call('POST', '/auth/mfa/enroll/start', { mfaToken: first.json.mfaToken });
  assert.equal(start.status, 200);
  assert.match(start.json.otpauthUrl, /^otpauth:\/\/totp\/CoRoute/);
  const raw = await env.gw.rawSoda.findOne('users', { email: 'sec.admin@coroute.test' });
  assert.ok(String(raw.value.mfaPendingSecret).startsWith('enc:v1:k2:'), 'the secret is encrypted at rest');
  assert.equal((await call('POST', '/auth/mfa/enroll/confirm', { mfaToken: first.json.mfaToken, code: '000000' })).status, 401);
  const code = totp.totp(start.json.secret);
  const done = await call('POST', '/auth/mfa/enroll/confirm', { mfaToken: first.json.mfaToken, code }, null, ADM);
  assert.equal(done.status, 200, JSON.stringify(done.json));
  assert.equal(done.json.recoveryCodes.length, 10);
  assert.ok(cookieOf(done, '__Host-cr_adm'));
  assert.equal((await call('GET', '/admin/users', null, done.json.token)).status, 200);

  // Next sign-in: a code is needed; the same code again is refused (replay); a recovery code works once.
  const second = await login('sec.admin@coroute.test', 'Password#123', ADM);
  assert.equal(second.json.mfa, 'verify');
  assert.equal((await call('POST', '/auth/mfa/verify', { mfaToken: second.json.mfaToken, code })).status, 401, 'replayed code');
  const rc = done.json.recoveryCodes[0];
  const viaRc = await call('POST', '/auth/mfa/verify', { mfaToken: second.json.mfaToken, recoveryCode: rc }, null, ADM);
  assert.equal(viaRc.status, 200);
  const third = await login('sec.admin@coroute.test', 'Password#123', ADM);
  assert.equal((await call('POST', '/auth/mfa/verify', { mfaToken: third.json.mfaToken, recoveryCode: rc })).status, 401, 'recovery code single use');
  const next = totp.hotp(start.json.secret, totp.stepAt() + 1);
  assert.equal((await call('POST', '/auth/mfa/verify', { mfaToken: third.json.mfaToken, code: next }, null, ADM)).status, 200, 'the next step is accepted (clock drift)');
  const s = await env.gw.sessions.get(viaRc.json.sessionId);
  assert.equal(s.mfa, true);
  assert.equal(s.kind, 'admin');
  // An mfa token is bound to its step and expires with a password change.
  assert.equal((await call('POST', '/auth/mfa/enroll/start', { mfaToken: third.json.mfaToken })).status, 401);
  // Riders cannot enrol; the app sign-in of the admin is not blocked (ADMIN_MFA_ENFORCE=web).
  const r = await rider('nomfa');
  assert.equal((await call('POST', '/me/mfa/setup', { currentPassword: 'Password#123' }, r.token)).status, 403);
  assert.ok((await login('sec.admin@coroute.test', 'Password#123', APP2)).json.token);
});

test('requireAdmin with ADMIN_MFA_ENFORCE=all needs a 2-step session', async () => {
  const before = config.adminMfaEnforce;
  try {
    const { requireAdmin } = require('../src/auth');
    config.adminMfaEnforce = 'all';
    const run = (session) => { let code = 0; let nexted = false; requireAdmin({ user: { role: 'MASTER_ADMIN' }, authSession: session }, { status: (c) => ({ json: () => { code = c; } }) }, () => { nexted = true; }); return nexted ? 'next' : code; };
    assert.equal(run({ mfa: false }), 403);
    assert.equal(run({ mfa: true }), 'next');
  } finally { config.adminMfaEnforce = before; }
});

// ------------------------------------------------------------------ object-level access (IDOR)
test('object-level access: trips, ride rosters, timelines, receipts, crews, operator consoles and admin riders refuse other riders', async () => {
  const a = await rider('idora');
  const b = await rider('idorb');
  const trip = await call('POST', '/trips', { tripId: 'TRIP-IDOR-1', name: 'Mine', startTimeEpochMs: Date.now() - 3600000, endTimeEpochMs: Date.now(), distanceKm: 12, durationSec: 3600 }, a.token);
  if (trip.status < 300) {
    assert.equal((await call('GET', '/trips/TRIP-IDOR-1', null, b.token)).status, 404);
    await call('DELETE', '/trips/TRIP-IDOR-1', null, b.token);
    assert.equal((await call('GET', '/trips/TRIP-IDOR-1', null, a.token)).status, 200, 'another rider cannot delete my trip');
  }
  const convoy = await call('POST', '/convoys', { name: 'Private ride' }, a.token);
  assert.equal(convoy.status, 201);
  const gid = convoy.json.groupId;
  for (const p of [`/convoys/${gid}`, `/convoys/${gid}/emergency-roster`, `/convoys/${gid}/timeline`, `/convoys/${gid}/tracks`, `/convoys/${gid}/report`, `/convoys/${gid}/gpx`]) {
    const res = await call('GET', p, null, b.token);
    assert.ok([403, 404].includes(res.status), `${p}: ${res.status}`);
  }
  await env.gw.repo.saveRazorpayOrder({ orderId: 'order_IDOR123456', userId: a.user.userId, status: 'PAID', amountInPaise: 4900, currency: 'INR', category: 'group_small', createdAt: Date.now(), paidAt: Date.now() });
  assert.equal((await call('GET', '/web/receipt/order_IDOR123456', null, b.token)).status, 404);
  assert.equal((await call('GET', '/web/receipt/order_IDOR123456', null, a.token)).status, 200);
  const crew = await call('POST', '/crews', { name: 'Sec Crew' }, a.token);
  if (crew.status < 300) {
    const id = crew.json.crew ? crew.json.crew.crewId : crew.json.crewId;
    assert.ok([403, 404].includes((await call('GET', `/crews/${id}`, null, b.token)).status));
    assert.ok([403, 404].includes((await call('PATCH', `/crews/${id}`, { name: 'Taken' }, b.token)).status));
  }
  assert.ok([403, 404].includes((await call('GET', '/operator/op_someone', null, b.token)).status));
  assert.equal((await call('GET', '/admin/riders', null, b.token)).status, 403);
  assert.equal((await call('GET', `/admin/riders/${a.user.userId}`, null, b.token)).status, 403);
  const orders = await call('GET', '/subscription/orders', null, b.token);
  assert.ok(!JSON.stringify(orders.json).includes('order_IDOR123456'), 'order lists are per rider');
  const coupons = await call('GET', '/me/coupons', null, b.token);
  assert.equal(coupons.status, 200);
});

// ------------------------------------------------------------------ data protection
test('field encryption at rest: phones, emergency contact and medical ID are ciphertext in the database, plaintext in the API', async () => {
  const u = await rider('enc');
  await call('PATCH', '/me', { bloodGroup: 'O+', allergies: 'Penicillin', medicalNotes: 'Asthma inhaler in left pocket' }, u.token);
  const raw = (await env.gw.rawSoda.findOne('users', { userId: u.user.userId })).value;
  for (const f of ['phone', 'emergencyContact', 'emergencyContactName', 'bloodGroup', 'allergies', 'medicalNotes']) {
    assert.ok(String(raw[f]).startsWith('enc:v1:k2:'), `${f} encrypted`);
  }
  assert.equal(raw.email, u.email, 'e-mail stays the plain lookup column');
  const me = await call('GET', '/me', null, u.token);
  assert.equal(me.json.phone, '+919876543210');
  assert.equal(me.json.medicalNotes, 'Asthma inhaler in left pocket');
  // The emergency roster of a ride still reads the real numbers.
  const c = await call('POST', '/convoys', { name: 'Enc ride' }, u.token);
  const roster = await call('GET', `/convoys/${c.json.groupId}/emergency-roster`, null, u.token);
  if (roster.status === 200) assert.ok(!JSON.stringify(roster.json).includes('enc:v1'));
  const rosterRaw = await env.gw.rawSoda.query('convoy_riders', { groupId: c.json.groupId });
  for (const r of rosterRaw) if (r.value.phone) assert.ok(String(r.value.phone).startsWith('enc:v1:'), 'roster copy encrypted');
  assert.equal((await call('GET', '/health')).json.dataEncryption, 'ON');
});

test('lazy migration: plaintext and old-key values are re-encrypted on read; unknown keys never leak ciphertext', async () => {
  const fc = env.gw.fieldCrypto;
  const old = new FieldCrypto({ key: Buffer.alloc(32, 3), keyId: 'k1' });
  const key = await env.gw.rawSoda.insert('users', { userId: 'usr_lazy', email: 'lazy@coroute.test', name: 'Lazy', nameLower: 'lazy', phone: '+919811112222', emergencyContact: old.encrypt('+919833334444'), createdAt: Date.now() });
  const u = await env.gw.repo.findUserById('usr_lazy');
  assert.equal(u.phone, '+919811112222');
  assert.equal(u.emergencyContact, '+919833334444', 'old key still readable');
  await sleep(50);
  const raw = await env.gw.rawSoda.get('users', key);
  assert.ok(raw.phone.startsWith('enc:v1:k2:'), 'plaintext migrated');
  assert.ok(raw.emergencyContact.startsWith('enc:v1:k2:'), 'old key migrated to the current key');
  assert.equal(fc.decrypt(raw.phone), '+919811112222');
  // A concurrent update is never overwritten by the migration (compare-and-replace on the raw document).
  const k2 = await env.gw.rawSoda.insert('users', { userId: 'usr_lazy2', email: 'lazy2@coroute.test', name: 'Lazy2', nameLower: 'lazy2', phone: '+919800000000' });
  const p = env.gw.repo.findUserById('usr_lazy2');
  await env.gw.rawSoda.replace('users', k2, { userId: 'usr_lazy2', email: 'lazy2@coroute.test', name: 'Lazy2', nameLower: 'lazy2', phone: '+919811111111' });
  await p; await sleep(30);
  assert.equal(fc.decrypt((await env.gw.rawSoda.get('users', k2)).phone), '+919811111111');
  // Unknown key id: '' (never "enc:v1:..." as a phone number), reported by health.
  const stranger = new FieldCrypto({ key: Buffer.alloc(32, 5), keyId: 'kX' });
  assert.equal(fc.decrypt(stranger.encrypt('+919899999999')), '');
  assert.ok(fc.missingKids.has('kX'));
  // Tampering is detected (GCM tag).
  const enc = fc.encrypt('+919812345678');
  assert.equal(fc.decrypt(enc.slice(0, -4) + (enc.endsWith('AAAA') ? 'BBBB' : 'AAAA')), '');
  // Blind index: deterministic, keyed, purpose-separated.
  assert.equal(fc.blindIndex('Rider@Example.com', 'email'), fc.blindIndex(' rider@example.com', 'email'));
  assert.notEqual(fc.blindIndex('rider@example.com', 'email'), fc.blindIndex('rider@example.com', 'ip'));
  assert.notEqual(fc.blindIndex('rider@example.com', 'email'), new FieldCrypto({ blindKey: Buffer.alloc(32, 1) }).blindIndex('rider@example.com', 'email'));
  // Without a key nothing is encrypted (deploys before DATA_ENC_KEY behave exactly as before).
  const off = new FieldCrypto({});
  assert.equal(off.encrypt('+919811112222'), '+919811112222');
  assert.deepEqual(off.encryptDoc('users', { phone: '1' }), { phone: '1' });
});

test('log redaction: tokens, passwords, OTPs, e-mails and phone numbers never reach a log line', () => {
  const t = jwt.sign({ sub: 'x' }, 'k');
  const line = redactString(`login rider@example.com phone +91 98765 43210 Bearer ${t} rt1.ses_abcdefghijklmnopqrst.3.${'a'.repeat(43)} /reset?token=abc123&code=123456 at 1731400000000`);
  assert.ok(!line.includes('rider@example.com') && !line.includes('98765 43210') && !line.includes(t) && !line.includes('abc123') && !line.includes('123456 '), line);
  assert.match(line, /r\*\*\*@e\*\*\*\.com/);
  assert.match(line, /3210/);
  assert.match(line, /1731400000000/, 'timestamps are not phone numbers');
  const o = redact({ password: 'hunter2', otp: '123456', nested: { refreshToken: 'rt1.x', note: 'call 9876543210' }, count: 3 });
  assert.equal(o.password, '[redacted]');
  assert.equal(o.otp, '[redacted]');
  assert.equal(o.nested.refreshToken, '[redacted]');
  assert.equal(o.nested.note, 'call ******3210');
  assert.equal(o.count, 3);
  const seen = [];
  const log = redactingLogger({ info: (...a) => seen.push(a.join(' ')), warn() {}, error() {} });
  log.info('mail to', 'someone@coroute.test', { authorization: `Bearer ${t}` });
  assert.ok(!seen[0].includes('someone@coroute.test') && !seen[0].includes(t));
});

test('TOTP: RFC 6238 test vector and base32', () => {
  // RFC 6238 SHA-1 secret "12345678901234567890" at T=59 s -> 94287082 (8 digits); 6-digit form 287082.
  const secret = totp.base32Encode(Buffer.from('12345678901234567890'));
  assert.equal(totp.hotp(secret, 1), '287082');
  assert.equal(totp.base32Decode(secret).toString(), '12345678901234567890');
  assert.equal(totp.verifyTotp(secret, '287082', { now: 59000 }), 1);
  assert.equal(totp.verifyTotp(secret, '287082', { now: 59000, lastStep: 1 }), -1, 'replay refused');
  const rc = totp.newRecoveryCodes(3);
  assert.equal(totp.matchRecoveryCode(rc.codes[1].toLowerCase(), rc.hashes), 1);
  assert.equal(totp.matchRecoveryCode('AAAAA-AAAAA', rc.hashes), -1);
});

test('new-device e-mail: once per new device, never for the first sign-in; suspended riders are cut off everywhere at once', async () => {
  mails.length = 0;
  const u = await rider('newdev');
  assert.equal(mails.filter((m) => /New sign-in/.test(m.subject)).length, 0, 'registration is the first device');
  await login(u.email, 'Password#123', { ...APP2, 'User-Agent': 'Dart/3.7 (dart:io)' }, { device: { label: 'Galaxy S24', platform: 'android' } });
  await sleep(20);
  assert.equal(mails.filter((m) => m.subject === 'New sign-in to CoRoute on Galaxy S24').length, 1);
  await login(u.email, 'Password#123', { ...APP2, 'User-Agent': 'Dart/3.7 (dart:io)' }, { device: { label: 'Galaxy S24', platform: 'android' } });
  await sleep(20);
  assert.equal(mails.filter((m) => m.subject === 'New sign-in to CoRoute on Galaxy S24').length, 1, 'known device: no second mail');

  const admin = await login('sec.admin@coroute.test', 'Password#123');
  const v = await rider('suspend');
  const s = await login(v.email, 'Password#123', APP2);
  const ws = await socket(s.json.token);
  assert.equal((await call('PATCH', `/admin/users/${v.user.userId}/status`, { status: 'BLOCKED', reason: 'test' }, admin.json.token)).status, 200);
  assert.equal((await ws.closed).code, 4403);
  assert.equal((await call('GET', '/me', null, s.json.token)).status, 403);
  assert.equal((await call('POST', '/auth/refresh', { refreshToken: s.json.refreshToken })).status, 401);
});

test('a sign-out never cuts a rider out of a live ride: the ride socket stays (SOS still relays) until the ride ends', async () => {
  const lead = await rider('ridelead');
  const r = await rider('riderevoke');
  const phone = await login(r.email, 'Password#123', APP2);
  // Round 4: a laptop signed in BEFORE the ride (during it, the ride lock answers 423 to a new sign-in).
  const laptop = await login(r.email);
  const c = await call('POST', '/convoys', { name: 'Revoke ride' }, lead.token);
  assert.equal(c.status, 201);
  assert.equal((await call('POST', '/convoys/join', { code: c.json.joinCode }, phone.json.token)).status, 200);
  const wl = await env.joinRoom(lead.token, c.json.groupId);
  const wr = await env.joinRoom(phone.json.token, c.json.groupId);
  const other = await rider('riderother');
  const otherPhone = await login(other.email, 'Password#123', APP2);
  const notRiding = await socket(otherPhone.json.token);
  // A new sign-in on another device during the ride is refused (round 4 ride lock).
  assert.equal((await login(r.email)).status, 423);
  // Signed out of all devices from the laptop, mid-ride.
  assert.equal((await call('POST', '/auth/logout-all', {}, laptop.json.token)).status, 200);
  assert.equal((await call('GET', '/me', null, phone.json.token)).status, 401, 'REST refuses the session at once');
  // (A rider who is not on a ride is cut at once.)
  await call('POST', '/auth/logout-all', {}, otherPhone.json.token);
  assert.equal((await notRiding.closed).code, 4401);
  await sleep(100);
  assert.equal(wr.readyState, WebSocket.OPEN, 'the ride socket stays');
  // Round 4: it stays in safety-only mode: told so, no other rider's position or chat, no chat of its own.
  await wr.next((m) => m.type === 'SAFETY_ONLY');
  wl.sendJson({ type: 'TELEMETRY', lat: 17.31, lng: 78.41, speedKmh: 30 });
  wl.sendJson({ type: 'CHAT', text: 'hello group' });
  wr.sendJson({ type: 'CHAT', text: 'from a revoked phone' });
  const refused = await wr.next((m) => m.type === 'ERROR');
  assert.equal(refused.reason, 'SAFETY_ONLY');
  wr.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4, clientId: 'sos-after-revoke' });
  const alert = await wl.next((m) => m.type === 'ALERT');
  assert.equal(alert.alert.userId, r.user.userId, 'the group still gets the SOS');
  const own = await wr.next((m) => m.type === 'ALERT');
  assert.equal(own.alert.userId, r.user.userId, 'its own SOS echo arrives');
  await sleep(150);
  assert.ok(!wr.inbox.some((m) => m.type === 'RIDER_UPDATE' || m.type === 'MESSAGE' || m.type === 'SNAPSHOT'), 'no positions, chat or member data');
  // A reconnect during the ride (tunnel) is allowed back into the ride.
  const back = await socket(phone.json.token);
  assert.ok(back.inbox, 'reconnect during the ride');
  // The ride ends: the kept sockets close.
  assert.equal((await call('POST', `/convoys/${c.json.groupId}/status`, { status: 'ENDED' }, lead.token)).status, 200);
  assert.equal((await wr.closed), 4401);
  assert.equal((await back.closed).code, 4401);
  wl.close();
});

// ------------------------------------------------------------------ round 4 additions
test('round 4: account deletion from builds before 10025 without a password: e-mailed confirmation link (30 min, single use)', async () => {
  const u = await rider('delconfirm');
  const s = await login(u.email); // no new headers: a legacy session (builds before 10025)
  mails.length = 0;
  const r = await call('DELETE', '/me', null, s.json.token);
  assert.equal(r.status, 202);
  assert.equal(r.json.code, 'DELETE_CONFIRM_SENT');
  assert.match(r.json.message, /s\*\*\*@coroute\.test/);
  const m = mails.find((x) => x.to === u.email && x.subject === 'Confirm deleting your CoRoute account');
  assert.ok(m, 'confirmation e-mail');
  const token = /#confirm-delete=([A-Za-z0-9_-]{40,60})/.exec(m.text)[1];
  const doc = await env.gw.repo.findUserById(u.user.userId);
  assert.ok(doc.deleteConfirmHash && !JSON.stringify(doc).includes(token), 'only a hash is stored');
  assert.equal((await call('POST', '/auth/delete/confirm', { token: 'x'.repeat(43) })).status, 400);
  const ok = await call('POST', '/auth/delete/confirm', { token });
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.equal(await env.gw.repo.findUserById(u.user.userId), null, 'deleted');
  assert.equal((await call('POST', '/auth/delete/confirm', { token })).status, 400, 'single use');
  // An expired link does nothing.
  const v = await rider('delexpired');
  const vs = await login(v.email);
  mails.length = 0;
  await call('DELETE', '/me', null, vs.json.token);
  const t2 = /#confirm-delete=([A-Za-z0-9_-]{40,60})/.exec(mails.find((x) => x.to === v.email).text)[1];
  const d2 = await env.gw.repo.findUserById(v.user.userId);
  await env.gw.repo.updateUser(d2.key, { deleteConfirmExp: Date.now() - 1000 });
  assert.equal((await call('POST', '/auth/delete/confirm', { token: t2 })).status, 400);
  assert.ok(await env.gw.repo.findUserById(v.user.userId));
});

test('round 4: ADMIN_MFA_ENFORCE=all (default) by build: app >= 10025 admin calls need 2-step (step-up with a code), older builds keep web; strict covers all', async () => {
  assert.equal(config.adminMfaEnforce, 'all', 'the default');
  // sec.admin enrolled TOTP in the 2-step test above; enrol here when this test runs alone.
  let doc = await env.gw.repo.findUserByEmail('sec.admin@coroute.test');
  if (!doc) { await rider('admin'); doc = await env.gw.repo.findUserByEmail('sec.admin@coroute.test'); }
  const secret = totp.newSecret();
  await env.gw.repo.updateUser(doc.key, { mfaEnabled: true, mfaSecret: secret, mfaLastStep: -1, mfaRecovery: totp.newRecoveryCodes().hashes });
  env.gw.gate.invalidate(doc.userId);
  const app = await login('sec.admin@coroute.test', 'Password#123', { ...APP2, 'X-CoRoute-Build': '10025' });
  assert.equal(app.status, 200, 'the app sign-in itself never asks for a code (an admin is also a rider)');
  const refused = await call('GET', '/admin/users', null, app.json.token);
  assert.equal(refused.status, 403);
  assert.equal(refused.json.code, 'MFA_REQUIRED');
  assert.equal(refused.json.mfaEnrolled, true);
  assert.deepEqual(refused.json.methods, ['totp', 'recovery'], 'no e-mail codes for MASTER_ADMIN');
  assert.equal((await call('POST', '/auth/mfa/step-up/email-code', {}, app.json.token)).status, 403, 'MASTER_ADMIN cannot use e-mail codes');
  assert.equal((await call('POST', '/auth/mfa/step-up', { code: '000000' }, app.json.token)).status, 401);
  const up = await call('POST', '/auth/mfa/step-up', { code: totp.totp(secret) }, app.json.token);
  assert.equal(up.status, 200, JSON.stringify(up.json));
  assert.equal((await call('GET', '/admin/users', null, app.json.token)).status, 200, 'after the step-up');
  // An older build (legacy session): 'web' behaviour, not locked out of its admin screens.
  const old = await login('sec.admin@coroute.test');
  assert.equal((await call('GET', '/admin/users', null, old.json.token)).status, 200);
  const prev = config.adminMfaEnforce;
  try {
    config.adminMfaEnforce = 'strict';
    assert.equal((await call('GET', '/admin/users', null, old.json.token)).json.code, 'MFA_REQUIRED');
    config.adminMfaEnforce = 'web';
    const app2 = await login('sec.admin@coroute.test', 'Password#123', APP2);
    assert.equal((await call('GET', '/admin/users', null, app2.json.token)).status, 200);
  } finally { config.adminMfaEnforce = prev; }
});

test('round 4: e-mailed 2-step codes for operators without an authenticator app (website / console sign-in step); never for MASTER_ADMIN', async () => {
  const u = await rider('emailmfa');
  const doc = await env.gw.repo.findUserById(u.user.userId);
  await env.gw.repo.updateUser(doc.key, { mfaEmail: true });
  env.gw.gate.invalidate(u.user.userId);
  const first = await login(u.email, 'Password#123', {}, { client: 'web' });
  assert.equal(first.json.mfa, 'verify', JSON.stringify(first.json));
  assert.deepEqual(first.json.methods, ['email']);
  mails.length = 0;
  const sent = await call('POST', '/auth/mfa/email-code', { mfaToken: first.json.mfaToken });
  assert.equal(sent.status, 202, JSON.stringify(sent.json));
  const m = mails.find((x) => x.to === u.email && x.subject === 'Your CoRoute sign-in code');
  assert.ok(m);
  const code = /\b(\d{6})\b/.exec(m.text)[1];
  assert.equal((await call('POST', '/auth/mfa/verify', { mfaToken: first.json.mfaToken, emailCode: code === '999999' ? '000000' : '999999' })).status, 401);
  const ok = await call('POST', '/auth/mfa/verify', { mfaToken: first.json.mfaToken, emailCode: code, client: 'web' }, null, { 'X-CoRoute-Client': 'web' });
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.equal((await env.gw.sessions.get(ok.json.sessionId)).mfa, true);
  // MASTER_ADMIN: refused even when the flag is set in the database.
  const adm = await env.gw.repo.findUserByEmail('sec.admin@coroute.test');
  if (adm) {
    await env.gw.repo.updateUser(adm.key, { mfaEmail: true });
    const a = await login('sec.admin@coroute.test', 'Password#123', {}, { client: 'admin' });
    if (a.json.mfaToken) assert.equal((await call('POST', '/auth/mfa/email-code', { mfaToken: a.json.mfaToken })).status, 403);
    await env.gw.repo.updateUser(adm.key, { mfaEmail: false });
  }
});

test('round 4: WebSocket auth as the first message (no token in the URL) within WS_AUTH_TIMEOUT_MS, or the subprotocol; ?token= still works for old builds', async () => {
  const u = await rider('wsfirst');
  const s = await login(u.email, 'Password#123', APP2);
  const open = (url, protocols) => new Promise((resolve) => {
    const ws = new WebSocket(url, protocols);
    ws.inbox = [];
    ws.on('message', (d) => ws.inbox.push(JSON.parse(d.toString())));
    ws.closed = new Promise((res) => ws.on('close', (code, reason) => res({ code, reason: String(reason) })));
    ws.on('error', () => {});
    ws.once('open', () => resolve(ws));
  });
  const until = async (fn, ms = 2000) => { const end = Date.now() + ms; while (!fn()) { if (Date.now() > end) throw new Error('timeout'); await sleep(10); } };
  // First message.
  const a = await open(env.wsBase);
  a.send(JSON.stringify({ type: 'AUTH', token: s.json.token }));
  await until(() => a.inbox.some((m) => m.type === 'HELLO'));
  a.send(JSON.stringify({ type: 'PING' }));
  await until(() => a.inbox.some((m) => m.type === 'PONG'));
  a.close();
  // Subprotocol: the server echoes only "coroute.v1" (never the bearer entry).
  const b = await open(env.wsBase, ['coroute.v1', `coroute.bearer.${s.json.token}`]);
  assert.equal(b.protocol, 'coroute.v1');
  await until(() => b.inbox.some((m) => m.type === 'HELLO'));
  b.close();
  // A wrong first message, or none in time: closed 4401.
  const c = await open(env.wsBase);
  c.send(JSON.stringify({ type: 'JOIN', groupId: 'GRP-X' }));
  assert.equal((await c.closed).code, 4401);
  const prev = config.wsAuthTimeoutMs;
  config.wsAuthTimeoutMs = 300;
  try {
    const d = await open(env.wsBase);
    const closed = await d.closed;
    assert.deepEqual([closed.code, closed.reason], [4401, 'AUTH_TIMEOUT']);
  } finally { config.wsAuthTimeoutMs = prev; }
  // Old builds: ?token=.
  const e = await socket(s.json.token);
  assert.ok(e.inbox, 'legacy query token accepted'); e.close();
  // Tokens never reach a log line (gateway logger), also inside a logged URL.
  assert.ok(!redactString(`GET /ws?token=${s.json.token} 101`).includes(s.json.token));
});

test('round 4: HSTS is configurable (HSTS_MAX_AGE, HSTS_PRELOAD)', async () => {
  const prev = { age: config.hstsMaxAge, pre: config.hstsPreload };
  config.hstsMaxAge = 300; config.hstsPreload = false;
  const one = await boot({ mailTransport });
  try {
    const r = await fetch(`${one.base}/health`);
    assert.equal(r.headers.get('strict-transport-security'), 'max-age=300; includeSubDomains');
  } finally { await one.gw.shutdown(); }
  config.hstsMaxAge = 63072000; config.hstsPreload = true;
  const two = await boot({ mailTransport });
  try {
    const r = await fetch(`${two.base}/health`);
    assert.equal(r.headers.get('strict-transport-security'), 'max-age=63072000; includeSubDomains; preload');
  } finally { await two.gw.shutdown(); config.hstsMaxAge = prev.age; config.hstsPreload = prev.pre; }
});

test('round 4: every security e-mail template renders text and escaped HTML', () => {
  const { TEMPLATES, render } = require('../src/security_emails');
  for (const id of Object.keys(TEMPLATES)) {
    const m = render(id, { name: '<b>Asha</b>', device: 'Pixel 7', otherDevice: 'Galaxy', code: '123456', minutes: 10, hours: 24, link: 'https://coroute.example/x#t=1', signinUrl: 'https://coroute.example/signin', securityUrl: 'https://coroute.example/account', at: 'now', where: 'the console' }, { origin: 'https://coroute.example' });
    assert.ok(m.subject && m.text && m.html, id);
    assert.ok(!m.html.includes('<b>Asha</b>') && m.html.includes('&lt;b&gt;Asha&lt;/b&gt;'), `${id}: escaped`);
    assert.ok(!/<script|<img/i.test(m.html), `${id}: no scripts or remote images`);
  }
});
