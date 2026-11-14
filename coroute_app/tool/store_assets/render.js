#!/usr/bin/env node
'use strict';
/**
 * Round 12: renders the v3.58 design mocks into
 *   - the website phone screenshots (gateway/public/assets/screens/<name>-{320,480,636}.{avif,webp} + <name>-480.png),
 *   - the Google Play listing graphics (docs/store/play_assets_v3.58/: 8 phone screenshots, 4 + 4 tablet
 *     screenshots, the 1024 x 500 feature graphic, the 512 x 512 icon export).
 * The screens are drawn by tool/store_assets/mocks/ (static HTML/CSS with the app's tokens and Manrope), NOT
 * captured on a phone: compare with the real build before publishing (docs/store/play_assets_v3.58/README.md).
 *
 *   node tool/store_assets/render.js                 # everything
 *   node tool/store_assets/render.js web             # website screenshots only
 *   node tool/store_assets/render.js play            # Play graphics only
 *   node tool/store_assets/render.js play phone_03   # only matching Play jobs
 *
 * Needs Playwright with Chromium (gateway/node_modules or the global npm root; never installed here) and python3
 * with Pillow (AVIF / WebP encoding, RGB flattening).
 */
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execSync, execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..', '..');
const MOCKS = path.join(__dirname, 'mocks');
const BUILD = fs.mkdtempSync(path.join(os.tmpdir(), 'coroute-store-'));
const WEB_OUT = path.join(ROOT, 'gateway', 'public', 'assets', 'screens');
const PLAY_OUT = path.join(ROOT, 'docs', 'store', 'play_assets_v3.58');
const what = process.argv[2] || 'all';
const only = process.argv[3] || '';

function loadPlaywright() {
  const tries = [path.join(ROOT, 'gateway', 'node_modules', 'playwright')];
  try { tries.push(path.join(execSync('npm root -g').toString().trim(), 'playwright')); } catch { /* no npm */ }
  for (const p of tries) { try { return require(p); } catch { /* next */ } }
  throw new Error('Playwright not found (looked in ' + tries.join(', ') + ')');
}

/* ---------- 1. Build the mock HTML (python generators + the round 11 HUD mocks) ---------- */
execFileSync('python3', [path.join(MOCKS, 'gen_redesign.py'), BUILD], { stdio: 'inherit' });
execFileSync('python3', [path.join(MOCKS, 'gen_extra.py'), BUILD], { stdio: 'inherit' });
for (const f of fs.readdirSync(path.join(MOCKS, 'hud'))) fs.copyFileSync(path.join(MOCKS, 'hud', f), path.join(BUILD, f));
fs.copyFileSync(path.join(ROOT, 'assets', 'fonts', 'Manrope-Variable.ttf'), path.join(BUILD, 'Manrope-Variable.ttf'));

/* A neutral status bar: time, full Wi-Fi, full signal, full battery; no carrier, no notifications (Play guideline). */
const STATUS = '<span>9:41</span><span style="display:flex;gap:6px;align-items:center">'
  + '<svg width="16" height="12" viewBox="0 0 16 12"><path d="M8 11.5 0.6 4.2a10.5 10.5 0 0 1 14.8 0z" fill="currentColor"/></svg>'
  + '<svg width="14" height="12" viewBox="0 0 14 12"><path d="M13.5 0.5v11h-13z" fill="currentColor"/></svg>'
  + '<svg width="22" height="11" viewBox="0 0 22 11"><rect x=".5" y=".5" width="18" height="10" rx="2.5" fill="none" stroke="currentColor"/><rect x="2" y="2" width="15" height="7" rx="1.5" fill="currentColor"/><rect x="19.5" y="3.5" width="2" height="4" rx="1" fill="currentColor"/></svg></span>';

async function shootMock(page, file, { light = false, w = 412, h = 915, dpr = 2, out, css = '' }) {
  await page.setViewportSize({ width: w, height: h });
  await page.goto('file://' + path.join(BUILD, file + '.html') + (light ? '#light' : ''));
  await page.reload();
  await page.evaluate(([status, extra]) => {
    document.querySelectorAll('.status').forEach((s) => { s.innerHTML = status; });
    if (extra) { const st = document.createElement('style'); st.textContent = extra; document.head.appendChild(st); }
  }, [STATUS, css]);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(120);
  await page.screenshot({ path: out });
}

const py = (code, ...args) => execFileSync('python3', ['-c', code, ...args], { stdio: 'inherit' });

/* ---------- 2. Website screenshots: 636 x 1386 (the size the pages declare), then 480 / 320 ---------- */
// name -> [mock, light?]. Names are what the pages reference (features, safety, how-it-works, get, guide).
const WEB = {
  home: ['home', true], explore: ['explore', true], community: ['community', true], profile: ['profile', true],
  ride: ['hud_collapsed_group', false], intercom: ['hud_collapsed_group', false], stats: ['hud_half_group', false],
  curve: ['hud_night_curve', false], group: ['hud_full_group', false], noroute: ['hud_solo_noroute', false],
  crash: ['crash', true], sos: ['sos', true], finder: ['finder', true], offline: ['offline', true], trip: ['trip', true],
  people: ['community', false], welcome: ['welcome', false],
};
const ENCODE = `
import sys
from PIL import Image
src, out, name = sys.argv[1], sys.argv[2], sys.argv[3]
im = Image.open(src).convert('RGB')
assert im.size == (636, 1386), im.size
for w in (636, 480, 320):
    r = im if w == 636 else im.resize((w, round(1386 * w / 636)), Image.LANCZOS)
    r.save(f'{out}/{name}-{w}.webp', quality=80, method=6)
    r.save(f'{out}/{name}-{w}.avif', quality=55)
    if w == 480:
        r.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(f'{out}/{name}-480.png', optimize=True)
`;

/* ---------- 3. Play phone screenshots: 1080 x 2160 (2:1, within Play's 2:1 limit), caption band under 20 % ---------- */
const PHONE = [
  ['phone_01_home', 'home', true, 'Ride together. Stay safe.', 'Crash detection, SOS and your crew in one place'],
  ['phone_02_group_map', 'hud_collapsed_group', true, 'Your group on one live map', 'Big turn card, lead and sweep, hold to talk'],
  ['phone_03_ride_stats', 'hud_half_group', false, 'Know your ride as you ride', 'Speed against the limit, ride so far, distance by speed'],
  ['phone_04_curve_warnings', 'hud_night_curve', false, 'Curves and limits, ahead', 'Curve warnings with a comfortable speed'],
  ['phone_05_offline_link', 'offline', true, 'When the signal drops', 'The group\'s phones pass messages along'],
  ['phone_06_sos_finder', 'finder', true, 'SOS, then help finds you', 'The rescue finder guides riders in the last stretch'],
  ['phone_07_explore', 'explore', true, 'Rides near you', 'Breakfast runs, ghats and weekend trips'],
  ['phone_08_trip_report', 'trip', true, 'Every ride, remembered', 'Trip report, ride summary and replay'],
];

async function play(page) {
  fs.mkdirSync(path.join(PLAY_OUT, 'phone'), { recursive: true });
  fs.mkdirSync(path.join(PLAY_OUT, 'tablet_7in'), { recursive: true });
  fs.mkdirSync(path.join(PLAY_OUT, 'tablet_10in'), { recursive: true });
  const font = 'url(' + JSON.stringify('file://' + path.join(BUILD, 'Manrope-Variable.ttf')) + ')';
  // Screen area: 792 x 1760 px on a 1080 x 2160 page; the mock is the full 412 x 915 dp screen (792 / 412 = 1.92).
  for (const [i, [name, mock, light, title, sub]] of PHONE.entries()) {
    if (only && !name.includes(only)) continue;
    const shot = path.join(BUILD, name + '_screen.png');
    await shootMock(page, mock, { light, w: 412, h: 915, dpr: 3, out: shot });
    const warm = i % 2 === 1;
    const html = `<!doctype html><html><head><meta charset="utf-8"><style>
@font-face{font-family:Manrope;src:${font};font-weight:200 800}
*{margin:0;box-sizing:border-box}html,body{width:1080px;height:2160px;overflow:hidden}
body{font-family:Manrope,sans-serif;background:${warm ? '#F6F4F0' : '#1E5F6D'};color:${warm ? '#1F2328' : '#FFFFFF'};position:relative}
.topo{position:absolute;inset:0;opacity:${warm ? '.5' : '.18'}}
.cap{position:absolute;left:60px;right:60px;top:92px;height:300px;text-align:center}
h1{font-size:76px;font-weight:800;letter-spacing:-1.5px;line-height:1.08}
p{font-size:38px;font-weight:500;margin-top:22px;opacity:.86;line-height:1.3}
.scr{position:absolute;left:144px;top:400px;width:792px;height:1760px;border-radius:56px 56px 0 0;overflow:hidden;
 box-shadow:0 0 0 2px ${warm ? '#CFC8BD' : 'rgba(255,255,255,.25)'},0 30px 80px rgba(0,0,0,.28)}
.scr img{width:792px;height:1760px;display:block}
</style></head><body>
<svg class="topo" viewBox="0 0 1080 2160" preserveAspectRatio="none"><g fill="none" stroke="${warm ? '#2B7A8C' : '#FFFFFF'}" stroke-width="2" opacity=".35">
${Array.from({ length: 9 }, (_, k) => `<path d="M-40 ${180 + k * 240} C 260 ${80 + k * 240}, 520 ${340 + k * 240}, 1120 ${150 + k * 240}"/>`).join('')}</g></svg>
<div class="cap"><h1>${title}</h1><p>${sub}</p></div>
<div class="scr"><img src="file://${shot}"></div></body></html>`;
    const tmp = path.join(BUILD, name + '.html');
    fs.writeFileSync(tmp, html);
    const comp = await page.context().browser().newPage({ viewport: { width: 1080, height: 2160 }, deviceScaleFactor: 1 });
    await comp.goto('file://' + tmp);
    await comp.evaluate(() => document.fonts.ready);
    await comp.waitForTimeout(150);
    await comp.screenshot({ path: path.join(PLAY_OUT, 'phone', name + '.png') });
    await comp.close();
  }

  /* Tablets: Play asks for 16:9 / 9:16 and no extra text, so these are the app layouts at tablet size, no captions.
     7-inch: 1080 x 1920 portrait (576 x 1024 dp at 1.875). 10-inch: 1620 x 2880 portrait (810 x 1440 dp at 2).
     The landscape ride screen is 1920 x 1080 / 2880 x 1620 (the handlebar mount layout). */
  const wide = '.nav{width:100%!important}body{width:auto!important}.page{max-width:none}';
  const TAB = [
    ['01_ride_landscape', 'hud_landscape', false, 'land'],
    ['02_home', 'home', true, 'port'],
    ['03_explore', 'explore', true, 'port'],
    ['04_community', 'community', false, 'port'],
    ['05_profile', 'profile', true, 'port'],
  ];
  for (const [suffix, mock, light, orient] of TAB) {
    for (const [dir, pre, pw, ph, dpr] of [['tablet_7in', 'tablet7_', 576, 1024, 1.875], ['tablet_10in', 'tablet10_', 810, 1440, 2]]) {
      const name = pre + suffix;
      if (only && !name.includes(only)) continue;
      const out = path.join(PLAY_OUT, dir, name + '.png');
      const p2 = await page.context().browser().newPage({ deviceScaleFactor: dpr });
      if (orient === 'land') {
        // The HUD landscape mock is laid out at 915 x 412; scale it to fill a 16:9 page (no stretching).
        await shootLandscape(p2, mock, ph, pw, out);
      } else {
        await shootMock(p2, mock, { light, w: pw, h: ph, dpr, out, css: wide });
      }
      await p2.close();
    }
  }

  /* Feature graphic 1024 x 500: v3.58 helmet wordmark + motto on a convoy illustration; no device imagery, no badges. */
  if (!only || 'feature'.includes(only)) {
    const wordmark = path.join(ROOT, 'docs', 'brand', 'svg', 'coroute-wordmark-on-dark.svg');
    const riders = ['#79A8E8', '#E9A55B', '#D88AA6', '#6CC08B', '#FFFFFF'];
    const road = 'M560 540 C 640 420, 700 380, 790 330 S 940 220, 1060 120';
    const fhtml = `<!doctype html><html><head><meta charset="utf-8"><style>
@font-face{font-family:Manrope;src:${font};font-weight:200 800}
*{margin:0}body{width:1024px;height:500px;overflow:hidden;font-family:Manrope,sans-serif;background:#1E5F6D;position:relative}
svg.bg{position:absolute;inset:0}
.txt{position:absolute;left:64px;top:96px;color:#fff}
.brand img{height:70px;width:auto;display:block;margin-left:-6px}
h1{font-size:62px;font-weight:800;line-height:1.05;letter-spacing:-1.5px;margin-top:40px}
h1 span{color:#9ED3DD}
p{font-size:22px;margin-top:18px;color:#D6F0F3;font-weight:500}
</style></head><body>
<svg class="bg" viewBox="0 0 1024 500"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#236878"/><stop offset="1" stop-color="#174B57"/></linearGradient></defs>
<rect width="1024" height="500" fill="url(#g)"/>
<path d="M430 500 L 520 330 L 610 400 L 720 250 L 820 340 L 920 200 L 1024 290 L 1024 500 Z" fill="#2B7A8C" opacity=".55"/>
<path d="M380 500 L 500 400 L 640 470 L 780 360 L 900 430 L 1024 380 L 1024 500 Z" fill="#14424C" opacity=".8"/>
<circle cx="900" cy="96" r="34" fill="#E9A55B" opacity=".9"/>
<path d="${road}" fill="none" stroke="#0F3640" stroke-width="44" stroke-linecap="round"/>
<path d="${road}" fill="none" stroke="#E7E3DC" stroke-width="3" stroke-dasharray="14 14" opacity=".7"/>
<path d="${road}" fill="none" stroke="#5FB3C4" stroke-width="6" stroke-linecap="round" opacity=".9" stroke-dasharray="0 0"/>
${[0.18, 0.32, 0.46, 0.6, 0.74].map((t, k) => `<g data-t="${t}"><circle r="16" fill="${riders[k]}" stroke="#0F3640" stroke-width="4"/><circle r="28" fill="none" stroke="${riders[k]}" stroke-width="2" opacity=".45"/></g>`).join('')}
</svg>
<div class="txt"><div class="brand"><img src="file://${wordmark}" alt="CoRoute"></div><h1>Ride together.<br><span>Stay safe.</span></h1><p>Group and solo riding safety</p></div>
<script>const p=document.querySelector('path[stroke="#5FB3C4"]');const L=p.getTotalLength();document.querySelectorAll('g[data-t]').forEach(g=>{const q=p.getPointAtLength(L*g.dataset.t);g.setAttribute('transform','translate('+q.x+' '+q.y+')')});</script>
</body></html>`;
    const tmp = path.join(BUILD, 'feature.html');
    fs.writeFileSync(tmp, fhtml);
    const p3 = await page.context().browser().newPage({ viewport: { width: 1024, height: 500 }, deviceScaleFactor: 1 });
    await p3.goto('file://' + tmp);
    await p3.evaluate(() => document.fonts.ready);
    await p3.waitForTimeout(150);
    await p3.screenshot({ path: path.join(PLAY_OUT, 'feature_graphic_1024x500.png') });
    await p3.close();
  }

  /* Icon: the existing full-square store icon (store/icon_512.png, the launcher art without the rounded mask; Play
     applies its own mask), saved as the 32-bit PNG Play asks for. Not redrawn. */
  py(`
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGBA')
if im.size != (512, 512): im = im.resize((512, 512), Image.LANCZOS)
im.save(sys.argv[2], optimize=True)
`, path.join(ROOT, 'store', 'icon_512.png'), path.join(PLAY_OUT, 'icon_512.png'));

  // Screenshots and the feature graphic: 24-bit PNG, no alpha (Play requirement).
  py(`
import sys, glob
from PIL import Image
for f in glob.glob(sys.argv[1] + '/**/*.png', recursive=True):
    if f.endswith('icon_512.png'): continue
    im = Image.open(f)
    if im.mode != 'RGB': im.convert('RGB').save(f, optimize=True)
    else: im.save(f, optimize=True)
`, PLAY_OUT);
}

async function shootLandscape(page, mock, W, H, out) {
  await page.setViewportSize({ width: W, height: H });
  await page.goto('file://' + path.join(BUILD, mock + '.html'));
  // The landscape HUD mock is laid out at 915 x 412 dp. On a 16:9 tablet it becomes 915 x 515 dp (the side panel and
  // the map stretch down), scaled to the window width.
  await page.evaluate(([status, W]) => {
    document.querySelectorAll('.status').forEach((s) => { s.innerHTML = status; });
    const sc = document.querySelector('.screen');
    const H = Math.round(915 * 9 / 16);
    sc.style.height = H + 'px';
    sc.querySelectorAll('div[style*="left:400px"] > svg').forEach((m) => {
      m.setAttribute('preserveAspectRatio', 'xMidYMid slice');
      m.style.width = '100%'; m.style.height = '100%';
      m.removeAttribute('height'); m.removeAttribute('width');
    });
    sc.querySelectorAll('[style*="top:318px"]').forEach((e) => { e.style.top = (318 + H - 412) + 'px'; });
    sc.querySelectorAll('[style*="top:176px"]').forEach((e) => { e.style.top = (176 + (H - 412) / 2) + 'px'; });
    sc.style.transformOrigin = '0 0';
    sc.style.transform = 'scale(' + (W / 915) + ')';
  }, [STATUS, W]);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(120);
  await page.screenshot({ path: out });
}

(async () => {
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  try {
    if (what === 'all' || what === 'web') {
      const page = await browser.newPage({ deviceScaleFactor: 636 / 412 });
      for (const [name, [mock, light]] of Object.entries(WEB)) {
        if (only && !name.includes(only)) continue;
        const png = path.join(BUILD, 'web_' + name + '.png');
        await shootMock(page, mock, { light, w: 412, h: 898, out: png });
        py(ENCODE, png, WEB_OUT, name);
      }
      await page.close();
      console.log('website screenshots ->', WEB_OUT);
    }
    if (what === 'all' || what === 'play') {
      const page = await browser.newPage({ deviceScaleFactor: 3 });
      await play(page);
      await page.close();
      console.log('Play graphics ->', PLAY_OUT);
    }
  } finally {
    await browser.close();
    fs.rmSync(BUILD, { recursive: true, force: true });
  }
})().catch((e) => { console.error(e); process.exit(1); });
