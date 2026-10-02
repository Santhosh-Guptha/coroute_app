import 'dart:async';
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants/app_constants.dart';
import '../models/convoy_model.dart';
import '../models/rider_model.dart';
import '../models/sos_alert_model.dart';
import '../models/group_message_model.dart';
import '../models/stop_point_model.dart';
import '../models/trip_history_model.dart';
import 'oracle_ai_service.dart';

class ConvoyService extends ChangeNotifier {
  final OracleAiService _oracleService = OracleAiService();
  final Battery _battery = Battery();
  int _currentBatteryLevel = 100;
  bool _isCharging = false;
  StreamSubscription<BatteryState>? _batteryStateSub;
  StreamSubscription<CompassEvent>? _compassSub;
  double? _deviceCompassHeading;

  final Map<String, ConvoyModel> _allConvoys = {};
  String? _activeGroupId;
  bool _isRealGpsActive = false;
  String? _systemBroadcastMessage;

  Timer? _oracleSyncTimer;
  bool _isSyncingWithOracle = false;
  final Set<String> _resolvedAlertIds = {};
  Timer? _voicePollTimer;
  int _lastVoiceBurstTimestamp = DateTime.now().millisecondsSinceEpoch - 5000;
  final Set<String> _processedVoiceBurstKeys = {};

  StreamSubscription? _locationsSub;
  StreamSubscription? _alertsSub;
  StreamSubscription? _messagesSub;
  StreamSubscription? _stopsSub;
  StreamSubscription? _waitRequestsSub;
  StreamSubscription? _adminFleetSub;
  StreamSubscription<Position>? _gpsPositionSub;
  StreamSubscription? _tripStatusSub;
  StreamSubscription? _configSub;
  StreamSubscription? _voiceBurstSub;

  final StreamController<Map<String, dynamic>> _voiceBurstController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get voiceBurstStream => _voiceBurstController.stream;

  Map<String, ConvoyModel> get allConvoys => Map.unmodifiable(_allConvoys);
  String? get activeGroupId => _activeGroupId;
  String? get systemBroadcastMessage => _systemBroadcastMessage;
  bool get isRealGpsActive => _isRealGpsActive;
  int get currentBatteryLevel => _currentBatteryLevel;
  bool get isCharging => _isCharging;

  ConvoyModel? get activeConvoy =>
      _activeGroupId != null ? _allConvoys[_activeGroupId] : null;

  ConvoyService() {
    _initFirebaseAndSync();
    _initOracleSync();
    _initBatteryTracking();
    _initCompassTracking();
    _restoreActiveConvoySession();
  }

  /// Real-time Hardware Magnetometer Compass Tracking (Mobile facing direction)
  void _initCompassTracking() {
    _compassSub?.cancel();
    try {
      _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
        if (event.heading != null) {
          double h = event.heading!;
          if (h < 0) h += 360.0;
          _deviceCompassHeading = h;
        }
      });
    } catch (e) {
      debugPrint('Compass tracking note: $e');
    }
  }

  /// Automatically restore active convoy session and resume GPS tracking on launch
  Future<void> _restoreActiveConvoySession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedGroupId = prefs.getString(AppConstants.keyActiveGroupId);
      final savedUserName = prefs.getString(AppConstants.keyUserName);
      if (savedGroupId == null || savedGroupId.isEmpty) return;

      _activeGroupId = savedGroupId;
      _attachGroupListeners(savedGroupId);

      final myUserId = savedUserName != null && savedUserName.isNotEmpty
          ? 'usr_${savedUserName.toLowerCase().replaceAll(' ', '_')}'
          : null;

      // 1. Fetch group from Firebase Realtime Database
      try {
        final snap = await FirebaseDatabase.instance
            .ref('groups/$savedGroupId')
            .get()
            .timeout(const Duration(seconds: 3));
        if (snap.exists && snap.value is Map) {
          final groupMap = Map<String, dynamic>.from(snap.value as Map);
          final convoy = ConvoyModel.fromJson(groupMap);
          if (convoy.tripStatus != 'ENDED') {
            _allConvoys[savedGroupId] = convoy;
            if (myUserId != null) {
              startRealGpsTracking(myUserId).ignore();
              _startOracleSync(savedGroupId, myUserId);
              _startVoicePolling(savedGroupId);
            }
            notifyListeners();
            return;
          } else {
            await prefs.remove(AppConstants.keyActiveGroupId);
            _activeGroupId = null;
            return;
          }
        }
      } catch (e) {
        debugPrint('Firebase restore session note: $e');
      }

      // 2. Fallback to Oracle Autonomous Database
      try {
        final oracleConvoy = await _oracleService.fetchConvoyByGroupId(savedGroupId);
        if (oracleConvoy != null && oracleConvoy.tripStatus != 'ENDED') {
          _allConvoys[savedGroupId] = oracleConvoy;
          if (myUserId != null) {
            startRealGpsTracking(myUserId).ignore();
            _startOracleSync(savedGroupId, myUserId);
            _startVoicePolling(savedGroupId);
          }
          notifyListeners();
        } else if (oracleConvoy != null && oracleConvoy.tripStatus == 'ENDED') {
          await prefs.remove(AppConstants.keyActiveGroupId);
          _activeGroupId = null;
        }
      } catch (e) {
        debugPrint('Oracle restore session note: $e');
      }
    } catch (e) {
      debugPrint('Restore active convoy session error: $e');
    }
  }

  /// Real-time Device Battery Telemetry Tracking
  Future<void> _initBatteryTracking() async {
    await _refreshBatteryLevel();
    _batteryStateSub?.cancel();
    _batteryStateSub = _battery.onBatteryStateChanged.listen((BatteryState state) async {
      _isCharging = (state == BatteryState.charging || state == BatteryState.full);
      try {
        _currentBatteryLevel = await _battery.batteryLevel;
      } catch (_) {}

      if (_activeGroupId != null) {
        final convoy = _allConvoys[_activeGroupId];
        if (convoy != null) {
          for (final entry in convoy.riders.entries) {
            if (entry.value.role == 'LEAD' || convoy.riders.length == 1) {
              updateRiderLocation(entry.value.copyWith(
                batteryLevel: _currentBatteryLevel,
                isCharging: _isCharging,
              ));
              break;
            }
          }
        }
      }
      notifyListeners();
    });
  }

  /// Refresh current device battery percentage and state
  Future<void> _refreshBatteryLevel() async {
    try {
      _currentBatteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      _isCharging = (state == BatteryState.charging || state == BatteryState.full);
    } catch (e) {
      debugPrint('Battery query note: $e');
    }
  }

  /// Initial load of active convoys from Oracle 26ai Autonomous Database
  void _initOracleSync() {
    _oracleService.fetchActiveConvoysFromOracle().then((list) {
      for (final c in list) {
        _allConvoys[c.groupId] = c;
      }
      notifyListeners();
    }).catchError((e) {
      debugPrint('Oracle initial convoys fetch note: $e');
    });
  }

  /// Real-time Firebase Sync for all active groups (Admin Fleet Overview)
  void _initFirebaseAndSync() {
    try {
      final db = FirebaseDatabase.instance;
      _adminFleetSub = db.ref('groups').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is Map) {
          val.forEach((k, v) {
            if (v is Map) {
              try {
                final groupMap = Map<String, dynamic>.from(v);
                final convoy = ConvoyModel.fromJson(groupMap);
                final existing = _allConvoys[convoy.groupId];
                if (existing != null) {
                  final mergedRiders = Map<String, RiderModel>.from(existing.riders);
                  for (final r in convoy.riders.entries) {
                    if (!mergedRiders.containsKey(r.key) ||
                        r.value.lastSeenEpochMs >= mergedRiders[r.key]!.lastSeenEpochMs) {
                      mergedRiders[r.key] = r.value;
                    }
                  }
                  _allConvoys[convoy.groupId] = convoy.copyWith(
                    riders: mergedRiders,
                    activeAlerts: existing.activeAlerts.isNotEmpty ? existing.activeAlerts : convoy.activeAlerts,
                    messages: existing.messages.length >= convoy.messages.length ? existing.messages : convoy.messages,
                  );
                } else {
                  _allConvoys[convoy.groupId] = convoy;
                }
              } catch (e) {
                debugPrint('Error parsing group $k: $e');
              }
            }
          });
          notifyListeners();
        }
      });

      // Listen for system-wide admin broadcast
      db.ref('system_broadcast').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is Map) {
          final msg = val['message']?.toString();
          if (msg != null && msg.isNotEmpty) {
            _systemBroadcastMessage = msg;
            notifyListeners();
            Future.delayed(const Duration(seconds: 12), () {
              _systemBroadcastMessage = null;
              notifyListeners();
            });
          }
        }
      });
    } catch (e) {
      debugPrint('Firebase Realtime Database init error: $e');
    }
  }

  /// Get the current device GPS position (returns null if unavailable)
  Future<Position?> _getCurrentPosition() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }
      if (permission == LocationPermission.deniedForever) return null;

      // Try last known first (instant), fall back to current position
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) return lastKnown;

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      debugPrint('GPS position error: $e');
      return null;
    }
  }

  /// Create a brand-new dynamic convoy with real GPS
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
    final uuid = const Uuid().v4().substring(0, 8).toUpperCase();
    final joinCode = (100000 + math.Random().nextInt(900000)).toString();
    final now = DateTime.now().millisecondsSinceEpoch;

    // Get real GPS position from device
    final pos = await _getCurrentPosition();
    final initialLat = pos?.latitude ?? 0.0;
    final initialLng = pos?.longitude ?? 0.0;

    await _refreshBatteryLevel();
    final newConvoy = ConvoyModel(
      groupId: 'GRP-$uuid',
      name: name.trim(),
      joinCode: joinCode,
      createdByUserId: creatorId,
      createdByUserName: creatorName,
      startLocationName: startPoint,
      destinationName: destination,
      destinationLat: destLat,
      destinationLng: destLng,
      tripStatus: 'STARTED',
      createdAtEpochMs: now,
      distanceThresholdMeters: distanceThresholdMeters,
      stopThresholdSeconds: stopThresholdSeconds,
      voiceGuidanceEnabled: voiceGuidanceEnabled,
      routeBreadcrumbs: routeBreadcrumbs,
      riders: {
        creatorId: RiderModel(
          userId: creatorId,
          name: creatorName,
          vehicleType: vehicleType,
          lat: initialLat,
          lng: initialLng,
          speedKmh: 0.0,
          heading: 0.0,
          batteryLevel: _currentBatteryLevel,
          isCharging: _isCharging,
          role: 'LEAD',
          lastSeenEpochMs: now,
          phone: phone,
          vehicleNo: vehicleNo,
        ),
      },
    );

    _allConvoys[newConvoy.groupId] = newConvoy;
    _activeGroupId = newConvoy.groupId;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.keyActiveGroupId, newConvoy.groupId);
      await prefs.setString(AppConstants.keyUserName, creatorName);
    } catch (_) {}

    // Push to Oracle 26ai Autonomous Database
    await _oracleService.saveOrUpdateConvoy(newConvoy);

    // Push to Firebase Realtime Database
    _syncConvoyToFirebase(newConvoy);
    _attachGroupListeners(newConvoy.groupId);

    // Auto-start real GPS tracking for creator
    await startRealGpsTracking(creatorId);

    // Start background Oracle cloud sync
    _startOracleSync(newConvoy.groupId, creatorId);

    // Start high-cadence Intercom voice polling via Oracle 26ai Cloud SODA
    _startVoicePolling(newConvoy.groupId);

    notifyListeners();
    return newConvoy;
  }

  Future<void> _persistActiveSession(String groupId, String userName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.keyActiveGroupId, groupId);
      if (userName.isNotEmpty) {
        await prefs.setString(AppConstants.keyUserName, userName);
      }
    } catch (_) {}
  }

  /// Construct comprehensive TripHistoryModel from current convoy telemetry
  TripHistoryModel buildTripHistory(ConvoyModel convoy, {String? userId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final allRiders = convoy.riders.values.toList();
    double topSpeed = 0.0;
    double totalSpeed = 0.0;
    int speedCount = 0;
    for (final r in allRiders) {
      if (r.speedKmh > topSpeed) topSpeed = r.speedKmh;
      totalSpeed += r.speedKmh;
      speedCount++;
    }
    final avgSpeed = speedCount > 0 ? totalSpeed / speedCount : 0.0;
    final durationMs = math.max(60000, now - convoy.createdAtEpochMs);
    final durationHours = durationMs / 3600000.0;
    final estimatedDistanceKm = avgSpeed * durationHours;
    final visitedStops = convoy.stopPoints.where((s) => s.isVisited).length;

    return TripHistoryModel(
      tripId: 'TRIP-${convoy.groupId.replaceAll('GRP-', '')}-$now',
      tripName: convoy.name,
      startLocationName: convoy.startLocationName.isNotEmpty ? convoy.startLocationName : 'Convoy Start',
      destinationName: convoy.destinationName.isNotEmpty ? convoy.destinationName : 'Final Waypoint',
      startTimeEpochMs: convoy.createdAtEpochMs,
      endTimeEpochMs: now,
      totalDistanceKm: double.parse(estimatedDistanceKm.toStringAsFixed(1)),
      topSpeedKmh: double.parse(topSpeed.toStringAsFixed(1)),
      avgSpeedKmh: double.parse(avgSpeed.toStringAsFixed(1)),
      riderCount: convoy.riders.length,
      stopCount: visitedStops,
      breadcrumbTrail: allRiders.map((r) => TripBreadcrumbPoint(
        lat: r.lat,
        lng: r.lng,
        speedKmh: r.speedKmh,
        heading: r.heading,
        timestamp: r.lastSeenEpochMs,
      )).toList(),
      userId: userId ?? convoy.createdByUserId,
      createdByUserName: convoy.createdByUserName,
    );
  }

  void _persistTripHistoryToCloud(TripHistoryModel trip, String userId) {
    try {
      final cleanUid = 'usr_${userId.toLowerCase().replaceAll('usr_', '').replaceAll(' ', '_')}';
      final tripData = trip.toJson();
      FirebaseDatabase.instance.ref('users/$cleanUid/trips/${trip.tripId}').set(tripData).timeout(const Duration(seconds: 2)).catchError((_) {});
      FirebaseDatabase.instance.ref('trips/${trip.tripId}').set(tripData).timeout(const Duration(seconds: 2)).catchError((_) {});
      _oracleService.saveTripToOracle(trip).catchError((_) => false);
    } catch (e) {
      debugPrint('Cloud trip persist note: $e');
    }
  }

  /// Join an existing convoy using its 6-digit room code dynamically
  Future<ConvoyModel?> joinConvoyByCode({
    required String code,
    required RiderModel rider,
  }) async {
    final clean = code.trim().toUpperCase();
    await _refreshBatteryLevel();
    final riderWithBattery = rider.copyWith(
      batteryLevel: _currentBatteryLevel,
      isCharging: _isCharging,
    );

    // 1. Check local in-memory convoys (already synced from Oracle or memory)
    for (final c in _allConvoys.values) {
      if (c.joinCode.trim().toUpperCase() == clean) {
        final updatedRiders = Map<String, RiderModel>.from(c.riders);
        updatedRiders[riderWithBattery.userId] = riderWithBattery;
        final updated = c.copyWith(riders: updatedRiders);
        _allConvoys[c.groupId] = updated;
        _activeGroupId = c.groupId;
        _persistActiveSession(c.groupId, rider.name).ignore();

        // Persist joiner into Oracle 26ai Autonomous Database
        await _oracleService.saveOrUpdateConvoy(updated);

        _syncRiderLocationToFirebase(c.groupId, riderWithBattery);
        _attachGroupListeners(c.groupId);

        // Auto-start real GPS tracking for joining rider
        await startRealGpsTracking(riderWithBattery.userId);

        // Start bidirectional Oracle cloud sync
        _startOracleSync(c.groupId, riderWithBattery.userId);

        // Start high-cadence Intercom voice polling via Oracle 26ai Cloud SODA
        _startVoicePolling(c.groupId);

        notifyListeners();
        return updated;
      }
    }

    // 2. Query Oracle 26ai Autonomous Database directly
    try {
      final oracleConvoy = await _oracleService.fetchConvoyByCode(clean);
      if (oracleConvoy != null) {
        final updatedRiders = Map<String, RiderModel>.from(oracleConvoy.riders);
        updatedRiders[riderWithBattery.userId] = riderWithBattery;
        final updated = oracleConvoy.copyWith(riders: updatedRiders);

        _allConvoys[updated.groupId] = updated;
        _activeGroupId = updated.groupId;
        _persistActiveSession(updated.groupId, rider.name).ignore();

        // Persist joiner into Oracle 26ai Autonomous Database
        await _oracleService.saveOrUpdateConvoy(updated);

        _syncRiderLocationToFirebase(updated.groupId, riderWithBattery);
        _attachGroupListeners(updated.groupId);

        // Auto-start real GPS tracking for joining rider
        await startRealGpsTracking(riderWithBattery.userId);

        // Start bidirectional Oracle cloud sync
        _startOracleSync(updated.groupId, riderWithBattery.userId);

        // Start high-cadence Intercom voice polling via Oracle 26ai Cloud SODA
        _startVoicePolling(updated.groupId);

        notifyListeners();
        return updated;
      }
    } catch (e) {
      debugPrint('Oracle remote join query error: $e');
    }

    // 3. Fallback to Firebase Realtime Database if available
    try {
      final db = FirebaseDatabase.instance;
      final joinSnapshot = await db.ref('joinCodes/$clean').get().timeout(const Duration(milliseconds: 600));
      if (joinSnapshot.exists && joinSnapshot.value != null) {
        final targetGroupId = joinSnapshot.value.toString();
        final groupSnapshot = await db.ref('groups/$targetGroupId').get().timeout(const Duration(milliseconds: 600));
        if (groupSnapshot.exists && groupSnapshot.value != null) {
          final groupMap = Map<String, dynamic>.from(groupSnapshot.value as Map);
          final loadedConvoy = ConvoyModel.fromJson(groupMap);

          final updatedRiders = Map<String, RiderModel>.from(loadedConvoy.riders);
          updatedRiders[riderWithBattery.userId] = riderWithBattery;
          final updated = loadedConvoy.copyWith(riders: updatedRiders);

          _allConvoys[updated.groupId] = updated;
          _activeGroupId = updated.groupId;
          _persistActiveSession(updated.groupId, rider.name).ignore();

          await _oracleService.saveOrUpdateConvoy(updated);
          _syncRiderLocationToFirebase(updated.groupId, riderWithBattery);
          _attachGroupListeners(updated.groupId);

          // Auto-start real GPS tracking for joining rider
          await startRealGpsTracking(riderWithBattery.userId);

          // Start bidirectional Oracle cloud sync
          _startOracleSync(updated.groupId, riderWithBattery.userId);

          // Start high-cadence Intercom voice polling via Oracle 26ai Cloud SODA
          _startVoicePolling(updated.groupId);

          notifyListeners();
          return updated;
        }
      }
    } catch (e) {
      debugPrint('Firebase remote join query error: $e');
    }

    return null;
  }

  /// Start bidirectional background sync with Oracle 26ai Cloud (3-second cadence)
  void _startOracleSync(String groupId, String userId) {
    _oracleSyncTimer?.cancel();
    _oracleSyncTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (_activeGroupId != groupId) {
        timer.cancel();
        return;
      }
      if (_isSyncingWithOracle) return;
      _isSyncingWithOracle = true;

      try {
        final currentConvoy = _allConvoys[groupId];
        if (currentConvoy == null) return;

        await _refreshBatteryLevel();

        // 1. Fetch remote convoy from Oracle Autonomous Database
        final remote = await _oracleService.fetchConvoyByGroupId(groupId);
        if (remote != null) {
          // Keep all existing known riders to prevent disappearance / flicker
          final mergedRiders = Map<String, RiderModel>.from(currentConvoy.riders);
          for (final entry in remote.riders.entries) {
            if (!mergedRiders.containsKey(entry.key)) {
              mergedRiders[entry.key] = entry.value;
            } else {
              final localR = mergedRiders[entry.key]!;
              if (entry.value.lastSeenEpochMs > localR.lastSeenEpochMs) {
                mergedRiders[entry.key] = entry.value;
              }
            }
          }
          // Preserve local user's most recent sensor telemetry & battery
          final localRider = currentConvoy.riders[userId];
          if (localRider != null) {
            mergedRiders[userId] = localRider.copyWith(
              batteryLevel: _currentBatteryLevel,
              isCharging: _isCharging,
            );
          }

          // Filter remote alerts: ignore any alert marked resolved or in local resolved set
          final validRemoteAlerts = remote.activeAlerts
              .where((a) => !a.resolved && !_resolvedAlertIds.contains(a.alertId))
              .toList();

          // Also keep any active alert raised locally by this user if not yet on remote
          final localUnsyncedAlerts = currentConvoy.activeAlerts
              .where((a) => a.userId == userId && !a.resolved && !_resolvedAlertIds.contains(a.alertId))
              .toList();

          final alertMap = <String, SosAlertModel>{};
          for (final a in validRemoteAlerts) {
            alertMap[a.alertId] = a;
          }
          for (final a in localUnsyncedAlerts) {
            alertMap[a.alertId] = a;
          }

          final updated = currentConvoy.copyWith(
            riders: mergedRiders,
            activeAlerts: alertMap.values.toList(),
            messages: remote.messages.length > currentConvoy.messages.length ? remote.messages : currentConvoy.messages,
            stopPoints: remote.stopPoints.isNotEmpty ? remote.stopPoints : currentConvoy.stopPoints,
          );

          _allConvoys[groupId] = updated;

          // Push merged convoy state to Oracle
          await _oracleService.saveOrUpdateConvoy(updated);

          notifyListeners();
        } else {
          // If remote not found yet, push local convoy
          await _oracleService.saveOrUpdateConvoy(currentConvoy);
        }
      } catch (e) {
        debugPrint('Oracle sync loop error: $e');
      } finally {
        _isSyncingWithOracle = false;
      }
    });
  }

  /// Leave or Conclude active group session
  void leaveActiveConvoy(String userId) {
    if (_activeGroupId == null) return;
    final gid = _activeGroupId!;
    _oracleSyncTimer?.cancel();
    _voicePollTimer?.cancel();
    stopRealGpsTracking();

    final convoy = _allConvoys[gid];
    if (convoy != null) {
      // Save journey history for the leaving rider before departing
      if (convoy.riders.isNotEmpty) {
        final tripHistory = buildTripHistory(convoy, userId: userId);
        _persistTripHistoryToCloud(tripHistory, userId);
      }

      final updatedRiders = Map<String, RiderModel>.from(convoy.riders)..remove(userId);
      final updated = convoy.copyWith(riders: updatedRiders);
      _allConvoys[gid] = updated;
      _oracleService.saveOrUpdateConvoy(updated);
    }

    // Clear active session from preferences
    SharedPreferences.getInstance().then((p) => p.remove(AppConstants.keyActiveGroupId)).ignore();

    try {
      FirebaseDatabase.instance
          .ref('groups/$gid/riders/$userId')
          .remove()
          .timeout(const Duration(milliseconds: 500))
          .catchError((_) {});
      // Note: We deliberately do NOT remove 'locations/$userId' so last captured coordinates remain accessible
    } catch (_) {}
    _detachGroupListeners();
    _activeGroupId = null;
    notifyListeners();
  }

  /// Start Real GPS Tracking from device sensors
  Future<bool> startRealGpsTracking(String userId) async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    _gpsPositionSub?.cancel();
    _isRealGpsActive = true;

    _gpsPositionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3, // Update every 3 meters of movement
      ),
    ).listen((Position position) {
      if (_activeGroupId == null) return;
      final convoy = _allConvoys[_activeGroupId];
      if (convoy == null) return;
      final currentRider = convoy.riders[userId];

      final speedKmh = (position.speed * 3.6).clamp(0.0, 200.0);
      final heading = position.heading.clamp(0.0, 360.0);

      final wasStopped = (currentRider?.statusReason.isNotEmpty == true);
      final isNowMoving = speedKmh >= 3.0;

      // Sensor fusion: If moving >= 10 km/h, use GPS trajectory heading.
      // If stationary or moving slowly, use mobile physical facing direction from compass.
      double fusedHeading = currentRider?.heading ?? 0.0;
      if (speedKmh >= 10.0 && heading > 0) {
        fusedHeading = heading;
      } else if (_deviceCompassHeading != null) {
        fusedHeading = _deviceCompassHeading!;
      } else if (heading > 0) {
        fusedHeading = heading;
      }

      final updated = (currentRider ??
              RiderModel(
                userId: userId,
                name: 'Rider',
                lat: position.latitude,
                lng: position.longitude,
                batteryLevel: _currentBatteryLevel,
                isCharging: _isCharging,
                lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
              ))
          .copyWith(
        lat: position.latitude,
        lng: position.longitude,
        speedKmh: speedKmh,
        heading: fusedHeading,
        batteryLevel: _currentBatteryLevel,
        isCharging: _isCharging,
        lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
        statusReason: (isNowMoving && wasStopped) ? '' : (currentRider?.statusReason ?? ''),
        statusMessage: (isNowMoving && wasStopped) ? '' : (currentRider?.statusMessage ?? ''),
        stoppedSince: isNowMoving
            ? 0
            : ((currentRider?.stoppedSince ?? 0) != 0
                ? currentRider!.stoppedSince
                : DateTime.now().millisecondsSinceEpoch),
      );

      updateRiderLocation(updated);
    });

    notifyListeners();
    return true;
  }

  void stopRealGpsTracking() {
    _gpsPositionSub?.cancel();
    _isRealGpsActive = false;
    notifyListeners();
  }

  /// Send chat message or quick status broadcast card
  void sendGroupMessage({
    required String senderId,
    required String senderName,
    required String text,
    bool isQuickCard = false,
    String cardType = 'CUSTOM',
  }) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId]!;
    final msg = GroupMessageModel(
      messageId: 'MSG-${const Uuid().v4().substring(0, 8)}',
      senderId: senderId,
      senderName: senderName,
      text: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isQuickCard: isQuickCard,
      cardType: cardType,
    );

    final updatedMessages = List<GroupMessageModel>.from(convoy.messages)..add(msg);
    _allConvoys[_activeGroupId!] = convoy.copyWith(messages: updatedMessages);
    _oracleService.saveOrUpdateConvoy(_allConvoys[_activeGroupId!]!);

    try {
      FirebaseDatabase.instance
          .ref('groups/$_activeGroupId/messages/${msg.messageId}')
          .set(msg.toJson())
          .timeout(const Duration(milliseconds: 500))
          .catchError((_) {});
    } catch (_) {}

    notifyListeners();
  }

  /// Request 2-Minute Pull-Over Wait Timer across convoy
  void requestWait(String requesterName) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId]!;
    final now = DateTime.now().millisecondsSinceEpoch;

    final updatedWait = Map<String, int>.from(convoy.waitRequests);
    updatedWait[requesterName] = now;
    _allConvoys[_activeGroupId!] = convoy.copyWith(waitRequests: updatedWait);

    try {
      FirebaseDatabase.instance
          .ref('groups/$_activeGroupId/waitRequests/$requesterName')
          .set(now)
          .timeout(const Duration(milliseconds: 500))
          .catchError((_) {});
    } catch (_) {}

    sendGroupMessage(
      senderId: 'SYSTEM',
      senderName: requesterName,
      text: '⏱️ Requested a 2-minute pull-over stop. Please regroup safely.',
      isQuickCard: true,
      cardType: 'WAIT_2MIN',
    );

    notifyListeners();
  }

  /// Add a planned route stop / POI checkpoint
  void addStopPoint({
    required String name,
    required double lat,
    required double lng,
    String category = 'REST',
  }) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId]!;
    final stop = StopPointModel(
      stopId: 'STOP-${const Uuid().v4().substring(0, 6)}',
      name: name,
      lat: lat,
      lng: lng,
      orderIndex: convoy.stopPoints.length + 1,
      category: category,
    );

    final updatedStops = List<StopPointModel>.from(convoy.stopPoints)..add(stop);
    _allConvoys[_activeGroupId!] = convoy.copyWith(stopPoints: updatedStops);

    try {
      FirebaseDatabase.instance
          .ref('groups/$_activeGroupId/stopPoints/${stop.stopId}')
          .set(stop.toJson())
          .timeout(const Duration(milliseconds: 500))
          .catchError((_) {});
    } catch (_) {}

    notifyListeners();
  }

  /// Toggle stop point visited state
  void toggleStopVisited(String stopId, bool isVisited) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId]!;
    final updatedStops = convoy.stopPoints.map((s) {
      if (s.stopId == stopId) {
        return s.copyWith(isVisited: isVisited);
      }
      return s;
    }).toList();

    _allConvoys[_activeGroupId!] = convoy.copyWith(stopPoints: updatedStops);

    try {
      FirebaseDatabase.instance
          .ref('groups/$_activeGroupId/stopPoints/$stopId/isVisited')
          .set(isVisited)
          .timeout(const Duration(milliseconds: 500))
          .catchError((_) {});
    } catch (_) {}

    notifyListeners();
  }

  /// Update trip lifecycle state ('STARTED', 'PAUSED', 'ENDED')
  void updateTripState(String state) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId]!;
    _allConvoys[_activeGroupId!] = convoy.copyWith(tripStatus: state);
    _oracleService.saveOrUpdateConvoy(_allConvoys[_activeGroupId!]!);

    try {
      FirebaseDatabase.instance
          .ref('groups/$_activeGroupId/tripStatus')
          .set(state)
          .timeout(const Duration(milliseconds: 500))
          .catchError((_) {});
    } catch (_) {}

    // Stop GPS tracking and save journey when trip ends
    if (state == 'ENDED') {
      final tripHistory = buildTripHistory(convoy);
      _persistTripHistoryToCloud(tripHistory, convoy.createdByUserId);
      SharedPreferences.getInstance().then((p) => p.remove(AppConstants.keyActiveGroupId)).ignore();
      stopRealGpsTracking();
    }

    notifyListeners();
  }

  /// Set rider stopped status reason (Fuel, Rest, Mechanical, etc.)
  void updateStatusReason({
    required String userId,
    required String reason,
    String message = '',
  }) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId]!;
    final rider = convoy.riders[userId];
    if (rider == null) return;

    final updated = rider.copyWith(
      statusReason: reason,
      statusMessage: message,
      stoppedSince: reason.isEmpty ? 0 : DateTime.now().millisecondsSinceEpoch,
    );

    updateRiderLocation(updated);
  }

  /// Assign Co-rider / Pillion to a driver
  void setCoRiderDriver(String riderId, String driverId) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId]!;
    final rider = convoy.riders[riderId];
    if (rider == null) return;

    final updated = rider.copyWith(
      isCoRiding: driverId.isNotEmpty,
      ridingWithUserId: driverId,
    );

    updateRiderLocation(updated);
  }

  /// Update Group Configuration Thresholds
  void updateGroupConfig({
    double? distanceThresholdMeters,
    int? stopThresholdSeconds,
    bool? voiceGuidanceEnabled,
  }) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId]!;
    final updated = convoy.copyWith(
      distanceThresholdMeters: distanceThresholdMeters,
      stopThresholdSeconds: stopThresholdSeconds,
      voiceGuidanceEnabled: voiceGuidanceEnabled,
    );

    _allConvoys[_activeGroupId!] = updated;
    _oracleService.saveOrUpdateConvoy(updated);

    try {
      final db = FirebaseDatabase.instance;
      if (distanceThresholdMeters != null) {
        db.ref('groups/$_activeGroupId/distanceThresholdMeters').set(distanceThresholdMeters).timeout(const Duration(milliseconds: 500)).catchError((_) {});
      }
      if (stopThresholdSeconds != null) {
        db.ref('groups/$_activeGroupId/stopThresholdSeconds').set(stopThresholdSeconds).timeout(const Duration(milliseconds: 500)).catchError((_) {});
      }
      if (voiceGuidanceEnabled != null) {
        db.ref('groups/$_activeGroupId/voiceGuidanceEnabled').set(voiceGuidanceEnabled).timeout(const Duration(milliseconds: 500)).catchError((_) {});
      }
    } catch (_) {}

    notifyListeners();
  }

  /// Broadcast SOS Emergency Alert
  void triggerSosAlert({
    required String userId,
    required String userName,
    required double lat,
    required double lng,
    String type = 'EMERGENCY',
  }) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId]!;
    final alert = SosAlertModel(
      alertId: 'SOS-${const Uuid().v4()}',
      userId: userId,
      userName: userName,
      lat: lat,
      lng: lng,
      alertType: type,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    final updatedAlerts = List<SosAlertModel>.from(
      convoy.activeAlerts.where((a) => !a.resolved && !_resolvedAlertIds.contains(a.alertId)),
    )..add(alert);
    final updated = convoy.copyWith(activeAlerts: updatedAlerts);
    _allConvoys[_activeGroupId!] = updated;
    _oracleService.saveOrUpdateConvoy(updated);
    _syncAlertToFirebase(_activeGroupId!, alert);
    notifyListeners();
  }

  /// Resolve SOS Alert
  void resolveSosAlert(String alertId) {
    if (_activeGroupId == null) return;
    _resolvedAlertIds.add(alertId);
    final convoy = _allConvoys[_activeGroupId]!;
    final updatedAlerts = convoy.activeAlerts.where((a) => a.alertId != alertId).toList();
    final updated = convoy.copyWith(activeAlerts: updatedAlerts);
    _allConvoys[_activeGroupId!] = updated;
    _oracleService.saveOrUpdateConvoy(updated);
    _resolveAlertInFirebase(_activeGroupId!, alertId);
    notifyListeners();
  }

  /// Master Admin: Dissolve / Force End Convoy
  void adminDissolveConvoy(String groupId) {
    _allConvoys.remove(groupId);
    if (_activeGroupId == groupId) {
      stopRealGpsTracking();
      _activeGroupId = null;
    }
    _deleteConvoyInFirebase(groupId);
    notifyListeners();
  }

  /// Master Admin: Send Fleet-wide Safety Announcement
  void adminBroadcastSafetyAlert(String message) {
    _systemBroadcastMessage = message;
    _broadcastAdminAlertToFirebase(message);
    notifyListeners();
    Future.delayed(const Duration(seconds: 12), () {
      _systemBroadcastMessage = null;
      notifyListeners();
    });
  }

  /// Update current user's location (syncs to local state + Firebase)
  void updateRiderLocation(RiderModel updatedRider) {
    if (_activeGroupId == null) return;
    final convoy = _allConvoys[_activeGroupId];
    if (convoy == null) return;
    final updatedRiders = Map<String, RiderModel>.from(convoy.riders);
    updatedRiders[updatedRider.userId] = updatedRider;
    _allConvoys[_activeGroupId!] = convoy.copyWith(riders: updatedRiders);
    _syncRiderLocationToFirebase(_activeGroupId!, updatedRider);
    notifyListeners();
  }

  // --- FIREBASE SYNC HELPERS ---

  void _syncConvoyToFirebase(ConvoyModel convoy) {
    try {
      final db = FirebaseDatabase.instance;
      db.ref('groups/${convoy.groupId}').set(convoy.toJson()).timeout(const Duration(milliseconds: 500)).catchError((_) {});
      db.ref('joinCodes/${convoy.joinCode}').set(convoy.groupId).timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (e) {
      debugPrint('Firebase Convoy Sync Note: $e');
    }
  }

  void _syncRiderLocationToFirebase(String groupId, RiderModel rider) {
    try {
      final db = FirebaseDatabase.instance;
      db.ref('groups/$groupId/riders/${rider.userId}').set(rider.toJson()).timeout(const Duration(milliseconds: 500)).catchError((_) {});
      db.ref('locations/${rider.userId}').set(rider.toJson()).timeout(const Duration(milliseconds: 500)).catchError((_) {});
      db.ref('users/${rider.userId}/lastLocation').set({
        ...rider.toJson(),
        'groupId': groupId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }).timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (e) {
      debugPrint('Firebase Location Sync Note: $e');
    }
  }

  void _syncAlertToFirebase(String groupId, SosAlertModel alert) {
    try {
      final db = FirebaseDatabase.instance;
      db.ref('groups/$groupId/alerts/${alert.alertId}').set(alert.toJson()).timeout(const Duration(milliseconds: 500)).catchError((_) {});
      db.ref('alerts/${alert.alertId}').set(alert.toJson()).timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (e) {
      debugPrint('Firebase Alert Sync Note: $e');
    }
  }

  void _resolveAlertInFirebase(String groupId, String alertId) {
    try {
      final db = FirebaseDatabase.instance;
      db.ref('groups/$groupId/alerts/$alertId/resolved').set(true).timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (e) {
      debugPrint('Firebase Alert Resolve Note: $e');
    }
  }

  void _deleteConvoyInFirebase(String groupId) {
    try {
      final db = FirebaseDatabase.instance;
      db.ref('groups/$groupId').remove().timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (e) {
      debugPrint('Firebase Convoy Delete Note: $e');
    }
  }

  void _broadcastAdminAlertToFirebase(String message) {
    try {
      final db = FirebaseDatabase.instance;
      db.ref('system_broadcast').set({
        'message': message,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }).timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (e) {
      debugPrint('Firebase Broadcast Note: $e');
    }
  }

  void _attachGroupListeners(String groupId) {
    _locationsSub?.cancel();
    _alertsSub?.cancel();
    _messagesSub?.cancel();
    _stopsSub?.cancel();
    _waitRequestsSub?.cancel();
    _tripStatusSub?.cancel();
    _configSub?.cancel();

    try {
      final db = FirebaseDatabase.instance;

      // Realtime Riders Listener
      _locationsSub = db.ref('groups/$groupId/riders').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is Map) {
          final updatedRiders = <String, RiderModel>{};
          val.forEach((k, v) {
            if (v is Map) {
              final m = Map<String, dynamic>.from(v);
              updatedRiders[k.toString()] = RiderModel.fromJson(m);
            }
          });
          if (_allConvoys.containsKey(groupId)) {
            final merged = Map<String, RiderModel>.from(_allConvoys[groupId]!.riders);
            updatedRiders.forEach((userId, incomingRider) {
              final existing = merged[userId];
              if (existing == null || incomingRider.lastSeenEpochMs >= existing.lastSeenEpochMs) {
                merged[userId] = incomingRider;
              }
            });
            _allConvoys[groupId] = _allConvoys[groupId]!.copyWith(riders: merged);
            notifyListeners();
          }
        }
      });

      // Realtime Alerts Listener
      _alertsSub = db.ref('groups/$groupId/alerts').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is Map) {
          final alertsList = <SosAlertModel>[];
          val.forEach((k, v) {
            if (v is Map) {
              final m = Map<String, dynamic>.from(v);
              final alert = SosAlertModel.fromJson(m);
              if (!alert.resolved && !_resolvedAlertIds.contains(alert.alertId)) {
                alertsList.add(alert);
              }
            }
          });
          if (_allConvoys.containsKey(groupId)) {
            _allConvoys[groupId] = _allConvoys[groupId]!.copyWith(activeAlerts: alertsList);
            notifyListeners();
          }
        } else {
          // No alerts exist — clear any stale local alerts
          if (_allConvoys.containsKey(groupId)) {
            _allConvoys[groupId] = _allConvoys[groupId]!.copyWith(activeAlerts: []);
            notifyListeners();
          }
        }
      });

      // Realtime Messages Listener
      _messagesSub = db.ref('groups/$groupId/messages').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is Map) {
          final msgList = <GroupMessageModel>[];
          val.forEach((k, v) {
            if (v is Map) {
              final m = Map<String, dynamic>.from(v);
              msgList.add(GroupMessageModel.fromJson(m));
            }
          });
          msgList.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          if (_allConvoys.containsKey(groupId)) {
            _allConvoys[groupId] = _allConvoys[groupId]!.copyWith(messages: msgList);
            notifyListeners();
          }
        }
      });

      // Realtime Stops Listener
      _stopsSub = db.ref('groups/$groupId/stopPoints').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is Map) {
          final stopsList = <StopPointModel>[];
          val.forEach((k, v) {
            if (v is Map) {
              final m = Map<String, dynamic>.from(v);
              stopsList.add(StopPointModel.fromJson(m));
            }
          });
          stopsList.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
          if (_allConvoys.containsKey(groupId)) {
            _allConvoys[groupId] = _allConvoys[groupId]!.copyWith(stopPoints: stopsList);
            notifyListeners();
          }
        }
      });

      // Realtime Wait Requests Listener
      _waitRequestsSub = db.ref('groups/$groupId/waitRequests').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is Map) {
          final waitMap = <String, int>{};
          val.forEach((k, v) {
            if (v is num) {
              waitMap[k.toString()] = v.toInt();
            }
          });
          if (_allConvoys.containsKey(groupId)) {
            _allConvoys[groupId] = _allConvoys[groupId]!.copyWith(waitRequests: waitMap);
            notifyListeners();
          }
        }
      });

      // Realtime Trip Status Listener
      _tripStatusSub = db.ref('groups/$groupId/tripStatus').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is String && _allConvoys.containsKey(groupId)) {
          _allConvoys[groupId] = _allConvoys[groupId]!.copyWith(tripStatus: val);
          notifyListeners();
        }
      });

      // Realtime Config Listener (distance threshold, stop threshold, voice)
      _configSub = db.ref('groups/$groupId').onValue.listen((event) {
        final val = event.snapshot.value;
        if (val is Map && _allConvoys.containsKey(groupId)) {
          final data = Map<String, dynamic>.from(val);
          final current = _allConvoys[groupId]!;
          _allConvoys[groupId] = current.copyWith(
            distanceThresholdMeters: (data['distanceThresholdMeters'] as num?)?.toDouble(),
            stopThresholdSeconds: (data['stopThresholdSeconds'] as num?)?.toInt(),
            voiceGuidanceEnabled: data['voiceGuidanceEnabled'] as bool?,
          );
          // Don't notify here — other listeners already cover sub-paths
        }
      });

      // Realtime Voice Bursts Listener (Intercom)
      _voiceBurstSub = db.ref('groups/$groupId/voiceBursts').limitToLast(1).onChildAdded.listen((event) {
        final val = event.snapshot.value;
        if (val is Map) {
          final burst = Map<String, dynamic>.from(val);
          _voiceBurstController.add(burst);
        }
      });
    } catch (e) {
      debugPrint('Firebase Listener Attach Note: $e');
    }
  }

  /// Start high-cadence Intercom voice polling via Oracle 26ai Cloud SODA (1.2s cadence)
  void _startVoicePolling(String groupId) {
    _voicePollTimer?.cancel();
    _lastVoiceBurstTimestamp = DateTime.now().millisecondsSinceEpoch - 5000;
    _voicePollTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) async {
      if (_activeGroupId != groupId) return;
      try {
        final bursts = await _oracleService.fetchRecentVoiceBursts(groupId, _lastVoiceBurstTimestamp);
        for (final burst in bursts) {
          final burstTs = (burst['timestamp'] as num?)?.toInt() ?? 0;
          final burstKey = '${burst['senderId']}_$burstTs';
          if (!_processedVoiceBurstKeys.contains(burstKey)) {
            _processedVoiceBurstKeys.add(burstKey);
            if (burstTs > _lastVoiceBurstTimestamp) {
              _lastVoiceBurstTimestamp = burstTs;
            }
            _voiceBurstController.add(burst);
          }
        }
        if (_processedVoiceBurstKeys.length > 500) {
          _processedVoiceBurstKeys.clear();
        }
      } catch (e) {
        // Silent catch for background audio polling
      }
    });
  }

  /// Broadcast a voice burst packet over Oracle 26ai Cloud SODA + Firebase
  Future<void> sendVoiceBurst({
    required String senderId,
    required String senderName,
    required String audioBase64,
    required int durationMs,
  }) async {
    if (_activeGroupId == null) return;
    try {
      // 1. Post to Oracle 26ai Autonomous Database SODA collection 'voice_bursts'
      await _oracleService.sendVoiceBurst(
        groupId: _activeGroupId!,
        senderId: senderId,
        senderName: senderName,
        audioBase64: audioBase64,
        durationMs: durationMs,
      );

      // 2. Also push to Firebase Realtime Database if available
      final burstId = 'VB-${const Uuid().v4().substring(0, 8)}';
      FirebaseDatabase.instance.ref('groups/$_activeGroupId/voiceBursts/$burstId').set({
        'burstId': burstId,
        'senderId': senderId,
        'senderName': senderName,
        'audioBase64': audioBase64,
        'durationMs': durationMs,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }).timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (e) {
      debugPrint('sendVoiceBurst Note: $e');
    }
  }

  void _detachGroupListeners() {
    _voicePollTimer?.cancel();
    _locationsSub?.cancel();
    _alertsSub?.cancel();
    _messagesSub?.cancel();
    _stopsSub?.cancel();
    _waitRequestsSub?.cancel();
    _tripStatusSub?.cancel();
    _configSub?.cancel();
    _voiceBurstSub?.cancel();
  }

  @override
  void dispose() {
    _gpsPositionSub?.cancel();
    _compassSub?.cancel();
    _voicePollTimer?.cancel();
    _detachGroupListeners();
    _voiceBurstController.close();
    _adminFleetSub?.cancel();
    super.dispose();
  }
}
