/// Optional medical details a rider can add to the profile. Always on the lock
/// screen Medical ID; the gateway shares them with responders (ride group,
/// guardians, a rider who accepted to help) only while that rider's SOS or crash
/// alert is open. There is no sharing switch.
///
/// [contactName] / [contactPhone]: the emergency contact as entered, sent only to
/// an accepted responder from another group (the ride group has it in the roster).
class MedicalInfo {
  final String bloodGroup;
  final String allergies;
  final String notes;
  final String contactName;
  final String contactPhone;

  const MedicalInfo({this.bloodGroup = '', this.allergies = '', this.notes = '', this.contactName = '', this.contactPhone = ''});

  static const List<String> bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

  bool get isEmpty => bloodGroup.isEmpty && allergies.isEmpty && notes.isEmpty && contactPhone.isEmpty;

  /// Null when absent or empty.
  static MedicalInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final Map<Object?, Object?> map = json;
    String s(String k) => map[k]?.toString().trim() ?? '';
    final bg = s('bloodGroup');
    final m = MedicalInfo(
      bloodGroup: bloodGroups.contains(bg) ? bg : '',
      allergies: s('allergies'),
      notes: s('notes').isNotEmpty ? s('notes') : s('medicalNotes'),
      contactName: s('contactPhone').isNotEmpty ? s('contactName') : '',
      contactPhone: s('contactPhone'),
    );
    return m.isEmpty ? null : m;
  }

  Map<String, dynamic> toJson() => {
        if (bloodGroup.isNotEmpty) 'bloodGroup': bloodGroup,
        if (allergies.isNotEmpty) 'allergies': allergies,
        if (notes.isNotEmpty) 'notes': notes,
        if (contactPhone.isNotEmpty) 'contactPhone': contactPhone,
        if (contactPhone.isNotEmpty && contactName.isNotEmpty) 'contactName': contactName,
      };
}
