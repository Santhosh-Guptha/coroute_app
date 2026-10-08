import '../../core/constants/ride_thresholds.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/route_model.dart';
import '../../data/models/stop_point_model.dart';
import '../timeline/timeline_text.dart';
import '../tracking/geo_math.dart';

/// The rider's own GPS in plain words (shown in the ride top bar).
enum GpsState {
  accurate,
  updating,
  lowAccuracy,
  unavailable;

  String get label {
    switch (this) {
      case GpsState.accurate:
        return 'Accurate';
      case GpsState.updating:
        return 'Updating';
      case GpsState.lowAccuracy:
        return 'Low accuracy';
      case GpsState.unavailable:
        return 'Unavailable';
    }
  }
}

/// One rider in the group distance ladder (ordered from the front of the
/// group to the back).
class LadderRung {
  final RiderModel rider;
  final bool isMe;

  /// How far along the ride this rider is, in metres (along the planned
  /// route, or minus the straight distance to the destination when there is
  /// no route). Null when it cannot be known (no position, no route and no
  /// destination).
  final double? progressM;

  /// Distance to the rider just ahead in the ladder. Null for the first
  /// rider and for riders whose progress is unknown.
  final double? gapAheadM;

  /// Signed distance from me along the ride: positive ahead of me,
  /// negative behind me. Null when unknown or for me.
  final double? fromMeM;

  /// Straight-line distance from me, when both positions are known.
  final double? straightFromMeM;

  /// The gap to the rider ahead is larger than the group's separation limit.
  final bool tooFarBehind;

  const LadderRung({
    required this.rider,
    required this.isMe,
    this.progressM,
    this.gapAheadM,
    this.fromMeM,
    this.straightFromMeM,
    this.tooFarBehind = false,
  });

  /// True ahead of me, false behind, null when unknown or about level.
  bool? get ahead {
    final d = fromMeM;
    if (d == null || d.abs() <= RideFacts.sameSpotM) return null;
    return d > 0;
  }

  /// The distance to show next to the rider: along the ride when known,
  /// else as the crow flies.
  double? get displayFromMeM {
    final d = fromMeM;
    return d != null ? d.abs() : straightFromMeM;
  }
}

/// Everything the ride screen derives from one convoy update. Built by
/// [RideFacts.snapshot]; the screen keeps it until the convoy changes.
class RideSnapshot {
  final RiderModel? me;

  /// Metres still to ride to the destination (along the route when there is one).
  final double? remainingM;

  /// Riding time left at the planned route's pace. Null without a route.
  final Duration? eta;
  final List<LadderRung> ladder;
  final double spreadM;
  final StopPointModel? nextStop;
  final double? nextStopM;

  /// Planned stops in order with the distance from me (null when unknown).
  final List<(StopPointModel, double?)> stops;

  const RideSnapshot({
    required this.me,
    required this.remainingM,
    required this.eta,
    required this.ladder,
    required this.spreadM,
    required this.nextStop,
    required this.nextStopM,
    required this.stops,
  });

  /// The same snapshot with the remaining distance and ETA measured along
  /// the part of the route still to ride (see `RouteGuide`).
  RideSnapshot withRemaining(double? remainingM, Duration? eta) => RideSnapshot(
        me: me,
        remainingM: remainingM,
        eta: eta,
        ladder: ladder,
        spreadM: spreadM,
        nextStop: nextStop,
        nextStopM: nextStopM,
        stops: stops,
      );
}

/// Pure ride arithmetic for the active ride screen: remaining distance, ETA,
/// the group ladder with gaps, spread, nearby riders, stopped detection and
/// the GPS state. No timers, no GPS requests, no Flutter.
class RideFacts {
  RideFacts._();

  /// Two riders closer than this along the route count as level.
  static const double sameSpotM = 30;

  /// While moving, no fix for this long reads "Updating".
  static const Duration gpsUpdatingAfter = Duration(seconds: 15);

  /// Radius for "riders nearby" in stopped mode.
  static const double nearbyRadiusM = 500;

  static bool hasPosition(RiderModel r) => r.lat != 0 || r.lng != 0;

  static bool hasDestination(ConvoyModel c) => c.destinationLat != 0 || c.destinationLng != 0;

  /// Metres from the start of [line] to the point on it closest to (lat, lng).
  static double? alongM(double lat, double lng, List<(double, double)> line) => GeoMath.alongRoute(lat, lng, line)?.along;

  /// Length of [line] in metres, measured the same way as [alongM].
  static double? routeLengthM(List<(double, double)> line) => line.length < 2 ? null : alongM(line.last.$1, line.last.$2, line);

  /// Metres left to the destination: along the route when there is one
  /// (same rule as the status notification), else as the crow flies.
  /// Null without my position or without a destination.
  static double? remainingM({
    required double lat,
    required double lng,
    required List<(double, double)> line,
    required double destLat,
    required double destLng,
  }) {
    if (lat == 0 && lng == 0) return null;
    if (destLat == 0 && destLng == 0) return null;
    final along = alongM(lat, lng, line);
    final total = routeLengthM(line);
    if (along != null && total != null) {
      final left = total - along;
      return left < 0 ? 0.0 : left;
    }
    return GeoMath.haversine(lat, lng, destLat, destLng);
  }

  /// Riding time for [remaining] metres at the pace of the planned route
  /// (route duration / route distance). Null without a usable route.
  static Duration? etaFor(double? remaining, RouteModel? route) {
    if (remaining == null || route == null) return null;
    if (route.distanceM <= 0 || route.durationS <= 0) return null;
    return Duration(seconds: (remaining * route.durationS / route.distanceM).round());
  }

  /// How far along the ride [r] is (see [LadderRung.progressM]).
  static double? progressM(RiderModel r, List<(double, double)> line, {double destLat = 0, double destLng = 0}) {
    if (!hasPosition(r)) return null;
    if (line.length >= 2) return alongM(r.lat, r.lng, line);
    if (destLat != 0 || destLng != 0) return -GeoMath.haversine(r.lat, r.lng, destLat, destLng);
    return null;
  }

  /// The group from front to back, with the gap to the rider ahead and a
  /// "too far behind" flag when that gap is larger than the group's
  /// separation limit ([ConvoyModel.distanceThresholdMeters]). Riders whose
  /// place is unknown come last, by name.
  static List<LadderRung> ladder(ConvoyModel convoy, String myUserId) {
    final line = convoy.routeLine;
    final limit = convoy.distanceThresholdMeters;
    final me = convoy.riders[myUserId];
    final myProgress = me == null ? null : progressM(me, line, destLat: convoy.destinationLat, destLng: convoy.destinationLng);
    final known = <(RiderModel, double)>[];
    final unknown = <RiderModel>[];
    for (final r in convoy.riders.values) {
      final p = progressM(r, line, destLat: convoy.destinationLat, destLng: convoy.destinationLng);
      if (p == null) {
        unknown.add(r);
      } else {
        known.add((r, p));
      }
    }
    known.sort((a, b) {
      final c = b.$2.compareTo(a.$2);
      return c != 0 ? c : a.$1.name.compareTo(b.$1.name);
    });
    unknown.sort((a, b) => a.name.compareTo(b.name));

    double? straight(RiderModel r) =>
        (me != null && hasPosition(me) && hasPosition(r) && r.userId != myUserId) ? GeoMath.haversine(me.lat, me.lng, r.lat, r.lng) : null;

    final out = <LadderRung>[];
    for (var i = 0; i < known.length; i++) {
      final (r, p) = known[i];
      final isMe = myUserId.isNotEmpty && r.userId == myUserId;
      final gap = i == 0 ? null : known[i - 1].$2 - p;
      out.add(LadderRung(
        rider: r,
        isMe: isMe,
        progressM: p,
        gapAheadM: gap,
        fromMeM: (!isMe && myProgress != null) ? p - myProgress : null,
        straightFromMeM: straight(r),
        tooFarBehind: gap != null && limit > 0 && gap > limit,
      ));
    }
    for (final r in unknown) {
      out.add(LadderRung(rider: r, isMe: myUserId.isNotEmpty && r.userId == myUserId, straightFromMeM: straight(r)));
    }
    return out;
  }

  /// Length of the group in metres: front to back along the route, or the
  /// largest straight distance between two riders when there is no route.
  static double spreadM(ConvoyModel convoy) {
    final placed = convoy.riders.values.where(hasPosition).toList();
    if (placed.length < 2) return 0;
    final line = convoy.routeLine;
    if (line.length >= 2) {
      double? lo, hi;
      for (final r in placed) {
        final a = alongM(r.lat, r.lng, line);
        if (a == null) continue;
        lo = (lo == null || a < lo) ? a : lo;
        hi = (hi == null || a > hi) ? a : hi;
      }
      if (lo != null && hi != null) return hi - lo;
    }
    var best = 0.0;
    for (var i = 0; i < placed.length; i++) {
      for (var j = i + 1; j < placed.length; j++) {
        final d = GeoMath.haversine(placed[i].lat, placed[i].lng, placed[j].lat, placed[j].lng);
        if (d > best) best = d;
      }
    }
    return best;
  }

  /// Riders moving now (at least [RideThresholds.movingSpeedKmh], heard
  /// from within [RideThresholds.offlineAfter]).
  static int ridingCount(Iterable<RiderModel> riders, {required int nowMs}) {
    var n = 0;
    for (final r in riders) {
      final fresh = r.lastSeenEpochMs > 0 && nowMs - r.lastSeenEpochMs < RideThresholds.offlineAfter.inMilliseconds;
      if (fresh && r.speedKmh >= RideThresholds.movingSpeedKmh) n++;
    }
    return n;
  }

  /// Other riders within [radiusM] of me (last known positions).
  static int nearbyCount(ConvoyModel convoy, String myUserId, {double radiusM = nearbyRadiusM}) {
    final me = convoy.riders[myUserId];
    if (me == null || !hasPosition(me)) return 0;
    var n = 0;
    for (final r in convoy.riders.values) {
      if (r.userId == myUserId || !hasPosition(r)) continue;
      if (GeoMath.haversine(me.lat, me.lng, r.lat, r.lng) <= radiusM) n++;
    }
    return n;
  }

  /// How long I have been stopped, or null while riding. Stopped means
  /// slower than [RideThresholds.movingSpeedKmh] and either stopped for at
  /// least the group's stop limit or a stop reason is set.
  static Duration? stoppedFor(RiderModel me, {required int nowMs, required int thresholdSeconds}) {
    if (me.stoppedSince <= 0 || me.speedKmh >= RideThresholds.movingSpeedKmh) return null;
    final ms = nowMs - me.stoppedSince;
    if (ms < 0) return null;
    if (me.statusReason.isEmpty && ms < thresholdSeconds * 1000) return null;
    return Duration(milliseconds: ms);
  }

  /// The first planned stop not visited yet.
  static StopPointModel? nextStop(ConvoyModel convoy) {
    for (final s in convoy.plannedStops) {
      if (!s.isVisited) return s;
    }
    return null;
  }

  /// Metres from me to a point: along the route when both project onto it
  /// and the point is ahead, else as the crow flies. Null without my position.
  static double? distanceToM(RiderModel me, double lat, double lng, List<(double, double)> line, {double? myAlong}) {
    if (!hasPosition(me)) return null;
    final a = myAlong ?? alongM(me.lat, me.lng, line);
    final b = alongM(lat, lng, line);
    if (a != null && b != null && b - a > 0) return b - a;
    return GeoMath.haversine(me.lat, me.lng, lat, lng);
  }

  /// My GPS in plain words.
  static GpsState gpsState({
    required bool active,
    required int lastFixMs,
    double? accuracyM,
    required bool moving,
    required int nowMs,
  }) {
    if (!active) return GpsState.unavailable;
    if (accuracyM != null && accuracyM > RideThresholds.lowGpsAccuracyM) return GpsState.lowAccuracy;
    if (lastFixMs <= 0) return GpsState.updating;
    if (moving && nowMs - lastFixMs >= gpsUpdatingAfter.inMilliseconds) return GpsState.updating;
    return GpsState.accurate;
  }

  /// Plain text for "Share my ETA": where I am going, how far is left and
  /// when I arrive. No link, no coordinates. [arrival] is the clock time
  /// already formatted for the phone ("4:35 PM"); null or empty leaves it out.
  /// "On the way to Goa with CoRoute. 42 km left, arriving about 4:35 PM."
  static String shareEtaText({required String destinationName, double? remainingM, String? arrival}) {
    final dest = destinationName.trim();
    final head = dest.isEmpty ? 'On the way with CoRoute.' : 'On the way to $dest with CoRoute.';
    final left = (remainingM != null && remainingM.isFinite) ? '${TimelineText.distance(remainingM)} left' : '';
    final at = (arrival == null || arrival.isEmpty) ? '' : 'arriving about $arrival';
    final tail = [
      if (left.isNotEmpty) left,
      if (at.isNotEmpty) at,
    ].join(', ');
    if (tail.isEmpty) return head;
    return '$head ${tail[0].toUpperCase()}${tail.substring(1)}.';
  }

  /// All of the above for one convoy update.
  static RideSnapshot snapshot(ConvoyModel convoy, String myUserId) {
    final line = convoy.routeLine;
    final me = convoy.riders[myUserId];
    final myAlong = (me != null && hasPosition(me)) ? alongM(me.lat, me.lng, line) : null;
    final remaining = me == null
        ? null
        : remainingM(lat: me.lat, lng: me.lng, line: line, destLat: convoy.destinationLat, destLng: convoy.destinationLng);
    final next = nextStop(convoy);
    return RideSnapshot(
      me: me,
      remainingM: remaining,
      eta: etaFor(remaining, convoy.route),
      ladder: ladder(convoy, myUserId),
      spreadM: spreadM(convoy),
      nextStop: next,
      nextStopM: (me != null && next != null) ? distanceToM(me, next.lat, next.lng, line, myAlong: myAlong) : null,
      stops: [
        for (final s in convoy.plannedStops)
          (s, (me != null && !s.isVisited) ? distanceToM(me, s.lat, s.lng, line, myAlong: myAlong) : null),
      ],
    );
  }
}
