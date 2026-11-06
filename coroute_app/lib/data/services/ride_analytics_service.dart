import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/analytics/ride_analytics.dart';
import '../../domain/places/fuel_economy.dart';
import '../../domain/safety/fuel_profile.dart';
import '../local/ride_stats_store.dart';
import '../models/ride_analytics_inputs.dart';
import '../models/trip_history_model.dart';

/// Builds "Your ride analytics" on the phone: the saved trips, this phone's own
/// safety counts (RideStatsStore) and the bike's mileage. Nothing is sent
/// anywhere. A large history is computed in a background isolate; the last
/// result is kept in memory and reused while nothing changed.
class RideAnalyticsService {
  RideAnalyticsService._();

  /// Above this many trips the work moves off the UI thread.
  static const int isolateAbove = 150;

  /// The price per litre (kg, kWh) the rider entered for the cost estimate. Phone only.
  static const String keyFuelPrice = 'coroute_analytics_fuel_price_v1';

  static String? _cacheKey;
  static RideAnalytics? _cache;

  /// The cached result for exactly these inputs, or null.
  static RideAnalytics? cached(String key) => key == _cacheKey ? _cache : null;

  @visibleForTesting
  static void clearCache() {
    _cacheKey = null;
    _cache = null;
  }

  static List<RideSafetyEntry> safetyEntriesOf(Iterable<RideStats> stats) => [
        for (final s in stats)
          RideSafetyEntry(groupId: s.groupId, endedAt: s.endedAt, breaks: s.breaks, alerts: s.alerts, sos: s.sos, crashCheck: s.crashAlert),
      ];

  /// The bike's km per unit: learned from fill-ups when there are some, else the
  /// mileage the rider set. Null without either (no fuel numbers are shown then).
  static FuelInputs? fuelInputsOf({required FuelProfile profile, FuelLearning? learning, String unit = 'L', double? pricePerUnit}) {
    final rated = profile.mileageKmL.isFinite && profile.mileageKmL > 0 ? profile.mileageKmL : 0.0;
    final kmpu = learning == null ? rated : learning.effectiveKmPerUnit(rated);
    if (!kmpu.isFinite || kmpu <= 0) return null;
    return FuelInputs(kmPerUnit: kmpu, unit: unit, pricePerUnit: pricePerUnit);
  }

  static String keyOf({required int revision, required List<TripHistoryModel> trips, required List<RideStats> stats, FuelInputs? fuel, required int nowMs}) {
    var safetySig = 0;
    for (final s in stats) {
      safetySig = Object.hash(safetySig, s.groupId, s.endedAt, s.breaks, s.alerts, s.sos, s.crashAlert);
    }
    final first = trips.isEmpty ? '' : trips.first.tripId;
    final last = trips.isEmpty ? '' : trips.last.tripId;
    // The day is part of the key: "this month" and the weekly chart move with the calendar.
    final day = DateTime.fromMillisecondsSinceEpoch(nowMs);
    return '$revision|${trips.length}|$first|$last|$safetySig|${fuel?.kmPerUnit}|${fuel?.pricePerUnit}|${fuel?.unit}|${day.year}-${day.month}-${day.day}';
  }

  static Future<RideAnalytics> load({
    required List<TripHistoryModel> trips,
    int revision = 0,
    FuelInputs? fuel,
    int? nowMs,
    Future<List<RideStats>> Function()? loadStats,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    List<RideStats> stats;
    try {
      stats = await (loadStats ?? RideStatsStore.loadAll)();
    } catch (_) {
      stats = const [];
    }
    final key = keyOf(revision: revision, trips: trips, stats: stats, fuel: fuel, nowMs: now);
    final hit = cached(key);
    if (hit != null) return hit;
    final input = RideAnalyticsInput(
      rides: RideAnalyticsInputs.entriesOf(trips),
      safety: safetyEntriesOf(stats),
      fuel: fuel,
      nowMs: now,
    );
    final result = input.rides.length > isolateAbove && !kIsWeb ? await compute(RideAnalyticsCalculator.compute, input) : RideAnalyticsCalculator.compute(input);
    _cacheKey = key;
    _cache = result;
    return result;
  }

  static Future<double?> fuelPrice() async {
    try {
      final v = (await SharedPreferences.getInstance()).getDouble(keyFuelPrice);
      return v != null && v.isFinite && v > 0 ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Saves (or with null / 0 removes) the price per unit. Returns false when it could not be kept.
  static Future<bool> setFuelPrice(double? price) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (price == null || !price.isFinite || price <= 0) return await prefs.remove(keyFuelPrice);
      return await prefs.setDouble(keyFuelPrice, price);
    } catch (_) {
      return false;
    }
  }
}
