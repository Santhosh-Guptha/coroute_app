'use strict';
/**
 * The launch coupons (WELCOME50, CAPTAIN100, RIDERFREE) are ordinary coupon records: seeded once,
 * admin-managed, bound to plans, limited in total and to one redemption per rider, with a fixed
 * validity window. /membership/purchase obeys the same rules and never re-credits a payment. The
 * admin payment history prices orders from the stored catalog, not from hard-coded amounts.
 */
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_recKey';
process.env.RAZORPAY_TEST_KEY_SECRET = 'rec_secret_123';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_rec_123';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { setRazorpayFetch } = require('../src/razorpay_gateway');
const { seedDefaultCoupons, DEFAULT_COUPONS } = require('../src/subscription_routes');
const { boot } = require('./_helpers');

setRazorpayFetch(async (url, opts = {}) => {
  const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
  if (opts.method === 'POST' && url.endsWith('/orders')) {
    const b = JSON.parse(opts.body);
    return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, receipt: b.receipt, status: 'created' });
  }
  return reply(404, {});
});
const sign = (orderId, paymentId) => crypto.createHmac('sha256', 'rec_secret_123').update(`${orderId}|${paymentId}`).digest('hex');
const DAY = 86400000;

test('launch coupons are admin-managed records with plan binding, limits and validity', async (t) => {
  const env = await boot();
  t.after(() => { setRazorpayFetch(null); env.gw.shutdown(); });
  const repo = env.gw.repo;
  const admin = await env.register('Coupon Admin', 'admin@coroute.test');
  const A = admin.token;

  await t.test('seeded once into the coupon store, each bound, limited and with a real end date', async () => {
    const list = await env.api('GET', '/admin/coupons', null, A);
    assert.equal(list.status, 200);
    for (const d of DEFAULT_COUPONS) {
      const c = list.json.coupons.find((x) => x.code === d.code);
      assert.ok(c, `${d.code} is a stored record`);
      assert.equal(c.status, 'ACTIVE');
      assert.equal(c.maxUsagePerUser, 1);
      assert.equal(c.maxUsageTotal, d.maxUsageTotal);
      assert.deepEqual(c.applicableTiers, d.applicableTiers);
      assert.equal(c.createdBy, 'seed');
      assert.ok(c.expiresAt > Date.now() && c.expiresAt <= Date.now() + d.validDays * DAY, `${d.code} expires`);
    }
    const free = list.json.coupons.find((x) => x.code === 'RIDERFREE');
    assert.ok(!free.applicableTiers.includes('all'), 'RIDERFREE is bound to named plans, not any plan');
  });

  await t.test('re-seeding never overwrites an admin edit nor resurrects an archived coupon', async () => {
    const patched = await env.api('PATCH', '/admin/coupons/WELCOME50', { maxUsageTotal: 7 }, A);
    assert.equal(patched.status, 200);
    assert.equal((await env.api('DELETE', '/admin/coupons/CAPTAIN100', null, A)).status, 200);
    assert.deepEqual(await seedDefaultCoupons(repo), []);
    assert.equal((await repo.findCoupon('WELCOME50')).maxUsageTotal, 7);
    assert.equal((await repo.findCoupon('CAPTAIN100')).status, 'ARCHIVED');
    const archived = await env.api('POST', '/subscription/validate-coupon', { code: 'CAPTAIN100', planTier: 'roadCaptain', billingCycle: 'monthly', amount: 599 });
    assert.equal(archived.status, 400);
    assert.equal(archived.json.valid, false);
  });

  await t.test('a store without the record knows no such coupon (no built-in fallback)', async () => {
    const fresh = { findCoupon: async () => null };
    const { resolveCoupon } = require('../src/subscription_routes');
    assert.equal(await resolveCoupon('RIDERFREE', fresh), null);
    assert.equal(await resolveCoupon('WELCOME50', null), null);
  });

  await t.test('subscription: RIDERFREE activates once per rider, then is refused', async () => {
    const r = await env.register('Sub Rider', 'sub.rider@coroute.test');
    const first = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly', couponCode: 'RIDERFREE' }, r.token);
    assert.equal(first.status, 200, JSON.stringify(first.json));
    assert.equal(first.json.isFree, true);
    const ok = await env.api('POST', '/subscription/verify-payment', { orderId: first.json.orderId }, r.token);
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
    const used = await repo.findCoupon('RIDERFREE');
    assert.equal(used.usageCount, 1);
    const again = await env.api('POST', '/subscription/create-order', { planTier: 'roadCaptain', billingCycle: 'monthly', couponCode: 'RIDERFREE' }, r.token);
    assert.equal(again.status, 400);
    assert.equal(again.json.reason, 'PER_USER_LIMIT_REACHED');
    // Two free orders quoted before either is settled: only the first settles.
    const r3 = await env.register('Sub Rider Three', 'sub.rider3@coroute.test');
    const q1 = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly', couponCode: 'RIDERFREE' }, r3.token);
    const q2 = await env.api('POST', '/subscription/create-order', { planTier: 'roadCaptain', billingCycle: 'monthly', couponCode: 'RIDERFREE' }, r3.token);
    assert.equal(q1.status, 200);
    assert.equal(q2.status, 200);
    assert.equal((await env.api('POST', '/subscription/verify-payment', { orderId: q1.json.orderId }, r3.token)).status, 200);
    const second = await env.api('POST', '/subscription/verify-payment', { orderId: q2.json.orderId }, r3.token);
    assert.equal(second.status, 400);
    assert.equal(second.json.reason, 'PER_USER_LIMIT_REACHED');
    assert.equal((await repo.findCoupon('RIDERFREE')).usageCount, 2);
    // Settling the first again is idempotent (no third usage).
    assert.equal((await env.api('POST', '/subscription/verify-payment', { orderId: q1.json.orderId }, r3.token)).status, 200);
    assert.equal((await repo.findCoupon('RIDERFREE')).usageCount, 2);
    // Annual is outside the binding.
    const r2 = await env.register('Sub Rider Two', 'sub.rider2@coroute.test');
    const annual = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'annual', couponCode: 'RIDERFREE' }, r2.token);
    assert.equal(annual.status, 400);
    assert.equal(annual.json.reason, 'CYCLE_MISMATCH');
  });

  await t.test('membership: RIDERFREE via /membership/purchase is counted, not reusable, and bound to its plans', async () => {
    const r = await env.register('Mem Rider', 'mem.rider@coroute.test');
    const first = await env.api('POST', '/membership/purchase', { category: 'individual', offerCode: 'RIDERFREE' }, r.token);
    assert.equal(first.status, 201, JSON.stringify(first.json));
    assert.equal(first.json.membership.offerApplied, 'RIDERFREE');
    const until = first.json.membership.validUntil;
    // Repeat for the same plan: no extra month, no second redemption.
    const repeat = await env.api('POST', '/membership/purchase', { category: 'individual', offerCode: 'RIDERFREE' }, r.token);
    assert.equal(repeat.status, 200);
    assert.equal(repeat.json.isAlreadyActive, true);
    assert.equal(repeat.json.membership.validUntil, until);
    // Another plan with the same code: refused (once per rider).
    const other = await env.api('POST', '/membership/purchase', { category: 'group_small', offerCode: 'RIDERFREE' }, r.token);
    assert.equal(other.status, 400);
    assert.equal(other.json.reason, 'PER_USER_LIMIT_REACHED');
    const rows = await repo.listCouponRedemptions({ couponCode: 'RIDERFREE', userId: r.user.userId });
    assert.equal(rows.length, 1);
    // An unknown code is refused, never silently ignored.
    const unknown = await env.api('POST', '/membership/purchase', { category: 'group_small', offerCode: 'NOPE123' }, r.token);
    assert.equal(unknown.status, 404);

    // A plan added later is not covered by the binding.
    const catalog = await repo.getMembershipCatalog();
    catalog.club_xl = { id: 'club_xl', name: 'Club XL', monthlyPriceInr: 199, capacity: 20, billingPeriodDays: 30 };
    assert.equal((await env.api('PUT', '/admin/membership/catalog', { catalog }, A)).status, 200);
    const r2 = await env.register('Club Rider', 'club.rider@coroute.test');
    const xl = await env.api('POST', '/membership/activate-free', { category: 'club_xl', couponCode: 'RIDERFREE' }, r2.token);
    assert.equal(xl.status, 400);
    assert.equal(xl.json.reason, 'TIER_MISMATCH');
    // A flat ₹100 coupon does not make a ₹199 plan free.
    await env.api('POST', '/admin/coupons', { code: 'FLAT100', discountType: 'fixed', discountValue: 100, applicablePlans: ['club_xl'] }, A);
    const flat = await env.api('POST', '/membership/activate-free', { category: 'club_xl', couponCode: 'FLAT100' }, r2.token);
    assert.equal(flat.status, 400);
    assert.equal(flat.json.reason, 'PARTIAL_COUPON');
    const quote = await env.api('POST', '/membership/validate-coupon', { code: 'FLAT100', category: 'club_xl' }, r2.token);
    assert.equal(quote.json.finalAmount, 99);
    assert.equal(quote.json.isFree, false);
  });

  await t.test('a paused RIDERFREE is refused everywhere', async () => {
    assert.equal((await env.api('POST', '/admin/coupons/RIDERFREE/pause', {}, A)).status, 200);
    const r = await env.register('Late Rider', 'late.rider@coroute.test');
    const v = await env.api('POST', '/membership/validate-coupon', { code: 'RIDERFREE', category: 'individual' }, r.token);
    assert.equal(v.status, 400);
    const act = await env.api('POST', '/membership/activate-free', { category: 'individual', couponCode: 'RIDERFREE' }, r.token);
    assert.equal(act.status, 400);
    assert.equal(act.json.reason, 'COUPON_PAUSED');
    const sub = await env.api('POST', '/subscription/create-order', { planTier: 'proRider', billingCycle: 'monthly', couponCode: 'RIDERFREE' }, r.token);
    assert.equal(sub.status, 400);
    assert.equal((await env.api('POST', '/admin/coupons/RIDERFREE/resume', {}, A)).status, 200);
  });

  await t.test('/membership/purchase credits a verified payment once, only to its owner and plan', async () => {
    const buyer = await env.register('Paying Rider', 'paying.rider@coroute.test');
    const ord = await env.api('POST', '/membership/order', { category: 'group_small' }, buyer.token);
    assert.equal(ord.status, 201, JSON.stringify(ord.json));
    const payId = 'pay_rec_1';
    const body = { category: 'group_small', orderId: ord.json.orderId, paymentId: payId, signature: sign(ord.json.orderId, payId) };

    const thief = await env.register('Other Rider', 'other.rider@coroute.test');
    const stolen = await env.api('POST', '/membership/purchase', body, thief.token);
    assert.equal(stolen.status, 403);
    const wrongPlan = await env.api('POST', '/membership/purchase', { ...body, category: 'group_large' }, buyer.token);
    assert.equal(wrongPlan.status, 400);
    assert.equal(wrongPlan.json.reason, 'ORDER_PLAN_MISMATCH');
    const forged = await env.api('POST', '/membership/purchase', { ...body, signature: 'f'.repeat(64) }, buyer.token);
    assert.equal(forged.status, 400);
    assert.equal(forged.json.reason, 'INVALID_PAYMENT_SIGNATURE');

    const ok = await env.api('POST', '/membership/purchase', body, buyer.token);
    assert.equal(ok.status, 201, JSON.stringify(ok.json));
    const until = ok.json.membership.validUntil;
    const replay = await env.api('POST', '/membership/purchase', body, buyer.token);
    assert.equal(replay.status, 200);
    assert.equal(replay.json.isAlreadyActive, true);
    const mine = await env.api('GET', '/membership/my', null, buyer.token);
    assert.equal(mine.json.owned.validUntil, until, 'a replayed signature never adds another month');
  });

  await t.test('admin payment history prices orders from the stored catalog', async () => {
    const catalog = await repo.getMembershipCatalog();
    catalog.group_large.monthlyPriceInr = 149;
    catalog.group_large.name = 'Big Convoy';
    assert.equal((await env.api('PUT', '/admin/membership/catalog', { catalog }, A)).status, 200);
    const now = Date.now();
    await repo.saveRazorpayOrder({ orderId: 'order_cat_1', userId: admin.user.userId, category: 'group_large', amountInPaise: 0, isFree: true, status: 'PAID', createdAt: now, paidAt: now });
    await repo.saveRazorpayOrder({ orderId: 'order_sub_1', userId: admin.user.userId, planTier: 'proRider', billingCycle: 'monthly', amountInPaise: 7400, discountAmount: 75, status: 'PAID', createdAt: now, paidAt: now });
    const hist = await env.api('GET', '/admin/payments/history?search=order_&limit=200', null, A);
    assert.equal(hist.status, 200);
    const cat = hist.json.transactions.find((x) => x.orderId === 'order_cat_1');
    assert.equal(cat.originalPrice, 149, 'catalog price, not a hard-coded ₹99');
    assert.equal(cat.categoryName, 'Big Convoy');
    const sub = hist.json.transactions.find((x) => x.orderId === 'order_sub_1');
    assert.equal(sub.originalPrice, 149, 'amount + recorded discount, not the ₹9 individual fallback');
    assert.equal(sub.category, 'proRider');
    const an = await env.api('GET', '/admin/payments/analytics?range=7d', null, A);
    assert.equal(an.status, 200);
    assert.equal(an.json.byPlan.group_large.priceInr, 149);
    assert.equal(an.json.byPlan.club_xl.priceInr, 199);
  });
});
