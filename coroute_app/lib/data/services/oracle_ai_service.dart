import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/convoy_model.dart';
import '../models/rider_model.dart';
import '../models/trip_history_model.dart';

class OracleAiService extends ChangeNotifier {
  static const String sodaBaseUrl =
      'https://gfe473165e66472-coroutedb.adb.ap-hyderabad-1.oraclecloudapps.com/ords/admin/soda/latest';
  static const String _authHeader =
      'Basic QURNSU46RGV2TW9ua3MjT3JhY2xlMjZhaSE='; // ADMIN:DevMonks#Oracle26ai!

  final Map<String, String> _docIdByGroupId = {};
  bool _isOnline = false;
  int _syncedTripCount = 0;

  bool get isOnline => _isOnline;
  int get syncedTripCount => _syncedTripCount;

  OracleAiService() {
    checkHealth();
  }

  /// Check connectivity to Oracle 26ai Autonomous Database
  Future<bool> checkHealth() async {
    try {
      final res = await http.get(
        Uri.parse(sodaBaseUrl),
        headers: {
          'Authorization': _authHeader,
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 3));

      _isOnline = (res.statusCode == 200);
      notifyListeners();
      return _isOnline;
    } catch (e) {
      debugPrint('Oracle 26ai Health Check: $e');
      _isOnline = false;
      notifyListeners();
      return false;
    }
  }

  /// Fetch active convoy from Oracle 26ai by 6-digit join code
  Future<ConvoyModel?> fetchConvoyByCode(String joinCode) async {
    final clean = joinCode.trim().toUpperCase();
    try {
      final url = Uri.parse('$sodaBaseUrl/convoys?action=query');
      final res = await http.post(
        url,
        headers: {
          'Authorization': _authHeader,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'joinCode': clean}),
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['items'] is List && (decoded['items'] as List).isNotEmpty) {
          final item = decoded['items'][0];
          final docId = item['id']?.toString();
          final val = Map<String, dynamic>.from(item['value'] as Map);
          if (docId != null && val['groupId'] != null) {
            _docIdByGroupId[val['groupId'].toString()] = docId;
          }
          debugPrint('Oracle 26ai: Found convoy by code $clean -> ${val['groupId']}');
          return ConvoyModel.fromJson(val);
        }
      }
    } catch (e) {
      debugPrint('Oracle fetchConvoyByCode query error: $e');
    }

    // Fallback: query all convoys and match joinCode locally
    try {
      final all = await fetchActiveConvoysFromOracle();
      for (final c in all) {
        if (c.joinCode.trim().toUpperCase() == clean) {
          debugPrint('Oracle 26ai: Found convoy by fallback scan -> ${c.groupId}');
          return c;
        }
      }
    } catch (e) {
      debugPrint('Oracle fetchConvoyByCode fallback error: $e');
    }

    return null;
  }

  /// Fetch single convoy by groupId from Oracle 26ai
  Future<ConvoyModel?> fetchConvoyByGroupId(String groupId) async {
    try {
      // 1. Direct GET by SODA document ID if cached
      final docId = _docIdByGroupId[groupId];
      if (docId != null) {
        final url = Uri.parse('$sodaBaseUrl/convoys/$docId');
        final res = await http.get(
          url,
          headers: {
            'Authorization': _authHeader,
            'Accept': 'application/json',
          },
        ).timeout(const Duration(seconds: 3));

        if (res.statusCode == 200) {
          final val = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
          return ConvoyModel.fromJson(val);
        }
      }

      // 2. Query by groupId
      final queryUrl = Uri.parse('$sodaBaseUrl/convoys?action=query');
      final res = await http.post(
        queryUrl,
        headers: {
          'Authorization': _authHeader,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'groupId': groupId}),
      ).timeout(const Duration(seconds: 3));

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['items'] is List && (decoded['items'] as List).isNotEmpty) {
          final item = decoded['items'][0];
          final dId = item['id']?.toString();
          final val = Map<String, dynamic>.from(item['value'] as Map);
          if (dId != null) {
            _docIdByGroupId[groupId] = dId;
          }
          return ConvoyModel.fromJson(val);
        }
      }
    } catch (e) {
      debugPrint('Oracle fetchConvoyByGroupId error: $e');
    }
    return null;
  }

  /// Fetch all active convoys stored in Oracle 26ai
  Future<List<ConvoyModel>> fetchActiveConvoysFromOracle() async {
    try {
      final url = Uri.parse('$sodaBaseUrl/convoys');
      final res = await http.get(
        url,
        headers: {
          'Authorization': _authHeader,
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['items'] is List) {
          final List<ConvoyModel> list = [];
          for (final item in decoded['items']) {
            if (item is Map && item['value'] is Map) {
              final docId = item['id']?.toString();
              final val = Map<String, dynamic>.from(item['value'] as Map);
              if (docId != null && val['groupId'] != null) {
                _docIdByGroupId[val['groupId'].toString()] = docId;
              }
              list.add(ConvoyModel.fromJson(val));
            }
          }
          return list;
        }
      }
    } catch (e) {
      debugPrint('Oracle fetchActiveConvoys exception: $e');
    }
    return [];
  }

  /// Create or replace convoy document in Oracle 26ai (prevents duplicate documents)
  Future<bool> saveOrUpdateConvoy(ConvoyModel convoy) async {
    try {
      String? docId = _docIdByGroupId[convoy.groupId];

      // Query docId if not cached
      if (docId == null) {
        final queryUrl = Uri.parse('$sodaBaseUrl/convoys?action=query');
        final qRes = await http.post(
          queryUrl,
          headers: {
            'Authorization': _authHeader,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({'groupId': convoy.groupId}),
        ).timeout(const Duration(seconds: 3));

        if (qRes.statusCode == 200) {
          final qDecoded = jsonDecode(qRes.body);
          if (qDecoded is Map && qDecoded['items'] is List && (qDecoded['items'] as List).isNotEmpty) {
            docId = qDecoded['items'][0]['id']?.toString();
            if (docId != null) {
              _docIdByGroupId[convoy.groupId] = docId;
            }
          }
        }
      }

      // Update existing document in place via PUT
      if (docId != null) {
        final putUrl = Uri.parse('$sodaBaseUrl/convoys/$docId');
        final res = await http.put(
          putUrl,
          headers: {
            'Authorization': _authHeader,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(convoy.toJson()),
        ).timeout(const Duration(seconds: 4));

        _isOnline = (res.statusCode == 200 || res.statusCode == 204);
        return _isOnline;
      }

      // Insert new document via POST
      final postUrl = Uri.parse('$sodaBaseUrl/convoys');
      final res = await http.post(
        postUrl,
        headers: {
          'Authorization': _authHeader,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(convoy.toJson()),
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 201 || res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['items'] is List && (decoded['items'] as List).isNotEmpty) {
          final newId = decoded['items'][0]['id']?.toString();
          if (newId != null) _docIdByGroupId[convoy.groupId] = newId;
        }
        _isOnline = true;
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Oracle saveOrUpdateConvoy exception: $e');
      return false;
    }
  }

  /// Sync active convoy session and checkpoint metadata to Oracle 26ai
  Future<bool> saveConvoyToOracle(ConvoyModel convoy) async {
    return saveOrUpdateConvoy(convoy);
  }

  /// Save rider registration profile to Oracle 26ai
  Future<bool> saveRiderProfileToOracle(RiderModel rider) async {
    try {
      final url = Uri.parse('$sodaBaseUrl/riders');
      final res = await http.post(
        url,
        headers: {
          'Authorization': _authHeader,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(rider.toJson()),
      ).timeout(const Duration(seconds: 4));

      return res.statusCode == 201 || res.statusCode == 200;
    } catch (e) {
      debugPrint('Oracle 26ai saveRiderProfile exception: $e');
      return false;
    }
  }

  /// Save completed journey and GPS breadcrumb trail to Oracle 26ai JSON store
  Future<bool> saveTripToOracle(TripHistoryModel trip) async {
    try {
      final url = Uri.parse('$sodaBaseUrl/trips');
      final res = await http.post(
        url,
        headers: {
          'Authorization': _authHeader,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(trip.toJson()),
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 201 || res.statusCode == 200) {
        _syncedTripCount++;
        _isOnline = true;
        notifyListeners();
        debugPrint('Trip ${trip.tripId} successfully persisted to Oracle 26ai');
        return true;
      } else {
        debugPrint('Oracle 26ai saveTrip error: ${res.statusCode} ${res.body}');
        return false;
      }
    } catch (e) {
      debugPrint('Oracle 26ai saveTrip exception: $e');
      return false;
    }
  }

  /// Fetch all historical trips stored in Oracle 26ai
  Future<List<TripHistoryModel>> fetchTripsFromOracle() async {
    try {
      final url = Uri.parse('$sodaBaseUrl/trips');
      final res = await http.get(
        url,
        headers: {
          'Authorization': _authHeader,
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['items'] is List) {
          final items = decoded['items'] as List;
          final List<TripHistoryModel> list = [];
          for (final item in items) {
            if (item is Map && item['value'] is Map) {
              list.add(TripHistoryModel.fromJson(Map<String, dynamic>.from(item['value'])));
            }
          }
          list.sort((a, b) => b.endTimeEpochMs.compareTo(a.endTimeEpochMs));
          return list;
        }
      }
    } catch (e) {
      debugPrint('Oracle 26ai fetchTrips exception: $e');
    }
    return [];
  }

  /// Broadcast voice burst packet to Oracle 26ai Cloud SODA
  Future<bool> sendVoiceBurst({
    required String groupId,
    required String senderId,
    required String senderName,
    required String audioBase64,
    required int durationMs,
  }) async {
    try {
      final url = Uri.parse('$sodaBaseUrl/voice_bursts');
      final body = jsonEncode({
        'groupId': groupId,
        'senderId': senderId,
        'senderName': senderName,
        'audioBase64': audioBase64,
        'durationMs': durationMs,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      final res = await http.post(
        url,
        headers: {
          'Authorization': _authHeader,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: body,
      ).timeout(const Duration(seconds: 4));

      return res.statusCode == 201 || res.statusCode == 200;
    } catch (e) {
      debugPrint('Oracle sendVoiceBurst exception: $e');
      return false;
    }
  }

  /// Fetch new voice bursts for a group since a timestamp from Oracle 26ai Cloud SODA
  Future<List<Map<String, dynamic>>> fetchRecentVoiceBursts(
    String groupId,
    int sinceTimestampEpochMs,
  ) async {
    try {
      final url = Uri.parse('$sodaBaseUrl/voice_bursts?action=query');
      final query = jsonEncode({
        'groupId': groupId,
        'timestamp': {r'$gt': sinceTimestampEpochMs},
      });

      final res = await http.post(
        url,
        headers: {
          'Authorization': _authHeader,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: query,
      ).timeout(const Duration(seconds: 3));

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['items'] is List) {
          final List<Map<String, dynamic>> list = [];
          for (final item in decoded['items']) {
            if (item is Map && item['value'] is Map) {
              list.add(Map<String, dynamic>.from(item['value'] as Map));
            }
          }
          list.sort((a, b) => ((a['timestamp'] as num?)?.toInt() ?? 0)
              .compareTo((b['timestamp'] as num?)?.toInt() ?? 0));
          return list;
        }
      }
    } catch (e) {
      debugPrint('Oracle fetchRecentVoiceBursts exception: $e');
    }
    return [];
  }
}
