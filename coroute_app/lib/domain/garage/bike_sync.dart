import '../places/fuel_match.dart';
import 'bike_details.dart';
import 'bike_profile.dart';
import 'bike_type.dart';

/// 3.56 bike details once (owner bug: "When creating a ride it asks for the bike details every
/// time. Make it one time and sync it with the garage."). Pure Dart, unit tested.
///
/// One source of truth: the garage's active bike. These helpers decide
/// - when the "Complete your bike" sheet is needed before a create / join ([BikeGatePlan]);
/// - what the profile on the gateway keeps ([summaryOf], every detail incl. the confirmed type
///   and the fuel type) and when it may be sent ([mayShare]: never before the garage has loaded,
///   never for an empty garage, which used to wipe the server copy at start-up);
/// - how the garage is restored from that copy on a new install or phone ([merge]: it only fills
///   what the phone is missing and never overwrites a value the rider gave with an empty one).
class BikeSync {
  BikeSync._();

  /// The summary keys every gateway with the 3.55 summary knows.
  static const List<String> baseKeys = ['bikeModel', 'bikeCc', 'bikeColour', 'bikeTankL', 'bikeMileageKmL', 'bikeCooling'];

  /// 3.56 keys (only sent to a gateway whose profile returned them).
  static const List<String> detailKeys = ['bikeType', 'bikeFuel'];

  static const List<String> allKeys = [...baseKeys, ...detailKeys];

  static String _text(String s, int max) {
    final t = s.replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F  ]'), ' ').replaceAll(RegExp(' +'), ' ').trim();
    return t.length > max ? t.substring(0, max).trim() : t;
  }

  static double _inRange(double v, double min, double max) => v.isFinite && v >= min && v <= max ? (v * 10).round() / 10 : 0;

  /// What the gateway keeps for [bike] (values outside its ranges are sent as "not given").
  static Map<String, Object> summaryOf(BikeProfile? bike) {
    if (bike == null) {
      return {'bikeModel': '', 'bikeCc': 0, 'bikeColour': '', 'bikeTankL': 0, 'bikeMileageKmL': 0, 'bikeCooling': 'unknown', 'bikeType': '', 'bikeFuel': ''};
    }
    final ev = bike.fuelType == BikeFuelType.ev;
    final makeModel = '${bike.make} ${bike.model}'.trim();
    return {
      'bikeModel': _text(makeModel.isNotEmpty ? makeModel : bike.name, 60),
      'bikeCc': bike.engineCc >= 50 && bike.engineCc <= 2500 ? bike.engineCc : 0,
      'bikeColour': _text(bike.colour, 30),
      'bikeTankL': _inRange(bike.tankCapacityL, 2, 40),
      'bikeMileageKmL': _inRange(bike.expectedMileageKmL, ev ? 2 : 5, 120),
      'bikeCooling': bike.cooling.name,
      'bikeType': bike.bikeType?.wire ?? '',
      'bikeFuel': bike.fuelType.name,
    };
  }

  /// The active bike's summary may be shared only once the garage has loaded and has a bike: an
  /// empty summary sent before the load (or from a fresh install) wiped the rider's bike on the
  /// server, so it could never come back.
  static bool mayShare({required bool garageLoaded, required BikeProfile? bike}) => garageLoaded && bike != null;

  /// The keys of [summary] that differ from what the server returned ([server]); only keys the
  /// server knows are sent (an older gateway never sees the 3.56 keys).
  static Map<String, Object> changes(Map<String, Object> summary, Map<String, dynamic> server) => {
        for (final e in summary.entries)
          if (server.containsKey(e.key) && !_same(server[e.key], e.value)) e.key: e.value,
      };

  static bool _same(Object? a, Object b) {
    if (a is num && b is num) return (a - b).abs() < 0.05;
    return (a ?? '').toString() == b.toString();
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static double _num(Object? v) => v is num && v.isFinite ? v.toDouble() : (v is String ? double.tryParse(v) ?? 0 : 0);

  /// The garage bike after restoring from the gateway's copy [server], or null when nothing
  /// changes. [local] is the active bike on the phone (null: empty garage, e.g. a new install).
  /// - No local bike: a new bike from the server copy (missing details stay missing, never
  ///   made up, so the sheet asks only for those).
  /// - A local bike of the same model (or with no model yet): only details that are missing or
  ///   out of range on the phone are filled; whatever the rider gave on the phone wins.
  /// - A different bike on the phone: nothing (the phone is the source; it is sent up instead).
  static BikeProfile? merge(BikeProfile? local, Map<String, dynamic>? server, {required String newId}) {
    if (server == null) return null;
    final model = (server['bikeModel'] ?? '').toString().trim();
    if (model.length < 2) return null;
    final type = BikeType.parse(server['bikeType']);
    final fuelRaw = (server['bikeFuel'] ?? '').toString();
    final fuel = fuelRaw.isEmpty ? (type == BikeType.electric ? BikeFuelType.ev : BikeFuelType.petrol) : BikeFuelTypeInfo.parse(fuelRaw);
    final cc = _num(server['bikeCc']).round();
    final colour = (server['bikeColour'] ?? '').toString().trim();
    final tank = _num(server['bikeTankL']);
    final mileage = _num(server['bikeMileageKmL']);
    final cooling = EngineCooling.parse(server['bikeCooling']);

    if (local == null) {
      return BikeProfile(
        id: newId,
        name: model,
        model: model,
        bikeType: type,
        fuelType: fuel,
        engineCc: cc,
        colour: colour,
        tankCapacityL: tank,
        reserveCapacityL: tank > 0 ? (tank * 0.15 * 10).round() / 10 : 0,
        expectedMileageKmL: mileage,
        cooling: cooling,
      );
    }

    final localModel = _norm('${local.make} ${local.model}');
    final localName = _norm(local.name);
    final sameBike = localModel.length < 2 ? (localName.isEmpty || localName == _norm(model)) : localModel == _norm(model);
    if (!sameBike) return null;
    final missing = BikeDetails.missing(local).toSet();
    if (missing.isEmpty) return null;
    final ev = local.fuelType == BikeFuelType.ev;
    var b = local;
    var changed = false;
    if (missing.contains(BikeDetailField.model)) {
      b = b.copyWith(model: model, name: local.name.trim().isEmpty ? model : local.name);
      changed = true;
    }
    // The type only counts when the rider confirmed it; the server keeps only a confirmed one.
    // An electric type on a petrol bike (or the other way round) is not taken.
    if (missing.contains(BikeDetailField.type) && type != null && (type == BikeType.electric) == ev) {
      b = b.copyWith(bikeType: type);
      changed = true;
    }
    if (missing.contains(BikeDetailField.cc) && cc >= 50 && cc <= 2500) {
      b = b.copyWith(engineCc: cc);
      changed = true;
    }
    if (missing.contains(BikeDetailField.colour) && colour.isNotEmpty) {
      b = b.copyWith(colour: colour);
      changed = true;
    }
    if (missing.contains(BikeDetailField.tank) && tank >= 2 && tank <= 40) {
      b = b.copyWith(tankCapacityL: tank, reserveCapacityL: b.reserveCapacityL < tank ? b.reserveCapacityL : (tank * 0.15 * 10).round() / 10);
      changed = true;
    }
    final (mMin, mMax) = ev ? (2.0, 25.0) : (5.0, 120.0);
    if (missing.contains(BikeDetailField.mileage) && mileage >= mMin && mileage <= mMax && (fuelRaw.isEmpty || fuel == local.fuelType)) {
      b = b.copyWith(expectedMileageKmL: mileage);
      changed = true;
    }
    return changed ? b : null;
  }
}

/// What a create / join does about the bike.
enum BikeGateStep { pillion, rider, ask }

/// 3.56: the bike check before creating or joining a ride, decided from the garage's active bike
/// only, and only after the garage has loaded (an empty list before the load is not "no bike").
class BikeGatePlan {
  BikeGatePlan._();

  /// [loaded] false is treated as "load first": callers await the load, so this never asks on
  /// an empty in-memory garage.
  static BikeGateStep decide({required bool pillionAccount, required bool loaded, required BikeProfile? active}) {
    if (pillionAccount) return BikeGateStep.pillion;
    if (!loaded) return BikeGateStep.ask; // only reached when the load failed
    return BikeDetails.isComplete(active) ? BikeGateStep.rider : BikeGateStep.ask;
  }

  /// The one-time home prompt: never for a pillion account, never twice (shown or dismissed),
  /// never for a complete bike, and not for an empty garage (create / join asks then).
  static bool shouldPromptOnce({required bool alreadyPrompted, required bool pillionAccount, required bool loaded, required BikeProfile? active}) =>
      !alreadyPrompted && !pillionAccount && loaded && active != null && !BikeDetails.isComplete(active);
}
