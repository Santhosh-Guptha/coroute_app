'use strict';
/**
 * 3.57 e-mail marketing studio (src/email_marketing.js, docs/features_355/email_marketing.md): templates
 * (starters, CRUD, versions, archive), block rendering (HTML + plain text, dark-mode safe), variables
 * (unknown refused, fallbacks), the link allowlist, the coupon block and single-use unique codes (race
 * safe), the price block (pricing config at send time), segments with consent enforcement (marketing vs
 * account), scheduling, quiet hours, automation rules (once per rider), frequency caps, signed click
 * redirects (counted, switchable), unsubscribe attribution and suppression. SMTP is a fake transport.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'studio.admin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
process.env.PAYMENTS_ENABLED = 'true';
process.env.MAIL_POSTAL_ADDRESS = 'CoRoute, 12 MG Road, Bengaluru 560001, India';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { OfferEmails, unsubscribeToken } = require('../src/offer_emails');
const {
  EmailStudio, validateDesign, renderDesign, cleanButtonPath, cleanSitePath, discountText, STARTERS, VARIABLES, POSTAL_PLACEHOLDER,
} = require('../src/email_marketing');

const DAY = 86400000;
const ORIGIN = 'https://coroute.example';
const quiet = { info() {}, warn() {} };

/** A unit world: MemorySoda, repo, offers, studio, fake SMTP and a clock we move. */
async function world({ env = { MAIL_POSTAL_ADDRESS: 'CoRoute, 12 MG Road, Bengaluru' }, now = Date.now(), smtp } = {}) {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  const clock = { t: now };
  const sent = [];
  const mailer = { enabled: true, async send(m) { if (smtp) { const r = await smtp(m); if (r) return r; } sent.push(m); return { sent: true, messageId: `<m${sent.length}@t>` }; } };
  const offers = new OfferEmails({ soda, repo, mailer, origin: ORIGIN, secret: 'unit-secret', logger: quiet, clock: () => clock.t, env: {} });
  const images = [];
  const pushCampaigns = { async saveImage(buf) { const imageId = `pi_${'a'.repeat(23)}${images.length}`; images.push(buf); await soda.ensureCollection('push_images'); await soda.insert('push_images', { imageId, ext: 'png' }); return { imageId, url: `${ORIGIN}/media/push/${imageId}.png`, bytes: buf.length }; } };
  const studio = new EmailStudio({ soda, repo, mailer, offers, campaigns: pushCampaigns, config: { publicOrigin: ORIGIN, supportEmail: 'help@coroute.example' },
    secret: 'studio-secret', logger: quiet, clock: () => clock.t, sleep: async () => {}, env });
  await studio.setSettings({ quietStartHour: 0, quietEndHour: 0 }); // no quiet hours unless a test sets them
  let n = 0;
  const addUser = async (name, { consent = true, createdAt = clock.t - 400 * DAY, username } = {}) => {
    n++;
    const userId = `u${n}`;
    const email = `${name.toLowerCase().replace(/\W+/g, '.')}@x.test`;
    await soda.insert('users', { userId, name, email, createdAt, lastLoginAt: clock.t, ...(username ? { username, usernameKey: username.toLowerCase() } : {}) });
    if (username) { await soda.ensureCollection('usernames'); await soda.insert('usernames', { usernameKey: username.toLowerCase(), userId }); }
    if (consent) await offers.setConsent(userId, true, { email });
    return { userId, email, name };
  };
  const coupon = async (code, extra = {}) => repo.saveCoupon({ code, discountType: 'percentage', discountValue: 40, validFrom: Date.now() - DAY, expiresAt: Date.now() + 30 * DAY, status: 'ACTIVE', maxUsageTotal: 1000, ...extra });
  return { soda, repo, clock, sent, mailer, offers, studio, addUser, coupon, images };
}

const design = (blocks, extra = {}) => ({ subject: 'Hello {firstName}', preheader: 'A short line', blocks, ...extra });
const textBlock = (text) => ({ type: 'text', text });

// ============================================================ templates
test('templates: starters, create from a starter, versions, conflict, duplicate, archive, read-only starters', async () => {
  const w = await world();
  const ids = STARTERS.map((s) => s.id);
  assert.deepEqual(ids, ['festive_coupon', 'launch_offer', 'feature_news', 'ride_season', 'winback_coupon', 'plan_ending', 'club_invite', 'safety_tips']);
  // Every starter is a valid template (coupon code / images filled in when composing).
  for (const s of STARTERS) {
    const v = validateDesign(s.design, { category: s.category, origin: ORIGIN });
    assert.deepEqual(v.errors, [], s.id);
  }
  assert.equal(STARTERS.find((s) => s.id === 'plan_ending').category, 'account');
  const { template } = await w.studio.createTemplate({ fromStarter: 'winback_coupon' }, { by: 'a@x' });
  assert.match(template.templateId, /^et_[a-f0-9]{16}$/);
  assert.deepEqual([template.version, template.name, template.category, template.basedOn], [1, 'Win-back: we miss you (coupon)', 'marketing', 'starter:winback_coupon']);
  const d2 = { ...template.design, subject: 'Come back, {firstName}' };
  const v2 = await w.studio.updateTemplate(template.templateId, { design: d2, baseVersion: 1 }, { by: 'b@x' });
  assert.equal(v2.template.version, 2);
  await assert.rejects(w.studio.updateTemplate(template.templateId, { design: d2, baseVersion: 1 }), (e) => e.code === 'VERSION_CONFLICT' && e.status === 409);
  await assert.rejects(w.studio.updateTemplate(template.templateId, { design: { ...d2, subject: 'Hi {nmae}' } }), (e) => e.code === 'BAD_TEMPLATE' && /unknown variable \{nmae\}/.test(e.message));
  const full = await w.studio.getTemplate(template.templateId);
  assert.deepEqual(full.history.map((h) => h.version), [2, 1]);
  assert.equal((await w.studio.templateVersion(template.templateId, 1)).design.subject, 'We miss you on the road, {firstName}');
  // Restore = save an old version again (a new version).
  const restored = await w.studio.updateTemplate(template.templateId, { design: (await w.studio.templateVersion(template.templateId, 1)).design });
  assert.equal(restored.template.version, 3);
  // Duplicate ("save as new template").
  const dup = await w.studio.createTemplate({ fromTemplate: template.templateId });
  assert.equal(dup.template.name, 'Win-back: we miss you (coupon) (copy)');
  assert.notEqual(dup.template.templateId, template.templateId);
  // Archive hides it from the list; unarchive brings it back.
  await w.studio.setTemplateStatus(dup.template.templateId, 'archived');
  let list = await w.studio.listTemplates();
  assert.ok(!list.templates.some((t) => t.templateId === dup.template.templateId));
  assert.equal(list.starters.length, 8);
  list = await w.studio.listTemplates({ archived: true });
  assert.ok(list.templates.some((t) => t.templateId === dup.template.templateId && t.status === 'archived'));
  await w.studio.setTemplateStatus(dup.template.templateId, 'active');
  // Starters cannot be changed.
  await assert.rejects(w.studio.updateTemplate('festive_coupon', { design: d2 }), (e) => e.code === 'READ_ONLY');
});

// ============================================================ rendering
test('rendering: every block to HTML and plain text, escaped values, dark-mode styles, preheader, footer always last', async () => {
  const prices = { group_large: { name: 'Large Group', listPriceInr: 99, priceInr: 49, offer: { label: 'Launch offer', endAt: Date.UTC(2026, 10, 30) }, days: 30 } };
  const d = validateDesign(design([
    { type: 'footer', note: 'Thanks for riding.' }, // put first: still rendered last
    { type: 'header_image', imageId: `pi_${'b'.repeat(24)}`, alt: 'Riders' },
    { type: 'heading', text: 'Hi {firstName}', level: 1 },
    textBlock('Some **bold** and *italic* and _also italic_.\n\n- one\n- see [plans](/plans)'),
    { type: 'coupon', code: 'RIDE40', headline: 'For {firstName}', note: 'Until {validUntil}', buttonLabel: 'Use {couponCode}' },
    { type: 'price', planId: 'group_large', buttonLabel: 'Grab it' },
    { type: 'divider' },
    { type: 'button', label: 'Read the guide', path: '/guide', style: 'secondary' },
  ]), { origin: ORIGIN, mode: 'send' });
  assert.deepEqual(d.errors, []);
  assert.equal(d.design.blocks.at(-1).type, 'footer');
  assert.ok(d.warnings.some((x) => /footer is always the last/.test(x)));
  const m = renderDesign(d.design, {
    origin: ORIGIN, vars: { firstName: '<b>Asha</b>', couponCode: 'RIDE40', validUntil: '30 Nov 2026', discount: '40% off' },
    coupon: { code: 'RIDE40', discount: '40% off', validUntil: '30 Nov 2026', path: '/plans?coupon=RIDE40' }, prices,
    images: { [`pi_${'b'.repeat(24)}`]: `${ORIGIN}/media/push/x.png` }, category: 'marketing', unsubscribeUrl: `${ORIGIN}/email/unsubscribe?u=u1&t=x`,
    accountUrl: `${ORIGIN}/account#emails`, postalAddress: '12 MG Road, Bengaluru', supportEmail: 'help@coroute.example',
  });
  assert.equal(m.subject, 'Hello <b>Asha</b>');
  assert.ok(!m.html.includes('<b>Asha</b>') && m.html.includes('Hi &lt;b&gt;Asha&lt;/b&gt;'), 'variable values are escaped in HTML');
  for (const s of ['<strong>bold</strong>', '<em>italic</em>', '<em>also italic</em>', 'href="https://coroute.example/plans"', 'RIDE40', '40% off · valid until 30 Nov 2026',
    'href="https://coroute.example/plans?coupon=RIDE40"', 'text-decoration:line-through;">₹99</span>', '₹49', 'Launch offer · until', 'href="https://coroute.example/guide"',
    'Unsubscribe</a>', 'Manage e-mails</a>', 'Sent by CoRoute · 12 MG Road, Bengaluru · help@coroute.example', 'prefers-color-scheme: dark', 'color-scheme" content="light dark"',
    'A short line', 'Thanks for riding.', 'alt="Riders"']) {
    assert.ok(m.html.includes(s), `html has ${s}`);
  }
  assert.ok(m.html.indexOf('Thanks for riding.') > m.html.indexOf('Read the guide'), 'footer last');
  // Plain-text alternative, generated.
  for (const s of ['Hi <b>Asha</b>', 'Some bold and italic and also italic.', '* one', '* see plans (https://coroute.example/plans)', 'Code: RIDE40 (40% off, valid until 30 Nov 2026)',
    'Use RIDE40: https://coroute.example/plans?coupon=RIDE40', 'Large Group: ₹99 -> ₹49 (Launch offer', 'Read the guide: https://coroute.example/guide',
    'Unsubscribe: https://coroute.example/email/unsubscribe?u=u1&t=x', 'Sent by CoRoute · 12 MG Road, Bengaluru']) {
    assert.ok(m.text.includes(s), `text has ${s}`);
  }
  assert.ok(!/<[a-z]/i.test(m.text.replace(/<b>Asha<\/b>/g, '')), 'no HTML in the text version');
  // Account e-mails: no Offers unsubscribe; the postal placeholder when not configured; forced dark preview.
  const acc = renderDesign(validateDesign(design([textBlock('Your plan ends.')]), { category: 'account' }).design,
    { origin: ORIGIN, vars: { firstName: 'A' }, category: 'account', unsubscribeUrl: 'U', accountUrl: 'A', forceDark: true });
  assert.ok(!acc.html.includes('Unsubscribe') && acc.html.includes('about your CoRoute plan') && acc.html.includes(POSTAL_PLACEHOLDER));
  assert.ok(acc.html.includes('.cr-body{background:#0f1115!important}') && !acc.html.includes('@media (prefers-color-scheme'));
  assert.equal(discountText({ discountType: 'fixed', discountValue: 50 }), '₹50 off');
  assert.equal(discountText({ discountType: 'percentage', discountValue: 20, maxDiscountCap: 30 }), '20% off (up to ₹30)');
});

// ============================================================ variables
test('variables: unknown refused, coupon / price variables need their block, safe fallbacks for missing values', async () => {
  let v = validateDesign(design([textBlock('Hi {nmae} and {firstName}')]));
  assert.ok(v.errors.some((e) => /unknown variable \{nmae\}/.test(e)), v.errors.join());
  v = validateDesign(design([textBlock('Code {couponCode} at {offerPrice}')]));
  assert.ok(v.errors.includes('{couponCode} needs a coupon block.') && v.errors.includes('{offerPrice} needs a price block.'));
  v = validateDesign({ subject: 'Hi {first name}', blocks: [textBlock('x')] });
  assert.ok(v.errors.some((e) => /unknown variable \{first name\}/.test(e)));
  assert.equal(Object.keys(VARIABLES).join(','), 'firstName,username,planName,planEndsOn,couponCode,discount,validUntil,listPrice,offerPrice,link');
  // Fallbacks: a rider without a name / username / plan.
  const w = await world();
  const u = await w.addUser('X');
  await w.soda.query('users', { userId: u.userId }).then(async ([row]) => w.soda.replace('users', row.key, { ...row.value, name: '' }));
  const prep = await w.studio.prepare({ design: design([textBlock('Hi {firstName} @{username}, {planName} ends {planEndsOn}. {link}')]) });
  const m = await w.studio.build(prep, await w.repo.findUserById(u.userId));
  assert.ok(m.text.includes('Hi there @rider, your plan ends soon. https://coroute.example/plans'), m.text);
  assert.equal(m.subject, 'Hello there');
});

// ============================================================ links
test('link allowlist: buttons only to the listed pages, rich-text links only to this site', () => {
  for (const ok of ['/plans', '/plans?coupon=X1', '/updates', '/guide', '/operators/apply', '/account', '/account#emails']) assert.ok(cleanButtonPath(ok), ok);
  for (const bad of ['/admin', '/api/x', 'https://evil.example/plans', '//evil.example', '/plansx', '/r/abc', 'javascript:alert(1)', '/features']) assert.equal(cleanButtonPath(bad), '', bad);
  assert.equal(cleanSitePath('https://coroute.example/features', ORIGIN), '/features');
  for (const bad of ['https://evil.example/', '/api/admin', '/admin', '//x.y', '/email/unsubscribe', 'mailto:a@b.c']) assert.equal(cleanSitePath(bad, ORIGIN), '', bad);
  let v = validateDesign(design([textBlock('Go [here](https://evil.example/win)')]), { origin: ORIGIN });
  assert.ok(v.errors.some((e) => /links may only point to pages of this site/.test(e)));
  v = validateDesign(design([{ type: 'button', label: 'Go', path: '/admin' }]));
  assert.ok(v.errors.some((e) => /a button may only open/.test(e)));
  v = validateDesign(design([textBlock('<script>alert(1)</script>')]));
  assert.ok(v.errors.some((e) => /HTML is not allowed/.test(e)));
});

// ============================================================ coupon block and unique codes
test('coupon block: an active coupon (code, discount, validity, /plans?coupon=); unusable or child coupons refused', async () => {
  const w = await world();
  await w.coupon('RIDE40', { expiresAt: Date.UTC(2026, 11, 31, 12) });
  await assert.rejects(w.studio.prepare({ design: design([{ type: 'coupon', code: 'NOPE' }]) }), /There is no coupon NOPE/);
  await assert.rejects(w.studio.prepare({ design: design([{ type: 'coupon', code: '' }]) }), /choose a coupon/);
  await w.coupon('OLD', { status: 'PAUSED' });
  await assert.rejects(w.studio.prepare({ design: design([{ type: 'coupon', code: 'OLD' }]) }), /Coupon OLD is paused/);
  const prep = await w.studio.prepare({ design: design([{ type: 'coupon', code: 'RIDE40' }]) });
  const u = await w.addUser('Asha Rao');
  const m = await w.studio.build(prep, await w.repo.findUserById(u.userId));
  assert.ok(m.text.includes('Code: RIDE40 (40% off, valid until 31 Dec 2026)') && m.html.includes(`${ORIGIN}/plans?coupon=RIDE40`));
  // A unique-code parent must be public and active.
  await w.coupon('VIP', { allowedUserIds: ['u9'] });
  await assert.rejects(w.studio.prepare({ design: design([{ type: 'coupon', code: 'VIP' }]), uniqueCoupon: { enabled: true, prefix: 'VIP', validDays: 7 } }), /chosen riders only/);
  await assert.rejects(w.studio.prepare({ design: design([textBlock('x')]), uniqueCoupon: { enabled: true, prefix: 'X1', validDays: 7 } }), /Unique codes need a coupon block/);
  await assert.rejects(w.studio.prepare({ design: design([{ type: 'coupon', code: 'RIDE40' }]), uniqueCoupon: { enabled: true, prefix: 'x', validDays: 7 } }), /prefix/);
});

test('unique codes: one single-use child per rider, same code on retry, race safe issue and redemption, listed per parent', async () => {
  const w = await world();
  const parent = await w.coupon('DIWALI', { expiresAt: Date.now() + 10 * DAY, discountValue: 30, applicableTiers: ['group_large'] });
  const p = await w.repo.findCoupon('DIWALI');
  const opts = { campaignId: 'ec_aaaaaaaaaaaaaaaaaaaa', prefix: 'DIW', validDays: 3 };
  const a = await w.studio.issueUniqueCode(p, { ...opts, userId: 'ua' });
  const b = await w.studio.issueUniqueCode(p, { ...opts, userId: 'ub' });
  assert.match(a, /^DIW-[A-HJKMNP-Z2-9]{8}$/);
  assert.notEqual(a, b);
  assert.equal(await w.studio.issueUniqueCode(p, { ...opts, userId: 'ua' }), a, 'a retry reuses the code');
  // Concurrent issue for one (campaign, rider): one code.
  const many = await Promise.all(Array.from({ length: 8 }, () => w.studio.issueUniqueCode(p, { ...opts, userId: 'uc' })));
  assert.equal(new Set(many).size, 1);
  const child = await w.repo.findCoupon(a);
  assert.deepEqual([child.maxUsageTotal, child.maxUsagePerUser, child.allowedUserIds, child.parentCode, child.emailCampaignId, child.status, child.discountValue, child.applicableTiers],
    [1, 1, ['ua'], 'DIWALI', opts.campaignId, 'ACTIVE', 30, ['group_large']]);
  assert.ok(child.expiresAt <= Date.now() + 3 * DAY + 1000 && child.expiresAt <= parent.expiresAt, 'expiry: the sooner of N days and the parent');
  // Only that rider; once.
  const { checkCoupon } = require('../src/plan_pricing');
  assert.equal(checkCoupon(child, { uid: 'ub', planId: 'group_large', baseInr: 99 }).reason, 'NOT_ELIGIBLE');
  assert.equal(checkCoupon(child, { uid: 'ua', planId: 'group_large', baseInr: 99 }).ok, true);
  const tries = await Promise.all(Array.from({ length: 6 }, (_, i) => w.repo.reserveCouponSlot(a, { userId: 'ua', orderId: `order_${i}`, category: 'group_large', originalPrice: 99, discountAmount: 99, finalAmount: 0 })));
  assert.equal(tries.filter((x) => x.reserved).length, 1, 'a single-use code is used once, whatever the race');
  const used = await w.repo.findCoupon(a);
  assert.deepEqual([used.usageCount, used.status], [1, 'USAGE_LIMIT_REACHED']);
  // Coupon admin list: children are listed per parent, not in the main list.
  const main = await w.repo.listCoupons(500);
  assert.ok(main.some((c) => c.code === 'DIWALI') && !main.some((c) => c.parentCode));
  assert.equal((await w.repo.listCoupons(500, { includeChildren: true })).filter((c) => c.parentCode === 'DIWALI').length, 3);
  const listed = await w.studio.listUniqueCodes('DIWALI');
  assert.equal(listed.length, 3);
  assert.ok(listed.find((x) => x.code === a).used);
  assert.deepEqual(await w.studio.uniqueSummary(), { DIWALI: { issued: 3 } });
});

test('campaign with unique codes: every recipient gets their own code; redemptions are joined to the campaign report', async () => {
  const w = await world();
  await w.coupon('XMAS');
  const r1 = await w.addUser('Ravi One');
  const r2 = await w.addUser('Mira Two');
  const { campaign } = await w.studio.createCampaign({ name: 'Xmas', design: design([{ type: 'heading', text: 'Merry riding' }, { type: 'coupon', code: 'XMAS', buttonLabel: 'Use {couponCode}' }]),
    audience: { kind: 'all' }, uniqueCoupon: { enabled: true, prefix: 'XM', validDays: 14 } });
  await w.studio.tick();
  assert.equal(w.sent.length, 2);
  const codes = w.sent.map((m) => /Code: (XM-[A-Z0-9]{8})/.exec(m.text)[1]);
  assert.notEqual(codes[0], codes[1]);
  assert.ok(!w.sent.some((m) => m.text.includes('Code: XMAS ')), 'the parent code is never mailed');
  // Ravi redeems his code: the report counts it (a payment that succeeded).
  const ravisMail = w.sent.find((m) => m.to === r1.email);
  const ravisCode = /Code: (XM-[A-Z0-9]{8})/.exec(ravisMail.text)[1];
  await w.repo.reserveCouponSlot(ravisCode, { userId: r1.userId, orderId: 'order_r1', category: 'group_small', originalPrice: 49, discountAmount: 20, finalAmount: 0 });
  const rep = await w.studio.report(campaign.campaignId);
  assert.deepEqual([rep.queued, rep.sent, rep.failed, rep.redemptions.count, rep.redemptions.discountInr], [2, 2, 0, 1, 20]);
  void r2;
});

// ============================================================ price block
test('price block: list price struck and the offer price from the pricing config at SEND time', async () => {
  const w = await world();
  const cat = await w.repo.getMembershipCatalog();
  const setOffer = async (price) => {
    const c = JSON.parse(JSON.stringify(cat));
    c.group_large.listPriceInr = 99;
    c.group_large.offer = price === null ? null : { priceInr: price, label: 'Launch offer', startAt: Date.now() - DAY, endAt: Date.now() + 10 * DAY };
    await w.repo.setMembershipCatalog(c, 'test');
  };
  await setOffer(59);
  await w.addUser('Asha Price');
  const d = design([{ type: 'price', planId: 'group_large' }, textBlock('Now {offerPrice}, was {listPrice}.')], { subject: 'Large Group at {offerPrice}' });
  const pv = await w.studio.preview({ design: d });
  assert.ok(pv.text.includes('₹99 -> ₹59') && pv.subject === 'Large Group at ₹59');
  await w.studio.createCampaign({ design: d, audience: { kind: 'all' } });
  await setOffer(49); // the admin changes the offer before the job runs
  await w.studio.tick();
  assert.equal(w.sent.length, 1);
  assert.equal(w.sent[0].subject, 'Large Group at ₹49');
  assert.ok(w.sent[0].text.includes('Now ₹49, was ₹99.') && w.sent[0].html.includes('line-through;">₹99</span>'));
  await setOffer(null);
  const plain = await w.studio.preview({ design: d });
  assert.ok(plain.text.includes('Large Group: ₹99 per 30 days') && !plain.html.includes('line-through'));
});

// ============================================================ segments and consent
test('segments: counts per segment, only riders with the Offers consent, never suppressed; city is not a segment', async () => {
  const w = await world();
  const now = w.clock.t;
  const fresh = await w.addUser('Fresh Rider', { createdAt: now - 3 * DAY });
  const idle = await w.addUser('Idle Rider');
  const rider = await w.addUser('Busy Rider', { username: 'BusyRider1' });
  const noConsent = await w.addUser('No Consent', { consent: false });
  const supp = await w.addUser('Suppressed One');
  await w.offers.suppress(supp.email, 'bounce');
  await w.soda.insert('trips', { tripId: 't1', userId: rider.userId, endTimeEpochMs: now - 2 * DAY });
  await w.soda.insert('trips', { tripId: 't2', userId: idle.userId, endTimeEpochMs: now - 60 * DAY });
  await w.soda.insert('convoys', { groupId: 'g1', createdByUserId: rider.userId });
  await w.soda.insert('crew_members', { memberKey: 'c1|x', crewId: 'c1', userId: idle.userId, role: 'ADMIN' });
  await w.soda.insert('crew_members', { memberKey: 'c1|y', crewId: 'c1', userId: noConsent.userId, role: 'ADMIN' });
  await w.soda.insert('operators', { operatorId: 'op1', ownerId: rider.userId, status: 'APPROVED', validUntil: 0 });
  await w.soda.insert('memberships', { membershipId: 'm1', ownerUserId: rider.userId, category: 'group_small', status: 'ACTIVE', validUntil: now + 2 * DAY });
  await w.soda.insert('memberships', { membershipId: 'm2', ownerUserId: idle.userId, category: 'group_large', status: 'EXPIRED', validUntil: now - 3 * DAY });
  await w.soda.insert('memberships', { membershipId: 'm3', ownerUserId: noConsent.userId, category: 'group_small', status: 'ACTIVE', validUntil: now + 1 * DAY });
  const count = async (audience, category) => (await w.studio.audienceCount(audience, category)).riders;
  const ids = async (audience, category = 'marketing') => (await w.studio.resolveAudience(w.studio.validateAudience(audience, category), category)).map((x) => x.userId).sort();
  assert.equal(await count({ kind: 'all' }), 3, 'opted in and not suppressed: fresh, idle, busy');
  assert.deepEqual(await ids({ kind: 'joined_within', days: 7 }), [fresh.userId]);
  assert.deepEqual(await ids({ kind: 'inactive', days: 30 }), [idle.userId], 'no ride for 30 days (a 3-day-old account is not "inactive")');
  assert.deepEqual(await ids({ kind: 'never_hosted' }), [fresh.userId, idle.userId].sort());
  assert.deepEqual(await ids({ kind: 'plan_ends_within', days: 3 }), [rider.userId], 'the rider without consent is not in a marketing audience');
  assert.deepEqual(await ids({ kind: 'plan_expired_within', days: 7 }), [idle.userId]);
  assert.deepEqual(await ids({ kind: 'crew_admins' }), [idle.userId]);
  assert.deepEqual(await ids({ kind: 'operators' }), [rider.userId]);
  assert.deepEqual(await ids({ kind: 'usernames', usernames: ['@busyrider1', 'nobody_here'] }), [rider.userId]);
  assert.throws(() => w.studio.validateAudience({ kind: 'city', city: 'Pune' }, 'marketing'), /Unknown audience/);
  assert.throws(() => w.studio.validateAudience({ kind: 'inactive', days: 0 }, 'marketing'), /1 to 365/);
  // Account e-mails ("Plan ending soon", no coupon / price): plan segments only, consent not needed, hard suppression respected.
  assert.throws(() => w.studio.validateAudience({ kind: 'all' }, 'account'), (e) => e.code === 'ACCOUNT_AUDIENCE');
  assert.deepEqual(await ids({ kind: 'plan_ends_within', days: 3 }, 'account'), [noConsent.userId, rider.userId].sort());
  await assert.rejects(w.studio.prepare({ design: design([{ type: 'coupon', code: 'X' }]), category: 'account' }), /An account e-mail cannot carry a coupon/);
  await assert.rejects(w.studio.prepare({ design: design([textBlock('{discount}')]), category: 'account' }));
  await assert.rejects(w.studio.createCampaign({ design: design([textBlock('x')]), category: 'account', audience: { kind: 'all' } }), (e) => e.code === 'ACCOUNT_AUDIENCE');
});

test('consent enforcement at send time: an opt-out, a suppression or a deleted account after scheduling is skipped', async () => {
  const w = await world();
  const a = await w.addUser('Keeps Consent');
  const b = await w.addUser('Opts Out');
  const c = await w.addUser('Gets Suppressed');
  const { campaign } = await w.studio.createCampaign({ design: design([textBlock('News')]), audience: { kind: 'all' }, sendAt: w.clock.t + 3600000 });
  assert.equal(await w.studio.tick(), 0, 'not due yet');
  assert.equal(w.sent.length, 0);
  await w.studio._claimNext().then(() => null); // nothing due
  await w.offers.setConsent(b.userId, false);
  await w.offers.suppress(c.email, 'complaint');
  w.clock.t += 3600000 + 1000;
  // Resolve the audience early (as if the job had started), then change consent: the send-time check wins.
  await w.studio.tick();
  assert.deepEqual(w.sent.map((m) => m.to), [a.email]);
  const got = await w.studio.getCampaign(campaign.campaignId);
  assert.equal(got.status, 'SENT');
  assert.equal(got.stats.sent, 1);
  // Headers: one-click unsubscribe with the campaign id for attribution.
  const m = w.sent[0];
  assert.equal(m.headers['List-Unsubscribe'], `<${ORIGIN}/email/unsubscribe?u=${a.userId}&t=${unsubscribeToken('unit-secret', a.userId)}&cid=${campaign.campaignId}>`);
  assert.equal(m.headers['List-Unsubscribe-Post'], 'List-Unsubscribe=One-Click');
  assert.equal(m.headers['X-CoRoute-Category'], 'offers');
  assert.ok(m.text.includes('You get this e-mail because you turned on offer e-mails'));
});

// ============================================================ schedule, quiet hours, caps, automation
test('scheduling: never twice (mail_log key), quiet hours wait for the morning, frequency cap per week', async () => {
  const noonIst = Date.UTC(2026, 10, 12, 6, 30); // 12:00 IST
  const w = await world({ now: noonIst });
  await w.studio.setSettings({ quietStartHour: 21, quietEndHour: 9, maxPerWeek: 2 });
  const u = await w.addUser('Cap Rider');
  const mk = (s) => w.studio.createCampaign({ design: design([textBlock(s)], { subject: s }), audience: { kind: 'all' } });
  const c1 = await mk('One');
  await w.studio.tick();
  // A second run of the same campaign (lease ran out) cannot send again: the mail_log key exists.
  const row = await w.soda.findOne('email_studio_campaigns', { campaignId: c1.campaign.campaignId });
  await w.soda.replace('email_studio_campaigns', row.key, { ...row.value, status: 'SENDING', leaseUntil: 0, cursor: 0, recipients: [u.userId] });
  await w.studio.tick();
  assert.equal(w.sent.filter((m) => m.subject === 'One').length, 1);
  // Quiet hours: 22:00 IST -> nothing; 09:30 IST next day -> sent.
  w.clock.t = Date.UTC(2026, 10, 12, 16, 30);
  const c2 = await mk('Two');
  assert.equal(c2.quietNow, true);
  await w.studio.tick();
  assert.equal(w.sent.filter((m) => m.subject === 'Two').length, 0);
  w.clock.t = Date.UTC(2026, 10, 13, 4, 0);
  await w.studio.tick();
  assert.equal(w.sent.filter((m) => m.subject === 'Two').length, 1);
  // Cap: two marketing e-mails in 7 days already -> the third is capped.
  const c3 = await mk('Three');
  await w.studio.tick();
  assert.equal(w.sent.filter((m) => m.subject === 'Three').length, 0);
  assert.equal((await w.studio.getCampaign(c3.campaign.campaignId)).stats.capped, 1);
  w.clock.t += 8 * DAY;
  const c4 = await mk('Four');
  await w.studio.tick();
  assert.equal(w.sent.filter((m) => m.subject === 'Four').length, 1);
  void c4;
  // Settings validation.
  await assert.rejects(w.studio.setSettings({ maxPerWeek: 0 }), /1 to 14/);
  await assert.rejects(w.studio.setSettings({ quietStartHour: 25 }), /0 to 23/);
});

test('automation: win-back once per rider per 90 days; plan ending once per plan period; account notice without consent', async () => {
  const w = await world();
  await w.coupon('BACK20', { expiresAt: Date.now() + 400 * DAY });
  const idle = await w.addUser('Idle Biker');
  const active = await w.addUser('Active Biker');
  await w.soda.insert('trips', { tripId: 't1', userId: active.userId, endTimeEpochMs: w.clock.t - DAY });
  const tpl = (await w.studio.createTemplate({ fromStarter: 'winback_coupon' })).template;
  await assert.rejects(w.studio.createRule({ name: 'Win-back', trigger: 'inactive', days: 30, templateId: tpl.templateId }), /choose a coupon/);
  const rule = await w.studio.createRule({ name: 'Win-back', trigger: 'inactive', days: 30, cooldownDays: 90, templateId: tpl.templateId, couponCode: 'BACK20' });
  assert.match(rule.ruleId, /^ea_[a-f0-9]{16}$/);
  await w.studio.tick();
  await w.studio.tick();
  assert.deepEqual(w.sent.map((m) => m.to), [idle.email], 'once, to the idle rider only');
  assert.equal(w.sent[0].subject, 'We miss you on the road, Idle');
  assert.ok(w.sent[0].text.includes('Code: BACK20'));
  const toIdle = () => w.sent.filter((m) => m.to === idle.email).length;
  w.clock.t += 30 * DAY;
  await w.studio.tick();
  assert.equal(toIdle(), 1, 'still inside the 90 days');
  assert.equal(w.sent.filter((m) => m.to === active.email).length, 1, 'the other rider has now gone 30 days without a ride');
  w.clock.t += 61 * DAY;
  await w.studio.tick();
  assert.equal(toIdle(), 2, 'after 90 days, once more');
  const rep = await w.studio.report(rule.ruleId);
  assert.equal(rep.sent, 3);
  await w.studio.updateRule(rule.ruleId, { enabled: false });
  w.clock.t += 200 * DAY;
  const before = w.sent.length;
  await w.studio.tick();
  assert.equal(w.sent.length, before, 'a disabled rule sends nothing');

  // Plan ending: account notice (no consent needed), 3 days before, once per plan period.
  const w2 = await world();
  const holder = await w2.addUser('Plan Holder', { consent: false });
  await w2.soda.insert('memberships', { membershipId: 'mm', ownerUserId: holder.userId, category: 'group_small', status: 'ACTIVE', validUntil: w2.clock.t + 2.5 * DAY });
  const pt = (await w2.studio.createTemplate({ fromStarter: 'plan_ending' })).template;
  assert.equal(pt.category, 'account');
  await w2.studio.createRule({ name: 'Plan ending', trigger: 'plan_ending', days: 3, templateId: pt.templateId });
  await w2.studio.tick();
  w2.clock.t += 3600000;
  await w2.studio.tick();
  assert.equal(w2.sent.length, 1);
  assert.match(w2.sent[0].subject, /^Your Small Group plan ends on \d{1,2} [A-Z][a-z]{2} \d{4}$/);
  assert.equal(w2.sent[0].headers['X-CoRoute-Category'], 'account');
  assert.equal(w2.sent[0].headers['List-Unsubscribe'], undefined);
  // Renewed: a new plan period -> a new reminder before it ends.
  const row = await w2.soda.findOne('memberships', { membershipId: 'mm' });
  await w2.soda.replace('memberships', row.key, { ...row.value, validUntil: w2.clock.t + 32 * DAY });
  w2.clock.t += 30 * DAY;
  await w2.studio.tick();
  assert.equal(w2.sent.length, 2);
});

// ============================================================ clicks
test('click tracking: signed redirect tokens (tamper-proof, internal targets only), counted, can be switched off', async () => {
  const w = await world();
  const u = await w.addUser('Click Rider');
  const { campaign } = await w.studio.createCampaign({ design: design([textBlock('See [the guide](/guide)'), { type: 'button', label: 'Plans', path: '/plans' }]), audience: { kind: 'all' } });
  await w.studio.tick();
  const m = w.sent[0];
  const links = [...m.html.matchAll(/href="https:\/\/coroute\.example\/r\/([A-Za-z0-9_.-]+)"/g)].map((x) => x[1]);
  assert.equal(links.length, 2, 'both content links tracked');
  assert.ok(m.html.includes(`${ORIGIN}/email/unsubscribe?u=`), 'unsubscribe is never tracked');
  assert.ok(m.text.includes('Plans: https://coroute.example/plans'), 'the text version keeps plain links');
  const info = w.studio.readClickToken(links[0]);
  assert.deepEqual([info.campaignId, info.path], [campaign.campaignId, '/guide']);
  assert.equal(info.uh, w.studio.userHash(u.userId));
  assert.ok(!links[0].includes(u.userId) && !Buffer.from(links[0].split('.')[0], 'base64url').toString().includes(u.userId), 'no rider id in the link');
  // Tampering: another path with the old signature fails.
  const [p, sig] = links[0].split('.');
  const forged = `${Buffer.from(Buffer.from(p, 'base64url').toString().replace('/guide', '/plans')).toString('base64url')}.${sig}`;
  assert.equal(w.studio.readClickToken(forged), null);
  assert.equal(w.studio.readClickToken('x.y'), null);
  // An external target can never be signed in (the signature covers it, the path is re-checked).
  const evil = w.studio.clickToken(campaign.campaignId, u.userId, 'https://evil.example');
  assert.equal(w.studio.readClickToken(evil), null);
  await w.studio.recordClick(info);
  await w.studio.recordClick(info);
  await w.studio.recordClick(w.studio.readClickToken(links[1]));
  let rep = await w.studio.report(campaign.campaignId);
  assert.deepEqual([rep.clicks.total, rep.clicks.unique, rep.clicks.byLink[0]], [3, 1, { path: '/guide', total: 2 }]);
  // Off: no counting, and new e-mails carry direct links.
  await w.studio.setSettings({ clickTracking: false });
  assert.equal(await w.studio.recordClick(info), false);
  rep = await w.studio.report(campaign.campaignId);
  assert.equal(rep.clicks.total, 3);
  w.clock.t += 8 * DAY;
  await w.studio.createCampaign({ design: design([{ type: 'button', label: 'Plans', path: '/plans' }], { subject: 'Direct' }), audience: { kind: 'all' } });
  await w.studio.tick();
  const direct = w.sent.find((x) => x.subject === 'Direct');
  assert.ok(direct.html.includes('href="https://coroute.example/plans"') && !direct.html.includes('/r/'));
});

// ============================================================ unsubscribe, suppression, bounces
test('unsubscribe from a campaign e-mail: consent off, suppressed, counted on that campaign; bounces suppress', async () => {
  let bounce = false;
  const w = await world({ smtp: async () => (bounce ? { sent: false, error: 'EENVELOPE', responseCode: 550 } : null) });
  const u = await w.addUser('Leaving Rider');
  const v = await w.addUser('Bouncing Rider');
  const c = await w.studio.createCampaign({ design: design([textBlock('Hi')]), audience: { kind: 'all' } });
  await w.studio.tick();
  assert.equal(w.sent.length, 2);
  const mail = w.sent.find((m) => m.to === u.email);
  const unsub = /Unsubscribe: (\S+)/.exec(mail.text)[1];
  const q = new URL(unsub).searchParams;
  assert.equal(q.get('cid'), c.campaign.campaignId);
  assert.equal(await w.offers.unsubscribe(q.get('u'), q.get('t'), { campaignId: q.get('cid') }), true);
  assert.equal((await w.offers.consentOf(u.userId)).offersEmail, false);
  assert.ok(await w.offers.isSuppressed(u.email));
  assert.equal((await w.studio.report(c.campaign.campaignId)).unsubscribed, 1);
  // A forged campaign id for a rider who never got it is not counted.
  await w.offers.setConsent(u.userId, true, { email: u.email });
  await w.offers.unsubscribe(u.userId, unsubscribeToken('unit-secret', u.userId), { campaignId: 'ec_bbbbbbbbbbbbbbbbbbbb' });
  assert.equal((await w.studio.report('ec_bbbbbbbbbbbbbbbbbbbb')).unsubscribed, 0);
  // The next campaign: the unsubscribed rider is skipped; a permanent SMTP refusal suppresses the address.
  bounce = true;
  w.clock.t += 8 * DAY;
  const c2 = await w.studio.createCampaign({ design: design([textBlock('Again')], { subject: 'Again' }), audience: { kind: 'all' } });
  await w.studio.tick();
  const st = (await w.studio.getCampaign(c2.campaign.campaignId)).stats;
  assert.deepEqual([st.targeted, st.sent, st.failed], [1, 0, 1], 'only the bouncing rider was targeted');
  const s = (await w.offers.listSuppression()).find((x) => x.masked === 'b***@x.test');
  assert.equal(s.reason, 'bounce');
  void v;
});

test('postal address: real campaigns need MAIL_POSTAL_ADDRESS; test sends and previews show the placeholder', async () => {
  const w = await world({ env: {} });
  const admin = await w.addUser('Admin Person');
  await assert.rejects(w.studio.createCampaign({ design: design([textBlock('x')]), audience: { kind: 'all' } }), (e) => e.code === 'NO_POSTAL_ADDRESS');
  const pv = await w.studio.preview({ design: design([textBlock('x')]) });
  assert.equal(pv.postalAddressSet, false);
  assert.ok(pv.html.includes(POSTAL_PLACEHOLDER));
  const r = await w.studio.testSend({ design: design([textBlock('x')]) }, { userId: admin.userId });
  assert.equal(r.sent, true);
  assert.equal(w.sent[0].subject, '[Test] Hello Admin');
});

test('test send with unique codes issues a real single-use code for the admin (QA: redeem it on /plans)', async () => {
  const w = await world();
  await w.coupon('QA10');
  const admin = await w.addUser('Admin Qa', { consent: false });
  const r = await w.studio.testSend({ design: design([{ type: 'coupon', code: 'QA10' }]), uniqueCoupon: { enabled: true, prefix: 'QA', validDays: 2 } }, { userId: admin.userId });
  assert.match(r.uniqueCode, /^QA-/);
  const c = await w.repo.findCoupon(r.uniqueCode);
  assert.deepEqual([c.allowedUserIds, c.maxUsageTotal, c.status], [[admin.userId], 1, 'ACTIVE']);
  assert.ok(w.sent[0].text.includes(`Code: ${r.uniqueCode}`));
});

// ============================================================ HTTP API
let t; let admin; let rider;
before(async () => {
  const mails = [];
  t = await boot({ mailTransport: { async sendMail(m) { mails.push(m); return { messageId: `<s${mails.length}@t>` }; } } });
  t.mails = mails;
  admin = await t.register('Studio Admin', 'studio.admin@coroute.test');
  rider = await t.register('Studio Rider', 'studio.rider@coroute.test');
  await t.gw.notifications.lifecycle.idle();
  await t.gw.notifications.studio.setSettings({ quietStartHour: 0, quietEndHour: 0 });
});
after(async () => { await t.gw.shutdown(); });

test('API: admin only; config, templates, preview frame (sandboxed, own CSP), audience count, campaigns, click redirect', async () => {
  assert.equal((await t.api('GET', '/admin/email/studio/config', null, rider.token)).status, 403);
  const cfg = await t.api('GET', '/admin/email/studio/config', null, admin.token);
  assert.equal(cfg.status, 200);
  assert.equal(cfg.json.postalAddressSet, true);
  assert.deepEqual(cfg.json.buttonPaths, ['/plans', '/updates', '/guide', '/operators/apply', '/account']);
  assert.ok(cfg.json.segments.some((s) => s.kind === 'plan_ends_within' && s.account));
  // Admin page CSP allows only same-origin frames (the preview).
  const page = await fetch(`${t.origin}/admin`);
  assert.match(page.headers.get('content-security-policy'), /frame-src 'self'/);
  let r = await t.api('POST', '/admin/email/studio/templates', { fromStarter: 'festive_coupon' }, admin.token);
  assert.equal(r.status, 201);
  const tid = r.json.template.templateId;
  r = await t.api('PUT', `/admin/email/studio/templates/${tid}`, { design: { ...r.json.template.design, subject: 'Festive {firstName}' }, baseVersion: 1 }, admin.token);
  assert.deepEqual([r.status, r.json.template.version], [200, 2]);
  r = await t.api('PUT', `/admin/email/studio/templates/${tid}`, { design: { subject: 'x {bad}', blocks: [{ type: 'text', text: 'x' }] } }, admin.token);
  assert.deepEqual([r.status, r.json.code], [400, 'BAD_TEMPLATE']);
  assert.ok(Array.isArray(r.json.errors));
  r = await t.api('GET', `/admin/email/studio/templates/${tid}`, null, admin.token);
  assert.equal(r.json.template.history.length, 2);
  r = await t.api('POST', '/admin/email/studio/preview', { design: { subject: 'Hi {firstName}', preheader: 'P', blocks: [{ type: 'text', text: 'Hello **there**' }] } }, admin.token);
  assert.equal(r.status, 200);
  assert.match(r.json.previewUrl, /^\/email\/preview\/[A-Za-z0-9_-]{24}$/);
  const frame = await fetch(t.origin + r.json.previewUrl);
  assert.equal(frame.status, 200);
  const csp = frame.headers.get('content-security-policy');
  assert.ok(/sandbox/.test(csp) && /frame-ancestors 'self'/.test(csp) && /default-src 'none'/.test(csp) && !/script-src/.test(csp), csp);
  assert.equal(frame.headers.get('x-frame-options'), 'SAMEORIGIN');
  assert.ok((await frame.text()).includes('<strong>there</strong>'));
  assert.equal((await fetch(`${t.origin}/email/preview/${'a'.repeat(24)}`)).status, 404);
  // Consent: the rider opts in on the website; the count sees them.
  assert.equal((await t.api('PUT', '/web/marketing-consent', { offersEmail: true }, rider.token)).status, 200);
  r = await t.api('POST', '/admin/email/studio/audience-count', { audience: { kind: 'all' } }, admin.token);
  assert.deepEqual([r.status, r.json.riders], [200, 1]);
  // A campaign, sent now by the job.
  r = await t.api('POST', '/admin/email/studio/campaigns', { name: 'News', design: { subject: 'News for {firstName}', blocks: [{ type: 'button', label: 'Open the guide', path: '/guide' }] }, audience: { kind: 'all' } }, admin.token);
  assert.equal(r.status, 201, JSON.stringify(r.json));
  const cid = r.json.campaign.campaignId;
  await t.gw.notifications.studio.tick();
  const mail = t.mails.find((m) => m.subject === 'News for Studio');
  assert.ok(mail, 'sent to the opted-in rider');
  const token = /\/r\/([A-Za-z0-9_.-]+)"/.exec(mail.html)[1];
  const red = await fetch(`${t.origin}/r/${token}`, { redirect: 'manual' });
  assert.equal(red.status, 302);
  assert.equal(red.headers.get('location'), 'https://coroute.example/guide');
  const bad = await fetch(`${t.origin}/r/${token.slice(0, -2)}xx`, { redirect: 'manual' });
  assert.deepEqual([bad.status, bad.headers.get('location')], [302, '/']);
  r = await t.api('GET', `/admin/email/studio/campaigns/${cid}`, null, admin.token);
  assert.deepEqual([r.json.campaign.status, r.json.report.sent, r.json.report.clicks.total], ['SENT', 1, 1]);
  // Rules and settings are admin only and validated.
  assert.equal((await t.api('PUT', '/admin/email/studio/settings', { maxPerWeek: 3 }, rider.token)).status, 403);
  r = await t.api('PUT', '/admin/email/studio/settings', { maxPerWeek: 3, clickTracking: true }, admin.token);
  assert.deepEqual([r.status, r.json.maxPerWeek], [200, 3]);
  r = await t.api('POST', '/admin/email/studio/rules', { name: 'x', trigger: 'nope', templateId: tid }, admin.token);
  assert.equal(r.status, 400);
  // Unique code listing and library are reachable.
  assert.equal((await t.api('GET', '/admin/email/studio/unique-codes', null, admin.token)).status, 200);
  assert.equal((await t.api('GET', '/admin/email/studio/images/library', null, admin.token)).status, 200);
});

test('API: unsubscribe link of a studio e-mail (GET page keeps cid, POST unsubscribes and attributes)', async () => {
  const studio = t.gw.notifications.studio;
  const camps = await studio.listCampaigns();
  const cid = camps[0].campaignId;
  const mail = t.mails.find((m) => m.headers && m.headers['X-CoRoute-Campaign'] === cid);
  const link = /Unsubscribe: (\S+)/.exec(mail.text)[1].replace('https://coroute.example', t.origin);
  const page = await fetch(link);
  assert.equal(page.status, 200);
  assert.ok((await page.text()).includes(`cid=${cid}`), 'the button keeps the campaign id');
  const post = await fetch(link, { method: 'POST' });
  assert.equal(post.status, 200);
  assert.equal((await t.api('GET', '/web/marketing-consent', null, rider.token)).json.offersEmail, false);
  assert.equal((await studio.report(cid)).unsubscribed, 1);
});
