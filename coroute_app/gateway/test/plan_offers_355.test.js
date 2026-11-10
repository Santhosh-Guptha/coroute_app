'use strict';
/**
 * 3.56 plan prices: list price (MRP) + an optional offer { priceInr, label, startAt, endAt } per plan.
 * Effective price = offer price inside its window, else the list price; quote and order use it (one
 * computation), coupons apply on top unless the coupon says otherwise, never below the minimum price.
 */
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_offKey';
process.env.RAZORPAY_TEST_KEY_SECRET = 'off_secret_355';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_off_355';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'offadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { setRazorpayFetch } = require('../src/razorpay_gateway');
const pricing = require('../src/plan_pricing');
const { istTime } = require('../src/payment_security');
const { boot } = require('./_helpers');

setRazorpayFetch(async (url, opts = {}) => {
  const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
  if (opts.method === 'POST' && url.endsWith('/orders')) {
    const b = JSON.parse(opts.body);
    return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, status: 'created' });
  }
  return reply(404, {});
});
const sign = (orderId, paymentId) => crypto.createHmac('sha256', 'off_secret_355').update(`${orderId}|${paymentId}`).digest('hex');
const DAY = 86400000;
const WEB = { 'X-CoRoute-Client': 'web' };

const START = istTime('2026-11-20', 'start'); // 20 Nov 00:00 India time
const END = istTime('2026-11-30', 'end'); // until the end of 30 Nov, India time
const PLAN = { id: 'group_large', name: 'Large Group (7–12)', monthlyPriceInr: 99, capacity: 12, billingPeriodDays: 30, offer: { priceInr: 49, label: 'Launch offer', startAt: START, endAt: END } };

test('effective price: the offer inside its window (India time, start inclusive, end exclusive), else the list price', () => {
  assert.equal(START, Date.parse('2026-11-19T18:30:00Z'));
  assert.equal(END, Date.parse('2026-11-30T18:30:00Z'));
  assert.deepEqual(pricing.effectivePrice(PLAN, START - 1), { listPriceInr: 99, priceInr: 99, offer: null });
  assert.equal(pricing.effectivePrice(PLAN, START).priceInr, 49);
  assert.equal(pricing.effectivePrice(PLAN, END - 1).priceInr, 49, '23:59:59.999 on 30 Nov, India time');
  assert.equal(pricing.effectivePrice(PLAN, END).priceInr, 99, 'expired offer falls back to the list price');
  assert.equal(pricing.effectivePrice({ ...PLAN, offer: { ...PLAN.offer, priceInr: 120 } }, START).priceInr, 99, 'an offer at or above the list price is ignored');
  assert.equal(pricing.effectivePrice({ ...PLAN, offer: { priceInr: 49, label: 'Open', startAt: null, endAt: null } }, 1).priceInr, 49, 'open window');
  assert.equal(pricing.effectivePrice({ monthlyPriceInr: 49 }).priceInr, 49, 'old catalogs: monthlyPriceInr is the list price');
  assert.equal(pricing.effectivePrice({ listPriceInr: 79, monthlyPriceInr: 49 }).listPriceInr, 79);
});

test('quote: list price, the offer line, the coupon on the offer price, never below the floor', () => {
  const catalog = { group_large: PLAN };
  const q = pricing.computeQuote({ catalog, planId: 'group_large', coupon: { code: 'RIDE20', discountType: 'percentage', discountValue: 20 }, now: START + DAY });
  assert.deepEqual(q.breakdown.map((l) => [l.label, l.amountInr]), [['Large Group (30 days)', 99], ['Launch offer', -50], ['Coupon RIDE20', -10], ['To pay now', 39]]);
  assert.deepEqual([q.listPriceInr, q.basePriceInr, q.offerDiscountInr, q.couponDiscountInr, q.payableInr], [99, 49, 50, 10, 39]);
  assert.equal(q.offer.label, 'Launch offer');
  assert.match(q.summary, /₹99 − ₹50 Launch offer − ₹10 coupon = ₹39/);
  const after = pricing.computeQuote({ catalog, planId: 'group_large', now: END });
  assert.deepEqual([after.basePriceInr, after.payableInr, after.offer], [99, 99, null]);
  assert.equal(pricing.computeQuote({ catalog, planId: 'group_large', coupon: { code: 'ALL', discountType: 'fixed', discountValue: 999 }, now: START, minPayableInr: 25 }).payableInr, 25);
  const noStack = pricing.checkCoupon({ code: 'SOLO', status: 'ACTIVE', discountType: 'percentage', discountValue: 10, applicableTiers: ['all'], stackWithOffer: false }, { planId: 'group_large', baseInr: 49, offerActive: true });
  assert.equal(noStack.reason, 'NOT_WITH_OFFER');
});

let env;
let A;
before(async () => {
  env = await boot();
  const r = await env.api('POST', '/auth/register', { name: 'Offer Admin', email: 'offadmin@coroute.test', password: 'Password#123', phone: '+919822200000', vehicleType: 'Motorcycle', vehicleNo: 'KA02ZZ9999', emergencyContact: '+919000000001', emergencyContactName: 'Family' });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  A = r.json.token;
});
after(async () => { setRazorpayFetch(null); await env.gw.shutdown(); });

async function putOffer(offer, id = 'group_large', extra = {}) {
  const cat = (await env.api('GET', '/admin/membership/catalog', null, A)).json.catalog;
  return env.api('PUT', '/admin/membership/catalog', { catalog: { [id]: { ...cat[id], ...extra, offer } } }, A);
}

test('admin pricing editor: list price + offer with validation; catalog, quote, order and receipt use the offer', async () => {
  const now = Date.now();
  // Validation (the server checks what the editor checks).
  for (const [offer, field] of [[{ priceInr: 99, label: 'X' }, 'offer.priceInr'], [{ priceInr: 0, label: 'X' }, 'offer.priceInr'], [{ priceInr: 49, label: '' }, 'offer.label'],
    [{ priceInr: 49, label: 'X', startAt: now + 2 * DAY, endAt: now + DAY }, 'offer.window'], [{ priceInr: 49, label: 'X', endAt: now - DAY }, 'offer.window'], [{ priceInr: 49, label: 'X', endAt: 'soon' }, 'offer.window']]) {
    const r = await putOffer(offer);
    assert.equal(r.status, 400, JSON.stringify(offer));
    assert.equal(r.json.field, field, JSON.stringify(r.json));
  }
  const ok = await putOffer({ priceInr: 49, label: 'Launch offer', startAt: now - DAY, endAt: now + 10 * DAY });
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  assert.equal(ok.json.catalog.group_large.listPriceInr, 99);
  const audit = await env.api('GET', '/admin/audit?action=pricing', null, A);
  const e = audit.json.entries.find((x) => x.action === 'pricing.plan_price' && x.target === 'group_large');
  assert.ok(e && e.details.offer.priceInr === 49 && e.details.offerBefore === null, 'audit: what changed');

  // Public catalog: the price now, computed on the server; the stored offer itself is not exposed.
  const cat = await env.api('GET', '/membership/catalog');
  const gl = cat.json.categories.group_large;
  assert.deepEqual([gl.listPriceInr, gl.priceInr, gl.monthlyPriceInr, gl.activeOffer.label, gl.activeOffer.priceInr], [99, 49, 99, 'Launch offer', 49]);
  assert.ok(!('offer' in gl));
  assert.equal(cat.json.categories.group_small.activeOffer, null);

  const r = await env.register('Offer Buyer', 'offer.buyer@coroute.test');
  const q = await env.api('GET', '/membership/quote?plan=group_large', null, r.token, WEB);
  assert.deepEqual([q.json.listPriceInr, q.json.basePriceInr, q.json.payableInr], [99, 49, 49]);
  const qc = await env.api('GET', '/membership/quote?plan=group_large&coupon=WELCOME50', null, r.token, WEB);
  assert.deepEqual([qc.json.couponDiscountInr, qc.json.payableInr], [25, 24], 'coupon on top of the offer price (50% of ₹49, rounded)');
  const o = await env.api('POST', '/membership/order', { category: 'group_large', amount: 1 }, r.token, WEB);
  assert.equal(o.status, 201);
  assert.equal(o.json.amountInPaise, 4900, 'the order charges the offer price');
  const stored = await env.gw.repo.findRazorpayOrder(o.json.orderId);
  assert.deepEqual([stored.listPriceInr, stored.offerPriceInr, stored.offerLabel], [99, 49, 'Launch offer']);
  const pid = `pay_${crypto.randomBytes(5).toString('hex')}`;
  assert.equal((await env.api('POST', '/membership/verify', { orderId: o.json.orderId, paymentId: pid, signature: sign(o.json.orderId, pid) }, r.token, WEB)).status, 200);
  const rc = await env.api('GET', `/web/receipt/${o.json.orderId}`, null, r.token);
  assert.equal(rc.json.receipt.amountInr, 49);
  assert.equal(rc.json.receipt.offerLabel, 'Launch offer');
  assert.equal(rc.json.receipt.listPriceInr, 99);
  assert.ok(rc.json.receipt.lines.some((l) => l.label === 'Launch offer' && l.amountInr === -50));
  const pays = await env.api('GET', '/membership/payments', null, r.token);
  assert.equal(pays.json.payments.find((x) => x.orderId === o.json.orderId).offerLabel, 'Launch offer');

  // A coupon that does not stack with offers is refused while the offer runs (and works without it).
  const code = `NOSTK${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  assert.equal((await env.api('POST', '/admin/coupons', { code, discountType: 'percentage', discountValue: 10, stackWithOffer: false, applicablePlans: ['all'] }, A)).status, 201);
  const r2 = await env.register('Stack Rider', 'stack.rider@coroute.test');
  const ns = await env.api('GET', `/membership/quote?plan=group_large&coupon=${code}`, null, r2.token, WEB);
  assert.equal(ns.json.couponError.reason, 'NOT_WITH_OFFER');
  const ns2 = await env.api('GET', `/membership/quote?plan=group_small&coupon=${code}`, null, r2.token, WEB);
  assert.equal(ns2.json.couponCode, code, 'no offer on Small Group: the coupon applies');

  // An editor that does not send the offer keeps it; null removes it.
  const keep = await env.api('PUT', '/admin/membership/catalog', { catalog: { group_large: { name: 'Large Group (7–12)', monthlyPriceInr: 99 } } }, A);
  assert.equal(keep.json.catalog.group_large.offer.priceInr, 49);
  const off = await putOffer(null);
  assert.equal(off.json.catalog.group_large.offer, null);
  assert.equal((await env.api('GET', '/membership/catalog')).json.categories.group_large.priceInr, 99);
});

test('scheduled and expired offers: not shown before they start; after the end the list price is charged', async () => {
  const now = Date.now();
  assert.equal((await putOffer({ priceInr: 59, label: 'Weekend', startAt: now + DAY, endAt: now + 3 * DAY })).status, 200);
  assert.equal((await env.api('GET', '/membership/catalog')).json.categories.group_large.activeOffer, null);
  // An offer that ended (stored directly: the editor refuses an end in the past).
  const cat = await env.gw.repo.getMembershipCatalog();
  cat.group_large.offer = { priceInr: 49, label: 'Ended', startAt: now - 3 * DAY, endAt: now - 1 };
  await env.gw.repo.setMembershipCatalog(cat, 'test');
  const r = await env.register('Late Rider', 'late.rider@coroute.test');
  const o = await env.api('POST', '/membership/order', { category: 'group_large' }, r.token, WEB);
  assert.equal(o.json.amountInPaise, 9900, 'expired offer falls back to the list price');
  assert.equal(o.json.quote.offer, null);
});

test('migration: a stored catalog without listPriceInr reads its price as the list price', async () => {
  await env.gw.repo.setMembershipCatalog({ group_small: { id: 'group_small', name: 'Small Group (2–6)', monthlyPriceInr: 45, capacity: 6 } }, 'test');
  const c = await env.gw.repo.getMembershipCatalog();
  assert.equal(c.group_small.listPriceInr, 45);
  assert.equal(pricing.effectivePrice(c.group_small).priceInr, 45);
});

test('website plan cards: list price struck through, offer price, label and "until <date>"; home cards too', () => {
  const PUB = path.join(__dirname, '..', 'public');
  const plans = fs.readFileSync(path.join(PUB, 'assets', 'plans.js'), 'utf8');
  for (const s of ["el('s', 'sh-plan__was'", 'sh-plan__offer-label', "'until ' + S.date(p.offer.endsAt - 1)", 'c.activeOffer', 'c.priceInr']) assert.ok(plans.includes(s), s);
  // home.js: run with a catalog that has an offer.
  class El {
    constructor(t) { this.tagName = String(t).toUpperCase(); this.children = []; this.attrs = {}; this._text = ''; this.classList = { _s: new Set(), add: (c) => this.classList._s.add(c), contains: (c) => this.classList._s.has(c) }; }
    set className(v) { String(v).split(/\s+/).filter(Boolean).forEach((c) => this.classList.add(c)); }
    get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
    set textContent(v) { this._text = String(v); this.children = []; }
    appendChild(c) { this.children.push(c); return c; }
    setAttribute(k, v) { this.attrs[k] = String(v); }
    getAttribute(k) { return this.attrs[k] ?? null; }
    removeAttribute(k) { delete this.attrs[k]; }
    addEventListener() {}
    all(pred, out = []) { for (const c of this.children) { if (pred(c)) out.push(c); c.all(pred, out); } return out; }
  }
  const list = new El('div');
  const document = { hidden: false, readyState: 'loading', getElementById: (id) => (id === 'pricing-list' ? list : null), querySelector: () => null, createElement: (t) => new El(t), createElementNS: (ns, t) => new El(t), addEventListener() {} };
  const catalog = { categories: { group_large: { id: 'group_large', name: 'Large Group (7–12)', monthlyPriceInr: 99, listPriceInr: 99, priceInr: 49, activeOffer: { priceInr: 49, label: 'Launch offer', endsAt: END }, capacity: 12, minCapacity: 7, maxCapacity: 12 } } };
  const window = { fetch: async () => ({ ok: true, status: 200, json: async () => catalog }), addEventListener() {}, setInterval() {}, setTimeout() {} };
  new Function('document', 'window', fs.readFileSync(path.join(PUB, 'assets', 'home.js'), 'utf8'))(document, window); // eslint-disable-line no-new-func
  return new Promise((r) => setTimeout(r, 30)).then(() => {
    const card = list.all((e) => e.tagName === 'ARTICLE')[0];
    assert.ok(card, 'card rendered');
    const was = card.all((e) => e.tagName === 'S')[0];
    assert.equal(was.textContent, '₹99');
    assert.equal(card.all((e) => e.classList.contains('px-card__amount'))[0].textContent, '₹49');
    assert.ok(card.textContent.includes('Launch offer'));
  });
});
