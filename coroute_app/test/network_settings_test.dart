import 'package:coroute_app/core/constants/network_constants.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults: voice on, accident warnings on, lock screen on, large notification on, consent not seen', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsService();
    // Before load the defaults already hold.
    expect(s.voiceCritical, isTrue);
    await s.load();
    expect(s.voiceCritical, isTrue);
    expect(s.voiceWarnings, isTrue);
    expect(s.hazardAlerts, isTrue);
    expect(s.rideOnLockScreen, isTrue);
    expect(s.richNotification, isTrue);
    expect(s.netConsentSeen, isFalse);
    expect(s.netConsentPrompts, 0);
    // 3.16 defaults.
    expect(s.language, AppLanguage.system);
    expect(s.fuelRangeKm, 0);
    expect(s.speakMoreAfterDark, isTrue);
    expect(s.medicalIdOnLockScreen, isFalse);
    expect(s.documentsReminder, isTrue);
    expect(s.saveRouteMaps, isTrue);
  });

  test('3.16 settings are saved, read back and clamped; language reaches L10n', () async {
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
    await s.setSpeakMoreAfterDark(false);
    await s.setMedicalIdOnLockScreen(true);
    await s.setDocumentsReminder(false);
    await s.setSaveRouteMaps(false);
    expect(notified, 8);
    await s.setLanguage(AppLanguage.te); // no change: no notification
    expect(notified, 8);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(NetworkConstants.keyLanguage), 'te');
    expect(prefs.getInt(NetworkConstants.keyFuelRangeKm), 0);
    expect(prefs.getBool(NetworkConstants.keySpeakAfterDark), isFalse);
    expect(prefs.getBool(NetworkConstants.keyMedicalIdLock), isTrue);
    expect(prefs.getBool(NetworkConstants.keyDocsReminder), isFalse);
    expect(prefs.getBool(NetworkConstants.keySaveRouteMaps), isFalse);

    L10n.setLanguage(AppLanguage.en);
    final again = SettingsService();
    await again.load();
    expect(again.language, AppLanguage.te);
    expect(L10n.setting, AppLanguage.te, reason: 'load applies the saved language');
    expect(again.fuelRangeKm, 0);
    expect(again.speakMoreAfterDark, isFalse);
    expect(again.medicalIdOnLockScreen, isTrue);
    expect(again.documentsReminder, isFalse);
    expect(again.saveRouteMaps, isFalse);
    L10n.setLanguage(AppLanguage.system);
  });

  test('every switch is saved and read back', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsService();
    await s.load();
    var notified = 0;
    s.addListener(() => notified++);
    await s.setVoiceCritical(false);
    await s.setVoiceWarnings(false);
    await s.setHazardAlerts(false);
    await s.setRideOnLockScreen(false);
    await s.setRichNotification(false);
    await s.markNetConsentSeen();
    await s.bumpNetConsentPrompts();
    await s.bumpNetConsentPrompts();
    expect(notified, 8);
    await s.setVoiceCritical(false); // no change: no notification
    expect(notified, 8);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(NetworkConstants.keyVoiceCritical), isFalse);
    expect(prefs.getInt(NetworkConstants.keyNetConsentPrompts), 2);

    final again = SettingsService();
    await again.load();
    expect(again.voiceCritical, isFalse);
    expect(again.voiceWarnings, isFalse);
    expect(again.hazardAlerts, isFalse);
    expect(again.rideOnLockScreen, isFalse);
    expect(again.richNotification, isFalse);
    expect(again.netConsentSeen, isTrue);
    expect(again.netConsentPrompts, 2);
  });

  test('constants of the contract', () {
    expect(NetworkConstants.clientCaps, ['net1']);
    expect(NetworkConstants.assistTakenShowFor, const Duration(minutes: 2));
    expect(NetworkConstants.waveShowFor, const Duration(seconds: 5));
    expect(NetworkConstants.netConsentMaxPrompts, 3);
    expect(NetworkConstants.channelHazard, 'coroute_hazard');
    expect(NetworkConstants.channelSocial, 'coroute_social');
    expect(NetworkConstants.keyLanguage, 'coroute_language');
    expect(NetworkConstants.keyFuelRangeKm, 'coroute_fuel_range_km');
    expect(NetworkConstants.keySpeakAfterDark, 'coroute_speak_after_dark');
    expect(NetworkConstants.keyMedicalIdLock, 'coroute_medical_id_lock');
    expect(NetworkConstants.keyDocsReminder, 'coroute_docs_reminder');
    expect(NetworkConstants.keySaveRouteMaps, 'coroute_save_route_maps');
    expect(NetworkConstants.lowBatteryChipPct, 20);
    expect(NetworkConstants.liveLinkMinutes, 30);
  });

  // "Hazards empty when off" through ConvoyService is covered in convoy_network_test.dart.
}
