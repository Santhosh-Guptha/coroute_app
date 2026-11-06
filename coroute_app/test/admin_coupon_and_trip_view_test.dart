import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/admin/admin_payment_analytics_tab.dart';
import 'package:coroute_app/presentation/admin/admin_payments_logic.dart';
import 'package:coroute_app/presentation/admin/admin_plans_pricing_screen.dart';
import 'package:coroute_app/presentation/rider/trip_history_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => AppTheme.use(AppPalette.dark));

  group('Trip History View-Only Integrity', () {
    testWidgets('renders trips as view-only and contains NO delete options', (tester) async {
      final mockHttp = MockClient((req) async => http.Response('{}', 200, headers: {'content-type': 'application/json'}));
      final apiClient = ApiClient(httpClient: mockHttp);
      final authService = AuthService(apiClient);
      final tripStorage = TripStorageService(apiClient);

      final dummyTrip = TripHistoryModel(
        tripId: 'trip_view_only_123',
        tripName: 'Morning Ride to Nandi Hills',
        startTimeEpochMs: DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
        endTimeEpochMs: DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        totalDistanceKm: 65.4,
        avgSpeedKmh: 42.0,
        topSpeedKmh: 78.0,
        riderCount: 4,
        breadcrumbTrail: const [],
      );

      await tripStorage.saveTrip(dummyTrip);

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ApiClient>.value(value: apiClient),
              ChangeNotifierProvider<AuthService>.value(value: authService),
              ChangeNotifierProvider<TripStorageService>.value(value: tripStorage),
            ],
            child: const TripHistoryScreen(embedded: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trip is rendered
      expect(find.text('Morning Ride to Nandi Hills'), findsOneWidget);

      // CRITICAL SAFETY REQUIREMENT: NO Delete trip option exists for users
      expect(find.text('Delete trip'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);

      // View chevron affordance is present
      expect(find.byIcon(Icons.arrow_forward_ios_rounded), findsOneWidget);
    });
  });

  group('Admin Console Payments: Revenue and tabs', () {
    // The server plan catalog (GET /api/admin/coupons/plan-options), with prices an admin set.
    const planOptions = [
      {'id': 'proRider', 'label': 'CoRoute Pro', 'kind': 'subscription', 'monthlyInr': 199, 'annualInr': 1999, 'isActive': true},
      {'id': 'individual', 'label': 'Individual Membership', 'kind': 'membership', 'monthlyInr': 9, 'annualInr': null, 'isActive': true},
      {'id': 'group_small', 'label': 'Small Group (2–6)', 'kind': 'membership', 'monthlyInr': 59, 'annualInr': null, 'isActive': true},
      {'id': 'group_large', 'label': 'Large Group (7–12)', 'kind': 'membership', 'monthlyInr': 119, 'annualInr': null, 'isActive': true},
      {'id': 'family', 'label': 'Family Pack', 'kind': 'membership', 'monthlyInr': 149, 'annualInr': null, 'isActive': true},
    ];

    testWidgets('AdminPaymentAnalyticsTab displays financial KPIs, plan breakdown, and timeline', (tester) async {
      final client = MockClient((req) async {
        if (req.url.path.contains('/admin/payments/analytics')) {
          return http.Response(
            jsonEncode({
              'summary': {
                'grossSalesInr': 1580,
                'discountsInr': 380,
                'netRevenueInr': 1200,
                'totalTransactions': 25,
                'paidOrders': 20,
                'freeActivations': 5,
                'failedOrders': 2,
                'refundedAmountInr': 0,
                'refundedOrders': 0,
                'activeMemberships': 18,
                'newMemberships': 12,
                'averageOrderValueInr': 60,
              },
              'byPlan': {
                'individual': {
                  'name': 'Individual Membership (₹9/mo)',
                  'units': 10,
                  'grossInr': 90,
                  'discountsInr': 10,
                  'netInr': 80,
                  'activeMembers': 8,
                },
                'group_small': {
                  'name': 'Small Group 2–6 (₹49/mo)',
                  'units': 8,
                  'grossInr': 392,
                  'discountsInr': 100,
                  'netInr': 292,
                  'activeMembers': 6,
                },
                // 3.54: no group_large sales in the period: its row comes from the plan catalog.
              },
              'couponAnalytics': {
                'topCoupons': [
                  {
                    'code': 'SUMMER100',
                    'campaignName': 'Summer Launch',
                    'redemptions': 6,
                    'uniqueUsers': 6,
                    'discountAmount': 150,
                    'netRevenue': 300,
                  },
                ],
              },
              'timeline': [
                {'date': '2026-11-01', 'netInr': 240, 'orders': 4},
                {'date': '2026-11-02', 'netInr': 480, 'orders': 8},
                {'date': '2026-11-03', 'netInr': 360, 'orders': 6},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (req.url.path.contains('/admin/coupons/plan-options')) {
          return http.Response(jsonEncode({'plans': planOptions}), 200, headers: {'content-type': 'application/json'});
        }
        return http.Response('{}', 404);
      });

      final apiClient = ApiClient(httpClient: client);

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ApiClient>.value(value: apiClient),
            ],
            child: const Scaffold(
              body: AdminPaymentAnalyticsTab(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Gross sales'), findsOneWidget);
      expect(find.text('Discounts'), findsOneWidget);
      expect(find.text('Net revenue'), findsOneWidget);
      expect(find.text('Paid orders'), findsOneWidget);
      expect(find.text('Free plans'), findsOneWidget);
      // Names of plans with sales come from the analytics; a plan without sales gets its name and
      // price from the server plan catalog (an admin changed it to ₹119), never a hard-coded ₹99.
      expect(find.text('Individual Membership (₹9/mo)'), findsOneWidget);
      expect(find.text('Small Group 2–6 (₹49/mo)'), findsOneWidget);
      expect(find.text('Large Group (7–12) (₹119/mo)'), findsOneWidget);
      expect(find.textContaining('₹99'), findsNothing);
    });

    test('plan labels use the server catalog price, and no price when the server has none', () {
      expect(adminPlanLabel('group_small', planOptions), 'Small Group (2–6) (₹59/mo)');
      expect(adminPlanLabel('group_small', planOptions, perMonth: false), 'Small Group (2–6) (₹59)');
      expect(adminPlanLabel('group_large', const []), 'Large Group (7–12)');
      expect(adminPlanLabel('individual', const []), 'Individual (retired)');
      // Coupons bind to the paid plans only (Community is free; Individual is retired).
      expect(adminMembershipPlanIds(planOptions), ['group_small', 'group_large']);
    });

    testWidgets('Payments has four plain tabs: Payments, Revenue, Plans, Coupons (no module menu)', (tester) async {
      final client = MockClient((req) async => http.Response('{}', 200, headers: {'content-type': 'application/json'}));
      final apiClient = ApiClient(httpClient: client);
      final authService = AuthService(apiClient);

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ApiClient>.value(value: apiClient),
              ChangeNotifierProvider<AuthService>.value(value: authService),
            ],
            child: const AdminPlansPricingScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(AdminPaymentsTab.values.map((t) => t.label).toList(), ['Payments', 'Revenue', 'Plans', 'Coupons']);
      for (final label in ['Revenue', 'Plans', 'Coupons']) {
        expect(find.widgetWithText(Tab, label), findsOneWidget, reason: label);
      }
      expect(find.widgetWithText(Tab, 'Payments'), findsOneWidget);
      // Retired: the module menu, the members, coupon-use, offers, audit and gateway tabs.
      for (final gone in ['All modules', 'Jump to module', 'Members', 'Coupon use', 'Offers', 'Audit log', 'Gateway', 'MODULE CLUSTER']) {
        expect(find.widgetWithText(Tab, gone), findsNothing, reason: gone);
        expect(find.byTooltip(gone), findsNothing, reason: gone);
      }
      // Opening on a tab: Coupons shows the coupons and the automatic offers together.
      await tester.tap(find.widgetWithText(Tab, 'Coupons'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Coupons ('), findsOneWidget);
      expect(find.textContaining('Offers ('), findsOneWidget);
    });
  });
}
