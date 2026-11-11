import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/group_message_model.dart';

/// Ride chat data kept on the phone (3.55 ride chat):
/// * the quick action order the rider chose,
/// * riders whose chat messages are hidden on this phone ("Hide messages from Kiran"),
/// * when each ride's chat was last seen (unread badge),
/// * the chat of the last [keepRides] rides after they ended (trip summary shows it).
///
/// Every call is safe without storage (tests): it then reads empty and writes nothing.
class RideChatStore {
  RideChatStore._();

  static const String keyOrder = 'ride_chat_quick_order_v1';
  static const String keyHidden = 'ride_chat_hidden_v1';
  static const String keySeen = 'ride_chat_seen_v1';
  static const String keyArchive = 'ride_chat_archive_v1';

  /// Ended rides whose chat stays on the phone.
  static const int keepRides = 10;

  /// Messages kept per ended ride.
  static const int keepMessages = 300;

  static Future<SharedPreferences?> _p() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<List<String>> loadOrder() async => (await _p())?.getStringList(keyOrder) ?? const [];

  static Future<void> saveOrder(List<String> ids) async {
    await (await _p())?.setStringList(keyOrder, ids);
  }

  static Future<Set<String>> loadHidden() async => ((await _p())?.getStringList(keyHidden) ?? const <String>[]).toSet();

  static Future<void> saveHidden(Set<String> ids) async {
    await (await _p())?.setStringList(keyHidden, ids.take(200).toList());
  }

  static Future<Map<String, dynamic>> loadSeen() async {
    try {
      final raw = (await _p())?.getString(keySeen);
      final m = raw == null ? null : jsonDecode(raw);
      return m is Map ? Map<String, dynamic>.from(m) : const {};
    } catch (_) {
      return const {};
    }
  }

  static Future<void> saveSeen(Map<String, int> seen) async {
    // Only the newest 50 rides.
    final entries = seen.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    await (await _p())?.setString(keySeen, jsonEncode(Map.fromEntries(entries.take(50))));
  }

  /// Keeps [messages] of the ended ride [groupId] (newest rides first, at most [keepRides]).
  static Future<void> archive(String groupId, List<GroupMessageModel> messages) async {
    if (groupId.isEmpty || messages.isEmpty) return;
    final p = await _p();
    if (p == null) return;
    try {
      final all = _readArchive(p);
      all.remove(groupId);
      final keep = messages.length > keepMessages ? messages.sublist(messages.length - keepMessages) : messages;
      final next = <String, dynamic>{groupId: [for (final m in keep) m.toJson()], ...all};
      final trimmed = Map.fromEntries(next.entries.take(keepRides));
      await p.setString(keyArchive, jsonEncode(trimmed));
    } catch (e) {
      debugPrint('ride chat archive note: $e');
    }
  }

  /// The chat of an ended ride (oldest first), empty when none was kept.
  static Future<List<GroupMessageModel>> loadArchived(String groupId) async {
    final p = await _p();
    if (p == null || groupId.isEmpty) return const [];
    try {
      final raw = _readArchive(p)[groupId];
      if (raw is! List) return const [];
      return [for (final m in raw) if (m is Map) GroupMessageModel.fromJson(Map<String, dynamic>.from(m))];
    } catch (_) {
      return const [];
    }
  }

  static Map<String, dynamic> _readArchive(SharedPreferences p) {
    final raw = p.getString(keyArchive);
    if (raw == null) return {};
    final m = jsonDecode(raw);
    return m is Map ? Map<String, dynamic>.from(m) : {};
  }
}
