'use strict';
/**
 * 3.55 "Help from public riders" (switch publicRiderHelp): an SOS also asks riders of a PUBLIC ride
 * close by (src/safety_network.js _publicCandidate), with the same consent, caps and privacy as the
 * rest of the safety network, never across a public-ride block. Emergency at (17.500, lane).
 */
const { netBoot, line, E_LAT } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
let laneNo = 0;
const lane = () => 80 + (laneNo++) * 0.5;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

async function victim(lng) {
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victim' });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  return V;
}

/** A ride without a route, its lead parked ~750 m east of the emergency (no route / heading match). */
async function parked(lng, { pub }) {
  const B = await h.rideOn(null, { name: pub ? 'Public' : 'Private' });
  const ws = await h.t.connect(B.lead.token);
  await ws.next((m) => m.type === 'HELLO');
  ws.sendJson({ type: 'JOIN', groupId: B.gid, caps: ['net1', 'pubride1'] });
  await ws.next((m) => m.type === 'SNAPSHOT');
  ws.frames = [];
  ws.on('message', (d, bin) => { if (!bin) ws.frames.push(JSON.parse(d.toString())); });
  B.ws = ws;
  if (pub) {
    ws.sendJson({ type: 'CONFIG', publicRide: { on: true, radiusKm: 10 } });
    await ws.next((m) => m.type === 'CONFIG');
  }
  h.place(B.gid, B.lead, E_LAT, lng + 0.007, 0, 0);
  return B;
}

const uid = (u) => u.user.userId;
const requests = (ws) => h.got(ws, 'ASSIST_REQUEST');

test('a parked rider of a public ride nearby is asked; the same rider in a private ride is not', async () => {
  const lng = lane();
  const V = await victim(lng);
  const P = await parked(lng, { pub: true });
  await h.sos(V.ws, E_LAT, lng);
  const req = await P.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(req.publicRide, true);
  assert.equal(req.aheadOnRoute, false);
  assert.equal(req.distanceM, 700);
  // Privacy: the request carries no name, id, phone or medical info of the subject.
  assert.deepEqual(Object.keys(req).filter((k) => /name|user|phone|medical|groupid|subject/i.test(k)), []);
  await h.endRide(V); await h.endRide(P);

  const lng2 = lane();
  const V2 = await victim(lng2);
  const Q = await parked(lng2, { pub: false });
  await h.sos(V2.ws, E_LAT, lng2);
  await h.settle(80);
  h.net.tick(Date.now() + 1000);
  await h.settle(80);
  assert.equal(requests(Q.ws).length, 0, 'private ride rider off the route: existing rules unchanged');
  await h.endRide(V2); await h.endRide(Q);
});

test('without consent nobody is asked: helper switched help off, or the subject switched asking off', async () => {
  const lng = lane();
  const V = await victim(lng);
  const P = await parked(lng, { pub: true });
  h.t.gw.convoys.rooms.get(P.gid).riders.get(uid(P.lead)).assistHelp = false;
  await h.sos(V.ws, E_LAT, lng);
  await h.settle(80);
  assert.equal(requests(P.ws).length, 0);
  await h.endRide(V); await h.endRide(P);

  const lng2 = lane();
  const V2 = await victim(lng2);
  h.t.gw.convoys.rooms.get(V2.gid).meta.assistDefault = false; // the subject's group does not ask outside riders
  const P2 = await parked(lng2, { pub: true });
  await h.sos(V2.ws, E_LAT, lng2);
  await h.settle(80);
  assert.equal(requests(P2.ws).length, 0);
  await h.endRide(V2); await h.endRide(P2);
});

test('a public-ride block either way, a suspension or the admin switch keeps the rider out', async () => {
  const pr = h.t.gw.publicRides;
  // Blocked by the subject.
  let lng = lane();
  let V = await victim(lng);
  let P = await parked(lng, { pub: true });
  pr.block(uid(V.lead), uid(P.lead));
  await h.sos(V.ws, E_LAT, lng);
  await h.settle(80);
  assert.equal(requests(P.ws).length, 0, 'blocked');
  await h.endRide(V); await h.endRide(P);
  // Suspended from public ride.
  lng = lane();
  V = await victim(lng);
  P = await parked(lng, { pub: true });
  pr.suspend(uid(P.lead), Date.now() + 3600000);
  await h.sos(V.ws, E_LAT, lng);
  await h.settle(80);
  assert.equal(requests(P.ws).length, 0, 'suspended');
  pr.suspend(uid(P.lead), 0);
  await h.endRide(V); await h.endRide(P);
  // Admin switch off.
  lng = lane();
  V = await victim(lng);
  P = await parked(lng, { pub: true });
  const ff = h.t.gw.featureFlags;
  const was = ff.flags.publicRiderHelp;
  ff.flags.publicRiderHelp = false;
  try {
    await h.sos(V.ws, E_LAT, lng);
    await h.settle(80);
    assert.equal(requests(P.ws).length, 0, 'switch off');
  } finally { ff.flags.publicRiderHelp = was; }
  await h.endRide(V); await h.endRide(P);
});
