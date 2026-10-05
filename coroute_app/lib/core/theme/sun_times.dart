import 'dart:math' as math;

/// Sunrise and sunset for a place and day, computed on the phone with the
/// standard sunrise equation (accurate to a minute or two, no network, no GPS).
class SunTimes {
  SunTimes._();

  static double _rad(double d) => d * math.pi / 180;
  static double _deg(double r) => r * 180 / math.pi;

  /// Sunrise and sunset (UTC) for the calendar day of [day] at [lat], [lng].
  /// Returns null where the sun does not rise or set that day (polar regions).
  static ({DateTime sunrise, DateTime sunset})? forDay(DateTime day, double lat, double lng) {
    // Julian date of local noon on that day.
    final noonUtc = DateTime.utc(day.year, day.month, day.day, 12).subtract(Duration(minutes: (lng / 15 * 60).round()));
    final jd = noonUtc.millisecondsSinceEpoch / 86400000.0 + 2440587.5;
    final n = (jd - 2451545.0 + 0.0008).roundToDouble();
    final jStar = n - lng / 360;
    final m = (357.5291 + 0.98560028 * jStar) % 360;
    final mr = _rad(m);
    final c = 1.9148 * math.sin(mr) + 0.02 * math.sin(2 * mr) + 0.0003 * math.sin(3 * mr);
    final lambda = (m + c + 180 + 102.9372) % 360;
    final lr = _rad(lambda);
    final transit = 2451545.0 + jStar + 0.0053 * math.sin(mr) - 0.0069 * math.sin(2 * lr);
    final sinDec = math.sin(lr) * math.sin(_rad(23.4397));
    final cosDec = math.cos(math.asin(sinDec));
    final cosW = (math.sin(_rad(-0.833)) - math.sin(_rad(lat)) * sinDec) / (math.cos(_rad(lat)) * cosDec);
    if (cosW < -1 || cosW > 1) return null;
    final w = _deg(math.acos(cosW));
    DateTime fromJd(double j) => DateTime.fromMillisecondsSinceEpoch(((j - 2440587.5) * 86400000).round(), isUtc: true);
    return (sunrise: fromJd(transit - w / 360), sunset: fromJd(transit + w / 360));
  }

  /// Whether it is daytime at [now], and when that next changes.
  static ({bool day, DateTime nextChange}) state(DateTime now, double lat, double lng) {
    final local = now.toLocal();
    final today = forDay(local, lat, lng);
    if (today == null) {
      // Polar day or night: decide by season (northern summer = day in the north).
      final summer = local.month >= 4 && local.month <= 9;
      return (day: lat >= 0 ? summer : !summer, nextChange: now.add(const Duration(hours: 6)));
    }
    final u = now.toUtc();
    if (u.isBefore(today.sunrise)) return (day: false, nextChange: today.sunrise);
    if (u.isBefore(today.sunset)) return (day: true, nextChange: today.sunset);
    final tomorrow = forDay(local.add(const Duration(days: 1)), lat, lng);
    return (day: false, nextChange: tomorrow?.sunrise ?? now.add(const Duration(hours: 6)));
  }
}
