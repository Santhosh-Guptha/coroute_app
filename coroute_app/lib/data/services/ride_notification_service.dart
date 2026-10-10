import 'dart:convert';
import '../../domain/notify/fuel_notification.dart';
import 'ride_essentials_coordinator.dart';
import 'safety_service.dart';
import '../../domain/tracking/ride_power_policy.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/constants/ride_notification_constants.dart';
import '../../domain/notify/notification_snapshot.dart';
import '../models/convoy_model.dart';
import '../models/network_models.dart';
import '../models/network_wire.dart';
import '../models/timeline_event_model.dart';
import 'background_service.dart';
import 'convoy_service.dart';
import 'settings_service.dart';
import 'timeline_service.dart';

/// A button of the big ride notification, as the app sees it.
enum RideNotifActionKind { sos, wait, openMap, navigateEmergency, assistAccept, openFuel, viewGroup, viewFuel }

class RideNotifAction {
  final RideNotifActionKind kind;

  /// alertId or incidentId for [RideNotifActionKind.navigateEmergency] and [RideNotifActionKind.assistAccept].
  final String? ref;
  const RideNotifAction(this.kind, [this.ref]);

  /// From the native `{action, ref}` map; null for anything unknown.
  static RideNotifAction? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final ref = raw['ref']?.toString();
    final r = (ref == null || ref.isEmpty) ? null : ref;
    switch (raw['action']?.toString()) {
      case 'FUEL':
        return RideNotifAction(RideNotifActionKind.openFuel, r);
      case 'VIEW_GROUP':
        return const RideNotifAction(RideNotifActionKind.viewGroup);
      case 'VIEW_FUEL':
        return const RideNotifAction(RideNotifActionKind.viewFuel);
      case NotifConstants.actionSos:
        return const RideNotifAction(RideNotifActionKind.sos);
      case NotifConstants.actionWait:
        return const RideNotifAction(RideNotifActionKind.wait);
      case NotifConstants.actionMap:
        return const RideNotifAction(RideNotifActionKind.openMap);
      case NotifConstants.actionNavEmergency:
        return RideNotifAction(RideNotifActionKind.navigateEmergency, r);
      case NotifConstants.actionAssistAccept:
        return r == null ? null : RideNotifAction(RideNotifActionKind.assistAccept, r);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) => other is RideNotifAction && other.kind == kind && other.ref == ref;

  @override
  int get hashCode => Object.hash(kind, ref);

  @override
  String toString() => 'RideNotifAction($kind, $ref)';
}

/// MethodChannel `coroute/ride_notification` (RideNotification.kt). Replaceable in tests.
class RideNotificationChannel {
  RideNotificationChannel({MethodChannel? channel}) : _ch = channel ?? const MethodChannel(NotifConstants.notifChannel);

  final MethodChannel _ch;
  final StreamController<RideNotifAction> _actions = StreamController<RideNotifAction>.broadcast();
  bool _listening = false;

  /// Posts the big notification (same id and channel as the service). False when the
  /// phone cannot (old Android, notifications blocked, service not running, layout error).
  /// Throws MissingPluginException off Android.
  Future<bool> show(Map<String, Object?> args) async => (await _ch.invokeMethod<bool>('show', args)) == true;

  /// Android 7 or newer (custom notification layouts with the system frame).
  Future<bool> supported() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return (await _ch.invokeMethod<bool>('supported')) == true;
    } catch (_) {
      return false;
    }
  }

  /// The button that started the app before Dart was listening, once.
  Future<Map<String, Object?>?> takeLaunchAction() async {
    try {
      final r = await _ch.invokeMethod<Object?>('takeLaunchAction');
      return r is Map ? r.map((k, v) => MapEntry(k.toString(), v)) : null;
    } catch (_) {
      return null;
    }
  }

  /// Posts the last big notification again when the plugin replaced it. True when it shows.
  Future<bool> ensure() async {
    try {
      return (await _ch.invokeMethod<bool>('ensure')) == true;
    } catch (_) {
      return false;
    }
  }

  /// Button presses forwarded by the native side (`onAction {action, ref}`).
  Stream<RideNotifAction> get actions {
    if (!_listening) {
      _listening = true;
      _ch.setMethodCallHandler((call) async {
        if (call.method != 'onAction') return null;
        final a = RideNotifAction.fromMap(call.arguments);
        if (a != null) _actions.add(a);
        return true;
      });
    }
    return _actions.stream;
  }

  void dispose() {
    if (_listening) _ch.setMethodCallHandler(null);
    _actions.close();
  }
}

/// The narrow view of ConvoyService this service needs (a fake in tests).
abstract class RideNotifPort implements Listenable {
  ConvoyModel? get activeConvoy;
  String? get myUserId;
  List<AssistRequest> get assistRequests;
  List<HazardWarning> get hazards;
  void openSosFromNotification();
  void requestWaitFromNotification();
  bool answerAssist(String incidentId, AssistAnswer answer);
}

class ConvoyRideNotifPort implements RideNotifPort {
  ConvoyRideNotifPort(this._c);
  final ConvoyService _c;

  @override
  void addListener(VoidCallback listener) => _c.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => _c.removeListener(listener);
  @override
  ConvoyModel? get activeConvoy => _c.activeConvoy;
  @override
  String? get myUserId => _c.myUserId;
  @override
  List<AssistRequest> get assistRequests => _c.assistRequests;
  @override
  List<HazardWarning> get hazards => _c.hazards;
  @override
  void openSosFromNotification() => _c.openSosFromNotification();
  @override
  void requestWaitFromNotification() => _c.requestWaitFromNotification();
  @override
  bool answerAssist(String incidentId, AssistAnswer answer) => _c.answerAssist(incidentId, answer);
}

/// The big, sticky ride notification on the home and lock screen.
///
/// During a ride it replaces the foreground service's plain notification in
/// place (same id, same channel) with a native layout: destination, remaining
/// distance and ETA, the nearest riders ahead and behind, the group status,
/// and large buttons (SOS, Wait for me, Open map, and Navigate / I Can Help
/// during an emergency).
///
/// Battery: no GPS, no network, no polling. It listens to ConvoyService and
/// the timeline (data already in memory), arms one one-shot timer per change
/// burst, and pushes at most once per [NotifConstants.minInterval], only when
/// the visible content changed. A change of mode or emergency state is pushed
/// at once. Anything that fails falls back to the plain notification.
class RideNotificationService {
  RideNotificationService(
    ConvoyService convoys,
    TimelineService timeline,
    SettingsService settings, {
    RideNotificationChannel? channel,
    int Function()? clock,
    MedicalId? Function()? medicalId,
    RideEssentialsCoordinator? essentials,
    SafetyService? safety,
  }) : this.forPort(
          ConvoyRideNotifPort(convoys),
          settings,
          timeline: timeline,
          timelineEvents: () => timeline.events,
          channel: channel,
          clock: clock,
          medicalId: medicalId,
          essentials: essentials,
          safety: safety,
        );

  /// For tests: any port, any timeline source. [medicalId] (3.16) returns the rider's
  /// medical ID for the lock screen during their own SOS, or null (setting off).
  RideNotificationService.forPort(
    this._port,
    this._settings, {
    this._timeline,
    List<TimelineEventModel> Function()? timelineEvents,
    RideNotificationChannel? channel,
    int Function()? clock,
    this._clockText,
    MedicalId? Function()? medicalId,
    this.essentials,
    this.safety,
  })  : _events = timelineEvents ?? (() => const <TimelineEventModel>[]),
        _channel = channel ?? RideNotificationChannel(),
        _clock = clock ?? _wallClock,
        _medicalId = medicalId ?? _noMedicalId {
    essentials?.addListener(_onChange);
    safety?.addListener(_onChange);
    _port.addListener(_onChange);
    _timeline?.addListener(_onChange);
    _settings.addListener(_onChange);
    BackgroundService.onServiceStarted = _onServiceStarted;
    _actionSub = _channel.actions.listen(_onAction);
    _channel.takeLaunchAction().then((m) {
      if (_disposed) return;
      final a = RideNotifAction.fromMap(m);
      if (a != null) _onAction(a);
    }).ignore();
    _onChange();
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;
  static MedicalId? _noMedicalId() => null;

  final RideEssentialsCoordinator? essentials;
  final SafetyService? safety;
  bool _fuelView = false;
  final String _actionSession = DateTime.now().microsecondsSinceEpoch.toString();
  String get _fuelRef => jsonEncode([_actionSession, _port.myUserId, _port.activeConvoy?.groupId, essentials?.guide.routeVersion]);
  final RideNotifPort _port;
  final SettingsService _settings;
  final Listenable? _timeline;
  final List<TimelineEventModel> Function() _events;
  final RideNotificationChannel _channel;
  final int Function() _clock;
  final String? Function(int ms)? _clockText;
  final MedicalId? Function() _medicalId;
  StreamSubscription<RideNotifAction>? _actionSub;

  final ValueNotifier<RideNotifAction?> _pending = ValueNotifier<RideNotifAction?>(null);

  Timer? _freshnessTimer;
  Timer? _timer;
  Timer? _recheck;
  bool _disposed = false;
  bool _richActive = false;
  bool _inFlight = false;
  bool _dirty = false;
  bool _forceNext = false;
  bool _gaveUp = false;
  bool? _supported;
  int _failures = 0;
  final RidePowerPolicy _power = RidePowerPolicy();
  int _lastPushMs = -1 << 40;
  int _lastEnsureMs = -1 << 40;
  String? _lastKey;
  String? _lastQuick;
  String? _rideGroup;

  /// sos, openMap, navigateEmergency: the home screen opens the right view and calls [clearUiAction].
  ValueListenable<RideNotifAction?> get pendingUiAction => _pending;

  void clearUiAction() => _pending.value = null;

  /// The big notification is showing (the plain one is not updated meanwhile).
  bool get richActive => _richActive;

  @visibleForTesting
  int get failures => _failures;

  @visibleForTesting
  bool get gaveUp => _gaveUp;

  // ------------------------------------------------------------ state

  bool get _rideActive {
    final c = _port.activeConvoy;
    return c != null && _port.myUserId != null && c.tripStatus != 'ENDED';
  }

  NotifQuickState? _quick() {
    final c = _port.activeConvoy;
    final uid = _port.myUserId;
    if (c == null || uid == null) return null;
    return NotificationSnapshotBuilder.quickState(convoy: c, myUserId: uid, assists: _port.assistRequests, hazards: _port.hazards);
  }

  static String _quickKey(NotifQuickState q) => '${q.mode.wire}|${q.tone.wire}|${q.key}';

  void _onChange() {
    if (_disposed) return;
    if (!_rideActive) {
      _endRide();
      return;
    }
    final gid = _port.activeConvoy!.groupId;
    if (gid != _rideGroup) _startRide(gid);
    if (!_settings.richNotification || _gaveUp || _supported == false) {
      _deactivate();
      return;
    }
    final q = _quick();
    if (q == null) return;
    if (_quickKey(q) != _lastQuick) {
      // New mode, tone or emergency state: shown at once (emergency first).
      _pushNow();
      return;
    }
    _schedule();
  }

  void _startRide(String gid) {
    _rideGroup = gid;
    _fuelView = false;
    _failures = 0;
    _gaveUp = false;
    _lastKey = null;
    _lastQuick = null;
    _lastPushMs = -1 << 40;
  }

  void _endRide() {
    _freshnessTimer?.cancel();
    _timer?.cancel();
    _timer = null;
    _recheck?.cancel();
    _recheck = null;
    _dirty = false;
    _forceNext = false;
    if (_rideGroup == null && !_richActive) return;
    _rideGroup = null;
    _lastKey = null;
    _lastQuick = null;
    _failures = 0;
    _gaveUp = false;
    _setRich(false);
  }

  /// Rich notification switched off or given up: the plain one comes back.
  void _deactivate() {
    _freshnessTimer?.cancel();
    _timer?.cancel();
    _timer = null;
    _dirty = false;
    _lastKey = null;
    _lastQuick = null;
    _setRich(false);
  }

  void _setRich(bool value) {
    if (_richActive == value) return;
    _richActive = value;
    BackgroundService.setRichActive(value).ignore();
  }

  // ------------------------------------------------------------ pushing

  void _pushNow({bool force = false}) {
    _timer?.cancel();
    _timer = null;
    if (force) _forceNext = true;
    _dirty = true;
    _push().ignore();
  }

  Duration get _normalRefreshInterval {
    final c = _port.activeConvoy;
    final me = c?.riders[_port.myUserId];
    if (me != null) _power.updateBattery(me.batteryLevel, charging: me.isCharging);
    return _power.notificationInterval(critical: c?.activeAlerts.isNotEmpty == true || _port.assistRequests.isNotEmpty || _port.hazards.isNotEmpty);
  }

  void _schedule() {
    _dirty = true;
    if (_timer != null || _inFlight) return;
    final wait = _lastPushMs + _normalRefreshInterval.inMilliseconds - _clock();
    if (wait <= 0) {
      _push().ignore();
      return;
    }
    _timer = Timer(Duration(milliseconds: wait), () {
      _timer = null;
      if (_dirty) _push().ignore();
    });
  }

  Future<void> _push() async {
    if (_inFlight) {
      _dirty = true;
      return;
    }
    _inFlight = true;
    try {
      await _pushInner();
    } finally {
      _inFlight = false;
    }
    if (_disposed) return;
    if (_dirty && _rideActive && !_gaveUp && _settings.richNotification) {
      final q = _quick();
      if (q != null && _quickKey(q) != _lastQuick) {
        _pushNow();
      } else {
        _schedule();
      }
    }
  }

  Future<void> _pushInner() async {
    _dirty = false;
    final force = _forceNext;
    _forceNext = false;
    if (!_rideActive || !_settings.richNotification || _gaveUp) return;
    final ok = _supported ??= await _channel.supported();
    if (_disposed) return;
    if (!ok) {
      _giveUp();
      return;
    }
    final convoy = _port.activeConvoy;
    final uid = _port.myUserId;
    if (convoy == null || uid == null || convoy.tripStatus == 'ENDED') return;
    final now = _clock();
    _armFreshness(convoy, now);
    final snap = NotificationSnapshotBuilder.build(
      convoy: convoy,
      myUserId: uid,
      timelineEvents: _events(),
      assists: _port.assistRequests,
      hazards: _port.hazards,
      nowMs: now,
      lockScreenPublic: _settings.rideOnLockScreen,
      clockText: _clockText,
      medicalId: _medicalId(),
    );
    final quick = _quickKey(NotificationSnapshotBuilder.quickState(convoy: convoy, myUserId: uid, assists: _port.assistRequests, hazards: _port.hazards));
    final args = snap.toChannelArgs();
    final shared = essentials;
    if (snap.mode == NotifMode.ride && shared != null) {
      final fuel = FuelNotification.build(snapshot: shared.essentials.snapshot,
        progressM: shared.essentials.progressM, usableKm: safety?.estimatedUsableKm,
        uncertain: safety?.fuelEstimateUncertain ?? true, online: !shared.essentials.offline,
        currentPosition: shared.hasCurrentPosition, now: now);
      args['view'] = _fuelView ? 'FUEL' : 'GROUP';
      args['fuelRef'] = _fuelRef;
      args['routeLine'] = _fuelView ? fuel.line : [
        if (snap.behind.isNotEmpty) '${snap.behind.first.name} · ${snap.behind.first.detail}${snap.behind.first.flag == null ? '' : ' · ${snap.behind.first.flag}'}',
        'You',
        if (snap.ahead.isNotEmpty) '${snap.ahead.first.name} · ${snap.ahead.first.detail}${snap.ahead.first.flag == null ? '' : ' · ${snap.ahead.first.flag}'}',
      ].join(' → ');
      args['routeDetail'] = _fuelView ? fuel.detail : 'Distances from you · not to scale';
      if (_fuelView) {
        args['subtitle'] = fuel.detail;
        if (fuel.warning && snap.tone == NotifTone.normal) args['tone'] = 'WARNING';
      }
    }
    final key = jsonEncode(args);
    if (!force && key == _lastKey && _richActive) {
      _lastQuick = quick;
      await _ensureShowing(now);
      return;
    }
    var shown = false;
    try {
      shown = await _channel.show(args);
    } on MissingPluginException {
      shown = false;
      _gaveUp = true; // no native side (tests of other screens, other platforms)
    } catch (e) {
      debugPrint('ride notification note: $e');
      shown = false;
    }
    if (_disposed) return;
    _lastPushMs = now;
    _lastQuick = quick;
    if (shown) {
      _failures = 0;
      _lastKey = key;
      _lastEnsureMs = now;
      _setRich(true);
    } else {
      _failed();
    }
  }

  void _armFreshness(ConvoyModel convoy, int now) {
    _freshnessTimer?.cancel();
    final deadlines = <int>[
      for (final rider in convoy.riders.values) ...[
        rider.lastSeenEpochMs + NotifConstants.noSignalAfter.inMilliseconds + 1,
        if (rider.stoppedSince > 0) rider.stoppedSince + NotifConstants.stoppedFlagAfter.inMilliseconds + 1,
      ],
      if (essentials?.essentials.snapshot != null)
        essentials!.essentials.snapshot!.fetchedAt + const Duration(minutes: 30).inMilliseconds + 1,
    ].where((at) => at > now).toList()..sort();
    if (deadlines.isEmpty) return;
    _freshnessTimer = Timer(Duration(milliseconds: deadlines.first - now), () {
      _freshnessTimer = null;
      _onChange();
    });
  }

  /// The content did not change: once per interval make sure the plugin did not put its own back.
  Future<void> _ensureShowing(int now) async {
    if (now - _lastEnsureMs < NotifConstants.minInterval.inMilliseconds) return;
    _lastEnsureMs = now;
    final ok = await _channel.ensure();
    if (_disposed || ok) return;
    // Gone (swiped away on Android 14+, or the service restarted): plain one back, retry later.
    _failed();
  }

  void _failed() {
    _failures++;
    _lastKey = null;
    if (_failures >= NotifConstants.maxFailures) {
      _giveUp();
    } else {
      _setRich(false);
    }
  }

  void _giveUp() {
    _gaveUp = true;
    _deactivate();
  }

  void _onServiceStarted() {
    if (_disposed || !_rideActive || _gaveUp || !_settings.richNotification) return;
    // The plugin just posted its plain notification over ours.
    _lastKey = null;
    _lastQuick = null;
    _pushNow(force: true);
    _recheck?.cancel();
    _recheck = Timer(NotifConstants.restartRecheck, () {
      _recheck = null;
      if (_disposed || !_richActive) return;
      _lastEnsureMs = -1 << 40;
      _ensureShowing(_clock()).ignore();
    });
  }

  // ------------------------------------------------------------ actions

  void _onAction(RideNotifAction a) {
    if (_disposed) return;
    switch (a.kind) {
      case RideNotifActionKind.viewGroup:
      case RideNotifActionKind.viewFuel:
        if (!_rideActive) return;
        _fuelView = a.kind == RideNotifActionKind.viewFuel;
        if (_fuelView) essentials?.refresh(category: 'FUEL').ignore();
        _pushNow(force: true);
        break;
      case RideNotifActionKind.openFuel:
        if (!_rideActive) return;
        _pending.value = a.ref == _fuelRef ? a : const RideNotifAction(RideNotifActionKind.openMap);
        break;
      case RideNotifActionKind.sos:
        // Never sends: the app opens the hold-to-send screen.
        _port.openSosFromNotification();
        _pending.value = a;
        break;
      case RideNotifActionKind.wait:
        _port.requestWaitFromNotification();
        break;
      case RideNotifActionKind.openMap:
      case RideNotifActionKind.navigateEmergency:
        _pending.value = a;
        break;
      case RideNotifActionKind.assistAccept:
        final ref = a.ref;
        if (ref == null || ref.isEmpty) break;
        _port.answerAssist(ref, AssistAnswer.accept);
        _pending.value = RideNotifAction(RideNotifActionKind.navigateEmergency, ref);
        break;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _freshnessTimer?.cancel();
    _timer?.cancel();
    _recheck?.cancel();
    essentials?.removeListener(_onChange);
    safety?.removeListener(_onChange);
    _port.removeListener(_onChange);
    _timeline?.removeListener(_onChange);
    _settings.removeListener(_onChange);
    if (BackgroundService.onServiceStarted == _onServiceStarted) BackgroundService.onServiceStarted = null;
    _actionSub?.cancel();
    _channel.dispose();
    _pending.dispose();
  }
}
