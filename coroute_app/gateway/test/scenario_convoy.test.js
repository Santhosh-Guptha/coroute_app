'use strict';
/**
 * Convoy dynamics and regroup scenario tests (REQ-11, REQ-12, REQ-13):
 * - REQ-11: Toll plaza convoy split, gap distance calculation, and suppression of alarm spam
 * - REQ-12: Dynamic rendezvous marker broadcast, convergence tracking, and completion within 150m
 * - REQ-13: Sweeper distress detection when sweeper stops while pack is riding, reverse-escalation alert to Lead
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.INCIDENT_STILL_S = '2';
process.env.INCIDENT_STOP_WITHIN_S = '15';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

const T0 = Date.UTC(2026, 9, 10, 8, 0, 0);
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
  const lead = await t.register(`Lead ${n}`, `dynlead${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', {
    name: `Convoy ${n}`,
    start: { lat: 17.0, lng: 78.0, name: 'Start Point' },
    destination: 'Highway Layby End',
    destLat: 17.3,
    destLng: 78.0,
    distanceThresholdMeters: 1000,
    ...body,
  }, lead.token)).json;

  const members = [];
  for (const tag of ['Scout', 'Priya', 'Sweeper']) {
    n++;
    const u = await t.register(`${tag} ${n}`, `dyn${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }

  await sleep(30);
  const room = gw.convoys.rooms.get(c.groupId);
  return { lead, c, gid: c.groupId, room, members };
}

const uid = (u) => u.user.userId;
const listEvents = async (gid, type) => (await gw.repo.listEvents(gid, { limit: 1000 })).filter((e) => !type || e.type === type);

async function setPosition(room, u, lat, lng, speedKmh = 60, extra = {}) {
  gw.convoys.patchRider(room, uid(u), { lat, lng, speedKmh, ...extra }, { emit: false });
  await gw.timeline.idle();
}

test('REQ-11: Toll plaza convoy split, gap distance calculation, and suppression of alarm spam', async () => {
  const C = await setupConvoy();
  const [scout, priya, sweeper] = C.members;
  await gw.convoys.setRole(C.gid, { userId: uid(C.lead), name: 'Lead' }, uid(sweeper), 'SWEEPER');

  // Start trip status so incident and separation rules evaluate
  C.room.meta.tripStatus = 'STARTED';

  // Lead pack clears toll plaza: Lead at lat 17.180, Scout at lat 17.175 (~550m apart)
  await setPosition(C.room, C.lead, 17.180, 78.0, 80);
  await setPosition(C.room, scout, 17.175, 78.0, 80);

  // Trail pack held up at toll queue: Priya at lat 17.100, Sweeper at lat 17.099 (~110m apart, speed 0)
  // With statusReason set to 'Toll queue'
  await setPosition(C.room, priya, 17.100, 78.0, 0, { statusReason: 'Toll queue', stoppedSince: now });
  await setPosition(C.room, sweeper, 17.099, 78.0, 0, { statusReason: 'Toll queue', stoppedSince: now });

  // 1. Check separation over 60s HOLD_MS period
  for (let i = 0; i < 7; i++) {
    advance(10000);
    await setPosition(C.room, C.lead, 17.180, 78.0, 80);
    await setPosition(C.room, scout, 17.175, 78.0, 80);
    await setPosition(C.room, priya, 17.100, 78.0, 0, { statusReason: 'Toll queue' });
    await setPosition(C.room, sweeper, 17.099, 78.0, 0, { statusReason: 'Toll queue' });
  }

  // Check SEPARATED events generated for trailing pack
  const separatedEvents = await listEvents(C.gid, 'SEPARATED');
  assert.ok(separatedEvents.length >= 1, 'Separation event opened for trailing pack');

  const priyaSeparated = separatedEvents.find((e) => e.userId === uid(priya));
  assert.ok(priyaSeparated, 'Priya flagged as separated from group centroid');
  assert.ok(priyaSeparated.open, 'Separation entry remains open while split');
  assert.ok(priyaSeparated.data.distanceM > 1000, `Distance ${priyaSeparated.data.distanceM} exceeds 1000m threshold`);

  // Subsequent telemetry fixes update maxDistanceM rather than spamming duplicate open entries
  const initialOpenCount = separatedEvents.filter((e) => e.open).length;
  for (let i = 0; i < 3; i++) {
    advance(10000);
    await setPosition(C.room, priya, 17.098, 78.0, 0, { statusReason: 'Toll queue' });
  }
  const updatedSeparated = await listEvents(C.gid, 'SEPARATED');
  const currentOpenCount = updatedSeparated.filter((e) => e.open).length;
  assert.equal(currentOpenCount, initialOpenCount, 'No duplicate open events created during ongoing split');

  // 2. Alarm spam suppression: stationary riders with statusReason do NOT trigger false incident alarms
  const incidentEvents = await listEvents(C.gid, 'POSSIBLE_INCIDENT');
  const tollIncidents = incidentEvents.filter((e) => e.userId === uid(priya) || e.userId === uid(sweeper));
  assert.equal(tollIncidents.length, 0, 'False incident alarms suppressed for riders stopped in toll cluster');

  await t.api('POST', `/convoys/${C.gid}/status`, { status: 'ENDED' }, C.lead.token);
});

test('REQ-12: Dynamic rendezvous marker broadcast, convergence tracking, and completion within 150m', async () => {
  const C = await setupConvoy();
  const [scout, priya, sweeper] = C.members;

  // Add a dynamic rendezvous meeting stop point at lat 17.200, lng 78.0
  const rendezvousLat = 17.200;
  const rendezvousLng = 78.0;
  const meetStopId = 'stop_rendezvous_1';

  C.room.meta.stopPoints = [
    {
      stopId: meetStopId,
      name: 'Highway Layby Rendezvous',
      lat: rendezvousLat,
      lng: rendezvousLng,
      category: 'MEETING',
      status: 'PLANNED',
      isVisited: false,
      arrivals: {},
    },
  ];

  // Stage 1: Lead and Scout arrive first within 150m reach radius and slow down
  // 17.200 is rendezvous; 17.2005 is ~55m away (<= 150m)
  advance(10000);
  await setPosition(C.room, C.lead, 17.2002, 78.0, 5); // ~22m away
  await setPosition(C.room, scout, 17.2004, 78.0, 5);  // ~44m away

  // Priya and Sweeper are still converging from afar (at lat 17.150, ~5.5 km away)
  await setPosition(C.room, priya, 17.150, 78.0, 70);
  await setPosition(C.room, sweeper, 17.148, 78.0, 70);

  // Lead has reached stop
  const leadReached = await listEvents(C.gid, 'STOP_REACHED');
  assert.ok(leadReached.some((e) => e.userId === uid(C.lead)), 'Lead reached event logged');

  // Stop is not fully visited yet because Priya and Sweeper have not arrived
  let stopDoc = C.room.meta.stopPoints.find((s) => s.stopId === meetStopId);
  assert.equal(stopDoc.isVisited, false, 'Stop is not marked visited while riders are still converging');

  // Stage 2: Trail pack converges and arrives within 150m
  advance(10000);
  await setPosition(C.room, priya, 17.1995, 78.0, 5);   // ~55m away (<= 150m)
  await setPosition(C.room, sweeper, 17.1992, 78.0, 5); // ~88m away (<= 150m)

  // Verify allReached completion triggered
  stopDoc = C.room.meta.stopPoints.find((s) => s.stopId === meetStopId);
  assert.equal(stopDoc.isVisited, true, 'Meeting stop completed and marked visited once all riders arrive within 150m');

  const allReached = await listEvents(C.gid, 'STOP_ALL_REACHED');
  assert.ok(allReached.length >= 1, 'STOP_ALL_REACHED event emitted to whole convoy');
  assert.equal(allReached[0].data.stopId, meetStopId);

  await t.api('POST', `/convoys/${C.gid}/status`, { status: 'ENDED' }, C.lead.token);
});

test('REQ-13: Sweeper distress detection when sweeper stops while pack is riding, reverse-escalation alert to Lead', async () => {
  const C = await setupConvoy();
  const [scout, priya, sweeper] = C.members;
  await gw.convoys.setRole(C.gid, { userId: uid(C.lead), name: 'Lead' }, uid(sweeper), 'SWEEPER');

  C.room.meta.tripStatus = 'STARTED';

  // Cruising phase: entire pack riding at 75 km/h
  advance(10000);
  await setPosition(C.room, C.lead, 17.20, 78.0, 75);
  await setPosition(C.room, scout, 17.19, 78.0, 75);
  await setPosition(C.room, priya, 17.18, 78.0, 75);
  await setPosition(C.room, sweeper, 17.15, 78.0, 75);

  // Sweeper distress: sudden deceleration from 75 km/h to 0 km/h (hard stop), while rest of pack rides on
  advance(3000);
  await setPosition(C.room, sweeper, 17.1501, 78.0, 0); // 0 km/h hard stop

  // Pack continues moving forward at 80 km/h away from sweeper
  await setPosition(C.room, C.lead, 17.22, 78.0, 80);
  await setPosition(C.room, scout, 17.21, 78.0, 80);
  await setPosition(C.room, priya, 17.20, 78.0, 80);

  // Advance time past incidentStillS (2s)
  advance(5000);
  await setPosition(C.room, sweeper, 17.1501, 78.0, 0);

  // Check POSSIBLE_INCIDENT generated for Sweeper
  const incidents = await listEvents(C.gid, 'POSSIBLE_INCIDENT');
  assert.ok(incidents.length >= 1, 'Possible incident opened for distressed sweeper');

  const sweeperIncident = incidents.find((e) => e.userId === uid(sweeper));
  assert.ok(sweeperIncident, 'Incident registered specifically for sweeper user ID');
  assert.equal(sweeperIncident.data.reason, 'HARD_STOP');

  // Reverse-escalation verification: notification list MUST include the Lead
  assert.ok(Array.isArray(sweeperIncident.data.notify), 'Incident contains notification target list');
  assert.ok(
    sweeperIncident.data.notify.includes(uid(C.lead)),
    'Reverse-escalation routes sweeper distress alert to Lead user ID',
  );

  // Pack member (Priya) is NOT in notification list (prevents moving pack panic)
  assert.ok(
    !sweeperIncident.data.notify.includes(uid(priya)),
    'Pack riders excluded from direct incident notification during high-speed transit',
  );

  await t.api('POST', `/convoys/${C.gid}/status`, { status: 'ENDED' }, C.lead.token);
});
