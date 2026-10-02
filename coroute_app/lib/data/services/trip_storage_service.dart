import 'dart:convert';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../models/trip_history_model.dart';
import 'oracle_ai_service.dart';

class TripStorageService extends ChangeNotifier {
  List<TripHistoryModel> _trips = [];
  bool _isLoading = true;
  final OracleAiService _oracleAiService = OracleAiService();

  List<TripHistoryModel> get trips => List.unmodifiable(_trips);
  bool get isLoading => _isLoading;

  TripStorageService() {
    loadSavedTrips();
  }

  /// Initial load from local persistent storage, followed by cloud synchronization
  Future<void> loadSavedTrips({String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConstants.keyTripHistory);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _trips = decoded
            .whereType<Map<String, dynamic>>()
            .map((e) => TripHistoryModel.fromJson(e))
            .toList();
        _trips.sort((a, b) => b.endTimeEpochMs.compareTo(a.endTimeEpochMs));
      }
    } catch (e) {
      debugPrint('Error loading local trip history: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }

    // Background sync with Firebase and Oracle Cloud to fetch any remote trips
    syncWithCloud(userId: userId).ignore();
  }

  /// Synchronize trip records between Local Storage, Firebase RTDB, and Oracle 26ai Cloud
  Future<int> syncWithCloud({String? userId}) async {
    int newTripsCount = 0;
    final Map<String, TripHistoryModel> mergedMap = {
      for (final t in _trips) t.tripId: t,
    };

    // 1. Fetch from Oracle 26ai Autonomous Database
    try {
      final oracleTrips = await _oracleAiService.fetchTripsFromOracle();
      for (final t in oracleTrips) {
        if (!mergedMap.containsKey(t.tripId)) {
          mergedMap[t.tripId] = t;
          newTripsCount++;
        }
      }
    } catch (e) {
      debugPrint('Oracle cloud trips sync note: $e');
    }

    // 2. Fetch from Firebase Realtime Database
    try {
      final db = FirebaseDatabase.instance;
      final cleanUid = (userId != null && userId.isNotEmpty)
          ? 'usr_${userId.toLowerCase().replaceAll(' ', '_')}'
          : null;

      // Query user-specific trips
      if (cleanUid != null) {
        final userTripsSnap = await db.ref('users/$cleanUid/trips').get().timeout(const Duration(seconds: 3));
        if (userTripsSnap.exists && userTripsSnap.value is Map) {
          final m = Map<String, dynamic>.from(userTripsSnap.value as Map);
          m.forEach((_, v) {
            if (v is Map) {
              try {
                final t = TripHistoryModel.fromJson(Map<String, dynamic>.from(v));
                if (!mergedMap.containsKey(t.tripId)) {
                  mergedMap[t.tripId] = t;
                  newTripsCount++;
                }
              } catch (_) {}
            }
          });
        }
      }

      // Query global trips collection (recent 30)
      final globalTripsSnap = await db.ref('trips').limitToLast(30).get().timeout(const Duration(seconds: 3));
      if (globalTripsSnap.exists && globalTripsSnap.value is Map) {
        final m = Map<String, dynamic>.from(globalTripsSnap.value as Map);
        m.forEach((_, v) {
          if (v is Map) {
            try {
              final t = TripHistoryModel.fromJson(Map<String, dynamic>.from(v));
              if (!mergedMap.containsKey(t.tripId)) {
                mergedMap[t.tripId] = t;
                newTripsCount++;
              }
            } catch (_) {}
          }
        });
      }
    } catch (e) {
      debugPrint('Firebase cloud trips sync note: $e');
    }

    if (newTripsCount > 0 || mergedMap.length != _trips.length) {
      _trips = mergedMap.values.toList()
        ..sort((a, b) => b.endTimeEpochMs.compareTo(a.endTimeEpochMs));
      notifyListeners();
      await _persist();
    }

    return newTripsCount;
  }

  /// Save trip locally and distribute across Firebase RTDB and Oracle 26ai Cloud
  Future<void> saveTrip(TripHistoryModel trip, {String? userId}) async {
    // 1. Local memory & SharedPreferences
    final index = _trips.indexWhere((t) => t.tripId == trip.tripId);
    if (index >= 0) {
      _trips[index] = trip;
    } else {
      _trips.insert(0, trip);
    }
    notifyListeners();
    await _persist();

    final tripData = trip.toJson();

    // 2. Persist to Firebase Realtime Database
    try {
      final db = FirebaseDatabase.instance;
      final targetUserId = (userId != null && userId.isNotEmpty)
          ? userId
          : (trip.userId.isNotEmpty ? trip.userId : 'usr_rider');
      final cleanUid = 'usr_${targetUserId.toLowerCase().replaceAll('usr_', '').replaceAll(' ', '_')}';

      // Save under user's private collection
      db.ref('users/$cleanUid/trips/${trip.tripId}').set(tripData).timeout(const Duration(seconds: 2)).catchError((_) {});

      // Save under global fleet trips collection
      db.ref('trips/${trip.tripId}').set(tripData).timeout(const Duration(seconds: 2)).catchError((_) {});
    } catch (e) {
      debugPrint('Firebase save trip note: $e');
    }

    // 3. Persist to Oracle 26ai Autonomous Database SODA
    try {
      _oracleAiService.saveTripToOracle(trip).catchError((e) {
        debugPrint('Oracle save trip note: $e');
        return false;
      });
    } catch (e) {
      debugPrint('Oracle trip persist exception: $e');
    }
  }

  Future<void> deleteTrip(String tripId) async {
    _trips.removeWhere((t) => t.tripId == tripId);
    notifyListeners();
    await _persist();

    try {
      FirebaseDatabase.instance.ref('trips/$tripId').remove().timeout(const Duration(milliseconds: 500)).catchError((_) {});
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _trips.map((e) => e.toJson()).toList();
      await prefs.setString(AppConstants.keyTripHistory, jsonEncode(jsonList));
    } catch (e) {
      debugPrint('Failed to persist trips to preferences: $e');
    }
  }
}
