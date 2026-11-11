'use strict';
/**
 * Website revamp: live 3D hero, live numbers, "riding right now" and pricing read from the catalog.
 * - GET /api/public/live-now: aggregate only, rounded down to tens, honest zero, cached.
 * - home.js pricing block run against a small fake DOM: renders only what the catalog says.
 * - The 3D scene is lazy, low-power and has a static fallback; performance budgets for the homepage.
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { publicLiveNow, countLive } = require('../src/public_live');

const PUB = path.join(__dirname, '..', 'public');
const read = (rel) => fs.readFileSync(path.join(PUB, rel), 'utf8');

let gw, base;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });

/* ---------- live-now ---------- */
const fakeConvoys = (rooms) => ({
  rooms: new Map(rooms.map((r, i) => [`G${i}`, {
    meta: { tripStatus: r.status || 'STARTED' },
    riders: new Map(r.riders.map((x, j) => [`U${i}-${j}`, { userId: `U${i}-${j}`, name: 'Secret Name', lat: 12.9, lng: 77.6, ...x }])),
  }])),
});

test('live-now counts fresh riders on started or paused rides only', () => {
  const now = Date.now();
  const fresh = { lastSeenEpochMs: now - 60000 };
  const conv = fakeConvoys([
    { riders: [fresh, fresh, fresh] },
    { status: 'PAUSED', riders: [fresh, { ...fresh, presence: 'APP_CLOSED' }] },
    { status: 'ENDED', riders: [fresh, fresh] },
    { status: 'CREATED', riders: [fresh] },
    { riders: [{ lastSeenEpochMs: now - 11 * 60000 }] },
  ]);
  assert.deepEqual(countLive(conv, now), { riders: 4, groups: 2 });
});

test('live-now is rounded down to tens, never names anyone and says 0 when quiet', () => {
  const now = Date.now();
  const fresh = { lastSeenEpochMs: now - 1000 };
  const quiet = publicLiveNow(fakeConvoys([{ riders: [fresh, fresh, fresh, fresh, fresh, fresh, fresh, fresh, fresh] }]), now);
  assert.equal(quiet.ridersOnRide, 0, '9 riders read as 0');
  assert.equal(quiet.groupsRiding, 0, 'no group count below the threshold');
  const busy = publicLiveNow(fakeConvoys([
    { riders: Array(7).fill(fresh) }, { riders: Array(6).fill(fresh) }, { riders: Array(4).fill(fresh) }, { riders: Array(6).fill(fresh) },
  ]), now);
  assert.equal(busy.ridersOnRide, 20, '23 riders read as 20');
  assert.equal(busy.groupsRiding, 4);
  assert.equal(busy.approximate, true);
  assert.deepEqual(Object.keys(busy).sort(), ['approximate', 'groupsRiding', 'ok', 'ridersOnRide', 'threshold', 'updatedAt']);
  assert.ok(!/Secret|U0-|12\.9|77\.6|G0/.test(JSON.stringify(busy)), 'no names, ids or positions');
  assert.equal(publicLiveNow(null, now).ridersOnRide, 0);
});

test('GET /api/public/live-now: public, cached 30 s, honest zero on an idle server', async () => {
  const r = await fetch(base + '/api/public/live-now');
  assert.equal(r.status, 200);
  assert.match(r.headers.get('cache-control') || '', /max-age=30/);
  const j = await r.json();
  assert.equal(j.ok, true);
  assert.equal(j.ridersOnRide, 0);
  assert.equal(j.groupsRiding, 0);
  assert.equal(typeof j.updatedAt, 'number');
  // Cached: a ride that starts now is not visible until the cache expires.
  const fresh = { lastSeenEpochMs: Date.now() };
  gw.convoys.rooms.set('LIVE-TEST', { meta: { tripStatus: 'STARTED' }, riders: new Map(Array.from({ length: 12 }, (_, i) => [`u${i}`, { ...fresh }])) });
  try {
    const again = await (await fetch(base + '/api/public/live-now')).json();
    assert.equal(again.updatedAt, j.updatedAt);
    assert.equal(again.ridersOnRide, 0);
  } finally {
    gw.convoys.rooms.delete('LIVE-TEST');
  }
});

/* ---------- pricing, rendered by home.js from the catalog ---------- */
class El {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase(); this.children = []; this.attrs = {}; this.className = ''; this.hidden = false; this._text = '';
    const self = this;
    this.classList = {
      add(c) { if (!self.classList.contains(c)) self.className = `${self.className} ${c}`.trim(); },
      contains(c) { return self.className.split(/\s+/).includes(c); },
    };
  }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this.children = []; this._text = String(v); }
  appendChild(c) { this.children.push(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener() {}
  all(pred, out = []) { for (const c of this.children) { if (pred(c)) out.push(c); c.all(pred, out); } return out; }
  byClass(c) { return this.all((e) => e.classList.contains(c)); }
}
const flush = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

async function runHome(routes) {
  const list = new El('div');
  const calls = [];
  const document = {
    hidden: false, readyState: 'loading',
    getElementById: (id) => (id === 'pricing-list' ? list : null),
    querySelector: () => null,
    createElement: (t) => new El(t),
    createElementNS: (ns, t) => new El(t),
    addEventListener() {},
  };
  const window = {
    fetch: async (url) => {
      calls.push(url);
      if (!(url in routes)) return { ok: false, status: 404, json: async () => ({}) };
      const v = routes[url];
      if (v instanceof Error) throw v;
      return { ok: true, status: 200, json: async () => v };
    },
    addEventListener() {}, setInterval() {}, setTimeout() {},
  };
  // eslint-disable-next-line no-new-func
  new Function('document', 'window', read('assets/home.js'))(document, window);
  await flush();
  const cards = list.all((e) => e.tagName === 'ARTICLE');
  return { list, calls, cards, text: (c) => ({
    name: c.byClass('px-card__name')[0].textContent,
    seats: c.byClass('px-card__seats')[0].textContent,
    amount: c.byClass('px-card__amount')[0].textContent,
    per: c.byClass('px-card__per')[0].textContent,
  }) };
}

const CATALOG = {
  categories: {
    group_large: { id: 'group_large', name: 'Large Group (7–12)', monthlyPriceInr: 99, capacity: 12, minCapacity: 7, maxCapacity: 12, billingPeriodDays: 30, features: ['convoy_tracking', 'ptt_intercom'] },
    community: { id: 'community', name: 'Community', monthlyPriceInr: 0, capacity: 1, minCapacity: 1, maxCapacity: 1, purchasable: false, features: ['essential_safety', 'some_new_thing', 'Offline maps and re-routing'] },
    group_small: { id: 'group_small', name: 'Small Group (2–6)', monthlyPriceInr: 49, capacity: 6, minCapacity: 2, maxCapacity: 6, billingPeriodDays: 30, description: 'For small riding groups.' },
    retired: { id: 'retired', name: 'Old', monthlyPriceInr: 5, isActive: false },
    broken: { id: 'broken', name: 'No price' },
  },
  keyId: 'rzp_test_x', mode: 'test',
};

test('pricing cards show exactly what the catalog says, cheapest first', async () => {
  const { list, calls, cards, text } = await runHome({ '/api/membership/catalog': CATALOG });
  assert.deepEqual(calls, ['/api/membership/catalog']);
  assert.equal(list.getAttribute('data-state'), 'loaded');
  assert.deepEqual(cards.map((c) => c.getAttribute('data-plan')), ['community', 'group_small', 'group_large']);
  assert.deepEqual(cards.map(text), [
    { name: 'Community', seats: 'Solo rider', amount: 'Free', per: 'for solo riders, forever' },
    { name: 'Small Group', seats: '2 to 6 riders, host included', amount: '₹49', per: 'per month' },
    { name: 'Large Group', seats: '7 to 12 riders, host included', amount: '₹99', per: 'per month' },
  ]);
  assert.ok(cards[1].classList.contains('px-card--accent'), 'the first group plan is highlighted');
  assert.ok(cards[0].textContent.includes('Crash detection and SOS') && cards[0].textContent.includes('Some new thing') && cards[0].textContent.includes('Offline maps and re-routing'), 'feature labels: keys mapped or humanised, sentences kept');
  assert.ok(cards[1].textContent.includes('For small riding groups.'));
  assert.ok(!list.textContent.includes('rzp_') && !list.textContent.includes('Old'), 'no keys, no retired plans');
  // An admin price change shows up as is.
  const edited = JSON.parse(JSON.stringify(CATALOG));
  edited.categories.group_small.monthlyPriceInr = 59;
  const again = await runHome({ '/api/membership/catalog': edited });
  assert.equal(again.text(again.cards[1]).amount, '₹59');
});

test('pricing: no catalog means no prices, only a pointer to the plans page', async () => {
  for (const routes of [{}, { '/api/membership/catalog': new Error('down') }, { '/api/membership/catalog': { categories: {} } }, { '/api/membership/catalog': { nope: 1 } }]) {
    const { list, cards } = await runHome(routes);
    assert.equal(cards.length, 0);
    assert.ok(['error', 'empty'].includes(list.getAttribute('data-state')));
    assert.ok(/plans page/.test(list.textContent)); // 3.56: plans are bought on /plans
    assert.ok(!/\d/.test(list.textContent), 'no number shown');
  }
});

/* ---------- 3D hero and budgets ---------- */
test('hero (3.56): real app screens in phone frames, static backdrop, responsive AVIF/WebP with PNG fallback', async () => {
  const html = await (await fetch(base + '/')).text();
  const start = html.indexOf('<section class="hx hx--phones"');
  assert.ok(start > 0, 'hero section');
  const hero = html.slice(start, html.indexOf('</section>', start));
  assert.ok(hero.includes('class="hx__poster"'), 'static drawing is in the page');
  assert.ok(!hero.includes('data-hero3d'), 'no 3D scene behind the phones');
  assert.match(hero, /<h1 class="hx__title" id="hero-title">Ride Together\. <span>Stay Safe\.<\/span><\/h1>/, 'the motto is the headline');
  const pics = hero.match(/<picture class="dev__shot">[\s\S]*?<\/picture>/g) || [];
  assert.equal(pics.length, 3, 'three phone screens');
  for (const pic of pics) {
    assert.match(pic, /<source type="image\/avif" srcset="\/assets\/screens\/[a-z]+-320\.avif\?v=[0-9a-f]{10} 320w, [^"]+ 636w" sizes="[^"]+">/, 'AVIF srcset');
    assert.match(pic, /<source type="image\/webp" srcset="[^"]+webp[^"]+"/, 'WebP srcset');
    assert.match(pic, /<img src="\/assets\/screens\/[a-z]+-480\.png\?v=[0-9a-f]{10}" width="636" height="1386" alt="CoRoute [^"]{20,}"/, 'PNG fallback with size and alt text');
  }
  assert.ok(!/<script[^>]+hero3d/.test(html), 'no scene script');
  for (const f of ['crash-320.avif', 'crash-636.webp', 'crash-480.png']) {
    const r = await fetch(base + '/assets/screens/' + f);
    assert.equal(r.status, 200, f);
    assert.equal(r.headers.get('content-type').split(';')[0], { avif: 'image/avif', webp: 'image/webp', png: 'image/png' }[f.split('.').pop()], f);
  }
  const scene = read('assets/hero3d.js');
  assert.doesNotThrow(() => new Function(scene), 'hero3d.js still parses (kept for later use)');
});

test('screens gallery: accessible carousel, lazy images, arrows from site.js', async () => {
  const html = await (await fetch(base + '/')).text();
  const start = html.indexOf('id="screens"');
  const sec = html.slice(start, html.indexOf('</section>', start));
  assert.ok(/data-gallery role="region" aria-roledescription="carousel" aria-label="[^"]+"/.test(sec), 'carousel region');
  const slides = sec.match(/class="gal__slide" role="group" aria-roledescription="slide" aria-label="\d+ of \d+: [^"]+"/g) || [];
  assert.ok(slides.length >= 8, 'at least eight labelled slides');
  assert.ok(sec.includes('id="gallery-track" tabindex="0"'), 'track is keyboard scrollable');
  assert.ok(/data-gallery-nav hidden/.test(sec) && sec.includes('aria-controls="gallery-track"') && sec.includes('aria-label="Next screens"'), 'arrow buttons hidden until site.js runs');
  const imgs = sec.match(/<img [^>]+>/g) || [];
  assert.equal(imgs.length, slides.length);
  for (const img of imgs) assert.ok(img.includes('loading="lazy"') && /alt="CoRoute [^"]+"/.test(img), 'lazy with alt text');
  const js = read('assets/site.js');
  assert.ok(js.includes("querySelectorAll('[data-gallery]')") && js.includes('scrollBy') && js.includes('prev.disabled'), 'site.js wires the arrows');
});

test('homepage budgets: JS at most 250 KB gzip with the 3D scene, CSS at most 60 KB gzip', async () => {
  const gz = (rel) => zlib.gzipSync(fs.readFileSync(path.join(PUB, rel)), { level: 9 }).length;
  const html = await (await fetch(base + '/')).text();
  const js = [...html.matchAll(/<script[^>]+src="\/assets\/([^"?]+\.js)/g)].map((m) => m[1]);
  assert.deepEqual(js.sort(), ['board.js', 'home.js', 'site.js', 'theme-init.js']); // 3.56: board.js fills "Latest from CoRoute"; theme-init.js replaces the inline theme line (strict CSP)
  const jsTotal = [...js, 'hero3d.js'].reduce((s, f) => s + gz(`assets/${f}`), 0);
  assert.ok(jsTotal <= 250 * 1024, `homepage JS ${jsTotal} bytes gzip`);
  const css = [...html.matchAll(/<link rel="stylesheet" href="\/assets\/([^"?]+\.css)/g)].map((m) => m[1]);
  const cssTotal = css.reduce((s, f) => s + gz(`assets/${f}`), 0);
  assert.ok(cssTotal <= 60 * 1024, `homepage CSS ${cssTotal} bytes gzip`);
  // Fonts are self-hosted Manrope (the app's typeface) and preloaded on every page.
  for (const p of ['/', '/features', '/safety', '/get']) {
    const page = await (await fetch(base + p)).text();
    assert.ok(page.includes('<link rel="preload" href="/fonts/manrope-latin.woff2" as="font" type="font/woff2" crossorigin>'), `${p}: Manrope preloaded`);
  }
  const site = read('assets/site.css');
  assert.ok(site.includes('font-family: "Manrope"') && site.includes('--c-brand-fill: #2B7A8C') && site.includes('--c-sos: #D93A2F'), 'site.css uses the app tokens (light)');
  assert.ok(site.includes('--c-bg: #15181C') && site.includes('--c-surface: #1C2026') && site.includes('--c-text: #E7E3DC') && site.includes('prefers-color-scheme: dark'), 'site.css has the eye-friendly dark tokens and follows the system');
});
