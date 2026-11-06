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
const { AuthService, UserGate } = require('./auth');
const { ConvoyManager } = require('./convoys');
const { Hub } = require('./ws');
const { Retention } = require('./retention');
const { SubscriptionSweeper, expireIfDue } = require('./subscription_lifecycle');
const { buildRouter } = require('./routes');
const { seedDefaultCoupons } = require('./subscription_routes');
const { TrackStore } = require('./tracks');
const { GeoProxy } = require('./geo');
const { EssentialsService, OverpassPlacesProvider } = require('./essentials');
const { TimelineEngine } = require('./timeline');
const { SafetyNetwork } = require('./safety_network');
const { Discovery } = require('./discovery');
const { SafetyAudit } = require('./safety_audit');
const { RouteIndexCache, gridSize } = require('./net_geo');
const { loadSite, isHiddenPath, SITE_PAGES, SITEMAP } = require('./pages');
const rateLimit = require('express-rate-limit');
const { liveTokenOf } = require('./validate');
const { communityStories } = require('./trip_reviews');
const { sha256 } = require('./convoys');
const { GuardianService } = require('./guardians');
const { GuardianPush } = require('./guardian_push');
const { guardianRouter } = require('./guardian_routes');
const { EmergencySmsGateway } = require('./emergency_sms_gateway');
const { JobLease } = require('./job_lease');
const { Mirror } = require('./mirror');
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

async function createApp({ soda = createSoda(), logger = console, migrate = true, googleVerifier, geoFetch, clock, emergencyFetch, lease, mirror: mirrorOpts } = {}) {
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

  const gate = new UserGate(repo);
  const auth = new AuthService(repo, { googleVerifier, gate });
  const convoys = new ConvoyManager(repo, { logger });
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
  convoys.router = (wp) => geo.route(wp);
  convoys.geo = geo; // 3.16: nearest hospital lookups (never awaited by the SOS path)
  const timeline = new TimelineEngine({ convoys, repo, tracks, geo, logger, ...(clock ? { clock } : {}) });
  // 3.15: rider safety network and rider discovery (separate modules; they share only route geometry).
  const routes = new RouteIndexCache({ simplifyM: config.netRouteSimplifyM, maxPoints: config.netRouteMaxPoints, G: gridSize(config.netGridMillideg) });
  const network = new SafetyNetwork({ convoys, geo, audit, logger, routes, emergencyGateway });
  const discovery = new Discovery({ convoys, network, audit, logger, routes });
  convoys.network = network;
  convoys.on('emergency', (gid, alert, kind, ctx) => network.onEmergency(gid, alert, kind, ctx));
  convoys.on('telemetry', (gid, rider) => network.onTelemetry(gid, rider));
  convoys.on('roomLoaded', (gid) => network.onRoomLoaded(gid));
  convoys.on('roomEnded', (gid, room) => { network.onRoomEnded(gid, room); discovery.onRoomEnded(gid); });

  const app = express();
  app.disable('x-powered-by');
  // Only these proxies' X-Forwarded-For is believed (TRUST_PROXY; default loopback = this VM's Caddy).
  // VM2 also trusts VM1's private IP, so req.ip (and every IP rate limit) is the real client.
  app.set('trust proxy', config.trustProxy);
  // Two-VM deployment: which node answered (for checking the Caddy route split). Not sent on a single VM.
  if (config.gatewayRole !== 'all') app.use((req, res, next) => { res.set('X-CoRoute-Node', `${nodeName}/${config.gatewayRole}`); next(); });
  app.use(helmet({
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'", "'unsafe-inline'", "https://checkout.razorpay.com", "https://cdn.razorpay.com"],
        styleSrc: ["'self'", "'unsafe-inline'"],
        imgSrc: ["'self'", "data:", "https:"],
        connectSrc: ["'self'", "https://api.razorpay.com", "https://lumberjack.razorpay.com", "https://*.razorpay.com"],
        fontSrc: ["'self'"],
        frameSrc: ["'self'", "https://api.razorpay.com", "https://checkout.razorpay.com"],
        objectSrc: ["'none'"],
        frameAncestors: ["'none'"],
        baseUri: ["'self'"],
        formAction: ["'self'", "https://api.razorpay.com"],
      },
    },
    frameguard: { action: 'deny' },
    xContentTypeOptions: true,
  }));
  app.use((req, res, next) => {
    res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(self "https://checkout.razorpay.com" "https://api.razorpay.com")');
    next();
  });
  app.use(cors(config.corsOrigins.length ? { origin: config.corsOrigins } : { origin: false }));
  // The Razorpay webhook is signed over the exact bytes it sends: keep them raw, and small (1 MB).
  app.use('/api/subscription/webhook', express.raw({ type: () => true, limit: '1mb' }));
  app.use('/api/membership/webhook', express.raw({ type: () => true, limit: '1mb' }));
  app.use(express.json({ limit: '2mb' }));

  const server = http.createServer(app);
  const startedAt = Date.now();
  const hub = new Hub({ server, convoys, repo, tracks, timeline, logger, gate, network, discovery, emergencyGateway });
  network.attach(hub);
  discovery.attach(hub);
  // Two-node live mirror (src/mirror.js): off unless MIRROR_LISTEN_HOST / MIRROR_PEER_URL are set (opts: tests).
  const mirror = new Mirror({ convoys, logger, node: nodeName, ...(mirrorOpts || {}) });
  mirror.attach(hub);
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
    app.use('/api/guardian', guardianRouter({ service, gate, origin: origin.origin, push: guardianPush }));
  }
  // ---- Public website, served from here so no extra hosting is needed ----
  const path = require('path');
  const pub = (f) => path.join(__dirname, '..', 'public', f);
  const originOf = (req) => config.publicOrigin || `${req.protocol}://${req.get('host')}`;
  // Pages are assembled once at startup (shared header/footer partials, asset version); per request only
  // __ORIGIN__ (canonical, og:image, sitemap work for any domain) and __MAX_RIDERS__ are filled in.
  const site = loadSite(pub(''));
  const pageVars = (req) => ({ __ORIGIN__: originOf(req), __MAX_RIDERS__: String(config.maxConvoyRiders) });
  const sendPage = (res, html) => res.type('html').set('Cache-Control', 'public, max-age=300').send(html);
  const notFoundPage = (req, res) => res.status(404).type('html').set('Cache-Control', 'no-store').send(site.render('404.html', pageVars(req)));

  for (const [route, file] of Object.entries(SITE_PAGES)) {
    const paths = route === '/' ? ['/', '/index.html'] : [route, `${route}.html`];
    app.get(paths, (req, res) => sendPage(res, site.render(file, pageVars(req))));
  }
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
    const target = config.appStoreUrl || config.iosTestFlightUrl || config.iosIpaUrl || `${originOf(req)}/get#ios`;
    res.redirect(302, target);
  });
  app.get('/robots.txt', (req, res) => res.type('text/plain').send(`User-agent: *\nAllow: /\nDisallow: /api/\nSitemap: ${originOf(req)}/sitemap.xml\n`));
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
  // Partials, templates (_*.html) and raw page sources are never served directly: every page has a route above.
  app.use((req, res, next) => (!req.path.startsWith('/api/') && isHiddenPath(req.path) ? notFoundPage(req, res) : next()));
  app.use(express.static(pub(''), {
    index: false, maxAge: '7d', extensions: false,
    setHeaders: (res, p) => {
      if (p.endsWith('.html')) res.setHeader('Cache-Control', 'no-store');
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
  app.use('/api', buildRouter({ auth, convoys, repo, soda, hub, startedAt, tracks, timeline, geo, essentials, gate, network, audit, publicLiveLimiter, emergencyGateway, lease, nodeName }));
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
    if (isApi) {
      return res.status(status).json({ error: status === 500 ? 'Internal server error' : err.message });
    }
    notFoundPage(req, res);
  });

  const retention = new Retention({ repo, soda, convoys, logger });
  // Subscription expiry warnings (7/3/1 days) and rollback to community, hourly; started with retention.
  const subscriptions = new SubscriptionSweeper({ repo, auth, hub, logger });
  auth.onUserSeen = (user) => expireIfDue({ repo, auth, hub }, user);
  // Every scheduled job that writes data or sends messages runs under a lease: exactly once per interval
  // across the nodes sharing this database. server.js calls retention.start() after listen().
  let jobsStarted = false;
  retention.start = () => {
    if (jobsStarted) return;
    jobsStarted = true;
    const min = 60000;
    lease.run('retention', config.retentionRunEveryMinutes * min, () => retention.runOnce(Date.now(), { autoEnd: false }), { firstDelayMs: min });
    // Ending a stale convoy goes through its room: run it where rooms live.
    lease.run('convoy-auto-end', 60 * min, () => retention.autoEnd(), { prefer: 'live', firstDelayMs: min });
    lease.run('db-keepalive', config.keepAliveEveryMinutes * min, () => retention.keepAlive());
    lease.run('subscriptions', subscriptions.everyMs, () => subscriptions.runOnce(), { firstDelayMs: 90000 });
    if (backupModule && typeof backupModule.startBackupJobs === 'function') {
      backupModule.startBackupJobs({ lease, repo, soda, logger });
    }
  };
  subscriptions.start = () => retention.start();

  async function shutdown() {
    guardianPush?.stop();
    const leaseStopped = lease.stopAll({ waitMs: 8000 });
    retention.stop();
    subscriptions.stop();
    timeline.stop();
    network.stop();
    discovery.stop();
    audit.stop();
    // Final room state to the peer gateway, then RECONNECT {reason:'shutdown'} to every socket (src/mirror.js).
    await mirror.shutdown().catch(() => {});
    hub.close();
    for (const ws of hub.wss.clients) ws.terminate();
    await convoys.flushAll();
    await timeline.idle();
    await audit.flush().catch(() => {});
    await leaseStopped.catch(() => {});
    await new Promise((resolve) => server.close(resolve));
  }

  return { app, server, hub, mirror, repo, soda, auth, gate, convoys, retention, subscriptions, lease, tracks, timeline, geo, network, discovery, audit, routes, emergencyGateway, shutdown };
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

module.exports = { createApp, createSoda };
