'use strict';
/**
 * Round 8, prepared only (HIGH_TRAFFIC_PLAN_v3.57 item 10 / stage 4): shard-ready group placement. OFF by default
 * (SHARDS=1): every group is on the one live pair and nothing here changes how a request is routed.
 *
 * Model. A shard is a live PAIR (live node + twin, src/mirror.js). All riders of one group must be on the same pair,
 * so a group's fan-out never crosses servers. Placement is by groupId:
 *   bucket(groupId) = the last two hex characters of the id ("GRP-" + 8 hex, src/convoys.js): 256 buckets, readable
 *                     by Caddy with a plain regex (no hashing in the proxy);
 *   pair(bucket)    = rendezvous (highest random weight) hash over SHARD_PAIRS: sha256("<bucket>|<pair>"), the pair
 *                     with the largest value wins. Adding a pair moves only ~1/n of the buckets (consistent), and the
 *                     result never depends on the order of SHARD_PAIRS.
 * Settings: SHARDS (number of pairs; 1 = off), SHARD_PAIRS (comma list of pair names, default a,b,c,...),
 * SHARD_SELF (this node's pair; used by the lookup to say "here" or "elsewhere").
 *
 * Routing at stage 4 (documented, not enabled): the app opens /ws?g=<groupId> for a ride; Caddy's generated matchers
 * (deploy/gen_caddy_shards.js) send /ws?g=..., /api/convoys/<groupId>/... and any request with ?shard=<pair> to that
 * pair's upstreams. A join code is resolved FIRST with GET /api/shard?code=<code> (any node; one database read;
 * failures counted per account and per IP like wrong join codes), then POST /api/convoys/join?shard=<pair> goes to
 * the right pair.
 */
const crypto = require('crypto');

const BUCKETS = 256;
const ID_RE = /^GRP-[0-9A-F]{6,}$/i;

function shardConfig(env = process.env) {
  const n = Math.max(1, Math.min(64, Math.floor(Number(env.SHARDS) || 1)));
  const names = String(env.SHARD_PAIRS || '').split(',').map((s) => s.trim().toLowerCase()).filter((s) => /^[a-z0-9-]{1,16}$/.test(s));
  const pairs = names.length >= n ? names.slice(0, n) : Array.from({ length: n }, (_, i) => names[i] || String.fromCharCode(97 + (i % 26)) + (i >= 26 ? String(Math.floor(i / 26)) : ''));
  const self = String(env.SHARD_SELF || pairs[0]).trim().toLowerCase();
  return { shards: n, pairs, self, enabled: n > 1 };
}

/** 0..255 from the last two hex characters of a group id; null for an id that is not a group id. */
function bucketOf(groupId) {
  const g = String(groupId || '').trim();
  if (!ID_RE.test(g)) return null;
  return parseInt(g.slice(-2), 16);
}

const hex2 = (b) => b.toString(16).toUpperCase().padStart(2, '0');

/** Rendezvous hash: the pair for one bucket. */
function pairForBucket(bucket, pairs) {
  if (!pairs.length) return null;
  if (pairs.length === 1) return pairs[0];
  let best = null; let bestW = null;
  for (const p of pairs) {
    const w = crypto.createHash('sha256').update(`${hex2(bucket)}|${p}`).digest('hex');
    if (bestW === null || w > bestW) { bestW = w; best = p; }
  }
  return best;
}

/** The pair of a group (cfg from shardConfig). Unknown ids go to the first pair (never an error). */
function shardOf(groupId, cfg = shardConfig()) {
  if (!cfg.enabled) return cfg.pairs[0];
  const b = bucketOf(groupId);
  return b === null ? cfg.pairs[0] : pairForBucket(b, cfg.pairs);
}

/** bucket -> pair for every bucket, and pair -> [bucket hex] (for the Caddy generator and tests). */
function bucketTable(pairs) {
  const byPair = Object.fromEntries(pairs.map((p) => [p, []]));
  for (let b = 0; b < BUCKETS; b++) byPair[pairForBucket(b, pairs)].push(hex2(b));
  return byPair;
}

/**
 * Caddy snippet for SHARDS > 1: one named matcher per pair (query g, group id in a convoy path, or ?shard=<pair>) and a
 * reverse_proxy per pair. `upstreams`: { pair: 'host:port host:port' } (live node first; the twin is the fallback).
 * Regexes use only character classes and alternation: no backslashes or braces (CEL / Caddy placeholders).
 */
function caddyMatchers(cfg, upstreams = {}) {
  if (!cfg.enabled) return '# SHARDS=1: one live pair, no shard matchers (placement is off).\n';
  const table = bucketTable(cfg.pairs);
  const out = ['# BEGIN GENERATED SHARD MATCHERS (deploy/gen_caddy_shards.js; SHARDS=' + cfg.shards + ', pairs ' + cfg.pairs.join(',') + ')'];
  for (const p of cfg.pairs) {
    const alt = table[p].join('|');
    out.push(`@shard_${p} {`);
    out.push(`\texpression \`{query.g}.matches("(?i)^GRP-[0-9A-F]*(${alt})$") || {path}.matches("(?i)^/api/convoys/GRP-[0-9A-F]*(${alt})(/.*)?$") || {query.shard} == "${p}"\``);
    out.push('}');
  }
  for (const p of cfg.pairs) {
    const up = upstreams[p] || `<pair-${p}-live-private-ip>:3000 <pair-${p}-twin-private-ip>:3000`;
    out.push(`handle @shard_${p} {`);
    out.push(`\treverse_proxy ${up} {`);
    out.push('\t\tlb_policy first');
    out.push('\t\thealth_uri /api/health/live');
    out.push('\t\thealth_interval 5s');
    out.push('\t}');
    out.push('}');
  }
  out.push('# END GENERATED SHARD MATCHERS');
  return `${out.join('\n')}\n`;
}

/**
 * GET /api/shard?g=<groupId> | ?code=<join code>  (signed in). Answers { shard, shards, self, here } and, for a code,
 * nothing else (never the group id: the join call itself returns that). Wrong codes count against the caller like
 * wrong join codes (JOIN_MAX_FAILURES per account and JOIN_MAX_FAILURES_PER_IP per network, JOIN_WINDOW_MIN).
 */
function shardRouter({ repo, gate, requireAuth, config, cfg = shardConfig(), clock = Date.now }) {
  const express = require('express');
  const r = express.Router();
  const windowMs = Math.max(1, Number(config.joinWindowMin) || 15) * 60000;
  const fails = new Map(); // key -> [timestamps]
  const recent = (k, t) => { const a = (fails.get(k) || []).filter((x) => t - x < windowMs); if (a.length) fails.set(k, a); else fails.delete(k); return a; };
  const answer = (gid) => { const s = shardOf(gid, cfg); return { shard: s, shards: cfg.shards, self: cfg.self, here: s === cfg.self }; };
  r.get('/shard', requireAuth(gate), async (req, res, next) => {
    try {
      const t = clock();
      if (typeof req.query.g === 'string' && req.query.g) {
        if (bucketOf(req.query.g) === null) return res.status(400).json({ error: 'Not a group id.' });
        return res.json(answer(req.query.g));
      }
      const code = String(req.query.code || '').trim().toUpperCase();
      if (!/^[A-Z0-9]{4,10}$/.test(code)) return res.status(400).json({ error: 'Invalid join code.' });
      const uk = `u:${req.user.userId}`; const ik = `i:${req.ip}`;
      if (recent(uk, t).length >= (config.joinMaxFailures || 10) || recent(ik, t).length >= (config.joinMaxFailuresPerIp || 30)) {
        return res.status(429).json({ error: 'Too many wrong codes. Try again later.', code: 'TOO_MANY_ATTEMPTS' });
      }
      if (!cfg.enabled) return res.json({ shard: cfg.pairs[0], shards: 1, self: cfg.self, here: true });
      const meta = await repo.getActiveConvoyByJoinCode(code);
      if (!meta) {
        for (const k of [uk, ik]) { const a = recent(k, t); a.push(t); fails.set(k, a); }
        if (fails.size > 20000) for (const k of fails.keys()) { recent(k, t); if (fails.size <= 10000) break; }
        return res.status(404).json({ error: 'No active convoy found for that code.' });
      }
      return res.json(answer(meta.groupId));
    } catch (e) { return next(e); }
  });
  return r;
}

module.exports = { shardConfig, bucketOf, pairForBucket, shardOf, bucketTable, caddyMatchers, shardRouter, BUCKETS };
