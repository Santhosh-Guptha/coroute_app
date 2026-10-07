import 'dart:collection';
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

  /// Full trips (with trails) opened recently, newest last. At most [_fullCacheSize].
  final LinkedHashMap<String, TripHistoryModel> _fullCache = LinkedHashMap<String, TripHistoryModel>();
  static const int _fullCacheSize = 5;

  int _revision = 0;

  List<TripHistoryModel> get trips => List.unmodifiable(_trips);
  bool get isLoading => _isLoading;

  /// Goes up by one on every change of the trip list. [trips] returns a new list each time,
  /// so screens that cache work on the list compare this number instead.
  int get revision => _revision;

  @override
  void notifyListeners() {
    _revision++;
    super.notifyListeners();
  }

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
        // A trip still waiting for upload keeps its trail on the phone.
        for (final p in _pendingUpload) {
          final i = _trips.indexWhere((t) => t.tripId == p.tripId);
          if (i >= 0 && _trips[i].breadcrumbTrail.isEmpty && p.breadcrumbTrail.isNotEmpty) _trips[i] = p;
        }
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
      // Summaries only: trails are loaded when a trip is opened (see loadFull).
      final res = await _api.get('/trips?summary=1');
      final list = (res is Map ? res['trips'] : null);
      if (list is List) {
        final merged = {for (final t in _trips) t.tripId: t};
        for (final raw in list.whereType<Map>()) {
          final t = TripHistoryModel.fromJson(Map<String, dynamic>.from(raw));
          final local = merged[t.tripId];
          if (local == null) added++;
          merged[t.tripId] = mergeServerTrip(t, local); // server copy wins
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

  /// The server summary replaces the local trip; a trail already in memory is kept when it is
  /// the same route (same number of points), so the phone does not download it again.
  @visibleForTesting
  static TripHistoryModel mergeServerTrip(TripHistoryModel server, TripHistoryModel? local) {
    if (local == null || server.breadcrumbTrail.isNotEmpty || local.breadcrumbTrail.isEmpty) return server;
    if (server.trailPoints != 0 && server.trailPoints != local.breadcrumbTrail.length) return server;
    return server.withTrail(local.breadcrumbTrail);
  }

  /// The trip with its full trail: from memory, from the small cache, or from the server
  /// (GET /trips/:tripId). Throws [ApiException] when it cannot be loaded (offline: statusCode 0).
  Future<TripHistoryModel> loadFull(String tripId) async {
    final cached = _fullCache.remove(tripId);
    if (cached != null) {
      _fullCache[tripId] = cached; // most recent last
      return cached;
    }
    for (final t in _trips) {
      if (t.tripId == tripId && t.breadcrumbTrail.isNotEmpty) return t;
    }
    final res = await _api.get('/trips/${Uri.encodeComponent(tripId)}', timeout: const Duration(seconds: 20));
    final raw = res is Map ? res['trip'] : null;
    if (raw is! Map) throw const ApiException(404, 'Trip not found.');
    final full = TripHistoryModel.fromJson(Map<String, dynamic>.from(raw));
    _fullCache[tripId] = full;
    while (_fullCache.length > _fullCacheSize) {
      _fullCache.remove(_fullCache.keys.first);
    }
    return full;
  }

  /// A trail that is already in memory (no network), or null.
  TripHistoryModel? cachedFull(String tripId) => _fullCache[tripId];

  Future<void> deleteTrip(String tripId) async {
    _fullCache.remove(tripId);
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
    _fullCache.clear();
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
      } on ApiException catch (e) {
        // The server refused this trip for good (invalid, too large, too many trips): stop retrying it.
        if (isPermanentRefusal(e.statusCode)) {
          _pendingUpload.remove(t);
          continue;
        }
        break; // offline, signed out or server busy: try again later
      } catch (_) {
        break; // still offline
      }
    }
    await _persistPending();
  }

  /// 4xx answers that will never succeed on retry (not 401 signed out, 408 timeout or 429 slow down).
  @visibleForTesting
  static bool isPermanentRefusal(int status) => status >= 400 && status < 500 && status != 401 && status != 408 && status != 429;

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Summaries only: SharedPreferences is read fully into memory at start, so no trails here.
      await prefs.setString(AppConstants.keyTripHistory, jsonEncode(_trips.map((e) => e.toStorageJson()).toList()));
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
