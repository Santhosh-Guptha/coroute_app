// Round 11 ride HUD: turn card text, group pill, sheet states, speed ring, safety strip
// (lib/presentation/rider/hud/hud_logic.dart).
//   DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/hud_logic_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/warning_scheduler.dart';
import 'package:coroute_app/presentation/rider/hud/hud_logic.dart';

void main() {
  group('turn card text', () {
    test('distance countdown rounds finer as the turn comes closer', () {
      expect(HudTurnText.distance(12), 'Now');
      expect(HudTurnText.distance(20), 'Now');
      expect(HudTurnText.distance(54), '50 m');
      expect(HudTurnText.distance(96), '100 m');
      expect(HudTurnText.distance(349), '350 m');
      expect(HudTurnText.distance(980), '1.0 km');
      expect(HudTurnText.distance(1260), '1.3 km');
      expect(HudTurnText.distance(9940), '9.9 km');
      expect(HudTurnText.distance(14400), '14 km');
      expect(HudTurnText.distance(double.nan), '');
      expect(HudTurnText.distance(-3), '');
    });

    test('instruction names the road', () {
      expect(HudTurnText.instruction(HudTurnDir.left, 'MG Road'), 'Turn left onto MG Road');
      expect(HudTurnText.instruction(HudTurnDir.slightRight, 'NH 44'), 'Keep right onto NH 44');
      expect(HudTurnText.instruction(HudTurnDir.straight, 'NH 44'), 'Continue on NH 44');
      expect(HudTurnText.instruction(HudTurnDir.uTurn, 'Ring Rd'), 'Make a U-turn to Ring Rd');
      expect(HudTurnText.instruction(HudTurnDir.right, '  '), 'Turn right');
    });

    test('then-line only when the next manoeuvre is close', () {
      ({HudTurnDir direction, double distanceM, String road}) t(HudTurnDir d, double m, [String r = '']) => (direction: d, distanceM: m, road: r);
      expect(HudTurnText.thenLine([t(HudTurnDir.left, 200, 'MG Rd'), t(HudTurnDir.right, 350, 'Ring Rd')]), 'Then turn right onto Ring Rd');
      expect(HudTurnText.thenLine([t(HudTurnDir.left, 200), t(HudTurnDir.sharpLeft, 450)]), 'Then sharp left');
      expect(HudTurnText.thenLine([t(HudTurnDir.left, 200), t(HudTurnDir.right, 900)]), isNull, reason: '700 m apart');
      expect(HudTurnText.thenLine([t(HudTurnDir.left, 4000), t(HudTurnDir.right, 4100)]), isNull, reason: 'first turn still far');
      expect(HudTurnText.thenLine([t(HudTurnDir.left, 200), t(HudTurnDir.straight, 300, 'NH 4')]), isNull, reason: 'a name change is no manoeuvre');
      expect(HudTurnText.thenLine([t(HudTurnDir.left, 200)]), isNull);
    });

    test('no route: road name or free ride', () {
      expect(HudTurnText.freeRideTitle('Outer Ring Rd'), 'Outer Ring Rd');
      expect(HudTurnText.freeRideTitle(null), 'Free ride');
      expect(HudTurnText.freeRideTitle(' '), 'Free ride');
    });
  });

  group('group status pill', () {
    test('solo, follower, lead, falling behind, offline', () {
      expect(HudGroupPill.text(riders: 1, solo: true), 'Solo ride');
      expect(HudGroupPill.text(riders: 5, leadAheadM: 1240), '5 riders · lead 1.2 km ahead');
      expect(HudGroupPill.text(riders: 5, leadAheadM: 420), '5 riders · lead 400 m ahead');
      expect(HudGroupPill.text(riders: 5, iAmLead: true, lastBehindM: 800), '5 riders · last 800 m behind');
      expect(HudGroupPill.text(riders: 5, leadAheadM: 300, fallingBehind: ['Ravi Kumar']), '5 riders · Ravi falling behind');
      expect(HudGroupPill.text(riders: 5, fallingBehind: ['A', 'B']), '5 riders · 2 falling behind');
      expect(HudGroupPill.text(riders: 5, riding: 4), '5 riders · 4 riding');
      expect(HudGroupPill.text(riders: 5, leadAheadM: 300, connection: 'Reconnecting'), '5 riders · Reconnecting');
      expect(HudGroupPill.warn(fallingBehind: ['A']), isTrue);
      expect(HudGroupPill.warn(), isFalse);
      expect(HudGroupPill.riderGap(1240, speedKmh: 40), '1.2 km ahead · 2 min');
      expect(HudGroupPill.riderGap(-800), '800 m behind');
      expect(HudGroupPill.riderGap(-800, speedKmh: 5), '800 m behind');
      expect(HudGroupPill.riderGap(20), 'With you');
      expect(HudGroupPill.riderGap(null), '');
    });
  });

  group('sheet', () {
    test('snap points: collapsed from the header, half between, full at the max', () {
      final (min, half, max) = HudSheet.snapPoints(screenH: 915, collapsedPx: 200);
      expect(min, closeTo(200 / 915, 0.0001));
      expect(half, 0.55);
      expect(max, 0.85);
      // Large text: tall header, half moves to the middle so it stays a distinct stop.
      final (min2, half2, max2) = HudSheet.snapPoints(screenH: 640, collapsedPx: 320);
      expect(half2, greaterThan(min2 + 0.05));
      expect(half2, lessThan(max2 - 0.05));
    });

    test('state for an extent and the tap cycle', () {
      const s = (0.22, 0.55, 0.85);
      expect(HudSheet.stateFor(0.22, s), HudSheetState.collapsed);
      expect(HudSheet.stateFor(0.40, s), HudSheetState.half);
      expect(HudSheet.stateFor(0.75, s), HudSheetState.full);
      expect(HudSheet.next(HudSheetState.collapsed), HudSheetState.half);
      expect(HudSheet.next(HudSheetState.half), HudSheetState.full);
      expect(HudSheet.next(HudSheetState.full), HudSheetState.collapsed);
    });

    test('sections per state: collapsed controls always first; group parts only in a group', () {
      final c = HudSheet.sections(HudSheetState.collapsed, solo: false, hasRoute: true);
      expect(c, [HudSection.speedRow, HudSection.groupPill, HudSection.talkBar]);
      final h = HudSheet.sections(HudSheetState.half, solo: false, hasRoute: true);
      expect(h.take(3).toList(), c);
      expect(h, containsAll([HudSection.arcSpeedometer, HudSection.rideSoFar, HudSection.speedBands, HudSection.overLimit]));
      final fGroup = HudSheet.sections(HudSheetState.full, solo: false, hasRoute: true);
      expect(fGroup, containsAll([HudSection.groupList, HudSection.intercom, HudSection.chatPreview, HudSection.tripChart, HudSection.lifecycle]));
      final fSolo = HudSheet.sections(HudSheetState.full, solo: true, hasRoute: false);
      expect(fSolo.contains(HudSection.groupList), isFalse);
      expect(fSolo.contains(HudSection.talkBar), isFalse);
      expect(fSolo, contains(HudSection.tripChart));
    });

    test('landscape handlebar mount: side panel', () {
      expect(HudSheet.sidePanel(width: 915, height: 412), isTrue);
      expect(HudSheet.sidePanel(width: 412, height: 915), isFalse);
      expect(HudSheet.sidePanel(width: 540, height: 400), isFalse);
      expect(HudSheet.sidePanelWidth(915), inInclusiveRange(320, 420));
    });
  });

  group('speed ring and dial', () {
    test('amber over the limit, red past the +10 % margin, none without a limit', () {
      expect(HudSpeedRing.level(70, 0), HudSpeedLevel.none);
      expect(HudSpeedRing.level(58, 60), HudSpeedLevel.normal);
      expect(HudSpeedRing.level(60, 60), HudSpeedLevel.normal);
      expect(HudSpeedRing.level(64, 60), HudSpeedLevel.over);
      expect(HudSpeedRing.level(66, 60), HudSpeedLevel.over);
      expect(HudSpeedRing.level(67, 60), HudSpeedLevel.strong);
    });

    test('dial top', () {
      expect(HudSpeedRing.dialMax(peakKmh: 80, limitKmh: 60), 120);
      expect(HudSpeedRing.dialMax(peakKmh: 112, limitKmh: 80), 160);
      expect(HudSpeedRing.dialMax(peakKmh: 150, limitKmh: 100), 200);
    });
  });

  group('safety strip', () {
    test('one at a time, ordered like the warning scheduler; nothing during an emergency', () {
      const behind = HudAdvisory(kind: WarnKind.fallingBehind, key: 'fb', title: 'Ravi falling behind');
      const curve = HudAdvisory(kind: WarnKind.curve, key: 'c', title: 'Sharp right bend');
      const hazard = HudAdvisory(kind: WarnKind.hazard, key: 'h', title: 'Hazard ahead');
      expect(HudSafetyStripRules.pick([behind, curve])?.key, 'c');
      expect(HudSafetyStripRules.pick([behind, curve, hazard])?.key, 'h');
      expect(HudSafetyStripRules.pick([behind])?.key, 'fb');
      expect(HudSafetyStripRules.pick([hazard], emergency: true), isNull);
      expect(HudSafetyStripRules.pick(const []), isNull);
    });

    test('curve detail', () {
      expect(HudSafetyStripRules.curveDetail(35, 300), '35 km/h · 300 m');
      expect(HudSafetyStripRules.curveDetail(0, 80), '80 m');
    });
  });

  group('numbers', () {
    test('moving time, km, band distance, percent', () {
      expect(HudFormat.clock(0), '0:00');
      expect(HudFormat.clock(65 * 60000), '1:05');
      expect(HudFormat.km(0), '0.0');
      expect(HudFormat.km(12440), '12.4');
      expect(HudFormat.km(386800), '387');
      expect(HudFormat.bandDistance(13), '10 m');
      expect(HudFormat.bandDistance(12440), '12.4 km');
      expect(HudFormat.percent(0.384), '38 %');
      expect(HudFormat.kmh(49.6), '50');
    });
  });
}
