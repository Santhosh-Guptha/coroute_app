'use strict';
/**
 * Behind NLB -> Caddy (VM1) -> gateway (VM1 loopback, or VM2 over the private network) the client IP is
 * the X-Forwarded-For entry added by a trusted proxy. TRUST_PROXY lists those proxies; rate limits key on
 * the real client, and a client cannot pick its own address when the direct peer is not trusted.
 */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('child_process');
const config = require('../src/config');
const { boot } = require('./_helpers');

const feedback = () => ({ name: 'Proxy', email: 'proxy@coroute.test', message: 'This is a long enough feedback message.', t: Date.now() - 10000 });

async function burst(env, ip, n) {
  const statuses = [];
  for (let i = 0; i < n; i++) statuses.push((await env.api('POST', '/feedback', feedback(), null, ip ? { 'X-Forwarded-For': ip } : {})).status);
  return statuses;
}

test('default: loopback (this VM\'s Caddy) is trusted; rate limits key on the client from X-Forwarded-For', async (t) => {
  assert.deepEqual(config.trustProxy, ['loopback']);
  const env = await boot();
  t.after(() => env.close());
  const a = await burst(env, '203.0.113.10', 6);
  assert.ok(a.slice(0, 5).every((s) => s !== 429), JSON.stringify(a));
  assert.equal(a[5], 429, 'sixth message from the same client is limited');
  const b = await burst(env, '203.0.113.11', 1);
  assert.notEqual(b[0], 429, 'another client behind the same proxy has its own budget');
  // Caddy appends the peer it saw; a spoofed left-most entry does not change the client.
  const spoof = await burst(env, '198.51.100.1, 203.0.113.10', 1);
  assert.equal(spoof[0], 429);
});

test('VM2: a peer not in TRUST_PROXY cannot choose its address with X-Forwarded-For', async (t) => {
  const saved = config.trustProxy;
  config.trustProxy = ['10.0.0.70']; // only VM1's Caddy; this test connects from 127.0.0.1
  t.after(() => { config.trustProxy = saved; });
  const env = await boot();
  t.after(() => env.close());
  const statuses = [];
  for (let i = 0; i < 6; i++) statuses.push(...await burst(env, `203.0.113.${20 + i}`, 1));
  assert.equal(statuses[5], 429, 'all six counted against the real peer 127.0.0.1');
});

test('TRUST_PROXY accepts IPs, CIDRs and keywords; rejects anything else at startup', () => {
  const load = (v) => execFileSync(process.execPath, ['-e', "process.stdout.write(JSON.stringify(require('./src/config').trustProxy))"],
    { cwd: require('path').join(__dirname, '..'), env: { ...process.env, NODE_ENV: 'test', TRUST_PROXY: v }, stdio: ['ignore', 'pipe', 'pipe'] }).toString();
  assert.deepEqual(JSON.parse(load('loopback, 10.0.0.70,10.0.0.0/24,::1')), ['loopback', '10.0.0.70', '10.0.0.0/24', '::1']);
  for (const bad of ['true', '1', '10.0.0.300', '10.0.0.0/33', '*']) assert.throws(() => load(bad), undefined, bad);
});
