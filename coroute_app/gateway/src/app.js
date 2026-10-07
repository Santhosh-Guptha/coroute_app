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
const { AuthService } = require('./auth');
const { ConvoyManager } = require('./convoys');
const { Hub } = require('./ws');
const { Retention } = require('./retention');
const { buildRouter } = require('./routes');
const { TrackStore } = require('./tracks');
const { GeoProxy } = require('./geo');
const { TimelineEngine } = require('./timeline');

function createSoda() {
  if (config.sodaUrl === 'memory' || config.sodaUrl === 'http://mock') return new MemorySoda();
  return new SodaClient({ baseUrl: config.sodaUrl, user: config.oracleUser, password: config.oraclePassword, timeoutMs: config.oracleTimeoutMs });
}

async function createApp({ soda = createSoda(), logger = console, migrate = true, googleVerifier, geoFetch, clock } = {}) {
  const repo = new Repo(soda);
  if (migrate) await repo.migrate();

  const auth = new AuthService(repo, { googleVerifier });
  const convoys = new ConvoyManager(repo, { logger });
  const tracks = new TrackStore(repo);
  const geo = new GeoProxy({ repo, logger, ...(geoFetch ? { fetchImpl: geoFetch } : {}) });
  convoys.router = (wp) => geo.route(wp);
  const timeline = new TimelineEngine({ convoys, repo, tracks, geo, logger, ...(clock ? { clock } : {}) });

  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1); // behind Caddy/nginx on the VM
  app.use(helmet({ contentSecurityPolicy: false }));
  app.use(cors(config.corsOrigins.length ? { origin: config.corsOrigins } : { origin: false }));
  app.use(express.json({ limit: '2mb' }));

  const server = http.createServer(app);
  const startedAt = Date.now();
  const hub = new Hub({ server, convoys, repo, tracks, timeline, logger });
  // ---- Public website, served from here so no extra hosting is needed ----
  const path = require('path');
  const fs = require('fs');
  const pub = (f) => path.join(__dirname, '..', 'public', f);
  const originOf = (req) => config.publicOrigin || `${req.protocol}://${req.get('host')}`;
  // index.html carries __ORIGIN__ placeholders so canonical/og:image/sitemap are right for any domain.
  const indexTemplate = fs.readFileSync(pub('index.html'), 'utf8');
  const sendPage = (res, html) => res.type('html').set('Cache-Control', 'public, max-age=300').send(html);

  app.get(['/', '/index.html'], (req, res) => sendPage(res, indexTemplate.replaceAll('__ORIGIN__', originOf(req))));
  app.get(['/privacy', '/privacy.html'], (req, res) => res.sendFile(pub('privacy.html')));
  app.get(['/terms', '/terms.html'], (req, res) => res.sendFile(pub('terms.html')));
  app.get(['/docs', '/docs.html', '/architecture'], (req, res) => res.sendFile(pub('docs.html')));
  // One download link that never breaks: Play Store when configured, otherwise the latest GitHub release.
  app.get('/download', (req, res) => res.redirect(302, config.playStoreUrl || config.apkUrl));
  app.get('/robots.txt', (req, res) => res.type('text/plain').send(`User-agent: *\nAllow: /\nDisallow: /api/\nSitemap: ${originOf(req)}/sitemap.xml\n`));
  app.get('/sitemap.xml', (req, res) => {
    const o = originOf(req);
    const today = new Date().toISOString().slice(0, 10);
    const urls = [['/', '1.0'], ['/docs', '0.8'], ['/privacy', '0.3'], ['/terms', '0.3']]
      .map(([u, pr]) => `  <url><loc>${o}${u}</loc><lastmod>${today}</lastmod><priority>${pr}</priority></url>`).join('\n');
    res.type('application/xml').send(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`);
  });
  // Join link shared from the app: opens the app via its custom scheme, with the download as fallback.
  app.get('/join/:code', (req, res) => {
    const code = String(req.params.code || '').toUpperCase();
    if (!/^[A-Z0-9]{4,10}$/.test(code)) return res.redirect(302, '/');
    const html = fs.readFileSync(pub('join.html'), 'utf8').replaceAll('__CODE__', code).replaceAll('__ORIGIN__', originOf(req));
    res.type('html').set('Cache-Control', 'no-store').send(html);
  });
  // Android App Links verification (express.static ignores dot-directories, so serve it explicitly).
  app.get('/.well-known/assetlinks.json', (req, res) => res.type('application/json').set('Cache-Control', 'public, max-age=86400').sendFile(pub('.well-known/assetlinks.json')));
  app.get('/status', (req, res) => res.json({ service: 'CoRoute Gateway', version: require('../package.json').version, status: 'ONLINE' }));
  app.use(express.static(pub(''), { index: false, maxAge: '7d', extensions: false, setHeaders: (res, p) => { if (p.endsWith('.html')) res.setHeader('Cache-Control', 'no-store'); } }));
  app.use('/api', buildRouter({ auth, convoys, repo, soda, hub, startedAt, tracks, timeline, geo }));
  // 404: JSON for the API, a real page for everything else.
  app.use((req, res) => {
    if (req.path.startsWith('/api/') || req.path === '/api') return res.status(404).json({ error: 'Not found' });
    res.status(404).type('html').send(fs.readFileSync(pub('404.html'), 'utf8'));
  });

  const retention = new Retention({ repo, soda, convoys, logger });

  async function shutdown() {
    retention.stop();
    timeline.stop();
    hub.close();
    for (const ws of hub.wss.clients) ws.terminate();
    await convoys.flushAll();
    await timeline.idle();
    await new Promise((resolve) => server.close(resolve));
  }

  return { app, server, hub, repo, soda, auth, convoys, retention, tracks, timeline, geo, shutdown };
}

module.exports = { createApp, createSoda };
