// Riding roles (3.55): LEAD at the front, PACK in the middle, SWEEPER at the back.
//
// The gateway holds the roles (ROLE_SET, ROLE_SWAP, ROLE_AUTO) and sends ROLE_CHANGE with every
// change, so the riders concerned can be told to change position. Pure: no Flutter, no I/O.

/// The three riding roles as the wire spells them.
class RideRole {
  RideRole._();
  static const String lead = 'LEAD', middle = 'PACK', sweeper = 'SWEEPER';
  static const List<String> all = [lead, middle, sweeper];

  /// "Lead", "Middle" or "Sweeper" (anything else reads as "Middle").
  static String label(String role) => switch (role.toUpperCase()) {
        lead => 'Lead',
        sweeper => 'Sweeper',
        _ => 'Middle',
      };

  /// Where the role rides: "front", "middle" or "back".
  static String place(String role) => switch (role.toUpperCase()) {
        lead => 'front',
        sweeper => 'back',
        _ => 'middle',
      };
}

/// One rider's role change from a ROLE_CHANGE message.
class RoleChange {
  final String userId;
  final String name;
  final String from;
  final String to;
  const RoleChange({required this.userId, required this.name, required this.from, required this.to});

  static List<RoleChange> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw.whereType<Map>())
        if ((e['userId']?.toString() ?? '').isNotEmpty)
          RoleChange(
            userId: e['userId'].toString(),
            name: e['name']?.toString() ?? '',
            from: (e['from']?.toString() ?? RideRole.middle).toUpperCase(),
            to: (e['to']?.toString() ?? RideRole.middle).toUpperCase(),
          ),
    ];
  }
}

/// What a rider is told about a role change: a short card and the spoken line.
class RoleNotice {
  final String title;
  final String message;
  final String speech;

  /// True when the change concerns me (I must change position).
  final bool mine;
  const RoleNotice({required this.title, required this.message, required this.speech, required this.mine});

  /// The notice for [myUserId] from [changes]: my own change first (move to the front / middle /
  /// back), else the new lead or sweeper in one line. Null when nothing worth telling.
  /// [auto]: the change came from automatic roles (the order on the road).
  static RoleNotice? forMe(List<RoleChange> changes, {required String? myUserId, bool auto = false, String byName = ''}) {
    if (changes.isEmpty) return null;
    RoleChange? mine;
    for (final c in changes) {
      if (c.userId == myUserId) mine = c;
    }
    if (mine != null && mine.from != mine.to) {
      final why = auto ? ' (automatic roles)' : (byName.trim().isNotEmpty ? ' (set by ${byName.trim()})' : '');
      switch (mine.to) {
        case RideRole.lead:
          return RoleNotice(
            mine: true,
            title: 'You are now the lead$why',
            message: auto ? 'You are at the front of the group. Set a steady pace and watch the road for everyone.' : 'Move to the front of the group when it is safe. Keep a steady pace.',
            speech: auto ? 'You are at the front, so you are now leading the group. Keep a steady pace.' : 'You are now the lead. When it is safe, move to the front of the group.',
          );
        case RideRole.sweeper:
          return RoleNotice(
            mine: true,
            title: 'You are now the sweeper$why',
            message: auto ? 'You are the last rider. Keep everyone ahead of you and stop for anyone who stops.' : 'Drop back to the end of the group when it is safe. Nobody rides behind you.',
            speech: auto ? 'You are the last rider, so you are now the sweeper. Keep everyone ahead of you.' : 'You are now the sweeper. When it is safe, drop back to the end of the group.',
          );
        default:
          return RoleNotice(
            mine: true,
            title: 'You now ride in the middle$why',
            message: 'Ride between the lead and the sweeper. Keep the rider ahead in sight.',
            speech: 'You now ride in the middle of the group, between the lead and the sweeper.',
          );
      }
    }
    // Someone else: say who leads and who sweeps now.
    String? newLead, newSweeper;
    for (final c in changes) {
      if (c.to == RideRole.lead && c.from != RideRole.lead) newLead = c.name.isEmpty ? 'A rider' : c.name;
      if (c.to == RideRole.sweeper && c.from != RideRole.sweeper) newSweeper = c.name.isEmpty ? 'A rider' : c.name;
    }
    if (newLead == null && newSweeper == null) return null;
    final parts = [
      if (newLead != null) '$newLead now leads',
      if (newSweeper != null) '$newSweeper now sweeps',
    ];
    final line = '${parts.join(' and ')}.';
    return RoleNotice(mine: false, title: line, message: auto ? 'Automatic roles follow the order on the road.' : '', speech: line);
  }
}
