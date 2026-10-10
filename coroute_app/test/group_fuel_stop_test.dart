import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/group_fuel.dart';
import 'package:coroute_app/data/models/route_essential.dart';

const now = 200000;
PositionedFuelRange rider(
  String id,
  double longitude,
  double km, {
  int at = now,
  double latitude = 0,
}) => PositionedFuelRange(SharedFuelRange(id, km, at, at), latitude, longitude);
RouteEssential station({double entry = 10000, double access = 500}) =>
    RouteEssential(
      placeId: 'p',
      visitId: 'v',
      name: 'Fuel stop',
      category: 'FUEL',
      source: 'test',
      lat: 0,
      lng: .1,
      routePositionM: entry,
      entryM: entry,
      exitM: entry + 1000,
      accessDistanceM: access,
      detourDistanceM: 1000,
      detourDurationS: 60,
    );
GroupFuelStop? calculate(
  List<PositionedFuelRange> riders, {
  bool reliable = true,
  List<(double, double)> route = const [(0, 0), (0, .2)],
  int total = 2,
  List<RouteEssential>? stations,
}) => commonFuelStop(
  riders: riders,
  total: total,
  now: now,
  route: route,
  stations: stations ?? [station()],
  reliable: reliable,
);
void main() {
  test('common station uses individual road distance, including access, and headroom', () {
    final result = calculate([rider('rear', 0, 12), rider('ahead', .05, 6)]);
    expect(result, isNotNull);
    expect(result!.distanceKm['rear'], 10.5);
    expect(result.distanceKm['ahead'], closeTo(4.94, .02));
    expect(result.smallestRemainingKm, closeTo(1.06, .02));
  });
  test('a minimum group range alone cannot establish reachability', () {
    expect(calculate([rider('rear', 0, 6), rider('ahead', .05, 12)]), isNull);
  });
  test('empty list, duplicated, stale, future and unconsented estimates give no recommendation', () {
    expect(calculate([]), isNull);
    expect(calculate([rider('same', 0, 12), rider('same', .05, 12)]), isNull);
    for (final at in [80000, now + 1]) {
      expect(
        calculate([rider('a', 0, 12, at: at), rider('b', .05, 12)]),
        isNull,
      );
    }
  });
  test('partial contributor coverage calculates bottleneck stop for >= 1 rider', () {
    final result = calculate([rider('solo', 0, 12)], total: 3);
    expect(result, isNotNull);
    expect(result!.contributors, 1);
    expect(result.totalRiders, 3);
    expect(result.isCompleteCoverage, isFalse);
    expect(result.bottleneckRiderId, 'solo');
  });
  test('complete coverage flags isCompleteCoverage as true and identifies bottleneck', () {
    final result = calculate([rider('rear', 0, 12), rider('ahead', .05, 6)], total: 2);
    expect(result, isNotNull);
    expect(result!.contributors, 2);
    expect(result.totalRiders, 2);
    expect(result.isCompleteCoverage, isTrue);
    expect(result.bottleneckRiderId, 'ahead');
  });
  test('prioritizes reachable verified COCO pump over closer unbranded pump with fallback', () {
    final unbranded = station(entry: 8000);
    final coco = RouteEssential(
      placeId: 'coco-1',
      visitId: 'coco-v1',
      name: 'BPCL COCO Shoolagiri',
      category: 'FUEL',
      source: 'osm',
      lat: 0,
      lng: .12,
      routePositionM: 11000,
      entryM: 11000,
      exitM: 12000,
      accessDistanceM: 200,
      detourDistanceM: 400,
      detourDurationS: 30,
      isCoco: true,
      operatorName: 'BPCL',
      priority: 1,
    );
    // Both reachable: COCO selected
    final cocoResult = calculate([rider('a', 0, 15)], total: 1, stations: [unbranded, coco]);
    expect(cocoResult, isNotNull);
    expect(cocoResult!.station.placeId, 'coco-1');
    expect(cocoResult.isVerifiedCoco, isTrue);

    // COCO out of range (requires > 11.2 km): unbranded fallback at 8.5 km selected
    final fallbackResult = calculate([rider('a', 0, 10)], total: 1, stations: [unbranded, coco]);
    expect(fallbackResult, isNotNull);
    expect(fallbackResult!.station.placeId, 'p');
    expect(fallbackResult.isVerifiedCoco, isFalse);
  });
  test(
    'offline, off-route and passed entry are not suggested',
    () {
      final riders = [rider('a', 0, 12), rider('b', .05, 12)];
      expect(calculate(riders, reliable: false), isNull);
      expect(calculate([rider('a', 0, 12, latitude: .01), riders[1]]), isNull);
      expect(calculate([riders[0], rider('b', .15, 12)]), isNull);
      expect(calculate(riders, route: []), isNull);
    },
  );
  test('overlapping loop passes and invalid coordinates are rejected', () {
    expect(
      calculate(
        [rider('a', .05, 12), rider('b', .02, 12)],
        route: [(0, 0), (0, .2), (0, 0)],
      ),
      isNull,
    );
    expect(
      calculate([rider('a', double.nan, 12), rider('b', .02, 12)]),
      isNull,
    );
  });
  test(
    'equal range boundary is allowed, excessive road access is rejected',
    () {
      expect(calculate([rider('a', 0, 10.5)], total: 1), isNotNull);
      expect(calculate([rider('a', 0, 10.49)], total: 1), isNull);
      expect(
        calculate(
          [rider('a', 0, 12)],
          total: 1,
          stations: [station(access: 3000)],
        ),
        isNull,
      );
    },
  );
}
