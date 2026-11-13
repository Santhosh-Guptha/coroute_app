import 'package:coroute_app/core/constants/network_constants.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Emergency voice, "speak more after dark", the large ride notification, the documents
// line, saving route maps on Wi-Fi and the medical ID on the lock screen are always on
// now (no switches, no saved values), so only the real rider choices are tested here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults: spoken alerts on, accident warnings on, lock screen on, safety on, consent not seen', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsService();
    // Before load the defaults already hold.
    expect(s.voiceWarnings, isTrue);
    expect(s.crashDetection, isTrue);
    await s.load();
    expect(s.voiceWarnings, isTrue);
    expect(s.hazardAlerts, isTrue);
    expect(s.rideOnLockScreen, isTrue);
    expect(s.crashDetection, isTrue);
    expect(s.fatigueReminder, isTrue);
    expect(s.soloCheckIn, isTrue);
    expect(s.autoReroute, isTrue);
    expect(s.netConsentSeen, isFalse);
    expect(s.netConsentPrompts, 0);
    // 3.16 defaults.
    expect(s.language, AppLanguage.system);
    expect(s.fuelRangeKm, 0);
    expect(s.batterySaver, isFalse);
    expect(s.speedLimitWarningKmh, 0);
  });

  test(
    '3.16 settings are saved, read back and clamped; language reaches L10n',
    () async {
      SharedPreferences.setMockInitialValues({});
      L10n.systemLanguage = 'en';
      L10n.setLanguage(AppLanguage.system);
      final s = SettingsService();
      await s.load();
      var notified = 0;
      s.addListener(() => notified++);
      await s.setLanguage(AppLanguage.te);
      expect(L10n.setting, AppLanguage.te);
      expect(L10n.current, 'te');
      expect(L10n.changes.value, 'te');
      await s.setFuelRangeKm(250);
      await s.setFuelRangeKm(9000);
      expect(s.fuelRangeKm, 1500);
      await s.setFuelRangeKm(-5);
      expect(s.fuelRangeKm, 0);
      await s.setBatterySaver(true);
      await s.setSpeedLimitWarningKmh(500);
      expect(s.speedLimitWarningKmh, SafetyConstants.speedWarningMaxKmh);
      expect(notified, 6);
      await s.setLanguage(AppLanguage.te); // no change: no notification
      expect(notified, 6);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(NetworkConstants.keyLanguage), 'te');
      expect(prefs.getInt(NetworkConstants.keyFuelRangeKm), 0);
      expect(prefs.getBool(SettingsService.keyBatterySaver), isTrue);

      L10n.setLanguage(AppLanguage.en);
      final again = SettingsService();
      await again.load();
      expect(again.language, AppLanguage.te);
      expect(
        L10n.setting,
        AppLanguage.te,
        reason: 'load applies the saved language',
      );
      expect(again.fuelRangeKm, 0);
      expect(again.batterySaver, isTrue);
      expect(again.speedLimitWarningKmh, SafetyConstants.speedWarningMaxKmh);
      L10n.setLanguage(AppLanguage.system);
    },
  );

  test('every switch is saved and read back; always-on ones ignore "off" (3.55)', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsService();
    await s.load();
    var notified = 0;
    s.addListener(() => notified++);
    await s.setVoiceWarnings(false);
    await s.setHazardAlerts(false); // always on: ignored
    await s.setRideOnLockScreen(false); // lock-screen cockpit: the rider's choice again (saved)
    await s.setAutoReroute(false); // always on: ignored
    await s.setHardwarePtt(true);
    await s.markNetConsentSeen();
    await s.bumpNetConsentPrompts();
    await s.bumpNetConsentPrompts();
    expect(notified, 6);
    await s.setVoiceWarnings(false); // no change: no notification
    expect(notified, 6);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(NetworkConstants.keyVoiceWarnings), isFalse);
    expect(prefs.getBool(SettingsService.keyAutoReroute), isTrue);
    expect(prefs.getBool(SettingsService.keyHardwarePtt), isTrue);
    expect(prefs.getInt(NetworkConstants.keyNetConsentPrompts), 2);

    final again = SettingsService();
    await again.load();
    expect(again.voiceWarnings, isFalse);
    expect(again.hazardAlerts, isTrue);
    expect(again.rideOnLockScreen, isFalse, reason: '"Show cockpit on lock screen while riding" is kept');
    expect(again.autoReroute, isTrue);
    expect(again.hardwarePtt, isTrue);
    expect(again.netConsentSeen, isTrue);
    expect(again.netConsentPrompts, 2);
  });

  test('constants of the contract', () {
    expect(NetworkConstants.clientCaps, ['net1', 'pubride1', 'posbatch1']);
    expect(NetworkConstants.assistTakenShowFor, const Duration(minutes: 2));
    expect(NetworkConstants.waveShowFor, const Duration(seconds: 5));
    expect(NetworkConstants.netConsentMaxPrompts, 3);
    expect(NetworkConstants.channelHazard, 'coroute_hazard');
    expect(NetworkConstants.channelSocial, 'coroute_social');
    expect(NetworkConstants.keyLanguage, 'coroute_language');
    expect(NetworkConstants.keyFuelRangeKm, 'coroute_fuel_range_km');
    expect(NetworkConstants.mapAlertDismissSeconds, 5);
    expect(NetworkConstants.lowBatteryChipPct, 20);
    expect(NetworkConstants.liveLinkMinutes, 30);
  });

  // "Hazards empty when off" through ConvoyService is covered in convoy_network_test.dart.
}
