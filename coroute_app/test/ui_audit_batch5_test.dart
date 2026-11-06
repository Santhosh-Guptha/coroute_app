import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/data/services/app_version_service.dart';
import 'package:coroute_app/data/services/smart_airbag_bridge_service.dart';
import 'package:coroute_app/data/services/gpx_service.dart';

// Profile & Account
import 'package:coroute_app/presentation/account/account_screen.dart';
import 'package:coroute_app/presentation/account/edit_profile_screen.dart';
import 'package:coroute_app/presentation/account/change_password_screen.dart';
import 'package:coroute_app/presentation/account/appearance_sheet.dart';

// Admin screens
import 'package:coroute_app/presentation/admin/master_admin_dashboard.dart';
import 'package:coroute_app/presentation/admin/admin_safety_screen.dart';
import 'package:coroute_app/presentation/admin/admin_settings_screen.dart';
import 'package:coroute_app/presentation/admin/admin_users_screen.dart';
import 'package:coroute_app/presentation/admin/admin_user_details_screen.dart';
import 'package:coroute_app/presentation/admin/admin_convoy_inspector.dart';
import 'package:coroute_app/presentation/admin/admin_plans_pricing_screen.dart';
import 'package:coroute_app/presentation/admin/admin_device_compatibility_screen.dart';
import 'package:coroute_app/presentation/admin/admin_emergencies_panel.dart';

// Dialogs & Modals
import 'package:coroute_app/presentation/widgets/rider_status_sheet.dart';
import 'package:coroute_app/presentation/ride/meet_here_sheet.dart';
import 'package:coroute_app/presentation/ride/incident_sheet.dart';
import 'package:coroute_app/presentation/ride/assist_sheet.dart';
import 'package:coroute_app/presentation/widgets/pre_ride_checklist_sheet.dart';

// Loading, Error, Offline
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:coroute_app/presentation/widgets/data_saver_tile.dart';

// Other Screens
import 'package:coroute_app/presentation/update/force_update_screen.dart';
import 'package:coroute_app/presentation/report/trip_report_screen.dart';
import 'package:coroute_app/presentation/rider/ride_replay_screen.dart';
import 'package:coroute_app/presentation/rider/widgets/tactical_ride_share_card.dart';
import 'package:coroute_app/presentation/rider/widgets/smart_airbag_hud_pill.dart';

import 'ui_audit_helper.dart';

class FakeAdminAlarm implements AdminAlarm {
  @override
  Future<void> start({required String title, required String body}) async {}
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuditEnvironment env;
  late AppVersionService appVersionService;

  setUp(() async {
    env = await AuditEnvironment.create(isMasterAdmin: true);
    appVersionService = AppVersionService(env.meta);
  });

  tearDown(() {
    appVersionService.dispose();
    env.dispose();
  });

  testWidgets('Batch 5: Profile, Admin, Dialogs, Offline, and Other Screens', (tester) async {
    // -------------------------------------------------------------------------
    // CATEGORY 12: Profile & Settings
    // -------------------------------------------------------------------------

    // SCR-062: Account Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AccountScreen(embedded: false),
      outputPath: '../docs/ui-audit/screenshots/12_profile_settings/SCR-062_account_screen.png',
    );

    // SCR-063: Edit Profile Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const EditProfileScreen(),
      outputPath: '../docs/ui-audit/screenshots/12_profile_settings/SCR-063_edit_profile_screen.png',
    );

    // SCR-064: Change Password Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const ChangePasswordScreen(forced: false),
      outputPath: '../docs/ui-audit/screenshots/12_profile_settings/SCR-064_change_password_screen.png',
    );

    // SCR-065: Appearance Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: Center(
          child: AppearanceSheet(),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/12_profile_settings/SCR-065_appearance_sheet.png',
    );

    // -------------------------------------------------------------------------
    // CATEGORY 13: Admin & Operations
    // -------------------------------------------------------------------------

    // SCR-066: Master Admin Dashboard
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: MasterAdminDashboard(alarm: FakeAdminAlarm()),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-066_master_admin_dashboard.png',
    );

    // SCR-067: Admin Safety (the old separate phone dashboard is retired: one console for all sizes)
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: AdminSafetyScreen(alarm: FakeAdminAlarm()),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-067_admin_safety_screen.png',
    );

    // SCR-068: Admin Users Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AdminUsersScreen(initialFilter: AdminUserFilter.all),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-068_admin_users_screen.png',
    );

    // SCR-069: Admin User Details Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AdminUserDetailsScreen(userId: 'rider_dev_01'),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-069_admin_user_details_screen.png',
    );

    // SCR-070: Admin Convoy Inspector
    final sampleConvoy = createSampleConvoyModel();
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: AdminConvoyInspector(convoy: sampleConvoy),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-070_admin_convoy_inspector.png',
    );

    // SCR-071: Admin Plans & Pricing Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AdminPlansPricingScreen(initialTab: AdminPaymentsTab.plans),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-071_admin_plans_pricing_screen.png',
    );

    // SCR-072: Admin Promotions / Offers Tab
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AdminPlansPricingScreen(initialTab: AdminPaymentsTab.coupons),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-072_admin_promotions_tabs.png',
    );

    // SCR-073: Admin Device Compatibility Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AdminDeviceCompatibilityScreen(),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-073_admin_device_compatibility.png',
    );

    // SCR-074: Admin Emergencies Panel
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: Center(
          child: AdminEmergenciesPanel(alarm: FakeAdminAlarm()),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-074_admin_emergencies_panel.png',
    );

    // SCR-075: Admin Payment Analytics Tab
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AdminPlansPricingScreen(initialTab: AdminPaymentsTab.revenue),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-075_admin_payment_analytics_tab.png',
    );

    // SCR-076: Admin Payments list (the coupon usage tab was retired; coupons used are under Revenue)
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AdminPlansPricingScreen(initialTab: AdminPaymentsTab.payments),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-076_admin_payments_list.png',
    );

    // SCR-077: Admin Settings (website numbers, gateway, audit log, tools)
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AdminSettingsScreen(),
      outputPath: '../docs/ui-audit/screenshots/13_admin_client/SCR-077_admin_settings_screen.png',
    );

    // -------------------------------------------------------------------------
    // CATEGORY 14: Dialogs & Modals
    // -------------------------------------------------------------------------

    // SCR-078: Quick Stop Reason Modal
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: Center(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF141923),
              borderRadius: BorderRadius.circular(16),
            ),
            child: StatusPicker(
              currentCode: 'FUELING',
              onPick: (code, msg) {},
              onClear: () {},
            ),
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/14_dialogs_modals/SCR-078_quick_stop_reason_modal.png',
    );

    // SCR-080: Meet Here Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: Center(
          child: MeetHereSheet(
            placeName: () async => 'Tumkur Toll Plaza',
            distanceFromMeM: 32400,
            lead: true,
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/14_dialogs_modals/SCR-080_meet_here_sheet.png',
    );

    // SCR-081: Incident Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: SingleChildScrollView(
          child: IncidentSheetBody(
            convoyId: 'trip_blr_goa_01',
            subjectUserId: 'rider_dev_02',
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/14_dialogs_modals/SCR-081_incident_sheet.png',
    );

    // SCR-082: Assist Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: SingleChildScrollView(
          child: AssistSheetBody(
            incidentId: 'incident_01',
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/14_dialogs_modals/SCR-082_assist_sheet.png',
    );

    // SCR-083: Pre-Ride Checklist Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: SingleChildScrollView(
          child: PreRideChecklistSheet(checks: []),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/14_dialogs_modals/SCR-083_pre_ride_checklist_sheet.png',
    );

    // -------------------------------------------------------------------------
    // CATEGORY 15: Loading, Error & Offline States
    // -------------------------------------------------------------------------

    // SCR-086: Connection Banner Offline
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: Column(
          children: [
            SizedBox(height: 120),
            ConnectionBanner(),
            Spacer(),
          ],
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/15_loading_error_offline/SCR-086_connection_banner_offline.png',
    );

    // SCR-087: Data Saver Tile
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: DataSaverTile(),
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/15_loading_error_offline/SCR-087_data_saver_tile.png',
    );

    // -------------------------------------------------------------------------
    // CATEGORY 16: Other System Screens & High-Value Cards
    // -------------------------------------------------------------------------

    // SCR-088: Force Update Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: ChangeNotifierProvider<AppVersionService>.value(
        value: appVersionService,
        child: const ForceUpdateScreen(),
      ),
      outputPath: '../docs/ui-audit/screenshots/16_other_screens/SCR-088_force_update_screen.png',
    );

    // SCR-089: Trip Report Screen
    final sampleTripHistory = TripHistoryModel(
      tripId: 'trip_blr_goa_01',
      tripName: 'Bangalore to Goa Monsoon Run',
      startLocationName: 'Hebbal, Bangalore',
      destinationName: 'Panaji, Goa',
      startTimeEpochMs: DateTime.now().millisecondsSinceEpoch - 3600000 * 5,
      endTimeEpochMs: DateTime.now().millisecondsSinceEpoch,
      totalDistanceKm: 494.0,
      topSpeedKmh: 98.4,
      avgSpeedKmh: 68.2,
      riderCount: 4,
      stopCount: 2,
      breadcrumbTrail: [
        TripBreadcrumbPoint(
          lat: 12.9716,
          lng: 77.5946,
          speedKmh: 65.0,
          heading: 310.0,
          timestamp: DateTime.now().millisecondsSinceEpoch - 3600000 * 4,
        ),
        TripBreadcrumbPoint(
          lat: 13.3409,
          lng: 77.1010,
          speedKmh: 75.0,
          heading: 315.0,
          timestamp: DateTime.now().millisecondsSinceEpoch - 3600000 * 2,
        ),
        TripBreadcrumbPoint(
          lat: 15.2993,
          lng: 74.1240,
          speedKmh: 0.0,
          heading: 0.0,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      userId: 'rider_dev_01',
      createdByUserName: 'Santhosh Bukka',
    );

    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: TripReportScreen(trip: sampleTripHistory),
      outputPath: '../docs/ui-audit/screenshots/16_other_screens/SCR-089_trip_report_screen.png',
    );

    // SCR-090: Ride Replay Screen
    final trackpoints = [
      GpxTrackpoint(
        latitude: 12.9716,
        longitude: 77.5946,
        elevationM: 920.0,
        speedKmh: 65.0,
        timestamp: DateTime.now().subtract(const Duration(hours: 3)),
      ),
      GpxTrackpoint(
        latitude: 13.3409,
        longitude: 77.1010,
        elevationM: 840.0,
        speedKmh: 78.0,
        timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      ),
      GpxTrackpoint(
        latitude: 15.2993,
        longitude: 74.1240,
        elevationM: 10.0,
        speedKmh: 45.0,
        timestamp: DateTime.now(),
      ),
    ];
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: RideReplayScreen(
        rideTitle: 'Bangalore to Goa Monsoon Run',
        convoyCode: '650505',
        trackpoints: trackpoints,
      ),
      outputPath: '../docs/ui-audit/screenshots/16_other_screens/SCR-090_ride_replay_screen.png',
    );

    // SCR-091: Tactical Ride Share Card
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TacticalRideShareCard(
              rideTitle: 'Bangalore to Goa Monsoon Run',
              convoyCode: '650505',
              startTime: DateTime.now().subtract(const Duration(hours: 6)),
              distanceKm: 494.0,
              duration: const Duration(hours: 6, minutes: 12),
              avgSpeedKmh: 79.7,
              topSpeedKmh: 108.5,
              elevationGainM: 1240.0,
            ),
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/16_other_screens/SCR-091_tactical_ride_share_card.png',
    );

    // SCR-093: Smart Airbag HUD Pill
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: SmartAirbagHudPill(
              connectionState: AirbagConnectionState.connected,
              telemetry: AirbagTelemetry(
                modelName: 'Alpinestars Tech-Air 5',
                batteryLevel: 92,
                isArmed: true,
                isDeployed: false,
              ),
            ),
          ),
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/16_other_screens/SCR-093_smart_airbag_hud_pill.png',
    );
  });
}

