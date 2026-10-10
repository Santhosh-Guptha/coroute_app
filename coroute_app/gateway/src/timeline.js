'use strict';
/**
 * TimelineEngine: turns everything that happens in a convoy into one ordered
 * group timeline (collection trip_events), shared by every member.
 *
 * Two kinds of entries:
 *   instant   JOINED, LEFT, STOP_ADDED, STATUS, STOP_PASSED, STOP_ALL_REACHED, DESTINATION_ALL_REACHED, TRIP_*,
 *             SOS_RESPONSE (a rider going to / with an SOS rider), CHECK_IN (rider said they are OK)
 *   interval  STOPPED, SEPARATED, OFF_ROUTE, OFFLINE, SOS, CORIDE, MOVING, STOP_REACHED, DESTINATION_REACHED (time at the place),
 *             OVERSPEED (over the group speed limit), POSSIBLE_INCIDENT (hard stop, then still), NO_REPLY (solo check-in)
 *             (open while it lasts; closed with endedAt/durationMs)
 *   3.16      instant ROLE_CHANGED (sweeper set or removed), FOLLOW_UP (still okay after a crash alarm);
 *             interval STALE_UPDATE (a moving rider stopped sending fixes), LOW_BATTERY (15% and not charging),
 *             BEHIND_SWEEPER (a rider fell behind the sweeper on the route)
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
const { haversine, distanceToPolyline, alongRoute, medianCentre, decodePolyline } = require('./geo_math');
const { buildTripReport } = require('./report');
const { scrub, mentions } = require('./anonymise');
const { ConvoyError, sourceOf } = require('./convoys');

const INTERVAL_TYPES = new Set(['STOPPED', 'SEPARATED', 'OFF_ROUTE', 'OFFLINE', 'SOS', 'CORIDE', 'MOVING', 'STOP_REACHED', 'DESTINATION_REACHED', 'OVERSPEED', 'POSSIBLE_INCIDENT', 'NO_REPLY',
  'STALE_UPDATE', 'LOW_BATTERY', 'BEHIND_SWEEPER', 'CONVOY_SPLIT', 'REGROUP', 'SWEEPER_DISTRESS']);
/** Stale rule: gaps longer than this are dead zones, not the rider's rhythm; ring of the last GAP_RING gaps. */
const GAP_MAX_S = 300;
const GAP_RING = 10;
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
    convoys.on('presence', (gid, p) => this._guard(this.onPresence(gid, p)));

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

  /**
   * Account deletion: drops the rider's in-memory state, so nothing is written for them later.
   * Open entries are written again when they close: the rider's own (an open SOS, a stop) are
   * dropped, and other riders' entries that name them (a co-ride with them) are anonymised
   * with the same `id` the database erase uses.
   */
  forgetUser(userId, id = null) {
    for (const st of this.states.values()) {
      st.riders.delete(userId);
      for (const [slot, ev] of [...st.open.entries()]) {
        if (slot.endsWith(`:${userId}`) || ev.userId === userId) st.open.delete(slot);
        else if (id && mentions(ev, id)) st.open.set(slot, scrub(ev, id));
      }
    }
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
    st = { open: new Map(), riders: new Map(), routeRef: null, route: null, lastSepCheck: 0, ready: null, isSplit: false, splitSince: 0, splitPacks: null };
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
    if (!r) { r = { cluster: null, sepSince: 0, offSince: 0, visits: {}, lastFixAt: 0, gaps: [], behindSince: 0, segIndex: null, distressSince: 0 }; st.riders.set(userId, r); }
    return r;
  }

  _name(gid, userId) {
    const room = this.convoys.rooms.get(gid);
    return room?.riders.get(userId)?.name || room?.meta.members?.[userId]?.name || '';
  }

  _route(st, meta) {
    const src = (Array.isArray(meta.route?.waypoints) && meta.route.waypoints.length >= 2)
      ? meta.route.waypoints
      : (meta.route?.polyline || meta.routeBreadcrumbs);
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

  /** Place name for a point, or '' (never holds the report up for long). */
  async _placeName(lat, lng) {
    const timeout = new Promise((r) => { const t = setTimeout(() => r(null), config.geoReverseTimeoutMs); if (t.unref) t.unref(); });
    return (await Promise.race([this.geo.reverse(lat, lng).catch(() => null), timeout])) || '';
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
    // 3.16 stale rule: the rider's own rhythm (last GAP_RING intervals between fixes, dead zones excluded).
    if (rs.lastFixAt > 0 && t > rs.lastFixAt) {
      const gapS = (t - rs.lastFixAt) / 1000;
      if (gapS <= GAP_MAX_S) { rs.gaps.push(gapS); if (rs.gaps.length > GAP_RING) rs.gaps.shift(); }
    }
    rs.lastFixAt = t;
    const who = { userId: rider.userId, userName: rider.name };

    // Back online?
    if (st.open.has(`OFFLINE:${rider.userId}`)) await this._close(gid, st, `OFFLINE:${rider.userId}`, t);
    // 3.16: updates resumed.
    if (st.open.has(`STALE:${rider.userId}`)) await this._close(gid, st, `STALE:${rider.userId}`, t, { data: { result: 'RESUMED' } });
    // 3.16: low battery (the phone reports its level with every fix).
    await this._battery(gid, st, room, rider, t);

    // Possible incident (hard stop, then still): server side, so riders on older apps get it too.
    await this._incident(gid, st, rs, room, rider, t);

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

    // Group speed limit, lowered near stops and in towns (3.16) when the lead set a town limit.
    await this._speed(gid, st, rs, rider, p, t, m.speedLimitKmh || 0, this._activeLimit(m, p));

    // Separation and the sweeper rules, at most every 5 s per convoy, or on same-timestamp batches.
    if (t - st.lastSepCheck >= 5000 || t === st.lastSepCheck) {
      st.lastSepCheck = t;
      await this._checkSubClusters(gid, st, room, t);
      await this._checkSeparation(gid, st, room, t);
      await this._checkSweeper(gid, st, room, t);
      await this._checkSweeperDistress(gid, st, room, t);
      await this._checkRegroupConvergence(gid, st, room, t);
    }
  }

  /**
   * 3.16 speed by context: { limit, context } for a fix. Within TOWN_RADIUS_M of the start, the
   * destination or a planned stop the town limit applies (the lower of the two when both are set).
   * One distance per place per fix, at most about 22 places.
   */
  _activeLimit(m, p) {
    const group = m.speedLimitKmh || 0;
    const town = m.townLimitKmh || 0;
    if (!town) return { limit: group, context: 'GROUP' };
    const R = config.townRadiusM;
    const near = (lat, lng) => (lat || lng) && haversine(lat, lng, p.lat, p.lng) <= R;
    let inTown = (m.start && near(m.start.lat, m.start.lng)) || near(m.destinationLat || 0, m.destinationLng || 0);
    if (!inTown) {
      for (const s of m.stopPoints || []) {
        if (!s.lat || s.status === 'SUGGESTED' || s.status === 'SKIPPED') continue;
        if (near(s.lat, s.lng)) { inTown = true; break; }
      }
    }
    if (!inTown) return { limit: group, context: 'GROUP' };
    return { limit: group > 0 ? Math.min(group, town) : town, context: 'TOWN' };
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
  async _speed(gid, st, rs, rider, p, t, groupLimit, active = null) {
    const limit = active ? active.limit : groupLimit;
    const context = active ? active.context : 'GROUP';
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
        data: { limitKmh: limit, maxKmh: rs.overPeak, count: rs.overCount, notify, context },
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

  /** Periodic: offline detection, stale riders (3.16). */
  async tick() {
    const t = this.now();
    for (const [gid, room] of this.convoys.rooms) {
      if (!['STARTED', 'PAUSED'].includes(room.meta.tripStatus)) continue;
      const st = await this._state(gid);
      const limit = (room.meta.offlineAlertMinutes || config.offlineAlertMinutes) * 60000;
      const typical = this._typicalGap(st);
      const staleS = Math.max(config.staleMinS, config.staleFactor * typical);
      for (const r of room.riders.values()) {
        const last = r.lastSeenEpochMs || 0;
        const slot = `OFFLINE:${r.userId}`;
        if (last && t - last >= limit && !st.open.has(slot)) {
          await this._open(gid, st, slot, { userId: r.userId, userName: r.name, type: 'OFFLINE', startedAt: last, lat: r.lat, lng: r.lng, data: { cause: 'NO_SIGNAL' } });
        }
        await this._stale(gid, st, room, r, t, { typical, staleS });
        await this._escalateOffline(gid, st, room, r, t);
        const rsi = st.riders.get(r.userId);
        if (rsi?.hardStop) await this._maybeOpenIncident(gid, st, rsi, room, r, t);
        // A rider who slowed down and then parked sends few fixes: end the episode here.
        const rs = st.riders.get(r.userId);
        const over = `OVERSPEED:${r.userId}`;
        if (rs?.underSince && st.open.has(over) && t - rs.underSince >= config.overspeedClearMs) await this._endOverspeed(gid, st, rs, over);
      }
      await this._checkSweeperDistress(gid, st, room, t);
      await this._checkRegroupConvergence(gid, st, room, t);
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
        const data = { alertId: a.alertId, alertType: a.alertType, auto: !!a.auto, responders: [], source: sourceOf(a) };
        if (a.reportedBy) { data.reportedBy = a.reportedBy; data.reportedByName = a.reportedByName || this._name(gid, a.reportedBy); }
        if (a.details && Number.isFinite(a.details.speedBeforeKmh)) data.speedBeforeKmh = a.details.speedBeforeKmh;
        await this._open(gid, st, `SOS:${a.alertId}`, { userId: a.userId, userName: a.userName, type: 'SOS', startedAt: a.timestamp, lat: a.lat, lng: a.lng, data });
        // An SOS replaces a possible incident of the same rider.
        await this._close(gid, st, `INCIDENT:${a.userId}`, this.now(), { data: { result: 'SOS' } });
        return;
      }
      case 'ALERT_RESOLVED': {
        const st = await this._state(gid);
        await this._close(gid, st, `SOS:${payload.alertId}`, this.now(), {
          data: { resolvedBy: payload.by, resolvedByName: this._name(gid, payload.by), ...(payload.status ? { status: payload.status } : {}) },
        });
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
      case 'SOS_RESPONSE': {
        const a = act.alert;
        await this._instant(gid, {
          ...who, type: 'SOS_RESPONSE', startedAt: act.at,
          data: { alertId: a.alertId, kind: act.kind, forUserId: a.userId, forUserName: a.userName || this._name(gid, a.userId) },
        });
        const open = st.open.get(`SOS:${a.alertId}`);
        if (open) {
          open.data = { ...(open.data || {}), responders: act.responders };
          open.updatedAt = this.now();
          await this.repo.upsertEvent(open).catch((e) => this.log.warn('[timeline] save failed', e.message));
          this.convoys._emit(gid, 'TIMELINE_UPDATE', { event: publicEvent(open) });
        }
        return null;
      }
      // 3.15: the emergency's status and the nearby responder (first name, status, ETA) on the open SOS entry.
      case 'EMERGENCY_STATUS':
      case 'EMERGENCY_NETWORK': {
        const open = act.alert && st.open.get(`SOS:${act.alert.alertId}`);
        if (!open) return null;
        const data = { ...(open.data || {}), status: act.alert.status || open.data?.status };
        if (act.type === 'EMERGENCY_NETWORK' && act.network) data.network = { name: String(act.network.name || ''), status: act.network.status, etaS: act.network.etaS ?? null };
        open.data = data;
        await this._update(gid, open);
        return null;
      }
      case 'ROLE_CHANGED':
        return this._instant(gid, { ...who, type: 'ROLE_CHANGED', data: { role: act.role, byUserId: act.byUserId || '' } });
      case 'REGROUP_INITIATED': {
        const rg = act.regroup;
        await this._open(gid, st, 'REGROUP', {
          ...who,
          type: 'REGROUP_INITIATED',
          startedAt: rg?.createdAt || this.now(),
          lat: act.lat,
          lng: act.lng,
          placeName: act.placeName || '',
          data: {
            regroupId: rg?.regroupId,
            suggestedByUserId: rg?.suggestedByUserId,
            targetAction: rg?.targetAction,
            targetKmh: rg?.targetKmh,
          },
        });
        return null;
      }
      case 'REGROUP_COMPLETED': {
        if (st.open.has('REGROUP')) {
          await this._close(gid, st, 'REGROUP', act.completedAt || this.now(), {
            data: { reason: act.reason || 'COMPLETED' },
          });
        }
        await this._instant(gid, {
          ...who,
          type: 'REGROUP_COMPLETED',
          startedAt: act.completedAt || this.now(),
          lat: act.lat,
          lng: act.lng,
          placeName: act.placeName || '',
          data: { reason: act.reason || 'COMPLETED' },
        });
        return null;
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

  // ------------------------------------------------------- safety (3.14)
  /** Saves an open entry's changed data and pushes it to the room. */
  async _update(gid, ev) {
    ev.updatedAt = this.now();
    await this.repo.upsertEvent(ev).catch((e) => this.log.warn('[timeline] save failed', e.message));
    this.convoys._emit(gid, 'TIMELINE_UPDATE', { event: publicEvent(ev) });
  }

  /** True when the point is within INCIDENT_STOP_NEAR_M of a planned stop or the destination. */
  _nearPlannedStop(meta, lat, lng) {
    const R = config.incidentStopNearM;
    for (const s of meta.stopPoints || []) {
      if (!s.lat || s.status === 'SUGGESTED' || s.status === 'SKIPPED') continue;
      if (haversine(s.lat, s.lng, lat, lng) <= R) return true;
    }
    if ((meta.destinationLat || meta.destinationLng) && haversine(meta.destinationLat, meta.destinationLng, lat, lng) <= R) return true;
    return false;
  }

  /**
   * C3 possible incident: from INCIDENT_FROM_KMH or more to INCIDENT_STOP_KMH or less within
   * INCIDENT_STOP_WITHIN_S marks a hard stop; still (slow, inside INCIDENT_STILL_RADIUS_M) for
   * INCIDENT_STILL_S opens POSSIBLE_INCIDENT for the lead(s) and the nearest riders. Moving on closes it.
   */
  async _incident(gid, st, rs, room, rider, t) {
    const speed = Number(rider.speedKmh) || 0;
    const slot = `INCIDENT:${rider.userId}`;
    const open = st.open.get(slot);
    if (open && (speed >= 15 || (Number.isFinite(open.lat) && open.lat !== null && haversine(open.lat, open.lng, rider.lat, rider.lng) > 100))) {
      await this._close(gid, st, slot, t, { data: { result: 'MOVED' } });
    }
    if (rs.hardStop && (speed > config.incidentStopKmh || haversine(rs.hardStop.lat, rs.hardStop.lng, rider.lat, rider.lng) > config.incidentStillRadiusM)) {
      rs.hardStop = null;
    }
    if (speed >= config.incidentFromKmh) {
      rs.fastAt = t; rs.fastKmh = speed;
    } else if (speed <= config.incidentStopKmh && !rs.hardStop && rs.fastAt && t - rs.fastAt <= config.incidentStopWithinS * 1000) {
      rs.hardStop = { at: t, lat: rider.lat, lng: rider.lng, fromKmh: Math.round(rs.fastKmh || 0), opened: false };
      rs.fastAt = 0;
    }
    if (rs.hardStop) await this._maybeOpenIncident(gid, st, rs, room, rider, t);
  }

  async _maybeOpenIncident(gid, st, rs, room, rider, t) {
    const hs = rs.hardStop;
    if (!hs || hs.opened || t - hs.at < config.incidentStillS * 1000) return;
    if (room.meta.tripStatus !== 'STARTED') return;
    // The group stopped together (red light, toll queue, jam): every rider made the same hard stop.
    // Wait longer before paging the lead; riders who stopped beside a fallen rider are already there.
    if (t - hs.at < config.incidentStillGroupS * 1000 && this._stoppedWithOthers(room, rider.userId, hs, t)) return;
    const slot = `INCIDENT:${rider.userId}`;
    if (st.open.has(slot)) { hs.opened = true; return; }
    const current = room.riders.get(rider.userId) || rider;
    if (current.statusReason) return; // the rider said why they stopped
    if ([...room.alerts.values()].some((a) => !a.resolved && a.userId === rider.userId)) return;
    if (this._nearPlannedStop(room.meta, hs.lat, hs.lng)) { hs.opened = true; return; }
    hs.opened = true;
    await this._open(gid, st, slot, {
      userId: rider.userId, userName: rider.name, type: 'POSSIBLE_INCIDENT', startedAt: hs.at, lat: hs.lat, lng: hs.lng,
      data: { fromKmh: hs.fromKmh, reason: 'HARD_STOP', notify: this._incidentNotify(room, rider.userId, hs, t), auto: true },
    });
  }

  /** True when another rider seen in the last 2 min is slow (15 km/h or less) within INCIDENT_GROUP_NEAR_M of the stop. */
  _stoppedWithOthers(room, subjectId, at, t) {
    for (const r of room.riders.values()) {
      if (r.userId === subjectId || !(r.lat || r.lng) || t - (r.lastSeenEpochMs || 0) > FRESH_MS) continue;
      if ((Number(r.speedKmh) || 0) > 15) continue;
      if (haversine(at.lat, at.lng, r.lat, r.lng) <= config.incidentGroupNearM) return true;
    }
    return false;
  }

  /** Lead(s) and sweeper(s), plus the INCIDENT_NEAREST nearest other riders seen in the last 2 minutes. */
  _incidentNotify(room, subjectId, at, t) {
    const notify = [];
    const subject = room.riders.get(subjectId);
    const isSweeperDistress = subject?.role === 'SWEEPER';

    for (const r of room.riders.values()) {
      if (r.userId === subjectId) continue;
      if (r.role === 'LEAD' || room.meta.createdByUserId === r.userId) {
        notify.push(r.userId);
      } else if (!isSweeperDistress && r.role === 'SWEEPER') {
        notify.push(r.userId);
      }
    }
    // Reverse-escalation: sweeper distress is routed only to Lead(s) to avoid moving pack panic
    if (isSweeperDistress) {
      return notify;
    }
    const near = [...room.riders.values()]
      .filter((r) => r.userId !== subjectId && !notify.includes(r.userId) && t - (r.lastSeenEpochMs || 0) <= FRESH_MS && (r.lat || r.lng))
      .map((r) => ({ id: r.userId, d: haversine(at.lat, at.lng, r.lat, r.lng) }))
      .sort((a, b) => a.d - b.d)
      .slice(0, Math.max(0, config.incidentNearest));
    for (const n of near) notify.push(n.id);
    return notify;
  }

  /**
   * B3: offline for NO_SIGNAL_ESCALATE_MIN after riding at NO_SIGNAL_MIN_KMH or more, away from
   * planned stops and not a clean app close: marked escalated (the lead is alerted by the apps).
   */
  async _escalateOffline(gid, st, room, r, t) {
    const ev = st.open.get(`OFFLINE:${r.userId}`);
    if (!ev || ev.data?.escalated || ev.data?.cause === 'APP_CLOSED') return;
    if (t - ev.startedAt < config.noSignalEscalateMin * 60000) return;
    const kmh = Number(r.speedKmh) || 0;
    if (kmh < config.noSignalMinKmh) return;
    if ((r.lat || r.lng) && this._nearPlannedStop(room.meta, r.lat, r.lng)) return;
    ev.data = { ...(ev.data || {}), escalated: true, lastKmh: Math.round(kmh) };
    await this._update(gid, ev);
  }

  /** Presence (BYE, socket close): a clean app close opens OFFLINE at once (no 5 min wait). */
  async onPresence(gid, p) {
    if (p.presence !== 'APP_CLOSED') return;
    const room = this.convoys.rooms.get(gid);
    if (!room || !['STARTED', 'PAUSED'].includes(room.meta.tripStatus)) return;
    const st = await this._state(gid);
    const r = p.rider || room.riders.get(p.userId);
    if (!r) return;
    const slot = `OFFLINE:${p.userId}`;
    const open = st.open.get(slot);
    if (st.open.has(`STALE:${p.userId}`)) await this._close(gid, st, `STALE:${p.userId}`, this.now(), { data: { result: 'APP_CLOSED' } });
    if (open) {
      if (open.data?.cause !== 'APP_CLOSED') { open.data = { ...(open.data || {}), cause: 'APP_CLOSED' }; await this._update(gid, open); }
      return;
    }
    await this._open(gid, st, slot, {
      userId: r.userId, userName: r.name, type: 'OFFLINE', startedAt: r.lastSeenEpochMs || this.now(), lat: r.lat, lng: r.lng, data: { cause: 'APP_CLOSED' },
    });
  }

  /** JOIN with prevExit KILLED: Android closed the app; the open OFFLINE entry says so. */
  async markKilled(gid, userId, downFrom) {
    const st = await this._state(gid);
    const ev = st.open.get(`OFFLINE:${userId}`);
    if (!ev) return false;
    ev.data = { ...(ev.data || {}), cause: 'KILLED', ...(downFrom ? { downFrom } : {}) };
    await this._update(gid, ev);
    return true;
  }

  /**
   * CHECK_IN from the solo check-in. NO_REPLY opens NO_REPLY:<uid> (once while open).
   * OK closes the rider's possible incident and no-reply entries and logs CHECK_IN when it closed one.
   */
  async checkIn(gid, user, msg = {}) {
    const room = await this.convoys.getRoom(gid);
    const rider = room.riders.get(user.userId);
    if (!rider) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const result = msg.result;
    if (result !== 'OK' && result !== 'NO_REPLY') throw new ConvoyError('Check-in result must be OK or NO_REPLY.', 400);
    const followUp = msg.context === 'FOLLOW_UP';
    // 3.16: the follow-up after a crash alarm only says "still okay"; it never opens or closes anything.
    if (followUp && result !== 'OK') throw new ConvoyError('A follow-up check-in can only be OK.', 400, 'BAD_RESULT');
    const st = await this._state(gid);
    const t = this.now();
    const num = (v) => (v === null || v === undefined || typeof v === 'boolean' || v === '' ? NaN : Number(v));
    const lat = Number.isFinite(num(msg.lat)) ? Math.max(-90, Math.min(90, num(msg.lat))) : rider.lat;
    const lng = Number.isFinite(num(msg.lng)) ? Math.max(-180, Math.min(180, num(msg.lng))) : rider.lng;
    if (followUp) {
      await this._instant(gid, { userId: user.userId, userName: rider.name, type: 'FOLLOW_UP', startedAt: t, lat, lng, data: { result: 'OK' } });
      return { followUp: true };
    }
    if (result === 'NO_REPLY') {
      const awayM = Number.isFinite(num(msg.awayM)) ? Math.round(Math.max(0, Math.min(500000, num(msg.awayM)))) : 0;
      await this._open(gid, st, `NO_REPLY:${user.userId}`, { userId: user.userId, userName: rider.name, type: 'NO_REPLY', startedAt: t, lat, lng, data: { awayM } });
      return { opened: true };
    }
    const rs = st.riders.get(user.userId);
    if (rs) rs.hardStop = null;
    let closed = 0;
    for (const slot of [`INCIDENT:${user.userId}`, `NO_REPLY:${user.userId}`]) {
      if (await this._close(gid, st, slot, t, { data: { result: 'OK' } })) closed++;
    }
    if (closed) await this._instant(gid, { userId: user.userId, userName: rider.name, type: 'CHECK_IN', startedAt: t, lat, lng, data: { result: 'OK' } });
    return { closed };
  }

  // ------------------------------------------------------- safety (3.16)
  /** Riders to tell about a rider's trouble: the lead(s) and the sweeper (never the rider). */
  _leadsAndSweeper(room, subjectId) {
    const out = [];
    for (const r of room.riders.values()) {
      if (r.userId === subjectId) continue;
      if (r.role === 'LEAD' || room.meta.createdByUserId === r.userId) out.push(r.userId);
    }
    for (const r of room.riders.values()) if (r.userId !== subjectId && r.role === 'SWEEPER' && !out.includes(r.userId)) out.push(r.userId);
    return out;
  }

  /** The group's typical gap between fixes (s): median of each rider's median gap (riders with 3 gaps or more), default 20. */
  _typicalGap(st) {
    const meds = [];
    for (const rs of st.riders.values()) {
      if (!rs.gaps || rs.gaps.length < 3) continue;
      meds.push(median(rs.gaps));
    }
    return meds.length ? median(meds) : 20;
  }

  /**
   * Stale rider (item 10): riding (last speed 1 km/h or more, parked phones heartbeat slowly on
   * purpose), online as far as presence knows, no OFFLINE entry yet, and no fix for longer than
   * max(STALE_MIN_S, STALE_FACTOR x the group's typical gap). Closed by the next fix (RESUMED),
   * replaced when OFFLINE opens (OFFLINE), on leave and at trip end.
   */
  async _stale(gid, st, room, r, t, { typical, staleS }) {
    const slot = `STALE:${r.userId}`;
    const open = st.open.get(slot);
    if (st.open.has(`OFFLINE:${r.userId}`) || r.presence === 'APP_CLOSED') {
      if (open) await this._close(gid, st, slot, t, { data: { result: st.open.has(`OFFLINE:${r.userId}`) ? 'OFFLINE' : 'APP_CLOSED' } });
      return;
    }
    if (open) return;
    const last = r.lastSeenEpochMs || 0;
    if (!last || !(r.lat || r.lng) || (Number(r.speedKmh) || 0) < 1) return;
    const gapS = (t - last) / 1000;
    if (gapS < staleS) return;
    await this._open(gid, st, slot, {
      userId: r.userId, userName: r.name, type: 'STALE_UPDATE', startedAt: last, lat: r.lat, lng: r.lng,
      data: { gapS: Math.round(gapS), typicalS: Math.round(typical), notify: this._leadsAndSweeper(room, r.userId) },
    });
  }

  /**
   * Low battery (item 12): at or under BATTERY_LOW_PCT and not charging opens LOW_BATTERY:<uid> for
   * the lead and sweeper; the level is updated only when it drops by 5 or more; charging or
   * BATTERY_OK_PCT closes it (CHARGING / RECOVERED), as do leave and trip end.
   */
  async _battery(gid, st, room, rider, t) {
    const level = Number(rider.batteryLevel);
    if (!Number.isFinite(level)) return;
    const charging = rider.isCharging === true;
    const slot = `BATTERY:${rider.userId}`;
    const open = st.open.get(slot);
    if (open) {
      if (charging) return this._close(gid, st, slot, t, { data: { result: 'CHARGING' } });
      if (level >= config.batteryOkPct) return this._close(gid, st, slot, t, { data: { result: 'RECOVERED' } });
      if ((open.data.level ?? 100) - level >= 5) { open.data = { ...open.data, level: Math.round(level) }; await this._update(gid, open); }
      return null;
    }
    if (level > config.batteryLowPct || charging) return null;
    return this._open(gid, st, slot, {
      userId: rider.userId, userName: rider.name, type: 'LOW_BATTERY', startedAt: t, lat: rider.lat, lng: rider.lng,
      data: { level: Math.round(level), notify: this._leadsAndSweeper(room, rider.userId) },
    });
  }

  /**
   * Sweeper rule (item 11), every 5 s with the separation check: with a fresh, positioned sweeper,
   * every other fresh rider further than SWEEPER_BEHIND_M behind them (along the route when both
   * project on it within 300 m; by distance to the destination without a route) for HOLD_MS opens
   * BEHIND:<uid> for the sweeper and the lead. Closed under 100 m behind, and all at once when the
   * sweeper changes or leaves.
   */
  async _checkSweeper(gid, st, room, t) {
    const fresh = (r) => t - (r.lastSeenEpochMs || 0) <= FRESH_MS && (r.lat || r.lng);
    const sweeper = [...room.riders.values()].find((r) => r.role === 'SWEEPER');
    const sid = sweeper ? sweeper.userId : null;
    if (st.sweeperId !== sid) {
      st.sweeperId = sid;
      for (const slot of [...st.open.keys()]) if (slot.startsWith('BEHIND:')) await this._close(gid, st, slot, t, { data: { result: 'SWEEPER_CHANGED' } });
      for (const rs of st.riders.values()) rs.behindSince = 0;
    }
    if (!sweeper || !fresh(sweeper)) return;
    const m = room.meta;
    const route = this._route(st, m);
    const dest = (m.destinationLat || m.destinationLng) ? { lat: m.destinationLat, lng: m.destinationLng } : null;
    if (!route && !dest) return;
    const srs = this._rs(st, sid);
    let sAlong = null;
    if (route) {
      const on = alongRoute({ lat: sweeper.lat, lng: sweeper.lng }, route, { fromIndex: srs.segIndex });
      if (on) { sAlong = on.alongM; srs.segIndex = on.segIndex; }
    }
    for (const r of room.riders.values()) {
      if (r.userId === sid || !fresh(r)) continue;
      const rs = this._rs(st, r.userId);
      let behindM = null;
      if (route && sAlong !== null) {
        const on = alongRoute({ lat: r.lat, lng: r.lng }, route, { fromIndex: rs.segIndex });
        if (on) { rs.segIndex = on.segIndex; behindM = sAlong - on.alongM; }
      } else if (!route && dest) {
        behindM = haversine(r.lat, r.lng, dest.lat, dest.lng) - haversine(sweeper.lat, sweeper.lng, dest.lat, dest.lng);
      }
      if (behindM === null) continue;
      const slot = `BEHIND:${r.userId}`;
      const open = st.open.get(slot);
      if (behindM > config.sweeperBehindM) {
        if (!rs.behindSince) rs.behindSince = t;
        if (open) {
          if (Math.round(behindM) > (open.data.maxDistanceM || 0)) open.data.maxDistanceM = Math.round(behindM);
          continue;
        }
        if (t - rs.behindSince >= HOLD_MS) {
          await this._open(gid, st, slot, {
            userId: r.userId, userName: r.name, type: 'BEHIND_SWEEPER', startedAt: rs.behindSince, lat: r.lat, lng: r.lng,
            data: { distanceM: Math.round(behindM), maxDistanceM: Math.round(behindM), sweeperId: sid, sweeperName: sweeper.name || '', notify: [sid, ...this._leadsAndSweeper(room, r.userId).filter((x) => x !== sid)] },
          });
        }
      } else if (behindM < 100) {
        rs.behindSince = 0;
        if (open) await this._close(gid, st, slot, t);
      }
    }
  }

  /**
   * REQ-11: Sub-cluster split detection.
   * Along-route 1D clustering detects splits (e.g. Lead Pack and Trail Pack split by toll plazas or signals)
   * when gap exceeds convoySplitThresholdM for convoySplitHoldS. Suppresses individual SEPARATED alarms.
   */
  async _checkSubClusters(gid, st, room, t) {
    const fresh = [...room.riders.values()].filter((r) => t - (r.lastSeenEpochMs || 0) <= FRESH_MS && (r.lat || r.lng));
    if (fresh.length < 2) {
      if (st.isSplit) {
        st.isSplit = false;
        st.splitSince = 0;
        st.splitPacks = null;
        if (st.open.has('CONVOY_SPLIT')) {
          await this._close(gid, st, 'CONVOY_SPLIT', t, { data: { result: 'INSUFFICIENT_RIDERS' } });
        }
        this.convoys._emit(gid, 'CONVOY_SPLIT_RESOLVED', { type: 'CONVOY_SPLIT_RESOLVED', groupId: gid, timestamp: t });
      }
      return;
    }

    const route = this._route(st, room.meta);
    let mapped = [];
    if (route && route.length >= 2) {
      for (const r of fresh) {
        const rs = this._rs(st, r.userId);
        const on = alongRoute({ lat: r.lat, lng: r.lng }, route, { fromIndex: rs.segIndex });
        if (on) {
          rs.segIndex = on.segIndex;
          mapped.push({ rider: r, alongM: on.alongM });
        }
      }
    }

    let maxGapM = 0;
    let splitIdx = -1;
    let leadPackRiders = [];
    let trailPackRiders = [];
    let leadAlongMin = 0, leadAlongMax = 0;
    let trailAlongMin = 0, trailAlongMax = 0;

    const threshold = room.meta.convoySplitThresholdM || config.convoySplitThresholdM || 1200;
    const holdMs = (room.meta.convoySplitHoldS || config.convoySplitHoldS || 45) * 1000;

    if (route && mapped.length >= 4) {
      mapped.sort((a, b) => b.alongM - a.alongM);
      for (let i = 0; i < mapped.length - 1; i++) {
        const gap = mapped[i].alongM - mapped[i + 1].alongM;
        if (gap > maxGapM) {
          maxGapM = gap;
          splitIdx = i;
        }
      }
      if (splitIdx >= 0) {
        const candLead = mapped.slice(0, splitIdx + 1).map((m) => m.rider);
        const candTrail = mapped.slice(splitIdx + 1).map((m) => m.rider);
        if (candLead.length >= 2 && candTrail.length >= 2) {
          leadPackRiders = candLead;
          trailPackRiders = candTrail;
          const leadAlongs = mapped.slice(0, splitIdx + 1).map((m) => m.alongM);
          const trailAlongs = mapped.slice(splitIdx + 1).map((m) => m.alongM);
          leadAlongMin = Math.round(Math.min(...leadAlongs));
          leadAlongMax = Math.round(Math.max(...leadAlongs));
          trailAlongMin = Math.round(Math.min(...trailAlongs));
          trailAlongMax = Math.round(Math.max(...trailAlongs));
        } else {
          maxGapM = 0;
        }
      }
    }

    if (maxGapM >= threshold && leadPackRiders.length > 0 && trailPackRiders.length > 0) {
      if (!st.splitSince) st.splitSince = t;
      if (t - st.splitSince >= holdMs) {
        const leadSpeeds = leadPackRiders.map((r) => Number(r.speedKmh) || 0);
        const trailSpeeds = trailPackRiders.map((r) => Number(r.speedKmh) || 0);
        const avgLeadSpeed = leadSpeeds.reduce((a, b) => a + b, 0) / leadPackRiders.length;
        const avgTrailSpeed = trailSpeeds.reduce((a, b) => a + b, 0) / trailPackRiders.length;

        const packs = [
          {
            packId: 'LEAD',
            name: 'Lead Pack',
            count: leadPackRiders.length,
            riderCount: leadPackRiders.length,
            leadUserId: leadPackRiders[0].userId,
            leadName: leadPackRiders[0].name,
            leadRider: leadPackRiders[0].name,
            avgSpeedKmh: +avgLeadSpeed.toFixed(1),
            speedKmh: Math.round(avgLeadSpeed),
            alongRouteMinM: leadAlongMin,
            alongRouteMaxM: leadAlongMax,
            riderIds: leadPackRiders.map((r) => r.userId),
          },
          {
            packId: 'TRAIL',
            name: 'Trail Pack',
            count: trailPackRiders.length,
            riderCount: trailPackRiders.length,
            leadUserId: trailPackRiders[0].userId,
            leadName: trailPackRiders[0].name,
            leadRider: trailPackRiders[0].name,
            avgSpeedKmh: +avgTrailSpeed.toFixed(1),
            speedKmh: Math.round(avgTrailSpeed),
            alongRouteMinM: trailAlongMin,
            alongRouteMaxM: trailAlongMax,
            gapMeters: Math.round(maxGapM),
            splitReason: 'TOLL_PLAZA_OR_SIGNAL',
            riderIds: trailPackRiders.map((r) => r.userId),
          },
        ];

        st.isSplit = true;
        st.splitPacks = packs;

        const open = st.open.get('CONVOY_SPLIT');
        if (!open) {
          await this._open(gid, st, 'CONVOY_SPLIT', {
            type: 'CONVOY_SPLIT',
            startedAt: st.splitSince,
            lat: leadPackRiders[0].lat,
            lng: leadPackRiders[0].lng,
            data: {
              gapMeters: Math.round(maxGapM),
              leadCount: leadPackRiders.length,
              trailCount: trailPackRiders.length,
              leadName: leadPackRiders[0].name,
              trailLeadName: trailPackRiders[0].name,
              reason: 'TOLL_PLAZA_OR_SIGNAL',
            },
          });
        } else {
          open.data = {
            ...open.data,
            gapMeters: Math.round(maxGapM),
            leadCount: leadPackRiders.length,
            trailCount: trailPackRiders.length,
          };
          open.updatedAt = this.now();
        }

        this.convoys._emit(gid, 'CONVOY_SPLIT', {
          type: 'CONVOY_SPLIT',
          groupId: gid,
          timestamp: t,
          packs,
        });
      }
    } else if (maxGapM < threshold * 0.7) {
      st.splitSince = 0;
      if (st.isSplit) {
        st.isSplit = false;
        st.splitPacks = null;
        if (st.open.has('CONVOY_SPLIT')) {
          await this._close(gid, st, 'CONVOY_SPLIT', t, { data: { result: 'REGROUPED' } });
        }
        this.convoys._emit(gid, 'CONVOY_SPLIT_RESOLVED', {
          type: 'CONVOY_SPLIT_RESOLVED',
          groupId: gid,
          timestamp: t,
        });
      }
    }
  }

  /**
   * REQ-13: Dedicated Sweeper Distress Monitor & Reverse-Escalation Safeguard.
   * If Sweeper halts (< 5 km/h) or drops offline (> 90 s) while Lead or main pack
   * is moving (> 35 km/h) for > 90 s, triggers SWEEPER_DISTRESS alert.
   */
  async _checkSweeperDistress(gid, st, room, t) {
    const sweeper = [...room.riders.values()].find((r) => r.role === 'SWEEPER');
    if (!sweeper) {
      for (const slot of [...st.open.keys()]) {
        if (slot.startsWith('SWEEPER_DISTRESS:')) await this._close(gid, st, slot, t, { data: { result: 'NO_SWEEPER' } });
      }
      return;
    }
    const lead = [...room.riders.values()].find((r) => r.role === 'LEAD' || r.userId === room.meta.createdByUserId);
    const leadSpeed = Number(lead?.speedKmh) || 0;
    const packMoving = [...room.riders.values()].some((r) => r.userId !== sweeper.userId && (Number(r.speedKmh) || 0) > config.sweeperPackMovingKmh);
    const mainPackMoving = leadSpeed > config.sweeperPackMovingKmh || packMoving;

    const sweeperSpeed = Number(sweeper.speedKmh) || 0;
    const lastSeen = sweeper.lastSeenEpochMs || 0;
    const holdMs = config.sweeperDistressHoldS * 1000;
    const sweeperOffline = !lastSeen || (t - lastSeen > holdMs);
    const sweeperHalted = !sweeperOffline && (sweeperSpeed < config.sweeperHaltKmh);

    const srs = this._rs(st, sweeper.userId);
    const slot = `SWEEPER_DISTRESS:${sweeper.userId}`;

    if (mainPackMoving && (sweeperHalted || sweeperOffline)) {
      if (!srs.distressSince) {
        srs.distressSince = sweeperOffline ? lastSeen : t;
      }
      const dur = t - srs.distressSince;
      if (dur >= holdMs) {
        if (!st.open.has(slot)) {
          const distBehindLead = (lead && Number.isFinite(lead.lat) && Number.isFinite(sweeper.lat))
            ? haversine(sweeper.lat, sweeper.lng, lead.lat, lead.lng) : 0;
          const status = sweeperHalted ? 'HALTED_UNEXPECTEDLY' : 'DROPPED_OFFLINE';
          const payload = {
            type: 'SWEEPER_DISTRESS',
            groupId: gid,
            timestamp: t,
            sweeperId: sweeper.userId,
            sweeperName: sweeper.name || 'Sweeper',
            lat: sweeper.lat,
            lng: sweeper.lng,
            status,
            distanceBehindLeadM: Math.round(distBehindLead),
            haltDurationSec: Math.round(dur / 1000),
            notify: this._leadsAndSweeper(room, sweeper.userId).filter((id) => id !== sweeper.userId),
          };
          await this._open(gid, st, slot, {
            userId: sweeper.userId,
            userName: sweeper.name,
            type: 'SWEEPER_DISTRESS',
            startedAt: srs.distressSince,
            lat: sweeper.lat,
            lng: sweeper.lng,
            data: payload,
          });
          this.convoys._emit(gid, 'SWEEPER_DISTRESS', payload);
        }
      }
    } else {
      if (sweeperSpeed >= 15 || (!mainPackMoving && sweeperSpeed >= 5)) {
        srs.distressSince = 0;
        if (st.open.has(slot)) {
          await this._close(gid, st, slot, t, { data: { result: 'RESOLVED' } });
          this.convoys._emit(gid, 'SWEEPER_DISTRESS_RESOLVED', {
            type: 'SWEEPER_DISTRESS_RESOLVED',
            groupId: gid,
            sweeperId: sweeper.userId,
            timestamp: t,
          });
        }
      }
    }
  }

  /**
   * REQ-12: Dynamic Rendezvous & Regroup Ahead convergence tracking.
   * Tracks convergence when activeRegroup is set; completes when all active riders are within 150m,
   * or expires after regroupTimeoutMin (25 min).
   */
  async _checkRegroupConvergence(gid, st, room, t) {
    const rg = room.regroup || room.meta?.activeRegroup;
    if (!rg || rg.resolved) return;
    if (t >= (rg.expiresAt || (rg.createdAt + config.regroupTimeoutMin * 60000))) {
      await this.convoys.clearRegroup(gid, { userId: 'SYSTEM', name: 'System' }, 'EXPIRED');
      return;
    }
    const fresh = [...room.riders.values()].filter((r) => t - (r.lastSeenEpochMs || 0) <= FRESH_MS && (r.lat || r.lng));
    if (fresh.length < 2) return;
    const R = config.regroupReachRadiusM || 150;
    const allWithin = fresh.every((r) => haversine(r.lat, r.lng, rg.lat, rg.lng) <= R);
    if (allWithin) {
      rg.resolved = true;
      await this.convoys.clearRegroup(gid, { userId: 'SYSTEM', name: 'System' }, 'COMPLETED');
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

    // Where each rider actually started and finished (names only, kept with the report).
    if (this.geo) {
      for (const pm of perMember) {
        const pts = pm.analysis?.points || [];
        if (pts.length < 2) continue;
        const first = pts[0], last = pts[pts.length - 1];
        const [startPlace, endPlace] = await Promise.all([this._placeName(first.lat, first.lng), this._placeName(last.lat, last.lng)]);
        const row = report.members.find((x) => x.userId === pm.userId);
        if (row) { row.startPlace = startPlace; row.endPlace = endPlace; }
      }
    }

    const fresh = await this.repo.getConvoyMeta(gid);
    const rebuilt = !!fresh?.report; // a later rebuild after late uploads
    await this.repo.saveConvoyMeta({ ...fresh, report });
    for (const pm of perMember) {
      if (!(await this.repo.findUserById(pm.userId))) continue; // never resurrect a deleted account
      if (rebuilt && !(await this.repo.getTrip(pm.tripDoc.tripId).catch(() => null))) continue; // the rider deleted this trip
      await this.repo.saveTrip(pm.tripDoc);
    }
    this.convoys._emit(gid, 'REPORT_READY', { groupId: gid });
    return report;
  }
}

function publicEvent(ev) {
  const { slot, key, ...rest } = ev;
  return rest;
}

function median(list) {
  const s = [...list].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

module.exports = { TimelineEngine, visibleWindow, eventVisible, publicEvent, INTERVAL_TYPES };
