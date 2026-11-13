// Android 12+ "Nearby devices" (BLUETOOTH_SCAN + BLUETOOTH_ADVERTISE + BLUETOOTH_CONNECT): pure state and
// rules, no platform code (pure Dart tests import this). The platform side is nearby_permission.dart.
library;

/// Where the "Nearby devices" permission stands on this phone.
enum NearbyAccess {
  /// Not a runtime permission here (Android 11 and older, iOS, desktop): nothing to ask.
  notNeeded,

  /// All three are granted.
  granted,

  /// At least one is missing; asking again can still show the system prompt.
  denied,

  /// At least one is missing and Android will not ask again: only app settings can change it.
  permanentlyDenied,
}

class NearbyPolicy {
  NearbyPolicy._();

  /// Android 12 (API 31) made Bluetooth scan / advertise / connect a runtime "Nearby devices" permission.
  static const int minSdk = 31;

  /// True when the "Nearby devices" permission exists on this phone (Android, SDK 31+).
  static bool applies({required bool android, required int sdk}) => android && sdk >= minSdk;

  /// Combines the three permissions into one [NearbyAccess].
  static NearbyAccess combine({
    required bool android,
    required int sdk,
    required bool scan,
    required bool advertise,
    required bool connect,
    bool anyPermanentlyDenied = false,
  }) {
    if (!applies(android: android, sdk: sdk)) return NearbyAccess.notNeeded;
    if (scan && advertise && connect) return NearbyAccess.granted;
    return anyPermanentlyDenied ? NearbyAccess.permanentlyDenied : NearbyAccess.denied;
  }

  /// Nothing more to do: granted, or not a runtime permission here.
  static bool satisfied(NearbyAccess a) => a == NearbyAccess.granted || a == NearbyAccess.notNeeded;

  /// Whether an automatic (not rider-initiated) prompt may be shown: only once ever, and never when it
  /// would change nothing. A rider tapping a button always gets the prompt (or app settings).
  static bool mayAutoPrompt(NearbyAccess a, {required bool askedBefore}) => a == NearbyAccess.denied && !askedBefore;
}
