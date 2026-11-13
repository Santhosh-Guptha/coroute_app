'use strict';
/**
 * Round 6 review list: coupon / payment signals (many accounts on one device hash, many failed payments, coupon
 * orders left unpaid, refund patterns) and spam-account signals (bulk sign-ups per network hash, bursts of
 * unconfirmed sign-ups). A list for a person to review: nothing is ever blocked or changed automatically.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'sig.admin@coroute.test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { seeder, DAY } = require('./_business_helpers');

let env; let admin; let now; let seed; let people;
before(async () => {
  env = await boot();
  now = Date.now();
  seed = seeder(env.soda, now);
  admin = await env.register('Signals Admin', 'sig.admin@coroute.test');
  people = {};
  const mk = async (name, o = {}) => { people[name] = await seed.user({ username: name, createdAt: now - 40 * DAY, ...o }); return people[name]; };
  // 5 accounts on one phone; 3 on another (below the threshold).
  for (let i = 0; i < 5; i++) await seed.session({ userId: (await mk(`dev_a${i}`)).userId, deviceKey: 'hash-of-device-A' });
  for (let i = 0; i < 3; i++) await seed.session({ userId: (await mk(`dev_b${i}`)).userId, deviceKey: 'hash-of-device-B' });
  // An old session on a third phone (outside 90 days) is ignored.
  for (let i = 0; i < 6; i++) await seed.session({ userId: people.dev_a0.userId + i, deviceKey: 'hash-old', at: now - 200 * DAY });
  // Failed payments: 5 in 30 days for one rider; 2 for another.
  await mk('card_fails'); for (let i = 0; i < 5; i++) await seed.order({ userId: people.card_fails.userId, status: 'FAILED', at: now - i * DAY });
  await mk('card_twice'); for (let i = 0; i < 2; i++) await seed.order({ userId: people.card_twice.userId, status: 'FAILED', at: now - i * DAY });
  // Refunds: two refunded orders, one within 48 hours of paying.
  await mk('refunder');
  await seed.order({ userId: people.refunder.userId, at: now - 20 * DAY, refundedInPaise: 19900, refunds: [{ at: now - 20 * DAY + 3600000 }] });
  await seed.order({ userId: people.refunder.userId, at: now - 5 * DAY, refundedInPaise: 19900, refunds: [{ at: now - DAY }] });
  // Coupon orders started and left: 6 in 30 days.
  await mk('coupon_tryer'); for (let i = 0; i < 6; i++) await seed.redemption({ code: 'WELCOME20', userId: people.coupon_tryer.userId, status: 'CANCELLED', at: now - i * DAY });
  // Bulk sign-ups: 9 new accounts from one network in 7 days; 12 unconfirmed sign-ups in one hour.
  const hour = Math.floor((now - 2 * DAY) / 3600000) * 3600000;
  for (let i = 0; i < 9; i++) { const u = await seed.user({ username: `net_${i}`, createdAt: now - 3 * DAY + i * 60000 }); await seed.session({ userId: u.userId, ipHash: 'hash-of-network-N', at: now - 3 * DAY }); }
  for (let i = 0; i < 12; i++) await seed.user({ username: `burst_${i}`, createdAt: hour + i * 60000, verified: false });
  await env.gw.business.brain.runNightly({});
});
after(async () => { await env.gw.shutdown(); });

test('each signal is found with its count; thresholds keep ordinary riders off the list', async () => {
  const r = await env.api('GET', '/admin/business/review', null, admin.token);
  assert.equal(r.status, 200);
  const by = Object.fromEntries(r.json.items.map((x) => [x.type, x]));
  assert.deepEqual(Object.keys(by).sort(), ['coupon_retries', 'device_accounts', 'failed_payments', 'refund_pattern', 'signup_network', 'unverified_burst']);
  assert.equal(r.json.items.length, 6, 'one of each: nothing below a threshold');
  assert.equal(by.device_accounts.count, 5);
  assert.deepEqual(by.device_accounts.riders.map((x) => x.username).sort(), ['dev_a0', 'dev_a1', 'dev_a2', 'dev_a3', 'dev_a4']);
  assert.equal(by.failed_payments.count, 5); assert.equal(by.failed_payments.riders[0].username, 'card_fails');
  assert.equal(by.refund_pattern.count, 2); assert.match(by.refund_pattern.note, /1 within 48 hours/);
  assert.equal(by.coupon_retries.count, 6); assert.equal(by.coupon_retries.riders[0].username, 'coupon_tryer');
  assert.equal(by.signup_network.count, 9);
  assert.equal(by.unverified_burst.count, 12); assert.equal(by.unverified_burst.riders.length, 0);
  assert.ok(r.json.items.every((x) => x.label && x.note && [1, 2, 3].includes(x.severity) && x.review.status === 'OPEN' && /^[a-f0-9]{12}$/.test(x.id)));
  assert.match(r.json.note, /Nothing here blocks or changes an account/);
  // The device / network hashes themselves never leave the server, and are not stored in the aggregate either.
  const stored = JSON.stringify((await env.soda.findOne('business_agg', { k: 'signals' })).value);
  for (const secret of ['hash-of-device-A', 'hash-of-network-N']) { assert.equal(stored.includes(secret), false); assert.equal(JSON.stringify(r.json).includes(secret), false); }
});

test('never an automatic block: every flagged account is exactly as it was (status, sessions, plans, orders)', async () => {
  for (const name of ['dev_a0', 'card_fails', 'refunder', 'coupon_tryer', 'net_3', 'burst_5']) {
    const u = (await env.soda.findOne('users', { username: name })).value;
    assert.equal(u.status, 'ACTIVE', name);
    assert.equal(u.role, 'RIDER');
  }
  assert.ok((await env.soda.query('auth_sessions', { deviceKey: 'hash-of-device-A' }, { limit: 10 })).every((s) => s.value.revokedAt === 0), 'no session was ended');
  const src = require('fs').readFileSync(require('path').join(__dirname, '..', 'src', 'business', 'brain.js'), 'utf8') + require('fs').readFileSync(require('path').join(__dirname, '..', 'src', 'business', 'index.js'), 'utf8');
  assert.doesNotMatch(src, /updateUser\(|status:\s*'(BLOCKED|ON_HOLD)'|revoke\w*\(|disconnectUser|setStatus/, 'the business code has no way to block, hold or sign out a rider');
});

test('review decisions: mark reviewed / open again, audited; they survive the next nightly run', async () => {
  const list = (await env.api('GET', '/admin/business/review', null, admin.token)).json.items;
  const item = list.find((x) => x.type === 'device_accounts');
  assert.equal((await env.api('POST', `/admin/business/review/${item.id}`, { status: 'BLOCK' }, admin.token)).status, 400);
  assert.equal((await env.api('POST', '/admin/business/review/000000000000', { status: 'REVIEWED' }, admin.token)).status, 404);
  const done = await env.api('POST', `/admin/business/review/${item.id}`, { status: 'REVIEWED', note: 'A family sharing one phone' }, admin.token);
  assert.equal(done.status, 200); assert.equal(done.json.review.status, 'REVIEWED');
  await env.gw.business.brain.runNightly({});
  const again = (await env.api('GET', '/admin/business/review', null, admin.token)).json.items.find((x) => x.id === item.id);
  assert.equal(again.review.status, 'REVIEWED'); assert.equal(again.review.note, 'A family sharing one phone'); assert.match(again.review.by, /sig\.admin/);
  assert.equal((await env.api('POST', `/admin/business/review/${item.id}`, { status: 'OPEN' }, admin.token)).json.review.status, 'OPEN');
  const audit = await env.soda.query('subscription_config', { k: 'audit', action: 'business.signal_review' }, { limit: 10 });
  assert.equal(audit.length, 2);
});

test('bounded: at most 100 signals are kept, the most severe first', async () => {
  const s2 = seed;
  for (let i = 0; i < 130; i++) { const u = await s2.user({ userId: `usr_many${i}`, username: `many_${i}` }); for (let k = 0; k < 4 + (i % 6); k++) await s2.order({ userId: u.userId, status: 'FAILED', at: now - k * 3600000 }); }
  await env.gw.business.brain.runNightly({});
  const items = (await env.soda.findOne('business_agg', { k: 'signals' })).value.items;
  assert.equal(items.length, 100);
  assert.deepEqual(items.map((x) => x.severity), items.map((x) => x.severity).slice().sort((a, b) => b - a));
});
