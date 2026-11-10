'use strict';
/**
 * 3.55 usernames, profiles, friends and profile pictures: HTTP routes and wiring
 * (docs/features_355/usernames_friends_profiles.md).
 *
 * attachSocial({ app, repo, auth, hub, lease, featureFlags, logger }) — once in app.js:
 *   - auth.onUserReady: every account gets a username at registration / sign-in / GET /me; a new
 *     account registered with an invite code sends the inviter a friend request.
 *   - startup backfill of usernames (leased, idempotent) and account-erase cleanup.
 *   - the public invite page GET /join/friend/:code (opens the app, else the download).
 * registerSocialRoutes({ r, repo, auth, hub, wrap, requireAdmin, flagsOf }) — authenticated router.
 *
 * Privacy rules (enforced here, tested in test/usernames_friends_355.test.js):
 *   - Another rider's profile NEVER carries phone, e-mail, medical info, emergency contacts, home or
 *     any location, guardian info, plan or payment, or the userId. Non-friends get the username and
 *     picture only; friends also the first name and ride totals (trips, km, hours, score).
 *   - A rider who blocked me is "not found" to me (same answer as an unknown username) and never gets
 *     my picture. A friend request to a rider who blocked the requester answers exactly like any
 *     unanswered request (202 REQUESTED, shown under "Sent"), so a block is never revealed. An
 *     unknown username or invite code answers 404 (usernames are public through the availability
 *     check anyway), so a typo is never reported as "sent".
 */
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const U = require('./usernames');
const F = require('./friends');
const A = require('./avatars');
const { stampEvent } = require('./push');

const FEATURE_OFF = { error: 'This feature is turned off for now.', code: 'FEATURE_OFF' };
const DAY = 86400000;

const firstNameOf = (name) => String(name || '').trim().split(/\s+/)[0].replace(/[^\p{L}\p{N}' .-]/gu, '').slice(0, 20) || 'Rider';
const round1 = (n) => Math.round(n * 10) / 10;

// ------------------------------------------------------------------ ride totals
const statsCache = new Map(); // userId -> { at, stats }
const STATS_TTL_MS = 2 * 60000;

/**
 * Ride totals from the stored trips (summary records are kept forever): one ride per group (the
 * server-built trip wins over a phone's copy of the same ride), solo trips as they are.
 */
function rideTotals(trips) {
  const byGroup = new Map();
  const solo = [];
  for (const t of trips || []) {
    if (!t || typeof t !== 'object') continue;
    if (!t.groupId) { solo.push(t); continue; }
    const cur = byGroup.get(t.groupId);
    const better = !cur || (t.source === 'server' && cur.source !== 'server')
      || (t.source === cur.source && (Number(t.totalDistanceKm) || 0) > (Number(cur.totalDistanceKm) || 0));
    if (better) byGroup.set(t.groupId, t);
  }
  const rides = [...byGroup.values(), ...solo];
  let km = 0, ms = 0, longest = 0, largest = 0;
  for (const t of rides) {
    const d = Math.max(0, Math.min(5000, Number(t.totalDistanceKm) || 0));
    km += d;
    longest = Math.max(longest, d);
    const moving = Number(t.movingMs) || 0;
    const span = Math.max(0, (Number(t.endTimeEpochMs) || 0) - (Number(t.startTimeEpochMs) || 0));
    ms += Math.min(48 * 3600000, moving > 0 ? moving : span);
    largest = Math.max(largest, Math.min(1000, Math.round(Number(t.riderCount) || (t.groupId ? 0 : 1))));
  }
  return {
    trips: rides.length, totalKm: round1(km), ridingHours: round1(ms / 3600000),
    longestTripKm: round1(longest), largestGroup: largest,
  };
}

async function rideStatsOf(repo, userId, { fresh = false } = {}) {
  const c = statsCache.get(userId);
  if (!fresh && c && Date.now() - c.at < STATS_TTL_MS) return c.stats;
  const trips = await repo.listTripsForUser(userId, 1000).catch(() => []);
  const stats = rideTotals(trips);
  statsCache.set(userId, { at: Date.now(), stats });
  if (statsCache.size > 5000) statsCache.delete(statsCache.keys().next().value);
  return stats;
}

/** The stored rider score (scoring module's collection), or null. Read-only. */
async function storedScoreOf(repo, userId) {
  try {
    const coll = (() => { try { return require('./rider_score').COLLECTION; } catch { return 'rider_scores'; } })();
    const r = await repo.soda.findOne(coll, { userId });
    const v = r && r.value;
    if (!v || typeof v.score !== 'number' || v.eligible === false) return null;
    return { score: Math.round(v.score), level: typeof v.level === 'string' ? v.level : null };
  } catch { return null; }
}

// ------------------------------------------------------------------ views
function avatarOf(u, flagsOf) {
  const fl = flagsOf ? flagsOf() : null;
  if (fl && !fl.isOn('profilePhotos')) return null;
  return A.avatarUrlOf(u && u.avatarId);
}

/** Small public card (lists, non-friends): username + picture only. */
function cardOf(u, flagsOf) {
  return { username: u.username || '', avatarUrl: avatarOf(u, flagsOf) };
}

function inviteLinkOf(code) {
  const origin = config.publicOrigin || config.linkOrigin;
  return `${origin.replace(/\/+$/, '')}/join/friend/${code}`;
}
const shareTextOf = (username, code) =>
  `Ride with me on CoRoute! Add me as a friend: ${username} (invite code ${code}). ${inviteLinkOf(code)}`;

// ------------------------------------------------------------------ wiring
function attachSocial({ app, repo, auth, hub = null, lease = null, featureFlags = null, logger = console, site = null, pageVars = null }) {
  const soda = repo.soda;
  const flagOn = (id) => !featureFlags || featureFlags.isOn(id);

  auth.onUserReady = async (user, ctx = {}) => {
    const u = await U.ensureUsername(repo, user);
    if (ctx.created && ctx.inviteCode && flagOn('friends')) {
      try {
        const inviterId = await F.userIdByInviteCode(soda, ctx.inviteCode);
        if (inviterId && inviterId !== u.userId) {
          const out = await F.sendRequest(soda, u.userId, inviterId, { via: 'invite' });
          if (out.created && !out.edge.shadow && hub) {
            const ev = stampEvent({ type: 'FRIEND_REQUEST', requestId: out.edge.requestId, username: u.username, via: 'invite' });
            const delivered = hub.sendToUser(inviterId, ev) || 0;
            if (hub.push) hub.push.onSocketEvent(inviterId, ev, { delivered }).catch(() => {});
          }
        }
      } catch (e) { logger.warn?.(`[friends] invite request not sent: ${e.message}`); }
    }
    return u;
  };

  // Account erase: usernames, friend edges, blocks, invite codes and pictures go with the account.
  const cascade = repo.deleteUserCascade.bind(repo);
  repo.deleteUserCascade = async (user, opts) => {
    const out = await cascade(user, opts);
    const uid = user && user.userId;
    if (uid) {
      await U.forgetUsernames(repo, uid).catch(() => {});
      await F.forgetFriends(soda, uid).catch(() => {});
      await A.forgetAvatars(soda, uid).catch(() => {});
      statsCache.delete(uid);
    }
    return out;
  };

  // Usernames for every older account (idempotent; leased so two nodes do not both scan).
  const run = () => U.backfillUsernames(repo, { logger });
  const started = lease && typeof lease.once === 'function' ? lease.once('username-backfill', run) : run();
  Promise.resolve(started).catch((e) => logger.warn?.(`[usernames] backfill failed: ${e.message}`));

  // Invite link: https://<site>/join/friend/<CODE> (Android App Links cover /join/). Opens the app
  // (coroute://join/friend/<CODE>), else offers the download. Never says whose code it is.
  const pageLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false });
  if (app) {
    app.get('/join/friend/:code', pageLimiter, (req, res) => {
      const code = F.normaliseInvite(req.params.code);
      if (!F.isInviteCode(code)) return res.redirect(302, '/');
      res.type('html').set('Cache-Control', 'no-store').set('X-Robots-Tag', 'noindex').set('Referrer-Policy', 'no-referrer')
        // The website design (shared header / footer partials, site.css) when the page is loaded; the
        // built-in plain page otherwise.
        .send(site && site.has('join_friend.html')
          ? site.render('join_friend.html', { ...(pageVars ? pageVars(req) : {}), __CODE__: code })
          : friendInvitePage(code));
    });
  }
}

function friendInvitePage(code) {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
    + '<meta name="robots" content="noindex"><title>Friend invite | CoRoute</title><link rel="stylesheet" href="/assets/site.css">'
    + '<style>main{max-width:34rem;margin:0 auto;padding:32px 16px;text-align:center;font-family:system-ui,sans-serif}'
    + '.code{font-size:2.4rem;font-weight:700;letter-spacing:.14em;margin:16px 0;overflow-wrap:anywhere}'
    + '.btn{display:block;margin:12px auto;max-width:320px;padding:14px 20px;border:2px solid currentColor;border-radius:12px;text-decoration:none;font-weight:700}</style>'
    + '</head><body><main><h1>You have a friend invite</h1>'
    + '<p>Open CoRoute to add your riding friend. New to CoRoute? Install it and enter this invite code when you sign up.</p>'
    + `<p class="code" aria-label="Invite code">${code}</p>`
    + `<a class="btn" href="coroute://join/friend/${code}">Open in CoRoute</a>`
    + '<a class="btn" href="/download">Get CoRoute</a></main></body></html>';
}

// ------------------------------------------------------------------ routes
function registerSocialRoutes({ r, repo, auth, hub = null, wrap, requireAdmin, flagsOf = () => null }) {
  const soda = repo.soda;
  const perUser = (req) => req.user?.userId || req.ip;
  const limiter = (windowMs, limit, message) => rateLimit({ windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: perUser, message: { error: message, code: 'RATE_LIMITED' } });
  const availabilityLimiter = limiter(60 * 1000, 30, 'Too many checks. Wait a minute.');
  const usernameWriteLimiter = limiter(60 * 60 * 1000, 10, 'Too many attempts. Try again later.');
  const requestLimiter = limiter(DAY, 20, 'You can send up to 20 friend requests a day.');
  const friendWriteLimiter = limiter(60 * 1000, 60, 'Too many changes. Wait a minute.');
  const profileLimiter = limiter(60 * 1000, 60, 'Too many requests. Wait a minute.');
  const avatarUploadLimiter = limiter(60 * 60 * 1000, 10, 'Too many picture uploads. Try again later.');
  const avatarReadLimiter = limiter(60 * 1000, 300, 'Too many requests.');
  const isOn = (id) => { const fl = flagsOf(); return !fl || fl.isOn(id); };
  const feature = (id) => (req, res, next) => (isOn(id) ? next() : res.status(403).set('Cache-Control', 'no-store').json({ ...FEATURE_OFF, feature: id }));
  const sendErr = (res, e) => {
    if (e instanceof U.UsernameError || e instanceof F.FriendError || e instanceof A.AvatarError) {
      return res.status(e.status).json({ error: e.message, code: e.code, ...(e.nextChangeAt ? { nextChangeAt: e.nextChangeAt } : {}) });
    }
    throw e;
  };
  const me = async (req) => {
    // Always the stored document (the session gate's cached copy may predate a change).
    const u = await repo.findUserById(req.user.userId);
    if (!u) throw Object.assign(new Error('This account no longer exists.'), { statusCode: 404 });
    return U.ensureUsername(repo, u);
  };
  const notify = (userId, payload) => {
    let delivered = 0;
    // One eventId for the socket message and the push (the app shows one notice per id).
    stampEvent(payload);
    try { if (hub) delivered = hub.sendToUser(userId, payload) || 0; } catch { /* best effort */ }
    // 3.55 push (src/push.js): a phone with the app closed still hears about it.
    try { if (hub && hub.push) hub.push.onSocketEvent(userId, payload, { delivered }).catch(() => {}); } catch { /* best effort */ }
  };

  // ---- own profile ----
  r.get('/me/profile', profileLimiter, wrap(async (req, res) => {
    const u = await me(req);
    const code = isOn('friends') ? await F.inviteCodeOf(soda, u.userId) : null;
    const last = Number(u.usernameChangedAt) || 0;
    res.set('Cache-Control', 'no-store').json({
      ok: true,
      profile: {
        username: u.username, name: u.name || '', avatarUrl: avatarOf(u, flagsOf),
        publicLeaderboard: u.publicLeaderboard !== false,
        usernameChangedAt: last, nextUsernameChangeAt: last ? last + U.CHANGE_MS : 0,
        memberSince: Number(u.createdAt) || 0,
        inviteCode: code, inviteLink: code ? inviteLinkOf(code) : null, shareText: code ? shareTextOf(u.username, code) : null,
      },
      stats: { ...(await rideStatsOf(repo, u.userId)), memberSince: Number(u.createdAt) || 0 },
    });
  }));

  r.get('/me/stats', profileLimiter, wrap(async (req, res) => {
    const u = await me(req);
    res.set('Cache-Control', 'no-store').json({ ok: true, stats: { ...(await rideStatsOf(repo, u.userId, { fresh: req.query.fresh === '1' })), memberSince: Number(u.createdAt) || 0 } });
  }));

  r.get('/users/username-available', availabilityLimiter, wrap(async (req, res) => {
    const out = await U.usernameAvailability(repo, String(req.query.u || '').slice(0, 40), req.user.userId);
    res.set('Cache-Control', 'no-store').json({ ok: true, ...out });
  }));

  r.patch('/me/username', usernameWriteLimiter, wrap(async (req, res) => {
    const u = await me(req);
    try {
      const out = await U.changeUsername(repo, u, req.body?.username);
      auth.gate?.invalidate?.(u.userId);
      res.json({ ok: true, username: out.username, usernameChangedAt: out.usernameChangedAt || 0, nextUsernameChangeAt: out.usernameChangedAt ? out.usernameChangedAt + U.CHANGE_MS : 0 });
    } catch (e) { sendErr(res, e); }
  }));

  r.patch('/me/privacy', friendWriteLimiter, wrap(async (req, res) => {
    const v = req.body?.publicLeaderboard;
    if (typeof v !== 'boolean') return res.status(400).json({ error: 'publicLeaderboard must be on or off.', code: 'BAD_REQUEST' });
    const u = await me(req);
    await repo.updateUser(u.key, { publicLeaderboard: v });
    auth.gate?.invalidate?.(u.userId);
    res.json({ ok: true, publicLeaderboard: v });
  }));

  // ---- profile pictures ----
  const rawAvatar = express.raw({ type: () => true, limit: A.MAX_BYTES });
  r.post('/me/avatar', feature('profilePhotos'), avatarUploadLimiter, (req, res, next) => {
    if (req.is('application/json') || req.is('multipart/form-data')) {
      return res.status(415).json({ error: 'Send the picture bytes as image/jpeg, image/png or image/webp.', code: 'UNSUPPORTED_PHOTO' });
    }
    rawAvatar(req, res, (err) => {
      if (!err) return next();
      if (err.type === 'entity.too.large') return res.status(413).json({ error: 'This picture is too large (up to 2 MB).', code: 'PHOTO_TOO_LARGE' });
      return res.status(400).json({ error: 'The picture did not arrive complete. Please try again.', code: 'NO_PHOTO' });
    });
  }, wrap(async (req, res) => {
    const u = await me(req);
    try {
      const out = await A.saveAvatar(repo, u, req.body);
      auth.gate?.invalidate?.(u.userId);
      res.status(201).json({ ok: true, avatarUrl: out.avatarUrl });
    } catch (e) { sendErr(res, e); }
  }));

  r.delete('/me/avatar', friendWriteLimiter, wrap(async (req, res) => {
    const removed = await A.removeAvatar(repo, req.user.userId);
    auth.gate?.invalidate?.(req.user.userId);
    res.json({ ok: true, removed });
  }));

  r.get('/avatars/:avatarId', feature('profilePhotos'), avatarReadLimiter, wrap(async (req, res) => {
    const found = await A.readAvatar(soda, String(req.params.avatarId || ''));
    const admin = req.user.role === 'MASTER_ADMIN';
    if (!found || (!admin && await F.hasBlocked(soda, found.userId, req.user.userId))) {
      return res.status(404).set('Cache-Control', 'no-store').json({ error: 'Not found' });
    }
    res.set('Cache-Control', 'private, max-age=86400, immutable').set('Content-Type', found.mime)
      .set('Content-Disposition', 'inline').set('X-Content-Type-Options', 'nosniff').set('X-Robots-Tag', 'noindex').send(found.data);
  }));

  // ---- other riders ----
  /** Target user doc for :username, or null when unknown OR when the target blocked the viewer. */
  const visibleTarget = async (req, raw) => {
    const t = await U.findUserByUsername(repo, raw);
    if (!t || t.status === 'BLOCKED') return null;
    if (t.userId !== req.user.userId && await F.hasBlocked(soda, t.userId, req.user.userId)) return null;
    return t;
  };

  r.get('/users/:username/profile', profileLimiter, wrap(async (req, res) => {
    const t = await visibleTarget(req, String(req.params.username || ''));
    if (!t) return res.status(404).set('Cache-Control', 'no-store').json({ error: 'Rider not found.', code: 'NOT_FOUND' });
    const self = t.userId === req.user.userId;
    const blockedByMe = !self && await F.hasBlocked(soda, req.user.userId, t.userId);
    const relation = self ? 'SELF' : blockedByMe ? 'BLOCKED' : await F.relationOf(soda, req.user.userId, t.userId);
    const profile = { ...cardOf(t, flagsOf), relation };
    if (blockedByMe) profile.avatarUrl = null;
    if (self || (relation === 'FRIENDS' && isOn('friends'))) {
      const s = await rideStatsOf(repo, t.userId);
      const score = await storedScoreOf(repo, t.userId);
      Object.assign(profile, {
        displayName: firstNameOf(t.name),
        stats: { trips: s.trips, totalKm: s.totalKm, ridingHours: s.ridingHours, score: score ? score.score : null, level: score ? score.level : null },
      });
    }
    res.set('Cache-Control', 'private, no-store').json({ ok: true, profile });
  }));

  // Riders of a ride I am in: username + picture per userId (group riders already know each other's ids).
  r.get('/convoys/:groupId/usernames', profileLimiter, wrap(async (req, res) => {
    const meta = await repo.getConvoyMeta(String(req.params.groupId || ''));
    const mine = meta && meta.members && meta.members[req.user.userId];
    if (!mine && req.user.role !== 'MASTER_ADMIN') return res.status(403).json({ error: 'Not a member of this convoy.', code: 'NOT_MEMBER' });
    const ids = Object.keys(meta.members || {}).slice(0, 500);
    const out = {};
    for (let i = 0; i < ids.length; i += 100) {
      const rows = await soda.query('users', { userId: { $in: ids.slice(i, i + 100) } }, { limit: 100 });
      for (const row of rows) {
        const u = row.value.username ? row.value : await U.ensureUsername(repo, { ...row.value, key: row.key }).catch(() => row.value);
        if (u.username) out[u.userId] = cardOf(u, flagsOf);
      }
    }
    res.set('Cache-Control', 'private, max-age=60').json({ ok: true, riders: out });
  }));

  // ---- friends ----
  for (const p of ['/friends', '/friends/*']) r.use(p, feature('friends'));

  const usersByIds = async (ids) => {
    const map = new Map();
    const list = [...new Set(ids)];
    for (let i = 0; i < list.length; i += 100) {
      const rows = await soda.query('users', { userId: { $in: list.slice(i, i + 100) } }, { limit: 100 });
      for (const row of rows) map.set(row.value.userId, { ...row.value, key: row.key });
    }
    return map;
  };

  r.get('/friends', profileLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { friends, incoming, outgoing } = await F.listFor(soda, uid);
    const blocks = await F.blockedBy(soda, uid);
    const other = (e) => (e.a === uid ? e.b : e.a);
    const users = await usersByIds([...friends, ...incoming, ...outgoing].map(other).concat(blocks.map((b) => b.blocked)));
    const withName = async (id) => {
      const u = users.get(id);
      if (!u) return null;
      return u.username ? u : U.ensureUsername(repo, u).catch(() => null);
    };
    const friendRows = [];
    for (const e of friends) {
      const u = await withName(other(e));
      if (!u) continue;
      const s = await rideStatsOf(repo, u.userId);
      friendRows.push({ ...cardOf(u, flagsOf), displayName: firstNameOf(u.name), since: e.respondedAt || e.createdAt, trips: s.trips, totalKm: s.totalKm });
    }
    const reqRow = async (e) => {
      const u = await withName(other(e));
      return u ? { requestId: e.requestId, ...cardOf(u, flagsOf), at: e.createdAt } : null;
    };
    const blockedRows = [];
    for (const b of blocks) {
      const u = await withName(b.blocked);
      if (u) blockedRows.push({ username: u.username, at: b.at });
    }
    const code = await F.inviteCodeOf(soda, uid);
    const meDoc = await me(req);
    res.set('Cache-Control', 'no-store').json({
      ok: true,
      friends: friendRows.sort((x, y) => x.username.localeCompare(y.username)),
      incoming: (await Promise.all(incoming.map(reqRow))).filter(Boolean).sort((x, y) => y.at - x.at),
      outgoing: (await Promise.all(outgoing.map(reqRow))).filter(Boolean).sort((x, y) => y.at - x.at),
      blocked: blockedRows,
      inviteCode: code, inviteLink: inviteLinkOf(code), shareText: shareTextOf(meDoc.username, code),
    });
  }));

  r.get('/friends/invite', profileLimiter, wrap(async (req, res) => {
    const u = await me(req);
    const code = await F.inviteCodeOf(soda, u.userId);
    res.set('Cache-Control', 'no-store').json({ ok: true, inviteCode: code, inviteLink: inviteLinkOf(code), shareText: shareTextOf(u.username, code) });
  }));

  /**
   * Add a friend by username or invite code (docs/features_355/usernames_friends_profiles.md).
   *   - unknown username / invite code: 404 NOT_FOUND with a clear message (whether a username is
   *     taken is public anyway through GET /users/username-available; an invite code cannot be
   *     guessed and requests are limited to 20 a day). A silent "sent" for a typo left the request
   *     nowhere in the app: not under the sender's "Sent", never with the other rider.
   *   - a rider who blocked me: the same 202 {status:'REQUESTED', request} as any unanswered request
   *     (a shadow edge the requester sees under "Sent" and the target never sees), so a block is
   *     never revealed.
   * The 202 carries the sender's own view of the request (`request`: the same row as GET /friends
   * `outgoing`), so the app shows it under "Sent" at once.
   */
  r.post('/friends/requests', requestLimiter, wrap(async (req, res) => {
    const body = req.body && typeof req.body === 'object' ? req.body : {};
    const uid = req.user.userId;
    let target = null;
    let via = 'username';
    if (typeof body.inviteCode === 'string' && body.inviteCode.trim()) {
      via = 'invite';
      const tid = await F.userIdByInviteCode(soda, body.inviteCode);
      target = tid ? await repo.findUserById(tid) : null;
      if (!target || target.status === 'BLOCKED') {
        return res.status(404).json({ error: 'This invite code is not valid. Check it and try again.', code: 'NOT_FOUND' });
      }
    } else if (typeof body.username === 'string' && body.username.trim()) {
      // "@SwiftFalcon482" (as the app shows names) and any capitals find the same rider.
      const name = body.username.trim().replace(/^@+/, '').trim();
      const v = U.validateUsername(name);
      if (!v.ok && v.code === 'USERNAME_FORMAT') return res.status(400).json({ error: 'Enter a username.', code: 'BAD_USERNAME' });
      target = await U.findUserByUsername(repo, name);
      if (!target || target.status === 'BLOCKED') {
        return res.status(404).json({ error: 'No rider has that username. Check the spelling.', code: 'NOT_FOUND' });
      }
    } else {
      return res.status(400).json({ error: 'Enter a username or an invite code.', code: 'BAD_REQUEST' });
    }
    if (target.userId === uid) return res.status(400).json({ error: 'That is you.', code: 'SELF' });
    let out;
    try { out = await F.sendRequest(soda, uid, target.userId, { via }); } catch (e) { return sendErr(res, e); }
    const named = await U.ensureUsername(repo, target);
    const card = cardOf(named, flagsOf);
    if (out.status === 'REQUESTED') {
      if (out.created && !out.edge.shadow) {
        const mine = await me(req);
        notify(target.userId, { type: 'FRIEND_REQUEST', requestId: out.edge.requestId, username: mine.username, via });
      }
      const edge = out.edge || {};
      return res.status(202).json({ ok: true, status: 'REQUESTED', request: { requestId: edge.requestId, ...card, at: edge.createdAt || Date.now() } });
    }
    if (out.status === 'FRIENDS') {
      const mine = await me(req);
      notify(target.userId, { type: 'FRIEND_ACCEPTED', username: mine.username });
    }
    res.status(200).json({ ok: true, status: out.status, friend: card });
  }));

  const respond = (yes) => wrap(async (req, res) => {
    const e = await F.respond(soda, req.user.userId, String(req.params.requestId || ''), yes);
    if (!e) return res.status(404).json({ error: 'This request is no longer waiting.', code: 'NOT_FOUND' });
    if (yes) {
      const mine = await me(req);
      notify(e.from, { type: 'FRIEND_ACCEPTED', requestId: e.requestId, username: mine.username });
    }
    res.json({ ok: true, status: yes ? 'FRIENDS' : 'DECLINED' });
  });
  r.post('/friends/requests/:requestId/accept', friendWriteLimiter, respond(true));
  r.post('/friends/requests/:requestId/decline', friendWriteLimiter, respond(false));
  r.delete('/friends/requests/:requestId', friendWriteLimiter, wrap(async (req, res) => {
    const ok = await F.cancelRequest(soda, req.user.userId, String(req.params.requestId || ''));
    res.status(ok ? 200 : 404).json(ok ? { ok: true } : { error: 'This request is no longer waiting.', code: 'NOT_FOUND' });
  }));
  r.delete('/friends/:username', friendWriteLimiter, wrap(async (req, res) => {
    const t = await U.findUserByUsername(repo, String(req.params.username || ''));
    const ok = !!t && await F.removeFriend(soda, req.user.userId, t.userId);
    res.json({ ok: true, removed: ok });
  }));

  // ---- blocks (a safety tool: available even while the friends switch is off) ----
  r.get('/blocks', profileLimiter, wrap(async (req, res) => {
    const blocks = await F.blockedBy(soda, req.user.userId);
    const users = await usersByIds(blocks.map((b) => b.blocked));
    res.set('Cache-Control', 'no-store').json({ ok: true, blocked: blocks.map((b) => users.get(b.blocked)).filter((u) => u && u.username).map((u) => ({ username: u.username })) });
  }));
  r.post('/blocks', friendWriteLimiter, wrap(async (req, res) => {
    const t = await U.findUserByUsername(repo, String(req.body?.username || ''));
    // Unknown usernames answer the same (no enumeration through the block button).
    if (!t) return res.json({ ok: true, blocked: true });
    try { await F.block(soda, req.user.userId, t.userId); } catch (e) { return sendErr(res, e); }
    res.json({ ok: true, blocked: true });
  }));
  r.delete('/blocks/:username', friendWriteLimiter, wrap(async (req, res) => {
    const t = await U.findUserByUsername(repo, String(req.params.username || ''));
    const ok = !!t && await F.unblock(soda, req.user.userId, t.userId);
    res.json({ ok: true, unblocked: ok });
  }));

  // ---- admin ----
  r.delete('/admin/users/:userId/avatar', requireAdmin, wrap(async (req, res) => {
    const userId = String(req.params.userId || '');
    const removed = await A.removeAvatar(repo, userId, { by: req.user.userId });
    if (removed && typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({ at: Date.now(), by: req.user.email || req.user.userId, byUserId: req.user.userId, action: 'user.avatar.remove', target: userId, details: {} }).catch(() => {});
    }
    auth.gate?.invalidate?.(userId);
    res.json({ ok: true, removed });
  }));
  r.get('/admin/users/:userId/social', requireAdmin, wrap(async (req, res) => {
    const u = await repo.findUserById(String(req.params.userId || ''));
    if (!u) return res.status(404).json({ error: 'User not found.' });
    const withName = await U.ensureUsername(repo, u);
    const { friends, incoming, outgoing } = await F.listFor(soda, u.userId);
    res.set('Cache-Control', 'no-store').json({
      ok: true, username: withName.username, avatarUrl: A.avatarUrlOf(u.avatarId), publicLeaderboard: u.publicLeaderboard !== false,
      usernameChangedAt: Number(u.usernameChangedAt) || 0, friends: friends.length, pendingIn: incoming.length, pendingOut: outgoing.length,
    });
  }));
  r.post('/admin/usernames/backfill', requireAdmin, wrap(async (req, res) => {
    res.json({ ok: true, ...(await U.backfillUsernames(repo)) });
  }));
}

module.exports = { attachSocial, registerSocialRoutes, rideTotals, firstNameOf, inviteLinkOf, friendInvitePage, _statsCache: statsCache };
