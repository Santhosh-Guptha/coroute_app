// 3.55 friends: the gateway's friend JSON as the app reads it
// (docs/features_355/usernames_friends_profiles.md).
//
// Pure Dart (no Flutter, no I/O), so the parsing is tested against JSON captured from the real
// gateway (test/friends_parse_355_test.dart, fixture test/fixtures/friends_355_gateway.json; the
// gateway test gateway/test/friends_app_contract_355.test.js checks the same fixture against the
// live answers, so the two sides cannot drift apart).
//
// Shapes (gateway/src/social_routes.js):
//   GET /friends               {friends:[{username, displayName, avatarUrl, since, trips, totalKm}],
//                               incoming:[{requestId, username, avatarUrl, at}], outgoing:[same],
//                               blocked:[{username, at}], inviteCode, inviteLink, shareText}
//   POST /friends/requests     202 {status:'REQUESTED', request:{requestId, username, avatarUrl, at}}
//                              200 {status:'FRIENDS' | 'ALREADY_FRIENDS', friend:{username, avatarUrl}}
//   socket FRIEND_REQUEST      {type, requestId, username, via, eventId}
//   socket FRIEND_ACCEPTED     {type, username, requestId?, eventId}

/// A profile picture path the gateway serves (anything else is ignored).
String? avatarPathOf(Object? v) {
  final s = v?.toString() ?? '';
  return s.startsWith('/api/avatars/') ? s : null;
}

/// v3.58: `/api/covers/<id>` from the gateway, else null (never a third-party URL).
String? coverPathOf(Object? v) {
  final s = v?.toString() ?? '';
  return s.startsWith('/api/covers/') ? s : null;
}

int _int(Object? v) => v is num ? v.toInt() : 0;
double _double(Object? v) => v is num ? v.toDouble() : 0;
String _str(Object? v) => v?.toString() ?? '';

/// One friend in the list (username, first name, picture, totals).
class FriendEntry {
  final String username;
  final String displayName;
  final String? avatarUrl;
  final int since;
  final int trips;
  final double totalKm;
  const FriendEntry({required this.username, this.displayName = '', this.avatarUrl, this.since = 0, this.trips = 0, this.totalKm = 0});
  factory FriendEntry.fromJson(Map raw) => FriendEntry(
        username: _str(raw['username']),
        displayName: _str(raw['displayName']),
        avatarUrl: avatarPathOf(raw['avatarUrl']),
        since: _int(raw['since']),
        trips: _int(raw['trips']),
        totalKm: _double(raw['totalKm']),
      );
}

/// A waiting request (incoming: someone asked me; outgoing: I asked them).
class FriendRequestEntry {
  final String requestId;
  final String username;
  final String? avatarUrl;
  final int at;
  const FriendRequestEntry({required this.requestId, required this.username, this.avatarUrl, this.at = 0});
  factory FriendRequestEntry.fromJson(Map raw) => FriendRequestEntry(
        requestId: _str(raw['requestId']),
        username: _str(raw['username']),
        avatarUrl: avatarPathOf(raw['avatarUrl']),
        at: _int(raw['at']),
      );

  /// A row the app can act on (accept / decline / cancel need the id).
  bool get valid => requestId.isNotEmpty && username.isNotEmpty;
}

/// GET /friends.
class FriendsSnapshot {
  final List<FriendEntry> friends;
  final List<FriendRequestEntry> incoming;
  final List<FriendRequestEntry> outgoing;
  final List<String> blocked;
  final String? inviteCode;
  final String? inviteLink;
  final String? shareText;
  const FriendsSnapshot({
    this.friends = const [],
    this.incoming = const [],
    this.outgoing = const [],
    this.blocked = const [],
    this.inviteCode,
    this.inviteLink,
    this.shareText,
  });

  static List<T> _list<T>(Object? raw, T Function(Map) f) => raw is List ? raw.whereType<Map>().map(f).toList() : <T>[];

  /// Null when [raw] is not a GET /friends answer at all (keeps what the app has).
  static FriendsSnapshot? parse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['friends'] is! List && raw['incoming'] is! List && raw['outgoing'] is! List) return null;
    String? opt(Object? v) => v == null || v.toString().isEmpty ? null : v.toString();
    return FriendsSnapshot(
      friends: _list(raw['friends'], FriendEntry.fromJson).where((f) => f.username.isNotEmpty).toList(),
      incoming: _list(raw['incoming'], FriendRequestEntry.fromJson).where((r) => r.valid).toList(),
      outgoing: _list(raw['outgoing'], FriendRequestEntry.fromJson).where((r) => r.valid).toList(),
      blocked: _list(raw['blocked'], (m) => _str(m['username'])).where((s) => s.isNotEmpty).toList(),
      inviteCode: opt(raw['inviteCode']),
      inviteLink: opt(raw['inviteLink']),
      shareText: opt(raw['shareText']),
    );
  }
}

/// Outcome of a friend request ("REQUESTED", "FRIENDS", "ALREADY_FRIENDS") or an error message.
class FriendRequestResult {
  final String? status;
  final String? error;

  /// The sender's own view of a REQUESTED request (shown under "Sent" at once).
  final FriendRequestEntry? request;

  /// The new friend's card for FRIENDS / ALREADY_FRIENDS.
  final String? friendUsername;
  const FriendRequestResult({this.status, this.error, this.request, this.friendUsername});
  bool get ok => error == null;

  /// POST /friends/requests answer.
  factory FriendRequestResult.fromJson(Object? raw) {
    if (raw is! Map) return const FriendRequestResult(status: 'REQUESTED');
    final req = raw['request'] is Map ? FriendRequestEntry.fromJson(raw['request'] as Map) : null;
    final friend = raw['friend'] is Map ? _str((raw['friend'] as Map)['username']) : '';
    return FriendRequestResult(
      status: raw['status']?.toString() ?? 'REQUESTED',
      request: req != null && req.valid ? req : null,
      friendUsername: friend.isEmpty ? null : friend,
    );
  }

  /// The snackbar line for the sender.
  String get confirmation => switch (status) {
        'FRIENDS' => friendUsername == null ? 'You are now friends' : 'You and $friendUsername are now friends',
        'ALREADY_FRIENDS' => 'You are already friends',
        _ => request == null
            ? 'Request sent. You will be friends once they accept.'
            : 'Request sent to ${request!.username}. It is under Sent until they answer.',
      };
}

/// A FRIEND_REQUEST / FRIEND_ACCEPTED socket message (or push data), or null for anything else.
class FriendPush {
  final String type;
  final String? requestId;
  final String username;
  final String? eventId;
  const FriendPush({required this.type, this.requestId, required this.username, this.eventId});

  static FriendPush? parse(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type']?.toString();
    if (type != 'FRIEND_REQUEST' && type != 'FRIEND_ACCEPTED') return null;
    final id = _str(raw['requestId']);
    final name = _str(raw['username']);
    return FriendPush(
      type: type!,
      requestId: id.isEmpty ? null : id,
      username: name.isEmpty ? 'A rider' : name,
      eventId: raw['eventId']?.toString(),
    );
  }

  bool get isRequest => type == 'FRIEND_REQUEST';

  /// The one-line notice ("X wants to be friends").
  String get line => isRequest ? '$username wants to be friends' : '$username accepted your friend request';

  /// The incoming row to show at once, before GET /friends answers (null without an id).
  FriendRequestEntry? get asIncoming =>
      isRequest && requestId != null && username != 'A rider' ? FriendRequestEntry(requestId: requestId!, username: username) : null;
}

/// [incoming] with [entry] added at the top unless a row with the same request id is there.
List<FriendRequestEntry> withRequest(List<FriendRequestEntry> list, FriendRequestEntry entry) =>
    list.any((r) => r.requestId == entry.requestId) ? list : [entry, ...list];

/// What the rider typed into "Add a friend" as the gateway expects it: trimmed, without a leading
/// "@" (the app shows names as @username).
String usernameInput(String raw) => raw.trim().replaceFirst(RegExp(r'^@+'), '').trim();
