'use strict';
/**
 * Round 6 "Servers" admin page: both nodes' health from the /metrics text they already serve (no Prometheus), with
 * simple thresholds and colours, the scheduled jobs' last runs and the backup age. MASTER_ADMIN only; nothing stored.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'srv.admin@coroute.test';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const { boot } = require('./_helpers');
const { Metrics } = require('../src/metrics');
const { ServerHealth, parseMetrics, nodeView, peerMetricsUrl } = require('../src/business/servers');
const { MemorySoda } = require('../src/oracle/memory_soda');

let env; let admin; let rider;
before(async () => {
  env = await boot();
  admin = await env.register('Servers Admin', 'srv.admin@coroute.test');
  rider = await env.register('A Rider', 'srv.rider@coroute.test');
});
after(async () => { await env.gw.shutdown(); });

const TEXT = (o = {}) => [
  '# HELP coroute_process_resident_memory_bytes Resident set size.', '# TYPE coroute_process_resident_memory_bytes gauge',
  `coroute_process_resident_memory_bytes ${(o.rssMb || 300) * 1048576}`,
  `coroute_process_heap_used_bytes ${(o.heapMb || 120) * 1048576}`, `coroute_process_heap_limit_bytes ${600 * 1048576}`,
  `coroute_process_uptime_seconds ${o.uptime || 7200}`,
  `coroute_event_loop_lag_ms{quantile="0.5"} 1`, `coroute_event_loop_lag_ms{quantile="0.99"} ${o.lag || 4}`, `coroute_event_loop_lag_ms{quantile="1"} ${(o.lag || 4) * 2}`,
  `coroute_ws_connections ${o.ws || 140}`, 'coroute_convoy_rooms_loaded 12',
  `coroute_db_calls_total{collection="users",op="get"} ${o.db || 1000}`, `coroute_db_calls_total{collection="alerts",op="insert"} 50`,
  `coroute_http_requests_total{method="GET",route="/api/me",status="2xx"} ${o.http || 5000}`, 'coroute_http_requests_total{method="GET",route="/api/x",status="5xx"} 3',
  `coroute_load_shed_total{route="/api/geo"} ${o.shed || 0}`, `coroute_load_shedding{mode="on"} ${o.shedding || 0}`,
  `coroute_mirror_up ${o.mirror === undefined ? 1 : o.mirror}`, `coroute_db_queue_length ${o.queue || 0}`,
  'coroute_node_info{node="vm1",role="live",version="3.55.0"} 1', '',
].join('\n');

test('parsing the Prometheus text: sums counters over labels, picks gauges, reads the node info', () => {
  const m = parseMetrics(TEXT({ db: 1000, http: 5000 }));
  assert.equal(m.dbCalls, 1050); assert.equal(m.httpRequests, 5003); assert.equal(m.http5xx, 3);
  assert.equal(m.wsConnections, 140); assert.equal(m.lagP99Ms, 4); assert.equal(m.lagMaxMs, 8);
  assert.deepEqual([m.node, m.role, m.version, m.mirrorUp], ['vm1', 'live', '3.55.0', true]);
  assert.deepEqual(parseMetrics('garbage\n\n# x\nname_without_value\n').dbCalls, 0, 'junk is ignored');
});

test('thresholds and colours: lag, memory, shedding, database queue, mirror link, rider cap; rates from two samples', () => {
  const at = 1_800_000_000_000;
  const ok = nodeView(parseMetrics(TEXT()), { at });
  assert.equal(ok.status, 'ok'); assert.deepEqual(ok.notes, []);
  assert.deepEqual([ok.ridersOnline, ok.rssMb, ok.memPct, ok.heapPct, ok.dbCallsPerSec], [140, 300, 29, 20, null]);
  const prev = { at: at - 10000, dbCalls: 550, dbErrors: 0, httpRequests: 4003, shedTotal: 0 };
  const rated = nodeView(parseMetrics(TEXT()), { at, prev });
  assert.equal(rated.dbCallsPerSec, 50); assert.equal(rated.httpPerSec, 100);
  assert.equal(nodeView(parseMetrics(TEXT({ db: 10 })), { at, prev }).dbCallsPerSec, null, 'a restart resets the counters: no negative rate');
  const cases = [
    [{ lag: 60 }, 'lag', 'warn'], [{ lag: 200 }, 'lag', 'bad'], [{ rssMb: 760 }, 'memory', 'warn'], [{ rssMb: 900 }, 'memory', 'bad'], [{ heapMb: 560 }, 'memory', 'bad'],
    [{ shedding: 1 }, 'shedding', 'bad'], [{ queue: 30 }, 'database', 'warn'], [{ queue: 150 }, 'database', 'bad'], [{ mirror: 0 }, 'mirror', 'warn'],
  ];
  for (const [o, check, want] of cases) {
    const v = nodeView(parseMetrics(TEXT(o)), { at });
    assert.equal(v.checks[check], want, JSON.stringify(o));
    assert.equal(v.status, want);
    assert.ok(v.notes.length >= 1 && v.notes.every((n) => typeof n === 'string' && n.length > 20), 'a plain-language note explains it');
  }
  assert.equal(nodeView(parseMetrics(TEXT({ shed: 9 })), { at, prev }).checks.shedding, 'warn', 'requests were shed since the last look');
  assert.equal(nodeView(parseMetrics(TEXT({ ws: 2450 })), { at, liveRiderCap: 2500 }).checks.riders, 'bad');
  assert.equal(nodeView(parseMetrics(TEXT({ ws: 2450 })), { at }).checks.riders, 'ok', 'no cap set: no colour');
});

test('the peer is read over HTTP with the metrics token; unreachable or refused peers are shown, never thrown', async () => {
  let seenAuth = null; let mode = 'ok';
  const peer = http.createServer((req, res) => {
    seenAuth = req.headers.authorization || null;
    if (mode === '404') { res.statusCode = 404; return res.end('{}'); }
    res.setHeader('Content-Type', 'text/plain'); res.end(TEXT({ lag: 70, ws: 3 }).replace('node="vm1",role="live"', 'node="vm2",role="web"'));
  });
  await new Promise((r) => peer.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${peer.address().port}/metrics`;
  const metrics = new Metrics({ loop: false });
  const soda = new MemorySoda();
  const sh = new ServerHealth({ metrics, soda, env: { PEER_METRICS_URL: url, METRICS_TOKEN: 'tok-123' }, node: 'vm1', role: 'live' });
  let snap = await sh.snapshot();
  assert.equal(seenAuth, 'Bearer tok-123');
  assert.equal(snap.nodes.length, 2);
  assert.deepEqual([snap.nodes[0].self, snap.nodes[0].node], [true, 'vm1']);
  assert.deepEqual([snap.nodes[1].node, snap.nodes[1].role, snap.nodes[1].status, snap.nodes[1].ridersOnline], ['vm2', 'web', 'warn', 3]);
  assert.equal(snap.status, 'warn', 'the page shows the worst colour');
  mode = '404';
  snap = await sh.snapshot();
  assert.equal(snap.nodes[1].reachable, false); assert.match(snap.nodes[1].error, /METRICS_ALLOW or METRICS_TOKEN/);
  await new Promise((r) => peer.close(r));
  snap = await sh.snapshot();
  assert.equal(snap.nodes[1].reachable, false); assert.equal(snap.nodes[1].status, 'bad'); assert.match(snap.nodes[1].error, /did not answer/);
  assert.ok(sh.prev.size <= 2, 'one small sample per node, nothing else kept');
  // Where the peer URL comes from.
  assert.equal(peerMetricsUrl({}, {}), null);
  assert.equal(peerMetricsUrl({}, { mirrorPeerUrl: 'ws://10.1.2.3:3101/mirror', port: 3000 }), 'http://10.1.2.3:3000/metrics');
  assert.equal(peerMetricsUrl({ PEER_METRICS_URL: 'ftp://x' }, {}), null);
  metrics.stop();
});

test('jobs and backups: last runs from the lease documents, overdue jobs and old or failed backups are coloured', async () => {
  const now = 1_800_000_000_000;
  const soda = new MemorySoda();
  const lease = { jobs: new Map([['retention', { intervalMs: 6 * 3600000 }], ['email-studio', { intervalMs: 60000 }], ['coupon-seed', { once: true }]]) };
  await soda.insert('leases', { name: 'retention', node: 'vm2', role: 'web', expiresAt: now + 1000, lastRunAt: now - 3600000, lastRunBy: 'vm2' });
  await soda.insert('leases', { name: 'email-studio', node: 'vm2', role: 'web', expiresAt: now + 1000, lastRunAt: now - 40 * 60000, lastRunBy: 'vm2' });
  await soda.insert('leases', { name: 'coupon-seed', node: 'vm1', role: 'live', expiresAt: now - 1000, lastRunAt: now - 90 * 86400000, lastRunBy: 'vm1' });
  const metrics = new Metrics({ loop: false });
  const sh = new ServerHealth({ metrics, soda, lease, env: {}, clock: () => now });
  const jobs = Object.fromEntries((await sh.jobs()).map((j) => [j.name, j]));
  assert.equal(jobs.retention.status, 'ok'); assert.equal(jobs.retention.lastRunBy, 'vm2');
  assert.equal(jobs['email-studio'].status, 'warn', 'a one-minute job that has not run for 40 minutes');
  assert.equal(jobs['coupon-seed'].status, 'ok', 'a run-once job is never overdue');
  assert.deepEqual(await sh.backup().then((b) => [b.known, b.status]), [false, 'warn']);
  await soda.insert('ops_status', { kind: 'backup', set: 'full', at: now - 5 * 3600000, ok: true, documents: 900 });
  await soda.insert('ops_status', { kind: 'backup', set: 'critical', at: now - 30 * 60000, ok: true, documents: 100 });
  assert.deepEqual(await sh.backup().then((b) => [b.known, b.status, b.fullAgeHours, b.criticalAgeHours]), [true, 'ok', 5, 0.5]);
  const row = await soda.findOne('ops_status', { set: 'full' });
  await soda.replace('ops_status', row.key, { ...row.value, at: now - 30 * 3600000 });
  assert.equal((await sh.backup()).status, 'warn');
  await soda.replace('ops_status', row.key, { ...row.value, at: now - 60 * 3600000 });
  assert.equal((await sh.backup()).status, 'bad');
  await soda.replace('ops_status', row.key, { ...row.value, at: now - 3600000, ok: false, error: 'PAR 403' });
  assert.equal((await sh.backup()).status, 'bad', 'a failed backup is red even when it is recent');
  metrics.stop();
});

test('the backup job reports its runs for the page', async () => {
  const { startBackupJobs } = require('../src/backup_jobs');
  const soda = new MemorySoda();
  await soda.insert('users', { userId: 'u1' });
  const objects = new Map();
  const store = { put: async (k, v) => { objects.set(k, v); }, get: async (k) => objects.get(k) || null, list: async () => [...objects.keys()].map((name) => ({ name })), remove: async (k) => objects.delete(k) };
  const jobs = startBackupJobs({ soda, store, logger: { info() {}, warn() {}, error() {} }, runner: () => ({ stop() {} }), env: { BACKUP_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString('base64') }, clock: () => 1_800_000_000_000 });
  assert.equal(jobs.enabled, true);
  await jobs.runNow('critical');
  const st = (await soda.findOne('ops_status', { kind: 'backup', set: 'critical' })).value;
  assert.deepEqual({ ok: st.ok, at: st.at }, { ok: true, at: 1_800_000_000_000 });
  assert.ok(st.documents >= 1);
  store.put = async () => { throw Object.assign(new Error('boom'), { code: 'PAR_403' }); };
  await assert.rejects(jobs.runNow('critical'));
  assert.equal((await soda.findOne('ops_status', { kind: 'backup', set: 'critical' })).value.ok, false);
  jobs.stop();
});

test('GET /api/admin/business/servers: this node from its own metrics, admin only; /metrics itself stays closed to the internet', async () => {
  assert.equal((await env.api('GET', '/admin/business/servers', null, null)).status, 401);
  assert.equal((await env.api('GET', '/admin/business/servers', null, rider.token)).status, 403);
  const r = await env.api('GET', '/admin/business/servers', null, admin.token);
  assert.equal(r.status, 200);
  const n = r.json.nodes[0];
  assert.equal(n.self, true); assert.equal(n.reachable, true);
  assert.equal(n.version, require('../package.json').version);
  assert.ok(n.rssMb > 10 && n.uptimeS >= 0 && n.ridersOnline === 0);
  assert.equal(n.mirrorUp, null, 'a single node has no mirror link to be down');
  assert.equal(r.json.peerConfigured, false); assert.equal(r.json.nodes.length, 1);
  assert.ok(Array.isArray(r.json.jobs) && r.json.backup && r.json.thresholds.lagMs.length === 2);
  await new Promise((res) => setTimeout(res, 20));
  const res = await fetch(`${env.origin}/metrics`, { headers: { 'X-Forwarded-For': '203.0.113.9' } });
  assert.ok([200, 404].includes(res.status));
  assert.match(await (await fetch(`${env.origin}/metrics`)).text(), /coroute_node_info\{node="[^"]+",role="all",version="[^"]+"\} 1/);
});
