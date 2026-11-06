import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/garage/bike_profile.dart';
import '../../domain/places/fuel_economy.dart';
import '../../domain/places/fuel_match.dart';
import '../../domain/safety/fuel_profile.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
import 'garage_service.dart';

/// On-device fuel intelligence for one ride: the active bike's fuel type, the
/// mileage learned from fill-ups (kept per bike on the phone), the riding style
/// of this ride and which "fill up here" warnings were already given. Never
/// throws; with nothing learned it changes nothing.
class FuelEconomyService {
  FuelEconomyService({Future<SharedPreferences> Function()? prefs, Future<BikeProfile?> Function()? activeBike})
      : _prefs = prefs ?? SharedPreferences.getInstance,
        _activeBike = activeBike ?? GarageService.readActiveBike;

  final Future<SharedPreferences> Function() _prefs;
  final Future<BikeProfile?> Function() _activeBike;

  BikeFuelType fuelType = BikeFuelType.petrol;
  String bikeId = 'default';
  FuelLearning learning = FuelLearning();
  final RidingStyle style = RidingStyle();
  double climbM = 0;
  final Set<String> _longGapWarned = {};
  Future<void>? _loading;
  double? _lastLat, _lastLng;
  int _lastTs = 0;

  String get _key => 'fuel_learning_v1:$bikeId';

  /// Loads the active bike and its learned mileage (once; [reload] after a garage change).
  Future<void> ensureLoaded({bool reload = false}) {
    if (reload) _loading = null;
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final bike = await _activeBike();
      if (bike != null) {
        fuelType = bike.fuelType;
        bikeId = bike.id;
      }
    } catch (_) {/* garage unreadable: petrol, default */}
    try {
      final raw = (await _prefs()).getString(_key);
      learning = raw == null ? FuelLearning() : FuelLearning.fromJson(jsonDecode(raw));
    } catch (_) {
      learning = FuelLearning();
    }
  }

  /// A new ride: the style and the warnings start again.
  void startRide() {
    style.reset();
    climbM = 0;
    _longGapWarned.clear();
    _lastLat = _lastLng = null;
    _lastTs = 0;
  }

  /// Each fix the ride already records: distance per speed band (no extra GPS work).
  void onFix(TrackPoint p) {
    if (!p.lat.isFinite || !p.lng.isFinite || p.accuracyM > 100) return;
    final lat = _lastLat, lng = _lastLng;
    if (lat != null && lng != null && p.ts > _lastTs && p.ts - _lastTs <= 60000 && p.speedKmh > 3) {
      final km = GeoMath.haversine(lat, lng, p.lat, p.lng) / 1000;
      if (km < 2) style.add(km, p.speedKmh);
    }
    _lastLat = p.lat;
    _lastLng = p.lng;
    _lastTs = p.ts;
  }

  /// Usable km with learned mileage, style and climbing; null when none of
  /// them applies, so the plain estimate stays exactly as before.
  double? adjust(FuelProfile p, {required double baselineKm, required double riddenKm}) {
    if (!p.valid) return null;
    final learned = p.litresMode && learning.learnedKmPerUnit != null ? learning.effectiveKmPerUnit(p.mileageKmL) : null;
    final f = style.factor;
    if (learned == null && f == 1.0 && climbM <= 0) return null;
    return adjustedUsableKm(p, baselineKm: baselineKm, riddenKm: riddenKm, effectiveKmPerUnit: learned, styleFactor: f, climbM: climbM);
  }

  /// A confirmed fill; learns from full-to-full windows and saves on the phone.
  Future<void> recordFill({required double kmSincePrev, double? amount, required bool full, required bool reliable,
      required double ratedKmPerUnit, required int at}) async {
    _longGapWarned.clear();
    try {
      await ensureLoaded();
      learning.addFill(
          FillRecord(at: at, kmSincePrev: kmSincePrev.isFinite ? kmSincePrev : 0, amount: amount != null && amount > 0 ? amount : null,
              full: full, reliable: reliable && kmSincePrev.isFinite),
          ratedKmPerUnit: ratedKmPerUnit,
          bounds: fuelType.mileageBounds);
      await (await _prefs()).setString(_key, jsonEncode(learning.toJson()));
    } catch (_) {/* learning is optional */}
  }

  /// True once per station per fill: the "fill up here" warning is given once.
  bool claimLongGap(String stationId) => _longGapWarned.add(stationId);
}
