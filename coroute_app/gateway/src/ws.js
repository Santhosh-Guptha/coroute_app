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
const { verifyTokenDetailed, ROLE_ADMIN, AuthError, identityOf } = require('./auth');
const { ConvoyError, publicRider, publicAlert } = require('./convoys');
/** Trip statuses of a ride that is still on (a revoked session keeps its ride socket during these). */
const ACTIVE_RIDE = new Set(['PLANNING', 'STARTED', 'PAUSED']);
const { clientIdOf } = require('./validate');
const { validateChunk, TrackError, uploadPermission } = require('./tracks');
const { visibleWindow, eventVisible, publicEvent } = require('./timeline');
const { RoadHazardRegistry } = require('./road_hazards');
// 3.55 admin feature switches (cached lookups, no DB read per message).
const { wsFeaturesFor, firstOff, FEATURE_OFF, FEATURE_OFF_MESSAGE } = require('./feature_flags');
// Round 8 realtime: abuse limits, compact position frames ('pos2'), interest management for big rides.
const RL = require('./ws_limits');
const { POS2_CAP, decodeP2, riderEntry, ru2Frame } = require('./pos2');
const { Interest } = require('./interest');

// Round 8 voice: the intercom relay lives in src/voice_relay.js (lowest priority, codec negotiation, caps, metrics,
// optional separate process). ws.js keeps thin delegates, marked "Round 8 voice".
const { VoiceRelay, encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END, VOICE_FEATURE } = require('./voice_relay');

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
/** v3.56: positions of one rider go out at most once per WS_POS_MIN_MS in rooms of any size (the first at once,
 * later ones coalesced, latest wins, flushed when the window ends; 800 ms lets a 1 Hz sender through untouched).
 * 0 = small rooms relay every fix at once. The app
 * sends a fix every 2.5 s (5 s with low data), so this only bites clients that send faster. Never SOS / alerts. */
const POS_MIN_MS = envInt('WS_POS_MIN_MS', 800);
/** v3.56: a coalesced flush goes to a socket that announced 'posbatch1' in its JOIN as ONE frame
 * { type: 'RIDER_UPDATES', riders: [...], ts } instead of one RIDER_UPDATE per rider (fewer frames, syscalls and TLS
 * records). Only to sockets with no backlog; others get the per-rider messages. WS_POS_BATCH=off disables it. */
const POS_BATCH = String(process.env.WS_POS_BATCH || 'on').toLowerCase() !== 'off';
const BATCH_CAP = 'posbatch1';
/** v3.56: in rooms above WS_COALESCE_ABOVE every position waits for the room's flush (every WS_COALESCE_MS) instead
 * of the first one going out at once, so a batch-capable socket gets one frame per window for the whole room
 * (a 50-rider room: ~2 frames/s per phone instead of ~20). Positions only. WS_BATCH_LARGE=off restores the
 * leading edge. */
const POS_BATCH_LARGE = POS_BATCH && String(process.env.WS_BATCH_LARGE || 'on').toLowerCase() !== 'off';
/** v3.56: telemetry and keep-alives re-check the account through the cached gate with this older bound (default
 * 120 s, stale-while-revalidate up to twice that) instead of USER_GATE_TTL_MS: a position never waits for the
 * database. Holds, blocks, deletions and sign-outs still act at once (invalidate + socket kick, both nodes). */
const GATE_HOT_TTL_MS = envInt('WS_GATE_TTL_MS', 120000);
const HOT_TYPES = new Set(['TELEMETRY', 'PING', 'P2']);
/** v3.56: ping interval (a socket missing one pong is closed at the next tick). */
const HEARTBEAT_MS = Math.max(5000, envInt('WS_HEARTBEAT_MS', 30000));
/** v3.56: permessage-deflate. Off by default: on the 1/8-OCPU micro the CPU costs more than the bytes saved
 * (positions are ~300 B; measured in tool/load). WS_DEFLATE=on enables it with a 1 KB threshold. */
const DEFLATE = String(process.env.WS_DEFLATE || 'off').toLowerCase() === 'on';

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
  // 3.55
  'ROLE_SWAP', 'ROLE_AUTO',
  // 3.55 bike / pillion swap
  'SWAP_REQUEST', 'SWAP_ANSWER',
  // 3.55 no-signal ahead (src/signal_ahead.js)
  'SIGNAL_AHEAD',
  // 3.55 buddy pairs
  'BUDDY_ASSIGN', 'BUDDY_PING',
  // 3.55 live bike change
  'RIDER_VEHICLE',
  // 3.55 pillion seat
  'PILLION_SEAT', 'PILLION_UNSEAT',
]);
/** Socket messages that alert the whole convoy: a few per 10 seconds, each type with its own budget
 * (a rider who just asked the group to wait must still be able to raise an SOS). */
const ALARM_TYPES = new Set(['WAIT', 'SOS', 'CHECK_IN', 'REPORT_DOWN']);
/** Messages that may carry a clientId (phone outbox): applied once, answered with ACK. */
const CLIENT_ID_TYPES = new Set(['CHAT', 'WAIT', 'STATUS', 'STOP_VISITED', 'SOS_RESPOND', 'CHECK_IN', 'REPORT_DOWN', 'ASSIST_ANSWER', 'NET_REPORT_FALSE', 'WAVE', 'ROLE_SET', 'REGROUP_SET', 'REGROUP_CLEAR', 'ROLE_SWAP', 'ROLE_AUTO', 'SWAP_REQUEST', 'SWAP_ANSWER', 'BUDDY_ASSIGN', 'BUDDY_PING', 'PILLION_SEAT', 'PILLION_UNSEAT']);
const BYE_REASONS = new Set(['APP_CLOSED', 'SIGN_OUT', 'LEFT']);
/**
 * Round 4 safety-only mode: a socket whose session was revoked during a live ride stays open until the ride ends but
 * may only send its own SOS / crash alert, position and keep-alives, and only receives control messages and its own
 * alerts: no other rider's position, chat, voice or member data.
 */
const SAFETY_ONLY_IN = new Set(['PING', 'SOS', 'TELEMETRY', 'P2', 'BYE', 'LAST_GASP_BEACON', 'JOIN', 'LEAVE', 'AUTH']);
const SAFETY_ONLY_OUT = new Set(['ACK', 'ERROR', 'PONG', 'HELLO', 'RECONNECT', 'SAFETY_ONLY', 'TRIP_STATUS', 'DISSOLVED', 'LEFT']);
const SAFETY_ONLY_MESSAGE = 'This phone was signed out of CoRoute. Until the ride ends it only sends your SOS, crash alerts and position.';
/** Round 4: the subprotocol new clients may offer (the token then travels as "coroute.bearer.<token>", never in the URL). */
const WS_PROTOCOL = 'coroute.v1';
const WS_BEARER_PREFIX = 'coroute.bearer.';
/** Protocol features this gateway offers (HELLO.features); 3.14 apps use a feature only when listed. */
const FEATURES_314 = ['ack', 'sos2', 'respond', 'presence', 'checkin', 'roster'];
/** 3.15: safety network and discovery, appended when switched on. */
/** 3.16: sweeper role, follow-up check-in, town limit, live links (always on). */
/** 3.55 'vehicle1': RIDER_VEHICLE (the rider's bike colour / model changed mid-ride).
 *  3.55 'pillion2': PILLION_SEAT / PILLION_UNSEAT (the pillion confirms the bike; the rider may decline). */
/** Round 8 'pos2': compact P2 position frames from the phone and RU2 batches to sockets with the 'pos2' cap
 *  (src/pos2.js). WS_POS2=off stops advertising it (apps then keep TELEMETRY JSON; P2 frames are still accepted). */
const POS2_ON = String(process.env.WS_POS2 || 'on').toLowerCase() !== 'off';
const FEATURES = [...FEATURES_314, ...(config.safetyNetEnabled ? ['net1'] : []), ...(config.discoveryEnabled ? ['discovery1'] : []), ...(config.publicRideEnabled ? ['pubride1'] : []), 'ride316', 'featurePolicy1', 'bin1', 'ride355', 'vehicle1', 'pillion2', ...(POS2_ON ? [POS2_CAP] : []), VOICE_FEATURE /* Round 8 voice: VOICE_CAPS / VOICE_CODEC */];
/** Client capabilities a 3.15 app sends with JOIN. Server-to-client types added in 3.15 go only to sockets with 'net1'. */
const CAP = /^[a-z0-9]{1,16}$/;
const INCIDENT_ID = /^NET-[0-9A-F]{12}$/;
const ENCOUNTER_ID = /^ENC-[0-9A-F]{12}$/;

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
    this.voiceRelay = new VoiceRelay(this); // Round 8 voice (src/voice_relay.js); floor state stays in this.voice
    this.roadHazards = new RoadHazardRegistry(); // groupId -> { group: stream|null, private: Map<from, stream> }
    this.posPending = new Map(); // groupId -> Map<userId, RIDER_UPDATE json> (large rooms, coalesced)
    this.posTimers = new Map(); // groupId -> flush timer
    this.posSentAt = new Map(); // groupId -> Map<userId, last fan-out time> (large rooms)
    this.stats = { posIn: 0, posOut: 0, posDropped: 0, posCoalesced: 0, slowKicked: 0, queued: 0, batchFrames: 0, connections: 0,
      // Round 8 (src/ws_limits.js, src/pos2.js, src/interest.js): one counter per limit and per new path.
      rlIpConcurrent: 0, rlIpRate: 0, rlUserConnect: 0, rlUserEvicted: 0, rlWarned: 0, rlKicked: 0, rlInvalid: 0, rlInvalidKicked: 0,
      rlJoinFlood: 0, rlIdleClosed: 0, rlSlowReader: 0, rlDropPos: 0, rlDropChat: 0, rlDropJoin: 0, rlDropPing: 0, rlDropOther: 0,
      sosOverBudget: 0, sosOverFloorEcho: 0, pos2In: 0, pos2Miss: 0, pos2Frames: 0, interestHeld: 0, interestFarSent: 0 };
    this.limits = RL.limitsConfig();
    this.trusted = RL.trustFn(config.trustProxy);
    this.ipLimiter = new RL.IpConnLimiter({ maxPerIp: this.limits.maxConnPerIp, perMin: this.limits.connPerMinPerIp });
    this.userConnLimiter = new RL.UserConnLimiter({ perMin: this.limits.connPerMinPerUser });
    this.interest = new Interest();
    this.posLatest = new Map(); // groupId -> Map<userId, { msg, rj, p2, at }> (interest rooms: far riders' latest)
    this.farTimers = new Map(); // groupId -> timer for withheld far positions
    this.outPending = new Set(); // sockets with queued outbound messages (see OUT_SOFT_BYTES)
    this.outTimer = null;
    /** Two-node live mirror (src/mirror.js), set by app.js; null on a single node. */
    this.mirror = null;
    // 3.57: a browser (it always sends Origin) may only open a socket from this site; the app sends no Origin.
    this.allowedOrigins = null; // Set of origins, filled by app.js (site origins + CORS_ORIGINS)
    /** Round 4 ride lock (src/ride_lock.js), set by app.js; null in unit tests. */
    this.rideLock = null;
    this.wss = new WebSocketServer({ server, path, maxPayload: 256 * 1024, verifyClient: (info, cb) => this._verifyClient(info, cb),
      perMessageDeflate: DEFLATE ? { threshold: 1024, concurrencyLimit: 4, serverNoContextTakeover: true, clientNoContextTakeover: true, zlibDeflateOptions: { level: 1, memLevel: 7 } } : false,
      // Round 4: echo only the plain protocol name (never the bearer entry, which carries the token).
      handleProtocols: (protocols) => (protocols && protocols.has(WS_PROTOCOL) ? WS_PROTOCOL : false) });
    this.wss.on('connection', (ws, req) => this._onConnection(ws, req));

    convoys.on('event', (groupId, payload, opts) => this.broadcast(groupId, payload, opts));
    // The sender's own copy of a durable event, after it was stored and the peer gateway has it.
    convoys.on('echo', (groupId, payload, userId) => this.broadcast(groupId, payload, { onlyUser: userId }));
    convoys.on('broadcast', (entry) => this.broadcastAll({ type: 'BROADCAST', message: entry.message, ts: entry.timestamp }));
    convoys.on('fleet', () => this._scheduleFleet());
    convoys.featureAnalytics?.on('change', () => this._scheduleFleet());
    // 3.15: room messages only 3.15 apps understand (EMERGENCY_UPDATE).
    convoys.on('capEvent', (groupId, cap, payload) => this.broadcastCap(groupId, cap, payload));
    // 3.55 bike / pillion swap: personal messages (SWAP_ASK, SWAP_RESULT) to one rider's sockets.
    convoys.on('userMessage', (groupId, userId, payload) => this.sendToUser(userId, { groupId, ...payload }));
    // An ended ride: no queued positions or voice floor survive it.
    convoys.on('roomEnded', (groupId) => this._dropRoomState(groupId));

    this.heartbeat = setInterval(() => {
      const t = Date.now();
      for (const ws of this.wss.clients) {
        if (ws.isAlive === false) { ws.terminate(); continue; }
        // 3.57: a signed-out session's socket that is no longer in a live ride (left it) closes now.
        if (ws.revokedPending && !this._rideKeepsSocket(ws)) { this._kick(ws, 4401, 'SIGNED_OUT'); continue; }
        // Round 8 timeouts (src/ws_limits.js): never a socket in a ride or an admin's fleet view.
        if (this._idleOrSlow(ws, t)) continue;
        ws.isAlive = false; ws.ping();
      }
      this.ipLimiter.sweep(); this.userConnLimiter.sweep();
    }, HEARTBEAT_MS);
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
    for (const t of this.farTimers.values()) clearTimeout(t);
    this.posTimers.clear(); this.posPending.clear(); this.farTimers.clear(); this.posLatest.clear();
    this.wss.close();
  }

  _dropRoomState(groupId) {
    const t = this.posTimers.get(groupId);
    if (t) clearTimeout(t);
    const ft = this.farTimers.get(groupId);
    if (ft) clearTimeout(ft);
    this.farTimers.delete(groupId); this.posLatest.delete(groupId);
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
    const ts = Date.now();
    const pr = publicRider(rider);
    const rj = JSON.stringify(pr);
    // One position, three wire forms built once: RIDER_UPDATE (legacy), the batch entry, the RU2 entry (pos2).
    const p = { msg: `{"type":"RIDER_UPDATE","rider":${rj},"ts":${ts}}`, rj, p2: riderEntry(pr, ts), ru2: null, ts };
    const big = set.size > POS_COALESCE_ABOVE;
    // Round 8 interest management: the latest position of every rider of a big room, for the far-rider refresh.
    if (this.interest.active(set.size)) {
      let lm = this.posLatest.get(gid);
      if (!lm) { lm = new Map(); this.posLatest.set(gid, lm); }
      p.at = ts;
      lm.set(rider.userId, p);
    }
    const windowMs = big ? POS_COALESCE_MS : POS_MIN_MS;
    // A position relayed from the peer gateway (no local sender socket) never goes back to its own rider.
    if (!(windowMs > 0)) return this._sendPosition(set, p, fromWs ? null : rider.userId, fromWs, rider.userId);
    const t = ts;
    let sentAt = this.posSentAt.get(gid);
    if (!sentAt) { sentAt = new Map(); this.posSentAt.set(gid, sentAt); }
    let pending = this.posPending.get(gid);
    const last = sentAt.get(rider.userId) || 0;
    if (!(big && POS_BATCH_LARGE) && !(pending && pending.has(rider.userId)) && t - last >= windowMs) {
      sentAt.set(rider.userId, t);
      return this._sendPosition(set, p, fromWs ? null : rider.userId, fromWs, rider.userId);
    }
    if (!pending) { pending = new Map(); this.posPending.set(gid, pending); }
    if (pending.has(rider.userId)) this.stats.posCoalesced++;
    pending.set(rider.userId, p);
    if (!this.posTimers.has(gid)) {
      // Large rooms: one flush per window for everyone. Small rooms: when this rider's window ends.
      const delay = big ? POS_COALESCE_MS : Math.max(25, last + windowMs - t);
      const timer = setTimeout(() => this._flushPositions(gid), delay);
      if (timer.unref) timer.unref();
      this.posTimers.set(gid, timer);
    }
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
    const entries = [];
    // A rider who left while queued is never brought back by a late position.
    for (const [uid, p] of pending) {
      if (!room.riders.has(uid)) { if (sentAt) sentAt.delete(uid); continue; }
      if (sentAt) sentAt.set(uid, t);
      entries.push([uid, p]);
    }
    if (!entries.length) return;
    if (this.interest.active(set.size)) return this._flushInterest(gid, set, room, entries, t);
    if (!POS_BATCH || entries.length < 2) {
      for (const [uid, p] of entries) this._sendPosition(set, p, uid, null, uid);
      return;
    }
    let all = null; let all2 = null; // the full batch (legacy / pos2), shared by every peer whose own rider is not in it
    const inBatch = new Set(entries.map(([uid]) => uid));
    for (const peer of set) {
      if (peer.readyState !== WebSocket.OPEN || peer.safetyOnly) continue;
      if (peer.bufferedAmount > MAX_BUFFERED_BYTES) { this.stats.slowKicked++; this._kick(peer, 1013, 'SLOW_LINK'); continue; }
      if (peer.bufferedAmount > POS_DROP_BYTES) { this.stats.posDropped += entries.length; continue; }
      const puid = peer.user && peer.user.userId;
      const isP2 = !!(peer.caps && peer.caps.has(POS2_CAP));
      if (!inBatch.has(puid) && !peer.outq && !(peer.bufferedAmount > OUT_SOFT_BYTES)) {
        if (isP2) {
          if (!all2) all2 = ru2Frame(entries.map(([, p]) => p.p2), t);
          peer.send(all2);
          this.stats.posOut += entries.length; this.stats.batchFrames++; this.stats.pos2Frames++;
          continue;
        }
        if (peer.caps && peer.caps.has(BATCH_CAP)) {
          if (!all) all = `{"type":"RIDER_UPDATES","riders":[${entries.map(([, p]) => p.rj).join(',')}],"ts":${t}}`;
          peer.send(all);
          this.stats.posOut += entries.length; this.stats.batchFrames++;
          continue;
        }
      }
      this._sendList(peer, entries.filter(([uid]) => uid !== puid), t);
    }
  }

  /**
   * Round 8 interest management (src/interest.js), rooms above WS_INTEREST_ABOVE sockets: each peer gets its nearest
   * riders, lead / sweeper / owner and riders with an open alert now; everyone else's latest position every
   * WS_INTEREST_FAR_MS. Alerts are separate frames and never pass through here.
   */
  _flushInterest(gid, set, room, entries, t) {
    const special = this.interest.special(room);
    const latest = this.posLatest.get(gid);
    const farMs = this.interest.cfg.farMs;
    let held = false;
    for (const peer of set) {
      if (peer.readyState !== WebSocket.OPEN || peer.safetyOnly) continue;
      if (peer.bufferedAmount > MAX_BUFFERED_BYTES) { this.stats.slowKicked++; this._kick(peer, 1013, 'SLOW_LINK'); continue; }
      if (peer.bufferedAmount > POS_DROP_BYTES) { this.stats.posDropped += entries.length; continue; }
      const puid = peer.user && peer.user.userId;
      const near = this.interest.near(room, puid, peer.interestCache || (peer.interestCache = {}), t);
      const since = peer.farAt || 0;
      const farDue = t - since >= farMs;
      const list = []; const inList = new Set();
      for (const [uid, p] of entries) {
        if (uid === puid) continue;
        if (farDue || near === null || near.has(uid) || special.has(uid)) { list.push([uid, p]); inList.add(uid); } else { this.stats.interestHeld++; held = true; }
      }
      if (farDue) {
        if (latest) {
          for (const [uid, x] of latest) {
            if (!room.riders.has(uid)) { latest.delete(uid); continue; }
            if (uid === puid || inList.has(uid) || x.at <= since) continue;
            list.push([uid, x]); this.stats.interestFarSent++;
          }
        }
        peer.farAt = t;
      }
      if (list.length) this._sendList(peer, list, t);
    }
    // Withheld positions reach their peers at the next far refresh even if nobody moves again.
    if (held && !this.farTimers.has(gid)) {
      const timer = setTimeout(() => {
        this.farTimers.delete(gid);
        const s = this.rooms.get(gid); const r = this.convoys.rooms.get(gid);
        if (s && r && this.interest.active(s.size)) this._flushInterest(gid, s, r, [], Date.now());
      }, farMs);
      if (timer.unref) timer.unref();
      this.farTimers.set(gid, timer);
    }
  }

  /** Positions [[uid, p]] to one peer: one RU2 / RIDER_UPDATES frame when it can take it, else per-rider messages. */
  _sendList(peer, list, t) {
    if (!list.length) return;
    const isP2 = !!(peer.caps && peer.caps.has(POS2_CAP));
    const batch = isP2 || (POS_BATCH && !!(peer.caps && peer.caps.has(BATCH_CAP)));
    if (batch && (isP2 || list.length > 1) && !peer.outq && !(peer.bufferedAmount > OUT_SOFT_BYTES)) {
      peer.send(isP2 ? ru2Frame(list.map(([, x]) => x.p2), t) : `{"type":"RIDER_UPDATES","riders":[${list.map(([, x]) => x.rj).join(',')}],"ts":${t}}`);
      this.stats.posOut += list.length; this.stats.batchFrames++;
      if (isP2) this.stats.pos2Frames++;
      return;
    }
    for (const [uid, x] of list) { this._out(peer, this._posData(peer, x), 2, uid); this.stats.posOut++; }
  }

  /** The wire form of one position for this peer: RU2 for 'pos2' sockets, RIDER_UPDATE JSON for the rest. */
  _posData(peer, p) {
    if (peer.caps && peer.caps.has(POS2_CAP)) { this.stats.pos2Frames++; return p.ru2 || (p.ru2 = ru2Frame([p.p2], p.ts)); }
    return p.msg;
  }

  _sendPosition(set, p, fromUid, exceptWs, posUid = fromUid) {
    for (const peer of set) {
      if (peer === exceptWs || peer.readyState !== WebSocket.OPEN) continue;
      if (peer.safetyOnly) continue; // round 4: no other rider's position for a revoked session
      if (fromUid && peer.user && peer.user.userId === fromUid) continue;
      if (peer.bufferedAmount > MAX_BUFFERED_BYTES) { this.stats.slowKicked++; this._kick(peer, 1013, 'SLOW_LINK'); continue; }
      if (peer.bufferedAmount > POS_DROP_BYTES) { this.stats.posDropped++; continue; }
      this._out(peer, this._posData(peer, p), 2, posUid);
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
  /** Round 4 safety-only mode: may this socket receive this message? (Every other socket: always.) */
  static safetyOk(ws, payload) {
    if (!ws.safetyOnly) return true;
    const type = payload && payload.type;
    if (SAFETY_ONLY_OUT.has(type)) return true;
    const uid = ws.user && ws.user.userId;
    if (type === 'ALERT' || type === 'EMERGENCY_UPDATE') {
      const a = payload.alert || payload;
      if (a && a.userId === uid) { (ws.ownAlerts || (ws.ownAlerts = new Set())).add(String(a.alertId || '')); return true; }
      return false;
    }
    if (type === 'ALERT_RESOLVED' || type === 'SOS_RESPONSE') return !!(ws.ownAlerts && ws.ownAlerts.has(String(payload.alertId || '')));
    return false;
  }

  /** Round 4: puts a socket of a revoked session into safety-only mode (kept for its live ride only). */
  _safetyOnly(ws) {
    ws.revokedPending = true;
    if (ws.safetyOnly) return;
    ws.safetyOnly = true;
    this.admins.delete(ws);
    this._endVoiceStreamsOf(ws);
    this.send(ws, { type: 'SAFETY_ONLY', message: SAFETY_ONLY_MESSAGE, ts: Date.now() });
  }

  send(ws, obj) { if (ws.readyState === WebSocket.OPEN && Hub.safetyOk(ws, obj)) this._out(ws, JSON.stringify(obj), Hub.prioOf(obj)); }
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
      if (ws.safetyOnly && !Hub.safetyOk(ws, payload)) continue;
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
  /** Distinct riders with an open, signed-in (allowed) socket on this node, in a room or not. */
  onlineUsers() {
    const out = new Set();
    for (const [uid, set] of this.byUser) for (const ws of set) if (ws.allowed && ws.readyState === WebSocket.OPEN) { out.add(uid); break; }
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
    for (const ws of set) if (ws.caps && ws.caps.has(cap) && ws.readyState === WebSocket.OPEN && Hub.safetyOk(ws, payload)) { this._out(ws, msg, prio); n++; }
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
    for (const ws of set) if ((!cap || (ws.caps && ws.caps.has(cap))) && ws.allowed && ws.readyState === WebSocket.OPEN && Hub.safetyOk(ws, payload)) { this._out(ws, msg, prio); n++; }
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
      this.stats.rlUserEvicted++;
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
    for (const ws of this.wss.clients) if (ws.readyState === WebSocket.OPEN && !ws.safetyOnly) this._out(ws, msg, 1);
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
    for (const ws of this.admins) if (ws.readyState === WebSocket.OPEN && ws.allowed && !ws.safetyOnly && ws.user.role === ROLE_ADMIN) ws.send(msg);
  }

  /**
   * Upgrade check: the origin rule, then round 8 per-IP limits (concurrent sockets, new sockets per minute). A refused
   * upgrade is answered HTTP 429 with Retry-After and costs no socket. The slot is freed when the TCP connection closes.
   */
  _verifyClient(info, cb) {
    if (!this._originAllowed(info.req)) return cb(false);
    const { key } = RL.clientIpOf(info.req, this.trusted);
    const r = this.ipLimiter.admit(key);
    if (!r.ok) {
      if (r.reason === 'rate') this.stats.rlIpRate++; else this.stats.rlIpConcurrent++;
      return cb(false, 429, 'Too Many Requests', { 'Retry-After': String(5 + Math.floor(Math.random() * 10)) });
    }
    if (key) {
      let freed = false;
      const free = () => { if (!freed) { freed = true; this.ipLimiter.release(key); } };
      if (info.req.socket) info.req.socket.once('close', free); else free();
    }
    return cb(true);
  }

  /** Round 8 timeouts (heartbeat): idle sockets outside a ride, and peers that stopped reading. True when closed. */
  _idleOrSlow(ws, t) {
    const L = this.limits;
    if (L.slowReaderMs > 0) {
      if (ws.bufferedAmount > OUT_SOFT_BYTES) {
        if (!ws.slowSince) ws.slowSince = t;
        else if (t - ws.slowSince > L.slowReaderMs) { this.stats.rlSlowReader++; this._kick(ws, 1013, 'SLOW_LINK'); return true; }
      } else ws.slowSince = 0;
    }
    if (L.idleMs > 0 && ws.allowed && !ws.groupId && !this.admins.has(ws) && t - (ws.lastInAt || ws.openedAt || t) > L.idleMs) {
      this.stats.rlIdleClosed++; this._kick(ws, 4408, 'IDLE_TIMEOUT'); return true;
    }
    return false;
  }

  /**
   * Round 8 per-socket token buckets: true when the message may go on. Over budget: positions and keep-alives are
   * dropped silently, anything else gets the usual ERROR 429 "Slow down." (with its clientId, so the phone's outbox
   * retries later); a RATE_LIMIT warning frame at most every 5 s per class; a socket that keeps flooding is closed 4429.
   * Safety messages always pass.
   */
  _rateOk(ws, cls, cid) {
    if (!ws.limiter || cls === 'safety') return true;
    if (ws.rlKicked) return false; // frames already buffered behind the close: dropped, not counted again
    const r = ws.limiter.check(cls);
    if (r === 'ok') return true;
    const k = `rlDrop${cls[0].toUpperCase()}${cls.slice(1)}`;
    if (k in this.stats) this.stats[k]++;
    if (r === 'kick') { ws.rlKicked = true; this.stats.rlKicked++; this._kick(ws, 4429, `RATE_LIMIT_${cls.toUpperCase()}`); return false; }
    const wait = ws.limiter.warn(cls);
    if (wait) { this.stats.rlWarned++; this.send(ws, { type: 'RATE_LIMIT', class: cls, retryMs: wait, ts: Date.now() }); }
    if (cls !== 'pos' && cls !== 'ping') this.sendError(ws, 429, 'Slow down.', 'RATE_LIMITED', cid || undefined);
    return false;
  }

  /** One invalid frame (malformed JSON, schema or size): true when the socket was closed for sending too many. */
  _invalidFrame(ws) {
    if (ws.rlKicked) return true;
    this.stats.rlInvalid++;
    if (ws.limiter && ws.limiter.invalid() === 'kick') { ws.rlKicked = true; this.stats.rlInvalidKicked++; this._kick(ws, 4400, 'INVALID_FRAMES'); return true; }
    return false;
  }

  /** A refused JOIN (not a member): a socket guessing group ids is closed 4429 JOIN_FLOOD. */
  _joinRefused(ws) {
    if (ws.rlKicked) return;
    if (ws.limiter && ws.limiter.joinRefused()) { ws.rlKicked = true; this.stats.rlJoinFlood++; this._kick(ws, 4429, 'JOIN_FLOOD'); }
  }

  /** Same-origin, an allowed site origin, or no Origin header at all (native app, server clients). */
  _originAllowed(req) {
    const origin = req && req.headers ? req.headers.origin : undefined;
    if (origin === undefined || origin === '') return true;
    if (this.allowedOrigins && this.allowedOrigins.has(String(origin).toLowerCase())) return true;
    try {
      const o = new URL(String(origin));
      return o.host.toLowerCase() === String(req.headers.host || '').toLowerCase();
    } catch { return false; }
  }

  // ---------------------------------------------------------- connection
  /**
   * The token of an upgrade request: Authorization: Bearer, the subprotocol entry "coroute.bearer.<token>" (round 4),
   * or ?token= (builds before 10025). Null when none: the first message must then be { type: 'AUTH', token }.
   */
  static upgradeToken(req) {
    const h = (req && req.headers && req.headers.authorization) || '';
    if (h.startsWith('Bearer ')) return { token: h.slice(7), via: 'header' };
    const proto = String((req && req.headers && req.headers['sec-websocket-protocol']) || '');
    if (proto) {
      for (const p of proto.split(',')) {
        const v = p.trim();
        if (v.startsWith(WS_BEARER_PREFIX) && v.length > WS_BEARER_PREFIX.length) return { token: v.slice(WS_BEARER_PREFIX.length), via: 'protocol' };
      }
    }
    try {
      const url = new URL(req.url, 'http://localhost');
      const q = url.searchParams.get('token');
      if (q) return { token: q, via: 'query' };
    } catch { /* ignore */ }
    return null;
  }

  _onConnection(ws, req) {
    this.stats.connections++;
    ws.openedAt = Date.now();
    ws.limiter = new RL.SocketLimiter(this.limits);
    const found = Hub.upgradeToken(req);
    if (found) return this._startSession(ws, found.token);
    // Round 4: no token in the request: the first message authenticates, within WS_AUTH_TIMEOUT_MS (5 s).
    ws.on('error', () => { /* close handler runs */ });
    ws.authPending = true;
    const timer = setTimeout(() => {
      if (!ws.authPending) return;
      ws.authPending = false;
      try { ws.close(4401, 'AUTH_TIMEOUT'); } catch { /* gone */ }
    }, config.wsAuthTimeoutMs);
    if (timer.unref) timer.unref();
    ws.once('message', (data, isBinary) => {
      clearTimeout(timer);
      if (!ws.authPending) return;
      ws.authPending = false;
      let m = null;
      if (!isBinary) { try { m = JSON.parse(data.toString()); } catch { m = null; } }
      if (!m || m.type !== 'AUTH' || typeof m.token !== 'string' || m.token.length > 4096) { try { ws.close(4401, 'Unauthorized'); } catch { /* gone */ } return; }
      this._startSession(ws, m.token);
    });
    ws.once('close', () => clearTimeout(timer));
  }

  _startSession(ws, token) {
    const verified = token && verifyTokenDetailed(token, { allowExpired: true });
    if (!verified) { ws.close(4401, 'Unauthorized'); return; }
    // 3.57: a short access token that ran out: the app refreshes and reconnects at once (no sign-out).
    if (verified.expired) { ws.close(4401, verified.claims.typ === 'at' ? 'TOKEN_EXPIRED' : 'Unauthorized'); return; }
    const claims = verified.claims;
    // Round 8: new sockets per account (a reconnect loop or a stolen token in a tight loop), before any database work.
    if (!this.userConnLimiter.admit(claims.sub)) { this.stats.rlUserConnect++; ws.close(4429, 'TOO_MANY_CONNECTS'); return; }

    ws.claims = claims;
    ws.sid = claims.sid || null;
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
          ws.lastInAt = Date.now();
          if (!this._rateOk(ws, 'pos')) return;
          this._onBinaryTelemetry(ws, buf).catch((e) => this._handleError(ws, e));
          return;
        }
        if (ws.safetyOnly) return; // round 4: no voice from a revoked session
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
      if (ok) this.send(ws, { type: 'HELLO', userId: ws.user.userId, serverTime: Date.now(), heartbeatSec: Math.round(HEARTBEAT_MS / 1000), protocol: 2, features: FEATURES });
      if (ok && ws.safetyOnly) this.send(ws, { type: 'SAFETY_ONLY', message: SAFETY_ONLY_MESSAGE, ts: Date.now() });
      // 3.55: an app that missed a switch change while offline catches up on (re)connect.
      const ff = this.convoys.featureFlags;
      if (ok && ff && ff.anyOff() && !ws.safetyOnly) this.send(ws, { type: 'FEATURE_FLAGS', ...ff.snapshot() });
      return ok;
    });
  }

  /** Close code for an account the gate refused: 4403 hold/block (do not retry), 4401 gone or signed out. */
  static closeCodeFor(e) {
    return e && (e.code === 'ACCOUNT_ON_HOLD' || e.code === 'ACCOUNT_BLOCKED') ? 4403 : 4401;
  }

  /** Runs the account gate for a socket; refreshes its identity or closes it. Resolves to true when allowed. */
  async _gateCheck(ws, { hot = false } = {}) {
    if (!this.gate) { ws.allowed = true; return true; }
    try {
      // 3.57: the session too (signed out, revoked, idle): checkDetailed also keeps an app session's last-seen fresh.
      // v3.56: positions and keep-alives (hot) accept an older cached entry and refresh it in the background.
      const opts = hot && GATE_HOT_TTL_MS > 0 ? { maxAgeMs: GATE_HOT_TTL_MS, swr: true } : undefined;
      const { user } = typeof this.gate.checkDetailed === 'function' ? await this.gate.checkDetailed(ws.claims, opts) : { user: await this.gate.check(ws.claims) };
      ws.user = identityOf(user);
      if (ws.user.role !== ROLE_ADMIN) this.admins.delete(ws);
      ws.allowed = true;
      return true;
    } catch (e) {
      // 3.57: a signed-out / revoked session never cuts a rider out of a live ride (SOS, crash alerts, positions): the
      // socket stays until the ride ends or the rider leaves it, then closes 4401. REST calls are refused at once.
      if (e instanceof AuthError && e.revoked && this._rideKeepsSocket(ws)) {
        ws.allowed = true;
        this._safetyOnly(ws); // round 4: SOS, crash alerts and own position only, until the ride ends
        return true;
      }
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

  /**
   * Ends every socket of one account at once (hold, block, delete, sign out everywhere); `exceptSid` keeps one session's;
   * `spareRiding` (sign-outs only, never hold / block / delete) keeps a socket in a live ride until the ride ends.
   */
  disconnectUser(userId, code = 4401, reason = 'ACCOUNT_GONE', { exceptSid = null, spareRiding = false } = {}) {
    let n = 0;
    for (const ws of this.wss.clients) {
      if (!ws.user || ws.user.userId !== userId || (exceptSid && ws.sid === exceptSid)) continue;
      if (spareRiding && this._rideKeepsSocket(ws)) { this._safetyOnly(ws); continue; }
      this._kick(ws, code, reason); n++;
    }
    return n;
  }

  /** 3.57: ends the sockets of one signed-out / revoked session (close 4401 SIGNED_OUT). spareRiding: see _rideKeepsSocket. */
  disconnectSession(sid, code = 4401, reason = 'SIGNED_OUT', { spareRiding = false } = {}) {
    if (!sid) return 0;
    let n = 0;
    for (const ws of this.wss.clients) {
      if (ws.sid !== sid) continue;
      if (spareRiding && this._rideKeepsSocket(ws)) { this._safetyOnly(ws); continue; }
      this._kick(ws, code, reason); n++;
    }
    return n;
  }

  /**
   * 3.57: true while this socket's rider is in a live ride on this node (bound to an active room, or a member of one
   * loaded here when reconnecting). Such a socket of a revoked session stays open until the ride is over.
   */
  _rideKeepsSocket(ws) {
    const uid = ws && ws.user && ws.user.userId;
    if (!uid || !this.convoys || !this.convoys.rooms) return false;
    const live = (room) => !!room && room.riders && room.riders.has(uid) && ACTIVE_RIDE.has(room.meta && room.meta.tripStatus);
    if (ws.groupId) return live(this.convoys.rooms.get(ws.groupId));
    for (const room of this.convoys.rooms.values()) if (live(room)) return true;
    return false;
  }

  /** 3.57: a ride ended: sockets kept open only for it (revoked sessions) close now. */
  closeRevokedOf(groupId) {
    for (const ws of this.wss.clients) {
      if (ws.revokedPending && (!ws.groupId || ws.groupId === groupId) && !this._rideKeepsSocket(ws)) this._kick(ws, 4401, 'SIGNED_OUT');
    }
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
    // Round 8: the SOS budget never goes below WS_SOS_FLOOR_PER_10S (default 10), whatever WS_ALARMS_PER_10S says.
    const limit = type === 'SOS' ? Math.max(config.wsAlarmsPer10s, this.limits.sosFloorPer10s) : config.wsAlarmsPer10s;
    if (recent.length >= limit) return false;
    recent.push(t);
    return true;
  }

  /**
   * Round 8: an SOS above its per-socket floor. True when answered with the rider's newest open alert (an ALERT echo
   * with duplicate: true, no database work); false when the rider has no open alert in the room (then it is raised
   * like any other: an SOS is never dropped).
   */
  _sosOverFloor(ws, msg = {}) {
    this.stats.sosOverBudget++;
    const room = ws.groupId && this.convoys.rooms.get(ws.groupId);
    if (!room) return false;
    const cid = msg && msg.clientId !== undefined && msg.clientId !== null ? String(msg.clientId).slice(0, 64) : '';
    let latest = null;
    for (const a of room.alerts.values()) {
      if (a.resolved || a.userId !== ws.user.userId) continue;
      if (cid && a.clientId === cid) { latest = a; break; } // a resend of this very SOS: its own alert
      if (!latest || (a.timestamp || 0) >= (latest.timestamp || 0)) latest = a;
    }
    if (!latest || (room.unsaved && room.unsaved.has(latest.alertId))) return false;
    this.stats.sosOverFloorEcho++;
    this.send(ws, { type: 'ALERT', alert: publicAlert(latest), duplicate: true, ts: Date.now() });
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
    if (!(await this._gateCheck(ws, { hot: true }))) return;
    const gid = ws.groupId;
    if (!gid) return;
    if (!this._allow(ws, 'telemetry', 3)) return; // silently drop bursts
    const room = await this._liveRoom(ws, gid);
    if (!room) return;
    if (this.rideLock && ws.sid && !ws.safetyOnly) this.rideLock.noteRide(ws.sid, ws.user.userId, gid).catch(() => {});
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
    ws.lastInAt = Date.now();
    let msg; let bad = false;
    try { msg = JSON.parse(data.toString()); } catch { bad = true; }
    // Round 8 'pos2': a compact position frame carries "t":"P2" instead of a type.
    if (!bad && msg && typeof msg === 'object' && msg.type === undefined && msg.t === 'P2') msg.type = 'P2';
    // Round 8 per-socket buckets before any async work (safety messages always pass).
    const okObj = !bad && !!msg && typeof msg === 'object' && !Array.isArray(msg);
    if (okObj && !this._rateOk(ws, RL.classOf(msg.type), CLIENT_ID_TYPES.has(msg.type) ? clientIdOf(msg.clientId) : '')) return;
    // Re-check the account through the cached gate (no DB read inside the TTL): a hold, block,
    // delete, demotion or password change applies to an open socket too. v3.56: positions and pings use the
    // longer hot-path bound (WS_GATE_TTL_MS) and never wait for the database.
    if (!(await this._gateCheck(ws, { hot: !bad && !!msg && HOT_TYPES.has(msg.type) }))) return;
    if (bad || !okObj) { if (this._invalidFrame(ws)) return; return this.sendError(ws, 400, 'Malformed JSON'); }
    // Round 8 schema / size check per type (src/ws_limits.js validateInbound; safety types always pass).
    const why = RL.validateInbound(msg, data.length);
    if (why) {
      if (this._invalidFrame(ws)) return;
      return this.sendError(ws, 400, 'Invalid message.', 'INVALID_MESSAGE', CLIENT_ID_TYPES.has(msg.type) ? clientIdOf(msg.clientId) || undefined : undefined);
    }
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
    if (ALARM_TYPES.has(msg.type) && !this._allowAlarm(ws, msg.type)) {
      // Round 8: an SOS is never refused by a rate limit. Above its floor (WS_SOS_FLOOR_PER_10S) the rider's open alert
      // is echoed back (the phone marks it delivered); with no open alert it is handled as usual.
      if (msg.type !== 'SOS') throw new ConvoyError('Slow down.', 429);
      if (this._sosOverFloor(ws, msg)) return;
    }
    // 3.55 admin feature switches: a message of a feature the admin turned off gets the usual ERROR
    // shape (403, reason FEATURE_OFF). Keyed by type, so a case that does not exist yet costs nothing.
    if (firstOff(this.convoys.featureFlags, wsFeaturesFor(msg))) throw new ConvoyError(FEATURE_OFF_MESSAGE, 403, FEATURE_OFF);
    // 3.56 access mode: a hybrid free-tier ride includes only the group features the admin chose.
    if (ws.groupId && typeof this.convoys.rideFeatureOff === 'function' && this.convoys.rideFeatureOff(ws.groupId, wsFeaturesFor(msg))) {
      throw new ConvoyError("This isn't included in this ride.", 403, 'GROUP_FEATURE_LOCKED');
    }
    // Round 4 safety-only mode (a session revoked during the ride): only its own SOS / crash alert and position.
    if (ws.safetyOnly && !SAFETY_ONLY_IN.has(msg.type)) throw new ConvoyError(SAFETY_ONLY_MESSAGE, 403, 'SAFETY_ONLY');
    switch (msg.type) {
      case 'AUTH': return; // already authenticated (a repeated first message)
      case 'PING': {
        if (ws.groupId && this.rideLock && !ws.safetyOnly && ws.sid) this.rideLock.noteRide(ws.sid, u.userId, ws.groupId).catch(() => {});
        return this.send(ws, { type: 'PONG', ts: Date.now() });
      }

      case 'JOIN': {
        const groupId = String(msg.groupId || '');
        if (groupId.length > 64) { this._joinRefused(ws); throw new ConvoyError('You are not a member of this convoy.', 403, 'NOT_MEMBER'); }
        if (!(await this.convoys.isMember(groupId, u.userId))) { this._joinRefused(ws); throw new ConvoyError('You are not a member of this convoy.', 403, 'NOT_MEMBER'); }
        if (this.mirror && this.mirror.capReached(u.userId) && !this._rejoining(groupId, u.userId)) {
          throw new ConvoyError('Server busy, try in a few minutes', 503, 'SERVER_BUSY');
        }
        // Round 4 ride lock: another device of this account is on a ride: this session cannot join one.
        if (this.rideLock && ws.sid && !ws.safetyOnly) {
          try { await this.rideLock.assertCanRide(u.userId, ws.sid, { reason: 'join' }); } catch (e) {
            if (e instanceof AuthError) throw new ConvoyError(e.message, 409, e.code);
            throw e;
          }
        }
        this._bind(ws, groupId);
        ws.byeReason = null;
        // 3.15 client capabilities, on every JOIN (array of at most 8 short words, unknown ones ignored).
        ws.caps = new Set(Array.isArray(msg.caps) ? msg.caps.slice(0, 8).filter((c) => typeof c === 'string' && CAP.test(c)) : []);
        const room = await this.convoys.getRoom(groupId);
        if (ws.safetyOnly) {
          // Round 4: no snapshot (other riders' details) for a revoked session; it may still raise its SOS here.
          this.send(ws, { type: 'SAFETY_ONLY', groupId, message: SAFETY_ONLY_MESSAGE, ts: Date.now() });
          return;
        }
        if (this.rideLock && ws.sid) {
          const force = ws.notedGroup !== groupId;
          ws.notedGroup = groupId;
          this.rideLock.noteRide(ws.sid, u.userId, groupId, { force }).catch(() => {});
        }
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
        if (this.rideLock && ws.sid && !ws.safetyOnly) this.rideLock.noteRide(ws.sid, u.userId, gid).catch(() => {});
        // Only telemetry fields are applied (never role or profile); see ConvoyManager.patchRider.
        const rider = this.convoys.patchRider(room, u.userId, msg, { emit: false });
        this._fanoutPosition(gid, ws, rider);
        if (this.mirror && rider) this.mirror.position(gid, rider);
        return;
      }
      case 'P2': {
        // Round 8 compact position frame (src/pos2.js): same rules and budget as TELEMETRY.
        const gid = this._requireRoom(ws);
        if (!this._allow(ws, 'telemetry', 3)) return; // silently drop bursts
        const dec = decodeP2(msg, ws.p2key || (ws.p2key = {}));
        if (!dec) return this.sendError(ws, 400, 'Invalid position.', 'INVALID_MESSAGE');
        if (dec.miss) { this.stats.pos2Miss++; return; } // a delta without its full fix: the next full one follows
        this.stats.pos2In++;
        const room = await this._liveRoom(ws, gid);
        if (!room) return;
        if (this.rideLock && ws.sid && !ws.safetyOnly) this.rideLock.noteRide(ws.sid, u.userId, gid).catch(() => {});
        const rider = this.convoys.patchRider(room, u.userId, dec.patch, { emit: false });
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
        if (driver && driver === u.userId) throw new ConvoyError('You cannot ride pillion on your own bike.', 400, 'BAD_PILLION');
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
      case 'CHAT_REPORT': {
        // 3.55 ride chat: report a message to the CoRoute team (public ride reports queue).
        const gid = this._requireRoom(ws);
        if (!this._allow(ws, 'action', 5)) throw new ConvoyError('Slow down.', 429);
        if (!this.publicRides) throw new ConvoyError('Reports are not available right now.', 503);
        const room = await this.convoys.getRoom(gid);
        const res = await this.publicRides.reportGroupChat(u, room, msg);
        return void this.send(ws, res);
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
      // ---- 3.55 no-signal ahead: relayed to the group and the rider's guardian links (src/signal_ahead.js) ----
      case 'SIGNAL_AHEAD': {
        if (!this.convoys.signalAhead) return this.sendError(ws, 400, `Unknown message type ${msg.type}`);
        this._requireRoom(ws);
        this.convoys.signalAhead.handle(ws, msg);
        return;
      }
      // ---- 3.16 ----
      case 'ROLE_SET': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'ROLE_SET', () => this.convoys.setRole(gid, u, msg.userId, msg.role));
      }
      // ---- 3.55: swap two riders' roles, automatic roles on/off ----
      case 'ROLE_SWAP': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'ROLE_SWAP', () => this.convoys.swapRoles(gid, u, msg.userId, msg.withUserId));
      }
      case 'ROLE_AUTO': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'ROLE_AUTO', () => this.convoys.setAutoRoles(gid, u, msg.on === true));
      }
      // ---- 3.55: two riders swap bikes, or a rider and their pillion change places ----
      case 'SWAP_REQUEST': {
        const gid = this._requireRoom(ws);
        const kind = typeof msg.kind === 'string' ? msg.kind.toUpperCase() : '';
        return this._once(ws, cid, 'SWAP_REQUEST', () => this.convoys.requestSwap(gid, u, msg.withUserId, kind));
      }
      case 'SWAP_ANSWER': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'SWAP_ANSWER', () => this.convoys.answerSwap(gid, u, msg.requestId, msg.accept === true));
      }
      // ---- 3.55: the rider picked another garage bike mid-ride ----
      case 'RIDER_VEHICLE': {
        const gid = this._requireRoom(ws);
        return void await this.convoys.setRiderVehicle(gid, u, msg);
      }
      // ---- 3.55: the pillion confirms which bike they sit on; the rider may decline / remove ----
      case 'PILLION_SEAT': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'PILLION_SEAT', () => this.convoys.seatPillion(gid, u, msg.withUserId));
      }
      case 'PILLION_UNSEAT': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'PILLION_UNSEAT', () => this.convoys.unseatPillion(gid, u, msg.userId));
      }
      // ---- 3.55: buddy pairs in large groups (src/buddies.js) ----
      case 'BUDDY_ASSIGN': {
        const gid = this._requireRoom(ws);
        if (!this.convoys.buddies) return this.sendError(ws, 400, `Unknown message type ${msg.type}`);
        return this._once(ws, cid, 'BUDDY_ASSIGN', () => this.convoys.buddies.assign(gid, u));
      }
      case 'BUDDY_PING': {
        const gid = this._requireRoom(ws);
        if (!this.convoys.buddies) return this.sendError(ws, 400, `Unknown message type ${msg.type}`);
        return this._once(ws, cid, 'BUDDY_PING', () => this.convoys.buddies.ping(gid, u, msg));
      }
      // Round 8 voice: the app's receivable codecs (HELLO feature 'voice2'); answered with VOICE_CODEC.
      case 'VOICE_CAPS':
        this._requireRoom(ws);
        return this.voiceRelay.onCaps(ws, msg);
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
        // Same rule as POST /convoys/:id/status (routes.js).
        const isAdmin = u.role === ROLE_ADMIN || u.role === 'MASTER_ADMIN';
        if (!this.convoys.isLead(room, u) && !isAdmin) {
          throw new ConvoyError('Only the Trip owner or Lead can change the trip state.', 403, 'NOT_LEAD');
        }
        const status = String(msg.status || '').toUpperCase();
        if (status === 'ENDED' && !this.convoys.canManage(room, u)) {
          throw new ConvoyError('Only the Trip owner can end the trip.', 403, 'ONLY_OWNER_CAN_END_TRIP');
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
        const isRoadCaptain = this.convoys.isLead(room, u) || (rider && rider.role === 'CAPTAIN') ||
          u.role === 'ROAD_CAPTAIN' || u.role === 'MASTER_ADMIN' || u.role === 'ADMIN';

        if (!isRoadCaptain) {
          throw new ConvoyError('Only the Trip owner or Lead can broadcast road hazard alerts.', 403, 'ENTITLEMENT_REQUIRED');
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

        // 3.55: saved for future rides along this road (no rider id; merged with nearby reports).
        if (this.repo && typeof this.repo.saveRoadHazard === 'function') {
          const { roadRecordOf, reporterKeyOf } = require('./road_and_places');
          // What this rider felt (kind, spot, direction), not the live pin it merged into: the live
          // registry merges any kind within 100 m, the saved reports merge per kind within 80 m.
          // A new saved report gets a server id, so a client id can never overwrite another one.
          const felt = {
            hazardId: `rh_${crypto.randomBytes(8).toString('hex')}`, lat, lng,
            heading: Number(msg.heading) || (rider ? Number(rider.heading) : 0) || pin.heading,
            severity: msg.severity || pin.severity, classification: msg.classification || pin.classification,
          };
          this.repo.saveRoadHazard(roadRecordOf(felt), { reporterKey: reporterKeyOf(u.userId) })
            .catch((e) => this.log?.warn?.('[road] save failed', e.message));
        }
        pin.spokenWarning = require('./road_and_places').spokenWarningFor(pin.classification);

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
  // Round 8 voice: delegates to src/voice_relay.js (VoiceRelay). Names kept for mirror.js and older callers.
  _voiceState(groupId) { return this.voiceRelay.voiceState(groupId); }
  _onVoice(ws, data) { return this.voiceRelay.onBinary(ws, data); }
  _hdr(s) { return this.voiceRelay._hdr(s); }
  _relay(gid, stream, kind, header, payload) { return this.voiceRelay.fanout(gid, stream, kind, header, payload); }
  _endStream(gid, stream, reason) { return this.voiceRelay.endStream(gid, stream, reason); }
  _endVoiceStreamsOf(ws) { return this.voiceRelay.endStreamsOf(ws); }
  /** Voice from a rider on the peer gateway (hand-back window); see VoiceRelay.applyRemote. */
  applyRemoteVoice(gid, kind, header, payload, opts = {}) { return this.voiceRelay.applyRemote(gid, kind, header, payload, opts); }
  /** The group floor of a room for the mirror snapshot, or null. */
  floorOf(gid) { return this.voiceRelay.floorOf(gid); }
}

module.exports = { Hub, encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END, FEATURES, FEATURES_314 };
