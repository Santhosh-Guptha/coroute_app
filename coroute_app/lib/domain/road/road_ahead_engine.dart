import 'curve_predictor.dart';
import 'road_matcher.dart';
import 'speed_limit_resolver.dart';

/// The rider's choices (Settings > Road safety).
class RoadAheadPrefs {
  const RoadAheadPrefs({this.curveWarnings = true, this.limitDisplay = true, this.overspeedWarning = true, this.tolerancePct = OverspeedPolicy.defaultTolerancePct, this.voice = true, this.cautious = false});
  final bool curveWarnings, limitDisplay, overspeedWarning;
  final int tolerancePct;

  /// Voice warnings are on (off = chips only).
  final bool voice;
  final bool cautious;
}

/// What the cockpit shows (the limit sign and the bend chip). Immutable: a new value only when
/// something visible changed, so the chips repaint only then.
class RoadAheadView {
  const RoadAheadView({this.limit, this.level = OverspeedLevel.none, this.curve, this.curveAdvisoryKmh = 0, this.curveDistanceM = 0});

  final ResolvedLimit? limit;
  final OverspeedLevel level;

  /// The bend that was warned and is still ahead (null: no chip).
  final RoadCurve? curve;
  final int curveAdvisoryKmh;

  /// Rounded to 10 m (the chip does not repaint for every metre).
  final int curveDistanceM;

  static const RoadAheadView empty = RoadAheadView();

  bool get isEmpty => limit == null && curve == null;

  @override
  bool operator ==(Object other) =>
      other is RoadAheadView &&
      other.limit?.kmh == limit?.kmh &&
      other.limit?.source == limit?.source &&
      other.limit?.zone == limit?.zone &&
      other.level == level &&
      other.curve?.key == curve?.key &&
      other.curveAdvisoryKmh == curveAdvisoryKmh &&
      other.curveDistanceM == curveDistanceM;

  @override
  int get hashCode => Object.hash(limit?.kmh, limit?.source, limit?.zone, level, curve?.key, curveAdvisoryKmh, curveDistanceM);
}

class RoadAheadOutput {
  const RoadAheadOutput({required this.view, this.curveWarning, this.overspeed = OverspeedDecision.none, this.matched = false});
  final RoadAheadView view;

  /// A bend to announce now (voice + chip).
  final CurveWarning? curveWarning;
  final OverspeedDecision overspeed;

  /// The rider is matched to a road of the road cells (the limit comes from there).
  final bool matched;
}

/// Curve and speed-limit prediction for one rider (pure; round 7). Fed with each fix.
///
///  * On a planned route ([routeLine] + [routeAlongM], rider on the line): bends come from the
///    route line (analysed once per line). Junction corners are left to the navigation voice.
///  * Free riding, or off the route: the rider is matched to a road of the loaded road cells and
///    the bends come from that road and its most likely continuation ([RoadMatcher.ahead]).
///    No cells, no match, no heading: silent.
///  * The limit always comes from the matched road ([SpeedLimitResolver]); it also caps the
///    advisory speed of a bend.
class RoadAheadEngine {
  RoadAheadEngine({RoadMatcher? matcher}) : matcher = matcher ?? RoadMatcher();

  final RoadMatcher matcher;
  final CurveWarner warner = CurveWarner();
  final OverspeedPolicy overspeed = OverspeedPolicy();

  /// Free riding looks this far ahead (the longest warning distance is 400 m).
  static const double lookAheadM = 700;
  static const double minFreeSpeedKmh = 15;

  Object? _lineKey;
  int _lineLen = -1;
  List<RoadCurve> _routeCurves = const [];
  List<(double, double)> _spots = const [];

  RoadCurve? _chip;
  int _chipAdvisory = 0;
  double _chipDistance = 0;
  int _chipSetMs = 0;

  ResolvedLimit? _limit;
  RoadMatch? lastMatch;

  ResolvedLimit? get limit => _limit;
  List<RoadCurve> get routeCurves => _routeCurves;

  void reset() {
    warner.reset();
    overspeed.reset();
    _lineKey = null;
    _lineLen = -1;
    _routeCurves = const [];
    _chip = null;
    _limit = null;
    lastMatch = null;
  }

  /// Places where riders brake hard (hazard cells of kind hard_brake / skid): bends there are
  /// raised one class. A new list re-analyses the route line.
  void setHardBrakeSpots(List<(double, double)> spots) {
    if (spots.length == _spots.length) return;
    _spots = spots;
    _lineKey = null;
  }

  RoadAheadOutput onFix({
    required double lat,
    required double lng,
    required double speedKmh,
    required int nowMs,
    double? headingDeg,
    bool dark = false,
    bool rain = false,
    List<(double, double)>? routeLine,
    double? routeAlongM,
    bool onRoute = false,
    bool schoolHours = true,
    RoadAheadPrefs prefs = const RoadAheadPrefs(),
  }) {
    final cond = CurveConditions(dark: dark, rain: rain, cautious: prefs.cautious);
    // ---- the road under me (limit, free-riding geometry)
    final m = matcher.wayCount == 0 && matcher.cellCount == 0 ? null : matcher.match(lat, lng, headingDeg: headingDeg, speedKmh: speedKmh);
    lastMatch = m;
    ResolvedLimit? limit;
    if (m != null) {
      limit = SpeedLimitResolver.resolve(m.way, urban: m.urban, correctionKmh: matcher.correctionFor(m.way.id));
      if (!limit.estimated) {
        // A school / hospital next to a road with a known limit: warn earlier (no tolerance).
        final z = matcher.zonesNear(lat, lng);
        final school = z.$1 && schoolHours, hospital = z.$2;
        if (school || hospital) limit = limit.withZone(school: school, hospital: hospital);
      }
    }
    _limit = limit;

    // ---- bends ahead
    CurveWarning? warning;
    List<RoadCurve> curves = const [];
    var along = 0.0;
    var junctions = false;
    final useRoute = onRoute && routeLine != null && routeLine.length >= 3 && routeAlongM != null && routeAlongM.isFinite;
    if (useRoute) {
      if (!identical(routeLine, _lineKey) || routeLine.length != _lineLen) {
        _lineKey = routeLine;
        _lineLen = routeLine.length;
        _routeCurves = CurveAnalyzer.analyze(routeLine, hardBrakeSpots: _spots);
      }
      curves = _routeCurves;
      along = routeAlongM;
    } else if (m != null && headingDeg != null && speedKmh >= minFreeSpeedKmh) {
      final a = matcher.ahead(m, maxM: lookAheadM);
      curves = CurveAnalyzer.analyze(a.line, hardBrakeSpots: _spots);
      junctions = true;
    }
    if (prefs.curveWarnings) {
      warning = warner.onFix(curves: curves, alongM: along, speedKmh: speedKmh, nowMs: nowMs, conditions: cond, limitKmh: limit?.kmh, includeJunctions: junctions);
    }
    if (warning != null) {
      _chip = warning.curve;
      _chipAdvisory = warning.advisoryKmh;
      _chipSetMs = nowMs;
    }
    // The chip stays until the bend is behind me (found again on the current line by its key),
    // at most 40 s.
    final chip = _chip;
    if (chip != null) {
      RoadCurve? now;
      for (final c in curves) {
        if (c.key == chip.key) {
          now = c;
          break;
        }
      }
      if (!prefs.curveWarnings || nowMs - _chipSetMs > 40000 || (now == null && nowMs - _chipSetMs > 4000) || (now != null && now.apexM < along)) {
        _chip = null;
      } else if (now != null) {
        _chipDistance = (now.startM - along).clamp(0, 2000).toDouble();
      }
    }

    // ---- overspeed
    final decision = prefs.overspeedWarning && prefs.limitDisplay
        ? overspeed.onSpeed(limit: limit, speedKmh: speedKmh, nowMs: nowMs, tolerancePct: prefs.tolerancePct, voice: prefs.voice)
        : OverspeedDecision.none;
    if (!(prefs.overspeedWarning && prefs.limitDisplay)) overspeed.reset();

    final view = RoadAheadView(
      limit: prefs.limitDisplay ? limit : null,
      level: decision.level,
      curve: _chip,
      curveAdvisoryKmh: _chip == null ? 0 : _chipAdvisory,
      curveDistanceM: _chip == null ? 0 : (_chipDistance / 10).round() * 10,
    );
    return RoadAheadOutput(view: view, curveWarning: warning, overspeed: decision, matched: m != null);
  }
}
