import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/feature_gates.dart';
import 'api_client.dart';

/// A `SUBSCRIPTION_EXPIRING` warning from the gateway, kept until the UI shows it once.
class SubscriptionExpiringNotice {
  final int daysRemaining;
  final SubscriptionTier tier;
  final int validUntil;

  /// 7, 3 or 1: the warning step this notice belongs to (shown once per step).
  final int threshold;

  const SubscriptionExpiringNotice({
    required this.daysRemaining,
    required this.tier,
    required this.validUntil,
    required this.threshold,
  });
}

/// A `SUBSCRIPTION_EXPIRED` event from the gateway, kept until the UI shows it once.
class SubscriptionExpiredNotice {
  final SubscriptionTier previousTier;
  final int expiredAt;

  const SubscriptionExpiredNotice({required this.previousTier, required this.expiredAt});
}

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
class PlanSubscriptionService extends ChangeNotifier with WidgetsBindingObserver {
  static const String keyTier = 'coroute_active_subscription_plan';
  static const String keyValidUntil = 'coroute_subscription_valid_until';
  static const String keyForceUnlocked = 'coroute_force_all_unlocked';
  static const String keyPreviousTier = 'coroute_subscription_previous_tier';
  static const String keyExpiredAt = 'coroute_subscription_expired_at';

  /// Prefix of the per-step "expiring" warning marker (value: the validUntil it was shown for).
  static const String keyExpiringNoticePrefix = 'coroute_subscription_expiring_notice_';

  /// Days-left steps at which an expiry warning is shown, once each per subscription period.
  static const List<int> warningThresholds = [7, 3, 1];

  final ApiClient? _api;

  SubscriptionTier _currentTier = SubscriptionTier.community;
  int _validUntil = 0;
  bool _forceAllUnlocked = false;
  bool _loaded = false;

  /// The paid tier the rider had before it ran out (null while a plan is active or never had one).
  SubscriptionTier? _previousTier;
  int _expiredAt = 0;

  /// Days left as the server computed them (used when it is fresher than the local clock).
  int? _serverDaysRemaining;

  SubscriptionExpiringNotice? _expiringNotice;
  SubscriptionExpiredNotice? _expiredNotice;
  Timer? _expiryTimer;
  bool _observing = false;

  PlanSubscriptionService([this._api]) {
    _expiryTimer = Timer.periodic(const Duration(minutes: 1), (_) => checkExpiry());
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // No binding (unit tests): expiry is still checked by the timer and on sync.
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onAppResumed();
  }

  /// Back in the foreground: the clock may have moved past validUntil while asleep.
  void onAppResumed() {
    checkExpiry();
    if (_api != null && _api.hasToken) syncFromServer().ignore();
  }

  /// The tier whose features are unlocked right now (an expired paid plan reads as community).
  SubscriptionTier get currentTier => _currentTier;

  /// Alias of [currentTier], named for call sites that gate features.
  SubscriptionTier get effectiveTier => _currentTier;
  int get validUntil => _validUntil;
  bool get forceAllUnlocked => _forceAllUnlocked;
  bool get loaded => _loaded;

  /// The paid tier that ran out, until the rider renews or picks Community on purpose.
  SubscriptionTier? get previousTier => _previousTier;
  int get expiredAt => _expiredAt;

  /// True when a paid plan ended and the rider has been rolled back to Community.
  bool get isExpired => _previousTier != null && _currentTier == SubscriptionTier.community;

  bool get _isPaid => _currentTier != SubscriptionTier.community;

  /// Whole days left on the current paid plan (0 when none, or when it already ended).
  int get daysRemaining {
    if (!_isPaid || _validUntil <= 0) return 0;
    final ms = _validUntil - DateTime.now().millisecondsSinceEpoch;
    if (ms <= 0) return 0;
    final local = (ms / Duration.millisecondsPerDay).ceil();
    final server = _serverDaysRemaining;
    return server != null && server < local ? server : local;
  }

  /// True when the paid plan ends within [warningThresholds].first days.
  bool get expiringSoon => _isPaid && _validUntil > 0 && daysRemaining <= warningThresholds.first;

  /// The tier to offer when the rider taps "Renew": the expired one, or the one that is ending.
  SubscriptionTier get renewTier => _previousTier ?? (_isPaid ? _currentTier : SubscriptionTier.community);

  /// Pending warning from the gateway (or the local countdown), null once shown.
  SubscriptionExpiringNotice? get expiringNotice => _expiringNotice;

  /// Pending "your plan ended" notice, null once shown.
  SubscriptionExpiredNotice? get expiredNotice => _expiredNotice;

  /// Marks the pending warning as shown.
  void consumeExpiringNotice() {
    if (_expiringNotice == null) return;
    _expiringNotice = null;
    notifyListeners();
  }

  /// Marks the pending expired dialog as shown.
  void consumeExpiredNotice() {
    if (_expiredNotice == null) return;
    _expiredNotice = null;
    notifyListeners();
  }

  /// The warning step (7, 3 or 1) a number of days left falls into.
  static int thresholdFor(int daysRemaining) {
    for (final t in warningThresholds.reversed) {
      if (daysRemaining <= t) return t;
    }
    return warningThresholds.first;
  }

  /// Two or three headline features of a paid tier, for renewal copy.
  static String keyFeatureSummary(SubscriptionTier tier) {
    switch (tier) {
      case SubscriptionTier.proRider:
        return 'live radar, voice alerts and crash detection';
      case SubscriptionTier.roadCaptain:
        return '40-rider convoys, priority intercom and waypoint push';
      case SubscriptionTier.tourOperator:
        return 'fleet dispatch, 100-rider fleets and satellite backup';
      case SubscriptionTier.community:
        return 'your Community features';
    }
  }

  /// Rolls a paid plan back to Community once its validUntil is in the past.
  /// Returns true when a rollback happened.
  bool checkExpiry() {
    if (!_isPaid || _validUntil <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_validUntil > now) {
      // Still valid: raise the 7/3/1-day warning locally too, in case the gateway's push is missed.
      if (expiringSoon) _noteExpiring(daysRemaining, _currentTier, _validUntil);
      return false;
    }
    _expire(previousTier: _currentTier, expiredAt: _validUntil, notice: false);
    return true;
  }

  void _expire({required SubscriptionTier previousTier, required int expiredAt, required bool notice}) {
    _previousTier = previousTier == SubscriptionTier.community ? _previousTier : previousTier;
    _expiredAt = expiredAt;
    _currentTier = SubscriptionTier.community;
    _validUntil = 0;
    _serverDaysRemaining = null;
    _expiringNotice = null;
    _forceAllUnlocked = false;
    if (notice && _previousTier != null) {
      _expiredNotice = SubscriptionExpiredNotice(previousTier: _previousTier!, expiredAt: expiredAt);
    }
    _syncToFeatureGates();
    notifyListeners();
    _persist();
  }

  void _persist() {
    SharedPreferences.getInstance().then((prefs) async {
      await prefs.setString(keyTier, _currentTier.name);
      await prefs.setInt(keyValidUntil, _validUntil);
      await prefs.setBool(keyForceUnlocked, _forceAllUnlocked);
      final prev = _previousTier;
      if (prev == null) {
        await prefs.remove(keyPreviousTier);
        await prefs.remove(keyExpiredAt);
      } else {
        await prefs.setString(keyPreviousTier, prev.name);
        await prefs.setInt(keyExpiredAt, _expiredAt);
      }
    }).ignore();
  }

  static SubscriptionTier? _tierNamed(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final t in SubscriptionTier.values) {
      if (t.name.toLowerCase() == name.toLowerCase()) return t;
    }
    return null;
  }

  /// Applies the `subscriptionStatus` object the gateway sends with `/me`,
  /// `/auth/login` and `/subscription/status`:
  /// `{ tier, validUntil, isActive, isExpired, daysRemaining, expiringSoon, previousTier }`.
  /// An expired paid tier arrives already reported as `community`.
  void applySubscriptionStatus(Map<String, dynamic> status) {
    final tierName = status['tier']?.toString();
    if (tierName == null || tierName.isEmpty) return;
    final until = status['validUntil'] is num ? (status['validUntil'] as num).toInt() : 0;
    final prev = _tierNamed(status['previousTier']?.toString());
    final expired = status['isExpired'] == true;
    final days = status['daysRemaining'] is num ? (status['daysRemaining'] as num).toInt() : null;
    applyServerSubscription(tierName, until, previousTier: expired ? (prev ?? _previousTier) : prev, serverDaysRemaining: days);
    if (status['expiringSoon'] == true && _isPaid && days != null) {
      _noteExpiring(days, _currentTier, _validUntil);
    }
  }

  /// Records a warning for [daysRemaining] days left, once per threshold step per plan period.
  void _noteExpiring(int daysRemaining, SubscriptionTier tier, int validUntil) {
    final threshold = thresholdFor(daysRemaining);
    SharedPreferences.getInstance().then((prefs) {
      final key = '$keyExpiringNoticePrefix$threshold';
      if (prefs.getInt(key) == validUntil) return; // already shown for this period
      prefs.setInt(key, validUntil).ignore();
      _expiringNotice = SubscriptionExpiringNotice(
        daysRemaining: daysRemaining,
        tier: tier,
        validUntil: validUntil,
        threshold: threshold,
      );
      notifyListeners();
    }).ignore();
  }

  /// Gateway `SUBSCRIPTION_EXPIRING` `{daysRemaining, tier, validUntil}`.
  void handleExpiringEvent(Map<String, dynamic> e) {
    final days = e['daysRemaining'] is num ? (e['daysRemaining'] as num).toInt() : daysRemaining;
    final tier = _tierNamed(e['tier']?.toString()) ?? _currentTier;
    final until = e['validUntil'] is num ? (e['validUntil'] as num).toInt() : _validUntil;
    if (tier == SubscriptionTier.community) return;
    if (until > 0 && (tier != _currentTier || until != _validUntil)) {
      applyServerSubscription(tier.name, until, serverDaysRemaining: days);
    } else {
      _serverDaysRemaining = days;
      notifyListeners();
    }
    _noteExpiring(days, tier, until);
  }

  /// Gateway `SUBSCRIPTION_EXPIRED` `{previousTier, expiredAt}`: roll back right away.
  void handleExpiredEvent(Map<String, dynamic> e) {
    final prev = _tierNamed(e['previousTier']?.toString()) ?? (_isPaid ? _currentTier : _previousTier);
    final at = e['expiredAt'] is num ? (e['expiredAt'] as num).toInt() : DateTime.now().millisecondsSinceEpoch;
    if (prev == null) return;
    _expire(previousTier: prev, expiredAt: at, notice: true);
  }

  /// `GET /subscription/history`: `{ history: [...], subscriptionHistory: [...], orders: [...] }`.
  Future<Map<String, dynamic>> fetchHistory() async {
    if (_api == null) throw const ApiException(0, 'API client unavailable.');
    final res = await _api.get('/subscription/history');
    if (res is Map) return Map<String, dynamic>.from(res);
    return const {'history': [], 'subscriptionHistory': [], 'orders': []};
  }

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
      _previousTier = _tierNamed(prefs.getString(keyPreviousTier));
      _expiredAt = prefs.getInt(keyExpiredAt) ?? 0;
      _syncToFeatureGates();
    } catch (_) {
      // Fallback defaults
    } finally {
      _loaded = true;
      notifyListeners();
    }
    checkExpiry();

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
        final m = Map<String, dynamic>.from(res);
        final status = m['subscriptionStatus'];
        if (status is Map) {
          applySubscriptionStatus(Map<String, dynamic>.from(status));
        } else if (m['tier'] != null) {
          // Flat shape (older gateway or the status object itself).
          applySubscriptionStatus(m);
        }
      }
    } catch (_) {}
    checkExpiry();
  }

  /// Applies a server-confirmed subscription tier and persists it locally.
  ///
  /// A paid tier whose [validUntilEpochMs] is already past is stored as Community
  /// with the paid tier kept as [previousTier]. A paid tier that is still valid
  /// clears any earlier expiry (the rider renewed).
  void applyServerSubscription(
    String tierName,
    int? validUntilEpochMs, {
    SubscriptionTier? previousTier,
    int? serverDaysRemaining,
  }) {
    final matched = _tierNamed(tierName) ?? SubscriptionTier.community;
    final until = validUntilEpochMs ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (matched != SubscriptionTier.community && until > 0 && until <= now) {
      _expire(previousTier: matched, expiredAt: until, notice: false);
      return;
    }
    _currentTier = matched;
    _validUntil = until;
    _forceAllUnlocked = false;
    _serverDaysRemaining = matched == SubscriptionTier.community ? null : serverDaysRemaining;
    if (matched != SubscriptionTier.community) {
      _previousTier = null; // an active paid plan supersedes any earlier expiry
      _expiredAt = 0;
    } else if (previousTier != null && previousTier != SubscriptionTier.community) {
      _previousTier = previousTier;
      if (_expiredAt == 0) _expiredAt = now;
    }
    _syncToFeatureGates();
    notifyListeners();
    _persist();
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
        if (res['subscriptionStatus'] is Map) {
          applySubscriptionStatus(Map<String, dynamic>.from(res['subscriptionStatus'] as Map));
        } else {
          applyServerSubscription(newTier, until);
        }
        return {'success': true, 'tier': newTier, 'validUntil': until};
      }
      if (res is Map && res['pending'] == true) {
        return {'success': false, 'pending': true, 'message': res['message']?.toString()};
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
    if (tier == SubscriptionTier.community) {
      // Chosen on purpose: no longer "expired", just free.
      _previousTier = null;
      _expiredAt = 0;
      _validUntil = 0;
      _serverDaysRemaining = null;
      _expiringNotice = null;
    }
    _syncToFeatureGates();
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyTier, tier.name);
      await prefs.setBool(keyForceUnlocked, false);
      if (tier == SubscriptionTier.community) {
        await prefs.setInt(keyValidUntil, 0);
        await prefs.remove(keyPreviousTier);
        await prefs.remove(keyExpiredAt);
      }
    } catch (_) {}
  }

  /// Signed out: back to the free tier with no history of a paid plan.
  Future<void> resetLocal() async {
    _currentTier = SubscriptionTier.community;
    _validUntil = 0;
    _previousTier = null;
    _expiredAt = 0;
    _serverDaysRemaining = null;
    _expiringNotice = null;
    _expiredNotice = null;
    _forceAllUnlocked = false;
    _syncToFeatureGates();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(keyTier);
      await prefs.remove(keyValidUntil);
      await prefs.remove(keyPreviousTier);
      await prefs.remove(keyExpiredAt);
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
