'use strict';
/**
 * Round 8 abuse limits for the WebSocket hub (HIGH_TRAFFIC_PLAN_v3.57 items 5 / section 10). Pure helpers, no I/O:
 * the Hub (src/ws.js) calls them and owns the sockets.
 *
 *   per IP        concurrent sockets (WS_MAX_CONN_PER_IP, default 50: NAT-friendly, a whole office or a mobile
 *                 carrier's CGNAT exit shares one address) and new sockets per minute (WS_CONN_PER_MIN_PER_IP, 120).
 *                 Refused at the upgrade with HTTP 429 + Retry-After (no socket is created). The IP is the trusted
 *                 client address (X-Forwarded-For walked right to left through TRUST_PROXY, like Express). A direct
 *                 loopback connection WITHOUT X-Forwarded-For (tests, tools on the VM itself) is not counted;
 *                 Caddy always adds the header.
 *   per user      new sockets per account (WS_CONN_PER_MIN_PER_USER, burst 30, refill 1 per 2 s) -> close 4429
 *                 TOO_MANY_CONNECTS; open sockets per account stay bounded by WS_MAX_SOCKETS_PER_USER (oldest out).
 *   per socket    token buckets per message class ("rate/burst"):
 *                   pos   WS_RL_POS   (5/20)   TELEMETRY, P2, binary telemetry 0x10
 *                   chat  WS_RL_CHAT  (2/10)   CHAT, CHAT_REPORT, PR_*, ROAD_WARN*
 *                   join  WS_RL_JOIN  (0.2/6)  JOIN, LEAVE  (+ JOIN refusals: WS_JOIN_FAIL_MAX per minute -> 4429 JOIN_FLOOD)
 *                   ping  WS_RL_PING  (1/10)   PING, AUTH, BYE
 *                   other WS_RL_OTHER (10/40)  everything else that is not safety
 *                 These sit OUTSIDE the existing per-type budgets (3 positions/s, WS_ACTIONS_PER_SEC, ...) which keep
 *                 working exactly as before; this layer only catches broken or hostile clients. A message over its
 *                 bucket is dropped and the socket gets a warning frame { type: 'RATE_LIMIT', class, retryMs } at most
 *                 once per 5 s per class (old apps ignore unknown types). Every drop also costs one "strike" token
 *                 (WS_RL_KICK_DROPS per 10 s, default 60): a socket that keeps flooding is closed with 4429
 *                 RATE_LIMIT_<CLASS>. Invalid frames (schema / size) have their own small budget -> 4400 INVALID_FRAMES.
 *   SAFETY        SOS, SOS_RESPOND, SOS_RESOLVE, WAIT, CHECK_IN, REPORT_DOWN, LAST_GASP_BEACON, ASSIST_ANSWER, MESH_BRIDGE are
 *                 never counted, never dropped and never rejected by the schema check (the convoy code clamps
 *                 their fields). The existing SOS-per-10-s budget gets a floor (WS_SOS_FLOOR_PER_10S, 10) and an SOS
 *                 above even that is answered with the rider's open alert instead of an error (see ws.js).
 *   timeouts      sockets that are not in a ride and sent nothing for WS_IDLE_MS (2 h) close 4408 IDLE_TIMEOUT (the
 *                 app reconnects when it needs to); a peer whose send buffer stays above WS_OUT_SOFT_BYTES for
 *                 WS_SLOW_READER_MS (60 s) closes 1013 SLOW_LINK (it reconnects and gets a SNAPSHOT).
 * Every limit has a counter in hub.stats (coroute_ws_events_total{kind="rl..."} on /metrics).
 */
const net = require('net');

const num = (v, d) => { const n = Number(v); return v !== undefined && v !== '' && Number.isFinite(n) && n >= 0 ? n : d; };

/** "rate/burst" (tokens per second / capacity) with defaults. */
function rateSpec(v, rate, burst) {
  const m = /^\s*([0-9.]+)\s*\/\s*([0-9.]+)\s*$/.exec(String(v || ''));
  if (!m) return { rate, burst };
  const r = Number(m[1]); const b = Number(m[2]);
  return { rate: Number.isFinite(r) && r > 0 ? r : rate, burst: Number.isFinite(b) && b >= 1 ? b : burst };
}

/** Settings read once (tests override through the constructor of the Hub or by env before require). */
function limitsConfig(env = process.env) {
  return {
    maxConnPerIp: num(env.WS_MAX_CONN_PER_IP, 50),
    connPerMinPerIp: num(env.WS_CONN_PER_MIN_PER_IP, 120),
    connPerMinPerUser: num(env.WS_CONN_PER_MIN_PER_USER, 30),
    pos: rateSpec(env.WS_RL_POS, 5, 20),
    chat: rateSpec(env.WS_RL_CHAT, 2, 10),
    join: rateSpec(env.WS_RL_JOIN, 0.2, 6),
    ping: rateSpec(env.WS_RL_PING, 1, 10),
    other: rateSpec(env.WS_RL_OTHER, 10, 40),
    invalid: { rate: 0.2, burst: 8 },
    kickDrops: Math.max(5, num(env.WS_RL_KICK_DROPS, 60)),
    joinFailMax: Math.max(2, num(env.WS_JOIN_FAIL_MAX, 8)),
    sosFloorPer10s: Math.max(3, num(env.WS_SOS_FLOOR_PER_10S, 10)),
    idleMs: num(env.WS_IDLE_MS, 2 * 3600000),
    slowReaderMs: num(env.WS_SLOW_READER_MS, 60000),
    warnEveryMs: 5000,
  };
}

class TokenBucket {
  constructor(rate, burst, t = Date.now()) { this.rate = rate; this.burst = burst; this.tokens = burst; this.at = t; }
  _refill(t) {
    if (t > this.at) { this.tokens = Math.min(this.burst, this.tokens + ((t - this.at) / 1000) * this.rate); this.at = t; }
  }
  take(t = Date.now(), n = 1) {
    this._refill(t);
    if (this.tokens >= n) { this.tokens -= n; return true; }
    return false;
  }
  full(t = Date.now()) { this._refill(t); return this.tokens >= this.burst; }
  /** Milliseconds until one token is back. */
  waitMs(t = Date.now()) { this._refill(t); return this.tokens >= 1 ? 0 : Math.ceil(((1 - this.tokens) / this.rate) * 1000); }
}

/** Never counted, never dropped, never schema-rejected. */
// Round 10: MESH_BRIDGE can carry an SOS from a rider without signal (src/mesh_bridge.js does its own frame count,
// size and per-second limits for everything that is not an SOS).
const SAFETY = new Set(['SOS', 'SOS_RESPOND', 'SOS_RESOLVE', 'WAIT', 'CHECK_IN', 'REPORT_DOWN', 'LAST_GASP_BEACON', 'ASSIST_ANSWER', 'MESH_BRIDGE']);
const CLASS_OF = new Map([
  ['TELEMETRY', 'pos'], ['P2', 'pos'],
  ['CHAT', 'chat'], ['CHAT_REPORT', 'chat'], ['ROAD_WARN', 'chat'], ['ROAD_WARN_VOTE', 'chat'],
  ['JOIN', 'join'], ['LEAVE', 'join'],
  ['PING', 'ping'], ['AUTH', 'ping'], ['BYE', 'ping'],
]);
/** The limiter class of an inbound message type ('safety' = exempt). */
function classOf(type) {
  if (SAFETY.has(type)) return 'safety';
  const c = CLASS_OF.get(type);
  if (c) return c;
  if (typeof type === 'string' && type.startsWith('PR_')) return 'chat';
  return 'other';
}

/** Largest accepted JSON frame per type (bytes); the rest: DEFAULT_MAX. The ws layer caps every frame at 256 KB. */
const DEFAULT_MAX = 16 * 1024;
const MAX_BYTES = new Map([
['P2', 1024], ['PING', 512], ['BYE', 512], ['AUTH', 4608], ['JOIN', 2048], ['LEAVE', 512],
  ['CHAT', 8192], ['CHAT_REPORT', 4096], ['MIC_STATE', 512], ['STATUS', 2048], ['CORIDER', 1024],
  ['ROUTE_SET', 256 * 1024], ['TRACK', 256 * 1024], ['STOP_ADD', 32 * 1024], ['STOP_SUGGEST', 32 * 1024], ['STOP_REORDER', 32 * 1024],
  ['CONFIG', 32 * 1024], ['TIMELINE_SINCE', 1024], ['ROAD_HAZARD', 4096], ['SIGNAL_AHEAD', 8192], ['RIDER_VEHICLE', 4096],
  ['MESH_HELLO', 512],
]);
const TYPE_RE = /^[A-Za-z0-9_]{1,32}$/;
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const MAX_KEYS = 64;

/**
 * Schema / size check of one parsed inbound JSON message. Returns '' when acceptable, else a short reason.
 * Deliberately structural only: the convoy code already coerces every field (junk numbers become 0, an invalid
 * clientId counts as absent, unknown types get "Unknown message type"), and old app builds must keep working.
 * What is refused here: a missing / non-word type, a frame larger than its type needs, an object with more top-level
 * keys than any real message has (hash flooding), and JOIN caps / P2 fields of the wrong shape. Safety types always pass.
 */
function validateInbound(msg, bytes) {
  if (!msg || typeof msg !== 'object' || Array.isArray(msg)) return 'not_object';
  const type = msg.type;
  if (typeof type !== 'string' || !TYPE_RE.test(type)) return 'bad_type';
  if (SAFETY.has(type)) return '';
  const max = MAX_BYTES.get(type) || DEFAULT_MAX;
  if (bytes > max) return 'too_big';
  let keys = 0;
  for (const k in msg) { if (Object.hasOwn(msg, k) && ++keys > MAX_KEYS) return 'too_many_keys'; }
  switch (type) {
    case 'JOIN':
      if (msg.caps !== undefined && msg.caps !== null && (!Array.isArray(msg.caps) || msg.caps.length > 32)) return 'bad_caps';
      return '';
    case 'P2':
      for (const k of ['q', 'a', 'o', 'da', 'do', 'k', 'v', 'h', 'b', 'ss', 'fl']) if (msg[k] !== undefined && msg[k] !== null && !isNum(msg[k])) return 'bad_number';
      return '';
    default:
      return '';
  }
}

// ------------------------------------------------------------------ client IP behind trusted proxies
const KEYWORDS = {
  loopback: [['127.0.0.0', 8, 'ipv4'], ['::1', 128, 'ipv6']],
  linklocal: [['169.254.0.0', 16, 'ipv4'], ['fe80::', 10, 'ipv6']],
  uniquelocal: [['10.0.0.0', 8, 'ipv4'], ['172.16.0.0', 12, 'ipv4'], ['192.168.0.0', 16, 'ipv4'], ['fc00::', 7, 'ipv6']],
};
const plain = (a) => { const s = String(a || '').trim(); return s.startsWith('::ffff:') && net.isIPv4(s.slice(7)) ? s.slice(7) : s; };

/** TRUST_PROXY list (config.trustProxy) -> predicate(address). */
function trustFn(items = ['loopback']) {
  const bl = new net.BlockList();
  for (const raw of items) {
    const it = String(raw).trim();
    if (KEYWORDS[it]) { for (const [a, b, f] of KEYWORDS[it]) bl.addSubnet(a, b, f); continue; }
    const [ip, bits] = it.split('/');
    const fam = net.isIP(ip);
    if (!fam) continue;
    bl.addSubnet(ip, bits === undefined ? (fam === 4 ? 32 : 128) : Number(bits), fam === 4 ? 'ipv4' : 'ipv6');
  }
  return (addr) => { const a = plain(addr); const f = net.isIP(a); return !!f && bl.check(a, f === 4 ? 'ipv4' : 'ipv6'); };
}

const LOOP = trustFn(['loopback']);
/**
 * The client address of an upgrade request: X-Forwarded-For walked right to left while the hop is trusted.
 * key: what the per-IP limiter counts, or null for a direct loopback connection without X-Forwarded-For.
 */
function clientIpOf(req, trusted) {
  const sock = plain(req && req.socket && req.socket.remoteAddress);
  const xff = String((req && req.headers && req.headers['x-forwarded-for']) || '').trim();
  let ip = sock;
  if (xff && trusted(sock)) {
    const hops = xff.split(',').map((h) => plain(h)).filter(Boolean);
    for (let i = hops.length - 1; i >= 0; i--) {
      ip = hops[i];
      if (!net.isIP(ip)) { ip = sock; break; }
      if (!trusted(ip)) break;
    }
  }
  const key = !xff && LOOP(sock) ? null : (net.isIP(ip) ? ip : sock || null);
  return { ip, key };
}

/** Concurrent sockets and new sockets per minute per client IP. */
class IpConnLimiter {
  constructor({ maxPerIp = 50, perMin = 120 } = {}, clock = Date.now) {
    this.maxPerIp = maxPerIp; this.perMin = perMin; this.clock = clock;
    this.open = new Map(); // ip -> open count
    this.rate = new Map(); // ip -> TokenBucket
  }
  /** { ok, reason } and, when ok, the slot is held until release(key). */
  admit(key) {
    if (!key) return { ok: true };
    const t = this.clock();
    if (this.perMin > 0) {
      let b = this.rate.get(key);
      if (!b) { b = new TokenBucket(this.perMin / 60, this.perMin, t); this.rate.set(key, b); }
      if (!b.take(t)) return { ok: false, reason: 'rate' };
    }
    const n = this.open.get(key) || 0;
    if (this.maxPerIp > 0 && n >= this.maxPerIp) return { ok: false, reason: 'concurrent' };
    this.open.set(key, n + 1);
    return { ok: true };
  }
  release(key) {
    if (!key) return;
    const n = (this.open.get(key) || 0) - 1;
    if (n > 0) this.open.set(key, n); else this.open.delete(key);
  }
  /** Drops idle rate buckets (called from the heartbeat). */
  sweep() { const t = this.clock(); for (const [k, b] of this.rate) if (!this.open.has(k) && b.full(t)) this.rate.delete(k); }
}

/** New sockets per account (a reconnect loop or a stolen token opening sockets in a tight loop). */
class UserConnLimiter {
  constructor({ perMin = 30 } = {}, clock = Date.now) { this.perMin = perMin; this.clock = clock; this.b = new Map(); }
  admit(userId) {
    if (!userId || !(this.perMin > 0)) return true;
    const t = this.clock();
    let b = this.b.get(userId);
    if (!b) { b = new TokenBucket(this.perMin / 60, this.perMin, t); this.b.set(userId, b); }
    return b.take(t);
  }
  sweep() { const t = this.clock(); for (const [k, b] of this.b) if (b.full(t)) this.b.delete(k); }
}

/**
 * Per-socket buckets. check(cls) -> 'ok' | 'drop' | 'kick'; warn(cls) says whether a warning frame is due.
 * 'safety' is always 'ok'.
 */
class SocketLimiter {
  constructor(cfg = limitsConfig(), clock = Date.now) {
    this.cfg = cfg; this.clock = clock;
    const t = clock();
    this.b = {};
    for (const c of ['pos', 'chat', 'join', 'ping', 'other', 'invalid']) this.b[c] = new TokenBucket(cfg[c].rate, cfg[c].burst, t);
    this.strikes = new TokenBucket(cfg.kickDrops / 10, cfg.kickDrops, t);
    this.warnedAt = {};
    this.joinFails = new TokenBucket(cfg.joinFailMax / 60, cfg.joinFailMax, t);
  }
  check(cls) {
    if (cls === 'safety') return 'ok';
    const t = this.clock();
    const b = this.b[cls] || this.b.other;
    if (b.take(t)) return 'ok';
    return this.strikes.take(t) ? 'drop' : 'kick';
  }
  /** One invalid frame: 'ok' (answered with ERROR 400) or 'kick'. */
  invalid() { return this.b.invalid.take(this.clock()) ? 'ok' : 'kick'; }
  /** A refused JOIN: true when the socket must close (JOIN_FLOOD). */
  joinRefused() { return !this.joinFails.take(this.clock()); }
  warn(cls) {
    const t = this.clock();
    if (this.warnedAt[cls] !== undefined && t - this.warnedAt[cls] < this.cfg.warnEveryMs) return 0;
    this.warnedAt[cls] = t;
    const b = this.b[cls] || this.b.other;
    return Math.max(1, b.waitMs(t));
  }
}

module.exports = {
  limitsConfig, rateSpec, TokenBucket, SAFETY, classOf, validateInbound, MAX_BYTES, DEFAULT_MAX,
  trustFn, clientIpOf, IpConnLimiter, UserConnLimiter, SocketLimiter,
};
