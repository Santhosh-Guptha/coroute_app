'use strict';
/**
 * Live emergency link pages (3.16, item 17): public/live.html, public/live_expired.html, assets/live.css, assets/live.js,
 * and the privacy and safety copy for the 3.16 items. Owned by WP-WEB.
 *
 * The pages are rendered here through the same include step pages.js uses, with sample values for the placeholders
 * app.js fills, so the content checks do not depend on the /e/:token route (WP-GW). The last test goes through the real
 * server when that route and the live-link API exist, and reports what it skipped otherwise.
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { boot } = require('./_helpers');

const PUBLIC = path.join(__dirname, '..', 'public');
const read = (f) => fs.readFileSync(path.join(PUBLIC, f), 'utf8');

/** Mirrors pages.js: resolve the header/footer includes, then fill the placeholders app.js provides. */
function render(file, vars) {
  let html = read(file).replace(/<!--#include ([a-z0-9-]+)-->/g, (m, name) => read(path.join('partials', `${name}.html`)));
  for (const [k, v] of Object.entries(vars)) html = html.replaceAll(k, v);
  return html;
}
const SAMPLE = {
  __ORIGIN__: 'https://coroute.test', __MAX_RIDERS__: '20', __ASSET_V__: '0123456789', __APP_VERSION__: '3.16',
  __RIDER__: 'Kiran', __LAT__: '17.38500', __LNG__: '78.48670',
  __AT__: '2026-10-09T09:30:00.000Z', __EXPIRES__: '2026-10-09T10:00:00.000Z',
};
const BAD = /[–—]|[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]/u;

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('live page: shell, rider data, calls to action, private by design', () => {
  const html = render('live.html', SAMPLE);
  assert.ok(html.includes('class="site-header"') && html.includes('class="site-footer"'), 'shared shell');
  assert.ok(!html.includes('<!--#include'), 'includes resolved');
  assert.ok(!/__[A-Z_]+__/.test(html), 'no placeholder left');
  assert.ok(html.includes('data-page="live"'));
  assert.ok(html.includes('<meta name="robots" content="noindex, nofollow">'), 'noindex');
  assert.ok(html.includes('<meta name="referrer" content="no-referrer">'), 'no referrer');
  assert.ok(html.includes('<h1 id="live-title">Rider emergency</h1>'));
  assert.ok(html.includes('<strong class="live__name">Kiran</strong> raised an SOS in Coroute and shared this link with you.'));
  assert.ok(html.includes('<div class="live-map" data-lat="17.38500" data-lng="78.48670" data-at="2026-10-09T09:30:00.000Z"'), 'map data attributes');
  assert.ok(html.includes('data-expires="2026-10-09T10:00:00.000Z"'));
  assert.ok(html.includes('<span data-pos>17.38500, 78.48670</span>'), 'last position line');
  assert.ok(html.includes('<time datetime="2026-10-09T09:30:00.000Z" data-updated>'), 'updated time');
  assert.ok(html.includes('Link valid until'));
  assert.ok(html.includes('href="tel:112"') && html.includes('>Call 112</a>'), 'Call 112 tel link');
  assert.match(html, /<a class="btn btn--secondary btn--block" href="https:\/\/www\.google\.com\/maps\/dir\/\?api=1&amp;destination=17\.38500,78\.48670" rel="noreferrer noopener" target="_blank" data-maps>Open in Google Maps<\/a>/, 'Google Maps link with noreferrer');
  assert.ok(html.includes('What to do') && html.includes('Stay on the line'), 'what to do');
  assert.ok(html.includes('openstreetmap.org/copyright') && html.includes('OpenStreetMap contributors'), 'OSM attribution');
  assert.ok(html.includes('/assets/live.css') && html.includes('/assets/live.js'), 'own assets');
  // Private: no site.js (its page-view beacon would post the token in the path), no third-party scripts or styles.
  assert.ok(!html.includes('/assets/site.js'), 'site.js (page-view beacon) is not loaded on the live page');
  assert.ok(!/<script[^>]+src="https?:/i.test(html) && !/<link[^>]+href="https?:/i.test(html), 'no third-party script or stylesheet');
  assert.ok(!BAD.test(html), 'no dashes or emoji');
  assert.ok(!/saves? lives|guaranteed/i.test(html), 'no promises');
  assert.equal((html.match(/<h1[\s>]/g) || []).length, 1, 'one h1');
});

test('expired page: plain copy, call 112, same shell and privacy rules', () => {
  const html = render('live_expired.html', SAMPLE);
  assert.ok(html.includes('class="site-header"') && !html.includes('<!--#include'));
  assert.ok(html.includes('<h1 id="live-title">This link has expired</h1>'));
  assert.ok(html.includes('Live emergency links in Coroute last 30 minutes or until the rider\'s group closes the alert.'));
  assert.ok(html.includes('If someone is in danger, call 112.'));
  assert.ok(html.includes('href="tel:112"'));
  assert.ok(html.includes('href="/get"'), 'download CTA');
  assert.ok(html.includes('<meta name="robots" content="noindex, nofollow">') && html.includes('<meta name="referrer" content="no-referrer">'));
  assert.ok(!html.includes('/assets/site.js'), 'no page-view beacon on the expired page either');
  assert.ok(!/__[A-Z_]+__/.test(html) && !BAD.test(html));
  // Different head tags from the live page.
  const live = render('live.html', SAMPLE);
  const title = (h) => (h.match(/<title>([^<]+)<\/title>/) || [])[1];
  assert.ok(title(html) && title(live) && title(html) !== title(live));
});

test('live.js and live.css: served, versioned, no analytics, documented tile use', async () => {
  for (const [p, type] of [['/assets/live.css', /text\/css/], ['/assets/live.js', /javascript/]]) {
    const r = await fetch(t.origin + p);
    assert.equal(r.status, 200, p);
    assert.match(r.headers.get('content-type'), type, p);
  }
  const js = read('assets/live.js');
  assert.ok(!js.includes('/api/pv') && !js.includes('sendBeacon'), 'no page-view beacon');
  assert.ok(!js.includes('localStorage') && !js.includes('document.cookie'), 'no storage, no cookies');
  assert.ok(js.includes("'/api/public/live/'"), 'polls the public JSON endpoint');
  assert.ok(js.includes('REFRESH_MS = 30000'), '30 second refresh');
  assert.ok(js.includes('410'), 'handles the expired status');
  assert.ok(js.includes('https://tile.openstreetmap.org/') && js.includes("referrerPolicy = 'no-referrer'"), 'OSM tiles without a referrer');
  assert.ok(!/[–—]/.test(js) && !/[–—]/.test(read('assets/live.css')));
  // The only external hosts the page can contact: OSM tiles (map images) and the Google Maps link the viewer taps.
  const hosts = new Set([...js.matchAll(/https:\/\/([a-z0-9.-]+)/g)].map((m) => m[1]));
  assert.deepEqual([...hosts].sort(), ['tile.openstreetmap.org', 'www.google.com']);
});

test('privacy page documents live links, weather, the hospital lookup and tiles on the phone; safety page mentions 3.16', async () => {
  const privacy = await (await fetch(t.origin + '/privacy')).text();
  assert.equal((await fetch(t.origin + '/privacy')).status, 200);
  for (const id of ['live-links', 'weather', 'nearest-hospital', 'offline-maps', 'ride-alerts', 'hard-braking', 'medical-id-lock-screen', 'bluetooth']) {
    assert.ok(privacy.includes(`id="${id}"`), `privacy section ${id}`);
    assert.ok(privacy.includes(`href="#${id}"`), `privacy toc entry ${id}`);
  }
  for (const s of ['Live emergency links', 'first name', '30 minutes', 'Open-Meteo', 'Weather data by Open-Meteo.com', 'nearest hospital',
    'OpenStreetMap', 'Save route map', 'never uploaded', 'off until you turn it on', 'does not use Bluetooth', 'rate limited']) {
    assert.ok(privacy.includes(s), `privacy mentions "${s}"`);
  }
  const safety = await (await fetch(t.origin + '/safety')).text();
  assert.ok(safety.includes('New in 3.16') && safety.includes('id="new-316"'), 'safety page: New in 3.16');
  assert.ok(safety.includes('live emergency link') && safety.includes('nearest hospital'), 'safety page: live link and hospital');
  assert.ok(!/saves? lives|guaranteed response|guarantees? (?:help|a response)/i.test(safety));
  for (const h of ['/privacy', '/safety']) {
    const html = h === '/privacy' ? privacy : safety;
    assert.ok(!BAD.test(html), `${h}: no dashes or emoji`);
    assert.ok(!/__[A-Z_]+__/.test(html), `${h}: placeholders`);
  }
});

test('live link through the server: /e/<token> page, JSON and expiry (skips the parts WP-GW has not landed yet)', async (ctx) => {
  const fakeToken = 'A'.repeat(32);
  // Malformed tokens are never a live page.
  const bad = await fetch(`${t.origin}/e/not-a-token`, { redirect: 'manual' });
  assert.ok([404, 410].includes(bad.status));
  const dead = await fetch(`${t.origin}/e/${fakeToken}`, { redirect: 'manual' });
  if (dead.status === 404) { ctx.diagnostic('GET /e/:token not wired yet (404); server checks skipped'); return; }
  assert.equal(dead.status, 410, 'unknown token answers 410 with the expired page');
  const deadHtml = await dead.text();
  assert.ok(deadHtml.includes('This link has expired') && deadHtml.includes('class="site-header"') && !deadHtml.includes('<!--#include'));
  assert.ok(!/__[A-Z_]+__/.test(deadHtml));
  assert.match(dead.headers.get('cache-control') || '', /no-store/);
  assert.match(dead.headers.get('x-robots-tag') || '', /noindex/);
  const deadJson = await fetch(`${t.origin}/api/public/live/${fakeToken}`);
  assert.equal(deadJson.status, 410);

  // A real link: owner raises an SOS, creates the link, the page shows the first name and position.
  const lead = await t.register('Live Lead', 'livelead@coroute.test');
  const rider = await t.register('Kiran Rao', 'liverider@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'Live ride' }, lead.token)).json;
  await t.api('POST', '/convoys/join', { code: c.joinCode }, rider.token);
  const wl = await t.joinRoom(lead.token, c.groupId);
  const wr = await t.joinRoom(rider.token, c.groupId);
  wr.sendJson({ type: 'SOS', lat: 17.385, lng: 78.4867, alertType: 'CRASH_OR_EMERGENCY', clientId: 'live-1' });
  const alert = (await wl.next((m) => m.type === 'ALERT')).alert;
  const made = await t.api('POST', `/convoys/${c.groupId}/alerts/${alert.alertId}/live-link`, {}, rider.token);
  if (made.status === 404 && !made.json.token) { ctx.diagnostic('live-link API not wired yet (404); link checks skipped'); wl.close(); wr.close(); return; }
  assert.equal(made.status, 200, JSON.stringify(made.json));
  assert.match(made.json.token, /^[A-Za-z0-9_-]{32}$/);
  assert.equal(made.json.url, `${t.origin}/e/${made.json.token}`);

  const page = await fetch(made.json.url);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('cache-control') || '', /no-store/);
  assert.match(page.headers.get('referrer-policy') || '', /no-referrer/);
  assert.match(page.headers.get('x-robots-tag') || '', /noindex/);
  const html = await page.text();
  assert.ok(html.includes('<strong class="live__name">Kiran</strong>'), 'first name only');
  assert.ok(!html.includes('Kiran Rao') && !html.includes('livelead') && !html.includes('+9198765'), 'no full name, e-mail or phone');
  assert.ok(html.includes('data-lat="17.38500" data-lng="78.48670"'), 'position at 5 decimals');
  assert.ok(!/__[A-Z_]+__/.test(html) && !html.includes('<!--#include'));
  assert.ok(html.includes('href="tel:112"'));

  const json = await (await fetch(`${t.origin}/api/public/live/${made.json.token}`)).json();
  assert.equal(json.firstName, 'Kiran');
  assert.equal(json.active, true);
  assert.deepEqual(Object.keys(json).sort(), ['active', 'at', 'expiresAt', 'firstName', 'lat', 'lng']);

  // Revoked: the page becomes the expired page and the JSON answers 410, which live.js turns into the expired state.
  assert.equal((await t.api('DELETE', `/convoys/${c.groupId}/alerts/${alert.alertId}/live-link`, undefined, rider.token)).status, 200);
  const gone = await fetch(made.json.url);
  assert.equal(gone.status, 410);
  assert.ok((await gone.text()).includes('This link has expired'));
  assert.equal((await fetch(`${t.origin}/api/public/live/${made.json.token}`)).status, 410);
  wl.close(); wr.close();
});
