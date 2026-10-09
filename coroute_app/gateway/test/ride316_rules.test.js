'use strict';
/**
 * 3.16 server-side ride rules: stale rider (STALE_UPDATE), low battery (LOW_BATTERY) and the lower
 * speed limit near stops and in towns (OVERSPEED with data.context). Fixes go through
 * ConvoyManager.patchRider (the TELEMETRY path) with a mocked clock; the timeline tick is called by hand.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.STALE_MIN_S = '2';
process.env.STALE_FACTOR = '3';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

const T0 = Date.UTC(2026, 9, 9, 4, 0, 0);
const quiet = { info() {}, warn() {}, error() {} };
let gw;
let t = T0;
let seq = 0;

before(async () => {
  mock.timers.enable({ apis: ['Date'], now: T0 });
  gw = await createApp({ soda: new MemorySoda(), logger: quiet });
});
after(async () => { if (gw) await gw.shutdown(); mock.timers.reset(); });

function advance(ms) { t += ms; mock.timers.setTime(t); }

async function rider(tag) {
  seq++;
  const r = await gw.auth.register({ name: `${tag} ${seq}`, email: `${tag.toLowerCase()}${seq}@coroute.test`, password: 'Password#123', phone: '9999999999' });
  return { userId: r.user.userId, name: `${tag} ${seq}`, role: 'RIDER' };
}

async function ride(opts = {}) {
  const lead = await rider('Lead');
  const snap = await gw.convoys.createConvoy(lead, { name: 'Rules ride', ...opts });
  const room = await gw.convoys.getRoom(snap.groupId);
  const members = [];
  for (let i = 0; i < (opts.riders || 0); i++) {
    const u = await rider('Rider');
    await gw.convoys.joinByCode(u, snap.joinCode);
    members.push(u);
  }
  return { lead, snap, room, gid: snap.groupId, members };
}

async function fix(room, u, patch) {
  gw.convoys.patchRider(room, u.userId, { lat: 17.0, lng: 78.0, speedKmh: 50, ...patch }, { emit: false });
  await gw.timeline.idle();
}
const events = async (gid, type) => (await gw.repo.listEvents(gid, { limit: 1000 })).filter((e) => e.type === type);
async function tick() { await gw.timeline.tick(); await gw.timeline.idle(); }

test('STALE_UPDATE: 3x the typical gap, moving riders only, closed by the next fix, replaced by OFFLINE', async () => {
  const R = await ride({ riders: 3 });
  const [a, b, parked] = R.members;
  // Everybody sends every 10 s for a minute: the group's typical gap is 10 s (threshold 30 s).
  let lat = 17.0;
  for (let i = 0; i < 6; i++) {
    advance(10000); lat += 0.001;
    await fix(R.room, R.lead, { lat, speedKmh: 50 });
    await fix(R.room, a, { lat, speedKmh: 50 });
    await fix(R.room, b, { lat, speedKmh: 50 });
    await fix(R.room, parked, { lat: 17.0, speedKmh: 0 });
  }
  await tick();
  assert.equal((await events(R.gid, 'STALE_UPDATE')).length, 0);

  // b and the parked rider go quiet; a and the lead keep sending. After 25 s nothing yet (threshold 30).
  for (let i = 0; i < 2; i++) { advance(12500); lat += 0.001; await fix(R.room, R.lead, { lat }); await fix(R.room, a, { lat }); }
  await tick();
  assert.equal((await events(R.gid, 'STALE_UPDATE')).length, 0, 'under the threshold');
  advance(10000); lat += 0.001; await fix(R.room, R.lead, { lat }); await fix(R.room, a, { lat });
  await tick();
  let stale = await events(R.gid, 'STALE_UPDATE');
  assert.equal(stale.length, 1, 'one stale entry');
  assert.equal(stale[0].userId, b.userId, 'the moving rider, not the parked one');
  assert.equal(stale[0].open, true);
  assert.equal(stale[0].data.typicalS, 10);
  assert.ok(stale[0].data.gapS >= 30, `gap ${stale[0].data.gapS}`);
  assert.deepEqual(stale[0].data.notify, [R.lead.userId], 'the lead is told');
  assert.equal(stale[0].startedAt, R.room.riders.get(b.userId).lastSeenEpochMs, 'starts at the last fix');
  // Idempotent while open.
  advance(10000); await tick();
  assert.equal((await events(R.gid, 'STALE_UPDATE')).length, 1);

  // b sends again: closed with RESUMED.
  await fix(R.room, b, { lat });
  stale = await events(R.gid, 'STALE_UPDATE');
  assert.equal(stale[0].open, false);
  assert.equal(stale[0].data.result, 'RESUMED');

  // b goes quiet for good: STALE opens, then OFFLINE (5 min) replaces it.
  advance(40000); lat += 0.001; await fix(R.room, R.lead, { lat }); await fix(R.room, a, { lat });
  await tick();
  stale = await events(R.gid, 'STALE_UPDATE');
  assert.equal(stale.length, 2);
  assert.equal(stale[1].open, true);
  advance(5 * 60000); lat += 0.001; await fix(R.room, R.lead, { lat }); await fix(R.room, a, { lat });
  await tick();
  stale = await events(R.gid, 'STALE_UPDATE');
  assert.equal(stale[1].open, false);
  assert.equal(stale[1].data.result, 'OFFLINE');
  assert.equal((await events(R.gid, 'OFFLINE')).filter((e) => e.userId === b.userId).length, 1);
  assert.equal((await events(R.gid, 'STALE_UPDATE')).filter((e) => e.userId === parked.userId).length, 0, 'the parked rider went offline without ever being stale');

  // a closes the app cleanly: OFFLINE at once, never STALE.
  gw.convoys.setPresence(R.gid, a.userId, 'APP_CLOSED');
  await gw.timeline.idle();
  advance(60000); lat += 0.001; await fix(R.room, R.lead, { lat });
  await tick();
  assert.equal((await events(R.gid, 'STALE_UPDATE')).filter((e) => e.userId === a.userId).length, 0, 'APP_CLOSED is never stale');
  await gw.convoys.setTripStatus(R.gid, 'ENDED');
  await gw.timeline.idle();
});

test('LOW_BATTERY: opens at 15 not charging, level updates every 5, closes at 25 or charging; lead and sweeper told', async () => {
  const R = await ride({ riders: 2 });
  const [sweeper, kiran] = R.members;
  await gw.convoys.setRole(R.gid, R.lead, sweeper.userId, 'SWEEPER');
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 16 });
  assert.equal((await events(R.gid, 'LOW_BATTERY')).length, 0, '16% is not low');
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 15, isCharging: true });
  assert.equal((await events(R.gid, 'LOW_BATTERY')).length, 0, 'charging phones are fine');
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 14, isCharging: false });
  let low = await events(R.gid, 'LOW_BATTERY');
  assert.equal(low.length, 1);
  assert.equal(low[0].userId, kiran.userId);
  assert.equal(low[0].data.level, 14);
  assert.deepEqual(low[0].data.notify, [R.lead.userId, sweeper.userId]);
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 11 });
  low = await events(R.gid, 'LOW_BATTERY');
  assert.equal(low[0].data.level, 14, 'a drop of 3 is not pushed');
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 9 });
  low = await events(R.gid, 'LOW_BATTERY');
  assert.equal(low[0].data.level, 9, 'a drop of 5 updates the level');
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 9, isCharging: true });
  low = await events(R.gid, 'LOW_BATTERY');
  assert.equal(low[0].open, false);
  assert.equal(low[0].data.result, 'CHARGING');
  // Unplugged again at 12, then charged to 25: RECOVERED.
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 12, isCharging: false });
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 20, isCharging: false });
  low = await events(R.gid, 'LOW_BATTERY');
  assert.equal(low.length, 2);
  assert.equal(low[1].open, true, '20 is still under the recovery level');
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 25, isCharging: false });
  low = await events(R.gid, 'LOW_BATTERY');
  assert.equal(low[1].open, false);
  assert.equal(low[1].data.result, 'RECOVERED');
  // Leaving closes an open one.
  advance(1000);
  await fix(R.room, kiran, { batteryLevel: 10 });
  await gw.convoys.leave(R.gid, kiran.userId);
  await gw.timeline.idle();
  low = await events(R.gid, 'LOW_BATTERY');
  assert.equal(low[2].open, false);
  await gw.convoys.setTripStatus(R.gid, 'ENDED');
  await gw.timeline.idle();
});

test('OVERSPEED by context: town limit within 1 km of a stop, the start or the destination; group limit elsewhere', async () => {
  const R = await ride({
    riders: 3, speedLimitKmh: 80, destination: 'End', destLat: 17.2, destLng: 78.0,
    start: { lat: 17.0, lng: 78.0, name: 'Start' },
    stops: [{ name: 'Fuel', lat: 17.1, lng: 78.0, category: 'FUEL' }],
  });
  await gw.convoys.updateConfig(R.gid, R.lead, { townLimitKmh: 40 });
  assert.equal(R.room.meta.townLimitKmh, 40);
  const [a, b, c] = R.members;
  const over = async (u) => (await events(R.gid, 'OVERSPEED')).filter((e) => e.userId === u.userId);
  // a: 55 km/h 500 m from the fuel stop for 20 s: over the town limit of 40.
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, a, { lat: 17.1045, lng: 78.0, speedKmh: 55 }); }
  let list = await over(a);
  assert.equal(list.length, 1);
  assert.equal(list[0].data.limitKmh, 40);
  assert.equal(list[0].data.context, 'TOWN');
  // b: 55 km/h on the open road (5 km from everything): under the group limit, nothing.
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, b, { lat: 17.15, lng: 78.0, speedKmh: 55 }); }
  assert.equal((await over(b)).length, 0);
  // b: 95 km/h on the open road: group limit, context GROUP.
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, b, { lat: 17.15, lng: 78.0, speedKmh: 95 }); }
  list = await over(b);
  assert.equal(list.length, 1);
  assert.equal(list[0].data.limitKmh, 80);
  assert.equal(list[0].data.context, 'GROUP');
  // c near the destination at 50: town again. Then the group limit is switched off: the town limit alone still applies.
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, c, { lat: 17.195, lng: 78.0, speedKmh: 50 }); }
  list = await over(c);
  assert.equal(list.length, 1);
  assert.equal(list[0].data.context, 'TOWN');
  await gw.convoys.updateConfig(R.gid, R.lead, { speedLimitKmh: 0 });
  const d = await rider('Rider');
  await gw.convoys.joinByCode(d, R.snap.joinCode);
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, d, { lat: 17.004, lng: 78.0, speedKmh: 50 }); }
  list = await over(d);
  assert.equal(list.length, 1, 'town limit alone, near the start');
  assert.equal(list[0].data.limitKmh, 40);
  assert.equal(list[0].data.context, 'TOWN');
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, b, { lat: 17.15, lng: 78.0, speedKmh: 120 }); }
  assert.equal((await over(b)).length, 1, 'no group limit: nothing new on the open road');
  await gw.convoys.setTripStatus(R.gid, 'ENDED');
  await gw.timeline.idle();
});

test('CONFIG townLimitKmh: lead only, clamped to 20..100 or off, echoed in CONFIG and the snapshot', async () => {
  const R = await ride({ riders: 1 });
  const pack = R.members[0];
  await assert.rejects(gw.convoys.updateConfig(R.gid, pack, { townLimitKmh: 40 }), (e) => e.status === 403);
  const configs = [];
  const on = (gid, p) => { if (p.type === 'CONFIG') configs.push(p); };
  gw.convoys.on('event', on);
  await gw.convoys.updateConfig(R.gid, R.lead, { townLimitKmh: 500 });
  assert.equal(R.room.meta.townLimitKmh, 100);
  assert.equal(configs.at(-1).townLimitKmh, 100);
  await gw.convoys.updateConfig(R.gid, R.lead, { townLimitKmh: 5 });
  assert.equal(R.room.meta.townLimitKmh, 20);
  await gw.convoys.updateConfig(R.gid, R.lead, { townLimitKmh: 'abc' });
  assert.equal(R.room.meta.townLimitKmh, 0, 'rubbish reads as off');
  await gw.convoys.updateConfig(R.gid, R.lead, { townLimitKmh: 40 });
  await gw.convoys.updateConfig(R.gid, R.lead, { townLimitKmh: true });
  assert.equal(R.room.meta.townLimitKmh, 40, 'a boolean is ignored');
  await gw.convoys.updateConfig(R.gid, R.lead, { speedLimitKmh: 60 });
  assert.equal(configs.at(-1).townLimitKmh, 40, 'always echoed');
  assert.equal((await gw.convoys.getSnapshot(R.gid)).townLimitKmh, 40);
  gw.convoys.off('event', on);
  await gw.convoys.setTripStatus(R.gid, 'ENDED');
  await gw.timeline.idle();
});
