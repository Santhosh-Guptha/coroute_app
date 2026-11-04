import 'package:flutter/material.dart';

/// Subscription tiers and feature entitlements for CoRoute.
///
/// Riders pick the plan to ride with on the Plan Selector screen, at or below the
/// tier the gateway says they hold; every screen, button and cockpit control maps
/// strictly to that effective plan.
enum SubscriptionTier {
  /// Free community tier: standard convoy (up to 4 bikes), basic telemetry, SOS.
  community,

  /// Individual pass: Solo tourers, Guardian web share link, advanced ride analytics.
  proRider,

  /// Convoy host pass: One captain unlocks up to 40 bikes, priority intercom ducking,
  /// mid-ride waypoint broadcast, and total pack spread alerts.
  roadCaptain,

  /// Commercial agency pass: Fleet dispatcher, unlimited bikes, insurance incident exports.
  tourOperator,
}

enum Feature {
  /// Priority audio channel that ducks background chatter when Road Captain speaks.
  priorityIntercomDucking,

  /// Ability to host convoys larger than 4 riders (up to 40 riders).
  unlimitedConvoyCapacity,

  /// Unlimited 2.5 km Minkowski corridor offline map tile downloads.
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

  /// B2B Fleet health, tour timetable variance & client risk scorecard.
  fleetAnalytics,

  /// Collective road hazard AI telemetry broadcast (Road Captain only).
  roadHazardBroadcast,

  /// Collective road hazard telemetry reception and helmet audio warnings (Community & Pro).
  roadHazardReceive,

  /// Emergency siren acoustic frequency detector & audio ducking (Community & all tiers).
  sirenAcousticDetector,

  /// BLE handlebar wireless remote for hands-free PTT, tactical signals, and SOS (Community & all tiers).
  bleHandlebarRemote,

  /// Smartwatch biometric trauma & pulse verification for crash escalation (Pro Rider & Road Captain).
  biometricTraumaPulse,

  /// Low-connectivity SOS & satellite emergency relay (Pro Rider & Tour Operator).
  satelliteSosRelay,

  /// Hands-free helmet Bluetooth intercom voice safety hotwords (Community & all tiers).
  voiceSafetyHotwords,

  /// Peer-to-Peer Bluetooth & Wi-Fi offline convoy mesh networking (Road Captain & Pro Rider).
  p2pOfflineMesh,

  /// Smart airbag vest BLE bridge for instantaneous pyrotechnic deployment escalation (Community & all tiers).
  smartAirbagVest,
}

class FeatureGates {
  FeatureGates._();

  /// Whether the payment screen, subscription plans, and feature gating are active.
  /// When true (default): features adhere to the user's active subscription tier and payment screens are enabled.
  /// When false: payment screens are OFF, feature gating is disabled, and all features are unlocked freely.
  static bool paymentsEnabled = true;

  /// CURRENT MASTER OVERRIDE:
  /// When true, all features across all tiers are unlocked.
  /// When false (default), features strictly adhere to [activeTier] for testing plan rules.
  static bool forceAllUnlocked = true;

  /// Active subscription tier for this session.
  static SubscriptionTier activeTier = SubscriptionTier.tourOperator;

  /// Checks whether a given [feature] is unlocked for the user.
  /// All features are included for all riders. Seat capacity is the only distinction.
  static bool isUnlocked(Feature feature, [SubscriptionTier? tier]) {
    return true;
  }

  /// Returns which tier is required to unlock the given feature.
  static SubscriptionTier requiredTier(Feature feature) {
    return SubscriptionTier.community;
  }

  /// Human-friendly feature display name.
  static String featureName(Feature feature) {
    switch (feature) {
      case Feature.priorityIntercomDucking:
        return 'Priority Intercom Voice Ducking (-18 dB)';
      case Feature.unlimitedConvoyCapacity:
        return 'Large Convoy Capacity (Up to 40+ Bikes)';
      case Feature.dynamicWaypointPush:
        return 'Mid-Ride Waypoint & Regroup Dispatch';
      case Feature.totalConvoySpreadAlert:
        return 'Total Convoy Spread Alerts';
      case Feature.guardianLiveShare:
        return 'Ride Guardian Encrypted Live Share';
      case Feature.unlimitedOfflinePacks:
        return 'Unlimited Corridor Offline Map Packs';
      case Feature.advancedTelemetryReplay:
        return '2D Route Replay & GPX Telemetry Export';
      case Feature.multiBikeGarage:
        return 'Multi-Bike Motorcycle Garage';
      case Feature.sunlightHudMode:
        return 'AMOLED Sunlight HUD High-Contrast';
      case Feature.fleetAnalytics:
        return 'B2B Fleet Health & Client Risk Scorecard';
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
        return 'Road Captain audio broadcasts automatically duck background chatter by -18 dB so hazard warnings cut through instantly.';
      case Feature.unlimitedConvoyCapacity:
        return 'Scale your convoy beyond the free 4-bike limit up to 40 riders (Road Captain) or 100+ riders (Tour Operator).';
      case Feature.dynamicWaypointPush:
        return 'Push route changes, fuel stops, and rest regroup waypoints dynamically to all connected riders in real-time.';
      case Feature.totalConvoySpreadAlert:
        return 'Monitors distance between Lead and Sweeper, alerting you before trailing riders get separated.';
      case Feature.guardianLiveShare:
        return 'Generate an encrypted live web tracking link for family or friends to monitor your ride in real-time.';
      case Feature.unlimitedOfflinePacks:
        return 'Download unlimited 2.5 km lateral corridor offline map tile packs across mountain passes and cellular dead zones.';
      case Feature.advancedTelemetryReplay:
        return 'Scrub through your ride with speed HUD, elevation profile, and high-resolution GPX export.';
      case Feature.multiBikeGarage:
        return 'Manage multiple motorcycles in your garage with unique tank capacities, reserve alerts, and service logs.';
      case Feature.sunlightHudMode:
        return 'Ultra-high-contrast AMOLED heads-up display mode designed for harsh noon sunlight on handlebars.';
      case Feature.fleetAnalytics:
        return 'Commercial fleet analytics, wear index estimation, scheduled waypoint timetable variance, and audit logs.';
    }
  }

  /// Displays a plan-gate modal: a one-tap switch when the rider already holds
  /// the needed tier (e.g. after dropping to Community), otherwise a way to upgrade.
  static void showUpgradeModal(BuildContext context, Feature feature) {
    // All features are unlocked by default across all tiers.
    return;
  }

  /// Returns the maximum allowable convoy size for the given tier.
  static int maxConvoyMembers([SubscriptionTier? tier]) {
    return 100;
  }

  /// Label for displaying the tier in settings or profile.
  static String tierLabel(SubscriptionTier tier) {
    switch (tier) {
      case SubscriptionTier.community:
        return 'Community Rider';
      case SubscriptionTier.proRider:
        return 'CoRoute Pro';
      case SubscriptionTier.roadCaptain:
        return 'Road Captain';
      case SubscriptionTier.tourOperator:
        return 'Tour Operator';
    }
  }
}
