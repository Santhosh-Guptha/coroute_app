'use strict';
/**
 * Process metrics in the Prometheus text format (v0.0.4), with no dependencies.
 *
 *   GET /metrics   allowed only from METRICS_ALLOW (IPs / CIDRs, default loopback: run `curl` on the VM itself)
 *                  or with "Authorization: Bearer <METRICS_TOKEN>" when that secret is set. Everyone else: 404.
 *                  Caddy also answers 404 for /metrics from the internet (deploy/caddy/*), so it never leaves the VM.
 *
 * What is measured (cheap: counters and fixed-bucket histograms, no per-request allocation beyond a timer):
 *   - event loop: delay p50/p99/max (perf_hooks.monitorEventLoopDelay, 20 ms resolution) and utilisation (ELU)
 *   - process: RSS, heap used / total / limit, external, uptime, CPU seconds
 *   - HTTP: requests by method, route class and status class; latency histogram by route class; in-flight
 *   - WebSocket: open sockets, rooms, the Hub's position counters (in, out, coalesced, dropped, batched ...)
 *   - database: SODA calls by operation and collection (count, errors, latency histogram) through instrumentSoda()
 *   - caches: user gate and session reads; load shedding: shed requests by class
 * Route classes keep the label set small and free of ids: the first two path segments with ids folded (/api/convoys).
 */
const { performance, monitorEventLoopDelay } = require('perf_hooks');
const v8 = require('v8');
const net = require('net');
const crypto = require('crypto');

const DEFAULT_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10];

const esc = (v) => String(v).replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/"/g, '\\"');
const labelKey = (labels) => Object.keys(labels).sort().map((k) => `${k}="${esc(labels[k])}"`).join(',');

class Counter {
  constructor(name, help) { this.name = name; this.help = help; this.values = new Map(); }
  inc(labels = {}, n = 1) { const k = labelKey(labels); this.values.set(k, (this.values.get(k) || 0) + n); }
  /** Hot path: the caller passes an already rendered label string (no sorting per call). */
  incKey(k, n = 1) { this.values.set(k, (this.values.get(k) || 0) + n); }
  get(labels = {}) { return this.values.get(labelKey(labels)) || 0; }
  render() {
    const out = [`# HELP ${this.name} ${this.help}`, `# TYPE ${this.name} counter`];
    for (const [k, v] of this.values) out.push(`${this.name}${k ? `{${k}}` : ''} ${v}`);
    return out.join('\n');
  }
}

class Gauge {
  constructor(name, help, collect = null) { this.name = name; this.help = help; this.values = new Map(); this.collect = collect; }
  set(labels, v) { this.values.set(labelKey(labels || {}), v); }
  render() {
    if (this.collect) { try { this.collect(this); } catch { /* a broken collector never breaks /metrics */ } }
    const out = [`# HELP ${this.name} ${this.help}`, `# TYPE ${this.name} gauge`];
    for (const [k, v] of this.values) if (Number.isFinite(v)) out.push(`${this.name}${k ? `{${k}}` : ''} ${v}`);
    return out.join('\n');
  }
}

class Histogram {
  constructor(name, help, buckets = DEFAULT_BUCKETS) { this.name = name; this.help = help; this.buckets = buckets; this.series = new Map(); }
  observe(labels, seconds) { this.observeKey(labelKey(labels || {}), seconds); }
  observeKey(k, seconds) {
    let s = this.series.get(k);
    if (!s) { s = { counts: new Array(this.buckets.length).fill(0), sum: 0, count: 0 }; this.series.set(k, s); }
    s.sum += seconds; s.count++;
    for (let i = 0; i < this.buckets.length; i++) if (seconds <= this.buckets[i]) { s.counts[i]++; break; }
  }
  render() {
    const out = [`# HELP ${this.name} ${this.help}`, `# TYPE ${this.name} histogram`];
    for (const [k, s] of this.series) {
      let acc = 0;
      const pre = k ? `${k},` : '';
      for (let i = 0; i < this.buckets.length; i++) { acc += s.counts[i]; out.push(`${this.name}_bucket{${pre}le="${this.buckets[i]}"} ${acc}`); }
      out.push(`${this.name}_bucket{${pre}le="+Inf"} ${s.count}`);
      out.push(`${this.name}_sum${k ? `{${k}}` : ''} ${+s.sum.toFixed(6)}`);
      out.push(`${this.name}_count${k ? `{${k}}` : ''} ${s.count}`);
    }
    return out.join('\n');
  }
}

/** /api/convoys/GRP-12AB/riders/usr_x -> /api/convoys ; /assets/site.css -> /assets ; / -> / */
function routeClass(path) {
  const p = String(path || '/').split('?')[0].toLowerCase();
  const seg = p.split('/').filter(Boolean);
  if (!seg.length) return '/';
  if (seg[0] !== 'api') return `/${/^[a-z0-9_.-]{1,24}$/.test(seg[0]) && !/\d{3,}/.test(seg[0]) ? seg[0] : ':page'}`;
  const second = seg[1] && /^[a-z][a-z0-9_-]{0,23}$/.test(seg[1]) && !/\d{3,}/.test(seg[1]) ? seg[1] : (seg[1] ? ':id' : '');
  return `/api${second ? `/${second}` : ''}`;
}

/** Event loop delay and utilisation, sampled continuously (one native histogram, reset every window). */
class LoopMonitor {
  constructor({ resolutionMs = 20, windowMs = 5000 } = {}) {
    this.h = monitorEventLoopDelay({ resolution: resolutionMs });
    this.h.enable();
    this.resolutionMs = resolutionMs;
    this.last = { p50: 0, p99: 0, max: 0, mean: 0, elu: 0 };
    this.elu = performance.eventLoopUtilization();
    this.timer = setInterval(() => this.sample(), windowMs);
    if (this.timer.unref) this.timer.unref();
  }
  /** Lag beyond the timer resolution, in ms (0 = on time). */
  _lag(ns) { return Math.max(0, ns / 1e6 - this.resolutionMs); }
  sample() {
    const e = performance.eventLoopUtilization(this.elu);
    this.elu = performance.eventLoopUtilization();
    if (this.h.count > 0 || this.h.max > 0) {
      this.last = { p50: this._lag(this.h.percentile(50)), p99: this._lag(this.h.percentile(99)), max: this._lag(this.h.max), mean: this._lag(this.h.mean), elu: e.utilization };
    } else this.last = { ...this.last, elu: e.utilization };
    this.h.reset();
    return this.last;
  }
  /** The current window so far (not reset), for load shedding decisions between samples. */
  current() {
    if (!this.h.count) return this.last;
    return { ...this.last, p99: Math.max(this.last.p99, this._lag(this.h.percentile(99))), max: Math.max(this.last.max, this._lag(this.h.max)) };
  }
  stop() { clearInterval(this.timer); this.h.disable(); }
}

class Metrics {
  constructor({ allow = ['loopback'], token = '', loop = true } = {}) {
    this.startedAt = Date.now();
    this.allow = allowList(allow);
    this.token = String(token || '');
    this.loop = loop ? new LoopMonitor() : null;
    this.inflight = 0;
    this.httpRequests = new Counter('coroute_http_requests_total', 'HTTP requests by method, route class and status class.');
    this.httpDuration = new Histogram('coroute_http_request_duration_seconds', 'HTTP request duration by route class.');
    this.dbCalls = new Counter('coroute_db_calls_total', 'SODA calls by operation and collection.');
    this.dbErrors = new Counter('coroute_db_errors_total', 'Failed SODA calls by operation and collection.');
    this.dbDuration = new Histogram('coroute_db_call_duration_seconds', 'SODA call duration by operation.', [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 6]);
    this.shed = new Counter('coroute_load_shed_total', 'Requests answered 503 by load shedding, by route class.');
    this.events = new Counter('coroute_events_total', 'Notable events (ws_slow_kick, ws_batch_frames, ...).');
    this.sources = []; // () => [{ name, help, type:'gauge'|'counter', values: [[labels, v]] }]
  }

  /** Registers a collector called at scrape time (hub stats, cache reads, ...). */
  source(fn) { this.sources.push(fn); }

  /** Express middleware: counts and times every request (the route class is taken from the path, never ids). */
  middleware() {
    return (req, res, next) => {
      const t0 = process.hrtime.bigint();
      this.inflight++;
      let done = false;
      const finish = () => {
        if (done) return; done = true;
        this.inflight--;
        const cls = routeClass(req.originalUrl || req.url);
        const status = Math.floor(res.statusCode / 100);
        // Label strings built in sorted key order (method, route, status) without a sort per request.
        this.httpRequests.incKey(`method="${esc(req.method)}",route="${esc(cls)}",status="${status}xx"`);
        this.httpDuration.observeKey(`route="${esc(cls)}"`, Number(process.hrtime.bigint() - t0) / 1e9);
      };
      res.once('finish', finish);
      res.once('close', finish);
      next();
    };
  }

  /** May this request read /metrics? Loopback / METRICS_ALLOW by the trusted client IP, or the bearer token. */
  allowed(req) {
    const auth = String(req.get ? req.get('authorization') || '' : '');
    if (this.token && auth.startsWith('Bearer ')) {
      const a = Buffer.from(auth.slice(7)); const b = Buffer.from(this.token);
      if (a.length === b.length && crypto.timingSafeEqual(a, b)) return true;
    }
    return ipAllowed(req.ip || (req.socket && req.socket.remoteAddress) || '', this.allow);
  }

  handler() {
    return (req, res) => {
      if (!this.allowed(req)) return res.status(404).json({ error: 'Not found' });
      res.set('Cache-Control', 'no-store').type('text/plain; version=0.0.4; charset=utf-8').send(this.render());
    };
  }

  render() {
    const parts = [];
    const mem = process.memoryUsage();
    const heap = v8.getHeapStatistics();
    const cpu = process.cpuUsage();
    const g = (name, help, v, labels) => {
      const k = labels ? labelKey(labels) : '';
      return `# HELP ${name} ${help}\n# TYPE ${name} gauge\n${name}${k ? `{${k}}` : ''} ${Number.isFinite(v) ? v : 0}`;
    };
    parts.push(g('coroute_process_resident_memory_bytes', 'Resident set size.', mem.rss));
    parts.push(g('coroute_process_heap_used_bytes', 'V8 heap used.', mem.heapUsed));
    parts.push(g('coroute_process_heap_total_bytes', 'V8 heap allocated.', mem.heapTotal));
    parts.push(g('coroute_process_heap_limit_bytes', 'V8 heap limit (--max-old-space-size).', heap.heap_size_limit));
    parts.push(g('coroute_process_external_bytes', 'Buffers and external memory.', mem.external + (mem.arrayBuffers || 0)));
    parts.push(g('coroute_process_cpu_seconds_total', 'User + system CPU seconds since start.', (cpu.user + cpu.system) / 1e6));
    parts.push(g('coroute_process_uptime_seconds', 'Seconds since the gateway started.', Math.round((Date.now() - this.startedAt) / 1000)));
    parts.push(g('coroute_http_inflight_requests', 'HTTP requests being handled now.', this.inflight));
    if (this.loop) {
      const l = this.loop.current();
      parts.push(`# HELP coroute_event_loop_lag_ms Event loop delay beyond the timer (last 5 s window).\n# TYPE coroute_event_loop_lag_ms gauge\n`
        + `coroute_event_loop_lag_ms{quantile="0.5"} ${+l.p50.toFixed(2)}\ncoroute_event_loop_lag_ms{quantile="0.99"} ${+l.p99.toFixed(2)}\ncoroute_event_loop_lag_ms{quantile="1"} ${+l.max.toFixed(2)}`);
      parts.push(g('coroute_event_loop_utilization', 'Share of time the event loop was busy (last 5 s window).', +l.elu.toFixed(4)));
    }
    for (const m of [this.httpRequests, this.httpDuration, this.dbCalls, this.dbErrors, this.dbDuration, this.shed, this.events]) {
      if (m.values ? m.values.size : m.series.size) parts.push(m.render());
    }
    for (const src of this.sources) {
      let list = [];
      try { list = src() || []; } catch { list = []; }
      for (const s of list) {
        const lines = [`# HELP ${s.name} ${s.help}`, `# TYPE ${s.name} ${s.type || 'gauge'}`];
        for (const [labels, v] of s.values) {
          const k = labels ? labelKey(labels) : '';
          if (Number.isFinite(v)) lines.push(`${s.name}${k ? `{${k}}` : ''} ${v}`);
        }
        parts.push(lines.join('\n'));
      }
    }
    return `${parts.join('\n')}\n`;
  }

  stop() { if (this.loop) this.loop.stop(); }
}

/** Wraps a SODA client: every call is counted and timed per operation and collection. Same API. */
const SODA_OPS = new Set(['ping', 'listCollections', 'ensureCollection', 'ensureIndex', 'compareAndReplace', 'insert', 'insertMany',
  'replace', 'get', 'remove', 'query', 'findOne', 'upsertBy', 'removeWhere', 'seedRev']);
function instrumentSoda(soda, metrics) {
  if (!soda || !metrics) return soda;
  return new Proxy(soda, {
    get(target, prop, recv) {
      const v = Reflect.get(target, prop, recv);
      if (typeof v !== 'function' || !SODA_OPS.has(prop)) return v;
      return function instrumented(...args) {
        const labels = { op: prop, collection: typeof args[0] === 'string' ? args[0] : '' };
        metrics.dbCalls.inc(labels);
        const t0 = process.hrtime.bigint();
        const end = (ok) => {
          metrics.dbDuration.observe({ op: prop }, Number(process.hrtime.bigint() - t0) / 1e9);
          if (!ok) metrics.dbErrors.inc(labels);
        };
        let r;
        try { r = v.apply(target, args); } catch (e) { end(false); throw e; }
        if (r && typeof r.then === 'function') return r.then((x) => { end(true); return x; }, (e) => { end(false); throw e; });
        end(true);
        return r;
      };
    },
  });
}

// ------------------------------------------------------------------ IP allow list
function allowList(items) {
  const out = [];
  for (const raw of (Array.isArray(items) ? items : String(items || '').split(','))) {
    const it = String(raw).trim();
    if (!it) continue;
    if (it === 'loopback') { out.push({ cidr: '127.0.0.0', bits: 8, fam: 4 }, { cidr: '::1', bits: 128, fam: 6 }); continue; }
    const [ip, bits] = it.split('/');
    const fam = net.isIP(ip);
    if (!fam) throw new Error(`[metrics] METRICS_ALLOW entry "${it}" is not an IP or CIDR`);
    out.push({ cidr: ip, bits: bits === undefined ? (fam === 4 ? 32 : 128) : Number(bits), fam });
  }
  return out;
}

function ipAllowed(ip, list) {
  let a = String(ip || '');
  if (a.startsWith('::ffff:') && net.isIPv4(a.slice(7))) a = a.slice(7);
  const fam = net.isIP(a);
  if (!fam) return false;
  const bl = new net.BlockList();
  for (const e of list) {
    if (e.fam !== fam) continue;
    bl.addSubnet(e.cidr, e.bits, fam === 4 ? 'ipv4' : 'ipv6');
  }
  return bl.check(a, fam === 4 ? 'ipv4' : 'ipv6');
}

module.exports = { Metrics, LoopMonitor, Counter, Gauge, Histogram, instrumentSoda, routeClass, ipAllowed, allowList };
