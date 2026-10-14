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
      packs.removeWhere((p) => p.id == pack.id || (p.name == pack.name && p.highDetail == pack.highDetail));
      packs.insert(0, pack);
      await _write(packs);
    } catch (e) {
      debugPrint('SavedMapPackStore save note: ${e.runtimeType}');
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
