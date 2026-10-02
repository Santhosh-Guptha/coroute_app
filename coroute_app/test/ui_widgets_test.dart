import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:coroute_app/presentation/widgets/intercom_dock.dart';

void main() {
  RiderModel rider(String id, String name) => RiderModel(userId: id, name: name, lat: 0, lng: 0, lastSeenEpochMs: 0);

  ConvoyModel convoy() => ConvoyModel(
        groupId: 'GRP-TEST',
        name: 'Test convoy',
        joinCode: '123456',
        createdByUserId: 'usr_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 0,
        riders: {'usr_me': rider('usr_me', 'Me'), 'usr_other': rider('usr_other', 'Other Rider')},
      );

  Widget host(Widget child, RealtimeService rt) => MultiProvider(
        providers: [
          ChangeNotifierProvider<RealtimeService>.value(value: rt),
          ChangeNotifierProvider(create: (_) => IntercomService(rt)),
        ],
        child: MaterialApp(home: Scaffold(body: Column(children: [child]))),
      );

  testWidgets('ConnectionBanner shows offline state and hides when connected', (tester) async {
    final rt = RealtimeService();
    await tester.pumpWidget(host(const ConnectionBanner(), rt));
    expect(find.textContaining('Offline'), findsOneWidget);
  });

  testWidgets('IntercomDock renders talk target, mode toggle, PTT and SOS', (tester) async {
    final rt = RealtimeService();
    await tester.pumpWidget(host(IntercomDock(convoy: convoy(), me: rider('usr_me', 'Me'), onSos: () {}), rt));
    expect(find.text('Talk to: Everyone'), findsOneWidget);
    expect(find.text('PTT'), findsOneWidget);
    expect(find.text('VOX'), findsOneWidget);
    expect(find.text('HOLD TO TALK'), findsOneWidget);
    expect(find.text('SOS'), findsOneWidget);
    // Offline → the dock says so instead of pretending the radio works.
    expect(find.textContaining('Reconnecting'), findsOneWidget);
  });

  testWidgets('Talk-to picker lists only other riders and switches to a private channel', (tester) async {
    final rt = RealtimeService();
    await tester.pumpWidget(host(IntercomDock(convoy: convoy(), me: rider('usr_me', 'Me')), rt));
    await tester.tap(find.text('Talk to: Everyone'));
    await tester.pumpAndSettle();
    expect(find.text('Everyone in the convoy'), findsOneWidget);
    expect(find.text('Other Rider'), findsOneWidget);
    expect(find.text('Me'), findsNothing);
    await tester.tap(find.text('Other Rider'));
    await tester.pumpAndSettle();
    expect(find.text('Private: Other Rider'), findsOneWidget);
  });
}
