import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../../domain/notify/alert_policy.dart';
import '../models/timeline_event_model.dart';
import 'convoy_service.dart';
import 'timeline_service.dart';

/// Shows trip alerts as notifications, separate from the ongoing trip status.
///
/// Every 30 s and on every timeline change it asks [AlertPolicy] what should
/// be showing, posts what is new and removes what is no longer true. Alerts
/// are grouped per trip. While CoRoute is open on screen only SOS alerts are
/// posted (the rider is already looking at the timeline).
class AlertService with WidgetsBindingObserver {
  AlertService(this._convoys, this._timeline, {FlutterLocalNotificationsPlugin? plugin, AlertPolicy? policy})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _policy = policy ?? AlertPolicy() {
    _timeline.addListener(_onTimeline);
    _convoys.addListener(_onConvoy);
    WidgetsBinding.instance.addObserver(this);
  }

  final ConvoyService _convoys;
  final TimelineService _timeline;
  final FlutterLocalNotificationsPlugin _plugin;
  final AlertPolicy _policy;

  bool _ready = false;
  bool _foreground = true;
  String? _groupId;
  Timer? _tick;
  final Map<String, AlertSpec> _shown = {};
  final Set<String> _oneShotsSeen = {};
  int _lastEventCount = 0;

  static const _channels = {
    AlertChannel.sos: ('coroute_sos', 'SOS alerts', 'A rider in your convoy needs help.', Importance.max),
    AlertChannel.alerts: ('coroute_alerts', 'Group alerts', 'A rider stopped for long, fell behind or lost signal.', Importance.high),
    AlertChannel.updates: ('coroute_updates', 'Trip updates', 'Stops reached, destination reached, route suggestions.', Importance.defaultImportance),
    AlertChannel.activity: ('coroute_activity', 'Convoy activity', 'Riders joining and leaving, route changes.', Importance.low),
  };

  bool get _supported => !kIsWeb && Platform.isAndroid;

  Future<void> _init() async {
    if (_ready || !_supported) return;
    try {
      await _plugin.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      for (final (id, name, desc, importance) in _channels.values) {
        await android?.createNotificationChannel(AndroidNotificationChannel(id, name, description: desc, importance: importance));
      }
      _ready = true;
    } catch (e) {
      debugPrint('alerts init note: $e');
    }
  }

  void _onConvoy() {
    final gid = _convoys.activeGroupId;
    if (gid == _groupId) return;
    _groupId = gid;
    _oneShotsSeen.clear();
    _lastEventCount = 0;
    _clearAll();
    _tick?.cancel();
    if (gid != null) {
      _init().then((_) => _reconcile());
      _tick = Timer.periodic(const Duration(seconds: 30), (_) => _reconcile());
    }
  }

  void _onTimeline() => _reconcile();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _reconcile();
  }

  AlertViewer? _viewer() {
    final c = _convoys.activeConvoy;
    final uid = _convoys.myUserId;
    if (c == null || uid == null) return null;
    final me = c.riders[uid];
    final role = me?.role ?? 'PACK';
    return AlertViewer(
      userId: uid,
      isLead: c.createdByUserId == uid || role == 'LEAD',
      isSweeper: role == 'SWEEPER',
      lat: me?.lat,
      lng: me?.lng,
    );
  }

  void _reconcile() {
    if (!_ready || _groupId == null || _timeline.groupId != _groupId) return;
    final me = _viewer();
    if (me == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final events = _timeline.events;

    // Standing alerts: show new or changed, remove resolved.
    final want = {for (final a in _policy.standing(events, me, nowMs: now)) a.key: a};
    for (final key in _shown.keys.toList()) {
      if (!want.containsKey(key) && !key.startsWith('EV:')) {
        _plugin.cancel(_shown.remove(key)!.id).ignore();
      }
    }
    for (final a in want.values) {
      final quiet = _foreground && a.channel != AlertChannel.sos;
      if (quiet || _shown[a.key] == a) continue;
      _show(a, sticky: a.channel == AlertChannel.sos);
    }

    // One-time alerts: only for entries that arrived live and are recent.
    if (events.length != _lastEventCount) {
      final firstLoad = _lastEventCount == 0;
      _lastEventCount = events.length;
      for (final TimelineEventModel e in events) {
        if (!_oneShotsSeen.add(e.eventId)) continue;
        if (firstLoad || now - e.startedAt > const Duration(minutes: 2).inMilliseconds) continue;
        final a = _policy.oneShot(e, me);
        // Safety alerts (the alerts channel) show even while the app is open; the rest only in the background.
        if (a == null || (_foreground && !AlertPolicy.showWhileOpen(a))) continue;
        _show(a, timeout: const Duration(minutes: 10));
      }
    }
  }

  void _show(AlertSpec a, {bool sticky = false, Duration? timeout}) {
    final (channelId, channelName, desc, importance) = _channels[a.channel]!;
    final sos = a.channel == AlertChannel.sos;
    final details = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: desc,
      importance: importance,
      priority: sos ? Priority.max : (a.channel == AlertChannel.alerts ? Priority.high : Priority.defaultPriority),
      category: sos ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.status,
      visibility: NotificationVisibility.public, // names only; no coordinates are ever in the text
      groupKey: 'trip_${_groupId ?? ''}',
      onlyAlertOnce: !sos,
      ongoing: sticky,
      autoCancel: !sticky,
      timeoutAfter: timeout?.inMilliseconds,
      // SOS keeps sounding until someone looks at it.
      additionalFlags: sos ? Int32List.fromList(const [4]) : null, // FLAG_INSISTENT
      styleInformation: a.body.isEmpty ? null : BigTextStyleInformation(a.body),
    );
    _plugin.show(a.id, a.title, a.body.isEmpty ? null : a.body, NotificationDetails(android: details)).ignore();
    _shown[a.key] = a;
  }

  void _clearAll() {
    for (final a in _shown.values) {
      _plugin.cancel(a.id).ignore();
    }
    _shown.clear();
  }

  void dispose() {
    _tick?.cancel();
    _timeline.removeListener(_onTimeline);
    _convoys.removeListener(_onConvoy);
    WidgetsBinding.instance.removeObserver(this);
  }
}
