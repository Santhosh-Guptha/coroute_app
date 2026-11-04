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
import 'package:coroute_app/presentation/admin/admin_coupon_usage_tab.dart';
import 'package:coroute_app/presentation/admin/admin_payment_analytics_tab.dart';
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

  group('Admin Console Coupon Usage & Analytics Views', () {
    testWidgets('AdminCouponUsageTab displays KPIs, filters, and redemptions log', (tester) async {
      final client = MockClient((req) async {
        if (req.url.path.contains('/admin/coupons/usage')) {
          return http.Response(
            jsonEncode({
              'summary': {
                'totalCoupons': 5,
                'activeCoupons': 4,
                'totalRedemptions': 12,
                'totalDiscountGivenInr': 360,
                'revenueGeneratedInr': 480,
                'uniqueUsersCount': 10,
              },
              'redemptions': [
                {
                  'redemptionId': 'red_1',
                  'couponCode': 'DIWALI50',
                  'campaignName': 'Diwali 2026 Blitz',
                  'userId': 'user_1',
                  'userName': 'Vikram Rathore',
                  'userEmail': 'vikram@coroute.test',
                  'category': 'group_small',
                  'categoryName': 'Group (2–6)',
                  'originalPrice': 49,
                  'discountAmount': 24,
                  'finalAmount': 25,
                  'orderId': 'mem_ord_test_01',
                  'status': 'SUCCESS',
                  'redeemedAt': DateTime.now().millisecondsSinceEpoch,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
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
              body: AdminCouponUsageTab(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Total Redemptions'), findsOneWidget);
      expect(find.text('Discounts Granted'), findsOneWidget);
      expect(find.text('Coupon Revenue'), findsOneWidget);
      expect(find.text('Active Coupons'), findsOneWidget);
      expect(find.textContaining('DIWALI50'), findsOneWidget);
      expect(find.textContaining('Vikram Rathore'), findsOneWidget);
    });

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
                'group_large': {
                  'name': 'Large Group 7–12 (₹99/mo)',
                  'units': 5,
                  'grossInr': 495,
                  'discountsInr': 50,
                  'netInr': 445,
                  'activeMembers': 4,
                },
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

      expect(find.text('Gross Sales'), findsOneWidget);
      expect(find.text('Total Discounts'), findsOneWidget);
      expect(find.text('Net Revenue'), findsOneWidget);
      expect(find.text('Paid Orders'), findsOneWidget);
      expect(find.text('Free Activations'), findsOneWidget);
      expect(find.text('Individual Membership (₹9/mo)'), findsOneWidget);
      expect(find.text('Small Group 2–6 (₹49/mo)'), findsOneWidget);
      expect(find.text('Large Group 7–12 (₹99/mo)'), findsOneWidget);
    });

    testWidgets('AdminPlansPricingScreen features the required 7 navigation entries', (tester) async {
      final client = MockClient((req) async {
        if (req.url.path.contains('/admin/subscription/overview')) {
          return http.Response(
            jsonEncode({
              'subscribers': {'community': 10, 'proRider': 5, 'roadCaptain': 2, 'tourOperator': 1},
              'totalUsers': 18,
              'active': 8,
              'revenue': {'today': 0, 'last7Days': 100, 'last30Days': 500, 'allTime': 1000},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      });

      final apiClient = ApiClient(httpClient: client);
      final authService = AuthService(apiClient);

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ApiClient>.value(value: apiClient),
              ChangeNotifierProvider<AuthService>.value(value: authService),
            ],
            child: const AdminPlansPricingScreen(initialTab: AdminPaymentsTab.overview),
          ),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      // Verify the 7 required tabs in enum
      expect(AdminPaymentsTab.overview.label, 'Dashboard');
      expect(AdminPaymentsTab.subscribers.label, 'Membership Management');
      expect(AdminPaymentsTab.coupons.label, 'Coupon Management');
      expect(AdminPaymentsTab.couponUsage.label, 'Coupon Usage');
      expect(AdminPaymentsTab.analytics.label, 'Payment Analytics');
      expect(AdminPaymentsTab.payments.label, 'Transaction History');
      expect(AdminPaymentsTab.audit.label, 'Audit Logs');
    });
  });
}
