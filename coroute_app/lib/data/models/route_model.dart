import 'package:flutter/foundation.dart';
import '../../domain/tracking/geo_math.dart';

/// Precalculated rectangular geographic bounding box for O(1) camera framing.
class RouteBounds {
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;

  const RouteBounds({
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });

  Map<String, dynamic> toJson() => {
        'minLat': minLat,
        'maxLat': maxLat,
        'minLng': minLng,
        'maxLng': maxLng,
      };

  factory RouteBounds.fromJson(Map<String, dynamic> j) => RouteBounds(
        minLat: (j['minLat'] as num).toDouble(),
        maxLat: (j['maxLat'] as num).toDouble(),
        minLng: (j['minLng'] as num).toDouble(),
        maxLng: (j['maxLng'] as num).toDouble(),
      );
}

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
  final RouteBounds? bounds;

  RouteModel({
    required this.distanceM,
    required this.durationS,
    required this.polyline,
    this.legs = const [],
    this.steps = const [],
    this.approximate = false,
    this.computedAt = 0,
    List<(double, double)>? precomputedPoints,
    List<(double, double)>? precomputedDisplayPoints,
    this.bounds,
  })  : _points = precomputedPoints,
        _displayPoints = precomputedDisplayPoints;

  List<(double, double)>? _points;
  List<(double, double)>? _displayPoints;

  /// Full-resolution decoded route line (lat, lng), decoded once.
  /// Retains 100% precision for turn-by-turn navigation, waypoint proximity,
  /// and dead reckoning.
  List<(double, double)> get points => _points ??= (GeoMath.decodePolyline(polyline) ?? const []);

  /// Simplified route line for overview map rendering (PolylineLayer) to prevent
  /// GPU Canvas overdraw and frame drops on long-distance trips.
  List<(double, double)> get displayPoints {
    if (_displayPoints != null) return _displayPoints!;
    final pts = points;
    if (pts.length <= 300) {
      _displayPoints = pts;
    } else {
      _displayPoints = GeoMath.simplify(pts, toleranceM: 15.0);
    }
    return _displayPoints!;
  }

  /// Geographic bounds computed on demand if not already precalculated.
  RouteBounds? get calculatedBounds {
    if (bounds != null) return bounds;
    final pts = points;
    if (pts.isEmpty) return null;
    var minLa = pts[0].$1, maxLa = pts[0].$1;
    var minLn = pts[0].$2, maxLn = pts[0].$2;
    for (var i = 1; i < pts.length; i++) {
      final p = pts[i];
      if (p.$1 < minLa) minLa = p.$1;
      if (p.$1 > maxLa) maxLa = p.$1;
      if (p.$2 < minLn) minLn = p.$2;
      if (p.$2 > maxLn) maxLn = p.$2;
    }
    return RouteBounds(minLat: minLa, maxLat: maxLa, minLng: minLn, maxLng: maxLn);
  }

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

    final rawBounds = j['bounds'];
    final parsedBounds = rawBounds is Map<String, dynamic> ? RouteBounds.fromJson(rawBounds) : null;

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
      bounds: parsedBounds,
    );
  }

  /// Parses JSON, decodes polyline, precomputes bounds and Douglas-Peucker simplified
  /// display points inside a background isolate to keep the UI thread completely unblocked.
  static Future<RouteModel> fromJsonAsync(Map<String, dynamic> j) async {
    return compute(_parseRouteInIsolate, j);
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
        if (bounds != null) 'bounds': bounds!.toJson(),
      };
}

/// Background isolate worker for decoding large polylines and precomputing
/// simplified display geometry without blocking UI frames.
RouteModel _parseRouteInIsolate(Map<String, dynamic> j) {
  final base = RouteModel.fromJson(j);
  final pts = GeoMath.decodePolyline(base.polyline) ?? const <(double, double)>[];
  List<(double, double)> displayPts;
  if (pts.length <= 300) {
    displayPts = pts;
  } else {
    displayPts = GeoMath.simplify(pts, toleranceM: 15.0);
  }

  RouteBounds? b = base.bounds;
  if (b == null && pts.isNotEmpty) {
    var minLa = pts[0].$1, maxLa = pts[0].$1;
    var minLn = pts[0].$2, maxLn = pts[0].$2;
    for (var i = 1; i < pts.length; i++) {
      final p = pts[i];
      if (p.$1 < minLa) minLa = p.$1;
      if (p.$1 > maxLa) maxLa = p.$1;
      if (p.$2 < minLn) minLn = p.$2;
      if (p.$2 > maxLn) maxLn = p.$2;
    }
    b = RouteBounds(minLat: minLa, maxLat: maxLa, minLng: minLn, maxLng: maxLn);
  }

  return RouteModel(
    distanceM: base.distanceM,
    durationS: base.durationS,
    polyline: base.polyline,
    legs: base.legs,
    steps: base.steps,
    approximate: base.approximate,
    computedAt: base.computedAt,
    precomputedPoints: pts,
    precomputedDisplayPoints: displayPts,
    bounds: b,
  );
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
