'use strict';
/**
 * ConvoyManager — the single authority for live convoy state.
 *
 *  - Holds each active convoy ("room") in memory for sub-millisecond reads.
 *  - Applies every mutation server-side (per-rider patches, never whole-document
 *    overwrites), so two riders can never clobber each other's position.
 *  - Persists to Oracle with write-behind throttling (telemetry) or immediately
 *    (messages, alerts, config, membership).
 *  - Emits domain events which the WebSocket hub fans out *only* to the room.
 */
const { EventEmitter } = require('events');
const crypto = require('crypto');
const config = require('./config');
const { featurePolicy, policyPatch, roomAnalytics } = require('./feature_policy');
const { FeatureAnalytics } = require('./feature_analytics');
const { ACTIVE_STATUSES } = require('./oracle/repo');
const { haversine, encodePolyline, decodePolyline, pointToSegment } = require('./geo_math');
const { scrub, scrubConvoyMeta, mentions } = require('./anonymise');
const { validPhone, roleOf } = require('./validate');

const STOP_CATEGORIES = new Set(['FUEL', 'FOOD', 'REST', 'MEETING', 'SCENIC', 'TOLL', 'OTHER', 'HOSPITAL', 'REPAIR', 'STAY', 'PHARMACY', 'TYRE', 'WASHROOM', 'ATM', 'POLICE', 'PARKING']);
/** The chat card posted when a rider asks the group to wait (plain text, no emoji). */
const WAIT_MESSAGE = 'Asked the group for a 2 minute stop. Please regroup safely.';
const MAX_STOPS = 20;
/** SOS kinds the app knows; any other A-Z_ word is kept as sent, anything else becomes EMERGENCY. */
const SOS_TYPES = ['EMERGENCY', 'CRASH_OR_EMERGENCY', 'CRASH', 'MEDICAL', 'MECHANICAL', 'POLICE'];
const RESPONSE_KINDS = new Set(['GOING', 'WITH_THEM', 'CANCEL']);
const PRESENCE = new Set(['ONLINE', 'NO_SIGNAL', 'APP_CLOSED']);
const LIVE_STATUSES = ['STARTED', 'PAUSED'];

// ---- EmergencyEvent (3.15): the SOS alert doc, extended ----
const EMERGENCY_OPEN = ['CONFIRMED_ACCIDENT', 'ASSISTANCE_REQUESTED', 'RESPONDER_ASSIGNED', 'ASSISTANCE_ARRIVED'];
const EMERGENCY_TERMINAL = ['RESOLVED', 'FALSE_ALARM', 'CANCELLED', 'EXPIRED'];
const EMERGENCY_SOURCES = new Set(['MANUAL', 'CRASH_AUTO', 'NEED_HELP', 'NOTIFICATION', 'MEMBER_REPORT', 'NEARBY_REPORT', 'WEARABLE']);
const RESOLVE_REASONS = new Set(['RESOLVED', 'FALSE_ALARM', 'CANCELLED']);
const HIGH_TYPES = new Set(['EMERGENCY', 'CRASH_OR_EMERGENCY', 'CRASH', 'MEDICAL', 'RIDER_DOWN']);
/** Allowed transitions: next status -> statuses it may come from (1.2 table). Who may ask is checked by the callers. */
const TRANSITIONS = {
  ASSISTANCE_REQUESTED: ['CONFIRMED_ACCIDENT', 'RESPONDER_ASSIGNED'],
  RESPONDER_ASSIGNED: ['CONFIRMED_ACCIDENT', 'ASSISTANCE_REQUESTED'],
  ASSISTANCE_ARRIVED: ['CONFIRMED_ACCIDENT', 'ASSISTANCE_REQUESTED', 'RESPONDER_ASSIGNED'],
  RESOLVED: EMERGENCY_OPEN, FALSE_ALARM: EMERGENCY_OPEN, CANCELLED: EMERGENCY_OPEN, EXPIRED: EMERGENCY_OPEN,
};
/** Rider profile keys the safety network reads from the live rider record (server only). */
const ASSIST_RIDER_KEYS = ['assistHelp', 'assistAsk', 'responderMedical'];

/** Status of an alert; docs written before 3.15 have none. */
function statusOf(a) {
  if (a && typeof a.status === 'string' && (EMERGENCY_OPEN.includes(a.status) || EMERGENCY_TERMINAL.includes(a.status))) {
    // A resolved doc always reads as closed (old gateway resolving a 3.15 doc, or the reverse).
    if (a.resolved && EMERGENCY_OPEN.includes(a.status)) return 'RESOLVED';
    return a.status;
  }
  return a && a.resolved ? 'RESOLVED' : 'ASSISTANCE_REQUESTED';
}
function sourceOf(a) {
  if (a && EMERGENCY_SOURCES.has(a.source)) return a.source;
  return a && a.auto ? 'CRASH_AUTO' : 'MANUAL';
}
function severityOf(alertType, source) {
  if (source === 'CRASH_AUTO') return 'CRITICAL';
  return HIGH_TYPES.has(alertType) ? 'HIGH' : 'LOW';
}
function isOpenStatus(st) { return EMERGENCY_OPEN.includes(st); }

class ConvoyError extends Error {
  /** reason: machine-readable cause. The app leaves a convoy only for NOT_MEMBER / CONVOY_GONE, never for other errors. */
  constructor(message, status = 400, reason = undefined) { super(message); this.status = status; this.name = 'ConvoyError'; this.reason = reason; }
}

/**
 * The only rider fields a client message may change. Role, profile (phone, vehicle,
 * emergency contact) and co-riding are never taken from a socket message: role and
 * co-riding are set by server code paths only, the profile comes from the users table.
 */
const TELEMETRY_FIELDS = ['lat', 'lng', 'speedKmh', 'heading', 'batteryLevel', 'isCharging', 'statusReason', 'statusMessage', 'stoppedSince', 'fuelEstimate'];
/** Extra fields only trusted server code may set (CORIDER handler). */
const TRUSTED_FIELDS = ['isCoRiding', 'ridingWithUserId'];

const shortId = (n = 4) => crypto.randomBytes(n).toString('hex').toUpperCase();
const now = () => Date.now();

function num(v, def = 0) { const n = Number(v); return Number.isFinite(n) ? n : def; }
/** Group speed limit in km/h: 0 means off, otherwise 20-200 in whole km/h. */
function speedLimit(v) { const n = Math.round(num(v, 0)); return n <= 0 ? 0 : Math.max(20, Math.min(200, n)); }
/** 3.16 lower limit near stops and in towns: 0 means off, otherwise 20-100 whole km/h. */
function townLimit(v) { const n = Math.round(num(v, 0)); return n <= 0 ? 0 : Math.max(20, Math.min(100, n)); }
/** Live emergency link token: 24 random bytes as base64url = 32 chars of A-Z a-z 0-9 _ -. Only its hash is ever stored. */
function newLiveToken() { return crypto.randomBytes(24).toString('base64url'); }
function sha256(s) { return crypto.createHash('sha256').update(String(s)).digest('hex'); }
function firstNameOf(name) { return String(name || '').trim().split(/\s+/)[0].slice(0, 20); }
function clampLat(v) { return Math.max(-90, Math.min(90, num(v))); }
function clampLng(v) { return Math.max(-180, Math.min(180, num(v))); }

class ConvoyManager extends EventEmitter {
  /** @param {import('./oracle/repo').Repo} repo */
  constructor(repo, opts = {}) {
    super();
    this.repo = repo;
    this.rooms = new Map(); // groupId -> room
    this.featureAnalytics = new FeatureAnalytics();
    this.persistIntervalMs = opts.persistIntervalMs ?? config.riderPersistIntervalMs;
    this.log = opts.logger || console;
    /** async (waypoints[]) => { distanceM, durationS, polyline, legs[] } | null. Set by app.js (GeoProxy). */
    this.router = opts.router || null;
    this.routeSeq = new Map(); // groupId -> latest route request number (stale answers are ignored)
    /** 3.16: GeoProxy (nearest hospital) and SafetyAudit, set by app.js; both optional. */
    this.geo = opts.geo || null;
    this.audit = opts.audit || null;
    /** 3.16 live emergency links: sha256(token) -> { gid, alertId } for open alerts of loaded rooms. */
    this.liveLinks = new Map();
  }

  _audit(row) { try { if (this.audit) this.audit.add(row); } catch { /* never in the way */ } }

  // ---------------------------------------------------------------- rooms
  async _loadRoom(groupId) {
    const meta = await this.repo.getConvoyMeta(groupId);
    if (!meta) return null;
    const [riders, messages, alerts] = await Promise.all([
      this.repo.listRiders(groupId),
      this.repo.listMessages(groupId),
      this.repo.listAlerts(groupId),
    ]);
    const room = {
      groupId,
      meta,
      riders: new Map(riders.map((r) => [r.userId, stripKey(r)])),
      messages,
      alerts: new Map(alerts.map((a) => [a.alertId, stripKey(a)])),
      dirty: new Set(),
      lastPersist: new Map(),
      persistTimer: null,
      regroup: meta.activeRegroup || null,
    };
    this.rooms.set(groupId, room);
    // 3.16: live link index from the open alerts (the token itself is never stored, only its hash).
    for (const a of room.alerts.values()) {
      if (!a.resolved && a.liveLink && a.liveLink.hash && !a.liveLink.revokedAt) this.liveLinks.set(a.liveLink.hash, { gid: groupId, alertId: a.alertId });
    }
    // 3.15: the safety network rebuilds its incidents from open alerts of a room loaded after a restart.
    this.emit('roomLoaded', groupId);
    return room;
  }

  async getRoom(groupId, { required = true } = {}) {
    let room = this.rooms.get(groupId);
    if (!room) room = await this._loadRoom(groupId);
    if (!room && required) throw new ConvoyError('Convoy not found.', 404, 'CONVOY_GONE');
    return room;
  }

  _touch(room) { room.meta.updatedAt = now(); }

  /** Full ConvoyModel JSON as the Flutter app expects it. */
  /** `admin`: for the fleet feed and admins (alerts without medical info). */
  snapshot(room, { admin = false } = {}) {
    const m = room.meta;
    return {
      groupId: m.groupId,
      name: m.name,
      joinCode: m.joinCode,
      createdByUserId: m.createdByUserId,
      createdByUserName: m.createdByUserName,
      startLocationName: m.startLocationName || '',
      destinationName: m.destinationName || '',
      destinationLat: m.destinationLat || 0,
      destinationLng: m.destinationLng || 0,
      tripStatus: m.tripStatus,
      createdAtEpochMs: m.createdAtEpochMs,
      endedAtEpochMs: m.endedAtEpochMs || 0,
      riders: Object.fromEntries([...room.riders.entries()].map(([k, v]) => [k, publicRider(v)])),
      activeAlerts: [...room.alerts.values()].filter((a) => !a.resolved).map((a) => publicAlert(a, { medical: !admin, summary: this._summary(room.groupId, a.alertId) })),
      messages: room.messages.slice(-200),
      stopPoints: m.stopPoints || [],
      pendingMembers: {},
      waitRequests: m.waitRequests || {},
      distanceThresholdMeters: m.distanceThresholdMeters ?? 1000,
      stopThresholdSeconds: m.stopThresholdSeconds ?? 180,
      voiceGuidanceEnabled: m.voiceGuidanceEnabled ?? true,
      speedLimitKmh: m.speedLimitKmh || 0,
      townLimitKmh: m.townLimitKmh || 0,
      featurePolicy: featurePolicy(m.featurePolicy),
      featureAnalytics: roomAnalytics(room),
      routeBreadcrumbs: m.routeBreadcrumbs || [],
      start: m.start || null,
      route: m.route ? publicRoute(m.route) : null,
      destinationArrivals: m.destinationArrivals || {},
      members: Object.values(m.members || {}).map((x) => ({ userId: x.userId, name: x.name, role: x.role, joinedAt: x.joinedAt, leftAt: x.leftAt || 0 })),
      // 3.15: social visibility (group's choice) and the group default for nearby assistance.
      visibility: m.visibility === 'PUBLIC' ? 'PUBLIC' : 'PRIVATE',
      discovery: m.discovery === true,
      assistDefault: m.assistDefault !== false,
      activeRegroup: room.regroup || m.activeRegroup || null,
    };
  }

  /** { network, ownNearest } of an alert from the safety network (memory only), or null. */
  _summary(groupId, alertId) {
    try { return this.network ? this.network.summaryFor(groupId, alertId) : null; } catch { return null; }
  }

  async getSnapshot(groupId, opts = {}) { return this.snapshot(await this.getRoom(groupId), opts); }

  async isMember(groupId, userId) {
    const room = await this.getRoom(groupId, { required: false });
    return !!room && room.riders.has(userId) && ACTIVE_STATUSES.includes(room.meta.tripStatus);
  }

  _emit(groupId, type, payload = {}) {
    if (['ALERT', 'ALERT_RESOLVED', 'SOS_RESPONSE'].includes(type)) this.featureAnalytics.record('safety', true);
    this.emit('event', groupId, { type, ts: now(), ...payload });
  }

  // ------------------------------------------------------------ lifecycle
  async createConvoy(user, p) {
    const name = String(p.name || '').trim();
    if (name.length < 2) throw new ConvoyError('Convoy name is required.');

    // One active convoy per rider: leave any other first (prevents cross-group leakage).
    await this.leaveAll(user.userId);
    // Phone, vehicle and emergency contact come from the account, never from the request.
    const riderInput = { ...clientRiderInput(p.rider), ...profileOf(await this.repo.findUserById(user.userId)) };

    let joinCode;
    do { joinCode = String(100000 + crypto.randomInt(900000)); } while (await this.repo.joinCodeInUse(joinCode));

    const t = now();
    const groupId = `GRP-${shortId(4)}`;
    const meta = await this.repo.createConvoyMeta({
      groupId,
      name,
      joinCode,
      createdByUserId: user.userId,
      createdByUserName: user.name,
      startLocationName: String(p.startPoint || p.startLocationName || p.start?.name || '').slice(0, 120),
      start: sanitizePlace(p.start),
      destinationName: String(p.destination || p.destinationName || '').slice(0, 120),
      destinationLat: clampLat(p.destLat ?? p.destinationLat),
      destinationLng: clampLng(p.destLng ?? p.destinationLng),
      tripStatus: 'STARTED',
      createdAtEpochMs: t,
      distanceThresholdMeters: num(p.distanceThresholdMeters, 1000),
      stopThresholdSeconds: num(p.stopThresholdSeconds, 180),
      voiceGuidanceEnabled: p.voiceGuidanceEnabled !== false,
      speedLimitKmh: speedLimit(p.speedLimitKmh),
      routeBreadcrumbs: sanitizeBreadcrumbs(p.routeBreadcrumbs),
      stopPoints: sanitizeStops(p.stops, { by: user, status: 'PLANNED' }),
      waitRequests: {},
      members: { [user.userId]: memberRecord(user, { ...riderInput, role: 'LEAD' }, t) },
    });
    const rider = buildRider(user, { ...riderInput, role: 'LEAD' }, t);
    await this.repo.upsertRider(groupId, rider);

    const room = {
      groupId, meta, riders: new Map([[rider.userId, rider]]), messages: [], alerts: new Map(),
      dirty: new Set(), lastPersist: new Map(), persistTimer: null, regroup: null,
    };
    this.rooms.set(groupId, room);
    this.emit('fleet');
    const at = meta.start || (rider.lat || rider.lng ? { lat: rider.lat, lng: rider.lng, name: '' } : null);
    this.emit('activity', groupId, { type: 'TRIP_STARTED', user, name, lat: at?.lat, lng: at?.lng, placeName: at?.name || meta.startLocationName || '' });
    if (!meta.start && at) meta.start = { lat: at.lat, lng: at.lng, name: meta.startLocationName || '' };
    this.recomputeRoute(groupId).catch((e) => this.log.warn('[convoys] route failed', e.message));
    return this.snapshot(room);
  }

  async joinByCode(user, code, riderProfile = {}) {
    const clean = String(code || '').trim().toUpperCase();
    if (!/^[A-Z0-9]{4,10}$/.test(clean)) throw new ConvoyError('Invalid join code.');
    const meta = await this.repo.getActiveConvoyByJoinCode(clean);
    if (!meta) throw new ConvoyError('No active convoy found for that code.', 404);

    const room = await this.getRoom(meta.groupId);
    // Size cap for new riders only; someone already in the convoy can always re-join.
    if (!room.riders.has(user.userId) && room.riders.size >= config.maxConvoyRiders) {
      throw new ConvoyError(`This convoy is full (${config.maxConvoyRiders} riders).`, 409, 'CONVOY_FULL');
    }
    if (!room.riders.has(user.userId)) await this.leaveAll(user.userId, { except: meta.groupId });

    const existing = room.riders.get(user.userId);
    const profile = profileOf(await this.repo.findUserById(user.userId));
    const rider = buildRider(user, { ...(existing || {}), ...clientRiderInput(riderProfile), ...profile, role: existing?.role || 'PACK' }, now());
    room.riders.set(rider.userId, rider);
    const prev = room.meta.members?.[rider.userId];
    const record = memberRecord(user, rider, existing ? (prev?.joinedAt || rider.joinedAt) : now());
    record.firstJoinedAt = prev?.firstJoinedAt || prev?.joinedAt || record.joinedAt;
    room.meta.members = { ...(room.meta.members || {}), [rider.userId]: record };
    await this.repo.upsertRider(room.groupId, rider);
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(room.groupId, 'RIDER_UPDATE', { rider: publicRider(rider), joined: !existing });
    this.emit('fleet');
    return this.snapshot(room);
  }

  /** Removes the rider from every active convoy they are in (except `except`). */
  async leaveAll(userId, { except } = {}) {
    for (const room of this.rooms.values()) {
      if (room.groupId !== except && room.riders.has(userId)) await this.leave(room.groupId, userId);
    }
    const dbMembership = await this.repo.findActiveMembership(userId);
    if (dbMembership && dbMembership.groupId !== except) await this.leave(dbMembership.groupId, userId);
  }

  async leave(groupId, userId) {
    const room = await this.getRoom(groupId, { required: false });
    if (!room) { await this.repo.removeRider(groupId, userId); return; }
    const rider = room.riders.get(userId);
    room.riders.delete(userId);
    room.dirty.delete(userId);
    if (room.meta.members?.[userId]) room.meta.members[userId].leftAt = now();
    await this.repo.removeRider(groupId, userId);
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    if (rider) this._emit(groupId, 'RIDER_LEFT', { userId, name: rider.name });
    this.emit('fleet');
    if (room.riders.size === 0 && ACTIVE_STATUSES.includes(room.meta.tripStatus)) {
      await this.setTripStatus(groupId, 'ENDED', { system: true });
    }
  }

  async setTripStatus(groupId, status, { system = false } = {}) {
    if (!['PLANNING', 'STARTED', 'PAUSED', 'ENDED'].includes(status)) throw new ConvoyError('Invalid trip status.');
    const room = await this.getRoom(groupId);
    room.meta.tripStatus = status;
    if (status === 'ENDED') {
      room.meta.endedAtEpochMs = now();
      // Durable, location-free record of who rode together (kept forever).
      room.meta.memberSummary = Object.values(room.meta.members || {});
      room.meta.riderCount = room.meta.memberSummary.length;
    }
    this._touch(room);
    await this.flushRoom(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'TRIP_STATUS', { tripStatus: status, system });
    this.emit('fleet');
    if (status === 'ENDED') {
      clearTimeout(room.persistTimer);
      this.rooms.delete(groupId);
      // 3.15: the safety network and discovery close everything of this room (no DB change).
      this.emit('roomEnded', groupId, room);
      // Medical info lives only as long as the ride.
      for (const a of room.alerts.values()) delete a.medical;
      await this.repo.stripAlertMedical(groupId).catch((e) => this.log.warn('[convoys] medical strip failed', e.message));
    }
    return status;
  }

  // ------------------------------------------------------------ telemetry
  /**
   * Applies a telemetry/status patch to one rider. Memory first, DB later.
   * Only TELEMETRY_FIELDS are read from the patch, each coerced to its type;
   * `trusted` (server code only) also allows the co-riding fields.
   */
  patchRider(room, userId, patch, { emit = true, trusted = false } = {}) {
    const current = room.riders.get(userId);
    if (!current) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const next = { ...current, ...sanitizeTelemetry(patch) };
    if (!featurePolicy(room.meta.featurePolicy).groupFuelEnabled) next.fuelEstimate = null;
    if (trusted && patch) {
      if (patch.isCoRiding !== undefined) next.isCoRiding = !!patch.isCoRiding;
      if (patch.ridingWithUserId !== undefined && patch.ridingWithUserId !== null) next.ridingWithUserId = String(patch.ridingWithUserId).slice(0, 64);
    }
    next.lastSeenEpochMs = now();
    room.riders.set(userId, next);
    room.dirty.add(userId);
    this._schedulePersist(room);
    if (patch && patch.lat !== undefined && patch.lng !== undefined) this.emit('telemetry', room.groupId, next);
    if (emit) this._emit(room.groupId, 'RIDER_UPDATE', { rider: publicRider(next) });
    return next;
  }

  _schedulePersist(room) {
    if (room.persistTimer) return;
    room.persistTimer = setTimeout(() => {
      room.persistTimer = null;
      this.flushRoom(room).catch((e) => this.log.warn('[convoys] persist failed', e.message));
    }, this.persistIntervalMs);
    if (room.persistTimer.unref) room.persistTimer.unref();
  }

  async flushRoom(room) {
    const ids = [...room.dirty];
    room.dirty.clear();
    await Promise.all(ids.map(async (userId) => {
      const rider = room.riders.get(userId);
      if (rider) await this.repo.upsertRider(room.groupId, rider);
    }));
    if (ids.length) {
      this._touch(room);
      await this.repo.saveConvoyMeta(room.meta);
    }
  }

  async flushAll() {
    for (const room of this.rooms.values()) {
      clearTimeout(room.persistTimer); room.persistTimer = null;
      await this.flushRoom(room).catch(() => {});
    }
  }

  // ------------------------------------------------------ chat / alerts
  async sendMessage(groupId, user, { text, isQuickCard = false, cardType = 'CUSTOM', clientId = '', sentAt } = {}) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const clean = String(text || '').trim().slice(0, 500);
    if (!clean) throw new ConvoyError('Message text is required.');
    const t = now();
    const msg = {
      messageId: `MSG-${shortId(4)}`, senderId: user.userId, senderName: user.name, text: clean,
      timestamp: t, isQuickCard: !!isQuickCard, cardType: String(cardType || 'CUSTOM').slice(0, 24),
    };
    // Outbox (3.14): the phone's id for this message, and when it was written (it may have waited for signal).
    if (clientId) {
      msg.clientId = clientId;
      msg.sentAt = clampTime(sentAt, t - 6 * 3600000, t, t);
    }
    return this._postMessage(room, msg);
  }

  async _postMessage(room, msg) {
    room.messages.push(msg);
    if (room.messages.length > 500) room.messages.splice(0, room.messages.length - 500);
    await this.repo.addMessage(room.groupId, msg);
    this._emit(room.groupId, 'MESSAGE', { message: msg });
    return msg;
  }

  async requestWait(groupId, user) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    room.meta.waitRequests = { ...(room.meta.waitRequests || {}), [user.name]: now() };
    // Expire stale wait requests (>2 min) while we are here.
    for (const [k, v] of Object.entries(room.meta.waitRequests)) if (now() - v > 150000) delete room.meta.waitRequests[k];
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'WAIT_REQUESTS', { waitRequests: room.meta.waitRequests });
    // A system card in the chat (SYSTEM is not a rider, so it is posted directly; requestedBy lets
    // account deletion find it).
    return this._postMessage(room, {
      messageId: `MSG-${shortId(4)}`, senderId: 'SYSTEM', senderName: user.name, requestedBy: user.userId,
      text: WAIT_MESSAGE, timestamp: now(), isQuickCard: true, cardType: 'WAIT_2MIN',
    }).catch(() => null);
  }

  /**
   * Raises an SOS. Idempotent per (rider, clientId): a phone that retries an SOS after a
   * dead zone (it never saw the echo) gets the existing alert back instead of a second one.
   * 3.14 extras (all optional, old apps send none): auto (raised by crash detection),
   * speedBeforeKmh, impactG, occurredAt. The rider's optional medical info is attached for the
   * group while the alert is open (a failed read never blocks the SOS).
   * Returns { alert, duplicate } (alert as stored, use publicAlert for the wire).
   */
  async raiseSos(groupId, user, msg = {}) {
    // The same SOS (same rider, same clientId) can arrive again while the first copy is still
    // being stored: a double press, the CRASH upgrade of a waiting SOS, a resend after a
    // reconnect. Later copies wait for the first and are answered as duplicates (one alert).
    const raw = msg && msg.clientId;
    const cid = raw === undefined || raw === null ? '' : String(raw).slice(0, 64);
    if (!cid) return this._raiseSos(groupId, user, msg);
    const inflight = this.sosInFlight || (this.sosInFlight = new Map());
    const k = `${groupId}|${user.userId}|${cid}`;
    const first = inflight.get(k);
    if (first) {
      const r = await first;
      return { alert: r.alert, duplicate: true };
    }
    const p = this._raiseSos(groupId, user, msg);
    inflight.set(k, p);
    try { return await p; } finally { inflight.delete(k); }
  }

  async _raiseSos(groupId, user, msg = {}) {
    // msg.type is the socket message type ('SOS'), not the kind of SOS (alertType).
    const { lat, lng, type, alertType, clientId } = msg || {};
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const cid = clientId === undefined || clientId === null ? '' : String(clientId).slice(0, 64);
    if (cid) {
      for (const a of room.alerts.values()) {
        if (a.userId === user.userId && a.clientId === cid) return { alert: a, duplicate: true };
      }
      // Already resolved and no longer in memory: still the same SOS, never a new one.
      const stored = await this.repo.findAlertByClientId(groupId, user.userId, cid);
      if (stored) return { alert: stripKey(stored), duplicate: true };
    }
    const t = now();
    const details = {};
    const speed = boundedNumber(msg.speedBeforeKmh, 0, 300);
    if (speed !== null) details.speedBeforeKmh = speed;
    const impact = boundedNumber(msg.impactG, 0, 50);
    if (impact !== null) details.impactG = impact;
    // 3.15: where it came from (old apps send nothing: crash alerts read as CRASH_AUTO, the rest MANUAL).
    const src = typeof msg.source === 'string' && EMERGENCY_SOURCES.has(msg.source) && !['MEMBER_REPORT', 'NEARBY_REPORT'].includes(msg.source)
      ? msg.source : (msg.auto === true ? 'CRASH_AUTO' : 'MANUAL');
    const auto = msg.auto === true || src === 'CRASH_AUTO';
    const kind = sosType(alertType || (type === 'SOS' ? '' : type));
    const alert = {
      alertId: `SOS-${crypto.randomUUID()}`, userId: user.userId, userName: user.name,
      lat: clampLat(lat), lng: clampLng(lng), alertType: kind, timestamp: t, resolved: false,
      ...(cid ? { clientId: cid } : {}),
      auto,
      details,
      occurredAt: clampTime(msg.occurredAt, t - 6 * 3600000, t + 60000, t),
      responders: {},
      ...this._emergencyFields(room, { lat: clampLat(lat), lng: clampLng(lng), msg, source: src, alertType: kind, t }),
    };
    const ownerDoc = await withTimeout(this.repo.findUserById(user.userId), 1500).catch(() => null);
    return { alert: await this._storeAlert(room, alert, ownerDoc), duplicate: false };
  }

  /** The 3.15 EmergencyEvent fields of a new alert. */
  _emergencyFields(room, { lat, lng, msg = {}, source, alertType, t, status }) {
    const out = {
      status: status || (source === 'CRASH_AUTO' ? 'CONFIRMED_ACCIDENT' : 'ASSISTANCE_REQUESTED'),
      source,
      severity: severityOf(alertType, source),
      confirmedAt: t,
      lastUpdateAt: t,
      routeIndex: routeIndexOf(room.meta, lat, lng),
    };
    const heading = boundedNumber(msg.heading, -100000, 100000);
    if (heading !== null) out.heading = Math.round((((heading % 360) + 360) % 360) * 10) / 10;
    const sp = boundedNumber(msg.speedKmh, 0, 300);
    if (sp !== null) out.speedKmh = sp;
    const acc = boundedNumber(msg.accuracyM, 0, 5000);
    if (acc !== null) out.accuracyM = Math.round(acc);
    return out;
  }

  /**
   * Stores a new alert, tells the room (ALERT, never throttled, before any network work) and hands
   * it to the safety network ('emergency' RAISED, not awaited). `ownerDoc`: the subject's users doc
   * (medical info for the group; assistance settings and false alarm history for the network).
   */
  async _storeAlert(room, alert, ownerDoc) {
    const medical = medicalOf(ownerDoc);
    if (medical) alert.medical = medical;
    room.alerts.set(alert.alertId, alert);
    await this.repo.addAlert(room.groupId, alert);
    this._emit(room.groupId, 'ALERT', { alert: publicAlert(alert, { summary: this._summary(room.groupId, alert.alertId) }) });
    this.emit('fleet');
    try {
      this.emit('emergency', room.groupId, alert, 'RAISED', { owner: ownerInfo(ownerDoc) });
    } catch (e) { this.log.warn('[convoys] emergency hook failed', e.message); }
    this._lookupHospital(room, alert);
    return alert;
  }

  /**
   * 3.16: nearest hospital for the incident sheet. Runs after the ALERT went out and is never awaited:
   * one lookup per alert (memory flag), only for HIGH / CRITICAL alerts, only when the polite OSM queue
   * is short. On success the alert gets `nearestHospital` (stored) and the room an EMERGENCY_UPDATE.
   */
  _lookupHospital(room, alert) {
    if (alert.hospitalTried || alert.nearestHospital) return;
    alert.hospitalTried = true;
    if (!this.geo || typeof this.geo.nearestHospital !== 'function') return;
    if (!['HIGH', 'CRITICAL'].includes(alert.severity || severityOf(alert.alertType, sourceOf(alert)))) return;
    if (typeof this.geo.queueWaitMs === 'function' && this.geo.queueWaitMs() >= config.hospitalMaxWaitMs) return;
    if (!(alert.lat || alert.lng)) return;
    const gid = room.groupId, alertId = alert.alertId;
    Promise.resolve()
      .then(() => this.geo.nearestHospital(alert.lat, alert.lng))
      .then(async (h) => {
        if (!h || !h.name) return;
        const cur = this.rooms.get(gid)?.alerts.get(alertId);
        if (!cur || cur.resolved) return;
        cur.nearestHospital = { name: String(h.name).slice(0, 80), lat: h.lat, lng: h.lng, distanceM: Math.round(h.distanceM) };
        await this.repo.updateAlert(gid, alertId, { nearestHospital: cur.nearestHospital }).catch(() => {});
        this.emitEmergencyUpdate(gid, alertId);
      })
      .catch((e) => this.log.warn('[convoys] hospital lookup failed', e.message));
  }

  /**
   * Closes or cancels an SOS. `reason` (3.15): RESOLVED (default), FALSE_ALARM, CANCELLED.
   * Any member or an admin resolves; FALSE_ALARM / CANCELLED count only from the owner (the
   * subject) or an admin, otherwise it is RESOLVED. The owner's cancel within
   * EMERGENCY_CANCEL_GRACE_S while nobody outside the group was asked is CANCELLED, later FALSE_ALARM.
   */
  async resolveSos(groupId, user, alertId, reason = 'RESOLVED') {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId) && user.role !== 'MASTER_ADMIN') throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const a = room.alerts.get(alertId);
    if (!a || a.resolved) {
      // Unknown here or already closed: answered as before (idempotent for the phones).
      if (a) { delete a.medical; }
      await this.repo.resolveAlert(groupId, alertId, user.userId);
      this._emit(groupId, 'ALERT_RESOLVED', { alertId, by: user.userId, status: a ? statusOf(a) : 'RESOLVED' });
      this.emit('fleet');
      return true;
    }
    const r = typeof reason === 'string' && RESOLVE_REASONS.has(reason.toUpperCase()) ? reason.toUpperCase() : 'RESOLVED';
    let next = 'RESOLVED';
    if (r !== 'RESOLVED') {
      const owner = a.userId === user.userId;
      if (owner) {
        const notified = this.network ? this.network.notifiedCount(groupId, alertId) : 0;
        const within = now() - (a.confirmedAt || a.timestamp || 0) <= config.emergencyCancelGraceS * 1000;
        next = within && notified === 0 ? 'CANCELLED' : 'FALSE_ALARM';
      } else if (user.role === 'MASTER_ADMIN') {
        next = 'FALSE_ALARM';
      }
    }
    await this.setEmergencyStatus(groupId, alertId, next, { by: user.userId });
    return true;
  }

  /**
   * The only writer of EmergencyEvent status changes (3.15). Checks the transition table, persists,
   * updates the alert's SOS timeline entry, tells the safety network and the room. Terminal states
   * close the alert like 3.14 did (resolved, medical removed, ALERT_RESOLVED + status).
   * Returns the alert, or null when the change is not allowed (closed, unknown, same status).
   */
  async setEmergencyStatus(groupId, alertId, next, { by = 'SYSTEM' } = {}) {
    // Live convoys only (every caller already has the room in memory; an ended ride is never loaded back).
    const room = this.rooms.get(groupId);
    const a = room?.alerts.get(alertId);
    if (!a || a.resolved) return null;
    const cur = statusOf(a);
    if (!TRANSITIONS[next] || !TRANSITIONS[next].includes(cur)) return null;
    const t = now();
    a.status = next;
    a.lastUpdateAt = t;
    if (EMERGENCY_TERMINAL.includes(next)) {
      a.resolved = true; a.resolvedAt = t; a.resolvedBy = by; a.resolveReason = next === 'EXPIRED' ? 'EXPIRED' : next;
      delete a.medical;
      // 3.16: a live link dies with the alert.
      const linkPatch = this._revokeLink(groupId, a, t, 'SYSTEM') ? { liveLink: a.liveLink } : {};
      await this.repo.resolveAlert(groupId, alertId, by, { status: next, resolveReason: a.resolveReason, lastUpdateAt: t, ...(a.netResponders ? { netResponders: a.netResponders } : {}), ...linkPatch })
        .catch((e) => this.log.warn('[convoys] resolve failed', e.message));
      this.emit('activity', groupId, { type: 'EMERGENCY_STATUS', alert: a });
      this._emit(groupId, 'ALERT_RESOLVED', { alertId, by, status: next });
      this.emit('fleet');
      this._hook('RESOLVED', groupId, a);
      return a;
    }
    await this.repo.updateAlert(groupId, alertId, { status: next, lastUpdateAt: t }).catch((e) => this.log.warn('[convoys] status save failed', e.message));
    this.emit('activity', groupId, { type: 'EMERGENCY_STATUS', alert: a });
    this._hook('STATUS', groupId, a);
    this.emitEmergencyUpdate(groupId, alertId);
    this.emit('fleet');
    return a;
  }

  _hook(kind, groupId, a) {
    try { this.emit('emergency', groupId, a, kind, {}); } catch (e) { this.log.warn('[convoys] emergency hook failed', e.message); }
  }

  /**
   * EMERGENCY_UPDATE to the room's 3.15 sockets (cap net1): status, latest known position, the
   * nearby assistance summary and the nearest own member. Old apps never get it.
   */
  emitEmergencyUpdate(groupId, alertId) {
    const room = this.rooms.get(groupId);
    const a = room?.alerts.get(alertId);
    if (!a) return false;
    const sum = this._summary(groupId, alertId) || {};
    const pos = sum.position || { lat: a.lat, lng: a.lng };
    this.emit('capEvent', groupId, 'net1', {
      type: 'EMERGENCY_UPDATE', alertId, status: statusOf(a), lastUpdateAt: a.lastUpdateAt || a.timestamp || 0,
      lat: pos.lat, lng: pos.lng,
      network: sum.network || { state: 'OFF', stage: 0, notified: 0, onScene: false, responders: [] },
      ownNearest: sum.ownNearest || null,
      // 3.16: known once the lookup answered (never delays anything).
      ...(a.nearestHospital ? { nearestHospital: a.nearestHospital } : {}),
      ts: now(),
    });
    return true;
  }

  // ------------------------------------------------------ live emergency links (3.16)
  /**
   * A public link https://<origin>/e/<token> to the rider's live position during an open SOS,
   * made by the alert owner or the lead. The token (24 random bytes, base64url) is returned once
   * and never stored: the alert keeps sha256(token), expiry, creator and revocation. One valid link
   * per alert (409 LINK_ACTIVE while one lives), at most LIVE_LINK_PER_ALERT links per alert (429).
   * Returns { token, expiresAt } (the URL is built by the REST layer from the request origin).
   */
  async createLiveLink(groupId, user, alertId) {
    const room = await this.getRoom(groupId);
    this._requireMember(room, user);
    const a = typeof alertId === 'string' ? room.alerts.get(alertId) : null;
    if (!a || a.resolved) throw new ConvoyError('That alert is no longer open.', 404, 'ALERT_CLOSED');
    if (a.userId !== user.userId && !this.isLead(room, user)) throw new ConvoyError('Only the rider or the lead can share a live link.', 403, 'NOT_ALLOWED');
    const t = now();
    const cur = a.liveLink;
    if (cur && cur.hash && !cur.revokedAt && cur.expiresAt > t) {
      const e = new ConvoyError('A live link is already active.', 409, 'LINK_ACTIVE');
      e.expiresAt = cur.expiresAt;
      throw e;
    }
    if (cur && cur.hash) this._revokeLink(groupId, a, t, user.userId, cur.expiresAt <= t ? 'EXPIRE' : 'REVOKE');
    const count = (a.liveLinkCount || 0) + 1;
    if (count > config.liveLinkPerAlert) throw new ConvoyError('No more live links can be made for this alert.', 429, 'LINK_LIMIT');
    const token = newLiveToken();
    const hash = sha256(token);
    a.liveLink = { hash, expiresAt: t + config.liveLinkMin * 60000, createdBy: user.userId, createdAt: t, revokedAt: 0 };
    a.liveLinkCount = count;
    this.liveLinks.set(hash, { gid: groupId, alertId: a.alertId });
    await this.repo.updateAlert(groupId, a.alertId, { liveLink: a.liveLink, liveLinkCount: count }).catch((e) => this.log.warn('[convoys] live link save failed', e.message));
    this._audit({ kind: 'LIVE_LINK', actorId: user.userId, subjectId: a.userId, alertId: a.alertId, groupId, detail: 'CREATE' });
    this.emitEmergencyUpdate(groupId, a.alertId);
    return { token, expiresAt: a.liveLink.expiresAt };
  }

  /** Owner, lead or admin stops a live link early. Idempotent. */
  async revokeLiveLink(groupId, user, alertId) {
    const room = await this.getRoom(groupId);
    if (user.role !== 'MASTER_ADMIN') this._requireMember(room, user);
    const a = typeof alertId === 'string' ? room.alerts.get(alertId) : null;
    if (!a) throw new ConvoyError('That alert is no longer open.', 404, 'ALERT_CLOSED');
    if (a.userId !== user.userId && !this.isLead(room, user)) throw new ConvoyError('Only the rider or the lead can stop a live link.', 403, 'NOT_ALLOWED');
    if (this._revokeLink(groupId, a, now(), user.userId)) {
      await this.repo.updateAlert(groupId, a.alertId, { liveLink: a.liveLink }).catch(() => {});
      if (!a.resolved) this.emitEmergencyUpdate(groupId, a.alertId);
    }
    return true;
  }

  /** Marks the alert's link revoked (memory + index) and audits it. Returns true when something changed. */
  _revokeLink(groupId, a, t, by, detail = 'REVOKE') {
    const l = a.liveLink;
    if (!l || !l.hash || l.revokedAt) return false;
    l.revokedAt = t;
    this.liveLinks.delete(l.hash);
    this._audit({ kind: 'LIVE_LINK', actorId: by, subjectId: a.userId, alertId: a.alertId, groupId, detail });
    return true;
  }

  /**
   * What the public page shows for a link hash: { firstName, lat, lng, at, active: true, expiresAt }
   * or null (unknown, expired, revoked, resolved). The position is the rider's current one in the
   * room when it is fresher than the alert's, else the alert's. Nothing else leaves.
   */
  liveView(hash) {
    const ref = typeof hash === 'string' ? this.liveLinks.get(hash) : null;
    if (!ref) return null;
    const room = this.rooms.get(ref.gid);
    const a = room?.alerts.get(ref.alertId);
    const l = a && a.liveLink;
    if (!a || !l || l.hash !== hash || a.resolved || l.revokedAt) { this.liveLinks.delete(hash); return null; }
    const t = now();
    if (l.expiresAt <= t) {
      this._revokeLink(ref.gid, a, t, 'SYSTEM', 'EXPIRE');
      this.repo.updateAlert(ref.gid, a.alertId, { liveLink: a.liveLink }).catch(() => {});
      return null;
    }
    const alertAt = a.lastUpdateAt || a.timestamp || 0;
    const rider = room.riders.get(a.userId);
    let lat = a.lat, lng = a.lng, at = alertAt;
    if (rider && (rider.lat || rider.lng) && (rider.lastSeenEpochMs || 0) >= alertAt) { lat = rider.lat; lng = rider.lng; at = rider.lastSeenEpochMs; }
    return { firstName: firstNameOf(a.userName || rider?.name), lat: +Number(lat).toFixed(5), lng: +Number(lng).toFixed(5), at, active: true, expiresAt: l.expiresAt };
  }

  // ------------------------------------------------------ sweeper role (3.16)
  /**
   * The lead makes a rider the SWEEPER (or back to PACK). One sweeper per room: the previous one
   * becomes PACK in the same change. Never the creator, never a LEAD. Every changed rider is sent as
   * RIDER_UPDATE (old and new apps apply `role`) and the timeline gets ROLE_CHANGED for the target.
   */
  async setRole(groupId, user, userId, role) {
    const room = await this.getRoom(groupId);
    this._requireLead(room, user);
    const r = roleOf(role);
    if (!r) throw new ConvoyError('Role must be SWEEPER or PACK.', 400, 'BAD_ROLE');
    const uid = typeof userId === 'string' && userId.length <= 64 ? userId : '';
    const target = uid ? room.riders.get(uid) : null;
    if (!target) throw new ConvoyError('That rider is not in this convoy.', 404, 'NOT_MEMBER');
    if (target.role === 'LEAD' || room.meta.createdByUserId === uid) throw new ConvoyError('The lead cannot be given another role.', 403, 'NOT_ALLOWED');
    const changed = [];
    if (r === 'SWEEPER') {
      for (const o of room.riders.values()) {
        if (o.userId !== uid && o.role === 'SWEEPER') changed.push(this._applyRole(room, o.userId, 'PACK'));
      }
    }
    if (target.role !== r) changed.push(this._applyRole(room, uid, r));
    if (!changed.length) return target;
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    for (const rider of changed) {
      room.dirty.delete(rider.userId);
      await this.repo.upsertRider(groupId, rider).catch((e) => this.log.warn('[convoys] role save failed', e.message));
      this._emit(groupId, 'RIDER_UPDATE', { rider: publicRider(rider) });
    }
    this.emit('activity', groupId, { type: 'ROLE_CHANGED', user: { userId: uid, name: target.name }, role: r, byUserId: user.userId });
    this.emit('fleet');
    return room.riders.get(uid);
  }

  _applyRole(room, uid, role) {
    const next = { ...room.riders.get(uid), role };
    room.riders.set(uid, next);
    if (room.meta.members?.[uid]) room.meta.members[uid] = { ...room.meta.members[uid], role };
    return next;
  }

  /**
   * "Rider down here" (3.15 REPORT_DOWN). With subjectUserId (a rider of my room, not me): a member
   * report for that rider (their open alert is returned when there is one). Without: a nearby
   * report (someone outside the group) as an alert in my room, the reporter on scene.
   * The point must be within NET_REPORT_MAX_M of my last position. Returns { alert, duplicate }.
   */
  async reportDown(groupId, user, msg = {}) {
    const room = await this.getRoom(groupId);
    const me = room.riders.get(user.userId);
    if (!me) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const lat = Number(msg.lat), lng = Number(msg.lng);
    if (msg.lat === null || msg.lng === null || typeof msg.lat === 'boolean' || typeof msg.lng === 'boolean' ||
        !Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) {
      throw new ConvoyError('Send the position of the rider.', 400, 'BAD_POSITION');
    }
    let subject = null;
    if (msg.subjectUserId !== undefined && msg.subjectUserId !== null && msg.subjectUserId !== '') {
      const sid = typeof msg.subjectUserId === 'string' && msg.subjectUserId.length <= 64 ? msg.subjectUserId : '';
      subject = sid && sid !== user.userId ? room.riders.get(sid) : null;
      if (!subject) throw new ConvoyError('That rider is not in your group.', 403, 'NOT_ALLOWED');
    }
    if (!(me.lat || me.lng) || haversine(me.lat, me.lng, lat, lng) > config.netReportMaxM) {
      throw new ConvoyError('You can report a rider only near your own position.', 422, 'TOO_FAR');
    }
    const t = now();
    const log = this.reportDownLog || (this.reportDownLog = new Map());
    const recent = (log.get(user.userId) || []).filter((x) => t - x < 600000);
    if (recent.length >= config.reportDownPer10Min) throw new ConvoyError('Slow down.', 429);
    recent.push(t);
    log.set(user.userId, recent);
    if (log.size > 5000) for (const [k, v] of log) if (!v.some((x) => t - x < 600000)) log.delete(k);

    if (subject) {
      const open = [...room.alerts.values()].find((a) => a.userId === subject.userId && !a.resolved);
      if (open) {
        if (!open.reportedBy) {
          open.reportedBy = user.userId; open.reportedByName = user.name;
          await this.repo.updateAlert(groupId, open.alertId, { reportedBy: user.userId, reportedByName: user.name }).catch(() => {});
        }
        return { alert: open, duplicate: true };
      }
    }
    const base = {
      alertId: `SOS-${crypto.randomUUID()}`, lat: clampLat(lat), lng: clampLng(lng), alertType: 'RIDER_DOWN', timestamp: t, resolved: false,
      auto: false, details: {}, occurredAt: t, responders: {}, reportedBy: user.userId, reportedByName: user.name,
    };
    if (subject) {
      const alert = {
        ...base, userId: subject.userId, userName: subject.name,
        ...this._emergencyFields(room, { lat: base.lat, lng: base.lng, msg: { heading: msg.heading }, source: 'MEMBER_REPORT', alertType: 'RIDER_DOWN', t, status: 'ASSISTANCE_REQUESTED' }),
      };
      const doc = await withTimeout(this.repo.findUserById(subject.userId), 1500).catch(() => null);
      return { alert: await this._storeAlert(room, alert, doc), duplicate: false };
    }
    const alert = {
      ...base, userId: user.userId, userName: user.name,
      ...this._emergencyFields(room, { lat: base.lat, lng: base.lng, msg: { heading: msg.heading }, source: 'NEARBY_REPORT', alertType: 'RIDER_DOWN', t, status: 'ASSISTANCE_ARRIVED' }),
    };
    // The injured person is not the reporter: no medical info of the reporter is attached.
    room.alerts.set(alert.alertId, alert);
    await this.repo.addAlert(groupId, alert);
    this._emit(groupId, 'ALERT', { alert: publicAlert(alert, { summary: this._summary(groupId, alert.alertId) }) });
    this.emit('fleet');
    try { this.emit('emergency', groupId, alert, 'RAISED', { owner: null }); } catch (e) { this.log.warn('[convoys] emergency hook failed', e.message); }
    this._lookupHospital(room, alert);
    return { alert, duplicate: false };
  }

  /**
   * "I'm going" / "I'm with them" / cancel, by a convoy member for someone else's open alert.
   * Returns { changed, responders }.
   */
  async respondSos(groupId, user, { alertId, kind } = {}) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const k = typeof kind === 'string' ? kind.toUpperCase() : '';
    if (!RESPONSE_KINDS.has(k)) throw new ConvoyError('Answer with GOING, WITH_THEM or CANCEL.', 400);
    const a = typeof alertId === 'string' ? room.alerts.get(alertId) : null;
    if (!a || a.resolved) throw new ConvoyError('That alert is no longer open.', 404, 'ALERT_CLOSED');
    if (a.userId === user.userId) throw new ConvoyError('You cannot respond to your own alert.', 403, 'OWN_ALERT');
    const map = { ...(a.responders || {}) };
    const t = now();
    const prev = map[user.userId];
    if (k === 'CANCEL') {
      if (!prev) return { changed: false, responders: respondersList(map) };
      delete map[user.userId];
    } else {
      if (prev && prev.kind === k) return { changed: false, responders: respondersList(map) };
      if (!prev && Object.keys(map).length >= config.sosRespondersMax) throw new ConvoyError('Enough riders are already responding.', 409, 'RESPONDERS_FULL');
      map[user.userId] = { userId: user.userId, name: user.name, kind: k, at: t };
    }
    a.responders = map;
    await this.repo.updateAlert(groupId, a.alertId, { responders: map });
    const responders = respondersList(map);
    this._emit(groupId, 'SOS_RESPONSE', { alertId: a.alertId, userId: user.userId, name: user.name, kind: k === 'CANCEL' ? null : k, at: t, responders });
    this.emit('activity', groupId, { type: 'SOS_RESPONSE', user, alert: a, kind: k, at: t, responders });
    this.emit('fleet');
    // 3.15 lifecycle: own-group responders move the emergency too.
    const st = statusOf(a);
    if (k === 'GOING' && (st === 'CONFIRMED_ACCIDENT' || st === 'ASSISTANCE_REQUESTED')) {
      await this.setEmergencyStatus(groupId, a.alertId, 'RESPONDER_ASSIGNED', { by: user.userId });
    } else if (k === 'WITH_THEM' && st !== 'ASSISTANCE_ARRIVED') {
      await this.setEmergencyStatus(groupId, a.alertId, 'ASSISTANCE_ARRIVED', { by: user.userId });
    } else if (k === 'CANCEL' && st === 'RESPONDER_ASSIGNED' && !Object.values(map).some((x) => x && x.kind === 'GOING')
      && !(this.network && this.network.hasActiveResponder(groupId, a.alertId))) {
      await this.setEmergencyStatus(groupId, a.alertId, 'ASSISTANCE_REQUESTED', { by: user.userId });
    }
    return { changed: true, responders };
  }

  // ------------------------------------------------------ presence (3.14)
  /**
   * Online / no signal / app closed for one rider. Changes no telemetry and no lastSeen.
   * Broadcasts PRESENCE to the room and emits 'presence' for the timeline. Rooms not in memory are skipped.
   */
  setPresence(groupId, userId, presence) {
    if (!PRESENCE.has(presence)) return null;
    const room = this.rooms.get(groupId);
    const rider = room?.riders.get(userId);
    if (!rider) return null;
    if (rider.presence === presence) return rider;
    const at = now();
    const next = { ...rider, presence, presenceAt: at };
    room.riders.set(userId, next);
    room.dirty.add(userId);
    this._schedulePersist(room);
    this._emit(groupId, 'PRESENCE', { userId, presence, at });
    this.emit('presence', groupId, { userId, presence, at, rider: next });
    return next;
  }

  /**
   * The rider changed their phone, emergency contact or emergency-text opt-out: update their record
   * in the live ride (the opt-out stays server side) and tell the room to fetch the SMS roster again.
   */
  async applyProfile(userId, user, keys = null) {
    const rooms = [...this.rooms.values()].filter((r) => r.riders.has(userId));
    if (!rooms.length) {
      const meta = await this.repo.findActiveMembership(userId).catch(() => null);
      const room = meta && await this.getRoom(meta.groupId, { required: false }).catch(() => null);
      if (room && room.riders.has(userId)) rooms.push(room);
    }
    const p = profileOf(user);
    // 3.15: only the nearby-assistance switches changed: no roster refresh for the room.
    const rosterChange = !Array.isArray(keys) || keys.some((k) => !ASSIST_RIDER_KEYS.includes(k));
    for (const room of rooms) {
      const cur = room.riders.get(userId);
      const next = {
        ...cur, phone: p.phone, emergencyContact: p.emergencyContact, emergencyContactName: p.emergencyContactName, smsOptOut: p.smsOptOut,
        assistHelp: p.assistHelp, assistAsk: p.assistAsk, responderMedical: p.responderMedical,
      };
      room.riders.set(userId, next);
      room.dirty.add(userId);
      this._schedulePersist(room);
      if (cur.phone !== next.phone || cur.emergencyContact !== next.emergencyContact || cur.emergencyContactName !== next.emergencyContactName) {
        this._emit(room.groupId, 'RIDER_UPDATE', { rider: publicRider(next) });
      }
      if (rosterChange) this._emit(room.groupId, 'ROSTER_CHANGED', {});
    }
    return rooms.length;
  }

  // ------------------------------------------------------ outbox dedupe (3.14)
  /** True when this rider's message with this clientId was already applied in this room. */
  seenClientId(room, userId, clientId, type) {
    const map = room.clientIds || (room.clientIds = new Map());
    const k = `${userId}:${clientId}`;
    const at = map.get(k);
    if (at !== undefined) {
      if (now() - at <= config.clientIdTtlH * 3600000) return true;
      map.delete(k);
    }
    // Chat survives a gateway restart: the stored messages carry their clientId.
    if (type === 'CHAT') return room.messages.some((m) => m.senderId === userId && m.clientId === clientId);
    return false;
  }

  rememberClientId(room, userId, clientId) {
    const map = room.clientIds || (room.clientIds = new Map());
    const k = `${userId}:${clientId}`;
    map.delete(k);
    map.set(k, now());
    const cutoff = now() - config.clientIdTtlH * 3600000;
    for (const [key, at] of map) { if (at >= cutoff && map.size <= config.clientIdCache) break; map.delete(key); }
  }

  // ------------------------------------------------------ SMS roster (3.14)
  /**
   * Phone numbers for the caller's own SMS fallback during a live ride: every other rider with a
   * usable number who did not opt out (user id, role and number only), plus the caller's own
   * emergency contact. Built from memory. Throws 403 NOT_MEMBER / 409 RIDE_NOT_ACTIVE.
   */
  async emergencyRoster(groupId, userId) {
    const gid = typeof groupId === 'string' && groupId.length <= 64 ? groupId : '';
    let room = gid ? this.rooms.get(gid) : null;
    if (gid && !room) {
      // Only live convoys are loaded into memory; an ended one answers from its stored record.
      const meta = await this.repo.getConvoyMeta(gid);
      if (meta && ACTIVE_STATUSES.includes(meta.tripStatus)) room = await this.getRoom(gid, { required: false });
      else if (meta && meta.members?.[userId] && !(meta.members[userId].leftAt >= (meta.members[userId].joinedAt || 0))) {
        throw new ConvoyError('The ride is not active.', 409, 'RIDE_NOT_ACTIVE');
      }
    }
    const me = room?.riders.get(userId);
    if (!room || !me) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    if (!LIVE_STATUSES.includes(room.meta.tripStatus)) throw new ConvoyError('The ride is not active.', 409, 'RIDE_NOT_ACTIVE');
    const t = now();
    const mine = digits(validPhone(me.phone));
    const seen = new Set(mine ? [mine] : []);
    const rank = (r) => (r.role === 'LEAD' || room.meta.createdByUserId === r.userId ? 0 : r.role === 'SWEEPER' ? 1 : 2);
    const members = [];
    for (const r of [...room.riders.values()].sort((a, b) => rank(a) - rank(b))) {
      if (r.userId === userId || r.smsOptOut === true) continue;
      const phone = validPhone(r.phone);
      const key = digits(phone);
      if (!phone || seen.has(key)) continue;
      seen.add(key);
      members.push({ userId: r.userId, role: rank(r) === 0 ? 'LEAD' : (r.role || 'PACK'), phone });
    }
    const contactPhone = validPhone(me.emergencyContact);
    return {
      groupId: room.groupId, generatedAt: t, validUntil: t + config.rosterValidH * 3600000, cap: config.smsMaxRecipients,
      members,
      emergencyContact: contactPhone ? { name: String(me.emergencyContactName || ''), phone: contactPhone } : null,
    };
  }

  // ------------------------------------------------------ admin emergencies (3.14)
  /** Every open alert in every live convoy, newest first. No medical info, no phone numbers. */
  async emergencies() {
    const metas = await this.repo.listActiveConvoyMeta();
    const out = [];
    const seen = new Set();
    const rooms = [];
    for (const m of metas) {
      const room = await this.getRoom(m.groupId, { required: false });
      if (room) { rooms.push(room); seen.add(room.groupId); }
    }
    for (const room of this.rooms.values()) if (!seen.has(room.groupId)) rooms.push(room);
    for (const room of rooms) {
      if (!ACTIVE_STATUSES.includes(room.meta.tripStatus)) continue;
      const leadId = room.meta.createdByUserId && room.riders.has(room.meta.createdByUserId)
        ? room.meta.createdByUserId
        : [...room.riders.values()].find((r) => r.role === 'LEAD')?.userId;
      const lead = leadId ? { userId: leadId, name: room.riders.get(leadId)?.name || '' } : null;
      for (const a of room.alerts.values()) {
        if (a.resolved) continue;
        const rider = room.riders.get(a.userId);
        const sum = this._summary(room.groupId, a.alertId);
        const net = sum?.network;
        const u = await this.repo.findUserById(a.userId).catch(() => null);
        out.push({
          status: statusOf(a), source: sourceOf(a), severity: a.severity || severityOf(a.alertType, sourceOf(a)),
          network: net
            ? { state: net.state, stage: net.stage, notified: net.notified, responders: net.responders.map((x) => ({ name: x.name, status: x.status, etaS: x.etaS ?? null })) }
            : { state: 'OFF', stage: 0, notified: 0, responders: [] },
          falseAlarms30d: falseAlarmCount(u, now()),
          groupId: room.groupId, convoyName: room.meta.name || '', alertId: a.alertId, alertType: a.alertType || 'EMERGENCY', auto: !!a.auto,
          userId: a.userId, userName: a.userName || rider?.name || '', lat: a.lat || 0, lng: a.lng || 0,
          startedAt: a.timestamp || 0, occurredAt: a.occurredAt || a.timestamp || 0,
          presence: rider?.presence || '', lastSeenAt: rider?.lastSeenEpochMs || 0, riders: room.riders.size, lead,
          responders: respondersList(a.responders),
        });
      }
    }
    return out.sort((x, y) => y.startedAt - x.startedAt);
  }

  // ------------------------------------------------------ stops / config
  /**
   * Logs one rider's arrival / departure / pass at a planned stop (stopId) or
   * the destination (stopId null). Marks the stop visited once every rider
   * currently in the convoy has reached it. Returns { allReachedNow, count }.
   */
  async recordVisit(groupId, stopId, rider, patch) {
    const room = this.rooms.get(groupId);
    if (!room) return null;
    const entry = (prev) => ({ ...(prev || {}), name: rider.name, ...patch });
    const everyone = [...room.riders.keys()];
    let allReachedNow = false;
    if (stopId) {
      const stop = (room.meta.stopPoints || []).find((s) => s.stopId === stopId);
      if (!stop) return null;
      const arrivals = { ...(stop.arrivals || {}), [rider.userId]: entry(stop.arrivals?.[rider.userId]) };
      const all = everyone.length > 0 && everyone.every((u) => arrivals[u]?.arrivedAt);
      allReachedNow = all && !stop.isVisited;
      room.meta.stopPoints = room.meta.stopPoints.map((s) => (s.stopId === stopId ? { ...s, arrivals, ...(all ? { isVisited: true, visitedAt: s.visitedAt || now() } : {}) } : s));
      this._touch(room);
      await this.repo.saveConvoyMeta(room.meta);
      this._emit(groupId, 'STOPS', { stopPoints: room.meta.stopPoints });
    } else {
      const arrivals = { ...(room.meta.destinationArrivals || {}), [rider.userId]: entry(room.meta.destinationArrivals?.[rider.userId]) };
      const all = everyone.length > 0 && everyone.every((u) => arrivals[u]?.arrivedAt);
      allReachedNow = all && !room.meta.destinationAllReachedAt;
      room.meta.destinationArrivals = arrivals;
      if (allReachedNow) room.meta.destinationAllReachedAt = now();
      this._touch(room);
      await this.repo.saveConvoyMeta(room.meta);
      this._emit(groupId, 'DESTINATION_ARRIVALS', { destinationArrivals: arrivals, allReachedAt: room.meta.destinationAllReachedAt || 0 });
    }
    return { allReachedNow, count: everyone.length };
  }

  isLead(room, user) {
    const rider = room.riders.get(user.userId);
    return user.role === 'MASTER_ADMIN' || room.meta.createdByUserId === user.userId || rider?.role === 'LEAD';
  }

  _requireMember(room, user) {
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
  }

  _requireLead(room, user) {
    this._requireMember(room, user);
    if (!this.isLead(room, user)) throw new ConvoyError('Only the convoy lead can change the route.', 403);
  }

  async _saveStops(room, { route = true } = {}) {
    // Keep orderIndex 1..n in list order.
    room.meta.stopPoints = (room.meta.stopPoints || []).map((s, i) => ({ ...s, orderIndex: i + 1 }));
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(room.groupId, 'STOPS', { stopPoints: room.meta.stopPoints });
    if (route) this.recomputeRoute(room.groupId).catch((e) => this.log.warn('[convoys] route failed', e.message));
  }

  /**
   * The lead adds a planned stop; anyone else's stop becomes a suggestion the lead accepts or declines.
   * Lead only, optional: `insertBefore` (a stopId) puts the stop before that stop instead of at the end
   * (riding order), and `replaceStopId` removes an open (planned, not visited) MEETING stop in the same
   * change when the new stop is a MEETING stop ("Meet here" moves the meeting point). Unknown ids are ignored.
   */
  async addStop(groupId, user, p) {
    const room = await this.getRoom(groupId);
    this._requireMember(room, user);
    const lead = this.isLead(room, user);
    let list = [...(room.meta.stopPoints || [])];
    const [stop] = sanitizeStops([p], { by: user, status: lead ? 'PLANNED' : 'SUGGESTED' });
    if (!stop) throw new ConvoyError('Pick a place for the stop.');
    if (lead && stop.category === 'MEETING' && typeof p.replaceStopId === 'string' && p.replaceStopId) {
      list = list.filter((s) => !(s.stopId === p.replaceStopId && s.category === 'MEETING' && s.status === 'PLANNED' && !s.isVisited));
    }
    if (list.length >= MAX_STOPS) throw new ConvoyError(`A trip can have at most ${MAX_STOPS} stops.`);
    const at = lead && typeof p.insertBefore === 'string' && p.insertBefore ? list.findIndex((s) => s.stopId === p.insertBefore) : -1;
    if (at >= 0) list.splice(at, 0, stop); else list.push(stop);
    room.meta.stopPoints = list;
    await this._saveStops(room, { route: lead });
    this.emit('activity', groupId, { type: lead ? 'STOP_ADDED' : 'STOP_SUGGESTED', user, stop });
    return stop;
  }

  async suggestStop(groupId, user, p) {
    const room = await this.getRoom(groupId);
    this._requireMember(room, user);
    const [stop] = sanitizeStops([p], { by: user, status: 'SUGGESTED' });
    if (!stop) throw new ConvoyError('Pick a place for the stop.');
    if ((room.meta.stopPoints || []).length >= MAX_STOPS) throw new ConvoyError(`A trip can have at most ${MAX_STOPS} stops.`);
    room.meta.stopPoints = [...(room.meta.stopPoints || []), stop];
    await this._saveStops(room, { route: false });
    this.emit('activity', groupId, { type: 'STOP_SUGGESTED', user, stop });
    return stop;
  }

  /** Lead: accept (becomes a planned stop) or decline (removed) a suggestion. */
  async decideStop(groupId, user, stopId, accept) {
    const room = await this.getRoom(groupId);
    this._requireLead(room, user);
    const stop = (room.meta.stopPoints || []).find((s) => s.stopId === stopId);
    if (!stop || stop.status !== 'SUGGESTED') throw new ConvoyError('That suggestion is no longer open.', 404);
    if (accept) {
      room.meta.stopPoints = room.meta.stopPoints.map((s) => (s.stopId === stopId ? { ...s, status: 'PLANNED', acceptedBy: user.userId } : s));
    } else {
      room.meta.stopPoints = room.meta.stopPoints.filter((s) => s.stopId !== stopId);
    }
    await this._saveStops(room, { route: accept });
    if (accept) this.emit('activity', groupId, { type: 'STOP_ADDED', user, stop: { ...stop, status: 'PLANNED' }, suggestedBy: stop.suggestedByName });
    return true;
  }

  async removeStop(groupId, user, stopId) {
    const room = await this.getRoom(groupId);
    this._requireLead(room, user);
    const before = (room.meta.stopPoints || []).length;
    room.meta.stopPoints = (room.meta.stopPoints || []).filter((s) => s.stopId !== stopId);
    if (room.meta.stopPoints.length === before) return false;
    await this._saveStops(room);
    this.emit('activity', groupId, { type: 'ROUTE_CHANGED', user, change: 'STOP_REMOVED' });
    return true;
  }

  async skipStop(groupId, user, stopId) {
    const room = await this.getRoom(groupId);
    this._requireLead(room, user);
    const stop = (room.meta.stopPoints || []).find((s) => s.stopId === stopId);
    if (!stop) throw new ConvoyError('Stop not found.', 404);
    room.meta.stopPoints = room.meta.stopPoints.map((s) => (s.stopId === stopId ? { ...s, status: 'SKIPPED', skippedBy: user.userId } : s));
    await this._saveStops(room);
    this.emit('activity', groupId, { type: 'STOP_SKIPPED', user, stop });
    return true;
  }

  /** Lead: new stop order (list of stopIds). Unknown ids are ignored; stops not listed keep their place at the end. */
  async reorderStops(groupId, user, order) {
    const room = await this.getRoom(groupId);
    this._requireLead(room, user);
    const ids = Array.isArray(order) ? order.map(String) : [];
    const byId = new Map((room.meta.stopPoints || []).map((s) => [s.stopId, s]));
    const next = [];
    for (const id of ids) if (byId.has(id)) { next.push(byId.get(id)); byId.delete(id); }
    room.meta.stopPoints = [...next, ...byId.values()];
    await this._saveStops(room);
    this.emit('activity', groupId, { type: 'ROUTE_CHANGED', user, change: 'STOPS_REORDERED' });
    return room.meta.stopPoints;
  }

  /** Lead: change the start and/or the destination. */
  async setRoute(groupId, user, { start, destination } = {}) {
    const room = await this.getRoom(groupId);
    this._requireLead(room, user);
    const s = sanitizePlace(start);
    const d = sanitizePlace(destination);
    if (!s && !d) throw new ConvoyError('Pick a place.');
    if (s) { room.meta.start = s; room.meta.startLocationName = s.name || room.meta.startLocationName; }
    if (d) { room.meta.destinationLat = d.lat; room.meta.destinationLng = d.lng; room.meta.destinationName = d.name || 'Destination'; }
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'DESTINATION', {
      destinationName: room.meta.destinationName, destinationLat: room.meta.destinationLat, destinationLng: room.meta.destinationLng,
      start: room.meta.start || null, startLocationName: room.meta.startLocationName || '',
    });
    this.emit('activity', groupId, { type: 'ROUTE_CHANGED', user, change: d ? 'DESTINATION' : 'START', place: d || s });
    this.recomputeRoute(groupId).catch((e) => this.log.warn('[convoys] route failed', e.message));
    return true;
  }

  /** Waypoints: start, planned (not skipped, not suggested, not yet visited) stops in order, destination. */
  routeWaypoints(meta) {
    const wp = [];
    if (meta.start) wp.push({ lat: meta.start.lat, lng: meta.start.lng });
    for (const s of meta.stopPoints || []) {
      if (s.status === 'SUGGESTED' || s.status === 'SKIPPED') continue;
      wp.push({ lat: s.lat, lng: s.lng, stopId: s.stopId });
    }
    if (meta.destinationLat || meta.destinationLng) wp.push({ lat: meta.destinationLat, lng: meta.destinationLng });
    return wp.slice(0, 25);
  }

  /**
   * Computes the driving route through every waypoint (free OSRM through the
   * gateway cache). If the routing service is unavailable the route is the
   * straight line between the points, marked approximate, so the app always
   * has something to show and measure against.
   */
  async recomputeRoute(groupId) {
    const room = await this.getRoom(groupId, { required: false });
    if (!room) return null;
    const wp = this.routeWaypoints(room.meta);
    const seq = (this.routeSeq.get(groupId) || 0) + 1;
    this.routeSeq.set(groupId, seq);
    if (wp.length < 2) {
      room.meta.route = null;
      await this.repo.saveConvoyMeta(room.meta);
      this._emit(groupId, 'ROUTE', { route: null });
      return null;
    }
    let r = null;
    if (this.router) {
      try { r = await this.router(wp); } catch { r = null; }
    }
    if (this.routeSeq.get(groupId) !== seq || !this.rooms.has(groupId)) return null; // a newer request won
    const route = r ? { ...r, approximate: false } : straightRoute(wp);
    route.waypoints = wp;
    route.computedAt = now();
    room.meta.route = route;
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'ROUTE', { route: publicRoute(route) });
    return route;
  }

  async setStopVisited(groupId, user, stopId, isVisited) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    room.meta.stopPoints = (room.meta.stopPoints || []).map((s) => (s.stopId === stopId ? { ...s, isVisited: !!isVisited } : s));
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'STOPS', { stopPoints: room.meta.stopPoints });
  }

  async setRegroup(groupId, user, payload = {}) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const rider = room.riders.get(user.userId);
    const isLeadOrSweeper = rider.role === 'LEAD' || rider.role === 'SWEEPER' || room.meta.createdByUserId === user.userId || user.role === 'MASTER_ADMIN';
    if (!isLeadOrSweeper) {
      throw new ConvoyError('Only the lead or sweeper can designate a regroup point.', 403, 'NOT_AUTHORIZED');
    }
    const lat = num(payload.lat);
    const lng = num(payload.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      throw new ConvoyError('Valid coordinates required for regroup point.', 400);
    }
    const t = now();
    const regroup = {
      regroupId: `RG-${shortId(4)}`,
      stopId: payload.stopId ? String(payload.stopId) : null,
      lat: clampLat(lat),
      lng: clampLng(lng),
      name: String(payload.name || 'Regroup Ahead').trim().slice(0, 100) || 'Regroup Ahead',
      suggestedByUserId: user.userId,
      suggestedByName: user.name || rider.name || '',
      targetAction: String(payload.targetAction || 'PULL_OVER_AND_WAIT').slice(0, 50),
      targetKmh: Number.isFinite(num(payload.targetKmh)) ? Math.round(num(payload.targetKmh)) : 40,
      createdAt: t,
      expiresAt: t + (config.regroupTimeoutMin || 25) * 60000,
      resolved: false,
    };
    room.regroup = regroup;
    room.meta.activeRegroup = regroup;
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'REGROUP_ACTIVE', { groupId, regroup });
    this.emit('activity', groupId, {
      type: 'REGROUP_INITIATED',
      user,
      lat: regroup.lat,
      lng: regroup.lng,
      placeName: regroup.name,
      regroup,
    });
    return regroup;
  }

  async clearRegroup(groupId, user, reason = 'COMPLETED') {
    const room = await this.getRoom(groupId, { required: false });
    if (!room || (!room.regroup && !room.meta?.activeRegroup)) return null;
    const prev = room.regroup || room.meta.activeRegroup;
    room.regroup = null;
    delete room.meta.activeRegroup;
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    const completedAt = now();
    this._emit(groupId, 'REGROUP_COMPLETED', {
      groupId,
      regroup: prev,
      reason,
      completedAt,
    });
    this.emit('activity', groupId, {
      type: 'REGROUP_COMPLETED',
      user: user || { userId: 'SYSTEM', name: 'System' },
      lat: prev ? prev.lat : null,
      lng: prev ? prev.lng : null,
      placeName: prev ? prev.name : '',
      reason,
      completedAt,
    });
    return prev;
  }

  async updateConfig(groupId, user, patch) {
    const room = await this.getRoom(groupId);
    const operation = (room.configWrite || Promise.resolve()).catch(() => {}).then(() => this._updateConfig(groupId, user, patch));
    room.configWrite = operation;
    try { return await operation; }
    catch (e) { this.featureAnalytics.record('configuration', false); throw e; }
  }

  async _updateConfig(groupId, user, patch) {
    const room = await this.getRoom(groupId);
    const rider = room.riders.get(user.userId);
    if (!rider) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    if (rider.role !== 'LEAD' && room.meta.createdByUserId !== user.userId && user.role !== 'MASTER_ADMIN') {
      throw new ConvoyError('Only the convoy lead can change settings.', 403);
    }
    const updated = structuredClone(room.meta);
    let nextPolicy;
    if (patch.featurePolicy !== undefined) {
      try { nextPolicy = policyPatch(updated.featurePolicy, patch.featurePolicy); }
      catch (e) { throw new ConvoyError(e.message, 400); }
    }
    if (patch.distanceThresholdMeters !== undefined) updated.distanceThresholdMeters = Math.max(100, Math.min(20000, num(patch.distanceThresholdMeters, 1000)));
    if (patch.stopThresholdSeconds !== undefined) updated.stopThresholdSeconds = Math.max(30, Math.min(3600, num(patch.stopThresholdSeconds, 180)));
    if (patch.voiceGuidanceEnabled !== undefined) updated.voiceGuidanceEnabled = !!patch.voiceGuidanceEnabled;
    if (patch.speedLimitKmh !== undefined) updated.speedLimitKmh = speedLimit(patch.speedLimitKmh);
    // 3.16: lower limit near stops and in towns (0 = off; wrong types read as off).
    if (patch.townLimitKmh !== undefined && patch.townLimitKmh !== null && typeof patch.townLimitKmh !== 'boolean') updated.townLimitKmh = townLimit(patch.townLimitKmh);
    // 3.15: social visibility and the group default for nearby assistance (wrong types are ignored).
    if (patch.visibility === 'PUBLIC' || patch.visibility === 'PRIVATE') updated.visibility = patch.visibility;
    if (typeof patch.discovery === 'boolean') updated.discovery = patch.discovery;
    if (typeof patch.assistDefault === 'boolean') updated.assistDefault = patch.assistDefault;
    if (nextPolicy) updated.featurePolicy = nextPolicy;
    updated.updatedAt = now();
    await this.repo.saveConvoyMeta(updated);
    room.meta = updated;
    this.featureAnalytics.record('configuration', true);
    if (nextPolicy && !nextPolicy.groupFuelEnabled) {
      for (const [id, rider] of room.riders) {
        rider.fuelEstimate = null; room.dirty.add(id);
        this._emit(groupId, 'RIDER_UPDATE', { rider: publicRider(rider) });
      }
      this._schedulePersist(room);
    }
    const { distanceThresholdMeters, stopThresholdSeconds, voiceGuidanceEnabled } = room.meta;
    this._emit(groupId, 'CONFIG', {
      distanceThresholdMeters, stopThresholdSeconds, voiceGuidanceEnabled, speedLimitKmh: room.meta.speedLimitKmh || 0,
      townLimitKmh: room.meta.townLimitKmh || 0,
      featurePolicy: featurePolicy(room.meta.featurePolicy),
      visibility: room.meta.visibility === 'PUBLIC' ? 'PUBLIC' : 'PRIVATE', discovery: room.meta.discovery === true, assistDefault: room.meta.assistDefault !== false,
    });
  }

  /**
   * Account deletion: removes the rider from every convoy loaded in memory (name, ids and
   * contact details replaced, their messages, wait card and SOS alerts dropped) and saves
   * those convoys, so a later flush can never write the old details back.
   * Returns the groupIds of all loaded convoys (their metadata in memory is authoritative).
   */
  async forgetUser(id) {
    const live = new Set();
    for (const room of this.rooms.values()) {
      live.add(room.groupId);
      const uid = id.userId;
      const before = room.messages.length;
      room.messages = room.messages.filter((m) => m.senderId !== uid && !(m.senderId === 'SYSTEM' && (m.requestedBy === uid || (id.name && m.senderName === id.name))));
      let touched = room.messages.length !== before;
      if (room.clientIds) for (const k of [...room.clientIds.keys()]) if (k.startsWith(`${uid}:`)) room.clientIds.delete(k);
      for (const [alertId, a] of [...room.alerts.entries()]) {
        if (a.userId === uid) { room.alerts.delete(alertId); touched = true; } else if (mentions(a, id)) { room.alerts.set(alertId, scrub(a, id)); touched = true; }
      }
      for (const [rid, r] of [...room.riders.entries()]) {
        if (mentions(r, id)) { room.riders.set(rid, scrub(r, id)); room.dirty.add(rid); touched = true; }
      }
      if (mentions(room.meta, id)) { room.meta = scrubConvoyMeta(room.meta, id); touched = true; }
      if (touched) {
        await this.repo.saveConvoyMeta(room.meta);
        await this.flushRoom(room).catch(() => {});
      }
    }
    return live;
  }

  // ---------------------------------------------------------------- admin
  async fleet() {
    const metas = await this.repo.listActiveConvoyMeta();
    const out = [];
    for (const m of metas) {
      const room = await this.getRoom(m.groupId, { required: false });
      if (room) out.push(this.snapshot(room, { admin: true }));
    }
    return out;
  }

  async adminDissolve(groupId) {
    const room = await this.getRoom(groupId, { required: false });
    if (room) {
      this._emit(groupId, 'DISSOLVED', {});
      clearTimeout(room.persistTimer);
      this.rooms.delete(groupId);
      this.emit('roomEnded', groupId, room);
    }
    await this.repo.deleteConvoyCascade(groupId);
    this.emit('fleet');
  }

  async adminBroadcast(user, message) {
    const clean = String(message || '').trim().slice(0, 300);
    if (!clean) throw new ConvoyError('Message is required.');
    const entry = { message: clean, timestamp: now(), byUserId: user.userId };
    await this.repo.addBroadcast(entry);
    this.emit('broadcast', entry);
    return entry;
  }

  // ------------------------------------------------------- housekeeping
  async autoEndStaleConvoys(cutoffMs) {
    const stale = await this.repo.listStaleActiveConvoys(cutoffMs);
    for (const m of stale) {
      try { await this.setTripStatus(m.groupId, 'ENDED', { system: true }); } catch { /* ignore */ }
    }
    return stale.length;
  }
}

function memberRecord(user, rider, joinedAt) {
  return {
    userId: user.userId, name: user.name, role: rider.role || 'PACK', vehicleType: rider.vehicleType || '',
    vehicleNo: rider.vehicleNo || '', joinedAt: joinedAt || rider.joinedAt || Date.now(),
  };
}

function sanitizeStops(list, { by, status }) {
  if (!Array.isArray(list)) return [];
  const out = [];
  for (const p of list.slice(0, MAX_STOPS)) {
    const place = sanitizePlace(p);
    if (!place) continue;
    const cat = String(p.category || 'REST').toUpperCase();
    out.push({
      stopId: `STOP-${shortId(3)}`, name: String(p.name || place.name || 'Stop').slice(0, 80), lat: place.lat, lng: place.lng,
      orderIndex: out.length + 1, category: STOP_CATEGORIES.has(cat) ? cat : 'OTHER', isVisited: false,
      status, plannedDwellMin: Math.max(0, Math.min(600, Math.round(num(p.plannedDwellMin, 0)))),
      suggestedBy: by?.userId || '', suggestedByName: by?.name || '', createdAt: now(),
    });
  }
  return out;
}

function straightRoute(wp) {
  const legs = [];
  for (let i = 1; i < wp.length; i++) {
    const d = haversine(wp[i - 1].lat, wp[i - 1].lng, wp[i].lat, wp[i].lng);
    legs.push({ distanceM: Math.round(d), durationS: Math.round(d / (45 / 3.6)) }); // 45 km/h estimate
  }
  return {
    approximate: true,
    distanceM: legs.reduce((a, l) => a + l.distanceM, 0),
    durationS: legs.reduce((a, l) => a + l.durationS, 0),
    polyline: encodePolyline(wp),
    legs,
  };
}

function publicRoute(r) {
  return { distanceM: r.distanceM || 0, durationS: r.durationS || 0, polyline: r.polyline || '', legs: r.legs || [], approximate: !!r.approximate, computedAt: r.computedAt || 0 };
}

function sanitizePlace(p) {
  if (!p || typeof p !== 'object') return null;
  const lat = Number(p.lat), lng = Number(p.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || (lat === 0 && lng === 0)) return null;
  return { lat: clampLat(lat), lng: clampLng(lng), name: String(p.name || '').slice(0, 120) };
}

/** Typed copy of the telemetry fields present in a client message (unknown fields are dropped). */
function sanitizeTelemetry(patch) {
  const out = {};
  if (!patch || typeof patch !== 'object') return out;
  const has = (k) => patch[k] !== undefined && patch[k] !== null;
  if (has('lat')) out.lat = clampLat(patch.lat);
  if (has('lng')) out.lng = clampLng(patch.lng);
  if (has('speedKmh')) out.speedKmh = Math.max(0, Math.min(300, num(patch.speedKmh)));
  if (has('heading')) out.heading = ((num(patch.heading) % 360) + 360) % 360;
  if (has('batteryLevel')) out.batteryLevel = Math.max(0, Math.min(100, Math.round(num(patch.batteryLevel, 100))));
  if (has('isCharging')) out.isCharging = !!patch.isCharging;
  if (has('statusReason')) out.statusReason = String(patch.statusReason).slice(0, 24);
  if (has('statusMessage')) out.statusMessage = String(patch.statusMessage).slice(0, 140);
  if (has('stoppedSince')) out.stoppedSince = Math.max(0, Math.min(now() + 60000, Math.round(num(patch.stoppedSince))));
  if (Object.hasOwn(patch, 'fuelEstimate')) {
    const f = patch.fuelEstimate;
    out.fuelEstimate = f && Number.isFinite(f.usableKm) && f.usableKm >= 0 && f.usableKm <= 15000
      && Number.isFinite(f.confirmedAt) && f.confirmedAt > 0 && f.confirmedAt <= now() + 60000
      ? { usableKm: Math.floor(f.usableKm), confirmedAt: f.confirmedAt, updatedAt: now() } : null;
  }
  return out;
}

/** Profile fields shown to convoy-mates, always from the users table (never from the client). */
function profileOf(u) {
  if (!u) return {};
  const pillion = (u.vehicleType || '').trim().toLowerCase() === 'pillion rider' || (u.vehicleNo || '').trim().toUpperCase() === 'PILLION';
  return {
    phone: String(u.phone || ''),
    vehicleType: pillion ? 'Pillion Rider' : String(u.vehicleType || 'Motorcycle'),
    vehicleNo: pillion ? 'PILLION' : String(u.vehicleNo || ''),
    emergencyContact: String(u.emergencyContact || ''),
    emergencyContactName: String(u.emergencyContactName || ''),
    smsOptOut: !!u.smsOptOut, // server only: never in publicRider
    // 3.15 nearby assistance, server only (never in publicRider).
    assistHelp: u.assistHelp !== false,
    assistAsk: u.assistAsk !== false,
    responderMedical: u.responderMedical === true,
  };
}

/** What the safety network needs from the subject's users doc at raise (memory only). */
function ownerInfo(u) {
  if (!u) return null;
  return {
    assistAsk: typeof u.assistAsk === 'boolean' ? u.assistAsk : undefined,
    responderMedical: u.responderMedical === true,
    falseAlarmAt: Array.isArray(u.falseAlarmAt) ? u.falseAlarmAt.filter(Number.isFinite) : [],
  };
}

/** False alarms of a user within ABUSE_WINDOW_D. */
function falseAlarmCount(u, t) {
  const list = u && Array.isArray(u.falseAlarmAt) ? u.falseAlarmAt : [];
  return list.filter((x) => Number.isFinite(x) && t - x <= config.abuseWindowD * 86400000).length;
}

/** Segment index of the point on the group's route polyline (within NET_ON_ROUTE_M), or null. */
function routeIndexOf(meta, lat, lng) {
  const poly = meta && meta.route && meta.route.polyline;
  if (typeof poly !== 'string' || !poly || !(lat || lng)) return null;
  const line = decodePolyline(poly, 50000);
  if (!line || line.length < 2) return null;
  let best = null;
  for (let i = 0; i < line.length - 1; i++) {
    const d = pointToSegment({ lat, lng }, line[i], line[i + 1]).dist;
    if (!best || d < best.d) best = { d, i };
  }
  return best && best.d <= config.netOnRouteM ? best.i : null;
}

/** What a client may send about itself when creating or joining: position, heading, battery and bike colour. */
function clientRiderInput(p) {
  const out = sanitizeTelemetry({ lat: p?.lat, lng: p?.lng, heading: p?.heading, batteryLevel: p?.batteryLevel, isCharging: p?.isCharging });
  if (p && p.vehicleColor !== undefined && p.vehicleColor !== null) out.vehicleColor = String(p.vehicleColor).slice(0, 20);
  return out;
}

function stripKey(o) { const { key, ...rest } = o; return rest; }

function publicRider(r) {
  // Everything the convoy-mates need; nothing they don't.
  return {
    userId: r.userId, name: r.name, vehicleType: r.vehicleType || 'Motorcycle', vehicleColor: r.vehicleColor || 'Black',
    lat: r.lat || 0, lng: r.lng || 0, speedKmh: r.speedKmh || 0, heading: r.heading || 0,
    batteryLevel: r.batteryLevel ?? 100, isCharging: !!r.isCharging, role: r.role || 'PACK',
    statusReason: r.statusReason || '', statusMessage: r.statusMessage || '', lastSeenEpochMs: r.lastSeenEpochMs || 0,
    phone: r.phone || '', emergencyContact: r.emergencyContact || '', emergencyContactName: r.emergencyContactName || '',
    vehicleNo: r.vehicleNo || '', isCoRiding: !!r.isCoRiding, ridingWithUserId: r.ridingWithUserId || '', stoppedSince: r.stoppedSince || 0,
    presence: r.presence || '', presenceAt: r.presenceAt || 0,
    fuelEstimate: r.fuelEstimate && now() - r.fuelEstimate.updatedAt < 120000 ? r.fuelEstimate : null,
  };
}

function buildRider(user, p, t) {
  return {
    ...publicRider({
      ...p,
      userId: user.userId,
      name: user.name,
      lat: p.lat, lng: p.lng, speedKmh: 0, heading: num(p.heading),
      lastSeenEpochMs: t,
    }),
    joinedAt: p.joinedAt || t,
    smsOptOut: !!p.smsOptOut,
    assistHelp: p.assistHelp !== false,
    assistAsk: p.assistAsk !== false,
    responderMedical: p.responderMedical === true,
  };
}

/** A number within [min, max] rounded to 1 decimal, or null when absent / not a number. */
function boundedNumber(v, min, max) {
  if (v === undefined || v === null || v === '' || typeof v === 'boolean') return null;
  const n = Number(v);
  if (!Number.isFinite(n)) return null;
  return Math.round(Math.max(min, Math.min(max, n)) * 10) / 10;
}

/** An epoch ms time clamped to [min, max]; `def` when absent or not a number. */
function clampTime(v, min, max, def) {
  const n = Number(v);
  if (v === undefined || v === null || typeof v === 'boolean' || !Number.isFinite(n)) return def;
  return Math.round(Math.max(min, Math.min(max, n)));
}

/** SOS kind: upper case A-Z and _ (1 to 24), else EMERGENCY. */
function sosType(v) {
  const s = typeof v === 'string' ? v.trim().toUpperCase() : '';
  return /^[A-Z_]{1,24}$/.test(s) ? s : 'EMERGENCY';
}

/** The optional medical info of a users document, or null when nothing is filled in. */
function medicalOf(u) {
  if (!u) return null;
  const m = {};
  if (u.bloodGroup) m.bloodGroup = String(u.bloodGroup);
  if (u.allergies) m.allergies = String(u.allergies);
  if (u.medicalNotes) m.notes = String(u.medicalNotes);
  return Object.keys(m).length ? m : null;
}

function respondersList(map) {
  return Object.values(map || {}).filter((r) => r && r.userId)
    .map((r) => ({ userId: r.userId, name: r.name || '', kind: r.kind, at: r.at || 0 }))
    .sort((a, b) => a.at - b.at);
}

/**
 * An alert as sent on the wire: responders as a list; medical info only for the convoy room
 * (`medical: false` for admins and the fleet feed), and only while the alert is open.
 */
function publicAlert(a, { medical = true, summary = null } = {}) {
  const { key, groupId, medical: med, responders, network, ownNearest, liveLink, liveLinkCount, hospitalTried, ...rest } = a;
  const source = sourceOf(a);
  const out = {
    ...rest, auto: !!a.auto, details: a.details || {}, occurredAt: a.occurredAt || a.timestamp || 0, responders: respondersList(responders),
    // 3.15 EmergencyEvent fields (old docs get derived values; old apps ignore them).
    status: statusOf(a), source, severity: a.severity || severityOf(a.alertType, source),
    heading: Number.isFinite(a.heading) ? a.heading : null,
    speedKmh: Number.isFinite(a.speedKmh) ? a.speedKmh : null,
    accuracyM: Number.isFinite(a.accuracyM) ? a.accuracyM : null,
    routeIndex: Number.isInteger(a.routeIndex) ? a.routeIndex : null,
    confirmedAt: a.confirmedAt || a.timestamp || 0,
    lastUpdateAt: a.lastUpdateAt || a.timestamp || 0,
    reportedBy: a.reportedBy || '', reportedByName: a.reportedByName || '',
    resolveReason: a.resolveReason || null,
  };
  if (summary && summary.network) out.network = summary.network;
  if (summary && summary.ownNearest !== undefined) out.ownNearest = summary.ownNearest;
  if (medical && med && !a.resolved) out.medical = med;
  // 3.16: the live link's times only (never the hash), and the nearest hospital once known.
  if (liveLink && liveLink.hash) out.liveLink = { expiresAt: liveLink.expiresAt || 0, revokedAt: liveLink.revokedAt || 0 };
  if (a.nearestHospital && a.nearestHospital.name) out.nearestHospital = a.nearestHospital;
  return out;
}

function digits(phone) { return String(phone || '').replace(/[^0-9]/g, '').slice(-10); }

function withTimeout(p, ms) {
  let timer;
  const t = new Promise((resolve) => { timer = setTimeout(() => resolve(null), ms); if (timer.unref) timer.unref(); });
  return Promise.race([Promise.resolve(p), t]).finally(() => clearTimeout(timer));
}

function sanitizeBreadcrumbs(list) {
  if (!Array.isArray(list)) return [];
  return list.slice(0, 5000)
    .filter((p) => p && Number.isFinite(Number(p.lat)) && Number.isFinite(Number(p.lng)))
    .map((p) => ({ lat: clampLat(p.lat), lng: clampLng(p.lng) }));
}

module.exports = {
  ConvoyManager, ConvoyError, publicRider, publicAlert, sanitizeTelemetry, TELEMETRY_FIELDS, TRUSTED_FIELDS, WAIT_MESSAGE, SOS_TYPES, LIVE_STATUSES,
  statusOf, sourceOf, severityOf, isOpenStatus, falseAlarmCount, ownerInfo, EMERGENCY_OPEN, EMERGENCY_TERMINAL, EMERGENCY_SOURCES,
  townLimit, sha256,
};
