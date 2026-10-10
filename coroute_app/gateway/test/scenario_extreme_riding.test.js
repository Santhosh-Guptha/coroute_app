'use strict';
/**
 * Automated test suite covering extreme real-world riding scenarios (gateway side):
 * - Scenario B: High-Jitter Patchy Cellular Network (clientId deduplication, in-flight bursts)
 * - Scenario D: Highway Convoy Split (sweeper alerts & regrouping)
 * - Scenario E: Concurrent Multi-Incident Alarm (independent responder tracking & resolution)
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.WS_ALARMS_PER_10S = '30';

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

let counter = 0;
async function createRide(body = {}) {
  counter++;
  const lead = await t.register(`ScenarioLead ${counter}`, `scen_lead${counter}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `ScenarioRide ${counter}`, ...body }, lead.token)).json;
  const riders = [];
  for (const tag of ['RiderA', 'RiderB', 'Sweeper']) {
    counter++;
    const r = await t.register(`${tag} ${counter}`, `scen_${tag}${counter}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, r.token)).status, 200);
    riders.push(r);
  }
  await sleep(30);
  const room = gw.convoys.rooms.get(c.groupId);
  return { lead, c, gid: c.groupId, room, riders };
}

const uid = (u) => u.user.userId;
const events = async (gid, type) => (await gw.repo.listEvents(gid, { limit: 1000 })).filter((e) => e.type === type);

async function fix(room, u, lat, lng, speedKmh = 50) {
  gw.convoys.patchRider(room, uid(u), { lat, lng, speedKmh }, { emit: false });
  await gw.timeline.idle();
}

test('Scenario B Gateway: High-Jitter packet bursts and in-flight duplicate SOS messages applied once', async () => {
  const R = await createRide();
  const [riderA] = R.riders;
  const wl = await t.joinRoom(R.lead.token, R.gid);
  const wa = await t.joinRoom(riderA.token, R.gid);

  // Simultaneous packet burst: Client sends the exact same SOS message 3 times in one network tick
  const clientId = `sos_burst_${counter}`;
  wa.sendJson({ type: 'SOS', lat: 12.9716, lng: 77.5946, alertType: 'CRASH', auto: true, clientId });
  wa.sendJson({ type: 'SOS', lat: 12.9716, lng: 77.5946, alertType: 'CRASH', auto: true, clientId });
  wa.sendJson({ type: 'SOS', lat: 12.9716, lng: 77.5946, alertType: 'CRASH', auto: true, clientId });

  // Exactly one alert reaches the lead / convoy room
  const first = await wl.next((m) => m.type === 'ALERT');
  assert.equal(first.alert.clientId, clientId);
  assert.equal(first.alert.auto, true);

  await sleep(100);
  assert.equal(
    wl.inbox.filter((m) => m.type === 'ALERT').length,
    0,
    'Convoy room must not receive duplicate alerts from cellular packet bursts'
  );

  // The sender gets echoes: first confirmation + duplicate echoes
  const senderEchoes = wa.inbox.filter((m) => m.type === 'ALERT' && m.alert.clientId === clientId);
  assert.ok(senderEchoes.length >= 1);
  const duplicates = wa.inbox.filter((m) => m.type === 'ALERT' && m.duplicate === true);
  assert.ok(duplicates.length >= 1, 'Burst repeats are safely flagged as duplicates');

  wl.close();
  wa.close();
});

test('Scenario D Gateway: Highway Convoy Split triggers BEHIND_SWEEPER alert and clears upon regrouping', async () => {
  const R = await createRide({
    start: { lat: 17.0, lng: 78.0, name: 'Start' },
    destination: 'End',
    destLat: 17.2,
    destLng: 78.0,
  });
  const [riderA, riderB, sw] = R.riders;

  // Designate sweeper role
  await gw.convoys.setRole(R.gid, { userId: uid(R.lead), name: 'Lead', role: 'RIDER' }, uid(sw), 'SWEEPER');

  // Lead at 17.120, Sweeper at 17.100, RiderA at 17.098 (200m behind sweeper), RiderB at 17.095 (555m behind sweeper)
  // First 5 ticks (50s): held for 60s
  for (let i = 0; i < 5; i++) {
    advance(10000);
    await fix(R.room, R.lead, 17.12, 78.0);
    await fix(R.room, sw, 17.100, 78.0);
    await fix(R.room, riderA, 17.098, 78.0);
    await fix(R.room, riderB, 17.095, 78.0);
  }
  let behind = await events(R.gid, 'BEHIND_SWEEPER');
  assert.equal(behind.length, 0, 'No alert before 60s hold time expires');

  // Next 3 ticks (total 80s > 60s threshold): BEHIND_SWEEPER opens for RiderB
  for (let i = 0; i < 3; i++) {
    advance(10000);
    await fix(R.room, R.lead, 17.12, 78.0);
    await fix(R.room, sw, 17.100, 78.0);
    await fix(R.room, riderA, 17.098, 78.0);
    await fix(R.room, riderB, 17.095, 78.0);
  }

  behind = await events(R.gid, 'BEHIND_SWEEPER');
  assert.equal(behind.length, 1, 'BEHIND_SWEEPER opened for RiderB (555m behind sweeper)');
  assert.equal(behind[0].userId, uid(riderB));
  assert.equal(behind[0].open, true);
  assert.equal(behind[0].data.sweeperId, uid(sw));

  // Regrouping: RiderB accelerates and passes the sweeper (moves ahead to 17.101)
  for (let i = 0; i < 2; i++) {
    advance(10000);
    await fix(R.room, sw, 17.100, 78.0);
    await fix(R.room, riderB, 17.101, 78.0);
  }

  behind = await events(R.gid, 'BEHIND_SWEEPER');
  assert.equal(behind[0].open, false, 'BEHIND_SWEEPER closes once rider passes sweeper');
});

test('Scenario E Gateway: Concurrent Multi-Incident Alarms track responders independently and resolve cleanly', async () => {
  const R = await createRide();
  const [riderA, riderB, sw] = R.riders;
  const wl = await t.joinRoom(R.lead.token, R.gid);
  const wa = await t.joinRoom(riderA.token, R.gid);
  const wb = await t.joinRoom(riderB.token, R.gid);
  const wsw = await t.joinRoom(sw.token, R.gid);

  // 1. Rider A triggers manual SOS
  wa.sendJson({ type: 'SOS', lat: 12.95, lng: 77.55, alertType: 'EMERGENCY', clientId: `sos_a_${counter}` });
  const alertAEvent = await wl.next((m) => m.type === 'ALERT');
  const alertIdA = alertAEvent.alert.alertId;

  // 2. Rider B triggers automatic crash alarm simultaneously
  wb.sendJson({
    type: 'SOS',
    lat: 12.98,
    lng: 77.58,
    alertType: 'CRASH',
    auto: true,
    speedBeforeKmh: 68,
    impactG: 7.2,
    clientId: `sos_b_${counter}`,
  });
  const alertBEvent = await wl.next((m) => m.type === 'ALERT');
  const alertIdB = alertBEvent.alert.alertId;

  assert.notEqual(alertIdA, alertIdB, 'Each concurrent incident gets its own unique alertId');

  // Verify both alerts are open simultaneously in room state
  assert.equal(R.room.alerts.size, 2);
  assert.equal(R.room.alerts.get(alertIdA).resolved, false);
  assert.equal(R.room.alerts.get(alertIdB).resolved, false);

  // 3. Independent responder tracking:
  // Lead responds to Alert A: "GOING"
  wl.sendJson({ type: 'SOS_RESPOND', alertId: alertIdA, kind: 'GOING', clientId: `resp_a_${counter}` });
  const respAEcho = await wl.next((m) => m.type === 'ACK');
  assert.equal(respAEcho.duplicate, false);

  // Sweeper responds to Alert B: "WITH_THEM"
  wsw.sendJson({ type: 'SOS_RESPOND', alertId: alertIdB, kind: 'WITH_THEM', clientId: `resp_b_${counter}` });
  const respBEcho = await wsw.next((m) => m.type === 'ACK');
  assert.equal(respBEcho.duplicate, false);

  // Verify responders map is partitioned by alertId
  const alertADoc = R.room.alerts.get(alertIdA);
  const alertBDoc = R.room.alerts.get(alertIdB);
  assert.equal(alertADoc.responders[uid(R.lead)]?.kind, 'GOING');
  assert.equal(alertADoc.responders[uid(sw)], undefined);
  assert.equal(alertBDoc.responders[uid(sw)]?.kind, 'WITH_THEM');
  assert.equal(alertBDoc.responders[uid(R.lead)], undefined);

  // 4. Independent resolution:
  // Rider A resolves their manual SOS (e.g. false alarm / assistance reached)
  wa.sendJson({ type: 'SOS_RESOLVE', alertId: alertIdA, reason: 'RESOLVED' });
  const resolvedA = await wl.next((m) => m.type === 'ALERT_RESOLVED');
  assert.equal(resolvedA.alertId, alertIdA);

  // Alert A is resolved, Alert B remains OPEN and active
  assert.equal(R.room.alerts.get(alertIdA).resolved, true);
  assert.equal(R.room.alerts.get(alertIdB).resolved, false, 'Alert B must remain active when Alert A resolves');

  // Sweeper remains actively assigned as responder to Alert B
  assert.equal(R.room.alerts.get(alertIdB).responders[uid(sw)]?.kind, 'WITH_THEM');

  // 5. Finally Alert B is resolved
  wb.sendJson({ type: 'SOS_RESOLVE', alertId: alertIdB, reason: 'RESOLVED' });
  const resolvedB = await wl.next((m) => m.type === 'ALERT_RESOLVED');
  assert.equal(resolvedB.alertId, alertIdB);
  assert.equal(R.room.alerts.get(alertIdB).resolved, true);

  wl.close();
  wa.close();
  wb.close();
  wsw.close();
});
