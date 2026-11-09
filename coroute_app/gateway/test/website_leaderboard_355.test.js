'use strict';
/**
 * 3.55b website leaderboards:
 * - /leaderboard is a site page (shared shell, nav item, sitemap); the home page has a hidden #leaderboard section;
 *   neither writes a number or a username into the page;
 * - site.js reads GET /api/public/leaderboard, renders usernames with textContent only (cleaned, cut to 32),
 *   keeps the best 5 (home) or 10 (page), hides boards without riders, and treats a 404 or bad answer as empty:
 *   the home section stays hidden and the page shows "Leaderboards appear once riders complete enough rides";
 * - tabs follow the ARIA pattern; the privacy page explains usernames only and the opt-out.
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

const PUB = path.join(__dirname, '..', 'public');
const JS = fs.readFileSync(path.join(PUB, 'assets', 'site.js'), 'utf8');
const BLOCK = (() => {
  const i = JS.indexOf('/* ---------- Leaderboards');
  const j = JS.indexOf('/* ---------- Accordion', i);
  assert.ok(i > 0 && j > i, 'site.js has the leaderboard block');
  return JS.slice(i, j);
})();
const BOARDS = ['topScore', 'longestRide', 'mostKm', 'mostHours', 'mostRides'];

let gw, base;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });

const textOf = (h) => h.replace(/<[^>]+>/g, ' ').replace(/&[a-z]+;/g, ' ').replace(/\s+/g, ' ');
const sectionOf = (html, id) => {
  const i = html.indexOf(`id="${id}"`);
  assert.ok(i > 0, `section #${id}`);
  const start = html.lastIndexOf('<section', i);
  return html.slice(start, html.indexOf('</section>', i));
};

test('pages: /leaderboard in the shared shell, nav and sitemap; the home section is hidden and empty', async () => {
  const r = await fetch(base + '/leaderboard');
  assert.equal(r.status, 200);
  const html = await r.text();
  assert.ok(html.includes('data-nav="leaderboard" aria-current="page"'), 'nav item current');
  assert.ok(html.includes('class="site-header"') && html.includes('class="site-footer"'));
  const sec = sectionOf(html, 'leaderboard');
  for (const b of BOARDS) assert.ok(sec.includes(`data-lb-tab="${b}"`), `tab ${b}`);
  assert.ok(sec.includes('data-lb-limit="10"') && sec.includes('role="tablist"') && sec.includes('role="tabpanel"'));
  assert.ok(textOf(sec).includes('Leaderboards appear once riders complete enough rides'), 'empty note');
  assert.ok(textOf(sec).includes('Riders can hide their name in the app'), 'opt-out note');
  assert.ok(!/\d/.test(textOf(sec).replace(/Top 10/g, '')), 'no number written into the page');

  const home = await (await fetch(base + '/')).text();
  const open = home.match(/<section[^>]*id="leaderboard"[^>]*>/);
  assert.ok(open && /\bhidden\b/.test(open[0]) && /data-lb-hide-empty/.test(open[0]) && /data-lb-limit="5"/.test(open[0]), 'home: hidden until a board has a rider');
  const hs = sectionOf(home, 'leaderboard');
  assert.ok(hs.includes('href="/leaderboard"') && textOf(hs).includes('Riders can hide their name in the app'));
  assert.ok(!/\d/.test(textOf(hs).replace(/top 10/gi, '')), 'home: no number written into the page');
  assert.ok(home.includes('href="/leaderboard" data-nav="leaderboard"'), 'header links the page');

  const sm = await (await fetch(base + '/sitemap.xml')).text();
  assert.ok(sm.includes(`<loc>${base}/leaderboard</loc>`));
  const privacy = textOf(await (await fetch(base + '/privacy')).text());
  assert.ok(privacy.includes('Public leaderboards') && privacy.includes('unique username') && privacy.includes('rounded totals') && privacy.includes('opt out'), 'privacy page explains it');
});

test('site.js leaderboard block: one public endpoint, no credentials, no innerHTML, textContent for names', () => {
  assert.ok(BLOCK.includes("fetch('/api/public/leaderboard'"));
  assert.ok(BLOCK.includes("credentials: 'omit'"));
  assert.ok(!/innerHTML|insertAdjacentHTML|outerHTML|document\.write/.test(BLOCK), 'no HTML injection');
  assert.ok(BLOCK.includes('nm.textContent = r.name'), 'usernames as text');
  assert.ok(BLOCK.includes('prefers-reduced-motion: reduce'));
  assert.ok(BLOCK.includes("'ArrowRight'") && BLOCK.includes("'Home'") && BLOCK.includes("'End'"), 'keyboard tabs');
  assert.ok(!/[^\x00-\x7F]/.test(BLOCK), 'ASCII only (escapes for the cleaned characters)');
});

/* ---------- render, in a small fake DOM ---------- */
class El {
  constructor(tag, attrs = {}) {
    this.tagName = tag.toUpperCase();
    this.attrs = { ...attrs };
    this.children = [];
    this.hidden = 'hidden' in attrs;
    this.id = attrs.id || '';
    this._text = '';
    this.listeners = {};
    this.style = { props: {}, setProperty(k, v) { this.props[k] = v; } };
    const cls = this.cls = new Set();
    this.classList = { add(c) { cls.add(c); }, remove(c) { cls.delete(c); }, contains(c) { return cls.has(c); } };
    this.className = '';
    this.offsetWidth = 0;
  }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this.children = []; this._text = String(v); }
  appendChild(c) { this.children.push(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  hasAttribute(k) { return k in this.attrs; }
  addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); }
  focus() { this.focused = true; }
  all(out = []) { for (const c of this.children) { out.push(c); c.all(out); } return out; }
  matches(sel) {
    const m = sel.match(/^\[([a-z-]+)\]$/);
    if (!m) throw new Error(`fake DOM: unsupported selector ${sel}`);
    return m[1] in this.attrs;
  }
  querySelectorAll(sel) { return this.all().filter((e) => e.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

function makeBox({ limit, hideEmpty }) {
  const attrs = { 'data-leaderboard': '', 'data-lb-limit': String(limit) };
  if (hideEmpty) { attrs['data-lb-hide-empty'] = ''; attrs.hidden = ''; }
  const box = new El('section', attrs);
  const body = box.appendChild(new El('div', { 'data-lb-body': '' }));
  const tabs = {};
  for (const b of BOARDS) tabs[b] = body.appendChild(new El('button', { 'data-lb-tab': b, id: `t-${b}` }));
  const panel = body.appendChild(new El('div', { 'data-lb-panel': '' }));
  const list = panel.appendChild(new El('ol', { 'data-lb-list': '' }));
  const empty = box.appendChild(new El('p', { 'data-lb-empty': '', hidden: '' }));
  const live = box.appendChild(new El('p', { 'data-lb-live': '', hidden: '' }));
  const upd = live.appendChild(new El('span', { 'data-lb-updated': '' }));
  return { box, body, tabs, panel, list, empty, live, upd };
}

const flush = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };
async function run(answer, opts = { limit: 10, hideEmpty: false }) {
  const page = makeBox(opts);
  const root = new El('body');
  root.appendChild(page.box);
  const calls = [];
  const fetchFn = async (url) => { calls.push(url); return typeof answer === 'function' ? answer(url) : { ok: true, status: 200, json: async () => answer }; };
  const doc = { hidden: false, createElement: (t) => new El(t), querySelectorAll: (s) => root.querySelectorAll(s), addEventListener() {} };
  const win = { fetch: fetchFn }; // no matchMedia: reduced motion, final state at once
  // eslint-disable-next-line no-new-func
  new Function('doc', 'win', 'fetch', BLOCK)(doc, win, fetchFn);
  await flush();
  const rows = page.list.children.map((li) => ({
    rank: li.children[0].textContent, name: li.children[2].children[0].textContent,
    sub: li.children[2].children[1] ? li.children[2].children[1].textContent : null, value: li.children[3].textContent,
    bar: li.children[4].children[0].style.width,
  }));
  return { ...page, rows, calls };
}

const SAMPLE = {
  updatedAt: Date.UTC(2026, 10, 9, 10),
  topScore: [
    { username: 'ridge_runner', score: 812, rides: 41 },
    { username: '<img src=x onerror=alert(1)>', score: 990, rides: 12 },
    { username: 'ridge_runner', score: 700, rides: 3 },
    { username: 'ghost‮rider\u0007', score: 640, rides: 1 },
    { username: '', score: 900 },
    { username: 'zero', score: 0 },
    { username: { evil: true }, score: 500 },
    { username: 'x'.repeat(60), score: 'NaN' },
    { username: 'y'.repeat(40), score: 300, rides: 9 },
  ],
  longestRide: [{ username: 'ladakh_lata', km: 1240.7 }],
  mostKm: [],
  mostHours: [{ username: 'night_owl', hours: 312 }],
  mostRides: 'oops',
};

test('render: clean usernames as text, highest first, invalid rows dropped, empty boards hidden', async () => {
  const r = await run(SAMPLE);
  assert.deepEqual(r.calls, ['/api/public/leaderboard']);
  assert.equal(r.box.hidden, false);
  assert.equal(r.empty.hidden, true);
  assert.equal(r.live.hidden, false);
  assert.match(r.upd.textContent, /^Updated /);
  assert.deepEqual(r.rows.map((x) => x.name), ['<img src=x onerror=alert(1)>', 'ridge_runner', 'ghostrider', 'y'.repeat(32)], 'text only, duplicates and junk dropped, cut to 32');
  assert.deepEqual(r.rows.map((x) => x.rank), ['1', '2', '3', '4']);
  assert.equal(r.rows[0].value, '990 pts');
  assert.equal(r.rows[1].sub, '41 rides');
  assert.equal(r.rows[2].sub, '1 ride');
  assert.equal(r.rows[0].bar, '100%');
  assert.equal(r.rows[3].bar, '30%');
  assert.equal(r.tabs.topScore.getAttribute('aria-selected'), 'true');
  assert.equal(r.tabs.topScore.getAttribute('tabindex'), '0');
  assert.equal(r.tabs.mostKm.hidden, true, 'a board without riders has no tab');
  assert.equal(r.tabs.mostRides.hidden, true, 'a malformed board has no tab');
  assert.equal(r.tabs.longestRide.hidden, false);
  assert.equal(r.panel.getAttribute('aria-labelledby'), 't-topScore');

  // Switch tab by click and by keyboard (End -> last visible tab).
  r.tabs.longestRide.listeners.click[0]();
  assert.equal(r.tabs.longestRide.getAttribute('aria-selected'), 'true');
  assert.equal(r.tabs.topScore.getAttribute('tabindex'), '-1');
  assert.equal(r.list.children[0].children[3].textContent, '1,240 km');
  let prevented = false;
  r.tabs.longestRide.listeners.keydown[0]({ key: 'End', preventDefault() { prevented = true; } });
  assert.ok(prevented);
  assert.equal(r.tabs.mostHours.getAttribute('aria-selected'), 'true');
  assert.equal(r.tabs.mostHours.focused, true);
  assert.equal(r.list.children[0].children[3].textContent, '312 h');
  r.tabs.mostHours.listeners.keydown[0]({ key: 'ArrowRight', preventDefault() {} });
  assert.equal(r.tabs.topScore.getAttribute('aria-selected'), 'true', 'arrow keys wrap around visible tabs');
});

test('render: top 5 on home, top 10 on the page', async () => {
  const many = { topScore: Array.from({ length: 15 }, (_, i) => ({ username: `rider_${i}`, score: 1000 - i * 10, rides: 5 })) };
  assert.equal((await run(many, { limit: 5, hideEmpty: true })).rows.length, 5);
  const page = await run(many, { limit: 10, hideEmpty: false });
  assert.equal(page.rows.length, 10);
  assert.equal(page.rows[9].name, 'rider_9');
});

test('empty, missing endpoint or switched off: home hides, the page shows the empty note, nothing invented', async () => {
  const notFound = () => ({ ok: false, status: 404, json: async () => ({ error: 'Not found' }) });
  for (const answer of [notFound, { updatedAt: 1, topScore: [], longestRide: [], mostKm: [], mostHours: [], mostRides: [] }, { enabled: false }, null, 'nope']) {
    const home = await run(answer, { limit: 5, hideEmpty: true });
    assert.equal(home.box.hidden, true, 'home: hidden');
    assert.equal(home.rows.length, 0);
    const pg = await run(answer, { limit: 10, hideEmpty: false });
    assert.equal(pg.box.hidden, false, 'page: stays');
    assert.equal(pg.empty.hidden, false, 'page: empty note');
    assert.equal(pg.body.hidden, true, 'page: no tabs');
    assert.equal(pg.live.hidden, true);
    assert.equal(pg.rows.length, 0);
  }
  const thrown = await run(() => { throw new Error('offline'); }, { limit: 10, hideEmpty: false });
  assert.equal(thrown.empty.hidden, false);
});
