#!/usr/bin/env node
/* Renders the CoRoute Play listing art from the HTML sources in this folder.
 *   node render.js [outDir] [nameFilter]
 * outDir defaults to the parent folder (out/play_assets). Needs playwright (with Chromium); uses sharp if
 * installed, otherwise python3 + Pillow, to flatten.
 * Every PNG is flattened to 24-bit RGB (no alpha), as Play requires for screenshots and the feature graphic. */
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
let sharp = null;
try { sharp = require('sharp'); } catch (e) { /* falls back to python3 + Pillow */ }

// Flatten to 24-bit RGB PNG (no alpha). Returns {width,height,channels,hasAlpha}.
async function flattenTo(buf, dest) {
  if (sharp) {
    await sharp(buf).flatten({ background: '#F6F4F0' }).removeAlpha().toColourspace('srgb').png({ compressionLevel: 9 }).toFile(dest);
    return sharp(dest).metadata();
  }
  const tmp = dest + '.tmp.png'; fs.writeFileSync(tmp, buf);
  const out = execFileSync('python3', ['-I', '-c', `import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGBA')
bg = Image.new('RGBA', im.size, (246, 244, 240, 255)); bg.alpha_composite(im)
rgb = bg.convert('RGB'); rgb.save(sys.argv[2], optimize=True)
print(rgb.size[0], rgb.size[1], len(rgb.getbands()))`, tmp, dest]).toString().trim().split(' ');
  fs.unlinkSync(tmp);
  return { width: +out[0], height: +out[1], channels: +out[2], hasAlpha: false };
}

const SRC = __dirname;
const OUT = path.resolve(process.argv[2] || path.join(SRC, '..'));
const FILTER = process.argv[3] || '';

const phone = [
  ['phone_01_ride_together', 'p01_ride.html'],
  ['phone_02_sos', 'p02_sos.html'],
  ['phone_03_crash', 'p03_crash.html'],
  ['phone_04_intercom', 'p04_intercom.html'],
  ['phone_05_group', 'p05_group.html'],
  ['phone_06_sirens', 'p06_sirens.html'],
  ['phone_07_people', 'p07_people.html'],
  ['phone_08_trip_report', 'p08_trip.html'],
  ['phone_09_guardians', 'p09_guardians.html'],
  ['phone_10_light_dark', 'p10_theme.html'],
];
const JOBS = [
  ...phone.map(([n, f]) => ({ out: `phone/${n}.png`, file: f, w: 1080, h: 1920, scale: 1 })),
  { out: 'feature_graphic_1024x500.png', file: 'feature.html', w: 1024, h: 500, scale: 1 },
  ...['map', 'trip', 'sos', 'people'].flatMap((k, i) => [
    { out: `tablet_7in/tablet7_0${i + 1}_${k}.png`, file: `tablet.html?s=${k}`, w: 1920, h: 1080, scale: 1 },
    { out: `tablet_10in/tablet10_0${i + 1}_${k}.png`, file: `tablet.html?s=${k}`, w: 1920, h: 1080, scale: 4 / 3 },
  ]),
];

const TYPES = { '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript', '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2' };
function serve() {
  return new Promise(res => {
    const srv = http.createServer((req, rsp) => {
      const p = path.join(SRC, decodeURIComponent(req.url.split('?')[0]));
      if (!p.startsWith(SRC) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { rsp.writeHead(404); return rsp.end(); }
      rsp.writeHead(200, { 'Content-Type': TYPES[path.extname(p)] || 'application/octet-stream' });
      fs.createReadStream(p).pipe(rsp);
    }).listen(0, '127.0.0.1', () => res(srv));
  });
}

(async () => {
  const srv = await serve();
  const base = `http://127.0.0.1:${srv.address().port}/`;
  const browser = await chromium.launch();
  for (const j of JOBS) {
    if (FILTER && !j.out.includes(FILTER) && !j.file.includes(FILTER)) continue;
    if (!fs.existsSync(path.join(SRC, j.file.split('?')[0]))) { console.log('skip (no source):', j.file); continue; }
    const ctx = await browser.newContext({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: j.scale });
    const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error') console.log('  console:', m.text()); });
    page.on('pageerror', e => console.log('  pageerror:', e.message));
    await page.goto(base + j.file);
    await page.waitForFunction('window.__ready === true', null, { timeout: 30000 });
    const err = await page.evaluate('window.__err');
    if (err) console.log('  error:', err);
    const buf = await page.screenshot({ type: 'png', clip: { x: 0, y: 0, width: j.w, height: j.h } });
    const dest = path.join(OUT, j.out);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const m = await flattenTo(buf, dest);
    console.log(`${j.out}  ${m.width}x${m.height}  channels=${m.channels} alpha=${m.hasAlpha}`);
    await ctx.close();
  }
  await browser.close();
  srv.close();
})();
