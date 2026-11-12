import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../domain/auth/session_policy.dart';
import '../../domain/security/lock_screen_cockpit_policy.dart';
import 'ride_window_native.dart';
import 'session_guard.dart';

/// Cockpit on the lock screen while riding (docs/features_355/lock_screen_cockpit.md). Rules in
/// [LockScreenCockpitPolicy].
///
/// Keeps MainActivity over the keyguard while a ride is on, someone is signed in, the setting is on and the cockpit
/// is in front; turns it off at once when any of these ends. Tracks the keyguard (locked mode), the screens opened
/// above the cockpit ([guard], a NavigatorObserver on the app's navigator) and the phone's thermal status (for
/// the Ride AOD). Nothing is stored.
class LockScreenCockpitService extends ChangeNotifier {
  LockScreenCockpitService({
    RideWindowPort? port,
    RideSafetyState Function()? ride,
    bool Function()? signedIn,
    bool Function()? settingOn,
    bool Function()? safetyFlowOpen,
    int Function()? clock,
  })  : _port = port ?? RideWindowNative(),
        _ride = ride ?? (() => SessionGuard.instance.state),
        _signedIn = signedIn ?? (() => false),
        _settingOn = settingOn ?? (() => true),
        _safetyFlowOpen = safetyFlowOpen ?? (() => false),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final RideWindowPort _port;
  final RideSafetyState Function() _ride;
  bool Function() _signedIn;
  bool Function() _settingOn;
  bool Function() _safetyFlowOpen;
  final int Function() _clock;

  /// Observer for the app's (root) navigator: put it in MaterialApp.navigatorObservers.
  late final LockedRouteGuard guard = LockedRouteGuard._(this);

  Route<dynamic>? _cockpitRoute;
  bool _cockpitVisible = false;
  bool _keyguardLocked = false;
  bool _over = false;
  int _thermal = 0;
  bool _aodShowing = false;
  bool _unlocking = false;
  bool _started = false;
  bool _disposed = false;
  int _lastTapMs = 0;

  set signedIn(bool Function() f) => _signedIn = f;
  set settingOn(bool Function() f) => _settingOn = f;
  set safetyFlowOpen(bool Function() f) => _safetyFlowOpen = f;

  /// MainActivity is (asked to be) shown over the keyguard.
  bool get overKeyguard => _over;

  bool get keyguardLocked => _keyguardLocked;

  /// Locked mode: over a keyguard that is still locked.
  bool get locked => LockScreenCockpitPolicy.lockedMode(overKeyguard: _over, keyguardLocked: _keyguardLocked);

  /// PowerManager thermal status (0 when unknown or below Android 10).
  int get thermalStatus => _thermal;

  /// The Ride AOD is on screen (the padlock chip hides on the black screen).
  bool get aodShowing => _aodShowing;
  set aodShowing(bool v) {
    if (v == _aodShowing) return;
    _aodShowing = v;
    _notifySoon();
  }

  /// A private screen above the cockpit waits for the unlock (the gate covers it).
  bool get shieldShowing => locked && guard.topIsPending;

  bool get unlocking => _unlocking;

  /// The cockpit is the screen in front (private screens opened after an unlock turn this off).
  bool get cockpitInFront => _cockpitVisible && _cockpitRoute != null && !guard._privateAbove(_cockpitRoute);

  /// Any pointer down anywhere in the app (from the gate): tells the rider's own taps from screens opening by themselves.
  void noteTap() => _lastTapMs = _clock();

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _port.listen(onKeyguard: _onKeyguard, onThermal: _onThermal);
    final locked = await _port.keyguardLocked();
    final thermal = await _port.thermalStatus();
    if (_disposed) return;
    _keyguardLocked = locked;
    _thermal = thermal;
    refresh();
    notifyListeners();
  }

  /// The ride screen reports itself: its route and whether it is the visible screen of an active ride.
  void setCockpit({required Route<dynamic>? route, required bool visible}) {
    if (identical(route, _cockpitRoute) && visible == _cockpitVisible) return;
    _cockpitRoute = route;
    _cockpitVisible = visible && route != null;
    refresh();
  }

  /// The ride screen goes away (dispose): only clears when it is still the registered one.
  void clearCockpit(Route<dynamic>? route) {
    if (route != null && !identical(route, _cockpitRoute)) return;
    setCockpit(route: null, visible: false);
  }

  /// Re-evaluates the rules (ride, sign-in, setting or screens changed) and tells the native side on a change.
  void refresh() {
    if (_disposed) return;
    final want = LockScreenCockpitPolicy.showOverKeyguard(
      ride: _safeRide(),
      signedIn: _safe(_signedIn),
      settingOn: _safe(_settingOn),
      cockpitInFront: cockpitInFront,
    );
    if (want == _over) return;
    _over = want;
    _port.setCockpitOverKeyguard(want).ignore();
    if (!locked) guard._promotePending();
    _notifySoon();
  }

  RideSafetyState _safeRide() {
    try {
      return _ride();
    } catch (_) {
      return RideSafetyState.idle; // unsure: never over the keyguard (the safe side for privacy)
    }
  }

  static bool _safe(bool Function() f) {
    try {
      return f();
    } catch (_) {
      return false;
    }
  }

  void _onKeyguard(bool locked) {
    if (_disposed || locked == _keyguardLocked) return;
    _keyguardLocked = locked;
    if (!this.locked) guard._promotePending();
    refresh();
    _notifySoon();
  }

  void _onThermal(int status) {
    if (_disposed || status == _thermal) return;
    _thermal = status;
    _notifySoon();
  }

  /// Asks the phone to unlock (fingerprint / PIN over our window). True when it is unlocked now.
  Future<bool> requestUnlock() async {
    if (!locked) return true;
    if (_unlocking) return false;
    _unlocking = true;
    _notifySoon();
    try {
      final r = await _port.requestUnlock();
      var unlocked = r == KeyguardUnlock.ok || r == KeyguardUnlock.notLocked;
      if (!unlocked) unlocked = !(await _port.keyguardLocked());
      if (_disposed) return unlocked;
      if (unlocked) {
        _keyguardLocked = false;
        guard._promotePending();
        refresh();
      }
      return unlocked;
    } finally {
      _unlocking = false;
      _notifySoon();
    }
  }

  /// Runs [run] at once when [action] is allowed (or the phone is not locked); otherwise after the unlock, or not
  /// at all when the rider cancels it. True when [run] ran.
  Future<bool> runUnlocked(CockpitAction action, FutureOr<void> Function() run) async {
    if (!LockScreenCockpitPolicy.needsUnlock(locked: locked, action: action)) {
      await run();
      return true;
    }
    if (!await requestUnlock()) return false;
    await run();
    return true;
  }

  /// The covered screen: unlock and show it, or close it when the unlock is cancelled.
  Future<bool> unlockForPending() async {
    final ok = await requestUnlock();
    if (!ok) guard.closePending();
    return ok;
  }

  void _routeOpenedWhileLocked() {
    if (LockScreenCockpitPolicy.askUnlockAtOnce(nowMs: _clock(), lastTapMs: _lastTapMs)) {
      // After the push finished: the system unlock sheet comes over our window.
      scheduleMicrotask(() => unlockForPending().ignore());
    }
  }

  void _routesChanged() {
    refresh();
    _notifySoon();
  }

  /// Never notifies in the middle of a build (navigator observers run inside a push).
  void _notifySoon() {
    if (_disposed) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks || phase == SchedulerPhase.midFrameMicrotasks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_over) _port.setCockpitOverKeyguard(false).ignore();
    _over = false;
    super.dispose();
  }
}

/// One screen on the app's navigator, as the locked cockpit sees it.
class _GuardEntry {
  _GuardEntry(this.route, {required this.allowed, required this.pending});
  final Route<dynamic> route;

  /// A safety screen: never covered.
  final bool allowed;

  /// Opened while locked: covered until the unlock.
  bool pending;
}

/// Watches the screens opened on the app's navigator. While the cockpit is locked a new screen that is not a
/// safety screen is "pending": the gate covers it and asks for the unlock (at once for the rider's own tap);
/// a cancelled unlock closes it again. A private screen opened while unlocked turns the over-keyguard window off.
class LockedRouteGuard extends NavigatorObserver {
  LockedRouteGuard._(this._service);

  final LockScreenCockpitService _service;
  final List<_GuardEntry> _entries = [];

  int _indexOf(Route<dynamic>? r) => r == null ? -1 : _entries.indexWhere((e) => identical(e.route, r));

  /// The top screen waits for the unlock.
  bool get topIsPending => _entries.isNotEmpty && _entries.last.pending;

  /// Number of screens waiting for the unlock (tests).
  int get pendingCount => _entries.where((e) => e.pending).length;

  bool _privateAbove(Route<dynamic>? cockpit) {
    final i = _indexOf(cockpit);
    for (var k = i + 1; k < _entries.length; k++) {
      final e = _entries[k];
      if (!e.allowed && !e.pending) return true;
    }
    return false;
  }

  _GuardEntry _classify(Route<dynamic> route) {
    final cockpit = _service._cockpitRoute;
    // Screens below or before the cockpit (the app's start screens) are not the cockpit's business.
    if (cockpit == null || _indexOf(cockpit) < 0 || identical(route, cockpit)) {
      return _GuardEntry(route, allowed: true, pending: false);
    }
    final decision = LockScreenCockpitPolicy.routeWhileLocked(
      routeName: route.settings.name,
      safetyFlowOpen: LockScreenCockpitService._safe(_service._safetyFlowOpen),
    );
    final allowed = decision == LockedRouteDecision.allowed;
    return _GuardEntry(route, allowed: allowed, pending: !allowed && _service.locked);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final e = _classify(route);
    _entries.add(e);
    _service._routesChanged();
    if (e.pending) _service._routeOpenedWhileLocked();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _drop(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _drop(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = _indexOf(oldRoute);
    if (newRoute == null) {
      if (oldRoute != null) _drop(oldRoute);
      return;
    }
    final e = _classify(newRoute);
    if (i >= 0) {
      _entries[i] = e;
    } else {
      _entries.add(e);
    }
    _service._routesChanged();
  }

  void _drop(Route<dynamic> route) {
    final i = _indexOf(route);
    if (i < 0) return;
    _entries.removeAt(i);
    _service._routesChanged();
  }

  /// Unlocked: waiting screens are simply open now.
  void _promotePending() {
    for (final e in _entries) {
      e.pending = false;
    }
  }

  /// The unlock was cancelled: the waiting screens close (their callers get null, as for Back).
  void closePending() {
    final waiting = _entries.where((e) => e.pending).map((e) => e.route).toList();
    for (final r in waiting.reversed) {
      final nav = r.navigator;
      if (nav != null && r.isActive) nav.removeRoute(r);
    }
  }
}
