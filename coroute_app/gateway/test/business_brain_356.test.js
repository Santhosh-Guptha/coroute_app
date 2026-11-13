'use strict';
/**
 * Round 6 business brain (src/business/brain.js): cohort retention, activation funnel, plan and coupon conversion,
 * revenue trend and renewals on synthetic data; authorisation; memory bounds and job batching.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'biz.admin@coroute.test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { seeder, monday, DAY } = require('./_business_helpers');
const { BusinessBrain, weekOf, AT_RISK_MAX } = require('../src/business/brain');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');

const quiet = { info() {}, warn() {}, error() {} };
let env; let admin; let rider; let now; let seed;
before(async () => {
  env = await boot();
  now = Date.now();
  seed = seeder(env.soda, now);
  admin = await env.register('Biz Admin', 'biz.admin@coroute.test');
  rider = await env.register('Plain Rider', 'plain.rider@coroute.test');
  // Cohort A: 10 riders signed up 3 weeks ago; 6 rode in week 0, 4 of those again in week +1, 2 in week +3 (this week).
  const a = monday(now, 3);
  for (let i = 0; i < 10; i++) {
    const rides = [];
    if (i < 6) rides.push({ at: a + DAY, group: i < 3 });
    if (i < 4) rides.push(a + 8 * DAY);
    if (i < 2) rides.push(monday(now, 0) - 6 * 3600000 > now ? now - 3600000 : Math.min(now - 60000, monday(now, 0)));
    await seed.user({ createdAt: a, rides: rides.length ? rides : null, verified: i < 9 });
  }
  // Cohort B: 4 riders signed up last week, 1 rode that week.
  const b = monday(now, 1);
  for (let i = 0; i < 4; i++) await seed.user({ createdAt: b, rides: i === 0 ? [b + DAY] : null });
  // Orders: 3 paid small group (one refunded in full, one with a coupon), 1 failed, 1 created, 1 test mode, 1 staff.
  const users = (await env.soda.query('users', { role: 'RIDER' }, { limit: 100 })).map((r) => r.value).filter((u) => /^usr_b/.test(u.userId));
  await seed.order({ userId: users[0].userId, at: now - 2 * DAY });
  await seed.order({ userId: users[1].userId, at: now - 3 * DAY, refundedInPaise: 19900, refunds: [{ at: now - 2 * DAY }] });
  await seed.order({ userId: users[2].userId, at: now - 10 * DAY, couponCode: 'welcome20', amountInPaise: 15900 });
  await seed.redemption({ code: 'WELCOME20', userId: users[2].userId, discount: 40, final: 159, at: now - 10 * DAY });
  await seed.order({ userId: users[3].userId, status: 'FAILED', at: now - DAY });
  await seed.order({ userId: users[4].userId, status: 'CREATED', at: now - DAY });
  await seed.order({ userId: users[5].userId, mode: 'test', at: now - DAY });
  await seed.order({ userId: admin.user.userId, at: now - DAY, amountInPaise: 99900 });
  await seed.plan(users[0].userId, { until: now + 5 * DAY });
  await seed.plan(users[1].userId, { until: now + 20 * DAY });
  await seed.plan(users[2].userId, { until: now + 60 * DAY });
  await env.gw.repo.countPageview(new Date(now + 19800000).toISOString().slice(0, 10), '/plans', '');
  await env.gw.repo.countPageview(new Date(now + 19800000).toISOString().slice(0, 10), '/plans', '');
  await env.gw.business.brain.runNightly({});
});
after(async () => { await env.gw.shutdown(); });

const get = (path, token = admin.token) => env.api('GET', `/admin/business${path}`, null, token);

test('authorisation: MASTER_ADMIN only (401 without a session, 403 for a rider) on every business route', async () => {
  const routes = [['GET', '/overview'], ['GET', '/retention'], ['GET', '/conversion'], ['GET', '/churn'], ['POST', '/churn/winback'], ['GET', '/sendtime'], ['GET', '/review'],
    ['POST', '/review/abcdef012345'], ['GET', '/servers'], ['GET', '/settings'], ['PUT', '/settings'], ['GET', '/summary/preview'], ['POST', '/summary/test'], ['POST', '/refresh']];
  for (const [m, p] of routes) {
    assert.equal((await env.api(m, `/admin/business${p}`, m === 'GET' ? null : {}, null)).status, 401, `${m} ${p} anonymous`);
    assert.equal((await env.api(m, `/admin/business${p}`, m === 'GET' ? null : {}, rider.token)).status, 403, `${m} ${p} rider`);
  }
  const ok = await get('/overview');
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get('cache-control'), 'no-store');
});

test('cohort retention: weekly sign-up cohorts x weeks active (rode at least once), staff left out', async () => {
  const r = (await get('/retention')).json.retention;
  assert.equal(r.weeks, 12);
  assert.equal(r.cohorts.length, 12);
  const a = r.cohorts.find((c) => c.week === weekOf(now) - 3);
  assert.equal(a.size, 10);
  assert.deepEqual(a.active, [6, 4, 0, 2], 'week 0, +1, +2, +3 (only the weeks that have happened)');
  const b = r.cohorts.find((c) => c.week === weekOf(now) - 1);
  assert.equal(b.size, 4);
  assert.deepEqual(b.active, [1, 0]);
  const cur = r.cohorts.find((c) => c.week === weekOf(now));
  assert.equal(cur.size, 1, 'the plain rider registered in this test; the admin is staff and not counted');
  for (const c of r.cohorts) { assert.equal(c.active.length, 12 - (c.week - r.cohorts[0].week)); assert.ok(c.active.every((n) => n <= c.size)); }
  assert.equal(JSON.stringify(r).includes('usr_'), false, 'cohorts hold counts only');
});

test('activation funnel: signed up -> verified -> first ride -> first group ride -> paid', async () => {
  const f = (await get('/overview')).json.funnel;
  assert.deepEqual(f.all, { signedUp: 15, verified: 14, firstRide: 7, firstGroupRide: 3, paid: 3 });
  assert.deepEqual(f.recent, f.all, 'everyone signed up within 90 days');
  assert.ok(f.all.signedUp >= f.all.verified && f.all.verified >= f.all.firstRide && f.all.firstRide >= f.all.firstGroupRide);
});

test('plan and coupon conversion, revenue trend, renewals due (live money only, after refunds)', async () => {
  const c = (await get('/conversion')).json.conversion;
  const small = c.plans.find((p) => p.plan === 'group_small');
  assert.deepEqual({ created: small.created, paid: small.paid, refunded: small.refunded, failed: small.failed }, { created: 5, paid: 3, refunded: 1, failed: 1 });
  assert.equal(small.netInr, 199 + 0 + 159);
  const w = c.coupons.find((x) => x.code === 'WELCOME20');
  assert.deepEqual({ paid: w.paid, redeemed: w.redeemed, revenueInr: w.revenueInr, discountInr: w.discountInr }, { paid: 1, redeemed: 1, revenueInr: 159, discountInr: 40 });
  assert.equal(c.planViews.views30, 2);
  const o = (await get('/overview')).json;
  assert.equal(o.revenue.weekly.length, 26);
  assert.equal(o.revenue.weekly.reduce((s, x) => s + x.netInr, 0), 358);
  assert.equal(o.revenue.weekly.reduce((s, x) => s + x.orders, 0), 3);
  assert.deepEqual({ netInr: o.revenue.last7.netInr, orders: o.revenue.last7.orders, refundsInr: o.revenue.last7.refundsInr }, { netInr: 199, orders: 2, refundsInr: 199 });
  assert.deepEqual({ in7: o.revenue.renewals.in7, in14: o.revenue.renewals.in14, in30: o.revenue.renewals.in30 }, { in7: 1, in14: 1, in30: 2 });
  assert.equal(o.revenue.renewals.list.length, 2);
  assert.ok(o.revenue.renewals.list.every((x) => Object.keys(x).sort().join() === 'plan,until,userId'), 'ids, plan and date only');
  assert.equal(o.meta.lastRunAt > 0, true);
});

test('refresh runs the computation once at a time and is audited', async () => {
  const [a, b] = await Promise.all([env.api('POST', '/admin/business/refresh', {}, admin.token), env.api('POST', '/admin/business/refresh', {}, admin.token)]);
  assert.equal(a.status, 200); assert.equal(b.status, 200);
  assert.equal(a.json.state.lastRunAt, b.json.state.lastRunAt, 'the second call joined the run in progress');
  const audit = await env.soda.query('subscription_config', { k: 'audit', action: 'business.refresh' }, { limit: 10 });
  assert.equal(audit.length, 2);
});

test('aggregates are small documents without personal data (no names, e-mail addresses or phone numbers)', async () => {
  const rows = await env.soda.query('business_agg', {}, { limit: 100 });
  assert.ok(rows.length >= 8);
  for (const r of rows) {
    const text = JSON.stringify(r.value);
    assert.ok(text.length < 60000, `${r.value.k} is ${text.length} bytes`);
    assert.doesNotMatch(text, /@coroute\.test|Rider \d|\+91\d{6}/, `${r.value.k} holds personal data`);
  }
});

test('job batching and memory bounds: pages of PAGE documents, a pause per page, capped riders, abortable', async () => {
  const soda = new MemorySoda();
  const repo = new Repo(soda);
  await repo.migrate();
  const s = seeder(soda, now);
  for (let i = 0; i < 300; i++) await s.user({ createdAt: now - 20 * DAY, rides: [now - (40 + (i % 30)) * DAY, now - 70 * DAY], lastActiveAt: now - 40 * DAY });
  const scans = []; const queries = [];
  const scan = soda.scan.bind(soda);
  soda.scan = (c, o) => { scans.push({ c, pageSize: o && o.pageSize }); return scan(c, o); };
  const q = soda.query.bind(soda);
  soda.query = (c, f, o) => { queries.push({ c, limit: o && o.limit }); return q(c, f, o); };
  const brain = new BusinessBrain({ soda, repo, logger: quiet, page: 50, pauseMs: 0, maxRiders: 120, env: {} });
  const state = await brain.runNightly({});
  assert.ok(scans.length >= 5 && scans.every((x) => x.pageSize <= 50), 'whole-collection reads are paged');
  assert.ok(queries.filter((x) => ['subscription_config', 'business_obs', 'email_events'].includes(x.c)).every((x) => x.limit <= 50));
  assert.ok(brain.stats.pages >= 300 / 50 * 2, `one pause per page (${brain.stats.pages})`);
  assert.equal(state.counts.riders, 120, 'riders held in memory are capped');
  assert.ok(brain.stats.peakRiders <= 120);
  assert.deepEqual(state.truncated, ['riders'], 'and the page says the numbers are partial');
  const churn = await brain.getAgg('churn');
  assert.ok(churn.atRisk.length <= AT_RISK_MAX);
  // A stop signal ends the job at the next page.
  const ac = new AbortController(); ac.abort();
  await assert.rejects(brain.runNightly({ signal: ac.signal }), /stopped/);
  // Switched off: nothing runs, nothing is counted.
  const off = new BusinessBrain({ soda, repo, logger: quiet, env: { BUSINESS_ANALYTICS: 'off' } });
  assert.deepEqual(await off.runNightly({}), { skipped: 'OFF' });
  off.observeOpen('usr_x'); assert.equal(off.opens.size, 0);
});

test('the nightly job and the weekly summary run under the job lease', () => {
  const src = require('fs').readFileSync(require('path').join(__dirname, '..', 'src', 'business', 'index.js'), 'utf8');
  assert.match(src, /lease\.run\('business-nightly', 24 \* 60 \* min, \(\{ signal \} = \{\}\) => brain\.runNightly\(\{ signal \}\)/);
  assert.match(src, /lease\.run\('business-weekly-summary'/);
});
