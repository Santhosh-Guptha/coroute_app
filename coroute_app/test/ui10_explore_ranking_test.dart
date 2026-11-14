import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/explore/destinations.dart';

void main() {
  // Rider in central Bengaluru.
  const lat = 12.9716, lng = 77.5946;
  const nandi = Destination(id: 'd1', name: 'Nandi Hills', region: 'Karnataka', lat: 13.3702, lng: 77.6835, category: DestinationCategory.breakfast);
  const coorg = Destination(id: 'd2', name: 'Coorg', region: 'Karnataka', lat: 12.3375, lng: 75.8069, category: DestinationCategory.weekend, tags: [DestinationCategory.ghats]);
  const savandurga = Destination(id: 'd3', name: 'Savandurga', region: 'Karnataka', lat: 12.9196, lng: 77.2929, category: DestinationCategory.breakfast);
  const ooty = Destination(id: 'd4', name: 'Ooty', region: 'Tamil Nadu', lat: 11.4102, lng: 76.6950, category: DestinationCategory.weekend, tags: [DestinationCategory.twisty, DestinationCategory.ghats]);
  const all = [coorg, ooty, nandi, savandurga];

  group('distance ranking', () {
    test('nearest first, ranks are 1-based', () {
      final r = ExploreRanking.rank(all, lat: lat, lng: lng);
      expect(r.map((x) => x.destination.id).toList(), ['d3', 'd1', 'd4', 'd2']);
      expect(r.map((x) => x.rank).toList(), [1, 2, 3, 4]);
    });

    test('road km is the straight line times the road factor', () {
      final r = ExploreRanking.rank([nandi], lat: lat, lng: lng).single;
      final straight = ExploreRanking.haversineKm(lat, lng, nandi.lat, nandi.lng);
      expect(straight, closeTo(45.8, 1.5));
      expect(r.roadKm, closeTo(straight * ExploreRanking.roadFactor, 0.001));
      expect(r.rideTime!.inMinutes, (r.roadKm! / ExploreRanking.avgKmh * 60).round());
    });

    test('without a position the admin order is kept and no distance is shown', () {
      final r = ExploreRanking.rank(all);
      expect(r.map((x) => x.destination.id).toList(), ['d2', 'd4', 'd1', 'd3']);
      expect(r.every((x) => x.roadKm == null && x.rideTime == null), isTrue);
      // 0,0 is "no fix", not the Gulf of Guinea.
      expect(ExploreRanking.rank(all, lat: 0, lng: 0).first.roadKm, isNull);
    });
  });

  group('category filter and search', () {
    test('a category keeps its own places and places tagged with it', () {
      final ghats = ExploreRanking.rank(all, lat: lat, lng: lng, category: DestinationCategory.ghats);
      expect(ghats.map((x) => x.destination.id).toList(), ['d4', 'd2']);
      expect(ghats.first.rank, 1);
      final breakfast = ExploreRanking.rank(all, lat: lat, lng: lng, category: DestinationCategory.breakfast);
      expect(breakfast.map((x) => x.destination.id).toList(), ['d3', 'd1']);
      expect(ExploreRanking.rank(all, category: DestinationCategory.night), isEmpty);
    });

    test('search matches name, region and description, any case', () {
      expect(ExploreRanking.rank(all, query: 'tamil').single.destination.id, 'd4');
      expect(ExploreRanking.rank(all, query: 'NANDI').single.destination.id, 'd1');
      expect(ExploreRanking.rank(all, query: '  ').length, 4);
    });

    test('twisty and ghats chips appear only when some place carries them', () {
      expect(ExploreRanking.chipsFor(all), contains(DestinationCategory.twisty));
      expect(ExploreRanking.chipsFor([nandi, savandurga]), isNot(contains(DestinationCategory.ghats)));
      expect(ExploreRanking.chipsFor(const []).first, DestinationCategory.all);
    });
  });

  group('parsing and labels', () {
    test('bad rows are dropped, third-party photos are ignored', () {
      expect(Destination.fromJson({'id': 'x', 'name': 'A', 'lat': 100, 'lng': 1}), isNull);
      expect(Destination.fromJson({'id': '', 'name': 'A', 'lat': 1, 'lng': 1}), isNull);
      final d = Destination.fromJson({'id': 'x', 'name': ' Hampi ', 'lat': 15.335, 'lng': 76.46, 'category': 'one-day', 'photoUrl': 'https://example.com/a.jpg'})!;
      expect(d.name, 'Hampi');
      expect(d.category, DestinationCategory.oneDay);
      expect(d.photoUrl, isNull);
      final own = Destination.fromJson({'id': 'x', 'name': 'H', 'lat': 1, 'lng': 1, 'photoUrl': '/api/public/destinations/x/photo?v=2'})!;
      expect(own.photoUrl, '/api/public/destinations/x/photo?v=2');
      expect(Destination.fromJson(own.toJson())!.photoUrl, own.photoUrl);
    });

    test('km and time labels are rounded and honest about being estimates', () {
      expect(ExploreRanking.kmLabel(null), '');
      expect(ExploreRanking.kmLabel(3.4), '~3 km');
      expect(ExploreRanking.kmLabel(63), '~65 km');
      expect(ExploreRanking.kmLabel(1238), '~1,240 km');
      expect(ExploreRanking.timeLabel(const Duration(minutes: 42)), '40 min');
      expect(ExploreRanking.timeLabel(const Duration(minutes: 88)), '1.5 h');
      expect(ExploreRanking.timeLabel(const Duration(minutes: 480)), '8 h');
    });
  });
}
