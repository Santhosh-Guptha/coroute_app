import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/ride_essentials_coordinator.dart';
import 'package:coroute_app/data/services/route_essentials_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'route_essentials_test.dart' as fixture;

class Port extends ChangeNotifier implements RideEssentialsPort {
  @override
  ConvoyModel? activeConvoy;
  @override
  String? myUserId = 'me';
  @override
  bool isOnline = true;
  @override
  bool isRealGpsActive = true;
  @override
  bool conservingBattery = false;
  final fixes = StreamController<TrackPoint>.broadcast(sync: true);
  @override
  Stream<TrackPoint> get myFixes => fixes.stream;
  void changed() => notifyListeners();
}

ConvoyModel convoy({String id = 'g', double lat = 17}) => ConvoyModel(
    groupId: id, name: 'Ride', joinCode: 'JOIN', createdByUserId: 'me',
    createdByUserName: 'Me', createdAtEpochMs: fixture.t0,
    destinationLat: lat + 2, destinationLng: 78, route: fixture.route(lat: lat));

void main() {
  late Port port;
  late SettingsService settings;
  late RideEssentialsCoordinator coordinator;
  late int now, calls;
  late Future<http.Response> Function(http.Request) handler;
  void setup() {
    now = fixture.t0; calls = 0;
    port = Port()..activeConvoy = convoy();
    settings = SettingsService();
    handler = (_) async => http.Response(jsonEncode(fixture.response()), 200);
    final essentials = RouteEssentialsService(
      ApiClient(httpClient: MockClient((request) { calls++; return handler(request); })),
      load: () async => null, save: (_) async {}, clock: () => now);
    coordinator = RideEssentialsCoordinator(port, settings, essentials,
      fetchRoute: (_) async => null, clock: () => now);
    addTearDown(() async {
      coordinator.dispose();
      expect(port.fixes.hasListener, isFalse);
      await port.fixes.close();
      port.dispose(); settings.dispose();
    });
  }
  void fix({double lat = 17, double accuracy = 5, int? ts}) => port.fixes.add(
    TrackPoint(ts: ts ?? now, lat: lat, lng: 78, accuracyM: accuracy, speedKmh: 30));

  testWidgets('works without a map and shares discovery across fixes', (tester) async {
    setup(); expect(calls, 0);
    fix(); await tester.pump();
    expect(calls, 1); expect(coordinator.essentials.snapshot, isNotNull);
    final guide = coordinator.guide;
    for (var i = 1; i <= 10; i++) {
      now += 1000; fix(lat: 17 + i * .0001); await tester.pump();
    }
    expect(identical(guide, coordinator.guide), isTrue);
    expect(coordinator.essentials.progressM, greaterThan(0)); expect(calls, 1);
    coordinator.dispose();
  });
  testWidgets('offline start and reconnect perform one bounded refresh', (tester) async {
    setup(); port.isOnline = false; port.changed();
    fix(); await tester.pump(); expect(calls, 0);
    port.isOnline = true; port.changed(); await tester.pump(); expect(calls, 1);
    port.changed(); await tester.pump(); expect(calls, 1);
    port.isOnline = false; port.changed(); await tester.pump();
    expect(coordinator.essentials.snapshot, isNotNull);
    expect(coordinator.essentials.reliable, isFalse);
    coordinator.dispose();
  });
  testWidgets('stale GPS expires while stationary without network work', (tester) async {
    setup(); fix(); await tester.pump();
    now += RideEssentialsCoordinator.fixLifetime.inMilliseconds;
    await tester.pump(RideEssentialsCoordinator.fixLifetime);
    expect(coordinator.hasCurrentPosition, isFalse);
    expect(coordinator.essentials.snapshot, isNull); expect(calls, 1);
    fix(); await tester.pump();
    expect(coordinator.hasCurrentPosition, isTrue);
    expect(coordinator.essentials.snapshot, isNotNull); expect(calls, 1);
    coordinator.dispose();
  });
  testWidgets('old future inaccurate and duplicate fixes cannot move progress', (tester) async {
    setup(); fix(accuracy: 150); fix(ts: now + 1); fix(ts: now - 120000);
    await tester.pump(); expect(calls, 0);
    fix(); await tester.pump(); final progress = coordinator.essentials.progressM;
    fix(lat: 18); fix(lat: 18, ts: now - 1); await tester.pump();
    expect(coordinator.essentials.progressM, progress); expect(calls, 1);
    coordinator.dispose();
  });
  testWidgets('account switch resets matching and rejects pending results', (tester) async {
    setup(); final pending = Completer<http.Response>(); handler = (_) => pending.future;
    fix(); await tester.pump(); final oldGuide = coordinator.guide;
    port.myUserId = 'other'; port.changed(); await tester.pump();
    expect(identical(coordinator.guide, oldGuide), isFalse);
    expect(coordinator.hasCurrentPosition, isFalse);
    pending.complete(http.Response(jsonEncode(fixture.response()), 200));
    await tester.pump(); expect(coordinator.essentials.snapshot, isNull);
    coordinator.dispose();
  });
  testWidgets('route change rejects the old response', (tester) async {
    setup(); final pending = Completer<http.Response>(); handler = (_) => pending.future;
    fix(); await tester.pump();
    port.activeConvoy = convoy(lat: 20); port.changed(); await tester.pump();
    pending.complete(http.Response(jsonEncode(fixture.response()), 200));
    await tester.pump(); expect(coordinator.essentials.snapshot, isNull); expect(calls, 1);
    coordinator.dispose();
  });
  testWidgets('conservation suppresses optional work but allows explicit refresh', (tester) async {
    setup(); port.conservingBattery = true; port.changed();
    fix(); await tester.pump(); expect(calls, 0);
    await coordinator.refresh(force: true); expect(calls, 1);
    coordinator.dispose();
  });
  testWidgets('ride end and revoked GPS invalidate guidance without fetching', (tester) async {
    setup(); fix(); await tester.pump();
    port.isRealGpsActive = false; port.changed(); await tester.pump();
    expect(coordinator.essentials.snapshot, isNull);
    port.activeConvoy = port.activeConvoy!.copyWith(tripStatus: 'ENDED');
    port.changed(); await tester.pump(); expect(coordinator.groupId, isNull);
    now += 1000; fix(); await tester.pump(); expect(calls, 1);
    coordinator.dispose();
  });
}
