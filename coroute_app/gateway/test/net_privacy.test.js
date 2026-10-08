'use strict';
/**
 * 3.15 privacy of the safety network: every JSON frame an external rider receives (requests,
 * updates, closes, hazards, discovery) is walked key by key; nothing that identifies the other
 * group or its riders may appear. Medical info only after acceptance and only with the subject's
 * separate opt-in. The original group never learns the responder's id or group. Access ends at resolve.
 */
const { netBoot, line, E_LAT, sleep } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
let laneNo = 0;
const lane = () => 40 + (laneNo++) * 0.5;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

const NEW_TYPES = new Set(['ASSIST_REQUEST', 'ASSIST_UPDATE', 'ASSIST_CLOSED', 'HAZARD', 'HAZARD_CLEAR', 'DISCOVERY', 'WAVED']);
const FORBIDDEN_KEYS = ['userId', 'groupId', 'alertId', 'phone', 'emergencyContact', 'emergencyContactName', 'vehicleNo', 'joinCode', 'members', 'riders', 'name', 'email', 'medical', 'userName', 'reportedBy', 'reportedByName', 'responders'];

/** Every key path of a frame that is not allowed for external riders. */
function badKeys(frame, { medicalOk = false } = {}) {
  const bad = [];
  const walk = (v, path) => {
    if (Array.isArray(v)) { v.forEach((x, i) => walk(x, `${path}[${i}]`)); return; }
    if (!v || typeof v !== 'object') return;
    for (const [k, x] of Object.entries(v)) {
      const p = `${path}.${k}`;
      const allowed = (k === 'riders' && frame.type === 'DISCOVERY' && typeof x === 'number')
        || (k === 'medical' && medicalOk && frame.type === 'ASSIST_UPDATE');
      if (FORBIDDEN_KEYS.includes(k) && !allowed) bad.push(p);
      walk(x, p);
    }
  };
  walk(frame, frame.type);
  return bad;
}

function leaks(frames, needles) {
  const out = [];
  for (const f of frames) {
    const s = JSON.stringify(f);
    for (const n of needles) if (n && s.includes(String(n))) out.push(`${f.type}: ${n}`);
  }
  return out;
}

async function setup({ responderMedical }) {
  const lng = lane();
  const subject = await h.rider('Victim Lead');
  const r = await h.t.api('PATCH', '/me', { bloodGroup: 'O+', allergies: 'Peanut allergy', medicalNotes: 'Asthma inhaler', responderMedical }, subject.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.responderMedical, responderMedical);
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Secret Squad Name', lead: subject });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  const mate = await h.join(V, 'Mate');
  V.mws = await h.net1(mate.token, V.gid);
  h.place(V.gid, mate, 17.43219, lng + 0.00123, 0, 0); // far behind: does not change who is faster
  // External responder X (another group) and a warned-only rider W.
  const X = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Helper Crew Zeta' });
  X.ws = await h.net1(X.lead.token, X.gid);
  h.place(X.gid, X.lead, 17.475, lng, 0, 60);
  const W = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Warned Only' });
  W.ws = await h.net1(W.lead.token, W.gid);
  h.place(W.gid, W.lead, 17.455, lng, 0, 60);
  const needles = [
    subject.user.userId, mate.user.userId, V.gid, 'Secret Squad Name', subject.user.name, mate.user.name, subject.user.phone, mate.user.phone,
    '+919000000002', 'Kin Contact', subject.user.vehicleNo, V.c.joinCode, '17.43219', String(lng + 0.00123),
    ...(responderMedical ? [] : ['Peanut allergy', 'Asthma inhaler']),
  ];
  return { lng, subject, mate, V, X, W, needles };
}

test('external frames carry only the whitelisted fields; no medical without the separate opt-in', async () => {
  const s = await setup({ responderMedical: false });
  const a = await h.sos(s.V.ws, E_LAT, s.lng);
  const req = await s.X.ws.next((m) => m.type === 'ASSIST_REQUEST');
  await s.W.ws.next((m) => m.type === 'HAZARD');
  s.X.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'p-acc' });
  const upd = await s.X.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  assert.deepEqual(Object.keys(upd.subject).sort(), ['firstName', 'vehicleColor', 'vehicleType']);
  assert.equal(upd.subject.firstName, 'Net');
  assert.equal(upd.medical, undefined, 'no opt-in, no medical');
  h.place(s.X.gid, s.X.lead, 17.49, s.lng, 0, 50);
  h.place(s.V.gid, s.V.lead, E_LAT + 0.001, s.lng, 0, 3); // the subject moved a little
  await sleep(50);
  s.V.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId });
  await s.X.ws.next((m) => m.type === 'ASSIST_CLOSED');
  await s.W.ws.next((m) => m.type === 'HAZARD_CLEAR');
  const ext = [...s.X.ws.frames, ...s.W.ws.frames].filter((f) => NEW_TYPES.has(f.type));
  assert.ok(ext.length >= 4);
  for (const f of ext) assert.deepEqual(badKeys(f), [], JSON.stringify(f));
  assert.deepEqual(leaks(ext, s.needles), []);
  for (const f of ext.filter((x) => x.type === 'ASSIST_REQUEST')) {
    assert.deepEqual(Object.keys(f).filter((k) => !['type', 'ts'].includes(k)).sort(),
      ['aheadOnRoute', 'distanceM', 'etaS', 'fasterThanGroup', 'incidentId', 'kind', 'lastUpdateAt', 'lat', 'lng', 'reportedAt', 'routeDistanceM', 'severity']);
  }
  // Nothing about the responder's identity reaches the subject's group.
  const own = [...s.V.ws.frames, ...s.V.mws.frames];
  assert.deepEqual(leaks(own, [s.X.lead.user.userId, s.X.gid, 'Helper Crew Zeta', s.X.lead.user.name, s.X.lead.user.phone, s.X.c.joinCode]), []);
  assert.ok(own.some((f) => f.type === 'EMERGENCY_UPDATE' && f.network.responders.some((r) => r.name === 'Net')));
  for (const X of [s.V, s.X, s.W]) await h.endRide(X);
});

test('medical info goes to an accepted responder only with responderMedical, never before acceptance', async () => {
  const s = await setup({ responderMedical: true });
  await h.sos(s.V.ws, E_LAT, s.lng);
  const req = await s.X.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(req.medical, undefined);
  assert.equal(h.got(s.X.ws, 'ASSIST_UPDATE').length, 0);
  s.X.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'm-acc' });
  const upd = await s.X.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  assert.deepEqual(upd.medical, { bloodGroup: 'O+', allergies: 'Peanut allergy', notes: 'Asthma inhaler' });
  assert.deepEqual(badKeys(upd, { medicalOk: true }), []);
  assert.equal(h.got(s.W.ws, 'HAZARD').every((f) => f.medical === undefined), true);
  // The responder cancels: their phone drops the request (and with it the medical info).
  s.X.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'CANCEL', clientId: 'm-can' });
  const closed = await s.X.ws.next((m) => m.type === 'ASSIST_CLOSED');
  assert.equal(closed.incidentId, req.incidentId);
  for (const X of [s.V, s.X, s.W]) await h.endRide(X);
});

test('a rider who was never asked gets 404 for a real incident id; access ends at resolve', async () => {
  const s = await setup({ responderMedical: false });
  const a = await h.sos(s.V.ws, E_LAT, s.lng);
  const req = await s.X.ws.next((m) => m.type === 'ASSIST_REQUEST');
  // W only got a hazard: cannot accept, but may report a false alert.
  s.W.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'w-acc' });
  const e1 = await s.W.ws.next((m) => m.type === 'ERROR' && m.clientId === 'w-acc');
  assert.equal(e1.code, 404);
  assert.equal(e1.reason, 'INCIDENT_CLOSED');
  // A stranger in an unrelated ride: 404 too (no oracle of existence), also for a malformed id.
  const Z = await h.rideOn(null, { name: 'Stranger' });
  const zws = await h.net1(Z.lead.token, Z.gid);
  zws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'z-acc' });
  assert.equal((await zws.next((m) => m.type === 'ERROR' && m.clientId === 'z-acc')).code, 404);
  zws.sendJson({ type: 'ASSIST_ANSWER', incidentId: 'NET-XYZ', answer: 'ACCEPT', clientId: 'z-bad' });
  assert.equal((await zws.next((m) => m.type === 'ERROR' && m.clientId === 'z-bad')).code, 404);
  s.X.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'x-acc' });
  await s.X.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  s.V.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId });
  await s.X.ws.next((m) => m.type === 'ASSIST_CLOSED' && m.reason === 'RESOLVED');
  const before = s.X.ws.frames.length;
  h.place(s.V.gid, s.V.lead, E_LAT + 0.002, s.lng, 0, 5);
  h.place(s.X.gid, s.X.lead, 17.499, s.lng, 0, 20);
  await sleep(60);
  assert.equal(s.X.ws.frames.slice(before).filter((f) => NEW_TYPES.has(f.type)).length, 0, 'no updates after close');
  s.X.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ARRIVED', clientId: 'x-arr' });
  assert.equal((await s.X.ws.next((m) => m.type === 'ERROR' && m.clientId === 'x-arr')).code, 404);
  s.X.ws.sendJson({ type: 'NET_REPORT_FALSE', incidentId: req.incidentId, clientId: 'x-rep' });
  assert.equal((await s.X.ws.next((m) => m.type === 'ERROR' && m.clientId === 'x-rep')).code, 404);
  zws.close();
  for (const X of [s.V, s.X, s.W, Z]) await h.endRide(X);
});

test('discovery frames: group name and rider count only, never coordinates or member names', async () => {
  const lng = lane();
  const A = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Public North' });
  const B = await h.rideOn(line(lng, 17.70, 17.40), { name: 'Public South' });
  for (const R of [A, B]) {
    R.ws = await h.net1(R.lead.token, R.gid);
    R.ws.sendJson({ type: 'CONFIG', visibility: 'PUBLIC', discovery: true });
    await R.ws.next((m) => m.type === 'CONFIG' && m.visibility === 'PUBLIC');
  }
  h.place(A.gid, A.lead, 17.47123, lng, 0, 60);
  h.place(B.gid, B.lead, 17.50456, lng, 180, 60);
  h.t.gw.discovery.tick(Date.now());
  const da = await A.ws.next((m) => m.type === 'DISCOVERY');
  const db = await B.ws.next((m) => m.type === 'DISCOVERY');
  for (const f of [da, db]) assert.deepEqual(badKeys(f), []);
  assert.deepEqual(leaks([da], [B.lead.user.userId, B.gid, B.lead.user.name, '17.50456', B.c.joinCode]), []);
  assert.deepEqual(leaks([db], [A.lead.user.userId, A.gid, A.lead.user.name, '17.47123', A.c.joinCode]), []);
  assert.equal(da.groupName, 'Public South');
  for (const X of [A, B]) await h.endRide(X);
});
