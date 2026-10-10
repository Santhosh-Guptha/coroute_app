'use strict';
const express = require('express');
const rateLimit = require('express-rate-limit');
const { requireAuth, requireAdmin, AuthError } = require('./auth');
const { ValidationError, tripRecord, sitePath, weatherPoints, liveTokenOf } = require('./validate');
const { identity } = require('./anonymise');
const { ConvoyError, falseAlarmCount, sha256 } = require('./convoys');
const config = require('./config');
const { featurePolicy } = require('./feature_policy');
const { visibleWindow, eventVisible, publicEvent } = require('./timeline');
const { toWire, toGpx, filterPoints, validateChunk, uploadPermission, TrackError } = require('./tracks');

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

/**
 * @param {{auth: import('./auth').AuthService, convoys: import('./convoys').ConvoyManager, repo: any, soda: any, hub: any, startedAt:number}} deps
 */
function buildRouter({ auth, convoys, repo, soda, hub, startedAt, tracks, timeline, geo, essentials, gate, network = null, audit = null, publicLiveLimiter = null }) {
  const r = express.Router();
  r.use((req, res, next) => {
    const feature = req.path.startsWith('/geo/essentials') ? 'essentials' : req.path.startsWith('/geo/weather') ? 'weather'
      : req.path.startsWith('/geo/route') ? 'route' : req.path.startsWith('/geo/') ? 'places'
      : req.path.startsWith('/trips') ? 'trips' : null;
    const started = Date.now();
    if (feature) res.once('finish', () => convoys.featureAnalytics?.record(feature, res.statusCode < 400, Date.now() - started));
    next();
  });
  const originOf = (req) => config.publicOrigin || `${req.protocol}://${req.get('host')}`;

  const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many attempts, try again later.' } });
  const apiLimiter = rateLimit({ windowMs: 60 * 1000, limit: 240, standardHeaders: 'draft-7', legacyHeaders: false });

  // ---- public ----
  r.get('/health', wrap(async (req, res) => {
    let db = 'DOWN';
    try { db = (await soda.ping()) ? 'UP' : 'DEGRADED'; } catch { db = 'DOWN'; }
    res.status(db === 'UP' ? 200 : 503).json({
      status: db === 'UP' ? 'HEALTHY' : 'DEGRADED',
      uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
      db,
      rooms: convoys.rooms.size,
      sockets: hub ? hub.wss.clients.size : 0,
      version: require('../package.json').version,
    });
  }));

  // App metadata: version gate + links. Public, cacheable.
  r.get('/meta', (req, res) => {
    const origin = config.publicOrigin || `${req.protocol}://${req.get('host')}`;
    res.set('Cache-Control', 'public, max-age=300').json({
      minBuild: config.minAppBuild,
      latestBuild: config.latestAppBuild,
      downloadUrl: `${origin}/download`,
      privacyUrl: `${origin}/privacy`,
      termsUrl: `${origin}/terms`,
      supportEmail: config.supportEmail,
      googleSignIn: config.googleClientIds.length > 0,
      guardianPersonal: process.env.GUARDIAN_ENABLED === 'true',
    });
  });

  r.post('/auth/register', authLimiter, wrap(async (req, res) => res.status(201).json(await auth.register(req.body || {}))));
  r.post('/auth/login', authLimiter, wrap(async (req, res) => res.json(await auth.login(req.body || {}))));
  r.post('/auth/google', authLimiter, wrap(async (req, res) => res.json(await auth.loginWithGoogle(req.body || {}))));

  // ---- website endpoints (public, rate-limited, no cookies, no personal data stored for analytics) ----
  const siteLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false });
  const feedbackLimiter = rateLimit({ windowMs: 60 * 60 * 1000, limit: 5, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many messages from this network. Please try again later.' } });

  r.post('/pv', siteLimiter, express.text({ type: '*/*', limit: '2kb' }), wrap(async (req, res) => {
    let body = {};
    try { body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {}); } catch { body = {}; }
    // Only the site's own pages are counted (anything else would grow the table without limit).
    const path = sitePath(body.path);
    if (!path) return res.status(204).end();
    let refHost = '';
    try { if (body.ref) refHost = new URL(String(body.ref)).hostname.slice(0, 80); } catch { /* ignore */ }
    const day = new Date().toISOString().slice(0, 10);
    repo.countPageview(day, path, refHost, config.pvMaxReferrers).catch(() => {});
    res.status(204).end();
  }));

  r.post('/feedback', feedbackLimiter, wrap(async (req, res) => {
    const b = req.body || {};
    // Honeypot: real users never fill the hidden "website" field. Timing: humans take > 3 s.
    if (b.website) return res.status(204).end();
    const started = Number(b.t);
    if (!Number.isFinite(started) || Date.now() - started < 3000) return res.status(400).json({ error: 'Please take a moment and try again.' });
    const name = String(b.name || '').trim().slice(0, 80);
    const email = String(b.email || '').trim().toLowerCase();
    const message = String(b.message || '').trim();
    const errors = {};
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) errors.email = 'Enter a valid e-mail address.';
    if (message.length < 20) errors.message = 'Please write at least 20 characters.';
    if (message.length > 2000) errors.message = 'Please keep it under 2000 characters.';
    if (/https?:\/\/\S+/gi.test(message) && (message.match(/https?:\/\//gi) || []).length > 2) errors.message = 'Too many links.';
    if (Object.keys(errors).length) return res.status(422).json({ error: 'Please correct the highlighted fields.', fields: errors });
    await repo.addFeedback({
      name, email, message, createdAt: Date.now(),
      userAgent: String(req.headers['user-agent'] || '').slice(0, 160),
      appVersion: String(b.appVersion || '').slice(0, 40),
      device: String(b.device || '').slice(0, 80),
      source: b.appVersion ? 'app' : 'web',
    });
    res.status(201).json({ ok: true });
  }));

  // ---- live emergency link (3.16): public, no auth, per-IP limited, never cached or indexed ----
  // The token is only ever compared by hash; a malformed token is a 404, a dead link a 410, and neither
  // says anything about other links. Views are audited at most once per link per 5 minutes (no IP, no token).
  const liveLimiter = publicLiveLimiter || rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  const viewAudited = new Map(); // hash -> last audit time
  r.get('/public/live/:token', liveLimiter, (req, res) => {
    res.set('Cache-Control', 'no-store').set('X-Robots-Tag', 'noindex').set('Referrer-Policy', 'no-referrer');
    const token = liveTokenOf(req.params.token);
    if (!token) return res.status(404).json({ error: 'Not found' });
    const hash = sha256(token);
    const view = convoys.liveView(hash);
    if (!view) return res.status(410).json({ error: 'This link has expired.' });
    const t = Date.now();
    if (audit && t - (viewAudited.get(hash) || 0) >= 5 * 60000) {
      viewAudited.set(hash, t);
      const ref = convoys.liveLinks.get(hash);
      audit.add({ kind: 'LIVE_LINK', alertId: ref?.alertId, groupId: ref?.gid, detail: 'VIEW' });
      if (viewAudited.size > 2000) for (const [k, at] of viewAudited) if (t - at >= 5 * 60000) viewAudited.delete(k);
    }
    res.json(view);
  });

  // ---- authenticated ----
  r.use(requireAuth(gate), apiLimiter);

  r.get('/me', wrap(async (req, res) => {
    const me = await auth.me(req.user.userId, { appBuild: parseInt(req.get('X-CoRoute-Build') || '0', 10) });
    // Sliding session: a rider who opens the app at least once a month is never signed out.
    // The new token is built from the database user, so role changes take effect too.
    if (Date.now() - (req.tokenIssuedAt || 0) > config.tokenRefreshAfterHours * 3600000) {
      // Signed from the database document so the token carries the current password version.
      res.set('X-CoRoute-Token', auth.issueToken(req.dbUser || me));
    }
    res.json(me);
  }));
  r.patch('/me', wrap(async (req, res) => res.json(await auth.updateProfile(req.user.userId, req.body || {}))));
  /**
   * Before an account is erased: leave every convoy, let a trip that just ended finish writing,
   * then remove the rider from convoys loaded in memory (so a later save cannot bring the name back).
   */
  async function prepareErase(user) {
    // Close the rider's sockets first, so nothing they send can be written during the erase.
    if (hub) hub.disconnectUser(user.userId, 4401, 'ACCOUNT_GONE');
    // 3.15: out of every safety network incident (their own ones close; queued audit rows dropped).
    if (network) network.forgetUser(user.userId);
    await convoys.leaveAll(user.userId);
    if (timeline) await timeline.idle();
    const id = identity(user);
    const skipGroups = await convoys.forgetUser(id);
    if (timeline) timeline.forgetUser(user.userId, id);
    return { id, skipGroups };
  }
  r.post('/me/password', wrap(async (req, res) => res.json(await auth.changePassword(req.user.userId, req.body || {}))));
  r.delete('/me', wrap(async (req, res) => {
    const out = await auth.deleteAccount(req.user.userId, { prepare: prepareErase });
    if (hub) hub.disconnectUser(req.user.userId, 4401, 'ACCOUNT_GONE');
    res.json(out);
  }));

  // Convoys
  // Every rider (not only new app builds) needs the safety profile before riding in a group.
  const ensureProfileComplete = async (req) => {
    if (req.user?.role === 'MASTER_ADMIN') return;
    const u = req.dbUser || await repo.findUserById(req.user.userId);
    if (!u) return;
    const isPillion = (u.vehicleType || '').trim().toLowerCase() === 'pillion rider' || (u.vehicleNo || '').trim().toUpperCase() === 'PILLION';
    const complete = Boolean(
      (u.name || '').trim().length >= 2 &&
      (u.phone || '').trim().length >= 7 &&
      (isPillion || (u.vehicleNo || '').trim().length >= 2) &&
      (u.emergencyContact || '').trim().length >= 7 &&
      (u.emergencyContactName || '').trim().length >= 2
    );
    if (!complete) {
      // (An AuthError, so the error handler answers 400 with the code; a plain Error became a 500.)
      throw new AuthError('Add your phone number, bike number (or pillion) and emergency contact in your profile before creating or joining a convoy.', 400, 'PROFILE_INCOMPLETE');
    }
  };

  r.post('/convoys', wrap(async (req, res) => {
    await ensureProfileComplete(req);
    res.status(201).json(await convoys.createConvoy(req.user, req.body || {}));
  }));
  // Join codes are short, so wrong codes are limited per rider and per network; correct joins do not count.
  const joinMessage = { error: `Too many wrong codes. Try again in ${config.joinWindowMin} minutes.`, code: 'TOO_MANY_ATTEMPTS' };
  const joinLimiterUser = rateLimit({
    windowMs: config.joinWindowMin * 60000, limit: config.joinMaxFailures, skipSuccessfulRequests: true,
    standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `u:${req.user.userId}`, message: joinMessage,
  });
  const joinLimiterIp = rateLimit({
    windowMs: config.joinWindowMin * 60000, limit: config.joinMaxFailuresPerIp, skipSuccessfulRequests: true,
    standardHeaders: false, legacyHeaders: false, message: joinMessage,
  });
  r.post('/convoys/join', joinLimiterIp, joinLimiterUser, wrap(async (req, res) => {
    await ensureProfileComplete(req);
    res.json(await convoys.joinByCode(req.user, req.body?.code, req.body?.rider || {}));
  }));
  r.get('/convoys/active', wrap(async (req, res) => {
    const meta = await repo.findActiveMembership(req.user.userId);
    if (!meta) return res.json({ convoy: null });
    res.json({ convoy: await convoys.getSnapshot(meta.groupId) });
  }));
  r.get('/convoys/:groupId', wrap(async (req, res) => {
    const { groupId } = req.params;
    const member = await convoys.isMember(groupId, req.user.userId);
    if (!member && req.user.role !== 'MASTER_ADMIN') {
      return res.status(403).json({ error: 'Not a member of this convoy.' });
    }
    // Medical info goes to the ride group only, never to admins.
    res.json(await convoys.getSnapshot(groupId, { admin: !member }));
  }));
  // Emergency SMS roster (3.14): phone numbers for the rider's own SMS fallback while a ride is live.
  // Current riders of the convoy only, rate limited, never cached by anything in between.
  const rosterLimiter = rateLimit({
    windowMs: 60 * 1000, limit: config.rosterPerMin, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => `roster:${req.user.userId}`, message: { error: 'Too many requests. Try again in a minute.', code: 'RATE_LIMITED' },
  });
  r.get('/convoys/:groupId/emergency-roster', (req, res, next) => { res.set('Cache-Control', 'no-store'); next(); }, rosterLimiter, wrap(async (req, res) => {
    res.json(await convoys.emergencyRoster(String(req.params.groupId || ''), req.user.userId));
  }));
  // Live emergency link (3.16): the alert owner or the lead shares https://<origin>/e/<token> for 30 minutes.
  const liveLinkLimiter = rateLimit({
    windowMs: 60 * 1000, limit: 6, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => `live:${req.user.userId}`, message: { error: 'Too many requests. Try again in a minute.', code: 'RATE_LIMITED' },
  });
  r.post('/convoys/:groupId/alerts/:alertId/live-link', (req, res, next) => { res.set('Cache-Control', 'no-store'); next(); }, liveLinkLimiter, wrap(async (req, res) => {
    try {
      const out = await convoys.createLiveLink(String(req.params.groupId || ''), req.user, String(req.params.alertId || ''));
      res.json({ token: out.token, url: `${originOf(req)}/e/${out.token}`, expiresAt: out.expiresAt });
    } catch (e) {
      if (e instanceof ConvoyError && e.reason === 'LINK_ACTIVE') return res.status(409).json({ error: e.message, code: 'LINK_ACTIVE', expiresAt: e.expiresAt || 0 });
      throw e;
    }
  }));
  r.delete('/convoys/:groupId/alerts/:alertId/live-link', (req, res, next) => { res.set('Cache-Control', 'no-store'); next(); }, liveLinkLimiter, wrap(async (req, res) => {
    await convoys.revokeLiveLink(String(req.params.groupId || ''), req.user, String(req.params.alertId || ''));
    res.json({ ok: true });
  }));
  r.post('/convoys/:groupId/leave', wrap(async (req, res) => { await convoys.leave(req.params.groupId, req.user.userId); res.json({ ok: true }); }));
  r.post('/convoys/:groupId/status', wrap(async (req, res) => {
    const room = await convoys.getRoom(req.params.groupId);
    const rider = room.riders.get(req.user.userId);
    if (!rider || (rider.role !== 'LEAD' && room.meta.createdByUserId !== req.user.userId && req.user.role !== 'MASTER_ADMIN')) {
      return res.status(403).json({ error: 'Only the convoy lead can change the trip state.' });
    }
    res.json({ tripStatus: await convoys.setTripStatus(req.params.groupId, String(req.body?.status || '')) });
  }));

  // Trips (summary records are kept forever; GPS trails are trimmed by retention)
  // ?summary=1: the list without GPS trails (each trail is fetched on demand with GET /trips/:tripId).
  // Older app builds call without the flag and still get the trails.
  r.get('/trips', wrap(async (req, res) => {
    const trips = await repo.listTripsForUser(req.user.userId);
    if (String(req.query.summary || '') !== '1') return res.json({ trips });
    res.json({
      trips: trips.map(({ breadcrumbTrail, ...rest }) => ({ ...rest, trailPoints: Array.isArray(breadcrumbTrail) ? breadcrumbTrail.length : 0 })),
    });
  }));
  r.get('/trips/:tripId', wrap(async (req, res) => {
    const trip = await repo.getTrip(String(req.params.tripId));
    if (!trip || trip.userId !== req.user.userId) return res.status(404).json({ error: 'Trip not found.' });
    res.json({ trip: { ...trip, trailPoints: Array.isArray(trip.breadcrumbTrail) ? trip.breadcrumbTrail.length : 0 } });
  }));
  r.post('/trips', wrap(async (req, res) => {
    const size = Number(req.get('content-length')) || 0;
    if (size > config.tripMaxBytes) return res.status(413).json({ error: 'This trip is too large to save.', code: 'TRIP_TOO_LARGE' });
    // Known fields only, with types and sizes enforced (no free-form JSON is stored).
    const t = tripRecord(req.body);
    // Trips built by the server from the real tracks are authoritative; a phone's estimate never replaces them.
    const existing = await repo.getTrip(t.tripId);
    if (existing && (existing.source === 'server' || existing.userId !== req.user.userId)) return res.status(200).json({ ok: true, kept: 'server' });
    if (!existing) {
      let count = 0;
      try { count = await repo.countTripsForUser(req.user.userId, config.maxTripsPerUser); } catch { count = 0; }
      if (count >= config.maxTripsPerUser) {
        return res.status(409).json({ error: `You can keep up to ${config.maxTripsPerUser} trips. Delete old trips to save new ones.`, code: 'TOO_MANY_TRIPS' });
      }
    }
    const trip = { ...t, source: 'device', userId: req.user.userId, savedAt: Date.now() };
    await repo.saveTrip(trip);
    res.status(201).json({ ok: true });
  }));
  // ---- group timeline, tracks and report (members only, limited to the viewer's membership window) ----
  const viewWindow = async (req, res) => {
    const meta = await repo.getConvoyMeta(String(req.params.groupId));
    const win = visibleWindow(meta, req.user);
    if (!win) { res.status(403).json({ error: 'Not a member of this convoy.' }); return null; }
    return { meta, win };
  };
  const intQ = (v, def) => { const n = Number(v); return Number.isFinite(n) ? n : def; };
  /** The planned trip for the maps: start, planned stops with who reached them, destination. */
  const publicPlan = (meta) => {
    if (!meta) return null;
    const place = (lat, lng, name) => (Number.isFinite(lat) && Number.isFinite(lng) && (lat || lng) ? { lat, lng, name: name || '' } : null);
    return {
      start: meta.start ? place(meta.start.lat, meta.start.lng, meta.start.name || meta.startLocationName) : null,
      destination: place(meta.destinationLat, meta.destinationLng, meta.destinationName),
      destinationArrivals: meta.destinationArrivals || {},
      stops: (meta.stopPoints || [])
        .filter((s) => s.status !== 'SUGGESTED' && Number.isFinite(s.lat) && Number.isFinite(s.lng))
        .map((s) => ({ stopId: s.stopId, name: s.name, lat: s.lat, lng: s.lng, category: s.category || 'OTHER', status: s.status || 'PLANNED', isVisited: !!s.isVisited, orderIndex: s.orderIndex || 0, arrivals: s.arrivals || {} })),
    };
  };

  r.get('/convoys/:groupId/timeline', wrap(async (req, res) => {
    const v = await viewWindow(req, res); if (!v) return;
    const since = Math.max(0, intQ(req.query.since, 0));
    const types = String(req.query.types || '').split(',').map((x) => x.trim().toUpperCase()).filter(Boolean);
    const onlyUser = req.query.userId ? String(req.query.userId) : null;
    let events = (await repo.listEvents(v.meta.groupId, { since, userId: onlyUser || undefined, limit: 20000 }))
      .filter((e) => eventVisible(e, v.win, req.user.userId));
    if (types.length) events = events.filter((e) => types.includes(e.type));
    res.json({ groupId: v.meta.groupId, events: events.map(publicEvent), serverTime: Date.now() });
  }));

  r.get('/convoys/:groupId/tracks', wrap(async (req, res) => {
    const v = await viewWindow(req, res); if (!v) return;
    const reqFrom = Math.max(0, intQ(req.query.from, 0));
    const reqTo = intQ(req.query.to, Number.MAX_SAFE_INTEGER);
    const simplifyM = Math.min(100, Math.max(0, intQ(req.query.simplify, 0)));
    const onlyUser = req.query.userId ? String(req.query.userId) : undefined;
    const byUser = await tracks.load(v.meta.groupId, { userId: onlyUser, from: reqFrom, to: reqTo });
    const out = [];
    for (const [uid, pts] of byUser) {
      const own = uid === req.user.userId;
      const clipped = own ? pts : pts.filter((p) => p.ts >= v.win.from && p.ts <= v.win.to);
      if (!clipped.length) continue;
      out.push({ userId: uid, name: v.meta.members?.[uid]?.name || '', points: toWire(filterPoints(clipped), simplifyM) });
    }
    res.json({ groupId: v.meta.groupId, tracks: out, format: ['ts', 'lat', 'lng', 'kmh'], plan: publicPlan(v.meta) });
  }));

  // Batch upload of recorded points (the app's normal path; also works after the trip ended, within the grace period).
  const trackLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => req.user?.userId || req.ip });
  r.post('/convoys/:groupId/tracks', trackLimiter, wrap(async (req, res) => {
    const gid = String(req.params.groupId);
    const room = convoys.rooms.get(gid);
    const meta = room ? room.meta : await repo.getConvoyMeta(gid);
    const perm = uploadPermission(meta, req.user.userId);
    if (!perm.ok) return res.status(perm.tooLate ? 410 : 403).json({ error: perm.tooLate ? 'This trip is closed for uploads.' : 'Not a member of this convoy.' });
    const chunks = Array.isArray(req.body?.chunks) ? req.body.chunks : [];
    if (chunks.length === 0 || chunks.length > 20) return res.status(400).json({ error: 'Send 1 to 20 chunks.' });
    const acked = [], rejected = [];
    let added = false;
    for (const c of chunks) {
      try {
        const chunk = validateChunk(c, { tripStartMs: perm.tripStartMs });
        const r2 = await tracks.save(gid, req.user.userId, chunk);
        acked.push(r2.seq);
        if (!r2.duplicate) added = true;
      } catch (e) {
        if (!(e instanceof TrackError)) throw e;
        rejected.push({ seq: c?.seq ?? null, error: e.message });
      }
    }
    if (perm.ended && added && timeline) timeline.scheduleRebuild(gid);
    res.json({ acked, rejected });
  }));

  // Everything the trip report screen needs for one convoy, for any viewer allowed to see it (members within their window, admins).
  r.get('/convoys/:groupId/summary', wrap(async (req, res) => {
    const v = await viewWindow(req, res); if (!v) return;
    const events = (await repo.listEvents(v.meta.groupId, { limit: 20000 })).filter((e) => eventVisible(e, v.win, req.user.userId)).map(publicEvent);
    res.json({
      groupId: v.meta.groupId, name: v.meta.name, tripStatus: v.meta.tripStatus,
      startedAt: v.meta.createdAtEpochMs || 0, endedAt: v.meta.endedAtEpochMs || 0,
      startName: v.meta.start?.name || v.meta.startLocationName || '', destinationName: v.meta.destinationName || '',
      report: v.meta.report || null, events, plan: publicPlan(v.meta),
      members: Object.values(v.meta.members || {}).map((m) => ({ userId: m.userId, name: m.name, role: m.role })),
    });
  }));
  r.get('/convoys/:groupId/report', wrap(async (req, res) => {
    const v = await viewWindow(req, res); if (!v) return;
    res.json({ groupId: v.meta.groupId, tripStatus: v.meta.tripStatus, report: v.meta.report || null });
  }));

  r.get('/convoys/:groupId/gpx', wrap(async (req, res) => {
    const v = await viewWindow(req, res); if (!v) return;
    const uid = String(req.query.userId || req.user.userId);
    const byUser = await tracks.load(v.meta.groupId, { userId: uid });
    let pts = filterPoints(byUser.get(uid) || []);
    if (uid !== req.user.userId) pts = pts.filter((p) => p.ts >= v.win.from && p.ts <= v.win.to);
    if (!pts.length) return res.status(404).json({ error: 'No recorded track for this rider.' });
    const name = `${v.meta.name || 'CoRoute trip'} - ${v.meta.members?.[uid]?.name || 'rider'}`;
    const safe = name.replace(/[^A-Za-z0-9 _-]/g, '').trim().replace(/\s+/g, '_').slice(0, 60) || 'coroute_trip';
    res.type('application/gpx+xml').set('Content-Disposition', `attachment; filename="${safe}.gpx"`).send(toGpx({ name, tracks: [{ name, points: pts }] }));
  }));

  r.get('/trips/:tripId/report', wrap(async (req, res) => {
    const trip = await repo.getTrip(String(req.params.tripId));
    if (!trip || trip.userId !== req.user.userId) return res.status(404).json({ error: 'Trip not found.' });
    if (!trip.groupId) return res.json({ trip, report: null, events: [] });
    const meta = await repo.getConvoyMeta(trip.groupId);
    const win = visibleWindow(meta, req.user);
    if (!win) return res.json({ trip, report: null, events: [] });
    const events = (await repo.listEvents(trip.groupId, { limit: 20000 })).filter((e) => eventVisible(e, win, req.user.userId)).map(publicEvent);
    res.json({ trip, report: meta.report || null, events, plan: publicPlan(meta), members: Object.values(meta.members || {}).map((m) => ({ userId: m.userId, name: m.name, role: m.role })) });
  }));

  // ---- places and routes (free OSM services through the gateway cache) ----
  const geoLimiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => req.user?.userId || req.ip, message: { error: 'Too many place lookups. Wait a moment.' } });
  r.get('/geo/search', geoLimiter, wrap(async (req, res) => {
    const lat = Number(req.query.lat), lng = Number(req.query.lng);
    res.json({ results: await geo.search(req.query.q, { lat, lng }) });
  }));
  r.get('/geo/reverse', geoLimiter, wrap(async (req, res) => {
    const lat = Number(req.query.lat), lng = Number(req.query.lng);
    if (!(Math.abs(lat) <= 90 && Math.abs(lng) <= 180)) return res.status(400).json({ error: 'Invalid coordinates.' });
    res.json({ name: await geo.reverse(lat, lng) });
  }));
  r.post('/geo/essentials', geoLimiter, wrap(async (req, res) => {
    try {
      const { groupId, ...query } = req.body || {};
      if (groupId !== undefined) {
        if (typeof groupId !== 'string' || !await convoys.isMember(groupId, req.user.userId)) return res.status(403).json({ error: 'Active membership required.' });
        const room = await convoys.getRoom(groupId);
        if (!featurePolicy(room.meta.featurePolicy).essentialsEnabled) return res.status(403).json({ error: 'Route essentials are disabled for this group.', code: 'FEATURE_DISABLED' });
      }
      res.set('Cache-Control', 'no-store').json(await essentials.query(query));
    }
    catch (e) { res.status(e.status || 503).json({ error: 'Route essentials are unavailable.', code: e.code || 'ESSENTIALS_UNAVAILABLE' }); }
  }));
  r.post('/geo/route', geoLimiter, wrap(async (req, res) => {
    const route = await geo.route(req.body?.waypoints);
    if (!route) return res.status(502).json({ error: 'Route is not available right now.' });
    res.json(route);
  }));
  // Weather on the route (3.16): 1 to 5 points with their ETA, answered from a 0.1 degree grid cache (Open-Meteo).
  const weatherLimiter = rateLimit({
    windowMs: 60 * 1000, limit: config.weatherUserPerMin, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => `wx:${req.user.userId}`, message: { error: 'Too many weather checks. Wait a moment.', code: 'RATE_LIMITED' },
  });
  r.post('/geo/weather', weatherLimiter, wrap(async (req, res) => {
    if (!geo.weatherEnabled) return res.status(503).json({ error: 'Weather is not available.', code: 'WEATHER_OFF' });
    const points = weatherPoints(req.body?.points);
    const out = await geo.weather(points);
    if (!out) return res.status(503).json({ error: 'Weather is not available.', code: 'WEATHER_OFF' });
    res.set('Cache-Control', 'private, max-age=600').json(out);
  }));

  r.delete('/trips/:tripId', wrap(async (req, res) => res.json({ removed: await repo.deleteTrip(req.params.tripId, req.user.userId) })));

  // Admin
  r.get('/admin/fleet', requireAdmin, wrap(async (req, res) => res.json({ convoys: await convoys.fleet() })));
  // Every open SOS and crash alert across convoys (3.14). No medical info, no phone numbers.
  r.get('/admin/emergencies', requireAdmin, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store').json({ serverTime: Date.now(), emergencies: await convoys.emergencies() });
  }));
  // 3.16: an admin calls the rider's emergency contact from the emergencies panel. The number is answered
  // once for the call and never stored in the audit (actor, rider, alert and time only).
  const adminContactLimiter = rateLimit({
    windowMs: 60 * 1000, limit: 10, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => `contact:${req.user.userId}`, message: { error: 'Too many requests. Try again in a minute.', code: 'RATE_LIMITED' },
  });
  r.post('/admin/emergencies/:groupId/:alertId/contact', requireAdmin, adminContactLimiter, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const gid = String(req.params.groupId || ''), alertId = String(req.params.alertId || '');
    const room = gid.length <= 64 ? await convoys.getRoom(gid, { required: false }).catch(() => null) : null;
    const a = room && alertId.length <= 80 ? room.alerts.get(alertId) : null;
    if (!a || a.resolved) return res.status(404).json({ error: 'That alert is no longer open.', code: 'ALERT_CLOSED' });
    const u = await repo.findUserById(a.userId).catch(() => null);
    const name = String(u?.emergencyContactName || '').trim(), phone = String(u?.emergencyContact || '').trim();
    if (!name && !phone) return res.status(404).json({ error: 'No emergency contact on file.', code: 'NO_CONTACT' });
    if (audit) audit.add({ kind: 'ADMIN_CONTACT', actorId: req.user.userId, subjectId: a.userId, alertId: a.alertId, groupId: gid, detail: 'CALL' });
    res.json({ name, phone, riderName: a.userName || room.riders.get(a.userId)?.name || '' });
  }));
  // Rider safety network (3.15): open incidents, users with false alarms, the latest audit rows.
  r.get('/admin/safety', requireAdmin, wrap(async (req, res) => {
    const t = Date.now();
    const users = await repo.listFalseAlarmUsers().catch(() => []);
    const falseAlarmUsers = users.map((u) => {
      const count30d = falseAlarmCount(u, t);
      return { userId: u.userId, name: u.name || '', count30d, throttled: count30d >= config.abuseFalseAlarms, lastAt: Math.max(0, ...u.falseAlarmAt.filter(Number.isFinite)) };
    }).filter((x) => x.count30d > 0).sort((a, b) => (b.count30d - a.count30d) || (b.lastAt - a.lastAt)).slice(0, 50);
    if (audit) await audit.flush().catch(() => {});
    res.set('Cache-Control', 'no-store').json({
      serverTime: t,
      incidents: network ? network.adminView() : [],
      falseAlarmUsers,
      audit: await repo.listAudit({ limit: 100 }).catch(() => []),
    });
  }));
  r.post('/admin/users/:userId/false-alarms/reset', requireAdmin, wrap(async (req, res) => {
    const userId = String(req.params.userId || '');
    if (!(await repo.resetFalseAlarms(userId))) return res.status(404).json({ error: 'User not found.' });
    if (audit) audit.add({ kind: 'RESET', actorId: req.user.userId, subjectId: userId, detail: 'FALSE_ALARMS' });
    res.json({ ok: true });
  }));
  r.post('/admin/broadcast', requireAdmin, wrap(async (req, res) => res.json(await convoys.adminBroadcast(req.user, req.body?.message))));
  r.get('/admin/feature-analytics', requireAdmin, (req, res) => res.set('Cache-Control', 'no-store').json(convoys.featureAnalytics.snapshot()));
  r.get('/admin/analytics', requireAdmin, wrap(async (req, res) => {
    const days = Math.min(Math.max(parseInt(req.query.days, 10) || 30, 1), 365);
    const since = new Date(Date.now() - days * 86400000).toISOString().slice(0, 10);
    res.json({ since, pageviews: await repo.listPageviews(since) });
  }));
  r.get('/admin/app-builds', requireAdmin, wrap(async (req, res) => {
    const days = Math.min(Math.max(parseInt(req.query.days, 10) || 30, 1), 365);
    res.json(await auth.appBuilds({ days, minBuild: config.minAppBuild, latestBuild: config.latestAppBuild }));
  }));
  // Finished rides across all riders, with each report's headline numbers and retention status.
  const convoySummary = (m) => {
    const startedAt = m.createdAtEpochMs || 0;
    const endedAt = m.endedAtEpochMs || 0;
    const retentionDays = config.retentionEndedConvoyDays || 90;
    const retentionMs = retentionDays * 86400000;
    const expiresAt = endedAt ? endedAt + retentionMs : null;
    const daysRemaining = expiresAt ? Math.max(0, Math.ceil((expiresAt - Date.now()) / 86400000)) : null;
    const isApproachingRetention = daysRemaining !== null && daysRemaining <= 14;
    return {
      groupId: m.groupId, name: m.name, createdByUserName: m.createdByUserName || '',
      startedAt, endedAt,
      startName: m.start?.name || m.startLocationName || '', destinationName: m.destinationName || '',
      members: Object.keys(m.members || {}).length,
      hasReport: !!m.report,
      distanceM: m.report?.group?.distanceM || 0,
      durationMs: m.report?.group?.durationMs || Math.max(0, endedAt - startedAt),
      arrived: m.report?.group?.arrived || 0,
      sos: m.report?.group?.sos || 0,
      plannedStops: m.report?.group?.plannedStops || 0,
      visitedStops: m.report?.group?.visitedStops || 0,
      tripStatus: m.tripStatus || 'ENDED',
      gpsStripped: !!m.gpsStripped,
      retentionDaysRemaining: daysRemaining,
      isApproachingRetention,
    };
  };

  r.get('/admin/groups', requireAdmin, wrap(async (req, res) => {
    const active = await convoys.fleet();
    const ended = (await repo.listEndedConvoyMeta(500)).map(convoySummary);
    const approachingRetention = ended.filter((c) => c.isApproachingRetention || c.gpsStripped);
    res.json({
      active,
      completed: ended,
      approachingRetention,
      retentionPolicyDays: config.retentionEndedConvoyDays || 90,
    });
  }));

  r.get('/admin/convoys/history', requireAdmin, wrap(async (req, res) => {
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 100, 1), 500);
    res.json({ convoys: (await repo.listEndedConvoyMeta(limit)).map(convoySummary) });
  }));
  r.get('/admin/stats', requireAdmin, wrap(async (req, res) => {
    const days = Math.min(Math.max(parseInt(req.query.days, 10) || 30, 1), 3650);
    const since = Date.now() - days * 86400000;
    const ended = (await repo.listEndedConvoyMeta(5000)).map(convoySummary);
    const recent = ended.filter((c) => c.endedAt >= since);
    const users = await repo.listUsers(5000);
    const sum = (list, k) => list.reduce((s, c) => s + (c[k] || 0), 0);
    res.json({
      days,
      riders: users.length,
      activeRiders: users.filter((u) => (u.lastActiveAt || 0) >= since).length,
      newRiders: users.filter((u) => (u.createdAt || 0) >= since).length,
      liveConvoys: convoys.rooms.size,
      rides: { all: ended.length, recent: recent.length },
      distanceM: { all: sum(ended, 'distanceM'), recent: sum(recent, 'distanceM') },
      rideMs: { all: sum(ended, 'durationMs'), recent: sum(recent, 'durationMs') },
      riderTrips: await repo.countTrips(),
      avgGroupSize: ended.length ? +(sum(ended, 'members') / ended.length).toFixed(1) : 0,
      sos: { all: sum(ended, 'sos'), recent: sum(recent, 'sos') },
    });
  }));
  r.get('/admin/feedback', requireAdmin, wrap(async (req, res) => res.json({ feedback: await repo.listFeedback() })));

  r.get('/admin/users', requireAdmin, wrap(async (req, res) => {
    const users = await auth.listUsers(5000);
    const activeMap = new Map();
    for (const [gid, room] of convoys.rooms) {
      for (const uid of room.riders.keys()) {
        activeMap.set(uid, { groupId: gid, name: room.meta?.name || 'Active Ride', role: room.riders.get(uid)?.role || 'PACK' });
      }
    }
    const activeMetas = await repo.listActiveConvoyMeta().catch(() => []);
    for (const m of activeMetas) {
      for (const uid of Object.keys(m.members || {})) {
        if (!m.members[uid].leftAt && !activeMap.has(uid)) {
          activeMap.set(uid, { groupId: m.groupId, name: m.name, role: m.members[uid].role || 'PACK' });
        }
      }
    }
    const enriched = users.map((u) => {
      const act = activeMap.get(u.userId) || null;
      return {
        ...u,
        activeGroup: act,
        isInActiveConvoy: !!act,
      };
    });
    res.json({ users: enriched });
  }));

  r.get('/admin/users/:userId/details', requireAdmin, wrap(async (req, res) => {
    const { userId } = req.params;
    const user = await repo.findUserById(userId);
    if (!user) return res.status(404).json({ error: 'User not found.' });

    let activeGroup = null;
    for (const [gid, room] of convoys.rooms) {
      if (room.riders.has(userId)) {
        activeGroup = { groupId: gid, name: room.meta?.name || 'Active Ride', role: room.riders.get(userId)?.role || 'PACK' };
        break;
      }
    }
    if (!activeGroup) {
      const act = await repo.findActiveMembership(userId);
      if (act) {
        activeGroup = { groupId: act.groupId, name: act.name, role: act.members?.[userId]?.role || 'PACK' };
      }
    }

    const trips = await repo.listTripsForUser(userId, 500);
    const groupIds = [...new Set(trips.map((t) => t.groupId).filter(Boolean))];
    const groupMetaMap = new Map();
    for (const gid of groupIds) {
      const meta = await repo.getConvoyMeta(gid);
      if (meta) groupMetaMap.set(gid, meta);
    }

    const groups = trips.map((t) => {
      const meta = groupMetaMap.get(t.groupId);
      const members = meta ? Object.values(meta.members || {}).map((m) => ({
        userId: m.userId,
        name: m.name,
        role: m.role || 'PACK',
        vehicleType: m.vehicleType || '',
        vehicleNo: m.vehicleNo || '',
      })) : [];
      return {
        tripId: t.tripId,
        groupId: t.groupId || '',
        name: t.tripName,
        tripStatus: meta?.tripStatus || 'ENDED',
        startedAt: t.startTimeEpochMs,
        endedAt: t.endTimeEpochMs,
        startName: t.startLocationName || meta?.start?.name || meta?.startLocationName || '',
        destinationName: t.destinationName || meta?.destinationName || '',
        totalDistanceKm: t.totalDistanceKm || 0,
        movingMs: t.movingMs || 0,
        restMs: t.restMs || 0,
        userRole: meta?.members?.[userId]?.role || 'PACK',
        members,
      };
    });

    res.json({
      user: {
        userId: user.userId, name: user.name, email: user.email, role: user.role, status: user.status || 'ACTIVE',
        statusReason: user.statusReason || '', statusChangedAt: user.statusChangedAt || 0,
        phone: user.phone || '', vehicleType: user.vehicleType || 'Motorcycle', vehicleNo: user.vehicleNo || '',
        emergencyContact: user.emergencyContact || '', emergencyContactName: user.emergencyContactName || '',
        provider: user.provider || 'password', createdAt: user.createdAt || 0, lastActiveAt: user.lastActiveAt || 0,
      },
      activeGroup,
      isInActiveConvoy: !!activeGroup,
      groups,
    });
  }));

  r.patch('/admin/users/:userId/status', requireAdmin, wrap(async (req, res) => {
    const { userId } = req.params;
    const status = String(req.body?.status || '').toUpperCase();
    const reason = String(req.body?.reason || '').trim();
    if (!['ACTIVE', 'ON_HOLD', 'BLOCKED'].includes(status)) {
      return res.status(400).json({ error: 'Status must be ACTIVE, ON_HOLD, or BLOCKED.' });
    }

    if (status !== 'ACTIVE') {
      let inActive = false;
      let activeName = '';
      for (const [gid, room] of convoys.rooms) {
        if (room.riders.has(userId)) {
          inActive = true;
          activeName = room.meta?.name || gid;
          break;
        }
      }
      if (!inActive) {
        const act = await repo.findActiveMembership(userId);
        if (act) {
          inActive = true;
          activeName = act.name || act.groupId;
        }
      }
      if (inActive) {
        return res.status(400).json({
          error: `User is currently participating in active convoy "${activeName}". Cannot hold or block an active rider.`,
          code: 'USER_IN_ACTIVE_CONVOY',
        });
      }
    }

    const updated = await auth.setUserStatus(req.user, userId, status, reason);
    if (status !== 'ACTIVE' && hub) hub.disconnectUser(userId, 4403, status === 'BLOCKED' ? 'ACCOUNT_BLOCKED' : 'ACCOUNT_ON_HOLD');
    res.json({ user: updated });
  }));

  r.delete('/admin/users/:userId', requireAdmin, wrap(async (req, res) => {
    const { userId } = req.params;
    const target = await repo.findUserById(userId);
    if (!target) return res.status(404).json({ error: 'User not found.' });
    if (target.role === 'MASTER_ADMIN') {
      return res.status(403).json({ error: 'Cannot delete the master administrator account.' });
    }
    // Same steps as DELETE /me: no report write may follow the erase.
    await repo.deleteUserCascade(target, await prepareErase(target));
    if (gate) gate.invalidate(userId);
    if (hub) hub.disconnectUser(userId, 4401, 'ACCOUNT_GONE');
    res.json({ ok: true, userId });
  }));

  r.patch('/admin/users/:userId/role', requireAdmin, wrap(async (req, res) => res.json(await auth.setRole(req.user, req.params.userId, String(req.body?.role || '')))));
  r.post('/admin/users/:userId/reset-password', requireAdmin, wrap(async (req, res) => res.json(await auth.adminResetPassword(req.user, req.params.userId))));
  r.delete('/admin/convoys/:groupId', requireAdmin, wrap(async (req, res) => { await convoys.adminDissolve(req.params.groupId); res.json({ ok: true, groupId: req.params.groupId }); }));

  // Errors
  // eslint-disable-next-line no-unused-vars
  r.use((err, req, res, next) => {
    if (err instanceof AuthError) return res.status(err.status).json({ error: err.message, ...(err.code ? { code: err.code } : {}) });
    if (err instanceof ValidationError) return res.status(err.status).json({ error: err.message, code: err.code, fields: err.fields });
    if (err instanceof ConvoyError) return res.status(err.status).json({ error: err.message, ...(err.reason ? { code: err.reason } : {}) });
    if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Malformed JSON' });
    console.error('[api]', err);
    res.status(500).json({ error: 'Internal error' });
  });

  return r;
}

module.exports = { buildRouter };
