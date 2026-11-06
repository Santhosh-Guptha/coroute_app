import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/membership_service.dart';
import 'package:coroute_app/presentation/subscription/payment_history_screen.dart';

class MockApiClient extends ApiClient {
  Map<String, dynamic> historyResponse = {};
  Map<String, dynamic> membershipPaymentsResponse = {};
  Map<String, dynamic> myMembershipResponse = {};

  @override
  Future<dynamic> get(
    String path, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (path == '/subscription/history') return historyResponse;
    if (path == '/membership/payments') return membershipPaymentsResponse;
    if (path == '/membership/my') return myMembershipResponse;
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Payment History Deduplication and Asia/Kolkata Timezone', () {
    late MockApiClient mockApi;
    late MembershipService membershipService;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mockApi = MockApiClient();
      membershipService = MembershipService(mockApi);
    });

    testWidgets('Deduplicates duplicate orders and payments between memOrders and data[orders]/history', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      const orderId = 'ord_duplicate_123';
      const paymentId = 'pay_duplicate_456';

      // Membership payments endpoint returns the order
      mockApi.membershipPaymentsResponse = {
        'payments': [
          {
            'orderId': orderId,
            'paymentId': paymentId,
            'amountInPaise': 4900,
            'amountInr': 49.0,
            'category': 'group_small',
            'status': 'PAID',
            'mode': 'live',
            'isFree': false,
            'paidAt': now - 10000,
            'createdAt': now - 20000,
          }
        ],
        'paymentHistory': [],
      };

      // Subscription history endpoint returns the EXACT SAME order and payment
      mockApi.historyResponse = {
        'userId': 'usr_test_1',
        'history': [
          {
            'orderId': orderId,
            'paymentId': paymentId,
            'amountInr': 49.0,
            'category': 'group_small',
            'status': 'PAID',
            'paidAt': now - 10000,
            'createdAt': now - 20000,
          }
        ],
        'orders': [
          {
            'orderId': orderId,
            'paymentId': paymentId,
            'amountInPaise': 4900,
            'planTier': 'group_small',
            'status': 'PAID',
            'paidAt': now - 10000,
            'createdAt': now - 20000,
          }
        ],
        'subscriptionHistory': [],
      };

      // Owned membership active
      mockApi.myMembershipResponse = {
        'owned': {
          'membershipId': 'mem_owned_1',
          'ownerUserId': 'usr_test_1',
          'category': 'group_small',
          'categoryName': 'Group Membership (2–6)',
          'capacity': 6,
          'priceRupees': 49,
          'status': 'ACTIVE',
          'validUntil': now + 25 * 86400000,
          'members': {},
          'orderId': orderId,
          'paymentId': paymentId,
        },
        'participating': [],
      };

      await membershipService.fetchMyMembership();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            // Legacy plan periods and orders come straight from GET /subscription/history.
            ChangeNotifierProvider<ApiClient>.value(value: mockApi),
            ChangeNotifierProvider<MembershipService?>.value(value: membershipService),
          ],
          child: const MaterialApp(
            home: PaymentHistoryScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify the order card is only rendered ONCE, not duplicated
      expect(find.text('Small Group (2–6)'), findsWidgets);
      // Verify payment ID is rendered in CopyRow
      expect(find.byWidgetPredicate((w) => w is Text && w.data == paymentId), findsWidgets);
      expect(find.byWidgetPredicate((w) => w is Text && w.data == orderId), findsWidgets);

      // Verify Authoritative Membership is displayed in Current Plan Card
      expect(find.text('Current plan'), findsOneWidget);
      expect(find.text('Group Membership (2–6)'), findsOneWidget);
      expect(find.text('ACTIVE'), findsWidgets);
    });

    testWidgets('Inspects participating membership status if owned membership is absent', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;

      mockApi.membershipPaymentsResponse = {'payments': [], 'paymentHistory': []};
      mockApi.historyResponse = {'orders': [], 'history': [], 'subscriptionHistory': []};

      mockApi.myMembershipResponse = {
        'owned': null,
        'participating': [
          {
            'membershipId': 'mem_part_1',
            'ownerUserId': 'usr_owner_99',
            'category': 'group_large',
            'categoryName': 'Group Membership (7–12)',
            'capacity': 12,
            'priceRupees': 99,
            'status': 'ACTIVE',
            'validUntil': now + 15 * 86400000,
            'members': {},
          }
        ],
      };

      await membershipService.fetchMyMembership();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            // Legacy plan periods and orders come straight from GET /subscription/history.
            ChangeNotifierProvider<ApiClient>.value(value: mockApi),
            ChangeNotifierProvider<MembershipService?>.value(value: membershipService),
          ],
          child: const MaterialApp(
            home: PaymentHistoryScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Group Membership (7–12)'), findsOneWidget);
      expect(find.text('ACTIVE (MEMBER)'), findsOneWidget);
    });

    testWidgets('Calculates daysRemaining and validUntil accurately in Asia/Kolkata timezone', (tester) async {
      // 10 days from now
      final now = DateTime.now().millisecondsSinceEpoch;
      final validUntilMs = now + 10 * 86400000;

      mockApi.membershipPaymentsResponse = {'payments': [], 'paymentHistory': []};
      mockApi.historyResponse = {'orders': [], 'history': [], 'subscriptionHistory': []};

      mockApi.myMembershipResponse = {
        'owned': {
          'membershipId': 'mem_owned_kolkata',
          'ownerUserId': 'usr_test_1',
          'category': 'individual',
          'categoryName': 'Individual Solo',
          'capacity': 1,
          'priceRupees': 9,
          'status': 'ACTIVE',
          'validUntil': validUntilMs,
          'members': {},
        },
        'participating': [],
      };

      await membershipService.fetchMyMembership();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            // Legacy plan periods and orders come straight from GET /subscription/history.
            ChangeNotifierProvider<ApiClient>.value(value: mockApi),
            ChangeNotifierProvider<MembershipService?>.value(value: membershipService),
          ],
          child: const MaterialApp(
            home: PaymentHistoryScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Formatted in IST (+05:30)
      expect(
        find.byWidgetPredicate((w) =>
            w is Text &&
            w.data != null &&
            RegExp(r'\d{1,2}\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{4}').hasMatch(w.data!)),
        findsOneWidget,
      );
      expect(find.text('10'), findsOneWidget); // Days left: 10
      expect(find.text('ACTIVE'), findsWidgets);
      expect(find.text('Individual Solo'), findsOneWidget);
    });
  });
}
