// ignore_for_file: avoid_print
// Round 10 rescue beacon lab: detection versus distance and noise, and false positives.
//
// Uses the app's own generator (RescueSynth), detector (RescueBeaconDetector) and confirmation
// rule (RescueBeaconTracker) from lib/domain/rescue/, plus a simple propagation and noise model
// (lib/domain/rescue/acoustic_scene.dart). Pure Dart, no Flutter. Run from the repository root:
//
//   tool/rescue_lab/run.sh                 # default: 6 trials per cell
//   tool/rescue_lab/run.sh --trials 20     # slower, smoother numbers
//   tool/rescue_lab/run.sh --quick         # 2 trials, fewer distances (a smoke run)
//
// Assumptions (edit them here; documented in docs/features_355/rescue_beacon.md):
//   siren at 1 m, phone in the open, alarm volume max:        82 dB SPL (2..4 kHz)
//   speaker response vs 3 kHz:  15 kHz -5 dB, 18.6 kHz -10 dB (an "old phone": 15 kHz -12, 18.6 kHz -25)
//   locator level vs siren peak: 0.22 / 0.78 = -11 dB
//   pocket / under a jacket: -8 dB at 3 kHz, -15 dB at 15..19 kHz; face-down on leaves: -5 / -8 dB
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:coroute_app/domain/rescue/acoustic_scene.dart';
import 'package:coroute_app/domain/rescue/rescue_acoustics.dart';
import 'package:coroute_app/domain/rescue/rescue_beacon_detector.dart';
import 'package:coroute_app/domain/rescue/rescue_id.dart';

const int sr = 48000;
const double sirenAt1m = 82;

class Condition {
  final String name;
  final double sirenLossDb;
  final double hfLossDb;
  final double speakerHigh; // response at 18.6 kHz vs 3 kHz
  final double speakerLow; // response at 15.2 kHz vs 3 kHz
  const Condition(this.name, this.sirenLossDb, this.hfLossDb, {this.speakerHigh = -10, this.speakerLow = -5});
}

const conditions = [
  Condition('open', 0, 0),
  Condition('face-down', 5, 8),
  Condition('pocket/jacket', 8, 15),
  Condition('old phone, open', 0, 0, speakerHigh: -25, speakerLow: -12),
];

class Scenario {
  final String name;
  final double ambient2to4k; // ambient level in the siren band (dB SPL), for audibility
  final Float64List Function(AcousticScene s, int n) noise;
  const Scenario(this.name, this.ambient2to4k, this.noise);
}

final scenarios = <Scenario>[
  Scenario('quiet forest', 28, (s, n) => s.forest(n, 35)),
  Scenario('forest + wind', 32, (s, n) {
    final x = s.forest(n, 35);
    AcousticScene.addInto(x, s.wind(n, 72));
    return x;
  }),
  Scenario('roadside, engine idling', 45, (s, n) {
    final x = s.forest(n, 35);
    AcousticScene.addInto(x, s.engine(n, 76));
    AcousticScene.addInto(x, s.road(n, 60));
    return x;
  }),
  Scenario('handling noise', 30, (s, n) {
    final x = s.forest(n, 35);
    AcousticScene.addInto(x, s.handling(n, 72));
    return x;
  }),
  Scenario('everything', 48, (s, n) {
    final x = s.forest(n, 40);
    AcousticScene.addInto(x, s.wind(n, 72));
    AcousticScene.addInto(x, s.engine(n, 76));
    AcousticScene.addInto(x, s.road(n, 60));
    AcousticScene.addInto(x, s.handling(n, 70));
    return x;
  }),
];

/// Locator SPL during a tone at [d] m.
double beaconSpl(BeaconBand band, Condition c, double d) {
  final f = band == BeaconBand.high ? 18400.0 : 15000.0;
  final speaker = band == BeaconBand.high ? c.speakerHigh : c.speakerLow;
  final at1 = sirenAt1m + 20 * math.log(RescueSynth.beaconPeak / RescueSynth.sirenPeakMax) / math.ln10 + speaker - c.hfLossDb;
  return AcousticScene.splAt(at1, f, d);
}

/// One trial: [seconds] of the locator (one band) at [d] m in [sc]. Returns (packets decoded for
/// the target, packets sent, confirmed).
(int, int, bool) trial(BeaconBand band, Condition c, Scenario sc, double d, int seed, {double seconds = 8, bool matched = true}) {
  final scene = AcousticScene(sampleRate: sr, seed: seed);
  final synth = RescueSynth(sampleRate: sr);
  final id = RescueId.fromKey('lab-$seed');
  final n = (seconds * sr).round();
  final beacon = synth.segment(seconds: seconds, rescueId: id, bands: [band], firstPacketAtS: 0.2 + (seed % 7) * 0.05);
  final toneRms = RescueSynth.beaconPeak / math.sqrt2;
  final g = AcousticScene.splToRms(beaconSpl(band, c, d)) / toneRms;
  final x = sc.noise(scene, n);
  AcousticScene.addInto(x, scene.micNoise(n));
  AcousticScene.addInto(x, beacon, g);
  final det = RescueBeaconDetector(sampleRate: sr, bands: const [BeaconBand.high, BeaconBand.low], targets: matched ? [id] : const []);
  final tr = RescueBeaconTracker(targetId: id);
  var got = 0;
  // Feed in 20 ms frames like the mic hub.
  final frame = (0.02 * sr).round();
  for (var i = 0; i < n; i += frame) {
    final end = math.min(n, i + frame);
    for (final p in det.addFloat(Float64List.sublistView(x, i, end))) {
      final t = (p.timeS * 1000).round();
      if (p.id == id) got++;
      tr.onPacket(p, t);
    }
  }
  final sent = ((seconds - 0.2 - BeaconFormat.packetS) / BeaconFormat.packetIntervalS).floor() + 1;
  return (got, sent, tr.best((seconds * 1000).round()) != null);
}

void main(List<String> args) {
  var trials = 6;
  var quick = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--trials' && i + 1 < args.length) trials = int.parse(args[++i]);
    if (args[i] == '--quick') quick = true;
  }
  if (quick) trials = 2;
  final distances = quick ? [5.0, 15.0, 30.0, 60.0] : [5.0, 10.0, 15.0, 20.0, 25.0, 30.0, 40.0, 50.0, 70.0, 100.0];
  final sw = Stopwatch()..start();
  print('# CoRoute rescue beacon lab (sample rate $sr Hz, $trials trials of 8 s per cell)\n');

  // ---------------------------------------------------------------- audible siren
  print('## Audible siren (2..4 kHz), SPL at the rescuer vs the ambient level in that band\n');
  print('| distance | open, forest | pocket, forest | open, park (no foliage) |');
  print('|---|---|---|---|');
  for (final d in [10.0, 25.0, 50.0, 75.0, 100.0, 150.0, 200.0]) {
    String cell(double loss, bool forest) => '${AcousticScene.splAt(sirenAt1m - loss, 3000, d, forest: forest).toStringAsFixed(0)} dB';
    print('| ${d.toStringAsFixed(0)} m | ${cell(0, true)} | ${cell(8, true)} | ${cell(0, false)} |');
  }
  print('\nAmbient in the 2..4 kHz band: quiet forest ~28 dB, wind ~32 dB, roadside ~45 dB. Audible to an attentive');
  print('listener when the siren is about 0..5 dB above it (its sweep makes it stand out); clearly audible 10 dB above.\n');

  // ---------------------------------------------------------------- locator detection
  print('## Locator detection (confirmed = 2 packets with the right id within 12 s; an 8 s listen)\n');
  final summary = <String, List<double>>{};
  for (final band in [BeaconBand.high, BeaconBand.low]) {
    for (final c in conditions) {
      if (quick && c.name.startsWith('face')) continue;
      print('### ${band.name} band, phone ${c.name}\n');
      print('| scenario | ${distances.map((d) => '${d.toStringAsFixed(0)} m').join(' | ')} |');
      print('|---|${distances.map((_) => '---').join('|')}|');
      for (final sc in scenarios) {
        if (quick && sc.name == 'handling noise') continue;
        final cells = <String>[];
        for (final d in distances) {
          var conf = 0, got = 0, sent = 0;
          for (var t = 0; t < trials; t++) {
            final (g, s, ok) = trial(band, c, sc, d, 1000 * t + d.round() + sc.name.length * 7);
            got += g;
            sent += s;
            if (ok) conf++;
          }
          final rate = conf / trials;
          summary.putIfAbsent('${band.name}|${c.name}|${sc.name}', () => []).add(rate);
          cells.add('${(100 * rate).round()}% (${(100 * got / math.max(1, sent)).round()}%)');
        }
        print('| ${sc.name} | ${cells.join(' | ')} |');
      }
      print('\nCells: confirmed detection rate (packet decode rate). SPL of one locator tone at the rescuer: '
          '${[for (final d in [5.0, 20.0, 40.0]) '${d.toStringAsFixed(0)} m ${beaconSpl(band, c, d).toStringAsFixed(0)} dB'].join(', ')}.\n');
    }
  }

  // ---------------------------------------------------------------- range summary
  print('## Range summary (largest distance with >= 80 % confirmed detection)\n');
  print('| band | phone | ${scenarios.where((s) => !(quick && s.name == 'handling noise')).map((s) => s.name).join(' | ')} |');
  print('|---|---|${scenarios.where((s) => !(quick && s.name == 'handling noise')).map((_) => '---').join('|')}|');
  for (final band in [BeaconBand.high, BeaconBand.low]) {
    for (final c in conditions) {
      if (quick && c.name.startsWith('face')) continue;
      final cells = <String>[];
      for (final sc in scenarios) {
        if (quick && sc.name == 'handling noise') continue;
        final rates = summary['${band.name}|${c.name}|${sc.name}']!;
        var best = 0.0;
        for (var i = 0; i < distances.length; i++) {
          if (rates[i] >= 0.8) {
            best = distances[i];
          } else {
            break;
          }
        }
        cells.add(best == 0 ? '< ${distances.first.toStringAsFixed(0)} m' : '${best.toStringAsFixed(0)} m');
      }
      print('| ${band.name} | ${c.name} | ${cells.join(' | ')} |');
    }
  }

  // ---------------------------------------------------------------- matched vs generic
  print('\n## Known-id (matched) detection vs full decoding, high band, phone open, quiet forest\n');
  print('| mode | ${distances.map((d) => '${d.toStringAsFixed(0)} m').join(' | ')} |');
  print('|---|${distances.map((_) => '---').join('|')}|');
  for (final m in [true, false]) {
    final cells = <String>[];
    for (final d in distances) {
      var conf = 0;
      for (var t = 0; t < trials; t++) {
        if (trial(BeaconBand.high, conditions.first, scenarios.first, d, 1000 * t + d.round() + 3, matched: m).$3) conf++;
      }
      cells.add('${(100 * conf / trials).round()}%');
    }
    print('| ${m ? 'known id (finder)' : 'full decode (help anyone)'} | ${cells.join(' | ')} |');
  }

  // ---------------------------------------------------------------- false positives
  final fpSeconds = quick ? 60 : 300;
  print('\n## False positives ($fpSeconds s of noise per scenario, "help anyone" mode = any id accepted)\n');
  print('| scenario | packets decoded (any id) | confirmed (any id) | target id confirmed |');
  print('|---|---|---|---|');
  var totalDecoded = 0, totalConfirmed = 0;
  for (final sc in scenarios) {
    final scene = AcousticScene(sampleRate: sr, seed: 77 + sc.name.length);
    // Known-id (matched) mode for the target, as on the finder screen, plus full decoding for any id.
    final det = RescueBeaconDetector(sampleRate: sr, targets: [RescueId.fromKey('target')]);
    final anyone = RescueBeaconTracker(helpAnyone: true);
    final target = RescueBeaconTracker(targetId: RescueId.fromKey('target'));
    var decoded = 0;
    var confirmedIds = <int>{};
    var targetConfirmed = false;
    const chunkS = 10;
    for (var c = 0; c < fpSeconds ~/ chunkS; c++) {
      final n = chunkS * sr;
      final x = sc.noise(scene, n);
      AcousticScene.addInto(x, scene.micNoise(n));
      for (final p in det.addFloat(x)) {
        final t = (p.timeS * 1000).round();
        decoded++;
        anyone.onPacket(p, t);
        target.onPacket(p, t);
        final b = anyone.best(t);
        if (b != null) confirmedIds.add(b.id);
        if (target.best(t) != null) targetConfirmed = true;
      }
    }
    totalDecoded += decoded;
    totalConfirmed += confirmedIds.length;
    print('| ${sc.name} | $decoded | ${confirmedIds.length} | ${targetConfirmed ? 'YES' : 'no'} |');
  }
  // Another rider's beacon close by must never confirm the target.
  {
    final scene = AcousticScene(sampleRate: sr, seed: 5);
    final synth = RescueSynth(sampleRate: sr);
    final other = RescueId.fromKey('other-rider');
    final targetId = RescueId.fromKey('target');
    final n = 30 * sr;
    final x = scene.forest(n, 35);
    final b = synth.segment(seconds: 30, rescueId: other, bands: BeaconBand.values);
    AcousticScene.addInto(x, b, AcousticScene.splToRms(beaconSpl(BeaconBand.high, conditions.first, 5)) / (RescueSynth.beaconPeak / math.sqrt2));
    final det = RescueBeaconDetector(sampleRate: sr, targets: [targetId]);
    final tr = RescueBeaconTracker(targetId: targetId);
    var heardOther = 0;
    for (final p in det.addFloat(x)) {
      tr.onPacket(p, (p.timeS * 1000).round());
      if (p.id == other) heardOther++;
    }
    print('\nAnother rider\'s beacon at 5 m for 30 s: $heardOther packets of the other id decoded, target confirmed: '
        '${tr.best(30000) != null ? 'YES (bug)' : 'no'}; listed as "another beacon nearby": ${tr.otherIds.contains(other)}.');
  }
  // The victim's own siren at close range must not produce locator packets (harmonics stay below 12 kHz).
  {
    final scene = AcousticScene(sampleRate: sr, seed: 9);
    final synth = RescueSynth(sampleRate: sr);
    final n = 20 * sr;
    final x = synth.siren(20, level: RescueSynth.sirenPeakMax, sweepPeriodS: 0.3);
    final g = AcousticScene.splToRms(AcousticScene.splAt(sirenAt1m, 3000, 2)) / (RescueSynth.sirenPeakMax / math.sqrt2);
    for (var i = 0; i < n; i++) {
      x[i] *= g;
    }
    AcousticScene.addInto(x, scene.micNoise(n));
    final det = RescueBeaconDetector(sampleRate: sr);
    final pk = det.addFloat(x);
    print('Siren alone at 2 m for 20 s: ${pk.length} locator packets decoded (expected 0).');
  }
  print('\nTotal over all false-positive runs: $totalDecoded stray packets decoded, $totalConfirmed confirmed ids.');
  print('\n(lab run took ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(0)} s)');
}
