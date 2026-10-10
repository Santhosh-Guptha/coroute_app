import 'package:flutter/foundation.dart';

import '../../core/constants/route_constants.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/route_model.dart';
import '../ride/ride_facts.dart';
import 'off_route_detector.dart';
import 'reroute_policy.dart';
import 'route_plan.dart';
import 'route_progress.dart';
import '../timeline/timeline_text.dart';

/// Asks the route service for a route through these points; null when it
/// is not available (offline, error, timeout). Never throws.
typedef RouteFetcher = Future<RouteModel?> Function(List<(double, double)> waypoints);

/// Follows my position along the route during a ride and, when I leave the
/// planned route, quietly fetches a personal route from where I am to the
/// destination through the stops I still have to ride to.
///
/// * Works only on the fixes it is given (the ride coordinator passes my own
///   location fixes as they arrive). No timers, no extra GPS, no polling:
///   with no new fix it does nothing.
/// * The personal route is mine only; the group plan stays as it is.
/// * Back on the planned route: the personal route is dropped.
/// * Requests follow [ReroutePolicy] (one per minute, one per 3 minutes with
///   data saver, back-off after failures, none while offline).
///
/// It notifies listeners only when the status line or the active route
/// changes; progress along the line is read by the ride screen when it
/// rebuilds for the same fix.
class RouteGuide extends ChangeNotifier {
  RouteGuide({required this.fetchRoute});

  final RouteFetcher fetchRoute;
  final ReroutePolicy policy = ReroutePolicy();
  final OffRouteDetector _detector = OffRouteDetector();
  final OffRouteDetector _rejoin = OffRouteDetector(initial: OffRouteState.offRoute);

  ConvoyModel? _convoy;
  String _uid = '';
  Object? _routeKey;
  Object? _crumbKey;
  RouteProgress? _plan;
  RouteModel? _planRoute;
  bool _everOnPlan = false;
  bool _arrived = false;

  RouteModel? _personal;
  RouteProgress? _personalProgress;

  int _generation = 0;
  bool _disposed = false;
  String? _status;
  int _statusUntilMs = 0;
  (double, double)? _lastFix;
  int _routeVersion = 0;

  /// Text for the quiet status line, or null.
  String? get statusLine => _status;

  /// True while a personal route replaces the group plan on my screen.
  bool get hasPersonalRoute => _personal != null;

  /// The group plan as I follow it.
  RouteProgress? get plan => _plan;

  /// The line I follow now: my personal route if any, else the group plan.
  RouteProgress? get active => _personalProgress ?? _plan;

  /// The route whose pace gives the ETA (personal or planned).
  RouteModel? get activeRoute => _personal ?? _planRoute;

  /// Changes whenever the active line is replaced (for caching map points).
  int get routeVersion => _routeVersion;

  /// True once I have been on the planned route; before that (riding to the
  /// start) nothing is purged and nobody is rerouted.
  bool get started => _everOnPlan;

  /// True when this screen tells the route state itself (so the generic
  /// "You are off the planned route" alert would only repeat it).
  bool get handlesOffRoute => _everOnPlan && _canReroute;

  /// Metres left along the active line, from the last matched point.
  double? get remainingM => _everOnPlan ? active?.remainingM : null;

  /// Riding time left at the active route's pace.
  Duration? get eta => RideFacts.etaFor(remainingM, activeRoute);

  bool get _canReroute {
    final c = _convoy;
    final r = _planRoute;
    if (c == null || r == null || r.approximate) return false;
    if (c.tripStatus != 'STARTED') return false;
    // Arrived (the gateway saw me at the destination): nothing left to reroute to.
    if (c.destinationArrivals[_uid]?.reached ?? false) return false;
    return c.destinationLat != 0 || c.destinationLng != 0;
  }

  /// The latest convoy. A new group plan (route or stops changed) drops my
  /// personal route: it may skip a stop the lead just added. If I am still
  /// off the new plan, the next fixes fetch a fresh personal route.
  void setConvoy(ConvoyModel convoy, String myUserId) {
    if (_disposed) return;
    _convoy = convoy;
    _uid = myUserId;
    // Compared by content: a reconnect brings the same route as a new object.
    final route = convoy.route;
    final key = route?.polyline;
    final crumbs = route == null ? convoy.routeBreadcrumbs : null;
    if (key == _routeKey && identical(crumbs, _crumbKey)) {
      _routeKey = key; // keep the newest string, so the next check is an identity check
      _planRoute = route;
      return;
    }
    _routeKey = key;
    _crumbKey = crumbs;
    final line = convoy.routeLine;
    _plan = line.length >= 2 ? RouteProgress(line) : null;
    _planRoute = route;
    final hadPersonal = _personal != null;
    _arrived = false;
    _clearPersonal();
    _detector.reset();
    _rejoin.reset(OffRouteState.offRoute);
    _lastFix = null;
    if (hadPersonal || _status != null) {
      _status = null;
      _statusUntilMs = 0;
      _notify();
    }
  }

  void _clearPersonal() {
    _personal = null;
    _personalProgress = null;
    _generation++;
    _routeVersion++;
  }

  /// One location fix of mine. Cheap: a windowed match on one or two lines.
  void onFix({
    required double lat,
    required double lng,
    required double speedKmh,
    double? accuracyM,
    required int nowMs,
    required bool online,
    required bool lowData,
  }) {
    if (_disposed) return;
    final plan = _plan;
    if (plan == null || (lat == 0 && lng == 0)) return;
    final fix = (lat, lng);
    if (fix == _lastFix) return;
    _lastFix = fix;
    var changed = false;
    if (_statusUntilMs > 0 && nowMs >= _statusUntilMs) {
      _status = null;
      _statusUntilMs = 0;
      changed = true;
    }

    final limit = OffRouteDetector.limitFor(accuracyM);
    final onPlan = plan.update(lat, lng, acceptM: limit, accuracyM: accuracyM);
    if (onPlan != null && onPlan.onLine && !_everOnPlan) {
      _everOnPlan = true;
      changed = true;
    }
    if (!_everOnPlan || !_canReroute) {
      if (changed) _notify();
      return;
    }

    // Near the end of the route: I have arrived. Riding around the
    // destination town (to a hotel, a fuel pump) never asks for a new route.
    if (!_arrived && _nearEnd(plan)) {
      _arrived = true;
      _generation++; // a route still on its way is no longer needed
      _detector.reset();
      if (_personal == null && _status != null && _statusUntilMs == 0) {
        _status = null;
        changed = true;
      }
    }
    if (_arrived) {
      // Keep the purge of the personal route going; nothing else to do.
      _personalProgress?.update(lat, lng, acceptM: limit, accuracyM: accuracyM);
      if (changed) _notify();
      return;
    }

    final personal = _personalProgress;
    if (personal != null) {
      if (onPlan != null) {
        _rejoin.onFix(
          tsMs: nowMs,
          offM: onPlan.offM,
          alongM: onPlan.onLine ? onPlan.alongM : null,
          accuracyM: accuracyM,
          speedKmh: speedKmh,
        );
        if (!_rejoin.isOff) {
          _clearPersonal();
          _detector.reset();
          _rejoin.reset(OffRouteState.offRoute);
          _setStatus('Back on the planned route', untilMs: nowMs + RouteConstants.backOnRouteNoticeFor.inMilliseconds, force: true);
          return;
        }
      }
      final m = personal.update(lat, lng, acceptM: limit, accuracyM: accuracyM);
      if (m != null) {
        _detector.onFix(tsMs: nowMs, offM: m.offM, alongM: m.onLine ? m.alongM : null, accuracyM: accuracyM, speedKmh: speedKmh);
      }
    } else if (onPlan != null) {
      final wasOff = _detector.isOff;
      _detector.onFix(tsMs: nowMs, offM: onPlan.offM, alongM: onPlan.onLine ? onPlan.alongM : null, accuracyM: accuracyM, speedKmh: speedKmh);
      if (wasOff && !_detector.isOff) {
        _generation++; // a request still on its way is no longer needed
        _setStatus('Back on the planned route', untilMs: nowMs + RouteConstants.backOnRouteNoticeFor.inMilliseconds);
        return;
      }
    }

    if (_detector.isOff) _reroute(lat, lng, nowMs: nowMs, online: online, lowData: lowData);
    if (changed) _notify();
  }

  /// True when the last matched point of the plan (or of my personal route)
  /// is within [RouteConstants.nearDestinationM] of its end.
  bool _nearEnd(RouteProgress plan) {
    bool near(RouteProgress? p) {
      final left = p?.remainingM;
      return left != null && left <= RouteConstants.nearDestinationM;
    }

    return near(plan) || near(_personalProgress);
  }

  void _reroute(double lat, double lng, {required int nowMs, required bool online, required bool lowData}) {
    final convoy = _convoy;
    if (convoy == null) return;
    if (!policy.canRequest(nowMs: nowMs, online: online, lowData: lowData)) {
      if (!policy.inFlight && _personal == null) _setStatus('Off the planned route');
      return;
    }
    final waypoints = RoutePlan.rerouteWaypoints(convoy, _uid, lat, lng, plan: _plan, myAlongM: _plan?.matched?.alongM);
    if (waypoints.length < 2) return;
    policy.started(nowMs);
    final gen = _generation;
    if (_personal == null) _setStatus('Off the planned route, finding a new route');
    _fetch(waypoints, gen).ignore();
  }

  Future<void> _fetch(List<(double, double)> waypoints, int gen) async {
    RouteModel? r;
    try {
      r = await fetchRoute(waypoints);
    } catch (_) {
      r = null;
    }
    if (_disposed) return;
    final route = r;
    final ok = route != null && !route.approximate && route.points.length >= 2;
    RouteProgress? progress;
    RouteMatch? here;
    if (route != null && ok) {
      progress = RouteProgress(route.points);
      final last = _lastFix;
      if (last != null) here = progress.update(last.$1, last.$2);
    }
    // A route that does not start where I am (my road or track is not on
    // the map) backs off like a failure, so it is not asked for every minute.
    policy.finished(ok: ok && (here == null || here.onLine));
    if (gen != _generation || !_detector.isOff || _arrived) return;
    if (route == null || progress == null) {
      if (_personal == null) _setStatus('Off the planned route');
      return;
    }
    _personal = route;
    _personalProgress = progress;
    _routeVersion++;
    _detector.reset();
    _rejoin.reset(OffRouteState.offRoute);
    _setStatus('New route, ${TimelineText.distance(route.distanceM)}', force: true);
  }

  /// Sets the status line; notifies only when something visible changed.
  void _setStatus(String? text, {int untilMs = 0, bool force = false}) {
    final same = text == _status && untilMs == _statusUntilMs;
    _status = text;
    _statusUntilMs = untilMs;
    if (!same || force) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
