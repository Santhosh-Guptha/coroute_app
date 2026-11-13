// 3.55 minimal settings (docs/SETTINGS_MINIMAL_v3.55.md): safety settings are always on, a stored
// "off" from an older version is ignored and rewritten once, and the screen shows only a few rows.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/network_constants.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/device_diagnostic_report.dart';
import 'package:coroute_app/data/services/device_diagnostic_service.dart';
import 'package:coroute_app/data/services/rider_score_service.dart';
import 'package:coroute_app/presentation/diagnostics/pre_ride_phone_check_screen.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/presentation/rider/widgets/glove_quick_settings_modal.dart';
import 'package:coroute_app/presentation/safety/safety_settings_sheet.dart';
import 'package:coroute_app/presentation/settings/settings_screen.dart';

/// Never finishes a check: the phone check screen stays on its "checking" state.
class _PendingDiag extends DeviceDiagnosticService {
  @override
  Future<DeviceDiagnosticReport?> loadCachedReport() async => null;

  @override
  Future<DeviceDiagnosticReport> runFullDiagnostic({String? riderId, String? riderEmail, bool micTest = true}) =>
      Completer<DeviceDiagnosticReport>().future;
}

bool _allOn(SettingsService s) =>
    s.crashDetection &&
    s.smsFallback &&
    s.fatigueReminder &&
    s.soloCheckIn &&
    s.etaCheckIn &&
    s.noSignalAhead &&
    s.hazardAlerts &&
    s.rideOnLockScreen &&
    s.autoReroute &&
    s.voiceCleanup;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('always-on safety settings', () {
    test('on by default, including emergency texts', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await s.loadSoundSettings();
      expect(_allOn(s), isTrue);
      expect(s.sirenAlerts, isTrue, reason: 'siren alerts default on');
      expect(SettingsService.alwaysOnKeys, isNot(contains(SettingsService.keySirenAlerts)));
    });

    test('cannot be turned off: every setter ignores "off" and nothing is notified', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await s.loadSoundSettings();
      var notified = 0;
      s.addListener(() => notified++);
      await s.setCrashDetection(false);
      await s.setSmsFallback(false);
      await s.setFatigueReminder(false);
      await s.setSoloCheckIn(false);
      await s.setEtaCheckIn(false);
      await s.setNoSignalAhead(false);
      await s.setHazardAlerts(false);
      await s.setAutoReroute(false);
      await s.setVoiceCleanup(false);
      expect(_allOn(s), isTrue);
      expect(notified, 0);
      final prefs = await SharedPreferences.getInstance();
      for (final k in SettingsService.alwaysOnKeys) {
        expect(prefs.getBool(k), isTrue, reason: k);
      }
    });

    test('migration: a stored "off" from an older version is forced on once, with the version key', () async {
      SharedPreferences.setMockInitialValues({
        for (final k in SettingsService.alwaysOnKeys) k: false,
        // User choices are left alone, whichever way they were set.
        NetworkConstants.keyVoiceWarnings: false,
        SettingsService.keyBatterySaver: true,
        SafetyConstants.keySpeedLimitWarningKmh: 80,
      });
      final s = SettingsService();
      await s.load();
      await s.loadSoundSettings();
      expect(_allOn(s), isTrue);
      final prefs = await SharedPreferences.getInstance();
      for (final k in SettingsService.alwaysOnKeys) {
        expect(prefs.getBool(k), isTrue, reason: k);
      }
      expect(prefs.getInt(SettingsService.keySafetyDefaultsVersion), SettingsService.safetyDefaultsVersion);
      // Never turns a rider's choice off (or on).
      expect(s.voiceWarnings, isFalse);
      expect(s.batterySaver, isTrue);
      expect(s.speedLimitWarningKmh, 80);

      // Already migrated, and a stale "off" written later (e.g. a restored backup) is still ignored.
      await prefs.setBool(SafetyConstants.keyCrashDetection, false);
      final again = SettingsService();
      await again.load();
      expect(again.crashDetection, isTrue);
    });
  });

  group('fixed defaults (Nov 11): give-way side, safety report in my score', () {
    test('migration v2 forces give-way to Automatic and the score report on, once, with the version key', () async {
      SharedPreferences.setMockInitialValues({
        SettingsService.keySafetyDefaultsVersion: 1,
        SettingsService.keyGiveWaySide: 'right',
        RiderScoreService.prefsUseReport: false,
        // A choice the rider still has: never touched by v2.
        SettingsService.keySirenAlerts: false,
      });
      final s = SettingsService();
      await s.load();
      await s.loadSoundSettings();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SettingsService.keySafetyDefaultsVersion), SettingsService.safetyDefaultsVersion);
      expect(prefs.getString(SettingsService.keyGiveWaySide), 'auto');
      expect(s.giveWaySide, 'auto');
      expect(prefs.getBool(RiderScoreService.prefsUseReport), isTrue);
      expect(prefs.getInt(RiderScoreService.prefsSendFrom), isNotNull, reason: 'rides from while it was off are never sent');
      expect(s.sirenAlerts, isFalse, reason: 'v2 never re-runs the v1 siren step');
    });

    test('a rider who had the score report on gets no send-from cut-off', () async {
      SharedPreferences.setMockInitialValues({SettingsService.keySafetyDefaultsVersion: 1});
      final s = SettingsService();
      await s.load();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(RiderScoreService.prefsUseReport), isTrue);
      expect(prefs.containsKey(RiderScoreService.prefsSendFrom), isFalse);
    });

    test('give-way side cannot be changed any more', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await s.loadSoundSettings();
      await s.setGiveWaySide('left');
      expect(s.giveWaySide, 'auto');
    });
  });

  group('siren alerts switch (default on)', () {
    test('the rider can turn it off and on; the choice is kept', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await s.loadSoundSettings();
      var notified = 0;
      s.addListener(() => notified++);
      await s.setSirenAlerts(false);
      expect(s.sirenAlerts, isFalse);
      expect(notified, 1, reason: 'listeners (detector / mic hub) release the mic at once');
      final again = SettingsService();
      await again.load();
      await again.loadSoundSettings();
      expect(again.sirenAlerts, isFalse, reason: 'already migrated: never forced back on');
      await again.setSirenAlerts(true);
      expect(again.sirenAlerts, isTrue);
    });

    test('migration: the value the old round forced on stays on; an older "off" becomes on once', () async {
      // Upgraded from before 3.55 with siren off: the version-1 migration turns it on (default on).
      SharedPreferences.setMockInitialValues({SettingsService.keySirenAlerts: false});
      final s = SettingsService();
      await s.load();
      await s.loadSoundSettings();
      expect(s.sirenAlerts, isTrue);
      // Already migrated by the last round (forced on): stays on, never forced off.
      SharedPreferences.setMockInitialValues({
        SettingsService.keySirenAlerts: true,
        SettingsService.keySafetyDefaultsVersion: SettingsService.safetyDefaultsVersion,
      });
      final t = SettingsService();
      await t.load();
      await t.loadSoundSettings();
      expect(t.sirenAlerts, isTrue);
    });
  });

  group('settings screen', () {
    Future<void> pump(WidgetTester tester, SettingsService s) async {
      AppTheme.use(AppPalette.light);
      addTearDown(() => AppTheme.use(AppPalette.dark));
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
        value: s,
        child: MaterialApp(theme: AppTheme.themeFor(AppPalette.light), home: const SettingsScreen()),
      ));
      await tester.pump();
    }

    // Round 9 (docs/quality/ROUND9_SETTINGS_NOTES.md): two switches on the main screen; the lock-screen
    // cockpit (a privacy choice) is the only switch under Advanced.
    testWidgets('few rows, no safety switches, Advanced is collapsed and opens with one tap', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await pump(tester, s);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('settings_always_on')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings_speed_warning')), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(2), reason: 'siren alerts, data saver');
      expect(find.byKey(const ValueKey('settings_siren_alerts')), findsOneWidget);
      for (final gone in ['settings_crash', 'settings_sms', 'settings_auto_reroute', 'settings_voice_cleanup', 'settings_spoken_alerts', 'batterySaver',
        'settings_ride_idle', 'settings_keep_screen_on']) {
        expect(find.byKey(ValueKey(gone)), findsNothing, reason: gone);
      }
      expect(find.byKey(const ValueKey('settings_lock_screen_cockpit')), findsNothing, reason: 'collapsed');
      expect(find.text(SettingsScreen.moreTitle), findsOneWidget);

      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('settings_more')), 120, scrollable: list);
      await tester.tap(find.byKey(const ValueKey('settings_more')));
      await tester.pump();
      for (final gone in ['settings_pause_music', 'settings_lower_music_speeding']) {
        expect(find.byKey(ValueKey(gone)), findsNothing, reason: gone);
      }
      await tester.scrollUntilVisible(find.byKey(const ValueKey('settings_lock_screen_cockpit')), 120, scrollable: list);
      await tester.tap(find.byKey(const ValueKey('settings_lock_screen_cockpit')));
      await tester.pump();
      expect(s.rideOnLockScreen, isFalse, reason: 'still the rider\'s choice (privacy)');
      expect(tester.takeException(), isNull);
    });

    testWidgets('round 9: fits a small phone (320 x 568) with no overflow, Advanced open', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      AppTheme.use(AppPalette.light);
      addTearDown(() => AppTheme.use(AppPalette.dark));
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
        value: s,
        child: MaterialApp(theme: AppTheme.themeFor(AppPalette.light), home: const SettingsScreen()),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('settings_more')), 120, scrollable: list);
      await tester.tap(find.byKey(const ValueKey('settings_more')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('none of the removed rows, even with More open; Safety health is on the main screen', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await pump(tester, s);
      expect(find.byKey(const ValueKey('settings_safety_health')), findsOneWidget);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('settings_more')), 120, scrollable: list);
      await tester.tap(find.byKey(const ValueKey('settings_more')));
      await tester.pump();
      for (final k in SettingsScreen.removedRowKeys) {
        expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
      }
      for (final t in ['Give way to the', 'Safety report in my score', 'Offline maps', 'Rate CoRoute', 'Send feedback', 'Diagnostics', 'Phone check',
        SafetyTexts.helpTitle, SafetyTexts.askTitle]) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('Safety health opens the phone check screen, not Settings', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      AppTheme.use(AppPalette.light);
      addTearDown(() => AppTheme.use(AppPalette.dark));
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: s),
          ChangeNotifierProvider<DeviceDiagnosticService>.value(value: _PendingDiag()),
        ],
        child: MaterialApp(theme: AppTheme.themeFor(AppPalette.light), home: const SettingsScreen()),
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('settings_safety_health')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PreRidePhoneCheckScreen), findsOneWidget);
      expect(find.byType(SettingsScreen, skipOffstage: false), findsOneWidget, reason: 'covered by the phone check, not a second Settings');
    });

    test('the "Safety is always on" list names helping and asking nearby riders', () {
      final labels = SettingsScreen.alwaysOn.map((e) => e.$2).toList();
      expect(labels, contains(SafetyTexts.helpTitle));
      expect(labels, contains(SafetyTexts.askTitle));
    });

    testWidgets('siren alerts switch turns off with one tap', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await s.loadSoundSettings();
      await pump(tester, s);
      expect(find.text(SettingsScreen.sirenSubtitle), findsOneWidget);
      expect(SettingsScreen.alwaysOn.map((e) => e.$2), isNot(contains(SettingsScreen.sirenTitle)));
      await tester.tap(find.byKey(const ValueKey('settings_siren_alerts')));
      await tester.pump();
      expect(s.sirenAlerts, isFalse);
    });

    testWidgets('the speed warning value stays mine', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await pump(tester, s);
      final chip = SafetyConstants.speedWarningChoices.lastWhere((v) => v > 0);
      await tester.tap(find.text('$chip'));
      await tester.pump();
      expect(s.speedLimitWarningKmh, chip);
    });
  });

  testWidgets('quick settings: three big toggles, no screen-on toggle', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsService();
    await s.load();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: GloveQuickSettingsModal(settingsService: s))));
    for (final k in ['quick_setting_voice_alerts', 'quick_setting_night_map', 'quick_setting_battery_saver']) {
      expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(96), reason: k);
    }
    expect(find.byKey(const Key('quick_setting_screen_always_on')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
