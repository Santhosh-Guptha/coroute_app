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

const VOICE_START = 0x01, VOICE_FRAME = 0x02, VOICE_END = 0x03;

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
  'ROLE_SET',
]);
/** Socket messages that alert the whole convoy: a few per 10 seconds, each type with its own budget
 * (a rider who just asked the group to wait must still be able to raise an SOS). */
const ALARM_TYPES = new Set(['WAIT', 'SOS', 'CHECK_IN', 'REPORT_DOWN']);
/** Messages that may carry a clientId (phone outbox): applied once, answered with ACK. */
const CLIENT_ID_TYPES = new Set(['CHAT', 'WAIT', 'STATUS', 'STOP_VISITED', 'SOS_RESPOND', 'CHECK_IN', 'REPORT_DOWN', 'ASSIST_ANSWER', 'NET_REPORT_FALSE', 'WAVE', 'ROLE_SET']);
const BYE_REASONS = new Set(['APP_CLOSED', 'SIGN_OUT', 'LEFT']);
/** Protocol features this gateway offers (HELLO.features); 3.14 apps use a feature only when listed. */
const FEATURES_314 = ['ack', 'sos2', 'respond', 'presence', 'checkin', 'roster'];
/** 3.15: safety network and discovery, appended when switched on. */
/** 3.16: sweeper role, follow-up check-in, town limit, live links (always on). */
const FEATURES = [...FEATURES_314, ...(config.safetyNetEnabled ? ['net1'] : []), ...(config.discoveryEnabled ? ['discovery1'] : []), 'ride316'];
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
  constructor({ server, convoys, repo, tracks = null, timeline = null, logger = console, path = '/ws', gate = null, network = null, discovery = null }) {
    this.convoys = convoys; this.repo = repo; this.tracks = tracks; this.timeline = timeline; this.log = logger; this.gate = gate;
    this.network = network; this.discovery = discovery;
    this.rooms = new Map(); // groupId -> Set<ws>
    this.byUser = new Map(); // userId -> Set<ws> (3.15 personal messages)
    this.admins = new Set();
    this.voice = new Map(); // groupId -> { group: stream|null, private: Map<from, stream> }
    this.wss = new WebSocketServer({ server, path, maxPayload: 256 * 1024 });
    this.wss.on('connection', (ws, req) => this._onConnection(ws, req));

    convoys.on('event', (groupId, payload) => this.broadcast(groupId, payload));
    convoys.on('broadcast', (entry) => this.broadcastAll({ type: 'BROADCAST', message: entry.message, ts: entry.timestamp }));
    convoys.on('fleet', () => this._scheduleFleet());
    // 3.15: room messages only 3.15 apps understand (EMERGENCY_UPDATE).
    convoys.on('capEvent', (groupId, cap, payload) => this.broadcastCap(groupId, cap, payload));

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
    clearInterval(this.heartbeat); clearInterval(this.fleetTimer); this.wss.close();
  }

  // ------------------------------------------------------------- helpers
  send(ws, obj) { if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj)); }
  sendError(ws, code, message, reason, clientId) {
    this.send(ws, { type: 'ERROR', code, message, ...(reason ? { reason } : {}), ...(clientId ? { clientId } : {}) });
  }

  broadcast(groupId, payload, { except } = {}) {
    const set = this.rooms.get(groupId);
    if (!set) return;
    const msg = JSON.stringify(payload);
    for (const ws of set) if (ws !== except && ws.readyState === WebSocket.OPEN) ws.send(msg);
  }
  /** Room broadcast to sockets that announced `cap` in their JOIN (3.15 types never reach older apps). */
  broadcastCap(groupId, cap, payload) {
    const set = this.rooms.get(groupId);
    if (!set) return 0;
    const msg = JSON.stringify({ ts: Date.now(), ...payload });
    let n = 0;
    for (const ws of set) if (ws.caps && ws.caps.has(cap) && ws.readyState === WebSocket.OPEN) { ws.send(msg); n++; }
    return n;
  }
  /** Personal message to every open socket of a user that announced `cap`. Returns how many got it. */
  sendToUser(userId, payload, cap) {
    const set = this.byUser.get(userId);
    if (!set) return 0;
    const msg = JSON.stringify({ ts: Date.now(), ...payload });
    let n = 0;
    for (const ws of set) if ((!cap || (ws.caps && ws.caps.has(cap))) && ws.allowed && ws.readyState === WebSocket.OPEN) { ws.send(msg); n++; }
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
    for (const ws of this.wss.clients) if (ws.readyState === WebSocket.OPEN) ws.send(msg);
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
    const msg = JSON.stringify({ type: 'FLEET', convoys: fleet, ts: Date.now() });
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
      if (isBinary) { if (ws.allowed) this._onVoice(ws, data); return; }
      this._onJson(ws, data).catch((e) => this._handleError(ws, e));
    });
    ws.on('close', () => {
      const gid = ws.groupId;
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

  _requireRoom(ws) {
    if (!ws.groupId) throw new ConvoyError('Join a convoy first.', 409);
    return ws.groupId;
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
        if (!(await this.convoys.isMember(groupId, u.userId))) throw new ConvoyError('You are not a member of this convoy.', 403, 'NOT_MEMBER');
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
        const room = await this.convoys.getRoom(gid);
        // Only telemetry fields are applied (never role or profile); see ConvoyManager.patchRider.
        const rider = this.convoys.patchRider(room, u.userId, msg, { emit: false });
        return this.broadcast(gid, { type: 'RIDER_UPDATE', rider: publicRider(rider), ts: Date.now() }, { except: ws });
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
        // A retried SOS: only the sender hears it again, so the phone can mark it delivered.
        if (r.duplicate) this.send(ws, { type: 'ALERT', alert: publicAlert(r.alert), duplicate: true, ts: Date.now() });
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
      // ---- 3.16 ----
      case 'ROLE_SET': {
        const gid = this._requireRoom(ws);
        return this._once(ws, cid, 'ROLE_SET', () => this.convoys.setRole(gid, u, msg.userId, msg.role));
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
        return;
      }
      case 'TRIP_STATUS': {
        const gid = this._requireRoom(ws);
        const room = await this.convoys.getRoom(gid);
        const rider = room.riders.get(u.userId);
        if (!rider || (rider.role !== 'LEAD' && room.meta.createdByUserId !== u.userId && u.role !== ROLE_ADMIN)) {
          throw new ConvoyError('Only the convoy lead can change the trip state.', 403);
        }
        await this.convoys.setTripStatus(gid, String(msg.status || ''));
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
        if (perm.ended && !r.duplicate && this.timeline) this.timeline.scheduleRebuild(gid);
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
        if (cur && cur.ws !== ws) this._endStream(gid, cur, 'preempted');
      }
      const stream = {
        streamId: crypto.randomBytes(6).toString('hex'), ws, from: ws.user.userId, fromName: ws.user.name, to,
        startedAt: t, lastAt: t, frames: 0, sampleRate: VOICE_RATES.has(Number(pkt.header.sampleRate)) ? Number(pkt.header.sampleRate) : 16000, codec: String(pkt.header.codec || 'pcm16').slice(0, 16),
      };
      if (to) state.private.set(ws.user.userId, stream); else state.group = stream;
      ws.voiceStream = stream;
      this._relay(gid, stream, VOICE_START, { ...this._hdr(stream), sampleRate: stream.sampleRate, codec: stream.codec }, null);
      return;
    }

    const stream = ws.voiceStream;
    if (!stream || (stream.to || null) !== to) return; // frame without a stream → drop

    if (pkt.kind === VOICE_FRAME) {
      if (t - stream.startedAt > config.voiceMaxStreamMs) return this._endStream(gid, stream, 'max-duration');
      if (pkt.payload.length === 0 || pkt.payload.length > config.voiceMaxFrameBytes) return;
      stream.lastAt = t; stream.frames++;
      this._relay(gid, stream, VOICE_FRAME, { ...this._hdr(stream), seq: pkt.header.seq | 0 }, pkt.payload);
      return;
    }
    if (pkt.kind === VOICE_END) this._endStream(gid, stream, 'end');
  }

  _hdr(s) { return { streamId: s.streamId, from: s.from, fromName: s.fromName, to: s.to, ts: Date.now() }; }

  _relay(gid, stream, kind, header, payload) {
    const set = this.rooms.get(gid);
    if (!set) return;
    const frame = encodeVoice(kind, header, payload);
    for (const client of set) {
      if (client === stream.ws || client.readyState !== WebSocket.OPEN) continue;
      if (stream.to && client.user.userId !== stream.to) continue; // 1:1 — only the chosen rider hears it
      if (client.bufferedAmount > 512 * 1024) continue; // slow link: drop audio rather than build latency
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
    this._relay(gid, stream, VOICE_END, { ...this._hdr(stream), reason }, null);
    const durationMs = Date.now() - stream.startedAt;
    if (stream.frames > 0) {
      this.repo.logVoiceSession({ groupId: gid, from: stream.from, to: stream.to, startedAt: stream.startedAt, durationMs, frames: stream.frames, reason });
    }
  }

  _endVoiceStreamsOf(ws) {
    if (ws.voiceStream && ws.groupId) this._endStream(ws.groupId, ws.voiceStream, 'disconnect');
  }
}

module.exports = { Hub, encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END, FEATURES, FEATURES_314 };
