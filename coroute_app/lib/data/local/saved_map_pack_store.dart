import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/safety_constants.dart';
import '../models/saved_map_pack.dart';

/// SharedPreferences persistence store for saved offline corridor map packs.
class SavedMapPackStore {
  SavedMapPackStore._();

  static Future<List<SavedMapPack>> loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SafetyConstants.keySavedMapPacks);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List<dynamic>;
      final packs = list
          .map((e) => SavedMapPack.fromJson(e as Map<String, dynamic>))
          .toList();
      packs.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
      return packs;
    } catch (e) {
      debugPrint('SavedMapPackStore load note: ${e.runtimeType}');
      return const [];
    }
  }

  static Future<void> save(SavedMapPack pack) async {
    try {
      final packs = (await loadAll()).toList();
      packs.removeWhere((p) =>
          p.id == pack.id ||
          (pack.tripId != null && p.tripId == pack.tripId) ||
          (pack.tripId == null && p.tripId == null && p.name == pack.name && p.highDetail == pack.highDetail));
      packs.insert(0, pack);
      await _write(packs);
    } catch (e) {
      debugPrint('SavedMapPackStore save note: ${e.runtimeType}');
    }
  }

  /// The ride [tripId] ended at [at]: its map starts its retention time (OfflineMapRetention).
  /// True when a pack was marked.
  static Future<bool> markCompleted(String tripId, DateTime at) async {
    try {
      final packs = (await loadAll()).toList();
      var changed = false;
      for (var i = 0; i < packs.length; i++) {
        if (packs[i].tripId == tripId && packs[i].completedAt == null) {
          packs[i] = packs[i].copyWith(completedAt: at);
          changed = true;
        }
      }
      if (changed) await _write(packs);
      return changed;
    } catch (e) {
      debugPrint('SavedMapPackStore mark note: ${e.runtimeType}');
      return false;
    }
  }

  /// Deletes several packs in one write.
  static Future<void> deleteAll(Iterable<String> ids) async {
    final doomed = ids.toSet();
    if (doomed.isEmpty) return;
    try {
      final packs = (await loadAll()).toList();
      packs.removeWhere((p) => doomed.contains(p.id));
      await _write(packs);
    } catch (e) {
      debugPrint('SavedMapPackStore delete note: ${e.runtimeType}');
    }
  }

  static Future<void> delete(String id) async {
    try {
      final packs = (await loadAll()).toList();
      packs.removeWhere((p) => p.id == id);
      await _write(packs);
    } catch (e) {
      debugPrint('SavedMapPackStore delete note: ${e.runtimeType}');
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(SafetyConstants.keySavedMapPacks);
    } catch (e) {
      debugPrint('SavedMapPackStore clear note: ${e.runtimeType}');
    }
  }

  static Future<void> _write(List<SavedMapPack> packs) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(packs.map((p) => p.toJson()).toList());
    await prefs.setString(SafetyConstants.keySavedMapPacks, jsonStr);
  }
}
