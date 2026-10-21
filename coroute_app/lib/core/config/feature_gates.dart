/// Subscription tiers and feature entitlements for CoRoute.
///
/// Architecture Design:
/// In the current phase, [forceAllUnlocked] is set to `true`, ensuring all
/// riders and road captains enjoy 100% of CoRoute's capabilities completely free.
///
/// In the future monetization phase, [forceAllUnlocked] can be toggled to `false`,
/// cleanly enforcing Google Play / Apple In-App Purchase (IAP) tiers without
/// requiring any structural refactoring across the app.
enum SubscriptionTier {
  /// Free community tier: standard convoy (up to 4 bikes), basic telemetry, SOS.
  community,

  /// Individual pass: Solo tourers, Guardian web share link, advanced ride analytics.
  proRider,

  /// Convoy host pass: One captain unlocks up to 30 bikes, priority intercom ducking,
  /// mid-ride waypoint broadcast, and total pack spread alerts.
  roadCaptain,

  /// Commercial agency pass: Fleet dispatcher, unlimited bikes, insurance incident exports.
  tourOperator,
}

enum Feature {
  /// Priority audio channel that ducks background chatter when Road Captain speaks.
  priorityIntercomDucking,

  /// Ability to host convoys larger than 4 riders (up to 30 riders).
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
}

class FeatureGates {
  FeatureGates._();

  /// CURRENT MASTER OVERRIDE:
  /// When true, all features across all tiers are completely unlocked and available.
  /// Set to `false` when enabling production Google Play In-App Billing.
  static bool forceAllUnlocked = true;

  /// Active mock or purchased tier for this session (defaults to roadCaptain when unlocked).
  static SubscriptionTier activeTier = SubscriptionTier.roadCaptain;

  /// Checks whether a given [feature] is unlocked for the user.
  static bool isUnlocked(Feature feature, [SubscriptionTier? tier]) {
    if (forceAllUnlocked) return true;

    final effectiveTier = tier ?? activeTier;
    switch (feature) {
      case Feature.priorityIntercomDucking:
      case Feature.unlimitedConvoyCapacity:
      case Feature.dynamicWaypointPush:
      case Feature.totalConvoySpreadAlert:
        return effectiveTier == SubscriptionTier.roadCaptain ||
            effectiveTier == SubscriptionTier.tourOperator;

      case Feature.guardianLiveShare:
      case Feature.unlimitedOfflinePacks:
      case Feature.advancedTelemetryReplay:
      case Feature.multiBikeGarage:
      case Feature.sunlightHudMode:
        return effectiveTier != SubscriptionTier.community;
    }
  }

  /// Returns the maximum allowable convoy size for the given tier.
  static int maxConvoyMembers([SubscriptionTier? tier]) {
    if (forceAllUnlocked) return 30;

    final effectiveTier = tier ?? activeTier;
    switch (effectiveTier) {
      case SubscriptionTier.community:
        return 4;
      case SubscriptionTier.proRider:
        return 4; // Can join large convoys, but hosts max 4
      case SubscriptionTier.roadCaptain:
        return 30;
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
