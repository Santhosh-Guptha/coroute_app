#!/usr/bin/env node
'use strict';
/**
 * 3.57 round 3 web console smoke test (docs/features_355/web_riders_admin.md, web_admin.md, email_marketing.md).
 * Boots a test-mode gateway in-process (MemorySoda, a fake SMTP transport), seeds an admin, riders with rides,
 * plans, coupons and orders, then drives Chromium with Playwright:
 *   admin: Overview, global search, Riders list (search / filter), rider page, Assign plan (dialog + preview + e-mail),
 *          Give a coupon (dialog, code dialog), the E-mail wizard for one rider (template -> check -> send) and for an
 *          audience (Festive offer + coupon -> check -> schedule -> status), Push, Settings, Audit log
 *   rider: /account (profile, plan, personal coupons, payments, rides, clubs, e-mails, security)
 * Screenshots in light and dark, desktop (1440x900) and tablet (1024x768). Fails on any page error, CSP violation
 * or a step that does not complete.
 *
 *   node tool/web_console_smoke.js [screenshot dir]
 *
 * Playwright is resolved from the gateway's node_modules, then the global npm root (never installed here).
 */
process.env.NODE_ENV = 'test';
// 3.57: these smoke runs check the console sections, not 2-step sign-in (tool/security_smoke.js does).
process.env.ADMIN_MFA_ENFORCE = 'off';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'console.admin@coroute.test';
process.env.PUBLIC_ORIGIN = process.env.PUBLIC_ORIGIN || 'https://coroute.example';
process.env.MAIL_POSTAL_ADDRESS = process.env.MAIL_POSTAL_ADDRESS || 'CoRoute, 12 MG Road, Bengaluru 560001, India';
process.env.PAYMENTS_ENABLED = 'true';

const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

const GW = path.join(__dirname, '..', 'gateway');
const OUT = path.resolve(process.argv[2] || path.join(require('os').tmpdir(), 'webconsole'));
fs.mkdirSync(OUT, { recursive: true });
const DAY = 86400000;
const PASSWORD = 'Password#123';

function loadPlaywright() {
  const tries = [path.join(GW, 'node_modules', 'playwright')];
  try { tries.push(path.join(execSync('npm root -g').toString().trim(), 'playwright')); } catch { /* no npm */ }
  for (const p of tries) { try { return require(p); } catch { /* next */ } }
  throw new Error('Playwright not found (looked in ' + tries.join(', ') + ')');
}

async function bootGateway() {
  const { createApp } = require(path.join(GW, 'src/app'));
  const { MemorySoda } = require(path.join(GW, 'src/oracle/memory_soda'));
  const quiet = { info() {}, warn() {}, error() {} };
  const mails = [];
  const gw = await createApp({ soda: new MemorySoda(), logger: quiet, mailTransport: { async sendMail(m) { mails.push(m); return { messageId: `<c${mails.length}@smoke>` }; } } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${gw.server.address().port}`;
  const api = async (method, p, body, token) => {
    const res = await fetch(`${origin}/api${p}`, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, json: await res.json().catch(() => ({})) };
  };
  let n = 0;
  const register = async (name, email, extra = {}) => {
    n++;
    const r = await api('POST', '/auth/register', { name, email, password: PASSWORD, phone: `+9198765${String(10000 + n).slice(-5)}`, vehicleType: 'Motorcycle', vehicleNo: `TS09AB${1000 + n}`, emergencyContact: '+919000000001', emergencyContactName: 'Family Contact', ...extra });
    if (r.status !== 201) throw new Error('register failed: ' + JSON.stringify(r.json));
    return r.json;
  };
  return { gw, origin, api, register, mails };
}

async function seed({ gw, api, register }) {
  const admin = await register('Console Admin', 'console.admin@coroute.test');
  const names = ['Asha Rao', 'Vikram Singh', 'Meera Iyer', 'Rahul Nair', 'Kiran Das', 'Priya Menon', 'Arjun Reddy', 'Neha Shah', 'Farhan Ali', 'Divya Pillai', 'Sanjay Gupta', 'Lakshmi Bhat'];
  const riders = [];
  for (const [i, nm] of names.entries()) riders.push(await register(nm, `${nm.toLowerCase().replace(/\s+/g, '.')}@coroute.test`, i === 7 ? { emergencyContact: '+919000000002' } : {}));
  const repo = gw.repo;
  const now = Date.now();
  // One rider without an emergency contact.
  const neha = await repo.findUserById(riders[7].user.userId);
  await repo.updateUser(neha.key, { emergencyContact: '', emergencyContactName: '' });
  for (const c of [
    { code: 'DIWALI40', name: 'Diwali 40', campaignName: 'Festive 2026', discountType: 'percentage', discountValue: 40, maxDiscountCap: 200, applicableTiers: ['group_small', 'group_large'], validFrom: now - 10 * DAY, expiresAt: now + 20 * DAY, maxUsageTotal: 500 },
    { code: 'CREW100', name: 'Crew ₹100 off', discountType: 'fixed', discountValue: 100, applicableTiers: ['group_large'], validFrom: now - 30 * DAY, expiresAt: now + 60 * DAY, maxUsageTotal: 200 },
  ]) {
    const r = await api('POST', '/admin/coupons', c, admin.token);
    if (r.status !== 201) throw new Error('coupon seed failed: ' + JSON.stringify(r.json));
  }
  let k = 0;
  for (let m = 0; m < 120; m += 3) {
    const r = riders[k % 6];
    const large = k % 3 === 0;
    const at = now - m * DAY - (k % 5) * 3600000;
    await repo.saveRazorpayOrder({ orderId: `order_c${k}`, userId: r.user.userId, status: 'PAID', mode: 'live', category: large ? 'group_large' : 'group_small', planTier: large ? 'group_large' : 'group_small', billingCycle: 'monthly', amountInPaise: large ? 99900 : 49900, paymentId: `pay_c${k}`, createdAt: at, paidAt: at, ...(k === 4 ? { refundedAmountInPaise: 49900, fullyRefunded: true, refundStatus: 'PROCESSED' } : {}) });
    k++;
  }
  for (const [i, r] of riders.slice(1, 5).entries()) {
    await repo.saveMembership({ membershipId: `mem_c${i}`, ownerUserId: r.user.userId, category: i % 2 ? 'group_large' : 'group_small', status: 'ACTIVE', priceInr: i % 2 ? 999 : 499, validFrom: now - 20 * DAY, validUntil: now + (6 + i * 9) * DAY, capacity: i % 2 ? 12 : 6, members: {} });
  }
  // Rides for a few riders (Asha has the most).
  const rides = ['Nandi Hills sunrise ride', 'Coffee run to Hoskote', 'Skandagiri night trek ride', 'Mysore highway day trip', 'Weekend loop', 'Kanakapura river ride'];
  let t = 0;
  for (const [ri, r] of riders.slice(0, 6).entries()) {
    for (let j = 0; j < 6 - ri; j++) {
      const end = now - (j * 4 + ri) * DAY - 3 * 3600000;
      await repo.saveTrip({ tripId: `TRIP-C${t++}-${r.user.userId}`, userId: r.user.userId, tripName: rides[(j + ri) % rides.length], totalDistanceKm: 40 + j * 23 + ri * 7, startTimeEpochMs: end - (90 + j * 25) * 60000, endTimeEpochMs: end, groupId: j % 2 ? null : `GRP${j}` });
    }
  }
  // Consent for two riders; Asha gets a personal code later in the UI.
  await api('PUT', '/web/marketing-consent', { offersEmail: true }, riders[1].token);
  await api('PUT', '/web/marketing-consent', { offersEmail: true }, riders[2].token);
  await gw.notifications.studio.setSettings({ quietStartHour: 0, quietEndHour: 0 });
  return { admin, riders };
}

(async () => {
  const env = await bootGateway();
  const { origin, api } = env;
  const { admin, riders } = await seed(env);
  const asha = riders[0];
  const ashaMe = (await api('GET', '/me', null, asha.token)).json;
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  const problems = [];
  const shots = [];
  const results = {};

  async function adminRun(theme, viewport, full) {
    const ctx = await browser.newContext({ viewport, colorScheme: theme, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    const tag = `${theme}${viewport.width < 1200 ? '-tablet' : ''}`;
    page.on('pageerror', (e) => problems.push(`[${tag}] page error: ${e.message}`));
    page.on('console', (m) => { if (m.type() === 'error' && !/status of 40[1349]/.test(m.text())) problems.push(`[${tag}] console: ${m.text()}`); });
    const shot = async (name, opts = {}) => { const f = path.join(OUT, `${name}-${tag}.png`); await page.waitForTimeout(opts.wait || 350); await page.screenshot({ path: f, fullPage: !!opts.full }); shots.push(f); };
    const nav = async (hash) => { await page.evaluate((x) => { location.hash = x; }, hash); };

    await page.goto(`${origin}/admin`);
    await page.waitForSelector('#signin:not([hidden])');
    await page.fill('#signin-id', 'console.admin@coroute.test'); await page.fill('#signin-pw', PASSWORD); await page.click('#signin-btn');
    await page.waitForSelector('#shell:not([hidden])');
    // Overview (the console opens on it)
    await page.waitForSelector('#view .chart svg');
    await shot('01-overview');
    if (viewport.width < 1200) {
      await page.click('#menu-btn');
      await page.waitForSelector('body.nav-open');
      await shot('01b-menu-drawer');
      await page.keyboard.press('Escape');
    }
    // Global search
    await page.click('#gsearch');
    await page.keyboard.type(ashaMe.username.slice(0, 5));
    await page.waitForSelector('#gsearch-list:not([hidden]) .gsearch__item');
    await shot('02-global-search');
    await page.keyboard.press('Escape');

    // Riders list
    await nav('#/riders');
    await page.waitForSelector('#view .rd-table tbody tr');
    await shot('03-riders-list');
    if (full) {
      await page.selectOption('select[aria-label="Emergency contact"]', 'no');
      await page.waitForFunction(() => document.querySelectorAll('#view .rd-table tbody tr').length === 1);
      results.filterEmergency = true;
      await page.selectOption('select[aria-label="Emergency contact"]', '');
      await page.fill('input[aria-label="Search riders"]', 'asha');
      await page.waitForFunction(() => document.querySelectorAll('#view .rd-table tbody tr').length === 1);
      results.search = true;
    }
    // Rider page
    await nav('#/riders/' + asha.user.userId);
    await page.waitForSelector('#view .rd-head h1');
    await shot('04-rider-page');
    if (full) await shot('04b-rider-page-full', { full: true });

    // Assign plan
    await page.click('button:has-text("Assign plan")');
    await page.waitForSelector('.dialog .rd-dialog');
    await page.fill('.dialog input[aria-label="Reason"]', 'Beta tester thank-you');
    await page.waitForFunction(() => { const f = document.querySelector('.dialog .rd-frame'); return f && f.getAttribute('src'); });
    await shot('05-assign-plan-dialog', { wait: 900 });
    if (full) {
      const before = env.mails.length;
      await page.click('.dialog button:has-text("Assign plan")');
      await page.waitForSelector('.toast:has-text("assigned until")');
      await page.waitForSelector('#view .rd-head .chip:has-text("Small Group")');
      results.assignedEmails = env.mails.length - before;
      if (results.assignedEmails !== 1) problems.push('assign plan sent ' + results.assignedEmails + ' e-mails');
    } else {
      await page.keyboard.press('Escape');
    }
    // Give a coupon
    await page.click('#view .rd-head button:has-text("Give a coupon")');
    await page.waitForSelector('.dialog .rd-dialog');
    await page.waitForFunction(() => { const s = document.querySelector('.dialog select[aria-label="Coupon"]'); return s && s.options.length && s.options[0].value; });
    await page.selectOption('.dialog select[aria-label="Coupon"]', 'DIWALI40');
    await page.fill('.dialog input[aria-label="Reason"]', 'Ride cancelled by us');
    await page.check('.dialog .rd-dialog label.check:has-text("E-mail it") input');
    await page.waitForSelector('.dialog .wz-service:not([hidden])');
    await page.check('.dialog .wz-service input[type="checkbox"]');
    await page.fill('.dialog input[aria-label="Service note"]', 'Asked on support chat #4411');
    await shot('06-coupon-dialog', { wait: 900 });
    if (full) {
      await page.click('.dialog button:has-text("Make the code")');
      await page.waitForSelector('.dialog .rd-code');
      results.couponCode = (await page.textContent('.dialog .rd-code .mono')).trim();
      await shot('06b-coupon-code');
      await page.click('.dialog button:has-text("Done")');
    } else {
      await page.keyboard.press('Escape');
    }

    // E-mail wizard for one rider
    await page.waitForSelector('#view .rd-head button:has-text("Send e-mail")');
    await page.click('#view .rd-head button:has-text("Send e-mail")');
    await page.waitForSelector('#view .wz-gallery .wz-tpl');
    await shot('07-wizard-step2-gallery');
    await page.click('#view .wz-tpl:has-text("Plan assigned")');
    await page.waitForSelector('#view .es-blocks');
    await shot('08-wizard-step2-editor');
    await page.click('#view button:has-text("Next: check and send")');
    await page.waitForSelector('#view .wz-ci.is-ok');
    await page.waitForFunction(() => !document.querySelector('#view .wz-ci.is-wait'));
    await page.waitForFunction(() => { const f = document.querySelector('#view .es-frame'); return f && f.getAttribute('src'); });
    await shot('09-wizard-step3-check', { wait: 1000 });
    if (full) {
      const before = env.mails.length;
      await page.click('#view .wz-check-grid button:has-text("Send now")');
      await page.waitForSelector('.dialog');
      await page.click('.dialog button:has-text("Send")');
      await page.waitForSelector('#view .wz-done');
      results.oneToOneSent = env.mails.length - before;
      await shot('10-wizard-sent');
    }

    // E-mail wizard for an audience
    await nav('#/email');
    await page.waitForSelector('#view .wz-steps');
    if (await page.isVisible('#view button:has-text("Choose another")')) await page.click('#view button:has-text("Choose another")');
    await page.waitForSelector('#view .wz-step');
    if (await page.isVisible('#view .wz-step button:has-text("Who")')) await page.click('#view .wz-step button:has-text("Who")');
    await page.waitForSelector('#view .wz-who');
    await page.click('#view .wz-card:has-text("An audience")');
    await page.waitForSelector('#view .wz-count b');
    await shot('11-wizard-step1-audience');
    await page.click('#view button:has-text("Next: what to send")');
    await page.waitForSelector('#view .wz-gallery .wz-tpl, #view .es-blocks');
    if (await page.isVisible('#view button:has-text("Choose another")')) { await page.click('#view button:has-text("Choose another")'); if (await page.isVisible('.dialog')) await page.click('.dialog button:has-text("Choose another")'); }
    await page.waitForSelector('#view .wz-gallery .wz-tpl');
    await page.click('#view .wz-tpl:has-text("Festive offer")');
    await page.waitForSelector('#view .es-blocks select[aria-label="Coupon"] option[value="DIWALI40"]', { state: 'attached' });
    await page.selectOption('#view .es-blocks select[aria-label="Coupon"]', 'DIWALI40');
    if (await page.isVisible('#view .es-addbar button:has-text("More blocks")')) await page.click('#view .es-addbar button:has-text("More blocks")');
    await page.click('#view .es-block button[aria-label="Delete"]'); // the header image block (needs an upload)
    await shot('12-wizard-step2-festive');
    await page.click('#view button:has-text("Next: check and send")');
    await page.waitForFunction(() => !document.querySelector('#view .wz-ci.is-wait') && document.querySelectorAll('#view .wz-ci').length >= 4);
    await page.waitForFunction(() => { const f = document.querySelector('#view .es-frame'); return f && f.getAttribute('src'); });
    await shot('13-wizard-step3-audience', { wait: 1000 });
    const disabled = await page.isDisabled('#view .wz-check-grid button.btn--primary');
    if (disabled) problems.push(`[${tag}] audience send button stayed disabled: ` + (await page.textContent('#view .wz-check')));
    if (full && !disabled) {
      await page.click('#view .wz-check-grid button.btn--primary');
      await page.waitForSelector('.dialog');
      await page.click('.dialog button:has-text("Send")');
      await page.waitForSelector('#view .wz-progress');
      await page.waitForSelector('#view .chip:has-text("Sent")', { timeout: 15000 });
      await shot('14-wizard-status');
    }
    // History, Push, Settings, Audit log
    await nav('#/email/history');
    await page.waitForSelector('#view .table, #view .empty');
    await shot('15-email-history');
    await nav('#/push');
    await page.waitForSelector('#view .np-grid');
    await shot('16-push');
    await nav('#/settings');
    await page.waitForSelector('#view .settings-body');
    await page.waitForTimeout(400);
    await shot('17-settings');
    if (full) {
      await nav('#/settings/templates');
      await page.waitForSelector('#view a[href="#/templates/plan_assigned"]');
      await shot('17b-settings-templates');
      await nav('#/templates/plan_assigned');
      await page.waitForSelector('#view .tp-mail');
      await shot('17c-template-plan-assigned');
    }
    await nav('#/audit');
    await page.waitForSelector('#view .table');
    await shot('18-audit-log');
    // Old links still land in the right place.
    await page.goto(`${origin}/admin#/notifications/email/campaigns`);
    await page.waitForFunction(() => location.hash === '#/email/history');
    await ctx.close();
  }

  async function accountRun(theme, viewport) {
    const ctx = await browser.newContext({ viewport, colorScheme: theme, deviceScaleFactor: 1 });
    const tag = `${theme}${viewport.width < 1200 ? '-tablet' : ''}${viewport.width < 600 ? '-phone' : ''}`;
    await ctx.addInitScript((tok) => { try { sessionStorage.setItem('coroute_session', tok); } catch (e) { /* ignore */ } }, asha.token);
    const page = await ctx.newPage();
    page.on('pageerror', (e) => problems.push(`[account ${tag}] page error: ${e.message}`));
    page.on('console', (m) => { if (m.type() === 'error' && !/status of 40[134]/.test(m.text())) problems.push(`[account ${tag}] console: ${m.text()}`); });
    await page.goto(`${origin}/account`);
    await page.waitForSelector('#ac-coupons .ac-coupon, #ac-coupons .sh-empty');
    await page.waitForSelector('#ac-rides .ac-list, #ac-rides p');
    await page.waitForSelector('#ac-payments table, #ac-payments .sh-empty');
    await page.waitForTimeout(500);
    const f = path.join(OUT, `20-account-${tag}.png`);
    await page.screenshot({ path: f, fullPage: true });
    shots.push(f);
    if (!results.accountCoupon) results.accountCoupon = await page.$$eval('#ac-coupons .ac-coupon__code', (els) => els.map((e) => e.textContent));
    await ctx.close();
  }

  try {
    await adminRun('light', { width: 1440, height: 900 }, true);
    await adminRun('dark', { width: 1440, height: 900 }, false);
    await adminRun('light', { width: 1024, height: 768 }, false);
    await adminRun('dark', { width: 1024, height: 768 }, false);
    await accountRun('light', { width: 1440, height: 900 });
    await accountRun('dark', { width: 1440, height: 900 });
    await accountRun('light', { width: 1024, height: 768 });
    await accountRun('dark', { width: 390, height: 844 });
  } catch (e) {
    problems.push('step failed: ' + (e && e.message ? e.message.split('\n')[0] : e));
  }
  if (results.couponCode && !(results.accountCoupon || []).includes(results.couponCode)) problems.push('/account does not list the personal code ' + results.couponCode);
  await browser.close();
  await env.gw.shutdown();
  console.log(JSON.stringify({ origin, results, screenshots: shots.length, out: OUT, adminToken: !!admin.token }, null, 2));
  if (problems.length) { console.error('PROBLEMS:\n' + problems.join('\n')); process.exit(1); }
  console.log('web console smoke: OK');
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
