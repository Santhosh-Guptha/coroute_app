import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/auth/session_policy.dart';
import '../../domain/security/app_lock_policy.dart';
import 'app_security_native.dart';
import 'session_guard.dart';

/// Round 4: "Lock CoRoute with fingerprint or screen lock" (off by default). Rules in [AppLockPolicy]: lock on a cold
/// start and after the delay in the background, never during a ride, convoy, SOS, crash countdown or pending
/// emergency texts (an existing lock drops at once when one starts). SOS, Call 112 and the Medical ID stay reachable.
class AppLockService extends ChangeNotifier with WidgetsBindingObserver {
  AppLockService({RideSafetyState Function()? state, bool Function()? signedIn, Future<UnlockResult> Function()? unlock, Future<bool> Function()? lockAvailable})
      : _state = state ?? (() => SessionGuard.instance.state),
        _signedIn = signedIn ?? (() => true),
        _unlock = unlock ?? (() => AppSecurityNative.authenticate(subtitle: 'Your rides and profile stay private')),
        _lockAvailable = lockAvailable ?? AppSecurityNative.lockAvailable;

  static const String keyEnabled = 'coroute_app_lock';
  static const String keyDelayMin = 'coroute_app_lock_delay_min';

  final RideSafetyState Function() _state;
  bool Function() _signedIn;
  final Future<UnlockResult> Function() _unlock;
  final Future<bool> Function() _lockAvailable;

  bool _enabled = false;
  int _delayMin = AppLockPolicy.defaultDelay.inMinutes;
  bool _available = false;
  bool _locked = false;
  bool _bypass = false; // SOS / Medical ID / Call 112 opened from the lock screen
  bool _bypassExternal = false; // ... in another screen (call, Medical ID card): back on resume
  DateTime? _backgroundedAt;
  Timer? _recheck;
  bool _started = false;

  bool get enabled => _enabled;
  int get delayMinutes => _delayMin;
  bool get lockAvailable => _available;

  /// The lock screen is shown now.
  bool get locked => _locked && !_bypass && AppLockPolicy.stayLocked(locked: _locked, state: _safeState());

  set signedIn(bool Function() f) => _signedIn = f;

  RideSafetyState _safeState() {
    try {
      return _state();
    } catch (_) {
      return const RideSafetyState(rideActive: true); // unsure: never lock
    }
  }

  /// Reads the settings and locks on a cold start when the rules say so.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final p = await SharedPreferences.getInstance();
      _enabled = p.getBool(keyEnabled) ?? false;
      _delayMin = p.getInt(keyDelayMin) ?? AppLockPolicy.defaultDelay.inMinutes;
    } catch (_) {}
    _available = await _lockAvailable();
    WidgetsBinding.instance.addObserver(this);
    if (AppLockPolicy.lockOnColdStart(enabled: _enabled, lockAvailable: _available, signedIn: _signedIn(), state: _safeState())) _lock();
    notifyListeners();
  }

  void _lock() {
    _locked = true;
    _bypass = false;
    _recheck?.cancel();
    // A ride, SOS or crash countdown that starts while locked unlocks at once (checked every 2 s).
    _recheck = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_locked && !AppLockPolicy.stayLocked(locked: true, state: _safeState())) {
        _locked = false;
        _recheck?.cancel();
        notifyListeners();
      }
    });
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final at = _backgroundedAt;
      _backgroundedAt = null;
      if (_bypass && _bypassExternal) {
        // Back from the Medical ID card or a call started on the lock screen: the lock screen again.
        _bypass = false;
        _bypassExternal = false;
        notifyListeners();
        return;
      }
      if (_bypass) return;
      if (AppLockPolicy.lockOnResume(enabled: _enabled, lockAvailable: _available, signedIn: _signedIn(), state: _safeState(),
          backgroundedAt: at, now: DateTime.now(), delay: AppLockPolicy.delayOf(_delayMin))) {
        _lock();
      }
    }
  }

  /// Unlock with fingerprint / face or the screen lock. True when unlocked.
  Future<bool> unlock() async {
    final r = await _unlock();
    if (r == UnlockResult.ok || r == UnlockResult.unavailable) {
      // No screen lock any more (removed in Android settings): nothing to unlock with, so the lock goes.
      _locked = false;
      _bypass = false;
      _recheck?.cancel();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// SOS, Call 112 or the Medical ID from the lock screen: the lock steps aside (an SOS then keeps it away by the
  /// rules); [relock] puts it back when the action ended without an emergency.
  void bypassForSafety({bool external = false}) {
    _bypass = true;
    _bypassExternal = external;
    notifyListeners();
  }

  void relock() {
    if (!_bypass) return;
    _bypass = false;
    _bypassExternal = false;
    notifyListeners();
  }

  /// Settings switch. Turning it on needs a screen lock and one successful unlock (so nobody locks themselves out).
  Future<String?> setEnabled(bool on) async {
    if (on) {
      _available = await _lockAvailable();
      if (!_available) return 'Set a screen lock (PIN, pattern or password) in Android settings first.';
      final r = await _unlock();
      if (r != UnlockResult.ok) return r == UnlockResult.cancelled ? null : 'Could not confirm it is you. Try again.';
    }
    _enabled = on;
    if (!on) {
      _locked = false;
      _recheck?.cancel();
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(keyEnabled, on);
    } catch (_) {}
    notifyListeners();
    return null;
  }

  Future<void> setDelayMinutes(int minutes) async {
    _delayMin = AppLockPolicy.delayOf(minutes).inMinutes;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(keyDelayMin, _delayMin);
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    _recheck?.cancel();
    if (_started) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
