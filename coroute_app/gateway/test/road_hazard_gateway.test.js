'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const test = require('node:test');
const assert = require('node:assert/strict');
const { RoadHazardRegistry, haversineM, angleDiff } = require('../src/road_hazards');

test('RoadHazardRegistry: 100m spatial deduplication merges close observations', () => {
  const registry = new RoadHazardRegistry({ deduplicationRadiusM: 100.0 });

  // Lead rider reports pothole at (12.9716, 77.5946)
  const obs1 = {
    hazardId: 'rh_001',
    userId: 'rider_1',
    lat: 12.9716,
    lng: 77.5946,
    heading: 90.0,
    severity: 'HIGH',
    classification: 'POTHOLE',
    confidence: 0.85,
    timestamp: 1000,
  };

  const res1 = registry.ingestObservation(obs1);
  assert.equal(res1.isNew, true);
  assert.equal(res1.pin.corroborationCount, 1);
  assert.equal(res1.pin.severity, 'HIGH');

  // Second observation 35 meters away along same road heading from a second rider
  // At lat 12.9716, 1 deg lon is ~108.5 km => 35m is ~0.00032 deg lon
  const obs2 = {
    hazardId: 'rh_002',
    userId: 'rider_2',
    lat: 12.9716,
    lng: 77.59492,
    heading: 90.0,
    severity: 'CRITICAL',
    classification: 'POTHOLE',
    confidence: 0.90,
    timestamp: 2000,
  };

  const res2 = registry.ingestObservation(obs2);
  assert.equal(res2.isNew, false); // Merged into existing pin!
  assert.equal(res2.pin.hazardId, 'rh_001');
  assert.equal(res2.pin.corroborationCount, 2);
  assert.equal(res2.pin.severity, 'CRITICAL'); // Escalate to higher severity
  assert.ok(res2.pin.confidence >= 0.95);
});

test('RoadHazardRegistry: repeated report from SAME rider does NOT inflate corroboration', () => {
  const registry = new RoadHazardRegistry({ deduplicationRadiusM: 100.0 });

  const obs1 = {
    hazardId: 'rh_lead_01',
    userId: 'rider_captain',
    lat: 12.9716,
    lng: 77.5946,
    heading: 90.0,
    severity: 'HIGH',
  };
  const res1 = registry.ingestObservation(obs1);
  assert.equal(res1.pin.corroborationCount, 1);

  // Same rider reports again 20 meters away (e.g. circling back or secondary sensor jolt)
  const obsRepeat = {
    hazardId: 'rh_lead_02',
    userId: 'rider_captain', // Same user!
    lat: 12.9716,
    lng: 77.59478, // 20m away
    heading: 90.0,
    severity: 'HIGH',
  };
  const resRepeat = registry.ingestObservation(obsRepeat);
  assert.equal(resRepeat.isNew, false);
  assert.equal(resRepeat.pin.corroborationCount, 1, 'Same rider must not inflate corroboration count');
});

test('RoadHazardRegistry: duplicate eventId returns duplicate: true idempotently', () => {
  const registry = new RoadHazardRegistry();
  const obs = {
    hazardId: 'rh_exact_id_123',
    userId: 'rider_1',
    lat: 12.9716,
    lng: 77.5946,
    heading: 90.0,
  };
  const res1 = registry.ingestObservation(obs);
  assert.equal(res1.isNew, true);
  assert.equal(res1.duplicate, false);

  // Resend identical frame (network retry)
  const resRetry = registry.ingestObservation(obs);
  assert.equal(resRetry.isNew, false);
  assert.equal(resRetry.duplicate, true);
  assert.equal(resRetry.pin.corroborationCount, 1);
});

test('RoadHazardRegistry: 99m vs 101m spatial boundary threshold test', () => {
  const registry = new RoadHazardRegistry({ deduplicationRadiusM: 100.0 });
  // Base pin
  registry.ingestObservation({
    hazardId: 'rh_base',
    lat: 12.971600,
    lng: 77.594600,
    heading: 90.0,
  });

  // At lat 12.9716, 1 deg lon is ~108540m
  // 99m is ~0.000912 deg
  // 101m is ~0.000931 deg
  const obs99m = {
    hazardId: 'rh_99m',
    userId: 'rider_2',
    lat: 12.971600,
    lng: 77.594600 + (99.0 / 108540.0),
    heading: 90.0,
  };
  const res99 = registry.ingestObservation(obs99m);
  assert.equal(res99.isNew, false, '99m observation should merge into base pin');
  assert.equal(res99.pin.hazardId, 'rh_base');

  const obs101m = {
    hazardId: 'rh_101m',
    userId: 'rider_3',
    lat: 12.971600,
    lng: 77.594600 + (101.5 / 108540.0),
    heading: 90.0,
  };
  const res101 = registry.ingestObservation(obs101m);
  assert.equal(res101.isNew, true, '101m observation must create a separate pin');
  assert.equal(res101.pin.hazardId, 'rh_101m');
  assert.equal(registry.pins.size, 2);
});

test('RoadHazardRegistry: opposite carriageway is not merged despite proximity', () => {
  const registry = new RoadHazardRegistry({ deduplicationRadiusM: 100.0, directionToleranceDeg: 60.0 });

  // Hazard on eastbound carriageway (heading 90 deg)
  const obsEast = {
    hazardId: 'rh_east',
    lat: 12.9716,
    lng: 77.5946,
    heading: 90.0,
    severity: 'HIGH',
    classification: 'POTHOLE',
  };

  const resEast = registry.ingestObservation(obsEast);
  assert.equal(resEast.isNew, true);

  // Hazard 20 meters away on westbound carriageway (heading 270 deg)
  const obsWest = {
    hazardId: 'rh_west',
    lat: 12.9717,
    lng: 77.5946,
    heading: 270.0,
    severity: 'MEDIUM',
    classification: 'POTHOLE',
  };

  const resWest = registry.ingestObservation(obsWest);
  assert.equal(resWest.isNew, true); // Distinct pin because heading difference is 180 deg!
  assert.notEqual(resWest.pin.hazardId, resEast.pin.hazardId);
});

test('RoadHazardRegistry: distinct hazards > 100m apart create separate pins', () => {
  const registry = new RoadHazardRegistry({ deduplicationRadiusM: 100.0 });

  // Hazard 1
  const obs1 = {
    hazardId: 'rh_km10',
    lat: 12.9716,
    lng: 77.5946,
    heading: 90.0,
  };
  const res1 = registry.ingestObservation(obs1);
  assert.equal(res1.isNew, true);

  // Hazard 2: 250 meters away
  const obs2 = {
    hazardId: 'rh_km10_25',
    lat: 12.9716,
    lng: 77.5970,
    heading: 90.0,
  };
  const res2 = registry.ingestObservation(obs2);
  assert.equal(res2.isNew, true);
  assert.equal(registry.pins.size, 2);
});

test('RoadHazardRegistry: filterEligibleRecipients excludes passed and opposite riders', () => {
  const registry = new RoadHazardRegistry();
  const pin = {
    hazardId: 'rh_target',
    lat: 12.9716,
    lng: 77.5946,
    heading: 90.0, // Moving East
  };

  const riders = [
    // Rider 1: 300m West of hazard, moving East (heading 90) -> UPSTREAM, ON ROUTE!
    {
      userId: 'rider_trailing',
      lat: 12.9716,
      lng: 77.5918,
      heading: 90.0,
    },
    // Rider 2: 150m East of hazard, moving East (heading 90) -> ALREADY PASSED!
    {
      userId: 'rider_passed',
      lat: 12.9716,
      lng: 77.5960,
      heading: 90.0,
    },
    // Rider 3: 300m West of hazard, moving West (heading 270) -> OPPOSITE CARRIAGEWAY!
    {
      userId: 'rider_opposite',
      lat: 12.9716,
      lng: 77.5918,
      heading: 270.0,
    },
  ];

  const eligible = registry.filterEligibleRecipients(pin, riders);
  const eligibleIds = eligible.map(e => e.userId);

  assert.ok(eligibleIds.includes('rider_trailing'), 'Trailing rider should be eligible');
  assert.ok(!eligibleIds.includes('rider_passed'), 'Passed rider should be excluded');
  assert.ok(!eligibleIds.includes('rider_opposite'), 'Opposite carriageway rider should be excluded');
  assert.equal(eligible.length, 1);
});

const WebSocket = require('ws');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

test('WebSocket Security: ROAD_HAZARD publisher entitlement enforcement and invalid input rejection', async () => {
  const soda = new MemorySoda();
  const gw = await createApp({ soda, logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const { port } = gw.server.address();
  const base = `http://127.0.0.1:${port}/api`;
  const wsBase = `ws://127.0.0.1:${port}/ws`;

  async function api(method, path, body, token) {
    const res = await fetch(base + path, {
      method,
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: res.status, json: await res.json().catch(() => ({})) };
  }

  function connectWs(token) {
    return new Promise((resolve) => {
      const ws = new WebSocket(`${wsBase}?token=${token}`);
      ws.inbox = [];
      ws.waiters = [];
      ws.on('message', (data) => {
        const item = JSON.parse(data.toString());
        const w = ws.waiters.findIndex((wt) => wt.pred(item));
        if (w >= 0) ws.waiters.splice(w, 1)[0].resolve(item); else ws.inbox.push(item);
      });
      ws.next = (pred, timeout = 3000) => new Promise((res, rej) => {
        const i = ws.inbox.findIndex(pred);
        if (i >= 0) return res(ws.inbox.splice(i, 1)[0]);
        const t = setTimeout(() => rej(new Error('timeout waiting for message')), timeout);
        ws.waiters.push({ pred, resolve: (v) => { clearTimeout(t); res(v); } });
      });
      ws.on('open', () => resolve(ws));
    });
  }

  try {
    // 1. Register Lead (Captain) and Follower
    const leadReg = await api('POST', '/auth/register', {
      name: 'Lead Captain', email: 'captain@coroute.test', password: 'Password#123',
      phone: '9999999991', vehicleType: 'Motorcycle', vehicleNo: 'TS09AB0001',
      emergencyContact: '+919000000001', emergencyContactName: 'Contact 1',
    });
    const followReg = await api('POST', '/auth/register', {
      name: 'Follower Pro', email: 'follower@coroute.test', password: 'Password#123',
      phone: '9999999992', vehicleType: 'Motorcycle', vehicleNo: 'TS09AB0002',
      emergencyContact: '+919000000002', emergencyContactName: 'Contact 2',
    });

    // 2. Create convoy by Lead
    const convoyRes = await api('POST', '/convoys', { name: 'Safety Test Convoy' }, leadReg.json.token);
    const groupId = convoyRes.json.groupId;
    const joinCode = convoyRes.json.joinCode;

    // Follower joins convoy
    await api('POST', '/convoys/join', { code: joinCode }, followReg.json.token);

    // 3. Connect WebSockets
    const leadWs = await connectWs(leadReg.json.token);
    const followWs = await connectWs(followReg.json.token);

    // Join room
    leadWs.send(JSON.stringify({ type: 'JOIN', groupId }));
    await leadWs.next((m) => m.type === 'SNAPSHOT');
    followWs.send(JSON.stringify({ type: 'JOIN', groupId }));
    await followWs.next((m) => m.type === 'SNAPSHOT');

    // 4. Follower (not Road Captain / not Lead) attempts to broadcast ROAD_HAZARD
    // Must be rejected with structured error code 403 / ENTITLEMENT_REQUIRED
    followWs.send(JSON.stringify({
      type: 'ROAD_HAZARD',
      lat: 12.9716,
      lng: 77.5946,
      heading: 90.0,
      severity: 'HIGH',
    }));
    const errFollower = await followWs.next((m) => m.type === 'ERROR');
    assert.equal(errFollower.code, 403);
    assert.equal(errFollower.reason, 'ENTITLEMENT_REQUIRED');

    // 5. Lead Captain sends invalid coordinates (lat = 999.0)
    leadWs.send(JSON.stringify({
      type: 'ROAD_HAZARD',
      lat: 999.0,
      lng: 77.5946,
    }));
    const errCoords = await leadWs.next((m) => m.type === 'ERROR');
    assert.equal(errCoords.code, 400);

    // 6. Lead Captain publishes valid hazard frame
    leadWs.send(JSON.stringify({
      type: 'ROAD_HAZARD',
      hazardId: 'rh_captain_live',
      lat: 12.9716,
      lng: 77.5946,
      heading: 90.0,
      severity: 'CRITICAL',
    }));
    const ack = await leadWs.next((m) => m.type === 'ROAD_HAZARD_ACK');
    assert.equal(ack.hazardId, 'rh_captain_live');
    assert.equal(ack.isNew, true);

    leadWs.close();
    followWs.close();
  } finally {
    await gw.shutdown();
  }
});
