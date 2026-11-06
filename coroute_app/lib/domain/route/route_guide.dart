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

  /// Hands-free personal fuel detour stop for THIS rider only.
  /// Computes a personal detour without altering the group convoy plan for other riders.
  Future<bool> addPersonalFuelStop({
    required double lat,
    required double lng,
    required String name,
  }) async {
    if (_disposed) return false;
    final convoy = _convoy;
    final start = _lastFix ?? (convoy != null && convoy.destinationLat != 0 ? (convoy.destinationLat, convoy.destinationLng) : null);
    if (start == null || (start.$1 == 0 && start.$2 == 0)) return false;

    (double, double)? dest;
    if (convoy != null && (convoy.destinationLat != 0 || convoy.destinationLng != 0)) {
      dest = (convoy.destinationLat, convoy.destinationLng);
    } else {
      final line = convoy?.routeLine ?? const [];
      if (line.length >= 2) dest = line.last;
    }
    if (dest == null) return false;

    final myAlongM = _plan?.matched?.alongM;
    final stops = <(double, double)>[
      (lat, lng), // Detour to fuel station first
      if (convoy != null)
        for (final s in convoy.plannedStops)
          if (RoutePlan.stillAhead(s, _uid) && !RoutePlan.isBehind(s, _plan, myAlongM))
            (s.lat, s.lng),
    ];
    final room = RouteConstants.maxWaypoints - 2;
    final waypoints = [start, ...stops.take(room < 0 ? 0 : room), dest];

    try {
      final route = await fetchRoute(waypoints);
      if (_disposed || route == null || route.points.length < 2) return false;
      _personal = route;
      _personalProgress = RouteProgress(route.points);
      reroute.followNewLine();
      _rejoin.reset(OffRouteState.offRoute);
      _personalFuelStop = StopPointModel(
        stopId: 'personal_fuel_${DateTime.now().millisecondsSinceEpoch}',
        lat: lat,
        lng: lng,
        name: name,
        category: 'FUEL',
        suggestedByName: 'Me',
      );
      _routeVersion++;
      _setStatus('Auto-routed to $name: ${TimelineText.distance(route.distanceM)}', force: true);
      _notify();
      return true;
    } catch (_) {
      return false;
    }
  }

  void clearPersonalFuelStop() {
    _personalFuelStop = null;
    _clearPersonal();
    reroute.followNewLine();
    _notify();
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
        if (!_rejoin.isOff) {
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
    final waypoints = RoutePlan.rerouteWaypoints(convoy, _uid, lat, lng, plan: _plan, myAlongM: _plan?.matched?.alongM);
    if (waypoints.length < 2) return;
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
