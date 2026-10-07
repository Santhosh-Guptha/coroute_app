'use strict';
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { OAuth2Client } = require('google-auth-library');
const config = require('./config');

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

function publicUser(u) {
  return {
    userId: u.userId,
    name: u.name,
    email: u.email,
    role: u.role,
    status: u.status || 'ACTIVE',
    statusReason: u.statusReason || '',
    statusChangedAt: u.statusChangedAt || 0,
    phone: u.phone || '',
    vehicleType: u.vehicleType || 'Motorcycle',
    vehicleNo: u.vehicleNo || '',
    emergencyContact: u.emergencyContact || '',
    emergencyContactName: u.emergencyContactName || '',
    provider: u.provider || 'password',
    createdAt: u.createdAt || 0,
    lastActiveAt: u.lastActiveAt || u.lastLoginAt || 0,
    mustChangePassword: !!u.mustChangePassword,
  };
}

function signToken(user) {
  return jwt.sign(
    { sub: user.userId, name: user.name, role: user.role, email: user.email },
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

class AuthService {
  /** @param {import('./oracle/repo').Repo} repo */
  constructor(repo, { googleVerifier } = {}) {
    this.repo = repo;
    this.google = googleVerifier || (config.googleClientIds.length ? new OAuth2Client() : null);
  }

  async _uniqueUserId(name) {
    const base = `usr_${slug(name)}`;
    if (!(await this.repo.findUserById(base))) return base;
    for (;;) {
      const candidate = `${base}_${crypto.randomBytes(2).toString('hex')}`;
      if (!(await this.repo.findUserById(candidate))) return candidate;
    }
  }

  async register({ name, email, password, phone, vehicleType, vehicleNo, emergencyContact, emergencyContactName }) {
    const cleanName = (name || '').trim();
    const cleanEmail = (email || '').trim().toLowerCase();
    if (cleanName.length < 2) throw new AuthError('Callsign / full name is required.');
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(cleanEmail)) throw new AuthError('A valid email address is required.');
    if (!password || password.length < 8) throw new AuthError('Password must be at least 8 characters.');
    if (!(phone || '').trim()) throw new AuthError('Mobile phone number is required.');
    if (await this.repo.findUserByEmail(cleanEmail)) throw new AuthError('This email is already registered. Please sign in.', 409);

    const user = await this.repo.createUser({
      userId: await this._uniqueUserId(cleanName),
      name: cleanName,
      email: cleanEmail,
      passwordHash: await bcrypt.hash(password, 10),
      role: bootstrapRoleFor(cleanEmail),
      provider: 'password',
      phone: phone.trim(),
      vehicleType: (vehicleType || 'Motorcycle').trim(),
      vehicleNo: (vehicleNo || '').trim().toUpperCase(),
      emergencyContact: (emergencyContact || '').trim(),
      emergencyContactName: (emergencyContactName || '').trim(),
      createdAt: Date.now(),
      lastLoginAt: Date.now(),
    });
    return { token: signToken(user), user: publicUser(user) };
  }

  async login({ identifier, password }) {
    const id = (identifier || '').trim();
    if (!id || !password) throw new AuthError('Email/callsign and password are required.');
    const user = id.includes('@') ? await this.repo.findUserByEmail(id) : await this.repo.findUserByName(id);
    // Constant-ish time: always run a compare.
    const ok = user?.passwordHash ? await bcrypt.compare(password, user.passwordHash) : (await bcrypt.compare(password, '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ012345'), false);
    if (!user || !ok) throw new AuthError('Invalid credentials.', 401);
    if (user.status === 'ON_HOLD') throw new AuthError('Your account has been placed on hold by the administrator.', 403, 'ACCOUNT_ON_HOLD');
    if (user.status === 'BLOCKED') throw new AuthError('Your account has been blocked by the administrator.', 403, 'ACCOUNT_BLOCKED');
    const role = bootstrapRoleFor(user.email, user.role);
    const updated = await this.repo.updateUser(user.key, { lastLoginAt: Date.now(), role }) || user;
    return { token: signToken(updated), user: publicUser(updated) };
  }

  async loginWithGoogle({ idToken }) {
    if (!this.google) throw new AuthError('Google Sign-In is not configured on this server.', 501);
    if (!idToken) throw new AuthError('idToken is required.');
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
      if (user.status === 'ON_HOLD') throw new AuthError('Your account has been placed on hold by the administrator.', 403, 'ACCOUNT_ON_HOLD');
      if (user.status === 'BLOCKED') throw new AuthError('Your account has been blocked by the administrator.', 403, 'ACCOUNT_BLOCKED');
      user = await this.repo.updateUser(user.key, { lastLoginAt: Date.now(), role: bootstrapRoleFor(email, user.role), googleSub: payload.sub }) || user;
    }
    return { token: signToken(user), user: publicUser(user) };
  }

  async changePassword(userId, { currentPassword, newPassword }) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
    if (!newPassword || newPassword.length < 8) throw new AuthError('New password must be at least 8 characters.');
    if (user.passwordHash) {
      const ok = currentPassword && await bcrypt.compare(currentPassword, user.passwordHash);
      if (!ok && !user.mustChangePassword) throw new AuthError('Current password is incorrect.', 401);
    }
    await this.repo.updateUser(user.key, { passwordHash: await bcrypt.hash(newPassword, 10), mustChangePassword: false, passwordChangedAt: Date.now() });
    return { ok: true };
  }

  /** Admin-assisted reset (no e-mail infrastructure needed): returns a one-time temporary password. */
  async adminResetPassword(actor, targetUserId) {
    const target = await this.repo.findUserById(targetUserId);
    if (!target) throw new AuthError('User not found.', 404);
    const temp = crypto.randomBytes(9).toString('base64url').replace(/[-_]/g, 'x').slice(0, 12);
    await this.repo.updateUser(target.key, {
      passwordHash: await bcrypt.hash(temp, 10), mustChangePassword: true, passwordResetBy: actor.userId, passwordResetAt: Date.now(),
    });
    return { temporaryPassword: temp, userId: target.userId, name: target.name };
  }

  async deleteAccount(userId) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
    if (user.role === ROLE_ADMIN && (await this.repo.countAdmins()) <= 1) {
      throw new AuthError('Promote another administrator before deleting the last admin account.', 409);
    }
    await this.repo.deleteUserCascade(user);
    return { ok: true };
  }

  async updateProfile(userId, patch) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
    const allowed = ['phone', 'vehicleType', 'vehicleNo', 'emergencyContact', 'emergencyContactName'];
    const clean = {};
    for (const k of allowed) if (patch[k] !== undefined) clean[k] = String(patch[k]).trim();
    if (clean.vehicleNo) clean.vehicleNo = clean.vehicleNo.toUpperCase();
    const updated = await this.repo.updateUser(user.key, clean);
    return publicUser(updated);
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
      statusReason: String(reason || '').trim(),
    });
    return publicUser(updated);
  }

  /** A fresh session token for an already verified user (sliding refresh). */
  issueToken(user) { return signToken(user); }

  async me(userId, { appBuild = 0, now = Date.now() } = {}) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('This account no longer exists.', 404, 'ACCOUNT_GONE');
    if (user.status === 'ON_HOLD') throw new AuthError('Your account has been placed on hold by the administrator.', 403, 'ACCOUNT_ON_HOLD');
    if (user.status === 'BLOCKED') throw new AuthError('Your account has been blocked by the administrator.', 403, 'ACCOUNT_BLOCKED');
    // Which app build each rider uses, so the minimum build can be raised safely.
    // Written only when it changes, or once in 12 hours to keep "active" current.
    const build = Number.isInteger(appBuild) && appBuild > 0 && appBuild < 1000000 ? appBuild : 0;
    const patch = {};
    if (build && build !== user.appBuild) patch.appBuild = build;
    if (!user.lastActiveAt || now - user.lastActiveAt > 12 * 3600000) patch.lastActiveAt = now;
    if (Object.keys(patch).length) await this.repo.updateUser(user.key, patch).catch(() => null);
    return publicUser(user);
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

/** Express middleware: requires a valid Bearer token. */
function requireAuth(req, res, next) {
  const h = req.headers.authorization || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : null;
  const claims = token && verifyToken(token);
  if (!claims) return res.status(401).json({ error: 'Your session has ended. Please sign in again.', code: 'SESSION_INVALID' });
  req.tokenIssuedAt = (claims.iat || 0) * 1000;
  req.user = { userId: claims.sub, name: claims.name, role: claims.role, email: claims.email };
  next();
}

function requireAdmin(req, res, next) {
  if (req.user?.role !== ROLE_ADMIN) return res.status(403).json({ error: 'Admin only' });
  next();
}

module.exports = { AuthService, AuthError, requireAuth, requireAdmin, signToken, verifyToken, ROLE_ADMIN, ROLE_RIDER, slug };
