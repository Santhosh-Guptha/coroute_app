'use strict';
/**
 * Admin analytics (master admin only), per-rider configuration, and the public
 * aggregated usage numbers for the website.
 *
 * Every number is counted from stored documents; nothing is estimated or invented.
 * Collections are read in pages of 1000 (the SODA REST page size) up to a cap; a
 * response says `truncated: true` when a cap was reached, so a partial count is
 * never shown as a complete one. Heavy aggregates are cached for a short time.
 */
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { COLLECTIONS: C, ACTIVE_STATUSES } = require('./oracle/repo');
const { effectiveSubscription, isPaidTier } = require('./subscription_lifecycle');

const DAY = 86400000;
const PAGE = 1000;
const SCAN_CAP = 50000;
const ROLES = ['RIDER', 'MASTER_ADMIN'];
const STATUSES = ['ACTIVE', 'ON_HOLD', 'BLOCKED'];
const TIERS = ['community', 'proRider', 'roadCaptain', 'tourOperator'];
/** Timeline event types counted per group (what an admin asks about a ride). */
const GROUP_EVENT_TYPES = ['REGROUP_INITIATED', 'REGROUP_COMPLETED', 'SEPARATED', 'OFF_ROUTE', 'OVERSPEED', 'OFFLINE', 'STOPPED',
  'SOS', 'POSSIBLE_INCIDENT', 'SWEEPER_DISTRESS', 'CONVOY_SPLIT', 'LOW_BATTERY', 'JOINED', 'LEFT'];

const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const round1 = (v) => Math.round(num(v) * 10) / 10;
const clampInt = (v, lo, hi, dflt) => { const n = parseInt(v, 10); return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : dflt; };
const tripKm = (t) => num(t.totalDistanceKm) || num(t.distanceM) / 1000;
const tripMovingMs = (t) => num(t.movingMs) || Math.max(0, num(t.endTimeEpochMs) - num(t.startTimeEpochMs) - num(t.restMs));
function median(list) {
  const a = list.filter((x) => Number.isFinite(x)).sort((x, y) => x - y);
  if (!a.length) return null;
  const m = Math.floor(a.length / 2);
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
}
const isGuest = (u) => u.provider === 'guest' || String(u.email || '').endsWith('@guest.coroute.local');
/** CLOSED as a real emergency (not a false alarm, cancel or expiry). */
const sosResolvedReal = (a) => a.resolved === true && !['FALSE_ALARM', 'CANCELLED', 'EXPIRED'].includes(a.resolveReason || a.status);
const sosFalseAlarm = (a) => a.resolved === true && ['FALSE_ALARM', 'CANCELLED'].includes(a.resolveReason || a.status);
/** Seconds from the alert to the first rider who answered it, or null. */
function firstResponseSec(a) {
  const at = num(a.timestamp || a.occurredAt);
  const times = Object.values(a.responders || {}).map((r) => num(r && r.at)).filter((t) => t > 0 && t >= at);
  return at > 0 && times.length ? Math.round((Math.min(...times) - at) / 1000) : null;
}

/** Reads every document of `coll` matching `filter`, in pages, up to `cap`. */
async function scan(soda, coll, filter = {}, { cap = SCAN_CAP } = {}) {
  const rows = [];
  for (let offset = 0; offset < cap; offset += PAGE) {
    const page = await soda.query(coll, filter, { limit: Math.min(PAGE, cap - offset), offset });
    for (const r of page) rows.push(r.value);
    if (page.length < Math.min(PAGE, cap - offset)) return { rows, truncated: false };
  }
  return { rows, truncated: true };
}

/** Small time-boxed cache for the aggregates (keyed by name). */
function makeCache(ttlMs) {
  const m = new Map();
  return {
    async get(key, fn) {
      const hit = m.get(key);
      if (hit && hit.until > Date.now()) return hit.value;
      const value = await fn();
      m.set(key, { value, until: Date.now() + ttlMs });
      if (m.size > 50) m.delete(m.keys().next().value);
      return value;
    },
    clear() { m.clear(); },
  };
}

/** userId -> live ride (in memory first, then stored active convoys). */
async function ridingMap(repo, convoys) {
  const map = new Map();
  for (const [gid, room] of convoys?.rooms || []) {
    for (const uid of room.riders.keys()) map.set(uid, { groupId: gid, name: room.meta?.name || 'Ride' });
  }
  const metas = await repo.listActiveConvoyMeta(500).catch(() => []);
  for (const m of metas) {
    for (const [uid, mem] of Object.entries(m.members || {})) {
      if (!mem?.leftAt && !map.has(uid)) map.set(uid, { groupId: m.groupId, name: m.name || 'Ride' });
    }
  }
  return map;
}

/** Riders currently holding a membership (owner or accepted member) that has not ended. */
function membershipHolders(memberships, now) {
  const set = new Set();
  for (const m of memberships) {
    if (m.status !== 'ACTIVE' || num(m.validUntil) <= now) continue;
    if (m.ownerUserId) set.add(m.ownerUserId);
    for (const [uid, mem] of Object.entries(m.members || {})) if (!mem || mem.status !== 'REMOVED') set.add(uid);
  }
  return set;
}

// ---------------------------------------------------------------- aggregates

async function overview({ repo, convoys }, { days = 30, now = Date.now() } = {}) {
  const soda = repo.soda;
  const since = now - days * DAY;
  const [users, trips, ended, alerts, orders, memberships] = await Promise.all([
    scan(soda, C.users), scan(soda, C.trips), scan(soda, C.convoys, { tripStatus: 'ENDED' }), scan(soda, C.alerts),
    scan(soda, C.subscriptionConfig, { k: 'rzp_order' }), scan(soda, C.memberships, {}, { cap: 20000 }),
  ]);
  const riders = users.rows.filter((u) => !isGuest(u));
  const holders = membershipHolders(memberships.rows, now);
  const planHolders = riders.filter((u) => effectiveSubscription(u, now).tier !== 'community' || holders.has(u.userId)).length;
  const paidOrders = orders.rows.filter((o) => o.status === 'PAID' && num(o.amountInPaise) > 0);
  const liveOrders = paidOrders.filter((o) => o.mode !== 'test');
  const paying = new Set(liveOrders.map((o) => o.userId).filter(Boolean));
  const net = (o) => (num(o.amountInPaise) - num(o.refundedAmountInPaise)) / 100;
  const paidAt = (o) => num(o.paidAt) || num(o.createdAt);
  const tripsIn = trips.rows.filter((t) => num(t.endTimeEpochMs) >= since);
  const endedIn = ended.rows.filter((c) => num(c.endedAtEpochMs || c.updatedAt) >= since);
  const memberCount = (c) => Object.keys(c.members || {}).length;
  const groupKm = (c) => num(c.report?.group?.distanceM) / 1000;
  const alertsIn = alerts.rows.filter((a) => num(a.timestamp) >= since);
  const responses = alerts.rows.map(firstResponseSec).filter((x) => x !== null);
  const resolveSecs = alerts.rows.filter(sosResolvedReal).map((a) => (num(a.resolvedAt) - num(a.timestamp)) / 1000).filter((s) => s >= 0);
  const live = convoys?.rooms ? convoys.rooms.size : 0;
  return {
    ok: true,
    generatedAt: now,
    days,
    truncated: [users, trips, ended, alerts, orders, memberships].some((s) => s.truncated),
    riders: {
      total: riders.length,
      guests: users.rows.length - riders.length,
      active7d: riders.filter((u) => num(u.lastActiveAt || u.lastLoginAt) >= now - 7 * DAY).length,
      active30d: riders.filter((u) => num(u.lastActiveAt || u.lastLoginAt) >= now - 30 * DAY).length,
      newInPeriod: riders.filter((u) => num(u.createdAt) >= since).length,
      onHold: riders.filter((u) => u.status === 'ON_HOLD').length,
      blocked: riders.filter((u) => u.status === 'BLOCKED').length,
      planHolders,
      paying: paying.size,
      conversionPct: riders.length ? round1((paying.size / riders.length) * 100) : 0,
    },
    rides: {
      live,
      groupsCompleted: ended.rows.length,
      groupsInPeriod: endedIn.length,
      completedTrips: trips.rows.length,
      tripsInPeriod: tripsIn.length,
      kmRidden: Math.round(trips.rows.reduce((s, t) => s + tripKm(t), 0)),
      kmInPeriod: Math.round(tripsIn.reduce((s, t) => s + tripKm(t), 0)),
      groupKm: Math.round(ended.rows.reduce((s, c) => s + groupKm(c), 0)),
      ridingHours: round1(trips.rows.reduce((s, t) => s + tripMovingMs(t), 0) / 3600000),
      avgGroupSize: ended.rows.length ? round1(ended.rows.reduce((s, c) => s + memberCount(c), 0) / ended.rows.length) : 0,
    },
    safety: {
      sosTotal: alerts.rows.length,
      sosInPeriod: alertsIn.length,
      open: alerts.rows.filter((a) => a.resolved !== true).length,
      resolved: alerts.rows.filter(sosResolvedReal).length,
      falseAlarms: alerts.rows.filter(sosFalseAlarm).length,
      answered: responses.length,
      medianResponseSec: median(responses),
      medianResolveSec: resolveSecs.length ? Math.round(median(resolveSecs)) : null,
    },
    payments: {
      paidOrders: liveOrders.length,
      revenueInr: Math.round(liveOrders.reduce((s, o) => s + net(o), 0)),
      revenueInPeriodInr: Math.round(liveOrders.filter((o) => paidAt(o) >= since).reduce((s, o) => s + net(o), 0)),
      testPaidOrders: paidOrders.length - liveOrders.length,
      testRevenueInr: Math.round(paidOrders.filter((o) => o.mode === 'test').reduce((s, o) => s + net(o), 0)),
      couponOrders: orders.rows.filter((o) => o.status === 'PAID' && (o.couponCode || o.offerCode)).length,
    },
  };
}

/** Per-rider totals for every rider (one pass over trips and alerts). */
async function riderTotals(repo) {
  const soda = repo.soda;
  const [trips, alerts] = await Promise.all([scan(soda, C.trips), scan(soda, C.alerts)]);
  const by = new Map();
  const get = (uid) => { let t = by.get(uid); if (!t) { t = { trips: 0, km: 0, movingMs: 0, sos: 0, lastTripAt: 0 }; by.set(uid, t); } return t; };
  for (const t of trips.rows) {
    if (!t.userId) continue;
    const x = get(t.userId);
    x.trips++; x.km += tripKm(t); x.movingMs += tripMovingMs(t); x.lastTripAt = Math.max(x.lastTripAt, num(t.endTimeEpochMs));
  }
  for (const a of alerts.rows) if (a.userId) get(a.userId).sos++;
  return { by, truncated: trips.truncated || alerts.truncated };
}

function riderRow(u, totals, riding, now) {
  const t = totals.get(u.userId) || { trips: 0, km: 0, movingMs: 0, sos: 0, lastTripAt: 0 };
  const st = effectiveSubscription(u, now);
  return {
    userId: u.userId, name: u.name || '', email: u.email || '', phone: u.phone || '',
    role: u.role || 'RIDER', status: u.status || 'ACTIVE', tier: st.tier, guest: isGuest(u),
    trips: t.trips, km: round1(t.km), ridingHours: round1(t.movingMs / 3600000), sos: t.sos,
    lastSeenAt: Math.max(num(u.lastActiveAt || u.lastLoginAt), t.lastTripAt), createdAt: num(u.createdAt),
    riding: riding.get(u.userId) || null,
  };
}

const RIDER_SORTS = {
  lastSeen: (a, b) => b.lastSeenAt - a.lastSeenAt,
  joined: (a, b) => b.createdAt - a.createdAt,
  trips: (a, b) => b.trips - a.trips || b.km - a.km,
  km: (a, b) => b.km - a.km,
  sos: (a, b) => b.sos - a.sos,
  name: (a, b) => a.name.localeCompare(b.name),
};

async function riderDetail({ repo, convoys }, userId, now = Date.now()) {
  const soda = repo.soda;
  const u = await repo.findUserById(userId);
  if (!u) return null;
  const [trips, alerts, orders, diags, audit, membership, riding] = await Promise.all([
    scan(soda, C.trips, { userId }, { cap: 5000 }),
    scan(soda, C.alerts, { userId }, { cap: 2000 }),
    scan(soda, C.subscriptionConfig, { k: 'rzp_order', userId }, { cap: 2000 }),
    scan(soda, C.diagnostics, { riderId: userId }, { cap: 200 }),
    scan(soda, C.subscriptionConfig, { k: 'audit', target: userId }, { cap: 500 }),
    typeof repo.findMembershipByOwner === 'function' ? repo.findMembershipByOwner(userId).catch(() => null) : null,
    ridingMap(repo, convoys),
  ]);
  const km = trips.rows.reduce((s, t) => s + tripKm(t), 0);
  const movingMs = trips.rows.reduce((s, t) => s + tripMovingMs(t), 0);
  const tripEnds = trips.rows.map((t) => num(t.endTimeEpochMs)).filter((x) => x > 0);
  const st = effectiveSubscription(u, now);
  const paid = orders.rows.filter((o) => o.status === 'PAID');
  const devices = new Map();
  for (const d of diags.rows.sort((a, b) => num(b.timestamp || b.createdAt) - num(a.timestamp || a.createdAt))) {
    const di = d.deviceInfo || {};
    const key = `${di.manufacturer || ''}|${di.model || ''}`;
    if (devices.has(key)) continue;
    devices.set(key, {
      manufacturer: String(di.manufacturer || ''), model: String(di.model || ''),
      os: String(di.osVersion || di.androidVersion || di.os || ''), appVersion: String(d.appVersion || di.appVersion || ''),
      result: String(d.overallResult || ''), reportedAt: num(d.timestamp || d.createdAt),
    });
  }
  return {
    ok: true,
    truncated: [trips, alerts, orders].some((s) => s.truncated),
    rider: {
      userId: u.userId, name: u.name || '', email: u.email || '', phone: u.phone || '', role: u.role || 'RIDER',
      status: u.status || 'ACTIVE', statusReason: u.statusReason || '', provider: u.provider || 'password', guest: isGuest(u),
      createdAt: num(u.createdAt), lastSeenAt: Math.max(num(u.lastActiveAt || u.lastLoginAt), tripEnds.length ? Math.max(...tripEnds) : 0),
      appBuild: num(u.appBuild) || null, vehicleType: u.vehicleType || '', riding: riding.get(userId) || null,
    },
    stats: {
      trips: trips.rows.length,
      km: round1(km),
      ridingHours: round1(movingMs / 3600000),
      avgSpeedKmh: movingMs > 0 ? round1(km / (movingMs / 3600000)) : 0,
      topSpeedKmh: round1(trips.rows.reduce((mx, t) => Math.max(mx, num(t.topSpeedKmh)), 0)),
      groups: new Set(trips.rows.map((t) => t.groupId).filter(Boolean)).size,
      firstTripAt: tripEnds.length ? Math.min(...tripEnds) : 0,
      lastTripAt: tripEnds.length ? Math.max(...tripEnds) : 0,
      sos: alerts.rows.length,
      sosOpen: alerts.rows.filter((a) => a.resolved !== true).length,
      falseAlarms: alerts.rows.filter(sosFalseAlarm).length,
    },
    plan: {
      tier: st.tier, rawTier: st.rawTier, validUntil: st.validUntil, daysRemaining: st.daysRemaining, isExpired: st.isExpired,
      membership: membership && membership.status ? {
        category: membership.category || '', name: membership.categoryName || '', status: membership.status,
        validUntil: num(membership.validUntil), members: Object.keys(membership.members || {}).length,
      } : null,
    },
    payments: {
      orders: orders.rows.length,
      paid: paid.length,
      totalPaidInr: Math.round(paid.reduce((s, o) => s + num(o.amountInPaise), 0) / 100),
      refundedInr: Math.round(orders.rows.reduce((s, o) => s + num(o.refundedAmountInPaise), 0) / 100),
      recent: orders.rows.sort((a, b) => num(b.createdAt) - num(a.createdAt)).slice(0, 10).map((o) => ({
        orderId: o.orderId, status: o.status || 'CREATED', amount: num(o.amountInPaise) / 100, mode: o.mode || null,
        plan: o.planTier || o.category || null, couponCode: o.couponCode || o.offerCode || null, createdAt: num(o.createdAt), paidAt: num(o.paidAt),
      })),
    },
    devices: [...devices.values()],
    limits: limitsOf(u),
    audit: audit.rows.sort((a, b) => num(b.at) - num(a.at)).slice(0, 20)
      .map((e) => ({ at: num(e.at), by: e.by || null, action: e.action || '', details: e.details || {} })),
  };
}

function limitsOf(u) {
  const o = u.adminLimits && typeof u.adminLimits === 'object' ? u.adminLimits : {};
  return { maxTrips: Number.isInteger(o.maxTrips) ? o.maxTrips : null, defaultMaxTrips: config.maxTripsPerUser };
}

/** The trip-storage cap for a rider: the admin override when set, else the server default. */
function maxTripsFor(u) {
  const v = u?.adminLimits?.maxTrips;
  return Number.isInteger(v) && v >= 0 ? v : config.maxTripsPerUser;
}

function groupRow(m, live) {
  const g = m.report?.group || {};
  const startedAt = num(m.createdAtEpochMs);
  const endedAt = num(m.endedAtEpochMs);
  return {
    groupId: m.groupId, name: m.name || 'Ride', status: live ? 'LIVE' : (m.tripStatus || 'ENDED'),
    createdByUserName: m.createdByUserName || '', startedAt, endedAt,
    members: Object.keys(m.members || {}).length,
    distanceKm: round1(num(g.distanceM) / 1000),
    durationMs: num(g.durationMs) || (endedAt ? Math.max(0, endedAt - startedAt) : 0),
    sos: num(g.sos), arrived: num(g.arrived), hasReport: !!m.report,
    destinationName: m.destinationName || '',
  };
}

async function groupDetail({ repo, convoys }, groupId) {
  const soda = repo.soda;
  const meta = await repo.getConvoyMeta(groupId);
  const room = convoys?.rooms?.get(groupId) || null;
  if (!meta && !room) return null;
  const m = meta || room.meta || {};
  const [events, alerts] = await Promise.all([
    scan(soda, C.events, { groupId }, { cap: 10000 }),
    scan(soda, C.alerts, { groupId }, { cap: 2000 }),
  ]);
  const counts = {};
  for (const t of GROUP_EVENT_TYPES) counts[t] = 0;
  for (const e of events.rows) if (Object.hasOwn(counts, e.type)) counts[e.type]++;
  const report = m.report || null;
  const g = report?.group || {};
  const reportMembers = Array.isArray(report?.members) ? report.members : [];
  const byId = new Map(reportMembers.map((x) => [x.userId, x]));
  const memberIds = new Set([...Object.keys(m.members || {}), ...(room ? room.riders.keys() : [])]);
  const members = [...memberIds].map((uid) => {
    const mem = (m.members || {})[uid] || {};
    const rider = room?.riders.get(uid) || {};
    const s = byId.get(uid) || null;
    return {
      userId: uid, name: s?.name || mem.name || rider.name || '', role: s?.role || mem.role || rider.role || 'PACK',
      online: room ? room.riders.has(uid) : false,
      trackAvailable: !!s?.trackAvailable,
      distanceKm: round1(num(s?.distanceM) / 1000), movingMs: num(s?.movingMs), avgKmh: round1(s?.avgMovingKmh), maxKmh: round1(s?.maxKmh),
      sos: num(s?.sos), separatedMs: num(s?.separatedMs), offRouteMs: num(s?.offRouteMs), reachedDestination: !!s?.reachedDestination,
    };
  }).sort((a, b) => b.distanceKm - a.distanceKm || a.name.localeCompare(b.name));
  const startedAt = num(m.createdAtEpochMs);
  const endedAt = num(m.endedAtEpochMs);
  const live = !!room || ACTIVE_STATUSES.includes(m.tripStatus);
  return {
    ok: true,
    truncated: events.truncated || alerts.truncated,
    group: {
      groupId, name: m.name || 'Ride', status: room ? 'LIVE' : (m.tripStatus || 'ENDED'), live,
      createdByUserName: m.createdByUserName || '', startName: m.start?.name || m.startLocationName || '', destinationName: m.destinationName || '',
      startedAt, endedAt, hasReport: !!report,
    },
    stats: {
      members: memberIds.size,
      distanceKm: round1(num(g.distanceM) / 1000),
      durationMs: num(g.durationMs) || (endedAt ? Math.max(0, endedAt - startedAt) : (live && startedAt ? Math.max(0, Date.now() - startedAt) : 0)),
      arrived: num(g.arrived),
      stopsPlanned: Array.isArray(m.stopPoints) ? m.stopPoints.length : num(g.plannedStops),
      stopsVisited: Array.isArray(m.stopPoints) ? m.stopPoints.filter((s) => s.isVisited).length : num(g.visitedStops),
      regroups: counts.REGROUP_INITIATED,
      separations: counts.SEPARATED,
      offRoute: counts.OFF_ROUTE,
      overspeed: counts.OVERSPEED,
      incidents: counts.POSSIBLE_INCIDENT + counts.SWEEPER_DISTRESS,
      alerts: {
        total: alerts.rows.length,
        open: alerts.rows.filter((a) => a.resolved !== true).length,
        resolved: alerts.rows.filter(sosResolvedReal).length,
        falseAlarms: alerts.rows.filter(sosFalseAlarm).length,
        medianResponseSec: median(alerts.rows.map(firstResponseSec).filter((x) => x !== null)),
      },
    },
    events: counts,
    members,
  };
}

/** Aggregated, PII-free numbers for the public website. */
async function publicUsage(repo, now = Date.now()) {
  const soda = repo.soda;
  const [users, trips, ended, alerts, reviews] = await Promise.all([
    scan(soda, C.users), scan(soda, C.trips), scan(soda, C.convoys, { tripStatus: 'ENDED' }), scan(soda, C.alerts),
    scan(soda, C.feedback, { status: 'APPROVED' }, { cap: 5000 }),
  ]);
  const ratings = reviews.rows.map((r) => r.rating).filter((x) => Number.isInteger(x) && x >= 1 && x <= 5);
  return {
    riders: users.rows.filter((u) => !isGuest(u)).length,
    ridesCompleted: trips.rows.length,
    kmRidden: Math.round(trips.rows.reduce((s, t) => s + tripKm(t), 0)),
    groupsRidden: ended.rows.filter((c) => Object.keys(c.members || {}).length >= 2).length,
    sosResolved: alerts.rows.filter(sosResolvedReal).length,
    avgRating: ratings.length ? round1(ratings.reduce((a, b) => a + b, 0) / ratings.length) : null,
    updatedAt: now,
  };
}

// ---------------------------------------------------------------- routes

/** GET /public/usage-stats (+ /usage-stats). Registered before authentication. */
function registerPublicUsageRoutes({ r, repo, wrap }) {
  const cache = makeCache(5 * 60 * 1000);
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, message: { ok: false, error: 'Too many requests.' } });
  const handler = wrap(async (req, res) => {
    res.set('Cache-Control', 'public, max-age=300');
    const cfg = typeof repo.getCommunityStatsConfig === 'function' ? await repo.getCommunityStatsConfig().catch(() => ({})) : {};
    if (cfg && cfg.showPublicStats === false) return res.json({ ok: true, enabled: false, stats: null });
    const stats = await cache.get('usage', () => publicUsage(repo));
    res.json({ ok: true, enabled: true, stats });
  });
  r.get('/public/usage-stats', limiter, handler);
  r.get('/usage-stats', limiter, handler);
  return { cache };
}

function registerAdminAnalyticsRoutes({ r, repo, convoys, auth, hub, gate, wrap, requireAdmin, plans }) {
  const cache = makeCache(60 * 1000);
  const fresh = (req) => String(req.query.fresh || '') === '1';
  const audit = async (req, action, target, details) => {
    if (typeof repo.addAuditEntry !== 'function') return;
    try {
      await repo.addAuditEntry({ at: Date.now(), by: req.user?.email || req.user?.userId || 'admin', byUserId: req.user?.userId || null, action, target, details });
    } catch { /* never in the way */ }
  };

  r.get('/admin/analytics/overview', requireAdmin, wrap(async (req, res) => {
    const days = clampInt(req.query.days, 1, 365, 30);
    if (fresh(req)) cache.clear();
    res.set('Cache-Control', 'no-store').json(await cache.get(`overview:${days}`, () => overview({ repo, convoys }, { days })));
  }));

  // ?q=&status=ACTIVE|ON_HOLD|BLOCKED&tier=&riding=1&sort=lastSeen|joined|trips|km|sos|name&limit=&cursor=
  r.get('/admin/analytics/riders', requireAdmin, wrap(async (req, res) => {
    const now = Date.now();
    const limit = clampInt(req.query.limit, 1, 200, 50);
    const cursor = clampInt(req.query.cursor, 0, 1000000, 0);
    const q = String(req.query.q || '').trim().toLowerCase().slice(0, 100);
    const status = String(req.query.status || '').trim().toUpperCase();
    const tier = String(req.query.tier || '').trim();
    const sort = Object.hasOwn(RIDER_SORTS, req.query.sort) ? req.query.sort : 'lastSeen';
    if (fresh(req)) cache.clear();
    const [users, totals, riding] = await Promise.all([
      scan(repo.soda, C.users), cache.get('riderTotals', () => riderTotals(repo)), ridingMap(repo, convoys),
    ]);
    let rows = users.rows.map((u) => riderRow(u, totals.by, riding, now));
    if (STATUSES.includes(status)) rows = rows.filter((x) => x.status === status);
    if (TIERS.includes(tier)) rows = rows.filter((x) => x.tier === tier);
    if (String(req.query.riding || '') === '1') rows = rows.filter((x) => x.riding);
    if (q) rows = rows.filter((x) => [x.name, x.email, x.phone, x.userId].some((v) => String(v || '').toLowerCase().includes(q)));
    rows.sort(RIDER_SORTS[sort]);
    const page = rows.slice(cursor, cursor + limit);
    res.set('Cache-Control', 'no-store').json({
      ok: true, riders: page, total: rows.length, cursor, limit,
      nextCursor: cursor + page.length < rows.length ? cursor + page.length : null,
      truncated: users.truncated || totals.truncated,
    });
  }));

  r.get('/admin/analytics/riders/:userId', requireAdmin, wrap(async (req, res) => {
    const out = await riderDetail({ repo, convoys }, String(req.params.userId || '').slice(0, 80));
    if (!out) return res.status(404).json({ ok: false, error: 'User not found.', code: 'USER_NOT_FOUND' });
    res.set('Cache-Control', 'no-store').json(out);
  }));

  // ?status=live|ended|all&q=&limit=&cursor=
  r.get('/admin/analytics/groups', requireAdmin, wrap(async (req, res) => {
    const limit = clampInt(req.query.limit, 1, 200, 50);
    const cursor = clampInt(req.query.cursor, 0, 1000000, 0);
    const status = ['live', 'ended'].includes(req.query.status) ? req.query.status : 'all';
    const q = String(req.query.q || '').trim().toLowerCase().slice(0, 100);
    const liveIds = new Set(convoys?.rooms ? convoys.rooms.keys() : []);
    const parts = [];
    if (status !== 'ended') parts.push(scan(repo.soda, C.convoys, { tripStatus: { $in: ACTIVE_STATUSES } }, { cap: 2000 }));
    if (status !== 'live') parts.push(scan(repo.soda, C.convoys, { tripStatus: 'ENDED' }));
    const scans = await Promise.all(parts);
    let rows = scans.flatMap((s) => s.rows).map((m) => groupRow(m, liveIds.has(m.groupId)));
    if (q) rows = rows.filter((x) => [x.name, x.createdByUserName, x.destinationName, x.groupId].some((v) => String(v || '').toLowerCase().includes(q)));
    rows.sort((a, b) => (b.status === 'LIVE') - (a.status === 'LIVE') || (b.endedAt || b.startedAt) - (a.endedAt || a.startedAt));
    const page = rows.slice(cursor, cursor + limit);
    res.set('Cache-Control', 'no-store').json({
      ok: true, groups: page, total: rows.length, cursor, limit,
      nextCursor: cursor + page.length < rows.length ? cursor + page.length : null,
      truncated: scans.some((s) => s.truncated),
    });
  }));

  r.get('/admin/analytics/groups/:groupId', requireAdmin, wrap(async (req, res) => {
    const gid = String(req.params.groupId || '');
    const out = gid.length <= 64 ? await groupDetail({ repo, convoys }, gid) : null;
    if (!out) return res.status(404).json({ ok: false, error: 'Ride not found.', code: 'GROUP_NOT_FOUND' });
    res.set('Cache-Control', 'no-store').json(out);
  }));

  // ---- per-rider configuration: role, status, plan, limits (every change is audited) ----
  const configView = async (u) => {
    const st = effectiveSubscription(u);
    return {
      userId: u.userId, role: u.role || 'RIDER', status: u.status || 'ACTIVE', statusReason: u.statusReason || '',
      plan: { tier: st.tier, rawTier: st.rawTier, validUntil: st.validUntil, daysRemaining: st.daysRemaining, isExpired: st.isExpired },
      limits: limitsOf(u),
      options: { roles: ROLES, statuses: STATUSES, tiers: TIERS },
    };
  };

  r.get('/admin/users/:userId/config', requireAdmin, wrap(async (req, res) => {
    const u = await repo.findUserById(String(req.params.userId || ''));
    if (!u) return res.status(404).json({ ok: false, error: 'User not found.', code: 'USER_NOT_FOUND' });
    res.set('Cache-Control', 'no-store').json({ ok: true, config: await configView(u) });
  }));

  // Body: { role?, status?, reason?, plan?: { tier, days?, note? }, limits?: { maxTrips: int|null } }
  r.patch('/admin/users/:userId/config', requireAdmin, wrap(async (req, res) => {
    const userId = String(req.params.userId || '');
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    const bad = (code, error) => res.status(400).json({ ok: false, error, code });
    if (b.role !== undefined && !ROLES.includes(b.role)) return bad('BAD_ROLE', `role must be one of ${ROLES.join(', ')}`);
    const status = b.status === undefined ? undefined : String(b.status).toUpperCase();
    if (status !== undefined && !STATUSES.includes(status)) return bad('BAD_STATUS', `status must be one of ${STATUSES.join(', ')}`);
    const reason = typeof b.reason === 'string' ? b.reason.trim().slice(0, 200) : '';
    let plan = null;
    if (b.plan !== undefined) {
      if (!b.plan || typeof b.plan !== 'object' || !TIERS.includes(b.plan.tier)) return bad('BAD_TIER', `plan.tier must be one of ${TIERS.join(', ')}`);
      const days = b.plan.tier === 'community' ? 0 : Number(b.plan.days);
      if (b.plan.tier !== 'community' && (!Number.isInteger(days) || days < 1 || days > 3660)) return bad('BAD_DAYS', 'plan.days must be a whole number from 1 to 3660');
      plan = { tier: b.plan.tier, days, note: typeof b.plan.note === 'string' ? b.plan.note.trim().slice(0, 500) : '' };
    }
    let limits = null;
    if (b.limits !== undefined) {
      if (!b.limits || typeof b.limits !== 'object' || Array.isArray(b.limits)) return bad('BAD_LIMIT', 'limits must be an object');
      const mt = b.limits.maxTrips;
      if (mt !== null && mt !== undefined && (!Number.isInteger(mt) || mt < 0 || mt > 5000)) return bad('BAD_LIMIT', 'limits.maxTrips must be a whole number from 0 to 5000, or null for the default');
      limits = { maxTrips: mt === undefined ? undefined : mt };
    }
    if (b.role === undefined && status === undefined && !plan && !limits) return bad('NOTHING_TO_CHANGE', 'Send role, status, plan or limits.');

    let u = await repo.findUserById(userId);
    if (!u) return res.status(404).json({ ok: false, error: 'User not found.', code: 'USER_NOT_FOUND' });
    if (userId === req.user.userId && ((b.role !== undefined && b.role !== u.role) || (status !== undefined && status !== 'ACTIVE'))) {
      return res.status(409).json({ ok: false, error: 'You cannot change your own role or block your own account.', code: 'SELF_CHANGE' });
    }
    if (status !== undefined && status !== 'ACTIVE' && status !== (u.status || 'ACTIVE')) {
      const ride = (await ridingMap(repo, convoys)).get(userId);
      if (ride) return res.status(409).json({ ok: false, error: `This rider is in the live ride "${ride.name}". Hold or block them after the ride.`, code: 'USER_IN_ACTIVE_CONVOY' });
    }

    const changed = [];
    if (b.role !== undefined && b.role !== (u.role || 'RIDER')) {
      const before = u.role || 'RIDER';
      await auth.setRole(req.user, userId, b.role);
      await audit(req, 'user.role', userId, { from: before, to: b.role });
      changed.push('role');
    }
    if (status !== undefined && (status !== (u.status || 'ACTIVE') || (reason && reason !== (u.statusReason || '')))) {
      const before = u.status || 'ACTIVE';
      await auth.setUserStatus(req.user, userId, status, reason);
      if (status !== 'ACTIVE' && hub) hub.disconnectUser(userId, 4403, status === 'BLOCKED' ? 'ACCOUNT_BLOCKED' : 'ACCOUNT_ON_HOLD');
      await audit(req, 'user.status', userId, { from: before, to: status, reason });
      changed.push('status');
    }
    if (limits && limits.maxTrips !== undefined) {
      u = await repo.findUserById(userId);
      const before = limitsOf(u).maxTrips;
      const next = { ...(u.adminLimits && typeof u.adminLimits === 'object' ? u.adminLimits : {}) };
      if (limits.maxTrips === null) delete next.maxTrips; else next.maxTrips = limits.maxTrips;
      await repo.updateUser(u.key, { adminLimits: next });
      await audit(req, 'user.limits', userId, { maxTrips: { from: before, to: limits.maxTrips } });
      changed.push('limits');
    }
    if (plan) {
      u = await repo.findUserById(userId);
      const before = effectiveSubscription(u).tier;
      if (plan.tier === 'community') {
        if (before !== 'community' || isPaidTier(u.subscriptionTier)) {
          await plans.revoke({ req, userDoc: u, note: plan.note });
          changed.push('plan');
        }
      } else {
        await plans.grant({ req, userDoc: u, planTier: plan.tier, days: plan.days, reason: plan.note });
        changed.push('plan');
      }
    }
    if (gate && changed.length) gate.invalidate(userId);
    cache.clear();
    const after = await repo.findUserById(userId);
    res.set('Cache-Control', 'no-store').json({ ok: true, changed, config: await configView(after) });
  }));

  return { cache };
}

module.exports = {
  registerAdminAnalyticsRoutes, registerPublicUsageRoutes, overview, riderDetail, groupDetail, publicUsage, maxTripsFor, scan, median,
};
