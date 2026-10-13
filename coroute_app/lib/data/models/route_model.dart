import '../../domain/tracking/geo_math.dart';

/// The planned driving route through start, stops and destination, computed
/// by the gateway (free OSRM, or straight lines marked [approximate] when the
/// routing service is unavailable).
class RouteModel {
  final double distanceM;
  final int durationS;
  final String polyline;
  final List<RouteLeg> legs;
  final List<RouteStep> steps;
  final bool approximate;
  final int computedAt;

  RouteModel({
    required this.distanceM,
    required this.durationS,
    required this.polyline,
    this.legs = const [],
    this.steps = const [],
    this.approximate = false,
    this.computedAt = 0,
  });

  List<(double, double)>? _points;

  /// Decoded route line (lat, lng), decoded once.
  List<(double, double)> get points => _points ??= (GeoMath.decodePolyline(polyline) ?? const []);

  factory RouteModel.fromJson(Map<String, dynamic> j) {
    final rawSteps = (j['steps'] as List? ?? const []).whereType<Map>().toList();
    var cumM = 0.0;
    final parsedSteps = <RouteStep>[];
    for (final s in rawSteps) {
      final d = (s['distanceM'] as num?)?.toDouble() ?? 0.0;
      final start = (s['startM'] as num?)?.toDouble() ?? cumM;
      final end = (s['endM'] as num?)?.toDouble() ?? (start + d);
      cumM = end;
      parsedSteps.add(RouteStep(
        name: s['name']?.toString() ?? '',
        ref: s['ref']?.toString() ?? '',
        distanceM: d,
        durationS: (s['durationS'] as num?)?.toInt() ?? 0,
        startM: start,
        endM: end,
      ));
    }

    return RouteModel(
      distanceM: (j['distanceM'] as num?)?.toDouble() ?? 0,
      durationS: (j['durationS'] as num?)?.toInt() ?? 0,
      polyline: j['polyline']?.toString() ?? '',
      legs: (j['legs'] as List? ?? const [])
          .whereType<Map>()
          .map((l) => RouteLeg((l['distanceM'] as num?)?.toDouble() ?? 0, (l['durationS'] as num?)?.toInt() ?? 0))
          .toList(),
      steps: parsedSteps,
      approximate: j['approximate'] == true,
      computedAt: (j['computedAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// Finds the active turn step at [alongM] metres from the start of the route.
  RouteStep? stepAt(double alongM) {
    if (steps.isEmpty || alongM < 0) return null;
    for (final s in steps) {
      if (alongM >= s.startM && alongM <= s.endM) {
        return s;
      }
    }
    if (alongM >= steps.last.endM) return steps.last;
    return steps.first;
  }

  /// Current road or highway name at [alongM] metres, or null if unnamed.
  String? roadNameAt(double alongM) {
    if (steps.isEmpty) return null;
    final s = stepAt(alongM);
    if (s != null && s.roadLabel.isNotEmpty) {
      return s.roadLabel;
    }
    for (final step in steps) {
      if ((alongM - step.endM).abs() <= 500 || (alongM - step.startM).abs() <= 500) {
        if (step.roadLabel.isNotEmpty) return step.roadLabel;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'distanceM': distanceM,
        'durationS': durationS,
        'polyline': polyline,
        'legs': legs.map((l) => {'distanceM': l.distanceM, 'durationS': l.durationS}).toList(),
        'steps': steps.map((s) => s.toJson()).toList(),
        'approximate': approximate,
        'computedAt': computedAt,
      };
}

class RouteLeg {
  final double distanceM;
  final int durationS;
  const RouteLeg(this.distanceM, this.durationS);
}

/// A turn step / road corridor segment along the route.
class RouteStep {
  final String name;
  final String ref;
  final double distanceM;
  final int durationS;
  final double startM;
  final double endM;

  const RouteStep({
    required this.name,
    this.ref = '',
    required this.distanceM,
    this.durationS = 0,
    required this.startM,
    required this.endM,
  });

  /// The clean, concise road or highway label to display on the cockpit pill.
  /// E.g. "NH 44", "Outer Ring Rd", "NH 44 · Hosur Rd"
  String get roadLabel {
    final cleanRef = ref.trim();
    final cleanName = name.trim();
    if (cleanRef.isNotEmpty && cleanName.isNotEmpty) {
      final refNum = RegExp(r'\d+').firstMatch(cleanRef)?.group(0);
      final isNationalHwy = cleanRef.toUpperCase().startsWith('NH') &&
          cleanName.toLowerCase().contains('national highway') &&
          (refNum == null || cleanName.contains(refNum));
      if (cleanName.toLowerCase().contains(cleanRef.toLowerCase()) || isNationalHwy) {
        return cleanName;
      }
      return '$cleanRef · $cleanName';
    }
    if (cleanRef.isNotEmpty) return cleanRef;
    return cleanName;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'ref': ref,
        'distanceM': distanceM,
        'durationS': durationS,
        'startM': startM,
        'endM': endM,
      };
}
