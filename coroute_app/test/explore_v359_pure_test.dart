// v3.59 Explore: admin config parsing, rider routes, and preparing a ride for sharing (pure Dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/explore/destinations.dart';
import 'package:coroute_app/domain/explore/explore_config.dart';

List<(double, double)> rideTo(double lat, double lng, {double km = 25}) {
  final n = (km * 10).round();
  return [for (var i = 0; i <= n; i++) (lat - (1 - i / n) * (km / 111), lng)];
}

void main() {
  test('config: admin order, unknown sections ignored, custom categories kept, fallback offline', () {
    final c = ExploreConfig.fromJson({
      'headline': 'Ride somewhere new',
      'sections': [
        {'id': 'near_you', 'title': 'Close by'},
        {'id': 'future_section', 'title': 'x'},
        {'id': 'featured'},
      ],
      'categories': [
        {'id': 'coffee', 'label': 'Coffee runs'},
        {'id': 'ghats', 'label': 'Ghats'},
      ],
      'featured': ['ds_aaaaaaaaaaaa', 3],
      'routes': {'enabled': false, 'showNotes': true},
    });
    expect(c.headline, 'Ride somewhere new');
    expect(c.sections.map((s) => s.id).toList(), ['near_you', 'featured']);
    expect(c.titleOf('near_you'), 'Close by');
    expect(c.titleOf('featured'), 'Picked for you');
    expect(c.labelOf('coffee'), 'Coffee runs');
    expect(c.featured, ['ds_aaaaaaaaaaaa']);
    expect(c.routesEnabled, isFalse);
    expect(ExploreConfig.fromJson(null).has(ExploreSectionId.nearYou), isTrue);
  });

  test('destinations: custom category ids filter and rank', () {
    final d = Destination.fromJson({'id': 'ds_1', 'name': 'Filter Coffee Point', 'lat': 13.1, 'lng': 77.6, 'category': 'coffee', 'tags': ['twisty']})!;
    expect(d.catId, 'coffee');
    expect(d.fitsKey('coffee'), isTrue);
    expect(d.fitsKey('twisty'), isTrue);
    expect(d.fitsKey('ghats'), isFalse);
    expect(d.fitsKey('all'), isTrue);
    final ranked = ExploreRanking.rank([d], categoryId: 'coffee');
    expect(ranked.length, 1);
    expect(ExploreRanking.rank([d], categoryId: 'ghats'), isEmpty);
    expect(Destination.fromJson(d.toJson())!.catId, 'coffee', reason: 'cached copy keeps the custom id');
  });

  test('rider route parsing and labels', () {
    final r = RiderRoute.fromJson({
      'id': 'rt_aaaaaaaaaaaa', 'destId': 'ds_1', 'username': 'ghat_rider', 'points': [[13.1, 77.6], [13.2, 77.61], 'bad'],
      'distanceKm': 62.4, 'durationMin': 125, 'day': '2026-11-14', 'note': ' Go early ',
    })!;
    expect(r.points.length, 2);
    expect(r.durationLabel, '2 h 5 min');
    expect(r.dayLabel, '14 Nov 2026');
    expect(r.note, 'Go early');
    expect(RiderRoute.fromJson({'id': 'x', 'destId': 'd', 'username': 'u', 'points': [[1, 1]], 'distanceKm': 1}), isNull);
  });

  test('sharing: finds the reached destination, trims both ends, thins long rides', () {
    final nandi = Destination(id: 'ds_n', name: 'Nandi Hills', lat: 13.3702, lng: 77.6835);
    final far = Destination(id: 'ds_f', name: 'Ooty', lat: 11.41, lng: 76.69);
    final track = rideTo(13.3702, 77.6835);
    expect(RouteSharing.reached(track, [far, nandi]).map((d) => d.id).toList(), ['ds_n']);
    final trimmed = RouteSharing.trimEnds(track);
    expect(RouteSharing.lengthM(track) - RouteSharing.lengthM(trimmed), greaterThan(1700));
    expect(RouteSharing.trimEnds(rideTo(13.37, 77.68, km: 2)), isEmpty, reason: 'too short to share');
    final long = rideTo(13.3702, 77.6835, km: 400);
    expect(RouteSharing.payload(long).length, lessThanOrEqualTo(RouteSharing.maxPoints));
    expect(RouteSharing.payload(track).first.length, 2);
    expect(RouteSharing.bounds(track), isNotNull);
  });
}
