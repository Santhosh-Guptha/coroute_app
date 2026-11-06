'use strict';
/** Review photos in Object Storage (REVIEW_PHOTO_STORE=par) and the disk -> PAR migration. */
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const photos = require('../src/review_photos');
const { startParServer } = require('./_par_server');
const { migrateReviewPhotos } = require('../scripts/migrate_review_photos_to_par');
const { createParStore } = require('../src/object_store');

/** Minimal JPEG with an EXIF segment carrying a camera make and GPS text. */
function jpegWithExif() {
  const seg = (marker, body) => { const h = Buffer.from([0xFF, marker, 0, 0]); h.writeUInt16BE(body.length + 2, 2); return Buffer.concat([h, body]); };
  const exif = Buffer.concat([Buffer.from('Exif\0\0', 'binary'), Buffer.from('MM\0\x2a\0\0\0\x08\0\0Canon GPSLAT 12.97', 'binary')]);
  const sof = Buffer.from([8, 0x01, 0xE0, 0x02, 0x80, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  return Buffer.concat([Buffer.from([0xFF, 0xD8]), seg(0xE1, exif), seg(0xDB, Buffer.alloc(65, 1)), seg(0xC0, sof),
    seg(0xDA, Buffer.from([3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0])), Buffer.alloc(100, 0x55), Buffer.from([0xFF, 0xD9])]);
}

test('PAR store: same API as disk, EXIF stripped before upload, objects under review-photos/', async (t) => {
  const par = await startParServer();
  t.after(() => par.close());
  const store = photos.createPhotoStore('/nonexistent', { store: 'par', parUrl: par.url });
  assert.equal(store.kind, 'par');
  assert.equal(store.fileOf({ id: 'rp_' + 'a'.repeat(24), ext: 'jpg' }), null, 'no file paths');
  const prepared = photos.preparePhoto(jpegWithExif());
  const meta = await store.save(prepared);
  assert.ok(photos.isPhotoId(meta.id));
  assert.equal(meta.mime, 'image/jpeg');
  const name = `review-photos/${meta.id}.jpg`;
  assert.ok(par.objects.has(name));
  assert.equal(par.objects.get(name).type, 'image/jpeg');
  assert.ok(!par.objects.get(name).body.toString('latin1').includes('GPSLAT'), 'metadata never reaches the bucket');
  assert.deepEqual(await store.read(meta), prepared.data);
  assert.equal(await store.read({ id: '../../etc/passwd', ext: 'jpg' }), null);
  assert.equal(await store.read({ id: meta.id, ext: 'exe' }), null);
  await store.remove(meta);
  assert.equal(await store.read(meta), null);
  assert.ok(!par.objects.has(name));
});

test('PAR without DELETE: a removed photo is overwritten (tombstone) and no longer served', async (t) => {
  const par = await startParServer({ allowDelete: false });
  t.after(() => par.close());
  const store = photos.createPhotoStore(null, { store: 'par', parUrl: par.url });
  const meta = await store.save(photos.preparePhoto(jpegWithExif()));
  await store.remove(meta);
  assert.equal(await store.read(meta), null);
  assert.ok(par.objects.get(`review-photos/${meta.id}.jpg`).body.length < 40, 'original bytes overwritten');
});

test('read errors answer "not found" (the route sends a bare 404), never the PAR URL', async (t) => {
  const par = await startParServer();
  t.after(() => par.close());
  const store = photos.createPhotoStore(null, { store: 'par', parUrl: par.url });
  const meta = await store.save(photos.preparePhoto(jpegWithExif()));
  par.state.failNext = 100;
  assert.equal(await store.read(meta), null);
});

test('backend switch: default disk; REVIEW_PHOTO_STORE=par needs REVIEW_PHOTO_PAR_URL; unknown values refused', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rp-'));
  const config = require('../src/config');
  const saved = { store: config.reviewPhotoStore, url: config.reviewPhotoParUrl, envStore: process.env.REVIEW_PHOTO_STORE, envUrl: process.env.REVIEW_PHOTO_PAR_URL };
  const set = (store, url) => {
    config.reviewPhotoStore = store; config.reviewPhotoParUrl = url;
    if (store === undefined) delete process.env.REVIEW_PHOTO_STORE; else process.env.REVIEW_PHOTO_STORE = store;
    if (url === undefined) delete process.env.REVIEW_PHOTO_PAR_URL; else process.env.REVIEW_PHOTO_PAR_URL = url;
  };
  try {
    set(undefined, undefined);
    assert.equal(photos.createPhotoStore(dir).kind, 'disk');
    set('par', undefined);
    assert.throws(() => photos.createPhotoStore(dir), /REVIEW_PHOTO_PAR_URL/);
    set('par', 'https://objectstorage.ap-hyderabad-1.oraclecloud.com/p/x/n/ns/b/bkt/o/');
    assert.equal(photos.createPhotoStore(dir).kind, 'par');
    set('s3', undefined);
    assert.throws(() => photos.createPhotoStore(dir), /disk or par/);
  } finally {
    set(saved.store, saved.url);
    if (saved.envStore === undefined) delete process.env.REVIEW_PHOTO_STORE; else process.env.REVIEW_PHOTO_STORE = saved.envStore;
    if (saved.envUrl === undefined) delete process.env.REVIEW_PHOTO_PAR_URL; else process.env.REVIEW_PHOTO_PAR_URL = saved.envUrl;
  }
});

test('account deletion removes the rider\'s photos from the bucket', async (t) => {
  const par = await startParServer();
  t.after(() => par.close());
  const { MemorySoda } = require('../src/oracle/memory_soda');
  const { Repo } = require('../src/oracle/repo');
  const repo = new Repo(new MemorySoda());
  await repo.migrate();
  repo._photos = photos.createPhotoStore(null, { store: 'par', parUrl: par.url });
  const meta = await repo._photos.save(photos.preparePhoto(jpegWithExif()));
  await repo.createUser({ userId: 'u1', name: 'Asha', email: 'asha@x.test' });
  await repo.soda.insert('feedback', { feedbackId: 'f1', tripId: 't1', userId: 'u1', email: 'asha@x.test', uploads: [meta], createdAt: 1 });
  await repo.deleteUserCascade(await repo.findUserById('u1'));
  assert.equal(par.objects.size, 0);
});

test('migration disk -> PAR: dry run writes nothing, real run copies, rerun is a no-op', async (t) => {
  const par = await startParServer();
  t.after(() => par.close());
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rp-mig-'));
  const disk = photos.createPhotoStore(dir, { store: 'disk' });
  const a = await disk.save(photos.preparePhoto(jpegWithExif()));
  const b = await disk.save(photos.preparePhoto(jpegWithExif()));
  fs.writeFileSync(path.join(dir, 'notes.txt'), 'not a photo');
  const objectStore = createParStore(par.url, { backoffMs: 5 });
  const quiet = { info() {}, warn() {} };

  const dry = await migrateReviewPhotos({ dir, objectStore, dryRun: true, log: quiet });
  assert.deepEqual(dry, { scanned: 2, uploaded: 2, skipped: 0, failed: 0, ignored: 1 });
  assert.equal(par.objects.size, 0);

  const real = await migrateReviewPhotos({ dir, objectStore, log: quiet });
  assert.deepEqual(real, { scanned: 2, uploaded: 2, skipped: 0, failed: 0, ignored: 1 });
  const parPhotos = photos.createPhotoStore(null, { store: 'par', objectStore });
  assert.deepEqual(await parPhotos.read(a), await disk.read(a));
  assert.deepEqual(await parPhotos.read(b), await disk.read(b));
  assert.ok(fs.existsSync(disk.fileOf(a)), 'disk files are left in place');

  const again = await migrateReviewPhotos({ dir, objectStore, verify: true, log: quiet });
  assert.deepEqual(again, { scanned: 2, uploaded: 0, skipped: 2, failed: 0, ignored: 1 });
  // A failing bucket is counted, not fatal.
  par.objects.clear();
  par.state.failNext = 1000;
  const failing = await migrateReviewPhotos({ dir, objectStore: createParStore(par.url, { backoffMs: 1, retries: 1 }), log: quiet });
  assert.equal(failing.failed, 2);
  // A missing folder is nothing to do.
  assert.equal((await migrateReviewPhotos({ dir: path.join(dir, 'nope'), objectStore, log: quiet })).scanned, 0);
});
