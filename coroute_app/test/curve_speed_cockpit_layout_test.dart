// Round 7 responsive cockpit: the chip layout per screen (lib/domain/road/cockpit_layout.dart).
//   DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/curve_speed_cockpit_layout_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/road/cockpit_layout.dart';

void main() {
  test('form per screen: small phone, normal phone, landscape mount, tablet, split screen, large text', () {
    expect(CockpitLayout.of(width: 320, height: 568).form, CockpitForm.compact);
    expect(CockpitLayout.of(width: 359, height: 760).form, CockpitForm.compact);
    expect(CockpitLayout.of(width: 360, height: 760).form, CockpitForm.regular);
    expect(CockpitLayout.of(width: 412, height: 915).form, CockpitForm.regular);
    expect(CockpitLayout.of(width: 780, height: 360).form, CockpitForm.landscape);
    expect(CockpitLayout.of(width: 915, height: 412).form, CockpitForm.landscape);
    expect(CockpitLayout.of(width: 800, height: 1280).form, CockpitForm.wide);
    expect(CockpitLayout.of(width: 1280, height: 800).form, CockpitForm.wide);
    expect(CockpitLayout.of(width: 412, height: 440).form, CockpitForm.compact, reason: 'split screen: half the height');
    expect(CockpitLayout.of(width: 412, height: 915, textScale: 1.6).form, CockpitForm.compact, reason: 'large text needs the compact chips');
  });

  test('primary controls are never below 56 dp; text scale inside the chips is held at 1.0-1.3', () {
    for (final (w, h, ts) in [(320.0, 480.0, 2.0), (360.0, 640.0, 1.0), (800.0, 360.0, 0.8), (1024.0, 768.0, 1.15), (412.0, 915.0, double.nan)]) {
      final l = CockpitLayout.of(width: w, height: h, textScale: ts);
      expect(l.primaryControl, greaterThanOrEqualTo(56));
      expect(l.textScale, inInclusiveRange(1.0, 1.3));
      expect(l.signSize, greaterThanOrEqualTo(44));
    }
  });

  test('the chips fit beside a 56 dp action column on every form, at the largest text', () {
    for (final (w, h) in [(320.0, 568.0), (360.0, 640.0), (412.0, 915.0), (640.0, 360.0), (800.0, 1280.0), (412.0, 440.0)]) {
      final l = CockpitLayout.of(width: w, height: h, textScale: 2.0);
      // 16 dp screen padding on both sides, the action column and an 8 dp gap.
      expect(l.chipsWidth, lessThanOrEqualTo(w - 32 - 56 - 8), reason: '$w x $h ${l.form}');
      expect(l.chipsHeight, lessThan(h * 0.4), reason: '$w x $h');
    }
  });

  test('portrait stacks the bend chip under the sign; landscape and tablets put them side by side', () {
    expect(CockpitLayout.of(width: 360, height: 760).stacked, isTrue);
    expect(CockpitLayout.of(width: 320, height: 568).stacked, isTrue);
    expect(CockpitLayout.of(width: 800, height: 360).stacked, isFalse);
    expect(CockpitLayout.of(width: 1280, height: 800).stacked, isFalse);
  });
}
