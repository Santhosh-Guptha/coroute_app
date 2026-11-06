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
 *             • room_snapshots (live rider state) of convoys ended > RETENTION_ENDED_CONVOY_DAYS
 *   SIMPLIFIED: track_chunks older than TRACK_DETAIL_DAYS (default 14) are merged per rider and
 *             convoy into one simplified document (Douglas-Peucker, TRACK_SIMPLIFY_TOLERANCE_M,
 *             first / last point and a point at least every minute kept, `simplified: true`);
 *             the originals are deleted only after it is written. Replay, GPX and trip reports
 *             read it like any chunk. It is removed at TRACK_RETENTION_DAYS like the rest.
 *             • lat/lng on trip_events older than TRACK_RETENTION_DAYS (the entry, its
 *               times, durations and place name are KEPT)
 *             • lat/lng on SOS alerts older than TRACK_RETENTION_DAYS (who, when and type are KEPT)
 *             • voice_log entries older than RETENTION_VOICE_LOG_DAYS (metadata only; audio is never stored)
 *             • geo_cache entries older than GEO_CACHE_DAYS
 *             • medical info left on resolved SOS alerts (safety net: it is removed on resolve and at trip end)
 *             • safety_audit rows older than AUDIT_RETENTION_DAYS (3.15; ids and codes only, no coordinates)
 *   AUTO-END: active convoys with no activity for RETENTION_STALE_CONVOY_HOURS.
 *   KEEPALIVE: a tiny read keeps an Always-Free Autonomous DB from being auto-paused.
 */
const config = require('./config');
const { COLLECTIONS } = require('./oracle/repo');
const { simplifyTrack, encodeChunkBody, mergeChunkPoints } = require('./tracks');

const DAY = 86400000;
const envInt = (name, def) => { const n = parseInt(process.env[name], 10); return Number.isFinite(n) ? n : def; };
const setting = (key, envName, def) => (Number.isFinite(config[key]) ? config[key] : envInt(envName, def));
/** Points per simplified document (a very long ride is stored as a few consecutive documents). */
const SIMPLIFIED_MAX_POINTS = 5000;

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

  autoEnd(nowMs = Date.now()) {
    return this.convoys.autoEndStaleConvoys(nowMs - config.retentionStaleConvoyHours * 3600000);
  }

  async keepAlive() {
    await this.soda.ping();
  }

  /** autoEnd: false when the convoy auto-end runs as its own job (it touches live rooms; see app.js). */
  async runOnce(nowMs = Date.now(), { autoEnd = true } = {}) {
    const stats = { autoEnded: 0, convoysStripped: 0, riderDocsRemoved: 0, tripsStripped: 0, voiceLogsRemoved: 0, trackChunksRemoved: 0, eventsStripped: 0, alertsStripped: 0, geoCacheRemoved: 0, medicalStripped: 0, auditRemoved: 0, tracksSimplified: 0, trackChunksMerged: 0 };

    stats.guardianRemoved = await this.repo.purgeGuardianAccess(nowMs);

    // 1. End convoys nobody has touched for a long time (phones died, app uninstalled, ...).
    if (autoEnd) stats.autoEnded = await this.autoEnd(nowMs);

    // 2. Strip GPS traces from old ended convoys — keep the convoy record itself.
    const cutoff = nowMs - config.retentionEndedConvoyDays * DAY;
    const ended = await this.repo.listEndedConvoysBefore(cutoff);
    for (const meta of ended) {
      if (meta.gpsStripped) continue;
      stats.riderDocsRemoved += await this.soda.removeWhere(COLLECTIONS.riders, { groupId: meta.groupId });
      if (typeof this.repo.removeRoomSnapshot === 'function') await this.repo.removeRoomSnapshot(meta.groupId);
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
    Object.assign(stats, await this.simplifyOldTracks(nowMs));
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

    // Safety network audit trail (3.15).
    stats.auditRemoved = await this.repo.purgeOlderThan(COLLECTIONS.audit, 'at', nowMs - config.auditRetentionDays * DAY);

    // 5. Voice session metadata is operational only.
    stats.voiceLogsRemoved = await this.repo.purgeOlderThan(COLLECTIONS.voiceLog, 'startedAt', nowMs - config.retentionVoiceLogDays * DAY);

    this.log.info('[retention] done', JSON.stringify(stats));
    return stats;
  }

  /**
   * Merges each rider's track chunks older than TRACK_DETAIL_DAYS into simplified documents.
   * Crash safe: the simplified documents are written first, the originals deleted after; a later
   * run merges whatever is left (points are de-duplicated by timestamp).
   */
  async simplifyOldTracks(nowMs = Date.now(), { maxRiders = 500 } = {}) {
    const out = { tracksSimplified: 0, trackChunksMerged: 0 };
    const detailDays = setting('trackDetailDays', 'TRACK_DETAIL_DAYS', 14);
    if (!(detailDays > 0)) return out;
    const detailCutoff = nowMs - detailDays * DAY;
    const keepCutoff = nowMs - config.trackRetentionDays * DAY;
    if (detailCutoff <= keepCutoff) return out; // everything that old is deleted anyway
    const toleranceM = setting('trackSimplifyToleranceM', 'TRACK_SIMPLIFY_TOLERANCE_M', 5);
    const done = new Set();
    for (let round = 0; round < 50 && done.size < maxRiders; round++) {
      const rows = await this.soda.query(COLLECTIONS.trackChunks,
        { endTs: { $lt: detailCutoff, $gte: keepCutoff }, simplified: { $exists: false } }, { limit: 500 });
      const pairs = new Map();
      for (const { value } of rows) {
        const k = `${value.groupId}\u0000${value.userId}`;
        if (!done.has(k)) pairs.set(k, value);
      }
      if (!pairs.size) break;
      for (const [k, v] of pairs) {
        done.add(k);
        try {
          const n = await this._simplifyRider(v.groupId, v.userId, detailCutoff, nowMs, toleranceM);
          if (n) { out.tracksSimplified++; out.trackChunksMerged += n; }
        } catch (e) {
          this.log.warn('[retention] track simplify failed:', e.message);
        }
        if (done.size >= maxRiders) break;
      }
    }
    return out;
  }

  /** Returns how many original chunks were merged (0 when there was nothing to do). */
  async _simplifyRider(groupId, userId, detailCutoff, nowMs, toleranceM) {
    const rows = [];
    for (let offset = 0; offset < 200000; offset += 1000) {
      const page = await this.soda.query(COLLECTIONS.trackChunks, { groupId, userId, endTs: { $lt: detailCutoff } },
        { orderBy: [{ path: 'startTs', datatype: 'number', order: 'asc' }], limit: 1000, offset });
      rows.push(...page);
      if (page.length < 1000) break;
    }
    const originals = rows.filter((r) => r.value.simplified !== true);
    if (!originals.length) return 0;
    const points = simplifyTrack(mergeChunkPoints(rows.map((r) => r.value)), { toleranceM });
    if (!points.length) return 0; // nothing decodable: leave the documents alone
    // Write the simplified documents first (seq < 0 never collides with a phone's seq).
    for (let i = 0, part = 0; i < points.length; i += SIMPLIFIED_MAX_POINTS, part++) {
      const slice = points.slice(i, i + SIMPLIFIED_MAX_POINTS);
      await this.soda.insert(COLLECTIONS.trackChunks, {
        groupId, userId, seq: -(nowMs * 100 + part), ...encodeChunkBody(slice),
        simplified: true, simplifiedAt: nowMs, toleranceM, sourceChunks: originals.length, createdAt: nowMs,
      });
    }
    // Only then remove what was merged (older simplified documents included).
    for (const r of rows) await this.soda.remove(COLLECTIONS.trackChunks, r.key);
    return originals.length;
  }
}

module.exports = { Retention };
