import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/net_constants.dart';
import '../../core/constants/network_constants.dart';
import '../local/outbox_store.dart';
import '../local/roster_store.dart';
import '../models/convoy_model.dart';
import '../models/emergency_roster.dart';
import '../models/group_message_model.dart';
import '../models/network_models.dart';
import '../models/network_wire.dart';
import '../models/outbox_item.dart';
import '../models/pending_sos.dart';
import '../models/rider_model.dart';
import '../models/route_model.dart';
import '../models/safety_wire.dart';
import '../models/sos_alert_model.dart';
import '../models/stop_point_model.dart';
import '../models/trip_history_model.dart';
import '../../domain/notify/status_text.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
import 'api_client.dart';
import 'background_service.dart';
import 'geo_service.dart';
import 'realtime_service.dart';
import 'settings_service.dart';
import 'timeline_service.dart';
import 'track_recorder.dart';
import 'trip_storage_service.dart';

/// Convoy state for the signed-in rider.
///
/// The gateway is the single source of truth: this class holds a mirror of the
/// active convoy that is updated by push events over one WebSocket (no polling),
/// and sends the rider's own telemetry with battery-aware throttling.
class ConvoyService extends ChangeNotifier {
  /// [outboxStore], [rosterStore], [clock] and [rosterDebounce] are for tests; the app uses the defaults.
  ConvoyService(
    this._api,
    this._rt,
    this._trips, {
    this.recorder,
    this.timeline,
    this.settings,
    OutboxStore? outboxStore,
    RosterStore? rosterStore,
    int Function()? clock,
    this._rosterDebounce = NetConstants.rosterRefreshDebounce,
  })  : _outboxStore = outboxStore ?? OutboxStore(),
        _rosterStore = rosterStore ?? RosterStore(),
        _clock = clock ?? _wallClock {
    _eventSub = _rt.events.listen(_onEvent);
    BackgroundService.addButtonListener(_onNotificationButton);
    _rt.addListener(_onConnectionChanged);
    _initBatteryTracking();
    _loadPendingSos();
    _outboxReady = _loadOutbox();
    _smsFallbackWas = _smsFallbackOn;
    settings?.addListener(_onSettingsChanged);
    // The compass only feeds the heading shown on screen: off while the app is not visible.
    // onDetach: the app is closing on purpose, so the group sees "App closed" rather than "No signal".
    try {
      _lifecycle = AppLifecycleListener(
        onHide: _pauseCompass,
        onPause: _pauseCompass,
        onResume: _resumeCompass,
        onShow: _resumeCompass,
        onDetach: _onDetach,
      );
    } catch (e) {
      debugPrint('lifecycle listener note: $e'); // no Flutter binding (plain unit tests)
    }
  }

  /// Data saver setting (optional: tests and older call sites work without it).
  final SettingsService? settings;
  AppLifecycleListener? _lifecycle;
  bool _compassPaused = false;

  final ApiClient _api;
  final RealtimeService _rt;
  final TripStorageService _trips;
  final TrackRecorder? recorder;
  final TimelineService? timeline;
  final Battery _battery = Battery();

  StreamSubscription<Map<String, dynamic>>? _eventSub;
  StreamSubscription<BatteryState>? _batteryStateSub;
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<Position>? _gpsSub;
  Timer? _idleHeartbeat;
  Timer? _batteryRefresh;
  Timer? _broadcastClear;
  Timer? _statusTimer;
  String _lastStatus = '';

  final Map<String, ConvoyModel> _allConvoys = {};
  String? _activeGroupId;
  String? _myUserId;
  bool _isRealGpsActive = false;
  bool _gpsIdleProfile = false;
  DateTime? _stationarySince;
  DateTime _lastTelemetryPush = DateTime.fromMillisecondsSinceEpoch(0);
  String? _systemBroadcastMessage;
  String? _lastError;
  String? _pendingJoinCode;
  bool _sosRequestedFromNotification = false;
  int _currentBatteryLevel = 100;
  bool _isCharging = false;
  double? _deviceCompassHeading;
  double? _lastFixAccuracyM;
  bool _adminWatching = false;
  PendingSos? _pendingSos;
  String? _deliveredSosAlertId;
  String? _sosOkNotice;
  Timer? _sosOkClear;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;
  final int Function() _clock;

  // Outbox (B4): chat, status, stops, WAIT, SOS replies and check-ins survive a dead zone and a restart.
  final OutboxStore _outboxStore;
  List<OutboxItem> _outbox = [];
  late final Future<void> _outboxReady;
  int _outboxEpoch = 0;
  int _clientSeq = 0;
  Timer? _outboxTimer;
  int _burstStartMs = 0;
  int _burstCount = 0;

  // Presence (B1).
  bool _killedLastTime = false;
  int? _killedAliveAt;
  int _lastAliveStampMs = 0;

  // My own fixes for the safety features (crash detection, fatigue): no extra GPS.
  final StreamController<TrackPoint> _myFixes = StreamController<TrackPoint>.broadcast();

  // Emergency SMS roster (only while a ride is active and the rider opted in).
  final RosterStore _rosterStore;
  final Duration _rosterDebounce;
  EmergencyRoster? _roster;
  int _rosterEpoch = 0;
  bool _rosterFetching = false;
  Timer? _rosterTimer;
  bool _smsFallbackWas = false;
  bool _disposed = false;

  // 3.15 Rider Safety Network and Rider Discovery Network: memory only, never persisted,
  // cleared with the ride. On a reconnect requests and warnings stay until the server sends them
  // again (a responder's navigation must not stop when they ride out of a dead zone); those not
  // sent again within [NetworkConstants.resendGrace] were closed meanwhile and are left out.
  final Map<String, AssistRequest> _assists = {};
  final List<AssistNotice> _assistNotices = [];
  final Map<String, HazardWarning> _hazards = {};
  final Map<String, Encounter> _encounters = {};
  final Map<String, EncounterType> _ignoredEncounters = {};
  final Set<String> _falseReported = {};
  final Set<String> _netUnconfirmed = {};
  int _netReconnectAt = 0;
  int _networkRevision = 0;
  bool _wasConnected = false;

  // 3.16: "Leave ride" pressed on the notification (the UI confirms it), live emergency
  // links this phone created (memory only, token never persisted or logged).
  bool _leaveRequestedFromNotification = false;
  final Map<String, LiveLink> _liveLinks = {};

  // ------------------------------------------------------------- getters
  Map<String, ConvoyModel> get allConvoys => Map.unmodifiable(_allConvoys);
  String? get activeGroupId => _activeGroupId;
  ConvoyModel? get activeConvoy => _activeGroupId != null ? _allConvoys[_activeGroupId] : null;
  String? get systemBroadcastMessage => _systemBroadcastMessage;
  String? get lastError => _lastError;

  /// A join code received through a `coroute://join/CODE` or `/join/CODE` link, waiting for the UI.
  String? get pendingJoinCode => _pendingJoinCode;
  void setPendingJoinCode(String? code) {
    final clean = code?.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    _pendingJoinCode = (clean == null || clean.isEmpty) ? null : clean;
    notifyListeners();
  }

  /// Set when the rider pressed SOS on the lock-screen notification; the UI confirms it.
  bool get sosRequestedFromNotification => _sosRequestedFromNotification;
  void clearSosRequest() {
    _sosRequestedFromNotification = false;
    notifyListeners();
  }
  bool get isRealGpsActive => _isRealGpsActive;

  /// Set when "Leave ride" was pressed on the notification (3.16): the UI asks "Leave the
  /// ride?" and calls [leaveActiveConvoy] on yes. Nothing leaves by itself.
  bool get leaveRequestedFromNotification => _leaveRequestedFromNotification;
  void clearLeaveRequest() {
    if (!_leaveRequestedFromNotification) return;
    _leaveRequestedFromNotification = false;
    notifyListeners();
  }

  /// Accuracy in metres of the last GPS fix (read-only; for the "Low accuracy" GPS word).
  double? get myFixAccuracyM => _lastFixAccuracyM;
  bool get isOnline => _rt.isConnected;

  /// An SOS this phone raised that the convoy has not confirmed yet (no signal, or not echoed yet).
  PendingSos? get pendingSos => _pendingSos;

  /// The internet works but the CoRoute server does not answer (banner: "CoRoute server not reachable").
  bool get serverUnreachable => _rt.serverUnreachable;

  /// True when the connected gateway supports [feature] (see ProtocolFeatures).
  bool supports(String feature) => _rt.supports(feature);

  /// Every GPS fix of mine while a ride is active (the same fixes the map uses; no extra GPS).
  Stream<TrackPoint> get myFixes => _myFixes.stream;

  /// Items waiting to be sent or refused by the server, oldest first. Refused items
  /// ("Not sent") stay visible for [NetConstants.outboxFailedShowFor].
  List<OutboxItem> get outbox {
    final now = _clock();
    return List.unmodifiable(_outbox.where((i) => !_failedExpired(i, now)));
  }

  int get outboxCount => outbox.length;

  /// True while the item is waiting for signal or for the server's answer.
  bool isQueued(String clientId) => _outbox.any((i) => i.clientId == clientId && i.isPending);

  /// Phone numbers for the no-internet SMS fallback of the active ride, or null.
  EmergencyRoster? get emergencyRoster {
    final r = _roster, gid = _activeGroupId;
    if (r == null || gid == null || !r.isValidFor(gid, _clock())) return null;
    return r;
  }

  /// The server id of this rider's own open SOS, if any (so it can be resolved from any screen).
  String? get myOpenSosAlertId {
    final c = activeConvoy;
    final uid = _myUserId;
    if (c != null && uid != null) {
      for (final a in c.activeAlerts.reversed) {
        if (a.userId == uid && !a.resolved) return a.alertId;
      }
    }
    return null;
  }

  /// "`<name>` says they are OK": shown for a short while when a rider resolves their own SOS.
  String? get sosOkNotice => _sosOkNotice;

  /// Recorded GPS points still waiting on the phone for upload (no polling; refreshed on events).
  int get pendingTrackPoints => recorder?.pendingPoints ?? 0;
  int get currentBatteryLevel => _currentBatteryLevel;
  bool get isCharging => _isCharging;
  String? get myUserId => _myUserId;

  // ------------------------------------------------ 3.15 safety network getters
  /// Changes whenever a network or discovery list, or an emergency's status, changed
  /// (cheap change check for listeners that should not rebuild on every GPS fix).
  int get networkRevision => _networkRevision;

  bool get _netOn => _rt.supports(ProtocolFeatures.safetyNet);
  bool get _discoveryOn => _rt.supports(ProtocolFeatures.discovery);

  static bool _dismissed(ResponderStatus s) =>
      s == ResponderStatus.declined || s == ResponderStatus.cancelled || s == ResponderStatus.unableToReach;

  /// Kept over a reconnect but not sent again by the server within the grace: closed meanwhile.
  bool _netGone(String id) =>
      _netUnconfirmed.contains(id) && _clock() - _netReconnectAt > NetworkConstants.resendGrace.inMilliseconds;

  /// Open requests to help a rider of another group, newest first. Requests I declined,
  /// cancelled or could not reach are left out (the server may still close them later).
  List<AssistRequest> get assistRequests {
    if (!_netOn) return const [];
    final list = _assists.values.where((r) => !_dismissed(r.myStatus) && !_netGone(r.incidentId)).toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return List.unmodifiable(list);
  }

  /// The request I accepted (on the way or with the rider), at most one.
  AssistRequest? get activeAssist {
    if (!_netOn) return null;
    AssistRequest? best;
    for (final r in _assists.values) {
      if (!r.myStatus.isActive || _netGone(r.incidentId)) continue;
      if (best == null || r.receivedAt > best.receivedAt) best = r;
    }
    return best;
  }

  /// "Another nearby rider is responding" notices, shown for [NetworkConstants.assistTakenShowFor].
  List<AssistNotice> get assistNotices {
    if (!_netOn) return const [];
    final now = _clock();
    return List.unmodifiable(_assistNotices.where((n) => now - n.at <= NetworkConstants.assistTakenShowFor.inMilliseconds).toList().reversed);
  }

  /// Accident warnings on my route, newest first. Empty while "Accident warnings on my
  /// route" is off (they are still kept, so switching it on shows them again).
  List<HazardWarning> get hazards {
    if (!_netOn || settings?.hazardAlerts == false) return const [];
    final now = _clock();
    final list = _hazards.values
        .where((h) => now - h.receivedAt <= NetworkConstants.hazardStaleAfter.inMilliseconds && !_netGone(h.hazardId))
        .toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return List.unmodifiable(list);
  }

  /// Public riding groups nearby that I did not ignore, newest first.
  List<Encounter> get encounters {
    if (!_discoveryOn) return const [];
    final now = _clock();
    final list = _encounters.values
        .where((e) => !_ignoredEncounters.containsKey(e.encounterId) && now - e.at <= NetworkConstants.encounterStaleAfter.inMilliseconds)
        .toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    return List.unmodifiable(list);
  }

  // ------------------------------------------------------------ 3.16 getters
  bool get _ride316 => _rt.supports(ProtocolFeatures.ride316);

  /// The rider the lead made the sweeper, if any.
  String? get sweeperId => activeConvoy?.sweeperId;
  bool get hasSweeper => sweeperId != null;

  /// The live emergency link this phone created for [alertId], while it is valid: not
  /// expired, not revoked (here or by the lead) and the alert still open.
  LiveLink? liveLinkFor(String alertId) {
    final l = _liveLinks[alertId];
    if (l == null) return null;
    final now = _clock();
    SosAlertModel? alert;
    for (final a in activeConvoy?.activeAlerts ?? const <SosAlertModel>[]) {
      if (a.alertId == alertId) alert = a;
    }
    if (!l.isValidAt(now) || alert == null || alert.resolved || alert.liveLinkRevokedAt > 0) {
      _liveLinks.remove(alertId);
      return null;
    }
    return l;
  }

  // ---------------------------------------------------------- lifecycle
  /// Call after sign-in. Opens the socket and restores an active convoy if any.
  Future<void> startSession({required String token, required String userId, bool admin = false}) async {
    _myUserId = userId;
    _rt.connect(token, adminMode: admin);
    _adminWatching = admin;
    await _readPreviousExit();
    final cachedRoster = _smsFallbackOn ? await _rosterStore.load() : null;
    final rosterEpoch = _rosterEpoch;
    await _restoreActiveConvoy();
    _killedLastTime = false;
    _killedAliveAt = null;
    final gid = _activeGroupId;
    if (cachedRoster != null) {
      if (gid != null && cachedRoster.isValidFor(gid, _clock())) {
        // Restored only for the same ride and while still valid (no internet after a restart).
        // Not when a fetch already answered (a refusal clears it, an answer replaces it).
        if (_roster == null && !_disposed && rosterEpoch == _rosterEpoch) {
          _roster = cachedRoster;
          notifyListeners();
        }
      } else {
        _rosterStore.clear().ignore();
      }
    } else if (settings != null && settings!.isLoaded && !_smsFallbackOn) {
      _rosterStore.clear().ignore();
    }
  }

  /// Reads whether the last ride ended without a clean exit (Android killed the app).
  Future<void> _readPreviousExit() async {
    try {
      final p = await SharedPreferences.getInstance();
      _killedLastTime = p.getBool(NetConstants.keyRideAlive) ?? false;
      final at = p.getInt(NetConstants.keyLastAliveAt);
      _killedAliveAt = (at != null && at > 0) ? at : null;
    } catch (_) {
      _killedLastTime = false;
      _killedAliveAt = null;
    }
  }

  /// Marks the ride as running (true) or cleanly finished (false) on disk.
  void _writeRideAlive(bool alive) {
    final now = _clock();
    if (alive) _lastAliveStampMs = now;
    SharedPreferences.getInstance().then((p) async {
      await p.setBool(NetConstants.keyRideAlive, alive);
      if (alive) {
        await p.setInt(NetConstants.keyLastAliveAt, now);
      } else {
        await p.remove(NetConstants.keyLastAliveAt);
      }
    }).catchError((Object _) {});
  }

  /// The app is closing on purpose: say BYE so the group sees "App closed", not "No signal".
  void _onDetach() {
    if (_activeGroupId == null) return;
    _rt.sendBye('APP_CLOSED');
    _writeRideAlive(false);
  }

  /// Call on sign-out.
  Future<void> endSession() async {
    if (_activeGroupId != null) _rt.sendBye('SIGN_OUT');
    _writeRideAlive(false);
    _clearPendingSos(); // never carried over to the next account on this phone
    _clearOutbox();
    _clearRoster();
    _clearNetwork();
    _deliveredSosAlertId = null;
    _stopStatus();
    recorder?.stop().ignore();
    timeline?.detach();
    BackgroundService.stop().ignore();
    stopRealGpsTracking();
    _rt.disconnect();
    _allConvoys.clear();
    _activeGroupId = null;
    _myUserId = null;
    notifyListeners();
  }

  Future<void> _restoreActiveConvoy() async {
    try {
      final res = await _api.get('/convoys/active');
      final c = (res is Map) ? res['convoy'] : null;
      if (c is Map) {
        final convoy = ConvoyModel.fromJson(Map<String, dynamic>.from(c));
        _activate(convoy);
        return;
      }
      // The server says there is no active convoy: an SOS still waiting on the phone has no
      // convoy to go to any more (an offline answer never gets here, so it is kept then).
      if (res is Map) {
        _clearPendingSos();
        _clearOutbox();
        if (_killedLastTime) _writeRideAlive(false);
      }
    } on ApiException catch (e) {
      debugPrint('restore active convoy note: ${e.message}');
    } catch (e) {
      debugPrint('restore active convoy note: $e');
    }
    // Nothing active on the server → clear any stale local pointer.
    SharedPreferences.getInstance().then((p) => p.remove(AppConstants.keyActiveGroupId)).ignore();
  }

  void _activate(ConvoyModel convoy) {
    // An SOS waiting for another (old) convoy can no longer be delivered there.
    if (_pendingSos != null && _pendingSos!.groupId != convoy.groupId) _clearPendingSos();
    _dropOutboxOfOtherGroups(convoy.groupId);
    if (_roster != null && _roster!.groupId != convoy.groupId) _clearRoster();
    if (_activeGroupId != convoy.groupId) _clearNetwork();
    _allConvoys[convoy.groupId] = convoy;
    _activeGroupId = convoy.groupId;
    if (_killedLastTime) {
      // The phone closed CoRoute during this ride last time: tell the group once, with the next JOIN.
      _rt.joinRoom(convoy.groupId, prevExit: 'KILLED', prevAliveAt: _killedAliveAt);
      _killedLastTime = false;
      _killedAliveAt = null;
    } else {
      _rt.joinRoom(convoy.groupId);
    }
    _writeRideAlive(true);
    SharedPreferences.getInstance().then((p) => p.setString(AppConstants.keyActiveGroupId, convoy.groupId)).ignore();
    _initCompassTracking();
    // Every member's route is recorded on their own phone and uploaded for the group timeline.
    recorder?.start(convoy.groupId, minStop: Duration(seconds: convoy.stopThresholdSeconds));
    timeline?.attach(convoy.groupId).ignore();
    _startStatus();
    if (_myUserId != null) startRealGpsTracking(_myUserId!).ignore();
    // Foreground service: keeps GPS, intercom and the connection alive with the screen locked.
    BackgroundService.start(convoyName: convoy.name, riderCount: convoy.riders.length).ignore();
    refreshEmergencyRoster(force: true).ignore();
    _flushOutbox();
    notifyListeners();
  }

  void _refreshNotification() => _pushStatus();

  // ------------------------------------------------ live status notification
  void _startStatus() {
    _statusTimer?.cancel();
    _lastStatus = '';
    // Redraw at most every 10 s, and only when the visible text changed (no sound, same notification).
    _statusTimer = Timer.periodic(const Duration(seconds: 10), (_) => _pushStatus());
    Timer(const Duration(seconds: 3), _pushStatus);
  }

  void _stopStatus() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _lastStatus = '';
  }

  void _pushStatus() {
    final convoy = activeConvoy;
    final uid = _myUserId;
    if (convoy == null || uid == null || _statusTimer == null) return;
    // 3.15: the large ride notification owns the ongoing notification; a plain update would replace it.
    if (BackgroundService.richActive) {
      _lastStatus = ''; // post the plain text again at once if the large one falls back
      return;
    }
    final me = convoy.riders[uid];
    final now = DateTime.now().millisecondsSinceEpoch;
    final route = convoy.routeLine;
    final meLat = me?.lat ?? 0.0, meLng = me?.lng ?? 0.0;
    final hasMe = meLat != 0 || meLng != 0;
    final myAlong = hasMe ? GeoMath.alongRoute(meLat, meLng, route) : null;
    final others = <StatusMember>[];
    for (final r in convoy.riders.values) {
      if (r.userId == uid || (r.lat == 0 && r.lng == 0)) continue;
      final along = myAlong != null ? GeoMath.alongRoute(r.lat, r.lng, route) : null;
      Duration? stoppedFor;
      final openStop = timeline?.openFor(r.userId, 'STOPPED');
      if (openStop != null) {
        stoppedFor = openStop.durationAt(now);
      } else if (r.stoppedSince > 0 && r.speedKmh < 3 && now - r.stoppedSince >= convoy.stopThresholdSeconds * 1000) {
        stoppedFor = Duration(milliseconds: now - r.stoppedSince);
      }
      others.add(StatusMember(
        name: r.name,
        distanceM: hasMe ? GeoMath.haversine(meLat, meLng, r.lat, r.lng) : 0.0,
        ahead: (myAlong != null && along != null && (along.along - myAlong.along).abs() > 30) ? along.along > myAlong.along : null,
        speedKmh: r.speedKmh,
        sinceUpdate: Duration(milliseconds: (now - r.lastSeenEpochMs).clamp(0, 1 << 40).toInt()),
        stoppedFor: stoppedFor,
      ));
    }
    final stops = convoy.plannedStops.where((s) => !s.isVisited).toList();
    final next = stops.isNotEmpty ? stops.first : null;
    final status = StatusText.build(
      convoyName: convoy.name,
      others: others,
      destinationRemainingM: !hasMe || (convoy.destinationLat == 0 && convoy.destinationLng == 0)
          ? null
          : (myAlong != null && route.length >= 2)
              // Along the planned route, not as the crow flies.
              ? ((GeoMath.alongRoute(route.last.$1, route.last.$2, route)?.along ?? 0) - myAlong.along).clamp(0.0, double.infinity).toDouble()
              : GeoMath.haversine(meLat, meLng, convoy.destinationLat, convoy.destinationLng),
      nextStopName: next?.name,
      nextStopRemainingM: hasMe && next != null ? GeoMath.haversine(meLat, meLng, next.lat, next.lng) : null,
    );
    final key = '${status.title}\n${status.text}';
    if (key == _lastStatus) return;
    _lastStatus = key;
    BackgroundService.updateStatus(title: status.title, text: status.text).ignore();
  }

  /// Buttons on the persistent notification (usable from the lock screen).
  void _onNotificationButton(String id) {
    if (_activeGroupId == null) return;
    if (id == BackgroundService.buttonLeave && _myUserId != null) {
      // 3.16: never a one-tap leave. The app asks "Leave the ride?" first.
      _leaveRequestedFromNotification = true;
      notifyListeners();
    } else if (id == BackgroundService.buttonSos) {
      // 3.15: never a one-tap send. The app opens the hold-to-send SOS screen.
      openSosFromNotification();
    }
  }

  @visibleForTesting
  void debugNotificationButton(String id) => _onNotificationButton(id);

  /// SOS pressed on a notification: asks the UI to show the hold-to-send SOS screen.
  /// Never raises an SOS by itself.
  void openSosFromNotification() {
    _sosRequestedFromNotification = true;
    notifyListeners();
  }

  /// "Wait for me" pressed on the ride notification (during an active ride only).
  void requestWaitFromNotification() {
    final uid = _myUserId;
    if (_activeGroupId == null || uid == null) return;
    requestWait(activeConvoy?.riders[uid]?.name ?? 'Rider');
  }

  void _onConnectionChanged() {
    final up = _rt.isConnected && !_wasConnected;
    _wasConnected = _rt.isConnected;
    // Back online (HELLO, before the re-JOIN): the server sends again what is still open.
    if (up) _markNetworkUnconfirmed();
    if (_rt.isConnected) {
      recorder?.uploadNow(); // send what was recorded in the dead zone
      // The roster could not be fetched before HELLO named the gateway's features, or it is
      // getting old (a long or multi-day ride): fetch while there is signal, since the texts
      // are needed exactly when there is none.
      if (_rosterWanted && _rosterStale) refreshEmergencyRoster(force: true).ignore();
    } else {
      recorder?.refreshPendingCount().ignore();
      // Handed to a socket that is gone: waiting for signal again (sent after the next SNAPSHOT).
      _outboxTimer?.cancel();
      _outboxTimer = null;
      _resetSendingItems();
    }
    // A pending SOS and the outbox are sent again after the SNAPSHOT that follows the re-JOIN (see _onEvent).
    notifyListeners();
  }

  /// The server builds the exact trip report shortly after a trip ends; fetch it then.
  void _syncTripsLater() {
    final uid = _myUserId;
    Timer(const Duration(seconds: 45), () => _trips.syncWithCloud(userId: uid).ignore());
  }

  // --------------------------------------------------------- push events
  void _onEvent(Map<String, dynamic> e) {
    final type = e['type']?.toString();
    if (type == 'BROADCAST') {
      _systemBroadcastMessage = e['message']?.toString();
      _broadcastClear?.cancel();
      _broadcastClear = Timer(const Duration(seconds: 12), () {
        _systemBroadcastMessage = null;
        notifyListeners();
      });
      notifyListeners();
      return;
    }
    if (type == 'FLEET') {
      _applyFleet(e['convoys']);
      return;
    }
    if (type == 'ACK') {
      _onAck(e['clientId']?.toString());
      return;
    }
    if (type == 'ERROR') {
      final cid = e['clientId']?.toString();
      final code = e['code'];
      if (cid != null && cid.isNotEmpty) _onOutboxError(cid, code is num ? code.toInt() : int.tryParse('$code'), e['message']?.toString());
      _lastError = e['message']?.toString();
      debugPrint('gateway error ${e['code']}: ${e['message']}');
      // Leave the convoy only when the server says we are no longer in it, and only after
      // double-checking: a slow link, a restart or an unrelated error (for example a 1:1 call
      // to a rider who is offline) must never throw a rider out of their group.
      final reason = e['reason']?.toString();
      if (reason == 'NOT_MEMBER' || reason == 'CONVOY_GONE') _confirmMembershipOrDrop().ignore();
      notifyListeners();
      return;
    }

    final gid = _activeGroupId;
    if (gid == null) return;
    final convoy = _allConvoys[gid];

    switch (type) {
      case 'SNAPSHOT':
        if (e['convoy'] is Map) {
          _allConvoys[gid] = ConvoyModel.fromJson(Map<String, dynamic>.from(e['convoy'] as Map));
        }
        // Back in the room after a dead zone or a restart: send the SOS that is still waiting,
        // then the outbox in order (the server ignores repeats by clientId).
        _sendPendingSos();
        _resetSendingItems();
        _flushOutbox();
        break;
      case 'RIDER_UPDATE':
        if (convoy == null || e['rider'] is! Map) return;
        final rider = RiderModel.fromJson(Map<String, dynamic>.from(e['rider'] as Map));
        final riders = Map<String, RiderModel>.from(convoy.riders)..[rider.userId] = rider;
        _allConvoys[gid] = convoy.copyWith(riders: riders);
        if (e['joined'] == true) {
          _refreshNotification();
          _scheduleRosterRefresh();
        }
        break;
      case 'RIDER_LEFT':
        if (convoy == null) return;
        final riders = Map<String, RiderModel>.from(convoy.riders)..remove(e['userId']?.toString());
        _allConvoys[gid] = convoy.copyWith(riders: riders);
        _refreshNotification();
        _scheduleRosterRefresh();
        break;
      case 'PRESENCE':
        if (convoy == null) return;
        final uid = e['userId']?.toString();
        final r = uid == null ? null : convoy.riders[uid];
        if (r == null) return;
        final riders = Map<String, RiderModel>.from(convoy.riders)
          ..[uid!] = r.copyWith(presence: e['presence']?.toString() ?? '', presenceAt: (e['at'] as num?)?.toInt() ?? _clock());
        _allConvoys[gid] = convoy.copyWith(riders: riders);
        break;
      case 'SOS_RESPONSE':
        if (convoy == null) return;
        final alertId = e['alertId']?.toString();
        if (alertId == null || !convoy.activeAlerts.any((a) => a.alertId == alertId)) return;
        final list = SosResponder.listFrom(e['responders']);
        _allConvoys[gid] = convoy.copyWith(
          activeAlerts: [for (final a in convoy.activeAlerts) a.alertId == alertId ? a.copyWith(responders: list) : a],
        );
        break;
      case 'ROSTER_CHANGED':
        _scheduleRosterRefresh();
        return;
      case 'MESSAGE':
        if (convoy == null || e['message'] is! Map) return;
        final msg = GroupMessageModel.fromJson(Map<String, dynamic>.from(e['message'] as Map));
        if (convoy.messages.any((m) => m.messageId == msg.messageId)) return;
        final msgs = List<GroupMessageModel>.from(convoy.messages)..add(msg);
        if (msgs.length > 300) msgs.removeRange(0, msgs.length - 300);
        _allConvoys[gid] = convoy.copyWith(messages: msgs);
        break;
      case 'ALERT':
        if (convoy == null || e['alert'] is! Map) return;
        final alert = SosAlertModel.fromJson(Map<String, dynamic>.from(e['alert'] as Map));
        final pending = _pendingSos;
        if (pending != null && pending.matches(alert.clientId)) {
          // The server has it: delivered to the convoy. Never shown as delivered before this echo.
          _pendingSos = null;
          _deliveredSosAlertId = alert.alertId;
          PendingSosStore.clear().ignore();
        }
        final others = convoy.activeAlerts.where((a) => a.alertId != alert.alertId);
        final alerts = alert.resolved ? others.toList() : (List<SosAlertModel>.from(others)..add(alert));
        if (alert.resolved || alert.liveLinkRevokedAt > 0) _liveLinks.remove(alert.alertId);
        _allConvoys[gid] = convoy.copyWith(activeAlerts: alerts);
        _networkRevision++;
        break;
      case 'ALERT_RESOLVED':
        if (convoy == null) return;
        final resolvedId = e['alertId']?.toString();
        final by = e['by']?.toString();
        for (final a in convoy.activeAlerts) {
          if (a.alertId == resolvedId && by != null && by == a.userId && a.userId != _myUserId) {
            _showSosOk('${a.userName.isNotEmpty ? a.userName : 'The rider'} says they are OK.');
          }
        }
        if (resolvedId != null && resolvedId == _deliveredSosAlertId) _deliveredSosAlertId = null;
        _liveLinks.remove(resolvedId);
        _allConvoys[gid] = convoy.copyWith(activeAlerts: convoy.activeAlerts.where((a) => a.alertId != resolvedId).toList());
        _networkRevision++;
        break;
      case 'EMERGENCY_UPDATE':
        if (convoy == null) return;
        final id = e['alertId']?.toString();
        if (id == null || !convoy.activeAlerts.any((a) => a.alertId == id)) return;
        _allConvoys[gid] = convoy.copyWith(activeAlerts: [for (final a in convoy.activeAlerts) a.alertId == id ? _patchEmergency(a, e) : a]);
        _networkRevision++;
        break;
      case 'ASSIST_REQUEST':
        if (!_onAssistRequest(e)) return;
        break;
      case 'ASSIST_UPDATE':
        if (!_onAssistUpdate(e)) return;
        break;
      case 'ASSIST_CLOSED':
        final id = e['incidentId']?.toString();
        if (id == null || _assists.remove(id) == null) return; // subject, medical and position go with it
        if (AssistClosedReason.fromWire(e['reason']?.toString()) == AssistClosedReason.taken) {
          _addAssistNotice(id, AssistClosedReason.taken);
        }
        _networkRevision++;
        break;
      case 'HAZARD':
        final h = HazardWarning.fromJson(e, receivedAt: _clock());
        if (h == null) return;
        _netUnconfirmed.remove(h.hazardId);
        _hazards[h.hazardId] = h;
        _networkRevision++;
        break;
      case 'HAZARD_CLEAR':
        if (_hazards.remove(e['hazardId']?.toString()) == null) return;
        _networkRevision++;
        break;
      case 'DISCOVERY':
        if (!_onDiscovery(e)) return;
        break;
      case 'WAVED':
        final id = e['encounterId']?.toString();
        final enc = id == null ? null : _encounters[id];
        if (enc == null) return;
        _encounters[id!] = enc.copyWith(theyWavedAt: _clock()); // local time: shown for a few seconds
        _networkRevision++;
        break;
      case 'STOPS':
        if (convoy == null || e['stopPoints'] is! List) return;
        final stops = (e['stopPoints'] as List).whereType<Map>().map((s) => StopPointModel.fromJson(Map<String, dynamic>.from(s))).toList();
        _allConvoys[gid] = convoy.copyWith(stopPoints: stops);
        break;
      case 'ROUTE':
        if (convoy == null) return;
        final r = e['route'];
        _allConvoys[gid] = r is Map
            ? convoy.copyWith(route: RouteModel.fromJson(Map<String, dynamic>.from(r)))
            : convoy.copyWith(clearRoute: true);
        _lastStatus = ''; // distances along the route changed
        break;
      case 'DESTINATION_ARRIVALS':
        if (convoy == null) return;
        _allConvoys[gid] = convoy.copyWith(destinationArrivals: StopArrival.mapFrom(e['destinationArrivals']));
        break;
      case 'DESTINATION':
        if (convoy == null) return;
        final st = e['start'];
        _allConvoys[gid] = convoy.copyWith(
          destinationName: e['destinationName']?.toString(),
          destinationLat: (e['destinationLat'] as num?)?.toDouble(),
          destinationLng: (e['destinationLng'] as num?)?.toDouble(),
          startLocationName: e['startLocationName']?.toString(),
          startLat: st is Map ? (st['lat'] as num?)?.toDouble() : null,
          startLng: st is Map ? (st['lng'] as num?)?.toDouble() : null,
        );
        break;
      case 'WAIT_REQUESTS':
        if (convoy == null || e['waitRequests'] is! Map) return;
        final w = <String, int>{};
        (e['waitRequests'] as Map).forEach((k, v) {
          if (v is num) w[k.toString()] = v.toInt();
        });
        _allConvoys[gid] = convoy.copyWith(waitRequests: w);
        break;
      case 'CONFIG':
        if (convoy == null) return;
        _allConvoys[gid] = convoy.copyWith(
          distanceThresholdMeters: (e['distanceThresholdMeters'] as num?)?.toDouble(),
          stopThresholdSeconds: (e['stopThresholdSeconds'] as num?)?.toInt(),
          voiceGuidanceEnabled: e['voiceGuidanceEnabled'] as bool?,
          speedLimitKmh: (e['speedLimitKmh'] as num?)?.toInt(),
          visibility: e['visibility'] is String ? GroupVisibility.fromWire(e['visibility'] as String) : null,
          discovery: e['discovery'] is bool ? e['discovery'] as bool : null,
          assistDefault: e['assistDefault'] is bool ? e['assistDefault'] as bool : null,
          townLimitKmh: (e['townLimitKmh'] as num?)?.toInt(),
        );
        break;
      case 'TRIP_STATUS':
        if (convoy == null) return;
        final status = e['tripStatus']?.toString() ?? convoy.tripStatus;
        _allConvoys[gid] = convoy.copyWith(tripStatus: status);
        if (status == 'ENDED') {
          _onTripEnded(_allConvoys[gid]!);
        } else if (status == 'STARTED' || status == 'PAUSED') {
          refreshEmergencyRoster().ignore();
        }
        break;
      case 'DISSOLVED':
        _dropActiveConvoyLocally();
        break;
      default:
        return;
    }
    notifyListeners();
  }

  void _applyFleet(dynamic list) {
    if (list is! List) return;
    final seen = <String>{};
    for (final c in list.whereType<Map>()) {
      final convoy = ConvoyModel.fromJson(Map<String, dynamic>.from(c));
      _allConvoys[convoy.groupId] = convoy;
      seen.add(convoy.groupId);
    }
    _allConvoys.removeWhere((k, _) => !seen.contains(k) && k != _activeGroupId);
    notifyListeners();
  }

  bool _confirmingMembership = false;

  Future<void> _confirmMembershipOrDrop() async {
    final gid = _activeGroupId;
    if (gid == null || _confirmingMembership) return;
    _confirmingMembership = true;
    try {
      final res = await _api.get('/convoys/active');
      final c = res is Map ? res['convoy'] : null;
      if (c is Map && c['groupId'] == gid) {
        _allConvoys[gid] = ConvoyModel.fromJson(Map<String, dynamic>.from(c));
        _rt.joinRoom(gid); // still a member: just rejoin the room
        notifyListeners();
      } else if (_activeGroupId == gid) {
        _dropActiveConvoyLocally();
      }
    } catch (_) {
      // Could not confirm (offline): stay in the convoy; the next reconnect re-joins it.
    } finally {
      _confirmingMembership = false;
    }
  }

  void _dropActiveConvoyLocally() {
    final gid = _activeGroupId;
    _clearPendingSos();
    _clearOutbox();
    _clearRoster();
    _clearNetwork();
    _writeRideAlive(false);
    _stopStatus();
    recorder?.stop().ignore();
    timeline?.detach();
    BackgroundService.stop().ignore();
    stopRealGpsTracking();
    _compassSub?.cancel();
    _rt.leaveRoom();
    if (gid != null) _allConvoys.remove(gid);
    _activeGroupId = null;
    SharedPreferences.getInstance().then((p) => p.remove(AppConstants.keyActiveGroupId)).ignore();
    notifyListeners();
  }

  void _onTripEnded(ConvoyModel convoy) {
    _clearPendingSos();
    _clearOutbox();
    _clearRoster();
    _clearNetwork();
    _writeRideAlive(false);
    if (_myUserId != null && convoy.riders.containsKey(_myUserId)) {
      _trips.saveTrip(buildTripHistory(convoy, userId: _myUserId), userId: _myUserId).ignore();
    }
    _stopStatus();
    recorder?.stop().ignore();
    _syncTripsLater();
    BackgroundService.stop().ignore();
    stopRealGpsTracking();
    _compassSub?.cancel();
    _rt.leaveRoom();
    _activeGroupId = null;
    SharedPreferences.getInstance().then((p) => p.remove(AppConstants.keyActiveGroupId)).ignore();
  }

  // ------------------------------------------------------- create / join
  Future<ConvoyModel> createConvoy({
    required String name,
    required String creatorId,
    required String creatorName,
    String startPoint = '',
    String destination = '',
    double destLat = 0.0,
    double destLng = 0.0,
    String vehicleType = 'Motorcycle',
    String vehicleNo = '',
    String phone = '',
    List<Map<String, double>> routeBreadcrumbs = const [],
    double distanceThresholdMeters = 1000.0,
    int stopThresholdSeconds = 180,
    bool voiceGuidanceEnabled = true,
    int speedLimitKmh = 0,
    PickedPlace? start,
    List<PickedPlace> stops = const [],
  }) async {
    final pos = await _getCurrentPosition();
    await _refreshBatteryLevel();
    final res = await _api.post('/convoys', {
      'name': name.trim(),
      'startPoint': startPoint,
      if (start != null)
        'start': start.toJson()
      else if (pos != null)
        'start': {'lat': pos.latitude, 'lng': pos.longitude, 'name': startPoint},
      if (stops.isNotEmpty) 'stops': stops.map((p) => p.toJson()).toList(),
      'destination': destination,
      'destLat': destLat,
      'destLng': destLng,
      'distanceThresholdMeters': distanceThresholdMeters,
      'stopThresholdSeconds': stopThresholdSeconds,
      'voiceGuidanceEnabled': voiceGuidanceEnabled,
      if (speedLimitKmh > 0) 'speedLimitKmh': speedLimitKmh,
      'routeBreadcrumbs': routeBreadcrumbs,
      'rider': {
        'lat': pos?.latitude ?? 0.0,
        'lng': pos?.longitude ?? 0.0,
        'vehicleType': vehicleType,
        'vehicleNo': vehicleNo,
        'phone': phone,
        'batteryLevel': _currentBatteryLevel,
        'isCharging': _isCharging,
      },
    });
    final convoy = ConvoyModel.fromJson(Map<String, dynamic>.from(res as Map));
    _myUserId ??= creatorId;
    _activate(convoy);
    return convoy;
  }

  Future<ConvoyModel?> joinConvoyByCode({required String code, required RiderModel rider}) async {
    _lastError = null;
    try {
      await _refreshBatteryLevel();
      final res = await _api.post('/convoys/join', {
        'code': code.trim().toUpperCase(),
        'rider': {
          'lat': rider.lat,
          'lng': rider.lng,
          'vehicleType': rider.vehicleType,
          'vehicleNo': rider.vehicleNo,
          'phone': rider.phone,
          'batteryLevel': _currentBatteryLevel,
          'isCharging': _isCharging,
        },
      });
      final convoy = ConvoyModel.fromJson(Map<String, dynamic>.from(res as Map));
      _myUserId ??= rider.userId;
      _activate(convoy);
      return convoy;
    } on ApiException catch (e) {
      _lastError = e.message;
      notifyListeners();
      return null;
    } catch (e) {
      _lastError = 'Could not join the convoy.';
      notifyListeners();
      return null;
    }
  }

  /// Leave the active convoy (saves the journey summary first).
  Future<void> leaveActiveConvoy(String userId) async {
    final gid = _activeGroupId;
    if (gid == null) return;
    _clearPendingSos();
    _clearOutbox();
    _clearRoster();
    _clearNetwork();
    _writeRideAlive(false);
    final convoy = _allConvoys[gid];
    if (convoy != null && convoy.riders.isNotEmpty) {
      _trips.saveTrip(buildTripHistory(convoy, userId: userId), userId: userId).ignore();
    }
    _stopStatus();
    recorder?.stop().ignore();
    _syncTripsLater();
    BackgroundService.stop().ignore();
    stopRealGpsTracking();
    _compassSub?.cancel();
    _rt.leaveRoom();
    _activeGroupId = null;
    _allConvoys.remove(gid);
    SharedPreferences.getInstance().then((p) => p.remove(AppConstants.keyActiveGroupId)).ignore();
    notifyListeners();
    try {
      await _api.post('/convoys/$gid/leave');
    } catch (e) {
      debugPrint('leave note: $e');
    }
  }

  // ---------------------------------------------------------- telemetry
  Future<Position?> _getCurrentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && DateTime.now().difference(last.timestamp).inMinutes < 2) return last;
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 4)),
      );
    } catch (e) {
      debugPrint('GPS position note: $e');
      return null;
    }
  }

  LocationSettings _settingsFor({required bool idle}) {
    final filter = idle ? AppConfig.gpsDistanceFilterIdle : AppConfig.gpsDistanceFilterMoving;
    final accuracy = idle ? LocationAccuracy.medium : LocationAccuracy.high;
    if (!kIsWeb && Platform.isAndroid) {
      // Background access is granted by the app's foreground service (BackgroundService), so
      // geolocator does not need its own notification here.
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: filter,
        intervalDuration: idle ? const Duration(seconds: 20) : const Duration(seconds: 2),
      );
    }
    return LocationSettings(accuracy: accuracy, distanceFilter: filter);
  }

  /// Starts adaptive GPS tracking: fine + frequent while moving, coarse + sparse when stopped.
  Future<bool> startRealGpsTracking(String userId) async {
    _myUserId = userId;
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return false;

    _gpsIdleProfile = false;
    _stationarySince = null;
    _subscribeGps();
    _isRealGpsActive = true;

    _idleHeartbeat?.cancel();
    _idleHeartbeat = Timer.periodic(AppConfig.telemetryIdleInterval, (_) {
      // While stopped the position stream is silent; a light heartbeat keeps "last seen" fresh.
      // Parked: the GPS stream is quiet, so the heartbeat records the parked time (not in a tunnel while moving).
      if (_gpsIdleProfile || _stationarySince != null) recorder?.onHeartbeat();
      final me = activeConvoy?.riders[_myUserId];
      if (me != null && DateTime.now().difference(_lastTelemetryPush) >= AppConfig.telemetryIdleInterval) {
        _pushTelemetry(me.copyWith(speedKmh: 0));
      }
    });
    notifyListeners();
    return true;
  }

  void _subscribeGps() {
    _gpsSub?.cancel();
    _gpsSub = Geolocator.getPositionStream(locationSettings: _settingsFor(idle: _gpsIdleProfile)).listen(_onPosition, onError: (e) {
      debugPrint('GPS stream note: $e');
    });
  }

  void _onPosition(Position position) {
    final userId = _myUserId;
    final convoy = activeConvoy;
    if (userId == null || convoy == null) return;
    final current = convoy.riders[userId];

    final speedKmh = (position.speed.isFinite ? position.speed * 3.6 : 0.0).clamp(0.0, 300.0).toDouble();
    _lastFixAccuracyM = position.accuracy.isFinite ? position.accuracy : null;
    final fix = TrackPoint(
      ts: position.timestamp.millisecondsSinceEpoch,
      lat: position.latitude,
      lng: position.longitude,
      speedKmh: speedKmh,
      accuracyM: position.accuracy.isFinite ? position.accuracy : 999,
    );
    recorder?.onFix(fix);
    if (_myFixes.hasListener) _myFixes.add(fix);
    final gpsHeading = position.heading.isFinite ? position.heading.clamp(0.0, 360.0).toDouble() : 0.0;
    final isMoving = speedKmh >= 3.0;

    // Adaptive power profile.
    if (isMoving) {
      _stationarySince = null;
      if (_gpsIdleProfile) {
        _gpsIdleProfile = false;
        _subscribeGps();
      }
    } else {
      _stationarySince ??= DateTime.now();
      if (!_gpsIdleProfile && DateTime.now().difference(_stationarySince!).inMinutes >= 3) {
        _gpsIdleProfile = true;
        _subscribeGps();
      }
    }

    // Sensor fusion: GPS course when moving, magnetometer when (nearly) stopped.
    double fusedHeading = current?.heading ?? 0.0;
    if (speedKmh >= 10.0 && gpsHeading > 0) {
      fusedHeading = gpsHeading;
    } else if (_deviceCompassHeading != null) {
      fusedHeading = _deviceCompassHeading!;
    } else if (gpsHeading > 0) {
      fusedHeading = gpsHeading;
    }

    final wasStopped = current?.statusReason.isNotEmpty == true;
    final base = current ??
        RiderModel(userId: userId, name: 'Rider', lat: position.latitude, lng: position.longitude, lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch);
    final updated = base.copyWith(
      lat: position.latitude,
      lng: position.longitude,
      speedKmh: speedKmh,
      heading: fusedHeading,
      batteryLevel: _currentBatteryLevel,
      isCharging: _isCharging,
      lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
      statusReason: (isMoving && wasStopped) ? '' : base.statusReason,
      statusMessage: (isMoving && wasStopped) ? '' : base.statusMessage,
      stoppedSince: isMoving ? 0 : (base.stoppedSince != 0 ? base.stoppedSince : DateTime.now().millisecondsSinceEpoch),
    );

    // Local UI updates immediately; the network push is throttled.
    _setMyRiderLocally(updated);
    final since = DateTime.now().difference(_lastTelemetryPush);
    final movedFar = current == null ||
        Geolocator.distanceBetween(current.lat, current.lng, position.latitude, position.longitude) > 40;
    if (since >= AppConfig.telemetryInterval(settings?.lowData ?? false) || movedFar || (isMoving && wasStopped)) {
      _pushTelemetry(updated);
    }
  }

  void _setMyRiderLocally(RiderModel rider) {
    final gid = _activeGroupId;
    final convoy = gid != null ? _allConvoys[gid] : null;
    if (convoy == null) return;
    _allConvoys[gid!] = convoy.copyWith(riders: Map<String, RiderModel>.from(convoy.riders)..[rider.userId] = rider);
    notifyListeners();
  }

  void _pushTelemetry(RiderModel r) {
    _lastTelemetryPush = DateTime.now();
    final now = _clock();
    if (_activeGroupId != null && now - _lastAliveStampMs >= NetConstants.aliveStampEvery.inMilliseconds) {
      _lastAliveStampMs = now;
      SharedPreferences.getInstance().then((p) => p.setInt(NetConstants.keyLastAliveAt, now)).catchError((Object _) => false);
      // Same once-a-minute beat: renew the SMS roster before it expires (no extra timer).
      if (_rt.isConnected && _rosterWanted && _rosterStale) refreshEmergencyRoster(force: true).ignore();
    }
    _rt.send({
      'type': 'TELEMETRY',
      'lat': r.lat,
      'lng': r.lng,
      'speedKmh': double.parse(r.speedKmh.toStringAsFixed(1)),
      'heading': double.parse(r.heading.toStringAsFixed(0)),
      'batteryLevel': _currentBatteryLevel,
      'isCharging': _isCharging,
      'statusReason': r.statusReason,
      'statusMessage': r.statusMessage,
      'stoppedSince': r.stoppedSince,
    });
  }

  void stopRealGpsTracking() {
    _gpsSub?.cancel();
    _gpsSub = null;
    _idleHeartbeat?.cancel();
    _isRealGpsActive = false;
    notifyListeners();
  }

  /// Kept for callers that patch the local rider (status, co-rider…); pushes the change.
  void updateRiderLocation(RiderModel updatedRider) {
    _setMyRiderLocally(updatedRider);
    if (updatedRider.userId == _myUserId) _pushTelemetry(updatedRider);
  }

  // ------------------------------------------------------------ compass
  void _pauseCompass() {
    if (_compassSub == null) return;
    _compassPaused = true;
    _compassSub?.cancel();
    _compassSub = null;
    _deviceCompassHeading = null; // stale once the phone moved in a pocket
  }

  void _resumeCompass() {
    if (!_compassPaused) return;
    _compassPaused = false;
    if (_activeGroupId != null && _compassSub == null) _initCompassTracking();
  }

  void _initCompassTracking() {
    _compassSub?.cancel();
    _compassPaused = false;
    try {
      _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
        if (event.heading == null) return;
        var h = event.heading!;
        if (h < 0) h += 360.0;
        _deviceCompassHeading = h;
      });
    } catch (e) {
      debugPrint('Compass note: $e');
    }
  }

  // ------------------------------------------------------------ battery
  Future<void> _initBatteryTracking() async {
    await _refreshBatteryLevel();
    _batteryStateSub?.cancel();
    try {
      _batteryStateSub = _battery.onBatteryStateChanged.listen((state) async {
        _isCharging = state == BatteryState.charging || state == BatteryState.full;
        await _refreshBatteryLevel();
        notifyListeners();
      }, onError: (_) {});
    } catch (_) {}
    _batteryRefresh?.cancel();
    _batteryRefresh = Timer.periodic(const Duration(seconds: 60), (_) => _refreshBatteryLevel());
  }

  Future<void> _refreshBatteryLevel() async {
    try {
      _currentBatteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      _isCharging = state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {}
  }

  // --------------------------------------------------------------- actions
  void sendGroupMessage({
    required String senderId,
    required String senderName,
    required String text,
    bool isQuickCard = false,
    String cardType = 'CUSTOM',
  }) {
    if (_activeGroupId == null || text.trim().isEmpty) return;
    _enqueue('CHAT', {'text': text.trim(), 'isQuickCard': isQuickCard, 'cardType': cardType, 'sentAt': _clock()});
  }

  void requestWait(String requesterName) {
    if (_activeGroupId == null) return;
    _enqueue('WAIT', {});
  }

  void addStopPoint({required String name, required double lat, required double lng, String category = 'REST'}) {
    if (_activeGroupId == null) return;
    _rt.send({'type': 'STOP_ADD', 'name': name, 'lat': lat, 'lng': lng, 'category': category});
  }

  // ------------------------------------------------------ route planning
  /// True when this rider may change the route (lead or creator).
  bool get canEditRoute {
    final c = activeConvoy;
    final uid = _myUserId;
    if (c == null || uid == null) return false;
    return c.createdByUserId == uid || c.riders[uid]?.role == 'LEAD';
  }

  bool _sendRoute(Map<String, dynamic> msg) {
    if (_activeGroupId == null) return false;
    final ok = _rt.send(msg);
    if (!ok) {
      _lastError = 'No connection. Try again when you are back online.';
      notifyListeners();
    }
    return ok;
  }

  /// Lead: adds a planned stop. Anyone else: sends a suggestion for the lead.
  bool addStop(PickedPlace p) => _sendRoute({'type': 'STOP_ADD', ...p.toJson()});
  bool suggestStop(PickedPlace p) => _sendRoute({'type': 'STOP_SUGGEST', ...p.toJson()});

  /// Lead: sets a meeting point (a MEETING stop) through the same add-stop
  /// message, placed before [insertBefore] (riding order) and replacing the
  /// open meeting point [replaceStopId], if given. The gateway checks both.
  bool addMeetingPoint(PickedPlace p, {String? insertBefore, String? replaceStopId}) => _sendRoute({
        'type': 'STOP_ADD',
        ...p.copyWith(category: 'MEETING').toJson(),
        'insertBefore': ?insertBefore,
        'replaceStopId': ?replaceStopId,
      });
  bool acceptStop(String stopId) => _sendRoute({'type': 'STOP_ACCEPT', 'stopId': stopId});
  bool declineStop(String stopId) => _sendRoute({'type': 'STOP_DECLINE', 'stopId': stopId});
  bool removeStop(String stopId) => _sendRoute({'type': 'STOP_REMOVE', 'stopId': stopId});
  bool skipStop(String stopId) => _sendRoute({'type': 'STOP_SKIP', 'stopId': stopId});

  /// Lead: new order of stops. Applied locally at once so the list does not jump back.
  bool reorderStops(List<String> stopIds) {
    final gid = _activeGroupId;
    final c = gid != null ? _allConvoys[gid] : null;
    if (c != null) {
      final byId = {for (final s in c.stopPoints) s.stopId: s};
      final next = <StopPointModel>[
        for (var i = 0; i < stopIds.length; i++)
          if (byId[stopIds[i]] != null) byId[stopIds[i]]!.copyWith(orderIndex: i + 1),
      ];
      for (final s in c.stopPoints) {
        if (!stopIds.contains(s.stopId)) next.add(s.copyWith(orderIndex: next.length + 1));
      }
      _allConvoys[gid!] = c.copyWith(stopPoints: next);
      notifyListeners();
    }
    return _sendRoute({'type': 'STOP_REORDER', 'order': stopIds});
  }

  bool setDestination(PickedPlace p) => _sendRoute({'type': 'ROUTE_SET', 'destination': p.toJson()});
  bool setStart(PickedPlace p) => _sendRoute({'type': 'ROUTE_SET', 'start': p.toJson()});

  void toggleStopVisited(String stopId, bool isVisited) {
    if (_activeGroupId == null) return;
    _enqueue('STOP_VISITED', {'stopId': stopId, 'isVisited': isVisited});
  }

  void updateTripState(String state) {
    if (_activeGroupId == null) return;
    _rt.send({'type': 'TRIP_STATUS', 'status': state});
  }

  void updateStatusReason({required String userId, required String reason, String message = ''}) {
    final convoy = activeConvoy;
    final rider = convoy?.riders[userId];
    if (rider == null) return;
    final stoppedSince = reason.isEmpty ? 0 : DateTime.now().millisecondsSinceEpoch;
    _setMyRiderLocally(rider.copyWith(statusReason: reason, statusMessage: message, stoppedSince: stoppedSince));
    _enqueue('STATUS', {'statusReason': reason, 'statusMessage': message, 'stoppedSince': stoppedSince});
  }

  void setCoRiderDriver(String riderId, String driverId) {
    final convoy = activeConvoy;
    final rider = convoy?.riders[riderId];
    if (rider == null) return;
    _setMyRiderLocally(rider.copyWith(isCoRiding: driverId.isNotEmpty, ridingWithUserId: driverId));
    _rt.send({'type': 'CORIDER', 'ridingWithUserId': driverId});
  }

  /// Lead: group settings. [townLimitKmh] (3.16, 0 = off) goes only to a gateway that supports it.
  void updateGroupConfig({double? distanceThresholdMeters, int? stopThresholdSeconds, bool? voiceGuidanceEnabled, int? speedLimitKmh, int? townLimitKmh}) {
    final payload = <String, dynamic>{'type': 'CONFIG'};
    if (distanceThresholdMeters != null) payload['distanceThresholdMeters'] = distanceThresholdMeters;
    if (stopThresholdSeconds != null) payload['stopThresholdSeconds'] = stopThresholdSeconds;
    if (voiceGuidanceEnabled != null) payload['voiceGuidanceEnabled'] = voiceGuidanceEnabled;
    if (speedLimitKmh != null) payload['speedLimitKmh'] = speedLimitKmh;
    if (townLimitKmh != null && _ride316) payload['townLimitKmh'] = townLimitKmh;
    if (payload.length == 1) return;
    _rt.send(payload);
  }

  /// Lead (3.16): makes [userId] the sweeper, or back to pack. One sweeper per group (the
  /// server moves the previous one back); applied when the RIDER_UPDATE comes back. Goes
  /// through the outbox. False when not the lead, the gateway is too old, the rider is not
  /// in the group, or the target is me or a lead.
  bool setSweeper(String userId, {required bool on}) {
    final c = activeConvoy;
    if (c == null || !canEditRoute || !_ride316) return false;
    final r = c.riders[userId];
    if (r == null || userId == _myUserId || userId == c.createdByUserId || r.role == RiderRoles.lead) return false;
    // Only the newest role change for a rider matters.
    _outbox.removeWhere((i) => i.type == 'ROLE_SET' && i.state == OutboxState.waiting && i.payload['userId'] == userId);
    return _enqueue('ROLE_SET', {'userId': userId, 'role': on ? RiderRoles.sweeper : RiderRoles.pack}) != null;
  }

  /// Raises an SOS for the active convoy. It is kept on the phone (memory and disk) until
  /// the server echoes it back, and sent again after every reconnect with the same
  /// clientId, so it is never lost in a dead zone and never delivered twice.
  SosDelivery triggerSosAlert({required String userId, required String userName, required double lat, required double lng, String type = 'EMERGENCY'}) =>
      _raise(idHint: userId, type: type, lat: lat, lng: lng);

  /// Raises an SOS (manual or automatic). A pending SOS for the same convoy keeps its
  /// clientId; a CRASH raise upgrades a pending one (type, automatic, details).
  SosDelivery raiseSos({
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
    EmergencySource? source,
  }) =>
      _raise(
        type: type,
        lat: lat,
        lng: lng,
        auto: auto,
        speedBeforeKmh: speedBeforeKmh,
        impactG: impactG,
        occurredAtMs: occurredAtMs,
        // An automatic crash SOS without an explicit source is a crash detection, not a button press.
        source: source ?? (auto ? EmergencySource.crashAuto : EmergencySource.manual),
      );

  SosDelivery _raise({
    String? idHint,
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
    EmergencySource source = EmergencySource.manual,
  }) {
    final gid = _activeGroupId;
    if (gid == null) return SosDelivery.notInConvoy;
    final existing = _pendingSos;
    final now = _clock();
    // My last fix (no new GPS request): heading, speed and accuracy go with the SOS.
    final me = _myUserId == null ? null : _allConvoys[gid]?.riders[_myUserId];
    double? heading, speed;
    if (me != null && (me.lat != 0 || me.lng != 0)) {
      heading = me.heading.isFinite ? me.heading : null;
      speed = me.speedKmh.isFinite ? me.speedKmh : null;
    }
    final accuracy = _lastFixAccuracyM;
    final PendingSos pending;
    if (existing != null && existing.groupId == gid) {
      // Still the same emergency (not confirmed yet): keep its id, use the newer position.
      final upgrade = type == SosTypes.crash && existing.type != SosTypes.crash;
      pending = upgrade
          ? existing.copyWith(
              lat: lat,
              lng: lng,
              type: type,
              auto: auto,
              speedBeforeKmh: speedBeforeKmh,
              impactG: impactG,
              createdAt: occurredAtMs ?? existing.createdAt,
              source: source,
              heading: heading,
              speedKmh: speed,
              accuracyM: accuracy,
            )
          : existing.copyWith(
              lat: lat,
              lng: lng,
              // A manual press never downgrades crash detection; an automatic one upgrades a manual SOS.
              source: existing.source == EmergencySource.manual ? source : null,
              heading: heading,
              speedKmh: speed,
              accuracyM: accuracy,
            );
    } else {
      final who = (idHint != null && idHint.isNotEmpty) ? idHint : (_myUserId ?? 'rider');
      pending = PendingSos(
        clientId: '$who-$now',
        groupId: gid,
        lat: lat,
        lng: lng,
        type: type,
        createdAt: occurredAtMs ?? now,
        auto: auto,
        speedBeforeKmh: speedBeforeKmh,
        impactG: impactG,
        source: source,
        heading: heading,
        speedKmh: speed,
        accuracyM: accuracy,
      );
    }
    _pendingSos = pending;
    PendingSosStore.save(pending).ignore();
    final sent = _sendPendingSos();
    notifyListeners();
    return sent ? SosDelivery.sent : SosDelivery.queued;
  }

  // ------------------------------------------------------ SOS replies, check-in
  /// "I'm going" / "I'm with them" / "Not going" for someone else's SOS. Goes through
  /// the outbox. False when not in a ride, for my own alert, or the gateway is too old.
  bool respondToSos(String alertId, SosResponseKind kind) {
    final c = activeConvoy;
    final uid = _myUserId;
    if (c == null || uid == null || alertId.isEmpty || !_rt.supports(ProtocolFeatures.respond)) return false;
    for (final a in c.activeAlerts) {
      if (a.alertId == alertId && a.userId == uid) return false;
    }
    // A newer answer replaces one still waiting for signal.
    _outbox.removeWhere((i) => i.type == 'SOS_RESPOND' && i.state == OutboxState.waiting && i.payload['alertId'] == alertId);
    return _enqueue('SOS_RESPOND', {'alertId': alertId, 'kind': kind.wire}) != null;
  }

  /// My answer to an alert: the newest one still queued, else what the server has.
  SosResponseKind? myResponseTo(String alertId) {
    for (final i in _outbox.reversed) {
      if (i.type != 'SOS_RESPOND' || i.isFailed || i.payload['alertId'] != alertId) continue;
      final k = SosResponseKind.fromWire(i.payload['kind']?.toString());
      return k == SosResponseKind.cancel ? null : k;
    }
    final uid = _myUserId;
    final c = activeConvoy;
    if (uid == null || c == null) return null;
    for (final a in c.activeAlerts) {
      if (a.alertId != alertId) continue;
      for (final r in a.responders) {
        if (r.userId == uid) return r.kind == SosResponseKind.cancel ? null : r.kind;
      }
    }
    return null;
  }

  /// Answer to the solo "Are you OK?" check (or no answer). Goes through the outbox.
  /// False when not in a ride or the gateway is too old. [context] (3.16): the post-crash
  /// "Still okay?" follow-up, sent only to a gateway that supports it (an older one gets a
  /// plain OK check-in).
  bool sendCheckIn(CheckInResult result, {double? awayM, CheckInContext? context}) {
    if (_activeGroupId == null || !_rt.supports(ProtocolFeatures.checkIn)) return false;
    if (context == CheckInContext.followUp && result == CheckInResult.noReply) return false; // the server refuses it
    final me = _myUserId == null ? null : activeConvoy?.riders[_myUserId];
    final lat = me?.lat ?? 0.0, lng = me?.lng ?? 0.0;
    final hasPos = lat != 0 || lng != 0;
    final payload = <String, dynamic>{'result': result.wire};
    if (context != null && _ride316) payload['context'] = context.wire;
    if (awayM != null && awayM.isFinite) payload['awayM'] = awayM.round().clamp(0, 500000);
    if (hasPos) {
      payload['lat'] = lat;
      payload['lng'] = lng;
    }
    return _enqueue('CHECK_IN', payload) != null;
  }

  // ----------------------------------------------------------------- outbox
  bool _failedExpired(OutboxItem i, int now) =>
      i.isFailed && now - (i.failedAt ?? i.createdAt) > NetConstants.outboxFailedShowFor.inMilliseconds;

  String _newClientId(int now) {
    _clientSeq = (_clientSeq + 1) % 100000;
    final salt = math.Random().nextInt(0xffff).toRadixString(16);
    return 'o$now-$_clientSeq-$salt';
  }

  OutboxItem? _enqueue(String type, Map<String, dynamic> payload) {
    final gid = _activeGroupId;
    if (gid == null) return null;
    final now = _clock();
    final item = OutboxItem(clientId: _newClientId(now), groupId: gid, type: type, payload: payload, createdAt: now);
    if (type == 'STATUS') {
      // Only the newest status matters.
      _outbox.removeWhere((i) => i.type == 'STATUS' && i.state == OutboxState.waiting);
    }
    _outbox.add(item);
    while (_outbox.length > NetConstants.outboxMaxItems) {
      final chat = _outbox.indexWhere((i) => i.type == 'CHAT');
      _outbox.removeAt(chat >= 0 ? chat : 0);
    }
    _persistOutbox();
    _flushOutbox();
    notifyListeners();
    return item;
  }

  /// Sends waiting items in order, at most [NetConstants.outboxSendPerSecond] per second.
  /// Called on enqueue and after each SNAPSHOT; a one-shot timer only while items wait
  /// and the socket is connected (no polling).
  void _flushOutbox() {
    _outboxTimer?.cancel();
    _outboxTimer = null;
    if (_outbox.isEmpty) return;
    final now = _clock();
    var changed = false;
    final before = _outbox.length;
    _outbox.removeWhere((i) => _failedExpired(i, now));
    final gid = _activeGroupId;
    if (gid == null || !_rt.isConnected) {
      if (_outbox.length != before) _persistOutbox();
      return;
    }
    // Dropped at send time: another ride, too old, or a WAIT or WAVE nobody needs any more.
    // "I Can Help" and "Arrived" are never dropped for age within the ride.
    _outbox.removeWhere((i) =>
        i.state == OutboxState.waiting &&
        (i.groupId != gid ||
            (now - i.createdAt > NetConstants.outboxMaxAge.inMilliseconds && !_keepForRide(i)) ||
            (i.type == 'WAIT' && now - i.createdAt > NetConstants.outboxWaitMaxAge.inMilliseconds) ||
            (i.type == 'WAVE' && now - i.createdAt > NetworkConstants.waveMaxAge.inMilliseconds)));
    changed = _outbox.length != before;
    final wall = DateTime.now().millisecondsSinceEpoch;
    if (wall - _burstStartMs >= 1000) {
      _burstStartMs = wall;
      _burstCount = 0;
    }
    final ack = _rt.supports(ProtocolFeatures.ack);
    var idx = 0;
    while (idx < _outbox.length && _burstCount < NetConstants.outboxSendPerSecond) {
      final item = _outbox[idx];
      if (item.state != OutboxState.waiting) {
        idx++;
        continue;
      }
      if (!_rt.send(item.toMessage(withClientId: ack))) break;
      _burstCount++;
      changed = true;
      if (ack) {
        _outbox[idx] = item.copyWith(state: OutboxState.sending);
        idx++;
      } else {
        // Older gateway (no ACK): done once handed to the socket, as in 3.13.
        _outbox.removeAt(idx);
      }
    }
    if (changed) {
      _persistOutbox();
      notifyListeners();
    }
    if (_rt.isConnected && _outbox.any((i) => i.state == OutboxState.waiting)) {
      final wait = (1000 - (DateTime.now().millisecondsSinceEpoch - _burstStartMs)).clamp(50, 1000).toInt();
      _outboxTimer = Timer(Duration(milliseconds: wait), _flushOutbox);
    }
  }

  static bool _keepForRide(OutboxItem i) {
    if (i.type != 'ASSIST_ANSWER') return false;
    final a = i.payload['answer'];
    return a == AssistAnswer.accept.wire || a == AssistAnswer.arrived.wire;
  }

  void _onAck(String? clientId) {
    if (clientId == null || clientId.isEmpty) return;
    final before = _outbox.length;
    _outbox.removeWhere((i) => i.clientId == clientId);
    if (_outbox.length == before) return;
    _persistOutbox();
    notifyListeners();
  }

  /// ERROR for an outbox item: 4xx (not 429) means the server refused it ("Not sent");
  /// 429 and 5xx keep it for another try.
  void _onOutboxError(String clientId, int? code, String? message) {
    final idx = _outbox.indexWhere((i) => i.clientId == clientId);
    if (idx < 0) return;
    final c = code ?? 500;
    if (c >= 400 && c < 500 && c != 429) {
      final item = _outbox[idx];
      _outbox[idx] = item.copyWith(state: OutboxState.failed, error: message ?? 'Not sent', failedAt: _clock());
      if (item.type == 'ASSIST_ANSWER' && (c == 404 || c == 409)) {
        // Closed (404) or someone else is already responding (409): the request is over for me.
        final id = item.payload['incidentId']?.toString();
        if (id != null && _assists.remove(id) != null) {
          if (c == 409) _addAssistNotice(id, AssistClosedReason.taken);
          _networkRevision++;
          notifyListeners();
        }
      }
    } else {
      _outbox[idx] = _outbox[idx].copyWith(state: OutboxState.waiting);
      if (c == 429 && _rt.isConnected && _outboxTimer == null) {
        _outboxTimer = Timer(const Duration(seconds: 1), _flushOutbox);
      }
    }
    _persistOutbox();
  }

  void _resetSendingItems() {
    var changed = false;
    for (var i = 0; i < _outbox.length; i++) {
      if (_outbox[i].state == OutboxState.sending) {
        _outbox[i] = _outbox[i].copyWith(state: OutboxState.waiting);
        changed = true;
      }
    }
    if (changed) _persistOutbox();
  }

  void _dropOutboxOfOtherGroups(String groupId) {
    final before = _outbox.length;
    _outbox.removeWhere((i) => i.groupId != groupId);
    if (_outbox.length != before) _persistOutbox();
  }

  void _persistOutbox() {
    final epoch = _outboxEpoch;
    _outboxReady.then((_) {
      if (epoch != _outboxEpoch) return Future<void>.value();
      return _outboxStore.save(List<OutboxItem>.of(_outbox));
    }).ignore();
  }

  Future<void> _loadOutbox() async {
    final epoch = _outboxEpoch;
    final stored = await _outboxStore.load();
    if (stored.isEmpty || epoch != _outboxEpoch || _disposed) return;
    final have = {for (final i in _outbox) i.clientId};
    _outbox = [
      for (final i in stored)
        if (!have.contains(i.clientId)) i.state == OutboxState.sending ? i.copyWith(state: OutboxState.waiting) : i,
      ..._outbox,
    ];
    notifyListeners();
    _flushOutbox();
  }

  /// Cleared with the ride (end, leave, dropped, sign-out), like the pending SOS.
  void _clearOutbox() {
    _outboxEpoch++;
    _outboxTimer?.cancel();
    _outboxTimer = null;
    _outbox = [];
    _outboxStore.clear().ignore();
  }

  // --------------------------------------------------------- SMS roster
  bool get _smsFallbackOn => settings?.smsFallback == true;

  bool get _rosterWanted => _smsFallbackOn && _activeGroupId != null && _rt.supports(ProtocolFeatures.roster);

  /// No usable roster, or more than half of its validity is gone. An expired roster cannot be
  /// renewed in a dead zone, and without it only the emergency contact would be texted.
  bool get _rosterStale {
    final r = _roster, gid = _activeGroupId;
    if (gid == null) return false;
    final now = _clock();
    if (r == null || !r.isValidFor(gid, now)) return true;
    final life = r.validUntil - r.fetchedAt;
    return life > 0 && r.validUntil - now < life ~/ 2;
  }

  void _onSettingsChanged() {
    final on = _smsFallbackOn;
    if (on == _smsFallbackWas) return;
    _smsFallbackWas = on;
    if (on) {
      refreshEmergencyRoster(force: true).ignore();
    } else {
      _clearRoster();
      notifyListeners();
    }
  }

  /// Fetches the phone numbers for the SMS fallback of the active ride. Only when the
  /// rider opted in, the ride is running and the gateway supports it. Never logged.
  Future<void> refreshEmergencyRoster({bool force = false}) async {
    final gid = _activeGroupId;
    if (gid == null || !_rosterWanted) return;
    final status = _allConvoys[gid]?.tripStatus;
    if (status != 'STARTED' && status != 'PAUSED') return;
    if (!force && _roster?.isValidFor(gid, _clock()) == true) return;
    if (_rosterFetching) return;
    _rosterFetching = true;
    final epoch = _rosterEpoch;
    try {
      final res = await _api.get('/convoys/$gid/emergency-roster');
      if (_disposed || epoch != _rosterEpoch || _activeGroupId != gid || !_smsFallbackOn) return;
      if (res is Map) {
        final r = EmergencyRoster.fromJson(Map<String, dynamic>.from(res), fetchedAt: _clock());
        if (r != null && r.groupId == gid) {
          _roster = r;
          await _rosterStore.save(r);
          if (epoch != _rosterEpoch || _disposed) {
            if (epoch != _rosterEpoch) _rosterStore.clear().ignore(); // cleared while saving
            return;
          }
          notifyListeners();
        }
      }
    } on ApiException catch (e) {
      // Not a member any more, or the ride is not running: nothing may stay on the phone.
      if (e.statusCode == 403 || e.statusCode == 409) _clearRoster();
      debugPrint('emergency roster note: ${e.statusCode}');
    } catch (_) {
      debugPrint('emergency roster note: not fetched'); // offline: keep the stored copy
    } finally {
      _rosterFetching = false;
    }
  }

  /// Riders joined, left or changed their opt-out: fetch again, at most once per debounce window.
  void _scheduleRosterRefresh() {
    if (!_rosterWanted || _rosterTimer?.isActive == true) return;
    _rosterTimer = Timer(_rosterDebounce, () {
      _rosterTimer = null;
      refreshEmergencyRoster(force: true).ignore();
    });
  }

  void _clearRoster() {
    _rosterEpoch++;
    _rosterTimer?.cancel();
    _rosterTimer = null;
    _roster = null;
    _rosterStore.clear().ignore();
  }

  /// Sends the waiting SOS if there is one for the active convoy. Event-driven only (no timer).
  bool _sendPendingSos() {
    final p = _pendingSos;
    if (p == null || p.groupId != _activeGroupId) return false;
    return _rt.send(p.toMessage());
  }

  Future<void> _loadPendingSos() async {
    final stored = await PendingSosStore.load();
    if (stored == null || _pendingSos != null) return;
    _pendingSos = stored;
    if (_activeGroupId != null && stored.groupId != _activeGroupId) {
      _clearPendingSos();
      return;
    }
    _sendPendingSos();
    notifyListeners();
  }

  void _clearPendingSos() {
    if (_pendingSos == null) return;
    _pendingSos = null;
    PendingSosStore.clear().ignore();
  }

  void _showSosOk(String text) {
    _sosOkNotice = text;
    _sosOkClear?.cancel();
    _sosOkClear = Timer(const Duration(seconds: 15), () {
      _sosOkNotice = null;
      notifyListeners();
    });
  }

  /// Cancels this rider's own SOS: resolves it on the server if it was delivered, and drops
  /// it from the phone if it is still waiting to be sent.
  /// [reason]: false alarm by default ("I am safe"); "Help reached me" passes [ResolveReason.resolved].
  void cancelMySos({ResolveReason reason = ResolveReason.falseAlarm}) {
    final waiting = _pendingSos;
    if (waiting != null) {
      _clearPendingSos();
      notifyListeners();
    }
    final id = myOpenSosAlertId ?? _deliveredSosAlertId;
    if (id != null) resolveSosAlert(id, reason: reason);
  }

  /// Closes an SOS. The [reason] goes to a gateway with the safety network only.
  void resolveSosAlert(String alertId, {ResolveReason reason = ResolveReason.resolved}) {
    final gid = _activeGroupId;
    if (gid == null) return;
    _liveLinks.remove(alertId); // the server revokes it with the alert
    final convoy = _allConvoys[gid];
    if (convoy != null) {
      _allConvoys[gid] = convoy.copyWith(activeAlerts: convoy.activeAlerts.where((a) => a.alertId != alertId).toList());
      notifyListeners();
    }
    _rt.send({'type': 'SOS_RESOLVE', 'alertId': alertId, if (_netOn) 'reason': reason.wire});
  }

  // ------------------------------------------------- 3.15 safety network
  SosAlertModel _patchEmergency(SosAlertModel a, Map<String, dynamic> e) {
    double? d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    final lat = d(e['lat']), lng = d(e['lng']);
    final hasPos = lat != null && lng != null && (lat != 0 || lng != 0);
    final lu = d(e['lastUpdateAt']);
    final link = e['liveLink'] is Map ? e['liveLink'] as Map : null;
    if (link != null && ((link['revokedAt'] as num?)?.toInt() ?? 0) > 0) _liveLinks.remove(a.alertId);
    return a.copyWith(
      status: EmergencyStatus.fromWire(e['status']?.toString()),
      lastUpdateAt: lu?.toInt(),
      lat: hasPos ? lat : null,
      lng: hasPos ? lng : null,
      network: EmergencyNetwork.fromJson(e['network']),
      ownNearest: OwnNearest.fromJson(e['ownNearest']),
      clearOwnNearest: e.containsKey('ownNearest') && e['ownNearest'] == null,
      nearestHospital: NearbyPlace.fromJson(e['nearestHospital']),
      liveLinkExpiresAt: link == null ? null : ((link['expiresAt'] as num?)?.toInt() ?? 0),
      liveLinkRevokedAt: link == null ? null : ((link['revokedAt'] as num?)?.toInt() ?? 0),
    );
  }

  /// True while an ASSIST_ANSWER for [incidentId] waits in the outbox (my newer answer wins).
  bool _answerPending(String incidentId) =>
      _outbox.any((i) => i.type == 'ASSIST_ANSWER' && i.isPending && i.payload['incidentId'] == incidentId);

  bool _onAssistRequest(Map<String, dynamic> e) {
    final r = AssistRequest.fromJson(e, receivedAt: _clock());
    if (r == null) return false;
    _netUnconfirmed.remove(r.incidentId);
    // Asked again after "another rider is responding" (that rider dropped out): the notice goes.
    _assistNotices.removeWhere((n) => n.incidentId == r.incidentId);
    final old = _assists[r.incidentId];
    _assists[r.incidentId] = old == null
        ? r
        : r.copyWith(
            // A request sent again (reconnect) carries no answer: keep mine.
            myStatus: old.myStatus != ResponderStatus.requested ? old.myStatus : null,
            incidentStatus: old.incidentStatus,
            subject: old.subject,
            medical: old.medical,
            arrivalCheck: old.arrivalCheck,
          );
    _networkRevision++;
    return true;
  }

  bool _onAssistUpdate(Map<String, dynamic> e) {
    final id = e['incidentId']?.toString();
    if (id == null || id.isEmpty) return false;
    final old = _assists[id];
    AssistRequest? next;
    if (old == null) {
      next = AssistRequest.fromJson(e, receivedAt: _clock()); // sent again after a reconnect
    } else {
      next = old.merge(e);
      if (_answerPending(id)) next = next.copyWith(myStatus: old.myStatus);
    }
    if (next == null) return false;
    _netUnconfirmed.remove(id);
    _assists[id] = next;
    _networkRevision++;
    return true;
  }

  void _addAssistNotice(String incidentId, AssistClosedReason reason) {
    final now = _clock();
    _assistNotices.removeWhere((n) => n.incidentId == incidentId || now - n.at > NetworkConstants.assistTakenShowFor.inMilliseconds);
    _assistNotices.add(AssistNotice(incidentId: incidentId, reason: reason, at: now));
  }

  bool _onDiscovery(Map<String, dynamic> e) {
    final id = e['encounterId']?.toString();
    if (id == null || id.isEmpty) return false;
    if (e['state']?.toString().toUpperCase() == 'END') {
      _ignoredEncounters.remove(id);
      if (_encounters.remove(id) == null) return false;
      _networkRevision++;
      return true;
    }
    final enc = Encounter.fromJson(e, at: _clock());
    if (enc == null) return false;
    final old = _encounters[id];
    // Ignored until it ends or the way the groups meet changes.
    if (_ignoredEncounters[id] != null && _ignoredEncounters[id] != enc.type) _ignoredEncounters.remove(id);
    _encounters[id] = old == null ? enc : enc.copyWith(iWaved: old.iWaved, theyWavedAt: old.theyWavedAt);
    _networkRevision++;
    return true;
  }

  /// Back online: requests and warnings stay (the responder keeps navigating) until the server
  /// sends them again; what it does not send again within [NetworkConstants.resendGrace] was
  /// closed while I had no signal and is left out by the getters. Discovery starts over.
  void _markNetworkUnconfirmed() {
    _netUnconfirmed
      ..clear()
      ..addAll(_assists.keys)
      ..addAll(_hazards.keys);
    _netReconnectAt = _clock();
    _assistNotices.clear();
    _encounters.clear();
    _ignoredEncounters.clear();
    _networkRevision++;
  }

  /// Everything of the safety and discovery networks goes (subject, medical, positions).
  void _clearNetwork() {
    _netUnconfirmed.clear();
    _liveLinks.clear();
    if (_assists.isEmpty && _assistNotices.isEmpty && _hazards.isEmpty && _encounters.isEmpty && _ignoredEncounters.isEmpty && _falseReported.isEmpty) return;
    _assists.clear();
    _assistNotices.clear();
    _hazards.clear();
    _encounters.clear();
    _ignoredEncounters.clear();
    _falseReported.clear();
    _networkRevision++;
  }

  /// Answers a request to help a nearby rider (I Can Help, Can't Assist, Arrived...).
  /// Goes through the outbox; my status changes at once. False when the gateway has no
  /// safety network or the request is unknown (closed).
  bool answerAssist(String incidentId, AssistAnswer answer) {
    final r = _assists[incidentId];
    if (!_netOn || r == null) return false;
    final item = _enqueue('ASSIST_ANSWER', {'incidentId': incidentId, 'answer': answer.wire});
    if (item == null) return false;
    final done = answer == AssistAnswer.arrived || answer == AssistAnswer.notFound;
    _assists[incidentId] = r.copyWith(myStatus: answer.resultingStatus, arrivalCheck: done ? false : null);
    _networkRevision++;
    notifyListeners();
    return true;
  }

  /// "Report false alert" for a request or an accident warning I received; once per id.
  bool reportFalseAlert(String incidentId) {
    if (!_netOn || _falseReported.contains(incidentId)) return false;
    if (!_assists.containsKey(incidentId) && !_hazards.containsKey(incidentId)) return false;
    if (_enqueue('NET_REPORT_FALSE', {'incidentId': incidentId}) == null) return false;
    _falseReported.add(incidentId);
    return true;
  }

  /// True after [reportFalseAlert] for this id.
  bool falseAlertReported(String incidentId) => _falseReported.contains(incidentId);

  /// "Rider down here": [subjectUserId] for a rider of my group, none for someone who is
  /// not in my group (I am at the scene). Goes through the outbox.
  bool reportRiderDown({required double lat, required double lng, String? subjectUserId}) {
    if (!_netOn || _activeGroupId == null) return false;
    if (!lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return false;
    final subject = (subjectUserId == null || subjectUserId.isEmpty) ? null : subjectUserId;
    if (subject != null && subject == _myUserId) return false;
    final me = _myUserId == null ? null : activeConvoy?.riders[_myUserId];
    final heading = me != null && (me.lat != 0 || me.lng != 0) && me.heading.isFinite ? me.heading.round() % 360 : null;
    return _enqueue('REPORT_DOWN', {'lat': lat, 'lng': lng, 'subjectUserId': ?subject, 'heading': ?heading}) != null;
  }

  /// Waves to a nearby public group (one tap; the server limits how often).
  bool wave(String encounterId) {
    final enc = _encounters[encounterId];
    if (!_discoveryOn || enc == null || enc.iWaved) return false;
    if (_enqueue('WAVE', {'encounterId': encounterId}) == null) return false;
    _encounters[encounterId] = enc.copyWith(iWaved: true);
    _networkRevision++;
    notifyListeners();
    return true;
  }

  /// Hides a nearby group card on this phone until the encounter ends or changes type.
  void ignoreEncounter(String encounterId) {
    final enc = _encounters[encounterId];
    if (enc == null) return;
    _ignoredEncounters[encounterId] = enc.type;
    _networkRevision++;
    notifyListeners();
  }

  /// Lead: group visibility and discovery (social, needs a `discovery1` gateway) and the
  /// group default for asking nearby riders to help (`net1`). False when not the lead,
  /// nothing supported was given, or there is no connection.
  bool setGroupVisibility({GroupVisibility? visibility, bool? discovery, bool? assistDefault}) {
    final gid = _activeGroupId;
    if (gid == null || !canEditRoute) return false;
    final msg = <String, dynamic>{'type': 'CONFIG'};
    if (_discoveryOn) {
      if (visibility != null) msg['visibility'] = visibility.wire;
      if (discovery != null) msg['discovery'] = discovery;
    }
    if (_netOn && assistDefault != null) msg['assistDefault'] = assistDefault;
    if (msg.length == 1) return false;
    if (!_sendRoute(msg)) return false;
    final c = _allConvoys[gid];
    if (c != null) {
      _allConvoys[gid] = c.copyWith(
        visibility: msg.containsKey('visibility') ? visibility : null,
        discovery: msg.containsKey('discovery') ? discovery : null,
        assistDefault: msg.containsKey('assistDefault') ? assistDefault : null,
      );
      notifyListeners();
    }
    return true;
  }

  // ------------------------------------------------------- 3.16 live links
  /// Creates a live emergency link for an open alert of my group (the owner or the lead):
  /// `https://<origin>/e/<token>`, valid [NetworkConstants.liveLinkMinutes]. Kept in memory
  /// only; the token is never persisted or logged. When the server says one is already
  /// active (409 LINK_ACTIVE) the one this phone knows is returned, else null.
  Future<LiveLink?> createLiveLink(String alertId) async {
    final gid = _activeGroupId;
    if (gid == null || alertId.isEmpty || !_ride316) return null;
    try {
      final res = await _api.post('/convoys/$gid/alerts/$alertId/live-link');
      final link = LiveLink.fromJson(res);
      if (link == null || _activeGroupId != gid) return null;
      _liveLinks[alertId] = link;
      _networkRevision++;
      notifyListeners();
      return link;
    } on ApiException catch (e) {
      if (e.statusCode == 409) return liveLinkFor(alertId);
      _lastError = e.message;
      notifyListeners();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Stops sharing: revokes the live link of [alertId] on the server and drops it here.
  Future<bool> revokeLiveLink(String alertId) async {
    final gid = _activeGroupId;
    if (gid == null || alertId.isEmpty || !_ride316) return false;
    final had = _liveLinks.remove(alertId) != null;
    if (had) {
      _networkRevision++;
      notifyListeners();
    }
    try {
      await _api.delete('/convoys/$gid/alerts/$alertId/live-link');
      return true;
    } on ApiException catch (e) {
      // Already gone (closed alert, no link): nothing to share any more.
      return e.statusCode == 404;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------ admin
  /// Master admin: live fleet overview over the same socket (read-only, no audio).
  void startAdminFleetWatch() {
    _adminWatching = true;
    _rt.send({'type': 'ADMIN_SUBSCRIBE'});
    _api.get('/admin/fleet').then((res) {
      if (res is Map) _applyFleet(res['convoys']);
    }).catchError((e) => debugPrint('fleet note: $e'));
  }

  bool get isAdminWatching => _adminWatching;

  Future<void> adminDissolveConvoy(String groupId) async {
    _allConvoys.remove(groupId);
    if (_activeGroupId == groupId) _dropActiveConvoyLocally();
    notifyListeners();
    try {
      await _api.delete('/admin/convoys/$groupId');
    } catch (e) {
      debugPrint('dissolve note: $e');
    }
  }

  Future<void> adminBroadcastSafetyAlert(String message) async {
    try {
      await _api.post('/admin/broadcast', {'message': message});
    } catch (e) {
      debugPrint('broadcast note: $e');
    }
  }

  // ----------------------------------------------------------- trip summary
  /// The phone's own record of a convoy trip, saved the moment it ends so the
  /// trip is in history at once (also offline). It carries no made-up numbers:
  /// distance, speeds and the route come from the server's report, which
  /// replaces this record a minute later (same trip id).
  TripHistoryModel buildTripHistory(ConvoyModel convoy, {String? userId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return TripHistoryModel(
      tripId: 'TRIP-${convoy.groupId.replaceAll('GRP-', '')}-${userId ?? convoy.createdByUserId}',
      tripName: convoy.name,
      startLocationName: convoy.startLocationName.isNotEmpty ? convoy.startLocationName : 'Convoy Start',
      destinationName: convoy.destinationName.isNotEmpty ? convoy.destinationName : 'Final Waypoint',
      startTimeEpochMs: convoy.createdAtEpochMs,
      endTimeEpochMs: math.max(now, convoy.createdAtEpochMs + 60000),
      totalDistanceKm: 0,
      topSpeedKmh: 0,
      avgSpeedKmh: 0,
      riderCount: convoy.riders.length,
      stopCount: 0,
      userId: userId ?? convoy.createdByUserId,
      createdByUserName: convoy.createdByUserName,
      groupId: convoy.groupId,
      source: 'device',
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _eventSub?.cancel();
    _rt.removeListener(_onConnectionChanged);
    _batteryStateSub?.cancel();
    _batteryRefresh?.cancel();
    _compassSub?.cancel();
    _gpsSub?.cancel();
    _idleHeartbeat?.cancel();
    _broadcastClear?.cancel();
    _sosOkClear?.cancel();
    _statusTimer?.cancel();
    _disposed = true;
    _outboxTimer?.cancel();
    _rosterTimer?.cancel();
    settings?.removeListener(_onSettingsChanged);
    _myFixes.close();
    super.dispose();
  }
}
