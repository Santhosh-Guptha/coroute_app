import 'dart:math' as math;
import '../timeline/timeline_text.dart';

/// Direction from one point to another, in words riders use
/// ("1.8 km north-east of you"). Pure, no state.
class Bearing {
  Bearing._();

  /// Initial great-circle bearing from point 1 to point 2, 0 to 360 degrees (0 = north, 90 = east).
  static double degrees(double lat1, double lng1, double lat2, double lng2) {
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dl = (lng2 - lng1) * math.pi / 180;
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    final deg = math.atan2(y, x) * 180 / math.pi;
    return (deg + 360) % 360;
  }

  static const List<String> _words = ['north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west'];

  /// Eight-point compass word for [deg] ("north", "north-east", ...).
  static String compassWord(double deg) {
    if (!deg.isFinite) return 'north';
    final d = ((deg % 360) + 360) % 360;
    return _words[((d + 22.5) ~/ 45) % 8];
  }

  /// "1.8 km north-east of you", "450 m south of you".
  static String fromMe(num metres, double deg) => '${TimelineText.distance(metres)} ${compassWord(deg)} of you';
}
