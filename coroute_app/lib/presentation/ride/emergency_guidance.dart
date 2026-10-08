import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/constants/emergency_nav_constants.dart';
import '../../core/ui/ui_format.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/network_models.dart';
import '../../data/models/route_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/voice_service.dart';
import '../../domain/ride/ride_facts.dart';
import '../../domain/route/off_route_detector.dart';
import '../../domain/route/reroute_policy.dart';
import '../../domain/route/route_progress.dart';
import '../../domain/notify/relation.dart';
import '../../domain/route/threshold_announcer.dart';
import '../../domain/tracking/bearing.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
import 'route_guide.dart' show RouteFetcher;

/// What the in-app navigation leads to.
enum NavTargetKind {
  /// An open SOS or crash alert of my own group (ref = alertId).
  groupEmergency,

  /// An assistance request from another group (ref = incidentId).
  assist,
}

/// One navigation target. Two targets are the same when kind and ref match.
class NavTarget {
  final NavTargetKind kind;

  /// The alertId (group emergency) or the incidentId (assist).
  final String ref;

  /// Who or what, for the status line ("Rahul"); may be empty (external riders get no names).
  final String label;

  const NavTarget({required this.kind, required this.ref, this.label = ''});

  @override
  bool operator ==(Object other) => other is NavTarget && other.kind == kind && other.ref == ref;

  @override
  int get hashCode => Object.hash(kind, ref);
}

/// A reported accident as I approach it.
class HazardView {
  final HazardWarning hazard;

  /// Metres to it: along the group route when [alongRoute], else straight.
  final double distanceM;

  /// True when both I and the accident are on the group route.
  final bool alongRoute;

  /// Behind me now (never listed by [EmergencyGuidance.hazards]).
  final bool passed;

  const HazardView({required this.hazard, required this.distanceM, this.alongRoute = false, this.passed = false});

  /// "Accident reported 2.3 km ahead" (the map marker label).
  String get label => 'Accident reported ${Relation.distanceText(distanceM)} ahead';
}

/// Speaks text with the warning priority (tests pass their own).
typedef GuidanceSpeaker = void Function(String text, String key);

/// Navigation to an emergency inside the app, plus distance warnings for
/// accidents reported ahead (3.15 Rider Safety Network).
///
/// * [start] fetches a personal route from my position to the emergency
///   point through `/geo/route` ([RouteFetcher], limits of [ReroutePolicy]).
///   With no route it guides by straight distance and direction
///   ("Emergency 1.4 km north-east").
/// * It follows my own fixes ([ConvoyService.myFixes]) only while a target
///   or a hazard exists, so it works with the screen off and asks for no
///   extra GPS. No timers.
/// * A new route is asked for when the emergency point moved more than
///   [EmergencyNavConstants.retargetMoveM] or I left the route.
/// * Voice: 5 km, 2 km, 1 km, 500 m, 100 m, each once
///   ([ThresholdAnnouncer]); hazards 5 km, 2 km, 1 km, 500 m, each once,
///   silent once passed.
/// * The target closes (alert resolved, request closed): navigation stops.
class EmergencyGuidance extends ChangeNotifier {
  EmergencyGuidance(
    this._convoys,
    this._voice,
    this._settings, {
    required this.fetchRoute,
    int Function()? clock,
    GuidanceSpeaker? speak,
  })  : _clock = clock ?? _wallClock,
        _speakOverride = speak {
    _convoys.addListener(_onConvoys);
    _onConvoys();
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final ConvoyService _convoys;
  final VoiceService? _voice;
  final SettingsService? _settings;
  final int Function() _clock;
  final GuidanceSpeaker? _speakOverride;
  final RouteFetcher fetchRoute;

  final ReroutePolicy _policy = ReroutePolicy();
  final OffRouteDetector _off = OffRouteDetector();

  NavTarget? _target;
  (double, double)? _point;
  RouteProgress? _route;
  RouteModel? _routeModel;
  (double, double)? _routedTo;
  ThresholdAnnouncer _navAnnouncer = _newNavAnnouncer();
  double? _remainingM;
  Duration? _eta;
  String? _statusLine;
  bool _onRoute = false;
  int _gen = 0;

  StreamSubscription<TrackPoint>? _sub;
  (double, double)? _me;
  (double, double)? _headingFrom;
  double? _heading;

  final Map<String, _HazardState> _hz = {};
  RouteProgress? _groupRoute;
  Object? _groupRouteKey;
  String _sig = '';
  bool _disposed = false;

  static ThresholdAnnouncer _newNavAnnouncer() =>
      ThresholdAnnouncer(EmergencyNavConstants.navThresholdsM, hysteresisM: EmergencyNavConstants.thresholdHysteresisM);

  // ------------------------------------------------------------- getters

  NavTarget? get target => _target;
  (double, double)? get targetPoint => _point;

  /// My personal route to the emergency, or null (straight guidance).
  RouteProgress? get route => _route;

  /// Metres still to go (along the route when on it, else straight), or null before my first position.
  double? get remainingM => _remainingM;

  /// Riding time left, or null.
  Duration? get eta => _eta;

  /// "Emergency 2.3 km, about 4 min" / "Emergency 1.4 km north-east", or null.
  String? get statusLine => _statusLine;

  /// True while following a route (not the straight fallback).
  bool get onRoute => _onRoute;

  /// True while this phone listens to its own fixes (a target or a hazard exists).
  bool get listening => _sub != null;

  /// True when navigating to [kind] / [ref].
  bool isTarget(NavTargetKind kind, String ref) {
    final t = _target;
    return t != null && t.kind == kind && t.ref == ref;
  }

  /// The part of my route still to ride (for the red line on the map).
  List<(double, double)> get remainingLine {
    final r = _route;
    if (r == null || !r.isUsable) return const [];
    return r.matched == null ? r.points : r.remainingLine();
  }

  /// Accidents reported ahead, nearest first; passed ones are left out.
  List<HazardView> get hazards {
    final out = <HazardView>[];
    final me = _myPos();
    for (final h in _convoys.hazards) {
      final st = _hz[h.hazardId];
      if (st != null && st.passed) continue;
      double? d = st?.distanceM;
      var along = st?.along ?? false;
      if (d == null) {
        final ahead = h.aheadM;
        if (ahead != null && h.onRoute) {
          d = ahead;
          along = true;
        } else if (me != null) {
          d = GeoMath.haversine(me.$1, me.$2, h.lat, h.lng);
        } else if (ahead != null) {
          d = ahead;
        }
      }
      if (d == null || !d.isFinite) continue;
      out.add(HazardView(hazard: h, distanceM: d < 0 ? 0.0 : d, alongRoute: along));
    }
    out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return out;
  }

  // --------------------------------------------------------- spoken words

  /// "1 kilometer", "2 kilometers", "500 meters".
  static String spokenDistance(int m) {
    if (m >= 1000) {
      final km = m ~/ 1000;
      return km == 1 ? '1 kilometer' : '$km kilometers';
    }
    return '$m meters';
  }

  /// What is said at a navigation threshold.
  static String navSpeech(int m) =>
      m <= 100 ? 'You are approaching the emergency location.' : 'Emergency location ${spokenDistance(m)} away.';

  /// What is said at a hazard threshold.
  static String hazardSpeech(int m) => m <= 500
      ? 'Caution. Rider accident ${spokenDistance(m)} ahead. Slow down.'
      : 'Caution. Rider accident reported ${spokenDistance(m)} ahead.';

  // ------------------------------------------------------------- actions

  /// Starts guiding to [t]. False when the target is not open or has no position.
  Future<bool> start(NavTarget t) async {
    if (_disposed) return false;
    final found = _lookup(t);
    final p = found.point;
    if (!found.open || p == null) return false;
    _target = t;
    _point = p;
    _route = null;
    _routeModel = null;
    _routedTo = null;
    _onRoute = false;
    _off.reset();
    _policy.reset();
    _navAnnouncer = _newNavAnnouncer();
    _gen++;
    _syncSubscription();
    _recomputeNav(feedVoice: true);
    _publish(force: true);
    await _requestRoute();
    return true;
  }

  /// Stops guiding (the hazard warnings go on).
  void stop() {
    if (_target == null) return;
    _target = null;
    _point = null;
    _route = null;
    _routeModel = null;
    _routedTo = null;
    _remainingM = null;
    _eta = null;
    _statusLine = null;
    _onRoute = false;
    _gen++;
    _syncSubscription();
    _publish(force: true);
  }

  // ------------------------------------------------------------ internals

  ({bool open, (double, double)? point}) _lookup(NavTarget t) {
    switch (t.kind) {
      case NavTargetKind.groupEmergency:
        final c = _convoys.activeConvoy;
        if (c == null) return (open: false, point: null);
        for (final a in c.activeAlerts) {
          if (a.alertId != t.ref) continue;
          if (a.resolved) return (open: false, point: null);
          final r = c.riders[a.userId];
          final alertAt = a.lastUpdateAt ?? a.timestamp;
          if (r != null && (r.lat != 0 || r.lng != 0) && r.lastSeenEpochMs > alertAt) return (open: true, point: (r.lat, r.lng));
          if (a.lat != 0 || a.lng != 0) return (open: true, point: (a.lat, a.lng));
          if (r != null && (r.lat != 0 || r.lng != 0)) return (open: true, point: (r.lat, r.lng));
          return (open: true, point: null);
        }
        return (open: false, point: null);
      case NavTargetKind.assist:
        final active = _convoys.activeAssist;
        if (active != null && active.incidentId == t.ref) return (open: true, point: (active.lat, active.lng));
        for (final a in _convoys.assistRequests) {
          if (a.incidentId == t.ref) return (open: true, point: (a.lat, a.lng));
        }
        return (open: false, point: null);
    }
  }

  (double, double)? _myPos() {
    final me = _me;
    if (me != null) return me;
    final c = _convoys.activeConvoy;
    final uid = _convoys.myUserId;
    final r = (c == null || uid == null) ? null : c.riders[uid];
    if (r == null || (r.lat == 0 && r.lng == 0)) return null;
    return (r.lat, r.lng);
  }

  double? _myHeading() {
    final h = _heading;
    if (h != null) return h;
    final c = _convoys.activeConvoy;
    final uid = _convoys.myUserId;
    final r = (c == null || uid == null) ? null : c.riders[uid];
    if (r == null || r.speedKmh < 10) return null;
    return r.heading;
  }

  void _onConvoys() {
    if (_disposed) return;
    var changed = false;
    final t = _target;
    if (t != null) {
      final found = _lookup(t);
      if (!found.open) {
        stop();
      } else {
        final p = found.point;
        if (p != null && p != _point) {
          _point = p;
          changed = true;
          final to = _routedTo;
          if (to != null && GeoMath.haversine(to.$1, to.$2, p.$1, p.$2) > EmergencyNavConstants.retargetMoveM) {
            _requestRoute().ignore();
          }
          _recomputeNav(feedVoice: false);
        }
      }
    }
    final list = _convoys.hazards;
    final ids = {for (final h in list) h.hazardId};
    if (ids.length != _hz.length || !ids.every(_hz.containsKey)) {
      _hz.removeWhere((k, _) => !ids.contains(k));
      for (final id in ids) {
        _hz.putIfAbsent(id, _HazardState.new);
      }
      changed = true;
    }
    _syncSubscription();
    if (changed) _publish();
  }

  void _syncSubscription() {
    final need = _target != null || _hz.isNotEmpty;
    if (need && _sub == null) {
      _sub = _convoys.myFixes.listen(_onFix);
    } else if (!need && _sub != null) {
      _sub?.cancel();
      _sub = null;
      _me = null;
      _headingFrom = null;
      _heading = null;
    }
  }

  /// One of my own fixes (tests call it through the fake ConvoyService stream).
  void _onFix(TrackPoint p) {
    if (_disposed || (p.lat == 0 && p.lng == 0)) return;
    final here = (p.lat, p.lng);
    _me = here;
    final from = _headingFrom;
    if (from == null) {
      _headingFrom = here;
    } else if (GeoMath.haversine(from.$1, from.$2, here.$1, here.$2) >= EmergencyNavConstants.headingMinMoveM) {
      _heading = Bearing.degrees(from.$1, from.$2, here.$1, here.$2);
      _headingFrom = here;
    }
    final acc = p.accuracyM > 0 ? p.accuracyM : null;
    if (_target != null) {
      final route = _route;
      if (route != null && route.isUsable) {
        final m = route.update(p.lat, p.lng, acceptM: OffRouteDetector.limitFor(acc), accuracyM: acc);
        if (m != null) {
          _off.onFix(tsMs: p.ts, offM: m.offM, alongM: m.onLine ? m.alongM : null, accuracyM: acc, speedKmh: p.speedKmh);
        }
        if (_off.isOff) _requestRoute().ignore();
      } else {
        _requestRoute().ignore(); // retried under the policy (once a minute, back-off)
      }
      _recomputeNav(feedVoice: true);
    }
    if (_hz.isNotEmpty) _hazardFix(p, acc);
    _publish();
  }

  void _recomputeNav({required bool feedVoice}) {
    final t = _target;
    final to = _point;
    final me = _myPos();
    if (t == null || to == null || me == null) {
      _remainingM = null;
      _eta = null;
      _statusLine = null;
      _onRoute = false;
      return;
    }
    final straight = GeoMath.haversine(me.$1, me.$2, to.$1, to.$2);
    double remaining = straight;
    var onRoute = false;
    final route = _route;
    if (route != null && route.isUsable) {
      final m = route.matched;
      final left = route.remainingM;
      final last = route.last;
      if (m != null && left != null && last != null && last.onLine && !_off.isOff) {
        final end = route.points.last;
        remaining = left + GeoMath.haversine(end.$1, end.$2, to.$1, to.$2);
        onRoute = true;
      }
    }
    _onRoute = onRoute;
    _remainingM = remaining;
    final model = _routeModel;
    final eta = onRoute ? RideFacts.etaFor(remaining, model) : null;
    _eta = eta ??
        Duration(
          seconds: (remaining * EmergencyNavConstants.straightDetourFactor / (EmergencyNavConstants.straightSpeedKmh / 3.6)).round(),
        );
    final d = Relation.distanceText(remaining);
    if (onRoute) {
      _statusLine = 'Emergency $d, about ${formatDuration(Duration(minutes: math.max(1, (_eta!.inSeconds / 60).round())))}';
    } else {
      final deg = Bearing.degrees(me.$1, me.$2, to.$1, to.$2);
      _statusLine = 'Emergency $d ${Bearing.compassWord(deg)}';
    }
    if (!feedVoice) return;
    final hit = _navAnnouncer.onDistance(remaining);
    if (hit != null) _say(navSpeech(hit), 'NAV:${t.ref}:$hit');
  }

  Future<void> _requestRoute() async {
    final t = _target;
    final me = _myPos();
    final to = _point;
    if (_disposed || t == null || me == null || to == null) return;
    final now = _clock();
    if (!_policy.canRequest(nowMs: now, online: _convoys.isOnline, lowData: _settings?.lowData ?? false)) return;
    _policy.started(now);
    final gen = ++_gen;
    RouteModel? r;
    try {
      r = await fetchRoute([me, to]);
    } catch (_) {
      r = null;
    }
    if (_disposed) return;
    final route = r;
    final ok = route != null && !route.approximate && route.points.length >= 2;
    _policy.finished(ok: ok);
    if (gen != _gen || _target != t) return;
    if (route == null || !ok) {
      _recomputeNav(feedVoice: false);
      _publish();
      return;
    }
    final progress = RouteProgress(route.points);
    final here = _me ?? me;
    progress.update(here.$1, here.$2);
    _route = progress;
    _routeModel = route;
    _routedTo = to;
    _off.reset();
    _recomputeNav(feedVoice: false);
    _publish(force: true);
  }

  void _syncGroupRoute(ConvoyModel? c) {
    final Object? key = c == null ? null : (c.route?.polyline ?? c.routeBreadcrumbs);
    if (key == _groupRouteKey) return;
    _groupRouteKey = key;
    final line = c?.routeLine ?? const <(double, double)>[];
    _groupRoute = line.length >= 2 ? RouteProgress(line) : null;
    for (final st in _hz.values) {
      st.routeKey = null;
    }
  }

  void _hazardFix(TrackPoint p, double? acc) {
    final me = (p.lat, p.lng);
    _syncGroupRoute(_convoys.activeConvoy);
    final gr = _groupRoute;
    final mine = gr?.update(p.lat, p.lng, acceptM: EmergencyNavConstants.onRouteM, accuracyM: acc);
    final heading = _myHeading();
    for (final h in _convoys.hazards) {
      final st = _hz[h.hazardId];
      if (st == null || st.passed) continue;
      double? dist;
      var along = false;
      if (mine != null && mine.onLine && gr != null) {
        if (st.routeKey == null || !identical(st.routeKey, _groupRouteKey)) {
          st.routeKey = _groupRouteKey;
          final hm = gr.locateAhead(h.lat, h.lng, fromAlongM: math.max(0.0, mine.alongM - EmergencyNavConstants.hazardPassedM));
          st.alongM = (hm != null && hm.offM <= EmergencyNavConstants.onRouteM) ? hm.alongM : null;
        }
        final ha = st.alongM;
        if (ha != null) {
          dist = ha - mine.alongM;
          along = true;
          if (dist < -EmergencyNavConstants.hazardPassedM) {
            st.passed = true;
            continue;
          }
        }
      }
      var toward = true;
      if (!along) {
        final s = GeoMath.haversine(me.$1, me.$2, h.lat, h.lng);
        dist = s;
        final min = st.minStraight;
        final last = st.lastStraight;
        if (min == null || s < min) {
          st.minStraight = s;
          st.growing = 0;
        } else if (last != null && s > last) {
          st.growing++;
        } else if (last != null && s < last) {
          st.growing = 0;
        }
        st.lastStraight = s;
        if ((st.minStraight ?? s) < EmergencyNavConstants.hazardPassedNearM && st.growing >= EmergencyNavConstants.hazardPassedGrowingFixes) {
          st.passed = true;
          continue;
        }
        if (heading != null) {
          final bearing = Bearing.degrees(me.$1, me.$2, h.lat, h.lng);
          toward = _angleDiff(heading, bearing) <= EmergencyNavConstants.hazardHeadingDeg;
        }
      }
      final d = dist ?? 0.0;
      st.distanceM = d < 0 ? 0.0 : d;
      st.along = along;
      // Riding to this very emergency: the navigation lines speak, not the caution ones too.
      final navigatingHere = _target?.ref == h.hazardId;
      if ((along || toward) && !navigatingHere) {
        final hit = st.announcer.onDistance(st.distanceM!);
        if (hit != null) _say(hazardSpeech(hit), 'HAZ:${h.hazardId}:$hit');
      }
    }
  }

  static double _angleDiff(double a, double b) {
    final d = ((a - b) % 360 + 360) % 360;
    return d > 180 ? 360 - d : d;
  }

  void _say(String text, String key) {
    final s = _speakOverride;
    if (s != null) {
      s(text, key);
      return;
    }
    _voice?.speak(text, priority: VoicePriority.warning, key: key);
  }

  /// Notifies only when something visible changed (rounded distances, the status line).
  void _publish({bool force = false}) {
    if (_disposed) return;
    final b = StringBuffer()
      ..write(_target?.ref ?? '')
      ..write('|')
      ..write(_statusLine ?? '')
      ..write('|')
      ..write(_route == null ? 0 : identityHashCode(_route))
      ..write('|')
      ..write(_point?.toString() ?? '');
    for (final h in hazards) {
      b
        ..write('|')
        ..write(h.hazard.hazardId)
        ..write(':')
        ..write(formatDistanceRounded(h.distanceM));
    }
    final sig = b.toString();
    if (!force && sig == _sig) return;
    _sig = sig;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _convoys.removeListener(_onConvoys);
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}

class _HazardState {
  final ThresholdAnnouncer announcer =
      ThresholdAnnouncer(EmergencyNavConstants.hazardThresholdsM, hysteresisM: EmergencyNavConstants.thresholdHysteresisM);
  Object? routeKey;
  double? alongM;
  double? minStraight;
  double? lastStraight;
  int growing = 0;
  bool passed = false;
  double? distanceM;
  bool along = false;
}
