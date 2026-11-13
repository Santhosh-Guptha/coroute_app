import 'dart:convert';
import 'dart:math' as math;

/// 3.56 (round 6): "Private places" (docs/handbook: "Private places"). Up to three places (home,
/// work, ...) the rider marks on a map. They are kept ONLY on the phone. Within [radiusM] of one:
///  * the ride's recorded route is not saved and not uploaded (so it is missing from trip reports,
///    shared trip pages, route pictures and GPX files, for everyone);
///  * nothing is added to the anonymous road data ("Help make roads safer").
/// The LIVE position during a ride is NOT hidden: the group, a guardian's live link and an SOS always
/// get the real position (safety comes first).
///
/// Pure Dart; tested in test/private_places_356_test.dart.
class PrivatePlace {
  final String label;
  final double lat;
  final double lng;
  const PrivatePlace({required this.label, required this.lat, required this.lng});

  Map<String, Object> toJson() => {'l': label, 'a': lat, 'o': lng};

  static PrivatePlace? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final a = raw['a'], o = raw['o'];
    if (a is! num || o is! num || !a.isFinite || !o.isFinite) return null;
    if (a.abs() > 90 || o.abs() > 180 || (a == 0 && o == 0)) return null;
    final l = (raw['l']?.toString() ?? '').trim();
    return PrivatePlace(label: l.length > 24 ? l.substring(0, 24) : l, lat: a.toDouble(), lng: o.toDouble());
  }
}

class PrivatePlaces {
  PrivatePlaces._();

  static const int maxPlaces = 3;

  /// The hidden radius around each place: the same 300 m that is cut from both ends of every ride.
  static const double radiusM = 300;

  /// At most [maxPlaces] valid places from stored JSON (anything unreadable is skipped).
  static List<PrivatePlace> decode(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final raw = jsonDecode(json);
      if (raw is! List) return const [];
      return [for (final r in raw) ?PrivatePlace.fromJson(r)].take(maxPlaces).toList();
    } catch (_) {
      return const [];
    }
  }

  static String encode(List<PrivatePlace> places) => jsonEncode([for (final p in places.take(maxPlaces)) p.toJson()]);

  /// Is this point inside the hidden radius of one of [places]?
  static bool isNear(List<PrivatePlace> places, double lat, double lng, {double radius = radiusM}) {
    if (!lat.isFinite || !lng.isFinite) return false;
    for (final p in places) {
      if (distanceM(p.lat, p.lng, lat, lng) < radius) return true;
    }
    return false;
  }

  /// [points] without the ones near a private place (order kept).
  static List<T> trim<T>(List<PrivatePlace> places, List<T> points, (double, double) Function(T) at) {
    if (places.isEmpty) return points;
    return [
      for (final p in points)
        if (!isNear(places, at(p).$1, at(p).$2)) p,
    ];
  }

  /// A new list with [place] added, or null when the list is full.
  static List<PrivatePlace>? add(List<PrivatePlace> places, PrivatePlace place) =>
      places.length >= maxPlaces ? null : [...places, place];

  static double distanceM(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dp = p2 - p1, dl = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }
}
