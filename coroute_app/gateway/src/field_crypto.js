'use strict';
/**
 * 3.57 security: field-level encryption at rest (AES-256-GCM) and keyed blind indexes (HMAC-SHA256).
 * docs/features_355/sessions_and_security.md, docs/security/SECURITY_AUDIT_v3.55.md.
 *
 * Keys (env, from OCI Vault -> /run/coroute/secrets.env; never in git, same values on both VMs):
 *   DATA_ENC_KEY            32 random bytes, base64 (openssl rand -base64 32). The key new values are written with.
 *   DATA_ENC_KEY_ID         short id of that key (default "k1"); stored with every value so keys can rotate.
 *   DATA_ENC_KEYS_PREVIOUS  "k0:<base64>,k-old:<base64>": older keys, read only. Values written with them are
 *                           re-encrypted with DATA_ENC_KEY the next time the document is read (lazy migration).
 *   BLIND_INDEX_KEY         32 random bytes, base64: keyed hashes (IP hashes in session records, device
 *                           fingerprints, future e-mail lookup). Falls back to a key derived from JWT_SECRET.
 *
 * Stored format: "enc:v1:<kid>:<iv b64url>:<ciphertext+tag b64url>". A value without the prefix is plaintext
 * from before encryption (read as is, encrypted on the next write or by the lazy migration).
 *
 * No DATA_ENC_KEY: values are written in plaintext (exactly as before 3.57) and a production warning is logged.
 * A value whose key id this node does not know is NEVER returned as garbage: decrypt() returns '' and the
 * node reports the missing key id (health + log), so an SOS never texts "enc:v1:..." as a phone number.
 *
 * The collection field map (FIELD_SPEC) says which fields are protected:
 *   users           phone, emergency contact (number and name), medical ID fields, TOTP secrets
 *   convoy_riders   the rider's phone and emergency contact copied into a ride's roster
 *   room_snapshots  the same fields inside riders[] (one live-state document per ride)
 * E-mail stays a plaintext column (it is the sign-in identifier, the unique index and the admin search key);
 * blindIndex() is ready for a later step that encrypts it too.
 */
const crypto = require('crypto');

const PREFIX = 'enc:v1:';
const KID_RE = /^[A-Za-z0-9_-]{1,16}$/;

const USER_FIELDS = Object.freeze(['phone', 'emergencyContact', 'emergencyContactName', 'bloodGroup', 'allergies', 'medicalNotes', 'mfaSecret', 'mfaPendingSecret']);
const ROSTER_FIELDS = Object.freeze(['phone', 'emergencyContact', 'emergencyContactName']);
const FIELD_SPEC = Object.freeze({
  users: { fields: USER_FIELDS, lazy: true },
  convoy_riders: { fields: ROSTER_FIELDS, lazy: true },
  room_snapshots: { arrays: { riders: ROSTER_FIELDS } },
});

function b64url(buf) { return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
function unb64url(s) { return Buffer.from(String(s).replace(/-/g, '+').replace(/_/g, '/'), 'base64'); }

/** 32-byte base64 key, or null when empty. Throws on a malformed key (a typo must not silently disable encryption). */
function parseKey(v, name = 'DATA_ENC_KEY') {
  const s = String(v || '').trim();
  if (!s) return null;
  const buf = Buffer.from(s, 'base64');
  if (buf.length !== 32) throw new Error(`[config] ${name} must be 32 random bytes, base64 encoded (openssl rand -base64 32)`);
  return buf;
}

/** "kid:base64,kid2:base64" -> Map(kid -> key). */
function parseKeyList(v, name = 'DATA_ENC_KEYS_PREVIOUS') {
  const out = new Map();
  for (const part of String(v || '').split(',').map((x) => x.trim()).filter(Boolean)) {
    const i = part.indexOf(':');
    const kid = i > 0 ? part.slice(0, i) : '';
    if (!KID_RE.test(kid)) throw new Error(`[config] ${name}: every entry is <keyId>:<base64 key>`);
    out.set(kid, parseKey(part.slice(i + 1), `${name} (${kid})`));
  }
  return out;
}

class FieldCrypto {
  /**
   * @param {{key?: Buffer|null, keyId?: string, previous?: Map<string, Buffer>, blindKey?: Buffer|null, logger?: object}} o
   */
  constructor({ key = null, keyId = 'k1', previous = new Map(), blindKey = null, logger = console } = {}) {
    if (key && key.length !== 32) throw new Error('FieldCrypto: key must be 32 bytes');
    if (!KID_RE.test(keyId)) throw new Error('FieldCrypto: bad key id');
    this.key = key; this.keyId = keyId; this.logger = logger;
    this.keys = new Map(previous);
    if (key) this.keys.set(keyId, key);
    this.blindKey = blindKey || null;
    /** Key ids met in stored values that this node cannot decrypt (reported by /api/health). */
    this.missingKids = new Set();
    this.stats = { encrypted: 0, decrypted: 0, failed: 0, migrated: 0 };
  }

  get enabled() { return !!this.key; }

  static isEncrypted(v) { return typeof v === 'string' && v.startsWith(PREFIX); }

  /** Encrypts a string (non-strings and '' are returned unchanged; already encrypted values too). */
  encrypt(value, aad = '') {
    if (!this.key || typeof value !== 'string' || value === '' || FieldCrypto.isEncrypted(value)) return value;
    const iv = crypto.randomBytes(12);
    const c = crypto.createCipheriv('aes-256-gcm', this.key, iv);
    if (aad) c.setAAD(Buffer.from(String(aad)));
    const ct = Buffer.concat([c.update(value, 'utf8'), c.final(), c.getAuthTag()]);
    this.stats.encrypted++;
    return `${PREFIX}${this.keyId}:${b64url(iv)}:${b64url(ct)}`;
  }

  /** Decrypts an "enc:v1:" value; plaintext is returned as is; an undecryptable value reads as ''. */
  decrypt(value, aad = '') {
    if (!FieldCrypto.isEncrypted(value)) return value;
    const parts = value.slice(PREFIX.length).split(':');
    if (parts.length !== 3) { this.stats.failed++; return ''; }
    const [kid, ivS, ctS] = parts;
    const key = this.keys.get(kid);
    if (!key) {
      if (!this.missingKids.has(kid)) {
        this.missingKids.add(kid);
        this.logger.error?.(`[crypto] a stored value uses data key id "${kid}" which this node does not have: set DATA_ENC_KEY / DATA_ENC_KEYS_PREVIOUS (same on both VMs)`);
      }
      this.stats.failed++;
      return '';
    }
    try {
      const iv = unb64url(ivS); const buf = unb64url(ctS);
      if (iv.length !== 12 || buf.length < 16) throw new Error('short');
      const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
      if (aad) d.setAAD(Buffer.from(String(aad)));
      d.setAuthTag(buf.subarray(buf.length - 16));
      const out = Buffer.concat([d.update(buf.subarray(0, buf.length - 16)), d.final()]).toString('utf8');
      this.stats.decrypted++;
      return out;
    } catch {
      this.stats.failed++;
      return '';
    }
  }

  /** True when the value should be (re)written: plaintext while a key is set, or an older key id. */
  needsMigration(value) {
    if (!this.key || typeof value !== 'string' || value === '') return false;
    if (!FieldCrypto.isEncrypted(value)) return true;
    const kid = value.slice(PREFIX.length).split(':')[0];
    return kid !== this.keyId && this.keys.has(kid);
  }

  /** Keyed, deterministic hash for lookups without storing the value (purpose separates uses). */
  blindIndex(value, purpose = 'default') {
    const v = String(value == null ? '' : value).trim().toLowerCase();
    if (!v) return '';
    const key = this.blindKey || crypto.createHash('sha256').update('coroute-blind-index-fallback').digest();
    return b64url(crypto.createHmac('sha256', key).update(`${purpose}|${v}`).digest()).slice(0, 32);
  }

  // ---- documents ------------------------------------------------------------------------------
  /** A copy of `doc` with the collection's protected fields encrypted (no-op without a key). */
  encryptDoc(collection, doc) {
    const spec = FIELD_SPEC[collection];
    if (!spec || !this.key || !doc || typeof doc !== 'object') return doc;
    const out = { ...doc };
    for (const f of spec.fields || []) if (typeof out[f] === 'string' && out[f]) out[f] = this.encrypt(out[f]);
    for (const [arr, fields] of Object.entries(spec.arrays || {})) {
      if (!Array.isArray(out[arr])) continue;
      out[arr] = out[arr].map((it) => {
        if (!it || typeof it !== 'object') return it;
        const o = { ...it };
        for (const f of fields) if (typeof o[f] === 'string' && o[f]) o[f] = this.encrypt(o[f]);
        return o;
      });
    }
    return out;
  }

  /** A copy of `doc` with protected fields decrypted. Always runs (a node without a key still reads plaintext). */
  decryptDoc(collection, doc) {
    const spec = FIELD_SPEC[collection];
    if (!spec || !doc || typeof doc !== 'object') return doc;
    let out = doc;
    const copy = () => { if (out === doc) out = { ...doc }; };
    for (const f of spec.fields || []) {
      if (FieldCrypto.isEncrypted(doc[f])) { copy(); out[f] = this.decrypt(doc[f]); }
    }
    for (const [arr, fields] of Object.entries(spec.arrays || {})) {
      if (!Array.isArray(doc[arr])) continue;
      if (!doc[arr].some((it) => it && fields.some((f) => FieldCrypto.isEncrypted(it[f])))) continue;
      copy();
      out[arr] = doc[arr].map((it) => {
        if (!it || typeof it !== 'object' || !fields.some((f) => FieldCrypto.isEncrypted(it[f]))) return it;
        const o = { ...it };
        for (const f of fields) if (FieldCrypto.isEncrypted(o[f])) o[f] = this.decrypt(o[f]);
        return o;
      });
    }
    return out;
  }

  /** True when a raw stored document has a protected field that should be rewritten (lazy migration). */
  docNeedsMigration(collection, raw) {
    const spec = FIELD_SPEC[collection];
    if (!spec || !spec.lazy || !this.key || !raw) return false;
    return (spec.fields || []).some((f) => this.needsMigration(raw[f]));
  }

  /** A raw stored doc rewritten with the current key (decrypt old-key values, encrypt plaintext). */
  migrateDoc(collection, raw) {
    return this.encryptDoc(collection, this.decryptDoc(collection, raw));
  }
}

/**
 * Wraps a SODA client so the protected fields are encrypted on every write and decrypted on every read,
 * for every module (repo, social routes, usernames ...) without changing them. Other collections pass
 * through untouched. Reads of documents with plaintext / old-key fields schedule a lazy re-write
 * (compare-and-replace on the raw document, so a concurrent update always wins).
 */
function encryptingSoda(soda, fc, { logger = console, lazy = true } = {}) {
  if (!soda || !fc || soda.__fieldCrypto) return soda;
  const spec = (c) => FIELD_SPEC[c];
  const pending = new Set();
  const migrate = (collection, key, raw) => {
    if (!lazy || !fc.docNeedsMigration(collection, raw) || pending.has(`${collection}:${key}`) || pending.size > 200) return;
    const id = `${collection}:${key}`;
    pending.add(id);
    const next = fc.migrateDoc(collection, raw);
    Promise.resolve()
      .then(() => soda.compareAndReplace(collection, key, raw, next))
      .then((ok) => { if (ok) fc.stats.migrated++; })
      .catch((e) => logger.warn?.(`[crypto] lazy field migration skipped: ${e && e.message ? String(e.message).slice(0, 80) : 'error'}`))
      .finally(() => pending.delete(id));
  };
  const readRow = (collection, row) => {
    if (!row || !spec(collection)) return row;
    migrate(collection, row.key, row.value);
    return { ...row, value: fc.decryptDoc(collection, row.value) };
  };
  const wrapped = Object.create(soda);
  Object.assign(wrapped, {
    __fieldCrypto: fc,
    __raw: soda,
    insert: (c, doc) => soda.insert(c, spec(c) ? fc.encryptDoc(c, doc) : doc),
    insertMany: (c, docs) => soda.insertMany(c, spec(c) && Array.isArray(docs) ? docs.map((d) => fc.encryptDoc(c, d)) : docs),
    replace: (c, key, doc) => soda.replace(c, key, spec(c) ? fc.encryptDoc(c, doc) : doc),
    upsertBy: (c, filter, doc) => soda.upsertBy(c, filter, spec(c) ? fc.encryptDoc(c, doc) : doc),
    async compareAndReplace(c, key, expected, replacement) {
      if (!spec(c)) return soda.compareAndReplace(c, key, expected, replacement);
      // Values are encrypted with a random IV: compare the decrypted views, then swap the raw document atomically.
      const raw = await soda.get(c, key);
      if (!raw || !require('util').isDeepStrictEqual(fc.decryptDoc(c, raw), expected)) return false;
      return soda.compareAndReplace(c, key, raw, fc.encryptDoc(c, replacement));
    },
    async get(c, key) {
      const d = await soda.get(c, key);
      if (!d || !spec(c)) return d;
      migrate(c, key, d);
      return fc.decryptDoc(c, d);
    },
    async query(c, filter, opts) {
      const rows = await soda.query(c, filter, opts);
      return spec(c) ? rows.map((r) => readRow(c, r)) : rows;
    },
    async findOne(c, filter, opts) {
      const r = await soda.findOne(c, filter, opts);
      return spec(c) ? readRow(c, r) : r;
    },
    scan(c, opts) {
      const it = soda.scan(c, opts);
      if (!spec(c)) return it;
      return (async function* () { for await (const page of it) yield page.map((r) => ({ ...r, value: fc.decryptDoc(c, r.value) })); })();
    },
  });
  return wrapped;
}

/** The process-wide FieldCrypto from config (DATA_ENC_KEY, DATA_ENC_KEY_ID, DATA_ENC_KEYS_PREVIOUS, BLIND_INDEX_KEY). */
function fieldCryptoFromConfig(config, logger = console) {
  let blindKey = config.blindIndexKey || null;
  if (!blindKey && config.jwtSecret) blindKey = crypto.createHmac('sha256', String(config.jwtSecret)).update('coroute-blind-index-v1').digest();
  return new FieldCrypto({ key: config.dataEncKey || null, keyId: config.dataEncKeyId || 'k1', previous: config.dataEncKeysPrevious || new Map(), blindKey, logger });
}

module.exports = { FieldCrypto, encryptingSoda, fieldCryptoFromConfig, parseKey, parseKeyList, FIELD_SPEC, USER_FIELDS, ROSTER_FIELDS, PREFIX };
