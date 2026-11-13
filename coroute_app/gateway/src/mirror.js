'use strict';
/**
 * Two-node live mirror: VM1 (GATEWAY_ROLE=live) normally holds every rider socket; VM2 (GATEWAY_ROLE=web)
 * serves the web and keeps a live copy of every ride, so riders that reconnect to it (L4 load balancer:
 * VM1 primary, VM2 backup) find their ride intact, and hand back to VM1 when it is healthy again.
 * Both nodes share one database. Without MIRROR_* settings this module only answers /api/health/live and
 * the LIVE_RIDER_CAP count: a single node behaves exactly as before.
 *
 * Link. Each node listens on MIRROR_LISTEN_HOST:MIRROR_LISTEN_PORT (WebSocket, path /mirror) and dials
 * MIRROR_PEER_URL (backoff 0.25 s .. 5 s). Mutual challenge/response: HMAC-SHA256 over both nonces and the
 * node names with a key derived (HKDF) from MIRROR_KEY; a wrong key is closed with 4401. Every frame after
 * that is AES-256-GCM with per-direction session keys (HKDF over MIRROR_KEY and both nonces) and a 64-bit
 * counter as nonce: a replayed or reordered frame closes the link. If both dials succeed, the link dialed by
 * the node with the smaller NODE_NAME is kept (both sides decide the same) and the other closed with 4409.
 * Heartbeat every second (state, role, rooms with local sockets, cumulative ack, RTT); 3.5 s of silence is a
 * dead link. Sending never blocks the live path: lanes 0 (SOS, alerts, roster, durable events) and 1 (other
 * events) queue while the socket is backpressured (lane 1 drops its oldest beyond 20000), lane 2 (positions,
 * voice frames) is dropped at once.
 *
 * Protocol (JSON unless noted, all inside the encrypted frames):
 *   CHAL/AUTH/OK  handshake (plain text)       HELLO  node, role, boot, state, seen seqs, live riders, rooms
 *   SNAP          up to 20 serialized rooms    SNAP_END  snapshot complete (a syncing live node starts serving)
 *   EV            one replicated room event: origin (node#boot), seq, groupId, state delta d
 *                 { room | meta, riders, gone, msgs, alerts, regroup, cids, unsaved, saved, ended }, the room
 *                 message w (or wc = {cap, payload}) for the peer's own sockets, a = 1 when an ack is wanted
 *   EA            ack of one EV                P  position (coalesced to 1/s per rider, droppable)
 *   HB / HBA      heartbeat / its echo         LU  riders with a live socket here (on change): u = in a room,
 *                                              o = any open signed-in socket (home screen too; push dedupe)
 *   U             personal message for a rider whose socket is on the peer
 *   binary 0x02   voice START/FRAME/END (frames only while the peer has sockets in that room)
 *   XS            state of a registered extension (src/public_ride.js 'pr'), after the rooms, before SNAP_END;
 *                 its changes travel as EV with g '' and x = {k, op} (same ordering, ack and resend as rooms)
 * Events are applied idempotently: a receiver ignores an EV whose seq is not above the last one seen from
 * that origin. Events not yet acknowledged are kept (bounded) and sent again after a reconnect, before the
 * snapshot; the snapshot then merges both sides (newest meta, freshest telemetry per rider, membership by the
 * newer member records, union of messages, alerts: resolved wins, then the newest).
 *
 * Decisions:
 *  - The peer applies a remote event to its in-memory room and repeats the same room message to its own
 *    sockets of that room (riders split across nodes during a hand-back see and hear each other). Remote
 *    events never reach the local timeline, safety network ('emergency') or SMS gateway: the origin node did
 *    those (shared database). Remote positions do feed the local safety network grid.
 *  - Room authority: the node with sockets of a room runs its background automation (timeline ticks, alert
 *    expiry, discovery); with sockets on both (or none), the GATEWAY_ROLE=live node; link down: each node.
 *    The group talk floor: a remote START while a local stream is live goes to the live node.
 *  - Persistence: a room is written (one room snapshot document per flush) by a node with local sockets in it.
 *  - Durable events (SOS, CRASH and member reports, resolve, respond, chat): stored in the database first,
 *    then the room and the peer (ack awaited up to MIRROR_ACK_TIMEOUT_MS, not at all when the link is down),
 *    then the sender's echo / ACK. Dedupe state (clientIds, alert clientIds, storm guard via alerts) is
 *    replicated, and a cold node finds an SOS by clientId in the database.
 *  - Health: role=live starts 'syncing' (503) when the peer answers within MIRROR_STARTUP_WAIT_MS and holds
 *    live riders, until its snapshot is applied (at most MIRROR_SYNC_TIMEOUT_MS). 'overloaded' (503) only
 *    after the event loop lagged > 2 s for > 10 s. 'shutdown' (503) during a graceful stop.
 *  - Hand-back: the web node, seeing the live node 'serving' for MIRROR_HANDBACK_DELAY_MS (time for the load
 *    balancer to mark it healthy), sends RECONNECT {delayMs 0-3000, reason 'handback'} to
 *    MIRROR_HANDBACK_PER_SEC sockets per second; a rider told once is not told again for 2 minutes (no
 *    ping-pong while the balancer still points here); a socket still open 10 s after its delay is closed (1012).
 *  - LIVE_RIDER_CAP counts distinct riders with an open room socket on both nodes.
 */
const crypto = require('crypto');
const http = require('http');
const os = require('os');
const { performance } = require('perf_hooks');
const { WebSocketServer, WebSocket } = require('ws');
const config = require('./config');

const ROLES = new Set(['live', 'web', 'all']);
const HIGH_WATER = 1024 * 1024; // link send buffer above which lane 2 is dropped and lanes 0/1 queue
const MAX_QUEUE = 20000;
const RESEND_MAX = 20000;
const SNAP_CHUNK = 20;
const HANDBACK_RETELL_MS = 120000;
const POS_MIN_MS = 1000;
const OVERLOAD_LAG_MS = 2000;
const OVERLOAD_FOR_MS = 10000;
const MAX_FRAME = 64 * 1024 * 1024;
const VOICE_START = 0x01, VOICE_FRAME = 0x02;
/** Rider fields that move with telemetry (the fresher copy wins them in a merge). */
const TELEMETRY_KEYS = ['lat', 'lng', 'speedKmh', 'heading', 'batteryLevel', 'isCharging', 'statusReason', 'statusMessage', 'stoppedSince', 'fuelEstimate', 'lastSeenEpochMs'];
const POSITION_KEYS = [...TELEMETRY_KEYS, 'userId', 'presence', 'presenceAt', 'micMuted', 'isSpeaking'];
/** Room events sent in lane 0 (never dropped, ahead of the rest). */
const CRITICAL = new Set(['ALERT', 'ALERT_RESOLVED', 'SOS_RESPONSE', 'EMERGENCY_UPDATE', 'RIDER_LEFT', 'DISSOLVED', 'TRIP_STATUS', 'RIDER_BATTERY_SHUTDOWN']);

const now = () => Date.now();
const hmac = (k, s) => crypto.createHmac('sha256', k).update(s).digest();
const hkdf = (secret, salt, info) => Buffer.from(crypto.hkdfSync('sha256', Buffer.from(secret, 'utf8'), salt, Buffer.from(info, 'utf8'), 32));
function safeEq(hex, buf) {
  if (typeof hex !== 'string' || hex.length !== buf.length * 2 || !/^[0-9a-f]+$/.test(hex)) return false;
  return crypto.timingSafeEqual(Buffer.from(hex, 'hex'), buf);
}
function pick(o, keys) { const out = {}; for (const k of keys) if (o[k] !== undefined) out[k] = o[k]; return out; }

/** One authenticated, encrypted connection to the peer. */
class Link {
  constructor(mirror, ws, dialer) {
    this.m = mirror; this.ws = ws; this.dialer = dialer;
    this.ready = false; this.peerNode = null;
    this.txKey = null; this.rxKey = null; this.txTag = dialer ? 1 : 2; this.rxTag = dialer ? 2 : 1;
    this.txCtr = 0n; this.rxCtr = -1n;
    this.lastRx = now(); this.openedAt = now();
    this.q = [[], []];
    this.sentRooms = new Set();
  }
  keys(nS, nC) {
    const salt = Buffer.concat([nS, nC]);
    const c2s = hkdf(this.m.key, salt, 'coroute-mirror c2s'), s2c = hkdf(this.m.key, salt, 'coroute-mirror s2c');
    this.txKey = this.dialer ? c2s : s2c; this.rxKey = this.dialer ? s2c : c2s;
  }
  seal(pt) {
    const iv = Buffer.alloc(12); iv.writeUInt32BE(this.txTag, 0); iv.writeBigUInt64BE(this.txCtr++, 4);
    const c = crypto.createCipheriv('aes-256-gcm', this.txKey, iv);
    const ct = Buffer.concat([c.update(pt), c.final()]);
    return Buffer.concat([iv.subarray(4), c.getAuthTag(), ct]);
  }
  open(buf) {
    if (!Buffer.isBuffer(buf) || buf.length < 25) throw new Error('short frame');
    const ctr = buf.readBigUInt64BE(0);
    if (ctr <= this.rxCtr) throw new Error('replayed frame');
    const iv = Buffer.alloc(12); iv.writeUInt32BE(this.rxTag, 0); iv.writeBigUInt64BE(ctr, 4);
    const d = crypto.createDecipheriv('aes-256-gcm', this.rxKey, iv);
    d.setAuthTag(buf.subarray(8, 24));
    const pt = Buffer.concat([d.update(buf.subarray(24)), d.final()]);
    this.rxCtr = ctr;
    return pt;
  }
  write(pt) {
    if (this.ws.readyState !== WebSocket.OPEN) return false;
    this.ws.send(this.seal(pt), { binary: true });
    return true;
  }
  close(code = 1000, reason = '') { try { this.ws.close(code, reason); } catch { /* gone */ } }
}

class Mirror {
  /**
   * @param {object} o convoys (ConvoyManager), logger, and overrides of the MIRROR_* settings (tests boot two
   *   nodes in one process): node, role, listenHost, listenPort, peerUrl, key, ackTimeoutMs, liveRiderCap,
   *   handbackDelayMs, handbackPerSec, startupWaitMs, syncTimeoutMs, heartbeatMs, deadMs, reconnectMinMs, reconnectMaxMs.
   */
  constructor(o = {}) {
    const c = config;
    this.convoys = o.convoys; this.log = o.logger || console; this.hub = null;
    this.node = String(o.node || c.nodeName || process.env.NODE_NAME || os.hostname()).slice(0, 64);
    this.role = ROLES.has(o.role) ? o.role : (ROLES.has(c.gatewayRole) ? c.gatewayRole : 'all');
    // v3.56 DR standby: /api/health/live answers 503 'standby' so no balancer ever sends riders here by mistake.
    this.standby = (o.role ?? c.gatewayRole) === 'standby';
    this.listenHost = o.listenHost ?? c.mirrorListenHost ?? '';
    this.listenPort = o.listenPort ?? c.mirrorListenPort ?? 3101;
    this.peerUrl = o.peerUrl ?? c.mirrorPeerUrl ?? '';
    this.key = o.key ?? c.mirrorKey ?? '';
    this.ackTimeoutMs = o.ackTimeoutMs ?? c.mirrorAckTimeoutMs ?? 400;
    this.cap = Math.max(0, o.liveRiderCap ?? c.liveRiderCap ?? 0);
    this.handbackDelayMs = o.handbackDelayMs ?? c.mirrorHandbackDelayMs ?? 15000;
    this.handbackPerSec = Math.max(1, o.handbackPerSec ?? c.mirrorHandbackPerSec ?? 25);
    this.startupWaitMs = o.startupWaitMs ?? c.mirrorStartupWaitMs ?? 3000;
    this.syncTimeoutMs = o.syncTimeoutMs ?? c.mirrorSyncTimeoutMs ?? 30000;
    this.heartbeatMs = o.heartbeatMs ?? 1000;
    this.deadMs = o.deadMs ?? 3500;
    this.reconnectMinMs = o.reconnectMinMs ?? 250;
    this.reconnectMaxMs = o.reconnectMaxMs ?? 5000;
    this.enabled = !!(this.listenHost || this.peerUrl);
    if (this.enabled && String(this.key).length < 32) throw new Error('[mirror] MIRROR_KEY (at least 32 characters) is required when MIRROR_LISTEN_HOST or MIRROR_PEER_URL is set');
    this.authKey = this.enabled ? hkdf(this.key, Buffer.from('coroute-mirror'), 'auth') : null;

    this.bootId = crypto.randomBytes(6).toString('hex');
    this.origin = `${this.node}#${this.bootId}`;
    this.seq = 0;
    this.lastSeen = new Map(); // origin -> highest seq applied
    this.resend = new Map(); // seq -> JSON of events not yet acknowledged
    this.acks = new Map(); // seq -> { res, timer }
    this.link = null; this.links = new Set(); this.peer = null;
    this.dialing = false; this.dialTimer = null; this.backoff = this.reconnectMinMs;
    this.posLast = new Map(); this.posPending = new Map();
    this.lastMeta = new Map();
    this.told = new Map();
    this.exts = new Map(); // name -> { exportState(), importState(s), applyRemote(op) } (public ride)
    this.lastLU = '';
    this.state = this.enabled && this.role === 'live' ? 'syncing' : 'serving';
    this.startedAt = now();
    this.loopLagMs = 0; this.overloadSince = 0;
    this.stats = { sent: 0, recv: 0, dupes: 0, dropped: 0, applied: 0, handedBack: 0, authFailed: 0 };
    this.stopped = false;
    this.server = null; this.wss = null; this.port = 0;
    this.timers = [];
    this._every(500, () => this._lagTick());
  }

  _every(ms, fn) {
    const t = setInterval(() => { try { fn(); } catch (e) { this.log.warn('[mirror]', e.message); } }, ms);
    if (t.unref) t.unref();
    this.timers.push(t);
    return t;
  }

  attach(hub) { this.hub = hub; hub.mirror = this; this.convoys.mirror = this; }

  /** Registers replicated state that is not a room (public ride index, blocks, requests, road warnings). */
  register(name, handler) { this.exts.set(name, handler); handler.mirror = this; }

  /** One change of a registered extension to the peer (an EV without a room). */
  ext(name, op) {
    if (!this.enabled) return;
    this._sendEvent({ g: '', d: {}, x: { k: name, op } }, { prio: 1 });
  }

  /** Starts listening and dialing (no-op on a single node). Resolves once the listener is bound. */
  async start() {
    if (!this.enabled || this.stopped) return this;
    this._every(this.heartbeatMs, () => this._tick());
    this._every(250, () => this._flushPositions());
    if (this.state === 'syncing') {
      const t = setTimeout(() => { if (this.state === 'syncing' && !this.link) this._serving('peer not reachable'); }, this.startupWaitMs);
      if (t.unref) t.unref();
      const t2 = setTimeout(() => { if (this.state === 'syncing') this._serving('sync timeout'); }, this.syncTimeoutMs);
      if (t2.unref) t2.unref();
      this.timers.push(t, t2);
    }
    if (this.listenHost) {
      this.server = http.createServer((req, res) => { res.statusCode = 426; res.end(); });
      this.wss = new WebSocketServer({ server: this.server, path: '/mirror', maxPayload: MAX_FRAME });
      this.wss.on('connection', (ws) => this._onInbound(ws));
      await new Promise((resolve, reject) => {
        this.server.once('error', reject);
        this.server.listen(this.listenPort, this.listenHost, () => { this.server.off('error', reject); resolve(); });
      });
      this.port = this.server.address().port;
      this.log.info?.(`[mirror] ${this.node} (${this.role}) listening on ${this.listenHost}:${this.port}`);
    }
    this._dial();
    return this;
  }

  /** Points the dialer at another peer (tests bind port 0 first). */
  setPeer(url) { this.peerUrl = url; this.enabled = true; this._dial(); }

  linked() { return !!(this.link && this.link.ready); }

  // ================================================================ link
  _onInbound(ws) {
    if (this.stopped) return ws.terminate();
    const link = new Link(this, ws, false);
    this.links.add(link);
    const nS = crypto.randomBytes(32);
    const timer = setTimeout(() => ws.terminate(), 5000);
    if (timer.unref) timer.unref();
    ws.on('error', () => {});
    ws.on('close', () => { clearTimeout(timer); this._linkDown(link); });
    ws.on('message', (data, isBinary) => {
      if (link.ready) return this._onFrame(link, data, isBinary);
      if (isBinary) return ws.close(4401, 'Unauthorized');
      let m; try { m = JSON.parse(data.toString()); } catch { m = null; }
      const ok = m && m.t === 'AUTH' && typeof m.node === 'string' && m.node.length <= 64 && typeof m.n === 'string' && /^[0-9a-f]{64}$/.test(m.n)
        && safeEq(m.mac, hmac(this.authKey, `C|${nS.toString('hex')}|${m.n}|${m.node}`));
      if (!ok) { this.stats.authFailed++; this.log.warn('[mirror] peer authentication failed (MIRROR_KEY?)'); return ws.close(4401, 'Unauthorized'); }
      if (m.node === this.node) { this.log.warn('[mirror] the peer has the same NODE_NAME'); return ws.close(4400, 'Same node name'); }
      clearTimeout(timer);
      ws.send(JSON.stringify({ t: 'OK', node: this.node, mac: hmac(this.authKey, `S|${m.n}|${nS.toString('hex')}|${this.node}`).toString('hex') }));
      link.peerNode = m.node;
      link.keys(nS, Buffer.from(m.n, 'hex'));
      this._linkUp(link);
    });
    ws.send(JSON.stringify({ t: 'CHAL', n: nS.toString('hex'), node: this.node, v: 1 }));
  }

  _dial() {
    if (!this.peerUrl || this.stopped || this.dialing || this.linked() || this.dialTimer) return;
    this.dialing = true;
    let ws;
    try { ws = new WebSocket(this.peerUrl, { handshakeTimeout: 3000, maxPayload: MAX_FRAME }); } catch (e) {
      this.dialing = false; this.log.warn('[mirror] bad MIRROR_PEER_URL', e.message); return;
    }
    const link = new Link(this, ws, true);
    this.links.add(link);
    const nC = crypto.randomBytes(32);
    let nS = null;
    const timer = setTimeout(() => ws.terminate(), 5000);
    if (timer.unref) timer.unref();
    ws.on('error', () => {});
    ws.on('close', (code) => {
      clearTimeout(timer);
      const wasReady = link.ready;
      this._linkDown(link);
      if (!wasReady) {
        this.dialing = false;
        if (code === 4401) this.log.warn('[mirror] the peer refused our MIRROR_KEY');
        this._redial();
      }
    });
    ws.on('message', (data, isBinary) => {
      if (link.ready) return this._onFrame(link, data, isBinary);
      if (isBinary) return ws.close(4401, 'Unauthorized');
      let m; try { m = JSON.parse(data.toString()); } catch { return ws.close(4401, 'Unauthorized'); }
      if (!nS) {
        if (!m || m.t !== 'CHAL' || typeof m.n !== 'string' || !/^[0-9a-f]{64}$/.test(m.n)) return ws.close(4401, 'Unauthorized');
        nS = Buffer.from(m.n, 'hex');
        ws.send(JSON.stringify({ t: 'AUTH', node: this.node, n: nC.toString('hex'), mac: hmac(this.authKey, `C|${m.n}|${nC.toString('hex')}|${this.node}`).toString('hex') }));
        return;
      }
      if (!m || m.t !== 'OK' || typeof m.node !== 'string' || !safeEq(m.mac, hmac(this.authKey, `S|${nC.toString('hex')}|${nS.toString('hex')}|${m.node}`))) {
        this.stats.authFailed++;
        this.log.warn('[mirror] the peer failed authentication (MIRROR_KEY?)');
        return ws.close(4401, 'Unauthorized');
      }
      clearTimeout(timer);
      link.peerNode = m.node;
      link.keys(nS, nC);
      this.dialing = false;
      this._linkUp(link);
    });
  }

  _redial() {
    if (this.stopped || !this.peerUrl || this.dialTimer || this.linked()) return;
    const wait = this.backoff;
    this.backoff = Math.min(this.reconnectMaxMs, this.backoff * 2);
    this.dialTimer = setTimeout(() => { this.dialTimer = null; this._dial(); }, wait);
    if (this.dialTimer.unref) this.dialTimer.unref();
  }

  _linkUp(link) {
    if (this.stopped) return link.close(1001);
    const cur = this.link;
    if (cur && cur !== link && cur.ready) {
      // Two links (both dialed): keep the one dialed by the smaller node name; both sides decide the same.
      const winner = this.node < link.peerNode ? this.node : link.peerNode;
      const dialerOf = (l) => (l.dialer ? this.node : l.peerNode);
      if (dialerOf(link) !== winner) { link.ready = false; return link.close(4409, 'Duplicate'); }
      cur.ready = false; cur.close(4409, 'Duplicate');
      if (this.link === cur) this.link = null;
    }
    link.ready = true;
    this.link = link;
    this.backoff = this.reconnectMinMs;
    if (this.dialTimer) { clearTimeout(this.dialTimer); this.dialTimer = null; }
    this.lastMeta.clear();
    this.lastLU = '';
    this.log.info?.(`[mirror] ${this.node} linked to ${link.peerNode}`);
    const live = this.hub ? [...this.hub.liveUsers()] : [];
    const online = this.hub && typeof this.hub.onlineUsers === 'function' ? [...this.hub.onlineUsers()] : live;
    this._json(link, {
      t: 'HELLO', node: this.node, role: this.role, boot: this.bootId, state: this.state,
      seen: Object.fromEntries(this.lastSeen), live, online, rooms: this._localRooms(),
    });
  }

  _linkDown(link) {
    this.links.delete(link);
    const was = this.link === link;
    link.ready = false;
    if (!was) return;
    this.link = null;
    for (const [s, p] of this.acks) { clearTimeout(p.timer); p.res(false); this.acks.delete(s); }
    const peer = this.peer;
    if (peer) { peer.rooms = new Set(); peer.live = new Set(); peer.online = new Set(); peer.servingSince = 0; peer.state = 'down'; }
    if (!this.stopped) {
      this.log.warn(`[mirror] ${this.node} lost the link to ${link.peerNode}`);
      // This node now runs every room alone: open alerts of mirrored rooms get their safety-network incident.
      for (const [gid, room] of this.convoys.rooms) {
        if ([...room.alerts.values()].some((a) => !a.resolved)) this.convoys.emit('roomLoaded', gid);
      }
      this._redial();
    }
  }

  // ================================================================ sending
  _json(link, obj, prio = 0) { return this._enqueue(link, Buffer.concat([Buffer.from([1]), Buffer.from(JSON.stringify(obj), 'utf8')]), prio); }

  _enqueue(link, pt, prio) {
    if (!link || !link.ready || link.ws.readyState !== WebSocket.OPEN) return false;
    const backlog = link.q[0].length || link.q[1].length;
    if (prio === 2) {
      if (backlog || link.ws.bufferedAmount > HIGH_WATER) { this.stats.dropped++; return false; }
      this.stats.sent++;
      return link.write(pt);
    }
    if (!backlog && link.ws.bufferedAmount <= HIGH_WATER) { this.stats.sent++; return link.write(pt); }
    link.q[prio].push(pt);
    if (link.q[1].length > MAX_QUEUE) { link.q[1].shift(); this.stats.dropped++; }
    this._armDrain(link);
    return true;
  }

  _armDrain(link) {
    if (link.drainTimer) return;
    link.drainTimer = setTimeout(() => {
      link.drainTimer = null;
      if (!link.ready) return;
      while (link.ws.bufferedAmount <= HIGH_WATER && (link.q[0].length || link.q[1].length)) {
        link.write(link.q[0].length ? link.q[0].shift() : link.q[1].shift());
        this.stats.sent++;
      }
      if (link.q[0].length || link.q[1].length) this._armDrain(link);
    }, 20);
    if (link.drainTimer.unref) link.drainTimer.unref();
  }

  /** Sends one replicated event (kept for a resend until acknowledged). Durable: resolves true on the peer's ack. */
  _sendEvent(ev, { durable = false, prio = 1 } = {}) {
    ev.t = 'EV'; ev.o = this.origin; ev.s = ++this.seq;
    if (durable) ev.a = 1;
    const str = JSON.stringify(ev);
    this.resend.set(ev.s, str);
    if (this.resend.size > RESEND_MAX) this.resend.delete(this.resend.keys().next().value);
    const link = this.linked() ? this.link : null;
    if (!link) return durable ? Promise.resolve(false) : null;
    this._enqueue(link, Buffer.concat([Buffer.from([1]), Buffer.from(str, 'utf8')]), prio);
    if (!durable) return null;
    return new Promise((res) => {
      const timer = setTimeout(() => { this.acks.delete(ev.s); res(false); }, this.ackTimeoutMs);
      if (timer.unref) timer.unref();
      this.acks.set(ev.s, { res, timer });
    });
  }

  // ================================================================ hooks (ConvoyManager / Hub)
  /** A room event applied here (ConvoyManager._emit / _durable): state delta + the room message to the peer. */
  local(gid, payload, { durable = false, cap = null } = {}) {
    if (!this.enabled) return null;
    const room = this.convoys.rooms.get(gid);
    const d = room ? this._delta(room, payload) : {};
    if (payload && payload.type === 'DISSOLVED') d.ended = true;
    const ev = { g: gid, d };
    if (cap) ev.wc = { cap, payload }; else ev.w = payload;
    const crit = durable || (payload && (CRITICAL.has(payload.type) || (payload.type === 'RIDER_UPDATE' && payload.joined !== undefined)));
    const p = this._sendEvent(ev, { durable, prio: crit ? 0 : 1 });
    if (d.ended) this._forget(gid);
    return p;
  }

  /** A room created here: its whole state. */
  roomCreated(room) {
    if (!this.enabled) return;
    if (this.link) this.link.sentRooms.add(room.groupId);
    this._sendEvent({ g: room.groupId, d: { room: this.serialize(room) } }, { prio: 0 });
  }

  /** A state change without a room message (clientIds, stored-again marks, profile, live links). */
  replicate(gid, delta) {
    if (!this.enabled) return;
    const room = this.convoys.rooms.get(gid);
    const d = { ...delta };
    if (room && this.link && !this.link.sentRooms.has(gid)) { d.room = this.serialize(room); this.link.sentRooms.add(gid); }
    this._sendEvent({ g: gid, d }, { prio: delta.alerts ? 0 : 1 });
  }

  /** A room message sent by the hub itself (MIC_STATUS, battery shutdown): repeated to the peer's sockets. */
  wire(gid, payload) {
    if (!this.enabled) return;
    const d = {};
    const room = this.convoys.rooms.get(gid);
    if (room && this.link && !this.link.sentRooms.has(gid)) { d.room = this.serialize(room); this.link.sentRooms.add(gid); }
    if (room && payload && payload.userId && payload.type === 'RIDER_BATTERY_SHUTDOWN' && room.riders.has(payload.userId)) d.riders = [room.riders.get(payload.userId)];
    this._sendEvent({ g: gid, d, w: payload }, { prio: CRITICAL.has(payload && payload.type) ? 0 : 1 });
  }

  /** A personal message for a rider with no socket here. */
  user(userId, payload, cap) {
    if (!this.userOnPeer(userId)) return;
    this._json(this.link, { t: 'U', u: userId, p: payload, c: cap || null }, payload && CRITICAL.has(payload.type) ? 0 : 1);
  }

  /**
   * True when the peer node holds an open signed-in socket of the rider (in a room or not), as of its
   * last LU (sent on change, at most once per heartbeat). Push uses it so a rider connected to the
   * OTHER node does not get a push for a notice its socket already shows.
   */
  userOnPeer(userId) {
    if (!this.linked() || !this.peer || !userId) return false;
    return this.peer.live.has(userId) || (!!this.peer.online && this.peer.online.has(userId));
  }

  /** A position from a local socket: to the peer at most once a second per rider (latest wins). */
  position(gid, rider) {
    if (!this.enabled || !this.linked() || !rider) return;
    const k = `${gid}|${rider.userId}`;
    const t = now();
    if (!this.posPending.has(k) && t - (this.posLast.get(k) || 0) >= POS_MIN_MS) {
      this.posLast.set(k, t);
      this._sendPosition(gid, rider);
    } else {
      this.posPending.set(k, gid);
    }
  }

  _flushPositions() {
    if (!this.posPending.size) return;
    const t = now();
    for (const [k, gid] of this.posPending) {
      if (t - (this.posLast.get(k) || 0) < POS_MIN_MS) continue;
      this.posPending.delete(k);
      const uid = k.slice(gid.length + 1);
      const rider = this.convoys.rooms.get(gid)?.riders.get(uid);
      if (!rider) continue;
      this.posLast.set(k, t);
      this._sendPosition(gid, rider);
    }
    if (this.posLast.size > 20000) for (const [k, at] of this.posLast) if (t - at > 60000) this.posLast.delete(k);
  }

  _sendPosition(gid, rider) {
    const link = this.link;
    if (!link) return;
    if (!link.sentRooms.has(gid)) this.replicate(gid, {}); // the whole room first, then the position
    this._json(link, { t: 'P', g: gid, r: pick(rider, POSITION_KEYS) }, 2);
  }

  /** Voice to the peer: START/END always (the floor), frames only while the peer has sockets in the room. */
  voice(gid, kind, header, payload) {
    if (!this.linked() || !this.peer) return;
    if (kind === VOICE_FRAME && !this.peer.rooms.has(gid)) return;
    const j = Buffer.from(JSON.stringify({ g: gid, k: kind, h: header }), 'utf8');
    const head = Buffer.alloc(3); head[0] = 2; head.writeUInt16BE(j.length, 1);
    this._enqueue(this.link, Buffer.concat([head, j, payload || Buffer.alloc(0)]), kind === VOICE_FRAME ? 2 : 1);
  }

  // ================================================================ state of a room on the wire
  serialize(room) {
    return {
      g: room.groupId, meta: room.meta, riders: [...room.riders.values()], messages: room.messages.slice(-200),
      alerts: [...room.alerts.values()], regroup: room.regroup || null,
      cids: room.clientIds ? [...room.clientIds] : [], unsaved: room.unsaved ? [...room.unsaved] : [],
    };
  }

  _delta(room, p) {
    const gid = room.groupId;
    if (this.link && !this.link.sentRooms.has(gid)) {
      this.link.sentRooms.add(gid);
      this.lastMeta.set(gid, JSON.stringify(room.meta));
      return { room: this.serialize(room) };
    }
    const d = {};
    const ms = JSON.stringify(room.meta);
    if (ms !== this.lastMeta.get(gid)) { d.meta = room.meta; this.lastMeta.set(gid, ms); }
    const type = p && p.type;
    const riderOf = (uid) => { const r = uid && room.riders.get(uid); if (r) (d.riders || (d.riders = [])).push(r); };
    const alertOf = (id) => {
      const a = id && room.alerts.get(id);
      if (!a) return;
      (d.alerts || (d.alerts = [])).push(a);
      if (room.unsaved && room.unsaved.has(id)) d.unsaved = [id];
    };
    switch (type) {
      case 'RIDER_UPDATE': riderOf(p.rider && p.rider.userId); break;
      case 'PRESENCE': riderOf(p.userId); break;
      case 'RIDER_LEFT': d.gone = [p.userId]; break;
      case 'ROSTER_CHANGED': case 'TRIP_HEAD_CHANGED': case 'CONFIG': d.riders = [...room.riders.values()]; break;
      case 'MESSAGE':
        if (p.message) { d.msgs = [p.message]; if (room.unsaved && room.unsaved.has(p.message.messageId)) d.unsaved = [p.message.messageId]; }
        break;
      case 'ALERT': alertOf(p.alert && p.alert.alertId); break;
      case 'ALERT_RESOLVED': case 'SOS_RESPONSE': case 'EMERGENCY_UPDATE': alertOf(p.alertId); break;
      case 'REGROUP_ACTIVE': case 'REGROUP_COMPLETED': d.regroup = room.regroup || null; break;
      default: break;
    }
    return d;
  }

  _forget(gid) {
    if (this.link) this.link.sentRooms.delete(gid);
    this.lastMeta.delete(gid);
  }

  // ================================================================ receiving
  _onFrame(link, data, isBinary) {
    if (link !== this.link) return; // a duplicate being closed
    let pt;
    try { pt = link.open(Buffer.isBuffer(data) ? data : Buffer.from(data)); } catch (e) {
      this.log.warn('[mirror] bad frame from the peer, closing the link:', e.message);
      return link.ws.terminate();
    }
    link.lastRx = now();
    this.stats.recv++;
    try {
      if (pt[0] === 2) return this._onVoice(pt);
      const m = JSON.parse(pt.subarray(1).toString('utf8'));
      this._onMessage(link, m);
    } catch (e) { this.log.warn('[mirror] frame failed', e.message); }
  }

  _onMessage(link, m) {
    switch (m.t) {
      case 'HELLO': return this._onHello(link, m);
      case 'HB': return this._onHeartbeat(link, m);
      case 'HBA': this.lagMs = Math.max(0, now() - Number(m.at || 0)); return;
      case 'LU':
        if (this.peer) {
          this.peer.live = new Set(Array.isArray(m.u) ? m.u : []);
          this.peer.online = new Set(Array.isArray(m.o) ? m.o : []);
        }
        return;
      case 'SNAP': for (const r of m.rooms || []) { try { this._mergeRoom(r); } catch (e) { this.log.warn('[mirror] snapshot room failed', e.message); } } return;
      case 'XS': { const h = this.exts.get(m.k); if (h) { try { h.importState(m.s); } catch (e) { this.log.warn('[mirror] extension state failed', e.message); } } return; }
      case 'SNAP_END':
        this.snapshotApplied = true;
        if (this.state === 'syncing') this._serving('snapshot applied');
        return;
      case 'EV': return this._onEvent(m);
      case 'EA': { const p = this.acks.get(m.s); if (p) { clearTimeout(p.timer); this.acks.delete(m.s); p.res(true); } return; }
      case 'P': return this._onPosition(m);
      case 'U': if (this.hub && typeof m.u === 'string') this.hub.sendToUser(m.u, m.p || {}, m.c || undefined, { local: true }); return;
      default: return;
    }
  }

  _onHello(link, m) {
    const prev = this.peer;
    if (prev && prev.boot !== m.boot) for (const k of [...this.lastSeen.keys()]) if (k.startsWith(`${prev.node}#`)) this.lastSeen.delete(k);
    this.peer = {
      node: String(m.node), role: ROLES.has(m.role) ? m.role : 'all', boot: String(m.boot), state: m.state,
      live: new Set(Array.isArray(m.live) ? m.live : []), rooms: new Set(Array.isArray(m.rooms) ? m.rooms : []),
      online: new Set(Array.isArray(m.online) ? m.online : []),
      servingSince: m.state === 'serving' ? now() : 0, hbAt: now(),
    };
    // Events the same peer process has not seen (sent while the link was down), then our whole state. A peer
    // that restarted (or one we never met) gets the snapshot only: replaying old room messages is noise there.
    if (prev && prev.boot === this.peer.boot) {
      const seen = Number(m.seen && m.seen[this.origin]) || 0;
      for (const [s, str] of this.resend) if (s > seen) this._enqueue(link, Buffer.concat([Buffer.from([1]), Buffer.from(str, 'utf8')]), 0);
    } else {
      this.resend.clear();
    }
    this._sendSnapshot(link);
    if (this.state === 'syncing' && this.peer.live.size === 0) this._serving('the peer holds no live riders');
  }

  _sendSnapshot(link, { onlyLocal = false } = {}) {
    const rooms = [];
    for (const room of this.convoys.rooms.values()) {
      if (onlyLocal && !this._hasLocal(room.groupId)) continue;
      rooms.push(this.serialize(room));
      link.sentRooms.add(room.groupId);
      this.lastMeta.set(room.groupId, JSON.stringify(room.meta));
    }
    for (let i = 0; i < rooms.length; i += SNAP_CHUNK) this._json(link, { t: 'SNAP', rooms: rooms.slice(i, i + SNAP_CHUNK) }, 0);
    for (const [k, h] of this.exts) {
      try { this._json(link, { t: 'XS', k, s: h.exportState() }, 0); } catch (e) { this.log.warn('[mirror] extension snapshot failed', k, e.message); }
    }
    this._json(link, { t: 'SNAP_END', n: rooms.length }, 0);
  }

  _onHeartbeat(link, m) {
    const p = this.peer;
    if (!p) return;
    p.hbAt = now();
    if (m.st !== p.state) p.servingSince = m.st === 'serving' ? now() : 0;
    p.state = m.st;
    p.role = ROLES.has(m.role) ? m.role : p.role;
    p.rooms = new Set(Array.isArray(m.rooms) ? m.rooms : []);
    p.liveCount = Number(m.n) || 0;
    const ack = Number(m.ack) || 0;
    for (const s of this.resend.keys()) { if (s > ack) break; this.resend.delete(s); }
    this._json(link, { t: 'HBA', at: m.at }, 0);
  }

  _onEvent(m) {
    if (typeof m.o !== 'string' || !Number.isFinite(m.s)) return;
    const last = this.lastSeen.get(m.o) || 0;
    if (m.s <= last) {
      this.stats.dupes++;
    } else {
      this.lastSeen.set(m.o, m.s);
      try { this._apply(String(m.g || ''), m.d || {}, m.w, m.wc); this.stats.applied++; } catch (e) { this.log.warn('[mirror] event failed', e.message); }
      if (m.x && typeof m.x === 'object') {
        const h = this.exts.get(m.x.k);
        if (h) { try { h.applyRemote(m.x.op); } catch (e) { this.log.warn('[mirror] extension event failed', e.message); } }
      }
    }
    if (m.a && this.link) this._json(this.link, { t: 'EA', s: m.s }, 0);
  }

  _hasLocal(gid) { const set = this.hub && this.hub.rooms.get(gid); return !!(set && set.size); }
  _localRooms() { return this.hub ? [...this.hub.rooms.keys()].filter((g) => this._hasLocal(g)) : []; }

  _markDirty(room, uid) {
    if (!this._hasLocal(room.groupId)) return;
    room.dirty.add(uid);
    this.convoys._schedulePersist(room);
  }

  _apply(gid, d, w, wc) {
    const C = this.convoys;
    let room = gid ? C.rooms.get(gid) : null;
    if (d.room) room = this._mergeRoom(d.room);
    if (room) {
      if (d.meta && (Number(d.meta.updatedAt) || 0) >= (Number(room.meta.updatedAt) || 0)) room.meta = d.meta;
      for (const r of d.riders || []) { if (r && r.userId) { this._applyRider(room, r); this._markDirty(room, r.userId); } }
      for (const uid of d.gone || []) { room.riders.delete(uid); room.dirty.delete(uid); }
      if (d.msgs) {
        for (const msg of d.msgs) if (msg && !room.messages.some((x) => x.messageId === msg.messageId)) room.messages.push(msg);
        if (room.messages.length > 500) room.messages.splice(0, room.messages.length - 500);
      }
      for (const a of d.alerts || []) {
        if (!a || !a.alertId) continue;
        const cur = room.alerts.get(a.alertId);
        if (cur && cur.resolved && !a.resolved) continue;
        room.alerts.set(a.alertId, a);
        C._indexLiveLink(gid, a);
      }
      if (Object.hasOwn(d, 'regroup')) room.regroup = d.regroup || null;
      if (Array.isArray(d.cids)) {
        const map = room.clientIds || (room.clientIds = new Map());
        for (const [k, at] of d.cids) if (!(map.get(k) >= at)) map.set(k, at);
      }
      for (const id of d.unsaved || []) C._setUnsaved(room, id, true);
      for (const id of d.saved || []) C._setUnsaved(room, id, false);
      this._afterMerge(room);
      if (w && w.type === 'MIC_STATUS' && w.micMuted !== undefined && room.riders.has(w.userId)) room.riders.get(w.userId).micMuted = !!w.micMuted;
    }
    // The same room message for this node's sockets of the room.
    if (this.hub && gid) {
      if (w) this.hub.broadcast(gid, w);
      if (wc && wc.cap) this.hub.broadcastCap(gid, wc.cap, wc.payload || {});
    }
    if (d.ended) this._endLocal(gid);
  }

  /** Remote rider record over ours: the remote copy, with our telemetry when ours is fresher. */
  _applyRider(room, r) {
    const cur = room.riders.get(r.userId);
    if (!cur) { room.riders.set(r.userId, r); return; }
    const next = { ...cur, ...r };
    if ((Number(cur.lastSeenEpochMs) || 0) > (Number(r.lastSeenEpochMs) || 0)) for (const k of TELEMETRY_KEYS) if (cur[k] !== undefined) next[k] = cur[k];
    if ((Number(cur.presenceAt) || 0) > (Number(r.presenceAt) || 0)) { next.presence = cur.presence; next.presenceAt = cur.presenceAt; }
    room.riders.set(r.userId, next);
  }

  /** A serialized room (snapshot or first event) merged into ours, or adopted when we do not have it. */
  _mergeRoom(remote) {
    const C = this.convoys;
    const gid = remote && remote.g;
    if (!gid || !remote.meta) return null;
    if (this.link) this.link.sentRooms.add(gid); // the peer has this room: our events can be deltas
    let room = C.rooms.get(gid);
    if (remote.meta.tripStatus === 'ENDED') { if (room) this._endLocal(gid); return null; }
    if (!room) {
      room = {
        groupId: gid, meta: remote.meta, riders: new Map((remote.riders || []).map((r) => [r.userId, r])),
        messages: remote.messages || [], alerts: new Map((remote.alerts || []).map((a) => [a.alertId, a])),
        dirty: new Set(), lastPersist: new Map(), persistTimer: null, regroup: remote.regroup || null, metaSavedAt: now(),
        clientIds: new Map(remote.cids || []),
      };
      if (remote.unsaved && remote.unsaved.length) room.unsaved = new Set(remote.unsaved);
      C.rooms.set(gid, room);
      for (const a of room.alerts.values()) C._indexLiveLink(gid, a);
      this._afterMerge(room);
      return room;
    }
    const newer = (Number(remote.meta.updatedAt) || 0) > (Number(room.meta.updatedAt) || 0);
    if (newer) { room.meta = remote.meta; room.regroup = remote.regroup || null; }
    const members = room.meta.members || {};
    const left = (uid) => { const m = members[uid]; return !!(m && m.leftAt && m.leftAt > (m.joinedAt || 0)); };
    const remoteIds = new Set();
    for (const r of remote.riders || []) {
      if (!r || !r.userId) continue;
      remoteIds.add(r.userId);
      if (room.riders.has(r.userId)) this._mergeRider(room, r, newer);
      else if (!left(r.userId)) room.riders.set(r.userId, r);
    }
    if (newer) for (const uid of [...room.riders.keys()]) if (!remoteIds.has(uid) && left(uid)) room.riders.delete(uid);
    const ids = new Set(room.messages.map((m) => m.messageId));
    let added = false;
    for (const msg of remote.messages || []) if (msg && !ids.has(msg.messageId)) { room.messages.push(msg); added = true; }
    if (added) {
      room.messages.sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));
      if (room.messages.length > 500) room.messages.splice(0, room.messages.length - 500);
    }
    for (const a of remote.alerts || []) {
      const cur = room.alerts.get(a.alertId);
      const take = !cur || (a.resolved && !cur.resolved) || (!cur.resolved && !a.resolved && (
        (a.lastUpdateAt || 0) > (cur.lastUpdateAt || 0)
        || ((a.lastUpdateAt || 0) === (cur.lastUpdateAt || 0) && Object.keys(a.responders || {}).length > Object.keys(cur.responders || {}).length)));
      if (take) { room.alerts.set(a.alertId, a); C._indexLiveLink(gid, a); }
    }
    const map = room.clientIds || (room.clientIds = new Map());
    for (const [k, at] of remote.cids || []) if (!(map.get(k) >= at)) map.set(k, at);
    this._afterMerge(room);
    return room;
  }

  /**
   * After remote state was merged: pending swap asks follow the replicated meta (they survive a
   * failover), and the one-LEAD invariant is restored (ConvoyManager.fixDoubleLead).
   */
  _afterMerge(room) {
    const C = this.convoys;
    if (!room || C.rooms.get(room.groupId) !== room) return;
    try { if (typeof C._swapsOf === 'function') C._swapsOf(room, now()); } catch (e) { this.log.warn('[mirror] swaps', e.message); }
    try { if (typeof C.fixDoubleLead === 'function') C.fixDoubleLead(room); } catch (e) { this.log.warn('[mirror] roles', e.message); }
  }

  /** Snapshot merge of one rider: telemetry from the fresher copy, membership fields from the newer meta's side. */
  _mergeRider(room, r, remoteMetaNewer) {
    const cur = room.riders.get(r.userId);
    const base = remoteMetaNewer ? { ...cur, ...r } : { ...r, ...cur };
    const fresher = (Number(r.lastSeenEpochMs) || 0) > (Number(cur.lastSeenEpochMs) || 0) ? r : cur;
    for (const k of TELEMETRY_KEYS) if (fresher[k] !== undefined) base[k] = fresher[k];
    const pres = (Number(r.presenceAt) || 0) > (Number(cur.presenceAt) || 0) ? r : cur;
    base.presence = pres.presence; base.presenceAt = pres.presenceAt;
    room.riders.set(r.userId, base);
  }

  _onPosition(m) {
    const room = this.convoys.rooms.get(m.g);
    const p = m.r;
    const r = room && p && room.riders.get(p.userId);
    if (!r || room.meta.tripStatus === 'ENDED') return;
    if ((Number(p.lastSeenEpochMs) || 0) <= (Number(r.lastSeenEpochMs) || 0)) return;
    const next = { ...r, ...p };
    room.riders.set(p.userId, next);
    this._markDirty(room, p.userId);
    try { if (this.convoys.network) this.convoys.network.onTelemetry(m.g, next); } catch { /* bookkeeping only */ }
    if (this.hub) this.hub._fanoutPosition(m.g, null, next);
  }

  _onVoice(pt) {
    if (!this.hub || pt.length < 3) return;
    const jl = pt.readUInt16BE(1);
    const j = JSON.parse(pt.subarray(3, 3 + jl).toString('utf8'));
    const payload = pt.subarray(3 + jl);
    this.hub.applyRemoteVoice(String(j.g || ''), j.k, j.h, payload, { peerHasFloorAuthority: this._peerPrimary() });
  }

  _endLocal(gid) {
    const C = this.convoys;
    const room = C.rooms.get(gid);
    this._forget(gid);
    if (!room) return;
    clearTimeout(room.persistTimer);
    C.rooms.delete(gid);
    for (const a of room.alerts.values()) { if (a.liveLink && a.liveLink.hash) C.liveLinks.delete(a.liveLink.hash); delete a.medical; }
    C.emit('roomEnded', gid, room);
  }

  // ================================================================ periodic
  _tick() {
    const link = this.linked() ? this.link : null;
    if (link) {
      if (now() - link.lastRx > this.deadMs) { this.log.warn('[mirror] peer silent, dropping the link'); link.ws.terminate(); return; }
      const peerOrigin = this.peer ? `${this.peer.node}#${this.peer.boot}` : '';
      const live = this.hub ? [...this.hub.liveUsers()] : [];
      this._json(link, { t: 'HB', at: now(), st: this.state, role: this.role, rooms: this._localRooms(), n: live.length, ack: this.lastSeen.get(peerOrigin) || 0 }, 0);
      const online = this.hub && typeof this.hub.onlineUsers === 'function' ? [...this.hub.onlineUsers()] : live;
      const lu = `${live.sort().join(',')}|${online.sort().join(',')}`;
      if (lu !== this.lastLU) { this.lastLU = lu; this._json(link, { t: 'LU', u: live, o: online }, 0); }
      this._handback();
    } else if (!this.dialing && !this.dialTimer) {
      this._dial();
    }
    const t = now();
    if (this.told.size > 5000) for (const [u, at] of this.told) if (t - at > HANDBACK_RETELL_MS) this.told.delete(u);
  }

  _lagTick() {
    const t = performance.now();
    const lag = this.lagAt ? Math.max(0, t - this.lagAt - 500) : 0;
    this.lagAt = t;
    this.loopLagMs = lag;
    if (lag > OVERLOAD_LAG_MS) { if (!this.overloadSince) this.overloadSince = now(); } else this.overloadSince = 0;
  }

  _serving(why) {
    if (this.state !== 'syncing') return;
    this.state = 'serving';
    this.log.info?.(`[mirror] ${this.node} serving (${why})`);
  }

  /** Web node: hand riders back to the live node once it has been serving for MIRROR_HANDBACK_DELAY_MS. */
  _handback() {
    const p = this.peer;
    if (this.role === 'live' || !this.hub || !p || p.role !== 'live' || p.state !== 'serving' || !p.servingSince) return;
    if (now() - p.servingSince < this.handbackDelayMs) return;
    const t = now();
    let n = 0;
    for (const ws of this.hub.wss.clients) {
      if (n >= this.handbackPerSec) break;
      if (ws.readyState !== WebSocket.OPEN || ws.reconnectAt || !ws.allowed) continue;
      const uid = ws.user && ws.user.userId;
      if (uid && t - (this.told.get(uid) || 0) < HANDBACK_RETELL_MS) continue;
      if (this.hub.requestReconnect(ws, crypto.randomInt(0, 3001), 'handback')) { n++; if (uid) this.told.set(uid, t); }
    }
    this.stats.handedBack += n;
  }

  // ================================================================ decisions
  /** True when the peer is this pair's primary (GATEWAY_ROLE=live there, or the smaller name among equals). */
  _peerPrimary() {
    const p = this.peer;
    if (!this.linked() || !p) return false;
    if (this.role === 'live') return false;
    if (p.role === 'live') return true;
    if (this.role === 'web' && p.role !== 'web') return true;
    if (p.role === 'web' && this.role !== 'web') return false;
    return p.node < this.node;
  }

  /** True when this node runs the room's background automation (see header). */
  authoritative(gid) {
    if (!this.enabled || !this.linked() || !this.peer) return true;
    const mine = this._hasLocal(gid), theirs = this.peer.rooms.has(gid);
    if (mine !== theirs) return mine;
    return !this._peerPrimary();
  }

  /** True when this node writes the room to the database. */
  shouldPersist(gid) {
    if (!this.enabled || !this.linked() || !this.peer) return true;
    if (this._hasLocal(gid)) return true;
    return !this.peer.rooms.has(gid) && this.authoritative(gid);
  }

  /** Distinct riders with an open room socket on this node and the peer. */
  liveSet() {
    const s = this.hub ? this.hub.liveUsers() : new Set();
    if (this.linked() && this.peer) for (const u of this.peer.live) s.add(u);
    return s;
  }

  /** LIVE_RIDER_CAP reached for a rider who is not live yet. */
  capReached(userId) {
    if (!this.cap) return false;
    const s = this.liveSet();
    if (s.has(userId)) return false;
    return s.size >= this.cap;
  }

  /** GET /api/health/live: { status, body }. */
  health() {
    let state = this.standby && this.state === 'serving' ? 'standby' : this.state;
    if (state === 'serving' && this.overloadSince && now() - this.overloadSince > OVERLOAD_FOR_MS) state = 'overloaded';
    const ok = state === 'serving';
    return {
      status: ok ? 200 : 503,
      body: {
        ok, node: this.node, role: this.role, liveRiders: this.liveSet().size, cap: this.cap,
        mirror: { connected: this.linked(), lagMs: this.linked() && Number.isFinite(this.lagMs) ? Math.round(this.lagMs) : null },
        eventLoopLagMs: Math.round(this.loopLagMs), state,
      },
    };
  }

  // ================================================================ stop
  /**
   * Graceful stop (SIGTERM): 503 at once, the final state of rooms with local sockets to the peer (acknowledged,
   * bounded), then RECONNECT {reason 'shutdown'} to every socket in batches of 100 with 0-3 s jitter.
   */
  /** v3.56: 503 on /api/health/live from now on (the balancer stops sending new riders), sockets stay served. */
  beginDrain() { if (!this.stopped) this.state = 'shutdown'; }

  async shutdown({ drain = true } = {}) {
    if (this.stopped) return;
    this.state = 'shutdown';
    if (this.linked()) {
      this._sendSnapshot(this.link, { onlyLocal: true });
      await this._sendEvent({ g: '', d: {} }, { durable: true, prio: 0 });
    }
    if (drain && this.hub) {
      const socks = [...this.hub.wss.clients].filter((ws) => ws.readyState === WebSocket.OPEN);
      for (let i = 0; i < socks.length; i++) {
        this.hub.requestReconnect(socks[i], crypto.randomInt(0, 3001), 'shutdown', 1000);
        if (i % 100 === 99) await new Promise((r) => setTimeout(r, 50));
      }
      if (socks.length) await new Promise((r) => setTimeout(r, 150));
    }
    this.stop();
  }

  /** Stops timers, the listener and the link. */
  stop({ abrupt = false } = {}) {
    if (this.stopped) return;
    this.stopped = true;
    for (const t of this.timers) { clearInterval(t); clearTimeout(t); }
    if (this.dialTimer) clearTimeout(this.dialTimer);
    for (const [s, p] of this.acks) { clearTimeout(p.timer); p.res(false); this.acks.delete(s); }
    for (const l of [...this.links]) { if (abrupt) l.ws.terminate(); else l.close(1001, 'Shutdown'); }
    if (this.wss) { for (const ws of this.wss.clients) ws.terminate(); this.wss.close(); }
    if (this.server) this.server.close();
  }

  /** Tests: the process dies (no goodbye, sockets dropped). */
  kill() { this.stop({ abrupt: true }); }
}

module.exports = { Mirror, Link };
