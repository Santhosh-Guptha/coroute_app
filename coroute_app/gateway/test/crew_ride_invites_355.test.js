'use strict';
/**
 * 3.55 "Start a ride with this crew" (docs/features_355/crews_polls.md, "Crew rides"): the trip owner
 * of a live ride invites chosen crew members; they accept (joining through the normal join logic,
 * without the join code) or decline. Validation matrix, capacity, expiry, privacy, socket + push.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'crewrideadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const F = require('../src/friends');
const RI = require('../src/crew_ride_invites');

let t;
let admin;
const pushes = [];
before(async () => {
  t = await boot();
  const ips = new Map();
  const call = t.api;
  t.api = (m, p, b, token, h = {}) => {
    if (!ips.has(token)) ips.set(token, `198.51.${100 + (ips.size >> 8)}.${ips.size % 256}`);
    return call(m, p, b, token, { 'X-Forwarded-For': ips.get(token), ...h });
  };
  admin = await t.register('Crew Ride Console', 'crewrideadmin@coroute.test');
  // A fake push service (the real one is src/push.js): records every call, never throws.
  t.gw.hub.push = { notifyUsers: async (ids, opts) => { pushes.push({ ids, opts }); return { sent: ids.length }; }, onSocketEvent: async () => null };
});
after(async () => { await t.gw.shutdown(); });

let seq = 0;
async function rider(name) {
  seq++;
  const r = await t.api('POST', '/auth/register', {
    name, email: `crewride${seq}_${Date.now()}@coroute.test`, password: 'Password#123',
    phone: `+9196${String(10000000 + seq).slice(-8)}`, vehicleType: 'Motorcycle', vehicleNo: `KA02CR${String(1000 + seq).slice(-4)}`,
    emergencyContact: '+919000000002', emergencyContactName: 'Family Contact',
  }, null, { 'X-Forwarded-For': `203.0.114.${seq % 250}` });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}
async function befriend(x, y) {
  const out = await F.sendRequest(t.soda, x.user.userId, y.user.userId);
  if (out.status === 'REQUESTED') await F.respond(t.soda, y.user.userId, out.edge.requestId, true);
}
async function crewWith(owner, members, name = 'Ghat Crew') {
  const c = await t.api('POST', '/crews', { name }, owner.token);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  const crew = c.json.crew;
  for (const m of members) {
    await befriend(owner, m);
    const inv = await t.api('POST', `/crews/${crew.crewId}/invites`, { username: m.user.username }, owner.token);
    assert.equal(inv.status, 201, JSON.stringify(inv.json));
    const list = await t.api('GET', '/crews', null, m.token);
    const mine = list.json.invites.find((i) => i.crewId === crew.crewId);
    assert.equal((await t.api('POST', `/crews/invites/${mine.inviteId}/accept`, null, m.token)).json.status, 'JOINED');
  }
  return crew;
}
async function startRide(host, name = 'Sunrise Loop') {
  const c = await t.api('POST', '/convoys', { name, startPoint: 'Cubbon Park Gate', destination: 'Nandi Hills' }, host.token);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  return c.json;
}
const send = (crew, host, groupId, usernames) => t.api('POST', `/crews/${crew.crewId}/ride-invites`, { groupId, usernames }, host.token);
const setFlag = (id, enabled) => t.api('PUT', `/admin/features/${id}`, { enabled, reason: 'test' }, admin.token);
const end = (host, gid) => t.api('POST', `/convoys/${gid}/status`, { status: 'ENDED' }, host.token);

test('pure helpers: usernames cleaned, status expiry, push text', () => {
  assert.deepEqual(RI.cleanUsernames([' @Swift ', 'swift', 'Kite', 7, '', 'x'.repeat(41)]), ['Swift', 'Kite']);
  assert.deepEqual(RI.cleanUsernames('Solo'), ['Solo']);
  const inv = { status: 'PENDING', expiresAt: 1000 };
  assert.equal(RI.effectiveStatus(inv, { now: 999 }), 'PENDING');
  assert.equal(RI.effectiveStatus(inv, { now: 1000 }), 'EXPIRED');
  assert.equal(RI.effectiveStatus(inv, { now: 1, rideActive: false }), 'EXPIRED');
  assert.equal(RI.effectiveStatus({ status: 'DECLINED', expiresAt: 0 }, { now: 5 }), 'DECLINED');
  assert.deepEqual(RI.inviteText({ hostUsername: 'SwiftFalcon482', rideName: 'Sunrise Loop', crewName: 'Ghat Crew' }),
    { title: 'Ride invitation', body: 'SwiftFalcon482 invited you to Sunrise Loop with Ghat Crew' });
  assert.equal(RI.LIMITS.TTL_MS, 12 * 3600000);
});

test('host invites chosen crew members: socket + push (no sensitive data), invitee sees it, accepts and joins without the code', async () => {
  const host = await rider('Hari Host');
  const asha = await rider('Asha Rao');
  const kiran = await rider('Kiran Das');
  const crew = await crewWith(host, [asha, kiran]);
  const ride = await startRide(host);
  const wa = await t.connect(asha.token);
  const wh = await t.connect(host.token);
  pushes.length = 0;

  const out = await send(crew, host, ride.groupId, [asha.user.username]);
  assert.equal(out.status, 201, JSON.stringify(out.json));
  assert.deepEqual(out.json.results.map((x) => x.status), ['INVITED']);
  assert.equal(out.json.invites.length, 1);
  assert.equal(out.json.invites[0].status, 'PENDING');
  assert.equal(out.json.invites[0].username, asha.user.username);
  const body = JSON.stringify(out.json);
  assert.ok(!body.includes(ride.joinCode), 'no join code');
  assert.ok(!body.includes(asha.user.userId), 'no userIds');

  // Socket to the invitee.
  const msg = await wa.next((m) => m.type === 'RIDE_INVITE');
  assert.equal(msg.crewName, 'Ghat Crew');
  assert.equal(msg.rideName, 'Sunrise Loop');
  assert.equal(msg.username, host.user.username);
  assert.ok(!JSON.stringify(msg).includes(ride.joinCode));
  // Push through the fake: the contract, no sensitive data.
  assert.equal(pushes.length, 1);
  assert.deepEqual(pushes[0].ids, [asha.user.userId]);
  assert.equal(pushes[0].opts.type, 'RIDE_INVITE');
  assert.equal(pushes[0].opts.title, 'Ride invitation');
  assert.equal(pushes[0].opts.body, `${host.user.username} invited you to Sunrise Loop with Ghat Crew`);
  assert.deepEqual(Object.keys(pushes[0].opts.data), ['inviteId', 'eventId']);
  // Same eventId as the socket message: the app shows one notice (3.55 follow-up dedupe).
  assert.equal(pushes[0].opts.data.eventId, `RIDE_INVITE:${pushes[0].opts.data.inviteId}`);
  assert.equal(msg.eventId, pushes[0].opts.data.eventId);
  assert.equal(pushes[0].opts.priority, 'high');
  assert.equal(pushes[0].opts.ttlSec, 1800);
  const pushText = JSON.stringify(pushes[0].opts);
  for (const secret of [ride.joinCode, '+9196', '@coroute.test', 'Family Contact', 'Hari Host']) assert.ok(!pushText.includes(secret), secret);

  // The invitee's list: host username, crew, ride, start / destination names, riders; no code, no coordinates.
  const mine = await t.api('GET', '/me/ride-invites', null, asha.token);
  assert.equal(mine.status, 200);
  assert.equal(mine.json.invites.length, 1);
  const v = mine.json.invites[0];
  assert.equal(v.host.username, host.user.username);
  assert.equal(v.host.displayName, 'Hari');
  assert.equal(v.crew.name, 'Ghat Crew');
  assert.equal(v.ride.name, 'Sunrise Loop');
  assert.equal(v.ride.startName, 'Cubbon Park Gate');
  assert.equal(v.ride.destinationName, 'Nandi Hills');
  assert.equal(v.ride.riders, 1);
  const vs = JSON.stringify(v);
  assert.ok(!vs.includes(ride.joinCode) && !/"lat"|"lng"|joinCode|userId/.test(vs), vs);
  const one = await t.api('GET', `/ride-invites/${v.inviteId}`, null, asha.token);
  assert.equal(one.json.invite.inviteId, v.inviteId);
  assert.equal((await t.api('GET', `/ride-invites/${v.inviteId}`, null, kiran.token)).status, 404, 'not for others');

  // Accept: joins the ride (normal join; no code in the request).
  const acc = await t.api('POST', `/ride-invites/${v.inviteId}/accept`, { rider: { vehicleModel: 'Classic 350', vehicleColor: 'Red' } }, asha.token);
  assert.equal(acc.status, 200, JSON.stringify(acc.json));
  assert.equal(acc.json.status, 'ACCEPTED');
  assert.ok(acc.json.convoy && acc.json.convoy.riders[asha.user.userId]);
  assert.ok(t.gw.convoys.rooms.get(ride.groupId).riders.has(asha.user.userId));
  const upd = await wh.next((m) => m.type === 'RIDE_INVITE_UPDATE');
  assert.equal(upd.status, 'ACCEPTED');
  assert.equal(upd.username, asha.user.username);
  // Accepting again is harmless; the list is empty now; the host sees ACCEPTED.
  assert.equal((await t.api('POST', `/ride-invites/${v.inviteId}/accept`, {}, asha.token)).json.status, 'ACCEPTED');
  assert.equal((await t.api('GET', '/me/ride-invites', null, asha.token)).json.invites.length, 0);
  const statuses = await t.api('GET', `/crews/${crew.crewId}/ride-invites?groupId=${ride.groupId}`, null, host.token);
  assert.equal(statuses.json.invites[0].status, 'ACCEPTED');
  // Inviting a rider already in the ride, and the same rider twice.
  const again = await send(crew, host, ride.groupId, [asha.user.username, kiran.user.username, kiran.user.username]);
  assert.deepEqual(again.json.results.map((x) => x.status), ['ALREADY_IN_RIDE', 'INVITED']);
  const dup = await send(crew, host, ride.groupId, [kiran.user.username]);
  assert.equal(dup.status, 200);
  assert.deepEqual(dup.json.results.map((x) => x.status), ['ALREADY_INVITED']);
  wa.close(); wh.close();
  await end(host, ride.groupId);
});

test('decline: the host is told; the invite is closed', async () => {
  const host = await rider('Dev Host');
  const asha = await rider('Asha Two');
  const crew = await crewWith(host, [asha], 'Coast Crew');
  const ride = await startRide(host, 'Coast Run');
  const wh = await t.connect(host.token);
  await send(crew, host, ride.groupId, [asha.user.username]);
  const inv = (await t.api('GET', '/me/ride-invites', null, asha.token)).json.invites[0];
  const dec = await t.api('POST', `/ride-invites/${inv.inviteId}/decline`, null, asha.token);
  assert.equal(dec.json.status, 'DECLINED');
  const upd = await wh.next((m) => m.type === 'RIDE_INVITE_UPDATE');
  assert.equal(upd.status, 'DECLINED');
  assert.equal((await t.api('POST', `/ride-invites/${inv.inviteId}/accept`, {}, asha.token)).status, 410);
  assert.equal((await t.api('GET', '/me/ride-invites', null, asha.token)).json.invites.length, 0);
  assert.ok(!t.gw.convoys.rooms.get(ride.groupId).riders.has(asha.user.userId));
  // Declined riders can be invited again.
  assert.deepEqual((await send(crew, host, ride.groupId, [asha.user.username])).json.results.map((x) => x.status), ['INVITED']);
  wh.close();
  await end(host, ride.groupId);
});

test('validation matrix: non-member, non-host, not in crew, ended ride, solo ride, empty list, switches', async () => {
  const host = await rider('Mira Host');
  const asha = await rider('Asha Three');
  const kiran = await rider('Kiran Three');
  const outsider = await rider('Out Sider');
  const crew = await crewWith(host, [asha, kiran], 'Hill Crew');
  const ride = await startRide(host, 'Hill Climb');

  // A rider outside the crew: the crew is invisible.
  assert.equal((await send(crew, outsider, ride.groupId, [asha.user.username])).status, 404);
  // A crew member who is not the trip owner of that ride.
  const notHost = await send(crew, asha, ride.groupId, [kiran.user.username]);
  assert.equal(notHost.status, 403);
  assert.equal(notHost.json.code, 'NOT_RIDE_HOST');
  // Unknown ride id.
  assert.equal((await send(crew, host, 'GRP-NOPE', [asha.user.username])).json.code, 'NOT_RIDE_HOST');
  // Invitees who are not crew members / unknown: the same answer.
  const odd = await send(crew, host, ride.groupId, [outsider.user.username, 'NoSuchRider999', host.user.username]);
  assert.deepEqual(odd.json.results.map((x) => x.status), ['NOT_A_MEMBER', 'NOT_A_MEMBER', 'ALREADY_IN_RIDE']);
  assert.equal(odd.status, 200);
  // Empty and too many.
  assert.equal((await send(crew, host, ride.groupId, [])).json.code, 'NO_INVITEES');
  assert.equal((await send(crew, host, ride.groupId, Array.from({ length: 51 }, (_, i) => `Rider${i}x`))).json.code, 'TOO_MANY_INVITEES');
  // Blocked either way: same answer as not a member.
  await F.block(t.soda, kiran.user.userId, host.user.userId);
  assert.deepEqual((await send(crew, host, ride.groupId, [kiran.user.username])).json.results.map((x) => x.status), ['NOT_A_MEMBER']);
  // Switches: crewRides off answers 403 FEATURE_OFF everywhere.
  assert.equal((await setFlag('crewRides', false)).status, 200);
  const off = await send(crew, host, ride.groupId, [asha.user.username]);
  assert.equal(off.status, 403);
  assert.equal(off.json.code, 'FEATURE_OFF');
  assert.equal((await t.api('GET', '/me/ride-invites', null, asha.token)).status, 403);
  assert.equal((await setFlag('crewRides', true)).status, 200);
  // Ended ride: refused.
  await end(host, ride.groupId);
  const ended = await send(crew, host, ride.groupId, [asha.user.username]);
  assert.equal(ended.status, 409);
  assert.equal(ended.json.code, 'RIDE_ENDED');
  // Solo ride (the host's plan has one seat).
  const solo = await startRide(host, 'Solo Spin');
  const realCap = t.gw.convoys._currentCapacity;
  t.gw.convoys._currentCapacity = async () => 1;
  try {
    const s = await send(crew, host, solo.groupId, [asha.user.username]);
    assert.equal(s.status, 409);
    assert.equal(s.json.code, 'SOLO_TRIP_ONLY');
  } finally { t.gw.convoys._currentCapacity = realCap; }
  await end(host, solo.groupId);
});

test('capacity per host plan: riders + waiting invites; accept into a full ride is refused by the normal join', async () => {
  const host = await rider('Cap Host');
  const a = await rider('Cap Asha');
  const b = await rider('Cap Kiran');
  const c = await rider('Cap Arjun');
  const crew = await crewWith(host, [a, b, c], 'Seat Crew');
  const ride = await startRide(host, 'Seat Ride');
  const realCap = t.gw.convoys._currentCapacity;
  t.gw.convoys._currentCapacity = async () => 3; // host + 2 seats
  try {
    const out = await send(crew, host, ride.groupId, [a.user.username, b.user.username, c.user.username]);
    assert.deepEqual(out.json.results.map((x) => x.status), ['INVITED', 'INVITED', 'RIDE_FULL']);
    assert.equal(out.json.capacity, 3);
    // Someone joins by code meanwhile and fills the ride: the next accept is refused by the join rules.
    const other = await rider('Code Joiner');
    assert.equal((await t.api('POST', '/convoys/join', { code: ride.joinCode }, other.token)).status, 200);
    const ia = (await t.api('GET', '/me/ride-invites', null, a.token)).json.invites[0];
    assert.equal((await t.api('POST', `/ride-invites/${ia.inviteId}/accept`, {}, a.token)).status, 200);
    const ib = (await t.api('GET', '/me/ride-invites', null, b.token)).json.invites[0];
    const full = await t.api('POST', `/ride-invites/${ib.inviteId}/accept`, {}, b.token);
    assert.equal(full.status, 409);
    assert.equal(full.json.code, 'CONVOY_FULL');
  } finally { t.gw.convoys._currentCapacity = realCap; }
  await end(host, ride.groupId);
});

test('expiry: after 12 h, or when the ride ends; a rider who left the crew cannot accept', async () => {
  const host = await rider('Exp Host');
  const a = await rider('Exp Asha');
  const b = await rider('Exp Kiran');
  const crew = await crewWith(host, [a, b], 'Late Crew');
  const ride = await startRide(host, 'Late Ride');
  await send(crew, host, ride.groupId, [a.user.username, b.user.username]);
  const ia = (await t.api('GET', '/me/ride-invites', null, a.token)).json.invites[0];
  assert.ok(ia.expiresAt - ia.createdAt === 12 * 3600000);
  // 12 h later (moved in the store).
  const row = await t.soda.findOne(RI.COLL, { inviteId: ia.inviteId });
  await t.soda.replace(RI.COLL, row.key, { ...row.value, expiresAt: Date.now() - 1 });
  assert.equal((await t.api('GET', '/me/ride-invites', null, a.token)).json.invites.length, 0);
  const late = await t.api('POST', `/ride-invites/${ia.inviteId}/accept`, {}, a.token);
  assert.equal(late.status, 410);
  assert.equal(late.json.code, 'INVITE_EXPIRED');
  // Kiran leaves the crew: the invite is gone.
  const ib = (await t.api('GET', '/me/ride-invites', null, b.token)).json.invites[0];
  assert.equal((await t.api('POST', `/crews/${crew.crewId}/leave`, {}, b.token)).status, 200);
  assert.equal((await t.api('POST', `/ride-invites/${ib.inviteId}/accept`, {}, b.token)).json.code, 'INVITE_GONE');
  // The ride ends: pending invites expire.
  const c = await rider('Exp Arjun');
  const crew2 = await crewWith(host, [c], 'End Crew');
  await send(crew2, host, ride.groupId, [c.user.username]);
  const ic = (await t.api('GET', '/me/ride-invites', null, c.token)).json.invites[0];
  await end(host, ride.groupId);
  assert.equal((await t.api('GET', '/me/ride-invites', null, c.token)).json.invites.length, 0);
  assert.equal((await t.api('POST', `/ride-invites/${ic.inviteId}/accept`, {}, c.token)).json.code, 'INVITE_EXPIRED');
  const hostView = await t.api('GET', `/crews/${crew2.crewId}/ride-invites?groupId=${ride.groupId}`, null, host.token);
  assert.equal(hostView.json.invites[0].status, 'EXPIRED');
  assert.equal(hostView.json.rideActive, false);
});

test('host cancels a waiting invite; push failures never break the request', async () => {
  const host = await rider('Can Host');
  const a = await rider('Can Asha');
  const crew = await crewWith(host, [a], 'Cancel Crew');
  const ride = await startRide(host, 'Cancel Ride');
  const real = t.gw.hub.push;
  t.gw.hub.push = { notifyUsers: () => { throw new Error('fcm down'); } };
  try {
    assert.equal((await send(crew, host, ride.groupId, [a.user.username])).status, 201);
  } finally { t.gw.hub.push = real; }
  const ia = (await t.api('GET', '/me/ride-invites', null, a.token)).json.invites[0];
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/ride-invites/${ia.inviteId}`, null, a.token)).status, 404, 'only the host');
  assert.equal((await t.api('DELETE', `/crews/${crew.crewId}/ride-invites/${ia.inviteId}`, null, host.token)).status, 200);
  assert.equal((await t.api('GET', '/me/ride-invites', null, a.token)).json.invites.length, 0);
  assert.equal((await t.api('POST', `/ride-invites/${ia.inviteId}/accept`, {}, a.token)).json.code, 'INVITE_GONE');
  await end(host, ride.groupId);
});
