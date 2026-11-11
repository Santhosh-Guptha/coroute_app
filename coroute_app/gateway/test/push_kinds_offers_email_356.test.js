'use strict';
/**
 * 3.56 push kinds and Offers e-mails (src/push_campaigns.js KINDS, src/offer_emails.js):
 * kinds with their own Android channel and rider opt-out (partner perks off until turned on), the
 * Partner perk guard (real-world perks only, never a CoRoute plan, price, coupon or link), Offers
 * e-mails with marketing consent (off by default), the unsubscribe link / one-click, the suppression
 * list, and the coupon block linking to /plans?coupon=.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'kinds.admin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
delete process.env.FCM_SERVICE_ACCOUNT_JSON;
delete process.env.FCM_SERVICE_ACCOUNT_FILE;

const fs = require('fs');
const path = require('path');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { PushCampaigns, KINDS, KIND_IDS } = require('../src/push_campaigns');
const { partnerPerkTermIn, forbiddenTermIn } = require('../src/policy_terms');
const { OfferEmails, buildOfferEmail, renderContent, unsubscribeToken, emailHash } = require('../src/offer_emails');

const DAY = 86400000;
const quiet = { info() {}, warn() {} };

// ------------------------------------------------------------ kinds and channels
test('push kinds: own Android channel each, partner perks off by default, safety stays outside', () => {
  assert.deepEqual(KIND_IDS, ['update', 'event', 'safety_tip', 'community', 'partner_perk']);
  const channels = KIND_IDS.map((k) => KINDS[k].channel);
  assert.equal(new Set(channels).size, KIND_IDS.length, 'one channel per kind');
  assert.equal(KINDS.update.channel, 'coroute_news', 'updates keep the existing "News and updates" channel');
  assert.equal(KINDS.update.pref, 'news', 'and the existing switch');
  assert.equal(KINDS.partner_perk.defaultOn, false);
  for (const k of ['update', 'event', 'safety_tip', 'community']) assert.equal(KINDS[k].defaultOn, true, k);
  // The Kotlin service and the Dart catalog name the same channels.
  const kt = fs.readFileSync(path.join(__dirname, '../../android/app/src/main/kotlin/space/devmonks/coroute_app/CoRouteMessagingService.kt'), 'utf8');
  const dart = fs.readFileSync(path.join(__dirname, '../../lib/domain/notify/push_kinds.dart'), 'utf8');
  for (const k of KIND_IDS) {
    assert.ok(kt.includes(`"${KINDS[k].channel}"`), `Kotlin has ${KINDS[k].channel}`);
    assert.ok(dart.includes(`'${KINDS[k].channel}'`), `Dart has ${KINDS[k].channel}`);
    assert.ok(dart.includes(`'${k}'`), `Dart has kind ${k}`);
  }
});

async function unitSetup({ now }) {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  for (const uid of ['u1', 'u2', 'u3']) {
    await soda.insert('users', { userId: uid, email: `${uid}@x.test`, lastLoginAt: now });
  }
  await soda.ensureCollection('push_tokens');
  for (const uid of ['u1', 'u2', 'u3']) await soda.insert('push_tokens', { userId: uid, token: `tok_${uid}_${'z'.repeat(30)}`, platform: 'android' });
  const calls = [];
  const push = { enabled: true, async notifyUsers(ids, msg) { calls.push({ ids, msg }); return { sent: 1, failed: 0, skipped: 0 }; } };
  const clock = { t: now };
  const svc = new PushCampaigns({ soda, repo, push, origin: 'https://coroute.example', clock: () => clock.t, sleep: async () => {}, batchSize: 10, ratePerSec: 100, dailyCap: 5, logger: quiet });
  return { soda, repo, svc, calls, clock };
}

test('opt-outs per kind; partner perks only to riders who turned them on, at most one a week', async () => {
  const now = Date.UTC(2026, 10, 11, 6, 0);
  const { svc, calls, clock } = await unitSetup({ now });
  await svc.setPrefs('u1', { events: false });
  await svc.setPrefs('u2', { partnerPerks: true });
  assert.deepEqual(await svc.prefsOf('u3'), { news: true, events: true, safetyTips: true, community: true, partnerPerks: false });
  const send = async (input) => { calls.length = 0; const c = await svc.create({ audience: { kind: 'all' }, ...input }); await svc.tick(); return { c: await svc.get(c.campaignId), to: calls.map((x) => x.ids[0]).sort(), msg: calls[0] && calls[0].msg }; };

  const ev = await send({ kind: 'event', title: 'Sunday breakfast ride', body: 'Meet the crew at 7 at the lake.' });
  assert.deepEqual(ev.to, ['u2', 'u3'], 'u1 turned Events off');
  assert.equal(ev.c.stats.optedOut, 1);
  assert.deepEqual([ev.msg.type, ev.msg.data.kind, ev.msg.data.channel], ['NEWS', 'event', 'coroute_events']);

  const tip = await send({ kind: 'safety_tip', title: 'Rain riding', body: 'Brake earlier and keep a longer gap in the rain.' });
  assert.deepEqual(tip.to, ['u1', 'u2', 'u3']);
  assert.equal(tip.msg.data.channel, 'coroute_safety_tips');

  const perk = { kind: 'partner_perk', partnerName: 'Speed Garage', curated: true, title: 'Partner perk for riders', body: '10% off a chain service at Speed Garage this month for CoRoute riders.' };
  const p1 = await send(perk);
  assert.deepEqual(p1.to, ['u2'], 'only the rider who turned partner perks on');
  assert.deepEqual([p1.msg.data.kind, p1.msg.data.channel, p1.msg.data.partner], ['partner_perk', 'coroute_partner_perks', 'Speed Garage']);
  const p2 = await send(perk);
  assert.deepEqual(p2.to, [], 'one partner perk a week');
  assert.equal(p2.c.stats.capped, 1);
  clock.t = now + 8 * DAY;
  assert.deepEqual((await send(perk)).to, ['u2'], 'next week again');
  // Old campaigns without a kind are updates.
  assert.equal((await send({ title: 'New in the app', body: 'Ride replays are here.' })).msg.data.kind, 'update');
});

test('partner perk guard: real-world perks only; no CoRoute plan, price, coupon, code or link', async () => {
  const now = Date.UTC(2026, 10, 11, 6, 0);
  const { svc } = await unitSetup({ now });
  const base = { kind: 'partner_perk', partnerName: 'Speed Garage', curated: true, title: 'A perk from Speed Garage', audience: { kind: 'all' } };
  assert.equal(partnerPerkTermIn('10% off a chain service at Speed Garage'), null);
  assert.equal(partnerPerkTermIn('A deal on riding gloves at the partner store, sale this weekend'), null);
  assert.ok(forbiddenTermIn('10% off a chain service'), 'an ordinary push still refuses "% off"');
  for (const [body, why] of [
    ['20% off Large Group plan', 'CoRoute plan'], ['Use code RIDE10 for 10% off', 'code'], ['Get a coupon at the garage', 'coupon'],
    ['Service for ₹499 only', 'amount'], ['Buy gloves at 10% off', 'buy'], ['Pay at the counter and save', 'pay'],
    ['Membership riders get 5% off', 'membership'], ['Promo code inside', 'promo code'], ['10% off at speedgarage.in', 'link'],
  ]) {
    await assert.rejects(svc.validate({ ...base, body }), (e) => e.status === 422 || e.code === 'NO_LINKS', why);
  }
  await assert.rejects(svc.validate({ ...base, body: '10% off a service.', partnerName: '' }), /Name the partner/);
  await assert.rejects(svc.validate({ ...base, body: '10% off a service.', curated: false }), /curated/);
  await assert.rejects(svc.validate({ ...base, kind: 'advert', body: 'x' }), /Choose a kind/);
  const ok = await svc.validate({ ...base, body: '10% off a chain service at Speed Garage for CoRoute riders.' });
  assert.deepEqual([ok.kind, ok.partnerName], ['partner_perk', 'Speed Garage']);
  // Other kinds keep the strict guard and say why offers are e-mail only.
  await assert.rejects(svc.validate({ kind: 'event', title: 'Ride', body: 'Get 20% off plans', audience: { kind: 'all' } }), /Channel "Email"/);
});

// ------------------------------------------------------------ offers e-mail
async function offerSetup({ now = Date.UTC(2026, 10, 11, 6, 0) } = {}) {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  for (const [uid, email] of [['r1', 'one@x.test'], ['r2', 'two@x.test'], ['r3', 'three@x.test'], ['r4', 'bad-address']]) {
    await soda.insert('users', { userId: uid, email, lastLoginAt: now });
  }
  await repo.saveCoupon({ code: 'RIDE50', discountType: 'percentage', discountValue: 50, applicableTiers: ['all'], status: 'ACTIVE', isActive: true, maxUsageTotal: 100, maxUsagePerUser: 1 }).catch(async () => {
    await soda.ensureCollection('coupons'); await soda.insert('coupons', { code: 'RIDE50', discountType: 'percentage', discountValue: 50, status: 'ACTIVE' });
  });
  const mails = [];
  const mailer = { enabled: true, async send(m) { mails.push(m); return { sent: true, messageId: `m${mails.length}` }; } };
  const clock = { t: now };
  const svc = new OfferEmails({ soda, repo, mailer, origin: 'https://coroute.example', secret: 'unit-secret', clock: () => clock.t, sleep: async () => {}, logger: quiet });
  return { soda, repo, svc, mails, clock };
}

const offer = { subject: 'Ride together for less', heading: 'Large Group launch offer', content: 'Plan your next group ride.\n\n- Group talk\n- Live map\n\n**Ends Sunday.** See [all plans](/plans).',
  coupon: { code: 'ride50', headline: '50% off your first month', note: 'On Large Group until 30 Nov.' }, audience: { kind: 'all' } };

test('offers e-mail: consent off by default, only opted-in riders, unsubscribe in every mail, suppression respected', async () => {
  const { svc, mails } = await offerSetup();
  assert.deepEqual((await svc.consentOf('r1')).offersEmail, false, 'off by default');
  await svc.setConsent('r1', true, { email: 'one@x.test' });
  await svc.setConsent('r2', true, { email: 'two@x.test' });
  await svc.setConsent('r4', true, {});
  await svc.suppress('TWO@x.test', 'bounce', 'admin');
  assert.deepEqual((await svc.audienceCount({ kind: 'all' })).riders, 1, 'r2 suppressed, r3 never opted in, r4 has no valid address');
  const c = await svc.create(offer);
  await svc.tick();
  const done = await svc.get(c.campaignId);
  assert.equal(done.status, 'SENT');
  assert.equal(mails.length, 1);
  const m = mails[0];
  assert.equal(m.to, 'one@x.test');
  assert.equal(m.subject, 'Ride together for less');
  const unsub = `https://coroute.example/email/unsubscribe?u=r1&t=${unsubscribeToken('unit-secret', 'r1')}`;
  assert.ok(m.html.includes(unsub.replace(/&/g, '&amp;')), 'unsubscribe link in the HTML');
  assert.ok(m.text.includes(unsub), 'and in the text part');
  assert.equal(m.headers['List-Unsubscribe'], `<${unsub}>`);
  assert.equal(m.headers['List-Unsubscribe-Post'], 'List-Unsubscribe=One-Click');
  // Coupon block: the code and a button to /plans?coupon=CODE.
  assert.ok(m.html.includes('RIDE50'));
  assert.ok(m.html.includes('https://coroute.example/plans?coupon=RIDE50'));
  assert.ok(m.text.includes('Use code RIDE50: https://coroute.example/plans?coupon=RIDE50'));
  // Unsubscribe: a bad token does nothing; a good one turns consent off and suppresses the address.
  assert.equal(await svc.unsubscribe('r1', 'x'.repeat(32)), false);
  assert.equal(await svc.unsubscribe('r1', unsubscribeToken('unit-secret', 'r1')), true);
  assert.equal((await svc.consentOf('r1')).offersEmail, false);
  assert.equal(await svc.isSuppressed('one@x.test'), true);
  assert.equal((await svc.listSuppression()).find((x) => x.emailHash === emailHash('one@x.test')).reason, 'unsubscribe');
  assert.equal((await svc.audienceCount({ kind: 'all' })).riders, 0);
  // Opting in again lifts the rider's own unsubscribe entry, never a bounce.
  await svc.setConsent('r1', true, { email: 'one@x.test' });
  await svc.setConsent('r2', true, { email: 'two@x.test' });
  assert.equal(await svc.isSuppressed('one@x.test'), false);
  assert.equal(await svc.isSuppressed('two@x.test'), true);
});

test('offers e-mail: consent and suppression re-checked at send time; validation of coupon, links and content', async () => {
  const { svc, mails } = await offerSetup();
  await svc.setConsent('r1', true, { email: 'one@x.test' });
  await svc.setConsent('r3', true, { email: 'three@x.test' });
  const c = await svc.create({ ...offer, sendAt: Date.now() + 3600000 });
  await svc.setConsent('r3', false);
  svc.clock = () => Date.now() + 2 * 3600000;
  await svc.tick();
  assert.deepEqual(mails.map((m) => m.to), ['one@x.test']);
  // The audience was resolved at send time: r3 had already opted out.
  assert.equal((await svc.get(c.campaignId)).stats.sent, 1);
  await assert.rejects(svc.validate({ ...offer, coupon: { code: 'NOPE99' } }), /no coupon NOPE99/);
  await assert.rejects(svc.validate({ ...offer, content: 'Go to [our partner](https://evil.example/x)' }), /only point to this site/);
  await assert.rejects(svc.validate({ ...offer, subject: '' }), /subject/);
  await assert.rejects(svc.validate({ ...offer, content: 'x'.repeat(5001) }), /longer/);
  // HTML in the content is escaped text, never markup.
  const r = renderContent('<script>alert(1)</script> **bold**', 'https://coroute.example');
  assert.ok(!r.html.includes('<script>'));
  assert.ok(r.html.includes('&lt;script&gt;'));
  assert.ok(r.html.includes('<strong>bold</strong>'));
  const mail = buildOfferEmail({ subject: 'S', content: 'Hi', origin: 'https://coroute.example', unsubscribeUrl: 'https://coroute.example/email/unsubscribe?u=a&t=b', accountUrl: 'https://coroute.example/account' });
  assert.ok(mail.html.includes('https://coroute.example/plans'), 'no coupon: the button opens /plans');
});

// ------------------------------------------------------------ through the HTTP API
let env, admin, rider;
const mails = [];
before(async () => {
  env = await boot({ mailTransport: { async sendMail(m) { mails.push(m); return { messageId: `<k${mails.length}@t>` }; } } });
  admin = await env.register('Kinds Admin', 'kinds.admin@coroute.test');
  rider = await env.register('Kinds Rider', 'kinds.rider@coroute.test');
});
after(async () => { await env.gw.shutdown(); });

test('API: per-kind push switches (safety cannot be turned off)', async () => {
  let r = await env.api('GET', '/me/push-prefs', null, rider.token);
  assert.deepEqual(r.json, { news: true, events: true, safetyTips: true, community: true, partnerPerks: false, safety: true });
  r = await env.api('PUT', '/me/push-prefs', { partnerPerks: true, events: false }, rider.token);
  assert.equal(r.status, 200);
  assert.deepEqual([r.json.partnerPerks, r.json.events, r.json.news], [true, false, true]);
  assert.equal((await env.api('PUT', '/me/push-prefs', { safety: false }, rider.token)).status, 400);
  assert.equal((await env.api('PUT', '/me/push-prefs', { ads: true }, rider.token)).status, 400);
  assert.equal((await env.api('PUT', '/me/push-prefs', { events: 'no' }, rider.token)).status, 400);
  const cfg = await env.api('GET', '/admin/push/config', null, admin.token);
  assert.deepEqual(cfg.json.kinds.map((k) => k.id), KIND_IDS);
});

test('API: website consent, unsubscribe page and one-click, admin-only offers e-mail routes', async () => {
  let r = await env.api('GET', '/web/marketing-consent', null, rider.token);
  assert.deepEqual([r.status, r.json.offersEmail, r.json.hasEmail], [200, false, true]);
  r = await env.api('PUT', '/web/marketing-consent', { offersEmail: true }, rider.token);
  assert.deepEqual([r.status, r.json.offersEmail], [200, true]);
  assert.equal((await env.api('PUT', '/web/marketing-consent', { offersEmail: 'yes' }, rider.token)).status, 400);
  // Admin-only.
  assert.equal((await env.api('POST', '/admin/email/offers/preview', { subject: 'S', content: 'C' }, rider.token)).status, 403);
  const prev = await env.api('POST', '/admin/email/offers/preview', { subject: 'Ride for less', content: 'Plans for groups.' }, admin.token);
  assert.equal(prev.status, 200, JSON.stringify(prev.json));
  assert.match(prev.json.html, /Unsubscribe/);
  const cnt = await env.api('POST', '/admin/email/offers/audience-count', { audience: { kind: 'all' } }, admin.token);
  assert.equal(cnt.json.riders, 1);
  // The unsubscribe link: GET shows a button (scanners never unsubscribe), POST unsubscribes.
  const secret = `${require('../src/config').jwtSecret}:offers`;
  const uid = rider.user.userId;
  const link = `${env.origin}/email/unsubscribe?u=${encodeURIComponent(uid)}&t=${unsubscribeToken(secret, uid)}`;
  const page = await fetch(link);
  assert.equal(page.status, 200);
  assert.match(await page.text(), /<form method="post"/);
  assert.equal((await env.api('GET', '/web/marketing-consent', null, rider.token)).json.offersEmail, true, 'GET alone changes nothing');
  const one = await fetch(link, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'List-Unsubscribe=One-Click' });
  assert.equal(one.status, 200);
  const after2 = (await env.api('GET', '/web/marketing-consent', null, rider.token)).json;
  assert.deepEqual([after2.offersEmail, after2.suppressed], [false, true]);
  assert.equal((await fetch(`${env.origin}/email/unsubscribe?u=${uid}&t=${'a'.repeat(32)}`, { method: 'POST' })).status, 400);
  const supp = await env.api('GET', '/admin/email/suppression', null, admin.token);
  assert.equal(supp.json.entries[0].reason, 'unsubscribe');
  assert.ok(!JSON.stringify(supp.json).includes('kinds.rider@coroute.test'), 'addresses are masked');
  // The account page offers the switch.
  const html = fs.readFileSync(path.join(__dirname, '../public/account.html'), 'utf8');
  assert.match(html, /id="ac-offers"/);
});
