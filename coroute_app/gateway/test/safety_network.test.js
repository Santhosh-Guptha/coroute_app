'use strict';
/**
 * 3.15 safety network: who is asked to help (route geometry, fallback, OSRM budget, own group
 * comparison, caps, escalation) and the responder lifecycle. Synthetic highway along a meridian
 * from 17.40 to 17.70, emergency at 17.500. Each test rides on its own meridian (`lane()`).
 */
const { netBoot, line, E_LAT, sleep } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
let laneNo = 0;
const lane = () => 74 + (laneNo++) * 0.5; // 50 km apart
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

/** The subject's group on the highway (northbound route). The lead is the subject, alone unless members are added. */
async function victim(lng, { route = true } = {}) {
  const V = await h.rideOn(route ? line(lng, 17.40, 17.70) : null, { name: 'Victim' });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  return V;
}

/** Another group with a route (points) or none; its lead placed at (lat, lng) with heading and speed. */
async function helpers(points, lat, lng, heading = 0, speed = 60) {
  const B = await h.rideOn(points, { name: 'Helpers' });
  B.ws = await h.net1(B.lead.token, B.gid);
  if (lat !== null) h.place(B.gid, B.lead, lat, lng, heading, speed);
  return B;
}

async function member(ride, lat, lng, heading = 0, speed = 60) {
  const u = await h.join(ride);
  const ws = await h.net1(u.token, ride.gid);
  h.place(ride.gid, u, lat, lng, heading, speed);
  return { u, ws };
}

const incOf = (alertId) => h.net.incidents.get(h.net.byAlert.get(alertId));

test('same highway, 3 km before the emergency, northbound: ASSIST_REQUEST (route based)', async () => {
  const lng = lane();
  const V = await victim(lng);
  const B = await helpers(line(lng, 17.40, 17.70), 17.473, lng, 0, 60);
  const a = await h.sos(V.ws, E_LAT, lng);
  const req = await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.match(req.incidentId, /^NET-[0-9A-F]{12}$/);
  assert.equal(req.aheadOnRoute, true);
  assert.equal(req.fasterThanGroup, true);
  assert.equal(req.kind, 'ACCIDENT');
  assert.equal(req.distanceM, 3000);
  assert.equal(req.routeDistanceM, 3000);
  assert.ok(req.etaS >= 150 && req.etaS <= 210, `eta ${req.etaS}`);
  assert.equal(req.severity, 'HIGH');
  // The subject's group sees the search.
  const up = await V.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.network.state === 'REQUESTED');
  assert.equal(up.alertId, a.alertId);
  assert.equal(up.status, 'ASSISTANCE_REQUESTED');
  assert.equal(up.network.notified, 1);
  await h.endRide(V); await h.endRide(B);
});

test('parallel road 1 km away, a rider who already passed, and a rider riding away: nobody is asked', async () => {
  const lng = lane();
  const V = await victim(lng);
  const P = await helpers(line(lng + 0.0095, 17.40, 17.70), 17.473, lng + 0.0095, 0, 60); // parallel road with its own route
  const Q = await helpers(line(lng, 17.40, 17.70), 17.53, lng, 0, 60); // passed, still northbound
  const S = await helpers(line(lng, 17.70, 17.40), 17.47, lng, 180, 60); // southbound, the point is behind them
  const a = await h.sos(V.ws, E_LAT, lng);
  await h.settle(80);
  h.net.tick(Date.now() + 1000);
  await h.settle(80);
  for (const ws of [P.ws, Q.ws, S.ws]) assert.equal(h.got(ws, 'ASSIST_REQUEST').length, 0);
  const inc = incOf(a.alertId);
  assert.equal(inc.stage, 2, 'stage 1 found nobody: searched 10 km at once');
  assert.equal(h.net.summaryFor(V.gid, a.alertId).network.state, 'NONE_FOUND');
  for (const R of [V, P, Q, S]) await h.endRide(R);
});

test('opposite direction on the same highway, coming toward it: ASSIST_REQUEST', async () => {
  const lng = lane();
  const V = await victim(lng);
  const S = await helpers(line(lng, 17.70, 17.40), 17.53, lng, 180, 60); // southbound, 3.3 km before the point
  await h.sos(V.ws, E_LAT, lng);
  const req = await S.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(req.aheadOnRoute, true);
  assert.equal(req.routeDistanceM, 3300);
  await h.endRide(V); await h.endRide(S);
});

test('no route: a path along the highway gets a LOW request after the road check; the parallel road does not', async () => {
  const lng = lane();
  h.net.osrmTimes = [];
  h.fake.table.fail = false; h.fake.table.delayMs = 0;
  h.fake.table.answer = (sources, dest) => sources.map(() => ({ distanceM: 2300, durationS: 150 }));
  const before = h.fake.table.calls;
  const V = await victim(lng);
  const B = await helpers(null, null, lng, 0, 60);
  h.pathTo(B.gid, B.lead, 17.48, lng, { n: 5 });
  const P = await helpers(null, null, lng + 0.0095, 0, 60);
  h.pathTo(P.gid, P.lead, 17.48, lng + 0.0095, { n: 5 });
  await h.sos(V.ws, E_LAT, lng);
  const req = await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(req.aheadOnRoute, false);
  assert.equal(req.routeDistanceM, 2300);
  assert.ok(h.fake.table.calls > before, 'one road check');
  await h.settle(50);
  assert.equal(h.got(P.ws, 'ASSIST_REQUEST').length, 0, 'parallel road never asked');
  for (const R of [V, B, P]) await h.endRide(R);
});

test('no route: 1.8 km straight but 12 km by road is rejected', async () => {
  const lng = lane();
  h.net.osrmTimes = [];
  h.fake.table.fail = false;
  h.fake.table.answer = (sources) => sources.map(() => ({ distanceM: 12000, durationS: 900 }));
  const V = await victim(lng);
  const B = await helpers(null, null, lng, 0, 60);
  h.pathTo(B.gid, B.lead, 17.4838, lng, { n: 5 });
  await h.sos(V.ws, E_LAT, lng);
  await h.settle(150);
  assert.equal(h.got(B.ws, 'ASSIST_REQUEST').length, 0);
  await h.endRide(V); await h.endRide(B);
});

test('no route and OSRM down: accepted only within 2 km; at most 2 table calls per incident', async () => {
  const lng = lane();
  h.net.osrmTimes = [];
  h.fake.table.fail = true;
  let calls = h.fake.table.calls;
  const V = await victim(lng);
  const far = await helpers(null, null, lng, 0, 60); // 2.2 km
  h.pathTo(far.gid, far.lead, 17.48, lng, { n: 5 });
  const a = await h.sos(V.ws, E_LAT, lng);
  await h.settle(150);
  for (let i = 1; i <= 4; i++) { h.net.tick(Date.now() + i * 1000); await h.settle(60); }
  assert.equal(h.got(far.ws, 'ASSIST_REQUEST').length, 0, '2.2 km without a road answer: not asked');
  assert.equal(incOf(a.alertId).osrmCalls, 2);
  assert.equal(h.fake.table.calls - calls, 2, 'never more than 2 table calls');
  await h.endRide(V); await h.endRide(far);

  const lng2 = lane();
  h.net.osrmTimes = [];
  calls = h.fake.table.calls;
  const V2 = await victim(lng2);
  const near = await helpers(null, null, lng2, 0, 60); // 1.67 km
  h.pathTo(near.gid, near.lead, 17.485, lng2, { n: 5 });
  await h.sos(V2.ws, E_LAT, lng2);
  const req = await near.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(req.aheadOnRoute, false);
  assert.equal(h.fake.table.calls - calls, 1);
  h.fake.table.fail = false;
  await h.endRide(V2); await h.endRide(near);
});

test('the route-based request is sent while the road check is still waiting (never blocking)', async () => {
  const lng = lane();
  h.net.osrmTimes = [];
  h.fake.table.fail = false; h.fake.table.delayMs = 1200;
  h.fake.table.answer = (sources) => sources.map(() => ({ distanceM: 2400, durationS: 160 }));
  const V = await victim(lng);
  const low = await helpers(null, null, lng, 0, 60);
  h.pathTo(low.gid, low.lead, 17.479, lng, { n: 5 });
  const high = await helpers(line(lng, 17.40, 17.70), 17.47, lng, 0, 60);
  const t0 = Date.now();
  await h.sos(V.ws, E_LAT, lng);
  await high.ws.next((m) => m.type === 'ASSIST_REQUEST', 800);
  assert.ok(Date.now() - t0 < 900, 'route-based request did not wait for OSRM');
  assert.equal(h.got(low.ws, 'ASSIST_REQUEST').length, 0, 'fallback rider still waits for the road check');
  const lateReq = await low.ws.next((m) => m.type === 'ASSIST_REQUEST', 2500);
  assert.equal(lateReq.aheadOnRoute, false);
  h.fake.table.delayMs = 0;
  for (const R of [V, low, high]) await h.endRide(R);
});

test('own group: a member 300 m behind means no external request; 11 km behind means a request', async () => {
  const lng = lane();
  const V = await victim(lng);
  const m = await member(V, E_LAT - 0.0027, lng, 0, 0); // 300 m behind, stopped
  const B = await helpers(line(lng, 17.40, 17.70), 17.473, lng, 0, 60);
  const a = await h.sos(V.ws, E_LAT, lng);
  await h.settle(80);
  assert.equal(h.got(B.ws, 'ASSIST_REQUEST').length, 0);
  const sum = h.net.summaryFor(V.gid, a.alertId);
  assert.equal(sum.ownNearest.userId, m.u.user.userId);
  assert.equal(sum.ownNearest.routeBased, true);
  assert.ok(sum.ownNearest.distanceM >= 280 && sum.ownNearest.distanceM <= 320);
  for (const R of [V, B]) await h.endRide(R);

  const lng2 = lane();
  const V2 = await victim(lng2);
  const far = await member(V2, 17.40, lng2, 0, 60); // 11 km behind
  const B2 = await helpers(line(lng2, 17.40, 17.70), 17.473, lng2, 0, 60);
  const a2 = await h.sos(V2.ws, E_LAT, lng2);
  await B2.ws.next((x) => x.type === 'ASSIST_REQUEST');
  const up = await V2.ws.next((x) => x.type === 'EMERGENCY_UPDATE' && x.alertId === a2.alertId && x.ownNearest);
  assert.equal(up.ownNearest.userId, far.u.user.userId);
  assert.ok(up.ownNearest.etaS > 600);
  for (const R of [V2, B2]) await h.endRide(R);
});

test('caps: at most 2 per group (closest + lead), at most 3 in total', async () => {
  const lng = lane();
  const V = await victim(lng);
  const B = await helpers(line(lng, 17.40, 17.70), 17.478, lng, 0, 60); // lead 2.4 km
  const b1 = await member(B, 17.485, lng, 0, 60); // 1.67 km
  const b2 = await member(B, 17.482, lng, 0, 60); // 2.0 km, not lead
  const C = await helpers(line(lng, 17.40, 17.70), 17.47, lng, 0, 60); // 3.3 km
  const c1 = await member(C, 17.469, lng, 0, 60);
  await h.sos(V.ws, E_LAT, lng);
  await h.settle(120);
  const n = (ws) => h.got(ws, 'ASSIST_REQUEST').length;
  assert.equal(n(b1.ws), 1, 'closest of B');
  assert.equal(n(B.ws), 1, "B's lead (within 1.5 x)");
  assert.equal(n(b2.ws), 0, 'third of B never');
  assert.equal(n(B.ws) + n(b1.ws) + n(b2.ws) + n(C.ws) + n(c1.ws), 3, 'total 3');
  for (const R of [V, B, C]) await h.endRide(R);
});

test('stage 1 empty: stage 2 (10 km) at once', async () => {
  const lng = lane();
  const V = await victim(lng);
  const B = await helpers(line(lng, 17.40, 17.70), 17.42, lng, 0, 60); // 8.9 km before
  const a = await h.sos(V.ws, E_LAT, lng);
  const req = await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(req.routeDistanceM, 8900);
  assert.equal(incOf(a.alertId).stage, 2);
  await h.endRide(V); await h.endRide(B);
});

test('DECLINE asks the next rider; ACCEPT closes the others (TAKEN), a second ACCEPT is 409', async () => {
  const lng = lane();
  const V = await victim(lng);
  const B = await helpers(line(lng, 17.40, 17.70), 17.30, lng, 0, 60); // lead far (not a candidate)
  const b1 = await member(B, 17.485, lng, 0, 60);
  const b2 = await member(B, 17.48, lng, 0, 60);
  const C = await helpers(line(lng, 17.40, 17.70), 17.475, lng, 0, 60);
  const a = await h.sos(V.ws, E_LAT, lng);
  const r1 = await b1.ws.next((m) => m.type === 'ASSIST_REQUEST');
  await C.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(h.got(b2.ws, 'ASSIST_REQUEST').length, 0, 'not the lead: waits');
  b1.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: r1.incidentId, answer: 'DECLINE', clientId: 'dec-1' });
  assert.equal((await b1.ws.next((m) => m.type === 'ACK' && m.clientId === 'dec-1')).duplicate, false);
  const r2 = await b2.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(r2.incidentId, r1.incidentId, 'same incident, one request each');
  // C accepts.
  C.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: r1.incidentId, answer: 'ACCEPT', clientId: 'acc-c' });
  await C.ws.next((m) => m.type === 'ACK' && m.clientId === 'acc-c');
  const upd = await C.ws.next((m) => m.type === 'ASSIST_UPDATE');
  assert.equal(upd.myStatus, 'ACCEPTED');
  assert.ok(upd.subject && upd.subject.firstName === 'Net', 'first word of the name only');
  const closed = await b2.ws.next((m) => m.type === 'ASSIST_CLOSED');
  assert.equal(closed.reason, 'TAKEN');
  const ev = await V.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'RESPONDER_ASSIGNED' && m.network.responders.length);
  const R = ev.network.responders[0];
  assert.equal(R.name, 'Net');
  assert.equal(R.status, 'ACCEPTED');
  assert.match(R.rid, /^[0-9a-f]{12}$/);
  assert.ok(Number.isFinite(R.etaS));
  assert.equal(JSON.stringify(ev).includes(C.lead.user.userId), false, 'never the responder userId');
  assert.equal(JSON.stringify(ev).includes(C.c.groupId), false, 'never the responder group');
  assert.equal(ev.network.state, 'ASSIGNED');
  b2.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: r1.incidentId, answer: 'ACCEPT', clientId: 'acc-b2' });
  const err = await b2.ws.next((m) => m.type === 'ERROR' && m.clientId === 'acc-b2');
  assert.equal(err.code, 409);
  assert.equal(err.reason, 'TAKEN');
  assert.equal(h.t.gw.convoys.rooms.get(V.gid).alerts.get(a.alertId).status, 'RESPONDER_ASSIGNED');
  for (const X of [V, B, C]) await h.endRide(X);
});

test('CANCEL by the responder: back to ASSISTANCE_REQUESTED and the next rider is asked', async () => {
  const lng = lane();
  const V = await victim(lng);
  const A = await helpers(line(lng, 17.40, 17.70), 17.475, lng, 0, 60);
  const B = await helpers(line(lng, 17.40, 17.70), 17.30, lng, 0, 60);
  const b1 = await member(B, 17.485, lng, 0, 60);
  const b2 = await member(B, 17.48, lng, 0, 60);
  const a = await h.sos(V.ws, E_LAT, lng);
  const req = await A.ws.next((m) => m.type === 'ASSIST_REQUEST');
  await b1.ws.next((m) => m.type === 'ASSIST_REQUEST');
  A.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'c-acc' });
  await V.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'RESPONDER_ASSIGNED');
  await b1.ws.next((m) => m.type === 'ASSIST_CLOSED' && m.reason === 'TAKEN');
  A.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'CANCEL', clientId: 'c-can' });
  const gone = await A.ws.next((m) => m.type === 'ASSIST_CLOSED');
  assert.equal(gone.reason, 'CANCELLED', 'the cancelling rider drops the request and the subject details');
  await V.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'ASSISTANCE_REQUESTED');
  // 3.15 behaviour fix: b1 was told "no assistance required" (TAKEN); it is still the closest
  // capable rider of B, so it is asked again (before: never asked twice, b2 was asked instead).
  const next = await b1.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(next.incidentId, req.incidentId);
  await h.settle(40);
  assert.equal(h.got(b2.ws, 'ASSIST_REQUEST').length, 0, 'one per group unless it is the lead');
  assert.equal(h.t.gw.convoys.rooms.get(V.gid).alerts.get(a.alertId).status, 'ASSISTANCE_REQUESTED');
  for (const X of [V, A, B]) await h.endRide(X);
});

test('responder: en route, arriving, arrival check within 100 m, ARRIVED moves the emergency to ASSISTANCE_ARRIVED', async () => {
  const lng = lane();
  const V = await victim(lng);
  const A = await helpers(line(lng, 17.40, 17.70), 17.475, lng, 0, 60);
  const a = await h.sos(V.ws, E_LAT, lng);
  const req = await A.ws.next((m) => m.type === 'ASSIST_REQUEST');
  A.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'r-acc' });
  await A.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  h.place(A.gid, A.lead, 17.48, lng, 0, 60);
  await A.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'EN_ROUTE');
  const enr = await V.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.network.responders[0]?.status === 'EN_ROUTE');
  assert.ok(Number.isFinite(enr.network.responders[0].lat), 'position while en route');
  h.place(A.gid, A.lead, 17.497, lng, 0, 30);
  await A.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ARRIVING');
  h.place(A.gid, A.lead, 17.4996, lng, 0, 5);
  const chk = await A.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.arrivalCheck === true);
  assert.equal(chk.myStatus, 'ARRIVING');
  A.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ARRIVED', clientId: 'r-arr' });
  const arr = await V.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'ASSISTANCE_ARRIVED');
  assert.equal(arr.network.responders[0].status, 'ARRIVED');
  assert.ok(arr.network.responders[0].arrivedAt > 0);
  assert.equal(arr.network.responders[0].lat, undefined, 'no position once arrived');
  const stored = (await h.t.gw.repo.listAlerts(V.gid)).find((x) => x.alertId === a.alertId);
  assert.equal(stored.status, 'ASSISTANCE_ARRIVED');
  assert.equal(stored.netResponders[0].status, 'ARRIVED');
  assert.equal(stored.network, undefined, 'network summary is never stored');
  for (const X of [V, A]) await h.endRide(X);
});

test('drift: a responder whose ETA doubles gets a backup asked (the responder stays)', async () => {
  const lng = lane();
  const V = await victim(lng);
  const A = await helpers(line(lng, 17.40, 17.70), 17.475, lng, 0, 60);
  const B = await helpers(line(lng, 17.40, 17.70), 17.30, lng, 0, 60);
  const b1 = await member(B, 17.48, lng, 0, 60);
  const b2 = await member(B, 17.47, lng, 0, 60);
  await h.sos(V.ws, E_LAT, lng);
  const req = await A.ws.next((m) => m.type === 'ASSIST_REQUEST');
  await b1.ws.next((m) => m.type === 'ASSIST_REQUEST');
  A.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'd-acc' });
  await A.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  // The responder ends up far back on the road, twice.
  h.place(A.gid, A.lead, 17.40, lng, 0, 30);
  h.place(A.gid, A.lead, 17.401, lng, 0, 30);
  // b1 was closed (TAKEN) at the first ACCEPT and is still the best of B: asked again as the backup.
  const backup = await b1.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(backup.incidentId, req.incidentId);
  const inc = h.net.incidents.get(req.incidentId);
  assert.equal(inc.responders.get(A.lead.user.userId).status, 'EN_ROUTE', 'the first responder stays');
  b1.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'd-acc2' });
  await b1.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  for (const X of [V, A, B]) await h.endRide(X);
});

test('a request not answered in 60 s times out and the next rider is asked', async () => {
  const lng = lane();
  const V = await victim(lng);
  const B = await helpers(line(lng, 17.40, 17.70), 17.30, lng, 0, 60);
  const b1 = await member(B, 17.485, lng, 0, 60);
  const b2 = await member(B, 17.48, lng, 0, 60);
  const a = await h.sos(V.ws, E_LAT, lng);
  const r1 = await b1.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(h.got(b2.ws, 'ASSIST_REQUEST').length, 0);
  h.net.tick(Date.now() + 61000);
  await b2.ws.next((m) => m.type === 'ASSIST_REQUEST');
  const inc = incOf(a.alertId);
  assert.equal(inc.notified.get(b1.u.user.userId).status, 'TIMEOUT');
  assert.equal(h.got(b1.ws, 'ASSIST_CLOSED').length, 0, 'a timed out rider still sees it');
  // ... and may still accept it.
  b1.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: r1.incidentId, answer: 'ACCEPT', clientId: 't-acc' });
  await b1.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  await b2.ws.next((m) => m.type === 'ASSIST_CLOSED' && m.reason === 'TAKEN');
  for (const X of [V, B]) await h.endRide(X);
});

test('reconnect: open requests are sent again after a net1 JOIN', async () => {
  const lng = lane();
  const V = await victim(lng);
  const B = await helpers(line(lng, 17.40, 17.70), 17.473, lng, 0, 60);
  await h.sos(V.ws, E_LAT, lng);
  const req = await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  B.ws.close();
  await sleep(30);
  const again = await h.net1(B.lead.token, B.gid);
  const r2 = await again.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(r2.incidentId, req.incidentId);
  B.ws = again;
  for (const X of [V, B]) await h.endRide(X);
});

test('gateway restart: incidents are rebuilt from open alerts when the room is loaded again', async () => {
  const lng = lane();
  const V = await victim(lng);
  const a = await h.sos(V.ws, E_LAT, lng);
  await h.settle(60);
  await h.t.gw.convoys.flushAll();
  // "Restart": the network and the room forget everything in memory.
  const net = h.net;
  net.incidents.clear(); net.byAlert.clear(); net.subjects.clear(); net.responderOf.clear();
  h.t.gw.convoys.rooms.delete(V.gid);
  const room = await h.t.gw.convoys.getRoom(V.gid);
  assert.ok(room.alerts.get(a.alertId), 'alert reloaded from the database');
  assert.equal(room.alerts.get(a.alertId).status, 'ASSISTANCE_REQUESTED');
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  const B = await helpers(line(lng, 17.40, 17.70), 17.473, lng, 0, 60);
  net.tick(Date.now());
  const req = await B.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.ok(net.incidents.get(req.incidentId).alerts.some((x) => x.alertId === a.alertId));
  for (const X of [V, B]) await h.endRide(X);
});
