#!/usr/bin/env node
'use strict';
/**
 * Daily activity keep-alive for the Oracle Always Free staging Autonomous Database (coroutestaging).
 *
 * Prevents Oracle Cloud Always Free from auto-pausing or suspending the staging database
 * due to 7-day inactivity. Performs an active write (SODA insert) and prunes historical entries
 * older than 30 days in a dedicated `_staging_keepalive` collection.
 *
 * Usage:
 *   node scripts/staging_keepalive.js [--dry-run]
 *
 * Environment:
 *   STAGING_ORACLE_SODA_URL (default: https://gfe473165e66472-coroutestaging.adb.ap-hyderabad-1.oraclecloudapps.com/ords/admin/soda/latest)
 *   STAGING_ORACLE_USER     (default: admin)
 *   STAGING_ORACLE_PASSWORD or ORACLE_PASSWORD (required)
 */
const os = require('os');
const { SodaClient } = require('../src/oracle/soda');

const DEFAULT_STAGING_SODA_URL = 'https://gfe473165e66472-coroutestaging.adb.ap-hyderabad-1.oraclecloudapps.com/ords/admin/soda/latest';
const COLLECTION = '_staging_keepalive';
const RETENTION_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

async function runStagingKeepalive({
  env = process.env,
  sodaClient = null,
  nowMs = Date.now(),
  log = console,
  dryRun = false,
} = {}) {
  const url = env.STAGING_ORACLE_SODA_URL || DEFAULT_STAGING_SODA_URL;
  const user = env.STAGING_ORACLE_USER || 'admin';
  const password = env.STAGING_ORACLE_PASSWORD || env.ORACLE_PASSWORD;

  if (!sodaClient && !password && url !== 'memory') {
    throw new Error('STAGING_ORACLE_PASSWORD or ORACLE_PASSWORD must be set.');
  }

  const soda = sodaClient || (url === 'memory'
    ? new (require('../src/oracle/memory_soda').MemorySoda)()
    : new SodaClient({ baseUrl: url, user, password, timeoutMs: 30000 }));

  if (dryRun) {
    log.info(`[staging-keepalive] Dry-run check against ${url} as ${user}`);
    const pingOk = await soda.ping();
    return { ok: pingOk, dryRun: true };
  }

  // 1. Ensure the collection exists
  await soda.ensureCollection(COLLECTION);

  // 2. Insert heartbeat document
  const doc = {
    heartbeat: true,
    timestamp: nowMs,
    isoDate: new Date(nowMs).toISOString(),
    host: os.hostname(),
    source: 'staging_keepalive',
    status: 'ACTIVE',
    note: 'Oracle Always Free inactivity prevention heartbeat',
  };

  const key = await soda.insert(COLLECTION, doc);
  log.info(`[staging-keepalive] Staging heartbeat inserted: key=${key} at ${doc.isoDate}`);

  // 3. Prune heartbeats older than 30 days
  const cutoff = nowMs - RETENTION_MS;
  let pruned = 0;
  try {
    pruned = await soda.removeWhere(COLLECTION, { timestamp: { $lt: cutoff } });
    if (pruned > 0) {
      log.info(`[staging-keepalive] Pruned ${pruned} old heartbeat document(s) older than 30 days`);
    }
  } catch (err) {
    log.warn(`[staging-keepalive] Prune warning (non-fatal): ${err.message}`);
  }

  return { ok: true, key, timestamp: nowMs, pruned };
}

module.exports = { runStagingKeepalive, COLLECTION, DEFAULT_STAGING_SODA_URL };

if (require.main === module) {
  const isDryRun = process.argv.includes('--dry-run');
  runStagingKeepalive({ dryRun: isDryRun })
    .then((res) => {
      console.log(`[staging-keepalive] Succeeded: ${JSON.stringify(res)}`);
      process.exit(0);
    })
    .catch((err) => {
      console.error(`[staging-keepalive] Failed: ${err.message}`);
      process.exit(1);
    });
}
