// 3.55 heritage places on the way: OSM classification (a useful category wins first), the pure
// "historic places ahead" finder and the notice gate (once per place, one per 10 minutes, never
// during an SOS).
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/places/heritage_ahead.dart';
import 'package:coroute_app/domain/places/place_poi.dart';
import 'package:coroute_app/domain/places/poi_category.dart';
import 'package:coroute_app/domain/places/route_corridor.dart';

PlacePoi poi(String id, double lat, double lng, Map<String, String> tags) =>
    PlacePoi.fromWire({'i': id, 'a': lat, 'o': lng, 't': tags})!;

/// About 111 km straight north along longitude 78.02 (0.01 deg lat ~ 1.11 km).
final northLine = [for (var i = 0; i <= 100; i++) (17.0 + i * 0.01, 78.02)];

void main() {
  group('classifyPoi heritage', () {
    test('historic tags, attractions, museums and heritage-listed places are heritage', () {
      expect(classifyPoi({'historic': 'fort', 'name': 'Golconda Fort'}), PoiCategory.heritage);
      expect(classifyPoi({'historic': 'archaeological_site'}), PoiCategory.heritage);
      expect(classifyPoi({'historic': 'temple'}), PoiCategory.heritage);
      expect(classifyPoi({'tourism': 'museum'}), PoiCategory.heritage);
      expect(classifyPoi({'tourism': 'attraction'}), PoiCategory.heritage);
      expect(classifyPoi({'heritage': '2', 'building': 'yes'}), PoiCategory.heritage);
    });

    test('a useful category wins first; unknown historic kinds are not shown', () {
      expect(classifyPoi({'amenity': 'fuel', 'historic': 'building'}), PoiCategory.fuel);
      expect(classifyPoi({'amenity': 'hospital', 'heritage': '1'}), PoiCategory.hospital);
      expect(classifyPoi({'tourism': 'viewpoint', 'historic': 'memorial'}), PoiCategory.viewpoint);
      expect(classifyPoi({'tourism': 'hotel', 'heritage': '2'}), PoiCategory.stay);
      expect(classifyPoi({'historic': 'milestone'}), isNull);
      expect(classifyPoi({'heritage': ''}), isNull);
    });

    test('labels, rank after viewpoint, shown by default', () {
      expect(PoiCategory.heritage.label, 'Historic places');
      expect(PoiCategory.heritage.singular, 'Historic place');
      expect(PoiCategory.heritage.rank, greaterThan(PoiCategory.viewpoint.rank));
      expect(defaultPoiCategories, contains(PoiCategory.heritage));
      expect(PoiCategoryInfo.byName('heritage'), PoiCategory.heritage);
      expect(poi('w1', 17.1, 78.02, {'historic': 'fort', 'name': 'Fort'}).category, PoiCategory.heritage);
    });
  });

  group('heritageAhead', () {
    final path = RoutePath(northLine);
    // At 17.10 (about 11 km along the line).
    const progress = 11132.0;

    test('within 1.5 km of the route and 1 to 25 km ahead, nearest first', () {
      final places = [
        poi('n1', 17.30, 78.025, {'historic': 'fort', 'name': 'Far Fort'}), // ~22 km ahead, ~530 m off
        poi('n2', 17.20, 78.02, {'historic': 'temple', 'name': 'Old Temple'}), // ~11 km ahead, on the route
        poi('n3', 17.15, 78.05, {'historic': 'ruins', 'name': 'Ruins Off'}), // ~3.2 km off: no
        poi('n4', 17.105, 78.02, {'historic': 'memorial', 'name': 'Too Close'}), // ~0.5 km ahead: no
        poi('n5', 17.05, 78.02, {'historic': 'castle', 'name': 'Behind'}), // behind: no
        poi('n6', 17.50, 78.02, {'historic': 'palace', 'name': 'Too Far'}), // ~44 km ahead: no
        poi('n7', 17.21, 78.02, {'amenity': 'fuel', 'name': 'Pump'}), // not heritage
      ];
      final out = heritageAhead(path: path, candidates: places, progressM: progress);
      expect(out.map((h) => h.poi.name), ['Old Temple', 'Far Fort']);
      expect(out.first.aheadM, closeTo(11132, 200));
      expect(out.first.offM, lessThan(50));
      expect(out.last.offM, closeTo(530, 60));
    });

    test('progress from my position when not given; nothing without a route', () {
      final places = [poi('n2', 17.20, 78.02, {'historic': 'temple', 'name': 'Old Temple'})];
      final out = heritageAhead(path: path, candidates: places, myLat: 17.10, myLng: 78.021);
      expect(out.single.poi.id, 'n2');
      expect(heritageAhead(path: RoutePath(const [(17.0, 78.0)]), candidates: places, myLat: 17.1, myLng: 78.02), isEmpty);
      expect(heritageAhead(path: path, candidates: places), isEmpty, reason: 'no progress and no position');
    });

    test('message: distance ahead and off the route', () {
      final h = HeritageAhead(poi: poi('n1', 17.2, 78.02, {'historic': 'fort', 'name': 'Golconda Fort'}), aheadM: 12300, offM: 610);
      expect(h.message, '12 km ahead, 600 m off the route. Worth a stop?');
      final near = HeritageAhead(poi: h.poi, aheadM: 4260, offM: 40);
      expect(near.message, '4.3 km ahead, right on the route. Worth a stop?');
    });
  });

  group('HeritageNoticeGate', () {
    HeritageAhead h(String id, {String name = 'Fort'}) =>
        HeritageAhead(poi: poi(id, 17.2, 78.02, {'historic': 'fort', if (name.isNotEmpty) 'name': name}), aheadM: 5000, offM: 100);

    test('once per place per ride, one notice every 10 minutes, never during an SOS', () {
      final g = HeritageNoticeGate();
      const t0 = 1000000;
      expect(g.pick([h('a')], nowMs: t0, sosOpen: true), isNull, reason: 'not during an SOS');
      expect(g.pick([h('a'), h('b')], nowMs: t0, sosOpen: false)?.poi.id, 'a');
      expect(g.pick([h('b')], nowMs: t0 + 60000, sosOpen: false), isNull, reason: 'one per 10 minutes');
      expect(g.pick([h('a'), h('b')], nowMs: t0 + 600000, sosOpen: false)?.poi.id, 'b', reason: 'a was told already');
      expect(g.pick([h('a'), h('b')], nowMs: t0 + 1300000, sosOpen: false), isNull, reason: 'both told');
      g.reset();
      expect(g.pick([h('a')], nowMs: t0 + 1300000, sosOpen: false)?.poi.id, 'a', reason: 'a new ride');
    });

    test('a nameless place is not worth a notice on its own', () {
      final g = HeritageNoticeGate();
      expect(g.pick([h('x', name: '')], nowMs: 1, sosOpen: false), isNull);
    });
  });
}
