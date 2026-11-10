'use strict';
const express = require('express');
const rateLimit = require('express-rate-limit');
const { requireAuth, requireAdmin, AuthError, verifyToken } = require('./auth');
const { ValidationError, tripRecord, sitePath, weatherPoints, liveTokenOf } = require('./validate');
const { identity } = require('./anonymise');
const { ConvoyError, falseAlarmCount, sha256 } = require('./convoys');
const config = require('./config');
const { featurePolicy } = require('./feature_policy');
const { visibleWindow, eventVisible, publicEvent } = require('./timeline');
const { toWire, toGpx, filterPoints, validateChunk, uploadPermission, TrackError } = require('./tracks');
const { registerSubscriptionPublicRoutes, registerSubscriptionAuthRoutes } = require('./subscription_routes');
const { registerMembershipPublicRoutes, registerMembershipAuthRoutes } = require('./membership_routes');
const { registerAdminAnalyticsRoutes, registerPublicUsageRoutes, maxTripsFor } = require('./admin_analytics');
const { assignPlan } = require('./admin_plans');
const { isStaffAccount, isGuestAccount, staffEmails, hasStaffMember } = require('./staff');

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

/**
 * @param {{auth: import('./auth').AuthService, convoys: import('./convoys').ConvoyManager, repo: any, soda: any, hub: any, startedAt:number}} deps
 */
function buildRouter({ auth, convoys, repo, soda, hub, startedAt, tracks, timeline, geo, essentials, poiCells = null, gate, network = null, audit = null, publicLiveLimiter = null, emergencyGateway = null, lease = null, nodeName = null, publicStats = null, diagLogs = null }) {
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
  const diagSubmitLimiter = rateLimit({
    windowMs: 24 * 60 * 60 * 1000,
    limit: 5,
    skipFailedRequests: true,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    keyGenerator: (req) => req.user?.userId || req.ip,
    message: { error: 'Rate limit exceeded: max 5 diagnostic submissions per day.' },
  });

  const PROHIBITED_DIAGNOSTIC_KEYS = [
    'imei',
    'serial',
    'serialnumber',
    'contacts',
    'contactlist',
    'messages',
    'smslist',
    'audio',
    'audiorecording',
    'recordedvoice',
    'password',
    'token',
    'refreshtoken',
    'accesstoken',
    'continuousgps',
    'gpstraces',
    'rawcoordinates',
    'exactpath',
  ];

  function containsProhibitedDiagnosticKeys(obj) {
    if (!obj || typeof obj !== 'object') return false;
    for (const [k, v] of Object.entries(obj)) {
      const cleanKey = k.toLowerCase().replace(/[^a-z0-9]/g, '');
      for (const p of PROHIBITED_DIAGNOSTIC_KEYS) {
        if (cleanKey.includes(p)) return true;
      }
      if (v && typeof v === 'object') {
        if (containsProhibitedDiagnosticKeys(v)) return true;
      }
    }
    return false;
  }

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
      // Two-VM deployment: which node answered, its GATEWAY_ROLE, and the scheduled jobs it holds.
      role: config.gatewayRole,
      node: nodeName || null,
      leases: lease ? Object.entries(lease.status()).filter(([, v]) => v.holding).map(([k]) => k) : [],
    });
  }));

  // App metadata: version gate + links. Public, cacheable.
  r.get('/meta', (req, res) => {
    const origin = config.publicOrigin || `${req.protocol}://${req.get('host')}`;
    const pkgVersion = require('../package.json').version;
    res.set('Cache-Control', 'no-cache').json({
      minBuild: config.minAppBuild,
      latestBuild: config.latestAppBuild,
      version: pkgVersion,
      downloadUrl: `${origin}/download`,
      privacyUrl: `${origin}/privacy`,
      termsUrl: `${origin}/terms`,
      supportEmail: config.supportEmail,
      googleSignIn: config.googleClientIds.length > 0,
      guardianPersonal: process.env.GUARDIAN_ENABLED === 'true',
      paymentsEnabled: config.paymentsEnabled,
    });
  });

  r.post('/auth/register', authLimiter, wrap(async (req, res) => res.status(201).json(await auth.register(req.body || {}))));
  // Wrong passwords are also limited per account (an attacker rotating IPs), correct logins do not count.
  const loginIdLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, limit: 10, skipSuccessfulRequests: true, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => `login:${String(req.body?.identifier || '').trim().toLowerCase().slice(0, 120)}`,
    message: { error: 'Too many attempts, try again later.' },
  });
  r.post('/auth/login', authLimiter, loginIdLimiter, wrap(async (req, res) => res.json(await auth.login(req.body || {}))));
  r.post('/auth/google', authLimiter, wrap(async (req, res) => res.json(await auth.loginWithGoogle(req.body || {}))));
  // Guest mode was retired in 3.55 (410 GUEST_RETIRED); kept so old builds get a clear message.
  r.post('/auth/guest', authLimiter, wrap(async (req, res) => res.json(await auth.loginAsGuest(req.body || {}))));

  // ---- website endpoints (public, rate-limited, no cookies, no personal data stored for analytics) ----
  const siteLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false });
  // /community-stories and /public/community-stories (approved rider reviews only) are in membership_routes.js.
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
    repo.countPageview(day, path, refHost, config.pvMaxReferrers).catch(() => { });
    res.status(204).end();
  }));

  // Topics the website feedback form offers (index.html #fb-topic). 'safety-idea' feeds future safety features.
  // Website topics, plus the app's "Suggest a safety feature" chips (group-riding, map-navigation).
  const FEEDBACK_TOPICS = ['general', 'safety-idea', 'bug', 'story', 'other', 'group-riding', 'map-navigation'];
  r.post('/feedback', feedbackLimiter, wrap(async (req, res) => {
    const b = req.body || {};
    // Honeypot: real users never fill the hidden "website" field. Timing: humans take > 3 s.
    if (b.website) return res.status(204).end();
    const started = Number(b.t);
    if (!Number.isFinite(started) || Date.now() - started < 3000) return res.status(400).json({ error: 'Please take a moment and try again.' });
    const name = String(b.name || '').trim().slice(0, 80);
    const email = String(b.email || '').trim().toLowerCase();
    const message = String(b.message || '').trim();
    // Topic (website form): empty means general; anything not on the list is refused, never stored.
    const topic = String(b.topic || '').trim().toLowerCase() || 'general';
    const errors = {};
    if (!FEEDBACK_TOPICS.includes(topic)) errors.topic = 'Choose a topic from the list.';
    // A signed-in app rider may send an idea without an e-mail ("Contact me" off): the app's token
    // stands in for it. Nothing about the account is stored with it (private by default).
    const auth = req.headers.authorization || '';
    const appRider = !email && auth.startsWith('Bearer ') && !!verifyToken(auth.slice(7));
    if (!appRider && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) errors.email = 'Enter a valid e-mail address.';
    if (message.length < 20) errors.message = 'Please write at least 20 characters.';
    if (message.length > 2000) errors.message = 'Please keep it under 2000 characters.';
    if (/https?:\/\/\S+/gi.test(message) && (message.match(/https?:\/\//gi) || []).length > 2) errors.message = 'Too many links.';
    if (Object.keys(errors).length) return res.status(422).json({ error: 'Please correct the highlighted fields.', fields: errors });
    await repo.addFeedback({
      name: email ? name : '', email, message, topic, contact: !!email, createdAt: Date.now(),
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
  r.get('/public/live/:token', liveLimiter, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store').set('X-Robots-Tag', 'noindex').set('Referrer-Policy', 'no-referrer');
    const token = liveTokenOf(req.params.token);
    if (!token) return res.status(404).json({ error: 'Not found' });
    const hash = sha256(token);
    // The page /e/<token> also shows links made by the emergency SMS gateway: its 30 s refresh
    // must find them here too (it used to get 410 and told the guardian the link had expired).
    let view = await convoys.liveViewLoaded(hash);
    if (!view && emergencyGateway && typeof emergencyGateway.liveView === 'function') {
      const g = emergencyGateway.liveView(hash);
      // Public: position and times only, never medical details.
      if (g) view = { firstName: g.firstName, lat: g.lat, lng: g.lng, at: g.at, active: true, expiresAt: g.expiresAt };
    }
    if (!view) return res.status(410).json({ error: 'This link has expired.' });
    const t = Date.now();
    if (audit && t - (viewAudited.get(hash) || 0) >= 5 * 60000) {
      viewAudited.set(hash, t);
      const ref = convoys.liveLinks.get(hash);
      audit.add({ kind: 'LIVE_LINK', alertId: ref?.alertId, groupId: ref?.gid, detail: 'VIEW' });
      if (viewAudited.size > 2000) for (const [k, at] of viewAudited) if (t - at >= 5 * 60000) viewAudited.delete(k);
    }
    res.json(view);
  }));

  // 3.55 admin feature switches: the website's community numbers are hidden while switched off.
  const flagsOf = () => convoys.featureFlags || null;
  require('./feature_flags').registerFeatureFlagPublicGuards({ r, flagsOf });
  // Razorpay webhook endpoint (public, HMAC-signature authenticated)
  registerSubscriptionPublicRoutes({ r, auth, repo, hub, wrap, convoys });
  registerMembershipPublicRoutes({ r, repo, wrap, convoys, hub }); // hub: SUBSCRIPTION_ACTIVATED after a web payment
  // 3.56 marketing board on the website (public posts; website only, never pushed to the app).
  require('./board').registerBoardPublicRoutes({ r, repo, wrap });
  // Aggregated, PII-free usage numbers for the website (cached 5 min).
  registerPublicUsageRoutes({ r, repo, wrap, store: publicStats });
  // Rounded count of riders on a ride right now for the website (cached 30 s, no PII).
  require('./public_live').registerPublicLiveRoutes({ r, convoys, wrap });

  // ---- authenticated ----
  r.use(requireAuth(gate), apiLimiter);
  // Sliding session on EVERY authenticated call (not only /me): a phone that stays on one long
  // multi-day ride (sockets, telemetry, SOS) without reopening the app is never signed out by
  // token age mid-ride. Signed from the database document (current role and password version).
  r.use((req, res, next) => {
    if (req.dbUser && req.tokenIssuedAt && Date.now() - req.tokenIssuedAt > config.tokenRefreshAfterHours * 3600000) {
      try { res.set('X-CoRoute-Token', auth.issueToken(req.dbUser)); } catch { /* never in the way */ }
    }
    next();
  });

  // 3.55 admin feature switches: GET /features (riders), /admin/features (console) and the 403
  // FEATURE_OFF guards in front of the REST features (registered before the routes they guard).
  require('./feature_flags').registerFeatureFlagRoutes({ r, flagsOf, repo, wrap, requireAdmin });
  // 3.55 platform: admin warnings for the rider (GET /me/warnings, POST /me/warnings/:id/ack).
  if (hub && hub.publicRides && hub.publicRides.adminWarnings) require('./admin_warnings').registerAdminWarningRoutes({ r, warnings: hub.publicRides.adminWarnings, wrap });
  // 3.55 usernames, profiles, friends, blocks, profile pictures (src/social_routes.js).
  require('./social_routes').registerSocialRoutes({ r, repo, auth, hub, wrap, requireAdmin, flagsOf });
  // 3.55 crews and crew polls (src/crews.js, src/crew_routes.js; switches crews / crewPolls).
  require('./crew_routes').registerCrewRoutes({ r, repo, hub, wrap, requireAdmin, flagsOf });
  // 3.55 "Start a ride with this crew": ride invites to chosen crew members (src/crew_ride_invites.js; switch crewRides).
  require('./crew_ride_invites').registerCrewRideInviteRoutes({ r, repo, hub, convoys, wrap, flagsOf, ensureProfileComplete: (req) => ensureProfileComplete(req) });
  // 3.55 push notifications: POST / DELETE /me/push-tokens (src/push.js).
  if (hub && hub.push) require('./push').registerPushRoutes({ r, push: hub.push, wrap });
  // 3.55 diagnostics logs: POST /me/diagnostics (gzip bundle), admin list / view / download / "Ask for logs" (src/diag_logs.js).
  if (diagLogs) diagLogs.register({ r, wrap, requireAdmin });
  // 3.55 marketing studio: coupon / offer image templates (admin only, switch marketingStudio).
  require('./marketing_templates').registerMarketingRoutes({ r, repo, wrap, requireAdmin, flagsOf });

  r.get('/me', wrap(async (req, res) => {
    const me = await auth.me(req.user.userId, { appBuild: parseInt(req.get('X-CoRoute-Build') || '0', 10) });
    // Sliding session: a rider who opens the app at least once a month is never signed out.
    // The new token is built from the database user, so role changes take effect too.
    if (!res.get('X-CoRoute-Token') && Date.now() - (req.tokenIssuedAt || 0) > config.tokenRefreshAfterHours * 3600000) {
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
    // Public ride: preferences, blocks, requests, chats and the contact log about this rider.
    if (hub && hub.publicRides) await hub.publicRides.forgetUser(user.userId).catch(() => {});
    const gwSms = emergencyGateway || convoys?.emergencyGateway;
    if (gwSms && typeof gwSms.revokeLinksFor === 'function') gwSms.revokeLinksFor(user.userId);
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
  // Server-Side Emergency SMS & WhatsApp Web Gateway (FEAT-08)
  // Per account: an SOS plus a few retries; a phone retrying the same dispatch within a minute gets the first result.
  const dispatchLimiter = rateLimit({
    windowMs: 10 * 60 * 1000, limit: 8, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => `sosx:${req.user.userId}`, message: { error: 'Too many emergency dispatches. Call 112 directly.', code: 'RATE_LIMITED' },
  });
  const recentDispatch = new Map(); // `${userId}|${numbers}` -> { at, out }
  const SEVERITIES = new Set(['LOW', 'MEDIUM', 'HIGH', 'CRITICAL']);
  const dispatchExternalHandler = wrap(async (req, res) => {
    const gw = emergencyGateway || convoys?.emergencyGateway;
    if (!gw) {
      return res.status(503).json({ error: 'Emergency gateway service is unavailable.', code: 'GATEWAY_UNAVAILABLE' });
    }
    const b = req.body || {};
    // Always the signed-in rider: a body riderId would read (and text) another account's emergency contact.
    const riderId = req.user.userId;
    const riderName = String(req.user?.name || b.riderName || 'CoRoute Rider').trim().slice(0, 60);
    const lat = Number(b.lat);
    const lng = Number(b.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      return res.status(400).json({ error: 'Valid lat (-90..90) and lng (-180..180) are required.', code: 'INVALID_COORDINATES' });
    }

    let contacts = Array.isArray(b.contacts) ? b.contacts.slice(0, 10) : [];
    if (contacts.length === 0 && repo && riderId) {
      const u = await repo.findUserById(riderId).catch(() => null);
      if (u?.emergencyContact) {
        contacts.push({ phone: u.emergencyContact, name: u.emergencyContactName || 'Emergency Contact' });
      }
    }

    if (contacts.length === 0) {
      return res.status(400).json({ error: 'No emergency contacts provided or found on profile.', code: 'NO_CONTACTS' });
    }

    const numbers = contacts.map((c) => String((c && (c.phone || c.number)) || '').replace(/[^0-9]/g, '').slice(-10)).filter(Boolean).sort().join(',');
    const key = `${riderId}|${numbers}`;
    const t = Date.now();
    for (const [k, v] of recentDispatch) if (t - v.at >= 60000) recentDispatch.delete(k);
    const prev = recentDispatch.get(key);
    if (prev) return res.status(200).json({ ...prev.out, duplicate: true });
    // Only a link to this server's own live page is put into the text (never a URL the client chose).
    // Either site host during the domain move (src/domains.js).
    const ownPrefix = typeof b.trackingUrl === 'string'
      ? [originOf(req), ...require('./domains').siteOriginsOf(config)].map((o) => `${o}/e/`).find((p) => b.trackingUrl.startsWith(p))
      : null;
    const trackingUrl = ownPrefix && liveTokenOf(b.trackingUrl.slice(ownPrefix.length)) ? b.trackingUrl : null;
    const severity = SEVERITIES.has(String(b.severity || '').toUpperCase()) ? String(b.severity).toUpperCase() : 'CRITICAL';
    const out = await gw.dispatchExternal({
      tripId: (typeof b.tripId === 'string' && /^[A-Za-z0-9_.:-]{1,80}$/.test(b.tripId)) ? b.tripId : `trip-${t}`,
      riderId,
      riderName,
      lat,
      lng,
      speedKmh: Math.max(0, Math.min(300, Number(b.speedKmh) || 0)),
      contacts,
      severity,
      bloodGroup: typeof b.bloodGroup === 'string' ? b.bloodGroup.slice(0, 4) : '',
      trackingUrl,
    });
    if (out && out.dispatched) recentDispatch.set(key, { at: t, out });

    res.status(200).json(out);
  });
  // The rider is safe: every standalone tracking link the gateway made for them stops working.
  r.delete('/v1/sos/live-links', wrap(async (req, res) => {
    const gw = emergencyGateway || convoys?.emergencyGateway;
    res.json({ revoked: gw && typeof gw.revokeLinksFor === 'function' ? gw.revokeLinksFor(req.user.userId) : 0 });
  }));
  r.post('/v1/sos/dispatch-external', dispatchLimiter, dispatchExternalHandler);
  r.post('/sos/dispatch-external', dispatchLimiter, dispatchExternalHandler);

  r.post('/convoys/:groupId/leave', wrap(async (req, res) => { await convoys.leave(req.params.groupId, req.user.userId); res.json({ ok: true }); }));

  // Two-Role Trip Governance: Trip Owner assigns Trip Head
  r.post('/convoys/:groupId/trip-head', wrap(async (req, res) => {
    const { targetUserId } = req.body || {};
    if (!targetUserId) throw new ConvoyError('targetUserId is required.');
    res.json(await convoys.setTripHead(req.params.groupId, req.user, String(targetUserId)));
  }));

  // Two-Role Trip Governance: Trip Owner removes a participant
  r.delete('/convoys/:groupId/riders/:targetUserId', wrap(async (req, res) => {
    res.json(await convoys.removeRider(req.params.groupId, req.user, req.params.targetUserId));
  }));
  r.post('/convoys/:groupId/status', wrap(async (req, res) => {
    const room = await convoys.getRoom(req.params.groupId);
    // Pause / resume: Trip owner or a Lead the owner picked (never an automatic front rider, see
    // ConvoyManager.isLead). End: Trip owner (and platform admins). The Trip head changes settings only.
    const isAdmin = req.user.role === 'ADMIN' || req.user.role === 'MASTER_ADMIN';
    if (!convoys.isLead(room, req.user) && !isAdmin) {
      return res.status(403).json({ error: 'Only the Trip owner or Lead can change the trip state.', reason: 'NOT_LEAD' });
    }
    const status = String(req.body?.status || '').toUpperCase();
    if (status === 'ENDED' && !convoys.canManage(room, req.user)) {
      return res.status(403).json({ error: 'Only the Trip owner can end the trip.', reason: 'ONLY_OWNER_CAN_END_TRIP' });
    }
    res.json({ tripStatus: await convoys.setTripStatus(req.params.groupId, status) });
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
      // The admin can set a per-rider cap (PATCH /admin/users/:userId/config); otherwise the server default.
      const cap = maxTripsFor(req.dbUser || await repo.findUserById(req.user.userId).catch(() => null));
      let count = 0;
      try { count = await repo.countTripsForUser(req.user.userId, Math.max(cap, 1)); } catch { count = 0; }
      if (count >= cap) {
        return res.status(409).json({ error: `You can keep up to ${cap} trips. Delete old trips to save new ones.`, code: 'TOO_MANY_TRIPS' });
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
    // Each rider's own cleaned track only; `brk` (5th element, 1) starts a new segment after a signal gap.
    res.json({ groupId: v.meta.groupId, tracks: out, format: ['ts', 'lat', 'lng', 'kmh', 'brk'], segmented: true, plan: publicPlan(v.meta) });
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
    // Valid chunks are written together (one batched insert); the answer waits until every one is stored,
    // and a failed write fails the request so the phone keeps those chunks and sends them again.
    const saves = [];
    for (const c of chunks) {
      try {
        const chunk = validateChunk(c, { tripStartMs: perm.tripStartMs });
        saves.push(tracks.save(gid, req.user.userId, chunk));
      } catch (e) {
        if (!(e instanceof TrackError)) throw e;
        rejected.push({ seq: c?.seq ?? null, error: e.message });
      }
    }
    const settled = await Promise.allSettled(saves);
    const failed = settled.find((x) => x.status === 'rejected');
    if (failed) throw failed.reason;
    for (const { value: r2 } of settled) {
      acked.push(r2.seq);
      if (!r2.duplicate) added = true;
    }
    if (perm.ended && added && timeline) timeline.scheduleRebuild(gid, req.user.userId);
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
  r.get('/geo/nearby-fuel', geoLimiter, wrap(async (req, res) => {
    const lat = Number(req.query.lat), lng = Number(req.query.lng);
    const radiusKm = Number(req.query.radiusKm) || 25;
    if (!(Math.abs(lat) <= 90 && Math.abs(lng) <= 180) || (lat === 0 && lng === 0)) {
      return res.status(400).json({ error: 'Valid latitude and longitude required.' });
    }
    res.set('Cache-Control', 'private, max-age=300').json({
      results: await geo.nearbyFuel(lat, lng, radiusKm),
    });
  }));
  // Map places by 0.05 degree cell: the phone picks the cells (route corridor ahead or around the
  // rider) and does all filtering, fuel matching and ranking; the gateway only proxies and caches.
  const poiLimiter = rateLimit({ windowMs: 60 * 1000, limit: 20, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => `poi:${req.user?.userId || req.ip}`, message: { error: 'Too many place lookups. Wait a moment.', code: 'RATE_LIMITED' } });
  r.get('/geo/poi-cells', poiLimiter, wrap(async (req, res) => {
    if (!poiCells) return res.status(503).json({ error: 'Map places are unavailable.', code: 'PLACES_NOT_CONFIGURED' });
    try {
      const out = await poiCells.cells(req.query.cells);
      res.set('Cache-Control', out.pending.length ? 'no-store' : 'private, max-age=3600').json(out);
    } catch (e) { res.status(e.status || 503).json({ error: 'Map places are unavailable.', code: e.code || 'PLACES_UNAVAILABLE' }); }
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
  // Planned routes and riders' new routes from where they are (startBearing: their direction of
  // travel). Clear errors with a code; a rider's app asks at most once per 15 s, this caps a user.
  const routeLimiter = rateLimit({
    windowMs: 60 * 1000, limit: 12, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => `rt:${req.user?.userId || req.ip}`, message: { error: 'Too many route requests. Wait a moment.', code: 'RATE_LIMITED' },
  });
  const ROUTE_ERRORS = {
    INVALID_WAYPOINTS: [400, 'Send 2 to 25 waypoints with valid coordinates (and startBearing 0 to 359 if any).'],
    ROUTE_DISABLED: [503, 'Routing is not available on this server.'],
    NO_ROUTE: [422, 'No road route between these points.'],
    UPSTREAM: [502, 'Route is not available right now.'],
  };
  r.post('/geo/route', geoLimiter, routeLimiter, wrap(async (req, res) => {
    const out = await geo.routeResult(req.body?.waypoints, { startBearing: req.body?.startBearing });
    if (!out.route) {
      const [status, error] = ROUTE_ERRORS[out.error] || ROUTE_ERRORS.UPSTREAM;
      return res.status(status).json({ error, code: out.error || 'UPSTREAM' });
    }
    res.json(out.route);
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
    if (audit) await audit.flush().catch(() => { });
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
  const staffIdsOfRepo = () => (typeof repo.staffUserIds === 'function' ? repo.staffUserIds().catch(() => new Set()) : Promise.resolve(new Set()));
  // staffIds (optional): flags a ride a staff account joined (hasStaff) and sizes the group by riders only.
  const convoySummary = (m, staffIds = null) => {
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
      riderMembers: staffIds ? Object.keys(m.members || {}).filter((id) => !staffIds.has(id)).length : Object.keys(m.members || {}).length,
      hasStaff: staffIds ? hasStaffMember(Object.keys(m.members || {}), staffIds) : false,
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
    const staffIds = await staffIdsOfRepo();
    const ended = (await repo.listEndedConvoyMeta(500)).map((m) => convoySummary(m, staffIds));
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
    const staffIds = await staffIdsOfRepo();
    res.json({ convoys: (await repo.listEndedConvoyMeta(limit)).map((m) => convoySummary(m, staffIds)) });
  }));
  r.get('/admin/stats', requireAdmin, wrap(async (req, res) => {
    const days = Math.min(Math.max(parseInt(req.query.days, 10) || 30, 1), 3650);
    const since = Date.now() - days * 86400000;
    const all = await repo.listUsers(5000);
    // Staff accounts (admins, STAFF_EMAILS) are not riders; guests are counted as before.
    const emails = staffEmails();
    const staff = all.filter((u) => !isGuestAccount(u) && isStaffAccount(u, emails));
    const staffIds = new Set(staff.map((u) => u.userId));
    const users = all.filter((u) => !staffIds.has(u.userId));
    const ended = (await repo.listEndedConvoyMeta(5000)).map((m) => convoySummary(m, staffIds));
    const recent = ended.filter((c) => c.endedAt >= since);
    const sum = (list, k) => list.reduce((s, c) => s + (c[k] || 0), 0);
    const sized = ended.filter((c) => c.riderMembers > 0);
    res.json({
      days,
      riders: users.length,
      excludesStaff: true,
      staff: staff.length,
      activeRiders: users.filter((u) => (u.lastActiveAt || 0) >= since).length,
      newRiders: users.filter((u) => (u.createdAt || 0) >= since).length,
      liveConvoys: convoys.rooms.size,
      rides: { all: ended.length, recent: recent.length },
      distanceM: { all: sum(ended, 'distanceM'), recent: sum(recent, 'distanceM') },
      rideMs: { all: sum(ended, 'durationMs'), recent: sum(recent, 'durationMs') },
      riderTrips: await repo.countTrips(),
      avgGroupSize: sized.length ? +(sum(sized, 'riderMembers') / sized.length).toFixed(1) : 0,
      ridesWithStaff: ended.filter((c) => c.hasStaff).length,
      sos: { all: sum(ended, 'sos'), recent: sum(recent, 'sos') },
    });
  }));
  r.get('/admin/feedback', requireAdmin, wrap(async (req, res) => {
    const items = typeof repo.listTripFeedback === 'function' ? await repo.listTripFeedback(200) : await repo.listFeedback(200);
    const summary = {
      total: items.length,
      pending: items.filter((f) => f.status === 'PENDING_REVIEW').length,
      approved: items.filter((f) => f.status === 'APPROVED').length,
      rejected: items.filter((f) => f.status === 'REJECTED').length,
      withdrawn: items.filter((f) => f.status === 'WITHDRAWN').length,
      changesRequested: items.filter((f) => f.status === 'CHANGES_REQUESTED' || f.status === 'NEEDS_CLARIFICATION').length,
      withPhotos: items.filter((f) => f.photoUrl && f.photoUrl.length > 0).length,
    };
    res.json({ summary, feedback: items });
  }));

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
    const emails = staffEmails();
    const enriched = users.map((u) => {
      const act = activeMap.get(u.userId) || null;
      return {
        ...u,
        staff: !isGuestAccount(u) && isStaffAccount(u, emails),
        activeGroup: act,
        isInActiveConvoy: !!act,
      };
    });
    // Counted here so the console never recounts on the phone: riders exclude staff and guests.
    const guests = enriched.filter((u) => isGuestAccount(u)).length;
    const staff = enriched.filter((u) => u.staff).length;
    res.json({
      users: enriched,
      counts: {
        accounts: enriched.length, riders: enriched.length - staff - guests, staff, guests,
        onHold: enriched.filter((u) => u.status === 'ON_HOLD').length,
        ridersOnHold: enriched.filter((u) => u.status === 'ON_HOLD' && !u.staff).length,
      },
    });
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
        // 3.55 public username and profile picture (DELETE /admin/users/:userId/avatar removes it).
        username: user.username || '', avatarUrl: require('./avatars').avatarUrlOf(user.avatarId),
      },
      activeGroup,
      isInActiveConvoy: !!activeGroup,
      groups,
      // 3.55 rider score breakdown (src/rider_score.js); null before the first ride.
      riderScore: convoys.riderScore ? await convoys.riderScore.adminView(userId).catch(() => null) : null,
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

  // ---- FEAT-DIAG-02: Diagnostic Report Submission ----
  r.post('/diagnostics/submit', diagSubmitLimiter, wrap(async (req, res) => {
    // 1. Check prohibited information
    if (containsProhibitedDiagnosticKeys(req.body)) {
      return res.status(400).json({ error: 'Prohibited information detected in diagnostic report.' });
    }

    // 2. Validate payload schema & consent
    if (req.body.consentGiven !== true) {
      return res.status(400).json({ error: 'Explicit rider consent is required to submit diagnostic reports.' });
    }
    if (!req.body.diagnosticId || typeof req.body.diagnosticId !== 'string') {
      return res.status(400).json({ error: 'diagnosticId string is required.' });
    }
    if (!req.body.deviceInfo || typeof req.body.deviceInfo !== 'object') {
      return res.status(400).json({ error: 'deviceInfo object is required.' });
    }
    if (!req.body.categories || typeof req.body.categories !== 'object') {
      return res.status(400).json({ error: 'categories object is required.' });
    }
    if (!req.body.overallResult || typeof req.body.overallResult !== 'string') {
      return res.status(400).json({ error: 'overallResult string is required.' });
    }

    const payload = {
      ...req.body,
      riderId: req.user?.userId || req.body.riderId,
      riderEmail: req.user?.email || req.body.riderEmail,
    };

    try {
      const result = await repo.submitDiagnostic(payload);
      res.json(result);
    } catch (err) {
      if (err.statusCode === 429) {
        return res.status(429).json({ error: err.message });
      }
      throw err;
    }
  }));

  // ---- FEAT-DIAG-03: Admin Device Compatibility Dashboard ----
  r.get('/admin/diagnostics', requireAdmin, wrap(async (req, res) => {
    const stats = await repo.getDiagnosticStats();
    const { reports, pagination } = await repo.listDiagnostics(req.query);
    res.json({ ok: true, stats, reports, pagination });
  }));

  r.get('/admin/diagnostics/:id', requireAdmin, wrap(async (req, res) => {
    const report = await repo.getDiagnostic(req.params.id);
    if (!report) return res.status(404).json({ error: 'Diagnostic report not found' });
    res.json({ ok: true, report });
  }));

  r.patch('/admin/diagnostics/:id', requireAdmin, wrap(async (req, res) => {
    const updated = await repo.updateDiagnosticStatus(req.params.id, {
      status: req.body?.status,
      adminNotes: req.body?.adminNotes,
      by: req.user?.email || req.user?.userId,
    });
    if (!updated) return res.status(404).json({ error: 'Diagnostic report not found' });
    res.json({ ok: true, report: updated });
  }));

  // Subscription and Razorpay UPI-only payment routes (including admin pricing & coupon management)
  registerSubscriptionAuthRoutes({ r, auth, repo, hub, wrap, requireAdmin });
  registerMembershipAuthRoutes({ r, repo, convoys, wrap, requireAdmin, hub });
  // 3.56 marketing board: admin posts (web admin "Board" section).
  require('./board').registerBoardAdminRoutes({ r, repo, wrap, requireAdmin });
  // 3.55: saved road reports along a ride, CoRoute rider place reviews (+ admin moderation).
  require('./road_and_places').registerRoadAndPlaceRoutes({ r, repo, convoys, wrap, requireAdmin });
  // 3.55 risky-stretch heads-up: anonymous hard-brake cells, served only with k >= 10 riders.
  require('./road_risk').registerRoadRiskRoutes({ r, repo, convoys, wrap });
  // Admin analytics (overview, riders, groups) and per-rider configuration (role, status, plan, limits).
  registerAdminAnalyticsRoutes({
    r, repo, convoys, auth, hub, gate, wrap, requireAdmin,
    plans: {
      // 3.55: the console assigns Community / Small Group / Large Group as a real membership.
      assign: ({ req, userDoc, plan, days, note }) => assignPlan({ repo, auth, hub, convoys, req, userDoc, plan, days, note }),
    },
  });

  // Errors
  // eslint-disable-next-line no-unused-vars
  r.use((err, req, res, next) => {
    if (err.statusCode && err.statusCode >= 400 && err.statusCode < 500) return res.status(err.statusCode).json({ error: err.message });
    if (err instanceof AuthError) return res.status(err.status).json({ error: err.message, ...(err.code ? { code: err.code } : {}) });
    if (err instanceof ValidationError) return res.status(err.status).json({ error: err.message, code: err.code, fields: err.fields });
    if (err instanceof ConvoyError) return res.status(err.status).json({ error: err.message, ...(err.reason ? { code: err.reason, reason: err.reason } : {}) });
    if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Malformed JSON' });
    console.error('[api]', err);
    res.status(500).json({ error: 'Internal error' });
  });

  return r;
}

module.exports = { buildRouter };
