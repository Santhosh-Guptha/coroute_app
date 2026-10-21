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

  /// Loads stored motorcycle profiles from persistent storage.
  Future<void> load() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    final rawList = sp.getStringList(_keyBikes);
    final activeId = sp.getString(_keyActiveBike);

    List<BikeProfile> loadedBikes = [];
    if (rawList != null && rawList.isNotEmpty) {
      for (final item in rawList) {
        try {
          final map = jsonDecode(item) as Map<String, dynamic>;
          loadedBikes.add(BikeProfile.fromJson(map));
        } catch (_) {}
      }
    }

    if (loadedBikes.isEmpty) {
      // Seed with default touring motorcycle
      final defaultBike = const BikeProfile(
        id: 'bike_default_01',
        name: 'Royal Enfield Himalayan 450',
        make: 'Royal Enfield',
        model: 'Himalayan 450',
        year: 2024,
        tankCapacityL: 17.0,
        reserveCapacityL: 3.5,
        expectedMileageKmL: 28.0,
        totalOdometerKm: 0.0,
        serviceIntervalKm: 5000.0,
        lastServiceOdometerKm: 0.0,
        isDefault: true,
      );
      loadedBikes = [defaultBike];
      await _persistBikes(sp, loadedBikes);
      await sp.setString(_keyActiveBike, defaultBike.id);
    }

    bikesNotifier.value = loadedBikes;

    // Resolve active bike
    final matching = loadedBikes.where((b) => b.id == activeId).toList();
    if (matching.isNotEmpty) {
      activeBikeNotifier.value = matching.first;
    } else {
      activeBikeNotifier.value = loadedBikes.first;
      await sp.setString(_keyActiveBike, loadedBikes.first.id);
    }

    _loaded = true;
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

  /// Adds a new bike or updates an existing bike profile in the garage.
  Future<void> saveBike(BikeProfile bike) async {
    // Feature gate check: Free tier allows 1 bike, multiBikeGarage allows unlimited
    final currentBikes = List<BikeProfile>.from(bikesNotifier.value);
    final existingIndex = currentBikes.indexWhere((b) => b.id == bike.id);

    if (existingIndex < 0 &&
        currentBikes.isNotEmpty &&
        !FeatureGates.isUnlocked(Feature.multiBikeGarage)) {
      // Future IAP protection: in community tier, only 1 bike is supported
      return;
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
