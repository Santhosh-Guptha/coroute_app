'use strict';
/**
 * End-to-end riding scenarios over HTTP + real WebSockets on MemorySoda:
 * solo ride (tracking, guardian link, SOS to guardian/SMS path, trip saved, report),
 * small group (join by code, roles, roster, presence, PTT floor control, regroup,
 * leave/rejoin, network drop/reconnect, lead ends for all) and group limits.
 */
process.env.NODE_ENV = 'test';
process.env.GUARDIAN_ENABLED = 'true';
process.env.PUBLIC_ORIGIN = 'https://guardian.example';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.MAX_CONVOY_RIDERS = '6';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { encodeVoice, VOICE_START, VOICE_FRAME, VOICE_END } = require('../src/ws');

let t;
const fetchCalls = [];
before(async () => {
  t = await boot({ emergencyFetch: async (url) => { fetchCalls.push(String(url)); throw new Error('offline in tests'); } });
});
after(async () => { await t.gw.shutdown(); });

let n = 0;
const rider = (tag) => { n++; return t.register(`${tag}${n}`, `scn-${tag.toLowerCase()}${n}@coroute.test`); };
const uid = (u) => u.user.userId;
const voice = (kind, header, payload = null) => encodeVoice(kind, header, payload);

test('SOLO: start, track, guardian link, SOS reaches guardian + SMS path, end, trip saved and report', async () => {
  const solo = await rider('Solo');
  const c = await t.api('POST', '/convoys', { name: 'Solo ride', start: { lat: 17.4, lng: 78.4, name: 'Home' } }, solo.token);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  const gid = c.json.groupId;
  const ws = await t.joinRoom(solo.token, gid);
  assert.equal(Object.keys(ws.snapshot.riders).length, 1);
  ws.sendJson({ type: 'TELEMETRY', lat: 17.401, lng: 78.401, speedKmh: 42, heading: 90, batteryLevel: 80 });
  await sleep(50);
  assert.equal(t.gw.convoys.rooms.get(gid).riders.get(uid(solo)).speedKmh, 42);

  // Guardian live link.
  const link = await t.api('POST', '/guardian/links', { groupId: gid, level: 'LIVE', acknowledged: true }, solo.token);
  assert.equal(link.status, 201, JSON.stringify(link.json));
  const token = new URL(link.json.url).hash.slice('#token='.length);
  const sess = await t.api('POST', '/guardian/session', { token }, null, { Origin: 'https://guardian.example' });
  assert.equal(sess.status, 201);
  const cookie = { Cookie: sess.headers.get('set-cookie').split(';')[0] };
  const path = `/guardian/sessions/${sess.json.sessionId}/snapshot`;
  let view = await t.api('GET', path, null, null, cookie);
  assert.equal(view.status, 200);
  assert.equal(view.json.status, 'RIDING');
  assert.ok(view.json.position);

  // SOS: echoed to the rider, guardian sees EMERGENCY, SMS path queued for the profile contact.
  ws.sendJson({ type: 'SOS', lat: 17.402, lng: 78.402, clientId: 'sos-solo-1' });
  const alert = await ws.next((m) => m.type === 'ALERT');
  assert.equal(alert.alert.userId, uid(solo));
  await sleep(100);
  view = await t.api('GET', path, null, null, cookie);
  assert.equal(view.json.status, 'EMERGENCY');
  const sms = t.gw.emergencyGateway.getOutbox({ channel: 'sms' });
  assert.ok(sms.some((e) => e.to === '+919000000001'), 'SOS queued an SMS to the emergency contact');
  // A retried SOS (same clientId) and a burst of new presses never multiply the alert or the SMS.
  const before = t.gw.emergencyGateway.getOutbox({ channel: 'sms', limit: 1000 }).length;
  ws.sendJson({ type: 'SOS', lat: 17.402, lng: 78.402, clientId: 'sos-solo-1' });
  ws.sendJson({ type: 'SOS', lat: 17.402, lng: 78.402, clientId: 'sos-solo-2' });
  await sleep(150);
  assert.ok([...t.gw.convoys.rooms.get(gid).alerts.values()].filter((a) => !a.resolved).length <= 2, 'storm guard: at most two open alerts');
  assert.equal(t.gw.emergencyGateway.getOutbox({ channel: 'sms', limit: 1000 }).length, before, 'no second SMS');

  // I'm safe.
  ws.sendJson({ type: 'SOS_RESOLVE', alertId: alert.alert.alertId, reason: 'CANCELLED' });
  await ws.next((m) => m.type === 'ALERT_RESOLVED');

  // End the ride; the trip record is saved and the report endpoint answers.
  const end = await t.api('POST', `/convoys/${gid}/status`, { status: 'ENDED' }, solo.token);
  assert.equal(end.status, 200);
  await ws.next((m) => m.type === 'DISSOLVED');
  // Late telemetry on a socket of an ended ride: no crash, no 500, the ride is not brought back.
  ws.sendJson({ type: 'TELEMETRY', lat: 17.41, lng: 78.41, speedKmh: 10 });
  const late = await ws.next((m) => m.type === 'ERROR', 1000).catch(() => null);
  if (late) assert.notEqual(late.code, 500, JSON.stringify(late));
  assert.equal(t.gw.convoys.rooms.has(gid), false, 'an ended ride is not reloaded into memory');
  const again = await t.api('POST', `/convoys/${gid}/status`, { status: 'PAUSED' }, solo.token);
  assert.equal(again.status, 409); assert.equal(again.json.reason || again.json.code, 'RIDE_ENDED');
  const tripId = `trip-${gid}`;
  const saved = await t.api('POST', '/trips', { tripId, groupId: gid, name: 'Solo ride', startedAt: Date.now() - 60000, endedAt: Date.now(), distanceKm: 3.2 }, solo.token);
  assert.ok([200, 201].includes(saved.status), JSON.stringify(saved.json));
  const list = await t.api('GET', '/trips?summary=1', null, solo.token);
  assert.ok(list.json.trips.some((x) => x.tripId === tripId));
  const rep = await t.api('GET', `/convoys/${gid}/summary`, null, solo.token);
  assert.equal(rep.status, 200); assert.equal(rep.json.tripStatus, 'ENDED');
  ws.close();
});

test('SMALL GROUP: join by code, roles, presence, PTT floor, regroup, leave/rejoin, drop/reconnect, lead ends for all', async () => {
  const lead = await rider('Lead');
  const c = (await t.api('POST', '/convoys', { name: 'Group ride' }, lead.token)).json;
  const gid = c.groupId;
  const others = [];
  for (const tag of ['Asha', 'Bala', 'Chen']) {
    const u = await rider(tag);
    const j = await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token);
    assert.equal(j.status, 200, JSON.stringify(j.json));
    others.push(u);
  }
  const [a, b, sweep] = others;
  const L = await t.joinRoom(lead.token, gid);
  const A = await t.joinRoom(a.token, gid);
  const B = await t.joinRoom(b.token, gid);
  const S = await t.joinRoom(sweep.token, gid);
  assert.equal(Object.keys(S.snapshot.riders).length, 4, 'roster has every rider');

  // Roles: only the lead sets the sweeper.
  A.sendJson({ type: 'ROLE_SET', userId: uid(sweep), role: 'SWEEPER' });
  assert.equal((await A.next((m) => m.type === 'ERROR')).code, 403);
  L.sendJson({ type: 'ROLE_SET', userId: uid(sweep), role: 'SWEEPER' });
  const ru = await B.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(sweep) && m.rider.role === 'SWEEPER');
  assert.ok(ru);

  // Positions: lead ahead, sweeper behind; everyone else sees both.
  L.sendJson({ type: 'TELEMETRY', lat: 17.50, lng: 78.40, speedKmh: 60 });
  S.sendJson({ type: 'TELEMETRY', lat: 17.40, lng: 78.40, speedKmh: 55 });
  await A.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(lead) && m.rider.lat === 17.5);
  await A.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(sweep) && m.rider.lat === 17.4);

  // PTT: one talker at a time; a second talker gets VOICE_BUSY; the floor frees after END.
  L.send(voice(VOICE_START, { sampleRate: 16000 }));
  await A.next((m) => m.binary && m.binary[0] === VOICE_START);
  L.send(voice(VOICE_FRAME, { seq: 1 }, Buffer.alloc(640, 1)));
  await B.next((m) => m.binary && m.binary[0] === VOICE_FRAME);
  A.send(voice(VOICE_START, { sampleRate: 16000 }));
  const busy = await A.next((m) => m.type === 'VOICE_BUSY');
  assert.ok(busy.speaker);
  L.send(voice(VOICE_END, {}));
  await B.next((m) => m.binary && m.binary[0] === VOICE_END);
  A.send(voice(VOICE_START, { sampleRate: 16000 }));
  await L.next((m) => m.binary && m.binary[0] === VOICE_START);
  A.send(voice(VOICE_END, {}));

  // Regroup: the sweeper may set one, a pack rider may not.
  B.sendJson({ type: 'REGROUP_SET', lat: 17.45, lng: 78.4, name: 'Dhaba' });
  assert.equal((await B.next((m) => m.type === 'ERROR')).code, 403);
  S.sendJson({ type: 'REGROUP_SET', lat: 17.45, lng: 78.4, name: 'Dhaba' });
  const rg = await A.next((m) => m.type === 'REGROUP_ACTIVE');
  assert.equal(rg.regroup.name, 'Dhaba');
  L.sendJson({ type: 'REGROUP_CLEAR', reason: 'COMPLETED' });
  await A.next((m) => m.type === 'REGROUP_COMPLETED');

  // Network drop (no BYE): the group sees NO_SIGNAL; reconnect brings ONLINE back.
  B.terminate();
  const ns = await A.next((m) => m.type === 'PRESENCE' && m.userId === uid(b) && m.presence === 'NO_SIGNAL', 3000);
  assert.ok(ns);
  const B2 = await t.joinRoom(b.token, gid);
  await A.next((m) => m.type === 'PRESENCE' && m.userId === uid(b) && m.presence === 'ONLINE');

  // A rider leaves and rejoins with the code.
  assert.equal((await t.api('POST', `/convoys/${gid}/leave`, null, a.token)).status, 200);
  await L.next((m) => m.type === 'RIDER_LEFT' && m.userId === uid(a));
  const rj = await t.api('POST', '/convoys/join', { code: c.joinCode }, a.token);
  assert.equal(rj.status, 200);
  await L.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(a) && m.joined === true);

  // Only the owner ends; everyone is told.
  S.sendJson({ type: 'TRIP_STATUS', status: 'ENDED' });
  assert.equal((await S.next((m) => m.type === 'ERROR')).code, 403);
  L.sendJson({ type: 'TRIP_STATUS', status: 'ENDED' });
  await Promise.all([B2, S, L].map((w) => w.next((m) => m.type === 'DISSOLVED', 3000)));
  const late = await t.api('POST', `/convoys/${gid}/status`, { status: 'STARTED' }, lead.token);
  assert.equal(late.status, 409);
  for (const w of [L, A, B2, S]) w.close();
});

test('LIMITS: convoy capacity, join code brute force, non-member isolation', async () => {
  const lead = await rider('Cap');
  const c = (await t.api('POST', '/convoys', { name: 'Cap ride' }, lead.token)).json;
  for (let i = 0; i < 5; i++) {
    const u = await rider('Cap');
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
  }
  const late = await rider('Cap');
  const full = await t.api('POST', '/convoys/join', { code: c.joinCode }, late.token);
  assert.equal(full.status, 409); assert.equal(full.json.reason || full.json.code, 'CONVOY_FULL');

  // Non-member: no snapshot, no socket room, no live link, no roster.
  const outsider = await rider('Out');
  assert.equal((await t.api('GET', `/convoys/${c.groupId}`, null, outsider.token)).status, 403);
  assert.equal((await t.api('GET', `/convoys/${c.groupId}/emergency-roster`, null, outsider.token)).status, 403);
  assert.equal((await t.api('GET', `/convoys/${c.groupId}/timeline`, null, outsider.token)).status, 403);
  const ow = await t.connect(outsider.token);
  ow.sendJson({ type: 'JOIN', groupId: c.groupId });
  assert.equal((await ow.next((m) => m.type === 'ERROR')).code, 403);
  ow.close();

  // Wrong join codes are limited per rider.
  const guesser = await rider('Guess');
  let last;
  for (let i = 0; i < 12; i++) last = await t.api('POST', '/convoys/join', { code: String(900000 + i) }, guesser.token);
  assert.equal(last.status, 429);
});

test('SOS storm: a burst of presses from two phones of one rider is at most two alerts and one SMS round', async () => {
  const r = await rider('Storm');
  const c = (await t.api('POST', '/convoys', { name: 'Storm ride' }, r.token)).json;
  const mate = await rider('Mate');
  await t.api('POST', '/convoys/join', { code: c.joinCode }, mate.token);
  const p1 = await t.joinRoom(r.token, c.groupId);
  const p2 = await t.joinRoom(r.token, c.groupId);
  const M = await t.joinRoom(mate.token, c.groupId);
  const smsBefore = t.gw.emergencyGateway.getOutbox({ channel: 'sms', limit: 5000 }).length;
  for (let i = 0; i < 3; i++) {
    p1.sendJson({ type: 'SOS', lat: 17, lng: 78, clientId: `storm-a-${i}` });
    p2.sendJson({ type: 'SOS', lat: 17, lng: 78, clientId: `storm-b-${i}` });
  }
  await sleep(400);
  const alerts = M.inbox.filter((m) => m.type === 'ALERT' && !m.duplicate);
  assert.equal(alerts.length, 2, 'six presses: at most two ALERTs reach the group');
  const open = [...t.gw.convoys.rooms.get(c.groupId).alerts.values()].filter((a) => !a.resolved);
  assert.equal(open.length, 2);
  const sms = t.gw.emergencyGateway.getOutbox({ channel: 'sms', limit: 5000 }).length - smsBefore;
  assert.equal(sms, 1, 'one SMS to the one emergency contact');
  // The phone said it already texted: the server does not text again.
  const r2 = await rider('Texted');
  const c2 = (await t.api('POST', '/convoys', { name: 'Texted ride' }, r2.token)).json;
  const q = await t.joinRoom(r2.token, c2.groupId);
  const before2 = t.gw.emergencyGateway.getOutbox({ channel: 'sms', limit: 5000 }).length;
  q.sendJson({ type: 'SOS', lat: 17, lng: 78, clientId: 'texted-1', clientSentSms: true });
  await q.next((m) => m.type === 'ALERT');
  await sleep(150);
  assert.equal(t.gw.emergencyGateway.getOutbox({ channel: 'sms', limit: 5000 }).length, before2);
  for (const w of [p1, p2, M, q]) w.close();
});
