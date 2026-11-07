'use strict';
/**
 * 3.55 group safety (docs/features_355/group_safety.md): the gateway parts only, the logic is on the
 * phones. Group stretch alert setting (stretchAlertKm), fatigue level in rider telemetry, buddy pairs
 * (BUDDY_ASSIGN / BUDDY_PING / re-pairing) and the anonymous risky-stretch cells (k >= 10).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { featurePolicy, policyPatch, DEFAULTS } = require('../src/feature_policy');
const { sanitizeTelemetry, publicRider } = require('../src/convoys');
const { assignBuddies, repairBuddies, groupsOf } = require('../src/buddies');
const { RoadRiskStore, groupEvents, cellOf, K_MIN, COLLECTION } = require('../src/road_risk');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { encodePolyline } = require('../src/geo_math');

let t, gw;
before(async () => { t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); });

const uid = (u) => u.user.userId;
let n = 0;
// Straight to the auth service (the REST register limit is 30 per 15 min per address).
let phone = 0;
const register = async (name, email) => {
  phone++;
  return JSON.parse(JSON.stringify(await gw.auth.register({
    name, email, password: 'Password#123', phone: `+9198766${String(10000 + phone).slice(-5)}`,
    vehicleType: 'Motorcycle', vehicleNo: `TS10AB${String(1000 + phone).slice(-4)}`,
    emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  })));
};
async function ride(riders) {
  n++;
  const lead = await register(`Lead ${n}`, `gslead${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Group ${n}` }, lead.token)).json;
  const members = [];
  for (let i = 0; i < riders - 1; i++) {
    n++;
    const u = await register(`Rider ${n}`, `gsrider${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  return { lead, c, gid: c.groupId, room: gw.convoys.rooms.get(c.groupId), members };
}

/** Every rider watches exactly one other rider of the ride, never themselves. */
function assertValidPairs(map, ids) {
  assert.deepEqual(Object.keys(map).sort(), [...ids].sort());
  for (const [a, b] of Object.entries(map)) { assert.notEqual(a, b); assert.ok(ids.includes(b)); }
  for (const g of groupsOf('x', map)) assert.ok(g.length === 2 || g.length === 3);
}

// ------------------------------------------------------------------ stretchAlertKm
test('stretchAlertKm: default 3, only 1/2/3/5 accepted, a bad stored value reads as the default', () => {
  assert.equal(DEFAULTS.stretchAlertKm, 3);
  assert.equal(featurePolicy({}).stretchAlertKm, 3);
  for (const v of [1, 2, 3, 5]) assert.equal(policyPatch({}, { stretchAlertKm: v }).stretchAlertKm, v);
  for (const v of [0, 4, 6, 2.5, '3', null, true, -1, 100]) assert.throws(() => policyPatch({}, { stretchAlertKm: v }), /Invalid feature setting/);
  assert.equal(featurePolicy({ stretchAlertKm: 4 }).stretchAlertKm, 3);
  assert.equal(featurePolicy({ stretchAlertKm: 5 }).stretchAlertKm, 5);
  // Other settings still validate as before.
  assert.equal(policyPatch({}, { guardianStopMinutes: 30 }).guardianStopMinutes, 30);
  assert.throws(() => policyPatch({}, { guardianStopMinutes: 3 }));
  assert.equal(policyPatch({ stretchAlertKm: 2 }, { essentialsEnabled: false }).stretchAlertKm, 2);
});

test('stretchAlertKm through CONFIG: the lead sets it, a rider cannot, a bad value is refused', async () => {
  const R = await ride(2);
  const wl = await t.joinRoom(R.lead.token, R.gid);
  wl.sendJson({ type: 'CONFIG', featurePolicy: { stretchAlertKm: 5 } });
  const cfg = await wl.next((m) => m.type === 'CONFIG' && m.featurePolicy && m.featurePolicy.stretchAlertKm === 5);
  assert.equal(cfg.featurePolicy.stretchAlertKm, 5);
  wl.sendJson({ type: 'CONFIG', featurePolicy: { stretchAlertKm: 4 } });
  assert.match((await wl.next((m) => m.type === 'ERROR')).message || '', /Invalid feature setting/);
  const wr = await t.joinRoom(R.members[0].token, R.gid);
  wr.sendJson({ type: 'CONFIG', featurePolicy: { stretchAlertKm: 1 } });
  await wr.next((m) => m.type === 'ERROR');
  assert.equal(featurePolicy(R.room.meta.featurePolicy).stretchAlertKm, 5);
  wl.close(); wr.close();
});

// ------------------------------------------------------------------ fatigueLevel
test('fatigueLevel telemetry: whole 0..3 only (rounded), anything else dropped; public only while recent; old apps read 0', () => {
  assert.equal(sanitizeTelemetry({ fatigueLevel: 2 }).fatigueLevel, 2);
  assert.equal(sanitizeTelemetry({ fatigueLevel: 2.4 }).fatigueLevel, 2);
  assert.equal(sanitizeTelemetry({ fatigueLevel: 0 }).fatigueLevel, 0);
  for (const v of [4, -1, 3.6, '2', true, NaN, Infinity, { x: 1 }]) assert.equal(sanitizeTelemetry({ fatigueLevel: v }).fatigueLevel, undefined, String(v));
  assert.ok(Number.isFinite(sanitizeTelemetry({ fatigueLevel: 1 }).fatigueAt));
  assert.equal(publicRider({ userId: 'a', fatigueLevel: 3, fatigueAt: Date.now() }).fatigueLevel, 3);
  assert.equal(publicRider({ userId: 'a', fatigueLevel: 3, fatigueAt: Date.now() - 11 * 60000 }).fatigueLevel, 0);
  assert.equal(publicRider({ userId: 'a' }).fatigueLevel, 0);
  assert.equal(publicRider({ userId: 'a', fatigueLevel: 3, fatigueAt: Date.now() }).fatigueAt, undefined, 'the time stays on the server');
});

test('fatigueLevel over the socket: TELEMETRY carries it to the group; a bad value never changes it', async () => {
  const R = await ride(2);
  const wr = await t.joinRoom(R.members[0].token, R.gid);
  const wl = await t.joinRoom(R.lead.token, R.gid);
  wr.sendJson({ type: 'TELEMETRY', lat: 17.4, lng: 78.4, fatigueLevel: 2 });
  const upd = await wl.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(R.members[0]));
  assert.equal(upd.rider.fatigueLevel, 2);
  wr.sendJson({ type: 'TELEMETRY', lat: 17.4, lng: 78.4, fatigueLevel: 9 });
  await sleep(400);
  assert.equal(R.room.riders.get(uid(R.members[0])).fatigueLevel, 2);
  wr.close(); wl.close();
});

// ------------------------------------------------------------------ buddy pairs (pure)
test('buddy assignment: deterministic, every rider one buddy, an odd count makes one trio', () => {
  const ids = ['u1', 'u2', 'u3', 'u4', 'u5', 'u6', 'u7'];
  const a = assignBuddies('G1', ids);
  assert.deepEqual(a, assignBuddies('G1', [...ids].reverse()), 'same riders, same pairs whatever the order');
  assertValidPairs(a, ids);
  const groups = groupsOf('G1', a);
  assert.equal(groups.filter((g) => g.length === 3).length, 1);
  assert.equal(groups.filter((g) => g.length === 2).length, 2);
  const even = assignBuddies('G1', ids.slice(0, 6));
  assertValidPairs(even, ids.slice(0, 6));
  assert.ok(groupsOf('G1', even).every((g) => g.length === 2));
  for (const [x, y] of Object.entries(even)) assert.equal(even[y], x, 'pairs watch each other');
  assert.deepEqual(assignBuddies('G1', ['solo']), {});
  assert.notDeepEqual(assignBuddies('G1', ids), assignBuddies('G2', ids), 'another ride shuffles differently');
});

test('buddy re-pairing: kept pairs stay; a leaver\'s buddy and a newcomer are paired; odd counts form or break a trio', () => {
  const ids = ['u1', 'u2', 'u3', 'u4', 'u5', 'u6', 'u7', 'u8'];
  const start = assignBuddies('G', ids);
  const pairOf = (m, x) => [x, m[x]].sort().join('|');
  // One leaves (7 left): their buddy joins another pair as a trio, every other pair is untouched.
  const gone = ids[0];
  const orphan = start[gone];
  const after = repairBuddies('G', start, ids.filter((x) => x !== gone));
  assertValidPairs(after, ids.filter((x) => x !== gone));
  for (const x of ids) if (x !== gone && x !== orphan && start[x] !== gone && start[start[x]] === x) {
    const g = groupsOf('G', after).find((gg) => gg.includes(x));
    assert.ok(g.includes(start[x]), `${x} keeps ${start[x]}`);
  }
  // A newcomer (8 again): the trio breaks up into two pairs.
  const back = repairBuddies('G', after, [...ids.filter((x) => x !== gone), 'u9']);
  assertValidPairs(back, [...ids.filter((x) => x !== gone), 'u9']);
  assert.ok(groupsOf('G', back).every((g) => g.length === 2));
  // Deterministic.
  assert.deepEqual(repairBuddies('G', start, ids.filter((x) => x !== gone)), after);
  // Nothing changed: same map.
  assert.equal(pairOf(repairBuddies('G', start, ids), 'u1'), pairOf(start, 'u1'));
  assert.deepEqual(repairBuddies('G', start, ['u1']), {});
  // A broken stored map is repaired from scratch.
  assertValidPairs(repairBuddies('G', { u1: 'u1', u2: 'zz' }, ['u1', 'u2', 'u3']), ['u1', 'u2', 'u3']);
});

// ------------------------------------------------------------------ buddy pairs (socket)
test('buddies: automatic at 7 riders, in the snapshot, re-paired on leave and join; lead-only BUDDY_ASSIGN', async () => {
  const R = await ride(6);
  assert.deepEqual(R.room.meta.buddies || {}, {}, 'no pairs below 7 riders');
  const wl = await t.joinRoom(R.lead.token, R.gid);
  n++;
  const seventh = await register(`Rider ${n}`, `gsrider${n}@coroute.test`);
  assert.equal((await t.api('POST', '/convoys/join', { code: R.c.joinCode }, seventh.token)).status, 200);
  const ev = await wl.next((m) => m.type === 'BUDDIES');
  const ids = [...R.room.riders.keys()];
  assertValidPairs(ev.buddies, ids);
  assert.deepEqual(R.room.meta.buddies, ev.buddies);
  const ws7 = await t.joinRoom(seventh.token, R.gid);
  assert.deepEqual(ws7.snapshot.buddies, ev.buddies);

  // A rider leaves: re-paired (everyone left still has exactly one buddy).
  const leaver = R.members[2];
  assert.equal((await t.api('POST', `/convoys/${R.gid}/leave`, {}, leaver.token)).status < 300, true);
  const ev2 = await wl.next((m) => m.type === 'BUDDIES');
  assertValidPairs(ev2.buddies, [...R.room.riders.keys()]);
  assert.equal(ev2.buddies[uid(leaver)], undefined);

  // Only the lead may reassign.
  const wr = await t.joinRoom(R.members[0].token, R.gid);
  wr.sendJson({ type: 'BUDDY_ASSIGN', clientId: 'b1' });
  assert.equal((await wr.next((m) => m.type === 'ERROR' && m.clientId === 'b1')).reason, 'NOT_AUTHORIZED');
  wl.sendJson({ type: 'BUDDY_ASSIGN', clientId: 'b2' });
  await wl.next((m) => m.type === 'ACK' && m.clientId === 'b2');
  const ev3 = await wl.next((m) => m.type === 'BUDDIES');
  assert.equal(ev3.byUserId, uid(R.lead));
  assert.deepEqual(ev3.buddies, assignBuddies(R.gid, [...R.room.riders.keys()]));
  wl.close(); ws7.close(); wr.close();
});

test('buddies: BUDDY_ASSIGN refused in a small ride when the seats are under 7', async () => {
  const R = await ride(3);
  const cap = R.room.meta.capacity;
  R.room.meta.capacity = 4; // a Small Group host
  const wl = await t.joinRoom(R.lead.token, R.gid);
  wl.sendJson({ type: 'BUDDY_ASSIGN', clientId: 'p1' });
  assert.equal((await wl.next((m) => m.type === 'ERROR' && m.clientId === 'p1')).reason, 'PLAN_REQUIRED');
  R.room.meta.capacity = 10; // a Large Group host: allowed even with 3 riders
  wl.sendJson({ type: 'BUDDY_ASSIGN', clientId: 'p2' });
  await wl.next((m) => m.type === 'ACK' && m.clientId === 'p2');
  assertValidPairs(R.room.meta.buddies, [...R.room.riders.keys()]);
  R.room.meta.capacity = cap;
  wl.close();
});

test('BUDDY_PING: relayed only to the buddy (CHECK, then OK back); a non-buddy is refused; a burst is throttled', async () => {
  const R = await ride(4);
  R.room.meta.capacity = 10;
  const wl = await t.joinRoom(R.lead.token, R.gid);
  wl.sendJson({ type: 'BUDDY_ASSIGN', clientId: 'a1' });
  await wl.next((m) => m.type === 'ACK' && m.clientId === 'a1');
  const buddies = R.room.meta.buddies;
  const all = [R.lead, ...R.members];
  const byId = new Map(all.map((u) => [uid(u), u]));
  const me = R.members[0];
  const buddy = byId.get(buddies[uid(me)]);
  const stranger = all.find((u) => u !== me && u !== buddy && buddies[uid(u)] !== uid(me));
  const sockets = new Map();
  for (const u of all) if (u !== R.lead) sockets.set(uid(u), await t.joinRoom(u.token, R.gid));
  sockets.set(uid(R.lead), wl);
  const wm = sockets.get(uid(me)), wb = sockets.get(uid(buddy));
  wm.sendJson({ type: 'BUDDY_PING', userId: uid(buddy), kind: 'CHECK', clientId: 'k1' });
  const got = await wb.next((m) => m.type === 'BUDDY_PING');
  assert.equal(got.fromUserId, uid(me));
  assert.equal(got.kind, 'CHECK');
  wb.sendJson({ type: 'BUDDY_PING', userId: uid(me), kind: 'OK', clientId: 'k2' });
  assert.equal((await wm.next((m) => m.type === 'BUDDY_PING')).kind, 'OK');
  await sleep(100);
  for (const [id, ws] of sockets) if (id !== uid(me) && id !== uid(buddy)) assert.ok(!ws.inbox.some((m) => m.type === 'BUDDY_PING'), 'nobody else hears it');
  if (stranger) {
    wm.sendJson({ type: 'BUDDY_PING', userId: uid(stranger), kind: 'CHECK', clientId: 'k3' });
    assert.equal((await wm.next((m) => m.type === 'ERROR' && m.clientId === 'k3')).reason, 'NOT_BUDDY');
  }
  wm.sendJson({ type: 'BUDDY_PING', userId: uid(buddy), kind: 'CHECK', clientId: 'k4' });
  await wm.next((m) => m.type === 'ACK' && m.clientId === 'k4');
  await sleep(100);
  assert.equal(wb.inbox.filter((m) => m.type === 'BUDDY_PING').length, 0, 'a second check within 30 s is not relayed');
  for (const ws of sockets.values()) ws.close();
});

// ------------------------------------------------------------------ risky stretch
test('road risk store: cells, heading buckets, k >= 10 distinct riders, no user ids stored, retention', async () => {
  const soda = new MemorySoda();
  const store = new RoadRiskStore(soda);
  await store.ensure();
  const at = { lat: 17.385, lng: 78.4867 };
  assert.equal(groupEvents([{ lat: 1, lng: 2, h: 8 }, { lat: 'x', lng: 2, h: 1 }, { lat: 0, lng: 0, h: 1 }]).length, 0);
  const g = groupEvents([{ ...at, h: 2 }, { lat: at.lat + 0.0002, lng: at.lng, h: 2 }, { ...at, h: 2 }, { ...at, h: 2 }, { ...at, h: 6 }]);
  assert.equal(g.length, 2, 'same cell and direction merge; the other direction is its own cell');
  assert.equal(g.find((x) => x.hb === 2).n, 3, 'at most 3 per cell per batch');
  const box = { s: 17.3, n: 17.5, w: 78.4, e: 78.6 };
  for (let i = 0; i < K_MIN - 1; i++) await store.record(`user-${i}`, [{ ...at, h: 2 }]);
  await store.record('user-0', [{ ...at, h: 2 }]); // a repeat reporter never counts twice
  assert.equal((await store.confirmedIn(box)).length, 0, '9 riders are not enough');
  await store.record(`user-${K_MIN - 1}`, [{ ...at, h: 2 }]);
  const cells = await store.confirmedIn(box);
  assert.equal(cells.length, 1);
  assert.equal(cells[0].reporterCount, K_MIN);
  assert.deepEqual([cells[0].lat, cells[0].lng], [cellOf(at.lat, at.lng).lat, cellOf(at.lat, at.lng).lng], 'rounded centre');
  // Nothing identifying is stored.
  const raw = JSON.stringify((await soda.query(COLLECTION, {}, { limit: 100 })).map((r) => r.value));
  for (let i = 0; i < K_MIN; i++) assert.ok(!raw.includes(`user-${i}`), 'no user id');
  assert.ok(!/userId|ts"|timestamp/.test(raw));
  const doc = (await soda.query(COLLECTION, {}, { limit: 1 }))[0].value;
  assert.deepEqual(Object.keys(doc).sort(), ['cell', 'count', 'firstDay', 'hb', 'lastDay', 'lat', 'lng', 'reporterCount', 'reporters', 'riskId'].sort());
  // Retention: 181 days without an event removes the cell.
  await store.purgeOld(Date.now() + 179 * 86400000);
  assert.equal((await store.confirmedIn(box)).length, 1);
  await store.purgeOld(Date.now() + 182 * 86400000);
  assert.equal((await store.confirmedIn(box)).length, 0);
});

test('road risk REST: POST brakes (auth), GET near a ride\'s route returns only k >= 10 cells within 120 m', async () => {
  const on = { lat: 17.40, lng: 78.45 };
  const off = { lat: 17.40, lng: 78.47 }; // ~2 km east of the route
  const R = await ride(1);
  R.room.meta.route = { polyline: encodePolyline([{ lat: 17.38, lng: 78.45 }, { lat: 17.42, lng: 78.45 }]), distanceM: 4400 };
  assert.equal((await t.api('POST', '/road-risk/brakes', { events: [{ ...on, h: 0 }] })).status, 401);
  assert.equal((await t.api('POST', '/road-risk/brakes', { nope: 1 }, R.lead.token)).status, 400);
  for (let i = 0; i < K_MIN; i++) {
    n++;
    const u = await register(`Brake ${n}`, `gsbrake${n}@coroute.test`);
    const res = await t.api('POST', '/road-risk/brakes', { events: [{ ...on, h: 0 }, { ...off, h: 0 }, ...(i < 5 ? [{ lat: 17.41, lng: 78.45, h: 0 }] : [])] }, u.token);
    assert.equal(res.status, 200, JSON.stringify(res.json));
  }
  const near = await t.api('GET', `/road-risk/near?groupId=${R.gid}`, null, R.lead.token);
  assert.equal(near.status, 200);
  assert.equal(near.json.cells.length, 1, 'the off-route cell and the 5-rider cell are left out');
  const c = near.json.cells[0];
  assert.deepEqual(Object.keys(c).sort(), ['headingBucket', 'headingDeg', 'id', 'lat', 'lng']);
  assert.equal(c.lat, cellOf(on.lat, on.lng).lat);
  // Members only.
  n++;
  const other = await register(`Other ${n}`, `gsother${n}@coroute.test`);
  assert.equal((await t.api('GET', `/road-risk/near?groupId=${R.gid}`, null, other.token)).status, 403);
  // The admin switch turns both off.
  const ff = gw.convoys.featureFlags;
  const orig = ff.isOn.bind(ff);
  ff.isOn = (id) => (id === 'riskyStretch' ? false : orig(id));
  try {
    assert.equal((await t.api('GET', `/road-risk/near?groupId=${R.gid}`, null, R.lead.token)).json.code, 'FEATURE_OFF');
    assert.equal((await t.api('POST', '/road-risk/brakes', { events: [] }, R.lead.token)).status, 403);
  } finally { ff.isOn = orig; }
});

// ------------------------------------------------------------------ missing-rider check (relay only)
test('missing-rider check: the phone\'s NO_REPLY goes through CHECK_IN; the timeline entry says why; OK closes it', async () => {
  const R = await ride(2);
  const me = R.members[0];
  const wm = await t.joinRoom(me.token, R.gid);
  const wl = await t.joinRoom(R.lead.token, R.gid);
  wm.sendJson({ type: 'CHECK_IN', result: 'NO_REPLY', context: 'MISSING_RIDER', awayM: 1400, clientId: 'm1' });
  await wm.next((m) => m.type === 'ACK' && m.clientId === 'm1');
  const ev = await wl.next((m) => m.type === 'TIMELINE' && m.event && m.event.type === 'NO_REPLY');
  assert.equal(ev.event.userId, uid(me));
  assert.equal(ev.event.data.context, 'MISSING_RIDER');
  assert.equal(ev.event.data.awayM, 1400);
  wm.sendJson({ type: 'CHECK_IN', result: 'OK', clientId: 'm2' });
  const closed = await wl.next((m) => m.type === 'TIMELINE_UPDATE' && m.event && m.event.type === 'NO_REPLY' && m.event.open === false);
  assert.equal(closed.event.userId, uid(me));
  // A plain solo check-in NO_REPLY carries no context.
  wm.sendJson({ type: 'CHECK_IN', result: 'NO_REPLY', clientId: 'm3' });
  const plain = await wl.next((m) => m.type === 'TIMELINE' && m.event && m.event.type === 'NO_REPLY' && m.event.open === true);
  assert.equal(plain.event.data.context, undefined);
  wm.close(); wl.close();
});
