'use strict';
/**
 * Functional audit fixes:
 *  - sliding session on every authenticated call (a multi-day ride never ends by token age);
 *  - guest accounts carry no placeholder phone / emergency numbers, and old guests' placeholders
 *    are never put in a ride's roster or texted; guests may still ride;
 *  - live emergency links: the JSON refresh finds links made by the emergency SMS gateway (no medical
 *    data), and a convoy link still works after a gateway restart (room not loaded yet).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.NET_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'auditadmin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const config = require('../src/config');
const { boot } = require('./_helpers');
const { realContactNumber } = require('../src/auth');

test('audit fixes: session, guests, live links', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const { api, gw } = env;

  await t.test('a day-old token gets a fresh one from any authenticated call, not only /me', async () => {
    const reg = await env.register('Long Rider', 'long@coroute.test');
    const stored = await gw.repo.findUserById(reg.user.userId);
    await gw.repo.updateUser(stored.key, { createdAt: Date.now() - 3 * 86400000 });
    gw.gate.invalidate(reg.user.userId);
    const old = jwt.sign({ sub: reg.user.userId, name: 'Long Rider', role: 'RIDER', email: 'long@coroute.test', iat: Math.floor(Date.now() / 1000) - 2 * 86400 },
      config.jwtSecret, { expiresIn: '28d', issuer: 'coroute-gateway' });
    const trips = await api('GET', '/trips?summary=1', undefined, old);
    assert.equal(trips.status, 200);
    const next = trips.headers.get('x-coroute-token');
    assert.ok(next, 'refresh header on an ordinary call');
    const claims = jwt.verify(next, config.jwtSecret);
    assert.equal(claims.sub, reg.user.userId);
    // A fresh token gets none.
    const fresh = await api('GET', '/trips?summary=1', undefined, reg.token);
    assert.equal(fresh.headers.get('x-coroute-token'), null);
    // /me sets it only once.
    const me = await api('GET', '/me', undefined, old);
    assert.ok(me.headers.get('x-coroute-token'));
    assert.ok(!me.headers.get('x-coroute-token').includes(','));
  });

  await t.test('guests: no placeholder numbers, still allowed to ride, never texted', async () => {
    const g = await api('POST', '/auth/guest', { name: 'Quick Guest' });
    assert.equal(g.status, 200, JSON.stringify(g.json));
    assert.equal(g.json.user.phone, '');
    assert.equal(g.json.user.emergencyContact, '');
    assert.equal(g.json.user.isGuest, true);
    const odd = await api('POST', '/auth/guest', { name: 12345, vehicleNo: { x: 1 } });
    assert.equal(odd.status, 200, 'a non-string name falls back instead of failing');
    assert.match(odd.json.user.name, /^Guest_\d{4}$/);
    assert.equal(odd.json.user.vehicleNo, 'GUEST');
    const c = await api('POST', '/convoys', { name: 'Guest Ride' }, g.json.token);
    assert.ok(c.json.groupId, JSON.stringify(c.json));

    // An older guest account stored with the placeholders.
    const lead = await env.register('Roster Lead', 'rosterlead@coroute.test');
    const ride = await api('POST', '/convoys', { name: 'Roster Ride' }, lead.token);
    const legacy = await api('POST', '/auth/guest', { name: 'Old Guest' });
    const doc = await gw.repo.findUserById(legacy.json.user.userId);
    await gw.repo.updateUser(doc.key, { phone: '9999999999', emergencyContact: '112112112', emergencyContactName: 'Emergency Services' });
    gw.gate.invalidate(legacy.json.user.userId);
    assert.equal(realContactNumber({ ...doc, phone: '9999999999' }, 'phone'), '');
    assert.equal(realContactNumber({ provider: 'password', email: 'a@b.c', phone: '9999999999' }, 'phone'), '9999999999');
    assert.equal((await api('POST', '/convoys/join', { code: ride.json.joinCode }, legacy.json.token)).status, 200);
    const room = gw.convoys.rooms.get(ride.json.groupId);
    const r = room.riders.get(legacy.json.user.userId);
    assert.equal(r.phone, '');
    assert.equal(r.emergencyContact, '');
    const roster = await api('GET', `/convoys/${ride.json.groupId}/emergency-roster`, undefined, lead.token);
    if (roster.status === 200) {
      assert.ok(!JSON.stringify(roster.json).includes('9999999999'), 'a placeholder is never in the SMS roster');
    }
    const own = await api('GET', `/convoys/${ride.json.groupId}/emergency-roster`, undefined, legacy.json.token);
    if (own.status === 200) assert.equal(own.json.emergencyContact ?? null, null);
  });

  await t.test('an ended ride is final: a retried end keeps its end time, resume is refused', async () => {
    const lead = await env.register('Final Lead', 'finallead@coroute.test');
    const c = (await api('POST', '/convoys', { name: 'Final Ride' }, lead.token)).json;
    assert.equal((await api('POST', `/convoys/${c.groupId}/status`, { status: 'ENDED' }, lead.token)).status, 200);
    const endedAt = (await gw.repo.getConvoyMeta(c.groupId)).endedAtEpochMs;
    await new Promise((r) => setTimeout(r, 20));
    const again = await api('POST', `/convoys/${c.groupId}/status`, { status: 'ENDED' }, lead.token);
    assert.equal(again.status, 200);
    assert.equal(again.json.tripStatus, 'ENDED');
    assert.equal((await gw.repo.getConvoyMeta(c.groupId)).endedAtEpochMs, endedAt);
    const resume = await api('POST', `/convoys/${c.groupId}/status`, { status: 'STARTED' }, lead.token);
    assert.equal(resume.status, 409);
    assert.equal(resume.json.code, 'RIDE_ENDED');
    const meta = await gw.repo.getConvoyMeta(c.groupId);
    assert.equal(meta.tripStatus, 'ENDED');
    assert.ok(!gw.convoys.rooms.has(c.groupId), 'an ended room is not kept in memory');
  });

  await t.test('a stale single-active-trip lock never keeps a rider off every ride', async () => {
    const admin = await env.register('Audit Admin', 'auditadmin@coroute.test');
    const lead = await env.register('Lock Lead', 'locklead@coroute.test');
    const rider = await env.register('Lock Rider', 'lockrider@coroute.test');
    const uid = rider.user.userId;
    const a = (await api('POST', '/convoys', { name: 'Dissolved Ride' }, lead.token)).json;
    assert.equal((await api('POST', '/convoys/join', { code: a.joinCode }, rider.token)).status, 200);
    assert.equal((await gw.repo.getActiveTrip(uid)).groupId, a.groupId);
    // An admin dissolves the ride: its riders' locks go with it.
    assert.equal((await api('DELETE', `/admin/convoys/${a.groupId}`, undefined, admin.token)).status, 200);
    assert.equal(await gw.repo.getActiveTrip(uid), null);

    const b = (await api('POST', '/convoys', { name: 'Next Ride' }, lead.token)).json;
    const c = (await api('POST', '/convoys', { name: 'Other Ride' }, admin.token)).json;
    const was = config.paymentsEnabled;
    config.paymentsEnabled = true;
    try {
      // A lock left behind for a convoy that no longer exists is released, not obeyed.
      await gw.repo.setActiveTrip(uid, { groupId: 'GRP-GONE', role: 'PARTICIPANT', status: 'STARTED' });
      const joined = await api('POST', '/convoys/join', { code: b.joinCode }, rider.token);
      assert.equal(joined.status, 200, JSON.stringify(joined.json));
      assert.equal((await gw.repo.getActiveTrip(uid)).groupId, b.groupId);
      // A real lock (the ride is on) still holds.
      const other = await api('POST', '/convoys/join', { code: c.joinCode }, rider.token);
      assert.equal(other.status, 409);
      assert.equal(other.json.code, 'ACTIVE_TRIP_CONFLICT');
    } finally {
      config.paymentsEnabled = was;
    }
  });

  await t.test('live links: SMS-gateway links refresh, without medical data', async () => {
    const url = gw.emergencyGateway.generateTrackingUrl({ tripId: 'standalone-x', riderId: 'r1', riderName: 'Meera Nair', lat: 12.97, lng: 77.59, bloodGroup: 'O+' });
    const token = url.split('/e/')[1];
    const res = await fetch(`${env.origin}/api/public/live/${token}`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.firstName, 'Meera');
    assert.equal(body.lat, 12.97);
    assert.ok(!('bloodGroup' in body));
    assert.ok(!JSON.stringify(body).includes('O+'));
    const page = await fetch(`${env.origin}/e/${token}`);
    assert.equal(page.status, 200);
  });

  await t.test('live links: a convoy link still works after a gateway restart', async () => {
    const lead = await env.register('Restart Lead', 'restartlead@coroute.test');
    const owner = await env.register('Asha Restart', 'restartowner@coroute.test');
    const c = (await api('POST', '/convoys', { name: 'Restart Ride' }, lead.token)).json;
    assert.equal((await api('POST', '/convoys/join', { code: c.joinCode }, owner.token)).status, 200);
    const wl = await env.joinRoom(lead.token, c.groupId);
    const wo = await env.joinRoom(owner.token, c.groupId);
    wo.sendJson({ type: 'SOS', lat: 17.385, lng: 78.4867, alertType: 'CRASH_OR_EMERGENCY', clientId: 'restart-1' });
    const alert = (await wl.next((m) => m.type === 'ALERT')).alert;
    const made = await api('POST', `/convoys/${c.groupId}/alerts/${alert.alertId}/live-link`, {}, owner.token);
    assert.equal(made.status, 200, JSON.stringify(made.json));
    wl.close(); wo.close();
    // Let the room write its state, then forget it as a restart would.
    const room = gw.convoys.rooms.get(c.groupId);
    await gw.convoys.flushRoom(room).catch(() => {});
    await new Promise((r) => setTimeout(r, 50));
    gw.convoys.rooms.delete(c.groupId);
    gw.convoys.liveLinks.clear();
    gw.convoys._liveWarmed = false; // a restarted gateway has loaded nothing yet
    gw.convoys._liveWarmAt = 0;
    const res = await fetch(`${env.origin}/api/public/live/${made.json.token}`);
    assert.equal(res.status, 200, 'the link is found after loading the live rooms');
    const body = await res.json();
    assert.equal(body.firstName, 'Asha');
    const page = await fetch(`${env.origin}/e/${made.json.token}`);
    assert.equal(page.status, 200);
  });
});
