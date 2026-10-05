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
const { verifyToken, ROLE_ADMIN } = require('./auth');
const { ConvoyError } = require('./convoys');
const { validateChunk, TrackError, uploadPermission } = require('./tracks');
const { visibleWindow, eventVisible, publicEvent } = require('./timeline');

const VOICE_START = 0x01, VOICE_FRAME = 0x02, VOICE_END = 0x03;

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
  constructor({ server, convoys, repo, tracks = null, timeline = null, logger = console, path = '/ws' }) {
    this.convoys = convoys; this.repo = repo; this.tracks = tracks; this.timeline = timeline; this.log = logger;
    this.rooms = new Map(); // groupId -> Set<ws>
    this.admins = new Set();
    this.voice = new Map(); // groupId -> { group: stream|null, private: Map<from, stream> }
    this.wss = new WebSocketServer({ server, path, maxPayload: 256 * 1024 });
    this.wss.on('connection', (ws, req) => this._onConnection(ws, req));

    convoys.on('event', (groupId, payload) => this.broadcast(groupId, payload));
    convoys.on('broadcast', (entry) => this.broadcastAll({ type: 'BROADCAST', message: entry.message, ts: entry.timestamp }));
    convoys.on('fleet', () => this._scheduleFleet());

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

  close() { clearInterval(this.heartbeat); clearInterval(this.fleetTimer); this.wss.close(); }

  // ------------------------------------------------------------- helpers
  send(ws, obj) { if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj)); }
  sendError(ws, code, message, reason) { this.send(ws, { type: 'ERROR', code, message, ...(reason ? { reason } : {}) }); }

  broadcast(groupId, payload, { except } = {}) {
    const set = this.rooms.get(groupId);
    if (!set) return;
    const msg = JSON.stringify(payload);
    for (const ws of set) if (ws !== except && ws.readyState === WebSocket.OPEN) ws.send(msg);
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
    const fleet = await this.convoys.fleet();
    const msg = JSON.stringify({ type: 'FLEET', convoys: fleet, ts: Date.now() });
    for (const ws of this.admins) if (ws.readyState === WebSocket.OPEN) ws.send(msg);
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

    ws.user = { userId: claims.sub, name: claims.name, role: claims.role, email: claims.email };
    ws.isAlive = true;
    ws.groupId = null;
    ws.rate = { telemetry: 0, chat: 0, track: 0, windowStart: Date.now() };
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('message', (data, isBinary) => {
      if (isBinary) this._onVoice(ws, data);
      else this._onJson(ws, data).catch((e) => this._handleError(ws, e));
    });
    ws.on('close', () => { this._unbind(ws); this.admins.delete(ws); });
    ws.on('error', () => { /* close handler runs */ });
    this.send(ws, { type: 'HELLO', userId: ws.user.userId, serverTime: Date.now(), heartbeatSec: 30 });
  }

  _handleError(ws, e) {
    if (e instanceof ConvoyError || e instanceof TrackError) return this.sendError(ws, e.status, e.message, e.reason);
    this.log.warn('[ws] error', e.message);
    this.sendError(ws, 500, 'Internal error');
  }

  _allow(ws, bucket, limitPerSec) {
    const t = Date.now();
    if (t - ws.rate.windowStart >= 1000) { ws.rate.windowStart = t; ws.rate.telemetry = 0; ws.rate.chat = 0; ws.rate.track = 0; }
    return ++ws.rate[bucket] <= limitPerSec;
  }

  _requireRoom(ws) {
    if (!ws.groupId) throw new ConvoyError('Join a convoy first.', 409);
    return ws.groupId;
  }

  async _onJson(ws, data) {
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { return this.sendError(ws, 400, 'Malformed JSON'); }
    const u = ws.user;
    switch (msg.type) {
      case 'PING': return this.send(ws, { type: 'PONG', ts: Date.now() });

      case 'JOIN': {
        const groupId = String(msg.groupId || '');
        if (!(await this.convoys.isMember(groupId, u.userId))) throw new ConvoyError('You are not a member of this convoy.', 403, 'NOT_MEMBER');
        this._bind(ws, groupId);
        const room = await this.convoys.getRoom(groupId);
        return this.send(ws, { type: 'SNAPSHOT', convoy: this.convoys.snapshot(room), ts: Date.now() });
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
        const rider = this.convoys.patchRider(room, u.userId, msg, { emit: false });
        return this.broadcast(gid, { type: 'RIDER_UPDATE', rider, ts: Date.now() }, { except: ws });
      }
      case 'STATUS': {
        const gid = this._requireRoom(ws);
        const room = await this.convoys.getRoom(gid);
        const patch = { statusReason: String(msg.statusReason ?? '').slice(0, 24), statusMessage: String(msg.statusMessage ?? '').slice(0, 140) };
        patch.stoppedSince = patch.statusReason ? (msg.stoppedSince || Date.now()) : 0;
        const prevReason = room.riders.get(u.userId)?.statusReason || '';
        const next = this.convoys.patchRider(room, u.userId, patch);
        if (patch.statusReason !== prevReason) {
          this.convoys.emit('activity', gid, { type: 'STATUS', user: u, reason: patch.statusReason, message: patch.statusMessage, lat: next.lat, lng: next.lng });
        }
        return;
      }
      case 'CORIDER': {
        const gid = this._requireRoom(ws);
        const room = await this.convoys.getRoom(gid);
        const driver = String(msg.ridingWithUserId || '');
        if (driver && !room.riders.has(driver)) throw new ConvoyError('Driver is not in this convoy.');
        const was = room.riders.get(u.userId)?.ridingWithUserId || '';
        this.convoys.patchRider(room, u.userId, { isCoRiding: !!driver, ridingWithUserId: driver });
        if (was !== driver) this.convoys.emit('activity', gid, { type: 'CORIDE', user: u, withUserId: driver });
        return;
      }
      case 'CHAT': {
        const gid = this._requireRoom(ws);
        if (!this._allow(ws, 'chat', 5)) throw new ConvoyError('Slow down.', 429);
        await this.convoys.sendMessage(gid, u, msg);
        return;
      }
      case 'WAIT': return void await this.convoys.requestWait(this._requireRoom(ws), u);
      case 'SOS': return void await this.convoys.raiseSos(this._requireRoom(ws), u, msg);
      case 'SOS_RESOLVE': return void await this.convoys.resolveSos(this._requireRoom(ws), u, String(msg.alertId || ''));
      case 'STOP_ADD': return void await this.convoys.addStop(this._requireRoom(ws), u, msg);
      case 'STOP_VISITED': return void await this.convoys.setStopVisited(this._requireRoom(ws), u, String(msg.stopId || ''), !!msg.isVisited);
      case 'CONFIG': return void await this.convoys.updateConfig(this._requireRoom(ws), u, msg);
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
        startedAt: t, lastAt: t, frames: 0, sampleRate: Number(pkt.header.sampleRate) || 16000, codec: String(pkt.header.codec || 'pcm16'),
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

module.exports = { Hub, encodeVoice, decodeVoice, VOICE_START, VOICE_FRAME, VOICE_END };
