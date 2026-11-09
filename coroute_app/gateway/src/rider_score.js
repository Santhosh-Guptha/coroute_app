'use strict';
/**
 * 3.55 rider score (docs/features_355/rider_score.md).
 *
 * A private 0-100 score of HOW SAFELY someone rides, built from data the gateway already has for
 * every group ride (the trip report: distance, riding time, stops; the timeline: OVERSPEED episodes
 * with limit and top speed, SEPARATED episodes) plus, when the rider allows it, a few per-ride counts
 * from the phone's private ride safety report (hard brakes, breaks, highest tiredness, minutes over
 * the limit). No raw track, no position and no time of day is ever used or stored here.
 *
 * Rules that must never change:
 *  - Speed is never rewarded: average and top speed are not inputs. Only time OVER the effective limit
 *    (group / town limit on the server, the phone's limit check) lowers the speed component.
 *  - SOS, crash alarms, "Bike down?" checks, possible-incident (hard stop) entries and false alarms
 *    are never read: using SOS must never cost a rider anything.
 *  - Breaks never lower a score; riding long stretches without one does.
 *
 * Storage: one document per rider in `rider_scores` (unique userId): the last RIDES_MAX ride facts
 * (numbers only), folded totals for older rides, the computed score and flat `lb*` fields the public
 * leaderboard sorts on. Writes are compare-and-replace (two nodes finishing reports never lose a ride).
 */

const COLLECTION = 'rider_scores';
const MIN_RIDES = 3;
const MIN_RIDE_KM = 10;
const HALF_LIFE_DAYS = 60;
const RIDES_MAX = 400;
const PENDING_MAX = 60;
const PENDING_TTL_MS = 14 * 864e5;
const EPISODES_MAX = 60;
const DAY = 864e5;
const WEIGHTS = Object.freeze({ speedDiscipline: 40, smoothness: 25, safety: 25, consistency: 10 });
/** Overall cap while the speed component cannot be measured (no limit on any counted ride). */
const NO_SPEED_CAP = 70;
const LEVELS = Object.freeze([
  { min: 85, name: 'Ace Rider' },
  { min: 70, name: 'Skilled' },
  { min: 50, name: 'Steady' },
  { min: 0, name: 'Learner' },
]);
/** A ride above these is kept for the rider's own score but never counted on the public leaderboard. */
const BOARD_MAX_RIDE_KM = 2000;
const BOARD_MAX_AVG_KMH = 150;
const RANK_SCAN_MAX = 20000;

const USERNAME_RE = /^[A-Za-z0-9._-]{2,32}$/;
/** A user's public leaderboard handle, or null when they must not be shown (no username, opted out, not active). */
function publicHandle(user) {
  if (!user || user.publicLeaderboard === false) return null;
  if (user.status && user.status !== 'ACTIVE') return null;
  const u = typeof user.username === 'string' ? user.username.trim() : '';
  return USERNAME_RE.test(u) ? u : null;
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const num = (v, max = 1e12) => { const n = Number(v); return Number.isFinite(n) && n >= 0 ? Math.min(n, max) : 0; };
const decay = (ageMs) => Math.pow(0.5, Math.max(0, ageMs) / (HALF_LIFE_DAYS * DAY));
const levelOf = (score) => (score == null ? null : LEVELS.find((l) => score >= l.min).name);

/** How heavily one minute over the limit weighs, by how far over (top speed of the episode vs its limit). */
function overWeight(pct) {
  if (pct >= 0.4) return 8;
  if (pct >= 0.25) return 4;
  if (pct >= 0.1) return 2;
  return 1;
}

/**
 * Speed discipline of one ride (0-100) or null when nothing tells us the limit (no group / town limit
 * and no phone count). Higher speed under the limit changes nothing.
 */
function rideSpeed(r) {
  const phoneOver = r.phone && Number.isFinite(r.phone.ol) ? r.phone.ol : null;
  if (!r.speedKnown && phoneOver == null) return null;
  const movingMin = Math.max(1, num(r.movingMs) / 60000);
  let serverOverMin = 0;
  let weighted = 0;
  let severe = 0;
  for (const e of r.episodes || []) {
    const lim = num(e.limitKmh, 300);
    if (!lim) continue;
    const pct = Math.max(0, (num(e.maxKmh, 400) - lim) / lim);
    const min = Math.max(0.05, num(e.durMs) / 60000); // a held episode is at least a few seconds
    serverOverMin += min;
    weighted += min * overWeight(pct);
    if (pct >= 0.4) severe++;
  }
  // Minutes the phone saw over its limit that the server did not (e.g. a road limit): unknown margin.
  const extra = Math.max(0, (phoneOver || 0) - serverOverMin);
  weighted += extra * 1.5;
  const s = 100 - 100 * Math.min(1, (3 * weighted) / movingMin) - 10 * severe;
  return clamp(Math.round(s * 10) / 10, 0, 100);
}

/** Smoothness of one ride from the phone's hard-brake count per 100 km, or null without phone data. */
function rideSmooth(r) {
  if (!r.phone || !Number.isFinite(r.phone.hb)) return null;
  const per100 = (r.phone.hb * 100) / Math.max(num(r.km), MIN_RIDE_KM);
  return clamp(Math.round(100 * Math.exp(-per100 / 10) * 10) / 10, 0, 100);
}

/** Safety habits of one ride: breaks on long rides, staying with the group. Never SOS / crash. */
function rideSafety(r) {
  let s = 100;
  if (r.longestStretchMs != null) {
    const h = num(r.longestStretchMs) / 3600000;
    if (h > 2.5) s -= Math.min(30, (h - 2) * 15);
  } else if (r.phone && num(r.phone.fp) >= 80 && num(r.phone.br) === 0) {
    s -= 10; // very tired and never stopped (only when the server could not see the stops)
  }
  if ((r.groupSize || 0) >= 2) {
    const sep = num(r.separatedCount, 1000);
    s -= Math.min(20, Math.max(0, sep - 1) * 5); // getting separated once happens; repeatedly is a habit
    if (num(r.movingMs) > 0 && num(r.separatedMs) / num(r.movingMs) > 0.25) s -= 10;
  }
  return clamp(Math.round(s * 10) / 10, 0, 100);
}

/** Rides regularly: share of the last 13 fortnights with a counted ride, recent fortnights weigh more. */
function consistencyOf(counted, now) {
  let total = 0, hit = 0;
  for (let i = 0; i < 13; i++) {
    const to = now - i * 14 * DAY, from = to - 14 * DAY;
    const w = decay(now - (from + to) / 2);
    total += w;
    if (counted.some((r) => r.endedAt > from && r.endedAt <= to)) hit += w;
  }
  return total ? Math.round((1000 * hit) / total) / 10 : 0;
}

function tipsFor(components, counted, now) {
  const tips = [];
  const recent = counted.filter((r) => now - r.endedAt <= 90 * DAY);
  const severe = recent.reduce((n, r) => n + (r.episodes || []).filter((e) => e.limitKmh && (e.maxKmh - e.limitKmh) / e.limitKmh >= 0.4).length, 0);
  if (severe > 0) tips.push(`You went far over the limit ${severe === 1 ? 'once' : `${severe} times`} in recent rides. Ease off early; the limit is there for what you cannot see.`);
  if (components.speedDiscipline != null && components.speedDiscipline < 85) tips.push('Keep within the limit on highways, where speed creeps up without you noticing.');
  if (components.speedDiscipline == null) tips.push('Set a group speed limit for your rides (or use the ride safety report) so your speed discipline can count.');
  if (components.smoothness != null && components.smoothness < 75) tips.push('Leave more gap to the vehicle ahead so you rarely need to brake hard.');
  if (components.smoothness == null) tips.push('Turn on "Use my ride safety report for my rider score" in Settings to include smoothness.');
  const long = recent.filter((r) => r.longestStretchMs != null && r.longestStretchMs > 2.5 * 3600000).length;
  if (long > 0) tips.push('Take a 10-minute break at least every 2 hours on long rides.');
  const sep = recent.filter((r) => (r.separatedCount || 0) > 1).length;
  if (sep > 0) tips.push('Keep the rider ahead in sight and use regroup points so you are not separated from the group.');
  if (components.consistency != null && components.consistency < 40) tips.push('Short, regular rides keep your skills sharp.');
  if (!tips.length) tips.push('Great riding. Keep it smooth and within the limit.');
  return tips.slice(0, 4);
}

function totalsOf(rides, archived = null) {
  const t = { km: num(archived?.km), movingMs: num(archived?.movingMs), rides: num(archived?.rides), longestKm: num(archived?.longestKm) };
  for (const r of rides) {
    if (!boardOk(r)) continue;
    t.km += num(r.km);
    t.movingMs += num(r.movingMs);
    if (num(r.km) >= MIN_RIDE_KM) t.rides++;
    t.longestKm = Math.max(t.longestKm, num(r.km));
  }
  return t;
}

/** A plausible ride for public totals (server stats are from real tracks; device numbers are capped). */
function boardOk(r) {
  const km = num(r.km);
  const h = num(r.movingMs) / 3600000;
  if (km > BOARD_MAX_RIDE_KM) return false;
  if (km > 1 && h > 0 && km / h > BOARD_MAX_AVG_KMH) return false;
  if (km > 1 && h === 0) return false;
  return true;
}

/**
 * Pure: the score of one rider from their stored ride facts at `now`.
 * @returns {{score:number|null, level:string|null, components:object, ridesCounted:number, minRides:number, tips:string[]}}
 */
function computeScore(rides, now = Date.now(), { minRides = MIN_RIDES } = {}) {
  const counted = (rides || []).filter((r) => num(r.km) >= MIN_RIDE_KM && num(r.endedAt) > 0 && r.endedAt <= now + DAY);
  const comp = (fn) => {
    let sw = 0, sv = 0;
    for (const r of counted) {
      const v = fn(r);
      if (v == null) continue;
      const w = decay(now - r.endedAt) * clamp(num(r.movingMs) / 3600000, 0.25, 4);
      sw += w; sv += w * v;
    }
    return sw > 0 ? Math.round((10 * sv) / sw) / 10 : null;
  };
  const components = {
    smoothness: comp(rideSmooth),
    speedDiscipline: comp(rideSpeed),
    safety: comp(rideSafety),
    consistency: counted.length ? consistencyOf(counted, now) : null,
  };
  const ridesCounted = counted.length;
  let score = null;
  if (ridesCounted >= minRides) {
    let w = 0, v = 0;
    for (const [k, weight] of Object.entries(WEIGHTS)) {
      if (components[k] == null) continue;
      w += weight; v += weight * components[k];
    }
    score = w ? Math.round(v / w) : null;
    if (score != null && components.speedDiscipline == null) score = Math.min(score, NO_SPEED_CAP);
  }
  const rounded = {};
  for (const k of Object.keys(components)) rounded[k] = components[k] == null ? null : Math.round(components[k]);
  return {
    score, level: levelOf(score), components: rounded, ridesCounted, minRides,
    tips: ridesCounted ? tipsFor(components, counted, now) : [`Ride ${minRides} rides of ${MIN_RIDE_KM} km or more to get your rider score.`],
  };
}

/** Longest riding stretch without a break of 10 minutes or more, from the report's stop list. */
function longestStretch(firstTs, lastTs, stops) {
  if (!(lastTs > firstTs)) return null;
  const breaks = (stops || []).filter((s) => num(s.durationMs) >= 10 * 60000).sort((a, b) => a.startTs - b.startTs);
  let prev = firstTs, best = 0;
  for (const b of breaks) { best = Math.max(best, b.startTs - prev); prev = Math.max(prev, b.endTs); }
  return Math.max(best, lastTs - prev);
}

/**
 * Ride facts of one member from a finished trip report (numbers only, no coordinates, no names).
 * `events` are the convoy's timeline entries; only this rider's OVERSPEED and SEPARATED are read.
 */
function rideFactsFromReport({ meta, stats, analysis, events, tripId }) {
  const mine = (events || []).filter((e) => e.userId === stats.userId);
  const episodes = mine.filter((e) => e.type === 'OVERSPEED').slice(0, EPISODES_MAX).map((e) => ({
    limitKmh: num(e.data?.limitKmh, 300), maxKmh: num(e.data?.maxKmh, 400), durMs: num(e.durationMs, 864e5),
  }));
  const sep = mine.filter((e) => e.type === 'SEPARATED');
  const hasTrack = !!(analysis && analysis.points && analysis.points.length >= 2);
  return {
    rideId: tripId,
    endedAt: num(stats.lastFixAt) || num(stats.leftAt) || num(meta.endedAtEpochMs) || Date.now(),
    km: Math.round(num(stats.distanceM, 5e6) / 100) / 10,
    movingMs: num(stats.movingMs, 7 * DAY),
    source: stats.statsSource || 'server',
    speedKnown: num(meta.speedLimitKmh) > 0 || num(meta.townLimitKmh) > 0,
    episodes,
    separatedCount: sep.length,
    separatedMs: sep.reduce((s, e) => s + num(e.durationMs, DAY), 0),
    groupSize: Object.keys(meta.members || {}).length,
    longestStretchMs: hasTrack ? longestStretch(analysis.firstTs, analysis.lastTs, analysis.stops) : null,
    phone: null,
  };
}

/** The phone's per-ride counts (ride safety report), validated. Never a position, time or track. */
function phoneCounts(body) {
  const b = body && typeof body === 'object' ? body : {};
  const int = (k, max) => { const v = Number(b[k]); return Number.isFinite(v) && v >= 0 ? Math.min(Math.round(v), max) : 0; };
  return { hb: int('hardBrakes', 1000), br: int('breaks', 100), fp: int('fatiguePeak', 100), fn: int('fatiguePrompts', 100), ol: int('overLimitMin', 1440) };
}

class RiderScoreService {
  /** @param {{soda:any, repo:any, flagsOf?:() => any, logger?:any, clock?:() => number}} opts */
  constructor({ soda, repo, flagsOf = () => null, logger = console, clock = Date.now }) {
    this.soda = soda; this.repo = repo; this.flagsOf = flagsOf; this.log = logger; this.now = clock;
    this._ready = null;
    this.stats = { ridesRecorded: 0, recomputed: 0 };
  }

  enabled() { const f = this.flagsOf(); return !f || f.isOn('riderScore'); }

  init() {
    if (!this._ready) {
      this._ready = (async () => {
        await this.soda.ensureCollection(COLLECTION);
        await this.soda.ensureIndex(COLLECTION, { name: 'rider_scores_user_ux', unique: true, fields: [{ path: 'userId' }] });
        await this.soda.ensureIndex(COLLECTION, { name: 'rider_scores_board_ix', fields: [{ path: 'eligible' }] });
      })().catch((e) => { this._ready = null; throw e; });
    }
    return this._ready;
  }

  async _get(userId) {
    await this.init();
    return this.soda.findOne(COLLECTION, { userId: String(userId) });
  }

  /** Read-modify-write of one rider's document (compare-and-replace, retried). */
  async _mutate(userId, fn) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const row = await this._get(userId);
      const base = row ? row.value : { userId: String(userId), rides: [], pending: {}, archived: null };
      const user = await this.repo.findUserById(String(userId)).catch(() => null);
      const next = this._finish(fn(structuredClone(base)));
      next.lbPublic = !!publicHandle(user); // refreshed on every write and by the daily job (used for ranks)
      if (!row) {
        try { await this.soda.insert(COLLECTION, next); return next; } catch (e) { if (e.status === 409) continue; throw e; }
      }
      if (await this.soda.compareAndReplace(COLLECTION, row.key, row.value, next)) return next;
    }
    throw new Error('[rider-score] busy, try again');
  }

  /** Caps the ride list, drops stale pending phone counts and refreshes the score + board fields. */
  _finish(doc) {
    const now = this.now();
    doc.rides = (doc.rides || []).sort((a, b) => b.endedAt - a.endedAt);
    if (doc.rides.length > RIDES_MAX) {
      const old = doc.rides.splice(RIDES_MAX);
      const t = totalsOf(old, doc.archived);
      doc.archived = t;
    }
    for (const [k, v] of Object.entries(doc.pending || {})) if (!v || now - (v.at || 0) > PENDING_TTL_MS) delete doc.pending[k];
    const keys = Object.keys(doc.pending || {});
    if (keys.length > PENDING_MAX) for (const k of keys.sort((a, b) => doc.pending[a].at - doc.pending[b].at).slice(0, keys.length - PENDING_MAX)) delete doc.pending[k];
    const s = computeScore(doc.rides, now);
    const t = totalsOf(doc.rides, doc.archived);
    Object.assign(doc, {
      score: s.score, level: s.level, components: s.components, ridesCounted: s.ridesCounted, minRides: s.minRides, tips: s.tips,
      updatedAt: now,
      eligible: s.ridesCounted >= MIN_RIDES && t.rides >= MIN_RIDES,
      lbScore: s.score == null ? -1 : s.score,
      lbKm: Math.round(t.km), lbHours: Math.round(t.movingMs / 360000) / 10, lbRides: t.rides, lbLongestKm: Math.round(t.longestKm),
    });
    return doc;
  }

  /** Adds or replaces one ride (idempotent by rideId: a report rebuilt after late uploads replaces it). */
  async recordRide(userId, facts) {
    if (!userId || !facts?.rideId) return null;
    const out = await this._mutate(userId, (doc) => {
      const prev = doc.rides.find((r) => r.rideId === facts.rideId);
      const pending = doc.pending?.[facts.rideId];
      const ride = { ...facts, phone: pending ? pending.c : (facts.phone || prev?.phone || null) };
      if (pending) delete doc.pending[facts.rideId];
      doc.rides = doc.rides.filter((r) => r.rideId !== facts.rideId).concat([ride]);
      return doc;
    });
    this.stats.ridesRecorded++;
    return out;
  }

  /** Phone counts for one ride (POST /me/score/rides). Merged now, or kept until the ride's report is built. */
  async submitPhoneCounts(userId, groupId, body) {
    const rideId = `TRIP-${String(groupId).replace('GRP-', '')}-${userId}`;
    const c = phoneCounts(body);
    return this._mutate(userId, (doc) => {
      const ride = doc.rides.find((r) => r.rideId === rideId);
      if (ride) ride.phone = c;
      else { doc.pending = doc.pending || {}; doc.pending[rideId] = { c, at: this.now() }; }
      return doc;
    });
  }

  /** Removes the phone counts the rider had sent (setting switched off). Server facts stay. */
  async clearPhoneCounts(userId) {
    const row = await this._get(userId);
    if (!row) return;
    await this._mutate(userId, (doc) => { for (const r of doc.rides) r.phone = null; doc.pending = {}; return doc; });
  }

  /** Hook from TimelineEngine.finishTrip: one ride per analysed member that kept a trip document. */
  async onTripFinished({ meta, perMember, events }) {
    for (const pm of perMember || []) {
      if (pm.reused || !pm.tripDoc || !pm.stats) continue;
      try {
        if (!(await this.repo.findUserById(pm.userId))) continue;
        await this.recordRide(pm.userId, rideFactsFromReport({ meta, stats: pm.stats, analysis: pm.analysis, events, tripId: pm.tripDoc.tripId }));
      } catch (e) { this.log.warn?.(`[rider-score] ride not recorded: ${e.message}`); }
    }
  }

  /** GET /me/score body (contract in docs/features_355/rider_score.md). */
  async scoreOf(userId) {
    const row = await this._get(userId);
    const doc = row?.value;
    // Recomputed on every read (decay moves with time); the stored copy is refreshed by rides and the daily job.
    const s = doc ? computeScore(doc.rides, this.now()) : computeScore([], this.now());
    return {
      score: s.score, level: s.level, components: s.components, ridesCounted: s.ridesCounted, minRides: s.minRides,
      updatedAt: doc?.updatedAt || null, tips: s.tips,
    };
  }

  /** Admin user detail: the breakdown plus per-ride numbers (no coordinates). */
  async adminView(userId) {
    const row = await this._get(userId).catch(() => null);
    if (!row) return null;
    const d = row.value;
    const s = computeScore(d.rides, this.now());
    return {
      ...s, updatedAt: d.updatedAt || null,
      totals: { km: d.lbKm || 0, hours: d.lbHours || 0, rides: d.lbRides || 0, longestKm: d.lbLongestKm || 0 },
      recentRides: (d.rides || []).slice(0, 20).map((r) => ({
        rideId: r.rideId, endedAt: r.endedAt, km: r.km, movingMin: Math.round(num(r.movingMs) / 60000),
        speed: rideSpeed(r), smoothness: rideSmooth(r), safety: rideSafety(r),
        overspeedEpisodes: (r.episodes || []).length, separated: r.separatedCount || 0, phoneCounts: !!r.phone,
      })),
    };
  }

  /**
   * The rider's own position on each public board (1 + riders with a higher value; ties share a place).
   * Null on a board when the rider is not on the public leaderboard (no username, opted out, too few rides).
   */
  async ranksOf(userId) {
    const row = await this._get(userId);
    const user = await this.repo.findUserById(String(userId)).catch(() => null);
    const username = publicHandle(user);
    const d = row?.value;
    const boards = { topScore: 'lbScore', longestRide: 'lbLongestKm', mostKm: 'lbKm', mostHours: 'lbHours', mostRides: 'lbRides' };
    const ranks = {};
    const on = !!(d && d.eligible && username);
    for (const [name, path] of Object.entries(boards)) {
      if (!on || !(Number(d[path]) > (path === 'lbScore' ? -1 : 0))) { ranks[name] = null; continue; }
      let above = 0;
      for (let offset = 0; offset < RANK_SCAN_MAX; offset += 1000) {
        const rows = await this.soda.query(COLLECTION, { eligible: true, lbPublic: true, [path]: { $gt: d[path] } }, { limit: 1000, offset, fields: 'id' });
        above += rows.length;
        if (rows.length < 1000) break;
      }
      ranks[name] = above + 1;
    }
    return { username, onLeaderboard: on, ranks };
  }

  /** Daily job: recompute every stored score (decay and consistency move with time). */
  async recomputeAll({ signal } = {}) {
    await this.init();
    let offset = 0, n = 0;
    for (;;) {
      if (signal?.aborted) break;
      const rows = await this.soda.query(COLLECTION, {}, { limit: 200, offset });
      for (const r of rows) {
        try { await this._mutate(r.value.userId, (doc) => doc); n++; } catch (e) { this.log.warn?.(`[rider-score] recompute: ${e.message}`); }
      }
      if (rows.length < 200) break;
      offset += rows.length;
    }
    this.stats.recomputed += n;
    return n;
  }

  /** Account erase. */
  async removeUser(userId) {
    await this.init();
    await this.soda.removeWhere(COLLECTION, { userId: String(userId) });
  }
}

module.exports = {
  RiderScoreService, computeScore, rideSpeed, rideSmooth, rideSafety, consistencyOf, rideFactsFromReport, longestStretch,
  phoneCounts, levelOf, overWeight, boardOk, totalsOf, publicHandle, USERNAME_RE,
  COLLECTION, MIN_RIDES, MIN_RIDE_KM, HALF_LIFE_DAYS, WEIGHTS, LEVELS, NO_SPEED_CAP,
};
