import '../tracking/geo_math.dart';
import 'group_safety_rider.dart';

/// The group's spread along the route: front-most and last fresh riders (pure).
class GroupSpread {
  final double spreadM;
  final String frontId;
  final String lastId;
  final double frontAlongM;
  final double lastAlongM;

  /// Along-route position of every fresh rider on the route (userId -> m).
  final Map<String, double> alongM;

  const GroupSpread({
    required this.spreadM,
    required this.frontId,
    required this.lastId,
    required this.frontAlongM,
    required this.lastAlongM,
    required this.alongM,
  });

  /// Riders farther than this from the route are left out (same as [Relation.onRouteM]).
  static const double onRouteM = 300;

  /// Null with fewer than two fresh riders on the route, or no route.
  static GroupSpread? compute(List<GroupSafetyRider> riders, List<(double, double)> route, int nowMs) {
    if (route.length < 2) return null;
    final along = <String, double>{};
    for (final r in riders) {
      if (!r.isFresh(nowMs)) continue;
      final a = GeoMath.alongRoute(r.lat, r.lng, route);
      if (a == null || a.offRoute > onRouteM) continue;
      along[r.userId] = a.along;
    }
    if (along.length < 2) return null;
    var front = along.entries.first, last = along.entries.first;
    for (final e in along.entries) {
      if (e.value > front.value) front = e;
      if (e.value < last.value) last = e;
    }
    return GroupSpread(
      spreadM: front.value - last.value,
      frontId: front.key,
      lastId: last.key,
      frontAlongM: front.value,
      lastAlongM: last.value,
      alongM: Map.unmodifiable(along),
    );
  }
}

enum StretchEvent { none, alert, repeat, clear }

/// 3.55 group stretch alert on the lead's phone (pure): spread over [thresholdM] for [holdFor]
/// → [StretchEvent.alert]; still over it → [StretchEvent.repeat] at most every [repeatEvery];
/// back under [clearRatio] of the threshold → [StretchEvent.clear]. Unknown spread (no route, one
/// rider) holds the state as it is (never clears or alerts on missing data).
class StretchMonitor {
  StretchMonitor({
    this.holdFor = const Duration(seconds: 30),
    this.repeatEvery = const Duration(minutes: 5),
    this.clearRatio = 0.8,
  });

  final Duration holdFor;
  final Duration repeatEvery;
  final double clearRatio;

  int? _overSince;
  int? _lastAlertAt;
  bool _alerting = false;
  double? _lastSpreadM;

  bool get alerting => _alerting;
  double? get lastSpreadM => _lastSpreadM;

  void reset() {
    _overSince = null;
    _lastAlertAt = null;
    _alerting = false;
    _lastSpreadM = null;
  }

  StretchEvent update({required int nowMs, required double? spreadM, required double thresholdM}) {
    if (spreadM == null || !spreadM.isFinite || thresholdM <= 0) return StretchEvent.none;
    _lastSpreadM = spreadM;
    if (spreadM > thresholdM) {
      _overSince ??= nowMs;
      if (nowMs - _overSince! < holdFor.inMilliseconds) return StretchEvent.none;
      if (!_alerting) {
        _alerting = true;
        _lastAlertAt = nowMs;
        return StretchEvent.alert;
      }
      if (nowMs - (_lastAlertAt ?? nowMs) >= repeatEvery.inMilliseconds) {
        _lastAlertAt = nowMs;
        return StretchEvent.repeat;
      }
      return StretchEvent.none;
    }
    // Between the clear line and the threshold: the hold restarts, an open alert stays.
    _overSince = null;
    if (_alerting && spreadM < thresholdM * clearRatio) {
      _alerting = false;
      return StretchEvent.clear;
    }
    return StretchEvent.none;
  }

  /// "Group spread 4 km, slow down" (km to one decimal below 10 km).
  static String title(double spreadM) => 'Group spread ${_km(spreadM)} km, slow down';

  static String spoken(double spreadM) => 'Group spread ${_km(spreadM)} kilometers, slow down';

  static String _km(double m) {
    final km = m / 1000;
    if (km >= 10) return '${km.round()}';
    final s = km.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }
}
