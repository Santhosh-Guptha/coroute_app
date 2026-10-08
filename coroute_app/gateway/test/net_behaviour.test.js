'use strict';
/**
 * 3.15 behaviour / privacy / safety scenarios (adversarial tester). The brief's target experience,
 * end to end, on one synthetic highway (a meridian, northbound "Hyderabad to Goa" route):
 *   A  "Hyderabad to Goa", 8 riders: Rahul crashes at E (17.500); the other 7 are 9 km ahead.
 *   B  3 riders on the same road behind him: Arjun 1.7 km, the lead 2.0 km, a third 3.3 km.
 *   C  approaching the accident road on a side road that joins the highway 2.2 km before E.
 *   D  on the other carriageway (own southbound route), 3.3 km before E, coming toward it.
 *   E  southbound 8.9 km away (same road, out of the first radius).
 *   P  passed (1.3 km north of E, still northbound), Q a parallel road 1 km east.
 * The whole scenario runs twice: A, B, C Private with D, E Public, then the reverse. Safety must
 * be identical; discovery only ever pairs two Public groups and never during an emergency.
 */
const { netBoot, line, E_LAT, sleep } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
let laneNo = 0;
const lane = () => 120 + (laneNo++) * 0.5;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

const OLD_TYPES = new Set(['HELLO', 'SNAPSHOT', 'ALERT', 'ALERT_RESOLVED', 'TELEMETRY', 'RIDER_UPDATE', 'RIDER_JOINED', 'RIDER_LEFT', 'CHAT', 'ACK', 'ERROR',
  'SOS_RESPONSE', 'TIMELINE_EVENT', 'TIMELINE_UPDATE', 'CONFIG', 'TRIP_STATUS', 'PRESENCE', 'FLEET', 'ROSTER_CHANGED', 'WAIT', 'STATUS', 'BROADCAST',
  'STOP_ADDED', 'STOPS', 'ROUTE', 'MEMBERS', 'PONG', 'PRESENCE_CHANGED']);
const NEW_TYPES = ['EMERGENCY_UPDATE', 'ASSIST_REQUEST', 'ASSIST_UPDATE', 'ASSIST_CLOSED', 'HAZARD', 'HAZARD_CLEAR', 'DISCOVERY', 'WAVED'];

let run = 0;
/** A rider whose first name is `name`'s first word (callsigns must be unique: the last word gets a run letter). */
async function person(name, extra = {}) { return h.rider(name.split(' ')[0], { name: `${name}${'XYZW'[run % 4]}${run}`, ...extra }); }

async function joinAs(ride, user) {
  const r = await h.t.api('POST', '/convoys/join', { code: ride.c.joinCode }, user.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  return user;
}

async function setVisibility(ride, ws, pub) {
  ws.sendJson({ type: 'CONFIG', visibility: pub ? 'PUBLIC' : 'PRIVATE', discovery: pub });
  await ws.next((m) => m.type === 'CONFIG' && m.visibility === (pub ? 'PUBLIC' : 'PRIVATE'));
}

/** Every socket's frames of the given types. */
const of = (ws, ...types) => ws.frames.filter((f) => types.includes(f.type));

async function scenario({ abcPublic }) {
  run++;
  const lng = lane();
  const north = line(lng, 17.40, 17.70);
  const south = line(lng, 17.70, 17.40);
  // ---- A: Rahul's group (Rahul + 7 riders 9 km ahead). Rahul shares medical with his group only.
  const aLead = await person('Kiran Lead');
  const A = await h.rideOn(north, { name: 'Hyderabad to Goa', lead: aLead });
  const rahul = await joinAs(A, await person('Rahul Sharma', { bloodGroup: 'B+', allergies: 'Penicillin' }));
  const aMembers = [aLead];
  for (let i = 0; i < 6; i++) aMembers.push(await joinAs(A, await person(`Amember${i} Rider`)));
  A.ws = await h.net1(A.lead.token, A.gid);
  A.rws = await h.net1(rahul.token, A.gid);
  A.old = await h.oldApp(aMembers[1].token, A.gid); // a 3.14 phone in the group
  for (const [i, m] of aMembers.entries()) h.place(A.gid, m, 17.581 + i * 0.0003, lng, 0, 60);
  h.place(A.gid, rahul, E_LAT, lng, 0, 0);
  // ---- B: same road behind Rahul.
  const bLead = await person('Bharat Lead');
  const B = await h.rideOn(north, { name: 'Weekend Riders', lead: bLead });
  const arjun = await joinAs(B, await person('Arjun Rao'));
  const b3 = await joinAs(B, await person('Bmember Third'));
  B.ws = await h.net1(bLead.token, B.gid);
  B.aws = await h.net1(arjun.token, B.gid);
  B.b3ws = await h.net1(b3.token, B.gid);
  h.place(B.gid, arjun, 17.4847, lng, 0, 60);
  h.place(B.gid, bLead, 17.482, lng, 0, 60);
  h.place(B.gid, b3, 17.470, lng, 0, 60);
  // ---- C: side road (from the west) joining the highway at 17.48, then north through E.
  const cRoute = [{ lat: 17.47, lng: lng - 0.03 }, { lat: 17.475, lng: lng - 0.015 }, ...line(lng, 17.48, 17.70)];
  const C = await h.rideOn(cRoute, { name: 'Coastal Crew' });
  C.ws = await h.net1(C.lead.token, C.gid);
  h.place(C.gid, C.lead, 17.4725, lng - 0.0225, 72, 60);
  // ---- D: southbound carriageway, coming toward E. E: southbound, 8.9 km away.
  const D = await h.rideOn(south, { name: 'Deccan Cruisers' });
  D.ws = await h.net1(D.lead.token, D.gid);
  h.place(D.gid, D.lead, 17.53, lng, 180, 60);
  const Eg = await h.rideOn(south, { name: 'Eastern Wheels' });
  Eg.ws = await h.net1(Eg.lead.token, Eg.gid);
  h.place(Eg.gid, Eg.lead, 17.58, lng, 180, 60);
  // ---- P passed, Q parallel road.
  const P = await h.rideOn(north, { name: 'Passed Pack' });
  P.ws = await h.net1(P.lead.token, P.gid);
  h.place(P.gid, P.lead, 17.512, lng, 0, 60);
  const Q = await h.rideOn(line(lng + 0.0095, 17.40, 17.70), { name: 'Parallel Pals' });
  Q.ws = await h.net1(Q.lead.token, Q.gid);
  h.place(Q.gid, Q.lead, 17.49, lng + 0.0095, 0, 60);

  for (const [R, pub] of [[A, abcPublic], [B, abcPublic], [C, abcPublic], [D, !abcPublic], [Eg, !abcPublic]]) await setVisibility(R, R.ws, pub);
  const externals = { arjun: B.aws, bLead: B.ws, b3: B.b3ws, C: C.ws, D: D.ws, E: Eg.ws, P: P.ws, Q: Q.ws };
  for (const ws of [...Object.values(externals), A.ws, A.rws, A.old]) ws.frames.length = 0;

  // ================= Rahul crashes (no answer to the 15 s countdown: CRASH_AUTO).
  const alert = await h.sos(A.rws, E_LAT, lng, { source: 'CRASH_AUTO', auto: true, heading: 0, speedKmh: 0, accuracyM: 12 });
  assert.equal(alert.status, 'CONFIRMED_ACCIDENT');
  assert.equal(alert.severity, 'CRITICAL');
  // Own group alerted at once, also the 3.14 phone.
  await A.ws.next((m) => m.type === 'ALERT' && m.alert.alertId === alert.alertId);
  await A.old.next((m) => m.type === 'ALERT' && m.alert.alertId === alert.alertId);
  await h.settle(60);

  const asked = Object.entries(externals).filter(([, ws]) => of(ws, 'ASSIST_REQUEST').length).map(([k]) => k).sort();
  const warned = Object.entries(externals).filter(([, ws]) => of(ws, 'HAZARD').length).map(([k]) => k).sort();
  assert.deepEqual(asked, ['D', 'arjun', 'bLead'], 'best 3: closest of B, B lead, D coming toward it; C (slower) not yet');
  // Warned: everyone approaching on the same road (the asked riders too: their phone shows the request
  // instead of the warning, AlertPolicy.network); never the passed, parallel or far riders.
  assert.deepEqual(warned, ['C', 'D', 'arjun', 'b3', 'bLead'], 'never P, Q, E');
  for (const ws of [A.ws, A.rws]) assert.equal(of(ws, 'ASSIST_REQUEST', 'HAZARD').length, 0, 'own group never gets external frames');
  const req = of(B.aws, 'ASSIST_REQUEST')[0];
  assert.equal(req.aheadOnRoute, true);
  assert.equal(req.distanceM, 1700);
  assert.equal(req.kind, 'ACCIDENT');
  const incidentId = req.incidentId;
  const up1 = await A.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.network.state === 'REQUESTED');
  assert.equal(up1.status, 'ASSISTANCE_REQUESTED');
  assert.equal(up1.network.notified, 3);
  assert.ok(up1.ownNearest && up1.ownNearest.routeBased, 'nearest own member measured along the route');
  assert.ok(up1.ownNearest.etaS >= 540, `own nearest is 9 km ahead (U-turn): ${up1.ownNearest.etaS}`);

  // ================= Arjun accepts.
  B.aws.sendJson({ type: 'ASSIST_ANSWER', incidentId, answer: 'ACCEPT', clientId: 'acc-arjun' });
  await B.aws.next((m) => m.type === 'ACK' && m.clientId === 'acc-arjun');
  const accUpd = await B.aws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  assert.equal(accUpd.subject.firstName, 'Rahul');
  assert.equal(accUpd.medical, undefined, 'no medical: Rahul did not opt in for responders');
  for (const ws of [B.ws, D.ws]) assert.equal((await ws.next((m) => m.type === 'ASSIST_CLOSED')).reason, 'TAKEN');
  const assigned = await A.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'RESPONDER_ASSIGNED' && m.network.responders.length);
  assert.equal(assigned.network.responders[0].name, 'Arjun');
  // Hazard recipients learn help is on the way.
  await C.ws.next((m) => m.type === 'HAZARD' && m.level === 'RESPONDER_ARRIVING');

  // ================= Arjun cannot make it: the best remaining rider (B lead, told "not needed") is asked again.
  B.aws.sendJson({ type: 'ASSIST_ANSWER', incidentId, answer: 'UNABLE', clientId: 'un-arjun' });
  assert.equal((await B.aws.next((m) => m.type === 'ASSIST_CLOSED')).reason, 'CANCELLED');
  await A.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'ASSISTANCE_REQUESTED');
  const again = await B.ws.next((m) => m.type === 'ASSIST_REQUEST', 1500);
  assert.equal(again.incidentId, incidentId, 'the B lead is asked again (closest capable rider)');

  // ================= B lead accepts, rides there, arrives.
  B.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId, answer: 'ACCEPT', clientId: 'acc-blead' });
  await B.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  h.place(B.gid, bLead, 17.49, lng, 0, 60);
  await B.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'EN_ROUTE');
  h.place(B.gid, bLead, 17.4996, lng, 0, 5);
  await B.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.arrivalCheck === true);
  B.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId, answer: 'ARRIVED', clientId: 'arr-blead' });
  const arrived = await A.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.status === 'ASSISTANCE_ARRIVED');
  assert.equal(arrived.network.responders.find((r) => r.status === 'ARRIVED').name, 'Bharat');
  await C.ws.next((m) => m.type === 'HAZARD' && m.level === 'ON_SCENE');

  // ================= Discovery during the emergency.
  h.t.gw.discovery.tick(Date.now());
  await h.settle(40);
  const disc = Object.fromEntries(Object.entries({ ...externals, A: A.ws }).map(([k, ws]) => [k, of(ws, 'DISCOVERY')]));
  if (abcPublic) {
    // A has an open emergency, B an active responder: nothing for anyone (C's only partners are suppressed).
    for (const [k, list] of Object.entries(disc)) assert.equal(list.length, 0, `no discovery for ${k} during the emergency`);
  } else {
    // D and E are the only Public pair: they see each other and nothing else.
    assert.equal(disc.D.length, 1); assert.equal(disc.D[0].groupName, 'Eastern Wheels');
    assert.equal(disc.E.length, 1); assert.equal(disc.E[0].groupName, 'Deccan Cruisers');
    for (const k of ['A', 'arjun', 'bLead', 'b3', 'C', 'P', 'Q']) assert.equal(disc[k].length, 0, `no discovery for private ${k}`);
  }

  // ================= Resolved by Rahul's group.
  A.ws.sendJson({ type: 'SOS_RESOLVE', alertId: alert.alertId });
  await A.ws.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === alert.alertId);
  assert.equal((await B.ws.next((m) => m.type === 'ASSIST_CLOSED' && m.reason !== 'TAKEN')).reason, 'RESOLVED');
  for (const ws of [C.ws, B.b3ws]) await ws.next((m) => m.type === 'HAZARD_CLEAR');
  assert.equal(h.net.incidents.has(incidentId), false, 'incident memory freed');
  assert.equal(h.net.responderOf.has(bLead.user.userId), false);
  assert.equal(h.net.subjects.has(rahul.user.userId), false);
  B.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId, answer: 'ARRIVED', clientId: 'late' });
  assert.equal((await B.ws.next((m) => m.type === 'ERROR' && m.clientId === 'late')).reason, 'INCIDENT_CLOSED');

  // ================= Privacy walk over everything external riders received.
  const aNeedles = [A.gid, 'Hyderabad to Goa', rahul.user.userId, rahul.user.phone, rahul.user.name, rahul.user.name.split(' ')[1], 'Penicillin', 'B+', rahul.user.vehicleNo,
    ...aMembers.flatMap((m) => [m.user.userId, m.user.name, m.user.phone]), '+919000000002', 'Kin Contact', A.c.joinCode, '17.581'];
  for (const [k, ws] of Object.entries(externals)) {
    const s = JSON.stringify(ws.frames.filter((f) => NEW_TYPES.includes(f.type)));
    for (const n of aNeedles) assert.equal(s.includes(String(n)), false, `${k} received ${n}`);
  }
  // The original group never learns the responders' ids, group or names beyond the first name.
  const bNeedles = [B.gid, 'Weekend Riders', arjun.user.userId, bLead.user.userId, arjun.user.phone, bLead.user.phone, 'Rao', arjun.user.vehicleNo, bLead.user.vehicleNo, B.c.joinCode];
  for (const ws of [A.ws, A.rws, A.old]) {
    const s = JSON.stringify(ws.frames);
    for (const n of bNeedles) assert.equal(s.includes(String(n)), false, `A received ${n}`);
  }
  // 3.14 phone: never a new type.
  const oldTypes = new Set(A.old.frames.map((f) => f.type));
  for (const t of NEW_TYPES) assert.equal(oldTypes.has(t), false, `old app got ${t}`);
  // Audit trail written, codes only.
  await sleep(2200);
  const rows = await h.t.gw.repo.listAudit({ limit: 500 });
  const mine = rows.filter((r) => r.incidentId === incidentId || r.alertId === alert.alertId);
  for (const kind of ['RAISE', 'NOTIFY', 'ANSWER', 'HAZARD', 'RESOLVE']) assert.ok(mine.some((r) => r.kind === kind), `audit ${kind}`);
  assert.equal(JSON.stringify(mine).includes(String(E_LAT)), false, 'no coordinates in the audit');

  for (const R of [A, B, C, D, Eg, P, Q]) await h.endRide(R);
  return { asked, warned };
}

test('brief scenario (A, B, C Private; D, E Public): closest capable riders asked, TAKEN rider asked again, privacy, cleanup', async () => {
  const r1 = await scenario({ abcPublic: false });
  const r2 = await scenario({ abcPublic: true });
  assert.deepEqual(r2, r1, 'Public / Private never changes who is asked or warned');
});

test('clustered SOS of two groups: each group keeps its own rider position (no other group rider position leaks)', async () => {
  const lng = lane();
  const A = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Group One' });
  A.ws = await h.net1(A.lead.token, A.gid);
  h.place(A.gid, A.lead, E_LAT, lng, 0, 0);
  const F = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Group Two' });
  F.ws = await h.net1(F.lead.token, F.gid);
  h.place(F.gid, F.lead, E_LAT + 0.0008, lng, 0, 0);
  const a = await h.sos(A.ws, E_LAT, lng);
  const f = await h.sos(F.ws, E_LAT + 0.0008, lng);
  assert.equal(h.net.byAlert.get(a.alertId), h.net.byAlert.get(f.alertId), 'one incident');
  F.ws.frames.length = 0;
  // A's injured rider is moved 120 m (ambulance): Group Two must not get that position.
  h.place(A.gid, A.lead, E_LAT - 0.0011, lng + 0.0002, 0, 20);
  h.net._pushUpdate(h.net.incidents.get(h.net.byAlert.get(a.alertId)), { force: true });
  await h.settle(40);
  const ups = of(F.ws, 'EMERGENCY_UPDATE').filter((m) => m.alertId === f.alertId);
  assert.ok(ups.length >= 1);
  for (const u of ups) {
    assert.notEqual(u.lat, +(E_LAT - 0.0011).toFixed(5), 'Group Two never sees Group One rider position');
    assert.equal(u.lat, +(E_LAT + 0.0008).toFixed(5));
  }
  const ownUp = await A.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.alertId === a.alertId && m.lat === +(E_LAT - 0.0011).toFixed(5));
  assert.ok(ownUp, 'the own group follows its own rider');
  await h.endRide(A); await h.endRide(F);
});

test('abuse: a rider cannot answer, arrive or report for an incident they were not asked about; ids are not guessable', async () => {
  const lng = lane();
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victims' });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  const X = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Asked' });
  X.ws = await h.net1(X.lead.token, X.gid);
  h.place(X.gid, X.lead, 17.48, lng, 0, 60);
  const M = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Mallory' });
  M.ws = await h.net1(M.lead.token, M.gid);
  h.place(M.gid, M.lead, 17.30, lng, 0, 0); // far, stopped: never asked
  const a = await h.sos(V.ws, E_LAT, lng);
  const req = await X.ws.next((m) => m.type === 'ASSIST_REQUEST');
  for (const [i, answer] of ['ACCEPT', 'ARRIVED', 'NOT_FOUND', 'UNABLE'].entries()) {
    M.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer, clientId: `m${i}` });
    const e = await M.ws.next((m) => m.type === 'ERROR' && m.clientId === `m${i}`);
    assert.equal(e.code, 404, `${answer} by a stranger`);
  }
  M.ws.sendJson({ type: 'NET_REPORT_FALSE', incidentId: req.incidentId, clientId: 'mf' });
  assert.equal((await M.ws.next((m) => m.type === 'ERROR' && m.clientId === 'mf')).code, 404);
  // Spoofing another rider's arrival: answers always act for the socket's own user.
  X.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ARRIVED', clientId: 'x-arr' });
  assert.equal((await X.ws.next((m) => m.type === 'ERROR' && m.clientId === 'x-arr')).reason, 'NOT_RESPONDING');
  // Reading other emergencies: a stranger cannot fetch the group's convoy or join its room.
  const g = await h.t.api('GET', `/convoys/${V.gid}`, null, M.lead.token);
  assert.equal(g.status, 403);
  // Visibility: only the lead.
  const mate = await h.join(V, 'Mate');
  const mws = await h.net1(mate.token, V.gid);
  mws.sendJson({ type: 'CONFIG', visibility: 'PUBLIC', discovery: true });
  const ce = await mws.next((m) => m.type === 'ERROR');
  assert.equal(ce.code, 403);
  assert.equal(h.t.gw.convoys.rooms.get(V.gid).meta.visibility || 'PRIVATE', 'PRIVATE');
  assert.equal(h.net.incidents.get(h.net.byAlert.get(a.alertId)).responders.size, 0);
  await h.endRide(V); await h.endRide(X); await h.endRide(M);
});

test('WAVE never reaches a group during its emergency', async () => {
  const lng = lane();
  const D = await h.rideOn(line(lng, 17.70, 17.40), { name: 'Wave One' });
  D.ws = await h.net1(D.lead.token, D.gid);
  const E = await h.rideOn(line(lng, 17.70, 17.40), { name: 'Wave Two' });
  E.ws = await h.net1(E.lead.token, E.gid);
  for (const R of [D, E]) await setVisibility(R, R.ws, true);
  h.place(D.gid, D.lead, 17.53, lng, 180, 60);
  h.place(E.gid, E.lead, 17.56, lng, 180, 60);
  h.t.gw.discovery.tick(Date.now());
  const dd = await D.ws.next((m) => m.type === 'DISCOVERY' && m.state === 'NEW');
  await E.ws.next((m) => m.type === 'DISCOVERY' && m.state === 'NEW');
  // E has an emergency now.
  h.place(E.gid, E.lead, 17.56, lng, 180, 0);
  await h.sos(E.ws, 17.56, lng);
  E.ws.frames.length = 0;
  D.ws.sendJson({ type: 'WAVE', encounterId: dd.encounterId, clientId: 'w1' });
  await D.ws.next((m) => (m.type === 'ACK' || m.type === 'ERROR') && m.clientId === 'w1');
  await h.settle(40);
  assert.equal(of(E.ws, 'WAVED').length, 0, 'social never shown during an emergency');
  await h.endRide(D); await h.endRide(E);
});

test('3.14 phone SOS still triggers the network; the 3.14 rider is never asked or warned', async () => {
  const lng = lane();
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Old Phones' });
  const old = await h.oldApp(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  const X = await h.rideOn(line(lng, 17.40, 17.70), { name: 'New Phones' });
  X.ws = await h.net1(X.lead.token, X.gid);
  h.place(X.gid, X.lead, 17.48, lng, 0, 60);
  const O = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Old Helper' });
  O.ws = await h.oldApp(O.lead.token, O.gid);
  h.place(O.gid, O.lead, 17.485, lng, 0, 60);
  old.sendJson({ type: 'SOS', lat: E_LAT, lng, alertType: 'CRASH', auto: true, clientId: 'old-sos' });
  await old.next((m) => m.type === 'ALERT');
  await X.ws.next((m) => m.type === 'ASSIST_REQUEST');
  await h.settle(40);
  for (const t of NEW_TYPES) {
    assert.equal(old.frames.some((f) => f.type === t), false, `old subject phone got ${t}`);
    assert.equal(O.ws.frames.some((f) => f.type === t), false, `old helper phone got ${t}`);
  }
  await h.endRide(V); await h.endRide(X); await h.endRide(O);
});
