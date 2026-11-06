// Pure logic for map places and fuel (no Flutter): cells and corridor chunks,
// along-route distance, fuel type matching, reachability, mileage learning and
// the fuel warning (including "fill up here" before a long gap).
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/places/fuel_advisor.dart';
import 'package:coroute_app/domain/places/fuel_ahead.dart';
import 'package:coroute_app/domain/places/fuel_economy.dart';
import 'package:coroute_app/domain/places/fuel_match.dart';
import 'package:coroute_app/domain/places/place_poi.dart';
import 'package:coroute_app/domain/places/poi_category.dart';
import 'package:coroute_app/domain/places/poi_declutter.dart';
import 'package:coroute_app/domain/places/route_corridor.dart';
import 'package:coroute_app/domain/safety/fuel_profile.dart';

PlacePoi poi(String id, double lat, double lng, Map<String, String> tags) =>
    PlacePoi.fromWire({'i': id, 'a': lat, 'o': lng, 't': tags})!;

/// About 111 km straight north along longitude 78.02.
final northLine = [for (var i = 0; i <= 100; i++) (17.0 + i * 0.01, 78.02)];

FuelStop stop(String id, double km, {FuelMatch match = FuelMatch.match}) => FuelStop(
    poi: poi(id, 17, 78, {'amenity': 'fuel', 'name': 'Pump $id'}),
    match: match,
    alongM: km * 1000,
    offM: 0,
    distanceKm: km,
    reach: Reach.unknown);

void main() {
  group('places from the wire', () {
    test('categories from OSM tags', () {
      expect(classifyPoi({'amenity': 'fuel'}), PoiCategory.fuel);
      expect(classifyPoi({'amenity': 'charging_station'}), PoiCategory.ev);
      expect(classifyPoi({'healthcare': 'hospital'}), PoiCategory.hospital);
      expect(classifyPoi({'amenity': 'clinic'}), PoiCategory.hospital);
      expect(classifyPoi({'craft': 'mechanic'}), PoiCategory.mechanic);
      expect(classifyPoi({'shop': 'tyres'}), PoiCategory.mechanic);
      expect(classifyPoi({'amenity': 'fast_food'}), PoiCategory.food);
      expect(classifyPoi({'tourism': 'guest_house'}), PoiCategory.stay);
      expect(classifyPoi({'amenity': 'toilets'}), PoiCategory.toilet);
      expect(classifyPoi({'amenity': 'bench'}), isNull);
    });

    test('name, phone, hours and emergency hospitals', () {
      final h = poi('n1', 17, 78, {'amenity': 'hospital', 'name': 'District Hospital', 'phone': '+91 40 1234 5678; 040 999', 'opening_hours': '24/7'});
      expect(h.displayName, 'District Hospital');
      expect(h.phone, '+914012345678');
      expect(h.open24h, isTrue);
      expect(h.isEmergencyHospital, isTrue);
      final c = poi('n2', 17, 78, {'amenity': 'clinic'});
      expect(c.displayName, 'Hospital or clinic');
      expect(c.isEmergencyHospital, isFalse);
      expect(PlacePoi.fromWire({'i': 'x', 'a': 99, 'o': 0, 't': {'amenity': 'fuel'}}), isNull);
      expect(PlacePoi.fromWire({'i': 'x', 'a': 1, 'o': 1, 't': {'amenity': 'bench'}}), isNull);
      final back = PlacePoi.fromWire(h.toWire())!;
      expect(back.tags['opening_hours'], '24/7');
    });
  });

  group('cells and the route corridor', () {
    test('cell keys match the gateway grid', () {
      expect(PoiCells.keyOf(17.0, 78.0), '340:1560');
      expect(PoiCells.keyOf(17.049, 78.049), '340:1560');
      expect(PoiCells.keyOf(-0.01, -0.01), '-1:-1');
      final b = PoiCells.bounds('340:1560')!;
      expect(b.s, closeTo(17.0, 1e-9));
      expect(b.e, closeTo(78.05, 1e-9));
    });

    test('around a point: one cell in the middle, four at a corner, nearest first', () {
      expect(PoiCells.around(17.025, 78.025, 2000), ['340:1560']);
      final corner = PoiCells.around(17.001, 78.001, 2000);
      expect(corner.length, 4);
      expect(corner.first, '340:1560');
    });

    test('path length, point at a distance and projection', () {
      final path = RoutePath(northLine);
      expect(path.lengthM, closeTo(111195, 300));
      final (lat, lng) = path.pointAt(path.lengthM / 2);
      expect(lat, closeTo(17.5, 0.001));
      expect(lng, closeTo(78.02, 1e-9));
      final h = path.project(17.3, 78.03)!;
      expect(h.along, closeTo(33358, 100));
      expect(h.off, closeTo(1064, 30));
    });

    test('corridor cells come in 20 km chunks, in route order, no duplicates', () {
      final c = RouteCorridor(RoutePath(northLine));
      expect(c.chunkCount, 6);
      final first = c.cellsOfChunk(0);
      expect(first.first, '340:1560', reason: 'the cell the route starts in comes first');
      expect(first.toSet(), {'339:1560', '340:1560', '341:1560', '342:1560', '343:1560'});
      final ahead = c.cellsAhead(0, ahead: 2);
      expect(ahead.toSet().length, ahead.length);
      expect(ahead.first, '340:1560');
      expect(ahead.length, 13);
      expect(ahead.last, '351:1560'); // about 60 km + 2 km buffer
      expect(c.chunkOf(65000), 3);
      expect(c.cellsAhead(65000, ahead: 0).first, c.cellsOfChunk(3).first);
      expect(c.chunkOf(1e9), 5, reason: 'clamped to the last chunk');
    });

    test('coverage ahead stops at the first chunk not loaded', () {
      final c = RouteCorridor(RoutePath(northLine));
      final loaded = {...c.cellsOfChunk(0), ...c.cellsOfChunk(1)};
      expect(c.coveredAheadM(5000, loaded.contains), closeTo(35000, 1));
      expect(c.coveredAheadM(45000, loaded.contains), 0);
      final all = {for (var i = 0; i < c.chunkCount; i++) ...c.cellsOfChunk(i)};
      expect(c.coveredAheadM(0, all.contains), closeTo(c.path.lengthM, 1));
    });

    test('the cursor follows the rider cheaply and recovers after a jump', () {
      final cur = RouteCursor(RoutePath(northLine));
      expect(cur.locate(17.1, 78.02), closeTo(11120, 50));
      expect(cur.locate(17.12, 78.021), closeTo(13344, 50));
      expect(cur.locate(17.9, 78.02), closeTo(100075, 100), reason: 'far jump: full scan');
      expect(cur.offM, lessThan(5));
    });
  });

  group('fuel type matching', () {
    test('petrol, diesel, CNG and electric', () {
      final tagged = poi('a', 17, 78, {'amenity': 'fuel', 'fuel:octane_91': 'yes', 'fuel:diesel': 'no'});
      final bare = poi('b', 17, 78, {'amenity': 'fuel', 'name': 'HP'});
      final noPetrol = poi('c', 17, 78, {'amenity': 'fuel', 'fuel:petrol': 'no', 'fuel:diesel': 'yes'});
      final cngByName = poi('d', 17, 78, {'amenity': 'fuel', 'name': 'IGL CNG Station'});
      final charger = poi('e', 17, 78, {'amenity': 'charging_station'});
      expect(fuelMatch(tagged, BikeFuelType.petrol), FuelMatch.match);
      expect(fuelMatch(tagged, BikeFuelType.diesel), FuelMatch.noMatch);
      expect(fuelMatch(bare, BikeFuelType.petrol), FuelMatch.unknown);
      expect(fuelMatch(noPetrol, BikeFuelType.petrol), FuelMatch.noMatch);
      expect(fuelMatch(noPetrol, BikeFuelType.diesel), FuelMatch.match);
      expect(fuelMatch(cngByName, BikeFuelType.cng), FuelMatch.match);
      expect(fuelMatch(bare, BikeFuelType.cng), FuelMatch.unknown);
      expect(fuelMatch(charger, BikeFuelType.ev), FuelMatch.match);
      expect(fuelMatch(charger, BikeFuelType.petrol), FuelMatch.noMatch);
      expect(fuelMatch(tagged, BikeFuelType.ev), FuelMatch.noMatch);
      expect(BikeFuelTypeInfo.parse('diesel'), BikeFuelType.diesel);
      expect(BikeFuelTypeInfo.parse(null), BikeFuelType.petrol);
      expect(BikeFuelType.ev.unit, 'kWh');
    });
  });

  group('stations ahead on the route', () {
    final path = RoutePath(northLine);
    final pois = [
      poi('behind', 17.05, 78.02, {'amenity': 'fuel', 'fuel:octane_91': 'yes'}),
      poi('near', 17.2, 78.025, {'amenity': 'fuel', 'fuel:octane_91': 'yes'}),
      poi('unknown', 17.4, 78.02, {'amenity': 'fuel'}),
      poi('diesel', 17.45, 78.02, {'amenity': 'fuel', 'fuel:petrol': 'no', 'fuel:diesel': 'yes'}),
      poi('far', 17.6, 78.02, {'amenity': 'fuel', 'fuel:octane_95': 'yes'}),
      poi('offroute', 17.3, 78.1, {'amenity': 'fuel', 'fuel:octane_91': 'yes'}),
      poi('food', 17.3, 78.02, {'amenity': 'cafe'}),
    ];
    final projected = projectOntoRoute(pois.where((p) => p.category == PoiCategory.fuel), path);

    test('projection keeps stations near the route, in order', () {
      expect(projected.map((p) => p.poi.id), ['behind', 'near', 'unknown', 'diesel', 'far']);
      final near = projected[1];
      expect(near.alongM, closeTo(22239, 60));
      expect(near.offM, closeTo(532, 20));
    });

    test('along-route distance, fuel type filter and reachability', () {
      final stops = fuelStopsAhead(projected, progressM: 11120, type: BikeFuelType.petrol, usableKm: 30, marginKm: 10);
      expect(stops.map((s) => s.poi.id), ['near', 'unknown', 'far']);
      expect(stops[0].distanceKm, closeTo(11.65, 0.1)); // 11.1 km along + 0.53 km off the road
      expect(stops[0].reach, Reach.reachable);
      expect(stops[1].distanceKm, closeTo(33.4, 0.2));
      expect(stops[1].reach, Reach.onReserve);
      expect(stops[1].confirmed, isFalse);
      expect(stops[2].reach, Reach.tooFar);
      final diesel = fuelStopsAhead(projected, progressM: 11120, type: BikeFuelType.diesel);
      expect(diesel.map((s) => s.poi.id), ['near', 'unknown', 'diesel', 'far']);
      expect(diesel.first.match, FuelMatch.unknown);
      expect(diesel.first.reach, Reach.unknown);
    });

    test('reach thresholds', () {
      expect(reachOf(20, usableKm: 30, marginKm: 10), Reach.reachable);
      expect(reachOf(35, usableKm: 30, marginKm: 10), Reach.onReserve);
      expect(reachOf(45, usableKm: 30, marginKm: 10), Reach.tooFar);
      expect(reachOf(5), Reach.unknown);
    });
  });

  group('mileage learning', () {
    test('full to full, with partial fills in between', () {
      final l = FuelLearning();
      expect(l.addFill(const FillRecord(at: 1, kmSincePrev: 0, full: true), ratedKmPerUnit: 25), isNull, reason: 'first full is only an anchor');
      expect(l.addFill(const FillRecord(at: 2, kmSincePrev: 150, amount: 5), ratedKmPerUnit: 25), isNull);
      expect(l.addFill(const FillRecord(at: 3, kmSincePrev: 180, amount: 6, full: true), ratedKmPerUnit: 25), closeTo(30, 1e-9));
      expect(l.learnedKmPerUnit, closeTo(30, 1e-9));
      expect(l.effectiveKmPerUnit(25), closeTo(27.5, 1e-9), reason: 'one sample: blended with the rated value');
      l.addFill(const FillRecord(at: 4, kmSincePrev: 400, amount: 10, full: true), ratedKmPerUnit: 25);
      expect(l.learnedKmPerUnit, closeTo(35, 1e-9), reason: 'smoothed');
      expect(l.effectiveKmPerUnit(25), closeTo(35, 1e-9));
    });

    test('bounds, short windows, missing amounts and GPS gaps are ignored', () {
      final l = FuelLearning();
      l.addFill(const FillRecord(at: 1, kmSincePrev: 0, full: true), ratedKmPerUnit: 25);
      expect(l.addFill(const FillRecord(at: 2, kmSincePrev: 300, amount: 1, full: true), ratedKmPerUnit: 25), isNull, reason: '300 km/L is impossible');
      expect(l.addFill(const FillRecord(at: 3, kmSincePrev: 30, amount: 1, full: true), ratedKmPerUnit: 25), isNull, reason: 'window too short');
      expect(l.addFill(const FillRecord(at: 4, kmSincePrev: 200, full: true), ratedKmPerUnit: 25), isNull, reason: 'no amount');
      expect(l.addFill(const FillRecord(at: 5, kmSincePrev: 200, amount: 8, full: true, reliable: false), ratedKmPerUnit: 25), isNull);
      expect(l.learnedKmPerUnit, isNull);
      expect(l.effectiveKmPerUnit(25), 25);
      final back = FuelLearning.fromJson(l.toJson());
      expect(back.fills.length, 5);
      expect(back.learnedKmPerUnit, isNull);
    });

    test('riding style factor', () {
      final s = RidingStyle();
      s.add(3, 20);
      expect(s.factor, 1.0, reason: 'not enough distance yet');
      s.add(1, 20);
      s.add(1, 25);
      expect(s.factor, closeTo(0.88, 1e-9));
      final h = RidingStyle();
      for (var i = 0; i < 20; i++) {
        h.add(1, 80);
      }
      expect(h.factor, closeTo(1.05, 1e-9));
      h.add(9, 80); // a 9 km step is a GPS jump, ignored
      expect(h.totalKm, 20);
    });

    test('adjusted range equals the plain estimate when nothing is learned', () {
      const p = FuelProfile(capacityL: 15, mileageKmL: 30, reserveL: 2, bufferKm: 20);
      final plain = p.usableKm(450, 100000);
      expect(adjustedUsableKm(p, baselineKm: 450, riddenKm: 100), closeTo(plain, 1e-9));
      expect(adjustedUsableKm(p, baselineKm: 450, riddenKm: 100, effectiveKmPerUnit: 35), greaterThan(plain));
      expect(adjustedUsableKm(p, baselineKm: 450, riddenKm: 100, styleFactor: 0.88), lessThan(plain));
      expect(adjustedUsableKm(p, baselineKm: 450, riddenKm: 100, climbM: 1000), closeTo(plain - 10, 1e-9));
      const km = FuelProfile(fullRangeKm: 300, bufferKm: 20);
      expect(adjustedUsableKm(km, baselineKm: 300, riddenKm: 100), closeTo(km.usableKm(300, 100000), 1e-9));
      expect(adjustedUsableKm(p, baselineKm: 10, riddenKm: 500), 0);
    });
  });

  group('fuel warning', () {
    FuelAheadView ahead(List<FuelStop> stops, {double coverageKm = 200, double? groupKm, String? groupName}) =>
        FuelAheadView(type: BikeFuelType.petrol, stops: stops, coverageKm: coverageKm, groupStopKm: groupKm, groupStopName: groupName);

    test('nothing while there is plenty of fuel', () {
      expect(decideFuelWarning(usableKm: 100, marginKm: 20, fullRangeKm: 400, ahead: ahead([stop('a', 30)])).kind, FuelWarningKind.none);
      expect(decideFuelWarning(usableKm: null, marginKm: 20, fullRangeKm: 400).kind, FuelWarningKind.none);
    });

    test('low with plenty of margin names the next matching station', () {
      final w = decideFuelWarning(usableKm: 60, marginKm: 20, fullRangeKm: 300, ahead: ahead([stop('a', 18)]));
      expect(w.kind, FuelWarningKind.low);
      expect(w.message, contains('Fuel low — next petrol station in 18 km'));
      expect(w.stationId, 'a');
      final unknown = decideFuelWarning(usableKm: 40, marginKm: 20, fullRangeKm: 300, ahead: ahead([stop('u', 8, match: FuelMatch.unknown)]));
      expect(unknown.message, contains('type unknown'));
      final none = decideFuelWarning(usableKm: 40, marginKm: 20, fullRangeKm: 300);
      expect(none.message, contains('no petrol station mapped ahead yet'));
    });

    test('urgent and critical', () {
      expect(decideFuelWarning(usableKm: 15, marginKm: 20, fullRangeKm: 300, ahead: ahead([stop('a', 12)])).kind, FuelWarningKind.urgent);
      expect(decideFuelWarning(usableKm: 8, marginKm: 20, fullRangeKm: 300, ahead: ahead([stop('a', 6)])).kind, FuelWarningKind.critical);
    });

    test('range risk only when the gap is known (loaded)', () {
      final w = decideFuelWarning(usableKm: 30, marginKm: 10, fullRangeKm: 300, ahead: ahead([stop('a', 45)], coverageKm: 100));
      expect(w.kind, FuelWarningKind.rangeRisk);
      expect(w.message, contains('45 km away'));
      final partial = decideFuelWarning(usableKm: 30, marginKm: 10, fullRangeKm: 300, ahead: ahead([stop('a', 45)], coverageKm: 20));
      expect(partial.kind, FuelWarningKind.low);
    });

    test('fill up here before a long gap', () {
      final w = decideFuelWarning(usableKm: 100, marginKm: 20, fullRangeKm: 400, ahead: ahead([stop('here', 3), stop('next', 133)]));
      expect(w.kind, FuelWarningKind.longGap);
      expect(w.message, startsWith('Next fuel after this is 130 km away — fill up at Pump here'));
      expect(w.stationId, 'here');
      final unmapped = decideFuelWarning(usableKm: 100, marginKm: 20, fullRangeKm: 400, ahead: ahead([stop('here', 3)], coverageKm: 200));
      expect(unmapped.kind, FuelWarningKind.longGap);
      expect(unmapped.message, contains('No petrol station mapped in the next 197 km'));
      final shortData = decideFuelWarning(usableKm: 100, marginKm: 20, fullRangeKm: 400, ahead: ahead([stop('here', 3)], coverageKm: 50));
      expect(shortData.kind, FuelWarningKind.none, reason: 'not enough loaded to know the gap');
      final easy = decideFuelWarning(usableKm: 100, marginKm: 20, fullRangeKm: 400, ahead: ahead([stop('here', 3), stop('next', 40)]));
      expect(easy.kind, FuelWarningKind.none);
      final notYet = decideFuelWarning(usableKm: 100, marginKm: 20, fullRangeKm: 400, ahead: ahead([stop('here', 12), stop('next', 160)]));
      expect(notYet.kind, FuelWarningKind.none, reason: 'warned when the station is close');
    });

    test('a group fuel stop within range is named instead', () {
      final w = decideFuelWarning(usableKm: 15, marginKm: 20, fullRangeKm: 300, ahead: ahead([stop('a', 5)], groupKm: 12, groupName: 'HP Kurnool'));
      expect(w.kind, FuelWarningKind.urgent);
      expect(w.message, contains('group fuel stop (HP Kurnool) in 12 km'));
      final gap = decideFuelWarning(usableKm: 100, marginKm: 20, fullRangeKm: 400, ahead: ahead([stop('here', 3), stop('next', 160)], groupKm: 3));
      expect(gap.kind, FuelWarningKind.none, reason: 'the group already stops there');
    });
  });

  group('declutter', () {
    test('nearest wins an overlap; a label yields but its icon stays; max respected', () {
      final out = declutter([
        const DeclutterItem(value: 'far', x: 100, y: 100, distanceM: 900),
        const DeclutterItem(value: 'near', x: 105, y: 102, distanceM: 100),
        const DeclutterItem(value: 'labelled', x: 200, y: 100, distanceM: 200, labelWidth: 100),
        const DeclutterItem(value: 'blocker', x: 260, y: 100, distanceM: 150),
        const DeclutterItem(value: 'other', x: 400, y: 400, distanceM: 300),
      ], max: 10);
      expect(out.map((p) => p.value), ['near', 'blocker', 'labelled', 'other']);
      expect(out.firstWhere((p) => p.value == 'labelled').showLabel, isFalse);
      final capped = declutter([for (var i = 0; i < 50; i++) DeclutterItem(value: i, x: i * 40.0, y: 0, distanceM: i.toDouble())], max: 5);
      expect(capped.length, 5);
    });

    test('pinned (24h emergency) first, off-screen skipped, labels when free', () {
      final out = declutter([
        const DeclutterItem(value: 'cafe', x: 50, y: 50, distanceM: 10),
        const DeclutterItem(value: 'er', x: 52, y: 50, distanceM: 500, pinned: true, labelWidth: 60),
        const DeclutterItem(value: 'off', x: -100, y: 50, distanceM: 1),
      ], max: 10, viewW: 300, viewH: 300);
      expect(out.map((p) => p.value), ['er']);
      expect(out.single.showLabel, isTrue);
      expect(PoiZoom.maxVisible(12.5), lessThan(PoiZoom.maxVisible(16)));
      expect(estimateLabelWidth(''), 0);
      expect(estimateLabelWidth('x' * 100), 132);
    });
  });
}
