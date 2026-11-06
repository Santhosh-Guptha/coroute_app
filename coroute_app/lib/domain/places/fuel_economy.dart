import 'dart:math' as math;

import '../safety/fuel_profile.dart';

/// One confirmed fill. [kmSincePrev] is the distance ridden since the fill before it.
class FillRecord {
  const FillRecord({required this.at, required this.kmSincePrev, this.amount, this.full = false, this.reliable = true});
  final int at;
  final double kmSincePrev;

  /// Litres (kg, kWh) added, when the rider typed it.
  final double? amount;
  final bool full;

  /// False when GPS gaps made the distance unsure.
  final bool reliable;

  Map<String, Object?> toJson() => {'at': at, 'km': kmSincePrev, 'q': amount, 'f': full, 'r': reliable};
  static FillRecord? fromJson(Object? j) {
    if (j is! Map || j['at'] is! num || j['km'] is! num) return null;
    final km = (j['km'] as num).toDouble();
    final q = j['q'] is num ? (j['q'] as num).toDouble() : null;
    if (!km.isFinite || km < 0 || (q != null && (!q.isFinite || q <= 0))) return null;
    return FillRecord(at: (j['at'] as num).toInt(), kmSincePrev: km, amount: q, full: j['f'] == true, reliable: j['r'] != false);
  }
}

/// Learns the bike's real mileage from full-to-full fills: the amount put in at a
/// full fill (plus any partial fills since the last full one) over the distance
/// ridden since that last full fill. Bounded and smoothed. Pure.
class FuelLearning {
  FuelLearning({List<FillRecord>? fills, this.learnedKmPerUnit, this.samples = 0}) : fills = fills ?? [];

  static const double minWindowKm = 40;
  static const int maxFills = 30;

  final List<FillRecord> fills;
  double? learnedKmPerUnit;
  int samples;

  /// Adds a fill; returns the new sample (km per unit) when one was learned.
  double? addFill(FillRecord f, {required double ratedKmPerUnit, (double, double) bounds = (5, 120)}) {
    fills.add(f);
    if (fills.length > maxFills) fills.removeRange(0, fills.length - maxFills);
    if (!f.full) return null;
    var j = fills.length - 2;
    while (j >= 0 && !fills[j].full) {
      j--;
    }
    if (j < 0) return null;
    var km = 0.0, amount = 0.0;
    for (var i = j + 1; i < fills.length; i++) {
      final x = fills[i];
      if (!x.reliable || x.amount == null) return null;
      km += x.kmSincePrev;
      amount += x.amount!;
    }
    if (km < minWindowKm || amount <= 0) return null;
    final sample = km / amount;
    final lo = math.max(bounds.$1, ratedKmPerUnit > 0 ? ratedKmPerUnit * 0.5 : bounds.$1);
    final hi = math.min(bounds.$2, ratedKmPerUnit > 0 ? ratedKmPerUnit * 1.6 : bounds.$2);
    if (!sample.isFinite || sample < lo || sample > hi) return null;
    final prev = learnedKmPerUnit;
    final alpha = samples < 3 ? 0.5 : 0.3;
    learnedKmPerUnit = prev == null ? sample : prev * (1 - alpha) + sample * alpha;
    samples++;
    return sample;
  }

  /// Rated mileage until learned; after one sample a blend, then the learned value.
  double effectiveKmPerUnit(double rated) {
    final l = learnedKmPerUnit;
    if (l == null || !l.isFinite || l <= 0) return rated;
    if (rated <= 0) return l;
    return samples <= 1 ? (rated + l) / 2 : l;
  }

  Map<String, Object?> toJson() => {'v': 1, 'fills': [for (final f in fills) f.toJson()], 'learned': learnedKmPerUnit, 'n': samples};
  static FuelLearning fromJson(Object? j) {
    if (j is! Map) return FuelLearning();
    final fills = <FillRecord>[];
    if (j['fills'] is List) {
      for (final f in j['fills'] as List) {
        final r = FillRecord.fromJson(f);
        if (r != null) fills.add(r);
      }
    }
    final l = j['learned'];
    return FuelLearning(fills: fills, learnedKmPerUnit: l is num && l.isFinite && l > 0 ? l.toDouble() : null,
        samples: j['n'] is num ? (j['n'] as num).toInt().clamp(0, 1000000) : 0);
  }
}

/// Distance ridden in speed bands this ride: town stop-go uses more, steady
/// highway less, very fast more again.
class RidingStyle {
  double cityKm = 0, mixedKm = 0, highwayKm = 0, fastKm = 0;

  void add(double km, double speedKmh) {
    if (!km.isFinite || km <= 0 || km > 5 || !speedKmh.isFinite || speedKmh < 0) return;
    if (speedKmh < 30) {
      cityKm += km;
    } else if (speedKmh < 60) {
      mixedKm += km;
    } else if (speedKmh <= 95) {
      highwayKm += km;
    } else {
      fastKm += km;
    }
  }

  double get totalKm => cityKm + mixedKm + highwayKm + fastKm;

  /// Multiplies mileage: 1.0 until 5 km are known; then 0.85 to 1.08.
  double get factor {
    final t = totalKm;
    if (t < 5) return 1.0;
    final f = (cityKm * 0.88 + mixedKm * 1.0 + highwayKm * 1.05 + fastKm * 0.9) / t;
    return f.clamp(0.85, 1.08).toDouble();
  }

  void reset() => cityKm = mixedKm = highwayKm = fastKm = 0;
}

/// Usable range left (km, before reserve and buffer) with learned mileage,
/// riding style and climbing. With rated mileage, factor 1 and no climb this
/// equals [FuelProfile.usableKm]. [baselineKm] is the range confirmed at the
/// last fill, computed with the rated mileage.
double adjustedUsableKm(FuelProfile p, {required double baselineKm, required double riddenKm,
    double? effectiveKmPerUnit, double styleFactor = 1, double climbM = 0}) {
  final style = styleFactor.isFinite ? styleFactor.clamp(0.8, 1.15).toDouble() : 1.0;
  final extraKm = climbM.isFinite && climbM > 0 ? climbM / 100 : 0.0; // about 1 km more per 100 m climbed
  final ridden = math.max(0.0, riddenKm) + extraKm;
  if (p.litresMode) {
    final rated = p.mileageKmL;
    final kmpu = ((effectiveKmPerUnit != null && effectiveKmPerUnit.isFinite && effectiveKmPerUnit > 0) ? effectiveKmPerUnit : rated) * style;
    final atFill = math.max(0.0, baselineKm) / rated;
    final left = math.max(0.0, atFill - ridden / kmpu);
    return math.max(0.0, left * kmpu - (p.reserveL * kmpu + p.bufferKm));
  }
  return math.max(0.0, baselineKm - ridden / style - p.marginKm);
}
