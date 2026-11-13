import 'package:flutter/foundation.dart';

import '../../core/ui/ride_alert.dart';
import '../../domain/intel/geohash.dart';
import '../../domain/road/road_ahead_engine.dart';
import '../../domain/road/speed_limit_resolver.dart';
import '../../domain/route/bend_advisor.dart';
import '../../domain/route/route_progress.dart';
import '../../domain/safety/altitude_care.dart';
import '../../domain/safety/night_care.dart';
import '../../domain/safety/speed_limit_advisor.dart';
import '../../domain/safety/warning_scheduler.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
import 'road_data_service.dart';
import 'sos_battery_reserve.dart';
import 'voice_service.dart';

/// What the cockpit shows for road context (one at a time; informational, dismissible).
class RoadCareNotice {
  const RoadCareNotice({required this.key, required this.title, required this.message, required this.rank, this.important = true});

  /// Stable per notice (the cockpit slot key).
  final String key;
  final String title;
  final String message;

  /// Higher replaces lower: bend 4, speed 3, altitude 2, night 1.
  final int rank;

  /// Important (amber) or normal tier.
  final bool important;
}

/// Road context on the phone (3.55; free on every plan, works without signal):
/// sharp-bend warning, smart speed limits, high-altitude care and night riding care.
///
/// Owned by SafetyService, which calls [onFix] with each of my fixes during a ride (never in an
/// offline solo ride) and [nightBreakDue] next to the fatigue tracker. All logic is in the pure
/// classes ([BendAdvisor], [SpeedLimitAdvisor], [AltitudeCare], [NightCare]); this class only
/// feeds them, gates them by the admin switches (bendWarning, speedLimits, altitudeCare,
/// nightCare) and speaks / shows their output. It never speaks or shows anything while an
/// emergency is open (my crash alarm, my SOS, or an open alert in the group).
class RoadCareService {
  RoadCareService({
    required this.voice,
    required this.emergency,
    required this.featureOn,
    required this.convoyLine,
    required this.onChanged,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final VoiceService? voice;

  /// An emergency is open (my crash alarm, my SOS, an open group alert): stay silent and hidden.
  final bool Function() emergency;
  final bool Function(String id) featureOn;
  final List<(double, double)>? Function() convoyLine;
  final VoidCallback onChanged;
  final int Function() _now;

  /// The line the rider follows (RouteGuide.active: a personal re-route or the group plan), set
  /// by the ride map while it is open. Null = the group route line from the convoy.
  RouteProgress? Function()? activeLine;

  /// Road limits and school / hospital zones from the cached places cells (set by the ride map
  /// from MapPlacesService.roadContext). Null = no speed limit data (nothing is warned).
  ({List<RoadLimitPoint> roads, List<SpeedZonePoint> zones}) Function()? roadData;

  // ---- round 7: curve and speed-limit prediction (docs/features_355/curve_and_speed_limit.md)
  /// Set by SafetyService (null in unit tests of the 3.55 behaviour: the 3.55 bend and limit
  /// advisors below then work exactly as before). When set, it takes over the bend warning and
  /// the road-limit warning; the school / hospital caps of [limits] stay.
  RoadAheadEngine? roadAhead;

  /// Road cells on the phone (prefetch + disk); null = no free-riding prediction.
  RoadDataService? roadCells;

  /// The rider's switches (Settings > Road safety). Null = defaults.
  RoadAheadPrefs Function()? roadPrefs;

  /// What the cockpit's limit sign and bend chip show. Changes only when something visible
  /// changed, so the chips repaint on their own without rebuilding the ride screen.
  final ValueNotifier<RoadAheadView> roadView = ValueNotifier<RoadAheadView>(RoadAheadView.empty);

  /// The one scheduler for every advisory voice warning of the ride (hazard, bend, speed limit,
  /// rough road, twisty, fatigue / night / altitude, falling behind): priorities, gaps, at most
  /// four a minute, never two at once, silent at once when an emergency opens.
  final WarningScheduler scheduler = WarningScheduler(rules: const {
    WarnKind.hazard: WarnRule(priority: 70, minGapMs: 8000, ttlMs: 6000),
    WarnKind.curve: WarnRule(priority: 60, minGapMs: 8000, ttlMs: 3000),
    WarnKind.speedLimit: WarnRule(priority: 50, minGapMs: 15000, ttlMs: 8000),
    WarnKind.fallingBehind: WarnRule(priority: 40, minGapMs: 20000, ttlMs: 20000),
    WarnKind.roughRoad: WarnRule(priority: 30, minGapMs: 20000, ttlMs: 6000),
    WarnKind.fatigue: WarnRule(priority: 20, minGapMs: 10000, ttlMs: 60000),
    WarnKind.twisty: WarnRule(priority: 10, minGapMs: 10000, ttlMs: 30000),
  });

  final BendAdvisor bends = BendAdvisor();
  final SpeedLimitAdvisor limits = SpeedLimitAdvisor();
  final AltitudeCare altitude = AltitudeCare();
  final NightCare night = NightCare();

  RoadCareNotice? _notice;
  int _noticeUntil = 0;
  bool _dark = false;
  double? _hintAlongM;
  TrackPoint? _headingFrom;
  double? _headingDeg;

  /// The road context card to show now (null = none). Expires by itself.
  RoadCareNotice? get notice {
    final n = _notice;
    if (n == null) return null;
    if (_now() >= _noticeUntil) {
      _notice = null;
      return null;
    }
    return n;
  }

  /// After sunset, with night care on (the cockpit raises alert card contrast).
  bool get isNight => _dark && featureOn('nightCare');

  /// The road limit context found at the last fix (for the ride report / tests).
  LimitContext? get limitHere => limits.last;

  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    onChanged();
  }

  void reset() {
    bends.reset();
    roadAhead?.reset();
    scheduler.reset();
    if (!roadView.value.isEmpty) roadView.value = RoadAheadView.empty;
    limits.reset();
    altitude.reset();
    night.reset();
    _notice = null;
    _hintAlongM = null;
    _headingFrom = null;
    _headingDeg = null;
    _setDark(false);
  }

  void _setDark(bool dark) {
    _dark = dark;
    RideAlert.nightContrast = isNight;
  }

  /// One of my fixes during a ride. [dark]: after sunset at the place; [otherLimitKmh] and
  /// [otherActive]: SafetyService's group / personal limit and whether it is warning now.
  void onFix(TrackPoint p, {required bool dark, int otherLimitKmh = 0, bool otherActive = false}) {
    if (p.lat == 0 && p.lng == 0) return;
    _trackHeading(p);
    _onNight(dark);
    _drainScheduler();
    if (p.accuracyM > 50) return; // too rough for bends and roads
    final engine = roadAhead;
    if (engine != null) {
      _onRoadAhead(engine, p, dark: dark, otherLimitKmh: otherLimitKmh, otherActive: otherActive);
    } else {
      _onBends(p);
    }
    _onLimits(p, otherLimitKmh: otherLimitKmh, otherActive: otherActive, zonesOnly: engine != null && engine.limit != null);
    _onAltitude(p);
  }

  /// Night riding care: true once per riding stretch at night after 90 min (the regular 2 h
  /// prompt stays). Shows and speaks the softer early break prompt itself.
  bool nightBreakDue({required int? stretchStartMs, required int nowMs}) {
    if (!featureOn('nightCare')) return false;
    if (!night.earlyBreakDue(stretchStartMs: stretchStartMs, nowMs: nowMs, dark: _dark)) return false;
    final mins = night.nightRideFor.inMinutes;
    _say('Night riding. You have been riding for $mins minutes. Time for a short break.', key: 'night_break');
    _show(RoadCareNotice(
      key: 'ROADCARE:NIGHT_BREAK:$stretchStartMs',
      title: 'Night riding: time for a short break',
      message: 'You have been riding for $mins minutes after sunset.',
      rank: 1,
    ), const Duration(minutes: 2));
    return true;
  }

  // ------------------------------------------------------------------ parts
  void _trackHeading(TrackPoint p) {
    final from = _headingFrom;
    if (from == null) {
      _headingFrom = p;
      return;
    }
    if (p.speedKmh < 5) return;
    final d = GeoMath.haversine(from.lat, from.lng, p.lat, p.lng);
    if (d >= 15) {
      _headingDeg = GeoMath.bearing(from.lat, from.lng, p.lat, p.lng);
      _headingFrom = p;
    }
  }

  void _onNight(bool dark) {
    final was = isNight;
    _setDark(dark);
    if (!featureOn('nightCare')) return;
    if (night.onDark(dark)) {
      _say(NightCare.sunsetSpeech, key: 'night_sunset');
      _show(const RoadCareNotice(
        key: 'ROADCARE:SUNSET',
        title: NightCare.sunsetTitle,
        message: NightCare.sunsetMessage,
        rank: 1,
        important: false,
      ), const Duration(seconds: 60));
    } else if (was != isNight) {
      onChanged(); // the cockpit redraws alert cards with night contrast
    }
  }

  void _onBends(TrackPoint p) {
    if (!featureOn('bendWarning')) return;
    final progress = activeLine?.call();
    final line = (progress != null && progress.isUsable) ? progress.points : convoyLine();
    bends.setLine(line);
    if (line == null || bends.bends.isEmpty) return;
    final hint = progress?.last?.alongM ?? _hintAlongM;
    final at = BendAdvisor.locate(p.lat, p.lng, line, hintAlongM: hint);
    if (at == null) return;
    _hintAlongM = at.onLine ? at.alongM : null;
    final w = bends.onFix(alongM: at.alongM, speedKmh: p.speedKmh, nowMs: p.ts, onLine: at.onLine);
    if (w == null) return;
    if (emergency()) return;
    if (_schedule(WarnKind.curve, 'bend_${w.bend.startAlongM.round()}', w.speech)) {
      voice?.speakHazard(w.speech, dedupeKey: 'bend_${w.bend.startAlongM.round()}');
    }
    final secs = (w.distanceM / (p.speedKmh / 3.6)).clamp(8, 30).round();
    _show(RoadCareNotice(key: 'ROADCARE:BEND:${w.bend.startAlongM.round()}', title: w.title, message: w.message, rank: 4),
        Duration(seconds: secs));
  }

  /// Round 7: bends ahead (route line, or the matched road in free riding) and the road's limit.
  void _onRoadAhead(RoadAheadEngine engine, TrackPoint p, {required bool dark, required int otherLimitKmh, required bool otherActive}) {
    final bendsOn = featureOn('bendWarning'), limitsOn = featureOn('speedLimits') && !SosBatteryReserve.isActive;
    if (!bendsOn && !limitsOn) {
      if (!roadView.value.isEmpty) roadView.value = RoadAheadView.empty;
      return;
    }
    final base = roadPrefs?.call() ?? const RoadAheadPrefs();
    final prefs = RoadAheadPrefs(
      curveWarnings: base.curveWarnings && bendsOn,
      limitDisplay: base.limitDisplay && limitsOn,
      // The group or personal limit, when as strict or already warning, speaks instead (one prompt).
      overspeedWarning: base.overspeedWarning && limitsOn,
      tolerancePct: base.tolerancePct,
      voice: base.voice,
      cautious: base.cautious,
    );
    roadCells?.onFix(p.lat, p.lng, headingDeg: _headingDeg);
    final progress = activeLine?.call();
    final line = (progress != null && progress.isUsable) ? progress.points : convoyLine();
    double? along;
    var onLine = false;
    if (line != null && line.length >= 3) {
      final at = BendAdvisor.locate(p.lat, p.lng, line, hintAlongM: progress?.last?.alongM ?? _hintAlongM);
      if (at != null) {
        onLine = at.onLine;
        along = at.alongM;
        _hintAlongM = at.onLine ? at.alongM : null;
      }
    }
    final out = engine.onFix(
      lat: p.lat,
      lng: p.lng,
      speedKmh: p.speedKmh,
      nowMs: p.ts,
      headingDeg: _headingDeg,
      dark: dark,
      routeLine: line,
      routeAlongM: along,
      onRoute: onLine,
      schoolHours: SpeedLimitAdvisor.schoolHours(DateTime.fromMillisecondsSinceEpoch(p.ts)),
      prefs: prefs,
    );
    final shown = out.view.limit, match = engine.lastMatch;
    if (shown != null && match != null) {
      final cell = Geohash.encode(p.lat, p.lng, 6);
      if (cell != null) {
        roadCells?.noteShown(way: match.way.id, cell: cell, kmh: shown.kmh, estimated: shown.estimated, source: shown.source.name, name: match.way.name);
      }
    }
    final em = emergency();
    final view = em ? RoadAheadView.empty : out.view;
    if (roadView.value != view) roadView.value = view;
    if (em) return;
    final w = out.curveWarning;
    if (w != null) {
      final key = 'bend_${w.curve.key}';
      if (_schedule(WarnKind.curve, key, w.speech)) voice?.speakHazard(w.speech, dedupeKey: key);
      final secs = (w.distanceM / (p.speedKmh / 3.6)).clamp(8, 30).round();
      _show(RoadCareNotice(key: 'ROADCARE:BEND:${w.curve.key}', title: w.title, message: w.message, rank: 4), Duration(seconds: secs));
    }
    final o = out.overspeed;
    final other = otherActive || (otherLimitKmh > 0 && engine.limit != null && otherLimitKmh <= engine.limit!.kmh);
    if (o.speak && !other) {
      _say(o.speech, key: 'road_limit_${engine.limit?.kmh}_${o.limitDropped ? 'drop' : o.level.name}');
      if (o.level != OverspeedLevel.none) {
        _show(RoadCareNotice(key: 'ROADCARE:LIMIT:road:${engine.limit?.kmh}', title: 'Speed ${o.title}', message: 'You are at ${p.speedKmh.round()} km/h.', rank: 3), const Duration(seconds: 12));
      }
    }
  }

  /// [zonesOnly]: the round 7 engine has the road's limit; only the school / hospital caps of
  /// the 3.55 advisor still warn here.
  void _onLimits(TrackPoint p, {required int otherLimitKmh, required bool otherActive, bool zonesOnly = false}) {
    final src = roadData;
    // Off in the SOS battery reserve (below 10% the phone keeps power for SOS).
    if (!featureOn('speedLimits') || src == null || SosBatteryReserve.isActive) return;
    final data = src();
    if (data.roads.isEmpty && data.zones.isEmpty) return; // never noisy without data
    final ctx = limits.limitAt(
      lat: p.lat,
      lng: p.lng,
      headingDeg: _headingDeg,
      roads: data.roads,
      zones: data.zones,
      localNow: DateTime.fromMillisecondsSinceEpoch(p.ts),
    );
    final w = limits.onSpeed(context: ctx, speedKmh: p.speedKmh, nowMs: p.ts, otherLimitKmh: otherLimitKmh, otherActive: otherActive);
    if (w == null || emergency()) return;
    if (zonesOnly && w.context.reason == LimitReason.road) return;
    _say(w.speech, key: 'road_limit_${w.context.key}');
    _show(RoadCareNotice(key: 'ROADCARE:LIMIT:${w.context.key}', title: w.title, message: w.message, rank: 3),
        const Duration(seconds: 20));
  }

  void _onAltitude(TrackPoint p) {
    if (!featureOn('altitudeCare')) return;
    final n = altitude.onFix(ts: p.ts, altM: p.altM);
    if (n == null || emergency()) return;
    _say(n.speech, key: 'altitude_${n.kind.name}');
    _show(RoadCareNotice(key: 'ROADCARE:ALT:${n.kind.name}:${p.ts ~/ 60000}', title: n.title, message: n.message, rank: 2),
        const Duration(seconds: 60));
  }

  // ------------------------------------------------------------------ round 4 road & safety intelligence
  /// IntelCareService shows its notices (hazard ahead, rough road, twisty section, long ride / night nudges) in
  /// this same cockpit slot (also on the lock-screen cockpit), with the same rules: never over an emergency, a
  /// more urgent road notice is not replaced. Returns false when it was not shown.
  bool showExternal(RoadCareNotice n, Duration forTime) {
    if (emergency()) return false;
    final cur = notice;
    if (cur != null && cur.rank > n.rank) return false;
    _show(n, forTime);
    return true;
  }

  /// Speaks [text] at warning priority unless an emergency is open.
  void sayExternal(String text, {required String key, bool hazard = false}) {
    if (emergency()) return;
    if (!_schedule(_kindOf(key, hazard: hazard), key, text, hazard: hazard)) return;
    if (hazard) {
      voice?.speakHazard(text, dedupeKey: key);
    } else {
      voice?.speak(text, priority: VoicePriority.warning, key: key);
    }
  }

  // ------------------------------------------------------------------ output
  void _say(String text, {required String key}) {
    if (emergency()) return;
    if (!_schedule(_kindOf(key), key, text)) return;
    voice?.speak(text, priority: VoicePriority.warning, key: key);
  }

  // ------------------------------------------------------------------ round 7: one warning scheduler
  static WarnKind _kindOf(String key, {bool hazard = false}) {
    final k = key.toUpperCase();
    if (k.startsWith('BEND')) return WarnKind.curve;
    if (k.startsWith('HAZARD') || (hazard && !k.startsWith('ROUGH'))) return WarnKind.hazard;
    if (k.startsWith('ROAD_LIMIT') || k.startsWith('LIMIT')) return WarnKind.speedLimit;
    if (k.startsWith('ROUGH')) return WarnKind.roughRoad;
    if (k.startsWith('TWISTY')) return WarnKind.twisty;
    if (k.startsWith('BEHIND') || k.startsWith('FALLING')) return WarnKind.fallingBehind;
    return WarnKind.fatigue; // breaks, night, altitude and other care notices
  }

  final Map<String, bool> _queuedHazard = <String, bool>{};

  /// True when [text] may be spoken now. A warning that has to wait is spoken by
  /// [_drainScheduler] (with the next fix) unless it expires; an emergency silences everything.
  bool _schedule(WarnKind kind, String key, String text, {bool hazard = false}) {
    final now = _now();
    scheduler.setEmergency(emergency(), now);
    final out = scheduler.submit(AdvisoryWarning(kind: kind, key: key, speech: text), now);
    if (out == WarnOutcome.queued) {
      if (_queuedHazard.length > 8) _queuedHazard.clear();
      _queuedHazard[key] = hazard || kind == WarnKind.curve || kind == WarnKind.hazard;
    }
    return out == WarnOutcome.speak || out == WarnOutcome.speakInterrupting;
  }

  /// Other services (falling behind in GroupSafetyService) ask before they speak an advisory.
  bool mayAdvise(WarnKind kind, String key, String text) => !emergency() && _schedule(kind, key, text);

  /// For GroupSafetyService.advisoryGate (falling behind).
  bool mayAdviseFallingBehind(String key, String text) => mayAdvise(WarnKind.fallingBehind, key, text);

  void _drainScheduler() {
    final now = _now();
    scheduler.setEmergency(emergency(), now);
    final w = scheduler.next(now);
    if (w == null) return;
    if (_queuedHazard.remove(w.key) ?? false) {
      voice?.speakHazard(w.speech, dedupeKey: w.key);
    } else {
      voice?.speak(w.speech, priority: VoicePriority.warning, key: w.key);
    }
  }

  void _show(RoadCareNotice n, Duration forTime) {
    if (emergency()) return;
    final cur = notice;
    if (cur != null && cur.rank > n.rank) return; // a more urgent road notice is showing
    _notice = n;
    _noticeUntil = _now() + forTime.inMilliseconds;
    onChanged();
  }
}
