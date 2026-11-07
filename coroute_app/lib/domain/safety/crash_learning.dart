// Crash detection that learns (3.55): each "I'm OK" on a crash alarm (a false alarm) raises the
// threshold of the "possible crash" stage that fired, for this bike and phone mount only.
//
// Bounded and additive, never making a real crash less likely to alarm on the severe paths:
//  * only two stages learn: the lowside / slide stage (moderate impact with rotation or tilt,
//    CrashScenario.lowsideSlide) and the low-speed fall stage (CrashScenario.stationaryDrop);
//  * the severe paths never change: high impact (dynamic >= 3.8 g or raw >= 4 g) and the
//    high-side tumble always alarm exactly as before, whatever was learned;
//  * +5% per false alarm, at most +25%; back down by 2 points per alarm-free riding hour;
//  * kept per bike (garage active bike id, 'default' without one), on the phone only.
//
// Pure Dart (JSON in, JSON out); persistence lives in the data layer.
import 'dart:math' as math;

import 'crash_incident.dart';

/// Learned adjustment for one bike.
class CrashLearningState {
  /// Extra percent on the slide stage threshold (0..[CrashLearning.capPct]).
  final double slidePct;

  /// Extra percent on the low-speed fall stage threshold (0..[CrashLearning.capPct]).
  final double lowFallPct;

  /// False alarms learned from since the last reset (shown in Settings).
  final int falseAlarms;

  /// Alarm-free riding time not yet turned into a decay step (ms, < 1 h).
  final int rideMsSinceDecay;

  const CrashLearningState({this.slidePct = 0, this.lowFallPct = 0, this.falseAlarms = 0, this.rideMsSinceDecay = 0});

  static const CrashLearningState none = CrashLearningState();

  bool get isEmpty => slidePct <= 0 && lowFallPct <= 0 && falseAlarms == 0;

  /// The multiplier for the slide stage thresholds (1.0 .. 1.25).
  double get slideScale => 1.0 + slidePct / 100.0;

  /// The multiplier for the low-speed fall stage thresholds (1.0 .. 1.25).
  double get lowFallScale => 1.0 + lowFallPct / 100.0;

  CrashLearningState copyWith({double? slidePct, double? lowFallPct, int? falseAlarms, int? rideMsSinceDecay}) => CrashLearningState(
        slidePct: slidePct ?? this.slidePct,
        lowFallPct: lowFallPct ?? this.lowFallPct,
        falseAlarms: falseAlarms ?? this.falseAlarms,
        rideMsSinceDecay: rideMsSinceDecay ?? this.rideMsSinceDecay,
      );

  Map<String, Object> toJson() => {
        's': double.parse(slidePct.toStringAsFixed(2)),
        'l': double.parse(lowFallPct.toStringAsFixed(2)),
        'n': falseAlarms,
        'r': rideMsSinceDecay,
      };

  static CrashLearningState fromJson(Object? j) {
    if (j is! Map) return none;
    double d(String k) {
      final v = (j[k] as num?)?.toDouble() ?? 0;
      return v.isFinite ? v.clamp(0.0, CrashLearning.capPct).toDouble() : 0;
    }

    final n = (j['n'] as num?)?.toInt() ?? 0;
    final r = (j['r'] as num?)?.toInt() ?? 0;
    return CrashLearningState(
      slidePct: d('s'),
      lowFallPct: d('l'),
      falseAlarms: math.max(0, math.min(n, 9999)),
      rideMsSinceDecay: r.clamp(0, CrashLearning.decayEvery.inMilliseconds - 1),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CrashLearningState &&
      other.slidePct == slidePct &&
      other.lowFallPct == lowFallPct &&
      other.falseAlarms == falseAlarms &&
      other.rideMsSinceDecay == rideMsSinceDecay;

  @override
  int get hashCode => Object.hash(slidePct, lowFallPct, falseAlarms, rideMsSinceDecay);

  @override
  String toString() => 'CrashLearningState(slide +${slidePct.toStringAsFixed(1)}%, low +${lowFallPct.toStringAsFixed(1)}%, n $falseAlarms)';
}

/// The learning rules (pure functions).
class CrashLearning {
  CrashLearning._();

  static const double stepPct = 5;
  static const double capPct = 25;
  static const double decayPct = 2;
  static const Duration decayEvery = Duration(hours: 1);

  /// The id the learning is kept under: the garage's active bike, else 'default'.
  static String bikeKey(String? bikeId) {
    final id = (bikeId ?? '').trim();
    return id.isEmpty ? 'default' : id;
  }

  /// True for the scenarios that may learn. The severe paths (high impact, high-side) never do.
  static bool learns(CrashScenario s) => s == CrashScenario.lowsideSlide || s == CrashScenario.stationaryDrop;

  /// "I'm OK" on an alarm of [scenario]: one step up on that stage only (bounded).
  static CrashLearningState onFalseAlarm(CrashLearningState s, CrashScenario scenario) {
    if (!learns(scenario)) return s;
    final slide = scenario == CrashScenario.lowsideSlide ? math.min(capPct, s.slidePct + stepPct) : s.slidePct;
    final low = scenario == CrashScenario.stationaryDrop ? math.min(capPct, s.lowFallPct + stepPct) : s.lowFallPct;
    // The alarm-free hour starts again after a false alarm.
    return s.copyWith(slidePct: slide, lowFallPct: low, falseAlarms: s.falseAlarms + 1, rideMsSinceDecay: 0);
  }

  /// A real alarm (the SOS went out, by answer or no answer): forget what was learned for the
  /// stage that fired, so a real crash pattern is never filtered next time.
  static CrashLearningState onRealAlarm(CrashLearningState s, CrashScenario scenario) {
    if (!learns(scenario)) return s;
    return s.copyWith(
      slidePct: scenario == CrashScenario.lowsideSlide ? 0 : s.slidePct,
      lowFallPct: scenario == CrashScenario.stationaryDrop ? 0 : s.lowFallPct,
    );
  }

  /// [ms] of alarm-free riding: 2 points down per full hour on both stages (not below 0).
  static CrashLearningState onRideTime(CrashLearningState s, int ms) {
    if (ms <= 0 || (s.slidePct <= 0 && s.lowFallPct <= 0)) {
      return s.rideMsSinceDecay == 0 ? s : s.copyWith(rideMsSinceDecay: 0);
    }
    final every = decayEvery.inMilliseconds;
    final total = s.rideMsSinceDecay + ms;
    final steps = total ~/ every;
    final rest = total % every;
    if (steps == 0) return s.copyWith(rideMsSinceDecay: rest);
    final down = steps * decayPct;
    return s.copyWith(
      slidePct: math.max(0.0, s.slidePct - down),
      lowFallPct: math.max(0.0, s.lowFallPct - down),
      rideMsSinceDecay: rest,
    );
  }

  /// Settings line: "Learned from 3 false alarms on this bike" (null when nothing learned).
  static String? settingsLine(CrashLearningState s) {
    if (s.falseAlarms <= 0) return null;
    return 'Learned from ${s.falseAlarms} false ${s.falseAlarms == 1 ? 'alarm' : 'alarms'} on this bike';
  }

  /// Every bike's state from the stored map (bounded to [maxBikes] entries).
  static const int maxBikes = 10;

  static Map<String, CrashLearningState> decodeAll(Object? j) {
    if (j is! Map) return {};
    final out = <String, CrashLearningState>{};
    for (final e in j.entries) {
      if (out.length >= maxBikes) break;
      final k = e.key.toString();
      if (k.isEmpty || k.length > 80) continue;
      out[k] = CrashLearningState.fromJson(e.value);
    }
    return out;
  }

  static Map<String, Object> encodeAll(Map<String, CrashLearningState> all) => {
        for (final e in all.entries)
          if (!e.value.isEmpty) e.key: e.value.toJson(),
      };
}
