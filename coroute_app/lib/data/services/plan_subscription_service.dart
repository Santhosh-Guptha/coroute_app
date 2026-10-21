import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/feature_gates.dart';

/// Information describing a capability or feature of a plan.
class PlanFeatureItem {
  final String title;
  final String description;
  final bool isHighlight;

  const PlanFeatureItem({
    required this.title,
    required this.description,
    this.isHighlight = false,
  });
}

/// Metadata and feature matrix for a specific subscription tier.
class PlanDetails {
  final SubscriptionTier tier;
  final String name;
  final String tagline;
  final String monthlyPrice;
  final String annualPrice;
  final int maxConvoySize;
  final List<PlanFeatureItem> features;
  final bool isPopular;

  const PlanDetails({
    required this.tier,
    required this.name,
    required this.tagline,
    required this.monthlyPrice,
    required this.annualPrice,
    required this.maxConvoySize,
    required this.features,
    this.isPopular = false,
  });
}

/// Service managing subscription plan selection, feature entitlements,
/// and local test-mode plan switching.
///
/// In the current test & pre-launch phase, any user can switch between tiers
/// freely on the Plan Selector Screen to test how CoRoute behaves under each
/// plan's strict rules or under the global "Force Unlock All" mode.
class PlanSubscriptionService extends ChangeNotifier {
  static const String keyTier = 'coroute_active_subscription_plan';
  static const String keyForceUnlocked = 'coroute_force_all_unlocked';

  SubscriptionTier _currentTier = SubscriptionTier.roadCaptain;
  bool _forceAllUnlocked = true;
  bool _loaded = false;

  SubscriptionTier get currentTier => _currentTier;
  bool get forceAllUnlocked => _forceAllUnlocked;
  bool get loaded => _loaded;

  /// Loads the persisted plan and unlock state from SharedPreferences.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tierName = prefs.getString(keyTier);
      if (tierName != null) {
        _currentTier = SubscriptionTier.values.firstWhere(
          (t) => t.name == tierName,
          orElse: () => SubscriptionTier.roadCaptain,
        );
      }
      _forceAllUnlocked = prefs.getBool(keyForceUnlocked) ?? true;
      _syncToFeatureGates();
    } catch (_) {
      // Fallback defaults
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// Selects and activates a plan for testing or use.
  Future<void> selectTier(SubscriptionTier tier) async {
    _currentTier = tier;
    _syncToFeatureGates();
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyTier, tier.name);
    } catch (_) {}
  }

  /// Toggles whether strict tier rules are enforced or all features forced unlocked.
  Future<void> setForceAllUnlocked(bool unlocked) async {
    _forceAllUnlocked = unlocked;
    _syncToFeatureGates();
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyForceUnlocked, unlocked);
    } catch (_) {}
  }

  void _syncToFeatureGates() {
    FeatureGates.activeTier = _currentTier;
    FeatureGates.forceAllUnlocked = _forceAllUnlocked;
  }

  /// Checks if a feature is unlocked under the current plan / force setting.
  bool isUnlocked(Feature feature) => FeatureGates.isUnlocked(feature, _currentTier);

  /// Current max allowable convoy size.
  int get maxConvoyMembers => FeatureGates.maxConvoyMembers(_currentTier);

  /// Returns full plan specifications for all available tiers.
  static List<PlanDetails> get allPlans => [
        const PlanDetails(
          tier: SubscriptionTier.community,
          name: 'Community Rider',
          tagline: 'Essential Safety & Small Group Rides',
          monthlyPrice: 'Free Forever',
          annualPrice: '₹0 / $0',
          maxConvoySize: 4,
          features: [
            PlanFeatureItem(
              title: 'Up to 4 Riders per Convoy',
              description: 'Real-time GPS tracking and live convoy bead-wire.',
            ),
            PlanFeatureItem(
              title: 'Standard PTT Intercom',
              description: 'Clear half-duplex voice bursts with noise suppression.',
            ),
            PlanFeatureItem(
              title: 'Essential Safety & SOS',
              description: 'Manual distress trigger with automated SMS coordinates fallback.',
            ),
            PlanFeatureItem(
              title: 'Stopped Rider Status Cards',
              description: 'Instant Fuel, Flat Tire, Rest Break & Mechanical badges.',
            ),
            PlanFeatureItem(
              title: 'Single Corridor Map Cache',
              description: 'Offline tile caching for your active planned route.',
            ),
          ],
        ),
        const PlanDetails(
          tier: SubscriptionTier.proRider,
          name: 'CoRoute Pro',
          tagline: 'Solo Exploration, Family Tracking & Deep Telemetry',
          monthlyPrice: '₹149 / mo ($3.99)',
          annualPrice: '₹1,199 / yr ($29.99)',
          maxConvoySize: 4,
          features: [
            PlanFeatureItem(
              title: 'Everything in Community',
              description: 'All core tracking, intercom, and safety features.',
            ),
            PlanFeatureItem(
              title: 'Ride Guardian Live Share',
              description: 'Live encrypted browser link for family (no app required).',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Auto Crash & Fall Detection',
              description: '18s high-speed slide window with auto-abort countdown.',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Unlimited 2.5km Corridor Packs',
              description: 'Download unlimited high-res offline tile packs across zoom 11–16.',
            ),
            PlanFeatureItem(
              title: 'Predictive Fuel Auto-Recovery',
              description: 'Automatic tank range monitoring and tunnel auto-reanchoring.',
            ),
            PlanFeatureItem(
              title: 'Multi-Bike Garage Profile',
              description: 'Custom tank capacities, reserve warnings & maintenance intervals.',
            ),
            PlanFeatureItem(
              title: 'High-Res GPX & Lean Telemetry',
              description: 'Export cornering G-force, elevation curves & speed data.',
            ),
          ],
        ),
        const PlanDetails(
          tier: SubscriptionTier.roadCaptain,
          name: 'Road Captain Pass',
          tagline: 'Host the Pack — One Pass Unlocks the Entire Convoy',
          monthlyPrice: '₹599 / mo ($12.99)',
          annualPrice: '₹4,499 / yr ($99.99)',
          maxConvoySize: 30,
          isPopular: true,
          features: [
            PlanFeatureItem(
              title: 'Host up to 30 Riders in One Convoy',
              description: 'Every joined rider automatically gets premium perks during the ride.',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Priority Intercom Voice Ducking (-18 dB)',
              description: 'Captain hazard broadcasts instantly duck background chatter.',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Total Convoy Spread Warnings',
              description: 'Alerts the Lead when the pack strings out (> 3 km separation).',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Mid-Ride Waypoint Push',
              description: 'Drop regroup or petrol station pins directly onto everyone\'s map.',
            ),
            PlanFeatureItem(
              title: 'Live Cockpit Fleet Matrix',
              description: 'Bird\'s-eye view of every member\'s speed, battery %, and status.',
            ),
            PlanFeatureItem(
              title: 'Includes All CoRoute Pro Features',
              description: 'Full Guardian links, crash alarms, garage, and GPX exports.',
            ),
          ],
        ),
        const PlanDetails(
          tier: SubscriptionTier.tourOperator,
          name: 'Tour Operator Enterprise',
          tagline: 'Commercial Fleets, Rallies & Multi-Day Expeditions',
          monthlyPrice: '₹3,999 / tour ($79)',
          annualPrice: '₹39,000 / yr ($499)',
          maxConvoySize: 100,
          features: [
            PlanFeatureItem(
              title: 'Up to 100+ Bikes per Convoy',
              description: 'Massive scale coordination for rallies, clubs, and tours.',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Web Dispatcher Console (PC / Tablet)',
              description: 'Live mission-control dashboard for base camp and support trucks.',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Custom Branded Join Codes',
              description: 'Personalized vanity codes (e.g. SPITI-2026, ROYAL-EXP-01).',
            ),
            PlanFeatureItem(
              title: 'Official Incident & SOS Insurance Logs',
              description: 'Export timestamped compliance manifests and safety logs (PDF/CSV).',
            ),
            PlanFeatureItem(
              title: 'Multi-Role Convoy Hierarchy',
              description: 'Dedicated Lead, Sweeper, Marshal, and Support Mechanic markers.',
            ),
          ],
        ),
      ];
}
