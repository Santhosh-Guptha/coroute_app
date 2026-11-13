'use strict';
/**
 * Round 10 rescue beacon and the nearby-rider network: the rescue id reaches an ACCEPTED outside
 * responder (never the plain request), and that responder may "ping the phone" by incidentId.
 */
const { netBoot, line, E_LAT, sleep } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

let h;
before(async () => { h = await netBoot(); });
after(async () => { await h.t.gw.shutdown(); });

test('ASSIST: rescueId only after ACCEPT; the accepted responder can ping the victim by incidentId', async () => {
  const lng = 52.5;
  const subject = await h.rider('Victim Rescue');
  const V = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Rescue Victims', lead: subject });
  V.ws = await h.net1(V.lead.token, V.gid);
  h.place(V.gid, V.lead, E_LAT, lng, 0, 0);
  const X = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Rescue Helpers' });
  X.ws = await h.net1(X.lead.token, X.gid);
  h.place(X.gid, X.lead, 17.475, lng, 0, 60);
  const a = await h.sos(V.ws, E_LAT, lng);
  const req = await X.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.equal(req.rescueId, undefined, 'no rescue id before the rider accepts');
  // Before accepting, a ping is refused.
  X.ws.sendJson({ type: 'RESCUE_PING', incidentId: req.incidentId });
  assert.equal((await X.ws.next((m) => m.type === 'ERROR')).reason, 'NOT_RESPONDER');
  X.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'rb-acc' });
  const upd = await X.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');
  const stored = h.t.gw.convoys.rooms.get(V.gid).alerts.get(a.alertId);
  assert.match(upd.rescueId, /^[0-9a-f]{4}$/);
  assert.equal(upd.rescueId, stored.rescueId);
  X.ws.sendJson({ type: 'RESCUE_PING', incidentId: req.incidentId });
  const heard = await V.ws.next((m) => m.type === 'RESCUE_PING');
  assert.equal(heard.alertId, a.alertId);
  assert.equal((await X.ws.next((m) => m.type === 'RESCUE_PING_RESULT')).sent, true);
  await sleep(30);
  V.ws.sendJson({ type: 'SOS_RESOLVE', alertId: a.alertId });
  await X.ws.next((m) => m.type === 'ASSIST_CLOSED');
});
