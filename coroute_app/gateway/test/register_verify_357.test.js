'use strict';
/**
 * Round 4 sign-up e-mail verification (audit #9): the same generic 202 for a new and a registered address, a single-use
 * 24 h link by SMTP, "someone tried to create an account with your e-mail" instead of a 409, no sign-in before the
 * link, Google counts as verified, resend rate limited, purge after 7 days, old builds (REGISTER_VERIFY_LEGACY).
 */
process.env.NODE_ENV = 'test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const config = require('../src/config');
const { boot } = require('./_helpers');

let env; let ipSeq = 0;
const mails = [];
const mailTransport = { sendMail: async (m) => { mails.push(m); return { messageId: `m${mails.length}` }; } };
const googleVerifier = { verifyIdToken: async ({ idToken }) => ({ getPayload: () => ({ email: idToken, email_verified: true, sub: `g-${idToken}`, iss: 'accounts.google.com', name: 'G Rider' }) }) };
const ip = () => `10.99.${Math.floor(++ipSeq / 250)}.${ipSeq % 250}`;
const APP = { 'X-CoRoute-Session': '2', 'X-CoRoute-Client': 'app', 'X-CoRoute-Build': '10025' };
const OLD = { 'X-CoRoute-Build': '10010' };

before(async () => { env = await boot({ mailTransport, googleVerifier }); });
after(async () => { await env.gw.shutdown(); });

const call = (method, path, body, token, headers = {}) => env.api(method, path, body, token, { 'X-Forwarded-For': ip(), ...headers });
const form = (tag, extra = {}) => ({
  name: `Reg ${tag}`, email: `reg.${tag}@coroute.test`, password: 'Password#123', phone: '+919876543210',
  vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact', ...extra,
});
const mailsTo = (to, subject) => mails.filter((m) => m.to === to && (!subject || String(m.subject).includes(subject)));
const linkToken = (m) => /#verify=([A-Za-z0-9_-]{40,60})/.exec(m.text)[1];

test('a new address: generic 202, verification link by e-mail, no sign-in before the link, then the account works', async () => {
  const r = await call('POST', '/auth/register', form('new'), null, APP);
  assert.equal(r.status, 202, JSON.stringify(r.json));
  assert.equal(r.json.message, 'Check your e-mail to finish creating your account');
  assert.equal(r.json.token, undefined, 'no session before verification');
  const m = mailsTo('reg.new@coroute.test', 'Confirm your e-mail')[0];
  assert.ok(m, 'verification mail');
  assert.match(m.text, /https:\/\/coroute\.example\/signin#verify=/);
  assert.ok(m.html.includes('Confirm my e-mail'));
  const doc = await env.gw.repo.findUserByEmail('reg.new@coroute.test');
  assert.equal(doc.emailVerified, false);
  assert.ok(doc.emailVerifyHash && !String(JSON.stringify(doc)).includes(linkToken(m)), 'only a hash is stored');
  // Sign-in before the link: refused only after the right password (a wrong one is the usual 401).
  const early = await call('POST', '/auth/login', { identifier: 'reg.new@coroute.test', password: 'Password#123' }, null, APP);
  assert.equal(early.status, 403);
  assert.equal(early.json.code, 'EMAIL_NOT_VERIFIED');
  assert.equal((await call('POST', '/auth/login', { identifier: 'reg.new@coroute.test', password: 'Nope#Password9' }, null, APP)).status, 401);
  // The link.
  const v = await call('POST', '/auth/email/verify', { token: linkToken(m) });
  assert.equal(v.status, 200, JSON.stringify(v.json));
  assert.equal((await call('POST', '/auth/email/verify', { token: linkToken(m) })).status, 400, 'single use');
  const ok = await call('POST', '/auth/login', { identifier: 'reg.new@coroute.test', password: 'Password#123' }, null, APP);
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.ok(ok.json.token && ok.json.refreshToken);
});

test('a registered address: the same 202 (no 409), and that address is told someone tried (once per 6 hours)', async () => {
  const first = await call('POST', '/auth/register', form('taken'), null, APP);
  await call('POST', '/auth/email/verify', { token: linkToken(mailsTo('reg.taken@coroute.test', 'Confirm')[0]) });
  mails.length = 0;
  const again = await call('POST', '/auth/register', form('taken', { name: 'Reg Someone Else' }), null, APP);
  assert.equal(again.status, 202);
  assert.deepEqual(again.json, first.json, 'identical answer: no enumeration');
  const tried = mailsTo('reg.taken@coroute.test', 'Someone tried');
  assert.equal(tried.length, 1);
  assert.match(tried[0].text, /Someone tried to create an account with your e-mail; if it was you, sign in or reset your password\./);
  await call('POST', '/auth/register', form('taken', { name: 'Reg Third Try' }), null, APP);
  assert.equal(mailsTo('reg.taken@coroute.test', 'Someone tried').length, 1, 'not repeated within 6 hours');
  // The account was not changed.
  assert.equal((await call('POST', '/auth/login', { identifier: 'reg.taken@coroute.test', password: 'Password#123' }, null, APP)).status, 200);
});

test('a callsign that is taken is said (callsigns are public) whatever the address; a pending sign-up repeated never replaces its password', async () => {
  await call('POST', '/auth/register', form('callsign'), null, APP);
  const dup = await call('POST', '/auth/register', form('callsign2', { name: 'Reg callsign' }), null, APP);
  assert.equal(dup.status, 409);
  assert.equal(dup.json.code, 'CALLSIGN_TAKEN');
  // The same pending sign-up again with another password: the link is sent again, the first password stays.
  mails.length = 0;
  const again = await call('POST', '/auth/register', form('pend', { password: 'First#Passw0rd' }), null, APP);
  assert.equal(again.status, 202);
  await new Promise((r) => setTimeout(r, 5));
  const second = await call('POST', '/auth/register', form('pend', { password: 'Second#Passw0rd' }), null, APP);
  assert.equal(second.status, 202);
  const link = mailsTo('reg.pend@coroute.test', 'Confirm')[0];
  await call('POST', '/auth/email/verify', { token: linkToken(link) });
  assert.equal((await call('POST', '/auth/login', { identifier: 'reg.pend@coroute.test', password: 'Second#Passw0rd' }, null, APP)).status, 401);
  assert.equal((await call('POST', '/auth/login', { identifier: 'reg.pend@coroute.test', password: 'First#Passw0rd' }, null, APP)).status, 200);
});

test('resend: always 202, a new link only for a pending sign-up, rate limited', async () => {
  await call('POST', '/auth/register', form('resend'), null, APP);
  mails.length = 0;
  const r1 = await call('POST', '/auth/register/resend', { email: 'reg.resend@coroute.test' });
  assert.equal(r1.status, 202);
  assert.equal(mailsTo('reg.resend@coroute.test').length, 0, 'not within 60 s of the last link');
  const doc = await env.gw.repo.findUserByEmail('reg.resend@coroute.test');
  await env.gw.repo.updateUser(doc.key, { emailVerifySent: [Date.now() - 120000] });
  const r2 = await call('POST', '/auth/register/resend', { email: 'reg.resend@coroute.test' });
  assert.equal(r2.status, 202);
  assert.equal(mailsTo('reg.resend@coroute.test', 'Confirm').length, 1);
  const unknown = await call('POST', '/auth/register/resend', { email: 'nobody.reg@coroute.test' });
  assert.equal(unknown.status, 202);
  assert.deepEqual(unknown.json, r2.json, 'same answer for unknown addresses');
});

test('Google sign-in is verified: a pending sign-up with that address becomes usable', async () => {
  await call('POST', '/auth/register', form('google'), null, APP);
  const g = await call('POST', '/auth/google', { idToken: 'reg.google@coroute.test' }, null, APP);
  assert.equal(g.status, 200, JSON.stringify(g.json));
  const doc = await env.gw.repo.findUserByEmail('reg.google@coroute.test');
  assert.equal(doc.emailVerified, true);
});

test('the website (client web) gets the same verification flow', async () => {
  const r = await call('POST', '/auth/register', { ...form('web'), client: 'web' }, null, { 'X-CoRoute-Client': 'web' });
  assert.equal(r.status, 202);
});

test('builds before 10025: REGISTER_VERIFY_LEGACY=verify answers a readable message (same for every address); allow keeps 201 + token', async () => {
  const prev = config.registerVerifyLegacy;
  try {
    config.registerVerifyLegacy = 'verify';
    const a = await call('POST', '/auth/register', form('oldnew'), null, OLD);
    assert.equal(a.status, 400);
    assert.equal(a.json.code, 'EMAIL_VERIFICATION_SENT');
    assert.match(a.json.error, /^Check your e-mail to finish creating your account\./);
    assert.ok(mailsTo('reg.oldnew@coroute.test', 'Confirm').length === 1);
    const b = await call('POST', '/auth/register', form('oldnew', { name: 'Reg Other Old' }), null, OLD);
    assert.deepEqual([b.status, b.json], [a.status, a.json], 'no enumeration for old builds either');
    config.registerVerifyLegacy = 'allow';
    const c = await call('POST', '/auth/register', form('oldallow'), null, OLD);
    assert.equal(c.status, 201);
    assert.ok(c.json.token, 'old behaviour behind the flag');
  } finally { config.registerVerifyLegacy = prev; }
});

test('a password reset link proves the address (pending sign-up verified); existing accounts count as verified', async () => {
  await call('POST', '/auth/register', form('reset'), null, APP);
  mails.length = 0;
  await call('POST', '/auth/password/forgot', { email: 'reg.reset@coroute.test' });
  const m = mailsTo('reg.reset@coroute.test', 'Reset')[0];
  const token = /#reset=([A-Za-z0-9_-]+)/.exec(m.text)[1];
  assert.equal((await call('POST', '/auth/password/reset', { token, newPassword: 'Brand#New#Pass1' })).status, 200);
  assert.equal((await call('POST', '/auth/login', { identifier: 'reg.reset@coroute.test', password: 'Brand#New#Pass1' }, null, APP)).status, 200);
  // An account from before round 4 has no emailVerified field: it signs in as before.
  const legacy = await call('POST', '/auth/register', form('legacyacct'));
  assert.equal(legacy.status, 201);
  const doc = await env.gw.repo.findUserByEmail('reg.legacyacct@coroute.test');
  assert.equal(doc.emailVerified, undefined);
  assert.equal((await call('POST', '/auth/login', { identifier: 'reg.legacyacct@coroute.test', password: 'Password#123' }, null, APP)).status, 200);
});

test('sign-ups never verified are purged after REGISTER_PURGE_DAYS; verified ones stay', async () => {
  await call('POST', '/auth/register', form('purge'), null, APP);
  await call('POST', '/auth/register', form('keep'), null, APP);
  await call('POST', '/auth/email/verify', { token: linkToken(mailsTo('reg.keep@coroute.test', 'Confirm')[0]) });
  for (const e of ['reg.purge@coroute.test', 'reg.keep@coroute.test']) {
    const d = await env.gw.repo.findUserByEmail(e);
    await env.gw.repo.updateUser(d.key, { createdAt: Date.now() - (config.registerPurgeDays + 1) * 86400000 });
  }
  const n = await env.gw.auth.purgeUnverified();
  assert.ok(n >= 1);
  assert.equal(await env.gw.repo.findUserByEmail('reg.purge@coroute.test'), null);
  assert.ok(await env.gw.repo.findUserByEmail('reg.keep@coroute.test'));
});
