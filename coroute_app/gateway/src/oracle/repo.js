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
