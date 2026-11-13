'use strict';
/**
 * Round 8: capacity-aware job worker (docs/features_355/job_queue.md). Pulls jobs from the queue (src/jobs/queue.js)
 * according to its OWN capacity; never pushed to.
 *
 *  - Concurrency per job family (WORKER_CONCURRENCY, e.g. "email:4,push:4,roads:1,photo:2,batch:1"), times `share`
 *    (WORKER_INPROCESS_SHARE, 0.5 for the worker inside a gateway), times the capacity factor (src/jobs/capacity.js:
 *    event-loop lag, CPU load per core, free memory, database calls in flight vs ORACLE_MAX_INFLIGHT). Capped overall
 *    by WORKER_MAX_CONCURRENCY. Factor 0 = take nothing new, except ONE urgent job (priority 0: security codes).
 *  - Polling: JOBS_POLL_MIN_MS (250) while there is work, doubling up to JOBS_POLL_MAX_MS (5000) while idle; a job
 *    enqueued on the same node wakes it at once (wake()). One small claim query per poll (JOBS_CLAIM_BATCH rows).
 *  - Each running job's lease is renewed every leaseMs / 3; a lost lease aborts the handler's signal.
 *  - stop({ drainMs }): claims nothing more, waits up to drainMs for running jobs, hands the rest back to the queue
 *    (attempt not spent) so another worker takes them at once.
 */
const crypto = require('crypto');
const os = require('os');
const { runInJob } = require('./context');

class JobTimeout extends Error { constructor(ms) { super(`job timed out after ${ms} ms`); this.name = 'JobTimeout'; this.code = 'JOB_TIMEOUT'; } }

class JobWorker {
  /**
   * @param {object} o
   * @param {object} o.queue        JobQueue
   * @param {Map} o.registry        type -> { handler(payload, { job, signal, attempt }), family, leaseMs, timeoutMs, backoffBaseMs }
   * @param {string[]|null} [o.families]  enabled families (null = every registered family)
   * @param {object} [o.capacity]   CapacityMonitor (factor())
   */
  constructor({ queue, registry, families = null, concurrency = {}, defaultConcurrency = 2, maxConcurrency = 16, share = 1, capacity = null,
    logger = console, node = os.hostname(), mode = 'inprocess', pollMinMs = 250, pollMaxMs = 5000, claimBatch = 4, reclaimEveryMs = 15000,
    clock = Date.now, urgentPriority = 0 } = {}) {
    this.queue = queue; this.registry = registry; this.familyFilter = families ? new Set(families) : null;
    this.concurrency = { ...concurrency }; this.defaultConcurrency = defaultConcurrency;
    this.maxConcurrency = Math.max(1, maxConcurrency); this.share = Math.max(0.05, Math.min(1, share));
    this.capacity = capacity; this.log = logger; this.node = node; this.mode = mode;
    this.pollMinMs = Math.max(10, pollMinMs); this.pollMaxMs = Math.max(this.pollMinMs, pollMaxMs);
    this.claimBatch = Math.max(1, Math.min(20, claimBatch)); this.reclaimEveryMs = reclaimEveryMs;
    this.clock = clock; this.urgentPriority = urgentPriority;
    this.owner = `${node}:${process.pid}:${crypto.randomBytes(3).toString('hex')}`;
    this.running = {}; // family -> n
    this.runningTotal = 0;
    this.urgentRunning = 0;
    this.active = new Set();
    this.delay = this.pollMinMs;
    this.timer = null; this.ticking = false; this.started = false; this.stopped = false; this.paused = false;
    this.lastReclaimAt = 0;
    this.lastCap = { factor: 1, reason: 'ok' };
    this.polls = 0; this.idlePolls = 0;
    this.outcomes = new Map(); // `${type}|${outcome}` -> n (types come from the registry: bounded)
  }

  /** Families this worker serves: registered ones, filtered by WORKER_TYPES. */
  families() {
    const set = new Set();
    for (const def of this.registry.values()) if (!this.familyFilter || this.familyFilter.has(def.family)) set.add(def.family);
    return [...set];
  }

  servesType(type) {
    const def = this.registry.get(type);
    return !!def && (!this.familyFilter || this.familyFilter.has(def.family));
  }

  start() {
    if (this.started || this.stopped) return this;
    this.started = true;
    this._schedule(0);
    return this;
  }

  _schedule(ms) {
    if (this.stopped) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => { this.timer = null; this._tick(); }, ms);
    this.timer.unref?.();
  }

  /** A job was enqueued on this node (or a slot freed up): poll now instead of waiting out the idle backoff. */
  wake() {
    if (!this.started || this.stopped || this.paused) return;
    this.delay = this.pollMinMs;
    if (!this.ticking) this._schedule(0);
    else this._again = true;
  }

  pause() { this.paused = true; if (this.timer) { clearTimeout(this.timer); this.timer = null; } }
  resume() { if (!this.paused) return; this.paused = false; this.delay = this.pollMinMs; if (this.started && !this.stopped) this._schedule(0); }

  _capOf(family, factor) {
    const conc = Math.max(0, Number(this.concurrency[family] ?? this.defaultConcurrency) || 0);
    if (!conc || factor <= 0) return 0;
    const scaled = conc * this.share * factor;
    return Math.max(1, factor >= 1 ? Math.ceil(scaled) : Math.floor(scaled));
  }

  /** Free slots per family right now. */
  slots(factor) {
    const free = {};
    let total = 0;
    const overall = Math.max(0, this.maxConcurrency - this.runningTotal);
    for (const f of this.families()) {
      const n = Math.max(0, this._capOf(f, factor) - (this.running[f] || 0));
      if (n > 0) { free[f] = n; total += n; }
    }
    return { free, total: Math.min(total, overall) };
  }

  async _tick() {
    if (this.ticking || this.stopped || this.paused) return;
    this.ticking = true;
    this._again = false;
    let next = this.delay;
    try {
      this.polls++;
      const now = this.clock();
      if (now - this.lastReclaimAt >= this.reclaimEveryMs) {
        this.lastReclaimAt = now;
        await this.queue.reclaimExpired({ limit: 10 }).catch((e) => this.log.warn?.(`[jobs] reclaim failed: ${e.message}`));
      }
      const cap = this.capacity ? this.capacity.factor() : { factor: 1, reason: 'ok' };
      this.lastCap = cap;
      const { free, total } = this.slots(cap.factor);
      let claimed = [];
      if (total > 0) {
        const reserved = {};
        claimed = await this.queue.claim(this.owner, {
          families: Object.keys(free), limit: Math.min(total, this.claimBatch),
          accept: (doc) => {
            if (!this.servesType(doc.type)) return false;
            const f = doc.family;
            if ((reserved[f] || 0) >= (free[f] || 0)) return false;
            reserved[f] = (reserved[f] || 0) + 1;
            return true;
          },
          leaseMsOf: (type) => this.registry.get(type)?.leaseMs || null,
        });
      } else if (cap.factor <= 0 && this.urgentRunning < 1 && this.runningTotal < this.maxConcurrency) {
        // Busy, but a security code must never wait for a quiet moment: one urgent job at a time.
        claimed = await this.queue.claim(this.owner, { families: this.families(), limit: 1, maxPriority: this.urgentPriority,
          accept: (doc) => this.servesType(doc.type), leaseMsOf: (type) => this.registry.get(type)?.leaseMs || null });
      }
      for (const job of claimed) this._run(job);
      if (claimed.length) { this.delay = this.pollMinMs; next = this.pollMinMs; } else if (total <= 0) {
        next = Math.min(this.pollMaxMs, this.pollMinMs * 4); // busy: look at capacity again soon, without hammering the DB
      } else {
        this.idlePolls++;
        this.delay = Math.min(this.pollMaxMs, Math.max(this.pollMinMs, this.delay * 2));
        next = this.delay;
      }
    } catch (e) {
      this.log.warn?.(`[jobs] poll failed: ${String(e.message || e).slice(0, 160)}`);
      this.delay = this.pollMaxMs; next = this.pollMaxMs;
    } finally {
      this.ticking = false;
      if (this._again) { this._again = false; next = 0; }
      if (!this.stopped && !this.paused) this._schedule(next);
    }
  }

  _count(type, outcome) {
    const k = `${type}|${outcome}`;
    this.outcomes.set(k, (this.outcomes.get(k) || 0) + 1);
  }

  _run(job) {
    const def = this.registry.get(job.doc.type);
    const f = job.doc.family;
    const urgent = (Number(job.doc.priority) || 0) <= this.urgentPriority;
    this.running[f] = (this.running[f] || 0) + 1;
    this.runningTotal++;
    if (urgent) this.urgentRunning++;
    const ac = new AbortController();
    const entry = { job, ac, lost: false, draining: false, timedOut: false, op: Promise.resolve() };
    // Every queue write of one job is serialised (a renew in flight never makes the finish look like a lost lease).
    const serial = (fn) => { const p = entry.op.then(fn, fn); entry.op = p.catch(() => {}); return p; };
    entry.serial = serial;
    this.active.add(entry);
    const leaseMs = (def && def.leaseMs) || job.doc.leaseMs || 60000;
    const renew = setInterval(() => {
      serial(() => (entry.draining ? true : this.queue.renew(job, leaseMs))).then((ok) => {
        if (!ok && !entry.draining) { entry.lost = true; ac.abort(); }
      }, () => { /* the database is unreachable: keep going; the lease decides */ });
    }, Math.max(500, Math.floor(leaseMs / 3)));
    renew.unref?.();
    let timeoutTimer = null;
    const timeoutMs = def && def.timeoutMs > 0 ? def.timeoutMs : 0;
    entry.promise = (async () => {
      let outcome = 'done';
      try {
        if (!def) throw Object.assign(new Error(`no handler for ${job.doc.type} on this worker`), { code: 'NO_HANDLER' });
        const payload = this.queue.open(job);
        const work = Promise.resolve().then(() => runInJob(job.doc, () => def.handler(payload, { job: job.doc, signal: ac.signal, attempt: job.doc.attempts })));
        if (timeoutMs) {
          await Promise.race([work, new Promise((_, rej) => { timeoutTimer = setTimeout(() => { entry.timedOut = true; ac.abort(); rej(new JobTimeout(timeoutMs)); }, timeoutMs); timeoutTimer.unref?.(); })]);
        } else await work;
        if (entry.lost || entry.draining) { outcome = entry.lost ? 'lost' : 'released'; } else {
          const ok = await serial(() => this.queue.complete(job));
          outcome = ok ? 'done' : 'lost';
        }
      } catch (e) {
        if (entry.lost) outcome = 'lost';
        else if (entry.draining) outcome = 'released';
        else outcome = await serial(() => this.queue.fail(job, e, { backoffBaseMs: def && def.backoffBaseMs })).catch(() => 'error');
        if (outcome === 'retry' || outcome === 'dead') this.log.warn?.(`[jobs] ${job.doc.type} ${job.doc.jobId} attempt ${job.doc.attempts}: ${outcome} (${String((e && (e.code || e.message)) || e).split('\n')[0].slice(0, 120)})`);
      } finally {
        clearInterval(renew);
        if (timeoutTimer) clearTimeout(timeoutTimer);
        this.running[f] = Math.max(0, (this.running[f] || 1) - 1);
        this.runningTotal = Math.max(0, this.runningTotal - 1);
        if (urgent) this.urgentRunning = Math.max(0, this.urgentRunning - 1);
        this.active.delete(entry);
        this._count(job.doc.type, outcome);
        this.wake();
      }
      return outcome;
    })();
    return entry.promise;
  }

  /** Resolves when nothing is running (tests). */
  async idle() {
    while (this.active.size || this.ticking) await Promise.allSettled([...this.active].map((e) => e.promise).concat([new Promise((r) => setTimeout(r, 5))]));
  }

  /** Graceful drain (SIGTERM): see the header. Resolves { finished, released }. */
  async stop({ drainMs = 25000 } = {}) {
    if (this.stopped) return { finished: 0, released: 0 };
    this.stopped = true;
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    const startedWith = this.active.size;
    if (this.active.size && drainMs > 0) {
      let t;
      await Promise.race([Promise.allSettled([...this.active].map((e) => e.promise)), new Promise((r) => { t = setTimeout(r, drainMs); })]); // bounded: keeps the process up while draining
      clearTimeout(t);
    }
    let released = 0;
    const left = [...this.active];
    await Promise.allSettled(left.map(async (e) => {
      e.draining = true;
      e.ac.abort();
      if (await e.serial(() => this.queue.release(e.job)).catch(() => false)) released++;
    }));
    return { finished: startedWith - left.length, released };
  }

  status() {
    const cap = this.lastCap || {};
    return {
      mode: this.mode, owner: this.owner, families: this.families(), paused: this.paused, stopped: this.stopped,
      running: { ...this.running }, runningTotal: this.runningTotal, maxConcurrency: this.maxConcurrency, share: this.share,
      capacity: { factor: cap.factor, reason: cap.reason }, pollDelayMs: this.delay, polls: this.polls, idlePolls: this.idlePolls,
    };
  }
}

module.exports = { JobWorker, JobTimeout };
