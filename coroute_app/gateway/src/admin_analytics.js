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
const { effectiveSubscription } = require('./subscription_lifecycle');
const { isStaffAccount, isGuestAccount, staffEmails, hasStaffMember } = require('./staff');
const { safeUsage, safeImpact, safeAllTime, PRIVACY_NOTE } = require('./public_privacy');
const { PublicStatsStore } = require('./public_stats');
const { planFrom, effectiveMembership } = require('./entitlements');
const { ADMIN_PLAN_CHOICES, adminPlanId, planView } = require('./admin_plans');

const DAY = 86400000;
const PAGE = 1000;
const SCAN_CAP = 50000;
const ROLES = ['RIDER', 'MASTER_ADMIN'];
const STATUSES = ['ACTIVE', 'ON_HOLD', 'BLOCKED'];
/** Plans an admin can filter by and assign (3.55: the plans riders have; legacy tier names are mapped). */
const TIERS = ADMIN_PLAN_CHOICES;
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
const isGuest = (u) => isGuestAccount(u);
/** Staff (admins, BOOTSTRAP_ADMIN_EMAILS, STAFF_EMAILS; see src/staff.js) among `users`, as a userId set. */
function staffSet(users) {
  const emails = staffEmails();
  return new Set(users.filter((u) => u && u.userId && !isGuest(u) && isStaffAccount(u, emails)).map((u) => u.userId));
}
/** userIds of every staff account: one indexed query when the repo has it, else a scan of users. */
async function staffIdsFor(repo) {
  if (typeof repo.staffUserIds === 'function') return repo.staffUserIds().catch(() => new Set());
  return staffSet((await scan(repo.soda, C.users)).rows);
}
const memberIdsOf = (c) => Object.keys(c?.members || {});
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
  // Staff (admins and STAFF_EMAILS) are never riders for these numbers; guests are counted apart as before.
  const staffIds = staffSet(users.rows);
  const riders = users.rows.filter((u) => !isGuest(u) && !staffIds.has(u.userId));
  const holders = membershipHolders(memberships.rows, now);
  const planHolders = riders.filter((u) => effectiveSubscription(u, now).tier !== 'community' || holders.has(u.userId)).length;
  const allPaidOrders = orders.rows.filter((o) => o.status === 'PAID' && num(o.amountInPaise) > 0);
  // A staff account's payments (usually checkout tests) are reported apart, never as rider revenue.
  const staffPaid = allPaidOrders.filter((o) => staffIds.has(o.userId));
  const paidOrders = allPaidOrders.filter((o) => !staffIds.has(o.userId));
  const liveOrders = paidOrders.filter((o) => o.mode !== 'test');
  const paying = new Set(liveOrders.map((o) => o.userId).filter(Boolean));
  const net = (o) => (num(o.amountInPaise) - num(o.refundedAmountInPaise)) / 100;
  const paidAt = (o) => num(o.paidAt) || num(o.createdAt);
  const tripsIn = trips.rows.filter((t) => num(t.endTimeEpochMs) >= since);
  const endedIn = ended.rows.filter((c) => num(c.endedAtEpochMs || c.updatedAt) >= since);
  // Group size counts riders only; a ride a staff account joined still counts as a ride (withStaff).
  const riderMembers = (c) => memberIdsOf(c).filter((id) => !staffIds.has(id)).length;
  const sized = ended.rows.filter((c) => riderMembers(c) > 0);
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
      excludesStaff: true,
      staff: staffIds.size,
      guests: users.rows.filter(isGuest).length,
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
      avgGroupSize: sized.length ? round1(sized.reduce((s, c) => s + riderMembers(c), 0) / sized.length) : 0,
      withStaff: ended.rows.filter((c) => hasStaffMember(memberIdsOf(c), staffIds)).length,
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
      couponOrders: orders.rows.filter((o) => o.status === 'PAID' && !staffIds.has(o.userId) && (o.couponCode || o.offerCode)).length,
      staffPaidOrders: staffPaid.length,
      staffRevenueInr: Math.round(staffPaid.reduce((s, o) => s + net(o), 0)),
    },
  };
}

// ---------------------------------------------------------------- trends (charts)

/** Day index of `ms` in the rider's local calendar (`tzMin` minutes east of UTC). */
const localDay = (ms, tzMin) => Math.floor((num(ms) + tzMin * 60000) / DAY);
/** `YYYY-MM-DD` of a local day index. */
const dayLabel = (d) => new Date(d * DAY).toISOString().slice(0, 10);

/**
 * Pure: buckets timestamps into `days` local days ending today (inclusive), oldest first.
 * `items` are `{ at, value?, key? }`; with `distinct` a key counts once per day.
 */
function bucketDays(items, { days, now, tzMin = 0, distinct = false }) {
  const today = localDay(now, tzMin);
  const first = today - days + 1;
  const out = new Array(days).fill(0);
  const seen = distinct ? Array.from({ length: days }, () => new Set()) : null;
  for (const it of items) {
    const at = num(it.at);
    if (at <= 0) continue;
    const i = localDay(at, tzMin) - first;
    if (i < 0 || i >= days) continue;
    if (seen) {
      if (it.key == null || seen[i].has(it.key)) continue;
      seen[i].add(it.key);
      out[i] += 1;
    } else {
      out[i] += it.value === undefined ? 1 : num(it.value);
    }
  }
  return out;
}

/**
 * Daily series for the admin overview charts: the last `days` local days and the
 * same number of days before them (for the "vs previous period" arrows), the plan
 * mix of riders, and what needs an admin's attention. Staff are never riders here.
 * Read-only; every number is counted from stored documents.
 */
async function trends({ repo, convoys, publicRideReports = null }, { days = 30, now = Date.now(), tzMin = 0 } = {}) {
  const soda = repo.soda;
  const [users, trips, ended, alerts, memberships] = await Promise.all([
    scan(soda, C.users), scan(soda, C.trips), scan(soda, C.convoys, { tripStatus: 'ENDED' }), scan(soda, C.alerts),
    scan(soda, C.memberships, {}, { cap: 20000 }),
  ]);
  const staffIds = staffSet(users.rows);
  const riders = users.rows.filter((u) => !isGuest(u) && !staffIds.has(u.userId));
  const riderTrips = trips.rows.filter((t) => !staffIds.has(t.userId));
  const span = days * 2; // current period + the one before it
  const split = (arr) => ({ current: arr.slice(days), previous: arr.slice(0, days) });
  const series = (items, opts = {}) => split(bucketDays(items, { days: span, now, tzMin, ...opts }));

  const rides = series(ended.rows.map((c) => ({ at: c.endedAtEpochMs || c.updatedAt })));
  const km = series(riderTrips.map((t) => ({ at: t.endTimeEpochMs, value: tripKm(t) })));
  const active = series(riderTrips.map((t) => ({ at: t.endTimeEpochMs, key: t.userId })), { distinct: true });
  const signups = series(riders.map((u) => ({ at: u.createdAt })));
  const sos = series(alerts.rows.map((a) => ({ at: a.timestamp || a.occurredAt })));
  const today = localDay(now, tzMin);
  const firstDay = today - days + 1;

  // Plan mix: the plan each rider has now (an owner's membership or legacy tier; a member counts under the group's plan).
  const owned = new Map();
  const memberOf = new Map();
  for (const m of memberships.rows) {
    if (m.status !== 'ACTIVE' || num(m.validUntil) <= now) continue;
    if (m.ownerUserId) owned.set(m.ownerUserId, m);
    for (const [uid, mem] of Object.entries(m.members || {})) if (uid !== m.ownerUserId && (!mem || mem.status !== 'REMOVED')) memberOf.set(uid, m.category);
  }
  const planCounts = new Map();
  for (const u of riders) {
    let id = adminPlanId(planFrom({ membership: owned.get(u.userId) || null, userDoc: u, now }).category) || 'community';
    if (id === 'community' && memberOf.has(u.userId)) id = adminPlanId(memberOf.get(u.userId)) || 'community';
    planCounts.set(id, (planCounts.get(id) || 0) + 1);
  }
  const plans = [...planCounts.entries()].map(([id, count]) => ({ id, count })).sort((a, b) => b.count - a.count);

  // Riders seen today (local day) and yesterday, from their last activity.
  const seenDay = (u) => localDay(u.lastActiveAt || u.lastLoginAt, tzMin);
  const activeToday = riders.filter((u) => seenDay(u) === today).length;

  // What needs attention: each count is independent, null when its source is unavailable.
  const safe = async (fn) => { try { return await fn(); } catch { return null; } };
  const [reviewsPending, photosPending, reportsOpen] = await Promise.all([
    safe(async () => (typeof repo.listTripFeedback === 'function' ? (await repo.listTripFeedback(500, 'PENDING_REVIEW')).length : null)),
    safe(async () => (typeof repo.listPlaceReviews === 'function'
      ? (await repo.listPlaceReviews({ limit: 300 })).reduce((n, x) => n + (x.uploads || []).filter((p) => p && p.approved !== true && !p.rejected).length, 0)
      : null)),
    safe(async () => (publicRideReports ? (await publicRideReports('OPEN')).length : null)),
  ]);

  return {
    ok: true,
    generatedAt: now,
    days,
    tzMin,
    truncated: [users, trips, ended, alerts, memberships].some((s) => s.truncated),
    labels: Array.from({ length: days }, (_, i) => dayLabel(firstDay + i)),
    series: {
      rides: rides.current, km: km.current.map(Math.round), activeRiders: active.current, signups: signups.current, sos: sos.current,
    },
    previous: {
      rides: rides.previous, km: km.previous.map(Math.round), activeRiders: active.previous, signups: signups.previous, sos: sos.previous,
    },
    riders: { total: riders.length, activeToday, activeYesterday: riders.filter((u) => seenDay(u) === today - 1).length },
    plans,
    attention: {
      openSos: alerts.rows.filter((a) => a.resolved !== true).length,
      liveRides: convoys?.rooms ? convoys.rooms.size : 0,
      reviewsPending,
      photosPending,
      reportsOpen,
      onHold: riders.filter((u) => u.status === 'ON_HOLD').length,
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

/** ownerUserId -> the owner's membership that is active now (the newest when several). */
function ownedMembershipMap(memberships, now) {
  const map = new Map();
  for (const raw of memberships) {
    const m = effectiveMembership(raw, now);
    if (!m || !m.ownerUserId || m.status !== 'ACTIVE' || num(m.validUntil) <= now) continue;
    const prev = map.get(m.ownerUserId);
    if (!prev || num(m.validUntil) > num(prev.validUntil)) map.set(m.ownerUserId, m);
  }
  return map;
}

function riderRow(u, totals, riding, now, emails = staffEmails(), owned = new Map()) {
  const t = totals.get(u.userId) || { trips: 0, km: 0, movingMs: 0, sos: 0, lastTripAt: 0 };
  // The plan the rider's app shows (membership, or a legacy tier until it ends), never only the legacy field.
  const plan = planFrom({ membership: owned.get(u.userId) || null, userDoc: u, now });
  return {
    userId: u.userId, name: u.name || '', email: u.email || '', phone: u.phone || '',
    username: u.username || '', avatarUrl: require('./avatars').avatarUrlOf(u.avatarId), // 3.55 (searchable)
    role: u.role || 'RIDER', status: u.status || 'ACTIVE', tier: plan.category || 'community', planName: plan.name || 'Community',
    planSource: plan.source || 'community', planValidUntil: num(plan.validUntil), guest: isGuest(u), staff: !isGuest(u) && isStaffAccount(u, emails),
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
  // The plan exactly as the rider's app has it (GET /membership/my uses the same planFrom).
  const p = planFrom({ membership, userDoc: u, now });
  const pUntil = num(p.validUntil);
  const resolved = {
    tier: p.category || 'community', name: p.name || 'Community', source: p.source || 'community', seats: p.seats || 1,
    validUntil: pUntil, daysRemaining: pUntil > now ? Math.ceil((pUntil - now) / DAY) : 0, legacyTier: p.legacyTier || null,
  };
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
      username: u.username || '', avatarUrl: require('./avatars').avatarUrlOf(u.avatarId), // 3.55 (admin can remove the picture)
      status: u.status || 'ACTIVE', statusReason: u.statusReason || '', provider: u.provider || 'password', guest: isGuest(u),
      staff: !isGuest(u) && isStaffAccount(u),
      createdAt: num(u.createdAt), lastSeenAt: Math.max(num(u.lastActiveAt || u.lastLoginAt), tripEnds.length ? Math.max(...tripEnds) : 0),
      appBuild: num(u.appBuild) || null, vehicleType: u.vehicleType || '', riding: riding.get(userId) || null,
      // 3.55: the active bike summary the rider's app shared (null when none was shared).
      bike: u.bikeModel || u.bikeColour || num(u.bikeCc) || num(u.bikeTankL) || num(u.bikeMileageKmL) ? {
        model: String(u.bikeModel || ''), cc: num(u.bikeCc), colour: String(u.bikeColour || ''),
        tankL: num(u.bikeTankL), mileageKmL: num(u.bikeMileageKmL),
        cooling: ['air', 'oil', 'liquid'].includes(u.bikeCooling) ? u.bikeCooling : 'unknown',
      } : null,
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
      ...resolved, rawTier: st.rawTier, isExpired: st.isExpired,
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

function groupRow(m, live, staffIds = new Set()) {
  const g = m.report?.group || {};
  const startedAt = num(m.createdAtEpochMs);
  const endedAt = num(m.endedAtEpochMs);
  return {
    groupId: m.groupId, name: m.name || 'Ride', status: live ? 'LIVE' : (m.tripStatus || 'ENDED'),
    createdByUserName: m.createdByUserName || '', startedAt, endedAt,
    members: Object.keys(m.members || {}).length,
    hasStaff: hasStaffMember(memberIdsOf(m), staffIds),
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
  const [events, alerts, staffIds] = await Promise.all([
    scan(soda, C.events, { groupId }, { cap: 10000 }),
    scan(soda, C.alerts, { groupId }, { cap: 2000 }),
    staffIdsFor(repo),
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
      staff: staffIds.has(uid),
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
      // A ride a staff account joined (often a test) still counts; this flag tells it apart.
      hasStaff: hasStaffMember(memberIds, staffIds),
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

/** Trips read for the all-time website totals (lease job every few minutes, never per request). */
const TOTALS_TRIP_CAP = 200000;
/** The keys of publicUsage (the older usage-stats view). */
const USAGE_KEYS = ['movingHours', 'avgSpeedKmh', 'weeklyKm', 'riders', 'ridesCompleted', 'kmRidden', 'groupsRidden', 'sosResolved', 'avgRating', 'ratingsCount', 'updatedAt'];

/**
 * Every community total the website may show, ALL-TIME and exact, in one pass per collection (3.55b).
 * The website only ever gets safeUsage / safeImpact / safeAllTime of this: rounded down, thresholded.
 *
 * Definitions (every one counted from stored documents; trips are kept forever, retention strips only
 * their GPS trail):
 *   riders            registered accounts: not guests, not staff (unchanged, the usage-stats "riders");
 *   ridersWithRide    of those, the riders with at least one completed ride (a saved trip) - the website's
 *                     headline "riders";
 *   ridesCompleted    saved trips (one per rider per ride), kmRidden their distance;
 *   movingHours       moving time of every trip with a distance (rider-hours on the road);
 *   groupRides        ended rides with two or more riders (= groupsRidden), largestGroup the most riders in one;
 *   longestTripKm     the longest single trip; bikes / bikeModels distinct registration numbers / models;
 *   safety            SOS resolved as real, crash alerts, alerts answered by a rider, median first response,
 *                     road reports still open;
 *   thisWeek          rides / km / hours / riders of trips that ended in the last 7 days (a secondary line);
 *   weeklyKm          the last 8 Monday-based UTC weeks (the ride analytics chart).
 * `truncated` is true when a scan cap was reached: every number is then a lower bound, which rounding
 * down and "+" keep honest.
 */
async function communityTotals(repo, now = Date.now()) {
  const soda = repo.soda;
  const [users, trips, ended, alerts, reviews, roads] = await Promise.all([
    scan(soda, C.users), scan(soda, C.trips, {}, { cap: TOTALS_TRIP_CAP }), scan(soda, C.convoys, { tripStatus: 'ENDED' }), scan(soda, C.alerts),
    scan(soda, C.feedback, { status: 'APPROVED' }, { cap: 5000 }),
    C.roadHazards ? scan(soda, C.roadHazards, {}, { cap: 20000 }) : { rows: [], truncated: false },
  ]);
  const staff = staffSet(users.rows);
  const riderDocs = users.rows.filter((u) => !isGuest(u) && !staff.has(u.userId));
  const riderIds = new Set(riderDocs.map((u) => u.userId));
  const ratings = reviews.rows.map((r) => r.rating).filter((x) => Number.isInteger(x) && x >= 1 && x <= 5);

  const WEEK = 7 * DAY;
  const d = new Date(now);
  const mondayUtc = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) - ((d.getUTCDay() + 6) % 7) * DAY;
  const weeks = [];
  for (let i = 7; i >= 0; i--) weeks.push({ weekStart: mondayUtc - i * WEEK, km: 0, rides: 0 });
  const week = { rides: 0, km: 0, movingMs: 0, riders: new Set() };
  const withRide = new Set();
  let movingMs = 0;
  let movingKm = 0;
  let km = 0;
  let longest = 0;
  for (const t of trips.rows) {
    const tk = tripKm(t);
    const ms = tripMovingMs(t);
    km += tk;
    if (tk > longest) longest = tk;
    if (ms > 0 && tk > 0) { movingMs += ms; movingKm += tk; }
    if (t.userId && riderIds.has(t.userId)) withRide.add(t.userId);
    const end = num(t.endTimeEpochMs);
    const w = weeks.find((x) => end >= x.weekStart && end < x.weekStart + WEEK);
    if (w) { w.km += tk; w.rides++; }
    if (end > now - WEEK && end <= now) {
      week.rides++; week.km += tk;
      if (ms > 0 && tk > 0) week.movingMs += ms;
      if (t.userId && riderIds.has(t.userId)) week.riders.add(t.userId);
    }
  }
  const bikes = new Set();
  const models = new Set();
  for (const u of riderDocs) {
    const pillion = String(u.vehicleType || '').toLowerCase() === 'pillion rider' || String(u.vehicleNo || '').toUpperCase() === 'PILLION';
    if (!pillion && String(u.vehicleNo || '').trim().length >= 3) bikes.add(String(u.vehicleNo).trim().toUpperCase());
    if (u.bikeModel) models.add(String(u.bikeModel).trim().toLowerCase());
  }
  const groupSizes = ended.rows.map((c) => Object.keys(c.members || {}).length).filter((n) => n >= 2);
  const real = alerts.rows.filter(sosResolvedReal);
  const responses = alerts.rows.map(firstResponseSec).filter((x) => x !== null);
  return {
    scope: 'all-time',
    riders: riderDocs.length,
    ridersWithRide: withRide.size,
    ridesCompleted: trips.rows.length,
    kmRidden: Math.round(km),
    movingHours: Math.floor(movingMs / 3600000),
    avgSpeedKmh: movingMs > 0 ? round1(movingKm / (movingMs / 3600000)) : null,
    weeklyKm: weeks.map((w) => ({ weekStart: w.weekStart, km: Math.round(w.km), rides: w.rides })),
    groupsRidden: groupSizes.length,
    groupRides: groupSizes.length,
    largestGroup: groupSizes.length ? Math.max(...groupSizes) : 0,
    longestTripKm: Math.floor(longest),
    bikes: bikes.size,
    bikeModels: models.size,
    sosResolved: real.length,
    avgRating: ratings.length ? round1(ratings.reduce((a, b) => a + b, 0) / ratings.length) : null,
    ratingsCount: ratings.length,
    safety: {
      sosResolved: real.length,
      crashAlerts: alerts.rows.filter((a) => /CRASH/.test(String(a.alertType || ''))).length,
      alertsAnswered: alerts.rows.filter((a) => Object.keys(a.responders || {}).length > 0).length,
      medianResponseSec: median(responses),
      responsesCounted: responses.length,
      roadReports: roads.rows.filter((h) => num(h.expiresAt) > now).length,
    },
    thisWeek: { rides: week.rides, km: Math.round(week.km), movingHours: Math.floor(week.movingMs / 3600000), riders: week.riders.size },
    truncated: !!(users.truncated || trips.truncated || ended.truncated || alerts.truncated),
    updatedAt: now,
  };
}

/** Aggregated, PII-free totals (exact): the usage-stats view of communityTotals. */
async function publicUsage(repo, now = Date.now()) {
  const t = await communityTotals(repo, now);
  const out = {};
  for (const k of USAGE_KEYS) out[k] = t[k];
  return out;
}

/** 3.55 website "CoRoute impact" numbers: communityTotals (made coarse by safeImpact). */
async function publicImpact(repo, now = Date.now()) {
  return communityTotals(repo, now);
}

// ---------------------------------------------------------------- routes

/**
 * Public website numbers (registered before authentication), all from ONE shared all-time aggregate
 * (src/public_stats.js: computed by one node every 5 min under the job lease, read from one document,
 * never a scan per request):
 *   GET /public/alltime-stats (+ /alltime-stats)  3.55b all-time totals (safeAllTime), cached 60 s;
 *   GET /public/impact-stats  (+ /impact-stats)   the impact tiles (safeImpact; all-time too), cached 60 s;
 *   GET /public/usage-stats   (+ /usage-stats)    the older usage view (safeUsage), cached 5 min.
 */
function registerPublicUsageRoutes({ r, repo, wrap, store = null }) {
  const totals = store || new PublicStatsStore({ repo });
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, message: { ok: false, error: 'Too many requests.' } });
  const shown = async () => {
    const cfg = typeof repo.getCommunityStatsConfig === 'function' ? await repo.getCommunityStatsConfig().catch(() => ({})) : {};
    return !(cfg && cfg.showPublicStats === false);
  };
  const view = (maxAge, safe, extra = {}) => wrap(async (req, res) => {
    res.set('Cache-Control', `public, max-age=${maxAge}`);
    if (!(await shown())) return res.json({ ok: true, enabled: false, stats: null });
    // Privacy: rounded down, nothing below 10, a rating only from 10 ratings, time to the hour (public_privacy.js).
    const stats = safe(await totals.get());
    res.json({ ok: true, enabled: true, ...extra, stats, privacy: PRIVACY_NOTE });
  });
  const usage = view(300, safeUsage);
  r.get('/public/usage-stats', limiter, usage);
  r.get('/usage-stats', limiter, usage);
  const impact = view(60, safeImpact);
  r.get('/public/impact-stats', limiter, impact);
  r.get('/impact-stats', limiter, impact);
  const allTime = view(60, safeAllTime, { scope: 'all-time' });
  r.get('/public/alltime-stats', limiter, allTime);
  r.get('/alltime-stats', limiter, allTime);
  return { store: totals };
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

  // Daily series for the overview charts. ?days=7|30|90&tz=<minutes east of UTC>
  r.get('/admin/analytics/trends', requireAdmin, wrap(async (req, res) => {
    const days = [7, 30, 90].includes(Number(req.query.days)) ? Number(req.query.days) : 30;
    const tzMin = clampInt(req.query.tz, -840, 840, 330);
    if (fresh(req)) cache.clear();
    const publicRideReports = async (status) => (await repo.soda.query('public_ride', { k: 'report', status }, { limit: 500 })).map((x) => x.value);
    res.set('Cache-Control', 'no-store').json(await cache.get(`trends:${days}:${tzMin}`, () => trends({ repo, convoys, publicRideReports }, { days, tzMin })));
  }));

  // ?q=&status=ACTIVE|ON_HOLD|BLOCKED&tier=&riding=1&staff=1|all&sort=lastSeen|joined|trips|km|sos|name&limit=&cursor=
  // Staff accounts are left out of the list and its total unless staff=1 (only staff) or staff=all (everyone).
  r.get('/admin/analytics/riders', requireAdmin, wrap(async (req, res) => {
    const now = Date.now();
    const limit = clampInt(req.query.limit, 1, 200, 50);
    const cursor = clampInt(req.query.cursor, 0, 1000000, 0);
    const q = String(req.query.q || '').trim().toLowerCase().slice(0, 100);
    const status = String(req.query.status || '').trim().toUpperCase();
    const tier = String(req.query.tier || '').trim();
    const sort = Object.hasOwn(RIDER_SORTS, req.query.sort) ? req.query.sort : 'lastSeen';
    if (fresh(req)) cache.clear();
    const [users, totals, riding, memberships] = await Promise.all([
      scan(repo.soda, C.users), cache.get('riderTotals', () => riderTotals(repo)), ridingMap(repo, convoys),
      scan(repo.soda, C.memberships, {}, { cap: 20000 }),
    ]);
    const emails = staffEmails();
    const owned = ownedMembershipMap(memberships.rows, now);
    let rows = users.rows.map((u) => riderRow(u, totals.by, riding, now, emails, owned));
    if (STATUSES.includes(status)) rows = rows.filter((x) => x.status === status);
    const tierId = adminPlanId(tier);
    if (tierId) rows = rows.filter((x) => x.tier === tierId);
    if (String(req.query.riding || '') === '1') rows = rows.filter((x) => x.riding);
    if (q) rows = rows.filter((x) => [x.name, x.email, x.phone, x.userId, x.username].some((v) => String(v || '').toLowerCase().includes(q)));
    const staffMode = ['1', 'all'].includes(String(req.query.staff || '')) ? String(req.query.staff) : '0';
    const staffCount = rows.filter((x) => x.staff).length;
    if (staffMode === '1') rows = rows.filter((x) => x.staff);
    else if (staffMode === '0') rows = rows.filter((x) => !x.staff);
    rows.sort(RIDER_SORTS[sort]);
    const page = rows.slice(cursor, cursor + limit);
    res.set('Cache-Control', 'no-store').json({
      ok: true, riders: page, total: rows.length, staffCount, excludesStaff: staffMode === '0', cursor, limit,
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
    const [scans, staffIds] = await Promise.all([Promise.all(parts), staffIdsFor(repo)]);
    let rows = scans.flatMap((s) => s.rows).map((m) => groupRow(m, liveIds.has(m.groupId), staffIds));
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
      plan: { ...(await planView(repo, u)), rawTier: st.rawTier, isExpired: st.isExpired },
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
      // Legacy tier names from an older console are mapped to their plan (proRider -> group_small ...).
      const tierId = b.plan && typeof b.plan === 'object' ? adminPlanId(b.plan.tier) : null;
      if (!tierId) return bad('BAD_TIER', `plan.tier must be one of ${TIERS.join(', ')}`);
      const days = tierId === 'community' ? 0 : Number(b.plan.days);
      if (tierId !== 'community' && (!Number.isInteger(days) || days < 1 || days > 3660)) return bad('BAD_DAYS', 'plan.days must be a whole number from 1 to 3660');
      plan = { tier: tierId, days, note: typeof b.plan.note === 'string' ? b.plan.note.trim().slice(0, 500) : '' };
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
      try {
        const out = await plans.assign({ req, userDoc: u, plan: plan.tier, days: plan.days, note: plan.note });
        if (out.changed) changed.push('plan');
      } catch (e) {
        if (e && e.code && e.status) return res.status(e.status).json({ ok: false, error: e.message, code: e.code, changed });
        throw e;
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
  registerAdminAnalyticsRoutes, registerPublicUsageRoutes, overview, trends, bucketDays, riderDetail, groupDetail, publicUsage, publicImpact, communityTotals, maxTripsFor, scan, median,
};
