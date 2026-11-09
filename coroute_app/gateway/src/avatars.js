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
 */
const crypto = require('crypto');
const reviewPhotos = require('./review_photos');

const COLL = 'avatars';
const MAX_BYTES = 2 * 1024 * 1024;
const MAX_SIDE = 2048;
const AVATAR_RE = /^av_[a-f0-9]{24}$/;
const PAR_PREFIX = 'avatars/';

class AvatarError extends Error {
  constructor(status, message, code) { super(message); this.name = 'AvatarError'; this.status = status; this.code = code; }
}

const isAvatarId = (v) => typeof v === 'string' && AVATAR_RE.test(v);
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
function prepareAvatar(buf) {
  if (Buffer.isBuffer(buf) && buf.length > MAX_BYTES) throw new AvatarError(413, 'This picture is too large (up to 2 MB).', 'PHOTO_TOO_LARGE');
  let p;
  try { p = reviewPhotos.preparePhoto(buf); } catch (e) {
    if (e instanceof reviewPhotos.PhotoError) throw new AvatarError(e.status, e.message, e.code);
    throw e;
  }
  if ((p.width && p.width > MAX_SIDE) || (p.height && p.height > MAX_SIDE)) {
    throw new AvatarError(415, `Please use a smaller picture (up to ${MAX_SIDE} px).`, 'PHOTO_TOO_BIG_SIDE');
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
async function saveAvatar(repo, user, buf, { objectStore, now = Date.now() } = {}) {
  const p = prepareAvatar(buf);
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
  await repo.updateUser(fresh.key, { avatarId, avatarAt: now });
  if (previous && previous !== avatarId) await deleteAvatarDoc(repo.soda, previous, { objectStore: os }).catch(() => {});
  return { avatarId, avatarUrl: avatarUrlOf(avatarId), bytes: doc.bytes, mime: doc.mime };
}

async function deleteAvatarDoc(soda, avatarId, { objectStore } = {}) {
  await ensureAvatarStore(soda);
  const r = await soda.findOne(COLL, { avatarId });
  if (!r) return false;
  if (r.value.store === 'par') {
    const os = objectStore === undefined ? objectStoreFromConfig() : objectStore;
    if (os) await os.del(`${PAR_PREFIX}${avatarId}.${r.value.ext}`).catch(() => {});
  }
  await soda.remove(COLL, r.key);
  return true;
}

/** Removes the rider's picture (rider or admin moderation). True when there was one. */
async function removeAvatar(repo, userId, { objectStore, by = null, now = Date.now() } = {}) {
  const u = await repo.findUserById(userId);
  if (!u || !u.avatarId) return false;
  await deleteAvatarDoc(repo.soda, u.avatarId, { objectStore });
  await repo.updateUser(u.key, { avatarId: null, avatarAt: 0, ...(by ? { avatarRemovedBy: by, avatarRemovedAt: now } : {}) });
  return true;
}

/** { userId, mime, data: Buffer } or null. */
async function readAvatar(soda, avatarId, { objectStore } = {}) {
  if (!isAvatarId(avatarId)) return null;
  await ensureAvatarStore(soda);
  const r = await soda.findOne(COLL, { avatarId });
  if (!r) return null;
  const v = r.value;
  let data = null;
  if (v.store === 'par') {
    const os = objectStore === undefined ? objectStoreFromConfig() : objectStore;
    data = os ? await os.get(`${PAR_PREFIX}${avatarId}.${v.ext}`).catch(() => null) : null;
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
  COLL, MAX_BYTES, MAX_SIDE, AvatarError, isAvatarId, avatarUrlOf, prepareAvatar, saveAvatar, removeAvatar,
  readAvatar, forgetAvatars, ensureAvatarStore,
  _resetForTests: () => { migrated = new WeakSet(); },
};
