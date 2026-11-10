// 3.55 after-ride wrap-up: one calm screen, swiped through at most 3 cards: "How was the ride?"
// first, then the places the rider stopped at long enough (longest stay first). Every card and the
// whole flow are skippable. Pure Dart: no Flutter, no I/O (docs/features_355/ratings_reviews.md).
import 'engagement_config.dart';

enum WrapUpKind { trip, place }

/// A place the rider stopped at (from the after-ride place prompts kept on the phone).
class WrapUpPlace {
  final String placeId;
  final String name;

  /// PoiCategory name ('stay', 'food', 'fuel', ...).
  final String category;
  final int dwellMin;
  final int atMs;
  const WrapUpPlace({required this.placeId, required this.name, required this.category, required this.dwellMin, required this.atMs});
}

class WrapUpItem {
  final WrapUpKind kind;

  /// Trip id (convoy group id or trip record id) or the place id.
  final String id;
  final String title;
  final WrapUpPlace? place;
  const WrapUpItem._(this.kind, this.id, this.title, this.place);

  factory WrapUpItem.trip(String tripId, String tripName) => WrapUpItem._(WrapUpKind.trip, tripId, tripName, null);
  factory WrapUpItem.place(WrapUpPlace p) => WrapUpItem._(WrapUpKind.place, p.placeId, p.name, p);
}

class RideWrapUpFlow {
  RideWrapUpFlow._();

  /// Cards in one wrap-up, at most.
  static const int maxItems = 3;

  /// The cards to show, in order. The trip card only when trip reviews are on, the server says the
  /// rider may review this ride and there is no review yet. Places: distinct, longest stay first
  /// (earlier first on a tie), at most [ReviewRules.maxPlaces] and never more than [maxItems] in all.
  static List<WrapUpItem> build({
    required ReviewRules rules,
    required String tripId,
    required String tripName,
    required bool canReviewTrip,
    required bool tripReviewed,
    required List<WrapUpPlace> places,
  }) {
    final out = <WrapUpItem>[];
    if (rules.tripEnabled && canReviewTrip && !tripReviewed && tripId.isNotEmpty) out.add(WrapUpItem.trip(tripId, tripName));
    if (rules.placesEnabled && rules.maxPlaces > 0) {
      final byId = <String, WrapUpPlace>{};
      for (final p in places) {
        if (p.placeId.isEmpty) continue;
        final old = byId[p.placeId];
        if (old == null || p.dwellMin > old.dwellMin) byId[p.placeId] = p;
      }
      final sorted = byId.values.toList()
        ..sort((a, b) {
          final c = b.dwellMin.compareTo(a.dwellMin);
          return c != 0 ? c : a.atMs.compareTo(b.atMs);
        });
      final room = maxItems - out.length;
      final take = rules.maxPlaces < room ? rules.maxPlaces : room;
      out.addAll(sorted.take(take < 0 ? 0 : take).map(WrapUpItem.place));
    }
    return out;
  }

  /// The chips a rider may pick on [item]: the trip chips, or the chips of the place's category.
  static List<ReviewChip> chipsFor(WrapUpItem item, EngagementConfig config) =>
      item.kind == WrapUpKind.trip ? config.tripChips : config.chipsForPlace(item.place?.category ?? 'other');

  /// Picked chip ids, in the order offered, only ids that were offered.
  static List<String> cleanChips(Iterable<String> picked, List<ReviewChip> offered) {
    final set = picked.toSet();
    return [for (final c in offered) if (set.contains(c.id)) c.id];
  }

  /// The note as sent: trimmed, at most [EngagementConfig.noteMax] characters.
  static String cleanNote(String note) {
    final t = note.trim();
    return t.length > EngagementConfig.noteMax ? t.substring(0, EngagementConfig.noteMax).trimRight() : t;
  }

  /// Body of POST /api/trips/:tripId/feedback for the quick trip review. Private: no publication
  /// consent, no photos (the full review sheet handles stories and photos).
  static Map<String, Object?> tripBody({required int rating, required Iterable<String> chips, required String note, required List<ReviewChip> offered}) => {
        'rating': rating.clamp(1, 5),
        'chips': cleanChips(chips, offered),
        'writtenFeedback': cleanNote(note),
        'consentPublish': false,
        'consentTripDetails': false,
        'consentPhoto': false,
      };

  /// May the trip report offer the quick trip review again? A ride skipped in the wrap-up is
  /// offered on its report for [ReviewRules.reportDays] days after it ended, until reviewed or
  /// closed there.
  static bool offerOnReport({
    required ReviewRules rules,
    required int endedAtMs,
    required int nowMs,
    required bool canReview,
    required bool reviewed,
    required bool dismissedOnReport,
  }) {
    if (!rules.tripEnabled || !canReview || reviewed || dismissedOnReport || endedAtMs <= 0 || rules.reportDays <= 0) return false;
    final age = nowMs - endedAtMs;
    return age >= 0 && age <= Duration(days: rules.reportDays).inMilliseconds;
  }
}
