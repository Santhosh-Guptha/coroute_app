import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/net_constants.dart';
import '../models/outbox_item.dart';

/// Disk copy of the persistent outbox (SharedPreferences, one key, oldest first).
/// Holds no phone numbers or medical data: only what the rider typed or tapped.
class OutboxStore {
  Future<List<OutboxItem>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return OutboxItem.decodeList(prefs.getString(NetConstants.keyOutbox));
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<OutboxItem> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (items.isEmpty) {
        await prefs.remove(NetConstants.keyOutbox);
      } else {
        await prefs.setString(NetConstants.keyOutbox, OutboxItem.encodeList(items));
      }
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(NetConstants.keyOutbox);
    } catch (_) {}
  }
}
