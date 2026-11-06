import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../models/membership_model.dart';
import 'api_client.dart';

/// Short, plain messages for the gateway's coupon refusal reasons
/// (`reason` in the error body of validate-coupon, order, create-order and activate-free).
const Map<String, String> couponReasonMessages = {
  'COUPON_NOT_FOUND': "We couldn't find that code",
  'COUPON_EXPIRED': 'Code expired',
  'COUPON_SCHEDULED': "This code isn't active yet",
  'COUPON_LIMIT_REACHED': 'This code has been fully used',
  'COUPON_USAGE_LIMIT_REACHED': 'This code has been fully used',
  'COUPON_INACTIVE': 'This code is no longer active',
  'COUPON_PAUSED': 'This code is paused right now',
  'COUPON_ARCHIVED': 'This code is no longer active',
  'COUPON_INVALID': "This code can't be used",
  'COUPON_RESERVATION_FAILED': "This code couldn't be applied",
  'COUPON_REQUIRED': 'Enter a code to activate for free',
  'PER_USER_LIMIT_REACHED': "You've already used this code",
  'TIER_MISMATCH': "This code isn't for this plan",
  'CYCLE_MISMATCH': "This code isn't for this billing period",
  'MIN_ORDER_NOT_MET': "This plan doesn't meet the code's minimum amount",
  'PARTIAL_COUPON': "This code doesn't cover the full price",
  'NEW_MEMBERS_ONLY': 'This code is for new members only',
  'FIRST_PAYMENT_ONLY': 'This code is for your first payment only',
  'NOT_ELIGIBLE': "This code isn't available for your account",
  'PLAN_INACTIVE': "This plan isn't on sale right now",
};

/// The plain message for a coupon refusal [reason], or null when it is not a coupon reason.
String? couponErrorMessage(String? reason) => reason == null ? null : couponReasonMessages[reason];

/// True when [reason] means only the code was refused: the rider can still pay the normal price.
bool isCouponRefusal(String? reason) => reason != null && reason != 'PLAN_INACTIVE' && couponReasonMessages.containsKey(reason);

/// The discount in rupees a validate-coupon answer grants on a ₹[basePrice] plan, as the server
/// computed it (`discountAmount`, older `discountInr`, else `discountPercent`). Never more than the
/// price and never assumed: an answer without a discount gives 0.
int couponDiscountRupees(Map<String, dynamic> res, int basePrice) {
  final raw = res['discountAmount'] ?? res['discountInr'];
  var amount = 0;
  if (raw is num) {
    amount = raw.round();
  } else if (res['discountPercent'] is num) {
    amount = (basePrice * (res['discountPercent'] as num) / 100).round();
  }
  if (amount < 0) return 0;
  return amount > basePrice ? basePrice : amount;
}

/// True only when the server itself says the coupon makes this plan free (`isFree`, or a final amount of 0).
bool couponServerConfirmsFree(Map<String, dynamic> res) {
  if (res['valid'] != true) return false;
  if (res['isFree'] == true) return true;
  final fin = res['finalAmount'] ?? res['finalAmountInr'];
  return fin is num && fin == 0;
}

/// Manages CoRoute Membership, Group Seat Entitlements, Two-Role Trip Governance,
/// Single Active Trip concurrency enforcement and secure Razorpay payment lifecycle.
class MembershipService extends ChangeNotifier {
  final ApiClient _api;
  SharedPreferences? _prefs;

  MembershipCatalog? _catalog;
  MyMembershipOverview? _myOverview;
  List<MembershipPaymentItem> _paymentHistory = const [];
  bool _isLoading = false;
  bool _isVerifying = false;
  String? _lastError;
  String? _lastErrorReason;

  Future<Map<String, dynamic>?>? _inFlightOrderFuture;
  String? _inFlightOrderKey;

  MembershipCatalog? get catalog => _catalog;
  MyMembershipOverview? get myOverview => _myOverview;
  UserMembership? get ownedMembership => _myOverview?.ownedMembership;
  List<UserMembership> get participating => _myOverview?.participating ?? const [];
  ActiveTripLock? get activeTrip => _myOverview?.activeTrip;
  List<MembershipPaymentItem> get paymentHistory => _paymentHistory;
  bool get paymentsEnabled => _myOverview?.paymentsEnabled ?? true;
  bool get isLoading => _isLoading;
  bool get isVerifying => _isVerifying;
  String? get lastError => _lastError;

  /// The gateway's machine-readable reason for the last refusal (for example PER_USER_LIMIT_REACHED).
  String? get lastErrorReason => _lastErrorReason;

  /// True when the last call failed only because of the coupon: the rider can pay the normal price.
  bool get lastErrorIsCouponRefusal => isCouponRefusal(_lastErrorReason);

  /// Records [e] as the last error: a coupon refusal gets its short plain message.
  void _recordError(Object e, String fallback) {
    if (e is ApiException) {
      _lastErrorReason = e.reason;
      _lastError = couponErrorMessage(e.reason) ?? e.message;
    } else {
      _lastErrorReason = null;
      _lastError = fallback;
    }
  }

  /// Authoritatively recognizes whether the rider has an active plan with valid capacity (ISSUE-10).
  bool get hasActivePlan {
    final owned = ownedMembership;
    return owned != null && !owned.isExpired && owned.capacity >= 1;
  }

  MembershipService(this._api, [this._prefs]) {
    _initCache();
  }

  Future<void> _initCache() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _loadFromCache();
    } catch (e) {
      debugPrint('[MembershipService] _initCache error: $e');
    }
  }

  Future<void> _loadFromCache() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final cachedJson = _prefs?.getString(AppConstants.keyMembershipCache);
      if (cachedJson != null && cachedJson.isNotEmpty) {
        final decoded = jsonDecode(cachedJson);
        if (decoded is Map<String, dynamic>) {
          final loadedOverview = MyMembershipOverview.fromJson(decoded);
          if (_myOverview == null) {
            _myOverview = loadedOverview;
            notifyListeners();
          }
        }
      }

      final cachedCatJson = _prefs?.getString(AppConstants.keyMembershipCatalogCache);
      if (cachedCatJson != null && cachedCatJson.isNotEmpty) {
        final decodedCat = jsonDecode(cachedCatJson);
        if (decodedCat is Map<String, dynamic>) {
          if (_catalog == null) {
            _catalog = MembershipCatalog.fromJson(decodedCat);
            notifyListeners();
          }
        }
      }
    } catch (e) {
      debugPrint('[MembershipService] _loadFromCache error: $e');
    }
  }

  Future<void> _saveToCache(MyMembershipOverview? overview) async {
    if (overview == null) return;
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final str = jsonEncode(overview.toJson());
      await _prefs?.setString(AppConstants.keyMembershipCache, str);
    } catch (e) {
      debugPrint('[MembershipService] _saveToCache error: $e');
    }
  }

  Future<void> _saveCatalogToCache(MembershipCatalog? cat) async {
    if (cat == null) return;
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final str = jsonEncode(cat.toJson());
      await _prefs?.setString(AppConstants.keyMembershipCatalogCache, str);
    } catch (e) {
      debugPrint('[MembershipService] _saveCatalogToCache error: $e');
    }
  }

  /// Fetch public or cached membership catalog.
  Future<MembershipCatalog?> fetchCatalog() async {
    try {
      final res = await _api.get('/membership/catalog');
      if (res is Map) {
        _catalog = MembershipCatalog.fromJson(Map<String, dynamic>.from(res));
        await _saveCatalogToCache(_catalog);
        notifyListeners();
        return _catalog;
      }
    } catch (e) {
      debugPrint('[MembershipService] fetchCatalog error: $e');
      if (_catalog == null) {
        await _loadFromCache();
      }
    }
    return _catalog;
  }

  /// Fetch active membership, participating groups, and active trip lock for authenticated rider.
  /// Durable offline caching: When backend is temporarily slow/offline or returns a transient error,
  /// do NOT classify a known active membership as expired! Use local cached entitlement.
  Future<MyMembershipOverview?> fetchMyMembership() async {
    _isLoading = true;
    _isVerifying = true;
    _lastError = null;
    notifyListeners();

    if (_myOverview == null) {
      await _loadFromCache();
    }

    try {
      final res = await _api.get('/membership/my');
      if (res is Map) {
        _myOverview = MyMembershipOverview.fromJson(Map<String, dynamic>.from(res));
        await _saveToCache(_myOverview);
      }
    } catch (e) {
      debugPrint('[MembershipService] fetchMyMembership error: $e');
      if (e is ApiException) _lastError = e.message;
      // When backend fails, preserve cached entitlement
      if (_myOverview == null) {
        await _loadFromCache();
      }
    } finally {
      _isLoading = false;
      _isVerifying = false;
      notifyListeners();
    }
    return _myOverview;
  }

  /// Create a server-authoritative Razorpay order for membership checkout.
  /// No code is sent unless the rider entered one. When the server prices the order at ₹0
  /// (a 100% coupon it accepted) it answers `isFree` and has already activated the membership.
  /// Deduplicates concurrent in-flight requests to never open duplicate payment orders.
  Future<Map<String, dynamic>?> createOrder({
    required String categoryId,
    String? offerCode,
  }) async {
    final cleanOffer = offerCode?.trim().toUpperCase();
    final orderKey = '$categoryId:${cleanOffer ?? ""}';

    if (_inFlightOrderFuture != null && _inFlightOrderKey == orderKey) {
      debugPrint('[MembershipService] Duplicate createOrder prevented for $orderKey; returning existing future.');
      return _inFlightOrderFuture;
    }

    _inFlightOrderKey = orderKey;
    _inFlightOrderFuture = _executeCreateOrder(categoryId: categoryId, offerCode: cleanOffer);

    try {
      return await _inFlightOrderFuture;
    } finally {
      _inFlightOrderFuture = null;
      _inFlightOrderKey = null;
    }
  }

  Future<Map<String, dynamic>?> _executeCreateOrder({
    required String categoryId,
    String? offerCode,
  }) async {
    _isLoading = true;
    _lastError = null;
    _lastErrorReason = null;
    notifyListeners();
    try {
      final body = <String, dynamic>{
        'category': categoryId,
        'categoryId': categoryId,
        if (offerCode != null && offerCode.isNotEmpty) 'offerCode': offerCode,
      };
      final res = await _api.post('/membership/order', body);
      if (res is Map) {
        final data = Map<String, dynamic>.from(res);
        if (data['isFree'] == true) {
          await fetchMyMembership();
        }
        return data;
      }
    } catch (e) {
      debugPrint('[MembershipService] createOrder error: $e');
      _recordError(e, 'Order creation failed. Please check your internet connection.');
      notifyListeners();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
    return null;
  }

  /// Cryptographically verify Razorpay payment and activate membership.
  Future<UserMembership?> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    _isLoading = true;
    _lastError = null;
    notifyListeners();
    try {
      final body = <String, dynamic>{
        'orderId': orderId,
        'paymentId': paymentId,
        'signature': signature,
      };
      final res = await _api.post('/membership/verify', body);
      if (res is Map && res['membership'] is Map) {
        final mem = UserMembership.fromJson(Map<String, dynamic>.from(res['membership'] as Map));
        await fetchMyMembership();
        await fetchPaymentHistory();
        return mem;
      }
    } catch (e) {
      debugPrint('[MembershipService] verifyPayment error: $e');
      if (e is ApiException) {
        _lastError = e.message;
      } else {
        _lastError = 'Payment verification failed.';
      }
      notifyListeners();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
    return null;
  }

  /// Fetch user's payment and transaction history from ledger.
  Future<List<MembershipPaymentItem>> fetchPaymentHistory() async {
    try {
      final res = await _api.get('/membership/payments');
      if (res is Map && res['payments'] is List) {
        _paymentHistory = (res['payments'] as List<dynamic>)
            .whereType<Map>()
            .map((e) => MembershipPaymentItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        notifyListeners();
        return _paymentHistory;
      }
    } catch (e) {
      debugPrint('[MembershipService] fetchPaymentHistory error: $e');
    }
    return _paymentHistory;
  }

  /// Validate coupon against a membership category on backend.
  /// Returns coupon discount data, or null with lastError (a short plain message) and
  /// lastErrorReason populated on rejection.
  Future<Map<String, dynamic>?> validateCoupon({
    required String code,
    required String categoryId,
  }) async {
    _lastError = null;
    _lastErrorReason = null;
    try {
      final body = {
        'code': code.trim().toUpperCase(),
        'category': categoryId,
      };
      final res = await _api.post('/membership/validate-coupon', body);
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
    } catch (e) {
      debugPrint('[MembershipService] validateCoupon error: $e');
      _recordError(e, 'Coupon validation failed.');
    }
    return null;
  }

  /// Activate zero-amount membership directly through backend authorization.
  /// No Razorpay order or checkout is created. Call it only after the server confirmed the
  /// coupon makes the plan free; the server checks the coupon again and may still refuse it.
  Future<UserMembership?> activateFreeMembership({
    required String categoryId,
    required String couponCode,
  }) async {
    _isLoading = true;
    _lastError = null;
    _lastErrorReason = null;
    notifyListeners();
    try {
      final body = {
        'category': categoryId,
        'couponCode': couponCode.trim().toUpperCase(),
      };
      final res = await _api.post('/membership/activate-free', body);
      if (res is Map && res['membership'] is Map) {
        final mem = UserMembership.fromJson(Map<String, dynamic>.from(res['membership'] as Map));
        await fetchMyMembership();
        await fetchPaymentHistory();
        return mem;
      }
    } catch (e) {
      debugPrint('[MembershipService] activateFreeMembership error: $e');
      _recordError(e, 'Membership activation failed. Please try again.');
      notifyListeners();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
    return null;
  }

  /// Purchase or claim an introductory offer for a membership category (legacy or direct wrapper).
  Future<UserMembership?> purchaseMembership({
    required String categoryId,
    String? offerCode,
    String? paymentId,
    String? orderId,
    String? signature,
  }) async {
    _isLoading = true;
    _lastError = null;
    notifyListeners();
    try {
      final body = <String, dynamic>{
        'categoryId': categoryId,
        'category': categoryId,
        if (offerCode != null && offerCode.trim().isNotEmpty)
          'offerCode': offerCode.trim().toUpperCase(),
        if (paymentId != null && paymentId.trim().isNotEmpty) 'paymentId': paymentId.trim(),
        if (orderId != null && orderId.trim().isNotEmpty) 'orderId': orderId.trim(),
        if (signature != null && signature.trim().isNotEmpty) 'signature': signature.trim(),
      };
      final res = await _api.post('/membership/purchase', body);
      if (res is Map && res['membership'] is Map) {
        final mem = UserMembership.fromJson(Map<String, dynamic>.from(res['membership'] as Map));
        await fetchMyMembership();
        return mem;
      }
    } catch (e) {
      debugPrint('[MembershipService] purchaseMembership error: $e');
      if (e is ApiException) {
        _lastError = e.message;
      } else {
        _lastError = 'Membership activation failed. Please try again.';
      }
      notifyListeners();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
    return null;
  }

  /// Trip Owner invites a participant by email or phone. Enforces capacity on backend.
  Future<bool> inviteMember(String identifier) async {
    _lastError = null;
    try {
      final id = identifier.trim();
      final res = await _api.post('/membership/members/invite', {
        'identifier': id,
        'email': id.contains('@') ? id : null,
        'userId': !id.contains('@') ? id : null,
      });
      if (res is Map && (res['ok'] == true || res['message'] != null || res['members'] != null)) {
        await fetchMyMembership();
        return true;
      }
    } catch (e) {
      debugPrint('[MembershipService] inviteMember error: $e');
      if (e is ApiException) {
        _lastError = e.message;
      } else {
        _lastError = 'Failed to send invitation.';
      }
      notifyListeners();
    }
    return false;
  }

  /// Invited rider accepts or declines membership trip invitation.
  Future<bool> respondInvitation({required String membershipId, required bool accept}) async {
    _lastError = null;
    try {
      final res = await _api.post('/membership/members/respond', {
        'membershipId': membershipId,
        'action': accept ? 'ACCEPT' : 'DECLINE',
        'accept': accept,
      });
      if (res is Map && (res['ok'] == true || res['message'] != null)) {
        await fetchMyMembership();
        return true;
      }
    } catch (e) {
      debugPrint('[MembershipService] respondInvitation error: $e');
      if (e is ApiException) _lastError = e.message;
      notifyListeners();
    }
    return false;
  }

  /// Trip Owner removes a participant from the membership (and active trip).
  Future<bool> removeMember(String targetUserId) async {
    _lastError = null;
    try {
      final res = await _api.delete('/membership/members/$targetUserId');
      if (res is Map && (res['ok'] == true || res['message'] != null || res['members'] != null)) {
        await fetchMyMembership();
        return true;
      }
    } catch (e) {
      debugPrint('[MembershipService] removeMember error: $e');
      if (e is ApiException) _lastError = e.message;
      notifyListeners();
    }
    return false;
  }

  // =========================================================================
  // PLATFORM ADMIN METHODS
  // =========================================================================

  /// Admin: fetch dynamic catalog config.
  Future<Map<String, dynamic>?> fetchAdminCatalog() async {
    try {
      final res = await _api.get('/admin/membership/catalog');
      if (res is Map) return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('[MembershipService] fetchAdminCatalog error: $e');
    }
    return null;
  }

  /// Admin: update dynamic catalog config.
  Future<bool> updateAdminCatalog(Map<String, dynamic> catalogData) async {
    try {
      final res = await _api.put('/admin/membership/catalog', catalogData);
      if (res is Map && (res['ok'] == true || res['message'] != null)) {
        await fetchCatalog();
        return true;
      }
    } catch (e) {
      debugPrint('[MembershipService] updateAdminCatalog error: $e');
    }
    return false;
  }

  /// Admin: fetch all memberships across the platform.
  Future<List<Map<String, dynamic>>> fetchAdminMemberships({int limit = 100}) async {
    try {
      final res = await _api.get('/admin/membership/memberships?limit=$limit');
      if (res is Map && res['memberships'] is List) {
        return (res['memberships'] as List<dynamic>)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      debugPrint('[MembershipService] fetchAdminMemberships error: $e');
    }
    return [];
  }

  /// Admin: fetch all payment transactions from ledger.
  Future<List<Map<String, dynamic>>> fetchAdminPayments({int limit = 100}) async {
    try {
      final res = await _api.get('/admin/membership/payments?limit=$limit');
      if (res is Map && res['payments'] is List) {
        return (res['payments'] as List<dynamic>)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      debugPrint('[MembershipService] fetchAdminPayments error: $e');
    }
    return [];
  }

  /// Admin: refund a paid order via Razorpay API and revoke/update membership.
  Future<bool> adminRefundPayment({
    required String orderId,
    int? amountInPaise,
    String? reason,
  }) async {
    try {
      final body = <String, dynamic>{
        'amountInPaise': ?amountInPaise,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      };
      final res = await _api.post('/admin/membership/payments/$orderId/refund', body);
      if (res is Map && res['ok'] == true) {
        return true;
      }
    } catch (e) {
      debugPrint('[MembershipService] adminRefundPayment error: $e');
    }
    return false;
  }

  /// Admin: fetch privacy-safe aggregate analytics.
  Future<Map<String, dynamic>?> fetchAdminAnalytics() async {
    try {
      final res = await _api.get('/admin/membership/analytics');
      if (res is Map) return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('[MembershipService] fetchAdminAnalytics error: $e');
    }
    return null;
  }
}
