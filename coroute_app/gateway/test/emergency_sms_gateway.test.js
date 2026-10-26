'use strict';

process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test-secret-test-secret-test-secret-1234';

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { EmergencySmsGateway, toE164, toWhatsAppNumber } = require('../src/emergency_sms_gateway');
const { boot } = require('./_helpers');

describe('EmergencySmsGateway Unit & Driver Tests', () => {
  test('toE164 normalizes Indian and international phone numbers', () => {
    assert.equal(toE164('9876543210'), '+919876543210');
    assert.equal(toE164('09876543210'), '+919876543210');
    assert.equal(toE164('+91 98765 43210'), '+919876543210');
    assert.equal(toE164('00447911123456'), '+447911123456');
    assert.equal(toWhatsAppNumber('+91 98765 43210'), '919876543210');
  });

  test('generates secure live tracking URLs and resolves via liveView', () => {
    const gw = new EmergencySmsGateway({ config: { publicOrigin: 'https://coroute.live', liveLinkMin: 30 } });
    const url = gw.generateTrackingUrl({
      tripId: 'TRIP-999',
      riderId: 'u123',
      riderName: 'Vikram Singh',
      lat: 12.9716,
      lng: 77.5946,
      speedKmh: 65,
      severity: 'CRITICAL',
      bloodGroup: 'B+',
    });

    assert.match(url, /^https:\/\/coroute\.live\/e\/[A-Za-z0-9_-]{32}$/);
    const token = url.split('/e/')[1];
    const hash = require('crypto').createHash('sha256').update(token).digest('hex');
    const view = gw.liveView(hash);

    assert.ok(view);
    assert.equal(view.firstName, 'Vikram');
    assert.equal(view.lat, 12.9716);
    assert.equal(view.lng, 77.5946);
    assert.equal(view.severity, 'CRITICAL');
    assert.equal(view.bloodGroup, 'B+');
  });

  test('formats distress message with vital location and tracking link', () => {
    const gw = new EmergencySmsGateway();
    const msg = gw.formatEmergencyMessage({
      riderName: 'Ananya Sharma',
      lat: 13.0827,
      lng: 80.2707,
      speedKmh: 42.4,
      severity: 'CRITICAL',
      bloodGroup: 'O+',
      trackingUrl: 'https://coroute.live/e/token123',
    });

    assert.match(msg, /Ananya Sharma/);
    assert.match(msg, /13.08270, 80.27070/);
    assert.match(msg, /42 km\/h/);
    assert.match(msg, /Blood Group: O\+/);
    assert.match(msg, /https:\/\/coroute\.live\/e\/token123/);
    assert.match(msg, /Call 112/);
  });

  test('Twilio SMS provider dispatches with basic auth', async () => {
    let capturedUrl = '';
    let capturedAuth = '';
    let capturedBody = '';

    const mockFetch = async (url, opts) => {
      capturedUrl = url;
      capturedAuth = opts.headers.Authorization;
      capturedBody = opts.body;
      return {
        ok: true,
        status: 201,
        json: async () => ({ sid: 'SM1234567890abcdef' }),
      };
    };

    const gw = new EmergencySmsGateway({
      fetchImpl: mockFetch,
      config: {
        telephonyPrimaryProvider: 'twilio',
        twilioAccountSid: 'AC_TEST_SID',
        twilioAuthToken: 'TEST_AUTH_TOKEN',
        twilioFromNumber: '+15005550006',
      },
    });

    const res = await gw.sendSms({
      to: '+919876543210',
      contactName: 'Rohan',
      body: 'Emergency Test',
    });

    assert.equal(res.success, true);
    assert.equal(res.provider, 'twilio');
    assert.equal(res.messageId, 'SM1234567890abcdef');
    assert.ok(capturedUrl.includes('AC_TEST_SID'));
    assert.ok(capturedAuth.startsWith('Basic '));
    assert.ok(capturedBody.includes('To=%2B919876543210'));
  });

  test('Infobip SMS provider dispatches with API key', async () => {
    let capturedUrl = '';
    let capturedAuth = '';

    const mockFetch = async (url, opts) => {
      capturedUrl = url;
      capturedAuth = opts.headers.Authorization;
      return {
        ok: true,
        status: 200,
        json: async () => ({ messages: [{ messageId: 'IB-999000' }] }),
      };
    };

    const gw = new EmergencySmsGateway({
      fetchImpl: mockFetch,
      config: {
        telephonyPrimaryProvider: 'infobip',
        infobipApiKey: 'test-infobip-key',
        infobipBaseUrl: 'https://api.infobip.com',
      },
    });

    const res = await gw.sendSms({
      to: '+919876543210',
      contactName: 'Dad',
      body: 'Infobip Test',
    });

    assert.equal(res.success, true);
    assert.equal(res.provider, 'infobip');
    assert.equal(res.messageId, 'IB-999000');
    assert.equal(capturedAuth, 'App test-infobip-key');
  });

  test('WhatsApp Business Cloud API dispatches correctly', async () => {
    let capturedUrl = '';
    let capturedBody = null;

    const mockFetch = async (url, opts) => {
      capturedUrl = url;
      capturedBody = JSON.parse(opts.body);
      return {
        ok: true,
        status: 200,
        json: async () => ({ messages: [{ id: 'wamid.HBg123' }] }),
      };
    };

    const gw = new EmergencySmsGateway({
      fetchImpl: mockFetch,
      config: {
        whatsappApiToken: 'EAAB_TEST_TOKEN',
        whatsappPhoneNumberId: '10987654321',
        whatsappApiUrl: 'https://graph.facebook.com/v20.0',
      },
    });

    const res = await gw.sendWhatsApp({
      to: '+91 98765 43210',
      contactName: 'Sister',
      body: 'WhatsApp Emergency Test',
    });

    assert.equal(res.success, true);
    assert.equal(res.provider, 'whatsapp_cloud_api');
    assert.equal(res.messageId, 'wamid.HBg123');
    assert.ok(capturedUrl.includes('10987654321/messages'));
    assert.equal(capturedBody.to, '919876543210');
    assert.equal(capturedBody.messaging_product, 'whatsapp');
  });

  test('Automatic fallback: Twilio fails -> falls back to Webhook provider', async () => {
    const mockFetch = async (url) => {
      if (url.includes('twilio.com')) {
        return { ok: false, status: 500, text: async () => 'Twilio gateway unavailable' };
      }
      if (url.includes('telephony-webhook.internal')) {
        return { ok: true, status: 200, json: async () => ({ messageId: 'WH-FALLBACK-101' }) };
      }
      throw new Error(`Unexpected URL ${url}`);
    };

    const gw = new EmergencySmsGateway({
      fetchImpl: mockFetch,
      config: {
        telephonyPrimaryProvider: 'twilio',
        telephonySecondaryProvider: 'webhook',
        twilioAccountSid: 'AC_FAIL',
        twilioAuthToken: 'TOKEN_FAIL',
        twilioFromNumber: '+15005550006',
        telephonyWebhookUrl: 'https://telephony-webhook.internal/sms',
      },
    });

    const res = await gw.sendSms({
      to: '+919876543210',
      contactName: 'Friend',
      body: 'Fallback Test',
    });

    assert.equal(res.success, true);
    assert.equal(res.provider, 'webhook');
    assert.equal(res.messageId, 'WH-FALLBACK-101');
  });

  test('Automatic fallback: all unconfigured -> logs structured outbox queue with zero loss', async () => {
    const gw = new EmergencySmsGateway({
      config: {
        telephonyPrimaryProvider: 'twilio',
        telephonySecondaryProvider: 'webhook',
        // No credentials configured
      },
    });

    const res = await gw.sendSms({
      to: '+919876543210',
      contactName: 'Guardian Contact',
      body: 'Outbox Test',
    });

    assert.equal(res.success, true);
    assert.equal(res.provider, 'outbox_queue');
    assert.equal(res.fallback, true);

    const outbox = gw.getOutbox();
    assert.equal(outbox.length, 1);
    assert.equal(outbox[0].status, 'QUEUED');
    assert.equal(outbox[0].to, '+919876543210');
    assert.equal(outbox[0].channel, 'sms');
  });

  test('sub-10 second delivery target: concurrent multi-contact dispatch', async () => {
    let activeCalls = 0;
    let maxParallel = 0;

    const mockFetch = async () => {
      activeCalls++;
      maxParallel = Math.max(maxParallel, activeCalls);
      await new Promise((r) => setTimeout(r, 20));
      activeCalls--;
      return { ok: true, status: 200, json: async () => ({ sid: 'SM-FAST' }) };
    };

    const gw = new EmergencySmsGateway({
      fetchImpl: mockFetch,
      config: {
        telephonyPrimaryProvider: 'twilio',
        twilioAccountSid: 'AC_PARALLEL',
        twilioAuthToken: 'AUTH_PARALLEL',
        twilioFromNumber: '+1000',
        whatsappApiToken: 'WA_TOKEN',
        whatsappPhoneNumberId: '12345',
      },
    });

    const start = Date.now();
    const result = await gw.dispatchExternal({
      tripId: 'TRIP-PARALLEL',
      riderId: 'u-speed',
      riderName: 'Rider Speed',
      lat: 12.9,
      lng: 77.6,
      contacts: [
        { phone: '+919000000001', name: 'Contact 1' },
        { phone: '+919000000002', name: 'Contact 2' },
        { phone: '+919000000003', name: 'Contact 3' },
      ],
    });
    const elapsed = Date.now() - start;

    assert.ok(elapsed < 2000, `Expected elapsed < 2000ms, got ${elapsed}ms`);
    assert.equal(result.dispatched, true);
    assert.equal(result.sentCount, 6); // 3 contacts * 2 channels (SMS + WhatsApp)
    assert.ok(maxParallel >= 2, `Expected parallel calls, max was ${maxParallel}`);
  });
});

describe('Emergency SMS Gateway REST & WebSocket Integration', () => {
  let app;
  let api;
  let register;

  before(async () => {
    app = await boot();
    api = app.api;
    register = app.register;
  });

  after(async () => {
    if (app && app.gw) {
      await app.gw.shutdown();
    }
  });

  test('POST /api/v1/sos/dispatch-external requires authentication (401)', async () => {
    const res = await api('POST', '/v1/sos/dispatch-external', {
      lat: 12.9716,
      lng: 77.5946,
      contacts: [{ phone: '+919876543210', name: 'Contact' }],
    });
    assert.equal(res.status, 401);
  });

  test('POST /api/v1/sos/dispatch-external validates coordinates (400)', async () => {
    const rider = await register('Rider One', 'rider1@coroute.internal');
    const res = await api('POST', '/v1/sos/dispatch-external', {
      lat: 'invalid',
      lng: 77.5946,
      contacts: [{ phone: '+919876543210', name: 'Contact' }],
    }, rider.token);

    assert.equal(res.status, 400);
    assert.equal(res.json.code, 'INVALID_COORDINATES');
  });

  test('POST /api/v1/sos/dispatch-external dispatches SMS and WhatsApp and returns tracking URL', async () => {
    const rider = await register('Rider Distress', 'distress@coroute.internal');
    const res = await api('POST', '/v1/sos/dispatch-external', {
      tripId: 'TRIP-EXT-1',
      lat: 12.9716,
      lng: 77.5946,
      speedKmh: 48,
      severity: 'CRITICAL',
      bloodGroup: 'AB+',
      contacts: [
        { phone: '+919876543210', name: 'Primary Guardian' },
      ],
    }, rider.token);

    assert.equal(res.status, 200);
    assert.equal(res.json.dispatched, true);
    assert.ok(res.json.sentCount >= 1);
    assert.ok(res.json.trackingUrl);
    assert.match(res.json.trackingUrl, /\/e\//);
    assert.equal(res.json.results.length, 2); // SMS + WhatsApp
  });

  test('POST /api/v1/sos/dispatch-external automatically resolves emergency contact from user profile', async () => {
    const rider = await register('Rider Profile', 'profile@coroute.internal', {
      emergencyContact: '+919123456789',
      emergencyContactName: 'Profile ICE',
    });

    const res = await api('POST', '/v1/sos/dispatch-external', {
      tripId: 'TRIP-PROFILE-ICE',
      lat: 12.9716,
      lng: 77.5946,
      // contacts omitted intentionally
    }, rider.token);

    assert.equal(res.status, 200);
    assert.equal(res.json.dispatched, true);
    assert.equal(res.json.results[0].contact, '+919123456789');
    assert.equal(res.json.results[0].name, 'Profile ICE');
  });

  test('dispatchForSos triggers server dispatch automatically when client has not sent SMS', async () => {
    const rider = await register('SOS Rider', 'sosrider@coroute.internal', {
      emergencyContact: '+919555544444',
      emergencyContactName: 'Emergency Mom',
    });

    const alert = {
      alertId: 'SOS-TEST-999',
      userId: rider.user.userId,
      userName: rider.user.name,
      lat: 13.0827,
      lng: 80.2707,
      speedKmh: 50,
      severity: 'CRITICAL',
    };

    const out = await app.gw.emergencyGateway.dispatchForSos({
      groupId: 'GRP-100',
      user: rider.user,
      alert,
      msg: { clientSentSms: false },
    });

    assert.ok(out);
    assert.equal(out.dispatched, true);
    assert.equal(out.results[0].contact, '+919555544444');
    assert.equal(alert.serverDispatchedByGateway, true);

    // Second call is ignored (no duplicate dispatch)
    const out2 = await app.gw.emergencyGateway.dispatchForSos({
      groupId: 'GRP-100',
      user: rider.user,
      alert,
      msg: { clientSentSms: false },
    });
    assert.equal(out2, null);
  });

  test('dispatchForSos skips server dispatch when client already sent SMS', async () => {
    const rider = await register('Client Sent Rider', 'clientsent@coroute.internal', {
      emergencyContact: '+919555544444',
      emergencyContactName: 'Emergency Mom',
    });

    const alert = {
      alertId: 'SOS-CLIENT-1',
      userId: rider.user.userId,
      userName: rider.user.name,
      lat: 13.0827,
      lng: 80.2707,
    };

    const out = await app.gw.emergencyGateway.dispatchForSos({
      groupId: 'GRP-100',
      user: rider.user,
      alert,
      msg: { clientSentSms: true },
    });

    assert.equal(out, null);
  });
});
