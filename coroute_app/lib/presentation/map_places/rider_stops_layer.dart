import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/intel/hazard_ahead.dart';

/// 3.56 (round 6): "Where riders stop" on the LIVE riding map. The trip planner always shows the
/// learned, k-anonymous rider stops along a route; on the ride map they are OFF by default (a clear
/// map while riding) and switched on in the "Places on map" sheet. The choice is kept on the phone.
class RiderStopsLivePref {
  RiderStopsLivePref._();

  static const String prefKey = 'map_rider_stops_live_v1';

  /// At most this many markers on the ride map (nearest cells first as cached).
  static const int maxMarkers = 40;

  static final ValueNotifier<bool> on = ValueNotifier<bool>(false);
  static bool _loaded = false;

  /// Reads the saved choice once (off when nothing is saved or storage fails).
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      on.value = (await SharedPreferences.getInstance()).getBool(prefKey) ?? false;
    } catch (_) {
      on.value = false;
    }
  }

  static Future<void> set(bool value) async {
    on.value = value;
    try {
      await (await SharedPreferences.getInstance()).setBool(prefKey, value);
    } catch (_) {}
  }

  /// Shown only when switched on and no alert is open (an SOS / crash keeps the map for the emergency).
  static bool show({required bool switchedOn, required bool alertOpen}) => switchedOn && !alertOpen;

  @visibleForTesting
  static void resetForTest() {
    _loaded = false;
    on.value = false;
  }
}

/// The markers of the learned rider stops (same look as on the trip planner).
List<Marker> riderStopMarkers(Iterable<IntelCell> stops, {int max = RiderStopsLivePref.maxMarkers}) => [
      for (final st in stops.take(max))
        Marker(
          point: LatLng(st.lat, st.lng),
          width: 26,
          height: 26,
          child: Semantics(
            label: 'Where riders stop${st.name.isEmpty ? '' : ': ${st.name}'}',
            child: Container(
              decoration: BoxDecoration(color: AppTheme.card, shape: BoxShape.circle, border: Border.all(color: AppTheme.accent, width: 2)),
              child: Icon(st.fuel ? Icons.local_gas_station_rounded : Icons.coffee_rounded, size: 14, color: AppTheme.accent),
            ),
          ),
        ),
    ];
