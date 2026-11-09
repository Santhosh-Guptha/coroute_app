import 'rider_model.dart';

/// 3.55 live bike change: the RIDER_VEHICLE message the app sends when the rider picks another
/// garage bike during a ride, so the colour and model the group sees follow at once (before, they
/// changed only on the next ride or join). Pure helpers, unit tested; the gateway validates the
/// same rules again (gateway/src/convoys.js riderVehicleInput).
class RiderVehicle {
  RiderVehicle._();

  /// The gateway applies one update per rider per this window; the app keeps the latest bike and
  /// sends it once the window has passed.
  static const Duration rateWindow = Duration(seconds: 10);
  static const int colourMax = 20;
  static const int modelMax = 40;

  static final RegExp _hex = RegExp(r'^#[0-9A-Fa-f]{6}$');
  static final RegExp _name = RegExp(r"^\p{L}[\p{L}\p{M}\p{N} .'\-/]{0,19}$", unicode: true);
  static final RegExp _junk = RegExp(r'[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]', unicode: true);

  /// The colour as the gateway accepts it: a colour name (letters first, at most 20 characters) or
  /// #RRGGBB (upper case). '' when there is none or it is not acceptable (then it is not sent).
  static String cleanColour(String raw) {
    final c = raw.replaceAll(_junk, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (_hex.hasMatch(c)) return c.toUpperCase();
    return _name.hasMatch(c) ? c : '';
  }

  /// Plain text, at most [modelMax] characters ('' when none).
  static String cleanModel(String raw) {
    final m = raw.replaceAll(_junk, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return m.length > modelMax ? m.substring(0, modelMax).trim() : m;
  }

  /// The message for the change from what the group sees ([me]) to the garage bike ([colour],
  /// [model]), or null when there is nothing to send: same values, no usable values, or the rider
  /// rides pillion (no bike of their own in this ride). A field without a usable value is left out,
  /// so the ride keeps what it has.
  ///
  /// 3.55 bike type: [kind] (a BikeType id, '' = not known) and [complete] (bike details complete)
  /// go along when they differ; the gateway needs a bike field with "complete", so the type is
  /// repeated when only "complete" changed.
  static Map<String, dynamic>? message({required RiderModel me, required String colour, required String model, String kind = '', bool? complete}) {
    if (me.isCoRiding || me.vehicleNo.trim().toUpperCase() == 'PILLION') return null;
    final c = cleanColour(colour);
    final m = cleanModel(model);
    final out = <String, dynamic>{'type': 'RIDER_VEHICLE'};
    if (c.isNotEmpty && c != me.vehicleColor) out['vehicleColor'] = c;
    if (m.isNotEmpty && m != me.vehicleModel) out['vehicleModel'] = m;
    if (kind.isNotEmpty && kind != me.vehicleKind) out['vehicleKind'] = kind;
    if (complete != null && complete != me.bikeComplete && kind.isNotEmpty) {
      out['vehicleKind'] = kind;
      out['bikeComplete'] = complete;
    }
    return out.length > 1 ? out : null;
  }

  /// How long to wait before the next send, given the last send at [lastSentAt].
  static Duration waitBeforeSend(DateTime? lastSentAt, DateTime now) {
    if (lastSentAt == null) return Duration.zero;
    final left = rateWindow - now.difference(lastSentAt);
    return left.isNegative ? Duration.zero : left;
  }

  /// Gateway refusals that will not change during this ride: stop sending until the next ride.
  /// (The admin switch is checked before sending, so FEATURE_OFF is not listed here: that reason is
  /// shared with other messages and must keep reaching the rider.)
  static bool isFinalRefusal(String? reason) => reason == 'BIKE_SWAPPED' || reason == 'PILLION_RIDER' || reason == 'BAD_VEHICLE';
}
