// 3.55 follow-up (owner approved): the place review question after the ride ends.
//
// During the ride the cockpit asks "How was Sri Sai Dhaba?" only when stopped. When the rider rode
// off without answering (or the question never got a stopped moment), the ride summary / end
// screen asks again: at most [maxPlaces] places, skippable, once.
//
// Pure Dart: no Flutter, no I/O. PlaceReviewService feeds it the dwells that qualified
// (PlaceDwellTracker) and the answers given in the cockpit, and stores [PendingPlaceReviews] in
// shared preferences so the list survives an app restart (7 days, at most 2).
import 'dart:convert';

import 'place_dwell.dart';
import 'place_poi.dart';
import 'poi_category.dart';

class RideEndReviews {
  /// At most this many places are asked about after a ride.
  static const int maxPlaces = 2;

  /// Places noted during one ride are kept at most this long (a ride left open for days).
  static const Duration keepFor = Duration(hours: 18);

  final Map<String, PlaceReviewPrompt> _waiting = {};
  final Set<String> _answered = {};

  /// A dwell that qualified during the ride (repeat calls for the same place keep the longest stay).
  void note(PlaceReviewPrompt p) {
    if (_answered.contains(p.placeId)) return;
    final old = _waiting[p.placeId];
    if (old == null || p.dwellMin > old.dwellMin) _waiting[p.placeId] = p;
  }

  /// The rider answered the cockpit question ("Rate", "Not now" or closed it): not asked again.
  void answered(String placeId) {
    _answered.add(placeId);
    _waiting.remove(placeId);
  }

  /// The places to ask about now: unanswered, newest [keepFor], longest stay first, at most
  /// [maxPlaces].
  List<PlaceReviewPrompt> pick({required int nowMs}) {
    _waiting.removeWhere((_, p) => nowMs - p.atMs > keepFor.inMilliseconds);
    final list = _waiting.values.toList()
      ..sort((a, b) {
        final c = b.dwellMin.compareTo(a.dwellMin);
        return c != 0 ? c : a.atMs.compareTo(b.atMs);
      });
    return list.take(maxPlaces).toList();
  }

  bool get isEmpty => _waiting.isEmpty;

  /// [placeId] is waiting for the after-ride question.
  bool has(String placeId) => _waiting.containsKey(placeId);

  /// "Skip" on the after-ride question: nothing more about this ride.
  void skipAll() => _waiting.clear();

  /// A new ride starts.
  void reset() {
    _waiting.clear();
    _answered.clear();
  }
}

/// 3.55 follow-up: one after-ride place question kept on the phone, so the list survives an app
/// restart (the app was closed at the ride end, or the rider did not answer yet). Only the ride
/// id, the place (id, name, category, position) and the stay; dropped after [keepFor].
class PendingPlaceReview {
  const PendingPlaceReview({
    required this.rideId,
    required this.placeId,
    required this.name,
    required this.category,
    required this.lat,
    required this.lng,
    required this.dwellMin,
    required this.atMs,
    required this.expiresAtMs,
  });

  /// Kept at most this long after the stay.
  static const Duration keepFor = Duration(days: 7);

  final String rideId;
  final String placeId;
  final String name;

  /// [PoiCategory.name].
  final String category;
  final double lat, lng;
  final int dwellMin;
  final int atMs;
  final int expiresAtMs;

  factory PendingPlaceReview.fromPrompt(PlaceReviewPrompt p, {required String rideId}) {
    final name = (p.place.tags['name:en'] ?? p.place.tags['name'] ?? p.place.tags['brand'] ?? '').trim();
    return PendingPlaceReview(
      rideId: rideId,
      placeId: p.placeId,
      name: name,
      category: p.place.category.name,
      lat: p.place.lat,
      lng: p.place.lng,
      dwellMin: p.dwellMin,
      atMs: p.atMs,
      expiresAtMs: p.atMs + keepFor.inMilliseconds,
    );
  }

  /// The question again (the place card and the review sheet need a [PlacePoi]).
  PlaceReviewPrompt toPrompt() {
    final cat = PoiCategory.values.where((c) => c.name == category).firstOrNull ?? PoiCategory.values.first;
    return PlaceReviewPrompt(
      place: PlacePoi(id: placeId, lat: lat, lng: lng, category: cat, tags: {if (name.isNotEmpty) 'name': name}),
      dwellMin: dwellMin,
      atMs: atMs,
    );
  }

  bool expired(int nowMs) => nowMs >= expiresAtMs;

  Map<String, Object?> toJson() => {
        'rideId': rideId,
        'placeId': placeId,
        'name': name,
        'category': category,
        'lat': lat,
        'lng': lng,
        'dwellMin': dwellMin,
        'atMs': atMs,
        'expiresAtMs': expiresAtMs,
      };

  static PendingPlaceReview? fromJson(Object? j) {
    if (j is! Map) return null;
    final placeId = j['placeId']?.toString() ?? '';
    final lat = (j['lat'] as num?)?.toDouble(), lng = (j['lng'] as num?)?.toDouble();
    final at = (j['atMs'] as num?)?.toInt() ?? 0;
    if (placeId.isEmpty || lat == null || lng == null || !lat.isFinite || !lng.isFinite || at <= 0) return null;
    return PendingPlaceReview(
      rideId: j['rideId']?.toString() ?? '',
      placeId: placeId,
      name: j['name']?.toString() ?? '',
      category: j['category']?.toString() ?? '',
      lat: lat,
      lng: lng,
      dwellMin: ((j['dwellMin'] as num?)?.toInt() ?? 1).clamp(1, 24 * 60),
      atMs: at,
      expiresAtMs: (j['expiresAtMs'] as num?)?.toInt() ?? at + keepFor.inMilliseconds,
    );
  }
}

/// The stored after-ride questions: at most [RideEndReviews.maxPlaces], newest ride first, longest
/// stay first within a ride, expired ones dropped. Pure (the service reads and writes the JSON).
class PendingPlaceReviews {
  PendingPlaceReviews([Iterable<PendingPlaceReview> items = const []]) : _items = [...items];

  final List<PendingPlaceReview> _items;

  List<PendingPlaceReview> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  /// Adds (or keeps the longer stay of) one place, then trims to [RideEndReviews.maxPlaces].
  /// Returns true when the stored list changed.
  bool add(PendingPlaceReview p, {required int nowMs}) {
    final before = _signature();
    final i = _items.indexWhere((e) => e.placeId == p.placeId);
    if (i < 0) {
      _items.add(p);
    } else if (p.dwellMin > _items[i].dwellMin || (p.rideId.isNotEmpty && _items[i].rideId.isEmpty)) {
      _items[i] = p;
    }
    _trim(nowMs);
    return before != _signature();
  }

  /// Answered or its question closed: gone.
  bool remove(String placeId) {
    final n = _items.length;
    _items.removeWhere((e) => e.placeId == placeId);
    return n != _items.length;
  }

  /// "Skip": everything of [rideId] (all when null) is gone.
  bool skip({String? rideId}) {
    final n = _items.length;
    _items.removeWhere((e) => rideId == null || e.rideId == rideId);
    return n != _items.length;
  }

  /// Not expired, of [rideId] when given.
  List<PendingPlaceReview> live({required int nowMs, String? rideId}) {
    _items.removeWhere((e) => e.expired(nowMs));
    return [for (final e in _items) if (rideId == null || e.rideId == rideId) e];
  }

  void _trim(int nowMs) {
    _items.removeWhere((e) => e.expired(nowMs));
    final rideAt = <String, int>{};
    for (final e in _items) {
      final r = rideAt[e.rideId];
      if (r == null || e.atMs > r) rideAt[e.rideId] = e.atMs;
    }
    _items.sort((a, b) {
      final c = rideAt[b.rideId]!.compareTo(rideAt[a.rideId]!);
      if (c != 0) return c;
      final d = b.dwellMin.compareTo(a.dwellMin);
      return d != 0 ? d : a.atMs.compareTo(b.atMs);
    });
    if (_items.length > RideEndReviews.maxPlaces) _items.removeRange(RideEndReviews.maxPlaces, _items.length);
  }

  String _signature() => _items.map((e) => '${e.rideId}|${e.placeId}|${e.dwellMin}').join(',');

  String encode() => jsonEncode([for (final e in _items) e.toJson()]);

  static PendingPlaceReviews decode(String? raw, {required int nowMs}) {
    if (raw == null || raw.isEmpty) return PendingPlaceReviews();
    try {
      final j = jsonDecode(raw);
      if (j is! List) return PendingPlaceReviews();
      final out = PendingPlaceReviews([for (final e in j) ?PendingPlaceReview.fromJson(e)]);
      out._trim(nowMs);
      return out;
    } catch (_) {
      return PendingPlaceReviews();
    }
  }
}
