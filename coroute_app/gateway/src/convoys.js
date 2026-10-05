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

class ConvoyError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; this.name = 'ConvoyError'; }
}

const RIDER_PATCH_FIELDS = new Set([
  'lat', 'lng', 'speedKmh', 'heading', 'batteryLevel', 'isCharging', 'statusReason', 'statusMessage',
  'stoppedSince', 'isCoRiding', 'ridingWithUserId', 'vehicleType', 'vehicleColor', 'vehicleNo', 'phone',
  'emergencyContact', 'emergencyContactName', 'role',
]);

const shortId = (n = 4) => crypto.randomBytes(n).toString('hex').toUpperCase();
const now = () => Date.now();

function num(v, def = 0) { const n = Number(v); return Number.isFinite(n) ? n : def; }
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
    if (!room && required) throw new ConvoyError('Convoy not found.', 404);
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
      routeBreadcrumbs: m.routeBreadcrumbs || [],
      start: m.start || null,
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
      routeBreadcrumbs: sanitizeBreadcrumbs(p.routeBreadcrumbs),
      stopPoints: [],
      waitRequests: {},
      members: { [user.userId]: memberRecord(user, { ...(p.rider || {}), role: 'LEAD' }, t) },
    });
    const rider = buildRider(user, { ...(p.rider || {}), role: 'LEAD' }, t);
    await this.repo.upsertRider(groupId, rider);

    const room = {
      groupId, meta, riders: new Map([[rider.userId, rider]]), messages: [], alerts: new Map(),
      dirty: new Set(), lastPersist: new Map(), persistTimer: null,
    };
    this.rooms.set(groupId, room);
    this.emit('fleet');
    const at = meta.start || (rider.lat || rider.lng ? { lat: rider.lat, lng: rider.lng, name: '' } : null);
    this.emit('activity', groupId, { type: 'TRIP_STARTED', user, name, lat: at?.lat, lng: at?.lng, placeName: at?.name || meta.startLocationName || '' });
    return this.snapshot(room);
  }

  async joinByCode(user, code, riderProfile = {}) {
    const clean = String(code || '').trim().toUpperCase();
    if (!/^[A-Z0-9]{4,10}$/.test(clean)) throw new ConvoyError('Invalid join code.');
    const meta = await this.repo.getActiveConvoyByJoinCode(clean);
    if (!meta) throw new ConvoyError('No active convoy found for that code.', 404);

    const room = await this.getRoom(meta.groupId);
    if (!room.riders.has(user.userId)) await this.leaveAll(user.userId, { except: meta.groupId });

    const existing = room.riders.get(user.userId);
    const rider = buildRider(user, { ...(existing || {}), ...riderProfile, role: existing?.role || 'PACK' }, now());
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
  /** Applies a telemetry/status patch to one rider. Memory first, DB later. */
  patchRider(room, userId, patch, { emit = true } = {}) {
    const current = room.riders.get(userId);
    if (!current) throw new ConvoyError('Not a member of this convoy.', 403);
    const next = { ...current };
    for (const [k, v] of Object.entries(patch || {})) {
      if (!RIDER_PATCH_FIELDS.has(k) || v === undefined || v === null) continue;
      next[k] = v;
    }
    if (patch.lat !== undefined) next.lat = clampLat(patch.lat);
    if (patch.lng !== undefined) next.lng = clampLng(patch.lng);
    if (patch.speedKmh !== undefined) next.speedKmh = Math.max(0, Math.min(300, num(patch.speedKmh)));
    if (patch.heading !== undefined) next.heading = ((num(patch.heading) % 360) + 360) % 360;
    if (patch.batteryLevel !== undefined) next.batteryLevel = Math.max(0, Math.min(100, Math.round(num(patch.batteryLevel, 100))));
    next.lastSeenEpochMs = now();
    room.riders.set(userId, next);
    room.dirty.add(userId);
    this._schedulePersist(room);
    if (patch.lat !== undefined && patch.lng !== undefined) this.emit('telemetry', room.groupId, next);
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
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403);
    const clean = String(text || '').trim().slice(0, 500);
    if (!clean) throw new ConvoyError('Message text is required.');
    const msg = {
      messageId: `MSG-${shortId(4)}`, senderId: user.userId, senderName: user.name, text: clean,
      timestamp: now(), isQuickCard: !!isQuickCard, cardType: String(cardType || 'CUSTOM').slice(0, 24),
    };
    room.messages.push(msg);
    if (room.messages.length > 500) room.messages.splice(0, room.messages.length - 500);
    await this.repo.addMessage(groupId, msg);
    this._emit(groupId, 'MESSAGE', { message: msg });
    return msg;
  }

  async requestWait(groupId, user) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403);
    room.meta.waitRequests = { ...(room.meta.waitRequests || {}), [user.name]: now() };
    // Expire stale wait requests (>2 min) while we are here.
    for (const [k, v] of Object.entries(room.meta.waitRequests)) if (now() - v > 150000) delete room.meta.waitRequests[k];
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'WAIT_REQUESTS', { waitRequests: room.meta.waitRequests });
    return this.sendMessage(groupId, { userId: 'SYSTEM', name: user.name }, {
      text: '⏱️ Requested a 2-minute pull-over stop. Please regroup safely.', isQuickCard: true, cardType: 'WAIT_2MIN',
    }).catch(() => null);
  }

  async raiseSos(groupId, user, { lat, lng, type, alertType }) {
    type = alertType || type || 'EMERGENCY';
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403);
    const alert = {
      alertId: `SOS-${crypto.randomUUID()}`, userId: user.userId, userName: user.name,
      lat: clampLat(lat), lng: clampLng(lng), alertType: String(type).slice(0, 24), timestamp: now(), resolved: false,
    };
    room.alerts.set(alert.alertId, alert);
    await this.repo.addAlert(groupId, alert);
    this._emit(groupId, 'ALERT', { alert });
    this.emit('fleet');
    return alert;
  }

  async resolveSos(groupId, user, alertId) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId) && user.role !== 'MASTER_ADMIN') throw new ConvoyError('Not a member of this convoy.', 403);
    const a = room.alerts.get(alertId);
    if (a) { a.resolved = true; a.resolvedAt = now(); a.resolvedBy = user.userId; }
    await this.repo.resolveAlert(groupId, alertId, user.userId);
    this._emit(groupId, 'ALERT_RESOLVED', { alertId, by: user.userId });
    this.emit('fleet');
    return true;
  }

  // ------------------------------------------------------ stops / config
  async addStop(groupId, user, { name, lat, lng, category = 'REST' }) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403);
    const stop = {
      stopId: `STOP-${shortId(3)}`, name: String(name || 'Stop').slice(0, 80), lat: clampLat(lat), lng: clampLng(lng),
      orderIndex: (room.meta.stopPoints || []).length + 1, category: String(category).slice(0, 24), isVisited: false,
    };
    room.meta.stopPoints = [...(room.meta.stopPoints || []), stop];
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'STOPS', { stopPoints: room.meta.stopPoints });
    this.emit('activity', groupId, { type: 'STOP_ADDED', user, stop });
    return stop;
  }

  async setStopVisited(groupId, user, stopId, isVisited) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403);
    room.meta.stopPoints = (room.meta.stopPoints || []).map((s) => (s.stopId === stopId ? { ...s, isVisited: !!isVisited } : s));
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'STOPS', { stopPoints: room.meta.stopPoints });
  }

  async updateConfig(groupId, user, patch) {
    const room = await this.getRoom(groupId);
    const rider = room.riders.get(user.userId);
    if (!rider) throw new ConvoyError('Not a member of this convoy.', 403);
    if (rider.role !== 'LEAD' && room.meta.createdByUserId !== user.userId && user.role !== 'MASTER_ADMIN') {
      throw new ConvoyError('Only the convoy lead can change settings.', 403);
    }
    if (patch.distanceThresholdMeters !== undefined) room.meta.distanceThresholdMeters = Math.max(100, Math.min(20000, num(patch.distanceThresholdMeters, 1000)));
    if (patch.stopThresholdSeconds !== undefined) room.meta.stopThresholdSeconds = Math.max(30, Math.min(3600, num(patch.stopThresholdSeconds, 180)));
    if (patch.voiceGuidanceEnabled !== undefined) room.meta.voiceGuidanceEnabled = !!patch.voiceGuidanceEnabled;
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    const { distanceThresholdMeters, stopThresholdSeconds, voiceGuidanceEnabled } = room.meta;
    this._emit(groupId, 'CONFIG', { distanceThresholdMeters, stopThresholdSeconds, voiceGuidanceEnabled });
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

function sanitizePlace(p) {
  if (!p || typeof p !== 'object') return null;
  const lat = Number(p.lat), lng = Number(p.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || (lat === 0 && lng === 0)) return null;
  return { lat: clampLat(lat), lng: clampLng(lng), name: String(p.name || '').slice(0, 120) };
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

module.exports = { ConvoyManager, ConvoyError, publicRider };
