'use strict';
/** Encrypted backups: export -> PAR -> restore round trip, key / tamper / production guards, jobs, retention. */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { createParStore, createMemoryStore, TOMBSTONE } = require('../src/object_store');
const bj = require('../src/backup_jobs');
const { startParServer } = require('./_par_server');
const restoreCli = require('../scripts/backup_restore');

const quiet = { info() {}, warn() {}, error() {} };
const KEY_B64 = crypto.randomBytes(32).toString('base64');
const KEY = bj.parseKey(KEY_B64);
const AT = Date.UTC(2026, 10, 6, 21, 5, 0);

class HostSoda extends MemorySoda {
  constructor(host) { super(); this.baseUrl = `https://${host}/ords/coroute/soda/latest`; }
}

async function seeded(host = 'prod-db.adb.ap-hyderabad-1.oraclecloudapps.com') {
  const soda = new HostSoda(host);
  const repo = new Repo(soda);
  await repo.migrate();
  for (let i = 0; i < 1234; i++) await soda.insert('users', { userId: `u${i}`, email: `u${i}@x.test`, name: `Rider ${i}`, nameLower: `rider ${i}` });
  await soda.insert('memberships', { membershipId: 'm1', ownerUserId: 'u1', status: 'ACTIVE', validUntil: 9e12 });
  await soda.insert('subscription_config', { k: 'rzp_order', orderId: 'order_1', amount: 49900 });
  await soda.insert('alerts', { alertId: 'a1', groupId: 'G1', userId: 'u2', resolved: false });
  await soda.insert('geo_cache', { k: 'x', value: { a: 1 }, createdAt: 1 });
  return { soda, repo };
}
const dump = async (soda, coll) => (await soda.query(coll, {}, { limit: 100000 })).map((r) => r.value)
  .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));

test('encryption: per-file salt and IV, wrong key and any changed byte fail', () => {
  const plain = Buffer.from('hello backups');
  const a = bj.encrypt(plain, KEY);
  const b = bj.encrypt(plain, KEY);
  assert.notDeepEqual(a, b, 'fresh salt / iv every time');
  assert.equal(a.subarray(0, 4).toString(), 'CRBK');
  assert.equal(a[4], 1, 'version');
  assert.deepEqual(bj.decrypt(a, KEY), plain);
  assert.throws(() => bj.decrypt(a, crypto.randomBytes(32)), (e) => e.code === 'DECRYPT');
  for (const pos of [5, 22, 40, a.length - 1]) { // salt, iv, tag, ciphertext
    const bad = Buffer.from(a); bad[pos] ^= 1;
    assert.throws(() => bj.decrypt(bad, KEY), (e) => e.code === 'DECRYPT', `byte ${pos}`);
  }
  assert.throws(() => bj.decrypt(Buffer.from('PK\x03\x04 a zip file, not a backup.........................................'), KEY), (e) => e.code === 'NOT_A_BACKUP');
  assert.throws(() => bj.parseKey('c2hvcnQ='), (e) => e.code === 'BAD_KEY');
  assert.throws(() => bj.parseKey(''), (e) => e.code === 'BAD_KEY');
});

test('collection sets: critical holds accounts, payments, SOS, reviews, guardians; full holds everything', async () => {
  const { soda } = await seeded();
  const critical = await bj.collectionsFor(soda, 'critical');
  for (const c of ['users', 'memberships', 'coupons', 'subscription_config', 'alerts', 'feedback', 'guardian_grants']) assert.ok(critical.includes(c), c);
  assert.ok(!critical.includes('geo_cache') && !critical.includes('track_chunks'));
  await soda.ensureCollection('leases'); // a collection created outside repo.js is included too
  const full = await bj.collectionsFor(soda, 'full');
  for (const c of ['users', 'track_chunks', 'room_snapshots', 'geo_cache', 'leases']) assert.ok(full.includes(c), c);
});

test('round trip: full backup to a PAR, restore into an empty database, every document back', async (t) => {
  const par = await startParServer({ pageSize: 2 });
  t.after(() => par.close());
  const { soda } = await seeded();
  const store = createParStore(par.url, { backoffMs: 5 });
  const manifest = await bj.runBackup({ soda, store, key: KEY, set: 'full', now: AT, log: quiet });
  assert.equal(manifest.object, 'coroute/2026/11/06/21-full.json.gz.enc');
  assert.ok(par.objects.has('coroute/2026/11/06/21-full.json.gz.enc'));
  assert.ok(par.objects.has('coroute/2026/11/06/21-full.manifest.json'));
  assert.equal(manifest.counts.users, 1234, 'paged through all documents');
  assert.equal(manifest.total, 1234 + 4);
  const enc = par.objects.get(manifest.object).body;
  assert.ok(!enc.includes(Buffer.from('u1@x.test')), 'nothing readable in the bucket');
  assert.equal(manifest.sha256Encrypted, bj.sha256(enc));

  const target = new HostSoda('restore-test.adb.ap-hyderabad-1.oraclecloudapps.com');
  const res = await bj.restoreBackup({ soda: target, blob: enc, key: KEY, manifest, migrate: () => new Repo(target).migrate(), log: quiet });
  assert.equal(res.restored.users, 1234);
  for (const c of ['users', 'memberships', 'subscription_config', 'alerts', 'geo_cache']) {
    assert.deepEqual(await dump(target, c), await dump(soda, c), c);
  }
  // Indexes exist on the target (repo.migrate ran first): a duplicate userId is refused.
  await assert.rejects(target.insert('users', { userId: 'u1', email: 'other@x.test' }));
});

test('restore refuses: wrong key, tampered file, manifest mismatch, production host, non-empty target', async () => {
  const { soda } = await seeded();
  const store = createMemoryStore();
  const manifest = await bj.runBackup({ soda, store, key: KEY, set: 'critical', now: AT, log: quiet });
  const blob = await store.get(manifest.object);
  const empty = () => new HostSoda('staging-db.example.com');

  await assert.rejects(bj.restoreBackup({ soda: empty(), blob, key: crypto.randomBytes(32), manifest, log: quiet }), (e) => e.code === 'DECRYPT');
  const tampered = Buffer.from(blob); tampered[tampered.length - 10] ^= 0x40;
  await assert.rejects(bj.restoreBackup({ soda: empty(), blob: tampered, key: KEY, log: quiet }), (e) => e.code === 'DECRYPT');
  await assert.rejects(bj.restoreBackup({ soda: empty(), blob: tampered, key: KEY, manifest, log: quiet }), (e) => e.code === 'CHECKSUM');
  await assert.rejects(bj.restoreBackup({ soda: empty(), blob, key: KEY, manifest: { ...manifest, sha256Encrypted: null, sha256: 'ab'.repeat(32) }, log: quiet }), (e) => e.code === 'CHECKSUM');
  await assert.rejects(bj.restoreBackup({ soda: empty(), blob, key: KEY, manifest: { ...manifest, sha256Encrypted: null, counts: { ...manifest.counts, users: 1 } }, log: quiet }), (e) => e.code === 'CHECKSUM');

  // Production: the backup's own source database, or a listed production host.
  await assert.rejects(bj.restoreBackup({ soda, blob, key: KEY, manifest, wipe: true, log: quiet }), (e) => e.code === 'PRODUCTION');
  await assert.rejects(bj.restoreBackup({ soda: empty(), blob, key: KEY, manifest, productionHosts: ['staging-db.example.com'], log: quiet }), (e) => e.code === 'PRODUCTION');
  const ok = await bj.restoreBackup({ soda, blob, key: KEY, manifest, wipe: true, allowProduction: true, log: quiet });
  assert.equal(ok.restored.users, 1234);
  assert.equal((await soda.query('users', {}, { limit: 100000 })).length, 1234, 'wiped then restored, not doubled');

  // A non-empty target needs --wipe.
  const busy = empty();
  await busy.insert('users', { userId: 'someone' });
  await assert.rejects(bj.restoreBackup({ soda: busy, blob, key: KEY, manifest, log: quiet }), (e) => e.code === 'NOT_EMPTY');
  assert.equal((await busy.query('users', {}, { limit: 10 })).length, 1, 'nothing written when refused');
});

test('dry run writes nothing; --collections restores only those', async () => {
  const { soda } = await seeded();
  const store = createMemoryStore();
  const manifest = await bj.runBackup({ soda, store, key: KEY, set: 'critical', now: AT, log: quiet });
  const blob = await store.get(manifest.object);
  const target = new HostSoda('staging-db.example.com');
  const dry = await bj.restoreBackup({ soda: target, blob, key: KEY, manifest, dryRun: true, log: quiet });
  assert.equal(dry.plan.users, 1234);
  assert.equal(dry.dryRun, true);
  assert.deepEqual(await target.listCollections(), []);
  const part = await bj.restoreBackup({ soda: target, blob, key: KEY, manifest, collections: ['memberships', 'alerts'], log: quiet });
  assert.deepEqual(Object.keys(part.restored).sort(), ['alerts', 'memberships']);
  assert.equal((await target.query('users', {}, {})).length, 0);
  await assert.rejects(bj.restoreBackup({ soda: target, blob, key: KEY, manifest, collections: ['nope'], log: quiet }), (e) => e.code === 'BAD_COLLECTION');
});

test('restore CLI: --file with its manifest, --object from the bucket, production refusal', async (t) => {
  const par = await startParServer();
  t.after(() => par.close());
  const { soda } = await seeded();
  const store = createParStore(par.url, { backoffMs: 5 });
  const manifest = await bj.runBackup({ soda, store, key: KEY, set: 'critical', now: AT, log: quiet });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bk-'));
  const file = path.join(dir, '21-critical.json.gz.enc');
  fs.writeFileSync(file, par.objects.get(manifest.object).body);
  fs.writeFileSync(path.join(dir, '21-critical.manifest.json'), par.objects.get(manifest.object.replace('.json.gz.enc', '.manifest.json')).body);
  const env = { BACKUP_ENCRYPTION_KEY: KEY_B64, BACKUP_PAR_URL: par.url };

  const dry = await restoreCli.main(['--file', file, '--dry-run'], env, { soda: new HostSoda('staging.example.com'), log: quiet });
  assert.equal(dry.plan.users, 1234);
  const target = new HostSoda('staging.example.com');
  const r = await restoreCli.main(['--object', manifest.object, '--collections', 'users'], env, { soda: target, log: quiet });
  assert.equal(r.restored.users, 1234);
  const latest = await restoreCli.main(['--latest', 'critical', '--dry-run'], env, { soda: new HostSoda('staging.example.com'), log: quiet });
  assert.equal(latest.plan.users, 1234);
  await assert.rejects(restoreCli.main(['--file', file, '--wipe'], env, { soda, log: quiet }), /production/);
  await assert.rejects(restoreCli.main(['--file', file, '--dry-run'], { ...env, BACKUP_ENCRYPTION_KEY: crypto.randomBytes(32).toString('base64') }, { soda: target, log: quiet }), /could not be decrypted/);
});

test('retention: backups older than 30 days are deleted, or tombstoned when the PAR refuses DELETE', async (t) => {
  for (const allowDelete of [true, false]) {
    const par = await startParServer({ allowDelete });
    t.after(() => par.close());
    const store = createParStore(par.url, { backoffMs: 5 });
    const put = (n) => store.put(n, Buffer.from('x'.repeat(100)));
    await put('coroute/2026/09/01/03-critical.json.gz.enc');
    await put('coroute/2026/09/01/03-critical.manifest.json');
    await put('coroute/2026/10/20/21-full.json.gz.enc');
    await put('coroute/state/last-full.json');
    await put('elsewhere/2020/01/01/00-full.json.gz.enc');
    const r = await bj.pruneBackups({ store, now: AT, retentionDays: 30, log: quiet });
    assert.equal(r.listSupported, true);
    if (allowDelete) {
      assert.equal(r.deleted, 2);
      assert.ok(!par.objects.has('coroute/2026/09/01/03-critical.json.gz.enc'));
    } else {
      assert.equal(r.tombstoned, 2);
      assert.ok(par.objects.get('coroute/2026/09/01/03-critical.json.gz.enc').body.equals(TOMBSTONE));
      const again = await bj.pruneBackups({ store, now: AT, retentionDays: 30, log: quiet });
      assert.equal(again.tombstoned, 0, 'tombstones are not rewritten');
    }
    assert.ok(par.objects.has('coroute/2026/10/20/21-full.json.gz.enc'), 'recent kept');
    assert.ok(par.objects.has('coroute/state/last-full.json'));
    assert.ok(par.objects.has('elsewhere/2020/01/01/00-full.json.gz.enc'), 'other prefixes untouched');
  }
  const par = await startParServer({ allowList: false });
  t.after(() => par.close());
  const r = await bj.pruneBackups({ store: createParStore(par.url, { backoffMs: 5 }), now: AT, log: quiet });
  assert.equal(r.listSupported, false);
});

test('startBackupJobs: disabled without settings, registers leased jobs, full once per day after the hour', async () => {
  const { soda } = await seeded();
  assert.equal(bj.startBackupJobs({ soda, env: {}, logger: quiet }).enabled, false);
  const bad = bj.startBackupJobs({ soda, env: { BACKUP_PAR_URL: 'https://x/p/t/n/ns/b/b/o/', BACKUP_ENCRYPTION_KEY: 'short' }, logger: quiet });
  assert.equal(bad.enabled, false);

  const jobs = new Map();
  const lease = { run(name, intervalMs, fn) { jobs.set(name, { intervalMs, fn }); return { stop() { jobs.get(name).stopped = true; } }; } };
  const store = createMemoryStore();
  let now = Date.UTC(2026, 10, 6, 20, 30);
  const env = { BACKUP_ENCRYPTION_KEY: KEY_B64, BACKUP_FULL_HOUR_UTC: '21' };
  const handle = bj.startBackupJobs({ repo: { soda }, lease, env, store, logger: quiet, clock: () => now });
  assert.equal(handle.enabled, true);
  assert.deepEqual([...jobs.keys()].sort(), ['backup-critical', 'backup-full']);
  assert.equal(jobs.get('backup-critical').intervalMs, 3600000);
  assert.equal(jobs.get('backup-full').intervalMs, 3600000);

  await jobs.get('backup-critical').fn();
  assert.ok(store.objects.has('coroute/2026/11/06/20-critical.json.gz.enc'));
  await jobs.get('backup-full').fn(); // 20:30 UTC: before the full-backup hour
  assert.ok(![...store.objects.keys()].some((k) => k.endsWith('-full.json.gz.enc')));
  now = Date.UTC(2026, 10, 6, 21, 10);
  await jobs.get('backup-full').fn();
  assert.ok(store.objects.has('coroute/2026/11/06/21-full.json.gz.enc'));
  now = Date.UTC(2026, 10, 6, 22, 10);
  await jobs.get('backup-full').fn(); // same day: not again
  assert.ok(!store.objects.has('coroute/2026/11/06/22-full.json.gz.enc'));
  now = Date.UTC(2026, 10, 7, 23, 10); // next day, the gateway was down at 21:00: catches up
  await jobs.get('backup-full').fn();
  assert.ok(store.objects.has('coroute/2026/11/07/23-full.json.gz.enc'));
  // A failing run is logged, never thrown into the lease runner.
  const broken = createMemoryStore();
  broken.put = async () => { throw new Error('bucket down'); };
  const warns = [];
  const h2 = bj.startBackupJobs({ soda, runner: (name, ms, fn) => { jobs.set(`x-${name}`, { fn }); return () => {}; }, env, store: broken, logger: { ...quiet, warn: (m) => warns.push(m) }, clock: () => now });
  await jobs.get('x-backup-critical').fn();
  assert.ok(warns.some((w) => /bucket down/.test(w)));
  h2.stop();
  handle.stop();
  assert.ok(jobs.get('backup-critical').stopped && jobs.get('backup-full').stopped);
});

test('the default runner (no lease) uses unref\'d intervals and stops cleanly', () => {
  const soda = new MemorySoda();
  const h = bj.startBackupJobs({ soda, env: { BACKUP_ENCRYPTION_KEY: KEY_B64 }, store: createMemoryStore(), logger: quiet });
  assert.equal(h.enabled, true);
  h.stop();
});

test('SodaClient.scan pages through every document by key, with or without fromID support', async () => {
  const { SodaClient } = require('../src/oracle/soda');
  for (const honoursFromId of [true, false]) {
    const docs = Array.from({ length: 23 }, (_, i) => ({ id: `K${String(i).padStart(3, '0')}`, value: { n: i } }));
    const calls = [];
    const fetchImpl = async (url) => {
      const u = new URL(url);
      calls.push(u.search);
      const limit = Number(u.searchParams.get('limit'));
      let from = Number(u.searchParams.get('offset')) || 0;
      if (honoursFromId && u.searchParams.get('fromID')) from = docs.findIndex((d) => d.id === u.searchParams.get('fromID'));
      const items = docs.slice(from, from + limit);
      // A document is deleted while the scan runs (offset paging alone would skip one).
      if (calls.length === 2) docs.splice(1, 1);
      return new Response(JSON.stringify({ items, hasMore: from + limit < docs.length }), { status: 200 });
    };
    const soda = new SodaClient({ baseUrl: 'https://db.example.com/ords/x/soda/latest', user: 'u', password: 'p', fetchImpl });
    const got = [];
    for await (const page of soda.scan('users', { pageSize: 5 })) got.push(...page.map((r) => r.key));
    assert.equal(new Set(got).size, got.length, 'no duplicates');
    if (honoursFromId) {
      assert.equal(got.length, 23, 'every document seen exactly once (the deleted one was read before)');
      assert.ok(calls.slice(1).every((c) => c.includes('fromID=')));
    } else {
      assert.ok(got.length >= 21, `offset fallback: ${got.length}`);
      assert.ok(calls.some((c) => c.includes('offset=')));
    }
  }
});

test('SodaClient.insertMany posts one array with action=insert and returns the keys', async () => {
  const { SodaClient } = require('../src/oracle/soda');
  let seen;
  const fetchImpl = async (url, init) => {
    seen = { url, body: JSON.parse(init.body), method: init.method };
    return new Response(JSON.stringify({ items: seen.body.map((_, i) => ({ id: `id${i}` })) }), { status: 200 });
  };
  const soda = new SodaClient({ baseUrl: 'https://db.example.com/ords/x/soda/latest', user: 'u', password: 'p', fetchImpl });
  assert.deepEqual(await soda.insertMany('track_chunks', [{ a: 1 }, { a: 2 }]), ['id0', 'id1']);
  assert.equal(seen.method, 'POST');
  assert.ok(seen.url.endsWith('/track_chunks?action=insert'));
  assert.deepEqual(seen.body, [{ a: 1 }, { a: 2 }]);
  assert.deepEqual(await soda.insertMany('x', []), []);
});
