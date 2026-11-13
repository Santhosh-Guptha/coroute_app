'use strict';
/**
 * Round 8 shard-ready group placement (src/shards.js, deploy/gen_caddy_shards.js; prepared, off by default): the hash
 * is stable (pinned values), consistent (a new pair takes buckets only for itself), order-independent and balanced;
 * the Caddy matchers cover every bucket exactly once; GET /api/shard answers for a group id or a join code, with wrong
 * codes limited like wrong join codes. SHARDS=1 changes nothing.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.JOIN_MAX_FAILURES = '3';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('child_process');
const path = require('path');
const S = require('../src/shards');
const { boot } = require('./_helpers');

test('stable: pinned group -> pair values for 2 and 3 pairs (a change here moves live rides: never edit casually)', () => {
  const c2 = S.shardConfig({ SHARDS: '2' }); const c3 = S.shardConfig({ SHARDS: '3' });
  const pinned = [['GRP-1A2B3C4D', 'a', 'a'], ['GRP-00000000', 'b', 'b'], ['GRP-DEADBEEF', 'a', 'a'], ['GRP-0F0F0F7E', 'b', 'c'], ['GRP-ABCDEF12', 'a', 'c'], ['GRP-12345699', 'a', 'c']];
  for (const [g, p2, p3] of pinned) {
    assert.equal(S.shardOf(g, c2), p2, `${g} with 2 pairs`);
    assert.equal(S.shardOf(g, c3), p3, `${g} with 3 pairs`);
    assert.equal(S.shardOf(g.toLowerCase(), c2), p2, 'case-insensitive');
  }
  assert.equal(S.bucketOf('GRP-1A2B3C4D'), 0x4D);
  assert.equal(S.bucketOf('nope'), null);
});

test('consistent, order-independent and balanced', () => {
  const ab = ['a', 'b']; const abc = ['a', 'b', 'c'];
  let moved = 0;
  for (let b = 0; b < S.BUCKETS; b++) {
    const before = S.pairForBucket(b, ab); const after = S.pairForBucket(b, abc);
    if (before !== after) { moved++; assert.equal(after, 'c', 'a bucket only ever moves to the new pair'); }
    assert.equal(S.pairForBucket(b, ['c', 'a', 'b']), after, 'order of SHARD_PAIRS does not matter');
  }
  assert.ok(moved > 50 && moved < 120, `about a third moves: ${moved}`);
  for (const n of [2, 3, 4]) {
    const t = S.bucketTable(S.shardConfig({ SHARDS: String(n) }).pairs);
    const sizes = Object.values(t).map((x) => x.length);
    assert.equal(sizes.reduce((x, y) => x + y, 0), 256);
    for (const s of sizes) assert.ok(s > (256 / n) * 0.7 && s < (256 / n) * 1.3, `balanced ${sizes}`);
  }
});

test('off by default: SHARDS=1 -> one pair, no matchers; unknown ids never fail', () => {
  const c1 = S.shardConfig({});
  assert.equal(c1.enabled, false);
  assert.equal(S.shardOf('GRP-1A2B3C4D', c1), 'a');
  assert.match(S.caddyMatchers(c1), /^# SHARDS=1/);
  assert.equal(S.shardOf('garbage', S.shardConfig({ SHARDS: '2' })), 'a');
  assert.deepEqual(S.shardConfig({ SHARDS: '2', SHARD_PAIRS: 'east, west', SHARD_SELF: 'west' }).pairs, ['east', 'west']);
});

test('Caddy matchers: every bucket exactly once, no backslashes, placeholders only; the CLI prints the same', () => {
  const cfg = S.shardConfig({ SHARDS: '2' });
  const text = S.caddyMatchers(cfg);
  assert.ok(!text.includes('\\'));
  const seen = new Map();
  for (const m of text.matchAll(/@shard_([a-z0-9-]+) \{\n\texpression `\{query\.g\}\.matches\("\(\?i\)\^GRP-\[0-9A-F\]\*\(([0-9A-F|]+)\)\$"\)/g)) {
    for (const b of m[2].split('|')) { assert.ok(!seen.has(b), `bucket ${b} twice`); seen.set(b, m[1]); }
  }
  assert.equal(seen.size, 256);
  assert.equal(seen.get('4D'), S.shardOf('GRP-1A2B3C4D', cfg));
  assert.match(text, /\{query\.shard\} == "a"/);
  assert.match(text, /<pair-a-live-private-ip>:3000/);
  const cli = execFileSync(process.execPath, [path.join(__dirname, '..', 'deploy', 'gen_caddy_shards.js'), '--shards', '2'], { env: { ...process.env, SHARDS: '' } }).toString();
  assert.equal(cli, text);
  const one = execFileSync(process.execPath, [path.join(__dirname, '..', 'deploy', 'gen_caddy_shards.js'), '--group', 'GRP-ABCDEF12', '--shards', '3']).toString();
  assert.match(one, /-> pair c/);
});

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

test('GET /api/shard: by group id (hash only) and by join code (one lookup; wrong codes limited); signed in only', async () => {
  const u = await t.register('Shard Rider', 'shard8@coroute.test');
  assert.equal((await t.api('GET', '/shard?g=GRP-1A2B3C4D')).status, 401);
  const byId = await t.api('GET', '/shard?g=GRP-1A2B3C4D', null, u.token);
  assert.equal(byId.status, 200);
  assert.deepEqual(byId.json, { shard: 'a', shards: 1, self: 'a', here: true });
  assert.equal((await t.api('GET', '/shard?g=nope', null, u.token)).status, 400);
  // Turn placement on for this router instance (the router reads its config at boot; this one is built here).
  const express = require('express');
  const { requireAuth } = require('../src/auth');
  const app = express();
  app.set('trust proxy', 'loopback');
  const cfg = S.shardConfig({ SHARDS: '2', SHARD_SELF: 'a' });
  app.use('/api', S.shardRouter({ repo: t.gw.repo, gate: t.gw.gate, requireAuth, config: { joinWindowMin: 15, joinMaxFailures: 3, joinMaxFailuresPerIp: 30 }, cfg }));
  const srv = await new Promise((r) => { const s = app.listen(0, '127.0.0.1', () => r(s)); });
  const base = `http://127.0.0.1:${srv.address().port}/api`;
  const get = async (q) => { const r = await fetch(`${base}/shard?${q}`, { headers: { Authorization: `Bearer ${u.token}` } }); return { status: r.status, json: await r.json().catch(() => ({})) }; };
  try {
    const c = (await t.api('POST', '/convoys', { name: 'Shard ride' }, u.token)).json;
    const ok = await get(`code=${c.joinCode}`);
    assert.equal(ok.status, 200);
    assert.equal(ok.json.shard, S.shardOf(c.groupId, cfg));
    assert.equal(ok.json.here, ok.json.shard === 'a');
    assert.equal(ok.json.groupId, undefined, 'never the group id for a code');
    const wrong = c.joinCode === '999999' ? '999998' : '999999';
    for (let i = 0; i < 3; i++) assert.equal((await get(`code=${wrong}`)).status, 404);
    const limited = await get(`code=${c.joinCode}`);
    assert.equal(limited.status, 429, 'limited like wrong join codes, even with the right code');
    assert.equal(limited.json.code, 'TOO_MANY_ATTEMPTS');
  } finally { srv.close(); }
});
