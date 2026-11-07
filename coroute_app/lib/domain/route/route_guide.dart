import 'package:flutter/foundation.dart';

import '../../core/constants/route_constants.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/route_model.dart';
import '../../data/models/stop_point_model.dart';
import '../navigation/heading_tracker.dart';
import '../navigation/nav_prompts.dart';
import '../navigation/off_route_monitor.dart';
import '../navigation/reroute_controller.dart';
import '../navigation/reroute_rules.dart';
import '../ride/ride_facts.dart';
import 'off_route_detector.dart';
import 'route_plan.dart';
import 'route_progress.dart';
import '../timeline/timeline_text.dart';
import '../tracking/dead_reckoning_engine.dart';
import '../tracking/geo_math.dart';

/// Asks the route service for a route through these points; null when it
/// is not available (offline, error, timeout). Never throws.
typedef RouteFetcher = Future<RouteModel?> Function(List<(double, double)> waypoints);

/// Like [RouteFetcher], with my direction of travel at the first point
/// (degrees, null when unknown), so the new route does not start with a U-turn.
typedef HeadedRouteFetcher = Future<RouteModel?> Function(List<(double, double)> waypoints, double? startHeadingDeg);

/// Says one navigation line (the voice applies mute and language).
typedef NavPromptSink = void Function(NavPrompt prompt);

/// Reverse geocodes a coordinate (lat, lng) to a place or road name.
typedef ReverseGeocoder = Future<String?> Function(double lat, double lng);

/// Follows my position along the route during a ride and, when I leave the
/// route I follow, fetches a personal route from where I am (in my
/// direction of travel) through the stops I still have to ride to, to the
/// destination.
///
/// * Works only on the fixes it is given (the ride coordinator passes my own
///   location fixes as they arrive). No timers, no extra GPS, no polling:
///   with no new fix it does nothing.
/// * Leaving the route, the requests and the spoken lines follow
///   [RerouteController] ([RerouteRules]): off after 8 s beyond 40 m heading
///   away (or 120 m at once), back within 25 m for 5 s; one request at a
///   time, at least 15 s apart, three failures and it stops; one short line
///   per departure, never more than one off-route line per 2 minutes.
/// * The personal route is mine only; the group plan stays as it is. A new
///   group plan (the lead changed the route) drops it and starts over.
/// * Back on the planned route: the personal route is dropped.
///
/// It notifies listeners only when the status line or the active route
/// changes; progress along the line is read by the ride screen when it
/// rebuilds for the same fix.
class RouteGuide extends ChangeNotifier {
  RouteGuide({required this.fetchRoute, this.reverseGeocode, this.fetchRouteHeaded, this.onPrompt});

  final RouteFetcher fetchRoute;
  final ReverseGeocoder? reverseGeocode;

  /// Used instead of [fetchRoute] for new routes when given (sends my heading).
  final HeadedRouteFetcher? fetchRouteHeaded;

  /// Where the short navigation lines go (null: not spoken).
  final NavPromptSink? onPrompt;

  /// Leaving the route, requests and spoken lines (exposed for tests).
  final RerouteController reroute = RerouteController();
  final HeadingTracker _heading = HeadingTracker();
  final OffRouteDetector _rejoin = OffRouteDetector(initial: OffRouteState.offRoute);
  int _lastFixMs = 0;
  bool _online = true;
  bool _offStatusShown = false;

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
  StopPointModel? _personalFuelStop;

  StopPointModel? get personalFuelStop => _personalFuelStop;

  // 3.55 "Route to group": a personal stop of another kind. Unlike the fuel stop it is only a way
  // back: it is cleared as soon as I am on the group's planned route again, within
  // [groupReachedM] of the target, or when the group plan changes.
  StopPointModel? _groupTarget;
  bool _groupDetourPending = false;
  int _groupRetryAtMs = 0;

  /// Where "Route to group" takes me (a point on the group's route near the closest rider), or null.
  StopPointModel? get groupTarget => _groupTarget;

  /// Within this distance of the group target it has done its job.
  static const double groupReachedM = 150;

  /// Called once when I reach (or ride past) my personal fuel stop and it is cleared.
  /// `reached`: true at the pump, false when I rode on past it.
  void Function(StopPointModel stop, {required bool reached})? onFuelStopDone;

  // 3.55 fuel detour stability: one request at a time, retried while offline, never dropped by
  // "back on the planned route" before the pump, kept through re-routes and a new group plan.
  bool _fuelBusy = false;
  bool _fuelDetourPending = false;
  int _fuelRetryAtMs = 0;
  double _fuelClosestM = double.infinity;

  /// Within this distance of the pump it counts as reached (or within [fuelSlowReachedM] when slow).
  static const double fuelReachedM = 60;
  static const double fuelSlowReachedM = 150;

  /// Riding on this much farther than my closest approach (once I was within
  /// [fuelPassNearM]) means I passed the pump: the stop is cleared.
  static const double fuelPassedM = 600;
  static const double fuelPassNearM = 400;

  /// A failed detour (no signal) is asked again at most this often.
  static const Duration fuelRetryEvery = Duration(seconds: 30);

  /// Hands-free personal fuel detour stop for THIS rider only.
  /// Computes a personal detour without altering the group convoy plan for other riders.
  ///
  /// The stop is set (and shown) at once; the detour route follows when the route service answers.
  /// True when the detour route is in place; false when it is not (no position or destination, no
  /// signal: the stop stays marked and the route is asked again from the next fixes).
  Future<bool> addPersonalFuelStop({
    required double lat,
    required double lng,
    required String name,
  }) async {
    if (_disposed) return false;
    final same = _personalFuelStop != null && GeoMath.haversine(_personalFuelStop!.lat, _personalFuelStop!.lng, lat, lng) < 30;
    if (same && _personal != null) return true; // a repeat tap for the same pump: nothing to do
    // 3.55 safety review: a request already on its way (a route to the group, or another pump) no
    // longer drops this tap. The pump is marked now and its detour is asked from the next fix once
    // that request is back (the old answer is ignored: identical() / generation checks below).
    if (same && _fuelBusy) return false;
    _personalFuelStop = StopPointModel(
      stopId: 'personal_fuel_${DateTime.now().millisecondsSinceEpoch}',
      lat: lat,
      lng: lng,
      name: name,
      category: 'FUEL',
      suggestedByName: 'Me',
    );
    _fuelClosestM = double.infinity;
    _fuelDetourPending = true;
    _fuelRetryAtMs = 0;
    _routeVersion++;
    _notify();
    return _fetchFuelDetour();
  }

  /// 3.55: routes me back to my group: from my position to [lat],[lng] (on the group's planned
  /// route near the closest rider, or that rider), then on through my remaining stops to the end.
  /// True when the route is in place; false while it is still to come (retried from the next fixes).
  Future<bool> routeToGroup({required double lat, required double lng, required String name}) async {
    if (_disposed || (lat == 0 && lng == 0)) return false;
    final same = _groupTarget != null && GeoMath.haversine(_groupTarget!.lat, _groupTarget!.lng, lat, lng) < 30;
    if (same && _personal != null && !_groupDetourPending) return true;
    _groupTarget = StopPointModel(
      stopId: 'personal_group_${DateTime.now().millisecondsSinceEpoch}',
      lat: lat,
      lng: lng,
      name: name,
      category: 'REGROUP',
      suggestedByName: 'Me',
    );
    _groupDetourPending = true;
    _groupRetryAtMs = 0;
    _routeVersion++;
    _notify();
    return _fetchGroupDetour();
  }

  /// Drops the route back to the group (I chose my own way); the plan (or a re-route) takes over.
  void clearGroupTarget() {
    if (_groupTarget == null) return;
    _groupTarget = null;
    _groupDetourPending = false;
    if (_personalFuelStop != null) {
      // The detour went through the target first: ask again straight to the pump.
      _fuelDetourPending = true;
      _fuelRetryAtMs = 0;
    }
    _clearPersonal();
    reroute.followNewLine();
    _notify();
  }

  Future<bool> _fetchGroupDetour() async {
    final target = _groupTarget;
    if (_disposed || target == null || _fuelBusy) return false;
    final start = _lastFix;
    if (start == null || (start.$1 == 0 && start.$2 == 0)) {
      _groupRetryAtMs = 0;
      return false;
    }
    final waypoints = [start, ..._detourTail(first: (target.lat, target.lng), requireDest: false)];
    _fuelBusy = true; // one detour request at a time, fuel or group
    final gen = ++_generation;
    RouteModel? route;
    try {
      route = await fetchRoute(waypoints);
    } catch (_) {
      route = null;
    } finally {
      _fuelBusy = false;
    }
    if (_disposed || !identical(_groupTarget, target)) return false;
    if (route == null || route.points.length < 2 || gen != _generation) {
      _groupDetourPending = true;
      _groupRetryAtMs = _lastFixMs + fuelRetryEvery.inMilliseconds;
      _setStatus('Route to the group: no route yet, trying again.', force: true);
      return false;
    }
    _personal = route;
    _personalProgress = RouteProgress(route.points);
    final last = _lastFix;
    if (last != null) _personalProgress!.update(last.$1, last.$2);
    _groupDetourPending = false;
    reroute.followNewLine();
    _rejoin.reset(OffRouteState.offRoute);
    _offStatusShown = false;
    _routeVersion++;
    _setStatus('Routing you to the group: ${TimelineText.distance(route.distanceM)}', force: true);
    _notify();
    return true;
  }

  /// After [first]: my fuel stop (unless it is [first]), the stops I still have to ride to, and
  /// the destination (when there is none and [requireDest], an empty list).
  List<(double, double)> _detourTail({required (double, double) first, bool requireDest = true}) {
    final convoy = _convoy;
    (double, double)? dest;
    if (convoy != null && (convoy.destinationLat != 0 || convoy.destinationLng != 0)) {
      dest = (convoy.destinationLat, convoy.destinationLng);
    } else {
      final line = convoy?.routeLine ?? const [];
      if (line.length >= 2) dest = line.last;
    }
    if (dest == null && requireDest) return const [];
    final myAlongM = _plan?.matched?.alongM;
    final fuel = _personalFuelStop;
    final stops = <(double, double)>[
      first,
      if (fuel != null && (fuel.lat, fuel.lng) != first) (fuel.lat, fuel.lng),
      if (convoy != null)
        for (final s in convoy.plannedStops)
          if (RoutePlan.stillAhead(s, _uid) && !RoutePlan.isBehind(s, _plan, myAlongM)) (s.lat, s.lng),
    ];
    final room = RouteConstants.maxWaypoints - 2;
    return [...stops.take(room < 0 ? 0 : room), ?dest];
  }

  /// Checks the group target against this fix: close enough, or a route still to fetch.
  void _checkGroupTarget(double lat, double lng, int nowMs, bool online) {
    final target = _groupTarget;
    if (target == null) return;
    if (GeoMath.haversine(lat, lng, target.lat, target.lng) <= groupReachedM) {
      _groupReached(nowMs);
      return;
    }
    if (_groupDetourPending && online && !_fuelBusy && nowMs >= _groupRetryAtMs) {
      _groupRetryAtMs = nowMs + fuelRetryEvery.inMilliseconds;
      _fetchGroupDetour().ignore();
    }
  }

  /// With the group again (near the target or back on the plan): the plan takes over.
  void _groupReached(int nowMs) {
    _groupTarget = null;
    _groupDetourPending = false;
    if (_personalFuelStop != null) {
      _fuelDetourPending = true;
      _fuelRetryAtMs = 0;
    }
    _clearPersonal();
    reroute.followNewLine();
    _rejoin.reset(OffRouteState.offRoute);
    _offStatusShown = false;
    _setStatus('Back with the group\'s route', untilMs: nowMs + RouteConstants.backOnRouteNoticeFor.inMilliseconds, force: true);
  }

  /// 3.55: true while I ride away from the group's planned route on my own (off it, or on a
  /// personal re-route), not counting my own fuel detour or a route back to the group. The
  /// cockpit uses it for "You left the group's route".
  bool get offGroupPlan =>
      _everOnPlan &&
      _canReroute &&
      !_arrived &&
      _personalFuelStop == null &&
      _groupTarget == null &&
      (_personal != null || reroute.status != RerouteStatus.following);

  /// Asks for the route from my position through the pump, then my remaining stops, to the end.
  Future<bool> _fetchFuelDetour() async {
    final stop = _personalFuelStop;
    if (_disposed || stop == null || _fuelBusy) return false;
    final convoy = _convoy;
    final start = _lastFix;
    (double, double)? dest;
    if (convoy != null && (convoy.destinationLat != 0 || convoy.destinationLng != 0)) {
      dest = (convoy.destinationLat, convoy.destinationLng);
    } else {
      final line = convoy?.routeLine ?? const [];
      if (line.length >= 2) dest = line.last;
    }
    if (start == null || (start.$1 == 0 && start.$2 == 0) || dest == null) {
      // No fix yet (or no destination): tried again from the next fix.
      _fuelRetryAtMs = 0;
      return false;
    }
    final myAlongM = _plan?.matched?.alongM;
    final stops = <(double, double)>[
      (stop.lat, stop.lng), // the pump first
      if (convoy != null)
        for (final s in convoy.plannedStops)
          if (RoutePlan.stillAhead(s, _uid) && !RoutePlan.isBehind(s, _plan, myAlongM)) (s.lat, s.lng),
    ];
    final room = RouteConstants.maxWaypoints - 2;
    final waypoints = [start, ...stops.take(room < 0 ? 0 : room), dest];
    _fuelBusy = true;
    // A re-route already on its way would land without the pump: it no longer applies.
    final gen = ++_generation;
    RouteModel? route;
    try {
      route = await fetchRoute(waypoints);
    } catch (_) {
      route = null;
    } finally {
      _fuelBusy = false;
    }
    if (_disposed) return false;
    // The pump was reached, cleared or replaced meanwhile, or a new group plan came in.
    if (!identical(_personalFuelStop, stop)) return false;
    if (route == null || route.points.length < 2 || gen != _generation) {
      _fuelDetourPending = true;
      _fuelRetryAtMs = _lastFixMs + fuelRetryEvery.inMilliseconds;
      _setStatus('Fuel stop marked: ${stop.name}. No route yet, trying again.', force: true);
      return false;
    }
    _personal = route;
    _personalProgress = RouteProgress(route.points);
    final last = _lastFix;
    if (last != null) _personalProgress!.update(last.$1, last.$2);
    _fuelDetourPending = false;
    reroute.followNewLine();
    _rejoin.reset(OffRouteState.offRoute);
    _offStatusShown = false;
    _routeVersion++;
    _setStatus('Auto-routed to ${stop.name}: ${TimelineText.distance(route.distanceM)}', force: true);
    _notify();
    return true;
  }

  /// Clears the fuel stop (refuelled, or I changed my mind); the plan (or a re-route) takes over.
  void clearPersonalFuelStop() {
    _personalFuelStop = null;
    _fuelDetourPending = false;
    _fuelClosestM = double.infinity;
    _clearPersonal();
    reroute.followNewLine();
    _notify();
  }

  /// Checks the pump against this fix: reached, passed, or a detour still to fetch. True when it notified.
  bool _checkFuelStop(double lat, double lng, double speedKmh, int nowMs, bool online) {
    final stop = _personalFuelStop;
    if (stop == null) return false;
    final d = GeoMath.haversine(lat, lng, stop.lat, stop.lng);
    if (d < _fuelClosestM) _fuelClosestM = d;
    final reached = d <= fuelReachedM || (d <= fuelSlowReachedM && speedKmh < 5);
    final passed = !reached && _fuelClosestM <= fuelPassNearM && d - _fuelClosestM >= fuelPassedM;
    if (reached || passed) {
      _personalFuelStop = null;
      _fuelDetourPending = false;
      _fuelClosestM = double.infinity;
      _clearPersonal();
      reroute.followNewLine();
      _rejoin.reset(OffRouteState.offRoute);
      _offStatusShown = false;
      _setStatus(
        reached ? 'At ${stop.name}. The route continues when you ride on.' : 'Passed ${stop.name}. Fuel stop removed.',
        untilMs: nowMs + RouteConstants.backOnRouteNoticeFor.inMilliseconds,
        force: true,
      );
      try {
        onFuelStopDone?.call(stop, reached: reached);
      } catch (_) {}
      return true;
    }
    if (_fuelDetourPending && online && !_fuelBusy && nowMs >= _fuelRetryAtMs) {
      _fuelRetryAtMs = nowMs + fuelRetryEvery.inMilliseconds;
      _fetchFuelDetour().ignore();
    }
    return false;
  }

  int _generation = 0;
  bool _disposed = false;
  String? _status;
  int _statusUntilMs = 0;
  (double, double)? _lastFix;
  int _routeVersion = 0;

  String? _lastRoadName;
  String? _cachedReverseRoadName;
  int _lastReverseLookupMs = 0;
  (double, double)? _lastReverseLookupFix;
  final Map<String, String> _roadNameGeoCache = {};

  /// Current road or highway name (e.g. "NH 44", "Outer Ring Rd") along the active route or cached corridor.
  String? get currentRoadName {
    final route = activeRoute;
    if (route != null && route.steps.isNotEmpty) {
      final progress = active?.matched;
      if (progress != null) {
        final rName = route.roadNameAt(progress.alongM);
        if (rName != null && rName.isNotEmpty) return rName;
      } else if (!_everOnPlan && route.steps.isNotEmpty) {
        final firstLabel = route.steps.first.roadLabel;
        if (firstLabel.isNotEmpty) return firstLabel;
      }
    }
    final fix = _lastFix;
    if (fix != null) {
      final cached = _roadNameGeoCache[_cellKey(fix.$1, fix.$2)];
      if (cached != null && cached.isNotEmpty) return cached;
    }
    return _cachedReverseRoadName;
  }

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
    // 3.55: a way back to the old plan no longer applies.
    _groupTarget = null;
    _groupDetourPending = false;
    // My fuel stop stays: its detour is asked again on the new plan from the next fix.
    if (_personalFuelStop != null) {
      _fuelDetourPending = true;
      _fuelRetryAtMs = 0;
    }
    // Re-anchor on the new group route: a request on its way is dropped.
    reroute.reset();
    _rejoin.reset(OffRouteState.offRoute);
    _lastFix = null;
    _offStatusShown = false;
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
  ///
  /// [headingDeg] is the GPS direction of travel when known (else it is
  /// taken from my movement); [autoReroute] false never asks for a new
  /// route (the "Auto re-route" setting), it only says "Off route." once.
  void onFix({
    required double lat,
    required double lng,
    required double speedKmh,
    double? accuracyM,
    required int nowMs,
    required bool online,
    required bool lowData,
    bool isTunnelCoasting = false,
    double? headingDeg,
    bool autoReroute = true,
  }) {
    if (_disposed) return;
    if (lat == 0 && lng == 0) return;
    final fix = (lat, lng);
    if (fix == _lastFix) return;
    _lastFix = fix;
    _lastFixMs = nowMs;
    _online = online;
    final heading = _heading.update(lat, lng, gpsHeadingDeg: headingDeg, speedKmh: speedKmh);
    var changed = false;
    if (_statusUntilMs > 0 && nowMs >= _statusUntilMs) {
      _status = null;
      _statusUntilMs = 0;
      changed = true;
    }

    if (_checkFuelStop(lat, lng, speedKmh, nowMs, online)) changed = false;
    _checkGroupTarget(lat, lng, nowMs, online);

    final road = currentRoadName;
    if (road != _lastRoadName) {
      _lastRoadName = road;
      changed = true;
    }

    if (road == null && reverseGeocode != null && online && !lowData && (nowMs - _lastReverseLookupMs >= 15000)) {
      final lastReq = _lastReverseLookupFix;
      final movedM = lastReq == null ? 999.0 : GeoMath.haversine(lastReq.$1, lastReq.$2, lat, lng);
      if (movedM >= 250) {
        _lastReverseLookupMs = nowMs;
        _lastReverseLookupFix = fix;
        final cell = _cellKey(lat, lng);
        reverseGeocode!(lat, lng).then((name) {
          if (_disposed || name == null || name.isEmpty) return;
          final clean = extractRoadName(name);
          if (clean.isNotEmpty) {
            _roadNameGeoCache[cell] = clean;
            _cachedReverseRoadName = clean;
            if (_cachedReverseRoadName != _lastRoadName) {
              _lastRoadName = _cachedReverseRoadName;
              _notify();
            }
          }
        }).catchError((_) {});
      }
    }

    final plan = _plan;
    if (plan == null) {
      if (changed) _notify();
      return;
    }

    final limit = RerouteRules.offLimitFor(accuracyM);
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
      reroute.reset();
      _offStatusShown = false;
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

    final nearPortal = DeadReckoningEngine.isNearTunnelPortal(lat, lng);
    final suppressOff = isTunnelCoasting || nearPortal;

    final personal = _personalProgress;
    RouteProgress line = plan;
    RouteMatch? m = onPlan;
    if (personal != null) {
      if (onPlan != null) {
        _rejoin.onFix(
          tsMs: nowMs,
          offM: onPlan.offM,
          alongM: onPlan.onLine ? onPlan.alongM : null,
          accuracyM: accuracyM,
          speedKmh: speedKmh,
          isTunnelCoasting: suppressOff,
        );
        // 3.55: back on the plan, a route back to the group has done its job.
        if (!_rejoin.isOff && _groupTarget != null) {
          _groupReached(nowMs);
          if (_personalFuelStop != null) return;
        }
        // Back on the plan drops my personal route, except a fuel detour before the pump
        // (a pump on the route is on the plan too: the detour must not cancel itself).
        if (!_rejoin.isOff && _personalFuelStop == null) {
          _clearPersonal();
          reroute.followNewLine();
          _rejoin.reset(OffRouteState.offRoute);
          _offStatusShown = false;
          _setStatus('Back on the planned route', untilMs: nowMs + RouteConstants.backOnRouteNoticeFor.inMilliseconds, force: true);
          return;
        }
      }
      line = personal;
      m = personal.update(lat, lng, acceptM: limit, accuracyM: accuracyM);
      // Riding the group plan again (a short cut back to the group) is not
      // leaving my new route: the plan counts too until the rejoin drops it.
      if (onPlan != null && onPlan.onLine && (m == null || onPlan.offM < m.offM)) {
        line = plan;
        m = onPlan;
      }
    }
    if (m == null) {
      if (changed) _notify();
      return;
    }

    final step = reroute.onFix(
      NavFix(tsMs: nowMs, speedKmh: speedKmh, accuracyM: accuracyM, headingDeg: heading),
      offM: m.offM,
      routeBearingDeg: _bearingAt(line, m),
      suppress: suppressOff,
      online: online,
      autoReroute: autoReroute,
    );
    _say(step.prompts);
    if (step.event == FollowEvent.cameBack) {
      _generation++; // a request still on its way is no longer needed
      _offStatusShown = false;
      // 3.55: on the plan again before the route to the group arrived.
      if (personal == null && _groupTarget != null) {
        _groupTarget = null;
        _groupDetourPending = false;
      }
      if (personal == null) {
        _setStatus('Back on the planned route', untilMs: nowMs + RouteConstants.backOnRouteNoticeFor.inMilliseconds);
        return;
      }
      _setStatus(null, force: changed);
      return;
    }
    if (step.request) _reroute(lat, lng, heading, nowMs);
    if (_syncOffStatus()) changed = false;
    if (changed) _notify();
  }

  /// Direction of [line] at the match (degrees), or null.
  static double? _bearingAt(RouteProgress line, RouteMatch m) {
    final pts = line.points;
    final i = m.index;
    if (i < 0 || i + 1 >= pts.length) return null;
    final (aLat, aLng) = pts[i];
    final (bLat, bLng) = pts[i + 1];
    if (aLat == bLat && aLng == bLng) return null;
    return RerouteRules.bearing(aLat, aLng, bLat, bLng);
  }

  /// The status line while off the route; true when it notified.
  bool _syncOffStatus() {
    final planned = _personal == null;
    final text = switch (reroute.status) {
      RerouteStatus.following => null,
      RerouteStatus.finding => planned ? 'Off the planned route, finding a new route' : 'Off route, finding a new route',
      RerouteStatus.noSignal => 'Off the planned route, no signal for a new route',
      RerouteStatus.gaveUp => "Couldn't find a new route. Follow the group.",
      RerouteStatus.off => planned ? 'Off the planned route' : 'Off route',
    };
    if (text != null) {
      _offStatusShown = true;
      if (text == _status && _statusUntilMs == 0) return false;
      _setStatus(text);
      return true;
    }
    if (!_offStatusShown) return false;
    _offStatusShown = false;
    if (_status == null) return false;
    _setStatus(null);
    return true;
  }

  void _say(List<NavPrompt> prompts) {
    final sink = onPrompt;
    if (sink == null || _disposed) return;
    for (final p in prompts) {
      try {
        sink(p);
      } catch (_) {}
    }
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

  void _reroute(double lat, double lng, double? heading, int nowMs) {
    final convoy = _convoy;
    if (convoy == null) return;
    // From here through the stops I still have to ride to (the next one
    // first), to the destination.
    var waypoints = RoutePlan.rerouteWaypoints(convoy, _uid, lat, lng, plan: _plan, myAlongM: _plan?.matched?.alongM);
    if (waypoints.length < 2) return;
    // My fuel stop comes first on any new route until I reach it.
    final fuel = _personalFuelStop;
    if (fuel != null) {
      final room = RouteConstants.maxWaypoints;
      waypoints = [waypoints.first, (fuel.lat, fuel.lng), ...waypoints.skip(1)];
      if (waypoints.length > room) waypoints = [...waypoints.take(room - 1), waypoints.last];
    }
    // 3.55: and the way back to the group before everything else.
    final group = _groupTarget;
    if (group != null) {
      final room = RouteConstants.maxWaypoints;
      waypoints = [waypoints.first, (group.lat, group.lng), ...waypoints.skip(1)];
      if (waypoints.length > room) waypoints = [...waypoints.take(room - 1), waypoints.last];
    }
    final ticket = reroute.begin(nowMs);
    _fetch(waypoints, heading, ticket, _generation).ignore();
  }

  Future<void> _fetch(List<(double, double)> waypoints, double? heading, int ticket, int gen) async {
    RouteModel? r;
    try {
      final headed = fetchRouteHeaded;
      r = headed != null ? await headed(waypoints, heading) : await fetchRoute(waypoints);
    } catch (_) {
      r = null;
    }
    if (_disposed) return;
    final route = r;
    RouteProgress? progress;
    RouteMatch? here;
    if (route != null && !route.approximate && route.points.length >= 2) {
      progress = RouteProgress(route.points);
      final last = _lastFix;
      if (last != null) here = progress.update(last.$1, last.$2);
    }
    // A route that does not start where I am (my road or track is not on
    // the map) counts as a failure and is not shown: following it would put
    // me off the route again at once.
    final usable = progress != null && (here == null || here.onLine);
    final out = reroute.finish(ticket, ok: usable, online: _online, nowMs: _lastFixMs);
    _say(out.prompts);
    if (!out.current || gen != _generation || _arrived || !usable || route == null) {
      _syncOffStatus();
      return;
    }
    _personal = route;
    _personalProgress = progress;
    _routeVersion++;
    _rejoin.reset(OffRouteState.offRoute);
    _offStatusShown = false;
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

  static String extractRoadName(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return '';
    final nhMatch = RegExp(r'\b(NH|SH|AH)\s*(\d+)\b', caseSensitive: false).firstMatch(clean);
    if (nhMatch != null) {
      final prefix = nhMatch.group(1)!.toUpperCase();
      final num = nhMatch.group(2)!;
      return '$prefix $num';
    }
    final parts = clean.split(',');
    if (parts.isNotEmpty) {
      return parts.first.trim();
    }
    return clean;
  }

  static String _cellKey(double lat, double lng) => '${(lat * 200).round() / 200},${(lng * 200).round() / 200}';

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
