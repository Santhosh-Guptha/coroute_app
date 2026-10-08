import '../../core/constants/route_constants.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/stop_point_model.dart';
import 'route_progress.dart';

/// Where a new meeting point goes in the stop list.
class MeetingPlacement {
  /// Put the meeting point just before this stop (null: after the last stop).
  final String? insertBefore;

  /// The open meeting point it replaces, if any.
  final StopPointModel? replaces;

  const MeetingPlacement({this.insertBefore, this.replaces});
}

/// Pure helpers that turn the group plan into route requests and stop edits.
class RoutePlan {
  RoutePlan._();

  static const String meetingCategory = 'MEETING';

  static bool _isMeeting(StopPointModel s) => s.category.toUpperCase() == meetingCategory;

  /// True when this rider still has to ride to [s]: planned, not marked
  /// visited, and not reached or passed by this rider.
  static bool stillAhead(StopPointModel s, String myUserId) {
    if (!s.isPlanned || s.isVisited) return false;
    final a = s.arrivals[myUserId];
    return a == null || !(a.reached || a.passed);
  }

  /// Points for a personal route from (lat, lng) to the destination through
  /// the stops this rider still has to ride to, in plan order. Capped at
  /// [RouteConstants.maxWaypoints] (the destination is always kept). Empty
  /// when there is nowhere to go (no destination and no route line).
  ///
  /// With [plan] and [myAlongM] (how far along the planned line I got), a
  /// stop that lies on the plan only behind me is left out too: a rider who
  /// joined halfway, or whose pass was not seen in a dead zone, is never
  /// sent back to an earlier stop.
  static List<(double, double)> rerouteWaypoints(
    ConvoyModel convoy,
    String myUserId,
    double lat,
    double lng, {
    RouteProgress? plan,
    double? myAlongM,
  }) {
    (double, double)? dest;
    if (convoy.destinationLat != 0 || convoy.destinationLng != 0) {
      dest = (convoy.destinationLat, convoy.destinationLng);
    } else {
      final line = convoy.routeLine;
      if (line.length >= 2) dest = line.last;
    }
    if (dest == null) return const [];
    final stops = <(double, double)>[
      for (final s in convoy.plannedStops)
        if (stillAhead(s, myUserId) && !_behind(s, plan, myAlongM)) (s.lat, s.lng),
    ];
    final room = RouteConstants.maxWaypoints - 2;
    return [(lat, lng), ...stops.take(room < 0 ? 0 : room), dest];
  }

  /// True when [s] lies on the plan but not on the part from [fromAlongM]
  /// onward. A stop away from the line (or with no plan) is never "behind".
  static bool _behind(StopPointModel s, RouteProgress? plan, double? fromAlongM) {
    if (plan == null || fromAlongM == null || !plan.isUsable) return false;
    const tol = RouteConstants.offRouteM;
    final anywhere = plan.locateAhead(s.lat, s.lng);
    if (anywhere == null || anywhere.offM > tol) return false;
    final ahead = plan.locateAhead(s.lat, s.lng, fromAlongM: fromAlongM);
    return ahead == null || ahead.offM > tol;
  }

  /// Where a meeting point at (lat, lng) belongs: before the first stop
  /// still ahead that lies farther along the planned route, so the group
  /// route visits it in riding order. An open (not visited) meeting point
  /// is replaced: a group has one meeting point at a time.
  /// [plan] is the planned route line; [fromAlongM] is how far along it the
  /// lead is (null: from the start).
  static MeetingPlacement meetingPlacement(
    ConvoyModel convoy, {
    required double lat,
    required double lng,
    RouteProgress? plan,
    double? fromAlongM,
  }) {
    StopPointModel? old;
    for (final s in convoy.plannedStops) {
      if (_isMeeting(s) && !s.isVisited) {
        old = s;
        break;
      }
    }
    String? before;
    if (plan != null && plan.isUsable) {
      final from = fromAlongM ?? 0.0;
      final meet = plan.locateAhead(lat, lng, fromAlongM: from)?.alongM;
      if (meet != null) {
        for (final s in convoy.plannedStops) {
          if (s.isVisited || s.stopId == old?.stopId) continue;
          final at = plan.locateAhead(s.lat, s.lng, fromAlongM: from)?.alongM;
          if (at != null && at > meet) {
            before = s.stopId;
            break;
          }
        }
      }
    }
    return MeetingPlacement(insertBefore: before, replaces: old);
  }
}
