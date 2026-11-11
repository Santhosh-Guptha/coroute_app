import '../../domain/membership/plan_gate_messages.dart';
import '../../domain/tracking/ride_power_policy.dart';
import '../../domain/tracking/battery_saver.dart';
import '../../domain/tracking/location_cadence.dart';
import '../../domain/tracking/speed_estimator.dart';
import 'solo_fix_source.dart' show speedFixOf;
import '../../domain/tracking/battery_performance_monitor.dart';
import '../../domain/safety/accel_bucket.dart';
import '../../domain/tracking/dead_reckoning_engine.dart';
import 'accel_source.dart';
import '../../domain/mesh/mesh_telemetry_packet.dart';
import 'p2p_mesh_service.dart';
import 'tile_cache_service.dart';
import '../models/ride_feature_policy.dart';
import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
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
import '../models/rider_vehicle.dart';
import '../models/route_model.dart';
import '../models/safety_wire.dart';
import '../models/sos_alert_model.dart';
import '../models/road_hazard_telemetry.dart';
import '../../domain/safety/road_surface_detector.dart';
import '../models/stop_point_model.dart';
import '../models/trip_history_model.dart';
import '../../domain/notify/status_text.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_cleaner.dart';
import '../../domain/tracking/track_point.dart';
import 'api_client.dart';
import 'background_service.dart';
import 'geo_service.dart';
import 'realtime_service.dart';
import 'settings_service.dart';
import 'timeline_service.dart';
import 'track_recorder.dart';
import 'trip_storage_service.dart';
import '../../domain/ride/ride_roles.dart';
import '../../domain/ride/vehicle_swap.dart';
import '../../domain/ride/pillion_seat.dart'; // 3.55 pillion seat
import '../../domain/ride/ride_chat.dart'; // 3.55 ride chat
import '../../domain/notify/notice_dedupe.dart';
import 'ride_chat_store.dart';
import '../../domain/diag/diag_log.dart'; // 3.55 diagnostics log (no personal data)
import 'diag_log_service.dart';

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
    this.mesh,
    this.onPlanChanged,
    this.tilePrefetcher,
    this._accel,
    DeadReckoningEngine? deadReckoning,
    OutboxStore? outboxStore,
    RosterStore? rosterStore,
    int Function()? clock,
    this._rosterDebounce = NetConstants.rosterRefreshDebounce,
  })  : _deadReckoning = deadReckoning ?? DeadReckoningEngine(),
        _outboxStore = outboxStore ?? OutboxStore(),
        _rosterStore = rosterStore ?? RosterStore(),
        _clock = clock ?? _wallClock {
    _eventSub = _rt.events.listen(_onEvent);
    _meshSub = mesh?.onTelemetryReceived.listen(_onMeshTelemetry);
    BackgroundService.addButtonListener(_onNotificationButton);
    _rt.addListener(_onConnectionChanged);
    _initBatteryTracking();
    _loadPendingSos();
    _loadPendingResolves();
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

  /// P2P offline wireless mesh service for dead zones.
  final P2pMeshService? mesh;
  StreamSubscription<MeshTelemetryPacket>? _meshSub;

  bool get isP2pMeshActive => mesh?.isRunning ?? false;
  int get p2pMeshPeerCount => mesh?.peerCount ?? 0;

  /// Data saver setting (optional: tests and older call sites work without it).
  final SettingsService? settings;
  final DeadReckoningEngine _deadReckoning;
  DeadReckoningEngine get deadReckoning => _deadReckoning;
  bool get isTunnelCoasting => _deadReckoning.isCoasting;

  final AccelSource? _accel;
  StreamSubscription<AccelBucket>? _deadReckoningAccelSub;
  Timer? _deadReckoningTimer;
  int _lastGpsFixTime = 0;

  AppLifecycleListener? _lifecycle;
  bool _compassPaused = false;
  final RidePowerPolicy _power = RidePowerPolicy();
  bool get conservingBattery => _power.conserving;

  /// Low battery detection (< 20%) state.
  bool get isLowBattery => _power.isLowBattery || (_currentBatteryLevel < 20 && !_isCharging);

  /// Battery saver (Agent 4): the rider's switch, or automatic at 20 % or less (with
  /// hysteresis, see [BatterySaverPolicy]). Gentler GPS, slower telemetry, 15 fps camera
  /// and the dark map; never fewer safety features.
  final BatterySaverPolicy _saverPolicy = BatterySaverPolicy();
  bool _saverWas = false;
  BatterySaverState get batterySaver =>
      _saverPolicy.update(percent: _currentBatteryLevel, charging: _isCharging, userOn: settings?.batterySaver ?? false);
  bool get batterySaverActive => batterySaver.active || isLowBattery;

  /// Re-applies the battery saver levers when it switched on or off.
  void _syncBatterySaver() {
    final on = batterySaverActive;
    if (on == _saverWas) return;
    _saverWas = on;
    _applyLowBatteryPolicy(on);
    notifyListeners();
  }

  /// Monitors and computes battery drain per riding hour.
  final BatteryPerformanceMonitor batteryMonitor = BatteryPerformanceMonitor();

  /// Optional tile prefetcher for pausing during low battery states.
  TilePrefetcher? tilePrefetcher;
  void attachTilePrefetcher(TilePrefetcher prefetcher) {
    tilePrefetcher = prefetcher;
    if (isLowBattery) tilePrefetcher?.handleLowBattery(true);
  }

  final ApiClient _api;
  final RealtimeService _rt;
  final TripStorageService _trips;
  final TrackRecorder? recorder;
  final TimelineService? timeline;
  /// The rider's plan changed on the gateway (a legacy tier ending, warned or revoked): the app
  /// re-reads its membership, the single source of what the rider may host.
  final VoidCallback? onPlanChanged;

  /// Speaks a line (set in main.dart to the VoiceService, important tier). Used for the 3.55
  /// riding role prompts ("You are now the sweeper, drop back...").
  void Function(String line, String key)? speaker;

  /// 3.55 admin feature switches (set in main.dart to FeatureFlagsService.on). Null = everything on,
  /// so tests and older wiring never lose a feature.
  bool Function(String id)? featureOn;
  /// The admin switch of [id] AND (3.56) the active ride including it (hybrid free tier).
  bool _featureOn(String id) => (featureOn?.call(id) ?? true) && (activeConvoy?.allowsGroupFeature(id) ?? true);

  RoleNotice? _roleNotice;
  Timer? _roleNoticeClear;

  /// The last riding role change worth showing (mine first), for 20 s.
  RoleNotice? get roleNotice => _roleNotice;

  /// 3.55 riding roles (lead / middle / sweeper, swaps, automatic roles) on this gateway.
  bool get supportsRideRoles => _rt.supports(ProtocolFeatures.ride355);
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

  /// Speed band driving the GPS cadence (see [LocationCadence]); hysteresis inside.
  final SpeedBandTracker _gpsBand = SpeedBandTracker();

  /// My ride speed from the GPS fixes (Doppler first, outliers rejected, 0 when stopped): the one
  /// number the cockpit shows, the overspeed check judges, telemetry sends and the track records.
  final SpeedEstimator _speedEst = SpeedEstimator();
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
  final Map<String, RoadHazardObservation> _roadHazards = {};

  // 3.55 road history: saved road reports along the ride's route (GET /road-hazards/near),
  // fetched after a SNAPSHOT at most every [_roadHistoryEvery] and again when the route changes.
  static const Duration _roadHistoryEvery = Duration(minutes: 10);
  int _roadHistoryAt = 0;
  String? _roadHistoryKey;
  bool _roadHistoryBusy = false;
  final Map<String, Encounter> _encounters = {};
  final Map<String, EncounterType> _ignoredEncounters = {};
  final Set<String> _falseReported = {};
  final Set<String> _netUnconfirmed = {};
  int _netReconnectAt = 0;
  int _networkRevision = 0;
  bool _wasConnected = false;

  // Failover (two gateways): what the server has not confirmed is sent again while the socket
  // stays up (see _resendUnconfirmed), and a JOIN refused as SERVER_BUSY is tried again.
  final Map<String, int> _sendingSince = {};
  int _sosSentAt = 0;
  int _resolvesSentAt = 0;
  bool _roomConfirmed = false;
  String? _serverBusyGid;
  int _serverBusyAt = 0;
  int _serverBusyRetryMs = 0;
  bool _lastErrorIsServerBusy = false;

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
  bool _locationRevoked = false;
  bool get isLocationRevoked => _locationRevoked;

  /// Called when location permission or GPS service is revoked/disabled during an active trip.
  /// Stops real GPS tracking immediately without terminating the active trip.
  void onLocationRevoked() {
    _locationRevoked = true;
    stopRealGpsTracking();
  }

  /// Called when location permission and GPS service are restored during an active trip.
  void onLocationRestored() {
    if (!_locationRevoked) return;
    _locationRevoked = false;
    final uid = _myUserId;
    if (uid != null && activeConvoy != null) {
      startRealGpsTracking(uid).ignore();
    }
    notifyListeners();
  }

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

  /// The gateway refused this new rider's JOIN because it is full right now (socket ERROR
  /// SERVER_BUSY). Not a removal: the ride stays, and the JOIN is tried again by itself
  /// (and by [retryAfterServerBusy]).
  bool get serverBusy => _serverBusyGid != null && _serverBusyGid == _activeGroupId;

  /// The last create or join failed because the gateway is busy ([ApiException.serverBusyMessage]).
  bool get lastErrorIsServerBusy => _lastErrorIsServerBusy;

  /// "Try again" after SERVER_BUSY on the socket: sends the JOIN again now.
  void retryAfterServerBusy() {
    final gid = _activeGroupId;
    if (gid == null || !_rt.isConnected) return;
    _serverBusyAt = _clock();
    _rt.joinRoom(gid);
  }

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
    final r = _roster, gid = _activeGroupId ?? _unconfirmedRideGid;
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
  /// 3.55: empty while the admin has live road warnings switched off (cards, pins and speech follow).
  List<RoadHazardObservation> get roadHazards => _featureOn('roadHazards') ? _roadHazards.values.toList() : const [];

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
    _loadChatPrefs().ignore(); // 3.55 ride chat: quick action order, hidden riders, unread marks
    _adminWatching = admin;
    await _readPreviousExit();
    final cachedRoster = _smsFallbackOn ? await _rosterStore.load() : null;
    final rosterEpoch = _rosterEpoch;
    await _restoreActiveConvoy();
    // An offline restart keeps the KILLED note for the re-join that follows when the link is back.
    if (_unconfirmedRideGid == null) {
      _killedLastTime = false;
      _killedAliveAt = null;
    }
    // The ride not confirmed yet (no signal) keeps its SMS roster: it is needed exactly then.
    final gid = _activeGroupId ?? _unconfirmedRideGid;
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
    _unconfirmedRideGid = null;
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

  /// The ride this phone was on when the app last closed, while the server could not be asked
  /// (restarted in a dead zone, server busy): kept, and asked again as soon as the link is back.
  /// Without this an offline restart dropped the ride, its SMS roster and the re-join for good.
  String? _unconfirmedRideGid;
  bool _restoringRide = false;

  Future<void> _restoreActiveConvoy() async {
    if (_restoringRide) return;
    _restoringRide = true;
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(AppConstants.keyActiveGroupId);
    } catch (_) {
      saved = null;
    }
    try {
      // A ride left without signal must not come back as "active" (the leave goes first).
      await _flushPendingLeaves();
      final res = await _api.get('/convoys/active');
      final c = (res is Map) ? res['convoy'] : null;
      if (c is Map) {
        final convoy = ConvoyModel.fromJson(Map<String, dynamic>.from(c));
        _unconfirmedRideGid = null;
        _activate(convoy);
        return;
      }
      // The server says there is no active convoy: an SOS still waiting on the phone has no
      // convoy to go to any more (an offline answer never gets here, so it is kept then).
      if (res is Map) {
        _clearPendingSos();
        _clearOutbox();
        if (_activeGroupId == null && _roster != null) _clearRoster();
        if (_killedLastTime) _writeRideAlive(false);
      }
    } on ApiException catch (e) {
      debugPrint('restore active convoy note: ${e.message}');
      // No answer from the gateway (offline, timeout, outage, rate limit): not "no ride".
      if (e.isOffline || e.statusCode >= 500 || e.statusCode == 429) {
        if (saved != null && saved.isNotEmpty && _activeGroupId == null) _unconfirmedRideGid = saved;
        if (!_disposed) notifyListeners();
        return;
      }
    } catch (e) {
      debugPrint('restore active convoy note: $e');
      if (saved != null && saved.isNotEmpty && _activeGroupId == null) _unconfirmedRideGid = saved;
      if (!_disposed) notifyListeners();
      return;
    } finally {
      _restoringRide = false;
    }
    // Nothing active on the server → clear any stale local pointer.
    _unconfirmedRideGid = null;
    SharedPreferences.getInstance().then((p) => p.remove(AppConstants.keyActiveGroupId)).ignore();
  }

  /// True while the phone was restarted during a ride without signal and the server has not
  /// confirmed the ride yet (the UI can say "Reconnecting to your ride...").
  bool get hasUnconfirmedRide => _activeGroupId == null && _unconfirmedRideGid != null;

  void _activate(ConvoyModel convoy) {
    _unconfirmedRideGid = null;
    _rideEndedNotice = false;
    // Resolves restored after a restart belong to this ride: they survive its first activation.
    if (_activeGroupId != convoy.groupId && _pendingResolvesGid != convoy.groupId) {
      _pendingResolves.clear();
      _pendingResolvesGid = null;
      _savePendingResolves();
    }
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
    // 3.55 live bike change: a bike picked while the ride was being restored still reaches the group.
    _syncVehicle();
    final myRider = convoy.riders[_myUserId];
    mesh?.start(
      joinCode: convoy.joinCode,
      myUserId: _myUserId ?? '',
      myUserName: myRider?.name ?? 'Rider',
    ).ignore();
    notifyListeners();
  }

  /// Explicitly refreshes group members from the server without restarting active tracking.
  Future<bool> refreshGroupMembers({bool force = false}) async {
    final gid = _activeGroupId;
    if (gid == null) return false;
    try {
      final res = await _api.get('/convoys/$gid');
      if (res is Map && res['convoy'] is Map) {
        final serverConvoy = ConvoyModel.fromJson(Map<String, dynamic>.from(res['convoy'] as Map));
        _mergeServerConvoy(serverConvoy);
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('refreshGroupMembers note: $e');
    }
    return false;
  }

  /// Restores server state completely on network recovery:
  /// - Refreshes active trip and group members without restarting active tracking.
  /// - Flushes queued outbox events safely without duplicates.
  /// - Drains queued offline track points.
  /// - Refreshes emergency roster and presence.
  Future<void> restoreServerState() async {
    final gid = _activeGroupId;
    if (gid == null) return;
    try {
      final res = await _api.get('/convoys/active');
      if (res is Map && res['convoy'] is Map) {
        final serverConvoy = ConvoyModel.fromJson(Map<String, dynamic>.from(res['convoy'] as Map));
        if (serverConvoy.groupId == gid) {
          _mergeServerConvoy(serverConvoy);
        }
      }
    } catch (e) {
      debugPrint('restoreServerState API note: $e');
    }

    if (_rt.isConnected) {
      _rt.joinRoom(gid);
    }

    recorder?.uploadNow();

    if (_rosterWanted && _rosterStale) {
      refreshEmergencyRoster(force: true).ignore();
    }
    notifyListeners();
  }

  void _mergeServerConvoy(ConvoyModel serverConvoy) {
    final gid = serverConvoy.groupId;
    final current = _allConvoys[gid];
    final myId = _myUserId;

    if (current != null && myId != null) {
      final localMe = current.riders[myId];
      final serverMe = serverConvoy.riders[myId];
      // Keep local rider telemetry if local fix is fresher or active
      if (localMe != null && (serverMe == null || localMe.lastSeenEpochMs >= serverMe.lastSeenEpochMs)) {
        // My position stays local; my role is always the server's (it may have changed while away).
        final mergedRiders = Map<String, RiderModel>.from(serverConvoy.riders)
          ..[myId] = serverMe == null ? localMe : localMe.copyWith(role: serverMe.role);
        _allConvoys[gid] = serverConvoy.copyWith(
          riders: mergedRiders,
          messages: _mergeMessages(current.messages, serverConvoy.messages),
          activeAlerts: _mergeAlerts(current.activeAlerts, serverConvoy.activeAlerts),
        );
        _pushTelemetry(localMe);
        return;
      }
    }
    _allConvoys[gid] = serverConvoy;
  }

  static List<GroupMessageModel> _mergeMessages(List<GroupMessageModel> local, List<GroupMessageModel> server) {
    final map = <String, GroupMessageModel>{};
    for (final m in local) {
      map[m.messageId] = m;
    }
    for (final m in server) {
      map[m.messageId] = m;
    }
    final list = map.values.toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (list.length > 300) list.removeRange(0, list.length - 300);
    return list;
  }

  static List<SosAlertModel> _mergeAlerts(List<SosAlertModel> local, List<SosAlertModel> server) {
    final map = <String, SosAlertModel>{};
    for (final a in local) {
      map[a.alertId] = a;
    }
    for (final a in server) {
      map[a.alertId] = a;
    }
    return map.values.where((a) => !a.resolved).toList();
  }

  void _onMeshTelemetry(MeshTelemetryPacket packet) {
    final gid = _activeGroupId;
    if (gid == null) return;
    final convoy = _allConvoys[gid];
    if (convoy == null || packet.userId == _myUserId) return;

    final rider = convoy.riders[packet.userId];
    if (rider == null) return;

    final updatedRider = rider.copyWith(
      lat: packet.lat,
      lng: packet.lng,
      speedKmh: packet.speedKmh,
      heading: packet.heading,
      batteryLevel: packet.batteryLevel,
      isCharging: packet.isCharging,
      role: packet.role,
      presence: 'MESH',
      presenceAt: packet.timestampMs,
      lastSeenEpochMs: packet.timestampMs,
      isMeshPeer: true,
      meshHops: packet.hopCount,
      lastMeshEpochMs: packet.timestampMs,
    );

    final riders = Map<String, RiderModel>.from(convoy.riders)..[packet.userId] = updatedRider;

    if (packet.isSos) {
      final hasAlert = convoy.activeAlerts.any((a) => a.userId == packet.userId && !a.resolved);
      if (!hasAlert) {
        final alert = SosAlertModel(
          alertId: 'mesh_${packet.userId}_${packet.seq}',
          userId: packet.userId,
          userName: packet.userName.isNotEmpty ? packet.userName : rider.name,
          lat: packet.lat,
          lng: packet.lng,
          alertType: packet.sosType,
          timestamp: packet.timestampMs,
          occurredAt: packet.timestampMs,
          source: EmergencySource.meshBeacon,
        );
        final alerts = List<SosAlertModel>.from(convoy.activeAlerts)..add(alert);
        _allConvoys[gid] = convoy.copyWith(riders: riders, activeAlerts: alerts);
        _networkRevision++;
        notifyListeners();
        _refreshNotification();
        return;
      }
    }

    _allConvoys[gid] = convoy.copyWith(riders: riders);
    notifyListeners();
    _refreshNotification();
  }

  /// Ingests a peer-to-peer mesh telemetry packet from a nearby teammate.
  void applyMeshTelemetry(MeshTelemetryPacket packet) => _onMeshTelemetry(packet);

  void _refreshNotification() => _pushStatus();

  // ------------------------------------------------ live status notification
  void _startStatus() {
    _statusTimer?.cancel();
    _lastStatus = '';
    // Redraw at most every 10 s, and only when the visible text changed (no sound, same notification).
    _statusTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _resendUnconfirmed();
      _pushStatus();
    });
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

  @visibleForTesting
  void setActiveConvoyForTesting(ConvoyModel convoy) {
    _allConvoys[convoy.groupId] = convoy;
    _activeGroupId = convoy.groupId;
    final myRider = convoy.riders[_myUserId];
    mesh?.start(
      joinCode: convoy.joinCode,
      myUserId: _myUserId ?? '',
      myUserName: myRider?.name ?? 'Rider',
    ).ignore();
    notifyListeners();
  }

  @visibleForTesting
  void setMyUserIdForTesting(String uid) {
    _myUserId = uid;
  }

  /// "End ride" / "Leave" on the ride notification: the app asks for a confirm first
  /// (same path as the plain notification's Leave button). Nothing ends by itself.
  void requestLeaveFromNotification() => _onNotificationButton(BackgroundService.buttonLeave);

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
    if (up) {
      _markNetworkUnconfirmed();
      // A ride left without signal: tell the server now, so the group stops waiting for this rider.
      if (_activeGroupId == null && _unconfirmedRideGid == null) _flushPendingLeaves().ignore();
      if (_activeGroupId == null && _unconfirmedRideGid != null) {
        // Restarted without signal during a ride: ask the server now and re-join it.
        _restoreActiveConvoy().ignore();
      } else {
        restoreServerState().ignore();
      }
    }
    if (_rt.isConnected) {
      recorder?.uploadNow(); // send what was recorded in the dead zone
      // The roster could not be fetched before HELLO named the gateway's features, or it is
      // getting old (a long or multi-day ride): fetch while there is signal, since the texts
      // are needed exactly when there is none.
      if (_rosterWanted && _rosterStale) refreshEmergencyRoster(force: true).ignore();
    } else {
      _roomConfirmed = false;
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
      if (e['code']?.toString() == ApiException.serverBusyCode) {
        // The gateway is full for new riders right now: say so plainly and try the JOIN again
        // later. Never a removal from the ride and never an outbox failure.
        _onServerBusy();
        return;
      }
      final cid = e['clientId']?.toString();
      final code = e['code'];
      // 3.55 live bike change: a refused RIDER_VEHICLE is retried later or dropped, quietly.
      if ((cid == null || cid.isEmpty) && _onVehicleRefused(e['reason']?.toString())) return;
      if (cid != null && cid.isNotEmpty) {
        _onOutboxError(cid, code is num ? code.toInt() : int.tryParse('$code'), e['message']?.toString(), e['reason']?.toString());
        _onSwapRefused(e['reason']?.toString(), e['message']?.toString()); // 3.55
        _onPillionRefused(e['reason']?.toString(), e['message']?.toString()); // 3.55 pillion seat
      }
      _lastError = e['message']?.toString();
      debugPrint('gateway error ${e['code']}: ${e['message']}');
      // Leave the convoy only when the server says we are no longer in it, and only after
      // double-checking: a slow link, a restart or an unrelated error (for example a 1:1 call
      // to a rider who is offline) must never throw a rider out of their group.
      final reason = e['reason']?.toString();
      if (reason == 'NOT_MEMBER' || reason == 'CONVOY_GONE') _confirmMembershipOrDrop().ignore();
      if (reason == 'RIDE_ENDED') {
        _lastError = 'This ride has ended.';
        _onRideEndedError().ignore();
      }
      notifyListeners();
      return;
    }

    // Plan events concern the account, not a convoy: handled whether or not a ride is active.
    // 3.56: CAPABILITIES_CHANGED (the admin changed the access mode, or its scheduled change came):
    // the same re-read of /membership/my, which carries the new capabilities.
    if (type == 'SUBSCRIPTION_ACTIVATED' ||
        type == 'SUBSCRIPTION_EXPIRING' ||
        type == 'SUBSCRIPTION_EXPIRED' ||
        type == 'SUBSCRIPTION_REVOKED' ||
        type == 'CAPABILITIES_CHANGED') {
      _onSubscriptionEvent(type!, e);
      return;
    }

    final gid = _activeGroupId;
    if (gid == null) return;
    final convoy = _allConvoys[gid];

    switch (type) {
      case 'SNAPSHOT':
        if (e['convoy'] is Map) {
          final serverConvoy = ConvoyModel.fromJson(Map<String, dynamic>.from(e['convoy'] as Map));
          _mergeServerConvoy(serverConvoy);
        }
        _roomConfirmed = true;
        if (_serverBusyGid != null) {
          _serverBusyGid = null;
          if (_lastErrorIsServerBusy) {
            _lastError = null;
            _lastErrorIsServerBusy = false;
          }
        }
        // Back in the room after a dead zone or a restart: send the SOS that is still waiting,
        // then the outbox in order (the server ignores repeats by clientId).
        _sendPendingSos();
        _sendPendingResolves();
        _resetSendingItems();
        _flushOutbox();
        _maybeFetchRoadHistory();
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
      case 'ROLE_CHANGE':
        _onRoleChange(e);
        return;
      // 3.55 pillion seat (room PILLION_SEATED / PILLION_UNSEATED; the rider records follow as RIDER_UPDATE).
      case 'PILLION_SEATED':
      case 'PILLION_UNSEATED':
        _onPillionEvent(type!, e, gid);
        return;
      // 3.55 bike / pillion swap (personal SWAP_ASK / SWAP_RESULT, room SWAP_DONE).
      case 'SWAP_ASK':
      case 'SWAP_RESULT':
      case 'SWAP_DONE':
        _onSwapEvent(type!, e, gid);
        return;
      case 'AUTO_ROLES':
        if (convoy == null) return;
        _allConvoys[gid] = convoy.copyWith(autoRoles: e['autoRoles'] == true);
        break;
      case 'MIC_STATUS':
        if (convoy == null) return;
        final uid = e['userId']?.toString();
        final r = uid == null ? null : convoy.riders[uid];
        if (r == null) return;
        final updatedRider = r.copyWith(
          micMuted: e.containsKey('micMuted') ? (e['micMuted'] == true) : r.micMuted,
          isSpeaking: e.containsKey('isSpeaking') ? (e['isSpeaking'] == true) : r.isSpeaking,
        );
        final riders = Map<String, RiderModel>.from(convoy.riders)..[uid!] = updatedRider;
        _allConvoys[gid] = convoy.copyWith(riders: riders);
        break;
      case 'MESSAGE':
        if (convoy == null || e['message'] is! Map) return;
        final msg = GroupMessageModel.fromJson(Map<String, dynamic>.from(e['message'] as Map));
        final cid = e['clientId']?.toString() ?? (e['message'] is Map ? e['message']['clientId']?.toString() : null);
        if (convoy.messages.any((m) => m.messageId == msg.messageId || (cid != null && cid.isNotEmpty && m.messageId == cid))) return;
        final msgs = List<GroupMessageModel>.from(convoy.messages)..add(msg);
        if (msgs.length > 300) msgs.removeRange(0, msgs.length - 300);
        _allConvoys[gid] = convoy.copyWith(messages: msgs);
        _onIncomingChat(gid, msg); // 3.55 ride chat: spoken quick cards, text banner, unread badge
        break;
      case 'ALERT':
        if (convoy == null || e['alert'] is! Map) return;
        final alert = SosAlertModel.fromJson(Map<String, dynamic>.from(e['alert'] as Map));
        final pending = _pendingSos;
        if (pending != null && pending.matches(alert.clientId)) {
          // The server has it: delivered to the convoy. Never shown as delivered before this echo.
          DiagLog.warn(DiagCat.sos, 'ack', {'sinceRaiseMs': _clock() - pending.createdAt, 'sinceSendMs': _sosSentAt == 0 ? -1 : _clock() - _sosSentAt, 'type': pending.type});
          _pendingSos = null;
          _deliveredSosAlertId = alert.alertId;
          PendingSosStore.clear().ignore();
        }
        final others = convoy.activeAlerts.where((a) =>
            a.alertId != alert.alertId &&
            (alert.clientId.isEmpty || a.clientId != alert.clientId));
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
        if (_pendingResolves.remove(resolvedId) != null) _savePendingResolves();
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
      case 'ROAD_HAZARD':
        try {
          final obs = RoadHazardObservation.fromJson(e).copyWith(fromHistory: false);
          // 3.55: a live report replaces a saved one of the same kind at the same spot.
          _roadHazards.removeWhere((_, h) =>
              h.fromHistory && h.classification == obs.classification && GeoMath.haversine(h.lat, h.lng, obs.lat, obs.lng) <= 80);
          _roadHazards[obs.eventId] = obs;
          _networkRevision++;
          notifyListeners();
        } catch (_) {}
        break;
      case 'ROAD_HAZARD_ACK':
        // The gateway confirms ROAD_HAZARD with its own ACK (no clientId): the outbox item is done
        // (matched by hazard id, else the oldest one waiting; a merged report carries the saved id).
        _ackRoadHazard(e['hazardId']?.toString());
        return;
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
        _maybeFetchRoadHistory(); // 3.55: saved road reports along the new line
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
        _configPending?.cancel();
        _configPending = null;
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
          featurePolicy: e['featurePolicy'] is Map ? RideFeaturePolicy.fromJson(e['featurePolicy']) : null,
          // The host's seats: raised at once when the host upgrades during the ride.
          capacity: (e['capacity'] as num?)?.toInt(),
          // 3.56 access mode: the group features of this ride ('all' clears a limit).
          groupFeatures: e.containsKey('groupFeatures') ? ConvoyModel.groupFeaturesFromWire(e['groupFeatures']) : convoy.groupFeatures,
          // 3.55 fix: automatic roles ride in CONFIG too (a missed AUTO_ROLES is corrected by the
          // next CONFIG; it decides whether a front rider has lead rights, see canEditRoute).
          autoRoles: e['autoRoles'] is bool ? e['autoRoles'] as bool : null,
        );
        break;
      case 'TRIP_STATUS':
        final status = e['tripStatus']?.toString() ?? convoy?.tripStatus;
        if (convoy != null) {
          _allConvoys[gid] = convoy.copyWith(tripStatus: status);
        }
        if (status == 'ENDED') {
          if (convoy != null) {
            _onTripEnded(convoy.copyWith(tripStatus: 'ENDED'));
          } else {
            _dropActiveConvoyLocally();
          }
        } else if (status == 'STARTED' || status == 'PAUSED') {
          refreshEmergencyRoster().ignore();
        }
        break;
      case 'DISSOLVED':
        final c = activeConvoy;
        if (c != null) {
          _onTripEnded(c.copyWith(tripStatus: 'ENDED'));
        } else {
          _dropActiveConvoyLocally();
        }
        break;
      default:
        return;
    }
    notifyListeners();
  }

  /// `SUBSCRIPTION_ACTIVATED`, `SUBSCRIPTION_EXPIRING`, `SUBSCRIPTION_EXPIRED` and
  /// `SUBSCRIPTION_REVOKED` (legacy tiers, until the last one ends): the plan is re-read from
  /// the membership, which already counts a legacy tier until its end date.
  void _onSubscriptionEvent(String type, Map<String, dynamic> e) {
    onPlanChanged?.call();
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

  /// The gateway answered 409 RIDE_ENDED (the end was missed: dead zone, killed app). Checked with the
  /// server first (a late error from an earlier ride must not end this one); then ended like a normal
  /// end (trip saved) and [rideEndedNotice] is set so Home can say "This ride has ended".
  Future<void> _onRideEndedError() async {
    final gid = _activeGroupId;
    final convoy = gid == null ? null : _allConvoys[gid];
    if (gid == null || convoy == null || _confirmingMembership) return;
    _confirmingMembership = true;
    try {
      final res = await _api.get('/convoys/active');
      final c = res is Map ? res['convoy'] : null;
      if (c is Map && c['groupId'] == gid) {
        _rt.joinRoom(gid); // still live: an unrelated late error
        return;
      }
      if (_activeGroupId != gid || _disposed) return;
      _rideEndedNotice = true;
      _onTripEnded(convoy.copyWith(tripStatus: 'ENDED'));
    } catch (_) {
      // Offline: the next re-join answers it.
    } finally {
      _confirmingMembership = false;
    }
  }

  bool _rideEndedNotice = false;

  /// True after the gateway said the ride had already ended (shown once on Home).
  bool get rideEndedNotice => _rideEndedNotice;

  void clearRideEndedNotice() {
    if (!_rideEndedNotice) return;
    _rideEndedNotice = false;
    notifyListeners();
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
    if (_pendingResolves.isNotEmpty || _pendingResolvesGid != null) {
      _pendingResolves.clear();
      _pendingResolvesGid = null;
      _savePendingResolves();
    }
    _clearOutbox();
    _clearRoster();
    _clearNetwork();
    _writeRideAlive(false);
    if (_myUserId != null && convoy.riders.containsKey(_myUserId)) {
      _saveEndedTrip(convoy, _myUserId).ignore();
    }
    // 3.55 ride chat: the ride's messages stay on the phone for the trip summary.
    RideChatStore.archive(convoy.groupId, convoy.messages).ignore();
    _stopStatus();
    recorder?.stop().ignore();
    _syncTripsLater();
    BackgroundService.stop().ignore();
    stopRealGpsTracking();
    _compassSub?.cancel();
    _rt.leaveRoom();
    _activeGroupId = null;
    SharedPreferences.getInstance().then((p) => p.remove(AppConstants.keyActiveGroupId)).ignore();
    notifyListeners();
  }

  // ------------------------------------------------------- create / join
  /// 3.55: the active garage bike's colour, sent as the rider's vehicle colour when creating
  /// or joining a ride (empty: not sent; the gateway keeps its default). Set by GarageBinding.
  String vehicleColor = '';

  /// 3.55: the active garage bike's model ("Himalayan 450"), sent with create / join and with
  /// RIDER_VEHICLE ('' when none).
  String vehicleModel = '';

  /// 3.55 bike type id of the active garage bike ('' when none) and whether its details are
  /// complete; sent with create / join and RIDER_VEHICLE. Set by GarageBinding.
  String vehicleKind = '';
  bool bikeComplete = false;

  /// GarageBinding: the active bike's type and completeness changed.
  void setActiveBikeDetails(String kind, bool complete) {
    if (kind == vehicleKind && complete == bikeComplete) return;
    vehicleKind = kind;
    bikeComplete = complete;
    _syncVehicle();
  }

  Timer? _vehicleTimer;
  DateTime? _vehicleSentAt;

  /// The ride in which the gateway refused RIDER_VEHICLE for good (swapped bike, pillion, switch off).
  String? _vehicleBlockedGid;

  /// 3.55 live bike change: GarageBinding reports the active bike. Kept for the next create / join
  /// and, during a group ride on a gateway with 'vehicle1', sent at once as RIDER_VEHICLE so the
  /// group's maps show the new colour and model (at most one per 10 s: the latest bike is sent
  /// when the window has passed; offline, it is retried until the ride shows it).
  void setActiveVehicle(String colour, String model) {
    vehicleColor = colour;
    vehicleModel = RiderVehicle.cleanModel(model);
    _syncVehicle();
  }

  void _syncVehicle() {
    _vehicleTimer?.cancel();
    _vehicleTimer = null;
    if (_disposed) return;
    final c = activeConvoy;
    final me = c?.riders[_myUserId];
    if (c == null || me == null || c.isSoloRide || _vehicleBlockedGid == c.groupId) return;
    if (!_rt.supports(ProtocolFeatures.vehicle1) || !_featureOn('riderVehicleLive')) return;
    final msg = RiderVehicle.message(me: me, colour: vehicleColor, model: vehicleModel, kind: vehicleKind, complete: vehicleKind.isEmpty ? null : bikeComplete);
    if (msg == null) return;
    final wait = RiderVehicle.waitBeforeSend(_vehicleSentAt, DateTime.now());
    if (wait > Duration.zero || !_rt.send(msg)) {
      _vehicleTimer = Timer(wait > Duration.zero ? wait : RiderVehicle.rateWindow, _syncVehicle);
      return;
    }
    _vehicleSentAt = DateTime.now();
    // Not confirmed by a RIDER_UPDATE (lost on the way): check again after the window.
    _vehicleTimer = Timer(RiderVehicle.rateWindow + const Duration(seconds: 1), _syncVehicle);
  }

  /// A RIDER_VEHICLE refusal (no clientId): handled quietly, never shown as an error banner.
  bool _onVehicleRefused(String? reason) {
    final sent = _vehicleSentAt;
    if (sent == null || DateTime.now().difference(sent) > const Duration(seconds: 30)) return false;
    if (reason == 'VEHICLE_RATE') {
      _vehicleSentAt = DateTime.now();
      _vehicleTimer?.cancel();
      _vehicleTimer = Timer(RiderVehicle.rateWindow, _syncVehicle);
      return true;
    }
    if (RiderVehicle.isFinalRefusal(reason)) {
      _vehicleBlockedGid = _activeGroupId;
      _vehicleTimer?.cancel();
      _vehicleTimer = null;
      return true;
    }
    return false;
  }

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
    await _flushPendingLeaves();
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
        if (vehicleColor.isNotEmpty) 'vehicleColor': vehicleColor,
        if (vehicleModel.isNotEmpty) 'vehicleModel': vehicleModel,
        if (vehicleKind.isNotEmpty) 'vehicleKind': vehicleKind,
        if (vehicleKind.isNotEmpty) 'bikeComplete': bikeComplete,
      },
    });
    final convoy = ConvoyModel.fromJson(Map<String, dynamic>.from(res as Map));
    _myUserId ??= creatorId;
    _activate(convoy);
    return convoy;
  }

  Future<ConvoyModel?> joinConvoyByCode({required String code, required RiderModel rider}) =>
      _joinWith(rider, (body) => _api.post('/convoys/join', {'code': code.trim().toUpperCase(), ...body}));

  /// 3.55 "Start a ride with this crew": accepts a ride invite (POST /ride-invites/:id/accept). The
  /// gateway joins me through the normal join rules (seats of the host's plan, one active trip,
  /// bike details); no join code is needed or shown. Same errors and activation as [joinConvoyByCode].
  Future<ConvoyModel?> joinFromRideInvite({required String inviteId, required RiderModel rider}) => _joinWith(rider, (body) async {
        final res = await _api.post('/ride-invites/${Uri.encodeComponent(inviteId)}/accept', body);
        return res is Map && res['convoy'] is Map ? res['convoy'] : res;
      });

  Future<ConvoyModel?> _joinWith(RiderModel rider, Future<dynamic> Function(Map<String, dynamic> body) send) async {
    _lastError = null;
    _lastErrorIsServerBusy = false;
    try {
      await _refreshBatteryLevel();
      await _flushPendingLeaves();
      final res = await send({
        'rider': {
          'lat': rider.lat,
          'lng': rider.lng,
          'vehicleType': rider.vehicleType,
          'vehicleNo': rider.vehicleNo,
          'phone': rider.phone,
          'batteryLevel': _currentBatteryLevel,
          'isCharging': _isCharging,
          if (vehicleColor.isNotEmpty) 'vehicleColor': vehicleColor,
          if (vehicleModel.isNotEmpty) 'vehicleModel': vehicleModel,
          if (vehicleKind.isNotEmpty) 'vehicleKind': vehicleKind,
          if (vehicleKind.isNotEmpty) 'bikeComplete': bikeComplete,
        },
      });
      final convoy = ConvoyModel.fromJson(Map<String, dynamic>.from(res as Map));
      _myUserId ??= rider.userId;
      _activate(convoy);
      return convoy;
    } on ApiException catch (e) {
      if (e.isServerBusy) {
        // HTTP 503 SERVER_BUSY: plain words, the sheet offers "Try again". Nothing else changes.
        _lastError = ApiException.serverBusyMessage;
        _lastErrorIsServerBusy = true;
      } else if (e.code == 'ACTIVE_TRIP_CONFLICT') {
        _lastError = 'You are already in an active trip. Please end or leave your current trip first.';
      } else if (e.code == 'MEMBERSHIP_EXPIRED') {
        _lastError = PlanGateMessages.hostingNeedsGroupPlan;
      } else if (e.code == 'SOLO_TRIP_ONLY') {
        _lastError = PlanGateMessages.soloRideNoJoin;
      } else {
        _lastError = e.message;
      }
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
      _saveEndedTrip(convoy, userId).ignore();
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
    } on ApiException catch (e) {
      debugPrint('leave note: $e');
      // Not delivered (no signal, outage): the server would keep this rider in the ride and
      // refuse their next ride with ACTIVE_TRIP_CONFLICT. Sent again before the next create/join.
      if (e.isOffline || e.statusCode >= 500 || e.statusCode == 429) await _rememberPendingLeave(gid);
    } catch (e) {
      debugPrint('leave note: $e');
      await _rememberPendingLeave(gid);
    }
  }

  Future<void> _rememberPendingLeave(String gid) async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList(AppConstants.keyPendingLeaves) ?? <String>[];
      if (!list.contains(gid)) list.add(gid);
      await p.setStringList(AppConstants.keyPendingLeaves, list.length > 5 ? list.sublist(list.length - 5) : list);
    } catch (_) {}
  }

  /// Sends the leaves this phone could not deliver earlier. Each one that the server answered
  /// (ok, or any 4xx: the convoy is gone or the rider is no longer in it) is forgotten.
  Future<void> _flushPendingLeaves() async {
    SharedPreferences p;
    List<String> list;
    try {
      p = await SharedPreferences.getInstance();
      list = p.getStringList(AppConstants.keyPendingLeaves) ?? <String>[];
    } catch (_) {
      return;
    }
    if (list.isEmpty) return;
    final left = <String>[];
    var reachable = true;
    for (final gid in list) {
      if (gid == _activeGroupId) continue; // rejoined meanwhile: not left any more
      if (!reachable) {
        left.add(gid); // no signal: do not wait for each one in turn
        continue;
      }
      try {
        await _api.post('/convoys/$gid/leave', null, const Duration(seconds: 8));
      } on ApiException catch (e) {
        if (e.isOffline || e.statusCode >= 500 || e.statusCode == 429) {
          left.add(gid);
          reachable = false;
        }
      } catch (_) {
        left.add(gid);
        reachable = false;
      }
    }
    try {
      if (left.isEmpty) {
        await p.remove(AppConstants.keyPendingLeaves);
      } else {
        await p.setStringList(AppConstants.keyPendingLeaves, left);
      }
    } catch (_) {}
  }

  /// Two-Role Trip Governance: Trip Owner assigns Trip Head.
  Future<bool> setTripHead(String targetUserId) async {
    final gid = _activeGroupId;
    if (gid == null) return false;
    try {
      await _api.post('/convoys/$gid/trip-head', {'targetUserId': targetUserId});
      return true;
    } catch (e) {
      debugPrint('[convoy_service] setTripHead error: $e');
      if (e is ApiException) _lastError = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Two-Role Trip Governance: Trip Owner removes a participant from the active trip.
  Future<bool> removeParticipant(String targetUserId) async {
    final gid = _activeGroupId;
    if (gid == null) return false;
    try {
      await _api.delete('/convoys/$gid/riders/$targetUserId');
      return true;
    } catch (e) {
      debugPrint('[convoy_service] removeParticipant error: $e');
      if (e is ApiException) _lastError = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Update trip status ('PAUSED', 'STARTED', 'ENDED')
  Future<bool> updateTripStatus(String status) async {
    final gid = _activeGroupId;
    if (gid == null) return false;
    try {
      await _api.post('/convoys/$gid/status', {'status': status});
      return true;
    } catch (e) {
      debugPrint('[convoy_service] updateTripStatus error: $e');
      if (e is ApiException) _lastError = e.message;
      if (e is ApiException && e.statusCode == 409 && e.code == 'RIDE_ENDED') {
        _lastError = 'This ride has ended.';
        _onRideEndedError().ignore();
      }
      notifyListeners();
      return false;
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

  /// The GPS subscription for the current state: navigation-grade, frequent fixes while riding
  /// fast; gentler when slow, parked ([idle]) or on [lowBattery] ([LocationCadence]).
  LocationSettings _settingsFor({required bool idle, bool lowBattery = false, SpeedBand? band}) {
    final plan = LocationCadence.plan(band ?? _gpsBand.band, idle: idle, lowBattery: lowBattery);
    final accuracy = switch (plan.precision) {
      GpsPrecision.low => LocationAccuracy.low,
      GpsPrecision.medium => LocationAccuracy.medium,
      GpsPrecision.high => LocationAccuracy.high,
      GpsPrecision.navigation => LocationAccuracy.bestForNavigation,
    };
    if (!kIsWeb && Platform.isAndroid) {
      // Background access is granted by the app's foreground service (BackgroundService), so
      // geolocator does not need its own notification here.
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: plan.distanceFilterM,
        intervalDuration: plan.interval,
      );
    }
    if (!kIsWeb && Platform.isIOS) {
      // Riding: Core Location's vehicle navigation mode, and never paused by iOS mid-ride.
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: plan.distanceFilterM,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
      );
    }
    return LocationSettings(accuracy: accuracy, distanceFilter: plan.distanceFilterM);
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
    _gpsBand.reset();
    _speedEst.reset();
    _subscribeGps();
    _isRealGpsActive = true;
    _lastGpsFixTime = DateTime.now().millisecondsSinceEpoch;

    // Ensure the persistent foreground service keeps GPS alive in the background
    final cName = activeConvoy?.name ?? 'Active Ride';
    final count = activeConvoy?.riders.length ?? 1;
    BackgroundService.start(convoyName: cName, riderCount: count).ignore();
    BackgroundService.requestIgnoreBatteryOptimization().ignore();

    _deadReckoningTimer?.cancel();
    _deadReckoningTimer = Timer.periodic(const Duration(seconds: 1), (t) => _onDeadReckoningTick(t));

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
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: _settingsFor(idle: _gpsIdleProfile, lowBattery: batterySaverActive),
    ).listen(_onPosition, onError: (e) {
      debugPrint('GPS stream note: $e');
    });
  }

  void feedAccelerometer(AccelBucket bucket) {
    _deadReckoning.checkAccelerometer(bucket);
  }

  void _subscribeAccelForDeadReckoning() {
    if (_deadReckoningAccelSub != null) return;
    final source = _accel;
    if (source != null) {
      _deadReckoningAccelSub = source.buckets().listen((bucket) {
        feedAccelerometer(bucket);
      }, onError: (_) {
        _deadReckoningAccelSub?.cancel();
        _deadReckoningAccelSub = null;
      });
    }
  }

  void _unsubscribeAccelForDeadReckoning() {
    _deadReckoningAccelSub?.cancel();
    _deadReckoningAccelSub = null;
  }

  void _onDeadReckoningTick([Timer? timer, int? overrideNowMs]) {
    if (!_isRealGpsActive && timer != null) return;
    // Battery: parked (idle GPS profile) and not coasting: nothing to estimate this second.
    if (timer != null && _gpsIdleProfile && !_deadReckoning.isCoasting && !_deadReckoning.isConverging) return;
    final userId = _myUserId;
    final convoy = activeConvoy;
    if (userId == null || convoy == null) return;
    final me = convoy.riders[userId];
    if (me == null) return;
    final now = overrideNowMs ?? _clock();

    if (convoy.routeLine.isNotEmpty) {
      _deadReckoning.setPlannedRoute(convoy.routeLine);
    }

    if (_deadReckoning.isCoasting) {
      final fix = _deadReckoning.computeFix(now);
      final coastKmh = _coastingSpeedKmh(fix.speedKmh, crashStop: fix.isCrashStop, nowMs: now);
      final coastingFix = TrackPoint(
        ts: now,
        lat: fix.lat,
        lng: fix.lng,
        speedKmh: coastKmh,
        accuracyM: 80.0,
      );
      recorder?.onFix(coastingFix, estimated: true); // projected along the plan: never part of the track
      if (_myFixes.hasListener) _myFixes.add(coastingFix);

      final updated = me.copyWith(
        lat: fix.lat,
        lng: fix.lng,
        speedKmh: coastKmh,
        heading: fix.heading,
        lastSeenEpochMs: now,
        trackingConfidence: fix.confidence,
        stoppedSince: fix.isCrashStop ? (me.stoppedSince > 0 ? me.stoppedSince : now) : 0,
      );
      _setMyRiderLocally(updated);
      _pushTelemetry(updated);
      return;
    }

    if (_deadReckoning.isConverging) {
      final point = _deadReckoning.computeConvergence(now);
      final convFix = TrackPoint(
        ts: now,
        lat: point.lat,
        lng: point.lng,
        speedKmh: point.speedKmh,
        accuracyM: 20.0,
      );
      recorder?.onFix(convFix, estimated: true); // blend between the estimate and GPS: never part of the track
      if (_myFixes.hasListener) _myFixes.add(convFix);

      final updated = me.copyWith(
        lat: point.lat,
        lng: point.lng,
        speedKmh: point.speedKmh,
        heading: point.heading,
        lastSeenEpochMs: now,
        trackingConfidence: TrackingConfidence.gpsFix,
      );
      _setMyRiderLocally(updated);
      _pushTelemetry(updated);
      return;
    }

    if (_lastGpsFixTime > 0) {
      final fixAgeSec = (now - _lastGpsFixTime) / 1000.0;
      final accuracy = _lastFixAccuracyM ?? 999.0;
      final hasActiveRoute = convoy.routeLine.length >= 2;
      if (DeadReckoningEngine.shouldInitiateCoasting(
        fixAgeSec: fixAgeSec,
        accuracyM: accuracy,
        lat: me.lat,
        lng: me.lng,
        speedKmh: me.speedKmh,
        hasActiveRoute: hasActiveRoute,
      )) {
        _startCoasting(me, now);
      }
    }
  }

  /// Speed while coasting: degraded fixes (accuracy > 50 m: trees, city) still carry a good
  /// Doppler speed, so a fresh estimate (< 2.5 s) wins over the frozen entry speed; in a real
  /// tunnel there are no fixes and the projection's speed is used. A crash stop is always 0.
  double _coastingSpeedKmh(double projectedKmh, {required bool crashStop, required int nowMs}) {
    if (crashStop) return projectedKmh;
    final fresh = _speedEst.hasEstimate &&
        _speedEst.source == SpeedSource.doppler &&
        nowMs - _speedEst.lastFixMs <= 2500;
    return fresh ? _speedEst.kmh : projectedKmh;
  }

  void _startCoasting(RiderModel rider, int nowMs) {
    _deadReckoning.startCoasting(
      lat: rider.lat,
      lng: rider.lng,
      speedKmh: rider.speedKmh,
      heading: rider.heading,
      timestampMs: nowMs,
    );
    _subscribeAccelForDeadReckoning();
    final fix = _deadReckoning.computeFix(nowMs);
    final coastingFix = TrackPoint(
      ts: nowMs,
      lat: fix.lat,
      lng: fix.lng,
      speedKmh: fix.speedKmh,
      accuracyM: 80.0,
    );
    recorder?.onFix(coastingFix, estimated: true); // projected along the plan: never part of the track
    if (_myFixes.hasListener) _myFixes.add(coastingFix);

    final updated = rider.copyWith(
      lat: fix.lat,
      lng: fix.lng,
      speedKmh: fix.speedKmh,
      heading: fix.heading,
      lastSeenEpochMs: nowMs,
      trackingConfidence: fix.confidence,
      stoppedSince: 0,
    );
    _setMyRiderLocally(updated);
    _pushTelemetry(updated);
  }

  void triggerCoasting({double? lat, double? lng, double? speedKmh, double? heading, int? timestampMs}) {
    final userId = _myUserId;
    final me = userId != null ? activeConvoy?.riders[userId] : null;
    final now = timestampMs ?? _clock();
    _startCoasting(
      me != null
          ? me.copyWith(
              lat: lat ?? me.lat,
              lng: lng ?? me.lng,
              speedKmh: speedKmh ?? me.speedKmh,
              heading: heading ?? me.heading,
            )
          : RiderModel(
              userId: userId ?? 'me',
              name: 'Me',
              lat: lat ?? 32.3639,
              lng: lng ?? 77.1462,
              speedKmh: speedKmh ?? 60.0,
              heading: heading ?? 10.0,
              lastSeenEpochMs: now,
            ),
      now,
    );
  }

  void triggerConvergence({required double gpsLat, required double gpsLng, double? speedKmh, double? heading, int? nowMs}) {
    final now = nowMs ?? _clock();
    _deadReckoning.startConvergence(
      gpsLat: gpsLat,
      gpsLng: gpsLng,
      gpsSpeedKmh: speedKmh ?? 60.0,
      gpsHeading: heading ?? 10.0,
      nowMs: now,
      durationMs: 4000,
    );
    _unsubscribeAccelForDeadReckoning();
    final point = _deadReckoning.computeConvergence(now);
    final userId = _myUserId;
    final current = userId != null ? activeConvoy?.riders[userId] : null;
    if (current != null) {
      final updated = current.copyWith(
        lat: point.lat,
        lng: point.lng,
        speedKmh: point.speedKmh,
        heading: point.heading,
        lastSeenEpochMs: now,
        trackingConfidence: TrackingConfidence.gpsFix,
      );
      _setMyRiderLocally(updated);
      _pushTelemetry(updated);
    }
  }

  void tickDeadReckoning([int? nowMs]) {
    _onDeadReckoningTick(null, nowMs);
  }

  void _onPosition(Position position) {
    final userId = _myUserId;
    final convoy = activeConvoy;
    if (userId == null || convoy == null) return;
    final current = convoy.riders[userId];
    final now = position.timestamp.millisecondsSinceEpoch;
    // Every fix, even a degraded one, goes through the estimator (it weighs and rejects by itself).
    final est = _speedEst.update(speedFixOf(position));
    final speedKmh = est.kmh.clamp(0.0, 300.0).toDouble();
    // 3.55 diagnostics: fix cadence / accuracy every 30 s; speed outliers (sampled).
    DiagLog.gpsFix(tMs: now, accuracyM: position.accuracy, rejected: est.rejected, kmh: speedKmh, lat: position.latitude, lng: position.longitude);
    if (est.rejected && DiagLog.sampler.take('speed_outlier', now)) {
      DiagLog.info(DiagCat.speed, 'speed_outlier', {'filtered': est.filteredKmh, 'source': est.source, 'acc': position.accuracy, 'gpsSpeed': position.speed * 3.6});
    }
    // Speed-adaptive GPS cadence: the faster the ride, the more often and finer the fixes. The band
    // has hysteresis and a dwell time, so the stream is re-subscribed only on a real change.
    if (_gpsBand.update(speedKmh, _clock()) && _isRealGpsActive && !_gpsIdleProfile) _subscribeGps();
    final accuracy = position.accuracy.isFinite ? position.accuracy : 999.0;
    final gpsHeading = position.heading.isFinite ? position.heading.clamp(0.0, 360.0).toDouble() : 0.0;
    final hasActiveRoute = convoy.routeLine.length >= 2;

    if (convoy.routeLine.isNotEmpty) {
      _deadReckoning.setPlannedRoute(convoy.routeLine);
    }

    // 1. If currently coasting:
    if (_deadReckoning.isCoasting) {
      if (accuracy <= 50.0) {
        // GPS re-acquired upon tunnel exit!
        // Apply ConvergencePoint to smoothly interpolate from coasted coordinate to real GPS fix over 3-5 seconds.
        _deadReckoning.startConvergence(
          gpsLat: position.latitude,
          gpsLng: position.longitude,
          gpsSpeedKmh: speedKmh,
          gpsHeading: gpsHeading,
          nowMs: now,
          durationMs: 4000,
        );
        _unsubscribeAccelForDeadReckoning();
        _lastGpsFixTime = now;
        _lastFixAccuracyM = accuracy;
        final point = _deadReckoning.computeConvergence(now);
        final fix = TrackPoint(
          ts: now,
          lat: point.lat,
          lng: point.lng,
          speedKmh: point.speedKmh,
          accuracyM: accuracy,
        );
        // The track records the real GPS fix; the blended position only moves the marker smoothly.
        recorder?.onFix(TrackPoint(ts: now, lat: position.latitude, lng: position.longitude, speedKmh: speedKmh, accuracyM: accuracy));
        if (_myFixes.hasListener) _myFixes.add(fix);
        final base = current ?? RiderModel(userId: userId, name: 'Rider', lat: point.lat, lng: point.lng, lastSeenEpochMs: now);
        final updated = base.copyWith(
          lat: point.lat,
          lng: point.lng,
          speedKmh: point.speedKmh,
          heading: point.heading,
          batteryLevel: _currentBatteryLevel,
          isCharging: _isCharging,
          lastSeenEpochMs: now,
          trackingConfidence: TrackingConfidence.gpsFix,
        );
        _setMyRiderLocally(updated);
        _pushTelemetry(updated);
        return;
      } else {
        // Still degraded inside tunnel/shadow, continue coasting
        return;
      }
    }

    // 2. If converging:
    if (_deadReckoning.isConverging) {
      if (accuracy <= 50.0) {
        _lastGpsFixTime = now;
        _lastFixAccuracyM = accuracy;
        _deadReckoning.updateConvergenceTarget(
          gpsLat: position.latitude,
          gpsLng: position.longitude,
          gpsSpeedKmh: speedKmh,
          gpsHeading: gpsHeading,
        );
        final point = _deadReckoning.computeConvergence(now);
        final fix = TrackPoint(
          ts: now,
          lat: point.lat,
          lng: point.lng,
          speedKmh: point.speedKmh,
          accuracyM: accuracy,
        );
        // The track records the real GPS fix; the blended position only moves the marker smoothly.
        recorder?.onFix(TrackPoint(ts: now, lat: position.latitude, lng: position.longitude, speedKmh: speedKmh, accuracyM: accuracy));
        if (_myFixes.hasListener) _myFixes.add(fix);
        final base = current ?? RiderModel(userId: userId, name: 'Rider', lat: point.lat, lng: point.lng, lastSeenEpochMs: now);
        final updated = base.copyWith(
          lat: point.lat,
          lng: point.lng,
          speedKmh: point.speedKmh,
          heading: point.heading,
          batteryLevel: _currentBatteryLevel,
          isCharging: _isCharging,
          lastSeenEpochMs: now,
          trackingConfidence: TrackingConfidence.gpsFix,
        );
        _setMyRiderLocally(updated);
        _pushTelemetry(updated);
        return;
      }
    }

    // 3. Not coasting & not converging: check if coasting should initiate
    if (DeadReckoningEngine.shouldInitiateCoasting(
      fixAgeSec: 0.0,
      accuracyM: accuracy,
      lat: position.latitude,
      lng: position.longitude,
      speedKmh: speedKmh,
      hasActiveRoute: hasActiveRoute,
    )) {
      _startCoasting(current ?? RiderModel(userId: userId, name: 'Rider', lat: position.latitude, lng: position.longitude, lastSeenEpochMs: now), now);
      return;
    }

    _lastGpsFixTime = now;
    _lastFixAccuracyM = accuracy;
    final fix = TrackPoint(
      ts: now,
      lat: position.latitude,
      lng: position.longitude,
      speedKmh: speedKmh,
      accuracyM: accuracy,
      // 3.55 high-altitude care (phone only; 0 = the phone has no altitude).
      altM: position.altitude.isFinite && position.altitude != 0 ? position.altitude : null,
    );
    recorder?.onFix(fix);
    if (_myFixes.hasListener) _myFixes.add(fix);
    final gpsHeadingDeg = gpsHeading;
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
      // Throttle GPS polling when stationary: switch to the idle profile after 90 s (low battery) or
      // 3 min (normal). 3.55 alert latency review: was 30 s / 60 s, shorter than many Indian red
      // lights and railway gates: the idle profile (20 s, 25 m filter, network accuracy) then
      // delayed the first riding fix by several seconds after every long light (speed readout,
      // overspeed, hazards ahead) and left the rider-down check without fresh fixes at a stop.
      final stationaryThreshold = batterySaverActive ? const Duration(seconds: 90) : const Duration(minutes: 3);
      if (!_gpsIdleProfile && DateTime.now().difference(_stationarySince!) >= stationaryThreshold) {
        _gpsIdleProfile = true;
        _subscribeGps();
        // Sensor stream optimization: pause dead reckoning accelerometer while stationary
        _unsubscribeAccelForDeadReckoning();
      }
    }

    // Sensor fusion: GPS course when moving, magnetometer when (nearly) stopped.
    double fusedHeading = current?.heading ?? 0.0;
    if (speedKmh >= 10.0 && gpsHeadingDeg > 0) {
      fusedHeading = gpsHeadingDeg;
    } else if (_deviceCompassHeading != null) {
      fusedHeading = _deviceCompassHeading!;
    } else if (gpsHeadingDeg > 0) {
      fusedHeading = gpsHeadingDeg;
    }

    final wasStopped = current?.statusReason.isNotEmpty == true;
    final base = current ??
        RiderModel(userId: userId, name: 'Rider', lat: position.latitude, lng: position.longitude, lastSeenEpochMs: now);
    final isLimpMode = base.statusReason == 'MECHANICAL' || base.statusReason == 'FLAT_TIRE';
    final shouldClearStatus = isMoving && wasStopped && (!isLimpMode || speedKmh >= 25.0);
    final updated = base.copyWith(
      lat: position.latitude,
      lng: position.longitude,
      speedKmh: speedKmh,
      heading: fusedHeading,
      batteryLevel: _currentBatteryLevel,
      isCharging: _isCharging,
      lastSeenEpochMs: now,
      statusReason: shouldClearStatus ? '' : base.statusReason,
      statusMessage: shouldClearStatus ? '' : base.statusMessage,
      stoppedSince: isMoving ? 0 : (base.stoppedSince != 0 ? base.stoppedSince : now),
      trackingConfidence: TrackingConfidence.gpsFix,
    );

    // Local UI updates immediately; the network push is throttled.
    _setMyRiderLocally(updated);
    final since = DateTime.now().difference(_lastTelemetryPush);
    final movedFar = current == null ||
        Geolocator.distanceBetween(current.lat, current.lng, position.latitude, position.longitude) > 40;
    final critical = convoy.activeAlerts.isNotEmpty || assistRequests.isNotEmpty || hazards.isNotEmpty;
    // Faster riders report more often (smooth markers for the group), never near the gateway's
    // 3 TELEMETRY/s limit, and slower in big groups (fan-out), data saver or battery saving.
    final interval = LocationCadence.telemetryInterval(
      _gpsBand.band,
      base: _power.telemetryInterval(moving: isMoving, lowData: settings?.lowData ?? false, critical: critical),
      moving: isMoving,
      lowData: (settings?.lowData ?? false) || _power.conserving || isLowBattery ||
          BatterySaverProfile.slowTelemetry(batterySaver, critical: critical),
      groupSize: convoy.riders.length,
    );
    if (since >= interval || movedFar || shouldClearStatus) {
      _pushTelemetry(updated);
    }
  }

  void _setMyRiderLocally(RiderModel rider) {
    final gid = _activeGroupId;
    final convoy = gid != null ? _allConvoys[gid] : null;
    if (convoy == null) return;
    _allConvoys[gid!] = convoy.copyWith(riders: Map<String, RiderModel>.from(convoy.riders)..[rider.userId] = rider);
    final hasActiveSos = convoy.activeAlerts.any((a) => a.userId == rider.userId && !a.resolved);
    mesh?.updateMyTelemetry(
      lat: rider.lat,
      lng: rider.lng,
      speedKmh: rider.speedKmh,
      heading: rider.heading,
      batteryLevel: _currentBatteryLevel,
      isCharging: _isCharging,
      role: rider.role,
      isSos: hasActiveSos,
      fuelUsableKm: rider.fuelUsableKm,
    );
    notifyListeners();
  }

  /// Only an opted-in usable range, never tank contents or mileage.
  Map<String, dynamic>? Function()? fuelEstimate;

  /// 3.55 group break planner: this phone's fatigue level 0..3 (null = not shared). Only the level
  /// is ever sent, never the signals behind it. Set by GroupSafetyService.
  int? Function()? fatigueLevel;
  void refreshFuelSharing() {
    final uid = _myUserId;
    final me = uid == null ? null : activeConvoy?.riders[uid];
    if (me != null) _pushTelemetry(me);
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
    final hasActiveSos = activeConvoy?.activeAlerts.any((a) => a.userId == r.userId && !a.resolved) ?? false;
    mesh?.updateMyTelemetry(
      lat: r.lat,
      lng: r.lng,
      speedKmh: r.speedKmh,
      heading: r.heading,
      batteryLevel: _currentBatteryLevel,
      isCharging: _isCharging,
      role: r.role,
      isSos: hasActiveSos,
      fuelUsableKm: r.fuelUsableKm,
    );
    _rt.send({
      'type': 'TELEMETRY',
      'fuelEstimate': activeConvoy?.featurePolicy.groupFuelEnabled == false ? null : fuelEstimate?.call(),
      'lat': r.lat,
      'lng': r.lng,
      'speedKmh': double.parse(r.speedKmh.toStringAsFixed(1)),
      'heading': double.parse(r.heading.toStringAsFixed(0)),
      'batteryLevel': _currentBatteryLevel,
      'isCharging': _isCharging,
      'statusReason': r.statusReason,
      'statusMessage': r.statusMessage,
      'stoppedSince': r.stoppedSince,
      'trackingConfidence': r.trackingConfidence.toWire(),
      'isCoasting': r.isTunnelCoasting,
      'fatigueLevel': ?fatigueLevel?.call(),
    });
  }

  void stopRealGpsTracking() {
    _gpsSub?.cancel();
    _gpsSub = null;
    _idleHeartbeat?.cancel();
    _deadReckoningTimer?.cancel();
    _deadReckoningTimer = null;
    _unsubscribeAccelForDeadReckoning();
    _deadReckoning.onGpsRecovered();
    _isRealGpsActive = false;
    mesh?.stop().ignore();
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
      final prevLevel = _currentBatteryLevel;
      final prevLow = isLowBattery;
      _currentBatteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      _isCharging = state == BatteryState.charging || state == BatteryState.full;
      final before = _power.conserving;
      _power.updateBattery(_currentBatteryLevel, charging: _isCharging);

      final nowLow = isLowBattery;
      if (nowLow != prevLow) {
        _applyLowBatteryPolicy(nowLow);
      }

      // Record battery measurement for per-riding-hour tracking
      final me = activeConvoy?.riders[_myUserId];
      final isMoving = (me?.speedKmh ?? 0) > 1.0;
      batteryMonitor.recordSample(
        batteryLevel: _currentBatteryLevel,
        isCharging: _isCharging,
        isMoving: isMoving,
        speedKmh: me?.speedKmh ?? 0.0,
      );

      if (before != _power.conserving || prevLow != nowLow || prevLevel != _currentBatteryLevel) {
        notifyListeners();
      }
      _syncBatterySaver();
    } catch (_) {}
  }

  void _applyLowBatteryPolicy(bool lowBattery) {
    // The rider's battery saver switch counts as low battery for these levers too.
    lowBattery = lowBattery || (settings?.batterySaver ?? false);
    tilePrefetcher?.handleLowBattery(lowBattery);
    mesh?.setLowBatteryMode(lowBattery);
    if (_isRealGpsActive) {
      _subscribeGps();
    }
  }

  @visibleForTesting
  void updateBatteryForTesting(int percent, {required bool isCharging}) {
    final prevLow = isLowBattery;
    _currentBatteryLevel = percent;
    _isCharging = isCharging;
    _power.updateBattery(percent, charging: isCharging);
    final nowLow = isLowBattery;
    if (nowLow != prevLow) {
      _applyLowBatteryPolicy(nowLow);
    }
    final me = activeConvoy?.riders[_myUserId];
    final isMoving = (me?.speedKmh ?? 0) > 1.0;
    batteryMonitor.recordSample(
      batteryLevel: percent,
      isCharging: isCharging,
      isMoving: isMoving,
      speedKmh: me?.speedKmh ?? 0.0,
    );
    notifyListeners();
  }

  @visibleForTesting
  LocationSettings settingsForTesting({required bool idle, bool lowBattery = false, SpeedBand? band}) =>
      _settingsFor(idle: idle, lowBattery: lowBattery, band: band);

  /// The current GPS speed band (cadence), for diagnostics and tests.
  SpeedBand get gpsSpeedBand => _gpsBand.band;

  @visibleForTesting
  bool get isGpsIdleProfile => _gpsIdleProfile;

  @visibleForTesting
  bool get isDeadReckoningAccelSubscribed => _deadReckoningAccelSub != null;

  @visibleForTesting
  void setStationarySinceForTesting(DateTime? dt) {
    _stationarySince = dt;
  }

  @visibleForTesting
  void handlePositionForTesting(Position pos) {
    _onPosition(pos);
  }

  @visibleForTesting
  void subscribeAccelForTesting() {
    _subscribeAccelForDeadReckoning();
  }

  // --------------------------------------------------------------- actions
  void sendGroupMessage({
    required String senderId,
    required String senderName,
    required String text,
    String? groupId,
    bool isQuickCard = false,
    String cardType = 'CUSTOM',
  }) {
    final gid = groupId ?? _activeGroupId;
    if (gid == null || text.trim().isEmpty) return;
    // Messages are a group feature: a solo ride (Community host) has nobody to message.
    if (_allConvoys[gid]?.isSoloRide == true) return;
    _enqueue('CHAT', {'text': text.trim(), 'isQuickCard': isQuickCard, 'cardType': cardType, 'sentAt': _clock()}, targetGroupId: gid);
  }

  // ------------------------------------------------------------ 3.55 ride chat
  // docs/features_355/ride_chat.md. Rules in lib/domain/ride/ride_chat.dart (pure).

  final ChatUnread _chatUnread = ChatUnread();
  Set<String> _chatHidden = <String>{};
  List<String> _quickOrder = const [];
  GroupMessageModel? _chatBanner;
  Timer? _chatBannerClear;
  String? _chatOpenGid;

  /// True while the rider is moving (the cockpit sets it to its RideTapGate). Null: my speed.
  bool Function()? rideMoving;

  /// How long a text message banner stays.
  static const Duration chatBannerFor = Duration(seconds: 8);

  bool get _chatMovingNow {
    final hook = rideMoving;
    if (hook != null) return hook();
    final me = activeConvoy?.riders[_myUserId];
    return me != null && !RideChat.canTypeAt(speedKmh: me.speedKmh);
  }

  /// Typing is shown in the chat: stopped, or riding pillion (someone else rides). While moving
  /// only the one-tap quick actions.
  bool get chatCanType {
    final me = activeConvoy?.riders[_myUserId];
    if (me?.isCoRiding == true) return true;
    return !_chatMovingNow;
  }

  Future<void> _loadChatPrefs() async {
    try {
      _quickOrder = await RideChatStore.loadOrder();
      _chatHidden = {..._chatHidden, ...await RideChatStore.loadHidden()};
      _chatUnread.load(await RideChatStore.loadSeen());
      notifyListeners();
    } catch (_) {}
  }

  /// The quick actions in the rider's order.
  List<RideQuickAction> get quickActions => RideChat.ordered(_quickOrder);

  /// Saves a new quick action order (ids of [RideChat.actions]).
  void setQuickActionOrder(List<String> ids) {
    _quickOrder = [for (final a in RideChat.ordered(ids)) a.id];
    RideChatStore.saveOrder(_quickOrder).ignore();
    notifyListeners();
  }

  /// Riders whose chat messages are hidden on this phone.
  Set<String> get chatHidden => Set.unmodifiable(_chatHidden);

  void setChatHidden(String userId, bool hidden) {
    if (userId.isEmpty || userId == _myUserId) return;
    final next = {..._chatHidden};
    hidden ? next.add(userId) : next.remove(userId);
    _chatHidden = next;
    RideChatStore.saveHidden(next).ignore();
    if (hidden && _chatBanner?.authorId == userId) _chatBanner = null;
    notifyListeners();
  }

  /// The ride's messages to show (hidden riders removed), oldest first.
  List<GroupMessageModel> visibleMessages(String gid) =>
      ChatRules.visible(_allConvoys[gid]?.messages ?? const <GroupMessageModel>[], (m) => m.authorId, _chatHidden);

  /// Unread messages from others in [gid] (badge on the Chat button).
  int unreadChat(String gid) {
    if (_chatOpenGid == gid) return 0;
    final uid = _myUserId ?? '';
    return _chatUnread.count(gid, [for (final m in _allConvoys[gid]?.messages ?? const <GroupMessageModel>[]) m.toLine()], myUserId: uid, hidden: _chatHidden);
  }

  /// The chat sheet of [gid] is open (null: closed): everything there counts as read.
  void setChatOpen(String? gid) {
    if (_disposed) return;
    final was = _chatOpenGid;
    _chatOpenGid = gid;
    final g = gid ?? was;
    if (g != null) markChatSeen(g);
    if (gid != null) _chatBanner = null;
    notifyListeners();
  }

  void markChatSeen(String gid) {
    final msgs = _allConvoys[gid]?.messages ?? const <GroupMessageModel>[];
    final last = msgs.isEmpty ? 0 : msgs.map((m) => m.timestamp).reduce((a, b) => a > b ? a : b);
    final before = _chatUnread.seenAt(gid);
    _chatUnread.markSeen(gid, last);
    if (_chatUnread.seenAt(gid) != before) RideChatStore.saveSeen(_chatUnread.toJson()).ignore();
  }

  /// The newest text message from another rider, for a banner (8 s; null when none).
  GroupMessageModel? get chatBanner => _chatBanner;

  void dismissChatBanner() {
    _chatBannerClear?.cancel();
    _chatBanner = null;
    notifyListeners();
  }

  void _onIncomingChat(String gid, GroupMessageModel msg) {
    if (gid != _activeGroupId) return;
    // One notice per message, whichever way it arrives (socket echo, peer gateway, restore).
    if (!NoticeDedupe.shared.firstTime('CHAT:${msg.messageId}')) return;
    // Old messages replayed after a reconnect are not announced.
    if (_clock() - msg.timestamp > const Duration(minutes: 2).inMilliseconds) return;
    final notice = ChatRules.decide(msg.toLine(), myUserId: _myUserId ?? '', moving: _chatMovingNow, hidden: _chatHidden, emergency: _emergencyOpen);
    if (notice.isNone) return;
    final line = notice.speech;
    if (line != null) _say(line, 'CHAT:${msg.messageId}');
    if (notice.banner && _chatOpenGid != gid) {
      _chatBanner = msg;
      _chatBannerClear?.cancel();
      _chatBannerClear = Timer(chatBannerFor, () {
        _chatBanner = null;
        notifyListeners();
      });
    }
  }

  /// Sends a quick action to the ride: "Wait for me" is a wait request (the gateway posts the chat
  /// card), the others a chat line marked as a quick card. Both wait in the outbox without signal.
  bool sendQuickAction(RideQuickAction a, {String? groupId}) {
    final gid = groupId ?? _activeGroupId;
    final me = gid == null ? null : _allConvoys[gid]?.riders[_myUserId];
    if (gid == null || _myUserId == null) return false;
    if (_allConvoys[gid]?.isSoloRide == true) return false;
    if (a.isWait) {
      if (gid != _activeGroupId) return false;
      requestWait(me?.name ?? 'Rider');
    } else {
      sendGroupMessage(groupId: gid, senderId: _myUserId!, senderName: me?.name ?? 'Rider', text: a.text, isQuickCard: true, cardType: a.cardType);
    }
    return true;
  }

  /// Reports a chat message to the CoRoute team (gateway CHAT_REPORT, reviewed with the public
  /// ride reports). Optionally hides the sender's messages on this phone too. False when offline.
  bool reportChatMessage(GroupMessageModel m, {String reason = 'ABUSE', bool hide = false}) {
    if (hide) setChatHidden(m.authorId, true);
    if (!_rt.isConnected || _activeGroupId == null) return false;
    return _rt.send({'type': 'CHAT_REPORT', 'messageId': m.messageId, 'reason': reason});
  }

  void requestWait(String requesterName) {
    if (_activeGroupId == null) return;
    // "Wait for me" asks the group: nothing to ask in a solo ride.
    if (activeConvoy?.isSoloRide == true) return;
    _enqueue('WAIT', {});
  }

  void addStopPoint({required String name, required double lat, required double lng, String category = 'REST'}) {
    if (_activeGroupId == null) return;
    _rt.send({'type': 'STOP_ADD', 'name': name, 'lat': lat, 'lng': lng, 'category': category});
  }

  // ------------------------------------------------------ route planning
  /// True when this rider has lead rights (route, stops, pause / resume, riding roles, regroup,
  /// buddy pairs): the trip owner or a Lead the owner picked. Same rule as the gateway's isLead().
  bool get canEditRoute {
    final c = activeConvoy;
    final uid = myUserId;
    if (c == null || uid == null) return false;
    // 3.55: an automatic (front-rider) lead has no lead rights. 3.55 owner decision (Nov 9): the
    // trip head is not here (settings only, see canChangeGroupSettings); a trip head who rides as
    // the picked Lead has these rights by that riding role.
    return c.createdByUserId == uid || c.tripOwnerUserId == uid || (c.riders[uid]?.role == 'LEAD' && !c.autoRoles);
  }

  /// True when this rider may change the trip's group settings (limits, thresholds, spoken alerts,
  /// visibility, ride features, public ride): lead rights or the trip head (gateway canChangeSettings).
  bool get canChangeGroupSettings {
    final c = activeConvoy;
    final uid = myUserId;
    if (c == null || uid == null) return false;
    return canEditRoute || (c.tripHeadUserId != null && c.tripHeadUserId == uid);
  }

  /// True when this rider is the trip head and has no lead rights: they can change the settings only.
  bool get isSettingsOnlyTripHead => canChangeGroupSettings && !canEditRoute;

  /// True when this rider may end the trip (and remove riders): the trip owner only (gateway canManage).
  bool get canEndTrip {
    final c = activeConvoy;
    final uid = myUserId;
    if (c == null || uid == null) return false;
    return c.createdByUserId == uid || c.tripOwnerUserId == uid;
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

  /// Ends the trip locally while offline.
  /// Preserves locally available trip and rider info, saves the trip into local history,
  /// and queues synchronization to the outbox for safe upload once reconnected.
  Future<void> endTripOffline() async {
    final convoy = activeConvoy;
    if (convoy == null) return;
    if (_myUserId != null && convoy.riders.containsKey(_myUserId)) {
      await _saveEndedTrip(convoy, _myUserId);
    }
    _enqueue('TRIP_STATUS', {'status': 'ENDED'});
    _onTripEnded(convoy.copyWith(tripStatus: 'ENDED'));
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
  void updateGroupConfig({double? distanceThresholdMeters, int? stopThresholdSeconds, bool? voiceGuidanceEnabled, int? speedLimitKmh, int? townLimitKmh, Map<String, dynamic>? featurePolicy}) {
    final payload = <String, dynamic>{'type': 'CONFIG'};
    if (distanceThresholdMeters != null) payload['distanceThresholdMeters'] = distanceThresholdMeters;
    if (stopThresholdSeconds != null) payload['stopThresholdSeconds'] = stopThresholdSeconds;
    if (voiceGuidanceEnabled != null) payload['voiceGuidanceEnabled'] = voiceGuidanceEnabled;
    if (speedLimitKmh != null) payload['speedLimitKmh'] = speedLimitKmh;
    if (townLimitKmh != null && _ride316) payload['townLimitKmh'] = townLimitKmh;
    if (featurePolicy != null && supports(ProtocolFeatures.featurePolicy) && isOnline && canChangeGroupSettings) payload['featurePolicy'] = featurePolicy;
    if (payload.length == 1) {
      // 3.55 fix: a feature control tapped while offline was dropped without a word.
      if (featurePolicy != null && canChangeGroupSettings && !isOnline) {
        _lastError = _configOfflineError;
        notifyListeners();
      }
      return;
    }
    final c = activeConvoy;
    // 3.55 fix: the same change again within a moment (a double tap on a switch or chip that
    // waits for the gateway's confirmation) is not sent twice.
    final key = jsonEncode(payload);
    final now = DateTime.now();
    if (key == _lastConfigKey && _lastConfigAt != null && now.difference(_lastConfigAt!) < configRepeatWindow) return;
    // 3.55 fix: say so when the change cannot be sent (it used to be dropped silently, so the
    // setting looked "not updating"), show it at once, and re-read the ride from the server if the
    // gateway does not confirm it (refused, or lost on the way) so the screen never shows a value
    // the group does not have.
    if (c == null || !canChangeGroupSettings) return;
    if (!_rt.send(payload)) {
      _lastError = _configOfflineError;
      notifyListeners();
      return;
    }
    _lastConfigKey = key;
    _lastConfigAt = now;
    // 3.55 fix: a sent change clears the "not changed" note of an earlier failed try.
    if (_lastError == _configOfflineError) _lastError = null;
    _allConvoys[c.groupId] = c.copyWith(
      distanceThresholdMeters: distanceThresholdMeters,
      stopThresholdSeconds: stopThresholdSeconds,
      voiceGuidanceEnabled: voiceGuidanceEnabled,
      speedLimitKmh: speedLimitKmh,
      townLimitKmh: payload.containsKey('townLimitKmh') ? townLimitKmh : null,
    );
    _awaitConfigEcho();
    notifyListeners();
  }

  /// An identical CONFIG within this window is not sent again (rapid repeated taps).
  static const Duration configRepeatWindow = Duration(milliseconds: 1500);
  String? _lastConfigKey;
  DateTime? _lastConfigAt;

  static const String _configOfflineError = 'No connection. The group setting was not changed; try again when you are back online.';

  /// Set while a group setting change waits for the gateway's CONFIG (cleared by it).
  Timer? _configPending;

  /// 3.55 fix: after an optimistic group setting change, re-read the ride from the server if the
  /// gateway's CONFIG does not come back in 6 s (refused, or lost), so no rider keeps seeing a value
  /// the group does not have. Shared by every CONFIG sender (group settings, visibility).
  void _awaitConfigEcho() {
    _configPending?.cancel();
    _configPending = Timer(const Duration(seconds: 6), () {
      _configPending = null;
      if (!_disposed) refreshGroupMembers().ignore();
    });
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

  /// Lead (3.55): gives [userId] a riding role: [RideRole.lead] (the current lead takes the rider's
  /// old place), [RideRole.middle] or [RideRole.sweeper]. The gateway keeps one lead and one
  /// sweeper and tells the riders concerned to change position. False when not allowed here.
  bool setRiderRole(String userId, String role) {
    final c = activeConvoy;
    if (c == null || !canEditRoute || !RideRole.all.contains(role)) return false;
    if (c.riders[userId] == null) return false;
    if (role == RideRole.lead && !supportsRideRoles) return false;
    if (!supportsRideRoles) return setSweeper(userId, on: role == RideRole.sweeper);
    _outbox.removeWhere((i) => i.type == 'ROLE_SET' && i.state == OutboxState.waiting && i.payload['userId'] == userId);
    return _enqueue('ROLE_SET', {'userId': userId, 'role': role}) != null;
  }

  /// Lead (3.55): two riders swap riding roles (e.g. the lead and the sweeper change places).
  bool swapRiderRoles(String userId, String withUserId) {
    final c = activeConvoy;
    if (c == null || !canEditRoute || !supportsRideRoles || userId == withUserId) return false;
    if (c.riders[userId] == null || c.riders[withUserId] == null) return false;
    return _enqueue('ROLE_SWAP', {'userId': userId, 'withUserId': withUserId}) != null;
  }

  /// Lead (3.55): automatic roles on or off (off by default). When on, the gateway gives the lead
  /// to the rider at the front and the sweeper role to the last rider, and tells them.
  bool setAutoRoles(bool on) {
    final c = activeConvoy;
    if (c == null || !canEditRoute || !supportsRideRoles) return false;
    _outbox.removeWhere((i) => i.type == 'ROLE_AUTO' && i.state == OutboxState.waiting);
    final ok = _enqueue('ROLE_AUTO', {'on': on}) != null;
    if (ok) {
      _allConvoys[c.groupId] = c.copyWith(autoRoles: on);
      notifyListeners();
    }
    return ok;
  }

  void _onRoleChange(Map<String, dynamic> e) {
    final changes = RoleChange.listFrom(e['changes']);
    final notice = RoleNotice.forMe(changes, myUserId: _myUserId, auto: e['auto'] == true, byName: e['byName']?.toString() ?? '');
    if (notice == null) return;
    _roleNotice = notice;
    _roleNoticeClear?.cancel();
    _roleNoticeClear = Timer(const Duration(seconds: 20), () {
      _roleNotice = null;
      notifyListeners();
    });
    // Spoken only when it is about me (a role change for someone else is a card, not a voice).
    if (notice.mine) _say(notice.speech, 'ROLE:${e['ts'] ?? _clock()}');
    notifyListeners();
  }

  /// 3.55 safety review: role and swap lines are never spoken while an emergency is open (my SOS,
  /// waiting or on the server, or any open SOS / crash alert in the ride); the card still shows,
  /// below the SOS in the cockpit's priority order.
  bool get _emergencyOpen => _pendingSos != null || (activeConvoy?.activeAlerts.any((a) => !a.resolved) ?? false);

  void _say(String line, String key) {
    if (_emergencyOpen) return;
    speaker?.call(line, key);
  }

  /// Clears the role card (the rider dismissed it).
  void dismissRoleNotice() {
    _roleNoticeClear?.cancel();
    _roleNotice = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ 3.55 bike / pillion swap
  SwapAsk? _swapAsk;
  Timer? _swapAskClear;
  SwapNotice? _swapNotice;
  Timer? _swapNoticeClear;
  String _swapLastAskedName = ''; // for "No answer from Kiran" (SWAP_RESULT on expiry has no name)

  /// A swap another rider asked me for, until I answer (Accept / Decline) or it expires.
  SwapAsk? get swapAsk => _swapAsk;

  /// The last swap card worth showing (done, declined, asked, refused), for 20 s.
  SwapNotice? get swapNotice => _swapNotice;

  /// Asks [userId] to swap bikes ([SwapKind.bikes]) or to change places as rider and pillion
  /// ([SwapKind.pillion], only with my own rider or pillion). Through the outbox; the gateway
  /// checks everything again. False when not possible here.
  bool requestSwap(String userId, SwapKind kind) {
    final c = activeConvoy;
    final me = c?.riders[_myUserId];
    final other = c?.riders[userId];
    if (c == null || me == null || other == null || c.isSoloRide || !supportsRideRoles) return false;
    if (!_featureOn('vehicleSwap')) return false; // 3.55 admin feature switch (the gateway refuses too)
    final ok = kind == SwapKind.bikes ? SwapRules.canSwapBikes(me, other) : SwapRules.canSwapPillion(me, other);
    if (!ok) return false;
    if (_enqueue('SWAP_REQUEST', {'withUserId': userId, 'kind': kind.wire}) == null) return false;
    _swapLastAskedName = other.name;
    _showSwapNotice(SwapNotice.asked(name: other.name, kind: kind));
    return true;
  }

  /// Answers the swap I was asked for. False when there is nothing to answer.
  bool answerSwap(String requestId, bool accept) {
    final ask = _swapAsk;
    if (ask == null || ask.requestId != requestId) return false;
    _swapAskClear?.cancel();
    _swapAsk = null;
    _enqueue('SWAP_ANSWER', {'requestId': requestId, 'accept': accept});
    notifyListeners();
    return true;
  }

  /// Clears the swap card (the rider dismissed it).
  void dismissSwapNotice() {
    _swapNoticeClear?.cancel();
    _swapNotice = null;
    notifyListeners();
  }

  void _showSwapNotice(SwapNotice n, {String? speakKey}) {
    _swapNotice = n;
    _swapNoticeClear?.cancel();
    _swapNoticeClear = Timer(const Duration(seconds: 20), () {
      _swapNotice = null;
      notifyListeners();
    });
    final line = n.speech;
    if (line != null && speakKey != null) _say(line, speakKey);
    notifyListeners();
  }

  void _onSwapEvent(String type, Map<String, dynamic> e, String gid) {
    final eg = e['groupId']?.toString();
    if (eg != null && eg.isNotEmpty && eg != gid) return; // about another ride
    switch (type) {
      case 'SWAP_ASK':
        final ask = SwapAsk.fromWire(e);
        if (ask == null || ask.fromUserId == _myUserId) return;
        _swapAsk = ask;
        _swapAskClear?.cancel();
        _swapAskClear = Timer(SwapAsk.showFor, () {
          _swapAsk = null;
          notifyListeners();
        });
        _say(ask.speech, 'SWAP_ASK:${ask.requestId}');
        notifyListeners();
      case 'SWAP_RESULT':
        if (e['accepted'] == true) return;
        final name = e['byName']?.toString() ?? _swapLastAskedName;
        _showSwapNotice(SwapNotice.declined(name: name, kind: SwapKind.fromWire(e['kind']), expired: e['expired'] == true));
      case 'SWAP_DONE':
        final n = SwapNotice.done(e, myUserId: _myUserId);
        if (n == null) return;
        // The ask I was answering (or a stale one between the same riders) is over.
        if (_swapAsk?.requestId == e['requestId']?.toString()) {
          _swapAskClear?.cancel();
          _swapAsk = null;
        }
        _showSwapNotice(n, speakKey: n.mine ? 'SWAP_DONE:${e['requestId'] ?? e['ts'] ?? _clock()}' : null);
    }
  }

  // ------------------------------------------------------------ 3.55 pillion seat
  PillionOffer? _pillionOffer;
  Timer? _pillionOfferClear;
  bool _pillionPick = false;

  /// The gateway lets the pillion confirm the bike (HELLO 'pillion2') and the admin switch is on.
  /// Otherwise the older CORIDER link ([setCoRiderDriver]) is used.
  bool get supportsPillionSeat {
    final c = activeConvoy;
    return c != null && !c.isSoloRide && _rt.supports('pillion2') && _featureOn('pillionSeat');
  }

  /// A pillion just sat on my bike: I may decline until [PillionOffer.declineByMs].
  PillionOffer? get pillionOffer => _pillionOffer;

  /// I am a pillion without a bike in this ride (declined, my rider left): offer the seat picker.
  bool get pillionNeedsSeat {
    final c = activeConvoy;
    final me = c?.riders[_myUserId];
    if (c == null || me == null || c.isSoloRide) return false;
    return _pillionPick || PillionSeat.needsSeat(me, c.riders);
  }

  /// Confirms that I ride pillion on [riderUserId]'s bike (after the rider saw "Confirm?").
  /// Through the outbox; the gateway checks the seat again. False when not possible here.
  bool seatPillion(String riderUserId) {
    final c = activeConvoy;
    final me = c?.riders[_myUserId];
    if (c == null || me == null || c.isSoloRide) return false;
    if (!PillionSeat.candidates(c.riders, me.userId).any((r) => r.userId == riderUserId)) return false;
    if (!supportsPillionSeat) {
      setCoRiderDriver(me.userId, riderUserId); // older gateway / switch off: the old link
      return true;
    }
    if (_enqueue('PILLION_SEAT', PillionSeat.seatMessage(riderUserId)) == null) return false;
    _pillionPick = false;
    _setMyRiderLocally(me.copyWith(isCoRiding: true, ridingWithUserId: riderUserId, pillionSeatAt: _clock()));
    return true;
  }

  /// I get off ([pillionUserId] null), or I decline / remove the pillion on my bike.
  bool unseatPillion([String? pillionUserId]) {
    final c = activeConvoy;
    final me = c?.riders[_myUserId];
    if (c == null || me == null) return false;
    if (pillionUserId == _pillionOffer?.pillionUserId) {
      _pillionOfferClear?.cancel();
      _pillionOffer = null;
    }
    if (!_rt.supports('pillion2')) {
      if (pillionUserId != null) return false; // the old protocol cannot remove someone else
      setCoRiderDriver(me.userId, '');
      return true;
    }
    // Getting off is never switched off (the gateway allows it with the switch off, too).
    if (_enqueue('PILLION_UNSEAT', PillionSeat.unseatMessage(pillionUserId)) == null) return false;
    notifyListeners();
    return true;
  }

  /// "OK": the rider keeps the pillion (the card goes; "Remove pillion" stays on the rider card).
  void dismissPillionOffer() {
    _pillionOfferClear?.cancel();
    _pillionOffer = null;
    notifyListeners();
  }

  /// Joined as a pillion: ask once which bike I sit on (the cockpit card "Pick the bike").
  void requestPillionPick() {
    _pillionPick = true;
    notifyListeners();
  }

  void dismissPillionPick() {
    _pillionPick = false;
    notifyListeners();
  }

  void _onPillionEvent(String type, Map<String, dynamic> e, String gid) {
    final me = _myUserId;
    if (type == 'PILLION_SEATED') {
      final n = PillionNotice.seated(e, myUserId: me);
      final p = e['pillion'], r = e['rider'];
      if (r is Map && p is Map && r['userId']?.toString() == me) {
        final by = e['declineBy'] is num ? (e['declineBy'] as num).toInt() : _clock() + PillionSeat.declineWindow.inMilliseconds;
        _pillionOffer = PillionOffer(pillionUserId: p['userId']?.toString() ?? '', pillionName: p['name']?.toString() ?? '', declineByMs: by);
        _pillionOfferClear?.cancel();
        final left = by - _clock();
        _pillionOfferClear = Timer(Duration(milliseconds: left > 0 ? left : 1), () {
          _pillionOffer = null;
          notifyListeners();
        });
      }
      if (p is Map && p['userId']?.toString() == me) _pillionPick = false;
      if (n != null) _showSwapNotice(SwapNotice(title: n.title, message: n.message, speech: n.speech, mine: n.mine), speakKey: 'PILLION:${e['at'] ?? _clock()}');
      return;
    }
    final n = PillionNotice.unseated(e, myUserId: me);
    final p = e['pillion'];
    if (p is Map && p['userId']?.toString() == _pillionOffer?.pillionUserId) {
      _pillionOfferClear?.cancel();
      _pillionOffer = null;
    }
    if (n == null) {
      notifyListeners();
      return;
    }
    if (n.pickAgain) _pillionPick = true;
    _showSwapNotice(SwapNotice(title: n.title, message: n.message, speech: n.speech, mine: n.mine),
        speakKey: n.speech == null ? null : 'UNSEAT:${e['ts'] ?? _clock()}');
  }

  void _onPillionRefused(String? reason, String? message) {
    final n = PillionNotice.refused(reason, message);
    if (n != null) _showSwapNotice(SwapNotice(title: n.title, message: n.message));
  }

  void _onSwapRefused(String? reason, String? message) {
    final n = SwapNotice.refused(reason, message);
    if (n != null) _showSwapNotice(n);
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
    Map<String, dynamic>? biometrics,
    String? traumaLevel,
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
        biometrics: biometrics,
        traumaLevel: traumaLevel,
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
    Map<String, dynamic>? biometrics,
    String? traumaLevel,
  }) {
    // Restarted in a dead zone during a ride: the SOS is queued for that ride (sent after the
    // re-join; the SMS fallback uses its cached roster meanwhile) instead of being refused.
    final gid = _activeGroupId ?? _unconfirmedRideGid;
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
              biometrics: biometrics ?? existing.biometrics,
              traumaLevel: traumaLevel ?? existing.traumaLevel,
            )
          : existing.copyWith(
              lat: lat,
              lng: lng,
              // A manual press never downgrades crash detection; an automatic one upgrades a manual SOS.
              source: existing.source == EmergencySource.manual ? source : null,
              heading: heading,
              speedKmh: speed,
              accuracyM: accuracy,
              biometrics: biometrics ?? existing.biometrics,
              traumaLevel: traumaLevel ?? existing.traumaLevel,
            );
    } else {
      final who = (idHint != null && idHint.isNotEmpty) ? idHint : (_myUserId ?? 'rider');
      pending = PendingSos(
        clientId: '$who-$now',
        linkToken: PendingSos.newLinkToken(),
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
        biometrics: biometrics,
        traumaLevel: traumaLevel,
      );
    }
    _pendingSos = pending;
    PendingSosStore.save(pending).ignore();
    final sent = _sendPendingSos();
    DiagLog.warn(DiagCat.sos, 'raise', {
      'type': type, 'src': source, 'auto': auto, 'sent': sent, 'repeat': existing != null && existing.groupId == gid,
      'connected': _rt.isConnected, 'acc': accuracy, 'lat': lat, 'lng': lng,
    });
    DiagLogService.instance.noteSafetyMoment('sos');
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

  OutboxItem? _enqueue(String type, Map<String, dynamic> payload, {String? targetGroupId}) {
    final gid = targetGroupId ?? _activeGroupId;
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
            (i.type == 'WAVE' && now - i.createdAt > NetworkConstants.waveMaxAge.inMilliseconds) ||
            // 3.55: a swap ask or answer is over after the gateway's 2 minutes.
            ((i.type == 'SWAP_REQUEST' || i.type == 'SWAP_ANSWER') && now - i.createdAt > SwapAsk.showFor.inMilliseconds)));
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
        _sendingSince[item.clientId] = now;
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
    _sendingSince.remove(clientId);
    final before = _outbox.length;
    _outbox.removeWhere((i) => i.clientId == clientId);
    if (_outbox.length == before) return;
    _persistOutbox();
    notifyListeners();
  }

  /// ERROR for an outbox item: 4xx (not 429) means the server refused it ("Not sent");
  /// 429 and 5xx keep it for another try.
  void _onOutboxError(String clientId, int? code, String? message, [String? reason]) {
    final idx = _outbox.indexWhere((i) => i.clientId == clientId);
    if (idx < 0) return;
    final c = code ?? 500;
    if (_notInRoomYet(c, message, reason)) {
      // Sent between HELLO and the answer to the (re-)JOIN, typically right after a failover:
      // not a refusal of the item. It waits and goes again after the SNAPSHOT (same clientId);
      // a real removal from the ride clears the outbox anyway.
      _sendingSince.remove(clientId);
      _outbox[idx] = _outbox[idx].copyWith(state: OutboxState.waiting);
      _persistOutbox();
      return;
    }
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
    _sendingSince.clear();
    _outboxStore.clear().ignore();
  }

  /// While the socket stays up, what the server has not confirmed is sent again with the same
  /// clientId (the server ignores repeats): an SOS without its ALERT echo, "I'm safe" without
  /// ALERT_RESOLVED, an outbox item without its ACK. The server confirms only after a durable
  /// save, so a save that failed without closing the socket is never lost. Runs on the 10 s
  /// status tick (no extra timer); after a reconnect the SNAPSHOT sends everything anyway.
  /// Also tries again a JOIN refused as SERVER_BUSY.
  void _resendUnconfirmed() {
    final gid = _activeGroupId;
    if (gid == null || !_rt.isConnected) return;
    final now = _clock();
    if (_serverBusyGid == gid && now - _serverBusyAt >= _serverBusyRetryMs) retryAfterServerBusy();
    if (!_roomConfirmed) return; // the SNAPSHOT after the re-JOIN sends everything
    final after = NetConstants.unconfirmedResendAfter.inMilliseconds;
    if (_pendingSos != null && now - _sosSentAt >= after) _sendPendingSos();
    if (_pendingResolves.isNotEmpty && now - _resolvesSentAt >= after) _sendPendingResolves();
    var stale = false;
    for (var i = 0; i < _outbox.length; i++) {
      final item = _outbox[i];
      if (item.state != OutboxState.sending) continue;
      if (now - (_sendingSince[item.clientId] ?? 0) >= after) {
        _outbox[i] = item.copyWith(state: OutboxState.waiting);
        stale = true;
      }
    }
    _sendingSince.removeWhere((cid, _) => !_outbox.any((i) => i.clientId == cid && i.state == OutboxState.sending));
    if (stale || _outbox.any((i) => i.state == OutboxState.waiting)) _flushOutbox();
  }

  @visibleForTesting
  void debugResendUnconfirmed() => _resendUnconfirmed();

  /// The gateway's "not in the room yet" answers to an outbox item: 409 "Join a convoy first."
  /// (no reason), NOT_JOINED, or NOT_MEMBER (which is double-checked with the server anyway).
  static bool _notInRoomYet(int code, String? message, String? reason) {
    if (reason == 'NOT_JOINED' || reason == 'NOT_MEMBER') return true;
    return code == 409 && (reason == null || reason.isEmpty) && (message ?? '').startsWith('Join a convoy first');
  }

  void _onServerBusy() {
    _serverBusyGid = _activeGroupId;
    _serverBusyAt = _clock();
    // 45-75 s, so a full gateway is not asked again by every new rider at the same moment.
    _serverBusyRetryMs = NetConstants.serverBusyRetry.inMilliseconds + math.Random().nextInt(30000);
    _lastError = ApiException.serverBusyMessage;
    _lastErrorIsServerBusy = true;
    notifyListeners();
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
    _syncBatterySaver();
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
    final sent = _rt.send(p.toMessage());
    if (sent) _sosSentAt = _clock();
    DiagLog.info(DiagCat.sos, 'send', {'ok': sent, 'ageMs': _clock() - p.createdAt});
    return sent;
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
    DiagLog.warn(DiagCat.sos, 'cancel', {'reason': reason, 'stillWaiting': waiting != null});
    if (reason == ResolveReason.falseAlarm) DiagLogService.instance.noteSafetyMoment('sos_false_alarm');
    if (waiting != null) {
      _clearPendingSos();
      notifyListeners();
    }
    final id = myOpenSosAlertId ?? _deliveredSosAlertId;
    if (id != null) resolveSosAlert(id, reason: reason);
  }

  /// Closes an SOS. The [reason] goes to a gateway with the safety network only.
  /// Kept until the server confirms it (ALERT_RESOLVED), and sent again after the next re-join:
  /// "I am safe" pressed in a dead zone used to vanish while the group kept responding.
  void resolveSosAlert(String alertId, {ResolveReason reason = ResolveReason.resolved}) {
    final gid = _activeGroupId;
    if (gid == null) return;
    _liveLinks.remove(alertId); // the server revokes it with the alert
    final convoy = _allConvoys[gid];
    if (convoy != null) {
      _allConvoys[gid] = convoy.copyWith(activeAlerts: convoy.activeAlerts.where((a) => a.alertId != alertId).toList());
      notifyListeners();
    }
    _pendingResolves[alertId] = reason;
    _pendingResolvesGid = gid;
    _savePendingResolves();
    if (_rt.send({'type': 'SOS_RESOLVE', 'alertId': alertId, if (_netOn) 'reason': reason.wire})) _resolvesSentAt = _clock();
  }

  /// Resolves not yet confirmed by the server (alertId -> reason), for the active ride only.
  /// Persisted (with their ride) so "I'm safe" pressed in a dead zone survives an app restart.
  final Map<String, ResolveReason> _pendingResolves = {};
  String? _pendingResolvesGid;
  static const _kPendingResolves = 'coroute_pending_resolves_v1';

  void _savePendingResolves() {
    final gid = _pendingResolvesGid;
    final data = _pendingResolves.isEmpty || gid == null
        ? null
        : jsonEncode({'gid': gid, 'r': {for (final e in _pendingResolves.entries) e.key: e.value.wire}});
    SharedPreferences.getInstance()
        .then((p) => data == null ? p.remove(_kPendingResolves) : p.setString(_kPendingResolves, data))
        .ignore();
  }

  Future<void> _loadPendingResolves() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kPendingResolves);
      if (raw == null || raw.isEmpty) return;
      final d = jsonDecode(raw);
      final gid = d is Map ? d['gid'] : null;
      final r = d is Map ? d['r'] : null;
      if (gid is! String || r is! Map || (_activeGroupId != null && _activeGroupId != gid)) {
        await p.remove(_kPendingResolves);
        return;
      }
      if (_pendingResolvesGid != null && _pendingResolvesGid != gid) return; // a newer ride's resolves won
      _pendingResolvesGid = gid;
      r.forEach((k, v) {
        final reason = ResolveReason.fromWire(v?.toString());
        if (k is String && k.isNotEmpty && reason != null) _pendingResolves.putIfAbsent(k, () => reason);
      });
      if (_disposed) return;
      if (_activeGroupId == gid) _sendPendingResolves();
      notifyListeners();
    } catch (e) {
      debugPrint('pending resolves note: $e');
    }
  }

  /// After a SNAPSHOT: alerts the server no longer has open are done; the others are sent again
  /// (the server treats a repeat as the same resolve) and stay hidden on this phone meanwhile.
  void _sendPendingResolves() {
    if (_pendingResolves.isEmpty) return;
    final gid = _activeGroupId;
    if (gid == null) return;
    final convoy = _allConvoys[gid];
    if (convoy == null) return;
    final open = {for (final a in convoy.activeAlerts) a.alertId};
    final before = _pendingResolves.length;
    _pendingResolves.removeWhere((id, _) => !open.contains(id));
    if (_pendingResolves.length != before) _savePendingResolves();
    if (_pendingResolves.isEmpty) return;
    _allConvoys[gid] = convoy.copyWith(activeAlerts: convoy.activeAlerts.where((a) => !_pendingResolves.containsKey(a.alertId)).toList());
    for (final entry in _pendingResolves.entries) {
      _rt.send({'type': 'SOS_RESOLVE', 'alertId': entry.key, if (_netOn) 'reason': entry.value.wire});
    }
    _resolvesSentAt = _clock();
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
    _roadHistoryAt = 0;
    _roadHistoryKey = null;
    if (_assists.isEmpty && _assistNotices.isEmpty && _hazards.isEmpty && _roadHazards.isEmpty && _encounters.isEmpty && _ignoredEncounters.isEmpty && _falseReported.isEmpty) return;
    _assists.clear();
    _assistNotices.clear();
    _hazards.clear();
    _roadHazards.clear();
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

  /// 3.55: a pothole, speed breaker or rough stretch felt by this phone (SafetyService.onRoadSurface,
  /// wired in main.dart). Sent only when I ride at the front of an active group ride (at least two
  /// riders, I am the riding lead, the room is joined) on a gateway that saves road reports
  /// (3.55, or the safety network): the riders behind are warned and the spot is saved, without any
  /// rider id, for later rides. False when nothing was sent.
  bool reportRoadSurface(RoadSurfaceEvent e) {
    final c = activeConvoy;
    final me = _myUserId;
    if (c == null || me == null || _activeGroupId == null) return false;
    if (c.isSoloRide || c.riders.length < 2 || c.tripStatus == 'ENDED') return false;
    if (c.ridingLeadId != me || !_roomConfirmed || !_rt.isConnected) return false;
    if (!(supportsRideRoles || _netOn)) return false;
    if (!e.lat.isFinite || !e.lng.isFinite || (e.lat == 0 && e.lng == 0)) return false;
    final now = _clock();
    final salt = math.Random().nextInt(0xffffff).toRadixString(16).padLeft(6, '0');
    final obs = RoadHazardObservation(
      eventId: 'rh_${now.toRadixString(36)}_$salt',
      timestamp: now,
      lat: e.lat,
      lng: e.lng,
      accuracyM: _lastFixAccuracyM ?? 0,
      speedKmh: e.speedKmh,
      heading: c.riders[me]?.heading ?? 0,
      peakVerticalG: e.peakDynG,
      peakYawRateDegS: e.peakGyroDegS,
      confidence: e.confidence,
      severity: RoadHazardSeverity.fromWire(e.severity),
      classification: RoadHazardClassification.fromWire(e.kind.wire),
    );
    // Not through broadcastRoadHazard: the gateway takes ROAD_HAZARD from the lead whether or not
    // the safety network is on.
    return _enqueue('ROAD_HAZARD', obs.toJson()) != null;
  }

  void _ackRoadHazard(String? hazardId) {
    var idx = _outbox.indexWhere((i) => i.type == 'ROAD_HAZARD' && i.payload['hazardId'] == hazardId);
    if (idx < 0) idx = _outbox.indexWhere((i) => i.type == 'ROAD_HAZARD' && i.state == OutboxState.sending);
    if (idx < 0) return;
    _sendingSince.remove(_outbox[idx].clientId);
    _outbox.removeAt(idx);
    _persistOutbox();
  }

  /// Fetches the saved road reports along the active ride's route (silently; offline is fine).
  /// At most every 10 minutes, and again when the route line changes. Live reports are kept.
  void _maybeFetchRoadHistory() {
    final c = activeConvoy;
    final gid = _activeGroupId;
    final poly = c?.route?.polyline ?? '';
    if (c == null || gid == null || poly.isEmpty || _roadHistoryBusy) return;
    final key = '$gid|${poly.length}|${poly.hashCode}';
    final now = _clock();
    if (key == _roadHistoryKey && now - _roadHistoryAt < _roadHistoryEvery.inMilliseconds) return;
    _roadHistoryBusy = true;
    _roadHistoryKey = key;
    _roadHistoryAt = now;
    _api.get('/road-hazards/near?groupId=${Uri.encodeQueryComponent(gid)}').then((res) {
      if (_disposed || _activeGroupId != gid) return;
      final list = res is Map && res['hazards'] is List ? res['hazards'] as List : const [];
      final saved = <String, RoadHazardObservation>{};
      for (final j in list) {
        if (j is! Map) continue;
        try {
          final h = RoadHazardObservation.fromJson(Map<String, dynamic>.from(j)).copyWith(fromHistory: true);
          if (h.eventId.isNotEmpty && (h.lat != 0 || h.lng != 0)) saved[h.eventId] = h;
        } catch (_) {}
      }
      _roadHazards.removeWhere((_, h) => h.fromHistory);
      saved.forEach((id, h) {
        final live = _roadHazards[id];
        if (live == null) _roadHazards[id] = h;
      });
      _networkRevision++;
      notifyListeners();
    }).catchError((Object _) {
      // Offline or an older gateway: try again after the next SNAPSHOT once the throttle allows.
    }).whenComplete(() => _roadHistoryBusy = false);
  }

  /// "Fixed?" on a saved road report: tells the gateway (enough riders saying so removes it) and
  /// drops it here at once. False when it is not a saved report.
  Future<bool> clearSavedRoadHazard(String hazardId) async {
    final h = _roadHazards[hazardId];
    if (h == null || !h.fromHistory) return false;
    _roadHazards.remove(hazardId);
    _networkRevision++;
    notifyListeners();
    try {
      await _api.post('/road-hazards/${Uri.encodeComponent(hazardId)}/clear');
    } catch (_) {
      // Removed on this phone anyway; the report expires on its own.
    }
    return true;
  }

  /// Broadcasts a road hazard observation (FEAT-02) to downstream riders in the convoy.
  bool broadcastRoadHazard(RoadHazardObservation observation) {
    if (!_netOn || _activeGroupId == null) return false;
    if (!_featureOn('roadHazards')) return false; // 3.55: switched off by the admin (the gateway refuses it too)
    final item = _enqueue('ROAD_HAZARD', observation.toJson());
    return item != null;
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
    if (gid == null || !canChangeGroupSettings) return false;
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
      // 3.55 fix: shown at once, then confirmed by the CONFIG echo or re-read from the server (a
      // refused change used to stay on the lead's screen while the group kept the old value).
      _awaitConfigEcho();
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
  /// Saves the ended trip to history at once, with the numbers and the trail
  /// computed on this phone from its own recorded track (no server work, works
  /// offline). The server's report replaces it later; the server uses these
  /// numbers itself when the track never reached it.
  Future<void> _saveEndedTrip(ConvoyModel convoy, String? userId) async {
    ({TripStats stats, List<TrackPoint> cleaned})? summary;
    try {
      summary = await recorder?.summaryOf(convoy.groupId, minStop: Duration(seconds: convoy.stopThresholdSeconds));
    } catch (_) {
      summary = null;
    }
    await _trips.saveTrip(buildTripHistory(convoy, userId: userId, summary: summary), userId: userId);
  }

  /// The phone's own record of a convoy trip, saved the moment it ends so the
  /// trip is in history at once (also offline). It carries no made-up numbers:
  /// with a [summary] (this phone's own cleaned track) distance, speeds, stops
  /// and the trail come from it; without one they stay 0 until the server's
  /// report replaces this record (same trip id). The trail is only this
  /// rider's recorded track, cut at signal gaps, never the planned route.
  TripHistoryModel buildTripHistory(ConvoyModel convoy, {String? userId, ({TripStats stats, List<TrackPoint> cleaned})? summary}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = summary?.stats;
    final trail = summary == null
        ? const <TripBreadcrumbPoint>[]
        : [
            for (final e in TrackCleaner.trail(summary.cleaned))
              TripBreadcrumbPoint(
                lat: double.parse(e.point.lat.toStringAsFixed(5)),
                lng: double.parse(e.point.lng.toStringAsFixed(5)),
                speedKmh: e.point.speedKmh,
                heading: 0,
                timestamp: e.point.ts,
                gapBefore: e.gapBefore,
              ),
          ];
    return TripHistoryModel(
      tripId: 'TRIP-${convoy.groupId.replaceAll('GRP-', '')}-${userId ?? convoy.createdByUserId}',
      tripName: convoy.name,
      startLocationName: convoy.startLocationName.isNotEmpty ? convoy.startLocationName : 'Convoy Start',
      destinationName: convoy.destinationName.isNotEmpty ? convoy.destinationName : 'Final Waypoint',
      startTimeEpochMs: convoy.createdAtEpochMs,
      endTimeEpochMs: math.max(now, convoy.createdAtEpochMs + 60000),
      totalDistanceKm: s == null ? 0 : double.parse((s.distanceM / 1000).toStringAsFixed(1)),
      topSpeedKmh: s?.maxKmh ?? 0,
      avgSpeedKmh: s?.avgMovingKmh ?? 0,
      riderCount: convoy.riders.length,
      stopCount: s?.stops.length ?? 0,
      movingMs: s?.movingMs ?? 0,
      restMs: s?.restMs ?? 0,
      breadcrumbTrail: trail,
      userId: userId ?? convoy.createdByUserId,
      createdByUserName: convoy.createdByUserName,
      groupId: convoy.groupId,
      source: 'device',
      clientStats: s?.toJson(),
    );
  }

  @override
  void dispose() {
    _chatBannerClear?.cancel();
    _lifecycle?.dispose();
    _configPending?.cancel(); // 3.55 fix
    _eventSub?.cancel();
    _meshSub?.cancel();
    mesh?.stop().ignore();
    _rt.removeListener(_onConnectionChanged);
    _batteryStateSub?.cancel();
    _batteryRefresh?.cancel();
    _compassSub?.cancel();
    _gpsSub?.cancel();
    _idleHeartbeat?.cancel();
    _broadcastClear?.cancel();
    _sosOkClear?.cancel();
    _roleNoticeClear?.cancel();
    _swapAskClear?.cancel(); // 3.55
    _swapNoticeClear?.cancel();
    _statusTimer?.cancel();
    _deadReckoningTimer?.cancel();
    _deadReckoningAccelSub?.cancel();
    _disposed = true;
    _outboxTimer?.cancel();
    _vehicleTimer?.cancel();
    _rosterTimer?.cancel();
    settings?.removeListener(_onSettingsChanged);
    _myFixes.close();
    super.dispose();
  }
}
