'use strict';
/**
 * Load shedding: under extreme load, NON-ESSENTIAL endpoints answer 503 with Retry-After so the node keeps its
 * capacity for rides. Essential traffic is never shed: SOS and alerts, crash reports, auth (sign-in, refresh),
 * ride telemetry and convoy routes, guardian and live emergency links, health checks, payment webhooks and the
 * WebSocket (not an Express route at all). The never-list is hard-coded and wins over any configuration.
 *
 * Overloaded = any of (checked at most every 250 ms):
 *   event loop delay p99 (current 5 s window) > LOAD_SHED_LAG_MS          (default 250 ms)
 *   HTTP requests in flight                    > LOAD_SHED_MAX_INFLIGHT    (default 200)
 *   V8 heap used / heap limit                   > LOAD_SHED_HEAP_RATIO      (default 0.90)
 *   database calls waiting for a slot           > LOAD_SHED_DB_QUEUE        (default 200; SodaClient limiter)
 * and it stays "shedding" until LOAD_SHED_HOLD_MS (5 s) after the last overloaded check (no flapping).
 *
 * LOAD_SHED = on (default in production) | off (default under NODE_ENV=test) | force (drills: always shed).
 * LOAD_SHED_PATHS: extra sheddable routes, comma separated, "GET /api/foo" or "/api/foo" (prefix, any method).
 * Retry-After: LOAD_SHED_RETRY_AFTER_S (15) plus 0-10 s of jitter, so clients do not come back together.
 */
const v8 = require('v8');

/** Never shed (prefix match on a segment boundary). Not configurable. */
const NEVER = [
  '/api/health', '/api/auth', '/api/v1/sos', '/api/sos', '/api/convoys', '/api/guardian', '/api/public/live', '/e/',
  '/api/geo/essentials', '/api/subscription/webhook', '/api/membership/webhook', '/api/razorpay', '/api/verify-payment',
  '/api/me/capabilities', '/api/intel/crash', '/api/intel/consent', '/api/me/ride-lock', '/ws', '/status', '/watch',
  '/api/admin/emergencies', '/api/admin/safety', '/api/admin/fleet', '/api/trips',
];

/** Sheddable by default: reads that a rider or visitor can retry later without any safety cost. */
const DEFAULT_SHED = [
  'GET /api/places/reviews', 'GET /api/places/review-summary', 'GET /api/public', 'GET /api/community-stats',
  'GET /api/community-stories', 'GET /community-stories', 'GET /api/usage-stats', 'GET /api/impact-stats', 'GET /api/alltime-stats',
  'GET /api/me/leaderboard', 'GET /api/me/score', 'GET /api/me/stats', 'GET /api/friends/suggestions', 'GET /api/users/search',
  'GET /api/clubs', 'GET /api/intel/hazards', 'GET /api/intel/road-quality', 'GET /api/intel/stops', 'GET /api/intel/twisty',
  'GET /api/intel/ride-tip', 'GET /api/intel/me/contributions', 'POST /api/intel/fuel-gaps', 'GET /api/road-risk/near',
  'GET /api/geo/poi-cells', 'GET /api/geo/nearby-fuel', 'POST /api/pv', 'POST /api/feedback', 'POST /api/diagnostics/submit',
  'GET /api/admin/analytics', 'GET /api/admin/payments/analytics', 'GET /api/admin/membership/analytics',
  'GET /api/admin/engagement/stats', 'GET /api/admin/convoys/history', 'GET /api/admin/payments/export.csv',
];

function parseRule(s) {
  const t = String(s || '').trim();
  if (!t) return null;
  const m = /^([A-Z]+)\s+(\/\S*)$/.exec(t);
  if (m) return { method: m[1], prefix: m[2].toLowerCase() };
  if (t.startsWith('/')) return { method: null, prefix: t.toLowerCase() };
  return null;
}

function prefixMatch(path, prefix) {
  if (!path.startsWith(prefix)) return false;
  if (path.length === prefix.length || prefix.endsWith('/')) return true;
  const c = path[prefix.length];
  return c === '/' || c === '?' || c === '.';
}

class LoadShedder {
  /**
   * @param {object} o loop (LoopMonitor or null), metrics (Metrics or null), mode, lagMs, maxInflight, heapRatio,
   *   dbQueue () => number, holdMs, retryAfterS, extra (rules), clock, heapStats () => {used, limit}
   */
  constructor(o = {}) {
    const env = process.env;
    const num = (k, d) => { const n = Number(env[k]); return Number.isFinite(n) && env[k] !== '' && env[k] !== undefined ? n : d; };
    this.mode = String(o.mode || env.LOAD_SHED || (env.NODE_ENV === 'test' ? 'off' : 'on')).toLowerCase();
    if (!['on', 'off', 'force'].includes(this.mode)) this.mode = 'on';
    this.loop = o.loop || null;
    this.metrics = o.metrics || null;
    this.lagMs = o.lagMs ?? num('LOAD_SHED_LAG_MS', 250);
    this.maxInflight = o.maxInflight ?? num('LOAD_SHED_MAX_INFLIGHT', 200);
    this.heapRatio = o.heapRatio ?? num('LOAD_SHED_HEAP_RATIO', 0.9);
    this.dbQueueMax = o.dbQueueMax ?? num('LOAD_SHED_DB_QUEUE', 200);
    this.dbQueue = o.dbQueue || (() => 0);
    this.holdMs = o.holdMs ?? num('LOAD_SHED_HOLD_MS', 5000);
    this.retryAfterS = o.retryAfterS ?? num('LOAD_SHED_RETRY_AFTER_S', 15);
    this.clock = o.clock || Date.now;
    this.heapStats = o.heapStats || (() => { const h = v8.getHeapStatistics(); return { used: h.used_heap_size, limit: h.heap_size_limit }; });
    this.inflight = o.inflight || (() => (this.metrics ? this.metrics.inflight : 0));
    const extra = o.extra ?? String(env.LOAD_SHED_PATHS || '').split(',');
    this.rules = [...DEFAULT_SHED, ...extra].map(parseRule).filter(Boolean);
    this.never = NEVER.map((p) => p.toLowerCase());
    this.checkedAt = 0; this.lastOverAt = -Infinity; this.reason = '';
    this.stats = { shed: 0, overloadedChecks: 0 };
  }

  /** Can this request be shed at all? (Never for anything on the never-list, whatever the configuration.) */
  sheddable(method, rawPath) {
    const path = String(rawPath || '').split('?')[0].toLowerCase();
    if (this.never.some((p) => prefixMatch(path, p))) return false;
    const m = String(method || 'GET').toUpperCase();
    const mm = m === 'HEAD' ? 'GET' : m;
    return this.rules.some((r) => (!r.method || r.method === mm) && prefixMatch(path, r.prefix));
  }

  /** The reason the node is overloaded now ('' when it is not). */
  overloadReason() {
    const now = this.clock();
    if (now - this.checkedAt >= 250) {
      this.checkedAt = now;
      let reason = '';
      const loop = this.loop ? this.loop.current() : null;
      if (loop && loop.p99 > this.lagMs) reason = `event loop lag p99 ${Math.round(loop.p99)} ms`;
      else if (this.inflight() > this.maxInflight) reason = `${this.inflight()} requests in flight`;
      else {
        const h = this.heapStats();
        if (h.limit > 0 && h.used / h.limit > this.heapRatio) reason = `heap ${Math.round((100 * h.used) / h.limit)}%`;
        else if (this.dbQueue() > this.dbQueueMax) reason = `${this.dbQueue()} database calls queued`;
      }
      if (reason) { this.lastOverAt = now; this.reason = reason; this.stats.overloadedChecks++; }
    }
    if (now - this.lastOverAt <= this.holdMs) return this.reason || 'overloaded';
    return '';
  }

  shedding() {
    if (this.mode === 'off') return false;
    if (this.mode === 'force') return true;
    return !!this.overloadReason();
  }

  middleware() {
    return (req, res, next) => {
      if (this.mode === 'off') return next();
      // Cheap first: the overload state is re-evaluated at most every 250 ms.
      if (!this.shedding()) return next();
      if (!this.sheddable(req.method, req.originalUrl || req.url)) return next();
      this.stats.shed++;
      if (this.metrics) this.metrics.shed.inc({ route: require('./metrics').routeClass(req.originalUrl || req.url) });
      const retry = Math.max(1, Math.round(this.retryAfterS + Math.random() * 10));
      res.set('Retry-After', String(retry)).set('Cache-Control', 'no-store');
      return res.status(503).json({ error: 'CoRoute is very busy right now. Please try again in a moment.', code: 'BUSY', retryAfterSec: retry });
    };
  }
}

module.exports = { LoadShedder, NEVER, DEFAULT_SHED, parseRule, prefixMatch };
