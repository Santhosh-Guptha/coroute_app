// v3.58 Home: one calm nudge strip for safety set-up that is still missing. Pure Dart (tool/pure_dart_test).
//
// Rules:
//  * Only missing items are candidates; the most important one is shown (order of [SafetyNudge.values]).
//  * "x" snoozes that item for [snooze]; the next missing one takes its place at once.
//  * A snoozed item comes back when the snooze ends and it is still missing.
//  * Nothing at all while a ride or an SOS is running (the cockpit owns the screen then).
library;

/// Most important first.
enum SafetyNudge { emergencyContact, crashDetection, medicalId, nearbyDevices }

extension SafetyNudgeText on SafetyNudge {
  String get key => switch (this) {
        SafetyNudge.emergencyContact => 'emergency_contact',
        SafetyNudge.crashDetection => 'crash_detection',
        SafetyNudge.medicalId => 'medical_id',
        SafetyNudge.nearbyDevices => 'nearby_devices',
      };

  /// One short line, our own words.
  String get line => switch (this) {
        SafetyNudge.emergencyContact => 'Add an emergency contact. SOS texts them first.',
        SafetyNudge.crashDetection => 'Crash detection is off. Turn it on before you ride.',
        SafetyNudge.medicalId => 'Add your Medical ID for responders.',
        SafetyNudge.nearbyDevices => 'Allow Nearby devices for SOS without signal.',
      };

  String get action => switch (this) {
        SafetyNudge.emergencyContact => 'Add',
        SafetyNudge.crashDetection => 'Turn on',
        SafetyNudge.medicalId => 'Add',
        SafetyNudge.nearbyDevices => 'Allow',
      };
}

/// What this phone knows about the rider's safety set-up.
class SafetySetup {
  final bool hasEmergencyContact;
  final bool crashDetectionOn;
  final bool hasMedicalId;

  /// Granted, or not a runtime permission on this phone (Android 11 and older, iOS).
  final bool nearbyDevicesOk;

  const SafetySetup({
    this.hasEmergencyContact = true,
    this.crashDetectionOn = true,
    this.hasMedicalId = true,
    this.nearbyDevicesOk = true,
  });

  List<SafetyNudge> get missing => [
        if (!hasEmergencyContact) SafetyNudge.emergencyContact,
        if (!crashDetectionOn) SafetyNudge.crashDetection,
        if (!hasMedicalId) SafetyNudge.medicalId,
        if (!nearbyDevicesOk) SafetyNudge.nearbyDevices,
      ];
}

class NudgeRotation {
  NudgeRotation._();

  static const Duration snooze = Duration(days: 3);

  /// The nudge to show now, or null. [dismissedAt]: nudge key -> epoch ms of its last "x".
  static SafetyNudge? pick(
    SafetySetup setup, {
    required Map<String, int> dismissedAt,
    required int nowMs,
    bool riding = false,
    Duration snoozeFor = snooze,
  }) {
    if (riding) return null;
    for (final n in setup.missing) {
      final at = dismissedAt[n.key];
      if (at == null || nowMs - at >= snoozeFor.inMilliseconds || nowMs < at) return n;
    }
    return null;
  }

  /// The map after the rider dismissed [n] at [nowMs]; entries of items that are no longer missing are dropped,
  /// so an item that goes missing again later is shown at once.
  static Map<String, int> dismiss(Map<String, int> dismissedAt, SafetyNudge n, int nowMs, SafetySetup setup) {
    final keep = {for (final m in setup.missing) m.key};
    return {
      for (final e in dismissedAt.entries)
        if (keep.contains(e.key)) e.key: e.value,
      n.key: nowMs,
    };
  }
}
