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
  const PlaceResult({required this.name, required this.displayName, required this.lat, required this.lng});
}

/// Place search, place names and routes through the gateway, which caches
/// the free OpenStreetMap services for everyone and respects their limits.
class GeoService {
  GeoService(this._api);
  final ApiClient _api;

  Future<List<PlaceResult>> search(String query, {double? nearLat, double? nearLng}) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    final near = (nearLat != null && nearLng != null) ? '&lat=$nearLat&lng=$nearLng' : '';
    try {
      final res = await _api.get('/geo/search?q=${Uri.encodeQueryComponent(q)}$near');
      final list = res is Map ? res['results'] : null;
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .where((r) => r['lat'] is num && r['lng'] is num)
          .map((r) => PlaceResult(
                name: r['name']?.toString() ?? '',
                displayName: r['displayName']?.toString() ?? r['name']?.toString() ?? '',
                lat: (r['lat'] as num).toDouble(),
                lng: (r['lng'] as num).toDouble(),
              ))
          .toList();
    } catch (_) {
      return const [];
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
  Future<RouteModel?> route(List<(double, double)> waypoints) async {
    if (waypoints.length < 2) return null;
    try {
      final res = await _api.post('/geo/route', {
        'waypoints': [for (final (lat, lng) in waypoints) {'lat': lat, 'lng': lng}],
      }, const Duration(seconds: 15));
      return res is Map ? RouteModel.fromJson(Map<String, dynamic>.from(res)) : null;
    } catch (_) {
      return null;
    }
  }
}
