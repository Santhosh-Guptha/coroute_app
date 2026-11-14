// v3.58 Profile: "Complete your riding profile". Pure Dart (tool/pure_dart_test). Safety items come first, so the
// next step the rider is offered is the one that helps most in an emergency.
library;

enum ChecklistItem { emergencyContact, medicalId, bike, nearbyDevices, preRideCheck, avatar, interests }

extension ChecklistItemText on ChecklistItem {
  String get key => switch (this) {
        ChecklistItem.emergencyContact => 'emergency_contact',
        ChecklistItem.medicalId => 'medical_id',
        ChecklistItem.bike => 'bike',
        ChecklistItem.nearbyDevices => 'nearby_devices',
        ChecklistItem.preRideCheck => 'pre_ride_check',
        ChecklistItem.avatar => 'avatar',
        ChecklistItem.interests => 'interests',
      };

  String get label => switch (this) {
        ChecklistItem.emergencyContact => 'Add an emergency contact',
        ChecklistItem.medicalId => 'Add your Medical ID',
        ChecklistItem.bike => 'Add your bike',
        ChecklistItem.nearbyDevices => 'Allow Nearby devices (SOS without signal)',
        ChecklistItem.preRideCheck => 'Run the pre-ride phone check',
        ChecklistItem.avatar => 'Add a profile picture',
        ChecklistItem.interests => 'Pick your riding interests',
      };

  /// Safety items are marked so the UI can show a small shield.
  bool get safety => switch (this) {
        ChecklistItem.emergencyContact || ChecklistItem.medicalId || ChecklistItem.nearbyDevices || ChecklistItem.preRideCheck => true,
        _ => false,
      };
}

class ProfileFacts {
  final bool hasEmergencyContact;
  final bool hasMedicalId;
  final bool hasBike;

  /// A pillion rides on someone else's bike: the bike step is not asked.
  final bool pillion;
  final bool nearbyDevicesOk;
  final bool preRideCheckDone;
  final bool hasAvatar;
  final bool hasInterests;

  /// Profile pictures switched off on the server: the avatar step is not asked.
  final bool photosOn;

  const ProfileFacts({
    this.hasEmergencyContact = false,
    this.hasMedicalId = false,
    this.hasBike = false,
    this.pillion = false,
    this.nearbyDevicesOk = false,
    this.preRideCheckDone = false,
    this.hasAvatar = false,
    this.hasInterests = false,
    this.photosOn = true,
  });
}

class ChecklistResult {
  /// Items that apply to this rider, in order, with done / not done.
  final List<(ChecklistItem, bool)> items;
  const ChecklistResult(this.items);

  int get total => items.length;
  int get doneCount => items.where((i) => i.$2).length;

  /// 0..1.
  double get progress => total == 0 ? 1 : doneCount / total;
  bool get complete => doneCount == total;

  /// The first item still to do, or null.
  ChecklistItem? get next {
    for (final i in items) {
      if (!i.$2) return i.$1;
    }
    return null;
  }

  /// "3 of 7 done".
  String get summary => '$doneCount of $total done';
}

class RidingChecklist {
  RidingChecklist._();

  static ChecklistResult of(ProfileFacts f) => ChecklistResult([
        (ChecklistItem.emergencyContact, f.hasEmergencyContact),
        (ChecklistItem.medicalId, f.hasMedicalId),
        if (!f.pillion) (ChecklistItem.bike, f.hasBike),
        (ChecklistItem.nearbyDevices, f.nearbyDevicesOk),
        (ChecklistItem.preRideCheck, f.preRideCheckDone),
        if (f.photosOn) (ChecklistItem.avatar, f.hasAvatar),
        (ChecklistItem.interests, f.hasInterests),
      ]);

  /// "Riding since Nov 2026", or "" when unknown.
  static String ridingSince(int memberSinceMs) {
    if (memberSinceMs <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(memberSinceMs);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return 'Riding since ${months[d.month - 1]} ${d.year}';
  }

  /// Riding interests a rider can pick (kept on the phone).
  static const List<String> interestChoices = [
    'Breakfast rides',
    'Night rides',
    'Weekend tours',
    'Twisty roads',
    'Ghats',
    'Long distance',
    'Off-road',
    'City commute',
  ];

  /// Riding styles (one choice).
  static const List<String> styleChoices = ['Relaxed', 'Touring', 'Sporty', 'Adventure'];
}
