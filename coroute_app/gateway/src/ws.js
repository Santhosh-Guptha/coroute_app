'use strict';
/**
 * WebSocket hub.
 *
 * Isolation model: a socket is authenticated at upgrade time (JWT) and is bound
 * to at most ONE convoy room after a successful, membership-checked JOIN. Every
 * broadcast is addressed to a room, and every room-scoped action re-checks that
 * the socket is bound to that room, so nothing — telemetry, chat, alerts or
 * audio — can ever cross from one group to another.
 *
 * Voice is relayed as binary frames so there is no base64 inflation and no
 * JSON parsing on the hot path:
 *
 *   byte 0      kind   0x01 START | 0x02 FRAME | 0x03 END
 *   bytes 1..2  header length (uint16, big-endian)
 *   header      UTF-8 JSON  { to?: userId|null, seq?, sampleRate?, codec?, streamId? }
 *   rest        PCM16LE mono samples (FRAME only)
 *
 * The server rewrites the header, adding { streamId, from, fromName, groupId, ts },
 * and relays to the whole room (to == null) or to exactly one rider (to == userId).
 */
const { WebSocketServer, WebSocket } = require('ws');
const crypto = require('crypto');
const config = require('./config');
const { verifyToken, ROLE_ADMIN, AuthError, identityOf } = require('./auth');
const { ConvoyError, publicRider, publicAlert } = require('./convoys');
const { clientIdOf } = require('./validate');
const { validateChunk, TrackError, uploadPermission } = require('./tracks');
const { visibleWindow, eventVisible, publicEvent } = require('./timeline');
const { RoadHazardRegistry } = require('./road_hazards');

const VOICE_START = 0x01, VOICE_FRAME = 0x02, VOICE_END = 0x03;

const envInt = (k, d) => { const n = parseInt(process.env[k] || '', 10); return Number.isFinite(n) && n >= 0 ? n : d; };
/** Position fan-out for large rooms: above this many sockets each rider's RIDER_UPDATE is throttled to one
 * per WS_COALESCE_MS (leading edge goes out at once; updates inside the window are coalesced, latest wins,
 * and flushed at the window's end), so a 100-rider convoy never multiplies bursts or stale positions. */
const POS_COALESCE_ABOVE = envInt('WS_COALESCE_ABOVE', 20);
const POS_COALESCE_MS = Math.max(50, envInt('WS_COALESCE_MS', 500));
/** A peer with this much unsent data gets no more positions (the next one supersedes them anyway). */
const POS_DROP_BYTES = envInt('WS_POSITION_DROP_BYTES', 256 * 1024);
/** A peer this far behind is a dead or hopeless link: closed (the app reconnects and gets a SNAPSHOT). */
const MAX_BUFFERED_BYTES = Math.max(POS_DROP_BYTES * 2, envInt('WS_MAX_BUFFERED_BYTES', 4 * 1024 * 1024));
/** Open sockets one account may hold at a time. */
const MAX_SOCKETS_PER_USER = Math.max(2, envInt('WS_MAX_SOCKETS_PER_USER', 8));
/** Voice frames per second a single stream may relay (20 ms frames are 50/s). */
const VOICE_MAX_FPS = envInt('VOICE_MAX_FPS', 100);

/**
 * Outbound priority (per socket). While a socket's send buffer is under OUT_SOFT_BYTES everything goes out at
 * once, in order. Above it, messages wait in three lanes drained every OUT_DRAIN_MS: 0 safety and control
 * (SOS, ALERT, RESOLVE, ERROR, ACK, RECONNECT...), 1 roster / chat / everything else, 2 positions (latest per
 * rider only, dropped while the buffer stays over WS_POSITION_DROP_BYTES). Voice is never queued: it is
 * dropped while a socket has a backlog. A socket whose lane 1 backlog passes OUT_MAX_QUEUED is closed (the
 * app reconnects and gets a SNAPSHOT).
 */
const OUT_SOFT_BYTES = Math.min(POS_DROP_BYTES, envInt('WS_OUT_SOFT_BYTES', 128 * 1024));
const OUT_DRAIN_MS = 25;
const OUT_MAX_QUEUED = 5000;
const PRIO_0 = new Set(['ALERT', 'ALERT_RESOLVED', 'SOS_RESPONSE', 'EMERGENCY_UPDATE', 'ERROR', 'ACK', 'RECONNECT', 'RIDER_BATTERY_SHUTDOWN',
  'DISSOLVED', 'TRIP_STATUS', 'HELLO', 'ASSIST_REQUEST', 'ROAD_HAZARD']);
/** A rider whose last activity in a ride is older than this, and who is live nowhere, is a new live rider for the cap. */
const LIVE_REJOIN_GRACE_MS = envInt('LIVE_REJOIN_GRACE_MS', 15 * 60000);

/** Intercom sample rates: 16 kHz, and 8 kHz from phones in data saver mode. */
const VOICE_RATES = new Set([8000, 16000]);

/** Socket messages limited by the per-second action budget. */
const ACTION_TYPES = new Set([
  'STATUS', 'CORIDER', 'STOP_ADD', 'STOP_SUGGEST', 'STOP_ACCEPT', 'STOP_DECLINE', 'STOP_REMOVE', 'STOP_SKIP', 'STOP_REORDER',
  'STOP_VISITED', 'ROUTE_SET', 'CONFIG', 'TIMELINE_SINCE', 'SOS_RESOLVE', 'TRIP_STATUS',
  // These read the database too (membership, convoy load, fleet).
  'JOIN', 'LEAVE', 'ADMIN_SUBSCRIBE',
  // 3.14
  'SOS_RESPOND', 'BYE',
  // 3.15
  'ASSIST_ANSWER', 'NET_REPORT_FALSE', 'WAVE',
  // 3.16
  'ROLE_SET', 'MIC_STATE',
  // 4.0
  'REGROUP_SET', 'REGROUP_CLEAR', 'LAST_GASP_BEACON',
  // FEAT-02
  'ROAD_HAZARD',
]);
/** Socket messages that alert the whole convoy: a few per 10 seconds, each type with its own budget
 * (a rider who just asked the group to wait must still be able to raise an SOS). */
const ALARM_TYPES = new Set(['WAIT', 'SOS', 'CHECK_IN', 'REPORT_DOWN']);
/** Messages that may carry a clientId (phone outbox): applied once, answered with ACK. */
const CLIENT_ID_TYPES = new Set(['CHAT', 'WAIT', 'STATUS', 'STOP_VISITED', 'SOS_RESPOND', 'CHECK_IN', 'REPORT_DOWN', 'ASSIST_ANSWER', 'NET_REPORT_FALSE', 'WAVE', 'ROLE_SET', 'REGROUP_SET', 'REGROUP_CLEAR']);
const BYE_REASONS = new Set(['APP_CLOSED', 'SIGN_OUT', 'LEFT']);
/** Protocol features this gateway offers (HELLO.features); 3.14 apps use a feature only when listed. */
const FEATURES_314 = ['ack', 'sos2', 'respond', 'presence', 'checkin', 'roster'];
/** 3.15: safety network and discovery, appended when switched on. */
/** 3.16: sweeper role, follow-up check-in, town limit, live links (always on). */
const FEATURES = [...FEATURES_314, ...(config.safetyNetEnabled ? ['net1'] : []), ...(config.discoveryEnabled ? ['discovery1'] : []), ...(config.publicRideEnabled ? ['pubride1'] : []), 'ride316', 'featurePolicy1', 'bin1'];
/** Client capabilities a 3.15 app sends with JOIN. Server-to-client types added in 3.15 go only to sockets with 'net1'. */
const CAP = /^[a-z0-9]{1,16}$/;
const INCIDENT_ID = /^NET-[0-9A-F]{12}$/;
const ENCOUNTER_ID = /^ENC-[0-9A-F]{12}$/;

function encodeVoice(kind, header, payload) {
  const h = Buffer.from(JSON.stringify(header), 'utf8');
  const out = Buffer.allocUnsafe(3 + h.length + (payload ? payload.length : 0));
  out[0] = kind; out.writeUInt16BE(h.length, 1); h.copy(out, 3);
  if (payload) payload.copy(out, 3 + h.length);
  return out;
}

function decodeVoice(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 3) return null;
  const kind = buf[0];
  const hl = buf.readUInt16BE(1);
  if (hl > 2048 || buf.length < 3 + hl) return null;
  let header;
  try { header = JSON.parse(buf.subarray(3, 3 + hl).toString('utf8')); } catch { return null; }
  return { kind, header, payload: buf.subarray(3 + hl) };
}

class Hub {
  /**
   * @param {{server: import('http').Server, convoys: import('./convoys').ConvoyManager, repo: any, logger?: any}} deps
   */
  constructor({ server, convoys, repo, tracks = null, timeline = null, logger = console, path = '/ws', gate = null, network = null, discovery = null, emergencyGateway = null, publicRides = null }) {
    this.convoys = convoys; this.repo = repo; this.tracks = tracks; this.timeline = timeline; this.log = logger; this.gate = gate;
    this.network = network; this.discovery = discovery;
    /** Public ride and road warnings (src/public_ride.js); null when not wired. */
    this.publicRides = publicRides;
    this.emergencyGateway = emergencyGateway || convoys?.emergencyGateway;
    this.rooms = new Map(); // groupId -> Set<ws>
    this.byUser = new Map(); // userId -> Set<ws> (3.15 personal messages)
    this.admins = new Set();
    this.voice = new Map();
    this.roadHazards = new RoadHazardRegistry(); // groupId -> { group: stream|null, private: Map<from, stream> }
    this.posPending = new Map(); // groupId -> Map<userId, RIDER_UPDATE json> (large rooms, coalesced)
    this.posTimers = new Map(); // groupId -> flush timer
    this.posSentAt = new Map(); // groupId -> Map<userId, last fan-out time> (large rooms)
    this.stats = { posIn: 0, posOut: 0, posDropped: 0, posCoalesced: 0, slowKicked: 0, queued: 0 };
    this.outPending = new Set(); // sockets with queued outbound messages (see OUT_SOFT_BYTES)
    this.outTimer = null;
    /** Two-node live mirror (src/mirror.js), set by app.js; null on a single node. */
    this.mirror = null;
    this.wss = new WebSocketServer({ server, path, maxPayload: 256 * 1024 });
    this.wss.on('connection', (ws, req) => this._onConnection(ws, req));

    convoys.on('event', (groupId, payload, opts) => this.broadcast(groupId, payload, opts));
    // The sender's own copy of a durable event, after it was stored and the peer gateway has it.
    convoys.on('echo', (groupId, payload, userId) => this.broadcast(groupId, payload, { onlyUser: userId }));
    convoys.on('broadcast', (entry) => this.broadcastAll({ type: 'BROADCAST', message: entry.message, ts: entry.timestamp }));
    convoys.on('fleet', () => this._scheduleFleet());
    convoys.featureAnalytics?.on('change', () => this._scheduleFleet());
    // 3.15: room messages only 3.15 apps understand (EMERGENCY_UPDATE).
    convoys.on('capEvent', (groupId, cap, payload) => this.broadcastCap(groupId, cap, payload));
    // An ended ride: no queued positions or voice floor survive it.
    convoys.on('roomEnded', (groupId) => this._dropRoomState(groupId));

    this.heartbeat = setInterval(() => {
      for (const ws of this.wss.clients) {
        if (ws.isAlive === false) { ws.terminate(); continue; }
        ws.isAlive = false; ws.ping();
      }
    }, 30000);
    if (this.heartbeat.unref) this.heartbeat.unref();
    this.fleetTimer = setInterval(() => this._pushFleet().catch(() => {}), 15000);
    if (this.fleetTimer.unref) this.fleetTimer.unref();
  }

  close() {
    // Sockets closed by a restart are not "no signal": presence is left as it was.
    this.closing = true;
    clearInterval(this.heartbeat); clearInterval(this.fleetTimer);
    if (this.outTimer) { clearTimeout(this.outTimer); this.outTimer = null; }
    for (const t of this.posTimers.values()) clearTimeout(t);
    this.posTimers.clear(); this.posPending.clear();
    this.wss.close();
  }

  _dropRoomState(groupId) {
    const t = this.posTimers.get(groupId);
    if (t) clearTimeout(t);
    this.posTimers.delete(groupId); this.posPending.delete(groupId); this.posSentAt.delete(groupId);
    this.voice.delete(groupId);
  }

  /** The room for a live-position message, or null (once per socket: ERROR 409 RIDE_ENDED) when the ride ended. */
  async _liveRoom(ws, gid) {
    const room = await this.convoys.getRoom(gid);
    if (room.meta.tripStatus !== 'ENDED') return room;
    if (!ws.rideEndedSent) { ws.rideEndedSent = true; this.sendError(ws, 409, 'This ride has ended.', 'RIDE_ENDED'); }
    return null;
  }

  /**
   * Position fan-out with backpressure. Small rooms: at once to every other socket. Large rooms
   * (> WS_COALESCE_ABOVE sockets): the rider's latest update is queued and flushed with everyone
   * else's every WS_COALESCE_MS. Either way a peer whose send buffer is over WS_POSITION_DROP_BYTES
   * skips positions (stale ones are worthless) and one over WS_MAX_BUFFERED_BYTES is closed.
   */
  _fanoutPosition(gid, fromWs, rider) {
    const set = this.rooms.get(gid);
    this.stats.posIn++;
    if (!set || !rider) return;
    const msg = JSON.stringify({ type: 'RIDER_UPDATE', rider: publicRider(rider), ts: Date.now() });
    if (set.size > POS_COALESCE_ABOVE) {
      const t = Date.now();
      let sentAt = this.posSentAt.get(gid);
      if (!sentAt) { sentAt = new Map(); this.posSentAt.set(gid, sentAt); }
      let pending = this.posPending.get(gid);
      if (!pending) { pending = new Map(); this.posPending.set(gid, pending); }
      if (!pending.has(rider.userId) && t - (sentAt.get(rider.userId) || 0) >= POS_COALESCE_MS) {
        sentAt.set(rider.userId, t);
        return this._sendPosition(set, msg, fromWs ? null : rider.userId, fromWs, rider.userId);
      }
      if (pending.has(rider.userId)) this.stats.posCoalesced++;
      pending.set(rider.userId, msg);
      if (!this.posTimers.has(gid)) {
        const timer = setTimeout(() => this._flushPositions(gid), POS_COALESCE_MS);
        if (timer.unref) timer.unref();
        this.posTimers.set(gid, timer);
      }
      return;
    }
    // A position relayed from the peer gateway (no local sender socket) never goes back to its own rider.
    this._sendPosition(set, msg, fromWs ? null : rider.userId, fromWs, rider.userId);
  }

  _flushPositions(gid) {
    this.posTimers.delete(gid);
    const pending = this.posPending.get(gid);
    this.posPending.delete(gid);
    const set = this.rooms.get(gid);
    const room = this.convoys.rooms.get(gid);
    if (!pending || !set || !room) return;
    const sentAt = this.posSentAt.get(gid);
    const t = Date.now();
    // A rider who left while queued is never brought back by a late position.
    for (const [uid, msg] of pending) {
      if (!room.riders.has(uid)) { if (sentAt) sentAt.delete(uid); continue; }
      if (sentAt) sentAt.set(uid, t);
      this._sendPosition(set, msg, uid, null, uid);
    }
  }

  _sendPosition(set, msg, fromUid, exceptWs, posUid = fromUid) {
    for (const peer of set) {
      if (peer === exceptWs || peer.readyState !== WebSocket.OPEN) continue;
      if (fromUid && peer.user && peer.user.userId === fromUid) continue;
      if (peer.bufferedAmount > MAX_BUFFERED_BYTES) { this.stats.slowKicked++; this._kick(peer, 1013, 'SLOW_LINK'); continue; }
      if (peer.bufferedAmount > POS_DROP_BYTES) { this.stats.posDropped++; continue; }
      this._out(peer, msg, 2, posUid);
      this.stats.posOut++;
    }
  }

  // ------------------------------------------------------------- outbound priority
  /** Lane of a server message: 0 safety/control, 1 the rest (positions use lane 2 in _sendPosition). */
  static prioOf(payload) { return payload && PRIO_0.has(payload.type) ? 0 : 1; }

  /**
   * Sends now when the socket has no backlog and its buffer is under OUT_SOFT_BYTES; otherwise queues in
   * its lane (lane 2: one pending position per rider, the newest). Returns false for a closed socket.
   */
  _out(ws, data, prio = 1, key = null) {
    if (ws.readyState !== WebSocket.OPEN) return false;
    if (!ws.outq && !(ws.bufferedAmount > OUT_SOFT_BYTES)) { ws.send(data); return true; }
    if (!ws.outq) { ws.outq = [[], [], new Map()]; this.outPending.add(ws); }
    this.stats.queued++;
    if (prio === 2) {
      const k = key || `_${this.stats.queued}`;
      ws.outq[2].delete(k); // keeps lane order by arrival of the newest
      ws.outq[2].set(k, data);
    } else {
      ws.outq[prio].push(data);
      if (ws.outq[1].length > OUT_MAX_QUEUED) { this.stats.slowKicked++; this._dropOut(ws); this._kick(ws, 1013, 'SLOW_LINK'); return false; }
    }
    this._armOut();
    return true;
  }

  _armOut() {
    if (this.outTimer || this.closing) return;
    this.outTimer = setTimeout(() => { this.outTimer = null; this._drainOut(); }, OUT_DRAIN_MS);
    if (this.outTimer.unref) this.outTimer.unref();
  }

  _dropOut(ws) { ws.outq = null; this.outPending.delete(ws); }

  _drainOut() {
    for (const ws of [...this.outPending]) {
      if (ws.readyState !== WebSocket.OPEN || !ws.outq) { this._dropOut(ws); continue; }
      const [q0, q1, q2] = ws.outq;
      while (!(ws.bufferedAmount > OUT_SOFT_BYTES)) {
        if (q0.length) { ws.send(q0.shift()); continue; }
        if (q1.length) { ws.send(q1.shift()); continue; }
        if (q2.size) {
          const [k, data] = q2.entries().next().value;
          q2.delete(k);
          if (ws.bufferedAmount > POS_DROP_BYTES) { this.stats.posDropped++; continue; }
          ws.send(data);
          continue;
        }
        break;
      }
      if (!q0.length && !q1.length && !q2.size) this._dropOut(ws);
    }
    if (this.outPending.size) this._armOut();
  }

  // ------------------------------------------------------------- helpers
  send(ws, obj) { if (ws.readyState === WebSocket.OPEN) this._out(ws, JSON.stringify(obj), Hub.prioOf(obj)); }
  sendError(ws, code, message, reason, clientId) {
    this.send(ws, { type: 'ERROR', code, message, ...(reason ? { reason } : {}), ...(clientId ? { clientId } : {}) });
  }

  /**
   * Room broadcast. `except`: one socket left out; `exceptUser` / `onlyUser`: every socket of that rider
   * left out / only that rider's sockets (the held-back sender echo of durable events).
   */
  broadcast(groupId, payload, { except, exceptUser, onlyUser } = {}) {
    const set = this.rooms.get(groupId);
    if (!set) return;
    const msg = JSON.stringify(payload);
    const prio = Hub.prioOf(payload);
    for (const ws of set) {
      if (ws === except || ws.readyState !== WebSocket.OPEN) continue;
      const uid = ws.user && ws.user.userId;
      if (exceptUser && uid === exceptUser) continue;
      if (onlyUser && uid !== onlyUser) continue;
      this._out(ws, msg, prio);
    }
  }
  /** Room broadcast that the peer gateway repeats to its own sockets of the room (messages not from ConvoyManager). */
  roomSend(groupId, payload, opts) {
    this.broadcast(groupId, payload, opts);
    if (this.mirror) this.mirror.wire(groupId, payload);
  }
  /** Distinct riders with an open socket bound to a room on this node. */
  liveUsers() {
    const out = new Set();
    for (const set of this.rooms.values()) for (const ws of set) if (ws.readyState === WebSocket.OPEN && ws.user) out.add(ws.user.userId);
    return out;
  }
  /** Tells a socket to reconnect (through the load balancer) after delayMs; closed by us if it has not gone after a grace. */
  requestReconnect(ws, delayMs, reason, graceMs = 10000) {
    if (ws.readyState !== WebSocket.OPEN || ws.reconnectAt) return false;
    ws.reconnectAt = Date.now();
    this.send(ws, { type: 'RECONNECT', delayMs: Math.max(0, Math.round(delayMs)), reason });
    const t = setTimeout(() => { if (ws.readyState === WebSocket.OPEN) this._kick(ws, 1012, reason === 'shutdown' ? 'SHUTDOWN' : 'HANDBACK'); }, delayMs + graceMs);
    if (t.unref) t.unref();
    return true;
  }
  /** Room broadcast to sockets that announced `cap` in their JOIN (3.15 types never reach older apps). */
  broadcastCap(groupId, cap, payload) {
    const set = this.rooms.get(groupId);
    if (!set) return 0;
    const msg = JSON.stringify({ ts: Date.now(), ...payload });
    const prio = Hub.prioOf(payload);
    let n = 0;
    for (const ws of set) if (ws.caps && ws.caps.has(cap) && ws.readyState === WebSocket.OPEN) { this._out(ws, msg, prio); n++; }
    return n;
  }
  /** Personal message to every open socket of a user that announced `cap`. Returns how many got it. */
  sendToUser(userId, payload, cap, { local = false } = {}) {
    const set = this.byUser.get(userId);
    // Not connected here: the peer gateway may hold the rider's socket (hand-back / failover window).
    if (!set) { if (!local && this.mirror) this.mirror.user(userId, payload, cap); return 0; }
    const msg = JSON.stringify({ ts: Date.now(), ...payload });
    const prio = Hub.prioOf(payload);
    let n = 0;
    for (const ws of set) if ((!cap || (ws.caps && ws.caps.has(cap))) && ws.allowed && ws.readyState === WebSocket.OPEN) { this._out(ws, msg, prio); n++; }
    if (!n && !local && this.mirror) this.mirror.user(userId, payload, cap);
    return n;
  }
  /** True when the user has an open, allowed socket with `cap` bound to a room. */
  online(userId, cap) {
    const set = this.byUser.get(userId);
    if (!set) return false;
    for (const ws of set) if ((!cap || (ws.caps && ws.caps.has(cap))) && ws.allowed && ws.groupId && ws.readyState === WebSocket.OPEN) return true;
    return false;
  }
  _index(ws) {
    const uid = ws.user && ws.user.userId;
    if (!uid) return;
    let set = this.byUser.get(uid);
    if (!set) { set = new Set(); this.byUser.set(uid, set); }
    // Sockets per account are bounded: the oldest (usually a dead link not yet reaped by the
    // heartbeat after a reconnect) makes room, so one token cannot hold hundreds of sockets.
    while (set.size >= MAX_SOCKETS_PER_USER) {
      const oldest = set.values().next().value;
      set.delete(oldest);
      this._kick(oldest, 1008, 'TOO_MANY_SOCKETS');
    }
    set.add(ws);
  }
  _unindex(ws) {
    const uid = ws.user && ws.user.userId;
    const set = uid && this.byUser.get(uid);
    if (!set) return;
    set.delete(ws);
    if (!set.size) this.byUser.delete(uid);
  }

  broadcastAll(payload) {
    const msg = JSON.stringify(payload);
    for (const ws of this.wss.clients) if (ws.readyState === WebSocket.OPEN) this._out(ws, msg, 1);
  }

  _bind(ws, groupId) {
    this._unbind(ws);
    ws.groupId = groupId;
    if (!this.rooms.has(groupId)) this.rooms.set(groupId, new Set());
    this.rooms.get(groupId).add(ws);
  }
  _unbind(ws) {
    if (!ws.groupId) return;
    this._endVoiceStreamsOf(ws);
    const set = this.rooms.get(ws.groupId);
    if (set) { set.delete(ws); if (set.size === 0) this.rooms.delete(ws.groupId); }
    ws.groupId = null;
  }

  _scheduleFleet() {
    if (this.fleetPending || this.admins.size === 0) return;
    this.fleetPending = setTimeout(() => { this.fleetPending = null; this._pushFleet().catch(() => {}); }, 1000);
  }
  async _pushFleet() {
    if (this.admins.size === 0) return;
    // Every subscriber passes the (cached) account gate again: a demoted, blocked or deleted
    // admin whose socket sends nothing must not keep receiving every convoy's live positions.
    await Promise.all([...this.admins].map((ws) => this._gateCheck(ws)));
    if (this.admins.size === 0) return;
    const fleet = await this.convoys.fleet();
    const msg = JSON.stringify({ type: 'FLEET', convoys: fleet, featureAnalytics: this.convoys.featureAnalytics?.snapshot(), ts: Date.now() });
    for (const ws of this.admins) if (ws.readyState === WebSocket.OPEN && ws.allowed && ws.user.role === ROLE_ADMIN) ws.send(msg);
  }

  // ---------------------------------------------------------- connection
  _onConnection(ws, req) {
    let token = null;
    try {
      const url = new URL(req.url, 'http://localhost');
      token = url.searchParams.get('token');
    } catch { /* ignore */ }
    if (!token) {
      const h = req.headers['authorization'] || '';
      if (h.startsWith('Bearer ')) token = h.slice(7);
    }
    const claims = token && verifyToken(token);
    if (!claims) { ws.close(4401, 'Unauthorized'); return; }

    ws.claims = claims;
    ws.user = { userId: claims.sub, name: claims.name, role: claims.role, email: claims.email };
    ws.isAlive = true;
    ws.groupId = null;
    ws.allowed = false; // nothing (JSON or voice) is acted on until the account gate passed
    ws.rate = { telemetry: 0, chat: 0, track: 0, action: 0, windowStart: Date.now() };
    ws.alarms = { WAIT: [], SOS: [], CHECK_IN: [], REPORT_DOWN: [] };
    ws.byeReason = null;
    ws.caps = new Set();
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('message', (data, isBinary) => {
      if (isBinary) {
        if (!ws.allowed) return;
        const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
        if (buf.length > 0 && buf[0] === 0x10) {
          this._onBinaryTelemetry(ws, buf).catch((e) => this._handleError(ws, e));
          return;
        }
        this._onVoice(ws, data);
        return;
      }
      this._onJson(ws, data).catch((e) => this._handleError(ws, e));
    });
    ws.on('close', () => {
      const gid = ws.groupId;
      this._dropOut(ws);
      this._unbind(ws);
      this._unindex(ws);
      this.admins.delete(ws);
      if (gid) this._presenceOnClose(ws, gid);
    });
    ws.on('error', () => { /* close handler runs */ });
    ws.ready = this._gateCheck(ws).then((ok) => {
      if (ok && ws.readyState === WebSocket.OPEN) this._index(ws);
      if (ok) this.send(ws, { type: 'HELLO', userId: ws.user.userId, serverTime: Date.now(), heartbeatSec: 30, protocol: 2, features: FEATURES });
      return ok;
    });
  }

  /** Close code for an account the gate refused: 4403 hold/block (do not retry), 4401 gone or signed out. */
  static closeCodeFor(e) {
    return e && (e.code === 'ACCOUNT_ON_HOLD' || e.code === 'ACCOUNT_BLOCKED') ? 4403 : 4401;
  }

  /** Runs the account gate for a socket; refreshes its identity or closes it. Resolves to true when allowed. */
  async _gateCheck(ws) {
    if (!this.gate) { ws.allowed = true; return true; }
    try {
      const user = await this.gate.check(ws.claims);
      ws.user = identityOf(user);
      if (ws.user.role !== ROLE_ADMIN) this.admins.delete(ws);
      ws.allowed = true;
      return true;
    } catch (e) {
      ws.allowed = false;
      if (e instanceof AuthError) {
        this._kick(ws, Hub.closeCodeFor(e), e.code || 'Unauthorized');
      } else {
        this.log.warn('[ws] account check failed', e.message);
        this._kick(ws, 1011, 'Try again');
      }
      return false;
    }
  }

  _kick(ws, code, reason) {
    ws.allowed = false;
    this._dropOut(ws);
    this._unbind(ws);
    this.admins.delete(ws);
    try { ws.close(code, String(reason).slice(0, 100)); } catch { /* already closing */ }
    // A peer that never answers the close handshake is dropped anyway.
    const t = setTimeout(() => { try { ws.terminate(); } catch { /* gone */ } }, 2000);
    if (t.unref) t.unref();
  }

  /** Ends every socket of one account at once (hold, block, delete). */
  disconnectUser(userId, code = 4401, reason = 'ACCOUNT_GONE') {
    let n = 0;
    for (const ws of this.wss.clients) {
      if (ws.user && ws.user.userId === userId) { this._kick(ws, code, reason); n++; }
    }
    return n;
  }

  _handleError(ws, e) {
    // Not stored yet (database trouble): the sender gets nothing, so its phone resends.
    if (e && e.silent) return;
    if (e instanceof ConvoyError || e instanceof TrackError) return this.sendError(ws, e.status, e.message, e.reason, e.clientId);
    this.log.warn('[ws] error', e.message);
    this.sendError(ws, 500, 'Internal error', undefined, e && e.clientId);
  }

  /**
   * Presence when a socket bound to a room closes (3.14): only when the rider has no other open
   * socket in that room. A BYE before the close means the app was closed; no BYE means no signal
   * (heartbeat timeout, network drop, process killed). LEFT: nothing (LEAVE handles it).
   */
  _presenceOnClose(ws, gid) {
    if (this.closing || !ws.user || !ws.allowed) return;
    const uid = ws.user.userId;
    const set = this.rooms.get(gid);
    if (set && [...set].some((c) => c !== ws && c.user && c.user.userId === uid && c.readyState === WebSocket.OPEN)) return;
    if (ws.byeReason === 'LEFT') return;
    const presence = ws.byeReason === 'APP_CLOSED' || ws.byeReason === 'SIGN_OUT' ? 'APP_CLOSED' : 'NO_SIGNAL';
    try { this.convoys.setPresence(gid, uid, presence); } catch (e) { this.log.warn('[ws] presence failed', e.message); }
  }

  _allow(ws, bucket, limitPerSec) {
    const t = Date.now();
    if (t - ws.rate.windowStart >= 1000) { ws.rate.windowStart = t; ws.rate.telemetry = 0; ws.rate.chat = 0; ws.rate.track = 0; ws.rate.action = 0; }
    return ++ws.rate[bucket] <= limitPerSec;
  }

  /** WAIT and SOS: a few per 10 seconds (each writes to the database and alerts everyone). */
  _allowAlarm(ws, type) {
    const t = Date.now();
    const recent = (ws.alarms[type] || []).filter((x) => t - x < 10000);
    ws.alarms[type] = recent;
    if (recent.length >= config.wsAlarmsPer10s) return false;
    recent.push(t);
    return true;
  }

  /**
   * LIVE_RIDER_CAP on a socket JOIN: a member who is coming back to the ride (active in it within
   * LIVE_REJOIN_GRACE_MS: joined, seen or presence changed) or who has an open SOS in it is never refused.
   */
  _rejoining(groupId, userId) {
    const room = this.convoys.rooms.get(groupId);
    const r = room && room.riders.get(userId);
    if (!r) return true; // loaded from the database just now: a member of a live ride
    const t = Date.now();
    const last = Math.max(Number(r.lastSeenEpochMs) || 0, Number(r.presenceAt) || 0, Number(r.joinedAt) || 0);
    if (t - last < LIVE_REJOIN_GRACE_MS) return true;
    for (const a of room.alerts.values()) if (!a.resolved && a.userId === userId) return true;
    return false;
  }

  _requireRoom(ws) {
    if (!ws.groupId) throw new ConvoyError('Join a convoy first.', 409, 'NOT_JOINED');
    return ws.groupId;
  }

  async _onBinaryTelemetry(ws, buf) {
    if (!Buffer.isBuffer(buf) || buf.length < 24) return;
    if (!(await ws.ready)) return;
    if (!(await this._gateCheck(ws))) return;
    const gid = ws.groupId;
    if (!gid) return;
    if (!this._allow(ws, 'telemetry', 3)) return; // silently drop bursts
    const room = await this._liveRoom(ws, gid);
    if (!room) return;
    const tsOffset = buf.readUInt32BE(1);
    const lat = buf.readInt32BE(5) / 1e6;
    const lng = buf.readInt32BE(9) / 1e6;
    if (Math.abs(lat) > 90 || Math.abs(lng) > 180) return; // corrupt frame: never moves the rider
    const speedKmh = buf.readUInt16BE(13) / 10;
    const heading = buf.readUInt16BE(15) / 10;
    const batByte = buf.readUInt8(17);
    const batteryLevel = batByte & 0x7F;
    const isCharging = (batByte & 0x80) !== 0;
    const usableFuelKm = buf.readUInt8(18) * 2;
    const flags = buf.readUInt8(19);
    const stopped = Boolean(flags & 0x01);
    const offRoute = Boolean(flags & 0x02);
    const sos = Boolean(flags & 0x04);
    const tunnel = Boolean(flags & 0x08);
    const seq = buf.readUInt32BE(20);

    const patch = {
      lat,
      lng,
      speedKmh,
      heading,
      batteryLevel,
      isCharging,
      ...(usableFuelKm > 0 ? { fuelEstimate: { usableRangeKm: usableFuelKm } } : {}),
    };
    if (stopped) {
      patch.statusReason = 'STOPPED';
    } else if (offRoute) {
      patch.statusReason = 'OFF_ROUTE';
    }
    const rider = this.convoys.patchRider(room, ws.user.userId, patch, { emit: false });
    // Relayed as JSON RIDER_UPDATE: the raw 24-byte frame carries no sender id, so a peer could
    // not tell whose position it is (and the sender could not be trusted to say).
    this._fanoutPosition(gid, ws, rider);
    if (this.mirror && rider) this.mirror.position(gid, rider);
  }

  async _onJson(ws, data) {
    if (!(await ws.ready)) return;
    // Re-check the account through the cached gate (no DB read inside the TTL): a hold, block,
    // delete, demotion or password change applies to an open socket too.
    if (!(await this._gateCheck(ws))) return;
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { return this.sendError(ws, 400, 'Malformed JSON'); }
    if (!msg || typeof msg !== 'object' || Array.isArray(msg)) return this.sendError(ws, 400, 'Malformed JSON');
    // Outbox messages (3.14): a valid clientId makes the message idempotent and earns an ACK.
    // An invalid clientId is treated as absent (old behaviour).
    const cid = CLIENT_ID_TYPES.has(msg.type) ? clientIdOf(msg.clientId) : '';
    try {
      return await this._dispatch(ws, msg, cid);
    } catch (e) {
      if (cid && e && typeof e === 'object') e.clientId = cid;
      throw e;
    }
  }

  /** Runs an outbox message once per (rider, clientId) in the room, then ACKs it to the sender. */
  async _once(ws, cid, type, apply) {
    if (!cid) return apply();
    const gid = this._requireRoom(ws);
    const room = await this.convoys.getRoom(gid);
    if (this.convoys.seenClientId(room, ws.user.userId, cid, type)) {
      return this.send(ws, { type: 'ACK', clientId: cid, duplicate: true, ts: Date.now() });
    }
    await apply();
    this.convoys.rememberClientId(room, ws.user.userId, cid);
    return this.send(ws, { type: 'ACK', clientId: cid, duplicate: false, ts: Date.now() });
  }

  async _dispatch(ws, msg, cid) {
    const u = ws.user;
    // Every message that writes to the database has a budget per socket.
    if (ACTION_TYPES.has(msg.type) && !this._allow(ws, 'action', config.wsActionsPerSec)) throw new ConvoyError('Slow down.', 429);
    if (ALARM_TYPES.has(msg.type) && !this._allowAlarm(ws, msg.type)) throw new ConvoyError('Slow down.', 429);
    switch (msg.type) {
      case 'PING': return this.send(ws, { type: 'PONG', ts: Date.now() });

      case 'JOIN': {
        const groupId = String(msg.groupId || '');
        if (groupId.length > 64) throw new ConvoyError('You are not a member of this convoy.', 403, 'NOT_MEMBER');
        if (!(await this.convoys.isMember(groupId, u.userId))) throw new ConvoyError('You are not a member of this convoy.', 403, 'NOT_MEMBER');
        if (this.mirror && this.mirror.capReached(u.userId) && !this._rejoining(groupId, u.userId)) {
          throw new ConvoyError('Server busy, try in a few minutes', 503, 'SERVER_BUSY');
        }
        this._bind(ws, groupId);
        ws.byeReason = null;
        // 3.15 client capabilities, on every JOIN (array of at most 8 short words, unknown ones ignored).
        ws.caps = new Set(Array.isArray(msg.caps) ? msg.caps.slice(0, 8).filter((c) => typeof c === 'string' && CAP.test(c)) : []);
        const room = await this.convoys.getRoom(groupId);
        this.send(ws, { type: 'SNAPSHOT', convoy: this.convoys.snapshot(room), ts: Date.now() });
        if (ws.caps.has('net1') && this.network) {
          try { this.network.resend(u.userId); } catch (e) { this.log.warn('[ws] resend failed', e.message); }
        }
        // 3.14: the phone says Android closed the app last time (no clean exit).
        if (msg.prevExit === 'KILLED' && this.timeline) {
          const t = Date.now();
          const at = Number.isFinite(Number(msg.prevAliveAt)) && msg.prevAliveAt !== null && typeof msg.prevAliveAt !== 'boolean'
            ? Math.round(Math.max(t - 48 * 3600000, Math.min(t, Number(msg.prevAliveAt)))) : 0;
          await this.timeline.markKilled(groupId, u.userId, at);
        }
        this.convoys.setPresence(groupId, u.userId, 'ONLINE');
        return;
      }
      case 'BYE': {
        // Recorded only; presence changes when the socket closes. Repeats are ignored.
        if (!ws.byeReason) ws.byeReason = BYE_REASONS.has(msg.reason) ? msg.reason : 'APP_CLOSED';
        return;
      }
      case 'LEAVE': {
        const gid = ws.groupId;
        this._unbind(ws);
        if (gid && msg.leaveConvoy) await this.convoys.leave(gid, u.userId);
        return this.send(ws, { type: 'LEFT', groupId: gid });
      }

      case 'TELEMETRY': {
        const gid = this._requireRoom(ws);
        if (!this._allow(ws, 'telemetry', 3)) return; // silently drop bursts
        const room = await this._liveRoom(ws, gid);
        if (!room) return;
        // Only telemetry fields are applied (never role or profile); see ConvoyManager.patchRider.
        const rider = this.convoys.patchRider(room, u.userId, msg, { emit: false });
        this._fanoutPosition(gid, ws, rider);
        if (this.mirror && rider) this.mirror.position(gid, rider);
        return;
      }
      case 'STATUS': return this._once(ws, cid, 'STATUS', async () => {
        const gid = this._requireRoom(ws);
        const room = await this.convoys.getRoom(gid);
        const patch = { statusReason: String(msg.statusReason ?? '').slice(0, 24), statusMessage: String(msg.statusMessage ?? '').slice(0, 140) };
        patch.stoppedSince = patch.statusReason ? (msg.stoppedSince || Date.now()) : 0;
        const prevReason = room.riders.get(u.userId)?.statusReason || '';
        const next = this.convoys.patchRider(room, u.userId, patch);
        if (patch.statusReason !== prevReason) {
          this.convoys.emit('activity', gid, { type: 'STATUS', user: u, reason: patch.statusReason, message: patch.statusMessage, lat: next.lat, lng: next.lng });
        }
      });
      case 'CORIDER': {
        const gid = this._requireRoom(ws);
        const room = await this.convoys.getRoom(gid);
        const driver = String(msg.ridingWithUserId || '');
        if (driver && !room.riders.has(driver)) throw new ConvoyError('Driver is not in this convoy.');
        const was = room.riders.get(u.userId)?.ridingWithUserId || '';
        this.convoys.patchRider(room, u.userId, { isCoRiding: !!driver, ridingWithUserId: driver }, { trusted: true });
        if (was !== driver) this.convoys.emit('activity', gid, { type: 'CORIDE', user: u, withUserId: driver });
        return;
      }
      case 'CHAT': {
        const gid = this._requireRoom(ws);
        if (!this._allow(ws, 'chat', 5)) throw new ConvoyError('Slow down.', 429);
        return this._once(ws, cid, 'CHAT', () => this.convoys.sendMessage(gid, u, {
          text: msg.text, isQuickCard: msg.isQuickCard, cardType: msg.cardType, clientId: cid, sentAt: msg.sentAt,
        }));
      }
      case 'WAIT': return this._once(ws, cid, 'WAIT', () => this.convoys.requestWait(this._requireRoom(ws), u));
      case 'SOS': {
        const gid = this._requireRoom(ws);
        const r = await this.convoys.raiseSos(gid, u, msg);
        if (!r.duplicate && (this.emergencyGateway || this.convoys?.emergencyGateway)) {
          const gw = this.emergencyGateway || this.convoys?.emergencyGateway;
          gw.dispatchForSos({ groupId: gid, user: u, alert: r.alert, msg }).catch((err) => {
            this.log.warn('[ws] Emergency gateway dispatch failed', err.message);
          });
        }
        // A retried SOS: only the sender hears it again, so the phone can mark it delivered. Never while it
        // is not stored (database trouble): the phone keeps resending and each resend tries the store again.
        if (r.duplicate && r.persisted !== false) this.send(ws, { type: 'ALERT', alert: publicAlert(r.alert), duplicate: true, ts: Date.now() });
        return;
      }
      case 'SOS_RESPOND': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'SOS_RESPOND', () => this.convoys.respondSos(gid, u, { alertId: msg.alertId, kind: msg.kind }));
      }
      case 'CHECK_IN': {
        const gid = this._requireRoom(ws);
        if (!this.timeline) throw new ConvoyError('Check-in is not available.', 503);
        return this._once(ws, cid, 'CHECK_IN', () => this.timeline.checkIn(gid, u, msg));
      }
      case 'SOS_RESOLVE': return void await this.convoys.resolveSos(this._requireRoom(ws), u, String(msg.alertId || ''), msg.reason);
      // ---- 3.15 safety network and discovery ----
      case 'REPORT_DOWN': {
        if (!this.network) return this.sendError(ws, 400, `Unknown message type ${msg.type}`);
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'REPORT_DOWN', async () => {
          const r = await this.convoys.reportDown(gid, u, msg);
          // The reporter's own echo of an existing alert, so the phone sees it is known.
          if (r.duplicate) this.send(ws, { type: 'ALERT', alert: publicAlert(r.alert), duplicate: true, ts: Date.now() });
        });
      }
      case 'ASSIST_ANSWER': {
        if (!this.network) return this.sendError(ws, 400, `Unknown message type ${msg.type}`);
        this._requireRoom(ws);
        const incidentId = typeof msg.incidentId === 'string' && INCIDENT_ID.test(msg.incidentId) ? msg.incidentId : '';
        if (!incidentId) throw new ConvoyError('This emergency is closed.', 404, 'INCIDENT_CLOSED');
        return this._once(ws, cid, 'ASSIST_ANSWER', async () => { this.network.answer(u, { incidentId, answer: msg.answer }); });
      }
      case 'NET_REPORT_FALSE': {
        if (!this.network) return this.sendError(ws, 400, `Unknown message type ${msg.type}`);
        this._requireRoom(ws);
        const incidentId = typeof msg.incidentId === 'string' && INCIDENT_ID.test(msg.incidentId) ? msg.incidentId : '';
        if (!incidentId) throw new ConvoyError('This emergency is closed.', 404, 'INCIDENT_CLOSED');
        return this._once(ws, cid, 'NET_REPORT_FALSE', async () => { this.network.reportFalse(u, { incidentId }); });
      }
      case 'WAVE': {
        if (!this.discovery || !config.discoveryEnabled) return this.sendError(ws, 400, `Unknown message type ${msg.type}`);
        const gid = this._requireRoom(ws);
        const encounterId = typeof msg.encounterId === 'string' && ENCOUNTER_ID.test(msg.encounterId) ? msg.encounterId : '';
        if (!encounterId) throw new ConvoyError('That group is no longer nearby.', 404, 'ENCOUNTER_CLOSED');
        return this._once(ws, cid, 'WAVE', async () => { this.discovery.wave(u, gid, encounterId); });
      }
      // ---- Public ride, safe contact and road warnings (src/public_ride.js: its own rate budget,
      // never the safety lanes, so nothing here can delay or use up an SOS) ----
      case 'PR_PREFS': case 'PR_CONTACT': case 'PR_REPLY': case 'PR_SAY': case 'PR_SHARE_LOC': case 'PR_SHARE_CONTACT':
      case 'PR_CLOSE': case 'PR_REPORT': case 'PR_BLOCK': case 'ROAD_WARN': case 'ROAD_WARN_VOTE': {
        if (!this.publicRides || !config.publicRideEnabled) return this.sendError(ws, 400, `Unknown message type ${msg.type}`);
        return void await this.publicRides.handle(ws, msg);
      }
      // ---- 3.16 ----
      case 'ROLE_SET': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'ROLE_SET', () => this.convoys.setRole(gid, u, msg.userId, msg.role));
      }
      case 'MIC_STATE': {
        const gid = this._requireRoom(ws);
        const room = this.convoys.rooms.get(gid);
        if (room && typeof this.convoys.isSoloRide === 'function' && this.convoys.isSoloRide(room)) {
          return this.sendError(ws, 403, 'Talk is for group rides. This is a solo ride.', 'SOLO_RIDE');
        }
        if (room && room.riders && room.riders.has(u.userId)) {
          room.riders.get(u.userId).micMuted = !!msg.muted;
        }
        return this.roomSend(gid, {
          type: 'MIC_STATUS',
          userId: u.userId,
          micMuted: !!msg.muted,
          ts: Date.now(),
        }, { except: ws });
      }
      case 'REGROUP_SET': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'REGROUP_SET', () => this.convoys.setRegroup(gid, u, msg));
      }
      case 'REGROUP_CLEAR': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'REGROUP_CLEAR', () => this.convoys.clearRegroup(gid, u, msg.reason));
      }
      case 'STOP_ADD': return void await this.convoys.addStop(this._requireRoom(ws), u, msg);
      case 'STOP_SUGGEST': return void await this.convoys.suggestStop(this._requireRoom(ws), u, msg);
      case 'STOP_ACCEPT': return void await this.convoys.decideStop(this._requireRoom(ws), u, String(msg.stopId || ''), true);
      case 'STOP_DECLINE': return void await this.convoys.decideStop(this._requireRoom(ws), u, String(msg.stopId || ''), false);
      case 'STOP_REMOVE': return void await this.convoys.removeStop(this._requireRoom(ws), u, String(msg.stopId || ''));
      case 'STOP_SKIP': return void await this.convoys.skipStop(this._requireRoom(ws), u, String(msg.stopId || ''));
      case 'STOP_REORDER': return void await this.convoys.reorderStops(this._requireRoom(ws), u, msg.order);
      case 'ROUTE_SET': return void await this.convoys.setRoute(this._requireRoom(ws), u, msg);
      case 'STOP_VISITED': return this._once(ws, cid, 'STOP_VISITED', () => this.convoys.setStopVisited(this._requireRoom(ws), u, String(msg.stopId || ''), !!msg.isVisited));
      case 'CONFIG': {
        const gid = this._requireRoom(ws);
        await this.convoys.updateConfig(gid, u, msg);
        if (this.discovery) this.discovery.onConfig(gid);
        if (this.publicRides) this.publicRides.onConfig(gid);
        return;
      }
      case 'TRIP_STATUS': {
        const gid = this._requireRoom(ws);
        const room = await this.convoys.getRoom(gid);
        const rider = room.riders.get(u.userId);
        const isLead = rider && rider.role === 'LEAD';
        const isCreator = room.meta.createdByUserId === u.userId;
        const isOwner = room.meta.tripOwnerUserId === u.userId;
        const isHead = room.meta.tripHeadUserId === u.userId;
        const isAdmin = u.role === ROLE_ADMIN || u.role === 'MASTER_ADMIN';
        if (!isLead && !isCreator && !isOwner && !isHead && !isAdmin) {
          throw new ConvoyError('Only the convoy lead or admin can change the trip state.', 403);
        }
        const status = String(msg.status || '').toUpperCase();
        if (status === 'ENDED' && !isOwner && !isCreator && !isAdmin) {
          throw new ConvoyError('Only the Trip Owner or Platform Admin can end the trip.', 403, 'ONLY_OWNER_CAN_END_TRIP');
        }
        await this.convoys.setTripStatus(gid, status);
        return;
      }
      case 'LAST_GASP_BEACON': {
        const gid = this._requireRoom(ws);
        const room = await this._liveRoom(ws, gid);
        if (!room) return;
        const lat = Math.max(-90, Math.min(90, Number(msg.lat) || 0));
        const lng = Math.max(-180, Math.min(180, Number(msg.lng) || 0));
        const fuelKm = Number(msg.fuelKm ?? msg.usableFuelKm) || 0;
        const speedKmh = Number(msg.speedKmh) || 0;
        const batteryLevel = Math.min(100, Math.max(0, Number(msg.batteryLevel ?? 5)));
        const patch = {
          lat,
          lng,
          speedKmh,
          batteryLevel,
          isCharging: false,
          statusReason: 'BATTERY_SHUTDOWN',
        };
        const rider = this.convoys.patchRider(room, u.userId, patch);
        this.roomSend(gid, {
          type: 'RIDER_BATTERY_SHUTDOWN',
          userId: u.userId,
          userName: u.name,
          lat,
          lng,
          fuelKm,
          speedKmh,
          batteryLevel,
          ts: Date.now(),
        });
        if (this.timeline) {
          await this.timeline.onActivity(gid, {
            type: 'BATTERY_SHUTDOWN',
            user: u,
            lat,
            lng,
            fuelKm,
            speedKmh,
            batteryLevel,
          });
        }
        return;
      }

            case 'ROAD_HAZARD': {
        const gid = this._requireRoom(ws);
        const room = await this.convoys.getRoom(gid);
        const rider = room.riders.get(u.userId);

        // Enforce Road Captain Broadcast Entitlement (Server-Enforced)
        const isRoadCaptain = (rider && (rider.role === 'LEAD' || rider.role === 'CAPTAIN')) ||
          u.role === 'ROAD_CAPTAIN' || u.role === 'MASTER_ADMIN' || u.role === 'ADMIN' ||
          (room.meta && room.meta.createdByUserId === u.userId);

        if (!isRoadCaptain) {
          throw new ConvoyError('Only the Road Captain or convoy lead can broadcast road hazard telemetry.', 403, 'ENTITLEMENT_REQUIRED');
        }

        // Validate payload
        const lat = Number(msg.lat);
        const lng = Number(msg.lng);
        if (!Number.isFinite(lat) || lat < -90 || lat > 90 || !Number.isFinite(lng) || lng < -180 || lng > 180) {
          throw new ConvoyError('Invalid road hazard coordinates.', 400);
        }

        // Ingest into RoadHazardRegistry for 100m spatial deduplication
        const { pin, isNew, duplicate } = this.roadHazards.ingestObservation({
          hazardId: msg.hazardId,
          userId: u.userId,
          lat,
          lng,
          heading: Number(msg.heading) || (rider ? Number(rider.heading) : 0),
          severity: msg.severity,
          classification: msg.classification,
          confidence: msg.confidence,
          timestamp: Number(msg.timestamp) || Date.now(),
        });

        // Send ACK back to the reporting Road Captain
        this.send(ws, {
          type: 'ROAD_HAZARD_ACK',
          hazardId: pin.hazardId,
          isNew,
          duplicate: Boolean(duplicate),
          corroborationCount: pin.corroborationCount,
          ts: Date.now(),
        });

        // If duplicate replayed frame, do not re-broadcast
        if (duplicate) return;

        // Downstream recipient filtering: route, carriageway heading, upstream distance
        const connectedClients = this.rooms.get(gid);
        if (connectedClients) {
          const roomRidersList = [];
          for (const clientWs of connectedClients) {
            if (clientWs.readyState === 1 && clientWs.user) {
              const r = room.riders.get(clientWs.user.userId);
              if (r) {
                roomRidersList.push({
                  userId: clientWs.user.userId,
                  lat: Number(r.lat),
                  lng: Number(r.lng),
                  heading: Number(r.heading),
                  ws: clientWs,
                });
              }
            }
          }

          const eligibleRecipients = this.roadHazards.filterEligibleRecipients(pin, roomRidersList);
          const eligibleUserIds = new Set(eligibleRecipients.map(e => e.userId));
          const distanceMap = new Map(eligibleRecipients.map(e => [e.userId, e.distanceM]));

          for (const clientWs of connectedClients) {
            if (clientWs.readyState === 1 && clientWs.user) {
              const isEligible = eligibleUserIds.has(clientWs.user.userId);
              if (isEligible) {
                const aheadM = distanceMap.get(clientWs.user.userId) || 300;
                this.send(clientWs, {
                  type: 'ROAD_HAZARD',
                  hazardId: pin.hazardId,
                  lat: pin.lat,
                  lng: pin.lng,
                  heading: pin.heading,
                  severity: pin.severity,
                  classification: pin.classification,
                  confidence: pin.confidence,
                  aheadM,
                  corroborationCount: pin.corroborationCount,
                  reportedAt: pin.firstDetectedAt,
                  expiresAt: pin.expiresAt,
                  spokenWarning: pin.spokenWarning,
                });
              }
            }
          }
        }

        return;
      }

      case 'TRACK': {
        // GPS points recorded on the phone (also the backlog after a dead zone).
        const gid = this._requireRoom(ws);
        if (!this.tracks) throw new ConvoyError('Track upload is not available.', 503);
        if (!this._allow(ws, 'track', 3)) throw new ConvoyError('Slow down.', 429);
        const room = this.convoys.rooms.get(gid);
        const meta = room ? room.meta : await this.repo.getConvoyMeta(gid);
        const perm = uploadPermission(meta, u.userId);
        if (!perm.ok) throw new ConvoyError('Not a member of this convoy.', 403);
        const chunk = validateChunk(msg, { tripStartMs: perm.tripStartMs });
        const r = await this.tracks.save(gid, u.userId, chunk);
        if (perm.ended && !r.duplicate && this.timeline) this.timeline.scheduleRebuild(gid, u.userId);
        return this.send(ws, { type: 'TRACK_ACK', seq: r.seq, duplicate: r.duplicate, ts: Date.now() });
      }
      case 'TIMELINE_SINCE': {
        const gid = this._requireRoom(ws);
        const meta = await this.repo.getConvoyMeta(gid);
        const win = visibleWindow(meta, u);
        if (!win) throw new ConvoyError('Not a member of this convoy.', 403);
        const since = Math.max(0, Number(msg.since) || 0);
        const events = (await this.repo.listEvents(gid, { since })).filter((e) => eventVisible(e, win, u.userId)).map(publicEvent);
        return this.send(ws, { type: 'TIMELINE_BATCH', events, since, ts: Date.now() });
      }

      case 'ADMIN_SUBSCRIBE': {
        if (u.role !== ROLE_ADMIN) throw new ConvoyError('Admin only.', 403);
        this.admins.add(ws);
        return this._pushFleet();
      }
      default:
        return this.sendError(ws, 400, `Unknown message type ${msg.type}`);
    }
  }

  // ---------------------------------------------------------------- voice
  _voiceState(groupId) {
    if (!this.voice.has(groupId)) this.voice.set(groupId, { group: null, private: new Map() });
    return this.voice.get(groupId);
  }

  _onVoice(ws, data) {
    const gid = ws.groupId;
    if (!gid) return; // not in a room: drop silently
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
    if (buf.length > config.voiceMaxFrameBytes + 2100) return;
    const pkt = decodeVoice(buf);
    if (!pkt) return;
    const state = this._voiceState(gid);
    const to = pkt.header.to ? String(pkt.header.to) : null;
    const t = Date.now();

    if (pkt.kind === VOICE_START) {
      // Talk is a group feature: a solo ride (Community host) has no one to talk to.
      const soloRoom = this.convoys.rooms.get(gid);
      if (soloRoom && typeof this.convoys.isSoloRide === 'function' && this.convoys.isSoloRide(soloRoom)) {
        return this.sendError(ws, 403, 'Talk is for group rides. This is a solo ride.', 'SOLO_RIDE');
      }
      // Validate target (must be a current room member, and not yourself).
      if (to) {
        const set = this.rooms.get(gid);
        const target = set && [...set].find((c) => c.user.userId === to);
        if (!target || to === ws.user.userId) return this.sendError(ws, 404, 'Rider is not online in this convoy.');
      } else {
        const cur = state.group;
        if (cur && cur.ws !== ws && t - cur.lastAt < config.voiceStreamIdleMs) {
          return this.send(ws, { type: 'VOICE_BUSY', speaker: cur.fromName, ts: t });
        }
        // The floor held by a rider on the peer gateway (hand-back window) is busy too.
        const rem = state.remote;
        if (rem && t - rem.lastAt < config.voiceStreamIdleMs) return this.send(ws, { type: 'VOICE_BUSY', speaker: rem.fromName, ts: t });
        state.remote = null;
        if (cur && cur.ws !== ws) this._endStream(gid, cur, 'preempted');
      }
      const channel = pkt.header.channel === 'LEAD_ONLY' ? 'LEAD_ONLY' : 'ALL';
      if (channel === 'LEAD_ONLY') {
        const room = this.convoys.rooms.get(gid);
        const speakerRider = room && room.riders ? room.riders.get(ws.user.userId) : null;
        const speakerRole = speakerRider ? speakerRider.role : ws.user.role;
        const isLeader = speakerRole === 'LEAD' || speakerRole === 'SWEEPER' || (room && room.meta && room.meta.createdByUserId === ws.user.userId) || ws.user.role === 'ADMIN' || ws.user.role === 'MASTER_ADMIN';
        if (!isLeader) {
          return this.sendError(ws, 403, 'Lead channel is restricted to convoy leads and sweepers.');
        }
      }
      const stream = {
        streamId: crypto.randomBytes(6).toString('hex'), ws, from: ws.user.userId, fromName: ws.user.name, to,
        channel,
        startedAt: t, lastAt: t, frames: 0, sampleRate: VOICE_RATES.has(Number(pkt.header.sampleRate)) ? Number(pkt.header.sampleRate) : 16000, codec: String(pkt.header.codec || 'pcm16').slice(0, 16),
      };
      if (to) state.private.set(ws.user.userId, stream); else state.group = stream;
      ws.voiceStream = stream;
      this.convoys.featureAnalytics?.record('voice', true);
      const hdr = { ...this._hdr(stream), channel: stream.channel, sampleRate: stream.sampleRate, codec: stream.codec };
      this._relay(gid, stream, VOICE_START, hdr, null);
      if (this.mirror) this.mirror.voice(gid, VOICE_START, hdr, null);
      this.roomSend(gid, {
        type: 'MIC_STATUS',
        userId: ws.user.userId,
        isSpeaking: true,
        channel: stream.channel,
        ts: t,
      });
      return;
    }

    const stream = ws.voiceStream;
    if (!stream || (stream.to || null) !== to) return; // frame without a stream → drop

    if (pkt.kind === VOICE_FRAME) {
      if (t - stream.startedAt > config.voiceMaxStreamMs) return this._endStream(gid, stream, 'max-duration');
      if (pkt.payload.length === 0 || pkt.payload.length > config.voiceMaxFrameBytes) return;
      // Frame budget per stream: a flooding client cannot multiply audio across the whole room.
      if (!stream.rateAt || t - stream.rateAt >= 1000) { stream.rateAt = t; stream.rateN = 0; }
      if (++stream.rateN > VOICE_MAX_FPS) return;
      stream.lastAt = t; stream.frames++;
      const hdr = { ...this._hdr(stream), seq: pkt.header.seq | 0 };
      this._relay(gid, stream, VOICE_FRAME, hdr, pkt.payload);
      if (this.mirror) this.mirror.voice(gid, VOICE_FRAME, hdr, pkt.payload);
      return;
    }
    if (pkt.kind === VOICE_END) this._endStream(gid, stream, 'end');
  }

  _hdr(s) { return { streamId: s.streamId, from: s.from, fromName: s.fromName, to: s.to, channel: s.channel || 'ALL', ts: Date.now() }; }

  _relay(gid, stream, kind, header, payload) {
    const set = this.rooms.get(gid);
    if (!set) return;
    const frame = encodeVoice(kind, header, payload);
    const room = this.convoys.rooms.get(gid);
    for (const client of set) {
      if (client === stream.ws || client.readyState !== WebSocket.OPEN) continue;
      if (stream.to && client.user.userId !== stream.to) continue; // 1:1 — only the chosen rider hears it
      if (stream.channel === 'LEAD_ONLY') {
        const rider = room && room.riders ? room.riders.get(client.user.userId) : null;
        const role = rider ? rider.role : client.user.role;
        const isLeadOrSweeper = role === 'LEAD' || role === 'SWEEPER' || (room && room.meta && room.meta.createdByUserId === client.user.userId) || client.user.role === 'ADMIN' || client.user.role === 'MASTER_ADMIN';
        if (!isLeadOrSweeper) continue;
      }
      if (client.bufferedAmount > 512 * 1024 || client.outq) continue; // slow link: drop audio rather than build latency
      client.send(frame);
    }
  }

  _endStream(gid, stream, reason) {
    const state = this.voice.get(gid);
    if (state) {
      if (state.group === stream) state.group = null;
      if (state.private.get(stream.from) === stream) state.private.delete(stream.from);
    }
    if (stream.ws.voiceStream === stream) stream.ws.voiceStream = null;
    const hdr = { ...this._hdr(stream), reason };
    this._relay(gid, stream, VOICE_END, hdr, null);
    if (this.mirror) this.mirror.voice(gid, VOICE_END, hdr, null);
    this.roomSend(gid, {
      type: 'MIC_STATUS',
      userId: stream.from,
      isSpeaking: false,
      ts: Date.now(),
    });
    const durationMs = Date.now() - stream.startedAt;
    if (stream.frames > 0) {
      this.repo.logVoiceSession({ groupId: gid, from: stream.from, to: stream.to, startedAt: stream.startedAt, durationMs, frames: stream.frames, reason });
    }
  }

  _endVoiceStreamsOf(ws) {
    if (ws.voiceStream && ws.groupId) this._endStream(ws.groupId, ws.voiceStream, 'disconnect');
  }

  /**
   * Voice from a rider on the peer gateway (hand-back window), relayed to this node's sockets of the room.
   * The group floor: a remote START while a local group stream is live goes to the room authority
   * (`peerHasFloorAuthority`: the peer is the GATEWAY_ROLE=live node): the local stream is preempted, or
   * the remote one is ignored here (the peer preempts it when our START reaches it).
   */
  applyRemoteVoice(gid, kind, header, payload, { peerHasFloorAuthority = false } = {}) {
    if (!header || typeof header.streamId !== 'string') return;
    const state = this._voiceState(gid);
    const rp = state.remotePrivate || (state.remotePrivate = new Map());
    const t = Date.now();
    const pseudo = { ws: null, to: header.to || null, channel: header.channel === 'LEAD_ONLY' ? 'LEAD_ONLY' : 'ALL' };
    if (kind === VOICE_START) {
      if (!header.to) {
        const cur = state.group;
        if (cur && t - cur.lastAt < config.voiceStreamIdleMs) {
          if (!peerHasFloorAuthority) return;
          this._endStream(gid, cur, 'preempted');
        }
        state.remote = { streamId: header.streamId, from: header.from, fromName: header.fromName, lastAt: t };
      } else {
        rp.set(header.streamId, { lastAt: t });
      }
      this._relay(gid, pseudo, kind, header, null);
      return;
    }
    const known = (state.remote && state.remote.streamId === header.streamId) ? state.remote : rp.get(header.streamId);
    if (!known) return;
    known.lastAt = t;
    if (kind === VOICE_END) {
      if (state.remote === known) state.remote = null; else rp.delete(header.streamId);
    }
    this._relay(gid, pseudo, kind, header, kind === VOICE_FRAME ? payload : null);
  }

  /** The group floor of a room for the mirror snapshot, or null. */
  floorOf(gid) {
    const st = this.voice.get(gid);
    const g = st && st.group;
    return g ? { streamId: g.streamId, from: g.from, fromName: g.fromName } : null;
  }
}

module.exports = { Hub, encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END, FEATURES, FEATURES_314 };
