import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/notify/notice_dedupe.dart';
import '../../domain/social/username_rules.dart';
import 'alarm_notifier.dart';
import 'api_client.dart';
import 'feature_flags_service.dart';
import 'realtime_service.dart';

/// Ride totals shown on a profile (GET /me/stats, friends' profiles).
@immutable
class RideTotals {
  final int trips;
  final double totalKm;
  final double ridingHours;
  final double longestTripKm;
  final int largestGroup;
  final int memberSince;
  const RideTotals({
    this.trips = 0,
    this.totalKm = 0,
    this.ridingHours = 0,
    this.longestTripKm = 0,
    this.largestGroup = 0,
    this.memberSince = 0,
  });

  static double _d(Object? v) => v is num ? v.toDouble() : 0;
  static int _i(Object? v) => v is num ? v.toInt() : 0;

  factory RideTotals.fromJson(Object? raw) {
    if (raw is! Map) return const RideTotals();
    return RideTotals(
      trips: _i(raw['trips']),
      totalKm: _d(raw['totalKm']),
      ridingHours: _d(raw['ridingHours']),
      longestTripKm: _d(raw['longestTripKm']),
      largestGroup: _i(raw['largestGroup']),
      memberSince: _i(raw['memberSince']),
    );
  }
}

/// The signed-in rider's public identity and settings (GET /me/profile).
@immutable
class MyProfile {
  final String username;
  final String name;
  final String? avatarUrl;
  final bool publicLeaderboard;
  final int usernameChangedAt;
  final int memberSince;
  final String? inviteCode;
  final String? inviteLink;
  final String? shareText;
  const MyProfile({
    required this.username,
    this.name = '',
    this.avatarUrl,
    this.publicLeaderboard = true,
    this.usernameChangedAt = 0,
    this.memberSince = 0,
    this.inviteCode,
    this.inviteLink,
    this.shareText,
  });

  factory MyProfile.fromJson(Map raw) => MyProfile(
        username: raw['username']?.toString() ?? '',
        name: raw['name']?.toString() ?? '',
        avatarUrl: _url(raw['avatarUrl']),
        publicLeaderboard: raw['publicLeaderboard'] != false,
        usernameChangedAt: raw['usernameChangedAt'] is num ? (raw['usernameChangedAt'] as num).toInt() : 0,
        memberSince: raw['memberSince'] is num ? (raw['memberSince'] as num).toInt() : 0,
        inviteCode: raw['inviteCode']?.toString(),
        inviteLink: raw['inviteLink']?.toString(),
        shareText: raw['shareText']?.toString(),
      );

  /// When a new username may be chosen (null = now).
  DateTime? get nextUsernameChange => UsernameRules.nextChangeAt(usernameChangedAt);
}

String? _url(Object? v) {
  final s = v?.toString() ?? '';
  return s.startsWith('/api/avatars/') ? s : null;
}

/// One friend in the list (username, first name, picture, totals).
@immutable
class FriendEntry {
  final String username;
  final String displayName;
  final String? avatarUrl;
  final int since;
  final int trips;
  final double totalKm;
  const FriendEntry({required this.username, this.displayName = '', this.avatarUrl, this.since = 0, this.trips = 0, this.totalKm = 0});
  factory FriendEntry.fromJson(Map raw) => FriendEntry(
        username: raw['username']?.toString() ?? '',
        displayName: raw['displayName']?.toString() ?? '',
        avatarUrl: _url(raw['avatarUrl']),
        since: raw['since'] is num ? (raw['since'] as num).toInt() : 0,
        trips: raw['trips'] is num ? (raw['trips'] as num).toInt() : 0,
        totalKm: raw['totalKm'] is num ? (raw['totalKm'] as num).toDouble() : 0,
      );
}

/// A waiting request (incoming or outgoing).
@immutable
class FriendRequestEntry {
  final String requestId;
  final String username;
  final String? avatarUrl;
  final int at;
  const FriendRequestEntry({required this.requestId, required this.username, this.avatarUrl, this.at = 0});
  factory FriendRequestEntry.fromJson(Map raw) => FriendRequestEntry(
        requestId: raw['requestId']?.toString() ?? '',
        username: raw['username']?.toString() ?? '',
        avatarUrl: _url(raw['avatarUrl']),
        at: raw['at'] is num ? (raw['at'] as num).toInt() : 0,
      );
}

/// Another rider's profile as the gateway allows me to see it.
@immutable
class RiderProfile {
  final String username;
  final String? avatarUrl;

  /// SELF, FRIENDS, PENDING_OUT, PENDING_IN, BLOCKED or NONE.
  final String relation;
  final String? displayName;
  final int? trips;
  final double? totalKm;
  final double? ridingHours;
  final int? score;
  final String? level;
  const RiderProfile({
    required this.username,
    this.avatarUrl,
    this.relation = 'NONE',
    this.displayName,
    this.trips,
    this.totalKm,
    this.ridingHours,
    this.score,
    this.level,
  });
  factory RiderProfile.fromJson(Map raw) {
    final s = raw['stats'] is Map ? raw['stats'] as Map : null;
    return RiderProfile(
      username: raw['username']?.toString() ?? '',
      avatarUrl: _url(raw['avatarUrl']),
      relation: raw['relation']?.toString() ?? 'NONE',
      displayName: raw['displayName']?.toString(),
      trips: s?['trips'] is num ? (s!['trips'] as num).toInt() : null,
      totalKm: s?['totalKm'] is num ? (s!['totalKm'] as num).toDouble() : null,
      ridingHours: s?['ridingHours'] is num ? (s!['ridingHours'] as num).toDouble() : null,
      score: s?['score'] is num ? (s!['score'] as num).round() : null,
      level: s?['level']?.toString(),
    );
  }
  bool get hasStats => trips != null;
}

/// Outcome of a friend request ("REQUESTED", "FRIENDS", "ALREADY_FRIENDS") or an error message.
@immutable
class FriendRequestResult {
  final String? status;
  final String? error;
  const FriendRequestResult({this.status, this.error});
  bool get ok => error == null;
}

/// 3.55 profile, usernames, friends and profile pictures (docs/features_355/usernames_friends_profiles.md).
///
/// Sources: GET /me/profile, /me/stats, /me/score (scoring module; absent until enough rides),
/// /friends; socket pushes FRIEND_REQUEST / FRIEND_ACCEPTED refresh the list (and the badge on
/// the Profile tab). Admin switches `friends` and `profilePhotos`.
class FriendsService extends ChangeNotifier {
  FriendsService(this._api, {RealtimeService? realtime, bool autoStart = true}) : _rt = realtime {
    if (autoStart) start();
  }

  static const String friendsFlag = 'friends';
  static const String photosFlag = 'profilePhotos';
  static const String _pendingInviteKey = 'coroute_pending_friend_invite';

  final ApiClient _api;
  final RealtimeService? _rt;
  StreamSubscription<Map<String, dynamic>>? _sub;
  AppLifecycleListener? _lifecycle;
  bool _started = false;
  bool _disposed = false;
  bool _hadToken = false;

  MyProfile? _profile;
  RideTotals _stats = const RideTotals();
  Map<String, dynamic>? _score;
  List<FriendEntry> _friends = const [];
  List<FriendRequestEntry> _incoming = const [];
  List<FriendRequestEntry> _outgoing = const [];
  List<String> _blocked = const [];
  bool _loading = false;
  String? _lastNotice;
  final Map<String, Map<String, ({String username, String? avatarUrl})>> _groupNames = {};

  MyProfile? get profile => _profile;
  RideTotals get stats => _stats;

  /// GET /me/score body ({score, level, components, ridesCounted, updatedAt}) or null while absent.
  Map<String, dynamic>? get score => _score;
  int? get scoreValue => _score?['score'] is num ? (_score!['score'] as num).round() : null;
  String? get scoreLevel => _score?['level']?.toString();
  List<FriendEntry> get friends => _friends;
  List<FriendRequestEntry> get incoming => _incoming;
  List<FriendRequestEntry> get outgoing => _outgoing;
  List<String> get blocked => _blocked;
  bool get loading => _loading;

  /// Number shown on the Profile tab badge (incoming requests).
  int get badgeCount => FeatureFlagsService.on(friendsFlag) ? _incoming.length : 0;

  /// 3.55: the system notification for a friend push while the app is in the background
  /// (replaceable in tests).
  @visibleForTesting
  static Future<void> Function(String title, String body) systemNotice = AlarmNotifier.showSocialNotice;

  static bool _inForeground() {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == null || s == AppLifecycleState.resumed;
    } catch (_) {
      return true; // no binding (pure unit tests)
    }
  }

  /// The last push worth a one-line notice ("X wants to be friends"); cleared by [takeNotice].
  String? takeNotice() {
    final n = _lastNotice;
    _lastNotice = null;
    return n;
  }

  ApiClient get api => _api;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started) return;
    _started = true;
    _hadToken = _api.hasToken;
    _sub = _rt?.events.listen((msg) {
      final type = msg['type'];
      if (type != 'FRIEND_REQUEST' && type != 'FRIEND_ACCEPTED') return;
      // 3.55 follow-up: the same event already shown (its push arrived first): refresh only.
      if (!NoticeDedupe.shared.firstTime(msg['eventId'])) {
        refreshFriends();
        return;
      }
      final who = msg['username']?.toString() ?? 'A rider';
      final line = type == 'FRIEND_REQUEST' ? '$who wants to be friends' : '$who accepted your friend request';
      // 3.55: in the background a system notification; in the foreground FriendNoticeHost shows
      // the line as a snackbar (via takeNotice).
      if (FeatureFlagsService.on(friendsFlag) && !_inForeground()) {
        _lastNotice = null;
        systemNotice(type == 'FRIEND_REQUEST' ? 'Friend request' : 'New friend', line).ignore();
      } else {
        _lastNotice = line;
      }
      refreshFriends();
    });
    _api.addListener(_onApiChanged);
    try {
      _lifecycle = AppLifecycleListener(onResume: () => refreshFriends());
    } catch (_) {
      // No binding (pure unit tests).
    }
    if (_api.hasToken) refreshAll();
  }

  void _onApiChanged() {
    final has = _api.hasToken;
    if (has && !_hadToken) {
      refreshAll();
      consumePendingInvite();
    }
    if (!has && _hadToken) _clear();
    _hadToken = has;
  }

  void _clear() {
    _profile = null;
    _stats = const RideTotals();
    _score = null;
    _friends = const [];
    _incoming = const [];
    _outgoing = const [];
    _blocked = const [];
    _groupNames.clear();
    _notify();
  }

  Future<void> refreshAll() async {
    // The own rider score is shown by RiderScoreCard (its own GET /me/score); not fetched twice here.
    await Future.wait([refreshProfile(), refreshFriends()]);
  }

  /// GET /me/profile (username, picture, invite code, totals).
  Future<void> refreshProfile() async {
    if (_disposed || !_api.hasToken) return;
    _loading = true;
    _notify();
    try {
      final res = await _api.get('/me/profile');
      if (res is Map && res['profile'] is Map) {
        _profile = MyProfile.fromJson(res['profile'] as Map);
        _stats = RideTotals.fromJson(res['stats']);
      }
    } catch (e) {
      debugPrint('Profile not refreshed: $e');
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// GET /me/score: absent (404 or score null) until enough rides; never an error on screen.
  Future<void> refreshScore() async {
    if (_disposed || !_api.hasToken) return;
    try {
      final res = await _api.get('/me/score');
      _score = res is Map && res['score'] is num ? Map<String, dynamic>.from(res) : null;
    } catch (_) {
      _score = null;
    }
    _notify();
  }

  Future<void> refreshFriends() async {
    if (_disposed || !_api.hasToken || !FeatureFlagsService.on(friendsFlag)) return;
    try {
      final res = await _api.get('/friends');
      if (res is! Map) return;
      List<T> list<T>(Object? raw, T Function(Map) f) => raw is List ? raw.whereType<Map>().map(f).toList() : <T>[];
      _friends = list(res['friends'], FriendEntry.fromJson);
      _incoming = list(res['incoming'], FriendRequestEntry.fromJson);
      _outgoing = list(res['outgoing'], FriendRequestEntry.fromJson);
      _blocked = list(res['blocked'], (m) => m['username']?.toString() ?? '').where((s) => s.isNotEmpty).toList();
      _notify();
    } catch (e) {
      debugPrint('Friends not refreshed: $e');
    }
  }

  /// Live availability while typing: null = available, else the reason.
  Future<String?> checkAvailable(String username) async {
    final local = UsernameRules.check(username);
    if (!local.ok) return local.message;
    try {
      final res = await _api.get('/users/username-available?u=${Uri.encodeQueryComponent(username.trim())}');
      if (res is Map && res['available'] == true) return null;
      return res is Map ? (res['message']?.toString() ?? 'That username is taken.') : 'Could not check right now.';
    } on ApiException catch (e) {
      return e.message;
    }
  }

  /// PATCH /me/username. Returns null on success, else the message to show.
  Future<String?> changeUsername(String username) async {
    final local = UsernameRules.check(username);
    if (!local.ok) return local.message;
    try {
      await _api.patch('/me/username', {'username': username.trim()});
      await refreshProfile();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Future<String?> setPublicLeaderboard(bool on) async {
    try {
      await _api.patch('/me/privacy', {'publicLeaderboard': on});
      await refreshProfile();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  /// POST /me/avatar with already downsized bytes (JPEG/PNG/WebP).
  Future<String?> uploadAvatar(Uint8List bytes, String mime) async {
    if (bytes.length > 2 * 1024 * 1024) return 'This picture is too large (up to 2 MB).';
    try {
      await _api.postBytes('/me/avatar', bytes, mime);
      await refreshProfile();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Future<String?> removeAvatar() async {
    try {
      await _api.delete('/me/avatar');
      await refreshProfile();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  /// Add a friend by username or invite code. [byCode] null = guess from [input] (an 8-character
  /// all-capitals code is a code, anything else a username).
  Future<FriendRequestResult> sendRequest(String input, {bool? byCode}) async {
    final text = input.trim();
    if (text.isEmpty) return const FriendRequestResult(error: 'Enter a username or an invite code.');
    final code = InviteCodes.normalise(text);
    final asCode = byCode ?? (code != null && (text == text.toUpperCase() || !UsernameRules.pattern.hasMatch(text)));
    if (asCode && code == null) return const FriendRequestResult(error: 'An invite code has 8 letters and numbers.');
    final body = asCode ? {'inviteCode': code} : {'username': text};
    try {
      final res = await _api.post('/friends/requests', body);
      await refreshFriends();
      return FriendRequestResult(status: res is Map ? res['status']?.toString() : 'REQUESTED');
    } on ApiException catch (e) {
      return FriendRequestResult(error: e.message);
    }
  }

  Future<String?> respond(String requestId, bool accept) =>
      _act(() => _api.post('/friends/requests/${Uri.encodeComponent(requestId)}/${accept ? 'accept' : 'decline'}'));
  Future<String?> cancelRequest(String requestId) => _act(() => _api.delete('/friends/requests/${Uri.encodeComponent(requestId)}'));
  Future<String?> removeFriend(String username) => _act(() => _api.delete('/friends/${Uri.encodeComponent(username)}'));
  Future<String?> block(String username) => _act(() => _api.post('/blocks', {'username': username}));
  Future<String?> unblock(String username) => _act(() => _api.delete('/blocks/${Uri.encodeComponent(username)}'));

  Future<String?> _act(Future<dynamic> Function() call) async {
    try {
      await call();
      await refreshFriends();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  /// Another rider's profile, or null when not found (unknown, or they blocked me: same answer).
  Future<RiderProfile?> profileOf(String username) async {
    try {
      final res = await _api.get('/users/${Uri.encodeComponent(username)}/profile');
      return res is Map && res['profile'] is Map ? RiderProfile.fromJson(res['profile'] as Map) : null;
    } catch (_) {
      return null;
    }
  }

  /// Username + picture of the riders of [groupId] by userId (cached per ride; members only).
  Future<Map<String, ({String username, String? avatarUrl})>> usernamesOfGroup(String groupId) async {
    final cached = _groupNames[groupId];
    if (cached != null) return cached;
    try {
      final res = await _api.get('/convoys/${Uri.encodeComponent(groupId)}/usernames');
      final out = <String, ({String username, String? avatarUrl})>{};
      final riders = res is Map ? res['riders'] : null;
      if (riders is Map) {
        riders.forEach((k, v) {
          if (v is Map && (v['username']?.toString() ?? '').isNotEmpty) {
            out[k.toString()] = (username: v['username'].toString(), avatarUrl: _url(v['avatarUrl']));
          }
        });
      }
      _groupNames[groupId] = out;
      if (_groupNames.length > 20) _groupNames.remove(_groupNames.keys.first);
      return out;
    } catch (_) {
      return const {};
    }
  }

  // ---- invite links (https://<site>/join/friend/<CODE>) ----

  /// Remembers an invite opened from a link. Signed in: the request is sent now; otherwise it is
  /// sent with the registration (AuthService.registerRider reads it) or after the next sign-in.
  Future<void> handleInviteCode(String code) async {
    final c = InviteCodes.normalise(code);
    if (c == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingInviteKey, c);
    } catch (_) {}
    if (_api.hasToken) await consumePendingInvite();
  }

  /// The invite code waiting for registration, if any (read by AuthService.registerRider).
  static Future<String?> pendingInviteCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_pendingInviteKey);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearPendingInvite() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingInviteKey);
    } catch (_) {}
  }

  /// Sends the request for a remembered invite (signed in only), then forgets it.
  Future<void> consumePendingInvite() async {
    if (!_api.hasToken || !FeatureFlagsService.on(friendsFlag)) return;
    final code = await pendingInviteCode();
    if (code == null) return;
    await clearPendingInvite();
    final r = await sendRequest(code, byCode: true);
    if (r.ok) {
      _lastNotice = r.status == 'FRIENDS' ? 'You are now friends' : 'Friend request sent';
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _lifecycle?.dispose();
    _api.removeListener(_onApiChanged);
    super.dispose();
  }
}
