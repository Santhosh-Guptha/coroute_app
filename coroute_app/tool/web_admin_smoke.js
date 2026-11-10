#!/usr/bin/env node
'use strict';
/**
 * 3.55 web admin smoke test (docs/features_355/web_admin.md). Boots a test-mode gateway in-process
 * (MemorySoda, NODE_ENV=test), seeds an admin, a rider, coupons, orders and memberships, then drives
 * /admin in headless Chromium with Playwright: signs in, opens every section, creates a coupon in the
 * UI, creates a template from a starter, exports a PNG (checks it is a real, full-size PNG) and takes
 * light and dark screenshots of each section. Fails on any page error or CSP violation.
 *
 *   node tool/web_admin_smoke.js [screenshot dir]
 *
 * Playwright is resolved from the gateway's node_modules, then the global npm root (never installed here).
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'smoke.admin@coroute.test';
process.env.PUBLIC_ORIGIN = process.env.PUBLIC_ORIGIN || 'https://coroute.example';

const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

const GW = path.join(__dirname, '..', 'gateway');
const OUT = path.resolve(process.argv[2] || path.join(require('os').tmpdir(), 'webadmin'));
fs.mkdirSync(OUT, { recursive: true });

function loadPlaywright() {
  const tries = [path.join(GW, 'node_modules', 'playwright')];
  try { tries.push(path.join(execSync('npm root -g').toString().trim(), 'playwright')); } catch { /* no npm */ }
  for (const p of tries) { try { return require(p); } catch { /* next */ } }
  throw new Error('Playwright not found (looked in ' + tries.join(', ') + ')');
}

const DAY = 86400000;
const PASSWORD = 'Password#123';

async function bootGateway() {
  const { createApp } = require(path.join(GW, 'src/app'));
  const { MemorySoda } = require(path.join(GW, 'src/oracle/memory_soda'));
  const quiet = { info() {}, warn() {}, error() {} };
  const gw = await createApp({ soda: new MemorySoda(), logger: quiet });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${gw.server.address().port}`;
  const api = async (method, p, body, token) => {
    const res = await fetch(`${origin}/api${p}`, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, json: await res.json().catch(() => ({})) };
  };
  let n = 0;
  const register = async (name, email) => {
    n++;
    const r = await api('POST', '/auth/register', { name, email, password: PASSWORD, phone: `+9198765${String(10000 + n).slice(-5)}`, vehicleType: 'Motorcycle', vehicleNo: `TS09AB${1000 + n}`, emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' });
    if (r.status !== 201) throw new Error('register failed: ' + JSON.stringify(r.json));
    return r.json;
  };
  return { gw, origin, api, register };
}

async function seed({ gw, api, register }) {
  const admin = await register('Smoke Admin', 'smoke.admin@coroute.test');
  const riders = [];
  for (const [i, nm] of ['Asha Rao', 'Vikram Singh', 'Meera Iyer', 'Rahul Nair', 'Kiran Das'].entries()) riders.push(await register(nm, `rider${i}@coroute.test`));
  const now = Date.now();
  for (const c of [
    { code: 'DIWALI40', name: 'Diwali 40', campaignName: 'Festive 2026', discountType: 'percentage', discountValue: 40, maxDiscountCap: 200, applicableTiers: ['group_small', 'group_large'], validFrom: now - 10 * DAY, expiresAt: now + 20 * DAY, maxUsageTotal: 500 },
    { code: 'CREW100', name: 'Crew ₹100 off', discountType: 'fixed', discountValue: 100, applicableTiers: ['group_large'], validFrom: now - 30 * DAY, expiresAt: now + 60 * DAY, maxUsageTotal: 200 },
    { code: 'MONSOON20', name: 'Monsoon 20', discountType: 'percentage', discountValue: 20, applicableTiers: ['all'], validFrom: now - 120 * DAY, expiresAt: now - 30 * DAY, maxUsageTotal: 100 },
  ]) {
    const r = await api('POST', '/admin/coupons', c, admin.token);
    if (r.status !== 201) throw new Error('coupon seed failed: ' + JSON.stringify(r.json));
  }
  await api('POST', '/admin/coupons/CREW100/pause', {}, admin.token);
  // Orders over the last 11 months (live), a few test-mode ones, one failed, one refunded.
  const repo = gw.repo;
  let k = 0;
  for (let m = 0; m < 330; m += 4) {
    const r = riders[k % riders.length];
    const large = k % 3 === 0;
    const at = now - m * DAY - (k % 5) * 3600000;
    await repo.saveRazorpayOrder({ orderId: `order_smoke${k}`, userId: r.user.userId, status: k % 17 === 5 ? 'FAILED' : 'PAID', mode: k % 11 === 3 ? 'test' : 'live', category: large ? 'group_large' : 'group_small', planTier: large ? 'group_large' : 'group_small', billingCycle: 'monthly', amountInPaise: (large ? 99900 : 49900) - (k % 4 === 0 ? 20000 : 0), couponCode: k % 4 === 0 ? 'DIWALI40' : null, discountAmount: k % 4 === 0 ? 200 : 0, paymentId: `pay_smoke${k}`, createdAt: at, paidAt: at, ...(k === 2 ? { refundedAmountInPaise: 49900, fullyRefunded: true, refundStatus: 'PROCESSED', refundReason: 'Duplicate purchase' } : {}) });
    if (k % 4 === 0) await repo.saveCouponRedemption({ redemptionId: `red_smoke${k}`, couponCode: k % 8 === 0 ? 'DIWALI40' : 'MONSOON20', userId: r.user.userId, status: 'SUCCESS', discountAmount: 200, finalAmount: large ? 799 : 299, redeemedAt: at });
    k++;
  }
  for (const [i, r] of riders.entries()) {
    await repo.saveMembership({ membershipId: `mem_smoke${i}`, ownerUserId: r.user.userId, category: i % 2 ? 'group_large' : 'group_small', status: 'ACTIVE', priceInr: i % 2 ? 999 : 499, validFrom: now - (40 + i * 50) * DAY, validUntil: now + (10 + i * 5) * DAY, capacity: i % 2 ? 12 : 6, members: {} });
  }
  return { admin, riders };
}

function pngSize(buf) {
  if (buf.length < 24 || buf.toString('ascii', 1, 4) !== 'PNG') return null;
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

(async () => {
  const env = await bootGateway();
  const { origin } = env;
  await seed(env);
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  const problems = [];
  const shots = [];
  const results = {};

  async function run(theme, viewport, full) {
    const ctx = await browser.newContext({ viewport, colorScheme: theme, acceptDownloads: true, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => problems.push(`[${theme}] page error: ${e.message}`));
    page.on('console', (m) => { if (m.type() === 'error' && !/status of 40[134]/.test(m.text())) problems.push(`[${theme}] console: ${m.text()}`); });
    const tag = `${theme}${viewport.width < 1200 ? '-tablet' : ''}`;
    const shot = async (name) => { const f = path.join(OUT, `${name}-${tag}.png`); await page.waitForTimeout(250); await page.screenshot({ path: f, fullPage: false }); shots.push(f); };

    await page.goto(`${origin}/admin`);
    await page.waitForSelector('#signin:not([hidden])');
    // A rider cannot sign in to the console.
    if (full) {
      await page.fill('#signin-id', 'rider0@coroute.test'); await page.fill('#signin-pw', PASSWORD); await page.click('#signin-btn');
      await page.waitForSelector('#signin-error:not([hidden])');
      const msg = await page.textContent('#signin-error');
      if (!/not a CoRoute administrator/.test(msg)) problems.push('rider sign-in message: ' + msg);
    }
    await shot('00-signin');
    await page.fill('#signin-id', 'smoke.admin@coroute.test'); await page.fill('#signin-pw', PASSWORD); await page.click('#signin-btn');
    await page.waitForSelector('#shell:not([hidden])');

    // Payments
    await page.waitForSelector('#view tbody tr.is-link');
    await page.waitForSelector('#view .tile__value');
    await shot('01-payments');
    if (full) {
      await page.click('#view tbody tr.is-link');
      await page.waitForSelector('.dialog');
      await shot('01b-payment-detail');
      await page.keyboard.press('Escape');
      const [dl] = await Promise.all([page.waitForEvent('download'), page.click('text=Export CSV')]);
      const csv = fs.readFileSync(await dl.path(), 'utf8');
      results.csvRows = csv.trim().split('\n').length - 1;
      if (results.csvRows < 10) problems.push('CSV export has only ' + results.csvRows + ' rows');
    }

    // Plans & pricing
    await page.click('#nav a[data-section="plans"]');
    await page.waitForSelector('text=Payment gateway');
    await page.waitForSelector('text=Audit log');
    await shot('02-plans');

    // Coupons
    await page.click('#nav a[data-section="coupons"]');
    await page.waitForSelector('#view tbody tr[data-code="DIWALI40"]');
    if (full) {
      await page.click('text=New coupon');
      await page.waitForSelector('.dialog');
      const dlg = page.locator('.dialog');
      await dlg.locator('label:has-text("Code") input').fill('SMOKE25');
      await dlg.locator('label:has-text("Display name") input').fill('Smoke test 25');
      await dlg.locator('label:has-text("Value") input').fill('25');
      await shot('03b-coupon-new');
      await dlg.locator('button:has-text("Create coupon")').click();
      await page.waitForSelector('#view tbody tr[data-code="SMOKE25"]');
      results.couponCreated = true;
    }
    await shot('03-coupons');

    // Revenue
    await page.click('#nav a[data-section="revenue"]');
    await page.waitForSelector('#view .chart svg');
    await shot('04-revenue');
    if (full) {
      const bar = page.locator('#view .chart .hit').nth(20);
      await bar.hover();
      await page.waitForSelector('.chart__tip:not([hidden])');
      await shot('04b-revenue-tooltip');
    }

    // Marketing studio
    await page.click('#nav a[data-section="marketing"]');
    if (full) {
      await page.goto(`${origin}/admin#/marketing/new?coupon=SMOKE25`);
      await page.waitForSelector('.starter[data-starter="festive"] canvas');
      await page.waitForTimeout(400);
      await shot('05b-marketing-starters');
      await page.click('.starter[data-starter="festive"]');
      await page.waitForSelector('.editor canvas');
      await page.waitForTimeout(500);
      results.templateCreated = true;
      // Select the coupon layer on the canvas and drag it a little (undo afterwards).
      const box = await page.locator('.stage__area canvas').boundingBox();
      await page.mouse.click(box.x + box.width * 0.5, box.y + box.height * 0.62);
      await page.mouse.down(); await page.mouse.move(box.x + box.width * 0.52, box.y + box.height * 0.6, { steps: 4 }); await page.mouse.up();
      await shot('05c-marketing-editor-selected');
      await page.click('button:has-text("Undo")');
      await page.click('button:has-text("Save")');
      await page.waitForSelector('.chip--ok:has-text("Saved")');
      const [dl] = await Promise.all([page.waitForEvent('download'), page.click('button:has-text("Export PNG")')]);
      const buf = fs.readFileSync(await dl.path());
      const size = pngSize(buf);
      results.png = { bytes: buf.length, ...size, name: dl.suggestedFilename() };
      fs.copyFileSync(await dl.path(), path.join(OUT, 'export-' + dl.suggestedFilename()));
      if (!size || size.width !== 1080 || size.height !== 1080 || buf.length < 20000) problems.push('PNG export looks wrong: ' + JSON.stringify(results.png));
      const [d2] = await Promise.all([page.waitForEvent('download'), page.click('button:has-text("All sizes")')]);
      const s2 = pngSize(fs.readFileSync(await d2.path()));
      fs.copyFileSync(await d2.path(), path.join(OUT, 'export-' + d2.suggestedFilename()));
      results.allSizesFirst = s2;
      await page.waitForTimeout(1500);
      await page.click('a:has-text("← Templates")');
    }
    await page.waitForSelector('.tcard canvas, .empty');
    await page.waitForTimeout(400);
    await shot('05-marketing');
    if (!full) {
      await page.click('.tcard__thumb');
      await page.waitForSelector('.editor canvas');
      await page.waitForTimeout(500);
      await shot('05c-marketing-editor');
    }
    // Sign out returns to the sign-in card.
    await page.click('#signout');
    await page.waitForSelector('#signin:not([hidden])');
    await ctx.close();
  }

  try {
    await run('light', { width: 1440, height: 900 }, true);
    await run('dark', { width: 1440, height: 900 }, false);
    await run('light', { width: 1024, height: 768 }, false);
  } catch (e) {
    problems.push('step failed: ' + (e && e.message));
  }
  await browser.close();
  await env.gw.shutdown();
  console.log(JSON.stringify({ origin, results, screenshots: shots.length, out: OUT }, null, 2));
  if (problems.length) { console.error('PROBLEMS:\n' + problems.join('\n')); process.exit(1); }
  console.log('web admin smoke: OK');
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
