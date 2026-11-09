// Visual check for the marketing studio (not shipped): renders the starter templates with the JS mirror
// in render.html. Usage (from the repo root):
//   dart --packages=.dart_tool/package_config.json docs/features_355/marketing_preview/dump_starters.dart > /tmp/mk/render_input.json
//   cp gateway/public/fonts/manrope-latin.woff2 docs/features_355/marketing_preview/render.html /tmp/mk/
//   node docs/features_355/marketing_preview/render.js gateway /tmp/mk   (PNGs in /tmp/mk/out)
const puppeteer = require(require('path').resolve(process.argv[2], 'node_modules/puppeteer'));
const fs = require('fs'); const path = require('path');
fs.mkdirSync(path.join(process.argv[3], 'out'), { recursive: true });
(async () => {
  const S = process.argv[3]; const data = JSON.parse(fs.readFileSync(path.join(S, 'render_input.json'), 'utf8'));
  const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || undefined, args: ['--no-sandbox', '--allow-file-access-from-files'] });
  const page = await browser.newPage();
  page.on('console', (m) => console.log('page:', m.text())); page.on('pageerror', (e) => console.log('pageerror:', e.message));
  await page.goto('file://' + path.join(S, 'render.html')); await page.evaluate(() => document.fonts.load('800 40px Manrope')); await page.evaluate(() => document.fonts.ready);
  for (const k of Object.keys(data)) {
    const url = await page.evaluate((d) => { window.render(d); return document.getElementById('c').toDataURL('image/png'); }, data[k]);
    fs.writeFileSync(path.join(S, 'out', `${k}.png`), Buffer.from(url.split(',')[1], 'base64'));
    console.log('wrote', k, data[k].t.size.width + 'x' + data[k].t.size.height);
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
