import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/notify/notification_snapshot.dart';

void main() {
  group('NotificationSnapshot Bead Wire arguments', () {
    test('toChannelArgs includes structured ahead, behind, telemetry, and distDetail', () {
      const snap = NotificationSnapshot(
        mode: NotifMode.ride,
        tone: NotifTone.normal,
        title: 'Western Ghats Riders',
        subtitle: 'Live convoy',
        telemetry: 'Pack #3 • 71 km/h',
        ahead: [
          RiderLine(name: 'Rahul', distanceM: 320, ahead: true),
        ],
        behind: [
          RiderLine(name: 'Kiran', distanceM: 450, ahead: false),
          RiderLine(name: 'Aditya', distanceM: 2800, ahead: false, flag: 'Stopped 5 min'),
        ],
      );

      final args = snap.toChannelArgs();

      expect(args['telemetry'], 'Pack #3 • 71 km/h');
      final ahead = args['ahead'] as List<Map<String, Object?>>;
      final behind = args['behind'] as List<Map<String, Object?>>;

      expect(ahead.length, 1);
      expect(ahead[0]['name'], 'Rahul');
      expect(ahead[0]['distDetail'], '300 m');

      expect(behind.length, 2);
      expect(behind[0]['name'], 'Kiran');
      expect(behind[0]['distDetail'], '450 m');
      expect(behind[1]['name'], 'Aditya');
      expect(behind[1]['distDetail'], '2.8 km');
      expect(behind[1]['flag'], 'Stopped 5 min');
    });
  });

}
