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
  const nfHtml = await nf.text();
  assert.ok(nfHtml.includes('Back to Coroute'));
  assert.ok(nfHtml.includes('class="site-header"') && !nfHtml.includes('<!--#include'), '404 uses the shared shell');
  const apiNf = await fetch(base + '/api/nope');
  assert.ok([401, 404].includes(apiNf.status)); // unknown API paths never return HTML
  assert.match(apiNf.headers.get('content-type'), /json/);

  const robots = await (await fetch(base + '/robots.txt')).text();
  assert.ok(robots.includes(`Sitemap: ${base}/sitemap.xml`));
  const sm = await (await fetch(base + '/sitemap.xml')).text();
  for (const p of ['/', '/features', '/safety', '/how-it-works', '/about', '/get', '/privacy', '/terms']) {
    assert.ok(sm.includes(`<loc>${base}${p}</loc>`), `sitemap lists ${p}`);
  }
  assert.ok(!sm.includes('/download<'), 'the download redirect is not a page');

  for (const p of ['/og-image.png', '/favicon.svg', '/favicon-32.png', '/apple-touch-icon.png', '/site.webmanifest',
    '/assets/site.css', '/assets/site.js', '/assets/icons.svg', '/assets/topo.svg', '/fonts/barlow-condensed-700.woff2', '/fonts/barlow-400.woff2', '/fonts/barlow-600.woff2', '/fonts/OFL-Barlow.txt']) {
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
  // Every text file the site serves or assembles: pages, partials, template, CSS, JS, SVG.
  const files = [];
  const walk = (d) => {
    for (const f of fs.readdirSync(d, { withFileTypes: true })) {
      const full = path.join(d, f.name);
      if (f.isDirectory()) { if (!f.name.startsWith('.') && f.name !== 'fonts') walk(full); }
      else if (/\.(html|css|js|svg|webmanifest)$/.test(f.name)) files.push(full);
    }
  };
  walk(dir);
  assert.ok(files.filter((f) => f.endsWith('.html')).length >= 10);
  for (const full of files) {
    const f = path.relative(dir, full);
    // favicon.svg carries a signed content-credentials manifest (base64), so it is checked for dashes/emoji only.
    const text = fs.readFileSync(full, 'utf8').replace(/<metadata>[\s\S]*?<\/metadata>/, '');
    assert.ok(!/[\u2013\u2014]/.test(text), `${f}: en or em dash`);
    assert.ok(!/[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]/u.test(text), `${f}: emoji`);
    if (!f.endsWith('.svg')) assert.ok(!/\b(?:\d{1,3}\.){3}\d{1,3}\b/.test(text), `${f}: IPv4 address`); // SVG path data looks like dotted numbers
    assert.ok(!/oraclecloudapps|JWT_SECRET|ORACLE_PASSWORD/i.test(text), `${f}: secret or database host name`);
    // No third-party requests: no external scripts, stylesheets or fonts.
    assert.ok(!/<script[^>]+src="https?:/i.test(text) && !/<link[^>]+rel="(?:stylesheet|preconnect|preload)"[^>]+href="https?:/i.test(text) && !/url\(\s*["']?https?:/i.test(text), `${f}: third-party resource`);
  }
  // The convoy size on the download page comes from the gateway's configuration.
  const config = require('../src/config');
  const get = await (await fetch(base + '/get')).text();
  assert.ok(get.includes(`Up to ${config.maxConvoyRiders} riders`), 'max riders from config');
  assert.ok(!get.includes('__MAX_RIDERS__'));
  assert.ok(get.includes('href="/download"') && get.includes('href="/download/32bit"'), 'download page links both builds');
});

test('site pages: shared shell, unique head tags, active nav, no placeholders left', async () => {
  const pages = ['/', '/features', '/safety', '/how-it-works', '/about', '/get', '/privacy', '/terms'];
  const titles = new Set(), descs = new Set();
  for (const p of pages) {
    const r = await fetch(base + p);
    assert.equal(r.status, 200, p);
    assert.match(r.headers.get('content-type'), /text\/html/);
    const html = await r.text();
    assert.ok(!/__[A-Z_]+__/.test(html), `${p}: unreplaced placeholder`);
    assert.ok(!html.includes('<!--#include'), `${p}: unresolved include`);
    const title = (html.match(/<title>([^<]+)<\/title>/) || [])[1];
    assert.ok(title && !titles.has(title), `${p}: unique title`);
    titles.add(title);
    const desc = (html.match(/<meta name="description" content="([^"]+)">/) || [])[1];
    assert.ok(desc && !descs.has(desc), `${p}: unique description`);
    descs.add(desc);
    assert.ok(html.includes(`<link rel="canonical" href="${base}${p}">`), `${p}: canonical`);
    if (p === '/') continue; // the home page is rebuilt by its own task
    assert.ok(html.includes(`<meta property="og:url" content="${base}${p}">`), `${p}: og:url`);
    assert.ok(html.includes(`<meta property="og:image" content="${base}/og-image.png">`), `${p}: og:image`);
    assert.ok(html.includes('<meta name="twitter:card" content="summary_large_image">'), `${p}: twitter card`);
    assert.ok(html.includes('class="site-header"') && html.includes('class="site-footer"'), `${p}: shared shell`);
    assert.ok(html.includes('href="#main"') && html.includes('id="main"'), `${p}: skip link target`);
    assert.match(html, /\/assets\/site\.css\?v=[0-9a-f]{10}"/, `${p}: versioned stylesheet`);
    const key = p.slice(1);
    if (p === '/terms') {
      // Terms has no nav item of its own (it lives in the footer), so nothing is marked current.
      assert.ok(!/data-nav="[^"]+" aria-current="page"/.test(html), `${p}: no nav item is current`);
    } else {
      assert.ok(html.includes(`data-nav="${key}" aria-current="page"`), `${p}: active nav item`);
      // Count nav items only: the legal pages also mark their own tab in the Privacy / Terms switch.
      assert.equal((html.match(/data-nav="[^"]+" aria-current="page"/g) || []).length, 2, `${p}: only its own nav items are current`);
    }
    assert.ok(html.includes('&copy; 2026 Coroute') && html.includes('openstreetmap.org/copyright'), `${p}: footer`);
  }
  // .html aliases render the same page; the join page uses the shell too.
  assert.equal((await fetch(base + '/features.html')).status, 200);
  const join = await (await fetch(base + '/join/AB12CD')).text();
  assert.ok(join.includes('coroute://join/AB12CD') && join.includes('class="site-header"'));
});

test('partials, templates and raw page sources are never served directly', async () => {
  for (const p of ['/partials/header.html', '/partials/footer.html', '/partials/', '/partials', '/_template.html', '/%5Ftemplate.html',
    '/partials%2Fheader.html', '/%70artials/header.html', '/404.html', '/join.html', '/PARTIALS/header.html']) {
    const r = await fetch(base + p, { redirect: 'manual' });
    assert.equal(r.status, 404, p);
    const html = await r.text();
    assert.ok(!html.includes('<!--#include'), `${p}: raw template leaked`);
  }
  const api = await fetch(base + '/api/x.html');
  assert.match(api.headers.get('content-type'), /json/);
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

// ---------------------------------------------------------------------------
// Product pages (/features /safety /how-it-works /about /get): page-specific checks.
// Owned by the product pages task; other blocks above are unchanged.
// ---------------------------------------------------------------------------
test('product pages: shared page styles, real content anchors and honest safety wording', async () => {
  const css = await fetch(base + '/assets/pages.css');
  assert.equal(css.status, 200);
  assert.match(css.headers.get('content-type'), /text\/css/);
  const sprite = await fetch(base + '/assets/pages/icons.svg');
  assert.equal(sprite.status, 200);
  const pages = {
    '/features': ['id="before"', 'id="during"', 'id="after"', 'Up to ', 'riders can join one group'],
    '/safety': ['call 112', 'New in 3.15', 'does not replace', 'only when other Coroute groups are riding', 'id="false-alarms"'],
    '/how-it-works': ['id="create"', 'id="join"', 'id="ride"', 'class="pg-faq"', 'Allow all the time'],
    '/about': ['Built because riders needed it.', 'https://github.com/Santhosh-Guptha/coroute_app', 'href="/#feedback"'],
    '/get': ['Android 6.0 or newer', 'id="permissions"', 'href="/privacy"'],
  };
  for (const [p, needles] of Object.entries(pages)) {
    const html = await (await fetch(base + p)).text();
    assert.match(html, /\/assets\/pages\.css\?v=[0-9a-f]{10}"/, `${p}: pages.css linked`);
    for (const n of needles) assert.ok(html.includes(n), `${p}: missing "${n}"`);
    assert.equal((html.match(/<h1[\s>]/g) || []).length, 1, `${p}: exactly one h1`);
    // Never promise outcomes in safety copy.
    assert.ok(!/saves? lives|guaranteed response|guarantees? (?:help|a response)/i.test(html), `${p}: overpromising safety wording`);
    // Every internal link on the page resolves (downloads are redirects by design).
    const hrefs = [...new Set([...html.matchAll(/href="(\/[^"#]*)(?:#[^"]*)?"/g)].map((m) => m[1] || '/'))];
    for (const h of hrefs) {
      const r = await fetch(base + h, { redirect: 'manual' });
      if (h.startsWith('/download')) assert.equal(r.status, 302, `${p}: ${h}`);
      else assert.equal(r.status, 200, `${p}: ${h}`);
    }
  }
});

// ---------------------------------------------------------------------------
// Integration: cache busting, release text, legal consistency.
// ---------------------------------------------------------------------------
test('every /assets reference carries the hash of the file it points to; version text comes from package.json', async () => {
  const crypto = require('crypto');
  const fs = require('fs');
  const path = require('path');
  const assets = path.join(__dirname, '..', 'public', 'assets');
  const hashOf = (rel) => crypto.createHash('sha256').update(fs.readFileSync(path.join(assets, rel))).digest('hex').slice(0, 10);
  for (const p of ['/', '/features', '/safety', '/how-it-works', '/about', '/get', '/privacy', '/terms', '/join/ABC123', '/no-such-page']) {
    const html = await (await fetch(base + p)).text();
    const refs = [...html.matchAll(/\/assets\/([A-Za-z0-9_\-./]+\.[a-z0-9]+)(\?v=[^"'#)\s]*)?/g)];
    assert.ok(refs.length > 0, `${p}: has asset references`);
    for (const [, rel, q] of refs) assert.equal(q, `?v=${hashOf(rel)}`, `${p}: /assets/${rel} versioned by its own hash`);
  }
  const version = require('../package.json').version.replace(/\.0$/, '');
  assert.ok((await (await fetch(base + '/get')).text()).includes(`Version ${version}<`), '/get shows the package version');
  assert.ok((await (await fetch(base + '/about')).text()).includes(`<dd>${version}. `), '/about shows the package version');
});

test('terms agree with the privacy policy on who an SOS reaches; iOS wording is consistent', async () => {
  const terms = await (await fetch(base + '/terms')).text();
  assert.ok(!/reaches only the members of your convoy/.test(terms), 'terms no longer say SOS reaches only the convoy');
  assert.ok(terms.includes('riders of other groups who are already riding toward you on the same road'));
  for (const p of ['/', '/get', '/about', '/how-it-works']) {
    const html = await (await fetch(base + p)).text();
    assert.ok(html.includes('No iOS version yet.'), `${p}: iOS wording`);
    assert.ok(!/iOS version is planned|One is planned/.test(html), `${p}: no iOS promise`);
  }
});
