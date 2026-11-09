// 3.55 garage: bike details (cc, colour, cooling), engine care, no sample bike, the shared
// garage feeding engine care / fuel / the profile summary, and the admin "Bike" line.
import 'dart:convert';

import 'package:coroute_app/data/services/garage_binding.dart';
import 'package:coroute_app/data/services/garage_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/weather_service.dart';
import 'package:coroute_app/domain/garage/bike_input.dart';
import 'package:coroute_app/domain/garage/bike_profile.dart';
import 'package:coroute_app/domain/garage/engine_care.dart';
import 'package:coroute_app/domain/places/fuel_match.dart';
import 'package:coroute_app/domain/safety/fuel_profile.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/admin/admin_rider_insights.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _keyBikes = 'coroute_garage_bikes_v1';
const _keyActive = 'coroute_garage_active_bike_id';

/// The sample bike versions before 3.55 put in every new garage, as it was stored.
const _legacySeed = BikeProfile(
  id: 'bike_default_01',
  name: 'Royal Enfield Himalayan 450',
  make: 'Royal Enfield',
  model: 'Himalayan 450',
  year: 2024,
  tankCapacityL: 17.0,
  reserveCapacityL: 3.5,
  expectedMileageKmL: 28.0,
  isDefault: true,
);

const _pulsar = BikeProfile(
  id: 'bike_pulsar',
  name: 'My Pulsar',
  make: 'Bajaj',
  model: 'Pulsar 150',
  tankCapacityL: 15,
  reserveCapacityL: 3.2,
  expectedMileageKmL: 45,
  engineCc: 149,
  colour: 'Black',
  cooling: EngineCooling.air,
);

const _start = 1700000000000;
TrackPoint _fix(int minute, double kmh, {int second = 0}) =>
    TrackPoint(ts: _start + minute * 60000 + second * 1000, lat: 17.4, lng: 78.5, speedKmh: kmh);

/// Fixes every 30 s from [fromMin] (inclusive) to [toMin] (exclusive); the advice given.
List<EngineCareAdvice> _ride(EngineCareAdvisor a, int fromMin, int toMin, double kmh) {
  final out = <EngineCareAdvice>[];
  for (var m = fromMin; m < toMin; m++) {
    for (final s in const [0, 30]) {
      final advice = a.onFix(_fix(m, kmh, second: s));
      if (advice != null) out.add(advice);
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BikeProfile details', () {
    test('json round trip keeps cc, colour and cooling', () {
      final back = BikeProfile.fromJson(jsonDecode(jsonEncode(_pulsar.toJson())) as Map<String, dynamic>);
      expect(back.engineCc, 149);
      expect(back.colour, 'Black');
      expect(back.cooling, EngineCooling.air);
      expect(back.tankCapacityL, 15);
      expect(back.fuelType, BikeFuelType.petrol);
    });

    test('old json without the new fields still loads (empty details)', () {
      final old = {
        'id': 'bike_old',
        'name': 'Old Bike',
        'make': 'Hero',
        'model': 'Splendor',
        'year': 2019,
        'tankCapacityL': 9.8,
        'reserveCapacityL': 1.5,
        'expectedMileageKmL': 60,
        'totalOdometerKm': 42000,
        'serviceIntervalKm': 3000,
        'lastServiceOdometerKm': 41000,
        'notes': '',
        'isDefault': false,
      };
      final b = BikeProfile.fromJson(old);
      expect(b.engineCc, 0);
      expect(b.colour, '');
      expect(b.cooling, EngineCooling.unknown);
      expect(b.effectiveCooling, EngineCooling.unknown);
      expect(b.fuelType, BikeFuelType.petrol);
      // Not written back when not given.
      expect(b.toJson().containsKey('engineCc'), isFalse);
      expect(b.toJson().containsKey('cooling'), isFalse);
      expect(EngineCooling.parse('nonsense'), EngineCooling.unknown);
    });

    test('effectiveCooling: given wins, else a guess from cc', () {
      expect(const BikeProfile(id: 'a', name: 'a', engineCc: 150).effectiveCooling, EngineCooling.air);
      expect(const BikeProfile(id: 'a', name: 'a', engineCc: 400).effectiveCooling, EngineCooling.liquid);
      expect(const BikeProfile(id: 'a', name: 'a', engineCc: 150, cooling: EngineCooling.liquid).effectiveCooling,
          EngineCooling.liquid);
      expect(const BikeProfile(id: 'a', name: 'a').effectiveCooling, EngineCooling.unknown);
    });

    test('every preset has an engine size and a cooling type (electric ones: neither)', () {
      for (final p in BikeProfile.popularPresets) {
        expect(p.bikeType, isNotNull, reason: p.name);
        if (p.fuelType == BikeFuelType.ev) {
          expect(p.reserveCapacityL, lessThan(p.tankCapacityL), reason: p.name);
          continue;
        }
        expect(p.engineCc, greaterThanOrEqualTo(50), reason: p.name);
        expect(p.cooling, isNot(EngineCooling.unknown), reason: p.name);
        expect(p.reserveCapacityL, lessThan(p.tankCapacityL), reason: p.name);
      }
      expect(BikeProfile.popularPresets.map((p) => p.id).toSet().length, BikeProfile.popularPresets.length);
    });
  });

  group('engineRestAfter', () {
    test('by cooling type and engine size', () {
      expect(engineRestAfter(const BikeProfile(id: 'a', name: 'a', engineCc: 110, cooling: EngineCooling.air)),
          const Duration(minutes: 60));
      expect(engineRestAfter(const BikeProfile(id: 'a', name: 'a', engineCc: 150, cooling: EngineCooling.air)),
          const Duration(minutes: 75));
      expect(engineRestAfter(const BikeProfile(id: 'a', name: 'a', cooling: EngineCooling.oil)), const Duration(minutes: 90));
      expect(engineRestAfter(const BikeProfile(id: 'a', name: 'a', cooling: EngineCooling.liquid)),
          const Duration(minutes: 120));
      expect(engineRestAfter(const BikeProfile(id: 'a', name: 'a')), isNull, reason: 'unknown cooling: no advice');
    });

    test('heat shortens it; electric has none', () {
      const air = BikeProfile(id: 'a', name: 'a', engineCc: 150, cooling: EngineCooling.air);
      expect(engineRestAfter(air, airTempC: 34), const Duration(minutes: 75));
      expect(engineRestAfter(air, airTempC: 38), const Duration(minutes: 56));
      expect(engineRestAfter(const BikeProfile(id: 'e', name: 'e', fuelType: BikeFuelType.ev, cooling: EngineCooling.liquid)),
          isNull);
      expect(engineRestMinutes(air), 15);
      expect(engineRestMinutes(const BikeProfile(id: 'l', name: 'l', cooling: EngineCooling.liquid)), 10);
    });
  });

  group('EngineCareAdvisor', () {
    test('advises once after the limit at 60 km/h or more', () {
      final a = EngineCareAdvisor()..bike = _pulsar; // air, 149 cc: 75 min
      expect(_ride(a, 0, 74, 70), isEmpty);
      final advice = _ride(a, 74, 140, 70);
      expect(advice, hasLength(1));
      expect(advice.single.title, 'Give your engine a rest');
      expect(advice.single.message, contains('15-minute'));
      expect(advice.single.message, contains('air-cooled'));
    });

    test('below 60 km/h is not hard riding', () {
      final a = EngineCareAdvisor()..bike = _pulsar;
      expect(_ride(a, 0, 200, 50), isEmpty);
    });

    test('a stop of 8 minutes resets the stretch; a shorter one does not', () {
      final a = EngineCareAdvisor()..bike = _pulsar;
      expect(_ride(a, 0, 80, 70), hasLength(1));
      // 7-minute stop, then hard again: still the same stretch (already advised).
      expect(_ride(a, 80, 87, 0), isEmpty);
      expect(_ride(a, 87, 170, 70), isEmpty);
      // 8-minute stop: a new stretch, advised again after another 75 minutes.
      expect(_ride(a, 170, 179, 0), isEmpty);
      expect(_ride(a, 179, 253, 70), isEmpty);
      expect(_ride(a, 253, 260, 70), hasLength(1));
    });

    test('a long gap without fixes counts as parked', () {
      final a = EngineCareAdvisor()..bike = _pulsar;
      expect(_ride(a, 0, 60, 70), isEmpty);
      // Phone off for 10 minutes, then riding again: the stretch starts over.
      expect(_ride(a, 70, 140, 70), isEmpty);
      expect(_ride(a, 140, 150, 70), hasLength(1));
    });

    test('no advice without a bike or with unknown cooling', () {
      final none = EngineCareAdvisor();
      expect(_ride(none, 0, 300, 90), isEmpty);
      final unknown = EngineCareAdvisor()..bike = const BikeProfile(id: 'u', name: 'u');
      expect(_ride(unknown, 0, 300, 90), isEmpty);
    });

    test('heat from the weather check brings it forward', () {
      final a = EngineCareAdvisor()
        ..bike = _pulsar
        ..airTempC = 40; // 75 → 56 min
      expect(_ride(a, 0, 56, 70), isEmpty);
      expect(_ride(a, 56, 58, 70), hasLength(1));
    });
  });

  group('validateBikeInput', () {
    Map<String, String> check({
      String name = 'My bike',
      String cc = '',
      String tank = '13',
      String reserve = '2.5',
      String mileage = '35',
      String odometer = '0',
      String unit = 'L',
    }) =>
        validateBikeInput(name: name, cc: cc, tank: tank, reserve: reserve, mileage: mileage, odometer: odometer, unit: unit);

    test('good input passes; cc may be empty', () {
      expect(check(), isEmpty);
      expect(check(cc: '349', odometer: ''), isEmpty);
      expect(check(tank: '13,5'), isEmpty, reason: 'comma decimals');
      expect(check(cc: '50', tank: '2', reserve: '0', mileage: '120'), isEmpty);
      expect(check(cc: '2500', tank: '40', mileage: '5'), isEmpty);
    });

    test('friendly errors per field', () {
      expect(check(name: '  ')['name'], 'Give your bike a name');
      expect(check(cc: '49')['cc'], contains('50 to 2500'));
      expect(check(cc: '2501')['cc'], isNotNull);
      expect(check(cc: '349.5')['cc'], isNotNull);
      expect(check(cc: 'abc')['cc'], isNotNull);
      expect(check(tank: '1.5')['tank'], 'Tank holds 2 to 40 L');
      expect(check(tank: '41')['tank'], isNotNull);
      expect(check(tank: '')['tank'], isNotNull);
      expect(check(reserve: '13')['reserve'], 'Reserve must be less than the tank');
      expect(check(reserve: '-1')['reserve'], isNotNull);
      expect(check(mileage: '4')['mileage'], 'Mileage is 5 to 120 km/L');
      expect(check(mileage: '121', unit: 'kWh')['mileage'], 'Mileage is 5 to 120 km/kWh');
      expect(check(odometer: '-5')['odometer'], "Odometer can't be negative");
      expect(check(odometer: 'x')['odometer'], isNotNull);
    });

    test('electric bikes skip the engine size check', () {
      expect(validateBikeInput(name: 'EV', cc: '10', tank: '4', reserve: '0.5', mileage: '30', odometer: '0', checkCc: false),
          isEmpty);
    });
  });

  group('GarageService (no sample bike)', () {
    test('an untouched legacy sample bike is removed and the active id cleared', () async {
      SharedPreferences.setMockInitialValues({
        _keyBikes: [jsonEncode(_legacySeed.toJson())],
        _keyActive: 'bike_default_01',
      });
      final g = GarageService();
      await g.load();
      expect(g.bikesNotifier.value, isEmpty);
      expect(g.activeBikeNotifier.value, isNull);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getStringList(_keyBikes), isEmpty);
      expect(sp.getString(_keyActive), isNull);
      expect(await GarageService.readActiveBike(), isNull);
    });

    test('readActiveBike skips the legacy sample bike before the garage was opened', () async {
      SharedPreferences.setMockInitialValues({
        _keyBikes: [jsonEncode(_legacySeed.toJson()), jsonEncode(_pulsar.toJson())],
        _keyActive: 'bike_default_01',
      });
      expect((await GarageService.readActiveBike())?.id, 'bike_pulsar');
    });

    test('the sample bike next to the rider\'s own: only the rider\'s stays, and is active', () async {
      SharedPreferences.setMockInitialValues({
        _keyBikes: [jsonEncode(_legacySeed.toJson()), jsonEncode(_pulsar.toJson())],
        _keyActive: 'bike_default_01',
      });
      final g = GarageService();
      await g.load();
      expect(g.bikesNotifier.value.map((b) => b.id), ['bike_pulsar']);
      expect(g.activeBikeNotifier.value?.id, 'bike_pulsar');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(_keyActive), 'bike_pulsar');
    });

    test('a sample bike the rider used (odometer, service, notes) is kept', () async {
      for (final used in [
        _legacySeed.copyWith(totalOdometerKm: 1200),
        _legacySeed.copyWith(lastServiceOdometerKm: 10),
        _legacySeed.copyWith(notes: 'Mine now'),
        _legacySeed.copyWith(name: 'My Himalayan'),
      ]) {
        expect(GarageService.isLegacySeed(used), isFalse);
        SharedPreferences.setMockInitialValues({
          _keyBikes: [jsonEncode(used.toJson())],
          _keyActive: 'bike_default_01',
        });
        final g = GarageService();
        await g.load();
        expect(g.bikesNotifier.value, hasLength(1));
        expect(g.activeBikeNotifier.value?.id, 'bike_default_01');
      }
      expect(GarageService.isLegacySeed(_legacySeed), isTrue);
    });

    test('editing a bike keeps its id, odometer and service history', () async {
      SharedPreferences.setMockInitialValues({});
      final g = GarageService();
      await g.load();
      final mine = _pulsar.copyWith(totalOdometerKm: 8000, lastServiceOdometerKm: 6000, notes: 'Chain new');
      expect(await g.saveBike(mine), isTrue);
      expect(await g.saveBike(mine.copyWith(colour: 'Red', engineCc: 150)), isTrue);
      expect(g.bikesNotifier.value, hasLength(1));
      final b = g.activeBikeNotifier.value!;
      expect([b.id, b.colour, b.engineCc, b.totalOdometerKm, b.lastServiceOdometerKm, b.notes],
          ['bike_pulsar', 'Red', 150, 8000, 6000, 'Chain new']);
      final stored = await GarageService.readActiveBike();
      expect(stored?.colour, 'Red');
    });
  });

  group('GarageBinding', () {
    test('the active bike goes to engine care and the ride colour; changes follow', () async {
      SharedPreferences.setMockInitialValues({});
      final g = GarageService();
      final care = EngineCareAdvisor();
      final colours = <String>[];
      final binding = GarageBinding(g, engineCare: care, onVehicleColour: colours.add);
      await g.load();
      await pumpEventQueue();
      expect(care.bike, isNull, reason: 'empty garage: no advice');
      expect(colours.last, '');
      await g.saveBike(_pulsar);
      expect(care.bike?.id, 'bike_pulsar');
      expect(colours.last, 'Black');
      await g.saveBike(_pulsar.copyWith(colour: 'Matte Blue With Long Name Stripes'));
      expect(colours.last.length, lessThanOrEqualTo(20));
      binding.dispose();
      await g.saveBike(_pulsar.copyWith(colour: 'Red'));
      expect(colours.last, isNot('Red'), reason: 'disposed');
    });

    test('summary for the gateway stays inside its ranges', () {
      expect(GarageBinding.bikeSummaryOf(_pulsar), {
        'bikeModel': 'Bajaj Pulsar 150',
        'bikeCc': 149,
        'bikeColour': 'Black',
        'bikeTankL': 15.0,
        'bikeMileageKmL': 45.0,
        'bikeCooling': 'air',
      });
      final odd = GarageBinding.bikeSummaryOf(const BikeProfile(
          id: 'x', name: 'Big tank', tankCapacityL: 60, expectedMileageKmL: 200, engineCc: 30, colour: 'red\nline'));
      expect(odd['bikeModel'], 'Big tank');
      expect(odd['bikeCc'], 0);
      expect(odd['bikeTankL'], 0);
      expect(odd['bikeMileageKmL'], 0);
      expect(odd['bikeColour'], 'red line');
      expect(odd['bikeCooling'], 'unknown');
      expect(GarageBinding.bikeSummaryOf(null)['bikeModel'], '');
    });

    test('fuel profile from the bike', () {
      final p = GarageBinding.fuelProfileOf(_pulsar)!;
      expect(p.litresMode, isTrue);
      expect(p.rangeKm, 15 * 45);
      expect(p.reserveL, 3.2);
      expect(GarageBinding.fuelProfileOf(const BikeProfile(id: 'z', name: 'z', tankCapacityL: 0)), isNull);
    });
  });

  group('SettingsService.adoptGarageFuelProfile', () {
    test('fills an empty profile, follows the garage, and never replaces the rider\'s own', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      expect(await s.adoptGarageFuelProfile(GarageBinding.fuelProfileOf(_pulsar)!), isFalse, reason: 'nobody signed in');
      await s.selectFuelUser('usr_1');
      expect(s.hasFuelProfile, isFalse);

      expect(await s.adoptGarageFuelProfile(GarageBinding.fuelProfileOf(_pulsar)!), isTrue);
      expect(s.hasFuelProfile, isTrue);
      expect(s.fuelProfile.rangeKm, 15 * 45);
      // A bike change or edit updates a garage-filled profile.
      final edited = GarageBinding.fuelProfileOf(_pulsar.copyWith(tankCapacityL: 12))!;
      expect(await s.adoptGarageFuelProfile(edited), isTrue);
      expect(s.fuelProfile.capacityL, 12);

      // The rider's own setting wins from then on.
      await s.setFuelProfile(const FuelProfile(capacityL: 10, mileageKmL: 40, reserveL: 1));
      expect(await s.adoptGarageFuelProfile(GarageBinding.fuelProfileOf(_pulsar)!), isFalse);
      expect(s.fuelProfile.capacityL, 10);
    });

    test('a simple range the rider set also wins', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsService();
      await s.load();
      await s.selectFuelUser('usr_2');
      await s.setFuelRangeKm(300);
      expect(await s.adoptGarageFuelProfile(GarageBinding.fuelProfileOf(_pulsar)!), isFalse);
      expect(s.hasFuelProfile, isFalse);
    });
  });

  test('weather summary carries the warmest temperature for engine care', () {
    final pts = [
      const WeatherPoint(lat: 17.4, lng: 78.5, atS: 1700000000),
      const WeatherPoint(lat: 17.9, lng: 79.6, atS: 1700003600, name: 'Warangal'),
    ];
    final s = WeatherService.summarise(pts, const [
      WeatherReading(precipProb: 0, precipMm: 0, code: 0, tempC: 31),
      WeatherReading(precipProb: 0, precipMm: 0, code: 0, tempC: 38.5),
    ], fetchedAt: 1, attribution: 'x');
    expect(s?.maxTempC, 38.5);
    final none = WeatherService.summarise(pts, const [WeatherReading(precipProb: 0, precipMm: 0, code: 0), null],
        fetchedAt: 1, attribution: 'x');
    expect(none?.maxTempC, isNull);
  });

  test('admin Bike line', () {
    expect(adminBikeLine(null), isNull);
    expect(adminBikeLine(const {'model': '', 'cc': 0, 'colour': '', 'tankL': 0, 'mileageKmL': 0, 'cooling': 'unknown'}),
        isNull);
    expect(
      adminBikeLine(const {'model': 'Classic 350', 'cc': 349, 'colour': 'Black', 'tankL': 13, 'mileageKmL': 35.5, 'cooling': 'oil'}),
      'Classic 350 · 349 cc · Air/oil-cooled · Black · 13 L tank · 35.5 km/L',
    );
  });
}
