'use strict';
/**
 * Round 12 website: the home page scroll story ("A ride with CoRoute") and the new app screens on the other pages.
 * - #story: seven chapters with headings, text in the HTML, a text alternative per figure, saved no-JS frames
 *   (lazy, sized), and assets/story.js loaded late by home.js (IntersectionObserver), drawing with text nodes only;
 * - reduced motion and no-JS keep the same text; the live layout is chosen by CSS (no layout shift);
 * - the home page still has no phone screenshots; features, safety, how-it-works, get and guide show the v3.58
 *   renders in phone frames (lazy, sized, described);
 * - honest wording for the offline link (per hop, never "1 km per phone"), the rescue finder (last stretch) and
 *   estimated limits ("est."); the JSON-LD feature list names the new features.
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

const PUB = path.join(__dirname, '..', 'public');
const read = (f) => fs.readFileSync(path.join(PUB, f), 'utf8');
let gw, base;
before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${gw.server.address().port}`;
});
after(async () => { await gw.shutdown(); });
const page = async (p) => (await fetch(base + p)).text();
const sectionOf = (html, id) => {
  const i = html.indexOf(`id="${id}"`);
  assert.ok(i > 0, `section #${id}`);
  const start = html.lastIndexOf('<section', i);
  return html.slice(start, html.indexOf('</section>', i));
};

test('home: the scroll story has seven chapters with headings, text in the HTML and a text alternative per visual', async () => {
  const html = await page('/');
  const sec = sectionOf(html, 'story');
  assert.ok(/<section[^>]*id="story"[^>]*data-story[^>]*data-src="\/assets\/story\.js\?v=[0-9a-f]{10}"/.test(html), 'story section with the versioned script for home.js');
  assert.ok(sec.includes('<h2 id="story-title">'), 'story heading');
  assert.ok(sec.includes('href="#standout"') && sec.includes('Skip the story'), 'keyboard users can skip the story');
  const scenes = [...sec.matchAll(/class="st__step[^"]*" id="story-([a-z]+)" data-scene="([a-z]+)"/g)].map((m) => m[2]);
  assert.deepEqual(scenes, ['plan', 'roll', 'ghat', 'forest', 'behind', 'crash', 'home'], 'seven chapters in order');
  assert.equal((sec.match(/<h3>/g) || []).length, 7, 'a heading per chapter');
  const figs = [...sec.matchAll(/<figure class="st__fig" data-frame="([a-z]+)" data-p="([0-9.]+)">([\s\S]*?)<\/figure>/g)];
  assert.equal(figs.length, 8, 'a figure per chapter, two for the crash (SOS and the finder)');
  for (const [, frame, , body] of figs) {
    assert.ok(/<figcaption class="sr-only">(?:Illustration|Chart)[^<]{60,}<\/figcaption>/.test(body), `${frame}: text alternative`);
    const img = body.match(/<noscript><img src="\/assets\/story\/([a-z]+)\.svg\?v=[0-9a-f]{10}" width="480" height="400" alt="" loading="lazy" decoding="async"><\/noscript>/);
    assert.ok(img, `${frame}: saved no-JS frame, sized and lazy`);
    const svg = read(`assets/story/${img[1]}.svg`);
    assert.ok(svg.startsWith('<svg xmlns="http://www.w3.org/2000/svg"') && svg.includes('prefers-color-scheme:dark') && svg.length > 3000, `${img[1]}.svg: a real frame with light and dark colours`);
    assert.ok(!/<script|href="http|on[a-z]+="/i.test(svg), `${img[1]}.svg: no script, links or handlers`);
  }
  // The story's crew is fictional (Indian first names) and the numbers are example values, not claims.
  for (const name of ['Meera', 'Imran', 'Kiran', 'Asha', 'Dev', 'Ravi']) assert.ok(sec.includes(name), name);
  assert.ok(/made up/.test(sec) && sec.includes('Find Ravi') && sec.includes('call 112'), 'fiction stated, the finder chapter, call 112');
  assert.ok(sec.includes('it does not replace them'), 'honest limits in the crash chapter');
  // Home still shows no phone screenshots (website_live.test.js), and nothing in the story is one.
  assert.ok(!sec.includes('/assets/screens/') && !sec.includes('dev__shot'));
});

test('story.js: late, light, safe and motion-aware; home.js loads it when the story comes near', () => {
  const js = read('assets/story.js');
  assert.doesNotThrow(() => new Function(js), 'story.js parses');
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(/.test(js), 'text nodes and DOM calls only');
  assert.ok(!/https?:\/\//.test(js.replace('http://www.w3.org/2000/svg', '')), 'no network requests');
  assert.ok(js.includes("'(prefers-reduced-motion: reduce)'") && js.includes("setAttribute('data-state', 'static')"), 'reduced motion: static frames');
  assert.ok(js.includes('IntersectionObserver') && js.includes('visibilitychange') && js.includes('requestAnimationFrame'), 'drawn only while visible');
  for (const s of ['plan', 'roll', 'ghat', 'forest', 'behind', 'crash', 'home']) assert.ok(new RegExp(`\\b${s}: function \\(g\\)`).test(js), `scene ${s}`);
  assert.ok(js.length < 40000, `story.js stays small (${js.length} bytes)`);
  const home = read('assets/home.js');
  const block = home.slice(home.indexOf('Round 12 scroll story'), home.indexOf('/* ---------- Live now'));
  assert.ok(block.includes("doc.querySelector('[data-story]')") && block.includes('IntersectionObserver') && block.includes("'fallback'"), 'home.js lazy-loads story.js with a fallback');
  assert.ok(!/innerHTML/.test(home), 'home.js: no innerHTML');
  const css = read('assets/home.css');
  assert.ok(/@media \(prefers-reduced-motion: no-preference\) \{\s*\.js \.st:not\(\[data-state="fallback"\]\) \.st__stage/.test(css), 'live layout only with motion allowed and JS, from the first paint');
  assert.ok(css.includes('/* story-svg:start') && css.includes('/* story-svg:end */'), 'story SVG rules marked for the frame exporter');
  assert.ok(css.includes('.st__box {') && css.includes('aspect-ratio: 6 / 5'), 'figures reserve their space (no layout shift)');
});

test('the other pages show the v3.58 app screens in phone frames, lazy, sized and described', async () => {
  const want = {
    '/features': ['crash', 'curve', 'group', 'intercom', 'community', 'trip', 'home', 'explore', 'ride', 'stats', 'offline', 'sos', 'finder', 'profile'],
    '/safety': ['crash', 'sos', 'finder', 'offline'],
    '/how-it-works': ['home', 'explore', 'ride', 'trip'],
    '/get': ['welcome', 'home', 'curve'],
    '/guide': ['home', 'noroute'],
  };
  for (const [p, names] of Object.entries(want)) {
    const html = await page(p);
    const imgs = [...html.matchAll(/<img src="\/assets\/screens\/([a-z-]+)-480\.png\?v=[0-9a-f]{10}" width="636" height="1386" alt="([^"]{40,140})" loading="lazy" decoding="async">/g)];
    const got = new Set(imgs.map((m) => m[1]));
    for (const n of names) assert.ok(got.has(n), `${p}: screen ${n}`);
    assert.equal(imgs.length, (html.match(/<img src="\/assets\/screens\//g) || []).length, `${p}: every screen image is sized, lazy and has alt text`);
    for (const [, n] of imgs) {
      for (const w of [320, 480, 636]) for (const ext of ['avif', 'webp']) assert.ok(html.includes(`/assets/screens/${n}-${w}.${ext}?v=`), `${p}: ${n}-${w}.${ext} in srcset`);
    }
  }
  for (const f of fs.readdirSync(path.join(PUB, 'assets', 'screens'))) {
    assert.ok(/^[a-z]+-(320|480|636)\.(avif|webp)$|^[a-z]+-480\.png$/.test(f), `screens/${f}: name pattern`);
  }
  for (const gone of ['dark', 'guardians', 'sirens']) assert.ok(!fs.existsSync(path.join(PUB, 'assets', 'screens', `${gone}-480.png`)), `old ${gone} screen removed`);
});

test('honest wording: offline link per hop, rescue finder for the last stretch, estimated limits, JSON-LD features', async () => {
  for (const p of ['/', '/features', '/safety', '/how-it-works', '/get', '/guide', '/about']) {
    const text = (await page(p)).replace(/<[^>]+>/g, ' ');
    assert.ok(!/\b1\s?km (?:per|each|for every|from (?:each|every|one)) (?:phone|rider|hop|bike)/i.test(text) && !/\b(?:one|a) kilometre (?:per|from each) (?:phone|rider)/i.test(text), `${p}: no 1 km per phone claim`);
    assert.ok(!/saves? lives|guaranteed rescue|always finds/i.test(text), `${p}: no overpromising`);
  }
  const features = await page('/features');
  assert.ok(features.includes('a few hundred metres per hop') && features.includes('est.') && features.includes('last stretch'), '/features: offline link, est., finder');
  assert.ok(features.includes('Noise reduction') && features.includes('id="ride-screen"') && features.includes('id="screens-tour"'), '/features: noise reduction, ride screen, screen tour');
  const safety = await page('/safety');
  assert.ok(safety.includes('id="rescue"') && safety.includes('id="offline-link"') && safety.includes('Roughly 30 to 100 m'), '/safety: rescue finder with honest ranges and the offline link');
  assert.ok(safety.includes('a few hundred metres per hop'), '/safety: offline link per hop');
  const get = await page('/get');
  assert.ok(get.includes('Android 7.0 or newer') && get.includes('Nearby devices (Bluetooth)'), '/get: minimum Android and the Nearby devices permission');
  const home = await page('/');
  const ld = JSON.parse(home.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
  assert.equal(ld.operatingSystem, 'Android 7.0 or newer');
  for (const f of ['Offline link', 'Rescue beacon and finder', 'Curve warnings and speed limits', 'noise reduction']) {
    assert.ok(ld.featureList.some((x) => x.includes(f)), `JSON-LD: ${f}`);
  }
});
