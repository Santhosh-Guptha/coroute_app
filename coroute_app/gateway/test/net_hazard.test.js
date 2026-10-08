'use strict';
/** 3.15 hazard warnings: who gets them (same road, approaching), level changes, clear, cap. */
process.env.HAZARD_MAX_RECIPIENTS = '3';
const { netBoot, line, E_LAT } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
let laneNo = 0;
const lane = () => 50 + (laneNo++) * 0.5;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

async function victim(lng) {
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victim' });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  return V;
}
async function other(points, lat, lng, heading = 0, speed = 60) {
  const B = await h.rideOn(points, { name: 'Other' });
  B.ws = await h.net1(B.lead.token, B.gid);
  if (lat !== null) h.place(B.gid, B.lead, lat, lng, heading, speed);
  return B;
}

test('approaching riders on the same road get HAZARD; parallel, passed and stopped riders do not', async () => {
  const lng = lane();
  const V = await victim(lng);
  const A = await other(line(lng, 17.40, 17.70), 17.473, lng, 0, 60);
  const F = await other(null, null, lng, 0, 50); // no route: recent path along the highway
  h.pathTo(F.gid, F.lead, 17.465, lng, { n: 5, speed: 50 });
  const P = await other(line(lng + 0.0095, 17.40, 17.70), 17.475, lng + 0.0095, 0, 60);
  const Q = await other(line(lng, 17.40, 17.70), 17.53, lng, 0, 60);
  const S = await other(line(lng, 17.40, 17.70), 17.48, lng, 0, 0);
  const a = await h.sos(V.ws, E_LAT, lng);
  const hz = await A.ws.next((m) => m.type === 'HAZARD');
  assert.equal(hz.hazardId, h.net.byAlert.get(a.alertId));
  assert.equal(hz.level, 'ACTIVE');
  assert.equal(hz.onRoute, true);
  assert.equal(hz.aheadM, 3000);
  assert.equal(hz.lat, E_LAT);
  const hf = await F.ws.next((m) => m.type === 'HAZARD');
  assert.equal(hf.onRoute, false);
  h.net.tick(Date.now() + 1000);
  await h.settle(60);
  for (const ws of [P.ws, Q.ws, S.ws]) assert.equal(h.got(ws, 'HAZARD').length, 0);
  assert.equal(h.got(A.ws, 'HAZARD').length, 1, 'once per incident');
  for (const X of [V, A, F, P, Q, S]) await h.endRide(X);
});

test('no hazard for a non-accident emergency (medical) or a low severity alert', async () => {
  const lng = lane();
  const V = await victim(lng);
  const A = await other(line(lng, 17.40, 17.70), 17.473, lng, 0, 60);
  await h.sos(V.ws, E_LAT, lng, { alertType: 'MEDICAL' });
  await h.settle(80);
  assert.equal(h.got(A.ws, 'HAZARD').length, 0);
  assert.equal(h.got(A.ws, 'ASSIST_REQUEST').length, 1, 'but assistance is asked');
  for (const X of [V, A]) await h.endRide(X);
});

test('level follows the emergency (ACTIVE, RESPONDER_ARRIVING, ON_SCENE), HAZARD_CLEAR on resolve', async () => {
  const lng = lane();
  const V = await victim(lng);
  const R = await other(line(lng, 17.40, 17.70), 17.478, lng, 0, 60); // will respond
  const W = await other(line(lng, 17.40, 17.70), 17.46, lng, 0, 60); // only warned (4.4 km, after R)
  const a = await h.sos(V.ws, E_LAT, lng);
  const req = await R.ws.next((m) => m.type === 'ASSIST_REQUEST');
  const h1 = await W.ws.next((m) => m.type === 'HAZARD');
  assert.equal(h1.level, 'ACTIVE');
  R.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'hz-acc' });
  const h2 = await W.ws.next((m) => m.type === 'HAZARD' && m.level === 'RESPONDER_ARRIVING');
  assert.equal(h2.hazardId, h1.hazardId);
  R.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ARRIVED', clientId: 'hz-arr' });
  const h3 = await W.ws.next((m) => m.type === 'HAZARD' && m.level === 'ON_SCENE');
  assert.equal(h3.hazardId, h1.hazardId);
  V.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId });
  const clr = await W.ws.next((m) => m.type === 'HAZARD_CLEAR');
  assert.equal(clr.hazardId, h1.hazardId);
  await R.ws.next((m) => m.type === 'ASSIST_CLOSED' && m.reason === 'RESOLVED');
  for (const X of [V, R, W]) await h.endRide(X);
});

test('HAZARD_CLEAR when the subject group ends its trip', async () => {
  const lng = lane();
  const V = await victim(lng);
  const W = await other(line(lng, 17.40, 17.70), 17.473, lng, 0, 60);
  await h.sos(V.ws, E_LAT, lng);
  const hz = await W.ws.next((m) => m.type === 'HAZARD');
  await h.endRide(V);
  const clr = await W.ws.next((m) => m.type === 'HAZARD_CLEAR');
  assert.equal(clr.hazardId, hz.hazardId);
  assert.equal(h.net.incidents.size, 0);
  await h.endRide(W);
});

test('at most HAZARD_MAX_RECIPIENTS warnings per incident', async () => {
  const lng = lane();
  const V = await victim(lng);
  const riders = [];
  for (let i = 0; i < 5; i++) riders.push(await other(line(lng, 17.40, 17.70), 17.46 + i * 0.004, lng, 0, 60));
  await h.sos(V.ws, E_LAT, lng);
  await h.settle(80);
  h.net.tick(Date.now() + 1000);
  await h.settle(60);
  const n = riders.reduce((s, r) => s + h.got(r.ws, 'HAZARD').length, 0);
  assert.equal(n, 3);
  for (const X of [V, ...riders]) await h.endRide(X);
});
