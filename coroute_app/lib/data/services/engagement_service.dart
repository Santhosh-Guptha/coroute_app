import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../domain/diag/diag_log.dart';
import '../../domain/engagement/engagement_config.dart';
import '../../domain/engagement/rating_ask_scheduler.dart';
import 'api_client.dart';

/// 3.55 ratings & reviews (docs/features_355/ratings_reviews.md): the admin's engagement templates
/// (GET /api/app/engagement-config, cached on the phone with built-in defaults), the "Rate CoRoute"
/// state (asks, the ride waiting for its ask, the last problem), Google Play's in-app review card
/// (native channel `coroute/in_app_review`, Play Core review library) and in-app feedback
/// (POST /api/me/feedback). Every call is safe: nothing here throws at a screen or blocks a ride.
class EngagementService extends ChangeNotifier {
  EngagementService(this._api, {bool load = true}) {
    _instance = this;
    if (load) unawaited(_restore());
  }

  final ApiClient? _api;

  static EngagementService? _instance;

  /// The live service (set when main.dart creates it); null in tests and before start-up.
  static EngagementService? get instance => _instance;

  static const MethodChannel _channel = MethodChannel('coroute/in_app_review');

  static const String _kConfig = 'coroute_engagement_config_v1';
  static const String _kConfigAt = 'coroute_engagement_config_at';
  static const String _kAsks = 'coroute_rate_asks_v1';
  static const String _kPending = 'coroute_rate_pending_since';
  static const String _kLastRideEnd = 'coroute_rate_last_ride_end';
  static const String _kLastRideProblem = 'coroute_rate_last_ride_problem';
  static const String _kLastProblem = 'coroute_rate_last_problem';
  static const String _kReportDismissed = 'coroute_wrapup_report_dismissed_v1';

  /// The server copy is refreshed at most this often.
  static const Duration refreshEvery = Duration(hours: 6);

  EngagementConfig _config = EngagementConfig.defaults;
  EngagementConfig get config => _config;

  int _fetchedAt = 0;
  bool _fetching = false;

  // ------------------------------------------------------------------ config
  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kConfig);
      if (raw != null && raw.isNotEmpty) _config = EngagementConfig.parse(raw);
      _fetchedAt = prefs.getInt(_kConfigAt) ?? 0;
      notifyListeners();
    } catch (_) {}
    unawaited(refresh());
  }

  /// Fetches the admin's templates when the saved copy is older than [refreshEvery] (or [force]).
  Future<void> refresh({bool force = false}) async {
    final api = _api;
    if (api == null || !api.hasToken || _fetching) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _fetchedAt < refreshEvery.inMilliseconds) return;
    _fetching = true;
    try {
      final res = await api.get('/app/engagement-config');
      if (res is Map && res['config'] is Map) {
        _config = EngagementConfig.parse(res);
        _fetchedAt = now;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kConfig, jsonEncode(_config.toJson()));
        await prefs.setInt(_kConfigAt, now);
        notifyListeners();
      }
    } catch (_) {
      // Offline or an older gateway: the saved copy / defaults stay.
    } finally {
      _fetching = false;
    }
  }

  // ------------------------------------------------------------------ "Rate CoRoute" state
  /// A ride ended. A clean ride leaves a pending ask (asked once the wrap-up closes, or at the next
  /// app open); a ride with SOS, crash alarm or a failed SOS clears it and starts the problem quiet.
  Future<void> onRideEnded({required bool hadProblem, int? endedAtMs}) async {
    final at = endedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastRideEnd, at);
      await prefs.setBool(_kLastRideProblem, hadProblem);
      await prefs.setInt(_kPending, RatingAskScheduler.pendingAfterRide(hadProblem: hadProblem, endedAtMs: at));
      if (hadProblem) await prefs.setInt(_kLastProblem, at);
    } catch (_) {}
  }

  /// A problem outside the ride end (a failed SOS send, a crash alarm): no ask for a while.
  static Future<void> noteProblem({int? atMs}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastProblem, atMs ?? DateTime.now().millisecondsSinceEpoch);
      await prefs.setInt(_kPending, 0);
    } catch (_) {}
  }

  /// Error entries in this app session's log, and whether one was an SOS / crash problem.
  static ({int errors, bool safetyProblem}) sessionHealth() {
    var errors = 0;
    var safety = false;
    try {
      for (final e in DiagLog.recent) {
        if (e.session != DiagLog.session || e.level != DiagLevel.error) continue;
        errors++;
        if (e.cat == DiagCat.sos || e.cat == DiagCat.crash) safety = true;
      }
    } catch (_) {}
    return (errors: errors, safetyProblem: safety);
  }

  /// What the scheduler needs from the phone (asks, pending ride, last problem).
  Future<({List<int> asks, int pendingSince, int lastRideEnd, bool lastRideProblem, int lastProblem})> askState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kAsks);
      final asks = <int>[];
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is List) asks.addAll(j.whereType<num>().map((e) => e.toInt()));
      }
      return (
        asks: asks,
        pendingSince: prefs.getInt(_kPending) ?? 0,
        lastRideEnd: prefs.getInt(_kLastRideEnd) ?? 0,
        lastRideProblem: prefs.getBool(_kLastRideProblem) ?? false,
        lastProblem: prefs.getInt(_kLastProblem) ?? 0,
      );
    } catch (_) {
      // Unreadable: behave as "asked just now", so nothing is shown.
      final now = DateTime.now().millisecondsSinceEpoch;
      return (asks: [now], pendingSince: 0, lastRideEnd: now, lastRideProblem: false, lastProblem: 0);
    }
  }

  /// Counted as asked BEFORE the card opens, so it never comes back sooner whatever happens.
  Future<bool> markAsked({int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      final st = await askState();
      final asks = RatingAskScheduler.prune([...st.asks, now], now);
      await prefs.setString(_kAsks, jsonEncode(asks));
      await prefs.setInt(_kPending, 0);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------ Play in-app review
  /// Opens Google Play's in-app review card (requestReviewFlow -> launchReviewFlow). Google decides
  /// whether it really shows (quota); the result never says whether the rider rated. Returns false
  /// when the flow could not run at all (no Play Store, not Android, error). Never throws.
  static Future<bool> launchInAppReview() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final r = await _channel.invokeMethod<Object?>('requestReview').timeout(const Duration(minutes: 3));
      return r is Map && r['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// The store page links for this platform, tried in order (empty where there is no store page).
  static List<Uri> storeUris() {
    if (kIsWeb) return const [];
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final id = AppConstants.androidPackageId;
        return [Uri.parse('market://details?id=$id'), Uri.parse('https://play.google.com/store/apps/details?id=$id')];
      case TargetPlatform.iOS:
        final uri = Uri.tryParse(AppConstants.iosAppStoreUrl.trim());
        return uri == null || uri.scheme != 'https' ? const [] : [uri];
      default:
        return const [];
    }
  }

  /// Opens the first store link that works (the Play Store app, then the web page).
  static Future<bool> openStoreListing() async {
    for (final u in storeUris()) {
      try {
        if (await launchUrl(u, mode: LaunchMode.externalApplication)) return true;
      } catch (_) {
        // No store app for market://: try the next link.
      }
    }
    return false;
  }

  /// The card closed this fast: Google most likely did not show it (quota), so the explicit
  /// "Rate CoRoute" row opens the store page instead.
  static const Duration notShownBelow = Duration(milliseconds: 700);

  /// The explicit "Rate CoRoute" row: Google's in-app card, else the store page. Not counted as an
  /// automatic ask. Returns false when neither could open.
  static Future<bool> rateFromRow() async {
    final sw = Stopwatch()..start();
    final ok = await launchInAppReview();
    if (ok && sw.elapsed >= notShownBelow) return true;
    return openStoreListing();
  }

  // ------------------------------------------------------------------ feedback
  /// Topics of the in-app feedback (same ids as the gateway).
  static const List<String> feedbackTopics = ['general', 'bug', 'idea', 'ride', 'places', 'other'];
  static const int feedbackMin = 5;
  static const int feedbackMax = 1000;

  /// Sends in-app feedback. Throws [ApiException] (the screen shows the message).
  Future<void> sendFeedback({required String message, String topic = 'general', bool contactOk = false, String appVersion = ''}) async {
    final api = _api;
    if (api == null) throw const ApiException(0, 'Not signed in.');
    await api.post('/me/feedback', {
      'message': message.trim(),
      'topic': feedbackTopics.contains(topic) ? topic : 'general',
      'contactOk': contactOk,
      'appVersion': appVersion,
      'platform': kIsWeb ? 'web' : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android'),
    });
  }

  // ------------------------------------------------------------------ trip report re-offer
  /// The rider closed the quick trip review on this ride's report: not offered there again.
  static Future<void> dismissOnReport(String tripId) async {
    if (tripId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kReportDismissed) ?? <String>[];
      if (list.contains(tripId)) return;
      list.add(tripId);
      await prefs.setStringList(_kReportDismissed, list.length > 50 ? list.sublist(list.length - 50) : list);
    } catch (_) {}
  }

  static Future<bool> dismissedOnReport(Iterable<String> tripIds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kReportDismissed) ?? const <String>[];
      return tripIds.any(list.contains);
    } catch (_) {
      return true; // unreadable: do not nag
    }
  }
}
