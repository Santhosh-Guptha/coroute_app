'use strict';
/**
 * v3.56 operations: /metrics (Prometheus text, loopback / allow list / token only), SODA call counters, load
 * shedding (non-essential reads only, never SOS / auth / rides / health), the SodaClient connection budget
 * (priority collections bypass it), the DR 'standby' role (no leases, /api/health/live 503), the drain hook,
 * keep-alive tuning and ETag / 304 on public JSON.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.METRICS_TOKEN = 'test-metrics-token-0123456789abcdef';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { Metrics, instrumentSoda, routeClass, ipAllowed, allowList } = require('../src/metrics');
const { LoadShedder, NEVER } = require('../src/load_shed');
const { SodaClient } = require('../src/oracle/soda');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { JobLease } = require('../src/job_lease');
const { Mirror } = require('../src/mirror');
const { IntelEngine } = require('../src/intel/engine');

let t;
before(async () => { t = await boot({ emergencyFetch: async () => { throw new Error('offline in tests'); } }); });
after(async () => { await t.gw.shutdown(); });

// ------------------------------------------------------------------ metrics
test('/metrics answers loopback in Prometheus text with HTTP, DB, event loop and WebSocket series', async () => {
  await t.api('GET', '/meta');
  const res = await fetch(`${t.origin}/metrics`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/plain/);
  assert.match(res.headers.get('content-type'), /version=0\.0\.4/);
  const body = await res.text();
  for (const name of ['coroute_http_requests_total', 'coroute_http_request_duration_seconds_bucket', 'coroute_db_calls_total',
    'coroute_event_loop_lag_ms', 'coroute_event_loop_utilization', 'coroute_process_resident_memory_bytes', 'coroute_ws_connections',
    'coroute_ws_events_total', 'coroute_cache_db_reads_total', 'coroute_load_shedding']) {
    assert.ok(body.includes(name), `missing ${name}`);
  }
  assert.match(body, /coroute_http_requests_total\{method="GET",route="\/api\/meta",status="2xx"\} \d+/);
  assert.doesNotMatch(body, /usr_|GRP-|@/, 'no ids or e-mails in labels');
});

test('/metrics is 404 for a client behind the proxy (X-Forwarded-For) unless it has the token', async () => {
  const pub = await fetch(`${t.origin}/metrics`, { headers: { 'X-Forwarded-For': '203.0.113.9' } });
  assert.equal(pub.status, 404);
  const bad = await fetch(`${t.origin}/metrics`, { headers: { 'X-Forwarded-For': '203.0.113.9', Authorization: 'Bearer nope' } });
  assert.equal(bad.status, 404);
  const ok = await fetch(`${t.origin}/metrics`, { headers: { 'X-Forwarded-For': '203.0.113.9', Authorization: `Bearer ${process.env.METRICS_TOKEN}` } });
  assert.equal(ok.status, 200);
});

test('route classes fold ids; IP allow list handles CIDRs and IPv4-mapped addresses', () => {
  assert.equal(routeClass('/api/convoys/GRP-12AB/riders/usr_x?x=1'), '/api/convoys');
  assert.equal(routeClass('/assets/site.css'), '/assets');
  assert.equal(routeClass('/'), '/');
  assert.equal(routeClass('/api/GRP-1234'), '/api/:id');
  const list = allowList(['loopback', '10.0.0.0/24']);
  assert.equal(ipAllowed('127.0.0.1', list), true);
  assert.equal(ipAllowed('::ffff:10.0.0.7', list), true);
  assert.equal(ipAllowed('10.0.1.7', list), false);
  assert.equal(ipAllowed('', list), false);
  assert.throws(() => allowList(['not-an-ip']));
});

test('instrumentSoda counts calls and errors per operation and collection, same results', async () => {
  const m = new Metrics({ loop: false });
  const soda = instrumentSoda(new MemorySoda(), m);
  await soda.ensureCollection('things');
  const key = await soda.insert('things', { a: 1 });
  assert.deepEqual((await soda.get('things', key)), { a: 1 });
  await soda.findOne('things', { a: 1 });
  assert.equal(m.dbCalls.get({ op: 'insert', collection: 'things' }), 1);
  assert.equal(m.dbCalls.get({ op: 'findOne', collection: 'things' }), 1);
  const failing = instrumentSoda({ get: async () => { throw new Error('down'); } }, m);
  await assert.rejects(failing.get('x', 'k'));
  assert.equal(m.dbErrors.get({ op: 'get', collection: 'x' }), 1);
  assert.match(m.render(), /coroute_db_call_duration_seconds_bucket\{op="insert",le="0.005"\}/);
});

// ------------------------------------------------------------------ load shedding
test('never-list: SOS, alerts, auth refresh, convoys, health, webhooks are never sheddable, even if configured', () => {
  const s = new LoadShedder({ mode: 'force', extra: ['/api/auth', 'POST /api/v1/sos/dispatch-external', '/api/convoys', '/api/health', '/api/sos'] });
  for (const [m, p] of [['POST', '/api/v1/sos/dispatch-external'], ['POST', '/api/sos/dispatch-external'], ['POST', '/api/auth/refresh'],
    ['POST', '/api/auth/login'], ['POST', '/api/convoys/GRP-1/tracks'], ['GET', '/api/convoys/GRP-1/emergency-roster'], ['GET', '/api/health'],
    ['GET', '/api/health/live'], ['POST', '/api/subscription/webhook'], ['GET', '/e/abc'], ['GET', '/api/public/live/abc'],
    ['POST', '/api/intel/crash'], ['GET', '/api/me/capabilities'], ['GET', '/api/admin/emergencies']]) {
    assert.equal(s.sheddable(m, p), false, `${m} ${p} must never be shed`);
  }
  assert.ok(NEVER.includes('/api/v1/sos'));
  for (const [m, p] of [['GET', '/api/places/reviews?lat=1'], ['GET', '/api/community-stats'], ['GET', '/api/intel/hazards'],
    ['POST', '/api/intel/fuel-gaps'], ['GET', '/api/public/leaderboard'], ['HEAD', '/api/usage-stats']]) {
    assert.equal(s.sheddable(m, p), true, `${m} ${p} is sheddable`);
  }
  assert.equal(s.sheddable('POST', '/api/places/reviews'), false, 'writing a review is not in the default list');
});

test('overload detection: event loop lag, in-flight, heap, DB queue; held for LOAD_SHED_HOLD_MS', () => {
  let now = 0; let lag = 0; let inflight = 0; let heap = 0.5; let q = 0;
  const s = new LoadShedder({ mode: 'on', clock: () => now, loop: { current: () => ({ p99: lag }) }, inflight: () => inflight,
    heapStats: () => ({ used: heap * 100, limit: 100 }), dbQueue: () => q, lagMs: 250, maxInflight: 200, heapRatio: 0.9, dbQueueMax: 200, holdMs: 5000 });
  assert.equal(s.shedding(), false);
  lag = 400; now += 300;
  assert.equal(s.shedding(), true);
  assert.match(s.overloadReason(), /event loop/);
  lag = 0; now += 4000;
  assert.equal(s.shedding(), true, 'held');
  now += 1500;
  assert.equal(s.shedding(), false, 'released after the hold');
  inflight = 500; now += 300; assert.equal(s.shedding(), true); inflight = 0; now += 6000; assert.equal(s.shedding(), false);
  heap = 0.95; now += 300; assert.match(s.overloadReason(), /heap/); heap = 0.5; now += 6000;
  q = 500; now += 300; assert.match(s.overloadReason(), /database/); q = 0; now += 6000;
  assert.equal(new LoadShedder({ mode: 'off', loop: { current: () => ({ p99: 9999 }) } }).shedding(), false);
});

test('end to end in force mode: a non-essential read gets 503 + Retry-After; essentials and SOS still work', async () => {
  const shedder = t.gw.shedder;
  const prev = shedder.mode;
  shedder.mode = 'force';
  try {
    const res = await fetch(`${t.base}/community-stats`);
    assert.equal(res.status, 503);
    const ra = Number(res.headers.get('retry-after'));
    assert.ok(ra >= 15 && ra <= 25, `Retry-After ${ra}`);
    assert.equal((await res.json()).code, 'BUSY');
    assert.equal((await fetch(`${t.base}/health`)).status, 200);
    const u = await t.register('Shed1', 'shed1@coroute.test');
    const u2 = await t.register('Shed2', 'shed2@coroute.test');
    const login = await t.api('POST', '/auth/login', { email: 'shed1@coroute.test', password: 'Password#123' });
    assert.notEqual(login.status, 503, 'sign-in is never shed');
    const c = await t.api('POST', '/convoys', { name: 'Shed ride' }, u.token);
    assert.ok(c.status === 200 || c.status === 201);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.json.joinCode }, u2.token)).status, 200);
    const a = await t.joinRoom(u.token, c.json.groupId);
    const b = await t.joinRoom(u2.token, c.json.groupId);
    a.sendJson({ type: 'SOS', clientId: 'shed-sos-1', lat: 12.9, lng: 77.6 });
    const alert = await b.next((m) => m.type === 'ALERT', 3000);
    assert.equal(alert.alert.userId, u.user.userId);
    a.close(); b.close();
    const body = await (await fetch(`${t.origin}/metrics`)).text();
    assert.match(body, /coroute_load_shed_total\{route="\/api\/community-stats"\} [1-9]/);
  } finally { shedder.mode = prev; }
});

// ------------------------------------------------------------------ SodaClient connection budget
function fakeFetch({ delayMs = 30 } = {}) {
  const state = { active: 0, max: 0, calls: [] };
  const f = async (url, init) => {
    state.calls.push(url);
    state.active++; state.max = Math.max(state.max, state.active);
    await sleep(delayMs);
    state.active--;
    return { ok: true, status: 200, text: async () => JSON.stringify({ items: [] }) };
  };
  return { f, state };
}

test('SodaClient: at most ORACLE_MAX_INFLIGHT calls at once; alerts / sessions / leases bypass the queue', async () => {
  const { f, state } = fakeFetch({ delayMs: 40 });
  const soda = new SodaClient({ baseUrl: 'https://adb.example/ords/x/soda/latest', user: 'u', password: 'p', fetchImpl: f, maxInFlight: 2 });
  const jobs = [];
  for (let i = 0; i < 6; i++) jobs.push(soda.query('trips', {}));
  await sleep(5);
  assert.equal(soda.queueLength(), 4);
  const t0 = Date.now();
  await soda.query('alerts', {}); // never waits behind the trips reads
  assert.ok(Date.now() - t0 < 80, 'priority collection bypassed the queue');
  await Promise.all(jobs);
  assert.ok(state.max <= 3, `max concurrent ${state.max} (2 budgeted + 1 bypass)`);
  assert.equal(soda.queueLength(), 0);
  assert.ok(soda.stats.queued >= 4 && soda.stats.bypass >= 1);
});

test('SodaClient: a full queue fails fast with 503 instead of piling up; 0 = unlimited', async () => {
  const { f } = fakeFetch({ delayMs: 30 });
  const soda = new SodaClient({ baseUrl: 'https://adb.example/x', user: 'u', password: 'p', fetchImpl: f, maxInFlight: 1, maxQueue: 1 });
  const a = soda.query('trips', {}); const b = soda.query('trips', {});
  await assert.rejects(soda.query('trips', {}), (e) => e.status === 503);
  await Promise.all([a, b]);
  const { f: f2, state } = fakeFetch({ delayMs: 20 });
  const free = new SodaClient({ baseUrl: 'https://adb.example/x', user: 'u', password: 'p', fetchImpl: f2, maxInFlight: 0 });
  await Promise.all(Array.from({ length: 10 }, () => free.query('trips', {})));
  assert.equal(state.max, 10);
});

// ------------------------------------------------------------------ DR standby role
test('standby role: JobLease never acquires or runs a job; a live node still does', async () => {
  const soda = new MemorySoda();
  const standby = new JobLease({ soda, role: 'standby', node: 'vm3', autoTick: false, logger: { info() {}, warn() {} } });
  let ran = 0;
  standby.run('retention', 1000, () => { ran++; });
  await standby.poll('retention');
  await standby.poll('retention');
  assert.equal(ran, 0);
  assert.equal(await standby.once('coupon-seed', () => { ran++; }), false);
  assert.equal(ran, 0);
  const live = new JobLease({ soda, role: 'all', node: 'vm1', autoTick: false, logger: { info() {}, warn() {} } });
  live.run('retention', 1000, () => { ran++; });
  await live.poll('retention');
  await sleep(5);
  assert.equal(ran, 1);
  await standby.stopAll({ waitMs: 10 }); await live.stopAll({ waitMs: 10 });
});

test('standby role: /api/health/live is 503 "standby"; beginDrain() makes a serving node 503 "shutdown"', async () => {
  const convoys = { on() {}, rooms: new Map() };
  const m = new Mirror({ convoys, role: 'standby', node: 'vm3', logger: { info() {}, warn() {} } });
  const h = m.health();
  assert.equal(h.status, 503);
  assert.equal(h.body.state, 'standby');
  m.stop();
  const live = new Mirror({ convoys, role: 'all', node: 'vm1', logger: { info() {}, warn() {} } });
  assert.equal(live.health().status, 200);
  live.beginDrain();
  assert.equal(live.health().status, 503);
  assert.equal(live.health().body.state, 'shutdown');
  live.stop();
});

test('config accepts GATEWAY_ROLE=standby', () => {
  const { execFileSync } = require('child_process');
  const out = execFileSync(process.execPath, ['-e', "process.stdout.write(require('./src/config').gatewayRole)"],
    { cwd: require('path').join(__dirname, '..'), env: { ...process.env, GATEWAY_ROLE: 'standby' } }).toString();
  assert.equal(out, 'standby');
});

// ------------------------------------------------------------------ HTTP: keep-alive, ETag / 304
test('HTTP keep-alive is above the proxy idle timeout, headers timeout above keep-alive', () => {
  assert.ok(t.gw.server.keepAliveTimeout >= 61000, `keepAliveTimeout ${t.gw.server.keepAliveTimeout}`);
  assert.ok(t.gw.server.headersTimeout > t.gw.server.keepAliveTimeout);
});

/** Plain http.get (fetch() adds Cache-Control: no-cache to conditional requests, as the Fetch spec says; apps do not). */
function rawGet(url, headers = {}) {
  return new Promise((resolve, reject) => {
    require('http').get(url, { headers }, (res) => { res.resume(); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers })); }).on('error', reject);
  });
}

test('public JSON has an ETag and answers 304 to If-None-Match (website access view, app meta)', async () => {
  for (const p of ['/public/access', '/meta']) {
    const r1 = await rawGet(`${t.base}${p}`);
    assert.equal(r1.status, 200, p);
    const etag = r1.headers.etag;
    assert.ok(etag, `${p} has an ETag`);
    const r2 = await rawGet(`${t.base}${p}`, { 'If-None-Match': etag });
    assert.equal(r2.status, 304, `${p} revalidates`);
  }
  const r = await fetch(`${t.base}/public/access`);
  assert.match(r.headers.get('cache-control'), /public, max-age=30/);
});

test('intel layer JSON: ETag computed before compression, 304 skips the work', () => {
  const headers = {}; let status = 200; let sent = null;
  const res = { set(k, v) { headers[k.toLowerCase()] = v; return this; }, get(k) { return headers[k.toLowerCase()]; }, status(s) { status = s; return this; },
    end() { sent = 'end'; return this; }, type() { return this; }, send(b) { sent = b; return this; } };
  const req1 = { get: () => '', fresh: false };
  IntelEngine.sendJson(req1, res, { cells: [1, 2, 3] });
  const etag = headers.etag;
  assert.match(etag, /^W\/"[0-9a-f]+-[A-Za-z0-9+/]{27}"$/);
  assert.ok(Buffer.isBuffer(sent));
  const req2 = { get: () => 'gzip', fresh: true };
  IntelEngine.sendJson(req2, res, { cells: [1, 2, 3] });
  assert.equal(status, 304); assert.equal(sent, 'end');
});
