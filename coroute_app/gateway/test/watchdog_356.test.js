'use strict';
/**
 * v3.56 uptime watchdog (deploy/watchdog/coroute_watchdog.js): real HTTP and WebSocket checks against a booted
 * gateway, one alert after N failures, one recovery mail, a daily summary, and automatic promotion only when
 * switched on and every required target has been down long enough.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { Watchdog, check, parseTargets } = require('../deploy/watchdog/coroute_watchdog');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('checks: /api/health HEALTHY, WebSocket upgrade 101, a dead port fails', async () => {
  const ok = await check({ name: 'h', kind: 'http', url: `${t.origin}/api/health` });
  assert.equal(ok.ok, true, ok.detail);
  const ws = await check({ name: 'w', kind: 'ws', url: `${t.wsBase.replace('ws:', 'ws:')}` });
  assert.equal(ws.ok, true, ws.detail);
  const dead = await check({ name: 'd', kind: 'http', url: 'http://127.0.0.1:9/api/health' }, { timeoutMs: 1000 });
  assert.equal(dead.ok, false);
  const notWs = await check({ name: 'x', kind: 'ws', url: `${t.origin}/api/meta` });
  assert.equal(notWs.ok, false);
});

test('one alert after 3 failures, one recovery, nothing in between', async () => {
  const mails = [];
  let now = Date.UTC(2026, 10, 12, 10, 0, 0);
  const wd = new Watchdog({ targets: parseTargets('vm1|http|http://x/api/health/live'), env: { WATCH_FAILS: '3' }, clock: () => now,
    mailer: async (s) => { mails.push(s); }, log: { info() {}, warn() {} } });
  let up = false;
  const checker = async () => ({ ok: up, ms: 5, detail: up ? 'HTTP 200' : 'ECONNREFUSED' });
  for (let i = 0; i < 5; i++) { await wd.round(checker); now += 30000; }
  assert.deepEqual(mails, ['[CoRoute] DOWN: vm1']);
  up = true;
  await wd.round(checker); await wd.round(checker);
  assert.deepEqual(mails, ['[CoRoute] DOWN: vm1', '[CoRoute] RECOVERED: vm1']);
});

test('daily summary once per day at the configured hour', async () => {
  const mails = [];
  let now = Date.UTC(2026, 10, 12, 2, 59, 0);
  const wd = new Watchdog({ targets: parseTargets('public|http|http://x/api/health'), env: { WATCH_SUMMARY_HOUR_UTC: '3', WATCH_BACKUP_STATUS: '/nonexistent' },
    clock: () => now, mailer: async (s, body) => { mails.push([s, body]); }, log: { info() {}, warn() {} } });
  const checker = async () => ({ ok: true, ms: 3, detail: 'HTTP 200' });
  await wd.round(checker);
  now += 60000; await wd.round(checker); now += 60000; await wd.round(checker);
  assert.equal(mails.length, 1);
  assert.match(mails[0][0], /daily summary 2026-11-12/);
  assert.match(mails[0][1], /public\s+100\.00% up/);
});

test('automatic promotion: off by default; when on, only after every required target is down long enough', async () => {
  let now = 0; let promoted = 0;
  const targets = parseTargets('public|http|http://x/a vm1|http|http://y/a vm2|http|http://z/a');
  const down = async () => ({ ok: false, ms: 1, detail: 'down' });
  const off = new Watchdog({ targets, env: {}, clock: () => now, runPromote: async () => { promoted++; }, log: { info() {}, warn() {} } });
  for (let i = 0; i < 60; i++) { await off.round(down); now += 30000; }
  assert.equal(promoted, 0, 'never without WATCH_AUTO_PROMOTE=1');
  now = 0;
  const on = new Watchdog({ targets, env: { WATCH_AUTO_PROMOTE: '1', WATCH_PROMOTE_AFTER_MIN: '10' }, clock: () => now, runPromote: async () => { promoted++; return 'ok'; }, log: { info() {}, warn() {} } });
  const vm2up = async (tg) => ({ ok: tg.name === 'vm2', ms: 1, detail: '' });
  for (let i = 0; i < 40; i++) { await on.round(vm2up); now += 30000; }
  assert.equal(promoted, 0, 'vm2 still serves: no promotion');
  for (let i = 0; i < 19; i++) { await on.round(down); now += 30000; }
  assert.equal(promoted, 0, 'not yet 10 minutes for vm2');
  for (let i = 0; i < 4; i++) { await on.round(down); now += 30000; }
  assert.equal(promoted, 1, 'promoted exactly once');
  for (let i = 0; i < 10; i++) { await on.round(down); now += 30000; }
  assert.equal(promoted, 1);
});
