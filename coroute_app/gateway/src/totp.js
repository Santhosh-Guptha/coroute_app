'use strict';
/**
 * 3.57 security: 2-step verification for MASTER_ADMIN (required on the web admin) and operators (optional).
 * RFC 6238 TOTP (HMAC-SHA1, 6 digits, 30 s steps, +-1 step for clock drift), RFC 4648 base32 secrets, and
 * single-use recovery codes (stored as SHA-256 hashes only). Works with Google Authenticator, Microsoft
 * Authenticator, 1Password, Aegis ... No dependency.
 *
 * Replay protection: the caller stores the last accepted step (users.mfaLastStep) and passes it back, so a
 * code that was already used (or an older one) is refused.
 */
const crypto = require('crypto');

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function base32Encode(buf) {
  let bits = 0; let value = 0; let out = '';
  for (const byte of buf) {
    value = (value << 8) | byte; bits += 8;
    while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

function base32Decode(s) {
  const clean = String(s || '').toUpperCase().replace(/[\s=-]/g, '');
  let bits = 0; let value = 0; const out = [];
  for (const ch of clean) {
    const i = B32.indexOf(ch);
    if (i < 0) throw new Error('bad base32');
    value = (value << 5) | i; bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 255); bits -= 8; }
  }
  return Buffer.from(out);
}

function newSecret() { return base32Encode(crypto.randomBytes(20)); }

function hotp(secret, counter, digits = 6) {
  const key = base32Decode(secret);
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(counter));
  const h = crypto.createHmac('sha1', key).update(msg).digest();
  const off = h[h.length - 1] & 15;
  const code = ((h[off] & 0x7f) << 24) | (h[off + 1] << 16) | (h[off + 2] << 8) | h[off + 3];
  return String(code % 10 ** digits).padStart(digits, '0');
}

function stepAt(now = Date.now(), period = 30) { return Math.floor(now / 1000 / period); }

/** The code for `now` (tests, enrolment previews). */
function totp(secret, now = Date.now()) { return hotp(secret, stepAt(now)); }

/**
 * Checks a 6-digit code within +-`window` steps. Returns the matched step (to store as the last used one),
 * or -1. A step <= lastStep is refused (replay).
 */
function verifyTotp(secret, code, { now = Date.now(), window = 1, lastStep = -1 } = {}) {
  const c = String(code == null ? '' : code).replace(/\s+/g, '');
  if (!/^\d{6}$/.test(c) || !secret) return -1;
  const cur = stepAt(now);
  let found = -1;
  for (let w = -window; w <= window; w++) {
    const step = cur + w;
    const expect = Buffer.from(hotp(secret, step));
    // Every candidate is compared (constant work), timing safe.
    if (crypto.timingSafeEqual(expect, Buffer.from(c)) && step > lastStep && found < 0) found = step;
  }
  return found;
}

/** otpauth:// URI for authenticator apps (QR code or manual entry). */
function otpauthUri({ secret, account, issuer = 'CoRoute' }) {
  const label = encodeURIComponent(`${issuer}:${account}`);
  return `otpauth://totp/${label}?secret=${secret}&issuer=${encodeURIComponent(issuer)}&algorithm=SHA1&digits=6&period=30`;
}

const hashCode = (code) => crypto.createHash('sha256').update(`coroute-recovery|${String(code).toUpperCase().replace(/[^A-Z0-9]/g, '')}`).digest('hex');

/** Ten recovery codes (XXXXX-XXXXX, 50 bits each): { codes (show once), hashes (store) }. */
function newRecoveryCodes(n = 10) {
  const codes = [];
  for (let i = 0; i < n; i++) {
    const raw = base32Encode(crypto.randomBytes(7)).slice(0, 10);
    codes.push(`${raw.slice(0, 5)}-${raw.slice(5)}`);
  }
  return { codes, hashes: codes.map(hashCode) };
}

/** The index of the matching stored hash, or -1 (the caller removes it: single use). */
function matchRecoveryCode(code, hashes) {
  if (!Array.isArray(hashes) || !code) return -1;
  const h = Buffer.from(hashCode(code));
  let found = -1;
  hashes.forEach((x, i) => { if (typeof x === 'string' && x.length === h.length && crypto.timingSafeEqual(Buffer.from(x), h) && found < 0) found = i; });
  return found;
}

module.exports = { base32Encode, base32Decode, newSecret, hotp, totp, verifyTotp, stepAt, otpauthUri, newRecoveryCodes, matchRecoveryCode };
