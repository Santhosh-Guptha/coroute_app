// Ride safety report (3.55): a private summary of my own ride, kept on the phone only and never
// uploaded. Stored alongside the existing RideStats (key 'sf', backward compatible: older
// entries simply have no summary). Pure Dart.
import 'dart:math' as math;

import '../intel/intel_policies.dart';
import '../tracking/geo_math.dart';
import '../tracking/track_point.dart';

class RideSafetySummary {
  final int hardBrakes;
  final int overLimitMin;
  final double nightKm;
  final int breaks;

  /// Highest fatigue level of the ride (0-100) and how many break prompts were shown.
  final int fatiguePeak;
  final int fatiguePrompts;

  /// "Bike down?" checks that opened, road hazards felt (potholes, speed breakers, rough road).
  final int bikeDownChecks;
  final int roadHazards;

  /// Crash alarms that opened (any answer).
  final int crashAlarms;

  /// Phone mount found this ride ('mounted', 'pocket', 'loose', 'unknown'; '' when not known).
  final String mount;

  /// Minutes in the SOS battery reserve.
  final int sosReserveMin;

  /// Round 4: kilometres of twisty road in this ride (from my own fixes; TwistyMeter).
  final int twistyKm;

  const RideSafetySummary({
    this.hardBrakes = 0,
    this.overLimitMin = 0,
    this.nightKm = 0,
    this.breaks = 0,
    this.fatiguePeak = 0,
    this.fatiguePrompts = 0,
    this.bikeDownChecks = 0,
    this.roadHazards = 0,
    this.crashAlarms = 0,
    this.mount = '',
    this.sosReserveMin = 0,
    this.twistyKm = 0,
  });

  bool get isEmpty =>
      hardBrakes == 0 &&
      overLimitMin == 0 &&
      nightKm < 0.1 &&
      breaks == 0 &&
      fatiguePeak == 0 &&
      fatiguePrompts == 0 &&
      bikeDownChecks == 0 &&
      roadHazards == 0 &&
      crashAlarms == 0 &&
      sosReserveMin == 0 &&
      twistyKm == 0;

  Map<String, Object> toJson() => {
        if (hardBrakes > 0) 'hb': hardBrakes,
        if (overLimitMin > 0) 'ol': overLimitMin,
        if (nightKm >= 0.1) 'nk': double.parse(nightKm.toStringAsFixed(1)),
        if (breaks > 0) 'b': breaks,
        if (fatiguePeak > 0) 'fp': fatiguePeak,
        if (fatiguePrompts > 0) 'fn': fatiguePrompts,
        if (bikeDownChecks > 0) 'bd': bikeDownChecks,
        if (roadHazards > 0) 'rh': roadHazards,
        if (crashAlarms > 0) 'ca': crashAlarms,
        if (mount.isNotEmpty) 'm': mount,
        if (sosReserveMin > 0) 'sr': sosReserveMin,
        if (twistyKm > 0) 'tw': twistyKm,
      };

  static RideSafetySummary? fromJson(Object? j) {
    if (j is! Map) return null;
    int n(String k) {
      final v = j[k];
      return v is num && v.isFinite ? math.max(0, v.toInt()) : 0;
    }

    final nk = j['nk'];
    final m = j['m'];
    return RideSafetySummary(
      hardBrakes: n('hb'),
      overLimitMin: n('ol'),
      nightKm: nk is num && nk.isFinite ? math.max(0.0, nk.toDouble()) : 0,
      breaks: n('b'),
      fatiguePeak: math.min(100, n('fp')),
      fatiguePrompts: n('fn'),
      bikeDownChecks: n('bd'),
      roadHazards: n('rh'),
      crashAlarms: n('ca'),
      mount: m is String && m.length <= 16 ? m : '',
      sosReserveMin: n('sr'),
      twistyKm: n('tw'),
    );
  }

  /// The lines of the "Safety summary" card, in order (pure, for tests). Zero counts that say
  /// something good are kept short ("No hard brakes").
  List<(String label, String value)> lines() {
    String plural(int v, String one, String many) => v == 1 ? '1 $one' : '$v $many';
    return [
      ('Hard brakes', hardBrakes == 0 ? 'None' : '$hardBrakes'),
      ('Over the speed limit', overLimitMin == 0 ? 'Never' : plural(overLimitMin, 'minute', 'minutes')),
      ('Riding after dark', nightKm < 0.1 ? 'None' : '${nightKm.toStringAsFixed(nightKm >= 10 ? 0 : 1)} km'),
      ('Breaks', breaks == 0 ? 'None' : '$breaks'),
      if (fatiguePeak > 0) ('Highest tiredness', '$fatiguePeak of 100'),
      if (fatiguePrompts > 0) ('Break reminders', '$fatiguePrompts'),
      if (bikeDownChecks > 0) ('"Bike down?" checks', '$bikeDownChecks'),
      if (crashAlarms > 0) ('Crash alarms', '$crashAlarms'),
      ('Road hazards felt', roadHazards == 0 ? 'None' : '$roadHazards'),
      if (sosReserveMin > 0) ('Battery saver for SOS', plural(sosReserveMin, 'minute', 'minutes')),
      if (twistyKm > 0) ('Twisty roads', '$twistyKm km'),
    ];
  }
}

/// Counts one ride's safety summary from fixes and events. Pure, no timers.
class RideSafetyAccumulator {
  TrackPoint? _last;
  int _overMs = 0;
  double _nightM = 0;
  int fatiguePeak = 0;
  int fatiguePrompts = 0;
  int bikeDownChecks = 0;
  int roadHazards = 0;
  int crashAlarms = 0;
  int _reserveMs = 0;
  int? _reserveSince;
  String mount = '';

  /// Round 4: twisty kilometres of this ride ("This ride: 34 km of twisty roads").
  final TwistyMeter twisty = TwistyMeter();

  int get overLimitMin => _overMs ~/ 60000;
  double get nightKm => _nightM / 1000;

  /// A fix: [limitKmh] (0 = none) with [toleranceKmh], and whether it is dark now.
  void onFix(TrackPoint p, {int limitKmh = 0, double toleranceKmh = 0, bool dark = false}) {
    final last = _last;
    if (last != null && p.ts < last.ts) return;
    _last = p;
    twisty.onFix(p);
    if (last == null) return;
    final gap = p.ts - last.ts;
    if (gap <= 0 || gap > 30000) return; // a GPS gap: nothing is assumed
    if (limitKmh > 0 && p.speedKmh > limitKmh + toleranceKmh && last.speedKmh > limitKmh + toleranceKmh) _overMs += gap;
    if (dark && !(p.lat == 0 && p.lng == 0) && !(last.lat == 0 && last.lng == 0)) {
      final d = GeoMath.haversine(last.lat, last.lng, p.lat, p.lng);
      // A jump faster than 250 km/h is a bad fix, not riding.
      if (d <= gap / 1000 * 70) _nightM += d;
    }
  }

  void onFatigue(int level) => fatiguePeak = math.max(fatiguePeak, level.clamp(0, 100));

  void onReserve(bool active, int nowMs) {
    final since = _reserveSince;
    if (active && since == null) {
      _reserveSince = nowMs;
    } else if (!active && since != null) {
      _reserveMs += math.max(0, nowMs - since);
      _reserveSince = null;
    }
  }

  RideSafetySummary build({required int hardBrakes, required int breaks, int? nowMs}) {
    var reserve = _reserveMs;
    final since = _reserveSince;
    if (since != null && nowMs != null) reserve += math.max(0, nowMs - since);
    return RideSafetySummary(
      hardBrakes: hardBrakes,
      overLimitMin: overLimitMin,
      nightKm: nightKm,
      breaks: breaks,
      fatiguePeak: fatiguePeak,
      fatiguePrompts: fatiguePrompts,
      bikeDownChecks: bikeDownChecks,
      roadHazards: roadHazards,
      crashAlarms: crashAlarms,
      mount: mount,
      sosReserveMin: reserve ~/ 60000,
      twistyKm: twisty.twistyKm,
    );
  }

  void reset() {
    _last = null;
    _overMs = 0;
    _nightM = 0;
    fatiguePeak = 0;
    fatiguePrompts = 0;
    bikeDownChecks = 0;
    roadHazards = 0;
    crashAlarms = 0;
    _reserveMs = 0;
    _reserveSince = null;
    mount = '';
    twisty.reset();
  }
}
