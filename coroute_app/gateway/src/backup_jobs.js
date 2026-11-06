'use strict';
/**
 * Encrypted database backups to OCI Object Storage (bucket PAR), with no OCI SDK.
 *
 * What:  'critical' (hourly)  accounts, memberships, coupons, payments / orders / pricing
 *                             (subscription_config), SOS alerts, feedback & reviews, guardian grants,
 *                             consents, revocations and subscriptions, organizations, convoys.
 *        'full'     (nightly) every collection (the repo's list plus whatever the database lists).
 * How:   every document of each collection is read page by page (nothing is skipped), written as
 *        gzip'd JSON lines, then encrypted with AES-256-GCM:
 *          file  = "CRBK" | version(1) | salt(16) | iv(12) | tag(16) | ciphertext
 *          key   = HKDF-SHA256(BACKUP_ENCRYPTION_KEY, salt, "coroute-backup-v1")  (fresh salt per file)
 *          AAD   = "CRBK" | version | salt | iv   (the header cannot be changed either)
 *        The file goes to  coroute/<yyyy>/<mm>/<dd>/<HH>-<set>.json.gz.enc  (UTC) and a manifest
 *        coroute/<yyyy>/<mm>/<dd>/<HH>-<set>.manifest.json  with document counts and sha256 of the
 *        gzip (plaintext) and of the encrypted file. coroute/state/last-full.json marks the last full day.
 * Keep:  BACKUP_RETENTION_DAYS (30): older backups are deleted through the PAR when it allows listing
 *        and DELETE; when DELETE is refused they are overwritten with a tiny tombstone. When the PAR
 *        cannot list, set an Object Storage lifecycle rule instead (prefix "coroute/", delete after
 *        30 days) — the log says so once.
 * Restore: scripts/backup_restore.js (restoreBackup below).
 *
 * The BACKUP_ENCRYPTION_KEY must be kept OUTSIDE the bucket and the VM image (password manager):
 * without it no backup can be read.
 */
const crypto = require('crypto');
const zlib = require('zlib');
const { createParStore } = require('./object_store');

const MAGIC = Buffer.from('CRBK', 'ascii');
const VERSION = 1;
const HKDF_INFO = Buffer.from('coroute-backup-v1', 'utf8');
const HEADER_LEN = 4 + 1 + 16 + 12; // magic, version, salt, iv
const TAG_LEN = 16;
const PREFIX = 'coroute/';
const STATE_FULL = `${PREFIX}state/last-full.json`;

/** Collections of the hourly 'critical' set (names as stored in Oracle; see repo.js COLLECTIONS). */
const CRITICAL_COLLECTIONS = Object.freeze([
  'users', 'organizations', 'memberships', 'coupons', 'subscription_config', 'alerts', 'feedback',
  'guardian_grants', 'guardian_consents', 'guardian_revocations', 'guardian_subscriptions', 'convoys',
]);

class BackupError extends Error {
  constructor(message, code = 'BACKUP') { super(message); this.name = 'BackupError'; this.code = code; }
}

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

function parseKey(b64) {
  const s = String(b64 || '').trim();
  const key = Buffer.from(s, 'base64');
  if (!s || key.length !== 32) throw new BackupError('BACKUP_ENCRYPTION_KEY must be 32 random bytes, base64 encoded (openssl rand -base64 32).', 'BAD_KEY');
  return key;
}

function deriveKey(master, salt) {
  return Buffer.from(crypto.hkdfSync('sha256', master, salt, HKDF_INFO, 32));
}

function encrypt(plain, master) {
  const salt = crypto.randomBytes(16);
  const iv = crypto.randomBytes(12);
  const header = Buffer.concat([MAGIC, Buffer.from([VERSION]), salt, iv]);
  const cipher = crypto.createCipheriv('aes-256-gcm', deriveKey(master, salt), iv);
  cipher.setAAD(header);
  const ct = Buffer.concat([cipher.update(plain), cipher.final()]);
  return Buffer.concat([header, cipher.getAuthTag(), ct]);
}

function decrypt(blob, master) {
  if (!Buffer.isBuffer(blob) || blob.length < HEADER_LEN + TAG_LEN || !blob.subarray(0, 4).equals(MAGIC)) {
    throw new BackupError('This is not a CoRoute backup file.', 'NOT_A_BACKUP');
  }
  const version = blob[4];
  if (version !== VERSION) throw new BackupError(`Unsupported backup version ${version}.`, 'VERSION');
  const header = blob.subarray(0, HEADER_LEN);
  const salt = blob.subarray(5, 21);
  const iv = blob.subarray(21, HEADER_LEN);
  const tag = blob.subarray(HEADER_LEN, HEADER_LEN + TAG_LEN);
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', deriveKey(master, salt), iv);
    d.setAAD(header);
    d.setAuthTag(tag);
    return Buffer.concat([d.update(blob.subarray(HEADER_LEN + TAG_LEN)), d.final()]);
  } catch {
    throw new BackupError('The backup could not be decrypted: wrong key, or the file was changed or damaged.', 'DECRYPT');
  }
}

const pad = (n) => String(n).padStart(2, '0');
/** Object names of one backup (UTC hour). */
function backupNames(set, at = Date.now()) {
  const d = new Date(at);
  const dir = `${PREFIX}${d.getUTCFullYear()}/${pad(d.getUTCMonth() + 1)}/${pad(d.getUTCDate())}`;
  const stem = `${dir}/${pad(d.getUTCHours())}-${set}`;
  return { object: `${stem}.json.gz.enc`, manifest: `${stem}.manifest.json` };
}
const dayOf = (at) => new Date(at).toISOString().slice(0, 10);

function hostOf(soda) {
  try { return new URL(soda.baseUrl).host.toLowerCase(); } catch { return ''; }
}

/** All documents of a collection, page by page (SodaClient.scan, or query paging as a fallback). */
async function* scanCollection(soda, coll, pageSize = 500) {
  if (typeof soda.scan === 'function') { yield* soda.scan(coll, { pageSize }); return; }
  for (let offset = 0; ; offset += pageSize) {
    const rows = await soda.query(coll, {}, { limit: pageSize, offset });
    if (rows.length) yield rows;
    if (rows.length < pageSize) return;
  }
}

/** Which collections a set covers on this database. */
async function collectionsFor(soda, set) {
  let listed = null;
  try { listed = await soda.listCollections(); } catch { /* fall back to the known names */ }
  if (set === 'full') {
    const { COLLECTIONS } = require('./oracle/repo');
    const all = new Set([...Object.values(COLLECTIONS), ...(listed || [])]);
    return [...all].filter((c) => !listed || listed.includes(c)).sort();
  }
  if (set === 'critical') return CRITICAL_COLLECTIONS.filter((c) => !listed || listed.includes(c));
  throw new BackupError(`Unknown backup set ${set}.`, 'BAD_SET');
}

/** gzip'd JSON lines of every document of `collections`: { gz, counts, total }. */
async function exportCollections(soda, collections, { set = 'custom', createdAt = Date.now(), pageSize = 500 } = {}) {
  const gzip = zlib.createGzip({ level: 6 });
  const parts = [];
  gzip.on('data', (c) => parts.push(c));
  const ended = new Promise((resolve, reject) => { gzip.on('end', resolve); gzip.on('error', reject); });
  const write = async (obj) => {
    if (!gzip.write(JSON.stringify(obj) + '\n')) await new Promise((r) => gzip.once('drain', r));
  };
  const counts = {};
  await write({ type: 'header', format: 'coroute-backup', version: VERSION, set, createdAt, sourceHost: hostOf(soda), collections });
  for (const c of collections) {
    counts[c] = 0;
    for await (const page of scanCollection(soda, c, pageSize)) {
      for (const row of page) { await write({ type: 'doc', c, k: row.key, v: row.value }); counts[c]++; }
    }
  }
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  await write({ type: 'end', counts, total });
  gzip.end();
  await ended;
  return { gz: Buffer.concat(parts), counts, total };
}

/** Builds, encrypts and uploads one backup set. Returns the manifest. */
async function runBackup({ soda, store, key, set, now = Date.now(), log = console }) {
  const started = Date.now();
  const collections = await collectionsFor(soda, set);
  const { gz, counts, total } = await exportCollections(soda, collections, { set, createdAt: now });
  const enc = encrypt(gz, key);
  const names = backupNames(set, now);
  const manifest = {
    format: 'coroute-backup-manifest', version: VERSION, set, createdAt: new Date(now).toISOString(),
    object: names.object, bytes: enc.length, gzipBytes: gz.length,
    sha256: sha256(gz), sha256Encrypted: sha256(enc), counts, total, collections, sourceHost: hostOf(soda),
    cipher: 'AES-256-GCM, HKDF-SHA256 per-file key', tookMs: 0,
  };
  await store.put(names.object, enc, 'application/octet-stream');
  manifest.tookMs = Date.now() - started;
  await store.put(names.manifest, Buffer.from(JSON.stringify(manifest, null, 2)), 'application/json');
  log.info?.(`[backup] ${set}: ${total} documents in ${collections.length} collections, ${enc.length} bytes -> ${names.object}`);
  return manifest;
}

/** Deletes (or tombstones) backups older than retentionDays. { listed, deleted, tombstoned, listSupported }. */
async function pruneBackups({ store, now = Date.now(), retentionDays = 30, log = console }) {
  const out = { listed: 0, deleted: 0, tombstoned: 0, listSupported: true };
  let objects;
  try {
    objects = await store.list(PREFIX, { raw: true });
  } catch (e) {
    if (e && e.code === 'LIST_UNSUPPORTED') { out.listSupported = false; return out; }
    throw e;
  }
  const cutoff = now - retentionDays * 86400000;
  const { TOMBSTONE } = require('./object_store');
  for (const o of objects) {
    const m = /^coroute\/(\d{4})\/(\d{2})\/(\d{2})\/(\d{2})-[a-z]+\.(json\.gz\.enc|manifest\.json)$/.exec(o.name);
    if (!m) continue;
    out.listed++;
    if (o.size === TOMBSTONE.length) continue; // already a tombstone
    const at = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4]);
    if (!(at < cutoff)) continue;
    const r = await store.del(o.name);
    if (r.tombstoned) out.tombstoned++; else out.deleted++;
  }
  if (out.deleted || out.tombstoned) log.info?.(`[backup] retention: ${out.deleted} deleted, ${out.tombstoned} tombstoned`);
  return out;
}

/** Settings from the environment (config.js may mirror them; these are the defaults). */
function backupSettings(env = process.env) {
  const int = (n, d) => { const v = parseInt(env[n], 10); return Number.isFinite(v) ? v : d; };
  return {
    parUrl: String(env.BACKUP_PAR_URL || '').trim(),
    keyB64: String(env.BACKUP_ENCRYPTION_KEY || '').trim(),
    criticalEveryMinutes: Math.max(5, int('BACKUP_CRITICAL_EVERY_MINUTES', 60)),
    fullHourUtc: Math.min(23, Math.max(0, int('BACKUP_FULL_HOUR_UTC', 21))),
    retentionDays: Math.max(1, int('BACKUP_RETENTION_DAYS', 30)),
  };
}

/**
 * Starts the backup timers. Disabled (logged once) unless BACKUP_PAR_URL and BACKUP_ENCRYPTION_KEY are set.
 *
 *   startBackupJobs({ soda, lease, logger })
 *
 * `lease.run(name, intervalMs, fn)` is the gateway's job-lease API (only one instance runs a job);
 * without it `runner` (same signature) or a plain unref'd setInterval is used. Jobs registered:
 *   'backup-critical'  every BACKUP_CRITICAL_EVERY_MINUTES (60)   critical set
 *   'backup-full'      every hour; runs the full set once per UTC day at/after BACKUP_FULL_HOUR_UTC,
 *                      then the retention pass
 * Returns { enabled, stop(), runNow(set) }.
 */
function startBackupJobs({ soda, repo, lease = null, runner = null, logger = console, env = process.env, store = null, clock = Date.now } = {}) {
  const db = soda || repo?.soda;
  const cfg = backupSettings(env);
  const off = (why) => { logger.info?.(`[backup] disabled: ${why}`); return { enabled: false, stop() {}, async runNow() { return null; } }; };
  if (!db) return off('no database client');
  if (!cfg.keyB64 || (!cfg.parUrl && !store)) return off('set BACKUP_PAR_URL and BACKUP_ENCRYPTION_KEY to enable');
  let key;
  let objectStore;
  try {
    key = parseKey(cfg.keyB64);
    objectStore = store || createParStore(cfg.parUrl);
  } catch (e) {
    logger.error?.(`[backup] disabled: ${e.message}`);
    return { enabled: false, error: e.message, stop() {}, async runNow() { return null; } };
  }
  const running = new Set();
  const guarded = (name, fn) => async () => {
    if (running.has(name)) return;
    running.add(name);
    try { await fn(); } catch (e) { logger.warn?.(`[backup] ${name} failed: ${e.message}`); } finally { running.delete(name); }
  };
  let warnedList = false;
  const runNow = async (set) => {
    const now = clock();
    const manifest = await runBackup({ soda: db, store: objectStore, key, set, now, log: logger });
    if (set === 'full') {
      await objectStore.put(STATE_FULL, Buffer.from(JSON.stringify({ day: dayOf(now), object: manifest.object })), 'application/json');
      const pr = await pruneBackups({ store: objectStore, now, retentionDays: cfg.retentionDays, log: logger });
      if (!pr.listSupported && !warnedList) {
        warnedList = true;
        logger.warn?.(`[backup] the PAR cannot list objects: set an Object Storage lifecycle rule (prefix "${PREFIX}", delete after ${cfg.retentionDays} days)`);
      }
    }
    return manifest;
  };
  const fullIfDue = async () => {
    const now = clock();
    if (new Date(now).getUTCHours() < cfg.fullHourUtc) return;
    const state = await objectStore.get(STATE_FULL).catch(() => null);
    let last = null;
    try { last = state ? JSON.parse(state.toString('utf8')).day : null; } catch { /* rewritten below */ }
    if (last === dayOf(now)) return;
    await runNow('full');
  };
  const defaultRunner = (name, ms, fn) => { const t = setInterval(fn, ms); if (t.unref) t.unref(); return { stop: () => clearInterval(t) }; };
  const run = lease && typeof lease.run === 'function' ? lease.run.bind(lease) : (runner || defaultRunner);
  const handles = [
    run('backup-critical', cfg.criticalEveryMinutes * 60000, guarded('critical', () => runNow('critical'))),
    run('backup-full', 3600000, guarded('full', fullIfDue)),
  ];
  logger.info?.(`[backup] enabled: critical every ${cfg.criticalEveryMinutes} min, full daily after ${pad(cfg.fullHourUtc)}:00 UTC, kept ${cfg.retentionDays} days`);
  return {
    enabled: true,
    store: objectStore,
    runNow,
    fullIfDue: guarded('full', fullIfDue),
    stop() {
      for (const h of handles) {
        try {
          if (typeof h === 'function') h();
          else if (h && typeof h.stop === 'function') h.stop();
          else if (h && typeof h.cancel === 'function') h.cancel();
        } catch { /* best effort */ }
      }
    },
  };
}

/** Decrypts, verifies and parses a backup file. Returns { header, docs: Map<coll, value[]>, counts }. */
function openBackup(blob, key, manifest = null) {
  if (manifest && manifest.sha256Encrypted && sha256(blob) !== manifest.sha256Encrypted) {
    throw new BackupError('The backup file does not match its manifest (sha256 of the encrypted file).', 'CHECKSUM');
  }
  const gz = decrypt(blob, key);
  if (manifest && manifest.sha256 && sha256(gz) !== manifest.sha256) throw new BackupError('The backup does not match its manifest (sha256).', 'CHECKSUM');
  let text;
  try { text = zlib.gunzipSync(gz).toString('utf8'); } catch { throw new BackupError('The backup is damaged (gzip).', 'DAMAGED'); }
  let header = null;
  let end = null;
  const docs = new Map();
  const counts = {};
  for (const line of text.split('\n')) {
    if (!line) continue;
    let rec;
    try { rec = JSON.parse(line); } catch { throw new BackupError('The backup is damaged (JSON line).', 'DAMAGED'); }
    if (rec.type === 'header') header = rec;
    else if (rec.type === 'doc') {
      if (!docs.has(rec.c)) docs.set(rec.c, []);
      docs.get(rec.c).push(rec.v);
      counts[rec.c] = (counts[rec.c] || 0) + 1;
    } else if (rec.type === 'end') end = rec;
  }
  if (!header || header.format !== 'coroute-backup' || !end) throw new BackupError('The backup is incomplete (no header or end record).', 'DAMAGED');
  for (const c of header.collections || []) if (!counts[c]) counts[c] = 0;
  for (const [c, n] of Object.entries(end.counts || {})) {
    if ((counts[c] || 0) !== n) throw new BackupError(`The backup is incomplete: ${c} has ${counts[c] || 0} of ${n} documents.`, 'DAMAGED');
  }
  if (manifest && manifest.counts) {
    for (const [c, n] of Object.entries(manifest.counts)) {
      if ((counts[c] || 0) !== n) throw new BackupError(`The backup does not match its manifest: ${c}.`, 'CHECKSUM');
    }
  }
  return { header, docs, counts };
}

/**
 * Restores a backup into `soda` (the TARGET database).
 * Refuses when the target host is a production host (the backup's own source host, or one listed in
 * productionHosts) unless allowProduction. Refuses non-empty target collections unless wipe.
 * dryRun: verifies everything and reports what would be restored, writes nothing.
 */
async function restoreBackup({ soda, blob, key, manifest = null, collections = null, dryRun = false, wipe = false,
  productionHosts = [], allowProduction = false, migrate = null, log = console, batchSize = 100 }) {
  const opened = openBackup(blob, key, manifest);
  const target = hostOf(soda);
  const prod = new Set([...productionHosts, opened.header.sourceHost, manifest?.sourceHost].filter(Boolean).map((h) => String(h).toLowerCase()));
  if (target && prod.has(target) && !allowProduction) {
    throw new BackupError(`Refusing to restore into ${target}: it is a production database. Restore into a separate database, or pass --i-understand-this-overwrites-production.`, 'PRODUCTION');
  }
  let names = [...opened.docs.keys(), ...Object.keys(opened.counts)];
  names = [...new Set(names)].sort();
  if (collections && collections.length) {
    const unknown = collections.filter((c) => !names.includes(c));
    if (unknown.length) throw new BackupError(`Not in this backup: ${unknown.join(', ')}.`, 'BAD_COLLECTION');
    names = names.filter((c) => collections.includes(c));
  }
  const plan = Object.fromEntries(names.map((c) => [c, opened.counts[c] || 0]));
  const result = { dryRun, set: opened.header.set, createdAt: opened.header.createdAt, sourceHost: opened.header.sourceHost, target, plan, restored: {} };
  if (dryRun) return result;
  if (migrate) await migrate();
  for (const c of names) await soda.ensureCollection(c);
  if (!wipe) {
    const busy = [];
    for (const c of names) if ((await soda.query(c, {}, { limit: 1 })).length) busy.push(c);
    if (busy.length) throw new BackupError(`Target collections are not empty: ${busy.join(', ')}. Use --wipe to replace their contents.`, 'NOT_EMPTY');
  }
  for (const c of names) {
    if (wipe) await soda.removeWhere(c, {});
    const docs = opened.docs.get(c) || [];
    let n = 0;
    for (let i = 0; i < docs.length; i += batchSize) {
      const part = docs.slice(i, i + batchSize);
      if (typeof soda.insertMany === 'function') await soda.insertMany(c, part);
      else for (const d of part) await soda.insert(c, d);
      n += part.length;
    }
    result.restored[c] = n;
    log.info?.(`[restore] ${c}: ${n}`);
  }
  return result;
}

module.exports = {
  CRITICAL_COLLECTIONS, BackupError, PREFIX, STATE_FULL,
  parseKey, encrypt, decrypt, backupNames, collectionsFor, exportCollections, runBackup, pruneBackups,
  backupSettings, startBackupJobs, openBackup, restoreBackup, hostOf, sha256,
};
