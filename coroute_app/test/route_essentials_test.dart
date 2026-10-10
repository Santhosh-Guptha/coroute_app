import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/route_essentials_service.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/models/route_essential.dart';
import 'package:coroute_app/domain/safety/fuel_profile.dart';
import 'package:coroute_app/domain/safety/fuel_range.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';

const t0 = 1700000000000;
Map<String, dynamic> place({double at = 10000}) => {'placeId': 'osm:node:1', 'visitId': '1:$at', 'name': 'Mapped pump', 'category': 'FUEL', 'source': 'OpenStreetMap',
  'lat': 17.1, 'lng': 78.0, 'routePositionM': at, 'entryM': at - 1000, 'exitM': at + 1000, 'accessDistanceM': 1200,
  'detourDistanceM': 400, 'detourDurationS': 120};
Map<String, dynamic> response({int time = t0, String category = 'FUEL', bool complete = true, bool stale = false}) => {
  'version': 1, 'routeKey': 'route-a', 'category': category, 'fromM': 0, 'toM': 150000, 'fetchedAt': time,
  'complete': complete, 'stale': stale, 'places': [place()], 'attribution': 'OpenStreetMap'};
RouteModel route({double lat = 17, bool approximate = false}) => RouteModel(distanceM: 200000, durationS: 10000,
  polyline: GeoMath.encodePolyline([(lat, 78), (lat + 2, 78)]), approximate: approximate);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('personal fuel calculation', () {
    const profile = FuelProfile(capacityL: 15, mileageKmL: 30, reserveL: 2, bufferKm: 20);
    test('unknown baseline is unknown; reserve and buffer deducted once', () {
      final f = FuelRangeTracker(); expect(f.usableKm(profile), isNull);
      expect(f.refuel(profile, t0, currentL: 10), isTrue);
      expect(f.usableKm(profile), 220);
      final saved = f.toJson()..['m'] = 170000;
      expect(FuelRangeTracker.fromJson(saved)!.usableKm(profile), 50);
    });
    test('partial fills add to remaining fuel, full fill resets and capacity caps', () {
      final f = FuelRangeTracker(); expect(f.refuel(profile, t0, addedL: 8), isFalse);
      f.refuel(profile, t0, currentL: 5);
      expect(f.refuel(profile, t0 + 1, addedL: 3), isTrue); expect(f.usableKm(profile), 160);
      f.refuel(profile, t0 + 2, addedL: 15); expect(f.usableKm(profile), 370);
      f.refuel(profile, t0 + 3, full: true); expect(f.usableKm(profile), 370);
    });
    test('invalid amounts do not mutate state; config changes invalidate old baseline', () {
      final f = FuelRangeTracker()..refuel(profile, t0, full: true);
      for (final amount in [-1.0, double.nan, double.infinity, 16.0]) {
        expect(f.refuel(profile, t0, currentL: amount), isFalse); expect(f.usableKm(profile), 370);
      }
      expect(f.usableKm(const FuelProfile(capacityL: 15, mileageKmL: 25)), isNull);
    });
    test('simple range mode supports a current estimate and reserve', () {
      const p = FuelProfile(fullRangeKm: 300, reserveKm: 50, bufferKm: 20);
      final f = FuelRangeTracker()..refuel(p, t0, currentKm: 100);
      expect(f.usableKm(p), 30); expect(f.refuel(p, t0, addedL: 5), isFalse);
    });
    test('bad profiles and corrupted state are rejected', () {
      expect(const FuelProfile(capacityL: 15, mileageKmL: 30, reserveL: 15).valid, isFalse);
      expect(const FuelProfile(fullRangeKm: double.nan).valid, isFalse);
      expect(const FuelProfile(fullRangeKm: 10).valid, isFalse);
      expect(FuelRangeTracker.fromJson({'m': double.nan}), isNull);
    });
    test('tracking gaps invalidate confidence, partial fill cannot erase uncertainty', () {
      final f = FuelRangeTracker()..refuel(profile, t0, full: true);
      f.onFix(const TrackPoint(ts: t0, lat: 17, lng: 78));
      f.onFix(const TrackPoint(ts: t0 + 400000, lat: 17.01, lng: 78));
      expect(f.uncertain, isTrue); expect(f.refuel(profile, t0 + 400001, addedL: 1), isFalse);
      final restored = FuelRangeTracker.fromJson(f.toJson())!; expect(restored.uncertain, isTrue);
      restored.refuel(profile, t0 + 400002, full: true); expect(restored.uncertain, isFalse);
    });
    test('duplicate or out-of-order fixes cannot rewind the distance anchor', () {
      final f = FuelRangeTracker();
      f.onFix(const TrackPoint(ts: t0, lat: 17, lng: 78));
      f.onFix(const TrackPoint(ts: t0 + 10000, lat: 17.001, lng: 78));
      final distance = f.riddenM;
      f.onFix(const TrackPoint(ts: t0 + 5000, lat: 17.1, lng: 78));
      f.onFix(const TrackPoint(ts: t0 + 10000, lat: 17.1, lng: 78));
      expect(f.riddenM, distance);
      f.onFix(const TrackPoint(ts: t0 + 20000, lat: 17.002, lng: 78));
      expect(f.riddenM, closeTo(distance * 2, 1));
    });
    test('four levels, unknown coverage, boundaries and from-rider distances', () {
      expect(fuelAdvice(usableKm: 26, nextKm: 34, reliable: true), FuelAdvice.rangeRisk);
      expect(fuelAdvice(usableKm: 58, nextKm: 19, followingKm: 74, reliable: true), FuelAdvice.recommended);
      expect(fuelAdvice(usableKm: 68, nextKm: 22, followingKm: 61, reliable: true), FuelAdvice.consider);
      expect(fuelAdvice(usableKm: 200, nextKm: 22, followingKm: 61, reliable: true), FuelAdvice.withinEstimate);
      expect(fuelAdvice(usableKm: 200, nextKm: 22, followingKm: 61, reliable: false), FuelAdvice.unknown);
      expect(fuelAdvice(usableKm: null, nextKm: 22, reliable: true), FuelAdvice.unknown);
      expect(fuelAdvice(usableKm: 22, nextKm: 22, reliable: true), FuelAdvice.consider);
    });
  });
  group('route snapshots and network lifecycle', () {
    late int now, calls;
    String? disk;
    late Future<http.Response> Function(http.Request) handler;
    late RouteEssentialsService service;
    setUp(() {
      now = t0; calls = 0; disk = null;
      FlutterSecureStorage.setMockInitialValues({});
      handler = (_) async => http.Response(jsonEncode(response()), 200);
      service = RouteEssentialsService(ApiClient(httpClient: MockClient((r) { calls++; return handler(r); })),
        load: () async => disk, save: (v) async { disk = v; }, clock: () => now);
    });
    tearDown(() => service.dispose());
    Future<void> update({bool online = true, bool force = false, bool lowData = false}) => service.update(route(), fromM: 0, online: online, force: force, lowData: lowData);
    test('GPS updates use cache; offline and data saver make no calls', () async {
      await update(online: false); await update(lowData: true); expect(calls, 0);
      await update(); expect(calls, 1); expect(service.reliable, true);
      for (var i = 0; i < 20; i++) { await service.update(route(), fromM: i * 10, online: true); }
      expect(calls, 1); await update(online: false); expect(service.snapshot, isNotNull); expect(service.reliable, false);
    });
    test('outage retains timestamp and options with bounded retry', () async {
      await update(); now += 1800001;
      handler = (_) async => http.Response('down', 503);
      await update(); expect(service.error, isNotNull); expect(service.snapshot!.fetchedAt, t0); expect(service.upcoming.length, 1);
      await update(); expect(calls, 2);
      handler = (_) async => http.Response(jsonEncode(response(time: now)), 200);
      await update(force: true); expect(service.error, isNull); expect(service.reliable, true);
    });
    test('restart offline restores route-specific cache', () async {
      await update(); final saved = disk;
      final restored = RouteEssentialsService(ApiClient(), load: () async => saved, save: (_) async {}, clock: () => now);
      await restored.update(route(), fromM: 0, online: false); expect(restored.upcoming.length, 1);
      await restored.update(route(lat: 18), fromM: 0, online: false); expect(restored.snapshot, isNull);
      restored.dispose();
    });
    test('offline forward progression retains overlapping route cache snapshot', () async {
      await update();
      await service.update(route(), fromM: 6000, online: false);
      expect(service.snapshot, isNotNull);
      expect(service.offline, true);
      expect(service.upcoming.length, 1);
    });
    test('late old route response cannot overwrite rerouted results', () async {
      final pending = Completer<http.Response>(); handler = (_) => pending.future;
      final first = update(); await Future<void>.delayed(Duration.zero);
      await service.update(route(lat: 18), fromM: 0, online: false);
      pending.complete(http.Response(jsonEncode(response()), 200)); await first;
      expect(service.snapshot, isNull); expect(service.loading, false);
    });
    test('concurrent updates deduplicate requests', () async {
      final pending = Completer<http.Response>(); handler = (_) => pending.future;
      final a = update(); await Future<void>.delayed(Duration.zero); final b = update();
      pending.complete(http.Response(jsonEncode(response()), 200)); await Future.wait([a, b]); expect(calls, 1);
    });
    test('approximate route clears old results without network', () async {
      await update(); await service.update(route(approximate: true), fromM: 0, online: true);
      expect(service.snapshot, isNull); expect(calls, 1);
    });
    test('HTML captive portal, unauthorised, rate limit, invalid JSON retain cache', () async {
      await update();
      for (final status in [200, 401, 403, 429, 502, 503]) {
        await service.api.setToken('session-$status');
        handler = (_) async => http.Response('<html>Login</html>', status);
        await update(force: true); expect(service.error, isNotNull); expect(service.snapshot!.fetchedAt, t0);
      }
    });
    test('empty success differs from provider failure; malformed places mark partial', () async {
      handler = (_) async => http.Response(jsonEncode(response()..['places'] = []), 200);
      await update(); expect(service.error, isNull); expect(service.upcoming, isEmpty);
      final parsed = EssentialsSnapshot.fromJson(response()..['places'] = [{'name': 'invalid'}]);
      expect(parsed!.complete, false);
    });
    test('stale provider fallback does not trigger a request storm', () async {
      handler = (_) async => http.Response(jsonEncode(response(stale: true)), 200);
      await update(); await update(); expect(calls, 1); expect(service.reliable, false);
    });
    test('corrupt cache and failed disk writes leave live results usable', () async {
      disk = '{broken'; await update(); expect(service.upcoming.length, 1);
      final s = RouteEssentialsService(ApiClient(httpClient: MockClient(handler)), load: () async => null, save: (_) async => throw StateError('disk full'), clock: () => now);
      await s.update(route(), fromM: 0, online: true); expect(s.cacheSaveFailed, true); expect(s.snapshot, isNotNull); s.dispose();
    });
    for (final status in [401, 403]) {
      test('$status blocks forced retries until credentials change', () async {
        await service.api.setToken('first');
        handler = (_) async => http.Response('{}', status);
        await update();
        expect(calls, 1);
        await update(force: true);
        now += 3600000;
        await update(force: true);
        expect(calls, 1);
        await service.api.setToken('replacement');
        handler = (_) async => http.Response(jsonEncode(response(time: now)), 200);
        await update(force: true);
        expect(calls, 2);
        expect(service.reliable, true);
      });
    }
    test('expired and future disk snapshots are not shown offline', () async {
      for (final time in [t0 - 7 * 86400000, t0 + 1]) {
        final key = '${route().polyline}|FUEL|0';
        final restored = RouteEssentialsService(ApiClient(),
          load: () async => jsonEncode({key: response(time: time)}),
          save: (_) async {}, clock: () => t0);
        await restored.update(route(), fromM: 0, online: false);
        expect(restored.snapshot, isNull);
        restored.dispose();
      }
    });
    test('timeout preserves last success and recovery clears failure', () async {
      await update();
      handler = (_) async => throw TimeoutException('network stalled');
      await update(force: true);
      expect(service.snapshot!.fetchedAt, t0);
      expect(service.reliable, false);
      expect(service.loading, false);
      handler = (_) async => http.Response(jsonEncode(response()), 200);
      await update(force: true);
      expect(service.error, isNull);
      expect(service.reliable, true);
    });
    test('default disk writes from separate services retain both routes', () async {
      SharedPreferences.setMockInitialValues({});
      final a = RouteEssentialsService(ApiClient(httpClient: MockClient(handler)), clock: () => now);
      final b = RouteEssentialsService(ApiClient(httpClient: MockClient(handler)), clock: () => now);
      try {
        await Future.wait([
          a.update(route(), fromM: 0, online: true),
          b.update(route(lat: 18), fromM: 0, online: true),
        ]);
        final prefs = await SharedPreferences.getInstance();
        final saved = jsonDecode(prefs.getString('essentials_cache_v1')!) as Map;
        expect(saved.length, 2);
        expect(saved.keys, contains('${route().polyline}|FUEL|0'));
        expect(saved.keys, contains('${route(lat: 18).polyline}|FUEL|0'));
      } finally { a.dispose(); b.dispose(); }
    });
    test('disk failure is recoverable without discarding live data', () async {
      var fail = true;
      final s = RouteEssentialsService(ApiClient(httpClient: MockClient(handler)),
        load: () async => null, save: (_) async { if (fail) throw StateError('disk full'); }, clock: () => now);
      await s.update(route(), fromM: 0, online: true);
      expect(s.cacheSaveFailed, true); expect(s.reliable, true);
      fail = false;
      await s.update(route(), fromM: 0, online: true, force: true);
      expect(s.cacheSaveFailed, false); expect(s.reliable, true); s.dispose();
    });
    test('default cache keeps newest eighteen entries across independent services', () async {
      SharedPreferences.setMockInitialValues({});
      for (var i = 0; i < 20; i++) {
        now = t0 + i;
        final s = RouteEssentialsService(ApiClient(httpClient: MockClient((_) async =>
          http.Response(jsonEncode(response(time: now)), 200))), clock: () => now);
        await s.update(route(lat: 10 + i / 10), fromM: 0, online: true); s.dispose();
      }
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('essentials_cache_v1')!) as Map;
      expect(saved.length, 18);
      expect(saved.containsKey('${route(lat: 10).polyline}|FUEL|0'), false);
      expect(saved.containsKey('${route(lat: 11.9).polyline}|FUEL|0'), true);
    });
    test('road access distance becomes unknown after passing its entry anchor', () {
      final p = RouteEssential.fromJson(place())!;
      expect(p.roadDistanceM(0), 10200); expect(p.roadDistanceM(9500), isNull);
    });
  });
}
