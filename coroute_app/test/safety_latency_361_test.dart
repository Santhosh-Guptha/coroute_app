import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/domain/safety/sms_plan.dart';

/// v3.61 safety latency: with no live link the waiting SOS is texted to the group sooner, never later.
void main() {
  test('offline group text comes sooner than the online one, and never instantly', () {
    expect(SafetyConstants.smsFallbackOffline < SafetyConstants.smsFallbackAfter, isTrue);
    expect(SafetyConstants.smsFallbackOffline.inSeconds >= 10, isTrue);
    expect(SafetyConstants.smsFallbackAfter.inSeconds <= 45, isTrue);
  });
  test('crash countdown and SOS timings are unchanged', () {
    expect(SafetyConstants.crashCountdown, const Duration(seconds: 30));
    expect(SafetyConstants.crashImpactG, 4.0);
  });
  test('no fix yet: the SOS text never carries a 0, 0 map pin', () {
    final at = DateTime(2026, 11, 15, 9, 5);
    final t = SmsText.sos(name: 'Ravi', auto: false, lat: 0, lng: 0, at: at, liveLink: 'https://coroute.live/e/abc');
    expect(t.contains('0.00000'), isFalse);
    expect(t.contains('Location not known yet. Live: https://coroute.live/e/abc'), isTrue);
    final india = SmsText.indianEmergencySos(name: 'Ravi', auto: true, lat: 0, lng: 0, at: at);
    expect(india.contains('Lat:0.00000'), isFalse);
    expect(india.contains('may have crashed at 09:05'), isTrue);
    expect(india.contains('ERSS: 112'), isTrue);
    final ok = SmsText.sos(name: 'Ravi', auto: false, lat: 17.4, lng: 78.4, at: at);
    expect(ok.contains('Map:'), isTrue);
  });
}
