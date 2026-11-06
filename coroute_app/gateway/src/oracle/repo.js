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
 *   room_snapshots  one per live room          unique: groupId. Every rider's live state (position, presence,
 *                   telemetry) in ONE document, rewritten by ConvoyManager's periodic flush instead of one
 *                   convoy_riders write per rider. convoy_riders documents are still written on join, leave,
 *                   role and profile changes; listRiders() overlays the newer snapshot state on them.
 */
const { identity, scrub, scrubConvoyMeta, mentions, FORMER_RIDER } = require('../anonymise');
const { STAFF_ROLES, staffEmails, isStaffAccount } = require('../staff');

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
  guardianGrants: 'guardian_grants',
  guardianSessions: 'guardian_sessions',
  guardianRevocations: 'guardian_revocations',
  guardianConsents: 'guardian_consents',
  guardianSubscriptions: 'guardian_subscriptions',
  guardianJobs: 'guardian_jobs',
  guardianPauses: 'guardian_pauses',
  coupons: 'coupons',
  subscriptionConfig: 'subscription_config',
  memberships: 'memberships',
  activeTrips: 'active_trips',
  organizations: 'organizations',
  diagnostics: 'device_diagnostics',
  roomSnapshots: 'room_snapshots',
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
    this.snapshotChains = new Map(); // groupId -> tail of its room snapshot write chain
    this.snapshotKeys = new Map(); // groupId -> SODA key of its room snapshot (saves the lookup on every flush)
  }

  /** Runs room snapshot writes of one group strictly one after another (never an older state last). */
  _snapshotSerial(groupId, fn) {
    const prev = this.snapshotChains.get(groupId) || Promise.resolve();
    const run = prev.then(fn, fn);
    const tail = run.catch(() => {});
    this.snapshotChains.set(groupId, tail);
    tail.then(() => { if (this.snapshotChains.get(groupId) === tail) this.snapshotChains.delete(groupId); });
    return run;
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
    await idx(C.guardianPauses, 'guardian_pause_ux', ['grantId'], true);
    await idx(C.guardianSubscriptions, 'guardian_sub_ux', ['subscriptionId'], true);
    await idx(C.guardianJobs, 'guardian_job_ux', ['jobId'], true);
    await idx(C.guardianConsents, 'guardian_consent_ix', ['groupId', 'userId', { path: 'createdAt', datatype: 'number' }]);
    await idx(C.guardianGrants, 'guardian_token_ux', ['tokenHash'], true);
    await idx(C.guardianGrants, 'guardian_id_ux', ['grantId'], true);
    await idx(C.guardianGrants, 'guardian_owner_ix', ['creatorId', 'groupId']);
    await idx(C.guardianSessions, 'guardian_session_ux', ['sessionHash'], true);
    await idx(C.guardianRevocations, 'guardian_revoke_ix', ['grantId']);
    for (const coll of [C.guardianGrants, C.guardianSessions, C.guardianRevocations]) {
      await idx(coll, `${coll}_expiry_ix`, [{ path: 'expiresAt', datatype: 'number' }]);
    }
    await idx(C.users, 'users_userid_ux', ['userId'], true);
    await idx(C.users, 'users_email_ux', ['email'], true);
    await idx(C.convoys, 'convoys_groupid_ux', ['groupId'], true);
    await idx(C.convoys, 'convoys_joincode_ix', ['joinCode', 'tripStatus']);
    await idx(C.convoys, 'convoys_status_ix', ['tripStatus', { path: 'updatedAt', datatype: 'number' }]);
    await idx(C.riders, 'riders_group_user_ux', ['groupId', 'userId'], true);
    await idx(C.riders, 'riders_user_ix', ['userId']);
    await idx(C.roomSnapshots, 'room_snapshots_group_ux', ['groupId'], true);
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
    await idx(C.feedback, 'feedback_trip_user_ix', ['tripId', 'userId']);
    await idx(C.feedback, 'feedback_status_ix', ['status', { path: 'submittedAt', datatype: 'number' }]);
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
    await idx(C.memberships, 'memberships_id_ux', ['membershipId'], true);
    await idx(C.memberships, 'memberships_owner_ix', ['ownerUserId']);
    await idx(C.memberships, 'memberships_status_ix', ['status', { path: 'validUntil', datatype: 'number' }]);
    await idx(C.activeTrips, 'active_trips_user_ux', ['userId'], true);
    await idx(C.activeTrips, 'active_trips_group_ix', ['groupId']);
    await idx(C.organizations, 'organizations_id_ux', ['organizationId'], true);
    await idx(C.diagnostics, 'diag_id_ux', ['diagnosticId'], true);
    await idx(C.diagnostics, 'diag_user_ix', ['riderId', { path: 'timestamp', datatype: 'number' }]);
    await idx(C.diagnostics, 'diag_mfg_ix', [{ path: 'deviceInfo.manufacturer', datatype: 'string' }]);
    await idx(C.diagnostics, 'diag_status_ix', ['lifecycleStatus', { path: 'timestamp', datatype: 'number' }]);
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
  /** Every row of `coll` matching filter, read in pages of 1000 (the SODA REST page size). */
  async _allRows(coll, filter) {
    const out = [];
    for (let offset = 0; ; offset += 1000) {
      const rows = await this.soda.query(coll, filter, { limit: 1000, offset });
      out.push(...rows);
      if (rows.length < 1000) return out;
    }
  }

  /** The review photo store (config.reviewPhotoDir); created on first use. */
  _reviewPhotoStore() {
    if (!this._photos) this._photos = require('../review_photos').createPhotoStore(require('../config').reviewPhotoDir);
    return this._photos;
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

    await this.soda.removeWhere(C.guardianConsents, { userId: uid });
    // Remove guardian credentials and dependent sessions before erasing the owner. Every grant is
    // read first (all pages, not only the first 100), then each one and its dependants go.
    const grants = await this._allRows(C.guardianGrants, { creatorId: uid });
    for (const { key, value } of grants) {
      if (value && value.grantId) {
        await this.soda.removeWhere(C.guardianSessions, { grantId: value.grantId });
        await this.soda.removeWhere(C.guardianSubscriptions, { grantId: value.grantId });
        await this.soda.removeWhere(C.guardianJobs, { grantId: value.grantId });
        await this.soda.removeWhere(C.guardianPauses, { grantId: value.grantId });
        await this.soda.removeWhere(C.guardianRevocations, { grantId: value.grantId });
      }
      await this.soda.remove(C.guardianGrants, key);
    }
    await this.soda.removeWhere(C.guardianGrants, { creatorId: uid }); // any written meanwhile
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
    // Trip reviews (public stories go with them) and their uploaded photo files on disk.
    const feedback = [
      ...(user.email ? await this._allRows(C.feedback, { email: user.email }) : []),
      ...await this._allRows(C.feedback, { userId: uid }),
    ];
    const photos = this._reviewPhotoStore();
    for (const { value } of feedback) {
      for (const meta of (Array.isArray(value && value.uploads) ? value.uploads : [])) await photos.remove(meta);
    }
    if (user.email) await this.soda.removeWhere(C.feedback, { email: user.email });
    await this.soda.removeWhere(C.feedback, { userId: uid });
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
      // The room snapshot: the rider's own entry goes, other riders' entries lose every trace of them.
      await this._snapshotSerial(gid, () => this._scrubWhere(C.roomSnapshots, { groupId: gid }, id, {
        mentioned: (doc, i) => mentions(doc, i),
        rewrite: (doc, i) => scrub({ ...doc, riders: (Array.isArray(doc.riders) ? doc.riders : []).filter((r) => !r || r.userId !== uid) }, i),
      }));
      await this._scrubWhere(C.events, { groupId: gid }, id);
      await this._scrubWhere(C.trips, { groupId: gid }, id, tripScrub);
      await this._scrubWhere(C.alerts, { groupId: gid }, id);
      await this._scrubWhere(C.messages, { groupId: gid }, id);
    }
    await this._scrubWhere(C.broadcasts, { byUserId: uid }, id);
    await this.soda.removeWhere(C.users, { userId: uid });
    return { groups: groups.size };
  }

  /** Newest first, up to `limit`, read in pages of 1000 (the SODA REST page size). */
  async listUsers(limit = 500) {
    const out = [];
    for (let offset = 0; offset < limit; offset += 1000) {
      const want = Math.min(1000, limit - offset);
      const rows = await this.soda.query(C.users, {}, { orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }], limit: want, offset });
      for (const r of rows) out.push({ ...r.value, key: r.key });
      if (rows.length < want) break;
    }
    return out;
  }
  /** Users on a paid tier (the sweeper's working set); expired-but-not-rolled-back documents included. */
  async listPaidSubscribers(limit = 2000) {
    const rows = await this.soda.query(C.users, { subscriptionTier: { $in: ['proRider', 'roadCaptain', 'tourOperator'] } }, { limit });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }
  /** Users filtered by subscription tier ('community' = everyone not on a paid tier); all users when no tiers given. */
  async listUsersBySubscription(tiers = null, limit = 10000) {
    const filter = Array.isArray(tiers) && tiers.length ? { subscriptionTier: { $in: tiers } } : {};
    const rows = await this.soda.query(C.users, filter, { limit });
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }
  async countAdmins() {
    return (await this.soda.query(C.users, { role: 'MASTER_ADMIN' }, { limit: 1000 })).length;
  }
  /**
   * userIds of the staff accounts (admin roles, BOOTSTRAP_ADMIN_EMAILS, STAFF_EMAILS; src/staff.js),
   * which every rider / member / revenue count leaves out. Two indexed queries, not a scan of users.
   */
  async staffUserIds() {
    const emails = [...staffEmails()];
    const [byRole, byEmail] = await Promise.all([
      this.soda.query(C.users, { role: { $in: STAFF_ROLES } }, { limit: 5000 }).catch(() => []),
      emails.length ? this.soda.query(C.users, { email: { $in: emails } }, { limit: 5000 }).catch(() => []) : [],
    ]);
    const ids = new Set();
    for (const r of [...byRole, ...byEmail]) {
      const u = r.value || {};
      if (u.userId && u.provider !== 'guest' && isStaffAccount(u)) ids.add(u.userId);
    }
    return ids;
  }
  async updateUser(key, patch) {
    const current = await this.soda.get(C.users, key);
    if (!current) return null;
    const doc = { ...current, ...patch };
    if (patch.name) doc.nameLower = patch.name.toLowerCase();
    await this.soda.replace(C.users, key, doc);
    return doc;
  }

  async setGuardianPause(doc) { await this.soda.upsertBy(C.guardianPauses, { grantId: doc.grantId }, doc); }
  async guardianPaused(grantId) { return (await this.soda.findOne(C.guardianPauses, { grantId }))?.value.paused === true; }
  async guardianEvents(groupId, since) {
    return (await this.soda.query(C.events, { groupId, startedAt: { $gte: since } },
      { limit: 100, orderBy: [{ path: 'startedAt', datatype: 'number', order: 'desc' }] })).map((r) => r.value);
  }
  async saveGuardianSubscription(doc) { return this.soda.upsertBy(C.guardianSubscriptions, { subscriptionId: doc.subscriptionId }, doc); }
  async advanceGuardianSubscription(expected, state) {
    const row = await this.soda.findOne(C.guardianSubscriptions, { subscriptionId: expected.subscriptionId });
    if (!row) return false;
    // Compare the entire observed cursor: never restore deleted or newly opted-out preferences.
    return this.soda.compareAndReplace(C.guardianSubscriptions, row.key, expected,
      { ...expected, state, sequence: (expected.sequence || 0) + 1 });
  }
  async listGuardianSubscriptions(now, offset = 0) {
    return (await this.soda.query(C.guardianSubscriptions, { expiresAt: { $gt: now } }, { limit: 100, offset })).map((r) => r.value);
  }
  async removeGuardianSubscription(subscriptionId) { await this.soda.removeWhere(C.guardianSubscriptions, { subscriptionId }); }
  async enqueueGuardianJob(doc) {
    if (await this.soda.findOne(C.guardianJobs, { jobId: doc.jobId })) return;
    try { await this.soda.insert(C.guardianJobs, doc); }
    catch (e) { if (!await this.soda.findOne(C.guardianJobs, { jobId: doc.jobId })) throw e; }
  }
  async listGuardianJobs(now) {
    return (await this.soda.query(C.guardianJobs, { state: 'PENDING', nextAttemptAt: { $lte: now } }, { limit: 100 })).map((r) => r.value);
  }
  async claimGuardianJob(jobId, owner, now) {
    const row = await this.soda.findOne(C.guardianJobs, { jobId });
    if (!row || row.value.state !== 'PENDING' || row.value.nextAttemptAt > now ||
        (row.value.leaseUntil || 0) > now) return null;
    const claimed = { ...row.value, leaseOwner: owner, leaseUntil: now + 120000 };
    return await this.soda.compareAndReplace(C.guardianJobs, row.key, row.value, claimed) ? claimed : null;
  }
  async finishGuardianJob(doc, owner) {
    const row = await this.soda.findOne(C.guardianJobs, { jobId: doc.jobId });
    if (!row || row.value.leaseOwner !== owner) return false;
    return this.soda.compareAndReplace(C.guardianJobs, row.key, row.value, { ...doc, leaseOwner: null, leaseUntil: 0 });
  }
  async getGuardianSubscription(subscriptionId) {
    return (await this.soda.findOne(C.guardianSubscriptions, { subscriptionId }))?.value || null;
  }
  async addGuardianConsent(doc) { await this.soda.insert(C.guardianConsents, doc); }
  async guardianConsent(groupId, userId) {
    const rows = await this.soda.query(C.guardianConsents, { groupId, userId },
      { limit: 20, orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }] });
    if (!rows.length) return null;
    // Concurrent decisions at the same timestamp resolve conservatively to refusal.
    const at = rows[0].value.createdAt;
    return (rows.find((r) => r.value.createdAt === at && !r.value.allowed) || rows[0]).value;
  }
  // Guardian credentials never become user accounts or convoy membership.
  async createGuardianGrant(doc) { await this.soda.insert(C.guardianGrants, doc); }
  async guardianGrant(filter) {
    const row = await this.soda.findOne(C.guardianGrants, filter);
    return row ? row.value : null;
  }
  async listGuardianGrants(creatorId, groupId) {
    const rows = await this.soda.query(C.guardianGrants, { creatorId, groupId },
      { limit: 100, orderBy: [{ path: 'createdAt', order: 'desc' }] });
    return rows.map((r) => r.value);
  }
  async createGuardianSession(doc) { await this.soda.insert(C.guardianSessions, doc); }
  async guardianSession(sessionHash) {
    const row = await this.soda.findOne(C.guardianSessions, { sessionHash });
    return row ? row.value : null;
  }
  async guardianRevoked(grantId) {
    return !!(await this.soda.findOne(C.guardianRevocations, { grantId }));
  }
  // Append-only tombstone: concurrent operations cannot resurrect a revoked grant.
  async revokeGuardianGrant(doc) { await this.soda.insert(C.guardianRevocations, doc); }
  async purgeGuardianAccess(nowMs) {
    let count = 0;
    // Remove grants before their tombstones; expiration is independently checked on reads.
    for (const coll of [C.guardianGrants, C.guardianSessions, C.guardianRevocations, C.guardianSubscriptions, C.guardianJobs, C.guardianPauses]) {
      count += await this.purgeOlderThan(coll, 'expiresAt', nowMs);
    }
    return count;
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
    // Invalidate access first, then erase dependent observer records in bounded pages.
    await this.soda.removeWhere(C.convoys, { groupId });
    await this.soda.removeWhere(C.guardianConsents, { groupId });
    while (true) {
      const grants = await this.soda.query(C.guardianGrants, { groupId }, { limit: 100 });
      if (!grants.length) break;
      for (const { key, value } of grants) {
        while (true) {
          const subs = await this.soda.query(C.guardianSubscriptions, { grantId: value.grantId }, { limit: 100 });
          if (!subs.length) break;
          for (const sub of subs) {
            await this.soda.removeWhere(C.guardianRevocations, { grantId: sub.value.subscriptionId });
            await this.soda.remove(C.guardianSubscriptions, sub.key);
          }
        }
        for (const coll of [C.guardianSessions, C.guardianSubscriptions, C.guardianJobs, C.guardianPauses, C.guardianRevocations]) {
          await this.soda.removeWhere(coll, { grantId: value.grantId });
        }
        await this.soda.remove(C.guardianGrants, key);
      }
    }
    for (const coll of [C.riders, C.messages, C.alerts, C.voiceLog, C.trackChunks, C.events, C.trips]) {
      await this.soda.removeWhere(coll, { groupId });
    }
    await this.removeRoomSnapshot(groupId);
    await this.soda.removeWhere(C.convoys, { groupId });
  }

  // ---------- riders ----------
  /**
   * Riders of a convoy: the convoy_riders documents (written on join / leave / role changes) with the
   * newer live state of the room snapshot laid over them. A rider found only in the snapshot (its own
   * document not written yet) is included too.
   */
  async listRiders(groupId) {
    const [rows, snap] = await Promise.all([
      this.soda.query(C.riders, { groupId }, { limit: 500 }),
      this.loadRoomSnapshot(groupId).catch(() => null),
    ]);
    const byId = new Map();
    const savedAt = new Map();
    for (const r of rows) {
      const { savedAt: at, ...value } = r.value;
      byId.set(value.userId, { ...value, key: r.key });
      savedAt.set(value.userId, Number(at) || 0);
    }
    if (snap) {
      for (const s of snap.riders) {
        if (!s || !s.userId) continue;
        const cur = byId.get(s.userId);
        if (!cur) byId.set(s.userId, { ...s, groupId });
        else if ((snap.updatedAt || 0) >= savedAt.get(s.userId)) byId.set(s.userId, { ...cur, ...s, groupId, key: cur.key });
      }
    }
    return [...byId.values()];
  }
  async upsertRider(groupId, rider) {
    const doc = { ...rider, groupId, userId: rider.userId };
    delete doc.key;
    const key = await this.soda.upsertBy(C.riders, { groupId, userId: rider.userId }, { ...doc, savedAt: Date.now() });
    return { key, ...doc };
  }
  async removeRider(groupId, userId) {
    const n = await this.soda.removeWhere(C.riders, { groupId, userId });
    // The rider must not come back from the room snapshot at the next room load.
    await this._snapshotSerial(groupId, async () => {
      const r = await this.soda.findOne(C.roomSnapshots, { groupId });
      if (!r || !Array.isArray(r.value.riders) || !r.value.riders.some((x) => x && x.userId === userId)) return;
      await this.soda.replace(C.roomSnapshots, r.key, { ...r.value, riders: r.value.riders.filter((x) => !x || x.userId !== userId) });
    }).catch(() => {});
    return n;
  }

  // ---------- room snapshots (one document per live room) ----------
  /**
   * Stores the live state of every rider of a room in ONE document (one write instead of one per rider).
   * `riders`: array (or Map) of the rider objects ConvoyManager keeps in memory (same fields upsertRider stores).
   * `positionsAt`: when these positions were taken (ms). Writes of one group never overtake each other.
   */
  async saveRoomSnapshot(groupId, { riders = [], positionsAt = Date.now() } = {}) {
    const list = (riders instanceof Map ? [...riders.values()] : Array.isArray(riders) ? riders : [])
      .filter((r) => r && r.userId)
      .map((r) => { const d = { ...r, groupId, userId: r.userId }; delete d.key; return d; });
    const doc = { groupId, riders: list, positionsAt: Number(positionsAt) || Date.now(), updatedAt: Date.now() };
    return this._snapshotSerial(groupId, async () => {
      const known = this.snapshotKeys.get(groupId);
      if (known) {
        try {
          await this.soda.replace(C.roomSnapshots, known, doc);
          return { key: known, ...doc };
        } catch (e) {
          if (!e || e.status !== 404) throw e;
          this.snapshotKeys.delete(groupId); // removed meanwhile (retention, cascade): look it up again
        }
      }
      let key;
      try {
        key = await this.soda.upsertBy(C.roomSnapshots, { groupId }, doc);
      } catch (e) {
        if (!e || (e.status !== 409 && e.status !== 400)) throw e;
        key = await this.soda.upsertBy(C.roomSnapshots, { groupId }, doc); // lost a first-insert race
      }
      this.snapshotKeys.set(groupId, key);
      return { key, ...doc };
    });
  }
  /** The last saved room snapshot: { riders, positionsAt, updatedAt } or null. */
  async loadRoomSnapshot(groupId) {
    const r = await this.soda.findOne(C.roomSnapshots, { groupId });
    if (!r) return null;
    this.snapshotKeys.set(groupId, r.key);
    return {
      riders: Array.isArray(r.value.riders) ? r.value.riders : [],
      positionsAt: r.value.positionsAt || 0,
      updatedAt: r.value.updatedAt || 0,
    };
  }
  async removeRoomSnapshot(groupId) {
    return this._snapshotSerial(groupId, async () => {
      this.snapshotKeys.delete(groupId);
      return this.soda.removeWhere(C.roomSnapshots, { groupId });
    });
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
  /** One bulk insert for many chunks (all or nothing on Oracle; see TrackStore for the fallback). */
  async insertTrackChunks(docs) {
    if (typeof this.soda.insertMany === 'function') return this.soda.insertMany(C.trackChunks, docs);
    const keys = [];
    for (const d of docs) keys.push(await this.soda.insert(C.trackChunks, d));
    return keys;
  }
  /** The seqs of one rider's chunks that are already stored, out of `seqs`. */
  async existingTrackSeqs(groupId, userId, seqs) {
    const found = new Set();
    for (let i = 0; i < seqs.length; i += 200) {
      const part = seqs.slice(i, i + 200);
      const rows = await this.soda.query(C.trackChunks, { groupId, userId, seq: { $in: part } }, { limit: 1000 });
      for (const r of rows) found.add(r.value.seq);
    }
    return found;
  }
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

  // ---------- subscription pricing & coupons ----------
  async getSubscriptionPricing() {
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'pricing' });
    return r ? r.value.prices : null;
  }
  /** The whole pricing document: { prices, history: [{at, by, prices}], updatedAt, updatedBy } or null. */
  async getSubscriptionPricingDoc() {
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'pricing' });
    return r ? r.value : null;
  }
  /** Saves the prices and appends an audit entry to `history` (the last 50 are kept). */
  async setSubscriptionPricing(prices, updatedBy = 'system') {
    const existing = await this.getSubscriptionPricingDoc();
    const at = Date.now();
    const history = Array.isArray(existing?.history) ? [...existing.history] : [];
    history.push({ at, by: updatedBy, prices });
    return this.soda.upsertBy(C.subscriptionConfig, { k: 'pricing' }, {
      k: 'pricing',
      prices,
      history: history.slice(-50),
      updatedAt: at,
      updatedBy,
    });
  }
  // ---------- offers (automatic discounts; subscription_config k='offer') ----------
  async listOffers(limit = 200) {
    const rows = await this.soda.query(C.subscriptionConfig, { k: 'offer' }, { limit });
    return rows.map((r) => r.value);
  }
  async findOffer(id) {
    if (!id) return null;
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'offer', id: String(id) });
    return r ? r.value : null;
  }
  async saveOffer(offer) {
    if (!offer || !offer.id) throw new Error('Offer id is required');
    const doc = { ...offer, k: 'offer', id: String(offer.id), updatedAt: Date.now() };
    delete doc.key;
    await this.soda.upsertBy(C.subscriptionConfig, { k: 'offer', id: doc.id }, doc);
    return doc;
  }
  async deleteOffer(id) {
    return this.soda.removeWhere(C.subscriptionConfig, { k: 'offer', id: String(id) });
  }
  /** Counts one PAID order against the offer. */
  async recordOfferRedemption(id) {
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'offer', id: String(id) });
    if (!r) return null;
    const next = { ...r.value, redemptions: (Number(r.value.redemptions) || 0) + 1, lastRedeemedAt: Date.now(), updatedAt: Date.now() };
    await this.soda.replace(C.subscriptionConfig, r.key, next);
    return next;
  }
  // ---------- subscription sweeper status (subscription_config k='sweep') ----------
  async getSubscriptionSweepStatus() {
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'sweep' });
    return r ? r.value : null;
  }
  async setSubscriptionSweepStatus(status) {
    return this.soda.upsertBy(C.subscriptionConfig, { k: 'sweep' }, { ...status, k: 'sweep' });
  }
  // ---------- Razorpay settings & order ledger (subscription_config) ----------
  /** Admin-saved gateway settings (secrets already encrypted by razorpay_gateway.js). */
  async getPaymentGatewaySettings() {
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'razorpay' });
    return r ? r.value.settings : null;
  }
  async setPaymentGatewaySettings(settings) {
    return this.soda.upsertBy(C.subscriptionConfig, { k: 'razorpay' }, { k: 'razorpay', settings, updatedAt: Date.now() });
  }
  async saveRazorpayOrder(order) {
    return this.soda.upsertBy(C.subscriptionConfig, { k: 'rzp_order', orderId: order.orderId }, { ...order, k: 'rzp_order' });
  }
  async findRazorpayOrder(orderId) {
    if (!orderId) return null;
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'rzp_order', orderId: String(orderId) });
    return r ? r.value : null;
  }
  async updateRazorpayOrder(orderId, patch) {
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'rzp_order', orderId: String(orderId) });
    if (!r) return null;
    const next = { ...r.value, ...patch, k: 'rzp_order', orderId: r.value.orderId, updatedAt: Date.now() };
    await this.soda.replace(C.subscriptionConfig, r.key, next);
    return next;
  }
  /** Ledger orders matching `filter`, up to `limit`, read in pages of 1000 (the SODA REST page size). */
  async listRazorpayOrders(filter = {}, limit = 200) {
    const out = [];
    for (let offset = 0; offset < limit; offset += 1000) {
      const want = Math.min(1000, limit - offset);
      const rows = await this.soda.query(C.subscriptionConfig, { ...filter, k: 'rzp_order' }, { limit: want, offset });
      for (const r of rows) out.push(r.value);
      if (rows.length < want) break;
    }
    return out;
  }
  async findRazorpayOrderByPaymentId(paymentId) {
    if (!paymentId) return null;
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'rzp_order', paymentId: String(paymentId) });
    return r ? r.value : null;
  }
  // ---------- admin audit trail (subscription_config k='audit') ----------
  /** Appends one admin action: { at, by, action, target, details }. */
  async addAuditEntry(entry) {
    const at = Number(entry?.at) || Date.now();
    const id = `aud_${at.toString(36)}_${require('crypto').randomBytes(4).toString('hex')}`;
    const doc = { ...entry, k: 'audit', id, at };
    delete doc.key;
    await this.soda.upsertBy(C.subscriptionConfig, { k: 'audit', id }, doc);
    return doc;
  }
  /** Newest first. */
  async listAuditEntries(limit = 100) {
    const rows = await this.soda.query(C.subscriptionConfig, { k: 'audit' }, { orderBy: [{ path: 'at', datatype: 'number', order: 'desc' }], limit });
    return rows.map((r) => r.value).sort((a, b) => (Number(b.at) || 0) - (Number(a.at) || 0));
  }
  // ---------- dynamic coupons & safe redemption tracking ----------

  computeCouponStatus(c, now = Date.now()) {
    if (!c) return 'ARCHIVED';
    if (c.status === 'ARCHIVED' || c.isArchived) return 'ARCHIVED';
    if (c.status === 'DRAFT') return 'DRAFT';
    const maxTotal = Number(c.maxUsageTotal) || 0;
    const used = Number(c.usageCount) || 0;
    if (c.status === 'USAGE_LIMIT_REACHED' || (maxTotal > 0 && used >= maxTotal)) return 'USAGE_LIMIT_REACHED';
    if (c.status === 'EXPIRED' || (c.expiresAt && c.expiresAt < now)) return 'EXPIRED';
    if (c.status === 'PAUSED' || c.isActive === false) return 'PAUSED';
    if (c.validFrom && c.validFrom > now) return 'SCHEDULED';
    return 'ACTIVE';
  }

  async findCoupon(rawCode) {
    if (!rawCode) return null;
    const code = String(rawCode).trim().toUpperCase();
    const r = await this.soda.findOne(C.coupons, { code });
    if (!r) return null;
    const c = { ...r.value, key: r.key };
    c.status = this.computeCouponStatus(c);
    c.isActive = (c.status === 'ACTIVE' || c.status === 'SCHEDULED');
    return c;
  }

  async listCoupons(limit = 500) {
    const rows = await this.soda.query(C.coupons, {}, { limit });
    const now = Date.now();
    return rows.map((r) => {
      const c = { ...r.value, key: r.key };
      c.status = this.computeCouponStatus(c, now);
      c.isActive = (c.status === 'ACTIVE' || c.status === 'SCHEDULED');
      return c;
    }).sort((a, b) => (Number(b.createdAt) || 0) - (Number(a.createdAt) || 0));
  }

  async saveCoupon(coupon) {
    const code = String(coupon.code || '').trim().toUpperCase();
    if (!code) throw new Error('Coupon code is required');
    const now = Date.now();
    const explicitStatus = String(coupon.status || '').trim().toUpperCase();
    const validFrom = Number(coupon.validFrom) || now;
    const expiresAt = Number(coupon.expiresAt) || (now + 30 * 86400000);
    const maxUsageTotal = Number(coupon.maxUsageTotal) > 0 ? Number(coupon.maxUsageTotal) : 100;
    const usageCount = Number(coupon.usageCount) || 0;

    let status = explicitStatus;
    if (coupon.isActive === false) {
      status = 'PAUSED';
    } else if (coupon.isActive === true && status === 'PAUSED') {
      status = validFrom > now ? 'SCHEDULED' : (expiresAt < now ? 'EXPIRED' : 'ACTIVE');
    } else if (!status || !['DRAFT', 'SCHEDULED', 'ACTIVE', 'PAUSED', 'EXPIRED', 'USAGE_LIMIT_REACHED', 'ARCHIVED'].includes(status)) {
      if (validFrom > now) status = 'SCHEDULED';
      else if (expiresAt < now) status = 'EXPIRED';
      else if (maxUsageTotal > 0 && usageCount >= maxUsageTotal) status = 'USAGE_LIMIT_REACHED';
      else status = 'ACTIVE';
    }

    const doc = {
      code,
      name: coupon.name ? String(coupon.name).trim() : code,
      description: coupon.description ? String(coupon.description).trim() : '',
      internalNotes: coupon.internalNotes ? String(coupon.internalNotes).trim() : '',
      campaignName: coupon.campaignName ? String(coupon.campaignName).trim() : '',
      status,
      discountType: coupon.discountType || 'percentage', // 'percentage' | 'fixed' | 'free'
      discountValue: Number(coupon.discountValue) || 0,
      maxDiscountCap: coupon.maxDiscountCap !== undefined && coupon.maxDiscountCap !== null ? Number(coupon.maxDiscountCap) : null,
      minOrderAmount: Number(coupon.minOrderAmount) || 0,
      validFrom,
      expiresAt,
      timezone: coupon.timezone || 'Asia/Kolkata',
      maxUsageTotal,
      usageCount,
      maxUsagePerUser: Number(coupon.maxUsagePerUser) > 0 ? Number(coupon.maxUsagePerUser) : 1,
      applicableTiers: Array.isArray(coupon.applicableTiers) && coupon.applicableTiers.length ? coupon.applicableTiers : ['all'],
      applicableCycles: Array.isArray(coupon.applicableCycles) && coupon.applicableCycles.length ? coupon.applicableCycles : ['all'],
      newMembersOnly: Boolean(coupon.newMembersOnly),
      firstPaymentOnly: Boolean(coupon.firstPaymentOnly),
      allowedUserIds: Array.isArray(coupon.allowedUserIds) ? coupon.allowedUserIds : [],
      isActive: (status === 'ACTIVE' || status === 'SCHEDULED'),
      usages: Array.isArray(coupon.usages) ? coupon.usages : [],
      createdAt: coupon.createdAt || now,
      updatedAt: now,
      createdBy: coupon.createdBy || 'admin',
    };

    await this.soda.upsertBy(C.coupons, { code }, doc);
    return doc;
  }

  async deleteCoupon(rawCode) {
    const code = String(rawCode).trim().toUpperCase();
    const existing = await this.findCoupon(code);
    if (!existing) return false;
    if (existing.status === 'DRAFT' && (!existing.usages || existing.usages.length === 0)) {
      return this.soda.removeWhere(C.coupons, { code });
    }
    // Soft-archive to preserve immutable audit trail and historical redemptions
    const archived = {
      ...existing,
      status: 'ARCHIVED',
      isActive: false,
      updatedAt: Date.now(),
    };
    delete archived.key;
    await this.soda.upsertBy(C.coupons, { code }, archived);
    return true;
  }

  async pauseCoupon(rawCode, updatedBy = 'admin') {
    const code = String(rawCode).trim().toUpperCase();
    const existing = await this.findCoupon(code);
    if (!existing) return null;
    const paused = {
      ...existing,
      status: 'PAUSED',
      isActive: false,
      updatedBy,
      updatedAt: Date.now(),
    };
    delete paused.key;
    await this.soda.upsertBy(C.coupons, { code }, paused);
    return paused;
  }

  async resumeCoupon(rawCode, updatedBy = 'admin') {
    const code = String(rawCode).trim().toUpperCase();
    const existing = await this.findCoupon(code);
    if (!existing) return null;
    const now = Date.now();
    let status = 'ACTIVE';
    if (existing.validFrom && existing.validFrom > now) status = 'SCHEDULED';
    else if (existing.expiresAt && existing.expiresAt < now) status = 'EXPIRED';
    else if (existing.maxUsageTotal > 0 && (existing.usageCount || 0) >= existing.maxUsageTotal) status = 'USAGE_LIMIT_REACHED';

    const resumed = {
      ...existing,
      status,
      isActive: (status === 'ACTIVE' || status === 'SCHEDULED'),
      updatedBy,
      updatedAt: now,
    };
    delete resumed.key;
    await this.soda.upsertBy(C.coupons, { code }, resumed);
    return resumed;
  }

  // ---------- coupon redemptions & reservations (k='coupon_redemption') ----------

  async saveCouponRedemption(redemptionDoc) {
    const doc = {
      ...redemptionDoc,
      k: 'coupon_redemption',
      updatedAt: Date.now(),
    };
    delete doc.key;
    await this.soda.upsertBy(C.subscriptionConfig, { k: 'coupon_redemption', redemptionId: doc.redemptionId }, doc);
    return doc;
  }

  async findCouponRedemptionByOrderId(orderId) {
    if (!orderId) return null;
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'coupon_redemption', orderId: String(orderId) });
    return r ? r.value : null;
  }

  async listCouponRedemptions(filter = {}, limit = 500) {
    const rows = await this.soda.query(C.subscriptionConfig, { k: 'coupon_redemption' }, { limit: 2000 });
    let list = rows.map((r) => r.value);

    if (filter.couponCode) {
      const code = String(filter.couponCode).trim().toUpperCase();
      list = list.filter((r) => (r.couponCode || '').toUpperCase() === code);
    }
    if (filter.userId) {
      list = list.filter((r) => r.userId === filter.userId);
    }
    if (filter.orderId) {
      list = list.filter((r) => r.orderId === filter.orderId);
    }
    if (filter.category) {
      list = list.filter((r) => r.category === filter.category);
    }
    if (filter.status) {
      list = list.filter((r) => (r.status || '').toUpperCase() === filter.status.toUpperCase());
    }
    if (filter.from) {
      const fromTs = Number(filter.from);
      list = list.filter((r) => (r.redeemedAt || r.reservedAt || r.createdAt) >= fromTs);
    }
    if (filter.to) {
      const toTs = Number(filter.to);
      list = list.filter((r) => (r.redeemedAt || r.reservedAt || r.createdAt) <= toTs);
    }

    return list
      .sort((a, b) => (Number(b.redeemedAt || b.reservedAt || b.createdAt) || 0) - (Number(a.redeemedAt || a.reservedAt || a.createdAt) || 0))
      .slice(0, limit);
  }

  /**
   * Safe transaction reservation of a coupon slot (15 min TTL).
   * Prevents concurrency race conditions without permanently consuming slot on payment abandonment.
   */
  async reserveCouponSlot(rawCode, { userId, orderId, category, categoryName, originalPrice, discountAmount, finalAmount, userDoc = null }) {
    const coupon = await this.findCoupon(rawCode);
    if (!coupon) return { reserved: false, error: 'Coupon not found' };

    const now = Date.now();
    const ttlMs = 15 * 60 * 1000;

    // Fetch active reservations for this coupon
    let allRedemptions = await this.listCouponRedemptions({ couponCode: coupon.code }, 1000);
    // A rider who closed the payment page and tries again must not be refused by their own earlier,
    // unpaid hold of the same code: that hold is released (if the old order is paid after all, its
    // confirmation still counts the redemption).
    if (userId) {
      const ownHolds = allRedemptions.filter((r) => r.userId === userId && r.status === 'RESERVED' && r.orderId !== orderId);
      for (const r of ownHolds) {
        await this.saveCouponRedemption({ ...r, status: 'CANCELLED', cancelledAt: now, cancelReason: 'SUPERSEDED' });
      }
      if (ownHolds.length) allRedemptions = allRedemptions.filter((r) => !ownHolds.includes(r));
    }
    const activeReservations = allRedemptions.filter((r) => r.status === 'RESERVED' && r.expiresAt > now && r.orderId !== orderId);

    const totalInFlightOrUsed = (coupon.usageCount || 0) + activeReservations.length;
    if (coupon.maxUsageTotal > 0 && totalInFlightOrUsed >= coupon.maxUsageTotal) {
      return { reserved: false, error: 'This coupon has reached its maximum total redemptions limit' };
    }

    if (userId) {
      const userRedemptions = allRedemptions.filter((r) => r.userId === userId && (r.status === 'SUCCESS' || (r.status === 'RESERVED' && r.expiresAt > now && r.orderId !== orderId)));
      const maxPerUser = Number(coupon.maxUsagePerUser) || 1;
      if (userRedemptions.length >= maxPerUser) {
        return { reserved: false, error: `You have already redeemed this coupon (limit ${maxPerUser} per rider)` };
      }
    }

    const redemptionId = `red_${now.toString(36)}_${require('crypto').randomBytes(4).toString('hex')}`;
    const redemptionDoc = {
      redemptionId,
      couponCode: coupon.code,
      campaignName: coupon.campaignName || coupon.name || coupon.code,
      userId: userId || 'guest',
      userName: userDoc?.name || 'Rider',
      userEmail: userDoc?.email || '',
      userPhone: userDoc?.phone || '',
      category: category || 'individual',
      categoryName: categoryName || category || 'individual',
      originalPrice: Number(originalPrice) || 0,
      discountAmount: Number(discountAmount) || 0,
      finalAmount: Number(finalAmount) || 0,
      orderId: orderId || '',
      paymentId: null,
      status: finalAmount === 0 ? 'SUCCESS' : 'RESERVED',
      isFree: finalAmount === 0,
      reservedAt: now,
      expiresAt: now + ttlMs,
      redeemedAt: finalAmount === 0 ? now : null,
      activatedAt: finalAmount === 0 ? now : null,
      createdAt: now,
    };

    await this.saveCouponRedemption(redemptionDoc);

    if (finalAmount === 0) {
      // Free activation completes immediately
      await this.recordCouponUsage(coupon.code, { userId, orderId, discountAmount });
    }

    return { reserved: true, redemption: redemptionDoc };
  }

  /**
   * Finalizes coupon redemption when payment succeeds.
   */
  async confirmCouponRedemption(orderId, { paymentId, method = 'RAZORPAY', paidAt = Date.now(), userDoc = null }) {
    if (!orderId) return null;
    let existing = await this.findCouponRedemptionByOrderId(orderId);
    if (!existing) {
      const rzp = await this.findRazorpayOrder(orderId);
      if (rzp?.internalOrderId) {
        existing = await this.findCouponRedemptionByOrderId(rzp.internalOrderId);
      }
      if (!existing && rzp?.offerCode) {
        const coupon = await this.findCoupon(rzp.offerCode);
        if (coupon) {
          const discountAmt = Number(rzp.discountAmount) || 0;
          const plans = await this._membershipPlanMeta();
          existing = {
            redemptionId: `red_${Date.now().toString(36)}_${require('crypto').randomBytes(4).toString('hex')}`,
            couponCode: coupon.code,
            campaignName: coupon.campaignName || coupon.name || coupon.code,
            userId: rzp.userId || 'guest',
            userName: userDoc?.name || 'Rider',
            userEmail: userDoc?.email || '',
            userPhone: userDoc?.phone || '',
            category: rzp.category || 'individual',
            categoryName: plans[rzp.category] ? plans[rzp.category].name : (rzp.category || 'individual'),
            originalPrice: this._orderOriginalPrice(rzp, plans),
            discountAmount: discountAmt || (rzp.isFree ? this._orderOriginalPrice(rzp, plans) : 0),
            finalAmount: (Number(rzp.amountInPaise) || 0) / 100,
            orderId,
            status: 'SUCCESS',
            isFree: Boolean(rzp.isFree),
            reservedAt: paidAt,
            expiresAt: paidAt + 15 * 60 * 1000,
            redeemedAt: paidAt,
            activatedAt: paidAt,
            createdAt: Date.now(),
          };
          await this.saveCouponRedemption(existing);
          await this.recordCouponUsage(coupon.code, { userId: rzp.userId, orderId, discountAmount: discountAmt });
          return existing;
        }
      }
    }
    if (!existing) return null;

    const updated = {
      ...existing,
      status: 'SUCCESS',
      paymentId: paymentId || existing.paymentId || '',
      method,
      paidAt,
      redeemedAt: paidAt,
      activatedAt: paidAt,
      updatedAt: Date.now(),
    };
    if (userDoc) {
      if (userDoc.name) updated.userName = userDoc.name;
      if (userDoc.email) updated.userEmail = userDoc.email;
      if (userDoc.phone) updated.userPhone = userDoc.phone;
    }
    await this.saveCouponRedemption(updated);

    // Increment coupon usage count
    await this.recordCouponUsage(existing.couponCode, {
      userId: existing.userId,
      orderId: existing.orderId,
      discountAmount: existing.discountAmount,
    });

    return updated;
  }

  /**
   * Releases reserved slot if user cancels or order fails.
   */
  async releaseCouponReservation(orderId) {
    if (!orderId) return false;
    const existing = await this.findCouponRedemptionByOrderId(orderId);
    if (existing && existing.status === 'RESERVED') {
      await this.saveCouponRedemption({
        ...existing,
        status: 'CANCELLED',
        cancelledAt: Date.now(),
        updatedAt: Date.now(),
      });
      return true;
    }
    return false;
  }

  async recordCouponUsage(rawCode, { userId, orderId, discountAmount }) {
    const code = String(rawCode).trim().toUpperCase();
    const coupon = await this.findCoupon(code);
    if (!coupon) return null;
    const usages = Array.isArray(coupon.usages) ? [...coupon.usages] : [];
    usages.push({
      userId: userId || 'guest',
      orderId: orderId || '',
      discountAmount: Number(discountAmount) || 0,
      usedAt: Date.now(),
    });
    const nextUsageCount = (coupon.usageCount || 0) + 1;
    let nextStatus = coupon.status;
    if (coupon.maxUsageTotal > 0 && nextUsageCount >= coupon.maxUsageTotal) {
      nextStatus = 'USAGE_LIMIT_REACHED';
    }
    const updated = {
      ...coupon,
      usageCount: nextUsageCount,
      status: nextStatus,
      usages,
      updatedAt: Date.now(),
    };
    delete updated.key;
    await this.soda.upsertBy(C.coupons, { code }, updated);
    return updated;
  }

  // ---------- payments analytics & searchable transaction history ----------

  /**
   * Name, monthly price and seat capacity of every membership plan, from the stored catalog
   * (or its built-in defaults when an admin never saved one). Prices are never hard-coded here.
   */
  async _membershipPlanMeta() {
    const catalog = await this.getMembershipCatalog().catch(() => ({}));
    const out = {};
    for (const [id, c] of Object.entries(catalog || {})) {
      if (!c || typeof c !== 'object') continue;
      out[id] = { id, name: c.name || id, priceInr: Number(c.monthlyPriceInr) || 0, capacity: Number(c.capacity) || 1 };
    }
    return out;
  }

  /**
   * The pre-discount price of an order in rupees: recorded on the order, else amount + recorded
   * discount, else the plan's current catalog price, else what was charged.
   */
  _orderOriginalPrice(o, plans) {
    if (Number(o.originalPrice) > 0) return Number(o.originalPrice);
    const amountInr = (Number(o.amountInPaise) || 0) / 100;
    const discount = Number(o.discountAmount) || 0;
    if (discount > 0) return amountInr + discount;
    const plan = o.category ? plans[o.category] : null;
    return plan ? plan.priceInr : amountInr;
  }

  async getMembershipPaymentAnalytics({ range = '30d', from, to } = {}) {
    const now = Date.now();
    let startTime = now - 30 * 86400000;
    let endTime = now;

    if (range === 'today') {
      // Asia/Kolkata day start: UTC+5:30 = 19800000 ms
      const kolkataOffset = 5.5 * 3600000;
      const localNow = new Date(now + kolkataOffset);
      localNow.setUTCHours(0, 0, 0, 0);
      startTime = localNow.getTime() - kolkataOffset;
    } else if (range === '7d') {
      startTime = now - 7 * 86400000;
    } else if (range === '30d') {
      startTime = now - 30 * 86400000;
    } else if (range === 'this_month') {
      const d = new Date(now);
      d.setDate(1); d.setHours(0, 0, 0, 0);
      startTime = d.getTime();
    } else if (range === 'last_month') {
      const d = new Date(now);
      d.setDate(1); d.setHours(0, 0, 0, 0);
      endTime = d.getTime();
      d.setMonth(d.getMonth() - 1);
      startTime = d.getTime();
    } else if (range === 'custom') {
      if (from) startTime = Number(from);
      if (to) endTime = Number(to);
    }

    // Staff accounts (admins, STAFF_EMAILS) are left out of every figure; their paid orders are reported apart.
    const staffIds = await this.staffUserIds().catch(() => new Set());
    const isStaffId = (id) => !!id && staffIds.has(id);
    const allOrders = await this.listRazorpayOrders({}, 5000);
    const allMemberships = (await this.soda.query(C.memberships, {}, { limit: 5000 }).then((r) => r.map((x) => x.value)).catch(() => []))
      .filter((m) => !isStaffId(m.ownerUserId));
    const redemptions = (await this.listCouponRedemptions({}, 5000)).filter((r) => !isStaffId(r.userId));

    const inRange = (o) => {
      const ts = Number(o.paidAt || o.createdAt) || 0;
      return ts >= startTime && ts <= endTime;
    };
    const staffRangeOrders = allOrders.filter((o) => inRange(o) && isStaffId(o.userId));
    const rangeOrders = allOrders.filter((o) => inRange(o) && !isStaffId(o.userId));
    const staffPaid = staffRangeOrders.filter((o) => String(o.status || '').toUpperCase() === 'PAID' && (Number(o.amountInPaise) || 0) > 0);

    let grossSalesInr = 0;
    let discountsInr = 0;
    let netRevenueInr = 0;
    let paidOrdersCount = 0;
    let failedOrdersCount = 0;
    let refundedAmountInr = 0;
    let refundedOrdersCount = 0;

    const plans = await this._membershipPlanMeta();
    const byPlan = {};
    // The three standard plans always appear (the dashboard reads them); any extra catalog plan is added.
    for (const id of new Set(['individual', 'group_small', 'group_large', ...Object.keys(plans)])) {
      const p = plans[id] || { id, name: id, priceInr: 0 };
      byPlan[id] = { id, name: p.name, priceInr: p.priceInr, units: 0, grossInr: 0, discountsInr: 0, netInr: 0, activeMembers: 0 };
    }

    // Calculate active members per plan, seat utilization, and MRR
    let totalMRR = 0;
    let totalSeatsAllocated = 0;
    let totalSeatsOccupied = 0;

    for (const m of allMemberships) {
      if (m.status === 'ACTIVE' && (m.validUntil || 0) > now) {
        const cat = m.category || 'individual';
        if (byPlan[cat]) {
          byPlan[cat].activeMembers++;
        }
        const plan = plans[cat];
        totalMRR += Number(m.priceInr) || (plan ? plan.priceInr : 0);
        totalSeatsAllocated += Number(m.capacity) || (plan ? plan.capacity : 1);
        totalSeatsOccupied += 1 + Object.keys(m.members || {}).length;
      }
    }

    const activeTripsList = await this.soda.query(C.activeTrips, {}, { limit: 5000 }).catch(() => []);

    const dayBuckets = new Map();
    // Pre-populate daily timeline points
    for (let t = startTime; t <= endTime; t += 86400000) {
      const dayStr = new Date(t).toISOString().slice(0, 10);
      dayBuckets.set(dayStr, { date: dayStr, grossInr: 0, discountsInr: 0, netInr: 0, orders: 0 });
    }

    let freeActivationsCount = 0;
    for (const o of rangeOrders) {
      const status = (o.status || '').toUpperCase();
      const amountPaise = Number(o.amountInPaise) || 0;
      const orderAmountInr = amountPaise / 100;
      const isFreeOrder = Boolean(o.isFree) || orderAmountInr === 0;
      const cat = o.category || null;
      const catalogPrice = this._orderOriginalPrice(o, plans);
      const discount = Number(o.discountAmount) || Math.max(0, catalogPrice - orderAmountInr);

      if (status === 'FAILED' || status === 'SIGNATURE_MISMATCH') {
        failedOrdersCount++;
      } else if (status === 'PAID') {
        if (isFreeOrder) {
          freeActivationsCount++;
          // Free activations are recorded separately and do not inflate gross or net monetary revenue
        } else {
          paidOrdersCount++;
          grossSalesInr += catalogPrice;
          discountsInr += discount;
          const netOrder = Math.max(0, orderAmountInr);
          netRevenueInr += netOrder;

        if (byPlan[cat]) {
          byPlan[cat].units++;
          byPlan[cat].grossInr += catalogPrice;
          byPlan[cat].discountsInr += discount;
          byPlan[cat].netInr += netOrder;
        }

        const refundPaise = Number(o.refundedAmountInPaise) || (Number(o.refundedAmount) * 100) || 0;
        if (refundPaise > 0) {
          refundedOrdersCount++;
          const refundInr = refundPaise / 100;
          refundedAmountInr += refundInr;
          netRevenueInr -= refundInr;
          if (byPlan[cat]) byPlan[cat].netInr -= refundInr;
        }

        const dayStr = new Date(Number(o.paidAt || o.createdAt)).toISOString().slice(0, 10);
        const b = dayBuckets.get(dayStr) || { date: dayStr, grossInr: 0, discountsInr: 0, netInr: 0, orders: 0 };
        b.grossInr += catalogPrice;
        b.discountsInr += discount;
        b.netInr += netOrder;
        b.orders++;
        dayBuckets.set(dayStr, b);
        }
      }
    }

    // Coupon ROI analytics
    const couponStats = new Map();
    const rangeRedemptions = redemptions.filter((r) => {
      const ts = Number(r.redeemedAt || r.reservedAt || r.createdAt) || 0;
      return ts >= startTime && ts <= endTime && r.status === 'SUCCESS';
    });

    let totalCouponDiscount = 0;
    let totalCouponNetRevenue = 0;

    for (const r of rangeRedemptions) {
      const cCode = r.couponCode || 'UNKNOWN';
      const cStat = couponStats.get(cCode) || {
        code: cCode,
        campaignName: r.campaignName || cCode,
        redemptions: 0,
        discountAmount: 0,
        netRevenue: 0,
        users: new Set(),
      };
      cStat.redemptions++;
      cStat.discountAmount += (Number(r.discountAmount) || 0);
      cStat.netRevenue += (Number(r.finalAmount) || 0);
      if (r.userId) cStat.users.add(r.userId);
      couponStats.set(cCode, cStat);

      totalCouponDiscount += (Number(r.discountAmount) || 0);
      totalCouponNetRevenue += (Number(r.finalAmount) || 0);
    }

    const topCoupons = Array.from(couponStats.values()).map((c) => ({
      code: c.code,
      campaignName: c.campaignName,
      redemptions: c.redemptions,
      uniqueUsers: c.users.size,
      discountAmount: Math.round(c.discountAmount * 100) / 100,
      netRevenue: Math.round(c.netRevenue * 100) / 100,
    })).sort((a, b) => b.redemptions - a.redemptions);

    // New memberships created in this window
    const newMembershipsCount = allMemberships.filter((m) => {
      const ts = Number(m.createdAt || m.validFrom) || 0;
      return ts >= startTime && ts <= endTime;
    }).length;

    const averageOrderValue = paidOrdersCount > 0 ? Math.round((netRevenueInr / paidOrdersCount) * 100) / 100 : 0;

    const totalActiveMembers = byPlan.individual.activeMembers + byPlan.group_small.activeMembers + byPlan.group_large.activeMembers;
    return {
      range,
      startTime,
      endTime,
      summary: {
        grossSalesInr: Math.round(grossSalesInr * 100) / 100,
        discountsInr: Math.round(discountsInr * 100) / 100,
        netRevenueInr: Math.round(netRevenueInr * 100) / 100,
        totalTransactions: rangeOrders.length,
        paidOrders: paidOrdersCount,
        freeActivations: freeActivationsCount,
        failedOrders: failedOrdersCount,
        refundedAmountInr: Math.round(refundedAmountInr * 100) / 100,
        refundedOrders: refundedOrdersCount,
        activeMemberships: totalActiveMembers,
        newMemberships: newMembershipsCount,
        averageOrderValueInr: averageOrderValue,
        excludesStaff: true,
        staffOrders: staffRangeOrders.length,
        staffPaidOrders: staffPaid.length,
        staffAmountInr: Math.round(staffPaid.reduce((s, o) => s + (Number(o.amountInPaise) || 0) / 100, 0) * 100) / 100,
      },
      activeMemberships: {
        individual: byPlan.individual.activeMembers,
        groupSmall: byPlan.group_small.activeMembers,
        groupLarge: byPlan.group_large.activeMembers,
        total: totalActiveMembers,
      },
      seatUtilization: {
        totalAllocated: totalSeatsAllocated,
        totalOccupied: totalSeatsOccupied,
        utilizationRate: totalSeatsAllocated > 0 ? (totalSeatsOccupied / totalSeatsAllocated).toFixed(2) : 0,
      },
      financialMetrics: {
        estimatedMRR: totalMRR,
        grossSales: Math.round(grossSalesInr * 100) / 100,
        netRevenue: Math.round(netRevenueInr * 100) / 100,
        currency: 'INR',
      },
      concurrency: {
        currentActiveTrips: activeTripsList.length,
      },
      byPlan,
      couponAnalytics: {
        totalRedemptions: rangeRedemptions.length,
        totalDiscountGivenInr: Math.round(totalCouponDiscount * 100) / 100,
        netRevenueFromCouponsInr: Math.round(totalCouponNetRevenue * 100) / 100,
        topCoupons,
      },
      timeline: Array.from(dayBuckets.values()).sort((a, b) => a.date.localeCompare(b.date)),
      timestamp: now,
    };
  }

  /**
   * Searchable and filterable payment transaction history.
   * Strips payment gateway secrets, CVVs, and private keys.
   */
  async listTransactions({ search = '', status = 'ALL', category = '', from, to, limit = 100, cursor = 0 } = {}) {
    const orders = await this.listRazorpayOrders({}, 5000);
    const users = await this.soda.query(C.users, {}, { limit: 5000 }).then((r) => r.map((x) => x.value)).catch(() => []);
    const userMap = new Map(users.map((u) => [u.userId, u]));
    const plans = await this._membershipPlanMeta();
    const subscriptionPricing = await this.getSubscriptionPricing().catch(() => null);

    let list = orders.map((o) => {
      const u = userMap.get(o.userId) || {};
      const amountInr = (Number(o.amountInPaise) || 0) / 100;
      const refundedInr = (Number(o.refundedAmountInPaise) || 0) / 100 || (Number(o.refundedAmount) || 0);
      return {
        orderId: o.orderId || '',
        internalOrderId: o.internalOrderId || '',
        paymentId: o.paymentId || '',
        userId: o.userId || '',
        userName: u.name || o.userName || 'Rider',
        userEmail: u.email || o.userEmail || '',
        userPhone: u.phone || o.userPhone || '',
        // Paid by a staff account (admin / STAFF_EMAILS): a checkout test, kept out of the analytics.
        staff: !!o.userId && u.provider !== 'guest' && isStaffAccount(u),
        category: o.category || o.planTier || 'individual',
        categoryName: o.category
          ? (plans[o.category] ? plans[o.category].name : o.category)
          : (o.planTier ? ((subscriptionPricing && subscriptionPricing[o.planTier] && subscriptionPricing[o.planTier].label) || o.planTier) : 'Individual'),
        amountInr,
        originalPrice: this._orderOriginalPrice(o, plans),
        discountAmount: Number(o.discountAmount) || 0,
        offerCode: o.offerCode || null,
        status: String(o.status || 'CREATED').toUpperCase(),
        transactionType: o.transactionType || (o.isFree || amountInr === 0 ? 'COUPON_ACTIVATION' : 'NEW'),
        mode: o.mode || (o.isFree || amountInr === 0 ? 'free' : 'live'),
        isFree: Boolean(o.isFree) || amountInr === 0,
        method: o.method || (o.isFree || amountInr === 0 ? 'COUPON' : 'RAZORPAY'),
        createdAt: Number(o.createdAt) || 0,
        paidAt: Number(o.paidAt) || 0,
        refundStatus: o.refundStatus || null,
        refundedAmount: refundedInr,
        refundReason: o.refundReason || null,
        failureReason: o.failureReason || null,
        failureCode: o.failureCode || null,
      };
    });

    if (status && status !== 'ALL') {
      const matchStatus = status.toUpperCase();
      list = list.filter((t) => t.status === matchStatus);
    }

    if (category) {
      list = list.filter((t) => t.category === category);
    }

    if (from) {
      const fromTs = Number(from);
      list = list.filter((t) => (t.paidAt || t.createdAt) >= fromTs);
    }

    if (to) {
      const toTs = Number(to);
      list = list.filter((t) => (t.paidAt || t.createdAt) <= toTs);
    }

    if (search && search.trim()) {
      const q = search.trim().toLowerCase();
      list = list.filter((t) =>
        t.orderId.toLowerCase().includes(q) ||
        t.paymentId.toLowerCase().includes(q) ||
        t.userId.toLowerCase().includes(q) ||
        t.userName.toLowerCase().includes(q) ||
        t.userEmail.toLowerCase().includes(q) ||
        t.userPhone.toLowerCase().includes(q) ||
        (t.offerCode && t.offerCode.toLowerCase().includes(q))
      );
    }

    list.sort((a, b) => (b.paidAt || b.createdAt) - (a.paidAt || a.createdAt));

    const offset = Math.max(0, parseInt(cursor, 10) || 0);
    const take = Math.min(200, Math.max(1, parseInt(limit, 10) || 100));
    const items = list.slice(offset, offset + take);

    return {
      transactions: items,
      total: list.length,
      limit: take,
      cursor: offset,
      nextCursor: offset + items.length < list.length ? offset + items.length : null,
    };
  }

  // ---------- memberships & commercial entities ----------
  /**
   * The plans: Community (free for every rider, solo rides, not sold), Small Group and Large Group
   * (paid; admin-editable price, seats, features, on sale). A stored catalog is read for those three
   * ids only (a stored retired 'individual' entry is ignored); a plan missing from it falls back to
   * its default. Community always stays free with one seat, whatever is stored.
   */
  async getMembershipCatalog() {
    const defaults = this._defaultMembershipCatalog();
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'membership_catalog' });
    const stored = r?.value?.catalog;
    if (!stored || typeof stored !== 'object') return defaults;
    const out = {};
    for (const id of Object.keys(defaults)) out[id] = stored[id] && typeof stored[id] === 'object' ? { ...stored[id], id } : defaults[id];
    out.community = {
      ...defaults.community,
      ...out.community,
      id: 'community', monthlyPriceInr: 0, capacity: 1, minCapacity: 1, maxCapacity: 1, purchasable: false, isActive: true,
      entitlements: defaults.community.entitlements,
    };
    return out;
  }

  _defaultMembershipCatalog() {
    return {
      community: {
        id: 'community',
        name: 'Community',
        monthlyPriceInr: 0,
        capacity: 1,
        minCapacity: 1,
        maxCapacity: 1,
        billingPeriodDays: 30,
        purchasable: false,
        isActive: true,
        features: ['Solo rides with live tracking', 'Guardian live link', 'SOS, crash detection and emergency texts', 'Medical ID', 'Fuel, fatigue and speed alerts', 'Offline maps and re-routing', 'Trip history and reports', 'Join any group ride for free'],
        entitlements: { ptt: false, convoy: false, groupSafety: false, personalTracking: true, basicNav: true, sharedTrip: false },
        description: 'Free for every rider: ride solo with every safety feature, and join friends\' group rides.',
      },
      group_small: {
        id: 'group_small',
        name: 'Small Group (2–6)',
        monthlyPriceInr: 49,
        capacity: 6,
        minCapacity: 2,
        maxCapacity: 6,
        billingPeriodDays: 30,
        features: ['convoy_tracking', 'group_trips', 'ptt_intercom', 'group_safety', 'shared_trips'],
        entitlements: { ptt: true, convoy: true, groupSafety: true, personalTracking: true, basicNav: true, sharedTrip: true },
        description: 'For small riding groups and clubs with up to 6 members.',
      },
      group_large: {
        id: 'group_large',
        name: 'Large Group (7–12)',
        monthlyPriceInr: 99,
        capacity: 12,
        minCapacity: 7,
        maxCapacity: 12,
        billingPeriodDays: 30,
        features: ['convoy_tracking', 'group_trips', 'ptt_intercom', 'group_safety', 'shared_trips'],
        entitlements: { ptt: true, convoy: true, groupSafety: true, personalTracking: true, basicNav: true, sharedTrip: true },
        description: 'For larger convoys and weekend expeditions with up to 12 members.',
      },
    };
  }

  async setMembershipCatalog(catalog, updatedBy = 'system') {
    return this.soda.upsertBy(C.subscriptionConfig, { k: 'membership_catalog' }, {
      k: 'membership_catalog',
      catalog,
      updatedAt: Date.now(),
      updatedBy,
    });
  }

  async findMembershipById(membershipId) {
    if (!membershipId) return null;
    const r = await this.soda.findOne(C.memberships, { membershipId: String(membershipId) });
    return r ? { ...r.value, key: r.key } : null;
  }

  async findMembershipByOwner(ownerUserId) {
    if (!ownerUserId) return null;
    const rows = await this.soda.query(C.memberships, { ownerUserId: String(ownerUserId) }, { limit: 50 });
    if (!rows || !rows.length) return null;
    const now = Date.now();
    // Prefer ACTIVE membership where validUntil > now, sorted by validUntil DESC
    const active = rows.map((r) => ({ ...r.value, key: r.key }))
      .filter((m) => m.status === 'ACTIVE' && (Number(m.validUntil) || 0) > now)
      .sort((a, b) => (Number(b.validUntil) || 0) - (Number(a.validUntil) || 0));
    if (active.length) return active[0];

    return null;
  }

  async findMembershipsForUser(userId) {
    if (!userId) return [];
    const uid = String(userId);
    const owned = await this.soda.query(C.memberships, { ownerUserId: uid }, { limit: 10 });
    const participant = await this.soda.query(C.memberships, { [`members.${uid}.status`]: 'ACCEPTED' }, { limit: 20 });
    const map = new Map();
    for (const r of [...owned, ...participant]) {
      map.set(r.value.membershipId, { ...r.value, key: r.key });
    }
    return Array.from(map.values());
  }

  async saveMembership(m) {
    if (!m?.membershipId) throw new Error('membershipId required');
    const doc = {
      ...m,
      membershipId: String(m.membershipId),
      upgradeHistory: Array.isArray(m.upgradeHistory) ? m.upgradeHistory : [],
      updatedAt: Date.now(),
    };
    delete doc.key;
    await this.soda.upsertBy(C.memberships, { membershipId: doc.membershipId }, doc);
    return doc;
  }

  async reconcileDuplicateMembershipsAndOrders() {
    const now = Date.now();
    const memberships = await this.soda.query(C.memberships, {}, { limit: 5000 }).catch(() => []);
    let membershipsAdjusted = 0;
    let paymentHistoryDeduplicated = 0;

    for (const row of memberships) {
      const m = row.value;
      if (m.status === 'ACTIVE') {
        if (m.validUntil > now + 35 * 86400000 && (m.offerApplied === 'RIDERFREE' || m.priceInr === 0)) {
          const correctedValidUntil = now + 30 * 86400000;
          await this.saveMembership({
            ...m,
            validUntil: correctedValidUntil,
            reconciledAt: now,
            reconcileNote: 'Corrected duplicate free coupon validity stacking',
          });
          membershipsAdjusted++;
        }
      }
    }

    const users = await this.soda.query(C.users, {}, { limit: 5000 }).catch(() => []);
    for (const uRow of users) {
      const u = uRow.value;
      let userUpdated = false;
      const updates = {};

      if (u.ownedMembership && u.ownedMembership.validUntil > now + 35 * 86400000 && (u.ownedMembership.offerApplied === 'RIDERFREE' || u.ownedMembership.priceInr === 0)) {
        updates.ownedMembership = {
          ...u.ownedMembership,
          validUntil: now + 30 * 86400000,
          reconciledAt: now,
          reconcileNote: 'Corrected duplicate free coupon validity stacking',
        };
        userUpdated = true;
      }

      if (Array.isArray(u.paymentHistory) && u.paymentHistory.length > 1) {
        const seenOrders = new Set();
        const deduplicated = [];
        for (const entry of u.paymentHistory) {
          const ordId = entry.orderId || `${entry.paidAt}_${entry.amountInr}`;
          if (!seenOrders.has(ordId)) {
            seenOrders.add(ordId);
            deduplicated.push(entry);
          }
        }
        if (deduplicated.length !== u.paymentHistory.length) {
          updates.paymentHistory = deduplicated;
          updates.lastPayment = deduplicated[deduplicated.length - 1];
          paymentHistoryDeduplicated += (u.paymentHistory.length - deduplicated.length);
          userUpdated = true;
        }
      }

      if (userUpdated) {
        await this.updateUser(uRow.key, updates);
      }
    }

    return {
      success: true,
      membershipsAdjusted,
      paymentHistoryDeduplicated,
      timestamp: now,
    };
  }

  // ---------- single active trip lock registry ----------
  async getActiveTrip(userId) {
    if (!userId) return null;
    const r = await this.soda.findOne(C.activeTrips, { userId: String(userId) });
    return r ? { ...r.value, key: r.key } : null;
  }

  async setActiveTrip(userId, { groupId, role, status = 'ACTIVE' }) {
    if (!userId || !groupId) throw new Error('userId and groupId required');
    const doc = {
      userId: String(userId),
      groupId: String(groupId),
      role: role || 'PARTICIPANT',
      status,
      lockedAt: Date.now(),
    };
    await this.soda.upsertBy(C.activeTrips, { userId: doc.userId }, doc);
    return doc;
  }

  async releaseActiveTrip(userId) {
    if (!userId) return false;
    return this.soda.removeWhere(C.activeTrips, { userId: String(userId) });
  }

  async releaseAllActiveTripsForGroup(groupId) {
    if (!groupId) return 0;
    return this.soda.removeWhere(C.activeTrips, { groupId: String(groupId) });
  }

  // ---------- public community stats & website metrics ----------
  async getCommunityStatsConfig() {
    const r = await this.soda.findOne(C.subscriptionConfig, { k: 'community_stats_config' }).catch(() => null);
    if (r?.value) return r.value;
    return {
      showPublicStats: true,
      showLongestTrips: true,
      showAnonymousLabels: true,
      labelPrefix: 'Rider',
    };
  }

  async setCommunityStatsConfig(config, updatedBy = 'admin') {
    const existing = await this.getCommunityStatsConfig();
    const doc = {
      ...existing,
      ...config,
      k: 'community_stats_config',
      updatedAt: Date.now(),
      updatedBy,
    };
    await this.soda.upsertBy(C.subscriptionConfig, { k: 'community_stats_config' }, doc);
    return doc;
  }

  async getCommunityStats() {
    const config = await this.getCommunityStatsConfig();
    if (config.showPublicStats === false) {
      return {
        enabled: false,
        message: 'Community statistics are currently private',
      };
    }

    // 1. Registered riders (staff accounts are not riders; guests are counted as before)
    const users = await this.soda.query(C.users, {}, { limit: 100000, fields: 'id' }).catch(() => []);
    const staffIds = await this.staffUserIds().catch(() => new Set());
    const totalRiders = Math.max(0, users.length - staffIds.size);

    // 2. Active riders
    const activeTripsList = await this.soda.query(C.activeTrips, {}, { limit: 10000 }).catch(() => []);
    const activeRiders = activeTripsList.filter((r) => !staffIds.has(r.value?.userId)).length;

    // 3. Completed trips and total verified distance
    const trips = await this.soda.query(C.trips, {}, { limit: 50000 }).catch(() => []);
    let totalKilometers = 0;
    for (const t of trips) {
      const val = t.value || {};
      const dist = Number(val.totalDistanceKm || (val.distanceM ? val.distanceM / 1000 : 0));
      if (dist > 0) totalKilometers += dist;
    }
    totalKilometers = Math.round(totalKilometers);

    // 4. Top 3 longest trips (anonymized, zero PII, zero raw coordinates)
    const longestTrips = [];
    if (config.showLongestTrips !== false) {
      const sortedTrips = trips
        .map((t) => t.value)
        .filter((t) => t && (Number(t.totalDistanceKm) > 0 || Number(t.distanceM) > 0))
        .sort((a, b) => {
          const distB = Number(b.totalDistanceKm || (b.distanceM ? b.distanceM / 1000 : 0));
          const distA = Number(a.totalDistanceKm || (a.distanceM ? a.distanceM / 1000 : 0));
          return distB - distA;
        })
        .slice(0, 3);

      sortedTrips.forEach((trip, idx) => {
        const distKm = Math.round(Number(trip.totalDistanceKm || (trip.distanceM ? trip.distanceM / 1000 : 0)));
        const durMs = (trip.endTimeEpochMs && trip.startTimeEpochMs)
          ? Math.max(0, trip.endTimeEpochMs - trip.startTimeEpochMs)
          : (trip.movingMs || 0);
        const hours = Math.floor(durMs / 3600000);
        const mins = Math.floor((durMs % 3600000) / 60000);
        const durationFormatted = hours > 0 ? `${hours}h ${mins}m` : `${mins > 0 ? mins : 1}m`;

        const label = config.showAnonymousLabels !== false
          ? `${config.labelPrefix || 'Rider'} #${idx + 1}`
          : 'CoRoute Rider';

        longestTrips.push({
          rank: idx + 1,
          distanceKm: distKm,
          durationFormatted,
          anonymousRiderLabel: label,
        });
      });
    }

    return {
      enabled: true,
      totalRiders,
      activeRiders,
      totalKilometers,
      longestTrips,
      lastUpdated: Date.now(),
    };
  }

  // ---------- post-trip feedback & community stories ----------
  // Trip reviews share the `feedback` collection with website contact messages; reviews are
  // the documents with a feedbackId. Rules (who may review, consent, moderation) live in
  // src/trip_reviews.js; this layer only stores and reads.
  async addTripFeedback(doc) {
    const feedbackId = doc.feedbackId || `FB-${Date.now()}-${Math.random().toString(36).slice(2, 8).toUpperCase()}`;
    const photos = Array.isArray(doc.photos) ? doc.photos.slice(0, 5) : (doc.photoUrl ? [doc.photoUrl] : []);
    const entry = {
      ...doc,
      feedbackId,
      photos,
      photoUrl: photos[0] || null,
      status: doc.status || 'PENDING_REVIEW',
      submittedAt: doc.submittedAt || Date.now(),
      reviewHistory: doc.reviewHistory || [],
    };
    delete entry.key;
    await this.soda.upsertBy(C.feedback, { feedbackId }, entry);
    return entry;
  }

  async getTripFeedback(feedbackId) {
    const r = await this.soda.findOne(C.feedback, { feedbackId: String(feedbackId) });
    return r ? { ...r.value, key: r.key } : null;
  }

  /** The rider's review of a trip (one per rider per trip), or null. */
  async findTripFeedbackFor(tripId, userId) {
    const rows = await this.soda.query(C.feedback, { tripId: String(tripId), userId: String(userId) }, { limit: 5 });
    const found = rows.map((r) => ({ ...r.value, key: r.key })).filter((v) => v.feedbackId);
    found.sort((a, b) => (b.updatedAt || b.submittedAt || 0) - (a.updatedAt || a.submittedAt || 0));
    return found[0] || null;
  }

  /** Trip reviews (not website contact messages), newest first; optional exact status. */
  async listTripFeedback(limit = 200, status = null) {
    const filter = status ? { status: String(status), feedbackId: { $exists: true } } : { feedbackId: { $exists: true } };
    const rows = await this.soda.query(C.feedback, filter, {
      orderBy: [{ path: 'submittedAt', datatype: 'number', order: 'desc' }],
      limit,
    }).catch(() => []);
    return rows.map((r) => ({ ...r.value, key: r.key }));
  }

  /**
   * Approved reviews as stored (newest submission first). Never invented: an empty list
   * when nothing is approved. Consent checks and the public shape are in trip_reviews.js.
   */
  async listApprovedStories(limit = 10) {
    const rows = await this.soda.query(C.feedback, { status: 'APPROVED', feedbackId: { $exists: true } }, {
      orderBy: [{ path: 'submittedAt', datatype: 'number', order: 'desc' }],
      limit,
    }).catch(() => []);
    return rows.map((r) => r.value || {}).filter((v) => v.feedbackId);
  }

  /**
   * Applies an admin decision. [patch] holds the already validated values; [historyEntry]
   * is appended to reviewHistory (the audit trail kept with the review).
   */
  async updateTripFeedbackReview(feedbackId, patch = {}, historyEntry = null) {
    // Older callers passed { action, adminNotes, formattedText, templateLayout, selectedPhotos, by }.
    if (patch && patch.action && !historyEntry) {
      const map = { APPROVE: 'APPROVED', REJECT: 'REJECTED', REQUEST_CLARIFICATION: 'CHANGES_REQUESTED', REQUEST_CHANGES: 'CHANGES_REQUESTED', WITHDRAW: 'WITHDRAWN' };
      const { action, adminNotes, by, ...rest } = patch;
      historyEntry = { action, adminNotes: adminNotes || '', by: by || 'admin', at: Date.now() };
      patch = { ...rest };
      if (map[action]) patch.status = map[action];
      for (const k of Object.keys(patch)) if (patch[k] === undefined) delete patch[k];
    }
    const r = await this.soda.findOne(C.feedback, { feedbackId: String(feedbackId) });
    if (!r) return null;
    const current = r.value;
    const next = {
      ...current,
      ...patch,
      reviewHistory: historyEntry ? [...(current.reviewHistory || []), historyEntry].slice(-100) : (current.reviewHistory || []),
      updatedAt: Date.now(),
    };
    delete next.key;
    await this.soda.replace(C.feedback, r.key, next);
    return next;
  }

  // ---------- device diagnostics & compatibility ----------
  async submitDiagnostic(doc) {
    const diagnosticId = doc.diagnosticId || `DIAG-${Date.now()}-${Math.random().toString(36).slice(2, 8).toUpperCase()}`;
    // Safe retry / idempotency check: if report with same diagnosticId already exists, return existing status
    const existing = await this.soda.findOne(C.diagnostics, { diagnosticId });
    if (existing) {
      return { ok: true, diagnosticId, status: existing.value?.lifecycleStatus || 'Submitted' };
    }

    // Rate limiting: max 5 submissions/day/rider
    const riderId = doc.riderId || doc.riderEmail;
    if (riderId) {
      const dayAgo = Date.now() - 24 * 60 * 60 * 1000;
      const recent = await this.soda.query(C.diagnostics, { riderId }, { limit: 50 }).catch(() => []);
      const countLast24h = recent.filter((r) => (r.value?.timestamp || r.value?.createdAt || 0) > dayAgo).length;
      if (countLast24h >= 5) {
        const err = new Error('Rate limit exceeded: max 5 diagnostic submissions per day per rider.');
        err.statusCode = 429;
        throw err;
      }
    }

    const entry = {
      ...doc,
      diagnosticId,
      lifecycleStatus: doc.lifecycleStatus || 'Submitted',
      submittedAt: Date.now(),
      createdAt: doc.createdAt || doc.timestamp || Date.now(),
      updatedAt: Date.now(),
      reviewHistory: doc.reviewHistory || [],
    };
    await this.soda.upsertBy(C.diagnostics, { diagnosticId }, entry);
    return { ok: true, diagnosticId, status: entry.lifecycleStatus };
  }

  async getDiagnostic(diagnosticId) {
    const r = await this.soda.findOne(C.diagnostics, { diagnosticId: String(diagnosticId) });
    return r ? { ...r.value, key: r.key } : null;
  }

  async listDiagnostics({ page = 1, limit = 20, manufacturer, overallStatus, status, search } = {}) {
    const lim = Math.max(1, Math.min(100, parseInt(limit, 10) || 20));
    const p = Math.max(1, parseInt(page, 10) || 1);
    const rows = await this.soda.query(C.diagnostics, {}, {
      orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }],
      limit: 1000,
    }).catch(() => []);

    let items = rows.map((r) => ({ ...r.value, key: r.key }));

    if (manufacturer) {
      const mfgLower = String(manufacturer).toLowerCase();
      items = items.filter((d) => (d.deviceInfo?.manufacturer || '').toLowerCase().includes(mfgLower));
    }
    if (overallStatus) {
      const ovLower = String(overallStatus).toLowerCase();
      items = items.filter((d) => (d.overallResult || '').toLowerCase() === ovLower);
    }
    if (status) {
      const stLower = String(status).toLowerCase();
      items = items.filter((d) => (d.lifecycleStatus || '').toLowerCase() === stLower);
    }
    if (search) {
      const q = String(search).toLowerCase();
      items = items.filter((d) =>
        (d.riderEmail || '').toLowerCase().includes(q) ||
        (d.riderId || '').toLowerCase().includes(q) ||
        (d.diagnosticId || '').toLowerCase().includes(q) ||
        (d.deviceInfo?.manufacturer || '').toLowerCase().includes(q) ||
        (d.deviceInfo?.model || '').toLowerCase().includes(q)
      );
    }

    const total = items.length;
    const totalPages = Math.ceil(total / lim) || 1;
    const offset = (p - 1) * lim;
    const paginated = items.slice(offset, offset + lim);

    return {
      reports: paginated,
      pagination: {
        total,
        page: p,
        limit: lim,
        totalPages,
      },
    };
  }

  async getDiagnosticStats() {
    const rows = await this.soda.query(C.diagnostics, {}, { limit: 2000 }).catch(() => []);
    const reports = rows.map((r) => r.value || {});
    const totalReports = reports.length;

    let fullySupportedCount = 0;
    const mfgCounts = new Map();
    const failureCatCounts = new Map();
    const statusCounts = {
      Created: 0,
      Completed: 0,
      'Pending Submission': 0,
      Submitted: 0,
      Failed: 0,
      Reviewed: 0,
      Resolved: 0,
    };

    for (const rep of reports) {
      if (rep.overallResult === 'Fully supported') fullySupportedCount++;
      const mfg = rep.deviceInfo?.manufacturer || 'Unknown';
      mfgCounts.set(mfg, (mfgCounts.get(mfg) || 0) + 1);

      const st = rep.lifecycleStatus || 'Submitted';
      if (statusCounts[st] !== undefined) statusCounts[st]++;
      else statusCounts[st] = 1;

      if (rep.categories && typeof rep.categories === 'object') {
        for (const [catKey, catVal] of Object.entries(rep.categories)) {
          if (catVal && ['Failed', 'Unsupported', 'Limited', 'Permission Required'].includes(catVal.status)) {
            failureCatCounts.set(catKey, (failureCatCounts.get(catKey) || 0) + 1);
          }
        }
      }
    }

    const fullySupportedPercent = totalReports > 0
      ? Math.round((fullySupportedCount / totalReports) * 1000) / 10
      : 0;

    const topManufacturers = Array.from(mfgCounts.entries())
      .map(([manufacturer, count]) => ({
        manufacturer,
        count,
        percent: totalReports > 0 ? Math.round((count / totalReports) * 1000) / 10 : 0,
      }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 10);

    const topFailureCategories = Array.from(failureCatCounts.entries())
      .map(([category, failureCount]) => ({
        category,
        failureCount,
        percent: totalReports > 0 ? Math.round((failureCount / totalReports) * 1000) / 10 : 0,
      }))
      .sort((a, b) => b.failureCount - a.failureCount)
      .slice(0, 10);

    return {
      totalReports,
      fullySupportedCount,
      fullySupportedPercent,
      topManufacturers,
      topFailureCategories,
      statusCounts,
    };
  }

  async updateDiagnosticStatus(diagnosticId, { status, adminNotes, by }) {
    const r = await this.soda.findOne(C.diagnostics, { diagnosticId: String(diagnosticId) });
    if (!r) return null;

    const current = r.value || {};
    const validStatuses = ['Created', 'Completed', 'Pending Submission', 'Submitted', 'Failed', 'Reviewed', 'Resolved'];
    if (status && !validStatuses.includes(status)) {
      const err = new Error(`Invalid lifecycle status '${status}'. Valid statuses: ${validStatuses.join(', ')}`);
      err.statusCode = 400;
      throw err;
    }

    const nextStatus = status || current.lifecycleStatus || 'Submitted';
    const historyEntry = {
      action: nextStatus,
      adminNotes: adminNotes || '',
      by: by || 'admin',
      at: Date.now(),
    };

    const next = {
      ...current,
      lifecycleStatus: nextStatus,
      adminNotes: adminNotes !== undefined ? String(adminNotes).slice(0, 5000) : current.adminNotes,
      reviewHistory: [...(current.reviewHistory || []), historyEntry],
      updatedAt: Date.now(),
    };

    await this.soda.replace(C.diagnostics, r.key, next);
    return next;
  }
}

module.exports = { Repo, COLLECTIONS: C, ACTIVE_STATUSES, storableAlert };
