'use strict';
/**
 * Password hashing that never runs on the event loop.
 *
 *   New hashes: Node crypto.scrypt (async, libuv threadpool), stored as
 *     scrypt$N$r$p$saltB64$hashB64        (N = 2^15, r = 8, p = 1 by default: ~100 ms on a fast core)
 *   Legacy bcrypt hashes ($2a$/$2b$/$2y$): verified in a worker_threads worker running bcryptjs, so a
 *     200-300 ms bcrypt compare never stalls sockets or other requests. A successful legacy verify
 *     reports needsRehash; AuthService then stores a scrypt hash (transparent upgrade).
 *
 * Every compare is constant time (crypto.timingSafeEqual). Unknown users are verified against a dummy
 * scrypt hash of the current cost, so "no such user" and "wrong password" take the same time.
 *
 * Concurrency: at most PASSWORD_HASH_CONCURRENCY scrypt jobs run at once (default 2), so a login burst
 * never occupies the whole libuv threadpool (DNS lookups and file I/O share it). Each running scrypt
 * needs 128 * N * r bytes (32 MiB at the defaults).
 *
 * Cost is configurable for the test suite (PASSWORD_SCRYPT_N; NODE_ENV=test defaults to 2^10).
 */
const crypto = require('crypto');
const path = require('path');
const { Worker } = require('worker_threads');

const SCRYPT_PREFIX = 'scrypt$';
const BCRYPT_RE = /^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$/;
const KEYLEN = 32;
const SALT_BYTES = 16;
// Bounds for parameters read back from stored hashes (a corrupt or hostile value must not exhaust memory).
const LIMITS = { maxN: 1 << 20, maxR: 32, maxP: 16 };

function isPow2(n) { return Number.isInteger(n) && n > 1 && (n & (n - 1)) === 0; }

function scryptAsync(password, salt, keylen, { N, r, p }) {
  return new Promise((resolve, reject) => {
    // maxmem must exceed 128 * N * r (plus a little): give it twice that.
    crypto.scrypt(password, salt, keylen, { N, r, p, maxmem: 256 * N * r + (1 << 20) }, (err, key) => (err ? reject(err) : resolve(key)));
  });
}

/** Parses scrypt$N$r$p$salt$hash; returns null when malformed or out of bounds. */
function parseScrypt(stored) {
  if (typeof stored !== 'string' || !stored.startsWith(SCRYPT_PREFIX)) return null;
  const parts = stored.split('$');
  if (parts.length !== 6) return null;
  const N = Number(parts[1]); const r = Number(parts[2]); const p = Number(parts[3]);
  if (!isPow2(N) || N > LIMITS.maxN || !Number.isInteger(r) || r < 1 || r > LIMITS.maxR || !Number.isInteger(p) || p < 1 || p > LIMITS.maxP) return null;
  const salt = Buffer.from(parts[4], 'base64');
  const hash = Buffer.from(parts[5], 'base64');
  if (salt.length < 8 || hash.length < 16 || hash.length > 64) return null;
  return { N, r, p, salt, hash };
}

/** A small, lazily started worker pool for legacy bcrypt compares. Idle workers exit. */
class BcryptPool {
  constructor({ size = 1, idleMs = 30000 } = {}) {
    this.size = Math.max(1, size); this.idleMs = idleMs;
    this.workers = []; // { worker, busy, idleTimer }
    this.queue = []; // { password, hash, resolve, reject }
    this.seq = 0;
  }

  compare(password, hash) {
    return new Promise((resolve, reject) => {
      this.queue.push({ password, hash, resolve, reject });
      this._drain();
    });
  }

  _spawn() {
    const worker = new Worker(path.join(__dirname, 'password_hash_worker.js'));
    const slot = { worker, busy: null, idleTimer: null };
    worker.unref();
    worker.on('message', (msg) => {
      const job = slot.busy; slot.busy = null;
      if (job) (msg.error ? job.reject(new Error(msg.error)) : job.resolve(msg.ok === true));
      this._drain();
    });
    const fail = (err) => {
      const job = slot.busy; slot.busy = null;
      this.workers = this.workers.filter((w) => w !== slot);
      if (slot.idleTimer) clearTimeout(slot.idleTimer);
      if (job) job.reject(err instanceof Error ? err : new Error('bcrypt worker exited'));
      this._drain();
    };
    worker.on('error', fail);
    worker.on('exit', (code) => fail(new Error(`bcrypt worker exited (${code})`)));
    this.workers.push(slot);
    return slot;
  }

  _drain() {
    while (this.queue.length) {
      let slot = this.workers.find((w) => !w.busy);
      if (!slot && this.workers.length < this.size) slot = this._spawn();
      if (!slot) return;
      const job = this.queue.shift();
      if (slot.idleTimer) { clearTimeout(slot.idleTimer); slot.idleTimer = null; }
      slot.busy = job;
      slot.worker.postMessage({ id: ++this.seq, password: job.password, hash: job.hash });
    }
    for (const slot of this.workers) {
      if (!slot.busy && !slot.idleTimer) {
        slot.idleTimer = setTimeout(() => { slot.idleTimer = null; if (!slot.busy) slot.worker.terminate().catch(() => {}); }, this.idleMs);
        slot.idleTimer.unref?.();
      }
    }
  }

  async close() {
    const all = this.workers.splice(0);
    await Promise.all(all.map((s) => { if (s.idleTimer) clearTimeout(s.idleTimer); return s.worker.terminate().catch(() => {}); }));
  }
}

class PasswordHasher {
  /**
   * @param {{N?:number,r?:number,p?:number,concurrency?:number,bcryptWorkers?:number}} opts
   */
  constructor({ N = 1 << 15, r = 8, p = 1, concurrency = 2, bcryptWorkers = 1, bcryptIdleMs = 30000 } = {}) {
    if (!isPow2(N) || N > LIMITS.maxN) throw new Error('[password_hash] N must be a power of two <= 2^20');
    this.params = { N, r, p };
    this.concurrency = Math.max(1, concurrency);
    this.active = 0; this.waiting = [];
    this.bcrypt = new BcryptPool({ size: bcryptWorkers, idleMs: bcryptIdleMs });
    this._dummy = null;
  }

  async _limited(fn) {
    if (this.active >= this.concurrency) await new Promise((resolve) => this.waiting.push(resolve));
    this.active++;
    try { return await fn(); } finally {
      this.active--;
      const next = this.waiting.shift();
      if (next) next();
    }
  }

  /** New hash in the current format and cost. */
  async hash(password) {
    if (typeof password !== 'string') throw new TypeError('password must be a string');
    const { N, r, p } = this.params;
    const salt = crypto.randomBytes(SALT_BYTES);
    const key = await this._limited(() => scryptAsync(password, salt, KEYLEN, this.params));
    return `${SCRYPT_PREFIX}${N}$${r}$${p}$${salt.toString('base64')}$${key.toString('base64')}`;
  }

  /** True when the stored hash is not scrypt at the current parameters. */
  needsRehash(stored) {
    const s = parseScrypt(stored);
    if (!s) return true;
    return s.N !== this.params.N || s.r !== this.params.r || s.p !== this.params.p || s.hash.length !== KEYLEN;
  }

  /**
   * Verifies password against stored (scrypt or legacy bcrypt). Never throws for a malformed hash.
   * @returns {Promise<{ok:boolean, needsRehash:boolean, legacy:boolean}>}
   */
  async verify(password, stored) {
    if (typeof password !== 'string' || typeof stored !== 'string' || !stored) {
      await this.dummyVerify(password);
      return { ok: false, needsRehash: false, legacy: false };
    }
    const s = parseScrypt(stored);
    if (s) {
      const key = await this._limited(() => scryptAsync(password, s.salt, s.hash.length, s));
      const ok = key.length === s.hash.length && crypto.timingSafeEqual(key, s.hash);
      return { ok, needsRehash: ok && this.needsRehash(stored), legacy: false };
    }
    if (BCRYPT_RE.test(stored)) {
      // bcryptjs.compare is itself constant time over the derived hash.
      let ok = false;
      try { ok = await this.bcrypt.compare(password, stored); } catch { ok = false; }
      return { ok, needsRehash: ok, legacy: true };
    }
    await this.dummyVerify(password);
    return { ok: false, needsRehash: false, legacy: false };
  }

  /** Same work as a real verify, for unknown accounts. Always false. */
  async dummyVerify(password) {
    if (!this._dummy) this._dummy = this.hash(crypto.randomBytes(16).toString('hex'));
    const dummy = await this._dummy;
    const s = parseScrypt(dummy);
    const key = await this._limited(() => scryptAsync(String(password ?? ''), s.salt, s.hash.length, s));
    crypto.timingSafeEqual(key, s.hash);
    return false;
  }

  close() { return this.bcrypt.close(); }
}

let shared = null;
/** Process-wide hasher built from config (PASSWORD_SCRYPT_N, PASSWORD_HASH_CONCURRENCY, PASSWORD_BCRYPT_WORKERS). */
function defaultHasher() {
  if (!shared) {
    const config = require('./config');
    shared = new PasswordHasher({
      N: config.passwordScryptN, r: config.passwordScryptR, p: config.passwordScryptP,
      concurrency: config.passwordHashConcurrency, bcryptWorkers: config.passwordBcryptWorkers,
    });
  }
  return shared;
}

module.exports = { PasswordHasher, BcryptPool, defaultHasher, parseScrypt, SCRYPT_PREFIX, BCRYPT_RE };
