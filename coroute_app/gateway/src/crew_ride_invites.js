'use strict';
/**
 * 3.55 "Start a ride with this crew": the host of a live group ride invites chosen crew members
 * (docs/features_355/crews_polls.md, section "Crew rides"). Invitees accept (they join the ride
 * through the normal join logic, without the join code) or decline.
 *
 * registerCrewRideInviteRoutes({ r, repo, hub, convoys, wrap, flagsOf, ensureProfileComplete, push })
 * once, on the authenticated router, AFTER registerCrewRoutes (whose `r.use('/crews', ...)` gates the
 * /crews/* paths with the `crews` switch). Own switch: `crewRides`.
 *
 * Collection `ride_invites` (created on first use):
 *   { inviteId, inviteKey, groupId, crewId, fromUserId, toUserId, status, createdAt, expiresAt, answeredAt }
 *   status: PENDING | ACCEPTED | DECLINED | EXPIRED | CANCELLED. inviteKey = `<groupId>|<toUserId>`
 *   (one live invite per rider per ride). expiresAt = createdAt + 12 h; an invite also expires when
 *   the ride ends. Expiry is applied lazily on every read.
 *
 * Privacy: the join code never leaves the gateway on this path (accepting needs no code); views carry
 * usernames, first names, pictures, the crew and ride names and the start / destination NAMES only
 * (never coordinates, phone, e-mail or userIds). Pushes carry the inviteId only (and the texts).
 */
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');
const CR = require('./crews');
const F = require('./friends');
const U = require('./usernames');
const A = require('./avatars');
const { ConvoyError } = require('./convoys');

const COLL = 'ride_invites';
const HOUR = 3600000;
const LIMITS = Object.freeze({
  TTL_MS: 12 * HOUR,
  NAMES_PER_REQUEST: 50,
  REQUESTS_PER_HOUR: 30,
  INVITES_PER_DAY: 300,
});
const STATUS = Object.freeze({ PENDING: 'PENDING', ACCEPTED: 'ACCEPTED', DECLINED: 'DECLINED', EXPIRED: 'EXPIRED', CANCELLED: 'CANCELLED' });
const ACTIVE = ['PLANNING', 'STARTED', 'PAUSED'];
const INVITE_RE = /^ri_[a-f0-9]{16}$/;
const FEATURE_OFF = { error: 'This feature is turned off for now.', code: 'FEATURE_OFF' };
const NOT_FOUND = { error: 'Ride invite not found.', code: 'INVITE_NOT_FOUND' };
const CREW_NOT_FOUND = { error: 'Crew not found.', code: 'CREW_NOT_FOUND' };

const isInviteId = (v) => typeof v === 'string' && INVITE_RE.test(v);
const withKey = (r) => (r ? { ...r.value, key: r.key } : null);
const stripKey = ({ key, ...v }) => v; // eslint-disable-line no-unused-vars
const isConflict = (e) => e && (e.status === 409 || /unique|ORA-00001|duplicate/i.test(String(e.message || '')));
const firstName = (name) => String(name || '').trim().split(/\s+/)[0] || '';

const ensured = new WeakSet();
async function ensureStore(soda) {
  if (ensured.has(soda)) return;
  await soda.ensureCollection(COLL);
  const idx = (name, fields, unique = false) => soda.ensureIndex(COLL, { name, unique, fields: fields.map((path) => ({ path })) });
  await idx('ride_invites_id_ux', ['inviteId'], true);
  await idx('ride_invites_to_ix', ['toUserId']);
  await idx('ride_invites_from_ix', ['fromUserId']);
  await idx('ride_invites_group_ix', ['groupId']);
  ensured.add(soda);
}

/**
 * The effective status of an invite now (pure): a PENDING invite past expiresAt, or whose ride is
 * no longer active, is EXPIRED.
 */
function effectiveStatus(inv, { now = Date.now(), rideActive = true } = {}) {
  if (!inv) return null;
  if (inv.status !== STATUS.PENDING) return inv.status;
  if (inv.expiresAt <= now || !rideActive) return STATUS.EXPIRED;
  return STATUS.PENDING;
}

/** Usernames from a request body (pure): trimmed, without '@', unique (case ignored), capped. */
function cleanUsernames(raw) {
  const list = Array.isArray(raw) ? raw : (typeof raw === 'string' ? [raw] : []);
  const seen = new Set();
  const out = [];
  for (const v of list) {
    if (typeof v !== 'string') continue;
    const u = v.trim().replace(/^@/, '');
    if (!u || u.length > 40) continue;
    const k = u.toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(u);
  }
  return out;
}

/** The push / banner text (pure): usernames and names only. */
function inviteText({ hostUsername, rideName, crewName }) {
  const who = hostUsername || 'A rider';
  const ride = rideName || 'a ride';
  return { title: 'Ride invitation', body: crewName ? `${who} invited you to ${ride} with ${crewName}` : `${who} invited you to ${ride}` };
}

function registerCrewRideInviteRoutes({ r, repo, hub = null, convoys, wrap, flagsOf = () => null, ensureProfileComplete = null, push = null, now = () => Date.now() }) {
  const soda = repo.soda;
  const perUser = (req) => req.user?.userId || req.ip;
  const limiter = (windowMs, limit, message) => rateLimit({ windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: perUser, message: { error: message, code: 'RATE_LIMITED' } });
  const sendLimiter = limiter(HOUR, LIMITS.REQUESTS_PER_HOUR, 'Too many ride invites. Try again later.');
  const answerLimiter = limiter(60 * 1000, 30, 'Too many answers. Wait a minute.');
  const readLimiter = limiter(60 * 1000, 120, 'Too many requests. Wait a minute.');
  const sentToday = new Map(); // userId -> { day, n } (per node; the hourly limiter is the main brake)

  const isOn = (id) => { const fl = flagsOf(); return !fl || fl.isOn(id); };
  const feature = (req, res, next) => (isOn('crews') && isOn('crewRides')
    ? next()
    : res.status(403).set('Cache-Control', 'no-store').json({ ...FEATURE_OFF, feature: isOn('crews') ? 'crewRides' : 'crews' }));
  const pushOf = () => push || (hub && hub.push) || (convoys && convoys.push) || null;
  const socket = (userId, payload) => { try { if (hub) hub.sendToUser(userId, payload); } catch { /* best effort */ } };
  const avatarOf = (u) => (isOn('profilePhotos') ? A.avatarUrlOf(u && u.avatarId) : null);

  const userById = async (id) => {
    const u = id ? await repo.findUserById(id) : null;
    if (!u || u.username) return u;
    return U.ensureUsername(repo, u).catch(() => u);
  };
  const metaOf = async (groupId) => {
    if (typeof groupId !== 'string' || !/^GRP-[A-Za-z0-9_-]{2,40}$/.test(groupId)) return null;
    const live = convoys.rooms && convoys.rooms.get(groupId);
    if (live) return { meta: live.meta, room: live };
    const room = await convoys.getRoom(groupId, { required: false }).catch(() => null);
    return room ? { meta: room.meta, room } : null;
  };
  const ownerOf = (meta) => meta.tripOwnerUserId || meta.createdByUserId;
  const rideActive = (meta) => !!meta && ACTIVE.includes(meta.tripStatus);

  /** Stores the lazy expiry. */
  const settle = async (inv, meta) => {
    const st = effectiveStatus(inv, { now: now(), rideActive: rideActive(meta) });
    if (st !== inv.status) {
      const next = { ...stripKey(inv), status: st, answeredAt: now() };
      await soda.replace(COLL, inv.key, next).catch(() => {});
      return { ...next, key: inv.key };
    }
    return inv;
  };

  /** The invitee's view (no join code, no coordinates, no userIds). */
  const inviteeView = async (inv, meta, room) => {
    const [host, crew] = await Promise.all([userById(inv.fromUserId), CR.getCrew(soda, inv.crewId)]);
    return {
      inviteId: inv.inviteId, status: inv.status, createdAt: inv.createdAt, expiresAt: inv.expiresAt,
      host: { username: (host && host.username) || '', displayName: firstName(host && host.name), avatarUrl: avatarOf(host) },
      crew: { crewId: inv.crewId, name: (crew && crew.name) || '' },
      ride: meta ? {
        groupId: inv.groupId, name: meta.name || '',
        startName: meta.startLocationName || (meta.start && meta.start.name) || '',
        destinationName: meta.destinationName || '',
        startedAt: meta.createdAtEpochMs || 0,
        status: meta.tripStatus || 'ENDED',
        riders: room && room.riders ? room.riders.size : 0,
        capacity: convoys._storedCapacity ? convoys._storedCapacity(meta) : (meta.capacity || 0),
      } : null,
    };
  };

  /** The host's view of one invite (statuses). */
  const hostRow = (inv, u) => ({
    inviteId: inv.inviteId, username: (u && u.username) || '', displayName: firstName(u && u.name), avatarUrl: avatarOf(u),
    status: inv.status, createdAt: inv.createdAt, expiresAt: inv.expiresAt, answeredAt: inv.answeredAt || 0,
  });

  const invitesOfRide = async (groupId) => {
    await ensureStore(soda);
    return (await soda.query(COLL, { groupId }, { limit: 1000 })).map(withKey);
  };

  const hostList = async (groupId, crewId, meta) => {
    const rows = [];
    for (const inv of await invitesOfRide(groupId)) {
      if (crewId && inv.crewId !== crewId) continue;
      rows.push(await settle(inv, meta));
    }
    rows.sort((a, b) => b.createdAt - a.createdAt);
    const out = [];
    for (const inv of rows) out.push(hostRow(inv, await userById(inv.toUserId)));
    return out;
  };

  // ------------------------------------------------------------------ host: send invites
  /** POST /crews/:crewId/ride-invites {groupId, usernames[]} */
  r.post('/crews/:crewId/ride-invites', feature, sendLimiter, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const me = req.user.userId;
    const crewId = String(req.params.crewId || '');
    const crew = CR.isCrewId(crewId) ? await CR.getCrew(soda, crewId) : null;
    if (!crew || !(await CR.memberOf(soda, crewId, me))) return res.status(404).json(CREW_NOT_FOUND);
    const groupId = String(req.body?.groupId || '');
    const found = await metaOf(groupId);
    if (!found || ownerOf(found.meta) !== me) {
      return res.status(403).json({ error: 'Only the trip owner of this ride can invite riders to it.', code: 'NOT_RIDE_HOST' });
    }
    const { meta, room } = found;
    if (!rideActive(meta)) return res.status(409).json({ error: 'This ride has ended.', code: 'RIDE_ENDED' });
    // 3.56 access mode: crew ride invites left out of a hybrid free-tier ride.
    if (typeof convoys.rideFeatureOff === 'function' && convoys.rideFeatureOff(meta.groupId, ['crewRides'])) {
      return res.status(403).json({ error: "This isn't included in this ride.", code: 'GROUP_FEATURE_LOCKED', feature: 'crewRides' });
    }
    const names = cleanUsernames(req.body?.usernames ?? req.body?.username);
    if (!names.length) return res.status(422).json({ error: 'Pick at least one crew member.', code: 'NO_INVITEES' });
    if (names.length > LIMITS.NAMES_PER_REQUEST) {
      return res.status(422).json({ error: `Up to ${LIMITS.NAMES_PER_REQUEST} riders per invite.`, code: 'TOO_MANY_INVITEES' });
    }
    const day = Math.floor(now() / (24 * HOUR));
    const used = sentToday.get(me);
    const count = used && used.day === day ? used.n : 0;
    if (count + names.length > LIMITS.INVITES_PER_DAY) return res.status(429).json({ error: 'Too many ride invites today. Try again tomorrow.', code: 'RATE_LIMITED' });

    // Seats: the host's plan (convoys._currentCapacity), counting riders in the ride and invites waiting.
    const capacity = await convoys._currentCapacity(room);
    if (capacity <= 1) return res.status(409).json({ error: "This is a solo ride. Others can't join it.", code: 'SOLO_TRIP_ONLY' });
    const existing = (await invitesOfRide(groupId)).map((inv) => ({ inv, st: effectiveStatus(inv, { now: now(), rideActive: true }) }));
    let pending = existing.filter((x) => x.st === STATUS.PENDING && !room.riders.has(x.inv.toUserId)).length;

    const host = await userById(me);
    const text = inviteText({ hostUsername: host && host.username, rideName: meta.name, crewName: crew.name });
    const results = [];
    const notified = [];
    for (const username of names) {
      const target = await U.findUserByUsername(repo, username).catch(() => null);
      const tid = target && target.userId;
      // Same answer for unknown, not in this crew, blocked either way, suspended: no enumeration.
      if (!tid || target.status === 'BLOCKED' || !(await CR.memberOf(soda, crewId, tid)) || (tid !== me && await F.blockedEither(soda, me, tid))) {
        results.push({ username, status: 'NOT_A_MEMBER' }); continue;
      }
      const uname = target.username || username;
      if (tid === me || room.riders.has(tid)) { results.push({ username: uname, status: 'ALREADY_IN_RIDE' }); continue; }
      const prev = existing.find((x) => x.inv.toUserId === tid);
      if (prev && prev.st === STATUS.PENDING) { results.push({ username: uname, status: 'ALREADY_INVITED', inviteId: prev.inv.inviteId }); continue; }
      if (room.riders.size + pending >= capacity) { results.push({ username: uname, status: 'RIDE_FULL' }); continue; }
      const t = now();
      const invite = {
        inviteId: `ri_${crypto.randomBytes(8).toString('hex')}`, inviteKey: `${groupId}|${tid}`,
        groupId, crewId, fromUserId: me, toUserId: tid, status: STATUS.PENDING, createdAt: t, expiresAt: t + LIMITS.TTL_MS, answeredAt: 0,
      };
      try {
        if (prev) await soda.replace(COLL, prev.inv.key, invite);
        else await soda.insert(COLL, invite);
      } catch (e) {
        if (!isConflict(e)) throw e;
        results.push({ username: uname, status: 'ALREADY_INVITED' }); continue;
      }
      pending++;
      results.push({ username: uname, status: 'INVITED', inviteId: invite.inviteId });
      notified.push({ tid, invite });
    }
    sentToday.set(me, { day, n: count + notified.length });

    for (const { tid, invite } of notified) {
      socket(tid, {
        type: 'RIDE_INVITE', inviteId: invite.inviteId, crewId, crewName: crew.name, rideName: meta.name || '',
        username: (host && host.username) || '', expiresAt: invite.expiresAt,
        // Same id in the push below: the app shows one notice per eventId (push.stampEvent format).
        eventId: `RIDE_INVITE:${invite.inviteId}`,
      });
    }
    const p = pushOf();
    if (p && typeof p.notifyUsers === 'function') {
      // One push per invite (each carries its own inviteId). notifyUsers never throws; not awaited.
      for (const { tid, invite } of notified) {
        try {
          Promise.resolve(p.notifyUsers([tid], { type: 'RIDE_INVITE', title: text.title, body: text.body, data: { inviteId: invite.inviteId, eventId: `RIDE_INVITE:${invite.inviteId}` }, priority: 'high', ttlSec: 1800 })).catch(() => {});
        } catch { /* never breaks the request */ }
      }
    }
    res.status(notified.length ? 201 : 200).json({ results, invites: await hostList(groupId, crewId, meta), capacity, riders: room.riders.size });
  }));

  /** GET /crews/:crewId/ride-invites?groupId= — the host sees the statuses. */
  r.get('/crews/:crewId/ride-invites', feature, readLimiter, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const me = req.user.userId;
    const crewId = String(req.params.crewId || '');
    if (!CR.isCrewId(crewId) || !(await CR.memberOf(soda, crewId, me))) return res.status(404).json(CREW_NOT_FOUND);
    const found = await metaOf(String(req.query.groupId || ''));
    if (!found || ownerOf(found.meta) !== me) return res.status(403).json({ error: 'Only the trip owner of this ride can see its invites.', code: 'NOT_RIDE_HOST' });
    res.json({ invites: await hostList(found.meta.groupId, crewId, found.meta), rideActive: rideActive(found.meta) });
  }));

  /** DELETE /crews/:crewId/ride-invites/:inviteId — the host takes back a waiting invite. */
  r.delete('/crews/:crewId/ride-invites/:inviteId', feature, wrap(async (req, res) => {
    const me = req.user.userId;
    const inv = await byId(req.params.inviteId);
    if (!inv || inv.fromUserId !== me || inv.crewId !== String(req.params.crewId || '')) return res.status(404).json(NOT_FOUND);
    if (inv.status === STATUS.PENDING) {
      await soda.replace(COLL, inv.key, { ...stripKey(inv), status: STATUS.CANCELLED, answeredAt: now() });
      socket(inv.toUserId, { type: 'RIDE_INVITE_UPDATE', inviteId: inv.inviteId, status: STATUS.CANCELLED });
    }
    res.json({ ok: true });
  }));

  // ------------------------------------------------------------------ invitee
  const byId = async (id) => {
    if (!isInviteId(id)) return null;
    await ensureStore(soda);
    return withKey(await soda.findOne(COLL, { inviteId: id }));
  };

  /** GET /me/ride-invites — my pending, unexpired invites, newest first. */
  r.get('/me/ride-invites', feature, readLimiter, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    await ensureStore(soda);
    const rows = (await soda.query(COLL, { toUserId: req.user.userId }, { limit: 200 })).map(withKey);
    const out = [];
    for (const raw of rows) {
      if (raw.status !== STATUS.PENDING) continue;
      const found = await metaOf(raw.groupId);
      const inv = await settle(raw, found && found.meta);
      if (inv.status !== STATUS.PENDING) continue;
      if (found && found.room.riders.has(req.user.userId)) continue; // already riding in it
      out.push(await inviteeView(inv, found.meta, found.room));
    }
    out.sort((a, b) => b.createdAt - a.createdAt);
    res.json({ invites: out });
  }));

  /** GET /ride-invites/:inviteId — one invite (the invitee, or its host). */
  r.get('/ride-invites/:inviteId', feature, readLimiter, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const raw = await byId(req.params.inviteId);
    const me = req.user.userId;
    if (!raw || (raw.toUserId !== me && raw.fromUserId !== me)) return res.status(404).json(NOT_FOUND);
    const found = await metaOf(raw.groupId);
    const inv = await settle(raw, found && found.meta);
    res.json({ invite: await inviteeView(inv, found && found.meta, found && found.room) });
  }));

  const answered = (inv, status, username) => {
    socket(inv.fromUserId, { type: 'RIDE_INVITE_UPDATE', inviteId: inv.inviteId, crewId: inv.crewId, status, username: username || '' });
  };

  /** POST /ride-invites/:inviteId/accept {rider?} — joins the ride (normal join rules; no code needed). */
  r.post('/ride-invites/:inviteId/accept', feature, answerLimiter, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const me = req.user.userId;
    const raw = await byId(req.params.inviteId);
    if (!raw || raw.toUserId !== me) return res.status(404).json(NOT_FOUND);
    const found = await metaOf(raw.groupId);
    const inv = await settle(raw, found && found.meta);
    if (inv.status === STATUS.ACCEPTED && found && found.room.riders.has(me)) {
      return res.json({ status: STATUS.ACCEPTED, convoy: await convoys.getSnapshot(inv.groupId) });
    }
    if (inv.status === STATUS.EXPIRED) return res.status(410).json({ error: 'This ride invite has expired.', code: 'INVITE_EXPIRED' });
    if (inv.status !== STATUS.PENDING) return res.status(410).json({ error: 'This ride invite is no longer open.', code: 'INVITE_GONE' });
    // Still in the crew, both of them, and no block between them.
    const stillOk = await CR.memberOf(soda, inv.crewId, me) && await CR.memberOf(soda, inv.crewId, inv.fromUserId)
      && !(await F.blockedEither(soda, me, inv.fromUserId)) && ownerOf(found.meta) === inv.fromUserId;
    if (!stillOk) {
      await soda.replace(COLL, inv.key, { ...stripKey(inv), status: STATUS.CANCELLED, answeredAt: now() });
      return res.status(410).json({ error: 'This ride invite is no longer valid.', code: 'INVITE_GONE' });
    }
    if (ensureProfileComplete) await ensureProfileComplete(req);
    let snapshot;
    try {
      // The normal join: capacity of the host's plan, one active trip, removed riders, bike details.
      snapshot = await convoys.joinByCode(req.user, found.meta.joinCode, (req.body && req.body.rider) || {});
    } catch (e) {
      if (e instanceof ConvoyError) return res.status(e.status || 400).json({ error: e.message, reason: e.reason, code: e.reason || 'JOIN_FAILED' });
      throw e;
    }
    const fresh = await byId(inv.inviteId);
    if (fresh) await soda.replace(COLL, fresh.key, { ...stripKey(fresh), status: STATUS.ACCEPTED, answeredAt: now() });
    const meUser = await userById(me);
    answered(inv, STATUS.ACCEPTED, meUser && meUser.username);
    res.json({ status: STATUS.ACCEPTED, convoy: snapshot });
  }));

  /** POST /ride-invites/:inviteId/decline */
  r.post('/ride-invites/:inviteId/decline', feature, answerLimiter, wrap(async (req, res) => {
    const me = req.user.userId;
    const raw = await byId(req.params.inviteId);
    if (!raw || raw.toUserId !== me) return res.status(404).json(NOT_FOUND);
    const found = await metaOf(raw.groupId);
    const inv = await settle(raw, found && found.meta);
    if (inv.status === STATUS.PENDING) {
      await soda.replace(COLL, inv.key, { ...stripKey(inv), status: STATUS.DECLINED, answeredAt: now() });
      const meUser = await userById(me);
      answered(inv, STATUS.DECLINED, meUser && meUser.username);
    }
    res.json({ status: inv.status === STATUS.PENDING ? STATUS.DECLINED : inv.status });
  }));

  // Account erase: invites to and from the rider go with the account.
  if (!repo.__rideInvitesCascade && typeof repo.deleteUserCascade === 'function') {
    repo.__rideInvitesCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) {
        try {
          await ensureStore(soda);
          for (const field of ['toUserId', 'fromUserId']) {
            for (const row of await soda.query(COLL, { [field]: user.userId }, { limit: 2000 })) await soda.remove(COLL, row.key);
          }
        } catch { /* best effort */ }
      }
      return out;
    };
  }
}

module.exports = { registerCrewRideInviteRoutes, effectiveStatus, cleanUsernames, inviteText, LIMITS, STATUS, COLL };
