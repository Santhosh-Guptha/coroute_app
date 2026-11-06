'use strict';
/**
 * The trip summary must show only the route the rider really rode: their own cleaned track, cut
 * at signal gaps, never a planned / re-routed line, never another rider's or another trip's
 * points. Synthetic tracks reproduce each way a wrong line used to appear.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { filterPoints, splitSegments, segmentedTrail, analyseTrack, toWire, toGpx, TrackStore, encodeChunkBody } = require('../src/tracks');
const { buildTripReport } = require('../src/report');
const { tripRecord, downsample } = require('../src/validate');
const { TimelineEngine } = require('../src/timeline');
const { haversine } = require('../src/geo_math');

const T0 = Date.UTC(2026, 10, 1, 4, 0, 0);
const KM_LAT = 1 / 111.195;

/** A ride north at `kmh` from (lat, 78.4), one fix every `stepS` s, `n` fixes. */
function ride({ t = T0, lat = 17, lng = 78.4, kmh = 60, stepS = 5, n = 60, acc = 6 } = {}) {
  const out = [];
  for (let i = 0; i < n; i++) out.push({ ts: t + i * stepS * 1000, lat: lat + (kmh * stepS * i / 3600) * KM_LAT, lng, v: kmh, acc });
  return out;
}
const last = (a) => a[a.length - 1];
const pathLen = (pts) => pts.slice(1).reduce((s, p, i) => s + haversine(pts[i].lat, pts[i].lng, p.lat, p.lng), 0);

test('a wrong first fix (cold start) no longer throws the whole ride away', () => {
  const real = ride({ t: T0 + 2000 });
  const bad = { ts: T0, lat: 17.3, lng: 78.9, v: 0, acc: 20 }; // 60 km away, plausible accuracy
  const clean = filterPoints([bad, ...real]);
  assert.equal(clean.length, real.length, 'every real fix kept');
  assert.equal(clean[0].ts, real[0].ts, 'the bad first fix is dropped');
});

test('single spikes, stray last fixes, coarse and dead-reckoned (80 m) fixes are dropped', () => {
  const real = ride({ n: 40 });
  const spike = { ...real[10], ts: real[10].ts + 1000, lat: real[10].lat + 0.02 }; // 2.2 km off for one fix
  const coarse = { ...real[20], ts: real[20].ts + 1000, lat: real[20].lat + 0.003, acc: 80 }; // coasting estimate
  const stray = { ts: last(real).ts + 1000, lat: 18.5, lng: 79.5, v: 0, acc: 10 };
  const clean = filterPoints([...real, spike, coarse, stray]);
  assert.equal(clean.length, real.length);
  assert.ok(clean.every((p) => real.some((r) => r.ts === p.ts)));
});

test('out-of-order chunks and duplicates are merged by time', () => {
  const real = ride({ n: 30 });
  const shuffled = [...real.slice(20), ...real.slice(0, 10), ...real.slice(10, 20), real[5], real[25]];
  const clean = filterPoints(shuffled);
  assert.deepEqual(clean.map((p) => p.ts), real.map((p) => p.ts));
});

test('a signal gap splits the track: wire breaks, trail gap flags, GPX segments, honest distances', () => {
  const a = ride({ n: 60 }); // 5 min, 5 km
  // 12 minutes without signal, 9 km further on (a dead zone in the hills).
  const b = ride({ t: last(a).ts + 12 * 60000, lat: last(a).lat + 9 * KM_LAT, n: 60 });
  const pts = [...a, ...b];
  const segs = splitSegments(pts);
  assert.equal(segs.length, 2);
  assert.equal(segs[1][0].ts, b[0].ts);

  // Maps: the 5th element starts a new piece; nothing joins the dead zone with a ridden line.
  const wire = toWire(pts, 8);
  const breaks = wire.filter((r) => r[4] === 1);
  assert.equal(breaks.length, 1);
  assert.equal(breaks[0][0], b[0].ts);
  assert.ok(wire.length < pts.length, 'still simplified');

  // Stored trip trail: same cut (gap: true), simplified per segment.
  const trail = segmentedTrail(pts, { toleranceM: 20 });
  assert.equal(trail.filter((p) => p.gap).length, 1);
  assert.equal(trail.find((p) => p.gap).ts, b[0].ts);

  const gpx = toGpx({ name: 'Ride', tracks: [{ name: 'me', points: pts }] });
  assert.equal((gpx.match(/<trkseg>/g) || []).length, 2);

  const an = analyseTrack(pts);
  assert.equal(an.pieces, 2);
  assert.ok(Math.abs(an.recordedDistanceM - (pathLen(a) + pathLen(b))) < 5);
  assert.ok(Math.abs(an.gapDistanceM - haversine(last(a).lat, last(a).lng, b[0].lat, b[0].lng)) < 5);
});

test('a two-minute rule: short pause in place is one piece; a 3-minute gap while moving is cut', () => {
  const a = ride({ n: 20 });
  const parked = ride({ t: last(a).ts + 10 * 60000, lat: last(a).lat + 0.00005, n: 20 }); // 10 min later, 5 m away
  assert.equal(splitSegments([...a, ...parked]).length, 1);
  const moved = ride({ t: last(a).ts + 3 * 60000, lat: last(a).lat + 3 * KM_LAT, n: 20 });
  assert.equal(splitSegments([...a, ...moved]).length, 2);
});

test('the retention-simplified track (a point at least every minute) is not cut into gaps', () => {
  const pts = [];
  for (let i = 0; i < 60; i++) pts.push({ ts: T0 + i * 60000, lat: 17 + i * 1.6 * KM_LAT, lng: 78.4, v: 96, acc: 5 }); // 1.6 km apart
  assert.equal(splitSegments(pts).length, 1);
  assert.equal(toWire(pts).filter((r) => r.length > 4).length, 0);
});

test('two plausible runs joined by a teleport: the jump is cut and never counted as distance', () => {
  const a = ride({ n: 30 });
  const b = ride({ t: last(a).ts + 5000, lat: 17.5, lng: 79.0, n: 30 }); // 70 km in 5 s
  const an = analyseTrack([...a, ...b]);
  assert.equal(an.pieces, 2);
  assert.ok(an.distanceM < pathLen(a) + pathLen(b) + 50, `distance ${an.distanceM}`);
});

test('the report trail is the rider\'s own cleaned track only, flagged at gaps', () => {
  const mine = [...ride({ n: 60 }), ...ride({ t: T0 + 20 * 60000, lat: 17.2, n: 60 })];
  const theirs = ride({ lat: 17.05, lng: 78.45, n: 60 });
  const meta = {
    groupId: 'GRP-TRUTH', name: 'Truth', createdAtEpochMs: T0 - 60000, endedAtEpochMs: T0 + 40 * 60000,
    members: { u1: { userId: 'u1', name: 'One' }, u2: { userId: 'u2', name: 'Two' } },
    route: { polyline: '_p~iF~ps|U_ulLnnqC_mqNvxq`@' }, // a planned / re-routed line elsewhere: never part of a trail
  };
  const { perMember } = buildTripReport({ meta, tracksByUser: new Map([['u1', mine], ['u2', theirs]]), events: [] });
  const one = perMember.find((p) => p.userId === 'u1').tripDoc.breadcrumbTrail;
  assert.ok(one.every((p) => Math.abs(p.lng - 78.4) < 1e-4), 'no point of the other rider or the planned line');
  assert.equal(one.filter((p) => p.gap).length, 1);
  assert.ok(one.every((p, i) => i === 0 || p.timestamp > one[i - 1].timestamp), 'ordered by time');
  const row = perMember.find((p) => p.userId === 'u1').stats;
  assert.equal(row.statsSource, 'server');
  assert.ok(row.gapDistanceM > 1000);
});

test('trip upload keeps gap flags (also when downsampled) and the phone\'s own numbers', () => {
  const trail = [];
  for (let i = 0; i < 100; i++) trail.push({ lat: 17 + i * 0.001, lng: 78.4, timestamp: T0 + i * 1000, ...(i === 51 ? { gap: true } : {}) });
  const rec = tripRecord({ tripId: 'TRIP-X-u1', breadcrumbTrail: trail, clientStats: { distanceM: 12345, movingMs: 600000, points: 100, firstFixAt: T0, lastFixAt: T0 + 99000, bogus: 'x', maxKmh: -3 } }, { maxPoints: 10 });
  assert.equal(rec.breadcrumbTrail.length, 10);
  assert.equal(rec.breadcrumbTrail.filter((p) => p.gap).length, 1, 'the gap survives downsampling');
  assert.deepEqual(rec.clientStats, { distanceM: 12345, movingMs: 600000, points: 100, firstFixAt: T0, lastFixAt: T0 + 99000 });
  assert.deepEqual(downsample([1, 2, 3], 5), [1, 2, 3]);
});

// ------------------------------------------------------------ server load: lazy report, windowed off-route
function fakeWorld({ meta, tracks, trips = new Map() }) {
  const convoys = new EventEmitter();
  convoys.rooms = new Map();
  convoys._emit = () => {};
  let stored = { ...meta };
  const loads = [];
  const repo = {
    getConvoyMeta: async () => stored,
    saveConvoyMeta: async (m) => { stored = m; },
    listEvents: async () => [],
    listOpenEvents: async () => [],
    upsertEvent: async () => {},
    removeEvent: async () => {},
    findUserById: async (id) => ({ userId: id }),
    getTrip: async (id) => trips.get(id) || null,
    saveTrip: async (t) => { trips.set(t.tripId, t); },
  };
  const store = { load: async (gid, { userId } = {}) => { loads.push(userId || '*'); return new Map([...tracks].filter(([u]) => !userId || u === userId)); } };
  const tl = new TimelineEngine({ convoys, repo, tracks: store, logger: { warn() {} } });
  return { tl, repo, trips, loads, convoys, meta: () => stored };
}

test('late upload: only that rider is analysed again; the others keep their report row', async () => {
  const meta = {
    groupId: 'GRP-LAZY', name: 'Lazy', tripStatus: 'ENDED', createdAtEpochMs: T0 - 60000, endedAtEpochMs: T0 + 60 * 60000,
    members: { u1: { userId: 'u1', name: 'One', joinedAt: T0 - 60000 }, u2: { userId: 'u2', name: 'Two', joinedAt: T0 - 60000 } },
  };
  const tracks = new Map([['u1', ride({ n: 60 })], ['u2', ride({ lng: 78.5, n: 60 })]]);
  const w = fakeWorld({ meta, tracks });
  try {
    await w.tl.finishTrip('GRP-LAZY');
    assert.deepEqual(w.loads, ['*']);
    const firstU2 = w.meta().report.members.find((m) => m.userId === 'u2');
    tracks.set('u1', ride({ n: 120 })); // u1's backlog arrives after the end
    w.trips.delete('TRIP-LAZY-u2'); // would be re-created by a full rebuild
    await w.tl.finishTrip('GRP-LAZY', { only: new Set(['u1']) });
    assert.deepEqual(w.loads, ['*', 'u1'], 'only the uploader\'s track is loaded');
    const rep = w.meta().report;
    assert.ok(rep.members.find((m) => m.userId === 'u1').distanceM > 9000);
    assert.deepEqual(rep.members.find((m) => m.userId === 'u2'), firstU2, 'u2 row reused as is');
    assert.equal(w.trips.has('TRIP-LAZY-u2'), false, 'no trip document rewritten for u2');
    assert.equal(w.tl.stats.reportRidersReused, 1);
  } finally { w.tl.stop(); }
});

test('no track on the server: the phone\'s own numbers and trail are used (old builds: timeline fallback)', async () => {
  const meta = {
    groupId: 'GRP-DEV', name: 'Dev', tripStatus: 'ENDED', createdAtEpochMs: T0, endedAtEpochMs: T0 + 3600000,
    members: { u1: { userId: 'u1', name: 'One', joinedAt: T0 }, u2: { userId: 'u2', name: 'Two', joinedAt: T0 } },
  };
  const trips = new Map([['TRIP-DEV-u1', {
    tripId: 'TRIP-DEV-u1', userId: 'u1', source: 'device',
    breadcrumbTrail: [{ lat: 17, lng: 78.4, timestamp: T0 }, { lat: 17.1, lng: 78.4, timestamp: T0 + 600000 }],
    clientStats: { distanceM: 11200, movingMs: 600000, restMs: 0, maxKmh: 71, avgMovingKmh: 67.2, stops: 0, firstFixAt: T0, lastFixAt: T0 + 600000, points: 120 },
  }]]);
  const w = fakeWorld({ meta, tracks: new Map(), trips });
  try {
    await w.tl.finishTrip('GRP-DEV');
    const rep = w.meta().report;
    const r1 = rep.members.find((m) => m.userId === 'u1');
    assert.equal(r1.statsSource, 'device');
    assert.equal(r1.distanceM, 11200);
    assert.equal(r1.maxKmh, 71);
    assert.equal(w.trips.get('TRIP-DEV-u1').breadcrumbTrail.length, 2, 'the phone trail is kept');
    assert.equal(rep.members.find((m) => m.userId === 'u2').statsSource, 'timeline');
  } finally { w.tl.stop(); }
});

test('off-route on the server: checked at most every 5 s per rider, near the last segment first', async () => {
  const route = [];
  for (let i = 0; i <= 2000; i++) route.push({ lat: 17 + i * 0.0005, lng: 78.4 }); // ~111 km, 2001 points
  const meta = {
    groupId: 'GRP-OFF', name: 'Off', tripStatus: 'STARTED', createdAtEpochMs: T0, offRouteMeters: 300,
    members: { u1: { userId: 'u1', name: 'One' } }, route: { waypoints: route },
  };
  const w = fakeWorld({ meta, tracks: new Map() });
  w.convoys.rooms.set('GRP-OFF', { meta, riders: new Map([['u1', { userId: 'u1', name: 'One' }]]) });
  const opened = [];
  w.tl._open = async (gid, st, slot, ev) => { opened.push(ev.type); st.open.set(slot, ev); return ev; };
  w.tl._close = async (gid, st, slot) => { st.open.delete(slot); };
  try {
    // 60 fixes, one per second, on the route.
    for (let i = 0; i < 60; i++) await w.tl.onTelemetry('GRP-OFF', { userId: 'u1', name: 'One', lat: 17.01 + i * 0.0002, lng: 78.4, speedKmh: 70, lastSeenEpochMs: T0 + i * 1000 });
    assert.ok(w.tl.stats.offRouteChecks <= 13, `checks ${w.tl.stats.offRouteChecks}`);
    assert.equal(w.tl.stats.offRouteFullScans, 0);
    // 2 km off the route for 90 s: an OFF_ROUTE entry after the hold time.
    for (let i = 0; i < 90; i++) await w.tl.onTelemetry('GRP-OFF', { userId: 'u1', name: 'One', lat: 17.03, lng: 78.42, speedKmh: 40, lastSeenEpochMs: T0 + 70000 + i * 1000 });
    assert.deepEqual(opened.filter((t) => t === 'OFF_ROUTE'), ['OFF_ROUTE']);
  } finally { w.tl.stop(); }
});

test('two riders\' chunks never mix and simplified documents read like the rest', async () => {
  const rows = [];
  const repo = {
    existingTrackSeqs: async () => new Set(),
    insertTrackChunks: async (docs) => { rows.push(...docs); },
    listTrackChunks: async (gid, { userId } = {}) => rows.filter((r) => r.groupId === gid && (!userId || r.userId === userId)),
  };
  const ts = new TrackStore(repo, { flushMs: 0 });
  const a = ride({ n: 30 });
  const b = ride({ lng: 78.6, n: 30 });
  rows.push({ groupId: 'G', userId: 'u1', seq: 2, ...encodeChunkBody(a.slice(15)) });
  rows.push({ groupId: 'G', userId: 'u2', seq: 1, ...encodeChunkBody(b) });
  rows.push({ groupId: 'G', userId: 'u1', seq: -5, simplified: true, ...encodeChunkBody(a.slice(0, 16)) });
  rows.push({ groupId: 'OTHER', userId: 'u1', seq: 1, ...encodeChunkBody(ride({ lat: 18, n: 10 })) });
  const one = (await ts.load('G', { userId: 'u1' })).get('u1');
  assert.equal(one.length, 30);
  assert.ok(one.every((p) => Math.abs(p.lng - 78.4) < 1e-5 && p.lat < 17.1));
  assert.deepEqual(one.map((p) => p.ts), a.map((p) => p.ts));
});
