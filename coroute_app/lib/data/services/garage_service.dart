import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/feature_gates.dart';
import '../../domain/garage/bike_profile.dart';
import '../../domain/safety/fuel_profile.dart';

/// Manages multiple motorcycle profiles, active bike selection, odometer tracking,
/// and scheduled maintenance intervals in the rider's garage.
class GarageService {
  static const String _keyBikes = 'coroute_garage_bikes_v1';
  static const String _keyActiveBike = 'coroute_garage_active_bike_id';

  final ValueNotifier<List<BikeProfile>> bikesNotifier = ValueNotifier<List<BikeProfile>>([]);
  final ValueNotifier<BikeProfile?> activeBikeNotifier = ValueNotifier<BikeProfile?>(null);

  bool _loaded = false;

  Future<void>? _loading;

  /// The one garage the whole app shares (3.55): the garage screen, the engine-care advice and
  /// the profile summary all see the same bikes. Registered as a provider in main.dart.
  static final GarageService shared = GarageService();

  /// The sample bike earlier versions put in every new garage (3.55: removed). Only an untouched
  /// copy is recognised: a rider who rode it, serviced it or wrote notes keeps it as their own.
  static bool isLegacySeed(BikeProfile b) =>
      b.id == 'bike_default_01' &&
      b.name == 'Royal Enfield Himalayan 450' &&
      b.totalOdometerKm == 0 &&
      b.lastServiceOdometerKm == 0 &&
      b.notes.isEmpty;

  /// Loads stored motorcycle profiles from persistent storage. A new garage starts empty
  /// (3.55: no sample bike); an untouched legacy sample bike is removed.
  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    final rawList = sp.getStringList(_keyBikes);
    final activeId = sp.getString(_keyActiveBike);

    final loadedBikes = <BikeProfile>[];
    var removedSeed = false;
    if (rawList != null && rawList.isNotEmpty) {
      for (final item in rawList) {
        try {
          final map = jsonDecode(item) as Map<String, dynamic>;
          final bike = BikeProfile.fromJson(map);
          if (isLegacySeed(bike)) {
            removedSeed = true;
            continue;
          }
          loadedBikes.add(bike);
        } catch (_) {}
      }
    }
    if (removedSeed) await _persistBikes(sp, loadedBikes);

    bikesNotifier.value = loadedBikes;

    // Resolve active bike (none in an empty garage).
    final matching = loadedBikes.where((b) => b.id == activeId).toList();
    if (matching.isNotEmpty) {
      activeBikeNotifier.value = matching.first;
    } else if (loadedBikes.isNotEmpty) {
      activeBikeNotifier.value = loadedBikes.first;
      await sp.setString(_keyActiveBike, loadedBikes.first.id);
    } else {
      activeBikeNotifier.value = null;
      if (activeId != null) await sp.remove(_keyActiveBike);
    }

    _loaded = true;
  }

  /// The active bike as saved on the phone, read only (never seeds a default; skips the
  /// untouched legacy sample bike, so a garage not opened since 3.55 reads as empty).
  static Future<BikeProfile?> readActiveBike() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final activeId = sp.getString(_keyActiveBike);
      BikeProfile? first;
      for (final item in sp.getStringList(_keyBikes) ?? const <String>[]) {
        try {
          final b = BikeProfile.fromJson(jsonDecode(item) as Map<String, dynamic>);
          if (isLegacySeed(b)) continue;
          first ??= b;
          if (b.id == activeId) return b;
        } catch (_) {}
      }
      return first;
    } catch (_) {
      return null;
    }
  }

  /// Sets the active motorcycle used for convoy rides and fuel calculations.
  Future<void> setActiveBike(String id) async {
    final bikes = bikesNotifier.value;
    final target = bikes.where((b) => b.id == id).toList();
    if (target.isEmpty) return;

    final sp = await SharedPreferences.getInstance();
    await sp.setString(_keyActiveBike, id);
    activeBikeNotifier.value = target.first;
  }

  /// Adds a new bike or updates an existing bike profile in the garage (same id: edit).
  /// False when a new bike is not allowed by the plan.
  Future<bool> saveBike(BikeProfile bike) async {
    // Feature gate check: Free tier allows 1 bike, multiBikeGarage allows unlimited
    final currentBikes = List<BikeProfile>.from(bikesNotifier.value);
    final existingIndex = currentBikes.indexWhere((b) => b.id == bike.id);

    if (existingIndex < 0 &&
        currentBikes.isNotEmpty &&
        !FeatureGates.isUnlocked(Feature.multiBikeGarage)) {
      // Future IAP protection: in community tier, only 1 bike is supported
      return false;
    }

    if (existingIndex >= 0) {
      currentBikes[existingIndex] = bike;
    } else {
      currentBikes.add(bike);
    }

    bikesNotifier.value = currentBikes;
    final sp = await SharedPreferences.getInstance();
    await _persistBikes(sp, currentBikes);

    if (activeBikeNotifier.value?.id == bike.id || currentBikes.length == 1) {
      activeBikeNotifier.value = bike;
      await sp.setString(_keyActiveBike, bike.id);
    }
    return true;
  }

  /// Deletes a motorcycle profile from the garage.
  Future<void> deleteBike(String id) async {
    final currentBikes = List<BikeProfile>.from(bikesNotifier.value);
    if (currentBikes.length <= 1) {
      // Cannot delete the only remaining bike
      return;
    }

    currentBikes.removeWhere((b) => b.id == id);
    bikesNotifier.value = currentBikes;

    final sp = await SharedPreferences.getInstance();
    await _persistBikes(sp, currentBikes);

    if (activeBikeNotifier.value?.id == id) {
      activeBikeNotifier.value = currentBikes.first;
      await sp.setString(_keyActiveBike, currentBikes.first.id);
    }
  }

  /// Records completed maintenance on a bike, updating its last service odometer.
  Future<void> recordServiceCompleted(String id, double odometerAtServiceKm) async {
    final currentBikes = List<BikeProfile>.from(bikesNotifier.value);
    final index = currentBikes.indexWhere((b) => b.id == id);
    if (index < 0) return;

    final updated = currentBikes[index].copyWith(
      lastServiceOdometerKm: odometerAtServiceKm,
      totalOdometerKm: odometerAtServiceKm > currentBikes[index].totalOdometerKm
          ? odometerAtServiceKm
          : currentBikes[index].totalOdometerKm,
    );

    currentBikes[index] = updated;
    bikesNotifier.value = currentBikes;

    final sp = await SharedPreferences.getInstance();
    await _persistBikes(sp, currentBikes);

    if (activeBikeNotifier.value?.id == id) {
      activeBikeNotifier.value = updated;
    }
  }

  /// Increments the active bike's odometer after a ride completes.
  Future<void> addTripDistance(double distanceKm) async {
    final active = activeBikeNotifier.value;
    if (active == null || distanceKm <= 0) return;

    final updated = active.copyWith(
      totalOdometerKm: active.totalOdometerKm + distanceKm,
    );
    await saveBike(updated);
  }

  /// Exports the active bike's fuel attributes into a [FuelProfile] for live tracking.
  FuelProfile toFuelProfile() {
    final active = activeBikeNotifier.value;
    if (active == null) {
      return const FuelProfile();
    }
    return FuelProfile(
      capacityL: active.tankCapacityL,
      mileageKmL: active.expectedMileageKmL,
      reserveL: active.reserveCapacityL,
      bufferKm: 15.0,
    );
  }

  Future<void> _persistBikes(SharedPreferences sp, List<BikeProfile> bikes) async {
    final list = bikes.map((b) => jsonEncode(b.toJson())).toList();
    await sp.setStringList(_keyBikes, list);
  }
}
