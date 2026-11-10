'use strict';
/**
 * 3.55 web admin (/admin, src/web_admin.js, docs/features_355/web_admin.md): the page and its assets are
 * served with a strict CSP and noindex, the money / marketing admin APIs it uses refuse rider tokens,
 * the new read-only endpoints (/api/admin/web/config, /api/admin/web/revenue) are admin only and
 * aggregate correctly (staff and test mode left out), and the browser QR encoder matches the reference.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'webadmin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { revenueSummary, monthKeys } = require('../src/web_admin');
const qr = require('../public/admin/qr.js');

let t, admin, rider;
before(async () => {
  t = await boot();
  admin = await t.register('Web Admin', 'webadmin@coroute.test');
  rider = await t.register('Ravi Rider', 'webrider@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

const page = (p) => fetch(t.origin + p, { redirect: 'manual' });

test('/admin is served with a strict CSP, noindex, no-store and no inline script or style', async () => {
  for (const p of ['/admin', '/admin/']) {
    const res = await page(p);
    assert.equal(res.status, 200, p);
    const csp = res.headers.get('content-security-policy');
    assert.match(csp, /default-src 'none'/);
    assert.match(csp, /script-src 'self'(;|$)/);
    assert.match(csp, /style-src 'self'(;|$)/);
    assert.match(csp, /frame-ancestors 'none'/);
    assert.match(csp, /form-action 'none'/);
    assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval|razorpay/);
    assert.match(res.headers.get('x-robots-tag'), /noindex/);
    assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
    assert.match(res.headers.get('cache-control'), /no-store/);
    assert.equal(res.headers.get('x-frame-options'), 'DENY');
    const html = await res.text();
    assert.match(html, /<meta name="robots" content="noindex/);
    // Every script is an external file of ours; no inline handlers or style attributes.
    for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)) {
      assert.match(m[1], /src="\/admin\/[a-z_]+\.js\?v=[0-9a-f]{10}"/);
      assert.equal(m[2].trim(), '');
    }
    assert.doesNotMatch(html, /\son[a-z]+=|style=/i);
    assert.match(html, /\/admin\/admin\.css\?v=[0-9a-f]{10}/);
  }
});

test('admin assets: right types, the same CSP, cached only with the current hash; unknown files 404', async () => {
  const html = await (await page('/admin')).text();
  const js = html.match(/\/admin\/admin\.js\?v=([0-9a-f]{10})/);
  const res = await page(js[0]);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /application\/javascript/);
  assert.match(res.headers.get('cache-control'), /immutable/);
  assert.match(res.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.match(res.headers.get('x-robots-tag'), /noindex/);
  const stale = await page('/admin/admin.js?v=0000000000');
  assert.equal(stale.headers.get('cache-control'), 'no-cache');
  assert.match((await page('/admin/admin.css')).headers.get('content-type'), /text\/css/);
  for (const p of ['/admin/index.html', '/admin/nope.js', '/admin/../src/app.js', '/admin/x/y']) {
    const r = await page(p);
    assert.equal(r.status, 404, p);
  }
  // The site's robots.txt keeps crawlers out too.
  assert.match(await (await page('/robots.txt')).text(), /Disallow: \/admin/);
});

test('the console signs in through the rate-limited login API', async () => {
  const r = await t.api('POST', '/auth/login', { identifier: 'webadmin@coroute.test', password: 'Password#123' });
  assert.equal(r.status, 200);
  assert.equal(r.json.user.role, 'MASTER_ADMIN');
  assert.ok(r.headers.get('ratelimit-policy') || r.headers.get('ratelimit'), 'login answers carry rate limit headers');
});

test('rider tokens are refused on every admin API the web console uses (and without a token: 401)', async () => {
  const calls = [
    ['GET', '/admin/web/config'], ['GET', '/admin/web/revenue'],
    ['GET', '/admin/payments'], ['GET', '/admin/payments/export.csv'], ['GET', '/admin/payments/analytics'], ['POST', '/admin/payments/order_x/refund'],
    ['POST', '/admin/membership/reconcile'], ['GET', '/admin/membership/catalog'], ['PUT', '/admin/membership/catalog'],
    ['GET', '/admin/payment-gateway'], ['PUT', '/admin/payment-gateway'], ['POST', '/admin/payment-gateway/test'], ['GET', '/admin/audit'],
    ['GET', '/admin/coupons'], ['POST', '/admin/coupons'], ['PATCH', '/admin/coupons/X1'], ['POST', '/admin/coupons/X1/pause'], ['GET', '/admin/coupons/usage'], ['GET', '/admin/coupons/plan-options'],
    ['GET', '/admin/marketing/templates'], ['POST', '/admin/marketing/templates'], ['GET', '/admin/marketing/coupons'], ['GET', '/admin/marketing/images'],
  ];
  for (const [m, p] of calls) {
    const r = await t.api(m, p, m === 'GET' ? undefined : {}, rider.token);
    assert.equal(r.status, 403, `${m} ${p} with a rider token`);
    const anon = await t.api(m, p, m === 'GET' ? undefined : {});
    assert.equal(anon.status, 401, `${m} ${p} without a token`);
  }
});

test('GET /api/admin/web/config: public origin, the plans page and who is signed in', async () => {
  const r = await t.api('GET', '/admin/web/config', undefined, admin.token);
  assert.equal(r.status, 200);
  assert.equal(r.json.publicOrigin, 'https://coroute.example');
  assert.equal(r.json.plansUrl, 'https://coroute.example/plans');
  assert.equal(r.json.user.role, 'MASTER_ADMIN');
  assert.equal(r.json.user.email, 'webadmin@coroute.test');
  assert.match(r.headers.get('cache-control'), /no-store/);
});

test('GET /api/admin/web/revenue: net of refunds per day / month, test and staff apart, paid plans, coupons', async () => {
  const repo = t.gw.repo;
  const now = Date.now();
  const DAY = 86400000;
  const order = (id, o) => repo.saveRazorpayOrder({ orderId: id, userId: rider.user.userId, status: 'PAID', mode: 'live', category: 'group_small', amountInPaise: 49900, createdAt: now - DAY, paidAt: now - DAY, ...o });
  await order('order_live1');
  await order('order_live2', { amountInPaise: 99900, category: 'group_large', refundedAmountInPaise: 20000, paidAt: now - 2 * DAY });
  await order('order_test', { mode: 'test', amountInPaise: 50000 });
  await order('order_staff', { userId: admin.user.userId, amountInPaise: 70000 });
  await order('order_failed', { status: 'FAILED' });
  await order('order_old', { amountInPaise: 10000, paidAt: now - 400 * DAY, createdAt: now - 400 * DAY });
  await repo.saveMembership({ membershipId: 'mem_w1', ownerUserId: rider.user.userId, category: 'group_small', status: 'ACTIVE', priceInr: 499, validFrom: now - 5 * DAY, validUntil: now + 25 * DAY });
  await repo.saveMembership({ membershipId: 'mem_w2', ownerUserId: admin.user.userId, category: 'group_large', status: 'ACTIVE', priceInr: 999, validFrom: now - 5 * DAY, validUntil: now + 25 * DAY });
  await repo.saveCouponRedemption({ redemptionId: 'red_w1', couponCode: 'WEB10', userId: rider.user.userId, status: 'SUCCESS', discountAmount: 50, finalAmount: 449, redeemedAt: now - DAY });
  await repo.saveCouponRedemption({ redemptionId: 'red_w2', couponCode: 'WEB10', userId: admin.user.userId, status: 'SUCCESS', discountAmount: 50, finalAmount: 449, redeemedAt: now - DAY });

  const r = await t.api('GET', '/admin/web/revenue?days=30&months=12', undefined, admin.token);
  assert.equal(r.status, 200);
  const j = r.json;
  assert.equal(j.excludesStaff, true);
  assert.equal(j.daily.length, 30);
  assert.equal(j.monthly.length, 12);
  // live: 499 + (999 - 200) = 1298 in the window; the 400-day-old order counts in totals only.
  assert.equal(j.daily.reduce((s, d) => s + d.netInr, 0), 1298);
  assert.equal(j.totals.netInr, 1398);
  assert.equal(j.totals.refundsInr, 200);
  assert.equal(j.totals.testNetInr, 500);
  assert.equal(j.totals.staffOrdersExcluded, 1);
  assert.equal(j.activePaidPlans.group_small, 1);
  assert.equal(j.activePaidPlans.group_large, undefined, 'a staff membership is not counted');
  assert.equal(j.monthly[11].activePaidPlans, 1);
  assert.equal(j.topCoupons.length, 1);
  assert.deepEqual(j.topCoupons[0], { code: 'WEB10', redemptions: 1, discountInr: 50, netInr: 449 });
  assert.equal(j.byPlan.find((p) => p.plan === 'group_large').netInr, 799);
  // Bounds are clamped.
  const wide = await t.api('GET', '/admin/web/revenue?days=9999&months=999', undefined, admin.token);
  assert.equal(wide.json.daily.length, 366);
  assert.equal(wide.json.monthly.length, 36);
});

test('revenue helpers: month keys are India-time months ending with the current one', async () => {
  const at = Date.UTC(2026, 0, 31, 20, 0); // 1 Feb 01:30 in India
  assert.deepEqual(monthKeys(at, 3), ['2025-12', '2026-01', '2026-02']);
  const empty = await revenueSummary({ listRazorpayOrders: async () => [], listCouponRedemptions: async () => [] }, { days: 7, months: 3, now: at });
  assert.equal(empty.daily.length, 7);
  assert.equal(empty.daily[6].date, '2026-02-01');
  assert.equal(empty.totals.netInr, 0);
});

test('admin APIs used by the web console answer for the admin (payments list, CSV, catalog, gateway view without secrets)', async () => {
  const list = await t.api('GET', '/admin/payments?limit=5', undefined, admin.token);
  assert.equal(list.status, 200);
  assert.ok(Array.isArray(list.json.payments));
  const csv = await fetch(`${t.base}/admin/payments/export.csv`, { headers: { Authorization: `Bearer ${admin.token}` } });
  assert.equal(csv.status, 200);
  assert.match(await csv.text(), /^orderId,userId,email/);
  const cat = await t.api('GET', '/admin/membership/catalog', undefined, admin.token);
  assert.ok(cat.json.catalog.group_small);
  const gw = await t.api('GET', '/admin/payment-gateway', undefined, admin.token);
  assert.equal(gw.status, 200);
  const text = JSON.stringify(gw.json);
  assert.doesNotMatch(text, /keySecret"\s*:\s*"/);
  assert.equal(typeof gw.json.test.keySecretSet, 'boolean');
});

// Reference matrices from the Python `qrcode` encoder (ERROR_CORRECT_M, byte mode, fixed mask, border 0),
// the same vectors the app's Dart encoder is tested against.
const QR_A = ['111111100111001111111', '100000101011101000001', '101110100010001011101', '101110100100001011101', '101110101100101011101', '100000100010101000001', '111111101010101111111', '000000000001100000000', '101010100011000010010', '100111000100001000110', '010000101110100010001', '101010000110001000100', '101001101010101010101', '000000001111010101010', '111111100001011101111', '100000100101110111000', '101110101101011101101', '101110100000001000110', '101110101100100010001', '100000100110001000110', '111111101000101010111'];
const QR_LINK = ['111111100110000010111111001111111', '100000100011100110100100001000001', '101110101010001010001100001011101', '101110101000100100100100001011101', '101110101000001111001101101011101', '100000101010101001010110101000001', '111111101010101010101010101111111', '000000001000101010111100000000000', '101111100111111001010010001111100', '110111010001111011011001001101101', '011011100011111111001010011010110', '010000011100110011110001010011111', '010001100111101010011111010011000', '001110011001000100100101100101011', '000111101001011111101110111111010', '010111000000000100000110011011100', '001111111011001101100000110111001', '101001000100010000111101001101101', '100100100111001110101100110110110', '111110011000111010010111101111111', '011101100100001100100100010111011', '110000011101010111001010000001101', '101101111100100001010010000011110', '100101010000111010111101111011110', '101111101000000001010010111111011', '000000001001110011111001100010111', '111111100100111101001011101010100', '100000101001001001101001100011100', '101110101001010110001110111111010', '101110101000000101100101010010101', '101110101110100111001111001100100', '100000100100100100000101110011100', '111111101110110111001011110100010'];
const rows = (q) => q.modules.map((r) => r.map((b) => (b ? '1' : '0')).join(''));

test('browser QR encoder (public/admin/qr.js) matches the reference module for module', () => {
  const a = qr.encode('A', { forceMask: 0 });
  assert.equal(a.version, 1);
  assert.deepEqual(rows(a), QR_A);
  const link = qr.encode('https://coroute.duckdns.org/get?coupon=FEST40', { forceMask: 2 });
  assert.equal(link.version, 4);
  assert.deepEqual(rows(link), QR_LINK);
  assert.equal(qr.encode('x'.repeat(14)).version, 1);
  assert.equal(qr.encode('x'.repeat(15)).version, 2);
  assert.equal(qr.encode('x'.repeat(213)).version, 10);
  assert.throws(() => qr.encode('x'.repeat(214)), /too long/);
  const auto = qr.encode('https://coroute.example/plans?coupon=DIWALI40');
  assert.ok(auto.mask >= 0 && auto.mask <= 7);
  assert.equal(auto.size, auto.version * 4 + 17);
});
