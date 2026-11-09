import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/places/place_dwell.dart';
import '../../domain/places/place_poi.dart';
import '../../domain/places/ride_end_reviews.dart';
import '../../domain/tracking/track_point.dart';
import 'api_client.dart';

/// "★ 4.3 · 12 CoRoute riders" for one place.
class PlaceRatingSummary {
  const PlaceRatingSummary({required this.avg, required this.count});
  final double avg;
  final int count;

  static PlaceRatingSummary? fromJson(Object? j) {
    if (j is! Map) return null;
    final count = (j['count'] as num?)?.toInt() ?? 0;
    final avg = (j['avg'] as num?)?.toDouble();
    if (count <= 0 || avg == null || !avg.isFinite) return null;
    return PlaceRatingSummary(avg: avg.clamp(1, 5).toDouble(), count: count);
  }
}

/// One CoRoute rider review as the gateway shows it: first name only, never the account.
class PlaceReviewItem {
  const PlaceReviewItem({
    required this.reviewId,
    required this.firstName,
    required this.rating,
    this.text = '',
    this.createdAt = 0,
    this.photos = const [],
    this.photosPending = 0,
    this.status = 'PUBLISHED',
    this.dwellMin = 0,
  });

  final String reviewId;
  final String firstName;
  final int rating;
  final String text;
  final int createdAt;

  /// Approved photos: gateway paths relative to [AppConfig.apiUrl] (`/places/reviews/<id>/photo/<pid>`).
  final List<String> photos;

  /// Mine only: photos waiting for the quick check.
  final int photosPending;
  final String status;
  final int dwellMin;

  static PlaceReviewItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['reviewId']?.toString() ?? '';
    final rating = (j['rating'] as num?)?.toInt() ?? 0;
    if (id.isEmpty || rating < 1 || rating > 5) return null;
    return PlaceReviewItem(
      reviewId: id,
      firstName: (j['firstName']?.toString() ?? '').trim().isEmpty ? 'Rider' : j['firstName'].toString().trim(),
      rating: rating,
      text: j['text']?.toString() ?? '',
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      photos: [
        if (j['photos'] is List)
          for (final p in j['photos'] as List)
            if (p is String && p.isNotEmpty) PlaceReviewService.relativePath(p),
      ],
      photosPending: (j['photosPending'] as num?)?.toInt() ?? 0,
      status: j['status']?.toString() ?? 'PUBLISHED',
      dwellMin: (j['dwellMin'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What GET /places/reviews?placeId= returns.
class PlaceReviewsPage {
  const PlaceReviewsPage({this.summary, this.reviews = const [], this.mine});
  final PlaceRatingSummary? summary;
  final List<PlaceReviewItem> reviews;
  final PlaceReviewItem? mine;

  static PlaceReviewsPage fromJson(Object? j) {
    if (j is! Map) return const PlaceReviewsPage();
    return PlaceReviewsPage(
      summary: PlaceRatingSummary.fromJson(j['summary']),
      reviews: [
        if (j['reviews'] is List)
          for (final r in j['reviews'] as List) ?PlaceReviewItem.fromJson(r),
      ],
      mine: PlaceReviewItem.fromJson(j['mine']),
    );
  }
}

/// CoRoute rider place reviews (3.55, Shanmuk's idea): after a rider spent a while at a
/// restaurant, a stay or any place, ask politely (once per place per day) for a quick rating that
/// helps the riders coming after; show those ratings and approved photos on the map and in the
/// place card.
///
/// * Fixes come from [attachFixes] (ConvoyService.myFixes, the ride's own GPS: no extra GPS);
///   places near me from [placesSource] (the map places cache the cockpit already has).
/// * The prompt is offered only when stopped (under 5 km/h) or after the ride, never while riding,
///   never while an SOS or crash alarm is open ([emergencyOpen]).
/// * Ratings for the map: [onViewport] fetches the per-place averages of the box on screen,
///   throttled and cached; [reviewsFor] the reviews of one place (cached for 2 minutes).
/// * Errors (offline) are silent for the background fetches; [submit] and [uploadPhoto] throw
///   [ApiException] with the gateway's friendly message.
class PlaceReviewService extends ChangeNotifier {
  PlaceReviewService(this._api, {int Function()? clock, bool loadPrefs = true}) : _clock = clock ?? _wall {
    if (loadPrefs) unawaited(_loadAsked());
  }

  static int _wall() => DateTime.now().millisecondsSinceEpoch;
  static const String prefsKey = 'place_review_asked_v1';
  static const int maxTextChars = 300;

  /// Places further than this are not looked at for a dwell (cheap box filter first).
  static const double nearbyM = 150;
  static const Duration reviewsTtl = Duration(minutes: 2);
  static const Duration summaryMinGap = Duration(seconds: 20);
  static const Duration summaryTtl = Duration(minutes: 5);
  static const Duration errorBackoff = Duration(seconds: 60);

  final ApiClient _api;
  final int Function() _clock;
  final PlaceDwellTracker _tracker = PlaceDwellTracker();

  /// The mapped places the phone has (set by the ride map).
  List<PlacePoi> Function()? placesSource;

  /// True while an SOS or a crash alarm is open (set in main.dart from SafetyService).
  bool Function()? emergencyOpen;

  /// True while a ride is on (set in main.dart from ConvoyService).
  bool Function()? rideActive;

  StreamSubscription<TrackPoint>? _fixSub;
  PlaceReviewPrompt? _prompt;

  /// 3.55 follow-up: places worth asking about after the ride (not answered in the cockpit).
  final RideEndReviews _rideEnd = RideEndReviews();
  bool _rideWasActive = false;
  double _lastSpeed = double.nan;
  bool _disposed = false;

  // ------------------------------------------------------------------ dwell and prompt

  /// Listens to my fixes (replaces an earlier stream).
  void attachFixes(Stream<TrackPoint> fixes) {
    _fixSub?.cancel();
    _fixSub = fixes.listen(onFix, onError: (_) {});
  }

  /// The polite question to show now ("How was Sri Sai Dhaba?"), or null.
  PlaceReviewPrompt? get prompt {
    final p = _prompt;
    if (p == null || (emergencyOpen?.call() ?? false)) return null;
    return p;
  }

  /// "Not now" (or the question was answered): gone, not asked again for this place today, and
  /// not asked again after the ride.
  void dismissPrompt() {
    final p = _prompt;
    if (p == null) return;
    _rideEnd.answered(p.placeId);
    _prompt = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ after the ride

  /// The review question for the ride summary / end screen: places where I stayed long enough
  /// during the ride and did not answer the cockpit question, longest stay first, at most 2.
  /// Empty when [enabled] is false (admin switches `placeReviews` and `reviewPrompt`, checked by
  /// the caller) or while an SOS / crash alarm is open.
  List<PlaceReviewPrompt> afterRidePrompts({required bool enabled}) {
    if (!enabled || (emergencyOpen?.call() ?? false)) return const [];
    // A dwell that qualified but never had a stopped moment is still in the tracker.
    final r = _tracker.pending;
    if (r != null) _rideEnd.note(r);
    return _rideEnd.pick(nowMs: _clock());
  }

  /// One after-ride place was rated (or its question closed): not asked again.
  void answerAfterRide(String placeId) {
    _rideEnd.answered(placeId);
    _tracker.markAsked(placeId, _clock());
    unawaited(_saveAsked());
    notifyListeners();
  }

  /// "Skip" on the after-ride question: nothing more about this ride.
  void skipAfterRide() {
    _rideEnd.skipAll();
    notifyListeners();
  }

  void onFix(TrackPoint f) {
    if (_disposed) return;
    final now = f.ts > 0 ? f.ts : _clock();
    _lastSpeed = f.speedKmh;
    // A new ride: the after-ride list starts empty.
    final active = rideActive?.call() ?? true;
    if (active && !_rideWasActive) _rideEnd.reset();
    _rideWasActive = active;
    // Riding along: no place can hold me; skip the scan (the tracker still sees the fix).
    final nearby = f.speedKmh > 25 ? const <PlacePoi>[] : _nearby(f.lat, f.lng);
    _tracker.onFix(lat: f.lat, lng: f.lng, tMs: now, nearby: nearby);
    final pending = _tracker.pending;
    if (pending != null && active) _rideEnd.note(pending);
    _evaluate(now);
  }

  /// The ride ended: a cockpit question still open closes unanswered (the ride summary asks
  /// instead, [afterRidePrompts]).
  void onRideEnded() {
    final r = _tracker.pending;
    if (r != null) _rideEnd.note(r);
    if (_prompt == null) return;
    _prompt = null;
    notifyListeners();
  }

  void _evaluate(int now, {bool rideEnded = false}) {
    final shown = _prompt;
    if (shown != null) {
      // Never while riding: riding off without answering closes it (it counted as asked).
      if (_lastSpeed.isFinite && _lastSpeed >= PlaceDwellTracker.stoppedKmh * 3 && !rideEnded) {
        _prompt = null;
        notifyListeners();
      }
      return;
    }
    final ended = rideEnded || !(rideActive?.call() ?? true);
    final due = _tracker.due(speedKmh: _lastSpeed, rideEnded: ended, emergencyOpen: emergencyOpen?.call() ?? false, nowMs: now);
    if (due == null) return;
    _tracker.markAsked(due.placeId, now);
    _prompt = due;
    unawaited(_saveAsked());
    notifyListeners();
  }

  List<PlacePoi> _nearby(double lat, double lng) {
    final src = placesSource;
    if (src == null) return const [];
    List<PlacePoi> all;
    try {
      all = src();
    } catch (_) {
      return const [];
    }
    const dLat = nearbyM / 111320;
    final dLng = nearbyM / (111320 * math.max(0.2, math.cos(lat * math.pi / 180)));
    return [
      for (final p in all)
        if ((p.lat - lat).abs() <= dLat && (p.lng - lng).abs() <= dLng) p,
    ];
  }

  Future<void> _loadAsked() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(prefsKey);
      if (raw == null) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      final now = _clock();
      m.forEach((k, v) {
        if (k is String && v is num && now - v < PlaceDwellTracker.askAgainAfter.inMilliseconds) _tracker.markAsked(k, v.toInt());
      });
    } catch (_) {}
  }

  Future<void> _saveAsked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final m = _tracker.asked;
      // Only place ids and times, kept 24 h; at most 200.
      final entries = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      await prefs.setString(prefsKey, jsonEncode({for (final e in entries.take(200)) e.key: e.value}));
    } catch (_) {}
  }

  // ------------------------------------------------------------------ reviews

  final Map<String, (int, PlaceReviewsPage)> _pages = {};
  final Map<String, PlaceRatingSummary> _summaries = {};

  /// The CoRoute rider rating of a place on the map, if any.
  PlaceRatingSummary? summaryFor(String placeId) => _summaries[placeId];

  /// Gateway photo paths are absolute (`/api/places/...`); [AppConfig.apiUrl] already ends in /api.
  static String relativePath(String p) => p.startsWith('/api/') ? p.substring(4) : p;

  /// Full URL of an approved photo, to load with [photoHeaders].
  String photoUrl(String path) => _api.apiUrlOf(relativePath(path));
  Map<String, String> get photoHeaders => _api.authHeaders;

  /// The reviews of one place (cached for [reviewsTtl] unless [force]).
  Future<PlaceReviewsPage> reviewsFor(String placeId, {bool force = false}) async {
    final hit = _pages[placeId];
    final now = _clock();
    if (!force && hit != null && now - hit.$1 < reviewsTtl.inMilliseconds) return hit.$2;
    final res = await _api.get('/places/reviews?placeId=${Uri.encodeQueryComponent(placeId)}');
    final page = PlaceReviewsPage.fromJson(res);
    _pages[placeId] = (now, page);
    if (_pages.length > 100) _pages.remove(_pages.keys.first);
    final s = page.summary;
    final before = _summaries[placeId];
    if (s != null) {
      _summaries[placeId] = s;
    } else {
      _summaries.remove(placeId);
    }
    if (before?.avg != s?.avg || before?.count != s?.count) notifyListeners();
    return page;
  }

  /// Sends (or replaces: one per rider and place) my review. Throws [ApiException].
  Future<PlaceReviewItem?> submit({
    required PlacePoi place,
    required int rating,
    String text = '',
    int dwellMin = 0,
  }) async {
    final res = await _api.post('/places/reviews', {
      'placeId': place.id,
      'placeName': place.displayName,
      'category': place.category.name,
      'lat': place.lat,
      'lng': place.lng,
      'rating': rating.clamp(1, 5),
      'text': text.trim().length > maxTextChars ? text.trim().substring(0, maxTextChars) : text.trim(),
      'dwellMin': dwellMin,
    });
    _pages.remove(place.id);
    if (_prompt?.placeId == place.id) _prompt = null;
    final item = res is Map ? PlaceReviewItem.fromJson(res['review']) : null;
    // Refresh the place's rating for the map (silently).
    unawaited(reviewsFor(place.id, force: true).then((_) {}, onError: (_) {}));
    notifyListeners();
    return item;
  }

  /// Adds one photo (JPEG, PNG or WebP bytes, already downscaled) to my review. It is shown to
  /// other riders after a quick check. Throws [ApiException].
  Future<void> uploadPhoto(String reviewId, Uint8List bytes, String mime) async {
    await _api.postBytes('/places/reviews/${Uri.encodeComponent(reviewId)}/photo', bytes, mime);
  }

  // ------------------------------------------------------------------ map ratings

  ({double s, double w, double n, double e})? _fetchedBox;
  int _fetchedAt = 0;
  int _nextFetchAt = 0;
  bool _fetching = false;

  /// The map moved: fetches the ratings of the places around the box on screen when it is not
  /// covered by the last fetch (at most every [summaryMinGap], refreshed after [summaryTtl]).
  void onViewport({required double s, required double w, required double n, required double e, required double zoom}) {
    if (zoom < 12 || _fetching || _disposed) return;
    if (![s, w, n, e].every((x) => x.isFinite) || n <= s || e <= w) return;
    final now = _clock();
    if (now < _nextFetchAt) return;
    final b = _fetchedBox;
    final covered = b != null && s >= b.s && n <= b.n && w >= b.w && e <= b.e && now - _fetchedAt < summaryTtl.inMilliseconds;
    if (covered) return;
    // A bit more than the screen, at most 1.4 degrees (the gateway takes up to 1.5).
    final padLat = ((n - s) * 0.3).clamp(0.005, 0.2), padLng = ((e - w) * 0.3).clamp(0.005, 0.2);
    var bs = s - padLat, bn = n + padLat, bw = w - padLng, be = e + padLng;
    if (bn - bs > 1.4) {
      final c = (bn + bs) / 2;
      bs = c - 0.7;
      bn = c + 0.7;
    }
    if (be - bw > 1.4) {
      final c = (be + bw) / 2;
      bw = c - 0.7;
      be = c + 0.7;
    }
    _nextFetchAt = now + summaryMinGap.inMilliseconds;
    unawaited(_fetchSummaries((s: bs, w: bw, n: bn, e: be), now));
  }

  Future<void> _fetchSummaries(({double s, double w, double n, double e}) box, int now) async {
    _fetching = true;
    try {
      String f(double x) => x.toStringAsFixed(4);
      final res = await _api.get('/places/review-summary?s=${f(box.s)}&w=${f(box.w)}&n=${f(box.n)}&e=${f(box.e)}');
      if (_disposed) return;
      var changed = false;
      if (res is Map && res['places'] is List) {
        for (final p in res['places'] as List) {
          if (p is! Map) continue;
          final id = p['placeId']?.toString();
          final s = PlaceRatingSummary.fromJson(p);
          if (id == null || s == null) continue;
          final before = _summaries[id];
          if (before?.avg != s.avg || before?.count != s.count) changed = true;
          _summaries[id] = s;
        }
      }
      while (_summaries.length > 3000) {
        _summaries.remove(_summaries.keys.first);
      }
      _fetchedBox = box;
      _fetchedAt = now;
      if (changed) notifyListeners();
    } catch (_) {
      // Offline or an older gateway: try again later, quietly.
      _nextFetchAt = _clock() + errorBackoff.inMilliseconds;
    } finally {
      _fetching = false;
    }
  }

  @visibleForTesting
  PlaceDwellTracker get tracker => _tracker;

  @override
  void dispose() {
    _disposed = true;
    _fixSub?.cancel();
    super.dispose();
  }
}
