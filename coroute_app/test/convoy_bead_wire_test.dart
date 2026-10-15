import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/notify/notification_snapshot.dart';
import 'package:coroute_app/presentation/widgets/convoy_bead_wire_widget.dart';

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

  group('ConvoyBeadWireWidget UI Tests', () {
    testWidgets('renders horizontal convoy bead chain with nodes and distance connectors', (tester) async {
      var waitTapped = false;
      var mapTapped = false;
      var sosTapped = false;

      final widget = MaterialApp(
        home: Scaffold(
          body: ConvoyBeadWireWidget(
            convoyName: 'Western Ghats Riders',
            telemetry: 'Pack #3 • 71 km/h',
            ahead: const [
              RiderLine(name: 'Rahul', distanceM: 320, ahead: true),
            ],
            behind: const [
              RiderLine(name: 'Kiran', distanceM: 450, ahead: false),
              RiderLine(name: 'Aditya', distanceM: 2800, ahead: false, flag: '⚠️ Stopped'),
            ],
            onWait: () => waitTapped = true,
            onMap: () => mapTapped = true,
            onSos: () => sosTapped = true,
          ),
        ),
      );

      await tester.pumpWidget(widget);

      // Verify Convoy Header & LIVE badge
      expect(find.text('Western Ghats Riders'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);

      // Verify Rider Nodes
      expect(find.text('Rahul'), findsOneWidget);
      expect(find.text('YOU'), findsOneWidget);
      expect(find.text('Kiran'), findsOneWidget);
      expect(find.text('Aditya'), findsOneWidget);

      // Verify Tags
      expect(find.text('▲ Ahead'), findsOneWidget);
      expect(find.text('Pack #2'), findsOneWidget);
      expect(find.text('▼ Behind'), findsOneWidget);
      expect(find.text('⚠️ Stopped'), findsOneWidget);

      // Verify Distance Pills
      expect(find.text('300 m'), findsOneWidget);
      expect(find.text('450 m'), findsOneWidget);
      expect(find.text('2.8 km'), findsOneWidget);

      // Verify Telemetry Subtitle
      expect(find.text('Pack #3 • 71 km/h'), findsOneWidget);

      // Verify 3 Glove-Friendly Action Buttons
      expect(find.text('⏸  WAIT'), findsOneWidget);
      expect(find.text('📍  MAP'), findsOneWidget);
      expect(find.text('⚠️  SOS'), findsOneWidget);

      // Tap buttons
      await tester.tap(find.text('⏸  WAIT'));
      expect(waitTapped, isTrue);

      await tester.tap(find.text('📍  MAP'));
      expect(mapTapped, isTrue);

      await tester.tap(find.text('⚠️  SOS'));
      expect(sosTapped, isTrue);
    });
  });
}
