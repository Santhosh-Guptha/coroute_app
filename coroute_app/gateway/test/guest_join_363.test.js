'use strict';
/**
 * v3.63 browser guests (src/guest_service.js, public/ride/): join a ride from the browser with a first name, wait
 * for the host's "Let in", appear on the map, get SOS alerts, raise SOS through the same path. A guest token opens
 * nothing else (no REST, no socket), is revoked when the host removes the guest or the ride ends, and the guest view
 * carries no phone numbers, emergency contacts or medical details.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const config = require('../src/config');
const { boot } = require('./_helpers');
const { verifyTokenDetailed } = require('../src/auth');

let t;
let ipSeq = 0;
const ip = () => ({ 'X-Forwarded-For': `10.63.${Math.floor(++ipSeq / 250)}.${ipSeq % 250}` });
before(async () => { config.rideJoinApproval = true; t = await boot(); });
after(async () => { config.rideJoinApproval = false; await t.gw.shutdown(); });

const dev = (n) => `devicekey${String(n).padStart(12, '0')}xyz`;
async function hostRide(tag) {
  const host = await t.register(`Host ${tag}`, `host.${tag}@coroute.test`);
  const c = await t.api('POST', '/convoys', { name: `Ride ${tag}`, rider: { lat: 12.97, lng: 77.59 } }, host.token);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  return { host, groupId: c.json.groupId, code: c.json.joinCode };
}

test('guest asks, host lets in, guest sees the group (no phones), shares position, gets and raises SOS', async () => {
  const { host, groupId, code } = await hostRide('g1');
  const hostWs = await t.joinRoom(host.token, groupId);
  const s = await t.api('POST', '/guest/start', { code: code.toLowerCase(), name: 'Asha Rao', deviceId: dev(1) }, null, ip());
  assert.equal(s.status, 202, JSON.stringify(s.json));
  assert.equal(s.json.status, 'PENDING');
  assert.equal(s.json.name, 'Asha');
  assert.ok(s.json.token && s.json.guestId.startsWith('gst_'));
  const req = await hostWs.next((m) => m.type === 'JOIN_REQUEST');
  assert.equal(req.userId, s.json.guestId);
  assert.equal(req.name, 'Asha');
  const g = s.json.token;

  // A guest token opens nothing else.
  assert.equal(verifyTokenDetailed(g), null);
  assert.equal((await t.api('GET', '/me', null, g)).status, 401);
  assert.equal((await t.api('GET', `/convoys/${groupId}`, null, g)).status, 401);
  assert.equal((await t.api('GET', '/guest/state', null, 'not-a-token')).status, 401);

  // The same browser asking again keeps one request (same guest).
  const again = await t.api('POST', '/guest/start', { code, name: 'Asha', deviceId: dev(1) }, null, ip());
  assert.equal(again.json.guestId, s.json.guestId);
  assert.equal((await t.api('GET', '/guest/state', null, g)).json.status, 'PENDING');

  const ok = await t.api('POST', `/convoys/${groupId}/join-requests/${s.json.guestId}`, { approve: true }, host.token);
  assert.equal(ok.status, 200, JSON.stringify(ok.json));
  const st = await t.api('GET', '/guest/state', null, g);
  assert.equal(st.json.status, 'IN', JSON.stringify(st.json));
  assert.ok(st.json.token, 'fresh token while riding');
  const hostRow = st.json.riders.find((r) => r.userId === host.user.userId);
  assert.ok(hostRow && hostRow.name === 'Host');
  assert.ok(!JSON.stringify(st.json).includes('+91'), 'no phone numbers or emergency contacts in the guest view');
  assert.ok(st.json.riders.find((r) => r.me && r.isGuest));

  // The app side sees a Browser rider.
  const snap = await t.api('GET', `/convoys/${groupId}`, null, host.token);
  const gr = snap.json.riders[s.json.guestId];
  assert.ok(gr && gr.isGuest === true && gr.vehicleType === 'Browser');

  // Position in -> the host's socket hears it.
  assert.equal((await t.api('POST', '/guest/position', { lat: 12.99, lng: 77.6, speedKmh: 30 }, g)).status, 200);
  const upd = await hostWs.next((m) => m.type === 'RIDER_UPDATE' && m.rider && m.rider.userId === s.json.guestId && m.rider.lat > 12.98);
  assert.equal(upd.rider.isGuest, true);
  assert.equal((await t.api('POST', '/guest/position', { lat: 0, lng: 0 }, g)).status, 400);

  // Host SOS -> in the guest view without medical details.
  const hsos = await t.api('POST', `/convoys/${groupId}/sos`, { clientId: 'host-sos-1', lat: 12.97, lng: 77.59 }, host.token);
  assert.equal(hsos.status, 201, JSON.stringify(hsos.json));
  const st2 = await t.api('GET', '/guest/state', null, g);
  const a = st2.json.alerts.find((x) => x.alertId === hsos.json.alertId);
  assert.ok(a && a.name === 'Host' && a.mine === false);
  assert.equal(a.medical, undefined);
  assert.equal((await t.api('POST', `/guest/sos/${hsos.json.alertId}/cancel`, {}, g)).status, 403, 'only your own SOS');

  // Guest SOS -> the same path: the host's socket gets the ALERT; a resend is the same SOS.
  const gs = await t.api('POST', '/guest/sos', { clientId: 'guest-sos-0001', lat: 12.99, lng: 77.6 }, g);
  assert.equal(gs.status, 201, JSON.stringify(gs.json));
  const al = await hostWs.next((m) => m.type === 'ALERT' && m.alert && m.alert.userId === s.json.guestId);
  assert.equal(al.alert.userName, 'Asha');
  const dup = await t.api('POST', '/guest/sos', { clientId: 'guest-sos-0001', lat: 12.99, lng: 77.6 }, g);
  assert.equal(dup.json.duplicate, true);
  assert.equal(dup.json.alertId, gs.json.alertId);
  assert.equal((await t.api('POST', `/guest/sos/${gs.json.alertId}/cancel`, {}, g)).status, 200);

  // Host removes the guest -> REMOVED, then the token is dead.
  assert.equal((await t.api('DELETE', `/convoys/${groupId}/riders/${s.json.guestId}`, null, host.token)).status, 200);
  assert.equal((await t.api('GET', '/guest/state', null, g)).json.status, 'REMOVED');
  assert.equal((await t.api('GET', '/guest/state', null, g)).status, 401);
  hostWs.close();
});

test('declined guest, ride end revokes guests, input checks and the start limit', async () => {
  const { host, groupId, code } = await hostRide('g2');
  const a = await t.api('POST', '/guest/start', { code, name: 'Ravi', deviceId: dev(2) }, null, ip());
  const no = await t.api('POST', `/convoys/${groupId}/join-requests/${a.json.guestId}`, { approve: false }, host.token);
  assert.equal(no.status, 200);
  assert.equal((await t.api('GET', '/guest/state', null, a.json.token)).json.status, 'DECLINED');
  assert.equal((await t.api('GET', '/guest/state', null, a.json.token)).status, 401);

  const b = await t.api('POST', '/guest/start', { code, name: 'Meera', deviceId: dev(3) }, null, ip());
  await t.api('POST', `/convoys/${groupId}/join-requests/${b.json.guestId}`, { approve: true }, host.token);
  assert.equal((await t.api('GET', '/guest/state', null, b.json.token)).json.status, 'IN');
  assert.equal((await t.api('POST', `/convoys/${groupId}/status`, { status: 'ENDED' }, host.token)).status, 200);
  await new Promise((r) => setTimeout(r, 50));
  const ended = await t.api('GET', '/guest/state', null, b.json.token);
  assert.ok(ended.status === 401 || ended.json.status === 'ENDED', JSON.stringify(ended.json));

  assert.equal((await t.api('POST', '/guest/start', { code: 'ZZ', name: 'X', deviceId: dev(4) }, null, ip())).status, 400);
  assert.equal((await t.api('POST', '/guest/start', { code, name: '<script>', deviceId: dev(4) }, null, ip())).status, 400);
  assert.equal((await t.api('POST', '/guest/start', { code, name: 'Ok', deviceId: 'short' }, null, ip())).status, 400);
  const none = await t.api('POST', '/guest/start', { code: 'QQQQ22', name: 'Kiran', deviceId: dev(5) }, null, ip());
  assert.equal(none.json.status, 'NO_RIDE');
  assert.equal(none.json.token, undefined);

  const same = { 'X-Forwarded-For': '10.99.99.99' };
  let last;
  for (let i = 0; i < 11; i++) last = await t.api('POST', '/guest/start', { code: 'QQQQ22', name: 'Spam', deviceId: dev(100 + i) }, null, same);
  assert.equal(last.status, 429, 'at most 10 guest starts per address in 15 min');
});

test('guest page: /ride/<code> is served with a strict CSP; the join page offers it', async () => {
  const r = await fetch(`${t.origin}/ride/ABC234`);
  assert.equal(r.status, 200);
  const csp = r.headers.get('content-security-policy');
  assert.match(csp, /script-src 'self'/);
  assert.ok(!/unsafe-inline/.test(csp), 'no inline scripts or styles');
  assert.match(r.headers.get('x-robots-tag'), /noindex/);
  const html = await r.text();
  assert.ok(!/<script>/.test(html) && !/ style="/.test(html), 'no inline script or style');
  assert.equal((await fetch(`${t.origin}/ride/bad!`)).status, 404);
  const join = await (await fetch(`${t.origin}/join/ABC234`)).text();
  assert.match(join, /href="\/ride\/ABC234"/);
  const js = require('fs').readFileSync(require('path').join(__dirname, '..', 'public', 'ride', 'ride.js'), 'utf8');
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(/.test(js), 'text only');
});
