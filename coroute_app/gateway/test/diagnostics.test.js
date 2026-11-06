'use strict';

process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

let gw, base, soda;
let admin, rider;

before(async () => {
  soda = new MemorySoda();
  gw = await createApp({ soda, logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const { port } = gw.server.address();
  base = `http://127.0.0.1:${port}/api`;

  admin = (await api('POST', '/auth/register', {
    name: 'Root Admin',
    email: 'admin@coroute.test',
    password: 'Password#123',
    phone: '+919876543210',
    vehicleType: 'Motorcycle',
    vehicleNo: 'TS09AB0001',
    emergencyContact: '+919000000001',
    emergencyContactName: 'Family Contact',
  })).json;

  rider = (await api('POST', '/auth/register', {
    name: 'Test Rider',
    email: 'rider@coroute.test',
    password: 'Password#123',
    phone: '+919876543211',
    vehicleType: 'Motorcycle',
    vehicleNo: 'TS09AB0002',
    emergencyContact: '+919000000002',
    emergencyContactName: 'Family Contact',
  })).json;
});

after(async () => {
  if (gw) await gw.shutdown();
});

async function api(method, path, body, token) {
  const res = await fetch(base + path, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json };
}

const sampleReport = {
  diagnosticId: 'diag-test-uuid-001',
  timestamp: Date.now(),
  consentGiven: true,
  overallResult: 'Fully supported',
  overallSummary: 'All hardware sensors, permissions, and emergency pipelines are fully supported.',
  lifecycleStatus: 'Submitted',
  deviceInfo: {
    manufacturer: 'Google',
    model: 'Pixel 8 Pro',
    osVersion: 'Android 14',
    apiLevel: 34,
    appVersion: '3.53.18',
    buildNumber: '10015',
    cpuArch: 'arm64-v8a',
    batteryOptimizationStatus: 'Unrestricted (Ignoring Optimizations)',
  },
  categories: {
    gps: {
      categoryKey: 'gps',
      title: 'GPS & Location',
      status: 'Ready',
      summary: 'GPS services and permissions ready for real-time tracking.',
      checks: [
        { key: 'location_service', name: 'Location Service Availability', status: 'Ready', detail: 'Enabled' },
        { key: 'permission_in_use', name: 'Location Permission (In-Use)', status: 'Ready', detail: 'Granted' },
      ],
    },
    accelerometer: {
      categoryKey: 'accelerometer',
      title: 'Accelerometer Sensor',
      status: 'Ready',
      summary: 'Accelerometer responsive with 50Hz continuous pipeline.',
      checks: [
        { key: 'accel_hardware', name: 'Hardware Sensor Presence', status: 'Supported', detail: 'Detected' },
      ],
    },
    crash_detection: {
      categoryKey: 'crash_detection',
      title: 'Crash Detection Pipeline',
      status: 'Ready',
      summary: 'Crash detection sensor pipeline ready.',
      checks: [
        { key: 'crash_hardware_support', name: 'Hardware Sensor Support', status: 'Supported', detail: 'Ready' },
      ],
    },
    sos: {
      categoryKey: 'sos',
      title: 'Emergency SOS & Telemetry',
      status: 'Ready',
      summary: 'Cloud gateway and local emergency persistence ready.',
      checks: [
        { key: 'sos_internet', name: 'Internet Connectivity', status: 'Ready', detail: 'Active' },
      ],
    },
  },
};

test('FEAT-DIAG-02: Diagnostic Report Submission', async (t) => {
  await t.test('rejects submissions without explicit rider consent', async () => {
    const unconsented = { ...sampleReport, diagnosticId: 'diag-no-consent', consentGiven: false };
    const res = await api('POST', '/diagnostics/submit', unconsented, rider.token);
    assert.equal(res.status, 400);
    assert.match(res.json.error, /consent/i);
  });

  await t.test('strictly blocks prohibited information (IMEI, serial, audio, contacts, GPS traces)', async () => {
    const leakImei = { ...sampleReport, diagnosticId: 'diag-leak-imei', imei: '356938035643803' };
    const res1 = await api('POST', '/diagnostics/submit', leakImei, rider.token);
    assert.equal(res1.status, 400);
    assert.match(res1.json.error, /prohibited/i);

    const leakContacts = { ...sampleReport, diagnosticId: 'diag-leak-contacts', contacts: [{ name: 'Friend', phone: '123' }] };
    const res2 = await api('POST', '/diagnostics/submit', leakContacts, rider.token);
    assert.equal(res2.status, 400);
    assert.match(res2.json.error, /prohibited/i);

    const leakAudio = { ...sampleReport, diagnosticId: 'diag-leak-audio', recordedAudio: 'base64audio...' };
    const res3 = await api('POST', '/diagnostics/submit', leakAudio, rider.token);
    assert.equal(res3.status, 400);
    assert.match(res3.json.error, /prohibited/i);

    const leakGps = { ...sampleReport, diagnosticId: 'diag-leak-gps', continuousGps: [{ lat: 12.97, lng: 77.59 }] };
    const res4 = await api('POST', '/diagnostics/submit', leakGps, rider.token);
    assert.equal(res4.status, 400);
    assert.match(res4.json.error, /prohibited/i);
  });

  await t.test('successfully accepts valid report and associates riderId', async () => {
    const res = await api('POST', '/diagnostics/submit', sampleReport, rider.token);
    assert.equal(res.status, 200);
    assert.equal(res.json.ok, true);
    assert.equal(res.json.diagnosticId, 'diag-test-uuid-001');
    assert.equal(res.json.status, 'Submitted');
  });

  await t.test('safe retry: submitting same diagnosticId returns existing report without duplicate', async () => {
    const res = await api('POST', '/diagnostics/submit', sampleReport, rider.token);
    assert.equal(res.status, 200);
    assert.equal(res.json.ok, true);
    assert.equal(res.json.diagnosticId, 'diag-test-uuid-001');
  });

  await t.test('enforces rate limiting: max 5 submissions/day/rider', async () => {
    // Already submitted 2 successful reports above (sampleReport + safe retry).
    // Let's submit 3 more to reach the 5 submissions/day limit:
    for (let i = 3; i <= 5; i++) {
      const r = await api('POST', '/diagnostics/submit', { ...sampleReport, diagnosticId: `diag-rate-${i}` }, rider.token);
      assert.equal(r.status, 200, `Report ${i} status: ${r.status}`);
    }

    // 6th report within 24h should be rejected with 429
    const blocked = await api('POST', '/diagnostics/submit', { ...sampleReport, diagnosticId: 'diag-rate-6' }, rider.token);
    assert.equal(blocked.status, 429);
    assert.match(blocked.json.error, /rate limit/i);
  });
});

test('FEAT-DIAG-03: Admin Device Compatibility Dashboard Endpoints', async (t) => {
  // Submit an additional report from another manufacturer (Samsung) with limitations
  const samsungReport = {
    diagnosticId: 'diag-samsung-001',
    timestamp: Date.now(),
    consentGiven: true,
    overallResult: 'Supported with limitations',
    overallSummary: 'Microphone permission missing; crash detection operational.',
    lifecycleStatus: 'Submitted',
    deviceInfo: {
      manufacturer: 'Samsung',
      model: 'Galaxy S23',
      osVersion: 'Android 14',
      apiLevel: 34,
      appVersion: '3.53.18',
      buildNumber: '10015',
      cpuArch: 'arm64-v8a',
      batteryOptimizationStatus: 'Optimized',
    },
    categories: {
      gps: { categoryKey: 'gps', title: 'GPS', status: 'Ready', checks: [] },
      accelerometer: { categoryKey: 'accelerometer', title: 'Accelerometer', status: 'Ready', checks: [] },
      microphone: { categoryKey: 'microphone', title: 'Microphone', status: 'Permission Required', checks: [] },
      background_execution: { categoryKey: 'background_execution', title: 'Background', status: 'Limited', checks: [] },
    },
  };

  // Submit via admin or repo
  await api('POST', '/diagnostics/submit', samsungReport, admin.token);

  await t.test('non-admin user is rejected with 403 on admin diagnostics endpoints', async () => {
    const res = await api('GET', '/admin/diagnostics', null, rider.token);
    assert.equal(res.status, 403);
  });

  await t.test('GET /admin/diagnostics returns aggregated stats and paginated list', async () => {
    const res = await api('GET', '/admin/diagnostics', null, admin.token);
    assert.equal(res.status, 200);
    assert.equal(res.json.ok, true);

    const { stats, reports, pagination } = res.json;
    assert.ok(stats.totalReports >= 2, `Total reports: ${stats.totalReports}`);
    assert.ok(typeof stats.fullySupportedPercent === 'number');
    assert.ok(Array.isArray(stats.topManufacturers));
    assert.ok(Array.isArray(stats.topFailureCategories));
    assert.ok(stats.statusCounts);

    assert.ok(Array.isArray(reports));
    assert.equal(pagination.page, 1);
    assert.ok(pagination.total >= 2);
  });

  await t.test('GET /admin/diagnostics supports filtering by manufacturer and status', async () => {
    const resMfg = await api('GET', '/admin/diagnostics?manufacturer=Samsung', null, admin.token);
    assert.equal(resMfg.status, 200);
    assert.ok(resMfg.json.reports.every((r) => r.deviceInfo.manufacturer.toLowerCase().includes('samsung')));

    const resSearch = await api('GET', '/admin/diagnostics?search=Galaxy', null, admin.token);
    assert.equal(resSearch.status, 200);
    assert.ok(resSearch.json.reports.some((r) => r.deviceInfo.model.includes('Galaxy')));
  });

  await t.test('GET /admin/diagnostics/:id returns full report detail', async () => {
    const res = await api('GET', '/admin/diagnostics/diag-samsung-001', null, admin.token);
    assert.equal(res.status, 200);
    assert.equal(res.json.ok, true);
    assert.equal(res.json.report.diagnosticId, 'diag-samsung-001');
    assert.equal(res.json.report.deviceInfo.model, 'Galaxy S23');
  });

  await t.test('GET /admin/diagnostics/:id returns 404 for unknown report', async () => {
    const res = await api('GET', '/admin/diagnostics/non-existent-id', null, admin.token);
    assert.equal(res.status, 404);
  });

  await t.test('PATCH /admin/diagnostics/:id updates lifecycle status and appends admin audit history', async () => {
    const updateRes = await api('PATCH', '/admin/diagnostics/diag-samsung-001', {
      status: 'Reviewed',
      adminNotes: 'Verified compatibility with Samsung OneUI 6 battery settings.',
    }, admin.token);

    assert.equal(updateRes.status, 200);
    assert.equal(updateRes.json.ok, true);
    assert.equal(updateRes.json.report.lifecycleStatus, 'Reviewed');
    assert.equal(updateRes.json.report.adminNotes, 'Verified compatibility with Samsung OneUI 6 battery settings.');

    // Check review history
    assert.ok(Array.isArray(updateRes.json.report.reviewHistory));
    const latest = updateRes.json.report.reviewHistory[updateRes.json.report.reviewHistory.length - 1];
    assert.equal(latest.action, 'Reviewed');
    assert.equal(latest.by, admin.user?.email || 'admin@coroute.test');
    assert.equal(latest.adminNotes, 'Verified compatibility with Samsung OneUI 6 battery settings.');
  });

  await t.test('PATCH /admin/diagnostics/:id rejects invalid status', async () => {
    const badStatus = await api('PATCH', '/admin/diagnostics/diag-samsung-001', {
      status: 'InvalidStatusXYZ',
    }, admin.token);

    assert.equal(badStatus.status, 400);
    assert.match(badStatus.json.error, /invalid lifecycle status/i);
  });
});
