'use strict';
/**
 * 3.15 rider discovery (social, opt-in): only when BOTH groups are Public with discovery on;
 * encounter kinds from route geometry; throttling; suppression under an emergency; WAVE; CONFIG.
 */
const { netBoot, line } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
let laneNo = 0;
const lane = () => 20 + (laneNo++) * 0.5;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

async function group(points, name, { pub = true, disc = true } = {}) {
  const G = await h.rideOn(points, { name });
  G.ws = await h.net1(G.lead.token, G.gid);
  if (pub || disc) {
    G.ws.sendJson({ type: 'CONFIG', visibility: pub ? 'PUBLIC' : 'PRIVATE', discovery: disc });
    await G.ws.next((m) => m.type === 'CONFIG');
  }
  return G;
}
const tick = () => h.t.gw.discovery.tick(Date.now());
const disc = (G) => h.got(G.ws, 'DISCOVERY');

test('both Public with discovery on: opposite directions on the same highway, meeting in about 2 minutes', async () => {
  const lng = lane();
  const A = await group(line(lng, 17.40, 17.70), 'North Riders');
  const B = await group(line(lng, 17.70, 17.40), 'South Riders');
  const b2 = await h.join(B, 'Second');
  h.place(A.gid, A.lead, 17.47, lng, 0, 60);
  h.place(B.gid, B.lead, 17.505, lng, 180, 60);
  h.place(B.gid, b2, 17.506, lng, 180, 60);
  tick();
  const da = await A.ws.next((m) => m.type === 'DISCOVERY');
  const db = await B.ws.next((m) => m.type === 'DISCOVERY');
  assert.equal(da.state, 'NEW');
  assert.equal(da.encounterType, 'OPPOSITE_DIRECTION');
  assert.equal(da.groupName, 'South Riders');
  assert.equal(da.riders, 2);
  assert.equal(da.distanceM, 4000, 'rounded to 500 m below 5 km');
  assert.equal(da.meetingS, 120);
  assert.equal(da.sameRoute, true);
  assert.equal(db.groupName, 'North Riders');
  assert.equal(db.encounterId, da.encounterId);
  for (const f of [da, db]) { assert.equal(f.lat, undefined); assert.equal(f.lng, undefined); }
  // Throttle: nothing new on the next tick.
  tick();
  await h.settle();
  assert.equal(disc(A).length, 1);
  for (const X of [A, B]) await h.endRide(X);
});

test('one side Private, or discovery off: nothing for either group', async () => {
  const lng = lane();
  const A = await group(line(lng, 17.40, 17.70), 'Open Group');
  const B = await group(line(lng, 17.70, 17.40), 'Closed Group', { pub: false, disc: true });
  const lng2 = lane();
  const C = await group(line(lng2, 17.40, 17.70), 'Open Two');
  const D = await group(line(lng2, 17.70, 17.40), 'Public No Discovery', { pub: true, disc: false });
  h.place(A.gid, A.lead, 17.47, lng, 0, 60); h.place(B.gid, B.lead, 17.505, lng, 180, 60);
  h.place(C.gid, C.lead, 17.47, lng2, 0, 60); h.place(D.gid, D.lead, 17.505, lng2, 180, 60);
  tick();
  await h.settle();
  for (const G of [A, B, C, D]) assert.equal(disc(G).length, 0);
  for (const X of [A, B, C, D]) await h.endRide(X);
});

test('parallel roads that never meet: nothing', async () => {
  const lng = lane();
  const A = await group(line(lng, 17.40, 17.70), 'Left Road');
  const B = await group(line(lng + 0.0095, 17.40, 17.70), 'Right Road');
  h.place(A.gid, A.lead, 17.47, lng, 0, 60);
  h.place(B.gid, B.lead, 17.48, lng + 0.0095, 0, 60);
  tick();
  await h.settle();
  assert.equal(disc(A).length + disc(B).length, 0);
  for (const X of [A, B]) await h.endRide(X);
});

test('same direction on the same route: SAME_DIRECTION with a catch-up time', async () => {
  const lng = lane();
  const A = await group(line(lng, 17.40, 17.70), 'Fast Pack');
  const B = await group(line(lng, 17.40, 17.70), 'Slow Pack');
  h.place(A.gid, A.lead, 17.47, lng, 0, 60);
  h.place(B.gid, B.lead, 17.49, lng, 0, 40);
  tick();
  const da = await A.ws.next((m) => m.type === 'DISCOVERY');
  assert.equal(da.encounterType, 'SAME_DIRECTION');
  assert.equal(da.sameRoute, true);
  assert.ok(da.meetingS >= 360 && da.meetingS <= 420, `meeting ${da.meetingS}`);
  for (const X of [A, B]) await h.endRide(X);
});

test('converging routes (joining the same road ahead) and crossing routes', async () => {
  const lng = lane();
  const join = [];
  for (let i = 0; i <= 5; i++) join.push({ lat: +(17.45 + 0.01 * i).toFixed(5), lng: +(lng - 0.03 + 0.006 * i).toFixed(5) });
  const A = await group([...join, ...line(lng, 17.52, 17.70)], 'Joining Pack');
  const B = await group(line(lng, 17.40, 17.70), 'Main Road Pack');
  h.place(A.gid, A.lead, 17.455, lng - 0.027, 30, 60);
  h.place(B.gid, B.lead, 17.47, lng, 0, 40);
  tick();
  const da = await A.ws.next((m) => m.type === 'DISCOVERY');
  assert.equal(da.encounterType, 'CONVERGING');
  assert.equal(da.sameRoute, true);
  assert.ok(da.meetingS > 0);
  for (const X of [A, B]) await h.endRide(X);

  const lng2 = lane();
  const C = await group([{ lat: 17.5, lng: lng2 - 0.03 }, { lat: 17.5, lng: lng2 + 0.03 }], 'Cross Pack');
  const D = await group(line(lng2, 17.40, 17.70), 'Highway Pack');
  h.place(C.gid, C.lead, 17.5, lng2 - 0.02, 90, 60);
  h.place(D.gid, D.lead, 17.488, lng2, 0, 40);
  tick();
  const dc = await C.ws.next((m) => m.type === 'DISCOVERY');
  assert.equal(dc.encounterType, 'CROSSING');
  assert.equal(dc.sameRoute, false);
  for (const X of [C, D]) await h.endRide(X);
});

test('END when the groups are far apart; again only after DISCOVERY_RENOTIFY_MIN', async () => {
  const lng = lane();
  const A = await group(line(lng, 17.40, 17.70), 'Pack One');
  const B = await group(line(lng, 17.70, 17.40), 'Pack Two');
  h.place(A.gid, A.lead, 17.47, lng, 0, 60);
  h.place(B.gid, B.lead, 17.505, lng, 180, 60);
  tick();
  const first = await A.ws.next((m) => m.type === 'DISCOVERY');
  // They pass each other and ride apart.
  h.place(A.gid, A.lead, 17.69, lng, 0, 60);
  h.place(B.gid, B.lead, 17.41, lng, 180, 60);
  tick();
  const end = await A.ws.next((m) => m.type === 'DISCOVERY' && m.state === 'END');
  assert.equal(end.encounterId, first.encounterId);
  await B.ws.next((m) => m.type === 'DISCOVERY' && m.state === 'END');
  // Close again within the hour: nothing.
  h.place(A.gid, A.lead, 17.47, lng, 0, 60);
  h.place(B.gid, B.lead, 17.505, lng, 180, 60);
  tick();
  await h.settle();
  assert.equal(disc(A).filter((f) => f.state === 'NEW').length, 1);
  // An hour later: a new encounter.
  for (const st of h.t.gw.discovery.encounters.values()) { st.notifiedAt -= 61 * 60000; st.endedAt -= 61 * 60000; }
  tick();
  const again = await A.ws.next((m) => m.type === 'DISCOVERY' && m.state === 'NEW');
  assert.notEqual(again.encounterId, first.encounterId);
  for (const X of [A, B]) await h.endRide(X);
});

test('a group with an open emergency gets no discovery (and is not announced)', async () => {
  const lng = lane();
  const A = await group(line(lng, 17.40, 17.70), 'Trouble Pack');
  const B = await group(line(lng, 17.70, 17.40), 'Calm Pack');
  h.place(A.gid, A.lead, 17.47, lng, 0, 0);
  h.place(B.gid, B.lead, 17.505, lng, 180, 60);
  await h.sos(A.ws, 17.47, lng, { alertType: 'MECHANICAL' });
  tick();
  await h.settle();
  assert.equal(disc(A).length + disc(B).length, 0);
  for (const X of [A, B]) await h.endRide(X);
});

test('WAVE: the other group gets WAVED; again within 5 minutes is 429; unknown encounter 404', async () => {
  const lng = lane();
  const A = await group(line(lng, 17.40, 17.70), 'Wave North');
  const B = await group(line(lng, 17.70, 17.40), 'Wave South');
  const a2 = await h.join(A, 'Pillion');
  const a2ws = await h.net1(a2.token, A.gid);
  h.place(A.gid, A.lead, 17.47, lng, 0, 60);
  h.place(B.gid, B.lead, 17.505, lng, 180, 60);
  tick();
  const d = await A.ws.next((m) => m.type === 'DISCOVERY');
  A.ws.sendJson({ type: 'WAVE', encounterId: d.encounterId, clientId: 'w1' });
  await A.ws.next((m) => m.type === 'ACK' && m.clientId === 'w1');
  const w = await B.ws.next((m) => m.type === 'WAVED');
  assert.equal(w.encounterId, d.encounterId);
  assert.equal(w.groupName, 'Wave North');
  assert.ok(w.at > 0);
  assert.equal(h.got(A.ws, 'WAVED').length, 0, 'not echoed to the waving group');
  a2ws.sendJson({ type: 'WAVE', encounterId: d.encounterId, clientId: 'w2' });
  assert.equal((await a2ws.next((m) => m.type === 'ERROR' && m.clientId === 'w2')).code, 429, 'one per room per 5 minutes');
  B.ws.sendJson({ type: 'WAVE', encounterId: d.encounterId, clientId: 'w3' });
  await B.ws.next((m) => m.type === 'ACK' && m.clientId === 'w3');
  await A.ws.next((m) => m.type === 'WAVED');
  B.ws.sendJson({ type: 'WAVE', encounterId: 'ENC-000000000000', clientId: 'w4' });
  const e = await B.ws.next((m) => m.type === 'ERROR' && m.clientId === 'w4');
  assert.equal(e.code, 404);
  assert.equal(e.reason, 'ENCOUNTER_CLOSED');
  a2ws.close();
  for (const X of [A, B]) await h.endRide(X);
});

test('CONFIG: visibility / discovery / assistDefault by the lead only, echoed, in the snapshot; switching to Private ends encounters', async () => {
  const lng = lane();
  const A = await group(line(lng, 17.40, 17.70), 'Config Pack', { pub: false, disc: false });
  assert.equal(A.ws.snapshot.visibility, 'PRIVATE', 'default PRIVATE');
  assert.equal(A.ws.snapshot.discovery, false, 'default off');
  assert.equal(A.ws.snapshot.assistDefault, true);
  const m = await h.join(A, 'Member');
  const mws = await h.net1(m.token, A.gid);
  mws.sendJson({ type: 'CONFIG', visibility: 'PUBLIC' });
  assert.equal((await mws.next((x) => x.type === 'ERROR')).code, 403);
  A.ws.sendJson({ type: 'CONFIG', visibility: 'PUBLIC', discovery: 'yes', assistDefault: false });
  const c = await mws.next((x) => x.type === 'CONFIG');
  assert.equal(c.visibility, 'PUBLIC');
  assert.equal(c.discovery, false, 'wrong type ignored');
  assert.equal(c.assistDefault, false);
  A.ws.sendJson({ type: 'CONFIG', visibility: 'NOPE', discovery: true });
  const c2 = await mws.next((x) => x.type === 'CONFIG');
  assert.equal(c2.visibility, 'PUBLIC');
  assert.equal(c2.discovery, true);
  const snap = (await h.t.api('GET', `/convoys/${A.gid}`, null, m.token)).json;
  assert.equal(snap.visibility, 'PUBLIC');
  assert.equal(snap.discovery, true);
  assert.equal(snap.assistDefault, false);
  const B = await group(line(lng, 17.70, 17.40), 'Other Pack');
  h.place(A.gid, A.lead, 17.47, lng, 0, 60);
  h.place(B.gid, B.lead, 17.505, lng, 180, 60);
  tick();
  await B.ws.next((x) => x.type === 'DISCOVERY' && x.state === 'NEW');
  A.ws.sendJson({ type: 'CONFIG', visibility: 'PRIVATE' });
  const end = await B.ws.next((x) => x.type === 'DISCOVERY' && x.state === 'END');
  assert.ok(end.encounterId);
  mws.close();
  for (const X of [A, B]) await h.endRide(X);
});
