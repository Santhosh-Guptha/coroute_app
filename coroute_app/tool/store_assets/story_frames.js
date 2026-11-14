#!/usr/bin/env node
'use strict';
/**
 * Round 12: saves the home page scroll story's static frames for visitors without JavaScript
 * (gateway/public/assets/story/<name>.svg, shown through <noscript> in index.html).
 * The frames are drawn by the same code as the live story (gateway/public/assets/story.js, reduced-motion mode), so
 * after editing a scene run this again:
 *
 *   node tool/store_assets/story_frames.js
 *
 * Each file carries the story's SVG rules (home.css, between "story-svg:start" and "story-svg:end") and the site's
 * colour tokens for light and dark (prefers-color-scheme). Needs Playwright with Chromium.
 */
process.env.NODE_ENV = 'test';
const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

const GW = path.join(__dirname, '..', '..', 'gateway');
const OUT = path.join(GW, 'public', 'assets', 'story');
const NAMES = { 'plan@1': 'plan', 'roll@0.8': 'roll', 'ghat@0.7': 'ghat', 'forest@1': 'forest', 'behind@0.62': 'behind', 'crash@0.42': 'crash', 'crash@1': 'finder', 'home@1': 'home' };

function loadPlaywright() {
  const tries = [path.join(GW, 'node_modules', 'playwright')];
  try { tries.push(path.join(execSync('npm root -g').toString().trim(), 'playwright')); } catch { /* no npm */ }
  for (const p of tries) { try { return require(p); } catch { /* next */ } }
  throw new Error('Playwright not found');
}

(async () => {
  const { createApp } = require(path.join(GW, 'src/app'));
  const { MemorySoda } = require(path.join(GW, 'src/oracle/memory_soda'));
  const gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${gw.server.address().port}`;
  const css = fs.readFileSync(path.join(GW, 'public', 'assets', 'home.css'), 'utf8');
  const rules = css.slice(css.indexOf('/* story-svg:start'), css.indexOf('/* story-svg:end */')).replace(/^\/\*[^*]*\*\/\n/, '');
  const tokenNames = [...new Set(rules.match(/--c-[a-z0-9-]+/g))];
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  const tokens = {};
  let frames = null;
  for (const scheme of ['light', 'dark']) {
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 }, colorScheme: scheme, reducedMotion: 'reduce' });
    await page.goto(origin + '/', { waitUntil: 'load' });
    tokens[scheme] = await page.evaluate((names) => names.map((n) => n + ':' + getComputedStyle(document.documentElement).getPropertyValue(n).trim()).join(';'), tokenNames);
    if (scheme === 'light') {
      await page.evaluate(() => document.getElementById('story').scrollIntoView());
      await page.waitForFunction(() => document.querySelector('[data-story][data-state="static"]'), null, { timeout: 15000 });
      const h = await page.evaluate(() => document.getElementById('story').offsetHeight);
      for (let y = 0; y < h; y += 400) { await page.evaluate((dy) => window.scrollBy(0, dy), 400); await page.waitForTimeout(60); }
      frames = await page.evaluate(() => [...document.querySelectorAll('[data-frame]')].map((f) => {
        const svg = f.querySelector('svg');
        return { key: f.getAttribute('data-frame') + '@' + f.getAttribute('data-p'), svg: svg ? svg.outerHTML : '' };
      }));
    }
    await page.close();
  }
  await browser.close();
  await gw.shutdown();
  fs.mkdirSync(OUT, { recursive: true });
  const style = `:root{${tokens.light}}@media (prefers-color-scheme:dark){:root{${tokens.dark}}}`
    + 'text{font-family:Manrope,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}' + rules.replace(/\s*\n\s*/g, '');
  for (const f of frames) {
    const name = NAMES[f.key];
    if (!name || !f.svg) throw new Error('frame not drawn: ' + f.key);
    const body = f.svg.replace(/^<svg[^>]*>/, '').replace(/<\/svg>$/, '').replace(/ opacity="1\.000"/g, '');
    const out = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 400" width="480" height="400" class="st-svg"><style>${style}</style>${body}</svg>\n`;
    fs.writeFileSync(path.join(OUT, name + '.svg'), out);
    console.log(name + '.svg', out.length, 'bytes');
  }
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
