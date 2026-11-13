'use strict';
/**
 * Round 6 best send time: an hour-of-week histogram of app opens and e-mail clicks per rider -> a preferred hour;
 * "Send at each rider's best time" in the e-mail wizard (a campaign with bestTime), always inside the quiet hours
 * rules; bounded memory for the open counter; batches written by any node and folded by the leased job.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'time.admin@coroute.test';
process.env.MAIL_POSTAL_ADDRESS = 'CoRoute, 1 Test Road, Hyderabad';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { seeder, DAY, IST } = require('./_business_helpers');
const { bestOf, addHist, hourOfWeek, OBS_MAX_USERS } = require('../src/business/brain');

const HOUR = 3600000;
/** Epoch ms of the given India-time hour on the day of `t`. */
const istAt = (t, hour) => Math.floor((t + IST) / DAY) * DAY - IST + hour * HOUR;

let env; let admin; let now; let seed; const sent = [];
before(async () => {
  env = await boot({ mailTransport: { sendMail: async (m) => { sent.push({ to: m.to, at: env.gw.notifications.studio.clock() }); return { messageId: `m${sent.length}` }; } } });
  now = Date.now();
  seed = seeder(env.soda, now);
  admin = await env.register('Time Admin', 'time.admin@coroute.test');
});
after(async () => { await env.gw.shutdown(); });

test('histogram maths: hour of week in India time, preferred bucket, minimum data, fading old habits', () => {
  assert.equal(hourOfWeek(Date.UTC(2026, 10, 9, 0, 0) - IST), 0, 'Monday 00:00 IST');
  assert.equal(hourOfWeek(Date.UTC(2026, 10, 15, 23, 30) - IST), 167, 'Sunday 23:30 IST');
  assert.equal(bestOf({ 20: 2, 44: 2 }), null, 'fewer than five events: no best time yet');
  assert.deepEqual(bestOf({ 20: 4, 44: 3, 68: 1 }), { how: 20, hour: 20, dow: 0, n: 8 });
  assert.equal(bestOf({ 19: 3, 43: 3, 67: 3, 8: 4 }).hour, 19, 'the hour of day summed over the week wins for the hour');
  let h = {};
  for (let i = 0; i < 100; i++) h = addHist(h, { 30: 5 });
  assert.ok(Object.values(h).reduce((s, v) => s + v, 0) <= 400, 'the histogram never grows without bound');
});

test('app opens: at most one per rider per hour, bounded memory, written as small batches and folded nightly', async () => {
  const brain = env.gw.business.brain;
  const u = await seed.user({ username: 'evening_rider', consent: true });
  const base = istAt(now - 20 * DAY, 20);
  for (let d = 0; d < 6; d++) { brain.observeOpen(u.userId, base + d * DAY); brain.observeOpen(u.userId, base + d * DAY + 60000); brain.observeOpen(u.userId, base + d * DAY + 120000); }
  assert.equal(brain.stats.opensSeen, 6, 'three opens in one hour count once');
  // Bounded: never more than OBS_MAX_USERS riders pending, the rest are dropped and counted.
  for (let i = 0; i < OBS_MAX_USERS + 50; i++) brain.observeOpen(`usr_flood_${i}`, now);
  assert.equal(brain.opens.size, OBS_MAX_USERS);
  assert.equal(brain.stats.opensDropped, 51);
  for (const k of [...brain.opens.keys()]) if (k.startsWith('usr_flood_')) brain.opens.delete(k);
  const written = await brain.flushOpens();
  assert.equal(written, 6);
  const batches = await env.soda.query('business_obs', {}, { limit: 10 });
  assert.equal(batches.length, 1);
  assert.ok(batches[0].value.o.every((e) => e.length === 3 && typeof e[1] === 'number'), 'rider id, hour of week, count: nothing else');
  await brain.runNightly({});
  assert.equal((await env.soda.query('business_obs', {}, { limit: 10 })).length, 0, 'folded batches are removed');
  const doc = (await env.soda.findOne('business_riders', { userId: u.userId })).value;
  assert.equal(doc.bestHour, 20);
  assert.deepEqual(Object.keys(doc).sort(), ['best', 'bestHour', 'casRev', 'hist', 'n', 'updatedAt', 'userId'].filter((k) => k !== 'casRev').sort(), 'a tiny document: id, histogram, best');
  assert.deepEqual([...(await brain.bestHours([u.userId, 'usr_unknown'])).entries()], [[u.userId, 20]]);
  const page = await env.api('GET', '/admin/business/sendtime', null, admin.token);
  assert.equal(page.json.sendtime.withBest, 1);
  assert.equal(page.json.sendtime.grid.length, 168);
  assert.equal(page.json.sendtime.hours[20], 1);
});

test('e-mail clicks count towards the best time (hashed user id, matched for consenting riders only)', async () => {
  const brain = env.gw.business.brain; const studio = env.gw.notifications.studio;
  const u = await seed.user({ username: 'lunch_clicker', consent: true });
  const t = istAt(now - 5 * DAY, 13);
  for (let i = 0; i < 3; i++) await env.soda.insert('email_events', { type: 'click', campaignId: 'ec_00000000000000000000', uh: studio.userHash(u.userId), path: '/plans', at: t + i * DAY });
  await brain.runNightly({});
  assert.equal((await brain.bestHours([u.userId])).get(u.userId), 13);
  const before = (await env.soda.findOne('business_riders', { userId: u.userId })).value.n;
  await brain.runNightly({});
  assert.equal((await env.soda.findOne('business_riders', { userId: u.userId })).value.n, before, 'a click is folded once (cursor)');
});

test('"Send at each rider\'s best time": each rider at their hour within 24 h, never in the quiet hours; unknown riders at once', async () => {
  const studio = env.gw.notifications.studio; const brain = env.gw.business.brain;
  const mk = async (name, hour) => {
    const u = await seed.user({ username: name, consent: true });
    if (hour !== null) { await env.soda.insert('business_riders', { userId: u.userId, hist: {}, best: hour, bestHour: hour, n: 9, updatedAt: now }); }
    return u;
  };
  const morning = await mk('bt_morning', 11); const evening = await mk('bt_evening', 19); const night = await mk('bt_night', 23); const unknown = await mk('bt_unknown', null);
  // A controllable clock: the campaign is created at 10:00 IST.
  let t = istAt(now + DAY, 10);
  studio.clock = () => t;
  studio.sleep = async () => {};
  sent.length = 0;
  const design = { subject: 'Ride this weekend', preheader: '', blocks: [{ type: 'text', text: 'Hello {firstName}.' }, { type: 'footer', note: '' }] };
  const res = await studio.createCampaign({ audience: { kind: 'usernames', usernames: ['bt_morning', 'bt_evening', 'bt_night', 'bt_unknown'] }, category: 'marketing', design, bestTime: true });
  assert.equal(res.campaign.bestTime, true);
  const id = res.campaign.campaignId;
  const status = async () => (await studio.getCampaign(id));
  await studio.tick();
  assert.deepEqual(sent.map((m) => m.to), [unknown.email], 'at 10:00 only the rider without a known hour gets it');
  let c = await status();
  assert.equal(c.status, 'SCHEDULED'); assert.equal(c.sendAt, istAt(t, 11), 'waits for the next rider\'s hour');
  assert.equal(c.dueAts, undefined, 'the schedule is not exposed');
  t = istAt(t, 10) + 30 * 60000; await studio.tick();
  assert.equal(sent.length, 1, '10:30: nobody is due');
  t = istAt(t, 11) + 60000; await studio.tick();
  assert.deepEqual(sent.map((m) => m.to), [unknown.email, morning.email]);
  t = istAt(t, 19) + 60000; await studio.tick();
  assert.deepEqual(sent.map((m) => m.to), [unknown.email, morning.email, evening.email]);
  // 23:00 is inside the quiet hours (21:00-09:00): nothing goes out; that rider gets it when they end (09:00 next day).
  t = istAt(t, 23) + 60000; await studio.tick();
  assert.equal(sent.length, 3, 'never in the quiet hours');
  c = await status();
  assert.equal(c.status, 'SCHEDULED');
  t = istAt(t + DAY, 9) + 60000; await studio.tick();
  assert.deepEqual(sent.map((m) => m.to), [unknown.email, morning.email, evening.email, night.email]);
  assert.equal(new Date(sent[3].at + IST).getUTCHours(), 9);
  c = await status();
  assert.equal(c.status, 'SENT'); assert.equal(c.stats.sent, 4); assert.equal(c.stats.timed, 3);
  // Consent is checked at send time for every rider, as for any campaign: a rider who withdrew gets nothing.
  sent.length = 0; t = istAt(t, 10);
  await env.gw.notifications.offers.setConsent(morning.userId, false, { source: 'test' });
  await studio.createCampaign({ audience: { kind: 'usernames', usernames: ['bt_morning', 'bt_evening'] }, category: 'marketing', design: { ...design, subject: 'Second' }, bestTime: true });
  for (const hr of [10, 11, 19]) { t = istAt(t, hr) + 60000; await studio.tick(); }
  assert.deepEqual(sent.map((m) => m.to), [evening.email]);
  // Without the business brain the option degrades to "send now".
  const keep = studio.sendTimes; studio.sendTimes = null;
  const plan = await studio._bestTimePlan(['a', 'b'], t, await studio.settings());
  assert.deepEqual(plan.dueAts, [t, t]); assert.equal(plan.timed, 0);
  studio.sendTimes = keep;
  void brain;
});

test('the wizard offers the option and the business page links to it', () => {
  const fs = require('fs'); const path = require('path');
  const wiz = fs.readFileSync(path.join(__dirname, '..', 'public', 'admin', 'email_wizard.js'), 'utf8');
  assert.match(wiz, /\['best', 'At each rider\\'s best time \(within 24 hours\)'\]/);
  assert.match(wiz, /if \(wz\.when === 'best'\) body\.bestTime = true;/);
  assert.match(wiz, /pre\.usernames/);
});
