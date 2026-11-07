// Phone-mount check (3.55): is the phone in a handlebar mount, a pocket, or loose in a bag?
//
// Crash detection reads the bike's motion best when the phone is fixed to the bike. In a
// pocket the body damps the impact and adds its own motion; loose in a tank bag the phone
// tumbles on its own. Pure Dart, fed with the 1 s buckets of the first minutes of riding (at
// [minSpeedKmh] or more); classifies once from [minSamples] (3 min) of riding seconds and at
// the latest after [maxSamples] (5 min). Thresholds are deliberately wide: an unclear pattern
// gives [MountKind.unknown], which never shows a card.
//
// Features over the riding seconds:
//  * jump rate: share of consecutive seconds whose tilt changed by more than [jumpDeg]
//    (a mounted phone leans smoothly with the bike; a loose phone flips around);
//  * tilt spread: standard deviation of the tilt;
//  * vibration: median stdG (engine and road vibration reach a mounted phone undamped);
//  * body motion: median gyro peak (a body moves the phone more than the handlebar does at
//    steady riding).
//
// Rules: jump rate >= [looseJumpRate] or tilt spread >= [looseTiltStd] -> loose;
// damped vibration (median stdG < [mountedMinStdG]) with body motion (gyro median >=
// [pocketGyroRadS] or tilt spread >= [pocketTiltStd]) -> pocket; undamped vibration, few jumps
// (< [mountedMaxJumpRate]) and a moderate tilt spread -> mounted; anything else -> unknown.
import 'dart:math' as math;

import 'accel_bucket.dart';

enum MountKind {
  mounted,
  pocket,
  loose,
  unknown;

  String get wire => name;

  static MountKind fromWire(String? s) => MountKind.values.firstWhere((k) => k.name == s, orElse: () => MountKind.unknown);

  /// Short label for the pre-ride phone check.
  String get label => switch (this) {
        mounted => 'Handlebar mount',
        pocket => 'In a pocket',
        loose => 'Loose or in a bag',
        unknown => 'Not sure',
      };

  /// The phone is not on the bike: crash detection is weaker.
  bool get weak => this == pocket || this == loose;
}

class MountFeatures {
  final int samples;
  final double jumpRate;
  final double tiltStd;
  final double medianStdG;
  final double medianGyro;

  const MountFeatures({required this.samples, required this.jumpRate, required this.tiltStd, required this.medianStdG, required this.medianGyro});

  @override
  String toString() => 'MountFeatures(n $samples, jumps ${jumpRate.toStringAsFixed(2)}, tiltStd ${tiltStd.toStringAsFixed(1)}, '
      'std ${medianStdG.toStringAsFixed(3)}, gyro ${medianGyro.toStringAsFixed(2)})';
}

class MountClassifier {
  MountClassifier({
    this.minSpeedKmh = 15,
    this.minSamples = 180,
    this.maxSamples = 300,
    this.jumpDeg = 25,
    this.looseJumpRate = 0.12,
    this.looseTiltStd = 25,
    this.mountedMinStdG = 0.035,
    this.mountedMaxJumpRate = 0.05,
    this.mountedMaxTiltStd = 18,
    this.pocketGyroRadS = 0.35,
    this.pocketTiltStd = 6,
  });

  final double minSpeedKmh;
  final int minSamples;
  final int maxSamples;
  final double jumpDeg;
  final double looseJumpRate;
  final double looseTiltStd;
  final double mountedMinStdG;
  final double mountedMaxJumpRate;
  final double mountedMaxTiltStd;
  final double pocketGyroRadS;
  final double pocketTiltStd;

  final List<AccelBucket> _samples = [];
  MountKind? _result;
  MountFeatures? _features;

  /// The classification once made (null while still collecting).
  MountKind? get result => _result;
  MountFeatures? get features => _features;
  int get samples => _samples.length;

  /// One riding second; returns the classification once, when it is made.
  MountKind? onBucket(AccelBucket b, {required double speedKmh}) {
    if (_result != null) return null;
    if (b.sensorConfidence < 0.5 || speedKmh < minSpeedKmh) return null;
    // A crash-like second is not a mounting pattern.
    if (b.peakG >= 3.0) return null;
    _samples.add(b);
    if (_samples.length < minSamples) return null;
    final f = featuresOf(_samples);
    final kind = classify(f);
    if (kind == MountKind.unknown && _samples.length < maxSamples) return null; // a bit more data
    _features = f;
    _result = kind;
    _samples.clear();
    return kind;
  }

  MountFeatures featuresOf(List<AccelBucket> s) {
    final n = s.length;
    if (n == 0) return const MountFeatures(samples: 0, jumpRate: 0, tiltStd: 0, medianStdG: 0, medianGyro: 0);
    var jumps = 0, pairs = 0;
    for (var i = 1; i < n; i++) {
      if (s[i].tMs - s[i - 1].tMs > 2000) continue; // not consecutive
      pairs++;
      if ((s[i].tiltDeg - s[i - 1].tiltDeg).abs() > jumpDeg) jumps++;
    }
    var sum = 0.0, sq = 0.0;
    for (final b in s) {
      sum += b.tiltDeg;
      sq += b.tiltDeg * b.tiltDeg;
    }
    final mean = sum / n;
    final tiltStd = math.sqrt(math.max(0.0, sq / n - mean * mean));
    return MountFeatures(
      samples: n,
      jumpRate: pairs == 0 ? 0 : jumps / pairs,
      tiltStd: tiltStd,
      medianStdG: _median([for (final b in s) b.stdG]),
      medianGyro: _median([for (final b in s) b.peakGyroRadS]),
    );
  }

  MountKind classify(MountFeatures f) {
    if (f.samples == 0) return MountKind.unknown;
    if (f.jumpRate >= looseJumpRate || f.tiltStd >= looseTiltStd) return MountKind.loose;
    final damped = f.medianStdG < mountedMinStdG;
    if (damped && (f.medianGyro >= pocketGyroRadS || f.tiltStd >= pocketTiltStd)) return MountKind.pocket;
    if (!damped && f.jumpRate < mountedMaxJumpRate && f.tiltStd < mountedMaxTiltStd) return MountKind.mounted;
    return MountKind.unknown;
  }

  static double _median(List<double> v) {
    if (v.isEmpty) return 0;
    final s = List<double>.of(v)..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  void reset() {
    _samples.clear();
    _result = null;
    _features = null;
  }
}
