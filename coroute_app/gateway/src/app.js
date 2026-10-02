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

function createSoda() {
  if (config.sodaUrl === 'memory' || config.sodaUrl === 'http://mock') return new MemorySoda();
  return new SodaClient({ baseUrl: config.sodaUrl, user: config.oracleUser, password: config.oraclePassword, timeoutMs: config.oracleTimeoutMs });
}

async function createApp({ soda = createSoda(), logger = console, migrate = true, googleVerifier } = {}) {
  const repo = new Repo(soda);
  if (migrate) await repo.migrate();

  const auth = new AuthService(repo, { googleVerifier });
  const convoys = new ConvoyManager(repo, { logger });

  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1); // behind Caddy/nginx on the VM
  app.use(helmet({ contentSecurityPolicy: false }));
  app.use(cors(config.corsOrigins.length ? { origin: config.corsOrigins } : { origin: false }));
  app.use(express.json({ limit: '2mb' }));

  const server = http.createServer(app);
  const startedAt = Date.now();
  const hub = new Hub({ server, convoys, repo, logger });
  app.get('/', (req, res) => res.json({ service: 'CoRoute Gateway', version: require('../package.json').version, status: 'ONLINE', privacy: '/privacy' }));
  // Public privacy policy (required by the Play Store) — served from here so no extra hosting is needed.
  app.get(['/privacy', '/privacy.html'], (req, res) => res.sendFile(require('path').join(__dirname, '..', 'public', 'privacy.html')));
  app.use('/api', buildRouter({ auth, convoys, repo, soda, hub, startedAt }));
  app.use((req, res) => res.status(404).json({ error: 'Not found' }));

  const retention = new Retention({ repo, soda, convoys, logger });

  async function shutdown() {
    retention.stop();
    hub.close();
    for (const ws of hub.wss.clients) ws.terminate();
    await convoys.flushAll();
    await new Promise((resolve) => server.close(resolve));
  }

  return { app, server, hub, repo, soda, auth, convoys, retention, shutdown };
}

module.exports = { createApp, createSoda };
