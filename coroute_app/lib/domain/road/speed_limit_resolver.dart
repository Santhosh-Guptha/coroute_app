import 'dart:math' as math;

import 'india_speed_limits.dart';
import 'road_cell.dart';

/// Where a limit came from, best first.
enum LimitSource {
  /// maxspeed:motorcycle on the road.
  osmMotorcycle,

  /// maxspeed on the road (a number).
  osm,

  /// Agreed by riders ("wrong limit" votes) for this road.
  corrected,

  /// maxspeed:type / source:maxspeed / zone:maxspeed ("IN:urban", "zone30").
  osmImplicit,

  /// The default table (road class + built-up or not).
  estimate,
}

class ResolvedLimit {
  const ResolvedLimit({required this.kmh, required this.source, required this.confidence, this.basis = '', this.wayId = 0, this.school = false, this.hospital = false});

  final int kmh;
  final LimitSource source;
  final LimitConfidence confidence;
  final String basis;
  final int wayId;

  /// A school / hospital is close to the road: warn earlier (no tolerance).
  final bool school, hospital;

  /// Shown as "~50 est." (not read from a sign or a tag for this road).
  bool get estimated => source == LimitSource.estimate || source == LimitSource.osmImplicit;
  bool get zone => school || hospital;

  /// The sign text: "50" or "~50".
  String get label => estimated ? '~$kmh' : '$kmh';

  ResolvedLimit withZone({required bool school, required bool hospital}) =>
      ResolvedLimit(kmh: kmh, source: source, confidence: confidence, basis: basis, wayId: wayId, school: school, hospital: hospital);
}

/// The limit of a road for a motorcycle (pure; round 7). Order:
///  1. maxspeed:motorcycle, then maxspeed (numbers; "mph" converted), never above the motorcycle
///     maximum of 80: a car limit of 100 on a highway reads 80;
///  2. a rider-agreed correction: replaces an estimate, or LOWERS a tagged limit (never raises it);
///  3. the implied type (maxspeed:type / source:maxspeed / zone:maxspeed);
///  4. the estimate table (road class, built-up or not, divided road).
/// Typical rider speeds are only a sanity check ([sanity]); they never set a limit.
class SpeedLimitResolver {
  SpeedLimitResolver._();

  /// km/h of a plain number ("50", "30 mph", "60;40" = the first); null otherwise.
  static int? numeric(String? raw) {
    if (raw == null) return null;
    final s = raw.split(';').first.trim().toLowerCase();
    final m = RegExp(r'^(\d{1,3}(?:\.\d+)?)\s*(km/h|kmh|kph|mph)?$').firstMatch(s);
    if (m == null) return null;
    final v = (double.parse(m.group(1)!) * (m.group(2) == 'mph' ? 1.609344 : 1)).round();
    return v >= 5 && v <= 140 ? v : null;
  }

  /// km/h implied by a type value ("IN:urban", "DE:zone30", "zone:30", "IN:zone:40"); null otherwise.
  static int? implicit(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().toLowerCase();
    final zone = RegExp(r'zone:?(\d{1,3})$').firstMatch(s);
    if (zone != null) {
      final v = int.parse(zone.group(1)!);
      return v >= 5 && v <= IndiaSpeedLimits.motorcycleMaxKmh ? v : null;
    }
    final colon = s.lastIndexOf(':');
    final kind = colon >= 0 ? s.substring(colon + 1) : s;
    return IndiaSpeedLimits.implicit[kind];
  }

  /// A divided road of 4 lanes or more, as far as the map can tell: one-way carriageway with 2
  /// or more lanes on a trunk / primary road.
  static bool looksDivided(RoadWay w) => w.oneway != 0 && w.lanes >= 2 && (w.highway == 'trunk' || w.highway == 'primary');

  static LimitEstimate estimate(RoadWay w, {required bool urban, String? stateCode}) {
    var h = w.highway;
    if (h.endsWith('_link')) h = h.substring(0, h.length - 5);
    final row = IndiaSpeedLimits.stateOverrides[stateCode]?[h] ?? IndiaSpeedLimits.table[h] ?? IndiaSpeedLimits.table['road']!;
    // Lit main roads are treated as built-up even where the cell looks empty.
    final builtUp = urban || (w.lit && h != 'motorway');
    var e = builtUp ? row.$1 : row.$2;
    if (!builtUp && looksDivided(w)) e = IndiaSpeedLimits.dividedRural;
    if (w.isLink) e = LimitEstimate(math.min(e.kmh, 40), LimitConfidence.low, 'Slip road: a careful guess');
    return e;
  }

  static ResolvedLimit resolve(RoadWay w, {required bool urban, int? correctionKmh, String? stateCode}) {
    const cap = IndiaSpeedLimits.motorcycleMaxKmh;
    final moto = numeric(w.maxspeedMotorcycle);
    final tag = numeric(w.maxspeed);
    final fix = correctionKmh != null && correctionKmh >= 5 && correctionKmh <= cap ? correctionKmh : null;
    if (moto != null || tag != null) {
      final v = math.min(moto ?? tag!, cap);
      if (fix != null && fix < v) {
        return ResolvedLimit(kmh: fix, source: LimitSource.corrected, confidence: LimitConfidence.medium, basis: 'Riders reported a lower limit than the map', wayId: w.id);
      }
      final capped = (moto ?? tag!) > cap;
      return ResolvedLimit(
        kmh: v,
        source: moto != null ? LimitSource.osmMotorcycle : LimitSource.osm,
        confidence: LimitConfidence.high,
        basis: capped ? 'Map limit ${moto ?? tag} is for cars: motorcycle maximum $cap' : 'Limit from the map (OpenStreetMap)',
        wayId: w.id,
      );
    }
    if (fix != null) {
      return ResolvedLimit(kmh: fix, source: LimitSource.corrected, confidence: LimitConfidence.medium, basis: 'Reported by riders', wayId: w.id);
    }
    final imp = implicit(w.maxspeedType) ?? implicit(w.maxspeed);
    if (imp != null) {
      // "Rural" on a divided 4-lane road: 80.
      final v = imp == IndiaSpeedLimits.motorcycleOtherRoadsKmh && !urban && looksDivided(w) ? cap : imp;
      return ResolvedLimit(kmh: v, source: LimitSource.osmImplicit, confidence: LimitConfidence.medium, basis: 'Default for this kind of road (map type ${w.maxspeedType ?? w.maxspeed})', wayId: w.id);
    }
    final e = estimate(w, urban: urban, stateCode: stateCode);
    return ResolvedLimit(kmh: e.kmh, source: LimitSource.estimate, confidence: e.confidence, basis: e.basis, wayId: w.id);
  }

  /// Sanity check of an ESTIMATE against the speed riders typically do there (road
  /// intelligence): when riders are much slower than the estimate, the estimate is probably too
  /// high for the road, so its confidence drops to low. The number itself never changes, and a
  /// typical speed is never used as a limit.
  static ResolvedLimit sanity(ResolvedLimit l, {double? typicalKmh}) {
    if (!l.estimated || typicalKmh == null || !typicalKmh.isFinite || typicalKmh <= 0) return l;
    if (typicalKmh < l.kmh * 0.6 && l.confidence != LimitConfidence.low) {
      return ResolvedLimit(kmh: l.kmh, source: l.source, confidence: LimitConfidence.low, basis: '${l.basis}; riders are usually much slower here', wayId: l.wayId, school: l.school, hospital: l.hospital);
    }
    return l;
  }
}

enum OverspeedLevel { none, over, strong }

/// What to do about the rider's speed right now.
class OverspeedDecision {
  const OverspeedDecision({required this.level, this.speak = false, this.speech = '', this.title = '', this.limitDropped = false});
  final OverspeedLevel level;

  /// Say [speech] now (once per stretch; afterwards the dial alone shows it).
  final bool speak;
  final String speech;
  final String title;

  /// The limit just went down while the rider was above the new one.
  final bool limitDropped;

  static const OverspeedDecision none = OverspeedDecision(level: OverspeedLevel.none);
}

/// Overspeed warning rule (pure; round 7):
///  * over = above the limit plus the tolerance ([tolerancePct], default 10%, never less than
///    5 km/h); strong = more than 20% over. Near a school / hospital the tolerance is 0;
///  * the rider must be over for [holdMs] (2 s);
///  * VOICE ONCE per stretch (the same limit, until the rider has been back under it for
///    [rearmMs]); after that the dial shows it without sound. Going from over to strong speaks
///    once more;
///  * an ESTIMATED limit never speaks (the dial turns amber only): a guess must not nag;
///  * a limit change is announced only when the new limit is lower and the rider is above it.
class OverspeedPolicy {
  OverspeedPolicy({this.holdMs = 2000, this.rearmMs = 20000});

  final int holdMs, rearmMs;

  static const int defaultTolerancePct = 10;
  static const List<int> toleranceChoices = [5, 10, 15, 20];

  int? _limit;
  int? _overSince, _underSince;
  bool _spokeOver = false, _spokeStrong = false;

  void reset() {
    _limit = null;
    _overSince = null;
    _underSince = null;
    _spokeOver = false;
    _spokeStrong = false;
  }

  static double thresholdKmh(int limitKmh, {int tolerancePct = defaultTolerancePct, bool zone = false}) =>
      zone ? limitKmh.toDouble() : limitKmh + math.max(5.0, limitKmh * tolerancePct.clamp(5, 30) / 100);

  static OverspeedLevel levelOf(double speedKmh, int limitKmh, {int tolerancePct = defaultTolerancePct, bool zone = false}) {
    if (limitKmh <= 0 || !speedKmh.isFinite) return OverspeedLevel.none;
    if (speedKmh <= thresholdKmh(limitKmh, tolerancePct: tolerancePct, zone: zone)) return OverspeedLevel.none;
    return speedKmh > limitKmh * 1.2 ? OverspeedLevel.strong : OverspeedLevel.over;
  }

  OverspeedDecision onSpeed({required ResolvedLimit? limit, required double speedKmh, required int nowMs, int tolerancePct = defaultTolerancePct, bool voice = true}) {
    if (limit == null) {
      reset();
      return OverspeedDecision.none;
    }
    final prev = _limit;
    var dropped = false;
    if (prev != limit.kmh) {
      dropped = prev != null && limit.kmh < prev && speedKmh > limit.kmh;
      _limit = limit.kmh;
      _overSince = null;
      _underSince = null;
      _spokeOver = false;
      _spokeStrong = false;
    }
    final level = levelOf(speedKmh, limit.kmh, tolerancePct: tolerancePct, zone: limit.zone);
    final canSpeak = voice && !limit.estimated;
    final where = limit.school ? 'School zone. ' : (limit.hospital ? 'Hospital zone. ' : '');
    if (level == OverspeedLevel.none) {
      _overSince = null;
      if (speedKmh <= limit.kmh) {
        final under = _underSince ??= nowMs;
        if (nowMs - under >= rearmMs) {
          _spokeOver = false;
          _spokeStrong = false;
        }
      }
      if (dropped && canSpeak) {
        // Above the new, lower limit but within the tolerance: one calm announcement.
        return OverspeedDecision(level: level, speak: true, limitDropped: true, speech: '${where}Speed limit now ${limit.kmh}.', title: 'Speed limit ${limit.kmh}');
      }
      return OverspeedDecision(level: level, limitDropped: dropped);
    }
    _underSince = null;
    final overSince = _overSince ??= nowMs;
    final title = '${limit.school ? 'School zone: ' : (limit.hospital ? 'Hospital zone: ' : '')}limit ${limit.label}';
    if (dropped && canSpeak && !_spokeOver) {
      _spokeOver = true;
      _spokeStrong = level == OverspeedLevel.strong;
      return OverspeedDecision(level: level, speak: true, limitDropped: true, speech: '${where}Speed limit now ${limit.kmh}. Please slow down.', title: title);
    }
    if (nowMs - overSince < holdMs) return OverspeedDecision(level: level, title: title, limitDropped: dropped);
    if (canSpeak && level == OverspeedLevel.strong && !_spokeStrong) {
      final first = !_spokeOver;
      _spokeOver = true;
      _spokeStrong = true;
      return OverspeedDecision(level: level, speak: true, speech: first ? '${where}Speed limit ${limit.kmh}. Slow down.' : 'Well over the limit of ${limit.kmh}. Slow down.', title: title);
    }
    if (canSpeak && !_spokeOver) {
      _spokeOver = true;
      return OverspeedDecision(level: level, speak: true, speech: '${where}Speed limit ${limit.kmh}. Please slow down.', title: title);
    }
    return OverspeedDecision(level: level, title: title);
  }
}
