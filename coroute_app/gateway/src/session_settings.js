'use strict';
/**
 * v3.62 phone sign-in policy, set in the web admin (Security > Phone sign-in), never by a VM file edit.
 *
 *   appIdleDays      0 = never signed out for being unused, else days without opening the app (1-365)
 *   appAbsoluteDays  0 = no maximum age, else days after sign-in (1-3650; extended while riding / during an SOS)
 *
 * A saved policy applies ONLY to phone sign-ins made after the save: each new app session carries a copy
 * (`appPol` on the session record, src/sessions.js). Riders who are signed in keep the rule they signed in with, so a
 * change here never signs out existing users. Sessions without a copy (every session made before v3.62) have no time
 * limit at all, whatever SESSION_APP_* says in the VM .env (those values are only the default until an admin saves).
 *
 * GET /api/admin/session-settings, PUT /api/admin/session-settings {appIdleDays, appAbsoluteDays} (MASTER_ADMIN,
 * audited). One cached copy per node (re-read every 30 s).
 */
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { COLLECTIONS: C } = require('./oracle/repo');

const DOC_KEY = 'session_policy';
const TTL_MS = 30000;
const LIMITS = Object.freeze({ appIdleDays: [0, 365], appAbsoluteDays: [0, 3650] });

class SessionSettingsError extends Error {
  constructor(message, field) { super(message); this.name = 'SessionSettingsError'; this.code = 'INVALID'; this.field = field; }
}

function envDefaults(c = config) {
  const clamp = (v, [lo, hi]) => Math.max(lo, Math.min(hi, Math.round(Number(v) || 0)));
  return { appIdleDays: clamp(c.sessionAppIdleDays, LIMITS.appIdleDays), appAbsoluteDays: clamp(c.sessionAppAbsoluteDays, LIMITS.appAbsoluteDays) };
}

function clean(raw, c = config) {
  const d = envDefaults(c);
  if (!raw || typeof raw !== 'object') return { ...d, saved: false, updatedAt: 0, updatedBy: '' };
  const out = { saved: true, updatedAt: Number(raw.updatedAt) || 0, updatedBy: String(raw.updatedBy || '').slice(0, 120) };
  for (const [k, [lo, hi]] of Object.entries(LIMITS)) {
    const n = Number(raw[k]);
    out[k] = Number.isFinite(n) ? Math.max(lo, Math.min(hi, Math.round(n))) : d[k];
  }
  return out;
}

function validate(body) {
  const b = body && typeof body === 'object' ? body : {};
  const out = {};
  for (const [k, [lo, hi]] of Object.entries(LIMITS)) {
    const n = Number(b[k]);
    if (!Number.isInteger(n) || n < lo || n > hi) throw new SessionSettingsError(`${k} must be a whole number from ${lo} to ${hi} (0 = no limit).`, k);
    out[k] = n;
  }
  return out;
}

class SessionSettings {
  constructor({ repo, logger = console, c = config } = {}) {
    this.repo = repo; this.log = logger; this.c = c;
    this.cfg = clean(null, c); this.at = 0;
  }

  async get() {
    if (Date.now() - this.at < TTL_MS) return this.cfg;
    try {
      const r = await this.repo.soda.findOne(C.subscriptionConfig, { k: DOC_KEY });
      this.cfg = clean(r ? r.value : null, this.c);
      this.at = Date.now();
    } catch { /* keep the last known policy */ }
    return this.cfg;
  }

  /** The policy a NEW phone session gets (days; 0 = no limit). */
  async appPolicy() {
    const p = await this.get();
    return { idleDays: p.appIdleDays, absDays: p.appAbsoluteDays };
  }

  async save(next, by) {
    const doc = { k: DOC_KEY, ...next, updatedAt: Date.now(), updatedBy: String(by || 'admin').slice(0, 120) };
    await this.repo.soda.upsertBy(C.subscriptionConfig, { k: DOC_KEY }, doc);
    this.cfg = clean(doc, this.c); this.at = Date.now();
    return this.cfg;
  }
}

function registerSessionSettingsRoutes({ r, settings, repo, wrap, requireAdmin, sessions = null }) {
  const adminLimit = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `ss:${req.user ? req.user.userId : req.ip}` });
  const view = async () => {
    const p = await settings.get();
    const env = envDefaults(settings.c);
    return {
      ok: true, ...p, limits: LIMITS, env,
      appliesTo: 'new',
      note: 'Applies only to phone sign-ins made after you save. Riders already signed in keep the rule they signed in with.',
      reuseGraceAppSec: settings.c.refreshReuseGraceAppSec,
      sweepKeepsLiveAppSessions: true,
      ...(sessions && typeof sessions.countLiveApp === 'function' ? { liveAppSessions: await sessions.countLiveApp().catch(() => null) } : {}),
    };
  };
  r.get('/admin/session-settings', requireAdmin, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store').json(await view());
  }));
  r.put('/admin/session-settings', requireAdmin, adminLimit, wrap(async (req, res) => {
    if (!req.user || req.user.role !== 'MASTER_ADMIN') return res.status(403).json({ error: 'Only a master admin can change sign-in rules.', code: 'FORBIDDEN' });
    let next;
    try { next = validate(req.body); } catch (e) { if (e instanceof SessionSettingsError) return res.status(400).json({ error: e.message, code: e.code, field: e.field }); throw e; }
    const by = req.user.email || req.user.userId || 'admin';
    await settings.save(next, by);
    if (typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({ by, byUserId: req.user.userId, action: 'sessions.app_policy.update', target: 'session_policy', details: next, at: Date.now() }).catch(() => {});
    }
    res.json(await view());
  }));
}

module.exports = { SessionSettings, registerSessionSettingsRoutes, DOC_KEY, LIMITS, clean, validate, envDefaults, SessionSettingsError };
