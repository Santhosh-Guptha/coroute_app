'use strict';
/**
 * Trip report: per-member and group statistics computed from the uploaded
 * tracks plus the timeline. Stored on the convoy (`report`, kept forever,
 * contains no coordinates) and as one trip document per member in `trips`
 * (so the existing trip-history screen shows real numbers).
 */
const { analyseTrack, filterPoints } = require('./tracks');
const { simplify } = require('./geo_math');

const sumDur = (events, type, userId) => events
  .filter((e) => e.type === type && e.userId === userId)
  .reduce((s, e) => s + (e.durationMs || 0), 0);

function buildTripReport({ meta, tracksByUser, events }) {
  const minStopMs = (meta.stopThresholdSeconds ?? 180) * 1000;
  const members = Object.values(meta.members || {});
  const endedAt = meta.endedAtEpochMs || Date.now();
  const startedAt = meta.createdAtEpochMs || 0;
  const perMember = [];

  for (const m of members) {
    const points = tracksByUser.get(m.userId) || [];
    const a = analyseTrack(points, { minStopMs });
    const hasTrack = a.points.length >= 2;
    const liveStops = events.filter((e) => e.type === 'STOPPED' && e.userId === m.userId);
    const stops = hasTrack
      ? a.stops.map((s) => ({ startTs: s.startTs, endTs: s.endTs, durationMs: s.durationMs }))
      : liveStops.map((e) => ({ startTs: e.startedAt, endTs: e.endedAt || e.startedAt, durationMs: e.durationMs || 0 }));
    const restMs = stops.reduce((s, x) => s + x.durationMs, 0);
    const firstTs = hasTrack ? a.firstTs : (m.joinedAt || startedAt);
    const lastTs = hasTrack ? a.lastTs : (m.leftAt || endedAt);

    const stats = {
      userId: m.userId, name: m.name, role: m.role || 'PACK', vehicleType: m.vehicleType || '', vehicleNo: m.vehicleNo || '',
      joinedAt: m.firstJoinedAt || m.joinedAt || 0, leftAt: m.leftAt || 0,
      trackAvailable: hasTrack,
      firstFixAt: firstTs, lastFixAt: lastTs,
      durationMs: Math.max(0, lastTs - firstTs),
      distanceM: Math.round(a.distanceM),
      movingMs: hasTrack ? a.movingMs : Math.max(0, lastTs - firstTs - restMs),
      restMs,
      gapMs: a.gapMs,
      stops: stops.length,
      longestStopMs: stops.reduce((mx, s) => Math.max(mx, s.durationMs), 0),
      avgMovingKmh: a.avgMovingKmh,
      maxKmh: a.maxKmh,
      separatedMs: sumDur(events, 'SEPARATED', m.userId),
      offRouteMs: sumDur(events, 'OFF_ROUTE', m.userId),
      offlineMs: sumDur(events, 'OFFLINE', m.userId),
      sos: events.filter((e) => e.type === 'SOS' && e.userId === m.userId).length,
      reachedDestination: events.some((e) => e.type === 'DESTINATION_REACHED' && e.userId === m.userId),
    };

    const trail = hasTrack ? simplify(filterPoints(points), 20).slice(0, 4000) : [];
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
      breadcrumbTrail: trail.map((p) => ({ lat: +p.lat.toFixed(5), lng: +p.lng.toFixed(5), speedKmh: p.v || 0, heading: 0, timestamp: p.ts })),
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
      arrived: perMember.filter((p) => p.stats.reachedDestination).length,
    },
    members: perMember.map((p) => p.stats),
  };
  return { report, perMember };
}

module.exports = { buildTripReport };
