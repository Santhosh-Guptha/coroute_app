'use strict';
/**
 * 3.56 rider website shop (docs/features_355/web_payments.md): the Play app sells nothing; plans, coupons,
 * payments and the account are on the website. Pages are served with a strict CSP, the coupon link lands on
 * /plans, a web session buys through the same membership endpoints as the app, a verified payment (or a
 * webhook) activates the plan and tells the app (SUBSCRIPTION_ACTIVATED), and the old app checkout path
 * (checkout.html?order=&t=&e=) keeps working.
 */
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.RAZORPAY_MODE = 'test';
process.env.RAZORPAY_TEST_KEY_ID = 'rzp_test_webshop';
process.env.RAZORPAY_TEST_KEY_SECRET = 'webshop_secret';
process.env.RAZORPAY_TEST_WEBHOOK_SECRET = 'whsec_webshop';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { setRazorpayFetch } = require('../src/razorpay_gateway');
const shop = require('../src/web_shop');
const { webCheckoutToken } = require('../src/subscription_routes');
const { boot } = require('./_helpers');

setRazorpayFetch(async (url, opts = {}) => {
  const reply = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => body });
  if (opts.method === 'POST' && url.endsWith('/orders')) {
    const b = JSON.parse(opts.body);
    return reply(200, { id: `order_${crypto.randomBytes(7).toString('hex')}`, amount: b.amount, currency: b.currency, status: 'created' });
  }
  return reply(404, {});
});
const sign = (orderId, paymentId) => crypto.createHmac('sha256', 'webshop_secret').update(`${orderId}|${paymentId}`).digest('hex');
const WEB = { 'X-CoRoute-Client': 'web' };
const PUB = path.join(__dirname, '..', 'public');

let env, origin;
before(async () => {
  env = await boot();
  origin = env.base.replace(/\/api$/, '');
});
after(async () => { setRazorpayFetch(null); await env.gw.shutdown(); });

/** Script source without comments (doc comments may mention what the code never does). */
const codeOf = (src) => src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
const page = (p, opts) => fetch(origin + p, { redirect: 'manual', ...opts });

test('shop pages are served with a strict CSP, no inline script, no-store, framing denied', async () => {
  for (const p of ['/plans', '/account', '/signin', '/receipt', '/plans.html']) {
    const r = await page(p);
    assert.equal(r.status, 200, p);
    const csp = r.headers.get('content-security-policy');
    assert.match(csp, /script-src 'self'(?: https:\/\/checkout\.razorpay\.com)?;/, `${p}: ${csp}`);
    assert.ok(!/script-src[^;]*'unsafe-inline'/.test(csp), `${p}: no inline script allowed`);
    assert.ok(csp.includes("frame-ancestors 'none'") && csp.includes("object-src 'none'") && csp.includes("base-uri 'none'"), p);
    assert.equal(r.headers.get('x-frame-options'), 'DENY');
    assert.equal(r.headers.get('cache-control'), 'no-store', p);
    assert.equal(r.headers.get('referrer-policy'), 'no-referrer');
    const html = await r.text();
    assert.ok(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), `${p}: inline <script>`);
    assert.ok(!/\son[a-z]+=/i.test(html.replace(/<svg[\s\S]*?<\/svg>/g, '')), `${p}: inline event handler`);
    assert.match(html, /<script src="\/assets\/theme-init\.js\?v=[a-f0-9]+"><\/script>/, `${p}: theme without inline script`);
    assert.ok(html.includes('class="site-header"') && !html.includes('<!--#include'), `${p}: shared shell`);
    assert.ok(!/₹\s?\d|Rs\.? ?\d/.test(html), `${p}: no price written into the page`);
  }
  // Only /plans (and the old /checkout) may load Razorpay; /signin only Google when configured; /account nothing.
  assert.ok((await page('/plans')).headers.get('content-security-policy').includes('frame-src https://api.razorpay.com https://checkout.razorpay.com'));
  const acc = (await page('/account')).headers.get('content-security-policy');
  assert.ok(!acc.includes('razorpay') && !acc.includes('google') && acc.includes("frame-src 'none'"), acc);
  assert.ok(!(await page('/signin')).headers.get('content-security-policy').includes('accounts.google.com'), 'no Google without GOOGLE_WEB_CLIENT_ID');
  const g = shop.shopCsp({ google: true });
  assert.ok(g.includes('script-src \'self\' https://accounts.google.com/gsi/client') && g.includes('frame-src https://accounts.google.com/gsi/'));
  // Marketing pages have their own strict policy (src/pages.js MARKETING_CSP): no Razorpay, no inline script.
  const mk = (await page('/features')).headers.get('content-security-policy');
  assert.ok(mk.includes("script-src 'self';") && !mk.includes('razorpay') && mk.includes("base-uri 'none'"), mk);
  const sm = await (await page('/sitemap.xml')).text();
  assert.ok(sm.includes(`<loc>${origin}/plans</loc>`) && !sm.includes('/account<') && !sm.includes('/signin<'));
});

test('session token: sessionStorage + Bearer only, never in a URL or localStorage; rendering is textContent only', () => {
  const js = Object.fromEntries(['shop', 'signin', 'plans', 'account', 'receipt'].map((n) => [n, fs.readFileSync(path.join(PUB, 'assets', `${n}.js`), 'utf8')]));
  assert.ok(js.shop.includes('window.sessionStorage') && js.shop.includes("'Bearer ' + t"));
  for (const [n, raw] of Object.entries(js)) {
    const src = raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, ''); // code only, not comments
    assert.ok(!/localStorage/.test(src), `${n}: localStorage`);
    assert.ok(!/innerHTML|insertAdjacentHTML|document\.write|outerHTML/.test(src), `${n}: HTML strings`);
    assert.ok(!/[?&](?:token|t)=['"]?\s*\+\s*(?:S\.)?token/.test(src), `${n}: token in a URL`);
    assert.ok(!/document\.cookie/.test(src), `${n}: cookies`);
  }
  assert.ok(js.plans.includes("'/membership/quote?plan='") && js.plans.includes("'/membership/order'") && js.plans.includes("'/membership/verify'"), 'plans: the app endpoints');
  assert.ok(!/(?:\\u20B9|₹)'?\s*\+?\s*'?\d/.test(codeOf(js.plans)) && !/price\w*\s*[:=]\s*[1-9]/i.test(codeOf(js.plans)), 'plans: no price constants');
  assert.ok(js.signin.includes("'/auth/login'") && js.signin.includes("'/auth/google'"));
});

test('coupon prefill is sanitised; /get?coupon= forwards to /plans; marketing links point at /plans', async () => {
  // Client: the same checks as the server (A-Z 0-9 - _, max 24).
  const sandbox = { window: {}, document: { addEventListener() {} } };
  vm.runInNewContext(fs.readFileSync(path.join(PUB, 'assets', 'shop.js'), 'utf8'), sandbox);
  const S = sandbox.window.CoShop;
  assert.equal(S.cleanCode(' welcome50 '), 'WELCOME50');
  for (const bad of ['<script>', 'a b', 'A'.repeat(25), '"x"', '']) assert.equal(S.cleanCode(bad), '', bad);
  assert.equal(S.safeNext('/plans?plan=group_small&coupon=X'), '/plans?plan=group_small&coupon=X');
  for (const bad of ['//evil.example', 'https://evil.example/plans', '/admin', 'javascript:alert(1)', '/plans/../admin']) assert.equal(S.safeNext(bad), '/account', bad);
  assert.equal(shop.cleanCouponCode('fest-40'), 'FEST-40');
  assert.equal(shop.cleanCouponCode('<x>'), '');

  const r = await page('/get?coupon=welcome50');
  assert.equal(r.status, 302);
  assert.equal(r.headers.get('location'), '/plans?coupon=WELCOME50');
  const bad = await page('/get?coupon=%3Cscript%3E');
  assert.equal(bad.headers.get('location'), '/plans');
  assert.equal((await page('/get')).status, 200, '/get itself stays the download page');
  // The server never renders the query into the page.
  const html = await (await page('/plans?coupon=%3Cimg%20src%3Dx%3E')).text();
  assert.ok(!html.includes('<img src=x>') && !html.includes('%3Cimg'));
  assert.equal(require('../src/marketing_templates').couponLink('https://coroute.devmonks.space', 'ride10'), 'https://coroute.devmonks.space/plans?coupon=RIDE10');
});

test('web session: plans data, quote with coupon, upgrade-only 409, order + verify -> active, SUBSCRIPTION_ACTIVATED, receipt', async () => {
  const rider = await env.register('Web Buyer', 'webbuyer@coroute.test');
  const other = await env.register('Other Rider', 'webother@coroute.test');
  // Sign in like the website does (same login API as the app; rate limited).
  const login = await env.api('POST', '/auth/login', { identifier: 'webbuyer@coroute.test', password: 'Password#123' });
  assert.equal(login.status, 200);
  assert.ok(login.headers.get('ratelimit') || login.headers.get('ratelimit-policy'), 'login is rate limited');
  const token = login.json.token;

  const cat = await env.api('GET', '/membership/catalog');
  assert.equal(cat.status, 200);
  assert.deepEqual(Object.keys(cat.json.categories).sort(), ['community', 'group_large', 'group_small']);
  assert.equal(cat.json.categories.community.monthlyPriceInr, 0);

  const cfg = await env.api('GET', '/web/config');
  assert.equal(cfg.status, 200);
  assert.equal(cfg.json.googleClientId, null);
  assert.equal(cfg.json.paymentsEnabled, true);

  // Quote with the launch coupon (seeded); a bad code never blocks the quote.
  const q = await env.api('GET', '/membership/quote?plan=group_small&coupon=WELCOME50', null, token, WEB);
  assert.equal(q.status, 200, JSON.stringify(q.json));
  assert.equal(q.json.couponCode, 'WELCOME50');
  assert.ok(q.json.payableInr < q.json.basePriceInr);
  const qb = await env.api('GET', '/membership/quote?plan=group_small&coupon=NOPE12', null, token, WEB);
  assert.equal(qb.json.couponError.reason, 'COUPON_NOT_FOUND');
  assert.equal(qb.json.payableInr, qb.json.basePriceInr);

  // Pay from the web session: the amount is the server's, a client amount is ignored.
  const ws = await env.connect(token);
  const o = await env.api('POST', '/membership/order', { category: 'group_small', amount: 1, amountInPaise: 100 }, token, WEB);
  assert.equal(o.status, 201, JSON.stringify(o.json));
  assert.equal(o.json.amountInr, cat.json.categories.group_small.monthlyPriceInr);
  const stored = await env.gw.repo.findRazorpayOrder(o.json.orderId);
  assert.equal(stored.channel, 'web');
  // Someone else cannot verify (or read the receipt of) this order.
  const pid = `pay_${crypto.randomBytes(5).toString('hex')}`;
  assert.equal((await env.api('POST', '/membership/verify', { orderId: o.json.orderId, paymentId: pid, signature: sign(o.json.orderId, pid) }, other.token)).status, 403);
  assert.equal((await env.api('POST', '/membership/verify', { orderId: o.json.orderId, paymentId: pid, signature: 'bad' }, token, WEB)).status, 400);
  // The bad signature marked the order FAILED; a fresh order for the real payment.
  const o2 = await env.api('POST', '/membership/order', { category: 'group_small' }, token, WEB);
  const v = await env.api('POST', '/membership/verify', { orderId: o2.json.orderId, paymentId: pid, signature: sign(o2.json.orderId, pid) }, token, WEB);
  assert.equal(v.status, 200, JSON.stringify(v.json));
  assert.equal(v.json.membership.status, 'ACTIVE');
  assert.equal(v.json.membership.category, 'group_small');
  const evt = await ws.next((m) => m.type === 'SUBSCRIPTION_ACTIVATED');
  assert.equal(evt.plan, 'group_small');
  assert.equal(evt.orderId, o2.json.orderId);
  ws.close();
  const my = await env.api('GET', '/membership/my', null, token);
  assert.equal(my.json.plan.category, 'group_small');

  // Upgrade-only: the same or a smaller plan is refused with the server's words.
  const down = await env.api('GET', '/membership/quote?plan=group_small', null, token, WEB);
  assert.equal(down.status, 409);
  assert.equal(down.json.reason, 'DOWNGRADE_NOT_ALLOWED');
  assert.match(down.json.error, /bigger plan anytime/);
  const up = await env.api('GET', '/membership/quote?plan=group_large', null, token, WEB);
  assert.equal(up.status, 200);
  assert.equal(up.json.kind, 'upgrade');
  assert.ok(up.json.creditInr > 0 && up.json.breakdown.some((l) => /Credit for/.test(l.label)), 'proration credit shown');

  // Receipt: own paid order only.
  const rc = await env.api('GET', `/web/receipt/${o2.json.orderId}`, null, token);
  assert.equal(rc.status, 200, JSON.stringify(rc.json));
  assert.equal(rc.json.receipt.paymentId, pid);
  assert.equal(rc.json.receipt.amountInr, o2.json.amountInr);
  assert.equal(rc.json.receipt.billedTo.email, 'webbuyer@coroute.test');
  assert.equal(rc.json.receipt.channel, 'web');
  assert.ok(!JSON.stringify(rc.json).includes('webhookEvents') && !JSON.stringify(rc.json).includes('"key"'));
  assert.equal((await env.api('GET', `/web/receipt/${o2.json.orderId}`, null, other.token)).status, 404, 'someone else: not found');
  assert.equal((await env.api('GET', `/web/receipt/${o2.json.orderId}`)).status, 401);
  assert.equal((await env.api('GET', `/web/receipt/${o.json.orderId}`, null, token)).status, 409, 'unpaid order: no receipt');
  const pays = await env.api('GET', '/membership/payments', null, token);
  assert.ok(pays.json.payments.some((p) => p.orderId === o2.json.orderId && p.status === 'PAID'));
});

test('webhook for a web order (the active URL) activates the plan and emits SUBSCRIPTION_ACTIVATED', async () => {
  // 3.56: only one URL is live (RAZORPAY_WEBHOOK_URL): the other answers 410 and settles nothing.
  for (const [hook, which] of [['/subscription/webhook', 'subscription'], ['/membership/webhook', 'membership']]) {
    process.env.RAZORPAY_WEBHOOK_URL = which;
    const other = which === 'subscription' ? '/membership/webhook' : '/subscription/webhook';
    const off = await fetch(env.base + other, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Razorpay-Signature': 'x' }, body: '{}' });
    assert.equal(off.status, 410, `${other} inactive while ${which} is chosen`);
    assert.equal((await off.json()).code, 'WEBHOOK_URL_INACTIVE');
    const email = `hook${hook.length}${crypto.randomBytes(2).toString('hex')}@coroute.test`;
    const rider = await env.register(`Hook Rider ${crypto.randomBytes(2).toString('hex')}`, email);
    const ws = await env.connect(rider.token);
    const o = await env.api('POST', '/membership/order', { category: 'group_large' }, rider.token, WEB);
    assert.equal(o.status, 201);
    // The browser closed before /verify: only Razorpay's webhook arrives.
    const body = JSON.stringify({ event: 'payment.captured', payload: { payment: { entity: { id: `pay_${crypto.randomBytes(5).toString('hex')}`, order_id: o.json.orderId, method: 'upi', amount: o.json.amountInPaise } } } });
    const sig = crypto.createHmac('sha256', 'whsec_webshop').update(body).digest('hex');
    const bad = await fetch(env.base + hook, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Razorpay-Signature': 'nope' }, body });
    assert.equal(bad.status, 400, `${hook}: signature required`);
    const res = await fetch(env.base + hook, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Razorpay-Signature': sig, 'X-Razorpay-Event-Id': `evt_${crypto.randomBytes(4).toString('hex')}` }, body });
    assert.equal(res.status, 200, hook);
    const evt = await ws.next((m) => m.type === 'SUBSCRIPTION_ACTIVATED');
    assert.equal(evt.plan, 'group_large', hook);
    ws.close();
    const my = await env.api('GET', '/membership/my', null, rider.token);
    assert.equal(my.json.plan.category, 'group_large', `${hook}: membership active`);
    const user = await env.gw.repo.findUserById(rider.user.userId);
    assert.ok(!user.subscriptionTier || user.subscriptionTier === 'community', `${hook}: no legacy tier written`);
  }
  delete process.env.RAZORPAY_WEBHOOK_URL;
});

test('old app checkout path: /checkout?order=&t=&e= still served and its API works; a plain visit goes to /plans', async () => {
  assert.equal((await page('/checkout')).headers.get('location'), '/plans');
  assert.equal((await page('/checkout.html')).status, 302);
  const r = await page('/checkout.html?order=order_x&t=y&e=1');
  assert.equal(r.status, 200);
  assert.ok(r.headers.get('content-security-policy').includes('https://checkout.razorpay.com'));
  assert.ok(r.headers.get('content-security-policy').includes('form-action \'self\' https://api.razorpay.com'), 'redirect mode posts to Razorpay');
  const html = await r.text();
  assert.match(html, /<script src="\/assets\/checkout\.js\?v=[a-f0-9]+" defer><\/script>/);
  assert.equal((await page('/checkout.html?paid=order_x')).status, 200, 'return from Razorpay');
  assert.equal((await page('/checkout.html?failed=x')).status, 200);
  const js = fs.readFileSync(path.join(PUB, 'assets', 'checkout.js'), 'utf8');
  assert.ok(js.includes("'/api/checkout/order/'") && js.includes("'&e='") && js.includes("'/api/razorpay/callback'"));

  // An app-created ledger order with a signed link is readable by the page.
  const rider = await env.register('Old App Rider', 'oldapp@coroute.test');
  const orderId = `order_${crypto.randomBytes(6).toString('hex')}`;
  await env.gw.repo.saveRazorpayOrder({ orderId, userId: rider.user.userId, planTier: 'proRider', billingCycle: 'monthly', amountInPaise: 4900, currency: 'INR', status: 'CREATED', mode: 'test', createdAt: Date.now() });
  const e = Date.now() + 30 * 60000;
  const look = await env.api('GET', `/checkout/order/${orderId}?t=${webCheckoutToken(orderId, e)}&e=${e}`);
  assert.equal(look.status, 200, JSON.stringify(look.json));
  assert.equal(look.json.amount, 4900);
});

test('notifyPlanActivated: socket event always, push only through the push service (never throws)', async () => {
  const sent = [];
  const pushed = [];
  shop.notifyPlanActivated({
    hub: { sendToUser: (u, p) => sent.push([u, p]), push: { notifyUsers: async (ids, o) => { pushed.push([ids, o]); return {}; } } },
    userId: 'usr_x', membership: { category: 'group_small', categoryName: 'Small Group (2–6)', validUntil: 123 }, order: { orderId: 'order_1' }, source: 'verify',
  });
  await new Promise((r) => setImmediate(r));
  assert.equal(sent[0][1].type, 'SUBSCRIPTION_ACTIVATED');
  assert.equal(sent[0][1].plan, 'group_small');
  assert.equal(pushed[0][1].type, 'SUBSCRIPTION_ACTIVATED');
  assert.equal(pushed[0][1].skipConnected, true);
  assert.equal(pushed[0][1].body, 'Small Group is active. Thank you for riding with CoRoute.');
  assert.doesNotThrow(() => shop.notifyPlanActivated({ hub: { sendToUser() { throw new Error('x'); } }, userId: 'u' }));
});
