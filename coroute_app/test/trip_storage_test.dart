import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<TripBreadcrumbPoint> trail(int n) =>
      List.generate(n, (i) => TripBreadcrumbPoint(lat: 17 + i / 1000, lng: 78, speedKmh: 40, heading: 0, timestamp: i * 1000));

  TripHistoryModel trip(String id, {int points = 0, int? trailPoints}) => TripHistoryModel(
        tripId: id,
        tripName: 'Ride $id',
        startTimeEpochMs: 1000,
        endTimeEpochMs: 2000,
        totalDistanceKm: 12,
        topSpeedKmh: 80,
        avgSpeedKmh: 40,
        breadcrumbTrail: trail(points),
        trailPoints: trailPoints,
      );

  group('Trip model', () {
    test('the stored copy has no trail but remembers its size', () {
      final t = trip('T1', points: 30);
      expect(t.trailPoints, 30);
      final stored = t.toStorageJson();
      expect(stored['breadcrumbTrail'], isEmpty);
      expect(stored['trailPoints'], 30);
      final back = TripHistoryModel.fromJson(jsonDecode(jsonEncode(stored)) as Map<String, dynamic>);
      expect(back.breadcrumbTrail, isEmpty);
      expect(back.trailPoints, 30);
      expect(back.trailOnServerOnly, isTrue);
    });

    test('older JSON without trailPoints and a summary without a trail both load', () {
      final old = TripHistoryModel.fromJson({'tripId': 'T2', 'breadcrumbTrail': [trail(1).first.toJson(), trail(2).last.toJson()]});
      expect(old.trailPoints, 2);
      expect(old.trailOnServerOnly, isFalse);
      final summary = TripHistoryModel.fromJson({'tripId': 'T3', 'trailPoints': 4000});
      expect(summary.breadcrumbTrail, isEmpty);
      expect(summary.trailPoints, 4000);
      final none = TripHistoryModel.fromJson({'tripId': 'T4'});
      expect(none.trailPoints, 0);
      expect(none.trailOnServerOnly, isFalse);
    });

    test('a trail in memory survives a summary sync only when it is the same route', () {
      final local = trip('T5', points: 30);
      final same = TripStorageService.mergeServerTrip(trip('T5', trailPoints: 30), local);
      expect(same.breadcrumbTrail.length, 30);
      final changed = TripStorageService.mergeServerTrip(trip('T5', trailPoints: 120), local);
      expect(changed.breadcrumbTrail, isEmpty);
      expect(changed.trailPoints, 120);
      expect(TripStorageService.mergeServerTrip(trip('T6', trailPoints: 9), null).trailPoints, 9);
    });

    test('server refusals that will never succeed are not retried', () {
      expect(TripStorageService.isPermanentRefusal(409), isTrue);
      expect(TripStorageService.isPermanentRefusal(413), isTrue);
      expect(TripStorageService.isPermanentRefusal(401), isFalse);
      expect(TripStorageService.isPermanentRefusal(429), isFalse);
      expect(TripStorageService.isPermanentRefusal(503), isFalse);
      expect(TripStorageService.isPermanentRefusal(0), isFalse);
    });
  });

  group('TripStorageService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('sync asks for summaries, stores no trails, and loads one trail on demand (cached)', () async {
      final requests = <String>[];
      final client = MockClient((req) async {
        requests.add(req.url.toString());
        if (req.url.path.endsWith('/trips') && req.method == 'GET') {
          final summary = trip('S1', trailPoints: 30).toStorageJson();
          return http.Response(jsonEncode({'trips': [summary]}), 200);
        }
        if (req.url.path.endsWith('/trips/S1')) {
          return http.Response(jsonEncode({'trip': trip('S1', points: 30).toJson()}), 200);
        }
        return http.Response('{}', 200);
      });
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      await api.setToken('jwt');
      final svc = TripStorageService(api);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(requests.any((u) => u.contains('/trips?summary=1')), isTrue);
      expect(svc.trips.single.trailOnServerOnly, isTrue);
      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString(AppConstants.keyTripHistory)!) as List;
      expect((stored.single as Map)['breadcrumbTrail'], isEmpty);

      final revision = svc.revision;
      final full = await svc.loadFull('S1');
      expect(full.breadcrumbTrail.length, 30);
      final before = requests.length;
      final again = await svc.loadFull('S1');
      expect(again.breadcrumbTrail.length, 30);
      expect(requests.length, before, reason: 'the second open uses the in-memory copy');
      expect(svc.cachedFull('S1'), isNotNull);
      expect(svc.revision, revision, reason: 'loading a trail does not change the list');
    });

    test('offline, a trail that is not on the phone cannot be loaded', () async {
      final client = MockClient((req) async => throw Exception('no network'));
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      await api.setToken('jwt');
      final svc = TripStorageService(api);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(svc.loadFull('S9'), throwsA(isA<ApiException>().having((e) => e.isOffline, 'offline', isTrue)));
    });
  });
}
