import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../../domain/auth/session_policy.dart';
import '../../domain/garage/bike_sync.dart';
import '../local/sensitive_prefs.dart';
import 'api_client.dart';
import 'ride_chat_store.dart';
import 'safety_native.dart';
import 'session_guard.dart';
import 'feature_flags_service.dart' show FeatureFlagsService;
import 'friends_service.dart' show FriendsService;

/// Account state. Registration (email + password, or Google) is mandatory;
/// there is no guest mode. Roles come from the database, not from the app.
///
/// 3.57 sessions (docs/features_355/sessions_and_security.md): a sign-out (the rider's, or the gateway ending the
/// session) never happens during a ride, an SOS, a crash countdown, a convoy or while emergency texts wait
/// ([SessionGuard]); it runs when the ride is over. Signing out ends the session on the gateway, removes the push
/// token, wipes the tokens and the cached personal data, and asks whether to keep the emergency info (contact and
/// Medical ID on the lock screen) on this phone (default: keep, because safety works without an account).
class AuthService extends ChangeNotifier {
  AuthService(this._api, {SessionGuard? guard}) : _guard = guard ?? SessionGuard.instance {
    _api.addListener(_onApiChanged);
    _loadSavedSession();
  }

  final SessionGuard _guard;
  final SensitivePrefs _secure = SensitivePrefs();

  /// The guard that holds a sign-out back during a ride (the UI shows its notice).
  SessionGuard get sessionGuard => _guard;

  /// Run before the session is revoked on the gateway (the push token is removed while the token still works).
  final List<Future<void> Function()> beforeSignOut = [];

  /// Run after a sign-out wiped the session (cached personal data, background services that need an account).
  final List<Future<void> Function()> afterSignOut = [];

  /// True while the gateway already ended the session but a ride keeps this phone signed in locally.
  bool _endedDuringRide = false;
  bool get sessionEndedDuringRide => _endedDuringRide;

  /// The API client dropped the token because the gateway ended the session.
  void _onApiChanged() {
    if (!_api.hasToken && _userId != null && !_isLoading) _sessionEndedByGateway();
  }

  /// The gateway ended the session: sign out now, or when the ride is over (idempotent).
  void _sessionEndedByGateway() {
    if (_userId == null) return;
    _lastSignOutReason = _api.lastSessionEndMessage ?? _lastSignOutReason;
    if (_guard.busy && !_endedDuringRide) {
      // Never mid-ride: keep the profile (SOS texts, Medical ID) and the screen until the ride is over.
      _endedDuringRide = true;
      notifyListeners();
    }
    // A sign-out already waits for the ride to end (the rider's own, or an earlier session end): it runs then.
    if (_guard.pending) return;
    _guard.runWhenSafe(SignOutCause.sessionEnded, () => _wipe(keepEmergencyInfo: true)).ignore();
  }

  String? _lastSignOutReason;

  /// The last `subscriptionStatus` object the gateway sent with `/me` or a login,
  /// kept so the plan service can pick it up even if it is created after the reply.
  Map<String, dynamic>? _lastSubscriptionStatus;
  Map<String, dynamic>? get lastSubscriptionStatus => _lastSubscriptionStatus;

  /// Called with every `subscriptionStatus` object received (wired to PlanSubscriptionService).
  void Function(Map<String, dynamic> status)? onSubscriptionStatus;

  /// Called when the session on this phone ends (sign out, revoked token, deleted account).
  VoidCallback? onSessionCleared;

  void _noteSubscriptionStatus(dynamic status) {
    if (status is! Map) return;
    final m = Map<String, dynamic>.from(status);
    _lastSubscriptionStatus = m;
    onSubscriptionStatus?.call(m);
  }

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
    serverClientId: AppConfig.googleWebClientId.isEmpty
        ? null
        : AppConfig.googleWebClientId,
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
  // 3.55 public username (src/usernames.js on the gateway): shown on the profile and to friends.
  String _username = '';

  // Medical info and the emergency text opt-out: memory only, from /me (never in SharedPreferences).
  String _bloodGroup = '';
  String _allergies = '';
  String _medicalNotes = '';
  bool _smsOptOut = false;
  bool _medicalLoaded = false;

  // Rider Safety Network switches (3.15): memory only, from /me. Always on since Nov 11 (owner
  // decision): these keep what the server last said, only to write it back on (see [_keepAssistOn]).
  bool _assistHelp = true;
  bool _assistAsk = true;
  String? _assistFixFor;
  int _netConsentAt = 0;
  bool _netLoaded = false;

  String? get currentUserId => _userId;
  String? get currentUserRole => _role;
  String? get currentUserEmail => _email;
  String? get currentUserName => _name;
  String? get vehicleType => _vehicleType;
  String? get phone => _phone;
  String? get emergencyContact => _emergencyContact;
  String? get emergencyContactName => _emergencyContactName;
  String? get vehicleNo => _vehicleNo;

  /// 3.55 public username (empty until a 3.55 gateway answered).
  String get username => _username;

  /// Optional medical info: always on the lock screen Medical ID and shared with responders
  /// (group, guardians, riders who accept to help) only while my SOS or crash alert is open.
  /// There is no sharing switch.
  String get bloodGroup => _bloodGroup;
  String get allergies => _allergies;
  String get medicalNotes => _medicalNotes;

  /// True when I asked not to receive emergency texts from my ride group.
  bool get smsOptOut => _smsOptOut;

  /// Get a request when a rider from another group may need help on my route. Always on since
  /// Nov 11 (owner decision, docs/SETTINGS_MINIMAL_v3.55.md): no switch in the app.
  bool get assistHelp => true;

  /// Let nearby riders of other groups be asked to help me. Always on since Nov 11.
  bool get assistAsk => true;

  /// What the gateway last reported (false only until [_keepAssistOn] wrote it back on).
  @visibleForTesting
  bool get serverAssistOn => _assistHelp && _assistAsk;

  /// Medical info always goes to a responder during my emergency (no switch any more). A stored
  /// `false` from an older version is ignored, here and on the gateway.
  bool get responderMedical => true;

  /// When I agreed to the nearby riders explanation (epoch ms), 0 = not yet.
  int get netConsentAt => _netConsentAt;

  /// True once a 3.15 gateway sent the switches above.
  bool get netLoaded => _netLoaded;

  /// True once the server sent the medical fields (a 3.14 gateway answered /me or a sign-in).
  /// Until then the form only sends the medical fields the rider actually changed.
  bool get medicalLoaded => _medicalLoaded;
  bool get isLoading => _isLoading;
  /// Signed in. Also true while a sign-out waits for the ride to end (the session already ended on the gateway).
  bool get isAuthenticated => (_api.hasToken || _endedDuringRide) && _userId != null && !isGuest;
  bool get isMasterAdmin => roleIsAdmin(_role);

  /// True if the user is registered or designated as a pillion passenger.
  bool get isPillion =>
      (_vehicleType ?? '').trim().toLowerCase() == 'pillion rider' ||
      (_vehicleNo ?? '').trim().toUpperCase() == 'PILLION';

  /// True for a guest session saved by a build before 3.55. Guest mode is retired:
  /// such a session is cleared on start and the rider is asked to create a free account.
  bool get isGuest =>
      (_userId ?? '').startsWith('guest_') ||
      (_email ?? '').endsWith('@guest.coroute.local');

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
    // 3.57: phone, emergency contact and e-mail live in the keystore (moved from SharedPreferences once).
    _email = await _secure.read(prefs, AppConstants.keyUserEmail) ?? _email;
    _phone = await _secure.read(prefs, AppConstants.keyPhone) ?? '';
    _emergencyContact = await _secure.read(prefs, AppConstants.keyEmergencyContact) ?? '';
    _emergencyContactName = await _secure.read(prefs, AppConstants.keyEmergencyName) ?? '';
    _keepEmergencyInfo = prefs.getBool(keyKeepEmergencyInfo) ?? true;
    _vehicleNo = prefs.getString(AppConstants.keyVehicleNo) ?? '';
    // Guest mode was retired in 3.55: a saved guest session is cleared once, with a clear message.
    if (isGuest) {
      _lastSignOutReason = 'Guest mode has ended. Create a free CoRoute account (Community plan) to keep riding.';
      await _clearSession();
    }
    _isLoading = false;
    notifyListeners();

    // Refresh the profile (and role) from the server in the background.
    if (_api.hasToken && _userId != null) {
      try {
        final me = await _api.get('/me');
        if (me is Map) await _applyUser(Map<String, dynamic>.from(me));
      } on ApiException catch (e) {
        if (e.endsSession) {
          // Revoked token, deleted, held or blocked account, as stated by the gateway. 3.57: through the guard
          // (never mid-ride; a crash countdown restored at start-up keeps the rider signed in until it is over).
          _lastSignOutReason = e.message;
          _sessionEndedByGateway();
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
        _sessionEndedByGateway();
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
    _provider = u['provider']?.toString() ?? _provider;
    if (u.containsKey('username')) _username = u['username']?.toString() ?? '';
    // Older gateways do not send these: keep what is known instead of clearing it.
    if (u.containsKey('bloodGroup')) {
      _bloodGroup = u['bloodGroup']?.toString() ?? '';
    }
    if (u.containsKey('allergies')) {
      _allergies = u['allergies']?.toString() ?? '';
    }
    if (u.containsKey('medicalNotes')) {
      _medicalNotes = u['medicalNotes']?.toString() ?? '';
    }
    if (u.containsKey('smsOptOut')) _smsOptOut = u['smsOptOut'] == true;
    if (u.containsKey('bloodGroup') || u.containsKey('smsOptOut')) {
      _medicalLoaded = true;
    }
    if (u.containsKey('assistHelp')) _assistHelp = u['assistHelp'] != false;
    if (u.containsKey('assistAsk')) _assistAsk = u['assistAsk'] != false;
    final consent = u['netConsentAt'];
    if (consent is num) _netConsentAt = consent.toInt();
    if (u.containsKey('assistHelp') ||
        u.containsKey('assistAsk') ||
        u.containsKey('responderMedical')) {
      _netLoaded = true;
    }
    // Plan state travels with the profile; an expired paid tier arrives as community.
    _noteSubscriptionStatus(u['subscriptionStatus']);
    // 3.55 bike summary: only a gateway that returns it accepts it (older ones never see it).
    // 3.56: only the keys this gateway returned (a newer one also keeps the type and fuel).
    if (u.containsKey('bikeModel')) {
      _bikeOnServer = {for (final k in bikeSummaryKeys) if (u.containsKey(k)) k: u[k]};
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.keyUserId, _userId ?? '');
    await prefs.setString(AppConstants.keyUserRole, _role ?? '');
    await _secure.write(prefs, AppConstants.keyUserEmail, _email ?? '');
    await prefs.setString(AppConstants.keyUserName, _name ?? '');
    await prefs.setString(AppConstants.keyVehicleType, _vehicleType ?? '');
    await _secure.write(prefs, AppConstants.keyPhone, _phone ?? '');
    await prefs.setString(AppConstants.keyVehicleNo, _vehicleNo ?? '');
    await _secure.write(prefs, AppConstants.keyEmergencyContact, _emergencyContact ?? '');
    await _secure.write(prefs, AppConstants.keyEmergencyName, _emergencyContactName ?? '');
    notifyListeners();
    _keepAssistOn();
  }

  /// "Help nearby riders" and "Ask nearby riders to help me" are always on (Nov 11). When the
  /// gateway still has one of them off (set by an older app), write both back on once per signed-in
  /// rider and app run. Skipped while the admin switch `assistNetwork` is off (the feature is
  /// paused for everyone; the rider's value is left as it is). Never blocks; failures retry next run.
  void _keepAssistOn() {
    final uid = _userId;
    if (uid == null || !_netLoaded || (_assistHelp && _assistAsk)) return;
    if (_assistFixFor == uid || !FeatureFlagsService.on('assistNetwork')) return;
    _assistFixFor = uid;
    updateNetworkPrefs(assistHelp: true, assistAsk: true).ignore();
  }

  bool get mustChangePassword => _mustChangePassword;

  Map<String, dynamic> _ok() => {
    'success': true,
    'isAdmin': isMasterAdmin,
    'userId': _userId,
    'name': _name,
    'mustChangePassword': _mustChangePassword,
  };
  Map<String, dynamic> _fail(Object e) => {
    'success': false,
    'error': e is ApiException
        ? e.message
        : 'Something went wrong. Please try again.',
    // Round 4: the gateway's code and body (ride lock 423, EMAIL_NOT_VERIFIED, wrong-code tries left ...).
    if (e is ApiException && e.code != null) 'code': e.code,
    if (e is ApiException) 'statusCode': e.statusCode,
    if (e is ApiException && e.body != null) 'body': e.body,
  };

  Future<Map<String, dynamic>> _consume(dynamic res) async {
    if (res is! Map || res['token'] == null || res['user'] is! Map) {
      return {'success': false, 'error': 'Unexpected server response.'};
    }
    clearSignOutReason();
    _guard.cancel();
    _endedDuringRide = false;
    // 3.57: the short access token and its refresh token (older gateways send only `token`).
    await _api.setSession(res['token'].toString(), refreshToken: res['refreshToken']?.toString());
    await _applyUser(Map<String, dynamic>.from(res['user'] as Map));
    // Login replies may carry the plan beside the user rather than inside it.
    if ((res['user'] as Map)['subscriptionStatus'] is! Map) {
      _noteSubscriptionStatus(res['subscriptionStatus']);
    }
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
      // 3.55: a friend invite opened before signing up goes with the registration (the gateway sends
      // the inviter a friend request).
      final invite = await FriendsService.pendingInviteCode();
      final res = await _api.post(
        '/auth/register',
        {
          'name': name.trim(),
          'email': email.trim(),
          'password': password,
          'phone': phone.trim(),
          'vehicleType': vehicleType.trim(),
          'vehicleNo': vehicleNo.trim(),
          'emergencyContact': emergencyContact.trim(),
          'emergencyContactName': emergencyContactName.trim(),
          'inviteCode': ?invite,
          'device': await _device(),
        },
        const Duration(seconds: 15),
        false,
      );
      if (invite != null) await FriendsService.clearPendingInvite();
      // Round 4: the account waits for its e-mail link (no token yet): the app shows "Check your inbox".
      if (res is Map && res['pending'] == true && res['token'] == null) {
        return {'success': false, 'pending': true, 'email': email.trim(), 'message': res['message']?.toString() ?? 'Check your e-mail to finish creating your account', 'resendAfterSec': res['resendAfterSec']};
      }
      return await _consume(res);
    } catch (e) {
      return _fail(e);
    }
  }

  // ---- Round 4: e-mail verification, ride lock override, admin 2-step ----

  /// "Send a new link" on the Check your inbox screen (always the same answer from the gateway).
  Future<Map<String, dynamic>> resendVerification(String email) async {
    try {
      final res = await _api.post('/auth/register/resend', {'email': email.trim()}, const Duration(seconds: 15), false);
      return {'success': true, 'message': res is Map ? res['message']?.toString() : null, 'resendAfterSec': res is Map ? res['resendAfterSec'] : null};
    } catch (e) {
      return _fail(e);
    }
  }

  /// Sends the ride sign-in code to the account address (after a 423 RIDE_ACTIVE_ELSEWHERE).
  Future<Map<String, dynamic>> sendRideLockCode(String lockToken) async {
    try {
      final res = await _api.post('/auth/ride-lock/code', {'lockToken': lockToken}, const Duration(seconds: 15), false);
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      return {'success': true, 'resendAfterSec': m['resendAfterSec'], 'sentTo': m['sentTo']};
    } catch (e) {
      return _fail(e);
    }
  }

  /// The e-mailed code: signs this phone in; the other phone's ride is handed over and it is signed out.
  Future<Map<String, dynamic>> verifyRideLockCode(String lockToken, String code) async {
    try {
      final res = await _api.post('/auth/ride-lock/verify', {'lockToken': lockToken, 'code': code.replaceAll(RegExp(r'[\s-]'), ''), 'device': await _device()},
          const Duration(seconds: 15), false);
      return await _consume(res);
    } catch (e) {
      return _fail(e);
    }
  }

  /// Admin 2-step step-up of this session (TOTP, recovery or e-mailed code), after a 403 MFA_REQUIRED.
  Future<Map<String, dynamic>> mfaStepUp({String? code, String? recoveryCode, String? emailCode}) async {
    try {
      await _api.post('/auth/mfa/step-up', {'code': ?code, 'recoveryCode': ?recoveryCode, 'emailCode': ?emailCode});
      return {'success': true};
    } catch (e) {
      return _fail(e);
    }
  }

  /// E-mails a 2-step code (operators without an authenticator app; never administrators).
  Future<Map<String, dynamic>> mfaSendEmailCode() async {
    try {
      final res = await _api.post('/auth/mfa/step-up/email-code', const {});
      return {'success': true, 'resendAfterSec': res is Map ? res['resendAfterSec'] : null};
    } catch (e) {
      return _fail(e);
    }
  }

  /// Sign in with email or callsign + password.
  Future<Map<String, dynamic>> loginRiderWithPassword({
    required String identifier,
    required String password,
  }) async {
    try {
      final res = await _api.post(
        '/auth/login',
        {'identifier': identifier.trim(), 'password': password, 'device': await _device()},
        const Duration(seconds: 15),
        false,
      );
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
      if (account == null) {
        return {'success': false, 'error': 'Google Sign-In cancelled.'};
      }
      final gAuth = await account.authentication;
      final idToken = gAuth.idToken;
      if (idToken == null || idToken.isEmpty) {
        return {
          'success': false,
          'error': 'Google did not return an ID token. Check the OAuth client configuration.',
        };
      }
      final res = await _api.post(
        '/auth/google',
        {'idToken': idToken, 'device': await _device()},
        const Duration(seconds: 15),
        false,
      );
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

  /// 3.55: the active bike's summary keys the gateway stores (engine care and fuel analysis).
  /// 3.56: also the confirmed bike type and the fuel type ([BikeSync.allKeys]).
  static const List<String> bikeSummaryKeys = BikeSync.allKeys;

  /// The bike summary as the gateway last returned it (null: an older gateway, or not loaded yet).
  Map<String, dynamic>? _bikeOnServer;

  /// 3.56: the gateway's copy of the rider's bike (restores the garage on a new install / phone).
  Map<String, dynamic>? get bikeOnServer => _bikeOnServer == null ? null : Map.unmodifiable(_bikeOnServer!);

  /// Shares the active bike's summary, best effort: only with a gateway that returned the
  /// summary before (older ones are never sent unknown keys), only when it changed, and every
  /// error (offline, refused) is ignored silently; the garage on the phone stays the source.
  Future<bool> syncBikeSummary(Map<String, Object> summary) async {
    final known = _bikeOnServer;
    if (_userId == null || known == null) return false;
    final changed = BikeSync.changes(summary, known);
    if (changed.isEmpty) return true;
    // One request at a time; the newest summary goes next. A refused one is not sent again.
    if (_bikeSyncing) {
      _bikePending = summary;
      return false;
    }
    final sig = changed.toString();
    if (sig == _bikeRefused) return false;
    _bikeSyncing = true;
    try {
      final res = await _api.patch('/me', changed);
      if (res is Map) {
        await _applyUser(Map<String, dynamic>.from(res));
      } else {
        _bikeOnServer = {...known, ...changed};
      }
      return true;
    } on ApiException catch (e) {
      debugPrint('bike summary note: $e');
      if (e.statusCode >= 400 && e.statusCode < 500) _bikeRefused = sig;
      return false;
    } catch (e) {
      debugPrint('bike summary note: $e');
      return false;
    } finally {
      _bikeSyncing = false;
      final next = _bikePending;
      _bikePending = null;
      if (next != null) syncBikeSummary(next).ignore();
    }
  }

  bool _bikeSyncing = false;
  Map<String, Object>? _bikePending;
  String? _bikeRefused;

  /// Update rider profile details (server is the source of truth). The
  /// medical fields and [smsOptOut] are sent only when given (older callers
  /// never clear them).
  Future<bool> updateProfile({
    required String phone,
    required String vehicleType,
    required String vehicleNo,
    required String emergencyContact,
    required String emergencyContactName,
    String? name,
    String? bloodGroup,
    String? allergies,
    String? medicalNotes,
    bool? smsOptOut,
    bool? assistHelp,
    bool? assistAsk,
    bool? netConsent,
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
      if (bloodGroup != null) payload['bloodGroup'] = bloodGroup.trim();
      if (allergies != null) payload['allergies'] = allergies.trim();
      if (medicalNotes != null) payload['medicalNotes'] = medicalNotes.trim();
      if (smsOptOut != null) payload['smsOptOut'] = smsOptOut;
      // Always on since Nov 11: only "on" is ever sent.
      if (assistHelp == true) payload['assistHelp'] = true;
      if (assistAsk == true) payload['assistAsk'] = true;
      // Medical info is always shared with responders in an emergency. Gateways before that rule
      // still read this switch, so it travels (as true) with the medical fields; newer ones ignore it.
      if (bloodGroup != null || allergies != null || medicalNotes != null) {
        payload['responderMedical'] = true;
      }
      if (netConsent == true) payload['netConsent'] = true;
      _lastProfileError = null;
      final res = await _api.patch('/me', payload);
      if (res is Map) await _applyUser(Map<String, dynamic>.from(res));
      return true;
    } on ApiException catch (e) {
      debugPrint('updateProfile note: $e');
      // Validation answers (422 / 409) carry a message for the rider; outages do not.
      _lastProfileError =
          (e.statusCode >= 400 && e.statusCode < 500 && !e.isUnauthorized)
          ? e.message
          : null;
      return false;
    } catch (e) {
      debugPrint('updateProfile note: $e');
      _lastProfileError = null;
      return false;
    }
  }

  /// Saves only the nearby riders switches (and the consent) without the rest
  /// of the profile. Shown at once; put back when the server refuses or
  /// cannot be reached. True when saved.
  Future<bool> updateNetworkPrefs({
    bool? assistHelp,
    bool? assistAsk,
    bool netConsent = false,
  }) async {
    // Always on since Nov 11: "off" is never sent.
    if (assistHelp == false) assistHelp = null;
    if (assistAsk == false) assistAsk = null;
    final helpBefore = _assistHelp, askBefore = _assistAsk;
    final payload = <String, dynamic>{
      'assistHelp': ?assistHelp,
      'assistAsk': ?assistAsk,
      if (netConsent) 'netConsent': true,
    };
    if (payload.isEmpty) return true;
    if (assistHelp != null) _assistHelp = assistHelp;
    if (assistAsk != null) _assistAsk = assistAsk;
    notifyListeners();
    try {
      _lastProfileError = null;
      final res = await _api.patch('/me', payload);
      if (res is Map) await _applyUser(Map<String, dynamic>.from(res));
      if (netConsent && _netConsentAt == 0) {
        // An older gateway does not echo the consent time: remember it for this session.
        _netConsentAt = DateTime.now().millisecondsSinceEpoch;
        notifyListeners();
      }
      return true;
    } catch (e) {
      debugPrint('updateNetworkPrefs note: $e');
      _assistHelp = helpBefore;
      _assistAsk = askBefore;
      notifyListeners();
      return false;
    }
  }

  /// Change password. [currentPassword] may be empty when the server issued a temporary one.
  Future<Map<String, dynamic>> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    try {
      final res = await _api.post('/me/password', {
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      });
      // The server ends every other session and hands this phone a fresh token.
      final fresh = res is Map ? res['token']?.toString() : null;
      if (fresh != null && fresh.isNotEmpty) await _api.setSession(fresh);
      _mustChangePassword = false;
      notifyListeners();
      return {'success': true};
    } catch (e) {
      return _fail(e);
    }
  }

  /// Permanently deletes the account and all data tied to it, then signs out.
  /// 3.57: the gateway asks a 3.57+ build to confirm it is the rider first: the result then has
  /// `code: REAUTH_REQUIRED`; call [reauthenticate] (password or Google) and try again.
  Future<Map<String, dynamic>> deleteAccount() async {
    try {
      await _api.delete('/me');
      await _wipe(keepEmergencyInfo: false);
      return {'success': true};
    } on ApiException catch (e) {
      return {..._fail(e), 'code': e.code};
    } catch (e) {
      return _fail(e);
    }
  }

  /// 3.57: confirms it is the rider (password, or Google for Google accounts) for a sensitive action.
  Future<Map<String, dynamic>> reauthenticate({String? password, bool withGoogle = false}) async {
    try {
      String? idToken;
      if (withGoogle) {
        final account = await _googleSignIn.signIn();
        idToken = (await account?.authentication)?.idToken;
        if (idToken == null || idToken.isEmpty) return {'success': false, 'error': 'Google did not confirm. Try again.'};
      }
      await _api.post('/auth/reauth', {'password': ?password, 'idToken': ?idToken});
      return {'success': true};
    } catch (e) {
      return _fail(e);
    }
  }

  /// The rider uses Google to sign in (no CoRoute password to confirm with).
  bool get signsInWithGoogle => _provider == 'google';
  String _provider = 'password';

  // ---- 3.57 sign out ----
  static const String keyKeepEmergencyInfo = 'coroute_keep_emergency_info';
  bool _keepEmergencyInfo = true;

  /// The rider's last answer to "Keep emergency info on this phone?" (default yes). While signed out and true,
  /// the lock-screen Medical ID and emergency contact stay on the phone (safety works without an account).
  bool get keepEmergencyInfo => _keepEmergencyInfo;

  /// Signs out. Never during a ride, an SOS, a crash countdown, a convoy or pending emergency texts: then it waits
  /// and the result says `deferred: true` with the message to show. [everywhere]: every device of the account.
  /// [keepEmergencyInfo]: keep the emergency contact and Medical ID on this phone (default yes).
  Future<Map<String, dynamic>> signOut({bool everywhere = false, bool keepEmergencyInfo = true}) async {
    final cause = everywhere ? SignOutCause.userEverywhere : SignOutCause.user;
    if (everywhere) {
      // The gateway must hear it (otherwise nothing changes on the other devices): fail loudly when offline.
      try {
        await _api.revokeAllSessions();
      } catch (e) {
        return _fail(e);
      }
    }
    final state = _guard.state;
    final now = await _guard.runWhenSafe(cause, () => _signOutNow(keepEmergencyInfo: keepEmergencyInfo, revoke: !everywhere));
    if (!now) return {'success': false, 'deferred': true, 'error': SignOutPolicy.deferredMessage(state, cause)};
    return {'success': true};
  }

  /// Older callers: a sign-out that keeps the emergency info on this phone.
  Future<void> logout() async {
    await signOut();
  }

  Future<void> _signOutNow({required bool keepEmergencyInfo, required bool revoke}) async {
    for (final f in List.of(beforeSignOut)) {
      try {
        await f();
      } catch (_) {}
    }
    if (revoke) await _api.revokeSession();
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    await _wipe(keepEmergencyInfo: keepEmergencyInfo);
  }

  /// Forgets the session and the cached personal data on this phone.
  Future<void> _wipe({required bool keepEmergencyInfo}) async {
    _endedDuringRide = false;
    _keepEmergencyInfo = keepEmergencyInfo;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyKeepEmergencyInfo, keepEmergencyInfo);
    } catch (_) {}
    await _clearSession();
    await RideChatStore.clearPersonal();
    // Profile pictures and other images of riders shown in this session.
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
    for (final f in List.of(afterSignOut)) {
      try {
        await f();
      } catch (_) {}
    }
  }

  /// "Galaxy S24" style label for "Where you're signed in" (manufacturer + model; nothing that identifies the phone).
  static String? _deviceLabel;
  Future<Map<String, String>> _device() async {
    if (_deviceLabel == null) {
      try {
        final info = await SafetyNative.deviceInfo().timeout(const Duration(seconds: 2));
        final m = info.manufacturer.trim();
        final model = info.model.trim();
        final brand = m.isEmpty ? '' : '${m[0].toUpperCase()}${m.substring(1)}';
        _deviceLabel = model.toLowerCase().startsWith(m.toLowerCase()) ? model : '$brand $model'.trim();
      } catch (_) {
        _deviceLabel = '';
      }
    }
    // Round 4 ride lock: the same phone may sign in again during its own ride (after a crash, an app kill or a
    // reinstall). The device key is a hash made on the phone (the gateway stores only a keyed hash of it); the
    // install id is random per installation. Neither identifies the phone outside CoRoute.
    _deviceKey ??= await SafetyNative.deviceKey().timeout(const Duration(seconds: 2), onTimeout: () => '');
    _installId ??= await _loadInstallId();
    return {
      'label': _deviceLabel ?? '',
      'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      if ((_deviceKey ?? '').isNotEmpty) 'id': _deviceKey!,
      if ((_installId ?? '').isNotEmpty) 'installId': _installId!,
    };
  }

  static String? _deviceKey;
  static String? _installId;
  static const String _installIdKey = 'coroute_install_id';

  static Future<String> _loadInstallId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final have = prefs.getString(_installIdKey);
      if (have != null && have.length >= 16) return have;
      final rnd = Random.secure();
      final id = base64Url.encode(List<int>.generate(24, (_) => rnd.nextInt(256))).replaceAll('=', '');
      await prefs.setString(_installIdKey, id);
      return id;
    } catch (_) {
      return '';
    }
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
    _username = '';
    _mustChangePassword = false;
    _bikeOnServer = null;
    _bloodGroup = '';
    _allergies = '';
    _medicalNotes = '';
    _smsOptOut = false;
    _medicalLoaded = false;
    _assistHelp = true;
    _assistAsk = true;
    _assistFixFor = null;
    _netConsentAt = 0;
    _netLoaded = false;
    _lastSubscriptionStatus = null;
    onSessionCleared?.call();
    final prefs = await SharedPreferences.getInstance();
    for (final k in [
      AppConstants.keyUserId,
      AppConstants.keyUserRole,
      AppConstants.keyUserName,
      AppConstants.keyVehicleType,
      AppConstants.keyActiveGroupId,
      AppConstants.keyPendingLeaves,
      AppConstants.keyVehicleNo,
    ]) {
      await prefs.remove(k);
    }
    for (final k in [AppConstants.keyUserEmail, AppConstants.keyPhone, AppConstants.keyEmergencyContact, AppConstants.keyEmergencyName]) {
      await _secure.remove(prefs, k);
    }
    _clearing = false;
    notifyListeners();
  }
}
