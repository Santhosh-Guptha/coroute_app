import 'stop_point_model.dart';

/// A named point on the plan (start or destination).
class PlanPlace {
  final double lat;
  final double lng;
  final String name;
  const PlanPlace({required this.lat, required this.lng, this.name = ''});

  static PlanPlace? fromJson(dynamic j) {
    if (j is! Map) return null;
    final lat = j['lat'], lng = j['lng'];
    if (lat is! num || lng is! num || (lat == 0 && lng == 0)) return null;
    return PlanPlace(lat: lat.toDouble(), lng: lng.toDouble(), name: j['name']?.toString() ?? '');
  }
}

/// A planned stop as it ended up: where, and who reached it when.
class PlanStop {
  final String stopId;
  final String name;
  final double lat;
  final double lng;
  final String category;
  final String status; // PLANNED or SKIPPED
  final bool isVisited;
  final int orderIndex;
  final Map<String, StopArrival> arrivals;

  const PlanStop({
    required this.stopId,
    required this.name,
    required this.lat,
    required this.lng,
    this.category = 'OTHER',
    this.status = 'PLANNED',
    this.isVisited = false,
    this.orderIndex = 0,
    this.arrivals = const {},
  });

  bool get isSkipped => status == 'SKIPPED';
}

/// The trip as planned (start, stops, destination) plus who reached what,
/// sent with the report and the replay so the maps can show it.
class TripPlan {
  final PlanPlace? start;
  final PlanPlace? destination;
  final Map<String, StopArrival> destinationArrivals;
  final List<PlanStop> stops;

  const TripPlan({this.start, this.destination, this.destinationArrivals = const {}, this.stops = const []});

  static TripPlan? fromJson(dynamic j) {
    if (j is! Map) return null;
    final stops = <PlanStop>[];
    for (final s in (j['stops'] as List? ?? const []).whereType<Map>()) {
      final lat = s['lat'], lng = s['lng'];
      if (lat is! num || lng is! num) continue;
      stops.add(PlanStop(
        stopId: s['stopId']?.toString() ?? '',
        name: s['name']?.toString() ?? '',
        lat: lat.toDouble(),
        lng: lng.toDouble(),
        category: s['category']?.toString() ?? 'OTHER',
        status: s['status']?.toString() ?? 'PLANNED',
        isVisited: s['isVisited'] == true,
        orderIndex: (s['orderIndex'] as num?)?.toInt() ?? 0,
        arrivals: StopArrival.mapFrom(s['arrivals']),
      ));
    }
    stops.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return TripPlan(
      start: PlanPlace.fromJson(j['start']),
      destination: PlanPlace.fromJson(j['destination']),
      destinationArrivals: StopArrival.mapFrom(j['destinationArrivals']),
      stops: stops,
    );
  }
}
