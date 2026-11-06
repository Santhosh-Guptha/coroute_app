'use strict';
/**
 * GATEWAY_ROLE / NODE_NAME: shown in /api/health and the X-CoRoute-Node header; scheduled jobs are started
 * through the job lease, the web node holding the web-preferred jobs and leaving live-preferred ones.
 */
process.env.NODE_ENV = 'test';
process.env.GATEWAY_ROLE = 'web';
process.env.NODE_NAME = 'vm2';
const test = require('node:test');
const assert = require('node:assert/strict');
const config = require('../src/config');
const { boot } = require('./_helpers');

test('web node: role in /api/health, node header, leased jobs', async (t) => {
  assert.equal(config.gatewayRole, 'web');
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const before = await env.api('GET', '/health');
  assert.equal(before.status, 200);
  assert.equal(before.json.role, 'web');
  assert.equal(before.json.node, 'vm2');
  assert.equal(before.headers.get('x-coroute-node'), 'vm2/web');
  // The launch coupons were seeded through the lease (once), and the lease was released.
  const seed = await env.soda.findOne('leases', { name: 'coupon-seed' });
  assert.ok(seed.value.lastRunAt > 0);
  assert.ok(seed.value.expiresAt <= Date.now());

  env.gw.retention.start(); // what server.js does after listen()
  env.gw.retention.start(); // idempotent
  for (let i = 0; i < 50 && env.gw.lease.status().subscriptions?.holding !== true; i++) await new Promise((r) => setTimeout(r, 20));
  const after = await env.api('GET', '/health');
  for (const job of ['retention', 'db-keepalive', 'subscriptions']) assert.ok(after.json.leases.includes(job), `${job} held by the web node`);
  assert.ok(!after.json.leases.includes('convoy-auto-end'), 'a live-preferred job waits for the live node');
  const st = env.gw.lease.status();
  assert.equal(st['convoy-auto-end'].prefer, 'live');
  assert.equal(st['db-keepalive'].runs, 1, 'no first delay: the keep-alive ran once');
  assert.equal(st.retention.runs, 0, 'retention keeps its first-run delay');
});
