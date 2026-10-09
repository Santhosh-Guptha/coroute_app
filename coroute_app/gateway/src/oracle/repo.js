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
 *   safety_audit    safety network audit rows  indexed: at, actorId; removed after AUDIT_RETENTION_DAYS (3.15)
 */
const { identity, scrub, scrubConvoyMeta, mentions, FORMER_RIDER } = require('../anonymise');

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
  audit: 'safety_audit',
};

/** Alert fields that live in memory only (filled by the safety network) and are never stored. */
// 3.16: `liveLink` (hash, times) and `nearestHospital` are stored with the alert; `hospitalTried` is not.
const MEMORY_ONLY_ALERT_FIELDS = ['network', 'ownNearest', 'hospitalTried'];
function storableAlert(a) {
  const out = { ...a };
  for (const k of MEMORY_ONLY_ALERT_FIELDS) delete out[k];
  delete out.key;
  return out;
}

const ACTIVE_STATUSES = ['PLANNING', 'STARTED', 'PAUSED'];

class Repo {
  /** @param {import('./soda').SodaClient} soda */
  constructor(soda) {
    this.soda = soda;
    this.alertChains = new Map(); // alertId -> tail of its write chain (read-modify-write is never interleaved)
  }

  /** Runs one read-modify-write of an alert after the previous one for the same alert finished. */
  _alertSerial(alertId, fn) {
    const prev = this.alertChains.get(alertId) || Promise.resolve();
    const run = prev.then(fn, fn);
    const tail = run.catch(() => {});
    this.alertChains.set(alertId, tail);
    tail.then(() => { if (this.alertChains.get(alertId) === tail) this.alertChains.delete(alertId); });
    return run;
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
    await idx(C.audit, 'audit_at_ix', [{ path: 'at', datatype: 'number' }]);
    await idx(C.audit, 'audit_actor_ix', ['actorId']);
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
  /** True when a convoy still refers to this userId (member or creator), even without an account. */
  async userIdReferenced(userId) {
    const asMember = await this.soda.query(C.convoys, { [`members.${userId}`]: { $exists: true } }, { limit: 1 });
    if (asMember.length) return true;
    return (await this.soda.query(C.convoys, { createdByUserId: userId }, { limit: 1 })).length > 0;
  }
  async createUser(user) {
    const doc = { ...user, nameLower: user.name.toLowerCase(), email: user.email.toLowerCase() };
    const key = await this.soda.insert(C.users, doc);
    return { key, ...doc };
  }
  /** Every groupId the rider ever appeared in (trips, memberships, timeline, convoys, chat, SOS). */
  async groupsOfUser(user) {
    const uid = user.userId;
    const groups = new Set();
    const collect = async (coll, filter) => {
      for (let offset = 0; offset < 20000; offset += 1000) {
        const rows = await this.soda.query(coll, filter, { limit: 1000, offset });
        for (const r of rows) if (r.value?.groupId) groups.add(r.value.groupId);
        if (rows.length < 1000) break;
      }
    };
    await collect(C.trips, { userId: uid });
    await collect(C.riders, { userId: uid });
    await collect(C.events, { userId: uid });
    await collect(C.convoys, { createdByUserId: uid });
    await collect(C.convoys, { [`members.${uid}`]: { $exists: true } });
    await collect(C.messages, { senderId: uid });
    await collect(C.alerts, { userId: uid });
    return groups;
  }

  /** Rewrites every document of `coll` matching filter that still mentions the rider. */
  async _scrubWhere(coll, filter, id, { skip = () => false, rewrite = scrub, mentioned = mentions } = {}) {
    let n = 0;
    for (let offset = 0; offset < 50000; offset += 1000) {
      const rows = await this.soda.query(coll, filter, { limit: 1000, offset });
      for (const r of rows) {
        if (skip(r.value) || !mentioned(r.value, id)) continue;
        await this.soda.replace(coll, r.key, rewrite(r.value, id));
        n++;
      }
      if (rows.length < 1000) break;
    }
    return n;
  }

  /**
   * Removes the account and everything tied to it. Trip records are personal data, so they go too.
   * Shared records keep their shape for the other riders but lose every trace of this rider
   * (see anonymise.js): convoy metadata, reports, other riders' timeline entries and trips.
   * `skipGroups`: convoys loaded in memory, whose metadata ConvoyManager.forgetUser already rewrote.
   */
  async deleteUserCascade(user, { id = identity(user), skipGroups = new Set() } = {}) {
    const uid = user.userId;
    const groups = await this.groupsOfUser(user);

    // The rider's own records.
    await this.soda.removeWhere(C.riders, { userId: uid });
    await this.soda.removeWhere(C.trips, { userId: uid });
    await this.soda.removeWhere(C.trackChunks, { userId: uid });
    await this.soda.removeWhere(C.events, { userId: uid });
    await this.soda.removeWhere(C.messages, { senderId: uid });
    await this.soda.removeWhere(C.messages, { senderId: 'SYSTEM', requestedBy: uid });
    await this.soda.removeWhere(C.alerts, { userId: uid });
    await this.soda.removeWhere(C.voiceLog, { from: uid });
    await this.soda.removeWhere(C.voiceLog, { to: uid });
    if (user.email) await this.soda.removeWhere(C.feedback, { email: user.email });
    // The safety log is not kept for deleted accounts (3.15).
    await this.soda.removeWhere(C.audit, { actorId: uid });
    await this.soda.removeWhere(C.audit, { subjectId: uid });

    // Shared records in every convoy the rider was part of.
    for (const gid of groups) {
      if (id.name) await this.soda.removeWhere(C.messages, { groupId: gid, senderId: 'SYSTEM', senderName: id.name }); // older wait cards
      // Other riders' trip records carry the creator's name without the creator's id
      // (possibly a name used before a rename), so they are matched through the convoy.
      const meta = await this.getConvoyMeta(gid);
      const creator = !!meta && (meta.createdByUserId === uid || meta.createdByUserId === id.anonId);
      const tripScrub = creator ? {
        mentioned: (doc, i) => mentions(doc, i) || (!!doc.createdByUserName && doc.createdByUserName !== FORMER_RIDER),
        rewrite: (doc, i) => ({ ...scrub(doc, i), createdByUserName: FORMER_RIDER }),
      } : {};
      if (!skipGroups.has(gid)) {
        // Keep updatedAt as it is, so retention timing does not change.
        await this._scrubWhere(C.convoys, { groupId: gid }, id, { rewrite: scrubConvoyMeta });
      }
      await this._scrubWhere(C.riders, { groupId: gid }, id); // e.g. another rider co-riding with them
      await this._scrubWhere(C.events, { groupId: gid }, id);
      await this._scrubWhere(C.trips, { groupId: gid }, id, tripScrub);
      await this._scrubWhere(C.alerts, { groupId: gid }, id);
      await this._scrubWhere(C.messages, { groupId: gid }, id);
    }
    await this._scrubWhere(C.broadcasts, { byUserId: uid }, id);
    await this.soda.removeWhere(C.users, { userId: uid });
    return { groups: groups.size };
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
  /** Finished convoys, newest first (admin history). */
  async listEndedConvoyMeta(limit = 200) {
    const rows = await this.soda.query(C.convoys, { tripStatus: 'ENDED' }, {
      orderBy: [{ path: 'updatedAt', datatype: 'number', order: 'desc' }],
      limit,
    });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }
  async countTrips(limit = 100000) {
    return (await this.soda.query(C.trips, {}, { limit })).length;
  }
  async deleteConvoyCascade(groupId) {
    await Promise.all([
      this.soda.removeWhere(C.riders, { groupId }),
      this.soda.removeWhere(C.messages, { groupId }),
      this.soda.removeWhere(C.alerts, { groupId }),
      this.soda.removeWhere(C.voiceLog, { groupId }),
      this.soda.removeWhere(C.trackChunks, { groupId }),
      this.soda.removeWhere(C.events, { groupId }),
      this.soda.removeWhere(C.trips, { groupId }),
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
    await this.soda.insert(C.alerts, { ...storableAlert(alert), groupId, resolved: false });
    return alert;
  }
  async findAlertByClientId(groupId, userId, clientId) {
    const r = await this.soda.findOne(C.alerts, { groupId, userId, clientId });
    return r ? { ...r.value, key: r.key } : null;
  }
  /** `extra`: 3.15 fields written with the resolve (status, resolveReason, resolvedAt). */
  async resolveAlert(groupId, alertId, byUserId, extra = {}) {
    return this._alertSerial(alertId, async () => {
      const r = await this.soda.findOne(C.alerts, { groupId, alertId });
      if (!r) return false;
      // Medical info is shown only while the alert is open: it is not kept after it.
      const { medical, ...rest } = r.value;
      await this.soda.replace(C.alerts, r.key, { ...rest, resolved: true, resolvedAt: Date.now(), resolvedBy: byUserId, ...storableAlert(extra) });
      return true;
    });
  }
  /** Merges `patch` into one stored alert (responders, 3.15 status fields). Memory-only fields are dropped. */
  async updateAlert(groupId, alertId, patch) {
    return this._alertSerial(alertId, async () => {
      const r = await this.soda.findOne(C.alerts, { groupId, alertId });
      if (!r) return false;
      // A closed alert keeps its closing status: a late open-status write never reopens it.
      const next = { ...r.value, ...storableAlert(patch) };
      if (r.value.resolved) { next.resolved = true; if (r.value.status) next.status = r.value.status; }
      await this.soda.replace(C.alerts, r.key, next);
      return true;
    });
  }
  /** Trip end: removes the medical info from every alert of the convoy (open or not). */
  async stripAlertMedical(groupId) {
    let n = 0;
    const rows = await this.soda.query(C.alerts, { groupId, medical: { $exists: true } }, { limit: 500 });
    for (const r of rows) {
      const { medical, ...rest } = r.value;
      await this.soda.replace(C.alerts, r.key, rest);
      n++;
    }
    return n;
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
  /** How many trips a rider has (up to `max`), reading keys only. */
  async countTripsForUser(userId, max = 500) {
    return (await this.soda.query(C.trips, { userId }, { limit: max, fields: 'id' })).length;
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
  async countPageview(day, path, referrerHost, maxReferrers = 50) {
    const existing = await this.soda.findOne(C.pageviews, { day, path });
    if (existing) {
      const v = existing.value;
      const refs = { ...(v.referrers || {}) };
      if (referrerHost) {
        // A bounded map: new hosts beyond the cap are counted together under "other".
        const key = refs[referrerHost] !== undefined || Object.keys(refs).filter((k) => k !== 'other').length < maxReferrers ? referrerHost : 'other';
        refs[key] = (refs[key] || 0) + 1;
      }
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

  // ---------- safety network (3.15) ----------
  async addAudit(row) { return this.soda.insert(C.audit, row); }
  /** Newest first. */
  async listAudit({ limit = 100, actorId } = {}) {
    const rows = await this.soda.query(C.audit, actorId ? { actorId } : {}, { orderBy: [{ path: 'at', datatype: 'number', order: 'desc' }], limit: Math.min(1000, Math.max(1, limit)) });
    return rows.map((r) => r.value);
  }
  /** Appends a false alarm time to the user (last 10 kept, server only). */
  async addFalseAlarm(userId, at) {
    const r = await this.soda.findOne(C.users, { userId });
    if (!r) return null;
    const list = [...(Array.isArray(r.value.falseAlarmAt) ? r.value.falseAlarmAt : []), at].filter(Number.isFinite).slice(-10);
    await this.soda.replace(C.users, r.key, { ...r.value, falseAlarmAt: list });
    return list;
  }
  async resetFalseAlarms(userId) {
    const r = await this.soda.findOne(C.users, { userId });
    if (!r) return false;
    await this.soda.replace(C.users, r.key, { ...r.value, falseAlarmAt: [] });
    return true;
  }
  /** Users with any false alarm recorded (admin view). */
  async listFalseAlarmUsers(limit = 500) {
    const rows = await this.soda.query(C.users, { falseAlarmAt: { $exists: true } }, { limit });
    return rows.map((r) => r.value).filter((u) => Array.isArray(u.falseAlarmAt) && u.falseAlarmAt.length);
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

module.exports = { Repo, COLLECTIONS: C, ACTIVE_STATUSES, storableAlert };
