import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../models/trip_history_model.dart';
import 'api_client.dart';

/// Journey history: a local cache for instant display + the gateway as the
/// durable store. Trip summaries (name, members, dates, statistics) are kept
/// forever on the server; only GPS trails are trimmed by server-side retention.
class TripStorageService extends ChangeNotifier {
  TripStorageService(this._api) {
    loadSavedTrips();
  }

  final ApiClient _api;
  List<TripHistoryModel> _trips = [];
  bool _isLoading = true;
  final List<TripHistoryModel> _pendingUpload = [];

  List<TripHistoryModel> get trips => List.unmodifiable(_trips);
  bool get isLoading => _isLoading;

  Future<void> loadSavedTrips({String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConstants.keyTripHistory);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _trips = decoded.whereType<Map>().map((e) => TripHistoryModel.fromJson(Map<String, dynamic>.from(e))).toList();
        _trips.sort((a, b) => b.endTimeEpochMs.compareTo(a.endTimeEpochMs));
      }
      final pending = prefs.getString('${AppConstants.keyTripHistory}_pending');
      if (pending != null && pending.isNotEmpty) {
        _pendingUpload.addAll((jsonDecode(pending) as List).whereType<Map>().map((e) => TripHistoryModel.fromJson(Map<String, dynamic>.from(e))));
      }
    } catch (e) {
      debugPrint('Error loading local trip history: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
    syncWithCloud(userId: userId).ignore();
  }

  /// Pulls the signed-in rider's trips from the gateway and merges them in.
  /// Returns the number of trips that were new on this device.
  Future<int> syncWithCloud({String? userId}) async {
    if (!_api.hasToken) return 0;
    await _flushPending();
    int added = 0;
    try {
      final res = await _api.get('/trips');
      final list = (res is Map ? res['trips'] : null);
      if (list is List) {
        final merged = {for (final t in _trips) t.tripId: t};
        for (final raw in list.whereType<Map>()) {
          final t = TripHistoryModel.fromJson(Map<String, dynamic>.from(raw));
          if (!merged.containsKey(t.tripId)) added++;
          merged[t.tripId] = t; // server copy wins
        }
        _trips = merged.values.toList()..sort((a, b) => b.endTimeEpochMs.compareTo(a.endTimeEpochMs));
        notifyListeners();
        await _persist();
      }
    } catch (e) {
      debugPrint('Trip sync note: $e');
    }
    return added;
  }

  /// Saves locally at once and uploads; retries later if offline.
  Future<void> saveTrip(TripHistoryModel trip, {String? userId}) async {
    final index = _trips.indexWhere((t) => t.tripId == trip.tripId);
    if (index >= 0) {
      _trips[index] = trip;
    } else {
      _trips.insert(0, trip);
    }
    notifyListeners();
    await _persist();

    try {
      await _api.post('/trips', trip.toJson());
    } catch (e) {
      debugPrint('Trip upload deferred: $e');
      _pendingUpload.removeWhere((t) => t.tripId == trip.tripId);
      _pendingUpload.add(trip);
      await _persistPending();
    }
  }

  Future<void> deleteTrip(String tripId) async {
    _trips.removeWhere((t) => t.tripId == tripId);
    _pendingUpload.removeWhere((t) => t.tripId == tripId);
    notifyListeners();
    await _persist();
    await _persistPending();
    try {
      await _api.delete('/trips/$tripId');
    } catch (e) {
      debugPrint('Trip delete note: $e');
    }
  }

  Future<void> clearLocal() async {
    _trips = [];
    _pendingUpload.clear();
    notifyListeners();
    await _persist();
    await _persistPending();
  }

  Future<void> _flushPending() async {
    if (_pendingUpload.isEmpty) return;
    final copy = List<TripHistoryModel>.from(_pendingUpload);
    for (final t in copy) {
      try {
        await _api.post('/trips', t.toJson());
        _pendingUpload.remove(t);
      } catch (_) {
        break; // still offline
      }
    }
    await _persistPending();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.keyTripHistory, jsonEncode(_trips.map((e) => e.toJson()).toList()));
    } catch (e) {
      debugPrint('Failed to persist trips: $e');
    }
  }

  Future<void> _persistPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('${AppConstants.keyTripHistory}_pending', jsonEncode(_pendingUpload.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }
}
