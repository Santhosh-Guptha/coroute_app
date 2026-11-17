'use strict';
/**
 * v3.62b closes the open security items of round 21:
 *  - a 2-step code is single use across BOTH nodes (unique row in mfa_used);
 *  - a forged Host header never ends up in a generated link when PUBLIC_ORIGIN is unset (production);
 *  - an SOS raised on the other node still gets its "closed" push (under its own cap).
 */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { requestOrigin, FALLBACK_ORIGIN } = require('../src/domains');
const { AuthService } = require('../src/auth');

test('2-step code: the second node using the same code is refused', async () => {
  const soda = new MemorySoda();
  const nodeA = Object.create(AuthService.prototype); nodeA.repo = { soda };
  const nodeB = Object.create(AuthService.prototype); nodeB.repo = { soda };
  await nodeA._claimMfaUse('u1', 'totp', '5900001');
  await assert.rejects(nodeB._claimMfaUse('u1', 'totp', '5900001'), (e) => e.code === 'MFA_CODE_WRONG');
  await nodeB._claimMfaUse('u1', 'totp', '5900002');
  await nodeB._claimMfaUse('u2', 'totp', '5900001');
  await nodeA._claimMfaUse('u1', 'rc', 'hash-a');
  await assert.rejects(nodeB._claimMfaUse('u1', 'rc', 'hash-a'));
});

test('2-step claim never blocks a sign-in when the database fails', async () => {
  const broken = { ensureCollection: async () => {}, ensureIndex: async () => {}, insert: async () => { throw Object.assign(new Error('timeout'), { status: 503 }); }, removeWhere: async () => 0 };
  const n = Object.create(AuthService.prototype); n.repo = { soda: broken };
  await n._claimMfaUse('u1', 'totp', '1');
});

test('link origin: forged Host is ignored in production without PUBLIC_ORIGIN', () => {
  const cfg = { publicOrigin: '', legacyOrigins: ['https://coroute.duckdns.org'], corsOrigins: ['https://coroute.example'] };
  const req = (host, protocol = 'https') => ({ protocol, get: (h) => (h === 'host' ? host : undefined) });
  const prev = process.env.NODE_ENV;
  process.env.NODE_ENV = 'production';
  try {
    assert.equal(requestOrigin(cfg, req('evil.example')), FALLBACK_ORIGIN);
    assert.equal(requestOrigin(cfg, req('evil.example\r\nX: y')), FALLBACK_ORIGIN);
    assert.equal(requestOrigin(cfg, req('coroute.example')), 'https://coroute.example');
    assert.equal(requestOrigin(cfg, req('127.0.0.1:3000', 'http')), 'http://127.0.0.1:3000');
    assert.equal(requestOrigin({ ...cfg, publicOrigin: 'https://coroute.devmonks.space' }, req('evil.example')), 'https://coroute.devmonks.space');
  } finally { process.env.NODE_ENV = prev; }
});

test('SOS raised on the other node: its close is still pushed, with a cap', async () => {
  const { ConvoyManager } = require('../src/convoys');
  const cm = Object.create(ConvoyManager.prototype);
  cm.log = { warn() {} };
  const calls = [];
  cm.push = { notifyUsers: async (ids, o) => { calls.push(o.type); return {}; } };
  const room = { groupId: 'g', riders: new Map([['a', {}], ['b', {}]]), meta: { name: 'Ride' } };
  for (let i = 0; i < 9; i++) cm._pushSos(room, { alertId: `x${i}`, userId: 'a', userName: 'Anu', timestamp: Date.now() }, 'RESOLVED');
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(calls.filter((t) => t === 'GROUP_SOS_RESOLVED').length, 6, 'closes from the other node: at most 6 per 10 min');
  calls.length = 0;
  cm._pushSos(room, { alertId: 'old', userId: 'z', userName: 'Z', timestamp: Date.now() - 7 * 3600000 }, 'RESOLVED');
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(calls.length, 0, 'no close push for an SOS older than 6 h');
});
