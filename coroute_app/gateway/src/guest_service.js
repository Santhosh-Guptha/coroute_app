'use strict';
/**
 * v3.63 browser guests: riders without the app (iPhone, a borrowed phone, no install) join a group ride from the
 * invite link in a browser (page /ride/<code>, public/ride/). Owner: "Guests and iPhone riders join from a browser,
 * appear on the ride map, see the group and get SOS alerts, with no app needed."
 *
 * Identity: a first name and a random device key kept in the browser (no account, no password, no e-mail). The real
 * gate is the host: every guest waits for "Let in" (the v3.60 join approval, JOIN_REQUEST / decideJoin), and a guest
 * takes a seat like any rider (plan seats, access mode and pricing unchanged: convoys.joinByCode does it all).
 *
 * Token: a JWT with typ 'guest' (sub = guestId, gid = the ride, v = record version), 12 h, HS256 with JWT_SECRET.
 * auth.verifyTokenDetailed refuses typ 'guest', so a guest token opens NO other API and NO socket: only the routes
 * here, only for its own ride. The record (collection guest_riders) is revoked when the guest leaves, the host
 * removes them, the host declines, or the ride ends; a revoked or older-version token is refused at once.
 *
 * Live view by polling (GET /api/guest/state every few seconds): the riders of the ride (name, role, position, last
 * seen; NO phone numbers or emergency contacts), open SOS / crash alerts (no medical details), the destination,
 * stops and route line. Positions in: POST /api/guest/position (same sanitizer as the app: convoys.patchRider).
 * SOS: POST /api/guest/sos goes through convoys.raiseSos (the same path, idempotent per clientId, never refused by a
 * limiter that a real rider could hit). A guest has no emergency contacts on file: their SOS reaches the group (and
 * the nearby-rider network as any SOS does); the page says so plainly.
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const jwt = require('jsonwebtoken');
const config = require('./config');
const { publicAlert } = require('./convoys');

const COLLECTION = 'guest_riders';
const TOKEN_TTL_S = 12 * 3600;
const REUSE_MS = 12 * 3600000;
const NAME_RE = /^[\p{L}][\p{L}\p{M} .'-]{0,29}$/u;
const DEVICE_RE = /^[A-Za-z0-9_-]{16,64}$/;
const CODE_RE = /^[A-Z0-9]{4,10}$/;
const sha = (s) => crypto.createHash('sha256').update(String(s)).digest('hex');
const firstName = (s) => String(s || '').trim().split(/\s+/)[0].slice(0, 30);

class GuestError extends Error {
  constructor(message, status = 400, code = 'GUEST_INVALID') { super(message); this.status = status; this.code = code; }
}

class GuestService {
  constructor({ repo, convoys, logger = console, clock = Date.now }) {
    Object.assign(this, { repo, convoys, log: logger, clock });
    this.soda = repo.soda;
    this.cache = new Map(); // guestId -> { rec, at }
    this.ready = null;
  }

  async init() {
    if (!this.ready) {
      this.ready = (async () => {
        await this.soda.ensureCollection(COLLECTION);
        await this.soda.ensureIndex(COLLECTION, { name: 'guest_riders_id_ux', unique: true, fields: [{ path: 'guestId' }] });
        await this.soda.ensureIndex(COLLECTION, { name: 'guest_riders_dev_ix', fields: [{ path: 'deviceKey' }] });
        await this.soda.ensureIndex(COLLECTION, { name: 'guest_riders_gid_ix', fields: [{ path: 'groupId' }] });
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  userOf(rec) { return { userId: rec.guestId, name: rec.name, role: 'GUEST', isGuest: true }; }

  tokenFor(rec) {
    return jwt.sign({ typ: 'guest', sub: rec.guestId, gid: rec.groupId || '', v: rec.v || 1 }, config.jwtSecret,
      { expiresIn: TOKEN_TTL_S, issuer: 'coroute-gateway', algorithm: 'HS256' });
  }

  async _find(guestId) {
    const hit = this.cache.get(guestId);
    if (hit && this.clock() - hit.at < 5000) return hit.rec;
    const r = await this.soda.findOne(COLLECTION, { guestId });
    const rec = r ? { ...r.value, key: r.key } : null;
    if (rec) this.cache.set(guestId, { rec, at: this.clock() }); else this.cache.delete(guestId);
    if (this.cache.size > 5000) this.cache.delete(this.cache.keys().next().value);
    return rec;
  }

  async _save(rec, patch) {
    const next = { ...rec, ...patch };
    const { key, ...doc } = next;
    await this.soda.replace(COLLECTION, key, doc);
    this.cache.set(rec.guestId, { rec: next, at: this.clock() });
    return next;
  }

  /** The guest record for a Bearer token, or a GuestError (401). */
  async verify(token) {
    let c;
    try { c = jwt.verify(String(token || ''), config.jwtSecret, { issuer: 'coroute-gateway', algorithms: ['HS256'] }); } catch {
      throw new GuestError('This browser link has expired. Open the invite again.', 401, 'GUEST_SESSION');
    }
    if (!c || c.typ !== 'guest' || typeof c.sub !== 'string' || !c.sub.startsWith('gst_')) throw new GuestError('Not a guest session.', 401, 'GUEST_SESSION');
    const rec = await this._find(c.sub);
    if (!rec || rec.revokedAt || (rec.v || 1) !== c.v) throw new GuestError(rec && rec.revokeReason === 'ENDED' ? 'This ride has ended.' : 'You are no longer in this ride.', 401, 'GUEST_SESSION');
    return rec;
  }

  async revoke(rec, reason) {
    if (!rec || rec.revokedAt) return rec;
    return this._save(rec, { revokedAt: this.clock(), revokeReason: String(reason).slice(0, 20), v: (rec.v || 1) + 1 });
  }

  /** Revokes every guest of a ride (the ride ended). Never throws. */
  async endGroup(groupId) {
    try {
      const rows = await this.soda.query(COLLECTION, { groupId: String(groupId) }, { limit: 500 });
      for (const r of rows) if (!r.value.revokedAt) await this.revoke({ ...r.value, key: r.key }, 'ENDED');
    } catch (e) { this.log.warn?.(`[guest] end group failed: ${e.message}`); }
  }

  /** Name + device key + code -> a guest record (reused for the same browser and ride) and its first join answer. */
  async start({ code, name, deviceId }) {
    await this.init();
    const cleanCode = String(code || '').trim().toUpperCase();
    if (!CODE_RE.test(cleanCode)) throw new GuestError('That join code is not right.', 400, 'BAD_CODE');
    const nm = firstName(name);
    if (!NAME_RE.test(nm)) throw new GuestError('Enter your first name (letters only).', 400, 'BAD_NAME');
    if (!DEVICE_RE.test(String(deviceId || ''))) throw new GuestError('Your browser could not be identified. Reload the page.', 400, 'BAD_DEVICE');
    const deviceKey = sha(`guest|${deviceId}`);
    const t = this.clock();
    let rec = null;
    const mine = await this.soda.query(COLLECTION, { deviceKey }, { limit: 20 });
    for (const r of mine) {
      const v = r.value;
      if (v.code === cleanCode && !v.revokedAt && t - (v.createdAt || 0) < REUSE_MS) { rec = { ...v, key: r.key }; break; }
    }
    if (rec && rec.name !== nm) rec = await this._save(rec, { name: nm });
    if (!rec) {
      const doc = { guestId: `gst_${crypto.randomBytes(12).toString('base64url')}`, name: nm, code: cleanCode, deviceKey, groupId: '', createdAt: t, joinedAt: 0, revokedAt: 0, revokeReason: '', v: 1 };
      const key = await this.soda.insert(COLLECTION, doc);
      rec = { ...doc, key };
    }
    return this._joinStep(rec);
  }

  /** Asks the ride (again): PENDING while the host decides, IN once let in. */
  async _joinStep(rec) {
    let out;
    try {
      out = await this.convoys.joinByCode(this.userOf(rec), rec.code, {});
    } catch (e) {
      const code = e && (e.reason || e.code);
      if (code === 'JOIN_DECLINED') { const r2 = await this.revoke(rec, 'DECLINED'); return { rec: r2, status: 'DECLINED', message: e.message }; }
      if (e && e.status === 404) { const r2 = await this.revoke(rec, 'NO_RIDE'); return { rec: r2, status: 'NO_RIDE', message: 'No live ride has that code. Ask the host for a new invite.' }; }
      throw new GuestError((e && e.message) || 'Could not join the ride.', (e && e.status) || 400, code || 'JOIN_FAILED');
    }
    const gid = out.groupId;
    if (gid && rec.groupId !== gid) rec = await this._save(rec, { groupId: gid });
    if (out.pending) return { rec, status: 'PENDING', rideName: out.name || '' };
    if (!rec.joinedAt) rec = await this._save(rec, { joinedAt: this.clock() });
    return { rec, status: 'IN', rideName: out.name || '' };
  }

  /** Current status of a verified guest; joins once the host has let them in. */
  async status(rec) {
    if (!rec.groupId) return this._joinStep(rec);
    const room = await this.convoys.getRoom(rec.groupId, { required: false }).catch(() => null);
    if (!room || room.meta.tripStatus === 'ENDED') { const r2 = await this.revoke(rec, 'ENDED'); return { rec: r2, status: 'ENDED' }; }
    if (room.riders.has(rec.guestId)) return { rec, status: 'IN', room };
    // Was in and is no longer (the host removed them, or they left elsewhere): never re-admitted silently.
    if (rec.joinedAt) { const r2 = await this.revoke(rec, 'REMOVED'); return { rec: r2, status: 'REMOVED' }; }
    const step = await this._joinStep(rec);
    if (step.status === 'IN') step.room = await this.convoys.getRoom(rec.groupId, { required: false }).catch(() => null);
    return step;
  }

  /** What a guest sees of the ride: no phone numbers, emergency contacts or medical details. */
  view(room, guestId) {
    const m = room.meta;
    const riders = [...room.riders.values()].map((r) => ({
      userId: r.userId, name: firstName(r.name), role: r.role || 'PACK', lat: r.lat || 0, lng: r.lng || 0, speedKmh: r.speedKmh || 0,
      heading: r.heading || 0, lastSeen: r.lastSeenEpochMs || 0, stoppedSince: r.stoppedSince || 0, isGuest: r.isGuest === true,
      presence: r.presence || '', me: r.userId === guestId,
    }));
    const alerts = [...room.alerts.values()].filter((a) => !a.resolved).map((a) => {
      const p = publicAlert(a, { medical: false });
      return { alertId: p.alertId, userId: p.userId, name: firstName(p.userName), alertType: p.alertType, lat: p.lat, lng: p.lng, at: p.timestamp, auto: !!p.auto, status: p.status, mine: p.userId === guestId };
    });
    const route = m.route && typeof m.route.polyline === 'string' && m.route.polyline.length < 200000 ? m.route.polyline : '';
    return {
      ride: { name: m.name || 'Group ride', status: m.tripStatus, destination: m.destinationName || '', destinationLat: m.destinationLat || 0, destinationLng: m.destinationLng || 0,
        host: firstName(m.createdByUserName), stops: (m.stopPoints || []).slice(0, 30).map((s) => ({ name: s.name || 'Stop', lat: s.lat, lng: s.lng })) },
      route, riders, alerts, at: this.clock(),
    };
  }

  async position(rec, body) {
    const room = await this.convoys.getRoom(rec.groupId, { required: false });
    if (!room || !room.riders.has(rec.guestId)) throw new GuestError('You are not in this ride.', 403, 'NOT_MEMBER');
    const b = body || {};
    const lat = Number(b.lat), lng = Number(b.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) throw new GuestError('Bad position.', 400, 'BAD_POSITION');
    const patch = { lat, lng };
    if (Number.isFinite(Number(b.speedKmh))) patch.speedKmh = Number(b.speedKmh);
    if (Number.isFinite(Number(b.heading))) patch.heading = Number(b.heading);
    if (Number.isFinite(Number(b.batteryLevel))) patch.batteryLevel = Number(b.batteryLevel);
    this.convoys.patchRider(room, rec.guestId, patch, { emit: true });
    return { ok: true };
  }

  async sos(rec, body) {
    const b = body || {};
    const clientId = typeof b.clientId === 'string' && /^[A-Za-z0-9_-]{8,64}$/.test(b.clientId) ? b.clientId : `g-${crypto.randomBytes(8).toString('hex')}`;
    const out = await this.convoys.raiseSos(rec.groupId, this.userOf(rec), {
      type: 'SOS', clientId, lat: b.lat, lng: b.lng, accuracyM: b.accuracyM, source: 'MANUAL',
    });
    return { alertId: out.alert.alertId, duplicate: !!out.duplicate, clientId };
  }

  async cancelSos(rec, alertId) {
    const room = await this.convoys.getRoom(rec.groupId, { required: false });
    const a = room && room.alerts.get(String(alertId || ''));
    if (!a || a.userId !== rec.guestId) throw new GuestError('Only your own SOS can be cancelled here.', 403, 'NOT_YOURS');
    await this.convoys.resolveSos(rec.groupId, this.userOf(rec), a.alertId, 'CANCELLED');
    return { ok: true };
  }

  async leave(rec) {
    if (rec.groupId) await this.convoys.leave(rec.groupId, rec.guestId).catch(() => {});
    await this.revoke(rec, 'LEFT');
    return { ok: true };
  }
}

/** /api/guest/* (no account; guest Bearer token after start). */
function guestRouter({ guests }) {
  const r = express.Router();
  const key = (req) => req.ip;
  const lim = (windowMs, limit, k = key) => rateLimit({ windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: k,
    message: { error: 'Too many requests. Wait a little and try again.', code: 'RATE_LIMITED' } });
  const startIp = lim(15 * 60000, 10);
  const startCode = lim(15 * 60000, 40, (req) => `gcode:${String((req.body && req.body.code) || '').toUpperCase().slice(0, 10)}`);
  const byGuest = (limit) => lim(60000, limit, (req) => `g:${req.guest ? req.guest.guestId : req.ip}`);
  const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res)).catch((e) => {
    if (e instanceof GuestError || (e && e.status && e.status < 500)) return res.status(e.status || 400).json({ error: e.message, code: e.code || 'GUEST_ERROR' });
    next(e);
  });
  const needGuest = (req, res, next) => {
    const h = req.headers.authorization || '';
    guests.verify(h.startsWith('Bearer ') ? h.slice(7) : '').then((rec) => { req.guest = rec; next(); },
      (e) => res.status((e && e.status) || 401).json({ error: (e && e.message) || 'Not a guest session.', code: (e && e.code) || 'GUEST_SESSION' }));
  };
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); res.set('X-Robots-Tag', 'noindex'); next(); });

  r.post('/start', startIp, startCode, wrap(async (req, res) => {
    const b = req.body || {};
    const out = await guests.start({ code: b.code, name: b.name, deviceId: b.deviceId });
    const live = out.rec && !out.rec.revokedAt;
    res.status(out.status === 'PENDING' ? 202 : 200).json({ status: out.status, rideName: out.rideName || '', name: out.rec.name, message: out.message || '',
      ...(live ? { token: guests.tokenFor(out.rec), guestId: out.rec.guestId } : {}) });
  }));
  r.get('/state', needGuest, byGuest(90), wrap(async (req, res) => {
    const out = await guests.status(req.guest);
    const body = { status: out.status, name: out.rec.name, rideName: out.rideName || '' };
    if (out.status === 'IN' && out.room) Object.assign(body, guests.view(out.room, out.rec.guestId));
    // A fresh token well before the old one ends (a long ride).
    if (out.status === 'IN' || out.status === 'PENDING') body.token = guests.tokenFor(out.rec);
    res.json(body);
  }));
  r.post('/position', needGuest, byGuest(40), wrap(async (req, res) => res.json(await guests.position(req.guest, req.body))));
  // SOS is never limited below what an abusive client would need (convoys.raiseSos dedupes and caps storms).
  r.post('/sos', needGuest, byGuest(600), wrap(async (req, res) => res.status(201).json(await guests.sos(req.guest, req.body))));
  r.post('/sos/:alertId/cancel', needGuest, byGuest(30), wrap(async (req, res) => res.json(await guests.cancelSos(req.guest, req.params.alertId))));
  r.post('/leave', needGuest, byGuest(10), wrap(async (req, res) => res.json(await guests.leave(req.guest))));
  return r;
}

module.exports = { GuestService, GuestError, guestRouter, COLLECTION };
