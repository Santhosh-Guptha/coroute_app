'use strict';
/**
 * 3.55 "CoRoute impact, live" on the website:
 * - safeImpact (src/public_privacy.js): every impact number is coarse, records only behind enough rides;
 * - GET /api/public/impact-stats answers with coarse values and the privacy note, never exact small numbers;
 * - the home page has the section hooks (hidden, nothing written into the page), /safety and /features a compact one;
 * - site.js polls /api/public/impact-stats every minute, pauses on a hidden tab, respects reduced motion, and its
 *   render hides tiles without a real number and the whole box below two real numbers (run in a small fake DOM).
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { safeImpact, PRIVACY_NOTE } = require('../src/public_privacy');

const PUB = path.join(__dirname, '..', 'public');
const JS = fs.readFileSync(path.join(PUB, 'assets', 'site.js'), 'utf8');
const KEYS = ['km', 'hours', 'rides', 'groupRides', 'largestGroup', 'longestTrip', 'bikes', 'sos', 'crash', 'answered', 'response', 'roads'];

let gw, base;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });

/* ---------- privacy rules ---------- */
test('safeImpact: counts rounded down with nothing below 10, records only behind enough rides', () => {
  const raw = {
    riders: 123, ridesCompleted: 57, kmRidden: 15234.6, groupsRidden: 21, sosResolved: 12, movingHours: 1317.4,
    groupRides: 23, largestGroup: 14, longestTripKm: 1847.9, bikes: 211, bikeModels: 9,
    safety: { sosResolved: 12, crashAlerts: 9, alertsAnswered: 34, medianResponseSec: 141.6, responsesCounted: 12, roadReports: 1049 },
    updatedAt: Date.UTC(2026, 10, 7, 14, 37),
  };
  const s = safeImpact(raw);
  assert.equal(s.kmRidden, 15000, 'distance to 1,000 km from 10,000 km');
  assert.equal(s.movingHours, 1300);
  assert.equal(s.ridesCompleted, 50);
  assert.equal(s.groupRides, 20);
  assert.equal(s.largestGroup, 14, 'largest group: a whole rider count, once 10 group rides exist');
  assert.equal(s.longestTripKm, 1840, 'longest trip rounded down to 10 km');
  assert.equal(s.bikes, 210);
  assert.equal(s.bikeModels, 0, 'fewer than 10 models reads as 0');
  assert.deepEqual(s.safety, { sosResolved: 10, crashAlerts: 0, alertsAnswered: 30, medianResponseSec: 142, roadReports: 1000 });
  assert.equal(s.updatedAt, Date.UTC(2026, 10, 7, 14), 'time to the hour');
  assert.ok(!('responsesCounted' in s.safety), 'the size of the response sample is not published');

  // Not enough yet: every record and safety number hides (0 or null), never an exact small value.
  const small = safeImpact({
    ridesCompleted: 9, groupRides: 9, largestGroup: 6, longestTripKm: 812, bikes: 3, kmRidden: 99,
    safety: { sosResolved: 2, crashAlerts: 1, alertsAnswered: 4, medianResponseSec: 75, responsesCounted: 9, roadReports: 7 },
  });
  assert.equal(small.ridesCompleted, 0);
  assert.equal(small.groupRides, 0);
  assert.equal(small.largestGroup, 0, 'no largest group below 10 group rides');
  assert.equal(small.longestTripKm, 0, 'no longest trip below 10 rides');
  assert.equal(small.bikes, 0);
  assert.equal(small.kmRidden, 0);
  assert.deepEqual(small.safety, { sosResolved: 0, crashAlerts: 0, alertsAnswered: 0, medianResponseSec: null, roadReports: 0 });

  // Junk in, nothing out.
  const junk = safeImpact({ ridesCompleted: 'x', groupRides: -40, largestGroup: Infinity, longestTripKm: NaN, safety: null });
  assert.equal(junk.largestGroup, 0);
  assert.equal(junk.longestTripKm, 0);
  assert.equal(junk.safety.medianResponseSec, null);
  assert.deepEqual(safeImpact(undefined).safety, { sosResolved: 0, crashAlerts: 0, alertsAnswered: 0, medianResponseSec: null, roadReports: 0 });
  assert.equal(PRIVACY_NOTE.perRider, false);
  assert.equal(PRIVACY_NOTE.perPlace, false);
});

test('GET /api/public/impact-stats: coarse values, the privacy note, no cookies, no per-ride lists', async () => {
  const r = await fetch(base + '/api/public/impact-stats');
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('set-cookie'), null);
  assert.match(r.headers.get('cache-control'), /max-age=60/);
  const j = await r.json();
  assert.equal(j.ok, true);
  assert.equal(j.enabled, true);
  assert.deepEqual(j.privacy, { ...PRIVACY_NOTE });
  const st = j.stats;
  for (const k of ['kmRidden', 'movingHours', 'ridesCompleted', 'groupRides', 'largestGroup', 'longestTripKm', 'bikes']) {
    assert.equal(typeof st[k], 'number', k);
    assert.ok(st[k] === 0 || st[k] >= 10, `${k}: zero or a coarse value`);
  }
  assert.ok(st.safety && typeof st.safety === 'object');
  assert.ok(!JSON.stringify(st).match(/"(?:trips|longestTrips|riderId|userId|name|email|lat|lng)"/), 'no per-ride or personal fields');
});

/* ---------- pages ---------- */
const sectionOf = (html, id) => {
  const i = html.indexOf(`id="${id}"`);
  assert.ok(i > 0, `section #${id}`);
  const start = html.lastIndexOf('<section', i);
  return html.slice(start, html.indexOf('</section>', i));
};
const textOf = (h) => h.replace(/<[^>]+>/g, ' ').replace(/&[a-z]+;/g, ' ').replace(/\s+/g, ' ');

test('home: the impact section is hidden until real numbers load and writes no number into the page', async () => {
  const html = await (await fetch(base + '/')).text();
  const open = html.match(/<section[^>]*id="impact"[^>]*>/);
  assert.ok(open, 'home: section #impact');
  assert.ok(/\bdata-impact\b/.test(open[0]) && /\bhidden\b/.test(open[0]), 'impact: hidden by default, filled by site.js');
  const sec = sectionOf(html, 'impact');
  for (const k of KEYS) assert.ok(sec.includes(`data-impact-key="${k}"`), `impact tile ${k}`);
  assert.equal((sec.match(/data-impact-key="[^"]+" hidden/g) || []).length, KEYS.length, 'every tile starts hidden');
  assert.ok(sec.includes('data-impact-updated') && sec.includes('class="live-dot"'), 'live dot and update time');
  assert.ok(sec.includes('data-impact-group') && textOf(sec).includes('Safety at work'), 'safety strip');
  const t = textOf(sec);
  for (const w of ['CoRoute impact, live', 'Real totals from real riders, rounded down', 'Never per rider', 'Kilometres ridden', 'Hours on the road', 'Largest group', 'Longest trip', 'Bikes on CoRoute', 'SOS alerts resolved', 'Crash alerts raised', 'Alerts answered by fellow riders', 'Typical response time', 'Road hazards reported']) {
    assert.ok(t.includes(w), `impact: "${w}"`);
  }
  assert.ok(!/\d/.test(t), 'impact: no number written into the page');
  assert.ok(!/saves? lives|lives saved|guarantee/i.test(t), 'impact: no overpromising');
  // The ride analytics card keeps its own hooks (fed by usage-stats).
  assert.ok(html.includes('data-ride-analytics') && html.includes('id="ra-chart"'));
});

test('/safety and /features carry a compact impact strip with the same hooks', async () => {
  const want = { '/safety': ['sos', 'crash', 'answered', 'response', 'roads'], '/features': ['km', 'hours', 'groupRides', 'largestGroup', 'longestTrip', 'bikes'] };
  for (const [p, keys] of Object.entries(want)) {
    const html = await (await fetch(base + p)).text();
    const open = html.match(/<section[^>]*id="impact"[^>]*>/);
    assert.ok(open && /\bdata-impact\b/.test(open[0]) && /\bhidden\b/.test(open[0]), `${p}: hidden impact strip`);
    const sec = sectionOf(html, 'impact');
    for (const k of keys) assert.ok(sec.includes(`data-impact-key="${k}"`), `${p}: tile ${k}`);
    assert.ok(!/\d/.test(textOf(sec).replace(/ten/g, '')), `${p}: no number written into the page`);
    assert.ok(sec.includes('href="/#impact"'), `${p}: links to the full numbers`);
  }
});

test('site.js: impact block polls the API every minute, pauses when hidden, respects reduced motion, no innerHTML', () => {
  const i = JS.indexOf('/* ---------- CoRoute impact, live');
  const j = JS.indexOf('/* ---------- Accordion', i);
  assert.ok(i > 0 && j > i, 'site.js has the impact block');
  const block = JS.slice(i, j);
  assert.ok(block.includes("fetch('/api/public/impact-stats'"), 'calls /api/public/impact-stats');
  assert.ok(block.includes("credentials: 'omit'"), 'no credentials');
  assert.ok(block.includes('setInterval(loadImpact, 60000)'), 'every 60 s');
  assert.ok(block.includes('if (doc.hidden) return;') && block.includes('visibilitychange'), 'paused on a hidden tab');
  assert.ok(block.includes('prefers-reduced-motion: reduce') && block.includes('requestAnimationFrame'), 'counters, never with reduced motion');
  assert.ok(!/innerHTML/.test(block), 'no innerHTML');
  assert.doesNotThrow(() => new Function(JS), 'site.js parses');
});

/* ---------- render, in a small fake DOM ---------- */
class El {
  constructor(tag, attrs = {}) {
    this.tagName = tag.toUpperCase();
    this.attrs = { ...attrs };
    this.children = [];
    this.parent = null;
    this.hidden = 'hidden' in attrs;
    this._text = '';
    const self = this;
    this.classList = { add(c) { self.cls.add(c); }, remove(c) { self.cls.delete(c); }, contains(c) { return self.cls.has(c); } };
    this.cls = new Set();
    this.offsetWidth = 0;
  }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this.children = []; this._text = String(v); }
  appendChild(c) { c.parent = this; this.children.push(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  all(out = []) { for (const c of this.children) { out.push(c); c.all(out); } return out; }
  matches(sel) {
    const m = sel.match(/^\[([a-z-]+)\](:not\(\[hidden\]\))?$/);
    if (!m) throw new Error(`fake DOM: unsupported selector ${sel}`);
    return m[1] in this.attrs && (!m[2] || !this.hidden);
  }
  querySelectorAll(sel) { return this.all().filter((e) => e.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

function makePage(keys, group) {
  const box = new El('section', { 'data-impact': '', hidden: '' });
  const upd = box.appendChild(new El('span', { 'data-impact-updated': '' }));
  const g = box.appendChild(new El('div', group ? { 'data-impact-group': '' } : {}));
  const tiles = {};
  for (const k of keys) {
    const tile = g.appendChild(new El('div', { 'data-impact-key': k, hidden: '' }));
    tile.appendChild(new El('dt'));
    tile.appendChild(new El('dd', { 'data-impact-value': '' }));
    tiles[k] = tile;
  }
  const note = box.appendChild(new El('p', { 'data-impact-note': '', hidden: '' }));
  const root = new El('body');
  root.appendChild(box);
  const doc = {
    hidden: false,
    createElement: (t) => new El(t),
    querySelectorAll: (sel) => root.querySelectorAll(sel),
    addEventListener() {},
  };
  return { doc, box, tiles, note, upd, group: g };
}
const flush = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };
const IMPACT = (() => {
  const i = JS.indexOf('/* ---------- CoRoute impact, live');
  return JS.slice(i, JS.indexOf('/* ---------- Accordion', i));
})();

async function run(body, keys = KEYS, group = false) {
  const page = makePage(keys, group);
  const calls = [];
  const fetchFn = async (url) => { calls.push(url); return { ok: true, status: 200, json: async () => body }; };
  // No matchMedia: treated as reduced motion, so the final values are written at once.
  const win = { fetch: fetchFn };
  // eslint-disable-next-line no-new-func
  new Function('doc', 'win', 'fetch', IMPACT)(page.doc, win, fetchFn);
  await flush();
  const shown = {};
  for (const [k, t] of Object.entries(page.tiles)) if (!t.hidden) shown[k] = t.children[1].textContent;
  return { ...page, shown, calls };
}

test('impact render: real tiles shown with coarse values, empty ones hidden, the box needs two real numbers', async () => {
  const stats = {
    ridesCompleted: 340, kmRidden: 48200, movingHours: 1320, groupRides: 90, largestGroup: 14, longestTripKm: 1840, bikes: 210,
    safety: { sosResolved: 20, crashAlerts: 0, alertsAnswered: 30, medianResponseSec: 142, roadReports: null },
  };
  const full = await run({ ok: true, enabled: true, stats });
  assert.deepEqual(full.calls, ['/api/public/impact-stats']);
  assert.equal(full.box.hidden, false);
  assert.deepEqual(full.shown, {
    km: '48,000+', hours: '1,300+', rides: '340+', groupRides: '90+', largestGroup: '14', longestTrip: '1,840+', bikes: '210+',
    sos: '20+', answered: '30+', response: '2min',
  });
  assert.equal(full.tiles.crash.hidden, true, 'a zero stays hidden');
  assert.equal(full.tiles.roads.hidden, true, 'a null stays hidden');
  assert.equal(full.note.hidden, false, 'gentle note when some tiles are not shown yet');
  assert.match(full.upd.textContent, /^Updated \d{2}:\d{2}$/);

  // An older server's exact small numbers are made coarse or hidden here too.
  const exact = await run({ ok: true, enabled: true, stats: { ridesCompleted: 57, kmRidden: 987, movingHours: 9, groupRides: 4, largestGroup: 6, longestTripKm: 412, bikes: 11, safety: { sosResolved: 3 } } });
  assert.deepEqual(exact.shown, { km: '900+', rides: '50+', longestTrip: '410+', bikes: '10+' });
  assert.equal(exact.tiles.largestGroup.hidden, true, 'no largest group without enough group rides');

  // Fewer than two real numbers: the whole box stays hidden.
  const one = await run({ ok: true, enabled: true, stats: { ridesCompleted: 40, safety: {} } });
  assert.equal(one.box.hidden, true);
  const none = await run({ ok: true, enabled: true, stats: { safety: {} } });
  assert.equal(none.box.hidden, true);

  // Switched off by the admin or the feature flag.
  const off = await run({ ok: true, enabled: false, stats: null });
  assert.equal(off.box.hidden, true);

  // A safety group with no real number hides itself.
  const safetyOnly = await run({ ok: true, enabled: true, stats: { ridesCompleted: 40, kmRidden: 5000, safety: {} } }, KEYS, true);
  assert.equal(safetyOnly.box.hidden, false);
  const g = await run({ ok: true, enabled: true, stats: { safety: { sosResolved: 1 } } }, ['sos', 'crash'], true);
  assert.equal(g.group.hidden, true);
});
