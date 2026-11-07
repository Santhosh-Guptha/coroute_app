// SOS battery reserve (3.55): below 10% battery during a ride, the phone keeps what is left for
// SOS and crash detection. Pure hysteresis and "send the last location once" rules; the
// controller (lib/data/services/sos_battery_reserve.dart) applies them.
//
//  * on: a ride is active, the phone is not charging and the battery is below [enterBelow] (10%);
//  * off: charging, the battery back at [exitAtOrAbove] (15%) or more, or the ride ended. The gap
//    between 10% and 15% keeps it from flapping on a battery reading that jumps by a percent;
//  * the last-location update goes out once per ride (per group id), on the first switch-on.

/// What changed on an update.
enum SosReserveChange { none, entered, exited }

class SosBatteryReservePolicy {
  SosBatteryReservePolicy({this.enterBelow = 10, this.exitAtOrAbove = 15});

  final int enterBelow;
  final int exitAtOrAbove;

  bool _active = false;
  String? _beaconFor;

  bool get active => _active;

  SosReserveChange update({required int percent, required bool charging, required bool rideActive}) {
    final valid = percent >= 0 && percent <= 100;
    if (_active) {
      if (!rideActive || charging || (valid && percent >= exitAtOrAbove)) {
        _active = false;
        return SosReserveChange.exited;
      }
      return SosReserveChange.none;
    }
    if (rideActive && !charging && valid && percent < enterBelow) {
      _active = true;
      return SosReserveChange.entered;
    }
    return SosReserveChange.none;
  }

  /// True once per ride: the caller sends the last-location update now.
  bool claimBeacon(String rideKey) {
    if (!_active || _beaconFor == rideKey) return false;
    _beaconFor = rideKey;
    return true;
  }

  /// The update could not be sent: the next update may claim it again.
  void releaseBeacon(String rideKey) {
    if (_beaconFor == rideKey) _beaconFor = null;
  }

  void reset() {
    _active = false;
    _beaconFor = null;
  }
}
