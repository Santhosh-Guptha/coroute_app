'use strict';
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { applyPlatformBlocks } = require('../src/pages');

test('platform blocks: iOS content only when an iOS link is configured', () => {
  const html = 'A<!--ios-->IOS<!--/ios-->B<!--no-ios-->SOON<!--/no-ios-->C<!--ios-->X\nY<!--/ios-->';
  assert.equal(applyPlatformBlocks(html, true), 'AIOSBC' + 'X\nY');
  assert.equal(applyPlatformBlocks(html, false), 'ABSOONC');
});

let gw, base;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });

test('without an iOS link the site never offers an iOS download and says so consistently', async () => {
  for (const page of ['/', '/get', '/about', '/how-it-works']) {
    const html = await (await fetch(base + page)).text();
    assert.ok(!html.includes('Download for iOS'), `${page} offers iOS download`);
    assert.ok(!html.includes('iOS 14.0'), `${page} mentions iOS 14 requirement`);
    assert.ok(!/<!--\/?(no-)?ios-->/.test(html), `${page} leaks block markers`);
  }
  const home = await (await fetch(base + '/')).text();
  assert.ok(home.includes('No iOS version yet. CoRoute runs on Android 6.0 or newer.'));
  const get = await (await fetch(base + '/get')).text();
  assert.ok(get.includes('No iOS version yet.'));
  assert.ok(!get.includes('id="ios"'));
});
