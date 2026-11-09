import '../places/fuel_match.dart';
import 'bike_input.dart';
import 'bike_profile.dart';
import 'bike_type.dart';

/// 3.55 mandatory bike details. A rider's bike must have: make / model, bike type, engine size
/// (cc), colour, tank (L, kg) and mileage (km/L, km/kg). An electric bike has no engine size or
/// fuel tank: it needs the model, type, colour and its mileage in km per kWh (the battery size is
/// optional; with it the app also knows the range). Pure Dart, unit tested.
///
/// Where it is enforced (never in an emergency, never mid-ride):
/// - the garage form ([validateBikeDetails], field messages);
/// - before creating or joining a ride as a rider (not as a pillion): the "Complete your bike"
///   sheet, pre-filled from [BikeDetailsSuggest];
/// - the gateway never refuses an older app: the rider record is only marked incomplete.
enum BikeDetailField {
  model('Make and model'),
  type('Bike type'),
  cc('Engine size'),
  colour('Colour'),
  tank('Tank size'),
  mileage('Mileage');

  const BikeDetailField(this.label);
  final String label;

  /// The garage form's field key for this detail (as in [validateBikeInput]).
  String get formKey => name;
}

class BikeDetails {
  BikeDetails._();

  static bool _isEv(BikeProfile b) => b.fuelType == BikeFuelType.ev;

  /// What is still missing on [bike] (empty: complete). A bike type counts only when the rider
  /// picked or confirmed it ([BikeProfile.bikeType] set): a guess must be confirmed once.
  static List<BikeDetailField> missing(BikeProfile? bike) {
    if (bike == null) return BikeDetailField.values.toList();
    final ev = _isEv(bike);
    final (mMin, mMax) = ev ? (2.0, 25.0) : (5.0, 120.0);
    return [
      if ('${bike.make} ${bike.model}'.trim().length < 2) BikeDetailField.model,
      if (bike.bikeType == null) BikeDetailField.type,
      if (!ev && (bike.engineCc < 50 || bike.engineCc > 2500)) BikeDetailField.cc,
      if (bike.colour.trim().isEmpty) BikeDetailField.colour,
      if (!ev && (bike.tankCapacityL < 2 || bike.tankCapacityL > 40)) BikeDetailField.tank,
      if (!(bike.expectedMileageKmL >= mMin && bike.expectedMileageKmL <= mMax)) BikeDetailField.mileage,
    ];
  }

  static bool isComplete(BikeProfile? bike) => missing(bike).isEmpty;

  /// "Add engine size and colour" for a list of missing details ('' when none).
  static String missingLine(List<BikeDetailField> m) {
    if (m.isEmpty) return '';
    final words = m.map((f) => f.label.toLowerCase()).toList();
    final list = words.length == 1 ? words.first : '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';
    return 'Add $list';
  }
}

/// The garage form check with the 3.55 mandatory details: everything [validateBikeInput] checks,
/// plus make / model, bike type, colour and (not for electric) engine size. Electric bikes may
/// leave the battery size empty (then [tank] is not checked); their mileage is km per kWh (2 to 25).
/// Field → message (empty map: all good).
Map<String, String> validateBikeDetails({
  required String name,
  required String make,
  required String model,
  required BikeType? type,
  required String colour,
  required String cc,
  required String tank,
  required String reserve,
  required String mileage,
  required String odometer,
  BikeFuelType fuelType = BikeFuelType.petrol,
}) {
  final ev = fuelType == BikeFuelType.ev;
  final unit = fuelType.unit;
  final evNoBattery = ev && tank.trim().isEmpty;
  final errors = validateBikeInput(
    // The name falls back to make + model, so an empty name is not an error when they are given.
    name: name.trim().isEmpty ? '$make $model' : name,
    cc: cc,
    tank: evNoBattery ? '10' : tank,
    reserve: evNoBattery ? '0' : reserve,
    mileage: ev ? '10' : mileage,
    odometer: odometer,
    unit: unit,
    checkCc: !ev,
  );
  if ('$make $model'.trim().length < 2) errors['model'] = 'Enter the make and model, e.g. Royal Enfield Classic 350';
  if (type == null) errors['type'] = 'Pick the bike type (it sets the shape your group sees)';
  if (colour.trim().isEmpty) errors['colour'] = 'Pick a colour so your group can spot you';
  if (!ev && cc.trim().isEmpty) {
    errors['cc'] = 'Enter the engine size, e.g. 350';
  } else if (!ev && errors.containsKey('cc')) {
    errors['cc'] = 'Engine size is 50 to 2500 cc';
  }
  if (ev) {
    final m = parseBikeNumber(mileage);
    if (m == null || m < 2 || m > 25) errors['mileage'] = 'Electric mileage is 2 to 25 km/kWh (range ÷ battery)';
    if (evNoBattery) {
      errors.remove('tank');
      errors.remove('reserve');
    }
  }
  return errors;
}

/// Pre-fills for the "Complete your bike" sheet and the garage form: the closest preset for the
/// typed model (engine size, tank, mileage, type), else the type guess alone.
class BikeDetailsSuggest {
  BikeDetailsSuggest._();

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// The preset whose model is in the typed make / model (or the other way round), or null.
  static BikeProfile? presetFor(String make, String model) {
    final typed = _norm('$make $model');
    final typedModel = _norm(model);
    if (typed.length < 3) return null;
    BikeProfile? best;
    var bestLen = 0;
    for (final p in BikeProfile.popularPresets) {
      final pm = _norm(p.model);
      final hit = (typedModel.isNotEmpty && (typedModel.contains(pm) || pm.contains(typedModel) && typedModel.length >= 4)) || typed.contains(pm);
      if (hit && pm.length > bestLen) {
        best = p;
        bestLen = pm.length;
      }
    }
    return best;
  }

  /// [bike] with every missing detail filled from the preset / guess where one is known (the
  /// rider still sees and confirms them). Details the rider gave are never changed, except a bike
  /// type that was only guessed, which stays unset (it must be confirmed).
  static BikeProfile fill(BikeProfile bike) {
    final p = presetFor(bike.make, bike.model) ?? presetFor('', bike.name);
    final ev = bike.fuelType == BikeFuelType.ev || p?.fuelType == BikeFuelType.ev;
    return bike.copyWith(
      engineCc: !ev && bike.engineCc < 50 ? (p?.engineCc ?? bike.engineCc) : bike.engineCc,
      tankCapacityL: !ev && (bike.tankCapacityL < 2 || bike.tankCapacityL > 40) ? (p?.tankCapacityL ?? bike.tankCapacityL) : bike.tankCapacityL,
      fuelType: ev ? BikeFuelType.ev : bike.fuelType,
    );
  }

  /// The type to pre-select in the picker (the rider confirms): picked, preset, guess, commuter.
  static BikeType typeFor(BikeProfile bike) {
    if (bike.bikeType != null) return bike.bikeType!;
    final p = presetFor(bike.make, bike.model) ?? presetFor('', bike.name);
    return p?.bikeType ?? bike.effectiveBikeType;
  }
}
