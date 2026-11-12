import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of asking the phone to unlock from the locked cockpit.
enum KeyguardUnlock { ok, cancelled, notLocked, error }

/// The Android side of the lock-screen cockpit and the ride screen's heat check
/// (android/.../RideWindowChannel.kt, MethodChannel "coroute/ride_window"):
///  * setCockpitOverKeyguard {on}: MainActivity over the keyguard (setShowWhenLocked; window flag below API 27).
///    Never turns the screen on (only the SOS / crash paths do).
///  * keyguardLocked: KeyguardManager.isKeyguardLocked; changes arrive as "onKeyguardChanged" {locked}.
///  * requestUnlock: KeyguardManager.requestDismissKeyguard (API 26+; a dismiss-keyguard window flag before).
///  * thermalStatus: PowerManager.getCurrentThermalStatus (API 29+, 0 before); changes as "onThermalChanged" {status}.
/// Tests use a fake [RideWindowPort].
abstract class RideWindowPort {
  Future<void> setCockpitOverKeyguard(bool on);
  Future<bool> keyguardLocked();
  Future<KeyguardUnlock> requestUnlock();
  Future<int> thermalStatus();

  /// Called by the native side; set once by the service.
  void listen({required void Function(bool locked) onKeyguard, required void Function(int status) onThermal});
}

class RideWindowNative implements RideWindowPort {
  RideWindowNative();

  static const MethodChannel _channel = MethodChannel('coroute/ride_window');

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> setCockpitOverKeyguard(bool on) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('setCockpitOverKeyguard', {'on': on});
    } catch (_) {/* no native side (tests, other platforms) */}
  }

  @override
  Future<bool> keyguardLocked() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('keyguardLocked') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<KeyguardUnlock> requestUnlock() async {
    if (!_supported) return KeyguardUnlock.notLocked;
    try {
      final r = await _channel.invokeMethod<String>('requestUnlock');
      return switch (r) {
        'ok' => KeyguardUnlock.ok,
        'cancelled' => KeyguardUnlock.cancelled,
        'notLocked' => KeyguardUnlock.notLocked,
        _ => KeyguardUnlock.error,
      };
    } catch (_) {
      return KeyguardUnlock.error;
    }
  }

  @override
  Future<int> thermalStatus() async {
    if (!_supported) return 0;
    try {
      return await _channel.invokeMethod<int>('thermalStatus') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  void listen({required void Function(bool locked) onKeyguard, required void Function(int status) onThermal}) {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      switch (call.method) {
        case 'onKeyguardChanged':
          onKeyguard(args is Map && args['locked'] == true);
        case 'onThermalChanged':
          final s = args is Map ? args['status'] : null;
          onThermal(s is int ? s : 0);
      }
      return null;
    });
  }
}
