'use strict';
/**
 * 3.55 Crews and crew polls: HTTP routes (docs/features_355/crews_polls.md). Rules and storage live
 * in crews.js; this file adds the views (privacy), pushes, rate limits, admin moderation, the admin
 * switches `crews` / `crewPolls` and the account-erase cleanup.
 *
 * registerCrewRoutes({ r, repo, hub, wrap, requireAdmin, flagsOf }) — once, on the authenticated router.
 *
 * Privacy:
 *   - A crew is invisible to non-members: every crew route answers the same 404 CREW_NOT_FOUND for an
 *     unknown crew and for a crew the rider is not in.
 *   - Member rows carry username, first name, picture and crew role only (never phone, e-mail,
 *     medical info, location or the userId).
 *   - Inviting: the same 404 NOT_A_FRIEND for an unknown username, a rider who is not my friend, a
 *     rider blocked either way and a suspended account (no enumeration).
 *   - Pushes never carry a userId.
 */
const rateLimit = require('express-rate-limit');
const U = require('./usernames');
const F = require('./friends');
const A = require('./avatars');
const CR = require('./crews');
const { firstNameOf } = require('./social_routes');
const { stampEvent } = require('./push');

const FEATURE_OFF = { error: 'This feature is turned off for now.', code: 'FEATURE_OFF' };
const NOT_FOUND = { error: 'Crew not found.', code: 'CREW_NOT_FOUND' };
const NOT_A_FRIEND = { error: 'You can only invite riders who are your friends.', code: 'NOT_A_FRIEND' };
const DAY = 86400000;

function registerCrewRoutes({ r, repo, hub = null, wrap, requireAdmin, flagsOf = () => null }) {
  const soda = repo.soda;
  const perUser = (req) => req.user?.userId || req.ip;
  const limiter = (windowMs, limit, message) => rateLimit({ windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: perUser, message: { error: message, code: 'RATE_LIMITED' } });
  const readLimiter = limiter(60 * 1000, 120, 'Too many requests. Wait a minute.');
  const createLimiter = limiter(60 * 60 * 1000, 20, 'Too many new crews. Try again later.');
  const inviteLimiter = limiter(DAY, 50, 'Too many invites today. Try again tomorrow.');
  const writeLimiter = limiter(60 * 1000, 60, 'Too many changes. Wait a minute.');
  const pollCreateLimiter = limiter(DAY, 30, 'Too many new polls today. Try again tomorrow.');
  const voteLimiter = limiter(60 * 1000, 60, 'Too many votes. Wait a minute.');

  const isOn = (id) => { const fl = flagsOf(); return !fl || fl.isOn(id); };
  const feature = (id) => (req, res, next) => (isOn(id) ? next() : res.status(403).set('Cache-Control', 'no-store').json({ ...FEATURE_OFF, feature: id }));
  const sendErr = (res, e) => {
    if (e instanceof CR.CrewError) return res.status(e.status).json({ error: e.message, code: e.code });
    throw e;
  };
  const notify = (userId, payload) => {
    let delivered = 0;
    // One eventId for the socket message and the push (the app shows one notice per id). A copy per
    // member: toMembers() passes the same object to everyone.
    payload = stampEvent({ ...payload });
    try { if (hub) delivered = hub.sendToUser(userId, payload) || 0; } catch { /* best effort */ }
    // 3.55 push (src/push.js): CREW_INVITE / POLL_CREATED reach a phone with the app closed.
    try { if (hub && hub.push) hub.push.onSocketEvent(userId, payload, { delivered }).catch(() => {}); } catch { /* best effort */ }
  };

  // Account erase: crews handed over or deleted, memberships, invites, votes (see crews.forgetCrewUser).
  if (!repo.__crewsCascade) {
    repo.__crewsCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await CR.forgetCrewUser(soda, user.userId).catch(() => {});
      return out;
    };
  }

  // ---- helpers ----
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
  const avatarOf = (u) => (isOn('profilePhotos') ? A.avatarUrlOf(u && u.avatarId) : null);
  const cardOf = (u) => ({ username: (u && u.username) || '', avatarUrl: avatarOf(u) });
  const blockersOf = async (uid) => {
    await F.ensureFriendStore(soda);
    return new Set((await soda.query(F.COLLECTIONS.blocks, { blocked: uid }, { limit: 2000 })).map((x) => x.value.blocker));
  };
  const gone = (u) => !u || u.status === 'BLOCKED';

  /** The crew and my membership, or null (unknown crew and "not a member" look the same). */
  const mine = async (req) => {
    const crewId = String(req.params.crewId || '');
    if (!CR.isCrewId(crewId)) return null;
    const crew = await CR.getCrew(soda, crewId);
    if (!crew) return null;
    const me = await CR.memberOf(soda, crewId, req.user.userId);
    return me ? { crew, me } : null;
  };

  /** Drops members whose account was deleted or suspended (the admin role moves on). */
  const sweep = async (crew) => {
    const members = await CR.membersOf(soda, crew.crewId);
    const users = await usersByIds(members.map((m) => m.userId));
    let changed = false;
    for (const m of members) {
      if (!gone(users.get(m.userId))) continue;
      const current = await CR.getCrew(soda, crew.crewId);
      if (!current) break;
      await CR.leaveCrew(soda, current, m.userId);
      changed = true;
    }
    if (!changed) return { crew, members, users };
    const fresh = await CR.getCrew(soda, crew.crewId);
    const left = fresh ? await CR.membersOf(soda, crew.crewId) : [];
    return { crew: fresh, members: left, users };
  };

  /** Push to every current member except `exceptId` (offline riders see it on next refresh). */
  const toMembers = async (crewId, payload, exceptId = null) => {
    if (!hub) return;
    for (const m of await CR.membersOf(soda, crewId)) if (m.userId !== exceptId) notify(m.userId, payload);
  };

  // 3.56 operator clubs (src/operators.js): name, deletion and hand-over are managed in the operator
  // console; members can always leave. `club` tells the app this crew is a club (old apps ignore it).
  const CLUB_MANAGED = { error: 'This club is managed in the CoRoute operator console.', code: 'CLUB_MANAGED' };
  const crewView = (crew, me) => ({
    crewId: crew.crewId, name: crew.name, description: crew.description || '',
    club: crew.club ? { operatorId: crew.club.operatorId, type: crew.club.type || null } : null,
    memberCount: crew.memberCount || 0, createdAt: crew.createdAt,
    settings: { membersCanCreatePolls: !!(crew.settings && crew.settings.membersCanCreatePolls) },
    myRole: me ? me.role : null,
    canInvite: CR.canManage(me), canCreatePoll: isOn('crewPolls') && CR.canCreatePoll(crew, me),
  });
  const memberView = (u, m, blockedMe) => ({
    username: u.username || '', displayName: firstNameOf(u.name), avatarUrl: blockedMe ? null : avatarOf(u), role: m.role, joinedAt: m.joinedAt,
  });

  const pollView = (poll, votes, viewerId, me, users, now) => {
    const t = CR.tally(poll, votes);
    const open = CR.pollOpen(poll, now);
    const mineVote = votes.find((v) => v.userId === viewerId);
    const out = {
      pollId: poll.pollId, question: poll.question, multi: !!poll.multi, anonymous: !!poll.anonymous, template: poll.template || null,
      status: open ? 'OPEN' : 'CLOSED', createdAt: poll.createdAt, closesAt: poll.closesAt, closedAt: open ? 0 : (poll.closedAt || poll.closesAt),
      createdBy: poll.createdBy && users.get(poll.createdBy) ? users.get(poll.createdBy).username || null : null,
      totalVoters: t.totalVoters, options: t.options, leaders: t.leaders,
      myVote: mineVote ? mineVote.optionIds : [],
      canClose: open && CR.canModeratePoll(poll, me), canDelete: CR.canModeratePoll(poll, me),
    };
    if (!poll.anonymous) {
      const voters = {};
      for (const o of poll.options) voters[o.id] = [];
      for (const v of votes) {
        const u = users.get(v.userId);
        if (!u || v.erased) continue;
        for (const id of v.optionIds || []) if (voters[id]) voters[id].push({ username: u.username || '', displayName: firstNameOf(u.name) });
      }
      out.voters = voters;
    }
    return out;
  };

  // ---- switches ----
  r.use('/crews', feature('crews'));

  // ---- my crews and invites ----
  r.get('/crews', readLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const now = Date.now();
    const pollsOn = isOn('crewPolls');
    const memberships = await CR.membershipsOf(soda, uid);
    const voted = new Set(pollsOn ? (await soda.query(CR.COLLECTIONS.votes, { userId: uid }, { limit: 5000 })).map((x) => x.value.pollId) : []);
    const crews = [];
    const adminIds = [];
    for (const m of memberships) {
      const crew = await CR.getCrew(soda, m.crewId);
      if (!crew) continue;
      let openPolls = 0, pendingVotes = 0, nextPollClosesAt = 0;
      if (pollsOn) {
        for (const p of await CR.pollsOf(soda, crew.crewId, now)) {
          if (!CR.pollOpen(p, now)) continue;
          openPolls++;
          if (!voted.has(p.pollId)) pendingVotes++;
          // 3.55 People hub: "Poll closes in 5 h" under the crew in the app's Crews list.
          const closes = Number(p.closesAt) || 0;
          if (closes > now && (!nextPollClosesAt || closes < nextPollClosesAt)) nextPollClosesAt = closes;
        }
      }
      adminIds.push(crew.adminId);
      crews.push({ ...crewView(crew, m), openPolls, pendingVotes, nextPollClosesAt, adminId: crew.adminId });
    }
    const invites = await CR.invitesFor(soda, uid, now);
    const inviteCrews = new Map();
    for (const inv of invites) inviteCrews.set(inv.crewId, await CR.getCrew(soda, inv.crewId));
    const users = await usersByIds([...adminIds, ...invites.map((i) => i.invitedBy)]);
    res.set('Cache-Control', 'no-store').json({
      ok: true,
      crews: crews.map(({ adminId, ...c }) => ({ ...c, admin: users.get(adminId) ? users.get(adminId).username || null : null }))
        .sort((a, b) => a.name.localeCompare(b.name)),
      invites: invites.filter((i) => inviteCrews.get(i.crewId) && users.get(i.invitedBy)).map((i) => ({
        inviteId: i.inviteId, crewId: i.crewId, crewName: inviteCrews.get(i.crewId).name,
        description: inviteCrews.get(i.crewId).description || '', memberCount: inviteCrews.get(i.crewId).memberCount || 0,
        invitedBy: cardOf(users.get(i.invitedBy)), createdAt: i.createdAt, expiresAt: i.expiresAt,
      })).sort((a, b) => b.createdAt - a.createdAt),
      limits: { maxOwned: CR.LIMITS.MAX_OWNED, maxJoined: CR.LIMITS.MAX_JOINED, maxMembers: CR.LIMITS.MAX_MEMBERS, maxCoAdmins: CR.LIMITS.MAX_CO_ADMINS },
    });
  }));

  r.post('/crews', createLimiter, wrap(async (req, res) => {
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    try {
      const crew = await CR.createCrew(soda, req.user.userId, { name: b.name, description: b.description });
      res.status(201).json({ ok: true, crew: crewView(crew, { role: CR.ROLES.ADMIN }) });
    } catch (e) { sendErr(res, e); }
  }));

  // Invitations addressed to me (registered before the /crews/:crewId routes).
  const answer = (yes) => wrap(async (req, res) => {
    let out;
    try { out = await CR.respondInvite(soda, req.user.userId, String(req.params.inviteId || ''), yes); } catch (e) { return sendErr(res, e); }
    if (!out) return res.status(404).json({ error: 'This invite is no longer waiting.', code: 'NOT_FOUND' });
    if (out.status === 'JOINED' && out.crew) {
      const meDoc = await U.ensureUsername(repo, await repo.findUserById(req.user.userId));
      await toMembers(out.crew.crewId, { type: 'CREW_UPDATED', crewId: out.crew.crewId, event: 'JOINED', username: meDoc.username }, req.user.userId);
    }
    res.json({ ok: true, status: out.status, crewId: out.crew ? out.crew.crewId : null });
  });
  r.post('/crews/invites/:inviteId/accept', writeLimiter, answer(true));
  r.post('/crews/invites/:inviteId/decline', writeLimiter, answer(false));

  // ---- one crew ----
  r.get('/crews/:crewId', readLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).set('Cache-Control', 'no-store').json(NOT_FOUND);
    const swept = await sweep(found.crew);
    const me = swept.crew ? swept.members.find((m) => m.userId === req.user.userId) : null;
    if (!swept.crew || !me) return res.status(404).set('Cache-Control', 'no-store').json(NOT_FOUND);
    const blockedMe = await blockersOf(req.user.userId);
    const members = swept.members.filter((m) => swept.users.get(m.userId))
      .map((m) => memberView(swept.users.get(m.userId), m, blockedMe.has(m.userId)));
    const order = { ADMIN: 0, CO_ADMIN: 1, MEMBER: 2 };
    members.sort((a, b) => order[a.role] - order[b.role] || a.joinedAt - b.joinedAt);
    let invites = [];
    if (CR.canManage(me)) {
      const live = await CR.liveInvitesOf(soda, swept.crew.crewId);
      const iu = await usersByIds(live.flatMap((i) => [i.userId, i.invitedBy]));
      invites = live.filter((i) => iu.get(i.userId)).map((i) => ({
        inviteId: i.inviteId, ...cardOf(iu.get(i.userId)), invitedBy: iu.get(i.invitedBy) ? iu.get(i.invitedBy).username : null,
        createdAt: i.createdAt, expiresAt: i.expiresAt,
      }));
    }
    res.set('Cache-Control', 'no-store').json({ ok: true, crew: crewView(swept.crew, me), members, invites });
  }));

  r.patch('/crews/:crewId', writeLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    if (found.me.role !== CR.ROLES.ADMIN) return res.status(403).json({ error: 'Only the crew admin can change the crew.', code: 'NOT_CREW_ADMIN' });
    if (found.crew.club) return res.status(409).json(CLUB_MANAGED);
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    try {
      const crew = await CR.updateCrew(soda, found.crew, { name: b.name, description: b.description, membersCanCreatePolls: b.membersCanCreatePolls });
      await toMembers(crew.crewId, { type: 'CREW_UPDATED', crewId: crew.crewId, event: 'SETTINGS' }, req.user.userId);
      res.json({ ok: true, crew: crewView(crew, found.me) });
    } catch (e) { sendErr(res, e); }
  }));

  r.delete('/crews/:crewId', writeLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    if (found.me.role !== CR.ROLES.ADMIN) return res.status(403).json({ error: 'Only the crew admin can delete the crew.', code: 'NOT_CREW_ADMIN' });
    if (found.crew.club) return res.status(409).json(CLUB_MANAGED);
    const members = await CR.membersOf(soda, found.crew.crewId);
    await CR.deleteCrew(soda, found.crew.crewId);
    for (const m of members) if (m.userId !== req.user.userId) notify(m.userId, { type: 'CREW_DELETED', crewId: found.crew.crewId, crewName: found.crew.name });
    res.json({ ok: true, deleted: true });
  }));

  // ---- inviting (admin and co-admins, friends only) ----
  r.get('/crews/:crewId/invitable', readLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    if (!CR.canManage(found.me)) return res.status(403).json({ error: 'Only the crew admin and co-admins can invite.', code: 'NOT_CREW_ADMIN' });
    const uid = req.user.userId;
    const { friends } = await F.listFor(soda, uid);
    const ids = friends.map((e) => (e.a === uid ? e.b : e.a));
    const users = await usersByIds(ids);
    const members = new Set((await CR.membersOf(soda, found.crew.crewId)).map((m) => m.userId));
    const invited = new Set((await CR.liveInvitesOf(soda, found.crew.crewId)).map((i) => i.userId));
    const out = ids.map((id) => users.get(id)).filter((u) => u && !gone(u) && u.username).map((u) => ({
      ...cardOf(u), displayName: firstNameOf(u.name), status: members.has(u.userId) ? 'MEMBER' : invited.has(u.userId) ? 'INVITED' : 'AVAILABLE',
    })).sort((a, b) => a.username.localeCompare(b.username));
    res.set('Cache-Control', 'no-store').json({ ok: true, friends: out });
  }));

  /**
   * POST /crews/:crewId/invites {username} or {usernames:[...]} (up to 20). Single: 201 INVITED,
   * 200 ALREADY_INVITED / ALREADY_MEMBER, 404 NOT_A_FRIEND. Batch: 200 {results:[{username, status}]}
   * with status INVITED | ALREADY_INVITED | ALREADY_MEMBER | NOT_A_FRIEND.
   */
  r.post('/crews/:crewId/invites', inviteLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    if (!CR.canManage(found.me)) return res.status(403).json({ error: 'Only the crew admin and co-admins can invite.', code: 'NOT_CREW_ADMIN' });
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    const single = typeof b.username === 'string';
    const names = single ? [b.username] : Array.isArray(b.usernames) ? b.usernames.filter((x) => typeof x === 'string') : [];
    if (!names.length) return res.status(400).json({ error: 'Pick a friend to invite.', code: 'BAD_REQUEST' });
    if (names.length > CR.LIMITS.INVITE_BATCH) return res.status(400).json({ error: `Invite up to ${CR.LIMITS.INVITE_BATCH} friends at a time.`, code: 'BAD_REQUEST' });
    const meDoc = await U.ensureUsername(repo, await repo.findUserById(req.user.userId));
    const results = [];
    for (const raw of [...new Set(names.map((n) => n.trim()).filter(Boolean))]) {
      const target = await U.findUserByUsername(repo, raw.slice(0, 40)).catch(() => null);
      let out = { status: 'REFUSED' };
      if (target && !gone(target)) {
        try { out = await CR.inviteToCrew(soda, found.crew, found.me, target.userId); } catch (e) {
          if (single || !(e instanceof CR.CrewError)) return sendErr(res, e);
          results.push({ username: raw, status: e.code });
          continue;
        }
      }
      if (out.status === 'INVITED') {
        notify(target.userId, { type: 'CREW_INVITE', inviteId: out.invite.inviteId, crewId: found.crew.crewId, crewName: found.crew.name, username: meDoc.username });
      }
      results.push({ username: out.status === 'REFUSED' ? raw : target.username, status: out.status === 'REFUSED' ? 'NOT_A_FRIEND' : out.status });
    }
    if (single) {
      const one = results[0] || { status: 'NOT_A_FRIEND' };
      if (one.status === 'NOT_A_FRIEND') return res.status(404).json(NOT_A_FRIEND);
      return res.status(one.status === 'INVITED' ? 201 : 200).json({ ok: true, status: one.status, username: one.username });
    }
    res.json({ ok: true, results });
  }));

  r.delete('/crews/:crewId/invites/:inviteId', writeLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    if (!CR.canManage(found.me)) return res.status(403).json({ error: 'Only the crew admin and co-admins can cancel invites.', code: 'NOT_CREW_ADMIN' });
    const ok = await CR.cancelInvite(soda, found.crew.crewId, String(req.params.inviteId || ''));
    res.status(ok ? 200 : 404).json(ok ? { ok: true } : { error: 'This invite is no longer waiting.', code: 'NOT_FOUND' });
  }));

  // ---- members ----
  const targetMember = async (crew, raw) => {
    const u = await U.findUserByUsername(repo, String(raw || '').slice(0, 40)).catch(() => null);
    if (!u) return null;
    const m = await CR.memberOf(soda, crew.crewId, u.userId);
    return m ? { u, m } : null;
  };

  r.post('/crews/:crewId/leave', writeLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    // The operator (club crew admin) cannot leave its own club; members always can.
    if (found.crew.club && found.me.role === CR.ROLES.ADMIN) return res.status(409).json(CLUB_MANAGED);
    let transferTo = null;
    const raw = req.body && typeof req.body.transferTo === 'string' ? req.body.transferTo : '';
    if (raw && found.me.role === CR.ROLES.ADMIN) {
      const t = await targetMember(found.crew, raw);
      if (!t || t.u.userId === req.user.userId) return res.status(422).json({ error: 'Pick a member of this crew.', code: 'NOT_A_MEMBER' });
      transferTo = t.u.userId;
    }
    let out;
    try { out = await CR.leaveCrew(soda, found.crew, req.user.userId, { transferTo }); } catch (e) { return sendErr(res, e); }
    if (out.newAdminId) notify(out.newAdminId, { type: 'CREW_UPDATED', crewId: found.crew.crewId, event: 'YOU_ARE_ADMIN', crewName: found.crew.name });
    if (!out.deleted) await toMembers(found.crew.crewId, { type: 'CREW_UPDATED', crewId: found.crew.crewId, event: 'LEFT' });
    res.json({ ok: true, left: out.left, deleted: out.deleted });
  }));

  r.delete('/crews/:crewId/members/:username', writeLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    if (found.me.role !== CR.ROLES.ADMIN) return res.status(403).json({ error: 'Only the crew admin can remove riders.', code: 'NOT_CREW_ADMIN' });
    const t = await targetMember(found.crew, req.params.username);
    if (!t) return res.status(404).json({ error: 'This rider is not in the crew.', code: 'NOT_A_MEMBER' });
    if (t.u.userId === req.user.userId) return res.status(409).json({ error: 'Use Leave crew instead.', code: 'NOT_ALLOWED' });
    await CR.leaveCrew(soda, found.crew, t.u.userId);
    notify(t.u.userId, { type: 'CREW_REMOVED', crewId: found.crew.crewId, crewName: found.crew.name });
    await toMembers(found.crew.crewId, { type: 'CREW_UPDATED', crewId: found.crew.crewId, event: 'REMOVED' }, req.user.userId);
    res.json({ ok: true, removed: true });
  }));

  r.patch('/crews/:crewId/members/:username', writeLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    if (found.me.role !== CR.ROLES.ADMIN) return res.status(403).json({ error: 'Only the crew admin can change roles.', code: 'NOT_CREW_ADMIN' });
    const t = await targetMember(found.crew, req.params.username);
    if (!t) return res.status(404).json({ error: 'This rider is not in the crew.', code: 'NOT_A_MEMBER' });
    try {
      const m = await CR.changeRole(soda, found.crew, t.m, String(req.body?.role || ''));
      notify(t.u.userId, { type: 'CREW_UPDATED', crewId: found.crew.crewId, event: 'ROLE' });
      res.json({ ok: true, username: t.u.username, role: m.role });
    } catch (e) { sendErr(res, e); }
  }));

  r.post('/crews/:crewId/transfer', writeLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    if (found.me.role !== CR.ROLES.ADMIN) return res.status(403).json({ error: 'Only the crew admin can hand over the crew.', code: 'NOT_CREW_ADMIN' });
    if (found.crew.club) return res.status(409).json(CLUB_MANAGED);
    const t = await targetMember(found.crew, req.body?.username);
    if (!t || t.u.userId === req.user.userId || gone(t.u)) return res.status(422).json({ error: 'Pick a member of this crew.', code: 'NOT_A_MEMBER' });
    await CR.transferAdmin(soda, found.crew, t.m);
    notify(t.u.userId, { type: 'CREW_UPDATED', crewId: found.crew.crewId, event: 'YOU_ARE_ADMIN', crewName: found.crew.name });
    await toMembers(found.crew.crewId, { type: 'CREW_UPDATED', crewId: found.crew.crewId, event: 'ADMIN' }, req.user.userId);
    res.json({ ok: true, admin: t.u.username });
  }));

  // ---- polls (no chat: questions, fixed options and votes only) ----
  const pollsFeature = feature('crewPolls');
  const pollsFor = async (crewId, viewerId, me, now) => {
    const polls = await CR.pollsOf(soda, crewId, now);
    const votesBy = new Map();
    for (const p of polls) votesBy.set(p.pollId, await CR.votesOf(soda, p.pollId));
    const ids = polls.flatMap((p) => [p.createdBy, ...(p.anonymous ? [] : votesBy.get(p.pollId).map((v) => v.userId))]);
    const users = await usersByIds(ids);
    return polls.map((p) => pollView(p, votesBy.get(p.pollId), viewerId, me, users, now));
  };
  const onePoll = async (poll, viewerId, me) => {
    const votes = await CR.votesOf(soda, poll.pollId);
    const users = await usersByIds([poll.createdBy, ...(poll.anonymous ? [] : votes.map((v) => v.userId))]);
    return pollView(poll, votes, viewerId, me, users, Date.now());
  };

  r.get('/crews/:crewId/polls', pollsFeature, readLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).set('Cache-Control', 'no-store').json(NOT_FOUND);
    const polls = await pollsFor(found.crew.crewId, req.user.userId, found.me, Date.now());
    res.set('Cache-Control', 'no-store').json({ ok: true, polls, canCreatePoll: CR.canCreatePoll(found.crew, found.me) });
  }));

  r.post('/crews/:crewId/polls', pollsFeature, pollCreateLimiter, wrap(async (req, res) => {
    const found = await mine(req);
    if (!found) return res.status(404).json(NOT_FOUND);
    let poll;
    try { poll = await CR.createPoll(soda, found.crew, found.me, req.body); } catch (e) { return sendErr(res, e); }
    const meDoc = await U.ensureUsername(repo, await repo.findUserById(req.user.userId));
    await toMembers(found.crew.crewId, { type: 'POLL_CREATED', crewId: found.crew.crewId, crewName: found.crew.name, pollId: poll.pollId, question: poll.question, username: meDoc.username }, req.user.userId);
    res.status(201).json({ ok: true, poll: await onePoll(poll, req.user.userId, found.me) });
  }));

  const pollOf = async (req, res) => {
    const found = await mine(req);
    if (!found) { res.status(404).json(NOT_FOUND); return null; }
    const poll = await CR.getPoll(soda, found.crew.crewId, String(req.params.pollId || ''));
    if (!poll) { res.status(404).json({ error: 'Poll not found.', code: 'POLL_NOT_FOUND' }); return null; }
    return { ...found, poll };
  };
  const updated = (crewId, pollId, extra = {}) => toMembers(crewId, { type: 'POLL_UPDATED', crewId, pollId, ...extra });

  r.post('/crews/:crewId/polls/:pollId/vote', pollsFeature, voteLimiter, wrap(async (req, res) => {
    const f = await pollOf(req, res);
    if (!f) return;
    try { await CR.castVote(soda, f.poll, req.user.userId, req.body?.optionIds); } catch (e) { return sendErr(res, e); }
    await updated(f.crew.crewId, f.poll.pollId);
    res.json({ ok: true, poll: await onePoll(f.poll, req.user.userId, f.me) });
  }));

  r.delete('/crews/:crewId/polls/:pollId/vote', pollsFeature, voteLimiter, wrap(async (req, res) => {
    const f = await pollOf(req, res);
    if (!f) return;
    try { await CR.retractVote(soda, f.poll, req.user.userId); } catch (e) { return sendErr(res, e); }
    await updated(f.crew.crewId, f.poll.pollId);
    res.json({ ok: true, poll: await onePoll(f.poll, req.user.userId, f.me) });
  }));

  r.post('/crews/:crewId/polls/:pollId/close', pollsFeature, writeLimiter, wrap(async (req, res) => {
    const f = await pollOf(req, res);
    if (!f) return;
    if (!CR.canModeratePoll(f.poll, f.me)) return res.status(403).json({ error: 'Only the poll creator, the crew admin and co-admins can close it.', code: 'NOT_ALLOWED' });
    const poll = await CR.closePoll(soda, f.poll, req.user.userId);
    await updated(f.crew.crewId, poll.pollId, { closed: true });
    res.json({ ok: true, poll: await onePoll(poll, req.user.userId, f.me) });
  }));

  r.delete('/crews/:crewId/polls/:pollId', pollsFeature, writeLimiter, wrap(async (req, res) => {
    const f = await pollOf(req, res);
    if (!f) return;
    if (!CR.canModeratePoll(f.poll, f.me)) return res.status(403).json({ error: 'Only the poll creator, the crew admin and co-admins can delete it.', code: 'NOT_ALLOWED' });
    await CR.deletePoll(soda, f.poll);
    await updated(f.crew.crewId, f.poll.pollId, { deleted: true });
    res.json({ ok: true, deleted: true });
  }));

  // ---- admin console (moderation; not behind the switches) ----
  const audit = async (req, action, target, details = {}) => {
    if (typeof repo.addAuditEntry !== 'function') return;
    await repo.addAuditEntry({ at: Date.now(), by: req.user.email || req.user.userId, byUserId: req.user.userId, action, target, details }).catch(() => {});
  };

  r.get('/admin/crews', requireAdmin, wrap(async (req, res) => {
    await CR.ensureCrewStore(soda);
    const q = String(req.query.q || '').trim().toLowerCase().slice(0, 40);
    const limit = Math.max(1, Math.min(200, parseInt(req.query.limit, 10) || 50));
    let rows = (await soda.query(CR.COLLECTIONS.crews, {}, { limit: 5000 })).map((x) => x.value);
    if (q) rows = rows.filter((c) => c.name.toLowerCase().includes(q) || c.crewId === q);
    rows.sort((a, b) => b.createdAt - a.createdAt);
    const page = rows.slice(0, limit);
    const users = await usersByIds(page.map((c) => c.adminId));
    const out = [];
    for (const c of page) {
      const polls = (await soda.query(CR.COLLECTIONS.polls, { crewId: c.crewId }, { limit: 1000 })).map((x) => x.value);
      out.push({
        crewId: c.crewId, name: c.name, description: c.description || '', memberCount: c.memberCount || 0, createdAt: c.createdAt,
        admin: users.get(c.adminId) ? users.get(c.adminId).username || null : null,
        polls: polls.length, openPolls: polls.filter((p) => CR.pollOpen(p)).length,
      });
    }
    res.set('Cache-Control', 'no-store').json({ ok: true, total: rows.length, crews: out });
  }));

  r.get('/admin/crews/:crewId', requireAdmin, wrap(async (req, res) => {
    const crew = await CR.getCrew(soda, String(req.params.crewId || ''));
    if (!crew) return res.status(404).json(NOT_FOUND);
    const members = await CR.membersOf(soda, crew.crewId);
    const polls = await CR.pollsOf(soda, crew.crewId);
    const users = await usersByIds([...members.map((m) => m.userId), ...polls.map((p) => p.createdBy)]);
    const pollRows = [];
    for (const p of polls) {
      const t = CR.tally(p, await CR.votesOf(soda, p.pollId));
      pollRows.push({
        pollId: p.pollId, question: p.question, options: t.options, totalVoters: t.totalVoters, status: CR.pollOpen(p) ? 'OPEN' : 'CLOSED',
        createdAt: p.createdAt, closesAt: p.closesAt, createdBy: users.get(p.createdBy) ? users.get(p.createdBy).username || null : null,
      });
    }
    res.set('Cache-Control', 'no-store').json({
      ok: true,
      crew: { crewId: crew.crewId, name: crew.name, description: crew.description || '', memberCount: members.length, createdAt: crew.createdAt, settings: crew.settings || {} },
      members: members.map((m) => ({ username: users.get(m.userId) ? users.get(m.userId).username || '' : '', userId: m.userId, role: m.role, joinedAt: m.joinedAt })),
      polls: pollRows,
    });
  }));

  r.delete('/admin/crews/:crewId', requireAdmin, wrap(async (req, res) => {
    const crew = await CR.getCrew(soda, String(req.params.crewId || ''));
    if (!crew) return res.status(404).json(NOT_FOUND);
    const members = await CR.membersOf(soda, crew.crewId);
    await CR.deleteCrew(soda, crew.crewId);
    for (const m of members) notify(m.userId, { type: 'CREW_DELETED', crewId: crew.crewId, crewName: crew.name });
    await audit(req, 'crew.delete', crew.crewId, { name: crew.name, members: members.length });
    res.json({ ok: true, deleted: true });
  }));

  r.delete('/admin/crews/:crewId/polls/:pollId', requireAdmin, wrap(async (req, res) => {
    const crewId = String(req.params.crewId || '');
    const poll = await CR.getPoll(soda, crewId, String(req.params.pollId || ''));
    if (!poll) return res.status(404).json({ error: 'Poll not found.', code: 'POLL_NOT_FOUND' });
    await CR.deletePoll(soda, poll);
    await updated(crewId, poll.pollId, { deleted: true });
    await audit(req, 'crew.poll.delete', poll.pollId, { crewId, question: poll.question });
    res.json({ ok: true, deleted: true });
  }));
}

module.exports = { registerCrewRoutes };
