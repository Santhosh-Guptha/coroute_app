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
import 'package:coroute_app/presentation/trip_planner/trip_review_sheet.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super();

  /// Every POST the screens made, in order: (path, body).
  final List<(String, Map)> posts = [];

  /// Every GET the screens made, in order.
  final List<String> gets = [];

  /// Coupon codes the gateway refuses, with the reason it gives (in the quote's `couponError`).
  static const refusals = {
    'USEDCODE': ('You have reached the redemption limit (1) for coupon USEDCODE', 'PER_USER_LIMIT_REACHED'),
    'GROUPONLY': ('Coupon GROUPONLY is only applicable to group_large', 'TIER_MISMATCH'),
    'OLDCODE': ('This coupon has expired', 'COUPON_EXPIRED'),
    'NOSUCH': ('Coupon NOSUCH does not exist', 'COUPON_NOT_FOUND'),
  };

  static const prices = {'group_small': (49, 'Small Group'), 'group_large': (99, 'Large Group')};

  /// The server quote: Large Group is an upgrade from a Small Group with 19 unused days (₹31 credit).
  Map<String, dynamic> quote(String plan, String coupon) {
    final (base, name) = prices[plan] ?? (49, 'Small Group');
    var discount = 0;
    Map<String, dynamic>? error;
    final refusal = refusals[coupon];
    if (refusal != null) {
      error = {'code': coupon, 'error': refusal.$1, 'reason': refusal.$2};
    } else if (coupon == 'RIDERFREE' || coupon == 'ONCEONLY') {
      discount = base;
    } else if (coupon == 'SAVE3') {
      discount = 3;
    } else if (coupon.isNotEmpty) {
      error = {'code': coupon, 'error': "We couldn't find that code", 'reason': 'COUPON_NOT_FOUND'};
    }
    final credit = plan == 'group_large' ? 31 : 0;
    final used = (base - discount) < credit ? (base - discount) : credit;
    final payable = base - discount - used;
    return {
      'plan': plan,
      'planName': name,
      'kind': credit > 0 ? 'upgrade' : 'new',
      'basePriceInr': base,
      'couponCode': discount > 0 ? coupon : null,
      'couponDiscountInr': discount,
      'creditInr': used,
      'unusedDays': credit > 0 ? 19 : 0,
      'payableInr': payable,
      'breakdown': [
        {'label': '$name (30 days)', 'amountInr': base},
        if (discount > 0) {'label': 'Coupon $coupon', 'amountInr': -discount},
        if (used > 0) {'label': 'Credit for 19 unused days of Small Group', 'amountInr': -used},
        {'label': 'To pay now', 'amountInr': payable},
      ],
      'summary': used > 0 ? '$name ₹$base − ₹$used credit for 19 unused days = ₹$payable' : '$name ₹$base = ₹$payable',
      'notes': [if (used > 0) 'Starts now and runs 30 days, until 5 Dec.'],
      'couponError': error,
    };
  }

  @override
  Future<dynamic> get(String path, {Duration timeout = const Duration(seconds: 10)}) async {
    gets.add(path);
    if (path == '/membership/catalog') {
      return {
        'categories': {
          'community': {'id': 'community', 'name': 'Community', 'monthlyPriceInr': 0, 'capacity': 1, 'purchasable': false},
          'group_small': {'id': 'group_small', 'name': 'Small Group', 'monthlyPriceInr': 49, 'capacity': 6},
          'group_large': {'id': 'group_large', 'name': 'Large Group', 'monthlyPriceInr': 99, 'capacity': 12},
        },
        'paymentsEnabled': true,
      };
    }
    if (path.startsWith('/membership/quote')) {
      final q = Uri.parse(path).queryParameters;
      return quote(q['plan'] ?? '', (q['coupon'] ?? '').toUpperCase());
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
      final code = m['offerCode']?.toString();
      // ONCEONLY was accepted in the quote, but the rider spent it meanwhile: the order refuses it.
      if (code == 'ONCEONLY') {
        throw const ApiException(400, "You've already used this code", null, 'PER_USER_LIMIT_REACHED');
      }
      if (code == 'RIDERFREE') {
        // ₹0: the server activates the plan itself (no payment opens).
        return {
          'orderId': 'mem_ord_free_1',
          'isFree': true,
          'amountInr': 0,
          'membership': {
            'membershipId': 'mem_free_123',
            'ownerUserId': 'user_tester',
            'category': m['category'],
            'categoryName': 'Small Group',
            'capacity': 6,
            'priceInr': 49,
            'status': 'ACTIVE',
            'validUntil': DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
          },
        };
      }
      // A paid order; payments are not configured in tests (no key), so checkout stops before Razorpay.
      final q = quote(m['category']?.toString() ?? '', code ?? '');
      return {
        'orderId': 'order_test_123',
        'keyId': '',
        'amountInPaise': (q['payableInr'] as int) * 100,
        'isFree': false,
      };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  // Stage 1 (the trip creation payment alert sheet) was retired: the app never opened it.

  group('Stage 2: Membership Payment Screen', () {
    const smallGroup = MembershipCategory(id: 'group_small', name: 'Small Group', priceRupees: 49, capacity: 6);
    const largeGroup = MembershipCategory(id: 'group_large', name: 'Large Group', priceRupees: 99, capacity: 12);

    Future<void> openPaymentScreen(WidgetTester tester, {MembershipCategory category = smallGroup}) async {
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(createTestApp(
        MembershipPaymentScreen(category: category, isTripCreationFlow: true),
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

    testWidgets('hides payment methods at ₹0, restores them when the coupon is removed', (tester) async {
      await openPaymentScreen(tester);

      // Starts with an empty coupon and the server price.
      expect(find.text('Membership Payment'), findsOneWidget);
      expect(find.text('Small Group'), findsOneWidget);
      expect(find.text('6 Riders Capacity · Monthly Subscription'), findsOneWidget);
      expect(find.text('PROMOTIONAL COUPON (OPTIONAL)'), findsOneWidget);
      expect(find.text('Enter coupon code'), findsOneWidget);
      expect(api.gets.any((g) => g.startsWith('/membership/quote?plan=group_small')), isTrue);
      expect(find.text('Instant UPI Apps'), findsOneWidget);
      expect(find.text('Cards & Net Banking'), findsOneWidget);
      expect(find.text('Pay ₹49 & Activate Membership'), findsOneWidget);

      await applyCode(tester, 'riderfree');

      expect(find.text('RIDERFREE Applied!'), findsOneWidget);
      expect(find.text('Instant UPI Apps'), findsNothing);
      expect(find.text('Cards & Net Banking'), findsNothing);
      expect(find.text('100% Free Activation'), findsOneWidget);
      expect(find.text('Activate Free Membership (₹0)'), findsOneWidget);

      await tester.tap(find.text('Remove Coupon'));
      await tester.pumpAndSettle();

      expect(find.text('₹49.00'), findsWidgets);
      expect(find.text('Instant UPI Apps'), findsOneWidget);
      expect(find.text('Pay ₹49 & Activate Membership'), findsOneWidget);
    });

    testWidgets('paying without a code sends no coupon and no amount: the server prices it', (tester) async {
      await openPaymentScreen(tester);
      await tapPay(tester, 'Pay ₹49 & Activate Membership');

      final orders = api.posts.where((p) => p.$1 == '/membership/order').toList();
      expect(orders, hasLength(1));
      expect(orders.single.$2.containsKey('offerCode'), isFalse);
      expect(orders.single.$2.containsKey('amount'), isFalse);
      expect(api.posts.any((p) => p.$1 == '/membership/activate-free'), isFalse);
    });

    for (final c in const [
      ('USEDCODE', "You've already used this code"),
      ('GROUPONLY', "This code isn't for this plan"),
      ('OLDCODE', 'Code expired'),
      ('NOSUCH', "We couldn't find that code"),
    ]) {
      testWidgets('a refused code (${c.$1}) shows "${c.$2}" under the field, is cleared, and Pay still works', (tester) async {
        await openPaymentScreen(tester);
        await applyCode(tester, c.$1);

        expect(find.text(c.$2), findsOneWidget);
        expect(find.text('${c.$1} Applied!'), findsNothing);
        expect(find.widgetWithText(TextField, c.$1), findsNothing, reason: 'the code is cleared');
        expect(find.text('Instant UPI Apps'), findsOneWidget);
        expect(find.text('Pay ₹49 & Activate Membership'), findsOneWidget);

        await tapPay(tester, 'Pay ₹49 & Activate Membership');
        final orders = api.posts.where((p) => p.$1 == '/membership/order').toList();
        expect(orders, hasLength(1));
        expect(orders.single.$2.containsKey('offerCode'), isFalse);
      });
    }

    testWidgets('a partial code lowers the price and goes with the paid order', (tester) async {
      await openPaymentScreen(tester);
      await applyCode(tester, 'SAVE3');

      expect(find.text('SAVE3 Applied!'), findsOneWidget);
      expect(find.text('−₹3.00'), findsOneWidget);
      expect(find.text('Pay ₹46 & Activate Membership'), findsOneWidget);
      await tapPay(tester, 'Pay ₹46 & Activate Membership');

      final orders = api.posts.where((p) => p.$1 == '/membership/order').toList();
      expect(orders.single.$2['offerCode'], 'SAVE3');
    });

    testWidgets('an upgrade shows the credit for unused days and the plain sentence', (tester) async {
      await openPaymentScreen(tester, category: largeGroup);

      expect(find.text('Credit for 19 unused days of Small Group'), findsOneWidget);
      expect(find.text('−₹31.00'), findsOneWidget);
      expect(find.text('Large Group ₹99 − ₹31 credit for 19 unused days = ₹68'), findsOneWidget);
      expect(find.text('Pay ₹68 & Activate Membership'), findsOneWidget);
    });

    testWidgets('₹0 goes through the order: the server activates it, no payment opens', (tester) async {
      await openPaymentScreen(tester);
      await applyCode(tester, 'RIDERFREE');
      await tapPay(tester, 'Activate Free Membership (₹0)');

      final orders = api.posts.where((p) => p.$1 == '/membership/order').toList();
      expect(orders, hasLength(1));
      expect(orders.single.$2['offerCode'], 'RIDERFREE');
      expect(api.posts.any((p) => p.$1 == '/membership/activate-free'), isFalse);
      expect(find.text('Membership Activated!'), findsOneWidget);
    });

    testWidgets('a code the order refuses is removed and the normal price returns', (tester) async {
      await openPaymentScreen(tester);
      await applyCode(tester, 'ONCEONLY');
      expect(find.text('Activate Free Membership (₹0)'), findsOneWidget);

      await tapPay(tester, 'Activate Free Membership (₹0)');

      expect(
        find.text("You've already used this code. The code was removed, so you can pay the normal price."),
        findsOneWidget,
      );
      expect(find.text('ONCEONLY Applied!'), findsNothing);
      expect(find.text('Pay ₹49 & Activate Membership'), findsOneWidget);
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
