import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/location_cadence.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:coroute_app/domain/mesh/mesh_transport.dart';
import 'package:coroute_app/domain/tracking/battery_governor.dart';
import 'package:coroute_app/domain/tracking/battery_performance_monitor.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';
import 'package:coroute_app/data/services/p2p_mesh_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';

class _FakeMeshTransport implements MeshTransport {
  bool _running = false;
  final StreamController<MeshIncomingPacket> _stream = StreamController<MeshIncomingPacket>.broadcast();

  @override
  Stream<MeshIncomingPacket> get incoming => _stream.stream;

  @override
  bool get isRunning => _running;

  @override
  void send(Uint8List data) {}

  @override
  Future<void> start({required String joinCode, int port = 42424}) async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }
}

class _DummyRealtimeService extends RealtimeService {
  @override
  bool get isConnected => true;
  @override
  RealtimeState get state => RealtimeState.connected;
  @override
  bool send(Map<String, dynamic> message) => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ISSUE-6H: Low Battery (< 20%) Detection & Policy Enforcement', () {
    test('BatteryGovernor detects low battery strictly below 20% when discharging', () {
      final governor = BatteryGovernor();
      bool? notifiedLow;
      governor.onLowBatteryChanged = (isLow) => notifiedLow = isLow;

      // At 21%: normal, nonessential tasks allowed
      governor.updateBattery(21, charging: false);
      expect(governor.isLowBattery, isFalse);
      expect(governor.isNonessentialTaskAllowed, isTrue);

      // Drops to 19%: triggers low battery mode
      governor.updateBattery(19, charging: false);
      expect(governor.isLowBattery, isTrue);
      expect(governor.isNonessentialTaskAllowed, isFalse);
      expect(notifiedLow, isTrue);

      // While charging at 15%: not considered low battery (charger attached)
      governor.updateBattery(15, charging: true);
      expect(governor.isLowBattery, isFalse);
      expect(governor.isNonessentialTaskAllowed, isTrue);
      expect(notifiedLow, isFalse);
    });

    test('TilePrefetcher pauses on low battery (< 20%) and skips nonessential prefetch', () async {
      SharedPreferences.setMockInitialValues({});
      final prefetcher = TilePrefetcher(null);

      expect(prefetcher.isPaused, isFalse);

      // Low battery notification arrives
      prefetcher.handleLowBattery(true);
      expect(prefetcher.isPaused, isTrue);
      expect(prefetcher.isLowBattery, isTrue);
      expect(prefetcher.error, 'low_battery');

      // Attempting to prepare active ride with route points under low battery
      final route = [(12.9716, 77.5946), (12.9720, 77.5950)];
      await prefetcher.prepareActiveRide(routeLine: route, label: 'Low Battery Test');

      // Verify nonessential tile downloads are skipped/not running
      expect(prefetcher.running, isFalse);

      // Battery restored
      prefetcher.handleLowBattery(false);
      expect(prefetcher.isPaused, isFalse);
      expect(prefetcher.isLowBattery, isFalse);
    });

    test('P2pMeshService throttles broadcast cadence in low battery mode', () async {
      final transport = _FakeMeshTransport();
      final mesh = P2pMeshService(transport: transport);
      await mesh.start(joinCode: 'TEST01', myUserId: 'u1');

      expect(mesh.isLowBattery, isFalse);

      // Set moving telemetry
      mesh.updateMyTelemetry(
        lat: 12.9716,
        lng: 77.5946,
        speedKmh: 45.0,
        heading: 90.0,
      );

      // Normal moving interval ~1.5s
      expect(mesh.computeBroadcastIntervalMs(), 1500);

      // Switch to low battery (< 20%)
      mesh.setLowBatteryMode(true);
      expect(mesh.isLowBattery, isTrue);

      // Moving interval throttled to 6s
      expect(mesh.computeBroadcastIntervalMs(), 6000);

      // Stationary telemetry (speed < 3 km/h)
      mesh.updateMyTelemetry(
        lat: 12.9716,
        lng: 77.5946,
        speedKmh: 0.0,
        heading: 90.0,
      );

      // Stationary interval throttled to 15s
      expect(mesh.computeBroadcastIntervalMs(), 15000);

      // Normal stationary interval is ~4s
      mesh.setLowBatteryMode(false);
      expect(mesh.computeBroadcastIntervalMs(), 4000);
    });

    test('ConvoyService coordinates low battery mode across mesh and tile prefetcher', () {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      final prefetcher = TilePrefetcher(null);
      final mesh = P2pMeshService(transport: _FakeMeshTransport());
      final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());

      final convoyService = ConvoyService(
        api,
        _DummyRealtimeService(),
        TripStorageService(api),
        tilePrefetcher: prefetcher,
        mesh: mesh,
      );

      expect(convoyService.isLowBattery, isFalse);
      expect(prefetcher.isPaused, isFalse);
      expect(mesh.isLowBattery, isFalse);

      // Battery drops to 16%
      convoyService.updateBatteryForTesting(16, isCharging: false);

      expect(convoyService.isLowBattery, isTrue);
      expect(prefetcher.isPaused, isTrue);
      expect(prefetcher.error, 'low_battery');
      expect(mesh.isLowBattery, isTrue);

      // Battery plugged in at 18%
      convoyService.updateBatteryForTesting(18, isCharging: true);

      expect(convoyService.isLowBattery, isFalse);
      expect(prefetcher.isPaused, isFalse);
      expect(mesh.isLowBattery, isFalse);

      convoyService.dispose();
    });
  });

  group('ISSUE-6H: Sensor Stream Optimization & Stationary Throttling', () {
    test('GPS polling profile throttles intervals and distance filters when stationary', () {
      final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
      final convoyService = ConvoyService(
        api,
        _DummyRealtimeService(),
        TripStorageService(api),
      );

      // 1. Moving normal settings: the speed band picks the cadence (slow: 2 s, high accuracy;
      // highway: 500 ms, navigation grade); no distance filter while riding (speed accuracy).
      final movingNormal = convoyService.settingsForTesting(idle: false, lowBattery: false);
      expect(movingNormal.distanceFilter, 0);
      expect(movingNormal.accuracy, LocationAccuracy.high);
      final highway = convoyService.settingsForTesting(idle: false, lowBattery: false, band: SpeedBand.highway);
      expect(highway.distanceFilter, 0);
      expect(highway.accuracy, LocationAccuracy.bestForNavigation);
      final highwayLow = convoyService.settingsForTesting(idle: false, lowBattery: true, band: SpeedBand.highway);
      expect(highwayLow.distanceFilter, 0);
      expect(highwayLow.accuracy, LocationAccuracy.high);

      // 2. Idle normal settings (stationary)
      final idleNormal = convoyService.settingsForTesting(idle: true, lowBattery: false);
      expect(idleNormal.distanceFilter, 25);
      expect(idleNormal.accuracy, LocationAccuracy.medium);

      // 3. Moving low battery settings
      final movingLow = convoyService.settingsForTesting(idle: false, lowBattery: true);
      expect(movingLow.distanceFilter, 0);
      expect(movingLow.accuracy, LocationAccuracy.medium);

      // 4. Idle low battery settings (maximum power conservation)
      final idleLow = convoyService.settingsForTesting(idle: true, lowBattery: true);
      expect(idleLow.distanceFilter, 40);
      expect(idleLow.accuracy, LocationAccuracy.low);

      convoyService.dispose();
    });

    test('Stationary transition pauses dead reckoning accelerometer subscription', () {
      final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
      final convoyService = ConvoyService(
        api,
        _DummyRealtimeService(),
        TripStorageService(api),
      );

      const userId = 'rider_opt_test';
      convoyService.setMyUserIdForTesting(userId);
      convoyService.setActiveConvoyForTesting(ConvoyModel(
        groupId: 'grp_opt',
        name: 'Optimization Convoy',
        joinCode: '654321',
        createdByUserId: userId,
        createdByUserName: 'Lead',
        createdAtEpochMs: 1700000000000,
        riders: {
          userId: RiderModel(
            userId: userId,
            name: 'Lead',
            lat: 12.9716,
            lng: 77.5946,
            lastSeenEpochMs: 1700000000000,
            speedKmh: 45.0,
          ),
        },
      ));

      // Simulate moving position (185 s before the stopped fix below)
      convoyService.handlePositionForTesting(Position(
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime.now().subtract(const Duration(seconds: 185)),
        accuracy: 10.0,
        altitude: 800.0,
        altitudeAccuracy: 5.0,
        heading: 90.0,
        headingAccuracy: 5.0,
        speed: 15.0, // 54 km/h
        speedAccuracy: 1.0,
      ));
      expect(convoyService.isGpsIdleProfile, isFalse);

      // Simulate a stationary stop for 185 seconds (3.55: the idle profile starts after 3 min)
      convoyService.setStationarySinceForTesting(
        DateTime.now().subtract(const Duration(seconds: 185)),
      );

      // Next position fix at 0 speed triggers idle profile and dead reckoning accelerometer pause
      convoyService.handlePositionForTesting(Position(
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime.now(),
        accuracy: 8.0,
        altitude: 800.0,
        altitudeAccuracy: 5.0,
        heading: 90.0,
        headingAccuracy: 5.0,
        speed: 0.0,
        speedAccuracy: 0.5,
        hasSpeed: true,
        hasSpeedAccuracy: true,
      ));

      expect(convoyService.isGpsIdleProfile, isTrue, reason: 'Must throttle GPS polling to idle when stationary');
      expect(convoyService.isDeadReckoningAccelSubscribed, isFalse, reason: 'Must unhook accelerometer when stationary');

      convoyService.dispose();
    });
  });

  group('ISSUE-6H: Battery Measurements Per Riding Hour', () {
    test('Accrues drain rates per riding hour and computes projected battery life', () {
      final monitor = BatteryPerformanceMonitor();
      var nowMs = 1700000000000;

      // Hour 1: 100% -> 94% (6% drain over 1 riding hour at 60 km/h)
      // Record 61 samples 1 minute apart (60 intervals = 3,600,000 ms)
      for (var min = 0; min <= 60; min++) {
        final level = 100 - ((min * 6) ~/ 60);
        monitor.recordSample(
          batteryLevel: level,
          isCharging: false,
          isMoving: true,
          speedKmh: 60.0,
          timestampMs: nowMs + (min * 60000),
        );
      }
      nowMs += 3600000;

      expect(monitor.hourlyMetrics.length, 1);
      final hour1 = monitor.hourlyMetrics.first;
      expect(hour1.hourIndex, 1);
      expect(hour1.startBatteryLevel, 100);
      expect(hour1.endBatteryLevel, 94);
      expect(hour1.drainPercent, 6);
      expect(hour1.ridingDurationMs, greaterThanOrEqualTo(3600000));

      // 30-minute tea stop (stationary, not moving): does NOT accrue riding duration
      for (var min = 1; min <= 30; min++) {
        monitor.recordSample(
          batteryLevel: 94,
          isCharging: false,
          isMoving: false,
          speedKmh: 0.0,
          timestampMs: nowMs + (min * 60000),
        );
      }
      nowMs += 1800000;
      expect(monitor.hourlyMetrics.length, 1, reason: 'Stationary stops must not trigger riding hours');

      // Hour 2: 94% -> 87% (7% drain over 2nd riding hour at 65 km/h)
      // 61 samples (60 intervals = 3,600,000 ms)
      for (var min = 0; min <= 60; min++) {
        final level = 94 - ((min * 7) ~/ 60);
        monitor.recordSample(
          batteryLevel: level,
          isCharging: false,
          isMoving: true,
          speedKmh: 65.0,
          timestampMs: nowMs + (min * 60000),
        );
      }

      expect(monitor.hourlyMetrics.length, 2);
      final hour2 = monitor.hourlyMetrics[1];
      expect(hour2.hourIndex, 2);
      expect(hour2.startBatteryLevel, 94);
      expect(hour2.endBatteryLevel, 87);
      expect(hour2.drainPercent, 7);

      // Verify aggregate measurements per riding hour
      expect(monitor.totalRidingHours, closeTo(2.0, 0.05));
      expect(monitor.totalRidingDrainPct, 13);
      expect(monitor.drainPerHour, closeTo(6.5, 0.2));
      // At 87% remaining with 6.5%/hr drain -> ~13.38 hours remaining
      expect(monitor.estimatedHoursRemaining, closeTo(87 / 6.5, 0.5));
    });

    test('Serializes and restores monitor state with complete hourly metric history', () {
      final monitor = BatteryPerformanceMonitor();
      final now = DateTime.now().millisecondsSinceEpoch;

      for (var i = 0; i <= 60; i++) {
        monitor.recordSample(
          batteryLevel: 100 - (i ~/ 12),
          isCharging: false,
          isMoving: true,
          speedKmh: 50.0,
          timestampMs: now + (i * 60000),
        );
      }

      final jsonStr = monitor.toJsonString();
      expect(jsonStr, isNotEmpty);

      final restored = BatteryPerformanceMonitor.fromJsonString(jsonStr);
      expect(restored.totalRidingDrainPct, monitor.totalRidingDrainPct);
      expect(restored.hourlyMetrics.length, monitor.hourlyMetrics.length);
      expect(restored.currentBatteryLevel, monitor.currentBatteryLevel);
    });
  });

  group('ISSUE-6H: Automated Performance & UI Thread Benchmarks', () {
    test('TilePrefetcher.tilesAlongAsync handles 5,000 route points without blocking UI thread', () async {
      SharedPreferences.setMockInitialValues({});

      // Generate dense 5,000 points serpentine route
      final points = <(double, double)>[];
      for (var i = 0; i < 5000; i++) {
        final lat = 12.0 + (i * 0.0002);
        final lng = 77.0 + ((i % 100) * 0.0001);
        points.add((lat, lng));
      }

      final stopwatch = Stopwatch()..start();
      final tiles = await TilePrefetcher.tilesAlongAsync(
        points,
        zooms: const [12, 13],
        maxTiles: 200,
      );
      stopwatch.stop();

      // Benchmark assertions
      expect(tiles, isNotEmpty);
      expect(tiles.length, lessThanOrEqualTo(200));
      expect(stopwatch.elapsedMilliseconds, lessThan(400),
          reason: 'Dense 5,000 points route simplification and tile sampling must finish quickly');
    });

    test('BatteryPerformanceMonitor high-frequency sample benchmark', () {
      final monitor = BatteryPerformanceMonitor();
      final base = DateTime.now().millisecondsSinceEpoch;

      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        monitor.recordSample(
          batteryLevel: 90 - (i ~/ 100),
          isCharging: false,
          isMoving: true,
          speedKmh: 55.0,
          timestampMs: base + (i * 1000),
        );
      }
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(30),
          reason: '1,000 battery telemetry samples should process in under 30ms without memory bloat');
      expect(monitor.samples.length, lessThanOrEqualTo(500),
          reason: 'Internal sample ring buffer must enforce 500 element upper bound');
    });
  });
}
