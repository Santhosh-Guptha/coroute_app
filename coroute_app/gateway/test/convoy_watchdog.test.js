'use strict';
/**
 * Tests for Convoy Dynamics & Safety Watchdog:
 *  - REQ-11: Convoy Sub-Cluster Detection (Toll Splits)
 *  - REQ-12: Dynamic Rendezvous & Regroup Ahead Protocol
 *  - REQ-13: Sweeper Distress & Reverse-Escalation
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

const T0 = Date.UTC(2026, 9, 10, 6, 0, 0);
let t, gw, now = T0;

before(async () => {
  mock.timers.enable({ apis: ['Date'], now: T0 });
  t = await boot();
  gw = t.gw;
});

after(async () => {
  await gw.shutdown();
  mock.timers.reset();
});

const advance = (ms) => {
  now += ms;
  mock.timers.setTime(now);
};

let n = 0;
async function setupConvoy(body = {}) {
  n++;
  const lead = await t.register(`Lead ${n}`, `lead${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Convoy ${n}`, ...body }, lead.token)).json;
  const members = [];
  for (const tag of ['Sweeper', 'RiderA', 'RiderB', 'RiderC']) {
    n++;
    const u = await t.register(`${tag} ${n}`, `rider${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  const room = gw.convoys.rooms.get(c.groupId);
  // Set Sweeper role
  await gw.convoys.setRole(c.groupId, lead.user, members[0].user.userId, 'SWEEPER');
  return { lead, c, gid: c.groupId, room, members };
}

const uid = (u) => u.user.userId;
const events = async (gid, type) => (await gw.repo.listEvents(gid, { limit: 1000 })).filter((e) => e.type === type);

async function patchRiderFix(room, u, lat, lng, speedKmh = 60) {
  gw.convoys.patchRider(room, uid(u), { lat, lng, speedKmh }, { emit: false });
  await gw.timeline.idle();
}

test('REQ-11: Sub-cluster split at toll plaza emits CONVOY_SPLIT and suppresses SEPARATED spam', async () => {
  // Polyline along longitude 77.600 from lat 13.000 to 13.250 (~27.8 km)
  const waypoints = [
    { lat: 13.000, lng: 77.600 },
    { lat: 13.050, lng: 77.600 },
    { lat: 13.100, lng: 77.600 },
    { lat: 13.200, lng: 77.600 },
    { lat: 13.250, lng: 77.600 },
  ];
  const C = await setupConvoy({
    destinationLat: 13.250,
    destinationLng: 77.600,
    distanceThresholdMeters: 1000,
  });
  const room = C.room;
  room.meta.route = {
    distanceM: 27800,
    durationS: 1800,
    polyline: '_ajnA_gsxMowH?owH?_pR?owH?', // straight path along lat 13.000 to 13.250
    waypoints,
  };

  const [sweeper, riderA, riderB, riderC] = C.members;

  const wLead = await t.joinRoom(C.lead.token, C.gid);
  const splitFrames = [];
  wLead.on('message', (d, bin) => {
    if (!bin) {
      const msg = JSON.parse(d.toString());
      if (msg.type === 'CONVOY_SPLIT' || msg.type === 'CONVOY_SPLIT_RESOLVED') {
        splitFrames.push(msg);
      }
    }
  });

  // Lead and RiderA clear toll and are at lat 13.100 and 13.090 (~11 km and ~10 km)
  // Sweeper, RiderB, RiderC are held at toll at lat 13.050, 13.048, 13.045 (~5.5 km, ~5.3 km, ~5.0 km)
  // The gap between RiderA (13.090) and Sweeper (13.050) is ~4.4 km (> 1200 m threshold)
  await patchRiderFix(room, C.lead, 13.100, 77.600, 80);
  await patchRiderFix(room, riderA, 13.090, 77.600, 75);
  await patchRiderFix(room, sweeper, 13.050, 77.600, 5);
  await patchRiderFix(room, riderB, 13.048, 77.600, 0);
  await patchRiderFix(room, riderC, 13.045, 77.600, 0);

  // Trigger initial split check to establish st.splitSince
  advance(5000);
  await patchRiderFix(room, C.lead, 13.100, 77.600, 80);

  // Before 45 seconds hold time, split is not yet confirmed
  assert.equal(splitFrames.length, 0);

  // Advance time past 45s (50 seconds)
  advance(50000);
  await patchRiderFix(room, C.lead, 13.102, 77.600, 80);
  await patchRiderFix(room, riderA, 13.092, 77.600, 75);
  await patchRiderFix(room, sweeper, 13.050, 77.600, 5);
  await patchRiderFix(room, riderB, 13.048, 77.600, 0);
  await patchRiderFix(room, riderC, 13.045, 77.600, 0);

  await sleep(40);
  assert.ok(splitFrames.length >= 1, 'CONVOY_SPLIT event emitted');
  const splitEv = splitFrames[0];
  assert.equal(splitEv.type, 'CONVOY_SPLIT');
  assert.equal(splitEv.packs.length, 2);

  const leadPack = splitEv.packs.find((p) => p.packId === 'LEAD');
  const trailPack = splitEv.packs.find((p) => p.packId === 'TRAIL');
  assert.ok(leadPack, 'Lead pack present');
  assert.ok(trailPack, 'Trail pack present');
  assert.equal(leadPack.count, 2, 'Lead pack has 2 riders (Lead, RiderA)');
  assert.equal(trailPack.count, 3, 'Trail pack has 3 riders (Sweeper, RiderB, RiderC)');
  assert.ok(trailPack.gapMeters >= 4000, 'Gap is recorded above 4000m');

  // Verify SEPARATED alarms are suppressed
  await sleep(30);
  const sepEvents = await events(C.gid, 'SEPARATED');
  assert.equal(sepEvents.length, 0, 'Individual SEPARATED alarms suppressed during split');

  // Now trail pack catches up to lead pack (gap < 800m)
  advance(10000);
  await patchRiderFix(room, sweeper, 13.098, 77.600, 60);
  await patchRiderFix(room, riderB, 13.097, 77.600, 60);
  await patchRiderFix(room, riderC, 13.096, 77.600, 60);
  advance(5000);
  await patchRiderFix(room, C.lead, 13.102, 77.600, 80);

  await sleep(40);
  const resolved = splitFrames.find((f) => f.type === 'CONVOY_SPLIT_RESOLVED');
  assert.ok(resolved, 'CONVOY_SPLIT_RESOLVED emitted when regrouped');
});

test('REQ-12: Dynamic Rendezvous protocol with convergence tracking and timeout', async () => {
  const C = await setupConvoy();
  const [sweeper, riderA] = C.members;

  const wLead = await t.joinRoom(C.lead.token, C.gid);
  const wRiderA = await t.joinRoom(riderA.token, C.gid);
  const wSweeper = await t.joinRoom(sweeper.token, C.gid);

  const frames = [];
  wRiderA.on('message', (d, bin) => {
    if (!bin) frames.push(JSON.parse(d.toString()));
  });

  // Pack rider (non-lead, non-sweeper) cannot set regroup point (403)
  wRiderA.sendJson({
    type: 'REGROUP_SET',
    lat: 12.8234,
    lng: 77.9451,
    name: 'Shoolagiri Layby',
    clientId: 'rg-fail-1',
  });
  const err = await wRiderA.next((m) => m.type === 'ERROR' && m.clientId === 'rg-fail-1');
  assert.equal(err.code, 403);

  // Lead designates regroup point
  wLead.sendJson({
    type: 'REGROUP_SET',
    lat: 12.8234,
    lng: 77.9451,
    name: 'IndianOil COCO Shoolagiri Layby',
    targetAction: 'PULL_OVER_AND_WAIT',
    targetKmh: 40,
    clientId: 'rg-lead-1',
  });
  const ack = await wLead.next((m) => m.type === 'ACK' && m.clientId === 'rg-lead-1');
  assert.equal(ack.duplicate, false);

  const activeMsg = await wRiderA.next((m) => m.type === 'REGROUP_ACTIVE');
  assert.equal(activeMsg.regroup.name, 'IndianOil COCO Shoolagiri Layby');
  assert.equal(activeMsg.regroup.targetAction, 'PULL_OVER_AND_WAIT');
  assert.equal(C.room.meta.activeRegroup.name, 'IndianOil COCO Shoolagiri Layby');

  // Snapshot echoes activeRegroup
  const snap = C.room ? gw.convoys.snapshot(C.room) : null;
  assert.ok(snap && snap.activeRegroup, 'Snapshot contains activeRegroup');
  assert.equal(snap.activeRegroup.lat, 12.8234);

  // Convergence tracking: all riders move within 150m of regroup point (12.8234, 77.9451)
  advance(5000);
  await patchRiderFix(C.room, C.lead, 12.82345, 77.94512, 10);
  await patchRiderFix(C.room, sweeper, 12.82342, 77.94515, 5);
  await patchRiderFix(C.room, riderA, 12.82338, 77.94508, 0);
  for (const m of C.members.slice(2)) {
    await patchRiderFix(C.room, m, 12.82340, 77.94510, 0);
  }
  advance(5000);
  await patchRiderFix(C.room, C.lead, 12.82345, 77.94512, 10);

  await sleep(40);
  const completed = frames.find((f) => f.type === 'REGROUP_COMPLETED');
  assert.ok(completed, 'REGROUP_COMPLETED fired when all riders converged within 150m');
  assert.equal(C.room.meta.activeRegroup, undefined);

  // Test timeout expiration safeguard (25 min)
  wSweeper.sendJson({
    type: 'REGROUP_SET',
    lat: 12.9000,
    lng: 77.9000,
    name: 'Toll Exit Layby',
    clientId: 'rg-sweep-1',
  });
  await wSweeper.next((m) => m.type === 'ACK' && m.clientId === 'rg-sweep-1');
  assert.ok(C.room.meta.activeRegroup);

  // Advance past 25 minutes (26 min)
  advance(26 * 60000);
  await gw.timeline.tick();
  await sleep(40);
  assert.equal(C.room.meta.activeRegroup, undefined, 'Regroup point expired and cleared after 25 min');
});

test('REQ-13: Sweeper distress triggers when sweeper halts or drops offline while pack moves', async () => {
  const C = await setupConvoy();
  const [sweeper, riderA] = C.members;

  const wLead = await t.joinRoom(C.lead.token, C.gid);
  const distressFrames = [];
  wLead.on('message', (d, bin) => {
    if (!bin) {
      const msg = JSON.parse(d.toString());
      if (msg.type === 'SWEEPER_DISTRESS' || msg.type === 'SWEEPER_DISTRESS_RESOLVED') {
        distressFrames.push(msg);
      }
    }
  });

  // Lead and pack cruising at 70 km/h (> 35 km/h)
  // Sweeper halts (< 5 km/h) at lat 12.791, lng 77.912
  await patchRiderFix(C.room, C.lead, 12.820, 77.940, 70);
  await patchRiderFix(C.room, riderA, 12.815, 77.935, 70);
  await patchRiderFix(C.room, sweeper, 12.791, 77.912, 0); // halted

  // Under 90 seconds: no distress yet
  advance(60000); // 60s
  await patchRiderFix(C.room, C.lead, 12.830, 77.950, 70);
  await patchRiderFix(C.room, sweeper, 12.791, 77.912, 0);
  await sleep(20);
  assert.equal(distressFrames.length, 0, 'No distress under 90s');

  // Past 90 seconds (advance another 35s to total 95s)
  advance(35000);
  await patchRiderFix(C.room, C.lead, 12.840, 77.960, 70);
  await patchRiderFix(C.room, sweeper, 12.791, 77.912, 0);
  await sleep(40);

  assert.ok(distressFrames.length >= 1, 'SWEEPER_DISTRESS alert received');
  const alert = distressFrames[0];
  assert.equal(alert.type, 'SWEEPER_DISTRESS');
  assert.equal(alert.sweeperId, uid(sweeper));
  assert.equal(alert.status, 'HALTED_UNEXPECTEDLY');
  assert.ok(alert.distanceBehindLeadM > 2000, 'Distance behind lead recorded');
  assert.ok(alert.haltDurationSec >= 90, 'Halt duration recorded');

  // Sweeper resumes riding at 40 km/h: distress resolves
  advance(10000);
  await patchRiderFix(C.room, sweeper, 12.795, 77.915, 40);
  await sleep(40);

  const resolved = distressFrames.find((f) => f.type === 'SWEEPER_DISTRESS_RESOLVED');
  assert.ok(resolved, 'SWEEPER_DISTRESS_RESOLVED received when sweeper resumes');

  // Test Case B: Sweeper drops completely offline (> 90s without fix) while main pack is moving
  distressFrames.length = 0;
  advance(10000);
  // Main pack keeps sending fixes while sweeper sends nothing
  await patchRiderFix(C.room, C.lead, 12.860, 77.980, 75);
  advance(95000); // 95s without fix from sweeper
  await patchRiderFix(C.room, C.lead, 12.880, 78.000, 75);
  await gw.timeline.tick();
  await sleep(40);

  const offlineAlert = distressFrames.find((f) => f.type === 'SWEEPER_DISTRESS');
  assert.ok(offlineAlert, 'SWEEPER_DISTRESS triggered when sweeper drops offline for >90s');
  assert.equal(offlineAlert.status, 'DROPPED_OFFLINE');
});
