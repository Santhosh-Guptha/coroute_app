import 'convoy_service.dart';
import 'safety_service.dart';
import 'settings_service.dart';

/// Binds sharing to the existing telemetry lifecycle, including opt-out and
/// explicit refuelling. Disposed with the providers; no extra timer or GPS.
class FuelSharingBinding {
  FuelSharingBinding(this.convoys, this.settings, this.safety) {
    convoys.fuelEstimate = _estimate;
    settings.addListener(_onChange);
    safety.addListener(_onChange);
    _last = _stamp();
  }
  final ConvoyService convoys;
  final SettingsService settings;
  final SafetyService safety;
  String? _last;
  Map<String, dynamic>? _estimate() {
    final range = safety.estimatedUsableKm;
    if (!settings.shareFuelEstimate || range == null || !range.isFinite || safety.fuelEstimateUncertain || safety.fuelConfirmedAt <= 0) return null;
    return {'usableKm': range.floor(), 'confirmedAt': safety.fuelConfirmedAt};
  }
  String _stamp() => _estimate().toString();
  void _onChange() {
    final stamp = _stamp();
    if (_last == stamp) return;
    _last = stamp;
    convoys.refreshFuelSharing();
  }
  void dispose() {
    settings.removeListener(_onChange);
    safety.removeListener(_onChange);
    convoys.fuelEstimate = null;
  }
}
