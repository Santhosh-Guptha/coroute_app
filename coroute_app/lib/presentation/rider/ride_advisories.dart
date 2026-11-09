import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/map_places_service.dart';
import '../../domain/places/heritage_ahead.dart';
import '../../domain/places/poi_category.dart';
import '../../domain/places/route_corridor.dart';
import '../../domain/ride/ride_tap_gate.dart';
import '../../domain/route/off_route_group.dart';
import '../../domain/route/route_guide.dart';
import '../../domain/tracking/geo_math.dart';

/// 3.55 cockpit advisories that are not safety alerts, kept out of the (large) cockpit state:
///
/// * "Historic place on your way" (heritage places near the route ahead, from the map places
///   already on the phone; at most one per place per ride and one every 10 minutes, never
///   during an SOS).
/// * "You left the group's route" (off the group's plan for 20 s in a group ride; the way back
///   to the group, a wait request, or carrying on alone).
///
/// Fed from the cockpit's convoy listener (no timers, no extra GPS); the cockpit draws the slots
/// and runs the actions. Entry points for the 3.55 feature switches: [heritageEnabled] and
/// [offGroupEnabled].
class RideAdvisories {
  final HeritageNoticeGate heritageGate = HeritageNoticeGate();
  final OffRouteGroupMonitor offGroup = OffRouteGroupMonitor();

  /// Speak while moving, act when stopped: the gated cards (off-route, swap ask, historic place,
  /// place review) show their buttons only when [RideTapGate.canTap]. Fed on every [update]
  /// from my rider record's public speed (a pillion can always tap).
  final RideTapGate tapGate = RideTapGate();

  /// Each gated card's moving line is said once.
  final MovingLineOnce movingLines = MovingLineOnce();

  /// Switched off by the cockpit when the admin turned the feature off.
  bool heritageEnabled = true;
  bool offGroupEnabled = true;

  /// The heritage notice on screen now (until [heritageUntilMs]), or null.
  HeritageAhead? heritage;
  int heritageUntilMs = 0;

  /// How long a heritage notice stays (it has buttons, so longer than the 5 s auto-hide).
  static const Duration heritageShowFor = Duration(seconds: 45);

  /// Heritage places are looked for at most this often.
  static const Duration heritageCheckEvery = Duration(seconds: 30);

  /// Show "You left the group's route" now.
  bool offGroupShow = false;

  /// When the current departure began (part of the slot key), 0 when on route.
  int offGroupSinceMs = 0;

  int _lastHeritageCheckMs = 0;
  String? _groupId;
  Object? _pathKey;
  RoutePath? _path;

  /// One look after a convoy change. Returns the lines to say (text, key, heritage?).
  List<({String text, String key, bool heritage})> update({
    required ConvoyModel convoy,
    required RiderModel me,
    required RouteGuide guide,
    required MapPlacesService? places,
    required bool sosOpen,
    required int nowMs,
  }) {
    final out = <({String text, String key, bool heritage})>[];
    if (_groupId != convoy.groupId) {
      _groupId = convoy.groupId;
      heritageGate.reset();
      tapGate.reset();
      movingLines.reset();
      heritage = null;
      heritageUntilMs = 0;
      _lastHeritageCheckMs = 0;
    }
    final hasPos = me.lat != 0 || me.lng != 0;
    tapGate.update(speedKmh: me.speedKmh, nowMs: nowMs, passenger: me.isCoRiding);

    // ---- off the group's route
    final peers = groupPeers(convoy, me);
    final d = offGroupEnabled
        ? offGroup.update(
            offPlan: guide.offGroupPlan && !convoy.isSoloRide,
            nowMs: nowMs,
            riderCount: convoy.riders.length,
            myLat: hasPos ? me.lat : null,
            myLng: hasPos ? me.lng : null,
            others: peers,
          )
        : OffRouteGroupDecision.none;
    offGroupShow = d.show && !sosOpen;
    offGroupSinceMs = offGroup.off ? (offGroupSinceMs == 0 ? nowMs : offGroupSinceMs) : 0;
    if (d.speak && !sosOpen) {
      final line = tapGate.canTap ? OffRouteGroupMonitor.spokenStopped : OffRouteGroupMonitor.spoken;
      out.add((text: line, key: 'OFF_GROUP:$offGroupSinceMs', heritage: false));
    }

    // ---- historic places on the way
    if (heritage != null && nowMs >= heritageUntilMs) heritage = null;
    if (sosOpen) heritage = null;
    if (heritageEnabled &&
        hasPos &&
        places != null &&
        places.isEnabled(PoiCategory.heritage) &&
        nowMs - _lastHeritageCheckMs >= heritageCheckEvery.inMilliseconds) {
      _lastHeritageCheckMs = nowMs;
      final ahead = upcomingHeritage(convoy, me, places);
      final pick = heritageGate.pick(ahead, nowMs: nowMs, sosOpen: sosOpen);
      if (pick != null) {
        heritage = pick;
        heritageUntilMs = nowMs + heritageShowFor.inMilliseconds;
        out.add((text: 'Historic place on your way: ${pick.poi.displayName}, ${pick.message}', key: 'HERITAGE:${pick.poi.id}', heritage: true));
      }
    }
    return out;
  }

  /// Historic places near the route ahead of me, nearest first (also for the essentials sheet).
  List<HeritageAhead> upcomingHeritage(ConvoyModel convoy, RiderModel me, MapPlacesService places, {int limit = 5}) {
    final hasPos = me.lat != 0 || me.lng != 0;
    if (!hasPos) return const [];
    RoutePath? path;
    double? progress;
    final shared = places.path;
    if (places.hasRoute && shared != null && shared.valid) {
      path = shared;
      progress = places.progressM;
    } else {
      path = _planPath(convoy);
    }
    if (path == null || !path.valid) return const [];
    // Cheap first cut by straight-line distance, then the projection onto the route.
    final near = places.all.where((p) =>
        p.category == PoiCategory.heritage && GeoMath.haversine(me.lat, me.lng, p.lat, p.lng) <= 27000);
    return heritageAhead(path: path, candidates: near, progressM: progress, myLat: me.lat, myLng: me.lng, limit: limit);
  }

  /// The way back to the group, or null when no other rider has a fresh position.
  RejoinTarget? rejoinTarget(ConvoyModel convoy, RiderModel me, int nowMs) {
    if (me.lat == 0 && me.lng == 0) return null;
    return OffRouteGroupMonitor.target(myLat: me.lat, myLng: me.lng, others: groupPeers(convoy, me), nowMs: nowMs, plan: _planPath(convoy));
  }

  /// A choice was made on "You left the group's route".
  void resolveOffGroup() {
    offGroup.resolve();
    offGroupShow = false;
  }

  void dismissHeritage() {
    heritage = null;
    heritageUntilMs = 0;
  }

  /// The other riders, without my own rider or pillion (they are with me, not with the group).
  static List<GroupPeer> groupPeers(ConvoyModel convoy, RiderModel me) => [
        for (final r in convoy.riders.values)
          if (r.userId != me.userId &&
              !(me.isCoRiding && me.ridingWithUserId == r.userId) &&
              !(r.isCoRiding && r.ridingWithUserId == me.userId))
            GroupPeer(userId: r.userId, name: r.name, lat: r.lat, lng: r.lng, lastSeenMs: r.lastSeenEpochMs),
      ];

  RoutePath? _planPath(ConvoyModel convoy) {
    final Object key = convoy.route?.polyline ?? convoy.routeBreadcrumbs;
    if (!identical(key, _pathKey) && key != _pathKey) {
      _pathKey = key;
      final line = convoy.routeLine;
      _path = line.length >= 2 ? RoutePath(line) : null;
    }
    return _path;
  }
}
