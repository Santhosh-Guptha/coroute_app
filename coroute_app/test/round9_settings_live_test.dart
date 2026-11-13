// Round 9 (docs/quality/ROUND9_SETTINGS_NOTES.md): a speed limit changed during a ride applies on the
// next position update on the phone, in the voice, the ride notification / Live Update and the Ride AOD;
// and the fewer-settings migration (stored "off" ignored, consent never turned on). Widget tests: run
// with `flutter test test/round9_settings_live_test.dart` (the pure parts are in
// round9_speed_limit_live_pure_test.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/network_constants.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/background_service.dart';
import 'package:coroute_app/data/services/intel_care_service.dart';
import 'package:coroute_app/data/services/ride_notification_service.dart';
import 'package:coroute_app/data/services/road_care_service.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';
import 'package:coroute_app/domain/audio/voice_clarity.dart';
import 'package:coroute_app/domain/notify/live_update.dart';
import 'package:coroute_app/domain/notify/notification_snapshot.dart';
import 'package:coroute_app/domain/safety/settings_round9.dart';
import 'package:coroute_app/domain/tracking/screen_awake_policy.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/rider/widgets/ride_aod_view.dart';
import 'package:coroute_app/presentation/rider/widgets/road_ahead_settings_card.dart';

import 'audio_priority_and_fatigue_test.dart' show TestSafetyPort, TestVoiceEngine, TestAccelSource, TestSmsSender;
import 'ride_notification_service_test.dart' show FakePort, FakeChannel;

class _Port extends TestSafetyPort {
  void changed() => notifyListeners();
}

const int _t0 = 1731500000000;

ConvoyModel _ride({int speedLimitKmh = 0}) => ConvoyModel(
      groupId: 'g9',
      name: 'Speed ride',
      joinCode: '123456',
      createdByUserId: 'lead',
      createdByUserName: 'Lead',
      createdAtEpochMs: _t0,
      tripStatus: 'STARTED',
      speedLimitKmh: speedLimitKmh,
      riders: {'rider_1': RiderModel(userId: 'rider_1', name: 'Rider', lat: 17.4, lng: 78.4, lastSeenEpochMs: _t0)},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('speed limit changed mid-ride', () {
    late int now;
    late SettingsService settings;
    late _Port port;
    late TestVoiceEngine engine;
    late VoiceService voice;
    late SafetyService safety;
    var lat = 17.4;

    Future<void> start(WidgetTester tester, {int group = 0, int personal = 0}) async {
      SharedPreferences.setMockInitialValues({if (personal > 0) SafetyConstants.keySpeedLimitWarningKmh: personal});
      now = _t0;
      lat = 17.4;
      settings = SettingsService();
      await settings.load();
      port = _Port()..activeConvoy = _ride(speedLimitKmh: group);
      engine = TestVoiceEngine();
      voice = VoiceService(settings, engine: engine, clock: () => now);
      safety = SafetyService.forTest(port, settings, accel: TestAccelSource(), sms: TestSmsSender(), voice: voice, clock: () => now);
      port.changed();
      await tester.pump();
    }

    Future<void> fix(WidgetTester tester, double kmh) async {
      now += 1000;
      lat += 0.0002;
      port.emitFix(TrackPoint(lat: lat, lng: 78.4, speedKmh: kmh, ts: now));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
    }

    Future<void> end() async {
      safety.dispose();
      voice.dispose();
    }

    SafetyPrompt? overspeed() {
      for (final p in safety.prompts) {
        if (p.key == SafetyConstants.promptOverspeed) return p;
      }
      return null;
    }

    testWidgets('my own limit lowered in Settings: the limit changes at once, the warning comes on the next fix and names it', (tester) async {
      await start(tester, personal: 100);
      await fix(tester, 85);
      expect(overspeed(), isNull);
      expect(safety.currentSpeedLimit, 100);
      var notified = 0;
      safety.addListener(() => notified++);
      await settings.setSpeedLimitWarningKmh(80);
      await tester.pump();
      expect(safety.currentSpeedLimit, 80, reason: 'judged against the last fix at once');
      expect(notified, greaterThan(0), reason: 'the notification, AOD and lock-screen cockpit hear about it');
      await fix(tester, 85);
      expect(overspeed()?.message, contains('80 km/h'));
      expect(engine.spokenList.map((e) => e.$1).join('|'), contains('limit 80'));
      await end();
    });

    testWidgets('lowered twice within one minute: both warnings are spoken (the old minute key dropped the second)', (tester) async {
      await start(tester, personal: 80);
      await fix(tester, 95);
      await fix(tester, 95);
      final first = engine.spokenList.length;
      expect(first, greaterThan(0));
      await settings.setSpeedLimitWarningKmh(60);
      await fix(tester, 95);
      await fix(tester, 95);
      expect(engine.spokenList.length, greaterThan(first));
      expect(engine.spokenList.last.$1, contains('limit 60'));
      await end();
    });

    testWidgets('the lead lowers the group limit (CONFIG): this member is warned at the new limit', (tester) async {
      await start(tester, group: 100);
      await fix(tester, 90);
      expect(overspeed(), isNull);
      port.activeConvoy = port.activeConvoy!.copyWith(speedLimitKmh: 80);
      port.changed();
      await tester.pump();
      expect(safety.currentSpeedLimit, 80);
      await fix(tester, 90);
      expect(overspeed()?.message, contains('80 km/h'));
      // Raised again: the card goes on the next fix.
      port.activeConvoy = port.activeConvoy!.copyWith(speedLimitKmh: 120);
      port.changed();
      await tester.pump();
      await fix(tester, 90);
      expect(overspeed(), isNull);
      await end();
    });

    testWidgets('offline solo ride: my own limit from Settings now warns too', (tester) async {
      SharedPreferences.setMockInitialValues({SafetyConstants.keySpeedLimitWarningKmh: 60});
      now = _t0;
      settings = SettingsService();
      await settings.load();
      port = _Port()..rideActive = false;
      final solo = StreamController<TrackPoint>.broadcast();
      engine = TestVoiceEngine();
      voice = VoiceService(settings, engine: engine, clock: () => now);
      safety = SafetyService.forTest(port, settings, accel: TestAccelSource(), sms: TestSmsSender(), voice: voice, clock: () => now, soloFixes: () => solo.stream);
      expect(safety.startOfflineSoloRide(), isTrue);
      for (var i = 0; i < 3; i++) {
        now += 1000;
        solo.add(TrackPoint(lat: 17.4 + i * 0.0002, lng: 78.4, speedKmh: 75, ts: now));
        await tester.pump();
      }
      expect(overspeed()?.message, contains('60 km/h'));
      safety.stopOfflineSoloRide();
      expect(safety.currentSpeedLimit, 0);
      await solo.close();
      await end();
    });

    testWidgets('ride notification and Live Update show the new limit at once, not at the next 10 s refresh', (tester) async {
      await start(tester, personal: 100);
      BackgroundService.debugReset();
      final notifPort = FakePort();
      final channel = FakeChannel();
      final notif = RideNotificationService.forPort(notifPort, settings, channel: channel, clock: () => now, clockText: (_) => 'T', safety: safety);
      notifPort.convoy = ConvoyModel(
        groupId: 'G1',
        name: 'Weekend Ride',
        joinCode: '123456',
        createdByUserId: 'a',
        createdByUserName: 'Arjun',
        createdAtEpochMs: now,
        tripStatus: 'STARTED',
        riders: {
          'me': RiderModel(userId: 'me', name: 'Kiran', lat: 13.0, lng: 77.6, speedKmh: 40, lastSeenEpochMs: now),
          'a': RiderModel(userId: 'a', name: 'Arjun', lat: 13.01, lng: 77.6, speedKmh: 40, lastSeenEpochMs: now),
        },
      );
      notifPort.changed();
      await fix(tester, 50);
      final before = channel.shows.length;
      await settings.setSpeedLimitWarningKmh(80);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(channel.shows.length, greaterThan(before), reason: 'pushed now, not after the refresh interval');
      expect(channel.shows.last['telemetry'].toString(), contains('limit 80'));
      final live = channel.shows.last['live'];
      if (live is Map) expect(live['text'].toString(), contains('Limit 80'));
      notif.dispose();
      BackgroundService.debugReset();
      await end();
    });
  });

  group('Live Update and Ride AOD carry the limit', () {
    test('Live Update text names the limit; a solo ride with a limit gets a card of its own', () {
      expect(LiveUpdateContent.build(mode: NotifMode.ride), isNull);
      final solo = LiveUpdateContent.build(mode: NotifMode.ride, limitKmh: 60)!;
      expect(solo['title'], 'Speed limit 60 km/h');
      expect(solo['chip'], '60');
    });

    testWidgets('Ride AOD shows the limit and turns it red when over', (tester) async {
      Widget aod(double speed, int limit) => MaterialApp(home: RideAodView(speedKmh: speed, limitKmh: limit, now: () => DateTime(2026, 11, 13, 9)));
      await tester.pumpWidget(aod(50, 60));
      expect(find.text('Limit 60'), findsOneWidget);
      await tester.pumpWidget(aod(70, 60));
      expect(find.text('Over limit 60'), findsOneWidget);
      await tester.pumpWidget(aod(70, 0));
      expect(find.byKey(const Key('ride_aod_limit')), findsNothing);
    });
  });

  group('fewer settings: migration step 3', () {
    test('stored "off" / old choices from an older build are ignored and rewritten once; consent untouched', () async {
      SharedPreferences.setMockInitialValues({
        SettingsService.keySafetyDefaultsVersion: 2,
        SettingsService.keyCurveWarnings: false,
        SettingsService.keyRoadLimitDisplay: false,
        SettingsService.keyRoadOverspeedWarning: false,
        SettingsService.keyRoadOverspeedTolerancePct: 20,
        SettingsService.keyLowerMusicWhenSpeeding: false,
        SettingsService.keyNoiseReduction: 'off',
        SettingsService.keyWindNoiseMode: false,
        NetworkConstants.keyPauseOtherAudio: true,
        SettingsService.keyRideIdleMode: 'sleep',
        // The rider's own choices: never touched.
        NetworkConstants.keyVoiceWarnings: false,
        SettingsService.keyBatterySaver: true,
        NetworkConstants.keyRideOnLockScreen: false,
        SettingsService.keySirenAlerts: false,
        SafetyConstants.keySpeedLimitWarningKmh: 80,
      });
      final s = SettingsService();
      await s.load();
      await s.loadSoundSettings();
      expect(s.curveWarnings && s.roadLimitDisplay && s.roadOverspeedWarning && s.lowerMusicWhenSpeeding && s.windNoiseMode, isTrue);
      expect(s.roadOverspeedTolerancePct, 10);
      expect(s.noiseReduction, NoiseReduction.strong);
      expect(s.pauseOtherAudio, isFalse);
      expect(s.rideIdleMode, RideIdleMode.aod);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SettingsService.keySafetyDefaultsVersion), 3);
      for (final k in SettingsRound9.alwaysOnKeys) {
        expect(prefs.getBool(k), isTrue, reason: k);
      }
      for (final k in SettingsRound9.retiredKeys) {
        expect(prefs.containsKey(k), isFalse, reason: k);
      }
      expect(s.voiceWarnings, isFalse);
      expect(s.batterySaver, isTrue);
      expect(s.rideOnLockScreen, isFalse, reason: 'privacy choice kept');
      expect(s.sirenAlerts, isFalse);
      expect(s.speedLimitWarningKmh, 80);
    });

    test('a corrupt stored speed warning (wrong type) does not break loading', () async {
      SharedPreferences.setMockInitialValues({SafetyConstants.keySpeedLimitWarningKmh: 'fast', NetworkConstants.keyVoiceWarnings: false});
      final s = SettingsService();
      await s.load();
      expect(s.speedLimitWarningKmh, 0);
      expect(s.voiceWarnings, isFalse, reason: 'the rest still loaded');
    });

    test('road safety warnings: a stored "off" is ignored; consent is never switched on', () {
      final s = IntelSettings.fromJson({'hw': false, 'rr': false, 'tw': false, 'ln': false, 'bi': 180, 'con': false});
      expect(s.hazardWarnings && s.roughRoadWarnings && s.twistyWarnings && s.longRideNudges, isTrue);
      expect(s.consentOn, isFalse);
      expect(s.breakIntervalMin, 120, reason: 'never later than the always-on 2 h');
      expect(IntelSettings.fromJson({'bi': 90}).breakIntervalMin, 90, reason: 'a shorter interval chosen before is kept');
      s.roughRoadWarnings = false;
      expect(s.roughRoadWarnings, isTrue);
      expect(s.toJson()['rr'], isTrue);
    });
  });

  group('fewer settings: UI', () {
    testWidgets('Bends and speed limits card has no switches or margin picker; the estimate help is plain text', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
        value: s,
        child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: RoadAheadSettingsCard()))),
      ));
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(DropdownButton<int>), findsNothing);
      expect(find.text(RoadAheadSettingsCard.estimatedHelp), findsOneWidget);
      expect(find.text(RoadAheadSettingsCard.alwaysOnLine), findsOneWidget);
    });

    test('rough road, twisty and nudges can be muted for one ride from their card; hazards never', () {
      final care = RoadCareService(voice: null, emergency: () => false, featureOn: (_) => true, convoyLine: () => null, onChanged: () {}, now: () => _t0);
      const rough = RoadCareNotice(key: 'INTEL:ROUGH:a', title: 'Rough road ahead', message: '', rank: 1, important: false);
      expect(care.canMute(rough.key), isTrue);
      expect(care.showExternal(rough, const Duration(seconds: 15)), isTrue);
      care.muteForRide(rough.key);
      expect(care.notice, isNull, reason: 'the card goes');
      expect(care.showExternal(const RoadCareNotice(key: 'INTEL:ROUGH:b', title: 'Rough road ahead', message: '', rank: 1), const Duration(seconds: 15)), isFalse);
      const hazard = RoadCareNotice(key: 'INTEL:HAZARD:c', title: 'Hazard ahead', message: '', rank: 4);
      expect(care.canMute(hazard.key), isFalse);
      expect(care.showExternal(hazard, const Duration(seconds: 25)), isTrue);
      care.reset(); // next ride
      expect(care.showExternal(const RoadCareNotice(key: 'INTEL:ROUGH:d', title: 'Rough road ahead', message: '', rank: 5), const Duration(seconds: 15)), isTrue);
    });
  });
}
