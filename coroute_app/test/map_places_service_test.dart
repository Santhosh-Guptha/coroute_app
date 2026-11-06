// Map places service (cache, corridor fetching, retries, offline, fuel ahead)
// and widget smoke tests for the chips, the places sheet and the map layer.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/map_places_service.dart';
import 'package:coroute_app/domain/places/fuel_match.dart';
import 'package:coroute_app/domain/places/place_poi.dart';
import 'package:coroute_app/domain/places/poi_category.dart';
import 'package:coroute_app/presentation/map_places/map_places_layer.dart';
import 'package:coroute_app/presentation/map_places/place_chips.dart';

final line = [for (var i = 0; i <= 100; i++) (17.0 + i * 0.01, 78.02)];

Map<String, Object> wirePoi(String id, double lat, double lng, Map<String, String> t) => {'i': id, 'a': lat, 'o': lng, 't': t};
PlacePoi poi(String id, double lat, double lng, Map<String, String> t) => PlacePoi.fromWire(wirePoi(id, lat, lng, t))!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('MapPlacesService', () {
    late int now;
    late List<List<String>> calls;
    late MemoryPoiCellStore store;
    Object? Function(List<String>) answer = (_) => null;

    MapPlacesService make() => MapPlacesService(
          fetch: (keys) async {
            calls.add(keys);
            final a = answer(keys);
            if (a is Exception) throw a;
            return a;
          },
          store: store,
          clock: () => now,
        );

    Map<String, Object> all(List<String> keys) => {
          'cells': {
            for (final k in keys)
              k: {
                'at': now,
                'p': k == '342:1560'
                    ? [wirePoi('n1', 17.12, 78.021, {'amenity': 'fuel', 'fuel:octane_91': 'yes', 'name': 'HP'})]
                    : <Object>[],
              },
          },
          'pending': <String>[],
        };

    setUp(() {
      now = 1000000;
      calls = [];
      store = MemoryPoiCellStore();
      answer = all;
    });

    test('loads the corridor ahead in batches once, then serves memory and disk', () async {
      final s = make();
      s.setRoute(line);
      s.onPosition(17.0, 78.02);
      await s.idle();
      expect(calls.length, 2, reason: '13 cells for 3 chunks: batches of 12 + 1');
      expect(calls.first.length, 12);
      expect(store.writes, 13);
      expect(s.visible.map((p) => p.id), ['n1']);
      s.onPosition(17.01, 78.02);
      await s.idle();
      expect(calls.length, 2, reason: 'same chunk: no work');

      final again = make();
      again.setRoute(line);
      again.onPosition(17.0, 78.02);
      await again.idle();
      expect(calls.length, 2, reason: 'repeat trip: from the phone, no network');
      expect(again.visible.single.name, 'HP');
    });

    test('expired cells are refreshed after 7 days', () async {
      final s = make();
      s.setRoute(line);
      s.onPosition(17.0, 78.02);
      await s.idle();
      now += MapPlacesService.freshMs + 1;
      final later = make();
      later.setRoute(line);
      later.onPosition(17.0, 78.02);
      await later.idle();
      expect(calls.length, 4);
    });

    test('pending cells are asked again only after the retry time, on a later fix', () async {
      answer = (keys) => {'cells': <String, Object>{}, 'pending': keys};
      final s = make();
      s.setRoute(line);
      s.onPosition(17.0, 78.02);
      await s.idle();
      expect(calls.length, 1, reason: 'stops at the first refused batch');
      now += 10000;
      s.onPosition(17.001, 78.02);
      await s.idle();
      expect(calls.length, 1);
      now += MapPlacesService.retryMs;
      answer = all;
      s.onPosition(17.002, 78.02);
      await s.idle();
      expect(calls.length, 3);
      expect(s.visible.length, 1);
    });

    test('offline: saved places stay and nothing is retried for 5 minutes', () async {
      final s = make();
      s.setRoute(line);
      s.onPosition(17.0, 78.02);
      await s.idle();
      answer = (_) => const ApiException(0, 'offline');
      s.onPosition(17.25, 78.02); // chunk 1: needs one new cell
      await s.idle();
      expect(s.offline, isTrue);
      expect(s.visible.length, 1);
      final n = calls.length;
      now += 60000;
      s.onPosition(17.45, 78.02);
      await s.idle();
      expect(calls.length, n);
    });

    test('fuel ahead: matched station, loaded coverage and the group fuel stop', () async {
      final s = make();
      s.setRoute(line);
      s.onPosition(17.0, 78.02);
      await s.idle();
      s.setGroupFuelStops([(lat: 17.3, lng: 78.02, name: 'Lunch fuel')]);
      final v = s.fuelAhead(17.0, 78.02, usableKm: 50, marginKm: 10)!;
      expect(v.stops.single.poi.id, 'n1');
      expect(v.stops.single.distanceKm, closeTo(13.4, 0.2));
      expect(v.coverageKm, closeTo(60, 0.5));
      expect(v.groupStopKm, closeTo(33.4, 0.2));
      expect(v.groupStopName, 'Lunch fuel');
      expect(s.fuelAhead(17.5, 79.0), isNull, reason: 'far off the route');
    });

    test('chips and fuel type decide what is visible', () {
      final s = make();
      s.debugPut('340:1560', PoiCellData(now, [
        poi('petrol', 17.01, 78.01, {'amenity': 'fuel', 'fuel:octane_91': 'yes'}),
        poi('dieselOnly', 17.02, 78.01, {'amenity': 'fuel', 'fuel:petrol': 'no', 'fuel:diesel': 'yes'}),
        poi('cafe', 17.03, 78.01, {'amenity': 'cafe'}),
        poi('ev', 17.04, 78.01, {'amenity': 'charging_station'}),
        poi('atm', 17.04, 78.02, {'amenity': 'atm'}),
      ]));
      expect(s.visible.map((p) => p.id).toSet(), {'petrol', 'cafe'});
      s.fuelType = BikeFuelType.diesel;
      expect(s.visible.map((p) => p.id).toSet(), {'petrol', 'dieselOnly', 'cafe'});
      s.fuelType = BikeFuelType.ev;
      expect(s.visible.map((p) => p.id).toSet(), {'ev', 'cafe'});
      s.setEnabled(PoiCategory.atm, true);
      s.setEnabled(PoiCategory.food, false);
      expect(s.visible.map((p) => p.id).toSet(), {'ev', 'atm'});
    });
  });

  testWidgets('category chips toggle and the choice is saved', (tester) async {
    final s = MapPlacesService(fetch: (_) async => null);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PlaceCategoryChips(service: s))));
    expect(find.text('Fuel'), findsOneWidget);
    expect(s.isEnabled(PoiCategory.food), isTrue);
    await tester.tap(find.byKey(const ValueKey('placeChip_food')));
    await tester.pump();
    expect(s.isEnabled(PoiCategory.food), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('map_places_categories_v1'), isNot(contains('food')));
    final s2 = MapPlacesService(fetch: (_) async => null);
    await s2.loadPrefs();
    expect(s2.isEnabled(PoiCategory.food), isFalse);
    expect(s2.isEnabled(PoiCategory.fuel), isTrue);
  });

  testWidgets('places button opens the sheet with the chips', (tester) async {
    final s = MapPlacesService(fetch: (_) async => null);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: PlacesMapButton(service: s)))));
    await tester.tap(find.byKey(const ValueKey('placesMapButton')));
    await tester.pumpAndSettle();
    expect(find.text('Places on map'), findsOneWidget);
    expect(find.byKey(const ValueKey('placeSheetChip_hospital')), findsOneWidget);
  });

  testWidgets('map layer: icons and names at street zoom, nothing when zoomed out', (tester) async {
    final s = MapPlacesService(fetch: (_) async => null);
    s.debugPut('340:1560', PoiCellData(1, [
      poi('f', 17.005, 78.01, {'amenity': 'fuel', 'fuel:octane_91': 'yes', 'name': 'HP Fuel'}),
      poi('h', 17.020, 78.01, {'amenity': 'hospital', 'name': 'Govt Hospital', 'emergency': 'yes'}),
    ]));
    Widget map(double zoom) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: FlutterMap(
                key: ValueKey(zoom),
                options: MapOptions(initialCenter: const LatLng(17.0125, 78.01), initialZoom: zoom),
                children: [MapPlacesLayer(service: s)],
              ),
            ),
          ),
        );
    await tester.pumpWidget(map(15));
    await tester.pump();
    expect(find.byType(PoiMarker), findsNWidgets(2));
    expect(find.text('HP Fuel'), findsOneWidget);
    expect(find.text('Govt Hospital'), findsOneWidget);
    await tester.pumpWidget(map(13));
    await tester.pump();
    expect(find.byType(PoiMarker), findsNWidgets(2));
    expect(find.text('HP Fuel'), findsNothing, reason: 'names only from zoom 14');
    await tester.pumpWidget(map(11));
    await tester.pump();
    expect(find.byType(PoiMarker), findsNothing);
  });
}
