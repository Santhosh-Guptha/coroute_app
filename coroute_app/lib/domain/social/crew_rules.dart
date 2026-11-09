/// 3.55 Crews and crew polls: pure rules shared by the screens and the tests
/// (docs/features_355/crews_polls.md). They mirror gateway/src/crews.js; the gateway stays the
/// judge, these only give the rider an answer before sending.
library;

/// Limits (same numbers as the gateway's crews.LIMITS).
class CrewLimits {
  CrewLimits._();
  static const int nameMin = 3;
  static const int nameMax = 40;
  static const int descriptionMax = 200;
  static const int maxMembers = 100;
  static const int maxCoAdmins = 3;
  static const int maxOwned = 10;
  static const Duration inviteTtl = Duration(days: 14);
  static const int questionMax = 120;
  static const int optionsMin = 2;
  static const int optionsMax = 6;
  static const int optionMax = 60;
  static const Duration pollDefault = Duration(days: 3);
  static const Duration pollMin = Duration(minutes: 10);
  static const Duration pollMax = Duration(days: 30);
}

/// Crew roles as the gateway sends them.
class CrewRoles {
  CrewRoles._();
  static const String admin = 'ADMIN';
  static const String coAdmin = 'CO_ADMIN';
  static const String member = 'MEMBER';

  static String label(String role) => switch (role) {
        admin => 'Crew admin',
        coAdmin => 'Co-admin',
        _ => 'Member',
      };
}

class CrewRules {
  CrewRules._();

  static final RegExp _control = RegExp(r'[\x00-\x1F\x7F]');
  static final RegExp _space = RegExp(r'\s+');
  static final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final RegExp _email = RegExp(r'[^\s@]+@[^\s@]+\.[a-z]{2,}', caseSensitive: false);
  static final RegExp _link = RegExp(r'(https?://|www\.)', caseSensitive: false);
  static final RegExp _phone = RegExp(r'\d{7,}');
  static final RegExp _phoneSeparators = RegExp(r'[\s().-]');

  /// Trim, drop control characters and angle brackets, collapse whitespace (as the gateway does).
  static String clean(String raw) => raw.replaceAll(_control, ' ').replaceAll(RegExp('[<>]'), '').replaceAll(_space, ' ').trim();

  static int _len(String s) => s.runes.length;

  /// Phone numbers, e-mail addresses and links are not allowed in crew text.
  static bool looksLikeContact(String s) =>
      _phone.hasMatch(s.replaceAll(_phoneSeparators, '')) || _email.hasMatch(s) || _link.hasMatch(s);

  /// null when the name is fine, else the message to show.
  static String? checkName(String raw) {
    final v = clean(raw);
    final n = _len(v);
    if (n < CrewLimits.nameMin || n > CrewLimits.nameMax || !_letterOrDigit.hasMatch(v)) {
      return 'A crew name has ${CrewLimits.nameMin} to ${CrewLimits.nameMax} characters.';
    }
    if (looksLikeContact(v)) return 'Crew names cannot have phone numbers, e-mail addresses or links.';
    return null;
  }

  static String? checkDescription(String raw) {
    final v = clean(raw);
    if (_len(v) > CrewLimits.descriptionMax) return 'The description has up to ${CrewLimits.descriptionMax} characters.';
    if (v.isNotEmpty && looksLikeContact(v)) return 'The description cannot have phone numbers, e-mail addresses or links.';
    return null;
  }

  /// null when the poll can be sent, else the message to show. [closesAt] null = the default (3 days).
  static String? checkPoll({required String question, required List<String> options, DateTime? closesAt, DateTime? now}) {
    final q = clean(question);
    if (q.isEmpty || _len(q) > CrewLimits.questionMax) return 'Ask a question of up to ${CrewLimits.questionMax} characters.';
    if (options.length < CrewLimits.optionsMin || options.length > CrewLimits.optionsMax) {
      return 'A poll has ${CrewLimits.optionsMin} to ${CrewLimits.optionsMax} options.';
    }
    final seen = <String>{};
    for (final raw in options) {
      final o = clean(raw);
      if (o.isEmpty || _len(o) > CrewLimits.optionMax) return 'Each option has 1 to ${CrewLimits.optionMax} characters.';
      if (!seen.add(o.toLowerCase())) return 'Two options are the same.';
    }
    if ([q, ...options.map(clean)].any(looksLikeContact)) return 'Polls cannot have phone numbers, e-mail addresses or links.';
    if (closesAt != null) {
      final t = now ?? DateTime.now();
      if (closesAt.isBefore(t.add(CrewLimits.pollMin)) || closesAt.isAfter(t.add(CrewLimits.pollMax))) {
        return 'The poll can close between 10 minutes and 30 days from now.';
      }
    }
    return null;
  }

  /// "Ride date/place" template: a question and the next weekend days as options (no extra logic).
  static ({String question, List<String> options}) rideDateTemplate(DateTime now) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final out = <String>[];
    var d = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    while (out.length < 4) {
      if (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
        out.add('${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}');
      }
      d = d.add(const Duration(days: 1));
    }
    return (question: 'When shall we ride?', options: out);
  }

  /// "Closes in 2 days", "Closes in 5 h", "Closes in 12 min", "Closed".
  static String closesLabel(DateTime closesAt, {DateTime? now, bool closed = false}) {
    final left = closesAt.difference(now ?? DateTime.now());
    if (closed || left.inSeconds <= 0) return 'Closed';
    if (left.inDays >= 1) return 'Closes in ${left.inDays} ${left.inDays == 1 ? 'day' : 'days'}';
    if (left.inHours >= 1) return 'Closes in ${left.inHours} h';
    return 'Closes in ${left.inMinutes < 1 ? 1 : left.inMinutes} min';
  }
}

/// Poll results from the votes: counts per option, voters, percent of voters (whole numbers; with
/// multiple choice they can add up to more than 100) and the leading option(s).
class PollTally {
  final int totalVoters;
  final Map<String, int> counts;
  final Map<String, int> percents;
  final List<String> leaders;
  const PollTally({required this.totalVoters, required this.counts, required this.percents, required this.leaders});

  factory PollTally.of(List<String> optionIds, Iterable<List<String>> votes) {
    final counts = {for (final id in optionIds) id: 0};
    var voters = 0;
    for (final v in votes) {
      final ids = v.where(counts.containsKey).toSet();
      if (ids.isEmpty) continue;
      voters++;
      for (final id in ids) {
        counts[id] = counts[id]! + 1;
      }
    }
    final percents = {for (final id in optionIds) id: voters == 0 ? 0 : (counts[id]! * 100 / voters).round()};
    final max = counts.values.fold<int>(0, (a, b) => b > a ? b : a);
    return PollTally(
      totalVoters: voters,
      counts: counts,
      percents: percents,
      leaders: max == 0 ? const [] : [for (final id in optionIds) if (counts[id] == max) id],
    );
  }

  /// Bar fill 0..1 for an option (share of voters).
  double fill(String id) => totalVoters == 0 ? 0 : (counts[id] ?? 0) / totalVoters;
}

/// A vote the rider is about to send: single choice = exactly one option, multiple = 1..n distinct.
String? checkVote({required bool multi, required List<String> optionIds, required List<String> picked}) {
  if (picked.isEmpty) return 'Pick an option.';
  if (picked.toSet().length != picked.length) return 'Pick each option once.';
  if (picked.any((p) => !optionIds.contains(p))) return 'That option is not in this poll.';
  if (!multi && picked.length != 1) return 'This poll takes one answer.';
  return null;
}
