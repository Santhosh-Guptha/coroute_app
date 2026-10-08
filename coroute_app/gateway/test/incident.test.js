'use strict';
/**
 * 3.14 server safety rules: possible incident (hard stop, then still) and the no-signal escalation.
 * Time is simulated (Date is mocked); telemetry is applied through ConvoyManager.patchRider.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000'; // ticks are driven by the test
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.INCIDENT_STILL_S = '1';
process.env.INCIDENT_STOP_WITHIN_S = '15';
process.env.WS_ALARMS_PER_10S = '20';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');

const T0 = Date.now();
mock.timers.enable({ apis: ['Date'], now: T0 });
const { boot } = require('./_helpers');

let t;
let clock = T0;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); mock.timers.reset(); });

const latAt = (km) => 17 + km / 111.195;
const at = (ms) => { clock = ms; mock.timers.setTime(ms); };
const later = (ms) => at(clock + ms);

/** Lead + six riders, a planned fuel stop at km 20 and the destination at km 100. */
async function ride(tag) {
  const names = ['Lead', 'Asha', 'Bala', 'Chitra', 'Dev', 'Esha', 'Farah'];
  const users = [];
  for (const n of names) users.push(await t.register(`${n} ${tag}`, `${n.toLowerCase()}.${tag}@coroute.test`));
  const [lead, ...others] = users;
  const c = (await t.api('POST', '/convoys', {
    name: `Incident ${tag}`, start: { lat: latAt(0), lng: 78.4, name: 'Start' },
    destination: 'End', destLat: latAt(100), destLng: 78.4,
    stops: [{ name: 'Fuel', lat: latAt(20), lng: 78.4, category: 'FUEL' }],
  }, lead.token)).json;
  for (const u of others) assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
  const room = await t.gw.convoys.getRoom(c.groupId);
  const fix = async (u, km, kmh, extra = {}) => {
    t.gw.convoys.patchRider(room, u.user.userId, { lat: latAt(km), lng: 78.4, speedKmh: kmh, ...extra }, { emit: false });
    await t.gw.timeline.idle();
  };
  const open = async (type, uid) => (await t.gw.repo.listOpenEvents(c.groupId)).filter((e) => e.type === type && (!uid || e.userId === uid));
  const events = async (type, uid) => (await t.gw.repo.listEvents(c.groupId)).filter((e) => e.type === type && (!uid || e.userId === uid));
  return { c, room, lead, users, A: others[0], B: others[1], C: others[2], D: others[3], E: others[4], F: others[5], fix, open, events };
}

test('a hard stop from 60 km/h, then still: possible incident for the lead and the two nearest riders; moving on closes it', async () => {
  const r = await ride('hard');
  at(T0 + 60000);
  await r.fix(r.lead, 0, 40);
  await r.fix(r.B, 2, 40);
  await r.fix(r.C, 9, 40);
  await r.fix(r.D, 11, 40);
  await r.fix(r.E, 30, 40);
  await r.fix(r.F, 50, 40);
  await r.fix(r.A, 10, 60);
  later(5000);
  await r.fix(r.A, 10.05, 0);
  assert.equal((await r.open('POSSIBLE_INCIDENT')).length, 0, 'not before the still time');
  later(1500);
  await r.fix(r.A, 10.0501, 0);
  const [inc] = await r.open('POSSIBLE_INCIDENT', r.A.user.userId);
  assert.ok(inc, 'opened');
  assert.equal(inc.slot, `INCIDENT:${r.A.user.userId}`);
  assert.equal(inc.data.fromKmh, 60);
  assert.equal(inc.data.reason, 'HARD_STOP');
  assert.equal(inc.data.auto, true);
  assert.deepEqual(inc.data.notify, [r.lead.user.userId, r.D.user.userId, r.C.user.userId], 'lead first, then the two nearest');
  // One per hard stop.
  later(5000);
  await r.fix(r.A, 10.0501, 0);
  assert.equal((await r.events('POSSIBLE_INCIDENT')).length, 1);
  // Moving on closes it.
  later(5000);
  await r.fix(r.A, 10.2, 25);
  const [closed] = await r.events('POSSIBLE_INCIDENT', r.A.user.userId);
  assert.equal(closed.open, false);
  assert.equal(closed.data.result, 'MOVED');
});

test('no possible incident for a gentle stop, near a planned stop, or with a status set', async () => {
  const r = await ride('none');
  at(T0 + 3600000);
  for (const u of [r.lead, r.B, r.C]) await r.fix(u, 0, 30);
  // Gentle: the last fast fix is 20 s before the stop.
  await r.fix(r.A, 40, 60);
  later(20000);
  await r.fix(r.A, 40.1, 0);
  later(3000);
  await r.fix(r.A, 40.1, 0);
  // Near the fuel stop (km 20).
  await r.fix(r.B, 19.9, 70);
  later(3000);
  await r.fix(r.B, 19.95, 2);
  later(3000);
  await r.fix(r.B, 19.95, 0);
  // Status set (the rider said why they stopped).
  await r.fix(r.C, 60, 70);
  later(3000);
  await r.fix(r.C, 60.03, 0, { statusReason: 'NATURE_BREAK' });
  later(3000);
  await r.fix(r.C, 60.03, 0);
  await t.gw.timeline.tick();
  await t.gw.timeline.idle();
  assert.equal((await r.events('POSSIBLE_INCIDENT')).length, 0);
});

test('the tick opens an incident for a rider whose phone stopped reporting after the hard stop', async () => {
  const r = await ride('tick');
  at(T0 + 2 * 3600000);
  await r.fix(r.lead, 0, 30);
  await r.fix(r.A, 70, 80);
  later(4000);
  await r.fix(r.A, 70.05, 3);
  later(10000);
  await t.gw.timeline.tick();
  await t.gw.timeline.idle();
  const [inc] = await r.open('POSSIBLE_INCIDENT', r.A.user.userId);
  assert.ok(inc);
  assert.equal(inc.data.fromKmh, 80);
});

test('CHECK_IN OK closes the incident and logs CHECK_IN; an SOS closes it with result SOS', async () => {
  const r = await ride('close');
  at(T0 + 3 * 3600000);
  await r.fix(r.lead, 0, 30);
  const wa = await t.joinRoom(r.A.token, r.c.groupId);
  const wl = await t.joinRoom(r.lead.token, r.c.groupId);
  const hardStop = async (u, km) => {
    await r.fix(u, km, 60);
    later(3000);
    await r.fix(u, km + 0.03, 0);
    later(2000);
    await r.fix(u, km + 0.03, 0);
  };
  await hardStop(r.A, 50);
  assert.equal((await r.open('POSSIBLE_INCIDENT', r.A.user.userId)).length, 1);
  const pushed = await wl.next((m) => m.type === 'TIMELINE' && m.event.type === 'POSSIBLE_INCIDENT');
  assert.equal(pushed.event.slot, undefined, 'slot is server only');

  wa.sendJson({ type: 'CHECK_IN', result: 'OK', clientId: 'ok-1' });
  const ack = await wa.next((m) => m.type === 'ACK' && m.clientId === 'ok-1');
  assert.equal(ack.duplicate, false);
  const [inc] = await r.events('POSSIBLE_INCIDENT', r.A.user.userId);
  assert.equal(inc.open, false);
  assert.equal(inc.data.result, 'OK');
  const checks = await r.events('CHECK_IN', r.A.user.userId);
  assert.equal(checks.length, 1);
  assert.deepEqual(checks[0].data, { result: 'OK' });
  // OK with nothing open writes nothing.
  wa.sendJson({ type: 'CHECK_IN', result: 'OK' });
  await new Promise((res) => setTimeout(res, 50));
  await t.gw.timeline.idle();
  assert.equal((await r.events('CHECK_IN', r.A.user.userId)).length, 1);

  // A second hard stop; this time the rider raises an SOS.
  later(10000);
  await r.fix(r.A, 51, 40);
  await hardStop(r.A, 52);
  assert.equal((await r.open('POSSIBLE_INCIDENT', r.A.user.userId)).length, 1);
  wa.sendJson({ type: 'SOS', lat: latAt(52.03), lng: 78.4, alertType: 'CRASH' });
  await wl.next((m) => m.type === 'ALERT');
  await t.gw.timeline.idle();
  const all = await r.events('POSSIBLE_INCIDENT', r.A.user.userId);
  assert.equal(all.length, 2);
  assert.ok(all.every((e) => !e.open));
  assert.ok(all.some((e) => e.data.result === 'SOS'));
  // With the SOS open, a new hard stop does not open another incident.
  later(10000);
  await r.fix(r.A, 53, 40);
  await hardStop(r.A, 54);
  assert.equal((await r.open('POSSIBLE_INCIDENT', r.A.user.userId)).length, 0);
  wa.close(); wl.close();
});

test('CHECK_IN NO_REPLY opens NO_REPLY once; OK closes it; bad results are refused', async () => {
  const r = await ride('reply');
  at(T0 + 4 * 3600000);
  await r.fix(r.B, 30, 40);
  const wb = await t.joinRoom(r.B.token, r.c.groupId);
  wb.sendJson({ type: 'CHECK_IN', result: 'NO_REPLY', awayM: 2500.7, clientId: 'nr-1' });
  await wb.next((m) => m.type === 'ACK' && m.clientId === 'nr-1');
  wb.sendJson({ type: 'CHECK_IN', result: 'NO_REPLY', awayM: 9999999 });
  await new Promise((res) => setTimeout(res, 50));
  await t.gw.timeline.idle();
  const nr = await r.events('NO_REPLY', r.B.user.userId);
  assert.equal(nr.length, 1, 'idempotent while open');
  assert.equal(nr[0].open, true);
  assert.deepEqual(nr[0].data, { awayM: 2501 });
  wb.sendJson({ type: 'CHECK_IN', result: 'MAYBE', clientId: 'bad-1' });
  const err = await wb.next((m) => m.type === 'ERROR');
  assert.equal(err.code, 400);
  assert.equal(err.clientId, 'bad-1');
  wb.sendJson({ type: 'CHECK_IN', result: 'OK' });
  await new Promise((res) => setTimeout(res, 50));
  await t.gw.timeline.idle();
  const [closed] = await r.events('NO_REPLY', r.B.user.userId);
  assert.equal(closed.open, false);
  assert.equal(closed.data.result, 'OK');
  assert.equal((await r.events('CHECK_IN', r.B.user.userId)).length, 1);
  wb.close();
});

test('no signal: escalated after 10 min above 30 km/h, away from stops; not for slow riders, at a stop, or when the app was closed', async () => {
  const r = await ride('nosig');
  at(T0 + 5 * 3600000);
  for (const u of r.users) await r.fix(u, 1, 20); // everyone fresh
  await r.fix(r.A, 40, 62); // fast, away from stops
  await r.fix(r.B, 41, 20); // slow
  await r.fix(r.C, 20.05, 50); // at the fuel stop
  const wd = await t.joinRoom(r.D.token, r.c.groupId);
  await r.fix(r.D, 45, 70);
  wd.sendJson({ type: 'BYE', reason: 'APP_CLOSED' });
  await new Promise((res) => setTimeout(res, 30));
  wd.close();
  await new Promise((res) => setTimeout(res, 80));
  await t.gw.timeline.idle();
  const [closedApp] = await r.open('OFFLINE', r.D.user.userId);
  assert.equal(closedApp.data.cause, 'APP_CLOSED', 'opened at once');

  // Everyone else keeps reporting.
  const keepAlive = async () => { for (const u of [r.lead, r.E, r.F]) await r.fix(u, 1, 20); };
  later(6 * 60000);
  await keepAlive();
  await t.gw.timeline.tick();
  await t.gw.timeline.idle();
  const [offA] = await r.open('OFFLINE', r.A.user.userId);
  assert.equal(offA.data.cause, 'NO_SIGNAL');
  assert.ok(!offA.data.escalated, 'not before 10 min');
  later(5 * 60000);
  await keepAlive();
  await t.gw.timeline.tick();
  await t.gw.timeline.idle();
  const byUser = async (u) => (await r.open('OFFLINE', u.user.userId))[0];
  const a = await byUser(r.A);
  assert.equal(a.data.escalated, true);
  assert.equal(a.data.lastKmh, 62);
  assert.ok(!(await byUser(r.B)).data.escalated, 'slow rider: not escalated');
  assert.ok(!(await byUser(r.C)).data.escalated, 'at a planned stop: not escalated');
  assert.ok(!(await byUser(r.D)).data.escalated, 'app closed: not escalated');
  // Back online closes it (existing rule).
  await r.fix(r.A, 41, 50);
  const [back] = (await r.events('OFFLINE', r.A.user.userId));
  assert.equal(back.open, false);
  assert.equal(back.data.escalated, true);
});
