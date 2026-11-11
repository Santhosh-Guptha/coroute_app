'use strict';
/**
 * 3.56 purchase receipt and refund e-mails (src/purchase_email.js, docs/features_355/purchase_email.md)
 * and the editable templates (src/templates.js). SMTP is a fake transport.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'mailadmin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
process.env.SUPPORT_EMAIL = 'help@coroute.example';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { settleMembershipPayment, activateMembershipFromOrder } = require('../src/membership_routes');
const { Mailer } = require('../src/mailer');
const { PurchaseEmail } = require('../src/purchase_email');

const mails = [];
let failNext = 0;
// 3.57: the welcome e-mail of each new account (lifecycle_emails.js) is not part of these tests.
const mailTransport = { async sendMail(m) { if (m.headers && m.headers['X-CoRoute-Mail'] === 'welcome') return { messageId: '<welcome@test>' }; if (failNext > 0) { failNext--; throw Object.assign(new Error('connection refused'), { code: 'ECONNREFUSED' }); } mails.push(m); return { messageId: `<m${mails.length}@test>` }; } };

let t, admin, rider, other;
before(async () => {
  t = await boot({ mailTransport });
  admin = await t.register('Mail Admin', 'mailadmin@coroute.test');
  rider = await t.register('Asha Rao', 'asha.rider@coroute.test');
  other = await t.register('Other Rider', 'other.rider@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

const svc = () => t.gw.notifications.purchaseEmail;
let n = 0;
async function order(user, extra = {}) {
  n++;
  const orderId = `order_TEST${String(n).padStart(6, '0')}`;
  await t.gw.repo.saveRazorpayOrder({
    orderId, internalOrderId: `CR-${n}`, userId: user.user.userId, category: 'group_small', amountInPaise: 49900, originalPrice: 599, currency: 'INR',
    status: 'CREATED', mode: 'test', channel: 'web', createdAt: Date.now(), offerCode: 'RIDE10',
    quote: { planName: 'Small Group', seats: 6, billingDays: 30, breakdown: [
      { label: 'Small Group (30 days)', amountInr: 599 }, { label: 'Launch offer', amountInr: -50 }, { label: 'Coupon RIDE10', amountInr: -50 }, { label: 'To pay now', amountInr: 499 },
    ] },
    ...extra,
  });
  return orderId;
}

test('one receipt per order across the webhook and the payment check, with every payment detail', async () => {
  mails.length = 0;
  const orderId = await order(rider);
  const o = await t.gw.repo.findRazorpayOrder(orderId);
  await settleMembershipPayment({ repo: t.gw.repo, order: o, payment: { id: 'pay_TESTabc123', method: 'upi' } });
  // The payment check arrives after the webhook (or the webhook is retried): no second e-mail.
  await activateMembershipFromOrder({ repo: t.gw.repo, order: await t.gw.repo.findRazorpayOrder(orderId), paymentId: 'pay_TESTabc123', method: 'RAZORPAY', source: 'web_verification' });
  await settleMembershipPayment({ repo: t.gw.repo, order: await t.gw.repo.findRazorpayOrder(orderId), payment: { id: 'pay_TESTabc123' } });
  await svc().idle();
  assert.equal(mails.length, 1);
  const m = mails[0];
  assert.equal(m.to, 'asha.rider@coroute.test');
  assert.equal(m.subject, 'Your CoRoute receipt: Small Group');
  for (const s of ['Small Group (30 days)', '₹599.00', 'Launch offer', 'Coupon RIDE10', 'Amount charged: ₹499.00', 'pay_TESTabc123', orderId, 'IST',
    `https://coroute.example/receipt?order=${orderId}`, 'help@coroute.example', 'Thank you, Asha']) {
    assert.ok(m.text.includes(s), `text has ${s}`);
  }
  assert.match(m.html, /<html/);
  assert.ok(m.html.includes('₹499.00') && m.html.includes(`receipt?order=${orderId}`));
  assert.ok(!/To pay now/.test(m.text), 'the "To pay now" line becomes "Amount charged"');
  const log = await t.gw.soda.query('mail_log', { orderId }, { limit: 5 });
  assert.equal(log.length, 1);
  assert.equal(log[0].value.status, 'SENT');
  assert.equal(log[0].value.to, 'a***@coroute.test', 'the log keeps a masked address only');
});

test('the optional receipt address on the order wins; someone else\'s order is not found', async () => {
  mails.length = 0;
  const orderId = await order(rider);
  assert.equal((await t.api('POST', '/web/receipt-email', { orderId, email: 'not-an-email' }, rider.token)).status, 400);
  assert.equal((await t.api('POST', '/web/receipt-email', { orderId, email: 'x@y.test' }, other.token)).status, 404);
  assert.equal((await t.api('POST', '/web/receipt-email', { orderId, email: 'billing@family.test' }, rider.token)).status, 200);
  await t.gw.repo.updateRazorpayOrder(orderId, { status: 'PAID', paymentId: 'pay_TESTdef456', paidAt: Date.now() });
  await svc().idle();
  assert.equal(mails.length, 1);
  assert.equal(mails[0].to, 'billing@family.test');
});

test('an address given after a fast payment still gets the receipt; free orders and missing addresses are skipped', async () => {
  mails.length = 0;
  const ghost = await order({ user: { userId: 'no-such-user' } });
  await t.gw.repo.updateRazorpayOrder(ghost, { status: 'PAID', paymentId: 'pay_X' });
  await svc().idle();
  assert.equal(mails.length, 0);
  assert.deepEqual(await svc().sendReceipt(ghost), { skipped: 'NO_EMAIL' });
  const free = await order(rider, { amountInPaise: 0, isFree: true });
  await t.gw.repo.updateRazorpayOrder(free, { status: 'PAID', paymentId: 'free_1' });
  await svc().idle();
  assert.equal(mails.length, 0, 'no receipt for a ₹0 activation');
  // Disabled mailer: nothing claimed, nothing sent.
  const off = new PurchaseEmail({ repo: t.gw.repo, mailer: new Mailer({ transport: null }), templates: t.gw.notifications.templates, config: {} });
  assert.deepEqual(await off.sendReceipt(ghost), { skipped: 'MAIL_DISABLED' });
});

test('refund e-mail once per refunded amount', async () => {
  const orderId = await order(rider);
  await t.gw.repo.updateRazorpayOrder(orderId, { status: 'PAID', paymentId: 'pay_TESTref1', paidAt: Date.now() });
  await svc().idle();
  mails.length = 0;
  const patch = { refundId: 'rfnd_TEST1', refundStatus: 'PROCESSED', refundedAmountInPaise: 49900, refundedAmount: 499, fullyRefunded: true };
  await t.gw.repo.updateRazorpayOrder(orderId, patch);
  await t.gw.repo.updateRazorpayOrder(orderId, { ...patch, updatedAt: Date.now() }); // webhook after the admin refund
  await svc().idle();
  assert.equal(mails.length, 1);
  assert.equal(mails[0].subject, 'Your CoRoute refund: ₹499.00');
  assert.ok(mails[0].text.includes('rfnd_TEST1') && mails[0].text.includes('Full refund'));
});

test('a failed SMTP send is retried by the job', async () => {
  mails.length = 0;
  failNext = 1;
  const orderId = await order(rider);
  await t.gw.repo.updateRazorpayOrder(orderId, { status: 'PAID', paymentId: 'pay_TESTretry', paidAt: Date.now() });
  await svc().idle();
  assert.equal(mails.length, 0);
  const row = await t.gw.soda.findOne('mail_log', { key: `receipt:${orderId}` });
  assert.equal(row.value.status, 'RETRY');
  await t.gw.soda.replace('mail_log', row.key, { ...row.value, nextAttemptAt: 0 });
  assert.equal(await svc().retryDue(), 1);
  assert.equal(mails.length, 1);
  assert.equal((await t.gw.soda.findOne('mail_log', { key: `receipt:${orderId}` })).value.status, 'SENT');
});

test('templates: admin edits with variables, unknown variables refused, preview, history, reset', async () => {
  assert.equal((await t.api('GET', '/admin/templates', null, rider.token)).status, 403);
  const list = await t.api('GET', '/admin/templates', null, admin.token);
  assert.equal(list.status, 200);
  const ids = list.json.templates.map((x) => x.id);
  for (const id of ['purchase_receipt', 'refund', 'sos_sms', 'sos_safe_sms', 'push_plan_active', 'push_plan_ending', 'guardian_arrival']) assert.ok(ids.includes(id), id);
  const cur = list.json.templates.find((x) => x.id === 'purchase_receipt').current;
  let r = await t.api('PUT', '/admin/templates/purchase_receipt', { fields: { ...cur, subject: 'Receipt for {{plan}} ({{nmae}})' } }, admin.token);
  assert.equal(r.status, 400);
  assert.match(r.json.error, /unknown variable \{\{nmae\}\}/);
  r = await t.api('PUT', '/admin/templates/purchase_receipt', { fields: { ...cur, subject: 'CoRoute payment {{amount}} for {{plan}}' } }, admin.token);
  assert.equal(r.status, 200);
  assert.equal(r.json.version, 1);
  const pv = await t.api('POST', '/admin/templates/purchase_receipt/preview', { fields: { ...cur, subject: 'Hi {{name}}' } }, admin.token);
  assert.equal(pv.json.rendered.subject, 'Hi Asha');
  mails.length = 0;
  const orderId = await order(rider);
  await t.gw.repo.updateRazorpayOrder(orderId, { status: 'PAID', paymentId: 'pay_TESTtpl', paidAt: Date.now() });
  await svc().idle();
  assert.equal(mails[0].subject, 'CoRoute payment ₹499.00 for Small Group');
  // Push templates keep the Play policy.
  r = await t.api('PUT', '/admin/templates/push_plan_ending', { fields: { title: 'Your plan', body: 'Renew before {{date}} for a discount' } }, admin.token);
  assert.equal(r.status, 400);
  assert.match(r.json.error, /Google Play/);
  const h = await t.api('GET', '/admin/templates/purchase_receipt/history', null, admin.token);
  assert.equal(h.json.history.length, 1);
  r = await t.api('POST', '/admin/templates/purchase_receipt/reset', null, admin.token);
  assert.equal(r.json.version, 2);
  const after2 = (await t.api('GET', '/admin/templates', null, admin.token)).json.templates.find((x) => x.id === 'purchase_receipt');
  assert.equal(after2.isDefault, true);
  assert.equal(after2.current.subject, 'Your CoRoute receipt: {{plan}}');
});

test('an edited plan push template reaches the neutral plan notice', async () => {
  const P = require('../src/push');
  const r = await t.api('PUT', '/admin/templates/push_plan_active', { fields: { title: 'CoRoute', body: '{{plan}} is ready to ride.' } }, admin.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  await new Promise((res) => setTimeout(res, 30));
  assert.equal(P.planNotice({ type: 'SUBSCRIPTION_ACTIVATED', plan: 'group_small' }).body, 'Small Group is ready to ride.');
  await t.api('POST', '/admin/templates/push_plan_active/reset', null, admin.token);
  await new Promise((res) => setTimeout(res, 30));
  assert.equal(P.planNotice({ type: 'SUBSCRIPTION_ACTIVATED', plan: 'group_small' }).body, 'Your Small Group plan is active.');
});
