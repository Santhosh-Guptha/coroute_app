'use strict';
/**
 * With PLAY_STORE_URL set, the home page offers "Rate CoRoute on Google Play" with that exact link (escaped),
 * and still mentions rating in the app. The opposite case is in website_ios_blocks.test.js.
 */
process.env.NODE_ENV = 'test';
process.env.PLAY_STORE_URL = 'https://play.google.com/store/apps/details?id=space.devmonks.coroute&hl=en_IN';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

let gw, base;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });

test('with PLAY_STORE_URL the home page links the Google Play rating to it', async () => {
  const home = await (await fetch(base + '/')).text();
  const card = home.slice(home.indexOf('id="rate"'), home.indexOf('</li>', home.indexOf('id="rate"')));
  assert.ok(card.includes('Love riding safer? Rate CoRoute on Google Play.'), 'rating heading');
  assert.ok(card.includes('href="https://play.google.com/store/apps/details?id=space.devmonks.coroute&amp;hl=en_IN"'), 'configured link, escaped');
  assert.ok(card.includes('rel="noopener noreferrer"') && card.includes('(opens Google Play)'), 'safe external link, announced');
  assert.ok(card.includes('Rate us in the app'), 'in-app rating still mentioned');
  assert.ok(!home.includes('Share your story after a ride in the app.'), 'the no-play text is left out');
  assert.ok(!home.includes('__PLAY_STORE_URL__') && !/<!--\/?(no-)?play-->/.test(home), 'no placeholder or block markers left');
  // Other pages are unaffected and never carry the placeholder.
  for (const p of ['/features', '/get', '/about']) {
    const html = await (await fetch(base + p)).text();
    assert.ok(!html.includes('__PLAY_STORE_URL__'), p);
  }
});
