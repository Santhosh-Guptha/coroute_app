'use strict';
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { OAuth2Client } = require('google-auth-library');
const config = require('./config');

const ROLE_ADMIN = 'MASTER_ADMIN';
const ROLE_RIDER = 'RIDER';

class AuthError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; this.name = 'AuthError'; }
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
    phone: u.phone || '',
    vehicleType: u.vehicleType || 'Motorcycle',
    vehicleNo: u.vehicleNo || '',
    emergencyContact: u.emergencyContact || '',
    emergencyContactName: u.emergencyContactName || '',
    provider: u.provider || 'password',
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
      user = await this.repo.updateUser(user.key, { lastLoginAt: Date.now(), role: bootstrapRoleFor(email, user.role), googleSub: payload.sub }) || user;
    }
    return { token: signToken(user), user: publicUser(user) };
  }

  async updateProfile(userId, patch) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('User not found.', 404);
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

  async me(userId) {
    const user = await this.repo.findUserById(userId);
    if (!user) throw new AuthError('User not found.', 404);
    return publicUser(user);
  }
}

/** Express middleware: requires a valid Bearer token. */
function requireAuth(req, res, next) {
  const h = req.headers.authorization || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : null;
  const claims = token && verifyToken(token);
  if (!claims) return res.status(401).json({ error: 'Unauthorized' });
  req.user = { userId: claims.sub, name: claims.name, role: claims.role, email: claims.email };
  next();
}

function requireAdmin(req, res, next) {
  if (req.user?.role !== ROLE_ADMIN) return res.status(403).json({ error: 'Admin only' });
  next();
}

module.exports = { AuthService, AuthError, requireAuth, requireAdmin, signToken, verifyToken, ROLE_ADMIN, ROLE_RIDER, slug };
