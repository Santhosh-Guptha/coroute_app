import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import 'api_client.dart';

/// Account state. Registration (email + password, or Google) is mandatory;
/// there is no guest mode. Roles come from the database, not from the app.
class AuthService extends ChangeNotifier {
  AuthService(this._api) {
    _api.addListener(_onApiChanged);
    _loadSavedSession();
  }

  /// The API client dropped the token because the gateway ended the session.
  void _onApiChanged() {
    if (!_api.hasToken && _userId != null && !_isLoading) {
      _lastSignOutReason = _api.lastSessionEndMessage ?? _lastSignOutReason;
      _clearSession().ignore();
    }
  }

  String? _lastSignOutReason;

  /// Why the gateway ended the last session (hold, block, deleted, signed out elsewhere).
  /// Shown once on the sign-in screen, then cleared with [clearSignOutReason].
  String? get lastSignOutReason => _lastSignOutReason;
  void clearSignOutReason() {
    _lastSignOutReason = null;
    _api.lastSessionEndMessage = null;
  }

  /// Admin rights come only from the role the server stored for this account.
  static bool roleIsAdmin(String? role) => role == AppConstants.adminRole;

  @override
  void dispose() {
    _api.removeListener(_onApiChanged);
    super.dispose();
  }

  final ApiClient _api;
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: const ['email', 'profile'],
    serverClientId: AppConfig.googleWebClientId.isEmpty ? null : AppConfig.googleWebClientId,
  );

  String? _userId;
  String? _role;
  String? _email;
  String? _name;
  String? _vehicleType;
  String? _phone;
  String? _emergencyContact;
  String? _emergencyContactName;
  String? _vehicleNo;
  bool _isLoading = true;
  bool _mustChangePassword = false;

  String? get currentUserId => _userId;
  String? get currentUserRole => _role;
  String? get currentUserEmail => _email;
  String? get currentUserName => _name;
  String? get vehicleType => _vehicleType;
  String? get phone => _phone;
  String? get emergencyContact => _emergencyContact;
  String? get emergencyContactName => _emergencyContactName;
  String? get vehicleNo => _vehicleNo;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _api.hasToken && _userId != null;
  bool get isMasterAdmin => roleIsAdmin(_role);

  /// True if the user is registered or designated as a pillion passenger.
  bool get isPillion =>
      (_vehicleType ?? '').trim().toLowerCase() == 'pillion rider' ||
      (_vehicleNo ?? '').trim().toUpperCase() == 'PILLION';

  /// Mandatory safety invariant:
  /// Every rider must have verified contact numbers, bike registration (or pillion status),
  /// and emergency (ICE) contacts before creating or participating in group rides.
  bool get isProfileComplete {
    if (isMasterAdmin) return true;
    final nameOk = (_name ?? '').trim().length >= 2;
    final emailOk = (_email ?? '').trim().contains('@');
    final phoneOk = (_phone ?? '').trim().length >= 7;
    final pillion = isPillion;
    final vehicleOk = pillion || (_vehicleNo ?? '').trim().length >= 3;
    final iceNameOk = (_emergencyContactName ?? '').trim().length >= 2;
    final icePhoneOk = (_emergencyContact ?? '').trim().length >= 7;
    return nameOk && emailOk && phoneOk && vehicleOk && iceNameOk && icePhoneOk;
  }

  String? get token => _api.token;

  Future<void> _loadSavedSession() async {
    await _api.init();
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString(AppConstants.keyUserId);
    _email = prefs.getString(AppConstants.keyUserEmail);
    _role = prefs.getString(AppConstants.keyUserRole);
    _name = prefs.getString(AppConstants.keyUserName);
    _vehicleType = prefs.getString(AppConstants.keyVehicleType) ?? 'Motorcycle';
    _phone = prefs.getString(AppConstants.keyPhone) ?? '';
    _emergencyContact = prefs.getString(AppConstants.keyEmergencyContact) ?? '';
    _emergencyContactName = prefs.getString(AppConstants.keyEmergencyName) ?? '';
    _vehicleNo = prefs.getString(AppConstants.keyVehicleNo) ?? '';
    _isLoading = false;
    notifyListeners();

    // Refresh the profile (and role) from the server in the background.
    if (_api.hasToken && _userId != null) {
      try {
        final me = await _api.get('/me');
        if (me is Map) await _applyUser(Map<String, dynamic>.from(me));
      } on ApiException catch (e) {
        if (e.endsSession) {
          // Revoked token, deleted, held or blocked account, as stated by the gateway.
          _lastSignOutReason = e.message;
          await _clearSession();
        }
      } catch (_) {}
    }
  }

  /// Called when the realtime link was refused at connect. Asks the server
  /// whether the session is still valid; signs out only if it says no.
  Future<void> revalidate() async {
    if (!_api.hasToken) return;
    try {
      final me = await _api.get('/me');
      if (me is Map) await _applyUser(Map<String, dynamic>.from(me));
    } on ApiException catch (e) {
      if (e.endsSession) {
        _lastSignOutReason = e.message;
        await _clearSession();
      }
    } catch (_) {}
  }

  Future<void> _applyUser(Map<String, dynamic> u) async {
    _userId = u['userId']?.toString();
    _email = u['email']?.toString();
    _role = u['role']?.toString() ?? AppConstants.riderRole;
    _name = u['name']?.toString();
    _vehicleType = u['vehicleType']?.toString() ?? 'Motorcycle';
    _phone = u['phone']?.toString() ?? '';
    _vehicleNo = u['vehicleNo']?.toString() ?? '';
    _emergencyContact = u['emergencyContact']?.toString() ?? '';
    _emergencyContactName = u['emergencyContactName']?.toString() ?? '';
    _mustChangePassword = u['mustChangePassword'] == true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.keyUserId, _userId ?? '');
    await prefs.setString(AppConstants.keyUserRole, _role ?? '');
    await prefs.setString(AppConstants.keyUserEmail, _email ?? '');
    await prefs.setString(AppConstants.keyUserName, _name ?? '');
    await prefs.setString(AppConstants.keyVehicleType, _vehicleType ?? '');
    await prefs.setString(AppConstants.keyPhone, _phone ?? '');
    await prefs.setString(AppConstants.keyVehicleNo, _vehicleNo ?? '');
    await prefs.setString(AppConstants.keyEmergencyContact, _emergencyContact ?? '');
    await prefs.setString(AppConstants.keyEmergencyName, _emergencyContactName ?? '');
    notifyListeners();
  }

  bool get mustChangePassword => _mustChangePassword;

  Map<String, dynamic> _ok() => {'success': true, 'isAdmin': isMasterAdmin, 'userId': _userId, 'name': _name, 'mustChangePassword': _mustChangePassword};
  Map<String, dynamic> _fail(Object e) =>
      {'success': false, 'error': e is ApiException ? e.message : 'Something went wrong. Please try again.'};

  Future<Map<String, dynamic>> _consume(dynamic res) async {
    if (res is! Map || res['token'] == null || res['user'] is! Map) {
      return {'success': false, 'error': 'Unexpected server response.'};
    }
    clearSignOutReason();
    await _api.setToken(res['token'].toString());
    await _applyUser(Map<String, dynamic>.from(res['user'] as Map));
    return _ok();
  }

  /// Register a brand-new rider account.
  Future<Map<String, dynamic>> registerRider({
    required String name,
    required String email,
    required String password,
    required String phone,
    String vehicleType = 'Motorcycle (Adv)',
    String vehicleNo = '',
    String emergencyContact = '',
    String emergencyContactName = '',
  }) async {
    try {
      final res = await _api.post('/auth/register', {
        'name': name.trim(),
        'email': email.trim(),
        'password': password,
        'phone': phone.trim(),
        'vehicleType': vehicleType.trim(),
        'vehicleNo': vehicleNo.trim(),
        'emergencyContact': emergencyContact.trim(),
        'emergencyContactName': emergencyContactName.trim(),
      }, const Duration(seconds: 15), false);
      return await _consume(res);
    } catch (e) {
      return _fail(e);
    }
  }

  /// Sign in with email or callsign + password.
  Future<Map<String, dynamic>> loginRiderWithPassword({required String identifier, required String password}) async {
    try {
      final res = await _api.post('/auth/login', {'identifier': identifier.trim(), 'password': password}, const Duration(seconds: 15), false);
      return await _consume(res);
    } catch (e) {
      return _fail(e);
    }
  }

  /// Google Sign-In: the ID token is verified by the gateway, which issues our JWT.
  Future<Map<String, dynamic>> signInWithGoogle() async {
    try {
      try {
        await _googleSignIn.signOut();
      } catch (_) {}
      final account = await _googleSignIn.signIn();
      if (account == null) return {'success': false, 'error': 'Google Sign-In cancelled.'};
      final gAuth = await account.authentication;
      final idToken = gAuth.idToken;
      if (idToken == null || idToken.isEmpty) {
        return {'success': false, 'error': 'Google did not return an ID token. Check the OAuth client configuration.'};
      }
      final res = await _api.post('/auth/google', {'idToken': idToken}, const Duration(seconds: 15), false);
      return await _consume(res);
    } catch (e) {
      debugPrint('Google Sign-In note: $e');
      return _fail(e);
    }
  }

  String? _lastProfileError;

  /// The server's reason the last profile update was refused (for example "That callsign is
  /// taken."), or null when it failed for network reasons or succeeded.
  String? get lastProfileError => _lastProfileError;

  /// Update rider profile details (server is the source of truth).
  Future<bool> updateProfile({
    required String phone,
    required String vehicleType,
    required String vehicleNo,
    required String emergencyContact,
    required String emergencyContactName,
    String? name,
  }) async {
    try {
      final payload = <String, dynamic>{
        'phone': phone.trim(),
        'vehicleType': vehicleType.trim(),
        'vehicleNo': vehicleNo.trim().toUpperCase(),
        'emergencyContact': emergencyContact.trim(),
        'emergencyContactName': emergencyContactName.trim(),
      };
      if (name != null && name.trim().isNotEmpty) {
        payload['name'] = name.trim();
      }
      _lastProfileError = null;
      final res = await _api.patch('/me', payload);
      if (res is Map) await _applyUser(Map<String, dynamic>.from(res));
      return true;
    } on ApiException catch (e) {
      debugPrint('updateProfile note: $e');
      // Validation answers (422 / 409) carry a message for the rider; outages do not.
      _lastProfileError = (e.statusCode >= 400 && e.statusCode < 500 && !e.isUnauthorized) ? e.message : null;
      return false;
    } catch (e) {
      debugPrint('updateProfile note: $e');
      _lastProfileError = null;
      return false;
    }
  }

  /// Change password. [currentPassword] may be empty when the server issued a temporary one.
  Future<Map<String, dynamic>> changePassword({required String currentPassword, required String newPassword}) async {
    try {
      final res = await _api.post('/me/password', {'currentPassword': currentPassword, 'newPassword': newPassword});
      // The server ends every other session and hands this phone a fresh token.
      final fresh = res is Map ? res['token']?.toString() : null;
      if (fresh != null && fresh.isNotEmpty) await _api.setToken(fresh);
      _mustChangePassword = false;
      notifyListeners();
      return {'success': true};
    } catch (e) {
      return _fail(e);
    }
  }

  /// Permanently deletes the account and all data tied to it, then signs out.
  Future<Map<String, dynamic>> deleteAccount() async {
    try {
      await _api.delete('/me');
      await _clearSession();
      return {'success': true};
    } catch (e) {
      return _fail(e);
    }
  }

  Future<void> logout() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    await _clearSession();
  }

  bool _clearing = false;

  Future<void> _clearSession() async {
    if (_clearing) return;
    _clearing = true;
    _userId = null; // first, so the API listener does not re-enter
    await _api.setToken(null);
    _role = null;
    _email = null;
    _name = null;
    _vehicleType = null;
    _phone = null;
    _emergencyContact = null;
    _emergencyContactName = null;
    _vehicleNo = null;
    _mustChangePassword = false;
    final prefs = await SharedPreferences.getInstance();
    for (final k in [
      AppConstants.keyUserId, AppConstants.keyUserRole, AppConstants.keyUserEmail, AppConstants.keyUserName,
      AppConstants.keyVehicleType, AppConstants.keyActiveGroupId, AppConstants.keyPhone, AppConstants.keyVehicleNo,
      AppConstants.keyEmergencyContact, AppConstants.keyEmergencyName,
    ]) {
      await prefs.remove(k);
    }
    _clearing = false;
    notifyListeners();
  }
}
