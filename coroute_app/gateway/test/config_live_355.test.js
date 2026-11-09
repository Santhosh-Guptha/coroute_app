'use strict';
/**
 * 3.55 fix: group settings changed mid-ride take effect at once, for everyone.
 *  - CONFIG carries every group setting (one CONFIG brings a rider fully up to date).
 *  - The timeline rules read the ride's settings live: a new separation distance, stop time or
 *    speed limit applies to the very next fixes (no per-room copy taken at ride start).
 *  - Only the owner / lead may change them; a refused change emits nothing and changes nothing.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

const T0 = Date.UTC(2026, 10, 9, 5, 0, 0);
let gw, now = T0, n = 0;
before(async () => {
  mock.timers.enable({ apis: ['Date'], now: T0 });
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
});
after(async () => { if (gw) await gw.shutdown(); mock.timers.reset(); });

async function user(name) {
  n++;
  const r = await gw.auth.register({ name: `${name} ${n}`, email: `cfg${n}@coroute.test`, password: 'Password#123', phone: '9999999999' });
  return { userId: r.user.userId, name, role: 'RIDER' };
}
async function ride(body = {}) {
  const lead = await user('Lead');
  const rider = await user('Rider');
  const snap = await gw.convoys.createConvoy(lead, { name: `Cfg ${n}`, ...body });
  await gw.convoys.joinByCode(rider, snap.joinCode);
  const room = await gw.convoys.getRoom(snap.groupId);
  return { lead, rider, gid: snap.groupId, room };
}
function captureConfig(gid) {
  const got = [];
  const on = (g, ev) => { if (g === gid && ev.type === 'CONFIG') got.push(ev); };
  gw.convoys.on('event', on);
  return { got, stop: () => gw.convoys.off('event', on) };
}
const step = (ms) => { now += ms; mock.timers.setTime(now); };
async function fix(room, u, lat, lng, speedKmh) {
  gw.convoys.patchRider(room, u.userId, { lat, lng, speedKmh }, { emit: false });
  await gw.timeline.idle();
}
const events = async (gid, type) => (await gw.repo.listEvents(gid, { limit: 500 })).filter((e) => e.type === type);

test('CONFIG carries every group setting, with the values the snapshot has', async () => {
  const R = await ride();
  const cap = captureConfig(R.gid);
  await gw.convoys.updateConfig(R.gid, R.lead, {
    distanceThresholdMeters: 2500, stopThresholdSeconds: 300, voiceGuidanceEnabled: false,
    speedLimitKmh: 90, townLimitKmh: 40, featurePolicy: { stretchAlertKm: 5 },
    visibility: 'PUBLIC', discovery: true, assistDefault: false,
  });
  cap.stop();
  assert.equal(cap.got.length, 1, 'one CONFIG per change');
  const cfg = cap.got[0];
  for (const key of ['distanceThresholdMeters', 'stopThresholdSeconds', 'voiceGuidanceEnabled', 'speedLimitKmh',
    'townLimitKmh', 'featurePolicy', 'visibility', 'discovery', 'assistDefault', 'publicRide', 'capacity',
    'capacityPlan', 'soloRide', 'autoRoles']) {
    assert.ok(key in cfg, `CONFIG has ${key}`);
  }
  assert.equal(cfg.distanceThresholdMeters, 2500);
  assert.equal(cfg.stopThresholdSeconds, 300);
  assert.equal(cfg.voiceGuidanceEnabled, false);
  assert.equal(cfg.speedLimitKmh, 90);
  assert.equal(cfg.townLimitKmh, 40);
  assert.equal(cfg.featurePolicy.stretchAlertKm, 5, 'the stretch alert distance rides in featurePolicy');
  assert.equal(cfg.visibility, 'PUBLIC');
  assert.equal(cfg.discovery, true);
  assert.equal(cfg.assistDefault, false);
  assert.equal(cfg.autoRoles, false);

  // Every setting key the snapshot has is in CONFIG with the same value (no field only a reload brings).
  const snap = gw.convoys.snapshot(R.room);
  for (const key of ['distanceThresholdMeters', 'stopThresholdSeconds', 'voiceGuidanceEnabled', 'speedLimitKmh',
    'townLimitKmh', 'visibility', 'discovery', 'assistDefault', 'capacity', 'soloRide', 'autoRoles']) {
    assert.deepEqual(cfg[key], snap[key], `CONFIG.${key} matches the snapshot`);
  }
  assert.deepEqual(cfg.featurePolicy, snap.featurePolicy);

  // Automatic roles switched on: the next CONFIG says so too.
  await gw.convoys.setAutoRoles(R.gid, R.lead, true);
  const cap2 = captureConfig(R.gid);
  await gw.convoys.updateConfig(R.gid, R.lead, { speedLimitKmh: 80 });
  cap2.stop();
  assert.equal(cap2.got[0].autoRoles, true);
});

test('a non-lead change is refused: nothing changes, no CONFIG goes out', async () => {
  const R = await ride({ speedLimitKmh: 80 });
  const cap = captureConfig(R.gid);
  await assert.rejects(gw.convoys.updateConfig(R.gid, R.rider, { speedLimitKmh: 120, distanceThresholdMeters: 9000 }), (e) => e.status === 403);
  cap.stop();
  assert.equal(cap.got.length, 0);
  assert.equal(R.room.meta.speedLimitKmh, 80);
  assert.equal(R.room.meta.distanceThresholdMeters ?? 1000, 1000);

  // The trip head the owner picked may change them (owner decision: settings are the trip head's only extra power).
  R.room.meta.tripHeadUserId = R.rider.userId;
  await gw.convoys.updateConfig(R.gid, R.rider, { speedLimitKmh: 60 });
  assert.equal(R.room.meta.speedLimitKmh, 60);
  // ... but nothing else of the lead's: no pause, no riding roles, no automatic roles.
  assert.equal(gw.convoys.canChangeSettings(R.room, R.rider), true);
  assert.equal(gw.convoys.isLead(R.room, R.rider), R.room.riders.get(R.rider.userId).role === 'LEAD');
  assert.equal(gw.convoys.canManage(R.room, R.rider), false);
  await assert.rejects(gw.convoys.setAutoRoles(R.gid, R.rider, true), (e) => e.status === 403);
});

test('speed limit lowered mid-ride: the next fixes are judged against the new limit', async () => {
  const R = await ride({ speedLimitKmh: 100 });
  let lat = 17.0;
  const go = async (kmh, secs = 5) => { step(secs * 1000); lat += 0.0003; await fix(R.room, R.rider, lat, 78.0, kmh); };
  for (let i = 0; i < 6; i++) await go(90);
  assert.equal((await events(R.gid, 'OVERSPEED')).length, 0, '90 is under 100');

  await gw.convoys.updateConfig(R.gid, R.lead, { speedLimitKmh: 80 });
  for (let i = 0; i < 3; i++) await go(90);
  const over = await events(R.gid, 'OVERSPEED');
  assert.equal(over.length, 1, 'the new limit applied without restarting the ride');
  assert.equal(over[0].data.limitKmh, 80);
  assert.equal(over[0].open, true);

  // Raised again: riding at 90 is fine now and the episode closes after the clear time.
  await gw.convoys.updateConfig(R.gid, R.lead, { speedLimitKmh: 120 });
  for (let i = 0; i < 6; i++) await go(90);
  assert.equal((await events(R.gid, 'OVERSPEED')).filter((e) => e.open).length, 0);
});

test('separation distance changed mid-ride: SEPARATED follows the new distance', async () => {
  const R = await ride();
  await gw.convoys.updateConfig(R.gid, R.lead, { distanceThresholdMeters: 5000 });
  // 2 km apart (about 0.018 deg of latitude), both moving, for 2 minutes: within 5 km, no entry.
  const both = async () => {
    step(5000);
    await fix(R.room, R.lead, 17.0, 78.0, 40);
    await fix(R.room, R.rider, 17.018, 78.0, 40);
  };
  for (let i = 0; i < 24; i++) await both();
  assert.equal((await events(R.gid, 'SEPARATED')).length, 0, '2 km is within 5 km');

  // The lead lowers it to 1 km: the same 2 km gap becomes a separation after the usual hold.
  await gw.convoys.updateConfig(R.gid, R.lead, { distanceThresholdMeters: 1000 });
  for (let i = 0; i < 14; i++) await both();
  const sep = await events(R.gid, 'SEPARATED');
  assert.ok(sep.length >= 1, 'the new distance applied without restarting the ride');
  assert.equal(sep[0].data.limitM, 1000);
});

test('stop time changed mid-ride: a rider already standing still is judged by the new time', async () => {
  const R = await ride();
  await gw.convoys.updateConfig(R.gid, R.lead, { stopThresholdSeconds: 600 });
  for (let i = 0; i < 24; i++) { step(5000); await fix(R.room, R.rider, 17.5, 78.5, 0); }
  assert.equal((await events(R.gid, 'STOPPED')).length, 0, '2 min still is under 10 min');

  await gw.convoys.updateConfig(R.gid, R.lead, { stopThresholdSeconds: 60 });
  step(5000); await fix(R.room, R.rider, 17.5, 78.5, 0);
  const stopped = await events(R.gid, 'STOPPED');
  assert.equal(stopped.length, 1, 'the shorter stop time applied at the next fix');
  assert.equal(stopped[0].userId, R.rider.userId);
});
