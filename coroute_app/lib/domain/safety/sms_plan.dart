import '../../core/constants/safety_constants.dart';
import '../../data/models/emergency_roster.dart';
import '../tracking/geo_math.dart';

/// One person to text. [label]: 'contact', 'lead', 'sweeper' or 'rider'.
/// The phone number is never shown in the app and never logged.
class SmsRecipient {
  final String phone;
  final String label;
  const SmsRecipient({required this.phone, required this.label});

  @override
  String toString() => 'SmsRecipient($label)';
}

/// Who gets the emergency text, in order.
class SmsPlan {
  final List<SmsRecipient> recipients;

  /// People who could have been texted (after removing duplicates and the sender).
  final int eligible;

  /// Left out because of the cap or the text budget.
  final int capped;

  const SmsPlan({required this.recipients, required this.eligible, required this.capped});

  @override
  String toString() => 'SmsPlan(${recipients.length} of $eligible)';
}

/// Picks who gets the emergency text: the rider's emergency contact, the lead,
/// the sweeper, then the nearest riders by last known position. Never the
/// sender, never the same number twice. At most [cap] people, and no more texts
/// than the phone's budget ([partsLeft] text parts, [partsPerMessage] each).
/// Riders who opted out are not in the roster at all (the server leaves them out).
class SmsPlanner {
  SmsPlanner._();

  static SmsPlan plan({
    EmergencyRoster? roster,
    RosterContact? contact,
    required Map<String, (double, double)> lastPositions,
    (double, double)? me,
    int cap = SafetyConstants.smsMaxRecipients,
    int partsLeft = SafetyConstants.smsMaxPartsPer30Min,
    int partsPerMessage = 1,
    String? selfUserId,
    String? selfPhone,
  }) {
    final seen = <String>{};
    final self = selfPhone == null ? '' : phoneKey(selfPhone);
    if (self.isNotEmpty) seen.add(self);
    final ordered = <SmsRecipient>[];

    void add(String phone, String label) {
      final dial = dialable(phone);
      final key = phoneKey(dial);
      if (key.isEmpty || !seen.add(key)) return;
      ordered.add(SmsRecipient(phone: dial, label: label));
    }

    final c = contact ?? roster?.emergencyContact;
    if (c != null) add(c.phone, 'contact');

    final members = [
      for (final m in roster?.members ?? const <RosterMember>[])
        if (m.userId != selfUserId) m,
    ];
    for (final m in members) {
      if (m.role.toUpperCase() == 'LEAD') add(m.phone, 'lead');
    }
    for (final m in members) {
      if (m.role.toUpperCase() == 'SWEEPER') add(m.phone, 'sweeper');
    }
    final others = [
      for (final m in members)
        if (m.role.toUpperCase() != 'LEAD' && m.role.toUpperCase() != 'SWEEPER') m,
    ];
    double distanceOf(RosterMember m) {
      final pos = lastPositions[m.userId];
      final from = me;
      if (pos == null || from == null) return double.infinity;
      return GeoMath.haversine(from.$1, from.$2, pos.$1, pos.$2);
    }

    // Stable sort: riders with an unknown position keep the roster order, after the rest.
    final indexed = [for (var i = 0; i < others.length; i++) (i, others[i], distanceOf(others[i]))];
    indexed.sort((a, b) {
      final byDistance = a.$3.compareTo(b.$3);
      return byDistance != 0 ? byDistance : a.$1.compareTo(b.$1);
    });
    for (final (_, m, _) in indexed) {
      add(m.phone, 'rider');
    }

    final perMessage = partsPerMessage < 1 ? 1 : partsPerMessage;
    final byBudget = partsLeft <= 0 ? 0 : partsLeft ~/ perMessage;
    var limit = cap < 0 ? 0 : cap;
    if (byBudget < limit) limit = byBudget;
    final chosen = ordered.length <= limit ? ordered : ordered.sublist(0, limit);
    return SmsPlan(recipients: List.unmodifiable(chosen), eligible: ordered.length, capped: ordered.length - chosen.length);
  }

  /// The number as it is dialled: digits with an optional leading +.
  static String dialable(String phone) {
    final trimmed = phone.trim();
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '';
    return trimmed.startsWith('+') ? '+$digits' : digits;
  }

  /// Comparison key: the last 10 digits, so "+91 98765 43210" and "098765 43210" match.
  static String phoneKey(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 7) return '';
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }
}

/// The emergency text itself. Short, plain, with a map link; no phone numbers.
class SmsText {
  SmsText._();

  static String sos({
    required String name,
    required bool auto,
    required double lat,
    required double lng,
    required DateTime at,
    String? convoyName,
  }) {
    final who = name.trim().isEmpty ? 'A rider' : name.trim();
    final time = '${_two(at.hour)}:${_two(at.minute)}';
    final link = 'https://maps.google.com/?q=${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
    final ride = (convoyName ?? '').trim();
    final head = auto
        ? 'CoRoute automatic alert: $who may have crashed at $time and did not answer.'
        : 'CoRoute SOS: $who needs help ($time).';
    final tail = ride.isEmpty ? '' : ' Ride: $ride.';
    return '$head Map: $link$tail';
  }

  static String _two(int v) => v < 10 ? '0$v' : '$v';

  // GSM 03.38 basic set, and the extension set (each counts twice).
  static const String _gsm = '@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?'
      '¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
  static const String _gsmExt = '^{}\\[~]|€\f';

  /// Number of SMS parts Android will send for [body] (GSM 7-bit or UCS-2).
  static int parts(String body) {
    if (body.isEmpty) return 1;
    var septets = 0;
    var gsm = true;
    for (final ch in body.split('')) {
      if (_gsm.contains(ch)) {
        septets += 1;
      } else if (_gsmExt.contains(ch)) {
        septets += 2;
      } else {
        gsm = false;
        break;
      }
    }
    if (gsm) return septets <= 160 ? 1 : (septets + 152) ~/ 153;
    final units = body.length; // UTF-16 code units, as Android counts them
    return units <= 70 ? 1 : (units + 66) ~/ 67;
  }
}
