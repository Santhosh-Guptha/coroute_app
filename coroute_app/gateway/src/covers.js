'use strict';
/**
 * v3.58 profile cover photo (the wide picture behind the avatar on the app's Profile).
 *
 * The same pipeline as profile pictures (src/avatars.js, round 6 "Adjust picture"):
 *  - raw JPEG / PNG / WebP bytes recognised by magic bytes, at most 2 MB and 2048 px per side; the review photo
 *    cleaner strips EXIF / XMP / IPTC (no GPS or device data is stored, even from another client);
 *  - the rider's ORIGINAL is kept private (owner only, GET /me/cover/original; id `cvo_` + 24 hex) so the framing
 *    can be changed later; the PUBLIC cover (`cv_` + 24 hex) is the cropped, wide picture the app shows;
 *  - stored in Object Storage (`covers/<id>.<ext>`, `covers/original/<id>.<ext>`) when REVIEW_PHOTO_STORE=par,
 *    else in the database (`covers` collection, base64), so both VMs serve the same picture;
 *  - a new upload gets a new id (caches never show an old cover); replaced pictures are removed;
 *  - served only to signed-in riders, never to a rider the owner blocked (social_routes.js);
 *  - account erase removes every stored cover and original; an admin can remove a cover (moderation).
 *
 * Routes (social_routes.js): POST /me/cover/original, POST /me/cover[?original=&cx=&cy=&zoom=&rot=],
 * GET /me/cover/original, DELETE /me/cover, GET /covers/:coverId, DELETE /admin/users/:userId/cover.
 */
const crypto = require('crypto');
const A = require('./avatars');

const COLL = 'covers';
const MAX_BYTES = A.MAX_BYTES;
const MAX_SIDE = A.MAX_SIDE;
const COVER_RE = /^cv_[a-f0-9]{24}$/;
const ORIGINAL_RE = /^cvo_[a-f0-9]{24}$/;
const PAR_PREFIX = 'covers/';
const ORIGINAL_PAR_PREFIX = 'covers/original/';

const isCoverId = (v) => typeof v === 'string' && COVER_RE.test(v);
const isOriginalId = (v) => typeof v === 'string' && ORIGINAL_RE.test(v);
const parNameOf = (id, ext) => `${isOriginalId(id) ? ORIGINAL_PAR_PREFIX : PAR_PREFIX}${id}.${ext}`;
const coverUrlOf = (coverId) => (isCoverId(coverId) ? `/api/covers/${coverId}` : null);

let migrated = new WeakSet();
async function ensureStore(soda) {
  if (migrated.has(soda)) return;
  await soda.ensureCollection(COLL);
  await soda.ensureIndex(COLL, { name: 'covers_id_ux', unique: true, fields: [{ path: 'coverId' }] });
  await soda.ensureIndex(COLL, { name: 'covers_user_ix', unique: false, fields: [{ path: 'userId' }] });
  migrated.add(soda);
}

function objectStoreFrom(objectStore) {
  if (objectStore !== undefined) return objectStore;
  let cfg = {};
  try { cfg = require('./config'); } catch { /* scripts */ }
  if (String(cfg.reviewPhotoStore || '').toLowerCase() !== 'par' || !cfg.reviewPhotoParUrl) return null;
  return require('./object_store').createParStore(cfg.reviewPhotoParUrl);
}

async function putDoc(soda, os, doc, p) {
  if (os) await os.put(parNameOf(doc.coverId, p.ext), p.data, p.mime);
  else doc.data = p.data.toString('base64');
  await soda.insert(COLL, doc);
}

async function deleteDoc(soda, coverId, { objectStore } = {}) {
  await ensureStore(soda);
  const r = await soda.findOne(COLL, { coverId });
  if (!r) return false;
  if (r.value.store === 'par') {
    const os = objectStoreFrom(objectStore);
    if (os) await os.del(parNameOf(coverId, r.value.ext)).catch(() => {});
  }
  await soda.remove(COLL, r.key);
  return true;
}

async function readData(soda, v, objectStore) {
  if (v.store === 'par') {
    const os = objectStoreFrom(objectStore);
    return os ? os.get(parNameOf(v.coverId, v.ext)).catch(() => null) : null;
  }
  return typeof v.data === 'string' ? Buffer.from(v.data, 'base64') : null;
}

/** Step 1 of a new cover: the private original, kept as pending until a cover cropped from it is saved. */
async function saveOriginal(repo, user, buf, { objectStore, now = Date.now() } = {}) {
  const p = A.prepareAvatar(buf, { maxBytes: MAX_BYTES, maxSide: MAX_SIDE });
  if (!p.width || !p.height) throw new A.AvatarError(415, 'This picture could not be read. Try another one.', 'UNSUPPORTED_PHOTO');
  await ensureStore(repo.soda);
  const os = objectStoreFrom(objectStore);
  for (const r of await repo.soda.query(COLL, { userId: user.userId, kind: 'original', pending: true }, { limit: 20 })) {
    await deleteDoc(repo.soda, r.value.coverId, { objectStore }).catch(() => {});
  }
  const coverId = `cvo_${crypto.randomBytes(12).toString('hex')}`;
  const doc = { coverId, kind: 'original', pending: true, userId: user.userId, mime: p.mime, ext: p.ext, bytes: p.data.length, width: p.width, height: p.height, at: now, store: os ? 'par' : 'db' };
  await putDoc(repo.soda, os, doc, p);
  return { originalId: coverId, width: p.width, height: p.height };
}

/**
 * The public (cropped, wide) cover. With `originalId` it must be this rider's own original (it becomes the kept
 * one); without it the stored original no longer matches and is removed. `crop` (cx, cy, zoom, rot as for the
 * avatar) is optional and only kept with an original.
 */
async function saveCover(repo, user, buf, { objectStore, now = Date.now(), originalId = null, crop = null } = {}) {
  const p = A.prepareAvatar(buf, { maxBytes: MAX_BYTES, maxSide: MAX_SIDE });
  await ensureStore(repo.soda);
  const os = objectStoreFrom(objectStore);
  const fresh = await repo.findUserById(user.userId);
  let keep = null;
  let c = null;
  if (originalId) {
    if (!isOriginalId(originalId)) throw new A.AvatarError(409, 'Choose the picture again.', 'NO_ORIGINAL');
    const o = await repo.soda.findOne(COLL, { coverId: originalId });
    if (!o || o.value.userId !== user.userId || o.value.kind !== 'original') throw new A.AvatarError(409, 'Choose the picture again.', 'NO_ORIGINAL');
    keep = originalId;
    if (crop) c = A.normaliseCrop(crop);
    if (o.value.pending) await repo.soda.replace(COLL, o.key, { ...o.value, pending: false }).catch(() => {});
  }
  const coverId = `cv_${crypto.randomBytes(12).toString('hex')}`;
  const doc = { coverId, kind: 'cover', userId: user.userId, mime: p.mime, ext: p.ext, bytes: p.data.length, width: p.width || null, height: p.height || null, at: now, store: os ? 'par' : 'db' };
  await putDoc(repo.soda, os, doc, p);
  await repo.updateUser(fresh.key, { coverId, coverAt: now, coverOriginalId: keep, coverCrop: keep ? c : null });
  const replaced = [fresh.coverId, fresh.coverOriginalId && fresh.coverOriginalId !== keep ? fresh.coverOriginalId : null].filter((x) => x && x !== coverId);
  for (const id of replaced) await deleteDoc(repo.soda, id, { objectStore }).catch(() => {});
  return { coverId, coverUrl: coverUrlOf(coverId), hasOriginal: !!keep, crop: keep ? c : null };
}

/** The rider's own original { mime, data, crop } or null. Owner only (by userId, never by id). */
async function readOriginal(repo, userId, { objectStore } = {}) {
  const u = await repo.findUserById(userId);
  if (!u || !isOriginalId(u.coverOriginalId)) return null;
  await ensureStore(repo.soda);
  const r = await repo.soda.findOne(COLL, { coverId: u.coverOriginalId });
  if (!r || r.value.userId !== userId) return null;
  const data = await readData(repo.soda, r.value, objectStore);
  return data ? { mime: r.value.mime, data, crop: u.coverCrop || null } : null;
}

/** { userId, mime, data } of a public cover, or null (originals are never served here). */
async function readCover(soda, coverId, { objectStore } = {}) {
  if (!isCoverId(coverId)) return null;
  await ensureStore(soda);
  const r = await soda.findOne(COLL, { coverId });
  if (!r || r.value.kind !== 'cover') return null;
  const data = await readData(soda, r.value, objectStore);
  return data ? { userId: r.value.userId, mime: r.value.mime, data } : null;
}

/** Removes the rider's cover and every original (rider or admin). True when there was a cover. */
async function removeCover(repo, userId, { objectStore, by = null, now = Date.now() } = {}) {
  const u = await repo.findUserById(userId);
  if (!u) return false;
  await ensureStore(repo.soda);
  for (const r of await repo.soda.query(COLL, { userId, kind: 'original' }, { limit: 20 })) {
    await deleteDoc(repo.soda, r.value.coverId, { objectStore }).catch(() => {});
  }
  const had = isCoverId(u.coverId);
  if (had) await deleteDoc(repo.soda, u.coverId, { objectStore }).catch(() => {});
  if (had || u.coverOriginalId) {
    await repo.updateUser(u.key, { coverId: null, coverAt: 0, coverOriginalId: null, coverCrop: null, ...(by && had ? { coverRemovedBy: by, coverRemovedAt: now } : {}) });
  }
  return had;
}

/** Account erase: every stored cover of the rider. */
async function forgetCovers(soda, userId, { objectStore } = {}) {
  await ensureStore(soda);
  for (const r of await soda.query(COLL, { userId }, { limit: 100 })) await deleteDoc(soda, r.value.coverId, { objectStore }).catch(() => {});
}

module.exports = {
  COLL, MAX_BYTES, MAX_SIDE, isCoverId, isOriginalId, coverUrlOf, saveOriginal, saveCover, readOriginal, readCover, removeCover, forgetCovers,
  _resetForTests: () => { migrated = new WeakSet(); },
};
