'use strict';
/**
 * 3.57 lifecycle e-mails (src/lifecycle_emails.js, docs/features_355/lifecycle_emails.md): the welcome
 * e-mail (password and Google sign-up, once per account), its group rides block per access mode and the
 * "Tips and news" category, the welcome coupon setting, the ride summary e-mail (once per rider per ride,
 * thresholds, privacy of the route picture), e-mail categories with signed, scanner-safe unsubscribe links,
 * suppression, and no SMTP -> nothing. SMTP is a fake transport.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'life.admin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
process.env.SUPPORT_EMAIL = 'help@coroute.example';
process.env.PAYMENTS_ENABLED = 'true';
process.env.TRIP_MEMORY_DELAY_MIN = '0';

const zlib = require('zlib');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, quiet } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { Mailer } = require('../src/mailer');
const { TemplateStore } = require('../src/templates');
const { LifecycleEmails, categoryToken, kmText, durText } = require('../src/lifecycle_emails');
const { renderRoutePng, trimEnds, cleanTrail, haversine } = require('../src/route_png');

const mails = [];
const mailTransport = { async sendMail(m) { mails.push(m); return { messageId: `<l${mails.length}@test>` }; } };
const googleVerifier = {
  async verifyIdToken({ idToken }) {
    return { getPayload: () => ({ email: `${idToken}@gmail.test`, email_verified: true, sub: `g-${idToken}`, name: 'Ravi Kumar' }) };
  },
};

let t, admin;
const life = () => t.gw.notifications.lifecycle;
const byKind = (kind, to) => mails.filter((m) => m.headers && m.headers['X-CoRoute-Mail'] === kind && (!to || m.to === to));
const settle = async () => { await life().idle(); };

before(async () => {
  t = await boot({ mailTransport, googleVerifier });
  admin = await t.register('Life Admin', 'life.admin@coroute.test');
  await settle();
});
after(async () => { await t.gw.shutdown(); });

// ------------------------------------------------------------ welcome
test('welcome: sent once after a password sign-up, never on the request, with steps, guide and categories', async () => {
  const before = mails.length;
  const r = await t.register('Asha Rao', 'asha.life@coroute.test');
  await settle();
  const sent = byKind('welcome', 'asha.life@coroute.test');
  assert.equal(sent.length, 1);
  const m = sent[0];
  const me = await t.api('GET', '/me', null, r.token);
  assert.equal(m.subject, 'Welcome to CoRoute, Asha');
  for (const s of ['Welcome, Asha', `@${me.json.username}`, '1. Add your emergency contact and Medical ID', '2. Add your bike', '3. Start a ride',
    'Every safety feature is free', 'https://coroute.example/guide', 'help@coroute.example', 'Manage e-mails: https://coroute.example/account#emails']) {
    assert.ok(m.text.includes(s), `text has ${s}`);
  }
  assert.match(m.html, /<html/);
  assert.ok(m.html.includes('href="https://coroute.example/guide"'));
  // A one-click unsubscribe for the marketing-light part ("Tips and news").
  assert.match(m.headers['List-Unsubscribe'], /^<https:\/\/coroute\.example\/email\/unsubscribe\?u=[^&]+&c=tips_news&t=[A-Za-z0-9_-]{32}>$/);
  assert.equal(m.headers['List-Unsubscribe-Post'], 'List-Unsubscribe=One-Click');
  // Signing in again (and GET /me) never sends a second one.
  await t.api('POST', '/auth/login', { identifier: 'asha.life@coroute.test', password: 'Password#123' });
  await t.api('GET', '/me', null, r.token);
  await life().enqueueWelcome({ ...r.user, email: 'asha.life@coroute.test' });
  await settle();
  assert.equal(byKind('welcome', 'asha.life@coroute.test').length, 1);
  const log = await t.gw.soda.query('mail_log', { key: `welcome:${r.user.userId}` }, { limit: 5 });
  assert.equal(log.length, 1);
  assert.deepEqual([log[0].value.status, log[0].value.to], ['SENT', 'a***@coroute.test']);
  assert.ok(mails.length > before);
});

test('welcome: Google first sign-in gets one; the second Google sign-in does not', async () => {
  let r = await t.api('POST', '/auth/google', { idToken: 'ravi.k' });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  await settle();
  r = await t.api('POST', '/auth/google', { idToken: 'ravi.k' });
  assert.equal(r.status, 200);
  await settle();
  const sent = byKind('welcome', 'ravi.k@gmail.test');
  assert.equal(sent.length, 1);
  assert.equal(sent[0].subject, 'Welcome to CoRoute, Ravi');
});

test('welcome: group rides block per access mode, left out when Tips and news is off', async () => {
  const r = await t.register('Mode Rider', 'mode.rider@coroute.test');
  await settle();
  const user = await t.gw.repo.findUserById(r.user.userId);
  const am = t.gw.accessMode;
  await am.set({ mode: 'paid' }, { by: 'test' });
  let w = await life().buildWelcome(user);
  assert.equal(w.plans.kind, 'plans');
  assert.ok(w.text.includes('See group plans: https://coroute.example/plans?utm_source=welcome'));
  assert.ok(w.html.includes('See group plans') && !w.text.includes('coupon='), 'no coupon unless the admin sets one');
  await am.set({ mode: 'hybrid' }, { by: 'test' });
  w = await life().buildWelcome(user);
  assert.equal(w.plans.kind, 'plans');
  await am.set({ mode: 'free' }, { by: 'test' });
  w = await life().buildWelcome(user);
  assert.equal(w.plans.kind, 'free');
  assert.ok(w.text.includes('Group rides are free right now') && !w.text.includes('/plans'));
  await am.set({ mode: 'paid' }, { by: 'test' });
  // Tips and news off: the transactional part still goes, the block does not.
  assert.equal((await t.api('PUT', '/web/email-preferences', { tipsNews: false }, r.token)).status, 200);
  w = await life().buildWelcome(user);
  assert.equal(w.plans, null);
  assert.ok(!w.text.includes('Group rides') && !w.text.includes('/plans') && w.text.includes('Every safety feature is free'));
  assert.ok(!w.text.includes('Unsubscribe from tips and news'), 'nothing to unsubscribe from in the e-mail body');
});

test('welcome coupon: admin only, must be an active public coupon, then on the plans button', async () => {
  const repo = t.gw.repo;
  const now = Date.now();
  await repo.saveCoupon({ code: 'WELCOME10', discountType: 'percentage', discountValue: 10, validFrom: now - 1000, expiresAt: now + 30 * 86400000, status: 'ACTIVE' });
  await repo.saveCoupon({ code: 'VIPONLY', discountType: 'percentage', discountValue: 50, validFrom: now - 1000, expiresAt: now + 30 * 86400000, status: 'ACTIVE', allowedUserIds: ['usr_x'] });
  await repo.saveCoupon({ code: 'PAUSED5', discountType: 'percentage', discountValue: 5, validFrom: now - 1000, expiresAt: now + 30 * 86400000, isActive: false });
  const rider = await t.register('Coupon Rider', 'coupon.rider@coroute.test');
  assert.equal((await t.api('PUT', '/admin/email/lifecycle/settings', { welcomeCoupon: 'WELCOME10' }, rider.token)).status, 403);
  const put = (code) => t.api('PUT', '/admin/email/lifecycle/settings', { welcomeCoupon: code }, admin.token);
  assert.equal((await put('NOPE99')).status, 400);
  assert.equal((await put('bad code!')).status, 400);
  const vip = await put('VIPONLY');
  assert.equal(vip.status, 400);
  assert.match(vip.json.error, /public/);
  assert.equal((await put('PAUSED5')).status, 400);
  const ok = await put('welcome10');
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.equal(ok.json.welcomeCoupon, 'WELCOME10');
  const get = await t.api('GET', '/admin/email/lifecycle/settings', null, admin.token);
  assert.equal(get.json.welcomeCoupon, 'WELCOME10');
  const user = await repo.findUserById(rider.user.userId);
  let w = await life().buildWelcome(user);
  assert.ok(w.text.includes('https://coroute.example/plans?coupon=WELCOME10&utm_source=welcome'), w.text);
  // A coupon that stops being active is simply left out at send time.
  const c = await repo.findCoupon('WELCOME10');
  await repo.saveCoupon({ ...c, isActive: false });
  w = await life().buildWelcome(user);
  assert.ok(!w.text.includes('coupon=') && w.text.includes('/plans?utm_source=welcome'));
  assert.equal((await put('')).json.welcomeCoupon, '');
  // Audit entry for the change.
  const audit = await repo.listAuditEntries(50);
  assert.ok(audit.some((e) => e.action === 'email.lifecycle.settings'));
});

test('templates: welcome and ride summary are editable, validated, versioned, with a whole-e-mail preview', async () => {
  const list = await t.api('GET', '/admin/templates', null, admin.token);
  const ids = list.json.templates.map((x) => x.id);
  assert.ok(ids.includes('welcome') && ids.includes('trip_memory'));
  const welcome = list.json.templates.find((x) => x.id === 'welcome');
  assert.equal(welcome.channel, 'email');
  assert.ok(welcome.lifecycle);
  // Unknown variable refused.
  const bad = await t.api('PUT', '/admin/templates/welcome', { fields: { ...welcome.current, subject: 'Hi {{nmae}}' } }, admin.token);
  assert.equal(bad.status, 400);
  assert.match(bad.json.error, /unknown variable/);
  // Preview: the whole e-mail.
  const prev = await t.api('POST', '/admin/templates/trip_memory/preview', { fields: { ...list.json.templates.find((x) => x.id === 'trip_memory').current } }, admin.token);
  assert.equal(prev.status, 200);
  assert.equal(prev.json.mail.subject, 'Your ride: Nandi Hills sunrise ride · 128 km');
  assert.match(prev.json.mail.html, /data:image\/png;base64,/);
  assert.ok(prev.json.mail.text.includes('View trip report'));
  const wp = await t.api('POST', '/admin/templates/welcome/preview', {}, admin.token);
  assert.ok(wp.json.mail.text.includes('@SwiftFalcon482'));
  // Save a new version and it is used.
  const saved = await t.api('PUT', '/admin/templates/welcome', { fields: { ...welcome.current, subject: 'Hello {{name}}, ride safe' } }, admin.token);
  assert.equal(saved.status, 200, JSON.stringify(saved.json));
  const r = await t.register('Tpl Rider', 'tpl.rider@coroute.test');
  await settle();
  assert.equal(byKind('welcome', 'tpl.rider@coroute.test')[0].subject, 'Hello Tpl, ride safe');
  assert.equal((await t.api('GET', '/admin/templates/welcome/history', null, admin.token)).json.history[0].version, saved.json.version);
  await t.api('POST', '/admin/templates/welcome/reset', null, admin.token);
  void r;
});

// ------------------------------------------------------------ ride summary
const HOME = { lat: 12.97160, lng: 77.59456 };
/** A straight ride north-east from HOME, one point every ~100 m, `km` long. */
function trail(km, start = HOME) {
  const pts = [];
  const n = Math.round(km * 10);
  for (let i = 0; i <= n; i++) pts.push({ lat: +(start.lat + i * 0.0009 * 0.7).toFixed(5), lng: +(start.lng + i * 0.0009 * 0.7).toFixed(5), speedKmh: 40, heading: 0, timestamp: 1 });
  return pts;
}
let gseq = 0;
async function ride(user, { km = 24.6, minutes = 75, others = ['Bina Other'] } = {}) {
  gseq++;
  const gid = `GRP-LIFE${gseq}`;
  const end = Date.now() - 60000;
  const start = end - minutes * 60000;
  const tripDoc = {
    tripId: `TRIP-LIFE${gseq}-${user.userId}`, source: 'server', groupId: gid, userId: user.userId, tripName: 'Nandi Hills sunrise ride',
    startLocationName: 'Home street 12', destinationName: 'Nandi Hills', startTimeEpochMs: start, endTimeEpochMs: end, totalDistanceKm: km,
    topSpeedKmh: 96, avgSpeedKmh: 44, riderCount: 1 + others.length, stopCount: 2, movingMs: (minutes - 10) * 60000, restMs: 600000,
    createdByUserName: others[0] || '', breadcrumbTrail: trail(km), savedAt: Date.now(),
  };
  await t.gw.repo.saveTrip(tripDoc);
  const members = { [user.userId]: { userId: user.userId, name: user.name } };
  others.forEach((n, i) => { members[`usr_other_${gseq}_${i}`] = { userId: `usr_other_${gseq}_${i}`, name: n }; });
  const meta = { groupId: gid, name: 'Nandi Hills sunrise ride', members, createdAtEpochMs: start, endedAtEpochMs: end };
  await t.gw.repo.saveConvoyMeta(meta);
  return { gid, meta, tripDoc, perMember: [{ userId: user.userId, name: user.name, tripDoc }, ...Object.keys(members).filter((k) => k !== user.userId).map((k) => ({ userId: k, name: members[k].name, tripDoc: null }))] };
}

test('ride summary: once per rider per ride, own facts only, no speed, start and end left off the picture', async () => {
  const r = await t.register('Kiran Rider', 'kiran.rider@coroute.test');
  await settle();
  const user = await t.gw.repo.findUserById(r.user.userId);
  const x = await ride(user);
  life().onTripFinished({ meta: x.meta, perMember: x.perMember });
  life().onTripFinished({ meta: x.meta, perMember: x.perMember }); // a late-upload rebuild
  await settle();
  await life().processDue();
  const sent = byKind('trip_memory', 'kiran.rider@coroute.test');
  assert.equal(sent.length, 1);
  const m = sent[0];
  assert.equal(m.subject, 'Your ride: Nandi Hills sunrise ride · 24.6 km');
  for (const s of ['Distance: 24.6 km', 'Riding time: 1 h 5 min', 'Stops: 2', 'Riders: 2', 'Rate the places you stopped',
    `View trip report: https://coroute.example/trip/${encodeURIComponent(x.tripDoc.tripId)}?utm_source=ride_summary`]) {
    assert.ok(m.text.includes(s), `text has ${s}`);
  }
  // Privacy: no speed, no other rider, no place names of the start, no coordinates.
  const all = `${m.subject}\n${m.text}\n${m.html}`;
  for (const s of ['96', 'km/h', 'Top speed', 'Bina', 'Home street', String(HOME.lat), String(HOME.lng), '12.97', '77.59']) assert.ok(!all.includes(s), `mail must not include ${s}`);
  assert.match(m.headers['List-Unsubscribe'], /c=ride_summaries/);
  // The route picture: an inline PNG (cid), never a link to a map.
  assert.equal(m.attachments.length, 1);
  const a = m.attachments[0];
  assert.equal(a.contentType, 'image/png');
  assert.ok(m.html.includes(`cid:${a.cid}`));
  assert.deepEqual([...a.content.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.equal(a.content.readUInt32BE(16), 600);
  assert.equal(a.content.readUInt32BE(20), 300);
  const log = await t.gw.soda.query('mail_log', { key: `trip_memory:${x.gid}:${user.userId}` }, { limit: 3 });
  assert.equal(log.length, 1);
  assert.equal(log[0].value.status, 'SENT');
  // Only the analysed rider (with an account and a trip document) is queued.
  assert.equal((await t.gw.soda.query('mail_log', { groupId: x.gid }, { limit: 10 })).length, 1);
});

test('route picture: the first and last 300 m are cut, gaps are not bridged, a short trail has no picture', () => {
  const pts = cleanTrail(trail(5));
  const cut = trimEnds(pts, 300);
  assert.ok(haversine(HOME, cut[0]) >= 299, 'the picture starts at least 300 m from the real start');
  assert.ok(haversine(pts[pts.length - 1], cut[cut.length - 1]) >= 299, 'and ends 300 m before the real end');
  for (const p of cut) assert.ok(haversine(HOME, p) >= 299);
  assert.equal(renderRoutePng(trail(0.5)), null, 'too short to hide both ends: no picture');
  const png = renderRoutePng(trail(5)).png;
  // Decodes (IHDR + IDAT inflate to the right size).
  const idat = png.subarray(png.indexOf(Buffer.from('IDAT')) + 4, png.indexOf(Buffer.from('IEND')) - 8);
  assert.equal(zlib.inflateSync(idat).length, (600 * 3 + 1) * 300);
  const withGap = trail(5).map((p, i) => (i === 25 ? { ...p, gap: true } : p));
  assert.ok(renderRoutePng(withGap));
  assert.deepEqual([kmText(128.4), kmText(4.62), kmText(2)], ['128 km', '4.6 km', '2 km']);
  assert.deepEqual([durText(205 * 60000), durText(42 * 60000)], ['3 h 25 min', '42 min']);
});

test('ride summary thresholds: under 2 km or 10 minutes, or a deleted trip, gets none', async () => {
  const r = await t.register('Short Rider', 'short.rider@coroute.test');
  await settle();
  const user = await t.gw.repo.findUserById(r.user.userId);
  const shortKm = await ride(user, { km: 1.5, minutes: 30 });
  const shortTime = await ride(user, { km: 5, minutes: 8 });
  for (const x of [shortKm, shortTime]) life().onTripFinished({ meta: x.meta, perMember: x.perMember });
  await settle();
  assert.equal((await t.gw.soda.query('mail_log', { groupId: shortKm.gid }, { limit: 5 })).length, 0, 'nothing queued for a short ride');
  // Queued, then the rider deleted the trip before it was due.
  life().tripDelayMs = 60000;
  const del = await ride(user);
  life().onTripFinished({ meta: del.meta, perMember: del.perMember });
  await settle();
  await t.gw.repo.deleteTrip(del.tripDoc.tripId, user.userId);
  const row = await t.gw.soda.findOne('mail_log', { key: `trip_memory:${del.gid}:${user.userId}` });
  await t.gw.soda.replace('mail_log', row.key, { ...row.value, dueAt: Date.now() - 1 });
  life().tripDelayMs = 0;
  await life().processDue();
  assert.equal(byKind('trip_memory', 'short.rider@coroute.test').length, 0);
  assert.equal((await t.gw.soda.findOne('mail_log', { key: `trip_memory:${del.gid}:${user.userId}` })).value.reason, 'TRIP_GONE');
});

test('the trip report hands every finished ride to the ride summary service', async () => {
  const r = await t.register('Report Rider', 'report.rider@coroute.test');
  await settle();
  const user = await t.gw.repo.findUserById(r.user.userId);
  const x = await ride(user, { others: [] });
  const calls = [];
  const real = t.gw.convoys.tripMemory;
  t.gw.convoys.tripMemory = { onTripFinished: (a) => { calls.push(a); } };
  try { await t.gw.timeline.finishTrip(x.gid); } finally { t.gw.convoys.tripMemory = real; }
  assert.equal(calls.length, 1);
  assert.equal(calls[0].meta.groupId, x.gid);
  assert.ok(calls[0].perMember.some((p) => p.userId === user.userId && p.tripDoc));
});

// ------------------------------------------------------------ categories, unsubscribe, suppression
test('categories: account page API, defaults, offers stay opt-in, account e-mails cannot be turned off', async () => {
  const r = await t.register('Pref Rider', 'pref.rider@coroute.test');
  await settle();
  let g = await t.api('GET', '/web/email-preferences', null, r.token);
  assert.equal(g.status, 200);
  assert.deepEqual(g.json.categories, { account: true, rideSummaries: true, tipsNews: true, offers: false });
  assert.equal(g.json.hasEmail, true);
  assert.equal((await t.api('GET', '/web/email-preferences')).status, 401);
  assert.equal((await t.api('PUT', '/web/email-preferences', { account: false }, r.token)).status, 400);
  assert.equal((await t.api('PUT', '/web/email-preferences', { rideSummaries: 'no' }, r.token)).status, 400);
  assert.equal((await t.api('PUT', '/web/email-preferences', { ads: true }, r.token)).status, 400);
  g = await t.api('PUT', '/web/email-preferences', { rideSummaries: false, offers: true }, r.token);
  assert.equal(g.status, 200);
  assert.deepEqual(g.json.categories, { account: true, rideSummaries: false, tipsNews: true, offers: true });
  assert.equal((await t.api('GET', '/web/marketing-consent', null, r.token)).json.offersEmail, true, 'offers use the existing consent');
  // DPDP: every change is kept with its time and source.
  const doc = (await t.gw.soda.findOne('email_preferences', { userId: r.user.userId })).value;
  assert.deepEqual(doc.history.map((h) => [h.category, h.on, h.source]), [['rideSummaries', false, 'website']]);
  // Opted out of ride summaries: none sent.
  const user = await t.gw.repo.findUserById(r.user.userId);
  const x = await ride(user);
  life().onTripFinished({ meta: x.meta, perMember: x.perMember });
  await settle();
  assert.equal(byKind('trip_memory', 'pref.rider@coroute.test').length, 0);
  assert.equal((await t.gw.soda.findOne('mail_log', { key: `trip_memory:${x.gid}:${user.userId}` })).value.reason, 'OPTED_OUT');
});

test('unsubscribe links: signed per category, GET only shows a button (scanners), POST / one-click turns it off', async () => {
  const r = await t.register('Unsub Rider', 'unsub.rider@coroute.test');
  await settle();
  const welcome = byKind('welcome', 'unsub.rider@coroute.test')[0];
  const link = welcome.headers['List-Unsubscribe'].slice(1, -1).replace('https://coroute.example', t.origin);
  const page = await fetch(link);
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /<form method="post"/);
  assert.match(html, /tips and news/);
  assert.match(page.headers.get('content-security-policy'), /default-src 'none'/);
  assert.equal((await t.api('GET', '/web/email-preferences', null, r.token)).json.categories.tipsNews, true, 'GET alone changes nothing');
  const one = await fetch(link, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'List-Unsubscribe=One-Click' });
  assert.equal(one.status, 200);
  assert.match(await one.text(), /You are unsubscribed/);
  const cats = (await t.api('GET', '/web/email-preferences', null, r.token)).json.categories;
  assert.deepEqual([cats.tipsNews, cats.rideSummaries, cats.account], [false, true, true], 'only that category');
  // Ride summaries link.
  const secret = `${require('../src/config').jwtSecret}:lifecycle`;
  const uid = r.user.userId;
  const rides = `${t.origin}/email/unsubscribe?u=${encodeURIComponent(uid)}&c=ride_summaries&t=${categoryToken(secret, 'ride_summaries', uid)}`;
  assert.equal((await fetch(rides, { method: 'POST' })).status, 200);
  assert.equal((await t.api('GET', '/web/email-preferences', null, r.token)).json.categories.rideSummaries, false);
  // Forged, swapped or unknown category tokens.
  assert.equal((await fetch(`${t.origin}/email/unsubscribe?u=${uid}&c=ride_summaries&t=${'a'.repeat(32)}`, { method: 'POST' })).status, 400);
  assert.equal((await fetch(`${t.origin}/email/unsubscribe?u=${uid}&c=tips_news&t=${categoryToken(secret, 'ride_summaries', uid)}`, { method: 'POST' })).status, 400);
  assert.equal((await fetch(`${t.origin}/email/unsubscribe?u=${uid}&c=account&t=${categoryToken(secret, 'account', uid)}`)).status, 400);
  // History has the source.
  const doc = (await t.gw.soda.findOne('email_preferences', { userId: uid })).value;
  assert.ok(doc.history.every((h) => h.source === 'unsubscribe'));
  // Offer links (no c) still go to the offers handler.
  const { unsubscribeToken } = require('../src/offer_emails');
  const offerLink = `${t.origin}/email/unsubscribe?u=${encodeURIComponent(uid)}&t=${unsubscribeToken(`${require('../src/config').jwtSecret}:offers`, uid)}`;
  const op = await fetch(offerLink);
  assert.equal(op.status, 200);
  assert.match(await op.text(), /offer e-mails/);
});

test('suppression: a bounced / complained / admin-suppressed address gets no lifecycle e-mail; an offers unsubscribe does not stop them', async () => {
  const offers = t.gw.notifications.offers;
  const a = await t.register('Bounce Rider', 'bounce.rider@coroute.test');
  const b = await t.register('Offers Quitter', 'quit.rider@coroute.test');
  await settle();
  await offers.suppress('bounce.rider@coroute.test', 'bounce', 'test');
  await offers.suppress('quit.rider@coroute.test', 'unsubscribe', 'rider');
  for (const r of [a, b]) {
    const user = await t.gw.repo.findUserById(r.user.userId);
    const x = await ride(user);
    life().onTripFinished({ meta: x.meta, perMember: x.perMember });
  }
  await settle();
  assert.equal(byKind('trip_memory', 'bounce.rider@coroute.test').length, 0);
  assert.equal(byKind('trip_memory', 'quit.rider@coroute.test').length, 1);
  const rows = await t.gw.soda.query('mail_log', { userId: a.user.userId, kind: 'trip_memory' }, { limit: 5 });
  assert.equal(rows[0].value.reason, 'SUPPRESSED');
  const pref = await t.api('GET', '/web/email-preferences', null, a.token);
  assert.equal(pref.json.suppressed, true);
});

test('retries: a failed SMTP send is retried by the job, at most 3 tries; account erase removes the rows', async () => {
  const r = await t.register('Retry Rider', 'retry.rider@coroute.test');
  await settle();
  const user = await t.gw.repo.findUserById(r.user.userId);
  const x = await ride(user);
  const real = mailTransport.sendMail;
  let fails = 1;
  mailTransport.sendMail = async (m) => { if (fails > 0 && m.to === 'retry.rider@coroute.test') { fails--; throw Object.assign(new Error('down'), { code: 'ECONNREFUSED' }); } return real(m); };
  try {
    life().onTripFinished({ meta: x.meta, perMember: x.perMember });
    await settle();
    const key = `trip_memory:${x.gid}:${user.userId}`;
    let row = await t.gw.soda.findOne('mail_log', { key });
    assert.deepEqual([row.value.status, row.value.attempts, row.value.error], ['RETRY', 1, 'ECONNREFUSED']);
    await t.gw.soda.replace('mail_log', row.key, { ...row.value, dueAt: Date.now() - 1 });
    await life().processDue();
    row = await t.gw.soda.findOne('mail_log', { key });
    assert.deepEqual([row.value.status, row.value.attempts], ['SENT', 2]);
    assert.equal(byKind('trip_memory', 'retry.rider@coroute.test').length, 1);
  } finally { mailTransport.sendMail = real; }
  await t.gw.repo.deleteUserCascade(await t.gw.repo.findUserById(r.user.userId), {}).catch(() => {});
  await new Promise((res) => setTimeout(res, 20));
  assert.equal((await t.gw.soda.query('mail_log', { userId: r.user.userId }, { limit: 5 })).length, 0);
  assert.equal(await t.gw.soda.findOne('email_preferences', { userId: r.user.userId }), null);
});

test('no SMTP: nothing is queued or sent, and registration is never held up', async () => {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  const mailer = new Mailer({ env: {}, logger: quiet });
  assert.equal(mailer.enabled, false);
  const svc = new LifecycleEmails({ soda, repo, mailer, templates: new TemplateStore({ soda, logger: quiet }), config: { publicOrigin: 'https://coroute.example' }, logger: quiet, tripDelayMs: 0 });
  assert.deepEqual(await svc.enqueueWelcome({ userId: 'usr_a', email: 'a@b.test', name: 'A' }), { skipped: 'MAIL_DISABLED' });
  assert.equal(svc.onTripFinished({ meta: { groupId: 'GRP-1' }, perMember: [] }), null);
  assert.equal(await svc.processDue(), 0);
  await svc.idle();
  await soda.ensureCollection('mail_log');
  assert.equal((await soda.query('mail_log', {}, { limit: 5 })).length, 0);
  // No valid e-mail on the account: nothing queued either (with SMTP on).
  const on = new LifecycleEmails({ soda, repo, mailer: { enabled: true, send: async () => ({ sent: true }) }, templates: new TemplateStore({ soda, logger: quiet }), config: {}, logger: quiet });
  assert.deepEqual(await on.enqueueWelcome({ userId: 'usr_b', email: 'not-an-address', name: 'B' }), { skipped: 'NO_EMAIL' });
});

test('website: /guide page, /trip page shell (owner-only data), account e-mail choices', async () => {
  const g = await fetch(`${t.origin}/guide`);
  assert.equal(g.status, 200);
  const gh = await g.text();
  assert.ok(gh.includes('Emergency contact') && gh.includes('Add your bike') && gh.includes('call <b>112</b>'));
  assert.ok((await (await fetch(`${t.origin}/sitemap.xml`)).text()).includes('/guide</loc>'));
  const tp = await fetch(`${t.origin}/trip/TRIP-ABC-usr_x`);
  assert.equal(tp.status, 200);
  assert.equal(tp.headers.get('cache-control'), 'no-store');
  assert.match(tp.headers.get('x-robots-tag'), /noindex/);
  assert.ok((await tp.text()).includes('/assets/trip.js'));
  assert.equal((await fetch(`${t.origin}/trip/%3Cscript%3E`)).status, 404);
  // The trip API behind the page is the owner's only.
  const owner = await t.register('Trip Owner', 'trip.owner@coroute.test');
  const other = await t.register('Trip Other', 'trip.other@coroute.test');
  const user = await t.gw.repo.findUserById(owner.user.userId);
  const x = await ride(user);
  assert.equal((await t.api('GET', `/trips/${encodeURIComponent(x.tripDoc.tripId)}`, null, owner.token)).status, 200);
  assert.equal((await t.api('GET', `/trips/${encodeURIComponent(x.tripDoc.tripId)}`, null, other.token)).status, 404);
  const fs = require('fs');
  const acc = fs.readFileSync(require('path').join(__dirname, '../public/account.html'), 'utf8');
  for (const id of ['id="emails"', 'id="ac-rides"', 'id="ac-tips"', 'id="ac-offers"', 'id="ac-account"']) assert.ok(acc.includes(id), id);
  await settle();
});
