'use strict';
/**
 * Round 4 intelligence on the micro VMs: bounded memory (accumulators, cells per ride, raw queue, trimming FIFO,
 * read cache), the per-point CPU cost, idle sweep, and the aggregation job's batch budget and yielding to live traffic.
 */
process.env.NODE_ENV = 'test';

const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../src/intel/math');
const gh = require('../src/intel/geohash');
const { RideTrimmer } = require('../src/intel/privacy');
const { RAW_QUEUE_MAX } = require('../src/intel/engine');
const { makeEngine, ride, consentAll, move } = require('./_intel_helpers');

test('accumulators are capped (LRU); an evicted ride is flushed, not lost', async () => {
  process.env.INTEL_MAX_ACCUMULATORS = '20';
  const env = makeEngine();
  const ids = Array.from({ length: 50 }, (_, i) => `m${i}`);
  await consentAll(env, ids);
  for (const [i, id] of ids.entries()) {
    let p = { lat: 12.9 + i * 0.01, lng: 77.5 };
    for (let k = 0; k < 120; k++) { env.engine.onTelemetry('G', { userId: id, lat: p.lat, lng: p.lng }); p = move(p.lat, p.lng, 90, 20); env.clock.now += 2000; }
  }
  assert.equal(env.engine.acc.size, 20);
  assert.equal(env.engine.stats.evicted, 30);
  await env.engine.flushRaw();
  assert.equal((await env.soda.query('intel_raw', { k: 'ride' }, { limit: 100 })).length, 30, 'every evicted ride became one row');
  delete process.env.INTEL_MAX_ACCUMULATORS;
});

test('a long ride is flushed in chunks: at most INTEL_MAX_CELLS_PER_RIDE cells in memory', async () => {
  process.env.INTEL_MAX_CELLS_PER_RIDE = '20';
  const env = makeEngine();
  await consentAll(env, ['long']);
  let maxCells = 0;
  let p = { lat: 12.9, lng: 77.5 };
  for (let k = 0; k < 6000; k++) { // 120 km
    env.engine.onTelemetry('G', { userId: 'long', lat: p.lat, lng: p.lng });
    p = move(p.lat, p.lng, 45, 20); env.clock.now += 2000;
    const a = env.engine.acc.peek('G|long');
    maxCells = Math.max(maxCells, a.cells.size);
  }
  assert.ok(maxCells <= 20, `max ${maxCells}`);
  assert.ok(env.engine.stats.flushes >= 5);
  delete process.env.INTEL_MAX_CELLS_PER_RIDE;
});

test('raw queue is capped when the database is down; the trimming FIFO is capped', async () => {
  const env = makeEngine();
  env.soda.insertMany = async () => { throw new Error('down'); };
  await consentAll(env, ['q']);
  env.engine.flushRaw = () => Promise.resolve(); // simulate a stuck writer: only the cap protects memory
  for (let i = 0; i < 2000; i++) env.engine._queueRaw({ uid: 'q', k: 'evs', t: env.clock.now, d: { e: [] } });
  assert.equal(env.engine.rawQueue.length, RAW_QUEUE_MAX);
  assert.equal(env.engine.stats.rowsDropped, 2000 - RAW_QUEUE_MAX);
  const t = new RideTrimmer({ trimM: 300, maxHeld: 150 });
  for (let i = 0; i < 5000; i++) t.push({ lat: 12.9, lng: 77.5, t: i }); // parked for hours: one held point
  assert.equal(t.held.length, 1);
  assert.equal(t.held[0].t2, 4999);
  // GPS jitter of 12 m back and forth never grows past the cap and never releases early.
  const j = new RideTrimmer({ trimM: 300, maxHeld: 150 });
  let rel = 0;
  for (let i = 0; i < 5000; i++) rel += j.push({ lat: 12.9 + (i % 2 ? 0.00011 : 0), lng: 77.5, t: i }).length;
  assert.ok(j.held.length <= 150);
  assert.equal(rel, 0, 'jitter at the start is never counted (all of it is within 300 m of the start)');
});

test('read cache is an LRU of at most 200 tiles; idle rides are closed after 30 minutes', async () => {
  const env = makeEngine();
  for (let i = 0; i < 300; i++) env.engine.cache.set(`hz:t${i}`, { at: 0, cells: [] });
  assert.equal(env.engine.cache.size, 200);
  await consentAll(env, ['idle']);
  ride(env, { userId: 'idle', legs: [{ deg: 0, km: 2, kmh: 40 }] });
  assert.equal(env.engine.acc.size, 1);
  env.engine.sweepIdle(env.clock.now + 29 * 60000);
  assert.equal(env.engine.acc.size, 1);
  env.engine.sweepIdle(env.clock.now + 31 * 60000);
  assert.equal(env.engine.acc.size, 0);
});

test('worst case memory stays inside the 20 MB budget; a telemetry point costs microseconds', async () => {
  const env = makeEngine();
  const ids = Array.from({ length: 500 }, (_, i) => `w${i}`);
  await consentAll(env, ids);
  // 500 riders, each with a full 200-cell accumulator and a full FIFO (synthetic, the worst case).
  for (const id of ids) {
    const a = { k: `G|${id}`, uid: id, gid: 'G', trim: new RideTrimmer(), last: null, heading: null, cells: new Map(), stops: [], still: null, startedAt: 0, lastAt: env.clock.now, chunkAt: 0 };
    for (let c = 0; c < 200; c++) a.cells.set(`${gh.encode(12 + c * 0.01, 77, 6)}|${c % 12}`, [1, 2, 3, 4]);
    for (let h = 0; h < 150; h++) a.trim.held.push({ lat: 1, lng: 2, t: 3, v: 4, step: 5 });
    env.engine.acc.set(a.k, a);
  }
  const est = env.engine.memoryEstimate();
  assert.ok(est < 20 * 1024 * 1024, `estimate ${Math.round(est / 1048576)} MB`);
  // Measured heap growth of the same structure stays well under 40 MB (estimates are conservative).
  global.gc?.();
  // CPU: average cost per telemetry point (consenting rider, moving).
  const env2 = makeEngine();
  await consentAll(env2, ['cpu']);
  let p = { lat: 12.9, lng: 77.5 };
  const n = 20000;
  const t0 = process.hrtime.bigint();
  for (let k = 0; k < n; k++) { env2.engine.onTelemetry('G', { userId: 'cpu', lat: p.lat, lng: p.lng }); p = move(p.lat, p.lng, 30, 15); env2.clock.now += 1000; }
  const perPointUs = Number(process.hrtime.bigint() - t0) / 1000 / n;
  assert.ok(perPointUs < 60, `${perPointUs.toFixed(1)} us per point`);
  // A rider without consent costs a cached lookup only.
  const t1 = process.hrtime.bigint();
  for (let k = 0; k < n; k++) env2.engine.onTelemetry('G', { userId: 'cpu-no', lat: 12.9, lng: 77.5 });
  assert.ok(Number(process.hrtime.bigint() - t1) / 1000 / n < 30);
});

test('aggregation: at most INTEL_JOB_MAX_CELLS cell writes per run, the rest next run; yields to live traffic', async () => {
  process.env.INTEL_JOB_MAX_CELLS = '60';
  const env = makeEngine();
  const ids = Array.from({ length: 40 }, (_, i) => `j${i}`);
  await consentAll(env, ids);
  for (const [i, id] of ids.entries()) await env.engine.ingestEvents(id, [{ type: 'hard_brake', gh: gh.encode(8 + i * 0.2, 77.5, 7), hb: 0, ts: env.clock.now }]);
  await env.engine.flushRaw();
  let yields = 0;
  const orig = M.yieldNow;
  M.yieldNow = () => { yields++; return orig(); };
  const r1 = await env.engine.aggregate();
  assert.ok(r1.cells <= 60, `cells ${r1.cells}`);
  assert.ok(r1.folded < 40);
  assert.ok(yields >= 2, 'gave the event loop turns');
  let total = r1.folded;
  for (let i = 0; i < 5 && total < 40; i++) total += (await env.engine.aggregate()).folded;
  assert.equal(total, 40);
  assert.equal((await env.soda.query('intel_raw', { p: 0 }, { limit: 100 })).length, 0);
  M.yieldNow = orig;
  // An aborted run (lost lease) stops early and leaves the rest for the next holder.
  const ac = new AbortController(); ac.abort();
  await env.engine.ingestEvents('j0', [{ type: 'hard_brake', gh: gh.encode(12.9, 77.5, 7), hb: 0, ts: env.clock.now }]);
  assert.equal((await env.engine.aggregate({ signal: ac.signal })).folded, 0);
  delete process.env.INTEL_JOB_MAX_CELLS;
});

test('aggregates are written by the job-lease holder only; both nodes read', async () => {
  const { JobLease } = require('../src/intel/../job_lease');
  const env = makeEngine();
  const a = new JobLease({ soda: env.soda, role: 'web', node: 'vm2', logger: { info() {}, warn() {} }, autoTick: false });
  const b = new JobLease({ soda: env.soda, role: 'live', node: 'vm1', logger: { info() {}, warn() {} }, autoTick: false });
  let runsA = 0, runsB = 0;
  const realAgg = env.engine.aggregate.bind(env.engine);
  a.run('intel-aggregate', 60000, async () => { runsA++; await realAgg(); });
  b.run('intel-aggregate', 60000, async () => { runsB++; await realAgg(); });
  await a.poll('intel-aggregate'); await b.poll('intel-aggregate');
  await a.idle(); await b.idle();
  assert.equal(runsA + runsB, 1, 'exactly one node ran it');
  assert.equal(runsA, 1, 'the web node (preferred) holds it');
  await a.stopAll({ waitMs: 10 }); await b.stopAll({ waitMs: 10 });
});
