import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class PlaceSuggestion {
  final String displayName;
  final double lat;
  final double lng;

  PlaceSuggestion({
    required this.displayName,
    required this.lat,
    required this.lng,
  });

  factory PlaceSuggestion.fromJson(Map<String, dynamic> json) {
    return PlaceSuggestion(
      displayName: json['display_name'] ?? '',
      lat: double.tryParse(json['lat']?.toString() ?? '') ?? 0.0,
      lng: double.tryParse(json['lon']?.toString() ?? '') ?? 0.0,
    );
  }
}

class RouteDetails {
  final double distanceKm;
  final double durationMinutes;
  final List<LatLng> polyline;

  RouteDetails({
    required this.distanceKm,
    required this.durationMinutes,
    required this.polyline,
  });
}

class RoutingService {
  static const String _nominatimUrl = 'https://nominatim.openstreetmap.org/search';
  static const String _osrmUrl = 'https://router.project-osrm.org/route/v1/driving';
  static const String _userAgent = 'CoRouteApp/2.4 (devmonks.space)';

  /// Live place search using OpenStreetMap Nominatim
  static Future<List<PlaceSuggestion>> searchPlaces(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 3) return [];

    try {
      final uri = Uri.parse('$_nominatimUrl?q=${Uri.encodeComponent(trimmed)}&format=json&limit=5&addressdetails=1');
      final res = await http.get(
        uri,
        headers: {'User-Agent': _userAgent, 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is List) {
          return decoded
              .whereType<Map<String, dynamic>>()
              .map((e) => PlaceSuggestion.fromJson(e))
              .where((p) => p.lat != 0.0 && p.lng != 0.0)
              .toList();
        }
      }
    } catch (e) {
      debugPrint('Nominatim place search error: $e');
    }
    return [];
  }

  /// Calculates driving route geometry from OSRM
  static Future<RouteDetails?> fetchRoute({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
  }) async {
    if (startLat == 0.0 || startLng == 0.0 || endLat == 0.0 || endLng == 0.0) {
      return null;
    }

    try {
      final waypoints = '$startLng,$startLat;$endLng,$endLat';
      final uri = Uri.parse('$_osrmUrl/$waypoints?overview=full&geometries=geojson');
      final res = await http.get(
        uri,
        headers: {'User-Agent': _userAgent, 'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['routes'] is List && (data['routes'] as List).isNotEmpty) {
          final firstRoute = data['routes'][0];
          final distanceMeters = (firstRoute['distance'] as num?)?.toDouble() ?? 0.0;
          final durationSeconds = (firstRoute['duration'] as num?)?.toDouble() ?? 0.0;

          final coordsList = firstRoute['geometry']?['coordinates'] as List? ?? [];
          final List<LatLng> polyline = [];
          for (final c in coordsList) {
            if (c is List && c.length >= 2) {
              final lng = (c[0] as num).toDouble();
              final lat = (c[1] as num).toDouble();
              polyline.add(LatLng(lat, lng));
            }
          }

          return RouteDetails(
            distanceKm: double.parse((distanceMeters / 1000.0).toStringAsFixed(1)),
            durationMinutes: double.parse((durationSeconds / 60.0).toStringAsFixed(0)),
            polyline: polyline,
          );
        }
      }
    } catch (e) {
      debugPrint('OSRM route calculation error: $e');
    }
    return null;
  }
}
