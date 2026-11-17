'use strict';
/**
 * 3.57 security: server-side sessions. docs/features_355/sessions_and_security.md
 *
 * One document per signed-in device in `auth_sessions`:
 *   { sessionId, userId, kind, v2, deviceLabel, platform, uaSummary, ipHash, createdAt, lastSeenAt,
 *     absoluteExpiresAt, refreshHash, refreshCounter, prevRefreshHash, prevRefreshCounter, rotatedAt,
 *     mfa, reauthAt, revokedAt, revokeReason, revokedBy }
 * Refresh tokens are never stored: only their SHA-256 (256-bit random secrets, so a plain hash is enough).
 *
 * Kinds and lifetimes (config):
 *   app       Android app (>= 10025, X-CoRoute-Session: 2): 15 min access token + rotating refresh token;
 *             v3.60: no idle or absolute limit by default (SESSION_APP_IDLE_DAYS / SESSION_APP_ABSOLUTE_DAYS = 0): a
 *             phone stays signed in until the rider signs out, changes the password, or the session is revoked.
 *             With a limit set, it is never ended during a ride (extended while riding).
 *   legacy    older app builds and API clients that did not opt in: the long sliding token of before (30 days),
 *             now bound to this record (logout / revoke work instantly); idle 30 days; no absolute limit
 *             (they are retired by raising MIN_APP_BUILD, never by signing riders out).
 *   web       website /account, /plans ...: idle 60 min, absolute 7 days; refresh token in an httpOnly cookie.
 *   admin     /admin: idle 30 min, absolute 12 h, 2-step verification for MASTER_ADMIN; cookie SameSite=Strict.
 *   operator  /operator: idle 30 min, absolute 12 h; cookie SameSite=Strict.
 *
 * Rotation with reuse detection (refresh tokens "rt1.<sessionId>.<counter>.<secret>"):
 *   - the current token rotates (counter + 1);
 *   - the token just before it, within REFRESH_REUSE_GRACE_SEC of the rotation, also rotates (a lost reply or a
 *     second browser tab: never a sign-out);
 *   - any other older or mismatching token of the session = reuse: the whole session is revoked and audited.
 *
 * Every authenticated request and socket message checks the session (cached for USER_GATE_TTL_MS, invalidated
 * at once on this node by every revoke and on the peer node through the mirror extension 'ss').
 */
const crypto = require('crypto');
const config = require('./config');

const COLLECTION = 'auth_sessions';
const KINDS = new Set(['app', 'legacy', 'web', 'admin', 'operator']);
const SID_RE = /^ses_[A-Za-z0-9_-]{16,40}$/;
const RT_RE = /^rt1\.(ses_[A-Za-z0-9_-]{16,40})\.(\d{1,9})\.([A-Za-z0-9_-]{40,64})$/;

const sha256 = (s) => crypto.createHash('sha256').update(String(s)).digest('hex');
const safeEq = (a, b) => typeof a === 'string' && typeof b === 'string' && a.length === b.length && crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));

class SessionError extends Error {
  constructor(message, code = 'SESSION_INVALID', status = 401) { super(message); this.name = 'SessionError'; this.code = code; this.status = status; }
}

const MSG_SIGNED_OUT = 'You were signed out. Please sign in again.';
const MSG_EXPIRED = 'Your session expired. Please sign in again.';

/**
 * Lifetimes of one kind of session (ms). touchMs: how stale lastSeenAt may get before it is written again.
 * v3.62 phone sessions (app / legacy): the limits come from the session's own copy of the admin policy (`s.appPol`,
 * stamped at sign-in, src/session_settings.js). A session without one (made before v3.62) has no time limit, so a
 * policy change or a VM .env value never signs out riders who are already signed in.
 */
function policyOf(kind, c = config, s = null) {
  const min = 60000; const hour = 60 * min; const day = 24 * hour;
  const ap = s && s.appPol && typeof s.appPol === 'object' ? s.appPol : null;
  const appIdle = ap ? Math.max(0, Number(ap.idleDays) || 0) * day : 0;
  const appAbs = ap ? Math.max(0, Number(ap.absDays) || 0) * day : 0;
  switch (kind) {
    case 'web': return { idleMs: c.sessionWebIdleMin * min, absMs: c.sessionWebAbsoluteDays * day, touchMs: min, absHard: true, short: true, cookie: '__Host-cr_rt', sameSite: 'Lax' };
    case 'admin': return { idleMs: c.sessionAdminIdleMin * min, absMs: c.sessionAdminAbsoluteHours * hour, touchMs: min, absHard: true, short: true, cookie: '__Host-cr_adm', sameSite: 'Strict' };
    case 'operator': return { idleMs: c.sessionAdminIdleMin * min, absMs: c.sessionAdminAbsoluteHours * hour, touchMs: min, absHard: true, short: true, cookie: '__Host-cr_op', sameSite: 'Strict' };
    case 'app': return { idleMs: appIdle, absMs: appAbs, touchMs: 10 * min, absHard: false, short: true, cookie: null };
    default: return { idleMs: appIdle, absMs: 0, touchMs: 10 * min, absHard: false, short: false, cookie: null };
  }
}

const isPhoneKind = (k) => k === 'app' || k === 'legacy';
/** v3.62: how many times a phone may rotate from its previous refresh token after the 60 s window. */
const PREV_LATE_MAX = 3;

/** "Chrome on Windows", "CoRoute app on Android" ... from a User-Agent (no version numbers, no device ids). */
function uaSummary(ua) {
  const s = String(ua || '');
  if (!s) return 'Unknown device';
  if (/dart:io|CoRoute/i.test(s)) return /iPhone|iOS/i.test(s) ? 'CoRoute app on iPhone' : 'CoRoute app on Android';
  const browser = /Edg\//.test(s) ? 'Edge' : /OPR\/|Opera/.test(s) ? 'Opera' : /SamsungBrowser/.test(s) ? 'Samsung Internet'
    : /Firefox\//.test(s) ? 'Firefox' : /Chrome\//.test(s) ? 'Chrome' : /Safari\//.test(s) ? 'Safari' : /curl|node|undici|axios|python/i.test(s) ? 'Script' : 'Browser';
  const os = /Android/.test(s) ? 'Android' : /iPhone|iPad|iOS/.test(s) ? 'iPhone' : /Windows/.test(s) ? 'Windows' : /Mac OS X|Macintosh/.test(s) ? 'Mac'
    : /Linux/.test(s) ? 'Linux' : '';
  return os ? `${browser} on ${os}` : browser;
}

const cleanLabel = (v, max = 60) => String(v == null ? '' : v).replace(/[\u0000-\u001f\u007f<>]/g, '').trim().slice(0, max);

class SessionStore {
  /**
   * @param {{soda: any, logger?: object, clock?: () => number, ttlMs?: number, fieldCrypto?: any, audit?: any}} o
   */
  constructor({ soda, logger = console, clock = () => Date.now(), ttlMs = config.userGateTtlMs, fieldCrypto = null, audit = null } = {}) {
    this.soda = soda; this.log = logger; this.clock = clock; this.ttlMs = ttlMs; this.fc = fieldCrypto; this.audit = audit;
    this.cache = new Map(); // sessionId -> { s, at }
    this.inflight = new Map();
    this.maxEntries = 20000;
    /** ({sids, userId, all, reason}) => void: app.js closes sockets and pokes the peer node. */
    this.onRevoke = null;
    /** async (userId) => boolean: is the rider on a live ride / open alert right now (app.js). */
    this.isRiding = null;
    /** v3.62 async () => {idleDays, absDays}: the admin's phone sign-in policy for NEW sessions (src/session_settings.js). */
    this.appPolicy = null;
    this.reads = 0;
  }

  async init() {
    await this.soda.ensureCollection(COLLECTION);
    const idx = (name, fields, unique = false) => this.soda.ensureIndex(COLLECTION, { name, unique, fields: fields.map((f) => (typeof f === 'string' ? { path: f } : f)) });
    await idx('auth_sessions_id_ux', ['sessionId'], true);
    await idx('auth_sessions_user_ix', ['userId']);
    await idx('auth_sessions_seen_ix', [{ path: 'lastSeenAt', datatype: 'number' }]);
  }

  static kindOf(client, v2) {
    const c = String(client || '').toLowerCase();
    if (c === 'web' || c === 'admin' || c === 'operator') return c;
    if (c === 'app' || v2) return v2 ? 'app' : 'legacy';
    return 'legacy';
  }

  policy(kind) { return policyOf(kind); }

  _ipHash(ip) {
    if (!ip) return '';
    return this.fc ? this.fc.blindIndex(ip, 'ip') : sha256(`ip|${ip}`).slice(0, 32);
  }

  /** A keyed hash of a device / install id sent by the app ('' when absent or malformed). */
  deviceKey(id, purpose) {
    const v = String(id == null ? '' : id);
    if (!/^[A-Za-z0-9_-]{16,128}$/.test(v)) return '';
    return this.fc ? this.fc.blindIndex(v, `device-${purpose}`) : sha256(`${purpose}|${v}`).slice(0, 32);
  }

  _put(s) {
    this.cache.delete(s.sessionId);
    this.cache.set(s.sessionId, { s, at: this.clock() });
    while (this.cache.size > this.maxEntries) this.cache.delete(this.cache.keys().next().value);
  }

  _newRefresh(sessionId, counter) {
    const secret = crypto.randomBytes(32).toString('base64url');
    const token = `rt1.${sessionId}.${counter}.${secret}`;
    return { token, hash: sha256(token) };
  }

  /**
   * Creates a session for a signed-in user. Returns { session, refreshToken|null }.
   * @param {{user: object, kind?: string, device?: {label?: string, platform?: string}, ip?: string, ua?: string, mfa?: boolean}} o
   */
  async create({ user, kind = 'legacy', device = {}, ip = '', ua = '', mfa = false, build = 0, lockChecked = false }) {
    if (!KINDS.has(kind)) kind = 'legacy';
    // v3.62: a phone session keeps a copy of the admin policy of the moment it was made (0 / 0 = no limit: no copy).
    let appPol = null;
    if (isPhoneKind(kind)) {
      let ap = null;
      try { ap = this.appPolicy ? await this.appPolicy() : null; } catch { ap = null; }
      const idleDays = Math.max(0, Math.round(Number(ap ? ap.idleDays : config.sessionAppIdleDays) || 0));
      const absDays = Math.max(0, Math.round(Number(ap ? ap.absDays : config.sessionAppAbsoluteDays) || 0));
      if (idleDays || absDays) appPol = { idleDays, absDays, setAt: this.clock() };
    }
    const pol = policyOf(kind, config, appPol ? { appPol } : null);
    const t = this.clock();
    const sessionId = `ses_${crypto.randomBytes(16).toString('base64url')}`;
    const s = {
      sessionId, userId: user.userId, kind, v2: pol.short,
      deviceLabel: cleanLabel(device && device.label) || uaSummary(ua),
      platform: cleanLabel(device && device.platform, 20) || (kind === 'web' || kind === 'admin' || kind === 'operator' ? 'web' : (/iPhone|iOS/i.test(ua) ? 'ios' : 'android')),
      uaSummary: uaSummary(ua),
      ipHash: this._ipHash(ip),
      createdAt: t, lastSeenAt: t,
      absoluteExpiresAt: pol.absMs ? t + pol.absMs : 0,
      mfa: !!mfa, reauthAt: t,
      // Round 4 ride lock (src/ride_lock.js): keyed hashes of the app's device id / install id (never the ids), the
      // client build, and whether this sign-in passed the ride lock check.
      deviceKey: this.deviceKey(device && device.id, 'dev'), installKey: this.deviceKey(device && device.installId, 'inst'),
      build: Number.isInteger(build) && build > 0 && build < 1000000 ? build : 0, lockChecked: !!lockChecked,
      refreshHash: '', refreshCounter: 0, prevRefreshHash: '', prevRefreshCounter: -1, rotatedAt: 0,
      revokedAt: 0, revokeReason: '',
      ...(appPol ? { appPol } : {}),
    };
    let refreshToken = null;
    if (pol.short) {
      const r = this._newRefresh(sessionId, 1);
      s.refreshHash = r.hash; s.refreshCounter = 1;
      refreshToken = r.token;
    }
    const key = await this.soda.insert(COLLECTION, s);
    const stored = { ...s, key };
    this._put(stored);
    return { session: stored, refreshToken };
  }

  async _read(sessionId, { fresh = false, maxAgeMs = this.ttlMs, swr = false } = {}) {
    if (!SID_RE.test(String(sessionId || ''))) return null;
    const hit = this.cache.get(sessionId);
    const age = hit ? this.clock() - hit.at : Infinity;
    if (!fresh && hit && age < maxAgeMs) return hit.s;
    // v3.56 hot path (socket telemetry): an entry up to 2 x maxAgeMs old answers now, one refresh runs behind it.
    if (!fresh && hit && swr && age < 2 * maxAgeMs) {
      if (!this.inflight.has(sessionId)) this._read(sessionId).catch(() => {});
      return hit.s;
    }
    let p = this.inflight.get(sessionId);
    if (!p) {
      this.reads++;
      p = this.soda.findOne(COLLECTION, { sessionId }).then((r) => {
        if (this.inflight.get(sessionId) === p) this.inflight.delete(sessionId);
        const s = r ? { ...r.value, key: r.key } : null;
        if (s) this._put(s); else this.cache.delete(sessionId);
        return s;
      }, (e) => {
        if (this.inflight.get(sessionId) === p) this.inflight.delete(sessionId);
        // A short database outage never signs anyone out: an already known session is used until reads work.
        // Every revoke on this node removes its entry, so a revoked session never falls back to old data.
        const stale = this.cache.get(sessionId);
        if (stale) return stale.s;
        throw e;
      });
      this.inflight.set(sessionId, p);
    }
    return p;
  }

  /**
   * Writes a change to an existing session record: the patch is applied to the stored document (read again), so a
   * revoke made on the other node is never undone by an older cached copy, and a removed record is never re-created.
   */
  async _save(s, patch) {
    const r = await this.soda.findOne(COLLECTION, { sessionId: s.sessionId });
    if (!r) { this.cache.delete(s.sessionId); return null; }
    const cur = r.value;
    if (cur.revokedAt && !patch.revokedAt) { this._put({ ...cur, key: r.key }); return null; }
    const next = { ...cur, ...patch };
    try {
      await this.soda.replace(COLLECTION, r.key, next);
    } catch (e) {
      if (e && e.status === 404) { this.cache.delete(s.sessionId); return null; }
      throw e;
    }
    const stored = { ...next, key: r.key };
    this._put(stored);
    return stored;
  }

  /**
   * The session for a token's sid, checked: exists, belongs to userId, not revoked, not idle, not past a hard
   * absolute limit. Updates lastSeenAt now and then (never awaited by the caller's response path for long).
   * Throws SessionError (401 SESSION_INVALID) otherwise.
   */
  async validate(sessionId, userId, { touch = true, maxAgeMs, swr = false } = {}) {
    const s = await this._read(sessionId, { ...(maxAgeMs ? { maxAgeMs } : {}), swr });
    if (!s || s.userId !== userId) throw new SessionError(MSG_SIGNED_OUT);
    if (s.revokedAt) throw new SessionError(s.revokeReason === 'IDLE' || s.revokeReason === 'EXPIRED' ? MSG_EXPIRED : MSG_SIGNED_OUT);
    const pol = policyOf(s.kind, config, s);
    const t = this.clock();
    if (pol.idleMs && t - (Number(s.lastSeenAt) || 0) > pol.idleMs) {
      this.revoke(s.sessionId, 'IDLE').catch(() => {});
      throw new SessionError(MSG_EXPIRED);
    }
    if (pol.absHard && s.absoluteExpiresAt && t > s.absoluteExpiresAt) {
      this.revoke(s.sessionId, 'EXPIRED').catch(() => {});
      throw new SessionError(MSG_EXPIRED);
    }
    if (touch && t - (Number(s.lastSeenAt) || 0) > pol.touchMs) {
      const cur = { ...s, lastSeenAt: t };
      this._put(cur); // the next check on this node sees the new time at once
      this._save(s, { lastSeenAt: t }).catch((e) => this.log.warn?.(`[sessions] last-seen write failed: ${String(e && e.message).slice(0, 80)}`));
      return cur;
    }
    return s;
  }

  /**
   * Rotates a refresh token. Returns { session, refreshToken }. Throws SessionError: SESSION_INVALID when the
   * token is unknown, revoked, expired or reused (reuse also revokes the session).
   * `isRiding(userId)` may extend an app session past its absolute lifetime (never end a session mid-ride).
   */
  async refresh(rawToken, { kindHint = null, attempt = 0 } = {}) {
    const m = RT_RE.exec(String(rawToken || ''));
    if (!m) throw new SessionError(MSG_SIGNED_OUT);
    const [, sessionId, nStr] = m;
    const n = Number(nStr);
    const s = await this._read(sessionId, { fresh: true });
    if (!s || !s.v2) throw new SessionError(MSG_SIGNED_OUT);
    if (kindHint && s.kind !== kindHint && !(kindHint === 'app' && s.kind === 'app')) throw new SessionError(MSG_SIGNED_OUT);
    if (s.revokedAt) throw new SessionError(MSG_SIGNED_OUT);
    const t = this.clock();
    const h = sha256(rawToken);
    const pol = policyOf(s.kind, config, s);
    let graced = false;
    if (n === s.refreshCounter && safeEq(h, s.refreshHash)) {
      // the current token
    } else if (n === s.prevRefreshCounter && safeEq(h, s.prevRefreshHash) && this._withinGrace(s, t)) {
      // A lost reply or a second tab: rotate again from it, the sibling becomes invalid. v3.62: on a phone this is
      // also the reply lost on a bad mobile network, or a token the phone could not save before it was closed: the
      // previous token is accepted for REFRESH_REUSE_GRACE_APP_SEC (0 = any time) instead of 60 s.
      graced = true;
    } else if (n <= s.refreshCounter) {
      await this.revoke(s.sessionId, 'REFRESH_REUSE');
      this._audit('REFRESH_REUSE', s.userId, s.sessionId);
      this.log.warn?.(`[sessions] refresh token reuse detected: session revoked (user ${s.userId})`);
      throw new SessionError(MSG_SIGNED_OUT);
    } else {
      throw new SessionError(MSG_SIGNED_OUT);
    }
    if (pol.idleMs && t - (Number(s.lastSeenAt) || 0) > pol.idleMs) {
      await this.revoke(s.sessionId, 'IDLE');
      throw new SessionError(MSG_EXPIRED);
    }
    const patch = {};
    // v3.60: an app session made before "no time limit" still carries a date: ignored when the app limit is 0.
    if (s.absoluteExpiresAt && (pol.absMs || pol.absHard) && t > s.absoluteExpiresAt) {
      let riding = false;
      if (!pol.absHard && this.isRiding) { try { riding = await this.isRiding(s.userId); } catch { riding = true; /* unsure: never end a ride */ } }
      if (!riding) {
        await this.revoke(s.sessionId, 'EXPIRED');
        throw new SessionError(MSG_EXPIRED);
      }
      // Never signed out during a ride, SOS or crash alert: 24 more hours, audited.
      patch.absoluteExpiresAt = t + 24 * 3600000;
      this._audit('SESSION_EXTENDED_RIDE', s.userId, s.sessionId);
    }
    const next = this._newRefresh(s.sessionId, s.refreshCounter + 1);
    Object.assign(patch, {
      refreshHash: next.hash, refreshCounter: s.refreshCounter + 1, lastSeenAt: t,
      ...(graced ? {} : { prevRefreshHash: s.refreshHash, prevRefreshCounter: s.refreshCounter, rotatedAt: t, prevLateUses: 0 }),
    });
    // v3.62 security: after the short (60 s) window the previous token is a lost reply on a bad network; it may rotate
    // only a few times (PREV_LATE_MAX), so a stolen old refresh token can no longer mint new tokens forever.
    if (graced && t - (Number(s.rotatedAt) || 0) > config.refreshReuseGraceSec * 1000) patch.prevLateUses = (Number(s.prevLateUses) || 0) + 1;
    // Compare-and-replace: two refreshes racing on the same token never both rotate from the same state; the loser
    // runs again and finds its token as the previous one (graced), so neither client is signed out.
    const raw = { ...s }; delete raw.key;
    const doc = { ...raw, ...patch };
    const ok = await this.soda.compareAndReplace(COLLECTION, s.key, raw, doc);
    if (!ok) {
      if (attempt >= 2) throw new SessionError(MSG_SIGNED_OUT);
      return this.refresh(rawToken, { kindHint, attempt: attempt + 1 });
    }
    const saved = { ...doc, key: s.key };
    this._put(saved);
    return { session: saved, refreshToken: next.token, graced };
  }

  /** v3.62: may the previous refresh token still rotate (lost reply) at time t? */
  _withinGrace(s, t) {
    const since = t - (Number(s.rotatedAt) || 0);
    if (isPhoneKind(s.kind)) {
      if (since <= config.refreshReuseGraceSec * 1000) return true;
      // v3.62 security: a late previous token (lost reply) is accepted a few times only (never an endless replay).
      if ((Number(s.prevLateUses) || 0) >= PREV_LATE_MAX) return false;
      const g = Number(config.refreshReuseGraceAppSec) || 0;
      return g <= 0 || since <= g * 1000;
    }
    return since <= config.refreshReuseGraceSec * 1000;
  }

  /** v3.62: live phone sessions (for the admin page; capped count). */
  async countLiveApp() {
    // v3.62: cached 5 min (the command center polls the admin page every 15 s; a 5000-row scan each time is a load).
    const c = this._liveAppCount;
    if (c && this.clock() - c.at < 5 * 60000) return c.n;
    const rows = await this.soda.query(COLLECTION, { revokedAt: 0 }, { limit: 5000 });
    const n = rows.filter((r) => isPhoneKind(r.value && r.value.kind)).length;
    this._liveAppCount = { n, at: this.clock() };
    return n;
  }

  async get(sessionId) { return this._read(sessionId, { fresh: true }); }

  /** Marks a session as recently re-authenticated (password or Google), for sensitive actions. */
  async markReauth(sessionId) {
    const s = await this._read(sessionId, { fresh: true });
    if (!s || s.revokedAt) return null;
    return this._save(s, { reauthAt: this.clock() });
  }

  async markMfa(sessionId) {
    const s = await this._read(sessionId, { fresh: true });
    if (!s || s.revokedAt) return null;
    return this._save(s, { mfa: true });
  }

  recentlyAuthenticated(s) {
    return !!(s && s.reauthAt && this.clock() - s.reauthAt <= config.reauthWindowMin * 60000);
  }

  async revoke(sessionId, reason = 'SIGNED_OUT', { by = '' } = {}) {
    const s = await this._read(sessionId, { fresh: true }).catch(() => null);
    this.cache.delete(sessionId);
    if (!s || s.revokedAt) return false;
    await this._save(s, { revokedAt: this.clock(), revokeReason: String(reason).slice(0, 40), revokedBy: by || '' });
    this._notify({ sids: [sessionId], userId: s.userId, reason });
    return true;
  }

  /** Revokes every live session of a user (optionally keeping one). Returns the number revoked. */
  async revokeAllForUser(userId, reason = 'SIGNED_OUT_EVERYWHERE', { exceptSid = null, by = '' } = {}) {
    if (!userId) return 0;
    const rows = await this.soda.query(COLLECTION, { userId }, { limit: 1000 });
    const t = this.clock();
    const sids = [];
    for (const r of rows) {
      const s = { ...r.value, key: r.key };
      if (s.revokedAt || s.sessionId === exceptSid) continue;
      await this.soda.replace(COLLECTION, r.key, { ...r.value, revokedAt: t, revokeReason: String(reason).slice(0, 40), revokedBy: by || '' });
      this.cache.delete(s.sessionId);
      sids.push(s.sessionId);
    }
    // Entries not found in the database (just created on this node) are dropped from the cache too.
    for (const [sid, e] of this.cache) if (e.s.userId === userId && sid !== exceptSid) this.cache.delete(sid);
    this._notify({ sids, userId, all: !exceptSid, exceptSid, reason });
    return sids.length;
  }

  /** Erases every session record of a deleted account. */
  async purgeUser(userId) {
    if (!userId) return 0;
    for (const [sid, e] of this.cache) if (e.s.userId === userId) this.cache.delete(sid);
    return this.soda.removeWhere(COLLECTION, { userId });
  }

  /** The live sessions of a user, newest activity first (no hashes). */
  async list(userId) {
    const rows = await this.soda.query(COLLECTION, { userId }, { limit: 500 });
    const t = this.clock();
    return rows.map((r) => r.value)
      .filter((s) => {
        if (s.revokedAt) return false;
        const pol = policyOf(s.kind, config, s);
        if (pol.idleMs && t - (Number(s.lastSeenAt) || 0) > pol.idleMs) return false;
        return !(pol.absHard && s.absoluteExpiresAt && t > s.absoluteExpiresAt);
      })
      .sort((a, b) => (b.lastSeenAt || 0) - (a.lastSeenAt || 0))
      .map((s) => ({
        sessionId: s.sessionId, kind: s.kind, deviceLabel: s.deviceLabel, platform: s.platform, uaSummary: s.uaSummary,
        createdAt: s.createdAt, lastSeenAt: s.lastSeenAt, mfa: !!s.mfa,
      }));
  }

  /** Drops this node's cached copies (the peer revoked them; the database is the truth). */
  invalidateLocal({ sids = [], userId = null, exceptSid = null } = {}) {
    for (const sid of sids || []) this.cache.delete(sid);
    if (userId) for (const [sid, e] of this.cache) if (e.s.userId === userId && sid !== exceptSid) this.cache.delete(sid);
  }

  _notify(ev) {
    try { if (this.onRevoke) this.onRevoke(ev); } catch (e) { this.log.warn?.(`[sessions] revoke hook failed: ${e.message}`); }
  }

  _audit(detail, userId, sessionId) {
    try { if (this.audit) this.audit.add({ kind: 'AUTH', subjectId: userId, detail: `${detail}` }); } catch { /* never in the way */ }
    void sessionId;
  }

  /**
   * Removes ended session records 30 days after they ended (audit trail). v3.62: only records that really ended:
   * revoked, or past their own idle / hard absolute limit. A live phone session is never removed, however long the
   * phone was not used (before v3.62 a phone unused for 30 days lost its session here and was signed out). Leased.
   */
  async sweep({ now = this.clock() } = {}) {
    const cutoff = now - 30 * 86400000;
    let removed = 0;
    let after = 0;
    for (let page = 0; page < 50; page++) {
      const rows = await this.soda.query(COLLECTION, { lastSeenAt: { $lt: cutoff } }, { limit: 200, offset: after, orderBy: [{ path: 'lastSeenAt', datatype: 'number', order: 'asc' }] });
      if (!rows.length) break;
      let kept = 0;
      for (const r of rows) {
        const s = r.value || {};
        if (this._ended(s, cutoff)) { await this.soda.remove(COLLECTION, r.key); removed++; } else kept++;
      }
      after += kept;
      if (rows.length < 200) break;
    }
    return removed;
  }

  /** True when the record ended more than 30 days before `now` (cutoff = now - 30 days). */
  _ended(s, cutoff) {
    if (s.revokedAt) return Number(s.revokedAt) < cutoff;
    const pol = policyOf(s.kind, config, s);
    const seen = Number(s.lastSeenAt) || 0;
    if (pol.idleMs && seen + pol.idleMs < cutoff) return true;
    if (pol.absHard && s.absoluteExpiresAt && Number(s.absoluteExpiresAt) < cutoff) return true;
    return false;
  }

  // ---- mirror extension 'ss': revocations made on the peer node ----
  exportState() { return {}; }
  importState() { /* nothing to import: sessions live in the database */ }
  applyRemote(op) {
    if (!op || op.op !== 'REVOKE') return;
    const sids = Array.isArray(op.sids) ? op.sids.filter((x) => SID_RE.test(String(x))).slice(0, 1000) : [];
    const userId = typeof op.userId === 'string' ? op.userId.slice(0, 120) : null;
    this.invalidateLocal({ sids, userId: op.all ? userId : null, exceptSid: op.exceptSid || null });
    if (this.onRemoteRevoke) { try { this.onRemoteRevoke({ sids, userId, all: !!op.all, exceptSid: op.exceptSid || null }); } catch { /* sockets catch up on their next message */ } }
  }
}

module.exports = { SessionStore, SessionError, policyOf, isPhoneKind, PREV_LATE_MAX, uaSummary, COLLECTION, SID_RE, RT_RE, MSG_SIGNED_OUT, MSG_EXPIRED, sha256 };
