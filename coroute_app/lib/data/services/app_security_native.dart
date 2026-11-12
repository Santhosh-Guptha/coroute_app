import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of "Unlock CoRoute".
enum UnlockResult { ok, cancelled, unavailable, busy, error }

/// Round 4: the Android side of the app lock and FLAG_SECURE (android/.../AppSecurityChannel.kt, framework APIs only:
/// BiometricPrompt on Android 9+, the screen lock confirmation before). Every call is safe on other platforms and in
/// tests: nothing happens and the answers say "unavailable".
class AppSecurityNative {
  AppSecurityNative._();

  static const MethodChannel _channel = MethodChannel('coroute/app_security');

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Window FLAG_SECURE (no screenshots, blank in Recents) on or off.
  static Future<void> setSecure(bool on) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('setSecure', {'on': on});
    } catch (_) {/* older native side: nothing to do */}
  }

  /// The phone has a PIN, pattern or password (fingerprints need one too).
  static Future<bool> lockAvailable() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('lockAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Fingerprint / face or the screen lock.
  static Future<UnlockResult> authenticate({String title = 'Unlock CoRoute', String subtitle = ''}) async {
    if (!_supported) return UnlockResult.unavailable;
    try {
      final r = await _channel.invokeMethod<String>('authenticate', {'title': title, 'subtitle': subtitle});
      return switch (r) {
        'ok' => UnlockResult.ok,
        'cancelled' => UnlockResult.cancelled,
        'unavailable' => UnlockResult.unavailable,
        'busy' => UnlockResult.busy,
        _ => UnlockResult.error,
      };
    } catch (_) {
      return UnlockResult.error;
    }
  }

  /// The lock-screen Medical ID card (shown over the lock screen, no unlock needed).
  static Future<bool> openMedicalId() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openMedicalId') ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// FLAG_SECURE while at least one sensitive screen is shown (reference counted: a dialog over the sign-in screen
/// does not clear it when it closes).
class SecureWindow {
  SecureWindow._();

  static int _count = 0;

  /// For tests: how many sensitive screens hold the flag.
  @visibleForTesting
  static int get holders => _count;

  static void acquire() {
    _count++;
    if (_count == 1) AppSecurityNative.setSecure(true).ignore();
  }

  static void release() {
    if (_count == 0) return;
    _count--;
    if (_count == 0) AppSecurityNative.setSecure(false).ignore();
  }
}
