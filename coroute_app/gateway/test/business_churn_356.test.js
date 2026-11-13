'use strict';
/**
 * Round 6 churn warning: transparent rule score with top factors, the small logistic regression (only with enough
 * history and a good held-out AUC), the "At risk this week" list, and the win-back e-mail through the e-mail wizard
 * under the marketing consent rules (riders without consent are listed but never mailable).
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'churn.admin@coroute.test';
process.env.MAIL_POSTAL_ADDRESS = 'CoRoute, 1 Test Road, Hyderabad';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { seeder, DAY } = require('./_business_helpers');
const M = require('../src/business/churn_model');

let env; let admin; let now; let seed; const sent = [];
before(async () => {
  env = await boot({ mailTransport: { sendMail: async (m) => { sent.push(m); return { messageId: `m${sent.length}` }; } } });
  now = Date.now();
  seed = seeder(env.soda, now);
  admin = await env.register('Churn Admin', 'churn.admin@coroute.test');
});
after(async () => { await env.gw.shutdown(); });

test('rule score: plain facts, points and factors; capped at 100; nothing for an active rider', () => {
  const active = M.ruleScore({ lastRideAt: now - 2 * DAY, rideDays30: 6, rideDaysPrev60: 10, planEndsAt: now + 40 * DAY, lastOpenAt: now - DAY }, now);
  assert.deepEqual(active, { score: 0, factors: [] });
  const r = M.ruleScore({ lastRideAt: now - 45 * DAY, rideDays30: 0, rideDaysPrev60: 8, planEndsAt: now + 3 * DAY, lastOpenAt: now - 33 * DAY }, now);
  assert.equal(r.score, 30 + 25 + 15 + 20);
  assert.deepEqual(r.factors.map((f) => f.key), ['recency', 'frequency', 'app', 'plan']);
  assert.match(r.factors[0].label, /No ride for 45 days/);
  assert.match(r.factors[1].label, /none in the last 30 days/);
  assert.equal(M.ruleScore({ lastRideAt: now - 20 * DAY, rideDays30: 2, rideDaysPrev60: 12, lastOpenAt: now - 2 * DAY }, now).score, 15 + 20, 'riding less than half as often');
  assert.equal(M.ruleScore({ lastRideAt: now - 100 * DAY, rideDays30: 0, rideDaysPrev60: 20, planEndedAt: now - 5 * DAY, lastOpenAt: now - 90 * DAY }, now).score, 100, 'capped');
  assert.equal(M.ruleScore({ lastRideAt: 0, planEndedAt: now - 10 * DAY, lastOpenAt: now - DAY }, now).score, 20, 'a plan that ended, never rode');
});

test('logistic regression: needs enough history and both outcomes; reliable on separable data; bounded size', () => {
  let s = 5; const rnd = () => { s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648; };
  const today = Math.floor(now / DAY);
  const rows = [];
  for (let i = 0; i < 600; i++) {
    const keen = rnd() < 0.5; const days = [];
    for (let d = today - 110; d <= today; d++) if (rnd() < (keen ? 0.25 : (d < today - 28 ? 0.05 : 0.005))) days.push(d);
    const row = M.sampleOf(days, now, { createdAt: now - 200 * DAY });
    if (row) rows.push(row);
  }
  assert.equal(M.train(rows.slice(0, 50), { now }).ok, false);
  assert.match(M.train(rows.slice(0, 50), { now }).reason, /Needs 200 riders/);
  assert.equal(M.train(rows.map((r) => ({ ...r, y: 0 })), { now }).ok, false, 'one outcome only: no model');
  const m = M.train(rows, { now });
  assert.equal(m.ok, true);
  assert.ok(m.auc >= 0.8, `held-out AUC ${m.auc}`);
  assert.equal(m.w.length, M.FEATURES.length + 1);
  const gone = M.predict(m, { recencyDays: 70, rideDays30: 0, rideDaysPrev60: 1, tenureWeeks: 28, groupShare: 0 });
  const keen = M.predict(m, { recencyDays: 1, rideDays30: 9, rideDaysPrev60: 15, tenureWeeks: 28, groupShare: 0 });
  assert.ok(gone.p > 0.7 && keen.p < 0.3, `${gone.p} vs ${keen.p}`);
  assert.ok(gone.factors.length >= 1 && gone.factors.length <= 3 && gone.factors.every((f) => typeof f.label === 'string' && f.weight > 0), 'top factors in plain words');
  // Noise: the model is refused (AUC below the threshold) and the rules stay alone.
  const noise = rows.map((r) => ({ f: r.f, y: rnd() < 0.5 ? 1 : 0 }));
  const bad = M.train(noise, { now });
  assert.equal(bad.ok, false); assert.match(bad.reason, /Not reliable enough/);
  // Bounded: never more than MAX_SAMPLES rows.
  const many = []; for (let i = 0; i < M.MAX_SAMPLES + 500; i++) many.push(rows[i % rows.length]);
  assert.equal(M.train(many, { now }).n, M.MAX_SAMPLES);
  assert.equal(M.auc([0.9, 0.8, 0.2, 0.1], [1, 1, 0, 0]), 1);
  assert.equal(M.auc([0.5, 0.5, 0.5, 0.5], [1, 0, 1, 0]), 0.5);
});

test('"At risk this week": the highest scores with their factors; consent decides who can be mailed; win-back goes through the wizard', async () => {
  // Drifting riders: rode a lot two months ago, nothing since.
  const drifting = [];
  for (let i = 0; i < 6; i++) {
    const rides = []; for (let d = 80; d > 45; d -= 4) rides.push(now - d * DAY);
    drifting.push(await seed.user({ username: `drift_${i}`, createdAt: now - 150 * DAY, rides, lastActiveAt: now - 35 * DAY, consent: i < 3, email: i === 2 ? 'not-an-address' : undefined }));
  }
  // One of the consenting riders unsubscribed (suppression list).
  await env.gw.notifications.offers.suppress(drifting[1].email, 'unsubscribe', 'test');
  // Active riders, a rider lost long ago, a plan ending soon for someone who stopped opening the app.
  for (let i = 0; i < 5; i++) await seed.user({ createdAt: now - 150 * DAY, rides: [now - DAY, now - 3 * DAY, now - 9 * DAY, now - 40 * DAY, now - 50 * DAY], lastActiveAt: now - 3600000 });
  await seed.user({ username: 'long_gone', createdAt: now - 400 * DAY, rides: [now - 170 * DAY], lastActiveAt: now - 160 * DAY });
  const planner = await seed.user({ username: 'plan_ending', createdAt: now - 100 * DAY, rides: [now - 33 * DAY], plan: { until: now + 4 * DAY }, lastActiveAt: now - 20 * DAY, consent: true });
  await env.gw.business.brain.runNightly({});

  const r = await env.api('GET', '/admin/business/churn', null, admin.token);
  assert.equal(r.status, 200);
  const names = r.json.riders.map((x) => x.username);
  for (let i = 0; i < 6; i++) assert.ok(names.includes(`drift_${i}`), `drift_${i} listed`);
  assert.ok(names.includes('plan_ending'));
  assert.ok(!names.includes('long_gone'), 'a rider gone for more than 120 days is lost, not "at risk this week"');
  assert.equal(r.json.total, 7);
  assert.ok(r.json.riders.every((x) => x.score >= 50 && x.factors.length >= 1 && x.factors.length <= 3 && x.factors.every((f) => f.label && f.points > 0)));
  assert.deepEqual(r.json.riders.map((x) => x.score), r.json.riders.map((x) => x.score).slice().sort((a, b) => b - a), 'highest first');
  assert.equal(r.json.model.active, false, 'too little history here: rules only, and it says so');
  assert.match(r.json.model.reason, /Needs 200 riders/);
  const pe = r.json.riders.find((x) => x.username === 'plan_ending');
  assert.ok(pe.factors.some((f) => f.key === 'plan' && /Plan ends in 4 days/.test(f.label)));
  // Consent rules: listed, but only consenting, valid, not suppressed riders can be mailed; the reason is shown.
  const by = Object.fromEntries(r.json.riders.map((x) => [x.username, x]));
  assert.equal(by.drift_0.mailable, true);
  assert.deepEqual([by.drift_1.mailable, by.drift_1.whyNot], [false, 'Unsubscribed or address blocked']);
  assert.deepEqual([by.drift_2.mailable, by.drift_2.whyNot], [false, 'No valid e-mail address']);
  assert.deepEqual([by.drift_4.mailable, by.drift_4.whyNot], [false, 'Has not agreed to offer e-mails']);
  assert.equal(JSON.stringify(r.json).includes('@coroute.test'), false, 'no e-mail address in the list');
  // The stored aggregate has ids and numbers only.
  const stored = (await env.soda.findOne('business_agg', { k: 'churn' })).value;
  assert.deepEqual(Object.keys(stored.atRisk[0]).sort(), ['factors', 'lastOpenAt', 'lastRideAt', 'planEndsAt', 'score', 'userId']);

  // Win-back: nothing is sent by this call; it hands the wizard the mailable usernames and the win-back starter.
  const before = sent.length;
  const w = await env.api('POST', '/admin/business/churn/winback', {}, admin.token);
  assert.equal(w.status, 200);
  assert.deepEqual(w.json.usernames.sort(), ['drift_0', 'plan_ending']);
  assert.deepEqual({ mailable: w.json.mailable, notMailable: w.json.notMailable, starter: w.json.starter, category: w.json.category }, { mailable: 2, notMailable: 5, starter: 'winback_coupon', category: 'marketing' });
  assert.equal(sent.length, before);
  const one = await env.api('POST', '/admin/business/churn/winback', { userIds: [drifting[4].userId] }, admin.token);
  assert.deepEqual(one.json.usernames, [], 'a rider without consent is never handed over');

  // The wizard's own campaign path applies consent again at send time, even if every username is pasted in.
  const all = r.json.riders.map((x) => x.username);
  const camp = await env.api('POST', '/admin/email/studio/campaigns', { audience: { kind: 'usernames', usernames: all }, category: 'marketing',
    design: { subject: 'We miss you', preheader: '', blocks: [{ type: 'text', text: 'Come ride with us again.' }, { type: 'footer', note: '' }] } }, admin.token);
  assert.equal(camp.status, 201, JSON.stringify(camp.json));
  const studio = env.gw.notifications.studio;
  studio.isQuiet = () => false;
  await studio.tick();
  const to = sent.slice(before).map((m) => m.to).sort();
  assert.deepEqual(to, [drifting[0].email, planner.email].sort(), 'only the riders who agreed to offer e-mails got it');
});

test('account erase removes the rider from the business data', async () => {
  const u = await seed.user({ username: 'erase_me', createdAt: now - 150 * DAY, rides: [now - 50 * DAY, now - 60 * DAY, now - 64 * DAY], lastActiveAt: now - 40 * DAY });
  const brain = env.gw.business.brain;
  brain.observeOpen(u.userId, now - 3600000);
  await brain.runNightly({});
  assert.ok(await env.soda.findOne('business_riders', { userId: u.userId }));
  const row = await env.soda.findOne('users', { userId: u.userId });
  await env.gw.repo.deleteUserCascade({ ...row.value, key: row.key });
  assert.equal(await env.soda.findOne('business_riders', { userId: u.userId }), null);
  const list = await env.api('GET', '/admin/business/churn', null, admin.token);
  assert.ok(!list.json.riders.some((x) => x.userId === u.userId), 'a deleted rider is not shown even before the next nightly run');
});
