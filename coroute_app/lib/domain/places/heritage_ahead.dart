import 'place_poi.dart';
import 'poi_category.dart';
import 'route_corridor.dart';

/// 3.55 "Historic places on your way": famous ancient and historic places close to the route
/// ahead, so riders know what they could visit on the way. Pure: no Flutter, no I/O.

/// One historic place ahead on the route.
class HeritageAhead {
  const HeritageAhead({required this.poi, required this.aheadM, required this.offM});
  final PlacePoi poi;

  /// Along the route from me to the point nearest the place.
  final double aheadM;

  /// From the route to the place.
  final double offM;

  /// "12 km ahead, 600 m off the route. Worth a stop?"
  String get message {
    final off = offM < 100 ? 'right on the route' : '${_dist(offM)} off the route';
    return '${_dist(aheadM)} ahead, $off. Worth a stop?';
  }

  static String _dist(double m) {
    if (m < 1000) return '${(m / 50).round() * 50} m';
    final km = m / 1000;
    return km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
  }
}

/// Historic places within [maxOffM] of [path] and between [minAheadM] and [maxAheadM] ahead of
/// me, nearest first. My progress is [progressM] along the route, or found from my position
/// ([myLat], [myLng]) when not given. Places of other categories are ignored.
List<HeritageAhead> heritageAhead({
  required RoutePath path,
  required Iterable<PlacePoi> candidates,
  double? progressM,
  double? myLat,
  double? myLng,
  double maxOffM = 1500,
  double minAheadM = 1000,
  double maxAheadM = 25000,
  int limit = 5,
}) {
  final out = <HeritageAhead>[];
  if (!path.valid) return out;
  var at = progressM;
  if (at == null && myLat != null && myLng != null) at = path.project(myLat, myLng)?.along;
  if (at == null) return out;
  final seen = <String>{};
  for (final p in candidates) {
    if (p.category != PoiCategory.heritage || !seen.add(p.id)) continue;
    final hit = path.project(p.lat, p.lng);
    if (hit == null || hit.off > maxOffM) continue;
    final ahead = hit.along - at;
    if (ahead < minAheadM || ahead > maxAheadM) continue;
    out.add(HeritageAhead(poi: p, aheadM: ahead, offM: hit.off));
  }
  out.sort((a, b) => a.aheadM.compareTo(b.aheadM));
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// When to tell the rider about one: at most once per place per ride, at most one notice every
/// [every], never while an SOS is open, and only a named place (a nameless "Historic place" is
/// not worth a stop on its own).
class HeritageNoticeGate {
  HeritageNoticeGate({this.every = const Duration(minutes: 10)});
  final Duration every;
  final Set<String> _told = {};
  int? _lastAtMs;

  /// The place to tell about now (and remembers it), or null.
  HeritageAhead? pick(List<HeritageAhead> ahead, {required int nowMs, required bool sosOpen}) {
    if (sosOpen) return null;
    final last = _lastAtMs;
    if (last != null && nowMs - last < every.inMilliseconds) return null;
    for (final h in ahead) {
      if (!h.poi.hasName || _told.contains(h.poi.id)) continue;
      _told.add(h.poi.id);
      _lastAtMs = nowMs;
      return h;
    }
    return null;
  }

  /// A new ride: every place may be told again.
  void reset() {
    _told.clear();
    _lastAtMs = null;
  }
}
