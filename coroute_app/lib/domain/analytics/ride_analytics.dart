/// "Your ride analytics": every number is computed on the phone from the
/// rider's own trip history (no server work, works offline). Pure Dart, so it
/// can run in a background isolate and is unit tested without Flutter.
library;

/// One finished ride, reduced to what the analytics need (no trail).
class RideEntry {
  final String id;
  final String name;
  final String groupId;

  /// When the ride started (epoch ms, UTC). Decides its day, week and month.
  final int startMs;
  final int endMs;
  final double km;

  /// Time in motion (0 when unknown: the whole duration counts as riding).
  final int movingMs;
  final double topKmh;
  final int riders;

  /// True when the numbers came from this phone's own recorded track
  /// (TripStats / `clientStats`); false when only the account history had them.
  final bool fromPhone;

  const RideEntry({
    required this.id,
    this.name = '',
    this.groupId = '',
    required this.startMs,
    required this.endMs,
    required this.km,
    this.movingMs = 0,
    this.topKmh = 0,
    this.riders = 1,
    this.fromPhone = false,
  });

  int get durationMs => endMs > startMs ? endMs - startMs : 0;
  int get ridingMs => movingMs > 0 ? movingMs : durationMs;
  bool get isGroup => riders > 1;
}

/// The phone's own safety counts for one ride (RideStatsStore, never uploaded).
class RideSafetyEntry {
  final String groupId;
  final int endedAt;
  final int breaks;
  final int alerts;
  final bool sos;
  final bool crashCheck;

  const RideSafetyEntry({required this.groupId, this.endedAt = 0, this.breaks = 0, this.alerts = 0, this.sos = false, this.crashCheck = false});
}

/// What the fuel numbers need: the bike's mileage (km per [unit]) and, when
/// the rider entered one, the price per [unit]. Both stay on the phone.
class FuelInputs {
  final double kmPerUnit;
  final String unit;
  final double? pricePerUnit;
  const FuelInputs({required this.kmPerUnit, this.unit = 'L', this.pricePerUnit});
}

class PeriodTotals {
  final int rides;
  final double km;
  final int ridingMs;
  const PeriodTotals({this.rides = 0, this.km = 0, this.ridingMs = 0});
  static const PeriodTotals zero = PeriodTotals();
}

/// One bar of the weekly chart: the week starting Monday [year]-[month]-[day] (local).
class WeekBar {
  final int year;
  final int month;
  final int day;
  final double km;
  final int rides;
  const WeekBar({required this.year, required this.month, required this.day, this.km = 0, this.rides = 0});
}

class SafetySummary {
  /// Rides this phone kept safety counts for (the last 90 days).
  final int rides;
  final int breaks;
  final int alerts;
  final int sosRides;
  final int crashChecks;
  const SafetySummary({this.rides = 0, this.breaks = 0, this.alerts = 0, this.sosRides = 0, this.crashChecks = 0});
}

class FuelSummary {
  final String unit;
  final double usedTotal;
  final double usedThisMonth;

  /// Null when no price was entered.
  final double? costTotal;
  final double? costThisMonth;
  const FuelSummary({required this.unit, required this.usedTotal, required this.usedThisMonth, this.costTotal, this.costThisMonth});
}

class RideAnalytics {
  final int rides;
  final double totalKm;
  final int ridingMs;
  final double longestKm;
  final String longestName;
  final double topSpeedKmh;
  final double avgMovingKmh;
  final PeriodTotals thisMonth;
  final PeriodTotals lastMonth;

  /// The last 12 weeks, oldest first; the last bar is the current week.
  final List<WeekBar> weeks;
  final SafetySummary safety;
  final FuelSummary? fuel;
  final int groupRides;
  final int soloRides;
  final double groupKm;
  final double soloKm;

  /// Weekends in a row with a ride (this one counts once ridden; an unridden one
  /// that is not over yet does not break it).
  final int weekendStreak;
  final int weekStreak;
  final int bestWeekendStreak;

  /// How many rides used the phone's own numbers, and how many only the account's.
  final int fromPhone;
  final int fromAccount;

  const RideAnalytics({
    this.rides = 0,
    this.totalKm = 0,
    this.ridingMs = 0,
    this.longestKm = 0,
    this.longestName = '',
    this.topSpeedKmh = 0,
    this.avgMovingKmh = 0,
    this.thisMonth = PeriodTotals.zero,
    this.lastMonth = PeriodTotals.zero,
    this.weeks = const [],
    this.safety = const SafetySummary(),
    this.fuel,
    this.groupRides = 0,
    this.soloRides = 0,
    this.groupKm = 0,
    this.soloKm = 0,
    this.weekendStreak = 0,
    this.weekStreak = 0,
    this.bestWeekendStreak = 0,
    this.fromPhone = 0,
    this.fromAccount = 0,
  });

  bool get isEmpty => rides == 0;

  /// "3 weekends in a row" / "4 weeks in a row", or null below two.
  String? get streakText {
    if (weekendStreak >= 2) return '$weekendStreak weekends in a row';
    if (weekStreak >= 2) return '$weekStreak weeks in a row';
    return null;
  }
}

/// Everything [RideAnalyticsCalculator.compute] reads. Sendable to an isolate.
class RideAnalyticsInput {
  final List<RideEntry> rides;
  final List<RideSafetyEntry> safety;
  final FuelInputs? fuel;
  final int nowMs;

  /// Fixed offset from UTC in minutes (tests, or a chosen zone). Null: the
  /// phone's own zone at each moment (summer time included).
  final int? utcOffsetMinutes;

  const RideAnalyticsInput({required this.rides, this.safety = const [], this.fuel, required this.nowMs, this.utcOffsetMinutes});
}

class RideAnalyticsCalculator {
  RideAnalyticsCalculator._();

  static const int weeksShown = 12;
  static const int _dayMs = 86400000;

  /// Speeds above this are GPS errors (same limit as TrackRules.maxKmh).
  static const double maxPlausibleKmh = 250;

  static RideAnalytics compute(RideAnalyticsInput input) {
    final offsetMinutes = input.utcOffsetMinutes;
    int offsetMs(int ms) => offsetMinutes != null ? offsetMinutes * 60000 : DateTime.fromMillisecondsSinceEpoch(ms).timeZoneOffset.inMilliseconds;
    // Local calendar day number (days since 1970-01-01 in the rider's zone).
    int dayOf(int ms) => _floorDiv(ms + offsetMs(ms), _dayMs);
    // Monday of that day's week (1970-01-01 was a Thursday).
    int weekOf(int day) => day - _mod(day + 3, 7);
    bool weekend(int day) => _mod(day + 3, 7) >= 5;
    (int, int) monthOf(int day) {
      final d = DateTime.fromMillisecondsSinceEpoch(day * _dayMs, isUtc: true);
      return (d.year, d.month);
    }

    final rides = <RideEntry>[
      for (final r in input.rides)
        if (r.startMs > 0 && r.km.isFinite && r.km >= 0) r,
    ];
    final today = dayOf(input.nowMs);
    final thisWeek = weekOf(today);
    final (ty, tm) = monthOf(today);
    final (ly, lm) = tm == 1 ? (ty - 1, 12) : (ty, tm - 1);

    var totalKm = 0.0, longestKm = 0.0, top = 0.0, movingKm = 0.0;
    var longestName = '';
    var riding = 0, moving = 0, fromPhone = 0;
    var groupRides = 0, groupKm = 0.0, soloKm = 0.0;
    var tmRides = 0, tmKm = 0.0, tmMs = 0, lmRides = 0, lmKm = 0.0, lmMs = 0;
    final weekKm = List<double>.filled(weeksShown, 0);
    final weekRides = List<int>.filled(weeksShown, 0);
    final rideWeeks = <int>{};
    final weekendWeeks = <int>{};

    for (final r in rides) {
      totalKm += r.km;
      riding += r.ridingMs;
      if (r.movingMs > 0) {
        moving += r.movingMs;
        movingKm += r.km;
      }
      if (r.km > longestKm) {
        longestKm = r.km;
        longestName = r.name;
      }
      if (r.topKmh.isFinite && r.topKmh <= maxPlausibleKmh && r.topKmh > top) top = r.topKmh;
      if (r.fromPhone) fromPhone++;
      if (r.isGroup) {
        groupRides++;
        groupKm += r.km;
      } else {
        soloKm += r.km;
      }
      final day = dayOf(r.startMs);
      final (y, m) = monthOf(day);
      if (y == ty && m == tm) {
        tmRides++;
        tmKm += r.km;
        tmMs += r.ridingMs;
      } else if (y == ly && m == lm) {
        lmRides++;
        lmKm += r.km;
        lmMs += r.ridingMs;
      }
      final week = weekOf(day);
      rideWeeks.add(week);
      if (weekend(day)) weekendWeeks.add(week);
      final idx = weeksShown - 1 - (thisWeek - week) ~/ 7;
      if (idx >= 0 && idx < weeksShown) {
        weekKm[idx] += r.km;
        weekRides[idx]++;
      }
    }

    final weeks = <WeekBar>[
      for (var i = 0; i < weeksShown; i++)
        () {
          final start = thisWeek - (weeksShown - 1 - i) * 7;
          final d = DateTime.fromMillisecondsSinceEpoch(start * _dayMs, isUtc: true);
          return WeekBar(year: d.year, month: d.month, day: d.day, km: weekKm[i], rides: weekRides[i]);
        }(),
    ];

    // Streaks. The current weekend/week counts when ridden; when not (yet), it does not break the run.
    int runFrom(Set<int> set, int from) {
      var n = 0;
      for (var w = from; set.contains(w); w -= 7) {
        n++;
      }
      return n;
    }

    final weekendStreak = runFrom(weekendWeeks, weekendWeeks.contains(thisWeek) ? thisWeek : thisWeek - 7);
    final weekStreak = runFrom(rideWeeks, rideWeeks.contains(thisWeek) ? thisWeek : thisWeek - 7);
    var best = 0;
    for (final w in weekendWeeks) {
      if (weekendWeeks.contains(w - 7)) continue; // not the start of a run
      var n = 0;
      for (var x = w; weekendWeeks.contains(x); x += 7) {
        n++;
      }
      if (n > best) best = n;
    }

    var breaks = 0, alerts = 0, sos = 0, crash = 0;
    for (final s in input.safety) {
      breaks += s.breaks < 0 ? 0 : s.breaks;
      alerts += s.alerts < 0 ? 0 : s.alerts;
      if (s.sos) sos++;
      if (s.crashCheck) crash++;
    }

    FuelSummary? fuel;
    final f = input.fuel;
    if (f != null && f.kmPerUnit.isFinite && f.kmPerUnit > 0 && rides.isNotEmpty) {
      final used = totalKm / f.kmPerUnit;
      final usedMonth = tmKm / f.kmPerUnit;
      final price = f.pricePerUnit;
      final priced = price != null && price.isFinite && price > 0;
      fuel = FuelSummary(
        unit: f.unit,
        usedTotal: used,
        usedThisMonth: usedMonth,
        costTotal: priced ? used * price : null,
        costThisMonth: priced ? usedMonth * price : null,
      );
    }

    return RideAnalytics(
      rides: rides.length,
      totalKm: totalKm,
      ridingMs: riding,
      longestKm: longestKm,
      longestName: longestName,
      topSpeedKmh: top,
      avgMovingKmh: moving > 0 ? movingKm / (moving / 3600000) : 0,
      thisMonth: PeriodTotals(rides: tmRides, km: tmKm, ridingMs: tmMs),
      lastMonth: PeriodTotals(rides: lmRides, km: lmKm, ridingMs: lmMs),
      weeks: weeks,
      safety: SafetySummary(rides: input.safety.length, breaks: breaks, alerts: alerts, sosRides: sos, crashChecks: crash),
      fuel: fuel,
      groupRides: groupRides,
      soloRides: rides.length - groupRides,
      groupKm: groupKm,
      soloKm: soloKm,
      weekendStreak: weekendStreak,
      weekStreak: weekStreak,
      bestWeekendStreak: best,
      fromPhone: fromPhone,
      fromAccount: rides.length - fromPhone,
    );
  }

  static int _floorDiv(int a, int b) => (a / b).floor();
  static int _mod(int a, int b) => ((a % b) + b) % b;
}
