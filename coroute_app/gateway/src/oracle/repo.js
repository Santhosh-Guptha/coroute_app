'use strict';
/**
 * Data access layer. One function per business operation; the rest of the
 * gateway never touches SODA directly.
 *
 * Collections (all JSON documents in Oracle Autonomous DB):
 *   users           one per account            unique: userId, email
 *   convoys         convoy metadata + config   unique: groupId; indexed: joinCode, tripStatus
 *   convoy_riders   one per rider per convoy   unique: (groupId,userId)
 *   messages        chat / quick cards         indexed: (groupId,timestamp)
 *   alerts          SOS alerts                 indexed: (groupId,resolved)
 *   trips           finished journeys          indexed: userId, endTimeEpochMs
 *   voice_log       voice session metadata     indexed: startedAt  (NO audio is ever stored)
 *   broadcasts      admin fleet announcements  indexed: timestamp
 *   track_chunks    uploaded GPS points        unique: (groupId,userId,seq); removed after TRACK_RETENTION_DAYS
 *   trip_events     group timeline entries     unique: eventId; kept forever, coordinates removed after TRACK_RETENTION_DAYS
 *   geo_cache       place search / route cache unique: k; removed after GEO_CACHE_DAYS
 */
const C = {
  users: 'users',
  convoys: 'convoys',
  riders: 'convoy_riders',
  messages: 'messages',
  alerts: 'alerts',
  trips: 'trips',
  voiceLog: 'voice_log',
  broadcasts: 'broadcasts',
  pageviews: 'pageviews',
  feedback: 'feedback',
  trackChunks: 'track_chunks',
  events: 'trip_events',
  geoCache: 'geo_cache',
};

const ACTIVE_STATUSES = ['PLANNING', 'STARTED', 'PAUSED'];

class Repo {
  /** @param {import('./soda').SodaClient} soda */
  constructor(soda) {
    this.soda = soda;
  }

  /** Creates collections + indexes. Safe to run on every boot. */
  async migrate() {
    for (const name of Object.values(C)) await this.soda.ensureCollection(name);
    const idx = (coll, name, fields, unique = false) =>
      this.soda.ensureIndex(coll, { name, unique, fields: fields.map((f) => (typeof f === 'string' ? { path: f } : f)) });
    await idx(C.users, 'users_userid_ux', ['userId'], true);
    await idx(C.users, 'users_email_ux', ['email'], true);
    await idx(C.convoys, 'convoys_groupid_ux', ['groupId'], true);
    await idx(C.convoys, 'convoys_joincode_ix', ['joinCode', 'tripStatus']);
    await idx(C.convoys, 'convoys_status_ix', ['tripStatus', { path: 'updatedAt', datatype: 'number' }]);
    await idx(C.riders, 'riders_group_user_ux', ['groupId', 'userId'], true);
    await idx(C.riders, 'riders_user_ix', ['userId']);
    await idx(C.messages, 'messages_group_ts_ix', ['groupId', { path: 'timestamp', datatype: 'number' }]);
    await idx(C.messages, 'messages_id_ux', ['messageId'], true);
    await idx(C.alerts, 'alerts_group_ix', ['groupId', 'resolved']);
    await idx(C.alerts, 'alerts_id_ux', ['alertId'], true);
    await idx(C.trips, 'trips_user_ix', ['userId', { path: 'endTimeEpochMs', datatype: 'number' }]);
    await idx(C.trips, 'trips_id_ux', ['tripId'], true);
    await idx(C.voiceLog, 'voice_started_ix', [{ path: 'startedAt', datatype: 'number' }]);
    await idx(C.broadcasts, 'broadcasts_ts_ix', [{ path: 'timestamp', datatype: 'number' }]);
    await idx(C.pageviews, 'pageviews_day_path_ux', ['day', 'path'], true);
    await idx(C.feedback, 'feedback_ts_ix', [{ path: 'createdAt', datatype: 'number' }]);
    await idx(C.trackChunks, 'tracks_group_user_seq_ux', ['groupId', 'userId', { path: 'seq', datatype: 'number' }], true);
    await idx(C.trackChunks, 'tracks_group_ts_ix', ['groupId', { path: 'startTs', datatype: 'number' }]);
    await idx(C.trackChunks, 'tracks_end_ix', [{ path: 'endTs', datatype: 'number' }]);
    await idx(C.events, 'events_id_ux', ['eventId'], true);
    await idx(C.events, 'events_group_ts_ix', ['groupId', { path: 'startedAt', datatype: 'number' }]);
    await idx(C.events, 'events_user_ix', ['userId']);
    await idx(C.geoCache, 'geo_k_ux', ['k'], true);
    await idx(C.geoCache, 'geo_created_ix', [{ path: 'createdAt', datatype: 'number' }]);
  }

  // ---------- users ----------
  async findUserByEmail(email) {
    const r = await this.soda.findOne(C.users, { email: email.toLowerCase() });
    return r ? { ...r.value, key: r.key } : null;
  }
  async findUserById(userId) {
    const r = await this.soda.findOne(C.users, { userId });
    return r ? { ...r.value, key: r.key } : null;
  }
  async findUserByName(name) {
    const r = await this.soda.findOne(C.users, { nameLower: name.toLowerCase() });
    return r ? { ...r.value, key: r.key } : null;
  }
  async createUser(user) {
    const doc = { ...user, nameLower: user.name.toLowerCase(), email: user.email.toLowerCase() };
    const key = await this.soda.insert(C.users, doc);
    return { key, ...doc };
  }
  /** Removes the account and everything tied to it. Trip records are personal data, so they go too. */
  async deleteUserCascade(user) {
    await this.soda.removeWhere(C.riders, { userId: user.userId });
    await this.soda.removeWhere(C.trips, { userId: user.userId });
    await this.soda.removeWhere(C.trackChunks, { userId: user.userId });
    await this.soda.removeWhere(C.events, { userId: user.userId });
    if (user.email) await this.soda.removeWhere(C.feedback, { email: user.email });
    await this.soda.removeWhere(C.users, { userId: user.userId });
  }
  async listUsers(limit = 500) {
    const rows = await this.soda.query(C.users, {}, { orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }], limit });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }
  async countAdmins() {
    return (await this.soda.query(C.users, { role: 'MASTER_ADMIN' }, { limit: 1000 })).length;
  }
  async updateUser(key, patch) {
    const current = await this.soda.get(C.users, key);
    if (!current) return null;
    const doc = { ...current, ...patch };
    if (patch.name) doc.nameLower = patch.name.toLowerCase();
    await this.soda.replace(C.users, key, doc);
    return doc;
  }

  // ---------- convoys ----------
  async getConvoyMeta(groupId) {
    const r = await this.soda.findOne(C.convoys, { groupId });
    return r ? { ...r.value, key: r.key } : null;
  }
  async getActiveConvoyByJoinCode(joinCode) {
    const rows = await this.soda.query(C.convoys, { joinCode, tripStatus: { $in: ACTIVE_STATUSES } }, { limit: 5 });
    if (rows.length === 0) return null;
    rows.sort((a, b) => (b.value.createdAtEpochMs || 0) - (a.value.createdAtEpochMs || 0));
    return { ...rows[0].value, key: rows[0].key };
  }
  async joinCodeInUse(joinCode) {
    return !!(await this.getActiveConvoyByJoinCode(joinCode));
  }
  async createConvoyMeta(meta) {
    const doc = { ...meta, updatedAt: Date.now() };
    const key = await this.soda.insert(C.convoys, doc);
    return { key, ...doc };
  }
  async saveConvoyMeta(meta) {
    const { key, ...rest } = meta;
    const doc = { ...rest, updatedAt: Date.now() };
    if (key) {
      await this.soda.replace(C.convoys, key, doc);
      return { key, ...doc };
    }
    const k = await this.soda.upsertBy(C.convoys, { groupId: doc.groupId }, doc);
    return { key: k, ...doc };
  }
  async listActiveConvoyMeta(limit = 200) {
    const rows = await this.soda.query(C.convoys, { tripStatus: { $in: ACTIVE_STATUSES } }, {
      orderBy: [{ path: 'updatedAt', datatype: 'number', order: 'desc' }],
      limit,
    });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }
  async deleteConvoyCascade(groupId) {
    await Promise.all([
      this.soda.removeWhere(C.riders, { groupId }),
      this.soda.removeWhere(C.messages, { groupId }),
      this.soda.removeWhere(C.alerts, { groupId }),
      this.soda.removeWhere(C.voiceLog, { groupId }),
      this.soda.removeWhere(C.trackChunks, { groupId }),
      this.soda.removeWhere(C.events, { groupId }),
    ]);
    await this.soda.removeWhere(C.convoys, { groupId });
  }

  // ---------- riders ----------
  async listRiders(groupId) {
    const rows = await this.soda.query(C.riders, { groupId }, { limit: 500 });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }
  async getRider(groupId, userId) {
    const r = await this.soda.findOne(C.riders, { groupId, userId });
    return r ? { ...r.value, key: r.key } : null;
  }
  async upsertRider(groupId, rider) {
    const doc = { ...rider, groupId, userId: rider.userId };
    delete doc.key;
    const key = await this.soda.upsertBy(C.riders, { groupId, userId: rider.userId }, doc);
    return { key, ...doc };
  }
  async removeRider(groupId, userId) {
    return this.soda.removeWhere(C.riders, { groupId, userId });
  }
  async findActiveMembership(userId) {
    const rows = await this.soda.query(C.riders, { userId }, { limit: 50 });
    for (const r of rows) {
      const meta = await this.getConvoyMeta(r.value.groupId);
      if (meta && ACTIVE_STATUSES.includes(meta.tripStatus)) return meta;
    }
    return null;
  }

  // ---------- messages / alerts ----------
  async listMessages(groupId, limit = 200) {
    const rows = await this.soda.query(C.messages, { groupId }, {
      orderBy: [{ path: 'timestamp', datatype: 'number', order: 'desc' }],
      limit,
    });
    return rows.map((r) => r.value).reverse();
  }
  async addMessage(groupId, msg) {
    await this.soda.insert(C.messages, { ...msg, groupId });
    return msg;
  }
  async listAlerts(groupId, { includeResolved = false } = {}) {
    const filter = includeResolved ? { groupId } : { groupId, resolved: false };
    const rows = await this.soda.query(C.alerts, filter, { limit: 200 });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }
  async addAlert(groupId, alert) {
    await this.soda.insert(C.alerts, { ...alert, groupId, resolved: false });
    return alert;
  }
  async resolveAlert(groupId, alertId, byUserId) {
    const r = await this.soda.findOne(C.alerts, { groupId, alertId });
    if (!r) return false;
    await this.soda.replace(C.alerts, r.key, { ...r.value, resolved: true, resolvedAt: Date.now(), resolvedBy: byUserId });
    return true;
  }

  // ---------- trips ----------
  async saveTrip(trip) {
    const key = await this.soda.upsertBy(C.trips, { tripId: trip.tripId }, trip);
    return key;
  }
  async getTrip(tripId) {
    const r = await this.soda.findOne(C.trips, { tripId });
    return r ? r.value : null;
  }
  async listTripsForUser(userId, limit = 100) {
    const rows = await this.soda.query(C.trips, { userId }, {
      orderBy: [{ path: 'endTimeEpochMs', datatype: 'number', order: 'desc' }],
      limit,
    });
    return rows.map((r) => r.value);
  }
  async deleteTrip(tripId, userId) {
    return this.soda.removeWhere(C.trips, { tripId, userId });
  }

  // ---------- voice log / broadcasts ----------
  async logVoiceSession(entry) {
    try { await this.soda.insert(C.voiceLog, entry); } catch { /* best effort */ }
  }
  async addBroadcast(entry) {
    await this.soda.insert(C.broadcasts, entry);
  }

  // ---------- website: first-party analytics (no cookies, no personal data) ----------
  async countPageview(day, path, referrerHost) {
    const existing = await this.soda.findOne(C.pageviews, { day, path });
    if (existing) {
      const v = existing.value;
      const refs = { ...(v.referrers || {}) };
      if (referrerHost) refs[referrerHost] = (refs[referrerHost] || 0) + 1;
      await this.soda.replace(C.pageviews, existing.key, { ...v, count: (v.count || 0) + 1, referrers: refs });
    } else {
      await this.soda.insert(C.pageviews, { day, path, count: 1, referrers: referrerHost ? { [referrerHost]: 1 } : {} });
    }
  }
  async listPageviews(sinceDay) {
    const rows = await this.soda.query(C.pageviews, { day: { $gte: sinceDay } }, { orderBy: [{ path: 'day', order: 'desc' }], limit: 1000 });
    return rows.map((r) => r.value);
  }
  async addFeedback(entry) { await this.soda.insert(C.feedback, entry); }
  async listFeedback(limit = 200) {
    const rows = await this.soda.query(C.feedback, {}, { orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }], limit });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }

  // ---------- tracks ----------
  async findTrackChunk(groupId, userId, seq) {
    return this.soda.findOne(C.trackChunks, { groupId, userId, seq });
  }
  async insertTrackChunk(doc) { return this.soda.insert(C.trackChunks, doc); }
  /** All chunks overlapping [from, to], oldest first, paged so long trips load completely. */
  async listTrackChunks(groupId, { userId, from = 0, to = Number.MAX_SAFE_INTEGER } = {}) {
    const filter = { groupId, startTs: { $lte: to }, endTs: { $gte: from } };
    if (userId) filter.userId = userId;
    const out = [];
    for (let offset = 0; offset < 200000; offset += 1000) {
      const rows = await this.soda.query(C.trackChunks, filter, { orderBy: [{ path: 'startTs', datatype: 'number', order: 'asc' }], limit: 1000, offset });
      for (const r of rows) out.push(r.value);
      if (rows.length < 1000) break;
    }
    return out;
  }

  // ---------- timeline ----------
  async upsertEvent(ev) {
    const doc = { ...ev };
    delete doc.key;
    return this.soda.upsertBy(C.events, { eventId: ev.eventId }, doc);
  }
  async removeEvent(eventId) { return this.soda.removeWhere(C.events, { eventId }); }
  async listEvents(groupId, { since = 0, userId, limit = 2000 } = {}) {
    const filter = { groupId };
    if (since) filter.updatedAt = { $gt: since };
    if (userId) filter.userId = userId;
    const out = [];
    for (let offset = 0; offset < limit; offset += 1000) {
      const rows = await this.soda.query(C.events, filter, { orderBy: [{ path: 'startedAt', datatype: 'number', order: 'asc' }], limit: Math.min(1000, limit - offset), offset });
      for (const r of rows) out.push(r.value);
      if (rows.length < 1000) break;
    }
    return out;
  }
  async listOpenEvents(groupId) {
    const rows = await this.soda.query(C.events, { groupId, open: true }, { limit: 500 });
    return rows.map((r) => r.value);
  }

  // ---------- geo cache ----------
  async geoCacheGet(k) {
    const r = await this.soda.findOne(C.geoCache, { k });
    return r ? r.value : null;
  }
  async geoCachePut(k, value) {
    return this.soda.upsertBy(C.geoCache, { k }, { k, value, createdAt: Date.now() });
  }

  // ---------- housekeeping ----------
  async purgeOlderThan(collection, path, cutoffMs) {
    return this.soda.removeWhere(collection, { [path]: { $lt: cutoffMs } });
  }
  async listEndedConvoysBefore(cutoffMs, limit = 200) {
    const rows = await this.soda.query(C.convoys, { tripStatus: 'ENDED', updatedAt: { $lt: cutoffMs } }, { limit });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }
  async listStaleActiveConvoys(cutoffMs, limit = 200) {
    const rows = await this.soda.query(C.convoys, { tripStatus: { $in: ACTIVE_STATUSES }, updatedAt: { $lt: cutoffMs } }, { limit });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }
}

module.exports = { Repo, COLLECTIONS: C, ACTIVE_STATUSES };
