'use strict';
/**
 * Round 8 voice relay: the intercom off the safety path (docs/features_355/voice_clarity.md,
 * docs/quality/ROUND8_VOICE_NOTES.md). Moved out of ws.js; ws.js keeps thin delegates (marked "Round 8 voice").
 *
 * Wire format (unchanged since 3.14, binary WebSocket frames):
 *   byte 0      kind   0x01 START | 0x02 FRAME | 0x03 END
 *   bytes 1..2  header length (uint16, big-endian)
 *   header      UTF-8 JSON  { to?: userId|null, seq?, sampleRate?, codec?, channel? }
 *   rest        FRAME payload: PCM16LE mono ('pcm16') or length-prefixed Opus packets ('opus1')
 * The relay rewrites the header ({ streamId, from, fromName, to, channel, ts, ... }) and sends it to the group
 * (to == null), to exactly one rider (to == userId), or to the trip owner / Lead / sweepers (LEAD_ONLY).
 *
 * Round 8 additions:
 *  - LOWEST priority on the live socket: a voice frame goes out only while the socket has no queued safety /
 *    control backlog (ws.outq) and less than VOICE_DROP_BYTES unsent; otherwise it is dropped (never queued),
 *    so an SOS, alert or position is never behind more than VOICE_DROP_BYTES of audio.
 *  - Codec negotiation: apps announce VOICE_CAPS { codecs: ['opus1', 'pcm16'] } (HELLO feature 'voice2').
 *    The group codec is 'opus1' while every rider in the room can receive Opus, else 'pcm16' (an old build or a
 *    phone without the decoder is there). Every change is announced with VOICE_CODEC. An Opus START while the
 *    group needs PCM is refused with VOICE_CODEC { codec: 'pcm16', refused: true } (the app restarts in PCM);
 *    Opus frames are never sent to a socket that cannot decode them. No transcoding (CPU stays off this node).
 *  - Opus frames to Opus-capable sockets carry a compact header { streamId, from, seq, codec }.
 *  - Caps per speaker: frames per second (VOICE_MAX_FPS), bytes per second (VOICE_MAX_BYTES_PER_SEC), frame size
 *    (VOICE_MAX_FRAME_BYTES); talk-time fairness: a rider who has held the group floor for VOICE_FAIR_HOLD_MS
 *    yields it to the next rider who presses talk (the Lead / sweeper are exempt).
 *  - Metrics in hub.stats (coroute_ws_events_total{kind="voice..."} on /metrics): voiceBytesIn, voiceBytesOut,
 *    voiceFramesIn, voiceFramesOut, voiceDropped (backpressure), voiceCapped (rate / size caps), voiceCodecRefused,
 *    voiceCodecSkipped, voiceFairShare, voiceStreams, voiceSpeakers (gauge: live streams now).
 *  - VOICE_RELAY_MODE=process: a separate voice process (src/voice_relay_server.js, forked here) serves the
 *    WebSocket path /voice on VOICE_RELAY_PORT (Caddy: deploy/caddy/voice_relay.caddy). Apps that announced caps
 *    get a short-lived ticket in VOICE_CODEC.voice and send / receive voice there; the floor, the membership and
 *    every policy check stay here (this process is the authority, over IPC), so the voice bytes of new apps never
 *    touch this process unless an old build in the group still listens on /ws. Old builds keep using /ws.
 *    Default 'inprocess': everything on /ws as before.
 *
 * Voice rules do not change: never recorded (only a session log line: who, when, how long), group-only.
 */
const crypto = require('crypto');
const path = require('path');
const { WebSocket, WebSocketServer } = require('ws');
const config = require('./config');
const { firstOff, FEATURE_OFF, FEATURE_OFF_MESSAGE } = require('./feature_flags');

const VOICE_START = 0x01, VOICE_FRAME = 0x02, VOICE_END = 0x03;

const envInt = (k, d) => { const n = parseInt(process.env[k] || '', 10); return Number.isFinite(n) && n >= 0 ? n : d; };
/** Frames per second a single stream may relay (20 ms frames are 50/s; the app sends 40 ms frames, 25/s). */
const VOICE_MAX_FPS = envInt('VOICE_MAX_FPS', 100);
/** Bytes per second a single speaker may relay (PCM16 at 16 kHz is 32 000 B/s; Opus ~3 000 B/s). */
const VOICE_MAX_BPS = envInt('VOICE_MAX_BYTES_PER_SEC', 48000);
/** A socket with more unsent bytes than this gets no voice frame (dropped, never queued). Kept well under the
 * WS_OUT_SOFT_BYTES queueing threshold so safety messages are never queued behind audio. */
const VOICE_DROP_BYTES = envInt('VOICE_DROP_BYTES', 16384);
/** Group floor held this long yields to the next rider who presses talk (0 = off). */
const VOICE_FAIR_HOLD_MS = envInt('VOICE_FAIR_HOLD_MS', 20000);
/** A socket that has not announced VOICE_CAPS within this time after it was first seen counts as an old build. */
const VOICE_CAPS_GRACE_MS = envInt('VOICE_CAPS_GRACE_MS', 3000);
/** 'inprocess' (default) or 'process' (separate voice process on VOICE_RELAY_PORT, path /voice). */
const VOICE_RELAY_MODE = String(process.env.VOICE_RELAY_MODE || 'inprocess').toLowerCase() === 'process' ? 'process' : 'inprocess';
/** Port of the voice process (process mode). 0 = any free port (tests). */
const VOICE_RELAY_PORT = envInt('VOICE_RELAY_PORT', 3010);
/** Public path of the voice process WebSocket (Caddy routes it to VOICE_RELAY_PORT). */
const VOICE_PATH = '/voice';
const VOICE_TICKET_TTL_MS = 10 * 60000;

/** Intercom sample rates: 16 kHz, and 8 kHz from phones in data saver mode. */
const VOICE_RATES = new Set([8000, 16000]);
const CODECS = new Set(['pcm16', 'opus1']);
const OPUS = 'opus1', PCM = 'pcm16';
/** HELLO feature of a gateway with this relay (apps then send VOICE_CAPS). */
const VOICE_FEATURE = 'voice2';

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
  if (!header || typeof header !== 'object') return null;
  return { kind, header, payload: buf.subarray(3 + hl) };
}

// ------------------------------------------------------------------ tickets (process mode)
function ticketKey(secret) { return crypto.createHmac('sha256', String(secret || '')).update('coroute-voice-ticket-v1').digest(); }
const b64u = (b) => Buffer.from(b).toString('base64url');

/** A short-lived ticket that lets one rider open /voice for one room. */
function signTicket(secret, { userId, groupId, name }, now = Date.now()) {
  const body = b64u(JSON.stringify({ u: userId, g: groupId, n: String(name || '').slice(0, 80), e: now + VOICE_TICKET_TTL_MS }));
  return `${body}.${b64u(crypto.createHmac('sha256', ticketKey(secret)).update(body).digest())}`;
}

function verifyTicket(secret, ticket, now = Date.now()) {
  if (typeof ticket !== 'string' || ticket.length > 1024) return null;
  const i = ticket.indexOf('.');
  if (i <= 0) return null;
  const body = ticket.slice(0, i);
  const want = crypto.createHmac('sha256', ticketKey(secret)).update(body).digest();
  let got;
  try { got = Buffer.from(ticket.slice(i + 1), 'base64url'); } catch { return null; }
  if (got.length !== want.length || !crypto.timingSafeEqual(got, want)) return null;
  let j;
  try { j = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')); } catch { return null; }
  if (!j || typeof j.u !== 'string' || typeof j.g !== 'string' || !(j.e > now)) return null;
  return { userId: j.u, groupId: j.g, name: j.n || 'Rider', exp: j.e };
}

const isOpen = (c) => c && c.readyState === WebSocket.OPEN;
const STAT_KEYS = ['voiceBytesIn', 'voiceBytesOut', 'voiceFramesIn', 'voiceFramesOut', 'voiceDropped', 'voiceCapped',
  'voiceCodecRefused', 'voiceCodecSkipped', 'voiceFairShare', 'voiceStreams', 'voiceSpeakers'];

/**
 * The relay authority, owned by the Hub (one per gateway process). `hub` gives rooms (gid -> Set<ws>), convoys,
 * stats, send / sendError / roomSend, repo, mirror; `hub.voice` holds the per-room floor state
 * ({ group, private: Map<from, stream>, remote, remotePrivate }) so ws.js keeps dropping it with the room.
 */
class VoiceRelay {
  constructor(hub, { mode = VOICE_RELAY_MODE, port = VOICE_RELAY_PORT, logger = null } = {}) {
    this.hub = hub;
    this.log = logger || hub.log || console;
    this.mode = mode;
    this.port = port;
    this.state = hub.voice || (hub.voice = new Map());
    this.codecOf = new Map(); // gid -> last announced group codec
    this.attached = new Map(); // `${gid}|${uid}` -> Set<cid> (process mode: users with a /voice socket)
    this.edgeStreams = new Map(); // streamId -> stream (speakers on /voice)
    this.edge = null; // process mode: { send(msg), ready, port }
    this.speakers = 0;
    // hub.stats is (re)built by the hub after this constructor: the counters are added on first use / next tick.
    setImmediate(() => this.stats);
    // Process mode: forked once the hub's WebSocketServer exists (the hub builds it after this constructor runs).
    if (mode === 'process') setImmediate(() => this._startEdgeProcess());
  }

  get secret() { return config.jwtSecret; }

  /** hub.stats with the voice counters present (exported as coroute_ws_events_total{kind=...} on /metrics). */
  get stats() {
    const s = this.hub.stats || (this.hub.stats = {});
    if (s.voiceBytesIn === undefined) for (const k of STAT_KEYS) if (s[k] === undefined) s[k] = 0;
    return s;
  }

  voiceState(gid) {
    if (!this.state.has(gid)) this.state.set(gid, { group: null, private: new Map() });
    return this.state.get(gid);
  }

  /** Room sockets that take part in voice (bound, account allowed, not a revoked session). */
  _members(gid) {
    const set = this.hub.rooms.get(gid);
    return set ? [...set].filter((c) => isOpen(c) && !c.safetyOnly && c.user) : [];
  }

  // ------------------------------------------------------------------ codec negotiation
  static opusCapable(ws) { return !!((ws.voiceCaps && ws.voiceCaps.has(OPUS)) || (ws.caps && ws.caps.has(OPUS))); }

  /** Old build (never announced caps within the grace time) or a phone without the Opus decoder. */
  _pcmOnly(ws, now) {
    if (VoiceRelay.opusCapable(ws)) return false;
    if (ws.voiceCaps) return true; // announced, without opus1
    if (!ws.voiceSeenAt) ws.voiceSeenAt = now;
    return now - ws.voiceSeenAt >= VOICE_CAPS_GRACE_MS;
  }

  groupCodec(gid, now = Date.now()) {
    for (const c of this._members(gid)) if (this._pcmOnly(c, now)) return PCM;
    return OPUS;
  }

  /** Recomputes the group codec; announces a change to the sockets that understand VOICE_CODEC. */
  refreshCodec(gid, now = Date.now()) {
    const codec = this.groupCodec(gid, now);
    const prev = this.codecOf.get(gid);
    if (prev === codec) return codec;
    this.codecOf.set(gid, codec);
    if (prev !== undefined) {
      for (const c of this._members(gid)) if (c.voiceCaps) this.hub.send(c, this._codecMsg(gid, c, codec));
    }
    return codec;
  }

  _codecMsg(gid, ws, codec, extra = {}) {
    const m = { type: 'VOICE_CODEC', groupId: gid, codec, reason: codec === OPUS ? 'all_opus' : 'old_listener', ts: Date.now(), ...extra };
    if (this.edge && this.edge.ready && ws.user) {
      m.voice = { path: VOICE_PATH, ticket: signTicket(this.secret, { userId: ws.user.userId, groupId: gid, name: ws.user.name }), ttlMs: VOICE_TICKET_TTL_MS };
    }
    return m;
  }

  /** VOICE_CAPS { codecs: [...] } from an app (JSON). Answers with VOICE_CODEC for its room. */
  onCaps(ws, msg) {
    // At most 10 per socket per minute (sent once per JOIN; a loop must not make the room recompute).
    const t = Date.now();
    if (!ws.voiceCapsAt || t - ws.voiceCapsAt > 60000) { ws.voiceCapsAt = t; ws.voiceCapsN = 0; }
    if (++ws.voiceCapsN > 10) return;
    const list = Array.isArray(msg && msg.codecs) ? msg.codecs.slice(0, 4).filter((c) => typeof c === 'string' && CODECS.has(c)) : [];
    ws.voiceCaps = new Set(list.length ? list : [PCM]);
    const gid = ws.groupId;
    if (!gid || ws.safetyOnly) return;
    const prev = this.codecOf.get(gid);
    const codec = this.refreshCodec(gid);
    // Unchanged (or first answer): only this app is told; a change was just announced to every app.
    if (prev === undefined || prev === codec) this.hub.send(ws, this._codecMsg(gid, ws, codec));
  }

  /** A socket left a room (ws.js _unbind / close / safety-only): end its stream, re-check the codec afterwards. */
  endStreamsOf(ws) {
    const gid = ws.groupId;
    if (ws.voiceStream && gid) this.endStream(gid, ws.voiceStream, 'disconnect');
    if (gid) {
      setImmediate(() => {
        if (!this.hub.rooms.get(gid)) { this.codecOf.delete(gid); return; }
        this.refreshCodec(gid);
        this._revokeEdgeIfGone(gid, ws.user && ws.user.userId);
      });
    }
  }

  // ------------------------------------------------------------------ inbound
  /** A binary voice frame from a /ws socket. */
  onBinary(ws, data) {
    const gid = ws.groupId;
    if (!gid) return; // not in a room: drop silently
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
    this.stats.voiceBytesIn += buf.length;
    if (buf.length > config.voiceMaxFrameBytes + 2100) { this.stats.voiceCapped++; return; }
    const pkt = decodeVoice(buf);
    if (!pkt) return;
    const spk = { ws, cid: null, user: ws.user, userId: ws.user.userId, name: ws.user.name, role: ws.user.role, gid };
    if (pkt.kind === VOICE_START) return this._start(spk, pkt.header);
    const stream = ws.voiceStream;
    const to = pkt.header.to ? String(pkt.header.to) : null;
    if (!stream || (stream.to || null) !== to) return; // frame without a stream: drop
    if (pkt.kind === VOICE_FRAME) return this._frame(gid, stream, pkt.header, pkt.payload);
    if (pkt.kind === VOICE_END) this.endStream(gid, stream, 'end');
  }

  /** Errors and busy notices for a speaker go to its /ws socket (edge speakers: their /ws sockets in the room). */
  _reply(spk, obj, error = null) {
    const targets = spk.ws ? [spk.ws] : this._members(spk.gid).filter((c) => c.user.userId === spk.userId);
    for (const c of targets) {
      if (error) this.hub.sendError(c, error.code, error.message, error.reason);
      else this.hub.send(c, obj);
    }
    return null;
  }

  _start(spk, header) {
    const { gid } = spk;
    const t = Date.now();
    const state = this.voiceState(gid);
    const to = header.to ? String(header.to) : null;
    const C = this.hub.convoys;
    // Talk is a group feature: a solo ride (Community host) has no one to talk to.
    const room = C.rooms.get(gid);
    if (room && typeof C.isSoloRide === 'function' && C.isSoloRide(room)) {
      return this._reply(spk, null, { code: 403, message: 'Talk is for group rides. This is a solo ride.', reason: 'SOLO_RIDE' });
    }
    // 3.55: group talk switched off by the admin (only a new stream start is refused).
    if (firstOff(C.featureFlags, ['intercom'])) return this._reply(spk, null, { code: 403, message: FEATURE_OFF_MESSAGE, reason: FEATURE_OFF });
    // 3.56 access mode: group talk left out of a hybrid free-tier ride.
    if (typeof C.rideFeatureOff === 'function' && C.rideFeatureOff(gid, ['intercom'])) {
      return this._reply(spk, null, { code: 403, message: "This isn't included in this ride.", reason: 'GROUP_FEATURE_LOCKED' });
    }
    const codec = CODECS.has(header.codec) ? header.codec : PCM;
    // Round 8: an Opus START while the group needs PCM (an old build listens): refused, the app restarts in PCM.
    if (codec === OPUS && this.refreshCodec(gid, t) !== OPUS) {
      this.stats.voiceCodecRefused++;
      return this._reply(spk, { type: 'VOICE_CODEC', groupId: gid, codec: PCM, reason: 'old_listener', refused: true, ts: t });
    }
    const isLeader = this._isLeader(gid, spk.user);
    if (to) {
      // Target must be a current room member, and not yourself.
      const target = this._members(gid).find((c) => c.user.userId === to);
      if (!target || to === spk.userId) return this._reply(spk, null, { code: 404, message: 'Rider is not online in this convoy.' });
    } else {
      const cur = state.group;
      const mine = cur && (spk.ws ? cur.ws === spk.ws : cur.edgeCid === spk.cid);
      if (cur && !mine && t - cur.lastAt < config.voiceStreamIdleMs) {
        // Round 8 talk-time fairness: a long hold yields to the next rider who presses talk (not the Lead / sweeper).
        if (VOICE_FAIR_HOLD_MS > 0 && t - cur.startedAt >= VOICE_FAIR_HOLD_MS && !cur.leader) {
          this.stats.voiceFairShare++;
          this.endStream(gid, cur, 'fair-share');
        } else {
          return this._reply(spk, { type: 'VOICE_BUSY', speaker: cur.fromName, ts: t });
        }
      }
      // The floor held by a rider on the peer gateway (hand-back window) is busy too.
      const rem = state.remote;
      if (rem && t - rem.lastAt < config.voiceStreamIdleMs) return this._reply(spk, { type: 'VOICE_BUSY', speaker: rem.fromName, ts: t });
      state.remote = null;
      const cur2 = state.group;
      if (cur2 && !(spk.ws ? cur2.ws === spk.ws : cur2.edgeCid === spk.cid)) this.endStream(gid, cur2, 'preempted');
    }
    const channel = header.channel === 'LEAD_ONLY' ? 'LEAD_ONLY' : 'ALL';
    if (channel === 'LEAD_ONLY' && !isLeader) {
      return this._reply(spk, null, { code: 403, message: 'The lead channel is for the Trip owner, Lead and sweeper.' });
    }
    // A new START from the same speaker replaces its old stream.
    const old = spk.ws ? spk.ws.voiceStream : null;
    if (old && !old.ended) this.endStream(gid, old, 'replaced');
    const stream = {
      streamId: crypto.randomBytes(6).toString('hex'), gid, ws: spk.ws || null, edgeCid: spk.cid || null, from: spk.userId, fromName: spk.name, to,
      channel, leader: isLeader, startedAt: t, lastAt: t, frames: 0, codec,
      sampleRate: VOICE_RATES.has(Number(header.sampleRate)) ? Number(header.sampleRate) : 16000,
    };
    if (to) state.private.set(spk.userId, stream); else state.group = stream;
    if (spk.ws) spk.ws.voiceStream = stream; else this.edgeStreams.set(stream.streamId, stream);
    this.stats.voiceStreams++;
    this.speakers++;
    this.stats.voiceSpeakers = this.speakers;
    C.featureAnalytics?.record('voice', true);
    const hdr = { ...this._hdr(stream), channel: stream.channel, sampleRate: stream.sampleRate, codec: stream.codec };
    this.fanout(gid, stream, VOICE_START, hdr, null);
    if (this.hub.mirror) this.hub.mirror.voice(gid, VOICE_START, hdr, null);
    this.hub.roomSend(gid, { type: 'MIC_STATUS', userId: spk.userId, isSpeaking: true, channel: stream.channel, ts: t });
    return stream;
  }

  _frame(gid, stream, header, payload) {
    const t = Date.now();
    if (t - stream.startedAt > config.voiceMaxStreamMs) return this.endStream(gid, stream, 'max-duration');
    if (payload.length === 0 || payload.length > config.voiceMaxFrameBytes) { this.stats.voiceCapped++; return; }
    // Frame and byte budget per stream: a flooding client cannot multiply audio across the whole room.
    if (!stream.rateAt || t - stream.rateAt >= 1000) { stream.rateAt = t; stream.rateN = 0; stream.rateB = 0; }
    stream.rateN++; stream.rateB += payload.length;
    if (stream.rateN > VOICE_MAX_FPS || stream.rateB > VOICE_MAX_BPS) { this.stats.voiceCapped++; return; }
    stream.lastAt = t; stream.frames++;
    this.stats.voiceFramesIn++;
    const hdr = { ...this._hdr(stream), seq: header.seq | 0 };
    this.fanout(gid, stream, VOICE_FRAME, hdr, payload);
    if (this.hub.mirror) this.hub.mirror.voice(gid, VOICE_FRAME, hdr, payload);
  }

  _hdr(s) { return { streamId: s.streamId, from: s.from, fromName: s.fromName, to: s.to, channel: s.channel || 'ALL', ts: Date.now() }; }

  /** Trip owner / Lead (convoys.isLead), sweeper, or an admin account: may use the lead channel; fairness-exempt. */
  _isLeader(gid, user) {
    const C = this.hub.convoys;
    const room = C.rooms.get(gid);
    const rider = room && room.riders ? room.riders.get(user.userId) : null;
    const role = rider ? rider.role : user.role;
    const lead = room && typeof C.isLead === 'function' && C.isLead(room, user);
    return !!(lead || role === 'SWEEPER' || user.role === 'ADMIN' || user.role === 'MASTER_ADMIN');
  }

  /** May this listener hear the stream (1:1 target, lead channel)? (The speaker's own socket is skipped by callers.) */
  _hears(gid, stream, userId, accountRole, room) {
    if (stream.to && userId !== stream.to) return false; // 1:1: only the chosen rider hears it
    if (stream.channel === 'LEAD_ONLY') {
      const rider = room && room.riders ? room.riders.get(userId) : null;
      const role = rider ? rider.role : accountRole;
      return role === 'LEAD' || role === 'SWEEPER' || !!(room && room.meta && room.meta.createdByUserId === userId)
        || accountRole === 'ADMIN' || accountRole === 'MASTER_ADMIN';
    }
    return true;
  }

  /** Lowest priority: no voice while the socket has a queued backlog or VOICE_DROP_BYTES unsent. */
  static voiceMaySend(client) { return !client.outq && !(client.bufferedAmount > VOICE_DROP_BYTES); }

  /** Sends a voice packet to the room's /ws listeners (and, in process mode, hands /voice listeners to the edge). */
  fanout(gid, stream, kind, header, payload) {
    const set = this.hub.rooms.get(gid);
    const room = this.hub.convoys.rooms.get(gid);
    const t = Date.now();
    let full = null, compact = null;
    const edgeTargets = [];
    let needCodecCheck = false;
    if (set) {
      for (const client of set) {
        if (!client.user || client === stream.ws || !isOpen(client) || client.safetyOnly) continue;
        if (stream.edgeCid && client.user.userId === stream.from) continue; // a /voice speaker's own /ws socket
        if (!this._hears(gid, stream, client.user.userId, client.user.role, room)) continue;
        if (this.attached.size && this.attached.has(`${gid}|${client.user.userId}`)) {
          // This rider listens on /voice (process mode): the edge delivers it there.
          if (client.user.userId !== stream.from && !edgeTargets.includes(client.user.userId)
            && (stream.codec !== OPUS || VoiceRelay.opusCapable(client))) edgeTargets.push(client.user.userId);
          continue;
        }
        const opusOk = VoiceRelay.opusCapable(client);
        if (stream.codec === OPUS && !opusOk) {
          // Never Opus to a socket that cannot decode it; the group switches to PCM (VOICE_CODEC).
          this.stats.voiceCodecSkipped++;
          if (this._pcmOnly(client, t)) needCodecCheck = true;
          continue;
        }
        if (!VoiceRelay.voiceMaySend(client)) { this.stats.voiceDropped++; continue; } // slow link: drop audio
        let frame;
        if (kind === VOICE_FRAME && stream.codec === OPUS) {
          frame = compact || (compact = encodeVoice(kind, { streamId: header.streamId, from: header.from, seq: header.seq, codec: OPUS }, payload));
        } else {
          frame = full || (full = encodeVoice(kind, header, payload));
        }
        client.send(frame);
        this.stats.voiceBytesOut += frame.length;
        if (kind === VOICE_FRAME) this.stats.voiceFramesOut++;
      }
    }
    if (this.edge && edgeTargets.length && !stream.edgeCid) {
      this.edge.send({ t: 'deliver', gid, kind, header, payload: payload || null, targets: edgeTargets, codec: stream.codec, from: stream.from });
    }
    if (needCodecCheck) this.refreshCodec(gid, t);
  }

  endStream(gid, stream, reason) {
    const state = this.state.get(gid);
    if (state) {
      if (state.group === stream) state.group = null;
      if (state.private.get(stream.from) === stream) state.private.delete(stream.from);
    }
    if (stream.ended) return;
    stream.ended = true;
    if (stream.ws && stream.ws.voiceStream === stream) stream.ws.voiceStream = null;
    if (stream.edgeCid) {
      this.edgeStreams.delete(stream.streamId);
      if (this.edge && reason !== 'end' && reason !== 'disconnect') this.edge.send({ t: 'stop', streamId: stream.streamId, reason });
    }
    this.speakers = Math.max(0, this.speakers - 1);
    this.stats.voiceSpeakers = this.speakers;
    const hdr = { ...this._hdr(stream), reason };
    this.fanout(gid, stream, VOICE_END, hdr, null);
    if (this.hub.mirror) this.hub.mirror.voice(gid, VOICE_END, hdr, null);
    this.hub.roomSend(gid, { type: 'MIC_STATUS', userId: stream.from, isSpeaking: false, ts: Date.now() });
    const durationMs = Date.now() - stream.startedAt;
    if (stream.frames > 0 && this.hub.repo && typeof this.hub.repo.logVoiceSession === 'function') {
      this.hub.repo.logVoiceSession({ groupId: gid, from: stream.from, to: stream.to, startedAt: stream.startedAt, durationMs, frames: stream.frames, reason });
    }
  }

  /**
   * Voice from a rider on the peer gateway (hand-back window), relayed to this node's sockets of the room.
   * The group floor: a remote START while a local group stream is live goes to the room authority
   * (`peerHasFloorAuthority`: the peer is the GATEWAY_ROLE=live node): the local stream is preempted, or
   * the remote one is ignored here (the peer preempts it when our START reaches it).
   */
  applyRemote(gid, kind, header, payload, { peerHasFloorAuthority = false } = {}) {
    if (!header || typeof header.streamId !== 'string') return;
    const state = this.voiceState(gid);
    const rp = state.remotePrivate || (state.remotePrivate = new Map());
    const t = Date.now();
    const pseudo = { ws: null, from: header.from, to: header.to || null, channel: header.channel === 'LEAD_ONLY' ? 'LEAD_ONLY' : 'ALL', codec: CODECS.has(header.codec) ? header.codec : PCM };
    if (kind === VOICE_START) {
      if (!header.to) {
        const cur = state.group;
        if (cur && t - cur.lastAt < config.voiceStreamIdleMs) {
          if (!peerHasFloorAuthority) return;
          this.endStream(gid, cur, 'preempted');
        }
        state.remote = { streamId: header.streamId, from: header.from, fromName: header.fromName, lastAt: t, codec: pseudo.codec };
      } else {
        rp.set(header.streamId, { lastAt: t, codec: pseudo.codec });
      }
      this.fanout(gid, pseudo, kind, header, null);
      return;
    }
    const known = (state.remote && state.remote.streamId === header.streamId) ? state.remote : rp.get(header.streamId);
    if (!known) return;
    known.lastAt = t;
    pseudo.codec = known.codec || PCM;
    if (kind === VOICE_END) {
      if (state.remote === known) state.remote = null; else rp.delete(header.streamId);
    }
    this.fanout(gid, pseudo, kind, header, kind === VOICE_FRAME ? payload : null);
  }

  /** The group floor of a room for the mirror snapshot, or null. */
  floorOf(gid) {
    const st = this.state.get(gid);
    const g = st && st.group;
    return g ? { streamId: g.streamId, from: g.from, fromName: g.fromName } : null;
  }

  metrics() {
    const s = this.stats;
    return {
      mode: this.mode, edgeReady: !!(this.edge && this.edge.ready), speakers: this.speakers, attached: this.attached.size,
      bytesIn: s.voiceBytesIn, bytesOut: s.voiceBytesOut, framesIn: s.voiceFramesIn, framesOut: s.voiceFramesOut,
      dropped: s.voiceDropped, capped: s.voiceCapped, codecRefused: s.voiceCodecRefused, codecSkipped: s.voiceCodecSkipped,
      fairShare: s.voiceFairShare, streams: s.voiceStreams,
    };
  }

  // ------------------------------------------------------------------ process mode: the /voice edge
  _startEdgeProcess() {
    const { fork } = require('child_process');
    let backoff = 1000;
    const spawn = () => {
      if (this.closed) return;
      let child;
      try {
        child = fork(path.join(__dirname, 'voice_relay_server.js'), [], {
          serialization: 'advanced',
          env: { ...process.env, VOICE_RELAY_CHILD: '1', VOICE_RELAY_PORT: String(this.port) },
          stdio: ['ignore', 'inherit', 'inherit', 'ipc'],
        });
      } catch (e) {
        this.log.warn && this.log.warn(`voice relay process did not start: ${e.message}`);
        return;
      }
      const edge = { ready: false, port: null, child, send: (m) => { try { if (child.connected) child.send(m); } catch { /* restarting */ } } };
      this.edge = edge;
      child.on('message', (m) => { try { this._onEdge(edge, m); } catch (e) { this.log.warn && this.log.warn(`voice edge message: ${e.message}`); } });
      child.on('exit', () => {
        if (this.edge === edge) this.edge = null;
        // Everything the edge held is gone: free the floors, apps fall back to /ws.
        for (const s of [...this.edgeStreams.values()]) this.endStream(this._gidOf(s), s, 'disconnect');
        this.attached.clear();
        if (!this.closed) { const d = backoff; backoff = Math.min(backoff * 2, 30000); setTimeout(spawn, d).unref(); }
      });
    };
    spawn();
    // The hub's WebSocketServer closing (gateway shutdown) stops the voice process.
    if (this.hub.wss && typeof this.hub.wss.on === 'function') this.hub.wss.on('close', () => this.close());
  }

  close() {
    this.closed = true;
    const e = this.edge;
    this.edge = null;
    if (e && e.child) { try { e.child.kill(); } catch { /* gone */ } }
  }

  _gidOf(stream) { return stream.gid || ''; }

  _revokeEdgeIfGone(gid, uid) {
    if (!uid || !this.edge) return;
    const key = `${gid}|${uid}`;
    if (!this.attached.has(key)) return;
    if (this._members(gid).some((c) => c.user.userId === uid)) return;
    this.attached.delete(key);
    this.edge.send({ t: 'kick', gid, uid });
  }

  /** IPC from the voice process. */
  _onEdge(edge, m) {
    if (!m || typeof m !== 'object') return;
    switch (m.t) {
      case 'ready':
        edge.ready = true; edge.port = m.port;
        this.log.info && this.log.info(`voice relay process ready on port ${m.port}`);
        return;
      case 'attach': {
        const ok = typeof m.uid === 'string' && typeof m.gid === 'string' && this._members(m.gid).some((c) => c.user.userId === m.uid);
        if (ok) {
          const key = `${m.gid}|${m.uid}`;
          if (!this.attached.has(key)) this.attached.set(key, new Set());
          this.attached.get(key).add(m.cid);
        }
        edge.send({ t: 'attached', cid: m.cid, ok });
        return;
      }
      case 'detach': {
        const key = `${m.gid}|${m.uid}`;
        const set = this.attached.get(key);
        if (set) { set.delete(m.cid); if (!set.size) this.attached.delete(key); }
        for (const s of [...this.edgeStreams.values()]) if (s.edgeCid === m.cid) this.endStream(s.gid, s, 'disconnect');
        return;
      }
      case 'start': {
        const member = this._members(m.gid).find((c) => c.user.userId === m.uid);
        if (!member || !this.attached.has(`${m.gid}|${m.uid}`)) { edge.send({ t: 'startErr', cid: m.cid, req: m.req }); return; }
        const spk = { ws: null, cid: m.cid, user: member.user, userId: m.uid, name: member.user.name, role: member.user.role, gid: m.gid };
        const s = this._start(spk, m.header || {});
        if (!s) { edge.send({ t: 'startErr', cid: m.cid, req: m.req }); return; }
        // Which /voice listeners may hear it, and are there /ws listeners left (old builds) that need the frames here?
        const room = this.hub.convoys.rooms.get(m.gid);
        const targets = []; let legacy = false;
        for (const c of this._members(m.gid)) {
          if (c.user.userId === m.uid || !this._hears(m.gid, s, c.user.userId, c.user.role, room)) continue;
          if (this.attached.has(`${m.gid}|${c.user.userId}`)) { if (!targets.includes(c.user.userId)) targets.push(c.user.userId); } else legacy = true;
        }
        const mirror = !!this.hub.mirror;
        const hdr = { ...this._hdr(s), channel: s.channel, sampleRate: s.sampleRate, codec: s.codec };
        edge.send({ t: 'startOk', cid: m.cid, req: m.req, streamId: s.streamId, hdr, targets, wantFrames: legacy || mirror });
        return;
      }
      case 'frame': {
        const s = this.edgeStreams.get(m.streamId);
        if (!s) return;
        const payload = Buffer.isBuffer(m.payload) ? m.payload : Buffer.from(m.payload || []);
        this._frame(s.gid, s, { seq: m.seq }, payload);
        return;
      }
      case 'alive': {
        const s = this.edgeStreams.get(m.streamId);
        if (s) { s.lastAt = Date.now(); s.frames = Math.max(s.frames, m.frames | 0); }
        return;
      }
      case 'end': {
        const s = this.edgeStreams.get(m.streamId);
        if (s) this.endStream(s.gid, s, m.reason === 'disconnect' ? 'disconnect' : 'end');
        return;
      }
      case 'metrics':
        for (const k of ['voiceBytesIn', 'voiceBytesOut', 'voiceFramesIn', 'voiceFramesOut', 'voiceDropped', 'voiceCapped']) {
          if (typeof m[k] === 'number') this.stats[k] += m[k];
        }
        return;
      default:
    }
  }
}

/**
 * The /voice WebSocket edge (process mode, inside src/voice_relay_server.js; also usable in-process in tests).
 * Holds the voice sockets of apps with a ticket and relays between them; asks the authority (`link`) for every
 * floor decision; forwards frames to the authority only when old builds on /ws must hear them.
 */
class VoiceEdge {
  constructor({ server, link, secret, logger = console, path: p = VOICE_PATH }) {
    this.link = link; this.secret = secret; this.log = logger;
    this.socks = new Map(); // cid -> ws
    this.byRoom = new Map(); // gid -> Set<ws>
    this.streams = new Map(); // streamId -> { ws, gid, targets:Set, wantFrames, codec, hdr, frames, rateAt, rateN, rateB, aliveAt }
    this.nextCid = 1; this.nextReq = 1;
    this.delta = { voiceBytesIn: 0, voiceBytesOut: 0, voiceFramesIn: 0, voiceFramesOut: 0, voiceDropped: 0, voiceCapped: 0 };
    this.wss = new WebSocketServer({ server, path: p, maxPayload: 64 * 1024,
      handleProtocols: (protocols) => { for (const x of protocols) if (x === 'coroute.voice.v1') return x; return false; } });
    this.wss.on('connection', (ws, req) => this._onConnection(ws, req));
    this.metricsTimer = setInterval(() => this._flushMetrics(), 5000);
    this.metricsTimer.unref();
    this.heartbeat = setInterval(() => {
      for (const ws of this.socks.values()) { if (ws.isAlive === false) { ws.terminate(); continue; } ws.isAlive = false; try { ws.ping(); } catch { /* closing */ } }
    }, 30000);
    this.heartbeat.unref();
  }

  close() { clearInterval(this.metricsTimer); clearInterval(this.heartbeat); this.wss.close(); }

  _flushMetrics() {
    const d = this.delta;
    if (!Object.values(d).some((v) => v)) return;
    this.link.send({ t: 'metrics', ...d });
    for (const k of Object.keys(d)) d[k] = 0;
  }

  _onConnection(ws, req) {
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('error', () => { /* close runs */ });
    // The ticket: Sec-WebSocket-Protocol "coroute.voice.v1, coroute.voice.t.<ticket>", or a first JSON AUTH message.
    const offered = String(req.headers['sec-websocket-protocol'] || '').split(',').map((s) => s.trim());
    const tp = offered.find((s) => s.startsWith('coroute.voice.t.'));
    const auth = (ticket) => {
      const v = verifyTicket(this.secret, ticket);
      if (!v) { try { ws.close(4401, 'BAD_TICKET'); } catch { /* gone */ } return; }
      ws.uid = v.userId; ws.gid = v.groupId; ws.name = v.name; ws.cid = this.nextCid++;
      ws.pendingAttach = true;
      this.socks.set(ws.cid, ws);
      this.link.send({ t: 'attach', cid: ws.cid, uid: ws.uid, gid: ws.gid });
    };
    if (tp) auth(tp.slice('coroute.voice.t.'.length));
    else {
      const timer = setTimeout(() => { if (!ws.cid) { try { ws.close(4401, 'AUTH_TIMEOUT'); } catch { /* gone */ } } }, 5000);
      timer.unref();
      ws.once('message', (data, isBinary) => {
        clearTimeout(timer);
        if (ws.cid) return;
        let m = null;
        if (!isBinary) { try { m = JSON.parse(data.toString()); } catch { m = null; } }
        if (!m || m.type !== 'AUTH') { try { ws.close(4401, 'Unauthorized'); } catch { /* gone */ } return; }
        auth(m.ticket);
      });
    }
    ws.on('message', (data, isBinary) => { if (isBinary && ws.attached) this._onBinary(ws, Buffer.isBuffer(data) ? data : Buffer.from(data)); });
    ws.on('close', () => this._onClose(ws));
  }

  _onClose(ws) {
    if (!ws.cid) return;
    this.socks.delete(ws.cid);
    const set = this.byRoom.get(ws.gid);
    if (set) { set.delete(ws); if (!set.size) this.byRoom.delete(ws.gid); }
    if (ws.stream) this._endLocal(ws.stream, 'disconnect', true);
    if (ws.attached) this.link.send({ t: 'detach', cid: ws.cid, uid: ws.uid, gid: ws.gid });
  }

  /** IPC from the authority. */
  onLink(m) {
    if (!m || typeof m !== 'object') return;
    switch (m.t) {
      case 'attached': {
        const ws = this.socks.get(m.cid);
        if (!ws) return;
        ws.pendingAttach = false;
        if (!m.ok) { try { ws.close(4403, 'NOT_IN_RIDE'); } catch { /* gone */ } return; }
        ws.attached = true;
        if (!this.byRoom.has(ws.gid)) this.byRoom.set(ws.gid, new Set());
        this.byRoom.get(ws.gid).add(ws);
        try { ws.send(JSON.stringify({ type: 'VOICE_READY', groupId: ws.gid, ts: Date.now() })); } catch { /* closing */ }
        return;
      }
      case 'startOk': {
        const ws = this.socks.get(m.cid);
        if (!ws || !ws.pendingStart || ws.pendingStart.req !== m.req) return;
        const pend = ws.pendingStart;
        ws.pendingStart = null;
        const st = { streamId: m.streamId, ws, gid: ws.gid, to: pend.to, targets: new Set(m.targets || []), wantFrames: !!m.wantFrames, codec: m.hdr.codec, hdr: m.hdr, frames: 0, aliveAt: 0 };
        this.streams.set(m.streamId, st);
        ws.stream = st;
        this._send(st, VOICE_START, m.hdr, null);
        for (const f of pend.frames) this._frame(st, f.header, f.payload);
        if (pend.ended) this._endLocal(st, 'end', true);
        return;
      }
      case 'startErr': {
        const ws = this.socks.get(m.cid);
        if (ws && ws.pendingStart && ws.pendingStart.req === m.req) ws.pendingStart = null;
        return;
      }
      case 'deliver': {
        const set = this.byRoom.get(m.gid);
        if (!set) return;
        const targets = new Set(m.targets || []);
        const payload = m.payload ? (Buffer.isBuffer(m.payload) ? m.payload : Buffer.from(m.payload)) : null;
        let frame = null;
        for (const ws of set) {
          if (!targets.has(ws.uid) || ws.uid === m.from || !isOpen(ws)) continue;
          if (!VoiceRelay.voiceMaySend(ws)) { this.delta.voiceDropped++; continue; }
          frame = frame || (m.kind === VOICE_FRAME && m.codec === OPUS
            ? encodeVoice(m.kind, { streamId: m.header.streamId, from: m.header.from, seq: m.header.seq, codec: OPUS }, payload)
            : encodeVoice(m.kind, m.header, payload));
          ws.send(frame);
          this.delta.voiceBytesOut += frame.length;
          if (m.kind === VOICE_FRAME) this.delta.voiceFramesOut++;
        }
        return;
      }
      case 'stop': {
        const st = this.streams.get(m.streamId);
        if (st) this._endLocal(st, m.reason || 'preempted', false);
        return;
      }
      case 'kick': {
        for (const ws of [...this.socks.values()]) if (ws.uid === m.uid && ws.gid === m.gid) { try { ws.close(4403, 'LEFT_RIDE'); } catch { /* gone */ } }
        return;
      }
      default:
    }
  }

  _onBinary(ws, buf) {
    this.delta.voiceBytesIn += buf.length;
    if (buf.length > config.voiceMaxFrameBytes + 2100) { this.delta.voiceCapped++; return; }
    const pkt = decodeVoice(buf);
    if (!pkt) return;
    const to = pkt.header.to ? String(pkt.header.to) : null;
    if (pkt.kind === VOICE_START) {
      if (ws.stream) this._endLocal(ws.stream, 'replaced', true);
      const req = this.nextReq++;
      ws.pendingStart = { req, to, frames: [], ended: false };
      this.link.send({ t: 'start', cid: ws.cid, req, uid: ws.uid, gid: ws.gid, header: pkt.header });
      return;
    }
    if (ws.pendingStart && (ws.pendingStart.to || null) === to) {
      if (pkt.kind === VOICE_FRAME && ws.pendingStart.frames.length < 10) ws.pendingStart.frames.push({ header: pkt.header, payload: Buffer.from(pkt.payload) });
      if (pkt.kind === VOICE_END) ws.pendingStart.ended = true;
      return;
    }
    const st = ws.stream;
    if (!st || (st.to || null) !== to) return;
    if (pkt.kind === VOICE_FRAME) return this._frame(st, pkt.header, pkt.payload);
    if (pkt.kind === VOICE_END) this._endLocal(st, 'end', true);
  }

  _frame(st, header, payload) {
    const t = Date.now();
    if (payload.length === 0 || payload.length > config.voiceMaxFrameBytes) { this.delta.voiceCapped++; return; }
    if (!st.rateAt || t - st.rateAt >= 1000) { st.rateAt = t; st.rateN = 0; st.rateB = 0; }
    st.rateN++; st.rateB += payload.length;
    if (st.rateN > VOICE_MAX_FPS || st.rateB > VOICE_MAX_BPS) { this.delta.voiceCapped++; return; }
    st.frames++;
    this.delta.voiceFramesIn++;
    const seq = header.seq | 0;
    this._send(st, VOICE_FRAME, { ...st.hdr, seq, ts: t }, payload);
    if (st.wantFrames) this.link.send({ t: 'frame', streamId: st.streamId, seq, payload: Buffer.from(payload) });
    else if (t - st.aliveAt >= 500) { st.aliveAt = t; this.link.send({ t: 'alive', streamId: st.streamId, frames: st.frames }); }
  }

  _send(st, kind, header, payload) {
    const set = this.byRoom.get(st.gid);
    if (!set) return;
    let frame = null;
    for (const ws of set) {
      if (ws === st.ws || !st.targets.has(ws.uid) || !isOpen(ws)) continue;
      if (!VoiceRelay.voiceMaySend(ws)) { this.delta.voiceDropped++; continue; }
      frame = frame || (kind === VOICE_FRAME && st.codec === OPUS
        ? encodeVoice(kind, { streamId: header.streamId, from: header.from, seq: header.seq, codec: OPUS }, payload)
        : encodeVoice(kind, header, payload));
      ws.send(frame);
      this.delta.voiceBytesOut += frame.length;
      if (kind === VOICE_FRAME) this.delta.voiceFramesOut++;
    }
  }

  /** Ends a stream here; `tellAuthority` when the speaker ended it (the authority already knows otherwise). */
  _endLocal(st, reason, tellAuthority) {
    if (!this.streams.has(st.streamId)) return;
    this.streams.delete(st.streamId);
    if (st.ws.stream === st) st.ws.stream = null;
    this._send(st, VOICE_END, { ...st.hdr, reason, ts: Date.now() }, null);
    if (tellAuthority) this.link.send({ t: 'end', streamId: st.streamId, reason });
  }
}

module.exports = {
  VoiceRelay, VoiceEdge, encodeVoice, decodeVoice, signTicket, verifyTicket,
  VOICE_START, VOICE_FRAME, VOICE_END, VOICE_FEATURE, VOICE_PATH, VOICE_RELAY_MODE, VOICE_DROP_BYTES,
};
