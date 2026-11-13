'use strict';
/**
 * Round 6 weekly owner summary: Monday 09:00 India time, once per week across nodes, to the MASTER_ADMIN addresses
 * through the gateway's mailer; plain language, counts only; the words are an editable template; a switch in Settings.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'owner.one@coroute.test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { seeder, monday, DAY, IST } = require('./_business_helpers');
const { isSummaryTime } = require('../src/business/summary');

const HOUR = 3600000;
let env; let admin; let rider; let now; const sent = [];
before(async () => {
  env = await boot({ mailTransport: { sendMail: async (m) => { sent.push(m); return { messageId: `m${sent.length}` }; } } });
  now = Date.now();
  admin = await env.register('Owner One', 'owner.one@coroute.test');
  rider = await env.register('Some Rider', 'some.rider@coroute.test');
  const seed = seeder(env.soda, now);
  for (let i = 0; i < 12; i++) await seed.user({ createdAt: now - (i < 4 ? 2 : 40) * DAY, rides: i < 7 ? [now - DAY, now - 2 * DAY] : null, lastActiveAt: now - (i < 9 ? 1 : 30) * DAY });
  const u = (await env.soda.findOne('users', { username: 'rider_1' })).value;
  await seed.order({ userId: u.userId, at: now - 2 * DAY, amountInPaise: 49900 });
  await seed.order({ userId: u.userId, at: now - 3 * DAY, amountInPaise: 19900, refundedInPaise: 19900, refunds: [{ at: now - 2 * DAY }] });
  // A second administrator account (role), a held administrator and an unverified one.
  await env.soda.insert('users', { userId: 'usr_admin2', name: 'Owner Two', email: 'owner.two@coroute.test', role: 'MASTER_ADMIN', status: 'ACTIVE', emailVerified: true, createdAt: now });
  await env.soda.insert('users', { userId: 'usr_admin3', name: 'Held', email: 'held.admin@coroute.test', role: 'MASTER_ADMIN', status: 'ON_HOLD', emailVerified: true, createdAt: now });
  await env.soda.insert('users', { userId: 'usr_admin4', name: 'Unverified', email: 'unverified.admin@coroute.test', role: 'MASTER_ADMIN', status: 'ACTIVE', emailVerified: false, createdAt: now });
  // Alerts of the week: 2 SOS (one handled, one false alarm), 1 crash still open; one older alert.
  const al = (o) => env.soda.insert('alerts', { alertId: `SOS-${Math.random()}`, groupId: 'GRP-X', userId: u.userId, userName: 'Private Name', timestamp: now - DAY, resolved: false, ...o });
  await al({ auto: false, resolved: true, status: 'RESOLVED' }); await al({ auto: false, resolved: true, status: 'FALSE_ALARM' }); await al({ auto: true, status: 'ACTIVE' });
  await al({ auto: true, timestamp: now - 20 * DAY, resolved: true, status: 'RESOLVED' });
  await env.gw.business.brain.runNightly({});
});
after(async () => { await env.gw.shutdown(); });

const mondayAt = (hour, weeksAhead = 1) => monday(now, -weeksAhead) - 12 * HOUR + hour * HOUR;

test('when: Monday from 09:00 India time only', () => {
  assert.equal(isSummaryTime(mondayAt(8) + 59 * 60000), false);
  assert.equal(isSummaryTime(mondayAt(9)), true);
  assert.equal(isSummaryTime(mondayAt(23)), true);
  assert.equal(isSummaryTime(mondayAt(9) + DAY), false, 'Tuesday');
  assert.equal(isSummaryTime(mondayAt(9) - DAY), false, 'Sunday');
  assert.equal(new Date(mondayAt(9) + IST).getUTCDay(), 1);
});

test('sent once per week to the administrators, in plain language, counts only', async () => {
  const summary = env.gw.business.summary;
  sent.length = 0;
  assert.deepEqual(await summary.tick(mondayAt(8)), { skipped: 'NOT_TIME' });
  assert.equal(sent.length, 0);
  // Two nodes tick at the same moment: one sends.
  const [a, b] = await Promise.all([summary.tick(mondayAt(9)), summary.tick(mondayAt(9))]);
  assert.equal([a, b].filter((x) => x.sent === 2).length, 1, JSON.stringify([a, b]));
  assert.equal([a, b].filter((x) => x.skipped).length, 1);
  assert.deepEqual(sent.map((m) => m.to).sort(), ['owner.one@coroute.test', 'owner.two@coroute.test'], 'active, verified MASTER_ADMIN accounts and BOOTSTRAP_ADMIN_EMAILS; never a rider');
  assert.deepEqual(await summary.tick(mondayAt(10)), { skipped: 'ALREADY_SENT' });
  assert.deepEqual(await summary.tick(mondayAt(15)), { skipped: 'ALREADY_SENT' });
  assert.equal(sent.length, 2);
  const m = sent[0];
  assert.match(m.subject, /^CoRoute last week: \d+ riders active, ₹499$/);
  assert.match(m.text, /10 riders opened the app in the last 7 days, out of 13\. 5 new riders signed up\./);
  assert.match(m.text, /7 riders rode, on 14 ride days in total\./);
  assert.match(m.text, /2 SOS alerts and 1 crash alert: 1 closed as handled, 1 false alarm, 0 cancelled, 1 still open\./);
  assert.match(m.text, /Revenue: ₹499 net from 2 paid orders \(after ₹199 refunded\)\./);
  assert.match(m.text, /at-risk list/);
  assert.match(m.text, /Servers: (healthy|need a look|need attention now)\./);
  assert.match(m.text, /\/admin#\/business/);
  assert.doesNotMatch(m.text + m.html, /Private Name|some\.rider|rider_1|usr_b/, 'no rider names, addresses or ids');
  assert.doesNotMatch(m.html, /<script|javascript:/i);
  // Next Monday it goes out again.
  const next = await summary.tick(mondayAt(9, 2));
  assert.equal(next.sent, 2);
});

test('the switch in Settings turns it off and on (audited); mail off or analytics off: nothing is sent', async () => {
  const summary = env.gw.business.summary;
  const s = await env.api('GET', '/admin/business/settings', null, admin.token);
  assert.deepEqual({ weeklySummary: s.json.weeklySummary, mailConfigured: s.json.mailConfigured, recipients: s.json.recipients, sendsAt: s.json.sendsAt }, { weeklySummary: true, mailConfigured: true, recipients: 2, sendsAt: 'Monday 09:00 India time' });
  assert.equal((await env.api('PUT', '/admin/business/settings', { weeklySummary: 'no' }, admin.token)).status, 400);
  assert.equal((await env.api('PUT', '/admin/business/settings', { weeklySummary: false }, admin.token)).json.weeklySummary, false);
  sent.length = 0;
  assert.deepEqual(await summary.tick(mondayAt(9, 3)), { skipped: 'SWITCHED_OFF' });
  assert.equal(sent.length, 0);
  assert.equal((await env.api('PUT', '/admin/business/settings', { weeklySummary: true }, admin.token)).json.weeklySummary, true);
  assert.equal((await summary.tick(mondayAt(9, 3))).sent, 2);
  assert.equal((await env.soda.query('subscription_config', { k: 'audit', action: 'business.settings' }, { limit: 10 })).length, 2);
  const mailer = summary.mailer; summary.mailer = { enabled: false };
  assert.deepEqual(await summary.tick(mondayAt(9, 4)), { skipped: 'MAIL_OFF' });
  summary.mailer = mailer;
});

test('the words are an editable template; preview and "send me a test" (to the caller only)', async () => {
  const list = await env.api('GET', '/admin/templates', null, admin.token);
  const t = (list.json.templates || list.json).find((x) => x.id === 'owner_weekly_summary');
  assert.ok(t, 'listed under Settings > Templates');
  assert.deepEqual(t.variables.map((v) => v.name), ['week', 'activeRiders', 'newRiders', 'revenue', 'atRisk', 'adminUrl']);
  const save = await env.api('PUT', '/admin/templates/owner_weekly_summary', { fields: { ...t.current, subject: 'Weekly numbers: {{activeRiders}} active', heading: 'Hello owner' } }, admin.token);
  assert.equal(save.status, 200, JSON.stringify(save.json));
  const bad = await env.api('PUT', '/admin/templates/owner_weekly_summary', { fields: { ...t.current, subject: 'Hi {{riderEmail}}' } }, admin.token);
  assert.equal(bad.status, 400, 'an unknown variable is refused');
  env.gw.notifications.templates.cache && env.gw.notifications.templates.cache.clear && env.gw.notifications.templates.cache.clear();
  const p = await env.api('GET', '/admin/business/summary/preview', null, admin.token);
  assert.equal(p.status, 200);
  assert.match(p.json.subject, /^Weekly numbers: \d+ active$/);
  assert.match(p.json.text, /^Hello owner\n/);
  sent.length = 0;
  const test1 = await env.api('POST', '/admin/business/summary/test', {}, admin.token);
  assert.deepEqual({ sent: test1.json.sent, recipients: test1.json.recipients }, { sent: 1, recipients: 1 });
  assert.deepEqual(sent.map((m) => m.to), ['owner.one@coroute.test']);
  assert.equal((await env.api('POST', '/admin/business/summary/test', {}, rider.token)).status, 403);
});
