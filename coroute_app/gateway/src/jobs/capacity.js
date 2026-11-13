'use strict';
/**
 * Round 8: how much background work this process can take right now (src/jobs/worker.js scales its concurrency by
 * the factor). Measured, cheap, no dependencies:
 *
 *   event-loop lag     p99 of the last window (metrics.loop when the gateway has one, else our own histogram)
 *   CPU                1-minute load average per core (os.loadavg / os.cpus)
 *   memory             available memory share (/proc/meminfo MemAvailable on Linux, else os.freemem)
 *   database budget    calls in flight vs ORACLE_MAX_INFLIGHT, and calls waiting for a slot (SodaClient)
 *
 * factor = the lowest of the four: 1 below the "warn" level, 0.5 between warn and high, 0 at or above high
 * (0 = claim nothing new; running jobs finish). Thresholds: JOBS_LAG_WARN_MS / JOBS_LAG_HIGH_MS (40 / 100),
 * JOBS_LOAD_WARN / JOBS_LOAD_HIGH per core (1.0 / 1.5), JOBS_MEM_WARN_PCT / JOBS_MEM_LOW_PCT (20 / 10),
 * database: half the budget in flight = warn, 80 % or any call queued = high.
 */
const os = require('os');
const fs = require('fs');
const { monitorEventLoopDelay } = require('perf_hooks');

function memAvailablePct() {
  try {
    const text = fs.readFileSync('/proc/meminfo', 'utf8');
    const total = Number((/MemTotal:\s+(\d+)/.exec(text) || [])[1]);
    const avail = Number((/MemAvailable:\s+(\d+)/.exec(text) || [])[1]);
    if (total > 0 && avail >= 0) return (avail / total) * 100;
  } catch { /* not Linux */ }
  if (process.env.NODE_ENV === 'test' && process.platform !== 'linux') return 100;
  return (os.freemem() / Math.max(1, os.totalmem())) * 100;
}

const num = (v, d) => { const n = Number(v); return Number.isFinite(n) && n >= 0 ? n : d; };

class CapacityMonitor {
  /**
   * @param {object} o
   * @param {() => object} [o.sample]  test hook: returns { lagMs, loadPerCore, memFreePct, dbInflight, dbBudget, dbQueue }
   * @param {object} [o.loop]          metrics LoopMonitor (current() -> { p99 })
   * @param {object} [o.soda]          SodaClient (inFlight, maxInFlight, queueLength())
   */
  constructor({ sample = null, loop = null, soda = null, env = process.env, lagWarnMs, lagHighMs, loadWarn, loadHigh, memWarnPct, memLowPct } = {}) {
    this.sampler = sample; this.loop = loop; this.soda = soda;
    this.lagWarnMs = lagWarnMs ?? num(env.JOBS_LAG_WARN_MS, 40);
    this.lagHighMs = lagHighMs ?? num(env.JOBS_LAG_HIGH_MS, 100);
    this.loadWarn = loadWarn ?? num(env.JOBS_LOAD_WARN, 1.0);
    this.loadHigh = loadHigh ?? num(env.JOBS_LOAD_HIGH, 1.5);
    this.memWarnPct = memWarnPct ?? num(env.JOBS_MEM_WARN_PCT, 20);
    this.memLowPct = memLowPct ?? num(env.JOBS_MEM_LOW_PCT, 10);
    this.own = null;
    if (!sample && !loop) {
      this.own = monitorEventLoopDelay({ resolution: 20 });
      this.own.enable();
      this.ownResetAt = Date.now();
    }
    this.last = null;
  }

  _lag() {
    if (this.loop && typeof this.loop.current === 'function') { const c = this.loop.current() || {}; return Number(c.p99) || 0; }
    if (!this.own) return 0;
    const lag = this.own.count ? Math.max(0, this.own.percentile(99) / 1e6 - 20) : 0;
    if (Date.now() - this.ownResetAt > 5000) { this.own.reset(); this.ownResetAt = Date.now(); }
    return lag;
  }

  sample() {
    if (this.sampler) return this.sampler();
    const cores = Math.max(1, (os.cpus() || []).length || 1);
    const s = this.soda;
    return {
      lagMs: this._lag(),
      loadPerCore: (os.loadavg()[0] || 0) / cores,
      memFreePct: memAvailablePct(),
      dbInflight: s ? Number(s.inFlight) || 0 : 0,
      dbBudget: s ? Number(s.maxInFlight) || 0 : 0,
      dbQueue: s && typeof s.queueLength === 'function' ? Number(s.queueLength()) || 0 : 0,
    };
  }

  /** { factor 0 | 0.5 | 1, reason, sample } */
  factor() {
    const s = this.sample() || {};
    const parts = [];
    const lvl = (name, v, warn, high, higherIsWorse = true) => {
      const bad = higherIsWorse ? v >= high : v <= high;
      const meh = higherIsWorse ? v >= warn : v <= warn;
      if (bad) parts.push([0, name]); else if (meh) parts.push([0.5, name]);
    };
    lvl('lag', Number(s.lagMs) || 0, this.lagWarnMs, this.lagHighMs);
    lvl('cpu', Number(s.loadPerCore) || 0, this.loadWarn, this.loadHigh);
    if (Number.isFinite(s.memFreePct)) lvl('memory', s.memFreePct, this.memWarnPct, this.memLowPct, false);
    if (Number(s.dbQueue) > 0) parts.push([0, 'db']);
    else if (Number(s.dbBudget) > 0) lvl('db', (Number(s.dbInflight) || 0) / s.dbBudget, 0.5, 0.8);
    let factor = 1; let reason = 'ok';
    for (const [f, why] of parts) if (f < factor) { factor = f; reason = why; }
    this.last = { factor, reason, sample: s, at: Date.now() };
    return this.last;
  }

  stop() { if (this.own) { this.own.disable(); this.own = null; } }
}

module.exports = { CapacityMonitor, memAvailablePct };
