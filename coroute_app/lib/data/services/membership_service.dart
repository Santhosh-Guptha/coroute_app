import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/membership_model.dart';
import 'api_client.dart';

/// Manages CoRoute Membership, Group Seat Entitlements, Two-Role Trip Governance
/// and Single Active Trip concurrency enforcement.
class MembershipService extends ChangeNotifier {
  final ApiClient _api;

  MembershipCatalog? _catalog;
  MyMembershipOverview? _myOverview;
  bool _isLoading = false;
  String? _lastError;

  MembershipCatalog? get catalog => _catalog;
  MyMembershipOverview? get myOverview => _myOverview;
  UserMembership? get ownedMembership => _myOverview?.ownedMembership;
  List<UserMembership> get participating => _myOverview?.participating ?? const [];
  ActiveTripLock? get activeTrip => _myOverview?.activeTrip;
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

  /// Purchase or claim an introductory offer for a membership category.
  Future<UserMembership?> purchaseMembership({
    required String categoryId,
    String? offerCode,
    String? paymentId,
  }) async {
    _isLoading = true;
    _lastError = null;
    notifyListeners();
    try {
      final body = <String, dynamic>{
        'categoryId': categoryId,
        if (offerCode != null && offerCode.trim().isNotEmpty) 'offerCode': offerCode.trim().toUpperCase(),
        if (paymentId != null && paymentId.trim().isNotEmpty) 'paymentId': paymentId.trim(),
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
      final res = await _api.post('/membership/members/invite', {
        'identifier': identifier.trim(),
      });
      if (res is Map && res['ok'] == true) {
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
        'accept': accept,
      });
      if (res is Map && res['ok'] == true) {
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
      if (res is Map && res['ok'] == true) {
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
      if (res is Map && res['ok'] == true) {
        await fetchCatalog();
        return true;
      }
    } catch (e) {
      debugPrint('[MembershipService] updateAdminCatalog error: $e');
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

