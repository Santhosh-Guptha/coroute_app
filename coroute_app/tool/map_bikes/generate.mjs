// Regenerates assets/map_bikes/ and assets/garage_bikes/ from bikes.js (see README.md).
//   node tool/map_bikes/generate.mjs [--out <repo root>] [--only sport,cruiser] [--no-hero] [--no-top]
// Needs three@0.187.0, sharp and playwright resolvable from the current directory (run it from a
// scratch folder where they are installed; nothing is installed into the repo).
import { createRequire } from 'node:module';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const req = createRequire(path.join(process.cwd(), 'noop.js'));
const sharp = req('sharp');
const { chromium } = req('playwright');
const threeDir = path.resolve(path.dirname(req.resolve('three')), '..');

const args = process.argv.slice(2);
const arg = (k, d) => {
  const i = args.indexOf(k);
  return i < 0 ? d : args[i + 1];
};
const repo = path.resolve(arg('--out', path.join(here, '..', '..')));
const only = arg('--only', '')?.split(',').filter(Boolean);
const doTop = !args.includes('--no-top');
const doHero = !args.includes('--no-hero');

export const TYPES = ['commuter', 'scooter', 'sport', 'cruiser', 'adventure', 'offroad', 'electric', 'retro'];
const TOP = 64; // logical marker box (px); 2.0x = 128, 3.0x = 192
const HERO = [128, 80]; // logical garage hero
const SS = 4; // supersampling of the 3.0x size

export function serve() {
  const types = { '.js': 'text/javascript', '.html': 'text/html', '.png': 'image/png', '.json': 'application/json' };
  const srv = http.createServer((q, s) => {
    const u = decodeURIComponent(new URL(q.url, 'http://x').pathname);
    let f;
    if (u.startsWith('/three/')) f = path.join(threeDir, u.slice(7));
    else if (u.startsWith('/tool/')) f = path.join(here, u.slice(6));
    else if (u.startsWith('/assets/')) f = path.join(repo, u.slice(1));
    else if (u.startsWith('/scratch/')) f = path.join(process.cwd(), u.slice(9));
    if (!f || !fs.existsSync(f) || fs.statSync(f).isDirectory()) {
      s.writeHead(404);
      return s.end();
    }
    s.writeHead(200, { 'content-type': types[path.extname(f)] ?? 'application/octet-stream' });
    fs.createReadStream(f).pipe(s);
  });
  return new Promise((res) => srv.listen(0, '127.0.0.1', () => res(srv)));
}

const buf = (dataUrl) => Buffer.from(dataUrl.split(',')[1], 'base64');

async function writeScaled(png, name, dir, w, h) {
  const outs = [];
  for (const [scale, sub] of [[1, ''], [2, '2.0x'], [3, '3.0x']]) {
    const d = path.join(repo, 'assets', dir, sub);
    fs.mkdirSync(d, { recursive: true });
    const f = path.join(d, name);
    await sharp(png)
      .resize(w * scale, h * scale, { kernel: 'lanczos3' })
      .png({ palette: true, quality: 92, effort: 10, colours: 256, dither: 0.6, compressionLevel: 9 })
      .toFile(f);
    outs.push(f);
  }
  return outs;
}

async function main() {
  const srv = await serve();
  const port = srv.address().port;
  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on('console', (m) => m.type() === 'error' && console.error('page:', m.text()));
  page.on('pageerror', (e) => console.error('page error:', e.message));
  await page.goto(`http://127.0.0.1:${port}/tool/render.html`);
  await page.waitForFunction(() => window.ready === true, null, { timeout: 60000 });
  const list = only?.length ? only : TYPES;
  for (const t of list) {
    if (doTop) {
      for (const r of [1, 2]) {
        const res = await page.evaluate(([t, r, px]) => window.renderTop(t, r, px), [t, r, TOP * 3 * SS]);
        for (const layer of ['shadow', 'base', 'paint', 'gloss']) await writeScaled(buf(res[layer]), `${t}_${r}_${layer}.png`, 'map_bikes', TOP, TOP);
        console.log('top', t, r);
      }
    }
    if (doHero) {
      for (const r of [0, 2]) {
        const res = await page.evaluate(([t, r, w, h]) => window.renderHero(t, r, w, h), [t, r, HERO[0] * 3 * 3, HERO[1] * 3 * 3]);
        for (const layer of ['base', 'paint', 'gloss']) await writeScaled(buf(res[layer]), `${t}_${r}_${layer}.png`, 'garage_bikes', HERO[0], HERO[1]);
        console.log('hero', t, r);
      }
    }
  }
  await browser.close();
  srv.close();
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
