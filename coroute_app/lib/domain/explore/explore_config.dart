// v3.59 Explore: the admin's layout (sections, categories, featured places) and real riders' shared routes.
// Pure Dart (no Flutter), tested with tool/pure_dart_test. Gateway: src/explore.js.
library;

import 'dart:math' as math;

import 'destinations.dart';

/// Section ids the gateway may send, in the admin's order. Unknown ids are ignored (older app, newer server).
class ExploreSectionId {
  ExploreSectionId._();
  static const featured = 'featured';
  static const riderRoutes = 'rider_routes';
  static const nearYou = 'near_you';
  static const categories = 'categories';
  static const suggest = 'suggest';
  static const all = [featured, riderRoutes, nearYou, categories, suggest];
}

class ExploreSection {
  final String id;
  final String title;
  const ExploreSection(this.id, this.title);
}

class ExploreCategory {
  final String id;
  final String label;
  const ExploreCategory(this.id, this.label);
}

/// What the Explore tab shows (GET /api/public/explore `config`). [fallback] is used offline and with an older
/// gateway that only has /public/destinations.
class ExploreConfig {
  final String headline;
  final String subtitle;
  final List<ExploreSection> sections;
  final List<ExploreCategory> categories;
  final List<String> featured;
  final bool routesEnabled;
  final bool showNotes;

  const ExploreConfig({
    required this.headline,
    required this.subtitle,
    required this.sections,
    required this.categories,
    this.featured = const [],
    this.routesEnabled = true,
    this.showNotes = true,
  });

  static const ExploreConfig fallback = ExploreConfig(
    headline: 'Where to next?',
    subtitle: 'Places riders love, and the roads real CoRoute riders took to get there.',
    sections: [
      ExploreSection(ExploreSectionId.featured, 'Picked for you'),
      ExploreSection(ExploreSectionId.riderRoutes, 'Ridden by CoRoute riders'),
      ExploreSection(ExploreSectionId.nearYou, 'Rides near you'),
      ExploreSection(ExploreSectionId.categories, 'Browse by type'),
      ExploreSection(ExploreSectionId.suggest, 'Know a great ride?'),
    ],
    categories: [
      ExploreCategory('breakfast', 'Breakfast rides'),
      ExploreCategory('one_day', 'One-day rides'),
      ExploreCategory('weekend', 'Weekend trips'),
      ExploreCategory('twisty', 'Twisty roads'),
      ExploreCategory('ghats', 'Ghats and hills'),
      ExploreCategory('night', 'Night rides'),
    ],
  );

  bool has(String sectionId) => sections.any((s) => s.id == sectionId);
  String titleOf(String sectionId) => sections.firstWhere((s) => s.id == sectionId, orElse: () => ExploreSection(sectionId, '')).title;
  String labelOf(String categoryId) => categories.firstWhere((c) => c.id == categoryId, orElse: () => ExploreCategory(categoryId, '')).label;

  static ExploreConfig fromJson(Object? j) {
    if (j is! Map) return fallback;
    String text(Object? v, String d) => v is String && v.trim().isNotEmpty ? v.trim() : d;
    final rawS = j['sections'], rawC = j['categories'], rawF = j['featured'], routes = j['routes'];
    final sections = <ExploreSection>[
      if (rawS is List)
        for (final s in rawS)
          if (s is Map && ExploreSectionId.all.contains(s['id'])) ExploreSection(s['id'] as String, text(s['title'], fallback.titleOf(s['id'] as String))),
    ];
    final cats = <ExploreCategory>[
      if (rawC is List)
        for (final c in rawC)
          if (c is Map && c['id'] is String && (c['id'] as String).isNotEmpty) ExploreCategory(c['id'] as String, text(c['label'], c['id'] as String)),
    ];
    return ExploreConfig(
      headline: text(j['headline'], fallback.headline),
      subtitle: j['subtitle'] is String ? (j['subtitle'] as String).trim() : fallback.subtitle,
      sections: rawS is List ? sections : fallback.sections,
      categories: rawC is List ? cats : fallback.categories,
      featured: [if (rawF is List) for (final f in rawF) if (f is String) f],
      routesEnabled: routes is Map ? routes['enabled'] != false : true,
      showNotes: routes is Map ? routes['showNotes'] != false : true,
    );
  }
}

/// A route a rider chose to share (GET /api/explore/destinations/:id/routes).
class RiderRoute {
  final String id;
  final String destId;
  final String username;
  final List<(double, double)> points;
  final double distanceKm;
  final int? durationMin;

  /// Calendar day "2026-11-14" (no time of day is stored).
  final String day;
  final String note;
  final String bike;

  /// Only on my own routes: 'live' or 'hidden' (hidden by a moderator).
  final String? status;

  const RiderRoute({
    required this.id,
    required this.destId,
    required this.username,
    required this.points,
    required this.distanceKm,
    this.durationMin,
    required this.day,
    this.note = '',
    this.bike = '',
    this.status,
  });

  static RiderRoute? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], dest = j['destId'], user = j['username'], pts = j['points'], km = j['distanceKm'];
    if (id is! String || dest is! String || user is! String || pts is! List || km is! num) return null;
    final points = <(double, double)>[
      for (final p in pts)
        if (p is List && p.length >= 2 && p[0] is num && p[1] is num) ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
    if (points.length < 2) return null;
    final dur = j['durationMin'];
    return RiderRoute(
      id: id,
      destId: dest,
      username: user,
      points: points,
      distanceKm: km.toDouble(),
      durationMin: dur is num ? dur.round() : null,
      day: j['day'] is String ? j['day'] as String : '',
      note: j['note'] is String ? (j['note'] as String).trim() : '',
      bike: j['bike'] is String ? (j['bike'] as String).trim() : '',
      status: j['status'] is String ? j['status'] as String : null,
    );
  }

  /// "3 h 40 min", "55 min", or "".
  String get durationLabel {
    final m = durationMin;
    if (m == null) return '';
    if (m < 60) return '$m min';
    return m % 60 == 0 ? '${m ~/ 60} h' : '${m ~/ 60} h ${m % 60} min';
  }

  /// "14 Nov 2026" from the day, or "".
  String get dayLabel {
    final p = day.split('-');
    if (p.length != 3) return '';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final m = int.tryParse(p[1]) ?? 0;
    if (m < 1 || m > 12) return '';
    return '${int.tryParse(p[2]) ?? p[2]} ${months[m - 1]} ${p[0]}';
  }
}

/// Preparing a finished ride for sharing, on the phone (the gateway trims and simplifies again).
class RouteSharing {
  RouteSharing._();

  /// The rider must pass within this distance of the destination (same rule as the gateway).
  static const double reachKm = 3;

  /// Left out at both ends so nobody's home or office can be found (same as the gateway).
  static const double trimM = 1000;

  /// Points sent at most (the gateway keeps at most 300 after its own simplification).
  static const int maxPoints = 1500;

  static double _m(double lat1, double lng1, double lat2, double lng2) => ExploreRanking.haversineKm(lat1, lng1, lat2, lng2) * 1000;

  static double lengthM(List<(double, double)> pts) {
    var s = 0.0;
    for (var i = 1; i < pts.length; i++) {
      s += _m(pts[i - 1].$1, pts[i - 1].$2, pts[i].$1, pts[i].$2);
    }
    return s;
  }

  /// The curated destinations this ride reached (some point within [reachKm]), nearest pass first.
  static List<Destination> reached(List<(double, double)> track, List<Destination> all) {
    if (track.length < 2) return const [];
    final hits = <(Destination, double)>[];
    for (final d in all) {
      var best = double.infinity;
      for (final p in track) {
        final m = _m(p.$1, p.$2, d.lat, d.lng);
        if (m < best) best = m;
      }
      if (best <= reachKm * 1000) hits.add((d, best));
    }
    hits.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final h in hits) h.$1];
  }

  /// Drops the first and last [trimM] along the path; empty when the ride is too short to share.
  static List<(double, double)> trimEnds(List<(double, double)> pts, {double m = trimM}) {
    final total = lengthM(pts);
    if (pts.length < 2 || total <= 2 * m + 500) return const [];
    var acc = 0.0, start = 0;
    for (var i = 1; i < pts.length; i++) {
      acc += _m(pts[i - 1].$1, pts[i - 1].$2, pts[i].$1, pts[i].$2);
      if (acc >= m) {
        start = i;
        break;
      }
    }
    acc = 0;
    var end = pts.length - 1;
    for (var i = pts.length - 1; i > 0; i--) {
      acc += _m(pts[i].$1, pts[i].$2, pts[i - 1].$1, pts[i - 1].$2);
      if (acc >= m) {
        end = i - 1;
        break;
      }
    }
    return end > start ? pts.sublist(start, end + 1) : const [];
  }

  /// Keeps every n-th point so at most [max] remain (first and last kept).
  static List<(double, double)> thin(List<(double, double)> pts, {int max = maxPoints}) {
    if (pts.length <= max) return pts;
    final step = pts.length / (max - 1);
    return [for (var i = 0; i < max - 1; i++) pts[(i * step).floor()], pts.last];
  }

  /// What the phone sends: trimmed, thinned, 5 decimals. Empty = cannot be shared.
  static List<List<double>> payload(List<(double, double)> track) {
    double r5(double v) => (v * 1e5).roundToDouble() / 1e5;
    return [for (final p in thin(trimEnds(track))) [r5(p.$1), r5(p.$2)]];
  }

  /// Bounding box (south, west, north, east) of a route, for map fitting; null for fewer than 2 points.
  static (double, double, double, double)? bounds(List<(double, double)> pts) {
    if (pts.length < 2) return null;
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    for (final p in pts) {
      s = math.min(s, p.$1);
      n = math.max(n, p.$1);
      w = math.min(w, p.$2);
      e = math.max(e, p.$2);
    }
    return (s, w, n, e);
  }
}
