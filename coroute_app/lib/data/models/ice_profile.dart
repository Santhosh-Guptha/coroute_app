/// ICE (In Case of Emergency) medical profile stored offline for first responders.
class IceProfile {
  final String bloodGroup;
  final String allergies;
  final String medications;
  final String emergencyContactName;
  final String emergencyContactPhone;
  final bool organDonor;
  final String insurancePolicyNumber;

  const IceProfile({
    this.bloodGroup = '',
    this.allergies = '',
    this.medications = '',
    this.emergencyContactName = '',
    this.emergencyContactPhone = '',
    this.organDonor = false,
    this.insurancePolicyNumber = '',
  });

  bool get isEmpty =>
      bloodGroup.isEmpty &&
      allergies.isEmpty &&
      medications.isEmpty &&
      emergencyContactName.isEmpty &&
      emergencyContactPhone.isEmpty;

  Map<String, dynamic> toJson() => {
        'bloodGroup': bloodGroup,
        'allergies': allergies,
        'medications': medications,
        'emergencyContactName': emergencyContactName,
        'emergencyContactPhone': emergencyContactPhone,
        'organDonor': organDonor,
        'insurancePolicyNumber': insurancePolicyNumber,
      };

  factory IceProfile.fromJson(Map<String, dynamic> json) => IceProfile(
        bloodGroup: (json['bloodGroup'] as String?)?.trim() ?? '',
        allergies: (json['allergies'] as String?)?.trim() ?? '',
        medications: (json['medications'] as String?)?.trim() ?? '',
        emergencyContactName:
            (json['emergencyContactName'] as String?)?.trim() ?? '',
        emergencyContactPhone:
            (json['emergencyContactPhone'] as String?)?.trim() ?? '',
        organDonor: json['organDonor'] == true,
        insurancePolicyNumber:
            (json['insurancePolicyNumber'] as String?)?.trim() ?? '',
      );

  static const IceProfile empty = IceProfile();
}
