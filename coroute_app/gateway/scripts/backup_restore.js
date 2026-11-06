#!/usr/bin/env node
'use strict';
/**
 * Restores an encrypted CoRoute backup into a TARGET database.
 *
 *   node scripts/backup_restore.js --file <x.json.gz.enc> [--manifest <x.manifest.json>]
 *   node scripts/backup_restore.js --object coroute/2026/11/06/21-full.json.gz.enc
 *   node scripts/backup_restore.js --latest full|critical
 *     [--collections users,memberships] [--dry-run] [--wipe] [--i-understand-this-overwrites-production]
 *
 * Target: RESTORE_SODA_URL / RESTORE_ORACLE_USER / RESTORE_ORACLE_PASSWORD, falling back to
 * ORACLE_SODA_URL / ORACLE_USER / ORACLE_PASSWORD. Key: BACKUP_ENCRYPTION_KEY. Bucket: BACKUP_PAR_URL.
 *
 * Safety:
 *  - the file is decrypted (AES-256-GCM: a wrong key or any changed byte fails) and checked against
 *    its manifest (sha256, document counts) before anything is written;
 *  - refuses when the target host is the backup's source host or listed in BACKUP_PRODUCTION_HOSTS
 *    (comma separated hosts), unless --i-understand-this-overwrites-production;
 *  - refuses non-empty target collections unless --wipe (which deletes their documents first);
 *  - --dry-run checks everything and prints what would be restored, writing nothing.
 * Documents get new SODA keys (nothing refers to keys; every reference is a business id).
 * Collections and indexes are created first (Repo.migrate), as at gateway boot.
 */
const fs = require('fs');
const { SodaClient } = require('../src/oracle/soda');
const { createParStore } = require('../src/object_store');
const { restoreBackup, parseKey, backupSettings, PREFIX } = require('../src/backup_jobs');

const manifestNameOf = (object) => object.replace(/\.json\.gz\.enc$/, '.manifest.json');

async function main(argv = process.argv.slice(2), env = process.env, { soda: givenSoda = null, store: givenStore = null, log = console } = {}) {
  const opt = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : undefined; };
  const flag = (f) => argv.includes(f);
  const cfg = backupSettings(env);
  const key = parseKey(cfg.keyB64);
  const store = givenStore || (cfg.parUrl ? createParStore(cfg.parUrl) : null);

  let blob; let manifest = null;
  if (opt('--file')) {
    blob = await fs.promises.readFile(opt('--file'));
    const mf = opt('--manifest') || (opt('--file').endsWith('.json.gz.enc') ? manifestNameOf(opt('--file')) : null);
    if (mf && fs.existsSync(mf)) manifest = JSON.parse(await fs.promises.readFile(mf, 'utf8'));
    else if (opt('--manifest')) throw new Error(`Manifest not found: ${opt('--manifest')}`);
  } else {
    if (!store) throw new Error('Set BACKUP_PAR_URL (or use --file).');
    let object = opt('--object');
    if (!object && opt('--latest')) {
      const set = opt('--latest');
      const all = (await store.list(PREFIX)).map((o) => o.name).filter((n) => n.endsWith(`-${set}.json.gz.enc`)).sort();
      object = all[all.length - 1];
      if (!object) throw new Error(`No ${set} backup found.`);
    }
    if (!object) throw new Error('Pass --file, --object or --latest.');
    blob = await store.get(object);
    if (!blob) throw new Error(`Backup not found: ${object}`);
    const m = await store.get(manifestNameOf(object));
    if (!m) throw new Error(`Manifest not found for ${object} (refusing to restore unverified).`);
    manifest = JSON.parse(m.toString('utf8'));
    log.info?.(`[restore] ${object}`);
  }

  let soda = givenSoda;
  if (!soda) {
    const url = env.RESTORE_SODA_URL || env.ORACLE_SODA_URL;
    const user = env.RESTORE_ORACLE_USER || env.ORACLE_USER;
    const password = env.RESTORE_ORACLE_PASSWORD || env.ORACLE_PASSWORD;
    if (!url || !user || !password) throw new Error('Set RESTORE_SODA_URL, RESTORE_ORACLE_USER and RESTORE_ORACLE_PASSWORD (the TARGET database).');
    soda = new SodaClient({ baseUrl: url, user, password, timeoutMs: 30000 });
  }
  const productionHosts = String(env.BACKUP_PRODUCTION_HOSTS || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  const collections = opt('--collections') ? opt('--collections').split(',').map((s) => s.trim()).filter(Boolean) : null;
  const { Repo } = require('../src/oracle/repo');
  const result = await restoreBackup({
    soda, blob, key, manifest, collections,
    dryRun: flag('--dry-run'), wipe: flag('--wipe'),
    productionHosts, allowProduction: flag('--i-understand-this-overwrites-production'),
    migrate: () => new Repo(soda).migrate(), log,
  });
  log.info?.(JSON.stringify(result, null, 2));
  return result;
}

module.exports = { main };

if (require.main === module) {
  require('dotenv').config();
  main().catch((e) => { console.error(e.message); process.exit(1); });
}
