'use strict';
/**
 * TimelineEngine: turns everything that happens in a convoy into one ordered
 * group timeline (collection trip_events), shared by every member.
 *
 * Two kinds of entries:
 *   instant   JOINED, LEFT, STOP_ADDED, STATUS, STOP_PASSED, STOP_ALL_REACHED, DESTINATION_ALL_REACHED, TRIP_*
 *   interval  STOPPED, SEPARATED, OFF_ROUTE, OFFLINE, SOS, CORIDE, MOVING, STOP_REACHED, DESTINATION_REACHED (time at the place),
 *             OVERSPEED (over the group speed limit)
 *             (open while it lasts; closed with endedAt/durationMs)
 *
 * Live entries are computed from telemetry the moment they happen
 * (confidence "live"). When the trip ends, the report builder re-derives
 * stops and moving stretches from the full uploaded GPS tracks and replaces
 * the live STOPPED entries with exact ones (confidence "confirmed").
 *
 * Every entry is broadcast only to its own convoy room (TIMELINE /
 * TIMELINE_UPDATE). Reads through REST are limited to the viewer's own
 * membership window (see visibleWindow()).
 */
const crypto = require('crypto');
const config = require('./config');
const { haversine, distanceToPolyline, medianCentre, decodePolyline } = require('./geo_math');
const { buildTripReport } = require('./report');

const INTERVAL_TYPES = new Set(['STOPPED', 'SEPARATED', 'OFF_ROUTE', 'OFFLINE', 'SOS', 'CORIDE', 'MOVING', 'STOP_REACHED', 'DESTINATION_REACHED', 'OVERSPEED']);
const FRESH_MS = 2 * 60000;
const HOLD_MS = 60000; // a condition must last this long before it becomes an entry
const MAX_TS = Number.MAX_SAFE_INTEGER;

const newId = () => `EV-${crypto.randomBytes(6).toString('hex').toUpperCase()}`;

/** The period of a convoy a user may see: from their first join until they left (or forever while in it). */
function visibleWindow(meta, user) {
  if (!meta) return null;
  if (user.role === 'MASTER_ADMIN') return { from: 0, to: MAX_TS };
  const m = meta.members?.[user.userId];
  if (!m) return null;
  const from = Math.min(m.firstJoinedAt || m.joinedAt || 0, m.joinedAt || MAX_TS);
  const left = m.leftAt && m.leftAt >= (m.joinedAt || 0) ? m.leftAt : 0;
  return { from, to: left || MAX_TS };
}

function eventVisible(ev, win, userId) {
  if (ev.userId && ev.userId === userId) return true;
  const end = ev.endedAt || (ev.open ? MAX_TS : ev.startedAt);
  return ev.startedAt <= win.to && end >= win.from;
}

class TimelineEngine {
  constructor({ convoys, repo, tracks, geo = null, logger = console, tickMs = config.timelineTickMs, clock = Date.now }) {
    this.convoys = convoys; this.repo = repo; this.tracks = tracks; this.geo = geo; this.log = logger; this.now = clock;
    this.states = new Map(); // groupId -> state
    this.pending = new Set();
    this.rebuilds = new Map(); // groupId -> timer

    convoys.on('telemetry', (gid, rider) => this._guard(this.onTelemetry(gid, rider)));
    convoys.on('event', (gid, payload) => this._guard(this.onConvoyEvent(gid, payload)));
    convoys.on('activity', (gid, act) => this._guard(this.onActivity(gid, act)));

    this.timer = setInterval(() => this._guard(this.tick()), tickMs);
    if (this.timer.unref) this.timer.unref();
  }

  stop() {
    clearInterval(this.timer);
    for (const t of this.rebuilds.values()) clearTimeout(t);
    this.rebuilds.clear();
  }

  /** A phone uploaded points after the report was built: rebuild it once uploads settle. */
  scheduleRebuild(gid) {
    clearTimeout(this.rebuilds.get(gid));
    const t = setTimeout(() => { this.rebuilds.delete(gid); this._guard(this.finishTrip(gid)); }, config.reportRebuildMs);
    if (t.unref) t.unref();
    this.rebuilds.set(gid, t);
  }

  /** Waits for all in-flight work (tests, graceful shutdown). */
  async idle() { while (this.pending.size) await Promise.allSettled([...this.pending]); }

  _guard(p) {
    const tracked = Promise.resolve(p).catch((e) => this.log.warn('[timeline]', e.message)).finally(() => this.pending.delete(tracked));
    this.pending.add(tracked);
    return tracked;
  }

  // ------------------------------------------------------------- state
  async _state(gid) {
    let st = this.states.get(gid);
    if (st) { await st.ready; return st; }
    st = { open: new Map(), riders: new Map(), routeRef: null, route: null, lastSepCheck: 0, ready: null };
    st.ready = (async () => {
      const open = await this.repo.listOpenEvents(gid).catch(() => []);
      for (const ev of open) if (ev.slot) st.open.set(ev.slot, ev);
    })();
    this.states.set(gid, st);
    await st.ready;
    return st;
  }

  _rs(st, userId) {
    let r = st.riders.get(userId);
    if (!r) { r = { cluster: null, sepSince: 0, offSince: 0, visits: {}, lastFixAt: 0 }; st.riders.set(userId, r); }
    return r;
  }

  _name(gid, userId) {
    const room = this.convoys.rooms.get(gid);
    return room?.riders.get(userId)?.name || room?.meta.members?.[userId]?.name || '';
  }

  _route(st, meta) {
    const src = meta.route?.polyline || meta.routeBreadcrumbs;
    if (src !== st.routeRef) {
      st.routeRef = src;
      st.route = typeof src === 'string' ? decodePolyline(src) : (Array.isArray(src) && src.length >= 2 ? src : null);
    }
    return st.route;
  }

  // ----------------------------------------------------------- writing
  async _instant(gid, ev) {
    const t = ev.startedAt || this.now();
    return this._write(gid, { ...ev, startedAt: t, endedAt: t, durationMs: 0, open: false }, 'TIMELINE');
  }

  async _open(gid, st, slot, ev) {
    if (st.open.has(slot)) return st.open.get(slot);
    const doc = { ...ev, slot, open: true, endedAt: null, durationMs: 0 };
    st.open.set(slot, doc);
    return this._write(gid, doc, 'TIMELINE');
  }

  async _close(gid, st, slot, endedAt = this.now(), extra = {}) {
    const ev = st.open.get(slot);
    if (!ev) return null;
    st.open.delete(slot);
    ev.open = false;
    ev.endedAt = Math.max(endedAt, ev.startedAt);
    ev.durationMs = ev.endedAt - ev.startedAt;
    ev.data = { ...(ev.data || {}), ...(extra.data || {}) };
    ev.updatedAt = this.now();
    await this.repo.upsertEvent(ev).catch((e) => this.log.warn('[timeline] save failed', e.message));
    this.convoys._emit(gid, 'TIMELINE_UPDATE', { event: publicEvent(ev) });
    return ev;
  }

  async _write(gid, ev, kind) {
    const t = this.now();
    const doc = {
      eventId: ev.eventId || newId(), groupId: gid, userId: ev.userId || null, userName: ev.userName || (ev.userId ? this._name(gid, ev.userId) : ''),
      type: ev.type, startedAt: ev.startedAt, endedAt: ev.endedAt ?? null, durationMs: ev.durationMs || 0,
      lat: Number.isFinite(ev.lat) && ev.lat !== 0 ? +ev.lat.toFixed(5) : null,
      lng: Number.isFinite(ev.lng) && ev.lng !== 0 ? +ev.lng.toFixed(5) : null,
      placeName: ev.placeName || '', data: ev.data || {}, source: ev.source || 'server', confidence: ev.confidence || 'live',
      open: !!ev.open, slot: ev.slot || null, createdAt: t, updatedAt: t,
    };
    Object.assign(ev, doc);
    await this.repo.upsertEvent(doc).catch((e) => this.log.warn('[timeline] save failed', e.message));
    this.convoys._emit(gid, kind, { event: publicEvent(doc) });
    if (doc.lat !== null && !doc.placeName && this.geo) this._guard(this._enrichPlace(gid, ev));
    return ev;
  }

  async _enrichPlace(gid, ev) {
    const name = await this.geo.reverse(ev.lat, ev.lng);
    if (!name) return;
    ev.placeName = name;
    ev.updatedAt = this.now();
    await this.repo.upsertEvent(ev);
    this.convoys._emit(gid, 'TIMELINE_UPDATE', { event: publicEvent(ev) });
  }

  // ------------------------------------------------------------ inputs
  async onTelemetry(gid, rider) {
    if (!rider || !Number.isFinite(rider.lat) || (rider.lat === 0 && rider.lng === 0)) return;
    const room = this.convoys.rooms.get(gid);
    if (!room) return;
    const st = await this._state(gid);
    const rs = this._rs(st, rider.userId);
    const t = rider.lastSeenEpochMs || this.now();
    rs.lastFixAt = t;
    const who = { userId: rider.userId, userName: rider.name };

    // Back online?
    if (st.open.has(`OFFLINE:${rider.userId}`)) await this._close(gid, st, `OFFLINE:${rider.userId}`, t);

    // Stops (same rule as the report: stay inside the radius for the stop threshold).
    const minStopMs = (room.meta.stopThresholdSeconds ?? 180) * 1000;
    const p = { lat: rider.lat, lng: rider.lng, ts: t };
    const slotStop = `STOPPED:${rider.userId}`;
    const c = rs.cluster;
    if (!c) {
      rs.cluster = { first: p, last: p, sumLat: p.lat, sumLng: p.lng, n: 1 };
    } else {
      const centre = { lat: c.sumLat / c.n, lng: c.sumLng / c.n };
      const d = haversine(centre.lat, centre.lng, p.lat, p.lng);
      const stopped = st.open.has(slotStop);
      if (d <= config.stopRadiusM || (stopped && d <= config.stopExitM)) {
        c.last = p; c.sumLat += p.lat; c.sumLng += p.lng; c.n++;
        if (!stopped && c.last.ts - c.first.ts >= minStopMs) {
          const ctr = { lat: c.sumLat / c.n, lng: c.sumLng / c.n };
          await this._open(gid, st, slotStop, { ...who, type: 'STOPPED', startedAt: c.first.ts, lat: ctr.lat, lng: ctr.lng, data: { reason: rider.statusReason || '' } });
        }
      } else {
        if (stopped) await this._close(gid, st, slotStop, c.last.ts);
        rs.cluster = { first: p, last: p, sumLat: p.lat, sumLng: p.lng, n: 1 };
      }
    }

    // Planned stops and destination: every rider's arrival and departure is logged.
    const m = room.meta;
    for (const s of m.stopPoints || []) {
      if (!s.lat || s.status === 'SUGGESTED' || s.status === 'SKIPPED') continue;
      await this._visit(gid, st, rs, rider, p, t, { key: s.stopId, lat: s.lat, lng: s.lng, name: s.name, stopId: s.stopId });
    }
    if (m.destinationLat || m.destinationLng) {
      await this._visit(gid, st, rs, rider, p, t, { key: 'DEST', lat: m.destinationLat, lng: m.destinationLng, name: m.destinationName || 'the destination', stopId: null });
    }

    // Off route.
    const route = this._route(st, m);
    const slotOff = `OFF_ROUTE:${rider.userId}`;
    if (route) {
      const r = distanceToPolyline(p, route);
      const limit = m.offRouteMeters || config.offRouteM;
      if (r && r.dist > limit) {
        if (!rs.offSince) rs.offSince = t;
        if (!st.open.has(slotOff) && t - rs.offSince >= HOLD_MS) {
          await this._open(gid, st, slotOff, { ...who, type: 'OFF_ROUTE', startedAt: rs.offSince, lat: p.lat, lng: p.lng, data: { distanceM: Math.round(r.dist) } });
        }
      } else if (r && r.dist < limit * 0.7) {
        rs.offSince = 0;
        if (st.open.has(slotOff)) await this._close(gid, st, slotOff, t);
      }
    }

    // Group speed limit.
    await this._speed(gid, st, rs, rider, p, t, m.speedLimitKmh || 0);

    // Separation, at most every 5 s per convoy.
    if (t - st.lastSepCheck >= 5000) {
      st.lastSepCheck = t;
      await this._checkSeparation(gid, st, room, t);
    }
  }

  /**
   * Arrival at a planned stop or the destination. Inside the radius AND slow
   * (under 15 km/h) or inside for 30 s counts as reached; riding through
   * without slowing is logged as passed. Leaving closes the visit with its
   * duration. When every rider in the convoy has reached it, the stop is
   * marked visited for the group.
   */
  async _visit(gid, st, rs, rider, p, t, target) {
    rs.visits = rs.visits || {};
    const v = rs.visits[target.key] || (rs.visits[target.key] = { inside: false, enteredAt: 0, reached: false, done: false });
    if (v.done) return;
    const d = haversine(target.lat, target.lng, p.lat, p.lng);
    const R = config.reachRadiusM;
    const who = { userId: rider.userId, userName: rider.name };
    const dest = target.key === 'DEST';
    const slot = `VISIT:${target.key}:${rider.userId}`;
    if (d <= R) {
      if (!v.inside) { v.inside = true; v.enteredAt = t; }
      if (!v.reached && ((rider.speedKmh ?? 99) < 15 || t - v.enteredAt >= 30000)) {
        v.reached = true;
        await this._open(gid, st, slot, {
          ...who, type: dest ? 'DESTINATION_REACHED' : 'STOP_REACHED', startedAt: v.enteredAt, lat: target.lat, lng: target.lng,
          placeName: target.name, data: { stopId: target.stopId, name: target.name },
        });
        const res = await this.convoys.recordVisit(gid, target.stopId, rider, { arrivedAt: v.enteredAt }).catch(() => null);
        if (res?.allReachedNow) {
          await this._instant(gid, { type: dest ? 'DESTINATION_ALL_REACHED' : 'STOP_ALL_REACHED', startedAt: t, lat: target.lat, lng: target.lng, placeName: target.name, data: { stopId: target.stopId, name: target.name, riders: res.count } });
        }
      }
    } else if (v.inside && d > R * 1.3) {
      v.inside = false;
      if (v.reached) {
        v.done = true;
        await this._close(gid, st, slot, t);
        await this.convoys.recordVisit(gid, target.stopId, rider, { leftAt: t }).catch(() => null);
      } else {
        v.done = true;
        await this._instant(gid, { ...who, type: 'STOP_PASSED', startedAt: t, lat: target.lat, lng: target.lng, placeName: target.name, data: { stopId: target.stopId, name: target.name, destination: dest } });
        await this.convoys.recordVisit(gid, target.stopId, rider, { passedAt: t }).catch(() => null);
      }
    }
  }

  /**
   * Group speed limit. Riding above (limit + tolerance) for overspeedHoldMs
   * opens an OVERSPEED entry for that rider, so a single GPS spike never
   * counts. Riding at or under the limit for overspeedClearMs closes it with
   * its duration and top speed. Every episode is logged; only the first one
   * is announced to the group (data.notify). A repeat by the same rider
   * before overspeedRenotifyMs has passed since their last episode ended is
   * logged without a new notification.
   */
  async _speed(gid, st, rs, rider, p, t, limit) {
    const slot = `OVERSPEED:${rider.userId}`;
    const open = st.open.get(slot);
    if (!limit) {
      rs.overSince = 0; rs.underSince = 0; rs.overPeak = 0;
      if (open) await this._close(gid, st, slot, t);
      return;
    }
    const v = Math.round(Number(rider.speedKmh) || 0);
    if (v > limit + config.overspeedToleranceKmh) {
      rs.underSince = 0;
      if (open) {
        if (v > (open.data.maxKmh || 0)) open.data.maxKmh = v;
        return;
      }
      if (!rs.overSince) { rs.overSince = t; rs.overPeak = v; rs.overAt = { lat: p.lat, lng: p.lng }; return; }
      rs.overPeak = Math.max(rs.overPeak || 0, v);
      if (t - rs.overSince < config.overspeedHoldMs) return;
      rs.overCount = (rs.overCount || 0) + 1;
      const notify = !rs.overEndedAt || rs.overSince - rs.overEndedAt >= config.overspeedRenotifyMs;
      await this._open(gid, st, slot, {
        userId: rider.userId, userName: rider.name, type: 'OVERSPEED', startedAt: rs.overSince,
        lat: rs.overAt?.lat ?? p.lat, lng: rs.overAt?.lng ?? p.lng,
        data: { limitKmh: limit, maxKmh: rs.overPeak, count: rs.overCount, notify },
      });
      rs.overSince = 0;
    } else if (v <= limit) {
      rs.overSince = 0;
      if (!open) return;
      if (!rs.underSince) rs.underSince = t;
      if (t - rs.underSince >= config.overspeedClearMs) await this._endOverspeed(gid, st, rs, slot);
    }
  }

  async _endOverspeed(gid, st, rs, slot) {
    const at = rs.underSince;
    rs.underSince = 0;
    rs.overEndedAt = at;
    await this._close(gid, st, slot, at);
  }

  async _checkSeparation(gid, st, room, t) {
    const fresh = [...room.riders.values()].filter((r) => t - (r.lastSeenEpochMs || 0) <= FRESH_MS && (r.lat || r.lng));
    if (fresh.length < 2) return;
    const limit = room.meta.distanceThresholdMeters ?? 1000;
    const centre = medianCentre(fresh);
    for (const r of fresh) {
      let d;
      if (fresh.length === 2) {
        const other = fresh.find((o) => o.userId !== r.userId);
        d = haversine(r.lat, r.lng, other.lat, other.lng);
      } else {
        d = haversine(r.lat, r.lng, centre.lat, centre.lng);
      }
      const rs = this._rs(st, r.userId);
      const slot = `SEPARATED:${r.userId}`;
      if (d > limit) {
        if (!rs.sepSince) rs.sepSince = t;
        const open = st.open.get(slot);
        if (open) { open.data.maxDistanceM = Math.max(open.data.maxDistanceM || 0, Math.round(d)); continue; }
        if (t - rs.sepSince >= HOLD_MS) {
          await this._open(gid, st, slot, { userId: r.userId, userName: r.name, type: 'SEPARATED', startedAt: rs.sepSince, lat: r.lat, lng: r.lng, data: { distanceM: Math.round(d), maxDistanceM: Math.round(d), limitM: limit } });
        }
      } else if (d < limit * 0.8) {
        rs.sepSince = 0;
        if (st.open.has(slot)) await this._close(gid, st, slot, t);
      }
    }
  }

  /** Periodic: offline detection. */
  async tick() {
    const t = this.now();
    for (const [gid, room] of this.convoys.rooms) {
      if (!['STARTED', 'PAUSED'].includes(room.meta.tripStatus)) continue;
      const st = await this._state(gid);
      const limit = (room.meta.offlineAlertMinutes || config.offlineAlertMinutes) * 60000;
      for (const r of room.riders.values()) {
        const last = r.lastSeenEpochMs || 0;
        const slot = `OFFLINE:${r.userId}`;
        if (last && t - last >= limit && !st.open.has(slot)) {
          await this._open(gid, st, slot, { userId: r.userId, userName: r.name, type: 'OFFLINE', startedAt: last, lat: r.lat, lng: r.lng });
        }
        // A rider who slowed down and then parked sends few fixes: end the episode here.
        const rs = st.riders.get(r.userId);
        const over = `OVERSPEED:${r.userId}`;
        if (rs?.underSince && st.open.has(over) && t - rs.underSince >= config.overspeedClearMs) await this._endOverspeed(gid, st, rs, over);
      }
    }
  }

  async onConvoyEvent(gid, payload) {
    switch (payload.type) {
      case 'RIDER_UPDATE':
        if (payload.joined) {
          const r = payload.rider;
          await this._state(gid);
          await this._instant(gid, { userId: r.userId, userName: r.name, type: 'JOINED', lat: r.lat, lng: r.lng });
        }
        return;
      case 'RIDER_LEFT': {
        const st = await this._state(gid);
        for (const slot of [...st.open.keys()]) if (slot.endsWith(`:${payload.userId}`)) await this._close(gid, st, slot);
        st.riders.delete(payload.userId);
        await this._instant(gid, { userId: payload.userId, userName: payload.name, type: 'LEFT' });
        return;
      }
      case 'ALERT': {
        const a = payload.alert;
        const st = await this._state(gid);
        await this._open(gid, st, `SOS:${a.alertId}`, { userId: a.userId, userName: a.userName, type: 'SOS', startedAt: a.timestamp, lat: a.lat, lng: a.lng, data: { alertId: a.alertId, alertType: a.alertType } });
        return;
      }
      case 'ALERT_RESOLVED': {
        const st = await this._state(gid);
        await this._close(gid, st, `SOS:${payload.alertId}`, this.now(), { data: { resolvedBy: payload.by, resolvedByName: this._name(gid, payload.by) } });
        return;
      }
      case 'TRIP_STATUS': {
        const st = await this._state(gid);
        const map = { PAUSED: 'TRIP_PAUSED', STARTED: 'TRIP_RESUMED', ENDED: 'TRIP_ENDED', PLANNING: 'TRIP_PLANNING' };
        if (payload.tripStatus === 'ENDED') {
          for (const slot of [...st.open.keys()]) await this._close(gid, st, slot);
          await this._instant(gid, { type: 'TRIP_ENDED', data: { system: !!payload.system } });
          if (config.reportDelayMs > 0) await new Promise((r) => { const t = setTimeout(r, config.reportDelayMs); if (t.unref) t.unref(); });
          await this.finishTrip(gid);
          this.states.delete(gid);
          return;
        }
        await this._instant(gid, { type: map[payload.tripStatus] || 'TRIP_STATUS', data: { status: payload.tripStatus } });
        return;
      }
      default:
    }
  }

  async onActivity(gid, act) {
    const st = await this._state(gid);
    const who = act.user ? { userId: act.user.userId, userName: act.user.name } : {};
    switch (act.type) {
      case 'TRIP_STARTED':
        return this._instant(gid, { ...who, type: 'TRIP_STARTED', lat: act.lat, lng: act.lng, placeName: act.placeName || '', data: { name: act.name } });
      case 'STOP_ADDED':
        return this._instant(gid, { ...who, type: 'STOP_ADDED', lat: act.stop.lat, lng: act.stop.lng, placeName: act.stop.name, data: { stopId: act.stop.stopId, name: act.stop.name, category: act.stop.category, suggestedBy: act.suggestedBy || '' } });
      case 'STOP_SUGGESTED':
        return this._instant(gid, { ...who, type: 'STOP_SUGGESTED', lat: act.stop.lat, lng: act.stop.lng, placeName: act.stop.name, data: { stopId: act.stop.stopId, name: act.stop.name, category: act.stop.category } });
      case 'STOP_SKIPPED':
        return this._instant(gid, { ...who, type: 'STOP_SKIPPED', placeName: act.stop.name, data: { stopId: act.stop.stopId, name: act.stop.name } });
      case 'ROUTE_CHANGED':
        return this._instant(gid, { ...who, type: 'ROUTE_CHANGED', lat: act.place?.lat, lng: act.place?.lng, placeName: act.place?.name || '', data: { change: act.change } });
      case 'STATUS': {
        const open = st.open.get(`STOPPED:${act.user.userId}`);
        if (open && act.reason) { open.data.reason = act.reason; open.updatedAt = this.now(); await this.repo.upsertEvent(open).catch(() => {}); this.convoys._emit(gid, 'TIMELINE_UPDATE', { event: publicEvent(open) }); }
        if (!act.reason) return null;
        return this._instant(gid, { ...who, type: 'STATUS', lat: act.lat, lng: act.lng, data: { reason: act.reason, message: act.message || '' } });
      }
      case 'CORIDE': {
        const slot = `CORIDE:${act.user.userId}`;
        if (act.withUserId) return this._open(gid, st, slot, { ...who, type: 'CORIDE', startedAt: this.now(), data: { withUserId: act.withUserId, withName: this._name(gid, act.withUserId) } });
        return this._close(gid, st, slot);
      }
      default:
        return null;
    }
  }

  // ------------------------------------------------------------- report
  /** Builds the trip report from the full tracks and replaces live stops with exact ones. */
  async finishTrip(gid) {
    const meta = await this.repo.getConvoyMeta(gid);
    if (!meta) return null;
    const tracksByUser = this.tracks ? await this.tracks.load(gid) : new Map();
    // Only the points recorded while each rider was in the convoy count.
    for (const [uid, pts] of tracksByUser) {
      const m = meta.members?.[uid];
      if (!m) { tracksByUser.delete(uid); continue; }
      const from = (m.firstJoinedAt || m.joinedAt || 0) - 60000;
      const to = (m.leftAt && m.leftAt >= (m.joinedAt || 0) ? m.leftAt : (meta.endedAtEpochMs || this.now())) + 60000;
      tracksByUser.set(uid, pts.filter((p) => p.ts >= from && p.ts <= to));
    }
    const events = await this.repo.listEvents(gid, { limit: 20000 });
    const { report, perMember } = buildTripReport({ meta, tracksByUser, events });

    for (const pm of perMember) {
      if (!pm.analysis || pm.analysis.points.length < 2) continue; // no uploaded track (older app): keep live entries
      const live = events.filter((e) => e.userId === pm.userId && (e.type === 'STOPPED' || e.type === 'MOVING'));
      for (const e of live) await this.repo.removeEvent(e.eventId).catch(() => {});
      const reasonAt = (s) => live.find((e) => e.type === 'STOPPED' && e.startedAt <= s.endTs && (e.endedAt || s.endTs) >= s.startTs)?.data?.reason || '';
      for (const s of pm.analysis.stops) {
        await this._write(gid, {
          userId: pm.userId, userName: pm.name, type: 'STOPPED', startedAt: s.startTs, endedAt: s.endTs, durationMs: s.durationMs,
          lat: s.lat, lng: s.lng, confidence: 'confirmed', data: { reason: reasonAt(s), open: !!s.open },
        }, 'TIMELINE_UPDATE');
      }
      for (const g of pm.analysis.segments) {
        await this._write(gid, {
          userId: pm.userId, userName: pm.name, type: 'MOVING', startedAt: g.startTs, endedAt: g.endTs, durationMs: g.durationMs,
          confidence: 'confirmed', data: { distanceM: Math.round(g.distanceM), avgKmh: +g.avgKmh.toFixed(1), maxKmh: g.maxKmh },
        }, 'TIMELINE_UPDATE');
      }
    }

    const fresh = await this.repo.getConvoyMeta(gid);
    await this.repo.saveConvoyMeta({ ...fresh, report });
    for (const pm of perMember) {
      if (await this.repo.findUserById(pm.userId)) await this.repo.saveTrip(pm.tripDoc); // never resurrect a deleted account
    }
    this.convoys._emit(gid, 'REPORT_READY', { groupId: gid });
    return report;
  }
}

function publicEvent(ev) {
  const { slot, key, ...rest } = ev;
  return rest;
}

module.exports = { TimelineEngine, visibleWindow, eventVisible, publicEvent, INTERVAL_TYPES };
