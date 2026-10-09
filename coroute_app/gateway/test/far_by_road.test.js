'use strict';
/**
 * 3.16 "far by road": a fallback candidate the road check rejected (close in a straight line, far by
 * road) is not asked in stage 1; after the escalation, when nobody else qualifies, it is asked once with
 * farByRoad: true and its road ETA, only when that ETA is under NET_FAR_MAX_ETA_S (900 s); the group
 * sees farByRoad on the responder after ACCEPT.
 */
const { netBoot, E_LAT } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
let laneNo = 0;
const lane = () => 84 + (laneNo++) * 0.5;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

async function victim(lng) {
  const V = await h.rideOn(null, { name: 'Victim' });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  return V;
}
async function helperOnPath(lng, lat = 17.4838) {
  const B = await h.rideOn(null, { name: 'Helpers' });
  B.ws = await h.net1(B.lead.token, B.gid);
  h.pathTo(B.gid, B.lead, lat, lng, { n: 5 });
  return B;
}
const incOf = (alertId) => h.net.incidents.get(h.net.byAlert.get(alertId));

test('1.8 km straight, 9 km by road (ETA 600 s): not in stage 1, asked after the escalation with farByRoad and road values, once', async () => {
  const lng = lane();
  h.net.osrmTimes = [];
  h.fake.table.fail = false; h.fake.table.delayMs = 0;
  h.fake.table.answer = (sources) => sources.map(() => ({ distanceM: 9000, durationS: 600 }));
  const V = await victim(lng);
  const B = await helperOnPath(lng);
  const a = await h.sos(V.ws, E_LAT, lng);
  const req = await B.ws.next((m) => m.type === 'ASSIST_REQUEST', 1500);
  assert.equal(req.farByRoad, true);
  assert.equal(req.routeDistanceM, 9000, 'road distance');
  assert.equal(req.etaS, 600, 'road ETA');
  assert.equal(req.aheadOnRoute, false);
  const inc = incOf(a.alertId);
  assert.equal(inc.stage, 2, 'asked in stage 2 only');
  assert.equal(inc.farAsked, true);
  assert.equal(inc.notified.get(B.lead.user.userId).confidence, 'FAR');
  assert.equal(inc.notified.get(B.lead.user.userId).stage, 2, 'never in stage 1');
  // Only once per incident: a decline does not bring a second far ask, and nobody else exists.
  B.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'DECLINE', clientId: 'far-decline' });
  await B.ws.next((m) => m.type === 'ACK');
  await h.settle(120);
  h.net.tick(Date.now() + 20000);
  await h.settle(120);
  assert.equal(h.got(B.ws, 'ASSIST_REQUEST').length, 1);
  assert.equal(h.net.summaryFor(V.gid, a.alertId).network.state, 'NONE_FOUND');
  // Audit says FAR STAGE 2.
  await h.t.gw.audit.flush();
  const rows = await h.t.gw.repo.listAudit({ limit: 500 });
  assert.ok(rows.some((r) => r.kind === 'NOTIFY' && r.incidentId === req.incidentId && r.detail === 'FAR STAGE 2'));
  await h.endRide(V); await h.endRide(B);
});

test('road ETA over 900 s: never asked, even after the escalation', async () => {
  const lng = lane();
  h.net.osrmTimes = [];
  h.fake.table.answer = (sources) => sources.map(() => ({ distanceM: 12000, durationS: 1000 }));
  const V = await victim(lng);
  const B = await helperOnPath(lng);
  const a = await h.sos(V.ws, E_LAT, lng);
  await h.settle(200);
  h.net.tick(Date.now() + 1000);
  await h.settle(100);
  assert.equal(h.got(B.ws, 'ASSIST_REQUEST').length, 0, JSON.stringify([h.got(B.ws, 'ASSIST_REQUEST'), h.fake.table.calls, [...incOf(a.alertId).notified.values()]]));
  assert.equal(incOf(a.alertId).stage, 2);
  assert.equal(incOf(a.alertId).farAsked, undefined);
  await h.endRide(V); await h.endRide(B);
});

test('a far rider who accepts: the group sees farByRoad on the responder', async () => {
  const lng = lane();
  h.net.osrmTimes = [];
  h.fake.table.answer = (sources) => sources.map(() => ({ distanceM: 8000, durationS: 540 }));
  const V = await victim(lng);
  const B = await helperOnPath(lng);
  const a = await h.sos(V.ws, E_LAT, lng);
  const req = await B.ws.next((m) => m.type === 'ASSIST_REQUEST', 1500);
  assert.equal(req.farByRoad, true);
  B.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'far-accept' });
  await B.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  const up = await V.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.network.responders.some((r) => r.status === 'ACCEPTED'), 1500);
  const R = up.network.responders.find((r) => r.status === 'ACCEPTED');
  assert.equal(R.farByRoad, true);
  assert.equal(up.alertId, a.alertId);
  const snap = (await h.t.api('GET', `/convoys/${V.gid}`, undefined, V.lead.token)).json;
  assert.equal(snap.activeAlerts[0].network.responders[0].farByRoad, true);
  await h.endRide(V); await h.endRide(B);
});

test('a near candidate that passes the road check is a plain LOW ask (no farByRoad)', async () => {
  const lng = lane();
  h.net.osrmTimes = [];
  h.fake.table.answer = (sources) => sources.map(() => ({ distanceM: 2300, durationS: 150 }));
  const V = await victim(lng);
  const B = await helperOnPath(lng, 17.48);
  await h.sos(V.ws, E_LAT, lng);
  const req = await B.ws.next((m) => m.type === 'ASSIST_REQUEST', 1500);
  assert.equal(req.farByRoad, undefined);
  assert.equal(req.routeDistanceM, 2300);
  await h.endRide(V); await h.endRide(B);
});
