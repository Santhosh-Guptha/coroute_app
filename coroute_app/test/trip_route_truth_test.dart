import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:coroute_app/data/local/track_queue.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/track_recorder.dart';
import 'package:coroute_app/data/services/track_uploader.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/domain/tracking/replay_math.dart';
import 'package:coroute_app/domain/tracking/track_cleaner.dart';
import 'package:coroute_app/domain/tracking/track_filter.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/report/ride_share_card.dart';

/// The trip summary shows only the route the rider really rode. Synthetic
/// tracks reproduce each way a wrong line used to appear (see also
/// gateway/test/trip_route_truth.test.js, same rules).
const int t0 = 1800000000000;
const double kmLat = 1 / 111.195;

/// A ride north at [kmh], one fix every [stepS] s.
List<TrackPoint> ride({int t = t0, double lat = 17, double lng = 78.4, double kmh = 60, int stepS = 5, int n = 60, double acc = 6}) => [
      for (var i = 0; i < n; i++)
        TrackPoint(ts: t + i * stepS * 1000, lat: lat + kmh * stepS * i / 3600 * kmLat, lng: lng, speedKmh: kmh, accuracyM: acc),
    ];

double pathLen(List<TrackPoint> p) {
  var d = 0.0;
  for (var i = 1; i < p.length; i++) {
    d += GeoMath.haversine(p[i - 1].lat, p[i - 1].lng, p[i].lat, p[i].lng);
  }
  return d;
}

void main() {
  group('Cleaning the recorded track', () {
    test('a wrong first fix after a cold start does not throw the ride away', () {
      final real = ride(t: t0 + 2000);
      const bad = TrackPoint(ts: t0, lat: 17.3, lng: 78.9, accuracyM: 20);
      final clean = TrackCleaner.clean([bad, ...real]);
      expect(clean.length, real.length);
      expect(clean.first.ts, real.first.ts);
    });

    test('spikes, a stray last fix and coasting estimates (80 m) are dropped; order restored', () {
      final real = ride(n: 40);
      final spike = TrackPoint(ts: real[10].ts + 1000, lat: real[10].lat + 0.02, lng: 78.4, accuracyM: 8);
      final coasting = TrackPoint(ts: real[20].ts + 1000, lat: real[20].lat + 0.003, lng: 78.4, accuracyM: 80);
      final stray = TrackPoint(ts: real.last.ts + 1000, lat: 18.5, lng: 79.5, accuracyM: 10);
      final clean = TrackCleaner.clean([...real.reversed, spike, coasting, stray, real[3]]);
      expect(clean.map((p) => p.ts).toList(), real.map((p) => p.ts).toList());
    });

    test('segments: a 3-minute gap while moving cuts, a parked pause and a minute-spaced (simplified) track do not', () {
      final a = ride(n: 20);
      final moved = ride(t: a.last.ts + 3 * 60000, lat: a.last.lat + 3 * kmLat, n: 20);
      expect(TrackCleaner.segments([...a, ...moved]).length, 2);
      final parked = ride(t: a.last.ts + 10 * 60000, lat: a.last.lat + 0.00005, n: 20);
      expect(TrackCleaner.segments([...a, ...parked]).length, 1);
      final sparse = [for (var i = 0; i < 60; i++) TrackPoint(ts: t0 + i * 60000, lat: 17 + i * 1.6 * kmLat, lng: 78.4, speedKmh: 96)];
      expect(TrackCleaner.segments(sparse).length, 1);
    });

    test('trail: simplified per segment, the first point after a gap is marked', () {
      final a = ride(n: 60);
      final b = ride(t: a.last.ts + 12 * 60000, lat: a.last.lat + 9 * kmLat, n: 60);
      final trail = TrackCleaner.trail([...a, ...b]);
      expect(trail.length, lessThan(a.length + b.length));
      expect(trail.where((e) => e.gapBefore).map((e) => e.point.ts).toList(), [b.first.ts]);
    });
  });

  group('Trip numbers on the phone (same rules as the gateway)', () {
    test('distance, recorded distance and the straight line across a dead zone', () {
      final a = ride(n: 60);
      final b = ride(t: a.last.ts + 12 * 60000, lat: a.last.lat + 9 * kmLat, n: 60);
      final s = TripStats.compute([...a, ...b]);
      final gap = GeoMath.haversine(a.last.lat, a.last.lng, b.first.lat, b.first.lng);
      expect(s.pieces, 2);
      expect(s.recordedDistanceM, closeTo(pathLen(a) + pathLen(b), 5));
      expect(s.gapDistanceM, closeTo(gap, 5));
      expect(s.distanceM, closeTo(pathLen(a) + pathLen(b) + gap, 5));
      expect(s.avgMovingKmh, closeTo(60, 3), reason: 'the gap is not riding time');
      expect(s.maxKmh, 60);
      final json = s.toJson();
      expect(json['points'], a.length + b.length);
      expect(json['pieces'], 2);
    });

    test('a teleport between two plausible runs is never counted', () {
      final a = ride(n: 30);
      final b = ride(t: a.last.ts + 5000, lat: 17.5, lng: 79.0, n: 30);
      final s = TripStats.compute([...a, ...b]);
      expect(s.distanceM, lessThan(pathLen(a) + pathLen(b) + 50));
      expect(s.pieces, 2);
    });

    test('a parked stop counts as rest, not distance', () {
      final a = ride(n: 60);
      final parked = [for (var i = 1; i <= 60; i++) TrackPoint(ts: a.last.ts + i * 10000, lat: a.last.lat + (i.isEven ? 0.00002 : -0.00002), lng: 78.4, accuracyM: 6)];
      final s = TripStats.compute([...a, ...parked], minStop: const Duration(minutes: 3));
      expect(s.stops.length, 1);
      expect(s.restMs, greaterThan(9 * 60000));
      expect(s.distanceM, closeTo(pathLen(a), 20));
    });
  });

  group('Recording', () {
    test('the phone filter re-anchors after a wrong first fix instead of dropping the ride', () {
      final f = TrackFilter();
      expect(f.accept(const TrackPoint(ts: t0, lat: 17.3, lng: 78.9, accuracyM: 10)), isTrue);
      final real = ride(t: t0 + 1000, stepS: 1, n: 10);
      final accepted = [for (final p in real) f.accept(p)];
      expect(accepted.take(2), [false, false]);
      expect(accepted[2], isTrue, reason: 'three fixes agree: the first fix was the bad one');
      expect(accepted.skip(3).every((x) => x), isTrue);
    });

    test('estimated positions (tunnel coasting on the planned route) are never recorded; the summary is computed on the phone', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      recorder.start('GRP-T');
      final real = ride(n: 40);
      for (final p in real.take(20)) {
        recorder.onFix(p);
      }
      // In a "tunnel": the coasting engine walks along the PLANNED route 2 km west of the real road.
      for (var i = 0; i < 20; i++) {
        recorder.onFix(TrackPoint(ts: real[19].ts + 500 + i * 1000, lat: real[19].lat + i * 0.0002, lng: 78.38, speedKmh: 60, accuracyM: 20), estimated: true);
      }
      for (final p in real.skip(20)) {
        recorder.onFix(p);
      }
      final track = await recorder.trackOf('GRP-T');
      expect(track.length, real.length);
      expect(track.every((p) => p.lng == 78.4), isTrue);
      final summary = await recorder.summaryOf('GRP-T');
      expect(summary, isNotNull);
      expect(summary!.stats.distanceM, closeTo(pathLen(real), 5));
      await recorder.stop(upload: false);
    });

    test('a heartbeat while moving does not stamp an old position', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      recorder.start('GRP-H');
      recorder.onFix(const TrackPoint(ts: t0, lat: 17, lng: 78.4, speedKmh: 50, accuracyM: 5));
      recorder.onHeartbeat(nowMs: t0 + 60000);
      expect((await recorder.trackOf('GRP-H')).length, 1);
      await recorder.stop(upload: false);
    });
  });

  group('Drawing only what was ridden', () {
    test('a segmented server track is cut only at its marks (long straight simplified lines stay solid)', () {
      final track = ReplayTrack.fromJson({
        'userId': 'a',
        'points': [
          [t0, 17.000, 78.4, 90],
          [t0 + 4 * 60000, 17.060, 78.4, 90], // 6.7 km straight highway, simplified to two points
          [t0 + 5 * 60000, 17.075, 78.4, 90],
          [t0 + 20 * 60000, 17.200, 78.4, 60, 1], // after a dead zone
          [t0 + 21 * 60000, 17.210, 78.4, 60],
        ],
      }, segmented: true);
      final s = track.split();
      expect(s.pieces.length, 2);
      expect(s.pieces.first.length, 3);
      expect(s.gaps.length, 1);
      expect(track.positionAt(t0 + 10 * 60000, maxGap: const Duration(hours: 1)), isNull, reason: 'no position is invented across a gap');
    });

    test('trip trail pieces: marked gaps cut, an unmarked old trail is cut only at impossible jumps', () {
      TripBreadcrumbPoint p(double lat, int ts, {bool gap = false}) => TripBreadcrumbPoint(lat: lat, lng: 78.4, speedKmh: 60, heading: 0, timestamp: ts, gapBefore: gap);
      final marked = [p(17.0, t0), p(17.05, t0 + 300000), p(17.2, t0 + 1500000, gap: true), p(17.21, t0 + 1560000)];
      expect(TripBreadcrumbPoint.pieces(marked).map((x) => x.length).toList(), [2, 2]);
      final unmarked = [p(17.0, t0), p(17.08, t0 + 400000), p(17.5, t0 + 401000), p(17.09, t0 + 410000)];
      expect(TripBreadcrumbPoint.pieces(unmarked).length, 3, reason: 'the 45 km jump in one second is cut out');
      final json = TripBreadcrumbPoint.fromJson(marked[2].toJson());
      expect(json.gapBefore, isTrue);
      expect(marked[0].toJson().containsKey('gap'), isFalse);
    });

    test('the trip keeps the phone\'s own numbers through JSON', () {
      final s = TripStats.compute(ride(n: 30)).toJson();
      final trip = TripHistoryModel(tripId: 'TRIP-1-u', tripName: 'x', startTimeEpochMs: t0, endTimeEpochMs: t0 + 1, totalDistanceKm: 2.4, topSpeedKmh: 60, avgSpeedKmh: 60, clientStats: s);
      final back = TripHistoryModel.fromJson(trip.toJson());
      expect(back.clientStats?['distanceM'], s['distanceM']);
      expect(back.withTrail(const []).clientStats, isNotNull);
    });

    test('share sketch: pieces are joined with breaks, never drawn across a gap', () {
      final j = RideShareData.joinPieces([
        [const LatLng(17, 78.4), const LatLng(17.01, 78.4)],
        [const LatLng(0, 0)],
        [const LatLng(17.2, 78.4), const LatLng(17.21, 78.4)],
      ]);
      expect(j.points.length, 4);
      expect(j.breaks, {2});
      expect(RouteSketchPainter.keptIndices(1000).last, 999);
      expect(RouteSketchPainter.keptIndices(3), [0, 1, 2]);
    });
  });
}
