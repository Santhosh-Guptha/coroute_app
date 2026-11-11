import '../../domain/diag/diag_log.dart';
import '../models/route_model.dart';
import 'api_client.dart';

/// A place chosen on the map or from search.
class PickedPlace {
  final double lat;
  final double lng;
  final String name;
  final String category; // for stops: FUEL, FOOD, REST, SCENIC, TOLL, OTHER
  final int plannedDwellMin;

  const PickedPlace({required this.lat, required this.lng, this.name = '', this.category = 'REST', this.plannedDwellMin = 0});

  PickedPlace copyWith({double? lat, double? lng, String? name, String? category, int? plannedDwellMin}) => PickedPlace(
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        name: name ?? this.name,
        category: category ?? this.category,
        plannedDwellMin: plannedDwellMin ?? this.plannedDwellMin,
      );

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng, 'name': name, 'category': category, 'plannedDwellMin': plannedDwellMin};
}

class PlaceResult {
  final String name;
  final String displayName;
  final double lat;
  final double lng;

  /// Metres from the point the search was biased to (the map centre), when known.
  final int? distanceM;

  /// Outside the home country (India): shown only when India has nothing.
  final bool outside;

  const PlaceResult({required this.name, required this.displayName, required this.lat, required this.lng, this.distanceM, this.outside = false});

  /// One gateway search result, or null when it has no usable point.
  static PlaceResult? fromJson(Object? r) {
    if (r is! Map) return null;
    final lat = r['lat'], lng = r['lng'];
    if (lat is! num || lng is! num) return null;
    final la = lat.toDouble(), ln = lng.toDouble();
    if (!la.isFinite || !ln.isFinite || la.abs() > 90 || ln.abs() > 180) return null;
    final name = r['name']?.toString().trim() ?? '';
    final d = r['distanceM'];
    return PlaceResult(
      name: name.isNotEmpty ? name : '${la.toStringAsFixed(5)}, ${ln.toStringAsFixed(5)}',
      displayName: r['displayName']?.toString() ?? '',
      lat: la,
      lng: ln,
      distanceM: d is num && d.isFinite ? d.round() : null,
      outside: r['outside'] == true,
    );
  }

  static List<PlaceResult> listFrom(Object? list) =>
      list is List ? list.map(PlaceResult.fromJson).whereType<PlaceResult>().toList() : const <PlaceResult>[];
}

/// A search answer, or why there is none (so the screen can say "offline" or "try again"
/// instead of "No matching places").
class PlaceSearchOutcome {
  final List<PlaceResult> results;

  /// A short message for the rider when the search itself failed; null when it worked
  /// (an empty [results] then really means nothing was found).
  final String? error;

  const PlaceSearchOutcome(this.results, [this.error]);
  bool get failed => error != null;
}

/// What the gateway made of a pasted map link (POST /geo/link).
class MapLinkResolution {
  /// The point the link names (with its name, looked up when the link had none).
  final PlaceResult? place;

  /// Only a name was found: [results] is a search for [query].
  final String? query;
  final List<PlaceResult> results;
  final String? error;

  /// False when the link only gave a map view centre (check the pin).
  final bool precise;

  const MapLinkResolution({this.place, this.query, this.results = const [], this.error, this.precise = true});
}

/// "1.2 km", "850 m", "120 km": distance for a search result.
String placeDistanceLabel(int? metres) {
  if (metres == null || metres < 0) return '';
  if (metres < 1000) return '${(metres / 10).round() * 10} m';
  if (metres < 10000) return '${(metres / 1000).toStringAsFixed(1)} km';
  return '${(metres / 1000).round()} km';
}

/// Privacy-safe kind of a search text for diagnostics: never the text itself.
String placeQueryKind(String q) {
  if (RegExp(r'^[\d\s.,;:+\-°\x27"NSEWnsew]+$').hasMatch(q)) return 'numeric';
  if (RegExp(r'\d').hasMatch(q)) return 'mixed';
  return 'text';
}

/// Place search, place names and routes through the gateway, which caches
/// the free OpenStreetMap services for everyone and respects their limits.
class GeoService {
  GeoService(this._api);
  final ApiClient _api;

  /// Place names only (the old call). Prefer [searchPlaces], which says why it failed.
  Future<List<PlaceResult>> search(String query, {double? nearLat, double? nearLng}) async =>
      (await searchPlaces(query, nearLat: nearLat, nearLng: nearLng)).results;

  /// Searches places, India first and near ([nearLat], [nearLng]) first; the world when
  /// India has nothing, or at once with [everywhere]. Never throws.
  Future<PlaceSearchOutcome> searchPlaces(String query, {double? nearLat, double? nearLng, bool everywhere = false}) async {
    final q = query.trim();
    if (q.length < 3) return const PlaceSearchOutcome([]);
    final near = (nearLat != null && nearLng != null && nearLat.isFinite && nearLng.isFinite)
        ? '&lat=${nearLat.toStringAsFixed(3)}&lng=${nearLng.toStringAsFixed(3)}'
        : '';
    final sw = Stopwatch()..start();
    try {
      final res = await _api.get('/geo/search?q=${Uri.encodeQueryComponent(q)}$near${everywhere ? '&everywhere=1' : ''}');
      final list = PlaceResult.listFrom(res is Map ? res['results'] : null);
      // Length and kind only: never the words typed (they can be a home address).
      DiagLog.info(DiagCat.network, 'place_search', {'len': q.length, 'kind': placeQueryKind(q), 'count': list.length, 'ms': sw.elapsedMilliseconds, 'scope': everywhere ? 'world' : 'country'});
      return PlaceSearchOutcome(list);
    } on ApiException catch (e) {
      DiagLog.warn(DiagCat.network, 'place_search_failed', {'len': q.length, 'kind': placeQueryKind(q), 'status': e.statusCode, 'ms': sw.elapsedMilliseconds});
      return PlaceSearchOutcome(const [], _searchError(e));
    } catch (e) {
      DiagLog.warn(DiagCat.network, 'place_search_failed', {'len': q.length, 'type': e.runtimeType.toString()});
      return const PlaceSearchOutcome([], 'Search failed. Try again.');
    }
  }

  static String _searchError(ApiException e) {
    if (e.isOffline) return 'You seem to be offline. Check your connection and try again.';
    if (e.statusCode == 429) return 'Too many searches just now. Wait a few seconds and try again.';
    if (e.statusCode == 503) return 'Place search is busy right now. Try again in a moment.';
    if (e.isUnauthorized) return 'Sign in again to search places.';
    return 'Search failed. Try again.';
  }

  /// Reads a pasted map link through the gateway: expands Google short links
  /// (maps.app.goo.gl, goo.gl/maps) and names a bare point. Never throws.
  Future<MapLinkResolution> resolveLink(String text, {double? nearLat, double? nearLng}) async {
    try {
      final res = await _api.post('/geo/link', {
        'text': text.length > 2000 ? text.substring(0, 2000) : text,
        if (nearLat != null && nearLng != null) 'lat': double.parse(nearLat.toStringAsFixed(3)),
        if (nearLat != null && nearLng != null) 'lng': double.parse(nearLng.toStringAsFixed(3)),
      }, const Duration(seconds: 15));
      if (res is! Map) return const MapLinkResolution(error: 'Could not read this link.');
      final place = PlaceResult.fromJson(res['place']);
      DiagLog.info(DiagCat.network, 'map_link', {'kind': place != null ? 'point' : 'query', 'ok': true});
      final raw = res['place'];
      if (place != null) return MapLinkResolution(place: place, precise: !(raw is Map && raw['precise'] == false));
      return MapLinkResolution(query: res['query']?.toString(), results: PlaceResult.listFrom(res['results']));
    } on ApiException catch (e) {
      DiagLog.warn(DiagCat.network, 'map_link_failed', {'status': e.statusCode, 'code': e.code ?? ''});
      if (e.isOffline) return const MapLinkResolution(error: 'You seem to be offline. Check your connection and try again.');
      if (e.statusCode == 422 || e.statusCode == 400) return MapLinkResolution(error: e.message);
      if (e.statusCode == 429) return const MapLinkResolution(error: 'Too many links just now. Wait a few seconds and try again.');
      return const MapLinkResolution(error: 'Could not open this link right now. Try again.');
    } catch (_) {
      return const MapLinkResolution(error: 'Could not open this link right now. Try again.');
    }
  }

  /// Short name of a place ("HP fuel station, Shamshabad"), or null.
  Future<String?> reverse(double lat, double lng) async {
    try {
      final res = await _api.get('/geo/reverse?lat=${lat.toStringAsFixed(5)}&lng=${lng.toStringAsFixed(5)}');
      final n = res is Map ? res['name'] : null;
      return (n is String && n.isNotEmpty) ? n : null;
    } catch (_) {
      return null;
    }
  }

  /// Driving route through 2 to 25 waypoints (lat, lng), or null when unavailable.
  /// With [startHeadingDeg] (my direction of travel, a new route from where I
  /// am) the route leaves the first point in that direction when it can, so
  /// it does not start with a U-turn.
  Future<RouteModel?> route(List<(double, double)> waypoints, {double? startHeadingDeg}) async {
    if (waypoints.length < 2) return null;
    final h = startHeadingDeg;
    try {
      final res = await _api.post('/geo/route', {
        'waypoints': [for (final (lat, lng) in waypoints) {'lat': lat, 'lng': lng}],
        if (h != null && h.isFinite) 'startBearing': ((h % 360) + 360).round() % 360,
      }, const Duration(seconds: 15));
      if (res is! Map) return null;
      return await RouteModel.fromJsonAsync(Map<String, dynamic>.from(res));
    } catch (_) {
      return null;
    }
  }
}
