'use strict';
/**
 * 3.55 buddy pairs (Large Group plan): in a big group each rider watches one buddy.
 *
 *  - Pairs are assigned deterministically (same riders, same ride -> same pairs): riders are put in
 *    the order of a hash of (groupId, userId) and paired one after the other; an odd rider makes the
 *    last pair a trio (a -> b -> c -> a, each rider still watches exactly one other).
 *  - Automatic once the ride has BUDDY_MIN_RIDERS riders (and no pairs yet); the lead (riding lead,
 *    owner or master admin) can (re)assign at any time with BUDDY_ASSIGN in a large ride (host seats
 *    >= 7 or riders >= 7).
 *  - A join or a leave re-pairs only the riders it touches: kept pairs stay, the orphan and the
 *    newcomer are paired, an odd one out joins (or breaks up) a trio.
 *  - Stored on the ride as meta.buddies {userId: buddyId}; in the snapshot as `buddies`; every
 *    change goes out as BUDDIES {buddies}.
 *  - BUDDY_PING {userId, kind: CHECK|OK}: a light "buddy ok?" (and its "I'm OK" answer) relayed only
 *    to that one rider, only between buddies, at most one CHECK per pair per 30 s.
 *
 * The gateway only assigns, stores and relays; deciding when to check on a buddy is the phone's job.
 */
const crypto = require('crypto');
const { ConvoyError } = require('./convoys');

const BUDDY_MIN_RIDERS = 7;
const PING_GAP_MS = 30000;
const PING_KINDS = new Set(['CHECK', 'OK']);

const rank = (groupId, userId) => crypto.createHash('sha256').update(`${groupId}:${userId}`).digest('hex');

/** Riders in their deterministic order for this ride. */
function ordered(groupId, ids) {
  const r = new Map(ids.map((id) => [id, rank(groupId, id)]));
  return [...new Set(ids)].sort((a, b) => (r.get(a) < r.get(b) ? -1 : r.get(a) > r.get(b) ? 1 : (a < b ? -1 : 1)));
}

/** [[a,b],[c,d],[e,f,g]] -> {a:b,b:a,...,e:f,f:g,g:e}. */
function toMap(groups) {
  const out = {};
  for (const g of groups) {
    if (g.length < 2) continue;
    for (let i = 0; i < g.length; i++) out[g[i]] = g[(i + 1) % g.length];
  }
  return out;
}

/** Consecutive pairs; an odd last rider joins the last pair (a trio). */
function pairUp(list) {
  const groups = [];
  for (let i = 0; i + 1 < list.length; i += 2) groups.push([list[i], list[i + 1]]);
  if (list.length % 2 === 1 && groups.length) groups[groups.length - 1].push(list[list.length - 1]);
  return groups;
}

/** Fresh pairs for these riders (fewer than 2 riders: none). */
function assignBuddies(groupId, riderIds) {
  const ids = (riderIds || []).filter((x) => typeof x === 'string' && x);
  if (ids.length < 2) return {};
  return toMap(pairUp(ordered(groupId, ids)));
}

/** The pairs / trios of a stored map (cycles), in a deterministic order. Broken entries are dropped. */
function groupsOf(groupId, map) {
  const m = map && typeof map === 'object' && !Array.isArray(map) ? map : {};
  const seen = new Set();
  const groups = [];
  for (const start of ordered(groupId, Object.keys(m))) {
    if (seen.has(start)) continue;
    const cycle = [];
    let cur = start;
    while (typeof cur === 'string' && !seen.has(cur) && cycle.length < 4) { seen.add(cur); cycle.push(cur); cur = m[cur]; }
    if (cur === start && cycle.length >= 2 && cycle.length <= 3) groups.push(cycle);
  }
  return groups;
}

/**
 * Re-pairs after riders joined or left, keeping every pair whose riders are both still here.
 * Same inputs, same result.
 */
function repairBuddies(groupId, previous, riderIds) {
  const present = new Set((riderIds || []).filter((x) => typeof x === 'string' && x));
  if (present.size < 2) return {};
  const groups = groupsOf(groupId, previous).map((g) => g.filter((id) => present.has(id))).filter((g) => g.length >= 2);
  const paired = new Set(groups.flat());
  const loose = ordered(groupId, [...present].filter((id) => !paired.has(id)));
  for (let i = 0; i + 1 < loose.length; i += 2) groups.push([loose[i], loose[i + 1]]);
  if (loose.length % 2 === 1) {
    const odd = loose[loose.length - 1];
    const trio = groups.find((g) => g.length === 3);
    if (trio) groups.push([trio.pop(), odd]); // the trio becomes a pair, its last rider pairs with the odd one
    else if (groups.length) groups[0].push(odd);
  }
  return toMap(groups);
}

/** Whether a ride may use buddy pairs: host seats >= 7 or riders >= 7. */
function isLargeRide(convoys, room) {
  const seats = typeof convoys._storedCapacity === 'function' ? convoys._storedCapacity(room.meta) : 0;
  return seats >= BUDDY_MIN_RIDERS || room.riders.size >= BUDDY_MIN_RIDERS;
}

const sameMap = (a, b) => JSON.stringify(Object.entries(a || {}).sort()) === JSON.stringify(Object.entries(b || {}).sort());

class BuddyService {
  /** @param {import('./convoys').ConvoyManager} convoys */
  constructor(convoys, { logger, featureOn } = {}) {
    this.convoys = convoys;
    this.log = logger || console;
    this.featureOn = featureOn || ((id) => !convoys.featureFlags || convoys.featureFlags.isOn(id));
    this.chains = new Map();
    this.pingAt = new Map();
    convoys.on('event', (groupId, payload) => {
      const type = payload && payload.type;
      if (type === 'RIDER_LEFT' || (type === 'RIDER_UPDATE' && payload.joined === true)) {
        this._serial(groupId, () => this._onRoster(groupId)).catch((e) => this.log.warn('[buddies] re-pair failed', e.message));
      }
    });
    convoys.on('roomEnded', (groupId) => { this.chains.delete(groupId); for (const k of this.pingAt.keys()) if (k.startsWith(`${groupId}|`)) this.pingAt.delete(k); });
  }

  _serial(groupId, fn) {
    const prev = this.chains.get(groupId) || Promise.resolve();
    const run = prev.then(fn, fn);
    this.chains.set(groupId, run.catch(() => {}));
    return run;
  }

  async _store(room, buddies, byUserId) {
    room.meta.buddies = buddies;
    room.meta.buddiesAt = Date.now();
    this.convoys._touch(room);
    await this.convoys.repo.saveConvoyMeta(room.meta);
    this.convoys._emit(room.groupId, 'BUDDIES', { buddies, byUserId: byUserId || 'SYSTEM' });
  }

  /** A rider joined or left: re-pair (pairs exist) or pair for the first time (large ride reached 7). */
  async _onRoster(groupId) {
    if (this.convoys.passive && this.convoys.passive(groupId)) return; // the peer gateway runs this ride
    const room = this.convoys.rooms.get(groupId);
    if (!room || room.meta.tripStatus === 'ENDED') return;
    const ids = [...room.riders.keys()];
    const prev = room.meta.buddies && typeof room.meta.buddies === 'object' ? room.meta.buddies : {};
    const had = Object.keys(prev).length > 0;
    if (!had) {
      if (!this.featureOn('buddyPairs') || ids.length < BUDDY_MIN_RIDERS) return;
      await this._store(room, assignBuddies(groupId, ids));
      return;
    }
    const next = repairBuddies(groupId, prev, ids);
    if (!sameMap(prev, next)) await this._store(room, next);
  }

  /** BUDDY_ASSIGN by the lead: fresh pairs for everyone in the ride now. */
  async assign(groupId, user) {
    return this._serial(groupId, async () => {
      const room = await this.convoys.getRoom(groupId);
      const me = room.riders.get(user.userId);
      if (!me) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
      if (room.meta.tripStatus === 'ENDED') throw new ConvoyError('This ride has ended.', 409, 'TRIP_ENDED');
      const lead = me.role === 'LEAD' || room.meta.createdByUserId === user.userId || user.role === 'MASTER_ADMIN';
      if (!lead) throw new ConvoyError('Only the lead can assign buddies.', 403, 'NOT_AUTHORIZED');
      if (!isLargeRide(this.convoys, room)) throw new ConvoyError('Buddy pairs are for large groups (7 riders or more).', 403, 'PLAN_REQUIRED');
      if (room.riders.size < 2) throw new ConvoyError('Buddy pairs need at least two riders.', 409, 'TOO_FEW_RIDERS');
      const buddies = assignBuddies(groupId, [...room.riders.keys()]);
      await this._store(room, buddies, user.userId);
      return { buddies };
    });
  }

  /** BUDDY_PING: "buddy ok?" (CHECK) or the answer (OK), only between buddies, only to that rider. */
  async ping(groupId, user, msg = {}) {
    const room = await this.convoys.getRoom(groupId);
    const me = room.riders.get(user.userId);
    if (!me) throw new ConvoyError('Not a member of this convoy.', 403, 'NOT_MEMBER');
    const to = typeof msg.userId === 'string' && msg.userId.length <= 64 ? msg.userId : '';
    const kind = typeof msg.kind === 'string' && PING_KINDS.has(msg.kind.toUpperCase()) ? msg.kind.toUpperCase() : 'CHECK';
    const buddies = room.meta.buddies || {};
    if (!to || !room.riders.has(to) || to === user.userId || !(buddies[user.userId] === to || buddies[to] === user.userId)) {
      throw new ConvoyError('You can only check on your own buddy.', 403, 'NOT_BUDDY');
    }
    const t = Date.now();
    const key = `${groupId}|${user.userId}|${to}|${kind}`;
    if (t - (this.pingAt.get(key) || 0) < PING_GAP_MS) return { sent: false, throttled: true };
    this.pingAt.set(key, t);
    this.convoys.emit('userMessage', groupId, to, { type: 'BUDDY_PING', fromUserId: user.userId, fromName: me.name || user.name || '', kind, at: t });
    return { sent: true };
  }
}

module.exports = { BuddyService, assignBuddies, repairBuddies, groupsOf, isLargeRide, BUDDY_MIN_RIDERS, PING_GAP_MS };
