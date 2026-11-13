'use strict';
/**
 * Round 8 job queue (src/jobs/queue.js) and capacity-aware worker (src/jobs/worker.js, capacity.js):
 * exactly-once claim under concurrent workers (MemorySoda race AND the JSON Patch the REST client emits), lease expiry
 * reclaim, retries with backoff + jitter, dead letters, idempotent enqueue, payload bound, sealed payloads, TTL
 * cleanup, capacity backoff, idle backoff + wake-up, graceful drain, memory bounds.
 */
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { SodaClient } = require('../src/oracle/soda');
const { JobQueue, QUEUE_COLLECTION, DEAD_COLLECTION } = require('../src/jobs/queue');
const { JobWorker } = require('../src/jobs/worker');
const { CapacityMonitor } = require('../src/jobs/capacity');
const { RetryLater, Defer, PermanentError } = require('../src/jobs/errors');
const { Jobs, parseConcurrency, MAX_PENDING_FALLBACKS } = require('../src/jobs');
const { inJob } = require('../src/jobs/context');

const quiet = { info() {}, warn() {}, error() {} };
const SEAL = Buffer.alloc(32, 7);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** MemorySoda whose compare-and-replace yields first (interleaves concurrent claimers) and can run a hook once. */
class RaceSoda extends MemorySoda {
  constructor() { super(); this.beforeCas = null; this.casCalls = 0; }
  async _casApply(c, k, patch) {
    this.casCalls++;
    await new Promise((r) => setImmediate(r));
    const h = this.beforeCas;
    if (h) { this.beforeCas = null; await h(c, k); }
    return super._casApply(c, k, patch);
  }
}

function clockAt(t0 = 1_000_000) { const c = { t: t0 }; c.now = () => c.t; return c; }
const newQueue = (soda, extra = {}) => new JobQueue({ soda, logger: quiet, sealKey: SEAL, ...extra });
const rows = async (soda, coll = QUEUE_COLLECTION) => (await soda.query(coll, {}, { limit: 1000 })).map((r) => r.value);

// ---------------------------------------------------------------- exactly-once claim
test('exactly-once claim: 5 workers racing over 60 jobs on one database claim each job exactly once', async () => {
  const soda = new RaceSoda();
  const enq = newQueue(soda);
  for (let i = 0; i < 60; i++) await enq.enqueue('email.test', { i }, { priority: i % 3 });
  const workers = Array.from({ length: 5 }, () => newQueue(soda));
  const seen = new Map();
  await Promise.all(workers.map(async (q, w) => {
    for (let guard = 0; guard < 200; guard++) {
      const got = await q.claim(`w${w}`, { limit: 4 });
      if (!got.length) { if (!(await soda.query(QUEUE_COLLECTION, { state: 'queued' }, { limit: 1 })).length) return; continue; }
      for (const j of got) { seen.set(j.doc.jobId, (seen.get(j.doc.jobId) || 0) + 1); await q.complete(j); }
    }
  }));
  assert.equal(seen.size, 60);
  assert.ok([...seen.values()].every((n) => n === 1), 'no job was claimed twice');
  const conflicts = workers.reduce((a, q) => a + q.stats.claimConflicts, 0);
  assert.ok(conflicts > 0, `the race really happened (${conflicts} lost claims)`);
  assert.ok((await rows(soda)).every((d) => d.state === 'done' && d.payload === null));
});

test('exactly-once claim: a competitor that claims between our read and our compare-and-replace wins; we get nothing', async () => {
  const soda = new RaceSoda();
  const a = newQueue(soda); const b = newQueue(soda);
  await a.enqueue('push.test', { n: 1 });
  let bGot = null;
  soda.beforeCas = async () => { const got = await b.claim('B', { limit: 1 }); bGot = got[0]; };
  const aGot = await a.claim('A', { limit: 1 });
  assert.equal(aGot.length, 0);
  assert.ok(bGot && bGot.doc.leaseOwner === 'B');
  assert.equal(a.stats.claimConflicts, 1);
  const [doc] = await rows(soda);
  assert.equal(doc.state, 'running'); assert.equal(doc.leaseOwner, 'B'); assert.equal(doc.attempts, 1);
});

test('REST client: the claim is ONE JSON Patch testing casRev + state (+ every scalar) then replacing; a 412 is a lost race', async () => {
  const calls = [];
  const stored = { jobId: 'j_00000000000000000000', key: 'k1', type: 'email.test', family: 'email', payload: { a: 1 }, priority: 5, runAt: 10, state: 'queued',
    attempts: 0, maxAttempts: 5, leaseOwner: null, leaseUntil: 0, leaseMs: 60000, deleteOnDone: false, lastError: null, createdAt: 1, updatedAt: 1, casRev: 'rev-1' };
  let patchStatus = 200;
  const soda = new SodaClient({ baseUrl: 'https://example.test', user: 'u', password: 'p', maxInFlight: 0,
    fetchImpl: async (url, o) => {
      const call = { url, method: o.method, type: o.headers['Content-Type'], body: o.body ? JSON.parse(o.body) : undefined };
      calls.push(call);
      if (o.method === 'POST' && url.includes('action=query')) return new Response(JSON.stringify({ items: [{ id: 'K1', value: stored }] }), { status: 200 });
      if (o.method === 'PATCH') return new Response('', { status: patchStatus });
      return new Response('{}', { status: 200 });
    } });
  const q = new JobQueue({ soda, logger: quiet, sealKey: SEAL, clock: () => 20 });
  q.ready = Promise.resolve();
  const [job] = await q.claim('nodeA:1', { limit: 1 });
  const query = calls.find((c) => c.url.includes('action=query'));
  assert.deepEqual(query.body.$query, { state: 'queued', runAt: { $lte: 20 } });
  assert.deepEqual(query.body.$orderby.map((o) => [o.path, o.datatype, o.order]), [['priority', 'number', 'asc'], ['runAt', 'number', 'asc']]);
  const patch = calls.find((c) => c.method === 'PATCH');
  assert.equal(patch.type, 'application/json-patch+json');
  assert.match(patch.url, /\/job_queue\/K1$/);
  const tests = patch.body.filter((op) => op.op === 'test');
  assert.deepEqual(tests.find((t) => t.path === '/casRev'), { op: 'test', path: '/casRev', value: 'rev-1' });
  assert.deepEqual(tests.find((t) => t.path === '/state'), { op: 'test', path: '/state', value: 'queued' });
  assert.deepEqual(tests.find((t) => t.path === '/attempts'), { op: 'test', path: '/attempts', value: 0 });
  assert.ok(!tests.some((t) => t.path === '/payload'), 'objects are not tested (casRev covers them)');
  const last = patch.body[patch.body.length - 1];
  assert.equal(last.op, 'replace'); assert.equal(last.path, '');
  assert.equal(last.value.state, 'running'); assert.equal(last.value.leaseOwner, 'nodeA:1'); assert.equal(last.value.attempts, 1);
  assert.equal(last.value.leaseUntil, 20 + 60000);
  assert.ok(last.value.casRev && last.value.casRev !== 'rev-1', 'a fresh revision is written');
  assert.equal(job.doc.casRev, last.value.casRev);
  // The database refuses the precondition (another worker won): no job, counted as a conflict.
  patchStatus = 412;
  assert.deepEqual(await q.claim('nodeB:1', { limit: 1 }), []);
  assert.equal(q.stats.claimConflicts, 1);
});

// ---------------------------------------------------------------- leases
test('lease expiry: a dead worker\'s job is reclaimed, claimed by another worker, and the late finisher cannot overwrite it', async () => {
  const soda = new MemorySoda(); const c = clockAt();
  const q = newQueue(soda, { clock: c.now });
  await q.enqueue('batch.test', {}, { leaseMs: 10000 });
  const [a] = await q.claim('dead-worker', { limit: 1 });
  c.t += 5000;
  assert.equal(await q.reclaimExpired(), 0, 'not expired yet');
  assert.equal(await q.renew(a, 10000), true, 'the holder can renew');
  c.t += 10001;
  assert.equal(await q.reclaimExpired(), 1);
  let [doc] = await rows(soda);
  assert.equal(doc.state, 'queued'); assert.equal(doc.lastError, 'LEASE_EXPIRED'); assert.equal(doc.attempts, 1, 'the attempt stays spent');
  const [b] = await q.claim('live-worker', { limit: 1 });
  assert.equal(b.doc.attempts, 2);
  assert.equal(await q.complete(a), false, 'the old holder lost the job');
  assert.equal(await q.renew(a, 10000), false);
  assert.equal(await q.complete(b), true);
  [doc] = await rows(soda);
  assert.equal(doc.state, 'done');
});

test('lease expiry: a job that kills its worker every time ends in the dead-letter queue (no endless loop)', async () => {
  const soda = new MemorySoda(); const c = clockAt();
  const q = newQueue(soda, { clock: c.now });
  await q.enqueue('batch.crashy', {}, { maxAttempts: 2, leaseMs: 1000 });
  for (let i = 0; i < 2; i++) { assert.equal((await q.claim(`w${i}`)).length, 1); c.t += 1001; await q.reclaimExpired(); }
  assert.equal((await rows(soda)).length, 0);
  const [dead] = await rows(soda, DEAD_COLLECTION);
  assert.equal(dead.lastError, 'LEASE_EXPIRED'); assert.equal(dead.attempts, 2);
});

// ---------------------------------------------------------------- retries, backoff, dead letters
test('retries: exponential backoff with jitter (bounds), RetryLater delay, Defer keeps the attempt, dead letter after maxAttempts', async () => {
  const soda = new MemorySoda(); const c = clockAt();
  let rnd = 0;
  const q = newQueue(soda, { clock: c.now, random: () => rnd, backoffBaseMs: 1000, backoffMaxMs: 8000 });
  assert.deepEqual([1, 2, 3, 4, 5, 6].map((n) => q.backoffMs(n)), [500, 1000, 2000, 4000, 4000, 4000]);
  rnd = 0.999999;
  assert.deepEqual([1, 2, 3, 4, 5].map((n) => q.backoffMs(n)), [1000, 2000, 4000, 8000, 8000]);
  rnd = 0.5;
  await q.enqueue('email.flaky', { x: 1 }, { maxAttempts: 4 });
  let [j] = await q.claim('w');
  assert.equal(await q.fail(j, new Error('SMTP 421 for someone@example.test')), 'retry');
  let [doc] = await rows(soda);
  assert.equal(doc.state, 'queued'); assert.equal(doc.runAt, c.t + 750); assert.equal(doc.attempts, 1);
  assert.ok(!doc.lastError.includes('someone@example.test'), `error text is redacted: ${doc.lastError}`);
  assert.equal((await q.claim('w')).length, 0, 'not due before the backoff');
  c.t += 750;
  [j] = await q.claim('w');
  assert.equal(await q.fail(j, new RetryLater(60000)), 'retry');
  [doc] = await rows(soda);
  assert.equal(doc.runAt, c.t + 60000); assert.equal(doc.attempts, 2);
  c.t += 60000;
  [j] = await q.claim('w');
  assert.equal(await q.fail(j, new Defer(30000)), 'deferred');
  [doc] = await rows(soda);
  assert.equal(doc.attempts, 2, 'a deferral spends no attempt'); assert.equal(doc.runAt, c.t + 30000);
  c.t += 30000;
  [j] = await q.claim('w'); assert.equal(await q.fail(j, new Error('again')), 'retry');
  c.t += 10 * 60000;
  [j] = await q.claim('w'); assert.equal(j.doc.attempts, 4);
  assert.equal(await q.fail(j, new Error('last')), 'dead');
  assert.equal((await rows(soda)).length, 0, 'moved out of the queue');
  const dead = await q.listDead();
  assert.equal(dead.length, 1); assert.equal(dead[0].type, 'email.flaky'); assert.equal(dead[0].attempts, 4); assert.deepEqual(dead[0].payload, { x: 1 });
  // Admin retry: back with fresh attempts; discard of another.
  assert.equal(await q.retryDead(dead[0].jobId), 'retried');
  [doc] = await rows(soda);
  assert.equal(doc.state, 'queued'); assert.equal(doc.attempts, 0);
  [j] = await q.claim('w');
  assert.equal(await q.fail(j, new PermanentError('bad address')), 'dead', 'a permanent error is not retried');
  const again = await q.listDead();
  assert.equal(await q.discardDead(again[0].jobId), true);
  assert.equal((await q.listDead()).length, 0);
  assert.equal(await q.retryDead('j_ffffffffffffffffffff'), 'not_found');
});

// ---------------------------------------------------------------- idempotency, payloads
test('idempotent enqueue: the same key twice is one job; rearm puts a finished job back, never a pending one twice', async () => {
  const soda = new MemorySoda();
  const q = newQueue(soda);
  const a = await q.enqueue('email.receipt', { orderId: 'o1' }, { key: 'mail:receipt:o1' });
  const b = await q.enqueue('email.receipt', { orderId: 'o1' }, { key: 'mail:receipt:o1' });
  assert.equal(a.duplicate, false); assert.equal(b.duplicate, true); assert.equal(b.jobId, a.jobId);
  assert.equal((await rows(soda)).length, 1);
  const r1 = await q.enqueue('batch.tick', {}, { key: 'lease:x', rearm: true });
  const r2 = await q.enqueue('batch.tick', {}, { key: 'lease:x', rearm: true });
  assert.equal(r2.duplicate, true, 'still queued: no second run');
  const [j] = await q.claim('w', { families: ['batch'] });
  assert.equal(j.doc.jobId, r1.jobId);
  assert.equal((await q.enqueue('batch.tick', {}, { key: 'lease:x', rearm: true })).duplicate, true, 'running: no second run');
  await q.complete(j);
  const r3 = await q.enqueue('batch.tick', {}, { key: 'lease:x', rearm: true });
  assert.equal(r3.rearmed, true); assert.equal(r3.jobId, r1.jobId);
  const doc = (await rows(soda)).find((d) => d.key === 'lease:x');
  assert.equal(doc.state, 'queued'); assert.equal(doc.attempts, 0);
  assert.equal((await rows(soda)).filter((d) => d.key === 'lease:x').length, 1);
});

test('payloads are bounded; sealed payloads are encrypted at rest, opened on the worker and removed when done', async () => {
  const soda = new MemorySoda();
  const q = newQueue(soda, { maxPayloadBytes: 1024 });
  await assert.rejects(q.enqueue('email.big', { blob: 'x'.repeat(2000) }), (e) => e.code === 'PAYLOAD_TOO_LARGE');
  await assert.rejects(q.enqueue('Bad Type', {}), (e) => e.code === 'BAD_TYPE');
  assert.equal((await rows(soda)).length, 0);
  await q.enqueue('email.security', { to: 'rider@example.test', code: '493817' }, { sealed: true, priority: 0 });
  const [doc] = await rows(soda);
  const raw = JSON.stringify(doc);
  assert.ok(!raw.includes('493817') && !raw.includes('rider@example.test'), 'no plaintext code or address in the row');
  assert.match(doc.payload.$sealed, /^v1\./);
  assert.equal(doc.deleteOnDone, true);
  const [j] = await q.claim('w');
  assert.deepEqual(q.open(j), { to: 'rider@example.test', code: '493817' });
  const wrongKey = newQueue(soda, { sealKey: Buffer.alloc(32, 9) });
  assert.throws(() => wrongKey.open(j));
  await q.complete(j);
  assert.equal((await rows(soda)).length, 0, 'a done sealed job leaves nothing behind');
  const noKey = new JobQueue({ soda, logger: quiet, env: {} });
  await assert.rejects(noKey.enqueue('email.security', { a: 1 }, { sealed: true }), (e) => e.code === 'NO_SEAL_KEY');
});

test('TTL cleanup removes old finished rows and old dead letters only', async () => {
  const soda = new MemorySoda(); const c = clockAt();
  const q = newQueue(soda, { clock: c.now, doneTtlMs: 1000, deadTtlMs: 5000 });
  await q.enqueue('email.aa', {}); await q.enqueue('email.bb', {}, { maxAttempts: 1 }); await q.enqueue('email.cc', {});
  const got = await q.claim('w', { limit: 3 });
  for (const j of got) { if (j.doc.type === 'email.bb') await q.fail(j, new Error('x')); else if (j.doc.type === 'email.aa') await q.complete(j); }
  c.t += 1500;
  let out = await q.cleanup();
  assert.equal(out.done, 1); assert.equal(out.dead, 0);
  assert.deepEqual((await rows(soda)).map((d) => d.type), ['email.cc']);
  c.t += 5000;
  out = await q.cleanup();
  assert.equal(out.dead, 1);
  assert.equal((await rows(soda, DEAD_COLLECTION)).length, 0);
});

// ---------------------------------------------------------------- worker: capacity, backoff, drain
function registry(defs) {
  const m = new Map();
  for (const [type, handler, o = {}] of defs) m.set(type, { type, family: type.split('.')[0], handler, leaseMs: 60000, timeoutMs: 0, backoffBaseMs: 10, ...o });
  return m;
}

test('worker: runs handlers inside the job context, honours per-family concurrency, and backs off when the box is busy', async () => {
  const soda = new MemorySoda();
  const q = newQueue(soda);
  let running = 0; let peak = 0; const release = [];
  const reg = registry([['email.slow', async () => { running++; peak = Math.max(peak, running); assert.equal(inJob(), true); await new Promise((r) => release.push(r)); running--; }]]);
  let sample = { lagMs: 0, loadPerCore: 0.1, memFreePct: 80, dbInflight: 0, dbBudget: 10, dbQueue: 0 };
  const capacity = new CapacityMonitor({ sample: () => sample });
  const w = new JobWorker({ queue: q, registry: reg, concurrency: { email: 3 }, capacity, logger: quiet, pollMinMs: 10, pollMaxMs: 40 });
  for (let i = 0; i < 8; i++) await q.enqueue('email.slow', { i });
  w.start();
  await sleep(120);
  assert.equal(peak, 3, 'never more than the family concurrency');
  assert.equal(w.status().runningTotal, 3);
  // Busy: event-loop lag over the high mark -> factor 0 -> no new work even when slots free up.
  sample = { ...sample, lagMs: 250 };
  release.splice(0).forEach((r) => r());
  await sleep(150);
  assert.equal(w.status().runningTotal, 0, 'running jobs finished, nothing new taken');
  assert.equal(w.status().capacity.reason, 'lag');
  assert.equal((await soda.query(QUEUE_COLLECTION, { state: 'queued' }, { limit: 100 })).length, 5);
  // Half busy (CPU between warn and high): floor(3 * 0.5) = 1 at a time.
  sample = { ...sample, lagMs: 0, loadPerCore: 1.2 };
  await sleep(120);
  assert.equal(w.status().runningTotal, 1);
  assert.equal(w.status().capacity.factor, 0.5);
  // The database budget is nearly used up by the gateway: stop taking work.
  sample = { ...sample, loadPerCore: 0.1, dbInflight: 9 };
  release.splice(0).forEach((r) => r());
  await sleep(120);
  assert.equal(w.status().runningTotal, 0);
  assert.equal(w.status().capacity.reason, 'db');
  // Idle again: takes up to 3.
  sample = { ...sample, dbInflight: 0 };
  await sleep(120);
  assert.equal(w.status().runningTotal, 3);
  release.splice(0).forEach((r) => r());
  await sleep(100); release.splice(0).forEach((r) => r());
  await w.idle();
  await w.stop({ drainMs: 0 });
  assert.equal((await soda.query(QUEUE_COLLECTION, { state: 'done' }, { limit: 100 })).length, 8);
});

test('worker: a busy worker still takes ONE urgent (priority 0) job; capacity factor levels', async () => {
  const soda = new MemorySoda();
  const q = newQueue(soda);
  const ran = [];
  const reg = registry([['email.security', async (p) => { ran.push(p.n); }], ['email.bulk', async (p) => { ran.push(p.n); }]]);
  const capacity = new CapacityMonitor({ sample: () => ({ lagMs: 500, loadPerCore: 3, memFreePct: 5, dbInflight: 0, dbBudget: 10, dbQueue: 2 }) });
  assert.equal(capacity.factor().factor, 0);
  await q.enqueue('email.bulk', { n: 'bulk' }, { priority: 5 });
  await q.enqueue('email.security', { n: 'code' }, { priority: 0 });
  const w = new JobWorker({ queue: q, registry: reg, capacity, logger: quiet, pollMinMs: 10, pollMaxMs: 20 }).start();
  await sleep(100);
  await w.stop({ drainMs: 0 });
  assert.deepEqual(ran, ['code']);
  const lv = (s) => new CapacityMonitor({ sample: () => ({ lagMs: 0, loadPerCore: 0, memFreePct: 90, dbInflight: 0, dbBudget: 10, dbQueue: 0, ...s }) }).factor();
  assert.equal(lv({}).factor, 1);
  assert.deepEqual([lv({ lagMs: 50 }).factor, lv({ lagMs: 50 }).reason], [0.5, 'lag']);
  assert.deepEqual([lv({ memFreePct: 15 }).factor, lv({ memFreePct: 15 }).reason], [0.5, 'memory']);
  assert.deepEqual([lv({ memFreePct: 8 }).factor, lv({ memFreePct: 8 }).reason], [0, 'memory']);
  assert.deepEqual([lv({ dbInflight: 6 }).factor, lv({ dbQueue: 1 }).factor], [0.5, 0]);
  assert.equal(lv({ loadPerCore: 2 }).factor, 0);
});

test('worker: idle polling backs off 2x up to the max; a local enqueue wakes it at once', async () => {
  const soda = new MemorySoda();
  const q = newQueue(soda);
  let queries = 0;
  const orig = soda.query.bind(soda);
  soda.query = (...a) => { if (a[0] === QUEUE_COLLECTION) queries++; return orig(...a); };
  const done = [];
  const jobs = new Jobs({ soda, logger: quiet, options: { queue: true, pollMinMs: 20, pollMaxMs: 320, inprocess: 'on' }, queue: q,
    capacity: new CapacityMonitor({ sample: () => ({ lagMs: 0, loadPerCore: 0, memFreePct: 90, dbInflight: 0, dbBudget: 10, dbQueue: 0 }) }) });
  jobs.register('email.ping', async (p) => { done.push(p.n); });
  jobs.start();
  await sleep(700);
  const delay = jobs.worker.status().pollDelayMs;
  assert.equal(delay, 320, 'idle backoff reached the max');
  assert.ok(queries <= 12, `idle polls stay few (${queries} queries in 0.7 s)`);
  const t0 = Date.now();
  await jobs.enqueue('email.ping', { n: 1 });
  while (!done.length && Date.now() - t0 < 2000) await sleep(5);
  assert.deepEqual(done, [1]);
  assert.ok(Date.now() - t0 < 200, `woken at once (${Date.now() - t0} ms), not after the 320 ms idle delay`);
  await jobs.stop();
});

test('worker: graceful drain finishes what it can and hands the rest back to the queue (attempt not spent)', async () => {
  const soda = new MemorySoda();
  const q = newQueue(soda);
  const reg = registry([
    ['batch.quick', async () => { await sleep(20); }],
    ['batch.stuck', async (p, { signal }) => { await new Promise((r) => signal.addEventListener('abort', r)); }],
  ]);
  await q.enqueue('batch.quick', {}); await q.enqueue('batch.stuck', {});
  const w = new JobWorker({ queue: q, registry: reg, concurrency: { batch: 2 }, logger: quiet, pollMinMs: 10 }).start();
  await sleep(10);
  while (w.status().runningTotal < 2 && !(await soda.query(QUEUE_COLLECTION, { state: 'done' }, { limit: 1 })).length) await sleep(5);
  const out = await w.stop({ drainMs: 150 });
  assert.equal(out.released, 1);
  const docs = await rows(soda);
  const stuck = docs.find((d) => d.type === 'batch.stuck');
  assert.equal(stuck.state, 'queued'); assert.equal(stuck.attempts, 0); assert.equal(stuck.leaseOwner, null);
  assert.equal(docs.find((d) => d.type === 'batch.quick').state, 'done');
  // Another worker picks the handed-back job up at once.
  const [again] = await q.claim('next-worker');
  assert.equal(again.doc.type, 'batch.stuck');
});

test('worker: a failing handler is retried with backoff and dead-lettered; a lost lease aborts the handler', async () => {
  const soda = new RaceSoda();
  const q = newQueue(soda, { backoffBaseMs: 10, backoffMaxMs: 20 });
  let calls = 0;
  const reg = registry([['push.broken', async () => { calls++; throw new Error('FCM 500'); }, { backoffBaseMs: 10 }]]);
  await q.enqueue('push.broken', {}, { maxAttempts: 3 });
  const w = new JobWorker({ queue: q, registry: reg, logger: quiet, pollMinMs: 10, pollMaxMs: 20 }).start();
  for (let i = 0; i < 100 && !(await soda.query(DEAD_COLLECTION, {}, { limit: 1 })).length; i++) await sleep(10);
  await w.stop({ drainMs: 0 });
  assert.equal(calls, 3);
  const [dead] = await rows(soda, DEAD_COLLECTION);
  assert.equal(dead.lastError, 'FCM 500');
  // Lost lease: another worker reclaims the row while the handler runs -> the signal aborts.
  const q2 = newQueue(soda);
  let aborted = false;
  const reg2 = registry([['batch.long', async (p, { signal }) => { await new Promise((r) => signal.addEventListener('abort', () => { aborted = true; r(); })); }, { leaseMs: 1500 }]]);
  await q2.enqueue('batch.long', {});
  const w2 = new JobWorker({ queue: q2, registry: reg2, logger: quiet, pollMinMs: 10 }).start();
  await sleep(50);
  const [row] = await soda.query(QUEUE_COLLECTION, { type: 'batch.long' }, { limit: 1 });
  await soda.replace(QUEUE_COLLECTION, row.key, { ...row.value, leaseOwner: 'thief', casRev: 'stolen' });
  for (let i = 0; i < 150 && !aborted; i++) await sleep(10);
  assert.equal(aborted, true, 'the renew noticed the lease was gone');
  await w2.stop({ drainMs: 0 });
});

// ---------------------------------------------------------------- memory bounds
test('memory bounds: pending security fallbacks are capped, counters are keyed by registered types only', async () => {
  const soda = new MemorySoda();
  const jobs = new Jobs({ soda, logger: quiet, options: { queue: true, securityFallbackMs: 60000 }, queue: newQueue(soda) });
  jobs.register('email.security', async () => {});
  jobs.pendingFallbacks = MAX_PENDING_FALLBACKS;
  let inline = 0;
  const r = await jobs.urgent('email.security', { to: 'a@example.test' }, {}, async () => { inline++; return { sent: true }; });
  assert.deepEqual([r.sent, inline], [true, 1], 'over the cap: sent inline, nothing more held in memory');
  assert.equal((await rows(soda)).length, 0);
  jobs.pendingFallbacks = 0;
  for (let i = 0; i < 50; i++) await jobs.enqueue(`email.t${i}`, {});
  assert.equal(jobs.byType.size, 0, 'unregistered types never become metric labels');
  assert.ok(jobs.metricsRows().every((row) => row.values.length < 40));
  assert.deepEqual(parseConcurrency('email:4, push:2,bogus,x:9999'), { email: 4, push: 2 });
});
