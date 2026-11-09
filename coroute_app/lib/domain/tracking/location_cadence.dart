import 'dart:math' as math;

import 'nav_motion.dart';

/// Speed bands for the GPS cadence (km/h): stopped / walking pace (< 10),
/// town (10-40), open road (40-80), highway (> 80).
enum SpeedBand { stopped, city, road, highway }

/// How precise the platform should try to be (mapped to geolocator's
/// `LocationAccuracy` by the service; kept plugin-free here for tests).
enum GpsPrecision { low, medium, high, navigation }

/// One GPS subscription: minimum time and distance between updates.
class CadencePlan {
  final int intervalMs;
  final int distanceFilterM;
  final GpsPrecision precision;

  const CadencePlan(this.intervalMs, this.distanceFilterM, this.precision);

  Duration get interval => Duration(milliseconds: intervalMs);

  @override
  bool operator ==(Object other) =>
      other is CadencePlan &&
      other.intervalMs == intervalMs &&
      other.distanceFilterM == distanceFilterM &&
      other.precision == precision;

  @override
  int get hashCode => Object.hash(intervalMs, distanceFilterM, precision);

  @override
  String toString() => 'CadencePlan(${intervalMs}ms, ${distanceFilterM}m, $precision)';
}

/// Speed-adaptive location cadence: the faster the ride, the more often the
/// phone reports (so the map and the group's markers stay smooth), relaxed
/// on low battery, parked (idle) and in data saver. Pure; see
/// `test/location_cadence_test.dart`.
class LocationCadence {
  LocationCadence._();

  /// Moving, normal battery: stopped / walking pace 2 s, town and open road 1 s, highway 500 ms
  /// (navigation-grade fixes). No distance filter during a ride: the speed readout and the
  /// overspeed check need a fix every interval, and with a distance filter the last fix before a
  /// stop (often 5-8 km/h) stayed on screen while parked. (The filter saves no GNSS power: the
  /// chip runs anyway; it only dropped updates.)
  static const Map<SpeedBand, CadencePlan> normal = {
    SpeedBand.stopped: CadencePlan(2000, 0, GpsPrecision.high),
    SpeedBand.city: CadencePlan(1000, 0, GpsPrecision.navigation),
    SpeedBand.road: CadencePlan(1000, 0, GpsPrecision.navigation),
    SpeedBand.highway: CadencePlan(500, 0, GpsPrecision.navigation),
  };

  /// Moving, low battery: one step gentler everywhere, never navigation grade, and never slower
  /// than one fix every 2 s once moving (speed readout and overspeed check stay usable).
  static const Map<SpeedBand, CadencePlan> lowBattery = {
    SpeedBand.stopped: CadencePlan(4000, 0, GpsPrecision.medium),
    SpeedBand.city: CadencePlan(2000, 0, GpsPrecision.high),
    SpeedBand.road: CadencePlan(2000, 0, GpsPrecision.high),
    SpeedBand.highway: CadencePlan(1000, 0, GpsPrecision.high),
  };

  /// Parked for a while (the stream is nearly silent; a heartbeat keeps "last seen" fresh).
  static const CadencePlan idle = CadencePlan(20000, 25, GpsPrecision.medium);
  static const CadencePlan idleLowBattery = CadencePlan(45000, 40, GpsPrecision.low);

  static CadencePlan plan(SpeedBand band, {required bool idle, bool lowBattery = false}) {
    if (idle) return lowBattery ? LocationCadence.idleLowBattery : LocationCadence.idle;
    return (lowBattery ? LocationCadence.lowBattery : normal)[band]!;
  }

  /// The gateway drops more than 3 TELEMETRY messages a second per socket;
  /// never plan to get anywhere near that.
  static const int telemetryFloorMs = 1000;

  /// Telemetry push interval for [band]. [base] is the existing battery /
  /// data policy (2.5 s moving, 30 s parked, 5 s data saver): faster bands may
  /// go below it (town 2 s, open road 1.5 s, highway 1 s), never in data saver
  /// or while parked, and big groups are held back because every update is
  /// fanned out to every rider (> 25 riders: 2 s, > 50: 2.5 s).
  static Duration telemetryInterval(
    SpeedBand band, {
    required Duration base,
    required bool moving,
    bool lowData = false,
    int groupSize = 1,
  }) {
    final baseMs = base.inMilliseconds;
    if (!moving || lowData) return base;
    final bandMs = switch (band) {
      SpeedBand.stopped => baseMs,
      SpeedBand.city => 2000,
      SpeedBand.road => 1500,
      SpeedBand.highway => 1000,
    };
    final groupFloor = groupSize > 50 ? 2500 : (groupSize > 25 ? 2000 : telemetryFloorMs);
    final ms = math.max(math.max(groupFloor, telemetryFloorMs), math.min(baseMs, bandMs));
    return Duration(milliseconds: ms);
  }
}

/// Tracks the current [SpeedBand] with hysteresis: up at 10 / 40 / 80 km/h
/// (+1) after 2 s, down at 6 / 36 / 76 km/h (-4) after 6 s, so a speed
/// hovering at a boundary never re-subscribes the GPS stream over and over.
class SpeedBandTracker {
  SpeedBandTracker({int upDwellMs = 2000, int downDwellMs = 6000})
      : _bands = BandSelector(
          thresholds: const [10.0, 40.0, 80.0],
          marginUp: 1.0,
          marginDown: 4.0,
          upDwellMs: upDwellMs,
          downDwellMs: downDwellMs,
        );

  final BandSelector _bands;

  SpeedBand get band => SpeedBand.values[_bands.level];

  /// Feeds a speed sample; returns true when the band changed.
  bool update(double speedKmh, int nowMs) {
    final before = _bands.level;
    return _bands.update(speedKmh, nowMs) != before;
  }

  void reset([SpeedBand band = SpeedBand.stopped]) => _bands.reset(band.index);
}
