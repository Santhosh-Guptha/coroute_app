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
  const dl = await fetch(base + '/download', { redirect: 'manual' });
  assert.equal(dl.status, 302);
  assert.match(dl.headers.get('location'), /github\.com\/.*releases/);
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

  const reg = await fetch(base + '/api/auth/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'Admin', email: 'admin@coroute.test', password: 'Password#123', phone: '1' }) });
  const { token } = await reg.json();
  const a = await fetch(base + '/api/admin/analytics?days=7', { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(a.status, 200);
  assert.equal((await a.json()).pageviews.length, 2);
  const fb = await fetch(base + '/api/admin/feedback', { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(fb.status, 200);
});
