import 'dart:io';

import 'package:coroute_app/domain/security/lock_screen_cockpit_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// 3.56 (round 6): calling from the locked cockpit. A locked phone calls emergency services, and the
/// rider's own emergency contact while the rider's own SOS / crash alarm is open; every other number
/// waits for the phone's unlock.
void main() {
  const lines = ['112', '108', '100', '1033'];
  const own = '+91 98765 43210';
  bool needs(String number, {bool locked = true, bool open = false, String? contact = own}) => LockScreenCockpitPolicy.callNeedsUnlock(
        locked: locked,
        number: number,
        emergencyNumbers: lines,
        ownEmergencyContact: contact,
        ownEmergencyOpen: open,
      );

  test('not locked: nothing ever waits', () {
    for (final n in ['112', own, '+919000000001', '']) {
      expect(needs(n, locked: false), isFalse, reason: n);
    }
  });

  test('locked: emergency lines always dial', () {
    for (final n in ['112', ' 112 ', '108', '100', '1033', 'tel:112']) {
      expect(needs(n), isFalse, reason: n);
      expect(needs(n, open: true), isFalse, reason: n);
    }
    expect(needs('1120'), isTrue, reason: 'not an emergency line');
    expect(needs('911'), isTrue);
  });

  test("locked: the rider's own emergency contact dials only while the rider's own SOS / crash alarm is open", () {
    expect(needs(own, open: true), isFalse);
    expect(needs('09876543210', open: true), isFalse, reason: 'same subscriber, written differently');
    expect(needs('98765-43210', open: true), isFalse);
    expect(needs(own), isTrue, reason: 'no emergency: a found phone can not ring the family');
  });

  test('locked: every other number waits, also during an emergency', () {
    for (final n in ['+919000000001', '9876543211', '04012345678', '']) {
      expect(needs(n, open: true), isTrue, reason: n);
      expect(needs(n), isTrue, reason: n);
    }
    expect(needs('9876543210', open: true, contact: null), isTrue, reason: 'no emergency contact saved');
    expect(needs('9876543210', open: true, contact: ''), isTrue);
  });

  test('samePhone: last 10 digits, never short codes', () {
    expect(LockScreenCockpitPolicy.samePhone('+91 98765 43210', '9876543210'), isTrue);
    expect(LockScreenCockpitPolicy.samePhone('9876543210', '9876543211'), isFalse);
    expect(LockScreenCockpitPolicy.samePhone('112', '112'), isFalse);
    expect(LockScreenCockpitPolicy.samePhone(null, '9876543210'), isFalse);
  });

  test('dialContact still needs the unlock and 112 does not (older rules unchanged)', () {
    expect(LockScreenCockpitPolicy.needsUnlock(locked: true, action: CockpitAction.dialContact), isTrue);
    expect(LockScreenCockpitPolicy.needsUnlock(locked: true, action: CockpitAction.call112), isFalse);
    expect(LockScreenCockpitPolicy.needsUnlock(locked: true, action: CockpitAction.sosHold), isFalse);
    expect(LockScreenCockpitPolicy.needsUnlock(locked: true, action: CockpitAction.imOk), isFalse);
    expect(LockScreenCockpitPolicy.needsUnlock(locked: true, action: CockpitAction.medicalId), isFalse);
  });

  test('every Call button of the ride screens goes through the rule; the SOS sheet is never held back', () {
    String read(String p) => File(p).readAsStringSync();
    expect(read('lib/presentation/ride/incident_banner.dart').contains('callFromCockpit(context, clean'), isTrue);
    expect(read('lib/presentation/ride/group_safety_cards.dart').contains('callFromCockpit(context, phone'), isTrue);
    expect(read('lib/presentation/ride/rider_card_sheet.dart').contains('callFromCockpit(context, clean'), isTrue);
    final sos = read('lib/presentation/widgets/emergency_sos_sheet.dart');
    expect(sos.contains('callFromCockpit('), isFalse, reason: "the rider's own SOS sheet dials at once");
    // No ride screen dials a number directly any more.
    for (final f in ['lib/presentation/ride/group_safety_cards.dart', 'lib/presentation/ride/rider_card_sheet.dart', 'lib/presentation/safety/safety_card_sheet.dart', 'lib/presentation/ride/incident_sheet.dart']) {
      final src = read(f);
      final direct = RegExp(r"(?<!callFromCockpit\(context, (phone|clean), \(\) => )launchUrl\((Uri\(scheme: 'tel'|uri)").allMatches(src).length;
      expect(direct, 0, reason: f);
    }
  });
}
