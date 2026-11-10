'use strict';
/**
 * Coupon QR / link. 3.55 printed <origin>/get?coupon=CODE; since 3.56 buying is on the website, so the
 * marketing link is <origin>/plans?coupon=CODE and /get?coupon=CODE forwards there (server 302, get.js as a
 * fallback for an old cached page). /get itself is the download page: download links only, no code text.
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

/** Runs get.js with a location; returns where it sent the browser (or null). */
function run(search) {
  let went = null;
  const window = { location: { search, replace: (u) => { went = u; } } };
  vm.runInNewContext(GET_JS, { window, URLSearchParams, encodeURIComponent });
  return went;
}

test('/get?coupon=CODE forwards to /plans?coupon=CODE (well-formed codes only); /get stays the download page', async () => {
  const r = await fetch(base + '/get?coupon=welcome50', { redirect: 'manual' });
  assert.equal(r.status, 302);
  assert.equal(r.headers.get('location'), '/plans?coupon=WELCOME50');
  assert.equal(r.headers.get('cache-control'), 'no-store');
  for (const bad of ['%3Cscript%3Ealert(1)%3C%2Fscript%3E', 'A'.repeat(25), 'a%20b', '']) {
    const b = await fetch(base + '/get?coupon=' + bad, { redirect: 'manual' });
    assert.equal(b.headers.get('location'), '/plans', bad);
  }
  const page = await fetch(base + '/get');
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /<script src="\/assets\/get\.js\?v=[A-Za-z0-9_.]+" defer><\/script>/);
  assert.ok(!/coupon/i.test(html), 'no coupon wording on the download page');
  assert.ok(!/₹\s?\d|Rs\.? ?\d/.test(html), 'no prices on the download page');
  assert.ok(html.includes('href="/download"') && html.includes('href="/plans"'));
});

test('get.js (fallback): a code goes to /plans?coupon=CODE, a bad one to /plans, no code stays put; never writes HTML', () => {
  assert.equal(run('?coupon=ride-1'), '/plans?coupon=RIDE-1');
  assert.equal(run('?coupon=' + 'B'.repeat(24)), '/plans?coupon=' + 'B'.repeat(24));
  for (const bad of ['?coupon=%3Cimg%20src%3Dx%3E', '?coupon=' + 'A'.repeat(25), '?coupon="x"', '?coupon=']) assert.equal(run(bad), '/plans', bad);
  assert.equal(run(''), null);
  assert.equal(run('?other=WELCOME50'), null);
  assert.ok(!/innerHTML|insertAdjacentHTML|document\.write/.test(GET_JS));
});
