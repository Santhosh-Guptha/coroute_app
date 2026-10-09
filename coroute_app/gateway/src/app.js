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
const { buildRouter } = require('./routes');
const { TrackStore } = require('./tracks');
const { GeoProxy } = require('./geo');
const { TimelineEngine } = require('./timeline');
const { SafetyNetwork } = require('./safety_network');
const { Discovery } = require('./discovery');
const { SafetyAudit } = require('./safety_audit');
const { RouteIndexCache, gridSize } = require('./net_geo');
const { loadSite, isHiddenPath, SITE_PAGES, SITEMAP } = require('./pages');
const rateLimit = require('express-rate-limit');
const { liveTokenOf } = require('./validate');
const { sha256 } = require('./convoys');

function createSoda() {
  if (config.sodaUrl === 'memory' || config.sodaUrl === 'http://mock') return new MemorySoda();
  return new SodaClient({ baseUrl: config.sodaUrl, user: config.oracleUser, password: config.oraclePassword, timeoutMs: config.oracleTimeoutMs });
}

async function createApp({ soda = createSoda(), logger = console, migrate = true, googleVerifier, geoFetch, clock } = {}) {
  const repo = new Repo(soda);
  if (migrate) await repo.migrate();

  const gate = new UserGate(repo);
  const auth = new AuthService(repo, { googleVerifier, gate });
  const convoys = new ConvoyManager(repo, { logger });
  // 3.16: the live link index and the role / live link audit rows go through the same audit as the network.
  const audit = new SafetyAudit({ repo, logger });
  convoys.audit = audit;
  // A phone number, emergency-text opt-out or nearby-assistance switch change reaches the rider's live ride.
  auth.onProfileChanged = (user, keys) => convoys.applyProfile(user.userId, user, keys);
  const tracks = new TrackStore(repo);
  const geo = new GeoProxy({ repo, logger, ...(geoFetch ? { fetchImpl: geoFetch } : {}) });
  convoys.router = (wp) => geo.route(wp);
  convoys.geo = geo; // 3.16: nearest hospital lookups (never awaited by the SOS path)
  const timeline = new TimelineEngine({ convoys, repo, tracks, geo, logger, ...(clock ? { clock } : {}) });
  // 3.15: rider safety network and rider discovery (separate modules; they share only route geometry).
  const routes = new RouteIndexCache({ simplifyM: config.netRouteSimplifyM, maxPoints: config.netRouteMaxPoints, G: gridSize(config.netGridMillideg) });
  const network = new SafetyNetwork({ convoys, geo, audit, logger, routes });
  const discovery = new Discovery({ convoys, network, audit, logger, routes });
  convoys.network = network;
  convoys.on('emergency', (gid, alert, kind, ctx) => network.onEmergency(gid, alert, kind, ctx));
  convoys.on('telemetry', (gid, rider) => network.onTelemetry(gid, rider));
  convoys.on('roomLoaded', (gid) => network.onRoomLoaded(gid));
  convoys.on('roomEnded', (gid, room) => { network.onRoomEnded(gid, room); discovery.onRoomEnded(gid); });

  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1); // behind Caddy/nginx on the VM
  app.use(helmet({ contentSecurityPolicy: false }));
  app.use(cors(config.corsOrigins.length ? { origin: config.corsOrigins } : { origin: false }));
  app.use(express.json({ limit: '2mb' }));

  const server = http.createServer(app);
  const startedAt = Date.now();
  const hub = new Hub({ server, convoys, repo, tracks, timeline, logger, gate, network, discovery });
  network.attach(hub);
  discovery.attach(hub);
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
  app.get('/download', (req, res) => res.redirect(302, config.playStoreUrl || config.apkUrl || `${originOf(req)}${config.apkPath}`));
  app.get('/download/32bit', (req, res) => res.redirect(302, config.apkArm32Url || `${originOf(req)}${config.apkArm32Path}`));
  app.get('/robots.txt', (req, res) => res.type('text/plain').send(`User-agent: *\nAllow: /\nDisallow: /api/\nSitemap: ${originOf(req)}/sitemap.xml\n`));
  app.get('/sitemap.xml', (req, res) => {
    const o = originOf(req);
    const today = new Date().toISOString().slice(0, 10);
    const urls = SITEMAP
      .map(([u, pr]) => `  <url><loc>${o}${u}</loc><lastmod>${today}</lastmod><priority>${pr}</priority></url>`).join('\n');
    res.type('application/xml').send(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`);
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
  app.get('/e/:token', publicLiveLimiter, (req, res) => {
    const token = liveTokenOf(req.params.token);
    if (!token) return notFoundPage(req, res);
    res.set('Cache-Control', 'no-store').set('Referrer-Policy', 'no-referrer').set('X-Robots-Tag', 'noindex');
    const view = convoys.liveView(sha256(token));
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
  // Partials, templates (_*.html) and raw page sources are never served directly: every page has a route above.
  app.use((req, res, next) => (!req.path.startsWith('/api/') && isHiddenPath(req.path) ? notFoundPage(req, res) : next()));
  app.use(express.static(pub(''), {
    index: false, maxAge: '7d', extensions: false,
    setHeaders: (res, p) => {
      if (p.endsWith('.html')) res.setHeader('Cache-Control', 'no-store');
      // The APK keeps its name across releases: always check for a newer one.
      if (p.endsWith('.apk')) {
        res.setHeader('Cache-Control', 'no-cache');
        res.setHeader('Content-Type', 'application/vnd.android.package-archive');
      }
    },
  }));
  app.use('/api', buildRouter({ auth, convoys, repo, soda, hub, startedAt, tracks, timeline, geo, gate, network, audit, publicLiveLimiter }));
  // 404: JSON for the API, a real page for everything else.
  app.use((req, res) => {
    if (req.path.startsWith('/api/') || req.path === '/api') return res.status(404).json({ error: 'Not found' });
    notFoundPage(req, res);
  });

  const retention = new Retention({ repo, soda, convoys, logger });

  async function shutdown() {
    retention.stop();
    timeline.stop();
    network.stop();
    discovery.stop();
    audit.stop();
    hub.close();
    for (const ws of hub.wss.clients) ws.terminate();
    await convoys.flushAll();
    await timeline.idle();
    await audit.flush().catch(() => {});
    await new Promise((resolve) => server.close(resolve));
  }

  return { app, server, hub, repo, soda, auth, gate, convoys, retention, tracks, timeline, geo, network, discovery, audit, routes, shutdown };
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
