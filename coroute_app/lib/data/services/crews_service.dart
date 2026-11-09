import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../domain/notify/notice_dedupe.dart';
import '../../domain/social/crew_rules.dart';
import 'api_client.dart';
import 'feature_flags_service.dart';
import 'realtime_service.dart';

String? _avatar(Object? v) {
  final s = v?.toString() ?? '';
  return s.startsWith('/api/avatars/') ? s : null;
}

int _i(Object? v) => v is num ? v.toInt() : 0;
List<T> _list<T>(Object? raw, T Function(Map) f) => raw is List ? raw.whereType<Map>().map(f).toList() : <T>[];

/// One of my crews (GET /crews).
@immutable
class CrewSummary {
  final String crewId;
  final String name;
  final String description;
  final int memberCount;
  final String myRole;
  final String? admin;
  final int openPolls;
  final int pendingVotes;
  const CrewSummary({
    required this.crewId,
    required this.name,
    this.description = '',
    this.memberCount = 0,
    this.myRole = CrewRoles.member,
    this.admin,
    this.openPolls = 0,
    this.pendingVotes = 0,
  });
  factory CrewSummary.fromJson(Map m) => CrewSummary(
        crewId: m['crewId']?.toString() ?? '',
        name: m['name']?.toString() ?? '',
        description: m['description']?.toString() ?? '',
        memberCount: _i(m['memberCount']),
        myRole: m['myRole']?.toString() ?? CrewRoles.member,
        admin: m['admin']?.toString(),
        openPolls: _i(m['openPolls']),
        pendingVotes: _i(m['pendingVotes']),
      );
}

/// An invitation to join a crew, addressed to me.
@immutable
class CrewInvite {
  final String inviteId;
  final String crewId;
  final String crewName;
  final String description;
  final int memberCount;
  final String invitedBy;
  final String? invitedByAvatar;
  final int expiresAt;
  const CrewInvite({
    required this.inviteId,
    required this.crewId,
    required this.crewName,
    this.description = '',
    this.memberCount = 0,
    this.invitedBy = '',
    this.invitedByAvatar,
    this.expiresAt = 0,
  });
  factory CrewInvite.fromJson(Map m) {
    final by = m['invitedBy'] is Map ? m['invitedBy'] as Map : const {};
    return CrewInvite(
      inviteId: m['inviteId']?.toString() ?? '',
      crewId: m['crewId']?.toString() ?? '',
      crewName: m['crewName']?.toString() ?? '',
      description: m['description']?.toString() ?? '',
      memberCount: _i(m['memberCount']),
      invitedBy: by['username']?.toString() ?? '',
      invitedByAvatar: _avatar(by['avatarUrl']),
      expiresAt: _i(m['expiresAt']),
    );
  }
}

/// A crew member as the gateway shows it: username, first name, picture, role. Nothing else.
@immutable
class CrewMember {
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String role;
  final int joinedAt;
  const CrewMember({required this.username, this.displayName = '', this.avatarUrl, this.role = CrewRoles.member, this.joinedAt = 0});
  factory CrewMember.fromJson(Map m) => CrewMember(
        username: m['username']?.toString() ?? '',
        displayName: m['displayName']?.toString() ?? '',
        avatarUrl: _avatar(m['avatarUrl']),
        role: m['role']?.toString() ?? CrewRoles.member,
        joinedAt: _i(m['joinedAt']),
      );
}

/// An invite waiting for an answer (shown to the admin and co-admins).
@immutable
class CrewPendingInvite {
  final String inviteId;
  final String username;
  final String? avatarUrl;
  final String? invitedBy;
  final int expiresAt;
  const CrewPendingInvite({required this.inviteId, required this.username, this.avatarUrl, this.invitedBy, this.expiresAt = 0});
  factory CrewPendingInvite.fromJson(Map m) => CrewPendingInvite(
        inviteId: m['inviteId']?.toString() ?? '',
        username: m['username']?.toString() ?? '',
        avatarUrl: _avatar(m['avatarUrl']),
        invitedBy: m['invitedBy']?.toString(),
        expiresAt: _i(m['expiresAt']),
      );
}

/// GET /crews/:crewId.
@immutable
class CrewDetail {
  final String crewId;
  final String name;
  final String description;
  final int memberCount;
  final String myRole;
  final bool canInvite;
  final bool canCreatePoll;
  final bool membersCanCreatePolls;
  final List<CrewMember> members;
  final List<CrewPendingInvite> invites;
  const CrewDetail({
    required this.crewId,
    required this.name,
    this.description = '',
    this.memberCount = 0,
    this.myRole = CrewRoles.member,
    this.canInvite = false,
    this.canCreatePoll = false,
    this.membersCanCreatePolls = false,
    this.members = const [],
    this.invites = const [],
  });
  bool get isAdmin => myRole == CrewRoles.admin;
  int get coAdmins => members.where((m) => m.role == CrewRoles.coAdmin).length;

  factory CrewDetail.fromJson(Map res) {
    final c = res['crew'] is Map ? res['crew'] as Map : const {};
    final s = c['settings'] is Map ? c['settings'] as Map : const {};
    return CrewDetail(
      crewId: c['crewId']?.toString() ?? '',
      name: c['name']?.toString() ?? '',
      description: c['description']?.toString() ?? '',
      memberCount: _i(c['memberCount']),
      myRole: c['myRole']?.toString() ?? CrewRoles.member,
      canInvite: c['canInvite'] == true,
      canCreatePoll: c['canCreatePoll'] == true,
      membersCanCreatePolls: s['membersCanCreatePolls'] == true,
      members: _list(res['members'], CrewMember.fromJson),
      invites: _list(res['invites'], CrewPendingInvite.fromJson),
    );
  }
}

@immutable
class PollOption {
  final String id;
  final String text;
  final int count;
  final int percent;
  const PollOption({required this.id, required this.text, this.count = 0, this.percent = 0});
  factory PollOption.fromJson(Map m) =>
      PollOption(id: m['id']?.toString() ?? '', text: m['text']?.toString() ?? '', count: _i(m['count']), percent: _i(m['percent']));
}

/// A crew poll with its results. [voters] is empty for anonymous polls.
@immutable
class CrewPoll {
  final String pollId;
  final String question;
  final List<PollOption> options;
  final bool multi;
  final bool anonymous;
  final String? template;
  final bool open;
  final int createdAt;
  final int closesAt;
  final String? createdBy;
  final int totalVoters;
  final List<String> leaders;
  final List<String> myVote;
  final bool canClose;
  final bool canDelete;
  final Map<String, List<String>> voters;
  const CrewPoll({
    required this.pollId,
    required this.question,
    required this.options,
    this.multi = false,
    this.anonymous = false,
    this.template,
    this.open = true,
    this.createdAt = 0,
    this.closesAt = 0,
    this.createdBy,
    this.totalVoters = 0,
    this.leaders = const [],
    this.myVote = const [],
    this.canClose = false,
    this.canDelete = false,
    this.voters = const {},
  });

  factory CrewPoll.fromJson(Map m) {
    final voters = <String, List<String>>{};
    final raw = m['voters'];
    if (raw is Map) {
      raw.forEach((k, v) {
        voters[k.toString()] = v is List ? v.whereType<Map>().map((x) => x['username']?.toString() ?? '').where((s) => s.isNotEmpty).toList() : <String>[];
      });
    }
    return CrewPoll(
      pollId: m['pollId']?.toString() ?? '',
      question: m['question']?.toString() ?? '',
      options: _list(m['options'], PollOption.fromJson),
      multi: m['multi'] == true,
      anonymous: m['anonymous'] == true,
      template: m['template']?.toString(),
      open: m['status'] == 'OPEN',
      createdAt: _i(m['createdAt']),
      closesAt: _i(m['closesAt']),
      createdBy: m['createdBy']?.toString(),
      totalVoters: _i(m['totalVoters']),
      leaders: m['leaders'] is List ? (m['leaders'] as List).map((e) => e.toString()).toList() : const [],
      myVote: m['myVote'] is List ? (m['myVote'] as List).map((e) => e.toString()).toList() : const [],
      canClose: m['canClose'] == true,
      canDelete: m['canDelete'] == true,
      voters: voters,
    );
  }

  /// Results recomputed on the phone from per-option counts (bars).
  double fill(String optionId) {
    if (totalVoters == 0) return 0;
    final o = options.where((x) => x.id == optionId);
    return o.isEmpty ? 0 : (o.first.count / totalVoters).clamp(0, 1).toDouble();
  }
}

/// A friend in the invite picker: AVAILABLE, INVITED or MEMBER.
@immutable
class InvitableFriend {
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String status;
  const InvitableFriend({required this.username, this.displayName = '', this.avatarUrl, this.status = 'AVAILABLE'});
  factory InvitableFriend.fromJson(Map m) => InvitableFriend(
        username: m['username']?.toString() ?? '',
        displayName: m['displayName']?.toString() ?? '',
        avatarUrl: _avatar(m['avatarUrl']),
        status: m['status']?.toString() ?? 'AVAILABLE',
      );
  bool get available => status == 'AVAILABLE';
}

/// 3.55 Crews and crew polls (docs/features_355/crews_polls.md).
///
/// GET /crews keeps my crews and invitations; socket pushes CREW_INVITE, POLL_CREATED, POLL_UPDATED,
/// CREW_UPDATED, CREW_REMOVED, CREW_DELETED refresh it and tell an open crew screen to reload
/// ([changes]). The badge counts invitations plus open polls I have not answered.
/// Admin switches `crews` and `crewPolls`.
class CrewsService extends ChangeNotifier {
  CrewsService(this._api, {RealtimeService? realtime, bool autoStart = true}) : _rt = realtime {
    if (autoStart) start();
  }

  static const String crewsFlag = 'crews';
  static const String pollsFlag = 'crewPolls';
  static const Set<String> pushTypes = {'CREW_INVITE', 'POLL_CREATED', 'POLL_UPDATED', 'CREW_UPDATED', 'CREW_REMOVED', 'CREW_DELETED'};

  final ApiClient _api;
  final RealtimeService? _rt;
  StreamSubscription<Map<String, dynamic>>? _sub;
  AppLifecycleListener? _lifecycle;
  final StreamController<String> _changes = StreamController<String>.broadcast();
  bool _started = false;
  bool _disposed = false;
  bool _hadToken = false;

  List<CrewSummary> _crews = const [];
  List<CrewInvite> _invites = const [];
  bool _loaded = false;
  String? _lastNotice;

  List<CrewSummary> get crews => _crews;
  List<CrewInvite> get invites => _invites;
  bool get loaded => _loaded;

  /// crewId of a crew that changed (vote, new poll, member change). Open screens reload on it.
  Stream<String> get changes => _changes.stream;

  int get badgeCount {
    if (!FeatureFlagsService.on(crewsFlag)) return 0;
    final polls = FeatureFlagsService.on(pollsFlag) ? _crews.fold<int>(0, (a, c) => a + c.pendingVotes) : 0;
    return _invites.length + polls;
  }

  /// One line for the last push worth telling ("X invited you to Y"); cleared on read.
  String? takeNotice() {
    final n = _lastNotice;
    _lastNotice = null;
    return n;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started) return;
    _started = true;
    _hadToken = _api.hasToken;
    _sub = _rt?.events.listen(_onPush);
    _api.addListener(_onApiChanged);
    try {
      _lifecycle = AppLifecycleListener(onResume: () => refresh());
    } catch (_) {
      // No binding (pure unit tests).
    }
    if (_api.hasToken) refresh();
  }

  void _onPush(Map<String, dynamic> msg) {
    final type = msg['type']?.toString();
    if (type == null || !pushTypes.contains(type)) return;
    final crewId = msg['crewId']?.toString() ?? '';
    final who = msg['username']?.toString() ?? 'A rider';
    final crew = msg['crewName']?.toString() ?? 'a crew';
    // 3.55 follow-up: the same event already shown (its push arrived first): refresh only.
    final fresh = NoticeDedupe.shared.firstTime(msg['eventId']);
    switch (fresh ? type : '') {
      case 'CREW_INVITE':
        _lastNotice = '$who invited you to $crew';
      case 'POLL_CREATED':
        _lastNotice = 'New poll in $crew';
      case 'CREW_REMOVED':
        _lastNotice = 'You were removed from $crew';
      case 'CREW_DELETED':
        _lastNotice = '$crew was deleted';
      default:
        if (msg['event'] == 'YOU_ARE_ADMIN') _lastNotice = 'You are now the admin of $crew';
    }
    if (crewId.isNotEmpty && !_changes.isClosed) _changes.add(crewId);
    refresh();
  }

  void _onApiChanged() {
    final has = _api.hasToken;
    if (has && !_hadToken) refresh();
    if (!has && _hadToken) {
      _crews = const [];
      _invites = const [];
      _loaded = false;
      _notify();
    }
    _hadToken = has;
  }

  Future<void> refresh() async {
    if (_disposed || !_api.hasToken || !FeatureFlagsService.on(crewsFlag)) return;
    try {
      final res = await _api.get('/crews');
      if (res is! Map) return;
      _crews = _list(res['crews'], CrewSummary.fromJson);
      _invites = _list(res['invites'], CrewInvite.fromJson);
      _loaded = true;
      _notify();
    } catch (e) {
      debugPrint('Crews not refreshed: $e');
    }
  }

  String _p(String crewId) => '/crews/${Uri.encodeComponent(crewId)}';

  /// Runs [call]; null on success, else the gateway's message.
  Future<String?> _act(Future<dynamic> Function() call, {bool reload = true}) async {
    try {
      await call();
      if (reload) await refresh();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not reach CoRoute. Try again.';
    }
  }

  /// POST /crews. Returns (crewId, error).
  Future<(String?, String?)> create(String name, String description) async {
    final err = CrewRules.checkName(name) ?? CrewRules.checkDescription(description);
    if (err != null) return (null, err);
    try {
      final res = await _api.post('/crews', {'name': CrewRules.clean(name), 'description': CrewRules.clean(description)});
      await refresh();
      final crew = res is Map && res['crew'] is Map ? res['crew'] as Map : const {};
      return (crew['crewId']?.toString(), null);
    } on ApiException catch (e) {
      return (null, e.message);
    }
  }

  /// GET /crews/:crewId. Throws ApiException (404 when I am not a member).
  Future<CrewDetail> detail(String crewId) async {
    final res = await _api.get(_p(crewId));
    return CrewDetail.fromJson(res is Map ? res : const {});
  }

  Future<String?> update(String crewId, {String? name, String? description, bool? membersCanCreatePolls}) => _act(() => _api.patch(_p(crewId), {
        if (name != null) 'name': CrewRules.clean(name),
        if (description != null) 'description': CrewRules.clean(description),
        'membersCanCreatePolls': ?membersCanCreatePolls,
      }));

  Future<String?> deleteCrew(String crewId) => _act(() => _api.delete(_p(crewId)));

  Future<List<InvitableFriend>> invitable(String crewId) async {
    final res = await _api.get('${_p(crewId)}/invitable');
    return _list(res is Map ? res['friends'] : null, InvitableFriend.fromJson);
  }

  /// Invites friends. Returns (invitedCount, error).
  Future<(int, String?)> invite(String crewId, List<String> usernames) async {
    try {
      final res = await _api.post('${_p(crewId)}/invites', {'usernames': usernames});
      final results = res is Map && res['results'] is List ? (res['results'] as List).whereType<Map>() : const <Map>[];
      final invited = results.where((r) => r['status'] == 'INVITED').length;
      final full = results.any((r) => r['status'] == 'CREW_FULL');
      return (invited, full ? 'The crew is full (${CrewLimits.maxMembers} riders, counting invites).' : null);
    } on ApiException catch (e) {
      return (0, e.message);
    }
  }

  Future<String?> cancelInvite(String crewId, String inviteId) =>
      _act(() => _api.delete('${_p(crewId)}/invites/${Uri.encodeComponent(inviteId)}'), reload: false);

  Future<String?> respondInvite(String inviteId, bool accept) =>
      _act(() => _api.post('/crews/invites/${Uri.encodeComponent(inviteId)}/${accept ? 'accept' : 'decline'}'));

  Future<String?> leave(String crewId, {String? transferTo}) =>
      _act(() => _api.post('${_p(crewId)}/leave', {'transferTo': ?transferTo}));

  Future<String?> removeMember(String crewId, String username) =>
      _act(() => _api.delete('${_p(crewId)}/members/${Uri.encodeComponent(username)}'));

  Future<String?> setRole(String crewId, String username, String role) =>
      _act(() => _api.patch('${_p(crewId)}/members/${Uri.encodeComponent(username)}', {'role': role}), reload: false);

  Future<String?> transfer(String crewId, String username) => _act(() => _api.post('${_p(crewId)}/transfer', {'username': username}));

  // ---- polls ----
  Future<List<CrewPoll>> polls(String crewId) async {
    final res = await _api.get('${_p(crewId)}/polls');
    return _list(res is Map ? res['polls'] : null, CrewPoll.fromJson);
  }

  Future<String?> createPoll(
    String crewId, {
    required String question,
    required List<String> options,
    bool multi = false,
    bool anonymous = false,
    Duration duration = CrewLimits.pollDefault,
    String? template,
  }) {
    final closesAt = DateTime.now().add(duration);
    final err = CrewRules.checkPoll(question: question, options: options, closesAt: closesAt);
    if (err != null) return Future.value(err);
    return _act(() => _api.post('${_p(crewId)}/polls', {
          'question': CrewRules.clean(question),
          'options': options.map(CrewRules.clean).toList(),
          'multi': multi,
          'anonymous': anonymous,
          'durationHours': duration.inMinutes / 60,
          'template': ?template,
        }));
  }

  String _poll(String crewId, String pollId) => '${_p(crewId)}/polls/${Uri.encodeComponent(pollId)}';

  /// Votes (or changes the vote). Returns (updated poll, error).
  Future<(CrewPoll?, String?)> vote(String crewId, CrewPoll poll, List<String> optionIds) async {
    final err = checkVote(multi: poll.multi, optionIds: poll.options.map((o) => o.id).toList(), picked: optionIds);
    if (err != null) return (null, err);
    try {
      final res = await _api.post('${_poll(crewId, poll.pollId)}/vote', {'optionIds': optionIds});
      refresh();
      return (res is Map && res['poll'] is Map ? CrewPoll.fromJson(res['poll'] as Map) : null, null);
    } on ApiException catch (e) {
      return (null, e.message);
    }
  }

  Future<String?> retractVote(String crewId, String pollId) => _act(() => _api.delete('${_poll(crewId, pollId)}/vote'));
  Future<String?> closePoll(String crewId, String pollId) => _act(() => _api.post('${_poll(crewId, pollId)}/close'));
  Future<String?> deletePoll(String crewId, String pollId) => _act(() => _api.delete(_poll(crewId, pollId)));

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _lifecycle?.dispose();
    _changes.close();
    _api.removeListener(_onApiChanged);
    super.dispose();
  }
}
