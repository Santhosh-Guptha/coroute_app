import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/feature_gates.dart';
import 'api_client.dart';

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
/// Razorpay UPI payments, and server-synchronized subscription state.
class PlanSubscriptionService extends ChangeNotifier {
  static const String keyTier = 'coroute_active_subscription_plan';
  static const String keyValidUntil = 'coroute_subscription_valid_until';
  static const String keyForceUnlocked = 'coroute_force_all_unlocked';

  final ApiClient? _api;

  SubscriptionTier _currentTier = SubscriptionTier.community;
  int _validUntil = 0;
  bool _forceAllUnlocked = false;
  bool _loaded = false;

  PlanSubscriptionService([this._api]);

  SubscriptionTier get currentTier => _currentTier;
  int get validUntil => _validUntil;
  bool get forceAllUnlocked => _forceAllUnlocked;
  bool get loaded => _loaded;

  /// Loads the persisted plan and unlock state from SharedPreferences and syncs with server.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tierName = prefs.getString(keyTier);
      if (tierName != null) {
        _currentTier = SubscriptionTier.values.firstWhere(
          (t) => t.name == tierName,
          orElse: () => SubscriptionTier.community,
        );
      }
      _validUntil = prefs.getInt(keyValidUntil) ?? 0;
      _forceAllUnlocked = prefs.getBool(keyForceUnlocked) ?? false;
      _syncToFeatureGates();
    } catch (_) {
      // Fallback defaults
    } finally {
      _loaded = true;
      notifyListeners();
    }

    // Background sync from Gateway API
    if (_api != null && _api.hasToken) {
      syncFromServer().ignore();
    }
  }

  /// Refreshes authentic subscription status from the backend.
  Future<void> syncFromServer() async {
    if (_api == null || !_api.hasToken) return;
    try {
      final res = await _api.get('/subscription/status');
      if (res is Map) {
        final tierName = res['tier']?.toString();
        final until = res['validUntil'] is num ? (res['validUntil'] as num).toInt() : 0;
        if (tierName != null) {
          applyServerSubscription(tierName, until);
        }
      }
    } catch (_) {}
  }

  /// Applies a server-confirmed subscription tier and persists it locally.
  void applyServerSubscription(String tierName, int? validUntilEpochMs) {
    final matched = SubscriptionTier.values.firstWhere(
      (t) => t.name.toLowerCase() == tierName.toLowerCase(),
      orElse: () => SubscriptionTier.community,
    );
    _currentTier = matched;
    _validUntil = validUntilEpochMs ?? 0;
    _forceAllUnlocked = false;
    _syncToFeatureGates();
    notifyListeners();

    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(keyTier, matched.name);
      prefs.setInt(keyValidUntil, _validUntil);
      prefs.setBool(keyForceUnlocked, false);
    }).ignore();
  }

  /// Validates a promotional discount coupon code with the Gateway.
  Future<Map<String, dynamic>?> validateCoupon({
    required String code,
    required SubscriptionTier tier,
    bool annual = false,
    int? amount,
  }) async {
    if (_api == null) throw Exception('API client unavailable.');
    final res = await _api.post('/subscription/validate-coupon', {
      'code': code.trim().toUpperCase(),
      'planTier': tier.name,
      'billingCycle': annual ? 'annual' : 'monthly',
      'amount': ?amount,
    });
    if (res is Map) {
      return Map<String, dynamic>.from(res);
    }
    return null;
  }

  /// Creates a Razorpay UPI order via Gateway API with optional promotional coupon.
  Future<Map<String, dynamic>?> createOrder(
    SubscriptionTier tier, {
    bool annual = false,
    String? couponCode,
  }) async {
    if (_api == null) throw Exception('API client unavailable.');
    final res = await _api.post('/subscription/create-order', {
      'planTier': tier.name,
      'billingCycle': annual ? 'annual' : 'monthly',
      'couponCode': ?couponCode,
    });
    if (res is Map) {
      return Map<String, dynamic>.from(res);
    }
    return null;
  }

  /// Verifies a completed Razorpay UPI transaction with the Gateway and unlocks entitlements.
  Future<Map<String, dynamic>> verifyPayment({
    required String orderId,
    required SubscriptionTier tier,
    bool annual = false,
    String? paymentId,
    String? utr,
    String? signature,
    String? couponCode,
  }) async {
    if (_api == null) {
      return {'success': false, 'error': 'API client unavailable'};
    }
    try {
      final res = await _api.post('/subscription/verify-payment', {
        'orderId': orderId,
        'planTier': tier.name,
        'billingCycle': annual ? 'annual' : 'monthly',
        'paymentId': ?paymentId,
        'utr': ?utr,
        'signature': ?signature,
        'couponCode': ?couponCode,
      });

      if (res is Map && res['success'] == true) {
        final newTier = res['subscriptionTier']?.toString() ?? tier.name;
        final until = res['subscriptionValidUntil'] is num
            ? (res['subscriptionValidUntil'] as num).toInt()
            : 0;
        applyServerSubscription(newTier, until);
        return {'success': true, 'tier': newTier, 'validUntil': until};
      }
      return {'success': false, 'error': res is Map ? res['error']?.toString() : 'Verification failed'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Selects and activates a plan directly (used for free Community tier or local fallback).
  Future<void> selectTier(SubscriptionTier tier) async {
    _currentTier = tier;
    _forceAllUnlocked = false;
    _syncToFeatureGates();
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyTier, tier.name);
      await prefs.setBool(keyForceUnlocked, false);
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

  /// Checks if a feature is unlocked under the current plan.
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
          annualPrice: '₹0 / \$0',
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
            PlanFeatureItem(
              title: 'Road Hazard Helmet Audio Alerts',
              description: 'Receive spatial voice warnings 300m before severe road hazards.',
            ),
          ],
        ),
        const PlanDetails(
          tier: SubscriptionTier.proRider,
          name: 'CoRoute Pro',
          tagline: 'Solo Exploration, Family Tracking & Deep Telemetry',
          monthlyPrice: '₹149 / mo (\$3.99)',
          annualPrice: '₹1,199 / yr (\$29.99)',
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
          monthlyPrice: '₹599 / mo (\$12.99)',
          annualPrice: '₹4,499 / yr (\$99.99)',
          maxConvoySize: 40,
          isPopular: true,
          features: [
            PlanFeatureItem(
              title: 'Host up to 40 Riders in One Convoy',
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
              title: 'Dynamic Convoy Echelon Matrix',
              description: 'Visual zig-zag staggered formation audit and straggler radar.',
            ),
            PlanFeatureItem(
              title: 'Smartwatch Biometric Escalation',
              description: 'Heart-rate crash cross-referencing on paired Wear OS & BLE bands.',
            ),
          ],
        ),
        const PlanDetails(
          tier: SubscriptionTier.tourOperator,
          name: 'Tour Operator',
          tagline: 'Commercial Motorcycle Touring, Marshals & Dispatchers',
          monthlyPrice: '₹1,999 / mo (\$39.99)',
          annualPrice: '₹14,999 / yr (\$299.99)',
          maxConvoySize: 100,
          features: [
            PlanFeatureItem(
              title: 'Up to 100+ Riders per Fleet',
              description: 'Commercial scale for motorcycle clubs, rallies and guided tours.',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Commercial Fleet Analytics Dashboard',
              description: 'Web dispatcher view for marshals, mechanics & sweep vehicles.',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Multiple Sweepers & Tail-End Marshals',
              description: 'Coordinate dual sweepers and chase vehicle radios seamlessly.',
              isHighlight: true,
            ),
            PlanFeatureItem(
              title: 'Expedition Satellite Backup',
              description: 'Iridium Short Burst Data integration for zero-cellular zones.',
            ),
            PlanFeatureItem(
              title: 'Automated Rider Medical Briefings',
              description: 'One-click roster PDF export with blood groups & emergency contacts.',
            ),
          ],
        ),
      ];
}
