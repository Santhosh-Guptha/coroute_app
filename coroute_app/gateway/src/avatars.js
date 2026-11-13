'use strict';
/**
 * 3.55 profile pictures (docs/features_355/usernames_friends_profiles.md).
 *
 *  - Optional. Raw JPEG / PNG / WebP bytes only, recognised by magic bytes (the declared type is
 *    never trusted), at most MAX_BYTES, at most MAX_SIDE px per side (the app downsizes to 512 px
 *    and re-encodes as JPEG before upload, which also drops the camera's metadata).
 *  - Server side the same plain-JavaScript cleaner as review photos (src/review_photos.js
 *    preparePhoto) removes EXIF / XMP / IPTC / text chunks, so no GPS position or device data is
 *    stored even from another client. The gateway has no image library (package.json), so pixels
 *    are not re-encoded on the server.
 *  - Storage: OCI Object Storage (objects `avatars/<id>.<ext>`) when REVIEW_PHOTO_STORE=par, else
 *    the database (`avatars` collection, base64) so both gateway VMs serve the same picture.
 *  - Ids are random (`av_` + 24 hex); a new upload gets a new id (the URL changes, caches never
 *    show an old picture). Served only to signed-in riders through a checked route (never to a
 *    rider the owner blocked).
 *
 * 3.56 "Adjust picture" (docs/features_355/profile_photo_adjust.md):
 *  - The rider's ORIGINAL picture is kept next to the cropped public one, so the crop can be changed
 *    later without picking the picture again. The original is private: only its owner can read it
 *    (GET /me/avatar/original); its id (`avo_` + 24 hex) is never an avatar id, so the public
 *    /avatars/:id route can not serve it. Same cleaner (no EXIF / GPS), at most ORIGINAL_MAX_BYTES (2 MB) and
 *    MAX_SIDE px per side (the clients downscale to 2048 px before upload).
 *  - Flow: POST /me/avatar/original (kept as "pending") -> POST /me/avatar/crop with the cropped
 *    512 px picture + crop numbers + the pending original's id (promotes it, the old one is removed).
 *    Re-adjust: POST /me/avatar/crop without an original id keeps the stored original.
 *  - A plain POST /me/avatar (older apps) is a new picture with no original: the stored original is
 *    removed, because it no longer matches. Removal (rider or admin) removes both.
 */
const crypto = require('crypto');
const reviewPhotos = require('./review_photos');

const COLL = 'avatars';
const MAX_BYTES = 2 * 1024 * 1024;
const MAX_SIDE = 2048;
const AVATAR_RE = /^av_[a-f0-9]{24}$/;
const PAR_PREFIX = 'avatars/';
/** 3.56 private originals. */
// Same 2 MB as every stored photo (review_photos.preparePhoto); a 2048 px JPEG fits comfortably.
const ORIGINAL_MAX_BYTES = MAX_BYTES;
const ORIGINAL_RE = /^avo_[a-f0-9]{24}$/;
const ORIGINAL_PAR_PREFIX = 'avatars/original/';
/** The cropped public picture is square-ish and small (the clients write 512 px). */
const CROPPED_MAX_SIDE = 1024;
const MAX_ZOOM = 8;

class AvatarError extends Error {
  constructor(status, message, code) { super(message); this.name = 'AvatarError'; this.status = status; this.code = code; }
}

const isAvatarId = (v) => typeof v === 'string' && AVATAR_RE.test(v);
const isOriginalId = (v) => typeof v === 'string' && ORIGINAL_RE.test(v);
const parNameOf = (id, ext) => `${isOriginalId(id) ? ORIGINAL_PAR_PREFIX : PAR_PREFIX}${id}.${ext}`;

/**
 * Crop numbers shared by the app and the website (lib/domain/media/avatar_crop.dart, account.js):
 *   cx, cy  centre of the square, 0..1 of the picture AFTER rotation
 *   zoom    1..8 (1 = the largest square that fits)
 *   rot     quarter turns clockwise, 0..3
 * Returns a clean object or throws AvatarError 400.
 */
function normaliseCrop(raw) {
  const bad = () => new AvatarError(400, 'The crop of this picture is not valid.', 'BAD_CROP');
  let c = raw;
  if (typeof c === 'string') { try { c = JSON.parse(c); } catch { throw bad(); } }
  if (!c || typeof c !== 'object' || Array.isArray(c)) throw bad();
  const num = (v, lo, hi) => { const n = Number(v); if (typeof v === 'boolean' || v === null || v === '' || !Number.isFinite(n) || n < lo || n > hi) throw bad(); return n; };
  const r4 = (n) => Math.round(n * 10000) / 10000;
  const rot = num(c.rot, 0, 3);
  if (!Number.isInteger(rot)) throw bad();
  return { cx: r4(num(c.cx, 0, 1)), cy: r4(num(c.cy, 0, 1)), zoom: r4(num(c.zoom, 1, MAX_ZOOM)), rot };
}
const avatarUrlOf = (avatarId) => (isAvatarId(avatarId) ? `/api/avatars/${avatarId}` : null);

let migrated = new WeakSet();
async function ensureAvatarStore(soda) {
  if (migrated.has(soda)) return;
  await soda.ensureCollection(COLL);
  await soda.ensureIndex(COLL, { name: 'avatars_id_ux', unique: true, fields: [{ path: 'avatarId' }] });
  await soda.ensureIndex(COLL, { name: 'avatars_user_ix', unique: false, fields: [{ path: 'userId' }] });
  migrated.add(soda);
}

/** Validates and cleans uploaded bytes. Throws AvatarError (400 / 413 / 415). */
function prepareAvatar(buf, { maxBytes = MAX_BYTES, maxSide = MAX_SIDE } = {}) {
  if (Buffer.isBuffer(buf) && buf.length > maxBytes) throw new AvatarError(413, `This picture is too large (up to ${Math.round(maxBytes / (1024 * 1024))} MB).`, 'PHOTO_TOO_LARGE');
  let p;
  try { p = reviewPhotos.preparePhoto(buf); } catch (e) {
    if (e instanceof reviewPhotos.PhotoError) throw new AvatarError(e.status, e.message, e.code);
    throw e;
  }
  if ((p.width && p.width > maxSide) || (p.height && p.height > maxSide)) {
    throw new AvatarError(415, `Please use a smaller picture (up to ${maxSide} px).`, 'PHOTO_TOO_BIG_SIDE');
  }
  return p;
}

/** The object store for pictures when Object Storage is configured, else null (database). */
function objectStoreFromConfig() {
  let cfg = {};
  try { cfg = require('./config'); } catch { /* scripts */ }
  if (String(cfg.reviewPhotoStore || '').toLowerCase() !== 'par' || !cfg.reviewPhotoParUrl) return null;
  return require('./object_store').createParStore(cfg.reviewPhotoParUrl);
}

/**
 * Stores a new picture for `user` and points the user doc at it; the previous one is removed.
 * opts.objectStore: explicit store (tests) | null for the database | undefined = from config.
 */
async function saveAvatar(repo, user, buf, { objectStore, now = Date.now(), crop = null, originalId = undefined, maxSide = MAX_SIDE } = {}) {
  const p = prepareAvatar(buf, { maxSide });
  await ensureAvatarStore(repo.soda);
  const os = objectStore === undefined ? objectStoreFromConfig() : objectStore;
  const avatarId = `av_${crypto.randomBytes(12).toString('hex')}`;
  const doc = {
    avatarId, userId: user.userId, mime: p.mime, ext: p.ext, bytes: p.data.length,
    width: p.width || null, height: p.height || null, at: now, store: os ? 'par' : 'db',
  };
  if (os) await os.put(`${PAR_PREFIX}${avatarId}.${p.ext}`, p.data, p.mime);
  else doc.data = p.data.toString('base64');
  await repo.soda.insert(COLL, doc);
  const fresh = user.key ? user : await repo.findUserById(user.userId);
  const previous = fresh?.avatarId;
  // 3.56: `originalId` undefined = a plain new picture (the stored original no longer matches and
  // is removed); a string = the original this crop was made from (kept).
  const previousOriginal = fresh?.avatarOriginalId || null;
  const keepOriginal = isOriginalId(originalId) ? originalId : null;
  await repo.updateUser(fresh.key, { avatarId, avatarAt: now, avatarOriginalId: keepOriginal, avatarCrop: keepOriginal ? crop : null });
  // Round 8: removing the replaced pictures (Object Storage / database) is background work (photo.delete job).
  const replaced = [previous && previous !== avatarId ? previous : null, previousOriginal && previousOriginal !== keepOriginal ? previousOriginal : null].filter(Boolean);
  if (replaced.length) await deleteLater(repo.soda, replaced, objectStore, os);
  return { avatarId, avatarUrl: avatarUrlOf(avatarId), bytes: doc.bytes, mime: doc.mime, hasOriginal: !!keepOriginal, crop: keepOriginal ? crop : null };
}

/**
 * 3.56 step 1 of "new picture": stores the private original as PENDING (the user doc does not point
 * at it until a crop of it is saved). One pending original per rider: older pending ones are removed.
 */
async function saveOriginal(repo, user, buf, { objectStore, now = Date.now() } = {}) {
  const p = prepareAvatar(buf, { maxBytes: ORIGINAL_MAX_BYTES, maxSide: MAX_SIDE });
  if (!p.width || !p.height) throw new AvatarError(415, 'This picture could not be read. Try another one.', 'UNSUPPORTED_PHOTO');
  await ensureAvatarStore(repo.soda);
  const os = objectStore === undefined ? objectStoreFromConfig() : objectStore;
  const stale = await repo.soda.query(COLL, { userId: user.userId, kind: 'original', pending: true }, { limit: 20 });
  if (stale.length) await deleteLater(repo.soda, stale.map((r) => r.value.avatarId), objectStore, os);
  const originalId = `avo_${crypto.randomBytes(12).toString('hex')}`;
  const doc = {
    avatarId: originalId, kind: 'original', pending: true, userId: user.userId, mime: p.mime, ext: p.ext,
    bytes: p.data.length, width: p.width, height: p.height, at: now, store: os ? 'par' : 'db',
  };
  if (os) await os.put(parNameOf(originalId, p.ext), p.data, p.mime);
  else doc.data = p.data.toString('base64');
  await repo.soda.insert(COLL, doc);
  return { originalId, width: p.width, height: p.height, bytes: doc.bytes, mime: doc.mime };
}

/**
 * 3.56 step 2 / re-adjust: the cropped public picture + its crop numbers.
 *   originalId given  -> must be this rider's (pending or current) original; it becomes the current one.
 *   originalId absent -> the rider must already have an original (re-adjust).
 * Throws AvatarError 409 NO_ORIGINAL when there is nothing to crop from.
 */
async function saveCrop(repo, user, buf, { crop, originalId = null, objectStore, now = Date.now() } = {}) {
  const c = normaliseCrop(crop);
  await ensureAvatarStore(repo.soda);
  const fresh = await repo.findUserById(user.userId);
  const wanted = originalId || fresh?.avatarOriginalId || null;
  if (!isOriginalId(wanted)) throw new AvatarError(409, 'Choose the picture again to adjust it.', 'NO_ORIGINAL');
  const o = await repo.soda.findOne(COLL, { avatarId: wanted });
  // Another rider's original is "not there" (no hint that the id exists).
  if (!o || o.value.userId !== user.userId || o.value.kind !== 'original') throw new AvatarError(409, 'Choose the picture again to adjust it.', 'NO_ORIGINAL');
  const out = await saveAvatar(repo, fresh, buf, { objectStore, now, crop: c, originalId: wanted, maxSide: CROPPED_MAX_SIDE });
  if (o.value.pending) await repo.soda.replace(COLL, o.key, { ...o.value, pending: false }).catch(() => {});
  return out;
}

/** The rider's own original: { mime, data, width, height, crop } or null. Owner only (by userId). */
async function readOriginal(repo, userId, { objectStore } = {}) {
  const u = await repo.findUserById(userId);
  if (!u || !isOriginalId(u.avatarOriginalId)) return null;
  await ensureAvatarStore(repo.soda);
  const r = await repo.soda.findOne(COLL, { avatarId: u.avatarOriginalId });
  if (!r || r.value.userId !== userId) return null;
  const v = r.value;
  let data = null;
  if (v.store === 'par') {
    const os = objectStore === undefined ? objectStoreFromConfig() : objectStore;
    data = os ? await os.get(parNameOf(v.avatarId, v.ext)).catch(() => null) : null;
  } else if (typeof v.data === 'string') data = Buffer.from(v.data, 'base64');
  return data ? { mime: v.mime, data, width: v.width || null, height: v.height || null, crop: u.avatarCrop || null } : null;
}

async function deleteAvatarDoc(soda, avatarId, { objectStore } = {}) {
  await ensureAvatarStore(soda);
  const r = await soda.findOne(COLL, { avatarId });
  if (!r) return false;
  if (r.value.store === 'par') {
    const os = objectStore === undefined ? objectStoreFromConfig() : objectStore;
    if (os) await os.del(parNameOf(avatarId, r.value.ext)).catch(() => {});
  }
  await soda.remove(COLL, r.key);
  return true;
}

/**
 * Round 8 (src/jobs/producers.js): pictures that were replaced are removed by a photo.delete job when the job queue is
 * on. The EXIF / GPS clean-up of an upload stays on the request on purpose: raw bytes with a GPS position are never
 * stored anywhere, not even in a queue. An explicit objectStore (tests, scripts) is always handled inline.
 */
const photoJobs = new WeakMap();
function attachPhotoJobs(soda, jobs) { if (soda && jobs) photoJobs.set(soda, jobs); }
async function deleteLater(soda, ids, objectStore, resolvedStore) {
  const jobs = photoJobs.get(soda);
  if (jobs && jobs.enabled && objectStore === undefined && !require('./jobs/context').inJob()) {
    try { await jobs.enqueue('photo.delete', { avatarIds: ids.slice(0, 20) }, { priority: 6 }); return; } catch { /* inline below */ }
  }
  for (const id of ids) await deleteAvatarDoc(soda, id, { objectStore: resolvedStore }).catch(() => {});
}

/** Removes the rider's picture (rider or admin moderation). True when there was one. */
async function removeAvatar(repo, userId, { objectStore, by = null, now = Date.now() } = {}) {
  const u = await repo.findUserById(userId);
  if (!u) return false;
  // 3.56: the private original (current and any pending upload) goes with the picture.
  await ensureAvatarStore(repo.soda);
  const originals = await repo.soda.query(COLL, { userId, kind: 'original' }, { limit: 20 });
  for (const r of originals) await deleteAvatarDoc(repo.soda, r.value.avatarId, { objectStore }).catch(() => {});
  if (!u.avatarId) {
    if (u.avatarOriginalId) await repo.updateUser(u.key, { avatarOriginalId: null, avatarCrop: null });
    return false;
  }
  await deleteAvatarDoc(repo.soda, u.avatarId, { objectStore });
  await repo.updateUser(u.key, { avatarId: null, avatarAt: 0, avatarOriginalId: null, avatarCrop: null, ...(by ? { avatarRemovedBy: by, avatarRemovedAt: now } : {}) });
  return true;
}

/** { userId, mime, data: Buffer } or null. */
async function readAvatar(soda, avatarId, { objectStore } = {}) {
  if (!isAvatarId(avatarId)) return null;
  await ensureAvatarStore(soda);
  const r = await soda.findOne(COLL, { avatarId });
  if (!r || r.value.kind === 'original') return null;
  const v = r.value;
  let data = null;
  if (v.store === 'par') {
    const os = objectStore === undefined ? objectStoreFromConfig() : objectStore;
    data = os ? await os.get(parNameOf(avatarId, v.ext)).catch(() => null) : null;
  } else if (typeof v.data === 'string') {
    data = Buffer.from(v.data, 'base64');
  }
  return data ? { userId: v.userId, mime: v.mime, data } : null;
}

/** Account erase: every stored picture of the rider. */
async function forgetAvatars(soda, userId, { objectStore } = {}) {
  await ensureAvatarStore(soda);
  const rows = await soda.query(COLL, { userId }, { limit: 100 });
  for (const r of rows) await deleteAvatarDoc(soda, r.value.avatarId, { objectStore }).catch(() => {});
}

module.exports = {
  COLL, MAX_BYTES, MAX_SIDE, ORIGINAL_MAX_BYTES, CROPPED_MAX_SIDE, MAX_ZOOM, AvatarError, isAvatarId, isOriginalId, avatarUrlOf,
  prepareAvatar, normaliseCrop, saveAvatar, saveOriginal, saveCrop, readOriginal, removeAvatar,
  readAvatar, forgetAvatars, ensureAvatarStore, deleteAvatarDoc, attachPhotoJobs,
  _resetForTests: () => { migrated = new WeakSet(); },
};
