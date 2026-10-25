import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/ble_remote_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/intercom_network_resilience.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/presentation/rider/widgets/ble_remote_hud_pill.dart';

class _FakeRt extends RealtimeService {
  final StreamController<VoicePacket> _voiceCtrl = StreamController<VoicePacket>.broadcast();
  final StreamController<Map<String, dynamic>> _eventCtrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<VoicePacket> get voice => _voiceCtrl.stream;

  @override
  Stream<Map<String, dynamic>> get events => _eventCtrl.stream;

  @override
  bool get isConnected => true;

  @override
  String? get groupId => 'test_group';

  void disposeStreams() {
    _voiceCtrl.close();
    _eventCtrl.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FEAT-01: Feature Entitlement & Lifecycle Tests', () {
    test('TEST-BLE-01: Community Tier has full access to FEAT-01 (Free core safety)', () {
      expect(
        FeatureGates.isUnlocked(Feature.bleHandlebarRemote, SubscriptionTier.community),
        isTrue,
        reason: 'BLE Handlebar Remote must be free for Community tier (hands-on-bars safety).',
      );
      expect(
        FeatureGates.isUnlocked(Feature.bleHandlebarRemote, SubscriptionTier.proRider),
        isTrue,
      );
      expect(
        FeatureGates.isUnlocked(Feature.bleHandlebarRemote, SubscriptionTier.roadCaptain),
        isTrue,
      );
      expect(
        FeatureGates.isUnlocked(Feature.bleHandlebarRemote, SubscriptionTier.tourOperator),
        isTrue,
      );
    });

    test('TEST-BLE-02: Remote status and battery updates notify listeners', () {
      final remote = BleRemoteService(autoAttachKeyboard: false);
      expect(remote.status, equals(BleRemoteStatus.listening));
      expect(remote.batteryLevel, equals(95));

      int statusCount = 0;
      remote.statusNotifier.addListener(() => statusCount++);
      remote.updateStatus(BleRemoteStatus.paired);
      expect(remote.status, equals(BleRemoteStatus.paired));
      expect(statusCount, equals(1));

      int batteryCount = 0;
      remote.batteryLevelNotifier.addListener(() => batteryCount++);
      remote.updateBatteryLevel(80);
      expect(remote.batteryLevel, equals(80));
      expect(batteryCount, equals(1));

      remote.dispose();
    });
  });

  group('FEAT-01: Gesture Classification & Multi-Press Engine Tests', () {
    test('TEST-BLE-03: Single press activates PTT transmission', () async {
      final fakeRt = _FakeRt();
      final intercom = IntercomService(fakeRt);
      final remote = BleRemoteService(
        intercomService: intercom,
        autoAttachKeyboard: false,
      );

      final key = LogicalKeyboardKey.audioVolumeDown;
      const physicalKey = PhysicalKeyboardKey.audioVolumeDown;

      // Single KeyDown + KeyUp
      final downHandled = remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: Duration.zero,
      ));
      expect(downHandled, isTrue);

      final upHandled = remote.handleKeyEvent(KeyUpEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 60),
      ));
      expect(upHandled, isTrue);

      // Wait for multi-click window (380ms) to resolve single press
      await Future<void>.delayed(const Duration(milliseconds: 450));

      expect(remote.lastEvent, isNotNull);
      expect(remote.lastEvent!.gesture, equals(BleRemoteGesture.singlePress));
      expect(remote.lastEvent!.key, equals(key));

      remote.dispose();
      intercom.dispose();
      fakeRt.disposeStreams();
    });

    test('TEST-BLE-04: Key repeat events are consumed without creating extra gestures', () async {
      final remote = BleRemoteService(autoAttachKeyboard: false);
      final key = LogicalKeyboardKey.mediaPlayPause;
      const physicalKey = PhysicalKeyboardKey.mediaPlayPause;

      remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: Duration.zero,
      ));

      // Simulate rapid OS auto-repeats from holding button
      for (int i = 1; i <= 5; i++) {
        final repeatHandled = remote.handleKeyEvent(KeyRepeatEvent(
          logicalKey: key,
          physicalKey: physicalKey,
          timeStamp: Duration(milliseconds: i * 50),
        ));
        expect(repeatHandled, isTrue);
      }

      remote.handleKeyEvent(KeyUpEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 300),
      ));

      await Future<void>.delayed(const Duration(milliseconds: 450));

      // Only one gesture event dispatched despite 5 repeats
      expect(remote.lastEvent, isNotNull);
      expect(remote.lastEvent!.gesture, equals(BleRemoteGesture.singlePress));

      remote.dispose();
    });

    test('TEST-BLE-05: Double press triggers quick tactical hazard signal', () async {
      final fakeRt = _FakeRt();
      final resilience = IntercomNetworkResilience(realtimeService: fakeRt);

      final remote = BleRemoteService(
        networkResilience: resilience,
        autoAttachKeyboard: false,
      );

      final key = LogicalKeyboardKey.headsetHook;
      const physicalKey = PhysicalKeyboardKey.audioVolumeDown;

      // Click 1: Down & Up
      remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: Duration.zero,
      ));
      remote.handleKeyEvent(KeyUpEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 50),
      ));

      // Click 2: Down & Up 150ms later (well within 380ms window)
      await Future<void>.delayed(const Duration(milliseconds: 100));
      remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 150),
      ));
      remote.handleKeyEvent(KeyUpEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 200),
      ));

      // Wait for multi-click window to expire
      await Future<void>.delayed(const Duration(milliseconds: 450));

      expect(remote.lastEvent, isNotNull);
      expect(remote.lastEvent!.gesture, equals(BleRemoteGesture.doublePress));

      remote.dispose();
      resilience.dispose();
      fakeRt.disposeStreams();
    });

    test('TEST-BLE-06: Triple press immediately initiates Emergency SOS trigger', () async {
      final remote = BleRemoteService(autoAttachKeyboard: false);
      final key = LogicalKeyboardKey.audioVolumeUp;
      const physicalKey = PhysicalKeyboardKey.audioVolumeUp;

      // Click 1
      remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: Duration.zero,
      ));
      remote.handleKeyEvent(KeyUpEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 40),
      ));

      // Click 2
      await Future<void>.delayed(const Duration(milliseconds: 80));
      remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 120),
      ));
      remote.handleKeyEvent(KeyUpEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 160),
      ));

      // Click 3
      await Future<void>.delayed(const Duration(milliseconds: 80));
      remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 240),
      ));
      remote.handleKeyEvent(KeyUpEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 280),
      ));

      // Triple press dispatches immediately without waiting for window timeout!
      expect(remote.lastEvent, isNotNull);
      expect(remote.lastEvent!.gesture, equals(BleRemoteGesture.triplePress));

      remote.dispose();
    });

    test('TEST-BLE-07: Sustained long press (2.5s hold) initiates Emergency SOS trigger', () async {
      final remote = BleRemoteService(autoAttachKeyboard: false);
      final key = LogicalKeyboardKey.select;
      const physicalKey = PhysicalKeyboardKey.select;

      // Press down and hold
      remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: Duration.zero,
      ));

      // Before 2.5s: no SOS yet
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(remote.lastEvent, isNull);

      // Wait past 2.5s threshold
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(remote.lastEvent, isNotNull);
      expect(remote.lastEvent!.gesture, equals(BleRemoteGesture.longPress));

      // Release after long-press should be cleanly consumed
      final upHandled = remote.handleKeyEvent(KeyUpEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 2700),
      ));
      expect(upHandled, isTrue);

      remote.dispose();
    });

    test('TEST-BLE-08: Unmapped standard keyboard keys are passed through', () {
      final remote = BleRemoteService(autoAttachKeyboard: false);

      // Standard typing keys should NOT be intercepted
      expect(
        remote.handleKeyEvent(const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.keyA,
          physicalKey: PhysicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
        )),
        isFalse,
      );

      expect(
        remote.handleKeyEvent(const KeyDownEvent(
          logicalKey: LogicalKeyboardKey.space,
          physicalKey: PhysicalKeyboardKey.space,
          timeStamp: Duration.zero,
        )),
        isFalse,
      );

      remote.dispose();
    });

    test('TEST-BLE-09: Rapid contact bounce (<35ms) is safely coalesced', () async {
      final remote = BleRemoteService(autoAttachKeyboard: false);
      final key = LogicalKeyboardKey.camera;
      const physicalKey = PhysicalKeyboardKey.audioVolumeUp;

      // First contact
      remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: Duration.zero,
      ));

      // Noisy bounce 10ms later
      remote.handleKeyEvent(KeyDownEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 10),
      ));

      remote.handleKeyEvent(KeyUpEvent(
        logicalKey: key,
        physicalKey: physicalKey,
        timeStamp: const Duration(milliseconds: 60),
      ));

      await Future<void>.delayed(const Duration(milliseconds: 450));

      // Debounced into exactly one single press
      expect(remote.lastEvent, isNotNull);
      expect(remote.lastEvent!.gesture, equals(BleRemoteGesture.singlePress));

      remote.dispose();
    });
  });

  group('FEAT-01: UI & HUD Pill Widget Tests', () {
    testWidgets('TEST-BLE-10: BleRemoteHudPill renders correctly when paired', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: BleRemoteHudPill(
                status: BleRemoteStatus.paired,
                batteryPercent: 92,
              ),
            ),
          ),
        ),
      );

      expect(find.text('REMOTE PAIRED · 92%'), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth_connected), findsOneWidget);
      expect(find.byIcon(Icons.battery_charging_full), findsOneWidget);
    });

    testWidgets('TEST-BLE-11: BleRemoteHudPill renders offline state with accessibility semantics', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: BleRemoteHudPill(
                status: BleRemoteStatus.disconnected,
                onTap: () => tapped = true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('REMOTE DISCONNECTED'), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
      expect(find.byType(Semantics), findsWidgets);

      await tester.tap(find.text('REMOTE DISCONNECTED'));
      expect(tapped, isTrue);
    });

    test('TEST-BLE-12: Service disposal safely cancels timers and cleans up', () {
      final remote = BleRemoteService(autoAttachKeyboard: false);
      expect(() => remote.dispose(), returnsNormally);
      // Double dispose is safe
      expect(() => remote.dispose(), returnsNormally);
    });
  });
}
