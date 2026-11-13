'use strict';
/**
 * Round 8 background jobs: one object per process that ties the durable queue (queue.js), the capacity-aware worker
 * (worker.js) and the producers (producers.js) together. Docs: docs/features_355/job_queue.md,
 * docs/quality/ROUND8_JOBS_NOTES.md.
 *
 *   const jobs = attachJobs({ soda: rawSoda, lease, metrics, config, logger });
 *   jobs.register('email.receipt', async (payload, { job, signal }) => ..., { leaseMs, timeoutMs, maxAttempts });
 *   jobs.enabled                     JOBS_QUEUE=on (or a separate worker process)
 *   jobs.enqueue(type, payload, opts)            durable; wakes the local worker
 *   jobs.dispatch(type, payload, opts, inlineFn) queue when enabled, else inlineFn() (today's behaviour)
 *   jobs.urgent(type, payload, opts, inlineFn)   security codes: priority 0, sealed, inline if no worker took it
 *                                                within JOBS_SECURITY_FALLBACK_MS (10 s)
 *   jobs.routeLease(lease, map)      leased ticks keep their lease for scheduling and enqueue their work
 *   jobs.start() / jobs.stop({ drainMs })
 *
 * Where the work runs (env):
 *   JOBS_QUEUE=off (default)  nothing changes: every producer works inline, exactly as before round 8.
 *   JOBS_QUEUE=on             producers enqueue. WORKER_INPROCESS=auto|on|off decides whether THIS gateway also
 *                             works jobs: auto/on on GATEWAY_ROLE all|web; on GATEWAY_ROLE=live only while no other
 *                             worker (separate, or a web node's) has sent a heartbeat in the last 45 s, and never when
 *                             JOBS_SEPARATE_WORKER=on (a live node then does live work only).
 *   gateway/worker.js         a separate worker process (deploy/worker/coroute-worker.service): always works jobs.
 * SOS / alert delivery never goes through this module (sockets, SOS SMS and their lease jobs are untouched).
 */
const os = require('os');
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { JobQueue } = require('./queue');
const { JobWorker } = require('./worker');
const { CapacityMonitor } = require('./capacity');
const { inJob } = require('./context');

const WORKERS = 'job_workers';
const HEARTBEAT_MS = 15000;
const HEARTBEAT_FRESH_MS = 45000;
const MAX_PENDING_FALLBACKS = 2000;
const DEFAULT_CONCURRENCY = Object.freeze({ email: 4, push: 4, roads: 1, photo: 2, batch: 1 });

function onOff(v, def) {
  const s = String(v ?? '').trim().toLowerCase();
  if (!s) return def;
  return ['on', 'true', '1', 'yes'].includes(s);
}
const posNum = (v, d) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : d; };

/** "email:4,push:2" -> { email: 4, push: 2 } (unknown text ignored). */
function parseConcurrency(s) {
  const out = {};
  for (const part of String(s || '').split(',')) {
    const m = /^\s*([a-z][a-z0-9_]{1,15})\s*:\s*(\d{1,3})\s*$/.exec(part);
    if (m) out[m[1]] = Math.min(64, Number(m[2]));
  }
  return out;
}

/** Every setting this module reads (documented in deploy/.env.example). */
function jobsConfig(env = process.env) {
  const types = String(env.WORKER_TYPES || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  const inproc = String(env.WORKER_INPROCESS || 'auto').trim().toLowerCase();
  return {
    queue: onOff(env.JOBS_QUEUE, false),
    inprocess: ['on', 'off', 'auto'].includes(inproc) ? inproc : 'auto',
    separateWorker: onOff(env.JOBS_SEPARATE_WORKER, false),
    families: types.length && !types.includes('all') ? types : null,
    concurrency: { ...DEFAULT_CONCURRENCY, ...parseConcurrency(env.WORKER_CONCURRENCY) },
    maxConcurrency: posNum(env.WORKER_MAX_CONCURRENCY, 16),
    share: Math.min(1, posNum(env.WORKER_INPROCESS_SHARE, 0.5)),
    pollMinMs: posNum(env.JOBS_POLL_MIN_MS, 250),
    pollMaxMs: posNum(env.JOBS_POLL_MAX_MS, 5000),
    claimBatch: posNum(env.JOBS_CLAIM_BATCH, 4),
    maxPayloadBytes: posNum(env.JOBS_MAX_PAYLOAD_BYTES, 8192),
    doneTtlMs: posNum(env.JOBS_DONE_TTL_HOURS, 24) * 3600000,
    deadTtlMs: posNum(env.JOBS_DEAD_TTL_DAYS, 14) * 86400000,
    securityFallbackMs: posNum(env.JOBS_SECURITY_FALLBACK_MS, 10000),
    drainMs: posNum(env.WORKER_DRAIN_MS, 25000),
    alertOldestS: posNum(env.JOBS_ALERT_OLDEST_S, 300),
    alertDead: posNum(env.JOBS_ALERT_DEAD, 20),
  };
}

/** Lease stand-in for the separate worker process: records what the gateway would schedule, never runs it. */
class RegisterOnlyLease {
  constructor() { this.registerOnly = true; this.names = []; this.role = 'standby'; }
  run(name) { this.names.push(name); return { stop() {} }; }
  async once() { return false; }
  async stopAll() {}
  async idle() {}
  poll() { return Promise.resolve(); }
  status() { return {}; }
}

class Jobs {
  /**
   * @param {object} o
   * @param {object} o.soda          raw SODA client (job rows hold no protected fields; sealed payloads are encrypted here)
   * @param {object} [o.lease]       JobLease (cleanup job) or RegisterOnlyLease (separate worker process)
   * @param {object} [o.metrics]     Metrics (source() + loop)
   * @param {'gateway'|'separate'} [o.mode]
   * @param {object} [o.options]     overrides of jobsConfig() (tests)
   */
  constructor({ soda, lease = null, metrics = null, config = {}, logger = console, node = os.hostname(), role, mode, env = process.env,
    options = {}, clock = Date.now, capacity = null, queue = null } = {}) {
    this.soda = soda; this.lease = lease; this.metrics = metrics; this.log = logger; this.node = node; this.clock = clock;
    this.role = role || config.gatewayRole || 'all';
    this.mode = mode || (lease && lease.registerOnly ? 'separate' : 'gateway');
    this.cfg = { ...jobsConfig(env), ...options };
    this.enabled = this.mode === 'separate' ? true : !!this.cfg.queue;
    this.queue = queue || new JobQueue({ soda, logger, clock, maxPayloadBytes: this.cfg.maxPayloadBytes, doneTtlMs: this.cfg.doneTtlMs,
      deadTtlMs: this.cfg.deadTtlMs, jwtSecret: config.jwtSecret, env });
    this.registry = new Map();
    this.capacity = capacity;
    this.worker = null;
    this.workerPlan = 'off';
    this.timers = [];
    this.started = false;
    this.stopped = false;
    this.pendingFallbacks = 0;
    this.counters = { enqueued: 0, enqueueFailed: 0, inline: 0, fallbackInline: 0, fallbackTakenByWorker: 0 };
    this.byType = new Map(); // type -> enqueued (types from the registry: bounded)
    this.workerId = `${node}:${process.pid}:${crypto.randomBytes(3).toString('hex')}`;
    this.lastPeerCheck = null;
    if (metrics && typeof metrics.source === 'function') metrics.source(() => this.metricsRows());
  }

  /** Registers a handler. opts: { leaseMs, timeoutMs, maxAttempts, backoffBaseMs, priority (default for enqueue) }. */
  register(type, handler, opts = {}) {
    if (typeof handler !== 'function') throw new Error(`[jobs] handler for ${type} must be a function`);
    if (this.registry.has(type)) throw new Error(`[jobs] ${type} already registered`);
    const family = type.split('.')[0];
    this.registry.set(type, { type, family, handler, leaseMs: opts.leaseMs || 60000, timeoutMs: opts.timeoutMs || 0, maxAttempts: opts.maxAttempts || 5,
      backoffBaseMs: opts.backoffBaseMs || 5000, priority: opts.priority ?? 5 });
    return this;
  }

  _defaults(type, opts) {
    const def = this.registry.get(type) || {};
    return { priority: def.priority ?? 5, maxAttempts: def.maxAttempts, leaseMs: def.leaseMs, ...opts };
  }

  /** Durable enqueue (see JobQueue.enqueue). Wakes this node's worker when it serves the type. */
  async enqueue(type, payload, opts = {}) {
    try {
      const out = await this.queue.enqueue(type, payload, this._defaults(type, opts));
      this.counters.enqueued++;
      if (this.registry.has(type)) this.byType.set(type, (this.byType.get(type) || 0) + 1);
      if (this.worker && this.worker.servesType(type)) {
        const due = !(opts.delayMs > 0) && !(Number.isFinite(opts.runAt) && opts.runAt > this.clock());
        if (due) this.worker.wake();
      }
      return out;
    } catch (e) { this.counters.enqueueFailed++; throw e; }
  }

  /** Queue when enabled (and not already inside a job), else run inlineFn now. An enqueue that fails runs inline. */
  async dispatch(type, payload, opts, inlineFn) {
    if (!this.enabled || inJob()) { this.counters.inline++; return inlineFn(); }
    try { return { queued: true, ...(await this.enqueue(type, payload, opts)) }; } catch (e) {
      this.log.warn?.(`[jobs] enqueue ${type} failed (${String(e.code || e.message).slice(0, 80)}): running it inline`);
      this.counters.inline++;
      return inlineFn();
    }
  }

  /**
   * Time-critical work (security codes): highest priority, sealed payload, removed when done. If no worker has
   * claimed it within securityFallbackMs, this node takes it back (one compare-and-replace, so a worker that claims it
   * at the same moment and this node never both send) and runs inlineFn. A stopped worker can never block sign-in.
   * The enqueue itself failing or hanging also runs inlineFn.
   */
  async urgent(type, payload, opts, inlineFn) {
    if (!this.enabled || inJob()) { this.counters.inline++; return inlineFn(); }
    if (this.pendingFallbacks >= MAX_PENDING_FALLBACKS) { this.counters.fallbackInline++; return inlineFn(); }
    const waitAll = this.cfg.securityFallbackMs;
    const deadline = this.clock() + waitAll;
    this.pendingFallbacks++;
    // Not unref'd: a pending security code keeps the process alive until it is sent (bounded by securityFallbackMs).
    const sleep = (ms) => new Promise((r) => { setTimeout(r, Math.max(0, ms)); });
    try {
      const enq = this.enqueue(type, payload, { ...opts, priority: 0, sealed: true, deleteOnDone: true });
      let timedOut = false;
      let job = null;
      try {
        job = await Promise.race([enq, sleep(waitAll).then(() => { timedOut = true; return null; })]);
      } catch (e) {
        this.log.warn?.(`[jobs] ${type}: queue unavailable (${String(e.code || e.message).slice(0, 60)}), sending inline`);
        this.counters.fallbackInline++;
        return inlineFn();
      }
      if (timedOut || !job) {
        // The database is too slow to even take the job: send now, and cancel the job if it lands later.
        enq.then((late) => late && this.queue.takeOver(late.k, `${this.workerId}:cancel`).then((j) => j && this.queue.complete(j))).catch(() => {});
        this.counters.fallbackInline++;
        return inlineFn();
      }
      await sleep(deadline - this.clock());
      const taken = await this.queue.takeOver(job.k, `${this.workerId}:fallback`).catch(() => null);
      if (!taken) { this.counters.fallbackTakenByWorker++; return { queued: true, jobId: job.jobId }; }
      this.counters.fallbackInline++;
      this.log.warn?.(`[jobs] ${type}: no worker took it within ${waitAll} ms, sent inline`);
      let r;
      try { r = await inlineFn(); } finally { await this.queue.complete(taken).catch(() => {}); }
      return { ...(r && typeof r === 'object' ? r : {}), fallback: true };
    } finally { this.pendingFallbacks--; }
  }

  /**
   * Leased batch ticks: `map` = { leaseName: { type, leaseMs?, timeoutMs?, priority?, maxAttempts? } }. For those names
   * the lease still decides WHEN (exactly once across nodes), and its body becomes one enqueue of `type` with the key
   * `lease:<name>` (rearmed when the last run finished; skipped while one is still queued or running). The original
   * body is registered as the handler, so a worker runs exactly the same code. Other names pass through untouched.
   */
  routeLease(lease, map) {
    if (!lease || typeof lease.run !== 'function' || lease.__jobsRouted) return lease;
    lease.__jobsRouted = true;
    const orig = lease.run.bind(lease);
    lease.run = (name, intervalMs, fn, opts) => {
      const route = map[name];
      if (!route || typeof fn !== 'function') return orig(name, intervalMs, fn, opts);
      if (!this.registry.has(route.type)) {
        this.register(route.type, (payload, { signal }) => fn({ signal, name }), {
          leaseMs: route.leaseMs || 5 * 60000, timeoutMs: route.timeoutMs || 0, maxAttempts: route.maxAttempts || 3, priority: route.priority ?? 6, backoffBaseMs: 30000 });
      }
      const body = (ctx) => {
        if (!this.enabled) return fn(ctx);
        return this.enqueue(route.type, {}, { key: `lease:${name}`, rearm: true }).catch((e) => {
          this.log.warn?.(`[jobs] ${name}: enqueue failed (${String(e.code || e.message).slice(0, 60)}), running inline`);
          return fn(ctx);
        });
      };
      return orig(name, intervalMs, body, opts);
    };
    return lease;
  }

  /** What this process decides about working jobs itself. */
  plan() {
    if (!this.enabled) return 'off';
    if (this.mode === 'separate') return 'run';
    if (this.cfg.inprocess === 'off' || this.role === 'standby') return 'off';
    if (this.role === 'live') return this.cfg.separateWorker ? 'off' : 'yield';
    return 'run';
  }

  /** Starts the worker (when the plan says so), its heartbeat and the leased cleanup. Idempotent. */
  start() {
    if (this.started || this.stopped) return this;
    this.started = true;
    this.workerPlan = this.plan();
    if (this.workerPlan === 'off') {
      if (this.enabled && this.role === 'live') this.log.info?.('[jobs] live node: background jobs run on other nodes / the worker');
    } else {
      this.capacity = this.capacity || new CapacityMonitor({ loop: this.metrics && this.metrics.loop, soda: this.soda });
      this.worker = new JobWorker({
        queue: this.queue, registry: this.registry, families: this.cfg.families, concurrency: this.cfg.concurrency, maxConcurrency: this.cfg.maxConcurrency,
        share: this.mode === 'separate' ? 1 : this.cfg.share, capacity: this.capacity, logger: this.log, node: this.node,
        mode: this.mode === 'separate' ? 'separate' : 'inprocess', pollMinMs: this.cfg.pollMinMs, pollMaxMs: this.cfg.pollMaxMs, claimBatch: this.cfg.claimBatch,
        clock: this.clock,
      });
      this.worker.start();
      this.log.info?.(`[jobs] worker ${this.worker.mode} on ${this.node} (${this.role}): ${this.worker.families().join(', ') || 'no families'}${this.workerPlan === 'yield' ? ' (yields to any other worker)' : ''}`);
      const hb = setInterval(() => { this._heartbeat().catch(() => {}); }, HEARTBEAT_MS);
      hb.unref?.();
      this.timers.push(hb);
      this._heartbeat().catch(() => {});
    }
    if (this.enabled && this.lease && !this.lease.registerOnly && typeof this.lease.run === 'function') {
      this.lease.run('jobs-cleanup', 60 * 60000, ({ signal } = {}) => this.queue.cleanup({ signal }), { firstDelayMs: 7 * 60000 });
    }
    return this;
  }

  /** Heartbeat row (job_workers) of an active worker; a yielding live node checks for other workers instead. */
  async _heartbeat() {
    if (!this.worker || this.stopped) return;
    await this.soda.ensureCollection(WORKERS);
    const now = this.clock();
    if (this.workerPlan === 'yield') {
      const rows = await this.soda.query(WORKERS, { at: { $gt: now - HEARTBEAT_FRESH_MS }, active: true }, { limit: 20 });
      const other = rows.some((r) => r.value.workerId !== this.workerId && r.value.role !== 'live');
      this.lastPeerCheck = { at: now, otherWorker: other };
      if (other && !this.worker.paused) { this.worker.pause(); this.log.info?.('[jobs] another worker is up: this live node stops working jobs'); }
      if (!other && this.worker.paused) { this.worker.resume(); this.log.info?.('[jobs] no other worker seen: this live node works jobs meanwhile'); }
      if (this.worker.paused) return;
    }
    const st = this.worker.status();
    await this.soda.upsertBy(WORKERS, { workerId: this.workerId }, {
      workerId: this.workerId, node: this.node, role: this.mode === 'separate' ? 'worker' : this.role, mode: st.mode, active: !st.paused,
      families: st.families, running: st.runningTotal, factor: st.capacity.factor, reason: st.capacity.reason, at: now,
    });
  }

  /** Workers seen in the last 45 s (admin). */
  async workers() {
    try {
      await this.soda.ensureCollection(WORKERS);
      const rows = await this.soda.query(WORKERS, { at: { $gt: this.clock() - HEARTBEAT_FRESH_MS } }, { limit: 50 });
      return rows.map((r) => ({ node: r.value.node, role: r.value.role, mode: r.value.mode, active: r.value.active, families: r.value.families,
        running: r.value.running, capacity: r.value.factor, reason: r.value.reason, ageS: Math.round((this.clock() - r.value.at) / 1000) }));
    } catch { return []; }
  }

  /** Queue summary + workers + alert flags (admin API, worker /health/queue, watchdog). */
  async summary() {
    const s = this.enabled ? await this.queue.summary() : { types: {}, open: 0, dead: 0, oldestDueAgeS: 0 };
    const workers = this.enabled ? await this.workers() : [];
    const due = Object.values(s.types).reduce((a, t) => a + t.due, 0);
    const alerts = [];
    if (s.oldestDueAgeS > this.cfg.alertOldestS) alerts.push(`OLDEST_JOB_${s.oldestDueAgeS}S`);
    if (s.dead >= this.cfg.alertDead) alerts.push(`DEAD_LETTERS_${s.dead}`);
    if (due > 0 && !workers.some((w) => w.active)) alerts.push('NO_ACTIVE_WORKER');
    return {
      enabled: this.enabled, mode: this.mode, plan: this.workerPlan, ...s, due, workers,
      thisNode: this.worker ? this.worker.status() : null, counters: { ...this.counters },
      thresholds: { oldestS: this.cfg.alertOldestS, dead: this.cfg.alertDead }, alert: alerts.length > 0, alerts,
    };
  }

  /** Prometheus rows (metrics.source). Label values come from the registry and fixed words only. */
  metricsRows() {
    const out = [
      { name: 'coroute_jobs_enabled', help: '1 when producers enqueue background jobs (JOBS_QUEUE).', values: [[{ mode: this.mode }, this.enabled ? 1 : 0]] },
      { name: 'coroute_jobs_enqueued_total', help: 'Jobs enqueued by this process, by type.', type: 'counter', values: [...this.byType].map(([t, n]) => [{ type: t }, n]) },
      { name: 'coroute_jobs_dispatch_total', help: 'Producer outcomes (enqueued, inline, security fallback).', type: 'counter',
        values: Object.entries(this.counters).map(([k, v]) => [{ kind: k }, v]) },
    ];
    const q = this.queue.stats;
    out.push({ name: 'coroute_jobs_queue_ops_total', help: 'Queue operations of this process.', type: 'counter', values: Object.entries(q).map(([k, v]) => [{ op: k }, v]) });
    if (this.worker) {
      const st = this.worker.status();
      out.push({ name: 'coroute_jobs_running', help: 'Jobs running in this process, by family.', values: st.families.map((f) => [{ family: f }, st.running[f] || 0]) });
      out.push({ name: 'coroute_jobs_capacity_factor', help: 'Capacity factor of this worker (0 busy .. 1 idle).', values: [[{ reason: st.capacity.reason || 'ok' }, Number(st.capacity.factor ?? 1)]] });
      out.push({ name: 'coroute_jobs_poll_delay_ms', help: 'Current poll delay (idle backoff).', values: [[null, st.pollDelayMs]] });
      out.push({ name: 'coroute_jobs_processed_total', help: 'Finished jobs by type and outcome.', type: 'counter',
        values: [...this.worker.outcomes].map(([k, v]) => { const [type, outcome] = k.split('|'); return [{ type, outcome }, v]; }) });
    }
    return out;
  }

  /** Graceful stop: drains the worker (running jobs finish or go back to the queue) and removes the heartbeat row. */
  async stop({ drainMs } = {}) {
    if (this.stopped) return { finished: 0, released: 0 };
    // A gateway has TimeoutStopSec=20 for its whole drain: its in-process worker waits at most 5 s, then hands back.
    if (drainMs === undefined) drainMs = this.mode === 'separate' ? this.cfg.drainMs : Math.min(this.cfg.drainMs, 5000);
    this.stopped = true;
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
    let out = { finished: 0, released: 0 };
    if (this.worker) {
      out = await this.worker.stop({ drainMs });
      await this.soda.removeWhere(WORKERS, { workerId: this.workerId }).catch(() => {});
    }
    if (this.capacity && typeof this.capacity.stop === 'function') this.capacity.stop();
    return out;
  }
}

/** Admin API (MASTER_ADMIN, mounted at /api/admin/jobs). The web admin UI is wired by the lead (ROUND8 notes). */
function adminJobsRouter({ jobs, audit = null }) {
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60000, limit: 120, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res)).catch(next);
  const idOk = (id) => /^j_[a-f0-9]{20}$/.test(String(id || ''));
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  r.use(limiter, (req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  r.get('/', wrap(async (req, res) => res.json(await jobs.summary())));
  r.get('/dead', wrap(async (req, res) => res.json({ items: jobs.enabled || jobs.mode === 'separate' ? await jobs.queue.listDead({ limit: req.query.limit, type: String(req.query.type || '') }) : [] })));
  r.post('/dead/:jobId/retry', wrap(async (req, res) => {
    if (!idOk(req.params.jobId)) return res.status(404).json({ error: 'Not found', code: 'NOT_FOUND' });
    const out = await jobs.queue.retryDead(req.params.jobId);
    if (out === 'not_found') return res.status(404).json({ error: 'Not found', code: 'NOT_FOUND' });
    if (audit) audit({ at: Date.now(), by: by(req), byUserId: req.user ? req.user.userId : null, action: 'JOB_DEAD_RETRY', target: req.params.jobId, details: { outcome: out } });
    res.json({ ok: true, outcome: out });
  }));
  const discard = wrap(async (req, res) => {
    if (!idOk(req.params.jobId)) return res.status(404).json({ error: 'Not found', code: 'NOT_FOUND' });
    if (!(await jobs.queue.discardDead(req.params.jobId))) return res.status(404).json({ error: 'Not found', code: 'NOT_FOUND' });
    if (audit) audit({ at: Date.now(), by: by(req), byUserId: req.user ? req.user.userId : null, action: 'JOB_DEAD_DISCARD', target: req.params.jobId });
    res.json({ ok: true });
  });
  r.post('/dead/:jobId/discard', discard);
  r.delete('/dead/:jobId', discard);
  return r;
}

/** One call from app.js (and gateway/worker.js through createApp). */
function attachJobs(opts) { return new Jobs(opts); }

module.exports = { attachJobs, Jobs, adminJobsRouter, jobsConfig, parseConcurrency, RegisterOnlyLease, DEFAULT_CONCURRENCY, WORKERS_COLLECTION: WORKERS, MAX_PENDING_FALLBACKS };
