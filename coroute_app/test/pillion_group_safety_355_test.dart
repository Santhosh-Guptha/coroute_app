// 3.55 integration: a seated pillion is counted once per bike in the group-safety checks
// (missing-rider check, group spread / break, buddy pairs) and in the roll call.
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/domain/ride/bike_markers.dart';
import 'package:coroute_app/presentation/ride/roll_call_card.dart';
import 'package:flutter_test/flutter_test.dart';

RiderModel _r(String id, {double lat = 17.4, double lng = 78.4, String withId = '', int seen = 1000, double speed = 0}) => RiderModel(
      userId: id,
      name: id,
      lat: lat,
      lng: lng,
      speedKmh: speed,
      lastSeenEpochMs: seen,
      isCoRiding: withId.isNotEmpty,
      ridingWithUserId: withId,
    );

Map<String, RiderModel> _m(List<RiderModel> l) => {for (final r in l) r.userId: r};

void main() {
  group('safetyRoster', () {
    test('a seated pillion is left out; their rider stands for the bike', () {
      final riders = _m([_r('A'), _r('R'), _r('P', withId: 'R'), _r('S')]);
      expect(BikeMarkerPlan.safetyRoster(riders, meId: 'A').map((r) => r.userId), ['A', 'R', 'S']);
      expect(BikeMarkerPlan.countedOncePerBike(riders).length, 3);
    });

    test('on the pillion\'s own phone: the pillion is kept and their rider left out', () {
      final riders = _m([_r('A'), _r('R'), _r('P', withId: 'R')]);
      expect(BikeMarkerPlan.safetyRoster(riders, meId: 'P').map((r) => r.userId).toSet(), {'A', 'P'});
      // On the rider's phone the pillion is not one of the "others".
      expect(BikeMarkerPlan.safetyRoster(riders, meId: 'R').map((r) => r.userId).toSet(), {'A', 'R'});
    });

    test('rider\'s phone went quiet: the bike carries the pillion\'s fresher position', () {
      final riders = _m([_r('R', lat: 17.0, seen: 1000), _r('P', lat: 17.2, withId: 'R', seen: 60000, speed: 40)]);
      final bike = BikeMarkerPlan.safetyRoster(riders, meId: 'X').single;
      expect(bike.userId, 'R');
      expect(bike.lat, 17.2);
      expect(bike.lastSeenEpochMs, 60000);
      expect(bike.speedKmh, 40);
      // Both fresh: the rider's own position.
      final fresh = _m([_r('R', lat: 17.0, seen: 50000), _r('P', lat: 17.2, withId: 'R', seen: 60000)]);
      expect(BikeMarkerPlan.safetyRoster(fresh, meId: 'X').single.lat, 17.0);
    });

    test('no valid link (self, missing rider, rider is a pillion): counted as their own bike', () {
      final riders = _m([_r('X', withId: 'X'), _r('Y', withId: 'gone'), _r('Q', withId: 'Z'), _r('Z', withId: 'W')]);
      expect(BikeMarkerPlan.safetyRoster(riders).length, 4);
    });

    test('partnerOf finds the other person on the bike both ways', () {
      final riders = _m([_r('R'), _r('P', withId: 'R'), _r('S')]);
      expect(BikeMarkerPlan.partnerOf('R', riders)?.userId, 'P');
      expect(BikeMarkerPlan.partnerOf('P', riders)?.userId, 'R');
      expect(BikeMarkerPlan.partnerOf('S', riders), isNull);
    });
  });

  group('roll call', () {
    ConvoyModel convoy(Map<String, RiderModel> riders, {Map<String, StopArrival> arrivals = const {}}) => ConvoyModel(
          groupId: 'GRP-1',
          name: 'Ride',
          joinCode: '123456',
          tripStatus: 'STARTED',
          createdByUserId: 'R',
          createdByUserName: 'R',
          createdAtEpochMs: 1000,
          riders: riders,
          destinationArrivals: arrivals,
        );

    test('a seated pillion arrives with their bike', () {
      final c = convoy(_m([_r('R'), _r('P', withId: 'R'), _r('S')]), arrivals: {'R': const StopArrival(arrivedAt: 5000)});
      expect(RollCallCard.inputFor(c, c.riders['P']!).arrivedAtMs, 5000);
      expect(RollCallCard.inputFor(c, c.riders['S']!).arrivedAtMs, 0);
    });

    test('a seated pillion without a position of their own joined with the bike', () {
      final c = convoy(_m([_r('R', seen: 9000), _r('P', lat: 0, lng: 0, withId: 'R', seen: 0)]));
      final p = RollCallCard.inputFor(c, c.riders['P']!);
      expect(p.hasPosition, isTrue);
      expect(p.lastSeenMs, 9000);
    });
  });
}
