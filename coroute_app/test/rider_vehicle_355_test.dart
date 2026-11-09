// 3.55 live bike change: RIDER_VEHICLE built from the garage bike (gateway twin:
// gateway/test/rider_vehicle_355.test.js).
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/rider_vehicle.dart';
import 'package:coroute_app/data/services/garage_binding.dart';
import 'package:coroute_app/domain/garage/bike_profile.dart';

void main() {
  final me = RiderModel(userId: 'u1', name: 'Ravi', lat: 0, lng: 0, lastSeenEpochMs: 0, vehicleColor: 'Red', vehicleModel: 'Classic 350');

  group('RiderVehicle.cleanColour', () {
    test('colour names and #RRGGBB pass, anything else is dropped', () {
      expect(RiderVehicle.cleanColour('  Kaza   Brown '), 'Kaza Brown');
      expect(RiderVehicle.cleanColour('#a1b2c3'), '#A1B2C3');
      expect(RiderVehicle.cleanColour('#12345'), '');
      expect(RiderVehicle.cleanColour('1Red'), '');
      expect(RiderVehicle.cleanColour('<b>'), '');
      expect(RiderVehicle.cleanColour('c' * 21), '');
      expect(RiderVehicle.cleanColour(''), '');
    });
  });

  group('RiderVehicle.cleanModel', () {
    test('control characters out, at most 40 characters', () {
      expect(RiderVehicle.cleanModel(' Himalayan\n 450 '), 'Himalayan 450');
      expect(RiderVehicle.cleanModel('m' * 50).length, RiderVehicle.modelMax);
      expect(RiderVehicle.cleanModel('Duke\u202E 390'), 'Duke 390');
    });
  });

  group('RiderVehicle.message', () {
    test('only what changed, nothing when equal', () {
      expect(RiderVehicle.message(me: me, colour: 'Red', model: 'Classic 350'), isNull);
      expect(RiderVehicle.message(me: me, colour: 'Gunmetal Grey', model: 'Classic 350'),
          {'type': 'RIDER_VEHICLE', 'vehicleColor': 'Gunmetal Grey'});
      expect(RiderVehicle.message(me: me, colour: 'Red', model: 'Interceptor 650'),
          {'type': 'RIDER_VEHICLE', 'vehicleModel': 'Interceptor 650'});
    });

    test('unusable values are left out; a pillion sends nothing', () {
      expect(RiderVehicle.message(me: me, colour: '', model: ''), isNull);
      expect(RiderVehicle.message(me: me, colour: '<bad>', model: 'Duke 390'), {'type': 'RIDER_VEHICLE', 'vehicleModel': 'Duke 390'});
      expect(RiderVehicle.message(me: me.copyWith(isCoRiding: true), colour: 'Blue', model: ''), isNull);
      expect(RiderVehicle.message(me: me.copyWith(vehicleNo: 'PILLION'), colour: 'Blue', model: ''), isNull);
    });
  });

  test('waitBeforeSend keeps one send per 10 s', () {
    final t0 = DateTime(2026, 11, 9, 10);
    expect(RiderVehicle.waitBeforeSend(null, t0), Duration.zero);
    expect(RiderVehicle.waitBeforeSend(t0, t0.add(const Duration(seconds: 4))), const Duration(seconds: 6));
    expect(RiderVehicle.waitBeforeSend(t0, t0.add(const Duration(seconds: 11))), Duration.zero);
  });

  test('final refusals stop sending; the rate refusal and FEATURE_OFF do not', () {
    for (final r in ['BIKE_SWAPPED', 'PILLION_RIDER', 'BAD_VEHICLE']) {
      expect(RiderVehicle.isFinalRefusal(r), isTrue, reason: r);
    }
    expect(RiderVehicle.isFinalRefusal('VEHICLE_RATE'), isFalse);
    expect(RiderVehicle.isFinalRefusal('FEATURE_OFF'), isFalse);
  });

  test('GarageBinding.vehicleModelOf: make and model, else the name', () {
    expect(GarageBinding.vehicleModelOf(null), '');
    expect(GarageBinding.vehicleModelOf(const BikeProfile(id: 'a', name: 'My bike', make: 'Royal Enfield', model: 'Himalayan 450')),
        'Royal Enfield Himalayan 450');
    expect(GarageBinding.vehicleModelOf(const BikeProfile(id: 'a', name: 'Blue beast')), 'Blue beast');
    expect(GarageBinding.vehicleModelOf(BikeProfile(id: 'a', name: 'n' * 60)).length, 40);
  });

  test('RiderModel reads vehicleModel (missing: empty)', () {
    expect(RiderModel.fromJson({'userId': 'u', 'name': 'n', 'vehicleModel': 'Duke 390'}).vehicleModel, 'Duke 390');
    expect(RiderModel.fromJson({'userId': 'u', 'name': 'n'}).vehicleModel, '');
  });
}
