'use strict';
/**
 * GET /api/public/live-now: how many riders are on a ride right now, for the website.
 *
 * Aggregate only: no ids, names, groups, places or times beyond `updatedAt` (to the hour). Counts come from the live rides this
 * gateway holds in memory (a ride that is STARTED or PAUSED, a rider heard from in the last 10 minutes whose app is
 * not closed). To avoid pointing at individual riders the rider count is rounded DOWN to tens, so anything below 10
 * reads as 0, and the group count is only given once at least 10 riders are out. An idle server honestly says 0.
 * Cached for 30 s; rate-limited.
 */
const rateLimit = require('express-rate-limit');

const LIVE_STATUSES = new Set(['STARTED', 'PAUSED']);
const FRESH_MS = 10 * 60 * 1000;
const CACHE_MS = 30 * 1000;
const STEP = 10;

/** { ridersOnRide, groupsRiding } from a ConvoyManager's rooms (exact counts, before rounding). */
function countLive(convoys, now = Date.now()) {
  let riders = 0;
  let groups = 0;
  const rooms = convoys && convoys.rooms instanceof Map ? convoys.rooms.values() : [];
  for (const room of rooms) {
    if (!room || !room.meta || !LIVE_STATUSES.has(room.meta.tripStatus) || !(room.riders instanceof Map)) continue;
    let n = 0;
    for (const r of room.riders.values()) {
      if (!r || r.presence === 'APP_CLOSED') continue;
      if (now - (Number(r.lastSeenEpochMs) || 0) > FRESH_MS) continue;
      n += 1;
    }
    if (n > 0) { riders += n; groups += 1; }
  }
  return { riders, groups };
}

/** The public, rounded view of countLive. */
function publicLiveNow(convoys, now = Date.now()) {
  const { riders, groups } = countLive(convoys, now);
  const rounded = Math.floor(riders / STEP) * STEP;
  return {
    ok: true,
    ridersOnRide: rounded,
    groupsRiding: rounded >= STEP ? groups : 0,
    approximate: true,
    threshold: STEP,
    updatedAt: Math.floor(now / 3600000) * 3600000,
  };
}

function registerPublicLiveRoutes({ r, convoys, wrap }) {
  let cached = null;
  let cachedAt = 0;
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, message: { ok: false, error: 'Too many requests.' } });
  const handler = (req, res) => {
    const now = Date.now();
    if (!cached || now - cachedAt >= CACHE_MS) {
      cached = publicLiveNow(convoys, now);
      cachedAt = now;
    }
    res.set('Cache-Control', 'public, max-age=30');
    res.json(cached);
  };
  r.get('/public/live-now', limiter, wrap ? wrap(async (req, res) => handler(req, res)) : handler);
}

module.exports = { registerPublicLiveRoutes, publicLiveNow, countLive };
