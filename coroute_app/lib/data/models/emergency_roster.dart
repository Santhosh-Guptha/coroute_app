import 'dart:convert';

/// One rider who may receive an emergency text (no name: phones are never shown).
class RosterMember {
  final String userId;

  /// LEAD, SWEEPER or PACK.
  final String role;
  final String phone;

  const RosterMember({required this.userId, required this.role, required this.phone});

  static RosterMember? fromJson(Object? j) {
    if (j is! Map) return null;
    final phone = j['phone']?.toString().trim() ?? '';
    final userId = j['userId']?.toString() ?? '';
    if (phone.isEmpty || userId.isEmpty) return null;
    return RosterMember(userId: userId, role: (j['role']?.toString() ?? 'PACK').toUpperCase(), phone: phone);
  }

  Map<String, dynamic> toJson() => {'userId': userId, 'role': role, 'phone': phone};

  @override
  String toString() => 'RosterMember($userId, $role)';
}

/// The rider's own emergency contact.
class RosterContact {
  final String name;
  final String phone;

  const RosterContact({required this.name, required this.phone});

  static RosterContact? fromJson(Object? j) {
    if (j is! Map) return null;
    final phone = j['phone']?.toString().trim() ?? '';
    if (phone.isEmpty) return null;
    return RosterContact(name: j['name']?.toString() ?? '', phone: phone);
  }

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone};

  @override
  String toString() => 'RosterContact(set)';
}

/// Phone numbers for the no-internet SMS fallback of an active ride.
///
/// Kept on the phone only while the ride lasts and only when the rider opted
/// in; never shown, never logged ([toString] prints no phone numbers).
class EmergencyRoster {
  final String groupId;
  final int fetchedAt;
  final int validUntil;

  /// Most texts per SOS (the server's SMS_MAX_RECIPIENTS).
  final int cap;
  final List<RosterMember> members;
  final RosterContact? emergencyContact;

  const EmergencyRoster({
    required this.groupId,
    required this.fetchedAt,
    required this.validUntil,
    this.cap = 10,
    this.members = const [],
    this.emergencyContact,
  });

  bool isValidFor(String groupId, int nowMs) => groupId.isNotEmpty && this.groupId == groupId && validUntil > nowMs;

  /// From the server answer or the stored copy. [fetchedAt] overrides the stored or
  /// server time (the phone's clock is what [isValidFor] compares with).
  static EmergencyRoster? fromJson(Map<String, dynamic> j, {int? fetchedAt}) {
    final gid = j['groupId']?.toString() ?? '';
    if (gid.isEmpty) return null;
    final rawMembers = j['members'];
    final seen = <String>{};
    final members = <RosterMember>[];
    if (rawMembers is List) {
      for (final m in rawMembers) {
        final r = RosterMember.fromJson(m);
        if (r != null && seen.add(r.phone)) members.add(r);
      }
    }
    final at = fetchedAt ?? (j['fetchedAt'] as num?)?.toInt() ?? (j['generatedAt'] as num?)?.toInt() ?? 0;
    var until = (j['validUntil'] as num?)?.toInt() ?? 0;
    // The server's validity is relative to its clock; keep the same length on the phone's clock.
    final gen = (j['generatedAt'] as num?)?.toInt();
    if (fetchedAt != null && gen != null && gen > 0 && until > gen) until = fetchedAt + (until - gen);
    return EmergencyRoster(
      groupId: gid,
      fetchedAt: at,
      validUntil: until,
      cap: (j['cap'] as num?)?.toInt() ?? 10,
      members: members,
      emergencyContact: RosterContact.fromJson(j['emergencyContact']),
    );
  }

  Map<String, dynamic> toJson() => {
        'groupId': groupId,
        'fetchedAt': fetchedAt,
        'validUntil': validUntil,
        'cap': cap,
        'members': [for (final m in members) m.toJson()],
        'emergencyContact': emergencyContact?.toJson(),
      };

  String encode() => jsonEncode(toJson());

  static EmergencyRoster? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      return j is Map ? fromJson(Map<String, dynamic>.from(j)) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'EmergencyRoster($groupId, ${members.length} members, contact: ${emergencyContact != null})';
}
