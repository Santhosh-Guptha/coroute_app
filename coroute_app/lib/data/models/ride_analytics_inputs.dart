import '../../domain/analytics/ride_analytics.dart';
import 'trip_history_model.dart';

/// Turns saved trips into [RideEntry]s for the analytics. Pure.
///
/// The phone's own numbers come first: a trip carries `clientStats` (TripStats
/// computed from this phone's recorded track) when it was recorded here. Only a
/// trip without them (recorded on another phone, or before the phone kept them)
/// falls back to the account history's numbers from the server.
class RideAnalyticsInputs {
  RideAnalyticsInputs._();

  static RideEntry entryOf(TripHistoryModel t) {
    final cs = t.clientStats;
    final phone = cs != null && (cs['points'] ?? 0) >= 2 && (cs['distanceM'] ?? -1) >= 0;
    double num0(String k) => (cs?[k] ?? 0).toDouble();
    final km = phone ? num0('distanceM') / 1000 : t.totalDistanceKm;
    final moving = phone ? num0('movingMs').toInt() : t.movingMs;
    final top = phone ? num0('maxKmh') : t.topSpeedKmh;
    return RideEntry(
      id: t.tripId,
      name: t.tripName,
      groupId: t.groupId,
      startMs: t.startTimeEpochMs > 0 ? t.startTimeEpochMs : t.endTimeEpochMs,
      endMs: t.endTimeEpochMs,
      km: km.isFinite && km >= 0 ? km : 0,
      movingMs: moving > 0 ? moving : 0,
      topKmh: top.isFinite && top > 0 ? top : 0,
      riders: t.riderCount < 1 ? 1 : t.riderCount,
      fromPhone: phone,
    );
  }

  /// One entry per trip id (the list is already merged; this guards against repeats).
  static List<RideEntry> entriesOf(Iterable<TripHistoryModel> trips) {
    final seen = <String>{};
    return [
      for (final t in trips)
        if (t.tripId.isEmpty || seen.add(t.tripId)) entryOf(t),
    ];
  }

  /// The km of one trip as the analytics count it (used by the review prompt).
  static double kmOf(TripHistoryModel t) => entryOf(t).km;
}
