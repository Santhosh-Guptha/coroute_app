import '../../domain/tracking/geo_math.dart';

/// The planned driving route through start, stops and destination, computed
/// by the gateway (free OSRM, or straight lines marked [approximate] when the
/// routing service is unavailable).
class RouteModel {
  final double distanceM;
  final int durationS;
  final String polyline;
  final List<RouteLeg> legs;
  final bool approximate;
  final int computedAt;

  RouteModel({
    required this.distanceM,
    required this.durationS,
    required this.polyline,
    this.legs = const [],
    this.approximate = false,
    this.computedAt = 0,
  });

  List<(double, double)>? _points;

  /// Decoded route line (lat, lng), decoded once.
  List<(double, double)> get points => _points ??= (GeoMath.decodePolyline(polyline) ?? const []);

  factory RouteModel.fromJson(Map<String, dynamic> j) => RouteModel(
        distanceM: (j['distanceM'] as num?)?.toDouble() ?? 0,
        durationS: (j['durationS'] as num?)?.toInt() ?? 0,
        polyline: j['polyline']?.toString() ?? '',
        legs: (j['legs'] as List? ?? const [])
            .whereType<Map>()
            .map((l) => RouteLeg((l['distanceM'] as num?)?.toDouble() ?? 0, (l['durationS'] as num?)?.toInt() ?? 0))
            .toList(),
        approximate: j['approximate'] == true,
        computedAt: (j['computedAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'distanceM': distanceM,
        'durationS': durationS,
        'polyline': polyline,
        'legs': legs.map((l) => {'distanceM': l.distanceM, 'durationS': l.durationS}).toList(),
        'approximate': approximate,
        'computedAt': computedAt,
      };
}

class RouteLeg {
  final double distanceM;
  final int durationS;
  const RouteLeg(this.distanceM, this.durationS);
}
