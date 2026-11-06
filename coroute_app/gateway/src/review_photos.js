'use strict';
/**
 * Photos riders attach to a post-trip review ("our group's memorable moment").
 *
 *  - Accepted only as raw JPEG, PNG or WebP bytes, recognised by their magic bytes (the declared
 *    Content-Type is never trusted), at most MAX_BYTES each and MAX_PER_REVIEW per review.
 *  - Metadata that can identify a place or a device is removed in plain JavaScript before the file
 *    is written: JPEG APP1 (EXIF, XMP, with GPS) and APP13 (IPTC) segments and comments are dropped,
 *    and only the EXIF orientation is written back (so photos are not shown sideways); PNG text and
 *    eXIf chunks; WebP EXIF and XMP chunks. Pixels are not re-encoded (no native image library).
 *  - Files get random names and live in a data folder outside public/ (config.reviewPhotoDir).
 *    Nothing in that folder is served as a static file: routes check who may see each photo.
 *  - Storage backend (REVIEW_PHOTO_STORE): `disk` (default, REVIEW_PHOTO_DIR) or `par` (OCI Object
 *    Storage through the bucket Pre-Authenticated Request REVIEW_PHOTO_PAR_URL, objects named
 *    `review-photos/<id>.<ext>`). Both have the same API (save / read / remove). With `par` the
 *    photos are still served only through the gateway's checked routes: the PAR URL is a secret and
 *    never reaches a client. scripts/migrate_review_photos_to_par.js copies existing disk files.
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const MAX_BYTES = 2 * 1024 * 1024;
const MAX_PER_REVIEW = 3;
const MAX_SIDE = 10000; // larger than any phone photo after the app's 1600 px downscale
const PHOTO_ID = /^rp_[a-f0-9]{24}$/;
const TYPES = Object.freeze({
  jpeg: { mime: 'image/jpeg', ext: 'jpg' },
  png: { mime: 'image/png', ext: 'png' },
  webp: { mime: 'image/webp', ext: 'webp' },
});

class PhotoError extends Error {
  constructor(status, message, code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const isPhotoId = (v) => typeof v === 'string' && PHOTO_ID.test(v);
const newPhotoId = () => `rp_${crypto.randomBytes(12).toString('hex')}`;

/** 'jpeg' | 'png' | 'webp' | null, from the first bytes only. */
function sniff(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 12) return null;
  if (buf[0] === 0xFF && buf[1] === 0xD8 && buf[2] === 0xFF) return 'jpeg';
  if (buf.slice(0, 8).equals(Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))) return 'png';
  if (buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') return 'webp';
  return null;
}

/** EXIF orientation (1-8) from an APP1 payload, or 1. */
function exifOrientation(seg) {
  try {
    if (seg.toString('ascii', 0, 4) !== 'Exif') return 1;
    const t = 6; // TIFF header start
    const le = seg.toString('ascii', t, t + 2) === 'II';
    const u16 = (o) => (le ? seg.readUInt16LE(o) : seg.readUInt16BE(o));
    const u32 = (o) => (le ? seg.readUInt32LE(o) : seg.readUInt32BE(o));
    const ifd = t + u32(t + 4);
    const n = u16(ifd);
    for (let i = 0; i < n; i++) {
      const e = ifd + 2 + i * 12;
      if (u16(e) === 0x0112) {
        const v = u16(e + 8);
        return v >= 1 && v <= 8 ? v : 1;
      }
    }
  } catch { /* malformed EXIF: treat as upright */ }
  return 1;
}

/** A minimal APP1 segment holding only the orientation tag (no GPS, no camera, no dates). */
function orientationApp1(o) {
  const tiff = Buffer.alloc(26);
  tiff.write('MM', 0, 'ascii');
  tiff.writeUInt16BE(42, 2);
  tiff.writeUInt32BE(8, 4); // IFD0 right after the header
  tiff.writeUInt16BE(1, 8); // one entry
  tiff.writeUInt16BE(0x0112, 10); // Orientation
  tiff.writeUInt16BE(3, 12); // SHORT
  tiff.writeUInt32BE(1, 14); // count
  tiff.writeUInt16BE(o, 18); // value (left-justified in the 4-byte field)
  tiff.writeUInt32BE(0, 22); // no next IFD
  const payload = Buffer.concat([Buffer.from('Exif\0\0', 'binary'), tiff]);
  const head = Buffer.from([0xFF, 0xE1, 0, 0]);
  head.writeUInt16BE(payload.length + 2, 2);
  return Buffer.concat([head, payload]);
}

/** JPEG without APP1/APP13/COM segments; size from the first SOF marker. */
function cleanJpeg(buf) {
  const out = [buf.slice(0, 2)];
  let i = 2;
  let orientation = 1;
  let width = 0;
  let height = 0;
  let wroteOrientation = false;
  while (i + 4 <= buf.length) {
    if (buf[i] !== 0xFF) throw new PhotoError(415, 'This photo file is damaged.', 'BAD_PHOTO');
    const marker = buf[i + 1];
    if (marker === 0xFF) { i++; continue; } // fill byte
    if (marker === 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker === 0x01) { out.push(buf.slice(i, i + 2)); i += 2; continue; }
    if (marker === 0xD9) { out.push(buf.slice(i, i + 2)); i += 2; break; }
    const len = buf.readUInt16BE(i + 2);
    if (len < 2 || i + 2 + len > buf.length) throw new PhotoError(415, 'This photo file is damaged.', 'BAD_PHOTO');
    const seg = buf.slice(i, i + 2 + len);
    const body = buf.slice(i + 4, i + 2 + len);
    if (marker === 0xE1) {
      const o = exifOrientation(body);
      if (o !== 1) orientation = o;
    } else if (marker === 0xED || marker === 0xFE) {
      // IPTC / Photoshop resources and comments: dropped.
    } else {
      if (marker === 0xDA || ((marker >= 0xC0 && marker <= 0xCF) && marker !== 0xC4 && marker !== 0xC8 && marker !== 0xCC)) {
        if (marker !== 0xDA && !width && body.length >= 5) { height = body.readUInt16BE(1); width = body.readUInt16BE(3); }
      }
      if (!wroteOrientation && marker !== 0xE0 && orientation !== 1) { out.push(orientationApp1(orientation)); wroteOrientation = true; }
      out.push(seg);
      if (marker === 0xDA) {
        // Start of scan: the compressed image data follows to the end of the file.
        out.push(buf.slice(i + 2 + len));
        i = buf.length;
        break;
      }
    }
    i += 2 + len;
  }
  return { data: Buffer.concat(out), width, height };
}

const PNG_DROP = new Set(['tEXt', 'zTXt', 'iTXt', 'eXIf', 'tIME']);
function cleanPng(buf) {
  const out = [buf.slice(0, 8)];
  let i = 8;
  let width = 0;
  let height = 0;
  while (i + 12 <= buf.length) {
    const len = buf.readUInt32BE(i);
    const type = buf.toString('ascii', i + 4, i + 8);
    const end = i + 12 + len;
    if (end > buf.length) throw new PhotoError(415, 'This photo file is damaged.', 'BAD_PHOTO');
    if (type === 'IHDR' && len >= 8) { width = buf.readUInt32BE(i + 8); height = buf.readUInt32BE(i + 12); }
    if (!PNG_DROP.has(type)) out.push(buf.slice(i, end));
    i = end;
    if (type === 'IEND') break;
  }
  return { data: Buffer.concat(out), width, height };
}

function cleanWebp(buf) {
  const total = Math.min(buf.length, buf.readUInt32LE(4) + 8);
  const chunks = [];
  let i = 12;
  let width = 0;
  let height = 0;
  while (i + 8 <= total) {
    const fourcc = buf.toString('ascii', i, i + 4);
    const len = buf.readUInt32LE(i + 4);
    const end = i + 8 + len + (len % 2);
    if (i + 8 + len > total) throw new PhotoError(415, 'This photo file is damaged.', 'BAD_PHOTO');
    let chunk = buf.slice(i, Math.min(end, total));
    if (fourcc === 'VP8X' && len >= 10) {
      chunk = Buffer.from(chunk);
      chunk[8] &= ~0x0C; // clear the EXIF (0x08) and XMP (0x04) flags
      width = 1 + chunk.readUIntLE(12, 3);
      height = 1 + chunk.readUIntLE(15, 3);
    } else if (fourcc === 'VP8 ' && len >= 10 && !width) {
      width = buf.readUInt16LE(i + 14) & 0x3FFF;
      height = buf.readUInt16LE(i + 16) & 0x3FFF;
    } else if (fourcc === 'VP8L' && len >= 5 && !width) {
      const b = buf.readUInt32LE(i + 9);
      width = (b & 0x3FFF) + 1;
      height = ((b >>> 14) & 0x3FFF) + 1;
    }
    if (fourcc !== 'EXIF' && fourcc !== 'XMP ') chunks.push(chunk);
    i = end;
  }
  const body = Buffer.concat(chunks);
  const head = Buffer.alloc(12);
  head.write('RIFF', 0, 'ascii');
  head.writeUInt32LE(body.length + 4, 4);
  head.write('WEBP', 8, 'ascii');
  return { data: Buffer.concat([head, body]), width, height };
}

/**
 * Checks and cleans one uploaded photo. Resolves to { data, kind, mime, ext, width, height }
 * or throws PhotoError (400 empty, 413 too big, 415 not a JPEG/PNG/WebP or damaged).
 */
function preparePhoto(buf) {
  if (!Buffer.isBuffer(buf) || buf.length === 0) throw new PhotoError(400, 'No photo was received.', 'NO_PHOTO');
  if (buf.length > MAX_BYTES) throw new PhotoError(413, 'This photo is too large. Please pick a smaller one (up to 2 MB).', 'PHOTO_TOO_LARGE');
  const kind = sniff(buf);
  if (!kind) throw new PhotoError(415, 'Please choose a JPEG, PNG or WebP photo.', 'UNSUPPORTED_PHOTO');
  let res;
  try {
    res = kind === 'jpeg' ? cleanJpeg(buf) : kind === 'png' ? cleanPng(buf) : cleanWebp(buf);
  } catch (e) {
    if (e instanceof PhotoError) throw e;
    throw new PhotoError(415, 'This photo file is damaged.', 'BAD_PHOTO');
  }
  if (res.data.length < 12 || (res.width && res.width > MAX_SIDE) || (res.height && res.height > MAX_SIDE)) {
    throw new PhotoError(415, 'This photo could not be used. Please pick another one.', 'BAD_PHOTO');
  }
  return { ...res, kind, ...TYPES[kind] };
}

const PAR_PREFIX = 'review-photos/';

/** Backend settings: explicit options, then config.js, then the environment. */
function photoBackend(opts = {}) {
  let cfg = {};
  try { cfg = require('./config'); } catch { /* scripts without a full configuration */ }
  const store = String(opts.store || cfg.reviewPhotoStore || process.env.REVIEW_PHOTO_STORE || 'disk').trim().toLowerCase();
  const parUrl = String(opts.parUrl || cfg.reviewPhotoParUrl || process.env.REVIEW_PHOTO_PAR_URL || '').trim();
  return { store, parUrl };
}

/**
 * The review photo store. Disk (default) keeps files in [dir]; REVIEW_PHOTO_STORE=par keeps them in
 * Object Storage (REVIEW_PHOTO_PAR_URL). opts: { store?: 'disk'|'par', parUrl?, objectStore? }.
 */
function createPhotoStore(dir, opts = {}) {
  const { store, parUrl } = photoBackend(opts);
  if (store === 'par') return createParPhotoStore(parUrl, opts);
  if (store !== 'disk') throw new Error(`[review_photos] REVIEW_PHOTO_STORE must be disk or par (got ${store})`);
  return createDiskPhotoStore(dir);
}

/** Object name of a photo in the bucket, or null for metadata that is not a stored photo. */
function objectNameOf(meta) {
  if (!meta || !isPhotoId(meta.id) || !Object.values(TYPES).some((t) => t.ext === meta.ext)) return null;
  return `${PAR_PREFIX}${meta.id}.${meta.ext}`;
}

/** Object Storage store (bucket PAR). `objectStore` may be given directly (tests). */
function createParPhotoStore(parUrl, { objectStore } = {}) {
  let os = objectStore;
  if (!os) {
    if (!parUrl) throw new Error('[review_photos] REVIEW_PHOTO_STORE=par needs REVIEW_PHOTO_PAR_URL (a bucket PAR ending in /o/)');
    os = require('./object_store').createParStore(parUrl);
  }
  return {
    kind: 'par',
    dir: null,
    fileOf: () => null,
    objectName: objectNameOf,
    async save(prepared) {
      const id = newPhotoId();
      const meta = { id, mime: prepared.mime, ext: prepared.ext, bytes: prepared.data.length, width: prepared.width || null, height: prepared.height || null, at: Date.now() };
      await os.put(objectNameOf(meta), prepared.data, prepared.mime);
      return meta;
    },
    async read(meta) {
      const name = objectNameOf(meta);
      if (!name) return null;
      return os.get(name).catch(() => null);
    },
    /** Best effort, like the disk store (a PAR without DELETE overwrites the object with a tombstone). */
    async remove(meta) {
      const name = objectNameOf(meta);
      if (name) await os.del(name).catch(() => {});
    },
  };
}

/** Disk store for review photos. [dir] is outside public/ and created on first use. */
function createDiskPhotoStore(dir) {
  const fileOf = (meta) => {
    if (!meta || !isPhotoId(meta.id) || !Object.values(TYPES).some((t) => t.ext === meta.ext)) return null;
    return path.join(dir, `${meta.id}.${meta.ext}`);
  };
  return {
    kind: 'disk',
    dir,
    fileOf,
    async save(prepared) {
      await fs.promises.mkdir(dir, { recursive: true, mode: 0o700 });
      const id = newPhotoId();
      const meta = { id, mime: prepared.mime, ext: prepared.ext, bytes: prepared.data.length, width: prepared.width || null, height: prepared.height || null, at: Date.now() };
      await fs.promises.writeFile(fileOf(meta), prepared.data, { flag: 'wx', mode: 0o600 });
      return meta;
    },
    async read(meta) {
      const f = fileOf(meta);
      if (!f) return null;
      return fs.promises.readFile(f).catch(() => null);
    },
    /** Best effort: a photo the rider removed (or never consented to show) is deleted from disk. */
    async remove(meta) {
      const f = fileOf(meta);
      if (f) await fs.promises.unlink(f).catch(() => {});
    },
  };
}

module.exports = { MAX_BYTES, MAX_PER_REVIEW, TYPES, PAR_PREFIX, PhotoError, isPhotoId, newPhotoId, sniff, preparePhoto, createPhotoStore, createDiskPhotoStore, createParPhotoStore, objectNameOf, cleanJpeg, exifOrientation };
