import 'dart:async';
import 'dart:convert';

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

  PlanDetails copyWith({
    SubscriptionTier? tier,
    String? name,
    String? tagline,
    String? monthlyPrice,
    String? annualPrice,
    int? maxConvoySize,
    List<PlanFeatureItem>? features,
    bool? isPopular,
  }) {
    return PlanDetails(
      tier: tier ?? this.tier,
      name: name ?? this.name,
      tagline: tagline ?? this.tagline,
      monthlyPrice: monthlyPrice ?? this.monthlyPrice,
      annualPrice: annualPrice ?? this.annualPrice,
      maxConvoySize: maxConvoySize ?? this.maxConvoySize,
      features: features ?? this.features,
      isPopular: isPopular ?? this.isPopular,
    );
  }
}

/// Service managing subscription plan selection, feature entitlements,
/// Razorpay UPI payments, and server-synchronized subscription state.
class PlanSubscriptionService extends ChangeNotifier with WidgetsBindingObserver {
  /// The tier the server says the rider is entitled to (`entitledTier`).
  static const String keyTier = 'coroute_active_subscription_plan';
  static const String keyValidUntil = 'coroute_subscription_valid_until';

  /// The tier the rider chose to ride with (`preferredTier`, never above the entitlement).
  static const String keyPreferredTier = 'coroute_preferred_subscription_plan';
  static const String keyForceUnlocked = 'coroute_force_all_unlocked';
  static const String keyPreviousTier = 'coroute_subscription_previous_tier';
  static const String keyExpiredAt = 'coroute_subscription_expired_at';
  static const String keyConfiguredPlans = 'coroute_subscription_configured_plans';

  static Map<String, dynamic>? _configuredPlans;

  /// Exposes reactive plan details list with dynamically configured prices.
  List<PlanDetails> get plans => allPlans;

  /// Prefix of the per-step "expiring" warning marker (value: the validUntil it was shown for).
  static const String keyExpiringNoticePrefix = 'coroute_subscription_expiring_notice_';

  /// Days-left steps at which an expiry warning is shown, once each per subscription period.
  static const List<int> warningThresholds = [7, 3, 1];

  final ApiClient? _api;

  /// Server truth: the tier the rider has paid for (Community when none), with [_validUntil].
  SubscriptionTier _entitledTier = SubscriptionTier.community;
  int _validUntil = 0;

  /// Local choice: the tier the rider wants to use right now. Kept at or below the entitlement
  /// by [effectiveTier]; a paid rider may pick Community without giving the paid plan up.
  SubscriptionTier _preferredTier = SubscriptionTier.community;
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

  /// The tier the server says is paid for and not yet expired (Community when none).
  SubscriptionTier get entitledTier => _entitledTier;

  /// The tier the rider chose to use; may sit below [entitledTier] (never above it in effect).
  SubscriptionTier get preferredTier => _preferredTier;

  /// The tier whose features are unlocked right now: the preference while it is covered by the
  /// entitlement, otherwise Community (an expired paid plan reads as community).
  SubscriptionTier get effectiveTier =>
      _withinEntitlement(_preferredTier) ? _preferredTier : SubscriptionTier.community;

  /// Alias of [effectiveTier] for existing call sites.
  SubscriptionTier get currentTier => effectiveTier;
  int get validUntil => _validUntil;

  /// True when [tier] can be used without paying: Community, or at/below the entitlement.
  bool canSelect(SubscriptionTier tier) => _withinEntitlement(tier);

  /// True when [tier] is the paid plan the rider currently holds (valid, not expired).
  bool isEntitledTo(SubscriptionTier tier) =>
      tier != SubscriptionTier.community && tier == _entitledTier && !_entitlementLapsed;

  bool _withinEntitlement(SubscriptionTier tier) {
    if (tier == SubscriptionTier.community) return true;
    if (_entitlementLapsed) return false;
    return tier.index <= _entitledTier.index;
  }

  /// A paid entitlement whose validUntil is already behind us (before [checkExpiry] ran).
  bool get _entitlementLapsed =>
      _entitledTier != SubscriptionTier.community &&
      _validUntil > 0 &&
      _validUntil <= DateTime.now().millisecondsSinceEpoch;
  bool get forceAllUnlocked => _forceAllUnlocked;
  bool get loaded => _loaded;

  /// The paid tier that ran out, until the rider renews or picks Community on purpose.
  SubscriptionTier? get previousTier => _previousTier;
  int get expiredAt => _expiredAt;

  /// True when a paid plan ended and the rider has been rolled back to Community.
  bool get isExpired => _previousTier != null && _entitledTier == SubscriptionTier.community;

  /// True while the server-side entitlement is a paid tier.
  bool get _isPaid => _entitledTier != SubscriptionTier.community;

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
  SubscriptionTier get renewTier => _previousTier ?? (_isPaid ? _entitledTier : SubscriptionTier.community);

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
      if (expiringSoon) _noteExpiring(daysRemaining, _entitledTier, _validUntil);
      return false;
    }
    _expire(previousTier: _entitledTier, expiredAt: _validUntil, notice: false);
    return true;
  }

  void _expire({required SubscriptionTier previousTier, required int expiredAt, required bool notice}) {
    _previousTier = previousTier == SubscriptionTier.community ? _previousTier : previousTier;
    _expiredAt = expiredAt;
    // Only the entitlement ends; the preference is left as it is and effectiveTier
    // reads as Community until a renewal brings the entitlement back.
    _entitledTier = SubscriptionTier.community;
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
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(keyTier, _entitledTier.name);
      prefs.setInt(keyValidUntil, _validUntil);
      prefs.setString(keyPreferredTier, _preferredTier.name);
      prefs.setBool(keyForceUnlocked, _forceAllUnlocked);
      final prev = _previousTier;
      if (prev == null) {
        prefs.remove(keyPreviousTier);
        prefs.remove(keyExpiredAt);
      } else {
        prefs.setString(keyPreviousTier, prev.name);
        prefs.setInt(keyExpiredAt, _expiredAt);
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
      _noteExpiring(days, _entitledTier, _validUntil);
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
    final tier = _tierNamed(e['tier']?.toString()) ?? _entitledTier;
    final until = e['validUntil'] is num ? (e['validUntil'] as num).toInt() : _validUntil;
    if (tier == SubscriptionTier.community) return;
    if (until > 0 && (tier != _entitledTier || until != _validUntil)) {
      applyServerSubscription(tier.name, until, serverDaysRemaining: days);
    } else {
      _serverDaysRemaining = days;
      notifyListeners();
    }
    _noteExpiring(days, tier, until);
  }

  /// Gateway `SUBSCRIPTION_EXPIRED` `{previousTier, expiredAt}`: roll back right away.
  void handleExpiredEvent(Map<String, dynamic> e) {
    final prev = _tierNamed(e['previousTier']?.toString()) ?? (_isPaid ? _entitledTier : _previousTier);
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
        _entitledTier = SubscriptionTier.values.firstWhere(
          (t) => t.name == tierName,
          orElse: () => SubscriptionTier.community,
        );
      }
      _validUntil = prefs.getInt(keyValidUntil) ?? 0;
      // Older builds stored only one tier: the rider was using what they held.
      _preferredTier = _tierNamed(prefs.getString(keyPreferredTier)) ?? _entitledTier;
      _forceAllUnlocked = prefs.getBool(keyForceUnlocked) ?? false;
      _previousTier = _tierNamed(prefs.getString(keyPreviousTier));
      _expiredAt = prefs.getInt(keyExpiredAt) ?? 0;
      final cachedPlans = prefs.getString(keyConfiguredPlans);
      if (cachedPlans != null && cachedPlans.isNotEmpty) {
        try {
          final decoded = jsonDecode(cachedPlans);
          if (decoded is Map) {
            _configuredPlans = Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
      }
      _syncToFeatureGates();
    } catch (_) {
      // Fallback defaults
    } finally {
      _loaded = true;
      notifyListeners();
    }
    checkExpiry();

    // Background sync pricing & subscription from Gateway API
    if (_api != null) {
      refreshPricingConfig().ignore();
      if (_api.hasToken) {
        syncFromServer().ignore();
      }
    }
  }

  /// Applies live configured plan pricing and persists to local cache.
  void applyConfiguredPlans(Map<String, dynamic> plans) {
    _configuredPlans = Map<String, dynamic>.from(plans);
    _persistPlans(plans);
    notifyListeners();
  }

  void _persistPlans(Map<String, dynamic> plans) {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(keyConfiguredPlans, jsonEncode(plans));
    }).ignore();
  }

  /// Fetches latest public subscription config (plans, prices, gateway mode) from server.
  Future<void> refreshPricingConfig() async {
    if (_api == null) return;
    try {
      final res = await _api.get('/subscription/config');
      if (res is Map && res['plans'] is Map) {
        applyConfiguredPlans(Map<String, dynamic>.from(res['plans']));
      }
    } catch (_) {}
  }

  /// Refreshes authentic subscription status from the backend.
  Future<void> syncFromServer() async {
    refreshPricingConfig().ignore();
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
  /// Updates the entitlement only. A paid tier whose [validUntilEpochMs] is
  /// already past is stored as Community with the paid tier kept as
  /// [previousTier]. A paid tier that is still valid clears any earlier expiry
  /// (the rider renewed). A new or renewed paid plan also becomes the preferred
  /// tier (the rider just paid for it); a re-sync of an unchanged plan leaves
  /// the preference alone, so choosing Community on purpose sticks.
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
    final changed = matched != _entitledTier || until != _validUntil;
    _entitledTier = matched;
    _validUntil = until;
    _forceAllUnlocked = false;
    _serverDaysRemaining = matched == SubscriptionTier.community ? null : serverDaysRemaining;
    if (matched != SubscriptionTier.community) {
      _previousTier = null; // an active paid plan supersedes any earlier expiry
      _expiredAt = 0;
      if (changed) _preferredTier = matched;
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

  /// Chooses the plan to ride with. Only the preference changes: the paid
  /// entitlement ([entitledTier] / [validUntil]) is never touched, so a rider
  /// can drop to Community and come back to the paid plan for free while it is
  /// valid. Returns false, changing nothing, when [tier] is above the
  /// entitlement: the caller then has to open checkout.
  Future<bool> selectTier(SubscriptionTier tier) async {
    if (!_withinEntitlement(tier)) return false;
    _preferredTier = tier;
    _forceAllUnlocked = false;
    if (tier == SubscriptionTier.community && !_isPaid) {
      // Free on purpose after a plan ran out: no longer "expired", just free.
      _previousTier = null;
      _expiredAt = 0;
      _serverDaysRemaining = null;
      _expiringNotice = null;
    }
    _syncToFeatureGates();
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyPreferredTier, tier.name);
      await prefs.setBool(keyForceUnlocked, false);
      if (tier == SubscriptionTier.community && !_isPaid) {
        await prefs.remove(keyPreviousTier);
        await prefs.remove(keyExpiredAt);
      }
    } catch (_) {}
    return true;
  }

  /// Signed out: back to the free tier with no history of a paid plan.
  Future<void> resetLocal() async {
    _entitledTier = SubscriptionTier.community;
    _preferredTier = SubscriptionTier.community;
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
      await prefs.remove(keyPreferredTier);
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
    FeatureGates.activeTier = effectiveTier;
    FeatureGates.forceAllUnlocked = _forceAllUnlocked;
  }

  /// Checks if a feature is unlocked under the current plan.
  bool isUnlocked(Feature feature) => FeatureGates.isUnlocked(feature, effectiveTier);

  /// Current max allowable convoy size.
  int get maxConvoyMembers => FeatureGates.maxConvoyMembers(effectiveTier);

  /// Formats an INR price cleanly (e.g. 50 -> "₹50 / mo", 1199 -> "₹1,199 / yr").
  static String formatPlanPrice(num amount, {required bool isAnnual}) {
    final intVal = amount.toInt();
    final formatted = intVal >= 1000
        ? '₹${intVal ~/ 1000},${(intVal % 1000).toString().padLeft(3, '0')}'
        : '₹$intVal';
    return isAnnual ? '$formatted / yr' : '$formatted / mo';
  }

  /// Sets or updates the dynamically configured plan amounts in memory.
  static void setConfiguredPlans(Map<String, dynamic>? plans) {
    _configuredPlans = plans != null ? Map<String, dynamic>.from(plans) : null;
  }

  /// Returns full plan specifications for all available tiers, with live configured prices if available.
  static List<PlanDetails> get allPlans {
    final base = _basePlans;
    if (_configuredPlans == null || _configuredPlans!.isEmpty) return base;
    return base.map((p) {
      final key = p.tier.name;
      final cfg = _configuredPlans![key];
      if (cfg is Map) {
        final monthly = cfg['monthly'];
        final annual = cfg['annual'];
        final label = cfg['label']?.toString();
        return p.copyWith(
          name: (label != null && label.isNotEmpty) ? label : p.name,
          monthlyPrice: (monthly is num && monthly > 0)
              ? formatPlanPrice(monthly, isAnnual: false)
              : p.monthlyPrice,
          annualPrice: (annual is num && annual > 0)
              ? formatPlanPrice(annual, isAnnual: true)
              : p.annualPrice,
        );
      }
      return p;
    }).toList();
  }

  /// Static baseline plan specifications for all available tiers.
  static List<PlanDetails> get _basePlans => const [
        PlanDetails(
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
        PlanDetails(
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
        PlanDetails(
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
        PlanDetails(
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
