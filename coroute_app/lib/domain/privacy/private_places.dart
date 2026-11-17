import 'dart:convert';
import 'dart:math' as math;

/// 3.56 (round 6): "Private places" (docs/handbook: "Private places"). Up to three places (home,
/// work, ...) the rider marks on a map. They are kept ONLY on the phone. Within [radiusM] of one:
///  * the ride's recorded route is not saved and not uploaded (so it is missing from trip reports,
///    shared trip pages, route pictures and GPX files, for everyone);
///  * nothing is added to the anonymous road data ("Help make roads safer").
/// v3.63 privacy zones (owner: "others will not know the home or area the rider is coming from; safe
/// for girls"): each place has its own radius (300 m / 500 m / 1 km) and, within it, the LIVE position is
/// hidden too ([LivePrivacyMask]): the group, guardians, public ride pages, guests and live links get no
/// position at all, only "Location hidden near a saved place".
/// SAFETY OVERRIDE: during an SOS, a crash alarm / countdown or rider-down alarm the exact position is
/// always shared (and the SOS itself always carries it); emergency texts always use the exact position.
///
/// Pure Dart; tested in test/private_places_356_test.dart.
class PrivatePlace {
  final String label;
  final double lat;
  final double lng;

  /// v3.63: hidden radius (one of [PrivatePlaces.radiusChoices]); places saved before keep 300 m.
  final double radiusM;
  const PrivatePlace({required this.label, required this.lat, required this.lng, this.radiusM = PrivatePlaces.radiusM});

  Map<String, Object> toJson() => {'l': label, 'a': lat, 'o': lng, if (radiusM != PrivatePlaces.radiusM) 'r': radiusM};

  static PrivatePlace? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final a = raw['a'], o = raw['o'];
    if (a is! num || o is! num || !a.isFinite || !o.isFinite) return null;
    if (a.abs() > 90 || o.abs() > 180 || (a == 0 && o == 0)) return null;
    final l = (raw['l']?.toString() ?? '').trim();
    final r = raw['r'];
    final radius = r is num && PrivatePlaces.radiusChoices.contains(r.toDouble()) ? r.toDouble() : PrivatePlaces.radiusM;
    return PrivatePlace(label: l.length > 24 ? l.substring(0, 24) : l, lat: a.toDouble(), lng: o.toDouble(), radiusM: radius);
  }
}

class PrivatePlaces {
  PrivatePlaces._();

  static const int maxPlaces = 3;

  /// The hidden radius of places saved before v3.63: the same 300 m that is cut from both ends of every ride.
  static const double radiusM = 300;

  /// v3.63: the radii a rider can choose; new places default to [defaultRadiusM].
  static const List<double> radiusChoices = [300, 500, 1000];
  static const double defaultRadiusM = 500;

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

  /// Is this point inside the hidden radius of one of [places]? Each place's own radius ([radius]
  /// overrides it for every place; [extraM] widens each radius, for the exit hysteresis).
  static bool isNear(List<PrivatePlace> places, double lat, double lng, {double? radius, double extraM = 0}) {
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return false;
    for (final p in places) {
      if (distanceM(p.lat, p.lng, lat, lng) < (radius ?? p.radiusM) + extraM) return true;
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

/// v3.63 live position masking for privacy zones (pure; one per ride on this phone).
///
/// [update] says, for each outgoing position, whether it is hidden:
///  * hidden when the point is inside a place's radius; once hidden it stays hidden until the rider is
///    [exitMarginM] beyond the radius (no flicker at the edge, which would trace the zone's border);
///  * NEVER hidden while [emergency] is true (own SOS open or pending, crash alarm / countdown, rider-down
///    alarm): the exact position goes to the group and responders for the whole emergency;
///  * a fix without a position (0, 0 / not finite) is never "hidden" (nothing to hide).
/// While hidden the phone sends its telemetry WITHOUT a position (lat / lng 0 and `zoneHidden: true`), so
/// the gateway, the group, guardians, public pages, guests and live links never learn where the place is.
class LivePrivacyMask {
  LivePrivacyMask({this.exitMarginM = 50});

  final double exitMarginM;
  bool _hidden = false;
  int? _hiddenSinceMs;

  bool get hidden => _hidden;

  /// When the current hidden spell began (null when not hidden).
  int? get hiddenSinceMs => _hiddenSinceMs;

  bool update(List<PrivatePlace> places, double lat, double lng, {required bool emergency, int nowMs = 0}) {
    if (emergency || places.isEmpty || !lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) {
      if (emergency || places.isEmpty) _set(false, nowMs);
      return _hidden;
    }
    final inside = PrivatePlaces.isNear(places, lat, lng);
    final stillInside = _hidden && PrivatePlaces.isNear(places, lat, lng, extraM: exitMarginM);
    _set(inside || stillInside, nowMs);
    return _hidden;
  }

  void reset() => _set(false, 0);

  void _set(bool v, int nowMs) {
    if (v && !_hidden) _hiddenSinceMs = nowMs;
    if (!v) _hiddenSinceMs = null;
    _hidden = v;
  }

  /// The position to send: the real one, or (0, 0) while hidden.
  static (double, double) shared(bool hidden, double lat, double lng) => hidden ? (0.0, 0.0) : (lat, lng);
}
