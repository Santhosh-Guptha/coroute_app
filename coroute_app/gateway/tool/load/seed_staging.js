#!/usr/bin/env node
'use strict';
/**
 * Seeds load-test riders and convoys into the STAGING database (vm4) and writes their tokens for ws_load.js.
 * Never production: refuses unless PUBLIC_ORIGIN contains "staging" AND the database host is not listed in
 * PRODUCTION_DB_HOSTS (comma separated; set it in /etc/coroute/staging.env on vm4) AND --confirm-db <host> names
 * the database host exactly. Riders are tagged loadTest:true with e-mails @load.invalid (never deliverable).
 *
 *   sudo -E node tool/load/seed_staging.js --riders 300 --group-size 8 --out /tmp/coroute-load-tokens.json --confirm-db <db host>
 * Env: the staging gateway's settings and secrets (ORACLE_SODA_URL, ORACLE_USER, ORACLE_PASSWORD, JWT_SECRET, ...).
 */
const fs = require('fs');
const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf(`--${k}`); return i >= 0 ? argv[i + 1] : d; };

function guard(env = process.env, confirm = arg('confirm-db', '')) {
  const origin = String(env.PUBLIC_ORIGIN || '');
  if (!/staging/i.test(origin)) throw new Error(`PUBLIC_ORIGIN (${origin || 'empty'}) is not a staging origin: refusing.`);
  let host = '';
  try { host = new URL(String(env.ORACLE_SODA_URL || '')).host.toLowerCase(); } catch { throw new Error('ORACLE_SODA_URL is not a URL (a memory database cannot be seeded from another process).'); }
  const prod = String(env.PRODUCTION_DB_HOSTS || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  if (!prod.length) throw new Error('Set PRODUCTION_DB_HOSTS (the production database host) so this script can prove it is not writing there.');
  if (prod.includes(host)) throw new Error(`The database ${host} is listed in PRODUCTION_DB_HOSTS: refusing to seed production.`);
  if (confirm.toLowerCase() !== host) throw new Error(`Pass --confirm-db ${host} to confirm the staging database.`);
  return host;
}

async function main() {
  guard();
  process.env.NODE_ENV = process.env.NODE_ENV || 'production';
  const { createApp } = require('../../src/app');
  const { seedRiders } = require('./_seed');
  const quiet = { info() {}, warn: (m) => console.warn(m), error: (m) => console.error(m) };
  const gw = await createApp({ logger: quiet });
  const riders = await seedRiders(gw, { riders: Number(arg('riders', 300)), groupSize: Number(arg('group-size', 8)), prefix: 'lt' });
  await gw.convoys.flushAll().catch(() => {});
  const out = arg('out', '/tmp/coroute-load-tokens.json');
  fs.writeFileSync(out, JSON.stringify({ createdAt: Date.now(), riders }), { mode: 0o600 });
  console.log(`seeded ${riders.length} riders in ${new Set(riders.map((r) => r.groupId)).size} convoys -> ${out}`);
  await gw.shutdown().catch(() => {});
  process.exit(0);
}

module.exports = { guard };
if (require.main === module) main().catch((e) => { console.error(e.message); process.exit(1); });
