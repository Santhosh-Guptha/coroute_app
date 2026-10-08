'use strict';
/**
 * Rider Discovery Network (3.15, SOCIAL, opt-in). Fully separate from the safety network: its own
 * timer, messages, permission path (convoy meta flags set by the lead) and audit kinds. It never
 * reads alerts or safety network state except `network.hasOpen(gid)` (an emergency always wins),
 * and the safety network never reads anything here.
 *
 * A pair of convoys is considered only when BOTH are Public with discovery on and riding. Each gets
 * the other's group name, rider count, a rounded distance and the kind of encounter (same direction,
 * opposite direction, converging, crossing). Never coordinates, member names, destination or ids
 * other than the encounterId.
 */
const crypto = require('crypto');
const config = require('./config');
const { haversine, medianCentre } = require('./geo_math');
const {
  projectAll, projectNearest, angleDiff, crossAlongHeading, pointAt, RouteIndexCache, gridSize, cellKey, cellsAround,
} = require('./net_geo');
const { ConvoyError } = require('./convoys');

const ENCOUNTER_ID = /^ENC-[0-9A-F]{12}$/;

class Discovery {
  constructor({ convoys, network = null, audit = null, logger = console, clock = Date.now, tickMs = config.discoveryTickMs, routes = null, enabled = config.discoveryEnabled } = {}) {
    this.convoys = convoys; this.network = network; this.audit = audit; this.log = logger; this.clock = clock; this.enabled = enabled;
    this.routes = routes || new RouteIndexCache({ simplifyM: config.netRouteSimplifyM, maxPoints: config.netRouteMaxPoints, G: gridSize(config.netGridMillideg) });
    this.encounters = new Map(); // "gidA|gidB" (sorted) -> state
    this.byId = new Map(); // encounterId -> pair key
    this.waves = new Map(); // `${encounterId}|${gid}` -> last wave time
    this.userWaves = new Map(); // uid -> times
    this.out = { broadcastCap: () => 0 };
    this.timer = setInterval(() => { try { this.tick(); } catch (e) { this.log.warn('[discovery]', e.message); } }, tickMs);
    if (this.timer.unref) this.timer.unref();
  }

  attach(out) { this.out = out; }
  stop() { clearInterval(this.timer); }

  _eligible(room) {
    return !!room && room.meta.visibility === 'PUBLIC' && room.meta.discovery === true && room.meta.tripStatus === 'STARTED';
  }

  _suppressed(gid) { try { return !!this.network && this.network.hasOpen(gid); } catch { return false; } }

  /** Centroid, heading, speed and rider count of the fresh riders of a room, or null. */
  _groupState(gid, room, now) {
    const fresh = [...room.riders.values()].filter((r) => now - (r.lastSeenEpochMs || 0) <= config.netFreshS * 1000 && (r.lat || r.lng));
    if (!fresh.length) return null;
    const c = medianCentre(fresh);
    const moving = fresh.filter((r) => (Number(r.speedKmh) || 0) >= 10);
    let heading = null;
    if (moving.length) {
      let x = 0, y = 0;
      for (const r of moving) { x += Math.sin((r.heading || 0) * Math.PI / 180); y += Math.cos((r.heading || 0) * Math.PI / 180); }
      if (Math.hypot(x, y) > 1e-6) heading = ((Math.atan2(x, y) * 180 / Math.PI) + 360) % 360;
    }
    const sp = fresh.map((r) => Number(r.speedKmh) || 0).sort((a, b) => a - b);
    const kmh = sp.length % 2 ? sp[sp.length >> 1] : (sp[sp.length / 2 - 1] + sp[sp.length / 2]) / 2;
    return { gid, room, lat: c.lat, lng: c.lng, heading, v: kmh / 3.6, riders: fresh.length, idx: this.routes.forMeta(gid, room.meta) };
  }

  /** Encounter type of a pair, or null (parallel roads that never meet, moving apart, unknown). */
  classify(A, B) {
    const d = haversine(A.lat, A.lng, B.lat, B.lng);
    const L = config.discoveryLateralM;
    if (A.idx && B.idx) {
      const aOnB = projectNearest(B.idx, A.lat, A.lng);
      const bOnA = projectNearest(A.idx, B.lat, B.lng);
      const aOnA = projectNearest(A.idx, A.lat, A.lng);
      if (aOnB && bOnA && aOnA && aOnB.lateralM <= L && bOnA.lateralM <= L && aOnA.lateralM <= L) {
        const hA = A.heading ?? aOnA.segBearing;
        const hB = B.heading ?? bOnA.segBearing;
        const diff = angleDiff(hA, hB);
        // Signed speeds along A's route.
        const sA = angleDiff(hA, aOnA.segBearing) <= 90 ? 1 : -1;
        const sB = angleDiff(hB, bOnA.segBearing) <= 90 ? 1 : -1;
        const gap = bOnA.alongM - aOnA.alongM;
        const rate = B.v * sB - A.v * sA; // d(gap)/dt
        if (diff <= 45) {
          const closing = (gap > 0 && rate < 0) || (gap < 0 && rate > 0);
          return { type: 'SAME_DIRECTION', distanceM: d, meetingS: closing ? Math.abs(gap) / Math.abs(rate) : null, sameRoute: true };
        }
        if (diff > 135) {
          const closing = (gap > 0 && rate < 0) || (gap < 0 && rate > 0);
          if (!closing) return null;
          const vv = A.v + B.v;
          return { type: 'OPPOSITE_DIRECTION', distanceM: d, meetingS: vv > 0.5 ? Math.abs(gap) / vv : null, sameRoute: true };
        }
        return null;
      }
      return this._crossing(A, B, d);
    }
    // No usable route on one side: straight lines only, never CONVERGING / CROSSING.
    if (A.heading === null || B.heading === null) return null;
    const diff = angleDiff(A.heading, B.heading);
    const ca = crossAlongHeading(A.lat, A.lng, A.heading, B.lat, B.lng);
    if (ca.cross > L) return null;
    if (diff < 30) {
      // along > 0: B is ahead of A on A's line, so A is the rear group.
      const rear = ca.along > 0 ? A : B, front = ca.along > 0 ? B : A;
      const gap = Math.abs(ca.along);
      return { type: 'SAME_DIRECTION', distanceM: d, meetingS: rear.v > front.v + 0.5 ? gap / (rear.v - front.v) : null, sameRoute: false };
    }
    if (diff > 150 && ca.along > 0) {
      const vv = A.v + B.v;
      return { type: 'OPPOSITE_DIRECTION', distanceM: d, meetingS: vv > 0.5 ? d / vv : null, sameRoute: false };
    }
    return null;
  }

  /** Routes usable but not on each other's line: first point ahead of A (30 km) that lies on B's route ahead of B. */
  _crossing(A, B, d) {
    const pa = projectNearest(A.idx, A.lat, A.lng);
    const pb = projectNearest(B.idx, B.lat, B.lng);
    if (!pa || !pb || pa.lateralM > config.discoveryLateralM || pb.lateralM > config.discoveryLateralM) return null;
    const step = 100;
    const end = Math.min(A.idx.length, pa.alongM + 30000);
    for (let s = pa.alongM; s <= end; s += step) {
      const p = pointAt(A.idx, s);
      const hit = projectAll(B.idx, p.lat, p.lng, 150).find((x) => x.alongM >= pb.alongM);
      if (!hit) continue;
      if (A.v < 0.5 || B.v < 0.5) return null;
      const tA = (s - pa.alongM) / A.v;
      const tB = (hit.alongM - pb.alongM) / B.v;
      if (Math.abs(tA - tB) > config.discoveryCrossWindowS) return null;
      // Shared line for 1 km after the meeting point: converging, else crossing.
      let shared = true;
      for (let q = s + step; q <= Math.min(A.idx.length, s + 1000); q += step) {
        const pp = pointAt(A.idx, q);
        if (!projectAll(B.idx, pp.lat, pp.lng, 150).some((x) => x.alongM >= hit.alongM)) { shared = false; break; }
      }
      if (s + 1000 > A.idx.length) shared = false;
      return { type: shared ? 'CONVERGING' : 'CROSSING', distanceM: d, meetingS: Math.max(tA, tB), sameRoute: shared };
    }
    return null;
  }

  _key(a, b) { return a < b ? `${a}|${b}` : `${b}|${a}`; }

  /**
   * DISCOVERY for one room about the other. The message's own `type` is DISCOVERY, so the kind of
   * encounter travels as `encounterType` (DEV_GW.md deviation 1; the app reads it).
   */
  _payload(state, other, cls, kind) {
    const dist = cls ? cls.distanceM : state.lastDistance;
    const out = {
      type: 'DISCOVERY', encounterId: state.encounterId, state: kind, encounterType: cls ? cls.type : state.type,
      groupName: String(other.room.meta.name || '').slice(0, 60), riders: other.riders,
      distanceM: dist < 5000 ? Math.round(dist / 500) * 500 : Math.round(dist / 1000) * 1000,
      sameRoute: !!(cls ? cls.sameRoute : state.sameRoute),
    };
    const m = cls ? cls.meetingS : null;
    if (Number.isFinite(m)) out.meetingS = Math.round(m / 60) * 60;
    return out;
  }

  _send(gid, payload) { try { this.out.broadcastCap(gid, 'net1', payload); } catch { /* socket gone */ } }

  /** Every DISCOVERY_TICK_MS: eligible rooms only, pairs through a 0.1 degree grid. */
  tick(now = this.clock()) {
    if (!this.enabled) return;
    const eligible = [];
    for (const [gid, room] of this.convoys.rooms) if (this._eligible(room)) eligible.push([gid, room]);
    if (eligible.length < 2 && !this.encounters.size) return;
    const states = new Map();
    for (const [gid, room] of eligible) { const s = this._groupState(gid, room, now); if (s) states.set(gid, s); }
    const G = 0.1;
    const cells = new Map();
    for (const s of states.values()) {
      const k = cellKey(s.lat, s.lng, G);
      if (!cells.has(k)) cells.set(k, []);
      cells.get(k).push(s);
    }
    const seen = new Set();
    // Bounded work per tick: at most NET_MAX_CANDIDATES_EVAL pairs are classified (nearest first).
    const pairs = [];
    for (const A of states.values()) {
      for (const k of cellsAround(A.lat, A.lng, G, 1)) {
        for (const B of cells.get(k) || []) {
          if (B.gid === A.gid) continue;
          const key = this._key(A.gid, B.gid);
          if (seen.has(key)) continue;
          seen.add(key);
          const d = haversine(A.lat, A.lng, B.lat, B.lng);
          if (d > config.discoveryRadiusM) continue;
          pairs.push({ key, d, X: A.gid < B.gid ? A : B, Y: A.gid < B.gid ? B : A });
        }
      }
    }
    pairs.sort((a, b) => a.d - b.d);
    for (const p of pairs.slice(0, config.netMaxCandidatesEval)) this._pair(p.key, p.X, p.Y, this.classify(p.X, p.Y), now);
    for (const p of pairs.slice(config.netMaxCandidatesEval)) seen.delete(p.key); // not looked at this tick
    for (const [uid, list] of this.userWaves) if (!list.some((x) => now - x < 600000)) this.userWaves.delete(uid);
    // Encounters not seen this tick: end when far apart, unclassified for 10 min, or a room is no longer eligible.
    for (const [key, st] of [...this.encounters]) {
      if (seen.has(key) && !st.ended) continue;
      const [ga, gb] = key.split('|');
      const A = states.get(ga), B = states.get(gb);
      if (!A || !B) { this._end(key, st, now); continue; }
      if (st.ended) { if (now - st.endedAt > config.discoveryRenotifyMin * 60000) { this.encounters.delete(key); this.byId.delete(st.encounterId); } continue; }
      const d = haversine(A.lat, A.lng, B.lat, B.lng);
      if (d > config.discoveryEndM || now - (st.classifiedAt || st.notifiedAt) > 10 * 60000) this._end(key, st, now);
    }
  }

  _pair(key, A, B, cls, now) {
    let st = this.encounters.get(key);
    if (!cls) {
      if (st && !st.ended && now - (st.classifiedAt || st.notifiedAt) > 10 * 60000) this._end(key, st, now);
      return;
    }
    if (!(cls.distanceM <= config.discoveryRadiusM || (Number.isFinite(cls.meetingS) && cls.meetingS <= config.discoveryMeetMaxS))) return;
    if (st && st.ended) {
      if (now - st.notifiedAt < config.discoveryRenotifyMin * 60000) return;
      this.encounters.delete(key); this.byId.delete(st.encounterId); st = null;
    }
    if (!st) {
      st = { encounterId: `ENC-${crypto.randomBytes(6).toString('hex').toUpperCase()}`, type: cls.type, sameRoute: cls.sameRoute, notifiedAt: now, classifiedAt: now, lastDistance: cls.distanceM, ended: false, endedAt: 0, sent: {} };
      this.encounters.set(key, st);
      this.byId.set(st.encounterId, key);
    }
    st.classifiedAt = now;
    st.lastDistance = cls.distanceM;
    const typeChanged = st.type !== cls.type;
    st.type = cls.type; st.sameRoute = cls.sameRoute;
    for (const [me, other] of [[A, B], [B, A]]) {
      if (this._suppressed(me.gid) || this._suppressed(other.gid)) continue; // an emergency always wins
      const prev = st.sent[me.gid];
      if (prev === st.type) continue;
      this._send(me.gid, this._payload(st, other, cls, prev ? 'UPDATE' : 'NEW'));
      st.sent[me.gid] = st.type;
      if (!prev || typeChanged) st.notifiedAt = now;
      if (this.audit) this.audit.add({ kind: 'DISCOVERY_NOTIFY', groupId: me.gid, detail: `${st.type} ${prev ? 'UPDATE' : 'NEW'}` });
    }
  }

  _end(key, st, now) {
    if (st.ended) return;
    st.ended = true; st.endedAt = now;
    for (const gid of Object.keys(st.sent)) this._send(gid, { type: 'DISCOVERY', encounterId: st.encounterId, state: 'END', encounterType: st.type, groupName: '', riders: 0, distanceM: 0, sameRoute: false });
    st.sent = {};
  }

  /** WAVE from a rider of either room: the other room gets WAVED. Throws 404 / 429. */
  wave(user, gid, encounterId) {
    const key = typeof encounterId === 'string' && ENCOUNTER_ID.test(encounterId) ? this.byId.get(encounterId) : null;
    const st = key && this.encounters.get(key);
    if (!st || st.ended || !this.enabled) throw new ConvoyError('That group is no longer nearby.', 404, 'ENCOUNTER_CLOSED');
    const [ga, gb] = key.split('|');
    if (gid !== ga && gid !== gb) throw new ConvoyError('That group is no longer nearby.', 404, 'ENCOUNTER_CLOSED');
    if (!st.sent[gid]) throw new ConvoyError('That group is no longer nearby.', 404, 'ENCOUNTER_CLOSED');
    const now = this.clock();
    const wk = `${encounterId}|${gid}`;
    if (now - (this.waves.get(wk) || 0) < config.discoveryWaveGapMin * 60000) throw new ConvoyError('Slow down.', 429);
    const mine = (this.userWaves.get(user.userId) || []).filter((x) => now - x < 600000);
    if (mine.length >= 3) throw new ConvoyError('Slow down.', 429);
    mine.push(now);
    this.userWaves.set(user.userId, mine);
    this.waves.set(wk, now);
    if (this.waves.size > 5000) for (const [k, v] of this.waves) if (now - v > config.discoveryWaveGapMin * 60000) this.waves.delete(k);
    const other = gid === ga ? gb : ga;
    const myRoom = this.convoys.rooms.get(gid);
    // Social never reaches a group during an emergency (either side): the wave is used up, not delivered.
    if (!this._suppressed(other) && !this._suppressed(gid)) {
      this._send(other, { type: 'WAVED', encounterId, groupName: String(myRoom?.meta.name || ''), at: now });
    }
    if (this.audit) this.audit.add({ kind: 'WAVE', groupId: gid, actorId: user.userId, detail: 'WAVE' });
    return true;
  }

  /** A room left memory: its encounters end. */
  onRoomEnded(gid) {
    for (const [key, st] of [...this.encounters]) {
      if (key.split('|').includes(gid)) { this._end(key, st, this.clock()); this.encounters.delete(key); this.byId.delete(st.encounterId); }
    }
    this.routes.forget(gid);
  }

  /** A room switched off discovery or went private: its open encounters end at once. */
  onConfig(gid) {
    const room = this.convoys.rooms.get(gid);
    if (this._eligible(room)) return;
    for (const [key, st] of this.encounters) if (key.split('|').includes(gid)) this._end(key, st, this.clock());
  }
}

module.exports = { Discovery };
