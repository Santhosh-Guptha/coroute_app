'use strict';
/**
 * Exactly-once scheduled jobs across gateway nodes that share one database.
 *
 * One lease document per job name in the `leases` collection:
 *   { name, holder, role, expiresAt, version, lastRunAt, lastRunBy, wantedBy?, wantedAt? }
 *
 * - Creating a lease is an insert guarded by a unique index on `name` (two nodes racing: one wins).
 * - Every later change (renew, take over an expired lease, mark a run, hand back, release) is an atomic
 *   compare-and-replace of the whole document (SodaClient.compareAndReplace: JSON Patch `test` + `replace`
 *   in one PATCH; MemorySoda emulates it). A node whose CAS fails re-reads and never acts on stale state.
 * - A run is recorded (lastRunAt) in the same CAS that renews the lease, BEFORE fn starts: across nodes a
 *   job runs at most once per interval, and on one node never concurrently with itself.
 *
 * Role preference (GATEWAY_ROLE):
 *   Each job prefers one role ('web' by default; jobs that touch in-memory ride rooms prefer 'live').
 *   A node of the preferred role (or role 'all') takes a free or expired lease at once. A node of the
 *   other role takes it only once the lease has been expired for LIVE_TAKEOVER_GRACE (120 s default).
 *   When a preferred node finds the lease held by a non-preferred node it asks for it (wantedAt); the
 *   holder hands it back at its next renew, after any run in progress finishes.
 *
 * 'standby' (v3.56 DR node): never takes any lease (promotion changes the role and restarts).
 *
 * Clocks: expiry uses wall-clock time; both VMs run chrony/NTP (OCI default). Skew well under the TTL
 * (60 s default) is harmless.
 */
const os = require('os');
const crypto = require('crypto');

const COLLECTION = 'leases';

class JobLease {
  /**
   * @param {{soda: object, role?: 'live'|'web'|'all', node?: string, logger?: object, clock?: () => number,
   *          ttlMs?: number, heartbeatMs?: number, graceMs?: number, collection?: string}} opts
   */
  constructor({ soda, role = 'all', node = os.hostname(), logger = console, clock = Date.now,
    ttlMs = 60000, heartbeatMs = 15000, graceMs = 120000, collection = COLLECTION, autoTick = true } = {}) {
    if (!soda) throw new Error('[lease] soda client required');
    if (!['live', 'web', 'all', 'standby'].includes(role)) throw new Error(`[lease] invalid role ${role}`);
    this.soda = soda; this.role = role; this.node = node; this.log = logger; this.clock = clock;
    this.ttlMs = ttlMs; this.heartbeatMs = heartbeatMs; this.graceMs = graceMs; this.collection = collection;
    // A restarted process is a new holder: it never mistakes its previous life's lease for its own.
    this.holder = `${node}:${process.pid}:${crypto.randomBytes(4).toString('hex')}`;
    this.autoTick = autoTick; // false: tests drive poll() themselves
    this.jobs = new Map();
    this.stopped = false;
    this._ready = null;
    this._lastWarn = 0;
  }

  _init() {
    if (!this._ready) {
      this._ready = (async () => {
        await this.soda.ensureCollection(this.collection);
        await this.soda.ensureIndex(this.collection, { name: `${this.collection}_name_ux`, unique: true, fields: [{ path: 'name' }] });
      })().catch((e) => { this._ready = null; throw e; });
    }
    return this._ready;
  }

  _warn(msg) {
    const now = Date.now();
    if (now - this._lastWarn < 60000) return; // a database outage must not flood the log
    this._lastWarn = now;
    this.log.warn(msg);
  }

  _preferred(job) { return this.role === 'all' || this.role === job.prefer; }

  _register(name, intervalMs, fn, { prefer = 'web', firstDelayMs = 0, once = false, minGapMs = 0 } = {}) {
    if (this.jobs.has(name)) throw new Error(`[lease] job ${name} already registered`);
    if (!['web', 'live'].includes(prefer)) throw new Error(`[lease] prefer must be web or live (${name})`);
    const job = {
      name, intervalMs, fn, prefer, once, minGapMs, notBefore: this.clock() + firstDelayMs,
      key: null, doc: null, holding: false, running: null, polling: null, nextCheckAt: 0,
      missingSince: null, timer: null, abort: null, runs: 0, lastError: null, lastRunAt: 0,
    };
    this.jobs.set(name, job);
    return job;
  }

  /**
   * Runs fn every intervalMs on whichever node holds the lease `name`; skipped while another node holds
   * it; never concurrently. fn receives { signal } (aborted when this node loses the lease).
   * opts: { prefer: 'web'|'live', firstDelayMs }
   */
  run(name, intervalMs, fn, opts = {}) {
    if (!(intervalMs > 0)) throw new Error(`[lease] interval required (${name})`);
    const job = this._register(name, intervalMs, fn, opts);
    if (this.autoTick) {
      const tickMs = Math.max(10, Math.min(this.heartbeatMs, intervalMs, Math.floor(this.ttlMs / 3)));
      job.timer = setInterval(() => { this.poll(name).catch(() => {}); }, tickMs);
      job.timer.unref?.();
      setImmediate(() => { this.poll(name).catch(() => {}); });
    }
    return { stop: () => this._stopJob(job) };
  }

  /**
   * One-off job (e.g. startup seeding): runs fn once on the node that gets the lease, unless it ran less
   * than minGapMs ago anywhere. Resolves true when this node ran it. The lease is released afterwards.
   */
  async once(name, fn, { prefer = 'web', minGapMs = 10 * 60000 } = {}) {
    const job = this._register(name, Infinity, fn, { prefer, once: true, minGapMs });
    try {
      await this.poll(name);
      if (!job.running) return false;
      await job.running;
      return true;
    } finally {
      await this._release(job).catch(() => {});
      this.jobs.delete(name);
    }
  }

  _due(job, now) {
    if (job.running || this.stopped) return false;
    const last = Number(job.doc?.lastRunAt) || 0;
    if (job.once) return now - last >= job.minGapMs;
    return now >= Math.max(last + job.intervalMs, job.notBefore);
  }

  async _read(job) {
    if (job.key) {
      const doc = await this.soda.get(this.collection, job.key);
      if (doc) return { key: job.key, value: doc };
      job.key = null;
    }
    const row = await this.soda.findOne(this.collection, { name: job.name });
    if (row) job.key = row.key;
    return row;
  }

  /** One scheduling step for job `name`. Exposed for tests (deterministic clocks). */
  poll(name) {
    const job = this.jobs.get(name);
    if (!job || this.stopped) return Promise.resolve();
    if (job.polling) return job.polling;
    job.polling = this._poll(job).catch((e) => {
      this._warn(`[lease] ${name}: ${e.message}`);
      job.nextCheckAt = this.clock() + this.heartbeatMs;
      // A holder that cannot renew keeps its lease only until it expires.
      if (job.holding && !(job.doc && job.doc.expiresAt > this.clock())) this._lost(job);
    }).finally(() => { job.polling = null; });
    return job.polling;
  }

  _lost(job) {
    job.holding = false;
    if (job.abort) { job.abort.abort(); job.abort = null; }
  }

  async _cas(job, next) {
    const ok = await this.soda.compareAndReplace(this.collection, job.key, job.doc, next);
    if (ok) job.doc = next;
    return ok;
  }

  async _poll(job) {
    // v3.56 standby (DR) node: never takes a lease, so it never runs a job while vm1 / vm2 serve.
    if (this.role === 'standby') return;
    await this._init();
    let now = this.clock();
    const ttl = this.ttlMs;

    const preferred = this._preferred(job);
    const handBack = !preferred && job.doc?.wantedAt && now - job.doc.wantedAt <= ttl && !job.running;
    if (job.holding && !handBack && job.doc && job.doc.holder === this.holder && job.doc.expiresAt > now) {
      const needRenew = now >= job.doc.expiresAt - Math.floor((2 * ttl) / 3);
      const due = this._due(job, now);
      if (!needRenew && !due) return;
      const next = { ...job.doc, expiresAt: now + ttl, version: (job.doc.version || 0) + 1 };
      if (due) { next.lastRunAt = now; next.lastRunBy = this.node; }
      if (await this._cas(job, next)) {
        if (due) this._start(job);
        return;
      }
      // The document changed under us (a hand-back request, or something stranger): re-read below.
    } else if (!job.holding && now < job.nextCheckAt) {
      return; // standby: the next read is due when the holder's lease could have run out
    }

    const row = await this._read(job);
    now = this.clock();
    const doc = row?.value || null;

    if (!doc) {
      job.holding = false;
      if (job.missingSince === null) job.missingSince = now;
      if (!preferred && now - job.missingSince < this.graceMs) { job.nextCheckAt = now + this.heartbeatMs; return; }
      const fresh = { name: job.name, holder: this.holder, node: this.node, role: this.role, expiresAt: now + ttl, version: 1, lastRunAt: 0, lastRunBy: null };
      try {
        job.key = await this.soda.insert(this.collection, fresh);
      } catch {
        job.nextCheckAt = 0; // lost the race: the next poll reads the winner's document
        return;
      }
      job.doc = fresh; job.holding = true; job.missingSince = null;
      this.log.info?.(`[lease] ${job.name}: acquired by ${this.node} (${this.role})`);
      return this._afterAcquire(job);
    }
    job.missingSince = null;

    if (doc.holder === this.holder && doc.expiresAt > now) {
      // Still ours. A preferred node asked for it: hand it back once nothing is running.
      job.doc = doc; job.holding = true;
      const wanted = doc.wantedAt && now - doc.wantedAt <= ttl && doc.wantedBy !== this.holder;
      if (wanted && !preferred && !job.running) {
        const released = { ...doc, expiresAt: now, version: (doc.version || 0) + 1, wantedBy: null, wantedAt: null };
        if (await this._cas(job, released)) {
          this._lost(job);
          this.log.info?.(`[lease] ${job.name}: handed back by ${this.node}`);
        }
        job.nextCheckAt = now + this.graceMs;
        return;
      }
      const next = { ...doc, expiresAt: now + ttl, version: (doc.version || 0) + 1 };
      const due = this._due(job, now);
      if (due) { next.lastRunAt = now; next.lastRunBy = this.node; }
      if (await this._cas(job, next) && due) this._start(job);
      return;
    }

    if (doc.expiresAt > now) {
      // Held elsewhere.
      if (job.holding) this._lost(job);
      job.doc = doc;
      const holderPreferred = doc.role === 'all' || doc.role === job.prefer;
      if (preferred && !holderPreferred && !(doc.wantedAt && now - doc.wantedAt <= ttl)) {
        await this.soda.compareAndReplace(this.collection, job.key, doc, { ...doc, wantedBy: this.holder, wantedAt: now });
        job.nextCheckAt = now + this.heartbeatMs;
        return;
      }
      // A preferred standby looks again soon (a graceful release is picked up within ~2 heartbeats).
      job.nextCheckAt = preferred ? Math.min(doc.expiresAt, now + 2 * this.heartbeatMs) : Math.min(doc.expiresAt + this.graceMs, now + ttl);
      if (preferred && doc.wantedBy === this.holder) job.nextCheckAt = now + this.heartbeatMs;
      return;
    }

    // Expired.
    if (job.holding) this._lost(job);
    job.doc = doc;
    if (!preferred && now - doc.expiresAt < this.graceMs) { job.nextCheckAt = doc.expiresAt + this.graceMs; return; }
    const taken = { ...doc, holder: this.holder, node: this.node, role: this.role, expiresAt: now + ttl, version: (doc.version || 0) + 1, wantedBy: null, wantedAt: null };
    if (await this._cas(job, taken)) {
      job.holding = true;
      this.log.info?.(`[lease] ${job.name}: taken over by ${this.node} (${this.role}) from ${doc.node || doc.holder}`);
      return this._afterAcquire(job);
    }
    job.nextCheckAt = 0;
  }

  async _afterAcquire(job) {
    const now = this.clock();
    if (!this._due(job, now)) return;
    const next = { ...job.doc, lastRunAt: now, lastRunBy: this.node, version: (job.doc.version || 0) + 1 };
    if (await this._cas(job, next)) this._start(job);
  }

  _start(job) {
    const abort = new AbortController();
    job.abort = abort;
    const started = this.clock();
    job.runs++; job.lastRunAt = started;
    job.running = (async () => job.fn({ signal: abort.signal, name: job.name }))()
      .then(() => { job.lastError = null; }, (e) => {
        job.lastError = e?.message || String(e);
        this.log.warn(`[lease] ${job.name} failed: ${job.lastError}`);
      })
      .finally(() => { job.running = null; if (job.abort === abort) job.abort = null; });
  }

  async _release(job) {
    if (!job.holding || !job.key || !job.doc) return;
    const now = this.clock();
    const released = { ...job.doc, expiresAt: Math.min(job.doc.expiresAt, now), version: (job.doc.version || 0) + 1, wantedBy: null, wantedAt: null };
    try { await this._cas(job, released); } finally { job.holding = false; }
  }

  _stopJob(job) {
    if (job.timer) clearInterval(job.timer);
    job.timer = null;
  }

  /**
   * Stops every timer, waits up to waitMs for running jobs, then releases held leases so the other node
   * can take over at once (graceful shutdown). Safe to call without awaiting.
   */
  async stopAll({ waitMs = 10000 } = {}) {
    this.stopped = true;
    const jobs = [...this.jobs.values()];
    for (const job of jobs) this._stopJob(job);
    const running = jobs.map((j) => j.running).filter(Boolean);
    if (running.length) {
      let t;
      await Promise.race([Promise.allSettled(running), new Promise((r) => { t = setTimeout(r, waitMs); t.unref?.(); })]);
      clearTimeout(t);
    }
    await Promise.allSettled(jobs.map((j) => j.polling).filter(Boolean));
    await Promise.allSettled(jobs.filter((j) => !j.running).map((j) => this._release(j)));
    for (const j of jobs) if (j.abort) j.abort.abort();
  }

  /** Resolves when no job of this node is running or polling. */
  async idle() {
    for (;;) {
      const busy = [...this.jobs.values()].flatMap((j) => [j.running, j.polling]).filter(Boolean);
      if (!busy.length) return;
      await Promise.allSettled(busy);
    }
  }

  /** What this node knows about each job (for /api/health). */
  status() {
    const out = {};
    for (const j of this.jobs.values()) {
      out[j.name] = { holding: j.holding, running: !!j.running, prefer: j.prefer, runs: j.runs,
        lastRunAt: Number(j.doc?.lastRunAt) || 0, lastRunBy: j.doc?.lastRunBy || null, ...(j.lastError ? { lastError: j.lastError } : {}) };
    }
    return out;
  }
}

module.exports = { JobLease, LEASE_COLLECTION: COLLECTION };
