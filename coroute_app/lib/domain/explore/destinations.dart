// v3.58 Explore: admin-curated rider destinations, ranked by distance from the rider. Pure Dart (no Flutter), so
// tool/pure_dart_test runs its tests. Distance and time are computed on the phone: straight line x road factor.
library;

import 'dart:math' as math;

/// The chips on Explore. [all] is not a stored category.
enum DestinationCategory { all, breakfast, night, oneDay, weekend, twisty, ghats }

extension DestinationCategoryText on DestinationCategory {
  /// Wire value (gateway `category`), and the chip id.
  String get key => switch (this) {
        DestinationCategory.all => 'all',
        DestinationCategory.breakfast => 'breakfast',
        DestinationCategory.night => 'night',
        DestinationCategory.oneDay => 'one_day',
        DestinationCategory.weekend => 'weekend',
        DestinationCategory.twisty => 'twisty',
        DestinationCategory.ghats => 'ghats',
      };

  String get label => switch (this) {
        DestinationCategory.all => 'All',
        DestinationCategory.breakfast => 'Breakfast',
        DestinationCategory.night => 'Night',
        DestinationCategory.oneDay => 'One day',
        DestinationCategory.weekend => 'Weekend',
        DestinationCategory.twisty => 'Twisty roads',
        DestinationCategory.ghats => 'Ghats',
      };

  /// "Breakfast ride", used on the hero badge.
  String get rideLabel => switch (this) {
        DestinationCategory.all => 'Ride',
        DestinationCategory.breakfast => 'Breakfast ride',
        DestinationCategory.night => 'Night ride',
        DestinationCategory.oneDay => 'One-day ride',
        DestinationCategory.weekend => 'Weekend ride',
        DestinationCategory.twisty => 'Twisty roads',
        DestinationCategory.ghats => 'Ghat ride',
      };

  static DestinationCategory parse(Object? raw) {
    final s = raw?.toString().trim().toLowerCase().replaceAll('-', '_') ?? '';
    for (final c in DestinationCategory.values) {
      if (c != DestinationCategory.all && c.key == s) return c;
    }
    return DestinationCategory.oneDay;
  }
}

/// One curated place to ride to (GET /api/public/destinations).
class Destination {
  final String id;
  final String name;
  final String region;
  final double lat;
  final double lng;
  final DestinationCategory category;

  /// Extra chips this place also fits (e.g. a ghat road that is also a weekend ride).
  final List<DestinationCategory> tags;
  final String description;

  /// `/api/public/destinations/<id>/photo` when the admin uploaded one, else null (gradient art is drawn).
  final String? photoUrl;

  const Destination({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.region = '',
    this.category = DestinationCategory.oneDay,
    this.tags = const [],
    this.description = '',
    this.photoUrl,
  });

  /// Null when the row is unusable (no id / name / valid coordinates).
  static Destination? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], lat = j['lat'], lng = j['lng'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty) return null;
    if (lat is! num || lng is! num || !lat.isFinite || !lng.isFinite || lat.abs() > 90 || lng.abs() > 180) return null;
    final photo = j['photoUrl'];
    final rawTags = j['tags'];
    return Destination(
      id: id,
      name: name.trim(),
      region: j['region'] is String ? (j['region'] as String).trim() : '',
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      category: DestinationCategoryText.parse(j['category']),
      tags: [
        if (rawTags is List)
          for (final t in rawTags) DestinationCategoryText.parse(t),
      ],
      description: j['description'] is String ? (j['description'] as String).trim() : '',
      // Only our own gateway's photo route; never a third-party URL.
      photoUrl: photo is String && photo.startsWith('/api/public/destinations/') ? photo : null,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'region': region,
        'lat': lat,
        'lng': lng,
        'category': category.key,
        'tags': [for (final t in tags) t.key],
        'description': description,
        if (photoUrl != null) 'photoUrl': photoUrl,
      };

  bool fits(DestinationCategory c) => c == DestinationCategory.all || category == c || tags.contains(c);
}

/// A destination with its distance from the rider (null when the rider's position is unknown).
class RankedDestination {
  final Destination destination;
  final int rank;
  final double? roadKm;
  final Duration? rideTime;
  const RankedDestination(this.destination, this.rank, this.roadKm, this.rideTime);
}

class ExploreRanking {
  ExploreRanking._();

  /// Roads are longer than the straight line; 1.3 is a fair average for Indian highways and state roads.
  static const double roadFactor = 1.3;

  /// Average moving speed for the time estimate, km/h (a relaxed group pace with short stops).
  static const double avgKmh = 45;

  static double haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1, math.sqrt(a)));
  }

  static double roadKmBetween(double lat1, double lng1, double lat2, double lng2) => haversineKm(lat1, lng1, lat2, lng2) * roadFactor;

  static Duration rideTimeFor(double roadKm) => Duration(minutes: (roadKm / avgKmh * 60).round());

  /// Case-insensitive match on name, region and description.
  static bool matches(Destination d, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return d.name.toLowerCase().contains(q) || d.region.toLowerCase().contains(q) || d.description.toLowerCase().contains(q);
  }

  /// Filters by [category] and [query], then ranks nearest first (1-based ranks). Without a position the
  /// admin's order is kept and no distance is shown. Ties keep the input order (stable).
  static List<RankedDestination> rank(
    List<Destination> all, {
    double? lat,
    double? lng,
    DestinationCategory category = DestinationCategory.all,
    String query = '',
  }) {
    final hasFix = lat != null && lng != null && lat.isFinite && lng.isFinite && !(lat == 0 && lng == 0);
    final picked = [
      for (var i = 0; i < all.length; i++)
        if (all[i].fits(category) && matches(all[i], query)) (i, all[i], hasFix ? roadKmBetween(lat, lng, all[i].lat, all[i].lng) : null),
    ];
    if (hasFix) {
      picked.sort((a, b) {
        final c = a.$3!.compareTo(b.$3!);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    }
    return [
      for (var i = 0; i < picked.length; i++)
        RankedDestination(picked[i].$2, i + 1, picked[i].$3, picked[i].$3 == null ? null : rideTimeFor(picked[i].$3!)),
    ];
  }

  /// Chips worth showing: All, the four ride kinds, and Twisty / Ghats only when some destination carries them.
  static List<DestinationCategory> chipsFor(List<Destination> all) => [
        DestinationCategory.all,
        DestinationCategory.breakfast,
        DestinationCategory.night,
        DestinationCategory.oneDay,
        DestinationCategory.weekend,
        if (all.any((d) => d.fits(DestinationCategory.twisty))) DestinationCategory.twisty,
        if (all.any((d) => d.fits(DestinationCategory.ghats))) DestinationCategory.ghats,
      ];

  /// "~65 km", "~1,240 km", or "" without a distance.
  static String kmLabel(double? km) {
    if (km == null) return '';
    final n = km < 10 ? km.round().clamp(1, 9) : (km / 5).round() * 5;
    final s = n.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
    return '~$s km';
  }

  /// "45 min", "1.5 h", "8 h", or "" without a time.
  static String timeLabel(Duration? d) {
    if (d == null) return '';
    final m = d.inMinutes;
    if (m < 60) return '${(m / 5).round().clamp(1, 11) * 5} min';
    final h = (m / 30).round() / 2;
    return h == h.roundToDouble() ? '${h.round()} h' : '${h.toStringAsFixed(1)} h';
  }
}
