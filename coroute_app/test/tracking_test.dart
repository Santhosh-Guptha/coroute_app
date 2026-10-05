import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:coroute_app/data/local/track_queue.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/timeline_service.dart';
import 'package:coroute_app/data/services/track_recorder.dart';
import 'package:coroute_app/data/services/track_uploader.dart';
import 'package:coroute_app/domain/notify/status_text.dart';
import 'package:coroute_app/domain/timeline/timeline_text.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/domain/tracking/stop_detector.dart';
import 'package:coroute_app/domain/tracking/track_chunker.dart';
import 'package:coroute_app/domain/tracking/track_filter.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

const int t0 = 1800000000000;

/// Synthetic ride heading north: segments of (minutes, km/h) sampled every [stepS] seconds.
List<TrackPoint> synth(List<(double, double)> plan, {int stepS = 5, double jitterM = 4}) {
  final pts = <TrackPoint>[];
  var km = 0.0;
  var t = t0;
  var seed = 7;
  double rnd() {
    seed = (seed * 16807) % 2147483647;
    return seed / 2147483647 - 0.5;
  }

  for (final (minutes, kmh) in plan) {
    final steps = (minutes * 60 / stepS).round();
    for (var i = 0; i < steps; i++) {
      t += stepS * 1000;
      km += kmh * stepS / 3600;
      final jit = kmh == 0 ? jitterM : 0.0;
      pts.add(TrackPoint(ts: t, lat: 17 + km / 111.195 + rnd() * jit / 111195, lng: 78.4 + rnd() * jit / 106000, speedKmh: kmh, accuracyM: 6));
    }
  }
  return pts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GeoMath (same reference values as the gateway)', () {
    test('one degree of latitude', () {
      expect((GeoMath.haversine(17, 78, 18, 78) - 111195).abs(), lessThan(5));
    });
    test('Google polyline reference round trip', () {
      const enc = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';
      final pts = GeoMath.decodePolyline(enc)!;
      expect(pts, [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]);
      expect(GeoMath.encodePolyline(pts), enc);
      expect(GeoMath.decodePolyline('@@@'), isNull);
    });
  });

  group('TrackFilter', () {
    test('drops bad accuracy, time going back, teleports and parked drift', () {
      final f = TrackFilter();
      expect(f.accept(const TrackPoint(ts: t0, lat: 17, lng: 78, accuracyM: 80)), isFalse);
      expect(f.accept(const TrackPoint(ts: t0, lat: 17, lng: 78, accuracyM: 5)), isTrue);
      expect(f.accept(const TrackPoint(ts: t0 - 1000, lat: 17.001, lng: 78, accuracyM: 5)), isFalse);
      expect(f.accept(const TrackPoint(ts: t0 + 2000, lat: 17.1, lng: 78, accuracyM: 5)), isFalse); // 11 km in 2 s
      expect(f.accept(const TrackPoint(ts: t0 + 5000, lat: 17.00001, lng: 78, accuracyM: 5)), isFalse); // 1 m drift
      expect(f.accept(const TrackPoint(ts: t0 + 30000, lat: 17.00001, lng: 78, accuracyM: 5)), isTrue); // parked heartbeat kept
      expect(f.accept(const TrackPoint(ts: t0 + 35000, lat: 17.0008, lng: 78, speedKmh: 50, accuracyM: 5)), isTrue);
      expect(f.accept(const TrackPoint(ts: t0 + 40000, lat: 0, lng: 0, accuracyM: 5)), isFalse);
    });
  });

  group('StopDetector', () {
    test('a real stop is found once; slow traffic and a short halt are not stops', () {
      final pts = synth([(10, 60), (18, 0), (10, 60), (5, 5), (1.5, 0), (10, 60)]);
      final d = StopDetector(minStop: const Duration(minutes: 2));
      final events = pts.map(d.add).whereType<StopEvent>().toList();
      expect(events.length, 2);
      expect(events.first.started, isTrue);
      expect(events.last.started, isFalse);
      final ms = events.last.stop.endTs! - events.last.stop.startTs;
      expect((ms - 18 * 60000).abs(), lessThanOrEqualTo(10000));
    });
    test('the stop in progress is visible while parked', () {
      final pts = synth([(2, 40), (5, 0)]);
      final d = StopDetector(minStop: const Duration(minutes: 2));
      pts.forEach(d.add);
      expect(d.current, isNotNull);
      expect(d.current!.isOpen, isTrue);
      expect(d.current!.durationAt(pts.last.ts).inMinutes, greaterThanOrEqualTo(4));
    });
  });

  group('TrackChunker', () {
    test('splits at 120 points, gap-free offsets, stable seq', () {
      final pts = synth([(30, 40)]); // 360 points
      final queued = [for (var i = 0; i < pts.length; i++) QueuedPoint(i + 1, 'G', pts[i])];
      final chunks = TrackChunker.build(queued);
      expect(chunks.length, 3);
      expect(chunks.first.ids.length, 120);
      expect(chunks.first.seq, 1 * 1000 + 120);
      expect(chunks[1].seq, 121 * 1000 + 120);
      expect(chunks.first.t.first, 0);
      expect(chunks.first.t.last, 119 * 5000);
      expect(GeoMath.decodePolyline(chunks.first.enc)!.length, 120);
      expect(TrackChunker.build(queued).map((c) => c.seq), chunks.map((c) => c.seq)); // same input, same seq
      final json = chunks.first.toJson();
      expect(json.keys, containsAll(['seq', 'startTs', 'enc', 't', 'v', 'acc']));
      expect(json['v'], everyElement(40));
    });
  });

  group('TrackUploader', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    Future<ApiClient> api(MockClient c) async {
      final a = ApiClient(httpClient: c, storage: const FlutterSecureStorage());
      await a.setToken('t');
      return a;
    }

    test('uploads in chunks and marks only acknowledged points', () async {
      final queue = MemoryTrackQueue();
      for (final p in synth([(25, 40)])) {
        await queue.add('GRP-1', p);
      }
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        expect(req.url.path, endsWith('/convoys/GRP-1/tracks'));
        final chunks = (jsonDecode(req.body)['chunks'] as List).cast<Map>();
        // Acknowledge all but the last chunk (as if it failed validation it would be in "rejected").
        final acked = chunks.take(chunks.length - 1).map((c) => c['seq']).toList();
        return http.Response(jsonEncode({'acked': acked, 'rejected': []}), 200);
      });
      final up = TrackUploader(await api(client), queue);
      final n = await up.flush();
      expect(n, 240);
      expect(queue.pendingCount('GRP-1'), 60);
      expect(calls, 1);
    });

    test('keeps points when offline, drops a group the server closed', () async {
      final queue = MemoryTrackQueue();
      for (final p in synth([(5, 40)])) {
        await queue.add('GRP-A', p);
      }
      for (final p in synth([(5, 40)])) {
        await queue.add('GRP-B', p);
      }
      final client = MockClient((req) async {
        if (req.url.path.contains('GRP-A')) return http.Response(jsonEncode({'error': 'busy'}), 503);
        return http.Response(jsonEncode({'error': 'This trip is closed for uploads.'}), 410);
      });
      final up = TrackUploader(await api(client), queue);
      expect(await up.flush(onlyGroup: 'GRP-B'), 0);
      expect(queue.pendingCount('GRP-B'), 0); // dropped
      expect(await up.flush(onlyGroup: 'GRP-A'), 0);
      expect(queue.pendingCount('GRP-A'), 60); // still waiting
    });
  });

  group('TrackRecorder', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('records fixes, detects the stop locally and keeps the parked time with heartbeats', () async {
      final queue = MemoryTrackQueue();
      final client = MockClient((req) async => http.Response(jsonEncode({'acked': [], 'rejected': []}), 200));
      final apiClient = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      final rec = TrackRecorder(queue, TrackUploader(apiClient, queue), uploadEvery: const Duration(hours: 1), uploadAfterPoints: 100000);
      rec.start('GRP-1', minStop: const Duration(minutes: 2));
      final moving = synth([(3, 50)]);
      moving.forEach(rec.onFix);
      expect(rec.currentStop, isNull);
      // Parked: GPS goes quiet, heartbeats every 30 s carry the parked time.
      var t = moving.last.ts;
      for (var i = 0; i < 8; i++) {
        t += 30000;
        rec.onHeartbeat(nowMs: t);
      }
      expect(rec.currentStop, isNotNull);
      expect(rec.recordedPoints, moving.length + 8);
      await queue.flushBuffer();
      expect(queue.pendingCount('GRP-1'), moving.length + 8);
      await rec.stop(upload: false);
      expect(rec.isRecording, isFalse);
      rec.onFix(TrackPoint(ts: t + 60000, lat: 17.5, lng: 78.4, accuracyM: 5));
      expect(queue.pendingCount('GRP-1'), moving.length + 8); // nothing recorded after stop
    });
  });

  group('Timeline', () {
    TimelineEventModel ev(Map<String, dynamic> j) => TimelineEventModel.fromJson({'eventId': 'E', 'groupId': 'G', 'startedAt': t0, ...j});

    test('plain-language wording', () {
      expect(TimelineText.duration(const Duration(seconds: 45)), '45 s');
      expect(TimelineText.duration(const Duration(minutes: 18)), '18 min');
      expect(TimelineText.duration(const Duration(minutes: 82)), '1 h 22 min');
      expect(TimelineText.distance(640), '640 m');
      expect(TimelineText.distance(2400), '2.4 km');
      expect(TimelineText.distance(84000), '84 km');

      final stop = ev({'type': 'STOPPED', 'userId': 'u', 'userName': 'Priya', 'durationMs': 18 * 60000, 'placeName': 'HP fuel station, Shamshabad', 'data': {'reason': 'FUELING'}});
      expect(TimelineText.title(stop, nowMs: t0), 'Priya stopped for 18 min');
      expect(TimelineText.detail(stop, nowMs: t0), 'HP fuel station, Shamshabad · fuelling');

      final openStop = ev({'type': 'STOPPED', 'userId': 'u', 'userName': 'Priya', 'open': true});
      expect(TimelineText.title(openStop, nowMs: t0 + 12 * 60000), 'Priya is stopped, 12 min so far');

      final sep = ev({'type': 'SEPARATED', 'userId': 'u', 'userName': 'Bala', 'durationMs': 14 * 60000, 'data': {'maxDistanceM': 2400}});
      expect(TimelineText.title(sep, nowMs: t0), 'Bala fell behind 2.4 km');
      expect(TimelineText.detail(sep, nowMs: t0), 'regrouped after 14 min');

      final sos = ev({'type': 'SOS', 'userId': 'u', 'userName': 'Chitra', 'durationMs': 20000, 'data': {'alertType': 'MECHANICAL', 'resolvedByName': 'Asha'}});
      expect(TimelineText.title(sos, nowMs: t0), 'Chitra raised an SOS (mechanical issue)');
      expect(TimelineText.detail(sos, nowMs: t0), 'resolved by Asha after 20 s');

      final moving = ev({'type': 'MOVING', 'userId': 'u', 'userName': 'Asha', 'durationMs': 82 * 60000, 'data': {'distanceM': 84000, 'avgKmh': 61.4, 'maxKmh': 96}});
      expect(TimelineText.title(moving, nowMs: t0), 'Asha rode 84 km in 1 h 22 min');
      expect(TimelineText.detail(moving, nowMs: t0), 'avg 61 km/h · top 96 km/h');
      expect(TimelineText.title(ev({'type': 'TRIP_ENDED'}), nowMs: t0), 'Trip ended');
    });

    test('service: loads, applies pushes for its own convoy only, confirmed stop replaces live', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final client = MockClient((req) async => http.Response(jsonEncode({
            'events': [
              {'eventId': 'E1', 'groupId': 'G1', 'type': 'JOINED', 'userId': 'b', 'userName': 'Bala', 'startedAt': t0, 'updatedAt': 1},
              {'eventId': 'E2', 'groupId': 'G1', 'type': 'STOPPED', 'userId': 'b', 'userName': 'Bala', 'startedAt': t0 + 600000, 'endedAt': t0 + 960000, 'durationMs': 360000, 'confidence': 'live', 'updatedAt': 2},
            ]
          }), 200));
      final apiClient = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      await apiClient.setToken('t');
      final rt = RealtimeService();
      final svc = TimelineService(apiClient, rt);
      await svc.attach('G1');
      expect(svc.events.map((e) => e.eventId), ['E1', 'E2']);
      expect(svc.filtered(types: {'STOPPED'}).length, 1);
      expect(svc.filtered(userIds: {'nobody'}), isEmpty);
      svc.dispose();
      rt.dispose();
    });
  });

  group('Live status notification text', () {
    test('collapsed line: nearest three, then +N; expanded: one line per rider', () {
      final others = [
        const StatusMember(name: 'Priya Sharma', distanceM: 1320, ahead: false, speedKmh: 54),
        const StatusMember(name: 'Alex', distanceM: 790, ahead: true, speedKmh: 61),
        const StatusMember(name: 'Ravi', distanceM: 5200, sinceUpdate: Duration(minutes: 3)),
        const StatusMember(name: 'Meenakshisundaram', distanceM: 2100, ahead: false, stoppedFor: Duration(minutes: 12)),
        const StatusMember(name: 'Zoya', distanceM: 15400, ahead: false, speedKmh: 40),
      ];
      final s = StatusText.build(convoyName: 'Hyd to Kurnool', others: others, destinationRemainingM: 64300, nextStopName: 'Lunch', nextStopRemainingM: 12100);
      expect(s.title, 'Hyd to Kurnool · 6 riders');
      final lines = s.text.split('\n');
      expect(lines.first, 'Alex 800 m ahead · Priya 1.3 km behind · Meenakshi. stopped 12m · +2');
      expect(lines.length, 1 + 5 + 1);
      expect(lines[1], 'Alex: 800 m ahead · 61 km/h · now');
      expect(lines[3], 'Meenakshi.: 2.1 km behind · stopped 12 min · now');
      expect(lines[4], 'Ravi: 5.2 km · no signal · 3 min ago');
      expect(lines.last, 'Next: Lunch 12 km · Destination 64 km');
    });

    test('same positions give the same text (no redraw), alone shows a hint', () {
      final a = StatusText.build(convoyName: 'C', others: [const StatusMember(name: 'A', distanceM: 1010)]);
      final b = StatusText.build(convoyName: 'C', others: [const StatusMember(name: 'A', distanceM: 1040)]);
      expect(a.text, b.text);
      expect(StatusText.build(convoyName: 'C', others: const []).text, contains('Share the join code'));
    });

    test('ahead or behind along the route', () {
      final route = [(17.0, 78.4), (17.5, 78.4)];
      final me = GeoMath.alongRoute(17.1, 78.4, route)!;
      final other = GeoMath.alongRoute(17.2, 78.401, route)!;
      expect(other.along, greaterThan(me.along));
      expect((other.along - me.along - 11120).abs(), lessThan(60));
      expect(other.offRoute, closeTo(106, 3));
      expect(GeoMath.alongRoute(17, 78, [(17.0, 78.0)]), isNull);
    });
  });
}
