import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/membership_service.dart';
import 'package:coroute_app/presentation/subscription/membership_payment_screen.dart';
import 'package:coroute_app/presentation/subscription/payment_success_screen.dart';
import 'package:coroute_app/presentation/trip_planner/trip_creation_payment_alert_sheet.dart';
import 'package:coroute_app/presentation/trip_planner/trip_review_sheet.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super();

  @override
  Future<dynamic> get(String path, {Duration timeout = const Duration(seconds: 10)}) async {
    if (path == '/membership/catalog') {
      return {
        'categories': {
          'individual': {'id': 'individual', 'name': 'Individual Membership', 'monthlyPriceInr': 9, 'capacity': 1},
          'group_small': {'id': 'group_small', 'name': 'Group Membership (2–6)', 'monthlyPriceInr': 49, 'capacity': 6},
        },
        'paymentsEnabled': true,
      };
    }
    if (path == '/membership/my') {
      return {
        'owned': null,
        'participating': [],
        'paymentsEnabled': true,
      };
    }
    return {};
  }

  @override
  Future<dynamic> post(String path, [Object? body, Duration timeout = const Duration(seconds: 12), bool auth = true]) async {
    if (path == '/membership/order') {
      return {
        'orderId': 'order_test_123',
        'keyId': 'rzp_test_dummy',
        'amountInPaise': 0,
        'isFree': true,
      };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testCategory = MembershipCategory(
    id: 'individual',
    name: 'Individual Membership',
    priceRupees: 9,
    capacity: 1,
  );

  final testMembership = UserMembership(
    membershipId: 'mem_12345',
    ownerUserId: 'user_tester',
    category: 'individual',
    categoryName: 'Individual Membership',
    capacity: 1,
    priceRupees: 9,
    status: 'ACTIVE',
    validUntil: DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
  );

  Widget createTestApp(Widget child) {
    AppTheme.use(AppPalette.dark);
    final api = _FakeApiClient();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<MembershipService>(create: (_) => MembershipService(api)),
        ChangeNotifierProvider<AuthService>(create: (_) => AuthService(api)),
      ],
      child: MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  group('Stage 1: Trip Creation Payment Alert Sheet', () {
    testWidgets('renders plan details, RIDERFREE discount and triggers action buttons', (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      bool? result;

      await tester.pumpWidget(createTestApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await TripCreationPaymentAlertSheet.show(
                context,
                category: testCategory,
                activeOfferCode: 'RIDERFREE',
                discountPercent: 100,
              );
            },
            child: const Text('Open Sheet'),
          ),
        ),
      ));

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      // Verify Stage 1 UI
      expect(find.text('Membership Required'), findsOneWidget);
      expect(find.text('Individual Membership'), findsOneWidget);
      expect(find.text('1 Rider'), findsOneWidget);
      expect(find.text('Introductory Offer (RIDERFREE)'), findsOneWidget);
      expect(find.text('₹0.00 (Free)'), findsOneWidget);
      expect(find.text('Activate Free Introductory Offer'), findsOneWidget);
      expect(find.text('Maybe Later'), findsOneWidget);

      // Tap Proceed
      await tester.tap(find.text('Activate Free Introductory Offer'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });

    testWidgets('Maybe Later dismisses without proceeding', (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      bool? result = true;

      await tester.pumpWidget(createTestApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await TripCreationPaymentAlertSheet.show(
                context,
                category: testCategory,
                activeOfferCode: 'RIDERFREE',
                discountPercent: 100,
              );
            },
            child: const Text('Open Sheet'),
          ),
        ),
      ));

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      // Tap Maybe Later
      await tester.tap(find.text('Maybe Later'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });
  });

  group('Stage 2: Membership Payment Screen', () {
    testWidgets('renders payment methods, benefits, price summary and handles free promo checkout', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(createTestApp(
        const MembershipPaymentScreen(
          category: testCategory,
          isTripCreationFlow: true,
        ),
      ));
      await tester.pumpAndSettle();

      // Verify UI
      expect(find.text('Membership Payment'), findsOneWidget);
      expect(find.text('Individual Membership'), findsOneWidget);
      expect(find.text('1 Rider Capacity · Monthly Subscription'), findsOneWidget);
      expect(find.text('PROMOTIONAL COUPON'), findsOneWidget);
      expect(find.text('Instant UPI Apps'), findsOneWidget);
      expect(find.text('Cards & Net Banking'), findsOneWidget);
      expect(find.text('Total Payable'), findsOneWidget);
      expect(find.text('Activate Free Introductory Offer (₹0)'), findsOneWidget);

      // Verify promo coupon modification
      await tester.enterText(find.byType(TextField).first, '');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // Should show base price ₹9.00
      expect(find.text('₹9.00'), findsWidgets);

      // Re-apply RIDERFREE
      await tester.enterText(find.byType(TextField).first, 'RIDERFREE');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('Introductory promo applied: 100% OFF (₹0)'), findsOneWidget);
      expect(find.text('Activate Free Introductory Offer (₹0)'), findsOneWidget);
    });
  });

  group('Stage 3: Payment Success Screen', () {
    testWidgets('renders verified badge, transaction ref and Continue button', (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(createTestApp(
        PaymentSuccessScreen(
          membership: testMembership,
          transactionReference: 'pay_test_8877665544',
          amountPaidInRupees: 0,
          isTripCreationFlow: true,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Membership Activated!'), findsOneWidget);
      expect(find.text('Individual Membership'), findsOneWidget);
      expect(find.text('₹0.00 (Introductory Offer)'), findsOneWidget);
      expect(find.textContaining('pay_test_88776655'), findsOneWidget);
      expect(find.text('Active · Server Verified'), findsOneWidget);
      expect(find.text('Continue Creating Your Trip'), findsOneWidget);
    });
  });

  group('Stage 4: Return to Trip Review Sheet', () {
    testWidgets('displays Membership Activated Successfully banner and Confirm and Create Trip button', (tester) async {
      int? chosenLimit;

      await tester.pumpWidget(createTestApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              chosenLimit = await TripReviewSheet.show(
                context,
                name: 'Bengaluru Monsoon Expedition',
                startName: 'Indiranagar',
                destinationName: 'Nandi Hills',
                route: RouteModel(distanceM: 62000, durationS: 5400, polyline: ''),
                stops: 1,
                speedLimitKmh: 60,
                membershipActivated: true,
                confirmLabel: 'Confirm and Create Trip',
              );
            },
            child: const Text('Open Review'),
          ),
        ),
      ));

      await tester.tap(find.text('Open Review'));
      await tester.pumpAndSettle();

      // Verify Stage 4 restored state & banner
      expect(find.text('Membership Activated Successfully'), findsOneWidget);
      expect(find.text('Bengaluru Monsoon Expedition'), findsOneWidget);
      expect(find.text('From Indiranagar to Nandi Hills'), findsOneWidget);
      expect(find.text('62 km'), findsOneWidget);
      expect(find.text('1 h 30 min'), findsOneWidget);
      expect(find.text('Confirm and Create Trip'), findsOneWidget);

      // Explicit user confirmation
      await tester.tap(find.byKey(const Key('trip_review_confirm_button')));
      await tester.pumpAndSettle();

      expect(chosenLimit, 60);
    });
  });
}
