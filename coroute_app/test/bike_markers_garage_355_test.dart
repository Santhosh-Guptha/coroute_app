// 3.55 bike markers, garage bike shapes, mandatory bike details and the pillion seat (pure logic).
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/rider_vehicle.dart';
import 'package:coroute_app/data/services/garage_binding.dart';
import 'package:coroute_app/domain/garage/bike_details.dart';
import 'package:coroute_app/domain/garage/bike_profile.dart';
import 'package:coroute_app/domain/garage/bike_type.dart';
import 'package:coroute_app/domain/places/fuel_match.dart';
import 'package:coroute_app/domain/ride/bike_markers.dart';
import 'package:coroute_app/domain/ride/pillion_seat.dart';
import 'package:coroute_app/domain/tracking/replay_math.dart';
import 'package:flutter_test/flutter_test.dart';

RiderModel _r(String id, {String name = '', double lat = 17.4, double lng = 78.4, bool coRiding = false, String withId = '', String no = 'TS09AB1234',
        String kind = '', String colour = 'Red', String model = '', int seen = 1000, int seatAt = 0}) =>
    RiderModel(
      userId: id,
      name: name.isEmpty ? id : name,
      vehicleType: 'Motorcycle',
      vehicleNo: no,
      vehicleColor: colour,
      vehicleModel: model,
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
      pillionSeatAt: seatAt,
    );

bool _pos(RiderModel r) => r.lat != 0 || r.lng != 0;

void main() {
  group('bike type inference', () {
    BikeType? inf(String model, {String make = '', BikeFuelType? fuel}) => BikeTypeInference.infer(make: make, model: model, fuelType: fuel);

    test('obvious models map to their type', () {
      expect(inf('Activa 6G', make: 'Honda'), BikeType.scooter);
      expect(inf('Jupiter'), BikeType.scooter);
      expect(inf('Classic 350', make: 'Royal Enfield'), BikeType.retro);
      expect(inf('Interceptor 650'), BikeType.retro);
      expect(inf('Himalayan 450'), BikeType.adventure);
      expect(inf('R1250 GS Adventure', make: 'BMW'), BikeType.adventure);
      expect(inf('R15 V4', make: 'Yamaha'), BikeType.sport);
      expect(inf('390 Duke', make: 'KTM'), BikeType.sport);
      expect(inf('Duke390'), BikeType.sport, reason: 'word start followed by digits');
      expect(inf('Meteor 350'), BikeType.cruiser);
      expect(inf('Avenger 220'), BikeType.cruiser);
      expect(inf('Xpulse 200 4V', make: 'Hero'), BikeType.offroad);
      expect(inf('Xpulse 200T', make: 'Hero'), BikeType.adventure);
      expect(inf('Splendor Plus', make: 'Hero'), BikeType.commuter);
      expect(inf('Pulsar 150'), BikeType.commuter);
      expect(inf('Pulsar NS200'), BikeType.sport);
      expect(inf('450X', make: 'Ather'), BikeType.electric);
      expect(inf('Chetak'), BikeType.electric);
      expect(inf('Anything', fuel: BikeFuelType.ev), BikeType.electric);
    });

    test('unknown text: null, fallback commuter; wire ids parse back', () {
      expect(inf('My trusty steed'), isNull);
      expect(inf(''), isNull);
      expect(BikeTypeInference.fallback(model: 'Zzz'), BikeType.commuter);
      for (final t in BikeType.values) {
        expect(BikeType.parse(t.wire), t);
      }
      expect(BikeType.parse(''), isNull);
      expect(BikeType.parse('tank'), isNull);
      expect(BikeType.parse(' Scooter '), BikeType.scooter);
    });

    test('BikeProfile keeps the picked type; older garages guess it', () {
      const b = BikeProfile(id: 'a', name: 'My bike', make: 'Honda', model: 'Activa 6G');
      expect(b.bikeType, isNull);
      expect(b.effectiveBikeType, BikeType.scooter);
      final picked = b.copyWith(bikeType: BikeType.electric);
      final back = BikeProfile.fromJson(picked.toJson());
      expect(back.bikeType, BikeType.electric);
      expect(BikeProfile.fromJson(b.toJson()).bikeType, isNull);
      expect(b.toJson().containsKey('bikeType'), isFalse);
      expect(GarageBinding.vehicleKindOf(b), 'scooter');
      expect(GarageBinding.vehicleKindOf(null), '');
    });
  });

  group('mandatory bike details', () {
    const full = BikeProfile(
      id: 'b', name: 'Classic', make: 'Royal Enfield', model: 'Classic 350', bikeType: BikeType.retro,
      engineCc: 349, colour: 'Red', tankCapacityL: 13, expectedMileageKmL: 35,
    );

    test('complete petrol bike; each missing detail is named', () {
      expect(BikeDetails.missing(full), isEmpty);
      expect(BikeDetails.isComplete(full), isTrue);
      expect(BikeDetails.missing(null), BikeDetailField.values);
      expect(BikeDetails.missing(full.copyWith(make: '', model: '')), [BikeDetailField.model]);
      expect(BikeDetails.missing(const BikeProfile(id: 'x', name: 'x', make: 'RE', model: 'Classic 350', engineCc: 349, colour: 'Red')),
          [BikeDetailField.type], reason: 'a guessed type must be confirmed once');
      expect(BikeDetails.missing(full.copyWith(engineCc: 0)), [BikeDetailField.cc]);
      expect(BikeDetails.missing(full.copyWith(colour: ' ')), [BikeDetailField.colour]);
      expect(BikeDetails.missing(full.copyWith(tankCapacityL: 1)), [BikeDetailField.tank]);
      expect(BikeDetails.missing(full.copyWith(expectedMileageKmL: 200)), [BikeDetailField.mileage]);
      expect(BikeDetails.missingLine([BikeDetailField.cc, BikeDetailField.colour]), 'Add engine size and colour');
      expect(BikeDetails.missingLine([BikeDetailField.type, BikeDetailField.cc, BikeDetailField.colour]), 'Add bike type, engine size and colour');
      expect(BikeDetails.missingLine(const []), '');
    });

    test('electric: no engine size or tank needed, mileage in km/kWh', () {
      const ev = BikeProfile(
        id: 'e', name: 'Ather', make: 'Ather', model: '450X', bikeType: BikeType.electric, fuelType: BikeFuelType.ev,
        colour: 'White', tankCapacityL: 0, expectedMileageKmL: 30,
      );
      expect(BikeDetails.missing(ev), [BikeDetailField.mileage], reason: '30 km/kWh is out of the 2..25 range');
      expect(BikeDetails.isComplete(ev.copyWith(expectedMileageKmL: 20)), isTrue);
    });

    Map<String, String> check({
      String name = '', String make = 'Royal Enfield', String model = 'Classic 350', BikeType? type = BikeType.retro,
      String colour = 'Red', String cc = '349', String tank = '13', String reserve = '2', String mileage = '35',
      BikeFuelType fuel = BikeFuelType.petrol,
    }) =>
        validateBikeDetails(name: name, make: make, model: model, type: type, colour: colour, cc: cc, tank: tank, reserve: reserve,
            mileage: mileage, odometer: '', fuelType: fuel);

    test('garage form: everything required, friendly messages', () {
      expect(check(), isEmpty, reason: 'the name falls back to make + model');
      expect(check(make: '', model: '')['model'], contains('make and model'));
      expect(check(type: null)['type'], contains('bike type'));
      expect(check(colour: '')['colour'], isNotNull);
      expect(check(cc: '')['cc'], contains('engine size'));
      expect(check(cc: '40')['cc'], contains('50 to 2500'));
      expect(check(tank: '')['tank'], isNotNull);
      expect(check(mileage: '2')['mileage'], isNotNull);
    });

    test('garage form: electric skips engine size and allows no battery', () {
      expect(check(fuel: BikeFuelType.ev, model: 'Ather 450X', type: BikeType.electric, cc: '', tank: '', reserve: '', mileage: '20'), isEmpty);
      expect(check(fuel: BikeFuelType.ev, type: BikeType.electric, cc: '', tank: '3.7', reserve: '0.4', mileage: '20'), isEmpty);
      expect(check(fuel: BikeFuelType.ev, type: BikeType.electric, cc: '', tank: '', mileage: '40')['mileage'], contains('km/kWh'));
    });

    test('suggestions from the model: preset details and type', () {
      expect(BikeDetailsSuggest.presetFor('Royal Enfield', 'Classic 350')?.id, 'preset_re_classic_350');
      expect(BikeDetailsSuggest.presetFor('', 'activa')?.bikeType, BikeType.scooter);
      expect(BikeDetailsSuggest.presetFor('', 'zz'), isNull);
      const half = BikeProfile(id: 'h', name: 'Mine', model: 'Classic 350', colour: 'Red', tankCapacityL: 0);
      final filled = BikeDetailsSuggest.fill(half);
      expect(filled.engineCc, 349);
      expect(filled.tankCapacityL, 13);
      expect(filled.bikeType, isNull, reason: 'the type is pre-selected, not saved, until confirmed');
      expect(BikeDetailsSuggest.typeFor(half), BikeType.retro);
    });
  });

  group('bike marker plan', () {
    test('a seated pillion rides on the rider\'s marker; no separate dot', () {
      final riders = {
        'asha': _r('asha', kind: 'retro'),
        'kiran': _r('kiran', coRiding: true, withId: 'asha', no: 'PILLION'),
        'arjun': _r('arjun'),
      };
      final plan = BikeMarkerPlan.of(riders, myUserId: 'arjun', hasPosition: _pos);
      expect(plan.keys.toSet(), {'asha', 'arjun'});
      expect(plan['asha']!.pillion?.userId, 'kiran');
      expect(plan['asha']!.twoUp, isTrue);
      expect(plan['asha']!.meOnBoard, isFalse);
      expect(plan['arjun']!.meOnBoard, isTrue);
      expect(BikeMarkerPlan.countedOncePerBike(riders).map((r) => r.userId).toSet(), {'asha', 'arjun'});
    });

    test('on the pillion\'s phone the pair sits at my position; the bike look stays the rider\'s', () {
      final riders = {'asha': _r('asha', kind: 'sport'), 'kiran': _r('kiran', coRiding: true, withId: 'asha')};
      final plan = BikeMarkerPlan.of(riders, myUserId: 'kiran', hasPosition: _pos);
      expect(plan.keys, ['kiran']);
      expect(plan['kiran']!.bikeRider.userId, 'asha');
      expect(plan['kiran']!.meOnBoard, isTrue);
    });

    test('rider\'s phone lost signal: the pillion\'s fresher position carries the bike', () {
      final riders = {'asha': _r('asha', seen: 1000), 'kiran': _r('kiran', coRiding: true, withId: 'asha', seen: 60000)};
      expect(BikeMarkerPlan.of(riders, myUserId: 'x', hasPosition: _pos).keys, ['kiran']);
      final noPos = {'asha': _r('asha', lat: 0, lng: 0), 'kiran': _r('kiran', coRiding: true, withId: 'asha')};
      expect(BikeMarkerPlan.of(noPos, myUserId: 'x', hasPosition: _pos).keys, ['kiran']);
    });

    test('broken links and the switch off: everyone drawn alone', () {
      final riders = {
        'kiran': _r('kiran', coRiding: true, withId: 'gone'),
        'self': _r('self', coRiding: true, withId: 'self'),
        'a': _r('a', coRiding: true, withId: 'b'),
        'b': _r('b', coRiding: true, withId: 'a'),
      };
      expect(BikeMarkerPlan.of(riders, myUserId: 'x', hasPosition: _pos).length, 4);
      final pair = {'asha': _r('asha'), 'kiran': _r('kiran', coRiding: true, withId: 'asha')};
      expect(BikeMarkerPlan.of(pair, myUserId: 'x', hasPosition: _pos, mergePillions: false).length, 2);
      // Two pillions on one bike (odd snapshot): only one is merged.
      final two = {'asha': _r('asha'), 'p1': _r('p1', coRiding: true, withId: 'asha'), 'p2': _r('p2', coRiding: true, withId: 'asha')};
      expect(BikeMarkerPlan.of(two, myUserId: 'x', hasPosition: _pos).length, 2);
    });

    test('cue: the most urgent signal wins', () {
      expect(BikeMarkerCue.of(), BikeMarkerCue.normal);
      expect(BikeMarkerCue.of(stopped: true), BikeMarkerCue.stopped);
      expect(BikeMarkerCue.of(stopped: true, warning: true), BikeMarkerCue.warning);
      expect(BikeMarkerCue.of(warning: true, stale: true), BikeMarkerCue.stale);
      expect(BikeMarkerCue.of(sos: true, stale: true, warning: true), BikeMarkerCue.sos);
    });

    test('colours: names, #RRGGBB, last known word; unknown = null', () {
      expect(BikeColours.parse('Red'), 0xFFD32F2F);
      expect(BikeColours.parse('#a1b2c3'), 0xFFA1B2C3);
      expect(BikeColours.parse('Gunmetal Grey'), 0xFF7A7A7A);
      expect(BikeColours.parse('Matte Black'), 0xFF1B1B1B);
      expect(BikeColours.parse('Kaza Brown'), 0xFF6D4C41);
      expect(BikeColours.parse('Stardust'), isNull);
      expect(BikeColours.parse(''), isNull);
      expect(BikeColours.isLight(0xFFF4F4F4), isTrue);
      expect(BikeColours.isLight(0xFF1B1B1B), isFalse);
    });

    test('cache key: same look shares one glyph; size buckets; unknown kind = commuter', () {
      BikeMarkerKey k({String kind = 'retro', String colour = 'Red', bool two = false, BikeMarkerCue cue = BikeMarkerCue.normal, double size = 48}) =>
          BikeMarkerKey.of(vehicleKind: kind, vehicleColor: colour, fallbackArgb: 0xFF0E7C86, twoUp: two, cue: cue, size: size);
      expect(k(), k(size: 49), reason: '4 px buckets');
      expect(k() == k(size: 56), isFalse);
      expect(k() == k(two: true), isFalse);
      expect(k() == k(colour: 'Blue'), isFalse);
      expect(k() == k(cue: BikeMarkerCue.sos), isFalse);
      expect(k(kind: '').type, BikeType.commuter);
      expect(k(colour: 'Stardust').argb, 0xFF0E7C86, reason: 'unknown colour: the member colour');
      expect(k().id, 'retro|ffd32f2f|1|normal|48||h0');
      expect(BikeMarkerKey.bucket(2), 8);
      expect(BikeMarkerKey.bucket(999), 256);

      final evicted = <String>[];
      final lru = BikeGlyphLru<String>(max: 2, onEvict: evicted.add);
      var built = 0;
      String make(String s) {
        built++;
        return s;
      }

      lru.putIfAbsent(k(), () => make('a'));
      lru.putIfAbsent(k(size: 49), () => make('dup'));
      expect(built, 1);
      expect(lru.hits, 1);
      lru.putIfAbsent(k(colour: 'Blue'), () => make('b'));
      lru.putIfAbsent(k(), () => make('a2')); // touch a: b is now the oldest
      lru.putIfAbsent(k(colour: 'Green'), () => make('c'));
      expect(evicted, ['b']);
      expect(lru.length, 2);
    });

    test('accessible label', () {
      expect(
        bikeMarkerLabel(riderName: 'Asha', model: 'Classic 350', colour: 'Red', pillionName: 'Kiran', speed: '42 km/h', status: 'Riding'),
        'Asha, Classic 350, red, with pillion Kiran, 42 km/h, Riding',
      );
      expect(bikeMarkerLabel(riderName: 'Asha', model: '', colour: '', speed: 'Speed unavailable', status: 'Offline', me: true), 'You, Speed unavailable, Offline');
      expect(
        bikeMarkerLabel(riderName: 'Asha', model: 'Classic 350', colour: 'Red', pillionName: 'Kiran', speed: '40 km/h', status: 'Riding', me: true, mePillion: true),
        'You, riding pillion with Asha, Classic 350, red, 40 km/h, Riding',
      );
    });
  });

  group('pillion seat', () {
    final riders = {
      'asha': _r('asha', name: 'Asha', model: 'Royal Enfield Classic 350', colour: 'Red', kind: 'retro'),
      'ravi': _r('ravi', name: 'Ravi'),
      'kiran': _r('kiran', name: 'Kiran', no: 'PILLION'),
      'meera': _r('meera', name: 'Meera', coRiding: true, withId: 'ravi', seatAt: 5000),
    };

    test('candidates: riders with a bike and no pillion, never me or a pillion', () {
      expect(PillionSeat.candidates(riders, 'kiran').map((r) => r.userId), ['asha']);
      // Meera's own seat counts as free for her.
      expect(PillionSeat.candidates(riders, 'meera').map((r) => r.userId), ['asha', 'ravi']);
      expect(PillionSeat.candidates(riders, 'asha').map((r) => r.userId), isEmpty);
    });

    test('confirm text and bike line', () {
      expect(PillionSeat.confirmText(riders['asha']!), "You'll ride pillion on Asha's Royal Enfield Classic 350 (Red). Confirm?");
      expect(PillionSeat.bikeLine(_r('x', colour: 'Blue', kind: 'scooter')), 'Blue scooter');
      expect(PillionSeat.bikeLine(_r('x', colour: '', kind: '')), 'bike');
      expect(PillionSeat.seatMessage('asha'), {'withUserId': 'asha'});
      expect(PillionSeat.unseatMessage(), isEmpty);
      expect(PillionSeat.unseatMessage('meera'), {'userId': 'meera'});
    });

    test('decline window, pillion lookup and "needs a seat"', () {
      final m = riders['meera']!;
      expect(PillionSeat.canDecline(m, 5000 + 59000), isTrue);
      expect(PillionSeat.canDecline(m, 5000 + 61000), isFalse);
      expect(PillionSeat.pillionOn(riders, 'ravi')?.userId, 'meera');
      expect(PillionSeat.pillionOn(riders, 'asha'), isNull);
      expect(PillionSeat.needsSeat(riders['kiran']!, riders), isTrue, reason: 'pillion account without a seat');
      expect(PillionSeat.needsSeat(m, riders), isFalse);
      expect(PillionSeat.needsSeat(_r('z', coRiding: true, withId: 'gone'), riders), isTrue, reason: 'their rider left');
      expect(PillionSeat.needsSeat(riders['asha']!, riders), isFalse);
    });

    test('notices for everyone; the pillion is asked to pick again when dropped', () {
      final seated = {'pillion': {'userId': 'kiran', 'name': 'Kiran'}, 'rider': {'userId': 'asha', 'name': 'Asha'}, 'declineBy': 1};
      expect(PillionNotice.seated(seated, myUserId: 'ravi')!.title, 'Kiran is riding pillion with Asha');
      expect(PillionNotice.seated(seated, myUserId: 'ravi')!.speech, 'Kiran is riding pillion with Asha.');
      expect(PillionNotice.seated(seated, myUserId: 'asha')!.mine, isTrue);
      expect(PillionNotice.seated(seated, myUserId: 'kiran')!.title, "You're riding pillion with Asha");
      expect(PillionNotice.seated({'pillion': {}}, myUserId: 'x'), isNull);

      Map<String, dynamic> un(String reason) => {...seated, 'reason': reason};
      final declined = PillionNotice.unseated(un('DECLINED'), myUserId: 'kiran')!;
      expect(declined.pickAgain, isTrue);
      expect(declined.title, 'Asha declined you as pillion');
      expect(PillionNotice.unseated(un('DECLINED'), myUserId: 'ravi'), isNull);
      expect(PillionNotice.unseated(un('RIDER_LEFT'), myUserId: 'kiran')!.pickAgain, isTrue);
      expect(PillionNotice.unseated(un('PILLION_LEFT'), myUserId: 'asha')!.title, 'Kiran is no longer riding pillion with you');
      expect(PillionNotice.unseated(un('REMOVED'), myUserId: 'asha')!.title, 'Kiran is no longer your pillion');
      expect(PillionNotice.refused('SEAT_TAKEN', 'That bike already has a pillion.')!.message, 'That bike already has a pillion.');
      expect(PillionNotice.refused('SWAP_RATE', ''), isNull);
    });
  });

  group('RIDER_VEHICLE with the bike type', () {
    test('type and completeness go along when they differ', () {
      final me = _r('me', colour: 'Red', model: 'Classic 350', kind: 'commuter');
      expect(RiderVehicle.message(me: me, colour: 'Red', model: 'Classic 350', kind: 'retro', complete: false),
          {'type': 'RIDER_VEHICLE', 'vehicleKind': 'retro'});
      expect(RiderVehicle.message(me: me, colour: 'Red', model: 'Classic 350', kind: 'commuter', complete: true),
          {'type': 'RIDER_VEHICLE', 'vehicleKind': 'commuter', 'bikeComplete': true}, reason: 'a claim always carries a bike field');
      expect(RiderVehicle.message(me: me, colour: 'Red', model: 'Classic 350', kind: 'commuter', complete: false), isNull);
      expect(RiderVehicle.message(me: me, colour: 'Red', model: 'Classic 350'), isNull, reason: 'older callers unchanged');
      expect(RiderModel.fromJson({'userId': 'u', 'name': 'n', 'vehicleKind': 'scooter', 'bikeComplete': true, 'pillionSeatAt': 7}).vehicleKind, 'scooter');
    });
  });

  group('3D bike markers (3.56)', () {
    test('asset paths per type and riders; garage heroes with no rider or two', () {
      expect(BikeSprites.map(BikeType.sport, 1, BikeLayer.paint), 'assets/map_bikes/sport_1_paint.png');
      expect(BikeSprites.map(BikeType.cruiser, 2, BikeLayer.shadow), 'assets/map_bikes/cruiser_2_shadow.png');
      expect(BikeSprites.map(BikeType.scooter, 0, BikeLayer.base), 'assets/map_bikes/scooter_1_base.png', reason: 'a map bike always has its rider');
      expect(BikeSprites.map(BikeType.retro, 3, BikeLayer.gloss), 'assets/map_bikes/retro_2_gloss.png');
      expect(BikeSprites.hero(BikeType.adventure, 0, BikeLayer.base), 'assets/garage_bikes/adventure_0_base.png');
      expect(BikeSprites.hero(BikeType.adventure, 1, BikeLayer.paint), 'assets/garage_bikes/adventure_0_paint.png');
      expect(BikeSprites.hero(BikeType.offroad, 2, BikeLayer.gloss), 'assets/garage_bikes/offroad_2_gloss.png');
      expect(BikeSprites.hero(BikeType.electric, 2, BikeLayer.shadow), 'assets/garage_bikes/electric_2_base.png', reason: 'hero shadow is in base');
      final all = BikeSprites.allMap();
      expect(all.length, BikeType.values.length * 2 * 4);
      expect(all.toSet().length, all.length);
      // Unknown kinds draw the commuter (as before).
      final k = BikeMarkerKey.of(vehicleKind: 'hoverbike', vehicleColor: 'Red', fallbackArgb: 0, twoUp: true, cue: BikeMarkerCue.normal, size: 192);
      expect(BikeSprites.map(k.type, 2, BikeLayer.base), 'assets/map_bikes/commuter_2_base.png');
    });

    test('cache key carries a heading bucket only when asked', () {
      BikeMarkerKey k({double? h, int step = 10}) =>
          BikeMarkerKey.of(vehicleKind: 'sport', vehicleColor: 'Kaza Brown', fallbackArgb: 0, twoUp: false, cue: BikeMarkerCue.normal, size: 64, heading: h, headingStep: step);
      expect(k().heading, 0);
      expect(k(h: 4), k(h: -4), reason: 'both round to north');
      expect(k(h: 6).heading, 10);
      expect(k(h: 355).heading, 0);
      expect(k(h: 44).id, endsWith('|h40'));
      expect(k(h: 44) == k(h: 46), isFalse);
      expect(k(h: 44, step: 30).heading, 30);
      expect(k().argb, 0xFF6D4C41, reason: '"Kaza Brown" is brown');
      expect(headingBucket(-20), 340);
      expect(headingBucket(722), 0);
      expect(headingBucket(double.nan), 0);
      expect(headingBucket(181, step: 45), 180);
    });

    test('colour names the garage uses', () {
      expect(BikeColours.parse('Kaza Brown'), 0xFF6D4C41);
      expect(BikeColours.parse('Pearl White'), 0xFFF4F4F4);
      expect(BikeColours.parse('Racing Red'), 0xFFD32F2F);
      expect(BikeColours.parse('Matte Silver'), 0xFFC0C0C0);
      expect(BikeColours.parse('Desert Storm'), 0xFFC2A36B);
      expect(BikeColours.parse('#1E63D6'), 0xFF1E63D6);
    });

    test('paint tint: dark paints are lifted, light ones kept, always opaque', () {
      expect(BikeSprites.paintArgb(0xFF000000), 0xFF262626);
      expect(BikeSprites.paintArgb(0xFFFFFFFF), 0xFFFFFFFF);
      expect(BikeSprites.paintArgb(0x00D32F2F) >>> 24, 0xFF);
      final black = BikeSprites.paintArgb(0xFF1B1B1B) & 0xFF;
      expect(black, 0x3D);
      final red = BikeSprites.paintArgb(0xFFD32F2F);
      expect((red >> 16) & 0xFF, greaterThan(0xD0));
    });

    test('heading hold: standing riders keep the last heading; bad courses ignored', () {
      final h = HeadingHold();
      expect(h.update('a', 90, 30), 90);
      expect(h.update('a', 0, 0), 90, reason: 'stopped: GPS course is noise');
      expect(h.update('a', 200, 2), 90, reason: 'below walking speed');
      expect(h.update('a', double.nan, 40), 90);
      expect(h.update('a', -1, 40), 90, reason: 'no course');
      expect(h.update('a', 370, 40), 10);
      expect(h.update('b', 45, 0), 45, reason: 'first sight: use what we have');
      expect(h.update('c', -1, 0), 0);
      h.forget(['a']);
      expect(h.lastOf('b'), isNull);
      expect(h.lastOf('a'), 10);
    });

    test('replay heading: bearing of the ridden stretch, null when standing or across a gap', () {
      final t = ReplayTrack(userId: 'u', name: 'U', points: const [
        ReplayPoint(0, 17.0, 78.0, 40),
        ReplayPoint(10000, 17.001, 78.0, 40), // north
        ReplayPoint(20000, 17.001, 78.001, 40), // east
        ReplayPoint(30000, 17.001, 78.001, 0), // standing
        ReplayPoint(40000, 17.0010001, 78.001, 0), // jitter
        ReplayPoint(50000, 17.002, 78.001, 30, true), // after a gap
      ]);
      expect(t.headingAt(5000)!, closeTo(0, 1));
      expect(t.headingAt(15000)!, closeTo(90, 1));
      expect(t.headingAt(35000)!, closeTo(90, 1), reason: 'standing: looks back to the last move');
      expect(t.headingAt(45000), isNull, reason: 'signal gap');
      expect(t.headingAt(-1), isNull);
      expect(t.headingAt(60000), isNull);
    });
  });
}
