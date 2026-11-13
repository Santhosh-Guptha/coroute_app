#!/usr/bin/env node
'use strict';
/**
 * Round 8 (prepared, NOT enabled): prints the Caddy matchers that place groups on live pairs by consistent hash of the
 * group id (src/shards.js). With SHARDS=1 (the default) it prints a comment and nothing else: there is one pair.
 *
 *   SHARDS=2 SHARD_PAIRS=a,b node deploy/gen_caddy_shards.js
 *   node deploy/gen_caddy_shards.js --shards 2 --pairs a,b --upstream a="<a-live>:3000 <a-twin>:3000" --upstream b="..."
 *   node deploy/gen_caddy_shards.js --shards 2 --table          (bucket -> pair table, for the runbook)
 *   node deploy/gen_caddy_shards.js --group GRP-1A2B3C4D        (which pair a group is on)
 *
 * The output goes INSIDE the site block of the public Caddyfile, before the generic /ws and LIVE route handles
 * (deploy/caddy/Caddyfile.vm1). Stage 4 steps: gateway/deploy/RUNBOOK.md "Stage 4: second live pair (prepared)".
 * Placeholders only: real private addresses are passed on the command line on the VM, never committed.
 */
const { shardConfig, caddyMatchers, bucketTable, shardOf } = require('../src/shards');

const argv = process.argv.slice(2);
const val = (k) => { const i = argv.indexOf(`--${k}`); return i >= 0 ? argv[i + 1] : undefined; };
const env = { ...process.env };
if (val('shards')) env.SHARDS = val('shards');
if (val('pairs')) env.SHARD_PAIRS = val('pairs');
const cfg = shardConfig(env);
const upstreams = {};
argv.forEach((a, i) => {
  if (a !== '--upstream') return;
  const m = /^([a-z0-9-]{1,16})=(.+)$/.exec(String(argv[i + 1] || ''));
  if (!m) { console.error('--upstream name="host:port host:port"'); process.exit(2); }
  upstreams[m[1]] = m[2];
});

if (val('group')) {
  console.log(`${val('group')} -> pair ${shardOf(val('group'), cfg)} (SHARDS=${cfg.shards}, pairs ${cfg.pairs.join(',')})`);
} else if (argv.includes('--table')) {
  const t = bucketTable(cfg.pairs);
  for (const p of cfg.pairs) console.log(`${p}: ${t[p].length} buckets  ${t[p].join(' ')}`);
} else {
  process.stdout.write(caddyMatchers(cfg, upstreams));
}
