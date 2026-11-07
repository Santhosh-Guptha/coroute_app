import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/rider_status.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_settings_cards.dart';
import 'package:coroute_app/presentation/rider/widgets/rider_management_sheet.dart';

void main() {
  RiderModel makeRider({
    required String id,
    required String name,
    String role = 'PACK',
    int batteryLevel = 85,
    double speed = 55.0,
  }) {
    return RiderModel(
      userId: id,
      name: name,
      lat: 12.9716,
      lng: 77.5946,
      speedKmh: speed,
      heading: 90.0,
      role: role,
      batteryLevel: batteryLevel,
      lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  ConvoyModel makeConvoy({
    required RiderModel owner,
    required List<RiderModel> riders,
    String? tripHeadId,
  }) {
    final map = {for (final r in riders) r.userId: r};
    map[owner.userId] = owner;
    return ConvoyModel(
      groupId: 'GRP-MINIMAL-1',
      name: 'Western Ghats Odyssey',
      joinCode: '445566',
      createdByUserId: owner.userId,
      createdByUserName: owner.name,
      tripOwnerUserId: owner.userId,
      tripHeadUserId: tripHeadId ?? owner.userId,
      createdAtEpochMs: 1700000000000,
      riders: map,
    );
  }

  Widget wrapWithTheme(Widget child) {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );
  }

  testWidgets('GloveQuickActionGrid renders 6 oversized tiles and handles taps', (tester) async {
    final owner = makeRider(id: 'u1', name: 'Santhosh Bukka', role: 'LEAD');
    final convoy = makeConvoy(owner: owner, riders: [owner]);

    bool intercomTapped = false;
    bool stopsTapped = false;
    bool whyTapped = false;
    bool fuelTapped = false;
    bool messagesTapped = false;
    bool safetyTapped = false;

    await tester.pumpWidget(
      wrapWithTheme(
        GloveQuickActionGrid(
          convoy: convoy,
          me: owner,
          onOpenIntercom: () => intercomTapped = true,
          onOpenStops: () => stopsTapped = true,
          onTellWhy: () => whyTapped = true,
          stopReasonText: 'FUELING',
          onOpenFuel: () => fuelTapped = true,
          estimatedUsableKm: 320.0,
          nearestFuelName: 'Shell Express',
          nearestFuelAheadM: 8500.0,
          onOpenMessages: () => messagesTapped = true,
          chatQueued: 1,
          onOpenSafetyStatus: () => safetyTapped = true,
          isSafetyHealthy: true,
          isSolo: false,
        ),
      ),
    );

    expect(find.text('Talk to All'), findsOneWidget);
    expect(find.text('Route & Stops'), findsOneWidget);
    expect(find.text('Stop Reason'), findsOneWidget);
    expect(find.text('320 km range'), findsOneWidget);
    expect(find.textContaining('Messages'), findsOneWidget);
    expect(find.text('Safety Health'), findsOneWidget);
    expect(find.text('All systems active'), findsOneWidget);

    // Verify taps
    await tester.tap(find.text('Talk to All'));
    expect(intercomTapped, isTrue);

    await tester.tap(find.text('Route & Stops'));
    expect(stopsTapped, isTrue);

    await tester.tap(find.text('Stop Reason'));
    expect(whyTapped, isTrue);

    await tester.tap(find.text('320 km range'));
    expect(fuelTapped, isTrue);

    await tester.tap(find.textContaining('Messages'));
    expect(messagesTapped, isTrue);

    await tester.tap(find.text('Safety Health'));
    expect(safetyTapped, isTrue);
  });

  testWidgets('CompactConvoyRoster renders spread and horizontal compact rider avatars', (tester) async {
    final owner = makeRider(id: 'u1', name: 'Santhosh Bukka', role: 'LEAD');
    final rider2 = makeRider(id: 'u2', name: 'Kiran Rao', role: 'SWEEPER', batteryLevel: 18);
    final convoy = makeConvoy(owner: owner, riders: [owner, rider2]);

    RiderModel? selectedRider;
    bool manageTapped = false;

    await tester.pumpWidget(
      wrapWithTheme(
        CompactConvoyRoster(
          convoy: convoy,
          me: owner,
          spreadM: 1400.0,
          colors: {'u1': Colors.teal, 'u2': Colors.cyan},
          statuses: {'u1': RiderStatus.riding, 'u2': RiderStatus.riding},
          nowMs: DateTime.now().millisecondsSinceEpoch,
          onTapRider: (r) => selectedRider = r,
          onOpenManageRiders: () => manageTapped = true,
          isLead: true,
        ),
      ),
    );

    expect(find.textContaining('GROUP SPREAD: 1.4 km'), findsOneWidget);
    expect(find.text('2 Riders'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Kiran'), findsOneWidget);

    // Tap on Kiran
    await tester.tap(find.text('Kiran'));
    expect(selectedRider?.name, 'Kiran Rao');

    // Tap on manage riders
    await tester.tap(find.text('2 Riders'));
    expect(manageTapped, isTrue);
  });

  testWidgets('SecondaryManagementGroup renders organized secondary list tiles without obsolete 100-bike limits', (tester) async {
    final owner = makeRider(id: 'u1', name: 'Santhosh Bukka', role: 'LEAD');
    final convoy = makeConvoy(owner: owner, riders: [owner]);

    bool manageRidersTapped = false;
    bool audioTapped = false;
    bool groupTapped = false;
    bool guardianTapped = false;
    bool safetyDiagTapped = false;
    bool etaTapped = false;

    await tester.pumpWidget(
      wrapWithTheme(
        SecondaryManagementGroup(
          convoy: convoy,
          isLead: true,
          onOpenManageRiders: () => manageRidersTapped = true,
          onOpenAudioSettings: () => audioTapped = true,
          onOpenGroupSettings: () => groupTapped = true,
          onOpenGuardian: () => guardianTapped = true,
          onOpenSafetyStatus: () => safetyDiagTapped = true,
          onShareEta: () => etaTapped = true,
          etaSubtitle: '34 km left, about 18:45',
          isSolo: false,
        ),
      ),
    );

    expect(find.text('Manage Riders & Invite'), findsOneWidget);
    expect(find.text('Talk settings'), findsOneWidget);
    expect(find.text('Group Safety & Speed Limits'), findsOneWidget);
    expect(find.text('Ride Guardian'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Share my ETA'), findsOneWidget);

    // Verify no obsolete 100-bike copy is displayed
    expect(find.textContaining('100 BIKES'), findsNothing);

    // Test taps
    await tester.tap(find.text('Manage Riders & Invite'));
    expect(manageRidersTapped, isTrue);

    await tester.tap(find.text('Talk settings'));
    expect(audioTapped, isTrue);

    await tester.tap(find.text('Group Safety & Speed Limits'));
    expect(groupTapped, isTrue);

    await tester.tap(find.text('Ride Guardian'));
    expect(guardianTapped, isTrue);

    await tester.tap(find.text('Settings'));
    expect(safetyDiagTapped, isTrue);

    await tester.tap(find.text('Share my ETA'));
    expect(etaTapped, isTrue);
  });

  testWidgets('RideLifecycleBar renders pause, end, and leave buttons with glove targets', (tester) async {
    bool pauseToggled = false;
    bool endTapped = false;
    bool leaveTapped = false;

    await tester.pumpWidget(
      wrapWithTheme(
        RideLifecycleBar(
          isLead: true,
          isPaused: false,
          onTogglePause: () => pauseToggled = true,
          onEndRide: () => endTapped = true,
          onLeaveRide: () => leaveTapped = true,
        ),
      ),
    );

    expect(find.text('Pause group ride'), findsOneWidget);
    expect(find.text('End Ride'), findsOneWidget);
    expect(find.text('Leave Ride'), findsOneWidget);

    await tester.tap(find.text('Pause group ride'));
    expect(pauseToggled, isTrue);

    await tester.tap(find.text('End Ride'));
    expect(endTapped, isTrue);

    await tester.tap(find.text('Leave Ride'));
    expect(leaveTapped, isTrue);
  });

  testWidgets('RiderManagementSheet displays formal Trip Owner and Trip Head roles with join code', (tester) async {
    final owner = makeRider(id: 'u1', name: 'Santhosh Bukka', role: 'LEAD');
    final head = makeRider(id: 'u2', name: 'Kiran Rao', role: 'PACK');
    final convoy = makeConvoy(owner: owner, riders: [owner, head], tripHeadId: 'u2');

    bool shareTapped = false;
    bool copyTapped = false;

    await tester.pumpWidget(
      wrapWithTheme(
        RiderManagementSheet(
          convoy: convoy,
          me: owner,
          isOwner: true,
          isHead: false,
          onShareInvite: () => shareTapped = true,
          onCopyCode: () => copyTapped = true,
        ),
      ),
    );

    expect(find.text('Manage riders'), findsOneWidget);
    expect(find.text('INVITE CODE'), findsOneWidget);
    expect(find.text('445566'), findsOneWidget);
    expect(find.text('TRIP OWNER'), findsOneWidget);
    expect(find.text('TRIP HEAD'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);

    await tester.tap(find.text('Share'));
    expect(shareTapped, isTrue);

    await tester.tap(find.byIcon(Icons.copy_rounded));
    expect(copyTapped, isTrue);
  });
}
