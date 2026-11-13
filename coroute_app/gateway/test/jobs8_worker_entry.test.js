'use strict';
/**
 * Round 8: the separate worker process (gateway/worker.js) next to a gateway on the same database: the gateway (with
 * WORKER_INPROCESS=off) only enqueues, the worker sends; health endpoints; it never takes a job lease or serves riders;
 * SIGTERM-style stop drains and hands unfinished jobs back.
 */
process.env.NODE_ENV = 'test';
process.env.JOBS_QUEUE = 'on';
process.env.WORKER_INPROCESS = 'off';
process.env.JOBS_POLL_MIN_MS = '15';
process.env.JOBS_POLL_MAX_MS = '60';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.PUBLIC_ORIGIN = 'https://coroute.example';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { startWorker } = require('../worker');

const quiet = { info() {}, warn() {}, error() {} };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mails = [];
const mailTransport = { async sendMail(m) { mails.push(m); return { messageId: `<w${mails.length}@test>` }; } };
async function until(fn, ms = 3000) { const t0 = Date.now(); for (;;) { const v = await fn(); if (v) return v; if (Date.now() - t0 > ms) return v; await sleep(10); } }

let soda, t, w, healthBase;
before(async () => {
  soda = new MemorySoda();
  t = await boot({ soda, mailTransport });
  t.gw.app.locals.jobs.start();
  w = await startWorker({ logger: quiet, env: { WORKER_HEALTH_PORT: '0', WORKER_HEALTH_HOST: '127.0.0.1' }, appOptions: { soda, mailTransport } });
  healthBase = `http://127.0.0.1:${w.server.address().port}`;
});
after(async () => { await w.stop().catch(() => {}); await t.gw.app.locals.jobs.stop({ drainMs: 0 }); await t.gw.shutdown(); });

test('the gateway with WORKER_INPROCESS=off only enqueues; the separate worker sends the welcome e-mail', async () => {
  assert.equal(t.gw.app.locals.jobs.worker, null, 'no worker inside this gateway');
  assert.equal(w.jobs.mode, 'separate');
  assert.equal(w.jobs.worker.mode, 'separate');
  const r = await t.register('Worker Rider', 'worker.rider@coroute.test');
  await t.gw.notifications.lifecycle.idle();
  const sent = await until(() => mails.find((m) => m.to === 'worker.rider@coroute.test'));
  assert.ok(sent, 'sent by the worker process');
  assert.match(sent.subject, /^Welcome to CoRoute/);
  const [log] = (await soda.query('mail_log', { key: `welcome:${r.user.userId}` }, { limit: 2 })).map((x) => x.value);
  assert.equal(log.status, 'SENT');
  assert.ok(log.worker === null);
});

test('worker health: /health 200 with its status, /health/queue reports depth and alerts, /metrics for loopback', async () => {
  const h = await fetch(`${healthBase}/health`);
  assert.equal(h.status, 200);
  const hj = await h.json();
  assert.equal(hj.status, 'working');
  assert.equal(hj.worker.mode, 'separate');
  assert.ok(hj.worker.families.includes('email') && hj.worker.families.includes('batch'), 'leased batch handlers exist on the worker');
  const q = await fetch(`${healthBase}/health/queue`);
  const qj = await q.json();
  assert.equal(q.status, qj.alert ? 503 : 200);
  assert.equal(typeof qj.oldestDueAgeS, 'number');
  assert.ok(Array.isArray(qj.workers));
  const m = await fetch(`${healthBase}/metrics`);
  assert.equal(m.status, 200);
  assert.match(await m.text(), /coroute_jobs_enabled\{mode="separate"\} 1/);
  assert.equal((await fetch(`${healthBase}/api/health`)).status, 404, 'the worker serves no gateway routes');
});

test('the worker never takes a job lease and never schedules the leased batches itself', async () => {
  const lease = w.gw.lease;
  assert.equal(lease.registerOnly, true);
  assert.ok(lease.names.includes('business-nightly') || lease.names.includes('lifecycle-mail'), `recorded ${lease.names.join(',')}`);
  const holders = (await soda.query('leases', {}, { limit: 200 })).map((x) => x.value.node);
  assert.ok(holders.every((n) => n !== 'worker'), 'no lease rows from the worker');
});

test('the queue alert turns /health/queue into 503 (watchdog target); stop() drains and hands unfinished jobs back', async () => {
  w.jobs.cfg.alertDead = 1;
  await soda.insert('job_dead', { jobId: 'j_dddddddddddddddddddd', type: 'email.receipt', state: 'dead', deadAt: Date.now(), attempts: 5 });
  w.jobs.queue._summary = null;
  const q = await fetch(`${healthBase}/health/queue`);
  assert.equal(q.status, 503);
  assert.ok((await q.json()).alerts.some((a) => a.startsWith('DEAD_LETTERS')));
  // A job that is still running when the worker stops goes back to the queue.
  let release;
  w.jobs.register('batch.slow_entry', async (p, { signal }) => { await new Promise((r) => { release = r; signal.addEventListener('abort', r); }); });
  await w.jobs.enqueue('batch.slow_entry', {});
  await until(() => release);
  w.jobs.cfg.drainMs = 100;
  await w.stop();
  const h = await fetch(`${healthBase}/health`).catch(() => null);
  assert.equal(h, null, 'the health server is closed');
  const [row] = (await soda.query('job_queue', { type: 'batch.slow_entry' }, { limit: 1 })).map((x) => x.value);
  assert.equal(row.state, 'queued'); assert.equal(row.attempts, 0);
  assert.equal((await soda.query('job_workers', {}, { limit: 10 })).filter((x) => x.value.role === 'worker').length, 0, 'heartbeat row removed');
});
