// 3.55 platform: the on-phone incident record (CrashIncident / IncidentStatus) and its durable
// queue were retired; the pending-SOS store is the offline crash record. Detector enums stay here.

/// Motorcycle crash pattern scenarios recognized by Phase 2 detection.
enum CrashScenario {
  highImpactCollision,
  lowsideSlide,
  highsideFall,
  stationaryDrop,
  impactWithStillness,
  unknown;

  String get wireName {
    switch (this) {
      case CrashScenario.highImpactCollision:
        return 'HIGH_IMPACT_COLLISION';
      case CrashScenario.lowsideSlide:
        return 'LOWSIDE_SLIDE';
      case CrashScenario.highsideFall:
        return 'HIGHSIDE_FALL';
      case CrashScenario.stationaryDrop:
        return 'STATIONARY_DROP';
      case CrashScenario.impactWithStillness:
        return 'IMPACT_WITH_STILLNESS';
      case CrashScenario.unknown:
        return 'UNKNOWN';
    }
  }

  static CrashScenario fromWire(String? wire) {
    switch (wire?.toUpperCase()) {
      case 'HIGH_IMPACT_COLLISION':
        return CrashScenario.highImpactCollision;
      case 'LOWSIDE_SLIDE':
        return CrashScenario.lowsideSlide;
      case 'HIGHSIDE_FALL':
        return CrashScenario.highsideFall;
      case 'STATIONARY_DROP':
        return CrashScenario.stationaryDrop;
      case 'IMPACT_WITH_STILLNESS':
        return CrashScenario.impactWithStillness;
      default:
        return CrashScenario.unknown;
    }
  }
}

/// Movement state of rider and motorcycle.
enum MovementState {
  moving,
  stopped,
  unknown,
  degraded;

  String get wireName => name.toUpperCase();

  static MovementState fromWire(String? wire) {
    switch (wire?.toUpperCase()) {
      case 'MOVING':
        return MovementState.moving;
      case 'STOPPED':
        return MovementState.stopped;
      case 'DEGRADED':
        return MovementState.degraded;
      case 'UNKNOWN':
      default:
        return MovementState.unknown;
    }
  }
}
