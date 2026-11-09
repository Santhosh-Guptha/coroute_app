/// 3.55 coupon QR / link (docs/features_355/marketing_studio.md): `<origin>/get?coupon=CODE` and the
/// Play Install Referrer `coupon=CODE` hand a coupon code to the app. The code is kept for
/// [PendingCoupon.keepFor] and prefilled (never auto-purchased) on the plan payment screen, where
/// the server validates it as usual. Pure: no I/O.
library;

class PendingCoupon {
  final String code;

  /// When it was received (ms since epoch).
  final int savedAtMs;

  const PendingCoupon(this.code, this.savedAtMs);

  /// How long a code from a link waits for the rider.
  static const Duration keepFor = Duration(days: 7);

  /// Same format the website accepts: A-Z, 0-9, '-' and '_', at most 24 characters.
  static final RegExp _format = RegExp(r'^[A-Z0-9_-]{1,24}$');

  /// The cleaned code (trimmed, upper case) or null when it is not a valid coupon code.
  static String? clean(String? raw) {
    if (raw == null) return null;
    final c = raw.trim().toUpperCase();
    return _format.hasMatch(c) ? c : null;
  }

  /// The coupon of an app link `https://<site>/get?coupon=CODE` (also `coroute://get?coupon=`), or
  /// null for any other link.
  static String? fromUri(Uri uri) {
    final isGet = (uri.scheme == 'coroute' && uri.host == 'get') ||
        ((uri.scheme == 'https' || uri.scheme == 'http') && _isGetPath(uri.path));
    if (!isGet) return null;
    return clean(uri.queryParameters['coupon']);
  }

  static bool _isGetPath(String path) {
    final p = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
    return p == '/get' || p == '/get.html';
  }

  /// The coupon of a Play Install Referrer string (`coupon=CODE&utm_source=...`, URL-encoded or not).
  static String? fromReferrer(String? referrer) {
    if (referrer == null || referrer.isEmpty) return null;
    var r = referrer.trim();
    // Play may hand it over still encoded once (coupon%3DXYZ).
    if (!r.contains('=') && r.contains('%')) {
      try {
        r = Uri.decodeComponent(r);
      } catch (_) {
        return null;
      }
    }
    try {
      return clean(Uri.splitQueryString(r)['coupon']);
    } catch (_) {
      return null;
    }
  }

  bool isExpired(int nowMs) => nowMs - savedAtMs > keepFor.inMilliseconds || nowMs < savedAtMs - 60000;

  Map<String, Object> toJson() => {'code': code, 'savedAt': savedAtMs};

  static PendingCoupon? fromJson(Object? j) {
    if (j is! Map) return null;
    final code = clean(j['code']?.toString());
    final at = j['savedAt'];
    if (code == null || at is! num) return null;
    return PendingCoupon(code, at.toInt());
  }
}
