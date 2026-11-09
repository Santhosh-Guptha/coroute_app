'use strict';
/**
 * 3.55 push notifications: Firebase Cloud Messaging (HTTP v1) to the Android app, so friend
 * requests, crew invites, polls and ride invites reach a phone whose app is closed
 * (docs/features_355/push_notifications.md).
 *
 * HOW TO SEND A PUSH (contract for other modules):
 *
 *   // app.js creates ONE PushService per gateway and attaches it to:
 *   //   hub.push, convoys.push and app.locals.push   (also returned by createApp as `push`)
 *   const push = convoys.push || hub.push;            // may be null in old tests: always guard
 *   if (push) push.notifyUsers([userId1, userId2], {
 *     type: 'RIDE_INVITE',                 // A-Z and _ only; the app routes on it
 *     title: 'Ride invitation',                // short, shown as the notification title
 *     body: 'SwiftFalcon482 invited you to a ride',   // usernames only, never phone/e-mail/medical/location
 *     data: { inviteId: 'ri_...' },        // ids only; strings (numbers/booleans are stringified)
 *     ttlSec: 1800,                        // optional (defaults by type)
 *     priority: 'high',                    // optional: 'high' | 'normal' (default by type)
 *     skipConnected: false,                // optional: true = skip riders with a live socket
 *   });
 *   // -> Promise<{ sent, skipped, failed, disabled? }>. NEVER throws, never blocks the caller for
 *   //    long (call it without await on hot paths).
 *
 * Event hook used by social_routes.js / crew_routes.js: push.onSocketEvent(userId, payload, {delivered})
 * after hub.sendToUser(); FRIEND_REQUEST / FRIEND_ACCEPTED / CREW_INVITE / POLL_CREATED are pushed
 * only when no socket received them (a live app already showed it): neither a socket of this gateway
 * nor one on the peer node of the two-node mirror (mirror.userOnPeer, from the peer's LU list; the
 * hub forwards the socket message there). RIDE_INVITE always pushes. `skipConnected` checks both
 * nodes too.
 *
 * Dedupe (app safety net): stampEvent(payload) gives every notice a stable `eventId`
 * (TYPE:requestId / inviteId / pollId); callers stamp the payload BEFORE hub.sendToUser so the socket
 * message and the push data carry the same id, and the app shows one notice per eventId in 10 min.
 *
 * Configuration (env, never in code):
 *   FCM_SERVICE_ACCOUNT_JSON   the service account key JSON (or FCM_SERVICE_ACCOUNT_FILE = its path)
 *   FCM_PROJECT_ID             Firebase project id (defaults to the key's project_id)
 * Without them the service is DISABLED: every call is a no-op (logged once); tokens are still stored.
 * Admin switch `pushNotifications` (feature_flags.js) turns sending off for everyone.
 *
 * Storage: collection push_tokens { userId, token, platform, appVersion, updatedAt }, unique token,
 * at most 5 tokens per rider (oldest dropped). Tokens go with the account on erase and are pruned
 * when FCM answers UNREGISTERED / INVALID_ARGUMENT for them.
 *
 * Privacy: data-only messages; data is filtered (no key that names a phone, e-mail, medical,
 * location or user id field, no value that looks like an e-mail or phone number), short strings.
 */
const fs = require('fs');
const rateLimit = require('express-rate-limit');

const COLLECTION = 'push_tokens';
const MAX_TOKENS_PER_USER = 5;
const TOKEN_RE = /^[A-Za-z0-9:_\-.]{20,4096}$/;
const APP_VERSION_RE = /^[A-Za-z0-9.+_\-]{0,32}$/;
const TYPE_RE = /^[A-Z][A-Z_]{2,31}$/;
const PLATFORMS = new Set(['android']);
// Outbound allowlist (same pattern as guardian_push.js HOSTS): the sender only talks to FCM.
const HOSTS = new Set(['fcm.googleapis.com']);
const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

const MIN = 60;
const DEFAULTS = Object.freeze({
  RIDE_INVITE: { ttlSec: 30 * MIN, priority: 'high' },
  FRIEND_REQUEST: { ttlSec: 3 * 24 * 3600, priority: 'normal' },
  FRIEND_ACCEPTED: { ttlSec: 3 * 24 * 3600, priority: 'normal' },
  CREW_INVITE: { ttlSec: 3 * 24 * 3600, priority: 'normal' },
  POLL_CREATED: { ttlSec: 24 * 3600, priority: 'normal' },
});
const FALLBACK = { ttlSec: 24 * 3600, priority: 'normal' };
/** Socket events that become pushes (title + body from the event; ids only in data). */
const SOCKET_EVENTS = Object.freeze({
  FRIEND_REQUEST: (p) => ({ title: 'Friend request', body: `${p.username || 'A rider'} sent you a friend request`, data: { requestId: p.requestId } }),
  FRIEND_ACCEPTED: (p) => ({ title: 'New friend', body: `${p.username || 'A rider'} accepted your friend request`, data: {}, collapse: 'friends' }),
  CREW_INVITE: (p) => ({ title: 'Crew invite', body: `${p.username || 'A rider'} invited you to the crew ${p.crewName || ''}`.trim(), data: { inviteId: p.inviteId, crewId: p.crewId }, collapse: `crew_${p.crewId || ''}` }),
  POLL_CREATED: (p) => ({ title: p.crewName ? `New poll in ${p.crewName}` : 'New crew poll', body: p.question ? `${p.username || 'A rider'} asks: ${p.question}` : `${p.username || 'A rider'} started a poll`, data: { crewId: p.crewId, pollId: p.pollId } }),
  RIDE_INVITE: (p) => ({ title: 'Ride invitation', body: `${p.username || 'A rider'} invited you to a ride${p.rideName ? `: ${p.rideName}` : ''}`, data: { inviteId: p.inviteId, groupId: p.groupId }, collapse: `ride_${p.inviteId || ''}`, always: true }),
});

// Words (camelCase / snake_case parts of a data key) that never travel in a push.
const SENSITIVE_WORDS = new Set(['phone', 'mobile', 'tel', 'email', 'mail', 'medical', 'blood', 'allergy', 'allergies', 'condition', 'conditions',
  'lat', 'lng', 'lon', 'latitude', 'longitude', 'location', 'coords', 'coord', 'address', 'home', 'position', 'pos', 'user', 'userid', 'uid',
  'password', 'secret', 'token', 'contact', 'contacts', 'guardian', 'payment', 'card', 'firstname', 'lastname', 'dob', 'birth']);
const wordsOf = (k) => k.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(/[\s_]+/).filter(Boolean);
const isSensitiveKey = (k) => SENSITIVE_WORDS.has(k.toLowerCase()) || wordsOf(k).some((w) => SENSITIVE_WORDS.has(w));
const ID_KEY = /Id$/;
const ID_VALUE = /^[A-Za-z0-9_\-:.]{1,80}$/;
const EMAIL_VALUE = /[^\s@]+@[^\s@]+\.[^\s@]+/;
const PHONE_VALUE = /(?:\+?\d[\s-]?){9,}/;
const clip = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
const cleanText = (v, n) => clip(String(v == null ? '' : v).replace(/[\u0000-\u001f\u007f]+/g, ' ').trim(), n);

const EVENT_REF_KEYS = ['requestId', 'inviteId', 'pollId'];
let eventSeq = 0;
/**
 * Gives a notice payload a stable `eventId` (kept when already set): `TYPE:<requestId|inviteId|pollId>`,
 * or `TYPE:<time><seq>` when it has no such id. Mutates and returns the payload. Call it before
 * hub.sendToUser so the socket message and the push carry the same id (app dedupe, 10 minutes).
 */
function stampEvent(payload) {
  if (!payload || typeof payload !== 'object') return payload;
  if (typeof payload.eventId === 'string' && /^[A-Za-z0-9_\-:.]{1,80}$/.test(payload.eventId)) return payload;
  const type = String(payload.type || 'EVENT').replace(/[^A-Z_]/g, '').slice(0, 31) || 'EVENT';
  const refKey = EVENT_REF_KEYS.find((k) => typeof payload[k] === 'string' && /^[A-Za-z0-9_\-.]{1,40}$/.test(payload[k]));
  const ref = refKey ? payload[refKey] : `${Date.now().toString(36)}${(eventSeq = (eventSeq + 1) % 1e6).toString(36)}`;
  payload.eventId = `${type}:${ref}`.slice(0, 80);
  return payload;
}

/** Data-only payload with nothing sensitive: string values, short, at most 10 keys. */
function safeData(data) {
  const out = {};
  if (!data || typeof data !== 'object' || Array.isArray(data)) return out;
  for (const [k, raw] of Object.entries(data)) {
    if (Object.keys(out).length >= 10) break;
    if (!/^[A-Za-z][A-Za-z0-9_]{0,31}$/.test(k) || isSensitiveKey(k)) continue;
    if (['type', 'title', 'body', 'from', 'notification', 'message_type'].includes(k) || k.startsWith('google') || k.startsWith('gcm')) continue;
    if (raw == null || typeof raw === 'object') continue;
    const v = cleanText(raw, 120);
    if (!v) continue;
    if (ID_KEY.test(k)) { if (!ID_VALUE.test(v)) continue; } // ids: plain id characters only
    else if (EMAIL_VALUE.test(v) || PHONE_VALUE.test(v)) continue;
    out[k] = v;
  }
  return out;
}
/** Visible text: no e-mail addresses or phone numbers even if a caller passed one by mistake. */
function safeText(v, n) {
  return cleanText(v, n).replace(new RegExp(EMAIL_VALUE.source, 'g'), '').replace(new RegExp(PHONE_VALUE.source, 'g'), '').replace(/\s{2,}/g, ' ').trim();
}

/** The FCM HTTP v1 message for one token. */
function buildMessage(token, { type, title, body, data, ttlSec, priority, collapseKey }) {
  const d = DEFAULTS[type] || FALLBACK;
  const ttl = Math.max(0, Math.min(28 * 24 * 3600, Math.round(Number(ttlSec) || d.ttlSec)));
  const prio = (priority || d.priority) === 'high' ? 'HIGH' : 'NORMAL';
  const clean = safeData(data);
  // Default collapse key: one per thing (a stored offline message is replaced only by a newer one
  // about the same invite / request / poll), never one per type across different things.
  const ref = clean.inviteId || clean.requestId || clean.pollId || clean.crewId || clean.groupId || '';
  const collapse = cleanText(collapseKey || (ref ? `${type}_${ref}` : type), 60) || type;
  return {
    message: {
      token,
      data: { ...clean, type, title: safeText(title || 'CoRoute', 80) || 'CoRoute', body: safeText(body || '', 200) },
      android: { priority: prio, ttl: `${ttl}s`, collapse_key: collapse },
    },
  };
}

/** Error code of a failed FCM response ('UNREGISTERED', 'INVALID_ARGUMENT', 'QUOTA_EXCEEDED', ...). */
function fcmErrorCode(status, body) {
  const err = body && body.error;
  const details = (err && Array.isArray(err.details) ? err.details : []).map((x) => x && x.errorCode).filter(Boolean);
  if (details.length) return details[0];
  if (err && err.status) return err.status === 'NOT_FOUND' ? 'UNREGISTERED' : err.status;
  return status === 404 ? 'UNREGISTERED' : `HTTP_${status}`;
}

/** Service account from env: { credentials, projectId } or null (push disabled). */
function serviceAccountFromEnv(env = process.env, logger = console) {
  let raw = env.FCM_SERVICE_ACCOUNT_JSON;
  if ((!raw || !raw.trim()) && env.FCM_SERVICE_ACCOUNT_FILE) {
    try { raw = fs.readFileSync(env.FCM_SERVICE_ACCOUNT_FILE, 'utf8'); } catch (e) { logger.warn?.(`[push] FCM_SERVICE_ACCOUNT_FILE could not be read: ${e.code || e.message}`); return null; }
  }
  if (!raw || !raw.trim()) return null;
  let creds;
  try { creds = JSON.parse(raw); } catch { logger.warn?.('[push] FCM service account JSON is not valid JSON'); return null; }
  const projectId = (env.FCM_PROJECT_ID || creds.project_id || '').trim();
  if (!creds.client_email || !creds.private_key || !projectId) { logger.warn?.('[push] FCM service account is incomplete (client_email, private_key, project id)'); return null; }
  return { credentials: creds, projectId };
}

/**
 * Real transport: one POST to FCM v1 per token, OAuth token from google-auth-library (cached by it).
 * Returns { status, body }; never throws for HTTP errors (network errors throw -> retried).
 */
function fcmTransport({ credentials, projectId, fetchImpl = globalThis.fetch }) {
  const { JWT } = require('google-auth-library');
  const client = new JWT({ email: credentials.client_email, key: credentials.private_key, scopes: [FCM_SCOPE] });
  const url = new URL(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`);
  if (url.protocol !== 'https:' || !HOSTS.has(url.hostname)) throw new Error('FCM host is not allowed');
  return async (message) => {
    const { token } = await client.getAccessToken();
    const res = await fetchImpl(url.href, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify(message), redirect: 'error', signal: AbortSignal.timeout(10000),
    });
    let body = null;
    try { body = await res.json(); } catch { body = null; }
    return { status: res.status, body, retryAfter: res.headers && res.headers.get ? res.headers.get('retry-after') : null };
  };
}

class PushService {
  /**
   * @param {object} o
   * @param {object} o.soda       SODA client (push_tokens)
   * @param {object} [o.hub]      ws Hub (only for the "connected" check of onSocketEvent callers)
   * @param {Function} [o.flagsOf] () => FeatureFlags (switch `pushNotifications`)
   * @param {Function|null} [o.transport] async (fcmMessage) => {status, body}; undefined = from env
   */
  constructor({ soda, hub = null, flagsOf = () => null, logger = console, transport, env = process.env, sleep, clock = Date.now,
    perUserLimit = 30, perUserWindowMs = 10 * 60000, retries = 3 } = {}) {
    this.soda = soda; this.hub = hub; this.flagsOf = flagsOf; this.logger = logger; this.clock = clock;
    this.sleep = sleep || ((ms) => new Promise((r) => { const t = setTimeout(r, ms); t.unref?.(); }));
    this.perUserLimit = perUserLimit; this.perUserWindowMs = perUserWindowMs; this.retries = retries;
    this.sentAt = new Map(); // userId -> [timestamps] (per-user throttle, memory only)
    this.ready = null;
    this.warned = false;
    if (transport !== undefined) this.transport = transport;
    else {
      const sa = serviceAccountFromEnv(env, logger);
      try { this.transport = sa ? fcmTransport(sa) : null; } catch (e) { logger.warn?.(`[push] FCM sender not created: ${e.message}`); this.transport = null; }
    }
  }

  get enabled() { return !!this.transport; }

  async ensureStore() {
    if (!this.ready) {
      this.ready = (async () => {
        await this.soda.ensureCollection(COLLECTION);
        const idx = (name, fields, unique = false) => this.soda.ensureIndex(COLLECTION, { name, unique, fields: fields.map((path) => ({ path })) });
        await idx('push_tokens_token_ux', ['token'], true);
        await idx('push_tokens_user_ix', ['userId']);
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  // ------------------------------------------------------------ registry
  /** Stores (or moves) a token for the rider; keeps the newest 5. Throws {status:400} on bad input. */
  async registerToken(userId, { token, platform = 'android', appVersion = '' } = {}) {
    if (typeof token !== 'string' || !TOKEN_RE.test(token)) throw Object.assign(new Error('Invalid push token.'), { status: 400, code: 'BAD_TOKEN' });
    if (typeof platform !== 'string' || !PLATFORMS.has(platform)) throw Object.assign(new Error('Unsupported platform.'), { status: 400, code: 'BAD_PLATFORM' });
    const ver = appVersion == null ? '' : String(appVersion);
    if (!APP_VERSION_RE.test(ver)) throw Object.assign(new Error('Invalid app version.'), { status: 400, code: 'BAD_VERSION' });
    await this.ensureStore();
    const doc = { userId, token, platform, appVersion: ver, updatedAt: this.clock() };
    await this.soda.upsertBy(COLLECTION, { token }, doc);
    const mine = (await this.soda.query(COLLECTION, { userId }, { limit: 100 })).sort((a, b) => (b.value.updatedAt || 0) - (a.value.updatedAt || 0));
    for (const old of mine.slice(MAX_TOKENS_PER_USER)) await this.soda.remove(COLLECTION, old.key).catch(() => {});
    return { ok: true, tokens: Math.min(mine.length, MAX_TOKENS_PER_USER) };
  }

  /** Removes one token of the rider (or all of them when token is empty). */
  async unregisterToken(userId, token) {
    await this.ensureStore();
    if (token == null || token === '') return { removed: await this.forgetUser(userId) };
    if (typeof token !== 'string' || !TOKEN_RE.test(token)) throw Object.assign(new Error('Invalid push token.'), { status: 400, code: 'BAD_TOKEN' });
    const row = await this.soda.findOne(COLLECTION, { token });
    if (!row || row.value.userId !== userId) return { removed: 0 };
    await this.soda.remove(COLLECTION, row.key);
    return { removed: 1 };
  }

  async tokensOf(userId) {
    await this.ensureStore();
    return (await this.soda.query(COLLECTION, { userId }, { limit: 100 })).map((r) => r.value);
  }

  async forgetUser(userId) {
    await this.ensureStore();
    const rows = await this.soda.query(COLLECTION, { userId }, { limit: 100 });
    for (const r of rows) await this.soda.remove(COLLECTION, r.key).catch(() => {});
    return rows.length;
  }

  async pruneToken(token) {
    try {
      await this.ensureStore();
      const row = await this.soda.findOne(COLLECTION, { token });
      if (row) await this.soda.remove(COLLECTION, row.key);
    } catch { /* next send tries again */ }
  }

  // ------------------------------------------------------------ sending
  /** Per-user throttle (memory, per node): true when this user may get one more push now. */
  _allow(userId) {
    const now = this.clock();
    const list = (this.sentAt.get(userId) || []).filter((t) => now - t < this.perUserWindowMs);
    if (list.length >= this.perUserLimit) { this.sentAt.set(userId, list); return false; }
    list.push(now);
    this.sentAt.set(userId, list);
    if (this.sentAt.size > 20000) this.sentAt.delete(this.sentAt.keys().next().value);
    return true;
  }

  _connected(userId) {
    const set = this.hub && this.hub.byUser && this.hub.byUser.get(userId);
    if (set) for (const ws of set) if (ws.allowed && ws.readyState === 1) return true;
    return this._onPeer(userId);
  }

  /** The rider has an open socket on the OTHER node of the two-node mirror (cheap: the peer's LU set). */
  _onPeer(userId) {
    const m = this.hub && this.hub.mirror;
    try { return !!(m && typeof m.userOnPeer === 'function' && m.userOnPeer(userId)); } catch { return false; }
  }

  /** One message with retries on 429 / 5xx / network errors. Returns 'sent' | 'pruned' | 'failed'. */
  async _sendOne(message) {
    for (let attempt = 0; attempt <= this.retries; attempt++) {
      let res;
      try { res = await this.transport(message); } catch (e) {
        if (attempt === this.retries) { this.logger.warn?.(`[push] send failed: ${e.code || e.message}`); return 'failed'; }
        await this.sleep(Math.min(30000, 1000 * 2 ** attempt));
        continue;
      }
      const status = res && res.status;
      if (status >= 200 && status < 300) return 'sent';
      const code = fcmErrorCode(status, res && res.body);
      if (code === 'UNREGISTERED' || code === 'INVALID_ARGUMENT' || code === 'SENDER_ID_MISMATCH') {
        await this.pruneToken(message.message.token);
        return 'pruned';
      }
      if ((status === 429 || status >= 500) && attempt < this.retries) {
        const ra = Number(res && res.retryAfter);
        await this.sleep(Math.min(30000, Number.isFinite(ra) && ra > 0 ? ra * 1000 : 1000 * 2 ** attempt));
        continue;
      }
      this.logger.warn?.(`[push] FCM refused a message: ${code}`);
      return 'failed';
    }
    return 'failed';
  }

  /** See the header. Never throws. */
  async notifyUsers(userIds, opts = {}) {
    const out = { sent: 0, skipped: 0, failed: 0 };
    try {
      const ids = [...new Set((Array.isArray(userIds) ? userIds : [userIds]).filter((x) => typeof x === 'string' && x))].slice(0, 500);
      if (!ids.length) return out;
      const type = String(opts.type || '');
      if (!TYPE_RE.test(type)) { out.skipped = ids.length; return out; }
      const fl = this.flagsOf && this.flagsOf();
      if (fl && typeof fl.isOn === 'function' && !fl.isOn('pushNotifications')) { out.skipped = ids.length; out.disabled = 'switch'; return out; }
      if (!this.transport) {
        if (!this.warned) { this.warned = true; this.logger.info?.('[push] FCM is not configured (FCM_SERVICE_ACCOUNT_JSON / FCM_PROJECT_ID): push notifications are off'); }
        out.skipped = ids.length; out.disabled = 'unconfigured';
        return out;
      }
      for (const uid of ids) {
        if (opts.skipConnected && this._connected(uid)) { out.skipped++; continue; }
        const tokens = await this.tokensOf(uid);
        if (!tokens.length) { out.skipped++; continue; }
        if (!this._allow(uid)) { out.skipped++; continue; }
        for (const t of tokens) {
          const r = await this._sendOne(buildMessage(t.token, { ...opts, type }));
          if (r === 'sent') out.sent++; else out.failed++;
        }
      }
    } catch (e) {
      this.logger.warn?.(`[push] notifyUsers failed: ${e.message}`);
    }
    return out;
  }

  /**
   * Hook after hub.sendToUser(userId, payload): pushes the known social events. `delivered` = how many
   * live sockets got it; such events are not pushed again (RIDE_INVITE always is). Fire and forget.
   */
  onSocketEvent(userId, payload, { delivered = 0 } = {}) {
    const make = payload && SOCKET_EVENTS[payload.type];
    if (!make || !userId) return Promise.resolve(null);
    const m = make(payload);
    // Shown by a socket here, or by one on the peer node (the hub forwarded it there): no push.
    if (!m.always && (delivered > 0 || this._onPeer(userId))) return Promise.resolve(null);
    const eventId = stampEvent(payload).eventId;
    return this.notifyUsers([userId], { type: payload.type, title: m.title, body: m.body, data: { ...m.data, eventId }, collapseKey: m.collapse, skipConnected: false });
  }
}

/** POST / DELETE /me/push-tokens on the authenticated router. */
function registerPushRoutes({ r, push, wrap }) {
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 10, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => req.user?.userId || req.ip, message: { error: 'Too many requests. Wait a minute.', code: 'RATE_LIMITED' } });
  const fail = (res, e) => {
    if (e && e.status === 400) return res.status(400).json({ error: e.message, code: e.code });
    throw e;
  };
  r.post('/me/push-tokens', limiter, wrap(async (req, res) => {
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    try {
      const out = await push.registerToken(req.user.userId, { token: b.token, platform: b.platform || 'android', appVersion: b.appVersion || '' });
      res.set('Cache-Control', 'no-store').json({ ok: true, tokens: out.tokens, enabled: push.enabled });
    } catch (e) { fail(res, e); }
  }));
  r.delete('/me/push-tokens', limiter, wrap(async (req, res) => {
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    const token = typeof b.token === 'string' ? b.token : (typeof req.query.token === 'string' ? req.query.token : '');
    try {
      const out = await push.unregisterToken(req.user.userId, token);
      res.set('Cache-Control', 'no-store').json({ ok: true, removed: out.removed });
    } catch (e) { fail(res, e); }
  }));
}

/** Creates the service, attaches it (hub.push, convoys.push, app.locals.push) and the erase cleanup. */
function attachPush({ app = null, repo, hub = null, convoys = null, featureFlags = null, logger = console, transport } = {}) {
  const push = new PushService({ soda: repo.soda, hub, flagsOf: () => featureFlags, logger, ...(transport !== undefined ? { transport } : {}) });
  if (hub) hub.push = push;
  if (convoys) convoys.push = push;
  if (app && app.locals) app.locals.push = push;
  if (!repo.__pushCascade) {
    repo.__pushCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await push.forgetUser(user.userId).catch(() => {});
      return out;
    };
  }
  if (!push.enabled) logger.info?.('[push] FCM not configured: push notifications are disabled (tokens are still stored)');
  return push;
}

module.exports = { PushService, attachPush, registerPushRoutes, buildMessage, safeData, stampEvent, fcmErrorCode, serviceAccountFromEnv, COLLECTION, MAX_TOKENS_PER_USER, SOCKET_EVENTS, HOSTS };
