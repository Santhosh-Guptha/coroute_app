#!/usr/bin/env node
'use strict';
/**
 * 3.56 operator / club console smoke test (docs/features_355/operators.md). Boots a test-mode gateway in-process
 * (MemorySoda), seeds an approved tour operator with a roster, live rides (one with an SOS), an ended ride with
 * attendance, a public sign-up ride and two waiting applications, then drives the pages in headless Chromium:
 * /operators/apply, the web admin Operators section, the operator console (overview, roster, rides, live map,
 * reports, broadcasts) and the public ride page, light and dark, desktop and tablet. Fails on any page error or
 * CSP violation.
 *
 *   node tool/operators_smoke.js [screenshot dir]
 */
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'ops.admin@coroute.test';
process.env.PUBLIC_ORIGIN = process.env.PUBLIC_ORIGIN || 'https://coroute.example';

const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

const GW = path.join(__dirname, '..', 'gateway');
const OUT = path.resolve(process.argv[2] || path.join(require('os').tmpdir(), 'operators'));
fs.mkdirSync(OUT, { recursive: true });
const PASSWORD = 'Password#123';

function loadPlaywright() {
  const tries = [path.join(GW, 'node_modules', 'playwright')];
  try { tries.push(path.join(execSync('npm root -g').toString().trim(), 'playwright')); } catch { /* no npm */ }
  for (const p of tries) { try { return require(p); } catch { /* next */ } }
  throw new Error('Playwright not found (looked in ' + tries.join(', ') + ')');
}

async function main() {
  const { createApp } = require(path.join(GW, 'src/app'));
  const { MemorySoda } = require(path.join(GW, 'src/oracle/memory_soda'));
  const quiet = { info() {}, warn() {}, error() {} };
  const gw = await createApp({ soda: new MemorySoda(), logger: quiet });
  gw.hub.push = { notifyUsers: async (ids) => ({ sent: ids.length }), onSocketEvent: async () => null };
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${gw.server.address().port}`;
  let ipN = 0;
  const api = async (method, p, body, token) => {
    const res = await fetch(`${origin}/api${p}`, { method, headers: { 'Content-Type': 'application/json', 'X-Forwarded-For': `198.18.${(ipN >> 8) & 255}.${ipN++ & 255}`, ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, json: await res.json().catch(() => ({})) };
  };
  const must = (r, what) => { if (r.status >= 300) throw new Error(`${what}: ${r.status} ${JSON.stringify(r.json)}`); return r.json; };
  let n = 0;
  const register = async (name, email) => {
    n++;
    return must(await api('POST', '/auth/register', { name, email: email || `ops${n}@coroute.test`, password: PASSWORD, phone: `+9198765${String(10000 + n).slice(-5)}`, vehicleType: 'Motorcycle', vehicleNo: `TS09OP${1000 + n}`, emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' }), 'register');
  };

  // ---- seed ----
  const admin = await register('Ops Admin', 'ops.admin@coroute.test');
  const owner = await register('Ravi Kumar', 'ravi@coroute.test');
  const app = must(await api('POST', '/operators/apply', { type: 'TOUR_OPERATOR', name: 'Deccan Moto Tours', city: 'Hyderabad', email: 'hello@deccanmoto.example', phone: '+91 98480 12345', website: 'https://deccanmoto.example', expectedRiders: 60, description: 'Weekend tours to Srisailam, Araku and Hampi with a support van and a mechanic.' }, owner.token), 'apply');
  const opId = app.application.operatorId;
  for (const [nm, type, city] of [['Kakatiya Riders Club', 'RIDING_CLUB', 'Warangal'], ['Goa Bike Rentals', 'RENTAL_FLEET', 'Panaji']]) {
    const u = await register(nm.split(' ')[0] + ' Lead');
    must(await api('POST', '/operators/apply', { type, name: nm, city, email: `team@${nm.split(' ')[0].toLowerCase()}.example`, phone: '+91 90000 11111', expectedRiders: 25, description: 'Monthly club rides around the city and a long ride every quarter.' }, u.token), 'apply2');
  }
  must(await api('POST', `/admin/operators/${opId}/approve`, { limits: { maxMembers: 40, maxConcurrentRides: 3, maxRidesPerMonth: 20, maxRidersPerRide: 12, coOrganisers: 2 }, features: { multiGroupDashboard: true, rosterEmergency: true, attendance: true, rideCalendar: true, broadcast: true, exportReports: true }, validityDays: 365 }, admin.token), 'approve');
  const names = ['Anil Reddy', 'Bina Shah', 'Chetan Rao', 'Divya Menon', 'Farah Khan', 'Gopal Das', 'Hema Iyer', 'Imran Ali'];
  const members = [];
  for (const nm of names) members.push(await register(nm));
  must(await api('POST', `/operator/${opId}/roster/invites`, { usernames: members.map((m) => m.user.username) }, owner.token), 'invite');
  for (const m of members.slice(0, 7)) {
    const inv = (await api('GET', '/clubs', null, m.token)).json.invites[0];
    must(await api('POST', `/clubs/invites/${inv.inviteId}/accept`, null, m.token), 'accept');
  }
  must(await api('POST', `/operator/${opId}/co-organisers`, { username: members[0].user.username }, owner.token), 'co');
  const now = Date.now();
  const mk = async (body, tok = owner.token) => must(await api('POST', `/operator/${opId}/rides`, body, tok), 'ride').ride;
  const done = await mk({ title: 'Ananthagiri Hills Sunrise', startsAt: now - 3 * 3600000, meetName: 'Gachibowli flyover', destinationName: 'Ananthagiri Hills', maxRiders: 8, leadUsername: members[1].user.username, sweeperUsername: members[2].user.username });
  const r1 = await mk({ title: 'Srisailam Ghat Run', startsAt: now - 1800000, meetName: 'Tank Bund', destinationName: 'Srisailam', maxRiders: 10, leadUsername: members[0].user.username, sweeperUsername: members[3].user.username });
  const r2 = await mk({ title: 'Bhongir Fort Loop', startsAt: now - 900000, meetName: 'Uppal X Roads', destinationName: 'Bhongir Fort', maxRiders: 6, leadUsername: members[4].user.username });
  const pub = await mk({ title: 'Araku Valley Weekend', startsAt: now + 9 * 86400000, meetName: 'RK Beach, Visakhapatnam', destinationName: 'Araku Valley', maxRiders: 12, publicSignup: true, requireApproval: true, notes: 'Two days, one night stay at Araku. Riding gear and a valid licence required. Support van carries luggage.' });
  await mk({ title: 'Hampi Heritage Tour', startsAt: now + 20 * 86400000, meetName: 'Shamshabad toll plaza', destinationName: 'Hampi', maxRiders: 12 });
  const roomOf = (gid) => gw.convoys.rooms.get(gid);
  const place = (gid, uid, lat, lng, speed) => {
    const room = roomOf(gid);
    gw.convoys.patchRider(room, uid, { lat, lng, speedKmh: speed, batteryLevel: 70 });
    const r = room.riders.get(uid);
    if (r) r.lastSeenEpochMs = Date.now() - Math.round(Math.random() * 20000);
  };
  const startAndFill = async (ride, riders) => {
    const st = must(await api('POST', `/operator/${opId}/rides/${ride.rideId}/start`, null, owner.token), 'start');
    must(await api('POST', `/operator/${opId}/rides/${ride.rideId}/publish`, {}, owner.token), 'publish');
    for (const m of riders) {
      const inv = (await api('GET', '/me/ride-invites', null, m.token)).json.invites.find((x) => x.ride && x.ride.groupId === st.groupId);
      if (inv) must(await api('POST', `/ride-invites/${inv.inviteId}/accept`, {}, m.token), 'join');
    }
    return st.groupId;
  };
  const g0 = await startAndFill(done, [members[2], members[5], members[6]]);
  roomOf(g0).meta.destinationArrivals = { [members[1].user.userId]: { at: Date.now() }, [members[2].user.userId]: { at: Date.now() } };
  must(await api('POST', `/operator/${opId}/rides/${done.rideId}/end`, null, owner.token), 'end');
  const g1 = await startAndFill(r1, [members[3], members[5], members[6], members[2]]);
  const g2 = await startAndFill(r2, [members[1]]);
  place(g1, members[0].user.userId, 17.0, 78.62, 64);
  place(g1, members[5].user.userId, 16.985, 78.61, 61);
  place(g1, members[6].user.userId, 16.97, 78.6, 58);
  place(g1, members[2].user.userId, 16.95, 78.59, 0);
  place(g1, members[3].user.userId, 16.93, 78.585, 55);
  place(g2, members[4].user.userId, 17.47, 78.83, 48);
  place(g2, members[1].user.userId, 17.455, 78.8, 46);
  await gw.convoys.raiseSos(g1, { userId: members[2].user.userId, name: members[2].user.name }, { lat: 16.95, lng: 78.59, alertType: 'CRASH', clientId: 'smoke-sos' });
  for (const m of [members[5], members[6], members[7]]) must(await api('POST', `/rides/${pub.slug}/signup`, null, m.token), 'signup');
  must(await api('POST', `/operator/${opId}/rides/${pub.rideId}/signups/${members[5].user.username}`, { approve: true }, owner.token), 'approve signup');
  must(await api('POST', `/operator/${opId}/broadcasts`, { title: 'Srisailam ride today', body: 'Meet at Tank Bund at 5:30 am. Fuel up the night before. Rain gear recommended.' }, owner.token), 'broadcast');
  const pending = (await api('GET', '/admin/operators?status=PENDING', null, admin.token)).json.operators[0];

  // ---- browser ----
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  const errors = [];
  const shots = [];
  const sizes = { desktop: { width: 1440, height: 900 }, tablet: { width: 820, height: 1180 } };
  async function page(size, theme, token, tokenKey) {
    const ctx = await browser.newContext({ viewport: sizes[size], colorScheme: theme, deviceScaleFactor: 1 });
    if (token) await ctx.addInitScript(([k, v]) => { try { sessionStorage.setItem(k, v); } catch (e) { /* ignore */ } }, [tokenKey, token]);
    await ctx.addInitScript((th) => { try { localStorage.setItem('cr.op.theme', th); localStorage.setItem('cr.admin.theme', th); localStorage.setItem('coroute-theme', th); } catch (e) { /* ignore */ } }, theme);
    // Map tiles are not fetched in the smoke (offline): the map shows its grid.
    await ctx.route(/tile\.openstreetmap\.org/, (r) => r.abort());
    const p = await ctx.newPage();
    p.on('pageerror', (e) => errors.push(`${size}/${theme}: ${e.message}`));
    p.on('console', (m) => { if (m.type() === 'error' && !/tile\.openstreetmap|ERR_FAILED|net::/.test(m.text())) errors.push(`${size}/${theme} console: ${m.text()}`); });
    return { ctx, p };
  }
  async function shot(p, name, full = true) {
    await p.evaluate(() => { if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); window.scrollTo(0, 0); });
    await p.waitForTimeout(400);
    const file = path.join(OUT, `${name}.png`);
    await p.screenshot({ path: file, fullPage: full });
    shots.push(file);
  }
  const APPLICANTS = ['Neha Rao', 'Arjun Pillai', 'Sneha Joshi', 'Vikas Gupta'];
  for (const theme of ['light', 'dark']) {
    for (const size of ['desktop', 'tablet']) {
      const tag = `${size}-${theme}`;
      // Website apply page: signed out, then signed in (form).
      let { ctx, p } = await page(size, theme);
      await p.goto(`${origin}/operators/apply`);
      await p.waitForSelector('#op-signin:not([hidden])');
      await shot(p, `apply-signedout-${tag}`);
      await ctx.close();
      const applicant = await register(APPLICANTS.shift());
      ({ ctx, p } = await page(size, theme, applicant.token, 'coroute_session'));
      await p.goto(`${origin}/operators/apply`);
      await p.waitForSelector('#op-form:not([hidden])');
      await p.selectOption('#op-type', 'RIDING_CLUB');
      await p.fill('#op-name', 'Hyderabad Thumpers');
      await p.fill('#op-city', 'Hyderabad');
      await p.fill('#op-riders', '35');
      await p.fill('#op-email', 'ride@thumpers.example');
      await p.fill('#op-phone', '+91 99000 22222');
      await p.fill('#op-desc', 'Sunday breakfast rides and a monthly long ride for classic bikes.');
      await shot(p, `apply-form-${tag}`);
      await p.click('#op-submit');
      await p.waitForSelector('#op-status:not([hidden])');
      await shot(p, `apply-sent-${tag}`);
      await ctx.close();
      // Public ride page.
      ({ ctx, p } = await page(size, theme));
      await p.goto(`${origin}/rides/${pub.slug}`);
      await p.waitForFunction(() => document.getElementById('rp-seats').textContent.trim() !== '');
      await shot(p, `ride-public-${tag}`);
      await ctx.close();
      // Web admin: Operators list and detail.
      ({ ctx, p } = await page(size, theme, admin.token, 'cr.admin.token'));
      await ctx.addInitScript(() => { try { sessionStorage.setItem('cr.admin.user', JSON.stringify({ name: 'Ops Admin', email: 'ops.admin@coroute.test', role: 'MASTER_ADMIN' })); sessionStorage.setItem('cr.admin.lastActive', String(Date.now())); } catch (e) { /* ignore */ } });
      await p.goto(`${origin}/admin#/operators`);
      await p.waitForSelector('.table tbody tr');
      await shot(p, `admin-operators-${tag}`);
      await p.goto(`${origin}/admin#/operators/${pending.operatorId}`);
      await p.waitForSelector('.kv');
      await shot(p, `admin-operator-approve-${tag}`);
      await p.goto(`${origin}/admin#/operators/${opId}`);
      await p.waitForSelector('.tiles');
      await shot(p, `admin-operator-approved-${tag}`);
      await ctx.close();
      // Operator console.
      ({ ctx, p } = await page(size, theme, owner.token, 'cr.op.token'));
      await p.goto(`${origin}/operator#/overview`);
      await p.waitForSelector('.tiles');
      await shot(p, `console-overview-${tag}`);
      await p.goto(`${origin}/operator#/roster`);
      await p.waitForSelector('.table tbody tr');
      await shot(p, `console-roster-${tag}`);
      await p.goto(`${origin}/operator#/rides`);
      await p.waitForSelector('.table tbody tr');
      await shot(p, `console-rides-${tag}`);
      await p.goto(`${origin}/operator#/live`);
      await p.waitForSelector('.ridecard');
      await p.waitForSelector('.mk');
      await shot(p, `console-live-${tag}`, false);
      if (size === 'desktop') {
        await p.click('.sos-banner .btn');
        await p.waitForSelector('.contact');
        await shot(p, `console-sos-contact-${tag}`, false);
        await p.keyboard.press('Escape');
      }
      await p.goto(`${origin}/operator#/reports`);
      await p.waitForSelector('.table tbody tr');
      await shot(p, `console-reports-${tag}`);
      if (size === 'desktop') {
        await p.click('.table tbody tr');
        await p.waitForSelector('.dialog .table');
        await shot(p, `console-attendance-${tag}`, false);
        await p.keyboard.press('Escape');
      }
      await p.goto(`${origin}/operator#/broadcasts`);
      await p.waitForSelector('.card');
      await shot(p, `console-broadcasts-${tag}`);
      await ctx.close();
    }
  }
  // Signed-in rider: my clubs.
  {
    const { ctx, p } = await page('desktop', 'light', members[5].token, 'coroute_session');
    await p.goto(`${origin}/clubs`);
    await p.waitForSelector('.op-item');
    await shot(p, 'clubs-desktop-light');
    await ctx.close();
  }
  await browser.close();
  await gw.shutdown();
  console.log(`${shots.length} screenshots in ${OUT}`);
  if (errors.length) { console.error('Page errors:\n' + errors.join('\n')); process.exit(1); }
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
