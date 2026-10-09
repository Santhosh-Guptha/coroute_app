import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../../core/constants/network_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../domain/notify/alert_policy.dart';
import '../models/timeline_event_model.dart';
import 'alarm_notifier.dart';
import 'convoy_service.dart';
import 'timeline_service.dart';
import 'voice_service.dart';

/// Shows trip alerts as notifications, separate from the ongoing trip status.
///
/// Every 30 s and on every timeline change it asks [AlertPolicy] what should
/// be showing, posts what is new and removes what is no longer true. Alerts
/// are grouped per trip. While CoRoute is open on screen only SOS alerts are
/// posted (the rider is already looking at the timeline).
///
/// 3.15: also the safety network (assistance requests, accident warnings) and
/// discovery alerts from [ConvoyService], and each alert with a spoken line is
/// spoken once through [VoiceService] (foreground or background).
///
/// 3.16: spoken lines come in the voice's language ([VoiceService.speechLang]);
/// SOS lines are critical, group alerts (stopped, separated, no update, low battery,
/// behind the sweeper) and accident warnings are important (spoken after dark too
/// when "Speak more after dark" is on), the rest are warnings. A language change
/// re-words the alerts on screen; nothing is spoken again.
class AlertService with WidgetsBindingObserver {
  AlertService(this._convoys, this._timeline, {FlutterLocalNotificationsPlugin? plugin, AlertPolicy? policy, this._voice})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _policy = policy ?? AlertPolicy() {
    _timeline.addListener(_onTimeline);
    _convoys.addListener(_onConvoy);
    L10n.changes.addListener(_onLanguage);
    WidgetsBinding.instance.addObserver(this);
  }

  final ConvoyService _convoys;
  final TimelineService _timeline;
  final FlutterLocalNotificationsPlugin _plugin;
  final AlertPolicy _policy;
  final VoiceService? _voice;

  bool _ready = false;
  bool _foreground = true;
  String? _groupId;
  Timer? _tick;
  final Map<String, AlertSpec> _shown = {};
  final Set<String> _oneShotsSeen = {};
  int _lastEventCount = 0;
  final Set<String> _spoken = {};
  int _networkRevision = -1;
  bool? _groupVoice;

  static const _channels = {
    AlertChannel.sos: ('coroute_sos', 'SOS alerts', 'A rider in your convoy needs help.', Importance.max),
    AlertChannel.alerts: ('coroute_alerts', 'Group alerts', 'A rider stopped for long, fell behind or lost signal.', Importance.high),
    AlertChannel.updates: ('coroute_updates', 'Trip updates', 'Stops reached, destination reached, route suggestions.', Importance.defaultImportance),
    AlertChannel.activity: ('coroute_activity', 'Convoy activity', 'Riders joining and leaving, route changes.', Importance.low),
    AlertChannel.hazard: (NetworkConstants.channelHazard, 'Accident warnings', 'An accident was reported ahead on your route.', Importance.high),
    AlertChannel.social: (NetworkConstants.channelSocial, 'Riding groups nearby', 'Other public riding groups on your way.', Importance.low),
  };

  bool get _supported => !kIsWeb && Platform.isAndroid;

  Future<void> _init() async {
    if (_ready || !_supported) return;
    try {
      // One initialize() for the whole app, with the crash alarm's tap/action dispatcher:
      // initialising here again would replace that callback.
      if (!await AlarmNotifier.ensureInitialized(_plugin)) return;
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
    final groupVoice = _convoys.activeConvoy?.voiceGuidanceEnabled;
    if (groupVoice != null && groupVoice != _groupVoice) {
      _groupVoice = groupVoice;
      _voice?.setGroupVoice(groupVoice);
    }
    if (gid == _groupId) {
      // Network state changed (request, hazard, emergency update): show it now, not at the next tick.
      final rev = _convoys.networkRevision;
      if (rev != _networkRevision) {
        _networkRevision = rev;
        _reconcile();
      }
      return;
    }
    _groupId = gid;
    _oneShotsSeen.clear();
    _spoken.clear();
    _lastEventCount = 0;
    _networkRevision = _convoys.networkRevision;
    _clearAll();
    _tick?.cancel();
    if (gid != null) {
      _init().then((_) => _reconcile());
      _tick = Timer.periodic(const Duration(seconds: 30), (_) => _reconcile());
    }
  }

  void _onTimeline() => _reconcile();

  /// Language changed: the alerts on screen are re-worded (same keys, no new sound, no new speech).
  void _onLanguage() => _reconcile();

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
      route: c.routeLine,
    );
  }

  static bool _isNetworkKey(String k) =>
      k.startsWith(AlertPolicy.assistPrefix) || k.startsWith(AlertPolicy.assistTakenPrefix) || k.startsWith(AlertPolicy.hazardPrefix) || k.startsWith(AlertPolicy.encounterPrefix);

  void _reconcile() {
    if (_groupId == null) return;
    final me = _viewer();
    if (me == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final timelineReady = _timeline.groupId == _groupId;
    final events = timelineReady ? _timeline.events : const <TimelineEventModel>[];
    final alerts = _convoys.activeConvoy?.activeAlerts ?? const [];
    final speechLang = _voice?.speechLang ?? 'en';

    // Standing alerts: show new or changed, remove resolved.
    final want = <String, AlertSpec>{
      for (final a in _policy.standing(events, me, nowMs: now, alerts: alerts, speechLang: speechLang)) a.key: a,
      for (final a in _policy.network(
        assists: _convoys.assistRequests,
        notices: _convoys.assistNotices,
        hazards: _convoys.hazards,
        encounters: _convoys.encounters,
        me: me,
        nowMs: now,
        anyEmergency: alerts.any((a) => !a.resolved),
        speechLang: speechLang,
      ))
        a.key: a,
    };
    _speak(want.values); // also where notifications are not available
    if (!_ready) return;
    for (final key in _shown.keys.toList()) {
      // Timeline not loaded yet for this ride: keep its alerts until it is.
      if (!timelineReady && !_isNetworkKey(key)) continue;
      if (!want.containsKey(key) && !key.startsWith('EV:')) {
        _plugin.cancel(_shown.remove(key)!.id).ignore();
      }
    }
    for (final a in want.values) {
      final quiet = _foreground && a.channel != AlertChannel.sos;
      if (quiet || _shown[a.key] == a) continue;
      // Already showing (for example only the distance changed): update it without ringing again.
      _show(a, sticky: a.channel == AlertChannel.sos, update: _shown.containsKey(a.key));
    }

    // One-time alerts: only for entries that arrived live and are recent.
    if (timelineReady && events.length != _lastEventCount) {
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

  /// Speaks each alert's line once (critical ones interrupt; the voice service applies the settings).
  void _speak(Iterable<AlertSpec> specs) {
    final voice = _voice;
    if (voice == null) return;
    for (final a in specs) {
      final line = a.speech;
      if (line == null || line.isEmpty || !_spoken.add(a.key)) continue;
      voice.speak(line, priority: speechPriority(a), key: a.key).ignore();
    }
  }

  /// SOS channel: critical. Group alerts and accident warnings (the important tier, spoken
  /// after dark too): important. Anything else: warning.
  static VoicePriority speechPriority(AlertSpec a) => switch (a.channel) {
        AlertChannel.sos => VoicePriority.critical,
        AlertChannel.alerts || AlertChannel.hazard => VoicePriority.important,
        AlertChannel.updates || AlertChannel.activity || AlertChannel.social => VoicePriority.warning,
      };

  void _show(AlertSpec a, {bool sticky = false, Duration? timeout, bool update = false}) {
    final (channelId, channelName, desc, importance) = _channels[a.channel]!;
    final sos = a.channel == AlertChannel.sos;
    final social = a.channel == AlertChannel.social;
    final details = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: desc,
      importance: importance,
      priority: sos ? Priority.max : ((a.channel == AlertChannel.alerts || a.channel == AlertChannel.hazard) ? Priority.high : (social ? Priority.low : Priority.defaultPriority)),
      playSound: !social,
      enableVibration: !social,
      category: sos ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.status,
      visibility: NotificationVisibility.public, // names only; no coordinates are ever in the text
      groupKey: 'trip_${_groupId ?? ''}',
      onlyAlertOnce: !sos || update,
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
    L10n.changes.removeListener(_onLanguage);
    _timeline.removeListener(_onTimeline);
    _convoys.removeListener(_onConvoy);
    WidgetsBinding.instance.removeObserver(this);
  }
}
