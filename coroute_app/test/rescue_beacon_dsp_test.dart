// Round 10 rescue beacon: id, packet format, synthesiser, detector, tracker and decimator (pure Dart).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/rescue/acoustic_scene.dart';
import 'package:coroute_app/domain/rescue/decimator.dart';
import 'package:coroute_app/domain/rescue/rescue_acoustics.dart';
import 'package:coroute_app/domain/rescue/rescue_beacon_detector.dart';
import 'package:coroute_app/domain/rescue/rescue_id.dart';

double _rms(List<double> x) => math.sqrt(x.fold<double>(0, (a, v) => a + v * v) / x.length);

/// [seconds] of locator (and optional siren) for [id] at [splTone] dB SPL at the mic, over [noise].
Float64List _scene(int id, {required double splTone, double seconds = 8, List<BeaconBand> bands = const [BeaconBand.high], int sampleRate = 48000, Float64List Function(AcousticScene s, int n)? noise, int seed = 1}) {
  final scene = AcousticScene(sampleRate: sampleRate, seed: seed);
  final synth = RescueSynth(sampleRate: sampleRate);
  final n = (seconds * sampleRate).round();
  final x = noise == null ? scene.forest(n, 35) : noise(scene, n);
  AcousticScene.addInto(x, scene.micNoise(n));
  final b = synth.segment(seconds: seconds, rescueId: id, bands: bands);
  AcousticScene.addInto(x, b, AcousticScene.splToRms(splTone) / (RescueSynth.beaconPeak / math.sqrt2));
  return x;
}

List<BeaconPacket> _detect(Float64List x, {int sampleRate = 48000, List<int> targets = const []}) {
  final d = RescueBeaconDetector(sampleRate: sampleRate, targets: targets);
  final out = <BeaconPacket>[];
  final frame = (0.02 * sampleRate).round();
  for (var i = 0; i < x.length; i += frame) {
    out.addAll(d.addFloat(Float64List.sublistView(x, i, math.min(x.length, i + frame))));
  }
  return out;
}

void main() {
  group('rescue id', () {
    test('same id as the gateway for the same key (FNV-1a folded to 16 bits)', () {
      // Shared vectors with gateway/test/rescue_beacon_355.test.js.
      expect(RescueId.fromKey('client-123'), 0xc78e);
      expect(RescueId.hex(RescueId.fromKey('client-123')), 'c78e');
      expect(RescueId.fromKey(''), 0);
      for (final k in ['a', 'SOS-1b2c', 'u1-1731400000000', 'solo-u9-1']) {
        final id = RescueId.fromKey(k);
        expect(id, inInclusiveRange(1, 0xFFFF));
        expect(RescueId.fromKey(k), id, reason: 'stable');
      }
    });

    test('alert id: the server value first, then clientId, then alertId', () {
      expect(RescueId.forAlert(rescueIdHex: '0a3f', clientId: 'x', alertId: 'y'), 0x0a3f);
      expect(RescueId.forAlert(rescueIdHex: 'zz', clientId: 'client-123'), 0xc78e);
      expect(RescueId.forAlert(rescueIdHex: '0000', clientId: 'client-123'), 0xc78e);
      expect(RescueId.forAlert(alertId: 'SOS-abc'), RescueId.fromKey('SOS-abc'));
      expect(RescueId.forAlert(), 0);
    });

    test('CRC-8 changes with every single-bit change of the id', () {
      const id = 0xc78e;
      for (var b = 0; b < 16; b++) {
        expect(RescueId.crc8(id ^ (1 << b)), isNot(RescueId.crc8(id)));
      }
    });
  });

  group('packet format and synthesiser', () {
    test('symbols round-trip; sync first; a corrupted symbol fails the CRC', () {
      for (final id in [1, 0x1234, 0xc78e, 0xFFFF]) {
        final s = BeaconFormat.symbolsFor(id);
        expect(s.length, 16);
        expect(s.sublist(0, 4), BeaconFormat.sync);
        expect(BeaconFormat.idFromData(s.sublist(4)), id);
        final bad = [...s.sublist(4)];
        bad[5] = (bad[5] + 1) % 4;
        expect(BeaconFormat.idFromData(bad), isNull);
      }
    });

    test('packet: 800 ms, peak capped at -13 dBFS, smooth edges (no clicks)', () {
      final p = RescueSynth().packet(0xc78e, BeaconBand.high);
      expect(p.length, 38400);
      final peak = p.fold<double>(0, (a, v) => math.max(a, v.abs()));
      expect(peak, lessThanOrEqualTo(RescueSynth.beaconPeak + 1e-9));
      expect(peak, greaterThan(0.2));
      // The first and last samples of every tone are ~0 (raised-cosine ramps).
      expect(p[0].abs(), lessThan(1e-3));
      expect(p[(0.04 * 48000).round() - 1].abs(), lessThan(0.01));
    });

    test('siren: peak at the level, sweeps 2..4 kHz, nothing in the locator bands', () {
      final s = RescueSynth().siren(2, level: 0.78, sweepPeriodS: 0.5);
      final peak = s.fold<double>(0, (a, v) => math.max(a, v.abs()));
      expect(peak, closeTo(0.78, 0.02));
      // A 2 s siren fed to the detector gives no packets at all.
      expect(_detect(s), isEmpty);
    });

    test('segment: siren + locator never exceeds full scale; PCM16 conversion', () {
      final seg = RescueSynth().segment(seconds: 4, rescueId: 0x1234, sirenLevel: RescueSynth.sirenPeakMax, sweepPeriodS: 0.3, bands: BeaconBand.values);
      final peak = seg.fold<double>(0, (a, v) => math.max(a, v.abs()));
      expect(peak, lessThanOrEqualTo(1.0));
      final pcm = RescueSynth.toPcm16(seg);
      expect(pcm.length, seg.length);
    });

    test('the locator stays well below the siren (level cap)', () {
      expect(RescueSynth.beaconPeak, lessThan(RescueSynth.sirenPeakMax / 3));
    });
  });

  group('detector', () {
    test('decodes clean packets in both bands at 48 kHz and 44.1 kHz', () {
      for (final sr in [48000, 44100]) {
        final x = RescueSynth(sampleRate: sr).segment(seconds: 6, rescueId: 0xc78e, bands: BeaconBand.values);
        final p = _detect(x, sampleRate: sr);
        expect(p.length, greaterThanOrEqualTo(5), reason: '$sr');
        expect(p.every((e) => e.id == 0xc78e), isTrue);
        expect(p.map((e) => e.band).toSet(), BeaconBand.values.toSet());
      }
    });

    test('mixed into the loud siren: still decoded', () {
      final x = RescueSynth().segment(seconds: 6, rescueId: 0x2b2b, sirenLevel: 0.78, sweepPeriodS: 0.3);
      final p = _detect(x);
      expect(p.where((e) => e.id == 0x2b2b).length, greaterThanOrEqualTo(2));
    });

    test('decoded through engine, wind, road and handling noise at a usable level', () {
      final noises = <String, Float64List Function(AcousticScene, int)>{
        'engine': (s, n) => s.engine(n, 76),
        'wind': (s, n) => s.wind(n, 72),
        'road': (s, n) => s.road(n, 62),
        'handling': (s, n) => s.handling(n, 72),
        'forest': (s, n) => s.forest(n, 40),
      };
      for (final e in noises.entries) {
        final x = _scene(0x4d2, splTone: 35, noise: e.value, seed: 3);
        final p = _detect(x).where((p) => p.id == 0x4d2).length;
        expect(p, greaterThanOrEqualTo(2), reason: e.key);
      }
    });

    test('noise alone: no packets (every scenario, 30 s each)', () {
      final scene = AcousticScene(seed: 11);
      const n = 30 * 48000;
      for (final x in [scene.forest(n, 40), scene.engine(n, 80), scene.wind(n, 75), scene.handling(n, 75), scene.white(n, 0.05)]) {
        AcousticScene.addInto(x, scene.micNoise(n));
        final p = _detect(x, targets: [0xc78e]);
        expect(p.where((e) => e.id == 0xc78e), isEmpty);
        expect(p.length, lessThanOrEqualTo(1));
      }
    });

    test('known-id (matched) mode hears weaker packets than full decoding, never another id', () {
      var plain = 0, matched = 0;
      for (var seed = 1; seed <= 4; seed++) {
        final x = _scene(0x7777, splTone: 14, seconds: 8, seed: seed);
        plain += _detect(x).where((p) => p.id == 0x7777).length;
        matched += _detect(x, targets: [0x7777]).where((p) => p.id == 0x7777).length;
        expect(_detect(x, targets: [0x1111]).where((p) => p.id == 0x1111), isEmpty);
      }
      expect(matched, greaterThanOrEqualTo(plain));
    });

    test('farther = weaker SNR (the meter falls with distance)', () {
      double snrAt(double spl) {
        final p = _detect(_scene(0x5150, splTone: spl, seed: 2)).where((p) => p.id == 0x5150).toList();
        return p.map((e) => e.snrDb).reduce((a, b) => a + b) / p.length;
      }

      expect(snrAt(45), greaterThan(snrAt(30) + 5));
    });
  });

  group('tracker (false-positive guard)', () {
    BeaconPacket pk(int id, double t, {double snr = 15}) => BeaconPacket(id: id, band: BeaconBand.high, snrDb: snr, timeS: t);

    test('one packet is not a detection; two with the same id within 12 s are', () {
      final t = RescueBeaconTracker(targetId: 0x1234);
      t.onPacket(pk(0x1234, 1), 1000);
      expect(t.best(1000), isNull);
      t.onPacket(pk(0x1234, 3), 3000);
      expect(t.best(3000)?.id, 0x1234);
    });

    test('packets too far apart do not confirm; silence for 20 s drops the lock', () {
      final t = RescueBeaconTracker(targetId: 0x1234);
      t.onPacket(pk(0x1234, 1), 1000);
      t.onPacket(pk(0x1234, 20), 20000);
      expect(t.best(20000), isNull);
      t.onPacket(pk(0x1234, 22), 22000);
      expect(t.best(22000), isNotNull);
      expect(t.best(43000), isNull);
    });

    test('other ids are ignored (listed as "another beacon") unless "help anyone"', () {
      final t = RescueBeaconTracker(targetId: 0x1234);
      t.onPacket(pk(0x9999, 1), 1000);
      t.onPacket(pk(0x9999, 3), 3000);
      expect(t.best(3000), isNull);
      expect(t.otherIds, contains(0x9999));
      t.helpAnyone = true;
      t.onPacket(pk(0x9999, 5), 5000);
      t.onPacket(pk(0x9999, 7), 7000);
      expect(t.best(7000)?.id, 0x9999);
    });

    test('rising SNR reads as hotter', () {
      final t = RescueBeaconTracker(targetId: 1);
      for (var i = 0; i < 12; i++) {
        t.onPacket(pk(1, i * 2.0, snr: 8 + i * 1.5), i * 2000);
      }
      expect(t.best(22000)!.trend.at(22000).name, 'hotter');
    });
  });

  group('decimator 48 -> 16 kHz (the ride mic hub in rescue mode)', () {
    Int16List tone(double f, int n, {int sr = 48000, double amp = 10000}) =>
        Int16List.fromList([for (var i = 0; i < n; i++) (amp * math.sin(2 * math.pi * f * i / sr)).round()]);

    test('length is a third; 1 kHz passes at unity; 12 kHz and 18 kHz are removed', () {
      final d = Decimator3();
      final out = d.process(tone(1000, 48000));
      expect(out.length, 16000);
      final pass = _rms([for (final v in out.sublist(200)) v.toDouble()]);
      expect(pass, closeTo(10000 / math.sqrt2, 200));
      for (final f in [12000.0, 18000.0]) {
        final dd = Decimator3();
        final o = dd.process(tone(f, 48000));
        final r = _rms([for (final v in o.sublist(200)) v.toDouble()]);
        expect(20 * math.log(r / (10000 / math.sqrt2)) / math.ln10, lessThan(-50), reason: '$f Hz');
      }
    });

    test('frames of any size give the same output as one block', () {
      final x = tone(700, 9600);
      final a = Decimator3().process(x);
      final d = Decimator3();
      final b = <int>[];
      for (var i = 0; i < x.length; i += 961) {
        b.addAll(d.process(Int16List.sublistView(x, i, math.min(x.length, i + 961))));
      }
      expect(b, a.toList());
    });
  });
}
