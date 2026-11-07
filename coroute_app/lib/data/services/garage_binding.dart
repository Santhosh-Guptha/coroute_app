import 'package:flutter/foundation.dart';

import '../../domain/garage/bike_profile.dart';
import '../../domain/garage/engine_care.dart';
import '../../domain/safety/fuel_profile.dart';
import 'auth_service.dart';
import 'garage_service.dart';
import 'settings_service.dart';
import 'weather_service.dart';

/// Keeps the rest of the app in step with the garage's active bike (3.55):
/// - engine care: the safety service's advisor gets the bike (none: no advice) and the warmest
///   temperature on the route from the weather check;
/// - fuel: the bike's tank, reserve and mileage fill the fuel profile when the rider set none
///   (their own fuel settings always win, see [SettingsService.adoptGarageFuelProfile]);
/// - the ride: the bike's colour is the rider's vehicle colour for new rides and joins;
/// - the profile: a short bike summary is shared with the gateway, best effort, for analysis.
class GarageBinding {
  GarageBinding(
    this.garage, {
    this.engineCare,
    this.auth,
    this.settings,
    this.weather,
    this.onVehicleColour,
  }) {
    garage.activeBikeNotifier.addListener(_onBike);
    auth?.addListener(_onAuth);
    weather?.addListener(_onWeather);
    _lastUser = auth?.currentUserId;
    _onWeather();
    garage.load().then((_) => _onBike()).catchError((Object e) {
      debugPrint('garage note: $e');
    });
  }

  final GarageService garage;
  final EngineCareAdvisor? engineCare;
  final AuthService? auth;
  final SettingsService? settings;
  final WeatherService? weather;

  /// Sets the vehicle colour sent when creating or joining a ride ('' when none).
  final void Function(String colour)? onVehicleColour;

  String? _lastUser;
  bool _disposed = false;

  BikeProfile? get activeBike => garage.activeBikeNotifier.value;

  void _onBike() {
    if (_disposed) return;
    final bike = activeBike;
    final care = engineCare;
    // Setting the bike restarts the advisor's stretch: only when it really changed.
    if (care != null && !identical(care.bike, bike)) care.bike = bike;
    onVehicleColour?.call(vehicleColourOf(bike));
    _shareFuel(bike);
    _shareSummary(bike);
  }

  void _onAuth() {
    if (_disposed) return;
    final user = auth?.currentUserId;
    final changed = user != _lastUser;
    _lastUser = user;
    final bike = activeBike;
    // A different rider on this phone has their own fuel settings.
    if (changed) _shareFuel(bike);
    // The gateway's copy may have just arrived (/me): send only what differs.
    _shareSummary(bike);
  }

  void _onWeather() {
    if (_disposed) return;
    final t = weather?.last?.maxTempC;
    if (t != null) engineCare?.airTempC = t;
  }

  void _shareFuel(BikeProfile? bike) {
    final s = settings;
    final p = bike == null ? null : fuelProfileOf(bike);
    if (s == null || p == null) return;
    s.adoptGarageFuelProfile(p).ignore();
  }

  void _shareSummary(BikeProfile? bike) {
    final a = auth;
    if (a == null || a.currentUserId == null) return;
    a.syncBikeSummary(bikeSummaryOf(bike)).ignore();
  }

  /// The fuel profile a bike gives (null without tank and mileage).
  static FuelProfile? fuelProfileOf(BikeProfile bike) {
    if (bike.tankCapacityL <= 0 || bike.expectedMileageKmL <= 0) return null;
    final p = FuelProfile(
      capacityL: bike.tankCapacityL,
      mileageKmL: bike.expectedMileageKmL,
      reserveL: bike.reserveCapacityL.clamp(0, bike.tankCapacityL).toDouble(),
      bufferKm: 15,
    );
    return p.valid ? p : null;
  }

  /// The colour as the ride shows it (the gateway keeps at most 20 characters).
  static String vehicleColourOf(BikeProfile? bike) {
    final c = (bike?.colour ?? '').replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ').trim();
    return c.length > 20 ? c.substring(0, 20).trim() : c;
  }

  /// The summary the gateway accepts (values outside its ranges are sent as "not given").
  static Map<String, Object> bikeSummaryOf(BikeProfile? bike) {
    String text(String s, int max) {
      final t = s.replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F  ]'), ' ').replaceAll(RegExp(' +'), ' ').trim();
      return t.length > max ? t.substring(0, max).trim() : t;
    }

    double inRange(double v, double min, double max) => v.isFinite && v >= min && v <= max ? (v * 10).round() / 10 : 0;
    if (bike == null) {
      return {'bikeModel': '', 'bikeCc': 0, 'bikeColour': '', 'bikeTankL': 0, 'bikeMileageKmL': 0, 'bikeCooling': 'unknown'};
    }
    final makeModel = '${bike.make} ${bike.model}'.trim();
    return {
      'bikeModel': text(makeModel.isNotEmpty ? makeModel : bike.name, 60),
      'bikeCc': bike.engineCc >= 50 && bike.engineCc <= 2500 ? bike.engineCc : 0,
      'bikeColour': text(bike.colour, 30),
      'bikeTankL': inRange(bike.tankCapacityL, 2, 40),
      'bikeMileageKmL': inRange(bike.expectedMileageKmL, 5, 120),
      'bikeCooling': bike.cooling.name,
    };
  }

  void dispose() {
    _disposed = true;
    garage.activeBikeNotifier.removeListener(_onBike);
    auth?.removeListener(_onAuth);
    weather?.removeListener(_onWeather);
  }
}
