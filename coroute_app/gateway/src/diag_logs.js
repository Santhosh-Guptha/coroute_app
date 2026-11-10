'use strict';
/**
 * 3.55 app diagnostics logs (docs/features_355/diagnostics_logs.md).
 *
 * Riders send a gzip bundle of their app log (JSON lines written by the app's DiagLog) from
 * Settings › More › Diagnostics, after a safety moment ("send the log of this ride?"), or when an
 * admin asked for it ("Ask for logs"). Admins list, view and download them in the console
 * (System › Diagnostics, or a rider's "App logs").
 *
 *   POST   /api/me/diagnostics?reason=&build=&device=&os=&rideId=&requestId=   (auth; raw gzip body)
 *   GET    /api/me/diagnostics/requests                                      (auth; open admin requests)
 *   GET    /api/admin/diag-logs?userId=&username=&build=&reason=&days=
 *   GET    /api/admin/diag-logs/:id                (summary; audited diag.view)
 *   GET    /api/admin/diag-logs/:id/lines?cat=&level=&offset=&limit=
 *   GET    /api/admin/diag-logs/:id/download       (gzip; audited diag.download)
 *   DELETE /api/admin/diag-logs/:id                (audited diag.delete)
 *   POST   /api/admin/diag-logs/request {userId|username}   (socket / push DIAG_LOG_REQUEST; audited)
 *
 * Rules:
 *  - Body: gzip only (magic bytes, never the declared type), at most MAX_BYTES (5 MB) compressed and
 *    MAX_RAW_BYTES decompressed (zip-bomb guard), at most MAX_LINES lines. reason is required
 *    (manual | safety_prompt | admin_request); a request id must be an open request of this rider.
 *  - At most PER_DAY (5) bundles per rider per 24 h (counted in the database, so both gateway VMs agree).
 *  - Defence in depth: every line is parsed and rebuilt from the known keys only; fields with personal
 *    key names are dropped and string values are scrubbed again (e-mail, phone, JWT / tokens, long
 *    digit runs, URL queries); coordinates are rounded to 3 decimals. Unparseable lines are dropped.
 *  - Stored cleaned and re-gzipped: in Object Storage when DIAG_LOG_STORE=par (DIAG_LOG_PAR_URL, or the
 *    review photo bucket PAR with the prefix diag-logs/), else in the database (512 KB base64 chunks).
 *  - Kept RETENTION_DAYS (30) days (leased job 'diag-log-retention'); deleted with the account.
 *  - Admin switch `diagnosticsUpload` (default on) gates the upload only; admin reads stay available.
 *  - Server logs for these routes carry the request id and never the body, username or e-mail.
 */
const crypto = require('crypto');
const zlib = require('zlib');
const express = require('express');
const { stampEvent } = require('./push');

const COLLECTIONS = Object.freeze({ logs: 'diag_logs', chunks: 'diag_log_chunks', requests: 'diag_log_requests' });
const MAX_BYTES = 5 * 1024 * 1024;
const MAX_RAW_BYTES = 64 * 1024 * 1024;
const MAX_LINES = 500000;
const PER_DAY = 5;
const RETENTION_DAYS = 30;
const REQUEST_TTL_DAYS = 7;
const CHUNK_BYTES = 512 * 1024;
const DAY = 86400000;
const REASONS = new Set(['manual', 'safety_prompt', 'admin_request']);
const OBJECT_PREFIX = 'diag-logs/';
const ID_RE = /^dl_[a-f0-9]{20}$/;
const REQ_RE = /^dr_[a-f0-9]{16}$/;
const FEATURE_OFF = { error: 'Sending app logs is turned off for now.', code: 'FEATURE_OFF', feature: 'diagnosticsUpload' };

// ------------------------------------------------------------------ scrubbing (defence in depth)
// Same word list as the app (lib/domain/diag/diag_redact.dart).
const BLOCKED_WORDS = new Set([
  'name', 'names', 'firstname', 'lastname', 'username', 'nick', 'nickname',
  'phone', 'mobile', 'tel', 'msisdn', 'sms', 'email', 'mail',
  'message', 'msg', 'text', 'body', 'content', 'comment', 'note', 'notes', 'question', 'answer', 'title',
  'medical', 'blood', 'allergy', 'allergies', 'condition', 'conditions', 'medication', 'medications', 'organ', 'dob', 'birth',
  'token', 'jwt', 'bearer', 'password', 'secret', 'auth', 'authorization', 'cookie', 'otp', 'pin', 'key', 'apikey', 'signature',
  'address', 'street', 'home', 'destination', 'place', 'contact', 'contacts', 'emergency', 'guardian',
  'card', 'upi', 'vpa', 'payment', 'imei', 'serial',
]);
const ALLOW_SUFFIX = new Set(['len', 'length', 'count', 'ok', 'set', 'present', 'kind', 'type', 'source', 'src', 'ms', 'age']);
const wordsOf = (k) => String(k).replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(/[\s_\-.]+/).filter(Boolean);
function blockedKey(k) {
  const w = wordsOf(k);
  if (!w.length) return true;
  if (w.length > 1 && ALLOW_SUFFIX.has(w[w.length - 1])) return false;
  return w.some((x) => BLOCKED_WORDS.has(x));
}

const RE = {
  ctl: /[\u0000-\u001f\u007f]+/g,
  jwt: /eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/g,
  url: /https?:\/\/[^\s?#]+\?[^\s#]*/gi,
  email: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g,
  secret: /(?:bearer|token|key|secret|password|pwd|otp|auth)\s*[:=]?\s*\S+/gi,
  hex: /\b[A-Fa-f0-9]{24,}\b/g,
  b64: /[A-Za-z0-9_\-+/]{32,}={0,2}/g,
  coord: /-?\d{1,3}\.\d{4,}/g,
  phone: /\+?\(?\d[\d\s()-]{7,}\d/g,
  digits: /\d{7,}/g,
};

/** Free text made safe (the app already did this; a modified or old app is not trusted). */
function scrubText(input, max = 200) {
  let s = String(input == null ? '' : input).replace(RE.ctl, ' ');
  s = s.replace(RE.jwt, '<jwt>');
  s = s.replace(RE.url, (u) => u.slice(0, u.indexOf('?')));
  s = s.replace(RE.email, '<email>');
  s = s.replace(RE.secret, '<secret>');
  s = s.replace(RE.hex, (h) => (/\d/.test(h) ? '<hex>' : h));
  s = s.replace(RE.b64, (t) => (/\d/.test(t) && /[A-Z]/.test(t) && /[a-z]/.test(t) ? '<token>' : t));
  s = s.replace(RE.coord, (c) => String(Math.round(Number(c) * 1000) / 1000));
  s = s.replace(RE.phone, (p) => {
    const n = p.replace(/\D/g, '').length;
    const bare = n === p.length;
    return n >= 9 && n <= (bare ? 12 : 15) ? '<phone>' : p;
  });
  s = s.replace(RE.digits, '<num>');
  s = s.trim();
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

const LEVELS = new Set(['D', 'I', 'W', 'E']);
const CAT_RE = /^[a-z][a-z_]{1,19}$/;
const EVENT_RE = /^[a-z0-9_.]{1,48}$/;
const SHORT_ID = /^[A-Za-z0-9_.:-]{1,80}$/;

/** One parsed line rebuilt from the known keys only, or null when it is not a log entry. */
function cleanEntry(o) {
  if (!o || typeof o !== 'object' || Array.isArray(o)) return null;
  if (!Number.isFinite(o.t) || typeof o.e !== 'string') return null;
  const e = String(o.e).toLowerCase().replace(/[^a-z0-9_.]/g, '_').slice(0, 48);
  if (!EVENT_RE.test(e)) return null;
  const out = { t: Math.round(o.t) };
  if (Number.isFinite(o.m)) out.m = Math.round(o.m);
  out.l = LEVELS.has(o.l) ? o.l : 'I';
  out.c = typeof o.c === 'string' && CAT_RE.test(o.c) ? o.c : 'errors';
  out.e = e;
  if (o.f && typeof o.f === 'object' && !Array.isArray(o.f)) {
    const f = {};
    let n = 0;
    for (const [k0, v] of Object.entries(o.f)) {
      if (n >= 24) break;
      const k = String(k0).replace(/[^A-Za-z0-9_]/g, '_').slice(0, 32);
      if (!k || blockedKey(k) || v == null) continue;
      if (k === 'lat' || k === 'lng' || k === 'lon') {
        if (typeof v === 'number' && Number.isFinite(v)) { f[k] = Math.round(v * 1000) / 1000; n++; }
        continue;
      }
      if (typeof v === 'boolean') f[k] = v;
      else if (typeof v === 'number') f[k] = Number.isFinite(v) ? (Number.isInteger(v) ? v : Math.round(v * 100) / 100) : 0;
      else if (typeof v === 'string') { const s = scrubText(v, k === 'stack' ? 400 : 200); if (!s) continue; f[k] = s; }
      else continue; // nested objects / arrays: never stored
      n++;
    }
    if (n) out.f = f;
  }
  if (typeof o.b === 'string') out.b = o.b.replace(/[^A-Za-z0-9.+_-]/g, '').slice(0, 40);
  if (typeof o.s === 'string') out.s = o.s.replace(/[^A-Za-z0-9]/g, '').slice(0, 16);
  if (typeof o.r === 'string' && SHORT_ID.test(o.r)) out.r = o.r;
  if (Number.isFinite(o.n)) out.n = Math.round(o.n);
  return out;
}

class DiagError extends Error {
  constructor(status, message, code) { super(message); this.status = status; this.code = code; }
}

/** gunzip + parse + clean. Returns { text, lines, dropped, summary }. Throws DiagError. */
function cleanBundle(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 18 || buf[0] !== 0x1f || buf[1] !== 0x8b) {
    throw new DiagError(415, 'The log must be a gzip file.', 'NOT_GZIP');
  }
  if (buf.length > MAX_BYTES) throw new DiagError(413, 'The log is too large (5 MB at most).', 'TOO_LARGE');
  let raw;
  try {
    raw = zlib.gunzipSync(buf, { maxOutputLength: MAX_RAW_BYTES });
  } catch (e) {
    if (e && (e.code === 'ERR_BUFFER_TOO_LARGE' || /larger than/i.test(e.message || ''))) throw new DiagError(413, 'The log is too large once unpacked.', 'TOO_LARGE');
    throw new DiagError(400, 'The log file is damaged.', 'BAD_BUNDLE');
  }
  const src = raw.toString('utf8').split('\n');
  if (src.length > MAX_LINES + 1) throw new DiagError(413, 'The log has too many lines.', 'TOO_LARGE');
  const out = [];
  const byCategory = {};
  const byLevel = { D: 0, I: 0, W: 0, E: 0 };
  let dropped = 0, first = null, last = null, meta = null;
  for (const line of src) {
    const s = line.trim();
    if (!s) continue;
    let o;
    try { o = JSON.parse(s); } catch { dropped++; continue; }
    if (o && o.meta === 'coroute-diag' && meta === null) { meta = o; continue; }
    const c = cleanEntry(o);
    if (!c) { dropped++; continue; }
    out.push(JSON.stringify(c));
    byCategory[c.c] = (byCategory[c.c] || 0) + 1;
    byLevel[c.l]++;
    if (first === null || c.t < first) first = c.t;
    if (last === null || c.t > last) last = c.t;
  }
  if (!out.length) throw new DiagError(400, 'The log has no entries.', 'EMPTY');
  return {
    text: `${out.join('\n')}\n`,
    lines: out.length,
    dropped,
    rawBytes: raw.length,
    summary: { byCategory, byLevel, firstAt: first, lastAt: last, sessions: null },
    meta,
  };
}

const cleanMeta = (v, max, re = /[^A-Za-z0-9 .+_()-]/g) => (typeof v === 'string' ? scrubText(v, max).replace(re, '').trim().slice(0, max) : '');

// ------------------------------------------------------------------ storage
function createStore({ soda, objectStore = null }) {
  if (objectStore) {
    return {
      kind: 'par',
      async put(id, gz) { await objectStore.put(`${OBJECT_PREFIX}${id}.jsonl.gz`, gz, 'application/gzip'); },
      async get(id) { return objectStore.get(`${OBJECT_PREFIX}${id}.jsonl.gz`); },
      async del(id) { await objectStore.del(`${OBJECT_PREFIX}${id}.jsonl.gz`).catch(() => {}); },
    };
  }
  return {
    kind: 'db',
    async put(id, gz) {
      const docs = [];
      for (let i = 0, k = 0; i < gz.length; i += CHUNK_BYTES, k++) docs.push({ id, i: k, data: gz.subarray(i, i + CHUNK_BYTES).toString('base64') });
      for (const d of docs) await soda.insert(COLLECTIONS.chunks, d);
    },
    async get(id) {
      const rows = await soda.query(COLLECTIONS.chunks, { id }, { limit: 1000 });
      if (!rows.length) return null;
      rows.sort((a, b) => a.value.i - b.value.i);
      return Buffer.concat(rows.map((r) => Buffer.from(r.value.data, 'base64')));
    },
    async del(id) { await soda.removeWhere(COLLECTIONS.chunks, { id }).catch(() => {}); },
  };
}

/** DIAG_LOG_STORE=par with DIAG_LOG_PAR_URL (or REVIEW_PHOTO_PAR_URL): Object Storage; else the database. */
function objectStoreFromEnv(env = process.env) {
  if (String(env.DIAG_LOG_STORE || '').trim().toLowerCase() !== 'par') return null;
  const url = String(env.DIAG_LOG_PAR_URL || env.REVIEW_PHOTO_PAR_URL || '').trim();
  if (!url) throw new Error('[diag-logs] DIAG_LOG_STORE=par needs DIAG_LOG_PAR_URL (a bucket PAR ending in /o/)');
  return require('./object_store').createParStore(url);
}

// ------------------------------------------------------------------ service
class DiagLogs {
  /**
   * @param {{repo:any, hub?:any, flagsOf?:Function, logger?:any, objectStore?:any, clock?:Function}} o
   */
  constructor({ repo, hub = null, flagsOf = () => null, logger = console, objectStore = undefined, clock = Date.now }) {
    this.repo = repo;
    this.soda = repo.soda;
    this.hub = hub;
    this.flagsOf = flagsOf;
    this.log = logger;
    this.clock = clock;
    this.store = createStore({ soda: this.soda, objectStore: objectStore === undefined ? objectStoreFromEnv() : objectStore });
    this._ready = null;
  }

  async ensure() {
    if (!this._ready) {
      this._ready = (async () => {
        for (const c of Object.values(COLLECTIONS)) await this.soda.ensureCollection(c);
        const idx = (coll, name, fields, unique = false) => this.soda.ensureIndex(coll, { name, unique, fields: fields.map((path) => ({ path })) }).catch(() => {});
        await idx(COLLECTIONS.logs, 'diag_logs_id_ux', ['id'], true);
        await idx(COLLECTIONS.logs, 'diag_logs_user_ix', ['userId']);
        await idx(COLLECTIONS.chunks, 'diag_chunks_id_ix', ['id']);
        await idx(COLLECTIONS.requests, 'diag_req_id_ux', ['requestId'], true);
        await idx(COLLECTIONS.requests, 'diag_req_user_ix', ['userId']);
      })().catch((e) => { this._ready = null; throw e; });
    }
    return this._ready;
  }

  uploadOn() {
    const fl = this.flagsOf();
    return !fl || fl.isOn('diagnosticsUpload');
  }

  async countRecent(userId, now = this.clock()) {
    const rows = await this.soda.query(COLLECTIONS.logs, { userId, at: { $gte: now - DAY } }, { limit: PER_DAY + 1 });
    return rows.length;
  }

  /** Validates, cleans and stores one bundle. Returns the stored record (without the body). */
  async upload(user, buf, query = {}) {
    await this.ensure();
    const now = this.clock();
    const reason = String(query.reason || '');
    if (!REASONS.has(reason)) throw new DiagError(400, 'reason must be manual, safety_prompt or admin_request.', 'BAD_REASON');
    let request = null;
    if (query.requestId != null && query.requestId !== '') {
      const rid = String(query.requestId);
      if (!REQ_RE.test(rid)) throw new DiagError(400, 'Unknown log request.', 'BAD_REQUEST_ID');
      const r = await this.soda.findOne(COLLECTIONS.requests, { requestId: rid, userId: user.userId });
      if (!r) throw new DiagError(400, 'Unknown log request.', 'BAD_REQUEST_ID');
      request = r;
    }
    if ((await this.countRecent(user.userId, now)) >= PER_DAY) {
      throw new DiagError(429, `You can send app logs up to ${PER_DAY} times a day.`, 'RATE_LIMITED');
    }
    const cleaned = cleanBundle(buf);
    const gz = zlib.gzipSync(Buffer.from(cleaned.text, 'utf8'));
    const id = `dl_${crypto.randomBytes(10).toString('hex')}`;
    const rideId = typeof query.rideId === 'string' && SHORT_ID.test(query.rideId) ? query.rideId : null;
    const doc = {
      id,
      userId: user.userId,
      username: typeof user.username === 'string' ? user.username : '',
      usernameLc: typeof user.username === 'string' ? user.username.toLowerCase() : '',
      build: cleanMeta(query.build, 40, /[^A-Za-z0-9.+_-]/g),
      device: cleanMeta(query.device, 60),
      os: cleanMeta(query.os, 20),
      reason,
      rideId,
      requestId: request ? request.value.requestId : null,
      at: now,
      expiresAt: now + RETENTION_DAYS * DAY,
      bytes: gz.length,
      uploadBytes: buf.length,
      rawBytes: cleaned.rawBytes,
      lines: cleaned.lines,
      dropped: cleaned.dropped,
      errors: cleaned.summary.byLevel.E,
      warnings: cleaned.summary.byLevel.W,
      summary: cleaned.summary,
      storage: this.store.kind,
    };
    await this.store.put(id, gz);
    try {
      await this.soda.insert(COLLECTIONS.logs, doc);
    } catch (e) {
      await this.store.del(id);
      throw e;
    }
    if (request) {
      await this.soda.replace(COLLECTIONS.requests, request.key, { ...request.value, status: 'fulfilled', fulfilledAt: now, logId: id }).catch(() => {});
    }
    return doc;
  }

  async openRequests(userId, now = this.clock()) {
    await this.ensure();
    const rows = await this.soda.query(COLLECTIONS.requests, { userId, status: 'open' }, { limit: 20 });
    return rows.map((r) => r.value).filter((r) => now - r.at < REQUEST_TTL_DAYS * DAY)
      .map((r) => ({ requestId: r.requestId, at: r.at }));
  }

  /** Admin "Ask for logs": one open request per rider (reused), socket + push to the rider. */
  async request(admin, userId) {
    await this.ensure();
    const now = this.clock();
    const open = (await this.openRequests(userId, now))[0];
    let requestId = open && open.requestId;
    if (!requestId) {
      requestId = `dr_${crypto.randomBytes(8).toString('hex')}`;
      await this.soda.insert(COLLECTIONS.requests, { requestId, userId, at: now, by: admin.userId, status: 'open' });
    }
    let delivered = 0;
    if (this.hub) {
      const ev = stampEvent({ type: 'DIAG_LOG_REQUEST', requestId });
      try { delivered = this.hub.sendToUser(userId, ev) || 0; } catch { delivered = 0; }
      if (this.hub.push) this.hub.push.onSocketEvent(userId, ev, { delivered }).catch(() => {});
    }
    return { requestId, delivered: delivered > 0, reused: !!open };
  }

  async find(id) {
    if (!ID_RE.test(String(id || ''))) return null;
    await this.ensure();
    return this.soda.findOne(COLLECTIONS.logs, { id: String(id) });
  }

  async list({ userId, username, build, reason, days = 7, limit = 200 } = {}, now = this.clock()) {
    await this.ensure();
    const d = Math.max(1, Math.min(RETENTION_DAYS, parseInt(days, 10) || 7));
    const filter = { at: { $gte: now - d * DAY } };
    if (userId) filter.userId = String(userId);
    if (reason && REASONS.has(String(reason))) filter.reason = String(reason);
    let rows = (await this.soda.query(COLLECTIONS.logs, filter, { limit: 1000, orderBy: [{ path: 'at', datatype: 'number', order: 'desc' }] })).map((r) => r.value);
    if (username) {
      const u = String(username).trim().toLowerCase();
      rows = rows.filter((x) => x.usernameLc === u);
    }
    if (build) {
      const b = String(build).trim();
      rows = rows.filter((x) => String(x.build || '').startsWith(b));
    }
    rows.sort((a, b) => b.at - a.at);
    const lim = Math.max(1, Math.min(500, parseInt(limit, 10) || 200));
    return rows.slice(0, lim).map(publicView);
  }

  async body(id) {
    const gz = await this.store.get(id);
    return gz || null;
  }

  async lines(id, { cat, level, offset = 0, limit = 500 } = {}) {
    const gz = await this.body(id);
    if (!gz) return null;
    const all = zlib.gunzipSync(gz).toString('utf8').split('\n').filter(Boolean);
    const lv = String(level || '');
    const keep = lv === 'E' ? new Set(['E']) : lv === 'W' ? new Set(['W', 'E']) : lv === 'I' ? new Set(['I', 'W', 'E']) : null;
    const c = cat && CAT_RE.test(String(cat)) ? String(cat) : null;
    const parsed = [];
    for (const l of all) {
      let o;
      try { o = JSON.parse(l); } catch { continue; }
      if (c && o.c !== c) continue;
      if (keep && !keep.has(o.l)) continue;
      parsed.push(o);
    }
    const off = Math.max(0, parseInt(offset, 10) || 0);
    const lim = Math.max(1, Math.min(2000, parseInt(limit, 10) || 500));
    return { total: parsed.length, lines: parsed.slice(off, off + lim) };
  }

  async remove(id) {
    const r = await this.find(id);
    if (!r) return false;
    await this.store.del(id);
    await this.soda.remove(COLLECTIONS.logs, r.key);
    return true;
  }

  /** Account erase: every log, its stored body and the rider's requests. */
  async forgetUser(userId) {
    if (!userId) return 0;
    await this.ensure();
    const rows = await this.soda.query(COLLECTIONS.logs, { userId }, { limit: 1000 });
    for (const r of rows) {
      await this.store.del(r.value.id);
      await this.soda.remove(COLLECTIONS.logs, r.key);
    }
    await this.soda.removeWhere(COLLECTIONS.requests, { userId }).catch(() => {});
    return rows.length;
  }

  /** Retention: logs past expiresAt (30 days) and requests older than 7 days. */
  async runRetention(now = this.clock(), { signal } = {}) {
    await this.ensure();
    let removed = 0;
    for (let round = 0; round < 50; round++) {
      if (signal && signal.aborted) break;
      const rows = await this.soda.query(COLLECTIONS.logs, { expiresAt: { $lt: now } }, { limit: 100 });
      if (!rows.length) break;
      for (const r of rows) {
        await this.store.del(r.value.id);
        await this.soda.remove(COLLECTIONS.logs, r.key);
        removed++;
      }
    }
    await this.soda.removeWhere(COLLECTIONS.requests, { at: { $lt: now - REQUEST_TTL_DAYS * DAY } }).catch(() => {});
    if (removed) this.log.info?.(`[diag-logs] retention removed ${removed} log(s)`);
    return removed;
  }

  // ---------------------------------------------------------------- routes
  register({ r, wrap, requireAdmin }) {
    const self = this;
    const raw = express.raw({ type: () => true, limit: MAX_BYTES });
    const readBody = (req, res, next) => raw(req, res, (err) => {
      if (!err) return next();
      if (err.status === 413 || err.type === 'entity.too.large') return res.status(413).json({ error: 'The log is too large (5 MB at most).', code: 'TOO_LARGE' });
      return res.status(400).json({ error: 'The log could not be read.', code: 'BAD_BODY' });
    });
    const fail = (req, res, e) => {
      if (e instanceof DiagError) return res.status(e.status).set('Cache-Control', 'no-store').json({ error: e.message, code: e.code });
      // Request id and route only: never the body, the username or the e-mail.
      self.log.error?.(`[diag-logs] ${req.method} ${req.route ? req.route.path : ''} failed req=${req.requestId || '-'}: ${e && e.message ? String(e.message).slice(0, 200) : e}`);
      return res.status(500).json({ error: 'Internal server error', requestId: req.requestId });
    };
    const audit = async (req, action, target, details = {}) => {
      if (typeof self.repo.addAuditEntry !== 'function') return;
      await self.repo.addAuditEntry({ at: Date.now(), by: req.user.email || req.user.userId, byUserId: req.user.userId, action, target, details }).catch(() => {});
    };

    r.post('/me/diagnostics', (req, res, next) => (self.uploadOn() ? next() : res.status(403).set('Cache-Control', 'no-store').json(FEATURE_OFF)), readBody, wrap(async (req, res) => {
      try {
        const user = req.dbUser || req.user;
        const doc = await self.upload({ userId: req.user.userId, username: user && user.username }, req.body, req.query || {});
        self.log.info?.(`[diag-logs] stored ${doc.id} reason=${doc.reason} lines=${doc.lines} bytes=${doc.bytes} req=${req.requestId || '-'}`);
        res.status(201).set('Cache-Control', 'no-store').json({ ok: true, id: doc.id, lines: doc.lines, dropped: doc.dropped, expiresAt: doc.expiresAt });
      } catch (e) { fail(req, res, e); }
    }));

    r.get('/me/diagnostics/requests', wrap(async (req, res) => {
      try {
        res.set('Cache-Control', 'no-store').json({ ok: true, requests: await self.openRequests(req.user.userId) });
      } catch (e) { fail(req, res, e); }
    }));

    r.get('/admin/diag-logs', requireAdmin, wrap(async (req, res) => {
      try {
        const q = req.query || {};
        res.set('Cache-Control', 'no-store').json({ ok: true, logs: await self.list({ userId: q.userId, username: q.username, build: q.build, reason: q.reason, days: q.days, limit: q.limit }) });
      } catch (e) { fail(req, res, e); }
    }));

    r.post('/admin/diag-logs/request', requireAdmin, wrap(async (req, res) => {
      try {
        const b = req.body && typeof req.body === 'object' ? req.body : {};
        let userId = typeof b.userId === 'string' ? b.userId.trim() : '';
        if (!userId && typeof b.username === 'string' && b.username.trim()) {
          const u = await require('./usernames').findUserByUsername(self.repo, b.username).catch(() => null);
          userId = u && u.userId ? u.userId : '';
        }
        if (!userId) return res.status(400).json({ error: 'userId or username is required.', code: 'BAD_USER' });
        const target = typeof self.repo.findUserById === 'function' ? await self.repo.findUserById(userId) : { userId };
        if (!target) return res.status(404).json({ error: 'Rider not found.', code: 'NOT_FOUND' });
        const out = await self.request(req.user, userId);
        await audit(req, 'diag.request', userId, { requestId: out.requestId, delivered: out.delivered });
        res.set('Cache-Control', 'no-store').json({ ok: true, ...out });
      } catch (e) { fail(req, res, e); }
    }));

    r.get('/admin/diag-logs/:id', requireAdmin, wrap(async (req, res) => {
      try {
        const row = await self.find(req.params.id);
        if (!row) return res.status(404).json({ error: 'Log not found.', code: 'NOT_FOUND' });
        await audit(req, 'diag.view', row.value.id, { userId: row.value.userId });
        res.set('Cache-Control', 'no-store').json({ ok: true, log: publicView(row.value), summary: row.value.summary || null });
      } catch (e) { fail(req, res, e); }
    }));

    r.get('/admin/diag-logs/:id/lines', requireAdmin, wrap(async (req, res) => {
      try {
        const row = await self.find(req.params.id);
        if (!row) return res.status(404).json({ error: 'Log not found.', code: 'NOT_FOUND' });
        const q = req.query || {};
        const out = await self.lines(row.value.id, { cat: q.cat, level: q.level, offset: q.offset, limit: q.limit });
        if (!out) return res.status(404).json({ error: 'The log file is gone.', code: 'NOT_FOUND' });
        res.set('Cache-Control', 'no-store').json({ ok: true, ...out });
      } catch (e) { fail(req, res, e); }
    }));

    r.get('/admin/diag-logs/:id/download', requireAdmin, wrap(async (req, res) => {
      try {
        const row = await self.find(req.params.id);
        if (!row) return res.status(404).json({ error: 'Log not found.', code: 'NOT_FOUND' });
        const gz = await self.body(row.value.id);
        if (!gz) return res.status(404).json({ error: 'The log file is gone.', code: 'NOT_FOUND' });
        await audit(req, 'diag.download', row.value.id, { userId: row.value.userId, bytes: gz.length });
        res.status(200).set({
          'Content-Type': 'application/gzip',
          'Content-Disposition': `attachment; filename="coroute-diag-${row.value.id}.jsonl.gz"`,
          'Cache-Control': 'no-store',
          'X-Content-Type-Options': 'nosniff',
        }).send(gz);
      } catch (e) { fail(req, res, e); }
    }));

    r.delete('/admin/diag-logs/:id', requireAdmin, wrap(async (req, res) => {
      try {
        const row = await self.find(req.params.id);
        if (!row) return res.status(404).json({ error: 'Log not found.', code: 'NOT_FOUND' });
        await self.remove(row.value.id);
        await audit(req, 'diag.delete', row.value.id, { userId: row.value.userId });
        res.set('Cache-Control', 'no-store').json({ ok: true, deleted: true });
      } catch (e) { fail(req, res, e); }
    }));
  }
}

/** What the admin console lists (no summary body, no storage details). */
function publicView(d) {
  return {
    id: d.id, userId: d.userId, username: d.username || '', build: d.build || '', device: d.device || '', os: d.os || '',
    reason: d.reason, rideId: d.rideId || null, requestId: d.requestId || null, at: d.at, expiresAt: d.expiresAt,
    bytes: d.bytes, lines: d.lines, dropped: d.dropped || 0, errors: d.errors || 0, warnings: d.warnings || 0,
  };
}

/**
 * Wires the service once in app.js: erase cascade (logs go with the account) and the leased retention
 * job. Returns the service (app.js passes it to buildRouter for the routes).
 */
function attachDiagLogs({ repo, hub = null, featureFlags = null, lease = null, logger = console, objectStore = undefined, clock } = {}) {
  const svc = new DiagLogs({ repo, hub, flagsOf: () => featureFlags, logger, objectStore, ...(clock ? { clock } : {}) });
  if (!repo.__diagCascade) {
    repo.__diagCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await svc.forgetUser(user.userId).catch((e) => logger.warn?.(`[diag-logs] erase cleanup failed: ${e.message}`));
      return out;
    };
  }
  svc.startJobs = () => {
    if (lease && typeof lease.run === 'function') {
      lease.run('diag-log-retention', 6 * 3600000, ({ signal } = {}) => svc.runRetention(Date.now(), { signal }), { firstDelayMs: 5 * 60000 });
    }
  };
  return svc;
}

module.exports = {
  DiagLogs, DiagError, attachDiagLogs, cleanBundle, cleanEntry, scrubText, blockedKey, publicView, objectStoreFromEnv,
  COLLECTIONS, MAX_BYTES, MAX_RAW_BYTES, PER_DAY, RETENTION_DAYS, REASONS,
};
