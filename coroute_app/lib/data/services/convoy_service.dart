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
import '../models/convoy_model.dart';
import '../models/group_message_model.dart';
import '../models/pending_sos.dart';
import '../models/rider_model.dart';
import '../models/route_model.dart';
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
  ConvoyService(this._api, this._rt, this._trips, {this.recorder, this.timeline, this.settings}) {
    _eventSub = _rt.events.listen(_onEvent);
    BackgroundService.addButtonListener(_onNotificationButton);
    _rt.addListener(_onConnectionChanged);
    _initBatteryTracking();
    _loadPendingSos();
    // The compass only feeds the heading shown on screen: off while the app is not visible.
    try {
      _lifecycle = AppLifecycleListener(onHide: _pauseCompass, onPause: _pauseCompass, onResume: _resumeCompass, onShow: _resumeCompass);
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
  bool _adminWatching = false;
  PendingSos? _pendingSos;
  String? _deliveredSosAlertId;
  String? _sosOkNotice;
  Timer? _sosOkClear;

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
  bool get isOnline => _rt.isConnected;

  /// An SOS this phone raised that the convoy has not confirmed yet (no signal, or not echoed yet).
  PendingSos? get pendingSos => _pendingSos;

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

  // ---------------------------------------------------------- lifecycle
  /// Call after sign-in. Opens the socket and restores an active convoy if any.
  Future<void> startSession({required String token, required String userId, bool admin = false}) async {
    _myUserId = userId;
    _rt.connect(token, adminMode: admin);
    _adminWatching = admin;
    await _restoreActiveConvoy();
  }

  /// Call on sign-out.
  Future<void> endSession() async {
    _clearPendingSos(); // never carried over to the next account on this phone
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
      if (res is Map) _clearPendingSos();
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
    _allConvoys[convoy.groupId] = convoy;
    _activeGroupId = convoy.groupId;
    _rt.joinRoom(convoy.groupId);
    SharedPreferences.getInstance().then((p) => p.setString(AppConstants.keyActiveGroupId, convoy.groupId)).ignore();
    _initCompassTracking();
    // Every member's route is recorded on their own phone and uploaded for the group timeline.
    recorder?.start(convoy.groupId, minStop: Duration(seconds: convoy.stopThresholdSeconds));
    timeline?.attach(convoy.groupId).ignore();
    _startStatus();
    if (_myUserId != null) startRealGpsTracking(_myUserId!).ignore();
    // Foreground service: keeps GPS, intercom and the connection alive with the screen locked.
    BackgroundService.start(convoyName: convoy.name, riderCount: convoy.riders.length).ignore();
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
      leaveActiveConvoy(_myUserId!).ignore();
    } else if (id == BackgroundService.buttonSos) {
      final me = activeConvoy?.riders[_myUserId];
      if (me != null) {
        // Raise immediately (speed matters in an emergency); the UI shows it and can resolve it.
        triggerSosAlert(userId: me.userId, userName: me.name, lat: me.lat, lng: me.lng, type: 'CRASH_OR_EMERGENCY');
      }
      _sosRequestedFromNotification = true;
      notifyListeners();
    }
  }

  void _onConnectionChanged() {
    if (_rt.isConnected) {
      recorder?.uploadNow(); // send what was recorded in the dead zone
    } else {
      recorder?.refreshPendingCount().ignore();
    }
    // A pending SOS is sent again after the SNAPSHOT that follows the re-JOIN (see _onEvent).
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
    if (type == 'ERROR') {
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
        // Back in the room after a dead zone or a restart: send the SOS that is still waiting.
        _sendPendingSos();
        break;
      case 'RIDER_UPDATE':
        if (convoy == null || e['rider'] is! Map) return;
        final rider = RiderModel.fromJson(Map<String, dynamic>.from(e['rider'] as Map));
        final riders = Map<String, RiderModel>.from(convoy.riders)..[rider.userId] = rider;
        _allConvoys[gid] = convoy.copyWith(riders: riders);
        if (e['joined'] == true) _refreshNotification();
        break;
      case 'RIDER_LEFT':
        if (convoy == null) return;
        final riders = Map<String, RiderModel>.from(convoy.riders)..remove(e['userId']?.toString());
        _allConvoys[gid] = convoy.copyWith(riders: riders);
        _refreshNotification();
        break;
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
        _allConvoys[gid] = convoy.copyWith(activeAlerts: alerts);
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
        _allConvoys[gid] = convoy.copyWith(activeAlerts: convoy.activeAlerts.where((a) => a.alertId != resolvedId).toList());
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
        );
        break;
      case 'TRIP_STATUS':
        if (convoy == null) return;
        final status = e['tripStatus']?.toString() ?? convoy.tripStatus;
        _allConvoys[gid] = convoy.copyWith(tripStatus: status);
        if (status == 'ENDED') _onTripEnded(_allConvoys[gid]!);
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
    recorder?.onFix(TrackPoint(
      ts: position.timestamp.millisecondsSinceEpoch,
      lat: position.latitude,
      lng: position.longitude,
      speedKmh: speedKmh,
      accuracyM: position.accuracy.isFinite ? position.accuracy : 999,
    ));
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
    _rt.send({'type': 'CHAT', 'text': text.trim(), 'isQuickCard': isQuickCard, 'cardType': cardType});
  }

  void requestWait(String requesterName) {
    if (_activeGroupId == null) return;
    _rt.send({'type': 'WAIT'});
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
    _rt.send({'type': 'STOP_VISITED', 'stopId': stopId, 'isVisited': isVisited});
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
    _rt.send({'type': 'STATUS', 'statusReason': reason, 'statusMessage': message, 'stoppedSince': stoppedSince});
  }

  void setCoRiderDriver(String riderId, String driverId) {
    final convoy = activeConvoy;
    final rider = convoy?.riders[riderId];
    if (rider == null) return;
    _setMyRiderLocally(rider.copyWith(isCoRiding: driverId.isNotEmpty, ridingWithUserId: driverId));
    _rt.send({'type': 'CORIDER', 'ridingWithUserId': driverId});
  }

  void updateGroupConfig({double? distanceThresholdMeters, int? stopThresholdSeconds, bool? voiceGuidanceEnabled, int? speedLimitKmh}) {
    final payload = <String, dynamic>{'type': 'CONFIG'};
    if (distanceThresholdMeters != null) payload['distanceThresholdMeters'] = distanceThresholdMeters;
    if (stopThresholdSeconds != null) payload['stopThresholdSeconds'] = stopThresholdSeconds;
    if (voiceGuidanceEnabled != null) payload['voiceGuidanceEnabled'] = voiceGuidanceEnabled;
    if (speedLimitKmh != null) payload['speedLimitKmh'] = speedLimitKmh;
    _rt.send(payload);
  }

  /// Raises an SOS for the active convoy. It is kept on the phone (memory and disk) until
  /// the server echoes it back, and sent again after every reconnect with the same
  /// clientId, so it is never lost in a dead zone and never delivered twice.
  SosDelivery triggerSosAlert({required String userId, required String userName, required double lat, required double lng, String type = 'EMERGENCY'}) {
    final gid = _activeGroupId;
    if (gid == null) return SosDelivery.notInConvoy;
    final existing = _pendingSos;
    final pending = (existing != null && existing.groupId == gid)
        // Still the same emergency (not confirmed yet): keep its id, use the newer position.
        ? existing.copyWith(lat: lat, lng: lng)
        : PendingSos(
            clientId: '${userId.isNotEmpty ? userId : (_myUserId ?? 'rider')}-${DateTime.now().millisecondsSinceEpoch}',
            groupId: gid,
            lat: lat,
            lng: lng,
            type: type,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          );
    _pendingSos = pending;
    PendingSosStore.save(pending).ignore();
    final sent = _sendPendingSos();
    notifyListeners();
    return sent ? SosDelivery.sent : SosDelivery.queued;
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
  void cancelMySos() {
    final waiting = _pendingSos;
    if (waiting != null) {
      _clearPendingSos();
      notifyListeners();
    }
    final id = myOpenSosAlertId ?? _deliveredSosAlertId;
    if (id != null) resolveSosAlert(id);
  }

  void resolveSosAlert(String alertId) {
    final gid = _activeGroupId;
    if (gid == null) return;
    final convoy = _allConvoys[gid];
    if (convoy != null) {
      _allConvoys[gid] = convoy.copyWith(activeAlerts: convoy.activeAlerts.where((a) => a.alertId != alertId).toList());
      notifyListeners();
    }
    _rt.send({'type': 'SOS_RESOLVE', 'alertId': alertId});
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
    super.dispose();
  }
}
