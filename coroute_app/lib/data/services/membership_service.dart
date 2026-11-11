import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../domain/membership/plan_gate_messages.dart';
import '../../domain/membership/ride_capabilities.dart';
import '../models/membership_model.dart';
import 'api_client.dart';

/// Reads the rider's CoRoute plan (membership, seats, active trip lock) from the server and keeps a
/// cached copy for offline use. Play payments policy (docs/features_355/play_payments_policy.md):
/// the app is consumption-only. It never sells, prices or links to buying a plan; plans are
/// managed in the rider's CoRoute account and the app only re-reads them ([fetchMyMembership],
/// also on the SUBSCRIPTION_* socket / push events).
class MembershipService extends ChangeNotifier {
  final ApiClient _api;
  SharedPreferences? _prefs;

  MembershipCatalog? _catalog;
  MyMembershipOverview? _myOverview;
  bool _isLoading = false;
  bool _isVerifying = false;
  String? _lastError;

  MembershipCatalog? get catalog => _catalog;
  MyMembershipOverview? get myOverview => _myOverview;
  UserMembership? get ownedMembership => _myOverview?.ownedMembership;
  List<UserMembership> get participating => _myOverview?.participating ?? const [];
  ActiveTripLock? get activeTrip => _myOverview?.activeTrip;

  /// False when the server runs without plans (every rider may host): the app then shows no plan UI.
  bool get plansEnforced => _myOverview?.plansEnforced ?? true;
  bool get isLoading => _isLoading;
  bool get isVerifying => _isVerifying;
  String? get lastError => _lastError;

  /// Authoritatively recognizes whether the rider has an active plan with valid capacity (ISSUE-10):
  /// a membership, or a legacy tier until its end date.
  bool get hasActivePlan => planAccess.isPaid;

  /// The rider's plan (the single source for hosting, seats and the home status line). Every rider
  /// has at least Community (free, solo rides), also before the server answered.
  PlanAccess get planAccess => _myOverview?.planAccess ?? PlanAccess.community;

  /// 3.56 what the rider may host now (admin access mode, decided by the gateway). Null from an
  /// older gateway. Never carries a plan, a mode or a price.
  RideCapabilities? get capabilities => _myOverview?.capabilities;

  /// The one answer for "may this rider start a group ride others join": the gateway's capabilities
  /// when it sent them, else the plan (or plans off on the server).
  bool get canHostGroup => !plansEnforced || (capabilities?.canHostGroup ?? planAccess.canHostGroup);

  /// The neutral line for why hosting is limited now, or null (PlanGateMessages.forCapabilities).
  String? get hostingLimitMessage {
    final c = capabilities;
    if (c == null) return plansEnforced && !planAccess.canHostGroup ? PlanGateMessages.hostingNeedsGroupPlan : null;
    return PlanGateMessages.forCapabilities(c);
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

  /// Sign-out: forgets this account's plan and cached overview (the catalog stays).
  Future<void> clearLocal() async {
    _myOverview = null;
    _lastError = null;
    notifyListeners();
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.remove(AppConstants.keyMembershipCache);
    } catch (e) {
      debugPrint('[MembershipService] clearLocal error: $e');
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
}
