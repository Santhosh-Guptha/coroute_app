import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/marketing/pending_coupon.dart';

/// Keeps a coupon code that came from a coupon QR / link or the Play Install Referrer
/// (docs/features_355/marketing_studio.md) until the rider opens the plan payment screen, for
/// at most [PendingCoupon.keepFor]. Only the code is stored (it is not a secret). Never throws.
class PendingCouponStore {
  PendingCouponStore._();

  static const String keyPending = 'pending_coupon_v1';
  static const String keyReferrerChecked = 'install_referrer_checked_v1';
  static const MethodChannel _channel = MethodChannel('coroute/install_referrer');

  /// Bumped when a new code is saved (the payment screen may listen).
  static final ValueNotifier<String?> changes = ValueNotifier<String?>(null);

  /// Saves [raw] when it is a valid code; returns the cleaned code or null.
  static Future<String?> save(String? raw, {int? nowMs}) async {
    final code = PendingCoupon.clean(raw);
    if (code == null) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = PendingCoupon(code, nowMs ?? DateTime.now().millisecondsSinceEpoch);
      await prefs.setString(keyPending, jsonEncode(p.toJson()));
      changes.value = code;
      return code;
    } catch (e) {
      debugPrint('pending coupon save note: $e');
      return null;
    }
  }

  /// The waiting code, or null (an expired one is removed).
  static Future<String?> read({int? nowMs}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyPending);
      if (raw == null) return null;
      Object? j;
      try {
        j = jsonDecode(raw);
      } catch (_) {
        j = null;
      }
      final p = PendingCoupon.fromJson(j);
      if (p == null || p.isExpired(nowMs ?? DateTime.now().millisecondsSinceEpoch)) {
        await prefs.remove(keyPending);
        return null;
      }
      return p.code;
    } catch (e) {
      debugPrint('pending coupon read note: $e');
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(keyPending);
    } catch (_) {}
  }

  /// Android, first launch only: reads the Play Install Referrer once (native channel
  /// `coroute/install_referrer`, MainActivity) and saves its `coupon=` code. Guarded: never throws,
  /// and is not asked again after one answer (or "not available").
  static Future<String?> checkInstallReferrerOnce() async {
    if (kIsWeb) return null;
    try {
      if (!Platform.isAndroid) return null;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(keyReferrerChecked) == true) return null;
      String? referrer;
      try {
        referrer = await _channel.invokeMethod<String>('getInstallReferrer').timeout(const Duration(seconds: 8));
      } on MissingPluginException {
        referrer = null;
      } on PlatformException catch (e) {
        // SERVICE_UNAVAILABLE etc.: try again next launch; FEATURE_NOT_SUPPORTED: never.
        if (e.code == 'RETRY') return null;
        referrer = null;
      }
      await prefs.setBool(keyReferrerChecked, true);
      final code = PendingCoupon.fromReferrer(referrer);
      return code == null ? null : await save(code);
    } catch (e) {
      debugPrint('install referrer note: $e');
      return null;
    }
  }
}
