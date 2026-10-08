// Wire names for the 3.15 Rider Safety Network and Rider Discovery Network
// (shared by the app and the gateway, see gateway/src/safety_network.js and discovery.js).

String? _up(String? s) => s?.trim().toUpperCase();

/// Lifecycle of an emergency (the 3.14 SOS alert, extended). POSSIBLE_ACCIDENT is a
/// phone-only state (the crash alarm countdown) and never on the wire.
enum EmergencyStatus {
  confirmedAccident,
  assistanceRequested,
  responderAssigned,
  assistanceArrived,
  resolved,
  falseAlarm,
  cancelled,
  expired;

  String get wire => switch (this) {
        EmergencyStatus.confirmedAccident => 'CONFIRMED_ACCIDENT',
        EmergencyStatus.assistanceRequested => 'ASSISTANCE_REQUESTED',
        EmergencyStatus.responderAssigned => 'RESPONDER_ASSIGNED',
        EmergencyStatus.assistanceArrived => 'ASSISTANCE_ARRIVED',
        EmergencyStatus.resolved => 'RESOLVED',
        EmergencyStatus.falseAlarm => 'FALSE_ALARM',
        EmergencyStatus.cancelled => 'CANCELLED',
        EmergencyStatus.expired => 'EXPIRED',
      };

  /// Still needs attention (not resolved, false alarm, cancelled or expired).
  bool get isOpen => !isTerminal;

  bool get isTerminal => switch (this) {
        EmergencyStatus.resolved || EmergencyStatus.falseAlarm || EmergencyStatus.cancelled || EmergencyStatus.expired => true,
        _ => false,
      };

  static EmergencyStatus? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

/// Where an emergency came from.
enum EmergencySource {
  manual,
  crashAuto,
  needHelp,
  notification,
  memberReport,
  nearbyReport,
  wearable;

  String get wire => switch (this) {
        EmergencySource.manual => 'MANUAL',
        EmergencySource.crashAuto => 'CRASH_AUTO',
        EmergencySource.needHelp => 'NEED_HELP',
        EmergencySource.notification => 'NOTIFICATION',
        EmergencySource.memberReport => 'MEMBER_REPORT',
        EmergencySource.nearbyReport => 'NEARBY_REPORT',
        EmergencySource.wearable => 'WEARABLE',
      };

  static EmergencySource? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

enum EmergencySeverity {
  low,
  high,
  critical;

  String get wire => switch (this) {
        EmergencySeverity.low => 'LOW',
        EmergencySeverity.high => 'HIGH',
        EmergencySeverity.critical => 'CRITICAL',
      };

  static EmergencySeverity? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

/// Why the rider closes an SOS (SOS_RESOLVE reason).
enum ResolveReason {
  resolved,
  falseAlarm,
  cancelled;

  String get wire => switch (this) {
        ResolveReason.resolved => 'RESOLVED',
        ResolveReason.falseAlarm => 'FALSE_ALARM',
        ResolveReason.cancelled => 'CANCELLED',
      };

  static ResolveReason? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

/// A nearby rider's state for an assistance request.
enum ResponderStatus {
  requested,
  accepted,
  enRoute,
  arriving,
  arrived,
  unableToReach,
  cancelled,
  declined,
  timeout;

  String get wire => switch (this) {
        ResponderStatus.requested => 'REQUESTED',
        ResponderStatus.accepted => 'ACCEPTED',
        ResponderStatus.enRoute => 'EN_ROUTE',
        ResponderStatus.arriving => 'ARRIVING',
        ResponderStatus.arrived => 'ARRIVED',
        ResponderStatus.unableToReach => 'UNABLE_TO_REACH',
        ResponderStatus.cancelled => 'CANCELLED',
        ResponderStatus.declined => 'DECLINED',
        ResponderStatus.timeout => 'TIMEOUT',
      };

  /// Accepted and on the way (not yet arrived).
  bool get isGoing => this == ResponderStatus.accepted || this == ResponderStatus.enRoute || this == ResponderStatus.arriving;

  /// Helping: on the way or with the rider.
  bool get isActive => isGoing || this == ResponderStatus.arrived;

  static ResponderStatus? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

/// My answer to an assistance request (ASSIST_ANSWER).
enum AssistAnswer {
  accept,
  decline,
  cancel,
  unable,
  arrived,
  notFound;

  String get wire => switch (this) {
        AssistAnswer.accept => 'ACCEPT',
        AssistAnswer.decline => 'DECLINE',
        AssistAnswer.cancel => 'CANCEL',
        AssistAnswer.unable => 'UNABLE',
        AssistAnswer.arrived => 'ARRIVED',
        AssistAnswer.notFound => 'NOT_FOUND',
      };

  /// My state right after this answer (shown at once, before the server confirms).
  ResponderStatus get resultingStatus => switch (this) {
        AssistAnswer.accept => ResponderStatus.accepted,
        AssistAnswer.decline => ResponderStatus.declined,
        AssistAnswer.cancel => ResponderStatus.cancelled,
        AssistAnswer.unable => ResponderStatus.unableToReach,
        AssistAnswer.arrived => ResponderStatus.arrived,
        AssistAnswer.notFound => ResponderStatus.unableToReach,
      };

  static AssistAnswer? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

/// How the search for nearby riders is going (shown to the rider's own group).
enum NetworkState {
  off,
  searching,
  requested,
  assigned,
  noneFound;

  String get wire => switch (this) {
        NetworkState.off => 'OFF',
        NetworkState.searching => 'SEARCHING',
        NetworkState.requested => 'REQUESTED',
        NetworkState.assigned => 'ASSIGNED',
        NetworkState.noneFound => 'NONE_FOUND',
      };

  static NetworkState? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

/// Accident warning level for riders approaching it.
enum HazardLevel {
  active,
  responderArriving,
  onScene;

  String get wire => switch (this) {
        HazardLevel.active => 'ACTIVE',
        HazardLevel.responderArriving => 'RESPONDER_ARRIVING',
        HazardLevel.onScene => 'ON_SCENE',
      };

  static HazardLevel? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

/// How two public groups meet.
enum EncounterType {
  sameDirection,
  oppositeDirection,
  converging,
  crossing;

  String get wire => switch (this) {
        EncounterType.sameDirection => 'SAME_DIRECTION',
        EncounterType.oppositeDirection => 'OPPOSITE_DIRECTION',
        EncounterType.converging => 'CONVERGING',
        EncounterType.crossing => 'CROSSING',
      };

  static EncounterType? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

/// Why an assistance request ended for me (ASSIST_CLOSED).
enum AssistClosedReason {
  taken,
  resolved,
  falseAlarm,
  cancelled,
  expired,
  timeout;

  String get wire => switch (this) {
        AssistClosedReason.taken => 'TAKEN',
        AssistClosedReason.resolved => 'RESOLVED',
        AssistClosedReason.falseAlarm => 'FALSE_ALARM',
        AssistClosedReason.cancelled => 'CANCELLED',
        AssistClosedReason.expired => 'EXPIRED',
        AssistClosedReason.timeout => 'TIMEOUT',
      };

  static AssistClosedReason? fromWire(String? s) {
    final u = _up(s);
    for (final v in values) {
      if (v.wire == u) return v;
    }
    return null;
  }
}

/// Whether other public groups may discover this group (SOCIAL network only; safety never depends on it).
enum GroupVisibility {
  private,
  public;

  String get wire => switch (this) {
        GroupVisibility.private => 'PRIVATE',
        GroupVisibility.public => 'PUBLIC',
      };

  /// Anything unknown is private (the default).
  static GroupVisibility fromWire(String? s) => _up(s) == 'PUBLIC' ? GroupVisibility.public : GroupVisibility.private;
}
