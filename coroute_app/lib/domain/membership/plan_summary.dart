/// The read-only "Your plan" card, as plain data (pure Dart, no Flutter: unit-testable).
///
/// Play payments policy (docs/features_355/play_payments_policy.md): the app is consumption-only.
/// The card shows neutral account status only: the plan name, what it includes, its status and
/// end date, and one line saying where the plan is managed. It never shows a price, never offers
/// a way to buy, change or extend a plan, and never points to a website.
library;

/// The one line every plan card ends with (no link, no button).
const String planManagedLine = 'Your plan is managed in your CoRoute account.';

/// The line the Community (free) card always shows.
const String communityFreeLine = 'Solo riding and every safety feature are free.';

/// Words a rider-facing plan text must never contain (prices, buying, steering to pay).
/// Used to drop a server-sent feature line that would break the policy, and by the tests.
final RegExp planForbiddenText = RegExp(
  r'(₹|\bINR\b|\brs\.?\s*\d|\bprice|\bpricing|per month|/\s*mo\b|\bupgrade|\bpurchase|\bbuy\b|\bcheckout|\bcoupon|\bdiscount|\brenew|\bpayment|\bpay\b|offer code|website|\bsubscribe)',
  caseSensitive: false,
);

/// Plain values the card is built from (taken from the server's plan; no money fields exist).
class PlanFacts {
  /// 'community', 'membership', 'legacy' or 'none'.
  final String source;

  /// 'community', 'group_small', 'group_large', 'individual' or null.
  final String? category;

  /// The plan's own name (used for a legacy plan).
  final String name;

  /// Riders the rider may host, host included.
  final int seats;

  /// Epoch ms of the end of the plan; 0 = no end (Community).
  final int validUntil;

  /// The rider rides on a friend's group plan (invited onto it), with no plan of their own.
  final bool ridesOnFriendsPlan;

  /// What the server says the plan includes (catalog `features`), shown after the app's own lines.
  final List<String> serverFeatures;

  const PlanFacts({
    required this.source,
    this.category,
    this.name = '',
    this.seats = 1,
    this.validUntil = 0,
    this.ridesOnFriendsPlan = false,
    this.serverFeatures = const [],
  });
}

/// What the card shows, in order.
class PlanSummary {
  /// "Community", "Small Group", "Large Group" or a legacy plan's name.
  final String planName;

  /// "Free", "Active" or "Ended".
  final String status;

  /// "Ends on 12 Dec", "Ended on 3 Nov", or null (Community never ends).
  final String? dateLine;

  /// What the plan includes.
  final List<String> includes;

  /// A plain note (for example the Community free line), or null.
  final String? note;

  /// Always [planManagedLine].
  final String managedLine;

  final bool isCommunity;
  final bool isEnded;

  const PlanSummary({
    required this.planName,
    required this.status,
    required this.dateLine,
    required this.includes,
    required this.note,
    required this.isCommunity,
    required this.isEnded,
    this.managedLine = planManagedLine,
  });

  /// Every text of the card, top to bottom (for tests and the policy scan).
  List<String> get allText => [planName, status, ?dateLine, ...includes, ?note, managedLine];

  static const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "12 Dec" (with the year when it is not [now]'s year).
  static String dateLabel(int epochMs, DateTime now) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final base = '${d.day} ${_months[d.month - 1]}';
    return d.year == now.year ? base : '$base ${d.year}';
  }

  /// The short name of a plan category.
  static String nameOf(PlanFacts f) {
    if (f.source == 'legacy' && f.name.isNotEmpty) return f.name;
    switch (f.category) {
      case 'group_small':
        return 'Small Group';
      case 'group_large':
        return 'Large Group';
      case 'individual':
        return 'Individual';
      case 'community':
        return 'Community';
    }
    return f.name.isNotEmpty ? f.name : 'Community';
  }

  /// Server feature lines that are safe to show (no price or buying words, short, no duplicates).
  static List<String> safeFeatures(List<String> lines, {Iterable<String> already = const []}) {
    final seen = {for (final a in already) a.toLowerCase()};
    final out = <String>[];
    for (final raw in lines) {
      final l = raw.trim();
      if (l.isEmpty || l.length > 120 || planForbiddenText.hasMatch(l)) continue;
      if (seen.add(l.toLowerCase())) out.add(l);
    }
    return out;
  }

  static const List<String> _communityIncludes = [
    'Solo rides with live tracking',
    'SOS, crash alerts and guardians',
    'Join any group ride for free',
  ];

  /// Builds the card from [f] at [now].
  factory PlanSummary.from(PlanFacts f, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final nowMs = at.millisecondsSinceEpoch;
    final hasEnd = f.validUntil > 0;
    final ended = f.source != 'community' && f.source != 'none' && hasEnd && f.validUntil <= nowMs;
    final paidSource = f.source == 'membership' || f.source == 'legacy';
    final onCommunity = !paidSource || f.seats < 1 || ended;

    if (onCommunity) {
      final endedName = ended ? nameOf(f) : null;
      return PlanSummary(
        planName: 'Community',
        status: 'Free',
        dateLine: endedName != null ? 'Your $endedName plan ended on ${dateLabel(f.validUntil, at)}' : null,
        includes: [
          ..._communityIncludes,
          if (f.ridesOnFriendsPlan) "You ride in a friend's group plan",
        ],
        note: communityFreeLine,
        isCommunity: true,
        isEnded: ended,
      );
    }

    final name = nameOf(f);
    final group = f.seats >= 2;
    final own = <String>[
      if (group) 'Host group rides of up to ${f.seats} riders (you included)' else 'Solo rides',
      if (group) 'Talk, messages, invite code and regroup in your rides',
      'Every safety feature',
    ];
    return PlanSummary(
      planName: name,
      status: 'Active',
      dateLine: hasEnd ? 'Ends on ${dateLabel(f.validUntil, at)}' : null,
      includes: [...own, ...safeFeatures(f.serverFeatures, already: own)],
      note: null,
      isCommunity: false,
      isEnded: false,
    );
  }
}
