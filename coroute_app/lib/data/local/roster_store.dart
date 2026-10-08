import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/constants/net_constants.dart';
import '../models/emergency_roster.dart';

/// Encrypted copy of the emergency SMS roster (flutter_secure_storage).
/// Phone numbers are never written to SharedPreferences and never logged.
class RosterStore {
  RosterStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<EmergencyRoster?> load() async {
    try {
      return EmergencyRoster.decode(await _storage.read(key: NetConstants.keyRoster));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(EmergencyRoster r) async {
    try {
      await _storage.write(key: NetConstants.keyRoster, value: r.encode());
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: NetConstants.keyRoster);
    } catch (_) {}
  }
}
