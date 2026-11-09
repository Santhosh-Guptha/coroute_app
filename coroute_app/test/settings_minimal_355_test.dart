// 3.55 minimal settings (docs/SETTINGS_MINIMAL_v3.55.md): safety settings are always on, a stored
// "off" from an older version is ignored and rewritten once, and the screen shows only a few rows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/network_constants.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/presentation/rider/widgets/glove_quick_settings_modal.dart';
import 'package:coroute_app/presentation/settings/settings_screen.dart';

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
      await s.setRideOnLockScreen(false);
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
        NetworkConstants.keyPauseOtherAudio: true,
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
      expect(s.pauseOtherAudio, isTrue);
      expect(s.batterySaver, isTrue);
      expect(s.speedLimitWarningKmh, 80);

      // Already migrated, and a stale "off" written later (e.g. a restored backup) is still ignored.
      await prefs.setBool(SafetyConstants.keyCrashDetection, false);
      final again = SettingsService();
      await again.load();
      expect(again.crashDetection, isTrue);
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

    testWidgets('few rows, no safety switches, More is collapsed and opens with one tap', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await pump(tester, s);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('settings_always_on')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings_speed_warning')), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(4), reason: 'voice alerts, siren alerts, battery saver, data saver');
      expect(find.byKey(const ValueKey('settings_siren_alerts')), findsOneWidget);
      for (final gone in ['settings_crash', 'settings_sms', 'settings_auto_reroute', 'settings_voice_cleanup']) {
        expect(find.byKey(ValueKey(gone)), findsNothing, reason: gone);
      }
      expect(find.byKey(const ValueKey('settings_pause_music')), findsNothing, reason: 'collapsed');

      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('settings_more')), 120, scrollable: list);
      await tester.tap(find.byKey(const ValueKey('settings_more')));
      await tester.pump();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('settings_pause_music')), 120, scrollable: list);
      await tester.tap(find.byKey(const ValueKey('settings_pause_music')));
      await tester.pump();
      expect(s.pauseOtherAudio, isTrue);
      expect(tester.takeException(), isNull);
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
