import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/presentation/rider/rider_home_screen.dart';
import 'package:coroute_app/presentation/home/ride_start_view.dart';
import 'package:coroute_app/presentation/alerts/alerts_screen.dart';
import 'package:coroute_app/presentation/trip_planner/trip_planner_screen.dart';
import 'package:coroute_app/presentation/trip_planner/route_stops_panel.dart';
import 'package:coroute_app/presentation/trip_planner/trip_review_sheet.dart';
import 'package:coroute_app/presentation/trip/trip_feedback_sheet.dart';
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

  testWidgets('Batch 2: Home Navigation & Trip Management Screens', (tester) async {
    // SCR-013: Home Ride Start View
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(body: RideStartView()),
      outputPath: '../docs/ui-audit/screenshots/03_home_navigation/SCR-013_home_ride_start_view.png',
    );

    // SCR-014: Home Alerts Tab / Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const AlertsScreen(),
      outputPath: '../docs/ui-audit/screenshots/03_home_navigation/SCR-014_home_alerts_tab.png',
    );

    // SCR-015: Home Join Ride Modal Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const JoinRideSheet(initialCode: '650505'),
      outputPath: '../docs/ui-audit/screenshots/03_home_navigation/SCR-015_home_join_ride_sheet.png',
    );

    // SCR-016: Trip Planner Default Screen
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const TripPlannerScreen(),
      outputPath: '../docs/ui-audit/screenshots/04_trip_management/SCR-016_trip_planner_default.png',
    );

    // SCR-018: Route Stops Panel
    final sampleConvoy = createSampleConvoyModel();
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: Scaffold(body: RouteStopsPanel(convoy: sampleConvoy)),
      outputPath: '../docs/ui-audit/screenshots/04_trip_management/SCR-018_route_stops_panel.png',
    );

    // SCR-019: Trip Review Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: TripReviewSheet(
          name: 'Bangalore to Goa Monsoon Run',
          startName: 'Hebbal, Bangalore',
          destinationName: 'Panaji, Goa',
          stops: 3,
          speedLimitKmh: 80,
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/04_trip_management/SCR-019_trip_review_sheet.png',
    );

    // SCR-020 (offline tile verification) removed Nov 11: offline maps are automatic.

    // SCR-021: Trip Feedback Sheet
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const Scaffold(
        body: TripFeedbackSheet(
          tripId: 'trip_blr_goa_01',
          tripName: 'Bangalore to Goa Monsoon Run',
        ),
      ),
      outputPath: '../docs/ui-audit/screenshots/04_trip_management/SCR-021_trip_feedback_sheet.png',
    );

    // SCR-012: Home Screen Default
    await renderAndSaveScreen(
      tester: tester,
      env: env,
      widget: const RiderHomeScreen(),
      outputPath: '../docs/ui-audit/screenshots/03_home_navigation/SCR-012_home_screen_default.png',
    );

    debugPrint('BATCH_2_CAPTURED_SUCCESSFULLY');
  });
}
