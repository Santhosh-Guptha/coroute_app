/// 3.57 sessions & security: pure rules for the app's session (docs/features_355/sessions_and_security.md).
///
/// * What a gateway answer means for the session: refresh once (`TOKEN_EXPIRED`), end it (only the gateway's own
///   session codes), or nothing (network trouble, captive portals, validation errors never sign anyone out).
/// * When a sign-out must wait: never during a ride, an SOS or crash countdown, a convoy, or while emergency texts
///   are still waiting to go. The session then ends on the server at once, but the phone keeps the rider's screen,
///   profile and emergency contact (SOS texts and the lock-screen Medical ID keep working) until the ride is over.
library;

import 'dart:convert';

/// What the app should do with a gateway answer.
enum SessionAction {
  /// Nothing session related (success, offline, a refusal that is not about the session).
  none,

  /// The short access token ran out: refresh once (single flight), then repeat the call once.
  refresh,

  /// The gateway says the session is over (signed out elsewhere, revoked, deleted, held, blocked).
  end,
}

class SessionPolicy {
  SessionPolicy._();

  /// Gateway codes that end the session on this phone (every app build agrees on these).
  static const Set<String> endingCodes = {'SESSION_INVALID', 'ACCOUNT_GONE', 'ACCOUNT_ON_HOLD', 'ACCOUNT_BLOCKED'};

  /// The access token expired; the session itself is fine.
  static const String tokenExpired = 'TOKEN_EXPIRED';

  /// Decides from an HTTP status and the gateway's `code` (null when the body was not the gateway's).
  /// [canRefresh]: a refresh token is stored and this call was not already a retry.
  static SessionAction actionFor(int status, String? code, {required bool canRefresh}) {
    if (code == null) return SessionAction.none; // not our server (Wi-Fi login page, proxy, outage page)
    if (status == 401 && code == tokenExpired) return canRefresh ? SessionAction.refresh : SessionAction.none;
    if (endingCodes.contains(code)) return SessionAction.end;
    return SessionAction.none;
  }

  /// Seconds left on a JWT (from its `exp`), or null when it cannot be read. Used to refresh just before a
  /// socket reconnect instead of being refused first.
  static int? secondsLeft(String? jwt, {DateTime? now}) {
    if (jwt == null) return null;
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final json = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final m = RegExp(r'"exp"\s*:\s*(\d+)').firstMatch(json);
      if (m == null) return null;
      final exp = int.parse(m.group(1)!);
      final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
      return exp - t;
    } catch (_) {
      return null;
    }
  }
}

/// What is running on the phone right now that a sign-out must never interrupt.
class RideSafetyState {
  const RideSafetyState({
    this.rideActive = false,
    this.inConvoy = false,
    this.sosOrCountdown = false,
    this.pendingEmergencyTexts = false,
  });

  /// A convoy ride or an offline solo ride is being recorded.
  final bool rideActive;

  /// The rider is a member of a live convoy.
  final bool inConvoy;

  /// An SOS is open or a crash / rider-down countdown is running.
  final bool sosOrCountdown;

  /// Emergency texts are still waiting to be sent or confirmed.
  final bool pendingEmergencyTexts;

  static const RideSafetyState idle = RideSafetyState();

  bool get busy => rideActive || inConvoy || sosOrCountdown || pendingEmergencyTexts;

  /// Words for the "after the ride" notice (the first reason that applies).
  String get reason {
    if (sosOrCountdown) return 'an emergency is open';
    if (pendingEmergencyTexts) return 'emergency texts are still being sent';
    if (rideActive || inConvoy) return 'you are on a ride';
    return '';
  }
}

/// Why a sign-out was asked for.
enum SignOutCause { user, userEverywhere, sessionEnded }

class SignOutPolicy {
  SignOutPolicy._();

  /// A sign-out must wait while anything safety related runs. This holds for every cause: the rider's own tap
  /// (the button explains and offers it after the ride), a revoke from another device, an expired session.
  static bool mustDefer(RideSafetyState state) => state.busy;

  /// The text the app shows while a sign-out waits.
  static String deferredMessage(RideSafetyState state, SignOutCause cause) {
    final why = state.reason.isEmpty ? 'you are on a ride' : state.reason;
    switch (cause) {
      case SignOutCause.sessionEnded:
        return 'Your session ended, but $why. Safety features keep working; you will be signed out when the ride is over.';
      case SignOutCause.user:
      case SignOutCause.userEverywhere:
        return 'You can sign out after the ride: $why.';
    }
  }
}
