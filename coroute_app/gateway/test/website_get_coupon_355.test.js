'use strict';
/**
 * 3.55 coupon QR / link: <origin>/get?coupon=CODE shows "Code CODE will be applied in the app" and passes the
 * code on (Play Install Referrer on the store link, "Open in the app" on Android, "Copy code"). The page
 * itself carries no code and no coupon text; get.js checks the format and writes with textContent only.
 */
process.env.NODE_ENV = 'test';
process.env.PLAY_STORE_URL = 'https://play.google.com/store/apps/details?id=space.devmonks.coroute_app&hl=en_IN';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

let gw, base;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });

const GET_JS = fs.readFileSync(path.join(__dirname, '..', 'public', 'assets', 'get.js'), 'utf8');

/** A tiny DOM, enough for get.js: elements with attributes, children, textContent and hidden. */
function fakePage({ search, ua = 'Mozilla/5.0 (Linux; Android 14)', playHref = process.env.PLAY_STORE_URL }) {
  const make = (tag) => {
    const el = {
      tagName: tag.toUpperCase(), attrs: {}, children: [], hidden: false, className: '', id: '', _text: '', listeners: {},
      setAttribute(k, v) { this.attrs[k] = String(v); },
      getAttribute(k) { return Object.hasOwn(this.attrs, k) ? this.attrs[k] : null; },
      appendChild(c) { this.children.push(c); return c; },
      addEventListener(t, f) { this.listeners[t] = f; },
      get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); },
      set textContent(v) { this._text = String(v); this.children = []; },
      style: {},
    };
    Object.defineProperty(el, 'innerHTML', { set() { throw new Error('innerHTML used'); }, get() { throw new Error('innerHTML used'); } });
    return el;
  };
  const chip = make('div');
  chip.hidden = true;
  const play = make('span');
  play.setAttribute('data-href', playHref);
  const download = make('a');
  download.setAttribute('href', '/download');
  const document = {
    getElementById: (id) => ({ 'code-chip': chip, 'play-store': playHref ? play : null }[id] || null),
    createElement: make,
    createTextNode: (t) => ({ textContent: String(t) }),
    querySelectorAll: (sel) => (sel === 'a[href="/download"]' ? [download] : []),
    body: make('body'),
  };
  const window = { location: { search, origin: 'https://coroute.devmonks.space' } };
  vm.runInNewContext(GET_JS, { window, document, navigator: { userAgent: ua }, URL, URLSearchParams, encodeURIComponent });
  return { chip, download };
}

const find = (el, id) => {
  if (el.id === id) return el;
  for (const c of el.children || []) { const f = find(c, id); if (f) return f; }
  return null;
};

test('/get carries an empty, hidden code chip, the Play link for the referrer and get.js; no code text in the page', async () => {
  const html = await (await fetch(base + '/get?coupon=WELCOME50')).text();
  assert.ok(html.includes('<div class="code-chip" id="code-chip" role="status" hidden></div>'), 'empty hidden chip');
  assert.ok(html.includes('id="play-store" data-href="https://play.google.com/store/apps/details?id=space.devmonks.coroute_app&amp;hl=en_IN"'), 'play link, escaped');
  assert.match(html, /<script src="\/assets\/get\.js\?v=[A-Za-z0-9_.]+" defer><\/script>/);
  assert.ok(!html.includes('WELCOME50'), 'the query is never rendered by the server');
  assert.ok(!/coupon/i.test(html), 'no coupon wording in the page itself');
  const evil = await (await fetch(base + '/get?coupon=%3Cscript%3Ealert(1)%3C%2Fscript%3E')).text();
  assert.ok(!evil.includes('<script>alert'), 'nothing from the query in the HTML');
  assert.equal((await fetch(base + '/assets/get.js')).status, 200);
});

test('get.js: a valid code shows the chip and passes the code to Play (Install Referrer) and the app', () => {
  const { chip, download } = fakePage({ search: '?coupon=welcome50' });
  assert.equal(chip.hidden, false);
  assert.equal(chip.children[0].textContent, 'Code WELCOME50 will be applied in the app');
  const store = download.getAttribute('href');
  assert.ok(store.startsWith('https://play.google.com/store/apps/details?id=space.devmonks.coroute_app&hl=en_IN&referrer=coupon%3DWELCOME50'), store);
  const open = find(chip, 'code-open');
  assert.ok(open, 'Open in the app on Android');
  assert.ok(open.getAttribute('href').startsWith('intent://get?coupon=WELCOME50#Intent;scheme=coroute;package=space.devmonks.coroute_app;S.browser_fallback_url=https%3A%2F%2Fplay.google.com'));
  assert.equal(open.textContent, 'Open in the app');
  assert.equal(find(chip, 'code-copy').textContent, 'Copy code');
});

test('get.js: no Play link -> the download stays; not Android -> no "Open in the app", copy only', () => {
  const { chip, download } = fakePage({ search: '?coupon=RIDE-1', ua: 'Mozilla/5.0 (Windows NT 10.0)', playHref: '' });
  assert.equal(chip.hidden, false);
  assert.equal(download.getAttribute('href'), '/download');
  assert.equal(find(chip, 'code-open'), null);
  assert.ok(find(chip, 'code-copy'));
});

test('get.js: invalid or hostile codes show nothing and change nothing (format A-Z 0-9 - _, at most 24)', () => {
  for (const search of ['', '?coupon=', '?coupon=%3Cimg%20src%3Dx%20onerror%3Dalert(1)%3E', '?coupon=' + 'A'.repeat(25), '?coupon=a%20b', '?coupon="x"', '?other=WELCOME50']) {
    const { chip, download } = fakePage({ search });
    assert.equal(chip.hidden, true, search);
    assert.equal(chip.children.length, 0, search);
    assert.equal(download.getAttribute('href'), '/download', search);
  }
  // A 24-character code is fine.
  assert.equal(fakePage({ search: '?coupon=' + 'B'.repeat(24) }).chip.hidden, false);
  assert.ok(!/innerHTML|insertAdjacentHTML|document\.write/.test(GET_JS), 'textContent only');
});
