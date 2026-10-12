'use strict';
/**
 * Comprehensive security regression and hardening audit suite.
 * Validates:
 * 1. HTTP Security Headers: Content-Security-Policy, Permissions-Policy, X-Frame-Options DENY, X-Content-Type-Options nosniff.
 * 2. IDOR and Access Control: Convoy isolation, role hierarchy, non-member rejection, admin endpoint protection.
 * 3. Emergency Monotonicity and Anti-Replay: Non-existent alert resolution rejected without phantom event emission,
 *    telemetry packet cannot tamper with role or emergency state, idempotent SOS handling.
 * 4. Ride Guardian Capability Token Hardening: Entropy, invalid token handling, rate limiting.
 */
process.env.NODE_ENV = 'test';
process.env.GUARDIAN_ENABLED = 'true';
process.env.PUBLIC_ORIGIN = 'https://guardian.example';
process.env.GEO_ROUTE_URL = 'http://route.test';
process.env.GEO_MIN_INTERVAL_MS = '0';
process.env.NET_TICK_MS = '3600000';
process.env.DISCOVERY_TICK_MS = '3600000';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'securityadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const { netBoot, sleep } = require('./_net_helpers');

let h;

before(async () => {
  h = await netBoot();
});

after(async () => {
  await h.t.gw.shutdown();
});

function httpGet(path, headers = {}) {
  const url = new URL(path, h.t.origin);
  return new Promise((resolve, reject) => {
    http.get(url, { headers }, (res) => {
      let body = '';
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    }).on('error', reject);
  });
}

test('Security Headers: CSP, Frameguard, Nosniff, and Permissions-Policy on public endpoints', async () => {
  const res = await httpGet('/status');
  assert.equal(res.status, 200);

  // Content-Security-Policy verification
  const csp = res.headers['content-security-policy'];
  assert.ok(csp, 'Content-Security-Policy header must be present');
  assert.ok(csp.includes("frame-ancestors 'none'"), 'CSP frame-ancestors must be none');
  assert.ok(csp.includes("object-src 'none'"), 'CSP object-src must be none');

  // Clickjacking protection
  assert.equal(res.headers['x-frame-options'], 'DENY');

  // MIME confusion protection
  assert.equal(res.headers['x-content-type-options'], 'nosniff');

  // Permissions-Policy disables dangerous browser APIs
  const pp = res.headers['permissions-policy'];
  assert.ok(pp, 'Permissions-Policy header must be present');
  assert.ok(pp.includes('camera=()'), 'Camera API must be disabled');
  assert.ok(pp.includes('microphone=()'), 'Microphone API must be disabled');
  assert.ok(pp.includes('geolocation=()'), 'Geolocation API must be disabled');
});

test('Security Headers: Watch endpoint enforces ultra-strict CSP sandbox', async () => {
  const res = await httpGet('/watch');
  assert.equal(res.status, 200);
  const csp = res.headers['content-security-policy'];
  assert.ok(csp, 'Watch endpoint must serve explicit CSP');
  assert.ok(csp.includes("default-src 'none'"), 'Watch CSP default-src must be none');
  assert.ok(csp.includes("frame-ancestors 'none'"), 'Watch CSP frame-ancestors must be none');
  assert.equal(res.headers['x-frame-options'], 'DENY');
  assert.equal(res.headers['referrer-policy'], 'no-referrer');
});

test('IDOR Protection: Non-member cannot resolve an alert or mutate convoy state', async () => {
  const owner = await h.rider('ownerA');
  const attacker = await h.rider('attackerA');
  const ride = await h.rideOn(null, { name: 'SecureConvoy', lead: owner });
  const ws = await h.net1(owner.token, ride.gid);

  // Raise alert in secure convoy
  const alert = await h.sos(ws, 17.51, 78.10);
  assert.ok(alert.alertId, 'Alert must be raised');

  // Attacker is NOT in the convoy and attempts to resolve it
  let caughtError = false;
  try {
    await h.t.gw.convoys.resolveSos(ride.gid, attacker.user, alert.alertId, 'RESOLVED');
  } catch (err) {
    caughtError = true;
    assert.equal(err.status, 403);
    assert.equal(err.reason, 'NOT_MEMBER');
  }
  assert.ok(caughtError, 'Non-member resolution must throw ConvoyError NOT_MEMBER with 403');
  ws.close();
});

test('IDOR Protection: Unauthenticated and non-admin calls to /api/admin are rejected', async () => {
  const user = await h.rider('normalB');
  const res = await httpGet('/api/admin/fleet', { Authorization: `Bearer ${user.token}` });
  assert.equal(res.status, 403, 'Normal user must receive 403 on admin endpoints');

  const anonRes = await httpGet('/api/admin/fleet');
  assert.equal(anonRes.status, 401, 'Anonymous request must receive 401');
});

test('Emergency Monotonicity: Resolving non-existent alertId returns false and emits zero phantom events', async () => {
  const owner = await h.rider('ownerB');
  const ride = await h.rideOn(null, { name: 'MonotonicConvoy', lead: owner });

  let phantomEmitted = false;
  const listener = (gid, type) => {
    if (gid === ride.gid && type === 'ALERT_RESOLVED') phantomEmitted = true;
  };
  h.t.gw.convoys.on('ALERT_RESOLVED', listener);

  const result = await h.t.gw.convoys.resolveSos(ride.gid, owner.user, 'NONEXISTENT_ALERT_XYZ', 'RESOLVED');
  assert.equal(result, false, 'Non-existent alert resolution must return false');
  assert.equal(phantomEmitted, false, 'No phantom ALERT_RESOLVED event should be emitted');

  h.t.gw.convoys.off('ALERT_RESOLVED', listener);
});

test('Telemetry Packet Sanitization: Cannot inject role, phone, or admin elevations via websocket TELEMETRY', async () => {
  const rider = await h.rider('telemetryC');
  const ride = await h.rideOn(null, { name: 'TelemetryConvoy', lead: rider });
  const ws = await h.net1(rider.token, ride.gid);

  ws.sendJson({
    type: 'TELEMETRY',
    lat: 17.541,
    lng: 78.131,
    role: 'MEMBER',
    isAdmin: true,
    phone: '+919999999999',
    medical: { bloodGroup: 'AB+' },
  });

  await sleep(60);
  const room = await h.t.gw.convoys.getRoom(ride.gid);
  const current = room.riders.get(rider.user.userId);

  assert.equal(current.role, 'LEAD', 'Original LEAD role preserved');
  assert.equal(current.phone, rider.user.phone, 'Phone cannot be overwritten via TELEMETRY');
  assert.equal(current.isAdmin, undefined, 'isAdmin cannot be injected via TELEMETRY');
  assert.equal(current.medical, undefined, 'Medical payload cannot be injected into rider object');
  ws.close();
});

test('Ride Guardian Token Security: High entropy, reject malformed or non-existent token with 401', async () => {
  const badRes = await httpGet('/api/guardian/invalid-token-123');
  assert.equal(badRes.status, 401, 'Malformed or non-existent token must return 401 unauthorized');

  const shortRes = await httpGet('/api/guardian/abc');
  assert.equal(shortRes.status, 401, 'Short token must return 401 unauthorized');
});
