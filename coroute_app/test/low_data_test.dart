import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/config/app_config.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('data saver is off by default and survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsService();
    await s.load();
    expect(s.lowData, isFalse);
    await s.setLowData(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppConstants.keyLowData), isTrue);

    final again = SettingsService();
    await again.load();
    expect(again.lowData, isTrue);
  });

  test('positions every 5 s in data saver mode, every 2.5 s otherwise', () {
    expect(AppConfig.telemetryInterval(true), const Duration(seconds: 5));
    expect(AppConfig.telemetryInterval(false), const Duration(milliseconds: 2500));
  });

  test('intercom at 8 kHz (half the data) in data saver mode', () {
    expect(AppConfig.sampleRateFor(true), 8000);
    expect(AppConfig.sampleRateFor(false), 16000);
    expect(AppConfig.frameBytesFor(16000), 640);
    expect(AppConfig.frameBytesFor(8000), 320);
  });

  test('the transmit rate follows the setting', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.load();
    final rt = RealtimeService();
    final ic = IntercomService(rt, settings: settings);
    expect(ic.txSampleRate, 16000);
    await settings.setLowData(true);
    expect(ic.txSampleRate, 8000);
    expect(IntercomService(rt).txSampleRate, 16000, reason: 'no settings: normal quality');
    ic.dispose();
    rt.dispose();
  });

  test('the player is set up again when a stream arrives at another rate', () {
    expect(IntercomService.needsPlayerSetup(ready: false, currentRate: null, incoming: 16000), isTrue);
    expect(IntercomService.needsPlayerSetup(ready: true, currentRate: 16000, incoming: 16000), isFalse);
    expect(IntercomService.needsPlayerSetup(ready: true, currentRate: 16000, incoming: 8000), isTrue);
    expect(IntercomService.needsPlayerSetup(ready: true, currentRate: 8000, incoming: 16000), isTrue);
  });

  test('only known sample rates are played', () {
    VoicePacket p(Object? rate) => VoicePacket(VoiceKind.start, {'sampleRate': rate}, Uint8List(0));
    expect(p(8000).sampleRate, 8000);
    expect(p(16000).sampleRate, 16000);
    expect(p(44100).sampleRate, 16000);
    expect(p(1).sampleRate, 16000);
    expect(p(null).sampleRate, 16000);
  });
}
