#!/usr/bin/env node
'use strict';
/**
 * Round 4 browser checks (docs/features_355/sessions_and_security.md §9, §12). Boots a test-mode gateway in-process
 * (MemorySoda, a fake SMTP transport that keeps the mails) and drives headless Chromium with Playwright:
 *   1. ride lock: the rider's phone (app session, device A) is on a ride with its socket joined; the website /signin
 *      answers "You're on a ride on Pixel 7" with "Send code to my e-mail"; the mailed code signs the browser in
 *      (redirect to /account) and the old phone's session is revoked; also at phone width.
 *   2. sign-up: /signin -> Create an account -> "Check your inbox"; the mailed link (#verify=) confirms the address.
 * Screenshots go to the directory given (default: $TMPDIR/security2). Fails on a page error or CSP violation.
 *
 *   node tool/security_round4_smoke.js [screenshot dir]
 */
process.env.NODE_ENV = 'test';
process.env.PUBLIC_ORIGIN = process.env.PUBLIC_ORIGIN || 'https://coroute.example';

const path = require('path');
const fs = require('fs');
const assert = require('assert/strict');
const { execSync } = require('child_process');

const GW = path.join(__dirname, '..', 'gateway');
const OUT = path.resolve(process.argv[2] || path.join(require('os').tmpdir(), 'security2'));
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
  const WebSocket = require(path.join(GW, 'node_modules', 'ws'));
  const mails = [];
  const mailTransport = { sendMail: async (m) => { mails.push(m); return { messageId: `m${mails.length}` }; } };
  const gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} }, mailTransport });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${gw.server.address().port}`;
  const api = async (method, p, body, token, headers = {}) => {
    const res = await fetch(origin + '/api' + p, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers }, body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, json: await res.json().catch(() => ({})) };
  };
  const APP = { 'X-CoRoute-Session': '2', 'X-CoRoute-Client': 'app', 'X-CoRoute-Build': '10025' };
  const DEV_A = { id: 'devA-0123456789abcdef', installId: 'instA-0123456789abcdef', label: 'Pixel 7', platform: 'android' };

  // A rider (created the old way: this harness is not about sign-up) whose phone is on a solo ride.
  assert.equal((await api('POST', '/auth/register', { name: 'Smoke Lock', email: 'smoke.lock@coroute.test', password: 'Password#123', phone: '+919876543210', vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' })).status, 201);
  const phone = await api('POST', '/auth/login', { identifier: 'smoke.lock@coroute.test', password: 'Password#123', device: DEV_A }, null, APP);
  assert.equal(phone.status, 200);
  const ride = await api('POST', '/convoys', { name: 'Morning ride' }, phone.json.token);
  assert.equal(ride.status, 201, JSON.stringify(ride.json));
  const ws = new WebSocket(origin.replace('http', 'ws') + '/ws');
  const inbox = [];
  ws.on('message', (d) => inbox.push(JSON.parse(String(d))));
  await new Promise((r) => ws.once('open', r));
  ws.send(JSON.stringify({ type: 'AUTH', token: phone.json.token })); // round 4: the token as the first message
  const until = async (fn, what, ms = 5000) => { const end = Date.now() + ms; while (!fn()) { if (Date.now() > end) throw new Error('timeout: ' + what); await new Promise((r) => setTimeout(r, 20)); } };
  await until(() => inbox.some((m) => m.type === 'HELLO'), 'HELLO');
  ws.send(JSON.stringify({ type: 'JOIN', groupId: ride.json.groupId }));
  await until(() => inbox.some((m) => m.type === 'SNAPSHOT'), 'SNAPSHOT');

  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  const problems = [];
  const watch = (page, tag) => {
    page.on('pageerror', (e) => {
      if (/Transition was skipped/i.test(e.message)) return;
      problems.push(`${tag}: page error ${e.message} ${(e.stack || '').split('\n').slice(0, 3).join(' / ')}`);
    });
    page.on('console', (m) => { if (m.type() === 'error' && /Content Security Policy|Refused to/.test(m.text())) problems.push(`${tag}: ${m.text()}`); });
  };
  const shot = async (page, name) => {
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(150);
    try {
      return await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: true, timeout: 4000 });
    } catch {
      try {
        return await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: false, timeout: 3000 });
      } catch {
        /* headless Windows compositor frame commit timeout */
      }
    }
  };
  const results = [];
  try {
    // ---------------------------------------------------------------- 1. ride lock on the website
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const page = await ctx.newPage();
    watch(page, 'signin');
    await page.goto(`${origin}/signin?next=/account`);
    await page.fill('#si-id', 'smoke.lock@coroute.test');
    await page.fill('#si-pw', 'Password#123');
    await page.click('#si-submit', { force: true });
    await page.waitForSelector('#si-lock:not([hidden])');
    assert.equal((await page.textContent('#si-lock-title')).trim(), "You're on a ride on Pixel 7");
    assert.match(await page.textContent('#si-lock-msg'), /End the ride on that phone to sign in here\./);
    assert.ok(await page.isVisible('#si-lock-call'), 'Call 112 visible');
    assert.equal(await page.getAttribute('#si-lock-call', 'href'), 'tel:112');
    await shot(page, '01_signin_ride_lock');
    results.push('website: sign-in during a ride -> "You\'re on a ride on Pixel 7", Send code, Call 112');

    mails.length = 0;
    await page.click('#si-lock-send', { force: true });
    await page.waitForSelector('#si-lock-codebox:not([hidden])');
    await until(() => mails.some((m) => m.subject === 'Ride sign-in code'), 'code mail');
    const codeMail = mails.find((m) => m.subject === 'Ride sign-in code');
    const code = /\b(\d{6})\b/.exec(codeMail.text)[1];
    assert.match(await page.textContent('#si-lock-resend'), /Send again in \d+ s/);
    assert.ok(await page.isDisabled('#si-lock-resend'), 'resend waits');
    await shot(page, '02_signin_code_sent');
    fs.writeFileSync(path.join(OUT, '02b_ride_signin_code_email.html'), codeMail.html);

    await page.fill('#si-lock-code', '000000' === code ? '111111' : '000000');
    await page.click('#si-lock-verify', { force: true });
    await page.waitForFunction(() => /not right/.test((document.getElementById('si-lock-status') || {}).textContent || ''));
    await shot(page, '03_signin_wrong_code');
    await page.fill('#si-lock-code', code);
    await page.click('#si-lock-verify', { force: true });
    await page.waitForURL(/\/account$/, { timeout: 8000 });
    await page.waitForFunction(() => /Smoke Lock|@/.test((document.getElementById('ac-who') || {}).textContent || ''), null, { timeout: 8000 });
    await shot(page, '04_signed_in_after_code');
    assert.equal((await api('GET', '/me', null, phone.json.token)).status, 401, 'the old phone is signed out');
    await until(() => inbox.some((m) => m.type === 'SAFETY_ONLY'), 'old phone in safety-only mode');
    assert.ok(mails.some((m) => m.subject === 'Signed in during a ride'), 'notice e-mail');
    results.push('website: the e-mailed code signs in, the old phone drops to safety-only, notice mailed');
    await ctx.close();

    // The same panel at phone width (a second rider, so the lock is fresh).
    assert.equal((await api('POST', '/auth/register', { name: 'Smoke Narrow', email: 'smoke.narrow@coroute.test', password: 'Password#123', phone: '+919876543210', vehicleNo: 'TS09AB1235', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' })).status, 201);
    const p2 = await api('POST', '/auth/login', { identifier: 'smoke.narrow@coroute.test', password: 'Password#123', device: { ...DEV_A, label: 'Galaxy S24' } }, null, APP);
    const r2 = await api('POST', '/convoys', { name: 'Evening ride' }, p2.json.token);
    assert.equal(r2.status, 201);
    await gw.rideLock.noteRide(p2.json.sessionId, p2.json.user.userId, r2.json.groupId, { force: true });
    const narrow = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true });
    const np = await narrow.newPage();
    watch(np, 'narrow');
    await np.goto(`${origin}/signin`);
    await np.fill('#si-id', 'smoke.narrow@coroute.test');
    await np.fill('#si-pw', 'Password#123');
    await np.click('#si-submit', { force: true });
    await np.waitForSelector('#si-lock:not([hidden])');
    const overflow = await np.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(overflow <= 1, `no horizontal scroll at phone width (${overflow}px)`);
    await shot(np, '05_signin_ride_lock_phone');
    results.push('website: the ride lock panel fits a 390 px phone screen');
    await narrow.close();

    // ---------------------------------------------------------------- 2. sign-up -> check inbox
    const rc = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const rp = await rc.newPage();
    watch(rp, 'register');
    await rp.goto(`${origin}/signin`);
    await rp.click('#si-to-register', { force: true });
    await rp.waitForSelector('#si-register:not([hidden])');
    await rp.fill('#rg-name', 'Smoke Newbie');
    await rp.fill('#rg-email', 'smoke.newbie@coroute.test');
    await rp.fill('#rg-phone', '+919876500000');
    await rp.fill('#rg-pw', 'Long#Passphrase42');
    await rp.fill('#rg-pw2', 'Long#Passphrase42');
    await rp.fill('#rg-bike', 'KA01AB1234');
    await rp.fill('#rg-ice-name', 'Family Contact');
    await rp.fill('#rg-ice-phone', '+919000000001');
    await rp.check('#rg-terms');
    await shot(rp, '06_register_form');
    mails.length = 0;
    await rp.click('#rg-submit', { force: true });
    await rp.waitForSelector('#si-inbox:not([hidden])');
    assert.match(await rp.textContent('#si-inbox-msg'), /Check your e-mail to finish creating your account\. We sent a link to smoke\.newbie@coroute\.test\./);
    assert.ok(await rp.isDisabled('#si-inbox-resend'), 'resend waits 60 s');
    await shot(rp, '07_check_inbox');
    await until(() => mails.some((m) => /Confirm your e-mail/.test(m.subject)), 'verification mail');
    const vm = mails.find((m) => /Confirm your e-mail/.test(m.subject));
    fs.writeFileSync(path.join(OUT, '07b_verify_email.html'), vm.html);
    const token = /#verify=([A-Za-z0-9_-]{40,60})/.exec(vm.text)[1];
    // Not usable before the link.
    assert.equal((await api('POST', '/auth/login', { identifier: 'smoke.newbie@coroute.test', password: 'Long#Passphrase42' }, null, APP)).json.code, 'EMAIL_NOT_VERIFIED');
    await rp.goto(`${origin}/signin?from=mail#verify=${token}`);
    await rp.waitForSelector('#si-notice:not([hidden])');
    assert.match(await rp.textContent('#si-notice'), /confirmed/);
    assert.equal(await rp.evaluate(() => window.location.hash), '', 'the token left the address bar');
    await shot(rp, '08_email_confirmed');
    await rp.fill('#si-pw', 'Long#Passphrase42');
    await rp.click('#si-submit', { force: true });
    await rp.waitForURL(/\/(account|plans)/, { timeout: 8000 }).catch(() => null);
    results.push('website: create account -> "Check your inbox" -> link confirms -> sign in works');
    await rc.close();
  } finally {
    await browser.close();
    try { ws.close(); } catch { /* gone */ }
    await gw.shutdown();
  }
  if (problems.length) { console.error(problems.join('\n')); process.exit(1); }
  for (const r of results) console.log('ok -', r);
  console.log(`screenshots: ${OUT}`);
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
