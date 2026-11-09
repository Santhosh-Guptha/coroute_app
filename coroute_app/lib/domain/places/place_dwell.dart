// CoRoute rider place reviews (3.55): notice when the rider stayed a while at a place (a dhaba, a
// stay, a fuel station...) and offer, politely and once, to rate it for the riders coming after.
//
// Shanmuk's idea: "if users stay a while at restaurants or stays, politely ask them to review so it
// helps the next riders".
//
// Pure Dart: no Flutter, no I/O. The service layer (PlaceReviewService) feeds my fixes and the
// mapped places near me, keeps the "already asked" times in SharedPreferences and decides when the
// prompt may be shown.
//
// Rules:
//  * a dwell is staying within [radiusM] of one place for at least [minDwellFor] its category
//    (food 12 min, stay 30 min, fuel 8 min, others 10 min). A short GPS jump out of the circle
//    (under [outsideGrace]) does not end it;
//  * at most one prompt per place per [askAgainAfter] (24 h), whoever's phone restarted;
//  * the prompt is offered only when the rider is stopped (under [stoppedKmh]) or the ride has
//    ended — never while riding — and never while an SOS or a crash alarm is open;
//  * hospitals and police stations are never asked about on their own (a visit there may be an
//    emergency); a rider can still rate them from the place card;
//  * a dwell that was not offered within [promptValidFor] of leaving the place is dropped (asking
//    about a lunch stop hours later, at another place, would only confuse).
import '../tracking/geo_math.dart';
import 'place_poi.dart';
import 'poi_category.dart';

/// The polite question for one place: "How was Sri Sai Dhaba?".
class PlaceReviewPrompt {
  const PlaceReviewPrompt({required this.place, required this.dwellMin, required this.atMs});

  final PlacePoi place;

  /// Whole minutes spent there (at least 1).
  final int dwellMin;

  /// When the dwell qualified (epoch ms).
  final int atMs;

  String get placeId => place.id;
  String get title => 'How was ${place.displayName}?';
  String get message => 'You spent $dwellMin min there. A quick rating helps the riders coming after you.';
}

class PlaceDwellTracker {
  PlaceDwellTracker({Map<String, int>? asked}) : _asked = {...?asked};

  static const double radiusM = 80;

  /// A dwell survives this long outside the circle (GPS drift indoors, a walk to the bike).
  static const Duration outsideGrace = Duration(minutes: 2);
  static const Duration askAgainAfter = Duration(hours: 24);
  static const Duration promptValidFor = Duration(minutes: 30);
  static const double stoppedKmh = 5;

  /// Places never asked about by themselves (a visit may be an emergency).
  static const Set<PoiCategory> neverAsk = {PoiCategory.hospital, PoiCategory.police};

  /// How long a rider must stay before being asked.
  static Duration minDwellFor(PoiCategory c) => switch (c) {
        PoiCategory.food => const Duration(minutes: 12),
        PoiCategory.stay => const Duration(minutes: 30),
        PoiCategory.fuel || PoiCategory.ev => const Duration(minutes: 8),
        _ => const Duration(minutes: 10),
      };

  final Map<String, int> _asked;
  PlacePoi? _place;
  int _since = 0;
  int _lastInside = 0;
  PlaceReviewPrompt? _ready;

  /// Place id -> when it was asked about (epoch ms), for the service to persist.
  Map<String, int> get asked => Map.unmodifiable(_asked);

  /// The place I am staying at now (null when none).
  PlacePoi? get currentPlace => _place;

  /// The dwell that qualified and was not asked about yet, whether or not it may be shown now
  /// (for the after-ride question, RideEndReviews).
  PlaceReviewPrompt? get pending => _ready;

  /// Minutes at [currentPlace] so far.
  int dwellMinutes(int nowMs) => _place == null ? 0 : ((_lastInside - _since) / 60000).floor();

  bool wasAskedRecently(String placeId, int nowMs) {
    final at = _asked[placeId];
    return at != null && nowMs - at < askAgainAfter.inMilliseconds;
  }

  /// One fix with the mapped places near it (any list; only those within [radiusM] count).
  void onFix({required double lat, required double lng, required int tMs, required List<PlacePoi> nearby}) {
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return;
    final cur = _place;
    // Sticky: while I am still inside the current place's circle it stays the place, even when a
    // neighbouring shop is a few metres nearer.
    if (cur != null && GeoMath.haversine(lat, lng, cur.lat, cur.lng) <= radiusM) {
      _lastInside = tMs;
    } else {
      PlacePoi? best;
      var bestD = radiusM;
      for (final p in nearby) {
        final d = GeoMath.haversine(lat, lng, p.lat, p.lng);
        if (d <= bestD) {
          bestD = d;
          best = p;
        }
      }
      if (best != null && (cur == null || tMs - _lastInside > outsideGrace.inMilliseconds || best.id == cur.id)) {
        if (cur == null || best.id != cur.id) _since = tMs;
        _place = best;
        _lastInside = tMs;
      } else if (cur != null && tMs - _lastInside > outsideGrace.inMilliseconds) {
        _place = null;
      }
    }
    final p = _place;
    final r = _ready;
    if (r != null) {
      if (p != null && p.id == r.placeId) {
        _readyLeftAt = null;
        final mins = ((_lastInside - _since) / 60000).floor().clamp(1, 24 * 60).toInt();
        if (mins != r.dwellMin) _ready = PlaceReviewPrompt(place: r.place, dwellMin: mins, atMs: r.atMs);
      } else {
        // Left the place: the prompt keeps for a while (offered at the next stop), then goes.
        final left = _readyLeftAt ??= tMs;
        if (tMs - left > promptValidFor.inMilliseconds) {
          _ready = null;
          _readyLeftAt = null;
        }
      }
    }
    if (_ready == null && p != null && !neverAsk.contains(p.category) && !wasAskedRecently(p.id, tMs)) {
      final stayed = _lastInside - _since;
      if (stayed >= minDwellFor(p.category).inMilliseconds) {
        _ready = PlaceReviewPrompt(place: p, dwellMin: (stayed / 60000).floor().clamp(1, 24 * 60).toInt(), atMs: tMs);
        _readyLeftAt = null;
      }
    }
  }

  int? _readyLeftAt;

  /// The prompt to show now, or null. It is offered only when stopped (or the ride ended) and no
  /// SOS or crash alarm is open; [markAsked] records it once shown.
  PlaceReviewPrompt? due({required double speedKmh, required bool rideEnded, required bool emergencyOpen, required int nowMs}) {
    final r = _ready;
    if (r == null || emergencyOpen) return null;
    if (wasAskedRecently(r.placeId, nowMs)) {
      _ready = null;
      return null;
    }
    if (_readyLeftAt != null && nowMs - _readyLeftAt! > promptValidFor.inMilliseconds) {
      _ready = null;
      return null;
    }
    if (!rideEnded && !(speedKmh.isFinite && speedKmh < stoppedKmh)) return null;
    return r;
  }

  /// The prompt was shown (answered or not): not again for this place within 24 h.
  void markAsked(String placeId, int nowMs) {
    _asked[placeId] = nowMs;
    if (_ready?.placeId == placeId) _ready = null;
    _asked.removeWhere((_, at) => nowMs - at >= askAgainAfter.inMilliseconds);
  }

  void reset() {
    _place = null;
    _since = 0;
    _lastInside = 0;
    _ready = null;
    _readyLeftAt = null;
  }
}
