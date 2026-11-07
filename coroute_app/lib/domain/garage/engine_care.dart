// Engine care from the bike's details (3.55): when to give the engine a rest on a long hard
// stretch, and what to keep in mind at a stop. Pure Dart, fed with the rider's own fixes.
//
// The numbers are conservative rider rules of thumb, not a temperature reading (a phone cannot
// read the engine): small air-cooled engines held at high revs for a long time run hot, so they
// get a rest reminder sooner; liquid-cooled engines later. Heat makes it sooner still.
import '../places/fuel_match.dart';
import '../tracking/track_point.dart';
import 'bike_profile.dart';

/// The stretch after which a rest is advised, for a bike (null: no advice, e.g. electric).
Duration? engineRestAfter(BikeProfile bike, {double airTempC = 0}) {
  if (bike.fuelType == BikeFuelType.ev) return null;
  final cc = bike.engineCc;
  Duration base;
  switch (bike.effectiveCooling) {
    case EngineCooling.air:
      base = cc > 0 && cc <= 125 ? const Duration(minutes: 60) : const Duration(minutes: 75);
    case EngineCooling.oil:
      base = const Duration(minutes: 90);
    case EngineCooling.liquid:
      base = const Duration(minutes: 120);
    case EngineCooling.unknown:
      // Without details: the break reminder covers it (no separate engine advice).
      return null;
  }
  // Hot afternoons (35 °C and above) shorten it by a quarter.
  if (airTempC >= 35) base = Duration(minutes: (base.inMinutes * 0.75).round());
  return base;
}

/// How long the engine should rest (minutes) once stopped.
int engineRestMinutes(BikeProfile bike) => switch (bike.effectiveCooling) {
      EngineCooling.air => 15,
      EngineCooling.oil => 10,
      _ => 10,
    };

/// One piece of advice to show and say.
class EngineCareAdvice {
  final String title;
  final String message;
  final String speech;
  const EngineCareAdvice({required this.title, required this.message, required this.speech});
}

/// Watches hard riding (above [hardKmh]) without a stop of [restFor]; advises once per stretch.
class EngineCareAdvisor {
  EngineCareAdvisor({this.hardKmh = 60, this.restFor = const Duration(minutes: 8)});

  final double hardKmh;
  final Duration restFor;

  BikeProfile? _bike;
  double _airTempC = 0;
  int? _hardSince;
  int? _slowSince;
  int? _lastTs;
  bool _advised = false;

  /// The active bike from the garage (null: no advice).
  set bike(BikeProfile? b) {
    _bike = b;
    reset();
  }

  BikeProfile? get bike => _bike;

  /// The air temperature at the ride (from the weather check), °C.
  set airTempC(double t) => _airTempC = t;

  void reset() {
    _hardSince = null;
    _slowSince = null;
    _lastTs = null;
    _advised = false;
  }

  /// One fix; returns advice once when the hard stretch passes the bike's limit.
  EngineCareAdvice? onFix(TrackPoint p) {
    final b = _bike;
    if (b == null) return null;
    final limit = engineRestAfter(b, airTempC: _airTempC);
    if (limit == null) return null;
    final t = p.ts;
    final last = _lastTs;
    if (last != null && t < last) return null;
    _lastTs = t;
    // No fixes for a while: the bike was parked.
    if (last != null && t - last >= restFor.inMilliseconds) {
      _hardSince = null;
      _advised = false;
    }
    if (p.speedKmh >= hardKmh) {
      _slowSince = null;
      _hardSince ??= t;
    } else {
      _slowSince ??= t;
      if (t - _slowSince! >= restFor.inMilliseconds) {
        _hardSince = null;
        _advised = false;
      }
    }
    final since = _hardSince;
    if (since == null || _advised || t - since < limit.inMilliseconds) return null;
    _advised = true;
    final mins = engineRestMinutes(b);
    final hours = ((t - since) / 3600000);
    final ridden = hours >= 1 ? '${hours.toStringAsFixed(hours >= 2 ? 0 : 1)} h' : '${((t - since) / 60000).round()} min';
    final name = b.model.isNotEmpty ? b.model : b.name;
    final cool = b.effectiveCooling.label.toLowerCase();
    return EngineCareAdvice(
      title: 'Give your engine a rest',
      message: '$ridden of hard riding on your $cool $name. A $mins-minute stop in the shade lets the engine and you cool down.',
      speech: 'You have been riding hard for $ridden. At the next safe place, stop for about $mins minutes to let the engine cool.',
    );
  }
}
