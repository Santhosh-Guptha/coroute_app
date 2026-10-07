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
const { ACTIVE_STATUSES } = require('./oracle/repo');
const { haversine, encodePolyline } = require('./geo_math');
const { scrub, scrubConvoyMeta, mentions } = require('./anonymise');

const STOP_CATEGORIES = new Set(['FUEL', 'FOOD', 'REST', 'SCENIC', 'TOLL', 'OTHER']);
/** The chat card posted when a rider asks the group to wait (plain text, no emoji). */
const WAIT_MESSAGE = 'Asked the group for a 2 minute stop. Please regroup safely.';
const MAX_STOPS = 20;

class ConvoyError extends Error {
  /** reason: machine-readable cause. The app leaves a convoy only for NOT_MEMBER / CONVOY_GONE, never for other errors. */
  constructor(message, status = 400, reason = undefined) { super(message); this.status = status; this.name = 'ConvoyError'; this.reason = reason; }
}

/**
 * The only rider fields a client message may change. Role, profile (phone, vehicle,
 * emergency contact) and co-riding are never taken from a socket message: role and
 * co-riding are set by server code paths only, the profile comes from the users table.
 */
const TELEMETRY_FIELDS = ['lat', 'lng', 'speedKmh', 'heading', 'batteryLevel', 'isCharging', 'statusReason', 'statusMessage', 'stoppedSince'];
/** Extra fields only trusted server code may set (CORIDER handler). */
const TRUSTED_FIELDS = ['isCoRiding', 'ridingWithUserId'];

const shortId = (n = 4) => crypto.randomBytes(n).toString('hex').toUpperCase();
const now = () => Date.now();

function num(v, def = 0) { const n = Number(v); return Number.isFinite(n) ? n : def; }
/** Group speed limit in km/h: 0 means off, otherwise 20-200 in whole km/h. */
function speedLimit(v) { const n = Math.round(num(v, 0)); return n <= 0 ? 0 : Math.max(20, Math.min(200, n)); }
function clampLat(v) { return Math.max(-90, Math.min(90, num(v))); }
function clampLng(v) { return Math.max(-180, Math.min(180, num(v))); }

class ConvoyManager extends EventEmitter {
  /** @param {import('./oracle/repo').Repo} repo */
  constructor(repo, opts = {}) {
    super();
    this.repo = repo;
    this.rooms = new Map(); // groupId -> room
    this.persistIntervalMs = opts.persistIntervalMs ?? config.riderPersistIntervalMs;
    this.log = opts.logger || console;
    /** async (waypoints[]) => { distanceM, durationS, polyline, legs[] } | null. Set by app.js (GeoProxy). */
    this.router = opts.router || null;
    this.routeSeq = new Map(); // groupId -> latest route request number (stale answers are ignored)
  }

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
    };
    this.rooms.set(groupId, room);
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
  snapshot(room) {
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
      activeAlerts: [...room.alerts.values()].filter((a) => !a.resolved),
      messages: room.messages.slice(-200),
      stopPoints: m.stopPoints || [],
      pendingMembers: {},
      waitRequests: m.waitRequests || {},
      distanceThresholdMeters: m.distanceThresholdMeters ?? 1000,
      stopThresholdSeconds: m.stopThresholdSeconds ?? 180,
      voiceGuidanceEnabled: m.voiceGuidanceEnabled ?? true,
      speedLimitKmh: m.speedLimitKmh || 0,
      routeBreadcrumbs: m.routeBreadcrumbs || [],
      start: m.start || null,
      route: m.route ? publicRoute(m.route) : null,
      destinationArrivals: m.destinationArrivals || {},
      members: Object.values(m.members || {}).map((x) => ({ userId: x.userId, name: x.name, role: x.role, joinedAt: x.joinedAt, leftAt: x.leftAt || 0 })),
    };
  }

  async getSnapshot(groupId) { return this.snapshot(await this.getRoom(groupId)); }

  async isMember(groupId, userId) {
    const room = await this.getRoom(groupId, { required: false });
    return !!room && room.riders.has(userId) && ACTIVE_STATUSES.includes(room.meta.tripStatus);
  }

  _emit(groupId, type, payload = {}) {
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
      dirty: new Set(), lastPersist: new Map(), persistTimer: null,
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
  async sendMessage(groupId, user, { text, isQuickCard = false, cardType = 'CUSTOM' }) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const clean = String(text || '').trim().slice(0, 500);
    if (!clean) throw new ConvoyError('Message text is required.');
    const msg = {
      messageId: `MSG-${shortId(4)}`, senderId: user.userId, senderName: user.name, text: clean,
      timestamp: now(), isQuickCard: !!isQuickCard, cardType: String(cardType || 'CUSTOM').slice(0, 24),
    };
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
   * Returns { alert, duplicate }.
   */
  async raiseSos(groupId, user, { lat, lng, type, alertType, clientId } = {}) {
    type = alertType || type || 'EMERGENCY';
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
    const alert = {
      alertId: `SOS-${crypto.randomUUID()}`, userId: user.userId, userName: user.name,
      lat: clampLat(lat), lng: clampLng(lng), alertType: String(type).slice(0, 24), timestamp: now(), resolved: false,
      ...(cid ? { clientId: cid } : {}),
    };
    room.alerts.set(alert.alertId, alert);
    await this.repo.addAlert(groupId, alert);
    this._emit(groupId, 'ALERT', { alert });
    this.emit('fleet');
    return { alert, duplicate: false };
  }

  async resolveSos(groupId, user, alertId) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId) && user.role !== 'MASTER_ADMIN') throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const a = room.alerts.get(alertId);
    if (a) { a.resolved = true; a.resolvedAt = now(); a.resolvedBy = user.userId; }
    await this.repo.resolveAlert(groupId, alertId, user.userId);
    this._emit(groupId, 'ALERT_RESOLVED', { alertId, by: user.userId });
    this.emit('fleet');
    return true;
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

  /** The lead adds a planned stop; anyone else's stop becomes a suggestion the lead accepts or declines. */
  async addStop(groupId, user, p) {
    const room = await this.getRoom(groupId);
    this._requireMember(room, user);
    const lead = this.isLead(room, user);
    if ((room.meta.stopPoints || []).length >= MAX_STOPS) throw new ConvoyError(`A trip can have at most ${MAX_STOPS} stops.`);
    const [stop] = sanitizeStops([p], { by: user, status: lead ? 'PLANNED' : 'SUGGESTED' });
    if (!stop) throw new ConvoyError('Pick a place for the stop.');
    room.meta.stopPoints = [...(room.meta.stopPoints || []), stop];
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

  async updateConfig(groupId, user, patch) {
    const room = await this.getRoom(groupId);
    const rider = room.riders.get(user.userId);
    if (!rider) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    if (rider.role !== 'LEAD' && room.meta.createdByUserId !== user.userId && user.role !== 'MASTER_ADMIN') {
      throw new ConvoyError('Only the convoy lead can change settings.', 403);
    }
    if (patch.distanceThresholdMeters !== undefined) room.meta.distanceThresholdMeters = Math.max(100, Math.min(20000, num(patch.distanceThresholdMeters, 1000)));
    if (patch.stopThresholdSeconds !== undefined) room.meta.stopThresholdSeconds = Math.max(30, Math.min(3600, num(patch.stopThresholdSeconds, 180)));
    if (patch.voiceGuidanceEnabled !== undefined) room.meta.voiceGuidanceEnabled = !!patch.voiceGuidanceEnabled;
    if (patch.speedLimitKmh !== undefined) room.meta.speedLimitKmh = speedLimit(patch.speedLimitKmh);
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    const { distanceThresholdMeters, stopThresholdSeconds, voiceGuidanceEnabled } = room.meta;
    this._emit(groupId, 'CONFIG', { distanceThresholdMeters, stopThresholdSeconds, voiceGuidanceEnabled, speedLimitKmh: room.meta.speedLimitKmh || 0 });
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
      if (room) out.push(this.snapshot(room));
    }
    return out;
  }

  async adminDissolve(groupId) {
    const room = await this.getRoom(groupId, { required: false });
    if (room) {
      this._emit(groupId, 'DISSOLVED', {});
      clearTimeout(room.persistTimer);
      this.rooms.delete(groupId);
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
  };
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
  };
}

function sanitizeBreadcrumbs(list) {
  if (!Array.isArray(list)) return [];
  return list.slice(0, 5000)
    .filter((p) => p && Number.isFinite(Number(p.lat)) && Number.isFinite(Number(p.lng)))
    .map((p) => ({ lat: clampLat(p.lat), lng: clampLng(p.lng) }));
}

module.exports = { ConvoyManager, ConvoyError, publicRider, sanitizeTelemetry, TELEMETRY_FIELDS, TRUSTED_FIELDS, WAIT_MESSAGE };
