// SOS battery reserve (3.55, switch 'sosBatteryReserve'): below 10% battery during a ride the
// phone keeps what is left for SOS and crash detection, and tells the group and guardians where
// the rider is while it still can.
//
// One controller, [SosBatteryReserve.shared]; other features ask [SosBatteryReserve.isActive]
// and pause their non-safety work (place review prompts, heritage notices, hands-free group
// talk, the stops-on-the-way network refresh). On switch-on, once per ride:
//  * map tile downloads / prefetch stop (TilePrefetcher low-battery pause);
//  * hands-free group talk (VOX open mic) goes back to push-to-talk;
//  * one last-location update goes to the group (the existing LAST_GASP_BEACON message: the
//    gateway marks the rider BATTERY_SHUTDOWN, fans out RIDER_BATTERY_SHUTDOWN to the group,
//    and the rider's state with the last position is what Ride Guardian links show);
//  * the cockpit shows "Battery saver for SOS is on".
// GPS is already in its gentle low-battery cadence below 20% (ConvoyService battery policy,
// LocationCadence lowBattery) and stays so. SOS, crash detection and emergency texts are never
// paused by this controller.
import 'package:flutter/foundation.dart';

import '../../domain/safety/sos_battery_reserve_policy.dart';
import 'convoy_service.dart';
import 'intercom_service.dart';
import 'realtime_service.dart';
import 'tile_cache_service.dart';

/// The inputs the controller reads on every update (a fake in tests).
class SosReserveInputs {
  final int batteryPercent;
  final bool charging;
  final bool rideActive;

  /// The ride's group id (the last-location update goes out once per ride).
  final String? rideKey;
  final double lat;
  final double lng;
  final double speedKmh;

  const SosReserveInputs({
    required this.batteryPercent,
    required this.charging,
    required this.rideActive,
    this.rideKey,
    this.lat = 0,
    this.lng = 0,
    this.speedKmh = 0,
  });
}

class SosBatteryReserve extends ChangeNotifier {
  SosBatteryReserve({SosBatteryReservePolicy? policy}) : _policy = policy ?? SosBatteryReservePolicy();

  /// The one controller of the app (main.dart feeds it from ConvoyService).
  static final SosBatteryReserve shared = SosBatteryReserve();

  /// True while the reserve is on (any feature may ask; false when nothing feeds it).
  static bool get isActive => shared.active;

  final SosBatteryReservePolicy _policy;

  /// 3.55 admin switch 'sosBatteryReserve' (null = on). Off: never switches on.
  bool Function(String id)? featureOn;

  /// Sends the last-location update (true when it went out). main.dart: RealtimeService.send.
  bool Function(Map<String, dynamic> message)? sendMessage;

  /// Stops heavy work (tile prefetch, hands-free talk). Called with true on entry, false on exit.
  void Function(bool on)? onHeavyWorkPause;

  bool _cardDismissed = false;
  bool _beaconSent = false;

  bool get active => _policy.active;

  /// The last-location update went out during this activation.
  bool get beaconSent => _beaconSent;

  /// The cockpit card: shown while active until dismissed.
  bool get showCard => active && !_cardDismissed;

  static const String cardTitle = 'Battery saver for SOS is on';
  static const String cardMessage = 'Map downloads and extras are paused so SOS and crash detection keep working. '
      'Your group got your last location.';
  static const String cardMessageNotSent = 'Map downloads and extras are paused so SOS and crash detection keep working.';

  void dismissCard() {
    if (_cardDismissed) return;
    _cardDismissed = true;
    notifyListeners();
  }

  /// One look at the battery and ride state. Returns what changed.
  SosReserveChange update(SosReserveInputs i) {
    final on = featureOn?.call('sosBatteryReserve') ?? true;
    final change = _policy.update(
      percent: i.batteryPercent,
      charging: i.charging,
      rideActive: i.rideActive && on,
    );
    if (change == SosReserveChange.entered) {
      _cardDismissed = false;
      _beaconSent = false;
      try {
        onHeavyWorkPause?.call(true);
      } catch (_) {}
    } else if (change == SosReserveChange.exited) {
      try {
        onHeavyWorkPause?.call(false);
      } catch (_) {}
    }
    if (active && !_beaconSent) _trySendBeacon(i);
    if (change != SosReserveChange.none) notifyListeners();
    return change;
  }

  void _trySendBeacon(SosReserveInputs i) {
    final key = i.rideKey;
    final send = sendMessage;
    if (key == null || send == null || (i.lat == 0 && i.lng == 0)) return; // no position yet: next update
    if (!_policy.claimBeacon(key)) {
      _beaconSent = true; // already sent for this ride
      return;
    }
    var ok = false;
    try {
      ok = send(beaconMessage(i));
    } catch (_) {
      ok = false;
    }
    if (ok) {
      _beaconSent = true;
      notifyListeners();
    } else {
      // Not sent (no connection): the policy forgets the claim so the next update tries again.
      _policy.releaseBeacon(key);
    }
  }

  /// The last-location message (the gateway's LAST_GASP_BEACON; levels only, no sensor data).
  static Map<String, dynamic> beaconMessage(SosReserveInputs i) => {
        'type': 'LAST_GASP_BEACON',
        'lat': double.parse(i.lat.toStringAsFixed(6)),
        'lng': double.parse(i.lng.toStringAsFixed(6)),
        'speedKmh': double.parse(i.speedKmh.toStringAsFixed(1)),
        'batteryLevel': i.batteryPercent.clamp(0, 100),
        'reason': 'SOS_BATTERY_RESERVE',
      };

  @visibleForTesting
  void resetForTest() {
    _policy.reset();
    _cardDismissed = false;
    _beaconSent = false;
  }
}

/// Feeds [SosBatteryReserve.shared] from the ride (main.dart): the battery level and charging
/// state ConvoyService already reads every minute, the ride state and my last position. Applies
/// the heavy-work pause (tile prefetch, hands-free group talk) and sends the last location over
/// the existing realtime connection.
class SosBatteryReserveBinding {
  SosBatteryReserveBinding(
    this._convoys, {
    required RealtimeService realtime,
    TilePrefetcher? tiles,
    IntercomService? intercom,
    SosBatteryReserve? reserve,
  }) : reserve = reserve ?? SosBatteryReserve.shared {
    this.reserve.sendMessage = realtime.send;
    this.reserve.onHeavyWorkPause = (on) {
      if (on) {
        tiles?.handleLowBattery(true);
        if (intercom != null && intercom.isVoxArmed) intercom.disableHandsFree().ignore();
      } else {
        // Back to what the ride's own battery policy wants (paused below 20% or with the saver on).
        tiles?.handleLowBattery(_convoys.batterySaverActive);
      }
    };
    _convoys.addListener(_update);
    _update();
  }

  final ConvoyService _convoys;
  final SosBatteryReserve reserve;
  bool _disposed = false;

  void _update() {
    if (_disposed) return;
    final c = _convoys.activeConvoy;
    final uid = _convoys.myUserId;
    final me = uid == null ? null : c?.riders[uid];
    reserve.update(SosReserveInputs(
      batteryPercent: _convoys.currentBatteryLevel,
      charging: _convoys.isCharging,
      rideActive: c != null && c.tripStatus != 'ENDED',
      rideKey: c?.groupId,
      lat: me?.lat ?? 0,
      lng: me?.lng ?? 0,
      speedKmh: me?.speedKmh ?? 0,
    ));
  }

  void dispose() {
    _disposed = true;
    _convoys.removeListener(_update);
  }
}
