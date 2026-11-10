'use strict';
/**
 * 3.56 website payments and coupons: security review fixes (docs/features_355/web_payments_security.md).
 * Each test names the threat it covers. Razorpay is mocked: orders, payments (GET /payments/:id) and refunds.
 */
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_secKey';
process.env.RAZORPAY_TEST_KEY_SECRET = 'sec_secret_355';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_sec_355';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'secadmin@coroute.test';

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { setRazorpayFetch } = require('../src/razorpay_gateway');
const sec = require('../src/payment_security');
const pricing = require('../src/plan_pricing');
const { boot } = require('./_helpers');

// ---------------------------------------------------------------- Razorpay mock
const rzp = { orders: new Map(), payments: new Map(), refunds: 0, orderAmountDelta: 0 };
setRazorpayFetch(async (url, opts = {}) => {
  const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
  if (opts.method === 'POST' && url.endsWith('/orders')) {
    const b = JSON.parse(opts.body);
    const id = `order_${crypto.randomBytes(7).toString('hex')}`;
    rzp.orders.set(id, b);
    return reply(200, { id, amount: b.amount + rzp.orderAmountDelta, currency: b.currency, status: 'created' });
  }
  const pay = /\/payments\/([A-Za-z0-9_]+)$/.exec(url);
  if (pay && (!opts.method || opts.method === 'GET')) {
    const p = rzp.payments.get(pay[1]);
    return p ? reply(200, p) : reply(404, { error: { description: 'not found' } });
  }
  const ref = /\/payments\/([A-Za-z0-9_]+)\/refund$/.exec(url);
  if (ref && opts.method === 'POST') {
    rzp.refunds++;
    const b = JSON.parse(opts.body);
    return reply(200, { id: `rfnd_${crypto.randomBytes(5).toString('hex')}`, amount: b.amount, status: 'processed' });
  }
  return reply(404, {});
});
const sign = (orderId, paymentId) => crypto.createHmac('sha256', 'sec_secret_355').update(`${orderId}|${paymentId}`).digest('hex');
const hookSig = (body) => crypto.createHmac('sha256', 'whsec_sec_355').update(body).digest('hex');
const pid = () => `pay_${crypto.randomBytes(6).toString('hex')}`;
const DAY = 86400000;
const WEB = { 'X-CoRoute-Client': 'web' };

let env;
let admin;
const logLines = [];
const capture = { info: (...a) => logLines.push(a.join(' ')), warn: (...a) => logLines.push(a.join(' ')), error: (...a) => logLines.push(a.join(' ')), debug: () => {}, log: (...a) => logLines.push(a.join(' ')) };
let ipSeq = 0;
/** A rider (each registration from its own client IP: the sign-up limit is per IP). */
async function rider(label) {
  ipSeq++;
  const email = `${label}.${crypto.randomBytes(3).toString('hex')}@coroute.test`.toLowerCase();
  const r = await env.api('POST', '/auth/register', {
    name: `Rider ${label}`, email, password: 'Password#123', phone: `+9197${String(10000000 + ipSeq * 7919).slice(-8)}`,
    vehicleType: 'Motorcycle', vehicleNo: `KA01AB${String(1000 + ipSeq).slice(-4)}`, emergencyContact: '+919000000001', emergencyContactName: 'Family',
  }, null, { 'X-Forwarded-For': `10.9.${Math.floor(ipSeq / 200)}.${ipSeq % 200}` });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return { token: r.json.token, user: r.json.user, email };
}
/** A paid order for `who` (web), optionally with a coupon. */
async function order(who, category = 'group_small', offerCode) {
  const o = await env.api('POST', '/membership/order', { category, ...(offerCode ? { offerCode } : {}) }, who.token, WEB);
  assert.equal(o.status, 201, JSON.stringify(o.json));
  return o.json;
}
/** Razorpay knows this payment (captured, for the order's amount unless told otherwise). */
function captured(o, extra = {}) {
  const id = pid();
  rzp.payments.set(id, { id, order_id: o.orderId, amount: o.amountInPaise, currency: 'INR', status: 'captured', method: 'upi', ...extra });
  return id;
}
async function webhook(pathname, event, id = `evt_${crypto.randomBytes(5).toString('hex')}`) {
  const body = JSON.stringify(event);
  const res = await fetch(env.base + pathname, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Razorpay-Signature': hookSig(body), 'X-Razorpay-Event-Id': id }, body });
  return { status: res.status, json: await res.json().catch(() => ({})) };
}
async function newCoupon(code, fields = {}) {
  const r = await env.api('POST', '/admin/coupons', { code, name: code, discountType: 'percentage', discountValue: 20, maxUsageTotal: 100, maxUsagePerUser: 1, applicablePlans: ['all'], ...fields }, admin.token);
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json.coupon;
}

before(async () => {
  env = await boot({ logger: capture });
  admin = await rider('secadmin').catch(() => null);
  // The bootstrap admin needs that exact e-mail.
  const r = await env.api('POST', '/auth/register', { name: 'Sec Admin', email: 'secadmin@coroute.test', password: 'Password#123', phone: '+919811100000', vehicleType: 'Motorcycle', vehicleNo: 'KA01ZZ9999', emergencyContact: '+919000000001', emergencyContactName: 'Family' }, null, { 'X-Forwarded-For': '10.99.0.1' });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  const login = await env.api('POST', '/auth/login', { identifier: 'secadmin@coroute.test', password: 'Password#123' }, null, { 'X-Forwarded-For': '10.99.0.2' });
  admin = { token: login.json.token, user: login.json.user };
  assert.equal(admin.user.role, 'MASTER_ADMIN');
});
after(async () => { setRazorpayFetch(null); await env.gw.shutdown(); });
beforeEach(() => { sec.couponGuard.reset(); rzp.orderAmountDelta = 0; });

// ================================================================ pure rules
test('IST times: dates are India-time days (end exclusive), local times are India time, zones are honoured', () => {
  assert.equal(sec.istTime('2026-11-30', 'start'), Date.parse('2026-11-29T18:30:00Z'));
  assert.equal(sec.istTime('2026-11-30', 'end'), Date.parse('2026-11-30T18:30:00Z'), '"until 30 Nov" covers all of 30 Nov in India');
  assert.equal(sec.istTime('2026-11-30T09:15'), Date.parse('2026-11-30T03:45:00Z'));
  assert.equal(sec.istTime('2026-11-30T09:15:00Z'), Date.parse('2026-11-30T09:15:00Z'));
  assert.equal(sec.istTime(1790000000000), 1790000000000);
  for (const bad of ['tomorrow', '2026-13-45x', '<script>', {}, -5]) assert.equal(sec.istTime(bad), 0, String(bad));
});

test('coupon window: valid from its start (inclusive) to its end (exclusive); expired at exactly expiresAt', () => {
  const now = Date.now();
  const c = { code: 'EDGE', status: 'ACTIVE', discountType: 'percentage', discountValue: 10, applicableTiers: ['all'], validFrom: now - 1000, expiresAt: now };
  assert.equal(pricing.checkCoupon(c, { planId: 'group_small', baseInr: 49 }).reason, 'COUPON_EXPIRED');
  assert.equal(pricing.checkCoupon({ ...c, expiresAt: now + 60000 }, { planId: 'group_small', baseInr: 49 }).ok, true);
  assert.equal(pricing.checkCoupon({ ...c, validFrom: now + 60000, expiresAt: now + 120000 }, { planId: 'group_small', baseInr: 49 }).reason, 'COUPON_SCHEDULED');
  assert.equal(new (require('../src/oracle/repo').Repo)({}).computeCouponStatus({ expiresAt: now - 1 }, now), 'EXPIRED');
});

test('uniform refusals: missing, draft, archived, scheduled and private codes read the same', () => {
  const same = sec.couponRefusal(null);
  assert.deepEqual(same, { error: "We couldn't find that code", reason: 'COUPON_NOT_FOUND' });
  for (const reason of ['COUPON_SCHEDULED', 'COUPON_INACTIVE', 'COUPON_ARCHIVED', 'NOT_ELIGIBLE']) assert.deepEqual(sec.couponRefusal({ error: 'x', reason }), same, reason);
  assert.deepEqual(sec.couponRefusal({ error: 'This code has expired', reason: 'COUPON_EXPIRED' }), { error: 'This code has expired', reason: 'COUPON_EXPIRED' }, 'a public code keeps its reason');
  const g = new sec.CouponGuard({ limit: 3, windowMs: 1000, now: () => 0 });
  const req = { user: { userId: 'u1' }, ip: '1.2.3.4' };
  for (let i = 0; i < 3; i++) { assert.equal(g.blocked(req), 0); g.failed(req); }
  assert.ok(g.blocked(req) > 0);
  assert.ok(g.blocked({ ip: '1.2.3.4' }) > 0, 'the IP is braked too (another account on the same client)');
});

test('payment must match the order: order id, amount in paise, currency, captured', () => {
  const o = { orderId: 'order_a', amountInPaise: 4900, currency: 'INR' };
  assert.equal(sec.paymentMismatch({ order_id: 'order_a', amount: 4900, currency: 'INR', status: 'captured' }, o), null);
  assert.equal(sec.paymentMismatch({ order_id: 'order_b', amount: 4900 }, o), 'ORDER_MISMATCH');
  assert.equal(sec.paymentMismatch({ order_id: 'order_a', amount: 100 }, o), 'AMOUNT_MISMATCH');
  assert.equal(sec.paymentMismatch({ order_id: 'order_a', amount: 4900, currency: 'USD' }, o), 'CURRENCY_MISMATCH');
  assert.equal(sec.paymentMismatch({ order_id: 'order_a', amount: 4900, status: 'failed' }, o), 'NOT_CAPTURED');
});

test('price floor: never below zero, never below the configured minimum (a free coupon is the exception)', () => {
  assert.equal(pricing.flooredDiscount({ discountType: 'fixed', discountValue: 500 }, 49, 0), 49, 'never below zero');
  assert.equal(pricing.flooredDiscount({ discountType: 'percentage', discountValue: 100 }, 49, 20), 29, 'floor ₹20');
  assert.equal(pricing.flooredDiscount({ discountType: 'free' }, 49, 20), 49, 'a free month stays free');
  assert.equal(pricing.flooredDiscount({ discountType: 'fixed', discountValue: 10 }, 15, 20), 0, 'already below the floor: no discount');
  const q = pricing.computeQuote({ catalog: { group_small: { name: 'Small', monthlyPriceInr: 49, capacity: 6 } }, planId: 'group_small', coupon: { code: 'BIG', discountType: 'percentage', discountValue: 100 }, minPayableInr: 20 });
  assert.equal(q.payableInr, 20);
});

// ================================================================ order and verify
test('order: the amount is the server\'s; Razorpay must echo it; the order expires; one code per order', async () => {
  const r = await rider('amt');
  const o = await env.api('POST', '/membership/order', { category: 'group_small', amount: 1, amountInPaise: 100, finalAmount: 0 }, r.token, WEB);
  assert.equal(o.status, 201);
  assert.equal(o.json.amountInPaise, 4900);
  assert.ok(o.json.expiresAt > Date.now() && o.json.expiresAt <= Date.now() + sec.ORDER_TTL_MS + 1000);
  assert.equal(o.json.checkoutTimeoutSeconds, sec.CHECKOUT_TIMEOUT_S);
  assert.equal((await env.gw.repo.findRazorpayOrder(o.json.orderId)).expiresAt, o.json.expiresAt);
  rzp.orderAmountDelta = 100; // a provider answer for another amount is refused, nothing stored
  const bad = await env.api('POST', '/membership/order', { category: 'group_small' }, r.token, WEB);
  assert.equal(bad.status, 502);
  assert.equal(bad.json.code, 'GATEWAY_AMOUNT_MISMATCH');
  rzp.orderAmountDelta = 0;
  const two = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: ['A', 'B'] }, r.token, WEB);
  assert.deepEqual([two.status, two.json.reason], [400, 'ONE_CODE_ONLY']);
  const mixed = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: 'WELCOME50', couponCode: 'RIDERFREE' }, r.token, WEB);
  assert.deepEqual([mixed.status, mixed.json.reason], [400, 'ONE_CODE_ONLY']);
});

test('verify: bound to the order\'s rider (admins too); strict formats; idempotent; never for another payment', async () => {
  const r = await rider('vfy');
  const other = await rider('vfyother');
  const o = await order(r);
  const p = captured(o);
  for (const who of [other, admin]) {
    const x = await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: sign(o.orderId, p) }, who.token, WEB);
    assert.equal(x.status, 403, 'someone else, even an admin, cannot settle this order');
  }
  assert.equal((await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: 'x y', signature: 'zz' }, r.token, WEB)).status, 400);
  assert.equal((await env.api('POST', '/membership/verify', { orderId: { $ne: 1 }, paymentId: p }, r.token, WEB)).status, 400);
  const ok = await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: sign(o.orderId, p) }, r.token, WEB);
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.ok(!('webhookEvents' in ok.json.order) && !('keyId' in ok.json.order), 'the rider sees no internal order fields');
  const mem1 = await env.gw.repo.findMembershipByOwner(r.user.userId);
  const again = await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: sign(o.orderId, p) }, r.token, WEB);
  assert.equal(again.status, 200);
  const mem2 = await env.gw.repo.findMembershipByOwner(r.user.userId);
  assert.equal(mem2.validUntil, mem1.validUntil, 'a repeat never extends the plan');
  const p2 = captured(o);
  const swap = await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p2, signature: sign(o.orderId, p2) }, r.token, WEB);
  assert.deepEqual([swap.status, swap.json.reason], [409, 'REPLAY_ATTACK_DETECTED']);
  const user = await env.gw.repo.findUserById(r.user.userId);
  assert.equal(user.paymentHistory.filter((h) => h.orderId === o.orderId).length, 1);
});

test('concurrent verify + both webhooks + retries for one payment activate exactly once', async () => {
  const r = await rider('race');
  const code = `RACE${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(code);
  const o = await order(r, 'group_small', code);
  const p = captured(o);
  const ws = await env.connect(r.token);
  const activations = [];
  const t0 = Date.now();
  const ev = { event: 'payment.captured', payload: { payment: { entity: rzp.payments.get(p) } } };
  const calls = [];
  for (let i = 0; i < 4; i++) calls.push(env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: sign(o.orderId, p) }, r.token, WEB));
  calls.push(webhook('/subscription/webhook', ev));
  calls.push(webhook('/subscription/webhook', ev));
  const res = await Promise.all(calls);
  for (const x of res) assert.ok([200, 409].includes(x.status), JSON.stringify(x.json));
  await new Promise((d) => setTimeout(d, 300));
  for (const m of ws.inbox) if (m.type === 'SUBSCRIPTION_ACTIVATED') activations.push(m);
  ws.close();
  assert.equal(activations.length, 1, 'one activation, one app notice');
  const user = await env.gw.repo.findUserById(r.user.userId);
  assert.equal(user.paymentHistory.filter((h) => h.orderId === o.orderId).length, 1);
  const c = await env.gw.repo.findCoupon(code);
  assert.equal(c.usageCount, 1, 'the coupon is counted once');
  assert.equal((await env.gw.repo.findRazorpayOrder(o.orderId)).status, 'PAID');
  assert.ok(Date.now() - t0 < 5000);
});

test('amount / currency check: a payment for another amount never activates (verify and webhook)', async () => {
  const r = await rider('mismatch');
  const o = await order(r);
  const p = captured(o, { amount: 100 });
  const v = await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: sign(o.orderId, p) }, r.token, WEB);
  assert.deepEqual([v.status, v.json.reason], [400, 'AMOUNT_MISMATCH']);
  const cur = captured(o, { currency: 'USD' });
  const w = await webhook('/subscription/webhook', { event: 'payment.captured', payload: { payment: { entity: rzp.payments.get(cur) } } });
  assert.equal(w.status, 200);
  assert.equal(await env.gw.repo.findMembershipByOwner(r.user.userId), null, 'nothing activated');
  assert.equal((await env.gw.repo.findRazorpayOrder(o.orderId)).paymentMismatch, 'CURRENCY_MISMATCH');
});

test('webhooks: one URL active (410 on the other), replay protection across URLs and restarts, test events never settle live orders', async () => {
  const off = await webhook('/membership/webhook', { event: 'payment.captured', payload: {} });
  assert.deepEqual([off.status, off.json.code], [410, 'WEBHOOK_URL_INACTIVE']);
  const r = await rider('hook');
  const o = await order(r);
  const p = captured(o);
  const id = `evt_${crypto.randomBytes(5).toString('hex')}`;
  const ev = { event: 'payment.failed', payload: { payment: { entity: { id: p, order_id: o.orderId, error_description: 'x' } } } };
  assert.equal((await webhook('/subscription/webhook', ev, id)).json.status, 'ok');
  process.env.RAZORPAY_WEBHOOK_URL = 'membership';
  try {
    const dup = await webhook('/membership/webhook', ev, id);
    assert.equal(dup.json.status, 'duplicate', 'the same event id on the other URL is a replay');
  } finally { delete process.env.RAZORPAY_WEBHOOK_URL; }
  assert.equal(await env.gw.repo.claimWebhookEvent(id), false, 'stored, not only in memory');
  // Bad signature, and a body changed after signing.
  const body = JSON.stringify({ event: 'payment.captured', payload: { payment: { entity: rzp.payments.get(p) } } });
  const tampered = body.replace(String(o.amountInPaise), '100');
  const res = await fetch(env.base + '/subscription/webhook', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Razorpay-Signature': hookSig(body) }, body: tampered });
  assert.equal(res.status, 400);
  // A live-mode order is never settled by a test-mode event.
  await env.gw.repo.updateRazorpayOrder(o.orderId, { mode: 'live', status: 'CREATED' });
  await webhook('/subscription/webhook', { event: 'payment.captured', payload: { payment: { entity: rzp.payments.get(p) } } });
  assert.equal(await env.gw.repo.findMembershipByOwner(r.user.userId), null);
});

test('refunds: a full refund ends the plan it bought; a refunded order can never be activated again', async () => {
  const r = await rider('refund');
  const o = await order(r);
  const p = captured(o);
  assert.equal((await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: sign(o.orderId, p) }, r.token, WEB)).status, 200);
  const ref = await env.api('POST', `/admin/payments/${o.orderId}/refund`, { reason: 'test' }, admin.token);
  assert.equal(ref.status, 200, JSON.stringify(ref.json));
  assert.equal(ref.json.fullyRefunded, true);
  assert.equal(ref.json.planRevoked, true);
  assert.equal(await env.gw.repo.findMembershipByOwner(r.user.userId), null, 'the plan ended');
  // Replays after the refund: verify, webhook (new event id) -> no activation.
  await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: sign(o.orderId, p) }, r.token, WEB);
  await webhook('/subscription/webhook', { event: 'payment.captured', payload: { payment: { entity: rzp.payments.get(p) } } });
  assert.equal(await env.gw.repo.findMembershipByOwner(r.user.userId), null, 'still no plan');
  // A refund recorded before the payment was settled (webhook order): the claim refuses it.
  const o2 = await order(r);
  const p2 = captured(o2);
  await env.gw.repo.updateRazorpayOrder(o2.orderId, { refunds: [{ id: 'rfnd_x', amountInPaise: o2.amountInPaise, status: 'PROCESSED' }], refundStatus: 'PROCESSED', fullyRefunded: true });
  const v2 = await env.api('POST', '/membership/verify', { orderId: o2.orderId, paymentId: p2, signature: sign(o2.orderId, p2) }, r.token, WEB);
  assert.deepEqual([v2.status, v2.json.reason], [409, 'ORDER_REFUNDED']);
  assert.equal(await env.gw.repo.findMembershipByOwner(r.user.userId), null);
});

// ================================================================ coupons
test('coupon caps hold under concurrency: total cap across riders, per-rider cap, free activations, double confirm', async () => {
  const code = `CAP${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(code, { maxUsageTotal: 3 });
  const riders = [];
  for (let i = 0; i < 8; i++) riders.push(await rider(`cap${i}`));
  const res = await Promise.all(riders.map((x) => env.api('POST', '/membership/order', { category: 'group_small', offerCode: code }, x.token, WEB)));
  assert.equal(res.filter((x) => x.status === 201).length, 3, res.map((x) => x.status).join(','));
  assert.ok(res.filter((x) => x.status !== 201).every((x) => x.status === 400 && x.json.reason === 'COUPON_RESERVATION_FAILED'));
  let c = await env.gw.repo.findCoupon(code);
  assert.equal(c.holds.length, 3);

  // One rider, many tabs: at most one live hold.
  const solo = await rider('tabs');
  const code2 = `TAB${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(code2, { maxUsageTotal: 50, maxUsagePerUser: 1 });
  await Promise.all([1, 2, 3, 4, 5].map(() => env.api('POST', '/membership/order', { category: 'group_small', offerCode: code2 }, solo.token, WEB)));
  c = await env.gw.repo.findCoupon(code2);
  assert.ok(c.holds.filter((h) => h.userId === solo.user.userId).length <= 1);

  // Free coupon (₹0 order): exactly the cap activates.
  const free = `FREE${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(free, { discountType: 'free', discountValue: 100, maxUsageTotal: 2 });
  const fr = [];
  for (let i = 0; i < 6; i++) fr.push(await rider(`free${i}`));
  const fres = await Promise.all(fr.map((x) => env.api('POST', '/membership/activate-free', { category: 'group_small', couponCode: free }, x.token, WEB)));
  assert.equal(fres.filter((x) => x.status === 201).length, 2, fres.map((x) => `${x.status}:${x.json.reason || ''}`).join(','));
  c = await env.gw.repo.findCoupon(free);
  assert.equal(c.usageCount, 2);
  assert.equal(c.status, 'USAGE_LIMIT_REACHED');

  // The same paid order confirmed five times at once counts once.
  const conf = await rider('confirm');
  const code3 = `CNF${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(code3);
  const o = await order(conf, 'group_small', code3);
  await Promise.all([1, 2, 3, 4, 5].map(() => env.gw.repo.confirmCouponRedemption(o.orderId, { paymentId: 'pay_x' })));
  c = await env.gw.repo.findCoupon(code3);
  assert.equal(c.usageCount, 1);
  assert.equal(c.holds.length, 0);
});

test('coupon brute force: unknown codes brake the rider and the IP (429), valid codes included, until the window ends', async () => {
  const r = await rider('brute');
  for (let i = 0; i < 10; i++) {
    const q = await env.api('GET', `/membership/quote?plan=group_small&coupon=GUESS${i}X`, null, r.token, WEB);
    assert.equal(q.status, 200);
    assert.equal(q.json.couponError.reason, 'COUPON_NOT_FOUND');
  }
  const blocked = await env.api('GET', '/membership/quote?plan=group_small&coupon=WELCOME50', null, r.token, WEB);
  assert.deepEqual([blocked.status, blocked.json.reason], [429, 'COUPON_ATTEMPTS']);
  assert.ok(Number(blocked.headers.get('retry-after')) > 0);
  assert.equal((await env.api('POST', '/membership/validate-coupon', { code: 'WELCOME50', category: 'group_small' }, r.token)).status, 429);
  assert.equal((await env.api('POST', '/membership/order', { category: 'group_small', offerCode: 'WELCOME50' }, r.token)).status, 429);
  assert.equal((await env.api('POST', '/subscription/validate-coupon', { code: 'WELCOME50', planTier: 'group_small' })).status, 429, 'the old public endpoint too (same client)');
  assert.equal((await env.api('GET', '/membership/quote?plan=group_small', null, r.token, WEB)).status, 200, 'the price without a code still loads');
});

test('coupon enumeration: missing, draft, archived, scheduled and private codes answer identically everywhere', async () => {
  const r = await rider('enum');
  const t = Date.now();
  const sched = `SCH${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(sched, { validFrom: t + 5 * DAY, expiresAt: t + 9 * DAY });
  const priv = `PRV${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(priv, { allowedUserIds: ['someone_else'] });
  const arch = `ARC${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(arch);
  await env.api('DELETE', `/admin/coupons/${arch}`, null, admin.token);
  const answers = [];
  for (const code of ['NOPE1234', sched, priv, arch]) {
    const q = await env.api('GET', `/membership/quote?plan=group_small&coupon=${code}`, null, r.token, WEB);
    const v = await env.api('POST', '/membership/validate-coupon', { code, category: 'group_small' }, r.token);
    const o = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: code }, r.token);
    const pub = await env.api('POST', '/validate-coupon', { code, planTier: 'group_small' });
    answers.push(JSON.stringify([q.json.couponError.error, q.json.couponError.reason, v.status, v.json.error, v.json.reason, o.status, o.json.error, pub.status, pub.json.error, pub.json.reason]));
    sec.couponGuard.reset();
  }
  assert.equal(new Set(answers).size, 1, answers.join('\n'));
  const pub = await env.api('POST', '/validate-coupon', { code: '<b>X</b>' });
  assert.ok(!JSON.stringify(pub.json).includes('<b>'), 'the typed code is never echoed');
});

test('coupon codes are case-insensitive and trimmed; admin dates in India time; expiry works to the millisecond', async () => {
  const r = await rider('case');
  const q = await env.api('GET', '/membership/quote?plan=group_small&coupon=%20welcome50%20', null, r.token, WEB);
  assert.equal(q.json.couponCode, 'WELCOME50');
  const code = `DAY${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  const c = await newCoupon(code.toLowerCase(), { validFrom: '2026-11-01', expiresAt: '2026-12-31' });
  assert.equal(c.code, code);
  assert.equal(c.validFrom, Date.parse('2026-10-31T18:30:00Z'));
  assert.equal(c.expiresAt, Date.parse('2026-12-31T18:30:00Z'), 'valid through 31 Dec, India time');
  const bad = await env.api('POST', '/admin/coupons', { code: 'BADDATE1', discountType: 'percentage', discountValue: 10, expiresAt: 'soon' }, admin.token);
  assert.deepEqual([bad.status, bad.json.reason], [400, 'BAD_WINDOW']);
  const short = `EXP${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(short, { validFrom: Date.now() - 1000, expiresAt: Date.now() + 400 });
  assert.equal((await env.api('GET', `/membership/quote?plan=group_small&coupon=${short}`, null, r.token, WEB)).json.couponCode, short);
  await new Promise((d) => setTimeout(d, 500));
  assert.equal((await env.api('GET', `/membership/quote?plan=group_small&coupon=${short}`, null, r.token, WEB)).json.couponError.reason, 'COUPON_EXPIRED');
});

test('price floor from the admin; a coupon that does not stack with offers is refused while one runs', async () => {
  const r = await rider('floor');
  const code = `HUN${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(code, { discountType: 'percentage', discountValue: 100 });
  assert.equal((await env.api('PUT', '/admin/pricing-rules', { minPayableInr: 20 }, r.token)).status, 403);
  assert.equal((await env.api('PUT', '/admin/pricing-rules', { minPayableInr: -1 }, admin.token)).status, 400);
  assert.equal((await env.api('PUT', '/admin/pricing-rules', { minPayableInr: 20 }, admin.token)).status, 200);
  try {
    const q = await env.api('GET', `/membership/quote?plan=group_small&coupon=${code}`, null, r.token, WEB);
    assert.equal(q.json.payableInr, 20);
    const o = await order(r, 'group_small', code);
    assert.equal(o.amountInPaise, 2000, 'the order uses the same floor');
  } finally {
    await env.api('PUT', '/admin/pricing-rules', { minPayableInr: 0 }, admin.token);
  }
  const audit = await env.api('GET', '/admin/audit?action=pricing', null, admin.token);
  assert.ok(audit.json.entries.some((e) => e.action === 'pricing.rules_update'));
});

// ================================================================ admin, session, receipts, logs
test('admin endpoints are MASTER_ADMIN only (rider 403, anonymous 401); coupon changes are audited', async () => {
  const r = await rider('notadmin');
  const calls = [
    ['POST', '/admin/coupons', { code: 'HACK123', discountType: 'free' }], ['PATCH', '/admin/coupons/WELCOME50', { maxUsageTotal: 99999 }],
    ['DELETE', '/admin/coupons/WELCOME50'], ['POST', '/admin/coupons/WELCOME50/pause'], ['GET', '/admin/coupons'],
    ['PUT', '/admin/membership/catalog', { catalog: {} }], ['PUT', '/admin/pricing-rules', { minPayableInr: 0 }], ['GET', '/admin/payments'],
    ['POST', '/admin/payments/order_x/refund', {}], ['GET', '/admin/board'], ['POST', '/admin/board', { title: 'x', body: 'y' }], ['GET', '/admin/audit'],
  ];
  for (const [m, p, b] of calls) {
    assert.equal((await env.api(m, p, b, r.token)).status, 403, `${m} ${p} rider`);
    assert.equal((await env.api(m, p, b)).status, 401, `${m} ${p} anonymous`);
  }
  const code = `AUD${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  await newCoupon(code);
  await env.api('PATCH', `/admin/coupons/${code}`, { maxUsageTotal: 5, usageCount: 0, usages: [], holds: [] }, admin.token);
  const audit = await env.api('GET', '/admin/audit?action=coupon', null, admin.token);
  assert.ok(audit.json.entries.some((e) => e.action === 'coupon.create' && e.target === code));
  assert.ok(audit.json.entries.some((e) => e.action === 'coupon.update' && e.target === code));
});

test('web session: strict headers, no cookies, uniform sign-in errors, rate limited; receipts only for the owner', async () => {
  for (const p of ['/plans', '/signin', '/account', '/receipt', '/updates']) {
    const res = await fetch(env.base.replace(/\/api$/, '') + p);
    assert.equal(res.status, 200, p);
    const csp = res.headers.get('content-security-policy');
    assert.ok(csp.includes("frame-ancestors 'none'"), p);
    assert.ok(res.headers.get('strict-transport-security'), `${p}: HSTS`);
    assert.ok(res.headers.get('referrer-policy'), `${p}: Referrer-Policy`);
    assert.equal(res.headers.get('set-cookie'), null, `${p}: no cookie`);
    if (p !== '/updates') assert.ok(!/script-src[^;]*'unsafe-inline'/.test(csp), `${p}: no inline script`);
  }
  const r = await rider('sess');
  const wrongPw = await env.api('POST', '/auth/login', { identifier: r.email, password: 'Wrong#12345' }, null, { 'X-Forwarded-For': '10.50.0.1' });
  const noUser = await env.api('POST', '/auth/login', { identifier: 'nobody.here@coroute.test', password: 'Wrong#12345' }, null, { 'X-Forwarded-For': '10.50.0.2' });
  assert.deepEqual([wrongPw.status, wrongPw.json.error], [noUser.status, noUser.json.error], 'no account enumeration');
  assert.equal(wrongPw.headers.get('set-cookie'), null);
  let last;
  for (let i = 0; i < 11; i++) last = await env.api('POST', '/auth/login', { identifier: 'nobody.here@coroute.test', password: 'x' }, null, { 'X-Forwarded-For': `10.51.0.${i}` });
  assert.equal(last.status, 429, 'failed sign-ins per account are limited (across IPs)');
  const o = await order(r);
  const p = captured(o);
  await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: sign(o.orderId, p) }, r.token, WEB);
  const other = await rider('sessother');
  assert.equal((await env.api('GET', `/web/receipt/${o.orderId}`, null, other.token)).status, 404);
  assert.equal((await env.api('GET', `/web/receipt/${o.orderId}`, null, admin.token)).status, 404, 'an admin uses the admin payments view, not a rider receipt');
  assert.equal((await env.api('GET', `/web/receipt/${o.orderId}`, null, r.token)).status, 200);
});

test('no tokens, signatures or e-mails in server logs during the payment flow', async () => {
  const r = await rider('logs');
  const before = logLines.length;
  const o = await order(r);
  const p = captured(o);
  await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: sign(o.orderId, p) }, r.token, WEB);
  await env.api('POST', '/membership/verify', { orderId: o.orderId, paymentId: p, signature: 'f'.repeat(64) }, r.token, WEB);
  const lines = logLines.slice(before).join('\n');
  assert.ok(!lines.includes(r.token) && !lines.includes(sign(o.orderId, p)) && !lines.includes(r.email), lines.slice(0, 500));
  assert.equal(sec.maskEmail('rider@example.com'), 'r***@example.com');
});

test('website code: tokens only in sessionStorage + Bearer, every server value rendered as text', () => {
  const PUB = path.join(__dirname, '..', 'public');
  const code = (f) => fs.readFileSync(path.join(PUB, f), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  for (const f of ['assets/shop.js', 'assets/plans.js', 'assets/account.js', 'assets/receipt.js', 'assets/signin.js', 'assets/board.js', 'admin/board.js']) {
    const s = code(f);
    assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(s), `${f}: HTML strings`);
    assert.ok(!/localStorage\.setItem\([^)]*token/i.test(s) && !/document\.cookie/.test(s), `${f}: token storage`);
    assert.ok(!/[?&]token=/.test(s), `${f}: token in a URL`);
  }
  assert.ok(code('assets/plans.js').includes('timeout:'), 'Checkout closes itself before the order expires');
});
