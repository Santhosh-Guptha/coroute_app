'use strict';
/**
 * 3.55 platform: admin warnings delivered to riders.
 *
 * "Warn" on a public-ride report used to be recorded only (a WARNED row in the contact log). Now the
 * reported rider also gets the warning:
 *  - stored on their user document (`pendingWarnings`, at most MAX_PENDING, newest last) until they
 *    acknowledge it, so a rider who is offline sees it on the next app start;
 *  - pushed at once over the socket ({ type: 'ADMIN_WARNING', id, message, at }) when they are online
 *    (on either gateway VM: Hub.sendToUser relays to the peer).
 * Rider API: GET /api/me/warnings, POST /api/me/warnings/:id/ack.
 *
 * The admin console types the text (required, at most MESSAGE_MAX characters, validated by
 * validateWarnMessage; the default line stays as a quick option there). An older console that sends
 * no `message` still gets DEFAULT_MESSAGE.
 *
 * Rules: admins only (the caller is the admin router), plain text (control characters removed,
 * spaces collapsed, at most MESSAGE_MAX characters; never HTML), audited (ids and codes only, never
 * the text), switchable with the admin feature switch `adminWarnings` (off: the warning is still
 * recorded on the report as before, nothing is delivered and the rider list reads empty).
 */
const crypto = require('crypto');

const MESSAGE_MAX = 280;
const MAX_PENDING = 5;
const DEFAULT_MESSAGE = 'Please follow the public ride guidelines: be respectful and share only ride and road safety information.';
const ID_RE = /^AW-[0-9A-F]{12}$/;
const FLAG = 'adminWarnings';

/** Plain text only: control / zero-width characters removed, spaces collapsed, capped. Empty -> ''. */
function cleanMessage(raw) {
  if (typeof raw !== 'string') return '';
  const text = raw
    .replace(/[\u0000-\u001F\u007F\u200B-\u200F\u2028-\u202E\u2060-\u206F]/g, ' ')
    .replace(/[<>]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return text.length > MESSAGE_MAX ? `${text.slice(0, MESSAGE_MAX - 1).trimEnd()}…` : text;
}

/**
 * The admin's typed "Warn" text (admin console text box): required, trimmed, plain text after
 * cleaning, at most MESSAGE_MAX characters (refused, never cut, so the preview is what the rider
 * reads). Returns { ok: true, message } or { ok: false, code, error }.
 */
function validateWarnMessage(raw) {
  if (typeof raw !== 'string') return { ok: false, code: 'WARN_MESSAGE_REQUIRED', error: 'Type the warning the rider will see.' };
  const text = raw
    .replace(/[\u0000-\u001F\u007F\u200B-\u200F\u2028-\u202E\u2060-\u206F]/g, ' ')
    .replace(/[<>]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (!text) return { ok: false, code: 'WARN_MESSAGE_REQUIRED', error: 'Type the warning the rider will see.' };
  if (text.length > MESSAGE_MAX) return { ok: false, code: 'WARN_MESSAGE_TOO_LONG', error: `Use at most ${MESSAGE_MAX} characters for the warning.` };
  return { ok: true, message: text };
}

/** What the rider sees of a stored warning (no admin identity). */
const view = (w) => ({ id: w.id, message: w.message, at: w.at });

class AdminWarnings {
  constructor({ repo, hub = null, audit = null, flagsOf = () => null, clock = Date.now, logger = console } = {}) {
    this.repo = repo; this.hub = hub; this.audit = audit; this.flagsOf = flagsOf; this.clock = clock; this.log = logger;
  }

  /** The admin switch (unknown / no switches = on). */
  enabled() {
    try { const fl = this.flagsOf(); return !fl || fl.isOn(FLAG); } catch { return true; }
  }

  _audit(row) { try { if (this.audit) this.audit.add({ kind: 'ADMIN_WARNING', ...row }); } catch { /* never in the way */ } }

  /**
   * Stores and pushes a warning to `userId`. Returns { ok, delivered, warning } or { ok: false, reason }.
   * `ref` is the report id (kept with the warning for the admin record, not shown to the rider).
   */
  async warn(userId, message, { byUserId = null, ref = '' } = {}) {
    if (!userId || typeof userId !== 'string') return { ok: false, reason: 'NO_USER' };
    if (!this.enabled()) return { ok: false, reason: 'FEATURE_OFF' };
    const user = await this.repo.findUserById(userId);
    if (!user) return { ok: false, reason: 'NO_USER' };
    const now = this.clock();
    const warning = {
      id: `AW-${crypto.randomBytes(6).toString('hex').toUpperCase()}`,
      message: cleanMessage(message) || DEFAULT_MESSAGE,
      at: now,
      ref: String(ref || '').slice(0, 64),
    };
    const pending = Array.isArray(user.pendingWarnings) ? user.pendingWarnings.filter((w) => w && ID_RE.test(w.id)) : [];
    pending.push(warning);
    await this.repo.updateUser(user.key, { pendingWarnings: pending.slice(-MAX_PENDING) });
    let delivered = 0;
    try { if (this.hub) delivered = this.hub.sendToUser(userId, { type: 'ADMIN_WARNING', ...view(warning) }) || 0; } catch { /* stored anyway */ }
    this._audit({ actorId: byUserId || undefined, subjectId: userId, incidentId: warning.id, detail: 'SENT' }); // the warning id rides in incidentId (ids only)
    return { ok: true, delivered: delivered > 0, warning: view(warning) };
  }

  /** The rider's unacknowledged warnings, oldest first (empty while the switch is off). */
  async list(userId) {
    if (!this.enabled()) return [];
    const user = await this.repo.findUserById(userId);
    if (!user || !Array.isArray(user.pendingWarnings)) return [];
    return user.pendingWarnings.filter((w) => w && ID_RE.test(w.id)).map(view);
  }

  /** Acknowledges (removes) one warning. True when it was pending. Works with the switch off. */
  async ack(userId, id) {
    if (!ID_RE.test(String(id || ''))) return false;
    const user = await this.repo.findUserById(userId);
    if (!user || !Array.isArray(user.pendingWarnings)) return false;
    const rest = user.pendingWarnings.filter((w) => w && w.id !== id);
    if (rest.length === user.pendingWarnings.length) return false;
    await this.repo.updateUser(user.key, { pendingWarnings: rest });
    this._audit({ actorId: userId, subjectId: userId, incidentId: id, detail: 'ACK' });
    return true;
  }
}

/** Rider routes on the authenticated /api router. */
function registerAdminWarningRoutes({ r, warnings, wrap }) {
  r.get('/me/warnings', wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store').json({ warnings: await warnings.list(req.user.userId) });
  }));
  r.post('/me/warnings/:id/ack', wrap(async (req, res) => {
    const ok = await warnings.ack(req.user.userId, String(req.params.id || ''));
    res.status(ok ? 200 : 404).json(ok ? { ok: true } : { error: 'Warning not found.' });
  }));
}

module.exports = { AdminWarnings, registerAdminWarningRoutes, cleanMessage, validateWarnMessage, MESSAGE_MAX, MAX_PENDING, DEFAULT_MESSAGE };
