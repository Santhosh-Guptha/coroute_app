/// The feature gating map of CoRoute, plans v2.
///
/// Plans: Community (free forever, every rider has it: SOLO rides), Small Group 2–6 and Large
/// Group 7–12 (paid: host a group). No feature is sold on its own. What a plan changes is whether
/// the rider's OWN rides are solo or group, and how many riders the host may bring: that lives in
/// [PlanAccess] (membership_model.dart) and is decided by the gateway (a Community ride has one
/// seat: 409 SOLO_TRIP_ONLY to join it, 403 SOLO_RIDE for talk / messages / regroup / roles in it;
/// 409 CONVOY_FULL past a group host's seats).
///
///  * [FeatureAccess.safety]: never paywalled, in every ride, with any plan.
///  * [FeatureAccess.groupRide]: comes with a GROUP ride; inside one every rider has it (also a
///    Community rider who joined), because the host's group plan pays for the group. Not in a
///    solo ride ([availableInRide]).
///  * [FeatureAccess.personal]: free personal tools.
enum FeatureAccess { safety, groupRide, personal }

enum Feature {
  /// Priority audio channel that ducks background chatter when the ride lead speaks.
  priorityIntercomDucking,

  /// Corridor offline map tile downloads.
  unlimitedOfflinePacks,

  /// Scoped browser-based live tracking web link for family ("Ride Guardian").
  guardianLiveShare,

  /// Mid-ride waypoint and regroup stop push to all connected convoy maps.
  dynamicWaypointPush,

  /// Total convoy spread (Lead-to-Sweeper distance) stringing-out warnings.
  totalConvoySpreadAlert,

  /// Lean angle, G-force curves, and high-res telemetry GPX exporter.
  advancedTelemetryReplay,

  /// Multiple bike profiles with dynamic fuel consumption & service logs.
  multiBikeGarage,

  /// High-contrast AMOLED outdoor sunlight theme.
  sunlightHudMode,

  /// Collective road hazard broadcast to the riders behind.
  roadHazardBroadcast,

  /// Road hazard reception and helmet audio warnings.
  roadHazardReceive,

  /// Emergency siren acoustic frequency detector & audio ducking.
  sirenAcousticDetector,

  /// BLE handlebar wireless remote for hands-free PTT, tactical signals, and SOS.
  bleHandlebarRemote,

  /// Smartwatch biometric trauma & pulse verification for crash escalation.
  biometricTraumaPulse,

  /// Low-connectivity SOS & satellite emergency relay.
  satelliteSosRelay,

  /// Hands-free helmet Bluetooth intercom voice safety hotwords.
  voiceSafetyHotwords,

  /// Peer-to-Peer Bluetooth & Wi-Fi offline convoy mesh networking.
  p2pOfflineMesh,

  /// Smart airbag vest BLE bridge for instantaneous crash escalation.
  smartAirbagVest,
}

class FeatureGates {
  FeatureGates._();

  /// Which kind of feature [feature] is (see the map above).
  static FeatureAccess accessOf(Feature feature) {
    switch (feature) {
      case Feature.guardianLiveShare:
      case Feature.roadHazardReceive:
      case Feature.sirenAcousticDetector:
      case Feature.bleHandlebarRemote:
      case Feature.biometricTraumaPulse:
      case Feature.satelliteSosRelay:
      case Feature.voiceSafetyHotwords:
      case Feature.smartAirbagVest:
      case Feature.p2pOfflineMesh:
        return FeatureAccess.safety;
      case Feature.priorityIntercomDucking:
      case Feature.dynamicWaypointPush:
      case Feature.totalConvoySpreadAlert:
      case Feature.roadHazardBroadcast:
        return FeatureAccess.groupRide;
      case Feature.unlimitedOfflinePacks:
      case Feature.advancedTelemetryReplay:
      case Feature.multiBikeGarage:
      case Feature.sunlightHudMode:
        return FeatureAccess.personal;
    }
  }

  /// True for every rider: safety and personal features are free, and group features come with
  /// the ride itself (the gateway admits riders up to the host's seats). Plans never lock a feature.
  static bool isUnlocked(Feature feature) => true;

  /// In a ride: group-ride features only in a group ride; safety and personal features always.
  /// [soloRide] is `ConvoyModel.isSoloRide` (the host rides on Community).
  static bool availableInRide(Feature feature, {required bool soloRide}) =>
      !soloRide || accessOf(feature) != FeatureAccess.groupRide;

  /// Human-friendly feature display name.
  static String featureName(Feature feature) {
    switch (feature) {
      case Feature.priorityIntercomDucking:
        return 'Priority Intercom Voice Ducking (-18 dB)';
      case Feature.dynamicWaypointPush:
        return 'Mid-Ride Waypoint & Regroup Dispatch';
      case Feature.totalConvoySpreadAlert:
        return 'Total Convoy Spread Alerts';
      case Feature.guardianLiveShare:
        return 'Ride Guardian Encrypted Live Share';
      case Feature.unlimitedOfflinePacks:
        return 'Corridor Offline Map Packs';
      case Feature.advancedTelemetryReplay:
        return '2D Route Replay & GPX Telemetry Export';
      case Feature.multiBikeGarage:
        return 'Multi-Bike Motorcycle Garage';
      case Feature.sunlightHudMode:
        return 'AMOLED Sunlight HUD High-Contrast';
      case Feature.roadHazardBroadcast:
        return 'Road Hazard Telemetry Mesh Broadcast';
      case Feature.roadHazardReceive:
        return 'Road Hazard Helmet Audio Alerts & HUD';
      case Feature.sirenAcousticDetector:
        return 'Emergency Siren Acoustic Frequency Detector';
      case Feature.bleHandlebarRemote:
        return 'BLE Handlebar Wireless Remote & PTT';
      case Feature.biometricTraumaPulse:
        return 'Smartwatch Biometric Trauma & Pulse Verification';
      case Feature.satelliteSosRelay:
        return 'Low-Connectivity SOS & Satellite Relay';
      case Feature.voiceSafetyHotwords:
        return 'Helmet Intercom Voice Safety Hotwords';
      case Feature.p2pOfflineMesh:
        return 'Peer-to-Peer Bluetooth Offline Convoy Mesh';
      case Feature.smartAirbagVest:
        return 'Smart Airbag Vest BLE Peripheral Bridge';
    }
  }

  /// Human-friendly description of the feature.
  static String featureDescription(Feature feature) {
    switch (feature) {
      case Feature.voiceSafetyHotwords:
        return 'Hands-free voice recognition recognizing "CoRoute I\'m OK", "CoRoute SOS", "CoRoute Fuel", and "CoRoute Regroup" through helmet microphone in noisy riding conditions.';
      case Feature.p2pOfflineMesh:
        return 'Direct peer-to-peer wireless mesh connecting convoy bikes without cellular coverage, synchronizing telemetry, relative positions, and emergency distress beacons.';
      case Feature.smartAirbagVest:
        return 'Multi-brand Bluetooth Low Energy bridge for In&motion, Alpinestars Tech-Air, Helite, and Dainese D-air airbag vests with sub-150ms crash escalation.';
      case Feature.satelliteSosRelay:
        return 'Relays 16-byte emergency SOS distress packets via native OS satellite assistant, cellular ERSS 112, or connected satellite communicators when in deep dead zones.';
      case Feature.biometricTraumaPulse:
        return 'Connects Apple Watch, WearOS, or BLE heart rate sensors to verify rider pulse during crashes and escalate emergency dispatch for acute trauma.';
      case Feature.bleHandlebarRemote:
        return 'Hands-on-handlebar wireless remote control for push-to-talk intercom, tactical hazard signals, and emergency SOS trigger.';
      case Feature.sirenAcousticDetector:
        return 'Detects approaching emergency vehicle sirens, ducks music/intercom by -20 dB, and displays a pulsating cockpit yield alert.';
      case Feature.roadHazardBroadcast:
        return 'Broadcasts severe potholes and road defects detected by your bike to all following riders in the convoy.';
      case Feature.roadHazardReceive:
        return 'Delivers spatial helmet voice warnings and HUD alerts 300 meters before upcoming road hazards.';
      case Feature.priorityIntercomDucking:
        return 'Hazard warnings lower background chatter by 18 dB so they cut through instantly.';
      case Feature.dynamicWaypointPush:
        return 'Push route changes, fuel stops, and rest regroup waypoints dynamically to all connected riders in real-time.';
      case Feature.totalConvoySpreadAlert:
        return 'Monitors distance between the lead and the sweeper, alerting you before trailing riders get separated.';
      case Feature.guardianLiveShare:
        return 'Generate an encrypted live web tracking link for family or friends to monitor your ride in real-time.';
      case Feature.unlimitedOfflinePacks:
        return 'Download 2.5 km lateral corridor offline map tile packs across mountain passes and cellular dead zones.';
      case Feature.advancedTelemetryReplay:
        return 'Scrub through your ride with speed HUD, elevation profile, and high-resolution GPX export.';
      case Feature.multiBikeGarage:
        return 'Manage multiple motorcycles in your garage with unique tank capacities, reserve alerts, and service logs.';
      case Feature.sunlightHudMode:
        return 'Ultra-high-contrast AMOLED heads-up display mode designed for harsh noon sunlight on handlebars.';
    }
  }
}
