'use strict';
/**
 * Round 8: the separate background worker process (docs/features_355/job_queue.md, deploy/worker/coroute-worker.service).
 *
 *   node worker.js          (same /opt/coroute/gateway tree, same gateway.env + secrets, plus /etc/coroute/worker.env)
 *
 * It boots the same createApp as the gateway, so every job handler is the very code the gateway would run inline,
 * but it never listens on the gateway port, never takes a job lease (a RegisterOnlyLease only records the leased
 * batch jobs so their handlers exist), never links the live mirror and never holds a rider socket. It pulls jobs from
 * the queue by its own capacity (WORKER_TYPES, WORKER_CONCURRENCY, src/jobs/capacity.js).
 *
 * Health (WORKER_HEALTH_HOST:WORKER_HEALTH_PORT, default 127.0.0.1:8091; keep it private):
 *   GET /health        200 working | 503 draining / stopped
 *   GET /health/queue  queue depth, oldest age, dead letters; 503 above JOBS_ALERT_OLDEST_S / JOBS_ALERT_DEAD (watchdog)
 *   GET /metrics       Prometheus (METRICS_ALLOW / METRICS_TOKEN, like the gateway)
 * SIGTERM: claims nothing more, waits WORKER_DRAIN_MS (25 s) for running jobs, hands the rest back, exits.
 */
const express = require('express');
const config = require('./src/config');
const { createApp } = require('./src/app');
const { RegisterOnlyLease } = require('./src/jobs');

const log = {
  info: (...a) => console.log(new Date().toISOString(), ...a),
  warn: (...a) => console.warn(new Date().toISOString(), ...a),
  error: (...a) => console.error(new Date().toISOString(), ...a),
};

/** appOptions: extra createApp options (tests: soda, mailTransport, pushTransport). */
async function startWorker({ logger = log, env = process.env, listen = true, appOptions = {} } = {}) {
  const lease = new RegisterOnlyLease();
  // No mirror link, no migrations (the gateways own collection setup), no leases.
  const gw = await createApp({ logger, ...appOptions, lease, migrate: false, mirror: { listenHost: '', peerUrl: '' } });
  gw.retention.start(); // registers the leased batch handlers on the RegisterOnlyLease (nothing is scheduled here)
  const jobs = gw.app.locals.jobs;
  jobs.start();
  let draining = false;

  const h = express();
  h.disable('x-powered-by');
  h.get('/health', (req, res) => {
    const st = jobs.worker ? jobs.worker.status() : null;
    res.status(draining || !st || st.stopped ? 503 : 200).set('Cache-Control', 'no-store')
      .json({ status: draining ? 'draining' : 'working', node: config.nodeName, version: require('./package.json').version, worker: st });
  });
  h.get('/health/queue', async (req, res) => {
    try {
      const s = await jobs.summary();
      res.status(s.alert ? 503 : 200).set('Cache-Control', 'no-store').json({ alert: s.alert, alerts: s.alerts, due: s.due, dead: s.dead, oldestDueAgeS: s.oldestDueAgeS, types: s.types, workers: s.workers });
    } catch (e) { res.status(503).json({ alert: true, alerts: ['QUEUE_UNREADABLE'] }); }
  });
  h.get('/metrics', gw.metrics.handler());
  h.use((req, res) => res.status(404).json({ error: 'Not found' }));
  const port = env.WORKER_HEALTH_PORT !== undefined && env.WORKER_HEALTH_PORT !== '' && Number.isFinite(Number(env.WORKER_HEALTH_PORT)) ? Number(env.WORKER_HEALTH_PORT) : 8091;
  const host = String(env.WORKER_HEALTH_HOST || '127.0.0.1');
  const server = listen ? await new Promise((resolve) => { const s = h.listen(port, host, () => resolve(s)); }) : null;
  if (server) logger.info(`[worker] v${require('./package.json').version} on ${config.nodeName}: health http://${host}:${port}/health`);

  async function stop() {
    if (draining) return;
    draining = true;
    const out = await jobs.stop().catch((e) => { logger.error('[worker] drain error', e.message); return null; });
    if (out) logger.info(`[worker] drained: ${out.finished} finished, ${out.released} handed back to the queue`);
    config.shutdownDrainMs = 0; // no load balancer in front of a worker
    await gw.shutdown().catch(() => {});
    if (server) await new Promise((r) => server.close(r));
  }
  return { gw, jobs, server, stop, health: h };
}

if (require.main === module) {
  (async () => {
    try {
      const w = await startWorker();
      const onSig = async (sig) => { log.info(`[worker] ${sig}: draining`); await w.stop(); process.exit(0); };
      process.on('SIGTERM', () => onSig('SIGTERM'));
      process.on('SIGINT', () => onSig('SIGINT'));
      process.on('unhandledRejection', (e) => log.error('[worker] unhandledRejection', e));
    } catch (e) {
      log.error('[worker] fatal startup error:', e.message);
      process.exit(1);
    }
  })();
}

module.exports = { startWorker };
