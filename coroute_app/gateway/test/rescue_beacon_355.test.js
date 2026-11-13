'use strict';
/**
 * Round 10 rescue beacon (src/rescue_beacon.js): the rescue id on SOS alerts (same value as the app's
 * lib/domain/rescue/rescue_id.dart), and RESCUE_PING ("Ping the phone"): only the victim hears it,
 * only group members / active nearby responders may send it, low rate.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { rescueIdFromKey, rescueIdFor, RescuePings, PING_GAP_SENDER_MS } = require('../src/rescue_beacon');
const { publicAlert } = require('../src/convoys');

let t, gw;
before(async () => { t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); });

const uid = (u) => u.user.userId;
let n = 0, phone = 0;
const register = async (name, email) => {
  phone++;
  return JSON.parse(JSON.stringify(await gw.auth.register({
    name, email, password: 'Password#123', phone: `+9198767${String(10000 + phone).slice(-5)}`,
    vehicleType: 'Motorcycle', vehicleNo: `TS11AB${String(1000 + phone).slice(-4)}`,
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  })));
};
async function ride(riders) {
  n++;
  const lead = await register(`Lead Rescue${n}`, `rblead${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Rescue ${n}` }, lead.token)).json;
  const members = [];
  for (let i = 0; i < riders - 1; i++) {
    n++;
    const u = await register(`Ravi Rider${n}`, `rbrider${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  return { lead, c, gid: c.groupId, room: gw.convoys.rooms.get(c.groupId), members };
}

test('rescue id: the same FNV-1a fold as the app (shared vectors), 0 never used', () => {
  // Same vectors as test/rescue_beacon_dsp_test.dart and lib/domain/rescue/rescue_id.dart.
  assert.equal(rescueIdFromKey('client-123'), 'c78e');
  assert.equal(rescueIdFromKey('SOS-abc'), 'ed55');
  assert.equal(rescueIdFromKey('a'), 'cd20');
  assert.equal(rescueIdFromKey('u1-1731400000000'), '5f94');
  assert.equal(rescueIdFromKey('मोटरसाइकिल'), '327d', 'UTF-8 bytes, not UTF-16 units');
  assert.equal(rescueIdFromKey(''), '');
  assert.equal(rescueIdFromKey(null), '');
});

test('rescueIdFor: a well-formed phone value first, then clientId, then alertId', () => {
  assert.equal(rescueIdFor({ msgRescueId: '0A3F', clientId: 'client-123', alertId: 'x' }), '0a3f');
  assert.equal(rescueIdFor({ msgRescueId: '0000', clientId: 'client-123' }), 'c78e');
  assert.equal(rescueIdFor({ msgRescueId: 'zzzz', clientId: 'client-123' }), 'c78e');
  assert.equal(rescueIdFor({ msgRescueId: 12, clientId: '', alertId: 'SOS-abc' }), 'ed55');
});

test('publicAlert carries rescueId; older stored alerts get it derived', () => {
  const a = publicAlert({ alertId: 'SOS-abc', userId: 'u', clientId: 'client-123', timestamp: 1, responders: {} });
  assert.equal(a.rescueId, 'c78e');
  const b = publicAlert({ alertId: 'SOS-abc', userId: 'u', timestamp: 1, responders: {} });
  assert.equal(b.rescueId, 'ed55');
  const c = publicAlert({ alertId: 'SOS-abc', userId: 'u', rescueId: '1234', timestamp: 1, responders: {} });
  assert.equal(c.rescueId, '1234');
});

test('SOS over the socket: the group gets the alert with rescueId derived from the clientId', async () => {
  const R = await ride(3);
  const [ravi, other] = R.members;
  const wr = await t.joinRoom(ravi.token, R.gid);
  const wo = await t.joinRoom(other.token, R.gid);
  wr.sendJson({ type: 'SOS', lat: 12.97, lng: 77.59, clientId: 'client-123', alertType: 'CRASH', auto: true, source: 'CRASH_AUTO' });
  const got = await wo.next((m) => m.type === 'ALERT' && m.alert && m.alert.userId === uid(ravi));
  assert.equal(got.alert.rescueId, 'c78e');
  const stored = [...R.room.alerts.values()].find((a) => a.userId === uid(ravi));
  assert.equal(stored.rescueId, 'c78e');
  wr.close(); wo.close();
});

test('RESCUE_PING: only the victim hears it; result to the sender; throttled per sender; own / closed refused', async () => {
  const R = await ride(4);
  const [ravi, b, c] = R.members;
  const wl = await t.joinRoom(R.lead.token, R.gid);
  const wr = await t.joinRoom(ravi.token, R.gid);
  const wb = await t.joinRoom(b.token, R.gid);
  const wc = await t.joinRoom(c.token, R.gid);
  wr.sendJson({ type: 'SOS', lat: 12.97, lng: 77.59, clientId: 'ping-sos-1' });
  const alert = (await wb.next((m) => m.type === 'ALERT' && m.alert && m.alert.userId === uid(ravi))).alert;
  // A fake clock for this hub's limiter (the hub makes it on the first ping otherwise).
  let now = 1_000_000;
  gw.hub.rescuePings = new RescuePings(gw.convoys, { network: gw.network, now: () => now });

  wb.sendJson({ type: 'RESCUE_PING', alertId: alert.alertId });
  const heard = await wr.next((m) => m.type === 'RESCUE_PING');
  assert.equal(heard.alertId, alert.alertId);
  assert.equal(heard.fromName, b.user.name.split(' ')[0]);
  const res = await wb.next((m) => m.type === 'RESCUE_PING_RESULT');
  assert.equal(res.sent, true);
  await sleep(80);
  for (const w of [wl, wb, wc]) assert.ok(!w.inbox.some((m) => m.type === 'RESCUE_PING'), 'nobody else hears it');

  // Same sender again within 20 s: throttled. Another sender within 5 s of the last ping: throttled.
  now += 3000;
  wb.sendJson({ type: 'RESCUE_PING', alertId: alert.alertId });
  const again = await wb.next((m) => m.type === 'RESCUE_PING_RESULT');
  assert.equal(again.sent, false);
  assert.equal(again.throttled, true);
  wc.sendJson({ type: 'RESCUE_PING', alertId: alert.alertId });
  assert.equal((await wc.next((m) => m.type === 'RESCUE_PING_RESULT')).throttled, true);
  now += 3000;
  wc.sendJson({ type: 'RESCUE_PING', alertId: alert.alertId });
  assert.equal((await wc.next((m) => m.type === 'RESCUE_PING_RESULT')).sent, true);
  await wr.next((m) => m.type === 'RESCUE_PING');
  now += PING_GAP_SENDER_MS;
  wb.sendJson({ type: 'RESCUE_PING', alertId: alert.alertId });
  assert.equal((await wb.next((m) => m.type === 'RESCUE_PING_RESULT')).sent, true);

  // The victim cannot ping their own phone; a missing target is a bad request.
  wr.sendJson({ type: 'RESCUE_PING', alertId: alert.alertId });
  assert.equal((await wr.next((m) => m.type === 'ERROR')).reason, 'OWN_ALERT');
  wb.sendJson({ type: 'RESCUE_PING' });
  assert.equal((await wb.next((m) => m.type === 'ERROR')).reason, 'BAD_PING');

  // Closed alert: refused.
  await gw.convoys.resolveSos(R.gid, { userId: uid(ravi), name: ravi.user.name }, alert.alertId, 'RESOLVED');
  now += 60000;
  wl.sendJson({ type: 'RESCUE_PING', alertId: alert.alertId });
  assert.equal((await wl.next((m) => m.type === 'ERROR')).reason, 'ALERT_CLOSED');
  for (const w of [wl, wr, wb, wc]) w.close();
});

test('RESCUE_PING from another group: the alert is not in the sender\'s room', async () => {
  const A = await ride(2);
  const B = await ride(2);
  const victim = A.members[0];
  const wv = await t.joinRoom(victim.token, A.gid);
  const stranger = await t.joinRoom(B.members[0].token, B.gid);
  wv.sendJson({ type: 'SOS', lat: 12.9, lng: 77.5, clientId: 'cross-1' });
  await sleep(100);
  const alertId = [...A.room.alerts.values()][0].alertId;
  stranger.sendJson({ type: 'RESCUE_PING', alertId });
  assert.equal((await stranger.next((m) => m.type === 'ERROR')).reason, 'ALERT_CLOSED');
  await sleep(50);
  assert.ok(!wv.inbox.some((m) => m.type === 'RESCUE_PING'));
  wv.close(); stranger.close();
});

test('RescuePings: nearby responder path needs an ACTIVE responder; per-alert cap of 6 a minute', async () => {
  const sent = [];
  const room = { riders: new Map([['v', {}], ['m', {}]]), alerts: new Map([['A1', { alertId: 'A1', userId: 'v', resolved: false }]]) };
  const convoys = {
    rooms: new Map([['g1', room]]),
    getRoom: async () => room,
    emit: (ev, gid, to, payload) => sent.push({ ev, gid, to, payload }),
  };
  const network = { incidents: new Map([['NET-1', { primary: { gid: 'g1', uid: 'v', alertId: 'A1' }, responders: new Map([['h1', { status: 'EN_ROUTE' }], ['h2', { status: 'DECLINED' }]]) }]]) };
  let now = 0;
  const p = new RescuePings(convoys, { network, now: () => now });
  const r1 = await p.ping('their-room', { userId: 'h1', name: 'Helper One' }, { incidentId: 'NET-1' });
  assert.equal(r1.sent, true);
  assert.deepEqual(sent[0], { ev: 'userMessage', gid: 'g1', to: 'v', payload: { type: 'RESCUE_PING', alertId: 'A1', fromName: 'Helper', at: 0 } });
  await assert.rejects(p.ping('x', { userId: 'h2', name: 'H2' }, { incidentId: 'NET-1' }), (e) => e.reason === 'NOT_RESPONDER');
  await assert.rejects(p.ping('x', { userId: 'h3', name: 'H3' }, { incidentId: 'NET-404' }), (e) => e.reason === 'NOT_RESPONDER');
  // Many members, one alert: at most 6 a minute and one every 5 s.
  for (let i = 0; i < 12; i++) room.riders.set(`m${i}`, {});
  let ok = 0;
  for (let i = 0; i < 12; i++) {
    now += 5000;
    if ((await p.ping('g1', { userId: `m${i}`, name: `M${i}` }, { alertId: 'A1' })).sent) ok++;
  }
  assert.ok(ok <= 6, `sent ${ok}`);
  assert.ok(ok >= 5, `sent ${ok}`);
});
