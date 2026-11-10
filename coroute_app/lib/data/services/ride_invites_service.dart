import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/notify/notice_dedupe.dart';
import '../../domain/social/ride_invite_rules.dart';
import '../../domain/diag/diag_log.dart'; // 3.55 diagnostics log (no personal data)
import 'api_client.dart';
import 'feature_flags_service.dart';
import 'realtime_service.dart';

/// One crew member's invite as the host sees it (GET /crews/:id/ride-invites).
@immutable
class SentRideInvite {
  final String inviteId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String status;
  const SentRideInvite({required this.inviteId, required this.username, this.displayName = '', this.avatarUrl, this.status = RideInviteStatus.pending});
  factory SentRideInvite.fromJson(Map m) {
    final a = m['avatarUrl']?.toString() ?? '';
    return SentRideInvite(
      inviteId: m['inviteId']?.toString() ?? '',
      username: m['username']?.toString() ?? '',
      displayName: m['displayName']?.toString() ?? '',
      avatarUrl: a.startsWith('/api/avatars/') ? a : null,
      status: m['status']?.toString() ?? RideInviteStatus.pending,
    );
  }
}

/// Result of sending ride invites: per-name results and the host's status list.
@immutable
class RideInviteSendResult {
  final List<(String, String)> results; // (username, result code)
  final List<SentRideInvite> invites;
  final String? error;
  const RideInviteSendResult({this.results = const [], this.invites = const [], this.error});
  int get invited => results.where((r) => r.$2 == 'INVITED').length;
}

/// 3.55 "Start a ride with this crew": my ride invitations (GET /me/ride-invites), the socket pushes
/// RIDE_INVITE (to me) and RIDE_INVITE_UPDATE (accepted / declined, to the host), and the host's
/// calls. When the app opens or comes back, [autoShow] tells the host widget which open invites to
/// show by themselves (once per invite; the ids shown are kept on the phone). Switch `crewRides`.
class RideInvitesService extends ChangeNotifier {
  RideInvitesService(this._api, {RealtimeService? realtime, bool autoStart = true}) : _rt = realtime {
    if (autoStart) start();
  }

  static const String flag = 'crewRides';
  static const String _shownKey = 'coroute_ride_invites_shown_v1';

  final ApiClient _api;
  final RealtimeService? _rt;
  StreamSubscription<Map<String, dynamic>>? _sub;
  AppLifecycleListener? _lifecycle;
  bool _started = false;
  bool _disposed = false;
  bool _hadToken = false;

  List<RideInvite> _pending = const [];
  Set<String> _shown = {};
  bool _shownLoaded = false;
  final StreamController<RideInvite> _arrived = StreamController<RideInvite>.broadcast();
  final StreamController<(String, String)> _answers = StreamController<(String, String)>.broadcast();

  /// My open invitations, newest first.
  List<RideInvite> get pending => _pending;

  /// A RIDE_INVITE that came in on the socket while the app is open (for the in-app banner).
  Stream<RideInvite> get arrived => _arrived.stream;

  /// (username, status) when a rider I invited accepted or declined (RIDE_INVITE_UPDATE).
  Stream<(String, String)> get answers => _answers.stream;

  /// Bumps when the open invites were re-read (the host widget checks [autoShow] then).
  int _checks = 0;
  int get checks => _checks;

  bool get enabled => FeatureFlagsService.on('crews') && FeatureFlagsService.on(flag);

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

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _lifecycle?.dispose();
    _api.removeListener(_onApiChanged);
    _arrived.close();
    _answers.close();
    super.dispose();
  }

  void _onApiChanged() {
    final has = _api.hasToken;
    if (has && !_hadToken) refresh();
    if (!has && _hadToken) {
      _pending = const [];
      _notify();
    }
    _hadToken = has;
  }

  void _onPush(Map<String, dynamic> msg) {
    final type = msg['type']?.toString();
    if (type == 'RIDE_INVITE' || type == 'RIDE_INVITE_UPDATE') {
      DiagLog.info(DiagCat.social, 'ride_invite_event', {'kind': type, 'inviteId': msg['inviteId']?.toString(), 'eventId': msg['eventId']?.toString()});
    }
    if (type == 'RIDE_INVITE') {
      final id = msg['inviteId']?.toString() ?? '';
      if (id.isEmpty) return;
      final inv = RideInvite(
        inviteId: id,
        hostUsername: msg['username']?.toString() ?? '',
        crewName: msg['crewName']?.toString() ?? '',
        rideName: msg['rideName']?.toString() ?? '',
        expiresAt: msg['expiresAt'] is num ? (msg['expiresAt'] as num).toInt() : 0,
      );
      // The banner offers it now: not shown again by itself on the next resume.
      markShown(id);
      // 3.55 follow-up: one banner per invite even when its push arrived too (same eventId).
      if (!_arrived.isClosed && NoticeDedupe.shared.firstTime(msg['eventId'] ?? 'RIDE_INVITE:$id')) _arrived.add(inv);
      refresh(autoCheck: false);
    } else if (type == 'RIDE_INVITE_UPDATE') {
      final status = msg['status']?.toString() ?? '';
      final who = msg['username']?.toString() ?? '';
      if ((status == RideInviteStatus.accepted || status == RideInviteStatus.declined) && !_answers.isClosed) _answers.add((who, status));
      if (status == RideInviteStatus.cancelled) {
        _pending = _pending.where((i) => i.inviteId != msg['inviteId']?.toString()).toList();
        _notify();
      }
    }
  }

  Future<void> _loadShown() async {
    if (_shownLoaded) return;
    _shownLoaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      _shown = (sp.getStringList(_shownKey) ?? const []).toSet();
    } catch (_) {}
  }

  /// Remembers that [inviteId] was shown (it is not opened by itself again).
  Future<void> markShown(String inviteId) async {
    await _loadShown();
    if (!_shown.add(inviteId)) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final list = _shown.toList();
      await sp.setStringList(_shownKey, list.length > 200 ? list.sublist(list.length - 200) : list);
    } catch (_) {}
  }

  /// What to open by itself now (and marks those invites shown).
  Future<(RideInviteAutoShow, List<RideInvite>)> takeAutoShow() async {
    await _loadShown();
    final now = DateTime.now().millisecondsSinceEpoch;
    final mode = RideInviteRules.autoShow(_pending, _shown, now);
    final list = RideInviteRules.unseen(_pending, _shown, now);
    for (final i in list) {
      await markShown(i.inviteId);
    }
    return (mode, list);
  }

  /// GET /me/ride-invites.
  Future<void> refresh({bool autoCheck = true}) async {
    if (_disposed || !_api.hasToken || !enabled) return;
    try {
      final res = await _api.get('/me/ride-invites');
      if (res is! Map) return;
      final raw = res['invites'];
      _pending = raw is List ? raw.whereType<Map>().map(RideInvite.fromJson).toList() : const [];
      if (autoCheck) _checks++;
      _notify();
    } catch (e) {
      debugPrint('Ride invites not refreshed: $e');
    }
  }

  /// GET /ride-invites/:id. Throws ApiException (404 when it is not mine).
  Future<RideInvite> invite(String inviteId) async {
    final res = await _api.get('/ride-invites/${Uri.encodeComponent(inviteId)}');
    final m = res is Map && res['invite'] is Map ? res['invite'] as Map : const {};
    return RideInvite.fromJson(m);
  }

  /// POST /ride-invites/:id/decline. Null on success, else the gateway's message.
  Future<String?> decline(String inviteId) async {
    try {
      await _api.post('/ride-invites/${Uri.encodeComponent(inviteId)}/decline');
      _pending = _pending.where((i) => i.inviteId != inviteId).toList();
      _notify();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not reach CoRoute. Try again.';
    }
  }

  /// After a successful accept (ConvoyService.joinFromRideInvite): drop it from the list.
  void accepted(String inviteId) {
    _pending = _pending.where((i) => i.inviteId != inviteId).toList();
    _notify();
  }

  // ---- host ----
  (String, String, int)? _pendingCrewRide;

  /// "Start a ride" on a crew without a live ride: remembered while the rider creates the ride, so
  /// the crew member picker opens once it is live (RideInviteHost). Forgotten after 30 minutes.
  void setPendingCrewRide(String crewId, String crewName) => _pendingCrewRide = (crewId, crewName, DateTime.now().millisecondsSinceEpoch);

  /// (crewId, crewName) once, or null.
  (String, String)? takePendingCrewRide() {
    final p = _pendingCrewRide;
    _pendingCrewRide = null;
    if (p == null || DateTime.now().millisecondsSinceEpoch - p.$3 > 30 * 60000) return null;
    return (p.$1, p.$2);
  }

  String _crew(String crewId) => '/crews/${Uri.encodeComponent(crewId)}/ride-invites';

  /// POST /crews/:crewId/ride-invites {groupId, usernames}.
  Future<RideInviteSendResult> send(String crewId, String groupId, List<String> usernames) async {
    try {
      final res = await _api.post(_crew(crewId), {'groupId': groupId, 'usernames': usernames});
      final m = res is Map ? res : const {};
      final results = m['results'] is List
          ? [for (final r in (m['results'] as List).whereType<Map>()) (r['username']?.toString() ?? '', r['status']?.toString() ?? '')]
          : const <(String, String)>[];
      final invites = m['invites'] is List ? (m['invites'] as List).whereType<Map>().map(SentRideInvite.fromJson).toList() : const <SentRideInvite>[];
      return RideInviteSendResult(results: results, invites: invites);
    } on ApiException catch (e) {
      return RideInviteSendResult(error: e.message);
    } catch (_) {
      return const RideInviteSendResult(error: 'Could not reach CoRoute. Try again.');
    }
  }

  /// GET /crews/:crewId/ride-invites?groupId= (the host's statuses). Empty on any error.
  Future<List<SentRideInvite>> sent(String crewId, String groupId) async {
    try {
      final res = await _api.get('${_crew(crewId)}?groupId=${Uri.encodeQueryComponent(groupId)}');
      final raw = res is Map ? res['invites'] : null;
      return raw is List ? raw.whereType<Map>().map(SentRideInvite.fromJson).toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  /// DELETE /crews/:crewId/ride-invites/:inviteId.
  Future<String?> cancel(String crewId, String inviteId) async {
    try {
      await _api.delete('${_crew(crewId)}/${Uri.encodeComponent(inviteId)}');
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not reach CoRoute. Try again.';
    }
  }
}
