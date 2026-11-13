// Round 10 rescue beacon: finder guide, listen gate, ping limiter, trend, BLE payload, strobe rate
// and the speaker self-test (pure Dart).
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/rescue/proximity_trend.dart';
import 'package:coroute_app/domain/rescue/rescue_acoustics.dart';
import 'package:coroute_app/domain/rescue/rescue_ble.dart';
import 'package:coroute_app/domain/rescue/rescue_finder_model.dart';
import 'package:coroute_app/domain/rescue/rescue_strobe.dart';
import 'package:coroute_app/domain/rescue/speaker_self_test.dart';

void main() {
  group('strobe (photosensitivity)', () {
    test('SOS pattern: never more than 3 flashes in any second, every cycle >= 334 ms', () {
      final p = RescueStrobe.sosPattern();
      expect(RescueStrobe.validate(p), isTrue);
      expect(RescueStrobe.peakFlashesPerSecond(p, repeats: 5), lessThanOrEqualTo(3));
      for (var i = 0; i < p.length; i += 2) {
        expect(p[i] + p[i + 1], greaterThanOrEqualTo(RescueStrobe.minCycleMs));
      }
    });

    test('a too-fast unit is raised so the rate still holds', () {
      final p = RescueStrobe.sosPattern(unit: 50);
      expect(RescueStrobe.validate(p), isTrue);
      expect(RescueStrobe.peakFlashesPerSecond(p), lessThanOrEqualTo(3));
    });

    test('validate refuses fast or malformed patterns', () {
      expect(RescueStrobe.validate([100, 100, 100, 100]), isFalse); // 5 Hz
      expect(RescueStrobe.validate([150, 150]), isFalse); // 300 ms cycle
      expect(RescueStrobe.validate([200]), isFalse);
      expect(RescueStrobe.validate([0, 400]), isFalse);
      expect(RescueStrobe.validate([167, 167, 167, 167]), isTrue); // exactly 3 per second
    });

    test('flash only when dark and not face-down / covered', () {
      expect(RescueStrobe.shouldFlash(lux: 5, covered: false, isNight: false), isTrue);
      expect(RescueStrobe.shouldFlash(lux: 500, covered: false, isNight: true), isFalse);
      expect(RescueStrobe.shouldFlash(lux: 5, covered: true, isNight: true), isFalse);
      expect(RescueStrobe.shouldFlash(lux: 5, faceDown: true, isNight: true), isFalse);
      expect(RescueStrobe.shouldFlash(isNight: true), isTrue);
      expect(RescueStrobe.shouldFlash(isNight: false), isFalse);
    });
  });

  group('listen gate: the responder phone listens only during an open SOS', () {
    test('no open SOS of another rider: never', () {
      expect(RescueListenGate.shouldListen(openSosOfOther: false, finderOpen: true, distanceToVictimM: 10), isFalse);
    });
    test('finder open: yes; near the last position: yes; far: no', () {
      expect(RescueListenGate.shouldListen(openSosOfOther: true, finderOpen: true), isTrue);
      expect(RescueListenGate.shouldListen(openSosOfOther: true, finderOpen: false, distanceToVictimM: 800), isTrue);
      expect(RescueListenGate.shouldListen(openSosOfOther: true, finderOpen: false, distanceToVictimM: 5000), isFalse);
      expect(RescueListenGate.shouldListen(openSosOfOther: true, finderOpen: false), isFalse);
      expect(RescueListenGate.shouldListen(openSosOfOther: true, finderOpen: false, distanceToVictimM: 1500, offline: true), isTrue);
    });
  });

  group('ping limiter', () {
    test('one press every 20 s', () {
      final l = RescuePingLimiter();
      expect(l.tryPress(0), isTrue);
      expect(l.tryPress(5000), isFalse);
      expect(l.secondsUntilNext(5000), 15);
      expect(l.tryPress(20000), isTrue);
    });
  });

  group('trend and BLE ranges', () {
    test('rising RSSI = hotter, falling = colder, flat = steady, a single spike ignored', () {
      final up = ProximityTrend();
      for (var i = 0; i < 16; i++) {
        up.add(i * 1000, -95 + i * 1.5);
      }
      expect(up.at(15000), TrendDirection.hotter);
      final down = ProximityTrend();
      for (var i = 0; i < 16; i++) {
        down.add(i * 1000, -60 - i * 1.5);
      }
      expect(down.at(15000), TrendDirection.colder);
      final flat = ProximityTrend();
      for (var i = 0; i < 16; i++) {
        flat.add(i * 1000, i == 12 ? -50 : -80 + (i.isEven ? 1 : -1));
      }
      expect(flat.at(15000), TrendDirection.steady);
      expect(flat.at(30000), TrendDirection.unknown, reason: 'nothing heard lately');
    });

    test('closeness bands and meter', () {
      expect(BleRanges.of(-60), BleCloseness.veryClose);
      expect(BleRanges.of(-78), BleCloseness.close);
      expect(BleRanges.of(-90), BleCloseness.inRange);
      expect(BleRanges.of(-99), BleCloseness.weak);
      expect(BleRanges.meter(-100), 0);
      expect(BleRanges.meter(-40), 1);
    });

    test('BLE payload round trip; foreign data rejected', () {
      final p = RescueBle.payload(0xc78e, flags: RescueBle.flagSiren);
      expect(p, [0x52, 1, 0xc7, 0x8e, 1]);
      expect(RescueBle.parse(p), 0xc78e);
      expect(RescueBle.parse([0x52, 2, 1, 2]), isNull);
      expect(RescueBle.parse([0x00, 1, 1, 2]), isNull);
      expect(RescueBle.parse([0x52, 1, 0, 0]), isNull);
      expect(RescueBle.parse([0x52]), isNull);
    });
  });

  group('finder guide (honest)', () {
    test('far: GPS distance, bearing and route', () {
      final g = RescueFinderModel.guide(const FinderInputs(victimLat: 12.0, victimLng: 77.0, myLat: 12.0, myLng: 76.97, myHeadingDeg: 0), name: 'Ravi');
      expect(g.closeness, FinderCloseness.far);
      expect(g.distanceM, closeTo(3260, 60));
      expect(g.bearingDeg, closeTo(90, 1));
      expect(g.arrowDeg, closeTo(90, 1));
      expect(g.status, contains('route'));
      expect(g.listenPrompt, isFalse);
    });

    test('within 150 m by GPS: listen prompt', () {
      final g = RescueFinderModel.guide(const FinderInputs(victimLat: 12.0, victimLng: 77.0, myLat: 12.0009, myLng: 77.0));
      expect(g.distanceM, lessThan(150));
      expect(g.listenPrompt, isTrue);
      expect(g.status, contains('Listen'));
    });

    test('strong BLE: very close, look and listen, with the trend line', () {
      final g = RescueFinderModel.guide(const FinderInputs(bleRssi: -65, bleTrend: TrendDirection.hotter), name: 'Ravi');
      expect(g.closeness, FinderCloseness.veryClose);
      expect(g.status, startsWith('Very close: within about 20 m. Look and listen.'));
      expect(g.trendLine, contains('closer'));
    });

    test('confirmed beacon beats GPS; colder says turn around', () {
      final g = RescueFinderModel.guide(const FinderInputs(
        victimLat: 12.0, victimLng: 77.0, myLat: 12.01, myLng: 77.0,
        beaconConfirmed: true, beaconSnrDb: 12, beaconTrend: TrendDirection.colder,
      ));
      expect(g.closeness, FinderCloseness.close);
      expect(g.trendLine, contains('Turn around'));
    });

    test('no positions: says so, never invents a distance', () {
      final g = RescueFinderModel.guide(const FinderInputs(), name: 'Ravi');
      expect(g.distanceM, isNull);
      expect(g.status, contains('No position'));
    });

    test('the honesty note says proximity, not direction', () {
      expect(RescueFinderModel.honestyNote, contains('not which way'));
    });

    test('old last fix: age and accuracy shown', () {
      final g = RescueFinderModel.guide(const FinderInputs(victimLat: 1, victimLng: 1, victimFixAgeMs: 12 * 60000, victimAccuracyM: 30), name: 'Ravi');
      expect(g.gpsNote, 'Last GPS from Ravi 12 min ago (about 30 m)');
    });
  });

  group('speaker self-test', () {
    List<double> capture({required double hiGain, required double loGain, double noise = 0.0005}) {
      const sr = 48000;
      final r = math.Random(4);
      final sig = SpeakerSelfTest.testSignal(sr);
      final lead = (SpeakerSelfTest.leadInS * sr).round();
      final out = List<double>.generate(lead + sig.length + 2400, (_) => noise * (r.nextDouble() * 2 - 1));
      final tone = (SpeakerSelfTest.toneS * sr).round();
      for (var i = 0; i < sig.length; i++) {
        out[lead + i] += sig[i] * (i < tone ? hiGain : loGain);
      }
      return out;
    }

    test('both bands heard: both (the low band carries farther, see the lab)', () {
      expect(SpeakerSelfTest.analyse(capture(hiGain: 0.05, loGain: 0.05), 48000).mode, BeaconBandMode.both);
    });
    test('only the high band heard: high only', () {
      expect(SpeakerSelfTest.analyse(capture(hiGain: 0.05, loGain: 0.0), 48000).mode, BeaconBandMode.high);
    });
    test('high band rolled off, low heard: low only', () {
      expect(SpeakerSelfTest.analyse(capture(hiGain: 0.0, loGain: 0.05), 48000).mode, BeaconBandMode.low);
    });
    test('nothing measurable: both bands', () {
      expect(SpeakerSelfTest.analyse(capture(hiGain: 0, loGain: 0), 48000).mode, BeaconBandMode.both);
      expect(SpeakerSelfTest.analyse(const [], 48000).mode, BeaconBandMode.both);
    });
    test('band mode names round trip, unknown = both', () {
      expect(BeaconBandMode.fromName('low'), BeaconBandMode.low);
      expect(BeaconBandMode.fromName(null), BeaconBandMode.both);
      expect(BeaconBandMode.both.bands.length, 2);
    });
  });
}
