// Round 10 rescue beacon: the ride mic plan with a rescue (48 kHz) listener. Needs the Flutter SDK
// (ride_mic_hub.dart imports widgets / record): `flutter test test/rescue_mic_plan_test.dart`.
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/ride_mic_hub.dart';

void main() {
  MicPlan plan({bool det = false, bool ic = false, bool vox = false, bool hs = false, bool wide = false}) =>
      MicPlan.forNeeds(detection: det, intercom: ic, intercomHandsFree: vox, headset: hs, wide: wide);

  test('no rescue listener: exactly the plans of before', () {
    expect(plan(det: true), MicPlan.detection);
    expect(plan(ic: true, hs: true), MicPlan.headsetTalk);
    expect(plan(det: true).wideBand, isFalse);
  });

  test('rescue listener: raw built-in mic at 48 kHz, also with detection and hands-free talk', () {
    for (final p in [plan(wide: true), plan(det: true, wide: true), plan(det: true, ic: true, vox: true, hs: true, wide: true), plan(ic: true, wide: true)]) {
      expect(p.wideBand, isTrue);
      expect(p.processed, isFalse);
      expect(p.builtInMic, isTrue);
      expect(p.bluetooth, isFalse);
    }
  });

  test('push-to-talk held on a headset still uses the headset mic (the rescue listener pauses)', () {
    expect(plan(ic: true, hs: true, wide: true), MicPlan.headsetTalk);
  });

  test('wide plans differ from narrow ones (the capture re-opens)', () {
    expect(plan(det: true, wide: true) == MicPlan.detection, isFalse);
    expect(RideMicHub.wideSampleRate, 48000);
    expect(RideMicHub.wideFrameSamples, 960);
  });
}
