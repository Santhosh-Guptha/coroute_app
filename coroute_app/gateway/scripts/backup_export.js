#!/usr/bin/env node
'use strict';
/**
 * Runs one encrypted backup now (the same thing the gateway's backup jobs do on a timer).
 *
 *   node scripts/backup_export.js [--set critical|full] [--out <dir>] [--prune]
 *
 * Reads ORACLE_SODA_URL / ORACLE_USER / ORACLE_PASSWORD (the database to back up) and
 * BACKUP_ENCRYPTION_KEY. Uploads to BACKUP_PAR_URL, or with --out writes the encrypted file and
 * its manifest into a local folder instead (e.g. before a risky migration).
 * --prune also applies BACKUP_RETENTION_DAYS to the bucket.
 */
const fs = require('fs');
const path = require('path');
const { SodaClient } = require('../src/oracle/soda');
const { createParStore, createMemoryStore } = require('../src/object_store');
const { runBackup, pruneBackups, parseKey, backupSettings } = require('../src/backup_jobs');

async function main(argv = process.argv.slice(2), env = process.env) {
  const opt = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : undefined; };
  const set = opt('--set') || 'full';
  if (!['critical', 'full'].includes(set)) throw new Error('--set must be critical or full');
  const cfg = backupSettings(env);
  const key = parseKey(cfg.keyB64);
  for (const k of ['ORACLE_SODA_URL', 'ORACLE_USER', 'ORACLE_PASSWORD']) if (!env[k]) throw new Error(`Set ${k}.`);
  const soda = new SodaClient({ baseUrl: env.ORACLE_SODA_URL, user: env.ORACLE_USER, password: env.ORACLE_PASSWORD, timeoutMs: 30000 });
  const out = opt('--out');
  let store;
  if (out) store = createMemoryStore();
  else if (cfg.parUrl) store = createParStore(cfg.parUrl);
  else throw new Error('Set BACKUP_PAR_URL, or pass --out <dir>.');
  const manifest = await runBackup({ soda, store, key, set, now: Date.now(), log: console });
  if (out) {
    for (const [name, o] of store.objects) {
      const file = path.join(out, path.basename(name));
      await fs.promises.mkdir(out, { recursive: true });
      await fs.promises.writeFile(file, o.body, { mode: 0o600 });
      console.log('wrote', file);
    }
  } else if (argv.includes('--prune')) {
    console.log('retention', JSON.stringify(await pruneBackups({ store, retentionDays: cfg.retentionDays })));
  }
  console.log(JSON.stringify({ object: manifest.object, total: manifest.total, counts: manifest.counts, bytes: manifest.bytes }));
}

module.exports = { main };

if (require.main === module) {
  require('dotenv').config();
  main().catch((e) => { console.error(e.message); process.exit(1); });
}
