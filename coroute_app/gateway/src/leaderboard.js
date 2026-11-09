'use strict';
/**
 * 3.55 rider score API + public leaderboard (docs/features_355/rider_score.md).
 *
 *   GET  /api/me/score              (auth)  the rider's own score, components and tips
 *   POST /api/me/score/rides        (auth)  per-ride counts from the phone's ride safety report
 *   DELETE /api/me/score/phone      (auth)  forget every phone count (setting switched off)
 *   GET  /api/me/leaderboard        (auth)  the rider's own places on the public boards
 *   GET  /api/public/leaderboard    (public, cached 5 min, rate limited)
 *
 * Leaderboard privacy: usernames and rounded numbers only. Never a userId, a real name, a place, a
 * date or a ride. A rider appears only with a `username` on the user document, `publicLeaderboard`
 * not false, an active account and at least MIN_RIDES counted rides. Switch `leaderboard` off: empty
 * lists. Switch `riderScore` off: /me/score answers `enabled: false` with no score.
 */
const express = require('express');
const rateLimit = require('express-rate-limit');
const { requireAuth } = require('./auth');
const { COLLECTION, MIN_RIDES, publicHandle, USERNAME_RE } = require('./rider_score');

const CACHE_MS = 5 * 60 * 1000;
const TOP_N = 10;
const SCAN = 100; // rows read per board before filtering opted-out riders
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

const empty = (now) => ({ updatedAt: now, topScore: [], longestRide: [], mostKm: [], mostHours: [], mostRides: [] });

class Leaderboard {
  /** @param {{soda:any, repo:any, flagsOf?:() => any, clock?:() => number, cacheMs?:number}} opts */
  constructor({ soda, repo, riderScore, flagsOf = () => null, clock = Date.now, cacheMs = CACHE_MS }) {
    this.soda = soda; this.repo = repo; this.riderScore = riderScore; this.flagsOf = flagsOf; this.now = clock; this.cacheMs = cacheMs;
    this.cache = null; // { at, body }
    this.building = null;
    this.builds = 0;
  }

  enabled() { const f = this.flagsOf(); return !f || f.isOn('leaderboard'); }

  /** The public body: cached for cacheMs per node (one build at a time). */
  async get() {
    const now = this.now();
    if (!this.enabled()) return empty(now);
    if (this.cache && now - this.cache.at < this.cacheMs) return this.cache.body;
    if (!this.building) {
      this.building = this.build().then((body) => { this.cache = { at: this.now(), body }; return body; })
        .finally(() => { this.building = null; });
    }
    return this.building;
  }

  invalidate() { this.cache = null; }

  /** A user's public handle, or null when they must not be shown. */
  static handleOf(user) { return publicHandle(user); }

  async build() {
    this.builds++;
    if (this.riderScore) await this.riderScore.init();
    const users = new Map();
    const handle = async (userId) => {
      if (!users.has(userId)) users.set(userId, Leaderboard.handleOf(await this.repo.findUserById(userId).catch(() => null)));
      return users.get(userId);
    };
    const board = async (path, minValue, pick) => {
      const rows = await this.soda.query(COLLECTION, { eligible: true }, {
        orderBy: [{ path, datatype: 'number', order: 'desc' }, { path: 'lbRides', datatype: 'number', order: 'desc' }], limit: SCAN,
      });
      const out = [];
      for (const { value: d } of rows) {
        if (out.length >= TOP_N) break;
        if (!(Number(d[path]) > minValue) || (d.lbRides || 0) < MIN_RIDES) continue;
        const username = await handle(d.userId);
        if (!username) continue;
        out.push({ username, ...pick(d) });
      }
      return out;
    };
    return {
      updatedAt: this.now(),
      topScore: await board('lbScore', -1, (d) => ({ score: Math.round(d.lbScore), rides: d.lbRides })),
      longestRide: await board('lbLongestKm', 0, (d) => ({ km: Math.round(d.lbLongestKm) })),
      mostKm: await board('lbKm', 0, (d) => ({ km: Math.round(d.lbKm) })),
      mostHours: await board('lbHours', 0, (d) => ({ hours: Math.round(d.lbHours * 10) / 10 })),
      mostRides: await board('lbRides', 0, (d) => ({ rides: d.lbRides })),
    };
  }
}

/** Routes; mounted on /api before the main router. */
function riderScoreRouter({ riderScore, leaderboard, gate, flagsOf = () => null }) {
  const r = express.Router();
  const publicLimiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests, try again later.' } });
  const submitLimiter = rateLimit({ windowMs: 60 * 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => req.user?.userId || req.ip, message: { error: 'Too many requests, try again later.' } });
  const scoreOn = () => { const f = flagsOf(); return !f || f.isOn('riderScore'); };

  r.get('/public/leaderboard', publicLimiter, wrap(async (req, res) => {
    const body = await leaderboard.get();
    res.set('Cache-Control', 'public, max-age=300').json(body);
  }));

  const auth = requireAuth(gate);
  r.get('/me/score', auth, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    if (!scoreOn()) {
      return res.json({ enabled: false, score: null, level: null, components: { smoothness: null, speedDiscipline: null, safety: null, consistency: null }, ridesCounted: 0, minRides: MIN_RIDES, updatedAt: null, tips: [] });
    }
    res.json({ enabled: true, ...(await riderScore.scoreOf(req.user.userId)) });
  }));

  // The rider's own places on the public boards ("You: #42"); null places when not on the leaderboard.
  r.get('/me/leaderboard', auth, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    if (!leaderboard.enabled()) return res.json({ enabled: false, username: null, onLeaderboard: false, ranks: {} });
    res.json({ enabled: true, ...(await riderScore.ranksOf(req.user.userId)) });
  }));

  r.post('/me/score/rides', auth, submitLimiter, wrap(async (req, res) => {
    const groupId = String(req.body?.groupId || '');
    if (!/^GRP-[A-Za-z0-9_-]{1,64}$/.test(groupId)) return res.status(400).json({ error: 'groupId required.' });
    if (!scoreOn()) return res.status(202).json({ ok: true, ignored: 'FEATURE_OFF' });
    await riderScore.submitPhoneCounts(req.user.userId, groupId, req.body);
    res.status(202).json({ ok: true });
  }));

  r.delete('/me/score/phone', auth, wrap(async (req, res) => {
    await riderScore.clearPhoneCounts(req.user.userId);
    res.json({ ok: true });
  }));
  return r;
}

module.exports = { Leaderboard, riderScoreRouter, CACHE_MS, USERNAME_RE };
