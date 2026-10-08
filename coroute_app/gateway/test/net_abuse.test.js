'use strict';
/**
 * 3.15 abuse prevention: rate limits, false-alert reports, the false alarm counter and throttling of
 * EXTERNAL requests only (the own group is never slowed), admin view, reset, audit without coordinates.
 */
process.env.BOOTSTRAP_ADMIN_EMAILS = 'net.abuse.admin@coroute.test';
const { netBoot, line, E_LAT, sleep } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h, admin;
let laneNo = 0;
const lane = () => 30 + (laneNo++) * 0.5;
before(async () => {
  h = await netBoot();
  admin = await h.t.gw.auth.register({ name: 'Net Abuse Admin', email: 'net.abuse.admin@coroute.test', password: 'Password#123', phone: '+919822222222', vehicleType: 'Motorcycle', vehicleNo: 'KA01AB0002', emergencyContact: '+919000000004', emergencyContactName: 'Admin Kin' });
});
after(async () => { await h.t.gw.shutdown(); });

async function victim(lng, lat = E_LAT, lead = null) {
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victim', lead });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, lat, lng, 0, 0);
  return V;
}
async function other(lng, lat, speed = 60) {
  const B = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Other' });
  B.ws = await h.net1(B.lead.token, B.gid);
  h.place(B.gid, B.lead, lat, lng, 0, speed);
  return B;
}
const userDoc = (uid) => h.t.gw.repo.findUserById(uid);

test('REPORT_DOWN: the third in 10 minutes is 429 (per user, any socket)', async () => {
  const lng = lane();
  const R = await h.rideOn(null, { name: 'Reporter' });
  h.place(R.gid, R.lead, E_LAT, lng, 0, 0);
  const w1 = await h.net1(R.lead.token, R.gid);
  w1.sendJson({ type: 'REPORT_DOWN', lat: E_LAT, lng, clientId: 'a1' });
  await w1.next((m) => m.type === 'ACK' && m.clientId === 'a1');
  w1.sendJson({ type: 'REPORT_DOWN', lat: E_LAT + 0.01, lng, clientId: 'a2' });
  await w1.next((m) => m.type === 'ACK' && m.clientId === 'a2');
  const w2 = await h.net1(R.lead.token, R.gid);
  w2.sendJson({ type: 'REPORT_DOWN', lat: E_LAT - 0.01, lng, clientId: 'a3' });
  const e = await w2.next((m) => m.type === 'ERROR' && m.clientId === 'a3');
  assert.equal(e.code, 429);
  w1.close(); w2.close();
  await h.endRide(R);
});

test('NET_REPORT_FALSE: once per incident (repeat is a no-op), the 6th in an hour is 429', async () => {
  const lng = lane();
  const W = await other(lng, 17.47, 60);
  const victims = [];
  for (let i = 0; i < 6; i++) victims.push(await victim(lng, 17.475 + i * 0.008));
  const ids = [];
  for (const V of victims) {
    await h.sos(V.ws, V.room.riders.get(V.lead.user.userId).lat, lng);
    ids.push(h.net.byAlert.get([...V.room.alerts.keys()][0]));
  }
  h.net.tick(Date.now() + 500);
  await h.settle(60);
  const got = new Set(h.got(W.ws, 'HAZARD').map((f) => f.hazardId));
  const warned = ids.filter((id) => got.has(id));
  assert.ok(warned.length >= 6, `warned for ${warned.length}`);
  const codes = [];
  for (let i = 0; i < 6; i++) {
    W.ws.sendJson({ type: 'NET_REPORT_FALSE', incidentId: warned[i], clientId: `f${i}` });
    const r = await W.ws.next((m) => (m.type === 'ACK' || m.type === 'ERROR') && m.clientId === `f${i}`);
    codes.push(r.type === 'ACK' ? 200 : r.code);
    await sleep(110); // action budget
  }
  assert.deepEqual(codes, [200, 200, 200, 200, 200, 429]);
  W.ws.sendJson({ type: 'NET_REPORT_FALSE', incidentId: warned[0], clientId: 'f0-again' });
  assert.equal((await W.ws.next((m) => (m.type === 'ACK' || m.type === 'ERROR') && m.clientId === 'f0-again')).type, 'ACK', 'once per incident: repeat ignored');
  assert.equal(h.net.incidents.get(warned[0]).falseReports.size, 1);
  for (const X of [W, ...victims]) await h.endRide(X);
});

test('false alarm counter: not counted when nobody outside was asked; counted after a request; counted on 2 false reports', async () => {
  const lng = lane();
  const V = await victim(lng);
  let a = await h.sos(V.ws, E_LAT, lng);
  h.t.gw.convoys.rooms.get(V.gid).alerts.get(a.alertId).confirmedAt -= 120000;
  V.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId, reason: 'FALSE_ALARM' });
  assert.equal((await V.ws.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId)).status, 'FALSE_ALARM');
  await h.settle(60);
  assert.equal((await userDoc(V.lead.user.userId)).falseAlarmAt, undefined, 'notified 0: not an abuse signal');
  const B = await other(lng, 17.473);
  a = await h.sos(V.ws, E_LAT, lng);
  await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  V.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId, reason: 'FALSE_ALARM' });
  assert.equal((await V.ws.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === a.alertId)).status, 'FALSE_ALARM');
  await h.settle(60);
  assert.equal((await userDoc(V.lead.user.userId)).falseAlarmAt.length, 1);
  await h.endRide(B);

  // Two riders report a false alert, then the group "resolves" it: counted too.
  const lng2 = lane();
  const V2 = await victim(lng2);
  const X1 = await other(lng2, 17.473);
  const X2 = await other(lng2, 17.47);
  const a2 = await h.sos(V2.ws, E_LAT, lng2);
  const r1 = await X1.ws.next((m) => m.type === 'ASSIST_REQUEST');
  await X2.ws.next((m) => m.type === 'ASSIST_REQUEST' || m.type === 'HAZARD');
  X1.ws.sendJson({ type: 'NET_REPORT_FALSE', incidentId: r1.incidentId, clientId: 'x1' });
  X2.ws.sendJson({ type: 'NET_REPORT_FALSE', incidentId: r1.incidentId, clientId: 'x2' });
  await X1.ws.next((m) => m.type === 'ACK' && m.clientId === 'x1');
  await X2.ws.next((m) => m.type === 'ACK' && m.clientId === 'x2');
  V2.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a2.alertId });
  await V2.ws.next((m) => m.type === 'ALERT_RESOLVED');
  await h.settle(60);
  assert.equal((await userDoc(V2.lead.user.userId)).falseAlarmAt.length, 1);
  for (const X of [V, V2, X1, X2]) await h.endRide(X);
});

test('throttled owner (3 false alarms in 30 days): own group alerted at once; one external request, after 60 s; no hazards', async () => {
  const lng = lane();
  const owner = await h.rider('Throttled');
  const doc = await userDoc(owner.user.userId);
  const day = 86400000;
  await h.t.gw.repo.updateUser(doc.key, { falseAlarmAt: [Date.now() - day, Date.now() - 2 * day, Date.now() - 3 * day] });
  const V = await victim(lng, E_LAT, owner);
  const mate = await h.join(V, 'Mate');
  const mws = await h.net1(mate.token, V.gid);
  h.place(V.gid, mate, 17.30, lng, 0, 60); // far: does not count as faster
  const B = await other(lng, 17.473);
  const C = await other(lng, 17.47);
  const t0 = Date.now();
  V.ws.sendJson({ type: 'SOS', lat: E_LAT, lng, alertType: 'CRASH', clientId: 'thr-1' });
  await mws.next((m) => m.type === 'ALERT');
  assert.ok(Date.now() - t0 < 500, 'own group alert is immediate');
  await h.settle(80);
  assert.equal(h.got(B.ws, 'ASSIST_REQUEST').length + h.got(C.ws, 'ASSIST_REQUEST').length, 0, 'held back');
  assert.equal(h.got(B.ws, 'HAZARD').length + h.got(C.ws, 'HAZARD').length, 0, 'no hazards unless CRASH_AUTO');
  h.net.tick(Date.now() + 61000);
  await h.settle(60);
  h.net.tick(Date.now() + 62000);
  await h.settle(60);
  assert.equal(h.got(B.ws, 'ASSIST_REQUEST').length + h.got(C.ws, 'ASSIST_REQUEST').length, 1, 'only one external request');
  mws.close();
  for (const X of [V, B, C]) await h.endRide(X);
});

test('admin: /admin/safety lists incidents, false alarm users and audit rows (no coordinates); reset clears the counter', async () => {
  const lng = lane();
  const V = await victim(lng);
  const B = await other(lng, 17.473);
  await h.sos(V.ws, E_LAT, lng);
  await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  const flagged = await h.rider('Flagged');
  const d = await userDoc(flagged.user.userId);
  await h.t.gw.repo.updateUser(d.key, { falseAlarmAt: [Date.now() - 1000, Date.now() - 2000, Date.now() - 40 * 86400000] });
  assert.equal((await h.t.api('GET', '/admin/safety', null, V.lead.token)).status, 403);
  const r = await h.t.api('GET', '/admin/safety', null, admin.token);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('cache-control'), 'no-store');
  const inc = r.json.incidents.find((x) => x.groupIds.includes(V.gid));
  assert.ok(inc);
  assert.equal(inc.notified, 1);
  assert.equal(inc.kind, 'ASSIST');
  const fu = r.json.falseAlarmUsers.find((x) => x.userId === flagged.user.userId);
  assert.equal(fu.count30d, 2, 'only the last 30 days');
  assert.equal(fu.throttled, false);
  assert.ok(r.json.audit.length > 0);
  const kinds = new Set(r.json.audit.map((x) => x.kind));
  assert.ok(kinds.has('RAISE') && kinds.has('NOTIFY'), [...kinds].join());
  for (const row of r.json.audit) {
    assert.equal(row.lat, undefined); assert.equal(row.lng, undefined);
    assert.ok(!/\d+\.\d{3,}/.test(JSON.stringify({ detail: row.detail })), 'no coordinates in detail');
  }
  const em = await h.t.api('GET', '/admin/emergencies', null, admin.token);
  const row = em.json.emergencies.find((x) => x.groupId === V.gid);
  assert.equal(row.status, 'ASSISTANCE_REQUESTED');
  assert.equal(row.source, 'MANUAL');
  assert.equal(row.severity, 'HIGH');
  assert.equal(row.network.state, 'REQUESTED');
  assert.equal(row.network.notified, 1);
  assert.equal(row.falseAlarms30d, 0);
  const rs = await h.t.api('POST', `/admin/users/${flagged.user.userId}/false-alarms/reset`, {}, admin.token);
  assert.deepEqual(rs.json, { ok: true });
  assert.deepEqual((await userDoc(flagged.user.userId)).falseAlarmAt, []);
  assert.equal((await h.t.api('POST', '/admin/users/usr_nobody/false-alarms/reset', {}, admin.token)).status, 404);
  for (const X of [V, B]) await h.endRide(X);
});
