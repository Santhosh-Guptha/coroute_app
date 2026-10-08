'use strict';
/**
 * 3.14 SOS extras: crash alerts (auto, speed before, impact, time), medical info shown only to
 * the ride group while the alert is open, and "I'm going" / "I'm with them" responders.
 */
process.env.NODE_ENV = 'test';
process.env.WS_ALARMS_PER_10S = '20';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.SOS_RESPONDERS_MAX = '2';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'sosadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

/** A convoy with a lead, a rider (with medical info) and two more riders, all joined over sockets. */
async function ride(tag) {
  const lead = await t.register(`Lead ${tag}`, `lead.${tag}@coroute.test`);
  const rider = await t.register(`Rider ${tag}`, `rider.${tag}@coroute.test`);
  const p1 = await t.register(`Pack ${tag}`, `pack.${tag}@coroute.test`);
  const p2 = await t.register(`Pack2 ${tag}`, `pack2.${tag}@coroute.test`);
  const med = await t.api('PATCH', '/me', { bloodGroup: 'o+', allergies: 'Penicillin', medicalNotes: 'Asthma inhaler in the left pocket' }, rider.token);
  assert.equal(med.status, 200, JSON.stringify(med.json));
  const c = (await t.api('POST', '/convoys', { name: `Safety ${tag}` }, lead.token)).json;
  for (const u of [rider, p1, p2]) assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
  const ws = {
    lead: await t.joinRoom(lead.token, c.groupId),
    rider: await t.joinRoom(rider.token, c.groupId),
    p1: await t.joinRoom(p1.token, c.groupId),
    p2: await t.joinRoom(p2.token, c.groupId),
  };
  return { c, lead, rider, p1, p2, ws, close: () => Object.values(ws).forEach((w) => w.close()) };
}

test('a crash SOS stores and echoes auto, speed before, impact and time; values are clamped', async () => {
  const r = await ride('crash');
  const before = Date.now();
  r.ws.rider.sendJson({
    type: 'SOS', lat: 17.3, lng: 78.4, alertType: 'crash', auto: true, speedBeforeKmh: 999, impactG: 6.234,
    occurredAt: Date.now() + 3600000, clientId: 'crash-1',
  });
  const got = await r.ws.lead.next((m) => m.type === 'ALERT');
  const a = got.alert;
  assert.equal(a.alertType, 'CRASH');
  assert.equal(a.auto, true);
  assert.equal(a.details.speedBeforeKmh, 300);
  assert.equal(a.details.impactG, 6.2);
  assert.ok(a.occurredAt <= Date.now() + 60000 && a.occurredAt >= before, `occurredAt ${a.occurredAt}`);
  assert.deepEqual(a.responders, []);
  assert.deepEqual(a.medical, { bloodGroup: 'O+', allergies: 'Penicillin', notes: 'Asthma inhaler in the left pocket' });
  const stored = (await t.gw.repo.listAlerts(r.c.groupId))[0];
  assert.equal(stored.auto, true);
  assert.deepEqual(stored.responders, {}, 'map in the database');

  // Retried with the same clientId: the sender gets the same alert back, in wire form.
  r.ws.rider.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4, alertType: 'CRASH', auto: true, clientId: 'crash-1' });
  const dup = await r.ws.rider.next((m) => m.type === 'ALERT' && m.duplicate === true);
  assert.equal(dup.alert.alertId, a.alertId);
  assert.ok(Array.isArray(dup.alert.responders));

  // Bad and odd values.
  r.ws.p1.sendJson({ type: 'SOS', lat: 1, lng: 1, alertType: 'crash!!<script>', speedBeforeKmh: 'fast', impactG: -3, occurredAt: 0 });
  const bad = (await r.ws.lead.next((m) => m.type === 'ALERT' && m.alert.userId === r.p1.user.userId)).alert;
  assert.equal(bad.alertType, 'EMERGENCY');
  assert.equal(bad.details.speedBeforeKmh, undefined);
  assert.equal(bad.details.impactG, 0);
  assert.ok(bad.occurredAt >= Date.now() - 6 * 3600000 - 5000, 'clamped to at most 6 h back');
  assert.equal(bad.auto, false);
  assert.equal(bad.medical, undefined, 'no medical info when the rider has none');
  r.close();
});

test('an SOS from an older app is unchanged apart from the new defaults', async () => {
  const r = await ride('old');
  r.ws.p2.sendJson({ type: 'SOS', lat: 12.9, lng: 77.6 });
  const a = (await r.ws.lead.next((m) => m.type === 'ALERT')).alert;
  assert.equal(a.alertType, 'EMERGENCY');
  assert.equal(a.auto, false);
  assert.deepEqual(a.details, {});
  assert.deepEqual(a.responders, []);
  assert.equal(a.lat, 12.9);
  assert.equal(a.resolved, false);
  r.ws.p2.sendJson({ type: 'SOS', lat: 12.9, lng: 77.6, alertType: 'MECHANICAL' });
  assert.equal((await r.ws.lead.next((m) => m.type === 'ALERT')).alert.alertType, 'MECHANICAL');
  r.close();
});

test('medical info goes to the room only, never to admins, the fleet feed or the timeline, and is gone after resolve', async () => {
  const r = await ride('med');
  const admin = await t.register('Sos Admin', 'sosadmin@coroute.test');
  const wa = await t.connect(admin.token);
  await wa.next((m) => m.type === 'HELLO');
  wa.sendJson({ type: 'ADMIN_SUBSCRIBE' });
  await wa.next((m) => m.type === 'FLEET');

  r.ws.rider.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4, alertType: 'CRASH', auto: true });
  const a = (await r.ws.p1.next((m) => m.type === 'ALERT')).alert;
  assert.equal(a.medical.allergies, 'Penicillin');

  // A new socket of a member gets it in the SNAPSHOT while the alert is open.
  const again = await t.joinRoom(r.p2.token, r.c.groupId);
  assert.equal(again.snapshot.activeAlerts[0].medical.bloodGroup, 'O+');
  again.close();

  const fleet = await wa.next((m) => m.type === 'FLEET' && m.convoys.some((c) => c.groupId === r.c.groupId && c.activeAlerts.length), 3000);
  assert.ok(!JSON.stringify(fleet).includes('Penicillin'), 'no medical info in FLEET');
  const fleetRest = await t.api('GET', '/admin/fleet', null, admin.token);
  assert.ok(!JSON.stringify(fleetRest.json).includes('Penicillin'));
  const em = await t.api('GET', '/admin/emergencies', null, admin.token);
  assert.equal(em.status, 200);
  const mine = em.json.emergencies.find((e) => e.alertId === a.alertId);
  assert.ok(mine, JSON.stringify(em.json));
  assert.equal(mine.alertType, 'CRASH');
  assert.equal(mine.auto, true);
  assert.equal(mine.convoyName, 'Safety med');
  assert.equal(mine.lead.userId, r.lead.user.userId);
  assert.equal(mine.riders, 4);
  assert.equal(mine.presence, 'ONLINE');
  const emText = JSON.stringify(em.json);
  assert.ok(!emText.includes('Penicillin') && !emText.includes('medical'), 'no medical info for admins');
  assert.ok(!emText.includes(r.rider.user.phone) && !emText.includes('+9190'), 'no phone numbers for admins');
  assert.equal((await t.api('GET', '/admin/emergencies', null, r.lead.token)).status, 403);
  const adminView = await t.api('GET', `/convoys/${r.c.groupId}`, null, admin.token);
  assert.equal(adminView.status, 200);
  assert.ok(!JSON.stringify(adminView.json).includes('Penicillin'), 'admin convoy view has no medical info');
  const memberView = await t.api('GET', `/convoys/${r.c.groupId}`, null, r.p1.token);
  assert.ok(JSON.stringify(memberView.json).includes('Penicillin'), 'members see it while open');

  await t.gw.timeline.idle();
  const events = await t.gw.repo.listEvents(r.c.groupId);
  const sosEv = events.find((e) => e.type === 'SOS');
  assert.equal(sosEv.data.auto, true);
  assert.deepEqual(sosEv.data.responders, []);
  assert.ok(!JSON.stringify(events).includes('Penicillin'), 'no medical info in the timeline');

  r.ws.lead.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId });
  await r.ws.p1.next((m) => m.type === 'ALERT_RESOLVED');
  const stored = await t.gw.repo.listAlerts(r.c.groupId, { includeResolved: true });
  assert.ok(!JSON.stringify(stored).includes('Penicillin'), 'removed from the database on resolve');
  const room = t.gw.convoys.rooms.get(r.c.groupId);
  assert.equal(room.alerts.get(a.alertId).medical, undefined, 'and from memory');
  const after = await t.api('GET', `/convoys/${r.c.groupId}`, null, r.p1.token);
  assert.ok(!JSON.stringify(after.json).includes('Penicillin'));
  wa.close();
  r.close();
});

test('medical info is removed from open alerts when the trip ends', async () => {
  const r = await ride('end');
  r.ws.rider.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4 });
  await r.ws.lead.next((m) => m.type === 'ALERT');
  assert.ok(JSON.stringify(await t.gw.repo.listAlerts(r.c.groupId)).includes('Penicillin'));
  r.ws.lead.sendJson({ type: 'TRIP_STATUS', status: 'ENDED' });
  await r.ws.p1.next((m) => m.type === 'TRIP_STATUS');
  await sleep(50);
  await t.gw.timeline.idle();
  const stored = await t.gw.repo.listAlerts(r.c.groupId, { includeResolved: true });
  assert.equal(stored.length, 1);
  assert.ok(!JSON.stringify(stored).includes('Penicillin'), 'medical info stripped at trip end');
  r.close();
});

test('SOS_RESPOND: going, with them, cancel, the checks and the responders cap', async () => {
  const r = await ride('resp');
  const other = await t.register('Other Group Lead', 'other.resp@coroute.test');
  const oc = (await t.api('POST', '/convoys', { name: 'Other resp' }, other.token)).json;
  const wo = await t.joinRoom(other.token, oc.groupId);

  r.ws.rider.sendJson({ type: 'SOS', lat: 17.3, lng: 78.4, alertType: 'CRASH', auto: true });
  const a = (await r.ws.lead.next((m) => m.type === 'ALERT')).alert;

  r.ws.lead.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'GOING', clientId: 'resp-1' });
  const ack = await r.ws.lead.next((m) => m.type === 'ACK' && m.clientId === 'resp-1');
  assert.equal(ack.duplicate, false);
  const s1 = await r.ws.rider.next((m) => m.type === 'SOS_RESPONSE');
  assert.equal(s1.alertId, a.alertId);
  assert.equal(s1.userId, r.lead.user.userId);
  assert.equal(s1.name, 'Lead resp');
  assert.equal(s1.kind, 'GOING');
  assert.equal(s1.responders.length, 1);

  // Same clientId again: applied once.
  r.ws.lead.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'GOING', clientId: 'resp-1' });
  assert.equal((await r.ws.lead.next((m) => m.type === 'ACK' && m.clientId === 'resp-1')).duplicate, true);

  r.ws.p1.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'WITH_THEM' });
  const s2 = await r.ws.rider.next((m) => m.type === 'SOS_RESPONSE' && m.userId === r.p1.user.userId);
  assert.equal(s2.kind, 'WITH_THEM');
  assert.deepEqual(s2.responders.map((x) => x.kind).sort(), ['GOING', 'WITH_THEM']);

  // Cap (2 in this test): a third responder is refused.
  r.ws.p2.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'GOING', clientId: 'resp-p2' });
  const full = await r.ws.p2.next((m) => m.type === 'ERROR');
  assert.equal(full.code, 409);
  assert.equal(full.clientId, 'resp-p2');

  // Cancel: kind null and the full list after the change.
  r.ws.p1.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'CANCEL' });
  const s3 = await r.ws.rider.next((m) => m.type === 'SOS_RESPONSE' && m.userId === r.p1.user.userId && m.kind === null);
  assert.equal(s3.responders.length, 1);
  r.ws.p2.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'GOING' });
  await r.ws.rider.next((m) => m.type === 'SOS_RESPONSE' && m.userId === r.p2.user.userId);

  // Own alert, bad kind, unknown alert, another convoy's socket.
  r.ws.rider.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'GOING' });
  assert.equal((await r.ws.rider.next((m) => m.type === 'ERROR')).code, 403);
  r.ws.p1.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'MAYBE' });
  assert.equal((await r.ws.p1.next((m) => m.type === 'ERROR')).code, 400);
  r.ws.p1.sendJson({ type: 'SOS_RESPOND', alertId: 'SOS-nope', kind: 'GOING' });
  assert.equal((await r.ws.p1.next((m) => m.type === 'ERROR')).code, 404);
  wo.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'GOING' });
  assert.equal((await wo.next((m) => m.type === 'ERROR')).code, 404, 'an alert of another convoy is not visible');

  // Stored as a map; the timeline has the responses and the SOS entry carries the list.
  const stored = (await t.gw.repo.listAlerts(r.c.groupId)).find((x) => x.alertId === a.alertId);
  assert.deepEqual(Object.keys(stored.responders).sort(), [r.lead.user.userId, r.p2.user.userId].sort());
  await t.gw.timeline.idle();
  const events = await t.gw.repo.listEvents(r.c.groupId);
  const responses = events.filter((e) => e.type === 'SOS_RESPONSE');
  assert.equal(responses.length, 4);
  const first = responses.find((e) => e.userId === r.lead.user.userId);
  assert.deepEqual(first.data, { alertId: a.alertId, kind: 'GOING', forUserId: r.rider.user.userId, forUserName: 'Rider resp' });
  assert.ok(responses.some((e) => e.data.kind === 'CANCEL'));
  const sosEv = events.find((e) => e.type === 'SOS' && e.data.alertId === a.alertId);
  assert.equal(sosEv.data.responders.length, 2);
  assert.ok(r.ws.lead.inbox.some((m) => m.type === 'TIMELINE_UPDATE' && m.event.type === 'SOS'));
  assert.ok(!wo.inbox.some((m) => m.type === 'SOS_RESPONSE' || (m.event && m.event.groupId === r.c.groupId)), 'nothing leaks to another convoy');

  // An ex-member whose socket is still bound: 403.
  assert.equal((await t.api('POST', `/convoys/${r.c.groupId}/leave`, {}, r.p1.token)).status, 200);
  r.ws.p1.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'GOING' });
  assert.equal((await r.ws.p1.next((m) => m.type === 'ERROR')).code, 403);

  // Resolved: 404.
  r.ws.lead.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId });
  await r.ws.rider.next((m) => m.type === 'ALERT_RESOLVED');
  r.ws.p2.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'CANCEL' });
  assert.equal((await r.ws.p2.next((m) => m.type === 'ERROR')).code, 404);
  wo.close();
  r.close();
});
