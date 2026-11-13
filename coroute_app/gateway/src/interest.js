'use strict';
/**
 * Round 8 interest management for big rides (HIGH_TRAFFIC_PLAN_v3.57 item 9). A 100-rider ride relays every position
 * to every rider: O(n^2) entries per flush. In a room with more than WS_INTEREST_ABOVE sockets (default 30) each
 * socket gets, at the room's normal flush rate:
 *   - its WS_INTEREST_NEAR_K nearest riders (default 20; recomputed at most every WS_INTEREST_RECOMPUTE_MS, 2 s),
 *   - the LEAD and SWEEPER (and the trip owner),
 *   - every rider with an open alert (SOS, crash, member report: the alert itself is a separate frame that always
 *     reaches everyone and is never filtered here),
 * and the latest position of everyone else at most every WS_INTEREST_FAR_MS (default 5 s). A socket whose own
 * position is unknown (no fix yet) gets everyone at full rate. WS_INTEREST=off disables it.
 * Pure bookkeeping: the Hub (src/ws.js) builds the frames.
 */
const num = (v, d) => { const n = Number(v); return v !== undefined && v !== '' && Number.isFinite(n) && n >= 0 ? n : d; };

function interestConfig(env = process.env) {
  return {
    enabled: String(env.WS_INTEREST || 'on').toLowerCase() !== 'off',
    above: Math.max(2, num(env.WS_INTEREST_ABOVE, 30)),
    nearK: Math.max(1, num(env.WS_INTEREST_NEAR_K, 20)),
    farMs: Math.max(500, num(env.WS_INTEREST_FAR_MS, 5000)),
    recomputeMs: Math.max(100, num(env.WS_INTEREST_RECOMPUTE_MS, 2000)),
  };
}

const RAD = Math.PI / 180;
/** Squared equirectangular distance (only compared, never shown). */
function dist2(aLat, aLng, bLat, bLng) {
  const x = (bLng - aLng) * Math.cos(((aLat + bLat) / 2) * RAD);
  const y = bLat - aLat;
  return x * x + y * y;
}
const hasFix = (r) => !!r && Number.isFinite(Number(r.lat)) && Number.isFinite(Number(r.lng)) && (Number(r.lat) !== 0 || Number(r.lng) !== 0);

class Interest {
  constructor(cfg = interestConfig(), clock = Date.now) { this.cfg = cfg; this.clock = clock; }

  /** Interest management applies to a room of this many sockets. */
  active(roomSockets) { return this.cfg.enabled && roomSockets > this.cfg.above; }

  /** Riders every socket of the room gets at full rate: lead, sweeper, trip owner, anyone with an open alert. */
  special(room) {
    const out = new Set();
    if (!room) return out;
    for (const r of room.riders.values()) if (r.role === 'LEAD' || r.role === 'SWEEPER') out.add(r.userId);
    const owner = room.meta && (room.meta.tripOwnerUserId || room.meta.createdByUserId);
    if (owner) out.add(owner);
    if (room.alerts) for (const a of room.alerts.values()) if (!a.resolved && a.userId) out.add(a.userId);
    return out;
  }

  /**
   * The nearest K riders of `uid` (cached on `cache` = { at, set } for recomputeMs). null = everyone (no own fix).
   */
  near(room, uid, cache, t = this.clock()) {
    if (cache && cache.set !== undefined && t - cache.at < this.cfg.recomputeMs) return cache.set;
    const me = room && room.riders.get(uid);
    let set = null;
    if (hasFix(me)) {
      const lat = Number(me.lat); const lng = Number(me.lng);
      const list = [];
      for (const r of room.riders.values()) {
        if (r.userId === uid) continue;
        list.push([hasFix(r) ? dist2(lat, lng, Number(r.lat), Number(r.lng)) : Infinity, r.userId]);
      }
      if (list.length > this.cfg.nearK) {
        list.sort((x, y) => x[0] - y[0]);
        set = new Set(list.slice(0, this.cfg.nearK).map((x) => x[1]));
      } else set = new Set(list.map((x) => x[1]));
    }
    if (cache) { cache.at = t; cache.set = set; }
    return set;
  }
}

module.exports = { Interest, interestConfig, dist2 };
