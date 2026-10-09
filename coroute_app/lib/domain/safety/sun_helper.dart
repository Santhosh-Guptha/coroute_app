import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/sun_times.dart';

/// Day or night questions for the ride, from [SunTimes] (computed on the phone,
/// no network). Used for the "after dark" review line, the "Dark in 40 min"
/// ride line and the night voice rule.
class DarkCheck {
  DarkCheck._();

  /// The calendar day at the place (by its longitude), whatever the phone's time zone.
  static DateTime _dayAt(DateTime t, double lng) => t.toUtc().add(Duration(minutes: (lng * 4).round()));

  /// Today's sunset (local time) for the day of [localNow] at the place; null where the sun does not set.
  static DateTime? sunsetFor(DateTime localNow, double lat, double lng) {
    final t = SunTimes.forDay(_dayAt(localNow, lng), lat, lng);
    return t?.sunset.toLocal();
  }

  /// Today's sunrise (local time); null in polar cases.
  static DateTime? sunriseFor(DateTime localNow, double lat, double lng) {
    final t = SunTimes.forDay(_dayAt(localNow, lng), lat, lng);
    return t?.sunrise.toLocal();
  }

  /// Night at the place (before its sunrise or after its sunset, by the place's own day,
  /// so a phone set to another time zone gets the same answer). Polar cases fall back to
  /// [SunTimes.state].
  static bool isDark(DateTime now, double lat, double lng) {
    final t = SunTimes.forDay(_dayAt(now, lng), lat, lng);
    if (t == null) return !SunTimes.state(now, lat, lng).day;
    final u = now.toUtc();
    return u.isBefore(t.sunrise) || !u.isBefore(t.sunset);
  }

  /// Time left until sunset; null when it is already dark or the sun does not set.
  static Duration? untilDark(DateTime now, double lat, double lng) {
    if (isDark(now, lat, lng)) return null;
    final t = SunTimes.forDay(_dayAt(now, lng), lat, lng);
    if (t == null) return null;
    final left = t.sunset.difference(now.toUtc());
    return left.isNegative ? null : left;
  }

  /// Review sheet: "You will reach the destination after dark (sunset 6:10 PM)." when
  /// [departure] + [eta] passes the sunset of the departure day; "It is dark now." when
  /// the ride would start in the dark; null by day.
  static String? reviewLine({
    required DateTime departure,
    required Duration eta,
    required double lat,
    required double lng,
    required String Function(DateTime) fmtTime,
  }) {
    if (lat == 0 && lng == 0) return null;
    final day = SunTimes.forDay(_dayAt(departure, lng), lat, lng);
    if (day == null) return null;
    final dep = departure.toUtc();
    if (dep.isBefore(day.sunrise) || !dep.isBefore(day.sunset)) {
      final next = dep.isBefore(day.sunrise) ? day.sunrise : (SunTimes.forDay(_dayAt(departure, lng).add(const Duration(days: 1)), lat, lng)?.sunrise ?? day.sunrise);
      return L10n.t('dark.now', {'time': fmtTime(next.toLocal())});
    }
    if (dep.add(eta).isAfter(day.sunset)) {
      return L10n.t('dark.review', {'time': fmtTime(day.sunset.toLocal())});
    }
    return null;
  }

  /// Ride sheet: "Dark in 40 min" while sunset is within [SafetyConstants.darkWarnBefore]; else null.
  static String? rideLine({required DateTime now, required double lat, required double lng}) {
    if (lat == 0 && lng == 0) return null;
    final left = untilDark(now, lat, lng);
    if (left == null || left > SafetyConstants.darkWarnBefore) return null;
    final min = (left.inSeconds / 60).ceil();
    return L10n.t('dark.ride', {'min': min < 1 ? 1 : min});
  }
}
