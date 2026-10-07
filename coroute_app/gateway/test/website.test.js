'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

let gw, base, soda;
before(async () => {
  soda = new MemorySoda();
  gw = await createApp({ soda, logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('home page renders with origin-aware canonical, social image and no secrets', async () => {
  const r = await fetch(base + '/');
  const html = await r.text();
  assert.equal(r.status, 200);
  assert.ok(html.includes(`<link rel="canonical" href="${base}/">`));
  assert.ok(html.includes(`<meta property="og:image" content="${base}/og-image.png">`));
  assert.ok(!html.includes('__ORIGIN__'));
  assert.ok(!/JWT_SECRET|ORACLE_|oraclecloudapps|Basic [A-Za-z0-9+/=]+/i.test(html), 'secret-looking content in page');
  assert.ok(!/[A-Za-z0-9+/]{40,}={0,2}/.test(html.replace(/data:image[^"]+/g, '')), 'base64-looking blob in page');
  assert.ok(!html.includes('—'), 'em dash present');
});

test('privacy, terms, 404 page, robots, sitemap, static assets, download redirect', async () => {
  for (const p of ['/privacy', '/terms']) assert.equal((await fetch(base + p)).status, 200);
  const nf = await fetch(base + '/no-such-page');
  assert.equal(nf.status, 404);
  assert.match(nf.headers.get('content-type'), /text\/html/);
  assert.ok((await nf.text()).includes('Back to CoRoute'));
  const apiNf = await fetch(base + '/api/nope');
  assert.ok([401, 404].includes(apiNf.status)); // unknown API paths never return HTML
  assert.match(apiNf.headers.get('content-type'), /json/);

  const robots = await (await fetch(base + '/robots.txt')).text();
  assert.ok(robots.includes(`Sitemap: ${base}/sitemap.xml`));
  const sm = await (await fetch(base + '/sitemap.xml')).text();
  assert.ok(sm.includes(`<loc>${base}/privacy</loc>`) && sm.includes(`<loc>${base}/terms</loc>`));

  for (const p of ['/og-image.png', '/favicon.svg', '/favicon-32.png', '/apple-touch-icon.png', '/site.webmanifest']) {
    assert.equal((await fetch(base + p)).status, 200, p);
  }
  const al = await fetch(base + '/.well-known/assetlinks.json');
  assert.equal(al.status, 200);
  assert.equal((await al.json())[0].target.package_name, 'space.devmonks.coroute_app');
  // Without PLAY_STORE_URL / APK_URL the download is the APK this server hosts.
  const dl = await fetch(base + '/download', { redirect: 'manual' });
  assert.equal(dl.status, 302);
  assert.equal(dl.headers.get('location'), `${base}/coroute.apk`);
  const dl32 = await fetch(base + '/download/32bit', { redirect: 'manual' });
  assert.equal(dl32.status, 302);
  assert.equal(dl32.headers.get('location'), `${base}/coroute-32bit.apk`);
});

test('internal documentation is not served; public pages follow the site rules', async () => {
  for (const p of ['/docs', '/docs.html', '/architecture', '/COROUTE_SYSTEM_DOCUMENTATION.html']) {
    assert.equal((await fetch(base + p, { redirect: 'manual' })).status, 404, p);
  }
  const fs = require('fs');
  const path = require('path');
  const dir = path.join(__dirname, '..', 'public');
  const pages = fs.readdirSync(dir).filter((f) => f.endsWith('.html'));
  assert.ok(pages.length >= 5);
  for (const f of pages) {
    const html = fs.readFileSync(path.join(dir, f), 'utf8');
    assert.ok(!/[\u2013\u2014]/.test(html), `${f}: en or em dash`);
    assert.ok(!/[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]/u.test(html), `${f}: emoji`);
    assert.ok(!/\b(?:\d{1,3}\.){3}\d{1,3}\b/.test(html), `${f}: IPv4 address`);
    assert.ok(!/oraclecloudapps/i.test(html), `${f}: database host name`);
  }
  // The convoy size on the home page comes from the gateway's configuration.
  const home = await (await fetch(base + '/')).text();
  const config = require('../src/config');
  assert.ok(home.includes(`Up to ${config.maxConvoyRiders} riders`), 'max riders from config');
  assert.ok(!home.includes('__MAX_RIDERS__'));
  assert.ok(home.includes('/download/32bit'));
});

test('APKs served from public/ are never cached under the same name', async () => {
  const fs = require('fs');
  const path = require('path');
  const apk = path.join(__dirname, '..', 'public', 'coroute-test-only.apk');
  fs.writeFileSync(apk, 'PK');
  try {
    const r = await fetch(base + '/coroute-test-only.apk');
    assert.equal(r.status, 200);
    assert.equal(r.headers.get('cache-control'), 'no-cache');
    assert.match(r.headers.get('content-type'), /android\.package-archive/);
  } finally {
    fs.unlinkSync(apk);
  }
});

test('feedback form: validation, honeypot, timing, storage', async () => {
  const post = (body) => fetch(base + '/api/feedback', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const old = Date.now() - 10000;
  // honeypot filled → silently dropped
  assert.equal((await post({ website: 'spam.example', email: 'a@b.co', message: 'x'.repeat(30), t: old })).status, 204);
  // submitted too fast → rejected
  assert.equal((await post({ email: 'a@b.co', message: 'x'.repeat(30), t: Date.now() })).status, 400);
  // invalid fields → 422 with field errors
  const bad = await post({ email: 'not-an-email', message: 'short', t: old });
  assert.equal(bad.status, 422);
  const j = await bad.json();
  assert.ok(j.fields.email && j.fields.message);
  // valid → stored
  const ok = await post({ name: 'Rider', email: 'rider@example.com', message: 'The intercom picker is great, but the SOS button is hard to reach with gloves.', t: old });
  assert.equal(ok.status, 201);
  const stored = await gw.repo.listFeedback();
  assert.equal(stored.length, 1);
  assert.equal(stored[0].email, 'rider@example.com');
});

test('page-view beacon counts per day/path with no identifiers; admin can read analytics', async () => {
  for (let i = 0; i < 3; i++) {
    const r = await fetch(base + '/api/pv', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify({ path: '/', ref: 'https://forum.example.com/t/1' }) });
    assert.equal(r.status, 204);
  }
  await fetch(base + '/api/pv', { method: 'POST', body: JSON.stringify({ path: '/privacy' }) });
  await sleep(50);
  const day = new Date().toISOString().slice(0, 10);
  const rows = await gw.repo.listPageviews(day);
  const home = rows.find((r) => r.path === '/');
  assert.equal(home.count, 3);
  assert.equal(home.referrers['forum.example.com'], 3);
  assert.ok(!('ip' in home) && !('userAgent' in home));

  const reg = await fetch(base + '/api/auth/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'Admin', email: 'admin@coroute.test', password: 'Password#123', phone: '9999999999' }) });
  const { token } = await reg.json();
  const a = await fetch(base + '/api/admin/analytics?days=7', { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(a.status, 200);
  assert.equal((await a.json()).pageviews.length, 2);
  const fb = await fetch(base + '/api/admin/feedback', { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(fb.status, 200);
});

test('meta endpoint, join link page, account deletion and admin password reset', async () => {
  const meta = await (await fetch(base + '/api/meta')).json();
  assert.equal(meta.minBuild, 60);
  assert.ok(meta.privacyUrl.endsWith('/privacy') && meta.termsUrl.endsWith('/terms'));

  const join = await fetch(base + '/join/483921');
  assert.equal(join.status, 200);
  const jh = await join.text();
  assert.ok(jh.includes('coroute://join/483921') && jh.includes('483921'));
  assert.equal((await fetch(base + '/join/<script>', { redirect: 'manual' })).status, 302);

  const reg = async (name, email) => (await (await fetch(base + '/api/auth/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name, email, password: 'Password#123', phone: '9999999999', vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' }) })).json());
  const admin = (await (await fetch(base + '/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ identifier: 'admin@coroute.test', password: 'Password#123' }) })).json());
  const u = await reg('Delete Me', 'deleteme@coroute.test');
  const H = (t) => ({ 'Content-Type': 'application/json', Authorization: `Bearer ${t}` });

  // change password: wrong current → 401, right → ok, then login with new one
  assert.equal((await fetch(base + '/api/me/password', { method: 'POST', headers: H(u.token), body: JSON.stringify({ currentPassword: 'nope', newPassword: 'NewPassword#456' }) })).status, 401);
  assert.equal((await fetch(base + '/api/me/password', { method: 'POST', headers: H(u.token), body: JSON.stringify({ currentPassword: 'Password#123', newPassword: 'NewPassword#456' }) })).status, 200);
  const relog = await fetch(base + '/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ identifier: 'deleteme@coroute.test', password: 'NewPassword#456' }) });
  assert.equal(relog.status, 200);

  // admin reset → temporary password, mustChangePassword flag, user can set a new one without the current
  const reset = await (await fetch(base + `/api/admin/users/${u.user.userId}/reset-password`, { method: 'POST', headers: H(admin.token) })).json();
  assert.ok(reset.temporaryPassword.length >= 10);
  const tmpLogin = await (await fetch(base + '/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ identifier: 'deleteme@coroute.test', password: reset.temporaryPassword }) })).json();
  assert.equal(tmpLogin.user.mustChangePassword, true);
  const changed = await fetch(base + '/api/me/password', { method: 'POST', headers: H(tmpLogin.token), body: JSON.stringify({ newPassword: 'Fresh#Password9' }) });
  assert.equal(changed.status, 200);
  // The device that changed the password gets a fresh token; the old one is ended.
  tmpLogin.token = (await changed.json()).token;
  assert.ok(tmpLogin.token);

  // delete account: user, memberships and trips are gone; token stops working
  await fetch(base + '/api/convoys', { method: 'POST', headers: H(tmpLogin.token), body: JSON.stringify({ name: 'Doomed convoy' }) });
  await fetch(base + '/api/trips', { method: 'POST', headers: H(tmpLogin.token), body: JSON.stringify({ tripId: 'TRIP-DEL', endTimeEpochMs: Date.now() }) });
  const del = await fetch(base + '/api/me', { method: 'DELETE', headers: H(tmpLogin.token) });
  assert.equal(del.status, 200);
  assert.equal(await gw.repo.findUserByEmail('deleteme@coroute.test'), null);
  assert.equal((await gw.repo.listTripsForUser(u.user.userId)).length, 0);
  assert.ok([401, 404].includes((await fetch(base + '/api/me', { headers: H(tmpLogin.token) })).status));

  // the last admin cannot delete themselves
  assert.equal((await fetch(base + '/api/me', { method: 'DELETE', headers: H(admin.token) })).status, 409);
});
