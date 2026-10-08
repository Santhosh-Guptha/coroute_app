'use strict';
/**
 * Rider Safety Network (3.15): "the closest capable rider should be able to help first, regardless
 * of group". Never depends on a group's Public / Private choice (that is discovery.js, a separate
 * module with separate state that this module never reads).
 *
 * Works only on memory: ConvoyManager.rooms (live convoys), a coarse grid of rider positions and
 * per-route indexes (net_geo.js). The own group's alert (3.14 ALERT) is always sent by ConvoyManager
 * before anything here runs; nothing here can delay or throttle it.
 *
 * Incident = one emergency place in the network (two groups' SOS 100 m apart are one incident).
 * For an incident the network:
 *   1. asks the 1 to 3 riders of OTHER live convoys who can realistically reach it before the
 *      subject's own group: riders on their own planned route with the point ahead of them (route
 *      mode), or, without route data, riders whose recent path heads straight at it (stricter
 *      fallback, at most one, optionally checked by one OSRM table call that never blocks);
 *   2. warns riders approaching the point on the same road (hazard), never parallel roads or riders
 *      who already passed;
 *   3. runs the responder lifecycle (accept, en route, arriving, arrived, cancel, unable) and keeps
 *      the subject's group informed (EMERGENCY_UPDATE), without ever telling either side the other
 *      group's identity.
 * External riders only ever see the whitelisted views at the bottom of this file, and only while
 * the incident is open.
 */
const { EventEmitter } = require('events');
const crypto = require('crypto');
const config = require('./config');
const { haversine } = require('./geo_math');
const {
  SpatialGrid, gridSize, projectAll, projectWindow, angleDiff, bearing, crossAlong, RouteIndexCache,
} = require('./net_geo');
const { ConvoyError, statusOf, sourceOf, severityOf, falseAlarmCount } = require('./convoys');

const ACTIVE_RESPONDER = new Set(['ACCEPTED', 'EN_ROUTE', 'ARRIVING', 'ARRIVED']);
const MOVING_RESPONDER = new Set(['ACCEPTED', 'EN_ROUTE', 'ARRIVING']);
const ANSWERS = new Set(['ACCEPT', 'DECLINE', 'CANCEL', 'UNABLE', 'ARRIVED', 'NOT_FOUND']);
const SEARCH_STATUSES = new Set(['CONFIRMED_ACCIDENT', 'ASSISTANCE_REQUESTED', 'RESPONDER_ASSIGNED']);
const HAZARD_TYPES = new Set(['CRASH', 'CRASH_OR_EMERGENCY', 'RIDER_DOWN']);
const SEVERITY_RANK = { LOW: 0, HIGH: 1, CRITICAL: 2 };
/** Notified riders who still count against the caps (asked and not out: not declined, timed out, closed, cancelled, unable). */
const LIVE_ASK = new Set(['REQUESTED', 'ACCEPTED', 'EN_ROUTE', 'ARRIVING', 'ARRIVED']);
const CLOSE_REASON = { RESOLVED: 'RESOLVED', FALSE_ALARM: 'FALSE_ALARM', CANCELLED: 'CANCELLED', EXPIRED: 'EXPIRED', TRIP_ENDED: 'RESOLVED' };

const r100 = (m) => Math.round(m / 100) * 100;
const r30 = (s) => Math.round(s / 30) * 30;
const r5 = (x) => Math.round(x * 1e5) / 1e5;
const firstName = (name) => String(name || '').trim().split(/\s+/)[0].slice(0, 20);

class SafetyNetwork extends EventEmitter {
  constructor({ convoys, geo = null, audit = null, logger = console, clock = Date.now, tickMs = config.netTickMs, routes = null, enabled = config.safetyNetEnabled } = {}) {
    super();
    this.convoys = convoys; this.geo = geo; this.audit = audit; this.log = logger; this.clock = clock;
    this.enabled = enabled;
    this.routes = routes || new RouteIndexCache({ simplifyM: config.netRouteSimplifyM, maxPoints: config.netRouteMaxPoints, G: gridSize(config.netGridMillideg) });
    this.grid = new SpatialGrid(gridSize(config.netGridMillideg));
    this.riders = new Map(); // uid -> { gid, path: [{lat,lng,t}], lastSeg, lastFixAt }
    this.incidents = new Map(); // incidentId -> incident
    this.byAlert = new Map(); // alertId -> incidentId
    this.subjects = new Map(); // uid -> Set<incidentId> (the injured rider's fixes move the incident)
    this.responderOf = new Map(); // uid -> incidentId (active external responder)
    this.osrmTimes = []; // global table call budget (last minute)
    this.reportFalseLog = new Map(); // uid -> times (per hour budget)
    this.rebuild = new Set(); // gids loaded after a restart: open alerts get their incident back
    this.out = { sendToUser: () => 0, broadcastCap: () => 0, online: () => false };
    this.lastPrune = 0;
    this.timer = setInterval(() => this._guard(() => this.tick()), tickMs);
    if (this.timer.unref) this.timer.unref();
  }

  attach(out) { this.out = out; }
  stop() { clearInterval(this.timer); }

  _guard(fn) {
    try {
      const r = fn();
      if (r && typeof r.catch === 'function') r.catch((e) => this.log.warn('[net]', e.message));
    } catch (e) { this.log.warn('[net]', e.message); }
  }

  _audit(row) { if (this.audit) this.audit.add(row); }
  _send(uid, payload) { try { return this.out.sendToUser(uid, payload, 'net1'); } catch { return 0; } }

  // ================================================================== inputs
  /** convoys 'emergency': RAISED | STATUS | RESOLVED. Cheap and synchronous; searching is deferred. */
  onEmergency(gid, alert, kind, ctx = {}) {
    if (!alert || !alert.alertId) return;
    if (kind === 'RAISED') {
      const inc = this._raised(gid, alert, ctx.owner || null);
      this._audit({ kind: 'RAISE', alertId: alert.alertId, groupId: gid, subjectId: alert.userId, incidentId: inc?.incidentId, detail: `${sourceOf(alert)} ${statusOf(alert)}` });
      if (inc) {
        setImmediate(() => this._guard(() => {
          const t = this.clock();
          if (inc.closed) return;
          this._own(inc, t); // the own group's nearest rider, shown even when nobody outside is asked
          this._search(inc, t, 0, inc.ownBest);
          this._hazards(inc, t);
          this._pushUpdate(inc, { force: true });
        }));
      }
      return;
    }
    if (kind === 'STATUS') {
      this._audit({ kind: 'STATUS', alertId: alert.alertId, groupId: gid, detail: statusOf(alert) });
      this._onStatus(gid, alert);
      return;
    }
    if (kind === 'RESOLVED') {
      const st = statusOf(alert);
      this._audit({ kind: st === 'EXPIRED' ? 'EXPIRE' : 'RESOLVE', alertId: alert.alertId, groupId: gid, subjectId: alert.userId, detail: st });
      this._onResolved(gid, alert);
    }
  }

  /** convoys 'telemetry': O(1) bookkeeping, plus subject / responder work when they are involved. */
  onTelemetry(gid, rider) {
    if (!rider || !Number.isFinite(rider.lat) || !Number.isFinite(rider.lng) || (rider.lat === 0 && rider.lng === 0)) return;
    const uid = rider.userId;
    let rs = this.riders.get(uid);
    if (!rs || rs.gid !== gid) {
      if (rs) this.grid.remove(`${rs.gid}|${uid}`);
      rs = { gid, path: [], lastSeg: null, lastFixAt: 0 };
      this.riders.set(uid, rs);
    }
    this.grid.update(`${gid}|${uid}`, rider.lat, rider.lng);
    const t = rider.lastSeenEpochMs || this.clock();
    rs.lastFixAt = t;
    const last = rs.path[rs.path.length - 1];
    if (!last || haversine(last.lat, last.lng, rider.lat, rider.lng) >= 50) {
      rs.path.push({ lat: rider.lat, lng: rider.lng, t });
      if (rs.path.length > 6) rs.path.shift();
    }
    if (this.incidents.size === 0) return;
    const subj = this.subjects.get(uid);
    if (subj) for (const id of subj) { const inc = this.incidents.get(id); if (inc) this._guard(() => this._subjectMoved(inc, gid, rider, t)); }
    const rid = this.responderOf.get(uid);
    if (rid) { const inc = this.incidents.get(rid); if (inc) this._guard(() => this._responderMoved(inc, uid, rider, t)); }
  }

  /** A room was loaded into memory (gateway restart): its open alerts get incidents on the next tick. */
  onRoomLoaded(gid) { this.rebuild.add(gid); }

  /** A room left memory (trip end, dissolved): everything of it is closed here; nothing changes in the DB. */
  onRoomEnded(gid, room) {
    for (const inc of [...this.incidents.values()]) {
      const mine = inc.alerts.filter((x) => x.gid === gid);
      if (mine.length) {
        for (const x of mine) this.byAlert.delete(x.alertId);
        inc.alerts = inc.alerts.filter((x) => x.gid !== gid);
        if (!inc.alerts.length) { this._close(inc, 'RESOLVED'); continue; }
        this._pickPrimary(inc);
      }
      // A responder whose own ride ended is no longer on the way.
      for (const R of inc.responders.values()) {
        if (R.gid === gid && MOVING_RESPONDER.has(R.status)) this._responderOut(inc, R, 'CANCELLED');
      }
    }
    if (room) for (const uid of room.riders.keys()) { const rs = this.riders.get(uid); if (rs && rs.gid === gid) { this.grid.remove(`${gid}|${uid}`); this.riders.delete(uid); } }
    this.routes.forget(gid);
    this.rebuild.delete(gid);
  }

  // ================================================================== incidents
  _alertOf(ref) { return this.convoys.rooms.get(ref.gid)?.alerts.get(ref.alertId) || null; }
  _primaryAlert(inc) { return this._alertOf(inc.primary); }

  /** Creates the incident for a new alert, or joins an open one (same place and time, or same subject). */
  _raised(gid, alert, owner) {
    if (alert.resolved || this.byAlert.has(alert.alertId)) return this.incidents.get(this.byAlert.get(alert.alertId)) || null;
    const room = this.convoys.rooms.get(gid);
    const t = this.clock();
    const source = sourceOf(alert);
    const severity = alert.severity || severityOf(alert.alertType, source);
    const nearby = source === 'NEARBY_REPORT';
    const hasPos = Number.isFinite(alert.lat) && Number.isFinite(alert.lng) && !(alert.lat === 0 && alert.lng === 0);
    const ownerAsk = owner && typeof owner.assistAsk === 'boolean' ? owner.assistAsk : (room?.meta.assistDefault !== false);
    const accOk = !Number.isFinite(alert.accuracyM) || alert.accuracyM <= config.netMaxAccuracyM;
    const assist = !nearby && SEVERITY_RANK[severity] >= 1 && statusOf(alert) !== 'ASSISTANCE_ARRIVED' && ownerAsk !== false && hasPos && accOk;
    const throttled = !!owner && falseAlarmCount({ falseAlarmAt: owner.falseAlarmAt }, Date.now()) >= config.abuseFalseAlarms;
    const hazardKind = (HAZARD_TYPES.has(alert.alertType) || source === 'CRASH_AUTO' || source === 'NEED_HELP') && SEVERITY_RANK[severity] >= 1;
    const hazards = hasPos && hazardKind && (!throttled || source === 'CRASH_AUTO');
    const ref = { gid, alertId: alert.alertId, uid: alert.userId, source, assist, ownerOptOut: ownerAsk === false, responderMedical: !!owner?.responderMedical };

    // Clustering: one incident per place (any group) or per subject.
    let inc = null;
    if (hasPos) {
      for (const cand of this.incidents.values()) {
        const sameSubject = !nearby && cand.alerts.some((x) => x.uid === alert.userId && x.source !== 'NEARBY_REPORT');
        const near = haversine(cand.lat, cand.lng, alert.lat, alert.lng) <= config.emergencyClusterM && t - cand.createdAt <= config.emergencyClusterMin * 60000;
        if (sameSubject || near) { inc = cand; break; }
      }
    }
    if (inc) {
      inc.alerts.push(ref);
      this.byAlert.set(alert.alertId, inc.incidentId);
      if (nearby) { inc.reports++; inc.onScene = true; }
      if (SEVERITY_RANK[severity] > SEVERITY_RANK[inc.severity]) inc.severity = severity;
      if (throttled) inc.throttled = true;
      if (hazards && !inc.hazards) inc.hazards = true;
      if (assist && inc.kind !== 'ASSIST') {
        // A real emergency joins a "rider down here" report: the incident starts searching.
        inc.kind = 'ASSIST'; inc.primary = ref; inc.stage = 1; inc.stageAt = t; inc.stageCount = 0;
        if (hasPos) { inc.lat = alert.lat; inc.lng = alert.lng; inc.accuracyM = alert.accuracyM; }
      }
      if (!nearby) this._addSubject(alert.userId, inc.incidentId);
      this._pushUpdate(inc, { force: true });
      return inc;
    }
    if (this.incidents.size >= config.netMaxIncidents) {
      // Oldest hazard-only incident makes room; assistance incidents are never dropped.
      const victim = [...this.incidents.values()].filter((x) => x.kind !== 'ASSIST').sort((a, b) => a.createdAt - b.createdAt)[0];
      if (victim) this._close(victim, 'RESOLVED');
      else if (!assist) return null;
    }
    inc = {
      incidentId: `NET-${crypto.randomBytes(6).toString('hex').toUpperCase()}`,
      alerts: [ref], primary: ref,
      lat: hasPos ? alert.lat : 0, lng: hasPos ? alert.lng : 0, heading: alert.heading, speedKmh: alert.speedKmh, accuracyM: alert.accuracyM,
      severity, createdAt: t, lastUpdateAt: alert.lastUpdateAt || t,
      kind: assist ? 'ASSIST' : 'HAZARD_ONLY', hazards,
      accident: HAZARD_TYPES.has(alert.alertType) || source === 'CRASH_AUTO' || source === 'NEED_HELP',
      stage: 1, stageAt: t, stageCount: 0, lowInStage: false, stage2Done: false,
      osrmCalls: 0, osrmPending: false,
      notified: new Map(), responders: new Map(), hazardSent: new Map(), falseReports: new Set(),
      throttled, onScene: nearby, reports: nearby ? 1 : 0, backupWanted: false, searchStopped: false,
      ownNearest: new Map(), ownBest: Infinity, level: null, lastEmergencyUpdateAt: 0, lastEtaSent: null, persistAt: t,
    };
    inc.level = this._level(inc);
    this.incidents.set(inc.incidentId, inc);
    this.byAlert.set(alert.alertId, inc.incidentId);
    if (!nearby) this._addSubject(alert.userId, inc.incidentId);
    return inc;
  }

  _addSubject(uid, id) {
    let s = this.subjects.get(uid);
    if (!s) { s = new Set(); this.subjects.set(uid, s); }
    s.add(id);
  }

  _pickPrimary(inc) {
    if (inc.alerts.includes(inc.primary)) return;
    inc.primary = inc.alerts.find((x) => x.assist) || inc.alerts.find((x) => x.source !== 'NEARBY_REPORT') || inc.alerts[0];
    if (!inc.alerts.some((x) => x.assist)) inc.kind = 'HAZARD_ONLY';
  }

  _onStatus(gid, alert) {
    const inc = this.incidents.get(this.byAlert.get(alert.alertId));
    if (!inc) return;
    inc.lastUpdateAt = Math.max(inc.lastUpdateAt, alert.lastUpdateAt || 0);
    const st = statusOf(alert);
    if (st === 'ASSISTANCE_ARRIVED') this._closePending(inc, 'TAKEN'); // someone is with them: nobody else needs to come
    this._updateLevel(inc);
    if (st === 'ASSISTANCE_REQUESTED' || st === 'CONFIRMED_ACCIDENT') setImmediate(() => this._guard(() => this._search(inc, this.clock())));
  }

  _onResolved(gid, alert) {
    const id = this.byAlert.get(alert.alertId);
    const inc = id && this.incidents.get(id);
    this.byAlert.delete(alert.alertId);
    if (!inc) return;
    const st = statusOf(alert);
    // False alarm counter (abuse prevention): never affects the own group, only external requests later.
    const genuineArrival = [...inc.responders.values()].some((R) => R.status === 'ARRIVED' && !inc.falseReports.has(R.uid));
    if ((st === 'FALSE_ALARM' && inc.notified.size > 0) || (inc.falseReports.size >= config.netFalseReportsFlag && !genuineArrival)) {
      const subject = alert.source === 'NEARBY_REPORT' || alert.source === 'MEMBER_REPORT' ? (alert.reportedBy || alert.userId) : alert.userId;
      this.convoys.repo.addFalseAlarm(subject, Date.now()).catch(() => {});
    }
    inc.alerts = inc.alerts.filter((x) => x.alertId !== alert.alertId);
    if (!inc.alerts.length) { this._close(inc, CLOSE_REASON[st] || 'RESOLVED'); return; }
    this._pickPrimary(inc);
    this._updateLevel(inc);
  }

  /** Ends an incident: every external rider loses access (ASSIST_CLOSED / HAZARD_CLEAR), memory freed. */
  _close(inc, reason) {
    if (inc.closed) return;
    inc.closed = true;
    this.incidents.delete(inc.incidentId);
    for (const x of inc.alerts) this.byAlert.delete(x.alertId);
    for (const uid of inc.notified.keys()) this._send(uid, { type: 'ASSIST_CLOSED', incidentId: inc.incidentId, reason });
    for (const uid of inc.hazardSent.keys()) this._send(uid, { type: 'HAZARD_CLEAR', hazardId: inc.incidentId });
    for (const [uid, id] of [...this.responderOf]) if (id === inc.incidentId) this.responderOf.delete(uid);
    for (const [uid, set] of [...this.subjects]) { set.delete(inc.incidentId); if (!set.size) this.subjects.delete(uid); }
  }

  // ================================================================== state for the own group
  _activeResponders(inc) { return [...inc.responders.values()].filter((R) => ACTIVE_RESPONDER.has(R.status)); }

  _state(inc) {
    if (!this.enabled || inc.kind !== 'ASSIST') return 'OFF';
    if (this._activeResponders(inc).length) return 'ASSIGNED';
    if ([...inc.notified.values()].some((n) => n.status === 'REQUESTED')) return 'REQUESTED';
    if (inc.stage2Done) return 'NONE_FOUND';
    return 'SEARCHING';
  }

  _respondersView(inc) {
    return [...inc.responders.values()].map((R) => {
      const out = { rid: R.rid, name: R.name, status: R.status, etaS: Number.isFinite(R.etaS) ? Math.round(R.etaS) : null, distanceM: Number.isFinite(R.distanceM) ? Math.round(R.distanceM / 10) * 10 : null, acceptedAt: R.acceptedAt || 0, arrivedAt: R.arrivedAt || 0 };
      if (MOVING_RESPONDER.has(R.status) && Number.isFinite(R.lat)) { out.lat = r5(R.lat); out.lng = r5(R.lng); }
      if (R.reason) out.reason = R.reason;
      return out;
    });
  }

  /** { network, ownNearest, position } for publicAlert / EMERGENCY_UPDATE of one alert, or null. */
  summaryFor(gid, alertId) {
    const inc = this.incidents.get(this.byAlert.get(alertId));
    if (!inc) return null;
    return {
      network: { state: this._state(inc), stage: inc.kind === 'ASSIST' ? inc.stage : 0, notified: inc.notified.size, onScene: !!inc.onScene, responders: this._respondersView(inc) },
      ownNearest: inc.ownNearest.get(gid) || null,
      // The incident follows the primary subject's fixes: only that alert's group gets it. Another
      // group's alert in the same incident keeps its own point (never another group's rider position).
      position: inc.primary.alertId === alertId ? { lat: r5(inc.lat), lng: r5(inc.lng) } : null,
    };
  }

  notifiedCount(gid, alertId) { const inc = this.incidents.get(this.byAlert.get(alertId)); return inc ? inc.notified.size : 0; }
  hasActiveResponder(gid, alertId) { const inc = this.incidents.get(this.byAlert.get(alertId)); return !!inc && this._activeResponders(inc).length > 0; }

  /** True while a room has an open emergency, or one of its riders is an active external responder (discovery suppression). */
  hasOpen(gid) {
    const room = this.convoys.rooms.get(gid);
    if (room) for (const a of room.alerts.values()) if (!a.resolved) return true;
    for (const [uid, id] of this.responderOf) {
      const R = this.incidents.get(id)?.responders.get(uid);
      if (R && R.gid === gid && ACTIVE_RESPONDER.has(R.status)) return true;
    }
    return false;
  }

  /** EMERGENCY_UPDATE to every original room of the incident (throttled unless forced). */
  _pushUpdate(inc, { force = false } = {}) {
    const t = this.clock();
    if (!force && t - inc.lastEmergencyUpdateAt < 30000) return;
    inc.lastEmergencyUpdateAt = t;
    for (const x of inc.alerts) this.convoys.emitEmergencyUpdate(x.gid, x.alertId);
  }

  /** A responder changed: own rooms told, netResponders persisted, SOS timeline entry updated. */
  _responderChanged(inc, R) {
    const list = [...inc.responders.values()].map((x) => ({ rid: x.rid, name: x.name, status: x.status, acceptedAt: x.acceptedAt || 0, arrivedAt: x.arrivedAt || 0 }));
    for (const x of inc.alerts) {
      const a = this._alertOf(x);
      if (!a) continue;
      a.netResponders = list;
      this.convoys.repo.updateAlert(x.gid, x.alertId, { netResponders: list }).catch(() => {});
      if (R) this.convoys.emit('activity', x.gid, { type: 'EMERGENCY_NETWORK', alert: a, network: { name: R.name, status: R.status, etaS: Number.isFinite(R.etaS) ? Math.round(R.etaS) : null } });
    }
    this._pushUpdate(inc, { force: true });
  }

  // ================================================================== matching
  _speedModel(kmh) {
    const k = Number(kmh) || 0;
    if (k < 10) return { v: config.netDefaultKmh / 3.6, penalty: config.netStoppedPenaltyS };
    return { v: Math.max(config.netMinKmh, Math.min(config.netMaxKmh, k)) / 3.6, penalty: 0 };
  }

  /** Passes of the incident point on a route index, cached until the point moves (WeakMap: indexes are replaced on route change). */
  _passes(inc, idx) {
    const latLimit = this._latLimit(inc);
    const c = inc.passCache;
    if (!c || c.lat !== inc.lat || c.lng !== inc.lng || c.latLimit !== latLimit) inc.passCache = { lat: inc.lat, lng: inc.lng, latLimit, byIdx: new WeakMap() };
    let p = inc.passCache.byIdx.get(idx);
    if (!p) { p = projectAll(idx, inc.lat, inc.lng, latLimit); inc.passCache.byIdx.set(idx, p); }
    return p;
  }

  _latLimit(inc) {
    const acc = Number.isFinite(inc.accuracyM) ? inc.accuracyM : 0;
    return Math.max(config.netRouteLateralM, Math.min(acc + 50, config.netRouteLateralMaxM));
  }

  _fresh(r, now) { return r && now - (r.lastSeenEpochMs || 0) <= config.netFreshS * 1000 && (r.lat || r.lng) && r.presence !== 'APP_CLOSED'; }

  /** The rider projected on their room's route (windowed), or null when off route / no usable route. */
  _onRoute(gid, room, rider) {
    const idx = this.routes.forMeta(gid, room.meta);
    if (!idx) return null;
    const rs = this.riders.get(rider.userId);
    const p = projectWindow(idx, rider.lat, rider.lng, rs?.lastSeg, { onRouteM: config.netOnRouteM });
    if (!p || p.lateralM > config.netOnRouteM) return null;
    if (rs) rs.lastSeg = p.segIndex;
    return { idx, p };
  }

  /** Route-mode ETA from a rider to the incident; null = reject. `aheadMax`, `allowPassed` for own members. */
  _routeEta(inc, on, rider, { aheadMax, headingCheck = true } = {}) {
    const passes = this._passes(inc, on.idx);
    if (!passes.length) return null; // the point is not on this rider's road (parallel road, other highway)
    let best = null;
    for (const pe of passes) {
      const ahead = pe.alongM - on.p.alongM;
      if (ahead > -config.netPassedTolM && (!best || ahead < best.ahead)) best = { ahead, pe };
    }
    if (!best || best.ahead > aheadMax) return null; // passed, or too far along the road
    const kmh = Number(rider.speedKmh) || 0;
    if (headingCheck && kmh >= 10 && angleDiff(Number(rider.heading) || 0, on.p.segBearing) > config.netHeadingTolDeg) return null; // riding the route backwards
    const { v, penalty } = this._speedModel(kmh);
    const dist = Math.max(best.ahead, 0) + best.pe.lateralM;
    return { etaS: dist / v + penalty, routeDistanceM: dist, lateralM: best.pe.lateralM };
  }

  /**
   * Fallback (no usable route or rider off their route): straight at it. The recent path must head
   * at the point within a narrow corridor and the distance must be shrinking. Returns null or a LOW match.
   */
  _pathMatch(rider, lat, lng, { maxD, lateral, minKmh }) {
    const kmh = Number(rider.speedKmh) || 0;
    if (kmh < minKmh) return null;
    const d = haversine(rider.lat, rider.lng, lat, lng);
    if (d > maxD) return null;
    const rs = this.riders.get(rider.userId);
    const path = rs ? rs.path : [];
    if (path.length < 3) return null;
    const o = path[0];
    if (haversine(o.lat, o.lng, rider.lat, rider.lng) < 300) return null;
    const ca = crossAlong(o.lat, o.lng, rider.lat, rider.lng, lat, lng);
    if (ca.cross > lateral || ca.along - ca.lineLength <= 0) return null; // beside the line (parallel road) or behind
    if (angleDiff(bearing(o.lat, o.lng, rider.lat, rider.lng), Number(rider.heading) || 0) > 35) return null;
    const last3 = path.slice(-3).map((p) => haversine(p.lat, p.lng, lat, lng));
    if (!(last3[0] > last3[1] && last3[1] > last3[2])) return null; // not closing in
    return { d, lateralM: ca.cross };
  }

  /** Fresh own-group riders' best ETA to the incident (Infinity when nobody), and ownNearest per room. */
  _own(inc, now) {
    let best = Infinity;
    for (const x of inc.alerts) {
      if (x.source === 'NEARBY_REPORT') continue;
      const room = this.convoys.rooms.get(x.gid);
      if (!room) continue;
      let nearest = null;
      for (const m of room.riders.values()) {
        if (m.userId === x.uid || !this._fresh(m, now)) continue;
        const { v, penalty } = this._speedModel(m.speedKmh);
        let r = null;
        const on = this._onRoute(x.gid, room, m);
        if (on) {
          const passes = this._passes(inc, on.idx);
          if (passes.length) {
            let behind = null, past = null;
            for (const pe of passes) {
              const ahead = pe.alongM - on.p.alongM;
              if (ahead > -config.netPassedTolM) { if (!behind || ahead < behind.ahead) behind = { ahead, pe }; }
              else if (!past || -ahead < past.d) past = { d: -ahead, pe };
            }
            if (behind) { const dist = Math.max(0, behind.ahead) + behind.pe.lateralM; r = { etaS: dist / v + penalty, distanceM: dist, routeBased: true }; }
            else if (past) { const dist = past.d + past.pe.lateralM; r = { etaS: dist / v + penalty + config.netUturnPenaltyS, distanceM: dist, routeBased: true }; }
          }
        }
        if (!r) {
          const d = haversine(m.lat, m.lng, inc.lat, inc.lng) * config.netDetourPct / 100;
          r = { etaS: d / v + penalty, distanceM: d, routeBased: false };
        }
        if (!nearest || r.etaS < nearest.etaS) nearest = { userId: m.userId, name: m.name, ...r };
      }
      inc.ownNearest.set(x.gid, nearest ? { userId: nearest.userId, name: nearest.name, etaS: Math.round(nearest.etaS), distanceM: Math.round(nearest.distanceM), routeBased: nearest.routeBased } : null);
      if (nearest && nearest.etaS < best) best = nearest.etaS;
    }
    inc.ownBest = best;
    return best;
  }

  /** Riders of other live convoys who may reach the incident, evaluated (HIGH = route based, LOW = fallback). */
  _candidates(inc, now) {
    const R = inc.stage === 1 ? config.netRadius1M : config.netRadius2M;
    const aheadMax = inc.stage === 1 ? config.netRouteAheadMax1M : config.netRouteAheadMax2M;
    const own = new Set(inc.alerts.map((x) => x.gid));
    const pool = [];
    for (const key of this.grid.query(inc.lat, inc.lng, R)) {
      const bar = key.indexOf('|');
      const gid = key.slice(0, bar), uid = key.slice(bar + 1);
      // Never asked twice, except riders whose request was closed because someone else took it
      // ("No assistance is currently required"): when that responder drops out they are the best
      // remaining riders again (not for a throttled owner: lifetime cap).
      const prevAsk = inc.notified.get(uid);
      if (own.has(gid) || (prevAsk && (prevAsk.status !== 'CLOSED' || inc.throttled))) continue;
      const room = this.convoys.rooms.get(gid);
      if (!room || room.meta.tripStatus !== 'STARTED') continue;
      const rider = room.riders.get(uid);
      if (!this._fresh(rider, now)) continue;
      const d = haversine(rider.lat, rider.lng, inc.lat, inc.lng);
      if (d > R) continue;
      pool.push({ gid, uid, room, rider, d });
    }
    pool.sort((a, b) => a.d - b.d);
    const out = [];
    for (const c of pool.slice(0, config.netMaxCandidatesEval)) {
      const { gid, uid, room, rider, d } = c;
      const help = typeof rider.assistHelp === 'boolean' ? rider.assistHelp : room.meta.assistDefault !== false;
      if (!help) continue;
      if ([...room.alerts.values()].some((a) => !a.resolved)) continue; // they have their own emergency
      if (this.responderOf.has(uid)) continue;
      if (!this.out.online(uid, 'net1')) continue;
      const isLead = room.meta.createdByUserId === uid || rider.role === 'LEAD';
      const on = this._onRoute(gid, room, rider);
      if (on) {
        const m = this._routeEta(inc, on, rider, { aheadMax });
        if (m) out.push({ gid, uid, d, isLead, mode: 'HIGH', etaS: m.etaS, routeDistanceM: m.routeDistanceM, lateralM: m.lateralM, aheadOnRoute: true });
        continue;
      }
      const f = this._pathMatch(rider, inc.lat, inc.lng, { maxD: R * config.netFallbackRadiusPct / 100, lateral: config.netFallbackLateralM, minKmh: config.netFallbackMinKmh });
      if (!f) continue;
      const { v } = this._speedModel(rider.speedKmh);
      out.push({ gid, uid, d, isLead, mode: 'LOW', etaS: f.d * config.netDetourPct / 100 / v, routeDistanceM: null, lateralM: f.lateralM, aheadOnRoute: false, v });
    }
    out.sort((a, b) => (a.etaS - b.etaS) || ((a.mode === 'HIGH' ? 0 : 1) - (b.mode === 'HIGH' ? 0 : 1)) || (a.lateralM - b.lateralM));
    return out;
  }

  _pendingCount(inc) { let n = 0; for (const x of inc.notified.values()) if (x.status === 'REQUESTED') n++; return n; }

  /** Riders asked in this stage who have not said no, timed out or dropped out. */
  _stageLive(inc) {
    let n = 0;
    for (const x of inc.notified.values()) if (x.stage === inc.stage && LIVE_ASK.has(x.status)) n++;
    return n;
  }

  _canSearch(inc, now) {
    if (!this.enabled || inc.closed || inc.kind !== 'ASSIST' || inc.searchStopped) return false;
    const a = this._primaryAlert(inc);
    if (!a || a.resolved || !SEARCH_STATUSES.has(statusOf(a))) return false;
    if (Object.values(a.responders || {}).some((x) => x && x.kind === 'WITH_THEM')) return false;
    if (this._activeResponders(inc).length && !inc.backupWanted) return false;
    if (inc.throttled && now < inc.createdAt + config.netAbuserDelayS * 1000) return false;
    if (inc.osrmPending) return false;
    return true;
  }

  /**
   * One search pass: pick the best candidates within the caps and ask them. Route-based candidates
   * are asked at once; fallback ones (at most one per stage) only after the road check, which runs
   * in the background and never holds anything up. Stage 1 with nobody: straight to stage 2.
   */
  _search(inc, now, depth = 0, knownOwnBest = null) {
    if (!this._canSearch(inc, now)) return;
    const ownBest = knownOwnBest !== null ? knownOwnBest : this._own(inc, now);
    const all = this._candidates(inc, now).filter((c) => c.etaS + config.netEtaMarginS < ownBest);
    // Riders of a room already asked (and not out) count against that room's cap.
    const perRoom = new Map();
    for (const n of inc.notified.values()) {
      if (!LIVE_ASK.has(n.status)) continue;
      const l = perRoom.get(n.gid) || [];
      l.push({ etaS: n.etaS });
      perRoom.set(n.gid, l);
    }
    let total = this._stageLive(inc);
    let pending = this._pendingCount(inc);
    const capTotal = inc.throttled ? Math.max(0, config.netAbuserNotify - inc.notified.size) : Infinity;
    let sent = 0;
    const lows = [];
    for (const c of all) {
      if (pending >= config.netPendingMax || total >= config.netNotifyMax || sent >= capTotal) break;
      const inRoom = perRoom.get(c.gid) || [];
      if (inRoom.length >= config.netPerGroup) continue;
      if (inRoom.length === 1 && !(c.isLead && c.etaS <= 1.5 * inRoom[0].etaS)) continue; // second per room: only the lead
      if (c.mode === 'LOW') { if (!inc.lowInStage && inRoom.length === 0) lows.push(c); continue; }
      inRoom.push(c); perRoom.set(c.gid, inRoom);
      inRoom.sort((a, b) => a.etaS - b.etaS);
      this._notify(inc, c, now);
      total++; pending++; sent++;
    }
    if (lows.length && !inc.lowInStage && pending < config.netPendingMax && total < config.netNotifyMax && sent < capTotal) {
      this._roadCheck(inc, lows.slice(0, config.netOsrmSources), ownBest);
      if (sent) this._pushUpdate(inc, { force: true });
      return;
    }
    if (sent) { this._pushUpdate(inc, { force: true }); return; }
    this._nothingFound(inc, now, depth);
  }

  _nothingFound(inc, now, depth) {
    if (this._pendingCount(inc) > 0 || this._activeResponders(inc).length) return;
    if (inc.stage === 1 && depth === 0) {
      this._escalate(inc, now);
      this._search(inc, now, 1);
      return;
    }
    if (inc.stage === 2 && !inc.stage2Done) { inc.stage2Done = true; this._pushUpdate(inc, { force: true }); }
  }

  _escalate(inc, now) {
    inc.stage = 2; inc.stageAt = now; inc.lowInStage = false;
    this._pushUpdate(inc, { force: true });
  }

  /** Background OSRM table check for fallback candidates (budgeted, never blocking). */
  _roadCheck(inc, lows, ownBest) {
    const t = Date.now();
    this.osrmTimes = this.osrmTimes.filter((x) => t - x < 60000);
    const allowed = !!this.geo && this.geo.routeEnabled && inc.osrmCalls < config.netOsrmPerIncident && this.osrmTimes.length < config.netOsrmPerMin
      && (typeof this.geo.queueWaitMs !== 'function' || this.geo.queueWaitMs() < config.netOsrmMaxWaitMs);
    const finish = (res) => {
      inc.osrmPending = false;
      if (inc.closed) return;
      const now = this.clock();
      if (!this._canSearch(inc, now)) return;
      const ok = [];
      lows.forEach((c, i) => {
        const r = res && res[i];
        if (r && Number.isFinite(r.distanceM)) {
          if (r.distanceM > c.d * config.netRoadRatioPct / 100) return; // "1.8 km away, 12 km by road"
          ok.push({ ...c, etaS: Math.max(Number(r.durationS) || 0, r.distanceM / c.v), routeDistanceM: r.distanceM });
        } else if (c.d <= config.netFallbackNoOsrmM) {
          ok.push(c); // no road answer: only very close riders heading straight at it
        }
      });
      ok.sort((a, b) => a.etaS - b.etaS);
      const pick = ok.find((c) => c.etaS + config.netEtaMarginS < ownBest && !inc.notified.has(c.uid) && this.out.online(c.uid, 'net1'));
      if (pick && this._pendingCount(inc) < config.netPendingMax && this._stageLive(inc) < config.netNotifyMax
        && (!inc.throttled || inc.notified.size < config.netAbuserNotify)) {
        inc.lowInStage = true;
        this._notify(inc, pick, now);
        this._pushUpdate(inc, { force: true });
        return;
      }
      if (!inc.notified.size || this._pendingCount(inc) === 0) this._nothingFound(inc, now, inc.stage === 1 ? 0 : 1);
    };
    if (!allowed) { finish(null); return; }
    inc.osrmCalls++;
    this.osrmTimes.push(t);
    inc.osrmPending = true;
    const timeout = config.netOsrmTimeoutMs + config.netOsrmMaxWaitMs;
    let done = false;
    const timer = setTimeout(() => { if (!done) { done = true; finish(null); } }, timeout);
    if (timer.unref) timer.unref();
    Promise.resolve()
      .then(() => this.geo.table(lows.map((c) => { const r = this.convoys.rooms.get(c.gid)?.riders.get(c.uid); return { lat: r?.lat, lng: r?.lng }; }), { lat: inc.lat, lng: inc.lng }, { timeoutMs: config.netOsrmTimeoutMs }))
      .catch(() => null)
      .then((res) => { if (done) return; done = true; clearTimeout(timer); this._guard(() => finish(res)); });
  }

  _notify(inc, c, now) {
    const room = this.convoys.rooms.get(c.gid);
    const rider = room?.riders.get(c.uid);
    if (!rider) return;
    const n = {
      at: now, gid: c.gid, status: 'REQUESTED', stage: inc.stage, etaS: c.etaS, distanceM: c.d, routeDistanceM: c.routeDistanceM,
      confidence: c.mode, aheadOnRoute: !!c.aheadOnRoute,
    };
    inc.notified.set(c.uid, n);
    this._send(c.uid, externalRequestView(inc, n));
    this._audit({ kind: 'NOTIFY', incidentId: inc.incidentId, actorId: c.uid, detail: `${c.mode} STAGE ${inc.stage}` });
    for (const x of inc.alerts) {
      const a = this._alertOf(x);
      if (a && statusOf(a) === 'CONFIRMED_ACCIDENT' && x.source !== 'NEARBY_REPORT') {
        this.convoys.setEmergencyStatus(x.gid, x.alertId, 'ASSISTANCE_REQUESTED', { by: 'SYSTEM' }).catch(() => {});
      }
    }
  }

  /** Pending (and timed out) requests are closed: someone else is responding or is with the rider. */
  _closePending(inc, reason) {
    for (const [uid, n] of inc.notified) {
      if (n.status === 'REQUESTED' || n.status === 'TIMEOUT') {
        n.status = 'CLOSED';
        this._send(uid, { type: 'ASSIST_CLOSED', incidentId: inc.incidentId, reason });
      }
    }
  }

  // ================================================================== hazards
  _level(inc) {
    const a = this._primaryAlert(inc);
    const st = a ? statusOf(a) : 'ASSISTANCE_REQUESTED';
    if (st === 'ASSISTANCE_ARRIVED' || inc.alerts.every((x) => x.source === 'NEARBY_REPORT')) return 'ON_SCENE';
    if (st === 'RESPONDER_ASSIGNED') return 'RESPONDER_ARRIVING';
    return 'ACTIVE';
  }

  _updateLevel(inc) {
    const lvl = this._level(inc);
    if (lvl === inc.level) return;
    inc.level = lvl;
    for (const [uid, h] of inc.hazardSent) this._send(uid, hazardView(inc, h));
  }

  /** Warns riders approaching the point on the same road (server picks recipients, phones count down). */
  _hazards(inc, now) {
    if (!this.enabled || inc.closed || !inc.hazards) return;
    if (inc.hazardSent.size >= config.hazardMaxRecipients) return;
    const own = new Set(inc.alerts.map((x) => x.gid));
    let count = 0;
    for (const key of this.grid.query(inc.lat, inc.lng, config.hazardAheadM)) {
      if (inc.hazardSent.size >= config.hazardMaxRecipients) break;
      const bar = key.indexOf('|');
      const gid = key.slice(0, bar), uid = key.slice(bar + 1);
      if (own.has(gid) || inc.hazardSent.has(uid)) continue;
      const room = this.convoys.rooms.get(gid);
      const rider = room?.riders.get(uid);
      if (!room || !LIVE(room) || !this._fresh(rider, now) || (Number(rider.speedKmh) || 0) < 10) continue;
      if (!this.out.online(uid, 'net1')) continue;
      let h = null;
      const on = this._onRoute(gid, room, rider);
      if (on) {
        const passes = this._passes(inc, on.idx);
        let best = null;
        for (const pe of passes) { const ahead = pe.alongM - on.p.alongM; if (ahead > 0 && (!best || ahead < best)) best = ahead; }
        if (best === null || best > config.hazardAheadM) continue;
        if (angleDiff(Number(rider.heading) || 0, on.p.segBearing) > config.netHeadingTolDeg) continue;
        h = { at: now, aheadM: best, onRoute: true };
      } else {
        const f = this._pathMatch(rider, inc.lat, inc.lng, { maxD: 5000, lateral: 200, minKmh: 10 });
        if (!f) continue;
        h = { at: now, aheadM: f.d, onRoute: false };
      }
      inc.hazardSent.set(uid, h);
      this._send(uid, hazardView(inc, h));
      count++;
    }
    if (count) this._audit({ kind: 'HAZARD', incidentId: inc.incidentId, count, detail: inc.level });
  }

  // ================================================================== subject and responders
  _subjectMoved(inc, gid, rider, t) {
    const ref = inc.alerts.find((x) => x.uid === rider.userId && x.gid === gid && x.source !== 'NEARBY_REPORT');
    if (!ref) return;
    const a = this._alertOf(ref);
    if (!a || a.resolved) return;
    a.lastUpdateAt = t;
    inc.lastUpdateAt = t;
    if (t - (inc.persistAt || 0) >= 60000) {
      inc.persistAt = t;
      this.convoys.repo.updateAlert(ref.gid, ref.alertId, { lastUpdateAt: t }).catch(() => {});
    }
    if (inc.primary !== ref) return;
    const moved = haversine(inc.lat, inc.lng, rider.lat, rider.lng);
    inc.lat = rider.lat; inc.lng = rider.lng;
    if (moved > config.netSubjectUpdateM) this._pushUpdate(inc);
    for (const R of inc.responders.values()) {
      if (!MOVING_RESPONDER.has(R.status)) continue;
      const lastAt = R.subjectSentAt || 0;
      const lastPos = R.subjectSentPos;
      if (t - lastAt >= config.netSubjectUpdateMs && (!lastPos || haversine(lastPos.lat, lastPos.lng, inc.lat, inc.lng) > config.netSubjectUpdateM)) {
        R.subjectSentAt = t; R.subjectSentPos = { lat: inc.lat, lng: inc.lng };
        this._send(R.uid, this._responderView(inc, R));
      }
    }
  }

  /** ETA of a responder to the current incident position (route when it is on their route, else straight x detour). */
  _responderEta(inc, R, rider) {
    const room = this.convoys.rooms.get(R.gid);
    const { v, penalty } = this._speedModel(rider.speedKmh);
    if (room) {
      const on = this._onRoute(R.gid, room, rider);
      if (on) {
        const m = this._routeEta(inc, on, rider, { aheadMax: Infinity, headingCheck: false });
        if (m) return { etaS: m.etaS, distanceM: haversine(rider.lat, rider.lng, inc.lat, inc.lng) };
      }
    }
    const d = haversine(rider.lat, rider.lng, inc.lat, inc.lng);
    return { etaS: d * config.netDetourPct / 100 / v + penalty, distanceM: d };
  }

  _responderMoved(inc, uid, rider, t) {
    const R = inc.responders.get(uid);
    if (!R || !MOVING_RESPONDER.has(R.status)) return;
    const e = this._responderEta(inc, R, rider);
    R.etaS = e.etaS; R.distanceM = e.distanceM; R.lat = rider.lat; R.lng = rider.lng;
    let changed = false;
    if (R.status === 'ACCEPTED' && (Number(rider.speedKmh) || 0) >= 10) { R.status = 'EN_ROUTE'; changed = true; }
    if (e.distanceM <= config.netArrivingM && R.status !== 'ARRIVING') { R.status = 'ARRIVING'; changed = true; }
    let arrivalCheck = false;
    if (e.distanceM <= config.netArriveM && !R.arrivalAsked) { R.arrivalAsked = true; arrivalCheck = true; }
    // Drift: much slower than at acceptance for 2 evaluations in a row: look for a backup (the responder stays).
    if (e.etaS > R.startEtaS * config.netDriftPct / 100 && e.etaS - R.startEtaS > config.netDriftMinS) R.driftCount++;
    else R.driftCount = 0;
    if (R.driftCount >= 2 && !inc.backupWanted) {
      inc.backupWanted = true;
      setImmediate(() => this._guard(() => this._search(inc, this.clock())));
    }
    if (changed || arrivalCheck) {
      this._send(uid, this._responderView(inc, R, { arrivalCheck }));
      if (changed) this._responderChanged(inc, R);
      return;
    }
    if (R.lastEtaPushed === undefined || Math.abs(e.etaS - R.lastEtaPushed) > 60) {
      const before = inc.lastEmergencyUpdateAt;
      this._pushUpdate(inc);
      if (inc.lastEmergencyUpdateAt !== before) R.lastEtaPushed = e.etaS;
    }
  }

  _responderView(inc, R, extra = {}) {
    const a = this._primaryAlert(inc);
    const room = this.convoys.rooms.get(inc.primary.gid);
    const subjectRider = room?.riders.get(inc.primary.uid);
    const medicalOk = !!a && !a.resolved && !!a.medical && (subjectRider ? subjectRider.responderMedical === true : inc.primary.responderMedical);
    return externalResponderView(inc, R, {
      incidentStatus: a ? statusOf(a) : 'RESOLVED',
      subject: ACTIVE_RESPONDER.has(R.status) ? { firstName: firstName(a?.userName || subjectRider?.name), vehicleType: String(subjectRider?.vehicleType || ''), vehicleColor: String(subjectRider?.vehicleColor || '') } : null,
      medical: ACTIVE_RESPONDER.has(R.status) && medicalOk ? a.medical : null,
      ...extra,
    });
  }

  /** A responder drops out (cancel, unable, ride ended): back to searching when nobody else is coming. */
  _responderOut(inc, R, status, reason) {
    R.status = status;
    if (reason) R.reason = reason;
    this.responderOf.delete(R.uid);
    const n = inc.notified.get(R.uid);
    if (n) n.status = status;
    if (!this._activeResponders(inc).length) {
      inc.backupWanted = false;
      for (const x of inc.alerts) {
        const a = this._alertOf(x);
        if (a && statusOf(a) === 'RESPONDER_ASSIGNED' && !Object.values(a.responders || {}).some((y) => y && y.kind === 'GOING')) {
          this.convoys.setEmergencyStatus(x.gid, x.alertId, 'ASSISTANCE_REQUESTED', { by: 'SYSTEM' }).catch(() => {});
        }
      }
      setImmediate(() => this._guard(() => this._search(inc, this.clock())));
    }
    this._responderChanged(inc, R);
  }

  /** ASSIST_ANSWER. Throws ConvoyError 400 / 404 INCIDENT_CLOSED / 409 TAKEN. Returns { myStatus }. */
  answer(user, { incidentId, answer } = {}) {
    const uid = user.userId;
    const inc = typeof incidentId === 'string' ? this.incidents.get(incidentId) : null;
    const n = inc && inc.notified.get(uid);
    if (!inc || !n || inc.closed) throw new ConvoyError('This emergency is closed.', 404, 'INCIDENT_CLOSED');
    const ans = typeof answer === 'string' ? answer.toUpperCase() : '';
    if (!ANSWERS.has(ans)) throw new ConvoyError('Answer with ACCEPT, DECLINE, CANCEL, UNABLE, ARRIVED or NOT_FOUND.', 400);
    const now = this.clock();
    const R = inc.responders.get(uid);
    const active = R && ACTIVE_RESPONDER.has(R.status);
    this._audit({ kind: 'ANSWER', incidentId: inc.incidentId, actorId: uid, detail: ans });
    switch (ans) {
      case 'ACCEPT': {
        if (active) return { myStatus: R.status };
        if (!['REQUESTED', 'TIMEOUT', 'DECLINED'].includes(n.status)) throw new ConvoyError('Another rider is already responding.', 409, 'TAKEN');
        const a = this._primaryAlert(inc);
        if (!a || a.resolved || statusOf(a) === 'ASSISTANCE_ARRIVED') throw new ConvoyError('Another rider is already responding.', 409, 'TAKEN');
        if (this._activeResponders(inc).length && !inc.backupWanted) throw new ConvoyError('Another rider is already responding.', 409, 'TAKEN');
        const room = this.convoys.rooms.get(n.gid);
        const rider = room?.riders.get(uid);
        const name = firstName(rider?.name || user.name);
        const Rn = {
          uid, rid: crypto.createHash('sha256').update(inc.incidentId + uid).digest('hex').slice(0, 12), name, gid: n.gid,
          status: 'ACCEPTED', etaS: n.etaS, distanceM: n.distanceM, startEtaS: n.etaS, acceptedAt: now, arrivedAt: 0, driftCount: 0,
          lat: rider?.lat, lng: rider?.lng,
        };
        if (rider) { const e = this._responderEta(inc, Rn, rider); Rn.etaS = e.etaS; Rn.distanceM = e.distanceM; Rn.startEtaS = Math.max(e.etaS, 1); }
        inc.responders.set(uid, Rn);
        n.status = 'ACCEPTED';
        this.responderOf.set(uid, inc.incidentId);
        inc.backupWanted = false;
        for (const x of inc.alerts) {
          const al = this._alertOf(x);
          const st = al && statusOf(al);
          if (al && x.source !== 'NEARBY_REPORT' && (st === 'CONFIRMED_ACCIDENT' || st === 'ASSISTANCE_REQUESTED')) {
            this.convoys.setEmergencyStatus(x.gid, x.alertId, 'RESPONDER_ASSIGNED', { by: 'SYSTEM' }).catch(() => {});
          }
        }
        this._closePending(inc, 'TAKEN');
        this._send(uid, this._responderView(inc, Rn));
        this._responderChanged(inc, Rn);
        this._updateLevel(inc);
        return { myStatus: 'ACCEPTED' };
      }
      case 'DECLINE': {
        if (active) throw new ConvoyError('You are responding. Use Unable to assist.', 409, 'RESPONDING');
        if (n.status === 'REQUESTED' || n.status === 'TIMEOUT') {
          n.status = 'DECLINED';
          setImmediate(() => this._guard(() => this._search(inc, this.clock())));
          this._pushUpdate(inc, { force: true });
        }
        return { myStatus: n.status };
      }
      case 'CANCEL':
      case 'UNABLE': {
        if (!active) {
          if (n.status === 'REQUESTED' || n.status === 'TIMEOUT') {
            n.status = 'DECLINED';
            setImmediate(() => this._guard(() => this._search(inc, this.clock())));
          }
          return { myStatus: n.status };
        }
        this._responderOut(inc, R, ans === 'CANCEL' ? 'CANCELLED' : 'UNABLE_TO_REACH');
        // The rider stopped responding: their phone drops the request, the first name and medical info.
        this._send(uid, { type: 'ASSIST_CLOSED', incidentId: inc.incidentId, reason: 'CANCELLED' });
        return { myStatus: R.status };
      }
      case 'ARRIVED': {
        if (!active) throw new ConvoyError('Accept the request first.', 409, 'NOT_RESPONDING');
        if (R.status !== 'ARRIVED') {
          R.status = 'ARRIVED'; R.arrivedAt = now;
          const n2 = inc.notified.get(uid); if (n2) n2.status = 'ARRIVED';
          for (const x of inc.alerts) {
            const al = this._alertOf(x);
            if (al && !al.resolved && statusOf(al) !== 'ASSISTANCE_ARRIVED') this.convoys.setEmergencyStatus(x.gid, x.alertId, 'ASSISTANCE_ARRIVED', { by: 'SYSTEM' }).catch(() => {});
          }
          this._closePending(inc, 'TAKEN');
          this._send(uid, this._responderView(inc, R));
          this._responderChanged(inc, R);
          this._updateLevel(inc);
        }
        return { myStatus: 'ARRIVED' };
      }
      case 'NOT_FOUND': {
        if (!active) throw new ConvoyError('Accept the request first.', 409, 'NOT_RESPONDING');
        // Someone is on scene looking: the group sees it, no new search is started.
        inc.searchStopped = true;
        R.status = 'UNABLE_TO_REACH'; R.reason = 'NOT_FOUND';
        this.responderOf.delete(uid);
        const n2 = inc.notified.get(uid); if (n2) n2.status = 'UNABLE_TO_REACH';
        this._send(uid, this._responderView(inc, R));
        this._responderChanged(inc, R);
        return { myStatus: 'UNABLE_TO_REACH' };
      }
      default:
        throw new ConvoyError('Unknown answer.', 400);
    }
  }

  /** NET_REPORT_FALSE: once per user per incident, REPORT_FALSE_PER_H per user. */
  reportFalse(user, { incidentId } = {}) {
    const uid = user.userId;
    const inc = typeof incidentId === 'string' ? this.incidents.get(incidentId) : null;
    if (!inc || inc.closed || (!inc.notified.has(uid) && !inc.hazardSent.has(uid))) throw new ConvoyError('This emergency is closed.', 404, 'INCIDENT_CLOSED');
    if (inc.falseReports.has(uid)) return { duplicate: true };
    const t = Date.now();
    const recent = (this.reportFalseLog.get(uid) || []).filter((x) => t - x < 3600000);
    if (recent.length >= config.reportFalsePerH) throw new ConvoyError('Slow down.', 429);
    recent.push(t);
    this.reportFalseLog.set(uid, recent);
    inc.falseReports.add(uid);
    this._audit({ kind: 'REPORT_FALSE', incidentId: inc.incidentId, actorId: uid, count: inc.falseReports.size, detail: 'REPORTED' });
    return { duplicate: false };
  }

  /** After a net1 JOIN: everything still open for this rider is sent again (the phone cleared its lists). */
  resend(uid) {
    for (const inc of this.incidents.values()) {
      const n = inc.notified.get(uid);
      if (n) {
        const R = inc.responders.get(uid);
        if (R && ACTIVE_RESPONDER.has(R.status)) this._send(uid, this._responderView(inc, R));
        else if (n.status === 'REQUESTED' || n.status === 'TIMEOUT' || n.status === 'DECLINED') this._send(uid, externalRequestView(inc, n));
      }
      const h = inc.hazardSent.get(uid);
      if (h) this._send(uid, hazardView(inc, h));
    }
  }

  /** Account deletion: the rider leaves every incident and the grid; their own incidents close. */
  forgetUser(userId) {
    const rs = this.riders.get(userId);
    if (rs) this.grid.remove(`${rs.gid}|${userId}`);
    this.riders.delete(userId);
    this.reportFalseLog.delete(userId);
    for (const inc of [...this.incidents.values()]) {
      const mine = inc.alerts.filter((x) => x.uid === userId);
      if (mine.length) {
        for (const x of mine) this.byAlert.delete(x.alertId);
        inc.alerts = inc.alerts.filter((x) => x.uid !== userId);
        if (!inc.alerts.length) { this._close(inc, 'RESOLVED'); continue; }
        this._pickPrimary(inc);
      }
      const R = inc.responders.get(userId);
      if (R && MOVING_RESPONDER.has(R.status)) this._responderOut(inc, R, 'CANCELLED');
      inc.responders.delete(userId);
      inc.notified.delete(userId);
      inc.hazardSent.delete(userId);
      inc.falseReports.delete(userId);
    }
    this.responderOf.delete(userId);
    this.subjects.delete(userId);
    if (this.audit) this.audit.forget(userId);
  }

  /** GET /api/admin/safety: open incidents (admins see user ids; no positions of external riders). */
  adminView() {
    return [...this.incidents.values()].map((inc) => {
      const a = this._primaryAlert(inc);
      return {
        incidentId: inc.incidentId, alertIds: inc.alerts.map((x) => x.alertId), groupIds: [...new Set(inc.alerts.map((x) => x.gid))],
        status: a ? statusOf(a) : 'RESOLVED', kind: inc.kind, stage: inc.stage, notified: inc.notified.size, hazardRecipients: inc.hazardSent.size,
        responders: [...inc.responders.values()].map((R) => ({ userId: R.uid, name: R.name, status: R.status, etaS: Number.isFinite(R.etaS) ? Math.round(R.etaS) : null })),
        createdAt: inc.createdAt,
      };
    }).sort((x, y) => y.createdAt - x.createdAt);
  }

  // ================================================================== periodic
  /** Every NET_TICK_MS: expiry, request timeouts, escalation, re-search, hazards. Nothing when idle. */
  tick(now = this.clock()) {
    if (now - this.lastPrune > 300000) this._prune(now);
    if (this.rebuild.size) this._rebuild();
    if (!this.incidents.size) return;
    for (const inc of [...this.incidents.values()]) {
      if (inc.closed) continue;
      // Expiry: no update from the subject and no status change for EMERGENCY_EXPIRE_MIN.
      for (const x of [...inc.alerts]) {
        const a = this._alertOf(x);
        if (a && !a.resolved && now - (a.lastUpdateAt || a.timestamp || 0) >= config.emergencyExpireMin * 60000) {
          this.convoys.setEmergencyStatus(x.gid, x.alertId, 'EXPIRED', { by: 'SYSTEM' }).catch(() => {});
        }
      }
      if (inc.closed) continue;
      let changed = false;
      for (const n of inc.notified.values()) {
        if (n.status === 'REQUESTED' && now - n.at >= config.netRequestTimeoutS * 1000) { n.status = 'TIMEOUT'; changed = true; }
      }
      if (inc.kind === 'ASSIST' && inc.stage === 1 && now - inc.stageAt >= config.netEscalateAfterS * 1000 && !this._activeResponders(inc).length) {
        this._escalate(inc, now);
      }
      const before = inc.ownBest;
      this._own(inc, now);
      if (inc.kind === 'ASSIST') this._search(inc, now, 0, inc.ownBest);
      const etaMoved = Number.isFinite(inc.ownBest) !== Number.isFinite(before) || (Number.isFinite(inc.ownBest) && Math.abs(before - inc.ownBest) > 60);
      if (changed || etaMoved) this._pushUpdate(inc, { force: changed });
      this._hazards(inc, now);
    }
  }

  _rebuild() {
    const gids = [...this.rebuild];
    this.rebuild.clear();
    for (const gid of gids) {
      const room = this.convoys.rooms.get(gid);
      if (!room) continue;
      for (const a of room.alerts.values()) {
        if (a.resolved || this.byAlert.has(a.alertId)) continue;
        const inc = this._raised(gid, a, null);
        if (inc) { const t = this.clock(); this._search(inc, t); this._hazards(inc, t); }
      }
    }
  }

  _prune(now) {
    this.lastPrune = now;
    // Open alerts without an incident (dropped by the incident cap) still expire.
    for (const [gid, room] of this.convoys.rooms) {
      for (const a of room.alerts.values()) {
        if (!a.resolved && !this.byAlert.has(a.alertId) && now - (a.lastUpdateAt || a.timestamp || 0) >= config.emergencyExpireMin * 60000) {
          this.convoys.setEmergencyStatus(gid, a.alertId, 'EXPIRED', { by: 'SYSTEM' }).catch(() => {});
        }
      }
    }
    for (const [uid, rs] of this.riders) {
      if (now - rs.lastFixAt > 15 * 60000) { this.grid.remove(`${rs.gid}|${uid}`); this.riders.delete(uid); }
    }
    for (const [uid, list] of this.reportFalseLog) if (!list.some((x) => now - x < 3600000)) this.reportFalseLog.delete(uid);
  }
}

function LIVE(room) { return room.meta.tripStatus === 'STARTED'; }

// ==================================================================== external views (whitelists)
/** ASSIST_REQUEST: the minimum before acceptance. Never names, ids other than incidentId, or other riders. */
function externalRequestView(inc, n) {
  const out = {
    type: 'ASSIST_REQUEST', incidentId: inc.incidentId, lat: r5(inc.lat), lng: r5(inc.lng),
    distanceM: r100(n.distanceM || 0), aheadOnRoute: !!n.aheadOnRoute, fasterThanGroup: true,
    severity: inc.severity, kind: inc.accident ? 'ACCIDENT' : 'EMERGENCY', reportedAt: inc.createdAt, lastUpdateAt: inc.lastUpdateAt,
  };
  if (Number.isFinite(n.routeDistanceM)) out.routeDistanceM = r100(n.routeDistanceM);
  if (Number.isFinite(n.etaS)) out.etaS = r30(n.etaS);
  return out;
}

/** ASSIST_UPDATE: after acceptance adds the subject's first name and vehicle, medical only with opt-in. */
function externalResponderView(inc, R, { incidentStatus, subject = null, medical = null, arrivalCheck = false } = {}) {
  const out = {
    type: 'ASSIST_UPDATE', incidentId: inc.incidentId, incidentStatus, myStatus: R.status,
    lat: r5(inc.lat), lng: r5(inc.lng), lastUpdateAt: inc.lastUpdateAt,
  };
  if (Number.isFinite(R.etaS)) out.etaS = r30(R.etaS);
  if (Number.isFinite(R.distanceM)) out.distanceM = Math.round(R.distanceM / 10) * 10;
  if (arrivalCheck) out.arrivalCheck = true;
  if (subject) out.subject = { firstName: String(subject.firstName || ''), vehicleType: String(subject.vehicleType || ''), vehicleColor: String(subject.vehicleColor || '') };
  if (medical) {
    const m = {};
    if (medical.bloodGroup) m.bloodGroup = String(medical.bloodGroup);
    if (medical.allergies) m.allergies = String(medical.allergies);
    if (medical.notes) m.notes = String(medical.notes);
    if (Object.keys(m).length) out.medical = m;
  }
  return out;
}

/** HAZARD: a point and how far ahead, no identity at all. hazardId = incidentId (for "Report false alert"). */
function hazardView(inc, h) {
  const out = { type: 'HAZARD', hazardId: inc.incidentId, lat: r5(inc.lat), lng: r5(inc.lng), level: inc.level || 'ACTIVE', onRoute: !!h.onRoute, reportedAt: inc.createdAt };
  if (Number.isFinite(h.aheadM)) out.aheadM = r100(h.aheadM);
  return out;
}

module.exports = { SafetyNetwork, externalRequestView, externalResponderView, hazardView };
