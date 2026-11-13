'use strict';
/**
 * Round 10 offline link: the gateway side of the phone-to-phone mesh (docs/features_355/offline_long_range_link.md).
 *
 * Riders without signal form a Bluetooth LE (Coded PHY) mesh. Any rider of the same ride whose phone still has a
 * healthy socket is a BRIDGE: it forwards the sealed mesh frames it hears, and the room's traffic goes back into the
 * mesh from its phone. Three socket messages, all scoped to the rider's room (no HTTP route):
 *
 *   MESH_HELLO  {caps}            phone -> gateway after every JOIN. Answered with MESH_KEY (the ride's group key) and
 *                                 a room-wide MESH_CAPS {caps: {userId: bits}} ("4 of 6 phones support long range").
 *   MESH_KEY    {key, epoch}      gateway -> phone. key = HMAC-SHA256(MESH_KEY_SECRET, "coroute-mesh-v1|groupId|epoch"),
 *                                 32 bytes, base64. MESH_KEY_SECRET defaults to a key derived from JWT_SECRET. The
 *                                 epoch is the ride's creation time: a new ride of the same group gets a new key.
 *   MESH_BRIDGE {f: [base64]}     bridge phone -> gateway: up to MAX_FRAMES sealed frames heard over the mesh. Every
 *                                 frame is opened with the ride key (AES-256-GCM, same layout as
 *                                 lib/domain/mesh/mesh_frame.dart), checked for freshness and replay, mapped to a rider
 *                                 of this room by its short id (FNV-1a 32 of the user id), then:
 *                                   position  the rider's live position (via-bridge flag, presence ONLINE) unless the
 *                                             rider has a socket of its own in the room (direct wins: never doubled);
 *                                   SOS       stored exactly like an SOS from the rider's own socket (same clientId,
 *                                             so a copy arriving later directly or via another bridge is the same
 *                                             alert), emergency gateway dispatch included. A "resolved" SOS from the
 *                                             mesh is acknowledged but NEVER closes the alert (the ride key is shared:
 *                                             it cannot prove the rider sent it);
 *                                   others    ignored (voice, chat and chain alerts stay in the mesh).
 *                                 Answered with MESH_BRIDGE_ACK {acks: [{o, cid, alertId}]}: the bridge phone puts a
 *                                 "server has it" acknowledgement into the mesh so the SOS origin stops resending.
 *
 * Abuse limits: only sockets bound to the room; at most MAX_FRAMES frames of at most MAX_FRAME_BYTES per message;
 * non-SOS frames at most MESH_BRIDGE_PER_SEC per socket (SOS frames are never rate limited); the admin switch
 * 'offlineMesh' off -> SOS frames only (no switch may take an SOS path away). MESH_BRIDGE is a safety type in
 * src/ws_limits.js (never dropped by the generic limiter, because it can carry an SOS); this module does its own checks.
 * Metrics: hub.stats.meshFrames / meshSos / meshPos / meshRejected / meshDirectWins / meshReplay.
 */
const crypto = require('crypto');
const config = require('./config');

const MESH_CAP = 'mesh1';
const MAX_FRAMES = 48;
const MAX_FRAME_BYTES = 1200;
const VIA_BRIDGE_MS = 30000;
const CLASS = { SOS: 0, ALERT: 1, POSITION: 2, VOICE: 3, CHAT: 4, CONTROL: 5 };
/** Seconds a frame of each class may be old when it arrives (same as ReplayGuard.maxAgeSec in the app). */
const MAX_AGE_SEC = { 0: 6 * 3600, 1: 15 * 60, 2: 5 * 60, 3: 15 * 60, 4: 30 * 60, 5: 60 };
const SOS_TYPES = ['CRASH', 'BREAKDOWN', 'MEDICAL', 'STOPPED', 'CUSTOM', 'SOS'];
const SOS_SOURCES = new Set(['MANUAL', 'CRASH_AUTO', 'NEED_HELP', 'NOTIFICATION', 'WEARABLE']);

const num = (v, d) => { const n = Number(v); return v !== undefined && v !== '' && Number.isFinite(n) && n >= 0 ? n : d; };

/** FNV-1a 32 over the UTF-8 user id; 0 is never used (lib/domain/mesh/mesh_frame.dart meshShortId). */
function shortId(userId) {
  let h = 0x811c9dc5;
  for (const b of Buffer.from(String(userId), 'utf8')) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h === 0 ? 1 : h;
}

function meshSecret(env = process.env) {
  const s = String(env.MESH_KEY_SECRET || '').trim();
  if (s) return Buffer.from(s, 'utf8');
  return crypto.createHmac('sha256', String(config.jwtSecret)).update('coroute-mesh-key-secret-v1').digest();
}

/** The ride's 32-byte group key. */
function rideKey(secret, groupId, epoch) {
  return crypto.createHmac('sha256', secret).update(`coroute-mesh-v1|${groupId}|${epoch}`).digest();
}

function aesBlock(key, block16) {
  const c = crypto.createCipheriv(key.length === 32 ? 'aes-256-ecb' : 'aes-128-ecb', key, null);
  c.setAutoPadding(false);
  return Buffer.concat([c.update(block16), c.final()]);
}

/** 16-bit group tag (first two bytes of AES_k("CoRouteMeshTag01")): frames of other rides are skipped cheaply. */
function groupTag(key) {
  const t = aesBlock(key, Buffer.from('CoRouteMeshTag01', 'utf8'));
  return (t[0] << 8) | t[1];
}

const HEADER = 33;
const AAD = 22;
const TAG = 16;

/** Opens one sealed frame; null when it is not of this ride, malformed or fails authentication. */
function openFrame(key, tag, buf) {
  if (!Buffer.isBuffer(buf) || buf.length < HEADER + TAG + 1) return null;
  if (buf[0] !== 0xc5 || buf[1] !== 0x21 || ((buf[2] << 8) | buf[3]) !== tag) return null;
  const origin = buf.readUInt32BE(5), boot = buf.readUInt32BE(9), seq = buf.readUInt32BE(13);
  const nonce = Buffer.alloc(12);
  nonce.writeUInt32BE(origin, 0); nonce.writeUInt32BE(boot, 4); nonce.writeUInt32BE(seq, 8);
  const body = buf.subarray(HEADER);
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', key, nonce);
    d.setAAD(buf.subarray(0, AAD));
    d.setAuthTag(body.subarray(body.length - TAG));
    const payload = Buffer.concat([d.update(body.subarray(0, body.length - TAG)), d.final()]);
    if (!payload.length) return null;
    return {
      cls: buf[4] & 0x07, proxied: (buf[4] & 0x08) !== 0, origin, boot, seq,
      t: buf.readUInt32BE(17), initialTtl: Math.min(buf[21], 8), ttl: Math.min(buf[22], buf[21], 8), payload,
      id: `${origin.toString(16)}.${boot.toString(16)}.${seq}`,
    };
  } catch {
    return null;
  }
}

/** Reads a length-prefixed UTF-8 string. */
function str(b, o) {
  if (o.i >= b.length) { o.bad = true; return ''; }
  const n = b[o.i++];
  if (o.i + n > b.length) { o.bad = true; return ''; }
  const s = b.toString('utf8', o.i, o.i + n);
  o.i += n;
  return s;
}

/** MeshSos (lib/domain/mesh/mesh_messages.dart). */
function decodeSos(p) {
  if (p.length < 1 + 1 + 1 + 4 + 4 + 4 + 2 + 1 + 2 + 4 || p[0] !== 0x01) return null;
  const flags = p[1];
  const type = SOS_TYPES[Math.min(p[2], SOS_TYPES.length - 1)];
  const lat = p.readInt32BE(3) / 1e6, lng = p.readInt32BE(7) / 1e6;
  const occurredAt = p.readUInt32BE(11) * 1000;
  const acc = p.readUInt16BE(15), speed = p[17], heading = p.readUInt16BE(18);
  const o = { i: 20, bad: false };
  const source = str(p, o), clientId = str(p, o), linkToken = str(p, o), name = str(p, o);
  if (o.bad || !clientId) return null;
  return {
    alertType: type, lat, lng, occurredAt, auto: (flags & 1) !== 0, resolved: (flags & 2) !== 0,
    accuracyM: flags & 4 ? acc : undefined, speedKmh: flags & 8 ? speed : undefined, heading: flags & 16 ? heading : undefined,
    source, clientId, linkToken, name,
  };
}

/** MeshPos: pos2 scales (1e-5 degrees, dm/s, degrees). */
function decodePos(p) {
  if (p.length < 19 || p[0] !== 0x20) return null;
  const fu = p.readUInt16BE(15);
  return {
    lat: p.readInt32BE(1) / 1e5, lng: p.readInt32BE(5) / 1e5, speedKmh: Math.round(p.readUInt16BE(9) * 0.36 * 10) / 10,
    heading: p.readUInt16BE(11), batteryLevel: p[13] & 0x7f, isCharging: (p[13] & 0x80) !== 0,
    fuelUsableKm: fu === 0xffff ? null : fu, fixAgeSec: p.readUInt16BE(17),
  };
}

class MeshBridge {
  /** @param {import('./ws').Hub} hub */
  constructor(hub, { env = process.env, clock = Date.now } = {}) {
    this.hub = hub;
    this.clock = clock;
    this.secret = meshSecret(env);
    this.perSec = num(env.MESH_BRIDGE_PER_SEC, 40);
    this.caps = new Map(); // groupId -> Map<userId, { caps, at }>
    this.seen = new Map(); // groupId -> Map<frameId, origin time sec>
    this.bridged = new Map(); // groupId -> Map<userId, at> (riders whose presence the bridge set ONLINE)
    for (const k of ['meshFrames', 'meshSos', 'meshPos', 'meshRejected', 'meshDirectWins', 'meshReplay', 'meshHello']) hub.stats[k] = hub.stats[k] || 0;
    this.timer = setInterval(() => this.sweep(), 10000);
    if (this.timer.unref) this.timer.unref();
  }

  close() { clearInterval(this.timer); }

  _epoch(room) { return Number((room && room.meta && room.meta.createdAtEpochMs) || 0); }

  keyFor(groupId, room) {
    const epoch = this._epoch(room);
    const key = rideKey(this.secret, groupId, epoch);
    return { key, epoch, tag: groupTag(key) };
  }

  /** MESH_HELLO: remember the phone's capability bits, hand it the ride key, tell the room the new capability map. */
  async onHello(ws, msg) {
    const gid = this.hub._requireRoom(ws);
    const room = await this.hub.convoys.getRoom(gid);
    this.hub.stats.meshHello++;
    const caps = Number.isInteger(msg.caps) && msg.caps >= 0 && msg.caps <= 0xff ? msg.caps : 0;
    let m = this.caps.get(gid);
    if (!m) { m = new Map(); this.caps.set(gid, m); }
    const prev = m.get(ws.user.userId);
    m.set(ws.user.userId, { caps, at: this.clock() });
    const { key, epoch } = this.keyFor(gid, room);
    this.hub.send(ws, { type: 'MESH_KEY', groupId: gid, key: key.toString('base64'), epoch, ts: this.clock() });
    const all = {};
    for (const [uid, e] of m) if (room.riders.has(uid)) all[uid] = e.caps;
    if (!prev || prev.caps !== caps) this.hub.roomSend(gid, { type: 'MESH_CAPS', groupId: gid, caps: all, ts: this.clock() });
    else this.hub.send(ws, { type: 'MESH_CAPS', groupId: gid, caps: all, ts: this.clock() });
  }

  _hasDirectSocket(gid, userId, except) {
    const set = this.hub.rooms.get(gid);
    if (!set) return false;
    for (const c of set) if (c !== except && c.user && c.user.userId === userId && c.readyState === 1) return true;
    return false;
  }

  _fresh(gid, f) {
    const nowSec = Math.floor(this.clock() / 1000);
    if (f.t > nowSec + 300 || nowSec - f.t > (MAX_AGE_SEC[f.cls] || 60)) return false;
    let s = this.seen.get(gid);
    if (!s) { s = new Map(); this.seen.set(gid, s); }
    if (s.has(f.id)) return false;
    s.set(f.id, f.t);
    if (s.size > 20000) {
      for (const [k, t] of s) { if (nowSec - t > MAX_AGE_SEC[0] || s.size > 18000) s.delete(k); else break; }
    }
    return true;
  }

  /** MESH_BRIDGE from a bridge phone. */
  async onBridge(ws, msg) {
    const gid = this.hub._requireRoom(ws);
    const room = await this.hub.convoys.getRoom(gid);
    const list = Array.isArray(msg.f) ? msg.f.slice(0, MAX_FRAMES) : [];
    if (!list.length) return;
    const { key, tag } = this.keyFor(gid, room);
    const byShort = new Map();
    for (const uid of room.riders.keys()) byShort.set(shortId(uid), uid);
    const flags = this.hub.convoys.featureFlags;
    const meshOn = !flags || typeof flags.isOn !== 'function' || flags.isOn('offlineMesh');
    const t = this.clock();
    if (!ws.meshRate || t - ws.meshRate.at >= 1000) ws.meshRate = { at: t, n: 0 };
    const acks = [];
    let accepted = 0;
    for (const item of list) {
      if (typeof item !== 'string' || item.length > Math.ceil(MAX_FRAME_BYTES / 3) * 4) { this.hub.stats.meshRejected++; continue; }
      const f = openFrame(key, tag, Buffer.from(item, 'base64'));
      if (!f) { this.hub.stats.meshRejected++; continue; }
      const isSos = f.cls === CLASS.SOS;
      if (!isSos && (!meshOn || ++ws.meshRate.n > this.perSec)) continue;
      if (f.payload[0] === 0x02) continue; // SOS acknowledgements stay in the mesh
      const uid = byShort.get(f.origin);
      if (!uid || f.proxied || uid === ws.user.userId) { this.hub.stats.meshRejected++; continue; }
      if (!this._fresh(gid, f)) { this.hub.stats.meshReplay++; continue; }
      this.hub.stats.meshFrames++;
      accepted++;
      try {
        if (isSos && f.payload[0] === 0x01) {
          const ack = await this._sos(ws, gid, room, uid, f);
          if (ack) acks.push(ack);
        } else if (f.cls === CLASS.POSITION && f.payload[0] === 0x20) {
          this._position(ws, gid, room, uid, f);
        }
      } catch (e) {
        this.hub.log.warn('[mesh] bridged frame failed', e.message);
      }
    }
    this.hub.send(ws, { type: 'MESH_BRIDGE_ACK', groupId: gid, n: accepted, acks, ts: this.clock() });
  }

  _position(ws, gid, room, uid, f) {
    const p = decodePos(f.payload);
    if (!p) return;
    if (this._hasDirectSocket(gid, uid, ws)) { this.hub.stats.meshDirectWins++; return; }
    const fixAt = Math.min(this.clock(), (f.t - p.fixAgeSec) * 1000);
    if (this.clock() - fixAt > VIA_BRIDGE_MS) return; // too old to show as a live position
    const cur = room.riders.get(uid);
    // The server already has a newer fix (origin time is whole seconds: 1.5 s of slack).
    if (cur && (cur.lat || cur.lng) && Number(cur.lastSeenEpochMs || 0) > fixAt + 1500) return;
    const patch = { lat: p.lat, lng: p.lng, speedKmh: p.speedKmh, heading: p.heading, batteryLevel: p.batteryLevel, isCharging: p.isCharging, viaBridge: ws.user.userId };
    const rider = this.hub.convoys.patchRider(room, uid, patch, { emit: false, trusted: true });
    if (!rider) return;
    rider.lastSeenEpochMs = fixAt;
    this.hub.stats.meshPos++;
    let b = this.bridged.get(gid);
    if (!b) { b = new Map(); this.bridged.set(gid, b); }
    b.set(uid, this.clock());
    if (rider.presence !== 'ONLINE') this.hub.convoys.setPresence(gid, uid, 'ONLINE');
    this.hub._fanoutPosition(gid, ws, rider);
    if (this.hub.mirror) this.hub.mirror.position(gid, rider);
  }

  async _sos(ws, gid, room, uid, f) {
    const s = decodeSos(f.payload);
    if (!s) return null;
    this.hub.stats.meshSos++;
    const rider = room.riders.get(uid);
    const user = { userId: uid, name: (rider && rider.name) || s.name || 'Rider' };
    if (s.resolved) {
      // Never closed from the mesh: the group key is shared by every rider of the ride, so a bridged "resolved" cannot
      // prove it came from the rider. The SOS stays open until the rider's own socket (or the lead) closes it; the
      // phone's own "safe now" SMS is unchanged. Acknowledged so the mesh stops carrying it.
      this.hub.stats.meshResolveIgnored = (this.hub.stats.meshResolveIgnored || 0) + 1;
      return { o: f.origin, cid: s.clientId, alertId: '' };
    }
    const msg = {
      type: 'SOS', lat: s.lat, lng: s.lng, alertType: s.alertType, clientId: s.clientId, occurredAt: s.occurredAt,
      auto: s.auto, source: SOS_SOURCES.has(s.source) ? s.source : (s.auto ? 'CRASH_AUTO' : 'MANUAL'),
      ...(s.linkToken ? { smsLinkToken: s.linkToken } : {}),
      ...(s.heading !== undefined ? { heading: s.heading } : {}), ...(s.speedKmh !== undefined ? { speedKmh: s.speedKmh } : {}),
      ...(s.accuracyM !== undefined ? { accuracyM: s.accuracyM } : {}),
      viaBridge: ws.user.userId,
    };
    const r = await this.hub.convoys.raiseSos(gid, user, msg);
    const gw = this.hub.emergencyGateway || this.hub.convoys?.emergencyGateway;
    if (!r.duplicate && gw) {
      gw.dispatchForSos({ groupId: gid, user, alert: r.alert, msg }).catch((err) => this.hub.log.warn('[mesh] emergency dispatch failed', err.message));
    }
    // Acknowledged only once it is stored (database trouble: no ack, the origin keeps resending, each copy retries).
    if (r.persisted === false) return null;
    return { o: f.origin, cid: s.clientId, alertId: (r.alert && r.alert.alertId) || '' };
  }

  /** Riders the bridge marked ONLINE whose bridged positions stopped (and with no socket of their own): NO_SIGNAL. */
  sweep() {
    const t = this.clock();
    for (const [gid, m] of this.bridged) {
      for (const [uid, at] of m) {
        if (t - at < VIA_BRIDGE_MS) continue;
        m.delete(uid);
        if (this._hasDirectSocket(gid, uid, null)) continue;
        const r = this.hub.convoys.rooms && this.hub.convoys.rooms.get(gid);
        const rider = r && r.riders.get(uid);
        if (rider && rider.presence === 'ONLINE') {
          try { this.hub.convoys.setPresence(gid, uid, 'NO_SIGNAL'); } catch { /* room gone */ }
        }
      }
      if (!m.size) this.bridged.delete(gid);
    }
    for (const [gid, m] of this.caps) {
      for (const [uid, e] of m) if (t - e.at > 12 * 3600000) m.delete(uid);
      if (!m.size) this.caps.delete(gid);
    }
    const nowSec = Math.floor(t / 1000);
    for (const [gid, s] of this.seen) {
      for (const [k, ts] of s) if (nowSec - ts > MAX_AGE_SEC[0]) s.delete(k);
      if (!s.size) this.seen.delete(gid);
    }
  }

  dropRoom(groupId) {
    this.caps.delete(groupId);
    this.seen.delete(groupId);
    this.bridged.delete(groupId);
  }
}

module.exports = { MeshBridge, MESH_CAP, shortId, rideKey, groupTag, openFrame, decodeSos, decodePos, meshSecret, VIA_BRIDGE_MS };
