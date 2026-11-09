'use strict';
/**
 * 3.55 admin feature switches ("kill switches"): the master admin turns a feature off for every rider
 * (and back on). Admin-only writes, locked safety features, a required reason to switch off, the
 * database as the truth (a fresh cache on another node reads the same state), the FEATURE_FLAGS push
 * to connected apps, and server-side enforcement (403 FEATURE_OFF) on REST and socket messages.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'ffadmin@coroute.test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const {
  FeatureFlags, CATALOG, effectiveFlags, cleanStored, wsFeaturesFor, firstOff, FEATURE_OFF_MESSAGE,
} = require('../src/feature_flags');

let t, gw, admin, rider;
before(async () => {
  t = await boot();
  gw = t.gw;
  admin = await t.register('Fiona Admin', 'ffadmin@coroute.test');
  rider = await t.register('Ravi Rider', 'ffrider@coroute.test');
});
after(async () => { await gw.shutdown(); });

const setFlag = (id, body, token = admin.token) => t.api('PUT', `/admin/features/${id}`, body, token);

let n = 0;
async function groupRide() {
  n++;
  const lead = await t.register(`Lead ${n}`, `fflead${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Switch ride ${n}` }, lead.token)).json;
  const members = [];
  for (let i = 0; i < 2; i++) {
    n++;
    const u = await t.register(`Member ${n}`, `ffmember${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  return { lead, gid: c.groupId, members };
}

test('pure: defaults, locked features, cleaning and the socket message map', () => {
  const all = effectiveFlags({});
  for (const e of CATALOG) assert.equal(all[e.id], e.locked ? true : e.defaultOn);
  for (const id of ['sos', 'crashDetection', 'emergencySms', 'medicalId']) {
    assert.equal(CATALOG.find((e) => e.id === id).locked, true, `${id} is locked`);
    assert.equal(effectiveFlags({ [id]: false })[id], true, 'a locked feature can never be off');
  }
  for (const id of ['rideRoles', 'autoRoles', 'roadHazards', 'roadHistory', 'placeReviews', 'heritagePlaces', 'offRouteGroupPrompt',
    'vehicleSwap', 'engineCare', 'fuelAutoRoute', 'essentials', 'mapPlaces', 'publicRide', 'discovery', 'assistNetwork', 'intercom',
    'guardianLink', 'groupFuel', 'rideAnalytics', 'reviewPrompt', 'weather', 'sirenDetector', 'bleRemote', 'communityStatsWebsite']) {
    const e = CATALOG.find((x) => x.id === id);
    assert.ok(e && !e.locked, `${id} is switchable`);
  }
  // 3.55 audio / mic round and live bike change: switchable, on by default, listed in the console.
  const added = { speedAudio: 'Riding', callAwareAlerts: 'Riding', hornAlert: 'Safety', voiceCleanup: 'Group', riderVehicleLive: 'Group' };
  for (const [id, group] of Object.entries(added)) {
    const e = CATALOG.find((x) => x.id === id);
    assert.ok(e && !e.locked && e.defaultOn === true && e.group === group && e.label && e.description, `${id} is a default-on switch in ${group}`);
  }
  assert.match(CATALOG.find((x) => x.id === 'sirenDetector').description, /ambulance, police and fire/);
  assert.equal(new Set(CATALOG.map((e) => e.id)).size, CATALOG.length, 'ids are unique');
  assert.deepEqual(wsFeaturesFor({ type: 'RIDER_VEHICLE' }), ['riderVehicleLive']);
  assert.deepEqual(cleanStored({ sos: false, weather: false, nope: false, intercom: 'no' }), { weather: false });
  assert.deepEqual(wsFeaturesFor({ type: 'ROAD_HAZARD' }), ['roadHazards']);
  assert.deepEqual(wsFeaturesFor({ type: 'ROLE_SET', role: 'LEAD' }), ['rideRoles']);
  assert.deepEqual(wsFeaturesFor({ type: 'ROLE_SET', role: 'SWEEPER' }), []);
  assert.deepEqual(wsFeaturesFor({ type: 'ROLE_AUTO', on: true }), ['rideRoles', 'autoRoles']);
  assert.deepEqual(wsFeaturesFor({ type: 'ROLE_AUTO', on: false }), [], 'switching automatic roles off is always allowed');
  assert.deepEqual(wsFeaturesFor({ type: 'SWAP_REQUEST' }), ['vehicleSwap']);
  assert.deepEqual(wsFeaturesFor({ type: 'PR_BLOCK' }), [], 'blocking / reporting stays allowed');
  for (const type of ['SOS', 'CHECK_IN', 'REPORT_DOWN', 'SOS_RESPOND', 'TELEMETRY', 'JOIN']) assert.deepEqual(wsFeaturesFor({ type }), []);
  const fl = new FeatureFlags({ logger: { warn() {} } });
  assert.equal(fl.isOn('unknownThing'), true, 'unknown ids are on');
  assert.equal(firstOff(null, ['weather']), null);
});

test('a database outage never switches features off', async () => {
  const soda = { findOne: async () => { throw new Error('db down'); } };
  const fl = new FeatureFlags({ soda, logger: { warn() {} } });
  await fl.refresh();
  assert.equal(fl.isOn('weather'), true);
});

test('riders read the switches; only the admin changes them', async () => {
  const r = await t.api('GET', '/features', null, rider.token);
  assert.equal(r.status, 200);
  assert.equal(r.json.ok, true);
  assert.equal(r.json.flags.rideRoles, true);
  assert.equal(r.json.flags.sos, true);
  assert.match(r.headers.get('cache-control'), /max-age=30/);
  assert.equal((await t.api('GET', '/features')).status, 401, 'authenticated only');

  assert.equal((await t.api('GET', '/admin/features', null, rider.token)).status, 403);
  assert.equal((await setFlag('weather', { enabled: false, reason: 'x' }, rider.token)).status, 403);

  const view = await t.api('GET', '/admin/features', null, admin.token);
  assert.equal(view.status, 200);
  const sos = view.json.features.find((x) => x.id === 'sos');
  assert.equal(sos.locked, true);
  assert.equal(sos.enabled, true);
  assert.ok(view.json.features.every((x) => x.label && x.description && view.json.groups.includes(x.group)));
});

test('validation: unknown id, locked feature, reason required, bad body', async () => {
  assert.equal((await setFlag('nope', { enabled: false, reason: 'x' })).status, 400);
  const locked = await setFlag('sos', { enabled: false, reason: 'testing' });
  assert.equal(locked.status, 400);
  assert.equal(locked.json.code, 'FEATURE_LOCKED');
  const noReason = await setFlag('weather', { enabled: false });
  assert.equal(noReason.status, 400);
  assert.equal(noReason.json.code, 'REASON_REQUIRED');
  assert.equal((await setFlag('weather', { enabled: false, reason: '   ' })).json.code, 'REASON_REQUIRED');
  assert.equal((await setFlag('weather', { enabled: false, reason: 'x'.repeat(201) })).status, 400);
  assert.equal((await setFlag('weather', { enabled: 'false', reason: 'x' })).status, 400);
  assert.equal((await setFlag('weather', { enabled: false, reason: 42 })).status, 400);
  assert.equal((await t.api('GET', '/features', null, rider.token)).json.flags.weather, true, 'nothing changed');
});

test('switch off: persisted, audited, pushed to connected apps, and a fresh cache agrees', async () => {
  const ws = await t.connect(rider.token);
  await ws.next((m) => m.type === 'HELLO');
  const res = await setFlag('placeReviews', { enabled: false, reason: 'Photo upload bug' });
  assert.equal(res.status, 200, JSON.stringify(res.json));
  assert.equal(res.json.flags.placeReviews, false);
  assert.equal(res.json.feature.lastChange.reason, 'Photo upload bug');
  const push = await ws.next((m) => m.type === 'FEATURE_FLAGS');
  assert.equal(push.flags.placeReviews, false);
  assert.ok(push.updatedAt > 0);
  ws.close();

  // Another node (or a restart): a new cache on the same database reads the same state.
  const other = new FeatureFlags({ soda: t.soda, logger: { warn() {} } });
  assert.equal(other.isOn('placeReviews'), true, 'defaults before the first read');
  await other.refresh();
  assert.equal(other.isOn('placeReviews'), false);

  // The audit log has the change.
  const audit = await gw.repo.listAuditEntries(20);
  const row = audit.find((a) => a.action === 'feature.off' && a.target === 'placeReviews');
  assert.ok(row, 'audited');
  assert.equal(row.by, 'ffadmin@coroute.test');
  assert.equal(row.details.reason, 'Photo upload bug');

  // History in the admin view.
  const view = await t.api('GET', '/admin/features', null, admin.token);
  assert.equal(view.json.history[0].id, 'placeReviews');
  assert.equal(view.json.features.find((x) => x.id === 'placeReviews').enabled, false);

  // A socket that connects while something is off is told at once.
  const late = await t.connect(rider.token);
  const caught = await late.next((m) => m.type === 'FEATURE_FLAGS');
  assert.equal(caught.flags.placeReviews, false);
  late.close();
});

test('REST enforcement: places and saved road reports answer 403 FEATURE_OFF; admin moderation stays', async () => {
  // placeReviews is off from the previous test.
  const g = await t.api('GET', '/places/reviews?placeId=osm:node:1', null, rider.token);
  assert.equal(g.status, 403);
  assert.equal(g.json.code, 'FEATURE_OFF');
  assert.equal(g.json.error, FEATURE_OFF_MESSAGE);
  const p = await t.api('POST', '/places/reviews', { placeId: 'osm:node:1', placeName: 'Cafe', category: 'food', lat: 17.1, lng: 78.1, rating: 5, text: 'Good' }, rider.token);
  assert.equal(p.status, 403);
  assert.equal((await t.api('GET', '/admin/place-reviews', null, admin.token)).status, 200, 'moderation still works');

  assert.notEqual((await t.api('GET', '/road-hazards/near?lat=17.1&lng=78.1', null, rider.token)).status, 403);
  assert.equal((await setFlag('roadHistory', { enabled: false, reason: 'Stale reports' })).status, 200);
  const near = await t.api('GET', '/road-hazards/near?lat=17.1&lng=78.1', null, rider.token);
  assert.equal(near.status, 403);
  assert.equal(near.json.code, 'FEATURE_OFF');

  // Back on: the guard lets requests through again.
  assert.equal((await setFlag('roadHistory', { enabled: true })).status, 200, 'no reason needed to switch on');
  assert.notEqual((await t.api('GET', '/road-hazards/near?lat=17.1&lng=78.1', null, rider.token)).status, 403);
  assert.equal((await setFlag('placeReviews', { enabled: true })).status, 200);
  assert.notEqual((await t.api('GET', '/places/reviews?placeId=osm:node:1', null, rider.token)).status, 403);
});

test('socket enforcement: ROAD_HAZARD, ROLE_AUTO and ROLE_SET LEAD get ERROR 403 FEATURE_OFF', async () => {
  const R = await groupRide();
  const wl = await t.joinRoom(R.lead.token, R.gid);
  assert.equal((await setFlag('roadHazards', { enabled: false, reason: 'False positives' })).status, 200);
  assert.equal((await setFlag('rideRoles', { enabled: false, reason: 'Role prompt loop' })).status, 200);
  await wl.next((m) => m.type === 'FEATURE_FLAGS' && m.flags.rideRoles === false);

  wl.sendJson({ type: 'ROAD_HAZARD', lat: 17.1, lng: 78.1, heading: 90, severity: 'HIGH' });
  const e1 = await wl.next((m) => m.type === 'ERROR');
  assert.equal(e1.code, 403);
  assert.equal(e1.reason, 'FEATURE_OFF');
  assert.equal(e1.message, FEATURE_OFF_MESSAGE);

  wl.sendJson({ type: 'ROLE_AUTO', on: true, clientId: 'ffauto1' });
  const e2 = await wl.next((m) => m.type === 'ERROR');
  assert.equal(e2.reason, 'FEATURE_OFF');
  assert.equal(e2.clientId, 'ffauto1', 'the outbox entry is answered (no endless resend)');
  assert.notEqual(gw.convoys.rooms.get(R.gid).meta.autoRoles, true);

  wl.sendJson({ type: 'ROLE_SET', userId: R.members[0].user.userId, role: 'LEAD', clientId: 'ffrole1' });
  assert.equal((await wl.next((m) => m.type === 'ERROR')).reason, 'FEATURE_OFF');

  // The socket itself is untouched by the refusals (safety lanes are never mapped to a switch).
  wl.sendJson({ type: 'PING' });
  await wl.next((m) => m.type === 'PONG');

  // Back on: ROLE_AUTO works again.
  assert.equal((await setFlag('rideRoles', { enabled: true })).status, 200);
  wl.sendJson({ type: 'ROLE_AUTO', on: true, clientId: 'ffauto2' });
  assert.equal((await wl.next((m) => m.type === 'AUTO_ROLES')).autoRoles, true);

  // autoRoles off alone: turning automatic roles on is refused, turning them off is allowed.
  assert.equal((await setFlag('autoRoles', { enabled: false, reason: 'Flicker' })).status, 200);
  wl.sendJson({ type: 'ROLE_AUTO', on: false, clientId: 'ffauto3' });
  assert.equal((await wl.next((m) => m.type === 'AUTO_ROLES' && m.autoRoles === false)).autoRoles, false);
  wl.sendJson({ type: 'ROLE_AUTO', on: true, clientId: 'ffauto4' });
  assert.equal((await wl.next((m) => m.type === 'ERROR')).reason, 'FEATURE_OFF');

  // Bike swap (its socket case is another 3.55 change): refused before it is dispatched.
  assert.equal((await setFlag('vehicleSwap', { enabled: false, reason: 'Swap stuck' })).status, 200);
  wl.sendJson({ type: 'SWAP_REQUEST', withUserId: R.members[0].user.userId, kind: 'BIKES', clientId: 'ffswap1' });
  const e3 = await wl.next((m) => m.type === 'ERROR');
  assert.equal(e3.reason, 'FEATURE_OFF');

  for (const id of ['autoRoles', 'roadHazards', 'vehicleSwap']) assert.equal((await setFlag(id, { enabled: true })).status, 200);
  wl.close();
});

test('website community numbers are hidden (not an error) while switched off', async () => {
  const on = await t.api('GET', '/public/usage-stats');
  assert.equal(on.status, 200);
  assert.notEqual(on.json.code, 'FEATURE_OFF');
  assert.equal((await setFlag('communityStatsWebsite', { enabled: false, reason: 'Numbers look wrong' })).status, 200);
  const off = await t.api('GET', '/public/usage-stats');
  assert.equal(off.status, 200);
  assert.equal(off.json.enabled, false);
  assert.equal(off.json.stats, null);
  const cs = await t.api('GET', '/public/community-stats');
  assert.equal(cs.json.enabled, false);
  assert.equal((await setFlag('communityStatsWebsite', { enabled: true })).status, 200);
  assert.notEqual((await t.api('GET', '/public/usage-stats')).json.code, 'FEATURE_OFF');
});
