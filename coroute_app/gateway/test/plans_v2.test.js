'use strict';
/**
 * Plans v2: Community is free for every rider (solo rides only), Small Group and Large Group are
 * paid; upgrades are prorated (credit for the unused days of the current paid plan), downgrades
 * start when the paid period ends; coupons work on the plans sold today (the "every code is
 * invalid" bug); solo rides refuse the group features with a clear code.
 */
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.MAX_CONVOY_RIDERS = '50';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_plansV2';
process.env.RAZORPAY_TEST_KEY_SECRET = 'plans_v2_secret';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_plans_v2';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { setRazorpayFetch } = require('../src/razorpay_gateway');
const pricing = require('../src/plan_pricing');
const { normalizePlanId, effectiveMembership, planFrom } = require('../src/entitlements');
const { seedDefaultCoupons } = require('../src/subscription_routes');
const { encodeVoice, VOICE_START } = require('../src/ws');
const { boot } = require('./_helpers');

const DAY = 86400000;
const HOUR = 3600000;
const CATALOG = {
  community: { id: 'community', name: 'Community', monthlyPriceInr: 0, capacity: 1, billingPeriodDays: 30, purchasable: false },
  group_small: { id: 'group_small', name: 'Small Group', monthlyPriceInr: 49, capacity: 6, billingPeriodDays: 30 },
  group_large: { id: 'group_large', name: 'Large Group', monthlyPriceInr: 99, capacity: 12, billingPeriodDays: 30 },
};
const NOW = Date.UTC(2026, 10, 6, 6, 0, 0);
const mem = (category, msLeft, extra = {}) => ({
  membershipId: 'mem_x', ownerUserId: 'u1', category, categoryName: CATALOG[category] ? CATALOG[category].name : category,
  capacity: CATALOG[category] ? CATALOG[category].capacity : 1, priceInr: CATALOG[category] ? CATALOG[category].monthlyPriceInr : 9,
  status: 'ACTIVE', validFrom: NOW - DAY, validUntil: NOW + msLeft, ...extra,
});
const quote = (planId, membership, opts = {}) => pricing.computeQuote({ catalog: CATALOG, planId, membership, now: NOW, ...opts });

test('proration: Small -> Large with 19 unused days = ₹99 - ₹31 = ₹68, the new plan starts now for 30 days', () => {
  const q = quote('group_large', mem('group_small', 19 * DAY));
  assert.equal(q.kind, 'upgrade');
  assert.deepEqual([q.basePriceInr, q.unusedDays, q.creditInr, q.couponDiscountInr, q.payableInr], [99, 19, 31, 0, 68]);
  assert.equal(q.summary, 'Large Group ₹99 − ₹31 credit for 19 unused days = ₹68');
  assert.equal(q.startsAt, NOW);
  assert.equal(q.endsAt, NOW + 30 * DAY);
  assert.deepEqual(q.breakdown.map((l) => l.amountInr), [99, -31, 68]);
});

test('proration edges: same-day upgrade, last day, Community -> paid, early renewal', () => {
  // Bought an hour ago: all 30 days are unused (₹49 credit).
  const sameDay = quote('group_large', mem('group_small', 30 * DAY - HOUR));
  assert.deepEqual([sameDay.unusedDays, sameDay.creditInr, sameDay.payableInr], [30, 49, 50]);
  // The last few hours: nothing left to credit.
  const lastDay = quote('group_large', mem('group_small', 3 * HOUR));
  assert.deepEqual([lastDay.unusedDays, lastDay.creditInr, lastDay.payableInr], [0, 0, 99]);
  // 13 hours left rounds to one day: round(49 / 30) = ₹2.
  assert.equal(quote('group_large', mem('group_small', 13 * HOUR)).creditInr, 2);
  // Community (no paid plan): the full price, starting now.
  const fresh = quote('group_small', null);
  assert.deepEqual([fresh.kind, fresh.creditInr, fresh.payableInr, fresh.endsAt - fresh.startsAt], ['new', 0, 49, 30 * DAY]);
  assert.equal(fresh.summary, 'Small Group ₹49 = ₹49');
  // An ended plan gives no credit.
  assert.equal(quote('group_large', mem('group_small', -HOUR)).creditInr, 0);
  // Renewing early: ₹49 - credit for the 10 days left (₹16) = ₹33, a fresh 30 days from now.
  const renew = quote('group_small', mem('group_small', 10 * DAY));
  assert.deepEqual([renew.kind, renew.creditInr, renew.payableInr, renew.endsAt], ['renewal', 16, 33, NOW + 30 * DAY]);
  // The legacy ₹9 Individual still credits its unused days: round(15 x 9 / 30) = ₹5 (rounded half up).
  const legacy = quote('group_small', mem('individual', 15 * DAY, { capacity: 1, priceInr: 9 }));
  assert.deepEqual([legacy.kind, legacy.creditInr, legacy.payableInr], ['upgrade', 5, 44]);
});

test('proration: coupon first (on the list price), then the credit; credit above the price adds days', () => {
  const welcome = { code: 'WELCOME50', discountType: 'percentage', discountValue: 50 };
  const q = quote('group_large', mem('group_small', 19 * DAY), { coupon: welcome });
  assert.deepEqual([q.couponDiscountInr, q.creditInr, q.payableInr], [50, 31, 18]);
  assert.equal(q.summary, 'Large Group ₹99 − ₹50 coupon − ₹31 credit for 19 unused days = ₹18');
  assert.deepEqual(q.breakdown.map((l) => l.amountInr), [99, -50, -31, 18]);
  // Credit larger than what is left to pay: payable 0 and the rest becomes whole days.
  const big = quote('group_small', mem('group_large', 25 * DAY));
  // credit round(25 x 99 / 30) = 83 > 49: pay 0, leftover 34 / (49 / 30) = 20.8 -> 20 extra days.
  assert.deepEqual([big.kind, big.creditAvailableInr, big.creditInr, big.payableInr, big.isFree], ['downgrade', 0, 0, 49, false]);
  const stacked = quote('group_large', mem('group_large', 60 * DAY));
  assert.deepEqual([stacked.kind, stacked.creditAvailableInr, stacked.creditInr, stacked.payableInr, stacked.extraDays], ['renewal', 198, 99, 0, 30]);
  assert.equal(stacked.endsAt, NOW + 60 * DAY);
  // A coupon and credit together never go below zero.
  const both = quote('group_large', mem('group_large', 29 * DAY), { coupon: { code: 'X', discountType: 'fixed', discountValue: 90 } });
  assert.equal(both.payableInr, 0);
  assert.ok(both.extraDays > 0);
  // A period paid with a 100% coupon earns no credit.
  assert.equal(quote('group_large', mem('group_small', 20 * DAY, { creditBasisInr: 0 })).creditInr, 0);
});

test('downgrade: no credit or refund, starts when the current paid period ends; scheduled change reads right', () => {
  const cur = mem('group_large', 12 * DAY);
  const q = quote('group_small', cur);
  assert.equal(q.kind, 'downgrade');
  assert.deepEqual([q.creditInr, q.payableInr, q.startsAt, q.endsAt], [0, 49, NOW + 12 * DAY, NOW + 42 * DAY]);
  assert.ok(q.notes[0].startsWith('Starts when your Large Group ends'));
  // The stored document after the downgrade: Large until the switch, then Small.
  const doc = { ...cur, validUntil: q.endsAt, scheduledChange: { category: 'group_small', categoryName: 'Small Group', capacity: 6, priceInr: 49, creditBasisInr: 49, billingPeriodDays: 30, startsAt: q.startsAt, endsAt: q.endsAt } };
  const before = effectiveMembership(doc, NOW);
  assert.deepEqual([before.category, before.validUntil], ['group_large', NOW + 12 * DAY]);
  const after = effectiveMembership(doc, NOW + 13 * DAY);
  assert.deepEqual([after.category, after.capacity, after.validUntil, after.scheduledChange], ['group_small', 6, NOW + 42 * DAY, null]);
  assert.deepEqual([planFrom({ membership: doc, now: NOW }).seats, planFrom({ membership: doc, now: NOW + 13 * DAY }).seats], [12, 6]);
  assert.equal(planFrom({ membership: doc, now: NOW }).nextPlan.category, 'group_small');
  // Upgrading again before the switch credits the unused Large days and the prepaid Small period.
  const back = quote('group_large', doc);
  assert.deepEqual([back.kind, back.creditAvailableInr], ['renewal', Math.round((12 * 99) / 30 + 49)]);
});

test('plan changes (3.55): only a bigger plan while a paid plan runs; any plan once it ends', () => {
  assert.deepEqual(pricing.PLAN_ORDER, ['community', 'individual', 'group_small', 'group_large']);
  const block = (planId, m) => pricing.changeBlock({ membership: m, planId, now: NOW });
  // Mid-period downgrade and same tier are refused with one clear code.
  const down = block('group_small', mem('group_large', 12 * DAY));
  assert.deepEqual([down.status, down.reason, down.code, down.currentPlan], [409, 'DOWNGRADE_NOT_ALLOWED', 'DOWNGRADE_NOT_ALLOWED', 'group_large']);
  assert.equal(down.error, pricing.DOWNGRADE_MESSAGE);
  assert.equal(block('group_large', mem('group_large', 12 * DAY)).reason, 'DOWNGRADE_NOT_ALLOWED');
  assert.equal(block('group_small', mem('group_small', 3 * DAY)).reason, 'DOWNGRADE_NOT_ALLOWED');
  // Upgrades are allowed (also from the retired Individual).
  assert.equal(block('group_large', mem('group_small', 12 * DAY)), null);
  assert.equal(block('group_small', mem('individual', 12 * DAY, { capacity: 1, priceInr: 9 })), null);
  // No paid plan, or it has ended: anything goes.
  assert.equal(block('group_small', null), null);
  assert.equal(block('group_small', mem('group_large', -HOUR)), null);
  assert.equal(block('group_small', mem('group_large', 5 * DAY, { status: 'CANCELLED' })), null);
});

test('upgrade credit is capped at the new price (after the coupon); nothing is carried over', () => {
  // A Small period bought at an old, higher price (₹120): credit round(30 x 120 / 30) = 120 > ₹99.
  const dear = quote('group_large', mem('group_small', 30 * DAY - HOUR, { priceInr: 120 }));
  assert.equal(dear.kind, 'upgrade');
  assert.deepEqual([dear.creditAvailableInr, dear.creditInr, dear.payableInr, dear.extraDays], [120, 99, 0, 0]);
  assert.equal(dear.endsAt, NOW + 30 * DAY, 'a normal period, no extra days');
  assert.ok(dear.creditInr <= dear.basePriceInr);
  // Coupons still apply to upgrades: 60% off ₹99 = ₹59 off, ₹40 left; credit ₹49 is capped at ₹40.
  const coupon = { code: 'UP60', discountType: 'percentage', discountValue: 60 };
  const c = quote('group_large', mem('group_small', 30 * DAY - HOUR), { coupon });
  assert.deepEqual([c.couponDiscountInr, c.creditAvailableInr, c.creditInr, c.payableInr, c.extraDays], [59, 49, 40, 0, 0]);
  assert.equal(c.couponCode, 'UP60');
});

test('coupon rules: plan ids in any spelling, retired Individual binding, minimum order, first purchase', () => {
  assert.deepEqual(['Group_Small ', 'small group', 'GROUP-LARGE', 'individual', 'roadCaptain', 'all', ''].map(normalizePlanId), ['group_small', 'group_small', 'group_large', 'group_small', null, 'all', null]);
  const base = { code: 'C', status: 'ACTIVE', discountType: 'percentage', discountValue: 50, maxUsagePerUser: 1, usages: [] };
  assert.equal(pricing.checkCoupon({ ...base, applicableTiers: ['GROUP_SMALL'] }, { uid: 'u', planId: 'group_small', baseInr: 49 }).ok, true);
  assert.equal(pricing.checkCoupon({ ...base, applicableTiers: ['individual'] }, { uid: 'u', planId: 'group_small', baseInr: 49 }).ok, true, 'a coupon made for the ₹9 plan works on its successor');
  assert.equal(pricing.checkCoupon({ ...base, applicableTiers: ['roadCaptain'] }, { uid: 'u', planId: 'group_large', baseInr: 99 }).reason, 'TIER_MISMATCH');
  assert.equal(pricing.checkCoupon({ ...base, minOrderAmount: 100 }, { uid: 'u', planId: 'group_large', baseInr: 99 }).reason, 'MIN_ORDER_NOT_MET');
  const freeMonthOnly = { paymentHistory: [{ status: 'PAID', isFree: true, amountInr: 0 }] };
  const paidBefore = { paymentHistory: [{ status: 'PAID', isFree: false, amountInr: 49 }] };
  assert.equal(pricing.checkCoupon({ ...base, newMembersOnly: true }, { uid: 'u', userDoc: freeMonthOnly, planId: 'group_small', baseInr: 49 }).ok, true);
  assert.equal(pricing.checkCoupon({ ...base, newMembersOnly: true }, { uid: 'u', userDoc: paidBefore, planId: 'group_small', baseInr: 49 }).reason, 'NEW_MEMBERS_ONLY');
  assert.equal(pricing.checkCoupon({ ...base, status: 'EXPIRED' }, { uid: 'u', planId: 'group_small', baseInr: 49 }).reason, 'COUPON_EXPIRED');
  assert.equal(pricing.couponDiscountInr({ discountType: 'percentage', discountValue: 50, maxDiscountCap: 30 }, 99), 30);
  assert.equal(pricing.couponDiscountInr({ discountType: 'fixed', discountValue: 500 }, 49), 49);
});

setRazorpayFetch(async (url, opts = {}) => {
  const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
  if (opts.method === 'POST' && url.endsWith('/orders')) {
    const b = JSON.parse(opts.body);
    return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, receipt: b.receipt, status: 'created' });
  }
  return reply(404, {});
});
const sign = (orderId, paymentId) => crypto.createHmac('sha256', 'plans_v2_secret').update(`${orderId}|${paymentId}`).digest('hex');

test('plans v2 over HTTP and WebSocket', async (t) => {
  const env = await boot();
  t.after(() => { setRazorpayFetch(null); env.gw.shutdown(); });
  const repo = env.gw.repo;
  const admin = await env.register('Plans Admin', 'admin@coroute.test');
  const pay = async (token, category, offerCode) => {
    const o = await env.api('POST', '/membership/order', { category, ...(offerCode ? { offerCode } : {}) }, token);
    if (o.status !== 201 || o.json.isFree) return o;
    const paymentId = `pay_${crypto.randomBytes(5).toString('hex')}`;
    const v = await env.api('POST', '/membership/verify', { orderId: o.json.orderId, paymentId, signature: sign(o.json.orderId, paymentId) }, token);
    assert.equal(v.status, 200, JSON.stringify(v.json));
    return o;
  };

  await t.test('coupon bug: the seeded WELCOME50 and RIDERFREE apply to the plans sold today; Pay never depends on a code', async () => {
    const r = await env.register('Coupon Rider', 'coupon.rider@coroute.test');
    const v = await env.api('POST', '/membership/validate-coupon', { code: ' welcome50 ', category: 'group_small' }, r.token);
    assert.equal(v.status, 200, JSON.stringify(v.json));
    assert.deepEqual([v.json.discountAmount, v.json.finalAmount, v.json.quote.payableInr], [25, 24, 24]);
    const large = await env.api('POST', '/membership/validate-coupon', { code: 'WELCOME50', category: 'group_large' }, r.token);
    assert.equal(large.status, 200, 'no ₹100 minimum any more');
    const free = await env.api('GET', '/membership/quote?plan=group_large&coupon=riderfree', null, r.token);
    assert.equal(free.status, 200);
    assert.deepEqual([free.json.couponDiscountInr, free.json.payableInr, free.json.couponError], [99, 0, null]);
    // A wrong code never blocks the price: the quote is the full price with the reason.
    const bad = await env.api('GET', '/membership/quote?plan=group_small&coupon=NOPE', null, r.token);
    assert.equal(bad.status, 200);
    assert.deepEqual([bad.json.payableInr, bad.json.couponError.reason], [49, 'COUPON_NOT_FOUND']);
    // The order charges the quote, whatever amount a client sends.
    const o = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: 'WELCOME50', amount: 1 }, r.token);
    assert.equal(o.status, 201, JSON.stringify(o.json));
    assert.equal(o.json.amountInr, 24);
    assert.equal(o.json.quote.couponDiscountInr, 25);
    // Closing the payment page and trying again with the same code is not refused by the first hold.
    const again = await env.api('POST', '/membership/order', { category: 'group_small', offerCode: 'WELCOME50' }, r.token);
    assert.equal(again.status, 201, JSON.stringify(again.json));
    assert.equal(again.json.amountInr, 24);
  });

  await t.test('old-shape launch coupons are fixed once at boot: WELCOME50 without the ₹100 minimum, RIDERFREE rebound', async () => {
    const t0 = Date.now();
    await repo.saveCoupon({ code: 'WELCOME50', discountType: 'percentage', discountValue: 50, applicableTiers: ['all'], minOrderAmount: 100, maxUsageTotal: 1000, maxUsagePerUser: 1, validFrom: t0 - 200 * DAY, expiresAt: t0 - DAY, createdBy: 'seed', usageCount: 3, usages: [{ userId: 'old', orderId: 'o1' }] });
    await repo.saveCoupon({ code: 'RIDERFREE', discountType: 'free', discountValue: 100, applicableTiers: ['individual', 'group_small', 'group_large'], applicableCycles: ['monthly'], minOrderAmount: 0, maxUsageTotal: 100, maxUsagePerUser: 1, validFrom: t0 - DAY, expiresAt: t0 + 100 * DAY, createdBy: 'seed' });
    assert.deepEqual((await seedDefaultCoupons(repo)).sort(), ['RIDERFREE', 'WELCOME50']);
    const w = await repo.findCoupon('WELCOME50');
    assert.deepEqual([w.status, w.minOrderAmount, w.newMembersOnly, w.usageCount, w.applicableTiers], ['ACTIVE', 0, true, 3, ['group_small', 'group_large']]);
    const f = await repo.findCoupon('RIDERFREE');
    assert.deepEqual([f.status, f.applicableTiers], ['ACTIVE', ['group_small', 'group_large']]);
    assert.deepEqual(await seedDefaultCoupons(repo), [], 'fixed once; later admin edits stick');
  });

  await t.test('plans that cannot be bought: Community (free) and the retired Individual (410)', async () => {
    const r = await env.register('Plan Picker', 'plan.picker@coroute.test');
    const c = await env.api('GET', '/membership/quote?plan=community', null, r.token);
    assert.deepEqual([c.status, c.json.reason], [400, 'FREE_PLAN']);
    for (const path of ['/membership/quote?plan=individual']) {
      const res = await env.api('GET', path, null, r.token);
      assert.deepEqual([res.status, res.json.reason], [410, 'LEGACY_PLAN']);
    }
    const o = await env.api('POST', '/membership/order', { category: 'individual' }, r.token);
    assert.deepEqual([o.status, o.json.reason], [410, 'LEGACY_PLAN']);
    const af = await env.api('POST', '/membership/activate-free', { category: 'individual', couponCode: 'RIDERFREE' }, r.token);
    assert.equal(af.status, 410);
  });

  await t.test('an active Individual purchase is honoured until it ends, then the rider is Community', async () => {
    const r = await env.register('Legacy Solo', 'legacy.solo@coroute.test');
    const until = Date.now() + 5 * DAY;
    await repo.saveMembership({ membershipId: `mem_${r.user.userId}`, ownerUserId: r.user.userId, category: 'individual', categoryName: 'Individual', capacity: 1, priceInr: 9, status: 'ACTIVE', validFrom: Date.now() - DAY, validUntil: until, members: {} });
    const my = await env.api('GET', '/membership/my', null, r.token);
    assert.deepEqual([my.json.plan.source, my.json.plan.category, my.json.plan.validUntil, my.json.plan.canHostGroup], ['membership', 'individual', until, false]);
    const q = await env.api('GET', '/membership/quote?plan=group_small', null, r.token);
    assert.deepEqual([q.json.kind, q.json.creditInr, q.json.payableInr], ['upgrade', 2, 47]);
    const m = await repo.findMembershipByOwner(r.user.userId);
    m.validUntil = Date.now() - 1000;
    await repo.saveMembership(m);
    const later = await env.api('GET', '/membership/my', null, r.token);
    assert.deepEqual([later.json.plan.source, later.json.plan.seats], ['community', 1]);
  });

  await t.test('upgrade Small -> Large charges the prorated amount; downgrade is scheduled; credit covering it all needs no payment', async () => {
    const r = await env.register('Upgrader', 'upgrader@coroute.test');
    await pay(r.token, 'group_small');
    // 19 days used up of the 30.
    const m = await repo.findMembershipByOwner(r.user.userId);
    m.validUntil = Date.now() + 11 * DAY;
    await repo.saveMembership(m);
    const q = await env.api('GET', '/membership/quote?plan=group_large', null, r.token);
    assert.deepEqual([q.json.kind, q.json.unusedDays, q.json.creditInr, q.json.payableInr], ['upgrade', 11, 18, 81]);
    assert.equal(q.json.summary, 'Large Group ₹99 − ₹18 credit for 11 unused days = ₹81');
    const o = await pay(r.token, 'group_large');
    assert.equal(o.json.amountInr, 81, 'the order is the quote');
    const my = await env.api('GET', '/membership/my', null, r.token);
    assert.equal(my.json.plan.category, 'group_large');
    assert.ok(Math.abs(my.json.plan.validUntil - (Date.now() + 30 * DAY)) < 60000, 'a full period from now');

    // 3.55: no downgrade while Large runs (quote, coupon check, order and free activation refuse it).
    const d = await env.api('GET', '/membership/quote?plan=group_small', null, r.token);
    assert.deepEqual([d.status, d.json.reason], [409, 'DOWNGRADE_NOT_ALLOWED']);
    assert.equal(d.json.error, 'You can move to a bigger plan anytime. Smaller plans can be chosen when your current plan ends.');
    const dOrder = await env.api('POST', '/membership/order', { category: 'group_small' }, r.token);
    assert.deepEqual([dOrder.status, dOrder.json.code], [409, 'DOWNGRADE_NOT_ALLOWED']);
    const dCoupon = await env.api('POST', '/membership/validate-coupon', { code: 'WELCOME50', category: 'group_small' }, r.token);
    assert.deepEqual([dCoupon.status, dCoupon.json.valid, dCoupon.json.reason], [409, false, 'DOWNGRADE_NOT_ALLOWED']);
    const dFree = await env.api('POST', '/membership/activate-free', { category: 'group_small', couponCode: 'RIDERFREE' }, r.token);
    assert.deepEqual([dFree.status, dFree.json.reason], [409, 'DOWNGRADE_NOT_ALLOWED']);
    const after = await env.api('GET', '/membership/my', null, r.token);
    assert.deepEqual([after.json.plan.category, after.json.plan.seats], ['group_large', 12]);

    // The same plan again: a repeat tap with nothing to pay is "already active"; paying again is refused.
    const same = await env.api('GET', '/membership/quote?plan=group_large', null, r.token);
    assert.deepEqual([same.status, same.json.reason], [409, 'DOWNGRADE_NOT_ALLOWED']);
    const sameTap = await env.api('POST', '/membership/order', { category: 'group_large' }, r.token);
    assert.deepEqual([sameTap.status, sameTap.json.isAlreadyActive], [200, true], 'credit covers it: nothing bought');
    const m1 = await repo.findMembershipByOwner(r.user.userId);
    m1.validUntil = Date.now() + 5 * DAY;
    await repo.saveMembership(m1);
    const sameOrder = await env.api('POST', '/membership/order', { category: 'group_large' }, r.token);
    assert.deepEqual([sameOrder.status, sameOrder.json.reason], [409, 'DOWNGRADE_NOT_ALLOWED']);

    // After the plan ends, any plan can be chosen (Small at full price).
    const m2 = await repo.findMembershipByOwner(r.user.userId);
    m2.validUntil = Date.now() - 1000;
    await repo.saveMembership(m2);
    const ended = await env.api('GET', '/membership/quote?plan=group_small', null, r.token);
    assert.deepEqual([ended.status, ended.json.kind, ended.json.payableInr], [200, 'new', 49]);
    await pay(r.token, 'group_small');
    const small = await env.api('GET', '/membership/my', null, r.token);
    assert.equal(small.json.plan.category, 'group_small');
  });

  await t.test('admin "Change plan" is exempt: an admin may move a rider to a smaller plan mid-period', async () => {
    const r = await env.register('Admin Moved', 'admin.moved@coroute.test');
    await pay(r.token, 'group_large');
    const refused = await env.api('POST', '/membership/order', { category: 'group_small' }, r.token);
    assert.equal(refused.status, 409);
    const g = await env.api('POST', `/admin/subscription/users/${r.user.userId}/grant`, { planTier: 'group_small', days: 30, reason: 'club request' }, admin.token);
    assert.equal(g.status, 200, JSON.stringify(g.json));
    const my = await env.api('GET', '/membership/my', null, r.token);
    assert.deepEqual([my.json.plan.category, my.json.plan.seats], ['group_small', 6]);
  });

  await t.test('Community rides solo: nobody joins, talk / messages / regroup / roles refused with SOLO_RIDE; a group ride gives every rider the group features', async () => {
    const host = await env.register('Solo Host', 'solo.host2@coroute.test');
    const other = await env.register('Would Join', 'would.join@coroute.test');
    const ride = await env.api('POST', '/convoys', { name: 'Just me' }, host.token);
    assert.equal(ride.status, 201, JSON.stringify(ride.json));
    assert.deepEqual([ride.json.capacity, ride.json.soloRide], [1, true]);
    const j = await env.api('POST', '/convoys/join', { code: ride.json.joinCode }, other.token);
    assert.deepEqual([j.status, j.json.code], [409, 'SOLO_TRIP_ONLY']);
    const ws = await env.joinRoom(host.token, ride.json.groupId);
    assert.equal(ws.snapshot.soloRide, true);
    for (const msg of [{ type: 'CHAT', text: 'hello' }, { type: 'REGROUP_SET', lat: 17.4, lng: 78.4 }, { type: 'WAIT' }, { type: 'MIC_STATE', muted: false }]) {
      ws.sendJson(msg);
      const err = await ws.next((m) => m.type === 'ERROR');
      assert.equal(err.reason, 'SOLO_RIDE', msg.type);
      assert.equal(err.code, 403);
    }
    ws.send(encodeVoice(VOICE_START, { sampleRate: 16000, codec: 'pcm16' }));
    assert.equal((await ws.next((m) => m.type === 'ERROR')).reason, 'SOLO_RIDE');
    // Safety is never gated: a status update still works.
    ws.sendJson({ type: 'STATUS', status: 'STOPPED', reason: 'Fuel' });
    ws.close();
    assert.equal((await env.api('POST', `/convoys/${ride.json.groupId}/status`, { status: 'ENDED' }, host.token)).status, 200);

    // A Small Group host: the Community rider joins for free and can talk and message.
    const groupHost = await env.register('Group Host', 'group.host2@coroute.test');
    await pay(groupHost.token, 'group_small');
    const g = await env.api('POST', '/convoys', { name: 'Pack' }, groupHost.token);
    assert.deepEqual([g.json.capacity, g.json.soloRide], [6, false]);
    assert.equal((await env.api('POST', '/convoys/join', { code: g.json.joinCode }, other.token)).status, 200);
    const w2 = await env.joinRoom(other.token, g.json.groupId);
    w2.sendJson({ type: 'CHAT', text: 'on my way' });
    const echo = await w2.next((m) => m.type === 'MESSAGE' || m.type === 'ERROR');
    assert.equal(echo.type, 'MESSAGE', JSON.stringify(echo));
    const my = await env.api('GET', '/membership/my', null, other.token);
    assert.equal(my.json.plan.source, 'community');
    w2.close();
    assert.equal((await env.api('POST', `/convoys/${g.json.groupId}/status`, { status: 'ENDED' }, groupHost.token)).status, 200);
  });

  await t.test('admin: Community is listed (free, not sold), only its description and features change; coupon plans are the paid plans', async () => {
    const cat = await env.api('GET', '/admin/membership/catalog', null, admin.token);
    assert.deepEqual(Object.keys(cat.json.catalog), ['community', 'group_small', 'group_large']);
    const c = cat.json.catalog;
    c.community = { ...c.community, monthlyPriceInr: 10, features: ['Solo rides', 'Safety for everyone'] };
    c.individual = { name: 'Individual', monthlyPriceInr: 9 }; // an older admin build sends it back
    const put = await env.api('PUT', '/admin/membership/catalog', { catalog: c }, admin.token);
    assert.equal(put.status, 200, JSON.stringify(put.json));
    const after = await repo.getMembershipCatalog();
    assert.deepEqual([after.community.monthlyPriceInr, after.community.features, after.individual], [0, ['Solo rides', 'Safety for everyone'], undefined]);
    const opts = await env.api('GET', '/admin/coupons/plan-options', null, admin.token);
    assert.deepEqual(opts.json.plans.map((p) => p.id), ['group_small', 'group_large']);
  });
});
