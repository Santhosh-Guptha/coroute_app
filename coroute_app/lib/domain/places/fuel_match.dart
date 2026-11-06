import 'place_poi.dart';
import 'poi_category.dart';

/// What the bike runs on (garage). Default petrol.
enum BikeFuelType { petrol, diesel, cng, ev }

extension BikeFuelTypeInfo on BikeFuelType {
  String get label => switch (this) {
        BikeFuelType.petrol => 'Petrol',
        BikeFuelType.diesel => 'Diesel',
        BikeFuelType.cng => 'CNG',
        BikeFuelType.ev => 'Electric',
      };

  /// Unit of the tank and of the mileage (km per unit).
  String get unit => switch (this) {
        BikeFuelType.ev => 'kWh',
        BikeFuelType.cng => 'kg',
        _ => 'L',
      };

  /// "petrol station" / "charging point", for plain sentences.
  String get stationWord => switch (this) {
        BikeFuelType.ev => 'charging point',
        BikeFuelType.cng => 'CNG station',
        _ => '${label.toLowerCase()} station',
      };

  /// Sensible mileage bounds (km per unit) for learning.
  (double, double) get mileageBounds => switch (this) {
        BikeFuelType.ev => (2, 25),
        BikeFuelType.cng => (10, 120),
        _ => (5, 120),
      };

  static BikeFuelType parse(Object? v) {
    for (final t in BikeFuelType.values) {
      if (t.name == v) return t;
    }
    return BikeFuelType.petrol;
  }
}

enum FuelMatch { match, unknown, noMatch }

const _petrolKeys = ['fuel:octane_91', 'fuel:octane_92', 'fuel:octane_95', 'fuel:octane_98', 'fuel:octane_100',
  'fuel:petrol', 'fuel:e5', 'fuel:e10', 'fuel:e20'];
const _dieselKeys = ['fuel:diesel', 'fuel:HGV_diesel', 'fuel:biodiesel'];
const _cngKeys = ['fuel:cng', 'fuel:biogas'];

FuelMatch _byKeys(Map<String, String> t, List<String> keys) {
  var sawNo = false;
  for (final k in keys) {
    final v = t[k];
    if (v == 'yes') return FuelMatch.match;
    if (v == 'no') sawNo = true;
  }
  return sawNo ? FuelMatch.noMatch : FuelMatch.unknown;
}

/// Whether a station sells what this bike needs. A station without fuel tags is
/// "unknown" (shown, lower priority); only an explicit "no" hides it.
FuelMatch fuelMatch(PlacePoi p, BikeFuelType type) {
  if (type == BikeFuelType.ev) {
    if (p.category == PoiCategory.ev) return FuelMatch.match;
    return FuelMatch.noMatch;
  }
  if (p.category != PoiCategory.fuel) return FuelMatch.noMatch;
  final t = p.tags;
  switch (type) {
    case BikeFuelType.petrol:
      return _byKeys(t, _petrolKeys);
    case BikeFuelType.diesel:
      return _byKeys(t, _dieselKeys);
    case BikeFuelType.cng:
      final m = _byKeys(t, _cngKeys);
      if (m == FuelMatch.unknown && RegExp(r'\bcng\b', caseSensitive: false).hasMatch(p.name)) return FuelMatch.match;
      return m;
    case BikeFuelType.ev:
      return FuelMatch.noMatch;
  }
}
