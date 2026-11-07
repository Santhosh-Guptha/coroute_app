import 'package:flutter/foundation.dart';

import '../../core/ui/ride_alert.dart';
import '../../domain/route/bend_advisor.dart';
import '../../domain/route/route_progress.dart';
import '../../domain/safety/altitude_care.dart';
import '../../domain/safety/night_care.dart';
import '../../domain/safety/speed_limit_advisor.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
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
    if (p.accuracyM > 50) return; // too rough for bends and roads
    _onBends(p);
    _onLimits(p, otherLimitKmh: otherLimitKmh, otherActive: otherActive);
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
    voice?.speakHazard(w.speech, dedupeKey: 'bend_${w.bend.startAlongM.round()}');
    final secs = (w.distanceM / (p.speedKmh / 3.6)).clamp(8, 30).round();
    _show(RoadCareNotice(key: 'ROADCARE:BEND:${w.bend.startAlongM.round()}', title: w.title, message: w.message, rank: 4),
        Duration(seconds: secs));
  }

  void _onLimits(TrackPoint p, {required int otherLimitKmh, required bool otherActive}) {
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

  // ------------------------------------------------------------------ output
  void _say(String text, {required String key}) {
    if (emergency()) return;
    voice?.speak(text, priority: VoicePriority.warning, key: key);
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
