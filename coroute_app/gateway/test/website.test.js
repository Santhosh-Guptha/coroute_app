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
    '/assets/site.css', '/assets/site.js', '/assets/home.css', '/assets/home.js', '/assets/hero3d.js', '/assets/icons.svg', '/assets/topo.svg', '/assets/live.css', '/assets/live.js', '/fonts/manrope-latin.woff2', '/fonts/manrope-latin-ext.woff2', '/fonts/OFL-Manrope.txt']) {
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
  const dlIos = await fetch(base + '/download/ios', { redirect: 'manual' });
  assert.equal(dlIos.status, 302);
  assert.equal(dlIos.headers.get('location'), `${base}/get`); // no iOS link configured in tests
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
  // The convoy size on the download page is the largest paid plan's seats (catalog), not the server ceiling.
  const config = require('../src/config');
  const { siteMaxRiders } = require('../src/plan_pricing');
  const get = await (await fetch(base + '/get')).text();
  assert.ok(get.includes(`Up to ${siteMaxRiders(null, config.maxConvoyRiders)} riders`), 'max riders from the plan catalog');
  assert.ok(!get.includes('__MAX_RIDERS__'));
  assert.ok(get.includes('href="/download"') && get.includes('href="/download/32bit"'), 'download page links all Android builds');
  // The iOS button appears only when APP_STORE_URL / IOS_TESTFLIGHT_URL / IOS_IPA_URL is set (website_ios_blocks.test.js).
  assert.equal(get.includes('href="/download/ios"'), Boolean(config.appStoreUrl || config.iosTestFlightUrl || config.iosIpaUrl));
});

test('site pages: shared shell, unique head tags, active nav, no placeholders left', async () => {
  const pages = ['/', '/features', '/safety', '/how-it-works', '/leaderboard', '/about', '/get', '/privacy', '/terms'];
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
    '/about': ['Built because riders needed it.', 'Clear and open by design.', 'href="/#feedback"'],
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
    // 3.55: the iOS app is being built; without an iOS link every page says so the same way (no dates promised).
    assert.ok(html.includes('The iOS app is building now and coming soon.'), `${p}: iOS wording`);
    assert.ok(!/iOS version is planned|One is planned|No iOS version yet/.test(html), `${p}: one consistent iOS message`);
  }
});

// ---------------------------------------------------------------------------
// Website = information + live pricing + the 3.56 rider shop (/plans, /signin, /account, /receipt: see
// web_plans_355.test.js). Prices appear ONLY as rendered from the plan list (GET /api/membership/catalog,
// admin-editable): no price is written into any page. Coupons only on /plans; /checkout only pays an order an
// older app created (a plain visit goes to /plans).
// ---------------------------------------------------------------------------
test('pricing comes only from the catalog API: no hard-coded prices, coupons or admin UI on public pages', async () => {
  for (const p of ['/pricing-admin', '/pricing-admin.html']) assert.equal((await fetch(base + p, { redirect: 'manual' })).status, 404, p);
  const sm = await (await fetch(base + '/sitemap.xml')).text();
  assert.ok(!sm.includes('/checkout<') && !sm.includes('/pricing-admin'), 'checkout and admin pages are not listed');
  for (const p of ['/', '/features', '/how-it-works', '/safety', '/about', '/get', '/privacy', '/terms', '/no-such-page']) {
    const html = await (await fetch(base + p)).text();
    assert.ok(!/href="\/checkout|href="\/pricing-admin/.test(html), `${p}: links to checkout or admin`);
    assert.ok(!/Choose Pro|Plans &amp; Pay|hm-plan\b|id="plans"/.test(html), `${p}: old plan section or CTA`);
    assert.ok(!/coupon/i.test(html), `${p}: coupon UI (coupons live on /plans only)`);
    assert.ok(!html.includes('/api/subscription/config') && !html.includes('/api/create-order'), `${p}: order calls`);
    if (p !== '/terms' && p !== '/privacy') assert.ok(!/&#8377;\s?\d|\u20B9\s?\d|Rs\.? ?\d|INR ?\d|\d+\s*(?:\/|per) ?month/i.test(html), `${p}: hard-coded price`);
  }
  const home = await (await fetch(base + '/')).text();
  assert.ok(home.includes('href="/get"') && home.includes('Get the app'));
  // The pricing section is an empty frame that home.js fills from the catalog.
  const sec = home.slice(home.indexOf('id="pricing"'), home.indexOf('</section>', home.indexOf('id="pricing"')));
  assert.ok(sec.includes('data-pricing') && sec.includes('id="pricing-list"'), 'home: pricing frame');
  assert.ok(!/\d/.test(sec.replace(/<[^>]+>/g, '')), 'home: no number written into the pricing section');
  assert.ok(sec.includes('Join a ride you are invited to: Free.'), 'home: joining is free');
  assert.ok(/href="\/plans" data-nav="plans"/.test(home), 'header links to the plans page');
  assert.ok(/href="\/account" data-nav="account"/.test(home), 'header links to the account');
  const fs = require('fs');
  const path = require('path');
  const js = fs.readFileSync(path.join(__dirname, '..', 'public', 'assets', 'home.js'), 'utf8');
  const block = js.slice(js.indexOf('/* ---------- Pricing'), js.indexOf('/* ---------- end pricing'));
  assert.ok(block.length > 1000, 'home.js has the pricing block');
  assert.ok(block.includes("getJSON('/api/membership/catalog')"), 'pricing: read from the catalog');
  assert.ok(!/innerHTML/.test(js), 'home.js: no innerHTML');
  assert.ok(!/(?:\\u20B9|\u20B9|&#8377;)'?\s*\+?\s*'?\d/.test(block) && !/(?:price|Price|Inr)\w*\s*[:=]\s*[1-9]/.test(block), 'pricing: no price constants in the script');
  // The catalog the page reads is public and carries prices and seats.
  const cat = await (await fetch(base + '/api/membership/catalog')).json();
  assert.ok(cat.categories && typeof cat.categories === 'object');
  for (const c of Object.values(cat.categories)) assert.equal(typeof c.monthlyPriceInr, 'number');
});

test('checkout page: older app orders only (signed link), noindex, return link to the app; a plain visit goes to /plans', async () => {
  const plain = await fetch(base + '/checkout', { redirect: 'manual' });
  assert.equal(plain.status, 302);
  assert.equal(plain.headers.get('location'), '/plans');
  const r = await fetch(base + '/checkout.html?order=x&t=y&e=1');
  assert.equal(r.status, 200);
  const html = await r.text();
  assert.ok(html.includes('<meta name="robots" content="noindex, nofollow">'));
  assert.ok(html.includes('Choose a plan on the plans page') && html.includes('href="/plans"'), 'fallback for a link that is not valid any more');
  assert.ok(html.includes('href="coroute://subscription"') && html.includes('Return to the CoRoute app'));
  const js = require('fs').readFileSync(require('path').join(__dirname, '..', 'public', 'assets', 'checkout.js'), 'utf8');
  assert.ok(js.includes("'/api/checkout/order/'") && js.includes("'&e='"), 'loads the app order with its signed expiry');
  assert.ok(js.includes('upi: true, card: false'), 'UPI only');
  for (const gone of ['plan-card', 'rider-name', 'coupon', 'test-creds', 'offer-banner', '/api/create-order', '/api/subscription/offers', '/api/subscription/config', 'pricing-admin', 'Test Card']) {
    assert.ok(!(html + js).toLowerCase().includes(gone.toLowerCase()), `checkout still has ${gone}`);
  }
});

test('website index contains community stories container and small square checkbox consent', async () => {
  const r = await fetch(base + '/');
  const html = await r.text();
  assert.equal(r.status, 200);
  assert.ok(html.includes('id="community-stories-container"'), 'has community stories container');
  assert.ok(html.includes('type="checkbox"') && html.includes('id="fb-consent"'), 'has small square checkbox consent');
  assert.ok(!html.includes('paste url') && !html.includes('paste-url'), 'no paste url option');

  // Rider stories come from the moderated feed only. The server may answer with { ok, stories } or a bare array,
  // and either may be empty: the page never fills the gap with sample stories.
  const api = await fetch(base + '/api/public/community-stories?limit=3');
  assert.equal(api.status, 200);
  const aj = await api.json();
  assert.ok(Array.isArray(aj.stories), '/api/public/community-stories returns a stories list');
  const sr = await fetch(base + '/community-stories');
  assert.equal(sr.status, 200);
  const sj = await sr.json();
  assert.ok(Array.isArray(sj) || Array.isArray(sj.stories), '/community-stories returns a list');
});

// ---------------------------------------------------------------------------
// Homepage for long-distance group riders: safe, secure, memorable, real reviews only.
// ---------------------------------------------------------------------------
test('home page: touring pitch, safe / secure / memorable sections, moderated reviews, no invented proof', async () => {
  const html = await (await fetch(base + '/')).text();
  for (const id of ['features', 'long-haul', 'safe', 'secure', 'memorable', 'how', 'pricing', 'numbers', 'reviews', 'faq', 'feedback']) {
    assert.ok(html.includes(`id="${id}"`), `home: section #${id}`);
  }
  assert.equal((html.match(/<h1[\s>]/g) || []).length, 1, 'home: exactly one h1');
  assert.ok(html.includes('href="/get"') && html.includes('Download for Android') && html.includes('href="/how-it-works"'), 'home: primary and secondary CTA');
  assert.ok(/<meta name="description" content="[^"]*group motorcycle touring safety app/i.test(html), 'home: description targets touring riders');
  assert.ok(html.includes('<meta property="og:title"') && html.includes('<meta name="twitter:title"'), 'home: social titles');
  assert.ok(html.includes('approved') || html.includes('reads each one'), 'home: explains that stories are moderated');
  assert.ok(html.includes('does not replace them') && html.includes('call 112'), 'home: honest safety limits');
  // Every image on the page is local; nothing is loaded from another site.
  assert.ok(!/<img[^>]+src="https?:/i.test(html), 'home: third-party image');
  // No internal infrastructure jargon in user-facing copy, and no hard-coded rider counts or ratings.
  for (const p of ['/', '/features', '/safety', '/how-it-works', '/about', '/get']) {
    const page = await (await fetch(base + p)).text();
    assert.ok(!/Oracle|dual-node|WebSocket|SODA|BLE mesh|IMU\b/.test(page.replace(/<script[\s\S]*?<\/script>/g, '')), `${p}: infrastructure jargon`);
    assert.ok(!/\b\d[\d,.]*\+?\s*(?:riders trust|happy riders|five-star|5-star reviews)/i.test(page), `${p}: invented social proof`);
  }

  // The reviews script renders rider text safely and never invents stories.
  const fs = require('fs');
  const path = require('path');
  const js = fs.readFileSync(path.join(__dirname, '..', 'public', 'assets', 'site.js'), 'utf8');
  const reviews = js.slice(js.indexOf('Rider reviews'), js.indexOf('Theme toggle'));
  assert.ok(reviews.length > 1000, 'site.js has the reviews block');
  assert.ok(reviews.includes("'/api/public/community-stories?limit='") && reviews.includes("'/community-stories'"), 'reviews: API with fallback');
  assert.ok(!/innerHTML/.test(reviews), 'reviews: no innerHTML');
  assert.ok(reviews.includes('Rider stories appear here after a ride and a moderation check'), 'reviews: honest empty state');
  assert.ok(!/Arjun|Priya|Himalayan Pass|fallbackStories/.test(js), 'reviews: no hard-coded sample stories');
  assert.ok(reviews.includes("img.loading = 'lazy'") && reviews.includes('img.alt'), 'reviews: lazy photos with alt text');
  // The script must parse: a syntax error would silently break the menu, theme toggle and forms.
  assert.doesNotThrow(() => new Function(js), 'site.js parses');
});

test('home page: "CoRoute in numbers" is hidden until real counts load; stories use the shared templates', async () => {
  const html = await (await fetch(base + '/')).text();
  const m = html.match(/<section[^>]*id="numbers"[^>]*>/);
  assert.ok(m, 'home: section #numbers');
  assert.ok(/\bhidden\b/.test(m[0]) && m[0].includes('data-usage-stats'), 'numbers: hidden by default, filled by site.js');
  assert.ok(html.includes('id="usage-stats-list"'), 'numbers: list container');
  // No number is written into the page itself: they only come from the API.
  const section = html.slice(html.indexOf('id="numbers"'), html.indexOf('<!-- /numbers -->'));
  assert.ok(section.length > 200, 'numbers: section found');
  assert.ok(!/\d{2,}/.test(section.replace(/<[^>]+>/g, '')), 'numbers: no hard-coded counts');
  const fs = require('fs');
  const path = require('path');
  const js = fs.readFileSync(path.join(__dirname, '..', 'public', 'assets', 'site.js'), 'utf8');
  const usage = js.slice(js.indexOf('CoRoute in numbers'), js.indexOf('Theme toggle'));
  assert.ok(usage.includes("'/api/public/usage-stats'") && usage.includes("'/api/public/community-stats'"), 'numbers: API with fallback');
  assert.ok(usage.includes('setInterval(loadUsage, 60000)') && usage.includes('requestAnimationFrame'), 'numbers: live refresh every 60 s with counters');
  assert.ok(!/innerHTML/.test(usage), 'numbers: no innerHTML');
  const { TEMPLATE_IDS } = require('../src/trip_reviews');
  for (const id of TEMPLATE_IDS) assert.ok(js.includes(`'${id}'`), `site.js knows template ${id}`);
  const css = fs.readFileSync(path.join(__dirname, '..', 'public', 'assets', 'home.css'), 'utf8');
  for (const id of ['photo-left', 'photo-top', 'quote-card']) assert.ok(css.includes(`.rv-card--${id}`), `home.css styles ${id}`);
  assert.ok(css.includes('.rv-card__gallery'), 'home.css styles the gallery');
});
