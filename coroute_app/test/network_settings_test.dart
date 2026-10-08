import 'package:coroute_app/core/constants/network_constants.dart';
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
  });

  // "Hazards empty when off" through ConvoyService is covered in convoy_network_test.dart.
}
