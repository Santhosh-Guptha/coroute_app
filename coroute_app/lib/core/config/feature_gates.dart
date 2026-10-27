import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../../data/services/plan_subscription_service.dart';
import '../../presentation/subscription/plan_selector_screen.dart';

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

  /// CURRENT MASTER OVERRIDE:
  /// When true, all features across all tiers are unlocked.
  /// When false (default), features strictly adhere to [activeTier] for testing plan rules.
  static bool forceAllUnlocked = false;

  /// Active subscription tier for this session.
  static SubscriptionTier activeTier = SubscriptionTier.community;

  /// Checks whether a given [feature] is unlocked for the user.
  static bool isUnlocked(Feature feature, [SubscriptionTier? tier]) {
    if (forceAllUnlocked) return true;

    final effectiveTier = tier ?? activeTier;
    switch (feature) {
      case Feature.fleetAnalytics:
        return effectiveTier == SubscriptionTier.tourOperator;

      case Feature.priorityIntercomDucking:
      case Feature.unlimitedConvoyCapacity:
      case Feature.dynamicWaypointPush:
      case Feature.totalConvoySpreadAlert:
      case Feature.roadHazardBroadcast:
        return effectiveTier == SubscriptionTier.roadCaptain ||
            effectiveTier == SubscriptionTier.tourOperator;

      case Feature.roadHazardReceive:
      case Feature.sirenAcousticDetector:
      case Feature.bleHandlebarRemote:
      case Feature.voiceSafetyHotwords:
      case Feature.smartAirbagVest:
        return true;

      case Feature.guardianLiveShare:
      case Feature.unlimitedOfflinePacks:
      case Feature.advancedTelemetryReplay:
      case Feature.multiBikeGarage:
      case Feature.sunlightHudMode:
      case Feature.biometricTraumaPulse:
      case Feature.satelliteSosRelay:
      case Feature.p2pOfflineMesh:
        return effectiveTier != SubscriptionTier.community;
    }
  }

  /// Returns which tier is required to unlock the given feature.
  static SubscriptionTier requiredTier(Feature feature) {
    switch (feature) {
      case Feature.fleetAnalytics:
        return SubscriptionTier.tourOperator;
      case Feature.priorityIntercomDucking:
      case Feature.unlimitedConvoyCapacity:
      case Feature.dynamicWaypointPush:
      case Feature.totalConvoySpreadAlert:
      case Feature.roadHazardBroadcast:
        return SubscriptionTier.roadCaptain;
      case Feature.roadHazardReceive:
      case Feature.sirenAcousticDetector:
      case Feature.bleHandlebarRemote:
      case Feature.voiceSafetyHotwords:
      case Feature.smartAirbagVest:
        return SubscriptionTier.community;
      case Feature.guardianLiveShare:
      case Feature.unlimitedOfflinePacks:
      case Feature.advancedTelemetryReplay:
      case Feature.multiBikeGarage:
      case Feature.sunlightHudMode:
      case Feature.biometricTraumaPulse:
      case Feature.satelliteSosRelay:
      case Feature.p2pOfflineMesh:
        return SubscriptionTier.proRider;
    }
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
    final neededTier = requiredTier(feature);
    final neededLabel = tierLabel(neededTier);
    final planService = context.read<PlanSubscriptionService>();
    final heldAlready = planService.canSelect(neededTier);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.border2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.warnTint,
                border: Border.all(color: AppTheme.warnBorder, width: 2),
              ),
              child: Icon(Icons.lock_rounded, color: AppTheme.warnText, size: 30),
            ),
            const SizedBox(height: 16),
            Text(
              featureName(feature),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.accentText.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.accentText, width: 1),
              ),
              child: Text(
                'REQUIRES $neededLabel'.toUpperCase(),
                style: TextStyle(
                  color: AppTheme.accentText,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              featureDescription(feature),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.text2, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  // Only switches within what the rider holds; a higher tier needs checkout.
                  final switched = await planService.selectTier(neededTier);
                  if (!context.mounted) return;
                  if (switched) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(seconds: 2),
                        backgroundColor: AppTheme.card,
                        content: Text(
                          'Activated $neededLabel! Feature is now unlocked.',
                          style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w700),
                        ),
                      ),
                    );
                  } else {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PlanSelectorScreen(preselectTier: neededTier),
                      ),
                    );
                  }
                },
                child: Text(
                  (heldAlready ? 'SWITCH TO $neededLabel (FREE)' : 'UPGRADE TO $neededLabel').toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Returns the maximum allowable convoy size for the given tier.
  static int maxConvoyMembers([SubscriptionTier? tier]) {
    if (forceAllUnlocked) return 100;

    final effectiveTier = tier ?? activeTier;
    switch (effectiveTier) {
      case SubscriptionTier.community:
        return 4;
      case SubscriptionTier.proRider:
        return 4;
      case SubscriptionTier.roadCaptain:
        return 40;
      case SubscriptionTier.tourOperator:
        return 100;
    }
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
