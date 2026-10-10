'use strict';
/**
 * 3.15 backward compatibility: 3.11 to 3.14 apps (no JOIN caps) never receive a new message type,
 * still get ALERT / ALERT_RESOLVED (with extra fields they ignore), their SOS is searched for, and
 * they are never asked to help. Profile switches: types, defaults, never in public views; opt-outs.
 */
process.env.BOOTSTRAP_ADMIN_EMAILS = 'net.compat.admin@coroute.test';
const { netBoot, line, E_LAT } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
let laneNo = 0;
const lane = () => 10 + (laneNo++) * 0.5;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

const NEW_TYPES = ['EMERGENCY_UPDATE', 'ASSIST_REQUEST', 'ASSIST_UPDATE', 'ASSIST_CLOSED', 'HAZARD', 'HAZARD_CLEAR', 'DISCOVERY', 'WAVED'];

test('HELLO keeps the 3.14 features first and appends net1, discovery1, ride316', async () => {
  const u = await h.rider('Hello');
  const ws = await h.t.connect(u.token);
  const hello = await ws.next((m) => m.type === 'HELLO');
  assert.deepEqual(hello.features, ['ack', 'sos2', 'respond', 'presence', 'checkin', 'roster', 'net1', 'discovery1', 'ride316', 'featurePolicy1', 'bin1']);
  ws.close();
});

test('an old app never gets a new message type during a full scenario, and is never asked to help', async () => {
  const lng = lane();
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victim' });
  V.ws = await h.oldApp(V.lead.token, V.gid); // the subject runs 3.14
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  const vMate = await h.join(V, 'Old Mate');
  const vOld = await h.oldApp(vMate.token, V.gid);
  h.place(V.gid, vMate, 17.30, lng, 0, 60);
  const OldC = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Old Helpers' });
  const oldCand = await h.oldApp(OldC.lead.token, OldC.gid);
  h.place(OldC.gid, OldC.lead, 17.48, lng, 0, 60); // perfectly placed, but a 3.14 app
  const NewC = await h.rideOn(line(lng, 17.40, 17.70), { name: 'New Helpers' });
  NewC.ws = await h.net1(NewC.lead.token, NewC.gid);
  h.place(NewC.gid, NewC.lead, 17.473, lng, 0, 60);
  // A 3.14 SOS: no source, no heading.
  V.ws.sendJson({ type: 'SOS', lat: E_LAT, lng, alertType: 'CRASH_OR_EMERGENCY', clientId: 'old-sos-1' });
  const al = await vOld.next((m) => m.type === 'ALERT');
  assert.equal(al.alert.status, 'ASSISTANCE_REQUESTED');
  assert.equal(al.alert.source, 'MANUAL');
  assert.equal(al.alert.severity, 'HIGH');
  assert.deepEqual(al.alert.responders, [], '3.14 fields unchanged');
  const req = await NewC.ws.next((m) => m.type === 'ASSIST_REQUEST');
  NewC.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'c-acc' });
  await NewC.ws.next((m) => m.type === 'ASSIST_UPDATE');
  h.place(NewC.gid, NewC.lead, 17.4995, lng, 0, 10);
  NewC.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ARRIVED', clientId: 'c-arr' });
  await NewC.ws.next((m) => m.type === 'ACK' && m.clientId === 'c-arr');
  vOld.sendJson({ type: 'SOS_RESOLVE', alertId: al.alert.alertId }); // 3.14: no reason
  const res = await V.ws.next((m) => m.type === 'ALERT_RESOLVED');
  assert.equal(res.status, 'RESOLVED');
  await NewC.ws.next((m) => m.type === 'ASSIST_CLOSED');
  await h.settle(60);
  for (const ws of [V.ws, vOld, oldCand]) {
    const bad = ws.frames.filter((f) => NEW_TYPES.includes(f.type)).map((f) => f.type);
    assert.deepEqual(bad, [], 'no new types for 3.14 sockets');
  }
  assert.ok(vOld.frames.some((f) => f.type === 'TIMELINE_UPDATE' || f.type === 'TIMELINE'), 'existing types still flow');
  for (const X of [V, OldC, NewC]) await h.endRide(X);
});

test('a 3.14 crash alert (auto true, no source) reads as CRASH_AUTO / CONFIRMED_ACCIDENT', async () => {
  const lng = lane();
  const V = await h.rideOn(null, { name: 'Old Crash' });
  const ws = await h.oldApp(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  ws.sendJson({ type: 'SOS', lat: E_LAT, lng, alertType: 'CRASH', auto: true, clientId: 'old-crash' });
  const al = await ws.next((m) => m.type === 'ALERT');
  assert.equal(al.alert.source, 'CRASH_AUTO');
  assert.equal(al.alert.status, 'CONFIRMED_ACCIDENT');
  assert.equal(al.alert.severity, 'CRITICAL');
  await h.endRide(V);
});

test('alerts stored before 3.15 read with derived status and source', async () => {
  const { publicAlert } = require('../src/convoys');
  const old = { alertId: 'SOS-x', userId: 'u', userName: 'N', lat: 1, lng: 2, alertType: 'EMERGENCY', timestamp: 5, resolved: false, auto: false, responders: {} };
  const p = publicAlert(old);
  assert.equal(p.status, 'ASSISTANCE_REQUESTED');
  assert.equal(p.source, 'MANUAL');
  assert.equal(p.lastUpdateAt, 5);
  assert.equal(publicAlert({ ...old, resolved: true }).status, 'RESOLVED');
  assert.equal(publicAlert({ ...old, auto: true }).source, 'CRASH_AUTO');
});

test('PATCH /me: assist switches are type checked, selfUser defaults, never in public views; live ride updated without ROSTER_CHANGED', async () => {
  const u = await h.rider('Switches');
  const me = await h.t.api('GET', '/me', null, u.token);
  assert.equal(me.json.assistHelp, true);
  assert.equal(me.json.assistAsk, true);
  assert.equal(me.json.responderMedical, false);
  assert.equal(me.json.netConsentAt, 0);
  const bad = await h.t.api('PATCH', '/me', { assistHelp: 'yes' }, u.token);
  assert.equal(bad.status, 422);
  assert.equal(bad.json.fields.assistHelp, 'This field must be on or off.');
  const R = await h.rideOn(null, { name: 'Switch Ride', lead: u });
  const ws = await h.net1(u.token, R.gid);
  const t0 = Date.now();
  const ok = await h.t.api('PATCH', '/me', { assistHelp: false, assistAsk: false, responderMedical: true, netConsent: true }, u.token);
  assert.equal(ok.status, 200);
  assert.equal(ok.json.assistHelp, false);
  assert.equal(ok.json.assistAsk, false);
  assert.equal(ok.json.responderMedical, true);
  assert.ok(ok.json.netConsentAt >= t0);
  const rider = h.t.gw.convoys.rooms.get(R.gid).riders.get(u.user.userId);
  assert.equal(rider.assistHelp, false);
  assert.equal(rider.responderMedical, true);
  await h.settle(40);
  assert.equal(h.got(ws, 'ROSTER_CHANGED').length, 0, 'assist keys only: no roster refresh');
  const snap = (await h.t.api('GET', `/convoys/${R.gid}`, null, u.token)).json;
  for (const k of ['assistHelp', 'assistAsk', 'responderMedical', 'falseAlarmAt', 'netConsentAt']) {
    assert.equal(snap.riders[u.user.userId][k], undefined, `publicRider has no ${k}`);
  }
  const admin = await h.t.gw.auth.register({ name: 'Net Compat Admin', email: 'net.compat.admin@coroute.test', password: 'Password#123', phone: '+919833333334', vehicleType: 'Motorcycle', vehicleNo: 'KA01AC0003', emergencyContact: '+919000000005', emergencyContactName: 'Admin Kin' });
  const list = await h.t.api('GET', '/admin/users', null, admin.token);
  const row = list.json.users.find((x) => x.userId === u.user.userId);
  for (const k of ['assistHelp', 'assistAsk', 'responderMedical', 'netConsentAt', 'falseAlarmAt']) assert.equal(row[k], undefined, `publicUser has no ${k}`);
  ws.close();
  await h.endRide(R);
});

test('opt-outs: assistHelp off is never asked; assistAsk off means no external search (own group unaffected)', async () => {
  const lng = lane();
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victim' });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  const noHelp = await h.rider('No Help');
  await h.t.api('PATCH', '/me', { assistHelp: false }, noHelp.token);
  const N = await h.rideOn(line(lng, 17.40, 17.70), { name: 'No Help Ride', lead: noHelp });
  N.ws = await h.net1(noHelp.token, N.gid);
  h.place(N.gid, noHelp, 17.473, lng, 0, 60);
  await h.sos(V.ws, E_LAT, lng);
  await h.settle(80);
  assert.equal(h.got(N.ws, 'ASSIST_REQUEST').length, 0);
  assert.equal(h.got(N.ws, 'HAZARD').length, 1, 'a warning is not an ask: still warned');
  for (const X of [V, N]) await h.endRide(X);

  const lng2 = lane();
  const noAsk = await h.rider('No Ask');
  await h.t.api('PATCH', '/me', { assistAsk: false }, noAsk.token);
  const V2 = await h.rideOn(line(lng2, 17.40, 17.70), { name: 'Private Victim', lead: noAsk });
  V2.ws = await h.net1(noAsk.token, V2.gid);
  h.place(V2.gid, noAsk, E_LAT, lng2, 0, 0);
  const mate = await h.join(V2, 'Mate');
  const mws = await h.net1(mate.token, V2.gid);
  const B = await h.rideOn(line(lng2, 17.40, 17.70), { name: 'Helpers' });
  B.ws = await h.net1(B.lead.token, B.gid);
  h.place(B.gid, B.lead, 17.473, lng2, 0, 60);
  const a = await h.sos(V2.ws, E_LAT, lng2);
  await mws.next((m) => m.type === 'ALERT' && m.alert.alertId === a.alertId);
  await h.settle(80);
  assert.equal(h.got(B.ws, 'ASSIST_REQUEST').length, 0);
  assert.equal(h.net.summaryFor(V2.gid, a.alertId).network.state, 'OFF');
  mws.close();
  for (const X of [V2, B]) await h.endRide(X);
});

test('Public / Private never changes safety: a Private group is asked to help and its SOS is searched for', async () => {
  const lng = lane();
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Private Victim' });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  const B = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Public Helpers' });
  B.ws = await h.net1(B.lead.token, B.gid);
  B.ws.sendJson({ type: 'CONFIG', visibility: 'PUBLIC', discovery: true });
  await B.ws.next((m) => m.type === 'CONFIG');
  h.place(B.gid, B.lead, 17.473, lng, 0, 60);
  assert.equal(h.t.gw.convoys.rooms.get(V.gid).meta.visibility, undefined, 'victim stays Private (default)');
  await h.sos(V.ws, E_LAT, lng);
  await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  for (const X of [V, B]) await h.endRide(X);
  // And the reverse: the Private group helps a Public one.
  const lng2 = lane();
  const V2 = await h.rideOn(line(lng2, 17.40, 17.70), { name: 'Public Victim' });
  V2.ws = await h.net1(V2.lead.token, V2.gid);
  V2.ws.sendJson({ type: 'CONFIG', visibility: 'PUBLIC', discovery: true });
  await V2.ws.next((m) => m.type === 'CONFIG');
  h.place(V2.gid, V2.lead, E_LAT, lng2, 0, 0);
  const P = await h.rideOn(line(lng2, 17.40, 17.70), { name: 'Private Helpers' });
  P.ws = await h.net1(P.lead.token, P.gid);
  h.place(P.gid, P.lead, 17.473, lng2, 0, 60);
  await h.sos(V2.ws, E_LAT, lng2);
  await P.ws.next((m) => m.type === 'ASSIST_REQUEST');
  for (const X of [V2, P]) await h.endRide(X);
});
