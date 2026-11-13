#!/usr/bin/env node
'use strict';
/**
 * Round 4 road & safety intelligence smoke test (docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md). Boots a test-mode
 * gateway in-process (MemorySoda), seeds consenting test riders' signals THROUGH THE REAL PIPELINE (events, per-ride
 * rows, aggregation, crash brain training), then drives /admin (Road & safety intelligence pages) and /account
 * (Help make roads safer) in headless Chromium with Playwright, light and dark, and fails on page errors or CSP
 * violations. Seeded data is synthetic test data for this local run only (never in production).
 *
 *   node tool/intel_admin_smoke.js [screenshot dir]
 */
process.env.NODE_ENV = 'test';
process.env.ADMIN_MFA_ENFORCE = 'off';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'intel.smoke@coroute.test';
process.env.PUBLIC_ORIGIN = process.env.PUBLIC_ORIGIN || 'https://coroute.example';
process.env.CRASH_BRAIN_MODE = process.env.CRASH_BRAIN_MODE || 'approved';

const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

const GW = path.join(__dirname, '..', 'gateway');
const OUT = path.resolve(process.argv[2] || path.join(require('os').tmpdir(), 'intel'));
fs.mkdirSync(OUT, { recursive: true });
const PASSWORD = 'Password#123';
const DAY = 86400000;

function loadPlaywright() {
  const tries = [path.join(GW, 'node_modules', 'playwright')];
  try { tries.push(path.join(execSync('npm root -g').toString().trim(), 'playwright')); } catch { /* no npm */ }
  for (const p of tries) { try { return require(p); } catch { /* next */ } }
  throw new Error('Playwright not found');
}

function rng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

async function boot() {
  const { createApp } = require(path.join(GW, 'src/app'));
  const { MemorySoda } = require(path.join(GW, 'src/oracle/memory_soda'));
  const gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${gw.server.address().port}`;
  const api = async (method, p, body, token) => {
    const res = await fetch(`${origin}/api${p}`, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, json: await res.json().catch(() => ({})) };
  };
  let n = 0;
  const register = async (name, email) => {
    n++;
    const r = await api('POST', '/auth/register', { name, email, password: PASSWORD, phone: `+9198765${String(20000 + n).slice(-5)}`, vehicleType: 'Motorcycle', vehicleNo: `KA05AB${1000 + n}`, emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' });
    if (r.status !== 201) throw new Error('register failed: ' + JSON.stringify(r.json));
    return r.json;
  };
  return { gw, origin, api, register };
}

async function seed({ gw, api, register }) {
  const admin = await register('Intel Smoke Admin', 'intel.smoke@coroute.test');
  const rider = await register('Asha Rao', 'asha.rao@coroute.test');
  await api('PUT', '/intel/consent', { on: true, source: 'web' }, rider.token);
  const intel = gw.intel;
  const gh = require(path.join(GW, 'src/intel/geohash'));
  const { riderHash } = require(path.join(GW, 'src/intel/privacy'));
  const M = require(path.join(GW, 'src/intel/math'));
  const r = rng(42);
  const now = Date.now();
  const riders = Array.from({ length: 14 }, (_, i) => `smoke-rider-${i}`);
  for (const id of riders) await intel.consent.set(id, true);
  // Hazards around Bengaluru, Mysuru road and the Hyderabad ORR (hard braking, swerves, a crash cluster).
  const spots = [
    [12.9352, 77.6245, 'hard_brake', 0], [12.9719, 77.6412, 'hard_brake', 2], [12.9081, 77.5896, 'swerve', 4], [12.8465, 77.4951, 'crash', 6],
    [12.7598, 77.3201, 'hard_brake', 6], [12.6201, 77.0902, 'skid', 6], [12.3142, 76.6553, 'hard_brake', 2], [13.0287, 77.5896, 'swerve', 0],
    [17.4401, 78.3489, 'hard_brake', 2], [17.3616, 78.4747, 'crash', 4], [17.4933, 78.3915, 'hard_brake', 6],
  ];
  for (const [i, id] of riders.entries()) {
    const ev = [];
    for (const [lat, lng, type, hb] of spots) {
      if (r() < 0.75) ev.push({ type, gh: gh.encode(lat + (r() - 0.5) * 0.0004, lng + (r() - 0.5) * 0.0004, 7), hb, sb: 2, ts: now - Math.floor(r() * 20) * DAY - (r() < 0.6 ? 0 : 3) * 3600000 });
    }
    // Potholes on two stretches.
    for (let k = 0; k < 6; k++) if (r() < 0.8) ev.push({ type: k % 3 ? 'pothole' : 'rough', gh: gh.encode(12.88 - k * 0.012, 77.55 - k * 0.01, 7), hb: 5, sb: 2, ts: now - Math.floor(r() * 10) * DAY, conf: 0.9 });
    void i;
    await intel.ingestEvents(id, ev, { now });
  }
  await intel.flushRaw();
  // Per-ride rows (what the gateway writes from telemetry): a ghat road (Bannerghatta to Kanakapura hills), a highway,
  // and stops at two fuel stations / a dhaba.
  const docs = [];
  for (const id of riders) {
    const c = [];
    for (let k = 0; k < 18; k++) { const g6 = gh.encode(12.75 - k * 0.012, 77.45 - k * 0.006, 6); c.push([g6, 2, 1300, 160, k < 9 ? 380 : 15, 160 * 38]); }
    for (let k = 0; k < 25; k++) { const g6 = gh.encode(12.95 + k * 0.03, 77.62 + k * 0.012, 6); c.push([g6, 2, 1500, 95, 8, 95 * 62]); }
    const s = [[gh.encode(12.8467, 77.4953, 7), 14, 10], [gh.encode(13.2281, 77.7135, 7), 22, 13], [gh.encode(12.6205, 77.0905, 7), 9, 16]];
    const m = M.monthKey(now);
    docs.push({ k: 'ride', rh: riderHash(intel.key, id, m), m, t: now - 2 * DAY, te: now - 2 * DAY + 3 * 3600000, p: 0, d: { c, s } });
  }
  await gw.soda.insertMany('intel_raw', docs);
  for (let i = 0; i < 5; i++) await intel.aggregate();
  // Tag two stops as fuel / food (normally matched from cached places by the daily job).
  const stops = await gw.soda.query('intel_cells', { layer: 'st' }, { limit: 10 });
  for (const [i, row] of stops.entries()) await gw.soda.replace('intel_cells', row.key, { ...row.value, place: i === 0 ? { name: 'Indian Oil, Kanakapura Rd', cat: 'fuel' } : i === 1 ? { name: 'Highway Dhaba', cat: 'food' } : null });
  intel.cache.clear();
  // Crash brain: 320 labelled alarms (synthetic) and a training run.
  const CB = require(path.join(GW, 'src/intel/crash_brain'));
  const train = [];
  for (let i = 0; i < 320; i++) {
    const real = r() < 0.28;
    const dm = ['samsung SM-A515F', 'Redmi Note 12', 'vivo Y21', 'OnePlus Nord'][i % 4];
    const f = CB.cleanFeatures({ pg: real ? 5 + r() * 6 : 4 + r() * 0.55, dur: real ? 120 : 20, v: 20 + r() * 50, still: real ? 30 : r() * 6, rot: real ? 4 : 0.6, mount: r() < 0.3 ? 'pocket' : 'mounted', path: 'impact', thr: 4, dm });
    train.push({ id: `smoke-${i}`, m: M.monthKey(now), f, y: real ? 1 : 0, g: CB.modelGroup(dm), ...(i % 3 === 0 ? { sh: { p: real ? 0.9 : 0.1, scale: 1.15, fires: real || f.pg >= 4.6, v: 1 } } : {}) });
  }
  await gw.soda.insertMany('intel_crash_train', train);
  await intel.trainCrashBrain();
  await intel.daily();
  return { admin, rider };
}

(async () => {
  const env = await boot();
  const { origin } = env;
  const { rider } = await seed(env);
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  const problems = [];
  const shots = [];
  for (const theme of ['light', 'dark']) {
    const ctx = await browser.newContext({ viewport: { width: 1360, height: 900 }, colorScheme: theme, deviceScaleFactor: 1 });
    // Tiles: the OSM tile server is not reachable from here; answer tile requests with a plain grey tile.
    await ctx.route('https://tile.openstreetmap.org/**', (route) => route.fulfill({ status: 200, contentType: 'image/png',
      body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mN89+7dfwAJ2gPdHqvlNAAAAABJRU5ErkJggg==', 'base64') }));
    const page = await ctx.newPage();
    page.on('pageerror', (e) => problems.push(`[${theme}] page error: ${e.message}`));
    page.on('console', (m) => { if (m.type() === 'error' && !/status of 40[134]/.test(m.text())) problems.push(`[${theme}] console: ${m.text()}`); });
    const shot = async (name, full = false) => { const f = path.join(OUT, `${name}-${theme}.png`); await page.waitForTimeout(600); await page.screenshot({ path: f, fullPage: full }); shots.push(f); };
    await page.goto(`${origin}/admin`);
    await page.waitForSelector('#signin:not([hidden])');
    await page.fill('#signin-id', 'intel.smoke@coroute.test'); await page.fill('#signin-pw', PASSWORD); await page.click('#signin-btn');
    await page.waitForSelector('#shell:not([hidden])');
    for (const [i, s] of ['hazards', 'crashbrain', 'riderstops', 'roadquality', 'twisty', 'dangertimes', 'dataprivacy'].entries()) {
      await page.evaluate((x) => { location.hash = '#/' + x; }, s);
      await page.waitForSelector('#view .page-head');
      await page.waitForFunction(() => !document.querySelector('#view .loading'), null, { timeout: 8000 }).catch(() => problems.push(`[${theme}] ${s}: still loading`));
      const err = await page.$('#view .banner--bad');
      if (err && s !== 'dataprivacy') problems.push(`[${theme}] ${s}: ${await err.textContent()}`);
      await shot(`${String(i + 1).padStart(2, '0')}-${s}`, s === 'crashbrain' || s === 'dataprivacy');
    }
    // Website /account: the consent card.
    const p2 = await ctx.newPage();
    p2.on('pageerror', (e) => problems.push(`[${theme}] account page error: ${e.message}`));
    await p2.goto(`${origin}/`);
    await p2.evaluate((t) => sessionStorage.setItem('coroute_session', t), rider.token);
    await p2.goto(`${origin}/account#roads`);
    await p2.waitForFunction(() => { const b = document.getElementById('ac-roads-on'); return b && !b.disabled; }, null, { timeout: 8000 }).catch(() => problems.push(`[${theme}] account: consent box did not load`));
    const checked = await p2.$eval('#ac-roads-on', (b) => b.checked).catch(() => null);
    if (checked !== true) problems.push(`[${theme}] account: consent should show on (was ${checked})`);
    await p2.$eval('#roads', (el) => el.scrollIntoView({ block: 'start' }));
    await p2.waitForTimeout(500);
    const f = path.join(OUT, `08-account-roads-${theme}.png`); await p2.screenshot({ path: f }); shots.push(f);
    // Mobile width of the account card.
    await p2.setViewportSize({ width: 390, height: 844 });
    await p2.$eval('#roads', (el) => el.scrollIntoView({ block: 'start' }));
    await p2.waitForTimeout(400);
    const f2 = path.join(OUT, `09-account-roads-mobile-${theme}.png`); await p2.screenshot({ path: f2 }); shots.push(f2);
    await ctx.close();
  }
  await browser.close();
  await env.gw.shutdown().catch(() => {});
  console.log(`${shots.length} screenshots in ${OUT}`);
  if (problems.length) { console.error(problems.join('\n')); process.exit(1); }
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
