import 'package:flutter/foundation.dart';

import '../../domain/garage/bike_details.dart';
import '../../domain/garage/bike_profile.dart';
import '../../domain/garage/bike_sync.dart';
import '../../domain/garage/engine_care.dart';
import '../../domain/safety/fuel_profile.dart';
import 'auth_service.dart';
import 'fuel_economy_service.dart';
import 'garage_service.dart';
import 'settings_service.dart';
import 'weather_service.dart';

/// Keeps the rest of the app in step with the garage's active bike (3.55):
/// - engine care: the safety service's advisor gets the bike (none: no advice) and the warmest
///   temperature on the route from the weather check;
/// - fuel: the bike's tank, reserve and mileage fill the fuel profile when the rider set none
///   (their own fuel settings always win, see [SettingsService.adoptGarageFuelProfile]);
/// - the ride: the bike's colour (and model) is the rider's vehicle for new rides and joins and,
///   during a ride, is sent to the group at once (3.55 live bike change, RIDER_VEHICLE);
/// - the profile: a short bike summary is shared with the gateway, best effort, for analysis.
class GarageBinding {
  GarageBinding(
    this.garage, {
    this.engineCare,
    this.auth,
    this.settings,
    this.weather,
    this.onVehicleColour,
    this.onVehicle,
    this.onBikeDetails,
    this.fuelEconomy,
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

  /// 3.55 fix: the ride's fuel intelligence (fuel type, learned mileage), told about a bike change.
  final FuelEconomyService? fuelEconomy;

  /// Sets the vehicle colour sent when creating or joining a ride ('' when none).
  final void Function(String colour)? onVehicleColour;

  /// 3.55 live bike change: the active bike's colour and model ('' when none). The ride service
  /// keeps them for the next create / join and, during a ride, tells the group at once.
  final void Function(String colour, String model)? onVehicle;

  /// 3.55 bike type and mandatory details: the active bike's type id ('' when none) and whether
  /// its details are complete (sent with create / join and RIDER_VEHICLE; the map shape).
  final void Function(String kind, bool complete)? onBikeDetails;

  String? _lastUser;
  bool _disposed = false;

  BikeProfile? get activeBike => garage.activeBikeNotifier.value;

  void _onBike() {
    if (_disposed || !garage.isLoaded) return;
    // 3.56: an empty or incomplete garage takes what the profile on the gateway keeps first (a
    // new install / phone); the restored bike fires this listener again.
    if (_restoreNow()) return;
    final bike = activeBike;
    final care = engineCare;
    // Setting the bike restarts the advisor's stretch: only when it really changed.
    if (care != null && !identical(care.bike, bike)) care.bike = bike;
    // 3.55 fix: a bike changed mid-ride also changes the fuel type / learned mileage at once.
    fuelEconomy?.useBike(bike).ignore();
    onVehicleColour?.call(vehicleColourOf(bike));
    onBikeDetails?.call(vehicleKindOf(bike), BikeDetails.isComplete(bike));
    onVehicle?.call(vehicleColourOf(bike), vehicleModelOf(bike));
    _shareFuel(bike);
    _shareSummary(bike);
  }

  void _onAuth() {
    if (_disposed) return;
    final user = auth?.currentUserId;
    final changed = user != _lastUser;
    _lastUser = user;
    // 3.56: nothing is decided or sent before the garage has loaded (the load shares it):
    // an empty summary sent at start-up used to wipe the rider's bike on the server.
    if (!garage.isLoaded) return;
    if (_restoreNow()) return;
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
    // 3.56: never an empty garage's summary (it would clear the bike the server keeps).
    if (!BikeSync.mayShare(garageLoaded: garage.isLoaded, bike: bike)) return;
    a.syncBikeSummary(bikeSummaryOf(bike)).ignore();
  }

  bool _restoring = false;

  static String _newBikeId() => 'bike_${DateTime.now().millisecondsSinceEpoch}';

  /// Starts a restore when the gateway's copy fills something the garage is missing.
  bool _restoreNow() {
    if (_restoring) return false;
    if (BikeSync.merge(activeBike, auth?.bikeOnServer, newId: 'probe') == null) return false;
    restoreFromServer().ignore();
    return true;
  }

  /// 3.56: fills the garage's active bike from the profile on the gateway (a new install, a new
  /// phone, or details given on another phone); only what the phone is missing, never an empty
  /// value over one the rider gave. Creates the bike (and makes it active) in an empty garage.
  /// Awaited by the ride's bike check before it decides to ask.
  Future<void> restoreFromServer() async {
    if (_disposed || _restoring) return;
    _restoring = true;
    var restored = false;
    try {
      await garage.load();
      final merged = BikeSync.merge(activeBike, auth?.bikeOnServer, newId: _newBikeId());
      if (merged != null && await garage.saveBike(merged)) {
        await garage.setActiveBike(merged.id);
        restored = true;
      }
    } catch (e) {
      debugPrint('garage restore note: $e');
    } finally {
      _restoring = false;
    }
    // The listener ran while restoring (and skipped the share): share the result now.
    if (restored && !_disposed) _onBike();
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

  /// The bike type id the group's map draws ('' without a bike; the guess until the rider picks).
  static String vehicleKindOf(BikeProfile? bike) => bike == null ? '' : bike.effectiveBikeType.wire;

  /// The model as the group sees it: make and model, else the bike's name (at most 40 characters).
  static String vehicleModelOf(BikeProfile? bike) {
    if (bike == null) return '';
    final makeModel = '${bike.make} ${bike.model}'.trim();
    final m = (makeModel.isNotEmpty ? makeModel : bike.name).replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ').replaceAll(RegExp(' +'), ' ').trim();
    return m.length > 40 ? m.substring(0, 40).trim() : m;
  }

  /// The summary the gateway accepts (values outside its ranges are sent as "not given");
  /// 3.56: also the confirmed bike type and the fuel type ([BikeSync.summaryOf]).
  static Map<String, Object> bikeSummaryOf(BikeProfile? bike) => BikeSync.summaryOf(bike);

  void dispose() {
    _disposed = true;
    garage.activeBikeNotifier.removeListener(_onBike);
    auth?.removeListener(_onAuth);
    weather?.removeListener(_onWeather);
  }
}
