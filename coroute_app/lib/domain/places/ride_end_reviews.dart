// 3.55 follow-up (owner approved): the place review question after the ride ends.
//
// During the ride the cockpit asks "How was Sri Sai Dhaba?" only when stopped. When the rider rode
// off without answering (or the question never got a stopped moment), the ride summary / end
// screen asks again: at most [maxPlaces] places, skippable, once.
//
// Pure Dart: no Flutter, no I/O. PlaceReviewService feeds it the dwells that qualified
// (PlaceDwellTracker) and the answers given in the cockpit.
import 'place_dwell.dart';

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

  /// "Skip" on the after-ride question: nothing more about this ride.
  void skipAll() => _waiting.clear();

  /// A new ride starts.
  void reset() {
    _waiting.clear();
    _answered.clear();
  }
}
