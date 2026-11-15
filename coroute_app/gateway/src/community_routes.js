'use strict';
/**
 * v3.60 communities (docs/features_355/communities_chat_v360.md). A community is a crew (crews.js) with:
 *   - visibility: public (anyone signed in can see it, its members, polls and rides, and join at once) or
 *     private (anyone can find its name, picture and size; joining is a request the admin or a co-admin approves);
 *   - a picture (same cleaner and storage as profile pictures, src/avatars.js; served by /avatars/:id);
 *   - hosted rides: a manager plans a ride (title, meeting place, destination, start time, notes) and members
 *     answer Interested / Not interested. At ride time the host starts a live ride and invites the interested
 *     members from the ride screen (crew_ride_invites.js);
 *   - polls (crew_routes.js) and the community chat (chat.js).
 *
 * registerCommunityRoutes({ r, repo, hub, wrap, flagsOf, plans }) once, on the authenticated router, AFTER
 * registerCrewRoutes. Admin switch `crews` gates everything; `communityRides` gates hosted rides.
 *
 * Privacy: member rows carry username, first name, picture and role only. A private community shows non-members
 * nothing but its name, description, picture and member count. Pushes carry ids and names only.
 */
const express = require('express');
const rateLimit = require('express-rate-limit');
const crypto = require('crypto');
const U = require('./usernames');
const F = require('./friends');
const A = require('./avatars');
const CR = require('./crews');
const { firstNameOf } = require('./social_routes');
const { stampEvent } = require('./push');

const FEATURE_OFF = { error: 'This feature is turned off for now.', code: 'FEATURE_OFF' };
const NOT_FOUND = { error: 'Community not found.', code: 'CREW_NOT_FOUND' };
const NOT_MANAGER = { error: 'Only the community admin and co-admins can do this.', code: 'NOT_CREW_ADMIN' };
const DAY = 86400000;

/** "Sat 22 Nov, 6:30 am" in India time. */
function whenLabel(ms) {
  try {
    return new Intl.DateTimeFormat('en-IN', { weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', hour12: true, timeZone: 'Asia/Kolkata' })
      .format(new Date(ms)).replace(/\s+/g, ' ');
  } catch { return ''; }
}

function registerCommunityRoutes({ r, repo, hub = null, wrap, flagsOf = () => null, plans = null }) {
  const soda = repo.soda;
  const perUser = (req) => req.user?.userId || req.ip;
  const limiter = (windowMs, limit, message) => rateLimit({ windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: perUser, message: { error: message, code: 'RATE_LIMITED' } });
  const readLimiter = limiter(60 * 1000, 120, 'Too many requests. Wait a minute.');
  const writeLimiter = limiter(60 * 1000, 40, 'Too many changes. Wait a minute.');
  const joinLimiter = limiter(DAY, 40, 'Too many join requests today. Try again tomorrow.');
  const photoLimiter = limiter(60 * 60 * 1000, 20, 'Too many picture changes. Try again later.');
  const rideLimiter = limiter(DAY, 20, 'Too many new rides today. Try again tomorrow.');

  const isOn = (id) => { const fl = flagsOf(); return !fl || fl.isOn(id); };
  const feature = (id) => (req, res, next) => (isOn(id) ? next() : res.status(403).set('Cache-Control', 'no-store').json({ ...FEATURE_OFF, feature: id }));
  const noStore = (res) => res.set('Cache-Control', 'no-store');
  const sendErr = (res, e) => {
    if (e instanceof CR.CrewError) return res.status(e.status).json({ error: e.message, code: e.code });
    if (e instanceof A.AvatarError) return res.status(e.status || 400).json({ error: e.message, code: e.code });
    throw e;
  };
  const notify = (userId, payload) => {
    payload = stampEvent({ ...payload });
    let delivered = 0;
    try { if (hub) delivered = hub.sendToUser(userId, payload) || 0; } catch { /* best effort */ }
    try { if (hub && hub.push) hub.push.onSocketEvent(userId, payload, { delivered }).catch(() => {}); } catch { /* best effort */ }
  };

  const usersByIds = async (ids) => {
    const map = new Map();
    const list = [...new Set(ids.filter(Boolean))];
    for (let i = 0; i < list.length; i += 100) {
      const rows = await soda.query('users', { userId: { $in: list.slice(i, i + 100) } }, { limit: 100 });
      for (const row of rows) {
        const u = { ...row.value, key: row.key };
        map.set(u.userId, u.username ? u : await U.ensureUsername(repo, u).catch(() => u));
      }
    }
    return map;
  };
  const gone = (u) => !u || u.status === 'BLOCKED';
  const avatarOf = (u) => (isOn('profilePhotos') ? A.avatarUrlOf(u && u.avatarId) : null);
  const cardOf = (u) => ({ username: (u && u.username) || '', displayName: firstNameOf(u && u.name), avatarUrl: avatarOf(u) });
  const photoUrlOf = (crew) => (crew.photoId ? A.avatarUrlOf(crew.photoId) : null);

  const crewOf = async (req) => {
    const crewId = String(req.params.crewId || '');
    return CR.isCrewId(crewId) ? CR.getCrew(soda, crewId) : null;
  };
  /** The community and my membership (null when not a member). */
  const withMe = async (req) => {
    const crew = await crewOf(req);
    if (!crew) return null;
    return { crew, me: await CR.memberOf(soda, crew.crewId, req.user.userId) };
  };
  const managers = async (crewId) => (await CR.membersOf(soda, crewId)).filter((m) => CR.canManage(m));
  const toMembers = async (crewId, payload, exceptId = null) => {
    if (!hub) return;
    for (const m of await CR.membersOf(soda, crewId)) if (m.userId !== exceptId) notify(m.userId, payload);
  };
  const capFor = async (crew) => {
    // Plan limit "community size" of the admin (plans.js), never above the crew cap.
    const cap = CR.capOf(crew);
    if (crew.club || !plans) return cap;
    const lim = await plans.limitFor(crew.adminId, 'communityMembersMax').catch(() => null);
    return Number.isInteger(lim) && lim > 0 ? Math.min(cap, lim) : cap;
  };

  const summaryOf = (crew, extra = {}) => ({
    crewId: crew.crewId, name: crew.name, description: crew.description || '', visibility: CR.visibilityOf(crew),
    photoUrl: photoUrlOf(crew), memberCount: crew.memberCount || 0, club: !!crew.club, ...extra,
  });

  // Account erase: join requests and ride answers go with crews.forgetCrewUser (crew_routes cascade).

  r.use('/communities', feature('crews'));

  // ---- find communities ----
  r.get('/communities/discover', readLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const q = typeof req.query.q === 'string' ? req.query.q.slice(0, 40) : '';
    const list = await CR.discover(soda, { q, limit: 40 });
    const mine = new Set((await CR.membershipsOf(soda, uid)).map((m) => m.crewId));
    const asked = new Set((await CR.requestsBy(soda, uid)).map((x) => x.crewId));
    const blockers = new Set((await soda.query(F.COLLECTIONS.blocks, { blocked: uid }, { limit: 2000 }).catch(() => [])).map((x) => x.value.blocker));
    const out = list.filter((c) => !blockers.has(c.adminId)).map((c) => summaryOf(c, {
      status: mine.has(c.crewId) ? 'MEMBER' : asked.has(c.crewId) ? 'REQUESTED' : 'NONE',
    }));
    noStore(res).json({ ok: true, communities: out });
  }));

  /** A community seen by anyone: public shows members, polls (read-only) and rides; private only the summary. */
  r.get('/communities/:crewId', readLimiter, wrap(async (req, res) => {
    const found = await withMe(req);
    if (!found) return noStore(res).status(404).json(NOT_FOUND);
    const { crew, me } = found;
    if (await F.blockedEither(soda, req.user.userId, crew.adminId)) return noStore(res).status(404).json(NOT_FOUND);
    const requested = !me && !!(await CR.requestOf(soda, crew.crewId, req.user.userId));
    const open = !!me || CR.visibilityOf(crew) === 'public';
    const out = { ok: true, community: summaryOf(crew, { status: me ? 'MEMBER' : requested ? 'REQUESTED' : 'NONE', myRole: me ? me.role : null }) };
    if (open) {
      const members = await CR.membersOf(soda, crew.crewId);
      const users = await usersByIds(members.map((m) => m.userId));
      const order = { ADMIN: 0, CO_ADMIN: 1, MEMBER: 2 };
      out.members = members.filter((m) => !gone(users.get(m.userId)))
        .map((m) => ({ ...cardOf(users.get(m.userId)), role: m.role, joinedAt: m.joinedAt }))
        .sort((a, b) => order[a.role] - order[b.role] || a.joinedAt - b.joinedAt);
      out.rides = isOn('communityRides') ? await ridesView(crew, req.user.userId, me) : [];
    }
    noStore(res).json(out);
  }));

  // ---- join / request ----
  r.post('/communities/:crewId/join', joinLimiter, wrap(async (req, res) => {
    const found = await withMe(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    const { crew, me } = found;
    if (me) return res.json({ ok: true, status: 'MEMBER' });
    if (crew.club) return res.status(409).json({ error: 'Clubs are joined through the club organiser.', code: 'CLUB_MANAGED' });
    const uid = req.user.userId;
    const meDoc = await U.ensureUsername(repo, await repo.findUserById(uid));
    try {
      if (CR.visibilityOf(crew) === 'public') {
        const cap = await capFor(crew);
        if ((await CR.membersOf(soda, crew.crewId)).length >= cap) throw new CR.CrewError(`This community is full (${cap} riders).`, 'CREW_FULL', 409);
        const out = await CR.addMember(soda, crew, uid, uid);
        await toMembers(crew.crewId, { type: 'CREW_UPDATED', crewId: crew.crewId, event: 'JOINED', username: meDoc.username }, uid);
        return res.json({ ok: true, status: out.status === 'JOINED' ? 'MEMBER' : 'MEMBER' });
      }
      const out = await CR.requestJoin(soda, crew, uid);
      if (out.status === 'REQUESTED') {
        for (const m of await managers(crew.crewId)) {
          notify(m.userId, { type: 'CREW_JOIN_REQUEST', crewId: crew.crewId, crewName: crew.name, username: meDoc.username });
        }
      }
      res.status(out.status === 'REQUESTED' ? 202 : 200).json({ ok: true, status: out.status === 'ALREADY_MEMBER' ? 'MEMBER' : 'REQUESTED' });
    } catch (e) { sendErr(res, e); }
  }));

  r.delete('/communities/:crewId/join', writeLimiter, wrap(async (req, res) => {
    const crew = await crewOf(req);
    if (!crew) return res.status(404).json(NOT_FOUND);
    await CR.cancelRequest(soda, crew.crewId, req.user.userId);
    res.json({ ok: true, status: 'NONE' });
  }));

  // ---- requests (managers) ----
  r.get('/crews/:crewId/requests', readLimiter, wrap(async (req, res) => {
    const found = await withMe(req);
    if (!found || !found.me) return noStore(res).status(404).json(NOT_FOUND);
    if (!CR.canManage(found.me)) return res.status(403).json(NOT_MANAGER);
    const list = await CR.requestsOf(soda, found.crew.crewId);
    const users = await usersByIds(list.map((x) => x.userId));
    noStore(res).json({ ok: true, requests: list.filter((x) => !gone(users.get(x.userId))).map((x) => ({ ...cardOf(users.get(x.userId)), createdAt: x.createdAt })) });
  }));

  const decide = (approve) => wrap(async (req, res) => {
    const found = await withMe(req);
    if (!found || !found.me) return res.status(404).json(NOT_FOUND);
    if (!CR.canManage(found.me)) return res.status(403).json(NOT_MANAGER);
    const target = await U.findUserByUsername(repo, String(req.params.username || '')).catch(() => null);
    const pending = target ? await CR.requestOf(soda, found.crew.crewId, target.userId) : null;
    if (!pending) return res.status(404).json({ error: 'This request is no longer waiting.', code: 'NOT_FOUND' });
    if (!approve) {
      await CR.cancelRequest(soda, found.crew.crewId, target.userId);
      return res.json({ ok: true, status: 'DECLINED' });
    }
    try {
      const cap = await capFor(found.crew);
      if ((await CR.membersOf(soda, found.crew.crewId)).length >= cap) throw new CR.CrewError(`This community is full (${cap} riders).`, 'CREW_FULL', 409);
      await CR.addMember(soda, found.crew, target.userId, req.user.userId);
    } catch (e) { return sendErr(res, e); }
    notify(target.userId, { type: 'CREW_JOIN_APPROVED', crewId: found.crew.crewId, crewName: found.crew.name });
    await toMembers(found.crew.crewId, { type: 'CREW_UPDATED', crewId: found.crew.crewId, event: 'JOINED', username: target.username }, target.userId);
    res.json({ ok: true, status: 'APPROVED' });
  });
  r.post('/crews/:crewId/requests/:username/approve', writeLimiter, decide(true));
  r.post('/crews/:crewId/requests/:username/decline', writeLimiter, decide(false));

  // ---- picture (admin) ----
  const rawPhoto = express.raw({ type: () => true, limit: A.MAX_BYTES });
  r.post('/crews/:crewId/photo', photoLimiter, (req, res, next) => {
    if (req.is('application/json') || req.is('multipart/form-data')) {
      return res.status(415).json({ error: 'Send the picture bytes as image/jpeg, image/png or image/webp.', code: 'UNSUPPORTED_PHOTO' });
    }
    rawPhoto(req, res, (err) => {
      if (!err) return next();
      if (err.type === 'entity.too.large') return res.status(413).json({ error: 'This picture is too large (up to 2 MB).', code: 'PHOTO_TOO_LARGE' });
      return res.status(400).json({ error: 'The picture did not arrive complete. Please try again.', code: 'NO_PHOTO' });
    });
  }, wrap(async (req, res) => {
    const found = await withMe(req);
    if (!found || !found.me) return res.status(404).json(NOT_FOUND);
    if (!CR.canManage(found.me)) return res.status(403).json(NOT_MANAGER);
    try {
      const p = A.prepareAvatar(req.body, { maxSide: A.CROPPED_MAX_SIDE });
      await A.ensureAvatarStore(soda);
      const photoId = `av_${crypto.randomBytes(12).toString('hex')}`;
      // Stored like a profile picture with the community id as owner (no object storage: small, cropped square).
      await soda.insert(A.COLL, { avatarId: photoId, userId: found.crew.crewId, kind: 'crew', mime: p.mime, ext: p.ext, bytes: p.data.length, width: p.width || null, height: p.height || null, at: Date.now(), store: 'db', data: p.data.toString('base64') });
      const fresh = await CR.getCrew(soda, found.crew.crewId);
      const prev = fresh.photoId;
      const { key, ...value } = fresh;
      await soda.replace(CR.COLLECTIONS.crews, key, { ...value, photoId, updatedAt: Date.now() });
      if (prev) await A.deleteAvatarDoc(soda, prev).catch(() => {});
      await toMembers(fresh.crewId, { type: 'CREW_UPDATED', crewId: fresh.crewId, event: 'SETTINGS' }, req.user.userId);
      noStore(res).status(201).json({ ok: true, photoUrl: A.avatarUrlOf(photoId) });
    } catch (e) { sendErr(res, e); }
  }));

  r.delete('/crews/:crewId/photo', writeLimiter, wrap(async (req, res) => {
    const found = await withMe(req);
    if (!found || !found.me) return res.status(404).json(NOT_FOUND);
    if (!CR.canManage(found.me)) return res.status(403).json(NOT_MANAGER);
    const fresh = await CR.getCrew(soda, found.crew.crewId);
    if (fresh.photoId) {
      const { key, ...value } = fresh;
      await soda.replace(CR.COLLECTIONS.crews, key, { ...value, photoId: null, updatedAt: Date.now() });
      await A.deleteAvatarDoc(soda, fresh.photoId).catch(() => {});
    }
    res.json({ ok: true, photoUrl: null });
  }));

  // ---- hosted rides ----
  async function ridesView(crew, viewerId, me, now = Date.now()) {
    const rides = await CR.ridesOf(soda, crew.crewId, now);
    const hosts = await usersByIds(rides.map((x) => x.hostId));
    const out = [];
    for (const ride of rides) {
      const answers = await CR.rsvpsOf(soda, ride.rideId);
      const interested = answers.filter((a) => a.answer === 'INTERESTED');
      const iu = await usersByIds(interested.slice(0, 50).map((a) => a.userId));
      const mineA = answers.find((a) => a.userId === viewerId);
      out.push({
        rideId: ride.rideId, title: ride.title, meetName: ride.meetName, destName: ride.destName || '', notes: ride.notes || '',
        startAt: ride.startAt, when: whenLabel(ride.startAt), status: ride.status, past: ride.startAt < now - 6 * 3600000,
        host: hosts.get(ride.hostId) ? cardOf(hosts.get(ride.hostId)) : null,
        interestedCount: interested.length, notInterestedCount: answers.length - interested.length,
        interested: interested.map((a) => iu.get(a.userId)).filter((u) => !gone(u)).map(cardOf),
        myAnswer: mineA ? mineA.answer : null,
        canEdit: !!me && (ride.hostId === viewerId || CR.canManage(me)),
      });
    }
    return out.sort((a, b) => (a.past - b.past) || (a.past ? b.startAt - a.startAt : a.startAt - b.startAt));
  }

  r.use('/crews/:crewId/rides', feature('communityRides'));

  r.get('/crews/:crewId/rides', readLimiter, wrap(async (req, res) => {
    const found = await withMe(req);
    if (!found || (!found.me && CR.visibilityOf(found.crew) !== 'public')) return noStore(res).status(404).json(NOT_FOUND);
    noStore(res).json({ ok: true, rides: await ridesView(found.crew, req.user.userId, found.me), canHost: !!found.me && CR.canManage(found.me) });
  }));

  r.post('/crews/:crewId/rides', rideLimiter, wrap(async (req, res) => {
    const found = await withMe(req);
    if (!found || !found.me) return res.status(404).json(NOT_FOUND);
    if (!CR.canManage(found.me)) return res.status(403).json(NOT_MANAGER);
    if (plans) {
      const eff = await plans.effectiveFor(req.user.userId);
      if (!eff.features.communityRides) return res.status(403).json({ error: 'Hosting community rides is not included in your plan.', code: 'PLAN_FEATURE' });
      const upcoming = (await CR.ridesOf(soda, found.crew.crewId)).filter((x) => x.status === 'PLANNED' && x.startAt > Date.now());
      if (upcoming.length >= eff.limits.upcomingRidesMax) return res.status(409).json({ error: `Your plan allows up to ${eff.limits.upcomingRidesMax} planned rides at a time.`, code: 'RIDE_LIMIT' });
    }
    try {
      const ride = await CR.createRide(soda, found.crew, req.user.userId, req.body);
      await toMembers(found.crew.crewId, { type: 'CREW_RIDE_NEW', crewId: found.crew.crewId, crewName: found.crew.name, rideId: ride.rideId, title: ride.title, when: whenLabel(ride.startAt) }, req.user.userId);
      const view = (await ridesView(found.crew, req.user.userId, found.me)).find((x) => x.rideId === ride.rideId);
      res.status(201).json({ ok: true, ride: view });
    } catch (e) { sendErr(res, e); }
  }));

  const rideOf = async (req) => {
    const found = await withMe(req);
    if (!found) return null;
    const ride = await CR.getRide(soda, found.crew.crewId, String(req.params.rideId || ''));
    return ride ? { ...found, ride } : null;
  };

  r.patch('/crews/:crewId/rides/:rideId', writeLimiter, wrap(async (req, res) => {
    const found = await rideOf(req);
    if (!found || !found.me) return res.status(404).json({ error: 'Ride not found.', code: 'RIDE_NOT_FOUND' });
    if (found.ride.hostId !== req.user.userId && !CR.canManage(found.me)) return res.status(403).json(NOT_MANAGER);
    try {
      await CR.updateRide(soda, found.ride, req.body);
      await toMembers(found.crew.crewId, { type: 'CREW_UPDATED', crewId: found.crew.crewId, event: 'RIDES' }, req.user.userId);
      const view = (await ridesView(found.crew, req.user.userId, found.me)).find((x) => x.rideId === found.ride.rideId);
      res.json({ ok: true, ride: view });
    } catch (e) { sendErr(res, e); }
  }));

  r.delete('/crews/:crewId/rides/:rideId', writeLimiter, wrap(async (req, res) => {
    const found = await rideOf(req);
    if (!found || !found.me) return res.status(404).json({ error: 'Ride not found.', code: 'RIDE_NOT_FOUND' });
    if (found.ride.hostId !== req.user.userId && !CR.canManage(found.me)) return res.status(403).json(NOT_MANAGER);
    await CR.cancelRide(soda, found.ride);
    await toMembers(found.crew.crewId, { type: 'CREW_UPDATED', crewId: found.crew.crewId, event: 'RIDES' }, req.user.userId);
    res.json({ ok: true, status: 'CANCELLED' });
  }));

  r.post('/crews/:crewId/rides/:rideId/answer', writeLimiter, wrap(async (req, res) => {
    const found = await rideOf(req);
    if (!found || !found.me) return res.status(404).json({ error: 'Ride not found.', code: 'RIDE_NOT_FOUND' });
    try {
      const a = await CR.answerRide(soda, found.ride, req.user.userId, String(req.body?.answer || ''));
      const answers = await CR.rsvpsOf(soda, found.ride.rideId);
      res.json({ ok: true, myAnswer: a.answer, interestedCount: answers.filter((x) => x.answer === 'INTERESTED').length });
    } catch (e) { sendErr(res, e); }
  }));
}

module.exports = { registerCommunityRoutes, whenLabel };
