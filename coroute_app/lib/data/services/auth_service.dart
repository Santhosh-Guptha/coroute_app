import 'dart:convert';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../models/rider_model.dart';
import 'oracle_ai_service.dart';

class AuthService extends ChangeNotifier {
  String? _currentUserRole;
  String? _currentUserEmail;
  String? _currentUserName;
  String? _vehicleType;
  String? _phone;
  String? _emergencyContact;
  String? _emergencyContactName;
  String? _vehicleNo;
  bool _isLoading = true;

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
  );

  String? get currentUserRole => _currentUserRole;
  String? get currentUserEmail => _currentUserEmail;
  String? get currentUserName => _currentUserName;
  String? get vehicleType => _vehicleType;
  String? get phone => _phone;
  String? get emergencyContact => _emergencyContact;
  String? get emergencyContactName => _emergencyContactName;
  String? get vehicleNo => _vehicleNo;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _currentUserName != null || _currentUserRole != null;
  bool get isMasterAdmin => _currentUserRole == AppConstants.adminRole;

  AuthService() {
    _loadSavedSession();
  }

  Future<void> _loadSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    _currentUserRole = prefs.getString(AppConstants.keyUserRole);
    _currentUserEmail = prefs.getString(AppConstants.keyUserEmail);
    _currentUserName = prefs.getString(AppConstants.keyUserName);
    _vehicleType = prefs.getString(AppConstants.keyVehicleType) ?? 'Motorcycle';
    _phone = prefs.getString('user_phone') ?? '';
    _emergencyContact = prefs.getString('user_emergency_contact') ?? '';
    _emergencyContactName = prefs.getString('user_emergency_name') ?? '';
    _vehicleNo = prefs.getString('user_vehicle_no') ?? '';
    _isLoading = false;
    notifyListeners();
  }

  /// Authenticate as Master Admin (santhoshbukka5@gmail.com)
  Future<bool> loginMasterAdmin({
    required String email,
    required String password,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    if (cleanEmail == AppConstants.masterAdminEmail.toLowerCase() &&
        password.trim().isNotEmpty) {
      _currentUserRole = AppConstants.adminRole;
      _currentUserEmail = cleanEmail;
      _currentUserName = 'Master Admin (Santhosh Bukka)';
      _vehicleType = 'Command Center';

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.keyUserRole, AppConstants.adminRole);
      await prefs.setString(AppConstants.keyUserEmail, cleanEmail);
      await prefs.setString(AppConstants.keyUserName, _currentUserName!);
      await prefs.setString(AppConstants.keyVehicleType, _vehicleType!);

      notifyListeners();
      return true;
    }
    return false;
  }

  /// Google Sign-In Integration
  Future<Map<String, dynamic>> signInWithGoogle() async {
    try {
      try {
        await _googleSignIn.signOut();
      } catch (_) {}
      final account = await _googleSignIn.signIn();
      if (account == null) {
        return {'success': false, 'error': 'Google Sign-In canceled by user.'};
      }

      final email = account.email.trim().toLowerCase();
      final displayName = (account.displayName?.trim().isNotEmpty == true)
          ? account.displayName!.trim()
          : account.email.split('@').first;

      final isAdmin = (email == AppConstants.masterAdminEmail.toLowerCase());
      final role = isAdmin ? AppConstants.adminRole : AppConstants.riderRole;

      _currentUserRole = role;
      _currentUserEmail = email;
      _currentUserName = isAdmin ? 'Master Admin (Santhosh Bukka)' : displayName;
      _vehicleType = isAdmin ? 'Command Center' : (_vehicleType ?? 'Motorcycle (Adv)');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.keyUserRole, role);
      await prefs.setString(AppConstants.keyUserEmail, email);
      await prefs.setString(AppConstants.keyUserName, _currentUserName!);
      await prefs.setString(AppConstants.keyVehicleType, _vehicleType!);

      // Non-blocking sync to Firebase Realtime Database
      final userId = 'usr_${displayName.toLowerCase().replaceAll(' ', '_')}';
      try {
        FirebaseDatabase.instance.ref('users/$userId').update({
          'userId': userId,
          'name': displayName,
          'email': email,
          'role': role,
          'provider': 'google',
          'lastLoginEpochMs': DateTime.now().millisecondsSinceEpoch,
        }).timeout(const Duration(milliseconds: 500)).catchError((_) {});
      } catch (e) {
        debugPrint('Firebase Google user sync note: $e');
      }

      // Sync rider profile to Oracle 26ai Cloud SODA
      try {
        final riderProfile = RiderModel(
          userId: userId,
          name: displayName,
          role: role,
          vehicleType: _vehicleType ?? 'Motorcycle (Adv)',
          vehicleNo: _vehicleNo ?? '',
          phone: _phone ?? '',
          emergencyContact: _emergencyContact ?? '',
          emergencyContactName: _emergencyContactName ?? '',
          lat: 0.0,
          lng: 0.0,
          lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
        );
        OracleAiService().saveRiderProfileToOracle(riderProfile).catchError((_) => false);
      } catch (e) {
        debugPrint('Oracle rider profile sync note: $e');
      }

      notifyListeners();
      return {
        'success': true,
        'isAdmin': isAdmin,
        'email': email,
        'name': displayName,
      };
    } catch (e) {
      debugPrint('Google Sign-In Exception: $e');
      return {'success': false, 'error': 'Google Sign-In failed: $e'};
    }
  }

  /// Register a brand new Rider Account
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
    final cleanName = name.trim();
    final cleanEmail = email.trim().toLowerCase();
    final cleanPhone = phone.trim();
    final cleanVehicleNo = vehicleNo.trim().toUpperCase();

    if (cleanName.isEmpty) {
      return {'success': false, 'error': 'Callsign / Full Name is required.'};
    }
    if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
      return {'success': false, 'error': 'A valid email address is required.'};
    }
    if (password.length < 6) {
      return {'success': false, 'error': 'Password must be at least 6 characters.'};
    }
    if (cleanPhone.isEmpty) {
      return {'success': false, 'error': 'Mobile phone number is required.'};
    }

    final prefs = await SharedPreferences.getInstance();
    final rawUsers = prefs.getString('coroute_registered_users') ?? '{}';
    Map<String, dynamic> users = {};
    try {
      users = jsonDecode(rawUsers) as Map<String, dynamic>;
    } catch (_) {}

    // Check if email already registered
    if (users.containsKey(cleanEmail)) {
      return {'success': false, 'error': 'This email is already registered. Please sign in.'};
    }

    final isAdmin = (cleanEmail == AppConstants.masterAdminEmail.toLowerCase());
    final role = isAdmin ? AppConstants.adminRole : AppConstants.riderRole;
    final displayName = isAdmin ? 'Master Admin (Santhosh Bukka)' : cleanName;
    final vehicle = isAdmin ? 'Command Center' : vehicleType.trim();

    final userId = 'usr_${cleanName.toLowerCase().replaceAll(' ', '_')}';
    final userRecord = {
      'userId': userId,
      'name': displayName,
      'email': cleanEmail,
      'password': password,
      'phone': cleanPhone,
      'vehicleType': vehicle,
      'vehicleNo': cleanVehicleNo,
      'role': role,
      'emergencyContact': emergencyContact.trim(),
      'emergencyContactName': emergencyContactName.trim(),
      'registeredAt': DateTime.now().millisecondsSinceEpoch,
    };

    // Save to local registry
    users[cleanEmail] = userRecord;
    users['callsign_${cleanName.toLowerCase()}'] = userRecord;
    await prefs.setString('coroute_registered_users', jsonEncode(users));

    // Non-blocking sync to Firebase Realtime Database
    try {
      FirebaseDatabase.instance.ref('users/$userId').set({
        'userId': userId,
        'name': displayName,
        'email': cleanEmail,
        'phone': cleanPhone,
        'role': role,
        'vehicleType': vehicle,
        'vehicleNo': cleanVehicleNo,
        'emergencyContact': emergencyContact.trim(),
        'emergencyContactName': emergencyContactName.trim(),
        'registeredAt': DateTime.now().millisecondsSinceEpoch,
      }).timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (e) {
      debugPrint('Firebase user registration sync note: $e');
    }

    // Set active user session
    _currentUserRole = role;
    _currentUserEmail = cleanEmail;
    _currentUserName = displayName;
    _vehicleType = vehicle;
    _phone = cleanPhone;
    _emergencyContact = emergencyContact.trim();
    _emergencyContactName = emergencyContactName.trim();
    _vehicleNo = cleanVehicleNo;

    await prefs.setString(AppConstants.keyUserRole, role);
    await prefs.setString(AppConstants.keyUserEmail, cleanEmail);
    await prefs.setString(AppConstants.keyUserName, displayName);
    await prefs.setString(AppConstants.keyVehicleType, _vehicleType!);
    await prefs.setString('user_phone', cleanPhone);
    await prefs.setString('user_emergency_contact', _emergencyContact!);
    await prefs.setString('user_emergency_name', _emergencyContactName!);
    await prefs.setString('user_vehicle_no', cleanVehicleNo);

    notifyListeners();
    return {'success': true, 'userId': userId, 'isAdmin': isAdmin};
  }

  /// Sign In with Email/Callsign and Password
  Future<Map<String, dynamic>> loginRiderWithPassword({
    required String identifier,
    required String password,
  }) async {
    final cleanId = identifier.trim();
    final cleanLower = cleanId.toLowerCase();

    // Check Master Admin: if santhoshbukka5@gmail.com logs in, they are automatically granted Master Admin
    if (cleanLower == AppConstants.masterAdminEmail.toLowerCase()) {
      final ok = await loginMasterAdmin(email: cleanId, password: password);
      return ok
          ? {'success': true, 'isAdmin': true}
          : {'success': false, 'error': 'Invalid credentials for admin.'};
    }

    final prefs = await SharedPreferences.getInstance();
    final rawUsers = prefs.getString('coroute_registered_users') ?? '{}';
    Map<String, dynamic> users = {};
    try {
      users = jsonDecode(rawUsers) as Map<String, dynamic>;
    } catch (_) {}

    // Look up by email or callsign
    Map<String, dynamic>? account;
    if (users.containsKey(cleanLower)) {
      account = Map<String, dynamic>.from(users[cleanLower] as Map);
    } else if (users.containsKey('callsign_$cleanLower')) {
      account = Map<String, dynamic>.from(users['callsign_$cleanLower'] as Map);
    }

    // If found in local registry
    if (account != null) {
      final savedPass = account['password']?.toString() ?? '';
      if (savedPass.isNotEmpty && savedPass != password) {
        return {'success': false, 'error': 'Incorrect password. Please try again.'};
      }

      final accountEmail = account['email']?.toString() ?? '$cleanId@rider.coroute';
      final isAdmin = (accountEmail.toLowerCase() == AppConstants.masterAdminEmail.toLowerCase());
      final role = isAdmin ? AppConstants.adminRole : AppConstants.riderRole;

      _currentUserRole = role;
      _currentUserEmail = accountEmail;
      _currentUserName = account['name']?.toString() ?? cleanId;
      _vehicleType = account['vehicleType']?.toString() ?? 'Motorcycle';
      _phone = account['phone']?.toString() ?? '';
      _emergencyContact = account['emergencyContact']?.toString() ?? '';
      _emergencyContactName = account['emergencyContactName']?.toString() ?? '';
      _vehicleNo = account['vehicleNo']?.toString() ?? '';

      await prefs.setString(AppConstants.keyUserRole, role);
      await prefs.setString(AppConstants.keyUserEmail, _currentUserEmail!);
      await prefs.setString(AppConstants.keyUserName, _currentUserName!);
      await prefs.setString(AppConstants.keyVehicleType, _vehicleType!);
      await prefs.setString('user_phone', _phone!);
      await prefs.setString('user_emergency_contact', _emergencyContact!);
      await prefs.setString('user_emergency_name', _emergencyContactName!);
      await prefs.setString('user_vehicle_no', _vehicleNo!);

      notifyListeners();
      return {'success': true, 'isAdmin': isAdmin};
    }

    // Fallback: Check Firebase users
    try {
      final db = FirebaseDatabase.instance;
      final snap = await db.ref('users').get().timeout(const Duration(milliseconds: 500));
      if (snap.exists && snap.value != null && snap.value is Map) {
        final allUsers = Map<String, dynamic>.from(snap.value as Map);
        for (final entry in allUsers.values) {
          if (entry is Map) {
            final eEmail = entry['email']?.toString().toLowerCase();
            final eName = entry['name']?.toString().toLowerCase();
            if (eEmail == cleanLower || eName == cleanLower) {
              final isAdmin = (eEmail == AppConstants.masterAdminEmail.toLowerCase());
              final role = isAdmin ? AppConstants.adminRole : AppConstants.riderRole;

              _currentUserRole = role;
              _currentUserEmail = entry['email']?.toString() ?? '$cleanId@rider.coroute';
              _currentUserName = entry['name']?.toString() ?? cleanId;
              _vehicleType = entry['vehicleType']?.toString() ?? 'Motorcycle';
              _phone = entry['phone']?.toString() ?? '';
              _emergencyContact = entry['emergencyContact']?.toString() ?? '';
              _emergencyContactName = entry['emergencyContactName']?.toString() ?? '';
              _vehicleNo = entry['vehicleNo']?.toString() ?? '';

              await prefs.setString(AppConstants.keyUserRole, role);
              await prefs.setString(AppConstants.keyUserEmail, _currentUserEmail!);
              await prefs.setString(AppConstants.keyUserName, _currentUserName!);
              await prefs.setString(AppConstants.keyVehicleType, _vehicleType!);
              await prefs.setString('user_phone', _phone!);
              await prefs.setString('user_emergency_contact', _emergencyContact!);
              await prefs.setString('user_emergency_name', _emergencyContactName!);
              await prefs.setString('user_vehicle_no', _vehicleNo!);

              notifyListeners();
              return {'success': true, 'isAdmin': isAdmin};
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Firebase user remote lookup error: $e');
    }

    return {
      'success': false,
      'error': 'Account not found. Please click "Register Account" to create a new profile.'
    };
  }

  /// Backward-compatible login helper
  Future<void> loginRider({
    required String riderName,
    String vehicleType = 'Motorcycle',
    String? email,
    String phone = '',
    String emergencyContact = '',
    String emergencyContactName = '',
    String vehicleNo = '',
  }) async {
    final cleanEmail = email ?? '$riderName@rider.coroute';
    final isAdmin = (cleanEmail.toLowerCase() == AppConstants.masterAdminEmail.toLowerCase() ||
        riderName.toLowerCase() == AppConstants.masterAdminEmail.toLowerCase());
    final role = isAdmin ? AppConstants.adminRole : AppConstants.riderRole;

    _currentUserRole = role;
    _currentUserEmail = cleanEmail;
    _currentUserName = isAdmin ? 'Master Admin (Santhosh Bukka)' : riderName.trim();
    _vehicleType = isAdmin ? 'Command Center' : vehicleType.trim();
    _phone = phone.trim();
    _emergencyContact = emergencyContact.trim();
    _emergencyContactName = emergencyContactName.trim();
    _vehicleNo = vehicleNo.trim().toUpperCase();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.keyUserRole, role);
    await prefs.setString(AppConstants.keyUserEmail, _currentUserEmail!);
    await prefs.setString(AppConstants.keyUserName, _currentUserName!);
    await prefs.setString(AppConstants.keyVehicleType, _vehicleType!);
    await prefs.setString('user_phone', _phone!);
    await prefs.setString('user_emergency_contact', _emergencyContact!);
    await prefs.setString('user_emergency_name', _emergencyContactName!);
    await prefs.setString('user_vehicle_no', _vehicleNo!);

    notifyListeners();
  }

  /// Update Rider Profile Details
  Future<void> updateProfile({
    required String phone,
    required String vehicleType,
    required String vehicleNo,
    required String emergencyContact,
    required String emergencyContactName,
  }) async {
    _phone = phone.trim();
    _vehicleType = vehicleType.trim();
    _vehicleNo = vehicleNo.trim().toUpperCase();
    _emergencyContact = emergencyContact.trim();
    _emergencyContactName = emergencyContactName.trim();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_phone', _phone!);
    await prefs.setString(AppConstants.keyVehicleType, _vehicleType!);
    await prefs.setString('user_vehicle_no', _vehicleNo!);
    await prefs.setString('user_emergency_contact', _emergencyContact!);
    await prefs.setString('user_emergency_name', _emergencyContactName!);

    if (_currentUserName != null) {
      final userId = 'usr_${_currentUserName!.toLowerCase().replaceAll(' ', '_')}';
      try {
        FirebaseDatabase.instance.ref('users/$userId').update({
          'phone': _phone,
          'vehicleType': _vehicleType,
          'vehicleNo': _vehicleNo,
          'emergencyContact': _emergencyContact,
          'emergencyContactName': _emergencyContactName,
        }).timeout(const Duration(milliseconds: 500)).catchError((_) {});
      } catch (_) {}

      try {
        final riderProfile = RiderModel(
          userId: userId,
          name: _currentUserName!,
          role: _currentUserRole ?? 'RIDER',
          vehicleType: _vehicleType ?? 'Motorcycle',
          vehicleNo: _vehicleNo ?? '',
          phone: _phone ?? '',
          emergencyContact: _emergencyContact ?? '',
          emergencyContactName: _emergencyContactName ?? '',
          lat: 0.0,
          lng: 0.0,
          lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
        );
        OracleAiService().saveRiderProfileToOracle(riderProfile).catchError((_) => false);
      } catch (_) {}
    }

    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}

    _currentUserRole = null;
    _currentUserEmail = null;
    _currentUserName = null;
    _vehicleType = null;
    _phone = null;
    _emergencyContact = null;
    _emergencyContactName = null;
    _vehicleNo = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.keyUserRole);
    await prefs.remove(AppConstants.keyUserEmail);
    await prefs.remove(AppConstants.keyUserName);
    await prefs.remove(AppConstants.keyVehicleType);
    await prefs.remove(AppConstants.keyActiveGroupId);
    await prefs.remove('user_phone');
    await prefs.remove('user_emergency_contact');
    await prefs.remove('user_emergency_name');
    await prefs.remove('user_vehicle_no');

    notifyListeners();
  }
}
