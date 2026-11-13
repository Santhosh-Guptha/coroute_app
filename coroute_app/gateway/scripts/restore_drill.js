#!/usr/bin/env node
'use strict';
/**
 * Backup restore drill (v3.56): proves a backup file can really be restored, without touching any database.
 *
 *   node scripts/restore_drill.js --file /var/backups/coroute/daily/2026-11-12/21-full.json.gz.enc [--manifest x] [--json]
 *   node scripts/restore_drill.js --latest-dir /var/backups/coroute/daily      (newest *.json.gz.enc below it)
 *   ... --mail   e-mails the result to DRILL_MAIL_TO (or ALERT_TO) through the gateway's SMTP settings (SMTP_*, MAIL_FROM)
 *
 * Steps: decrypt (AES-256-GCM with BACKUP_ENCRYPTION_KEY: a wrong key or any changed byte fails), check sha256 and
 * document counts against the manifest, restore EVERY collection into an in-memory database (MemorySoda, the
 * same code path as scripts/backup_restore.js, indexes created by Repo.migrate), then count the documents in it
 * and compare. Exit code 0 = drill passed, 1 = failed. Prints one JSON line with the result (no document content).
 */
const fs = require('fs');
const path = require('path');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { restoreBackup, parseKey, backupSettings } = require('../src/backup_jobs');

function newestBackup(dir) {
  const found = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.json.gz.enc')) found.push({ p, t: fs.statSync(p).mtimeMs });
    }
  };
  walk(dir);
  found.sort((a, b) => b.t - a.t);
  return found.length ? found[0].p : null;
}

async function countAll(soda, name) {
  let n = 0;
  for (let off = 0; ; off += 1000) {
    const rows = await soda.query(name, {}, { limit: 1000, offset: off, fields: 'id' });
    n += rows.length;
    if (rows.length < 1000) return n;
  }
}

async function drill({ file, manifestFile = null, env = process.env, log = { info() {} } } = {}) {
  const started = Date.now();
  const cfg = backupSettings(env);
  const key = parseKey(cfg.keyB64);
  const blob = await fs.promises.readFile(file);
  const mf = manifestFile || file.replace(/\.json\.gz\.enc$/, '.manifest.json');
  const manifest = fs.existsSync(mf) ? JSON.parse(await fs.promises.readFile(mf, 'utf8')) : null;
  if (!manifest) throw new Error(`Manifest not found next to ${path.basename(file)} (a drill never restores an unverified file).`);
  const soda = new MemorySoda();
  const { Repo } = require('../src/oracle/repo');
  // The target is the in-memory database created above (never a real one), so the production guard does not apply.
  const result = await restoreBackup({ soda, blob, key, manifest, allowProduction: true, migrate: () => new Repo(soda).migrate(), log });
  const mismatches = [];
  let total = 0;
  for (const [c, expected] of Object.entries(result.plan)) {
    const got = await countAll(soda, c);
    total += got;
    if (got !== expected) mismatches.push({ collection: c, expected, restored: got });
  }
  return {
    ok: mismatches.length === 0, file: path.basename(file), set: result.set, backupCreatedAt: result.createdAt,
    backupAgeHours: result.createdAt ? +((Date.now() - Number(new Date(result.createdAt))) / 3600000).toFixed(1) : null,
    collections: Object.keys(result.plan).length, documents: total, bytes: blob.length, mismatches, seconds: +((Date.now() - started) / 1000).toFixed(1),
  };
}

async function mail(result, env = process.env) {
  const to = env.DRILL_MAIL_TO || env.ALERT_TO;
  if (!to || !env.SMTP_HOST) return false;
  const nodemailer = require('nodemailer');
  const port = Number(env.SMTP_PORT || 587);
  const t = nodemailer.createTransport({ host: env.SMTP_HOST, port, secure: port === 465, auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASS || env.SMTP_PASSWORD } : undefined });
  const subject = `[CoRoute] restore drill ${result.ok ? 'PASSED' : 'FAILED'}: ${result.documents ?? 0} documents, ${result.collections ?? 0} collections`;
  await t.sendMail({ from: env.MAIL_FROM || env.SMTP_USER, to, subject, text: `${JSON.stringify(result, null, 2)}\n\nHost: ${require('os').hostname()}\n` });
  return true;
}

async function main(argv = process.argv.slice(2), env = process.env) {
  const opt = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : undefined; };
  let file = opt('--file');
  if (!file && opt('--latest-dir')) file = newestBackup(opt('--latest-dir'));
  if (!file) throw new Error('Pass --file <backup.json.gz.enc> or --latest-dir <dir>.');
  let result;
  try { result = await drill({ file, manifestFile: opt('--manifest'), env }); } catch (e) { result = { ok: false, file: path.basename(file), error: String(e.message).slice(0, 300) }; }
  console.log(JSON.stringify(result));
  if (argv.includes('--mail')) await mail(result, env).catch((e) => console.error(`mail failed: ${e.message}`));
  return result;
}

module.exports = { drill, newestBackup, main };

if (require.main === module) {
  main().then((r) => process.exit(r.ok ? 0 : 1)).catch((e) => { console.error(e.message); process.exit(1); });
}
