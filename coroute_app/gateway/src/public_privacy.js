'use strict';
/**
 * Privacy rules for every number the public website shows (no login, nobody is a "user" of the site).
 *
 * The website only ever gets totals, and every total is made coarse before it leaves the server, so that a small
 * community can not be read back to one rider:
 *   - counts (riders, rides, group rides, SOS alerts) below MIN_COUNT read as 0, and are rounded DOWN:
 *     to tens below 1,000, hundreds below 100,000, thousands above;
 *   - distance is rounded DOWN to 100 km (to 1,000 km from 10,000 km on); below 100 km it reads as 0;
 *   - an average rating is only given when at least MIN_COUNT ratings are behind it;
 *   - no per-city, per-route, per-rider or per-ride figures at all (the old "longest trips" list is admin-only);
 *   - times are given to the hour at most (story dates to the day).
 * Rounding down (never to the nearest) keeps the website honest: "40+" rides is always true.
 */

const MIN_COUNT = 10;
const HOUR_MS = 3600 * 1000;
const DAY_MS = 24 * HOUR_MS;

const nonNeg = (v) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : 0; };

/** A count, rounded down to a privacy-safe step; anything below MIN_COUNT is 0. */
function roundCount(v) {
  const n = Math.floor(nonNeg(v));
  if (n < MIN_COUNT) return 0;
  const step = n < 1000 ? 10 : n < 100000 ? 100 : 1000;
  return Math.floor(n / step) * step;
}

/** Kilometres, rounded down to 100 km (1,000 km from 10,000 km on); below 100 km is 0. */
function roundKm(v) {
  const n = nonNeg(v);
  const step = n < 10000 ? 100 : 1000;
  return Math.floor(n / step) * step;
}

/** A time in ms, floored to the hour (null when missing). */
function toHour(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.floor(n / HOUR_MS) * HOUR_MS : null;
}

/** A time in ms, floored to the start of its UTC day (null when missing). */
function toDay(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.floor(n / DAY_MS) * DAY_MS : null;
}

/** An average rating, only when enough ratings are behind it. */
function safeRating(avg, count) {
  const a = Number(avg);
  if (!Number.isFinite(a) || a < 1 || a > 5 || !(Number(count) >= MIN_COUNT)) return null;
  return Math.round(a * 10) / 10;
}

/** The public view of admin_analytics.publicUsage: same keys, coarse values. */
function safeUsage(raw) {
  const u = raw || {};
  return {
    riders: roundCount(u.riders),
    ridesCompleted: roundCount(u.ridesCompleted),
    kmRidden: roundKm(u.kmRidden),
    groupsRidden: roundCount(u.groupsRidden),
    sosResolved: roundCount(u.sosResolved),
    avgRating: safeRating(u.avgRating, u.ratingsCount),
    // 3.55 ride analytics: hours rounded down like counts; the average speed only from MIN_COUNT rides
    // (whole km/h); a week's kilometres only when MIN_COUNT rides are behind it (else null: not shown).
    movingHours: roundCount(u.movingHours),
    avgSpeedKmh: Number(u.ridesCompleted) >= MIN_COUNT && Number(u.avgSpeedKmh) > 0 ? Math.floor(Number(u.avgSpeedKmh)) : null,
    weeklyKm: Array.isArray(u.weeklyKm)
      ? u.weeklyKm.map((w) => ({
        weekStart: toDay(w && w.weekStart),
        km: Number(w && w.rides) >= MIN_COUNT ? roundKm(w.km) : null,
        rides: roundCount(w && w.rides),
      }))
      : [],
    updatedAt: toHour(u.updatedAt),
  };
}

/**
 * 3.55 website impact view: everything in safeUsage plus records and safety outcomes.
 *  - largest group: a rider count of one ride with nobody named, shown only once 10 group rides exist;
 *  - longest trip: rounded down to 10 km, only once 10 rides exist;
 *  - bikes / bike models / safety counts: counts like every other (nothing below 10);
 *  - median response time: whole seconds, only from 10 answered alerts.
 */
function safeImpact(raw) {
  const u = raw || {};
  const s = u.safety || {};
  const enoughRides = Number(u.ridesCompleted) >= MIN_COUNT;
  return {
    ...safeUsage(u),
    groupRides: roundCount(u.groupRides),
    largestGroup: Number(u.groupRides) >= MIN_COUNT ? Math.floor(nonNeg(u.largestGroup)) : 0,
    longestTripKm: enoughRides ? Math.floor(nonNeg(u.longestTripKm) / 10) * 10 : 0,
    bikes: roundCount(u.bikes),
    bikeModels: roundCount(u.bikeModels),
    safety: {
      sosResolved: roundCount(s.sosResolved),
      crashAlerts: roundCount(s.crashAlerts),
      alertsAnswered: roundCount(s.alertsAnswered),
      medianResponseSec: Number(s.responsesCounted) >= MIN_COUNT && Number(s.medianResponseSec) > 0 ? Math.round(Number(s.medianResponseSec)) : null,
      roadReports: roundCount(s.roadReports),
    },
  };
}

/** The public view of repo.getCommunityStats: totals only, no per-ride list. The admin view keeps everything. */
function safeCommunityStats(stats) {
  const s = stats || {};
  if (s.enabled === false) return { enabled: false, message: s.message || 'Community statistics are currently private' };
  return {
    enabled: true,
    totalRiders: roundCount(s.totalRiders),
    activeRiders: roundCount(s.activeRiders),
    totalKilometers: roundKm(s.totalKilometers),
    longestTrips: [],
    lastUpdated: toHour(s.lastUpdated),
  };
}

/** What the website may say about how its numbers are made (sent with usage-stats). */
const PRIVACY_NOTE = Object.freeze({ minCount: MIN_COUNT, rounding: 'down', timeResolution: 'hour', perRider: false, perPlace: false });

module.exports = { MIN_COUNT, roundCount, roundKm, toHour, toDay, safeRating, safeUsage, safeImpact, safeCommunityStats, PRIVACY_NOTE };
