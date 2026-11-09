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

test('platform blocks: Google Play content only with an https PLAY_STORE_URL, which fills __PLAY_STORE_URL__', () => {
  const html = 'A<!--play--><a href="__PLAY_STORE_URL__">Rate</a><!--/play-->B<!--no-play-->STORY<!--/no-play-->C';
  const url = 'https://play.google.com/store/apps/details?id=com.example.app&hl=en';
  assert.equal(applyPlatformBlocks(html, false, url), 'A<a href="https://play.google.com/store/apps/details?id=com.example.app&amp;hl=en">Rate</a>BC');
  assert.equal(applyPlatformBlocks(html, false), 'ABSTORYC');
  assert.equal(applyPlatformBlocks(html, false, ''), 'ABSTORYC');
  // Anything that is not a plain https link counts as not configured.
  for (const bad of ['http://play.google.com/x', 'javascript:alert(1)', 'https://x.example/"onmouseover="1', 'https://x.example/<b>', ' ']) {
    assert.equal(applyPlatformBlocks(html, false, bad), 'ABSTORYC', bad);
  }
  // iOS and Play blocks are independent.
  assert.equal(applyPlatformBlocks('<!--ios-->I<!--/ios--><!--play-->P<!--/play--><!--no-play-->N<!--/no-play-->', true, url), 'IP');
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
  assert.ok(home.includes('The iOS app is building now and coming soon. Until then, CoRoute runs on Android 6.0 or newer.'));
  const get = await (await fetch(base + '/get')).text();
  assert.ok(get.includes('The iOS app is building now and coming soon.'));
  assert.ok(!get.includes('id="ios"'));
  // 3.55 "coming soon" state: a disabled control, never a dead link to an App Store page that does not exist.
  for (const [page, html] of [['/', home], ['/get', get]]) {
    const soon = html.match(/<button class="btn btn--soon[^"]*" type="button" aria-disabled="true">[\s\S]*?<\/button>/g) || [];
    assert.ok(soon.length >= 1, `${page}: iOS coming-soon control`);
    for (const b of soon) {
      assert.ok(b.includes('Coming soon') && b.includes('building now'), `${page}: coming-soon wording`);
      assert.ok(!/<a\b/.test(b) && !/href="(?!\/assets\/)/.test(b), `${page}: coming-soon control is not a link`);
    }
    assert.ok(!html.includes('href="/download/ios"') && !html.includes('href="/get#ios"'), `${page}: no dead iOS link`);
  }
  assert.ok(home.includes('<span class="soon-pill">Coming soon</span>'), 'footer and header say coming soon');
});

test('with an iOS link the real download shows and the coming-soon state is gone', () => {
  const fs = require('fs');
  const path = require('path');
  const pub = path.join(__dirname, '..', 'public');
  for (const f of ['index.html', 'get.html', 'partials/header.html', 'partials/footer.html']) {
    const out = applyPlatformBlocks(fs.readFileSync(path.join(pub, f), 'utf8'), true);
    assert.ok(!out.includes('btn--soon') && !out.includes('soon-pill'), `${f}: coming-soon removed when iOS is configured`);
    assert.ok(/href="\/(?:download\/ios|get#ios)"/.test(out), `${f}: real iOS link kept`);
  }
});

test('without PLAY_STORE_URL the site asks for a story in the app instead of a Google Play rating', async () => {
  const about = await (await fetch(base + '/about')).text();
  assert.ok(!about.includes('Rate CoRoute on Google Play'), 'no Play rating button');
  assert.ok(!about.includes('__PLAY_STORE_URL__') && !/<!--\/?(no-)?play-->/.test(about), 'no placeholder or block markers left');
  assert.ok(about.includes('Share your story after a ride in the app.'));
  assert.ok(about.includes('Rate us in the app'));
  const home = await (await fetch(base + '/')).text();
  assert.ok(!home.includes('__PLAY_STORE_URL__') && !/<!--\/?(no-)?play-->/.test(home), 'home: no placeholder or block markers');
});
