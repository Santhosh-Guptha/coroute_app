'use strict';
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { OAuth2Client } = require('google-auth-library');
const config = require('./config');
const { profileFields, ValidationError, SWITCHES } = require('./validate');

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
    // Nearby-rider assistance (3.15): owner only, never in publicUser.
    assistHelp: u.assistHelp !== false,
    assistAsk: u.assistAsk !== false,
    responderMedical: u.responderMedical === true,
    netConsentAt: Number(u.netConsentAt) || 0,
  };
}

/** Profile keys that change what the ride group's SMS roster holds. */
const ROSTER_KEYS = ['phone', 'emergencyContact', 'emergencyContactName', 'smsOptOut'];
/** Profile keys the safety network reads from the live rider record (3.15, server only, no ROSTER_CHANGED). */
const ASSIST_KEYS = ['assistHelp', 'assistAsk', 'responderMedical'];

function signToken(user) {
  return jwt.sign(
    // pv: the password version this token was issued for; a later password change ends it.
    { sub: user.userId, name: user.name, role: user.role, email: user.email, pv: Number(user.passwordChangedAt) || 0 },
    config.jwtSecret,
    { expiresIn: `${config.jwtTtlDays}d`, issuer: 'coroute-gateway' },
  );
}

function verifyToken(token) {
  try {
    return jwt.verify(token, config.jwtSecret, { issuer: 'coroute-gateway' });
  } catch {
    return null;
  }
}

const MSG_ON_HOLD = 'Your account has been placed on hold by the administrator.';
const MSG_BLOCKED = 'Your account has been blocked by the administrator.';
const MSG_GONE = 'This account no longer exists.';
const MSG_SESSION = 'Your session has ended. Please sign in again.';

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
  constructor(repo, { ttlMs = config.userGateTtlMs, maxEntries = 5000, clock = () => Date.now() } = {}) {
    this.repo = repo; this.ttlMs = ttlMs; this.maxEntries = maxEntries; this.clock = clock;
    this.cache = new Map(); // userId -> { user, at }
    this.inflight = new Map(); // userId -> Promise<user|null> (one DB read per user at a time)
    this.reads = 0;
  }

  invalidate(userId) {
    if (!userId) return;
    this.cache.delete(userId);
    this.inflight.delete(userId);
  }

  async _load(userId) {
    const hit = this.cache.get(userId);
    if (hit && this.clock() - hit.at < this.ttlMs) return hit.user;
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
    const userId = claims && claims.sub;
    if (!userId) throw new AuthError(MSG_SESSION, 401, 'SESSION_INVALID');
    const user = await this._load(String(userId));
    // 404 keeps what GET /me has always answered for a deleted account; the app signs out on the code.
    if (!user) throw new AuthError(MSG_GONE, 404, 'ACCOUNT_GONE');
    if (user.status === 'ON_HOLD') throw new AuthError(MSG_ON_HOLD, 403, 'ACCOUNT_ON_HOLD');
    if (user.status === 'BLOCKED') throw new AuthError(MSG_BLOCKED, 403, 'ACCOUNT_BLOCKED');
    const issuedMs = (Number(claims.iat) || 0) * 1000;
    // A token older than the account belongs to an earlier account that had the same userId.
    if (user.createdAt && issuedMs + 1000 < user.createdAt) throw new AuthError(MSG_SESSION, 401, 'SESSION_INVALID');
    const changed = Number(user.passwordChangedAt) || 0;
    if (changed) {
      const stale = claims.pv !== undefined ? changed > (Number(claims.pv) || 0) : changed > issuedMs + 1000;
      if (stale) throw new AuthError(MSG_SESSION, 401, 'SESSION_INVALID');
    }
    return user;
  }
}

/** The request identity, always from the database (role and name included), never from the token. */
function identityOf(user) {
  return { userId: user.userId, name: user.name, role: user.email ? bootstrapRoleFor(user.email, user.role) : (user.role || ROLE_RIDER), email: user.email };
}

class AuthService {
  /** @param {import('./oracle/repo').Repo} repo */
  constructor(repo, { googleVerifier, gate = null } = {}) {
    this.repo = repo;
    this.gate = gate;
    /** (user, changedKeys) => void: set by app.js so a live ride hears about phone / opt-out changes. */
    this.onProfileChanged = null;
    this.google = googleVerifier || (config.googleClientIds.length ? new OAuth2Client() : null);
  }

  _invalidate(userId) { if (this.gate) this.gate.invalidate(userId); }

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

  async register({ name, email, password, phone, vehicleType, vehicleNo, emergencyContact, emergencyContactName }) {
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
    if (await this.repo.findUserByEmail(clean.email)) throw new AuthError('This email is already registered. Please sign in.', 409);
    // The callsign is a sign-in name, so it must be unique.
    if (await this.repo.findUserByName(clean.name)) throw new ValidationError('That callsign is taken. Choose another one.', { name: 'That callsign is taken.' }, 409, 'CALLSIGN_TAKEN');

    const pillion = (clean.vehicleType || '').toLowerCase() === 'pillion rider' || clean.vehicleNo === 'PILLION';
    const cleanVehicleType = pillion ? 'Pillion Rider' : (clean.vehicleType || 'Motorcycle');
    const cleanVehicleNo = pillion ? 'PILLION' : (clean.vehicleNo || '');

    const user = await this.repo.createUser({
      userId: await this._uniqueUserId(clean.name),
      name: clean.name,
      email: clean.email,
      passwordHash: await bcrypt.hash(password, 10),
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
    return { token: signToken(user), user: selfUser(user) };
  }

  async login({ identifier, password }) {
    const id = typeof identifier === 'string' ? identifier.trim() : '';
    if (!id || !password || typeof password !== 'string') throw new AuthError('Email/callsign and password are required.');
    const user = id.includes('@') ? await this.repo.findUserByEmail(id) : await this.repo.findUserByName(id);
    // Constant-ish time: always run a compare.
    const ok = user?.passwordHash ? await bcrypt.compare(password, user.passwordHash) : (await bcrypt.compare(password, '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ012345'), false);
    if (!user || !ok) throw new AuthError('Invalid credentials.', 401);
    if (user.status === 'ON_HOLD') throw new AuthError(MSG_ON_HOLD, 403, 'ACCOUNT_ON_HOLD');
    if (user.status === 'BLOCKED') throw new AuthError(MSG_BLOCKED, 403, 'ACCOUNT_BLOCKED');
    const role = bootstrapRoleFor(user.email, user.role);
    const updated = await this.repo.updateUser(user.key, { lastLoginAt: Date.now(), role }) || user;
    return { token: signToken(updated), user: selfUser(updated) };
  }

  async loginWithGoogle({ idToken }) {
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
    } else {
      if (user.status === 'ON_HOLD') throw new AuthError(MSG_ON_HOLD, 403, 'ACCOUNT_ON_HOLD');
      if (user.status === 'BLOCKED') throw new AuthError(MSG_BLOCKED, 403, 'ACCOUNT_BLOCKED');
      user = await this.repo.updateUser(user.key, { lastLoginAt: Date.now(), role: bootstrapRoleFor(email, user.role), googleSub: payload.sub }) || user;
    }
    return { token: signToken(user), user: selfUser(user) };
  }

  async changePassword(userId, { currentPassword, newPassword }) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
    if (!newPassword || typeof newPassword !== 'string' || newPassword.length < 8) throw new AuthError('New password must be at least 8 characters.');
    if (newPassword.length > 200) throw new AuthError('Password must be at most 200 characters.');
    if (user.passwordHash) {
      const ok = typeof currentPassword === 'string' && currentPassword && await bcrypt.compare(currentPassword, user.passwordHash);
      if (!ok && !user.mustChangePassword) throw new AuthError('Current password is incorrect.', 401);
    }
    // Bumping passwordChangedAt ends every other session; this device gets a fresh token.
    const changedAt = Math.max(Date.now(), (Number(user.passwordChangedAt) || 0) + 1);
    const updated = await this.repo.updateUser(user.key, { passwordHash: await bcrypt.hash(newPassword, 10), mustChangePassword: false, passwordChangedAt: changedAt });
    this._invalidate(userId);
    return { ok: true, token: signToken(updated || { ...user, passwordChangedAt: changedAt }) };
  }

  /** Admin-assisted reset (no e-mail infrastructure needed): returns a one-time temporary password. */
  async adminResetPassword(actor, targetUserId) {
    const target = await this.repo.findUserById(targetUserId);
    if (!target) throw new AuthError('User not found.', 404);
    const temp = crypto.randomBytes(9).toString('base64url').replace(/[-_]/g, 'x').slice(0, 12);
    await this.repo.updateUser(target.key, {
      passwordHash: await bcrypt.hash(temp, 10), mustChangePassword: true, passwordResetBy: actor.userId, passwordResetAt: Date.now(),
      passwordChangedAt: Math.max(Date.now(), (Number(target.passwordChangedAt) || 0) + 1),
    });
    this._invalidate(target.userId);
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
    return { ok: true };
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
    // On/off switches (smsOptOut, 3.15 assistHelp / assistAsk / responderMedical).
    // Type checked even when unchanged, so a wrong client learns about it.
    const defaults = { smsOptOut: false, assistHelp: true, assistAsk: true, responderMedical: false };
    for (const k of SWITCHES) {
      if (patch[k] === undefined || patch[k] === null) continue;
      if (typeof patch[k] !== 'boolean') throw new ValidationError('This field must be on or off.', { [k]: 'This field must be on or off.' });
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
    const updated = Object.keys(clean).length ? await this.repo.updateUser(user.key, clean) : user;
    this._invalidate(userId);
    const keys = [...ROSTER_KEYS, ...ASSIST_KEYS].filter((k) => clean[k] !== undefined && clean[k] !== user[k]);
    if (keys.length && updated && this.onProfileChanged) {
      try { await this.onProfileChanged(updated, keys); } catch { /* the profile is saved; the ride catches up on the next join */ }
    }
    return selfUser(updated);
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
    return publicUser(updated);
  }

  /** A fresh session token for an already verified user (sliding refresh). */
  issueToken(user) { return signToken(user); }

  async me(userId, { appBuild = 0, now = Date.now() } = {}) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
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
    const claims = token && verifyToken(token);
    if (!claims) return res.status(401).json({ error: MSG_SESSION, code: 'SESSION_INVALID' });
    req.tokenIssuedAt = (claims.iat || 0) * 1000;
    if (!gate) {
      req.user = { userId: claims.sub, name: claims.name, role: claims.role, email: claims.email };
      return next();
    }
    gate.check(claims).then((user) => {
      req.dbUser = user;
      req.user = identityOf(user);
      next();
    }, (e) => {
      if (e instanceof AuthError) return res.status(e.status).json({ error: e.message, code: e.code });
      next(e);
    });
  };
}

function requireAdmin(req, res, next) {
  if (req.user?.role !== ROLE_ADMIN) return res.status(403).json({ error: 'Admin only' });
  next();
}

module.exports = { ROSTER_KEYS, ASSIST_KEYS, AuthService, AuthError, UserGate, identityOf, requireAuth, requireAdmin, signToken, verifyToken, publicUser, selfUser, ROLE_ADMIN, ROLE_RIDER, slug };
