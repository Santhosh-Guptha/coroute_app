/// Optional medical details a rider can add to the profile. The gateway shows
/// them to the ride group only while that rider's SOS or crash alert is open.
class MedicalInfo {
  final String bloodGroup;
  final String allergies;
  final String notes;

  const MedicalInfo({this.bloodGroup = '', this.allergies = '', this.notes = ''});

  static const List<String> bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

  bool get isEmpty => bloodGroup.isEmpty && allergies.isEmpty && notes.isEmpty;

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
    );
    return m.isEmpty ? null : m;
  }

  Map<String, dynamic> toJson() => {
        if (bloodGroup.isNotEmpty) 'bloodGroup': bloodGroup,
        if (allergies.isNotEmpty) 'allergies': allergies,
        if (notes.isNotEmpty) 'notes': notes,
      };
}
