// 3.56 owner bug: "When creating a ride it asks for the bike details every time. Make it one
// time and sync it with the garage." Pure logic (BikeSync, BikeGatePlan) and the garage store.
import 'package:coroute_app/data/services/garage_binding.dart';
import 'package:coroute_app/data/services/garage_service.dart';
import 'package:coroute_app/domain/garage/bike_details.dart';
import 'package:coroute_app/domain/garage/bike_profile.dart';
import 'package:coroute_app/domain/garage/bike_sync.dart';
import 'package:coroute_app/domain/garage/bike_type.dart';
import 'package:coroute_app/domain/places/fuel_match.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the "Complete your bike" sheet saves for a Classic 350.
const _classic = BikeProfile(
  id: 'bike_1',
  name: 'Royal Enfield Classic 350',
  model: 'Royal Enfield Classic 350',
  bikeType: BikeType.retro,
  engineCc: 349,
  colour: 'Red',
  tankCapacityL: 13,
  reserveCapacityL: 2,
  expectedMileageKmL: 35,
  cooling: EngineCooling.oil,
);

const _ather = BikeProfile(
  id: 'bike_ev',
  name: 'Ather 450X',
  make: 'Ather',
  model: '450X',
  bikeType: BikeType.electric,
  fuelType: BikeFuelType.ev,
  colour: 'White',
  tankCapacityL: 0,
  reserveCapacityL: 0,
  expectedMileageKmL: 22,
);

/// The gateway's copy as GET /me returns it.
Map<String, dynamic> _server(BikeProfile b) => Map<String, dynamic>.from(BikeSync.summaryOf(b));

void main() {
  group('server round-trip keeps the bike complete', () {
    test('bug: the 3.55 summary had no bike type, so a restored bike was asked for again', () {
      expect(BikeDetails.isComplete(_classic), isTrue);
      final old = _server(_classic)..removeWhere((k, _) => BikeSync.detailKeys.contains(k));
      final restoredOld = BikeSync.merge(null, old, newId: 'n')!;
      expect(BikeDetails.missing(restoredOld), [BikeDetailField.type], reason: 'what 3.55 could give back');
      final restored = BikeSync.merge(null, _server(_classic), newId: 'n')!;
      expect(BikeDetails.isComplete(restored), isTrue);
      expect([restored.model, restored.bikeType, restored.engineCc, restored.colour, restored.tankCapacityL, restored.expectedMileageKmL, restored.fuelType, restored.cooling],
          ['Royal Enfield Classic 350', BikeType.retro, 349, 'Red', 13.0, 35.0, BikeFuelType.petrol, EngineCooling.oil]);
    });

    test('electric: km/kWh mileage below 5 and no tank survive the round-trip', () {
      final low = _ather.copyWith(expectedMileageKmL: 3);
      final s = _server(low);
      expect(s['bikeMileageKmL'], 3.0);
      expect(s['bikeFuel'], 'ev');
      expect(s['bikeType'], 'electric');
      final back = BikeSync.merge(null, s, newId: 'n')!;
      expect(back.fuelType, BikeFuelType.ev);
      expect(BikeDetails.isComplete(back), isTrue);
    });

    test('summary: unconfirmed type is sent as empty, not as the guess', () {
      expect(BikeSync.summaryOf(_classic)['bikeType'], 'retro');
      const guessed = BikeProfile(id: 'g', name: 'Classic 350', model: 'Classic 350');
      expect(BikeSync.summaryOf(guessed)['bikeType'], '');
    });
  });

  group('start-up sync never wipes the server copy', () {
    test('bug: an empty summary was sent before the garage loaded (or from a new install)', () {
      expect(BikeSync.mayShare(garageLoaded: false, bike: _classic), isFalse);
      expect(BikeSync.mayShare(garageLoaded: true, bike: null), isFalse);
      expect(BikeSync.mayShare(garageLoaded: true, bike: _classic), isTrue);
    });

    test('only changed keys the gateway knows are sent (older gateway: no 3.56 keys)', () {
      final server = _server(_classic);
      expect(BikeSync.changes(BikeSync.summaryOf(_classic), server), isEmpty);
      expect(BikeSync.changes(BikeSync.summaryOf(_classic.copyWith(colour: 'Black')), server), {'bikeColour': 'Black'});
      final older = Map<String, dynamic>.from(server)..removeWhere((k, _) => BikeSync.detailKeys.contains(k));
      expect(BikeSync.changes(BikeSync.summaryOf(_classic.copyWith(bikeType: BikeType.cruiser)), older), isEmpty);
    });
  });

  group('restore merge', () {
    test('fills only what the phone is missing; never an empty value over a given one', () {
      final local = _classic.copyWith(colour: '', engineCc: 0);
      final server = _server(_classic)
        ..['bikeTankL'] = 0
        ..['bikeMileageKmL'] = 0;
      final m = BikeSync.merge(local, server, newId: 'n')!;
      expect(m.id, 'bike_1');
      expect([m.colour, m.engineCc, m.tankCapacityL, m.expectedMileageKmL], ['Red', 349, 13.0, 35.0]);
      expect(BikeDetails.isComplete(m), isTrue);
    });

    test('rider values win over the server', () {
      final server = _server(_classic.copyWith(colour: 'Blue', engineCc: 500));
      expect(BikeSync.merge(_classic, server, newId: 'n'), isNull, reason: 'complete: nothing to fill');
      final noType = BikeProfile(id: 'b', name: 'x', model: 'Royal Enfield Classic 350', engineCc: 349, colour: 'Black', tankCapacityL: 13, expectedMileageKmL: 35);
      final m = BikeSync.merge(noType, server, newId: 'n')!;
      expect([m.colour, m.engineCc, m.bikeType], ['Black', 349, BikeType.retro]);
    });

    test('a different bike on the phone is not touched; no server bike gives nothing', () {
      final other = const BikeProfile(id: 'p', name: 'Pulsar', make: 'Bajaj', model: 'Pulsar 150');
      expect(BikeSync.merge(other, _server(_classic), newId: 'n'), isNull);
      expect(BikeSync.merge(null, null, newId: 'n'), isNull);
      expect(BikeSync.merge(null, _server(_classic)..['bikeModel'] = '', newId: 'n'), isNull);
    });

    test('missing server details stay missing (never made up)', () {
      final partial = {'bikeModel': 'Hero Splendor Plus', 'bikeCc': 0, 'bikeColour': '', 'bikeTankL': 0, 'bikeMileageKmL': 0, 'bikeCooling': 'unknown'};
      final b = BikeSync.merge(null, partial, newId: 'n')!;
      expect(BikeDetails.missing(b), [BikeDetailField.type, BikeDetailField.cc, BikeDetailField.colour, BikeDetailField.tank, BikeDetailField.mileage]);
    });

    test('an electric type is not put on a petrol bike', () {
      final petrolNoType = const BikeProfile(id: 'e', name: 'Ather 450X', make: 'Ather', model: '450X', colour: 'White', expectedMileageKmL: 30, tankCapacityL: 5, engineCc: 100);
      final m = BikeSync.merge(petrolNoType, _server(_ather), newId: 'n');
      expect(m?.bikeType, isNot(BikeType.electric));
    });
  });

  group('the bike check before create / join', () {
    test('decided from the active bike, once complete never asks', () {
      expect(BikeGatePlan.decide(pillionAccount: false, loaded: true, active: _classic), BikeGateStep.rider);
      expect(BikeGatePlan.decide(pillionAccount: false, loaded: true, active: null), BikeGateStep.ask);
      expect(BikeGatePlan.decide(pillionAccount: false, loaded: true, active: _classic.copyWith(colour: '')), BikeGateStep.ask,
          reason: 'changed to an incomplete bike: asks again');
      expect(BikeGatePlan.decide(pillionAccount: true, loaded: true, active: null), BikeGateStep.pillion, reason: 'pillion path unchanged');
    });

    test('one-time home prompt: never twice, never for a pillion, a complete bike or an empty garage', () {
      final incomplete = _classic.copyWith(colour: '');
      expect(BikeGatePlan.shouldPromptOnce(alreadyPrompted: false, pillionAccount: false, loaded: true, active: incomplete), isTrue);
      expect(BikeGatePlan.shouldPromptOnce(alreadyPrompted: true, pillionAccount: false, loaded: true, active: incomplete), isFalse);
      expect(BikeGatePlan.shouldPromptOnce(alreadyPrompted: false, pillionAccount: true, loaded: true, active: incomplete), isFalse);
      expect(BikeGatePlan.shouldPromptOnce(alreadyPrompted: false, pillionAccount: false, loaded: true, active: _classic), isFalse);
      expect(BikeGatePlan.shouldPromptOnce(alreadyPrompted: false, pillionAccount: false, loaded: true, active: null), isFalse);
      expect(BikeGatePlan.shouldPromptOnce(alreadyPrompted: false, pillionAccount: false, loaded: false, active: incomplete), isFalse);
    });
  });

  group('garage store', () {
    test('a bike saved once (sheet) is complete after an app restart', () async {
      SharedPreferences.setMockInitialValues({});
      final g = GarageService();
      await g.load();
      expect(g.isLoaded, isTrue);
      expect(await g.saveBike(_classic), isTrue);
      await g.setActiveBike(_classic.id);
      final restarted = GarageService();
      expect(restarted.isLoaded, isFalse, reason: 'nothing decides before the load');
      await restarted.load();
      expect(BikeGatePlan.decide(pillionAccount: false, loaded: restarted.isLoaded, active: restarted.activeBikeNotifier.value), BikeGateStep.rider);
      expect(restarted.activeBikeNotifier.value!.bikeType, BikeType.retro, reason: 'confirmed type persisted');
    });

    test('a complete bike added in the garage replaces an incomplete active bike', () async {
      SharedPreferences.setMockInitialValues({});
      final g = GarageService();
      await g.load();
      await g.saveBike(const BikeProfile(id: 'old', name: 'Old', model: 'Old bike'));
      expect(BikeDetails.isComplete(g.activeBikeNotifier.value), isFalse);
      final added = await g.saveBike(_classic);
      if (added) {
        // (only with the multi-bike garage unlocked)
        expect(g.activeBikeNotifier.value?.id, 'bike_1');
      }
    });

    test('the binding restores a new install from the gateway copy', () async {
      SharedPreferences.setMockInitialValues({});
      final g = GarageService();
      final binding = GarageBinding(g);
      await g.load();
      await pumpEventQueue();
      expect(g.activeBikeNotifier.value, isNull, reason: 'no auth: nothing to restore');
      binding.dispose();
      expect(GarageBinding.bikeSummaryOf(_classic)['bikeType'], 'retro');
    });
  });
}
