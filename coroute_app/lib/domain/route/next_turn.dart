/// The next turn on the line I follow, for the Ride AOD, the locked cockpit and the Android 16 Live Update
/// (pure; test/next_turn_test.dart).
///
/// The route has no maneuver list, only road steps (name / ref with start and end along the line). The next
/// turn is where the next step starts; its direction comes from the line's own bearing [lookM] metres before
/// and after that point.
library;

import '../../data/models/route_model.dart';
import '../notify/status_text.dart';
import '../tracking/geo_math.dart';
import 'route_progress.dart';

enum TurnDirection { straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn }

class NextTurn {
  const NextTurn({required this.direction, required this.distanceM, required this.road});

  final TurnDirection direction;

  /// Metres from me to the turn along the line.
  final double distanceM;

  /// The road after the turn ('' when unnamed).
  final String road;

  /// "400 m", "1.2 km" (rounded like the notification).
  String get distanceText => StatusText.roundedDistance(distanceM);

  /// "Turn right", "Keep left", "Continue", "Make a U-turn".
  String get instruction => switch (direction) {
        TurnDirection.straight => 'Continue',
        TurnDirection.slightLeft => 'Keep left',
        TurnDirection.slightRight => 'Keep right',
        TurnDirection.left => 'Turn left',
        TurnDirection.right => 'Turn right',
        TurnDirection.sharpLeft => 'Sharp left',
        TurnDirection.sharpRight => 'Sharp right',
        TurnDirection.uTurn => 'Make a U-turn',
      };

  /// "Turn right in 400 m"
  String get line => '$instruction in $distanceText';

  /// Signed angle (degrees, -180..180, right positive) to a direction.
  static TurnDirection classify(double delta) {
    final a = delta.abs();
    if (a < 20) return TurnDirection.straight;
    final right = delta > 0;
    if (a < 45) return right ? TurnDirection.slightRight : TurnDirection.slightLeft;
    if (a < 135) return right ? TurnDirection.right : TurnDirection.left;
    if (a < 165) return right ? TurnDirection.sharpRight : TurnDirection.sharpLeft;
    return TurnDirection.uTurn;
  }

  /// Signed difference b2 - b1 in degrees, -180..180 (right positive).
  static double signedDelta(double b1, double b2) => ((b2 - b1 + 540.0) % 360.0) - 180.0;

  /// The next step start ahead of [alongM] on [line], or null (no steps, no line, past the last step).
  /// Steps closer than [minAheadM] are treated as passed.
  static NextTurn? compute({
    required List<RouteStep> steps,
    required RouteProgress line,
    required double alongM,
    double lookM = 25,
    double minAheadM = 5,
  }) {
    if (steps.isEmpty || !line.isUsable) return null;
    final length = line.lengthM;
    for (final s in steps) {
      if (s.startM <= alongM + minAheadM || s.startM <= 0) continue;
      if (s.startM >= length) return null;
      final before = _pointAt(line, s.startM - lookM);
      final at = _pointAt(line, s.startM);
      final after = _pointAt(line, s.startM + lookM);
      final b1 = GeoMath.bearing(before.$1, before.$2, at.$1, at.$2);
      final b2 = GeoMath.bearing(at.$1, at.$2, after.$1, after.$2);
      return NextTurn(direction: classify(signedDelta(b1, b2)), distanceM: s.startM - alongM, road: s.roadLabel);
    }
    return null;
  }

  /// Round 11 HUD (marked edit): the next [count] step starts ahead of [alongM], nearest first, for
  /// the turn card's "then ..." line. Same rules as [compute].
  static List<NextTurn> computeAhead({
    required List<RouteStep> steps,
    required RouteProgress line,
    required double alongM,
    int count = 2,
    double lookM = 25,
    double minAheadM = 5,
  }) {
    final out = <NextTurn>[];
    if (steps.isEmpty || !line.isUsable || count <= 0) return out;
    final length = line.lengthM;
    for (final s in steps) {
      if (s.startM <= alongM + minAheadM || s.startM <= 0) continue;
      if (s.startM >= length) break;
      final before = _pointAt(line, s.startM - lookM);
      final at = _pointAt(line, s.startM);
      final after = _pointAt(line, s.startM + lookM);
      final b1 = GeoMath.bearing(before.$1, before.$2, at.$1, at.$2);
      final b2 = GeoMath.bearing(at.$1, at.$2, after.$1, after.$2);
      out.add(NextTurn(direction: classify(signedDelta(b1, b2)), distanceM: s.startM - alongM, road: s.roadLabel));
      if (out.length >= count) break;
    }
    return out;
  }

  /// The point [d] metres along the line (clamped to its ends).
  static (double, double) _pointAt(RouteProgress line, double d) {
    final pts = line.points;
    if (d <= 0) return pts.first;
    if (d >= line.lengthM) return pts.last;
    var lo = 0, hi = pts.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (line.alongAtVertex(mid) <= d) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = line.alongAtVertex(lo), b = line.alongAtVertex(hi);
    final t = b - a <= 0 ? 0.0 : (d - a) / (b - a);
    final p = pts[lo], q = pts[hi];
    return (p.$1 + (q.$1 - p.$1) * t, p.$2 + (q.$2 - p.$2) * t);
  }
}
