'use strict';
/**
 * Round 4 ride lock (owner rule: "restrict the user to login in another device if current device is in a active
 * ride"). docs/features_355/sessions_and_security.md §9.
 *
 * Which session rides. A session is marked riding (`auth_sessions.ride = { groupId, since }`) when its device joins
 * a live ride: REST POST /convoys or /convoys/join with that session, or a socket of that session JOINs a room of a
 * live ride (solo and group rides are both rooms). While it rides, the hub writes `rideSeenAt` at most every
 * RIDE_LOCK_TOUCH (2 min) on socket traffic; HTTP calls keep `lastSeenAt` fresh. The records live in the database
 * both gateway nodes share, so the sign-in node (the web node) sees the same lock as the live node: nothing extra
 * has to replicate. Ride state is read from this node's room when it is loaded here, else from the database
 * (convoy status + membership, open alerts).
 *
 * The lock is ACTIVE when a live, not revoked session of the account
 *   - is marked riding in a ride that is still on (PLANNING / STARTED / PAUSED, the rider still a member), or the
 *     rider has an SOS / crash alert still open in it, and
 *   - was seen (HTTP or socket) within RIDE_LOCK_STALE_MIN (10) minutes.
 * A ride that ended unlocks at once; a phone that went silent unlocks after the stale window.
 *
 * While ACTIVE:
 *   - a sign-in on another device (password, Google, 2-step step, website, /account, admin, operator) answers 423
 *     RIDE_ACTIVE_ELSEWHERE, AFTER the password / Google check (the lock never tells that an account exists). The
 *     answer names the riding device only by its label, never the ride or a place, and carries a short `lockToken`
 *     for the e-mail code override;
 *   - the same device signing in again is allowed: same device id or install id (keyed hashes), e.g. after a crash,
 *     an app kill or a reinstall;
 *   - other sessions signed in before stay signed in but cannot start or join a ride (409 RIDE_ACTIVE_ELSEWHERE).
 *
 * Override ("Use e-mail code"): a 6-digit code (src/email_codes.js, 10 min, 5 tries, rate limited) goes to the account
 * address. The right code signs the new device in, marks the old device's ride handed over (the group sees
 * "<rider> switched phones"; an open SOS is never touched), then revokes the old session (its socket drops to
 * safety-only mode until the ride ends, src/ws.js) and e-mails a "Signed in during a ride" notice. Blocks,
 * overrides and the admin "End ride lock" are audited (safety_audit kind AUTH).
 */
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const config = require('./config');
const { AuthError } = require('./auth');

const COLLECTION = 'auth_sessions';
const ACTIVE = new Set(['PLANNING', 'STARTED', 'PAUSED']);
const CODE = 'RIDE_ACTIVE_ELSEWHERE';

const label = (s) => {
  const v = String((s && s.deviceLabel) || '').replace(/[\u0000-\u001f\u007f<>]/g, '').trim().slice(0, 60);
  return v && !/^Unknown device$/i.test(v) ? v : 'another phone';
};

class RideLock {
  /**
   * @param {{sessions: import('./sessions').SessionStore, repo: any, convoys: any, audit?: any, codes?: any, logger?: object, clock?: () => number}} o
   */
  constructor({ sessions, repo, convoys, audit = null, codes = null, logger = console, clock = () => Date.now() }) {
    this.sessions = sessions; this.repo = repo; this.convoys = convoys; this.audit = audit; this.log = logger; this.clock = clock;
    this.codes = codes || new (require('./email_codes').EmailCodes)({ repo, clock });
    this.touched = new Map(); // sid -> last rideSeenAt write on this node
    this.touchMs = Math.min(120000, Math.max(5000, Math.floor(config.rideLockStaleMin * 60000 / 4)));
    /** (op) => void: set by app.js, sends a handover to the peer node (mirror extension 'rl'). */
    this.toPeer = null;
    /** (mail) => Promise, set by security routes: sendTemplate. */
    this.mail = null;
  }

  get enabled() { return config.rideLockEnabled; }
  get staleMs() { return config.rideLockStaleMin * 60000; }

  _audit(detail, userId) {
    try { if (this.audit) this.audit.add({ kind: 'AUTH', subjectId: userId, detail }); } catch { /* audit only */ }
  }

  // ------------------------------------------------------------------ marking
  /**
   * Marks a session's device as riding in `groupId` (and refreshes its heartbeat). Throttled per session on this node
   * unless `force` (a new ride or join). Never throws.
   */
  async noteRide(sid, userId, groupId, { force = false } = {}) {
    if (!sid || !groupId || !this.enabled) return;
    const t = this.clock();
    const last = this.touched.get(sid) || 0;
    if (!force && t - last < this.touchMs) return;
    this.touched.set(sid, t);
    if (this.touched.size > 20000) this.touched.delete(this.touched.keys().next().value);
    try {
      const s = await this.sessions.get(sid);
      if (!s || s.revokedAt || (userId && s.userId !== userId)) return;
      if (s.kind === 'web' || s.kind === 'admin' || s.kind === 'operator') return; // a website never rides
      // An admin ended this lock for this ride: the ride goes on, the lock does not come back for it.
      if (s.rideLockReleased && s.rideLockReleased === groupId) return;
      const same = s.ride && s.ride.groupId === groupId;
      await this.sessions._save(s, { ride: same ? s.ride : { groupId: String(groupId).slice(0, 64), since: t }, rideSeenAt: t, ...(same ? {} : { rideLockReleased: '' }) });
    } catch (e) {
      this.touched.delete(sid);
      this.log.warn?.(`[ride-lock] mark failed: ${String(e && e.message).slice(0, 80)}`);
    }
  }

  // ------------------------------------------------------------------ state
  /** True while the rider is in this ride (still on, still a member) or has an alert still open in it. */
  async rideLive(userId, groupId) {
    const room = this.convoys && this.convoys.rooms ? this.convoys.rooms.get(groupId) : null;
    if (room) {
      if (ACTIVE.has(room.meta && room.meta.tripStatus) && room.riders && room.riders.has(userId)) return true;
      for (const a of (room.alerts && room.alerts.values ? room.alerts.values() : [])) if (a && !a.resolved && a.userId === userId) return true;
      return false;
    }
    const meta = await this.repo.getConvoyMeta(groupId);
    if (meta && ACTIVE.has(meta.tripStatus)) {
      const m = meta.members && meta.members[userId];
      if (m && !(Number(m.leftAt) > Number(m.joinedAt || 0))) return true;
    }
    const open = await this.repo.soda.findOne('alerts', { groupId, userId, resolved: false }).catch(() => null);
    return !!open;
  }

  /** Same device: the session's device id or install id (keyed hashes) matches. */
  static sameDevice(s, keys) {
    if (!s || !keys) return false;
    return !!((keys.deviceKey && s.deviceKey && keys.deviceKey === s.deviceKey) || (keys.installKey && s.installKey && keys.installKey === s.installKey));
  }

  keysOf(device = {}) {
    return { deviceKey: this.sessions.deviceKey(device && device.id, 'dev'), installKey: this.sessions.deviceKey(device && device.installId, 'inst') };
  }

  /**
   * The active lock of an account: { session, groupId, since } for the riding session, or null. A session whose ride
   * is over is unmarked on the way (lazily; the next sign-in does not read it again).
   */
  async active(userId) {
    if (!this.enabled || !userId) return null;
    const rows = await this.repo.soda.query(COLLECTION, { userId }, { limit: 500 });
    const t = this.clock();
    let best = null;
    for (const r of rows) {
      const s = { ...r.value, key: r.key };
      if (!s.ride || !s.ride.groupId || s.revokedAt) continue;
      if (s.rideLockReleased && s.rideLockReleased === s.ride.groupId) continue;
      const seen = Math.max(Number(s.lastSeenAt) || 0, Number(s.rideSeenAt) || 0);
      if (t - seen > this.staleMs) continue; // the phone went silent: unlocked
      let live;
      try { live = await this.rideLive(userId, s.ride.groupId); } catch { live = true; /* unsure: keep the lock (fail safe) */ }
      if (!live) {
        this.sessions._save(s, { ride: null }).catch(() => {});
        continue;
      }
      if (!best || seen > best.seen) best = { session: s, groupId: s.ride.groupId, since: Number(s.ride.since) || 0, seen };
    }
    return best;
  }

  /** The 423 error for a sign-in blocked by `lock` (message, device label, override token). */
  _blocked(user, lock, ctx, { mfa = false } = {}) {
    const dev = label(lock.session);
    const e = new AuthError(`You're on a ride on ${dev}. End the ride on that phone to sign in here.`, 423, CODE);
    e.extra = { device: dev, lockToken: this.issueToken(user, ctx, { mfa }), codeLength: 6 };
    return e;
  }

  /**
   * Sign-in check, AFTER the credentials were verified. Throws the 423 for another device during an active ride.
   * ctx: the sign-in context (security_routes.ctxOf): client, v2, device { id, installId, label, platform }.
   */
  async checkSignIn(user, ctx = {}, { mfa = false } = {}) {
    if (!this.enabled) return;
    const lock = await this.active(user.userId);
    if (!lock) return;
    if (RideLock.sameDevice(lock.session, this.keysOf(ctx.device))) return;
    this._audit(`RIDE_LOCK_BLOCK ${String(ctx.client || 'app').slice(0, 10)}`, user.userId);
    throw this._blocked(user, lock, ctx, { mfa });
  }

  /**
   * Refresh: a session created AFTER the ride began that never passed a ride lock check (a pre-round-4 session) on
   * another device may not mint new tokens during the ride. Sessions signed in before stay signed in.
   */
  async checkRefresh(session, user) {
    if (!this.enabled || !session || session.lockChecked) return;
    const lock = await this.active(session.userId);
    if (!lock || lock.session.sessionId === session.sessionId) return;
    if (RideLock.sameDevice(lock.session, { deviceKey: session.deviceKey, installKey: session.installKey })) return;
    if (!(Number(session.createdAt) > lock.since)) return;
    this._audit('RIDE_LOCK_BLOCK refresh', session.userId);
    throw this._blocked(user || { userId: session.userId }, lock, { client: session.kind, v2: session.v2, device: {} });
  }

  /**
   * Another session (signed in before the ride) starting or joining a ride: 409 RIDE_ACTIVE_ELSEWHERE. The riding
   * session itself and the same device pass.
   */
  async assertCanRide(userId, sid, { reason = 'ride' } = {}) {
    if (!this.enabled || !userId) return;
    const lock = await this.active(userId);
    if (!lock || !sid || lock.session.sessionId === sid) return;
    const me = await this.sessions.get(sid).catch(() => null);
    if (me && RideLock.sameDevice(lock.session, { deviceKey: me.deviceKey, installKey: me.installKey })) return;
    this._audit(`RIDE_LOCK_BLOCK ${reason}`, userId);
    const e = new AuthError(`You're on a ride on ${label(lock.session)}. End it there before starting or joining another ride here.`, 409, CODE);
    e.extra = { device: label(lock.session) };
    e.reason = CODE;
    throw e;
  }

  // ------------------------------------------------------------------ override token + e-mail code
  issueToken(user, ctx = {}, { mfa = false } = {}) {
    const d = ctx.device || {};
    return jwt.sign({
      sub: user.userId, typ: 'rl', jti: crypto.randomBytes(9).toString('base64url'), k: String(ctx.client || '').slice(0, 12), v2: ctx.v2 ? 1 : 0,
      mfa: mfa ? 1 : 0, pv: Number(user.passwordChangedAt) || 0,
      // No label from a browser: "Chrome on Windows" (the code e-mail names the device trying to sign in).
      d: { l: String(d.label || (ctx.ua ? require('./sessions').uaSummary(ctx.ua) : '') || '').slice(0, 60), p: String(d.platform || '').slice(0, 20), i: String(d.id || '').slice(0, 128), n: String(d.installId || '').slice(0, 128) },
    }, config.jwtSecret, { expiresIn: '15m', issuer: 'coroute-gateway', algorithm: 'HS256' });
  }

  verifyToken(token) {
    try {
      const c = jwt.verify(String(token || ''), config.jwtSecret, { issuer: 'coroute-gateway', algorithms: ['HS256'] });
      return c && c.typ === 'rl' ? c : null;
    } catch { return null; }
  }

  async _tokenUser(token) {
    const c = this.verifyToken(token);
    const bad = () => new AuthError('This sign-in step expired. Sign in again.', 401, 'LOCK_EXPIRED');
    if (!c) throw bad();
    const user = await this.repo.findUserById(String(c.sub));
    if (!user || user.status === 'ON_HOLD' || user.status === 'BLOCKED') throw bad();
    if ((Number(user.passwordChangedAt) || 0) !== (Number(c.pv) || 0)) throw bad();
    return { user, c };
  }

  /** Sends the ride sign-in code. Resolves { ok, resendAfterSec, expiresInSec, sentTo } (masked address). */
  async sendCode(token) {
    const { user, c } = await this._tokenUser(token);
    const lock = await this.active(user.userId);
    const out = await this.codes.issue(user, 'ride', { bind: c.jti });
    if (this.mail) {
      this.mail('ride_signin_code', user.email, {
        name: user.name, device: (c.d && c.d.l) || 'a new device', otherDevice: lock ? label(lock.session) : 'your other phone',
        code: out.code, minutes: config.emailCodeTtlMin,
      });
    }
    this._audit('RIDE_LOCK_CODE_SENT', user.userId);
    return { ok: true, resendAfterSec: out.resendAfterSec, expiresInSec: config.emailCodeTtlMin * 60, sentTo: maskEmail(user.email) };
  }

  /**
   * Checks the code, hands the ride over and revokes the old session. Resolves { user, ctx, mfa } for the caller to
   * issue the new session (AuthService._issue with the ride lock passed).
   */
  async verifyCode(token, code, reqCtx = {}) {
    const { user, c } = await this._tokenUser(token);
    await this.codes.verify(user, 'ride', code, { bind: c.jti });
    const lock = await this.active(user.userId);
    if (lock) await this.handOver(user, lock, { by: 'EMAIL_CODE' });
    this._audit(`RIDE_LOCK_OVERRIDE ${lock ? 'handover' : 'no-lock'}`, user.userId);
    const d = c.d || {};
    const ctx = {
      ...reqCtx, client: c.k || reqCtx.client || '', v2: !!c.v2,
      device: { label: d.l || (reqCtx.device && reqCtx.device.label) || '', platform: d.p || (reqCtx.device && reqCtx.device.platform) || '', id: d.i || '', installId: d.n || '' },
    };
    if (lock && this.mail) {
      this.mail('ride_signin_notice', user.email, {
        name: user.name, device: d.l || 'a new device', otherDevice: label(lock.session), at: istTime(this.clock()), securityUrl: `${config.publicOrigin || ''}/account`,
      });
    }
    return { user, ctx, mfa: !!c.mfa, handedOver: !!lock };
  }

  /**
   * Ends the old device's ride session safely: the ride is marked handed over (the group is told "<rider> switched
   * phones"), an open SOS is left exactly as it is, then the old session is revoked (its socket keeps safety-only
   * mode until the ride ends).
   */
  async handOver(user, lock, { by = 'EMAIL_CODE' } = {}) {
    const op = { op: 'HANDOVER', groupId: lock.groupId, userId: user.userId, name: String(user.name || 'A rider').slice(0, 60) };
    let done = false;
    try { done = await this.applyHandover(op, { local: true }); } catch (e) { this.log.warn?.(`[ride-lock] handover failed: ${e.message}`); }
    // Not loaded here (the web node): the live node tells the group; on a single node (or the peer down) load it here.
    let sent = false;
    if (!done && this.toPeer) { try { sent = !!this.toPeer(op); } catch { sent = false; } }
    if (!done && !sent) {
      try { done = await this.applyHandover(op, { load: true }); } catch (e) { this.log.warn?.(`[ride-lock] handover failed: ${e.message}`); }
    }
    await this.sessions._save(lock.session, { ride: null, rideHandedOverAt: this.clock() }).catch(() => null);
    await this.sessions.revoke(lock.session.sessionId, 'RIDE_HANDOVER', { by });
  }

  /** Runs a handover on the node that has the room (or loads it when asked). True when the group was told. */
  async applyHandover(op, { load = false } = {}) {
    if (!op || op.op !== 'HANDOVER' || !this.convoys) return false;
    const has = this.convoys.rooms && this.convoys.rooms.has(op.groupId);
    if (!has && !load) return false;
    if (typeof this.convoys.noteHandover !== 'function') return false;
    return this.convoys.noteHandover(String(op.groupId), String(op.userId), String(op.name || ''));
  }

  // mirror extension 'rl': a handover asked for by the peer node (it holds no room for the ride)
  exportState() { return {}; }
  importState() { /* nothing: the lock lives in the shared database */ }
  applyRemote(op) { this.applyHandover(op).catch(() => {}); }

  // ------------------------------------------------------------------ admin
  /** Admin view of a rider's lock: { onRide, device, since } (no ride details). */
  async view(userId) {
    const lock = await this.active(userId).catch(() => null);
    return lock ? { onRide: true, device: label(lock.session), since: lock.since } : { onRide: false };
  }

  /** MASTER_ADMIN "End ride lock" (reason required, audited): the riding session no longer locks sign-ins for this ride. */
  async adminEnd(userId, { by, reason }) {
    const why = String(reason || '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
    if (why.length < 3) throw new AuthError('Give a reason (at least 3 characters).', 400, 'REASON_REQUIRED');
    const lock = await this.active(userId);
    if (!lock) return { ok: true, ended: false };
    await this.sessions._save(lock.session, { rideLockReleased: lock.groupId, rideLockReleasedBy: String(by || '').slice(0, 120), rideLockReleasedAt: this.clock() });
    this._audit(`RIDE_LOCK_ADMIN_END by ${String(by || 'admin').slice(0, 60)}: ${why.slice(0, 160)}`, userId);
    return { ok: true, ended: true, device: label(lock.session) };
  }
}

function maskEmail(e) {
  const [a, d] = String(e || '').split('@');
  if (!a || !d) return 'your e-mail address';
  return `${a[0]}***@${d}`;
}
function istTime(ms) {
  try { return new Date(ms).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Kolkata' }) + ' IST'; } catch { return new Date(ms).toISOString(); }
}

module.exports = { RideLock, CODE, maskEmail };
