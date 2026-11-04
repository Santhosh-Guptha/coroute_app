import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/membership_model.dart';
import 'api_client.dart';

/// Manages CoRoute Membership, Group Seat Entitlements, Two-Role Trip Governance,
/// Single Active Trip concurrency enforcement and secure Razorpay payment lifecycle.
class MembershipService extends ChangeNotifier {
  final ApiClient _api;

  MembershipCatalog? _catalog;
  MyMembershipOverview? _myOverview;
  List<MembershipPaymentItem> _paymentHistory = const [];
  bool _isLoading = false;
  String? _lastError;

  MembershipCatalog? get catalog => _catalog;
  MyMembershipOverview? get myOverview => _myOverview;
  UserMembership? get ownedMembership => _myOverview?.ownedMembership;
  List<UserMembership> get participating => _myOverview?.participating ?? const [];
  ActiveTripLock? get activeTrip => _myOverview?.activeTrip;
  List<MembershipPaymentItem> get paymentHistory => _paymentHistory;
  bool get paymentsEnabled => _myOverview?.paymentsEnabled ?? true;
  bool get isLoading => _isLoading;
  String? get lastError => _lastError;

  MembershipService(this._api);

  /// Fetch public or cached membership catalog.
  Future<MembershipCatalog?> fetchCatalog() async {
    try {
      final res = await _api.get('/membership/catalog');
      if (res is Map) {
        _catalog = MembershipCatalog.fromJson(Map<String, dynamic>.from(res));
        notifyListeners();
        return _catalog;
      }
    } catch (e) {
      debugPrint('[MembershipService] fetchCatalog error: $e');
    }
    return _catalog;
  }

  /// Fetch active membership, participating groups, and active trip lock for authenticated rider.
  Future<MyMembershipOverview?> fetchMyMembership() async {
    _isLoading = true;
    _lastError = null;
    notifyListeners();
    try {
      final res = await _api.get('/membership/my');
      if (res is Map) {
        _myOverview = MyMembershipOverview.fromJson(Map<String, dynamic>.from(res));
      }
    } catch (e) {
      debugPrint('[MembershipService] fetchMyMembership error: $e');
      if (e is ApiException) _lastError = e.message;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
    return _myOverview;
  }

  /// Create a server-authoritative Razorpay order for membership checkout.
  /// If amount is ₹0 (e.g. RIDERFREE), order is immediately activated on backend.
  Future<Map<String, dynamic>?> createOrder({
    required String categoryId,
    String? offerCode,
  }) async {
    _isLoading = true;
    _lastError = null;
    notifyListeners();
    try {
      final body = <String, dynamic>{
        'category': categoryId,
        'categoryId': categoryId,
        if (offerCode != null && offerCode.trim().isNotEmpty)
          'offerCode': offerCode.trim().toUpperCase(),
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
      if (e is ApiException) {
        _lastError = e.message;
      } else {
        _lastError = 'Order creation failed. Please check your internet connection.';
      }
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
  /// Returns coupon discount data, or null with lastError populated on rejection.
  Future<Map<String, dynamic>?> validateCoupon({
    required String code,
    required String categoryId,
  }) async {
    _lastError = null;
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
      if (e is ApiException) {
        _lastError = e.message;
      } else {
        _lastError = 'Coupon validation failed.';
      }
    }
    return null;
  }

  /// Activate zero-amount membership directly through backend authorization.
  /// No Razorpay order or checkout is created.
  Future<UserMembership?> activateFreeMembership({
    required String categoryId,
    required String couponCode,
  }) async {
    _isLoading = true;
    _lastError = null;
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
        if (amountInPaise != null) 'amountInPaise': amountInPaise,
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
