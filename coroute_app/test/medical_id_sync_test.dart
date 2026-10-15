import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/data/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Lock-Screen First Responder ICE Card Sync Tests', () {
    test('setMedicalIdOnLockScreen updates preference and flutter.medical_enabled', () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs);

      expect(settings.medicalIdOnLockScreen, isFalse);

      await settings.setMedicalIdOnLockScreen(true);
      expect(settings.medicalIdOnLockScreen, isTrue);
      expect(prefs.getBool('flutter.medical_enabled'), isTrue);

      await settings.setMedicalIdOnLockScreen(false);
      expect(settings.medicalIdOnLockScreen, isFalse);
      expect(prefs.getBool('flutter.medical_enabled'), isFalse);
    });

    test('syncMedicalIdToLockScreen correctly persists all medical & ICE fields for native Quick Settings', () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsService(prefs);
      await settings.setMedicalIdOnLockScreen(true);

      await settings.syncMedicalIdToLockScreen(
        name: 'Kiran Kumar',
        bloodGroup: 'O+',
        allergies: 'Penicillin, Sulfa drugs',
        medicalNotes: 'Type 1 Diabetic; wears CGM sensor',
        contactName: 'Sneha (Spouse)',
        contactPhone: '+91 98765 43210',
      );

      expect(prefs.getString('flutter.medical_user_name'), equals('Kiran Kumar'));
      expect(prefs.getString('flutter.medical_blood_group'), equals('O+'));
      expect(prefs.getString('flutter.medical_allergies'), equals('Penicillin, Sulfa drugs'));
      expect(prefs.getString('flutter.medical_notes'), equals('Type 1 Diabetic; wears CGM sensor'));
      expect(prefs.getString('flutter.medical_contact_name'), equals('Sneha (Spouse)'));
      expect(prefs.getString('flutter.medical_contact_phone'), equals('+91 98765 43210'));
      expect(prefs.getBool('flutter.medical_enabled'), isTrue);
    });
  });
}
