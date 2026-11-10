// 3.55 People hub (docs/features_355/usernames_friends_profiles.md, "People hub"): the pure parts.
//
// Pure Dart (dart:async only, no Flutter, no I/O), tested in test/people_hub_355_test.dart:
//   - the search box: username prefix key, debounce (300 ms, 2+ characters), stale answers dropped
//   - the relationship chip on every person row (Friend / Requested / Accept / Add) and its one-tap
//     action, kept live from the friends lists the socket refreshes
//   - one Requests list for friend requests, crew invites and ride invites (incoming first, then sent)
//   - the badge numbers shared by the bottom bar, the hub segments and the profile
//
// Gateway shapes (gateway/src/social_routes.js):
//   GET /users/search?q=      {results:[{username, avatarUrl, relation}]}   (max 10)
//   GET /friends/suggestions  {suggestions:[{username, avatarUrl, relation, rides}]}

import 'dart:async';

import 'friends_models.dart';
import 'ride_invite_rules.dart';

/// Relationship values the gateway sends (GET /users/search, /users/:u/profile).
class PeopleRelation {
  PeopleRelation._();
  static const String none = 'NONE';
  static const String friends = 'FRIENDS';
  static const String pendingOut = 'PENDING_OUT';
  static const String pendingIn = 'PENDING_IN';
  static const String self = 'SELF';
  static const String blocked = 'BLOCKED';
}

/// What one tap on a person's chip does.
enum PeopleAction { add, accept, none }

/// The chip at the end of a person row.
class RelationChip {
  final String label;
  final PeopleAction action;
  const RelationChip(this.label, this.action);

  /// Tapping it sends something (Add / Accept): drawn as a filled button.
  bool get actionable => action != PeopleAction.none;

  static RelationChip of(String relation) => switch (relation) {
        PeopleRelation.friends => const RelationChip('Friend', PeopleAction.none),
        PeopleRelation.pendingOut => const RelationChip('Requested', PeopleAction.none),
        PeopleRelation.pendingIn => const RelationChip('Accept', PeopleAction.accept),
        PeopleRelation.self => const RelationChip('You', PeopleAction.none),
        PeopleRelation.blocked => const RelationChip('Blocked', PeopleAction.none),
        _ => const RelationChip('Add', PeopleAction.add),
      };
}

/// The username prefix the gateway searches for (lowercase, no "@"), or null while the text cannot
/// match a username (fewer than [peopleSearchMinChars] characters, or characters a username never
/// has, such as an e-mail's "@" or a phone number's "+"). Mirrors gateway searchKeyOf.
String? peopleSearchKey(String raw) {
  final k = raw.trim().replaceFirst(RegExp(r'^@+'), '').trim().toLowerCase();
  return RegExp(r'^[a-z0-9_]{2,20}$').hasMatch(k) ? k : null;
}

const int peopleSearchMinChars = 2;
const Duration peopleSearchDebounce = Duration(milliseconds: 300);

/// A rider in search results or "People you rode with": username, picture, relationship. Nothing
/// else is ever sent.
class PersonCard {
  final String username;
  final String? avatarUrl;
  final String relation;

  /// Rides together ("People you rode with" only).
  final int rides;
  const PersonCard({required this.username, this.avatarUrl, this.relation = PeopleRelation.none, this.rides = 0});

  factory PersonCard.fromJson(Map raw) => PersonCard(
        username: raw['username']?.toString() ?? '',
        avatarUrl: avatarPathOf(raw['avatarUrl']),
        relation: raw['relation']?.toString() ?? PeopleRelation.none,
        rides: raw['rides'] is num ? (raw['rides'] as num).toInt() : 0,
      );

  PersonCard withRelation(String r) => PersonCard(username: username, avatarUrl: avatarUrl, relation: r, rides: rides);

  static List<PersonCard> _list(Object? raw, String field) {
    final l = raw is Map ? raw[field] : null;
    return l is List ? l.whereType<Map>().map(PersonCard.fromJson).where((p) => p.username.isNotEmpty).toList() : const [];
  }

  /// GET /users/search answer (at most 10 rows are kept).
  static List<PersonCard> parseSearch(Object? raw) => _list(raw, 'results').take(10).toList();

  /// GET /friends/suggestions answer.
  static List<PersonCard> parseSuggestions(Object? raw) => _list(raw, 'suggestions');
}

/// The relationship to show for [username] now: the friends lists (refreshed live by the socket)
/// win over what the server said when the row was fetched. [listsLoaded] false (lists not read
/// yet) keeps the server's word.
String liveRelation(
  String username,
  String serverRelation, {
  required Iterable<String> friends,
  required Iterable<String> incoming,
  required Iterable<String> outgoing,
  bool listsLoaded = true,
}) {
  final k = username.toLowerCase();
  bool has(Iterable<String> l) => l.any((u) => u.toLowerCase() == k);
  if (has(friends)) return PeopleRelation.friends;
  if (has(outgoing)) return PeopleRelation.pendingOut;
  if (has(incoming)) return PeopleRelation.pendingIn;
  if (!listsLoaded) return serverRelation;
  // A friend removed, a request cancelled or declined since the row was fetched.
  if (serverRelation == PeopleRelation.friends || serverRelation == PeopleRelation.pendingOut || serverRelation == PeopleRelation.pendingIn) {
    return PeopleRelation.none;
  }
  return serverRelation;
}

// ------------------------------------------------------------------ search box

enum PeopleSearchPhase {
  /// Nothing typed: the hub shows its segments.
  idle,

  /// Typed, but fewer than 2 username characters: no request is sent.
  tooShort,

  /// Waiting for the debounce or the answer (previous results stay on screen).
  loading,
  results,
  empty,
  error,
}

class PeopleSearchState {
  final PeopleSearchPhase phase;

  /// The search key the results belong to.
  final String query;
  final List<PersonCard> results;
  final String? message;
  const PeopleSearchState(this.phase, {this.query = '', this.results = const [], this.message});

  static const PeopleSearchState idle = PeopleSearchState(PeopleSearchPhase.idle);

  /// The hub shows search instead of its segments.
  bool get active => phase != PeopleSearchPhase.idle;
}

/// The search box logic: results as you type, debounced, 2+ characters, the newest query wins.
///
/// [fetch] calls GET /users/search with the key. Every change goes to [onState].
class PeopleSearch {
  PeopleSearch({required this.fetch, required this.onState, this.debounce = peopleSearchDebounce});

  final Future<List<PersonCard>> Function(String key) fetch;
  final void Function(PeopleSearchState state) onState;
  final Duration debounce;

  Timer? _timer;
  int _seq = 0;
  bool _disposed = false;
  PeopleSearchState _state = PeopleSearchState.idle;

  PeopleSearchState get state => _state;

  /// Number of requests sent (tests: debounce sends one per pause).
  int requests = 0;

  void _emit(PeopleSearchState s) {
    if (_disposed) return;
    _state = s;
    onState(s);
  }

  /// The text in the box changed.
  void input(String raw) {
    _timer?.cancel();
    final typed = raw.trim();
    if (typed.isEmpty || typed.replaceFirst(RegExp(r'^@+'), '').isEmpty) {
      _seq++;
      return _emit(PeopleSearchState.idle);
    }
    final key = peopleSearchKey(raw);
    if (key == null) {
      _seq++;
      return _emit(const PeopleSearchState(PeopleSearchPhase.tooShort, message: 'Type 2 or more letters of a username'));
    }
    if (key == _state.query && (_state.phase == PeopleSearchPhase.results || _state.phase == PeopleSearchPhase.empty)) return;
    final seq = ++_seq;
    _emit(PeopleSearchState(PeopleSearchPhase.loading, query: key, results: _state.results));
    _timer = Timer(debounce, () => _run(key, seq));
  }

  /// Search again now (pull to refresh, retry).
  void retry() {
    final key = _state.query;
    if (key.isEmpty) return;
    _timer?.cancel();
    final seq = ++_seq;
    _emit(PeopleSearchState(PeopleSearchPhase.loading, query: key, results: _state.results));
    _run(key, seq);
  }

  Future<void> _run(String key, int seq) async {
    requests++;
    try {
      final rows = await fetch(key);
      if (seq != _seq) return; // a newer query was typed meanwhile
      _emit(PeopleSearchState(rows.isEmpty ? PeopleSearchPhase.empty : PeopleSearchPhase.results, query: key, results: rows));
    } catch (_) {
      if (seq != _seq) return;
      _emit(PeopleSearchState(PeopleSearchPhase.error, query: key, message: 'Could not search right now'));
    }
  }

  /// After a one-tap Add / Accept: the row shows its new state at once.
  void markRelation(String username, String relation) {
    final k = username.toLowerCase();
    if (!_state.results.any((p) => p.username.toLowerCase() == k)) return;
    _emit(PeopleSearchState(_state.phase, query: _state.query, message: _state.message, results: [
      for (final p in _state.results) p.username.toLowerCase() == k ? p.withRelation(relation) : p,
    ]));
  }

  void clear() => input('');

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}

// ------------------------------------------------------------------ requests

enum RequestKind { friend, crew, ride }

/// One row of the Requests segment: a friend request, a crew invite or a ride invite.
class RequestItem {
  final RequestKind kind;

  /// requestId / crew inviteId / ride inviteId (what accept / decline / cancel need).
  final String id;

  /// Addressed to me (Accept / Decline) or sent by me (Cancel; friend requests only).
  final bool incoming;

  /// The rider the row is about (the requester, the inviter, the ride host, or whom I asked).
  final String username;
  final String? avatarUrl;

  /// Crew rows: the crew; ride rows: the ride name (or the crew).
  final String title;

  /// One short line ("Wants to be friends", "Crew invite · 4 riders").
  final String subtitle;
  final String crewId;
  final int at;

  const RequestItem({
    required this.kind,
    required this.id,
    required this.incoming,
    required this.username,
    this.avatarUrl,
    this.title = '',
    this.subtitle = '',
    this.crewId = '',
    this.at = 0,
  });

  String get key => '${kind.name}:$id';

  factory RequestItem.friendIncoming(FriendRequestEntry r) =>
      RequestItem(kind: RequestKind.friend, id: r.requestId, incoming: true, username: r.username, avatarUrl: r.avatarUrl, title: r.username, subtitle: 'Wants to be friends', at: r.at);

  factory RequestItem.friendSent(FriendRequestEntry r) =>
      RequestItem(kind: RequestKind.friend, id: r.requestId, incoming: false, username: r.username, avatarUrl: r.avatarUrl, title: r.username, subtitle: 'Requested', at: r.at);

  factory RequestItem.crewInvite({
    required String inviteId,
    required String crewId,
    required String crewName,
    required String invitedBy,
    String? invitedByAvatar,
    int memberCount = 0,
    int at = 0,
  }) =>
      RequestItem(
        kind: RequestKind.crew,
        id: inviteId,
        incoming: true,
        username: invitedBy,
        avatarUrl: invitedByAvatar,
        title: crewName.isEmpty ? 'Crew' : crewName,
        subtitle: memberCount > 0 ? 'Crew invite · $memberCount ${memberCount == 1 ? 'rider' : 'riders'}' : 'Crew invite',
        crewId: crewId,
        at: at,
      );

  factory RequestItem.rideInvite(RideInvite i) => RequestItem(
        kind: RequestKind.ride,
        id: i.inviteId,
        incoming: true,
        username: i.hostUsername,
        avatarUrl: i.hostAvatarUrl,
        title: i.rideName.isNotEmpty ? i.rideName : (i.crewName.isNotEmpty ? i.crewName : 'Group ride'),
        subtitle: i.crewName.isNotEmpty ? 'Ride invite · ${i.crewName}' : 'Ride invite',
        crewId: i.crewId,
        at: i.createdAt,
      );
}

/// Every request in one list: incoming first (ride invites on top, they expire within the hour;
/// then newest first), then the requests I sent (newest first). Duplicates (same kind and id, for
/// example a socket row and the fetched row) appear once; rows without an id are left out.
List<RequestItem> mergeRequests({
  Iterable<FriendRequestEntry> friendIncoming = const [],
  Iterable<FriendRequestEntry> friendSent = const [],
  Iterable<RequestItem> crewInvites = const [],
  Iterable<RideInvite> rideInvites = const [],
  int? nowMs,
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final seen = <String>{};
  final incoming = <RequestItem>[];
  final sent = <RequestItem>[];
  void add(RequestItem r, List<RequestItem> into) {
    if (r.id.isEmpty || !seen.add(r.key)) return;
    into.add(r);
  }

  for (final r in friendIncoming) {
    if (r.valid) add(RequestItem.friendIncoming(r), incoming);
  }
  for (final c in crewInvites) {
    add(c, incoming);
  }
  for (final i in rideInvites) {
    if (i.status != RideInviteStatus.pending || (i.expiresAt > 0 && i.expiresAt <= now)) continue;
    add(RequestItem.rideInvite(i), incoming);
  }
  for (final r in friendSent) {
    if (r.valid) add(RequestItem.friendSent(r), sent);
  }
  int rank(RequestItem r) => r.kind == RequestKind.ride ? 0 : 1;
  incoming.sort((a, b) {
    final k = rank(a).compareTo(rank(b));
    return k != 0 ? k : b.at.compareTo(a.at);
  });
  sent.sort((a, b) => b.at.compareTo(a.at));
  return [...incoming, ...sent];
}

/// The numbers on the bottom bar's People tab, the hub segments and the profile: always the same
/// sum, so a badge never disagrees with the list it opens.
class PeopleBadges {
  /// Requests waiting for my answer: friend requests + crew invites + ride invites.
  final int requests;

  /// Open crew polls I have not voted in.
  final int crews;
  const PeopleBadges({this.requests = 0, this.crews = 0});

  int get total => requests + crews;

  /// "9+" above nine.
  static String label(int n) => n > 9 ? '9+' : '$n';

  /// Switched-off features count nothing.
  static PeopleBadges of({
    int friendRequests = 0,
    int crewInvites = 0,
    int rideInvites = 0,
    int pendingVotes = 0,
    bool friendsOn = true,
    bool crewsOn = true,
    bool pollsOn = true,
    bool crewRidesOn = true,
  }) =>
      PeopleBadges(
        requests: (friendsOn ? friendRequests : 0) + (crewsOn ? crewInvites : 0) + (crewsOn && crewRidesOn ? rideInvites : 0),
        crews: crewsOn && pollsOn ? pendingVotes : 0,
      );
}

/// The hint under a crew in the Crews list: a ride invite waiting, votes to cast, or when the next
/// poll closes. Null when there is nothing to say.
String? crewHint({int pendingVotes = 0, int openPolls = 0, int nextPollClosesAt = 0, bool rideInvite = false, int? nowMs}) {
  if (rideInvite) return 'Ride invite waiting';
  if (pendingVotes > 0) return pendingVotes == 1 ? '1 poll to vote' : '$pendingVotes polls to vote';
  if (openPolls > 0) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final left = nextPollClosesAt - now;
    if (nextPollClosesAt > 0 && left > 0) {
      final h = left ~/ 3600000;
      return h < 1 ? 'Poll closes within the hour' : h < 48 ? 'Poll closes in $h h' : 'Poll closes in ${h ~/ 24} days';
    }
    return openPolls == 1 ? '1 open poll' : '$openPolls open polls';
  }
  return null;
}

// ------------------------------------------------------------------ friend picker (crews)

/// [all] usernames containing [query] (any capitals, a leading "@" ignored), in their order.
List<String> filterUsernames(Iterable<String> all, String query) {
  final q = query.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
  return q.isEmpty ? all.toList() : all.where((u) => u.toLowerCase().contains(q)).toList();
}

/// "Select all" in a friend picker: every [visible] name picked (up to [cap] picked in total), or,
/// when all of them already are, none of them. Names picked but filtered out stay picked.
Set<String> toggleAllPicked(Set<String> picked, List<String> visible, {int? cap}) {
  if (visible.isNotEmpty && visible.every(picked.contains)) return {...picked}..removeAll(visible);
  final out = {...picked};
  for (final u in visible) {
    if (cap != null && out.length >= cap) break;
    out.add(u);
  }
  return out;
}
