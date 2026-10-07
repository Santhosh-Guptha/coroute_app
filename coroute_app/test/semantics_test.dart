import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/presentation/rider/live_cockpit_map_screen.dart';
import 'package:coroute_app/presentation/widgets/intercom_dock.dart';

void main() {
  RiderModel rider(String id, String name) => RiderModel(userId: id, name: name, lat: 0, lng: 0, lastSeenEpochMs: 0);

  ConvoyModel convoy() => ConvoyModel(
        groupId: 'GRP-A11Y',
        name: 'Screen reader ride',
        joinCode: '123456',
        createdByUserId: 'usr_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 0,
        riders: {'usr_me': rider('usr_me', 'Me'), 'usr_other': rider('usr_other', 'Other Rider')},
      );

  testWidgets('TalkBack reads the SOS and talk buttons', (tester) async {
    final handle = tester.ensureSemantics();
    final rt = RealtimeService();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<RealtimeService>.value(value: rt),
        ChangeNotifierProvider(create: (_) => IntercomService(rt)),
      ],
      // The ride screen puts the hold-to-send SOS button on the map and the talk row in the sheet.
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            RideSosButton(onTriggered: () {}),
            IntercomDock(convoy: convoy(), me: rider('usr_me', 'Me')),
          ]),
        ),
      ),
    ));
    expect(find.bySemanticsLabel('Send SOS to your convoy'), findsOneWidget);
    expect(find.bySemanticsLabel('Hold to talk to everyone'), findsOneWidget);
    handle.dispose();
  });

  test('talk button label names who will hear you', () {
    expect(pttSemanticsLabel(null), 'Hold to talk to everyone');
    expect(pttSemanticsLabel(''), 'Hold to talk to everyone');
    expect(pttSemanticsLabel('Bala'), 'Hold to talk to Bala');
  });
}
