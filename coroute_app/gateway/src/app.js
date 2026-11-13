'use strict';
/**
 * Wires every component together. Exported as a factory so tests can boot a
 * full gateway against the in-memory SODA implementation.
 */
const http = require('http');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const config = require('./config');
const { SodaClient } = require('./oracle/soda');
const { MemorySoda } = require('./oracle/memory_soda');
const { Repo } = require('./oracle/repo');
const { AuthService, UserGate, requireAuth, requireAdmin } = require('./auth');
const { ConvoyManager } = require('./convoys');
const { Hub } = require('./ws');
const { Retention } = require('./retention');
const { SubscriptionSweeper, expireIfDue } = require('./subscription_lifecycle');
const { buildRouter } = require('./routes');
const { seedDefaultCoupons } = require('./subscription_routes');
const { TrackStore } = require('./tracks');
const { GeoProxy } = require('./geo');
const { EssentialsService, OverpassPlacesProvider } = require('./essentials');
const { PoiCellService } = require('./poi_cells');
const { TimelineEngine } = require('./timeline');
const { SafetyNetwork } = require('./safety_network');
const { Discovery } = require('./discovery');
const { PublicRides, publicRideAdminRouter } = require('./public_ride');
const { AdminWarnings } = require('./admin_warnings');
const { SafetyAudit } = require('./safety_audit');
const { RouteIndexCache, gridSize } = require('./net_geo');
const { loadSite, isHiddenPath, SITE_PAGES, SITEMAP, MARKETING_CSP } = require('./pages');
const rateLimit = require('express-rate-limit');
const { liveTokenOf } = require('./validate');
const { communityStories } = require('./trip_reviews');
const { sha256 } = require('./convoys');
const { GuardianService } = require('./guardians');
const { GuardianPush } = require('./guardian_push');
const { GuardianArrival } = require('./guardian_arrival');
const { SignalAhead } = require('./signal_ahead');
const { guardianRouter } = require('./guardian_routes');
const { EmergencySmsGateway } = require('./emergency_sms_gateway');
const { JobLease } = require('./job_lease');
const { Mirror } = require('./mirror');
const { FeatureFlags } = require('./feature_flags');
const { siteOriginsOf, legacyHostRedirect } = require('./domains');
const { Metrics, instrumentSoda } = require('./metrics');
const { LoadShedder } = require('./load_shed');
// Encrypted Object Storage backups (src/backups.js -> backup_jobs.js): startBackupJobs({ lease, repo, soda, logger })
// registers 'backup-critical' and 'backup-full' on the job lease. Optional so a build without it still starts.
const backupModule = (() => {
  try { return require('./backups'); } catch (e) {
    if (e.code === 'MODULE_NOT_FOUND' && String(e.message).includes("'./backups'")) return null;
    throw e;
  }
})();

function createSoda() {
  if (config.sodaUrl === 'memory' || config.sodaUrl === 'http://mock') return new MemorySoda();
  return new SodaClient({ baseUrl: config.sodaUrl, user: config.oracleUser, password: config.oraclePassword, timeoutMs: config.oracleTimeoutMs });
}

async function createApp({ soda = createSoda(), logger = console, migrate = true, googleVerifier, geoFetch, clock, emergencyFetch, lease, mirror: mirrorOpts, pushTransport, diagObjectStore, mailTransport, smsProviders, smsFetch, pushImageStore } = {}) {
  // 3.57 security: every log line is redacted (tokens, passwords, OTPs, e-mails, phone numbers; src/redact.js).
  logger = require('./redact').redactingLogger(logger);
  // v3.56: Prometheus metrics (GET /metrics, loopback / METRICS_ALLOW / METRICS_TOKEN only) and SODA call counters.
  const metrics = new Metrics({ allow: config.metricsAllow, token: config.metricsToken });
  soda = instrumentSoda(soda, metrics);
  // 3.57 security: protected fields (phones, emergency contact, medical ID, 2-step secrets) are encrypted at rest
  // with AES-256-GCM when DATA_ENC_KEY is set (src/field_crypto.js); every module reads them decrypted.
  const fieldCrypto = require('./field_crypto').fieldCryptoFromConfig(config, logger);
  const rawSoda = soda;
  soda = require('./field_crypto').encryptingSoda(soda, fieldCrypto, { logger });
  if (!fieldCrypto.enabled && config.env === 'production') {
    logger.warn('[config] DATA_ENC_KEY is not set: phone numbers, emergency contacts and medical ID fields are stored without field encryption.');
  }
  const repo = new Repo(soda);
  const nodeName = config.nodeName || process.env.NODE_NAME || require('os').hostname();
  // Scheduled jobs run on exactly one node of a two-VM deployment (src/job_lease.js, GATEWAY_ROLE).
  lease = lease || new JobLease({ soda, role: config.gatewayRole, node: nodeName, logger,
    ttlMs: config.jobLeaseTtlMs, heartbeatMs: config.jobLeaseHeartbeatMs, graceMs: config.jobLeaseGraceMs });
  if (config.jwtSecretPrevious) {
    logger.warn('[auth] JWT_SECRET_PREVIOUS is configured: tokens signed with it are accepted (verification only) and refreshed to JWT_SECRET. Remove it once the rotation grace period is over.');
  }
  if (!config.settingsEncryptionKey && config.env === 'production') {
    logger.warn('[config] SETTINGS_ENCRYPTION_KEY is not set: saved Razorpay secrets and checkout links depend on JWT_SECRET.');
  }
  if (migrate) {
    await repo.migrate();
    // The launch coupons are ordinary coupon records: created once when absent, then admin-managed.
    // Leased so two nodes booting together never seed twice.
    await lease.once('coupon-seed', () => seedDefaultCoupons(repo))
      .catch((e) => logger.warn(`[coupons] default coupon seed failed: ${e.message}`));
  }

  // 3.57 server-side sessions (src/sessions.js): every token is bound to one; revokes end it everywhere at once.
  const sessions = new (require('./sessions').SessionStore)({ soda, logger, fieldCrypto });
  if (migrate) await sessions.init();
  const gate = new UserGate(repo, { sessions });
  const auth = new AuthService(repo, { googleVerifier, gate });
  const convoys = new ConvoyManager(repo, { logger });
  // 3.55 admin feature switches: one cached copy per node (re-read every 30 s and on a mirror poke);
  // every enforcement point reads convoys.featureFlags (no DB read per message). A failed first read
  // leaves every feature on.
  const featureFlags = new FeatureFlags({ repo, logger });
  convoys.featureFlags = featureFlags;
  await featureFlags.refresh();
  featureFlags.start();
  // 3.56 access mode (src/access_mode.js): paid / free for everyone / free up to limits, set in the web
  // admin. One cached copy per node (re-read every 30 s, schedule boundary checked every 15 s).
  const accessMode = new (require('./access_mode').AccessMode)({ repo, logger });
  convoys.accessMode = accessMode;
  await accessMode.refresh();
  accessMode.start();
  // 3.55 buddy pairs in large groups (src/buddies.js): assigned, stored and relayed only.
  convoys.buddies = new (require('./buddies').BuddyService)(convoys, { logger });
  const emergencyGateway = new EmergencySmsGateway({
    repo,
    convoys,
    logger,
    fetchImpl: emergencyFetch || geoFetch || globalThis.fetch,
    config,
  });
  convoys.emergencyGateway = emergencyGateway;
  // 3.16: the live link index and the role / live link audit rows go through the same audit as the network.
  const audit = new SafetyAudit({ repo, logger });
  convoys.audit = audit;
  sessions.audit = audit;
  // An app session is never ended by its absolute lifetime during a ride, an open SOS / crash alert (src/sessions.js).
  sessions.isRiding = async (userId) => {
    for (const room of convoys.rooms.values()) {
      if (!room || !room.riders || !room.riders.has(userId)) continue;
      if (['PLANNING', 'STARTED', 'PAUSED'].includes((room.meta || {}).tripStatus)) return true;
      for (const al of (room.alerts && room.alerts.values ? room.alerts.values() : [])) if (al && !al.resolved && al.userId === userId) return true;
    }
    return !!(await repo.getActiveTrip(userId).catch(() => null));
  };
  // Round 4 ride lock (src/ride_lock.js): no sign-in on another device while this account's device is on a live ride.
  const rideLock = new (require('./ride_lock').RideLock)({ sessions, repo, convoys, audit, codes: auth.codes, logger });
  auth.rideLock = rideLock;
  // A phone number, emergency-text opt-out or nearby-assistance switch change reaches the rider's live ride.
  auth.onProfileChanged = (user, keys) => convoys.applyProfile(user.userId, user, keys);
  const tracks = new TrackStore(repo);
  const geo = new GeoProxy({ repo, logger, ...(geoFetch ? { fetchImpl: geoFetch } : {}) });
  // Dedicated queue: background POI checks never block emergency hospital routing.
  const essentialsGeo = new GeoProxy({ repo, logger, ...(geoFetch ? { fetchImpl: geoFetch } : {}) });
  const essentials = new EssentialsService({ repo,
    places: process.env.ESSENTIALS_OVERPASS_URL ? new OverpassPlacesProvider({ url: process.env.ESSENTIALS_OVERPASS_URL, ...(geoFetch ? { fetchImpl: geoFetch } : {}) }) : null,
    routing: (wp) => essentialsGeo.route(wp),
  });
  // Map places: proxy + cache only (memory LRU + geo_cache, 7 days); the phone does the rest.
  const poiCells = new PoiCellService({ repo, logger, url: process.env.POI_OVERPASS_URL || process.env.ESSENTIALS_OVERPASS_URL || null, ...(geoFetch ? { fetchImpl: geoFetch } : {}) });
  convoys.router = (wp) => geo.route(wp);
  convoys.geo = geo; // 3.16: nearest hospital lookups (never awaited by the SOS path)
  const timeline = new TimelineEngine({ convoys, repo, tracks, geo, logger, ...(clock ? { clock } : {}) });
  // 3.15: rider safety network and rider discovery (separate modules; they share only route geometry).
  const routes = new RouteIndexCache({ simplifyM: config.netRouteSimplifyM, maxPoints: config.netRouteMaxPoints, G: gridSize(config.netGridMillideg) });
  const network = new SafetyNetwork({ convoys, geo, audit, logger, routes, emergencyGateway });
  const discovery = new Discovery({ convoys, network, audit, logger, routes });
  // Public ride and road warnings: coarse positions only, its own state (mirrored as extension 'pr').
  const publicRides = new PublicRides({ convoys, network, audit, soda, repo, logger, routes });
  await publicRides.init();
  convoys.on('telemetry', (gid, rider) => publicRides.onTelemetry(gid, rider));
  convoys.network = network;
  convoys.on('emergency', (gid, alert, kind, ctx) => network.onEmergency(gid, alert, kind, ctx));
  convoys.on('telemetry', (gid, rider) => network.onTelemetry(gid, rider));
  convoys.on('roomLoaded', (gid) => network.onRoomLoaded(gid));
  convoys.on('roomEnded', (gid, room) => { network.onRoomEnded(gid, room); discovery.onRoomEnded(gid); publicRides.onRoomEnded(gid); });
  // 3.55 solo and guardian safety: "Arrived safely" markers for guardian links, no-signal-ahead
  // notices (memory only), and public-ride blocks / suspensions for the safety network's public riders.
  new GuardianArrival({ convoys, repo, logger }).attach();
  convoys.signalAhead = new SignalAhead({ convoys, logger });
  convoys.on('roomEnded', (gid) => convoys.signalAhead.onRoomEnded(gid));
  // 3.55 rider score + public leaderboard (src/rider_score.js, src/leaderboard.js): rides are recorded
  // when a trip report is finished (TimelineEngine.finishTrip -> convoys.riderScore).
  const riderScore = new (require('./rider_score').RiderScoreService)({ soda, repo, flagsOf: () => featureFlags, logger });
  convoys.riderScore = riderScore;
  if (migrate) await riderScore.init().catch((e) => logger.warn(`[rider-score] collection setup failed: ${e.message}`));
  const leaderboard = new (require('./leaderboard').Leaderboard)({ soda, repo, riderScore, flagsOf: () => featureFlags });
  network.publicRides = publicRides;
  // Round 4 road & safety intelligence (src/intel/, docs/intelligence/): created here so it hears telemetry from the start;
  // its routes are attached below (before the main router).
  let intel = null;

  const app = express();
  app.disable('x-powered-by');
  app.use(metrics.middleware());
  // Never public: Caddy also answers 404 for /metrics from the internet. Before helmet / CORS (plain text).
  app.get('/metrics', metrics.handler());
  // Only these proxies' X-Forwarded-For is believed (TRUST_PROXY; default loopback = this VM's Caddy).
  // VM2 also trusts VM1's private IP, so req.ip (and every IP rate limit) is the real client.
  app.set('trust proxy', config.trustProxy);
  // Two-VM deployment: which node answered (for checking the Caddy route split). Not sent on a single VM.
  if (config.gatewayRole !== 'all') app.use((req, res, next) => { res.set('X-CoRoute-Node', `${nodeName}/${config.gatewayRole}`); next(); });
  app.use(helmet({
    contentSecurityPolicy: {
      directives: {
        // 3.57: the default for every response without its own policy (API answers, /e/, /join ...): no inline or
        // third-party script at all. Pages that need Razorpay or Google (/plans, /checkout, /signin) set their own.
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'"],
        scriptSrcAttr: ["'none'"],
        styleSrc: ["'self'", "'unsafe-inline'"],
        imgSrc: ["'self'", "data:", "https:"],
        connectSrc: ["'self'"],
        fontSrc: ["'self'"],
        frameSrc: ["'none'"],
        objectSrc: ["'none'"],
        frameAncestors: ["'none'"],
        baseUri: ["'self'"],
        formAction: ["'self'"],
      },
    },
    frameguard: { action: 'deny' },
    xContentTypeOptions: true,
    // 3.57: HSTS from config (Caddy may set its own per host; docs/security/SECURITY_AUDIT_v3.55.md).
    strictTransportSecurity: { maxAge: config.hstsMaxAge, includeSubDomains: true, preload: config.hstsPreload },
    referrerPolicy: { policy: 'strict-origin-when-cross-origin' },
  }));
  // 3.57: API answers are never cached by browsers or proxies unless a route says otherwise (public stats do);
  // private data cannot come back from the cache after sign-out (Back button, shared computers).
  app.use('/api', (req, res, next) => { res.set('Cache-Control', 'no-store'); res.set('Pragma', 'no-cache'); next(); });
  // 3.55: a request id on every request (X-Request-Id from Caddy / the client when well-formed, else a new
  // one), echoed in the response; server-side errors are logged with it (never bodies or personal data).
  app.use((req, res, next) => {
    const given = req.get('x-request-id');
    req.requestId = typeof given === 'string' && /^[A-Za-z0-9_.:-]{8,64}$/.test(given) ? given : require('crypto').randomBytes(8).toString('hex');
    res.setHeader('X-Request-Id', req.requestId);
    next();
  });
  app.use((req, res, next) => {
    res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(self "https://checkout.razorpay.com" "https://api.razorpay.com")');
    next();
  });
  // CORS_ORIGINS, when set, always includes every site origin (PUBLIC_ORIGIN and the legacy hosts).
  const corsOrigins = config.corsOrigins.length ? [...new Set([...config.corsOrigins, ...siteOriginsOf(config)])] : [];
  app.use(cors(corsOrigins.length ? { origin: corsOrigins } : { origin: false }));
  // REDIRECT_LEGACY_HOST=true: website pages on the old host -> PUBLIC_ORIGIN (301). Never /api, /ws, /.well-known.
  app.use(legacyHostRedirect(config));
  // v3.56 load shedding (src/load_shed.js): only non-essential reads, only under overload; never SOS, alerts, auth,
  // ride telemetry, convoy routes or webhooks. Before body parsing, so a shed request costs nothing.
  const shedder = new LoadShedder({ loop: metrics.loop, metrics,
    dbQueue: () => (typeof rawSoda.queueLength === 'function' ? rawSoda.queueLength() : 0) });
  app.use(shedder.middleware());
  // The Razorpay webhook is signed over the exact bytes it sends: keep them raw, and small (1 MB).
  app.use('/api/subscription/webhook', express.raw({ type: () => true, limit: '1mb' }));
  app.use('/api/membership/webhook', express.raw({ type: () => true, limit: '1mb' }));
  app.use(express.json({ limit: '2mb' }));

  const server = http.createServer(app);
  // v3.56 keep-alive above Caddy's upstream idle timeout (60 s), headers timeout above that (Node's rule).
  server.keepAliveTimeout = config.httpKeepAliveMs;
  server.headersTimeout = config.httpKeepAliveMs + 5000;
  const startedAt = Date.now();
  const hub = new Hub({ server, convoys, repo, tracks, timeline, logger, gate, network, discovery, emergencyGateway, publicRides });
  hub.rideLock = rideLock;
  // 3.57: sockets kept open only for a ride (their session was signed out) close when that ride ends.
  convoys.on('roomEnded', (gid) => { try { hub.closeRevokedOf(gid); } catch { /* the next message closes them */ } });
  // 3.57: browsers may open the socket only from this site (the app sends no Origin).
  hub.allowedOrigins = new Set([...siteOriginsOf(config), ...config.corsOrigins].map((o) => String(o).toLowerCase()));
  network.attach(hub);
  discovery.attach(hub);
  publicRides.attach(hub);
  // 3.55 platform: a report's WARN reaches the rider (stored until acknowledged, pushed when online).
  publicRides.adminWarnings = new AdminWarnings({ repo, hub, audit, flagsOf: () => featureFlags, logger });
  // 3.55 push notifications (src/push.js): FCM HTTP v1, off unless FCM_SERVICE_ACCOUNT_JSON / _FILE is set.
  // One service per gateway: hub.push, convoys.push, app.locals.push (push.notifyUsers(...), never throws).
  const push = require('./push').attachPush({ app, repo, hub, convoys, featureFlags, logger, ...(pushTransport !== undefined ? { transport: pushTransport } : {}) });
  // Two-node live mirror (src/mirror.js): off unless MIRROR_LISTEN_HOST / MIRROR_PEER_URL are set (opts: tests).
  const mirror = new Mirror({ convoys, logger, node: nodeName, ...(mirrorOpts || {}) });
  mirror.attach(hub);
  mirror.register('pr', publicRides);
  // 3.57: a session revoked on one node closes its sockets on both (the database stays the truth).
  const kickRevoked = ({ sids = [], userId = null, all = false, exceptSid = null, reason = 'SIGNED_OUT' } = {}) => {
    const held = /^ACCOUNT_(ON_HOLD|BLOCKED)$/.test(String(reason));
    const code = held ? 4403 : 4401;
    const why = held ? String(reason) : 'SIGNED_OUT';
    // A sign-out never cuts a rider out of a live ride (SOS relay, crash alerts): that socket closes when the ride ends.
    // Hold, block and deletion close everything at once (admin decisions, unchanged).
    const spareRiding = !held && reason !== 'ACCOUNT_DELETED';
    if (all || (userId && exceptSid)) hub.disconnectUser(userId, code, why, { exceptSid, spareRiding });
    else for (const sid of sids) hub.disconnectSession(sid, code, why, { spareRiding });
  };
  sessions.onRevoke = (ev) => {
    kickRevoked(ev);
    try { mirror.ext('ss', { op: 'REVOKE', sids: (ev.sids || []).slice(0, 1000), userId: ev.userId, all: !!ev.all, exceptSid: ev.exceptSid || null, reason: ev.reason }); } catch { /* the peer's cache expires within USER_GATE_TTL_MS */ }
  };
  sessions.onRemoteRevoke = (ev) => kickRevoked(ev);
  mirror.register('ss', sessions);
  // Round 4: a ride handover asked for on the node without the room (the web node) is told to the group by the peer.
  mirror.register('rl', rideLock);
  rideLock.toPeer = (op) => { if (!mirror.linked()) return false; mirror.ext('rl', op); return true; };
  // A switch changed on one node pokes the other to re-read the document (the DB stays the truth).
  mirror.register('ff', featureFlags);
  // Every connected app switches within seconds (each node tells its own sockets).
  featureFlags.on('change', (snap) => hub.broadcastAll({ type: 'FEATURE_FLAGS', ...snap }));
  // 3.56 access mode: a change (admin save, the other node, or the schedule boundary) tells every app to
  // re-read its capabilities (GET /api/me/capabilities) and gives live rides their new seats (never fewer).
  mirror.register('am', accessMode);
  accessMode.on('change', (ev) => {
    hub.broadcastAll({ type: 'CAPABILITIES_CHANGED', version: ev.version });
    convoys.refreshAllCapacities().catch((e) => logger.warn?.(`[access-mode] ride refresh failed: ${e.message}`));
  });
  await mirror.start();
  let guardianPush = null;
  // Pilot is disabled by default; an explicit HTTPS origin prevents host-header links.
  if (process.env.GUARDIAN_ENABLED === 'true') {
    const origin = new URL(config.publicOrigin);
    if (origin.protocol !== 'https:' || origin.origin !== config.publicOrigin) throw new Error('Guardian requires an HTTPS PUBLIC_ORIGIN');
    const service = new GuardianService({ repo, convoys });
    if (process.env.GUARDIAN_PUSH_ENABLED === 'true') {
      const webpush = require('web-push');
      const publicKey = process.env.GUARDIAN_VAPID_PUBLIC_KEY;
      webpush.setVapidDetails(process.env.GUARDIAN_VAPID_SUBJECT,
        publicKey, process.env.GUARDIAN_VAPID_PRIVATE_KEY);
      guardianPush = new GuardianPush({ repo, service, publicKey,
        send: (subscription, payload, options) => webpush.sendNotification(subscription, payload, options) });
      // Leased (one node), preferring the live node: building a guardian view loads the ride room.
      const push = guardianPush;
      lease.run('guardian-push', 15000, () => push.tick(), { prefer: 'live', firstDelayMs: 15000 });
    }
    app.use('/api/guardian', guardianRouter({ service, gate, origin: origin.origin, allowedOrigins: siteOriginsOf(config), push: guardianPush }));
  }
  // ---- Public website, served from here so no extra hosting is needed ----
  const path = require('path');
  const pub = (f) => path.join(__dirname, '..', 'public', f);
  const originOf = (req) => config.publicOrigin || `${req.protocol}://${req.get('host')}`;
  // Pages are assembled once at startup (shared header/footer partials, asset version); per request only
  // __ORIGIN__ (canonical, og:image, sitemap work for any domain) and __MAX_RIDERS__ are filled in.
  const site = loadSite(pub(''));
  // "Up to N riders": the largest paid plan's seats in the membership catalog (admin-editable, 12 when
  // the catalog says nothing), refreshed at most once a minute. MAX_CONVOY_RIDERS is only the server's
  // safety ceiling: it caps the number but is never advertised.
  const { siteMaxRiders: siteMaxRidersOf } = require('./plan_pricing');
  let siteMaxRiders = siteMaxRidersOf(null, config.maxConvoyRiders);
  let siteMaxReadAt = 0;
  const refreshSiteMaxRiders = () => {
    if (Date.now() - siteMaxReadAt < 60000) return;
    siteMaxReadAt = Date.now();
    repo.getMembershipCatalog().then((catalog) => { siteMaxRiders = siteMaxRidersOf(catalog, config.maxConvoyRiders); }).catch(() => {});
  };
  const pageVars = (req) => { refreshSiteMaxRiders(); return { __ORIGIN__: originOf(req), __MAX_RIDERS__: String(siteMaxRiders) }; };
  // A Cache-Control set earlier (the 3.56 shop pages: no-store) is kept.
  const sendPage = (res, html) => res.type('html').set('Cache-Control', res.get('Cache-Control') || 'public, max-age=300').send(html);
  const notFoundPage = (req, res) => res.status(404).type('html').set('Cache-Control', 'no-store').send(site.render('404.html', pageVars(req)));

  // 3.56 rider shop (src/web_shop.js): shop page headers (strict CSP), /get?coupon= -> /plans, /checkout
  // without an app order -> /plans, /api/web/config and /api/web/receipt/:orderId. Before the page routes.
  require('./web_shop').attachWebShop({ app, repo, gate, logger });
  // Marketing and legal pages: a strict CSP of their own (no inline script; src/pages.js MARKETING_CSP). The shop
  // pages and /checkout already carry theirs (web_shop.js).
  const shopRoutes = new Set([...Object.keys(require('./web_shop').SHOP_PAGES), '/checkout']);
  for (const [route, file] of Object.entries(SITE_PAGES)) {
    const paths = route === '/' ? ['/', '/index.html'] : [route, `${route}.html`];
    const strict = !shopRoutes.has(route);
    app.get(paths, (req, res) => {
      if (strict) res.set('Content-Security-Policy', MARKETING_CSP);
      sendPage(res, site.render(file, pageVars(req)));
    });
  }
  // RFC 9116 security.txt: Contact from SECURITY_CONTACT (else SUPPORT_EMAIL), Expires one year ahead, Policy /security.
  app.get(['/.well-known/security.txt', '/security.txt'], (req, res) => {
    res.type('text/plain; charset=utf-8').set('Cache-Control', 'public, max-age=86400').send(securityTxt({
      origin: originOf(req), contact: config.securityContact, now: Date.now(),
    }));
  });
  // One download link that never breaks: Play Store when configured, otherwise the APK this server hosts
  // (public/coroute.apk, 64-bit ARM). Older 32-bit phones use /download/32bit.
  app.get('/download', (req, res) => {
    res.set('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
    res.set('Pragma', 'no-cache');
    res.set('Expires', '0');
    res.redirect(302, config.playStoreUrl || config.apkUrl || `${originOf(req)}${config.apkPath}`);
  });
  app.get('/download/32bit', (req, res) => {
    res.set('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
    res.set('Pragma', 'no-cache');
    res.set('Expires', '0');
    res.redirect(302, config.apkArm32Url || `${originOf(req)}${config.apkArm32Path}`);
  });
  app.get('/download/ios', (req, res) => {
    res.set('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
    res.set('Pragma', 'no-cache');
    res.set('Expires', '0');
    const target = config.appStoreUrl || config.iosTestFlightUrl || config.iosIpaUrl || `${originOf(req)}/get`;
    res.redirect(302, target);
  });
  app.get('/robots.txt', (req, res) => res.type('text/plain').send(`User-agent: *\nAllow: /\nDisallow: /api/\nDisallow: /admin\nSitemap: ${originOf(req)}/sitemap.xml\n`));
  app.get('/sitemap.xml', (req, res) => {
    const o = originOf(req);
    const today = new Date().toISOString().slice(0, 10);
    const urls = SITEMAP
      .map(([u, pr]) => `  <url><loc>${o}${u}</loc><lastmod>${today}</lastmod><priority>${pr}</priority></url>`).join('\n');
    res.type('application/xml').send(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`);
  });
  app.get('/watch-sw.js', (req, res) => {
    if (process.env.GUARDIAN_ENABLED !== 'true') return notFoundPage(req, res);
    res.set('Cache-Control', 'no-cache').set('Service-Worker-Allowed', '/watch').type('application/javascript').sendFile(pub('_watch-sw.js'));
  });
  app.get('/watch', (req, res) => {
    if (process.env.GUARDIAN_ENABLED !== 'true') return notFoundPage(req, res);
    res.set('Cache-Control', 'no-store').set('Referrer-Policy', 'no-referrer')
      .set('X-Robots-Tag', 'noindex, nofollow')
      .set('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data: https://tile.openstreetmap.org https://*.tile.openstreetmap.org; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'; worker-src 'self'; manifest-src 'self'")
      .type('html').send(site.render('watch.html', pageVars(req)));
  });
  // 3.57 ride summary e-mail link: /trip/<tripId> shows the signed-in owner's own ride (numbers only; the page
  // reads GET /api/trips/:tripId, which answers 404 for anyone else). Shop page headers: strict CSP, no-store, noindex.
  app.get('/trip/:tripId', require('./web_shop').shopPageHeaders('/trip'), (req, res) => {
    if (!/^[A-Za-z0-9_.:-]{3,120}$/.test(String(req.params.tripId || ''))) return notFoundPage(req, res);
    res.type('html').send(site.render('trip.html', pageVars(req)));
  });
  // Join link shared from the app: opens the app via its custom scheme, with the download as fallback.
  app.get('/join/:code', (req, res) => {
    const code = String(req.params.code || '').toUpperCase();
    if (!/^[A-Z0-9]{4,10}$/.test(code)) return res.redirect(302, '/');
    const html = site.render('join.html', { ...pageVars(req), __CODE__: code });
    res.type('html').set('Cache-Control', 'no-store').send(html);
  });
  // 3.16 live emergency link page: the rider's first name, last position and time for 30 minutes. Never cached,
  // never indexed, no referrer leaves the page. A malformed token is a 404; a dead link the expired page (410).
  const publicLiveLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  app.get('/e/:token', publicLiveLimiter, async (req, res, next) => {
    const token = liveTokenOf(req.params.token);
    if (!token) return notFoundPage(req, res);
    res.set('Cache-Control', 'no-store').set('Referrer-Policy', 'no-referrer').set('X-Robots-Tag', 'noindex');
    let view;
    try {
      // After a gateway restart the room of an injured, offline rider may not be loaded yet.
      view = (await convoys.liveViewLoaded(sha256(token))) || emergencyGateway.liveView(sha256(token));
    } catch (e) { return next(e); }
    if (!view) {
      const html = site.has('live_expired.html') ? site.render('live_expired.html', pageVars(req)) : plainLivePage(null);
      return res.status(410).type('html').send(html);
    }
    const vars = {
      ...pageVars(req), __RIDER__: esc(view.firstName || 'A rider'), __LAT__: view.lat.toFixed(5), __LNG__: view.lng.toFixed(5),
      __AT__: new Date(view.at).toISOString(), __EXPIRES__: new Date(view.expiresAt).toISOString(),
    };
    const html = site.has('live.html') ? site.render('live.html', vars) : plainLivePage(vars);
    res.type('html').send(html);
  });
  // Android App Links verification (express.static ignores dot-directories, so serve it explicitly).
  app.get('/.well-known/assetlinks.json', (req, res) => res.type('application/json').set('Cache-Control', 'public, max-age=86400').sendFile(pub('.well-known/assetlinks.json')));
  app.get('/status', (req, res) => res.json({ service: 'CoRoute Gateway', version: require('../package.json').version, status: 'ONLINE' }));
  // Legacy website path: the same approved, consented stories as /api/public/community-stories (a bare array).
  const storiesLimiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  app.get('/community-stories', storiesLimiter, async (req, res, next) => {
    try {
      res.set('Cache-Control', 'public, max-age=30');
      res.json((await communityStories(repo, req.query.limit || 20)).stories);
    } catch (err) {
      next(err);
    }
  });
  // 3.55 web admin (src/web_admin.js): /admin page + assets with their own strict CSP and noindex.
  app.use(require('./web_admin').webAdminPages({ publicDir: pub('') }));
  // 3.56 operator / club console (src/operator_routes.js): /operator console, /operators/apply, /clubs, /rides/<slug>
  // and their /api routes. Before the static files (console assets carry their own CSP). The mailer is read lazily.
  require('./operator_routes').attachOperators({ app, repo, gate, convoys, hub, tracks, featureFlags, site, pageVars, notFoundPage, logger,
    mailerOf: () => { try { return notifications.mailer; } catch { return null; } } });
  // Partials, templates (_*.html) and raw page sources are never served directly: every page has a route above.
  app.use((req, res, next) => (!req.path.startsWith('/api/') && isHiddenPath(req.path) ? notFoundPage(req, res) : next()));
  app.use(express.static(pub(''), {
    index: false, maxAge: '7d', extensions: false,
    setHeaders: (res, p) => {
      if (p.endsWith('.html')) res.setHeader('Cache-Control', 'no-store');
      // 3.56 website screenshots: the bundled mime table predates AVIF.
      if (p.endsWith('.avif')) res.setHeader('Content-Type', 'image/avif');
      if (p.endsWith('.woff2') || p.endsWith('.woff')) res.setHeader('Access-Control-Allow-Origin', '*');
      // The APK/IPA keeps its name across releases: always check for a newer one.
      if (p.endsWith('.apk')) {
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Content-Type', 'application/vnd.android.package-archive');
      }
      if (p.endsWith('.ipa')) {
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Content-Type', 'application/octet-stream');
      }
    },
  }));
  // Load balancer health for live traffic (VM1 primary / VM2 backup): 200 serving, 503 syncing / overloaded / shutdown.
  app.get('/api/health/live', (req, res) => { const h = mirror.health(); res.status(h.status).set('Cache-Control', 'no-store').json(h.body); });
  // Public ride safety review (reports with their conversation, contact log, suspensions): admins only.
  app.use('/api/admin/public-ride', requireAuth(gate), requireAdmin, publicRideAdminRouter(publicRides));
  // 3.55 web admin read-only endpoints (config, revenue aggregates): admin only.
  app.use('/api/admin/web', requireAuth(gate), requireAdmin, require('./web_admin').webAdminApi({ repo, config }));
  // 3.56 access mode: /api/me/capabilities (rider), /api/public/access (website), /api/admin/access-mode (admin).
  require('./access_mode').attachAccessModeRoutes({ app, accessMode, repo, gate });
  // 3.56 notifications (src/notifications.js): admin push campaigns, purchase / refund e-mails, server SOS SMS
  // (emergencyGateway.sosSms) and the editable message templates. Jobs start with retention.start().
  const notifications = require('./notifications').attachNotifications({ app, repo, soda, gate, push, emergencyGateway, lease, config, logger,
    accessMode, ...(mailTransport !== undefined ? { mailTransport } : {}), ...(smsProviders ? { smsProviders } : {}), ...(smsFetch ? { smsFetch } : {}), ...(pushImageStore ? { imageStore: pushImageStore } : {}) });
  // 3.57 ride summary e-mail: TimelineEngine.finishTrip -> convoys.tripMemory.onTripFinished (never awaited).
  convoys.tripMemory = notifications.lifecycle;
  if (guardianPush) guardianPush.texts = notifications.guardianArrivalText;
  // 3.55b website all-time totals: one shared aggregate, refreshed by one node under the lease (src/public_stats.js).
  const publicStats = new (require('./public_stats').PublicStatsStore)({ repo, logger });
  app.use('/api', require('./leaderboard').riderScoreRouter({ riderScore, leaderboard, gate, flagsOf: () => featureFlags }));
  // 3.55 usernames, friends, profile pictures: auth hooks, username backfill, erase cleanup, /join/friend/:code page.
  require('./social_routes').attachSocial({ app, repo, auth, hub, lease, featureFlags, logger, site, pageVars });
  // 3.57 welcome e-mail: once per new account (password or Google), after the username exists. Queued in the
  // background (src/lifecycle_emails.js); never delays or fails the registration.
  const socialReady = auth.onUserReady;
  auth.onUserReady = async (user, ctx = {}) => {
    const u = (socialReady ? await socialReady(user, ctx) : user) || user;
    if (ctx.created) { try { notifications.lifecycle.queueWelcome(u); } catch { /* never in the way */ } }
    return u;
  };
  // 3.55 ratings & reviews engagement (src/engagement.js): app config, in-app feedback, admin templates and stats.
  require('./engagement').attachEngagement({ app, repo, gate, logger });
  // 3.55 diagnostics logs (src/diag_logs.js): rider uploads, admin viewer, erase cascade, leased retention.
  const diagLogs = require('./diag_logs').attachDiagLogs({ repo, hub, featureFlags, lease, logger, ...(diagObjectStore !== undefined ? { objectStore: diagObjectStore } : {}) });
  // 3.57 round 3 web admin Riders (src/admin_riders.js): list, rider page, assign plan / personal coupon / 1:1 e-mail,
  // global search, the e-mail wizard's system templates, and the rider's own coupons for /account.
  const riderAdmin = new (require('./admin_riders').RiderAdmin)({ repo, auth, hub, convoys, studio: notifications.studio, templates: notifications.templates,
    lifecycle: notifications.lifecycle, diagLogs, config });
  riderAdmin.rideLock = rideLock;
  {
    const ra = require('./admin_riders');
    app.use('/api/admin/riders', requireAuth(gate), requireAdmin, ra.adminRidersRouter({ riders: riderAdmin }));
    app.use('/api/admin/search', requireAuth(gate), requireAdmin, ra.adminSearchRouter({ riders: riderAdmin }));
    app.use('/api/admin/email-wizard', requireAuth(gate), requireAdmin, ra.emailWizardRouter({ riders: riderAdmin }));
    app.use('/api/me/coupons', requireAuth(gate), ra.meCouponsRouter({ riders: riderAdmin }));
  }
  // Round 6 business brain (src/business/, docs/intelligence/BUSINESS_ANALYTICS.md): nightly aggregates under the job
  // lease, the web admin "Business" pages and "Servers", the weekly owner summary. MASTER_ADMIN only.
  const business = require('./business').attachBusiness({ app, soda, rawSoda, repo, gate, lease, config, logger, metrics, studio: notifications.studio,
    mailer: notifications.mailer, templates: notifications.templates, node: nodeName, ...(clock ? { clock } : {}) });
  // "Send at each rider's best time" in the e-mail wizard reads the riders' preferred hour from the business brain.
  notifications.studio.sendTimes = business.brain;
  // ---------------------------------------------------------------------------------------------------------
  // ROUND 6 app-agent mounts go here
  // (routes reported by the Flutter / account / avatar / weather / risky-stretch agent are mounted in this block by
  //  the lead; keep them BEFORE the main router below, whose requireAuth catch-all would answer first. Add each new
  //  route to deploy/route_split.md: `node deploy/gen_caddy_routes.js --check` and test/route_split_356.test.js fail
  //  on an unclassified route.)
  // ---------------------------------------------------------------------------------------------------------
  // Round 4 road & safety intelligence: consent, events, hazards, stops, ETAs, crash brain, admin pages' API.
  intel = require('./intel/routes').attachIntel({ app, soda, repo, gate, lease, convoys, mirror, poiCells, logger, jwtSecret: config.jwtSecret, audit, ...(clock ? { clock } : {}) });
  if (migrate) await intel.init().catch((e) => logger.warn(`[intel] collection setup failed: ${e.message}`));
  intel.start();
  // Round 7: road-geometry cells for curve prediction and speed limits on the phone, and "wrong limit" votes
  // (src/road_cells.js, docs/features_355/curve_and_speed_limit.md). Before the main router, like the mounts above.
  const roadCells = require('./road_cells').attachRoadCells({ app, repo, soda, gate, intel, logger, audit, hashKey: intel.key, ...(geoFetch ? { fetchImpl: geoFetch } : {}), ...(clock ? { clock } : {}) });
  if (migrate) await roadCells.init().catch((e) => logger.warn(`[roads] collection setup failed: ${e.message}`));
  // 3.57 sessions & security endpoints (refresh, sign out, sign out everywhere, sessions list, password reset, re-auth,
  // e-mail change, 2-step verification). Before the main router (its requireAuth catch-all would answer first).
  const security = require('./security_routes').attachSecurityRoutes({ app, auth, gate, sessions, rideLock, logger, mailerOf: () => notifications.mailer });
  // ROUND 8 realtime: shard lookup for stage 4 group placement (src/shards.js; SHARDS=1 default = one pair, off).
  app.use('/api', require('./shards').shardRouter({ repo, gate, requireAuth, config }));
  // ---------------------------------------------------------------------------------------------------------
  // ROUND 8 jobs mount block (src/jobs/, docs/features_355/job_queue.md). JOBS_QUEUE=off (default): every producer
  // works inline as before. On: e-mails, push fan-out, road fetches, photo clean-up and the leased batch ticks are
  // enqueued and worked by capacity-aware workers (in this process per WORKER_INPROCESS, or gateway/worker.js).
  // SOS / alert paths are not touched. server.js / worker.js call app.locals.jobs.start() and .stop().
  {
    const J = require('./jobs');
    const jobs = J.attachJobs({ soda: rawSoda, lease, metrics, config, logger, node: nodeName });
    jobs.routeLease(lease, require('./jobs/producers').LEASE_ROUTES);
    require('./jobs/producers').registerProducers({ jobs, notifications, push, security, roadCells, repo, logger });
    app.locals.jobs = jobs;
    app.use('/api/admin/jobs', requireAuth(gate), requireAdmin, J.adminJobsRouter({ jobs,
      audit: typeof repo.addAuditEntry === 'function' ? (e) => repo.addAuditEntry(e).catch(() => {}) : null }));
  }
  // ---------------------------------------------------------------------------------------------------------
  app.use('/api', buildRouter({ auth, convoys, repo, soda, hub, startedAt, tracks, timeline, geo, essentials, poiCells, gate, network, audit, publicLiveLimiter, emergencyGateway, lease, nodeName, publicStats, diagLogs, requireRecentAuth: security.requireRecentAuth, fieldCrypto, rideLock, securityMail: security.mail, intel, roadCells }));
  // 404: JSON for the API, a real page for everything else.
  app.use((req, res) => {
    if (req.path.startsWith('/api/') || req.path === '/api') return res.status(404).json({ error: 'Not found' });
    notFoundPage(req, res);
  });
  // Centralised error handler: graceful responses for malformed JSON, precondition checks, and unexpected errors.
  app.use((err, req, res, next) => {
    if (res.headersSent) return next(err);
    if (err instanceof SyntaxError && err.status === 400 && 'body' in err) {
      return res.status(400).json({ error: 'Invalid JSON payload' });
    }
    if (err.name === 'PreconditionFailedError' || err.status === 412) {
      return res.status(412).end();
    }
    const isApi = req.path.startsWith('/api/') || req.path === '/api';
    const status = (typeof err.status === 'number' && err.status >= 400 && err.status < 600) ? err.status : 500;
    if (status >= 500) {
      // Method, route template (ids and query left out), request id and the error's first line only.
      const route = req.route && req.route.path ? `${req.baseUrl || ''}${req.route.path}` : req.path.replace(/\/[^/]*\d[^/]*/g, '/:id');
      logger.error(`[http] ${req.method} ${route} ${status} req=${req.requestId || '-'}: ${String((err && err.message) || err).split('\n')[0].slice(0, 200)}`);
    }
    if (isApi) {
      return res.status(status).json({ error: status === 500 ? 'Internal server error' : err.message });
    }
    notFoundPage(req, res);
  });

  const retention = new Retention({ repo, soda, convoys, logger });
  // Subscription expiry warnings (7/3/1 days) and rollback to community, hourly; started with retention.
  // `notify`: the neutral plan push ("Your plan ends on 12 Dec.", push.js SOCKET_EVENTS; Play payments policy).
  const subscriptions = new SubscriptionSweeper({ repo, auth, hub, logger, notify: (userId, payload) => (push ? push.onSocketEvent(userId, payload, { delivered: 0 }) : null) });
  auth.onUserSeen = (user) => { try { business.brain.observeOpen(user && user.userId); } catch { /* never in the way */ } return expireIfDue({ repo, auth, hub }, user); };
  // Every scheduled job that writes data or sends messages runs under a lease: exactly once per interval
  // across the nodes sharing this database. server.js calls retention.start() after listen().
  let jobsStarted = false;
  retention.start = () => {
    if (jobsStarted) return;
    jobsStarted = true;
    diagLogs.startJobs();
    const min = 60000;
    lease.run('retention', config.retentionRunEveryMinutes * min, () => retention.runOnce(Date.now(), { autoEnd: false }), { firstDelayMs: min });
    // Ending a stale convoy goes through its room: run it where rooms live.
    lease.run('convoy-auto-end', 60 * min, () => retention.autoEnd(), { prefer: 'live', firstDelayMs: min });
    lease.run('db-keepalive', config.keepAliveEveryMinutes * min, () => retention.keepAlive());
    lease.run('subscriptions', subscriptions.everyMs, () => subscriptions.runOnce(), { firstDelayMs: 90000 });
    lease.run('rider-score-daily', 24 * 60 * min, ({ signal } = {}) => riderScore.recomputeAll({ signal }), { firstDelayMs: 10 * min });
    // 3.57: ended session records are removed 30 days after their last activity.
    lease.run('auth-sessions-sweep', 6 * 60 * min, () => sessions.sweep(), { firstDelayMs: 15 * min });
    // Round 4: sign-ups never verified within REGISTER_PURGE_DAYS (7) are removed.
    lease.run('unverified-accounts-purge', 6 * 60 * min, () => auth.purgeUnverified(), { firstDelayMs: 20 * min });
    // Round 6: documents of the compare-and-replace collections written before this release get their revision
    // token (src/oracle/soda.js casRev), a few hundred per run, on the stored (raw) documents.
    lease.run('cas-rev-seed', 24 * 60 * min, ({ signal } = {}) => require('./oracle/soda').seedMissingRevs(rawSoda, { signal, logger }), { firstDelayMs: 3 * min });
    notifications.startJobs();
    publicStats.start(lease);
    intel.startJobs(lease);
    business.startJobs();
    if (backupModule && typeof backupModule.startBackupJobs === 'function') {
      // Backups copy the stored (encrypted) documents as they are: the raw client, not the decrypting wrapper.
      backupModule.startBackupJobs({ lease, repo, soda: rawSoda, logger });
    }
  };
  subscriptions.start = () => retention.start();

  // v3.56 metrics sources read at scrape time (no work between scrapes).
  metrics.source(() => {
    const out = [
      { name: 'coroute_ws_connections', help: 'Open WebSockets.', values: [[null, hub.wss.clients.size]] },
      { name: 'coroute_ws_rooms', help: 'Convoy rooms with a socket on this node.', values: [[null, hub.rooms.size]] },
      { name: 'coroute_convoy_rooms_loaded', help: 'Convoy rooms in memory.', values: [[null, convoys.rooms.size]] },
      { name: 'coroute_ws_events_total', help: 'WebSocket hub counters (positions in/out, coalesced, dropped, batched frames, slow links, connections).', type: 'counter',
        values: Object.entries(hub.stats).map(([k, v]) => [{ kind: k }, v]) },
      { name: 'coroute_cache_db_reads_total', help: 'Database reads by the account and session caches.', type: 'counter',
        values: [[{ cache: 'user_gate' }, gate.reads || 0], [{ cache: 'sessions' }, sessions.reads || 0]] },
      { name: 'coroute_load_shedding', help: '1 while non-essential requests are being shed.', values: [[{ mode: shedder.mode }, shedder.mode === 'off' ? 0 : (shedder.shedding() ? 1 : 0)]] },
      { name: 'coroute_node_info', help: 'This node (name, role, version); always 1.', values: [[{ node: nodeName, role: config.gatewayRole, version: require('../package.json').version }, 1]] },
      { name: 'coroute_mirror_up', help: 'Mirror link to the peer gateway is up.', values: [[null, mirror.linked() ? 1 : 0]] },
    ];
    if (rawSoda && rawSoda.stats && typeof rawSoda.queueLength === 'function') {
      out.push({ name: 'coroute_db_queue_length', help: 'Database calls waiting for a slot (ORACLE_MAX_INFLIGHT).', values: [[null, rawSoda.queueLength()]] });
      out.push({ name: 'coroute_db_inflight', help: 'Database calls in flight (budgeted collections).', values: [[null, rawSoda.inFlight || 0]] });
      out.push({ name: 'coroute_db_budget_total', help: 'Database budget counters.', type: 'counter', values: Object.entries(rawSoda.stats).map(([k, v]) => [{ kind: k }, v]) });
    }
    return out;
  });

  async function shutdown() {
    // v3.56 zero-downtime drain: 503 on /api/health/live first, keep serving for SHUTDOWN_DRAIN_MS so the load
    // balancer moves new connections, then the usual stop (RECONNECT to every socket, flush, close).
    if (config.shutdownDrainMs > 0) {
      mirror.beginDrain();
      await new Promise((r) => { const t = setTimeout(r, config.shutdownDrainMs); if (t.unref) t.unref(); });
    }
    metrics.stop();
    guardianPush?.stop();
    notifications.stop();
    business.stop();
    featureFlags.stop();
    accessMode.stop();
    const leaseStopped = lease.stopAll({ waitMs: 8000 });
    retention.stop();
    subscriptions.stop();
    timeline.stop();
    network.stop();
    discovery.stop();
    publicRides.stop();
    audit.stop();
    // Final room state to the peer gateway, then RECONNECT {reason:'shutdown'} to every socket (src/mirror.js).
    await mirror.shutdown().catch(() => {});
    hub.close();
    for (const ws of hub.wss.clients) ws.terminate();
    await convoys.flushAll();
    await timeline.idle();
    await audit.flush().catch(() => {});
    await intel.stop().catch(() => {});
    if (typeof tracks.flush === 'function') await tracks.flush().catch(() => {});
    await leaseStopped.catch(() => {});
    await new Promise((resolve) => server.close(resolve));
  }

  return { business, metrics, shedder, intel, roadCells, rideLock, sessions, fieldCrypto, rawSoda, notifications, riderAdmin, diagLogs, push, riderScore, leaderboard, publicStats, featureFlags, accessMode, app, server, hub, mirror, repo, soda, auth, gate, convoys, retention, subscriptions, lease, tracks, timeline, geo, network, discovery, publicRides, audit, routes, emergencyGateway, shutdown };
}

/**
 * The text of /.well-known/security.txt (RFC 9116). Contact: a mailto: of a valid address, else the /security page
 * (which tells reporters to use the in-app feedback). Expires: one year from `now`. Canonical, Policy and
 * Preferred-Languages point at this site.
 */
function securityTxt({ origin, contact, now = Date.now() }) {
  const { safeEmail } = require('./pages');
  const email = safeEmail(contact);
  const expires = new Date(now + 365 * 86400000);
  expires.setUTCMilliseconds(0);
  return [
    `Contact: ${email ? `mailto:${email}` : `${origin}/security`}`,
    `Expires: ${expires.toISOString().replace('.000Z', 'Z')}`,
    `Policy: ${origin}/security`,
    'Preferred-Languages: en',
    `Canonical: ${origin}/.well-known/security.txt`,
    '',
  ].join('\n');
}

/**
 * Built-in fallback for the live link pages when public/live.html / live_expired.html are not deployed
 * (the website pages are the real ones). Plain text, no scripts, no map: the position, the time and "Call 112".
 */
function plainLivePage(v) {
  const head = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
    + '<meta name="robots" content="noindex"><meta name="referrer" content="no-referrer"><title>CoRoute: rider emergency</title>'
    + '<style>body{font-family:system-ui,sans-serif;margin:0;padding:24px;max-width:36rem;line-height:1.5}a.call{display:inline-block;padding:14px 20px;border:2px solid #111;text-decoration:none;color:#111;font-weight:700;margin-top:12px}</style></head><body>';
  if (!v) return `${head}<h1>This link has expired</h1><p>Live emergency links in CoRoute last 30 minutes or until the rider's group closes the alert.</p><p>If someone is in danger, call 112.</p><p><a class="call" href="tel:112">Call 112</a></p></body></html>`;
  const maps = `https://www.google.com/maps/dir/?api=1&amp;destination=${v.__LAT__},${v.__LNG__}`;
  return `${head}<h1>Rider emergency</h1><p>${v.__RIDER__} raised an SOS in CoRoute and shared this link with you.</p>`
    + `<p>Last position: <span data-lat="${v.__LAT__}" data-lng="${v.__LNG__}">${v.__LAT__}, ${v.__LNG__}</span><br>Updated: ${v.__AT__}<br>Link valid until: ${v.__EXPIRES__}</p>`
    + `<p><a class="call" href="tel:112">Call 112</a></p><p><a href="${maps}" rel="noreferrer noopener" target="_blank">Open in Google Maps</a></p>`
    + '<p>What to do: call 112, say the location, stay on the line.</p></body></html>';
}

module.exports = { createApp, createSoda, securityTxt };
