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
    _loadSavedSession();
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
  bool get isMasterAdmin => _role == AppConstants.adminRole;
  String? get token => _api.token;

  Future<void> _loadSavedSession() async {
    await _api.init();
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString(AppConstants.keyUserId);
    _role = prefs.getString(AppConstants.keyUserRole);
    _email = prefs.getString(AppConstants.keyUserEmail);
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
        if (e.isUnauthorized) await _clearSession();
      } catch (_) {}
    }
  }

  Future<void> _applyUser(Map<String, dynamic> u) async {
    _userId = u['userId']?.toString();
    _role = u['role']?.toString() ?? AppConstants.riderRole;
    _email = u['email']?.toString();
    _name = u['name']?.toString();
    _vehicleType = u['vehicleType']?.toString() ?? 'Motorcycle';
    _phone = u['phone']?.toString() ?? '';
    _vehicleNo = u['vehicleNo']?.toString() ?? '';
    _emergencyContact = u['emergencyContact']?.toString() ?? '';
    _emergencyContactName = u['emergencyContactName']?.toString() ?? '';

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

  Map<String, dynamic> _ok() => {'success': true, 'isAdmin': isMasterAdmin, 'userId': _userId, 'name': _name};
  Map<String, dynamic> _fail(Object e) =>
      {'success': false, 'error': e is ApiException ? e.message : 'Something went wrong. Please try again.'};

  Future<Map<String, dynamic>> _consume(dynamic res) async {
    if (res is! Map || res['token'] == null || res['user'] is! Map) {
      return {'success': false, 'error': 'Unexpected server response.'};
    }
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

  /// Update rider profile details (server is the source of truth).
  Future<bool> updateProfile({
    required String phone,
    required String vehicleType,
    required String vehicleNo,
    required String emergencyContact,
    required String emergencyContactName,
  }) async {
    try {
      final res = await _api.patch('/me', {
        'phone': phone,
        'vehicleType': vehicleType,
        'vehicleNo': vehicleNo,
        'emergencyContact': emergencyContact,
        'emergencyContactName': emergencyContactName,
      });
      if (res is Map) await _applyUser(Map<String, dynamic>.from(res));
      return true;
    } catch (e) {
      debugPrint('updateProfile note: $e');
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    await _clearSession();
  }

  Future<void> _clearSession() async {
    await _api.setToken(null);
    _userId = null;
    _role = null;
    _email = null;
    _name = null;
    _vehicleType = null;
    _phone = null;
    _emergencyContact = null;
    _emergencyContactName = null;
    _vehicleNo = null;
    final prefs = await SharedPreferences.getInstance();
    for (final k in [
      AppConstants.keyUserId, AppConstants.keyUserRole, AppConstants.keyUserEmail, AppConstants.keyUserName,
      AppConstants.keyVehicleType, AppConstants.keyActiveGroupId, AppConstants.keyPhone, AppConstants.keyVehicleNo,
      AppConstants.keyEmergencyContact, AppConstants.keyEmergencyName,
    ]) {
      await prefs.remove(k);
    }
    notifyListeners();
  }
}
