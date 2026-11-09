import 'package:coroute_app/data/models/medical_info.dart';
import 'package:coroute_app/presentation/ride/incident_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner rule: medical info has no sharing switch. An accepted responder from another
/// group gets it with the emergency contact while the alert is open (ASSIST_UPDATE.medical).
void main() {
  test('ASSIST_UPDATE medical with the emergency contact parses and shows', () {
    final m = MedicalInfo.fromJson({'bloodGroup': 'O+', 'allergies': 'Penicillin', 'contactName': 'Kin', 'contactPhone': '+919000000002'})!;
    expect(m.contactName, 'Kin');
    expect(m.contactPhone, '+919000000002');
    expect(MedicalCard.linesOf(m), ['Blood group O+', 'Allergies: Penicillin', 'Emergency contact: Kin, +919000000002']);
    expect(m.toJson()['contactPhone'], '+919000000002');
  });

  test('contact only still counts; a name without a phone is dropped; empty stays null', () {
    final c = MedicalInfo.fromJson({'contactPhone': '+919000000002'})!;
    expect(MedicalCard.linesOf(c), ['Emergency contact: +919000000002']);
    expect(MedicalInfo.fromJson({'contactName': 'Kin'}), isNull);
    expect(MedicalInfo.fromJson({}), isNull);
    // Older gateways: medical fields only, unchanged.
    final old = MedicalInfo.fromJson({'bloodGroup': 'B+'})!;
    expect(old.contactPhone, '');
    expect(MedicalCard.linesOf(old), ['Blood group B+']);
  });
}
