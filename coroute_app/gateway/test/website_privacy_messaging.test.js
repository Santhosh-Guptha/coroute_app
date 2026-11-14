'use strict';
/**
 * Website, privacy and messaging (B3):
 * - every public number is coarse: rounded down, nothing below 10, ratings from 10 up, times to the hour,
 *   no per-ride list (src/public_privacy.js) on usage-stats, community-stats, live-now and stories;
 * - the site sets no cookies and loads no trackers;
 * - Community (solo is always free), group rides, ride analytics (a labelled sample), help-us-build and
 *   the feedback topic.
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const P = require('../src/public_privacy');

const PUB = path.join(__dirname, '..', 'public');
const read = (rel) => fs.readFileSync(path.join(PUB, rel), 'utf8');
const HOUR = 3600000;

let gw, base;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });

/* ---------- privacy rules ---------- */
test('privacy rounding: counts below 10 read as 0, then tens, hundreds, thousands, always rounded down', () => {
  const cases = [[0, 0], [1, 0], [9, 0], [10, 10], [19, 10], [48, 40], [999, 990], [1000, 1000], [1234, 1200], [99999, 99900], [123456, 123000], [-5, 0], [NaN, 0], ['37', 30], [null, 0]];
  for (const [n, want] of cases) assert.equal(P.roundCount(n), want, `count ${n}`);
  const km = [[0, 0], [99.9, 0], [100, 100], [987, 900], [9999, 9900], [10000, 10000], [15234.6, 15000], [-1, 0]];
  for (const [n, want] of km) assert.equal(P.roundKm(n), want, `km ${n}`);
  assert.equal(P.toHour(Date.UTC(2026, 10, 7, 14, 59, 59, 999)), Date.UTC(2026, 10, 7, 14));
  assert.equal(P.toDay(Date.UTC(2026, 10, 7, 14, 30)), Date.UTC(2026, 10, 7));
  assert.equal(P.toHour(null), null);
  assert.equal(P.safeRating(4.66, 9), null, 'a rating needs 10 ratings behind it');
  assert.equal(P.safeRating(4.66, 10), 4.7);
  assert.equal(P.safeRating(7, 50), null);
  assert.equal(P.MIN_COUNT, 10);
});

test('usage view: same keys, coarse values; community view: totals only, no per-ride list', () => {
  const raw = { riders: 7, ridesCompleted: 48, kmRidden: 15234, groupsRidden: 3, sosResolved: 2, avgRating: 4.5, ratingsCount: 4, updatedAt: Date.UTC(2026, 10, 7, 9, 41, 7) };
  assert.deepEqual(P.safeUsage(raw), {
    riders: 0, ridesCompleted: 40, kmRidden: 15000, groupsRidden: 0, sosResolved: 0, avgRating: null,
    movingHours: 0, avgSpeedKmh: null, weeklyKm: [], updatedAt: Date.UTC(2026, 10, 7, 9),
  });
  assert.equal(P.safeUsage({ ...raw, ratingsCount: 25 }).avgRating, 4.5);
  // 3.55 ride analytics: hours like counts, speed only from 10 rides, a week's km only from 10 rides.
  const ra = P.safeUsage({ ...raw, movingHours: 437, avgSpeedKmh: 41.8, weeklyKm: [
    { weekStart: Date.UTC(2026, 9, 26, 3), km: 1834, rides: 22 },
    { weekStart: Date.UTC(2026, 10, 2), km: 260, rides: 4 },
  ] });
  assert.equal(ra.movingHours, 430);
  assert.equal(ra.avgSpeedKmh, 41);
  assert.deepEqual(ra.weeklyKm, [
    { weekStart: Date.UTC(2026, 9, 26), km: 1800, rides: 20 },
    { weekStart: Date.UTC(2026, 10, 2), km: null, rides: 0 },
  ]);
  assert.equal(P.safeUsage({ ...raw, ridesCompleted: 9, avgSpeedKmh: 40 }).avgSpeedKmh, null);
  const community = P.safeCommunityStats({
    enabled: true, totalRiders: 123, activeRiders: 4, totalKilometers: 4321.7, lastUpdated: Date.UTC(2026, 10, 7, 9, 5),
    longestTrips: [{ rank: 1, distanceKm: 420, durationFormatted: '8h 0m', anonymousRiderLabel: 'Rider #1' }],
  });
  assert.deepEqual(community, { enabled: true, totalRiders: 120, activeRiders: 0, totalKilometers: 4300, longestTrips: [], lastUpdated: Date.UTC(2026, 10, 7, 9) });
  assert.deepEqual(P.safeCommunityStats({ enabled: false, message: 'off' }), { enabled: false, message: 'off' });
});

test('public endpoints answer with coarse numbers only', async () => {
  const u = await (await fetch(base + '/api/public/usage-stats')).json();
  assert.deepEqual(Object.keys(u.stats).sort(), ['avgRating', 'avgSpeedKmh', 'groupsRidden', 'kmRidden', 'movingHours', 'riders', 'ridesCompleted', 'sosResolved', 'updatedAt', 'weeklyKm']);
  assert.equal(u.stats.updatedAt % HOUR, 0, 'usage: time to the hour');
  assert.deepEqual(u.privacy, { minCount: 10, rounding: 'down', timeResolution: 'hour', perRider: false, perPlace: false });
  assert.ok(!('ratingsCount' in u.stats), 'the exact rating count stays on the server');
  const c = await (await fetch(base + '/api/public/community-stats')).json();
  assert.deepEqual(c.longestTrips, [], 'community: no per-ride list');
  assert.equal(c.lastUpdated % HOUR, 0, 'community: time to the hour');
  for (const k of ['totalRiders', 'activeRiders']) assert.equal(c[k] % 10, 0, k);
  const live = await (await fetch(base + '/api/public/live-now')).json();
  assert.equal(live.updatedAt % HOUR, 0, 'live-now: time to the hour');
  assert.equal(live.ridersOnRide % 10, 0);
});

test('a published story carries dates to the day only', () => {
  const { publicStory } = require('../src/trip_reviews');
  const at = Date.UTC(2026, 9, 3, 17, 42, 11);
  const s = publicStory({ feedbackId: 'FB-1', rating: 5, writtenFeedback: 'Great ride over the pass.', approvedAt: at, submittedAt: at - 5000 }, 0, {});
  assert.equal(s.approvedAt, Date.UTC(2026, 9, 3));
  assert.equal(s.submittedAt, Date.UTC(2026, 9, 3));
});

/* ---------- no cookies, no trackers ---------- */
const PAGES = ['/', '/features', '/safety', '/how-it-works', '/about', '/get', '/privacy', '/terms', '/no-such-page'];
const PUBLIC_APIS = ['/api/public/usage-stats', '/api/public/community-stats', '/api/public/live-now', '/api/public/community-stories?limit=3', '/api/membership/catalog'];
const TRACKERS = /google-analytics|googletagmanager|gtag\(|\bga\(|doubleclick|facebook\.net|fbq\(|connect\.facebook|hotjar|segment\.(?:io|com)|mixpanel|amplitude|clarity\.ms|plausible|matomo|piwik|newrelic|sentry|fullstory|mouseflow|yandex|tiktok|linkedin\.com\/px|adservice/i;

test('the website sets no cookies and loads no trackers', async () => {
  for (const p of [...PAGES, ...PUBLIC_APIS]) {
    const r = await fetch(base + p);
    assert.equal(r.headers.get('set-cookie'), null, `${p}: sets a cookie`);
    const body = await r.text();
    if (p.startsWith('/api/')) continue;
    assert.ok(!TRACKERS.test(body), `${p}: tracker`);
    assert.ok(!/<script[^>]+src="(?:https?:)?\/\//i.test(body), `${p}: third-party script`);
    assert.ok(!/<iframe/i.test(body), `${p}: embedded frame`);
  }
  const pv = await fetch(base + '/api/pv', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify({ path: '/', ref: '' }) });
  assert.equal(pv.status, 204);
  assert.equal(pv.headers.get('set-cookie'), null, 'page-view beacon sets no cookie');
  for (const f of ['assets/site.js', 'assets/home.js', 'assets/hero3d.js']) {
    const js = read(f);
    assert.ok(!/document\.cookie|\.cookie\s*=/.test(js), `${f}: touches cookies`);
    assert.ok(!TRACKERS.test(js), `${f}: tracker`);
    assert.ok(!/https?:\/\/(?!www\.w3\.org\/2000\/svg)/.test(js), `${f}: calls another site`);
  }
});

/* ---------- messaging on the home page ---------- */
const sectionOf = (html, id) => {
  const i = html.indexOf(`id="${id}"`);
  assert.ok(i > 0, `section #${id}`);
  const start = html.lastIndexOf('<section', i);
  return html.slice(start, html.indexOf('</section>', i));
};
const textOf = (h) => h.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

test('home: Community, solo riding and every safety feature are free (hero, pricing, FAQ)', async () => {
  const html = await (await fetch(base + '/')).text();
  const hero = sectionOf(html, 'hero-title');
  assert.ok(textOf(hero).includes('Community: solo riding and every safety feature are free.'), 'hero note');
  assert.ok(hero.includes('href="#community-free"'));
  const pricing = sectionOf(html, 'pricing');
  assert.ok(pricing.includes('id="community-free"'), 'Community banner inside pricing');
  assert.ok(textOf(pricing).includes('Solo riding and every safety feature are free.') && pricing.includes('href="/plans"'), 'pricing: free line, plans only on /plans');
  assert.ok(!/\d/.test(textOf(pricing)), 'pricing: still no number written into the page');
  // v3.58: one FAQ for the site, on /how-it-works.
  const hiw = await (await fetch(base + '/how-it-works')).text();
  const faq = sectionOf(hiw, 'faq');
  assert.ok(/Is it free\?[\s\S]*Yes for solo riders, always/.test(textOf(faq)), 'FAQ answer');
  assert.ok(textOf(faq).includes('What do the numbers on this site say about me?'), 'FAQ: numbers and privacy');
  assert.ok(!/Is CoRoute free\?/.test(textOf(faq)), 'no second, older free answer');
});

test('home: no duplicate sections; the rate card sits with the rider reviews (v3.58)', async () => {
  const html = await (await fetch(base + '/')).text();
  for (const id of ['group-rides', 'ride-analytics', 'numbers', 'help-build', 'faq']) assert.ok(!html.includes(`id="${id}"`), `#${id} removed`);
  const reviews = sectionOf(html, 'reviews');
  assert.ok(reviews.includes('id="rate"') && textOf(reviews).includes('Rate us in the app'), 'rate card inside reviews');
  assert.ok(!/\d/.test(textOf(sectionOf(html, 'pricing'))), 'no price on the home page');
});

test('feedback form: topics match the server, safety ideas are stored with their topic', async () => {
  const html = await (await fetch(base + '/')).text();
  const sel = html.slice(html.indexOf('<select'), html.indexOf('</select>'));
  const values = [...sel.matchAll(/<option value="([a-z-]+)"/g)].map((m) => m[1]);
  assert.deepEqual(values, ['general', 'safety-idea', 'bug', 'story', 'other']);
  assert.ok(html.includes('<label class="form-label" for="fb-topic">'), 'labelled');
  const post = (body) => fetch(base + '/api/feedback', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const old = Date.now() - 10000;
  const msg = 'Please add an automatic check-in when a rider stops for a long time in a tunnel.';
  assert.equal((await post({ email: 'idea@example.com', message: msg, topic: 'safety-idea', t: old })).status, 201);
  assert.equal((await post({ email: 'plain@example.com', message: msg, t: old })).status, 201);
  const bad = await post({ email: 'x@example.com', message: msg, topic: '<script>', t: old });
  assert.equal(bad.status, 422);
  assert.ok((await bad.json()).fields.topic);
  const stored = await gw.repo.listFeedback();
  assert.equal(stored.find((f) => f.email === 'idea@example.com').topic, 'safety-idea');
  assert.equal(stored.find((f) => f.email === 'plain@example.com').topic, 'general');
  assert.ok(!stored.some((f) => f.email === 'x@example.com'));
  const js = read('assets/site.js');
  assert.ok(js.includes("$$('[data-fb-topic]')") && js.includes("get('topic')"), 'site.js preselects the topic');
});

/* ---------- home.js renders the group plan chips from the catalog ---------- */
class El {
  constructor(tag) { this.tagName = String(tag).toUpperCase(); this.children = []; this.attrs = {}; this.className = ''; this.hidden = false; this._text = ''; const self = this; this.classList = { add(c) { self.className = `${self.className} ${c}`.trim(); }, contains(c) { return self.className.split(/\s+/).includes(c); } }; }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this.children = []; this._text = String(v); }
  appendChild(c) { this.children.push(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener() {}
}
async function runGroupPlans(catalog) {
  const chips = new El('ul');
  chips.hidden = true;
  const document = {
    hidden: false, readyState: 'loading',
    getElementById: (id) => (id === 'group-plans' ? chips : null),
    querySelector: () => null,
    createElement: (t) => new El(t), createElementNS: (ns, t) => new El(t), createTextNode: (t) => { const e = new El('#text'); e._text = String(t); return e; },
    addEventListener() {},
  };
  const window = {
    fetch: async () => (catalog ? { ok: true, status: 200, json: async () => catalog } : { ok: false, status: 503, json: async () => ({}) }),
    addEventListener() {}, setInterval() {}, setTimeout() {},
  };
  // eslint-disable-next-line no-new-func
  new Function('document', 'window', read('assets/home.js'))(document, window);
  for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r));
  return chips;
}

test('group plan chips: only paid group plans, with the catalog price and seats', async () => {
  const chips = await runGroupPlans({ categories: {
    community: { id: 'community', name: 'Community', monthlyPriceInr: 0, maxCapacity: 1 },
    group_large: { id: 'group_large', name: 'Large Group (7-12)', monthlyPriceInr: 99, minCapacity: 7, maxCapacity: 12, billingPeriodDays: 30 },
    group_small: { id: 'group_small', name: 'Small Group (2-6)', monthlyPriceInr: 49, minCapacity: 2, maxCapacity: 6, billingPeriodDays: 30 },
  } });
  assert.equal(chips.hidden, false);
  assert.deepEqual(chips.children.map((c) => c.getAttribute('data-plan')), ['group_small', 'group_large']);
  assert.deepEqual(chips.children.map((c) => c.textContent), ['Small Group2 to 6 riders, host included₹49 a month', 'Large Group7 to 12 riders, host included₹99 a month']);
  const none = await runGroupPlans(null);
  assert.equal(none.hidden, true, 'no catalog, no prices');
  assert.equal(none.children.length, 0);
});

/* ---------- 3.56: "Your data is protected" page and the honest comparison ---------- */
test('privacy-and-security page: plain-language promises, true security practices, deletion link, careful DPDP wording', async () => {
  const r = await fetch(base + '/privacy-and-security');
  assert.equal(r.status, 200);
  const html = await r.text();
  const t = textOf(html);
  for (const w of ['Encrypted on the way', 'Passwords stored as hashes', 'Location only during rides', 'Voice relayed, never stored', 'Medical info only in emergencies', 'No ads, no trackers, no sale',
    'Rate limits', 'Signed payment messages', 'Admin audit log', 'AES-256', 'scrypt', 'only when you send it']) {
    assert.ok(t.includes(w), w);
  }
  assert.ok(html.includes('href="/delete-account"'), 'links the deletion page');
  assert.ok(t.includes("Designed with India's DPDP Act in mind") && t.includes('not a certification'), 'DPDP: design intent, no certification claim');
  assert.ok(!/DPDP[- ](?:certified|compliant)|certified by/i.test(t), 'no compliance or certification claim');
  assert.ok(html.includes('data-nav="privacy-and-security" aria-current="page"'), 'nav item current');
  assert.ok(!/Oracle|WebSocket/.test(t), 'no infrastructure jargon');
  // The claims are true in the code.
  assert.ok(read('../src/password_hash.js').includes('crypto.scrypt'), 'scrypt hashing');
  assert.ok(read('../src/razorpay_gateway.js').includes('verifyWebhook'), 'signed webhooks');
  assert.ok(read('../src/backup_jobs.js').includes('aes-256-gcm'), 'encrypted backups');
  const home = await (await fetch(base + '/')).text();
  assert.ok(home.includes('href="/privacy-and-security" data-nav="privacy-and-security"'), 'header links the page');
});

test('home: why-CoRoute comparison names no competitor app, makes no price claim, and is honest about WhatsApp encryption', async () => {
  const html = await (await fetch(base + '/')).text();
  const cmp = sectionOf(html, 'compare');
  const t = textOf(cmp);
  for (const w of ['Typical group-ride apps', 'WhatsApp live location', 'crash detection', 'SOS without mobile data', 'Siren alerts', 'Live intercom', 'without installing an app', 'encrypted in transit', 'No ads', 'Group roles', 'Trip report']) assert.ok(t.toLowerCase().includes(w.toLowerCase()), w);
  for (const name of ['Asteride', 'RideClan', 'MileVoy', 'Riding Verse', 'Trilyt', 'Triplly', 'Detecht', 'Calimoto', 'REVER', 'Sena', 'Cardo']) assert.ok(!t.includes(name), `names ${name}`);
  assert.ok(/End-to-end/.test(t), 'WhatsApp encryption stated fairly');
  assert.ok(!/\d+\s*(?:\/|per) ?month|₹/.test(t), 'no prices');
  const sx = textOf(sectionOf(html, 'standout'));
  for (const w of ['Crash detection with a 30-second check', 'SOS that works without signal', "Hears sirens when your earbuds don't", 'Live intercom, hands-free, clean voice', 'Family follows live, no app needed', 'Your data is encrypted, never sold or shared']) assert.ok(sx.includes(w), w);
  assert.ok(!/15 seconds/.test(textOf(html)), 'crash countdown is 30 seconds (SafetyConstants.crashCountdown)');
});
