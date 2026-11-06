'use strict';
/**
 * Trip report: per-member and group statistics computed from the uploaded
 * tracks plus the timeline. Stored on the convoy (`report`, kept forever,
 * contains no coordinates) and as one trip document per member in `trips`
 * (so the existing trip-history screen shows real numbers).
 */
const { analyseTrack, segmentedTrail } = require('./tracks');

/** Numbers a phone computed from its own recorded track (see app TripStats), or null when unusable. */
function deviceStats(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const n = (k, max) => { const v = Number(raw[k]); return Number.isFinite(v) && v >= 0 ? Math.min(v, max) : 0; };
  const out = {
    distanceM: Math.round(n('distanceM', 5e6)), movingMs: n('movingMs', 7 * 864e5), restMs: n('restMs', 7 * 864e5), gapMs: n('gapMs', 7 * 864e5),
    maxKmh: Math.round(n('maxKmh', 300)), avgMovingKmh: +n('avgMovingKmh', 300).toFixed(1), stops: Math.round(n('stops', 1000)),
    longestStopMs: n('longestStopMs', 7 * 864e5), firstFixAt: n('firstFixAt', 1e15), lastFixAt: n('lastFixAt', 1e15), points: Math.round(n('points', 1e7)),
  };
  return out.points >= 2 && out.lastFixAt >= out.firstFixAt ? out : null;
}

const sumDur = (events, type, userId) => events
  .filter((e) => e.type === type && e.userId === userId)
  .reduce((s, e) => s + (e.durationMs || 0), 0);

/** Times over the group speed limit, total time over it and the top speed while over. */
function overspeed(events, userId) {
  const list = events.filter((e) => e.type === 'OVERSPEED' && e.userId === userId);
  return {
    overspeedCount: list.length,
    overspeedMs: list.reduce((s, e) => s + (e.durationMs || 0), 0),
    overspeedMaxKmh: list.reduce((mx, e) => Math.max(mx, Number(e.data?.maxKmh) || 0), 0),
  };
}

/**
 * `deviceStatsByUser` (optional): the numbers each phone computed from its own track, used for a
 * rider whose track never reached the server (older uploads failed, trip closed for uploads).
 * `only` + `previous` (optional, late uploads): only the riders in `only` are analysed again; the
 * others keep their row of the `previous` report (no analysis, no trip document).
 */
function buildTripReport({ meta, tracksByUser, events, deviceStatsByUser = null, only = null, previous = null }) {
  const minStopMs = (meta.stopThresholdSeconds ?? 180) * 1000;
  const members = Object.values(meta.members || {});
  const endedAt = meta.endedAtEpochMs || Date.now();
  const startedAt = meta.createdAtEpochMs || 0;
  const perMember = [];

  const prevRows = new Map((previous?.members || []).map((r) => [r.userId, r]));
  for (const m of members) {
    if (only && !only.has(m.userId) && prevRows.has(m.userId)) {
      perMember.push({ userId: m.userId, name: m.name, analysis: null, stats: prevRows.get(m.userId), tripDoc: null, reused: true });
      continue;
    }
    const points = tracksByUser.get(m.userId) || [];
    const a = analyseTrack(points, { minStopMs });
    const hasTrack = a.points.length >= 2;
    const dev = hasTrack ? null : deviceStats(deviceStatsByUser?.get?.(m.userId));
    const liveStops = events.filter((e) => e.type === 'STOPPED' && e.userId === m.userId);
    const stops = hasTrack
      ? a.stops.map((s) => ({ startTs: s.startTs, endTs: s.endTs, durationMs: s.durationMs }))
      : liveStops.map((e) => ({ startTs: e.startedAt, endTs: e.endedAt || e.startedAt, durationMs: e.durationMs || 0 }));
    const restMs = stops.reduce((s, x) => s + x.durationMs, 0);
    const firstTs = hasTrack ? a.firstTs : (dev ? dev.firstFixAt : (m.joinedAt || startedAt));
    const lastTs = hasTrack ? a.lastTs : (dev ? dev.lastFixAt : (m.leftAt || endedAt));

    const stats = {
      userId: m.userId, name: m.name, role: m.role || 'PACK', vehicleType: m.vehicleType || '', vehicleNo: m.vehicleNo || '',
      joinedAt: m.firstJoinedAt || m.joinedAt || 0, leftAt: m.leftAt || 0,
      trackAvailable: hasTrack || !!dev,
      statsSource: hasTrack ? 'server' : (dev ? 'device' : 'timeline'),
      firstFixAt: firstTs, lastFixAt: lastTs,
      durationMs: Math.max(0, lastTs - firstTs),
      distanceM: dev ? dev.distanceM : Math.round(a.distanceM),
      // Straight lines across signal gaps (part of distanceM, never drawn as a ridden line).
      gapDistanceM: hasTrack ? Math.round(a.gapDistanceM) : 0,
      movingMs: hasTrack ? a.movingMs : (dev ? dev.movingMs : Math.max(0, lastTs - firstTs - restMs)),
      restMs: dev ? dev.restMs : restMs,
      gapMs: dev ? dev.gapMs : a.gapMs,
      stops: dev ? dev.stops : stops.length,
      longestStopMs: dev ? dev.longestStopMs : stops.reduce((mx, s) => Math.max(mx, s.durationMs), 0),
      avgMovingKmh: dev ? dev.avgMovingKmh : a.avgMovingKmh,
      maxKmh: dev ? dev.maxKmh : a.maxKmh,
      separatedMs: sumDur(events, 'SEPARATED', m.userId),
      offRouteMs: sumDur(events, 'OFF_ROUTE', m.userId),
      offlineMs: sumDur(events, 'OFFLINE', m.userId),
      sos: events.filter((e) => e.type === 'SOS' && e.userId === m.userId).length,
      ...overspeed(events, m.userId),
      reachedDestination: events.some((e) => e.type === 'DESTINATION_REACHED' && e.userId === m.userId),
    };

    // Only this rider's own cleaned track, cut at signal gaps (the first point after one has gap: true).
    const trail = hasTrack ? segmentedTrail(a.points, { toleranceM: 20, maxPoints: 4000 }) : [];
    const tripDoc = {
      tripId: `TRIP-${String(meta.groupId).replace('GRP-', '')}-${m.userId}`,
      source: 'server',
      groupId: meta.groupId,
      userId: m.userId,
      tripName: meta.name,
      startLocationName: meta.startLocationName || meta.start?.name || '',
      destinationName: meta.destinationName || '',
      startTimeEpochMs: stats.joinedAt || startedAt,
      endTimeEpochMs: stats.leftAt || endedAt,
      totalDistanceKm: +(stats.distanceM / 1000).toFixed(1),
      topSpeedKmh: stats.maxKmh,
      avgSpeedKmh: stats.avgMovingKmh,
      riderCount: members.length,
      stopCount: stats.stops,
      movingMs: stats.movingMs,
      restMs: stats.restMs,
      createdByUserName: meta.createdByUserName || '',
      breadcrumbTrail: trail.map((p) => ({ lat: +p.lat.toFixed(5), lng: +p.lng.toFixed(5), speedKmh: p.v || 0, heading: 0, timestamp: p.ts, ...(p.gap ? { gap: true } : {}) })),
      savedAt: Date.now(),
    };
    perMember.push({ userId: m.userId, name: m.name, analysis: a, stats, tripDoc });
  }

  const visitedStops = (meta.stopPoints || []).filter((s) => s.isVisited).length;
  const report = {
    version: 1,
    generatedAt: Date.now(),
    group: {
      name: meta.name, startedAt, endedAt, durationMs: Math.max(0, endedAt - startedAt),
      members: members.length,
      distanceM: perMember.reduce((mx, p) => Math.max(mx, p.stats.distanceM), 0),
      plannedStops: (meta.stopPoints || []).length, visitedStops,
      sos: events.filter((e) => e.type === 'SOS').length,
      speedLimitKmh: meta.speedLimitKmh || 0,
      overspeedCount: events.filter((e) => e.type === 'OVERSPEED').length,
      arrived: perMember.filter((p) => p.stats.reachedDestination).length,
    },
    members: perMember.map((p) => p.stats),
  };
  return { report, perMember };
}

module.exports = { buildTripReport, deviceStats };
