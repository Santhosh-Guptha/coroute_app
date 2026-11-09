// 3.55 fix: settings and switches changed mid-ride take effect at once (docs/SETTINGS_LIVE_AUDIT_v3.55.md).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/ride_feature_policy.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/audio_priority_manager.dart';
import 'package:coroute_app/data/services/fuel_economy_service.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';
import 'package:coroute_app/domain/garage/bike_profile.dart';
import 'package:coroute_app/domain/places/fuel_match.dart';
import 'package:coroute_app/domain/safety/effective_speed_limit.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/rider/widgets/glove_quick_settings_modal.dart';

import 'audio_priority_and_fatigue_test.dart' show TestSafetyPort, TestVoiceEngine, TestAccelSource, TestSmsSender;

/// A speech engine that holds each line until [release] is called, so later alerts wait in the
/// Dart queue (as they do while the phone is still handing the first line over).
class GatedEngine implements VoiceEngine {
  final List<String> spoken = [];
  Completer<void> _gate = Completer<void>();
  void open() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<bool> init() async => true;
  @override
  Future<bool> speak(String text, {required bool interrupt, required String id, bool isEmergency = false, bool pauseOthers = false}) async {
    spoken.add(text);
    await _gate.future;
    _gate = Completer<void>()..complete();
    return true;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> release() async {}
}

ConvoyModel ride({int speedLimitKmh = 0, bool autoRoles = false}) => ConvoyModel(
      groupId: 'G',
      name: 'Live settings',
      joinCode: '123456',
      createdByUserId: 'lead',
      createdByUserName: 'Lead',
      createdAtEpochMs: 1700000000000,
      speedLimitKmh: speedLimitKmh,
      distanceThresholdMeters: 2500,
      stopThresholdSeconds: 300,
      voiceGuidanceEnabled: false,
      townLimitKmh: 40,
      autoRoles: autoRoles,
      featurePolicy: const RideFeaturePolicy(stretchAlertKm: 5),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('speed limit (lead fix, kept)', () {
    test('the stricter of the group and my own limit; 0 = none', () {
      expect(effectiveSpeedLimit(groupKmh: 100, personalKmh: 80), 80, reason: 'lowering mine mid-ride applies');
      expect(effectiveSpeedLimit(groupKmh: 60, personalKmh: 80), 60);
      expect(effectiveSpeedLimit(groupKmh: 0, personalKmh: 80), 80);
      expect(effectiveSpeedLimit(groupKmh: 90, personalKmh: 0), 90);
    });

    test('town limit set by the lead applies on the phone near stops (same rule as the gateway)', () {
      const stop = (17.0, 78.0);
      // ~550 m from the stop: inside 1 km, the lower town limit applies.
      expect(groupLimitAt(groupKmh: 80, townKmh: 40, lat: 17.005, lng: 78.0, places: [stop]), 40);
      // ~5.5 km away: the group limit.
      expect(groupLimitAt(groupKmh: 80, townKmh: 40, lat: 17.05, lng: 78.0, places: [stop]), 80);
      // No group limit: the town limit alone near a stop.
      expect(groupLimitAt(groupKmh: 0, townKmh: 50, lat: 17.005, lng: 78.0, places: [stop]), 50);
      // Group limit lower than the town limit: the lower one.
      expect(groupLimitAt(groupKmh: 30, townKmh: 50, lat: 17.005, lng: 78.0, places: [stop]), 30);
      // Town limit off, or an unset (0,0) place: the group limit.
      expect(groupLimitAt(groupKmh: 80, townKmh: 0, lat: 17.005, lng: 78.0, places: [stop]), 80);
      expect(groupLimitAt(groupKmh: 80, townKmh: 40, lat: 0.004, lng: 0.0, places: [(0.0, 0.0)]), 80);
      // With my own lower limit on top.
      expect(effectiveSpeedLimit(groupKmh: groupLimitAt(groupKmh: 80, townKmh: 40, lat: 17.005, lng: 78.0, places: [stop]), personalKmh: 60), 40);
    });
  });

  group('group settings model', () {
    test('a CONFIG-style copy changes only what it names; every other group setting is kept', () {
      final c = ride(autoRoles: true);
      final next = c.copyWith(speedLimitKmh: 70);
      expect(next.speedLimitKmh, 70);
      expect(next.distanceThresholdMeters, 2500);
      expect(next.stopThresholdSeconds, 300);
      expect(next.voiceGuidanceEnabled, isFalse);
      expect(next.townLimitKmh, 40);
      expect(next.autoRoles, isTrue);
      expect(next.featurePolicy.stretchAlertKm, 5);
      expect(c.copyWith(autoRoles: false).autoRoles, isFalse, reason: 'CONFIG now carries autoRoles too');
    });

    test('the server copy (fromJson of the CONFIG/snapshot fields) round-trips every group setting', () {
      final c = ride(speedLimitKmh: 90, autoRoles: true);
      final back = ConvoyModel.fromJson(c.toJson());
      expect(back.speedLimitKmh, 90);
      expect(back.distanceThresholdMeters, 2500);
      expect(back.stopThresholdSeconds, 300);
      expect(back.voiceGuidanceEnabled, isFalse);
      expect(back.townLimitKmh, 40);
      expect(back.autoRoles, isTrue);
      expect(back.featurePolicy.stretchAlertKm, 5);
    });
  });

  group('fuel economy follows the garage bike mid-ride', () {
    test('useBike switches fuel type and the learning kept for that bike, at once', () async {
      SharedPreferences.setMockInitialValues({
        'fuel_learning_v1:bike-2': jsonEncode({'v': 1, 'fills': [], 'learned': 31.0, 'n': 3}),
      });
      const bike1 = BikeProfile(id: 'bike-1', name: 'Classic');
      const bike2 = BikeProfile(id: 'bike-2', name: 'Diesel tourer', fuelType: BikeFuelType.diesel);
      final fe = FuelEconomyService(activeBike: () async => bike1);
      await fe.ensureLoaded();
      expect(fe.bikeId, 'bike-1');
      expect(fe.fuelType, BikeFuelType.petrol);
      expect(fe.learning.learnedKmPerUnit, isNull);

      // The rider picks another bike in the garage during the ride.
      await fe.useBike(bike2);
      expect(fe.bikeId, 'bike-2');
      expect(fe.fuelType, BikeFuelType.diesel);
      expect(fe.learning.learnedKmPerUnit, 31.0);

      // The same bike again is a no-op (no reload).
      final before = fe.learning;
      await fe.useBike(bike2);
      expect(identical(fe.learning, before), isTrue);

      // No bike (empty garage): petrol with the shared learning.
      await fe.useBike(null);
      expect(fe.bikeId, 'default');
      expect(fe.fuelType, BikeFuelType.petrol);
    });
  });

  group('spoken alerts switched off mid-ride', () {
    late SettingsService settings;
    late GatedEngine engine;
    late VoiceService voice;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsService();
      await settings.load();
      engine = GatedEngine();
      voice = VoiceService(settings, engine: engine, clock: () => 1700000000000);
    });
    tearDown(() => voice.dispose());

    test('lines still waiting are dropped; emergencies are never dropped', () async {
      final first = voice.speak('Turn left in 200 metres.', key: 'nav1');
      await Future<void>.delayed(Duration.zero);
      expect(engine.spoken, ['Turn left in 200 metres.']);
      voice.speakInformational('Fuel station in 5 km.', dedupeKey: 'info1').ignore();
      voice.speakConvoyAnnouncement('Regroup ahead.', dedupeKey: 'conv1').ignore();
      await Future<void>.delayed(Duration.zero);
      expect(voice.priorityManager.queueLength, 2);

      await settings.setVoiceWarnings(false);
      expect(voice.priorityManager.queueLength, 0, reason: 'the switch applies to lines already queued');

      engine.open();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(engine.spoken, ['Turn left in 200 metres.'], reason: 'nothing more was read out');
    });

    test('the lead switching group voice off drops queued navigation too', () async {
      final first = voice.speak('Keep right.', key: 'nav1');
      await Future<void>.delayed(Duration.zero);
      voice.speakNavigation('Turn right.', dedupeKey: 'nav2').ignore();
      await Future<void>.delayed(Duration.zero);
      expect(voice.priorityManager.queueLength, 1);
      voice.setGroupVoice(false);
      expect(voice.priorityManager.queueLength, 0);
      engine.open();
      await first;
    });

    test('dropQueuedWhere never drops a P0 emergency', () async {
      final m = AudioPriorityManager(engine: engine, clock: () => 1700000000000);
      final first = m.submit(text: 'Lead line.', priority: AudioPriority.p3Navigation);
      await Future<void>.delayed(Duration.zero);
      m.submit(text: 'Info.', priority: AudioPriority.p5Informational).ignore();
      await Future<void>.delayed(Duration.zero);
      expect(m.queueLength, 1);
      expect(m.dropQueuedWhere((_) => true), 1);
      expect(m.queueLength, 0);
      engine.open();
      await first;
      m.dispose();
    });
  });

  group('break reminder is always on (3.55)', () {
    testWidgets('switching it off is ignored: the 2 h break prompt still comes', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.load();
      var now = 1700000000000;
      final port = TestSafetyPort()
        ..activeConvoy = ConvoyModel(
          groupId: 'g',
          name: 'Long ride',
          joinCode: '123456',
          createdByUserId: 'captain',
          createdByUserName: 'Captain',
          createdAtEpochMs: now,
          tripStatus: 'STARTED',
          riders: {'rider_1': RiderModel(userId: 'rider_1', name: 'Rider', lat: 17.4, lng: 78.4, lastSeenEpochMs: now)},
        );
      final engine = TestVoiceEngine();
      final voice = VoiceService(settings, engine: engine, clock: () => now);
      final safety = SafetyService.forTest(port, settings, accel: TestAccelSource(), sms: TestSmsSender(), voice: voice, clock: () => now);
      addTearDown(() {
        safety.dispose();
        voice.dispose();
      });
      bool prompted() => safety.prompts.any((p) => p.key == SafetyConstants.promptFatigue);

      await settings.setFatigueReminder(false); // tried during the ride: ignored
      expect(settings.fatigueReminder, isTrue);
      port.emitFix(TrackPoint(lat: 17.4, lng: 78.4, speedKmh: 50, ts: now));
      await tester.pump();
      for (var i = 1; i <= 26; i++) {
        now += 5 * 60 * 1000;
        port.emitFix(TrackPoint(lat: 17.4 + i * 0.005, lng: 78.4, speedKmh: 55, ts: now));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 20));
      expect(prompted(), isTrue, reason: 'break prompt after 2 h 10 min');
      safety.answerPrompt(SafetyConstants.promptFatigue, primary: true);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('quick settings follow the switches', () {
    testWidgets('Voice and Battery saver rows flip on every tap (they kept the old state before)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.load();
      var screenOn = true;
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GloveQuickSettingsModal(
            settingsService: settings,
            keepScreenOn: screenOn,
            onToggleKeepScreenOn: () => screenOn = !screenOn,
          ),
        ),
      ));

      expect(settings.voiceWarnings, isTrue);
      await tester.tap(find.byKey(const Key('quick_setting_voice_alerts')));
      await tester.pump();
      expect(settings.voiceWarnings, isFalse);
      expect(find.text('Muted'), findsOneWidget);
      await tester.tap(find.byKey(const Key('quick_setting_voice_alerts')));
      await tester.pump();
      expect(settings.voiceWarnings, isTrue, reason: 'second tap turns it back on');

      await tester.tap(find.byKey(const Key('quick_setting_battery_saver')));
      await tester.pump();
      expect(settings.batterySaver, isTrue);
      expect(find.descendant(of: find.byKey(const Key('quick_setting_battery_saver')), matching: find.text('On')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quick_setting_battery_saver')));
      await tester.pump();
      expect(settings.batterySaver, isFalse);

      // 3.55: the screen always stays on while riding: no toggle here.
      expect(find.byKey(const Key('quick_setting_screen_always_on')), findsNothing);
      expect(screenOn, isTrue);
    });
  });
}
