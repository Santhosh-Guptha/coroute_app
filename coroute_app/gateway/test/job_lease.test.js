'use strict';
/**
 * Job leases: two gateway nodes on one database run each scheduled job exactly once per interval,
 * a dead holder is replaced after its lease expires, and GATEWAY_ROLE decides who runs what.
 */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { JobLease } = require('../src/job_lease');
const { MemorySoda } = require('../src/oracle/memory_soda');

const quiet = { info() {}, warn() {}, error() {} };

function cluster(roles, { ttlMs = 3000, graceMs = 120000 } = {}) {
  const soda = new MemorySoda();
  const clock = { t: 1_700_000_000_000 };
  const nodes = roles.map((role, i) => new JobLease({ soda, role, node: `vm${i + 1}`, logger: quiet, clock: () => clock.t, ttlMs, heartbeatMs: 1000, graceMs, autoTick: false }));
  return { soda, clock, nodes };
}

/** Registers the same job on every node; returns the shared run log. */
function job(nodes, name, intervalMs, opts = {}) {
  const log = [];
  let active = 0;
  for (const n of nodes) {
    n.run(name, intervalMs, async () => {
      active++;
      assert.equal(active, 1, 'never concurrently');
      log.push({ node: n.node, at: n.clock() });
      await new Promise((r) => setImmediate(r));
      active--;
    }, opts);
  }
  return log;
}

async function step(nodes, name, alive = nodes) {
  for (const n of alive) { await n.poll(name); await n.idle(); }
}

test('two nodes on one database: each job runs once per interval, on one node', async () => {
  const { clock, nodes } = cluster(['all', 'all']);
  const a = job(nodes, 'retention', 1000);
  const b = job(nodes, 'sweep', 2500);
  for (let i = 0; i < 40; i++) { // 10 s in 250 ms steps
    await step(nodes, 'retention'); await step(nodes, 'sweep');
    clock.t += 250;
  }
  assert.equal(a.length, 10);
  assert.equal(b.length, 4);
  for (let i = 1; i < a.length; i++) assert.ok(a[i].at - a[i - 1].at >= 1000, 'once per interval');
  assert.equal(new Set(a.map((r) => r.node)).size, 1, 'the holder keeps the lease while alive');
});

test('holder dies: the other node takes over after expiry, without a double run', async () => {
  const { clock, nodes } = cluster(['web', 'web'], { ttlMs: 3000 });
  const [vm1, vm2] = nodes;
  const log = job(nodes, 'subscriptions', 1000);
  await step(nodes, 'subscriptions', [vm1]); // vm1 starts first and holds the lease
  await step(nodes, 'subscriptions', [vm2]);
  assert.deepEqual(log.map((r) => r.node), ['vm1']);
  // vm1 crashes (no release). Until its lease expires vm2 runs nothing.
  for (let i = 0; i < 11; i++) { clock.t += 250; await step(nodes, 'subscriptions', [vm2]); }
  assert.equal(log.length, 1, 'skipped while held elsewhere');
  for (let i = 0; i < 12; i++) { clock.t += 250; await step(nodes, 'subscriptions', [vm2]); }
  assert.ok(log.length >= 2, 'taken over after expiry');
  assert.equal(log.at(-1).node, 'vm2');
  for (let i = 1; i < log.length; i++) assert.ok(log[i].at - log[i - 1].at >= 1000);
  assert.equal(vm2.status().subscriptions.holding, true);
});

test('role preference: web takes jobs at once; live only after the lease has been expired 120 s; hand-back when web returns', async () => {
  const { clock, nodes } = cluster(['live', 'web'], { ttlMs: 3000, graceMs: 120000 });
  const [live, web] = nodes;
  const log = job(nodes, 'retention', 10000);
  // Both start: the live node waits, the web node takes the free lease.
  await step(nodes, 'retention', [live, web]);
  assert.deepEqual(log.map((r) => r.node), ['vm2']);
  assert.equal(live.status().retention.holding, false);

  // The web VM stops. Its lease expires after 3 s; the live node waits a further 120 s.
  for (let s = 0; s < 120; s++) { clock.t += 1000; await step(nodes, 'retention', [live]); }
  assert.equal(log.length, 1, 'live node waits for the grace period');
  for (let s = 0; s < 6; s++) { clock.t += 1000; await step(nodes, 'retention', [live]); }
  assert.equal(log.at(-1).node, 'vm1', 'live node took over');
  const runsByLive = log.length;

  // The web VM comes back: it asks for the lease, the live node hands it back, web runs on schedule.
  for (let s = 0; s < 30; s++) { clock.t += 1000; await step(nodes, 'retention', [web, live]); }
  assert.equal(web.status().retention.holding, true);
  assert.equal(live.status().retention.holding, false);
  assert.equal(log.at(-1).node, 'vm2');
  assert.ok(log.length >= runsByLive + 2);
  for (let i = 1; i < log.length; i++) assert.ok(log[i].at - log[i - 1].at >= 10000, 'no double run around the hand-over');
});

test('a job that prefers live runs on the live node; a missing lease waits out the grace on the web node', async () => {
  const { clock, nodes } = cluster(['web', 'live'], { ttlMs: 3000, graceMs: 120000 });
  const [web, live] = nodes;
  const log = job(nodes, 'guardian-push', 1000, { prefer: 'live' });
  await step(nodes, 'guardian-push', [web]);
  assert.equal(log.length, 0, 'web does not take a live job while the live node may exist');
  await step(nodes, 'guardian-push', [live]);
  assert.deepEqual(log.map((r) => r.node), ['vm2']);
  for (let s = 0; s < 10; s++) { clock.t += 1000; await step(nodes, 'guardian-push', [web, live]); }
  assert.ok(log.every((r) => r.node === 'vm2'));
  assert.equal(log.length, 11);
});

test('once(): two nodes starting together seed exactly once', async () => {
  const { nodes } = cluster(['all', 'all']);
  let runs = 0;
  const fn = async () => { runs++; await new Promise((r) => setTimeout(r, 5)); };
  const results = await Promise.all(nodes.map((n) => n.once('coupon-seed', fn)));
  assert.equal(runs, 1);
  assert.deepEqual(results.sort(), [false, true]);
  // A restart minutes later does not seed again (minGap), the lease was released.
  assert.equal(await nodes[1].once('coupon-seed', fn), false);
  assert.equal(runs, 1);
});

test('stopAll releases held leases: the other preferred node takes over at once', async () => {
  const { clock, nodes } = cluster(['web', 'web'], { ttlMs: 60000 });
  const [vm1, vm2] = nodes;
  const log = job(nodes, 'keepalive', 1000);
  await step(nodes, 'keepalive', [vm1, vm2]);
  await vm1.stopAll();
  clock.t += 2000;
  await step(nodes, 'keepalive', [vm2]);
  assert.deepEqual(log.map((r) => r.node), ['vm1', 'vm2']);
});

test('real timers: two nodes, short interval, runs stay once per interval', async () => {
  const soda = new MemorySoda();
  const mk = (node) => new JobLease({ soda, role: 'all', node, logger: quiet, ttlMs: 300, heartbeatMs: 20 });
  const nodes = [mk('a'), mk('b')];
  const log = job(nodes, 'tick', 100);
  await new Promise((r) => setTimeout(r, 560));
  await Promise.all(nodes.map((n) => n.stopAll()));
  assert.ok(log.length >= 4 && log.length <= 6, `runs: ${log.length}`);
  for (let i = 1; i < log.length; i++) assert.ok(log[i].at - log[i - 1].at >= 100);
});
