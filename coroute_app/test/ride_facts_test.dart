import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';

void main() {
  const now = 1700000000000;
  // 0.1 degree of latitude along a meridian, as GeoMath measures it.
  const tenth = 0.1 * 3.141592653589793 / 180 * GeoMath.earthRadiusM; // about 11.12 km

  RiderModel rider(String id, String name, double lat, {double lng = 78.0, double speed = 40, int? seen, int stoppedSince = 0, String reason = ''}) =>
      RiderModel(
        userId: id,
        name: name,
        lat: lat,
        lng: lng,
        speedKmh: speed,
        lastSeenEpochMs: seen ?? now,
        stoppedSince: stoppedSince,
        statusReason: reason,
      );

  // A straight route north from 17.0 to 17.2 (about 22.2 km), planned at 30 min.
  final line = [(17.0, 78.0), (17.1, 78.0), (17.2, 78.0)];
  final route = RouteModel(distanceM: 2 * tenth, durationS: 1800, polyline: GeoMath.encodePolyline(line));

  ConvoyModel convoy(Map<String, RiderModel> riders, {RouteModel? r, double destLat = 17.2, double destLng = 78.0, List<StopPointModel> stops = const []}) =>
      ConvoyModel(
        groupId: 'GRP-1',
        name: 'Hill run',
        joinCode: '123456',
        createdByUserId: 'me',
        createdByUserName: 'Me',
        createdAtEpochMs: 0,
        destinationName: 'Top',
        destinationLat: destLat,
        destinationLng: destLng,
        riders: riders,
        route: r,
        stopPoints: stops,
        distanceThresholdMeters: 1000,
      );

  final riders = {
    'me': rider('me', 'Me', 17.05),
    'a': rider('a', 'Arjun', 17.15),
    'b': rider('b', 'Bala', 17.045),
    'k': rider('k', 'Kiran', 17.0),
    'x': rider('x', 'Xavier', 0, lng: 0),
  };

  group('remaining and ETA', () {
    test('remaining is along the route to its end', () {
      final m = RideFacts.remainingM(lat: 17.05, lng: 78.0, line: line, destLat: 17.2, destLng: 78.0);
      expect(m, closeTo(1.5 * tenth, 1));
    });

    test('no route: straight line to the destination; no position or destination: unknown', () {
      final m = RideFacts.remainingM(lat: 17.1, lng: 78.0, line: const [], destLat: 17.2, destLng: 78.0);
      expect(m, closeTo(GeoMath.haversine(17.1, 78.0, 17.2, 78.0), 0.01));
      expect(RideFacts.remainingM(lat: 0, lng: 0, line: line, destLat: 17.2, destLng: 78.0), isNull);
      expect(RideFacts.remainingM(lat: 17.1, lng: 78.0, line: line, destLat: 0, destLng: 0), isNull);
    });

    test('past the end of the route is zero, never negative', () {
      expect(RideFacts.remainingM(lat: 17.3, lng: 78.0, line: line, destLat: 17.2, destLng: 78.0), 0);
    });

    test('ETA uses the pace of the planned route', () {
      // Half the route left: half the planned time.
      expect(RideFacts.etaFor(tenth, route), const Duration(minutes: 15));
      expect(RideFacts.etaFor(null, route), isNull);
      expect(RideFacts.etaFor(tenth, null), isNull);
      expect(RideFacts.etaFor(tenth, RouteModel(distanceM: 0, durationS: 100, polyline: '')), isNull);
    });
  });

  group('ladder', () {
    test('front to back with gaps, too far behind and unknown last', () {
      final c = convoy(riders, r: route);
      final l = RideFacts.ladder(c, 'me');
      expect(l.map((r) => r.rider.userId).toList(), ['a', 'me', 'b', 'k', 'x']);
      expect(l[0].gapAheadM, isNull);
      expect(l[1].gapAheadM, closeTo(tenth, 1)); // Arjun is 11 km ahead of me
      expect(l[1].tooFarBehind, isTrue, reason: 'I am more than 1 km behind the rider ahead');
      expect(l[2].tooFarBehind, isFalse, reason: 'Bala is about 550 m behind me');
      expect(l[3].tooFarBehind, isTrue, reason: 'Kiran is about 5 km behind Bala');
      expect(l[4].progressM, isNull);
      expect(l[4].gapAheadM, isNull);
      expect(l[4].tooFarBehind, isFalse);
    });

    test('ahead and behind me, level riders have no side', () {
      final c = convoy({...riders, 'n': rider('n', 'Near', 17.0501)}, r: route);
      final l = {for (final r in RideFacts.ladder(c, 'me')) r.rider.userId: r};
      expect(l['a']!.ahead, isTrue);
      expect(l['a']!.fromMeM, closeTo(tenth, 1));
      expect(l['k']!.ahead, isFalse);
      expect(l['n']!.ahead, isNull, reason: 'about 11 m apart counts as level');
      expect(l['me']!.fromMeM, isNull);
      expect(l['me']!.isMe, isTrue);
      expect(l['x']!.displayFromMeM, isNull);
    });

    test('without a route the order follows the distance to the destination', () {
      final c = convoy(riders, r: null);
      final l = RideFacts.ladder(c, 'me');
      expect(l.first.rider.userId, 'a');
      expect(l.last.rider.userId, 'x');
      expect(l[1].rider.userId, 'me');
    });

    test('without a route and a destination nobody can be placed', () {
      final c = convoy(riders, r: null, destLat: 0, destLng: 0);
      final l = RideFacts.ladder(c, 'me');
      expect(l.every((r) => r.progressM == null), isTrue);
      expect(l.map((r) => r.rider.name).toList(), ['Arjun', 'Bala', 'Kiran', 'Me', 'Xavier']);
      expect(l.firstWhere((r) => r.rider.userId == 'a').displayFromMeM, closeTo(tenth, 1));
    });
  });

  group('group facts', () {
    test('spread is front to back along the route', () {
      expect(RideFacts.spreadM(convoy(riders, r: route)), closeTo(1.5 * tenth, 1));
    });

    test('spread without a route is the widest pair; one rider has no spread', () {
      expect(RideFacts.spreadM(convoy(riders, r: null)), closeTo(GeoMath.haversine(17.0, 78.0, 17.15, 78.0), 0.01));
      expect(RideFacts.spreadM(convoy({'me': riders['me']!}, r: route)), 0);
    });

    test('riding counts moving riders heard from recently', () {
      final rs = [
        rider('1', 'A', 17, speed: 40),
        rider('2', 'B', 17, speed: 2),
        rider('3', 'C', 17, speed: 50, seen: now - const Duration(minutes: 3).inMilliseconds),
        rider('4', 'D', 17, speed: 5),
      ];
      expect(RideFacts.ridingCount(rs, nowMs: now), 2);
    });

    test('nearby counts other riders within the radius', () {
      final c = convoy(riders, r: route);
      expect(RideFacts.nearbyCount(c, 'me', radiusM: 600), 1); // Bala, about 550 m
      expect(RideFacts.nearbyCount(c, 'me', radiusM: 100), 0);
      expect(RideFacts.nearbyCount(c, 'nobody'), 0);
    });
  });

  group('stopped', () {
    test('stopped after the group stop limit, or at once with a reason', () {
      final s = now - 200000; // 200 s ago
      expect(RideFacts.stoppedFor(rider('me', 'Me', 17, speed: 0, stoppedSince: s), nowMs: now, thresholdSeconds: 180), const Duration(seconds: 200));
      expect(RideFacts.stoppedFor(rider('me', 'Me', 17, speed: 0, stoppedSince: s), nowMs: now, thresholdSeconds: 300), isNull);
      expect(RideFacts.stoppedFor(rider('me', 'Me', 17, speed: 0, stoppedSince: now - 1000, reason: 'FUELING'), nowMs: now, thresholdSeconds: 300),
          const Duration(seconds: 1));
    });

    test('moving or never stopped is riding', () {
      expect(RideFacts.stoppedFor(rider('me', 'Me', 17, speed: 30, stoppedSince: now - 999999), nowMs: now, thresholdSeconds: 60), isNull);
      expect(RideFacts.stoppedFor(rider('me', 'Me', 17, speed: 0), nowMs: now, thresholdSeconds: 60), isNull);
    });
  });

  group('stops', () {
    final stops = [
      StopPointModel(stopId: 's1', name: 'Fuel', lat: 17.02, lng: 78.0, orderIndex: 1, isVisited: true, category: 'FUEL'),
      StopPointModel(stopId: 's2', name: 'Cafe', lat: 17.1, lng: 78.0, orderIndex: 2, category: 'FOOD'),
      StopPointModel(stopId: 's3', name: 'Idea', lat: 17.12, lng: 78.0, orderIndex: 3, status: 'SUGGESTED'),
    ];

    test('next stop is the first planned stop not visited, distance along the route', () {
      final snap = RideFacts.snapshot(convoy(riders, r: route, stops: stops), 'me');
      expect(snap.nextStop?.stopId, 's2');
      expect(snap.nextStopM, closeTo(0.5 * tenth, 1));
      expect(snap.stops.map((e) => e.$1.stopId).toList(), ['s1', 's2']);
      expect(snap.stops.first.$2, isNull, reason: 'visited stops have no distance');
      expect(snap.remainingM, closeTo(1.5 * tenth, 1));
      expect(snap.eta, isNotNull);
      expect(snap.ladder.length, 5);
    });

    test('a stop behind me is measured as the crow flies', () {
      final me = rider('me', 'Me', 17.05);
      expect(RideFacts.distanceToM(me, 17.0, 78.0, line), closeTo(GeoMath.haversine(17.05, 78.0, 17.0, 78.0), 0.01));
      expect(RideFacts.distanceToM(rider('me', 'Me', 0, lng: 0), 17.0, 78.0, line), isNull);
    });
  });

  group('GPS in words', () {
    test('each state', () {
      expect(RideFacts.gpsState(active: false, lastFixMs: now, moving: true, nowMs: now), GpsState.unavailable);
      expect(RideFacts.gpsState(active: true, lastFixMs: now, accuracyM: 80, moving: true, nowMs: now), GpsState.lowAccuracy);
      expect(RideFacts.gpsState(active: true, lastFixMs: now - 20000, accuracyM: 10, moving: true, nowMs: now), GpsState.updating);
      expect(RideFacts.gpsState(active: true, lastFixMs: now - 20000, accuracyM: 10, moving: false, nowMs: now), GpsState.accurate,
          reason: 'stopped: a quiet GPS is normal');
      expect(RideFacts.gpsState(active: true, lastFixMs: 0, moving: false, nowMs: now), GpsState.updating);
      expect(RideFacts.gpsState(active: true, lastFixMs: now - 1000, accuracyM: 12, moving: true, nowMs: now), GpsState.accurate);
      expect(GpsState.values.map((g) => g.label).toList(), ['Accurate', 'Updating', 'Low accuracy', 'Unavailable']);
    });
  });
}
