'use strict';
/**
 * r314 behaviour/safety tester regressions:
 * 1. The same SOS (same clientId) arriving twice at once (double press, upgrade to CRASH, resend
 *    after reconnect) must open ONE alert. The medical read added in 3.14 widened the window.
 * 2. A whole group stopping at a red light or a toll queue must not page the lead with a
 *    "possible incident" for every rider; a rider who stops alone still gets it after 2 min.
 * 3. Medical info and phone numbers never reach the admin emergencies feed, and the roster
 *    endpoint stays private (other convoy, opted out, rate limit).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.WS_ALARMS_PER_10S = '20';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'behadmin@coroute.test';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');

const T0 = Date.now();
mock.timers.enable({ apis: ['Date'], now: T0 });
const { boot } = require('./_helpers');

let t;
let clock = T0;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); mock.timers.reset(); });

const at = (ms) => { clock = ms; mock.timers.setTime(ms); };
const later = (ms) => at(clock + ms);
const latAt = (km) => 17 + km / 111.195;
const pause = (ms) => new Promise((res) => setTimeout(res, ms));

async function ride(tag, n = 5) {
  const names = ['Lead', 'Asha', 'Bala', 'Chitra', 'Dev', 'Esha'].slice(0, n);
  const users = [];
  for (const nm of names) users.push(await t.register(`${nm} ${tag}`, `${nm.toLowerCase()}.${tag}@coroute.test`));
  const [lead, ...others] = users;
  const c = (await t.api('POST', '/convoys', {
    name: `Behaviour ${tag}`, start: { lat: latAt(0), lng: 78.4, name: 'Start' },
    destination: 'End', destLat: latAt(100), destLng: 78.4,
  }, lead.token)).json;
  for (const u of others) assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
  const room = await t.gw.convoys.getRoom(c.groupId);
  room.meta.tripStatus = 'STARTED';
  const fix = async (u, km, kmh, extra = {}) => {
    t.gw.convoys.patchRider(room, u.user.userId, { lat: latAt(km), lng: 78.4, speedKmh: kmh, ...extra }, { emit: false });
    await t.gw.timeline.idle();
  };
  const events = async (type) => (await t.gw.repo.listEvents(c.groupId)).filter((e) => e.type === type);
  return { c, room, users, lead, others, fix, events };
}

test('the same SOS clientId sent twice at once opens one alert (in-flight dedupe)', async () => {
  const r = await ride('dup', 3);
  const [a] = r.others;
  const wa = await t.joinRoom(a.token, r.c.groupId);
  const wl = await t.joinRoom(r.lead.token, r.c.groupId);
  const msg = { type: 'SOS', lat: 17.1, lng: 78.4, alertType: 'EMERGENCY', clientId: `${a.user.userId}-1` };
  wa.sendJson(msg);
  wa.sendJson({ ...msg, alertType: 'CRASH', auto: true });
  wa.sendJson(msg);
  await wl.next((m) => m.type === 'ALERT');
  await pause(300);
  const stored = (await t.gw.repo.listAlerts(r.c.groupId)).filter((x) => x.userId === a.user.userId);
  assert.equal(stored.length, 1, 'one alert for one clientId');
  assert.equal(wl.inbox.filter((m) => m.type === 'ALERT').length, 0, 'the group heard it once');
  const dups = wa.inbox.filter((m) => m.type === 'ALERT' && m.duplicate === true);
  assert.equal(dups.length, 2, 'each repeat is answered to the sender as a duplicate');
  assert.ok(dups.every((d) => d.alert.alertId === stored[0].alertId));
  wa.close(); wl.close();
});

test('a group stopped together at a red light or toll queue: no possible incident after 2 min; a rider alone still gets one', async () => {
  const r = await ride('signal', 5);
  at(T0 + 3600000);
  // Everyone rides at 50 km/h in a bunch around km 10, then stops hard at the same signal.
  for (const u of r.users) await r.fix(u, 10, 50);
  later(4000);
  for (const [i, u] of r.users.entries()) await r.fix(u, 10.06 + i * 0.008, 3);
  for (let s = 0; s < 5; s++) {
    later(30000);
    for (const [i, u] of r.users.entries()) await r.fix(u, 10.06 + i * 0.008, 0);
    await t.gw.timeline.tick();
    await t.gw.timeline.idle();
  }
  assert.equal((await r.events('POSSIBLE_INCIDENT')).length, 0, '2.5 min at a red light with the group: nothing');

  // Light turns green; later one rider (Asha) hard-stops alone 3 km behind and stays still.
  later(10000);
  for (const u of r.users) await r.fix(u, 12, 50);
  const asha = r.others[0];
  later(3000);
  for (const u of r.users) if (u !== asha) await r.fix(u, 15, 50);
  await r.fix(asha, 12.05, 0);
  for (let s = 0; s < 5; s++) {
    later(30000);
    for (const u of r.users) if (u !== asha) await r.fix(u, 15 + (s + 1) * 0.4, 50);
    await t.gw.timeline.tick();
    await t.gw.timeline.idle();
  }
  const inc = await r.events('POSSIBLE_INCIDENT');
  assert.equal(inc.length, 1);
  assert.equal(inc[0].userId, asha.user.userId);
  assert.ok(inc[0].data.notify.includes(r.lead.user.userId));
});

test('stopped with the group for a long time (5 min) still opens it: a crash with riders around is not hidden forever', async () => {
  const r = await ride('crowd', 3);
  at(T0 + 2 * 3600000);
  const [a, b] = r.others;
  await r.fix(r.lead, 30, 40);
  await r.fix(a, 20, 60);
  await r.fix(b, 19.98, 55);
  later(3000);
  await r.fix(a, 20.03, 0);
  await r.fix(b, 20.02, 0); // B stops right beside A
  for (let s = 0; s < 11; s++) {
    later(30000);
    await r.fix(r.lead, 30 + (s + 1) * 0.4, 40);
    await r.fix(b, 20.02, 0);
    await r.fix(a, 20.03, 0);
    await t.gw.timeline.tick();
    await t.gw.timeline.idle();
  }
  const inc = await r.events('POSSIBLE_INCIDENT');
  assert.ok(inc.some((e) => e.userId === a.user.userId), 'opened after the longer group time');
});

test('admin emergencies feed: who, where, responders; never medical info or phone numbers', async () => {
  const r = await ride('feed', 3);
  const [a, b] = r.others;
  assert.equal((await t.api('PATCH', '/me', { bloodGroup: 'B+', allergies: 'Peanuts', medicalNotes: 'Diabetic' }, a.token)).status, 200);
  const admin = await t.register('Beh Admin', 'behadmin@coroute.test');
  const wa = await t.joinRoom(a.token, r.c.groupId);
  const wb = await t.joinRoom(b.token, r.c.groupId);
  wa.sendJson({ type: 'SOS', lat: 17.2, lng: 78.4, alertType: 'CRASH', auto: true, speedBeforeKmh: 62, clientId: 'feed-1' });
  const al = (await wb.next((m) => m.type === 'ALERT')).alert;
  assert.equal(al.medical.bloodGroup, 'B+', 'the group sees it while open');
  wb.sendJson({ type: 'SOS_RESPOND', alertId: al.alertId, kind: 'GOING', clientId: 'resp-1' });
  await wb.next((m) => m.type === 'ACK' && m.clientId === 'resp-1');
  const res = await t.api('GET', '/admin/emergencies', null, admin.token);
  assert.equal(res.status, 200);
  const e = res.json.emergencies.find((x) => x.alertId === al.alertId);
  assert.ok(e);
  assert.equal(e.alertType, 'CRASH');
  assert.equal(e.auto, true);
  assert.equal(e.responders.length, 1);
  const raw = JSON.stringify(res.json);
  for (const s of ['Peanuts', 'Diabetic', 'B+', 'medical', '+91', '98765', '9000000001']) {
    assert.ok(!raw.includes(s), `admin feed leaks ${s}`);
  }
  // A rider is not an admin.
  assert.equal((await t.api('GET', '/admin/emergencies', null, a.token)).status, 403);
  // Roster: a rider of another convoy gets 403; numbers of opted-out riders are absent.
  const other = await ride('feed2', 2);
  assert.equal((await t.api('GET', `/convoys/${r.c.groupId}/emergency-roster`, null, other.others[0].token)).status, 403);
  assert.equal((await t.api('PATCH', '/me', { smsOptOut: true }, b.token)).status, 200);
  const roster = await t.api('GET', `/convoys/${r.c.groupId}/emergency-roster`, null, a.token);
  assert.equal(roster.status, 200);
  assert.ok(!roster.json.members.some((m) => m.userId === b.user.userId), 'opted out: not shared');
  assert.ok(!roster.json.members.some((m) => m.userId === a.user.userId), 'never the caller');
  assert.ok(roster.json.members.every((m) => Object.keys(m).sort().join() === 'phone,role,userId'), 'no names or other fields');
  assert.equal(roster.headers.get('cache-control'), 'no-store');
  // Resolve: medical gone from the stored alert.
  wa.sendJson({ type: 'SOS_RESOLVE', alertId: al.alertId });
  await wb.next((m) => m.type === 'ALERT_RESOLVED');
  await pause(50);
  const stored = (await t.gw.repo.listAlerts(r.c.groupId, { includeResolved: true })).find((x) => x.alertId === al.alertId);
  assert.equal(stored.resolved, true);
  assert.equal(stored.medical, undefined);
  wa.close(); wb.close();
});

test('outbox: the same CHAT and WAIT clientId sent twice at once (old and new socket) is applied once', async () => {
  const r = await ride('cid', 3);
  const [a] = r.others;
  const w1 = await t.joinRoom(a.token, r.c.groupId);
  const w2 = await t.joinRoom(a.token, r.c.groupId); // the new socket after a reconnect
  const wl = await t.joinRoom(r.lead.token, r.c.groupId);
  const chat = { type: 'CHAT', text: 'Fuel stop ahead', clientId: 'o1-1-ab', sentAt: Date.now() };
  w1.sendJson(chat);
  w2.sendJson(chat);
  w1.sendJson({ type: 'WAIT', clientId: 'o1-2-ab' });
  w2.sendJson({ type: 'WAIT', clientId: 'o1-2-ab' });
  const acks = [];
  for (const id of ['o1-1-ab', 'o1-2-ab']) {
    acks.push(await w1.next((m) => m.type === 'ACK' && m.clientId === id));
    acks.push(await w2.next((m) => m.type === 'ACK' && m.clientId === id));
  }
  assert.equal(acks.filter((x) => x.duplicate === false).length, 2, 'one real apply per clientId');
  await pause(150);
  const room = await t.gw.convoys.getRoom(r.c.groupId);
  assert.equal(room.messages.filter((m) => m.clientId === 'o1-1-ab').length, 1);
  const msgs = wl.inbox.filter((m) => m.type === 'MESSAGE');
  assert.equal(msgs.filter((m) => m.message.clientId === 'o1-1-ab').length, 1, 'the group got the chat once');
  assert.equal(msgs.filter((m) => m.message.cardType === 'WAIT_2MIN').length, 1, 'one wait request');
  w1.close(); w2.close(); wl.close();
});
