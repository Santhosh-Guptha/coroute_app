'use strict';
/**
 * 3.55 "No-signal ahead" (switch `noSignalAhead`). The phone keeps a coverage log of its own past
 * rides (lib/domain/safety/coverage_log.dart) and, while it still has signal, says ONCE that a
 * stretch with no signal is ahead: SIGNAL_AHEAD { near?, backAt } ("Entering a no-signal stretch
 * near X, expected back online around HH:MM"). Back online it sends SIGNAL_AHEAD { clear: true }.
 *
 * The server only relays and keeps the latest notice in memory (per rider of a live room):
 *   - the rider's group gets SIGNAL_AHEAD { userId, name, near, backAt, at } (room event),
 *   - Ride Guardian links of the rider show it (GuardianService reads `noticeFor`), together with
 *     the last position the link already shows.
 * Never on the SOS lanes, never stored in the database. One notice per rider per COOLDOWN_MS.
 * A notice is shown until it is cleared, or until `backAt` + GRACE_MS (then the guardian page goes
 * back to its usual "Location updates are unavailable" wording).
 */

const COOLDOWN_MS = 5 * 60000;
const GRACE_MS = 30 * 60000;
const MIN_AHEAD_MS = 60000;
const MAX_AHEAD_MS = 3 * 3600000;
const NEAR_MAX = 60;
const LINK = /(https?:\/\/|www\.|\b[a-z0-9-]{2,}\.(com|in|net|org|io|me|ly|co|app|link|xyz)\b)/i;

function cleanNear(v) {
  if (typeof v !== 'string') return '';
  const s = v.replace(/[\u0000-\u001f\u007f<>]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, NEAR_MAX);
  return LINK.test(s) ? '' : s;
}

class SignalAhead {
  constructor({ convoys, clock = Date.now, logger = console } = {}) {
    this.convoys = convoys; this.clock = clock; this.log = logger;
    this.notices = new Map(); // `${gid}|${uid}` -> { at, backAt, near }
    this.lastSent = new Map(); // `${gid}|${uid}` -> at
  }

  /** WS SIGNAL_AHEAD from a rider in a room (ws.groupId). Returns the stored notice or null. */
  handle(ws, msg = {}) {
    const u = ws?.user;
    const gid = ws?.groupId;
    if (!u || !gid) return null;
    const room = this.convoys.rooms.get(gid);
    if (!room || !room.riders.has(u.userId) || room.meta.tripStatus !== 'STARTED') return null;
    return this.apply(gid, u.userId, msg);
  }

  apply(gid, uid, msg = {}) {
    const now = this.clock();
    const key = `${gid}|${uid}`;
    const room = this.convoys.rooms.get(gid);
    const name = String(room?.riders.get(uid)?.name || 'Rider').slice(0, 40);
    if (msg.clear === true) {
      if (!this.notices.delete(key)) return null;
      this.convoys._emit(gid, 'SIGNAL_AHEAD', { userId: uid, name, clear: true });
      return null;
    }
    const backAt = Number(msg.backAt);
    if (!Number.isSafeInteger(backAt) || backAt < now + MIN_AHEAD_MS || backAt > now + MAX_AHEAD_MS) return null;
    const last = this.lastSent.get(key) || 0;
    if (now - last < COOLDOWN_MS) return null;
    const notice = { at: now, backAt, near: cleanNear(msg.near) };
    this.notices.set(key, notice);
    this.lastSent.set(key, now);
    this.convoys._emit(gid, 'SIGNAL_AHEAD', { userId: uid, name, near: notice.near, backAt, at: now });
    this._prune(now);
    return notice;
  }

  /** The notice for a rider while it applies, or null. */
  noticeFor(gid, uid, now = this.clock()) {
    const n = this.notices.get(`${gid}|${uid}`);
    if (!n) return null;
    if (now > n.backAt + GRACE_MS) { this.notices.delete(`${gid}|${uid}`); return null; }
    return n;
  }

  onRoomEnded(gid) {
    for (const k of [...this.notices.keys()]) if (k.startsWith(`${gid}|`)) this.notices.delete(k);
    for (const k of [...this.lastSent.keys()]) if (k.startsWith(`${gid}|`)) this.lastSent.delete(k);
  }

  _prune(now) {
    if (this.notices.size < 2000 && this.lastSent.size < 5000) return;
    for (const [k, n] of this.notices) if (now > n.backAt + GRACE_MS) this.notices.delete(k);
    for (const [k, at] of this.lastSent) if (now - at > COOLDOWN_MS) this.lastSent.delete(k);
  }
}

module.exports = { SignalAhead, cleanNear, COOLDOWN_MS, GRACE_MS };
