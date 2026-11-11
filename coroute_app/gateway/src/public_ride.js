'use strict';
/**
 * Public ride and safe contact (opt-in, every plan). Separate from discovery.js ("Nearby groups")
 * and from the safety network: it only reads `network.hasOpen(gid)` (an emergency always wins).
 *
 * Public ride. The host of a ride (the rider of a solo ride) turns it on in the ride settings
 * (room meta `publicRide`, see public_ride_settings.js; off by default). Every PUBLIC_RIDE_TICK_MS
 * (30 s) the node that runs the room puts ONE coarse entry for the ride in a geohash index:
 * centre of the fresh riders snapped to a fixed 500 m grid, compass heading (8 points), rider count,
 * "Rider" / "Group of N" or the ride name (host's choice), the destination region (host's choice).
 * A ride parked for more than 10 minutes, with an open SOS, or whose host is suspended has no entry.
 * Entries go to the peer gateway (src/mirror.js extension 'pr') when they change, at most once a
 * minute otherwise.
 *
 * Who sees what. Riders of a public ride, and riders with "Show public rides near me" on (PR_PREFS),
 * get PUBLIC_RIDES: the public rides within BOTH radii (theirs and the ride's), never their own ride,
 * never a ride whose host blocked them or that they blocked. Sent when the list changes, at least
 * once a minute while it is not empty. No user ids, no group ids, no names of riders, no phone numbers.
 *
 * Safe contact. PR_CONTACT (Say hi / Ask for help / Warn about the road; a predefined line plus at
 * most 80 characters of filtered text: no links, numbers, handles or bad words) goes to the other
 * ride's host as PR_REQUEST. Guests cannot start contact. The host replies with a quick line, Accept
 * (a 30 minute channel: quick lines, optional live location of their own, optional contact details
 * they choose to share), Ignore, Block (30 days; riders blocked by 3 different riders lose public
 * ride for 7 days) or Report (stored with the conversation for admin review). Every contact is
 * logged for safety review (30 days). A ride with an open SOS takes no requests.
 *
 * Road warnings. A rider of a public ride, or with road warnings on, sends ROAD_WARN (one tap, the
 * kind only); the server takes their own position. Riders heading toward that spot (on their route,
 * or straight ahead on the same road) get ROAD_WARNING: within 5 km while one rider reported it,
 * within 20 km once 2 riders reported or confirmed it. Warnings expire (30 to 60 min by kind, never
 * more than 2 h); 2 "not there" votes clear them. Each node matches its own riders.
 */
const crypto = require('crypto');
const config = require('./config');
const { haversine, medianCentre } = require('./geo_math');
const { angleDiff, crossAlongHeading, projectNearest, RouteIndexCache, gridSize } = require('./net_geo');
const { ConvoyError } = require('./convoys');
const { publicRideOf, radiusOf, DEFAULT_RADIUS_KM } = require('./public_ride_settings');
const { cleanMessage, validateWarnMessage, MESSAGE_MAX, DEFAULT_MESSAGE } = require('./admin_warnings');

const CAP = 'pubride1';
const COLL = 'public_ride';
const MIN = 60000;
const DAY = 24 * 60 * MIN;
const OPEN = 1; // WebSocket.OPEN
const RIDE_ID = /^PR-[0-9A-F]{12}$/;
const REQ_ID = /^PRQ-[0-9A-F]{12}$/;
const CH_ID = /^PRC-[0-9A-F]{12}$/;
const WARN_ID = /^RW-[0-9A-F]{12}$/;
const TEXT_MAX = 80;

/** Predefined lines. The server sends the text with the code, so an older app still shows it. */
const QUICK = {
  HI: { HI: 'Hi from a rider nearby', RIDE_SAFE: 'Ride safe', NICE_RIDE: 'Nice ride!', WHERE_TO: 'Where are you heading?' },
  HELP: { FUEL: 'Need fuel', PUNCTURE: 'Puncture, need help', BREAKDOWN: 'Bike trouble, need help', LOST: 'Lost the way', FIRST_AID: 'Need first aid' },
  WARN: { POLICE: 'Police check ahead', ACCIDENT: 'Accident ahead', BLOCKED: 'Road blocked ahead', ANIMALS: 'Animals on road', BAD_ROAD: 'Bad road ahead', WEATHER: 'Fog or heavy rain ahead' },
  REPLY: { THANKS: 'Thanks!', OK: 'Okay', ON_MY_WAY: 'On my way', WAIT_THERE: 'Wait where you are', CANT_HELP: "Sorry, can't help now", CALL_112: 'Call 112 if urgent' },
};
const KINDS = new Set(['HI', 'HELP', 'WARN']);
/** Lines usable inside an open channel. */
const SAY = { ...QUICK.REPLY, ...QUICK.HELP, ...QUICK.WARN };

const WARN_KINDS = {
  POLICE: { label: 'Police check', ttlMin: 30 },
  ACCIDENT: { label: 'Accident', ttlMin: 60 },
  BLOCKED: { label: 'Landslide or road blocked', ttlMin: 60 },
  ANIMALS: { label: 'Animals on road', ttlMin: 30 },
  FUEL_CLOSED: { label: 'Fuel station closed', ttlMin: 60 },
  WEATHER: { label: 'Fog or heavy rain', ttlMin: 45 },
};
const WARN_HARD_END_MS = 2 * 60 * MIN;
const REPORT_REASONS = new Set(['ABUSE', 'SPAM', 'UNSAFE', 'OTHER']);
/** What an admin did about a report (PATCH /api/admin/public-ride/reports/:id). */
const REPORT_ACTIONS = new Set(['DISMISS', 'WARN', 'SUSPEND']);

// ------------------------------------------------------------------ text filter
const BAD_WORDS = ['fuck', 'fuk', 'shit', 'bitch', 'bastard', 'asshole', 'dick', 'cunt', 'slut', 'whore', 'pussy',
  'madarchod', 'behenchod', 'bhenchod', 'benchod', 'chutiya', 'chutia', 'gandu', 'randi', 'bhosdi', 'bhosdike', 'lund', 'harami'];
const LINK = /(https?:\/\/|www\.|\b[a-z0-9-]{2,}\.(com|in|net|org|io|me|ly|co|app|link|xyz|info|biz|gg|to|tk|ru)\b|t\.me\/|wa\.me\/)/i;
const EMAIL = /[^\s@]+@[^\s@]+\.[a-z]{2,}/i;
const HANDLE = /(^|\s)@[a-z0-9_.]{3,}/i;
const DIGIT_WORDS = /\b(zero|one|two|three|four|five|six|seven|eight|nine|ek|do|teen|char|paanch|chhe|saat|aath|nau)\b/gi;

/**
 * Short free text next to a predefined line: control characters removed, spaces collapsed, at most
 * 80 characters. Refused ({ ok: false, reason }) with a link, an e-mail, a @handle, a phone number
 * (7 or more digits, spaces and dashes ignored, digit words counted) or a bad word.
 */
function cleanText(raw, max = TEXT_MAX) {
  if (raw === undefined || raw === null || raw === '') return { ok: true, text: '' };
  if (typeof raw !== 'string') return { ok: false, reason: 'TEXT' };
  const text = raw.replace(/[\u0000-\u001F\u007F\u200B-\u200F\u2028-\u202E\u2060-\u206F]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!text) return { ok: true, text: '' };
  if (text.length > max) return { ok: false, reason: 'TOO_LONG' };
  if (LINK.test(text) || EMAIL.test(text) || HANDLE.test(text)) return { ok: false, reason: 'LINK' };
  const digits = (text.match(/\d/g) || []).length + (text.match(DIGIT_WORDS) || []).length * 1;
  if (digits >= 7 || /\d[\d\s().+-]{5,}\d/.test(text)) return { ok: false, reason: 'NUMBER' };
  const norm = text.toLowerCase().replace(/[0@4]/g, (c) => ({ 0: 'o', '@': 'a', 4: 'a' }[c])).replace(/[1!|]/g, 'i').replace(/3/g, 'e').replace(/[5$]/g, 's').replace(/7/g, 't');
  const words = norm.split(/[^a-z]+/).filter(Boolean);
  const squashed = norm.replace(/[^a-z]/g, '');
  for (const w of BAD_WORDS) {
    if (words.includes(w)) return { ok: false, reason: 'LANGUAGE' };
    if (w.length >= 5 && squashed.includes(w)) return { ok: false, reason: 'LANGUAGE' };
  }
  // Masked words ("f*ck"): each * stands for one letter.
  for (const t of text.toLowerCase().split(/\s+/)) {
    if (!t.includes('*')) continue;
    const re = new RegExp(`^${t.replace(/[^a-z*]/g, '').replace(/\*/g, '[a-z]')}$`);
    if (BAD_WORDS.some((w) => re.test(w))) return { ok: false, reason: 'LANGUAGE' };
  }
  return { ok: true, text };
}

/** A ride name or destination region shown to strangers: only when it would pass the text filter. */
function safeLabel(s, max) {
  const v = String(s || '').replace(/\s+/g, ' ').trim().slice(0, max);
  const c = cleanText(v);
  return c.ok ? c.text : '';
}

// ------------------------------------------------------------------ geometry
const M_LAT = 111320;
/** A fixed grid of ~`stepM` cells: every position inside one cell reads as the cell's centre. */
function snap(lat, lng, stepM = config.publicRideSnapM) {
  const latStep = stepM / M_LAT;
  const la = Math.round(lat / latStep) * latStep;
  const lngStep = stepM / (M_LAT * Math.max(0.2, Math.cos(la * Math.PI / 180)));
  const ln = Math.round(lng / lngStep) * lngStep;
  return { lat: Math.round(la * 1e5) / 1e5, lng: Math.round(ln * 1e5) / 1e5 };
}

const B32 = '0123456789bcdefghjkmnpqrstuvwxyz';
/** Standard geohash. */
function geohash(lat, lng, precision = 4) {
  let latLo = -90, latHi = 90, lngLo = -180, lngHi = 180, bit = 0, ch = 0, even = true, out = '';
  while (out.length < precision) {
    if (even) { const m = (lngLo + lngHi) / 2; if (lng >= m) { ch = (ch << 1) | 1; lngLo = m; } else { ch <<= 1; lngHi = m; } }
    else { const m = (latLo + latHi) / 2; if (lat >= m) { ch = (ch << 1) | 1; latLo = m; } else { ch <<= 1; latHi = m; } }
    even = !even;
    if (++bit === 5) { out += B32[ch]; bit = 0; ch = 0; }
  }
  return out;
}
const GH_PREC = 4; // cells of about 39 x 20 km
const GH_LAT = 180 / 2 ** 10, GH_LNG = 360 / 2 ** 10;
/** Geohash cells covering a circle of radius R metres (a superset). */
function cellsFor(lat, lng, R) {
  const dLat = R / M_LAT;
  const dLng = R / (M_LAT * Math.max(0.05, Math.cos(lat * Math.PI / 180)));
  const out = new Set();
  for (let a = lat - dLat; a <= lat + dLat + GH_LAT / 2; a += GH_LAT / 2) {
    for (let b = lng - dLng; b <= lng + dLng + GH_LNG / 2; b += GH_LNG / 2) {
      out.add(geohash(Math.max(-89.999, Math.min(89.999, Math.min(a, lat + dLat))), ((Math.min(b, lng + dLng) + 540) % 360) - 180, GH_PREC));
    }
  }
  return out;
}

const COMPASS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
const compass = (h) => COMPASS[Math.round((((h % 360) + 360) % 360) / 45) % 8];
const r3 = (x) => Math.round(x * 1e3) / 1e3;
const r5 = (x) => Math.round(x * 1e5) / 1e5;
const hex = (n) => crypto.randomBytes(n).toString('hex').toUpperCase();

function isGuest(user) {
  return !!user && (user.isGuest === true || user.provider === 'guest' || String(user.email || '').toLowerCase().endsWith('@guest.coroute.local'));
}

// ------------------------------------------------------------------ service
class PublicRides {
  constructor({ convoys, network = null, audit = null, soda = null, repo = null, logger = console, clock = Date.now, tickMs = config.publicRideTickMs, routes = null, enabled = config.publicRideEnabled } = {}) {
    this.convoys = convoys; this.network = network; this.audit = audit; this.soda = soda; this.repo = repo;
    this.log = logger; this.clock = clock; this.enabled = enabled; this.tickMs = tickMs;
    this.routes = routes || new RouteIndexCache({ simplifyM: config.netRouteSimplifyM, maxPoints: config.netRouteMaxPoints, G: gridSize(config.netGridMillideg) });
    this.out = null; this.mirror = null;
    this.adminWarnings = null; // 3.55 AdminWarnings (set by app.js): delivers a report's WARN to the rider
    this.index = new Map(); // rideId -> entry
    this.cells = new Map(); // geohash -> Set<rideId>
    this.rideOfGid = new Map(); // gid -> rideId (entries computed here)
    this.motion = new Map(); // gid -> { lat, lng, since } (parked detection)
    this.repAt = new Map(); // rideId -> { sig, at } last replicated
    this.prefs = new Map(); // uid -> { showNearby, radiusKm, roadWarnings, at }
    this.lists = new Map(); // uid -> { ids: Set<rideId>, sig, at } (this node's viewers)
    this.blocks = new Map(); // `${blocker}|${blocked}` -> { at, until }
    this.susp = new Map(); // uid -> until
    this.requests = new Map();
    this.channels = new Map();
    this.sharing = new Map(); // uid -> Set<channelId> while sharing location
    this.warnings = new Map();
    this.warnSent = new Map(); // warnId -> Map<uid, 'U' | 'C'> (this node's riders)
    this.rate = new Map(); // key -> times
    this.falseWarns = new Map(); // uid -> times
    this.lastPrune = 0;
    this.stats = { ticks: 0, entries: 0, lists: 0, contacts: 0, warnings: 0 };
    this.timer = setInterval(() => { try { this.tick(); } catch (e) { this.log.warn('[public-ride]', e.message); } }, tickMs);
    if (this.timer.unref) this.timer.unref();
  }

  attach(out) { this.out = out; out.publicRides = this; }
  stop() { clearInterval(this.timer); }

  /** Loads blocks and suspensions still in force (a restart keeps them). */
  async init() {
    if (!this.soda) return;
    try {
      await this.soda.ensureCollection(COLL);
      const t = this.clock();
      for (const r of await this.soda.query(COLL, { k: 'block', until: { $gt: t } }, { limit: 10000 })) {
        const v = r.value;
        this.blocks.set(`${v.blocker}|${v.blocked}`, { at: Number(v.at) || t, until: Number(v.until) });
      }
      for (const r of await this.soda.query(COLL, { k: 'suspend', until: { $gt: t } }, { limit: 10000 })) this.susp.set(r.value.userId, Number(r.value.until));
    } catch (e) { this.log.warn('[public-ride] load failed', e.message); }
  }

  // ---------------------------------------------------------------- small helpers
  _replicate(op) { try { if (this.mirror) this.mirror.ext('pr', op); } catch (e) { this.log.warn('[public-ride] replicate', e.message); } }
  _send(uid, payload, { local = false } = {}) { try { return this.out ? this.out.sendToUser(uid, payload, CAP, { local }) : 0; } catch { return 0; } }
  _store(doc) { if (this.soda) this.soda.insert(COLL, doc).catch((e) => this.log.warn('[public-ride] store failed', e.message)); }
  _hasOpen(gid) { try { return !!this.network && !!gid && this.network.hasOpen(gid); } catch { return false; } }
  _passive(gid) { return !!(this.convoys.passive && this.convoys.passive(gid)); }

  _rateOk(key, windowMs, max, now) {
    const list = (this.rate.get(key) || []).filter((x) => now - x < windowMs);
    if (list.length >= max) { this.rate.set(key, list); return false; }
    list.push(now); this.rate.set(key, list);
    return true;
  }

  suspendedUntil(uid, now = this.clock()) { const u = this.susp.get(uid) || 0; return u > now ? u : 0; }
  blocked(blocker, blocked, now = this.clock()) { const b = this.blocks.get(`${blocker}|${blocked}`); return !!b && b.until > now; }
  _eitherBlocked(a, b, now) { return this.blocked(a, b, now) || this.blocked(b, a, now); }

  /** The rider who answers for a ride: the trip owner, else the creator, else a lead. */
  hostOf(room) {
    const m = room.meta || {};
    for (const id of [m.tripOwnerUserId, m.createdByUserId]) if (id && room.riders.has(id)) return id;
    for (const r of room.riders.values()) if (r.role === 'LEAD') return r.userId;
    return m.tripOwnerUserId || m.createdByUserId || '';
  }

  _fresh(room, now) {
    return [...room.riders.values()].filter((r) => now - (Number(r.lastSeenEpochMs) || 0) <= config.netFreshS * 1000 && Number.isFinite(r.lat) && Number.isFinite(r.lng) && (r.lat || r.lng));
  }

  /** My own fresh position in the ride my socket is bound to, or null. */
  _pos(uid, gid, now) {
    const r = gid && this.convoys.rooms.get(gid)?.riders.get(uid);
    if (!r || !Number.isFinite(r.lat) || !Number.isFinite(r.lng) || (!r.lat && !r.lng)) return null;
    if (now - (Number(r.lastSeenEpochMs) || 0) > config.netFreshS * 1000) return null;
    return r;
  }

  /** This node's sockets that understand public ride and are in a ride: uid -> gid. */
  _localUsers() {
    const out = new Map();
    const byUser = this.out && this.out.byUser;
    if (!byUser) return out;
    for (const [uid, set] of byUser) {
      for (const ws of set) if (ws.readyState === OPEN && ws.allowed && ws.groupId && ws.caps && ws.caps.has(CAP)) { out.set(uid, ws.groupId); break; }
    }
    return out;
  }

  // ---------------------------------------------------------------- index
  /** One coarse entry for a ride run by this node, or null (off, not riding, parked, SOS, host suspended). */
  rideEntry(gid, room, now) {
    const s = publicRideOf(room.meta.publicRide);
    if (!s.on || !s.id || room.meta.tripStatus !== 'STARTED') return null;
    const hostId = this.hostOf(room);
    if (!hostId || this.suspendedUntil(hostId, now) || this._hasOpen(gid)) return null;
    const fresh = this._fresh(room, now);
    if (!fresh.length) return null;
    const c = medianCentre(fresh);
    const moving = fresh.filter((r) => (Number(r.speedKmh) || 0) >= 8);
    const m = this.motion.get(gid);
    if (!m || moving.length || haversine(m.lat, m.lng, c.lat, c.lng) > 300) this.motion.set(gid, { lat: c.lat, lng: c.lng, since: now });
    if (now - this.motion.get(gid).since > config.publicRideParkMin * MIN) return null;
    let heading = null;
    if (moving.length) {
      let x = 0, y = 0;
      for (const r of moving) { x += Math.sin((Number(r.heading) || 0) * Math.PI / 180); y += Math.cos((Number(r.heading) || 0) * Math.PI / 180); }
      if (Math.hypot(x, y) > 1e-6) heading = compass(((Math.atan2(x, y) * 180 / Math.PI) + 360) % 360);
    }
    const p = snap(c.lat, c.lng);
    const n = fresh.length;
    const name = s.showName ? safeLabel(room.meta.name, 40) : '';
    const region = s.showDestRegion ? safeLabel(String(room.meta.destinationName || '').split(',').pop(), 30) : '';
    return {
      rideId: s.id, gid, hostId, lat: p.lat, lng: p.lng, heading, riders: n,
      label: name || (n === 1 ? 'Rider' : `Group of ${n}`), destRegion: region, radiusKm: s.radiusKm, at: now,
    };
  }

  _put(e) {
    const old = this.index.get(e.rideId);
    const cell = geohash(e.lat, e.lng, GH_PREC);
    if (old && old.cell !== cell) this._uncell(old);
    e.cell = cell;
    this.index.set(e.rideId, e);
    let set = this.cells.get(cell);
    if (!set) { set = new Set(); this.cells.set(cell, set); }
    set.add(e.rideId);
  }
  _uncell(e) { const set = this.cells.get(e.cell); if (set) { set.delete(e.rideId); if (!set.size) this.cells.delete(e.cell); } }
  _drop(rideId) { const e = this.index.get(rideId); if (!e) return; this._uncell(e); this.index.delete(rideId); }

  _updateIndex(now) {
    const seen = new Set();
    for (const [gid, room] of this.convoys.rooms) {
      const s = room.meta && room.meta.publicRide;
      if (!s || s.on !== true || this._passive(gid)) continue;
      const e = this.rideEntry(gid, room, now);
      const prevId = this.rideOfGid.get(gid);
      if (prevId && (!e || prevId !== e.rideId)) this._unpublish(gid, prevId);
      if (!e) continue;
      seen.add(gid);
      e.local = true;
      this._put(e);
      this.rideOfGid.set(gid, e.rideId);
      const { at, local, cell, ...rest } = e;
      const sig = JSON.stringify(rest);
      const last = this.repAt.get(e.rideId);
      if (!last || last.sig !== sig || now - last.at >= MIN) {
        this.repAt.set(e.rideId, { sig, at: now });
        this._replicate({ op: 'IDX', id: e.rideId, e: { ...rest, at: now } });
      }
    }
    for (const [gid, id] of [...this.rideOfGid]) if (!seen.has(gid)) this._unpublish(gid, id);
    // Entries from the peer that stopped coming (peer gone, ride ended there).
    for (const [id, e] of [...this.index]) if (!e.local && now - e.at > 3 * Math.max(this.tickMs, 30000)) this._drop(id);
    this.stats.entries = this.index.size;
  }

  _unpublish(gid, id) {
    this.rideOfGid.delete(gid);
    this.repAt.delete(id);
    if (this.index.get(id)?.local) { this._drop(id); this._replicate({ op: 'IDX', id, e: null }); }
  }

  /** The radius a viewer sees with (km), or 0: their public ride's radius, else "Show public rides near me". */
  viewerRadiusKm(uid, gid) {
    const room = this.convoys.rooms.get(gid);
    const s = room ? publicRideOf(room.meta.publicRide) : null;
    if (s && s.on) return s.radiusKm;
    const p = this.prefs.get(uid);
    return p && p.showNearby ? p.radiusKm : 0;
  }

  /** Public rides a viewer may see now (both radii, never their own ride, never across a block). */
  visibleTo(uid, gid, now = this.clock()) {
    const radiusKm = this.viewerRadiusKm(uid, gid);
    const me = this._pos(uid, gid, now);
    if (!radiusKm || !me || this.suspendedUntil(uid, now)) return [];
    const out = [];
    for (const cell of cellsFor(me.lat, me.lng, radiusKm * 1000)) {
      for (const id of this.cells.get(cell) || []) {
        const e = this.index.get(id);
        if (!e || e.gid === gid || this._eitherBlocked(e.hostId, uid, now)) continue;
        const d = haversine(me.lat, me.lng, e.lat, e.lng);
        if (d > Math.min(radiusKm, e.radiusKm) * 1000) continue;
        out.push({ e, d });
      }
    }
    out.sort((a, b) => a.d - b.d);
    return out.slice(0, 30).map(({ e, d }) => {
      const v = { rideId: e.rideId, label: e.label, riders: e.riders, distanceKm: Math.max(1, Math.round(d / 1000)), lat: e.lat, lng: e.lng, heading: e.heading };
      if (e.destRegion) v.destRegion = e.destRegion;
      return v;
    });
  }

  _sendLists(now) {
    const local = this._localUsers();
    for (const [uid, gid] of local) {
      const rides = this.visibleTo(uid, gid, now);
      const prev = this.lists.get(uid);
      const sig = JSON.stringify(rides);
      if (prev && prev.sig === sig && (rides.length === 0 || now - prev.at < MIN)) continue;
      if (!prev && rides.length === 0) { this.lists.set(uid, { ids: new Set(), sig, at: now }); continue; }
      this.lists.set(uid, { ids: new Set(rides.map((r) => r.rideId)), sig, at: now });
      this._send(uid, { type: 'PUBLIC_RIDES', rides, radiusKm: this.viewerRadiusKm(uid, gid) }, { local: true });
      this.stats.lists++;
    }
    for (const uid of [...this.lists.keys()]) if (!local.has(uid)) this.lists.delete(uid);
  }

  // ---------------------------------------------------------------- periodic
  tick(now = this.clock()) {
    if (!this.enabled) return;
    this.stats.ticks++;
    this._updateIndex(now);
    this._sendLists(now);
    this._expire(now);
    this._matchWarnings(now);
    if (now - this.lastPrune > 60 * MIN) this._prune(now);
  }

  _expire(now) {
    for (const [id, q] of [...this.requests]) {
      if (q.state === 'OPEN' && now > q.expiresAt) {
        q.state = 'CLOSED';
        this._send(q.fromId, { type: 'PR_UPDATE', requestId: id, state: 'CLOSED' }, { local: true });
        if (!q.silent) this._send(q.toId, { type: 'PR_UPDATE', requestId: id, state: 'CLOSED' }, { local: true });
      }
      if (q.state !== 'OPEN' && now - q.at > 2 * config.publicRideChannelMin * MIN) this.requests.delete(id);
    }
    for (const [id, c] of [...this.channels]) {
      if (!c.closed && now > c.expiresAt) {
        c.closed = true;
        for (const u of [c.a, c.b]) this._send(u, { type: 'PR_CHANNEL', channelId: id, state: 'CLOSED' }, { local: true });
        this._stopSharing(c);
      }
      if (c.closed && now - c.expiresAt > 10 * MIN) this.channels.delete(id);
    }
    for (const [id, w] of [...this.warnings]) if (now > w.expiresAt) this._clearWarning(id, { replicate: false });
  }

  _prune(now) {
    this.lastPrune = now;
    for (const [k, list] of [...this.rate]) if (!list.some((x) => now - x < DAY)) this.rate.delete(k);
    for (const [k, b] of [...this.blocks]) if (b.until <= now) this.blocks.delete(k);
    for (const [u, until] of [...this.susp]) if (until <= now) this.susp.delete(u);
    for (const [u, list] of [...this.falseWarns]) if (!list.some((x) => now - x < DAY)) this.falseWarns.delete(u);
    for (const [u, p] of [...this.prefs]) if (now - p.at > 2 * DAY) this.prefs.delete(u);
    for (const gid of [...this.motion.keys()]) if (!this.convoys.rooms.has(gid)) this.motion.delete(gid);
    // Contact log kept 30 days; expired blocks and suspensions go with it.
    if (this.soda) {
      this.soda.removeWhere(COLL, { k: 'log', at: { $lt: now - 30 * DAY } }).catch(() => {});
      this.soda.removeWhere(COLL, { k: 'block', until: { $lt: now } }).catch(() => {});
      this.soda.removeWhere(COLL, { k: 'suspend', until: { $lt: now } }).catch(() => {});
    }
  }

  // ---------------------------------------------------------------- socket messages
  /** Every PR_* / ROAD_WARN* socket message. Answers the socket; throws ConvoyError. */
  async handle(ws, msg) {
    if (!this.enabled) throw new ConvoyError(`Unknown message type ${msg.type}`, 400);
    // Own budget: public ride messages never use up the budget of safety messages.
    const t = Date.now();
    const r = ws.prRate || (ws.prRate = { at: t, n: 0 });
    if (t - r.at >= 1000) { r.at = t; r.n = 0; }
    if (++r.n > 8) throw new ConvoyError('Slow down.', 429);
    const u = ws.user;
    const now = this.clock();
    let res;
    switch (msg.type) {
      case 'PR_PREFS': res = this.setPrefs(u, msg, now); break;
      case 'PR_CONTACT': res = this.contact(u, ws.groupId, msg, now); break;
      case 'PR_REPLY': res = await this.reply(u, msg, now); break;
      case 'PR_SAY': res = this.say(u, msg, now); break;
      case 'PR_SHARE_LOC': res = this.shareLocation(u, msg, now); break;
      case 'PR_SHARE_CONTACT': res = await this.shareContact(u, msg, now); break;
      case 'PR_CLOSE': res = this.closeChannel(u, msg, now); break;
      case 'PR_REPORT': res = await this.report(u, msg, now); break;
      case 'PR_BLOCK': res = this.blockRef(u, msg, now); break;
      case 'ROAD_WARN': res = this.roadWarn(u, ws.groupId, msg, now); break;
      case 'ROAD_WARN_VOTE': res = this.vote(u, msg, now); break;
      default: throw new ConvoyError(`Unknown message type ${msg.type}`, 400);
    }
    if (res && this.out) this.out.send(ws, res);
    return res;
  }

  setPrefs(u, msg, now) {
    const p = { showNearby: msg.showNearby === true, radiusKm: radiusOf(msg.radiusKm, DEFAULT_RADIUS_KM), roadWarnings: msg.roadWarnings === true, at: now };
    this.prefs.set(u.userId, p);
    this._replicate({ op: 'PREFS', uid: u.userId, p });
    const until = this.suspendedUntil(u.userId, now);
    return { type: 'PR_PREFS_OK', showNearby: p.showNearby, radiusKm: p.radiusKm, roadWarnings: p.roadWarnings, ...(until ? { suspendedUntil: until } : {}) };
  }

  /** How my ride looks to others (its public entry), or "Rider". */
  _labelOf(gid) {
    const id = this.rideOfGid.get(gid);
    const e = id && this.index.get(id);
    if (e) return { label: e.label, rideId: e.rideId };
    for (const x of this.index.values()) if (x.gid === gid) return { label: x.label, rideId: x.rideId };
    return { label: 'Rider' };
  }

  contact(u, gid, msg, now) {
    if (isGuest(u)) throw new ConvoyError('Sign in with an account to contact other riders.', 403, 'GUEST');
    if (!gid) throw new ConvoyError('Start or join a ride first.', 409, 'NOT_JOINED');
    if (this.suspendedUntil(u.userId, now)) throw new ConvoyError('Public ride is paused for your account.', 403, 'SUSPENDED');
    const kind = String(msg.kind || '');
    const quick = String(msg.quick || '');
    if (!KINDS.has(kind) || !QUICK[kind][quick]) throw new ConvoyError('Pick a message.', 400, 'BAD_QUICK');
    const txt = cleanText(msg.text);
    if (!txt.ok) throw new ConvoyError('Keep it short: no links, numbers or bad words.', 400, 'TEXT_NOT_ALLOWED');
    const rideId = typeof msg.rideId === 'string' && RIDE_ID.test(msg.rideId) ? msg.rideId : '';
    const list = this.lists.get(u.userId);
    const e = rideId && this.index.get(rideId);
    if (!e || !list || !list.ids.has(rideId)) throw new ConvoyError('That ride is no longer nearby.', 404, 'RIDE_GONE');
    if (e.gid === gid) throw new ConvoyError('That is your own ride.', 400, 'OWN_RIDE');
    if (this._hasOpen(gid)) throw new ConvoyError('Your SOS is open. Use SOS for help.', 409, 'SOS_OPEN');
    if (this._hasOpen(e.gid)) throw new ConvoyError("They can't take requests right now.", 409, 'BUSY');
    for (const q of this.requests.values()) {
      if (q.fromId === u.userId && q.toRideId === rideId && q.state === 'OPEN') throw new ConvoyError('You already asked this ride. Wait for a reply.', 429, 'ALREADY_ASKED');
    }
    if (!this._rateOk(`c2:${u.userId}:${rideId}`, 2 * MIN, 1, now)
      || !this._rateOk(`c10:${u.userId}`, 10 * MIN, 4, now)
      || !this._rateOk(`cday:${u.userId}`, DAY, 20, now)) throw new ConvoyError('Slow down.', 429, 'RATE');
    const me = this._pos(u.userId, gid, now);
    const from = this._labelOf(gid);
    const silent = this.blocked(e.hostId, u.userId, now);
    const q = {
      requestId: `PRQ-${hex(6)}`, fromId: u.userId, toId: e.hostId, fromGid: gid, toGid: e.gid, toRideId: rideId,
      fromLabel: from.label, fromRideId: from.rideId || '', toLabel: e.label, kind, quick, text: txt.text,
      distanceKm: me ? Math.max(1, Math.round(haversine(me.lat, me.lng, e.lat, e.lng) / 1000)) : null,
      at: now, expiresAt: now + config.publicRideRequestMin * MIN, state: 'OPEN', silent, replies: 0,
      log: [{ by: 'A', quick, text: txt.text, at: now }],
    };
    this.requests.set(q.requestId, q);
    this._replicate({ op: 'REQ', q });
    // Blocked: looks sent, is never delivered, and closes like an unanswered request.
    if (!silent) this._send(e.hostId, this.requestView(q));
    this._logContact({ ref: q.requestId, fromId: u.userId, toId: e.hostId, kind, quick, text: txt.text, delivered: !silent }, now);
    this.stats.contacts++;
    return { type: 'PR_SENT', requestId: q.requestId, rideId, expiresAt: q.expiresAt };
  }

  /** PR_REQUEST as the host sees it: who (label only), what, how far. */
  requestView(q) {
    const from = { label: q.fromLabel };
    if (q.fromRideId) from.rideId = q.fromRideId;
    const out = { type: 'PR_REQUEST', requestId: q.requestId, kind: q.kind, quick: q.quick, quickText: QUICK[q.kind][q.quick], text: q.text, from, at: q.at, expiresAt: q.expiresAt };
    if (q.distanceKm) out.distanceKm = q.distanceKm;
    return out;
  }

  _req(u, id, { host = true } = {}) {
    const q = typeof id === 'string' && REQ_ID.test(id) ? this.requests.get(id) : null;
    if (!q || (host ? q.toId !== u.userId : (q.toId !== u.userId && q.fromId !== u.userId)) || (host && q.silent)) {
      throw new ConvoyError('This request has closed.', 404, 'REQUEST_CLOSED');
    }
    return q;
  }

  async reply(u, msg, now) {
    const q = this._req(u, msg.requestId);
    const action = String(msg.action || '');
    if (action === 'BLOCK') { this._closeRequest(q); await this.block(u.userId, q.fromId, now); return { type: 'PR_REPLY_OK', requestId: q.requestId, action }; }
    if (action === 'REPORT') {
      this._closeRequest(q);
      await this._report(u.userId, q.fromId, q.requestId, msg.reason, msg.text, q.log, 'B', now);
      if (msg.block === true) await this.block(u.userId, q.fromId, now);
      return { type: 'PR_REPLY_OK', requestId: q.requestId, action };
    }
    if (q.state !== 'OPEN' || now > q.expiresAt) throw new ConvoyError('This request has closed.', 404, 'REQUEST_CLOSED');
    if (action === 'QUICK') {
      const quick = String(msg.quick || '');
      if (!QUICK.REPLY[quick]) throw new ConvoyError('Pick a reply.', 400, 'BAD_QUICK');
      const txt = cleanText(msg.text);
      if (!txt.ok) throw new ConvoyError('Keep it short: no links, numbers or bad words.', 400, 'TEXT_NOT_ALLOWED');
      if (q.replies >= 5 || !this._rateOk(`r:${q.requestId}`, 3000, 1, now)) throw new ConvoyError('Slow down.', 429, 'RATE');
      q.replies++;
      q.log.push({ by: 'B', quick, text: txt.text, at: now });
      this._replicate({ op: 'REQ', q });
      this._send(q.fromId, { type: 'PR_MESSAGE', ref: q.requestId, quick, quickText: QUICK.REPLY[quick], text: txt.text, at: now });
      this._logContact({ ref: q.requestId, fromId: u.userId, toId: q.fromId, kind: 'REPLY', quick, text: txt.text, delivered: true }, now);
      return { type: 'PR_REPLY_OK', requestId: q.requestId, action };
    }
    if (action === 'ACCEPT') {
      const c = {
        channelId: `PRC-${hex(6)}`, requestId: q.requestId, a: q.fromId, b: q.toId, aLabel: q.fromLabel, bLabel: q.toLabel,
        openedAt: now, expiresAt: now + config.publicRideChannelMin * MIN, share: {}, closed: false, log: [...q.log],
      };
      this.channels.set(c.channelId, c);
      q.state = 'ACCEPTED'; q.channelId = c.channelId;
      this._replicate({ op: 'REQ', q });
      this._replicate({ op: 'CHAN', c });
      this._send(q.fromId, { type: 'PR_UPDATE', requestId: q.requestId, state: 'ACCEPTED', channelId: c.channelId, expiresAt: c.expiresAt });
      this._send(q.fromId, { type: 'PR_CHANNEL', channelId: c.channelId, state: 'OPEN', expiresAt: c.expiresAt, with: { label: c.bLabel }, requestId: q.requestId });
      this._send(q.toId, { type: 'PR_CHANNEL', channelId: c.channelId, state: 'OPEN', expiresAt: c.expiresAt, with: { label: c.aLabel }, requestId: q.requestId });
      this._logContact({ ref: q.requestId, fromId: u.userId, toId: q.fromId, kind: 'ACCEPT', delivered: true }, now);
      return { type: 'PR_REPLY_OK', requestId: q.requestId, action, channelId: c.channelId };
    }
    if (action === 'IGNORE') { this._closeRequest(q); return { type: 'PR_REPLY_OK', requestId: q.requestId, action }; }
    throw new ConvoyError('Unknown reply.', 400, 'BAD_ACTION');
  }

  /** Ignore, block, report: the sender only learns that the request closed (same as no reply). */
  _closeRequest(q) {
    if (q.state !== 'OPEN') return;
    q.state = 'CLOSED';
    this._replicate({ op: 'REQ', q });
    this._send(q.fromId, { type: 'PR_UPDATE', requestId: q.requestId, state: 'CLOSED' });
  }

  _chan(u, id) {
    const c = typeof id === 'string' && CH_ID.test(id) ? this.channels.get(id) : null;
    if (!c || c.closed || (c.a !== u.userId && c.b !== u.userId) || this.clock() > c.expiresAt) throw new ConvoyError('This chat has ended.', 404, 'CHANNEL_CLOSED');
    return c;
  }
  _other(c, uid) { return c.a === uid ? c.b : c.a; }

  say(u, msg, now) {
    const c = this._chan(u, msg.channelId);
    const quick = String(msg.quick || '');
    if (quick && !SAY[quick]) throw new ConvoyError('Pick a message.', 400, 'BAD_QUICK');
    const txt = cleanText(msg.text);
    if (!txt.ok) throw new ConvoyError('Keep it short: no links, numbers or bad words.', 400, 'TEXT_NOT_ALLOWED');
    if (!quick && !txt.text) throw new ConvoyError('Pick a message.', 400, 'BAD_QUICK');
    if (!this._rateOk(`s:${c.channelId}:${u.userId}`, 3000, 1, now) || !this._rateOk(`sn:${c.channelId}:${u.userId}`, 2 * config.publicRideChannelMin * MIN, 40, now)) {
      throw new ConvoyError('Slow down.', 429, 'RATE');
    }
    c.log.push({ by: c.a === u.userId ? 'A' : 'B', quick, text: txt.text, at: now });
    if (c.log.length > 60) c.log.splice(0, c.log.length - 60);
    this._replicate({ op: 'CHAN', c });
    const to = this._other(c, u.userId);
    this._send(to, { type: 'PR_MESSAGE', ref: c.channelId, quick, quickText: quick ? SAY[quick] : '', text: txt.text, at: now });
    this._logContact({ ref: c.channelId, fromId: u.userId, toId: to, kind: 'SAY', quick, text: txt.text, delivered: true }, now);
    return { type: 'PR_SAY_OK', channelId: c.channelId, at: now };
  }

  shareLocation(u, msg, now) {
    const c = this._chan(u, msg.channelId);
    const on = msg.on === true;
    c.share[u.userId] = on ? c.expiresAt : 0;
    this._replicate({ op: 'CHAN', c });
    this._indexSharing(c);
    const to = this._other(c, u.userId);
    if (!on) this._send(to, { type: 'PR_LOCATION', channelId: c.channelId, off: true });
    else {
      // The rider's own latest fix, if this node has it (otherwise with the next fix).
      for (const room of this.convoys.rooms.values()) {
        const r = room.riders.get(u.userId);
        if (r && Number.isFinite(r.lat) && now - (Number(r.lastSeenEpochMs) || 0) <= config.netFreshS * 1000) {
          c.lastLoc = { ...(c.lastLoc || {}), [u.userId]: now };
          this._send(to, { type: 'PR_LOCATION', channelId: c.channelId, lat: r5(r.lat), lng: r5(r.lng), at: Number(r.lastSeenEpochMs) || now });
          break;
        }
      }
    }
    this._logContact({ ref: c.channelId, fromId: u.userId, toId: to, kind: on ? 'SHARE_LOCATION' : 'STOP_LOCATION', delivered: true }, now);
    return { type: 'PR_SHARE_LOC_OK', channelId: c.channelId, on, until: on ? c.expiresAt : 0 };
  }

  _indexSharing(c) {
    for (const uid of [c.a, c.b]) {
      const set = this.sharing.get(uid) || new Set();
      if (!c.closed && (c.share[uid] || 0) > this.clock()) set.add(c.channelId); else set.delete(c.channelId);
      if (set.size) this.sharing.set(uid, set); else this.sharing.delete(uid);
    }
  }
  _stopSharing(c) { c.share = {}; this._indexSharing(c); }

  /** convoys 'telemetry': a rider sharing their location in an open chat (at most every 10 s). */
  onTelemetry(gid, rider) {
    if (!rider || !this.sharing.size) return;
    const set = this.sharing.get(rider.userId);
    if (!set) return;
    const now = this.clock();
    for (const id of set) {
      const c = this.channels.get(id);
      if (!c || c.closed || (c.share[rider.userId] || 0) <= now) continue;
      const last = (c.lastLoc && c.lastLoc[rider.userId]) || 0;
      if (now - last < 10000) continue;
      c.lastLoc = { ...(c.lastLoc || {}), [rider.userId]: now };
      this._send(this._other(c, rider.userId), { type: 'PR_LOCATION', channelId: id, lat: r5(rider.lat), lng: r5(rider.lng), at: Number(rider.lastSeenEpochMs) || now });
    }
  }

  /** The rider's own first name and phone, only when they choose to share them in an open chat. */
  async shareContact(u, msg, now) {
    const c = this._chan(u, msg.channelId);
    if (!this.repo) throw new ConvoyError('Not available.', 503);
    const user = await this.repo.findUserById(u.userId);
    const { realContactNumber } = require('./auth');
    const phone = user ? realContactNumber(user, 'phone') : '';
    if (!phone) throw new ConvoyError('Add a phone number to your profile first.', 409, 'NO_PHONE');
    const name = String(user.name || '').trim().split(/\s+/)[0].slice(0, 20);
    const to = this._other(c, u.userId);
    this._send(to, { type: 'PR_CONTACT_SHARED', channelId: c.channelId, name, phone });
    this._logContact({ ref: c.channelId, fromId: u.userId, toId: to, kind: 'SHARE_CONTACT', delivered: true }, now);
    return { type: 'PR_SHARE_CONTACT_OK', channelId: c.channelId };
  }

  closeChannel(u, msg, now) {
    const c = this._chan(u, msg.channelId);
    c.closed = true; c.expiresAt = Math.min(c.expiresAt, now);
    this._stopSharing(c);
    this._replicate({ op: 'CHAN', c });
    this._send(this._other(c, u.userId), { type: 'PR_CHANNEL', channelId: c.channelId, state: 'CLOSED' });
    return { type: 'PR_CHANNEL', channelId: c.channelId, state: 'CLOSED' };
  }

  /** The other rider of a request or chat I am part of. */
  _counterpart(u, ref) {
    if (typeof ref === 'string' && REQ_ID.test(ref)) {
      const q = this.requests.get(ref);
      if (q && (q.fromId === u.userId || (q.toId === u.userId && !q.silent))) return { other: q.fromId === u.userId ? q.toId : q.fromId, log: q.log, mine: q.fromId === u.userId ? 'A' : 'B', q };
    }
    if (typeof ref === 'string' && CH_ID.test(ref)) {
      const c = this.channels.get(ref);
      if (c && (c.a === u.userId || c.b === u.userId)) return { other: this._other(c, u.userId), log: c.log, mine: c.a === u.userId ? 'A' : 'B', c };
    }
    throw new ConvoyError('Nothing to report here.', 404, 'REF_GONE');
  }

  async report(u, msg, now) {
    const x = this._counterpart(u, msg.ref);
    if (!this._rateOk(`rep:${u.userId}`, DAY, 20, now)) throw new ConvoyError('Slow down.', 429, 'RATE');
    const reportId = await this._report(u.userId, x.other, msg.ref, msg.reason, msg.text, x.log, x.mine, now);
    if (msg.block === true) await this.block(u.userId, x.other, now);
    return { type: 'PR_REPORT_OK', ref: msg.ref, reportId };
  }

  /**
   * 3.55 ride chat: a rider reports a group ride chat message (socket CHAT_REPORT). Stored with the
   * public ride reports (same admin queue, same 20 a day budget); the transcript holds only the
   * reported rider's and the reporter's last lines up to that message. Never tells the sender.
   */
  async reportGroupChat(u, room, msg, now = this.clock()) {
    const messageId = String((msg && msg.messageId) || '').slice(0, 40);
    const list = (room && room.messages) || [];
    const idx = list.findIndex((m) => m.messageId === messageId);
    if (idx < 0) throw new ConvoyError('Nothing to report here.', 404, 'REF_GONE');
    const target = list[idx];
    const author = target.senderId === 'SYSTEM' ? (target.requestedBy || '') : target.senderId;
    if (!author || author === u.userId) throw new ConvoyError('Nothing to report here.', 400, 'REF_GONE');
    if (!this._rateOk(`rep:${u.userId}`, DAY, 20, now)) throw new ConvoyError('Slow down.', 429, 'RATE');
    const log = [];
    for (const m of list.slice(0, idx + 1)) {
      const who = m.senderId === 'SYSTEM' ? (m.requestedBy || '') : m.senderId;
      if (who === author) log.push({ by: 'B', text: m.text || '', quick: m.isQuickCard ? String(m.cardType || '') : '', at: m.timestamp });
      else if (who === u.userId) log.push({ by: 'A', text: m.text || '', quick: m.isQuickCard ? String(m.cardType || '') : '', at: m.timestamp });
    }
    const reportId = await this._report(u.userId, author, `CHAT:${room.groupId}:${messageId}`, msg.reason, msg.text, log, 'A', now);
    return { type: 'CHAT_REPORT_OK', messageId, reportId };
  }

  async _report(reporterId, reportedId, ref, reason, note, log, mine, now) {
    const r = REPORT_REASONS.has(reason) ? reason : 'OTHER';
    const n = typeof note === 'string' ? note.replace(/[\u0000-\u001F\u007F]/g, ' ').trim().slice(0, 140) : '';
    const reportId = `RPT-${hex(6)}`;
    const transcript = (log || []).slice(-30).map((l) => ({ from: l.by === mine ? 'REPORTER' : 'REPORTED', quick: l.quick || '', text: l.text || '', at: l.at }));
    this._store({ k: 'report', reportId, at: now, reporterId, reportedId, ref: String(ref || ''), reason: r, note: n, transcript, status: 'OPEN' });
    return reportId;
  }

  blockRef(u, msg, now) {
    const x = this._counterpart(u, msg.ref);
    if (x.q) this._closeRequest(x.q);
    if (x.c && !x.c.closed) { x.c.closed = true; this._stopSharing(x.c); this._replicate({ op: 'CHAN', c: x.c }); this._send(x.other, { type: 'PR_CHANNEL', channelId: x.c.channelId, state: 'CLOSED' }); }
    this.block(u.userId, x.other, now);
    return { type: 'PR_BLOCK_OK', ref: msg.ref };
  }

  /** Blocks `blocked` for `blocker` (30 days). Blocked by 3 different riders in 30 days: public ride paused 7 days. */
  block(blocker, blocked, now = this.clock()) {
    if (!blocker || !blocked || blocker === blocked) return;
    const until = now + config.publicRideBlockDays * DAY;
    this.blocks.set(`${blocker}|${blocked}`, { at: now, until });
    this._replicate({ op: 'BLOCK', blocker, blocked, at: now, until });
    if (this.soda) this.soda.upsertBy(COLL, { k: 'block', blocker, blocked }, { k: 'block', blocker, blocked, at: now, until }).catch((e) => this.log.warn('[public-ride] block store failed', e.message));
    for (const c of this.channels.values()) {
      if (!c.closed && ((c.a === blocker && c.b === blocked) || (c.b === blocker && c.a === blocked))) {
        c.closed = true; this._stopSharing(c); this._replicate({ op: 'CHAN', c });
        this._send(blocked, { type: 'PR_CHANNEL', channelId: c.channelId, state: 'CLOSED' });
        this._send(blocker, { type: 'PR_CHANNEL', channelId: c.channelId, state: 'CLOSED' });
      }
    }
    const blockers = [...this.blocks].filter(([k, b]) => k.endsWith(`|${blocked}`) && b.until > now && now - b.at <= 30 * DAY).length;
    if (blockers >= config.publicRideSuspendBlocks && !this.suspendedUntil(blocked, now)) this.suspend(blocked, now + config.publicRideSuspendDays * DAY, now);
  }

  suspend(uid, until, now = this.clock()) {
    this.susp.set(uid, until);
    this._replicate({ op: 'SUSP', uid, until });
    if (this.soda) this.soda.upsertBy(COLL, { k: 'suspend', userId: uid }, { k: 'suspend', userId: uid, at: now, until }).catch(() => {});
    this._logContact({ ref: '', fromId: uid, toId: '', kind: until > now ? 'SUSPENDED' : 'UNSUSPENDED', delivered: false }, now);
  }

  _logContact(row, now) { this._store({ k: 'log', at: now, ...row }); }

  // ---------------------------------------------------------------- road warnings
  _warnsOn(uid, gid) {
    const room = this.convoys.rooms.get(gid);
    if (room && publicRideOf(room.meta.publicRide).on) return true;
    const p = this.prefs.get(uid);
    return !!(p && p.roadWarnings);
  }
  confirmed(w) { return w.by.length >= config.roadWarnConfirms; }

  roadWarn(u, gid, msg, now) {
    if (isGuest(u)) throw new ConvoyError('Sign in with an account to send road warnings.', 403, 'GUEST');
    if (!gid) throw new ConvoyError('Start or join a ride first.', 409, 'NOT_JOINED');
    const kind = String(msg.kind || '');
    if (!WARN_KINDS[kind]) throw new ConvoyError('Pick a warning.', 400, 'BAD_KIND');
    if (!this._warnsOn(u.userId, gid)) throw new ConvoyError('Turn on road warnings or Public ride first.', 403, 'ROAD_WARNINGS_OFF');
    if (this.suspendedUntil(u.userId, now)) throw new ConvoyError('Public ride is paused for your account.', 403, 'SUSPENDED');
    const falses = (this.falseWarns.get(u.userId) || []).filter((x) => now - x < DAY);
    if (falses.length >= 3) throw new ConvoyError('Road warnings are paused for your account today.', 403, 'WARN_PAUSED');
    const me = this._pos(u.userId, gid, now);
    if (!me) throw new ConvoyError('Waiting for GPS.', 409, 'NO_POSITION');
    // An existing warning of the same kind close by: this report confirms it.
    for (const w of this.warnings.values()) {
      if (w.kind === kind && haversine(w.lat, w.lng, me.lat, me.lng) <= config.roadWarnMergeM) {
        if (w.reporterId !== u.userId && !w.by.includes(u.userId)) this._confirm(w, u.userId, now);
        return { type: 'ROAD_WARN_SENT', warnId: w.warnId, merged: true, confirmations: w.by.length };
      }
    }
    if (!this._rateOk(`w10:${u.userId}`, 10 * MIN, 3, now) || !this._rateOk(`wday:${u.userId}`, DAY, 12, now)) throw new ConvoyError('Slow down.', 429, 'RATE');
    const ttl = WARN_KINDS[kind].ttlMin * MIN;
    const w = {
      warnId: `RW-${hex(6)}`, kind, lat: me.lat, lng: me.lng, heading: (Number(me.speedKmh) || 0) >= 5 && Number.isFinite(Number(me.heading)) ? Number(me.heading) : null,
      reporterId: u.userId, by: [u.userId], gone: [], at: now, expiresAt: now + ttl, hardEnd: now + WARN_HARD_END_MS,
    };
    this.warnings.set(w.warnId, w);
    this._replicate({ op: 'WARN', w });
    this._logContact({ ref: w.warnId, fromId: u.userId, toId: '', kind: 'ROAD_WARN', quick: kind, delivered: true }, now);
    this.stats.warnings++;
    this._matchWarning(w, now);
    return { type: 'ROAD_WARN_SENT', warnId: w.warnId, merged: false, confirmations: 1 };
  }

  _confirm(w, uid, now) {
    const was = this.confirmed(w);
    if (!w.by.includes(uid)) w.by.push(uid);
    w.gone = w.gone.filter((x) => x !== uid);
    w.expiresAt = Math.min(w.hardEnd, Math.max(w.expiresAt, now + WARN_KINDS[w.kind].ttlMin * MIN));
    this._replicate({ op: 'WARN', w });
    if (!was && this.confirmed(w)) this._matchWarning(w, now);
  }

  vote(u, msg, now) {
    const w = typeof msg.warnId === 'string' && WARN_ID.test(msg.warnId) ? this.warnings.get(msg.warnId) : null;
    // Only riders who got the warning (or reported it) vote.
    if (!w || (!this.warnSent.get(w.warnId)?.has(u.userId) && !w.by.includes(u.userId))) throw new ConvoyError('This warning has ended.', 404, 'WARN_GONE');
    if (isGuest(u)) throw new ConvoyError('Sign in with an account to confirm warnings.', 403, 'GUEST');
    if (!this._rateOk(`v:${u.userId}`, MIN, 6, now)) throw new ConvoyError('Slow down.', 429, 'RATE');
    if (msg.still === true) { if (w.reporterId !== u.userId) this._confirm(w, u.userId, now); }
    else {
      if (!w.gone.includes(u.userId)) w.gone.push(u.userId);
      w.by = w.by.filter((x) => x !== u.userId || x === w.reporterId);
      if (w.gone.length >= 2 && w.gone.length >= w.by.length) {
        const list = (this.falseWarns.get(w.reporterId) || []).filter((x) => now - x < DAY);
        list.push(now); this.falseWarns.set(w.reporterId, list);
        this._clearWarning(w.warnId);
        return { type: 'ROAD_WARN_VOTE_OK', warnId: w.warnId, cleared: true };
      }
      this._replicate({ op: 'WARN', w });
    }
    return { type: 'ROAD_WARN_VOTE_OK', warnId: w.warnId, cleared: false, confirmations: w.by.length };
  }

  _clearWarning(id, { replicate = true } = {}) {
    if (!this.warnings.has(id)) return;
    this.warnings.delete(id);
    for (const uid of (this.warnSent.get(id) || new Map()).keys()) this._send(uid, { type: 'ROAD_WARNING_CLEAR', warnId: id }, { local: true });
    this.warnSent.delete(id);
    if (replicate) this._replicate({ op: 'WARN_DEL', id });
  }

  /**
   * How far ahead a warning lies for a rider coming toward it (metres), or null. On the rider's route
   * when both are on it; otherwise straight ahead along the rider's heading on the same road.
   */
  aheadOf(w, r, gid, reachM) {
    const speed = Number(r.speedKmh) || 0;
    const h = Number(r.heading);
    if (speed < 10 || !Number.isFinite(h)) return null;
    const d = haversine(r.lat, r.lng, w.lat, w.lng);
    if (d > reachM * 1.2 || d < 50) return null;
    const L = config.discoveryLateralM;
    const room = this.convoys.rooms.get(gid);
    const idx = room ? this.routes.forMeta(gid, room.meta) : null;
    if (idx) {
      const pr = projectNearest(idx, r.lat, r.lng);
      const pw = projectNearest(idx, w.lat, w.lng);
      if (pr && pw && pr.lateralM <= L && pw.lateralM <= L) {
        const dir = angleDiff(h, pr.segBearing) <= 90 ? 1 : -1;
        const ahead = (pw.alongM - pr.alongM) * dir;
        return ahead > 50 && ahead <= reachM ? ahead : null;
      }
    }
    if (w.heading !== null && w.heading !== undefined) {
      const diff = angleDiff(h, w.heading);
      if (diff > 45 && diff < 135) return null; // a crossing road
    }
    const ca = crossAlongHeading(r.lat, r.lng, h, w.lat, w.lng);
    if (ca.along <= 50 || ca.along > reachM || ca.cross > L + 0.05 * ca.along) return null;
    return ca.along;
  }

  _matchWarnings(now) { if (this.warnings.size) for (const w of this.warnings.values()) this._matchWarning(w, now); }

  _matchWarning(w, now) {
    const conf = this.confirmed(w);
    const reach = conf ? config.roadWarnReachM : config.roadWarnNearM;
    const state = conf ? 'C' : 'U';
    let sent = this.warnSent.get(w.warnId);
    for (const [uid, gid] of this._localUsers()) {
      if (uid === w.reporterId || (sent && (sent.get(uid) === state || sent.get(uid) === 'C'))) continue;
      if (!this._warnsOn(uid, gid) || this._hasOpen(gid)) continue;
      const r = this._pos(uid, gid, now);
      if (!r) continue;
      const ahead = this.aheadOf(w, r, gid, reach);
      if (ahead === null) continue;
      const by = w.heading === null || w.heading === undefined ? 'NEARBY' : (angleDiff(Number(r.heading), w.heading) >= 135 ? 'ONCOMING' : 'AHEAD');
      if (!sent) { sent = new Map(); this.warnSent.set(w.warnId, sent); }
      sent.set(uid, state);
      this._send(uid, {
        type: 'ROAD_WARNING', warnId: w.warnId, kind: w.kind, label: WARN_KINDS[w.kind].label, aheadKm: Math.max(1, Math.round(ahead / 1000)),
        lat: r3(w.lat), lng: r3(w.lng), confirmed: conf, confirmations: w.by.length, by, reportedAt: w.at, expiresAt: w.expiresAt,
      }, { local: true });
    }
  }

  // ---------------------------------------------------------------- lifecycle
  /** CONFIG changed: a ride made private leaves the index at once. */
  onConfig(gid) {
    const room = this.convoys.rooms.get(gid);
    const s = room ? publicRideOf(room.meta.publicRide) : null;
    const id = this.rideOfGid.get(gid);
    if (id && (!s || !s.on || s.id !== id)) this._unpublish(gid, id);
  }

  onRoomEnded(gid) {
    const id = this.rideOfGid.get(gid);
    if (id) this._unpublish(gid, id);
    this.motion.delete(gid);
    this.routes.forget(gid);
  }

  /** Account erased: everything about the rider, here and in the database. */
  async forgetUser(uid) {
    this.prefs.delete(uid); this.lists.delete(uid); this.susp.delete(uid); this.sharing.delete(uid); this.falseWarns.delete(uid);
    for (const k of [...this.blocks.keys()]) if (k.startsWith(`${uid}|`) || k.endsWith(`|${uid}`)) this.blocks.delete(k);
    for (const [id, q] of [...this.requests]) if (q.fromId === uid || q.toId === uid) this.requests.delete(id);
    for (const [id, c] of [...this.channels]) if (c.a === uid || c.b === uid) this.channels.delete(id);
    for (const w of this.warnings.values()) { w.by = w.by.filter((x) => x !== uid); w.gone = w.gone.filter((x) => x !== uid); if (w.reporterId === uid) w.reporterId = ''; }
    if (!this.soda) return;
    for (const f of [{ fromId: uid }, { toId: uid }, { blocker: uid }, { blocked: uid }, { userId: uid }, { reporterId: uid }, { reportedId: uid }]) {
      await this.soda.removeWhere(COLL, f).catch(() => {});
    }
  }

  // ---------------------------------------------------------------- admin
  async listReports({ limit = 100, status } = {}) {
    if (!this.soda) return [];
    const rows = await this.soda.query(COLL, status ? { k: 'report', status } : { k: 'report' }, { orderBy: [{ path: 'at', datatype: 'number', order: 'desc' }], limit: Math.min(500, Math.max(1, limit)) });
    return rows.map((r) => r.value);
  }

  async listLog({ userId, limit = 200 } = {}) {
    if (!this.soda) return [];
    const q = async (f) => (await this.soda.query(COLL, { k: 'log', ...f }, { orderBy: [{ path: 'at', datatype: 'number', order: 'desc' }], limit: Math.min(1000, Math.max(1, limit)) })).map((r) => r.value);
    if (!userId) return q({});
    const rows = [...await q({ fromId: userId }), ...await q({ toId: userId })];
    return rows.sort((a, b) => b.at - a.at).slice(0, limit);
  }

  /**
   * Marks a report OPEN, REVIEWED or ACTIONED. `action` (DISMISS, WARN, SUSPEND) records what the
   * admin did on the report; WARN also writes a WARNED entry to the reported rider's contact log, so a
   * warning stays on their record for the next review.
   */
  async setReportStatus(reportId, status, { action, by = '', byUserId = null, days = 0, message = '' } = {}) {
    if (!this.soda || !['OPEN', 'REVIEWED', 'ACTIONED'].includes(status)) return false;
    if (action !== undefined && !REPORT_ACTIONS.has(action)) return false;
    const r = await this.soda.findOne(COLL, { k: 'report', reportId });
    if (!r) return false;
    const now = this.clock();
    const next = { ...r.value, status };
    if (action) Object.assign(next, { action, actionAt: now, actionBy: String(by || '').slice(0, 120), ...(action === 'SUSPEND' ? { actionDays: Math.max(0, Math.floor(Number(days) || 0)) } : {}) });
    // The admin record keeps the text the rider was sent (admins only; plain text).
    if (action === 'WARN') next.warnMessage = cleanMessage(message) || DEFAULT_MESSAGE;
    await this.soda.replace(COLL, r.key, next);
    if (action === 'WARN' && r.value.reportedId) {
      // 3.55: the warning is also delivered to the rider (src/admin_warnings.js, switch adminWarnings).
      let delivered = false;
      if (this.adminWarnings) {
        const w = await this.adminWarnings.warn(r.value.reportedId, message, { byUserId, ref: reportId }).catch((e) => { this.log.warn('[public-ride] warning delivery', e.message); return null; });
        delivered = !!(w && w.ok);
      }
      this._logContact({ ref: reportId, fromId: r.value.reportedId, toId: '', kind: 'WARNED', delivered }, now);
    }
    return true;
  }

  /** Reports with the riders' names and the reported rider's suspension (for the admin list). */
  async listReportsForAdmin(opts) {
    const reports = await this.listReports(opts);
    const ids = [...new Set(reports.flatMap((r) => [r.reporterId, r.reportedId]).filter(Boolean))].slice(0, 200);
    const names = new Map();
    if (this.repo && typeof this.repo.findUserById === 'function') {
      await Promise.all(ids.map(async (id) => {
        const u = await this.repo.findUserById(id).catch(() => null);
        if (u) names.set(id, String(u.callsign || u.name || u.displayName || '').trim());
      }));
    }
    const now = this.clock();
    return reports.map((r) => ({
      ...r,
      reporterName: names.get(r.reporterId) || '',
      reportedName: names.get(r.reportedId) || '',
      reportedSuspendedUntil: this.suspendedUntil(r.reportedId, now),
    }));
  }

  // ---------------------------------------------------------------- mirror extension ('pr')
  exportState() {
    return {
      idx: [...this.index.values()].filter((e) => e.local).map(({ local, cell, ...e }) => e),
      prefs: [...this.prefs],
      blocks: [...this.blocks],
      susp: [...this.susp],
      reqs: [...this.requests.values()],
      chans: [...this.channels.values()],
      warns: [...this.warnings.values()],
    };
  }

  importState(s) {
    if (!s || typeof s !== 'object') return;
    for (const e of s.idx || []) this.applyRemote({ op: 'IDX', id: e.rideId, e });
    for (const [uid, p] of s.prefs || []) { const cur = this.prefs.get(uid); if (!cur || cur.at <= p.at) this.prefs.set(uid, p); }
    for (const [k, b] of s.blocks || []) { const cur = this.blocks.get(k); if (!cur || cur.at <= b.at) this.blocks.set(k, b); }
    for (const [uid, until] of s.susp || []) this.susp.set(uid, Math.max(this.susp.get(uid) || 0, until));
    for (const q of s.reqs || []) this.applyRemote({ op: 'REQ', q });
    for (const c of s.chans || []) this.applyRemote({ op: 'CHAN', c });
    for (const w of s.warns || []) this.applyRemote({ op: 'WARN', w });
  }

  applyRemote(op) {
    if (!op || typeof op !== 'object') return;
    switch (op.op) {
      case 'IDX': {
        const cur = this.index.get(op.id);
        if (cur && cur.local) return; // ours is the fresher copy
        if (!op.e) { this._drop(op.id); return; }
        this._put({ ...op.e, local: false, at: this.clock() });
        return;
      }
      case 'PREFS': this.prefs.set(op.uid, op.p); return;
      case 'BLOCK': this.blocks.set(`${op.blocker}|${op.blocked}`, { at: op.at, until: op.until }); return;
      case 'SUSP': this.susp.set(op.uid, op.until); return;
      case 'REQ': {
        const cur = this.requests.get(op.q.requestId);
        if (cur && cur.state !== 'OPEN' && op.q.state === 'OPEN') return;
        this.requests.set(op.q.requestId, op.q);
        return;
      }
      case 'CHAN': {
        const cur = this.channels.get(op.c.channelId);
        if (cur && cur.closed && !op.c.closed) return;
        const c = { ...op.c, lastLoc: cur ? cur.lastLoc : undefined };
        this.channels.set(c.channelId, c);
        this._indexSharing(c);
        return;
      }
      case 'WARN': {
        const had = this.warnings.get(op.w.warnId);
        this.warnings.set(op.w.warnId, op.w);
        if (!had || (!this.confirmed(had) && this.confirmed(op.w))) this._matchWarning(op.w, this.clock());
        return;
      }
      case 'WARN_DEL': this._clearWarning(op.id, { replicate: false }); return;
      default:
    }
  }
}

/** Admin review: GET /reports, PATCH /reports/:id, GET /log?userId=, POST /users/:userId/suspension. */
function publicRideAdminRouter(publicRides) {
  const express = require('express');
  const r = express.Router();
  const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res)).catch(next);
  r.get('/reports', wrap(async (req, res) => res.set('Cache-Control', 'no-store').json({ reports: await publicRides.listReportsForAdmin({ limit: Number(req.query.limit) || 100, status: req.query.status || undefined }) })));
  // Body: { status: OPEN|REVIEWED|ACTIONED, action?: DISMISS|WARN|SUSPEND, days?, message? (WARN) }
  r.patch('/reports/:reportId', wrap(async (req, res) => {
    const action = req.body?.action === undefined ? undefined : String(req.body.action);
    if (action !== undefined && !REPORT_ACTIONS.has(action)) return res.status(400).json({ error: 'Unknown action.' });
    const by = req.user ? (req.user.email || req.user.userId || '') : '';
    // `message`: the admin's typed warning, sent to the rider with a WARN (src/admin_warnings.js).
    // When sent it is required (non-empty after trimming / cleaning) and at most 280 characters;
    // an older console that sends no `message` still delivers the default guidelines line.
    let message = '';
    if (action === 'WARN' && req.body?.message !== undefined && req.body?.message !== null) {
      const v = validateWarnMessage(req.body.message);
      if (!v.ok) return res.status(400).json({ error: v.error, code: v.code, max: MESSAGE_MAX });
      message = v.message;
    }
    const ok = await publicRides.setReportStatus(String(req.params.reportId || ''), String(req.body?.status || ''), { action, by, byUserId: req.user?.userId || null, days: req.body?.days, message });
    res.status(ok ? 200 : 404).json(ok ? { ok: true } : { error: 'Report not found.' });
  }));
  r.get('/log', wrap(async (req, res) => res.set('Cache-Control', 'no-store').json({ log: await publicRides.listLog({ userId: req.query.userId ? String(req.query.userId) : undefined, limit: Number(req.query.limit) || 200 }) })));
  r.post('/users/:userId/suspension', wrap(async (req, res) => {
    const days = Math.max(0, Math.min(365, Number(req.body?.days) || 0));
    const now = Date.now();
    publicRides.suspend(String(req.params.userId || ''), days ? now + days * DAY : 0, now);
    res.json({ ok: true, suspendedUntil: days ? now + days * DAY : 0 });
  }));
  return r;
}

module.exports = { PublicRides, publicRideAdminRouter, cleanText, snap, geohash, cellsFor, isGuest, QUICK, WARN_KINDS, CAP };
