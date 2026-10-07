/// Thresholds that turn raw rider signals into a plain status
/// (see `RiderStatus.fromSignals` in `lib/core/ui/rider_status.dart`),
/// plus the SOS hold time. One place, so every screen agrees.
class RideThresholds {
  RideThresholds._();

  /// No position update for this long: the rider shows as "Disconnected"
  /// (recently heard from, updates have stopped).
  static const Duration staleAfter = Duration(seconds: 60);

  /// No position update for this long: the rider shows as "Offline".
  /// Same as the "no signal" rule of the status notification.
  static const Duration offlineAfter = Duration(minutes: 2);

  /// GPS accuracy worse (larger) than this, in metres: "Low GPS".
  static const double lowGpsAccuracyM = 50;

  /// At or above this speed (km/h) the rider counts as riding. Below it,
  /// GPS jitter at a standstill is not mistaken for movement.
  static const double movingSpeedKmh = 5;

  /// Stopped for at least this long: shown as "Resting" instead of "Stopped".
  static const Duration restingAfter = Duration(minutes: 10);

  /// How long the SOS button must be held before the SOS is raised.
  static const Duration sosHold = Duration(milliseconds: 1500);
}
