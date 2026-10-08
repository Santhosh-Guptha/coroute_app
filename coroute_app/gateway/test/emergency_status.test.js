'use strict';
/**
 * 3.15 EmergencyEvent lifecycle: every row of the transition table (SPEC 1.2), including the ones
 * that must NOT happen, expiry, REPORT_DOWN (member and nearby) and clustering.
 */
process.env.BOOTSTRAP_ADMIN_EMAILS = 'net.admin.lead.1@coroute.test';
const { netBoot, line, E_LAT } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
let laneNo = 0;
const lane = () => 60 + (laneNo++) * 0.5;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

/** Lead + subject (member) in one group on the highway, both on 3.15 sockets. */
async function group(lng, { lead = null } = {}) {
  const G = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Group', lead });
  G.wl = await h.net1(G.lead.token, G.gid);
  G.subject = await h.join(G, 'Subject');
  G.ws = await h.net1(G.subject.token, G.gid);
  h.place(G.gid, G.lead, 17.40, lng, 0, 0);
  h.place(G.gid, G.subject, E_LAT, lng, 0, 0);
  return G;
}

const alertIn = (gid, id) => h.t.gw.convoys.rooms.get(gid).alerts.get(id);
const stored = async (gid, id) => (await h.t.gw.repo.listAlerts(gid, { includeResolved: true })).find((a) => a.alertId === id);

test('creation: CRASH_AUTO is CONFIRMED_ACCIDENT (critical), manual SOS is ASSISTANCE_REQUESTED; fields stored, network never stored', async () => {
  const lng = lane();
  const G = await group(lng);
  const crash = await h.sos(G.ws, E_LAT, lng, { source: 'CRASH_AUTO', heading: 365, speedKmh: 52.34, accuracyM: 12.6 });
  assert.equal(crash.status, 'CONFIRMED_ACCIDENT');
  assert.equal(crash.source, 'CRASH_AUTO');
  assert.equal(crash.severity, 'CRITICAL');
  assert.equal(crash.auto, true, 'CRASH_AUTO implies auto');
  assert.equal(crash.heading, 5);
  assert.equal(crash.speedKmh, 52.3);
  assert.equal(crash.accuracyM, 13);
  assert.ok(Number.isInteger(crash.routeIndex), 'segment on the group route');
  assert.ok(crash.confirmedAt > 0 && crash.lastUpdateAt > 0);
  assert.equal(crash.network, undefined, 'the ALERT goes out before any network work');
  assert.ok(['SEARCHING', 'NONE_FOUND'].includes(h.net.summaryFor(G.gid, crash.alertId).network.state));
  const snap = (await h.t.api('GET', `/convoys/${G.gid}`, null, G.lead.token)).json;
  assert.ok(snap.activeAlerts.find((x) => x.alertId === crash.alertId).network, 'the snapshot carries the summary');
  const doc = await stored(G.gid, crash.alertId);
  assert.equal(doc.status, 'CONFIRMED_ACCIDENT');
  assert.equal(doc.network, undefined);
  assert.equal(doc.ownNearest, undefined);
  const m = await h.sos(G.wl, 17.40, lng, { alertType: 'MECHANICAL' });
  assert.equal(m.status, 'ASSISTANCE_REQUESTED');
  assert.equal(m.source, 'MANUAL');
  assert.equal(m.severity, 'LOW');
  assert.equal(h.net.summaryFor(G.gid, m.alertId).network.state, 'OFF', 'low severity: no external search');
  await h.endRide(G);
});

test('own group GOING / CANCEL / WITH_THEM move the status; ARRIVED never goes back', async () => {
  const lng = lane();
  const G = await group(lng);
  const a = await h.sos(G.ws, E_LAT, lng);
  G.wl.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'GOING', clientId: 'g1' });
  const u1 = await G.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'RESPONDER_ASSIGNED');
  assert.equal(u1.alertId, a.alertId);
  await h.t.gw.timeline.idle();
  const ev = (await h.t.gw.repo.listOpenEvents(G.gid)).find((e) => e.slot === `SOS:${a.alertId}`);
  assert.equal(ev.data.status, 'RESPONDER_ASSIGNED', 'timeline entry follows');
  G.wl.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'CANCEL', clientId: 'g2' });
  await G.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'ASSISTANCE_REQUESTED');
  G.wl.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'WITH_THEM', clientId: 'g3' });
  await G.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'ASSISTANCE_ARRIVED');
  G.wl.sendJson({ type: 'SOS_RESPOND', alertId: a.alertId, kind: 'GOING', clientId: 'g4' });
  await G.wl.next((m) => m.type === 'ACK' && m.clientId === 'g4');
  await h.settle();
  assert.equal(alertIn(G.gid, a.alertId).status, 'ASSISTANCE_ARRIVED', 'not allowed back');
  assert.equal(await h.t.gw.convoys.setEmergencyStatus(G.gid, a.alertId, 'ASSISTANCE_REQUESTED'), null);
  assert.equal((await stored(G.gid, a.alertId)).status, 'ASSISTANCE_ARRIVED');
  await h.endRide(G);
});

test('SOS_RESOLVE reasons: member RESOLVED, member FALSE_ALARM is RESOLVED, owner within grace CANCELLED, owner later FALSE_ALARM', async () => {
  const lng = lane();
  const G = await group(lng);
  const old = await h.oldApp(G.lead.token, G.gid);
  // Member resolves (no reason).
  let a = await h.sos(G.ws, E_LAT, lng);
  G.wl.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId });
  let r = await G.ws.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId);
  assert.equal(r.status, 'RESOLVED');
  assert.equal(r.by, G.lead.user.userId);
  const oldR = await old.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId);
  assert.equal(oldR.status, 'RESOLVED', 'old apps get it too (extra field ignored)');
  // A member who is not the owner cannot call it a false alarm.
  a = await h.sos(G.ws, E_LAT, lng);
  G.wl.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId, reason: 'FALSE_ALARM' });
  r = await G.ws.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId);
  assert.equal(r.status, 'RESOLVED');
  // The owner within the grace, nobody outside asked: CANCELLED.
  a = await h.sos(G.ws, E_LAT, lng);
  G.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId, reason: 'FALSE_ALARM' });
  r = await G.wl.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId);
  assert.equal(r.status, 'CANCELLED');
  const doc = await stored(G.gid, a.alertId);
  assert.equal(doc.status, 'CANCELLED');
  assert.equal(doc.resolveReason, 'CANCELLED');
  assert.equal(doc.resolved, true);
  // The owner after the grace: FALSE_ALARM (also for reason CANCELLED). (A new socket: 3 SOS per 10 s per socket.)
  G.ws.close();
  G.ws = await h.net1(G.subject.token, G.gid);
  a = await h.sos(G.ws, E_LAT, lng);
  alertIn(G.gid, a.alertId).confirmedAt -= 61000;
  G.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId, reason: 'CANCELLED' });
  r = await G.wl.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId);
  assert.equal(r.status, 'FALSE_ALARM');
  // Resolving again changes nothing.
  G.wl.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId });
  r = await G.ws.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId);
  assert.equal(r.status, 'FALSE_ALARM');
  assert.equal((await stored(G.gid, a.alertId)).status, 'FALSE_ALARM');
  old.close();
  await h.endRide(G);
});

test('owner FALSE_ALARM after riders outside were asked is FALSE_ALARM even within the grace; an admin may call it too', async () => {
  const lng = lane();
  const G = await group(lng);
  const B = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Help' });
  B.ws = await h.net1(B.lead.token, B.gid);
  h.place(B.gid, B.lead, 17.473, lng, 0, 60);
  const a = await h.sos(G.ws, E_LAT, lng);
  await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  G.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId, reason: 'CANCELLED' });
  const r = await G.wl.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId);
  assert.equal(r.status, 'FALSE_ALARM');
  const closed = await B.ws.next((m) => m.type === 'ASSIST_CLOSED');
  assert.equal(closed.reason, 'FALSE_ALARM');
  await h.endRide(B); await h.endRide(G);

  const lng2 = lane();
  const admin = await h.t.gw.auth.register({ name: 'Net Admin Lead', email: 'net.admin.lead.1@coroute.test', password: 'Password#123', phone: '+919811111111', vehicleType: 'Motorcycle', vehicleNo: 'KA01AD0001', emergencyContact: '+919000000003', emergencyContactName: 'Admin Kin' });
  assert.equal(admin.user.role, 'MASTER_ADMIN');
  const G2 = await group(lng2, { lead: admin });
  const a2 = await h.sos(G2.ws, E_LAT, lng2);
  G2.wl.sendJson({ type: 'SOS_RESOLVE', alertId: a2.alertId, reason: 'FALSE_ALARM' });
  const r2 = await G2.ws.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a2.alertId);
  assert.equal(r2.status, 'FALSE_ALARM');
  await h.endRide(G2);
});

test('EXPIRED after EMERGENCY_EXPIRE_MIN without updates (server tick); old apps get ALERT_RESOLVED', async () => {
  const lng = lane();
  const G = await group(lng);
  const old = await h.oldApp(G.lead.token, G.gid);
  const a = await h.sos(G.ws, E_LAT, lng);
  h.net.tick(Date.now() + 179 * 60000);
  await h.settle();
  assert.equal(alertIn(G.gid, a.alertId).resolved, false, 'not yet');
  h.net.tick(Date.now() + 181 * 60000);
  const r = await old.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId);
  assert.equal(r.status, 'EXPIRED');
  assert.equal(r.by, 'SYSTEM');
  assert.equal(h.got(old, 'EMERGENCY_UPDATE').length, 0);
  assert.equal((await stored(G.gid, a.alertId)).status, 'EXPIRED');
  assert.equal(h.net.byAlert.has(a.alertId), false, 'incident closed');
  old.close();
  await h.endRide(G);
});

test('REPORT_DOWN for a member: their open SOS is returned (duplicate); otherwise a RIDER_DOWN alert for them', async () => {
  const lng = lane();
  const G = await group(lng);
  h.place(G.gid, G.lead, E_LAT - 0.001, lng, 0, 0); // the reporter is next to them
  const a = await h.sos(G.ws, E_LAT, lng);
  G.wl.sendJson({ type: 'REPORT_DOWN', lat: E_LAT, lng, subjectUserId: G.subject.user.userId, clientId: 'rd-1' });
  const echo = await G.wl.next((m) => m.type === 'ALERT' && m.duplicate);
  assert.equal(echo.alert.alertId, a.alertId);
  assert.equal(echo.alert.reportedBy, G.lead.user.userId);
  await G.wl.next((m) => m.type === 'ACK' && m.clientId === 'rd-1');
  G.wl.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId });
  await G.ws.next((m) => m.type === 'ALERT_RESOLVED');
  G.wl.sendJson({ type: 'REPORT_DOWN', lat: E_LAT, lng, subjectUserId: G.subject.user.userId, clientId: 'rd-2' });
  const al = await G.ws.next((m) => m.type === 'ALERT' && m.alert.alertType === 'RIDER_DOWN');
  assert.equal(al.alert.userId, G.subject.user.userId);
  assert.equal(al.alert.source, 'MEMBER_REPORT');
  assert.equal(al.alert.status, 'ASSISTANCE_REQUESTED');
  assert.equal(al.alert.reportedBy, G.lead.user.userId);
  assert.equal(al.alert.severity, 'HIGH');
  await h.endRide(G);
});

test('REPORT_DOWN validation: own id, unknown rider, bad position, too far from me', async () => {
  const lng = lane();
  const G = await group(lng);
  const err = async (msg) => { G.wl.sendJson({ type: 'REPORT_DOWN', ...msg }); return G.wl.next((m) => m.type === 'ERROR' && m.clientId === msg.clientId); };
  assert.equal((await err({ lat: 17.4, lng, subjectUserId: G.lead.user.userId, clientId: 'v1' })).code, 403);
  assert.equal((await err({ lat: 17.4, lng, subjectUserId: 'usr_nobody', clientId: 'v2' })).code, 403);
  assert.equal((await err({ lat: 0, lng: 0, clientId: 'v3' })).code, 400);
  G.wl.close();
  G.wl = await h.net1(G.lead.token, G.gid); // REPORT_DOWN is an alarm: 3 per 10 s per socket
  const far = await err({ lat: 17.45, lng, clientId: 'v4' }); // 5.5 km from the lead
  assert.equal(far.code, 422);
  assert.equal(far.reason, 'TOO_FAR');
  await h.endRide(G);
});

test('nearby report: the reporter is on scene, hazards only (no assistance search)', async () => {
  const lng = lane();
  const G = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Reporter' });
  G.ws = await h.net1(G.lead.token, G.gid);
  h.place(G.gid, G.lead, 17.4995, lng, 0, 0);
  const B = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Approach' });
  B.ws = await h.net1(B.lead.token, B.gid);
  h.place(B.gid, B.lead, 17.473, lng, 0, 60);
  G.ws.sendJson({ type: 'REPORT_DOWN', lat: E_LAT, lng, clientId: 'nb-1' });
  const al = await G.ws.next((m) => m.type === 'ALERT' && m.alert.source === 'NEARBY_REPORT');
  assert.equal(al.alert.userId, G.lead.user.userId);
  assert.equal(al.alert.status, 'ASSISTANCE_ARRIVED');
  assert.equal(al.alert.alertType, 'RIDER_DOWN');
  const hz = await B.ws.next((m) => m.type === 'HAZARD');
  assert.equal(hz.level, 'ON_SCENE');
  await h.settle(60);
  assert.equal(h.got(B.ws, 'ASSIST_REQUEST').length, 0);
  assert.equal(h.net.summaryFor(G.gid, al.alert.alertId).network.state, 'OFF');
  await h.endRide(G); await h.endRide(B);
});

test('clustering: two groups SOS 100 m apart are one incident; a candidate gets one request; a nearby report joins it (on scene)', async () => {
  const lng = lane();
  const G1 = await h.rideOn(line(lng, 17.40, 17.70), { name: 'One' });
  G1.ws = await h.net1(G1.lead.token, G1.gid);
  h.place(G1.gid, G1.lead, E_LAT, lng, 0, 0);
  const G2 = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Two' });
  G2.ws = await h.net1(G2.lead.token, G2.gid);
  h.place(G2.gid, G2.lead, E_LAT + 0.0009, lng, 0, 0);
  const R = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Rep' });
  R.ws = await h.net1(R.lead.token, R.gid);
  h.place(R.gid, R.lead, E_LAT - 0.0005, lng, 0, 0);
  const B = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Cand' });
  B.ws = await h.net1(B.lead.token, B.gid);
  h.place(B.gid, B.lead, 17.473, lng, 0, 60);
  const a1 = await h.sos(G1.ws, E_LAT, lng);
  const a2 = await h.sos(G2.ws, E_LAT + 0.0009, lng);
  const id1 = h.net.byAlert.get(a1.alertId);
  assert.equal(h.net.byAlert.get(a2.alertId), id1, 'one incident');
  await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  h.net.tick(Date.now() + 1000);
  await h.settle(60);
  assert.equal(h.got(B.ws, 'ASSIST_REQUEST').length, 1, 'one request per candidate');
  // Each group keeps its own alert (3.14 semantics).
  assert.equal(h.t.gw.convoys.rooms.get(G1.gid).alerts.has(a2.alertId), false);
  R.ws.sendJson({ type: 'REPORT_DOWN', lat: E_LAT - 0.0005, lng, clientId: 'cl-1' });
  const up = await G1.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.network.onScene === true);
  assert.equal(up.alertId, a1.alertId);
  assert.equal(h.net.incidents.get(id1).reports, 1);
  for (const X of [G1, G2, R, B]) await h.endRide(X);
});
