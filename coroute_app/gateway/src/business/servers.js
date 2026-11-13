'use strict';
/**
 * Round 6 "Servers" page of the web admin: the health of both gateway nodes, read from the /metrics text each node
 * already serves (src/metrics.js). No Prometheus, no agent, nothing stored: one small sample per node is kept in
 * memory to turn counters into per-second rates.
 *
 *   this node   metrics.render()                          (no HTTP)
 *   the peer    GET <PEER_METRICS_URL>                    (default: the mirror peer's host, this node's PORT, /metrics;
 *               "Authorization: Bearer METRICS_TOKEN" when set, else the peer's METRICS_ALLOW must list this node)
 *
 * Thresholds are simple and fixed (owner-facing colours): ok / warn / bad. docs/intelligence/BUSINESS_ANALYTICS.md.
 */

/** Sums and picks the series the page needs from Prometheus text. Bounded: one pass, fixed output. */
function parseMetrics(text) {
  const out = { rssBytes: 0, heapUsedBytes: 0, heapLimitBytes: 0, uptimeS: 0, lagP99Ms: 0, lagMaxMs: 0, elu: 0, wsConnections: 0, roomsLoaded: 0, inflight: 0,
    dbCalls: 0, dbErrors: 0, httpRequests: 0, http5xx: 0, shedTotal: 0, shedding: 0, mirrorUp: null, dbQueue: 0, node: null, role: null, version: null };
  for (const line of String(text || '').split('\n')) {
    if (!line || line[0] === '#') continue;
    const sp = line.lastIndexOf(' ');
    if (sp < 0) continue;
    const v = Number(line.slice(sp + 1));
    if (!Number.isFinite(v)) continue;
    const head = line.slice(0, sp);
    const br = head.indexOf('{');
    const name = br < 0 ? head : head.slice(0, br);
    const labels = br < 0 ? '' : head.slice(br);
    switch (name) {
      case 'coroute_process_resident_memory_bytes': out.rssBytes = v; break;
      case 'coroute_process_heap_used_bytes': out.heapUsedBytes = v; break;
      case 'coroute_process_heap_limit_bytes': out.heapLimitBytes = v; break;
      case 'coroute_process_uptime_seconds': out.uptimeS = v; break;
      case 'coroute_event_loop_lag_ms': if (labels.includes('quantile="0.99"')) out.lagP99Ms = v; else if (labels.includes('quantile="1"')) out.lagMaxMs = v; break;
      case 'coroute_event_loop_utilization': out.elu = v; break;
      case 'coroute_ws_connections': out.wsConnections = v; break;
      case 'coroute_convoy_rooms_loaded': out.roomsLoaded = v; break;
      case 'coroute_http_inflight_requests': out.inflight = v; break;
      case 'coroute_db_calls_total': out.dbCalls += v; break;
      case 'coroute_db_errors_total': out.dbErrors += v; break;
      case 'coroute_http_requests_total': out.httpRequests += v; if (labels.includes('status="5xx"')) out.http5xx += v; break;
      case 'coroute_load_shed_total': out.shedTotal += v; break;
      case 'coroute_load_shedding': out.shedding = Math.max(out.shedding, v); break;
      case 'coroute_mirror_up': out.mirrorUp = v === 1; break;
      case 'coroute_db_queue_length': out.dbQueue = v; break;
      case 'coroute_node_info': {
        const pick = (k) => { const m = new RegExp(`${k}="([^"]*)"`).exec(labels); return m ? m[1] : null; };
        out.node = pick('node'); out.role = pick('role'); out.version = pick('version');
        break;
      }
      default: break;
    }
  }
  return out;
}

const level = (v, warn, bad) => (v >= bad ? 'bad' : v >= warn ? 'warn' : 'ok');
const worst = (list) => (list.includes('bad') ? 'bad' : list.includes('warn') ? 'warn' : 'ok');

/** The owner-facing view of one node: numbers, a colour per number, an overall colour and plain-language notes. */
function nodeView(m, { prev = null, at, memLimitMb = 1024, liveRiderCap = 0 } = {}) {
  const dt = prev && at > prev.at ? (at - prev.at) / 1000 : 0;
  // A restart resets the counters: no rate for that sample.
  const rate = (cur, old) => (dt >= 1 && cur >= old ? Math.round(((cur - old) / dt) * 10) / 10 : null);
  const rssMb = Math.round(m.rssBytes / 1048576);
  const heapPct = m.heapLimitBytes > 0 ? Math.round((m.heapUsedBytes / m.heapLimitBytes) * 100) : 0;
  const memPct = memLimitMb > 0 ? Math.round((rssMb / memLimitMb) * 100) : 0;
  const shedDelta = prev && m.shedTotal >= prev.shedTotal ? m.shedTotal - prev.shedTotal : 0;
  const checks = {
    lag: level(m.lagP99Ms, 50, 150),
    memory: worst([level(memPct, 70, 85), level(heapPct, 75, 90)]),
    riders: liveRiderCap > 0 ? level(m.wsConnections / liveRiderCap, 0.8, 0.95) : 'ok',
    shedding: m.shedding ? 'bad' : (shedDelta > 0 ? 'warn' : 'ok'),
    database: worst([level(m.dbQueue, 20, 100), prev && dt >= 1 && m.dbErrors - prev.dbErrors > 0 ? 'warn' : 'ok']),
    mirror: m.mirrorUp === false ? 'warn' : 'ok',
  };
  const notes = [];
  if (checks.lag !== 'ok') notes.push(`The server is answering slowly (event loop lag ${Math.round(m.lagP99Ms)} ms; fine below 50).`);
  if (checks.memory !== 'ok') notes.push(`Memory is ${memPct}% of the ${memLimitMb} MB VM (heap ${heapPct}%).`);
  if (checks.riders !== 'ok') notes.push(`Riders online are close to LIVE_RIDER_CAP (${m.wsConnections} of ${liveRiderCap}).`);
  if (m.shedding) notes.push('Load shedding is ON: non-essential reads get "try again" answers. SOS, rides and sign-in are never shed.');
  else if (shedDelta > 0) notes.push(`${shedDelta} non-essential requests were shed since the last look.`);
  if (checks.database !== 'ok') notes.push(m.dbQueue >= 20 ? `${m.dbQueue} database calls are waiting for a slot.` : 'Some database calls failed since the last look.');
  if (checks.mirror !== 'ok') notes.push('The link to the other node is down: a failover would lose the last seconds of ride state.');
  return {
    node: m.node, role: m.role, version: m.version, uptimeS: m.uptimeS,
    ridersOnline: m.wsConnections, roomsLoaded: m.roomsLoaded, lagP99Ms: Math.round(m.lagP99Ms * 10) / 10, lagMaxMs: Math.round(m.lagMaxMs * 10) / 10,
    rssMb, memPct, heapPct, memLimitMb, dbCallsPerSec: rate(m.dbCalls, prev ? prev.dbCalls : 0), httpPerSec: rate(m.httpRequests, prev ? prev.httpRequests : 0),
    dbQueue: m.dbQueue, shedTotal: m.shedTotal, shedding: !!m.shedding, mirrorUp: m.mirrorUp, checks, status: worst(Object.values(checks)), notes,
  };
}

/** Peer /metrics URL: PEER_METRICS_URL, else derived from the mirror peer (ws://host:3101/mirror -> http://host:PORT/metrics). */
function peerMetricsUrl(env = process.env, config = {}) {
  const own = String(env.PEER_METRICS_URL || '').trim();
  if (own) return /^https?:\/\//i.test(own) ? own : null;
  const peer = String(config.mirrorPeerUrl || env.MIRROR_PEER_URL || '').trim();
  if (!peer) return null;
  try { const u = new URL(peer); return `http://${u.hostname}:${Number(config.port) || 3000}/metrics`; } catch { return null; }
}

class ServerHealth {
  constructor({ metrics, lease = null, soda = null, config = {}, env = process.env, fetchImpl = globalThis.fetch, clock = Date.now, node = '', role = '' } = {}) {
    this.metrics = metrics; this.lease = lease; this.soda = soda; this.config = config; this.env = env; this.fetch = fetchImpl; this.clock = clock; this.node = node; this.role = role;
    this.prev = new Map(); // node key -> last sample (bounded: this node and the peer)
    this.memLimitMb = Math.max(128, Number(env.NODE_MEMORY_MB) || 1024);
  }

  _view(key, m, at) {
    const prev = this.prev.get(key) || null;
    const view = nodeView(m, { prev, at, memLimitMb: this.memLimitMb, liveRiderCap: Number(this.config.liveRiderCap) || 0 });
    // Keep a sample at most every 5 s, so two admins looking at once still get a rate.
    if (!prev || at - prev.at >= 5000) this.prev.set(key, { at, dbCalls: m.dbCalls, dbErrors: m.dbErrors, httpRequests: m.httpRequests, shedTotal: m.shedTotal });
    return view;
  }

  async _peer() {
    const url = peerMetricsUrl(this.env, this.config);
    if (!url) return null;
    const token = String(this.config.metricsToken || this.env.METRICS_TOKEN || '');
    try {
      const res = await this.fetch(url, { headers: token ? { Authorization: `Bearer ${token}` } : {}, signal: AbortSignal.timeout(2500) });
      if (!res.ok) return { reachable: false, status: 'bad', error: res.status === 404 ? 'The other node does not allow this one to read /metrics (METRICS_ALLOW or METRICS_TOKEN).' : `The other node answered ${res.status}.`, notes: [] };
      const text = await res.text();
      if (text.length > 2 * 1024 * 1024) return { reachable: false, status: 'warn', error: 'The other node sent too much data.', notes: [] };
      return { reachable: true, self: false, ...this._view('peer', parseMetrics(text), this.clock()) };
    } catch (e) {
      return { reachable: false, status: 'bad', error: `The other node did not answer (${String(e && (e.name === 'TimeoutError' ? 'timeout' : e.code || e.message)).slice(0, 60)}).`, notes: [] };
    }
  }

  /** Last runs of the scheduled jobs (from the shared lease documents) with a colour when one is overdue. */
  async jobs() {
    if (!this.soda) return [];
    const now = this.clock();
    const rows = await this.soda.query('leases', {}, { limit: 200 }).catch(() => []);
    const intervals = new Map();
    if (this.lease && this.lease.jobs) for (const [name, j] of this.lease.jobs) intervals.set(name, j.once ? 0 : Number(j.intervalMs) || 0);
    return rows.map((r) => r.value).filter((d) => d && d.name).map((d) => {
      const every = intervals.get(d.name) || 0;
      const last = Number(d.lastRunAt) || 0;
      const overdue = every > 0 && last > 0 && now - last > Math.max(every * 2.5, every + 10 * 60000);
      const never = every > 0 && !last && Number(d.expiresAt) > 0;
      return { name: d.name, lastRunAt: last, lastRunBy: d.lastRunBy || null, heldBy: d.node || null, role: d.role || null, everyMs: every, known: intervals.has(d.name),
        status: overdue ? 'warn' : 'ok', note: overdue ? 'Later than expected.' : (never ? 'Has not run yet.' : '') };
    }).sort((a, b) => a.name.localeCompare(b.name));
  }

  /** Age of the last encrypted backup (the backup job writes a small status document after every run). */
  async backup() {
    if (!this.soda) return { known: false };
    const now = this.clock();
    const rows = await this.soda.query('ops_status', { kind: 'backup' }, { limit: 10 }).catch(() => []);
    if (!rows.length) return { known: false, status: 'warn', note: 'No backup has reported yet (backups are off until BACKUP_PAR_URL and BACKUP_ENCRYPTION_KEY are set).' };
    const sets = rows.map((r) => r.value).map((v) => ({ set: v.set, at: Number(v.at) || 0, ok: v.ok !== false, documents: Number(v.documents) || 0, error: v.error || null }));
    const full = sets.find((s) => s.set === 'full'); const critical = sets.find((s) => s.set === 'critical');
    const ageH = (s) => (s && s.at ? Math.round(((now - s.at) / 3600000) * 10) / 10 : null);
    const status = worst([
      full ? (!full.ok ? 'bad' : level(ageH(full), 26, 50)) : 'warn',
      critical ? (!critical.ok ? 'bad' : level(ageH(critical), 3, 12)) : 'warn',
    ]);
    return { known: true, status, sets, fullAgeHours: ageH(full), criticalAgeHours: ageH(critical),
      note: status === 'ok' ? '' : (!full ? 'The daily full backup has not run yet.' : (status === 'bad' ? 'The last backup failed or is more than two days old.' : 'A backup is older than expected.')) };
  }

  async snapshot() {
    const at = this.clock();
    const own = parseMetrics(this.metrics.render());
    // A single node has no mirror link to be down.
    if (!peerMetricsUrl(this.env, this.config) && !this.config.mirrorListenHost) own.mirrorUp = null;
    const self = { reachable: true, self: true, ...this._view('self', own, at) };
    if (!self.node) self.node = this.node;
    if (!self.role) self.role = this.role;
    const [peer, jobs, backup] = await Promise.all([this._peer(), this.jobs(), this.backup()]);
    const nodes = [self];
    if (peer) nodes.push(peer);
    const status = worst([...nodes.map((n) => n.status), ...jobs.map((j) => j.status), backup.status || 'ok']);
    return { at, status, nodes, peerConfigured: !!peerMetricsUrl(this.env, this.config), jobs, backup,
      thresholds: { lagMs: [50, 150], memoryPct: [70, 85], heapPct: [75, 90], dbQueue: [20, 100], fullBackupHours: [26, 50], criticalBackupHours: [3, 12] } };
  }
}

module.exports = { ServerHealth, parseMetrics, nodeView, peerMetricsUrl };
