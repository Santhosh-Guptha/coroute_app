'use strict';
/**
 * ConvoyManager - the single authority for live convoy state.
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
const { resolvePlan, clampSeats } = require('./entitlements');
const { FeatureAnalytics } = require('./feature_analytics');
const { ACTIVE_STATUSES } = require('./oracle/repo');
const { haversine, encodePolyline, decodePolyline, pointToSegment } = require('./geo_math');
const { scrub, scrubConvoyMeta, mentions } = require('./anonymise');
const { validPhone, roleOf } = require('./validate');
const { realContactNumber } = require('./auth');
const { applyPublicRidePatch, publicRideView } = require('./public_ride_settings');

const STOP_CATEGORIES = new Set(['FUEL', 'FOOD', 'REST', 'MEETING', 'SCENIC', 'TOLL', 'OTHER', 'HOSPITAL', 'REPAIR', 'STAY', 'PHARMACY', 'TYRE', 'WASHROOM', 'ATM', 'POLICE', 'PARKING']);
/** The chat card posted when a rider asks the group to wait (plain text, no emoji). */
const WAIT_MESSAGE = 'Asked the group for a 2 minute stop. Please regroup safely.';
// 3.55 bike / pillion swap: a pending ask lasts 2 minutes; a rider may ask a few times per 10 minutes.
const SWAP_KINDS = new Set(['BIKES', 'PILLION']);
const SWAP_ID = /^SWP-[0-9A-F]{12}$/;
const SWAP_TTL_MS = 2 * 60000;
const SWAP_RATE_MAX = 4;
const SWAP_RATE_WINDOW_MS = 10 * 60000;
/** 3.55 live bike change (RIDER_VEHICLE): at most one applied update per rider per window. */
const VEHICLE_RATE_MS = 10000;
const VEHICLE_MODEL_MAX = 40;
const VEHICLE_COLOUR_HEX = /^#[0-9A-Fa-f]{6}$/;
/** A colour name as the garage keeps it ("Kaza Brown", "Gunmetal Grey"): letters first, at most 20 characters. */
const VEHICLE_COLOUR_NAME = /^\p{L}[\p{L}\p{M}\p{N} .'\-/]{0,19}$/u;
/** 3.55 bike type (garage bike shape, map marker): one of these ids, '' when unknown (older apps). */
const VEHICLE_KINDS = new Set(['commuter', 'scooter', 'sport', 'cruiser', 'adventure', 'offroad', 'electric', 'retro']);
/** 3.55 pillion seat: the rider may decline a new pillion within this window (and remove one any time). */
const PILLION_DECLINE_MS = 60000;
const PILLION_RATE_MAX = 6;
const PILLION_RATE_WINDOW_MS = 10 * 60000;
const MAX_STOPS = 20;
const RESPONSE_KINDS = new Set(['GOING', 'WITH_THEM', 'CANCEL']);
const PRESENCE = new Set(['ONLINE', 'NO_SIGNAL', 'APP_CLOSED']);
const LIVE_STATUSES = ['STARTED', 'PAUSED'];
/** Alert storm guard: once a rider has SOS_STORM_MAX open alerts of one kind raised within SOS_DEDUPE_MS,
 * further presses (any clientId, any socket) are answered as duplicates of the latest one. */
const SOS_DEDUPE_MS = (() => { const n = parseInt(process.env.SOS_DEDUPE_MS || '', 10); return Number.isFinite(n) && n >= 0 ? n : 60000; })();
const SOS_STORM_MAX = 2;
/** Telemetry alone touches the convoy document at most this often (ride liveness for the stale-convoy job). */
const META_TOUCH_MS = 10 * 60000;

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
const ASSIST_RIDER_KEYS = ['assistHelp', 'assistAsk'];

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

class ConvoyError extends Error {
  /** reason: machine-readable cause. The app leaves a convoy only for NOT_MEMBER / CONVOY_GONE, never for other errors. */
  constructor(message, status = 400, reason = undefined) { super(message); this.status = status; this.name = 'ConvoyError'; this.reason = reason; }
}

/**
 * The only rider fields a client message may change. Role, profile (phone, vehicle,
 * emergency contact) and co-riding are never taken from a socket message: role and
 * co-riding are set by server code paths only, the profile comes from the users table.
 */
const TELEMETRY_FIELDS = ['lat', 'lng', 'speedKmh', 'heading', 'batteryLevel', 'isCharging', 'statusReason', 'statusMessage', 'stoppedSince', 'fuelEstimate', 'micMuted', 'isSpeaking', 'fatigueLevel'];

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
    /** Two-node live mirror (src/mirror.js), set by app.js. Null: single node, behaviour as before. */
    this.mirror = opts.mirror || null;
  }

  // ------------------------------------------------------------ two-node mirror
  /** True when the peer gateway runs this room's background automation (timeline ticks, expiry, discovery). */
  passive(groupId) { return !!this.mirror && !this.mirror.authoritative(groupId); }

  /**
   * LIVE_RIDER_CAP: a rider who is not live anywhere yet is refused while the cap is reached
   * (503 SERVER_BUSY). Riders already riding, rejoining or reconnecting are never refused (callers decide).
   */
  _admitNewRider(userId) {
    if (this.mirror && this.mirror.capReached(userId)) throw new ConvoyError('Server busy, try in a few minutes', 503, 'SERVER_BUSY');
  }

  /** Index (or drop) the live link of one alert after it was changed by the peer gateway. */
  _indexLiveLink(groupId, a) {
    if (!a || !a.liveLink || !a.liveLink.hash) return;
    if (!a.resolved && !a.liveLink.revokedAt) this.liveLinks.set(a.liveLink.hash, { gid: groupId, alertId: a.alertId });
    else this.liveLinks.delete(a.liveLink.hash);
  }

  /**
   * Durable room events (alerts, resolves, SOS responses, chat). The caller stored it first; then the room
   * hears it, the peer gateway acknowledges it (bounded wait, never when it is down) and only then the
   * sender gets its echo. A failed store (persisted = false) still reaches the room and the peer (safety
   * first) but the sender gets no echo, so the phone keeps resending by clientId.
   * The synchronous part (room + peer) runs before the first await: callers may fire side effects right after.
   */
  async _durable(groupId, type, payload, { sender = null, persisted = true } = {}) {
    if (['ALERT', 'ALERT_RESOLVED', 'SOS_RESPONSE'].includes(type)) this.featureAnalytics.record('safety', true);
    const full = { type, ts: now(), ...payload };
    const split = !!sender && (!persisted || !!(this.mirror && this.mirror.linked()));
    this.emit('event', groupId, full, split ? { exceptUser: sender } : undefined);
    const ack = this.mirror ? this.mirror.local(groupId, full, { durable: true }) : null;
    if (ack) await ack;
    if (split && persisted) this.emit('echo', groupId, full, sender);
    if (!persisted) this.log.warn(`[convoys] ${type} in ${groupId} not stored: sent to the room, sender not acknowledged (it will retry)`);
    return persisted;
  }

  /** Marks a record (alert or message id) of a room as not yet stored / stored again. */
  _setUnsaved(room, id, unsaved) {
    if (unsaved) (room.unsaved || (room.unsaved = new Set())).add(id);
    else if (room.unsaved) room.unsaved.delete(id);
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
      metaSavedAt: now(),
    };
    // An ended ride is read-only history: answered from this copy, never kept among the live rooms
    // (a late JOIN, status call or telemetry for it must not pin it in memory or revive its timers).
    if (meta.tripStatus === 'ENDED') return room;
    this.rooms.set(groupId, room);
    this.fixDoubleLead(room, { announce: false });
    // Pending bike / pillion swap asks survive a restart or failover (meta.pendingSwaps).
    this._swapsOf(room, now());
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
      publicRide: publicRideView(m.publicRide),
      activeRegroup: room.regroup || m.activeRegroup || null,
      // Seats of this ride, host included: the host's membership seats (never the server ceiling).
      capacity: this._storedCapacity(m),
      capacityPlan: m.capacityPlan || null,
      // 3.56 access mode: the group features of this ride ('all', or the list a hybrid free tier includes).
      groupFeatures: Array.isArray(m.groupFeatures) ? [...m.groupFeatures] : 'all',
      // A solo ride (Community host): the app hides talk, messages, invite and regroup.
      soloRide: this.isSoloRide(room),
      // 3.55: automatic riding roles (front rider leads, last one sweeps), off unless the lead turned it on.
      autoRoles: m.autoRoles === true,
      // 3.55 buddy pairs (large groups): {userId: buddyId}, empty when not assigned.
      buddies: m.buddies && typeof m.buddies === 'object' ? m.buddies : {},
    };
  }

  /**
   * A SOLO ride: its host rides on Community (or the legacy Individual plan), so the ride has one
   * seat. Talk, messages, wait requests, regroup and lead/sweep roles are group features and are
   * refused in it (403 SOLO_RIDE); every safety feature works the same. With payments off every
   * ride is a group ride. A host who upgrades during the ride turns it into a group ride at once.
   */
  isSoloRide(room) {
    if (config.paymentsEnabled === false || !room || !room.meta) return false;
    return this._storedCapacity(room.meta) <= 1;
  }

  /** Throws 403 SOLO_RIDE for a group feature used in a solo ride. */
  _requireGroupRide(room) {
    if (this.isSoloRide(room)) {
      throw new ConvoyError('Talk, messages and regroup are for group rides. This is a solo ride.', 403, 'SOLO_RIDE');
    }
  }

  /** The capacity stored on the convoy; rides from before capacities were stored read as the ceiling. */
  _storedCapacity(meta) {
    const cap = Number(meta && meta.capacity);
    return Number.isFinite(cap) && cap >= 1 ? clampSeats(cap) : clampSeats(config.maxConvoyRiders);
  }

  /**
   * The seats of `room` now: the host's active plan (an upgrade during the ride raises it and is
   * stored and announced), else what was stored when the ride started (a plan ending mid-ride, the
   * host falling back to Community's one seat, never shrinks a ride already under way).
   * Payments off: the server ceiling.
   */
  async _currentCapacity(room) {
    if (config.paymentsEnabled === false) return clampSeats(config.maxConvoyRiders);
    // 3.56 operator rides (src/operator_routes.js, operators.operatorCapacity): seats and group features
    // come from the operator's limits, set when the console starts the ride; the host's plan is not used.
    if (room.meta.operatorId) return this._storedCapacity(room.meta);
    const ownerId = room.meta.tripOwnerUserId || room.meta.createdByUserId;
    const access = await this._hostAccess(ownerId);
    // 3.56 access mode: a ride limited to some group features (hybrid free tier) gets them all once
    // its host may have them all (plan bought, or the admin switched to free / paid-with-plan).
    let changed = false;
    if (Array.isArray(room.meta.groupFeatures) && access.groupFeatures === null) {
      room.meta.groupFeatures = null;
      changed = true;
    }
    if (access.seats >= 1 && access.seats > this._storedCapacity(room.meta)) {
      room.meta.capacity = access.seats;
      room.meta.capacityPlan = access.plan.category;
      changed = true;
    }
    if (changed) {
      this._touch(room);
      await this.repo.saveConvoyMeta(room.meta);
      this._emit(room.groupId, 'CONFIG', this._configPayload(room));
    }
    return this._storedCapacity(room.meta);
  }

  /**
   * 3.56: what the host of a ride may do, from the plan AND the admin access mode (access_mode.js):
   * { plan, seats, canStartTrip, groupFeatures (null = every group feature), freeTier }.
   * Without an access mode service (unit tests) it is the plan alone, as before.
   */
  async _hostAccess(userId) {
    const plan = await resolvePlan(this.repo, userId);
    if (!this.accessMode) return { plan, seats: plan.seats, canStartTrip: plan.canStartTrip, groupFeatures: null, freeTier: false };
    const caps = await this.accessMode.capabilitiesOf(userId, { plan });
    return {
      plan, seats: caps.maxRiders, canStartTrip: plan.canStartTrip,
      groupFeatures: caps.groupFeatures === 'all' ? null : [...caps.groupFeatures], freeTier: !!caps.freeTier,
    };
  }

  /** The first of `ids` (feature switch ids) the ride `groupId` leaves out (hybrid free tier), or null. */
  rideFeatureOff(groupId, ids) {
    const room = groupId ? this.rooms.get(groupId) : null;
    if (!room || !room.meta || !Array.isArray(room.meta.groupFeatures)) return null;
    return require('./access_mode').lockedFeature(room.meta.groupFeatures, ids);
  }

  /** After an access mode change: every live ride takes the seats / features its host has now (never fewer). */
  async refreshAllCapacities() {
    for (const room of [...this.rooms.values()]) {
      if (!ACTIVE_STATUSES.includes(room.meta.tripStatus)) continue;
      await this._currentCapacity(room).catch((e) => this.log.warn('[convoys] capacity refresh failed', e.message));
    }
  }

  /** Hybrid free tier: the ride counts as one hosted group ride of the month when the first other rider joins. */
  _countFreeHosting(room, ownerId) {
    if (!this.accessMode || !room.meta.freeTierHost || room.meta.hostedCounted) return;
    room.meta.hostedCounted = true;
    this._touch(room);
    this.repo.saveConvoyMeta(room.meta).catch(() => {});
    this.accessMode.countHostedRide(ownerId).catch((e) => this.log.warn('[convoys] hosted ride count failed', e.message));
  }

  /**
   * After the host's plan changed (bought, upgraded): their live rides take the new seats at once,
   * so every rider sees the right count/capacity without waiting for the next join.
   */
  async refreshHostCapacity(userId) {
    if (!userId) return;
    for (const room of [...this.rooms.values()]) {
      if (!ACTIVE_STATUSES.includes(room.meta.tripStatus)) continue;
      if ((room.meta.tripOwnerUserId || room.meta.createdByUserId) !== userId) continue;
      await this._currentCapacity(room);
    }
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
    const full = { type, ts: now(), ...payload };
    this.emit('event', groupId, full);
    // Replicated to the peer gateway (state + the same room message for its sockets).
    if (this.mirror) this.mirror.local(groupId, full);
  }

  // ------------------------------------------------------------ lifecycle
  /**
   * The rider's single-active-trip lock, or null when it is stale: its convoy ended, was
   * dissolved by an admin or no longer exists (a crash between the end and the lock release,
   * older builds). A stale lock is released, so it can never keep a rider off every ride.
   * When the convoy cannot be read (database trouble) the lock is kept: fail safe.
   */
  async _activeLock(userId) {
    const lock = await this.repo.getActiveTrip(userId);
    if (!lock || !lock.groupId) return lock;
    const live = this.rooms.get(lock.groupId);
    let meta = live ? live.meta : undefined;
    if (!live) {
      try { meta = await this.repo.getConvoyMeta(lock.groupId); } catch { return lock; }
    }
    if (meta && ACTIVE_STATUSES.includes(meta.tripStatus)) return lock;
    await this.repo.releaseActiveTrip(userId).catch(() => {});
    return null;
  }

  /**
   * `opts.operator` (server only, src/operator_routes.js): { operatorId, rideId, capacity } starts an
   * operator ride: the seats come from the operator's limits and every group feature is on; the
   * host's personal plan and access mode are not consulted (the one-active-trip rule still applies).
   */
  async createConvoy(user, p, opts = {}) {
    const name = String(p.name || '').trim();
    if (name.length < 2) throw new ConvoyError('Convoy name is required.');
    this._admitNewRider(user.userId);

    // Concurrency-safe single active trip enforcement when monetization/membership is active
    let capacity = clampSeats(config.maxConvoyRiders);
    let capacityPlan = null;
    let groupFeatures = null;
    let freeTierHost = false;
    if (config.paymentsEnabled !== false) {
      const active = await this._activeLock(user.userId);
      if (active && ['PLANNING', 'STARTED', 'PAUSED'].includes(active.status)) {
        throw new ConvoyError('You already have an active trip. End or leave it first.', 409, 'ACTIVE_TRIP_CONFLICT');
      }
      // The host's plan (membership, or a legacy tier until it ends) and the admin access mode
      // (3.56, access_mode.js) decide the seats of the ride and, on a hybrid free tier, its group features.
      const access = opts.operator
        ? { canStartTrip: true, seats: Number(opts.operator.capacity) || 2, plan: { category: 'operator' }, groupFeatures: null, freeTier: false }
        : await this._hostAccess(user.userId);
      if (!access.canStartTrip) {
        throw new ConvoyError('Active membership required to create a trip.', 402, 'MEMBERSHIP_EXPIRED');
      }
      capacity = clampSeats(access.seats);
      capacityPlan = access.plan.category;
      groupFeatures = access.groupFeatures;
      freeTierHost = access.freeTier;
    }

    // Leave any other non-active residues
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
      tripOwnerUserId: user.userId,
      tripHeadUserId: user.userId,
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
      capacity,
      capacityPlan,
      // 3.56 access mode: null = every group feature; a list on a hybrid free-tier ride.
      groupFeatures,
      freeTierHost,
      ...(opts.operator ? { operatorId: String(opts.operator.operatorId), operatorRideId: String(opts.operator.rideId) } : {}),
      members: { [user.userId]: memberRecord(user, { ...riderInput, role: 'LEAD' }, t) },
    });
    const rider = buildRider(user, { ...riderInput, role: 'LEAD' }, t);
    await this.repo.upsertRider(groupId, rider);

    const room = {
      groupId, meta, riders: new Map([[rider.userId, rider]]), messages: [], alerts: new Map(),
      dirty: new Set(), lastPersist: new Map(), persistTimer: null, regroup: null, metaSavedAt: t,
    };
    this.rooms.set(groupId, room);
    if (this.mirror) this.mirror.roomCreated(room);
    await this.repo.setActiveTrip(user.userId, { groupId, role: 'OWNER', status: 'STARTED' });
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
    // Live-rider cap: a rider already in this ride (re-join, re-sync) is never refused.
    if (!room.riders.has(user.userId)) this._admitNewRider(user.userId);
    // Concurrency-safe single active trip check: cannot participate in multiple active trips simultaneously
    if (!room.riders.has(user.userId)) {
      if (config.paymentsEnabled !== false) {
        const existingTrip = await this._activeLock(user.userId);
        if (existingTrip && existingTrip.groupId !== meta.groupId && ['PLANNING', 'STARTED', 'PAUSED'].includes(existingTrip.status)) {
          throw new ConvoyError('You are already participating in another active trip. Leave or end it first.', 409, 'ACTIVE_TRIP_CONFLICT');
        }
      }
    }

    // Capacity: the host's membership seats (host included), never the global ceiling.
    const ownerId = meta.tripOwnerUserId || meta.createdByUserId;
    const allowedCapacity = await this._currentCapacity(room);
    if (allowedCapacity <= 1 && !room.riders.has(user.userId) && user.userId !== ownerId) {
      throw new ConvoyError("This is a solo ride. Others can't join it.", 409, 'SOLO_TRIP_ONLY');
    }
    // Removed from the owner's membership group: no new join (a rider already riding is never dropped).
    if (!room.riders.has(user.userId) && room.meta.joinBlocked && room.meta.joinBlocked[user.userId]) {
      throw new ConvoyError('The Trip owner removed you from this group.', 403, 'JOIN_BLOCKED');
    }
    // A seat is held from this check until the rider is in, so concurrent joins never overfill the ride.
    const joining = room.joining || (room.joining = new Set());
    const isNew = !room.riders.has(user.userId) && !joining.has(user.userId);
    if (isNew && room.riders.size + joining.size >= allowedCapacity) {
      throw new ConvoyError(`This convoy is full (${allowedCapacity} riders).`, 409, 'CONVOY_FULL');
    }
    if (isNew) joining.add(user.userId);
    if (isNew && user.userId !== ownerId) this._countFreeHosting(room, ownerId);
    try {
      if (!room.riders.has(user.userId)) await this.leaveAll(user.userId, { except: meta.groupId });

      const existing = room.riders.get(user.userId);
      const profile = profileOf(await this.repo.findUserById(user.userId));
      const rider = buildRider(user, { ...(existing || {}), ...clientRiderInput(riderProfile), ...profile, role: existing?.role || 'PACK' }, now());
      // 3.55: a bike swapped in this ride stays swapped when the rider re-joins (the profile is unchanged).
      if (existing?.rideVehicle) Object.assign(rider, existing.rideVehicle, { rideVehicle: existing.rideVehicle });
      if (existing?.roleAt) rider.roleAt = existing.roleAt;
      room.riders.set(rider.userId, rider);
      const prev = room.meta.members?.[rider.userId];
      const record = memberRecord(user, rider, existing ? (prev?.joinedAt || rider.joinedAt) : now());
      record.firstJoinedAt = prev?.firstJoinedAt || prev?.joinedAt || record.joinedAt;
      room.meta.members = { ...(room.meta.members || {}), [rider.userId]: record };
      await this.repo.upsertRider(room.groupId, rider);
      this._touch(room);
      await this.repo.saveConvoyMeta(room.meta);
      await this.repo.setActiveTrip(user.userId, {
        groupId: room.groupId,
        role: user.userId === (room.meta.tripOwnerUserId || room.meta.createdByUserId) ? 'OWNER' : (user.userId === room.meta.tripHeadUserId ? 'HEAD' : 'PARTICIPANT'),
        status: room.meta.tripStatus || 'STARTED',
      });
      this._emit(room.groupId, 'RIDER_UPDATE', { rider: publicRider(rider), joined: !existing });
      this.emit('fleet');
      return this.snapshot(room);
    } finally {
      if (isNew) joining.delete(user.userId);
    }
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
    // The single-active-trip lock is released only when it is for THIS convoy: leaving some other
    // (stale, ended or foreign) convoy must never unlock the ride the rider is on now.
    const releaseIfHere = async () => {
      const lock = await this.repo.getActiveTrip(userId).catch(() => null);
      if (lock && lock.groupId === groupId) await this.repo.releaseActiveTrip(userId);
    };
    const room = await this.getRoom(groupId, { required: false });
    // An ended convoy keeps its record as it was at the end (a late "leave" must not move leftAt);
    // a convoy the rider is not in is left untouched.
    if (!room || !ACTIVE_STATUSES.includes(room.meta.tripStatus) || !room.riders.has(userId)) {
      await this.repo.removeRider(groupId, userId);
      await releaseIfHere();
      return;
    }
    const rider = room.riders.get(userId);
    room.riders.delete(userId);
    room.dirty.delete(userId);
    if (room.meta.members?.[userId]) room.meta.members[userId].leftAt = now();
    await this.repo.removeRider(groupId, userId);
    await releaseIfHere();
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    if (rider) this._emit(groupId, 'RIDER_LEFT', { userId, name: rider.name });
    // 3.55 pillion seat: a rider who leaves takes no pillion along (the pillion is shown alone again
    // and picks another bike); a pillion who leaves frees the seat. Never throws into leave().
    if (rider) await this._pillionLeft(room, rider).catch((e) => this.log.warn('[convoys] pillion unlink failed', e.message));
    // 3.55 safety review: since 3.55 any rider can hold LEAD. When that rider leaves, the ride must
    // not be left without a lead (incident/BEHIND notify lists, sweeper distress and the riders'
    // "who leads" all read role LEAD): the owner, if still riding, takes the front again. Same rule
    // as "PACK for the lead" in setRole(). Never throws into leave().
    if (rider && room.riders.size > 0 && this._roleOfRider(room, rider) === 'LEAD') {
      const ownerId = room.meta.createdByUserId;
      const anyLead = [...room.riders.values()].some((r) => this._roleOfRider(room, r) === 'LEAD');
      if (!anyLead && ownerId && room.riders.has(ownerId)) {
        await this._commitRoles(room, new Map([[ownerId, 'LEAD']]), { userId: 'SYSTEM', name: '' }, { target: ownerId })
          .catch((e) => this.log.warn('[convoys] lead hand-back failed', e.message));
      }
    }
    this.emit('fleet');
    if (room.riders.size === 0 && ACTIVE_STATUSES.includes(room.meta.tripStatus)) {
      await this.setTripStatus(groupId, 'ENDED', { system: true });
    }
  }

  async setTripStatus(groupId, status, { system = false } = {}) {
    if (!['PLANNING', 'STARTED', 'PAUSED', 'ENDED'].includes(status)) throw new ConvoyError('Invalid trip status.');
    const room = await this.getRoom(groupId);
    if (room.meta.tripStatus === 'ENDED') {
      // An ended ride is final: a retried "end" (timeout, double tap) must not move its end time,
      // and a late pause/resume must never bring it back (its report, trips and reviews stand).
      if (this.rooms.get(groupId) === room) this.rooms.delete(groupId); // loaded only to answer this
      if (status === 'ENDED') return 'ENDED';
      throw new ConvoyError('This ride has ended.', 409, 'RIDE_ENDED');
    }
    room.meta.tripStatus = status;
    if (status === 'ENDED') {
      room.meta.endedAtEpochMs = now();
      // Durable, location-free record of who rode together (kept forever).
      room.meta.memberSummary = Object.values(room.meta.members || {});
      room.meta.riderCount = room.meta.memberSummary.length;
      // Pending swap asks end with the ride.
      for (const x of (room.swaps || new Map()).values()) clearTimeout(x.timer);
      if (room.swaps) room.swaps.clear();
      delete room.meta.pendingSwaps;
    }
    this._touch(room);
    await this.flushRoom(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'TRIP_STATUS', { tripStatus: status, system });
    if (status === 'ENDED') {
      this._emit(groupId, 'DISSOLVED', { reason: 'TRIP_ENDED' });
    }
    this.emit('fleet');
    if (status === 'ENDED') {
      await this.repo.releaseAllActiveTripsForGroup(groupId);
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
    if (room.meta.tripStatus === 'ENDED') return null;
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
      // Two nodes: the room is written by a node that holds sockets of it (both may during a hand-back).
      if (this.mirror && !this.mirror.shouldPersist(room.groupId)) { room.dirty.clear(); return; }
      this.flushRoom(room).catch((e) => this.log.warn('[convoys] persist failed', e.message));
    }, this.persistIntervalMs);
    if (room.persistTimer.unref) room.persistTimer.unref();
  }

  /**
   * Writes the live state of a room: ONE room snapshot document with every rider (repo.saveRoomSnapshot)
   * instead of one write per rider; repo.listRiders lays it over the convoy_riders documents, which are
   * still written at once on join, leave and role changes. The convoy document is touched at most every
   * META_TOUCH_MS for telemetry alone (it only keeps the ride from looking stale).
   * `perRider`: also rewrite the changed riders' own documents (account deletion scrubs them).
   * A failed write keeps the riders dirty for the next round.
   */
  async flushRoom(room, { perRider = false } = {}) {
    const ids = [...room.dirty];
    room.dirty.clear();
    if (!ids.length) return;
    try {
      if (perRider || typeof this.repo.saveRoomSnapshot !== 'function') {
        await Promise.all(ids.map(async (userId) => {
          const rider = room.riders.get(userId);
          if (rider) await this.repo.upsertRider(room.groupId, rider);
        }));
      }
      if (typeof this.repo.saveRoomSnapshot === 'function') {
        await this.repo.saveRoomSnapshot(room.groupId, { riders: [...room.riders.values()], positionsAt: now() });
      }
    } catch (e) {
      for (const id of ids) if (room.riders.has(id)) room.dirty.add(id);
      if (this.rooms.get(room.groupId) === room) this._schedulePersist(room);
      throw e;
    }
    if (now() - (room.metaSavedAt || 0) >= META_TOUCH_MS) {
      room.metaSavedAt = now();
      this._touch(room);
      await this.repo.saveConvoyMeta(room.meta);
    }
  }

  async flushAll() {
    for (const room of this.rooms.values()) {
      clearTimeout(room.persistTimer); room.persistTimer = null;
      if (this.mirror && !this.mirror.shouldPersist(room.groupId)) continue;
      await this.flushRoom(room).catch(() => {});
    }
  }

  // ------------------------------------------------------ chat / alerts
  async sendMessage(groupId, user, { text, isQuickCard = false, cardType = 'CUSTOM', clientId = '', sentAt } = {}) {
    const room = await this.getRoom(groupId);
    const isMember = room.riders.has(user.userId);
    const isCreator = room.meta.createdByUserId === user.userId;
    const isAdmin = user.role === 'ADMIN' || user.role === 'MASTER_ADMIN';
    if (!isMember && !isCreator && !isAdmin) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    this._requireGroupRide(room);
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
      // Sent before but not stored (database trouble): store that one now, never a second copy.
      const prev = room.unsaved && room.unsaved.size ? room.messages.find((m) => m.senderId === user.userId && m.clientId === clientId) : null;
      if (prev && room.unsaved.has(prev.messageId)) return this._retryUnsavedMessage(room, prev);
    }
    return this._postMessage(room, msg, { sender: user.userId });
  }

  /**
   * Stores a chat message, then tells the room and the peer gateway (durable: see _durable). `sender`: the
   * rider whose echo waits for the store and the peer. A failed store still reaches the room; the sender
   * gets no echo and no ACK (silent error), and the resend with the same clientId stores it again.
   */
  async _postMessage(room, msg, { sender = null } = {}) {
    room.messages.push(msg);
    if (room.messages.length > 500) room.messages.splice(0, room.messages.length - 500);
    let persisted = true;
    try { await this.repo.addMessage(room.groupId, msg); } catch (e) {
      persisted = false;
      this._setUnsaved(room, msg.messageId, true);
      this.log.warn('[convoys] message store failed', e.message);
    }
    await this._durable(room.groupId, 'MESSAGE', { message: msg }, { sender, persisted });
    if (!persisted) throw notStored();
    return msg;
  }

  /** A resent chat message (same rider, same clientId) whose first store failed: stored now, then echoed. */
  async _retryUnsavedMessage(room, msg) {
    try { await this.repo.addMessage(room.groupId, msg); } catch (e) {
      this.log.warn('[convoys] message store failed again', e.message);
      throw notStored();
    }
    this._setUnsaved(room, msg.messageId, false);
    if (this.mirror) this.mirror.replicate(room.groupId, { saved: [msg.messageId] });
    this.emit('echo', room.groupId, { type: 'MESSAGE', ts: now(), message: msg }, msg.senderId);
    return msg;
  }

  async requestWait(groupId, user) {
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    this._requireGroupRide(room);
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
    if (!cid) return this._raiseSosSerial(groupId, user, msg);
    const inflight = this.sosInFlight || (this.sosInFlight = new Map());
    const k = `${groupId}|${user.userId}|${cid}`;
    const first = inflight.get(k);
    if (first) {
      const r = await first;
      return { alert: r.alert, duplicate: true, persisted: r.persisted !== false };
    }
    const p = this._raiseSosSerial(groupId, user, msg);
    inflight.set(k, p);
    try { return await p; } finally { inflight.delete(k); }
  }

  /**
   * One SOS at a time per rider and room: a burst of presses (new clientIds, two phones, crash detection
   * plus a manual press) arriving together waits for the first to be stored, so the alert storm guard in
   * _raiseSos sees it and answers the rest as duplicates (one ALERT, one SMS round).
   */
  _raiseSosSerial(groupId, user, msg) {
    const chains = this.sosChain || (this.sosChain = new Map());
    const k = `${groupId}|${user.userId}`;
    const prev = chains.get(k) || Promise.resolve();
    const p = prev.catch(() => {}).then(() => this._raiseSos(groupId, user, msg));
    chains.set(k, p);
    p.catch(() => {}).finally(() => { if (chains.get(k) === p) chains.delete(k); });
    return p;
  }

  async _raiseSos(groupId, user, msg = {}) {
    // msg.type is the socket message type ('SOS'), not the kind of SOS (alertType).
    const { lat, lng, type, alertType, clientId } = msg || {};
    const room = await this.getRoom(groupId);
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const cid = clientId === undefined || clientId === null ? '' : String(clientId).slice(0, 64);
    if (cid) {
      for (const a of room.alerts.values()) {
        if (a.userId === user.userId && a.clientId === cid) {
          // Its first store failed: stored now (the sender is answered only once it is).
          const persisted = room.unsaved && room.unsaved.has(a.alertId) ? await this._retryUnsavedAlert(room, a) : true;
          return { alert: a, duplicate: true, persisted };
        }
      }
      // Already resolved and no longer in memory: still the same SOS, never a new one. Stored but open and
      // not in this room's memory (the gateway that took it went down before the peer heard of it): adopted.
      const stored = await this.repo.findAlertByClientId(groupId, user.userId, cid);
      if (stored) return { alert: this._adoptStoredAlert(room, stripKey(stored), user.userId), duplicate: true, persisted: true };
    }
    const t = now();
    const kind = sosType(alertType || (type === 'SOS' ? '' : type));
    // Alert storm guard: a burst of presses from several phones/sockets with new clientIds never floods
    // the group (a second distinct SOS still goes out; the server SMS gateway texts once per minute).
    let recent = 0, latest = null;
    for (const a of room.alerts.values()) {
      if (a.userId === user.userId && !a.resolved && a.alertType === kind && t - (Number(a.timestamp) || 0) < SOS_DEDUPE_MS) {
        recent++;
        if (!latest || (a.timestamp || 0) >= (latest.timestamp || 0)) latest = a;
      }
    }
    if (latest && recent >= SOS_STORM_MAX) return { alert: latest, duplicate: true };
    const details = {};
    const speed = boundedNumber(msg.speedBeforeKmh, 0, 300);
    if (speed !== null) details.speedBeforeKmh = speed;
    const impact = boundedNumber(msg.impactG, 0, 50);
    if (impact !== null) details.impactG = impact;
    // 3.15: where it came from (old apps send nothing: crash alerts read as CRASH_AUTO, the rest MANUAL).
    const src = typeof msg.source === 'string' && EMERGENCY_SOURCES.has(msg.source) && !['MEMBER_REPORT', 'NEARBY_REPORT'].includes(msg.source)
      ? msg.source : (msg.auto === true ? 'CRASH_AUTO' : 'MANUAL');
    const auto = msg.auto === true || src === 'CRASH_AUTO';
    const alert = {
      alertId: `SOS-${crypto.randomUUID()}`, userId: user.userId, userName: user.name,
      lat: clampLat(lat), lng: clampLng(lng), alertType: kind, timestamp: t, resolved: false,
      ...(cid ? { clientId: cid } : {}),
      // The phone already texted its contacts: the server SMS gateway does not text them again.
      ...(msg.clientSentSms === true || msg.clientDispatched === true ? { clientSentSms: true } : {}),
      auto,
      details,
      occurredAt: clampTime(msg.occurredAt, t - 6 * 3600000, t + 60000, t),
      responders: {},
      ...this._emergencyFields(room, { lat: clampLat(lat), lng: clampLng(lng), msg, source: src, alertType: kind, t }),
    };
    const ownerDoc = await withTimeout(this.repo.findUserById(user.userId), 1500).catch(() => null);
    await this._storeAlert(room, alert, ownerDoc, { sender: user.userId });
    return { alert, duplicate: false, persisted: !(room.unsaved && room.unsaved.has(alert.alertId)) };
  }

  /** Stores again an alert whose first store failed (a resend with its clientId). True once it is stored. */
  async _retryUnsavedAlert(room, a) {
    try {
      const there = a.clientId ? await this.repo.findAlertByClientId(room.groupId, a.userId, a.clientId) : null;
      if (!there) await this.repo.addAlert(room.groupId, a);
    } catch (e) {
      this.log.warn('[convoys] alert store failed again', e.message);
      return false;
    }
    this._setUnsaved(room, a.alertId, false);
    if (this.mirror) this.mirror.replicate(room.groupId, { saved: [a.alertId] });
    return true;
  }

  /** An open alert found in the database but not in this room's memory joins the room (everyone hears it). */
  _adoptStoredAlert(room, a, senderId) {
    if (a.resolved || room.alerts.has(a.alertId) || this.rooms.get(room.groupId) !== room) return room.alerts.get(a.alertId) || a;
    room.alerts.set(a.alertId, a);
    this._indexLiveLink(room.groupId, a);
    const full = { type: 'ALERT', ts: now(), alert: publicAlert(a, { summary: this._summary(room.groupId, a.alertId) }) };
    this.emit('event', room.groupId, full, { exceptUser: senderId });
    if (this.mirror) this.mirror.local(room.groupId, full);
    this.emit('fleet');
    this.emit('roomLoaded', room.groupId); // the safety network gives it its incident back
    return a;
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
  async _storeAlert(room, alert, ownerDoc, { sender = null } = {}) {
    const medical = medicalOf(ownerDoc);
    if (medical) alert.medical = medical;
    room.alerts.set(alert.alertId, alert);
    // Stored first. A failed store is logged and the alert still goes out (safety first); the sender gets
    // no echo, so the phone resends with the same clientId and the store is tried again.
    let persisted = true;
    try { await this.repo.addAlert(room.groupId, alert); } catch (e) {
      persisted = false;
      this._setUnsaved(room, alert.alertId, true);
      this.log.warn('[convoys] alert store failed', e.message);
    }
    const delivered = this._durable(room.groupId, 'ALERT', { alert: publicAlert(alert, { summary: this._summary(room.groupId, alert.alertId) }) }, { sender, persisted });
    this.emit('fleet');
    try {
      this.emit('emergency', room.groupId, alert, 'RAISED', { owner: ownerInfo(ownerDoc) });
    } catch (e) { this.log.warn('[convoys] emergency hook failed', e.message); }
    this._lookupHospital(room, alert);
    await delivered;
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
      if (a) {
        delete a.medical;
        // A repeated resolve (the phone saw no echo): stored again, then echoed.
        let persisted = true;
        try { await this.repo.resolveAlert(groupId, alertId, user.userId); } catch (e) { persisted = false; this.log.warn('[convoys] resolve failed', e.message); }
        if (persisted) this._setUnsaved(room, `res:${alertId}`, false);
        await this._durable(groupId, 'ALERT_RESOLVED', { alertId, by: user.userId, status: statusOf(a) }, { sender: user.userId, persisted });
        this.emit('fleet');
        return true;
      }
      // If alert is not in memory, ensure it actually exists in persistent storage before emitting resolution
      const exists = await this.repo.resolveAlert(groupId, alertId, user.userId);
      if (exists) {
        this._emit(groupId, 'ALERT_RESOLVED', { alertId, by: user.userId, status: 'RESOLVED' });
        this.emit('fleet');
        return true;
      }
      return false;
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
      let persisted = true;
      await this.repo.resolveAlert(groupId, alertId, by, { status: next, resolveReason: a.resolveReason, lastUpdateAt: t, ...(a.netResponders ? { netResponders: a.netResponders } : {}), ...linkPatch })
        .catch((e) => { persisted = false; this.log.warn('[convoys] resolve failed', e.message); });
      if (!persisted) this._setUnsaved(room, `res:${alertId}`, true);
      this.emit('activity', groupId, { type: 'EMERGENCY_STATUS', alert: a });
      // Stored first, then the room and the peer gateway, then the echo to the rider who resolved it.
      const delivered = this._durable(groupId, 'ALERT_RESOLVED', { alertId, by, status: next }, { sender: by && by !== 'SYSTEM' ? by : null, persisted });
      this.emit('fleet');
      this._hook('RESOLVED', groupId, a);
      await delivered;
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
    const payload = {
      type: 'EMERGENCY_UPDATE', alertId, status: statusOf(a), lastUpdateAt: a.lastUpdateAt || a.timestamp || 0,
      lat: pos.lat, lng: pos.lng,
      network: sum.network || { state: 'OFF', stage: 0, notified: 0, onScene: false, responders: [] },
      ownNearest: sum.ownNearest || null,
      // 3.16: known once the lookup answered (never delays anything).
      ...(a.nearestHospital ? { nearestHospital: a.nearestHospital } : {}),
      ts: now(),
    };
    this.emit('capEvent', groupId, 'net1', payload);
    if (this.mirror) this.mirror.local(groupId, payload, { cap: 'net1' });
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
    if (a.userId !== user.userId && !this.isLead(room, user)) throw new ConvoyError('Only the rider, the Trip owner or Lead can share a live link.', 403, 'NOT_ALLOWED');
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
    if (a.userId !== user.userId && !this.isLead(room, user)) throw new ConvoyError('Only the rider, the Trip owner or Lead can stop a live link.', 403, 'NOT_ALLOWED');
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
  /**
   * liveView, after making sure the live rooms are loaded: after a gateway restart only rooms a
   * rider re-joined are in memory, so a guardian's link to an injured (offline) rider read as
   * "expired". On the first miss the active rooms are loaded once (a live room stays in memory
   * until it ends; a failed load is tried again after 10 s) and it is asked again.
   */
  async liveViewLoaded(hash) {
    const v = this.liveView(hash);
    if (v || typeof hash !== 'string' || this._liveWarmed) return v;
    const t = now();
    if (this._liveWarmAt && t - this._liveWarmAt < 10000) return null;
    this._liveWarmAt = t;
    let metas;
    try { metas = await this.repo.listActiveConvoyMeta(); } catch { return null; }
    for (const m of metas) {
      if (!this.rooms.has(m.groupId)) await this.getRoom(m.groupId, { required: false }).catch(() => null);
    }
    this._liveWarmed = true;
    return this.liveView(hash);
  }

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

  // ------------------------------------------------------ riding roles (3.16 sweeper, 3.55 lead/middle/sweeper)
  /**
   * Riding roles: LEAD (front), PACK (middle) and SWEEPER (back). One LEAD and at most one SWEEPER.
   * The owner of the ride keeps the owner's rights whatever their riding role (isLead() checks the
   * owner first), so a role change never takes the ride away from its owner.
   *
   *  - LEAD for a rider: the current lead takes the rider's old role (a swap: lead <-> sweeper or
   *    lead <-> middle).
   *  - SWEEPER for a rider: the previous sweeper becomes PACK. For the current lead, the previous
   *    sweeper (or else the owner) takes the lead.
   *  - PACK for the lead: the owner takes the lead back (refused with NEED_LEAD when the lead is
   *    the owner: pick the new lead first).
   * Every changed rider goes out as RIDER_UPDATE (old apps apply `role`), the timeline gets
   * ROLE_CHANGED, and 3.55 apps get ROLE_CHANGE with the changes so the riders concerned are told
   * to change position (front / middle / back). `auto`: from automatic roles (the ride's order).
   */
  async setRole(groupId, user, userId, role, { auto = false } = {}) {
    const room = await this.getRoom(groupId);
    if (!auto) this._requireLead(room, user);
    this._requireGroupRide(room);
    const r = roleOf(role);
    if (!r) throw new ConvoyError('Role must be LEAD, SWEEPER or PACK.', 400, 'BAD_ROLE');
    const uid = typeof userId === 'string' && userId.length <= 64 ? userId : '';
    const target = uid ? room.riders.get(uid) : null;
    if (!target) throw new ConvoyError('That rider is not in this convoy.', 404, 'NOT_MEMBER');
    const plan = this._rolePlan(room, uid, r);
    return this._commitRoles(room, plan, user, { auto, target: uid });
  }

  /** Swaps the riding roles of two riders (e.g. the lead and the sweeper change places). */
  async swapRoles(groupId, user, userId, withUserId) {
    const room = await this.getRoom(groupId);
    this._requireLead(room, user);
    this._requireGroupRide(room);
    const a = room.riders.get(String(userId || ''));
    const b = room.riders.get(String(withUserId || ''));
    if (!a || !b) throw new ConvoyError('Both riders must be in this convoy.', 404, 'NOT_MEMBER');
    if (a.userId === b.userId) throw new ConvoyError('Pick two different riders.', 400, 'BAD_ROLE');
    const ra = this._roleOfRider(room, a), rb = this._roleOfRider(room, b);
    const plan = new Map([[a.userId, rb], [b.userId, ra]]);
    return this._commitRoles(room, plan, user, { auto: false, target: a.userId });
  }

  /** The lead switches automatic roles on or off (3.55; off by default). */
  async setAutoRoles(groupId, user, on) {
    const room = await this.getRoom(groupId);
    this._requireLead(room, user);
    this._requireGroupRide(room);
    const next = on === true;
    if (!!room.meta.autoRoles === next) return { autoRoles: next };
    room.meta.autoRoles = next;
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'AUTO_ROLES', { autoRoles: next, byUserId: user.userId, byName: user.name || '' });
    this.emit('activity', groupId, { type: 'AUTO_ROLES', user: { userId: user.userId, name: user.name || '' }, on: next });
    return { autoRoles: next };
  }

  /**
   * Automatic roles (called by the timeline engine with the fresh riders ordered front to back along
   * the route): the front rider leads and the last one sweeps. No-op unless the lead switched it on.
   * The engine applies its own hold time and minimum gap so roles never flicker in a tight pack.
   */
  async applyAutoRoles(groupId, orderedIds) {
    const room = this.rooms.get(groupId);
    if (!room || !room.meta.autoRoles || this.isSoloRide(room) || !Array.isArray(orderedIds) || orderedIds.length < 2) return null;
    // Single writer: only the node that owns the room (src/mirror.js authoritative) computes automatic
    // roles. During a two-node split both nodes saw the riders and each picked a lead, which could
    // briefly show two LEADs. The other node only applies what the owner replicates.
    if (this.passive(groupId)) return null;
    this.fixDoubleLead(room);
    const ids = orderedIds.filter((id) => room.riders.has(id));
    if (ids.length < 2) return null;
    const front = ids[0], back = ids[ids.length - 1];
    const plan = new Map();
    for (const r of room.riders.values()) {
      const want = r.userId === front ? 'LEAD' : (r.userId === back ? 'SWEEPER' : (ids.includes(r.userId) ? 'PACK' : null));
      if (want && this._roleOfRider(room, r) !== want) plan.set(r.userId, want);
    }
    // A rider not in the order (offline) who holds LEAD or SWEEPER gives it up to the riders who are.
    for (const r of room.riders.values()) {
      if (ids.includes(r.userId)) continue;
      const cur = this._roleOfRider(room, r);
      if ((cur === 'LEAD' && plan.has(front)) || (cur === 'SWEEPER' && plan.has(back))) plan.set(r.userId, 'PACK');
    }
    if (!plan.size) return null;
    // Replicated with the meta: a node taking the room over keeps the AUTO_ROLE_EVERY_MS spacing.
    room.meta.autoRolesAt = now();
    return this._commitRoles(room, plan, { userId: 'AUTO', name: 'Auto roles' }, { auto: true, target: front });
  }

  /**
   * Invariant: a ride has one LEAD. If a merged or loaded state ever holds two (a two-node split, an
   * old peer), the rider who became lead first (earlier `roleAt`, then the smaller userId) keeps it
   * and the others ride in the middle (PACK). Both nodes decide the same from the same state; the
   * owning node (`announce`, default: when not passive) tells the room with RIDER_UPDATE.
   * Returns the demoted rider ids.
   */
  fixDoubleLead(room, { announce = !this.passive(room.groupId) } = {}) {
    if (!room || !room.riders) return [];
    const leads = [...room.riders.values()].filter((r) => this._roleOfRider(room, r) === 'LEAD');
    if (leads.length < 2) return [];
    leads.sort((a, b) => (Number(a.roleAt) || 0) - (Number(b.roleAt) || 0) || String(a.userId).localeCompare(String(b.userId)));
    const demoted = [];
    for (const r of leads.slice(1)) {
      // Keeps the rider's roleAt: the fix is not a new role change (both nodes stay identical).
      const next = { ...r, role: 'PACK' };
      room.riders.set(r.userId, next);
      if (room.meta.members?.[r.userId]) room.meta.members[r.userId] = { ...room.meta.members[r.userId], role: 'PACK' };
      room.dirty.add(r.userId);
      demoted.push(r.userId);
    }
    this.log.warn(`[convoys] two leads in ${room.groupId}: kept ${leads[0].userId}, ${demoted.length} moved to PACK`);
    if (announce && this.rooms.get(room.groupId) === room) {
      this._schedulePersist(room);
      for (const id of demoted) {
        const r = room.riders.get(id);
        this.repo.upsertRider(room.groupId, r).catch(() => {});
        this._emit(room.groupId, 'RIDER_UPDATE', { rider: publicRider(r) });
      }
    }
    return demoted;
  }

  /** The riding role of a rider: the owner without a stored role counts as the lead (older rides). */
  _roleOfRider(room, r) {
    if (r.role === 'LEAD' || r.role === 'SWEEPER' || r.role === 'PACK') return r.role;
    return room.meta.createdByUserId === r.userId ? 'LEAD' : 'PACK';
  }

  /** userId -> new role for one change, following the rules of setRole(). */
  _rolePlan(room, uid, r) {
    const riders = [...room.riders.values()];
    const roleNow = (x) => this._roleOfRider(room, x);
    const target = room.riders.get(uid);
    const was = roleNow(target);
    const plan = new Map();
    if (was === r) return plan;
    const sweeper = riders.find((x) => x.userId !== uid && roleNow(x) === 'SWEEPER');
    const ownerId = room.meta.createdByUserId;
    if (r === 'LEAD') {
      for (const x of riders) if (x.userId !== uid && roleNow(x) === 'LEAD') plan.set(x.userId, was === 'SWEEPER' ? 'SWEEPER' : 'PACK');
    } else {
      if (r === 'SWEEPER' && sweeper) plan.set(sweeper.userId, 'PACK');
      if (was === 'LEAD') {
        // The lead moves back: someone must take the front.
        let next = null;
        if (r === 'SWEEPER' && sweeper) next = sweeper.userId;
        else if (ownerId && ownerId !== uid && room.riders.has(ownerId)) next = ownerId;
        if (!next) throw new ConvoyError('Choose who leads first: make another rider the lead.', 409, 'NEED_LEAD');
        plan.set(next, 'LEAD');
      }
    }
    plan.set(uid, r);
    return plan;
  }

  /** Applies a role plan: saves, sends RIDER_UPDATE per rider, ROLE_CHANGE once, timeline entries. */
  async _commitRoles(room, plan, user, { auto = false, target = null } = {}) {
    const groupId = room.groupId;
    const changes = [];
    for (const [uid, role] of plan) {
      const r = room.riders.get(uid);
      if (!r) continue;
      const from = this._roleOfRider(room, r);
      if (from === role && r.role === role) continue;
      const next = this._applyRole(room, uid, role);
      changes.push({ userId: uid, name: r.name || '', from, to: role, rider: next });
    }
    if (!changes.length) return target ? room.riders.get(target) : null;
    room.meta.rolesChangedAt = now();
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    for (const c of changes) {
      // Its own document now; the room snapshot (laid over it on load) is rewritten with the next flush.
      room.dirty.add(c.userId);
      this._schedulePersist(room);
      await this.repo.upsertRider(groupId, c.rider).catch((e) => this.log.warn('[convoys] role save failed', e.message));
      this._emit(groupId, 'RIDER_UPDATE', { rider: publicRider(c.rider) });
    }
    this._emit(groupId, 'ROLE_CHANGE', {
      changes: changes.map((c) => ({ userId: c.userId, name: c.name, from: c.from, to: c.to })),
      byUserId: user.userId, byName: user.name || '', auto,
    });
    for (const c of changes) {
      this.emit('activity', groupId, { type: 'ROLE_CHANGED', user: { userId: c.userId, name: c.name }, role: c.to, from: c.from, byUserId: user.userId, auto });
    }
    this.emit('fleet');
    return target ? room.riders.get(target) : null;
  }

  _applyRole(room, uid, role) {
    // roleAt: when this rider's role last changed (fixDoubleLead keeps the earlier lead).
    const next = { ...room.riders.get(uid), role, roleAt: now() };
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
          if (this.mirror) this.mirror.replicate(groupId, { alerts: [open] });
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
      await this._storeAlert(room, alert, doc, { sender: user.userId });
      if (room.unsaved && room.unsaved.has(alert.alertId)) throw notStored();
      return { alert, duplicate: false };
    }
    const alert = {
      ...base, userId: user.userId, userName: user.name,
      ...this._emergencyFields(room, { lat: base.lat, lng: base.lng, msg: { heading: msg.heading }, source: 'NEARBY_REPORT', alertType: 'RIDER_DOWN', t, status: 'ASSISTANCE_ARRIVED' }),
    };
    // The injured person is not the reporter: no medical info of the reporter is attached.
    await this._storeAlert(room, alert, null, { sender: user.userId });
    if (room.unsaved && room.unsaved.has(alert.alertId)) throw notStored();
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
    const unsavedKey = `resp:${a.alertId}`;
    // The same answer again after its store failed: stored now (the ACK waits for it).
    const unchanged = async () => {
      if (room.unsaved && room.unsaved.has(unsavedKey)) {
        try { await this.repo.updateAlert(groupId, a.alertId, { responders: a.responders || {} }); } catch { throw notStored(); }
        this._setUnsaved(room, unsavedKey, false);
      }
      return { changed: false, responders: respondersList(map) };
    };
    if (k === 'CANCEL') {
      if (!prev) return unchanged();
      delete map[user.userId];
    } else {
      if (prev && prev.kind === k) return unchanged();
      if (!prev && Object.keys(map).length >= config.sosRespondersMax) throw new ConvoyError('Enough riders are already responding.', 409, 'RESPONDERS_FULL');
      map[user.userId] = { userId: user.userId, name: user.name, kind: k, at: t };
    }
    a.responders = map;
    let persisted = true;
    try { await this.repo.updateAlert(groupId, a.alertId, { responders: map }); } catch (e) {
      persisted = false;
      this.log.warn('[convoys] SOS response store failed', e.message);
    }
    this._setUnsaved(room, unsavedKey, !persisted);
    const responders = respondersList(map);
    await this._durable(groupId, 'SOS_RESPONSE', { alertId: a.alertId, userId: user.userId, name: user.name, kind: k === 'CANCEL' ? null : k, at: t, responders }, { sender: user.userId, persisted });
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
    if (!persisted) throw notStored();
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
        assistHelp: p.assistHelp, assistAsk: p.assistAsk,
      };
      room.riders.set(userId, next);
      room.dirty.add(userId);
      this._schedulePersist(room);
      if (this.mirror) this.mirror.replicate(room.groupId, { riders: [next] });
      if (cur.phone !== next.phone || cur.emergencyContact !== next.emergencyContact || cur.emergencyContactName !== next.emergencyContactName) {
        this._emit(room.groupId, 'RIDER_UPDATE', { rider: publicRider(next) });
      }
      if (rosterChange) this._emit(room.groupId, 'ROSTER_CHANGED', {});
    }
    return rooms.length;
  }

  // ------------------------------------------------------ 3.55 live bike change
  /**
   * RIDER_VEHICLE: the rider picked another garage bike during the ride, so the colour (and model)
   * the group sees follow at once instead of on the next join. Validated (riderVehicleInput), at
   * most one per rider per VEHICLE_RATE_MS (409 VEHICLE_RATE: the app keeps the latest and sends it
   * after the window), and refused for a pillion or a rider whose bike was swapped in this ride (the
   * swap decides that rider's bike). Applied to this ride's rider record only, never the profile;
   * the change goes out as RIDER_UPDATE (old apps apply vehicleColor and ignore vehicleModel) and
   * is in every later snapshot.
   */
  async setRiderVehicle(groupId, user, msg) {
    const room = await this.getRoom(groupId);
    if (room.meta.tripStatus === 'ENDED') throw new ConvoyError('This ride has ended.', 409, 'TRIP_ENDED');
    const me = room.riders.get(user.userId);
    if (!me) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const v = riderVehicleInput(msg);
    if (me.isCoRiding || String(me.vehicleNo || '').toUpperCase() === 'PILLION') {
      throw new ConvoyError('A pillion has no bike of their own in this ride.', 409, 'PILLION_RIDER');
    }
    if (me.rideVehicle) throw new ConvoyError('You swapped bikes in this ride. The swapped bike stays.', 409, 'BIKE_SWAPPED');
    const t = now();
    const log = room.vehicleLog || (room.vehicleLog = new Map());
    const last = log.get(me.userId) || 0;
    if (t - last < VEHICLE_RATE_MS) throw new ConvoyError('Bike changed a moment ago. Try again in a few seconds.', 409, 'VEHICLE_RATE');
    const next = { ...me, ...v };
    if (next.vehicleColor === me.vehicleColor && (next.vehicleModel || '') === (me.vehicleModel || '')
      && (next.vehicleKind || '') === (me.vehicleKind || '') && !!next.bikeComplete === !!me.bikeComplete) return publicRider(me);
    log.set(me.userId, t);
    room.riders.set(me.userId, next);
    room.dirty.add(me.userId);
    this._touch(room);
    this._schedulePersist(room);
    this._emit(groupId, 'RIDER_UPDATE', { rider: publicRider(next) });
    return publicRider(next);
  }

  // ------------------------------------------------------ 3.55 pillion seat
  /** True when the record is a pillion (seated on a bike, or a pillion account). */
  _isPillionRecord(r) {
    return !!r && (!!r.isCoRiding || String(r.vehicleNo || '').toUpperCase() === 'PILLION');
  }

  /** The rider seated as pillion on `riderId`'s bike, or null. */
  _pillionOf(room, riderId) {
    for (const r of room.riders.values()) if (r.isCoRiding && r.ridingWithUserId === riderId) return r;
    return null;
  }

  /**
   * PILLION_SEAT {withUserId}: the caller confirms which bike they ride pillion on. The target must be
   * a rider of this group ride with a bike of their own (not a pillion), without a pillion, and not the
   * caller; the caller must not carry a pillion. Applied to this ride's rider records (isCoRiding,
   * ridingWithUserId, pillionSeatAt; persisted in the room snapshot and replicated like the rest),
   * broadcast as RIDER_UPDATE + PILLION_SEATED to everyone. The rider may decline within
   * PILLION_DECLINE_MS (and remove the pillion any time) with PILLION_UNSEAT. Rate limited per rider.
   */
  async seatPillion(groupId, user, withUserId) {
    const room = await this.getRoom(groupId);
    this._requireGroupRide(room);
    if (room.meta.tripStatus === 'ENDED') throw new ConvoyError('This ride has ended.', 409, 'TRIP_ENDED');
    const me = room.riders.get(user.userId);
    if (!me) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const uid = typeof withUserId === 'string' && withUserId.length <= 64 ? withUserId : '';
    if (!uid) throw new ConvoyError('Pick the rider whose bike you sit on.', 400, 'BAD_PILLION');
    if (uid === me.userId) throw new ConvoyError('You cannot ride pillion on your own bike.', 400, 'BAD_PILLION');
    const target = room.riders.get(uid);
    if (!target) throw new ConvoyError('That rider is not in this convoy.', 404, 'NOT_MEMBER');
    if (this._isPillionRecord(target)) throw new ConvoyError('That rider is a pillion and has no bike in this ride.', 409, 'TARGET_PILLION');
    if (me.isCoRiding && me.ridingWithUserId === uid) {
      return { riderUserId: uid, declineBy: (me.pillionSeatAt || 0) + PILLION_DECLINE_MS, already: true };
    }
    const taken = this._pillionOf(room, uid);
    if (taken && taken.userId !== me.userId) throw new ConvoyError('That bike already has a pillion.', 409, 'SEAT_TAKEN');
    if (this._pillionOf(room, me.userId)) throw new ConvoyError('Someone rides pillion on your bike. Remove them first.', 409, 'HAS_PILLION');
    const t = now();
    const log = room.pillionLog || (room.pillionLog = new Map());
    const recent = (log.get(me.userId) || []).filter((x) => t - x < PILLION_RATE_WINDOW_MS);
    if (recent.length >= PILLION_RATE_MAX) throw new ConvoyError('Too many seat changes. Try again in a few minutes.', 409, 'PILLION_RATE');
    recent.push(t);
    log.set(me.userId, recent);
    // Moving from one bike to another: the first rider is told the seat is free.
    if (me.isCoRiding && me.ridingWithUserId && room.riders.has(me.ridingWithUserId)) {
      this._emit(groupId, 'PILLION_UNSEATED', {
        pillion: this._who(me), rider: this._who(room.riders.get(me.ridingWithUserId)), reason: 'MOVED', byUserId: me.userId,
      });
    }
    const next = { ...me, isCoRiding: true, ridingWithUserId: uid, pillionSeatAt: t };
    await this._saveRiderNow(room, next);
    const declineBy = t + PILLION_DECLINE_MS;
    this._emit(groupId, 'PILLION_SEATED', {
      pillion: this._who(next),
      rider: { ...this._who(target), vehicleModel: target.vehicleModel || '', vehicleColor: target.vehicleColor || '', vehicleKind: target.vehicleKind || '' },
      at: t, declineBy,
    });
    this.emit('activity', groupId, { type: 'CORIDE', user: { userId: me.userId, name: me.name || user.name || '' }, withUserId: uid });
    return { riderUserId: uid, declineBy };
  }

  /**
   * PILLION_UNSEAT {userId?}: the pillion gets off (no userId, or their own), or the rider declines
   * (within PILLION_DECLINE_MS: reason DECLINED) or removes (later: REMOVED) the pillion on their bike.
   * Never feature-gated (getting off is always allowed). Broadcast as RIDER_UPDATE + PILLION_UNSEATED.
   */
  async unseatPillion(groupId, user, pillionUserId) {
    const room = await this.getRoom(groupId);
    if (room.meta.tripStatus === 'ENDED') throw new ConvoyError('This ride has ended.', 409, 'TRIP_ENDED');
    const me = room.riders.get(user.userId);
    if (!me) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const pid = typeof pillionUserId === 'string' && pillionUserId.length <= 64 && pillionUserId ? pillionUserId : me.userId;
    const pillion = room.riders.get(pid);
    if (!pillion || !pillion.isCoRiding || !pillion.ridingWithUserId) {
      throw new ConvoyError('Nobody rides pillion there now.', 409, 'NOT_SEATED');
    }
    let reason;
    if (pid === me.userId) reason = 'PILLION_LEFT';
    else if (pillion.ridingWithUserId === me.userId) reason = now() - (pillion.pillionSeatAt || 0) <= PILLION_DECLINE_MS ? 'DECLINED' : 'REMOVED';
    else throw new ConvoyError('Only the rider of that bike can remove their pillion.', 403, 'NOT_YOUR_PILLION');
    await this._unlinkPillion(room, pillion, reason, me.userId);
    return { reason };
  }

  /** Clears one pillion link and tells everyone (RIDER_UPDATE + PILLION_UNSEATED). */
  async _unlinkPillion(room, pillion, reason, byUserId) {
    const riderRec = room.riders.get(pillion.ridingWithUserId);
    const riderWho = riderRec ? this._who(riderRec) : { userId: pillion.ridingWithUserId, name: '' };
    const next = { ...pillion, isCoRiding: false, ridingWithUserId: '', pillionSeatAt: 0 };
    await this._saveRiderNow(room, next);
    this._emit(room.groupId, 'PILLION_UNSEATED', { pillion: this._who(next), rider: riderWho, reason, byUserId });
    this.emit('activity', room.groupId, { type: 'CORIDE', user: { userId: next.userId, name: next.name || '' }, withUserId: '' });
  }

  /** After `left` left the room: their pillion is unlinked (RIDER_LEFT), or their seat is freed (PILLION_LEFT). */
  async _pillionLeft(room, left) {
    for (const r of [...room.riders.values()]) {
      if (r.isCoRiding && r.ridingWithUserId === left.userId) await this._unlinkPillion(room, r, 'RIDER_LEFT', left.userId);
    }
    if (left.isCoRiding && left.ridingWithUserId && room.riders.has(left.ridingWithUserId)) {
      this._emit(room.groupId, 'PILLION_UNSEATED', {
        pillion: this._who(left), rider: this._who(room.riders.get(left.ridingWithUserId)), reason: 'PILLION_LEFT', byUserId: left.userId,
      });
    }
  }

  _who(r) { return { userId: r.userId, name: r.name || '' }; }

  /** A rider record changed by the server: memory, its own document now, the snapshot soon, RIDER_UPDATE. */
  async _saveRiderNow(room, next) {
    room.riders.set(next.userId, next);
    room.dirty.add(next.userId);
    this._touch(room);
    this._schedulePersist(room);
    await this.repo.upsertRider(room.groupId, next).catch((e) => this.log.warn('[convoys] rider save failed', e.message));
    this._emit(room.groupId, 'RIDER_UPDATE', { rider: publicRider(next) });
  }

  // ------------------------------------------------------ 3.55 bike / pillion swap
  /**
   * Two riders of a group ride swap their bikes (BIKES), or a rider and their pillion change places
   * (PILLION). The requester asks, only the other rider answers, within SWAP_TTL_MS. Pending asks
   * are kept in the convoy meta (`pendingSwaps`, server only, never in a snapshot): saved with the
   * meta and replicated to the peer gateway like the rest of the room, so a restart or failover keeps
   * them until they expire (the node that owns the room tells the requester). Applied to the rider
   * records of this ride, never to the account profile; `rideVehicle`
   * (server only) keeps the swapped bike over the profile when the rider re-joins this ride.
   * Personal messages (SWAP_ASK to the target, SWAP_RESULT to the requester) go out as the
   * 'userMessage' event (the hub sends them to that rider's sockets, through the peer if needed);
   * SWAP_DONE and RIDER_UPDATEs go to the room. Older apps ignore the new types.
   */
  async requestSwap(groupId, user, withUserId, kind) {
    const room = await this.getRoom(groupId);
    this._requireGroupRide(room);
    if (room.meta.tripStatus === 'ENDED') throw new ConvoyError('This ride has ended.', 409, 'TRIP_ENDED');
    const k = SWAP_KINDS.has(kind) ? kind : null;
    if (!k) throw new ConvoyError('Swap kind must be BIKES or PILLION.', 400, 'BAD_SWAP');
    const me = room.riders.get(user.userId);
    if (!me) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const uid = typeof withUserId === 'string' && withUserId.length <= 64 ? withUserId : '';
    const other = uid ? room.riders.get(uid) : null;
    if (!other) throw new ConvoyError('That rider is not in this convoy.', 404, 'NOT_MEMBER');
    if (other.userId === me.userId) throw new ConvoyError('Pick another rider to swap with.', 400, 'BAD_SWAP');
    const paired = this._pillionPair(me, other);
    if (k === 'PILLION' && !paired) throw new ConvoyError('You can only swap with your own rider or pillion.', 409, 'NOT_PAIRED');
    if (k === 'BIKES' && (me.isCoRiding || other.isCoRiding)) {
      throw new ConvoyError('A pillion has no bike to swap. Swap rider and pillion instead.', 409, 'PILLION_RIDER');
    }
    const t = now();
    const swaps = this._swapsOf(room, t);
    const pair = [me.userId, other.userId].sort().join('|');
    for (const x of swaps.values()) {
      if (x.pair === pair) throw new ConvoyError('A swap between you two is already waiting for an answer.', 409, 'SWAP_PENDING');
    }
    // A few asks per rider per window, so nobody can keep popping prompts on another phone.
    const log = room.swapLog || (room.swapLog = new Map());
    const recent = (log.get(me.userId) || []).filter((x) => t - x < SWAP_RATE_WINDOW_MS);
    if (recent.length >= SWAP_RATE_MAX) throw new ConvoyError('Too many swap requests. Try again in a few minutes.', 409, 'SWAP_RATE'); // 409, not 429: the phone outbox must not keep retrying it
    recent.push(t);
    log.set(me.userId, recent);
    const requestId = `SWP-${crypto.randomBytes(6).toString('hex').toUpperCase()}`;
    const pending = {
      requestId, kind: k, pair, fromUserId: me.userId, fromName: me.name || user.name || '', toUserId: other.userId,
      toName: other.name || '', at: t, expiresAt: t + SWAP_TTL_MS, timer: null,
    };
    swaps.set(requestId, pending);
    this._swapTimer(room, pending, t);
    await this._storeSwaps(room);
    this.emit('userMessage', groupId, other.userId, {
      type: 'SWAP_ASK', groupId, requestId, fromUserId: pending.fromUserId, fromName: pending.fromName, kind: k, expiresAt: pending.expiresAt,
    });
    return { requestId, expiresAt: pending.expiresAt };
  }

  /** The asked rider answers. Only they may; an unknown or expired request is 404 SWAP_EXPIRED. */
  async answerSwap(groupId, user, requestId, accept) {
    const room = await this.getRoom(groupId);
    const id = typeof requestId === 'string' && SWAP_ID.test(requestId) ? requestId : '';
    const swaps = this._swapsOf(room, now());
    const pending = id ? swaps.get(id) : null;
    if (!pending) throw new ConvoyError('This swap request has expired.', 404, 'SWAP_EXPIRED');
    if (pending.toUserId !== user.userId) throw new ConvoyError('Only the rider who was asked can answer.', 403, 'NOT_SWAP_TARGET');
    swaps.delete(id);
    clearTimeout(pending.timer);
    await this._storeSwaps(room);
    if (accept !== true) {
      this.emit('userMessage', groupId, pending.fromUserId, { type: 'SWAP_RESULT', groupId, requestId: id, accepted: false, kind: pending.kind, byUserId: user.userId, byName: pending.toName });
      return { accepted: false };
    }
    // Checked again: someone may have left, the ride ended or the pair split meanwhile.
    if (room.meta.tripStatus === 'ENDED') throw new ConvoyError('This ride has ended.', 409, 'TRIP_ENDED');
    const a = room.riders.get(pending.fromUserId), b = room.riders.get(pending.toUserId);
    if (!a || !b) throw new ConvoyError('That rider is not in this convoy.', 404, 'NOT_MEMBER');
    let nextA, nextB;
    const bike = (r) => ({ vehicleNo: r.vehicleNo || '', vehicleType: r.vehicleType || 'Motorcycle', vehicleColor: r.vehicleColor || 'Black' });
    if (pending.kind === 'PILLION') {
      if (!this._pillionPair(a, b)) throw new ConvoyError('You are no longer riding together.', 409, 'NOT_PAIRED');
      const pillion = a.isCoRiding && a.ridingWithUserId === b.userId ? a : b;
      const driver = pillion === a ? b : a;
      const drive = bike(driver);
      const ride = { vehicleNo: 'PILLION', vehicleType: 'Pillion Rider', vehicleColor: pillion.vehicleColor || drive.vehicleColor };
      const newDriver = { ...pillion, ...drive, rideVehicle: drive, isCoRiding: false, ridingWithUserId: '' };
      const newPillion = { ...driver, ...ride, rideVehicle: ride, isCoRiding: true, ridingWithUserId: pillion.userId };
      [nextA, nextB] = pillion === a ? [newDriver, newPillion] : [newPillion, newDriver];
    } else {
      if (a.isCoRiding || b.isCoRiding) throw new ConvoyError('A pillion has no bike to swap.', 409, 'PILLION_RIDER');
      const ba = bike(a), bb = bike(b);
      nextA = { ...a, ...bb, rideVehicle: bb };
      nextB = { ...b, ...ba, rideVehicle: ba };
    }
    room.riders.set(a.userId, nextA);
    room.riders.set(b.userId, nextB);
    this._touch(room);
    for (const r of [nextA, nextB]) {
      // Like a role change: its own document now, the room snapshot follows with the next flush.
      room.dirty.add(r.userId);
      this._schedulePersist(room);
      await this.repo.upsertRider(groupId, r).catch((e) => this.log.warn('[convoys] swap save failed', e.message));
      this._emit(groupId, 'RIDER_UPDATE', { rider: publicRider(r) });
    }
    const who = (r) => ({ userId: r.userId, name: r.name || '', vehicleNo: r.vehicleNo || '', vehicleType: r.vehicleType || '' });
    this._emit(groupId, 'SWAP_DONE', { kind: pending.kind, requestId: id, a: who(nextA), b: who(nextB) });
    this.emit('activity', groupId, {
      type: 'VEHICLE_SWAP', user: { userId: a.userId, name: a.name || '' }, kind: pending.kind,
      withUserId: b.userId, withName: b.name || '', vehicleNo: nextA.vehicleNo || '', withVehicleNo: nextB.vehicleNo || '',
    });
    if (pending.kind === 'PILLION') {
      // The co-riding timeline entries follow who is the pillion now.
      for (const r of [nextA, nextB]) this.emit('activity', groupId, { type: 'CORIDE', user: { userId: r.userId, name: r.name || '' }, withUserId: r.isCoRiding ? r.ridingWithUserId : '' });
    }
    this.emit('fleet');
    return { accepted: true, a: who(nextA), b: who(nextB) };
  }

  /** True when one of the two rides pillion with the other. */
  _pillionPair(a, b) {
    return (!!a.isCoRiding && a.ridingWithUserId === b.userId) || (!!b.isCoRiding && b.ridingWithUserId === a.userId);
  }

  /**
   * The room's pending swap asks, following the stored / replicated `meta.pendingSwaps` (asks made or
   * answered on the peer, or before a restart), expired ones dropped (their requesters told, as by
   * the timer). Every ask has a timer on this node.
   */
  _swapsOf(room, t) {
    const swaps = room.swaps || (room.swaps = new Map());
    const stored = room.meta.pendingSwaps && typeof room.meta.pendingSwaps === 'object' ? room.meta.pendingSwaps : {};
    if (room.meta.tripStatus === 'ENDED') {
      for (const x of swaps.values()) clearTimeout(x.timer);
      swaps.clear();
      return swaps;
    }
    for (const [id, x] of swaps) if (!stored[id]) { clearTimeout(x.timer); swaps.delete(id); }
    for (const [id, x] of Object.entries(stored)) {
      if (!SWAP_ID.test(id) || !x || typeof x !== 'object' || !Number.isFinite(x.expiresAt)) continue;
      if (!swaps.has(id)) swaps.set(id, { ...x, requestId: id, timer: null });
      this._swapTimer(room, swaps.get(id), t);
    }
    for (const [id, x] of swaps) if (x.expiresAt <= t) this._expireSwap(room.groupId, id);
    return swaps;
  }

  /** Starts the expiry timer of an ask on this node (once). */
  _swapTimer(room, pending, t, delay = null) {
    if (pending.timer) return;
    const ms = delay ?? Math.max(0, pending.expiresAt - t);
    pending.timer = setTimeout(() => { pending.timer = null; this._expireSwap(room.groupId, pending.requestId); }, ms);
    if (pending.timer.unref) pending.timer.unref();
  }

  /**
   * Writes the room's pending asks into the meta at once (plain objects, no timers), then saves the
   * meta and replicates it to the peer. A failed save is logged: the ask still works on this node.
   */
  async _storeSwaps(room) {
    const plain = {};
    for (const [id, x] of room.swaps || []) {
      const { timer, ...rest } = x;
      plain[id] = rest;
    }
    if (Object.keys(plain).length) room.meta.pendingSwaps = plain; else delete room.meta.pendingSwaps;
    this._touch(room);
    if (this.mirror) this.mirror.replicate(room.groupId, { meta: room.meta });
    await this.repo.saveConvoyMeta(room.meta).catch((e) => this.log.warn('[convoys] swap save failed', e.message));
  }

  /**
   * No answer in time: the requester hears it was not accepted. Told by the node that owns the room;
   * the other node keeps the ask until the owner's change arrives (or takes over after a failover).
   */
  _expireSwap(groupId, requestId) {
    const room = this.rooms.get(groupId);
    const pending = room?.swaps?.get(requestId);
    if (!pending) return;
    clearTimeout(pending.timer);
    pending.timer = null;
    if (this.passive(groupId) && now() - pending.expiresAt < SWAP_TTL_MS) {
      this._swapTimer(room, pending, now(), 5000);
      return;
    }
    room.swaps.delete(requestId);
    this._storeSwaps(room).catch(() => {});
    this.emit('userMessage', groupId, pending.fromUserId, { type: 'SWAP_RESULT', groupId, requestId, accepted: false, kind: pending.kind, expired: true });
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
    // Chat survives a gateway restart: the stored messages carry their clientId (one not stored yet is not "seen").
    if (type === 'CHAT') return room.messages.some((m) => m.senderId === userId && m.clientId === clientId && !(room.unsaved && room.unsaved.has(m.messageId)));
    return false;
  }

  rememberClientId(room, userId, clientId) {
    const map = room.clientIds || (room.clientIds = new Map());
    const k = `${userId}:${clientId}`;
    map.delete(k);
    map.set(k, now());
    if (this.mirror) this.mirror.replicate(room.groupId, { cids: [[k, map.get(k)]] });
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

  /**
   * Lead rights (pause / resume, riding roles, stops and route, regroup, buddy pairs, live links of
   * others, hazard broadcast): the Trip owner, a platform master admin, or a Lead the owner picked.
   * 3.55 (owner decision, Nov 9): the Trip head is NOT here. A trip head who also rides as a picked
   * Lead keeps these rights by that riding role. With automatic roles on, the riding LEAD is simply
   * whoever is at the front, so it does not carry the lead's rights.
   */
  isLead(room, user) {
    const rider = room.riders.get(user.userId);
    const isOwner = room.meta.tripOwnerUserId === user.userId || room.meta.createdByUserId === user.userId;
    const ridingLead = rider?.role === 'LEAD' && room.meta.autoRoles !== true;
    return user.role === 'MASTER_ADMIN' || isOwner || ridingLead;
  }

  /** The Trip head of this trip (secondary owner chosen by the Trip owner). */
  isTripHead(room, user) {
    return !!room?.meta?.tripHeadUserId && !!user && room.meta.tripHeadUserId === user.userId;
  }

  /**
   * Group settings (CONFIG: speed limits, thresholds, voice, visibility, feature policy, public ride,
   * automatic roles): everyone with lead rights, plus the Trip head. 3.55 owner decision: changing
   * the trip's settings is the only extra power of the Trip head.
   */
  canChangeSettings(room, user) {
    if (!room || !user) return false;
    return this.isLead(room, user) || this.isTripHead(room, user);
  }

  /**
   * Management rights of this trip (end the trip, remove riders): the Trip owner (creator) and
   * platform admins (ADMIN, MASTER_ADMIN). 3.55 owner decision: the Trip head can NOT end the trip
   * or remove riders; choosing the Trip head stays with the Trip owner. Riding roles never give these.
   */
  canManage(room, user) {
    if (!room || !user) return false;
    const m = room.meta;
    return user.role === 'ADMIN' || user.role === 'MASTER_ADMIN'
      || (m.tripOwnerUserId || m.createdByUserId) === user.userId || m.createdByUserId === user.userId;
  }

  _requireMember(room, user) {
    if (!room.riders.has(user.userId)) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
  }

  _requireLead(room, user) {
    this._requireMember(room, user);
    if (!this.isLead(room, user)) throw new ConvoyError('Only the Trip owner or Lead can do this.', 403, 'NOT_LEAD');
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
    this._requireGroupRide(room);
    const rider = room.riders.get(user.userId);
    // Trip owner, a Lead the owner picked (isLead: never an automatic front rider), or the sweeper.
    // 3.55: not the Trip head as such (settings only), unless they ride as that Lead or sweeper.
    const isLeadOrSweeper = this.isLead(room, user) || rider.role === 'SWEEPER';
    if (!isLeadOrSweeper) {
      throw new ConvoyError('Only the Trip owner, Lead or sweeper can set a regroup point.', 403, 'NOT_AUTHORIZED');
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
    // 3.55: the Trip owner, a lead the owner picked (never a front rider chosen by automatic roles)
    // and the Trip head (owner decision: the trip head can change the trip's settings, nothing more).
    if (!this.canChangeSettings(room, user)) {
      throw new ConvoyError('Only the Trip owner, Trip head or Lead can change group settings.', 403, 'NOT_LEAD');
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
    // Public ride (every plan; the host decides, the rider of a solo ride is its host).
    if (patch.publicRide && typeof patch.publicRide === 'object') updated.publicRide = applyPublicRidePatch(updated.publicRide, patch.publicRide);
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
    this._emit(groupId, 'CONFIG', this._configPayload(room));
  }

  /** The CONFIG event: group settings and the ride's seats. */
  _configPayload(room) {
    const { distanceThresholdMeters, stopThresholdSeconds, voiceGuidanceEnabled } = room.meta;
    return {
      distanceThresholdMeters, stopThresholdSeconds, voiceGuidanceEnabled, speedLimitKmh: room.meta.speedLimitKmh || 0,
      townLimitKmh: room.meta.townLimitKmh || 0,
      featurePolicy: featurePolicy(room.meta.featurePolicy),
      visibility: room.meta.visibility === 'PUBLIC' ? 'PUBLIC' : 'PRIVATE', discovery: room.meta.discovery === true, assistDefault: room.meta.assistDefault !== false,
      publicRide: publicRideView(room.meta.publicRide),
      capacity: this._storedCapacity(room.meta),
      capacityPlan: room.meta.capacityPlan || null,
      soloRide: this.isSoloRide(room),
      // 3.56 access mode: 'all', or the group features a hybrid free-tier ride includes.
      groupFeatures: Array.isArray(room.meta.groupFeatures) ? [...room.meta.groupFeatures] : 'all',
      // 3.55 fix: every group setting rides in CONFIG, so one CONFIG brings a rider fully up to date
      // (automatic roles decide whether a front rider has lead rights; before it came only in
      // AUTO_ROLES and a missed one stayed wrong until the next full snapshot).
      autoRoles: room.meta.autoRoles === true,
    };
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
        if (a.userId === uid) {
          // Their SOS goes, and with it any public live link to it (index entry included).
          if (a.liveLink && a.liveLink.hash) this.liveLinks.delete(a.liveLink.hash);
          room.alerts.delete(alertId); touched = true;
        } else if (mentions(a, id)) { room.alerts.set(alertId, scrub(a, id)); touched = true; }
      }
      for (const [rid, r] of [...room.riders.entries()]) {
        if (mentions(r, id)) { room.riders.set(rid, scrub(r, id)); room.dirty.add(rid); touched = true; }
      }
      if (mentions(room.meta, id)) { room.meta = scrubConvoyMeta(room.meta, id); touched = true; }
      if (touched) {
        await this.repo.saveConvoyMeta(room.meta);
        await this.flushRoom(room, { perRider: true }).catch(() => {});
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
    // Its riders are free to ride again (the lock used to outlive the dissolved convoy).
    await this.repo.releaseAllActiveTripsForGroup(groupId).catch(() => {});
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
  async setTripHead(groupId, user, targetUserId) {
    const room = await this.getRoom(groupId);
    const isOwner = (room.meta.tripOwnerUserId || room.meta.createdByUserId) === user.userId || user.role === 'ADMIN' || user.role === 'MASTER_ADMIN';
    if (!isOwner) throw new ConvoyError('Only the Trip owner can choose the Trip head.', 403, 'OWNER_ONLY');

    if (!targetUserId || !room.riders.has(targetUserId)) {
      throw new ConvoyError('Target rider is not in this convoy.', 404, 'NOT_MEMBER');
    }

    // 3.55 (owner decision): the Trip head can change the trip's settings only. Choosing a trip head
    // no longer moves the riding roles; the owner picks a Lead separately (Riding role), and a trip
    // head who rides as that Lead has the Lead's rights by that role.
    room.meta.tripHeadUserId = targetUserId;
    const newHead = room.riders.get(targetUserId);

    await this.repo.setActiveTrip(targetUserId, { groupId, role: 'HEAD', status: room.meta.tripStatus || 'STARTED' });
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    this._emit(groupId, 'TRIP_HEAD_CHANGED', { tripHeadUserId: targetUserId, name: newHead.name });
    return { ok: true, tripHeadUserId: targetUserId };
  }

  async removeRider(groupId, user, targetUserId) {
    const room = await this.getRoom(groupId);
    // Trip owner (and platform admins) only: the Trip head can change settings, not remove riders.
    if (!this.canManage(room, user)) throw new ConvoyError('Only the Trip owner can remove riders.', 403, 'OWNER_ONLY');

    const ownerId = room.meta.tripOwnerUserId || room.meta.createdByUserId;
    if (targetUserId === ownerId) {
      throw new ConvoyError('The Trip owner cannot be removed. End the trip instead.', 400, 'CANNOT_REMOVE_OWNER');
    }

    if (!room.riders.has(targetUserId)) {
      throw new ConvoyError('Rider is not in this convoy.', 404, 'NOT_MEMBER');
    }

    // The trip head role goes back to the owner. Riding roles are not touched here: leave() hands
    // the LEAD back to the owner when the removed rider was the Lead (never two LEADs).
    if (room.meta.tripHeadUserId === targetUserId) room.meta.tripHeadUserId = ownerId;

    await this.leave(groupId, targetUserId);
    return { ok: true, removedUserId: targetUserId };
  }

  /**
   * Stops a rider from joining this live ride again (membership owner removed them). Never removes a rider
   * who is in the ride now: they keep the group's SOS network until they leave or the ride ends.
   */
  async blockFutureJoin(groupId, userId) {
    const room = await this.getRoom(groupId, { required: false });
    if (!room || !ACTIVE_STATUSES.includes(room.meta.tripStatus) || !userId) return false;
    room.meta.joinBlocked = { ...(room.meta.joinBlocked || {}), [String(userId)]: now() };
    this._touch(room);
    await this.repo.saveConvoyMeta(room.meta);
    return true;
  }

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
  if (has('micMuted')) out.micMuted = !!patch.micMuted;
  if (has('isSpeaking')) out.isSpeaking = !!patch.isSpeaking;
  // 3.55 group break planner: only a fatigue level 0..3 (whole number), never the raw signals behind it.
  if (has('fatigueLevel')) {
    const f = typeof patch.fatigueLevel === 'number' && Number.isFinite(patch.fatigueLevel) ? Math.round(patch.fatigueLevel) : NaN;
    if (f >= 0 && f <= 3) { out.fatigueLevel = f; out.fatigueAt = now(); }
  }
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
    // Guest placeholder numbers are nobody's real contact: never shown to the group or texted.
    phone: realContactNumber(u, 'phone'),
    vehicleType: pillion ? 'Pillion Rider' : String(u.vehicleType || 'Motorcycle'),
    vehicleNo: pillion ? 'PILLION' : String(u.vehicleNo || ''),
    emergencyContact: realContactNumber(u, 'emergencyContact'),
    emergencyContactName: realContactNumber(u, 'emergencyContact') ? String(u.emergencyContactName || '') : '',
    smsOptOut: !!u.smsOptOut, // server only: never in publicRider
    // 3.15 nearby assistance, server only (never in publicRider).
    assistHelp: u.assistHelp !== false,
    assistAsk: u.assistAsk !== false,
  };
}

/** What the safety network needs from the subject's users doc at raise (memory only). */
function ownerInfo(u) {
  if (!u) return null;
  return {
    assistAsk: typeof u.assistAsk === 'boolean' ? u.assistAsk : undefined,
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
  // 3.55: the garage bike's model, when a newer app sends it (anything invalid is simply dropped).
  if (p && typeof p.vehicleModel === 'string') {
    const m = cleanVehicleModel(p.vehicleModel);
    if (m !== null) out.vehicleModel = m;
  }
  // 3.55 bike type and "bike details complete" (the new app enforces the details; older apps send
  // neither and are never refused, the rider is only marked incomplete).
  if (p && typeof p.vehicleKind === 'string' && VEHICLE_KINDS.has(p.vehicleKind)) out.vehicleKind = p.vehicleKind;
  if (p && typeof p.bikeComplete === 'boolean') out.bikeComplete = p.bikeComplete;
  return out;
}

/** Control and direction-override characters out, spaces collapsed; null when longer than VEHICLE_MODEL_MAX. */
function cleanVehicleModel(raw) {
  const m = String(raw).replace(/[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, ' ').replace(/\s+/g, ' ').trim();
  return m.length <= VEHICLE_MODEL_MAX ? m : null;
}

/**
 * 3.55 RIDER_VEHICLE body: {vehicleColor?, vehicleModel?}, at least one. The colour is a name as the
 * garage keeps it (letters first, at most 20 characters) or #RRGGBB, '' for "no colour" (shown as the
 * default); the model is plain text of at most 40 characters. Anything else is 400 BAD_VEHICLE.
 */
function riderVehicleInput(msg) {
  const out = {};
  const bad = (m) => new ConvoyError(m, 400, 'BAD_VEHICLE');
  if (msg && msg.vehicleColor !== undefined && msg.vehicleColor !== null) {
    if (typeof msg.vehicleColor !== 'string') throw bad('Bike colour must be text.');
    const c = msg.vehicleColor.replace(/\s+/g, ' ').trim();
    if (c && !VEHICLE_COLOUR_HEX.test(c) && !VEHICLE_COLOUR_NAME.test(c)) throw bad('Bike colour must be a colour name or #RRGGBB.');
    out.vehicleColor = VEHICLE_COLOUR_HEX.test(c) ? c.toUpperCase() : c;
  }
  if (msg && msg.vehicleModel !== undefined && msg.vehicleModel !== null) {
    if (typeof msg.vehicleModel !== 'string') throw bad('Bike model must be text.');
    const m = cleanVehicleModel(msg.vehicleModel);
    if (m === null) throw bad(`Bike model can be at most ${VEHICLE_MODEL_MAX} characters.`);
    out.vehicleModel = m;
  }
  if (msg && msg.vehicleKind !== undefined && msg.vehicleKind !== null) {
    if (typeof msg.vehicleKind !== 'string' || (msg.vehicleKind !== '' && !VEHICLE_KINDS.has(msg.vehicleKind))) throw bad('Unknown bike type.');
    out.vehicleKind = msg.vehicleKind;
  }
  if (msg && typeof msg.bikeComplete === 'boolean' && Object.keys(out).length) out.bikeComplete = msg.bikeComplete;
  if (!Object.keys(out).length) throw bad('Send the bike colour or model.');
  return out;
}

function stripKey(o) { const { key, ...rest } = o; return rest; }

/** Thrown when a durable record could not be stored: the sender gets nothing (no ERROR, no ACK) and resends. */
function notStored() {
  const e = new ConvoyError('Not stored yet.', 503, 'NOT_STORED');
  e.silent = true;
  return e;
}

function publicRider(r) {
  // Everything the convoy-mates need; nothing they don't.
  return {
    userId: r.userId, name: r.name, vehicleType: r.vehicleType || 'Motorcycle', vehicleColor: r.vehicleColor || 'Black',
    vehicleModel: r.vehicleModel || '', // 3.55: garage bike model ('' when unknown; old apps ignore it)
    // 3.55 bike type (map marker shape) and complete bike details; pillion seat time (decline window).
    vehicleKind: r.vehicleKind || '', bikeComplete: r.bikeComplete === true, pillionSeatAt: r.isCoRiding ? (r.pillionSeatAt || 0) : 0,
    lat: r.lat || 0, lng: r.lng || 0, speedKmh: r.speedKmh || 0, heading: r.heading || 0,
    batteryLevel: r.batteryLevel ?? 100, isCharging: !!r.isCharging, role: r.role || 'PACK',
    statusReason: r.statusReason || '', statusMessage: r.statusMessage || '', lastSeenEpochMs: r.lastSeenEpochMs || 0,
    phone: r.phone || '', emergencyContact: r.emergencyContact || '', emergencyContactName: r.emergencyContactName || '',
    vehicleNo: r.vehicleNo || '', isCoRiding: !!r.isCoRiding, ridingWithUserId: r.ridingWithUserId || '', stoppedSince: r.stoppedSince || 0,
    presence: r.presence || '', presenceAt: r.presenceAt || 0,
    fuelEstimate: r.fuelEstimate && now() - r.fuelEstimate.updatedAt < 120000 ? r.fuelEstimate : null,
    micMuted: !!r.micMuted,
    isSpeaking: !!r.isSpeaking,
    // 3.55: fatigue level 0..3, only while recent (10 min); 0 for older apps that never send it.
    fatigueLevel: Number.isInteger(r.fatigueLevel) && Number.isFinite(r.fatigueAt) && now() - r.fatigueAt < 600000 ? r.fatigueLevel : 0,
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
  ConvoyManager, ConvoyError, publicRider, publicAlert, sanitizeTelemetry, TELEMETRY_FIELDS, WAIT_MESSAGE, LIVE_STATUSES,
  statusOf, sourceOf, severityOf, falseAlarmCount, ownerInfo, EMERGENCY_OPEN, EMERGENCY_TERMINAL, EMERGENCY_SOURCES,
  townLimit, sha256, riderVehicleInput, VEHICLE_RATE_MS,
  VEHICLE_KINDS, PILLION_DECLINE_MS, PILLION_RATE_MAX, PILLION_RATE_WINDOW_MS,
};
