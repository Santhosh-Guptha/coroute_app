'use strict';
/**
 * Zero-maintenance housekeeping. Runs inside the gateway process on a timer.
 *
 * Policy (what is KEPT forever vs. what is removed):
 *   KEPT    : user accounts, convoy records (name, members, dates, settings),
 *             trip records (name, members, dates, distance / speed statistics),
 *             the group timeline (who, what, when, how long, place name) and trip reports.
 *   REMOVED : per-rider GPS traces only —
 *             • convoy_riders documents of convoys ended > RETENTION_ENDED_CONVOY_DAYS
 *             • routeBreadcrumbs of those convoys
 *             • breadcrumbTrail inside trips older than RETENTION_ENDED_CONVOY_DAYS
 *             • track_chunks (uploaded GPS points) older than TRACK_RETENTION_DAYS
 *             • lat/lng on trip_events older than TRACK_RETENTION_DAYS (the entry, its
 *               times, durations and place name are KEPT)
 *             • lat/lng on SOS alerts older than TRACK_RETENTION_DAYS (who, when and type are KEPT)
 *             • voice_log entries older than RETENTION_VOICE_LOG_DAYS (metadata only; audio is never stored)
 *             • geo_cache entries older than GEO_CACHE_DAYS
 *             • medical info left on resolved SOS alerts (safety net: it is removed on resolve and at trip end)
 *   AUTO-END: active convoys with no activity for RETENTION_STALE_CONVOY_HOURS.
 *   KEEPALIVE: a tiny read keeps an Always-Free Autonomous DB from being auto-paused.
 */
const config = require('./config');
const { COLLECTIONS } = require('./oracle/repo');

const DAY = 86400000;

class Retention {
  constructor({ repo, soda, convoys, logger = console }) {
    this.repo = repo; this.soda = soda; this.convoys = convoys; this.log = logger;
    this.timers = [];
  }

  start() {
    const every = config.retentionRunEveryMinutes * 60000;
    this.timers.push(setInterval(() => this.runOnce().catch((e) => this.log.warn('[retention] run failed:', e.message)), every));
    this.timers.push(setInterval(() => this.keepAlive().catch(() => {}), config.keepAliveEveryMinutes * 60000));
    for (const t of this.timers) if (t.unref) t.unref();
    // First pass shortly after boot.
    const first = setTimeout(() => this.runOnce().catch((e) => this.log.warn('[retention] first run failed:', e.message)), 60000);
    if (first.unref) first.unref();
  }

  stop() { for (const t of this.timers) clearInterval(t); }

  async keepAlive() {
    await this.soda.ping();
  }

  async runOnce(nowMs = Date.now()) {
    const stats = { autoEnded: 0, convoysStripped: 0, riderDocsRemoved: 0, tripsStripped: 0, voiceLogsRemoved: 0, trackChunksRemoved: 0, eventsStripped: 0, alertsStripped: 0, geoCacheRemoved: 0, medicalStripped: 0 };

    // 1. End convoys nobody has touched for a long time (phones died, app uninstalled, ...).
    stats.autoEnded = await this.convoys.autoEndStaleConvoys(nowMs - config.retentionStaleConvoyHours * 3600000);

    // 2. Strip GPS traces from old ended convoys — keep the convoy record itself.
    const cutoff = nowMs - config.retentionEndedConvoyDays * DAY;
    const ended = await this.repo.listEndedConvoysBefore(cutoff);
    for (const meta of ended) {
      if (meta.gpsStripped) continue;
      stats.riderDocsRemoved += await this.soda.removeWhere(COLLECTIONS.riders, { groupId: meta.groupId });
      const { key, ...doc } = meta;
      doc.routeBreadcrumbs = [];
      doc.gpsStripped = true;
      await this.soda.replace(COLLECTIONS.convoys, key, { ...doc, updatedAt: doc.updatedAt }); // keep updatedAt so it is not re-selected forever
      stats.convoysStripped++;
    }

    // 3. Strip breadcrumb trails from old trips — keep name, members, dates, statistics.
    const oldTrips = await this.soda.query(COLLECTIONS.trips, { endTimeEpochMs: { $lt: cutoff }, gpsStripped: { $exists: false } }, { limit: 300 });
    for (const { key, value } of oldTrips) {
      await this.soda.replace(COLLECTIONS.trips, key, { ...value, breadcrumbTrail: [], gpsStripped: true });
      stats.tripsStripped++;
    }

    // 4. Raw GPS points and timeline coordinates.
    const trackCutoff = nowMs - config.trackRetentionDays * DAY;
    stats.trackChunksRemoved = await this.repo.purgeOlderThan(COLLECTIONS.trackChunks, 'endTs', trackCutoff);
    for (let round = 0; round < 20; round++) {
      const rows = await this.soda.query(COLLECTIONS.events, { startedAt: { $lt: trackCutoff }, coordsStripped: { $exists: false } }, { limit: 500 });
      if (!rows.length) break;
      for (const { key, value } of rows) {
        await this.soda.replace(COLLECTIONS.events, key, { ...value, lat: null, lng: null, coordsStripped: true });
        stats.eventsStripped++;
      }
      if (rows.length < 500) break;
    }
    // SOS alerts keep who, when and the type; their exact position goes like every other coordinate.
    for (let round = 0; round < 20; round++) {
      const rows = await this.soda.query(COLLECTIONS.alerts, { timestamp: { $lt: trackCutoff }, coordsStripped: { $exists: false } }, { limit: 500 });
      if (!rows.length) break;
      for (const { key, value } of rows) {
        await this.soda.replace(COLLECTIONS.alerts, key, { ...value, lat: null, lng: null, coordsStripped: true });
        stats.alertsStripped++;
      }
      if (rows.length < 500) break;
    }
    // Medical info belongs to an open alert only (normally removed on resolve and at trip end).
    const withMedical = await this.soda.query(COLLECTIONS.alerts, { resolved: true, medical: { $exists: true } }, { limit: 500 });
    for (const { key, value } of withMedical) {
      const { medical, ...rest } = value;
      await this.soda.replace(COLLECTIONS.alerts, key, rest);
      stats.medicalStripped++;
    }
    stats.geoCacheRemoved = await this.repo.purgeOlderThan(COLLECTIONS.geoCache, 'createdAt', nowMs - config.geoCacheDays * DAY);

    // 5. Voice session metadata is operational only.
    stats.voiceLogsRemoved = await this.repo.purgeOlderThan(COLLECTIONS.voiceLog, 'startedAt', nowMs - config.retentionVoiceLogDays * DAY);

    this.log.info('[retention] done', JSON.stringify(stats));
    return stats;
  }
}

module.exports = { Retention };
