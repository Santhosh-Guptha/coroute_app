'use strict';
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const { defaultHasher } = require('./password_hash');
const { OAuth2Client } = require('google-auth-library');
const config = require('./config');
const { effectiveSubscription } = require('./subscription_lifecycle');
const { profileFields, ValidationError, SWITCHES, bikeFields, BIKE_KEYS } = require('./validate');
const { passwordProblem } = require('./password_policy');
const totpLib = require('./totp');

const ROLE_ADMIN = 'MASTER_ADMIN';
const ROLE_RIDER = 'RIDER';

class AuthError extends Error {
  /** code: machine-readable cause. The app signs out only for SESSION_INVALID / ACCOUNT_GONE. */
  constructor(message, status = 400, code = undefined) { super(message); this.status = status; this.name = 'AuthError'; this.code = code; }
}

function slug(s) {
  return s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 24) || 'rider';
}

/**
 * Roles live in the database (users.role). The optional BOOTSTRAP_ADMIN_EMAILS
 * environment list only seeds the *first* admin(s); afterwards admins are
 * managed through PATCH /api/admin/users/:userId/role.
 */
function bootstrapRoleFor(email, currentRole) {
  if (currentRole === ROLE_ADMIN) return ROLE_ADMIN;
  return config.adminEmails.includes(email.toLowerCase()) ? ROLE_ADMIN : (currentRole || ROLE_RIDER);
}

function isPillionUser(u) {
  return (u.vehicleType || '').trim().toLowerCase() === 'pillion rider' || (u.vehicleNo || '').trim().toUpperCase() === 'PILLION';
}

function checkProfileComplete(u) {
  const hasName = Boolean((u.name || '').trim().length >= 2);
  const hasEmail = Boolean((u.email || '').trim().includes('@'));
  const hasPhone = Boolean((u.phone || '').trim().length >= 7);
  const pillion = isPillionUser(u);
  const hasVehicle = pillion || Boolean((u.vehicleNo || '').trim().length >= 2);
  const hasIce = Boolean((u.emergencyContact || '').trim().length >= 7 && (u.emergencyContactName || '').trim().length >= 2);
  return Boolean(hasName && hasEmail && hasPhone && hasVehicle && hasIce);
}

/**
 * Older guest accounts were stored with placeholder numbers (phone 9999999999, emergency contact
 * 112112112) so they passed the profile check. Those are not anyone's real contact: an SOS must
 * never text or show them. Returns the stored number, or '' for a guest placeholder.
 */
const GUEST_PLACEHOLDER_NUMBERS = new Set(['9999999999', '112112112']);
function realContactNumber(u, field) {
  const v = String((u && u[field]) || '').trim();
  if (!v) return '';
  const isGuest = u.provider === 'guest' || String(u.email || '').endsWith('@guest.coroute.local');
  if (isGuest && GUEST_PLACEHOLDER_NUMBERS.has(v.replace(/[^0-9]/g, ''))) return '';
  return v;
}

/** The rider's bike summary as stored (3.55); never in publicUser (admin lists, other riders). */
function bikeSummary(u) {
  return {
    bikeModel: typeof u.bikeModel === 'string' ? u.bikeModel : '',
    bikeCc: Number(u.bikeCc) || 0,
    bikeColour: typeof u.bikeColour === 'string' ? u.bikeColour : '',
    bikeTankL: Number(u.bikeTankL) || 0,
    bikeMileageKmL: Number(u.bikeMileageKmL) || 0,
    bikeCooling: ['air', 'oil', 'liquid'].includes(u.bikeCooling) ? u.bikeCooling : 'unknown',
    bikeType: typeof u.bikeType === 'string' ? u.bikeType : '',
    bikeFuel: typeof u.bikeFuel === 'string' ? u.bikeFuel : '',
  };
}

function publicUser(u) {
  const pillion = isPillionUser(u);
  return {
    userId: u.userId,
    name: u.name,
    email: u.email,
    role: u.role,
    status: u.status || 'ACTIVE',
    statusReason: u.statusReason || '',
    statusChangedAt: u.statusChangedAt || 0,
    phone: u.phone || '',
    vehicleType: pillion ? 'Pillion Rider' : (u.vehicleType || 'Motorcycle'),
    vehicleNo: pillion ? 'PILLION' : (u.vehicleNo || ''),
    isPillion: pillion,
    isProfileComplete: checkProfileComplete(u),
    emergencyContact: u.emergencyContact || '',
    emergencyContactName: u.emergencyContactName || '',
    provider: u.provider || 'password',
    createdAt: u.createdAt || 0,
    lastActiveAt: u.lastActiveAt || u.lastLoginAt || 0,
    mustChangePassword: !!u.mustChangePassword,
    // 3.55 public username and profile picture (src/usernames.js, src/avatars.js): safe to show.
    username: u.username || '',
    avatarUrl: require('./avatars').avatarUrlOf(u.avatarId),
  };
}

/**
 * What the account owner sees about themselves: the public profile plus the optional medical
 * info and the emergency-text opt-out. Only for the owner (register, login, /me); admin lists and
 * details keep publicUser (no medical info).
 */
function selfUser(u) {
  return {
    ...publicUser(u),
    bloodGroup: u.bloodGroup || '',
    allergies: u.allergies || '',
    medicalNotes: u.medicalNotes || '',
    smsOptOut: !!u.smsOptOut,
    // 3.55 active bike summary (engine care, fuel analysis): owner and admin detail only.
    ...bikeSummary(u),
    // Nearby-rider assistance (3.15): owner only, never in publicUser.
    assistHelp: u.assistHelp !== false,
    assistAsk: u.assistAsk !== false,
    // Medical info is always shared with responders in an emergency (no switch any more). Kept as a
    // constant true so older apps that read it show the right state; a stored false is ignored.
    responderMedical: true,
    netConsentAt: Number(u.netConsentAt) || 0,
    subscriptionTier: u.subscriptionTier || 'community',
    subscriptionValidUntil: Number(u.subscriptionValidUntil) || 0,
    // Effective state: a paid tier past its validUntil reads as community here even before the
    // sweeper rolled the document back. Shape: { tier, validUntil, isActive, isExpired, daysRemaining, expiringSoon, previousTier }.
    subscriptionStatus: effectiveSubscription(u),
    // Lets the app tell a guest session apart (guest ids are ordinary usr_ ids).
    isGuest: u.provider === 'guest',
    // 3.55: hide my username from the website leaderboards (default shown); username change cooldown.
    publicLeaderboard: u.publicLeaderboard !== false,
    usernameChangedAt: Number(u.usernameChangedAt) || 0,
  };
}

/** Profile keys that change what the ride group's SMS roster holds. */
const ROSTER_KEYS = ['phone', 'emergencyContact', 'emergencyContactName', 'smsOptOut'];
/** Profile keys the safety network reads from the live rider record (3.15, server only, no ROSTER_CHANGED). */
const ASSIST_KEYS = ['assistHelp', 'assistAsk'];

/**
 * Signs an access token. 3.57: `sid` binds it to a server session (src/sessions.js), so a sign-out, a revoke or
 * "sign out of all devices" ends it at once. `short`: a 15-minute access token (typ 'at') for clients that refresh
 * (app >= 10025, website, admin, operator); otherwise the long sliding token older app builds understand.
 */
function signToken(user, { sid = null, short = false } = {}) {
  const claims = { sub: user.userId, name: user.name, role: user.role, email: user.email, pv: Number(user.passwordChangedAt) || 0 };
  if (sid) claims.sid = sid;
  if (short) claims.typ = 'at';
  return jwt.sign(
    // pv: the password version this token was issued for; a later password change ends it.
    claims,
    config.jwtSecret,
    { expiresIn: short ? `${config.accessTokenTtlMin}m` : `${config.jwtTtlDays}d`, issuer: 'coroute-gateway', algorithm: 'HS256' },
  );
}

/** A short-lived token for the second sign-in step (2-step verification); never accepted as a session. */
function signMfaToken(user, { kind, enroll }) {
  return jwt.sign({ sub: user.userId, typ: 'mfa', k: kind, e: enroll ? 1 : 0, pv: Number(user.passwordChangedAt) || 0 },
    config.jwtSecret, { expiresIn: '10m', issuer: 'coroute-gateway', algorithm: 'HS256' });
}
function verifyMfaToken(token) {
  try {
    const c = jwt.verify(String(token || ''), config.jwtSecret, { issuer: 'coroute-gateway', algorithms: ['HS256'] });
    return c && c.typ === 'mfa' ? c : null;
  } catch { return null; }
}

/**
 * Verifies with JWT_SECRET, then (rotation grace) with JWT_SECRET_PREVIOUS. Never signs with the previous one.
 * 3.57: an expired token is reported (expired: true) so a short access token can answer TOKEN_EXPIRED (the client
 * refreshes) instead of SESSION_INVALID (the client signs out). Callers that do not ask for it get null as before.
 * @returns {{claims: object, previous: boolean, expired: boolean}|null}
 */
function verifyTokenDetailed(token, { allowExpired = false } = {}) {
  // Algorithm pinned: a token signed any other way (none, RS/HS confusion) is never accepted.
  if (typeof token !== 'string' || token.length > 4096) return null;
  const opts = { issuer: 'coroute-gateway', algorithms: ['HS256'], ignoreExpiration: true };
  const finish = (claims, previous) => {
    // 2-step tokens are never a session.
    if (!claims || claims.typ === 'mfa') return null;
    const expired = Number.isFinite(claims.exp) && claims.exp * 1000 <= Date.now();
    if (expired && !allowExpired) return null;
    return { claims, previous, expired };
  };
  try {
    return finish(jwt.verify(token, config.jwtSecret, opts), false);
  } catch (e) {
    // Only a signature mismatch may fall back; a malformed token stays refused.
    if (!config.jwtSecretPrevious || e?.name !== 'JsonWebTokenError' || e.message !== 'invalid signature') return null;
  }
  try {
    return finish(jwt.verify(token, config.jwtSecretPrevious, opts), true);
  } catch {
    return null;
  }
}

function verifyToken(token) {
  const r = verifyTokenDetailed(token);
  return r ? r.claims : null;
}

const MSG_ON_HOLD = 'Your account has been placed on hold by the administrator.';
const MSG_BLOCKED = 'Your account has been blocked by the administrator.';
const MSG_GONE = 'This account no longer exists.';
const MSG_SESSION = 'Your session has ended. Please sign in again.';
// Guest / Quick Ride mode was retired in 3.55: every rider signs in with a (free) account.
const MSG_GUEST_RETIRED = 'Guest mode has ended. Create a free CoRoute account (Community plan) to keep riding.';

/** A guest session from before 3.55 (provider 'guest' or a placeholder guest address). */
function isLegacyGuest(u) {
  return !!u && (u.provider === 'guest' || String(u.userId || '').startsWith('guest_') || String(u.email || '').endsWith('@guest.coroute.local'));
}

/**
 * One account check for every authenticated request and socket.
 *
 * A valid JWT is not enough: the account must still exist, be ACTIVE, and the
 * token must not predate a password change. The users document is cached for
 * a short time (USER_GATE_TTL_MS) so an active rider costs at most one users
 * read per TTL; every admin action that changes an account calls invalidate()
 * so it takes effect at once.
 */
class UserGate {
  constructor(repo, { ttlMs = config.userGateTtlMs, maxEntries = 5000, clock = () => Date.now(), sessions = null } = {}) {
    this.repo = repo; this.ttlMs = ttlMs; this.maxEntries = maxEntries; this.clock = clock;
    /** 3.57 server-side sessions (src/sessions.js SessionStore); null in unit tests that build a bare gate. */
    this.sessions = sessions;
    this.cache = new Map(); // userId -> { user, at }
    this.inflight = new Map(); // userId -> Promise<user|null> (one DB read per user at a time)
    this.reads = 0;
  }

  invalidate(userId) {
    if (!userId) return;
    this.cache.delete(userId);
    this.inflight.delete(userId);
  }

  /**
   * v3.56: `maxAgeMs` lets a hot path (socket telemetry) accept an older entry than ttlMs; with `swr` an entry up to
   * twice that old is answered at once while one refresh runs in the background (stale-while-revalidate), so a
   * position never waits for the database. invalidate() still removes the entry at once (holds, blocks, deletes).
   */
  async _load(userId, { maxAgeMs = this.ttlMs, swr = false } = {}) {
    const hit = this.cache.get(userId);
    const age = hit ? this.clock() - hit.at : Infinity;
    if (hit && age < maxAgeMs) return hit.user;
    if (hit && swr && age < 2 * maxAgeMs) {
      if (!this.inflight.has(userId)) this._load(userId).catch(() => {});
      return hit.user;
    }
    let p = this.inflight.get(userId);
    if (!p) {
      this.reads++;
      p = this.repo.findUserById(userId).then((user) => {
        if (this.inflight.get(userId) === p) {
          this.inflight.delete(userId);
          if (user) {
            this.cache.delete(userId);
            this.cache.set(userId, { user, at: this.clock() });
            while (this.cache.size > this.maxEntries) this.cache.delete(this.cache.keys().next().value);
          }
        }
        return user;
      }, (e) => {
        if (this.inflight.get(userId) === p) this.inflight.delete(userId);
        // A short database outage must not sign out or disconnect everyone: an expired entry
        // is used until the next read works. invalidate() removes the entry, so an account
        // that was just held, blocked, deleted or demoted never falls back to old data.
        const stale = this.cache.get(userId);
        if (stale) return stale.user;
        throw e;
      });
      this.inflight.set(userId, p);
    }
    return p;
  }

  /** Resolves to the database user for these token claims, or throws AuthError. */
  async check(claims) {
    return (await this.checkDetailed(claims)).user;
  }

  /**
   * 3.57: { user, session } for these claims. A token with a sid must belong to a live session (src/sessions.js:
   * not signed out, revoked, idle or expired); a token without one (issued before 3.57) must not predate the
   * account's last "sign out of all devices" (users.tokensValidAfter).
   */
  async checkDetailed(claims, { touch = true, maxAgeMs, swr = false } = {}) {
    const user = await this._checkUser(claims, { maxAgeMs, swr });
    let session = null;
    if (claims.sid && this.sessions) {
      try {
        session = await this.sessions.validate(String(claims.sid), user.userId, { touch, maxAgeMs, swr });
      } catch (e) {
        if (e && e.name === 'SessionError') throw revokedError(e.message);
        throw e;
      }
    } else if (!claims.sid) {
      const after = Number(user.tokensValidAfter) || 0;
      if (after && (Number(claims.iat) || 0) * 1000 + 1000 < after) throw revokedError(MSG_SESSION);
    }
    return { user, session };
  }

  async _checkUser(claims, { maxAgeMs, swr = false } = {}) {
    const userId = claims && claims.sub;
    if (!userId) throw new AuthError(MSG_SESSION, 401, 'SESSION_INVALID');
    const user = await this._load(String(userId), { ...(maxAgeMs ? { maxAgeMs } : {}), swr });
    // 404 keeps what GET /me has always answered for a deleted account; the app signs out on the code.
    if (!user) throw new AuthError(MSG_GONE, 404, 'ACCOUNT_GONE');
    if (user.status === 'ON_HOLD') throw new AuthError(MSG_ON_HOLD, 403, 'ACCOUNT_ON_HOLD');
    if (user.status === 'BLOCKED') throw new AuthError(MSG_BLOCKED, 403, 'ACCOUNT_BLOCKED');
    // SESSION_INVALID so every app build (old ones too) signs the guest out with this message.
    if (isLegacyGuest(user)) throw new AuthError(MSG_GUEST_RETIRED, 401, 'SESSION_INVALID');
    // Round 4: an account whose e-mail is not verified yet never has a working session.
    if (user.emailVerified === false) throw new AuthError(MSG_SESSION, 401, 'SESSION_INVALID');
    const issuedMs = (Number(claims.iat) || 0) * 1000;
    // A token older than the account belongs to an earlier account that had the same userId.
    if (user.createdAt && issuedMs + 1000 < user.createdAt) throw new AuthError(MSG_SESSION, 401, 'SESSION_INVALID');
    const changed = Number(user.passwordChangedAt) || 0;
    if (changed) {
      const stale = claims.pv !== undefined ? changed > (Number(claims.pv) || 0) : changed > issuedMs + 1000;
      if (stale) throw revokedError(MSG_SESSION);
    }
    return user;
  }
}

/**
 * 3.57: a session that was signed out / revoked (not an account that is gone, held or blocked). The socket hub uses
 * `revoked` to keep a rider's live ride connection until the ride ends (never cut SOS relay mid-ride).
 */
function revokedError(message) {
  const e = new AuthError(message, 401, 'SESSION_INVALID');
  e.revoked = true;
  return e;
}

/** The request identity, always from the database (role and name included), never from the token. */
function identityOf(user) {
  return { userId: user.userId, name: user.name, role: user.email ? bootstrapRoleFor(user.email, user.role) : (user.role || ROLE_RIDER), email: user.email };
}

class AuthService {
  /** @param {import('./oracle/repo').Repo} repo */
  constructor(repo, { googleVerifier, gate = null, hasher = defaultHasher() } = {}) {
    this.repo = repo;
    this.gate = gate;
    /** Password hashing off the event loop (scrypt; legacy bcrypt verified in a worker, then upgraded). */
    this.hasher = hasher;
    /** (user, changedKeys) => void: set by app.js so a live ride hears about phone / opt-out changes. */
    this.onProfileChanged = null;
    /** async (user) => user|null: set by app.js; rolls an expired paid tier back on login and /me. */
    this.onUserSeen = null;
    /** async (user, {created, inviteCode}) => user: set by social_routes.attachSocial (username, invite). */
    this.onUserReady = null;
    this.google = googleVerifier || (config.googleClientIds.length ? new OAuth2Client() : null);
    /** 3.57: (type, user, data) => void, set by security_routes (new-device / lock / password-changed e-mails). */
    this.onSecurityEvent = null;
    /** 3.57: failed sign-ins per identifier on this node (progressive delay, also for unknown accounts). */
    this.failures = new Map();
    /** Round 4 ride lock (src/ride_lock.js), set by app.js; null in unit tests. */
    this.rideLock = null;
    /** Round 4: (templateId, to, vars) => Promise, set by security_routes (src/security_emails.js over SMTP). */
    this.mailTemplate = null;
    /** Round 4: e-mailed one-time codes (src/email_codes.js), created lazily. */
    this._codes = null;
  }

  get codes() {
    if (!this._codes) this._codes = new (require('./email_codes').EmailCodes)({ repo: this.repo });
    return this._codes;
  }

  _mail(id, to, vars) {
    try { if (this.mailTemplate && to) return this.mailTemplate(id, to, vars); } catch { /* never in the way */ }
    return Promise.resolve({ sent: false });
  }

  /** 3.57 server-side sessions (src/sessions.js), when the gate has them. */
  get sessions() { return (this.gate && this.gate.sessions) || null; }

  _invalidate(userId) { if (this.gate) this.gate.invalidate(userId); }

  _event(type, user, data = {}) {
    try { if (this.onSecurityEvent) this.onSecurityEvent(type, user, data); } catch { /* never in the way */ }
  }

  /** Ends every session of a user (optionally keeping the caller's) and every pre-3.57 token. */
  async revokeAllSessions(userId, reason, { exceptSid = null, by = '' } = {}) {
    const user = await this.repo.findUserById(userId);
    if (user && !exceptSid) await this.repo.updateUser(user.key, { tokensValidAfter: Date.now() }).catch(() => null);
    this._invalidate(userId);
    const store = this.sessions;
    return store ? store.revokeAllForUser(userId, reason, { exceptSid, by }) : 0;
  }

  /**
   * A new session for a user who just proved who they are: { token, user, sessionId, sessionKind,
   * refreshToken?, accessExpiresAt? }. ctx: { client, v2, device, ip, ua, created }.
   */
  async _issue(user, ctx = {}, { mfa = false, rideLockPassed = false } = {}) {
    const store = this.sessions;
    if (!store) return { token: signToken(user), user: selfUser(user) };
    const { SessionStore } = require('./sessions');
    const kind = SessionStore.kindOf(ctx.client, ctx.v2);
    // Round 4 ride lock: another device during an active ride answers 423 (credentials were checked before).
    if (this.rideLock && !ctx.created && !rideLockPassed) await this.rideLock.checkSignIn(user, ctx, { mfa });
    const { session, refreshToken } = await store.create({ user, kind, device: ctx.device || {}, ip: ctx.ip, ua: ctx.ua, mfa, build: ctx.build || 0, lockChecked: !!this.rideLock });
    const out = { token: signToken(user, { sid: session.sessionId, short: session.v2 }), user: selfUser(user), sessionId: session.sessionId, sessionKind: kind };
    if (session.v2) { out.refreshToken = refreshToken; out.accessExpiresAt = Date.now() + config.accessTokenTtlMin * 60000; }
    this._noteDevice(user, session, { quiet: !!ctx.created }).catch(() => {});
    return out;
  }

  /** "New sign-in to CoRoute on <device>": once per device fingerprint (keyed hash), never on the first one. */
  async _noteDevice(user, session, { quiet = false } = {}) {
    const fc = this.sessions && this.sessions.fc;
    const fp = fc ? fc.blindIndex(`${session.platform}|${session.deviceLabel}`, 'device') : `${session.platform}|${session.deviceLabel}`;
    const fresh = (user.key ? user : await this.repo.findUserById(user.userId)) || user;
    const known = Array.isArray(fresh.knownDevices) ? fresh.knownDevices.filter((d) => d && typeof d.fp === 'string') : [];
    if (known.some((d) => d.fp === fp)) return;
    const next = [...known, { fp, at: Date.now() }].slice(-20);
    if (fresh.key) await this.repo.updateUser(fresh.key, { knownDevices: next });
    // The first device recorded (registration, or the first sign-in after 3.57) sends nothing.
    if (known.length && !quiet) this._event('NEW_DEVICE', user, { device: session.deviceLabel, kind: session.kind, at: session.createdAt });
  }

  /** Who may enrol 2-step verification: administrators and operator owners / co-organisers. */
  async mfaEligible(user) {
    if (!user) return false;
    if (user.role === ROLE_ADMIN) return true;
    try { return (await require('./operators').operatorsFor(this.repo.soda, user.userId)).length > 0; } catch { return false; }
  }

  /** Which second step a sign-in needs: 'enroll' (admin without 2-step yet), 'verify', or null. */
  _mfaNeeded(user, kind) {
    if (kind === 'admin' && user.role === ROLE_ADMIN && config.adminMfaEnforce !== 'off') return user.mfaEnabled ? 'verify' : 'enroll';
    if ((kind === 'admin' || kind === 'operator' || kind === 'web') && (user.mfaEnabled || (user.mfaEmail && user.role !== ROLE_ADMIN))) return 'verify';
    return null;
  }

  /**
   * Second factors this account may use: TOTP and recovery codes when enrolled; an e-mailed code (round 4) for
   * operators and other non-admin accounts that turned it on or have TOTP (fallback). MASTER_ADMIN: TOTP or recovery only.
   */
  static mfaMethods(user) {
    const m = [];
    if (user && user.mfaEnabled) m.push('totp', 'recovery');
    if (user && user.role !== ROLE_ADMIN && (user.mfaEmail || user.mfaEnabled)) m.push('email');
    return m;
  }

  /** The answer to a correct password / Google sign-in: a session, or the second step first. */
  async _completeSignIn(user, ctx) {
    const { SessionStore } = require('./sessions');
    const kind = SessionStore.kindOf(ctx.client, ctx.v2);
    // Round 4: the ride lock is checked right after the credentials (before any 2-step step).
    if (this.rideLock && this.sessions) await this.rideLock.checkSignIn(user, ctx);
    const need = this.sessions ? this._mfaNeeded(user, kind) : null;
    if (need) {
      return { mfa: need, mfaToken: signMfaToken(user, { kind, enroll: need === 'enroll' }), methods: AuthService.mfaMethods(user), user: { name: user.name, role: user.role, email: user.email } };
    }
    return this._issue(user, ctx, { rideLockPassed: true });
  }

  async _failedSignIn(id, user) {
    const now = Date.now();
    const k = id.toLowerCase().slice(0, 120);
    const f = this.failures.get(k);
    const n = f && now - f.at < 15 * 60000 ? f.n + 1 : 1;
    this.failures.delete(k);
    this.failures.set(k, { n, at: now });
    while (this.failures.size > 20000) this.failures.delete(this.failures.keys().next().value);
    if (user && user.key) {
      const recent = now - (Number(user.loginFailAt) || 0) < 15 * 60000;
      const count = (recent ? Number(user.loginFailures) || 0 : 0) + 1;
      const patch = { loginFailures: count, loginFailAt: now };
      if (count >= config.loginLockThreshold) {
        const locks = (Number(user.lockCount) || 0) + 1;
        const minutes = Math.min(24 * 60, config.loginLockMinutes * 2 ** (locks - 1));
        Object.assign(patch, { loginFailures: 0, lockCount: locks, lockUntil: now + minutes * 60000 });
        this._event('ACCOUNT_LOCKED', user, { minutes });
        try { if (this.sessions && this.sessions.audit) this.sessions.audit.add({ kind: 'AUTH', subjectId: user.userId, detail: 'ACCOUNT_LOCKED' }); } catch { /* audit only */ }
      }
      await this.repo.updateUser(user.key, patch).catch(() => null);
    }
    // Progressive delay after the third failure (same for known and unknown accounts).
    const delay = Math.min(3000, config.loginDelayStepMs * Math.max(0, n - 3));
    if (delay > 0) await new Promise((r) => setTimeout(r, delay));
  }

  async _uniqueUserId(name) {
    const base = `usr_${slug(name)}`;
    // An id is free only if no account has it AND no convoy still lists it: accounts deleted
    // by builds before 3.11 left their id in convoy members, and a new account with that id
    // would inherit the old rider's view of those convoys.
    const free = async (id) => !(await this.repo.findUserById(id)) && !(await this.repo.userIdReferenced(id));
    if (await free(base)) return base;
    for (;;) {
      const candidate = `${base}_${crypto.randomBytes(2).toString('hex')}`;
      if (await free(candidate)) return candidate;
    }
  }

  /**
   * Creates an account. Round 4 (`verify`, the default): the answer is the same generic 202 whatever the address
   * ({ pending: true, message }); a new account waits for its e-mail link (single use, 24 h, only a hash stored) and
   * cannot sign in until then; a registered address gets a "someone tried to create an account with your e-mail"
   * mail instead of a 409. `verify: false` (builds before 10025 with REGISTER_VERIFY_LEGACY=allow): the old
   * behaviour, an immediate session (201) and 409 for a taken address.
   */
  async register({ name, email, password, phone, vehicleType, vehicleNo, emergencyContact, emergencyContactName, inviteCode }, ctx = {}, { verify = false } = {}) {
    if (!String(name ?? '').trim()) throw new AuthError('Callsign / full name is required.');
    if (!String(email ?? '').trim()) throw new AuthError('A valid email address is required.');
    if (!password || typeof password !== 'string' || password.length < 8) throw new AuthError('Password must be at least 8 characters.');
    if (password.length > 200) throw new AuthError('Password must be at most 200 characters.');
    if (!String(phone ?? '').trim()) throw new AuthError('Mobile phone number is required.');
    // Emergency contact may be added later (Google sign-up completes the profile afterwards).
    const clean = profileFields(
      { name, email, phone, vehicleType, vehicleNo, emergencyContact, emergencyContactName },
      { optionalEmpty: ['emergencyContact', 'emergencyContactName'] },
    );
    // 3.57: common / breached passwords, the e-mail or the callsign are refused (src/password_policy.js).
    const weak = passwordProblem(password, { email: clean.email, name: clean.name });
    if (weak) throw new ValidationError(weak, { password: weak }, 422, 'WEAK_PASSWORD');
    const invite = typeof inviteCode === 'string' ? inviteCode.slice(0, 20) : null;

    if (verify) {
      // The callsign is public (shown to riders), so "taken" may be said; it is checked BEFORE the address, so the
      // answer never depends on whether the address is registered.
      const byName = await this.repo.findUserByName(clean.name);
      const existing = await this.repo.findUserByEmail(clean.email);
      if (byName && !(existing && byName.userId === existing.userId)) {
        throw new ValidationError('That callsign is taken. Choose another one.', { name: 'That callsign is taken.' }, 409, 'CALLSIGN_TAKEN');
      }
      const passwordHash = await this.hasher.hash(password); // the same work for every answer (only stored for a new account)
      if (existing) {
        // A pending sign-up gets its link again (its first password stays: a second sign-up never replaces it, or a
        // stranger could set the password of an address before its owner opens the link).
        if (existing.emailVerified === false) await this._sendVerifyLink(existing);
        else this._noteRegisterAttempt(existing).catch(() => {});
        return { pending: true };
      }
      const pillion0 = (clean.vehicleType || '').toLowerCase() === 'pillion rider' || clean.vehicleNo === 'PILLION';
      const user = await this.repo.createUser({
        userId: await this._uniqueUserId(clean.name),
        name: clean.name,
        email: clean.email,
        passwordHash,
        role: bootstrapRoleFor(clean.email),
        provider: 'password',
        phone: clean.phone,
        vehicleType: pillion0 ? 'Pillion Rider' : (clean.vehicleType || 'Motorcycle'),
        vehicleNo: pillion0 ? 'PILLION' : (clean.vehicleNo || ''),
        emergencyContact: clean.emergencyContact || '',
        emergencyContactName: clean.emergencyContactName || '',
        createdAt: Date.now(),
        emailVerified: false,
        pendingInvite: invite || '',
      });
      await this._sendVerifyLink(user, { first: true });
      return { pending: true };
    }

    // Same words whether the address is registered or not, beyond the 409 the app needs to offer "Sign in".
    if (await this.repo.findUserByEmail(clean.email)) throw new AuthError('We could not create an account with these details. If you already have one, sign in or reset your password.', 409, 'ACCOUNT_EXISTS');
    // The callsign is a sign-in name, so it must be unique.
    if (await this.repo.findUserByName(clean.name)) throw new ValidationError('That callsign is taken. Choose another one.', { name: 'That callsign is taken.' }, 409, 'CALLSIGN_TAKEN');

    const pillion = (clean.vehicleType || '').toLowerCase() === 'pillion rider' || clean.vehicleNo === 'PILLION';
    const cleanVehicleType = pillion ? 'Pillion Rider' : (clean.vehicleType || 'Motorcycle');
    const cleanVehicleNo = pillion ? 'PILLION' : (clean.vehicleNo || '');

    const user = await this.repo.createUser({
      userId: await this._uniqueUserId(clean.name),
      name: clean.name,
      email: clean.email,
      passwordHash: await this.hasher.hash(password),
      role: bootstrapRoleFor(clean.email),
      provider: 'password',
      phone: clean.phone,
      vehicleType: cleanVehicleType,
      vehicleNo: cleanVehicleNo,
      emergencyContact: clean.emergencyContact || '',
      emergencyContactName: clean.emergencyContactName || '',
      createdAt: Date.now(),
      lastLoginAt: Date.now(),
    });
    const ready = await this._ready(user, { created: true, inviteCode: invite });
    return this._issue(ready, { ...ctx, created: true });
  }

  /**
   * A new verification link for a pending account (rate limited: one per 60 s, 3 per hour). Returns true when sent.
   */
  async _sendVerifyLink(user, { first = false } = {}) {
    const now = Date.now();
    const recent = (Array.isArray(user.emailVerifySent) ? user.emailVerifySent : []).filter((t) => now - t < 3600000);
    if (!first && (recent.length >= 3 || (recent.length && now - Math.max(...recent) < 60000))) return false;
    const token = crypto.randomBytes(32).toString('base64url');
    const hash = crypto.createHash('sha256').update(`emailverify|${token}`).digest('hex');
    await this.repo.updateUser(user.key, {
      emailVerifyHash: hash, emailVerifyExp: now + config.registerVerifyTtlHours * 3600000, emailVerifySent: [...recent, now],
    });
    const origin = config.publicOrigin || '';
    this._mail('register_verify', user.email, { name: user.name, link: `${origin}/signin#verify=${token}`, hours: config.registerVerifyTtlHours });
    return true;
  }

  /** "Someone tried to create an account with your e-mail": at most once per 6 hours per account. */
  async _noteRegisterAttempt(user) {
    const now = Date.now();
    if (now - (Number(user.registerAttemptMailAt) || 0) < 6 * 3600000) return;
    await this.repo.updateUser(user.key, { registerAttemptMailAt: now });
    this._mail('register_exists', user.email, { name: user.name, signinUrl: `${config.publicOrigin || ''}/signin` });
  }

  /** Resend from the "Check your inbox" screen: always the same answer; only a pending account gets a link. */
  async resendVerification(email) {
    const e = String(email || '').trim().toLowerCase();
    if (!e || e.length > 254 || !e.includes('@')) return;
    const user = await this.repo.findUserByEmail(e);
    if (user && user.emailVerified === false) await this._sendVerifyLink(user);
  }

  /** The e-mail link: the account becomes usable (welcome e-mail, username, invite). Single use, 24 h. */
  async verifyEmail(token) {
    const t = String(token || '');
    const bad = () => new AuthError('This link is not valid any more. Sign up again or ask for a new link.', 400, 'LINK_INVALID');
    if (!/^[A-Za-z0-9_-]{40,60}$/.test(t)) throw bad();
    const hash = crypto.createHash('sha256').update(`emailverify|${t}`).digest('hex');
    const row = await this.repo.soda.findOne('users', { emailVerifyHash: hash });
    const user = row ? { ...row.value, key: row.key } : null;
    if (!user || !(Number(user.emailVerifyExp) > Date.now())) throw bad();
    const updated = await this.repo.updateUser(user.key, { emailVerified: true, emailVerifiedAt: Date.now(), emailVerifyHash: '', emailVerifyExp: 0, emailVerifySent: [], pendingInvite: '' });
    this._invalidate(user.userId);
    await this._ready(updated || user, { created: true, inviteCode: user.pendingInvite || null });
    return { ok: true, email: user.email, message: 'Your e-mail is confirmed. Sign in to start riding.' };
  }

  /** Removes accounts that never verified their address within REGISTER_PURGE_DAYS (leased job). */
  async purgeUnverified(now = Date.now()) {
    const cutoff = now - config.registerPurgeDays * 86400000;
    const rows = await this.repo.soda.query('users', { emailVerified: false }, { limit: 500 });
    let n = 0;
    for (const r of rows) {
      const u = { ...r.value, key: r.key };
      if (!(Number(u.createdAt) < cutoff)) continue;
      await this.repo.deleteUserCascade(u, {}).catch(() => null);
      this._invalidate(u.userId);
      n++;
    }
    return n;
  }

  async login({ identifier, password }, ctx = {}) {
    const id = typeof identifier === 'string' ? identifier.trim() : '';
    if (!id || !password || typeof password !== 'string') throw new AuthError('Email/callsign and password are required.');
    if (id.length > 254 || password.length > 1024) throw new AuthError('Invalid credentials.', 401);
    const user = id.includes('@') ? await this.repo.findUserByEmail(id) : await this.repo.findUserByName(id);
    // 3.57: a locked account (too many wrong passwords) answers like the per-account rate limit, after the same work.
    if (user && Number(user.lockUntil) > Date.now()) {
      await this.hasher.dummyVerify(password);
      throw new AuthError('Too many attempts, try again later.', 429, 'RATE_LIMITED');
    }
    // Same work for unknown accounts: a dummy verify of the current cost, then the same refusal.
    const check = user?.passwordHash ? await this.hasher.verify(password, user.passwordHash) : (await this.hasher.dummyVerify(password), null);
    if (!user || !check?.ok) {
      await this._failedSignIn(id, user);
      throw new AuthError('Invalid credentials.', 401);
    }
    if (user.status === 'ON_HOLD') throw new AuthError(MSG_ON_HOLD, 403, 'ACCOUNT_ON_HOLD');
    if (user.status === 'BLOCKED') throw new AuthError(MSG_BLOCKED, 403, 'ACCOUNT_BLOCKED');
    // Round 4: only after the right password, so it never tells a stranger that the address signed up.
    if (user.emailVerified === false) {
      const e = new AuthError('Confirm your e-mail first: open the link we sent you. You can ask for a new link below.', 403, 'EMAIL_NOT_VERIFIED');
      e.extra = { email: user.email };
      throw e;
    }
    this.failures.delete(id.toLowerCase().slice(0, 120));
    const role = bootstrapRoleFor(user.email, user.role);
    const patch = { lastLoginAt: Date.now(), role };
    if (user.loginFailures || user.lockUntil) Object.assign(patch, { loginFailures: 0, lockUntil: 0 });
    // Transparent upgrade: a legacy bcrypt hash (or scrypt at older parameters) is replaced now that we
    // know the password. passwordChangedAt is not touched, so no session ends.
    if (check.needsRehash) patch.passwordHash = await this.hasher.hash(password);
    const updated = await this._ready(await this._seen(await this.repo.updateUser(user.key, patch) || user));
    return this._completeSignIn(updated, ctx);
  }

  async loginWithGoogle({ idToken }, ctx = {}) {
    if (!this.google) throw new AuthError('Google Sign-In is not configured on this server.', 501);
    if (!idToken || typeof idToken !== 'string') throw new AuthError('idToken is required.');
    let payload;
    try {
      const ticket = await this.google.verifyIdToken({ idToken, audience: config.googleClientIds });
      payload = ticket.getPayload();
    } catch {
      throw new AuthError('Google token could not be verified.', 401);
    }
    if (!payload?.email || !payload.email_verified) throw new AuthError('Google account email is not verified.', 401);
    // google-auth-library checked the signature, audience (our client ids) and expiry; the issuer is checked here too.
    if (payload.iss && !['accounts.google.com', 'https://accounts.google.com'].includes(payload.iss)) throw new AuthError('Google token could not be verified.', 401);
    const email = payload.email.toLowerCase();
    let user = await this.repo.findUserByEmail(email);
    if (!user) {
      const name = (payload.name || email.split('@')[0]).trim();
      user = await this.repo.createUser({
        userId: await this._uniqueUserId(name),
        name,
        email,
        role: bootstrapRoleFor(email),
        provider: 'google',
        googleSub: payload.sub,
        vehicleType: 'Motorcycle',
        createdAt: Date.now(),
        lastLoginAt: Date.now(),
      });
      user = await this._ready(user, { created: true });
      return this._issue(user, { ...ctx, created: true });
    } else {
      if (user.status === 'ON_HOLD') throw new AuthError(MSG_ON_HOLD, 403, 'ACCOUNT_ON_HOLD');
      if (user.status === 'BLOCKED') throw new AuthError(MSG_BLOCKED, 403, 'ACCOUNT_BLOCKED');
      // An account whose Google id is set answers only to that Google account.
      if (user.googleSub && payload.sub && user.googleSub !== payload.sub) throw new AuthError('Google token could not be verified.', 401);
      // Round 4: Google verified the address, so a pending password sign-up with it becomes a verified account.
      const verifiedNow = user.emailVerified === false;
      user = await this._ready(await this._seen(await this.repo.updateUser(user.key, { lastLoginAt: Date.now(), role: bootstrapRoleFor(email, user.role), googleSub: payload.sub,
        ...(verifiedNow ? { emailVerified: true, emailVerifiedAt: Date.now(), emailVerifyHash: '', emailVerifyExp: 0 } : {}) }) || user), verifiedNow ? { created: true } : {});
      if (verifiedNow) this._invalidate(user.userId);
    }
    return this._completeSignIn(user, ctx);
  }

  /** Guest mode was retired in 3.55: answers 410 so old builds show the message instead of riding as a guest. */
  async loginAsGuest() {
    throw new AuthError(MSG_GUEST_RETIRED, 410, 'GUEST_RETIRED');
  }

  async changePassword(userId, { currentPassword, newPassword }, ctx = {}) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
    if (!newPassword || typeof newPassword !== 'string' || newPassword.length < 8) throw new AuthError('New password must be at least 8 characters.');
    if (newPassword.length > 200) throw new AuthError('Password must be at most 200 characters.');
    const weak = passwordProblem(newPassword, { email: user.email, name: user.name });
    if (weak) throw new ValidationError(weak, { newPassword: weak }, 422, 'WEAK_PASSWORD');
    if (user.passwordHash) {
      const ok = typeof currentPassword === 'string' && currentPassword && (await this.hasher.verify(currentPassword, user.passwordHash)).ok;
      if (!ok && !user.mustChangePassword) throw new AuthError('Current password is incorrect.', 401);
    } else if (ctx.session && !ctx.recentAuth) {
      // A Google account setting its first password: a recent Google re-authentication is needed (POST /api/auth/reauth).
      throw new AuthError('Confirm it is you first.', 403, 'REAUTH_REQUIRED');
    }
    // Bumping passwordChangedAt ends every other session; this device gets a fresh token.
    const changedAt = Math.max(Date.now(), (Number(user.passwordChangedAt) || 0) + 1);
    const updated = await this.repo.updateUser(user.key, { passwordHash: await this.hasher.hash(newPassword), mustChangePassword: false, passwordChangedAt: changedAt, tokensValidAfter: changedAt, loginFailures: 0, lockUntil: 0 });
    this._invalidate(userId);
    // 3.57: every other session ends at once (sockets too); this one continues with a fresh token.
    const sid = ctx.session ? ctx.session.sessionId : null;
    if (this.sessions) await this.sessions.revokeAllForUser(userId, 'PASSWORD_CHANGED', { exceptSid: sid });
    const u = updated || { ...user, passwordChangedAt: changedAt };
    this._event('PASSWORD_CHANGED', u, {});
    return { ok: true, token: signToken(u, { sid, short: !!(ctx.session && ctx.session.v2) }) };
  }

  /** Admin-assisted reset (no e-mail infrastructure needed): returns a one-time temporary password. */
  async adminResetPassword(actor, targetUserId) {
    const target = await this.repo.findUserById(targetUserId);
    if (!target) throw new AuthError('User not found.', 404);
    const temp = crypto.randomBytes(9).toString('base64url').replace(/[-_]/g, 'x').slice(0, 12);
    await this.repo.updateUser(target.key, {
      passwordHash: await this.hasher.hash(temp), mustChangePassword: true, passwordResetBy: actor.userId, passwordResetAt: Date.now(),
      passwordChangedAt: Math.max(Date.now(), (Number(target.passwordChangedAt) || 0) + 1),
    });
    this._invalidate(target.userId);
    if (this.sessions) await this.sessions.revokeAllForUser(target.userId, 'ADMIN_PASSWORD_RESET', { by: actor.userId });
    return { temporaryPassword: temp, userId: target.userId, name: target.name };
  }

  /**
   * Deletes the account. `prepare(user)` runs after the checks and before the erase (it takes
   * the rider out of live convoys) and returns the options for Repo.deleteUserCascade.
   */
  async deleteAccount(userId, { prepare } = {}) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
    if (user.role === ROLE_ADMIN && (await this.repo.countAdmins()) <= 1) {
      throw new AuthError('Promote another administrator before deleting the last admin account.', 409);
    }
    const opts = prepare ? await prepare(user) : {};
    await this.repo.deleteUserCascade(user, opts || {});
    this._invalidate(userId);
    // 3.57: sessions end, then their records are erased with the rest of the account (nothing keeps the userId).
    if (this.sessions) {
      await this.sessions.revokeAllForUser(userId, 'ACCOUNT_DELETED').catch(() => 0);
      await this.sessions.purgeUser(userId).catch(() => 0);
    }
    return { ok: true };
  }

  // ---- Round 4: account deletion confirmed by e-mail (builds before 10025 that send no password) ----
  async requestDeleteConfirmation(userId) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError(MSG_GONE, 404, 'ACCOUNT_GONE');
    // The same refusal as the deletion itself, before any link is sent.
    if (user.role === ROLE_ADMIN && (await this.repo.countAdmins()) <= 1) {
      throw new AuthError('Promote another administrator before deleting the last admin account.', 409);
    }
    const now = Date.now();
    const recent = (Array.isArray(user.deleteConfirmSent) ? user.deleteConfirmSent : []).filter((t) => now - t < 3600000);
    const masked = (() => { const [a, d] = String(user.email || '').split('@'); return a && d ? `${a[0]}***@${d}` : 'your address'; })();
    if (recent.length >= 3) return { sent: false, maskedEmail: masked };
    const token = crypto.randomBytes(32).toString('base64url');
    const hash = crypto.createHash('sha256').update(`accountdelete|${token}`).digest('hex');
    await this.repo.updateUser(user.key, { deleteConfirmHash: hash, deleteConfirmExp: now + config.deleteConfirmTtlMin * 60000, deleteConfirmSent: [...recent, now] });
    this._mail('delete_confirm', user.email, { name: user.name, link: `${config.publicOrigin || ''}/account#confirm-delete=${token}`, minutes: config.deleteConfirmTtlMin });
    try { if (this.sessions && this.sessions.audit) this.sessions.audit.add({ kind: 'AUTH', subjectId: user.userId, detail: 'DELETE_CONFIRM_SENT' }); } catch { /* audit only */ }
    return { sent: true, maskedEmail: masked };
  }

  /** The deletion link: resolves to the account to delete (the link is used up), or throws 400 LINK_INVALID. */
  async consumeDeleteConfirmation(token) {
    const t = String(token || '');
    const bad = () => new AuthError('This link is not valid any more. Ask again from the app.', 400, 'LINK_INVALID');
    if (!/^[A-Za-z0-9_-]{40,60}$/.test(t)) throw bad();
    const hash = crypto.createHash('sha256').update(`accountdelete|${t}`).digest('hex');
    const row = await this.repo.soda.findOne('users', { deleteConfirmHash: hash });
    const user = row ? { ...row.value, key: row.key } : null;
    if (!user || !(Number(user.deleteConfirmExp) > Date.now())) throw bad();
    await this.repo.updateUser(user.key, { deleteConfirmHash: '', deleteConfirmExp: 0 });
    return user;
  }

  async updateProfile(userId, patch) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
    patch = patch && typeof patch === 'object' ? patch : {};
    const allowed = ['name', 'phone', 'vehicleType', 'vehicleNo', 'emergencyContact', 'emergencyContactName', 'bloodGroup', 'allergies', 'medicalNotes'];
    // Only values that change are validated and written: a rider whose stored details predate
    // a rule can still update any other field. Older apps never send the medical keys or the
    // opt-out, so those are never cleared by them.
    const changed = {};
    for (const k of allowed) {
      if (patch[k] === undefined || patch[k] === null) continue;
      const next = String(patch[k]).trim();
      const current = String(user[k] ?? '').trim();
      const same = k === 'vehicleNo' || k === 'bloodGroup' ? next.toUpperCase() === current.toUpperCase() : next === current;
      if (!same) changed[k] = patch[k];
    }
    // On/off switches (smsOptOut, 3.15 assistHelp / assistAsk; responderMedical is ignored).
    // Type checked even when unchanged, so a wrong client learns about it.
    // responderMedical (older apps) is still type checked but never stored: medical info always goes to
    // responders during the rider's emergency, so an old app sending false changes nothing.
    const defaults = { smsOptOut: false, assistHelp: true, assistAsk: true };
    for (const k of SWITCHES) {
      if (patch[k] === undefined || patch[k] === null) continue;
      if (typeof patch[k] !== 'boolean') throw new ValidationError('This field must be on or off.', { [k]: 'This field must be on or off.' });
      if (k === 'responderMedical') continue;
      const current = typeof user[k] === 'boolean' ? user[k] : defaults[k];
      if (patch[k] !== current) changed[k] = patch[k];
    }
    if (changed.name !== undefined && !String(changed.name).trim()) {
      throw new ValidationError('Your callsign cannot be empty.', { name: 'Your callsign cannot be empty.' });
    }
    const clean = profileFields(changed);
    if (clean.name !== undefined) {
      if (clean.name.toLowerCase() === String(user.nameLower || user.name || '').toLowerCase()) {
        // Same callsign with different capitals: always allowed.
      } else {
        const other = await this.repo.findUserByName(clean.name);
        if (other && other.userId !== user.userId) {
          throw new ValidationError('That callsign is taken. Choose another one.', { name: 'That callsign is taken.' }, 409, 'CALLSIGN_TAKEN');
        }
      }
    }
    const pillion = (clean.vehicleType ?? user.vehicleType ?? '').toLowerCase() === 'pillion rider' ||
                    (clean.vehicleNo ?? user.vehicleNo ?? '').toUpperCase() === 'PILLION' ||
                    patch.isPillion === true;
    if (patch.isPillion !== undefined || clean.vehicleType === 'Pillion Rider') {
      if (pillion) {
        clean.vehicleType = 'Pillion Rider';
        clean.vehicleNo = 'PILLION';
      }
    }
    // Consent to the nearby-rider network (3.15): only `true` counts, it stores when.
    if (patch.netConsent === true) clean.netConsentAt = Date.now();
    // 3.55 bike summary: validated (type, range, no control characters); only changes are written.
    const bike = bikeFields(patch);
    const stored = bikeSummary(user);
    for (const k of BIKE_KEYS) if (bike[k] !== undefined && bike[k] !== stored[k]) clean[k] = bike[k];
    const updated = Object.keys(clean).length ? await this.repo.updateUser(user.key, clean) : user;
    this._invalidate(userId);
    const keys = [...ROSTER_KEYS, ...ASSIST_KEYS].filter((k) => clean[k] !== undefined && clean[k] !== user[k]);
    if (keys.length && updated && this.onProfileChanged) {
      try { await this.onProfileChanged(updated, keys); } catch { /* the profile is saved; the ride catches up on the next join */ }
    }
    return selfUser(updated);
  }

  // ---- 3.57 password reset by e-mail (single use, 30 minutes, only a hash is stored) ----
  /**
   * Starts a reset. Always resolves the same way (no account enumeration); returns the raw token only for the
   * caller to e-mail (security_routes), or null when nothing is sent. At most 3 links per account per hour.
   */
  async requestPasswordReset(email) {
    const e = String(email || '').trim().toLowerCase();
    if (!e || e.length > 254 || !e.includes('@')) return null;
    const user = await this.repo.findUserByEmail(e);
    if (!user || isLegacyGuest(user) || user.status === 'BLOCKED') return null;
    const now = Date.now();
    const recent = (Array.isArray(user.pwResetSent) ? user.pwResetSent : []).filter((t) => now - t < 3600000);
    if (recent.length >= 3) return null;
    const token = require('crypto').randomBytes(32).toString('base64url');
    const hash = require('crypto').createHash('sha256').update(`pwreset|${token}`).digest('hex');
    await this.repo.updateUser(user.key, { pwResetHash: hash, pwResetExp: now + config.passwordResetTtlMin * 60000, pwResetSent: [...recent, now] });
    return { token, user };
  }

  /** Completes a reset: new password, the link is used up, every session and token of the account ends. */
  async resetPassword({ token, newPassword }) {
    const t = String(token || '');
    if (!/^[A-Za-z0-9_-]{40,60}$/.test(t)) throw new AuthError('This reset link is not valid any more. Ask for a new one.', 400, 'RESET_INVALID');
    const hash = require('crypto').createHash('sha256').update(`pwreset|${t}`).digest('hex');
    const row = await this.repo.soda.findOne('users', { pwResetHash: hash });
    const user = row ? { ...row.value, key: row.key } : null;
    if (!user || !(Number(user.pwResetExp) > Date.now())) {
      if (user) await this.repo.updateUser(user.key, { pwResetHash: '', pwResetExp: 0 }).catch(() => null);
      throw new AuthError('This reset link is not valid any more. Ask for a new one.', 400, 'RESET_INVALID');
    }
    if (!newPassword || typeof newPassword !== 'string' || newPassword.length < 8) throw new AuthError('New password must be at least 8 characters.');
    if (newPassword.length > 200) throw new AuthError('Password must be at most 200 characters.');
    const weak = passwordProblem(newPassword, { email: user.email, name: user.name });
    if (weak) throw new ValidationError(weak, { newPassword: weak }, 422, 'WEAK_PASSWORD');
    const changedAt = Math.max(Date.now(), (Number(user.passwordChangedAt) || 0) + 1);
    const updated = await this.repo.updateUser(user.key, {
      passwordHash: await this.hasher.hash(newPassword), pwResetHash: '', pwResetExp: 0, mustChangePassword: false,
      passwordChangedAt: changedAt, tokensValidAfter: changedAt, loginFailures: 0, lockUntil: 0, lockCount: 0,
      // Round 4: the reset link proved the address, so a pending sign-up is verified by it.
      ...(user.emailVerified === false ? { emailVerified: true, emailVerifiedAt: Date.now(), emailVerifyHash: '', emailVerifyExp: 0 } : {}),
    });
    this._invalidate(user.userId);
    if (this.sessions) await this.sessions.revokeAllForUser(user.userId, 'PASSWORD_RESET');
    this._event('PASSWORD_CHANGED', updated || user, { reset: true });
    return { ok: true };
  }

  // ---- 3.57 re-authentication for sensitive actions ----
  /** Checks the password (or a Google ID token for Google accounts) of a signed-in user. Throws AuthError 401. */
  async verifyIdentity(userId, { password, idToken } = {}) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError(MSG_GONE, 404, 'ACCOUNT_GONE');
    if (typeof password === 'string' && password && user.passwordHash) {
      if ((await this.hasher.verify(password, user.passwordHash)).ok) return user;
      await this._failedSignIn(user.email || user.userId, user);
      throw new AuthError('That password is not right.', 403, 'REAUTH_FAILED');
    }
    if (typeof idToken === 'string' && idToken && this.google) {
      let payload;
      try { payload = (await this.google.verifyIdToken({ idToken, audience: config.googleClientIds })).getPayload(); } catch { payload = null; }
      const ok = payload && payload.email_verified && String(payload.email || '').toLowerCase() === String(user.email || '').toLowerCase()
        && (!user.googleSub || user.googleSub === payload.sub);
      if (ok) return user;
      throw new AuthError('Google could not confirm it is you.', 403, 'REAUTH_FAILED');
    }
    throw new AuthError('Enter your password to confirm it is you.', 403, 'REAUTH_FAILED');
  }

  // ---- 3.57 change of e-mail: re-authentication + confirmation link to the new address + notice to the old ----
  async requestEmailChange(userId, newEmail) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError(MSG_GONE, 404, 'ACCOUNT_GONE');
    if (user.provider === 'google') throw new AuthError('This account signs in with Google, so its e-mail is the Google address.', 409, 'GOOGLE_ACCOUNT');
    const clean = String(newEmail || '').trim().toLowerCase();
    if (!/^[^\s@<>()",;:]{1,64}@[a-z0-9.-]{1,253}\.[a-z]{2,24}$/.test(clean)) throw new ValidationError('Enter a valid e-mail address.', { email: 'Enter a valid e-mail address.' });
    if (clean === String(user.email || '').toLowerCase()) throw new ValidationError('That is already your e-mail address.', { email: 'That is already your e-mail address.' });
    // An address that is taken gets no mail and the same answer (no enumeration).
    if (await this.repo.findUserByEmail(clean)) return { user, token: null, newEmail: clean };
    const token = require('crypto').randomBytes(32).toString('base64url');
    const hash = require('crypto').createHash('sha256').update(`emailchange|${token}`).digest('hex');
    await this.repo.updateUser(user.key, { emailChangeHash: hash, emailChangeTo: clean, emailChangeExp: Date.now() + 30 * 60000 });
    return { user, token, newEmail: clean };
  }

  async confirmEmailChange(token) {
    const t = String(token || '');
    if (!/^[A-Za-z0-9_-]{40,60}$/.test(t)) throw new AuthError('This confirmation link is not valid any more.', 400, 'LINK_INVALID');
    const hash = require('crypto').createHash('sha256').update(`emailchange|${t}`).digest('hex');
    const row = await this.repo.soda.findOne('users', { emailChangeHash: hash });
    const user = row ? { ...row.value, key: row.key } : null;
    if (!user || !(Number(user.emailChangeExp) > Date.now()) || !user.emailChangeTo) throw new AuthError('This confirmation link is not valid any more.', 400, 'LINK_INVALID');
    const to = user.emailChangeTo;
    if (await this.repo.findUserByEmail(to)) {
      await this.repo.updateUser(user.key, { emailChangeHash: '', emailChangeTo: '', emailChangeExp: 0 });
      throw new AuthError('That e-mail address is not available.', 409, 'EMAIL_TAKEN');
    }
    const from = user.email;
    const updated = await this.repo.updateUser(user.key, { email: to, emailChangeHash: '', emailChangeTo: '', emailChangeExp: 0, emailChangedAt: Date.now(), tokensValidAfter: Date.now() });
    this._invalidate(user.userId);
    if (this.sessions) await this.sessions.revokeAllForUser(user.userId, 'EMAIL_CHANGED');
    this._event('EMAIL_CHANGED', updated || user, { from, to });
    return { ok: true, email: to };
  }

  // ---- 3.57 2-step verification (TOTP + recovery codes) ----
  async _userForMfaToken(mfaToken, { enroll = null } = {}) {
    const c = verifyMfaToken(mfaToken);
    if (!c) throw new AuthError('This sign-in step expired. Sign in again.', 401, 'MFA_EXPIRED');
    const user = await this.repo.findUserById(String(c.sub));
    if (!user || user.status === 'ON_HOLD' || user.status === 'BLOCKED') throw new AuthError('This sign-in step expired. Sign in again.', 401, 'MFA_EXPIRED');
    if ((Number(user.passwordChangedAt) || 0) !== (Number(c.pv) || 0)) throw new AuthError('This sign-in step expired. Sign in again.', 401, 'MFA_EXPIRED');
    if (enroll !== null && !!c.e !== enroll) throw new AuthError('This sign-in step expired. Sign in again.', 401, 'MFA_EXPIRED');
    return { user, kind: c.k };
  }

  /** Starts enrolment: a new secret (stored encrypted, pending until a code confirms it). */
  async mfaSetup(user) {
    const secret = totpLib.newSecret();
    await this.repo.updateUser(user.key, { mfaPendingSecret: secret, mfaPendingAt: Date.now() });
    return { secret, otpauthUrl: totpLib.otpauthUri({ secret, account: user.email || user.name }) };
  }

  /** Confirms enrolment with a first code: 2-step on, ten recovery codes (shown once). */
  async mfaConfirm(user, code) {
    const fresh = await this.repo.findUserById(user.userId);
    if (!fresh || !fresh.mfaPendingSecret || Date.now() - (Number(fresh.mfaPendingAt) || 0) > 15 * 60000) throw new AuthError('Start the set-up again.', 400, 'MFA_SETUP_EXPIRED');
    const step = totpLib.verifyTotp(fresh.mfaPendingSecret, code);
    if (step < 0) throw new AuthError('That code is not right. Check the time on your phone and try the newest code.', 401, 'MFA_CODE_WRONG');
    const rc = totpLib.newRecoveryCodes();
    const updated = await this.repo.updateUser(fresh.key, { mfaEnabled: true, mfaSecret: fresh.mfaPendingSecret, mfaPendingSecret: '', mfaPendingAt: 0, mfaLastStep: step, mfaRecovery: rc.hashes, mfaEnrolledAt: Date.now() });
    this._invalidate(user.userId);
    this._event('MFA_ENABLED', updated || fresh, {});
    return { user: updated || fresh, recoveryCodes: rc.codes };
  }

  /** Checks a TOTP code or a recovery code (single use). Returns the updated user or throws. */
  async mfaCheck(user, { code, recoveryCode, emailCode }) {
    // Round 4: an e-mailed code (operators without an authenticator app; never MASTER_ADMIN).
    if (emailCode) {
      const u0 = await this.repo.findUserById(user.userId);
      if (!u0 || !AuthService.mfaMethods(u0).includes('email')) throw new AuthError('Use the code from your authenticator app or a recovery code.', 403, 'MFA_EMAIL_NOT_ALLOWED');
      try {
        return await this.codes.verify(u0, 'mfa', emailCode);
      } catch (e) {
        if (e && e.code === 'CODE_WRONG') await this._failedSignIn(u0.email || u0.userId, u0);
        throw e;
      }
    }
    const fresh = await this.repo.findUserById(user.userId);
    if (!fresh || !fresh.mfaEnabled || !fresh.mfaSecret) throw new AuthError('2-step verification is not set up.', 400, 'MFA_NOT_SET');
    if (recoveryCode) {
      const i = totpLib.matchRecoveryCode(recoveryCode, fresh.mfaRecovery);
      if (i < 0) { await this._failedSignIn(fresh.email || fresh.userId, fresh); throw new AuthError('That recovery code is not right.', 401, 'MFA_CODE_WRONG'); }
      const left = fresh.mfaRecovery.filter((_, j) => j !== i);
      const u = await this.repo.updateUser(fresh.key, { mfaRecovery: left });
      this._event('MFA_RECOVERY_USED', u || fresh, { left: left.length });
      return u || fresh;
    }
    const step = totpLib.verifyTotp(fresh.mfaSecret, code, { lastStep: Number.isFinite(fresh.mfaLastStep) ? fresh.mfaLastStep : -1 });
    if (step < 0) { await this._failedSignIn(fresh.email || fresh.userId, fresh); throw new AuthError('That code is not right. Use the newest code from your authenticator app.', 401, 'MFA_CODE_WRONG'); }
    return (await this.repo.updateUser(fresh.key, { mfaLastStep: step })) || fresh;
  }

  /** Second sign-in step: { mfaToken, code | recoveryCode } -> a session that passed 2-step verification. */
  async mfaVerifyLogin({ mfaToken, code, recoveryCode, emailCode }, ctx = {}) {
    const { user, kind } = await this._userForMfaToken(mfaToken, { enroll: false });
    const u = await this.mfaCheck(user, { code, recoveryCode, emailCode });
    return this._issue(u, { ...ctx, client: kind }, { mfa: true });
  }

  /** Round 4: e-mails a 2-step code (sign-in step with an mfaToken, or a step-up of a signed-in session). */
  async mfaSendEmailCode(user, { where = 'signing in to CoRoute' } = {}) {
    const fresh = await this.repo.findUserById(user.userId);
    if (!fresh || !AuthService.mfaMethods(fresh).includes('email')) {
      throw new AuthError(fresh && fresh.role === ROLE_ADMIN ? 'Administrators use their authenticator app or a recovery code.' : 'E-mail codes are not turned on for this account.', 403, 'MFA_EMAIL_NOT_ALLOWED');
    }
    const out = await this.codes.issue(fresh, 'mfa');
    this._mail('mfa_email_code', fresh.email, { name: fresh.name, code: out.code, minutes: config.emailCodeTtlMin, where });
    return { ok: true, resendAfterSec: out.resendAfterSec, expiresInSec: config.emailCodeTtlMin * 60 };
  }

  async mfaSendEmailCodeLogin({ mfaToken }) {
    const { user, kind } = await this._userForMfaToken(mfaToken, { enroll: false });
    return this.mfaSendEmailCode(user, { where: kind === 'operator' ? 'the CoRoute operator console' : kind === 'admin' ? 'the CoRoute web admin' : 'signing in to CoRoute' });
  }

  /**
   * Round 4 step-up for a signed-in session (the app's admin screens answer MFA_REQUIRED): a TOTP, recovery or
   * e-mailed code marks this session as 2-step verified.
   */
  async mfaStepUp(userId, sessionId, { code, recoveryCode, emailCode } = {}) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError(MSG_GONE, 404, 'ACCOUNT_GONE');
    if (!AuthService.mfaMethods(user).length) {
      throw new AuthError('Set up 2-step verification first: sign in to the web admin on a computer (it asks you to set it up).', 403, 'MFA_NOT_SET');
    }
    await this.mfaCheck(user, { code, recoveryCode, emailCode });
    if (this.sessions && sessionId) await this.sessions.markMfa(sessionId);
    return { ok: true };
  }

  /** Round 4: an operator turns e-mailed 2-step codes on or off (needs a recent re-authentication; not for admins). */
  async mfaSetEmail(userId, enable) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError(MSG_GONE, 404, 'ACCOUNT_GONE');
    if (user.role === ROLE_ADMIN) throw new AuthError('Administrators use an authenticator app (with recovery codes).', 403, 'MFA_EMAIL_NOT_ALLOWED');
    const updated = await this.repo.updateUser(user.key, { mfaEmail: !!enable });
    this._invalidate(userId);
    this._event(enable ? 'MFA_ENABLED' : 'MFA_DISABLED', updated || user, {});
    return { ok: true, mfaEmail: !!enable };
  }

  async mfaEnrollStartLogin({ mfaToken }) {
    const { user } = await this._userForMfaToken(mfaToken, { enroll: true });
    return this.mfaSetup(user);
  }

  async mfaEnrollConfirmLogin({ mfaToken, code }, ctx = {}) {
    const { user, kind } = await this._userForMfaToken(mfaToken, { enroll: true });
    const { user: u, recoveryCodes } = await this.mfaConfirm(user, code);
    return { ...(await this._issue(u, { ...ctx, client: kind }, { mfa: true })), recoveryCodes };
  }

  async mfaDisable(userId) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError(MSG_GONE, 404, 'ACCOUNT_GONE');
    const updated = await this.repo.updateUser(user.key, { mfaEnabled: false, mfaSecret: '', mfaPendingSecret: '', mfaRecovery: [], mfaLastStep: -1 });
    this._invalidate(userId);
    this._event('MFA_DISABLED', updated || user, {});
    return { ok: true };
  }

  async mfaNewRecoveryCodes(userId) {
    const user = await this.repo.findUserById(userId);
    if (!user || !user.mfaEnabled) throw new AuthError('2-step verification is not set up.', 400, 'MFA_NOT_SET');
    const rc = totpLib.newRecoveryCodes();
    await this.repo.updateUser(user.key, { mfaRecovery: rc.hashes });
    return { recoveryCodes: rc.codes };
  }

  // ---- admin user management (roles are data, not code) ----
  async listUsers(limit = 500) {
    const rows = await this.repo.listUsers(limit);
    return rows.map(publicUser);
  }

  async setRole(actor, targetUserId, role) {
    if (![ROLE_ADMIN, ROLE_RIDER].includes(role)) throw new AuthError('Invalid role.');
    const target = await this.repo.findUserById(targetUserId);
    if (!target) throw new AuthError('User not found.', 404);
    if (role !== ROLE_ADMIN && target.role === ROLE_ADMIN) {
      const admins = await this.repo.countAdmins();
      if (admins <= 1) throw new AuthError('Cannot demote the last administrator.', 409);
    }
    const updated = await this.repo.updateUser(target.key, { role, roleChangedBy: actor.userId, roleChangedAt: Date.now() });
    this._invalidate(target.userId);
    // 3.57: losing a role ends every session of the account (sockets too). Gaining one needs no sign-out: rights are
    // read from the database on every call, and the web admin asks for 2-step verification at its own sign-in.
    if (target.role === ROLE_ADMIN && role !== ROLE_ADMIN && this.sessions) await this.sessions.revokeAllForUser(target.userId, 'ROLE_CHANGED', { by: actor.userId });
    return publicUser(updated);
  }

  async setUserStatus(actor, targetUserId, status, reason = '') {
    const cleanStatus = String(status || '').toUpperCase();
    if (!['ACTIVE', 'ON_HOLD', 'BLOCKED'].includes(cleanStatus)) throw new AuthError('Invalid user status.');
    const target = await this.repo.findUserById(targetUserId);
    if (!target) throw new AuthError('User not found.', 404);
    if (target.role === ROLE_ADMIN && cleanStatus !== 'ACTIVE') {
      throw new AuthError('Cannot place the master administrator on hold or blocked.', 403);
    }
    const updated = await this.repo.updateUser(target.key, {
      status: cleanStatus,
      statusChangedBy: actor.userId,
      statusChangedAt: Date.now(),
      statusReason: String(reason || '').trim().slice(0, 200),
    });
    this._invalidate(target.userId);
    // 3.57: on hold / blocked ends every session at once (REST and sockets).
    if (cleanStatus !== 'ACTIVE' && this.sessions) await this.sessions.revokeAllForUser(target.userId, `ACCOUNT_${cleanStatus}`, { by: actor.userId });
    return publicUser(updated);
  }

  /** A fresh session token for an already verified user (sliding refresh of long tokens; keeps the session). */
  issueToken(user, { sid = null, short = false } = {}) { return signToken(user, { sid, short }); }

  /** Runs the subscription hook (expiry rollback); never fails the caller. */
  /** 3.55 username allocation / invite hook; never fails the caller. */
  async _ready(user, ctx = {}) {
    if (!this.onUserReady || !user) return user;
    try { return (await this.onUserReady(user, ctx)) || user; } catch { return user; }
  }

  async _seen(user) {
    if (!this.onUserSeen || !user) return user;
    try { return (await this.onUserSeen(user)) || user; } catch { return user; }
  }

  async me(userId, { appBuild = 0, now = Date.now() } = {}) {
    let user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
    if (isLegacyGuest(user)) throw new AuthError(MSG_GUEST_RETIRED, 401, 'SESSION_INVALID');
    user = await this._ready(await this._seen(user));
    if (user.status === 'ON_HOLD') throw new AuthError(MSG_ON_HOLD, 403, 'ACCOUNT_ON_HOLD');
    if (user.status === 'BLOCKED') throw new AuthError(MSG_BLOCKED, 403, 'ACCOUNT_BLOCKED');
    // Which app build each rider uses, so the minimum build can be raised safely.
    // Written only when it changes, or once in 12 hours to keep "active" current.
    const build = Number.isInteger(appBuild) && appBuild > 0 && appBuild < 1000000 ? appBuild : 0;
    const patch = {};
    if (build && build !== user.appBuild) patch.appBuild = build;
    if (!user.lastActiveAt || now - user.lastActiveAt > 12 * 3600000) patch.lastActiveAt = now;
    // An address in BOOTSTRAP_ADMIN_EMAILS is an admin from its next app start, not only after a new sign-in.
    const role = user.email ? bootstrapRoleFor(user.email, user.role) : (user.role || ROLE_RIDER);
    if (role !== user.role) patch.role = role;
    if (Object.keys(patch).length) {
      await this.repo.updateUser(user.key, patch).catch(() => null);
      if (patch.role && this.gate) this.gate.invalidate(user.userId);
    }
    return selfUser({ ...user, role });
  }

  /**
   * App builds of riders active in the last [days] days. Builds before 65 do
   * not report themselves; they are counted as "older".
   */
  async appBuilds({ days = 30, now = Date.now(), minBuild = 0, latestBuild = 0 } = {}) {
    const since = now - days * 86400000;
    const active = (await this.repo.listUsers(5000)).filter((u) => (u.lastActiveAt || 0) >= since);
    const counts = new Map();
    let older = 0;
    for (const u of active) {
      if (u.appBuild) counts.set(u.appBuild, (counts.get(u.appBuild) || 0) + 1);
      else older++;
    }
    const builds = [...counts.entries()].sort((a, b) => b[0] - a[0]).map(([build, users]) => ({ build, users }));
    const total = active.length;
    const onLatest = latestBuild ? builds.filter((b) => b.build >= latestBuild).reduce((s, b) => s + b.users, 0) : 0;
    // Raising the minimum to B locks out everyone below B: report how many that would be for each reported build.
    const lockout = builds.map((b) => ({ build: b.build, wouldLockOut: older + builds.filter((x) => x.build < b.build).reduce((s, x) => s + x.users, 0) }));
    return { days, total, older, builds, onLatest, minBuild, latestBuild, lockout };
  }
}

/**
 * Express middleware factory: requires a valid Bearer token AND an account that
 * passes the gate (exists, ACTIVE, token not older than the last password change).
 * req.user is built from the database user, so role and name are always current.
 */
function requireAuth(gate) {
  return (req, res, next) => {
    const h = req.headers.authorization || '';
    const token = h.startsWith('Bearer ') ? h.slice(7) : null;
    const verified = token && verifyTokenDetailed(token, { allowExpired: true });
    if (!verified) return res.status(401).json({ error: MSG_SESSION, code: 'SESSION_INVALID' });
    const { claims } = verified;
    if (verified.expired) {
      // 3.57: a short access token ran out: the client refreshes (POST /api/auth/refresh) and repeats the call once.
      // A long token (older app builds) that ran out is a session that ended, as before.
      if (claims.typ === 'at') return res.status(401).json({ error: 'Your session needs to be refreshed.', code: 'TOKEN_EXPIRED' });
      return res.status(401).json({ error: MSG_SESSION, code: 'SESSION_INVALID' });
    }
    req.tokenIssuedAt = (claims.iat || 0) * 1000;
    req.tokenClaims = claims;
    req.tokenShort = claims.typ === 'at';
    req.sessionSid = claims.sid || null;
    // Signed with JWT_SECRET_PREVIOUS (rotation grace): accepted, and the client is moved to the new secret.
    req.tokenPreviousSecret = verified.previous;
    if (!gate) {
      req.user = { userId: claims.sub, name: claims.name, role: claims.role, email: claims.email };
      return next();
    }
    gate.checkDetailed(claims).then(async ({ user, session }) => {
      req.dbUser = user;
      req.user = identityOf(user);
      req.authSession = session;
      if (!claims.sid && gate.sessions) {
        // 3.57 silent migration: a token from before server sessions keeps working; it is bound to a new session
        // record now and the client (every app build adopts X-CoRoute-Token) continues with the session-bound one.
        try {
          const sid = await migrateLegacyToken(gate, user, token, req);
          if (sid) { req.sessionSid = sid; res.set('X-CoRoute-Token', signToken(user, { sid })); }
        } catch { /* never in the way: the old token still works until it expires */ }
      } else if (verified.previous) {
        try { res.set('X-CoRoute-Token', signToken(user, { sid: claims.sid || null, short: req.tokenShort })); } catch { /* never in the way */ }
      }
      next();
    }, (e) => {
      if (e instanceof AuthError) return res.status(e.status).json({ error: e.message, code: e.code });
      next(e);
    });
  };
}

/** One session per pre-3.57 token (remembered per node for 10 minutes so parallel calls do not create several). */
async function migrateLegacyToken(gate, user, token, req) {
  const crypto2 = require('crypto');
  if (!gate._migrated) gate._migrated = new Map();
  const key = crypto2.createHash('sha256').update(token).digest('hex');
  const hit = gate._migrated.get(key);
  if (hit && Date.now() - hit.at < 600000) return hit.pending ? hit.pending : hit.sid;
  const pending = gate.sessions.create({ user, kind: 'legacy', device: { label: '', platform: '' }, ip: req.ip, ua: req.get ? req.get('user-agent') : '' })
    .then((r) => r.session.sessionId);
  gate._migrated.set(key, { at: Date.now(), sid: null, pending });
  const sid = await pending;
  gate._migrated.set(key, { at: Date.now(), sid });
  while (gate._migrated.size > 5000) gate._migrated.delete(gate._migrated.keys().next().value);
  return sid;
}

/**
 * Whether this request's admin call needs a 2-step session (ADMIN_MFA_ENFORCE, src/config.js):
 * 'all' (default): sessions of clients that can ask for a code (app >= 10025 'app', 'admin', 'operator', 'web');
 * older app builds ('legacy' sessions, tokens from before sessions) keep 'web'. 'strict': every session. 'web' / 'off': none.
 */
function adminMfaRequired(req) {
  const mode = config.adminMfaEnforce;
  if (req.authSession === undefined) return false; // no session store (unit tests of bare routers)
  if (mode === 'strict') return true;
  if (mode !== 'all') return false;
  const s = req.authSession;
  return !!s && s.kind !== 'legacy';
}

function requireAdmin(req, res, next) {
  if (req.user?.role !== ROLE_ADMIN) return res.status(403).json({ error: 'Admin only' });
  if (adminMfaRequired(req) && !(req.authSession && req.authSession.mfa)) {
    const u = req.dbUser || {};
    // Round 4: the app shows its 2-step prompt on this code (POST /api/auth/mfa/step-up), the web admin signs in again.
    return res.status(403).json({ error: 'Enter your 2-step verification code to use admin tools.', code: 'MFA_REQUIRED',
      mfaEnrolled: !!u.mfaEnabled, methods: AuthService.mfaMethods(u) });
  }
  next();
}

module.exports = { adminMfaRequired, signMfaToken, verifyMfaToken, migrateLegacyToken, isLegacyGuest, MSG_GUEST_RETIRED, realContactNumber, ROSTER_KEYS, ASSIST_KEYS, AuthService, AuthError, UserGate, identityOf, requireAuth, requireAdmin, signToken, verifyToken, verifyTokenDetailed, publicUser, selfUser, ROLE_ADMIN, ROLE_RIDER, slug };
