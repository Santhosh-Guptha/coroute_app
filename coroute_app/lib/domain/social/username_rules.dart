/// 3.55 usernames, friends and profiles: pure rules shared by the profile screens
/// (docs/features_355/usernames_friends_profiles.md). The gateway (gateway/src/usernames.js)
/// is the authority; these checks only give instant feedback while typing.
library;

/// Result of a local username check: [code] is null when the name may be sent to the server.
class UsernameCheck {
  final String? code;
  final String? message;
  const UsernameCheck.ok()
      : code = null,
        message = null;
  const UsernameCheck.bad(this.code, this.message);
  bool get ok => code == null;
}

abstract final class UsernameRules {
  static const int minLength = 3;
  static const int maxLength = 20;
  static const int changeDays = 30;
  static final RegExp pattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]{2,19}$');

  static const List<String> _reserved = [
    'admin', 'administrator', 'coroute', 'support', 'official', 'moderator', 'mod', 'staff', 'system',
    'root', 'help', 'helpdesk', 'security', 'team', 'service', 'null', 'undefined', 'api', 'owner',
    'devmonks', 'police', 'emergency', 'ambulance', 'sos', 'guardian', 'verified', 'billing',
    'anonymous', 'everyone', 'nobody', 'test', 'webmaster', 'info', 'noreply', 'contact',
  ];
  static const List<String> _reservedAnywhere = ['admin', 'coroute', 'support', 'official', 'moderator', 'devmonks', 'staff'];
  static const List<String> _profanity = [
    'fuck', 'fuk', 'shit', 'bitch', 'cunt', 'dick', 'cock', 'pussy', 'whore', 'slut', 'bastard', 'asshole',
    'nigg', 'fag', 'retard', 'rape', 'porn', 'sex', 'nazi', 'hitler', 'penis', 'vagina', 'boob', 'tits',
    'chutiya', 'chutia', 'bhenchod', 'behenchod', 'madarchod', 'bsdk', 'gandu', 'randi', 'harami', 'kutta',
    'lund', 'loda', 'lauda', 'chod', 'jihad', 'terror', 'suicide',
  ];
  static const List<String> _emailish = ['gmail', 'yahoo', 'hotmail', 'outlook', 'icloud', 'protonmail', 'rediff', 'mailcom', 'dotcom'];

  static String _normalise(String s) => s
      .toLowerCase()
      .replaceAll('_', '')
      .replaceAll('0', 'o')
      .replaceAll('1', 'i')
      .replaceAll('3', 'e')
      .replaceAll('4', 'a')
      .replaceAll('5', 's')
      .replaceAll('7', 't')
      .replaceAll('8', 'b')
      .replaceAll('9', 'g');

  /// Same rules and codes as the gateway: USERNAME_FORMAT, USERNAME_RESERVED,
  /// USERNAME_NOT_ALLOWED, USERNAME_CONTACT.
  static UsernameCheck check(String raw) {
    final u = raw.trim();
    if (!pattern.hasMatch(u)) {
      return const UsernameCheck.bad('USERNAME_FORMAT', 'Use 3 to 20 letters, numbers or _, starting with a letter.');
    }
    final k = u.toLowerCase();
    final n = _normalise(u);
    if (_reserved.contains(k) || _reserved.contains(k.replaceAll('_', '')) || _reservedAnywhere.any(n.contains)) {
      return const UsernameCheck.bad('USERNAME_RESERVED', 'That username is reserved. Choose another one.');
    }
    if (_profanity.any((w) => n.contains(w) || k.contains(w))) {
      return const UsernameCheck.bad('USERNAME_NOT_ALLOWED', 'That username is not allowed. Choose another one.');
    }
    final digits = RegExp(r'\d').allMatches(u).length;
    if (RegExp(r'\d{7,}').hasMatch(u.replaceAll('_', '')) || digits > 8 || _emailish.any(k.replaceAll('_', '').contains)) {
      return const UsernameCheck.bad('USERNAME_CONTACT', 'A username cannot look like a phone number or an e-mail address.');
    }
    return const UsernameCheck.ok();
  }

  /// When the rider may pick a new username again (null = now). [changedAtMs] 0 = never changed.
  static DateTime? nextChangeAt(int changedAtMs, {DateTime? now}) {
    if (changedAtMs <= 0) return null;
    final next = DateTime.fromMillisecondsSinceEpoch(changedAtMs).add(const Duration(days: changeDays));
    return next.isAfter(now ?? DateTime.now()) ? next : null;
  }

  /// True when only the capitals differ (always allowed, no cooldown).
  static bool sameIgnoringCase(String a, String b) => a.trim().toLowerCase() == b.trim().toLowerCase();
}

/// Invite codes: 8 of A-Z (no I, O) and 2-9, as the gateway issues them.
abstract final class InviteCodes {
  static final RegExp pattern = RegExp(r'^[A-HJ-NP-Z2-9]{8}$');

  /// Upper-cased with spaces and dashes removed; null when it cannot be a code.
  static String? normalise(String raw) {
    final c = raw.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return pattern.hasMatch(c) ? c : null;
  }

  /// The invite code in a shared link: `https://<site>/join/friend/<CODE>` or `coroute://join/friend/<CODE>`.
  static String? fromUri(Uri uri) {
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (uri.scheme == 'coroute' && uri.host == 'join' && segs.length >= 2 && segs.first == 'friend') {
      return normalise(segs[1]);
    }
    if (segs.length >= 3 && segs[segs.length - 3] == 'join' && segs[segs.length - 2] == 'friend') {
      return normalise(segs.last);
    }
    return null;
  }
}

/// Initials for the default avatar: two letters from a name or a username ("SwiftFalcon482" -> "SF").
String avatarInitials(String text) {
  final t = text.trim();
  if (t.isEmpty) return '?';
  final words = t.split(RegExp(r'[\s_]+')).where((w) => w.isNotEmpty).toList();
  if (words.length >= 2) return (words.first[0] + words.last[0]).toUpperCase();
  final caps = RegExp(r'[A-Z]').allMatches(t).map((m) => m.group(0)!).toList();
  if (caps.length >= 2) return caps.take(2).join();
  return t.substring(0, 1).toUpperCase();
}

/// "1,234 km", "12.5 km" for the profile stats.
String formatKm(num km) {
  if (km >= 1000) {
    final s = km.round().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return '$b km';
  }
  return '${km % 1 == 0 ? km.toInt() : km.toStringAsFixed(1)} km';
}
