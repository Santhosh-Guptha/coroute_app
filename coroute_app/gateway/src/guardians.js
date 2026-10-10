'use strict';
const crypto = require('crypto');
const bcrypt = require('bcryptjs');

const HOUR = 3600000;
const EVENT_LABELS = { TRIP_STARTED: 'Ride started', TRIP_PAUSED: 'Ride paused', TRIP_RESUMED: 'Ride resumed', TRIP_ENDED: 'Ride ended', STOP_REACHED: 'Planned stop reached', DESTINATION_REACHED: 'Destination arrival reported', SOS: 'Emergency status updated', SOS_RESPONSE: 'Assistance status updated', STOPPED: 'Extended stop', OFFLINE: 'Location updates unavailable', OFF_ROUTE: 'Route deviation reported', SEPARATED: 'Group separation reported' };
const LEVELS = new Set(['BASIC', 'LIVE', 'EMERGENCY_ONLY']);
const token = () => crypto.randomBytes(24).toString('base64url');
const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');
const validToken = (value) => typeof value === 'string' && /^[A-Za-z0-9_-]{32}$/.test(value);

class GuardianError extends Error {
  constructor(message = 'This monitoring access is unavailable.', status = 410) {
    super(message); this.status = status;
  }
}

function memberOf(meta, userId) {
  const m = meta?.members?.[userId];
  return m && Number.isFinite(m.joinedAt) && !(m.leftAt && m.leftAt >= m.joinedAt) ? m : null;
}

function expiry(grant, meta) {
  if (meta.tripStatus !== 'ENDED') return grant.expiresAt;
  return Number.isFinite(meta.endedAtEpochMs) && meta.endedAtEpochMs > 0
    ? Math.min(grant.expiresAt, meta.endedAtEpochMs + 6 * HOUR) : 0;
}

function summary(g, revoked, now) {
  return { grantId: g.grantId, label: g.label, subject: g.subject, level: g.level,
    createdAt: g.createdAt, expiresAt: g.expiresAt,
    status: revoked ? 'REVOKED' : now >= g.expiresAt ? 'EXPIRED' : 'ACTIVE' };
}

/** Read-only observer access with explicit personal and consented-group projections. */
class GuardianService {
  constructor({ repo, convoys, clock = Date.now }) {
    this.repo = repo; this.convoys = convoys; this.clock = clock;
  }

  async create(userId, groupId, input = {}) {
    const allowed = new Set(['subject', 'level', 'label', 'expiresAt', 'acknowledged', 'pin']);
    if (!input || typeof input !== 'object' || Array.isArray(input) ||
        Object.keys(input).some((k) => !allowed.has(k)) || input.acknowledged !== true ||
        (input.subject !== undefined && !['PERSONAL', 'GROUP'].includes(input.subject)) || !LEVELS.has(input.level)) {
      throw new GuardianError('Choose access and acknowledge link sharing.', 400);
    }
    if (input.label !== undefined && (typeof input.label !== 'string' || input.label.length > 80)) {
      throw new GuardianError('Use a label of at most 80 characters.', 400);
    }
    if (input.pin !== undefined && (typeof input.pin !== 'string' || !/^[0-9]{4,8}$/.test(input.pin))) throw new GuardianError('Use a PIN of 4 to 8 digits.', 400);
    const now = this.clock();
    const expiresAt = input.expiresAt ?? now + 72 * HOUR;
    if (!Number.isSafeInteger(expiresAt) || expiresAt <= now || expiresAt > now + 14 * 24 * HOUR) {
      throw new GuardianError('Choose an expiry within 14 days.', 400);
    }
    const [meta, user] = await Promise.all([this.repo.getConvoyMeta(groupId), this.repo.findUserById(userId)]);
    const member = memberOf(meta, userId);
    if (!member || !user || (user.status && user.status !== 'ACTIVE') || !['PLANNING', 'STARTED', 'PAUSED'].includes(meta.tripStatus)) {
      throw new GuardianError('An active personal ride membership is required.', 403);
    }
    const subject = input.subject || 'PERSONAL';
    const subjects = [];
    if (subject === 'GROUP') {
      if (member.role !== 'LEAD' && meta.createdByUserId !== userId) throw new GuardianError('Only the lead can share the group.', 403);
      for (const id of Object.keys(meta.members || {}).slice(0, 100)) {
        const m = memberOf(meta, id);
        if (!m) continue;
        const consent = await this.repo.guardianConsent(groupId, id);
        if (consent?.allowed && consent.joinedAt === m.joinedAt) subjects.push({ userId: id, joinedAt: m.joinedAt, consentId: consent.consentId });
      }
      if (!subjects.length) throw new GuardianError('No riders have enabled Guardian group sharing.', 400);
    }
    const secret = token();
    const grant = { grantId: crypto.randomUUID(), tokenHash: hash(secret), creatorId: userId,
      subjectId: userId, subject, subjects, groupId, level: input.level,
      label: (input.label || '').trim(), joinedAt: member.joinedAt, createdAt: now, expiresAt };
    if (input.pin) grant.pinHash = await bcrypt.hash(input.pin, 10);
    await this.repo.createGuardianGrant(grant); // Do not issue a token if persistence fails.
    return { ...summary(grant, false, now), token: secret };
  }

  async list(userId, groupId) {
    const grants = await this.repo.listGuardianGrants(userId, groupId);
    return Promise.all(grants.map(async (g) => {
      const result = summary(g, await this.repo.guardianRevoked(g.grantId), this.clock());
      try { const access = await this._access(g); result.expiresAt = access.expiresAt; }
      catch (e) { if (!(e instanceof GuardianError)) throw e; if (result.status === 'ACTIVE') result.status = e.code === 'GUARDIAN_PAUSED' ? 'PAUSED' : 'UNAVAILABLE'; }
      return result;
    }));
  }

  async pause(userId, grantId, paused) {
    if (typeof paused !== 'boolean') throw new GuardianError('Choose pause or resume.', 400);
    const grant = await this.repo.guardianGrant({ grantId });
    if (!grant || grant.creatorId !== userId) throw new GuardianError('Not found.', 404);
    await this.repo.setGuardianPause({ grantId, paused, expiresAt: grant.expiresAt });
    return { paused };
  }

  async revoke(userId, grantId) {
    const grant = await this.repo.guardianGrant({ grantId });
    if (!grant || grant.creatorId !== userId) throw new GuardianError('Not found.', 404);
    if (!await this.repo.guardianRevoked(grantId)) {
      await this.repo.revokeGuardianGrant({ grantId, revokedAt: this.clock(), expiresAt: grant.expiresAt });
    }
    return { revoked: true };
  }

  async _access(grant) {
    const now = this.clock();
    if (!grant || !['PERSONAL', 'GROUP'].includes(grant.subject) || !LEVELS.has(grant.level) || now >= grant.expiresAt || now < grant.createdAt) {
      throw new GuardianError();
    }
    const [revoked, meta, user] = await Promise.all([
      this.repo.guardianRevoked(grant.grantId), this.repo.getConvoyMeta(grant.groupId),
      this.repo.findUserById(grant.subjectId),
    ]);
    const member = memberOf(meta, grant.subjectId);
    if (revoked || !user || (user.status && user.status !== 'ACTIVE') || !member || member.joinedAt !== grant.joinedAt ||
        !['PLANNING', 'STARTED', 'PAUSED', 'ENDED'].includes(meta.tripStatus) || now >= expiry(grant, meta)) {
      throw new GuardianError();
    }
    if (grant.subject === 'GROUP' && member.role !== 'LEAD' && meta.createdByUserId !== grant.creatorId) throw new GuardianError();
    if (await this.repo.guardianPaused(grant.grantId)) {
      const error = new GuardianError('The rider has paused this link.', 423); error.code = 'GUARDIAN_PAUSED'; throw error;
    }
    return { meta, expiresAt: expiry(grant, meta) };
  }

  async setConsent(userId, groupId, allowed) {
    if (typeof allowed !== 'boolean') throw new GuardianError('Choose whether to share.', 400);
    const meta = await this.repo.getConvoyMeta(groupId), member = memberOf(meta, userId);
    if (!member || meta.tripStatus === 'ENDED') throw new GuardianError('Active membership required.', 403);
    const consent = { consentId: crypto.randomUUID(), groupId, userId, joinedAt: member.joinedAt,
      allowed, createdAt: this.clock() };
    await this.repo.addGuardianConsent(consent);
    return { allowed };
  }

  async getConsent(userId, groupId) {
    const meta = await this.repo.getConvoyMeta(groupId), member = memberOf(meta, userId);
    if (!member) throw new GuardianError('Active membership required.', 403);
    const consent = await this.repo.guardianConsent(groupId, userId);
    return { allowed: consent?.allowed === true && consent.joinedAt === member.joinedAt };
  }

  async _groupSubjects(grant, meta) {
    const permitted = [];
    for (const subject of (grant.subjects || []).slice(0, 100)) {
      const member = memberOf(meta, subject.userId);
      if (!member || member.joinedAt !== subject.joinedAt) continue;
      const [consent, user] = await Promise.all([this.repo.guardianConsent(grant.groupId, subject.userId), this.repo.findUserById(subject.userId)]);
      if (user && (!user.status || user.status === 'ACTIVE') && consent?.allowed && consent.consentId === subject.consentId) permitted.push(subject.userId);
    }
    return permitted;
  }

  async exchange(secret, pin) {
    if (!validToken(secret)) throw new GuardianError();
    const grant = await this.repo.guardianGrant({ tokenHash: hash(secret) });
    const access = await this._access(grant);
    if (grant.pinHash && (typeof pin !== 'string' || !/^[0-9]{4,8}$/.test(pin) || !await bcrypt.compare(pin, grant.pinHash))) {
      const error = new GuardianError('Enter the correct PIN supplied by the rider.', 401);
      error.code = 'GUARDIAN_PIN_REQUIRED'; throw error;
    }
    const credential = token();
    const session = { sessionHash: hash(credential), grantId: grant.grantId,
      createdAt: this.clock(), expiresAt: Math.min(access.expiresAt, this.clock() + HOUR) };
    await this.repo.createGuardianSession(session);
    // Recheck after storage: concurrent revocation never issues useful access.
    await this._access(grant);
    return { credential, expiresAt: session.expiresAt };
  }

  async sessionGrant(credential) {
    if (!validToken(credential)) throw new GuardianError();
    const session = await this.repo.guardianSession(hash(credential));
    if (!session || this.clock() >= session.expiresAt || this.clock() < session.createdAt) throw new GuardianError();
    const grant = await this.repo.guardianGrant({ grantId: session.grantId });
    await this._access(grant);
    return grant;
  }

  async ticket(grantId) {
    const grant = await this.repo.guardianGrant({ grantId });
    const access = await this._access(grant);
    const credential = token(), expiresAt = Math.min(access.expiresAt, this.clock() + 10 * 60000);
    await this.repo.createGuardianSession({ sessionHash: hash(credential), grantId, createdAt: this.clock(), expiresAt });
    return { credential, expiresAt };
  }

  async snapshot(credential) {
    if (!validToken(credential)) throw new GuardianError();
    const session = await this.repo.guardianSession(hash(credential));
    const now = this.clock();
    if (!session || now >= session.expiresAt || now < session.createdAt) throw new GuardianError();
    const grant = await this.repo.guardianGrant({ grantId: session.grantId });
    if (!grant) throw new GuardianError();
    return this.viewGrant(grant.grantId, session.expiresAt);
  }

  async viewGrant(grantId, sessionExpiry = Infinity) {
    const now = this.clock();
    const grant = await this.repo.guardianGrant({ grantId });
    const access = await this._access(grant);
    // Room loading is only for current state. It does not JOIN the guardian.
    const room = await this.convoys.getRoom(grant.groupId, { required: false });
    if (!room) throw new GuardianError();
    let out;
    let permittedIds = [grant.subjectId];
    if (grant.subject === 'GROUP') {
      const ids = await this._groupSubjects(grant, access.meta);
      permittedIds = ids;
      const riders = ids.map((id) => projectPersonal({ ...grant, subjectId: id }, access.meta, room, now));
      out = { version: 1, scope: 'GROUP', level: grant.level, serverTime: now, tripStatus: access.meta.tripStatus,
        status: access.meta.tripStatus === 'ENDED' ? 'RIDE_ENDED' : 'GROUP_UPDATE',
        emergency: riders.some((r) => r.emergency), coverage: 'Consenting riders only',
        sharedRiders: ids.length };
      if (grant.level === 'BASIC') {
        out.summary = { riding: riders.filter((r) => r.status === 'RIDING').length,
          stopped: riders.filter((r) => r.status === 'STOPPED').length,
          unavailable: riders.filter((r) => ['LOCATION_UNAVAILABLE', 'UNAVAILABLE'].includes(r.status)).length };
      } else if (grant.level === 'LIVE') out.riders = riders;
      else out.riders = riders.filter((r) => r.emergency);
      // Consent can change during projection; do not send the old permission set.
      if (JSON.stringify(ids) !== JSON.stringify(await this._groupSubjects(grant, access.meta))) throw new GuardianError();
    } else out = projectPersonal(grant, access.meta, room, now);
    const events = await this.repo.guardianEvents(grant.groupId, grant.createdAt);
    out.timeline = events.filter((e) => {
      if (!EVENT_LABELS[e.type] || !Number.isFinite(e.startedAt) || e.startedAt > now) return false;
      if (grant.level === 'EMERGENCY_ONLY' && !['SOS', 'SOS_RESPONSE'].includes(e.type)) return false;
      if (!e.type.startsWith('TRIP_') && !permittedIds.includes(e.userId)) return false;
      const duration = (e.endedAt || now) - e.startedAt;
      if (e.type === 'STOPPED' && duration < 15 * 60000) return false;
      if (e.type === 'OFFLINE' && duration < 10 * 60000) return false;
      if (['OFF_ROUTE', 'SEPARATED'].includes(e.type) && duration < 5 * 60000) return false;
      if (['STOPPED', 'OFFLINE', 'OFF_ROUTE', 'SEPARATED'].includes(e.type)) {
        if (e.open && access.meta.tripStatus !== 'STARTED') return false;
        // Suppress a routine warning whose start belongs to a known planned stop or pause.
        if (events.some((other) => ['STOP_REACHED', 'DESTINATION_REACHED'].includes(other.type) &&
            other.userId === e.userId && other.startedAt <= e.startedAt &&
            (other.endedAt || now) >= e.startedAt)) return false;
        const transitions = events.filter((other) => ['TRIP_PAUSED', 'TRIP_RESUMED', 'TRIP_STARTED'].includes(other.type) &&
          other.startedAt <= e.startedAt).sort((a, b) => b.startedAt - a.startedAt);
        if (transitions[0]?.type === 'TRIP_PAUSED') return false;
      }
      return true;
    }).slice(0, 30).map((e) => ({ eventId: e.eventId, type: e.type,
      label: EVENT_LABELS[e.type], at: e.startedAt, open: e.open === true,
      updatedAt: Number.isFinite(e.updatedAt) ? e.updatedAt : e.startedAt }));
    const finalAccess = await this._access(grant); // Reject changes while building the view.
    if (grant.subject === 'GROUP' && JSON.stringify(permittedIds) !==
        JSON.stringify(await this._groupSubjects(grant, finalAccess.meta))) throw new GuardianError();
    if (finalAccess.meta.tripStatus !== access.meta.tripStatus) throw new GuardianError();
    return { ...out, expiresAt: Math.min(finalAccess.expiresAt, sessionExpiry) };
  }
}

function positionOf(value, now) {
  const at = value?.lastSeenEpochMs ?? value?.timestamp;
  if (!value || !Number.isFinite(value.lat) || !Number.isFinite(value.lng) ||
      Math.abs(value.lat) > 90 || Math.abs(value.lng) > 180 || !(value.lat || value.lng) ||
      !Number.isSafeInteger(at) || at <= 0 || at > now) return null;
  return { lat: value.lat, lng: value.lng, observedAt: at, stale: now - at >= 120000 };
}

function projectPersonal(grant, meta, room, now) {
  // Explicit allowlist: never spread a rider, alert, convoy or nested response object.
  const out = { version: 1, scope: 'PERSONAL', level: grant.level, serverTime: now,
    tripStatus: meta.tripStatus, status: 'UNAVAILABLE', emergency: false };
  if (meta.tripStatus === 'PLANNING') return { ...out, status: 'WAITING_FOR_START' };
  if (meta.tripStatus === 'ENDED' || room.meta.tripStatus === 'ENDED') return { ...out, status: 'RIDE_ENDED' };
  const rider = room.riders.get(grant.subjectId);
  const alerts = [...room.alerts.values()].filter((a) => a.userId === grant.subjectId && !a.resolved);
  out.emergency = alerts.length > 0;
  if (grant.level === 'EMERGENCY_ONLY' && !alerts.length) return { ...out, status: 'NO_ACTIVE_ALERT' };
  if (rider) out.name = String(rider.name || 'Rider').slice(0, 80);
  const position = positionOf(rider, now);
  out.observedAt = position?.observedAt ?? null;
  out.status = !position || position.stale ? 'LOCATION_UNAVAILABLE'
    : meta.tripStatus === 'PAUSED' ? 'PAUSED'
    : Number.isFinite(rider.speedKmh) ? (rider.speedKmh >= 3 ? 'RIDING' : 'STOPPED') : 'UNAVAILABLE';
  if (grant.level === 'LIVE' && position) out.position = position;
  if (alerts.length) {
    out.status = 'EMERGENCY';
    // Only incident-local facts; no medical data, messages, responder identities or invented ETA.
    out.alerts = alerts.slice(0, 5).map((a) => {
      const result = { type: a.source === 'CRASH_AUTO' ? 'POSSIBLE_ACCIDENT' : 'HELP_REQUESTED',
        status: ['ASSISTANCE_REQUESTED', 'CONFIRMED_ACCIDENT', 'RESPONDER_ASSIGNED', 'RESPONDER_ARRIVED'].includes(a.status) ? a.status : 'HELP_REQUESTED',
        reportedAt: Number.isSafeInteger(a.timestamp) && a.timestamp <= now ? a.timestamp : null };
      const incident = positionOf({ lat: a.lat, lng: a.lng, timestamp: a.timestamp }, now);
      if (grant.level !== 'BASIC' && incident) result.position = incident;
      return result;
    });
  }
  return out;
}

module.exports = { GuardianService, GuardianError, projectPersonal };
