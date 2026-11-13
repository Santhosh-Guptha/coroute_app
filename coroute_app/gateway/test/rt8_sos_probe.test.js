'use strict';
/**
 * Round 8 synthetic SOS probe (deploy/watchdog/sos_probe.js): schedule, alert / recovery mails and the daily summary
 * with a fake clock and an injected runner; the staging-only and probe-group-only guards; one real run against a
 * booted gateway (allowed host 127.0.0.1) measuring delivery between the two probe sockets.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const os = require('os');
const fs = require('fs');
const path = require('path');
const { boot } = require('./_helpers');
const { SosProbe, runProbeOnce, probeConfig, hostRefusal, groupRefusal, probeDevice } = require('../deploy/watchdog/sos_probe');
const { Watchdog, parseTargets } = require('../deploy/watchdog/coroute_watchdog');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rt8-probe-'));
const envOf = (extra = {}) => ({ WATCH_SOS_PROBE: '1', WATCH_SOS_PROBE_STATUS: path.join(tmp, 'p.json'), WATCH_SOS_PROBE_EVERY_MIN: '15', WATCH_SOS_PROBE_MAX_MS: '1000', ...extra });

test('schedule and mails with a fake clock: every 15 min; mail on the first bad run, hourly while bad, once on recovery', async () => {
  let now = Date.UTC(2026, 10, 13, 10, 0, 0);
  const results = [];
  const probe = new SosProbe({ env: envOf(), clock: () => now, runner: async () => results.shift(), log: { warn() {} } });
  results.push({ ok: true, ms: 120, detail: 'delivered in 120 ms' });
  const first = await probe.tick(now);
  assert.equal(first.mail, null);
  assert.equal(await probe.tick(now + 60000), null, 'not due within 15 min');
  const mails = [];
  const seq = [{ ok: false, ms: 1450, detail: 'slow: 1450 ms' }, { ok: false, ms: null, detail: 'timeout' }, { ok: false, ms: null, detail: 'timeout' },
    { ok: false, ms: null, detail: 'timeout' }, { ok: false, ms: null, detail: 'timeout' }, { ok: true, ms: 90, detail: 'delivered in 90 ms' }, { ok: true, ms: 95, detail: 'delivered in 95 ms' }];
  for (const r of seq) { now += 15 * 60000; results.push(r); const out = await probe.tick(now); if (out.mail) mails.push(out.mail.subject); }
  assert.deepEqual(mails, ['[CoRoute] SOS PROBE SLOW on staging', '[CoRoute] SOS PROBE FAILED on staging', '[CoRoute] SOS probe RECOVERED']);
  const status = JSON.parse(fs.readFileSync(path.join(tmp, 'p.json'), 'utf8'));
  assert.equal(status.kind, 'sos_probe');
  assert.equal(status.runs, 8); assert.equal(status.fails, 5);
  assert.equal(status.last.ok, true);
  const line = probe.summaryLine();
  assert.match(line, /^SOS probe: 8 runs, 5 failed or slower than 1000 ms; p50 \d+ ms, p95 \d+ ms, max 1450 ms; last ok/);
  assert.match(probe.summaryLine(), /0 runs/, 'the day\'s counters reset after the summary');
  assert.equal(new SosProbe({ env: {} }).due(now), false, 'off unless WATCH_SOS_PROBE=1');
});

test('the watchdog runs the probe on its own schedule and puts it in the daily summary', async () => {
  let now = Date.UTC(2026, 10, 13, 2, 50, 0);
  const subjects = []; const texts = [];
  const probe = new SosProbe({ env: envOf(), clock: () => now, runner: async () => ({ ok: true, ms: 80, detail: 'delivered in 80 ms' }), log: { warn() {} } });
  const wd = new Watchdog({ targets: parseTargets('vm1|http|http://x/api/health/live'), env: { WATCH_SUMMARY_HOUR_UTC: '3' }, clock: () => now, probe,
    mailer: async (s, t) => { subjects.push(s); texts.push(t); }, log: { info() {}, warn() {} } });
  const ev = await wd.round(async () => ({ ok: true, ms: 5, detail: 'HTTP 200' }));
  assert.ok(ev.some((e) => e.type === 'SOS_PROBE' && e.ok && e.ms === 80));
  now += 30000;
  assert.ok(!(await wd.round(async () => ({ ok: true, ms: 5, detail: 'HTTP 200' }))).some((e) => e.type === 'SOS_PROBE'), 'not every 30 s');
  now = Date.UTC(2026, 10, 13, 3, 1, 0);
  await wd.round(async () => ({ ok: true, ms: 5, detail: 'HTTP 200' }));
  const i = subjects.findIndex((s) => s.startsWith('[CoRoute] daily summary'));
  assert.ok(i >= 0);
  assert.match(texts[i], /SOS probe: 1 runs, 0 failed/, 'one run: 11 min after the first, the second is not due yet');
});

test('guards: staging hosts only; the probe group must be named "SOS probe ..." and hold only the two probe accounts', async () => {
  assert.match(hostRefusal(probeConfig({ WATCH_SOS_PROBE_URL: 'wss://coroute.devmonks.space/ws' })), /not a staging host/);
  assert.equal(hostRefusal(probeConfig({ WATCH_SOS_PROBE_URL: 'wss://staging.coroute.devmonks.space/ws', WATCH_SOS_PROBE_API: 'https://staging.coroute.devmonks.space/api' })), '');
  assert.match(hostRefusal(probeConfig({ WATCH_SOS_PROBE_URL: 'wss://staging.x/ws', WATCH_SOS_PROBE_API: 'https://coroute.devmonks.space/api' })), /same host/);
  assert.equal(groupRefusal({ name: 'SOS probe staging', riders: { a: {}, b: {} } }, ['a', 'b']), '');
  assert.match(groupRefusal({ name: 'Sunday ride', riders: { a: {}, b: {} } }, ['a', 'b']), /not a probe group/);
  assert.match(groupRefusal({ name: 'SOS probe', riders: { a: {}, b: {}, c: {} } }, ['a', 'b']), /1 rider\(s\) besides/);
  const r = await runProbeOnce(probeConfig({ WATCH_SOS_PROBE_URL: 'wss://coroute.devmonks.space/ws' }));
  assert.equal(r.ok, false); assert.equal(r.refused, true);
});

let t;
before(async () => { t = await boot({ emergencyFetch: async () => { throw new Error('offline in tests'); } }); });
after(async () => { await t.gw.shutdown(); fs.rmSync(tmp, { recursive: true, force: true }); });

test('a real probe run against a local gateway: two sockets, SOS delivered and resolved, delivery time measured', async () => {
  await t.register('Probe A', 'probe-a@coroute.test');
  await t.register('Probe B', 'probe-b@coroute.test');
  // One-time staging setup (RUNBOOK "SOS probe"): the group is created and joined from the probe's own device identity,
  // so the ride lock sees the probe's later sign-ins as the same device.
  const asProbe = async (email) => (await t.api('POST', '/auth/login', { identifier: email, password: 'Password#123', device: probeDevice(email) })).json.token;
  const ta = await asProbe('probe-a@coroute.test'); const tb = await asProbe('probe-b@coroute.test');
  const c = (await t.api('POST', '/convoys', { name: 'SOS probe local' }, ta)).json;
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, tb)).status, 200);
  const cfg = probeConfig({ WATCH_SOS_PROBE_URL: t.wsBase, WATCH_SOS_PROBE_API: t.base, WATCH_SOS_PROBE_GROUP: c.groupId, WATCH_SOS_PROBE_EMAIL_A: 'probe-a@coroute.test',
    WATCH_SOS_PROBE_EMAIL_B: 'probe-b@coroute.test', WATCH_SOS_PROBE_PASSWORD: 'Password#123', WATCH_SOS_PROBE_ALLOW_HOST: '127.0.0.1', WATCH_SOS_PROBE_MAX_MS: '1000' });
  const r = await runProbeOnce(cfg);
  assert.equal(r.ok, true, r.detail);
  assert.ok(Number.isFinite(r.ms) && r.ms < 1000, `${r.ms} ms`);
  const alerts = await t.gw.repo.listAlerts(c.groupId, { includeResolved: true });
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].resolved, true, 'the probe resolves its SOS');
  assert.equal(alerts[0].clientSentSms, true, 'the server never texts anyone for a probe');
  // A third rider in the group: the probe refuses (never production riders).
  const x = await t.register('Probe Stranger', 'probe-x@coroute.test');
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, x.token)).status, 200);
  const refused = await runProbeOnce(cfg);
  assert.equal(refused.ok, false); assert.equal(refused.refused, true);
  assert.equal((await t.gw.repo.listAlerts(c.groupId, { includeResolved: true })).length, 1, 'no SOS raised when refused');
});
