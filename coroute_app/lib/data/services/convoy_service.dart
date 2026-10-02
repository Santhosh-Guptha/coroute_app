import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../models/convoy_model.dart';
import '../models/group_message_model.dart';
import '../models/rider_model.dart';
import '../models/sos_alert_model.dart';
import '../models/stop_point_model.dart';
import '../models/trip_history_model.dart';
import 'api_client.dart';
import 'background_service.dart';
import 'realtime_service.dart';
import 'trip_storage_service.dart';

/// Convoy state for the signed-in rider.
///
/// The gateway is the single source of truth: this class holds a mirror of the
/// active convoy that is updated by push events over one WebSocket (no polling),
/// and sends the rider's own telemetry with battery-aware throttling.
class ConvoyService extends ChangeNotifier {
  ConvoyService(this._api, this._rt, this._trips) {
    _eventSub = _rt.events.listen(_onEvent);
    BackgroundService.addButtonListener(_onNotificationButton);
    _rt.addListener(_onConnectionChanged);
    _initBatteryTracking();
  }

  final ApiClient _api;
  final RealtimeService _rt;
  final TripStorageService _trips;
  final Battery _battery = Battery();

  StreamSubscription<Map<String, dynamic>>? _eventSub;
  StreamSubscription<BatteryState>? _batteryStateSub;
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<Position>? _gpsSub;
  Timer? _idleHeartbeat;
  Timer? _batteryRefresh;
  Timer? _broadcastClear;

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
    } on ApiException catch (e) {
      debugPrint('restore active convoy note: ${e.message}');
    } catch (e) {
      debugPrint('restore active convoy note: $e');
    }
    // Nothing active on the server → clear any stale local pointer.
    SharedPreferences.getInstance().then((p) => p.remove(AppConstants.keyActiveGroupId)).ignore();
  }

  void _activate(ConvoyModel convoy) {
    _allConvoys[convoy.groupId] = convoy;
    _activeGroupId = convoy.groupId;
    _rt.joinRoom(convoy.groupId);
    SharedPreferences.getInstance().then((p) => p.setString(AppConstants.keyActiveGroupId, convoy.groupId)).ignore();
    _initCompassTracking();
    if (_myUserId != null) startRealGpsTracking(_myUserId!).ignore();
    // Foreground service: keeps GPS, intercom and the connection alive with the screen locked.
    BackgroundService.start(convoyName: convoy.name, riderCount: convoy.riders.length).ignore();
    notifyListeners();
  }

  void _refreshNotification() {
    final c = activeConvoy;
    if (c == null) return;
    BackgroundService.start(convoyName: c.name, riderCount: c.riders.length).ignore();
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

  void _onConnectionChanged() => notifyListeners();

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
      if (e['code'] == 403 || e['code'] == 404) _dropActiveConvoyLocally();
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
        final alerts = List<SosAlertModel>.from(convoy.activeAlerts.where((a) => a.alertId != alert.alertId))..add(alert);
        _allConvoys[gid] = convoy.copyWith(activeAlerts: alerts);
        break;
      case 'ALERT_RESOLVED':
        if (convoy == null) return;
        _allConvoys[gid] = convoy.copyWith(activeAlerts: convoy.activeAlerts.where((a) => a.alertId != e['alertId']).toList());
        break;
      case 'STOPS':
        if (convoy == null || e['stopPoints'] is! List) return;
        final stops = (e['stopPoints'] as List).whereType<Map>().map((s) => StopPointModel.fromJson(Map<String, dynamic>.from(s))).toList();
        _allConvoys[gid] = convoy.copyWith(stopPoints: stops);
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

  void _dropActiveConvoyLocally() {
    final gid = _activeGroupId;
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
    if (_myUserId != null && convoy.riders.containsKey(_myUserId)) {
      _trips.saveTrip(buildTripHistory(convoy, userId: _myUserId), userId: _myUserId).ignore();
    }
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
  }) async {
    final pos = await _getCurrentPosition();
    await _refreshBatteryLevel();
    final res = await _api.post('/convoys', {
      'name': name.trim(),
      'startPoint': startPoint,
      'destination': destination,
      'destLat': destLat,
      'destLng': destLng,
      'distanceThresholdMeters': distanceThresholdMeters,
      'stopThresholdSeconds': stopThresholdSeconds,
      'voiceGuidanceEnabled': voiceGuidanceEnabled,
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
    final convoy = _allConvoys[gid];
    if (convoy != null && convoy.riders.isNotEmpty) {
      _trips.saveTrip(buildTripHistory(convoy, userId: userId), userId: userId).ignore();
    }
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
    if (since >= AppConfig.telemetryMinInterval || movedFar || (isMoving && wasStopped)) {
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
  void _initCompassTracking() {
    _compassSub?.cancel();
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
    _batteryStateSub = _battery.onBatteryStateChanged.listen((state) async {
      _isCharging = state == BatteryState.charging || state == BatteryState.full;
      await _refreshBatteryLevel();
      notifyListeners();
    });
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

  void updateGroupConfig({double? distanceThresholdMeters, int? stopThresholdSeconds, bool? voiceGuidanceEnabled}) {
    final payload = <String, dynamic>{'type': 'CONFIG'};
    if (distanceThresholdMeters != null) payload['distanceThresholdMeters'] = distanceThresholdMeters;
    if (stopThresholdSeconds != null) payload['stopThresholdSeconds'] = stopThresholdSeconds;
    if (voiceGuidanceEnabled != null) payload['voiceGuidanceEnabled'] = voiceGuidanceEnabled;
    _rt.send(payload);
  }

  void triggerSosAlert({required String userId, required String userName, required double lat, required double lng, String type = 'EMERGENCY'}) {
    if (_activeGroupId == null) return;
    _rt.send({'type': 'SOS', 'lat': lat, 'lng': lng, 'alertType': type});
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
  TripHistoryModel buildTripHistory(ConvoyModel convoy, {String? userId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final riders = convoy.riders.values.toList();
    double topSpeed = 0.0, totalSpeed = 0.0;
    for (final r in riders) {
      if (r.speedKmh > topSpeed) topSpeed = r.speedKmh;
      totalSpeed += r.speedKmh;
    }
    final avgSpeed = riders.isNotEmpty ? totalSpeed / riders.length : 0.0;
    final durationMs = math.max(60000, now - convoy.createdAtEpochMs);
    final estimatedDistanceKm = avgSpeed * (durationMs / 3600000.0);

    return TripHistoryModel(
      tripId: 'TRIP-${convoy.groupId.replaceAll('GRP-', '')}-${userId ?? convoy.createdByUserId}',
      tripName: convoy.name,
      startLocationName: convoy.startLocationName.isNotEmpty ? convoy.startLocationName : 'Convoy Start',
      destinationName: convoy.destinationName.isNotEmpty ? convoy.destinationName : 'Final Waypoint',
      startTimeEpochMs: convoy.createdAtEpochMs,
      endTimeEpochMs: now,
      totalDistanceKm: double.parse(estimatedDistanceKm.toStringAsFixed(1)),
      topSpeedKmh: double.parse(topSpeed.toStringAsFixed(1)),
      avgSpeedKmh: double.parse(avgSpeed.toStringAsFixed(1)),
      riderCount: convoy.riders.length,
      stopCount: convoy.stopPoints.where((s) => s.isVisited).length,
      breadcrumbTrail: riders
          .map((r) => TripBreadcrumbPoint(lat: r.lat, lng: r.lng, speedKmh: r.speedKmh, heading: r.heading, timestamp: r.lastSeenEpochMs))
          .toList(),
      userId: userId ?? convoy.createdByUserId,
      createdByUserName: convoy.createdByUserName,
    );
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _rt.removeListener(_onConnectionChanged);
    _batteryStateSub?.cancel();
    _batteryRefresh?.cancel();
    _compassSub?.cancel();
    _gpsSub?.cancel();
    _idleHeartbeat?.cancel();
    _broadcastClear?.cancel();
    super.dispose();
  }
}
