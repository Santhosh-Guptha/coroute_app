// 3.55 follow-up: the admin convoy inspector, the master admin fleet map and the trip replay use
// the cockpit's once-per-bike plan: a seated pillion rides on their rider's two-up marker.
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/domain/ride/bike_markers.dart';
import 'package:flutter_test/flutter_test.dart';

RiderModel _r(String id, {double lat = 17.4, double lng = 78.4, bool coRiding = false, String withId = '', int seen = 1000, String kind = 'sport'}) => RiderModel(
      userId: id,
      name: id == 'arjun' ? 'Arjun' : (id == 'meera' ? 'Meera' : id),
      vehicleType: 'Motorcycle',
      vehicleNo: coRiding ? 'PILLION' : 'TS09AB1234',
      vehicleColor: 'Red',
      vehicleKind: kind,
      phone: '',
      lat: lat,
      lng: lng,
      speedKmh: 0,
      heading: 0,
      batteryLevel: 90,
      role: 'PACK',
      lastSeenEpochMs: seen,
      isCoRiding: coRiding,
      ridingWithUserId: withId,
    );

void main() {
  group('BikeMarkerPlan.forViewer (admin maps)', () {
    test('a seated pillion has no marker of their own; the pair is one two-up bike', () {
      final riders = {
        'arjun': _r('arjun', kind: 'adventure'),
        'meera': _r('meera', coRiding: true, withId: 'arjun', kind: ''),
        'ravi': _r('ravi', lat: 17.5),
        'nopos': _r('nopos', lat: 0, lng: 0),
      };
      final plan = BikeMarkerPlan.forViewer(riders);
      expect(plan.keys.toSet(), {'arjun', 'ravi'}, reason: 'pillion merged, rider without a position left out');
      final pair = plan['arjun']!;
      expect(pair.twoUp, isTrue);
      expect(pair.pillion!.userId, 'meera');
      expect(pair.bikeRider.vehicleKind, 'adventure', reason: 'the bike look comes from its rider');
      expect(pair.meOnBoard, isFalse, reason: 'nobody is me on an admin map');
      expect(BikeMarkerPlan.nameOf(pair), 'Arjun + Meera');
      expect(BikeMarkerPlan.nameOf(plan['ravi']!), 'ravi');
    });

    test('rider\'s phone lost signal: the pillion\'s fresher position carries the bike', () {
      final riders = {
        'arjun': _r('arjun', seen: 1000),
        'meera': _r('meera', coRiding: true, withId: 'arjun', seen: 60000, lat: 17.41),
      };
      final plan = BikeMarkerPlan.forViewer(riders);
      expect(plan.keys.single, 'meera');
      expect(plan['meera']!.bikeRider.userId, 'arjun');
      expect(plan['meera']!.twoUp, isTrue);
    });

    test('admin switch pillionSeat off: one marker each, as before', () {
      final riders = {'arjun': _r('arjun'), 'meera': _r('meera', coRiding: true, withId: 'arjun')};
      expect(BikeMarkerPlan.forViewer(riders, mergePillions: false).keys.toSet(), {'arjun', 'meera'});
    });
  });

  group('Replay / report markers (BikeMarkerPlan.replayBikes)', () {
    test('seatedPairs from the ride snapshot: pillion -> rider, invalid links left out', () {
      final riders = {
        'arjun': _r('arjun'),
        'meera': _r('meera', coRiding: true, withId: 'arjun'),
        'ghost': _r('ghost', coRiding: true, withId: 'gone'),
        'self': _r('self', coRiding: true, withId: 'self'),
      };
      expect(BikeMarkerPlan.seatedPairs(riders), {'meera': 'arjun'});
    });

    test('together: one two-up marker at the rider; apart: both keep their own', () {
      const pairs = {'meera': 'arjun'};
      final together = BikeMarkerPlan.replayBikes({'arjun': (17.4, 78.4), 'meera': (17.4003, 78.4), 'ravi': (17.5, 78.5)}, pairs);
      expect(together, {'arjun': true, 'ravi': false});
      final apart = BikeMarkerPlan.replayBikes({'arjun': (17.4, 78.4), 'meera': (17.45, 78.4)}, pairs);
      expect(apart, {'arjun': false, 'meera': false}, reason: 'seated later than this moment: not merged');
      final riderSilent = BikeMarkerPlan.replayBikes({'meera': (17.4, 78.4)}, pairs);
      expect(riderSilent, {'meera': true}, reason: 'the pillion carries the bike while the rider has no track');
      expect(BikeMarkerPlan.replayBikes({'arjun': (17.4, 78.4)}, const {}), {'arjun': false});
    });
  });
}
