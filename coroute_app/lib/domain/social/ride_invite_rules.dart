// 3.55 "Start a ride with this crew" (docs/features_355/crews_polls.md, "Crew rides"): the pure
// parts. A ride invite as the gateway shows it (no join code, no coordinates, no userIds), which
// invites to show by themselves when the app opens, the host's status labels and the member picker.

int _i(Object? v) => v is num ? v.toInt() : 0;
String _s(Object? v) => v?.toString() ?? '';
String? _avatar(Object? v) {
  final s = _s(v);
  return s.startsWith('/api/avatars/') ? s : null;
}

/// Invite statuses (gateway `ride_invites.status`).
class RideInviteStatus {
  RideInviteStatus._();
  static const String pending = 'PENDING';
  static const String accepted = 'ACCEPTED';
  static const String declined = 'DECLINED';
  static const String expired = 'EXPIRED';
  static const String cancelled = 'CANCELLED';

  /// The host's word for a status.
  static String label(String status) => switch (status) {
        pending => 'Waiting',
        accepted => 'Joined',
        declined => 'Declined',
        expired => 'Expired',
        cancelled => 'Cancelled',
        _ => 'Waiting',
      };

  /// Per-name results of POST /crews/:id/ride-invites, in plain words.
  static String resultLabel(String result) => switch (result) {
        'INVITED' => 'Invited',
        'ALREADY_INVITED' => 'Already invited',
        'ALREADY_IN_RIDE' => 'Already in the ride',
        'RIDE_FULL' => 'No seat left',
        'NOT_A_MEMBER' => 'Not in this crew',
        _ => 'Not invited',
      };
}

/// A ride invitation addressed to me (GET /me/ride-invites, GET /ride-invites/:id).
class RideInvite {
  final String inviteId;
  final String status;
  final int createdAt;
  final int expiresAt;
  final String hostUsername;
  final String hostFirstName;
  final String? hostAvatarUrl;
  final String crewId;
  final String crewName;
  final String rideName;
  final String startName;
  final String destinationName;
  final int startedAt;
  final String rideStatus;
  final int riders;
  final int capacity;

  const RideInvite({
    required this.inviteId,
    this.status = RideInviteStatus.pending,
    this.createdAt = 0,
    this.expiresAt = 0,
    this.hostUsername = '',
    this.hostFirstName = '',
    this.hostAvatarUrl,
    this.crewId = '',
    this.crewName = '',
    this.rideName = '',
    this.startName = '',
    this.destinationName = '',
    this.startedAt = 0,
    this.rideStatus = '',
    this.riders = 0,
    this.capacity = 0,
  });

  factory RideInvite.fromJson(Map m) {
    final host = m['host'] is Map ? m['host'] as Map : const {};
    final crew = m['crew'] is Map ? m['crew'] as Map : const {};
    final ride = m['ride'] is Map ? m['ride'] as Map : const {};
    return RideInvite(
      inviteId: _s(m['inviteId']),
      status: _s(m['status']).isEmpty ? RideInviteStatus.pending : _s(m['status']),
      createdAt: _i(m['createdAt']),
      expiresAt: _i(m['expiresAt']),
      hostUsername: _s(host['username']),
      hostFirstName: _s(host['displayName']),
      hostAvatarUrl: _avatar(host['avatarUrl']),
      crewId: _s(crew['crewId']),
      crewName: _s(crew['name']),
      rideName: _s(ride['name']),
      startName: _s(ride['startName']),
      destinationName: _s(ride['destinationName']),
      startedAt: _i(ride['startedAt']),
      rideStatus: _s(ride['status']),
      riders: _i(ride['riders']),
      capacity: _i(ride['capacity']),
    );
  }

  bool isOpen(int nowMs) => status == RideInviteStatus.pending && (expiresAt == 0 || expiresAt > nowMs);

  /// "Hari (@SwiftFalcon482)" or the username alone.
  String get hostLine => hostFirstName.isEmpty ? hostUsername : '$hostFirstName (@$hostUsername)';

  /// "Cubbon Park Gate → Nandi Hills", one side alone, or ''.
  String get routeLine {
    if (startName.isNotEmpty && destinationName.isNotEmpty) return '$startName → $destinationName';
    if (destinationName.isNotEmpty) return 'To $destinationName';
    if (startName.isNotEmpty) return 'From $startName';
    return '';
  }

  /// "3 riders" / "3 of 6 riders".
  String get ridersLine {
    final n = riders == 1 ? '1 rider' : '$riders riders';
    return capacity > 1 ? '$riders of $capacity riders' : n;
  }

  /// The banner / notification text (usernames and names only).
  String get noticeLine {
    final who = hostUsername.isEmpty ? 'A rider' : hostUsername;
    final ride = rideName.isEmpty ? 'a ride' : rideName;
    return crewName.isEmpty ? '$who invited you to $ride' : '$who invited you to $ride with $crewName';
  }
}

/// What to show by itself when the app opens or comes back (once per invite).
enum RideInviteAutoShow { none, single, list }

class RideInviteRules {
  RideInviteRules._();

  /// The open invites not shown yet, newest first.
  static List<RideInvite> unseen(List<RideInvite> invites, Set<String> shownIds, int nowMs) {
    final out = invites.where((i) => i.isOpen(nowMs) && !shownIds.contains(i.inviteId)).toList();
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  /// One unseen invite: its screen; several: the list; none: nothing.
  static RideInviteAutoShow autoShow(List<RideInvite> invites, Set<String> shownIds, int nowMs) {
    final n = unseen(invites, shownIds, nowMs).length;
    if (n == 0) return RideInviteAutoShow.none;
    return n == 1 ? RideInviteAutoShow.single : RideInviteAutoShow.list;
  }

  /// Crew members the host can pick: everyone but me and riders already in the ride (usernames
  /// compared without case).
  static List<T> pickable<T>(List<T> members, String Function(T) usernameOf, {required String myUsername, Set<String> inRide = const {}}) {
    final me = myUsername.toLowerCase();
    final riding = {for (final u in inRide) u.toLowerCase()};
    return members.where((m) {
      final u = usernameOf(m).toLowerCase();
      return u.isNotEmpty && u != me && !riding.contains(u);
    }).toList();
  }

  /// "Invite 3" / "Pick riders".
  static String sendLabel(int picked) => picked == 0 ? 'Pick riders' : (picked == 1 ? 'Invite 1 rider' : 'Invite $picked riders');

  /// Summary after sending: "2 invited · 1 no seat left".
  static String summary(List<String> results) {
    final counts = <String, int>{};
    for (final r in results) {
      counts[r] = (counts[r] ?? 0) + 1;
    }
    final parts = <String>[];
    final invited = counts.remove('INVITED') ?? 0;
    if (invited > 0) parts.add('$invited invited');
    for (final e in counts.entries) {
      parts.add('${e.value} ${RideInviteStatus.resultLabel(e.key).toLowerCase()}');
    }
    return parts.isEmpty ? 'Nobody invited' : parts.join(' · ');
  }
}
