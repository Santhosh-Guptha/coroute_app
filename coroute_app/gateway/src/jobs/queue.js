'use strict';
/**
 * Round 8: durable job queue on the existing database (one SODA collection, no Redis / RabbitMQ).
 * Docs: docs/features_355/job_queue.md.
 *
 * Collection `job_queue`, one document per job:
 *   { jobId, key, type, family, payload, priority, runAt, state, attempts, maxAttempts, leaseOwner, leaseUntil,
 *     leaseMs, deleteOnDone, lastError, createdAt, updatedAt, startedAt?, doneAt?, casRev }
 *   state: queued -> running -> done            (done rows lose their payload; removed after JOBS_DONE_TTL_HOURS)
 *                            -> queued (retry, runAt = backoff with jitter)
 *                            -> dead (moved to `job_dead`, kept JOBS_DEAD_TTL_DAYS, retry / discard from the admin API)
 *
 * Exactly-once claim: a worker reads candidate rows and claims each with ONE atomic compare-and-replace
 * (SodaClient.compareAndReplace: JSON Patch `test` of every top-level scalar of the observed row, `casRev` among
 * them, plus `replace`). Every write of this module gives the row a fresh `casRev` (the queue stamps it itself, so
 * `job_queue` does not need to be one of soda.js CAS_COLLECTIONS): of two workers racing on one row exactly one
 * patch applies, the other sees a failed precondition and moves on. A worker that dies keeps its rows only until
 * `leaseUntil`; reclaimExpired() puts them back (the attempt was already counted, so a job that kills its worker
 * every time ends in the dead-letter queue instead of looping).
 *
 * Idempotent enqueue: `key` has a unique index (default: the jobId). Enqueueing a key that exists returns the
 * existing job ({ duplicate: true }) instead of a second one; `rearm: true` puts a finished (done) job with that key
 * back in the queue (used for "one pending run at a time" jobs such as the leased batch ticks).
 *
 * Privacy: payloads are ids and small values (bounded: JOBS_MAX_PAYLOAD_BYTES, 8 KB default). A payload that must
 * carry something sensitive (a one-time security code) is sealed with AES-256-GCM (`sealed: true`; key
 * JOBS_SEAL_KEY or derived from JWT_SECRET) and its row is removed as soon as it is done.
 *
 * Database budget (free Autonomous DB, 20 sessions): one small query per poll (claim batch of a few rows), one CAS
 * per claimed row, one per finish; the worker backs off when idle (src/jobs/worker.js).
 */
const crypto = require('crypto');
const os = require('os');
const { newRev, REV_FIELD } = require('../oracle/soda');
const { Defer, RetryLater, PermanentError } = require('./errors');

const QUEUE = 'job_queue';
const DEAD = 'job_dead';
const TYPE_RE = /^[a-z][a-z0-9_]{1,15}\.[a-z][a-z0-9_]{1,40}$/;
const STATES = Object.freeze(['queued', 'running', 'done', 'dead']);

let redactString = (s) => s;
try { ({ redactString } = require('../redact')); } catch { /* scripts without the gateway tree */ }

const errText = (e) => redactString(String((e && (e.code || e.message)) || e || 'FAILED').split('\n')[0]).slice(0, 160);
const isUnique = (e) => !!e && (e.status === 409 || /unique|ORA-00001/i.test(`${e.message || ''} ${JSON.stringify(e.body || '')}`));

/** 32-byte key for sealed payloads: JOBS_SEAL_KEY (base64) or HKDF over JWT_SECRET. Null when neither is set. */
function sealKeyFrom({ sealKey, env = process.env, jwtSecret } = {}) {
  if (Buffer.isBuffer(sealKey) && sealKey.length === 32) return sealKey;
  const b64 = String(sealKey || env.JOBS_SEAL_KEY || '').trim();
  if (b64) {
    const buf = Buffer.from(b64, 'base64');
    if (buf.length === 32) return buf;
    throw new Error('[jobs] JOBS_SEAL_KEY must be 32 random bytes, base64 encoded (openssl rand -base64 32)');
  }
  const secret = String(jwtSecret || env.JWT_SECRET || '');
  if (!secret) return null;
  return Buffer.from(crypto.hkdfSync('sha256', Buffer.from(secret), Buffer.from('coroute-jobs'), Buffer.from('seal-v1'), 32));
}

function seal(key, json, aad) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  c.setAAD(Buffer.from(String(aad)));
  const ct = Buffer.concat([c.update(Buffer.from(json, 'utf8')), c.final()]);
  return `v1.${iv.toString('base64url')}.${c.getAuthTag().toString('base64url')}.${ct.toString('base64url')}`;
}

function unseal(key, box, aad) {
  const [v, iv, tag, ct] = String(box || '').split('.');
  if (v !== 'v1' || !iv || !tag || !ct) throw new PermanentError('sealed payload is malformed', 'SEALED_BAD');
  const d = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(iv, 'base64url'));
  d.setAAD(Buffer.from(String(aad)));
  d.setAuthTag(Buffer.from(tag, 'base64url'));
  return Buffer.concat([d.update(Buffer.from(ct, 'base64url')), d.final()]).toString('utf8');
}

class JobQueue {
  /**
   * @param {object} o
   * @param {object} o.soda           SODA client (SodaClient or MemorySoda)
   * @param {number} [o.maxPayloadBytes=8192]
   * @param {number} [o.doneTtlMs=24h] [o.deadTtlMs=14d]
   * @param {number} [o.backoffBaseMs=5000] [o.backoffMaxMs=15min] [o.defaultLeaseMs=60000] [o.defaultMaxAttempts=5]
   * @param {Buffer|string} [o.sealKey]  see sealKeyFrom
   * @param {() => number} [o.random]     jitter source (tests)
   */
  constructor({ soda, logger = console, clock = Date.now, collection = QUEUE, deadCollection = DEAD, maxPayloadBytes = 8192,
    doneTtlMs = 24 * 3600000, deadTtlMs = 14 * 86400000, backoffBaseMs = 5000, backoffMaxMs = 15 * 60000, defaultLeaseMs = 60000,
    defaultMaxAttempts = 5, sealKey, jwtSecret, env = process.env, random = Math.random } = {}) {
    if (!soda) throw new Error('[jobs] soda client required');
    this.soda = soda; this.log = logger; this.clock = clock; this.coll = collection; this.deadColl = deadCollection;
    this.maxPayloadBytes = Math.max(256, Number(maxPayloadBytes) || 8192);
    this.doneTtlMs = doneTtlMs; this.deadTtlMs = deadTtlMs;
    this.backoffBaseMs = backoffBaseMs; this.backoffMaxMs = backoffMaxMs;
    this.defaultLeaseMs = defaultLeaseMs; this.defaultMaxAttempts = defaultMaxAttempts;
    this.random = random;
    this.sealKey = sealKeyFrom({ sealKey, env, jwtSecret });
    this.ready = null;
    this.stats = { enqueued: 0, duplicates: 0, rearmed: 0, claimed: 0, claimConflicts: 0, done: 0, retried: 0, deferred: 0, dead: 0, reclaimed: 0, rejected: 0 };
    this._summary = null;
  }

  init() {
    if (!this.ready) {
      this.ready = (async () => {
        await this.soda.ensureCollection(this.coll);
        await this.soda.ensureCollection(this.deadColl);
        await this.soda.ensureIndex(this.coll, { name: `${this.coll}_key_ux`, unique: true, fields: [{ path: 'key' }] });
        // The claim query: state + runAt (the free tier keeps this to one small index).
        await this.soda.ensureIndex(this.coll, { name: `${this.coll}_claim_ix`, unique: false, fields: [{ path: 'state' }, { path: 'runAt', datatype: 'number' }] }).catch(() => {});
        await this.soda.ensureIndex(this.deadColl, { name: `${this.deadColl}_id_ux`, unique: true, fields: [{ path: 'jobId' }] });
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  /** Delay before retry number `attempts` (1 = after the first failure): exponential, capped, half jitter. */
  backoffMs(attempts, baseMs = this.backoffBaseMs) {
    const d = Math.min(this.backoffMaxMs, baseMs * 2 ** Math.max(0, attempts - 1));
    return Math.round(d / 2 + this.random() * (d / 2));
  }

  _job(k, doc) { return { k, doc }; }

  /** The payload of a claimed job (sealed payloads are opened here, on the worker). */
  open(job) {
    const p = job.doc.payload;
    if (p && typeof p === 'object' && typeof p.$sealed === 'string') {
      if (!this.sealKey) throw new PermanentError('no key to open a sealed payload (JOBS_SEAL_KEY / JWT_SECRET)', 'SEALED_NO_KEY');
      return JSON.parse(unseal(this.sealKey, p.$sealed, job.doc.type));
    }
    return p;
  }

  /**
   * Adds a job. opts: { key, priority (0 = most urgent .. 9), delayMs | runAt, maxAttempts, leaseMs, sealed, rearm, deleteOnDone }.
   * Resolves { jobId, key, k, state, duplicate, rearmed? }. Throws code PAYLOAD_TOO_LARGE / BAD_TYPE / NO_SEAL_KEY.
   */
  async enqueue(type, payload, opts = {}) {
    if (typeof type !== 'string' || !TYPE_RE.test(type)) throw Object.assign(new Error(`[jobs] bad job type ${type}`), { code: 'BAD_TYPE' });
    const json = JSON.stringify(payload === undefined ? null : payload);
    if (Buffer.byteLength(json, 'utf8') > this.maxPayloadBytes) {
      this.stats.rejected++;
      throw Object.assign(new Error(`[jobs] ${type} payload is larger than ${this.maxPayloadBytes} bytes`), { code: 'PAYLOAD_TOO_LARGE' });
    }
    let body = JSON.parse(json);
    if (opts.sealed) {
      if (!this.sealKey) throw Object.assign(new Error('[jobs] sealed payload without JOBS_SEAL_KEY / JWT_SECRET'), { code: 'NO_SEAL_KEY' });
      body = { $sealed: seal(this.sealKey, json, type) };
    }
    await this.init();
    const now = this.clock();
    const jobId = `j_${crypto.randomBytes(10).toString('hex')}`;
    const key = opts.key ? String(opts.key).slice(0, 200) : jobId;
    const priority = Math.max(0, Math.min(9, Math.round(Number(opts.priority ?? 5))));
    const runAt = Number.isFinite(opts.runAt) ? opts.runAt : now + Math.max(0, Number(opts.delayMs) || 0);
    const doc = {
      jobId, key, type, family: type.split('.')[0], payload: body, priority, runAt, state: 'queued', attempts: 0,
      maxAttempts: Math.max(1, Math.min(50, Number(opts.maxAttempts) || this.defaultMaxAttempts)),
      leaseOwner: null, leaseUntil: 0, leaseMs: Math.max(1000, Number(opts.leaseMs) || this.defaultLeaseMs),
      deleteOnDone: !!(opts.deleteOnDone || opts.sealed), lastError: null, createdAt: now, updatedAt: now, [REV_FIELD]: newRev(),
    };
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const k = await this.soda.insert(this.coll, doc);
        this.stats.enqueued++;
        this._summary = null;
        return { jobId, key, k, state: 'queued', duplicate: false, priority, family: doc.family };
      } catch (e) {
        if (!isUnique(e)) throw e;
        const row = await this.soda.findOne(this.coll, { key });
        if (!row) continue; // removed between the insert and the read (TTL cleanup): insert again
        const v = row.value;
        if (opts.rearm && v.state === 'done') {
          const next = { ...v, payload: body, priority, runAt, state: 'queued', attempts: 0, maxAttempts: doc.maxAttempts, leaseOwner: null, leaseUntil: 0,
            leaseMs: doc.leaseMs, lastError: null, doneAt: null, updatedAt: now, [REV_FIELD]: newRev() };
          if (await this.soda.compareAndReplace(this.coll, row.key, v, next)) {
            this.stats.rearmed++;
            return { jobId: v.jobId, key, k: row.key, state: 'queued', duplicate: false, rearmed: true, priority, family: v.family };
          }
          continue; // changed meanwhile: read again
        }
        this.stats.duplicates++;
        return { jobId: v.jobId, key, k: row.key, state: v.state, duplicate: true, priority: v.priority, family: v.family };
      }
    }
    throw Object.assign(new Error('[jobs] enqueue could not settle the idempotency key'), { code: 'ENQUEUE_RACE' });
  }

  async _claimRow(row, owner, now, leaseMs) {
    const v = row.value;
    const lease = Math.max(1000, Number(leaseMs) || Number(v.leaseMs) || this.defaultLeaseMs);
    const next = { ...v, state: 'running', leaseOwner: String(owner).slice(0, 120), leaseUntil: now + lease, attempts: (Number(v.attempts) || 0) + 1,
      startedAt: now, updatedAt: now, [REV_FIELD]: newRev() };
    if (await this.soda.compareAndReplace(this.coll, row.key, v, next)) { this.stats.claimed++; return this._job(row.key, next); }
    this.stats.claimConflicts++;
    return null;
  }

  /**
   * Claims up to `limit` due jobs for `owner`, most urgent first. Each is claimed by one compare-and-replace, so a
   * row two workers race for goes to exactly one of them. opts: { families: [..] | null (all), limit, accept(doc) =>
   * bool (checked before claiming: per-family slots), maxPriority (only jobs at least this urgent) }.
   */
  async claim(owner, { families = null, limit = 4, accept = null, maxPriority = null, leaseMsOf = null } = {}) {
    if (Array.isArray(families) && !families.length) return [];
    await this.init();
    const now = this.clock();
    const filter = { state: 'queued', runAt: { $lte: now } };
    if (Array.isArray(families)) filter.family = { $in: families };
    if (maxPriority !== null && maxPriority !== undefined) filter.priority = { $lte: maxPriority };
    const want = Math.max(1, Math.min(20, limit));
    const rows = await this.soda.query(this.coll, filter, { limit: Math.min(40, want * 2),
      orderBy: [{ path: 'priority', datatype: 'number', order: 'asc' }, { path: 'runAt', datatype: 'number', order: 'asc' }] });
    const out = [];
    for (const row of rows) {
      if (out.length >= want) break;
      if (accept && !accept(row.value)) continue;
      const j = await this._claimRow(row, owner, now, leaseMsOf ? leaseMsOf(row.value.type) : null);
      if (j) out.push(j);
    }
    if (out.length) this._summary = null;
    return out;
  }

  /** Extends the lease of a running job; false when it is no longer ours (reclaimed elsewhere). */
  async renew(job, leaseMs) {
    const now = this.clock();
    const next = { ...job.doc, leaseUntil: now + Math.max(1000, Number(leaseMs) || job.doc.leaseMs || this.defaultLeaseMs), updatedAt: now, [REV_FIELD]: newRev() };
    if (await this.soda.compareAndReplace(this.coll, job.k, job.doc, next)) { job.doc = next; return true; }
    return false;
  }

  /** The job finished. Done rows keep their key (idempotency window) but not their payload; sealed rows are removed. */
  async complete(job) {
    const now = this.clock();
    const next = { ...job.doc, state: 'done', payload: null, leaseOwner: null, leaseUntil: 0, lastError: null, doneAt: now, updatedAt: now, [REV_FIELD]: newRev() };
    const ok = await this.soda.compareAndReplace(this.coll, job.k, job.doc, next);
    if (!ok) { this.log.warn?.(`[jobs] ${job.doc.type} ${job.doc.jobId}: finished after its lease was taken over`); return false; }
    job.doc = next;
    this.stats.done++;
    this._summary = null;
    if (next.deleteOnDone) await this.soda.remove(this.coll, job.k).catch(() => {});
    return true;
  }

  /**
   * The job failed. Defer: back to the queue without spending the attempt. RetryLater / other errors: retry after
   * the given / backoff delay while attempts < maxAttempts. PermanentError or no attempts left: dead letter.
   * Resolves 'deferred' | 'retry' | 'dead' | 'lost'.
   */
  async fail(job, err, { backoffBaseMs } = {}) {
    const now = this.clock();
    const v = job.doc;
    const base = { ...v, leaseOwner: null, leaseUntil: 0, updatedAt: now, [REV_FIELD]: newRev() };
    let next; let outcome;
    if (err instanceof Defer) {
      next = { ...base, state: 'queued', attempts: Math.max(0, (Number(v.attempts) || 1) - 1), runAt: now + err.deferMs, lastError: v.lastError || null };
      outcome = 'deferred';
    } else if (!(err instanceof PermanentError) && (Number(v.attempts) || 0) < (Number(v.maxAttempts) || 1)) {
      const delay = err instanceof RetryLater ? err.retryInMs : this.backoffMs(Number(v.attempts) || 1, backoffBaseMs);
      next = { ...base, state: 'queued', runAt: now + delay, lastError: errText(err) };
      outcome = 'retry';
    } else {
      next = { ...base, state: 'dead', lastError: errText(err), deadAt: now };
      outcome = 'dead';
    }
    if (!(await this.soda.compareAndReplace(this.coll, job.k, v, next))) return 'lost';
    job.doc = next;
    this._summary = null;
    if (outcome === 'dead') { this.stats.dead++; await this._bury(job.k, next).catch((e) => this.log.warn?.(`[jobs] dead letter move failed: ${errText(e)}`)); } else if (outcome === 'retry') this.stats.retried++; else this.stats.deferred++;
    return outcome;
  }

  /** Copies a dead row to the dead-letter collection, then removes it from the queue (a failed copy is retried by cleanup()). */
  async _bury(k, doc) {
    try {
      await this.soda.insert(this.deadColl, { ...doc, state: 'dead', leaseOwner: null, leaseUntil: 0 });
    } catch (e) { if (!isUnique(e)) throw e; }
    await this.soda.remove(this.coll, k);
  }

  /** Graceful drain: a job this worker will not finish goes back to the queue at once (the attempt is not spent). */
  async release(job) {
    const now = this.clock();
    const v = job.doc;
    const next = { ...v, state: 'queued', attempts: Math.max(0, (Number(v.attempts) || 1) - 1), leaseOwner: null, leaseUntil: 0, runAt: now, updatedAt: now, [REV_FIELD]: newRev() };
    if (await this.soda.compareAndReplace(this.coll, job.k, v, next)) { job.doc = next; this._summary = null; return true; }
    return false;
  }

  /** Puts running jobs whose lease ran out back in the queue (or in the dead-letter queue when out of attempts). */
  async reclaimExpired({ limit = 10 } = {}) {
    await this.init();
    const now = this.clock();
    const rows = await this.soda.query(this.coll, { state: 'running', leaseUntil: { $lt: now } }, { limit: Math.max(1, Math.min(50, limit)) });
    let n = 0;
    for (const row of rows) {
      const v = row.value;
      const out = (Number(v.attempts) || 0) >= (Number(v.maxAttempts) || 1);
      const next = out
        ? { ...v, state: 'dead', leaseOwner: null, leaseUntil: 0, lastError: 'LEASE_EXPIRED', deadAt: now, updatedAt: now, [REV_FIELD]: newRev() }
        : { ...v, state: 'queued', leaseOwner: null, leaseUntil: 0, runAt: now, lastError: 'LEASE_EXPIRED', updatedAt: now, [REV_FIELD]: newRev() };
      if (await this.soda.compareAndReplace(this.coll, row.key, v, next)) {
        n++; this.stats.reclaimed++;
        if (out) { this.stats.dead++; await this._bury(row.key, next).catch(() => {}); }
      }
    }
    if (n) this._summary = null;
    return n;
  }

  /**
   * Security-code fallback (src/jobs/index.js): the producer takes its own job back when no worker claimed it in time.
   * Resolves the claimed job, or null when a worker has it (or it is finished / gone).
   */
  async takeOver(k, owner) {
    const v = await this.soda.get(this.coll, k);
    if (!v) return null;
    const now = this.clock();
    if (!(v.state === 'queued' || (v.state === 'running' && (Number(v.leaseUntil) || 0) < now))) return null;
    return this._claimRow({ key: k, value: v }, owner, now, null);
  }

  async get(jobId) {
    await this.init();
    const row = await this.soda.findOne(this.coll, { jobId: String(jobId) });
    return row ? this._job(row.key, row.value) : null;
  }

  /**
   * Admin / metrics summary: per type { queued, due, running, retrying, oldestAgeS }, dead letters. One bounded query
   * of the open rows (at most `scan`, oldest first) + one keys-only query of the dead letters. Cached for cacheMs.
   */
  async summary({ scan = 1000, cacheMs = 5000 } = {}) {
    const now = this.clock();
    if (this._summary && now - this._summary.at < cacheMs) return this._summary.value;
    await this.init();
    const rows = await this.soda.query(this.coll, { state: { $in: ['queued', 'running', 'dead'] } }, { limit: Math.min(1000, scan), orderBy: [{ path: 'createdAt', datatype: 'number', order: 'asc' }] });
    const types = {};
    let oldestDueMs = 0;
    for (const { value: v } of rows) {
      const t = types[v.type] || (types[v.type] = { queued: 0, due: 0, running: 0, retrying: 0, stuckDead: 0, oldestAgeS: 0, lastError: null });
      if (v.state === 'queued') {
        t.queued++;
        if ((Number(v.runAt) || 0) <= now) { t.due++; const age = now - Math.min(Number(v.runAt) || now, now); if (age > oldestDueMs) oldestDueMs = age; t.oldestAgeS = Math.max(t.oldestAgeS, Math.round((now - (Number(v.createdAt) || now)) / 1000)); }
        if ((Number(v.attempts) || 0) > 0) { t.retrying++; if (v.lastError) t.lastError = v.lastError; }
      } else if (v.state === 'running') t.running++;
      else t.stuckDead++;
    }
    const dead = await this.soda.query(this.deadColl, {}, { limit: 1000, fields: 'id' }).catch(() => []);
    const value = { at: now, types, open: rows.length, truncated: rows.length >= Math.min(1000, scan), dead: dead.length, deadTruncated: dead.length >= 1000,
      oldestDueAgeS: Math.round(oldestDueMs / 1000) };
    this._summary = { at: now, value };
    return value;
  }

  async listDead({ limit = 50, type = '' } = {}) {
    await this.init();
    const filter = type && TYPE_RE.test(type) ? { type } : {};
    const rows = await this.soda.query(this.deadColl, filter, { limit: Math.max(1, Math.min(200, Number(limit) || 50)), orderBy: [{ path: 'deadAt', datatype: 'number', order: 'desc' }] });
    return rows.map(({ value: v }) => ({
      jobId: v.jobId, type: v.type, key: v.key === v.jobId ? null : v.key, attempts: v.attempts, maxAttempts: v.maxAttempts, lastError: v.lastError,
      createdAt: v.createdAt, deadAt: v.deadAt, priority: v.priority,
      payload: v.payload && typeof v.payload === 'object' && v.payload.$sealed ? '[sealed]' : v.payload,
    }));
  }

  /** Puts a dead letter back in the queue with fresh attempts. 'retried' | 'duplicate' (its key is queued again) | 'not_found'. */
  async retryDead(jobId) {
    await this.init();
    const row = await this.soda.findOne(this.deadColl, { jobId: String(jobId) });
    if (!row) return 'not_found';
    const v = row.value;
    const now = this.clock();
    const doc = { ...v, state: 'queued', attempts: 0, runAt: now, leaseOwner: null, leaseUntil: 0, lastError: null, deadAt: null, updatedAt: now, retriedAt: now, [REV_FIELD]: newRev() };
    let outcome = 'retried';
    try { await this.soda.insert(this.coll, doc); } catch (e) { if (!isUnique(e)) throw e; outcome = 'duplicate'; }
    await this.soda.remove(this.deadColl, row.key);
    this._summary = null;
    return outcome;
  }

  async discardDead(jobId) {
    await this.init();
    const row = await this.soda.findOne(this.deadColl, { jobId: String(jobId) });
    if (!row) return false;
    await this.soda.remove(this.deadColl, row.key);
    this._summary = null;
    return true;
  }

  /** TTL cleanup (leased, hourly): finished rows after doneTtlMs, dead letters after deadTtlMs, stranded dead rows moved. */
  async cleanup({ signal = null } = {}) {
    await this.init();
    const now = this.clock();
    const done = await this.soda.removeWhere(this.coll, { state: 'done', doneAt: { $lt: now - this.doneTtlMs } });
    if (signal && signal.aborted) return { done, dead: 0, moved: 0 };
    const dead = await this.soda.removeWhere(this.deadColl, { deadAt: { $lt: now - this.deadTtlMs } });
    let moved = 0;
    for (const row of await this.soda.query(this.coll, { state: 'dead' }, { limit: 50 })) { await this._bury(row.key, row.value).then(() => { moved++; }, () => {}); }
    this._summary = null;
    return { done, dead, moved };
  }
}

module.exports = { JobQueue, QUEUE_COLLECTION: QUEUE, DEAD_COLLECTION: DEAD, TYPE_RE, STATES, sealKeyFrom, seal, unseal, hostname: os.hostname };
