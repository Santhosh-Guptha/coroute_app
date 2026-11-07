// What a rider types in the garage's add/edit sheet (3.55), checked with friendly messages.
// Pure Dart so it is unit tested; the gateway checks the shared summary again on its side.

/// Parses a number a rider typed ("13,5" works too); null when empty or not a number.
double? parseBikeNumber(String raw) {
  final t = raw.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  return v != null && v.isFinite ? v : null;
}

/// Field → message for every problem (empty map: all good). [unit] is the fuel unit (L, kg, kWh).
/// Engine size may be left empty; tank, reserve and mileage must be given.
Map<String, String> validateBikeInput({
  required String name,
  required String cc,
  required String tank,
  required String reserve,
  required String mileage,
  required String odometer,
  String unit = 'L',
  bool checkCc = true,
}) {
  final errors = <String, String>{};
  if (name.trim().isEmpty) errors['name'] = 'Give your bike a name';

  if (checkCc && cc.trim().isNotEmpty) {
    final v = parseBikeNumber(cc);
    if (v == null || v != v.roundToDouble() || v < 50 || v > 2500) {
      errors['cc'] = 'Engine size is 50 to 2500 cc (or leave it empty)';
    }
  }

  final t = parseBikeNumber(tank);
  if (t == null || t < 2 || t > 40) errors['tank'] = 'Tank holds 2 to 40 $unit';

  final r = parseBikeNumber(reserve);
  if (r == null || r < 0) {
    errors['reserve'] = 'Enter the reserve in $unit (0 if none)';
  } else if (t != null && r >= t) {
    errors['reserve'] = 'Reserve must be less than the tank';
  }

  final m = parseBikeNumber(mileage);
  if (m == null || m < 5 || m > 120) errors['mileage'] = 'Mileage is 5 to 120 km/$unit';

  if (odometer.trim().isNotEmpty) {
    final o = parseBikeNumber(odometer);
    if (o == null) {
      errors['odometer'] = 'Enter the odometer in km';
    } else if (o < 0) {
      errors['odometer'] = 'Odometer can\'t be negative';
    }
  }
  return errors;
}
