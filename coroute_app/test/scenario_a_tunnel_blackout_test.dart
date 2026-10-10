import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/route/route_progress.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/presentation/ride/riders_ladder.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';

/// Test mock ConvoyService providing a static convoy snapshot with disconnected state.
class _TunnelConvoyService extends ConvoyService {
  _TunnelConvoyService(ApiClient api, this.convoy, {this.online = false, this.pendingPoints = 12})
      : super(api, RealtimeService(), TripStorageService(api));

  final ConvoyModel convoy;
  final bool online;
  final int pendingPoints;

  @override
  Map<String, ConvoyModel> get allConvoys => {convoy.groupId: convoy};
  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get activeGroupId => convoy.groupId;
  @override
  String? get myUserId => 'rider_lead';
  @override
  bool get isOnline => online;
  @override
  int get pendingTrackPoints => pendingPoints;
}

class _MockRt extends RealtimeService {
  _MockRt({this.mockState = RealtimeState.disconnected});
  final RealtimeState mockState;

  @override
  RealtimeState get state => mockState;
  @override
  bool get isConnected => mockState == RealtimeState.connected;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    AppTheme.use(AppPalette.dark);
  });

  group('Scenario A: Long Tunnel & Canyon Blackout', () {
    // A 10 km mountain route through a gorge with a 3 km tunnel in the middle.
    // Tunnel entrance: lat 13.040, lng 77.500
    // Tunnel exit:     lat 13.067, lng 77.500 (approx 3 km straight north)
    final points = <(double, double)>[
      for (double lat = 13.000; lat <= 13.100 + 1e-9; lat += 0.002) (lat, 77.500)
    ];
    final totalRouteM = GeoMath.alongRoute(13.100, 77.500, points)!.along;

    test('Route progress dead reckoning: holds anchor during blackout and recovers on tunnel exit', () {
      final progress = RouteProgress(points);
      expect(progress.isUsable, isTrue);

      // 1. Rider approaches tunnel entrance (lat 13.040, ~4.4 km into route)
      final matchBeforeTunnel = progress.update(13.040, 77.500);
      expect(matchBeforeTunnel, isNotNull);
      expect(matchBeforeTunnel!.onLine, isTrue);
      final alongAtEntry = matchBeforeTunnel.alongM;
      final remainingAtEntry = progress.remainingM!;
      expect(alongAtEntry, greaterThan(4000));
      expect(remainingAtEntry, closeTo(totalRouteM - alongAtEntry, 1.0));

      // 2. Blackout inside tunnel: no GPS fixes arrive for 3 minutes.
      // Progress anchor must hold last position, remainingM must not jump to 0 or NaN.
      expect(progress.matched, isNotNull);
      expect(progress.matched!.alongM, alongAtEntry);
      expect(progress.remainingM, remainingAtEntry);
      expect(progress.remainingLine().isNotEmpty, isTrue);

      // 3. Exiting tunnel: GPS re-acquires 2 km ahead at lat 13.058 (within matchAheadM = 3000m).
      final matchAtExit = progress.update(13.058, 77.500);
      expect(matchAtExit, isNotNull);
      expect(matchAtExit!.onLine, isTrue);
      expect(matchAtExit.alongM, greaterThan(alongAtEntry + 1800));
      expect(progress.remainingM, lessThan(remainingAtEntry));
      expect(progress.remainingM!, greaterThan(0));

      // 4. Ultra-long mountain tunnel / deep canyon (> 3.5 km jump, lat 13.095):
      // Beyond local matchAheadM (3000m), global re-acquisition fires and anchors properly.
      final matchLongTunnel = progress.update(13.095, 77.500);
      expect(matchLongTunnel, isNotNull);
      expect(matchLongTunnel!.onLine, isTrue);
      expect(progress.lastSearchWasGlobal, isTrue, reason: 'Gap > 3000m triggers global route re-acquisition');
      expect(matchLongTunnel.alongM, greaterThan(alongAtEntry + 5500));
    });

    test('Hairpin & canyon geometry: noisy GPS drift does not slide backwards on mountain passes', () {
      // Out-and-back hairpin route
      final hairpin = <(double, double)>[
        (13.000, 77.500),
        (13.010, 77.500),
        (13.010, 77.505),
        (13.000, 77.505), // parallel return pass 500m away
      ];
      final p = RouteProgress(hairpin);

      // Enter first leg
      final m1 = p.update(13.005, 77.500);
      expect(m1, isNotNull);
      expect(m1!.index, 0);

      // Weak GPS fix drifting towards second leg must NOT skip ahead prematurely
      final drift = p.update(13.006, 77.502, accuracyM: 50);
      expect(drift, isNotNull);
      expect(drift!.index, 0, reason: 'Earlier pass of the hairpin is preserved');
    });

    test('GpsState transitions: accurate -> updating after 15s blackout -> unavailable when disabled', () {
      const now = 1700000000000;

      // Fresh fix: Accurate
      final stateFresh = RideFacts.gpsState(
        active: true,
        lastFixMs: now - 3000,
        moving: true,
        nowMs: now,
      );
      expect(stateFresh, GpsState.accurate);
      expect(stateFresh.label, 'Accurate');

      // 10 seconds into tunnel: still within 15s grace window
      final state10s = RideFacts.gpsState(
        active: true,
        lastFixMs: now - 10000,
        moving: true,
        nowMs: now,
      );
      expect(state10s, GpsState.accurate);

      // 20 seconds into tunnel: exceeds 15s -> Updating
      final stateUpdating = RideFacts.gpsState(
        active: true,
        lastFixMs: now - 20000,
        moving: true,
        nowMs: now,
      );
      expect(stateUpdating, GpsState.updating);
      expect(stateUpdating.label, 'Updating');

      // Low accuracy GPS fix in canyon (e.g. accuracy 80m > threshold 50m)
      final stateLowAcc = RideFacts.gpsState(
        active: true,
        lastFixMs: now - 2000,
        accuracyM: 80,
        moving: true,
        nowMs: now,
      );
      expect(stateLowAcc, GpsState.lowAccuracy);
      expect(stateLowAcc.label, 'Low accuracy');

      // Sensor completely off / permission revoked: Unavailable
      final stateUnavailable = RideFacts.gpsState(
        active: false,
        lastFixMs: now - 3000,
        moving: true,
        nowMs: now,
      );
      expect(stateUnavailable, GpsState.unavailable);
      expect(stateUnavailable.label, 'Unavailable');
    });

    test('Stale snapshot caching: convoy ladder & eta calculate safely during cellular blackout', () {
      final now = DateTime(2026, 10, 10, 11, 30).millisecondsSinceEpoch;
      final tunnelEnterMs = now - 5 * 60000; // 5 minutes ago

      final convoy = ConvoyModel(
        groupId: 'TUNNEL-GRP',
        name: 'Ghats Canyon Run',
        joinCode: '778899',
        createdByUserId: 'rider_lead',
        createdByUserName: 'Vikram Lead',
        createdAtEpochMs: tunnelEnterMs - 3600000,
        destinationLat: 13.100,
        destinationLng: 77.500,
        route: RouteModel(
          distanceM: totalRouteM,
          durationS: 900,
          polyline: GeoMath.encodePolyline(points),
        ),
        riders: {
          'rider_lead': RiderModel(
            userId: 'rider_lead',
            name: 'Vikram Lead',
            lat: 13.060,
            lng: 77.500,
            speedKmh: 45,
            lastSeenEpochMs: tunnelEnterMs,
            presence: 'NO_SIGNAL',
            presenceAt: tunnelEnterMs + 60000,
          ),
          'rider_tail': RiderModel(
            userId: 'rider_tail',
            name: 'Ananya Tail',
            lat: 13.040,
            lng: 77.500,
            speedKmh: 40,
            lastSeenEpochMs: tunnelEnterMs,
            presence: 'NO_SIGNAL',
            presenceAt: tunnelEnterMs + 60000,
          ),
          'rider_no_pos': RiderModel(
            userId: 'rider_no_pos',
            name: 'Dev NoPos',
            lat: 0,
            lng: 0,
            lastSeenEpochMs: 0,
          ),
        },
      );

      // Snapshot calculation must succeed without throwing
      final snapshot = RideFacts.snapshot(convoy, 'rider_lead');
      expect(snapshot.remainingM, isNotNull);
      expect(snapshot.eta, isNotNull);
      expect(snapshot.ladder, hasLength(3));

      // Front to back ordering: Vikram Lead (at 13.060) then Ananya Tail (at 13.040), then rider with no pos
      expect(snapshot.ladder[0].rider.userId, 'rider_lead');
      expect(snapshot.ladder[0].isMe, isTrue);
      expect(snapshot.ladder[1].rider.userId, 'rider_tail');
      expect(snapshot.ladder[1].isMe, isFalse);
      expect(snapshot.ladder[1].ahead, isFalse, reason: 'Tail is behind lead');
      expect(snapshot.ladder[2].rider.userId, 'rider_no_pos');
      expect(snapshot.ladder[2].progressM, isNull);

      // Presence string shows blackout timestamp clearly
      final tailRider = convoy.riders['rider_tail']!;
      final presence = presenceLine(tailRider, isMe: false, clock: (ms) => '11:25 AM');
      expect(presence, 'No signal since 11:25 AM');
    });

    testWidgets('Offline UI states: ConnectionBanner and Ladder render stably in full blackout', (tester) async {
      final now = DateTime(2026, 10, 10, 11, 30).millisecondsSinceEpoch;
      final lastUpdate = now - 4 * 60000;

      // 1. Connection banner status text check
      final offlineStatus = ConnectionBanner.status(
        state: RealtimeState.disconnected,
        lastUpdateMs: lastUpdate,
        nowMs: now,
      );
      expect(offlineStatus, 'Offline, last updated 4 min ago');

      // 2. Widget rendering test under offline condition
      final convoy = ConvoyModel(
        groupId: 'GRP-BLACKOUT',
        name: 'Nilgiri Tunnel',
        joinCode: '445566',
        createdByUserId: 'rider_lead',
        createdByUserName: 'Vikram Lead',
        createdAtEpochMs: lastUpdate - 3600000,
        destinationLat: 13.100,
        destinationLng: 77.500,
        riders: {
          'rider_lead': RiderModel(
            userId: 'rider_lead',
            name: 'Vikram Lead',
            lat: 13.050,
            lng: 77.500,
            speedKmh: 50,
            lastSeenEpochMs: lastUpdate,
            presence: 'NO_SIGNAL',
          ),
          'rider_rohit': RiderModel(
            userId: 'rider_rohit',
            name: 'Rohit',
            lat: 13.045,
            lng: 77.500,
            speedKmh: 0,
            lastSeenEpochMs: lastUpdate,
            presence: 'NO_SIGNAL',
          ),
        },
      );

      final api = ApiClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        storage: const FlutterSecureStorage(),
      );
      final service = _TunnelConvoyService(api, convoy, online: false, pendingPoints: 12);
      final rt = _MockRt(mockState: RealtimeState.disconnected);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<RealtimeService>.value(value: rt),
            ChangeNotifierProvider<ConvoyService>.value(value: service),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: Column(
                children: [
                  const ConnectionBanner(),
                  Expanded(
                    child: RidersLadder(
                      rungs: RideFacts.ladder(convoy, 'rider_lead'),
                      colors: const {},
                      statuses: const {},
                      nowMs: now,
                      onTap: (_) {},
                      offlinePlaces: const {'rider_rohit': 'Tunnel Bay 3'},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Offline. Positions shown may be out of date.'), findsOneWidget);
      expect(find.text('12 points waiting to upload'), findsOneWidget);
      expect(find.text('Rohit'), findsOneWidget);
      expect(find.textContaining('Tunnel Bay 3'), findsOneWidget);
    });
  });
}
