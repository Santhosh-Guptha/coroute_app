'use strict';
/**
 * 3.55 app diagnostics logs (src/diag_logs.js, docs/features_355/diagnostics_logs.md):
 * upload validation (auth, gzip only, size, reason), rate limit, server-side PII strip, admin list /
 * view / lines / download with audit, "Ask for logs" request flow, feature switch, retention and
 * account delete.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'diagadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('zlib');
const { boot } = require('./_helpers');
const D = require('../src/diag_logs');
const { createMemoryStore } = require('../src/object_store');

let t, admin, rider, other;
const objects = createMemoryStore();

before(async () => {
  t = await boot({ diagObjectStore: null }); // database storage (chunks) for this suite
  admin = await t.register('Diag Admin', 'diagadmin@coroute.test');
  rider = await t.register('Diag Rider', 'diagrider@coroute.test');
  other = await t.register('Other Rider', 'diagother@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

const line = (o) => JSON.stringify({ t: Date.now(), m: 1, l: 'I', c: 'ride', e: 'ride_start', n: 1, ...o });
function bundle(lines, meta = { meta: 'coroute-diag', v: 1, build: '3.55.0+10020' }) {
  return zlib.gzipSync(Buffer.from([JSON.stringify(meta), ...lines].join('\n') + '\n'));
}

async function upload(token, body, query = 'reason=manual&build=3.55.0%2B10020&device=Pixel%207&os=14', headers = {}) {
  const res = await fetch(`${t.base}/me/diagnostics?${query}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/gzip', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
    body,
  });
  return { status: res.status, json: await res.json().catch(() => ({})), headers: res.headers };
}

test('upload needs a session', async () => {
  const r = await upload(null, bundle([line({})]));
  assert.equal(r.status, 401);
});

test('only gzip bundles with a known reason are accepted', async () => {
  const plain = await upload(rider.token, Buffer.from(line({}) + '\n'));
  assert.equal(plain.status, 415);
  assert.equal(plain.json.code, 'NOT_GZIP');
  const bad = await upload(rider.token, bundle([line({})]), 'reason=whatever');
  assert.equal(bad.status, 400);
  assert.equal(bad.json.code, 'BAD_REASON');
  const damaged = Buffer.concat([bundle([line({})]).subarray(0, 20), Buffer.alloc(40, 7)]);
  const d = await upload(rider.token, damaged);
  assert.equal(d.status, 400);
  const empty = await upload(rider.token, bundle(['not json', '{"x":1}']));
  assert.equal(empty.status, 400);
  assert.equal(empty.json.code, 'EMPTY');
});

test('a body over 5 MB is refused (413)', async () => {
  const big = Buffer.alloc(D.MAX_BYTES + 1024, 1);
  big[0] = 0x1f; big[1] = 0x8b;
  const r = await upload(rider.token, big);
  assert.equal(r.status, 413);
  assert.equal(r.json.code, 'TOO_LARGE');
});

test('a zip bomb is refused once unpacked', () => {
  const bomb = zlib.gzipSync(Buffer.alloc(D.MAX_RAW_BYTES + 1024, 0x20));
  assert.ok(bomb.length < D.MAX_BYTES);
  assert.throws(() => D.cleanBundle(bomb), (e) => e.status === 413);
});

test('personal data is stripped again on the server; the log is stored and listed', async () => {
  const lines = [
    line({ c: 'sos', e: 'raise', l: 'W', f: { type: 'EMERGENCY', riderName: 'Raj Kumar', phone: '+919876543210', note: 'call me', lat: 17.385044, lng: 78.486671, what: 'mail raj@example.com or 9876543210', jwtish: 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1In0.c2lnbmF0dXJlMTIz', nested: { a: 1 } } }),
    line({ c: 'errors', e: 'flutter_error', l: 'E', f: { type: 'StateError', stack: 'Foo.bar x.dart:12' } }),
    'garbage line',
    JSON.stringify({ t: 'x', e: 1 }),
  ];
  const r = await upload(rider.token, bundle(lines), 'reason=manual&build=3.55.0%2B10020&device=Pixel%207&os=14&rideId=G-ABC123');
  assert.equal(r.status, 201, JSON.stringify(r.json));
  assert.equal(r.json.lines, 2);
  assert.equal(r.json.dropped, 2);
  assert.match(r.json.id, /^dl_[a-f0-9]{20}$/);

  const list = await t.api('GET', '/admin/diag-logs?days=1', null, admin.token);
  assert.equal(list.status, 200);
  const row = list.json.logs.find((x) => x.id === r.json.id);
  assert.ok(row);
  assert.equal(row.reason, 'manual');
  assert.equal(row.build, '3.55.0+10020');
  assert.equal(row.rideId, 'G-ABC123');
  assert.equal(row.errors, 1);

  const lr = await t.api('GET', `/admin/diag-logs/${r.json.id}/lines`, null, admin.token);
  assert.equal(lr.status, 200);
  const text = JSON.stringify(lr.json.lines);
  for (const needle of ['Raj Kumar', '+919876543210', 'call me', 'raj@example.com', '9876543210', 'eyJhbGci', '17.385044']) {
    assert.ok(!text.includes(needle), `leaked ${needle}`);
  }
  const sos = lr.json.lines.find((l) => l.c === 'sos');
  assert.equal(sos.f.lat, 17.385);
  assert.equal(sos.f.type, 'EMERGENCY');
  assert.equal(sos.f.nested, undefined);
  // Category / level filters.
  const errs = await t.api('GET', `/admin/diag-logs/${r.json.id}/lines?level=E`, null, admin.token);
  assert.deepEqual(errs.json.lines.map((l) => l.e), ['flutter_error']);
  const cat = await t.api('GET', `/admin/diag-logs/${r.json.id}/lines?cat=sos`, null, admin.token);
  assert.equal(cat.json.total, 1);
});

test('riders cannot reach the admin routes; admin views and downloads are audited', async () => {
  const up = await upload(other.token, bundle([line({})]));
  assert.equal(up.status, 201);
  const id = up.json.id;
  assert.equal((await t.api('GET', '/admin/diag-logs', null, rider.token)).status, 403);
  assert.equal((await t.api('GET', `/admin/diag-logs/${id}`, null, rider.token)).status, 403);
  assert.equal((await t.api('GET', `/admin/diag-logs/${id}/download`, null, rider.token)).status, 403);
  assert.equal((await t.api('POST', '/admin/diag-logs/request', { userId: other.user.userId }, rider.token)).status, 403);

  const view = await t.api('GET', `/admin/diag-logs/${id}`, null, admin.token);
  assert.equal(view.status, 200);
  assert.equal(view.json.summary.byCategory.ride, 1);
  const dl = await fetch(`${t.base}/admin/diag-logs/${id}/download`, { headers: { Authorization: `Bearer ${admin.token}` } });
  assert.equal(dl.status, 200);
  assert.equal(dl.headers.get('content-type'), 'application/gzip');
  const body = zlib.gunzipSync(Buffer.from(await dl.arrayBuffer())).toString('utf8');
  assert.match(body, /"e":"ride_start"/);
  const audit = await t.gw.repo.listAuditEntries(50);
  assert.ok(audit.some((a) => a.action === 'diag.view' && a.target === id));
  assert.ok(audit.some((a) => a.action === 'diag.download' && a.target === id));
  assert.equal((await t.api('GET', '/admin/diag-logs/dl_00000000000000000000', null, admin.token)).status, 404);
  assert.equal((await t.api('GET', '/admin/diag-logs/not-an-id', null, admin.token)).status, 404);
});

test('admin filters: username, build prefix, reason, user id', async () => {
  const me = await t.api('GET', '/me', null, other.token);
  const username = me.json.username || (me.json.user && me.json.user.username);
  assert.ok(username, 'rider has a username');
  const byUser = await t.api('GET', `/admin/diag-logs?username=${encodeURIComponent(username)}&days=1`, null, admin.token);
  assert.ok(byUser.json.logs.length >= 1);
  assert.ok(byUser.json.logs.every((x) => x.userId === other.user.userId));
  const byId = await t.api('GET', `/admin/diag-logs?userId=${other.user.userId}`, null, admin.token);
  assert.ok(byId.json.logs.every((x) => x.userId === other.user.userId));
  const byBuild = await t.api('GET', '/admin/diag-logs?build=3.55.0', null, admin.token);
  assert.ok(byBuild.json.logs.length >= 2);
  assert.equal((await t.api('GET', '/admin/diag-logs?build=9.9', null, admin.token)).json.logs.length, 0);
  assert.equal((await t.api('GET', '/admin/diag-logs?reason=safety_prompt', null, admin.token)).json.logs.length, 0);
});

test('at most 5 bundles per rider per day (429)', async () => {
  const R = await t.register('Rate Rider', 'diagrate@coroute.test');
  for (let i = 0; i < D.PER_DAY; i++) {
    const r = await upload(R.token, bundle([line({ n: i })]));
    assert.equal(r.status, 201, `upload ${i}`);
  }
  const over = await upload(R.token, bundle([line({})]));
  assert.equal(over.status, 429);
  assert.equal(over.json.code, 'RATE_LIMITED');
});

test('"Ask for logs": the rider gets a socket request, sees it in /me/diagnostics/requests and fulfils it', async () => {
  const R = await t.register('Asked Rider', 'diagasked@coroute.test');
  const ws = await t.connect(R.token);
  await ws.next((m) => m.type === 'HELLO');
  const ask = await t.api('POST', '/admin/diag-logs/request', { userId: R.user.userId }, admin.token);
  assert.equal(ask.status, 200, JSON.stringify(ask.json));
  assert.match(ask.json.requestId, /^dr_[a-f0-9]{16}$/);
  const ev = await ws.next((m) => m.type === 'DIAG_LOG_REQUEST');
  assert.equal(ev.requestId, ask.json.requestId);
  ws.close();
  // Asking again reuses the open request.
  const again = await t.api('POST', '/admin/diag-logs/request', { userId: R.user.userId }, admin.token);
  assert.equal(again.json.requestId, ask.json.requestId);
  assert.equal(again.json.reused, true);

  const open = await t.api('GET', '/me/diagnostics/requests', null, R.token);
  assert.deepEqual(open.json.requests.map((x) => x.requestId), [ask.json.requestId]);
  // Another rider cannot use this request id.
  const wrong = await upload(other.token, bundle([line({})]), `reason=admin_request&requestId=${ask.json.requestId}`);
  assert.equal(wrong.status, 400);
  const ok = await upload(R.token, bundle([line({})]), `reason=admin_request&requestId=${ask.json.requestId}`);
  assert.equal(ok.status, 201);
  assert.equal((await t.api('GET', '/me/diagnostics/requests', null, R.token)).json.requests.length, 0);
  const audit = await t.gw.repo.listAuditEntries(50);
  assert.ok(audit.some((a) => a.action === 'diag.request' && a.target === R.user.userId));
  assert.equal((await t.api('POST', '/admin/diag-logs/request', { userId: 'nobody' }, admin.token)).status, 404);
  assert.equal((await t.api('POST', '/admin/diag-logs/request', {}, admin.token)).status, 400);
});

test('the diagnosticsUpload switch turns uploads off; admin reads stay available', async () => {
  const set = await t.api('PUT', '/admin/features/diagnosticsUpload', { enabled: false, reason: 'test' }, admin.token);
  assert.equal(set.status, 200, JSON.stringify(set.json));
  const r = await upload(rider.token, bundle([line({})]));
  assert.equal(r.status, 403);
  assert.equal(r.json.code, 'FEATURE_OFF');
  assert.equal((await t.api('GET', '/admin/diag-logs', null, admin.token)).status, 200);
  assert.equal((await t.api('PUT', '/admin/features/diagnosticsUpload', { enabled: true, reason: 'test' }, admin.token)).status, 200);
  assert.equal((await upload(rider.token, bundle([line({})]))).status, 201);
});

test('retention removes logs older than 30 days with their stored body', async () => {
  const svc = t.gw.diagLogs;
  const R = await t.register('Old Rider', 'diagold@coroute.test');
  const up = await upload(R.token, bundle([line({})]));
  assert.equal(up.status, 201);
  assert.ok(await svc.body(up.json.id));
  assert.equal(await svc.runRetention(Date.now() + 29 * 86400000), 0);
  const removed = await svc.runRetention(Date.now() + 31 * 86400000);
  assert.ok(removed >= 1);
  assert.equal(await svc.find(up.json.id), null);
  assert.equal(await svc.body(up.json.id), null);
});

test('deleting the account deletes the rider\'s logs and requests', async () => {
  const R = await t.register('Gone Rider', 'diaggone@coroute.test');
  const up = await upload(R.token, bundle([line({})]));
  assert.equal(up.status, 201);
  await t.api('POST', '/admin/diag-logs/request', { userId: R.user.userId }, admin.token);
  assert.equal((await t.api('DELETE', '/me', null, R.token)).status, 200);
  const rows = [];
  for (const name of Object.values(D.COLLECTIONS)) {
    for (const doc of (t.soda.collections.get(name) || new Map()).values()) rows.push(JSON.stringify(doc));
  }
  assert.ok(!rows.some((j) => j.includes(R.user.userId)), 'no diag document of the rider remains');
  assert.ok(!rows.some((j) => j.includes(up.json.id)), 'no chunk of the log remains');
});

test('object storage backend keeps bodies under diag-logs/ and removes them', async () => {
  const svc = new D.DiagLogs({ repo: t.gw.repo, objectStore: objects, logger: { info() {}, warn() {}, error() {} } });
  const doc = await svc.upload({ userId: rider.user.userId, username: 'x' }, bundle([line({})]), { reason: 'safety_prompt' });
  assert.equal(doc.storage, 'par');
  assert.ok(objects.objects.has(`diag-logs/${doc.id}.jsonl.gz`));
  await svc.remove(doc.id);
  assert.ok(!objects.objects.has(`diag-logs/${doc.id}.jsonl.gz`));
});

test('scrubText and cleanEntry (unit)', () => {
  assert.equal(D.scrubText('mail a.b@c.io now'), 'mail <email> now');
  assert.equal(D.scrubText('call +91 98765 43210'), 'call <phone>');
  assert.equal(D.scrubText('epoch 1731234567890 took 120ms'), 'epoch <num> took 120ms');
  assert.equal(D.scrubText('GET https://x.io/ws?token=abc'), 'GET https://x.io/ws');
  assert.ok(D.blockedKey('emergencyContactName'));
  assert.ok(!D.blockedKey('textLen'));
  assert.equal(D.cleanEntry({ t: 1, e: 'x', f: { password: 'p', ok: true } }).f.password, undefined);
  assert.equal(D.cleanEntry({ e: 'x' }), null);
});

test('every response carries a request id; a valid one from the proxy is kept', async () => {
  const r = await t.api('GET', '/me/diagnostics/requests', null, rider.token, { 'X-Request-Id': 'caddy-req-12345678' });
  assert.equal(r.headers.get('x-request-id'), 'caddy-req-12345678');
  const r2 = await t.api('GET', '/me/diagnostics/requests', null, rider.token, { 'X-Request-Id': 'bad id with spaces' });
  assert.match(r2.headers.get('x-request-id'), /^[a-f0-9]{16}$/);
});

test('tool/diag/analyze_logs.js summarises alert latency, false alarms, socket drops and errors', () => {
  const A = require('../../tool/diag/analyze_logs.js');
  const t0 = 1731234567000;
  const rows = [
    { meta: 'coroute-diag', build: '3.55.0+10020', reason: 'safety_prompt' },
    { t: t0, l: 'I', c: 'audio', e: 'audio', f: { line: 'audio: P1 SOS:* decision->audio 340ms' } },
    { t: t0 + 1, l: 'I', c: 'audio', e: 'audio', f: { line: 'audio: P2 overspeed decision->audio 900ms' } },
    { t: t0 + 2, l: 'I', c: 'speed', e: 'overspeed_warn', f: { src: 'group', fixAgeMs: 120 } },
    { t: t0 + 3, l: 'W', c: 'crash', e: 'alarm_open', f: { scenario: 'lowsideSlide' } },
    { t: t0 + 4, l: 'W', c: 'crash', e: 'alarm_cancel', f: { reason: 'im_ok' } },
    { t: t0 + 5, l: 'I', c: 'crash', e: 'candidate_dropped', f: { why: 'no stop' } },
    { t: t0 + 6, l: 'I', c: 'realtime', e: 'closed', f: { code: 1006, inRide: true } },
    { t: t0 + 7, l: 'E', c: 'errors', e: 'flutter_error', f: { type: 'StateError' } },
    { t: t0 + 8, l: 'E', c: 'errors', e: 'flutter_error', f: { type: 'StateError' } },
  ];
  const r = A.analyze(A.parse(rows.map((x) => JSON.stringify(x))));
  assert.equal(r.alerts.decisionToAudioByPriority.P1.max, 340);
  assert.equal(r.overspeed.warns, 1);
  assert.equal(r.crash.cancels.im_ok, 1);
  assert.equal(r.crash.dropped['no stop'], 1);
  assert.equal(r.realtime.closedByCode['1006'], 1);
  assert.equal(r.errors['errors.flutter_error (StateError)'], 2);
  assert.match(A.report(r), /P2 decision->audio: n=1 p50=900ms/);
});
