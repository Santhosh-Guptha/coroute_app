import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/auth/session_policy.dart';

/// 3.57: holds a sign-out back while a ride, an SOS, a crash countdown, a convoy or emergency texts are running
/// (docs/features_355/sessions_and_security.md, "Never signed out mid-ride").
///
/// The server ends a revoked session at once; this phone keeps the rider's screen, profile and emergency
/// contact until [probe] says nothing safety related runs any more, then performs the sign-out it was given.
/// Checked every [recheck] and whenever [check] is called (ride ended, alert resolved).
class SessionGuard extends ChangeNotifier {
  SessionGuard({this.probe, this.recheck = const Duration(seconds: 15)});

  /// The app-wide guard (wired in main.dart: convoy, safety service and emergency-text state).
  static final SessionGuard instance = SessionGuard();

  /// What runs right now. Null (tests, early start-up) reads as nothing running.
  RideSafetyState Function()? probe;
  final Duration recheck;

  RideSafetyState get state {
    try {
      return probe?.call() ?? RideSafetyState.idle;
    } catch (_) {
      // Unsure what runs: treat it as a ride (a sign-out can always wait, an SOS cannot).
      return const RideSafetyState(rideActive: true);
    }
  }

  bool get busy => SignOutPolicy.mustDefer(state);

  bool _pending = false;
  SignOutCause? _cause;
  Future<void> Function()? _action;
  Timer? _timer;

  /// A sign-out is waiting for the ride to end.
  bool get pending => _pending;
  SignOutCause? get pendingCause => _pending ? _cause : null;

  /// The notice to show while a sign-out waits ('' when none waits).
  String get pendingMessage => _pending ? SignOutPolicy.deferredMessage(state, _cause ?? SignOutCause.sessionEnded) : '';

  /// Runs [action] now when nothing safety related runs; otherwise keeps it until the ride is over.
  /// Returns true when it ran now. A later request replaces an earlier waiting one ("everywhere" wins).
  Future<bool> runWhenSafe(SignOutCause cause, Future<void> Function() action) async {
    if (!busy) {
      _clear();
      await action();
      return true;
    }
    if (!_pending || cause == SignOutCause.userEverywhere || _cause == SignOutCause.sessionEnded) {
      _cause = cause;
      _action = action;
    }
    _pending = true;
    _timer ??= Timer.periodic(recheck, (_) => check());
    notifyListeners();
    return false;
  }

  /// Performs a waiting sign-out if nothing safety related runs any more.
  Future<void> check() async {
    if (!_pending || busy) return;
    final action = _action;
    _clear();
    notifyListeners();
    if (action != null) await action();
  }

  /// Forgets a waiting sign-out (the rider signed in again, or the session came back).
  void cancel() {
    if (!_pending) return;
    _clear();
    notifyListeners();
  }

  void _clear() {
    _pending = false;
    _cause = null;
    _action = null;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
