import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  /// Every POST the screens made, in order: (path, body).
  final List<(String, Map)> posts = [];

  /// Coupon codes the gateway refuses at validate-coupon, with the reason it gives.
  static const refusals = {
    'USEDCODE': ('You have reached the redemption limit (1) for coupon USEDCODE', 'PER_USER_LIMIT_REACHED'),
    'GROUPONLY': ('Coupon GROUPONLY is only applicable to group_small', 'TIER_MISMATCH'),
    'OLDCODE': ('This coupon has expired', 'COUPON_EXPIRED'),
    'NOSUCH': ('Coupon NOSUCH does not exist', 'COUPON_NOT_FOUND'),
  };

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
    final m = body is Map ? body : const {};
    posts.add((path, m));
    if (path == '/membership/order') {
      // A paid order; payments are not configured in tests (no key), so checkout stops before Razorpay.
      return {
        'orderId': 'order_test_123',
        'keyId': '',
        'amountInPaise': 900,
        'isFree': false,
      };
    }
    if (path == '/membership/validate-coupon') {
      final code = m['code']?.toString() ?? '';
      final refusal = refusals[code];
      if (refusal != null) throw ApiException(400, refusal.$1, null, refusal.$2);
      if (code == 'RIDERFREE' || code == 'ONCEONLY') {
        return {
          'valid': true,
          'code': code,
          'discountType': 'free',
          'discountAmount': 9,
          'originalPrice': 9,
          'finalAmount': 0,
          'isFree': true,
          'message': 'Discount of ₹9 applied. Final payable: ₹0',
        };
      }
      if (code == 'SAVE3') {
        return {
          'valid': true,
          'code': code,
          'discountType': 'fixed',
          'discountAmount': 3,
          'originalPrice': 9,
          'finalAmount': 6,
          'isFree': false,
          'message': 'Discount of ₹3 applied. Final payable: ₹6',
        };
      }
      throw ApiException(404, 'Coupon $code does not exist', null, 'COUPON_NOT_FOUND');
    }
    if (path == '/membership/activate-free') {
      // ONCEONLY validated, but the rider spent it meanwhile: the server refuses the activation.
      if (m['couponCode'] == 'ONCEONLY') {
        throw const ApiException(400, 'You have already redeemed coupon ONCEONLY (limit 1 per rider)', null, 'PER_USER_LIMIT_REACHED');
      }
      return {
        'success': true,
        'isFree': true,
        'orderId': 'FREE-ACTIVATION-TEST',
        'membership': {
          'id': 'mem_free_123',
          'userId': 'user_tester',
          'categoryId': 'individual',
          'categoryName': 'Individual Membership',
          'capacity': 1,
          'priceRupees': 9,
          'status': 'ACTIVE',
          'validUntil': DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
        },
      };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  late _FakeApiClient api;

  Widget createTestApp(Widget child) {
    AppTheme.use(AppPalette.dark);
    api = _FakeApiClient();
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
    testWidgets('shows the normal price when no offer is advertised (no code assumed)', (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      bool? result;

      await tester.pumpWidget(createTestApp(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await TripCreationPaymentAlertSheet.show(context, category: testCategory);
            },
            child: const Text('Open Sheet'),
          ),
        ),
      ));

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('Membership Required'), findsOneWidget);
      expect(find.textContaining('RIDERFREE'), findsNothing);
      expect(find.textContaining('Offer ('), findsNothing);
      expect(find.text('₹9.00'), findsOneWidget);
      expect(find.text('Proceed to Payment (₹9)'), findsOneWidget);

      await tester.tap(find.text('Proceed to Payment (₹9)'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('renders plan details, an advertised offer and triggers action buttons', (tester) async {
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
                activeOfferCode: 'MONSOON',
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
      expect(find.text('Offer (MONSOON)'), findsOneWidget);
      expect(find.text('-₹9 (100% OFF)'), findsOneWidget);
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
              result = await TripCreationPaymentAlertSheet.show(context, category: testCategory);
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
    testWidgets('hides payment methods at ₹0, restores them when coupon removed, and handles free activation', (tester) async {
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

      // Verify UI - starts with empty coupon as requested
      expect(find.text('Membership Payment'), findsOneWidget);
      expect(find.text('Individual Membership'), findsOneWidget);
      expect(find.text('1 Rider Capacity · Monthly Subscription'), findsOneWidget);
      expect(find.text('PROMOTIONAL COUPON (OPTIONAL)'), findsOneWidget);
      expect(find.text('Enter coupon code'), findsOneWidget);

      // Initially at ₹9: Payment methods (UPI, Cards) are visible
      expect(find.text('Instant UPI Apps'), findsOneWidget);
      expect(find.text('Cards & Net Banking'), findsOneWidget);
      expect(find.text('Pay ₹9 & Activate Membership'), findsOneWidget);

      // Apply RIDERFREE coupon
      await tester.enterText(find.byType(TextField).first, 'RIDERFREE');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // At ₹0: Payment methods (UPI, Cards) MUST be hidden, Instant activation card visible
      expect(find.text('RIDERFREE Applied!'), findsOneWidget);
      expect(find.text('Instant UPI Apps'), findsNothing);
      expect(find.text('Cards & Net Banking'), findsNothing);
      expect(find.text('100% Free Activation'), findsOneWidget);
      expect(find.text('Activate Free Membership (₹0)'), findsOneWidget);

      // Remove coupon via "Remove Coupon" button
      await tester.tap(find.text('Remove Coupon'));
      await tester.pumpAndSettle();

      // Should restore base price ₹9.00 and payment methods now visible again!
      expect(find.text('₹9.00'), findsWidgets);
      expect(find.text('Instant UPI Apps'), findsOneWidget);
      expect(find.text('Cards & Net Banking'), findsOneWidget);
      expect(find.text('Pay ₹9 & Activate Membership'), findsOneWidget);
    });

    Future<void> openPaymentScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(createTestApp(
        const MembershipPaymentScreen(category: testCategory, isTripCreationFlow: true),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> applyCode(WidgetTester tester, String code) async {
      await tester.enterText(find.byType(TextField).first, code);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
    }

    Future<void> tapPay(WidgetTester tester, String label) async {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('paying without a code sends no coupon and never activates for free', (tester) async {
      await openPaymentScreen(tester);
      await tapPay(tester, 'Pay ₹9 & Activate Membership');

      final orders = api.posts.where((p) => p.$1 == '/membership/order').toList();
      expect(orders, hasLength(1));
      expect(orders.single.$2.containsKey('offerCode'), isFalse);
      expect(api.posts.any((p) => p.$1 == '/membership/activate-free'), isFalse);
      expect(api.posts.any((p) => (p.$2['offerCode'] ?? p.$2['couponCode']) == 'RIDERFREE'), isFalse);
    });

    for (final c in const [
      ('USEDCODE', "You've already used this code"),
      ('GROUPONLY', "This code isn't for this plan"),
      ('OLDCODE', 'Code expired'),
      ('NOSUCH', "We couldn't find that code"),
    ]) {
      testWidgets('a refused code (${c.$1}) shows "${c.$2}" and the rider can still pay the normal price', (tester) async {
        await openPaymentScreen(tester);
        await applyCode(tester, c.$1);

        expect(find.text(c.$2), findsOneWidget);
        expect(find.text('${c.$1} Applied!'), findsNothing);
        expect(find.text('Instant UPI Apps'), findsOneWidget);
        expect(find.text('Pay ₹9 & Activate Membership'), findsOneWidget);

        await tapPay(tester, 'Pay ₹9 & Activate Membership');
        final orders = api.posts.where((p) => p.$1 == '/membership/order').toList();
        expect(orders, hasLength(1));
        expect(orders.single.$2.containsKey('offerCode'), isFalse);
        expect(api.posts.any((p) => p.$1 == '/membership/activate-free'), isFalse);
      });
    }

    testWidgets('a partial code lowers the price and goes with the paid order', (tester) async {
      await openPaymentScreen(tester);
      await applyCode(tester, 'SAVE3');

      expect(find.text('SAVE3 Applied!'), findsOneWidget);
      expect(find.text('Pay ₹6 & Activate Membership'), findsOneWidget);
      await tapPay(tester, 'Pay ₹6 & Activate Membership');

      final orders = api.posts.where((p) => p.$1 == '/membership/order').toList();
      expect(orders.single.$2['offerCode'], 'SAVE3');
      expect(api.posts.any((p) => p.$1 == '/membership/activate-free'), isFalse);
    });

    testWidgets('₹0 activation happens only after the server confirms the code is free', (tester) async {
      await openPaymentScreen(tester);
      await applyCode(tester, 'RIDERFREE');
      await tapPay(tester, 'Activate Free Membership (₹0)');

      final free = api.posts.where((p) => p.$1 == '/membership/activate-free').toList();
      expect(free, hasLength(1));
      expect(free.single.$2['couponCode'], 'RIDERFREE');
      expect(find.text('Membership Activated!'), findsOneWidget);
    });

    testWidgets('a free code the server refuses at activation is removed and the normal price returns', (tester) async {
      await openPaymentScreen(tester);
      await applyCode(tester, 'ONCEONLY');
      expect(find.text('Activate Free Membership (₹0)'), findsOneWidget);

      await tapPay(tester, 'Activate Free Membership (₹0)');

      expect(
        find.text("You've already used this code. The code was removed, so you can pay the normal price."),
        findsOneWidget,
      );
      expect(find.text('ONCEONLY Applied!'), findsNothing);
      expect(find.text('Pay ₹9 & Activate Membership'), findsOneWidget);
      expect(find.text('Membership Activated!'), findsNothing);
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
