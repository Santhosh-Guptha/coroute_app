'use strict';
/**
 * 3.57 round 3 web admin Riders (src/admin_riders.js, docs/features_355/web_riders_admin.md): list / search / filters
 * (admin only, no phone or medical data), the rider page (emergency contact as present only), assign a plan through
 * the existing admin grant with one "Plan assigned" e-mail, a personal single-use coupon bound to the rider and
 * redeemable only by them, the consent rule for the coupon e-mail (Offers consent, or a noted service message), a
 * 1:1 e-mail (transactional vs marketing, suppression, idempotent), audit entries, the wizard's system templates,
 * the global search, account notices to named riders, and GET /api/me/coupons. SMTP is a fake transport.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'riders.admin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
process.env.PAYMENTS_ENABLED = 'true';
process.env.MAIL_POSTAL_ADDRESS = 'CoRoute, 12 MG Road, Bengaluru 560001, India';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { validateDesign } = require('../src/email_marketing');
const { toStudio } = require('../src/admin_riders');

const DAY = 86400000;
const mails = [];
const mailTransport = { async sendMail(m) { mails.push(m); return { messageId: `<r${mails.length}@test>` }; } };
const direct = (to) => mails.filter((m) => m.headers && m.headers['X-CoRoute-Mail'] === 'direct' && (!to || m.to === to));

let t; let admin; let asha; let ravi; let noContact;
before(async () => {
  t = await boot({ mailTransport });
  admin = await t.register('Riders Admin', 'riders.admin@coroute.test');
  asha = await t.register('Asha Rao', 'asha.rao@coroute.test');
  ravi = await t.register('Ravi Kumar', 'ravi.kumar@coroute.test');
  noContact = await t.register('Neha Shah', 'neha.shah@coroute.test');
  // Medical data and a second rider without an emergency contact.
  await t.api('PATCH', '/me', { bloodGroup: 'O+', allergies: 'Penicillin', medicalNotes: 'Asthma inhaler in the left pocket' }, asha.token);
  const n = await t.gw.repo.findUserById(noContact.user.userId);
  await t.gw.repo.updateUser(n.key, { emergencyContact: '', emergencyContactName: '' });
  await t.gw.repo.saveCoupon({ code: 'PARENT40', name: 'Parent 40', discountType: 'percentage', discountValue: 40, validFrom: Date.now() - DAY, expiresAt: Date.now() + 60 * DAY, status: 'ACTIVE', maxUsageTotal: 1000 });
  await t.gw.notifications.studio.setSettings({ quietStartHour: 0, quietEndHour: 0 });
});
after(async () => { await t.gw.shutdown(); });

const me = async (tok) => (await t.api('GET', '/me', null, tok)).json;
const rid = () => `req${Math.random().toString(36).slice(2, 12)}`;

test('authorisation: every riders / search / wizard API refuses a rider (403) and no token (401); /me/coupons needs a session', async () => {
  const id = asha.user.userId;
  const calls = [['GET', '/admin/riders'], ['GET', `/admin/riders/${id}`], ['POST', `/admin/riders/${id}/assign-plan`], ['POST', `/admin/riders/${id}/coupon`],
    ['POST', `/admin/riders/${id}/email`], ['POST', `/admin/riders/${id}/preview`], ['POST', `/admin/riders/${id}/email/check`], ['GET', '/admin/search?q=asha'], ['GET', '/admin/email-wizard/templates']];
  for (const [m, p] of calls) {
    assert.equal((await t.api(m, p, m === 'GET' ? undefined : {}, ravi.token)).status, 403, `${m} ${p} rider`);
    assert.equal((await t.api(m, p, m === 'GET' ? undefined : {})).status, 401, `${m} ${p} anonymous`);
  }
  assert.equal((await t.api('GET', '/me/coupons')).status, 401);
});

test('list: search by username / name / e-mail, filters, sort, pages; no phone, no medical data, no emergency number', async () => {
  const a = await me(asha.token);
  assert.ok(a.username, 'usernames are backfilled at sign-up');
  const list = await t.api('GET', '/admin/riders?limit=50', null, admin.token);
  assert.equal(list.status, 200);
  assert.match(list.headers.get('cache-control'), /no-store/);
  assert.equal(list.json.excludesStaff, true);
  assert.ok(!list.json.riders.some((x) => x.userId === admin.user.userId), 'staff left out by default');
  const row = list.json.riders.find((x) => x.userId === asha.user.userId);
  assert.ok(row);
  for (const k of ['username', 'name', 'email', 'plan', 'planValidUntil', 'rides', 'lastSeenAt', 'createdAt', 'avatarUrl', 'hasEmergencyContact']) assert.ok(k in row, k);
  const text = JSON.stringify(list.json);
  assert.doesNotMatch(text, /Penicillin|Asthma|"O\+"|\+919000000001|"phone"|bloodGroup|emergencyContactName/);
  const q = async (s) => (await t.api('GET', `/admin/riders?${s}`, null, admin.token)).json.riders.map((x) => x.userId);
  assert.deepEqual(await q(`q=${encodeURIComponent('@' + a.username)}`), [asha.user.userId]);
  assert.deepEqual(await q('q=ravi%20kumar'), [ravi.user.userId]);
  assert.deepEqual(await q('q=neha.shah%40coroute'), [noContact.user.userId]);
  assert.deepEqual(await q('emergency=no'), [noContact.user.userId]);
  assert.ok((await q('emergency=yes')).includes(asha.user.userId));
  assert.deepEqual(await q('plan=group_large'), []);
  assert.deepEqual(await q('lastRide=7d'), [], 'nobody rode');
  assert.equal((await q('lastRide=never')).length, 3);
  assert.equal((await q('staff=all&limit=100')).length, 4);
  assert.deepEqual(await q(`joinedFrom=${new Date(Date.now() + 2 * DAY).toISOString().slice(0, 10)}`), []);
  const paged = (await t.api('GET', '/admin/riders?limit=2&page=2&sort=name', null, admin.token)).json;
  assert.equal(paged.riders.length, 1);
  assert.deepEqual([paged.page, paged.pages, paged.total], [2, 2, 3]);
});

test('rider page: profile, plan, e-mail preferences; the emergency contact only as present; nothing medical', async () => {
  const r = await t.api('GET', `/admin/riders/${asha.user.userId}`, null, admin.token);
  assert.equal(r.status, 200);
  const j = r.json;
  assert.equal(j.rider.name, 'Asha Rao');
  assert.equal(j.rider.hasEmergencyContact, true);
  assert.equal(j.plan.tier, 'community');
  assert.equal(j.emails.offersConsent, false);
  assert.equal(j.emails.suppressed, null);
  assert.deepEqual(j.coupons.assigned, []);
  assert.doesNotMatch(JSON.stringify(j), /Penicillin|Asthma|"O\+"|\+919000000001|bloodGroup|allergies|medicalNotes|emergencyContactName|"phone"/);
  assert.equal((await t.api('GET', '/admin/riders/usr_nobody_here', null, admin.token)).status, 404);
  assert.equal((await t.api('GET', '/admin/riders/..%2F..', null, admin.token)).status, 404);
});

test('assign plan: the existing admin grant (₹0 ADMIN order + membership), effective now, one "Plan assigned" e-mail, audited', async () => {
  const id = asha.user.userId;
  const bad = await t.api('POST', `/admin/riders/${id}/assign-plan`, { plan: 'group_small', days: 30 }, admin.token);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.code, 'REASON_REQUIRED');
  assert.equal((await t.api('POST', `/admin/riders/${id}/assign-plan`, { plan: 'gold', days: 30, reason: 'x y z' }, admin.token)).json.code, 'BAD_PLAN');
  assert.equal((await t.api('POST', `/admin/riders/${id}/assign-plan`, { plan: 'group_small', until: '2001-01-01', reason: 'beta' }, admin.token)).json.code, 'BAD_DAYS');

  // Preview first (what the rider will get), then assign.
  const pv = await t.api('POST', `/admin/riders/${id}/preview`, { system: 'plan_assigned', planName: 'Small Group', planEndsOn: Date.now() + 30 * DAY }, admin.token);
  assert.equal(pv.status, 200, JSON.stringify(pv.json));
  assert.equal(pv.json.category, 'account');
  assert.equal(pv.json.check.classification, 'transactional');
  assert.match(pv.json.subject, /Small Group/);
  assert.match(pv.json.previewUrl, /^\/email\/preview\/[A-Za-z0-9_-]{24}$/);

  const before = direct().length;
  const r = await t.api('POST', `/admin/riders/${id}/assign-plan`, { plan: 'group_small', days: 30, reason: 'Beta tester thank-you', sendEmail: true }, admin.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.plan.tier, 'group_small');
  assert.match(r.json.orderId, /^admin_/);
  assert.equal(r.json.email.sent, true);
  assert.equal(r.json.email.classification, 'transactional');
  // The rider's own plan endpoint shows it at once (the app reads the same).
  const my = await t.api('GET', '/membership/my', null, asha.token);
  assert.equal(my.json.plan.category, 'group_small');
  const sent = direct('asha.rao@coroute.test');
  assert.equal(sent.length - before >= 1, true);
  assert.equal(direct().length - before, 1, 'exactly one e-mail');
  const m = sent[sent.length - 1];
  assert.match(m.subject, /Small Group plan is active/);
  assert.match(m.html, /\/account/);
  assert.ok(!m.headers['List-Unsubscribe'], 'an account e-mail has no offers unsubscribe header');
  assert.match(m.text, /changed your plan/);
  // The ledger order is the existing ADMIN grant.
  const order = await t.gw.repo.findRazorpayOrder(r.json.orderId);
  assert.equal(order.method, 'ADMIN');
  assert.equal(order.amountInPaise, 0);
  // Audit trail on the rider page.
  const d = (await t.api('GET', `/admin/riders/${id}`, null, admin.token)).json;
  const actions = d.audit.map((e) => e.action);
  for (const a of ['rider.assign_plan', 'subscription.grant', 'rider.email']) assert.ok(actions.includes(a), a);
  assert.equal(d.audit.find((e) => e.action === 'rider.assign_plan').details.reason, 'Beta tester thank-you');
  assert.ok(d.payments.some((p) => p.orderId === r.json.orderId && p.method === 'ADMIN'));
  // Without the e-mail: none sent.
  const n0 = direct().length;
  const r2 = await t.api('POST', `/admin/riders/${ravi.user.userId}/assign-plan`, { plan: 'group_large', until: new Date(Date.now() + 10 * DAY).toISOString().slice(0, 10), reason: 'Club lead', sendEmail: false }, admin.token);
  assert.equal(r2.status, 200);
  assert.equal(r2.json.plan.tier, 'group_large');
  assert.equal(r2.json.email, null);
  assert.equal(direct().length, n0);
  assert.ok(r2.json.plan.daysRemaining >= 10 && r2.json.plan.daysRemaining <= 11);
});

test('personal coupon: a single-use code bound to the rider, redeemable only by them; listed in /me/coupons', async () => {
  const id = asha.user.userId;
  const r = await t.api('POST', `/admin/riders/${id}/coupon`, { parentCode: 'PARENT40', validDays: 10, reason: 'Missed a ride', sendEmail: false, requestId: rid() }, admin.token);
  assert.equal(r.status, 201, JSON.stringify(r.json));
  const code = r.json.coupon.code;
  assert.match(code, /^PARENT-[A-HJ-NP-Z2-9]{8}$/);
  assert.equal(r.json.coupon.discount, '40% off');
  assert.equal(r.json.email, null);
  const c = await t.gw.repo.findCoupon(code);
  assert.deepEqual(c.allowedUserIds, [id]);
  assert.equal(c.maxUsageTotal, 1);
  assert.equal(c.parentCode, 'PARENT40');
  assert.ok(c.expiresAt <= Date.now() + 10 * DAY + 60000);
  // Only Asha can use it (Ravi's quote refuses it; Asha's applies it).
  const other = await t.api('GET', `/membership/quote?plan=group_large&coupon=${code}`, null, noContact.token);
  assert.ok(other.json.couponError, JSON.stringify(other.json));
  const mine = await t.api('GET', `/membership/quote?plan=group_large&coupon=${code}`, null, asha.token);
  assert.equal(mine.status, 200, JSON.stringify(mine.json));
  assert.ok(!mine.json.couponError, JSON.stringify(mine.json.couponError));
  assert.ok(mine.json.couponDiscountInr > 0);
  // Same request id -> the same code (a double click never makes two).
  const reqId = rid();
  const q1 = await t.api('POST', `/admin/riders/${id}/coupon`, { quick: { discountType: 'fixed', discountValue: 75 }, validDays: 5, reason: 'Support case', requestId: reqId }, admin.token);
  const q2 = await t.api('POST', `/admin/riders/${id}/coupon`, { quick: { discountType: 'fixed', discountValue: 75 }, validDays: 5, reason: 'Support case', requestId: reqId }, admin.token);
  assert.match(q1.json.coupon.code, /^GIFT-/);
  assert.equal(q2.json.coupon.code, q1.json.coupon.code);
  assert.equal(q1.json.coupon.discount, '₹75 off');
  // Bad input.
  assert.equal((await t.api('POST', `/admin/riders/${id}/coupon`, { quick: { discountType: 'percentage', discountValue: 140 }, reason: 'abc' }, admin.token)).json.code, 'BAD_COUPON');
  assert.equal((await t.api('POST', `/admin/riders/${id}/coupon`, { parentCode: 'NOPE99', reason: 'abc' }, admin.token)).status, 409);
  assert.equal((await t.api('POST', `/admin/riders/${id}/coupon`, { parentCode: code, reason: 'abc' }, admin.token)).status, 409, 'a child code is never a parent');
  // The rider sees their own codes; another rider sees none of them.
  const mc = await t.api('GET', '/me/coupons', null, asha.token);
  assert.equal(mc.status, 200);
  assert.deepEqual(mc.json.coupons.map((x) => x.code).sort(), [code, q1.json.coupon.code].sort());
  const one = mc.json.coupons.find((x) => x.code === code);
  assert.equal(one.state, 'ACTIVE');
  assert.equal(one.plansPath, `/plans?coupon=${code}`);
  assert.deepEqual((await t.api('GET', '/me/coupons', null, ravi.token)).json.coupons, []);
  // Rider page: assigned coupons and the audit entry.
  const d = (await t.api('GET', `/admin/riders/${id}`, null, admin.token)).json;
  assert.ok(d.coupons.assigned.some((x) => x.code === code && x.source === 'personal'));
  assert.equal(d.audit.find((e) => e.action === 'rider.coupon').details.reason, 'Support case');
  // Global search finds the code.
  const s = await t.api('GET', `/admin/search?q=${code}`, null, admin.token);
  assert.equal(s.json.coupons[0].code, code);
  assert.equal(s.json.coupons[0].personal, id);
});

test('coupon e-mail consent: no Offers consent -> code only; service message needs a note; with consent it is a marketing e-mail', async () => {
  const id = ravi.user.userId;
  const n0 = direct('ravi.kumar@coroute.test').length;
  const r = await t.api('POST', `/admin/riders/${id}/coupon`, { parentCode: 'PARENT40', reason: 'Asked on chat', sendEmail: true, requestId: rid() }, admin.token);
  assert.equal(r.status, 201);
  assert.ok(r.json.coupon.code, 'the code is made anyway, to share by hand');
  assert.equal(r.json.email.sent, false);
  assert.equal(r.json.email.code, 'NO_CONSENT');
  assert.equal(direct('ravi.kumar@coroute.test').length, n0);
  const noNote = await t.api('POST', `/admin/riders/${id}/coupon`, { parentCode: 'PARENT40', reason: 'Asked on chat', sendEmail: true, service: true, serviceNote: '', requestId: rid() }, admin.token);
  assert.equal(noNote.json.email.code, 'NOTE_REQUIRED');
  const svc = await t.api('POST', `/admin/riders/${id}/coupon`, { parentCode: 'PARENT40', reason: 'Asked on chat', sendEmail: true, service: true, serviceNote: 'Rider asked for a code on support chat #4411', requestId: rid() }, admin.token);
  assert.equal(svc.json.email.sent, true, JSON.stringify(svc.json));
  assert.equal(svc.json.email.classification, 'service');
  const m = direct('ravi.kumar@coroute.test').pop();
  assert.ok(m.html.includes(svc.json.coupon.code));
  assert.ok(m.html.includes(`/plans?coupon=${svc.json.coupon.code}`));
  assert.match(m.text, /you asked the CoRoute team/);
  const d = (await t.api('GET', `/admin/riders/${id}`, null, admin.token)).json;
  const ent = d.audit.find((e) => e.action === 'rider.email.service');
  assert.equal(ent.details.serviceNote, 'Rider asked for a code on support chat #4411');
  // With the consent: an ordinary offer e-mail with the unsubscribe header.
  assert.equal((await t.api('PUT', '/web/marketing-consent', { offersEmail: true }, ravi.token)).status, 200);
  const ok = await t.api('POST', `/admin/riders/${id}/coupon`, { quick: { discountType: 'percentage', discountValue: 20 }, reason: 'Loyal rider', sendEmail: true, requestId: rid() }, admin.token);
  assert.equal(ok.json.email.sent, true);
  assert.equal(ok.json.email.classification, 'marketing');
  const m2 = direct('ravi.kumar@coroute.test').pop();
  assert.match(m2.headers['List-Unsubscribe'], /\/email\/unsubscribe\?u=/);
  assert.match(m2.subject, /coupon just for you/);
  assert.match(m2.text, /CoRoute, 12 MG Road/);
});

test('1:1 e-mail: transactional vs marketing, suppression respected, idempotent, audited', async () => {
  const id = noContact.user.userId;
  const design = { subject: 'About your account, {firstName}', preheader: '', blocks: [{ type: 'text', text: 'Hi {firstName}, your crew invite is fixed. See [the guide](/guide).' }] };
  const requestId = rid();
  const n0 = direct('neha.shah@coroute.test').length;
  const r = await t.api('POST', `/admin/riders/${id}/email`, { design, category: 'account', requestId, templateId: 'quick' }, admin.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.sent, true);
  assert.equal(r.json.classification, 'transactional');
  const again = await t.api('POST', `/admin/riders/${id}/email`, { design, category: 'account', requestId }, admin.token);
  assert.equal(again.json.duplicate, true);
  assert.equal(direct('neha.shah@coroute.test').length - n0, 1, 'sent once');
  const m = direct('neha.shah@coroute.test').pop();
  assert.equal(m.subject, 'About your account, Neha');
  assert.match(m.text, /wrote to you about your account/);
  assert.ok(!m.headers['List-Unsubscribe']);
  // A coupon is never transactional.
  const promo = { subject: 'Hi', blocks: [{ type: 'coupon', code: 'PARENT40', buttonLabel: 'Use it' }] };
  const bad = await t.api('POST', `/admin/riders/${id}/email`, { design: promo, category: 'account', requestId: rid() }, admin.token);
  assert.equal(bad.status, 400);
  assert.match(bad.json.error, /account e-mail cannot carry a coupon/);
  // Marketing without consent: refused with the reason (409 NO_CONSENT).
  const mk = await t.api('POST', `/admin/riders/${id}/email`, { design: promo, category: 'marketing', requestId: rid() }, admin.token);
  assert.equal(mk.status, 409);
  assert.equal(mk.json.code, 'NO_CONSENT');
  assert.equal(mk.json.check.offersConsent, false);
  // Unique code in a 1:1 marketing e-mail (service message): a single-use code for this rider.
  const uq = await t.api('POST', `/admin/riders/${id}/email`, { design: promo, category: 'marketing', uniqueCoupon: { enabled: true, prefix: 'DM', validDays: 7 }, service: true, serviceNote: 'Asked by phone', requestId: rid() }, admin.token);
  assert.equal(uq.json.sent, true, JSON.stringify(uq.json));
  assert.match(uq.json.couponCode, /^DM-/);
  assert.deepEqual((await t.gw.repo.findCoupon(uq.json.couponCode)).allowedUserIds, [id]);
  // Suppressed (bounce): nothing goes, transactional or service.
  assert.equal((await t.api('POST', '/admin/email/suppression', { email: 'neha.shah@coroute.test', reason: 'bounce' }, admin.token)).status, 201);
  const sup = await t.api('POST', `/admin/riders/${id}/email`, { design, category: 'account', requestId: rid() }, admin.token);
  assert.equal(sup.status, 409);
  assert.equal(sup.json.code, 'SUPPRESSED');
  const sup2 = await t.api('POST', `/admin/riders/${id}/email`, { design: promo, category: 'marketing', service: true, serviceNote: 'asked', requestId: rid() }, admin.token);
  assert.equal(sup2.json.code, 'SUPPRESSED');
  const chk = await t.api('POST', `/admin/riders/${id}/email/check`, { category: 'account' }, admin.token);
  assert.equal(chk.json.check.suppressed, 'bounce');
  assert.equal(chk.json.check.allowed, false);
  // Rider page: the direct e-mails and the audit entries.
  const d = (await t.api('GET', `/admin/riders/${id}`, null, admin.token)).json;
  assert.equal(d.emails.suppressed, 'bounce');
  assert.ok(d.emails.recent.some((x) => x.subject === 'About your account, {firstName}' && x.status === 'SENT'));
  assert.equal(d.audit.filter((e) => e.action === 'rider.email').length, 2, 'the duplicate is not audited twice');
});

test('e-mail wizard system templates are valid designs from the editable words; account notices to named riders', async () => {
  const r = await t.api('GET', '/admin/email-wizard/templates', null, admin.token);
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.system.map((x) => x.id), ['welcome', 'plan_assigned', 'coupon_gift']);
  for (const s of r.json.system) assert.deepEqual(validateDesign(s.design, { category: s.category, origin: 'https://coroute.example' }).errors, [], s.id);
  // Editing the words in Settings > Templates changes the design (and the preview renders it).
  const save = await t.api('PUT', '/admin/templates/plan_assigned', { fields: { subject: 'Welcome to {{plan}}, {{name}}', heading: 'Enjoy {{plan}}', intro: 'Until {{validUntil}}.', buttonLabel: 'Open account', footer: 'Ride safe.' } }, admin.token);
  assert.equal(save.status, 200, JSON.stringify(save.json));
  const r2 = await t.api('GET', '/admin/email-wizard/templates', null, admin.token);
  assert.equal(r2.json.system.find((x) => x.id === 'plan_assigned').design.subject, 'Welcome to {planName}, {firstName}');
  const pv = await t.api('POST', '/admin/templates/coupon_gift/preview', {}, admin.token);
  assert.equal(pv.status, 200);
  assert.match(pv.json.mail.html, /GIFT-SAMPLE01/);
  assert.equal(toStudio('Hi {{name}} {oops} {{supportEmail}}', { name: 'firstName' }, { supportEmail: 'help@x' }), 'Hi {firstName} oops help@x');
  // Wizard "several riders": an account notice to named riders (no consent needed, at most 50 names).
  const a = await me(asha.token);
  const cnt = await t.api('POST', '/admin/email/studio/audience-count', { audience: { kind: 'usernames', usernames: [a.username] }, category: 'account' }, admin.token);
  assert.equal(cnt.status, 200, JSON.stringify(cnt.json));
  assert.equal(cnt.json.riders, 1);
  const many = Array.from({ length: 51 }, (_, i) => `rider_${i}`);
  assert.equal((await t.api('POST', '/admin/email/studio/audience-count', { audience: { kind: 'usernames', usernames: many }, category: 'account' }, admin.token)).status, 400);
});

test('global search: riders by username / e-mail, orders by id', async () => {
  const a = await me(asha.token);
  const s1 = await t.api('GET', `/admin/search?q=${encodeURIComponent(a.username.slice(0, 6))}`, null, admin.token);
  assert.ok(s1.json.riders.some((x) => x.userId === asha.user.userId));
  const s2 = await t.api('GET', '/admin/search?q=ravi.kumar%40', null, admin.token);
  assert.equal(s2.json.riders[0].userId, ravi.user.userId);
  const d = (await t.api('GET', `/admin/riders/${asha.user.userId}`, null, admin.token)).json;
  const orderId = d.payments[0].orderId;
  const s3 = await t.api('GET', `/admin/search?q=${orderId}`, null, admin.token);
  assert.equal(s3.json.orders[0].orderId, orderId);
  assert.equal(s3.json.orders[0].userId, asha.user.userId);
  assert.deepEqual((await t.api('GET', '/admin/search?q=a', null, admin.token)).json, { riders: [], orders: [], coupons: [] });
});
