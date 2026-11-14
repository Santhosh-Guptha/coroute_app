// v3.58 Home: hero carousel cards and the "Upcoming" list. Pure Dart (tool/pure_dart_test).
library;

enum HeroCard { ridesNearYou, groupRide, lastRide, safetyCheck }

class HomeFeed {
  HomeFeed._();

  /// Carousel cards in order. The safety check moves to the front when the phone check is due (first ride,
  /// new phone or changed permissions), because skipping it is what fails riders on the road.
  static List<HeroCard> heroCards({required bool hasLastRide, required bool safetyCheckDue}) => [
        if (safetyCheckDue) HeroCard.safetyCheck,
        HeroCard.ridesNearYou,
        HeroCard.groupRide,
        if (hasLastRide) HeroCard.lastRide,
        if (!safetyCheckDue) HeroCard.safetyCheck,
      ];
}

class CarouselPolicy {
  CarouselPolicy._();

  static const Duration interval = Duration(seconds: 6);

  /// Auto-scroll only with full motion, more than one card, and when the rider is not touching it.
  static bool autoAdvance({required bool reducedMotion, required int cards, required bool userHolding}) =>
      !reducedMotion && cards > 1 && !userHolding;

  static int next(int index, int cards) => cards <= 0 ? 0 : (index + 1) % cards;
}

enum UpcomingKind { rideInvite, clubRide, crewPoll }

class UpcomingItem {
  final UpcomingKind kind;
  final String id;
  final String title;
  final String subtitle;

  /// Epoch ms the item is about (ride start, invite expiry, poll close); 0 = unknown (sorted last).
  final int atMs;
  const UpcomingItem({required this.kind, required this.id, required this.title, this.subtitle = '', this.atMs = 0});
}

class UpcomingFeed {
  UpcomingFeed._();

  static const int max = 5;

  /// Ride invites first (they expire), then everything by time; past items (more than 6 h ago) are dropped.
  static List<UpcomingItem> merge(List<UpcomingItem> items, {required int nowMs}) {
    final keep = items.where((i) => i.atMs == 0 || i.atMs > nowMs - 6 * 3600000).toList();
    int weight(UpcomingItem i) => i.kind == UpcomingKind.rideInvite ? 0 : 1;
    keep.sort((a, b) {
      final w = weight(a).compareTo(weight(b));
      if (w != 0) return w;
      if (a.atMs == 0 && b.atMs == 0) return 0;
      if (a.atMs == 0) return 1;
      if (b.atMs == 0) return -1;
      return a.atMs.compareTo(b.atMs);
    });
    return keep.take(max).toList();
  }

  /// "Today 06:30", "Tomorrow 05:45", "Sat 14 Nov", for a local time.
  static String whenLabel(int atMs, {required DateTime now}) {
    if (atMs <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(atMs);
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (diff == 0) return 'Today $hm';
    if (diff == 1) return 'Tomorrow $hm';
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${wd[t.weekday - 1]} ${t.day} ${mo[t.month - 1]}';
  }
}
