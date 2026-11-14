import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/media/avatar_crop.dart';
import '../../domain/notify/notice_dedupe.dart';
import '../../domain/social/friends_models.dart';
import '../../domain/social/people_models.dart';
import '../../domain/social/username_rules.dart';
import '../../domain/diag/diag_log.dart'; // 3.55 diagnostics log (no personal data)
import 'alarm_notifier.dart';
import 'api_client.dart';
import 'feature_flags_service.dart';
import 'realtime_service.dart';

export '../../domain/social/friends_models.dart';
export '../../domain/social/people_models.dart';

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

  /// 3.56 "Adjust picture": the gateway keeps the original, so the crop can be changed later.
  final bool avatarAdjustable;

  /// How the kept original is cropped now (null when there is none).
  final AvatarCrop? avatarCrop;

  /// Changes when another original is stored (the cached copy on this phone is then dropped).
  final String? avatarOriginalTag;

  /// v3.58 profile cover photo: `/api/covers/<id>` or null; [coverAdjustable] when its original is kept.
  final String? coverUrl;
  final bool coverAdjustable;
  final bool publicLeaderboard;

  /// "Let riders find me": found by username prefix and suggested to riders I rode with (default on).
  final bool discoverable;
  final int usernameChangedAt;
  final int memberSince;
  final String? inviteCode;
  final String? inviteLink;
  final String? shareText;
  const MyProfile({
    required this.username,
    this.name = '',
    this.avatarUrl,
    this.avatarAdjustable = false,
    this.avatarCrop,
    this.avatarOriginalTag,
    this.coverUrl,
    this.coverAdjustable = false,
    this.publicLeaderboard = true,
    this.discoverable = true,
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
        avatarAdjustable: raw['avatarAdjustable'] == true,
        avatarCrop: AvatarCrop.fromJson(raw['avatarCrop']),
        avatarOriginalTag: raw['avatarOriginalTag']?.toString(),
        coverUrl: coverPathOf(raw['coverUrl']),
        coverAdjustable: raw['coverAdjustable'] == true,
        publicLeaderboard: raw['publicLeaderboard'] != false,
        discoverable: raw['discoverable'] != false,
        usernameChangedAt: raw['usernameChangedAt'] is num ? (raw['usernameChangedAt'] as num).toInt() : 0,
        memberSince: raw['memberSince'] is num ? (raw['memberSince'] as num).toInt() : 0,
        inviteCode: raw['inviteCode']?.toString(),
        inviteLink: raw['inviteLink']?.toString(),
        shareText: raw['shareText']?.toString(),
      );

  /// When a new username may be chosen (null = now).
  DateTime? get nextUsernameChange => UsernameRules.nextChangeAt(usernameChangedAt);
}

String? _url(Object? v) => avatarPathOf(v);

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
  bool _listsLoaded = false;
  List<PersonCard> _suggestions = const [];
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

  /// GET /friends answered at least once since sign-in (search chips then follow the lists).
  bool get listsLoaded => _listsLoaded;

  /// "People you rode with" (GET /friends/suggestions), friends and requests filtered out live.
  List<PersonCard> get suggestions => [
        for (final p in _suggestions)
          if (relationOf(p.username, p.relation) case final r when r != PeopleRelation.friends && r != PeopleRelation.pendingIn) p.withRelation(r),
      ];

  /// The chip state for [username] now (search rows, suggestions, profiles).
  String relationOf(String username, String serverRelation) => liveRelation(
        username,
        serverRelation,
        friends: _friends.map((f) => f.username),
        incoming: _incoming.map((r) => r.username),
        outgoing: _outgoing.map((r) => r.username),
        listsLoaded: _listsLoaded,
      );

  /// Number shown on the Profile tab, the "My profile & friends" row and the Friends row
  /// (incoming requests waiting for an answer).
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
    _sub = _rt?.events.listen(onPush);
    _api.addListener(_onApiChanged);
    // A request sent while the socket was down is never re-sent: read the list again whenever the
    // socket (re)connects.
    _rtWasConnected = _rt?.isConnected ?? false;
    _rt?.addListener(_onRealtimeChanged);
    try {
      _lifecycle = AppLifecycleListener(onResume: () => refreshFriends());
    } catch (_) {
      // No binding (pure unit tests).
    }
    if (_api.hasToken) refreshAll();
  }

  bool _rtWasConnected = false;
  void _onRealtimeChanged() {
    final now = _rt?.isConnected ?? false;
    if (now && !_rtWasConnected) refreshFriends();
    _rtWasConnected = now;
  }

  /// A socket message: FRIEND_REQUEST / FRIEND_ACCEPTED (anything else is ignored).
  @visibleForTesting
  void onPush(Map<String, dynamic> msg) {
    final push = FriendPush.parse(msg);
    // Ids only (never the username): did the socket event reach the phone, and was it shown?
    DiagLog.info(DiagCat.social, 'friend_event', {'kind': msg['type'], 'requestId': push?.requestId, 'eventId': push?.eventId, 'parsed': push != null, 'switchOn': FeatureFlagsService.on(friendsFlag), 'foreground': _inForeground()});
    if (push == null || !FeatureFlagsService.on(friendsFlag)) return;
    // The request shows at once (badge, Requests card), before GET /friends answers.
    final row = push.asIncoming;
    if (row != null) _incoming = withRequest(_incoming, row);
    // 3.55 follow-up: the same event already shown (its push arrived first): no second notice.
    if (NoticeDedupe.shared.firstTime(push.eventId)) {
      // In the background a system notification; in the foreground FriendNoticeHost shows the
      // line as a snackbar (via takeNotice).
      if (!_inForeground()) {
        _lastNotice = null;
        systemNotice(push.isRequest ? 'Friend request' : 'New friend', push.line).ignore();
      } else {
        _lastNotice = push.line;
      }
    }
    _notify();
    refreshFriends();
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
    _originalBytes = null;
    _originalTag = null;
    _stats = const RideTotals();
    _score = null;
    _friends = const [];
    _incoming = const [];
    _outgoing = const [];
    _blocked = const [];
    _listsLoaded = false;
    _suggestions = const [];
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
    if (_disposed || !_api.hasToken || !FeatureFlagsService.on(friendsFlag)) {
      DiagLog.debug(DiagCat.social, 'friends_refresh_skipped', {'signedIn': _api.hasToken, 'switchOn': FeatureFlagsService.on(friendsFlag)});
      return;
    }
    try {
      final snap = FriendsSnapshot.parse(await _api.get('/friends'));
      if (snap == null) {
        DiagLog.warn(DiagCat.social, 'friends_unparsed');
        return;
      }
      DiagLog.info(DiagCat.social, 'friends_loaded', {'friends': snap.friends.length, 'incoming': snap.incoming.length, 'outgoing': snap.outgoing.length});
      _friends = snap.friends;
      _incoming = snap.incoming;
      _outgoing = snap.outgoing;
      _blocked = snap.blocked;
      _listsLoaded = true;
      _notify();
    } catch (e) {
      debugPrint('Friends not refreshed: $e');
      DiagLog.warn(DiagCat.social, 'friends_refresh_failed', {'type': e.runtimeType.toString(), 'status': e is ApiException ? e.statusCode : null});
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

  /// GET /users/search?q= (username prefix, 2+ characters, max 10). Throws on a network error so
  /// the search box can say so; [PeopleSearch] calls it after the debounce.
  Future<List<PersonCard>> searchUsers(String key) async {
    final res = await _api.get('/users/search?q=${Uri.encodeQueryComponent(key)}');
    return PersonCard.parseSearch(res);
  }

  /// GET /friends/suggestions ("People you rode with"). Keeps the last list on any error.
  Future<void> refreshSuggestions() async {
    if (_disposed || !_api.hasToken || !FeatureFlagsService.on(friendsFlag)) return;
    try {
      _suggestions = PersonCard.parseSuggestions(await _api.get('/friends/suggestions'));
      _notify();
    } catch (e) {
      debugPrint('Suggestions not refreshed: $e');
    }
  }

  /// "Let riders find me" (PATCH /me/privacy {discoverable}).
  Future<String?> setDiscoverable(bool on) async {
    try {
      await _api.patch('/me/privacy', {'discoverable': on});
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
    _originalBytes = null;
    _originalTag = null;
    try {
      await _api.postBytes('/me/avatar', bytes, mime);
      await refreshProfile();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  // ---- 3.56 "Adjust picture" (docs/features_355/profile_photo_adjust.md) ----
  Uint8List? _originalBytes;
  String? _originalTag;

  /// The picture to adjust: the kept original (from this phone's memory, else downloaded), or, for
  /// a picture uploaded before originals were kept, the current picture ([fromOriginal] false).
  /// Null when there is no picture or it could not be loaded.
  Future<({Uint8List bytes, AvatarCrop? crop, bool fromOriginal})?> adjustSource() async {
    final p = _profile;
    final url = p?.avatarUrl;
    if (p == null || url == null) return null;
    try {
      if (p.avatarAdjustable) {
        final cached = _originalBytes;
        if (cached != null && _originalTag != null && _originalTag == p.avatarOriginalTag) {
          return (bytes: cached, crop: p.avatarCrop, fromOriginal: true);
        }
        final bytes = await _api.getBytes('/me/avatar/original', timeout: const Duration(seconds: 30));
        _originalBytes = bytes;
        _originalTag = p.avatarOriginalTag;
        return (bytes: bytes, crop: p.avatarCrop, fromOriginal: true);
      }
      final bytes = await _api.getBytes(url.substring(4), timeout: const Duration(seconds: 30));
      return (bytes: bytes, crop: null, fromOriginal: false);
    } on ApiException catch (e) {
      debugPrint('Picture to adjust not loaded: ${e.statusCode}');
      return null;
    }
  }

  /// Saves an adjusted picture: [cropped] is the public square. With [original] (a new picture, or
  /// the first adjust of an older one) the original is stored first and then cropped; without it
  /// the kept original stays and only the crop changes. Returns null on success, else the message.
  Future<String?> saveAdjustedAvatar({
    required Uint8List cropped,
    required String croppedMime,
    required AvatarCrop crop,
    Uint8List? original,
    String? originalMime,
  }) async {
    if (cropped.length > 2 * 1024 * 1024) return 'This picture is too large (up to 2 MB).';
    try {
      var query = crop.toQuery();
      if (original != null) {
        if (original.length > 2 * 1024 * 1024) return 'This picture is too large (up to 2 MB).';
        final res = await _api.postBytes('/me/avatar/original', original, originalMime ?? 'image/jpeg');
        final id = res is Map ? res['originalId']?.toString() : null;
        if (id == null || id.isEmpty) return 'The picture could not be saved. Please try again.';
        query = '$query&original=${Uri.encodeQueryComponent(id)}';
      }
      await _api.postBytes('/me/avatar/crop?$query', cropped, croppedMime);
      await refreshProfile();
      if (original != null) {
        _originalBytes = original;
        _originalTag = _profile?.avatarOriginalTag;
      }
      return null;
    } on ApiException catch (e) {
      // A gateway from before 3.56 has no adjust routes: save the cropped picture the old way.
      if (e.statusCode == 404 && original != null) return uploadAvatar(cropped, croppedMime);
      return e.message;
    }
  }

  // ---- v3.58 cover photo (gateway src/covers.js: private original + public wide cover) ----

  /// Saves a new cover: [cover] is the wide public picture. With [original] the full picture is kept privately
  /// first (owner only), so the framing can be changed later. Returns null on success, else the message.
  Future<String?> saveCover({required Uint8List cover, required String coverMime, Uint8List? original, String? originalMime}) async {
    if (cover.length > 2 * 1024 * 1024) return 'This picture is too large (up to 2 MB).';
    try {
      var path = '/me/cover';
      if (original != null && original.length <= 2 * 1024 * 1024) {
        final res = await _api.postBytes('/me/cover/original', original, originalMime ?? 'image/jpeg');
        final id = res is Map ? res['originalId']?.toString() : null;
        if (id != null && id.isNotEmpty) path = '/me/cover?original=${Uri.encodeQueryComponent(id)}&cx=0.5&cy=0.5&zoom=1&rot=0';
      }
      await _api.postBytes(path, cover, coverMime);
      await refreshProfile();
      return null;
    } on ApiException catch (e) {
      if (e.statusCode == 404) return 'Cover photos need the latest CoRoute server. Try again later.';
      return e.message;
    }
  }

  Future<String?> removeCover() async {
    try {
      await _api.delete('/me/cover');
      await refreshProfile();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Future<String?> removeAvatar() async {
    _originalBytes = null;
    _originalTag = null;
    try {
      await _api.delete('/me/avatar');
      await refreshProfile();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  /// Add a friend by username or invite code. [byCode] null = guess from [input] (an 8-character
  /// all-capitals code is a code, anything else a username). A leading "@" is ignored.
  Future<FriendRequestResult> sendRequest(String input, {bool? byCode}) async {
    final text = usernameInput(input);
    if (text.isEmpty) return const FriendRequestResult(error: 'Enter a username or an invite code.');
    final code = InviteCodes.normalise(text);
    final asCode = byCode ?? (code != null && (text == text.toUpperCase() || !UsernameRules.pattern.hasMatch(text)));
    if (asCode && code == null) return const FriendRequestResult(error: 'An invite code has 8 letters and numbers.');
    final body = asCode ? {'inviteCode': code} : {'username': text};
    try {
      final out = FriendRequestResult.fromJson(await _api.post('/friends/requests', body));
      // Under "Sent" at once (GET /friends below confirms it).
      final sent = out.request;
      if (sent != null) {
        _outgoing = withRequest(_outgoing, sent);
        _notify();
      }
      await refreshFriends();
      return out;
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
      _lastNotice = r.confirmation;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _rt?.removeListener(_onRealtimeChanged);
    _lifecycle?.dispose();
    _api.removeListener(_onApiChanged);
    super.dispose();
  }
}
