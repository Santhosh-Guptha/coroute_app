'use strict';
/**
 * 3.56 server SOS SMS (src/sos_sms.js, docs/features_355/sos_sms.md): one SMS per contact per SOS,
 * DLT template text and variables, retries with backoff, delivery receipts (Twilio signature, MSG91
 * reports), "safe now" on cancel, cost caps, no personal data in logs, provider adapters with the host
 * allowlist, the admin settings / test / log, and the full path SOS over the socket -> SMS -> resolve.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'smsadmin@coroute.test';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';
process.env.SMS_WEBHOOK_TOKEN = 'whtok_0123456789abcdef';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { TemplateStore } = require('../src/templates');
const { SosSms, ProviderError, twilioSignature, mapStatus, SMS_HOSTS } = require('../src/sos_sms');

const ORIGIN = 'https://coroute.example';
const AT = Date.UTC(2026, 10, 10, 8, 35); // 14:05 IST

function fakeProvider() {
  const p = { calls: [], failures: [], seq: 0, configured: () => true };
  p.send = async (m) => {
    p.calls.push(m);
    const f = p.failures.shift();
    if (f) throw f;
    return { messageId: `fk_${++p.seq}` };
  };
  return p;
}

function unit({ settings = {}, clockAt = AT } = {}) {
  const soda = new MemorySoda();
  const lines = [];
  const logger = { info: (s) => lines.push(String(s)), warn: (s) => lines.push(String(s)), error: (s) => lines.push(String(s)) };
  const fake = fakeProvider();
  const clock = { t: clockAt };
  const sms = new SosSms({ soda, templates: new TemplateStore({ soda, logger }), config: { publicOrigin: ORIGIN }, logger, clock: () => clock.t,
    env: { SMS_PROVIDER: 'off' }, providers: { fake }, settingsCacheMs: 0 });
  const ready = sms.saveSettings({ provider: 'fake', ...settings });
  return { soda, sms, fake, clock, lines, ready };
}
const contacts = [{ phone: '+91 98765 43210', name: 'Mom' }, { phone: '09123456780', name: 'Brother' }, { phone: '+919876543210', name: 'Mom again' }];
const sos = (sms, extra = {}) => sms.dispatchSos({ sosKey: 'ALERT-1', userId: 'u1', riderName: 'Asha Rao', lat: 12.971598, lng: 77.594562, token: 'Ab3dEf6hIj9lMn0pQr2tUv', contacts, at: AT, ...extra });

test('each contact is texted once per SOS with the exact DLT template text', async () => {
  const { sms, fake, ready } = unit();
  await ready;
  const out = await sos(sms);
  assert.equal(out.active, true);
  assert.deepEqual(out.results.map((r) => r.status), ['SENT', 'SENT']);
  assert.equal(fake.calls.length, 2, 'the duplicate number is texted once');
  assert.deepEqual(fake.calls.map((c) => c.to), ['+919876543210', '+919123456780']);
  assert.equal(fake.calls[0].body, `CoRoute SOS: Asha needs help. Live: ${ORIGIN}/e/Ab3dEf6hIj9lMn0pQr2tUv Lat 12.97160 Lng 77.59456 at 14:05 IST. Call 112. -CoRoute`);
  assert.deepEqual(fake.calls[0].vars, { name: 'Asha', token: 'Ab3dEf6hIj9lMn0pQr2tUv', lat: '12.97160', lng: '77.59456', time: '14:05' });
  for (const v of Object.values(fake.calls[0].vars)) assert.ok(v.length <= 30, 'every DLT variable fits 30 characters');
  // The same SOS again (relay copy, retry, second node): nobody is texted twice.
  const again = await sos(sms);
  assert.deepEqual(again.results.map((r) => r.status), ['DUPLICATE', 'DUPLICATE']);
  assert.equal(fake.calls.length, 2);
});

test('DLT templates keep their variables; changes warn about re-registration', async () => {
  const { sms } = unit();
  const t = sms.templates;
  await assert.rejects(t.save('sos_sms', { text: 'CoRoute SOS: {{name}} needs help at {{time}}.' }), /exactly these variables/);
  await assert.rejects(t.save('sos_sms', { text: 'SOS {{name}} {{origin}}/e/{{token}} {{lng}} {{lat}} {{time}}' }), /in this order/);
  const out = await t.save('sos_sms', { text: 'CoRoute alert: {{name}} needs help. Live: {{origin}}/e/{{token}} Lat {{lat}} Lng {{lng}} at {{time}} IST. Call 112. -CoRoute' });
  assert.ok(out.warnings.some((w) => /registered template/.test(w)));
  const list = await t.list();
  assert.match(list.find((x) => x.id === 'sos_sms').warning, /DLT/);
});

test('retries with backoff on provider trouble; a refusal fails at once', async () => {
  const { sms, fake, clock, ready } = unit();
  await ready;
  fake.failures.push(new ProviderError('HTTP 503', { retryable: true }), new ProviderError('network', { retryable: true }), new ProviderError('HTTP 400', { retryable: false }));
  const out = await sos(sms);
  assert.deepEqual(out.results.map((r) => r.status), ['QUEUED', 'QUEUED']);
  assert.deepEqual((await sms.tick()).retried, 0, 'not before the backoff');
  clock.t += 30000;
  await sms.tick();
  const rows = (await sms.soda.query('sos_sms', { sosKey: 'ALERT-1' }, { limit: 10 })).map((r) => r.value).sort((a, b) => a.toMasked.localeCompare(b.toMasked));
  const by = Object.fromEntries(rows.map((r) => [r.toMasked, r]));
  assert.equal(by['***210'].status, 'FAILED', 'the 400 on the retry is final');
  assert.equal(by['***780'].status, 'SENT');
  assert.equal(by['***780'].attempts, 2);
});

test('delivery receipts update each contact: Twilio (signed) and MSG91 reports', async () => {
  const { sms, ready } = unit();
  await ready;
  await sos(sms);
  const rows = await sms.soda.query('sos_sms', { sosKey: 'ALERT-1' }, { limit: 10 });
  assert.equal(await sms.onReceipts('fake', [{ messageId: rows[0].value.providerMessageId, status: 'delivered' }]), 1);
  assert.equal(await sms.onReceipts('fake', [{ messageId: rows[1].value.providerMessageId, status: 'undelivered' }]), 1);
  const after2 = (await sms.soda.query('sos_sms', { sosKey: 'ALERT-1' }, { limit: 10 })).map((r) => r.value.status).sort();
  assert.deepEqual(after2, ['DELIVERED', 'FAILED']);
  assert.equal(mapStatus('1'), 'DELIVERED');
  assert.equal(mapStatus('DELIVRD'), 'DELIVERED');
  assert.equal(mapStatus('NDNC'), 'FAILED');
  assert.equal(mapStatus('queued'), 'SENT');
});

test('cancel: "safe now" to the contacts who got the SOS; undelivered retries stop', async () => {
  const { sms, fake, ready } = unit();
  await ready;
  fake.failures.push(null, new ProviderError('HTTP 503', { retryable: true }));
  await sos(sms);
  const out = await sms.dispatchSafe('ALERT-1', { at: AT + 15 * 60000 });
  assert.deepEqual(out.results.map((r) => r.status).sort(), ['CANCELLED', 'SENT']);
  const safe = fake.calls.filter((c) => c.kind === 'SAFE');
  assert.equal(safe.length, 1);
  assert.equal(safe[0].body, 'CoRoute: Asha is safe now. The SOS alert was closed at 14:20 IST. No action is needed. -CoRoute');
  // Twice (resolve on both nodes): still once.
  await sms.dispatchSafe('ALERT-1');
  assert.equal(fake.calls.filter((c) => c.kind === 'SAFE').length, 1);
});

test('caps: SMS per SOS and per rider per day', async () => {
  const { sms, fake, ready } = unit({ settings: { maxPerSos: 1, maxPerUserDay: 2 } });
  await ready;
  const out = await sos(sms);
  assert.deepEqual(out.results.map((r) => r.status), ['SENT', 'CAPPED']);
  await sos(sms, { sosKey: 'ALERT-2' });
  const third = await sos(sms, { sosKey: 'ALERT-3' });
  assert.equal(third.results[0].status, 'CAPPED');
  assert.equal(third.results[0].reason, 'PER_DAY');
  assert.equal(fake.calls.length, 2);
});

test('no phone numbers, names or links in the logs; personal data purged after 48 h', async () => {
  const { sms, lines, clock, fake, ready } = unit();
  await ready;
  fake.failures.push(new ProviderError('HTTP 400: invalid number +919876543210', { retryable: false }));
  await sos(sms);
  await sms.dispatchSafe('ALERT-1');
  const all = lines.join('\n');
  assert.ok(all.length > 0);
  for (const s of ['9876543210', '9123456780', 'Asha', 'Ab3dEf6hIj9lMn0pQr2tUv', 'Mom']) assert.ok(!all.includes(s), `log has no ${s}`);
  const failed = (await sms.soda.query('sos_sms', { status: 'FAILED' }, { limit: 5 }))[0].value;
  assert.ok(!failed.lastError.includes('9876543210'), 'stored errors are redacted too');
  clock.t += 49 * 3600 * 1000;
  const r = await sms.tick();
  assert.ok(r.purged >= 2);
  const left = (await sms.soda.query('sos_sms', {}, { limit: 10 })).map((x) => x.value);
  assert.ok(left.every((x) => x.to === null && x.vars === null && x.body === null));
  const log = await sms.log();
  assert.equal(log[0].messages[0].to.startsWith('***'), true);
});

test('provider adapters: MSG91 flow and Twilio form, https to the allowed hosts only', async () => {
  const calls = [];
  const fetchImpl = async (url, init) => { calls.push({ url, init }); return { status: 200, json: async () => (String(url).includes('msg91') ? { type: 'success', message: 'req123' } : { sid: 'SM123' }) }; };
  const soda = new MemorySoda();
  const env = { MSG91_AUTH_KEY: 'k-msg91', TWILIO_ACCOUNT_SID: 'AC1', TWILIO_AUTH_TOKEN: 'tw-secret', TWILIO_FROM_NUMBER: '+15005550006', SMS_WEBHOOK_TOKEN: 'whtok_0123456789abcdef' };
  const sms = new SosSms({ soda, templates: new TemplateStore({ soda }), config: { publicOrigin: ORIGIN }, env, fetchImpl, logger: { info() {}, warn() {} }, settingsCacheMs: 0, clock: () => AT });
  await sms.saveSettings({ provider: 'msg91', msg91TemplateIdSos: 'tmplSOS12345', msg91TemplateIdSafe: 'tmplSAFE1234', senderId: 'CORUTE', dltEntityId: '1101234567890123456' });
  await sos(sms, { contacts: [{ phone: '+919876543210' }] });
  assert.equal(new URL(calls[0].url).hostname, 'control.msg91.com');
  assert.equal(calls[0].init.headers.authkey, 'k-msg91');
  const body = JSON.parse(calls[0].init.body);
  assert.equal(body.template_id, 'tmplSOS12345');
  assert.deepEqual(body.recipients[0], { mobiles: '919876543210', name: 'Asha', token: 'Ab3dEf6hIj9lMn0pQr2tUv', lat: '12.97160', lng: '77.59456', time: '14:05' });
  await sms.saveSettings({ provider: 'twilio' });
  await sos(sms, { sosKey: 'ALERT-T', contacts: [{ phone: '+919876543210' }] });
  const tw = calls[1];
  assert.equal(new URL(tw.url).hostname, 'api.twilio.com');
  const form = new URLSearchParams(tw.init.body);
  assert.equal(form.get('From'), '+15005550006');
  assert.match(form.get('Body'), /^CoRoute SOS: Asha needs help\./);
  assert.equal(form.get('StatusCallback'), `${ORIGIN}/api/sms/receipts/twilio/whtok_0123456789abcdef`);
  assert.deepEqual([...SMS_HOSTS].sort(), ['api.msg91.com', 'api.twilio.com', 'control.msg91.com']);
  assert.equal(tw.init.redirect, 'error');
});

// ------------------------------------------------------------ through the full gateway
let t, admin, rider;
const live = fakeProvider();
before(async () => {
  t = await boot({ smsProviders: { fake: live }, emergencyFetch: async () => { throw new Error('offline in tests'); } });
  admin = await t.register('SMS Admin', 'smsadmin@coroute.test');
  rider = await t.register('Kiran Kumar', 'kiran.sos@coroute.test', { emergencyContact: '+919812345678', emergencyContactName: 'Amma' });
});
after(async () => { await t.gw.shutdown(); });

test('admin: settings show secrets as Set / Not set, validate DLT ids, test SMS and the log', async () => {
  assert.equal((await t.api('GET', '/admin/sms/settings', null, rider.token)).status, 403);
  let r = await t.api('GET', '/admin/sms/settings', null, admin.token);
  assert.equal(r.status, 200);
  assert.equal(r.json.settings.provider, 'off');
  assert.equal(r.json.secrets.MSG91_AUTH_KEY, 'Not set');
  assert.equal(r.json.secrets.SMS_WEBHOOK_TOKEN, 'Set');
  assert.ok(!JSON.stringify(r.json).includes('whtok_0123456789abcdef'), 'secret values are never shown');
  r = await t.api('PUT', '/admin/sms/settings', { provider: 'fake', dltTemplateIdSos: '12ab' }, admin.token);
  assert.equal(r.status, 400);
  r = await t.api('PUT', '/admin/sms/settings', { provider: 'fake', senderId: 'CORUTE', dltEntityId: '1101234567890123456', dltTemplateIdSos: '1107123456789012345', dltTemplateIdSafe: '1107123456789012346' }, admin.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.ready, true);
  r = await t.api('POST', '/admin/sms/test', { phone: '+919800000099' }, admin.token);
  assert.equal(r.status, 200);
  assert.deepEqual([r.json.to, r.json.status], ['***099', 'SENT']);
  assert.match(live.calls.at(-1).body, /CoRoute test is safe now/);
});

test('SOS over the socket: the contact gets one SMS with a working live link; resolve sends "safe now"', async () => {
  live.calls.length = 0;
  const c = await t.api('POST', '/convoys', { name: 'Solo ride', start: { lat: 12.97, lng: 77.59, name: 'Home' } }, rider.token);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  const ws = await t.joinRoom(rider.token, c.json.groupId);
  const phoneToken = 'Zx9yWv8uTs7rQp6oNm5lKj';
  ws.sendJson({ type: 'SOS', lat: 12.9716, lng: 77.5946, clientId: 'sos-sms-1', smsLinkToken: phoneToken });
  const alert = await ws.next((m) => m.type === 'ALERT');
  await sleep(150);
  const sosCalls = live.calls.filter((x) => x.kind === 'SOS');
  assert.equal(sosCalls.length, 1, JSON.stringify(live.calls.map((x) => x.kind)));
  assert.equal(sosCalls[0].to, '+919812345678');
  const token = sosCalls[0].vars.token;
  assert.match(token, /^[A-Za-z0-9_-]{22}$/);
  assert.equal((await fetch(`${t.origin}/e/${token}`)).status, 200, 'the server SMS link works');
  assert.equal((await fetch(`${t.origin}/e/${phoneToken}`)).status, 200, 'the link in the phone\'s own text works once the SOS arrived');
  // Repeats of the same SOS never text again.
  ws.sendJson({ type: 'SOS', lat: 12.9716, lng: 77.5946, clientId: 'sos-sms-1', smsLinkToken: phoneToken });
  await sleep(100);
  assert.equal(live.calls.filter((x) => x.kind === 'SOS').length, 1);
  ws.sendJson({ type: 'SOS_RESOLVE', alertId: alert.alert.alertId, reason: 'CANCELLED' });
  await ws.next((m) => m.type === 'ALERT_RESOLVED');
  await sleep(100);
  const safe = live.calls.filter((x) => x.kind === 'SAFE');
  assert.equal(safe.length, 1);
  assert.equal(safe[0].to, '+919812345678');
  const log = await t.api('GET', '/admin/sms/log', null, admin.token);
  const g = log.json.sos.find((x) => x.sosKey === alert.alert.alertId);
  assert.deepEqual(g.messages.map((m) => m.kind).sort(), ['SAFE', 'SOS']);
  assert.ok(!JSON.stringify(log.json).includes('9812345678'));
  ws.close();
});

test('receipt webhooks: token required, Twilio signature checked, MSG91 reports parsed', async () => {
  const row = (await t.gw.soda.query('sos_sms', { kind: 'SOS' }, { limit: 5 })).find((r) => r.value.provider === 'fake');
  // Twilio-shaped receipt for a Twilio row.
  await t.gw.soda.replace('sos_sms', row.key, { ...row.value, provider: 'twilio', providerMessageId: 'SMabc', status: 'SENT' });
  const url = `${ORIGIN}/api/sms/receipts/twilio/whtok_0123456789abcdef`;
  const params = { MessageSid: 'SMabc', MessageStatus: 'delivered' };
  const post = (p, body, headers = {}) => fetch(`${t.base}/sms/receipts/${p}`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', ...headers }, body: new URLSearchParams(body).toString() });
  assert.equal((await post('twilio/wrongtoken_000000000', params)).status, 404);
  process.env.TWILIO_AUTH_TOKEN = 'tw-secret';
  try {
    assert.equal((await post('twilio/whtok_0123456789abcdef', params, { 'x-twilio-signature': 'bad' })).status, 403);
    const ok = await post('twilio/whtok_0123456789abcdef', params, { 'x-twilio-signature': twilioSignature('tw-secret', url, params) });
    assert.equal(ok.status, 200);
  } finally { delete process.env.TWILIO_AUTH_TOKEN; }
  assert.equal((await t.gw.soda.findOne('sos_sms', { providerMessageId: 'SMabc' })).value.status, 'DELIVERED');
  // MSG91: data=[{requestId, report:[{number, desc}]}]
  await t.gw.soda.replace('sos_sms', row.key, { ...(await t.gw.soda.get('sos_sms', row.key)), provider: 'msg91', providerMessageId: 'req777', status: 'SENT' });
  const data = JSON.stringify([{ requestId: 'req777', report: [{ number: '919812345678', status: '2', desc: 'FAILED' }] }]);
  assert.equal((await post('msg91/whtok_0123456789abcdef', { data })).status, 200);
  assert.equal((await t.gw.soda.findOne('sos_sms', { providerMessageId: 'req777' })).value.status, 'FAILED');
});
