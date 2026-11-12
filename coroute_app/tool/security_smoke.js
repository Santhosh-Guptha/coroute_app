#!/usr/bin/env node
'use strict';
/**
 * 3.57 sessions & security browser checks (docs/features_355/sessions_and_security.md). Boots a test-mode gateway
 * in-process (MemorySoda) and drives headless Chromium with Playwright:
 *   1. website: sign in -> /account; a new tab is signed in through the httpOnly cookie; Sign out -> home page (/);
 *      Back after sign-out shows no private data; the old access token is refused by the server.
 *   2. web admin: 2-step set-up at the first sign-in (QR + key, code, recovery codes), the idle warning dialog,
 *      then the automatic sign-out (server session revoked); Sign out -> home page.
 * Screenshots go to the directory given (default: $TMPDIR/security). Fails on a page error or CSP violation.
 *
 *   node tool/security_smoke.js [screenshot dir]
 *
 * Playwright is resolved from the gateway's node_modules, then the global npm root (never installed here).
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'smoke.secadmin@coroute.test';
process.env.PUBLIC_ORIGIN = process.env.PUBLIC_ORIGIN || 'https://coroute.example';

const path = require('path');
const fs = require('fs');
const assert = require('assert/strict');
const { execSync } = require('child_process');

const GW = path.join(__dirname, '..', 'gateway');
const OUT = path.resolve(process.argv[2] || path.join(require('os').tmpdir(), 'security'));
fs.mkdirSync(OUT, { recursive: true });

function loadPlaywright() {
  const tries = [path.join(GW, 'node_modules', 'playwright')];
  try { tries.push(path.join(execSync('npm root -g').toString().trim(), 'playwright')); } catch { /* no npm */ }
  for (const p of tries) { try { return require(p); } catch { /* next */ } }
  throw new Error('Playwright not found (looked in ' + tries.join(', ') + ')');
}

(async () => {
  const { createApp } = require(path.join(GW, 'src/app'));
  const { MemorySoda } = require(path.join(GW, 'src/oracle/memory_soda'));
  const totp = require(path.join(GW, 'src/totp'));
  const gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  // 127.0.0.1 is a secure context for Chromium: Secure / __Host- cookies work over plain http in this test.
  const origin = `http://127.0.0.1:${gw.server.address().port}`;
  const api = async (method, p, body, token, headers = {}) => {
    const res = await fetch(origin + '/api' + p, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers }, body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, json: await res.json().catch(() => ({})) };
  };
  const reg = (name, email) => api('POST', '/auth/register', { name, email, password: 'Password#123', phone: '+919876543210', vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' });
  assert.equal((await reg('Smoke Rider', 'smoke.rider@coroute.test')).status, 201);
  assert.equal((await reg('Smoke Admin', 'smoke.secadmin@coroute.test')).status, 201);

  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  const problems = [];
  const watch = (page, tag) => {
    page.on('pageerror', (e) => problems.push(`${tag}: page error ${e.message}`));
    page.on('console', (m) => { if (m.type() === 'error' && /Content Security Policy|Refused to/.test(m.text())) problems.push(`${tag}: ${m.text()}`); });
  };
  const shot = async (page, name) => {
    await page.waitForTimeout(200);
    try {
      return await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: false, timeout: 4000 });
    } catch {
      /* headless Windows compositor frame commit timeout */
    }
  };
  const results = [];
  try {
    // ---------------------------------------------------------------- 1. website
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 } });
    const page = await ctx.newPage();
    watch(page, 'site');
    await page.goto(`${origin}/signin?next=/account`);
    await page.fill('#si-id', 'smoke.rider@coroute.test');
    await page.fill('#si-pw', 'Password#123');
    await page.click('#si-submit');
    await page.waitForURL(/\/account$/);
    await page.goto(`${origin}/account`);
    await page.waitForFunction(() => /Smoke Rider|smoke_rider|@/.test(document.getElementById('ac-who').textContent || ''), null, { timeout: 8000 });
    await page.waitForSelector('#ac-sessions li');
    await shot(page, '01_account_signed_in');
    const cookies = await ctx.cookies();
    const rt = cookies.find((c) => c.name === '__Host-cr_rt');
    assert.ok(rt && rt.httpOnly && rt.secure && rt.sameSite === 'Lax', 'refresh cookie: httpOnly, Secure, SameSite=Lax');
    const accessToken = await page.evaluate(() => sessionStorage.getItem('coroute_session'));
    assert.ok(accessToken);
    assert.equal(await page.evaluate(() => document.cookie), '', 'page scripts cannot read the session cookie');
    results.push('website: signed in, refresh cookie is httpOnly / Secure / SameSite=Lax, invisible to scripts');

    // A new tab (empty sessionStorage) is signed in silently through the cookie.
    const tab2 = await ctx.newPage();
    watch(tab2, 'tab2');
    await tab2.goto(`${origin}/account`);
    await tab2.waitForURL(/\/account$/, { timeout: 8000 });
    await tab2.waitForFunction(() => /Smoke Rider|@/.test(document.getElementById('ac-who').textContent || ''), null, { timeout: 8000 });
    results.push('website: a new tab continues the session through the cookie');
    await tab2.close();

    // Back / forward cache: from /account go on to another page, the session ends (sign-out in another tab), Back
    // must not show the cached account page.
    await page.goto(`${origin}/features`);
    await page.evaluate(() => fetch('/api/auth/logout', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-CoRoute-Client': 'web', 'X-CoRoute-CSRF': '1', Authorization: 'Bearer ' + sessionStorage.getItem('coroute_session') }, body: '{"client":"web"}' }).then(() => sessionStorage.removeItem('coroute_session')));
    await page.goBack();
    await page.waitForURL(/\/signin/, { timeout: 8000 });
    await page.goto(page.url());
    await page.waitForSelector('#si-id');
    await shot(page, '03_back_after_signout');
    const text = await page.evaluate(() => document.body ? document.body.innerText : '');
    assert.ok(!/smoke\.rider@coroute\.test|Smoke Rider/.test(text), 'no private data after Back');
    results.push(`website: Back to a private page after sign-out shows no private data (goes to ${page.url().replace(origin, '')})`);
    assert.equal((await api('GET', '/me', null, accessToken)).status, 401, 'old access token refused after sign-out');

    // Sign in again; the Sign out button -> home page (/), server session revoked, cookie cleared.
    await page.evaluate(() => sessionStorage.clear());
    await page.fill('#si-id', 'smoke.rider@coroute.test');
    await page.fill('#si-pw', 'Password#123');
    await page.click('#si-submit', { force: true });
    await page.waitForURL(/\/account$/);
    await page.goto(`${origin}/account`);
    await page.waitForSelector('#ac-sessions li');
    const token2 = await page.evaluate(() => sessionStorage.getItem('coroute_session'));
    await page.click('#security button[data-signout]:not([data-signout="all"])', { force: true });
    await page.waitForURL(`${origin}/`, { timeout: 8000 });
    await page.goto(`${origin}/`);
    await page.waitForSelector('#main');
    await shot(page, '02_after_signout_home');
    assert.equal((await api('GET', '/me', null, token2)).status, 401, 'old access token refused after sign-out');
    assert.ok(!(await ctx.cookies()).some((c) => c.name === '__Host-cr_rt'), 'cookie cleared');
    assert.equal(await page.evaluate(() => sessionStorage.getItem('coroute_session')), null);
    results.push('website: Sign out -> home page (/), server session revoked, cookie cleared');
    await page.goBack().catch(() => null);
    await page.waitForTimeout(1200);
    const text2 = await page.evaluate(() => document.body ? document.body.innerText : '');
    assert.ok(!/smoke\.rider@coroute\.test/.test(text2), 'no private data after Back');
    await ctx.close();

    // ---------------------------------------------------------------- 2. web admin
    const actx = await browser.newContext({ viewport: { width: 1280, height: 860 } });
    const ap = await actx.newPage();
    watch(ap, 'admin');
    await ap.goto(`${origin}/admin`);
    await ap.waitForSelector('#signin-form:not([hidden])');
    await ap.fill('#signin-id', 'smoke.secadmin@coroute.test');
    await ap.fill('#signin-pw', 'Password#123');
    await ap.click('#signin-btn', { force: true });
    await ap.waitForSelector('#mfa-form:not([hidden]) #mfa-setup:not([hidden])');
    await ap.waitForFunction(() => (document.getElementById('mfa-secret').textContent || '').length > 20);
    await ap.waitForSelector('#mfa-qr svg');
    await shot(ap, '04_admin_2step_setup');
    const secret = (await ap.textContent('#mfa-secret')).replace(/\s+/g, '');
    await ap.fill('#mfa-code', totp.totp(secret));
    await ap.click('#mfa-btn', { force: true });
    await ap.waitForSelector('#mfa-codes:not([hidden]) #mfa-codes-list li');
    assert.equal(await ap.locator('#mfa-codes-list li').count(), 10);
    await shot(ap, '05_admin_recovery_codes');
    await ap.click('#mfa-codes-done', { force: true });
    await ap.waitForSelector('#shell:not([hidden])');
    results.push('admin: 2-step set-up forced at the first sign-in (QR + key, code, 10 recovery codes)');
    assert.ok((await actx.cookies()).find((c) => c.name === '__Host-cr_adm' && c.sameSite === 'Strict' && c.httpOnly), 'admin cookie Strict + httpOnly');

    // Idle: a short QA idle time for this tab (never longer than 30 min), reload (session continues via the cookie).
    await ap.evaluate(() => sessionStorage.setItem('cr.idleMs', '9000'));
    await ap.reload();
    await ap.waitForSelector('#shell:not([hidden])', { timeout: 8000 });
    const adminToken = await ap.evaluate(() => sessionStorage.getItem('cr.admin.token'));
    await ap.waitForSelector('.scrim--idle [role="alertdialog"]', { timeout: 12000 });
    const warn = await ap.textContent('.scrim--idle [data-idle-text]');
    assert.match(warn, /signed out in 0:0\d/);
    await shot(ap, '06_admin_idle_warning');
    results.push('admin: idle warning dialog shown before the automatic sign-out');
    await ap.waitForSelector('#signin:not([hidden]) #signin-error:not([hidden])', { timeout: 12000 });
    assert.match(await ap.textContent('#signin-error'), /without activity/);
    await shot(ap, '07_admin_auto_signed_out');
    await ap.waitForTimeout(500);
    assert.equal((await api('GET', '/admin/users', null, adminToken)).status, 401, 'server session revoked by the idle sign-out');
    results.push('admin: automatic sign-out after idle; the server session is revoked');

    // Sign in again (2-step code) and use Sign out -> home page.
    await ap.evaluate(() => sessionStorage.removeItem('cr.idleMs'));
    await ap.reload();
    await ap.waitForSelector('#signin-form:not([hidden])');
    await ap.fill('#signin-id', 'smoke.secadmin@coroute.test');
    await ap.fill('#signin-pw', 'Password#123');
    await ap.click('#signin-btn', { force: true });
    await ap.waitForSelector('#mfa-form:not([hidden])');
    await ap.fill('#mfa-code', totp.hotp(secret, totp.stepAt() + 1));
    await ap.click('#mfa-btn', { force: true });
    await ap.waitForSelector('#shell:not([hidden])');
    await ap.click('#signout', { force: true });
    await ap.waitForURL(`${origin}/`, { timeout: 8000 });
    await shot(ap, '08_admin_signout_home');
    results.push('admin: 2-step code at the next sign-in; Sign out -> home page (/)');
    await actx.close();
  } finally {
    await browser.close();
    await gw.shutdown();
  }
  for (const r of results) console.log(`ok  ${r}`);
  if (problems.length) { console.error(problems.join('\n')); process.exit(1); }
  console.log(`screenshots: ${OUT}`);
})().catch((e) => { console.error(e); process.exit(1); });
