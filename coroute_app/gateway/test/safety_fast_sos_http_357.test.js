'use strict';
/**
 * Round 7 faster SOS: POST /api/convoys/:groupId/sos is a second lane for the same SOS. The phone sends the socket
 * frame and this request together; whichever arrives first raises the alert, the other is a duplicate.
 */
process.env.NODE_ENV = 'test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { netBoot, sleep } = require('./_net_helpers');

let h, ride, member, leadWs, memberWs;
before(async () => {
  h = await netBoot();
  ride = await h.rideOn(null, { name: 'Fast SOS' });
  member = await h.join(ride, 'Fast');
  leadWs = await h.net1(ride.lead.token, ride.gid);
  memberWs = await h.net1(member.token, ride.gid);
});
after(async () => { for (const ws of [leadWs, memberWs]) try { ws.close(); } catch { /* closed */ } await h.t.gw.shutdown(); });

const alertsOf = (ws, cid) => ws.frames.filter((m) => m.type === 'ALERT' && m.alert && m.alert.clientId === cid && !m.duplicate);

test('HTTP only: the group hears the SOS (one ALERT), measured from the request to the frame', async () => {
  const cid = 'fast-http-1';
  const t0 = Date.now();
  const r = await h.t.api('POST', `/convoys/${ride.gid}/sos`, { clientId: cid, lat: 17.4, lng: 78.5, alertType: 'EMERGENCY', source: 'MANUAL' }, member.token);
  assert.equal(r.status, 201, JSON.stringify(r.json));
  assert.equal(r.json.duplicate, false); assert.equal(r.json.clientId, cid);
  await sleep(40);
  assert.equal(alertsOf(leadWs, cid).length, 1);
  assert.equal(alertsOf(leadWs, cid)[0].alert.lat, 17.4);
  assert.ok(Date.now() - t0 < 2000);
  const again = await h.t.api('POST', `/convoys/${ride.gid}/sos`, { clientId: cid, lat: 17.4, lng: 78.5 }, member.token);
  assert.equal(again.status, 200); assert.equal(again.json.duplicate, true); assert.equal(again.json.alertId, r.json.alertId);
  await sleep(30);
  assert.equal(alertsOf(leadWs, cid).length, 1, 'a repeat is not a second alert');
});

test('socket and HTTP together (either order): exactly one alert for the clientId', async () => {
  for (const [cid, httpFirst] of [['fast-both-1', true], ['fast-both-2', false]]) {
    const body = { clientId: cid, lat: 17.41, lng: 78.51, alertType: 'CRASH', auto: true };
    const frame = () => leadWs.sendJson({ type: 'SOS', ...body });
    const post = () => h.t.api('POST', `/convoys/${ride.gid}/sos`, body, ride.lead.token);
    let p;
    if (httpFirst) { p = post(); frame(); } else { frame(); p = post(); }
    const r = await p;
    assert.ok(r.status === 200 || r.status === 201, JSON.stringify(r.json));
    await sleep(60);
    assert.equal(alertsOf(memberWs, cid).length, 1, cid);
    const room = h.t.gw.convoys.rooms.get(ride.gid);
    assert.equal([...room.alerts.values()].filter((a) => a.clientId === cid).length, 1);
  }
});

test('authz and validation: sign-in, membership and a clientId are required', async () => {
  assert.equal((await h.t.api('POST', `/convoys/${ride.gid}/sos`, { clientId: 'x', lat: 1, lng: 1 })).status, 401);
  const outsider = await h.rider('Outsider');
  const no = await h.t.api('POST', `/convoys/${ride.gid}/sos`, { clientId: 'out-1', lat: 1, lng: 1 }, outsider.token);
  assert.equal(no.status, 403);
  assert.equal((await h.t.api('POST', `/convoys/${ride.gid}/sos`, { lat: 1, lng: 1 }, member.token)).status, 400);
  assert.equal((await h.t.api('POST', `/convoys/${ride.gid}/sos`, { clientId: 'c'.repeat(65), lat: 1, lng: 1 }, member.token)).status, 400);
});
