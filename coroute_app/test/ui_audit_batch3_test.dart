import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_settings_cards.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_overlay.dart';
import 'package:coroute_app/presentation/rider/widgets/rider_management_sheet.dart';
import 'package:coroute_app/presentation/ride/rider_card_sheet.dart';
import 'package:coroute_app/presentation/ride/group_settings_sheet.dart';
import 'package:coroute_app/presentation/timeline/live_timeline_screen.dart';
import 'package:coroute_app/presentation/map_picker/map_picker_screen.dart';
import 'package:coroute_app/presentation/trip_planner/offline_map_manager_screen.dart';
import 'package:coroute_app/presentation/widgets/intercom_dock.dart';
import 'package:coroute_app/presentation/ride/messages_sheet.dart';
import 'ui_audit_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuditEnvironment env;

  setUp(() async {
    env = await AuditEnvironment.create();
  });

  tearDown(() {
    env.dispose();
  });

  testWidgets('Batch 3: Active Cockpit, Convoy Management, Maps, and Comms', (tester) async {
    final sampleConvoy = createSampleConvoyModel();
    final me = sampleConvoy.riders['rider_dev_01']!;

    // SCR-022: Solo Collapsed Cockpit Top Bar
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: SafeArea(
          child: MinimalCockpitTopBar(
            title: 'Panaji, Goa · 494 km',
            connection: null,
            gps: GpsState.accurate,
            roadName: 'NH 48 Pune-Bengaluru Hwy',
            speedKmh: 74.0,
            speedLimitKmh: 80,
            isSolo: true,
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/05_active_cockpit/SCR-022_active_cockpit_solo_collapsed.png',
    );

    // SCR-023: Solo Expanded Cockpit Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              GloveQuickActionGrid(
                convoy: sampleConvoy,
                me: me,
                isSolo: true,
                isSafetyHealthy: true,
                onOpenIntercom: () {},
                onOpenStops: () {},
                onTellWhy: () {},
                onOpenFuel: () {},
                onOpenMessages: () {},
                chatQueued: 0,
                onOpenSafetyStatus: () {},
              ),
              const SizedBox(height: 16),
              RideLifecycleBar(
                isLead: true,
                isPaused: false,
                onTogglePause: () {},
                onEndRide: () {},
                onLeaveRide: () {},
              ),
            ],
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/05_active_cockpit/SCR-023_active_cockpit_solo_expanded.png',
    );

    // SCR-024: Group Collapsed Cockpit Top Bar
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: SafeArea(
          child: MinimalCockpitTopBar(
            title: 'Panaji, Goa · 494 km',
            connection: null,
            gps: GpsState.accurate,
            roadName: 'NH 48 Pune-Bengaluru Hwy',
            speedKmh: 74.0,
            speedLimitKmh: 80,
            isSolo: false,
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/05_active_cockpit/SCR-024_active_cockpit_group_collapsed.png',
    );

    // SCR-025: Group Lead Expanded Top Half
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              GloveQuickActionGrid(
                convoy: sampleConvoy,
                me: me,
                isSolo: false,
                isSafetyHealthy: true,
                onOpenIntercom: () {},
                onOpenStops: () {},
                onTellWhy: () {},
                onOpenFuel: () {},
                onOpenMessages: () {},
                chatQueued: 0,
                onOpenSafetyStatus: () {},
              ),
              const SizedBox(height: 16),
              CompactConvoyRoster(
                convoy: sampleConvoy,
                me: me,
                spreadM: 420.0,
                colors: {
                  'rider_dev_01': Colors.teal,
                  'rider_dev_02': Colors.cyan,
                  'rider_dev_03': Colors.amber,
                  'rider_dev_04': Colors.deepOrange,
                },
                statuses: const {},
                nowMs: DateTime.now().millisecondsSinceEpoch,
                onTapRider: (_) {},
                onOpenManageRiders: () {},
                isLead: true,
              ),
            ],
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/05_active_cockpit/SCR-025_active_cockpit_lead_expanded_top.png',
    );

    // SCR-026: Group Lead Expanded Bottom Half
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              SecondaryManagementGroup(
                convoy: sampleConvoy,
                isLead: true,
                isSolo: false,
                onOpenManageRiders: () {},
                onOpenAudioSettings: () {},
                onOpenGroupSettings: () {},
                onOpenGuardian: () {},
                onOpenSafetyStatus: () {},
                onShareEta: () {},
                etaSubtitle: 'ETA 02:56 · 494 km left',
              ),
              const SizedBox(height: 16),
              RideLifecycleBar(
                isLead: true,
                isPaused: false,
                onTogglePause: () {},
                onEndRide: () {},
                onLeaveRide: () {},
              ),
            ],
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/05_active_cockpit/SCR-026_active_cockpit_lead_expanded_bottom.png',
    );

    // SCR-027: Group Rider (Member) Expanded
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              SecondaryManagementGroup(
                convoy: sampleConvoy,
                isLead: false,
                isSolo: false,
                onOpenManageRiders: () {},
                onOpenAudioSettings: () {},
                onOpenGroupSettings: () {},
                onOpenGuardian: () {},
                onOpenSafetyStatus: () {},
                onShareEta: () {},
                etaSubtitle: 'ETA 02:56 · 494 km left',
              ),
              const SizedBox(height: 16),
              RideLifecycleBar(
                isLead: false,
                isPaused: false,
                onTogglePause: () {},
                onEndRide: () {},
                onLeaveRide: () {},
              ),
            ],
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/05_active_cockpit/SCR-027_active_cockpit_rider_expanded.png',
    );

    // SCR-028: Paused Ride State
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              RideLifecycleBar(
                isLead: true,
                isPaused: true,
                onTogglePause: () {},
                onEndRide: () {},
                onLeaveRide: () {},
              ),
            ],
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/05_active_cockpit/SCR-028_active_cockpit_paused_state.png',
    );

    // SCR-029: Night Mode HUD
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      palette: AppPalette.dark,
      widget: const Scaffold(
        body: SafeArea(
          child: MinimalCockpitTopBar(
            title: 'Panaji, Goa · 494 km',
            connection: null,
            gps: GpsState.accurate,
            roadName: 'NH 48 Night Highway Corridor',
            speedKmh: 74.0,
            speedLimitKmh: 80,
            isSolo: false,
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/05_active_cockpit/SCR-029_active_cockpit_night_mode.png',
    );

    // SCR-030: Rider Management Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: RiderManagementSheet(
          convoy: sampleConvoy,
          me: me,
          isOwner: true,
          isHead: true,
          onShareInvite: () {},
          onCopyCode: () {},
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/06_convoy_management/SCR-030_rider_management_sheet.png',
    );

    // SCR-031: Rider Card Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: RiderCard(
          convoyId: sampleConvoy.groupId,
          userId: 'rider_dev_02',
          onShowOnMap: (_) {},
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/06_convoy_management/SCR-031_rider_card_sheet.png',
    );

    // SCR-032: Group Settings Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: GroupSettingsView(convoyId: sampleConvoy.groupId),
      ),
      outputPath: '../docs/ui-audit/screenshots/06_convoy_management/SCR-032_group_settings_sheet.png',
    );

    // SCR-034: Live Timeline Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: LiveTimelineScreen(groupId: sampleConvoy.groupId),
      outputPath: '../docs/ui-audit/screenshots/06_convoy_management/SCR-034_live_timeline_screen.png',
    );

    // SCR-035: Map Picker Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const MapPickerScreen(title: 'Choose Regroup Location'),
      outputPath: '../docs/ui-audit/screenshots/07_maps_navigation/SCR-035_map_picker_screen.png',
    );

    // SCR-037: Offline Map Manager Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const OfflineMapManagerScreen(),
      outputPath: '../docs/ui-audit/screenshots/07_maps_navigation/SCR-037_offline_map_manager.png',
    );

    // SCR-041: Intercom Options Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: IntercomOptions(),
      ),
      outputPath: '../docs/ui-audit/screenshots/08_communication/SCR-041_intercom_options_sheet.png',
    );

    // SCR-042: Messages Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: MessagesView(
          convoyId: sampleConvoy.groupId,
          me: me,
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/08_communication/SCR-042_messages_sheet.png',
    );

    debugPrint('BATCH_3_CAPTURED_SUCCESSFULLY');
  });
}
