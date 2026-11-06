import 'package:flutter/foundation.dart';

import 'auth_service.dart';
import 'settings_service.dart';

/// Keeps the native lock-screen Medical ID (the quick settings tile and the ICE card over the
/// lock screen) in step with the rider's profile.
///
/// Medical ID has no on/off switch: it is always available. The rider controls it by editing
/// or clearing their medical info in the profile; signing out clears it. Only what the rider
/// entered for emergencies is copied (name, blood group, allergies, notes, emergency contact);
/// never a position or location history.
class MedicalIdLockSync {
  MedicalIdLockSync(this._auth, this._settings) {
    _auth.addListener(_sync);
    _sync();
  }

  final AuthService _auth;
  final SettingsService _settings;
  String? _last;
  bool _disposed = false;

  void _sync() {
    if (_disposed) return;
    final name = (_auth.currentUserName ?? '').trim();
    final blood = _auth.bloodGroup.trim();
    final allergies = _auth.allergies.trim();
    final notes = _auth.medicalNotes.trim();
    final contactName = (_auth.emergencyContactName ?? '').trim();
    final contactPhone = (_auth.emergencyContact ?? '').trim();
    final key = [name, blood, allergies, notes, contactName, contactPhone].join('\u0001');
    if (key == _last) return;
    _last = key;
    _settings
        .syncMedicalIdToLockScreen(
          name: name,
          bloodGroup: blood,
          allergies: allergies,
          medicalNotes: notes,
          contactName: contactName,
          contactPhone: contactPhone,
        )
        .catchError((Object e) => debugPrint('medical id sync note: $e'));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _auth.removeListener(_sync);
  }
}
