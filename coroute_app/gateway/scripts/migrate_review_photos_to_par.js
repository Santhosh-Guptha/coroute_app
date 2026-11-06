#!/usr/bin/env node
'use strict';
/**
 * One-off: copies review photos from the disk store (REVIEW_PHOTO_DIR) to Object Storage
 * (REVIEW_PHOTO_PAR_URL, objects `review-photos/<id>.<ext>`).
 *
 *   node scripts/migrate_review_photos_to_par.js [--dry-run] [--verify] [--dir <path>]
 *
 * Idempotent: a photo already in the bucket with the same size is skipped (--verify compares the
 * bytes too). Files on disk are never deleted or changed; after switching REVIEW_PHOTO_STORE=par and
 * checking the photos show in the app, the folder can be archived / removed by hand.
 * Photo metadata in the database ({ id, ext, mime, ... } in feedback.uploads) is the same for both
 * stores, so nothing in the database changes.
 * Exit code 0 = everything copied (or would be, with --dry-run), 1 = some failed.
 */
const fs = require('fs');
const path = require('path');
const { objectNameOf, isPhotoId, TYPES } = require('../src/review_photos');
const { createParStore } = require('../src/object_store');

const FILE = /^(rp_[a-f0-9]{24})\.([a-z]+)$/;

/** @returns {Promise<{scanned:number, uploaded:number, skipped:number, failed:number, ignored:number}>} */
async function migrateReviewPhotos({ dir, objectStore, dryRun = false, verify = false, log = console }) {
  const stats = { scanned: 0, uploaded: 0, skipped: 0, failed: 0, ignored: 0 };
  let names;
  try { names = await fs.promises.readdir(dir); } catch (e) {
    if (e.code === 'ENOENT') { log.info?.(`[migrate] ${dir} does not exist: nothing to copy`); return stats; }
    throw e;
  }
  const mimeOf = Object.fromEntries(Object.values(TYPES).map((t) => [t.ext, t.mime]));
  for (const file of names.sort()) {
    const m = FILE.exec(file);
    if (!m || !isPhotoId(m[1]) || !mimeOf[m[2]]) { stats.ignored++; continue; }
    stats.scanned++;
    const meta = { id: m[1], ext: m[2] };
    const name = objectNameOf(meta);
    try {
      const data = await fs.promises.readFile(path.join(dir, file));
      const remote = await objectStore.get(name);
      if (remote && remote.length === data.length && (!verify || remote.equals(data))) { stats.skipped++; continue; }
      if (dryRun) { log.info?.(`[migrate] would upload ${file} (${data.length} bytes)`); stats.uploaded++; continue; }
      await objectStore.put(name, data, mimeOf[m[2]]);
      const back = await objectStore.get(name);
      if (!back || !back.equals(data)) throw new Error('read-back mismatch');
      stats.uploaded++;
    } catch (e) {
      stats.failed++;
      log.warn?.(`[migrate] ${file}: ${e.message}`);
    }
  }
  return stats;
}

module.exports = { migrateReviewPhotos };

if (require.main === module) {
  const args = process.argv.slice(2);
  const flag = (f) => args.includes(f);
  const opt = (f) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : undefined; };
  (async () => {
    require('dotenv').config();
    const dir = opt('--dir') || (process.env.REVIEW_PHOTO_DIR || '').trim() || path.join(__dirname, '..', 'data', 'review-photos');
    const parUrl = (process.env.REVIEW_PHOTO_PAR_URL || '').trim();
    if (!parUrl) throw new Error('Set REVIEW_PHOTO_PAR_URL (bucket PAR ending in /o/).');
    const stats = await migrateReviewPhotos({ dir, objectStore: createParStore(parUrl), dryRun: flag('--dry-run'), verify: flag('--verify'), log: console });
    console.log(`${flag('--dry-run') ? '[dry run] ' : ''}${JSON.stringify(stats)}`);
    process.exit(stats.failed ? 1 : 0);
  })().catch((e) => { console.error(e.message); process.exit(1); });
}
