import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/timeline_event_model.dart';
import 'api_client.dart';
import 'realtime_service.dart';

/// The shared group timeline of the active convoy: who did what, where, when
/// and for how long. Loaded once over REST, then kept current by
/// TIMELINE / TIMELINE_UPDATE pushes; after a reconnect it asks only for what
/// changed (TIMELINE_SINCE).
class TimelineService extends ChangeNotifier {
  TimelineService(this._api, this._rt) {
    _sub = _rt.events.listen(_onEvent);
    _rt.addListener(_onConnection);
  }

  final ApiClient _api;
  final RealtimeService _rt;
  StreamSubscription<Map<String, dynamic>>? _sub;

  String? _groupId;
  final Map<String, TimelineEventModel> _byId = {};
  List<TimelineEventModel>? _sorted;
  int _lastUpdatedAt = 0;
  bool _loading = false;
  bool _wasConnected = false;
  String? _error;

  String? get groupId => _groupId;
  bool get isLoading => _loading;
  String? get error => _error;

  /// All entries, oldest first.
  List<TimelineEventModel> get events => _sorted ??= (_byId.values.toList()..sort(_order));

  static int _order(TimelineEventModel a, TimelineEventModel b) {
    final c = a.startedAt.compareTo(b.startedAt);
    return c != 0 ? c : a.eventId.compareTo(b.eventId);
  }

  /// Entries filtered by member and/or type. Empty sets mean "all".
  List<TimelineEventModel> filtered({Set<String> userIds = const {}, Set<String> types = const {}}) => events
      .where((e) => (userIds.isEmpty || (e.userId != null && userIds.contains(e.userId))) && (types.isEmpty || types.contains(e.type)))
      .toList();

  /// The open entry of [type] for [userId] (for example a stop in progress).
  TimelineEventModel? openFor(String userId, String type) {
    for (final e in _byId.values) {
      if (e.open && e.userId == userId && e.type == type) return e;
    }
    return null;
  }

  /// Starts following [groupId] (the active convoy, or a past trip to review).
  Future<void> attach(String groupId) async {
    if (_groupId == groupId && _byId.isNotEmpty) return;
    _groupId = groupId;
    _byId.clear();
    _sorted = null;
    _lastUpdatedAt = 0;
    notifyListeners();
    await reload();
  }

  void detach() {
    _groupId = null;
    _byId.clear();
    _sorted = null;
    _lastUpdatedAt = 0;
    notifyListeners();
  }

  Future<void> reload() async {
    final gid = _groupId;
    if (gid == null) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final res = await _api.get('/convoys/$gid/timeline');
      if (_groupId != gid) return;
      final list = res is Map ? res['events'] : null;
      if (list is List) {
        // The server's list is complete: start from it, so entries the report
        // replaced or removed (live stops that were only GPS drift) disappear.
        _byId.clear();
        _lastUpdatedAt = 0;
        _applyAll(list);
      }
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not load the timeline.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void _onConnection() {
    final now = _rt.isConnected;
    if (now && !_wasConnected && _groupId != null && _groupId == _rt.groupId) {
      // Catch up on what happened while this phone was offline.
      _rt.send({'type': 'TIMELINE_SINCE', 'since': _lastUpdatedAt});
    }
    _wasConnected = now;
  }

  void _onEvent(Map<String, dynamic> msg) {
    final type = msg['type']?.toString();
    if (type == 'TIMELINE' || type == 'TIMELINE_UPDATE') {
      final ev = msg['event'];
      if (ev is Map && _apply(Map<String, dynamic>.from(ev))) {
        _sorted = null;
        notifyListeners();
      }
    } else if (type == 'TIMELINE_BATCH') {
      final list = msg['events'];
      if (list is List) _applyAll(list);
      notifyListeners();
    } else if (type == 'REPORT_READY' && msg['groupId'] == _groupId) {
      reload().ignore(); // exact stops and moving stretches replace the live ones
    }
  }

  void _applyAll(List list) {
    for (final raw in list) {
      if (raw is Map) _apply(Map<String, dynamic>.from(raw));
    }
    _sorted = null;
  }

  /// Returns true when the entry belongs to the followed convoy and was stored.
  bool _apply(Map<String, dynamic> raw) {
    final e = TimelineEventModel.fromJson(raw);
    if (e.eventId.isEmpty || e.groupId != _groupId) return false;
    final prev = _byId[e.eventId];
    if (prev != null && prev.updatedAt > e.updatedAt) return false;
    _byId[e.eventId] = e;
    if (e.updatedAt > _lastUpdatedAt) _lastUpdatedAt = e.updatedAt;
    // The report replaces live stops with exact ones under new ids: drop the superseded live entry.
    if (e.confidence == 'confirmed' && e.type == 'STOPPED') {
      _byId.removeWhere((id, x) => id != e.eventId && x.type == 'STOPPED' && x.userId == e.userId && x.confidence == 'live' &&
          x.startedAt <= (e.endedAt ?? e.startedAt) && (x.endedAt ?? x.startedAt) >= e.startedAt);
    }
    return true;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _rt.removeListener(_onConnection);
    super.dispose();
  }
}
