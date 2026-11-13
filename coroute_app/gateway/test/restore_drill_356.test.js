'use strict';
/**
 * v3.56 restore drill (scripts/restore_drill.js): an encrypted backup written to disk restores completely into an
 * in-memory database and its counts match the manifest; a wrong key, a changed byte or a missing manifest fails.
 */
process.env.NODE_ENV = 'test';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { createMemoryStore } = require('../src/object_store');
const bj = require('../src/backup_jobs');
const { drill, newestBackup } = require('../scripts/restore_drill');

const KEY_B64 = crypto.randomBytes(32).toString('base64');
const quiet = { info() {}, warn() {}, error() {} };

async function backupToDisk() {
  const soda = new MemorySoda();
  for (const c of ['users', 'alerts', 'convoys']) await soda.ensureCollection(c);
  for (let i = 0; i < 25; i++) await soda.insert('users', { userId: `usr_${i}`, name: `R${i}` });
  for (let i = 0; i < 3; i++) await soda.insert('alerts', { alertId: `a${i}`, groupId: 'GRP-1', userId: 'usr_1' });
  await soda.insert('convoys', { groupId: 'GRP-1' });
  const store = createMemoryStore();
  await bj.runBackup({ soda, store, key: bj.parseKey(KEY_B64), set: 'full', now: Date.now(), log: quiet });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'drill-'));
  const day = path.join(dir, 'daily', '2026-11-12');
  fs.mkdirSync(day, { recursive: true });
  let file = null;
  for (const [name, o] of store.objects) {
    const p = path.join(day, path.basename(name));
    fs.writeFileSync(p, o.body);
    if (p.endsWith('.json.gz.enc')) file = p;
  }
  return { dir, file };
}

test('a good backup restores completely and the counts match', async () => {
  const { dir, file } = await backupToDisk();
  assert.equal(newestBackup(dir), file);
  const r = await drill({ file, env: { BACKUP_ENCRYPTION_KEY: KEY_B64 } });
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.ok(r.documents >= 29, `documents ${r.documents}`);
  assert.deepEqual(r.mismatches, []);
});

test('a wrong key, a changed byte or a missing manifest fails the drill', async () => {
  const { file } = await backupToDisk();
  await assert.rejects(drill({ file, env: { BACKUP_ENCRYPTION_KEY: crypto.randomBytes(32).toString('base64') } }));
  const buf = fs.readFileSync(file); buf[buf.length - 5] ^= 0xff; fs.writeFileSync(file, buf);
  await assert.rejects(drill({ file, env: { BACKUP_ENCRYPTION_KEY: KEY_B64 } }));
  const { file: f2 } = await backupToDisk();
  fs.unlinkSync(f2.replace(/\.json\.gz\.enc$/, '.manifest.json'));
  await assert.rejects(drill({ file: f2, env: { BACKUP_ENCRYPTION_KEY: KEY_B64 } }), /Manifest not found/);
});
