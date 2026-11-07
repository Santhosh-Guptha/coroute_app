'use strict';
/**
 * 3.55 "Arrival message" (switch `arrivalMessage`): guardians get "Arrived safely" once, then the
 * link stops tracking and expires.
 *
 * The server only records the fact; every decision about the ride is already made by the phones
 * (destination arrival, ending the ride). This module listens to the room events ConvoyManager
 * already emits and writes ONE arrival marker per rider:
 *   - DESTINATION_ARRIVALS with allReachedAt (every rider of the ride reached the destination; for
 *     a solo ride that is the rider's own arrival), or
 *   - TRIP_STATUS ENDED by a rider (not `system`: an abandoned or emptied ride is not "safe").
 * A rider with an open (unresolved) SOS / crash alert never gets a marker: an emergency is never
 * reported as "arrived safely".
 *
 * Markers live in the trip events collection under groupId `guardian:<groupId>` (so the riders'
 * own timeline never shows them) with a fixed eventId, so a second trigger (all arrived, then the
 * ride ended) keeps the first arrival time. GuardianService reads them (`repo.guardianArrival`):
 * the view then says ARRIVED with no position, and the link expires ARRIVED_KEEP_MS later.
 */

const ARRIVED_KEEP_MS = 2 * 3600000;

const arrivalGroupKey = (groupId) => `guardian:${groupId}`;
const arrivalEventId = (groupId, userId) => `ARRIVED-${groupId}-${userId}`;

class GuardianArrival {
  /** @param {{convoys: any, repo: any, clock?: () => number, logger?: any}} deps */
  constructor({ convoys, repo, clock = Date.now, logger = console }) {
    this.convoys = convoys; this.repo = repo; this.clock = clock; this.log = logger;
    this.pending = new Set();
    this._onEvent = (gid, msg) => {
      try { this.onEvent(gid, msg); } catch (e) { this.log.warn?.('[guardian-arrival]', e.message); }
    };
  }

  attach() { this.convoys.on('event', this._onEvent); return this; }
  detach() { this.convoys.off?.('event', this._onEvent); }

  _on() { const ff = this.convoys.featureFlags; return !ff || ff.isOn('arrivalMessage'); }

  /** Synchronous: who is in the room and who has an open alert is read at the moment of the event. */
  onEvent(gid, msg) {
    if (!msg || typeof msg !== 'object') return null;
    let reason = null;
    if (msg.type === 'DESTINATION_ARRIVALS' && Number(msg.allReachedAt) > 0) reason = 'ALL_ARRIVED';
    else if (msg.type === 'TRIP_STATUS' && msg.tripStatus === 'ENDED' && !msg.system) reason = 'ENDED';
    if (!reason || !this._on()) return null;
    const room = this.convoys.rooms?.get(gid);
    if (!room) return null;
    const open = new Set([...(room.alerts?.values() || [])].filter((a) => a && !a.resolved).map((a) => a.userId));
    const riders = [...room.riders.keys()].filter((uid) => !open.has(uid));
    const p = this.record(gid, riders, reason).catch((e) => this.log.warn?.('[guardian-arrival] store failed', e.message));
    return p;
  }

  /** Writes one marker per rider (an existing marker keeps its first time). */
  async record(gid, userIds, reason) {
    const at = this.clock();
    let written = 0;
    for (const userId of userIds.slice(0, 100)) {
      const key = `${gid}|${userId}`;
      if (this.pending.has(key)) continue;
      this.pending.add(key);
      try {
        if (await this.repo.guardianArrival(gid, userId)) continue;
        await this.repo.addGuardianArrival({
          eventId: arrivalEventId(gid, userId), groupId: arrivalGroupKey(gid), userId,
          type: 'ARRIVED', startedAt: at, updatedAt: at, open: false, reason,
        });
        written++;
      } finally { this.pending.delete(key); }
    }
    return written;
  }
}

module.exports = { GuardianArrival, ARRIVED_KEEP_MS, arrivalGroupKey, arrivalEventId };
