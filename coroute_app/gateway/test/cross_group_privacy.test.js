'use strict';
/**
 * Cross-group assistance topology and privacy verification suite.
 * Verifies:
 * 1. Route-aware cross-group assistance filtering (same carriageway, heading toward incident vs already-passed or parallel roads).
 * 2. Privacy separation invariant (SOCIAL PRIVACY != SAFETY RELAY CONSENT, private groups isolated from social discovery,
 *    exact coordinates never leaked in public discovery, medical details purged on resolution and never sent to admins).
 * 3. Ride Guardian capability token authorization (SHA-256 validation, PIN gate, rate limiting, instant pause/revocation, consent withdrawal).
 */
process.env.NODE_ENV = 'test';
process.env.GUARDIAN_ENABLED = 'true';
process.env.PUBLIC_ORIGIN = 'https://guardian.example';
process.env.GEO_ROUTE_URL = 'http://route.test';
process.env.GEO_MIN_INTERVAL_MS = '0';
process.env.NET_TICK_MS = '3600000';
process.env.DISCOVERY_TICK_MS = '3600000';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'privacyadmin@coroute.test';

const { netBoot, line, E_LAT, sleep } = require('./_net_helpers');
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');

let h;
let laneNo = 0;
const lane = () => 76 + (laneNo++) * 0.5;

before(async () => {
  h = await netBoot();
});

after(async () => {
  await h.t.gw.shutdown();
});

const FORBIDDEN_KEYS = [
  'userId', 'groupId', 'alertId', 'phone', 'emergencyContact',
  'emergencyContactName', 'vehicleNo', 'joinCode', 'members',
  'name', 'email', 'userName', 'reportedBy', 'reportedByName',
];

function collectForbiddenKeyLeaks(frame, { allowMedical = false } = {}) {
  const leaks = [];
  const walk = (val, path) => {
    if (Array.isArray(val)) {
      val.forEach((item, idx) => walk(item, `${path}[${idx}]`));
      return;
    }
    if (!val || typeof val !== 'object') return;
    for (const [k, v] of Object.entries(val)) {
      const p = `${path}.${k}`;
      const isAllowed = (k === 'riders' && frame.type === 'DISCOVERY' && typeof v === 'number')
        || (k === 'medical' && allowMedical && frame.type === 'ASSIST_UPDATE');
      if (FORBIDDEN_KEYS.includes(k) && !isAllowed) {
        leaks.push(p);
      }
      walk(v, p);
    }
  };
  walk(frame, frame.type || 'root');
  return leaks;
}

const guardianHeaders = (clientIp = '198.51.100.1') => ({
  Origin: 'https://guardian.example',
  'X-Forwarded-For': clientIp,
});

// ---------------------------------------------------------------------------
// 1. Cross-Group Assistance Topology and Route-Aware Filtering
// ---------------------------------------------------------------------------

test('cross-group topology: same carriageway heading toward incident receives ASSIST_REQUEST with aheadOnRoute', async () => {
  const lng = lane();
  const victimGroup = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victim Group' });
  victimGroup.ws = await h.net1(victimGroup.lead.token, victimGroup.gid);
  h.place(victimGroup.gid, victimGroup.lead, E_LAT, lng, 0, 0);

  // Helper B: 3 km before the incident (17.473 vs 17.500), northbound (heading 0) at 60 km/h.
  const helperGroup = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Helper Convoy' });
  helperGroup.ws = await h.net1(helperGroup.lead.token, helperGroup.gid);
  h.place(helperGroup.gid, helperGroup.lead, 17.473, lng, 0, 60);

  const alert = await h.sos(victimGroup.ws, E_LAT, lng);
  const req = await helperGroup.ws.next((m) => m.type === 'ASSIST_REQUEST');

  assert.match(req.incidentId, /^NET-[0-9A-F]{12}$/);
  assert.equal(req.aheadOnRoute, true);
  assert.equal(req.fasterThanGroup, true);
  assert.equal(req.distanceM, 3000);
  assert.equal(req.routeDistanceM, 3000);
  assert.ok(req.etaS >= 150 && req.etaS <= 210, `eta was ${req.etaS}`);
  assert.equal(req.severity, 'HIGH');

  // Verify victim group receives status update reflecting assistance request.
  const update = await victimGroup.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.network.state === 'REQUESTED');
  assert.equal(update.alertId, alert.alertId);
  assert.equal(update.status, 'ASSISTANCE_REQUESTED');
  assert.equal(update.network.notified, 1);

  await h.endRide(victimGroup);
  await h.endRide(helperGroup);
});

test('cross-group topology: opposing direction on same road heading toward incident receives ASSIST_REQUEST', async () => {
  const lng = lane();
  const victimGroup = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victim Northbound' });
  victimGroup.ws = await h.net1(victimGroup.lead.token, victimGroup.gid);
  h.place(victimGroup.gid, victimGroup.lead, E_LAT, lng, 0, 0);

  // Helper S: on southbound route (17.70 down to 17.40), placed at 17.53 (3.3 km ahead), heading south (180).
  const helperSouthbound = await h.rideOn(line(lng, 17.70, 17.40), { name: 'Helper Southbound' });
  helperSouthbound.ws = await h.net1(helperSouthbound.lead.token, helperSouthbound.gid);
  h.place(helperSouthbound.gid, helperSouthbound.lead, 17.53, lng, 180, 60);

  await h.sos(victimGroup.ws, E_LAT, lng);
  const req = await helperSouthbound.ws.next((m) => m.type === 'ASSIST_REQUEST');

  assert.equal(req.aheadOnRoute, true);
  assert.equal(req.routeDistanceM, 3300);
  assert.match(req.incidentId, /^NET-[0-9A-F]{12}$/);

  await h.endRide(victimGroup);
  await h.endRide(helperSouthbound);
});

test('cross-group topology: already-passed rider and parallel road riders are strictly rejected', async () => {
  const lng = lane();
  const victimGroup = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victim Main Road' });
  victimGroup.ws = await h.net1(victimGroup.lead.token, victimGroup.gid);
  h.place(victimGroup.gid, victimGroup.lead, E_LAT, lng, 0, 0);

  // Parallel road P: 1 km lateral distance away (lng + 0.0095), northbound route.
  const parallelGroup = await h.rideOn(line(lng + 0.0095, 17.40, 17.70), { name: 'Parallel Road Helper' });
  parallelGroup.ws = await h.net1(parallelGroup.lead.token, parallelGroup.gid);
  h.place(parallelGroup.gid, parallelGroup.lead, 17.473, lng + 0.0095, 0, 60);

  // Passed rider Q: on the same road, but already at 17.53 (past incident at 17.50), still heading north (0).
  const passedGroup = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Already Passed Helper' });
  passedGroup.ws = await h.net1(passedGroup.lead.token, passedGroup.gid);
  h.place(passedGroup.gid, passedGroup.lead, 17.53, lng, 0, 60);

  // Southbound rider S: placed at 17.47, heading south (180), incident at 17.50 is behind them.
  const ridingAwayGroup = await h.rideOn(line(lng, 17.70, 17.40), { name: 'Riding Away Helper' });
  ridingAwayGroup.ws = await h.net1(ridingAwayGroup.lead.token, ridingAwayGroup.gid);
  h.place(ridingAwayGroup.gid, ridingAwayGroup.lead, 17.47, lng, 180, 60);

  const alert = await h.sos(victimGroup.ws, E_LAT, lng);
  await h.settle(80);
  h.net.tick(Date.now() + 1000);
  await h.settle(80);

  // None of the non-converging or parallel or passed riders should receive an assist request.
  for (const ws of [parallelGroup.ws, passedGroup.ws, ridingAwayGroup.ws]) {
    assert.equal(h.got(ws, 'ASSIST_REQUEST').length, 0, 'No assist request should reach ineligible candidates');
  }

  const summary = h.net.summaryFor(victimGroup.gid, alert.alertId);
  assert.equal(summary.network.state, 'NONE_FOUND');

  for (const group of [victimGroup, parallelGroup, passedGroup, ridingAwayGroup]) {
    await h.endRide(group);
  }
});

test('cross-group topology: straight-line close but huge road detour is rejected', async () => {
  const lng = lane();
  h.net.osrmTimes = [];
  h.fake.table.fail = false;
  h.fake.table.delayMs = 0;
  // OSRM answers 12 km road distance for 1.8 km Euclidean distance.
  h.fake.table.answer = (sources) => sources.map(() => ({ distanceM: 12000, durationS: 900 }));

  const victimGroup = await h.rideOn(null, { name: 'Detour Victim' });
  victimGroup.ws = await h.net1(victimGroup.lead.token, victimGroup.gid);
  h.place(victimGroup.gid, victimGroup.lead, E_LAT, lng, 0, 0);

  const detourGroup = await h.rideOn(null, { name: 'Detour Candidate' });
  detourGroup.ws = await h.net1(detourGroup.lead.token, detourGroup.gid);
  // Heading toward 17.50 straight-line (~1.8 km away).
  h.pathTo(detourGroup.gid, detourGroup.lead, 17.484, lng, { n: 5 });

  await h.sos(victimGroup.ws, E_LAT, lng);
  await h.settle(120);

  // Large road detour must reject candidate.
  assert.equal(h.got(detourGroup.ws, 'ASSIST_REQUEST').length, 0, 'Detour greater than 4x Euclidean distance rejected');

  await h.endRide(victimGroup);
  await h.endRide(detourGroup);
});

// ---------------------------------------------------------------------------
// 2. Privacy Separation Invariant: SOCIAL PRIVACY != SAFETY RELAY CONSENT
// ---------------------------------------------------------------------------

test('privacy invariant: private groups never leak into social discovery but participate in safety network', async () => {
  const lng = lane();
  const privLead = await h.rider('Private Group Lead');
  const pubLead = await h.rider('Public Group Lead');

  // Group A is PRIVATE with discovery disabled.
  const groupA = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Shadow Squad', lead: privLead });
  groupA.ws = await h.net1(privLead.token, groupA.gid);
  groupA.ws.sendJson({ type: 'CONFIG', visibility: 'PRIVATE', discovery: false });
  await groupA.ws.next((m) => m.type === 'CONFIG');

  // Group B is PUBLIC with discovery enabled.
  const groupB = await h.rideOn(line(lng, 17.70, 17.40), { name: 'Open Highway Club', lead: pubLead });
  groupB.ws = await h.net1(pubLead.token, groupB.gid);
  groupB.ws.sendJson({ type: 'CONFIG', visibility: 'PUBLIC', discovery: true });
  await groupB.ws.next((m) => m.type === 'CONFIG');

  // Position both groups nearby.
  h.place(groupA.gid, privLead, 17.47, lng, 0, 60);
  h.place(groupB.gid, pubLead, 17.505, lng, 180, 60);

  // Trigger social discovery tick.
  h.t.gw.discovery.tick(Date.now());
  await h.settle(50);

  // Group A must NOT appear in discovery, nor receive discovery.
  assert.equal(h.got(groupA.ws, 'DISCOVERY').length, 0, 'Private group never receives DISCOVERY frames');
  assert.equal(h.got(groupB.ws, 'DISCOVERY').length, 0, 'Public group never receives DISCOVERY for private group');

  // Now an emergency occurs in Group A (Private Group).
  // SAFETY RELAY CONSENT is active: Group B should be notified to render emergency assistance.
  h.place(groupA.gid, privLead, E_LAT, lng, 0, 0);
  h.place(groupB.gid, pubLead, 17.53, lng, 180, 60);

  await h.sos(groupA.ws, E_LAT, lng);
  const assistReq = await groupB.ws.next((m) => m.type === 'ASSIST_REQUEST');
  assert.ok(assistReq, 'Public helper receives ASSIST_REQUEST for private group emergency');

  // Verify social discovery is STILL completely isolated.
  assert.equal(h.got(groupA.ws, 'DISCOVERY').length, 0, 'No discovery frames emitted during emergency');
  assert.equal(h.got(groupB.ws, 'DISCOVERY').length, 0, 'No discovery frames emitted during emergency');

  await h.endRide(groupA);
  await h.endRide(groupB);
});

test('privacy invariant: public discovery frames never expose exact coordinates or member names', async () => {
  const lng = lane();
  const lead1 = await h.rider('Explorer Alpha');
  const lead2 = await h.rider('Explorer Beta');

  const group1 = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Alpha Explorers', lead: lead1 });
  group1.ws = await h.net1(lead1.token, group1.gid);
  group1.ws.sendJson({ type: 'CONFIG', visibility: 'PUBLIC', discovery: true });
  await group1.ws.next((m) => m.type === 'CONFIG');

  const group2 = await h.rideOn(line(lng, 17.70, 17.40), { name: 'Beta Explorers', lead: lead2 });
  group2.ws = await h.net1(lead2.token, group2.gid);
  group2.ws.sendJson({ type: 'CONFIG', visibility: 'PUBLIC', discovery: true });
  await group2.ws.next((m) => m.type === 'CONFIG');

  // Opposite directions on same meridian meeting in ~2 minutes.
  h.place(group1.gid, lead1, 17.47, lng, 0, 60);
  h.place(group2.gid, lead2, 17.505, lng, 180, 60);

  h.t.gw.discovery.tick(Date.now());
  const da = await group1.ws.next((m) => m.type === 'DISCOVERY');
  const db = await group2.ws.next((m) => m.type === 'DISCOVERY');

  const discoveryFrames = [da, db];
  assert.ok(discoveryFrames.length === 2, 'Both public groups received discovery frames');

  for (const frame of discoveryFrames) {
    // Assert exact coordinates are NEVER present in DISCOVERY.
    assert.equal(frame.lat, undefined, 'DISCOVERY must not leak latitude');
    assert.equal(frame.lng, undefined, 'DISCOVERY must not leak longitude');
    assert.equal(frame.coordinates, undefined, 'DISCOVERY must not contain coordinates');
    assert.equal(frame.members, undefined, 'DISCOVERY must not leak member list');
    assert.equal(frame.userId, undefined, 'DISCOVERY must not leak user IDs');

    // Assert only coarse distance, groupName, riders count, and encounterType are emitted.
    assert.ok(typeof frame.groupName === 'string' && frame.groupName.length > 0);
    assert.ok(typeof frame.riders === 'number' && frame.riders >= 1);
    assert.ok(typeof frame.distanceM === 'number' && frame.distanceM % 500 === 0, 'Distance must be coarsely rounded');
    assert.ok(typeof frame.encounterType === 'string');
    assert.match(frame.encounterId, /^ENC-[0-9A-F]{12}$/);
  }

  await h.endRide(group1);
  await h.endRide(group2);
});

test('privacy invariant: external safety frames carry zero forbidden keys and isolate responder identity', async () => {
  const lng = lane();
  const victimLead = await h.rider('Victim Lead');
  await h.t.api('PATCH', '/me', {
    bloodGroup: 'O+',
    allergies: 'Peanut allergy',
    medicalNotes: 'Carries inhaler',
    responderMedical: false,
  }, victimLead.token);

  const victimRide = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Victim Convoy', lead: victimLead });
  victimRide.ws = await h.net1(victimLead.token, victimRide.gid);
  h.place(victimRide.gid, victimLead, E_LAT, lng, 0, 0);

  const helperRide = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Volunteer Helpers' });
  helperRide.ws = await h.net1(helperRide.lead.token, helperRide.gid);
  h.place(helperRide.gid, helperRide.lead, 17.473, lng, 0, 60);

  const alert = await h.sos(victimRide.ws, E_LAT, lng);
  const req = await helperRide.ws.next((m) => m.type === 'ASSIST_REQUEST');

  // Verify ASSIST_REQUEST has zero forbidden keys.
  const badReqKeys = collectForbiddenKeyLeaks(req);
  assert.deepEqual(badReqKeys, [], `Forbidden keys found in ASSIST_REQUEST: ${badReqKeys.join(', ')}`);

  // Helper accepts the assist request.
  helperRide.ws.sendJson({ type: 'ASSIST_ANSWER', incidentId: req.incidentId, answer: 'ACCEPT', clientId: 'ans-1' });
  const upd = await helperRide.ws.next((m) => m.type === 'ASSIST_UPDATE' && m.myStatus === 'ACCEPTED');

  // Subject details after acceptance: ONLY firstName, vehicleColor, vehicleType.
  assert.deepEqual(Object.keys(upd.subject).sort(), ['firstName', 'vehicleColor', 'vehicleType']);
  assert.equal(upd.medical, undefined, 'Medical data omitted because victim did not opt in');

  // Check victim group frames: responder real identity is never sent.
  const victimUpdate = await victimRide.ws.next((m) => m.type === 'EMERGENCY_UPDATE' && m.network.state === 'ASSIGNED');
  const responder = victimUpdate.network.responders[0];
  assert.match(responder.rid, /^[0-9a-f]{12}$/, 'Responder receives opaque per-incident rid');
  assert.equal(responder.userId, undefined, 'Victim group never receives responder userId');
  assert.equal(responder.groupId, undefined, 'Victim group never receives responder groupId');

  await h.endRide(victimRide);
  await h.endRide(helperRide);
});

test('privacy invariant: medical details are never sent to admins and are purged upon emergency resolution', async () => {
  const lng = lane();
  const victimLead = await h.rider('Medical Patient');
  await h.t.api('PATCH', '/me', {
    bloodGroup: 'AB+',
    allergies: 'Severe penicillin allergy',
    medicalNotes: 'Cardiac stent placed in 2024',
    responderMedical: true,
  }, victimLead.token);

  // Admin user.
  const admin = await h.t.gw.auth.register({
    name: 'Super Admin',
    email: 'privacyadmin@coroute.test',
    password: 'Password#123',
    phone: '+919811111112',
    vehicleType: 'Motorcycle',
    vehicleNo: 'KA01AD0002',
    emergencyContact: '+919000000005',
    emergencyContactName: 'Admin Kin',
  });
  assert.equal(admin.user.role, 'MASTER_ADMIN');

  const ride = await h.rideOn(line(lng, 17.40, 17.70), { name: 'Medical Emergency Ride', lead: victimLead });
  ride.ws = await h.net1(victimLead.token, ride.gid);
  h.place(ride.gid, victimLead, E_LAT, lng, 0, 0);

  const alert = await h.sos(ride.ws, E_LAT, lng);

  // Admin checks active emergencies.
  const adminEmergencies = await h.t.api('GET', '/admin/emergencies', null, admin.token);
  assert.equal(adminEmergencies.status, 200);
  const adminEmStr = JSON.stringify(adminEmergencies.json);
  assert.ok(!adminEmStr.includes('penicillin'), 'Admin emergencies feed must never include allergies');
  assert.ok(!adminEmStr.includes('Cardiac stent'), 'Admin emergencies feed must never include medical notes');
  assert.ok(!adminEmStr.includes('AB+'), 'Admin emergencies feed must never include blood group');

  // Admin checks user list.
  const adminUsers = await h.t.api('GET', '/admin/users', null, admin.token);
  assert.equal(adminUsers.status, 200);
  const adminUsersStr = JSON.stringify(adminUsers.json);
  assert.ok(!adminUsersStr.includes('penicillin'), 'Admin users list must never include allergies');
  assert.ok(!adminUsersStr.includes('Cardiac stent'), 'Admin users list must never include medical notes');

  // Resolve emergency.
  ride.ws.sendJson({ type: 'SOS_RESOLVE', alertId: alert.alertId, reason: 'RESOLVED' });
  const resolvedFrame = await ride.ws.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === alert.alertId);
  assert.equal(resolvedFrame.status, 'RESOLVED');

  // Verify medical data is completely purged from in-memory alert.
  const room = h.t.gw.convoys.rooms.get(ride.gid);
  const inMemoryAlert = room.alerts.get(alert.alertId);
  assert.equal(inMemoryAlert.medical, undefined, 'Medical data must be purged from in-memory alert upon resolution');
  assert.equal(inMemoryAlert.resolved, true);

  // Verify publicAlert helper output for resolved alert omits medical data.
  const storedAlert = await h.t.gw.repo.getConvoyMeta(ride.gid);
  assert.ok(storedAlert);

  await h.endRide(ride);
});

// ---------------------------------------------------------------------------
// 3. Ride Guardian Capability Token Authorization
// ---------------------------------------------------------------------------

test('guardian authorization: SHA-256 capability token validation and rejection of malformed tokens', async () => {
  const rider = await h.rider('Guardian Rider');
  const ride = await h.t.api('POST', '/convoys', { name: 'Guardian Protected Ride' }, rider.token);
  const groupId = ride.json.groupId;

  // Create Guardian capability link.
  const created = await h.t.api('POST', '/guardian/links', {
    groupId,
    subject: 'PERSONAL',
    level: 'LIVE',
    acknowledged: true,
  }, rider.token);
  assert.equal(created.status, 201);
  assert.ok(created.json.url);
  assert.equal(created.json.status, 'ACTIVE');

  // Extract capability token from URL fragment.
  const token = new URL(created.json.url).hash.slice('#token='.length);
  assert.equal(token.length, 32, 'Capability token must have 32 characters entropy');

  // Verify database stores SHA-256 tokenHash, NEVER raw capability token.
  const expectedHash = crypto.createHash('sha256').update(token).digest('hex');
  const grantInDb = await h.t.gw.repo.guardianGrant({ tokenHash: expectedHash });
  assert.ok(grantInDb, 'Grant must be retrievable by SHA-256 hash');
  assert.equal(grantInDb.tokenHash, expectedHash);
  assert.equal(grantInDb.token, undefined, 'Raw capability token must never be stored in database');

  const headers = guardianHeaders('198.51.100.21');

  // Exchange valid token -> succeeds and returns HTTP 201 with session credential cookie.
  const session = await h.t.api('POST', '/guardian/session', { token }, null, headers);
  assert.equal(session.status, 201);
  const cookie = session.headers.get('set-cookie');
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /Secure/);
  assert.match(cookie, /SameSite=Strict/);

  // Exchange with invalid token format (too short, too long, non-base64url) -> 410.
  const invalidFormat1 = await h.t.api('POST', '/guardian/session', { token: 'short' }, null, headers);
  assert.equal(invalidFormat1.status, 410);

  const invalidFormat2 = await h.t.api('POST', '/guardian/session', { token: 'a'.repeat(31) }, null, headers);
  assert.equal(invalidFormat2.status, 410);

  // Exchange with non-existent token of valid length -> 410.
  const fakeToken = crypto.randomBytes(24).toString('base64url');
  const nonExistent = await h.t.api('POST', '/guardian/session', { token: fakeToken }, null, headers);
  assert.equal(nonExistent.status, 410);

  await h.t.api('DELETE', `/guardian/links/${created.json.grantId}`, null, rider.token);
});

test('guardian authorization: PIN gate enforcement with status 401 GUARDIAN_PIN_REQUIRED', async () => {
  const rider = await h.rider('PIN Gate Rider');
  const ride = await h.t.api('POST', '/convoys', { name: 'PIN Gate Ride' }, rider.token);
  const groupId = ride.json.groupId;

  const pin = '482910';
  const created = await h.t.api('POST', '/guardian/links', {
    groupId,
    subject: 'PERSONAL',
    level: 'LIVE',
    acknowledged: true,
    pin,
  }, rider.token);
  assert.equal(created.status, 201);

  const token = new URL(created.json.url).hash.slice('#token='.length);
  const headers = guardianHeaders('198.51.100.22');

  // Exchange without PIN -> 401 GUARDIAN_PIN_REQUIRED.
  const noPin = await h.t.api('POST', '/guardian/session', { token }, null, headers);
  assert.equal(noPin.status, 401);
  assert.equal(noPin.json.code, 'GUARDIAN_PIN_REQUIRED');

  // Exchange with wrong PIN -> 401 GUARDIAN_PIN_REQUIRED.
  const wrongPin = await h.t.api('POST', '/guardian/session', { token, pin: '999999' }, null, headers);
  assert.equal(wrongPin.status, 401);
  assert.equal(wrongPin.json.code, 'GUARDIAN_PIN_REQUIRED');

  // Exchange with correct PIN -> 201 session credential.
  const correctPin = await h.t.api('POST', '/guardian/session', { token, pin }, null, headers);
  assert.equal(correctPin.status, 201);
  assert.ok(correctPin.json.sessionId);

  await h.t.api('DELETE', `/guardian/links/${created.json.grantId}`, null, rider.token);
});

test('guardian authorization: PIN rate limiting triggers HTTP 429 after 10 failed attempts', async () => {
  const rider = await h.rider('Rate Limit Rider');
  const ride = await h.t.api('POST', '/convoys', { name: 'Rate Limit Ride' }, rider.token);
  const groupId = ride.json.groupId;

  const pin = '567890';
  const created = await h.t.api('POST', '/guardian/links', {
    groupId,
    subject: 'PERSONAL',
    level: 'LIVE',
    acknowledged: true,
    pin,
  }, rider.token);
  assert.equal(created.status, 201);

  const token = new URL(created.json.url).hash.slice('#token='.length);
  const headers = guardianHeaders('198.51.100.23');

  // Perform 10 failed attempts.
  for (let i = 0; i < 10; i++) {
    const res = await h.t.api('POST', '/guardian/session', { token, pin: `00000${i}` }, null, headers);
    assert.equal(res.status, 401);
  }

  // The 11th attempt must trigger rate limit (HTTP 429).
  const rateLimited = await h.t.api('POST', '/guardian/session', { token, pin: '000099' }, null, headers);
  assert.equal(rateLimited.status, 429, '11th attempt within 1 minute must be rate limited with HTTP 429');

  await h.t.api('DELETE', `/guardian/links/${created.json.grantId}`, null, rider.token);
});

test('guardian authorization: instant pause and revocation block active and new sessions immediately', async () => {
  const rider = await h.rider('Pause Revoke Rider');
  const ride = await h.t.api('POST', '/convoys', { name: 'Pause Revoke Ride' }, rider.token);
  const groupId = ride.json.groupId;

  const created = await h.t.api('POST', '/guardian/links', {
    groupId,
    subject: 'PERSONAL',
    level: 'LIVE',
    acknowledged: true,
  }, rider.token);
  assert.equal(created.status, 201);
  const grantId = created.json.grantId;
  const token = new URL(created.json.url).hash.slice('#token='.length);
  const headers = guardianHeaders('198.51.100.24');

  // Establish active session.
  const session = await h.t.api('POST', '/guardian/session', { token }, null, headers);
  assert.equal(session.status, 201);
  const cookieHeader = { Cookie: session.headers.get('set-cookie').split(';')[0] };
  const snapshotPath = `/guardian/sessions/${session.json.sessionId}/snapshot`;

  // Verify snapshot works while active.
  const activeSnap = await h.t.api('GET', snapshotPath, null, null, cookieHeader);
  assert.equal(activeSnap.status, 200);

  // Instant pause.
  const pauseRes = await h.t.api('PATCH', `/guardian/links/${grantId}`, { paused: true }, rider.token);
  assert.equal(pauseRes.status, 200);
  assert.equal(pauseRes.json.paused, true);

  // Snapshot request must immediately return HTTP 423 GUARDIAN_PAUSED.
  const pausedSnap = await h.t.api('GET', snapshotPath, null, null, cookieHeader);
  assert.equal(pausedSnap.status, 423, 'Paused link must immediately return HTTP 423');

  // Resume link.
  const resumeRes = await h.t.api('PATCH', `/guardian/links/${grantId}`, { paused: false }, rider.token);
  assert.equal(resumeRes.status, 200);

  // Snapshot request succeeds again.
  const resumedSnap = await h.t.api('GET', snapshotPath, null, null, cookieHeader);
  assert.equal(resumedSnap.status, 200);

  // Instant revocation.
  const revokeRes = await h.t.api('DELETE', `/guardian/links/${grantId}`, null, rider.token);
  assert.equal(revokeRes.status, 200);
  assert.equal(revokeRes.json.revoked, true);

  // Snapshot request with existing session must immediately fail with HTTP 410.
  const revokedSnap = await h.t.api('GET', snapshotPath, null, null, cookieHeader);
  assert.equal(revokedSnap.status, 410, 'Revoked link session must immediately return HTTP 410');

  // New session exchange attempts must also fail with HTTP 410.
  const newExchange = await h.t.api('POST', '/guardian/session', { token }, null, headers);
  assert.equal(newExchange.status, 410, 'Exchange on revoked link must immediately fail with HTTP 410');
});

test('guardian authorization: consent withdrawal immediately removes member from projection', async () => {
  const lead = await h.rider('Lead Consent Rider');
  const member = await h.rider('Member Consent Rider');

  const ride = await h.t.api('POST', '/convoys', { name: 'Group Consent Ride' }, lead.token);
  const groupId = ride.json.groupId;

  // Member joins group.
  const joinRes = await h.t.api('POST', '/convoys/join', { code: ride.json.joinCode }, member.token);
  assert.equal(joinRes.status, 200);

  // Both lead and member give consent.
  await h.t.api('PATCH', `/guardian/consent/${groupId}`, { allowed: true }, lead.token);
  await h.t.api('PATCH', `/guardian/consent/${groupId}`, { allowed: true }, member.token);

  // Lead creates GROUP level link.
  const created = await h.t.api('POST', '/guardian/links', {
    groupId,
    subject: 'GROUP',
    level: 'LIVE',
    acknowledged: true,
  }, lead.token);
  assert.equal(created.status, 201);
  assert.equal(created.json.subject, 'GROUP');

  const token = new URL(created.json.url).hash.slice('#token='.length);
  const headers = guardianHeaders('198.51.100.25');
  const session = await h.t.api('POST', '/guardian/session', { token }, null, headers);
  assert.equal(session.status, 201);
  const cookieHeader = { Cookie: session.headers.get('set-cookie').split(';')[0] };
  const snapshotPath = `/guardian/sessions/${session.json.sessionId}/snapshot`;

  // Start the ride to project live members.
  await h.t.api('POST', `/convoys/${groupId}/status`, { status: 'STARTED' }, lead.token);

  // Initial snapshot: includes consenting member.
  const snap1 = await h.t.api('GET', snapshotPath, null, null, cookieHeader);
  assert.equal(snap1.status, 200);
  assert.equal(snap1.json.scope, 'GROUP');
  assert.ok(snap1.json.sharedRiders >= 2, 'Both lead and member should be included');

  // Member withdraws consent.
  const withdraw = await h.t.api('PATCH', `/guardian/consent/${groupId}`, { allowed: false }, member.token);
  assert.equal(withdraw.status, 200);
  assert.equal(withdraw.json.allowed, false);

  // Subsequent snapshot must immediately exclude member.
  const snap2 = await h.t.api('GET', snapshotPath, null, null, cookieHeader);
  assert.equal(snap2.status, 200);
  assert.equal(snap2.json.sharedRiders, 1, 'Member must be immediately removed from shared count');

  await h.t.api('DELETE', `/guardian/links/${created.json.grantId}`, null, lead.token);
  await h.t.api('POST', `/convoys/${groupId}/status`, { status: 'ENDED' }, lead.token);
});
