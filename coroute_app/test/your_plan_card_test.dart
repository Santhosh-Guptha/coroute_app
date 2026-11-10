import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/membership_service.dart';
import 'package:coroute_app/domain/membership/plan_gate_messages.dart';
import 'package:coroute_app/domain/membership/plan_summary.dart';
import 'package:coroute_app/presentation/subscription/membership_dashboard_screen.dart';
import 'package:coroute_app/presentation/subscription/your_plan_card.dart';

/// Play payments policy (docs/features_355/play_payments_policy.md): the "Your plan" screen is
/// read-only account status. No price, no button or link to buy, change or extend a plan, and a
/// plan activated in the CoRoute account shows as soon as the service re-reads it.
class _FakeMembership extends MembershipService {
  _FakeMembership() : super(ApiClient());
  MyMembershipOverview? overview;
  MembershipCatalog? cat;
  int fetches = 0;

  @override
  MyMembershipOverview? get myOverview => overview;
  @override
  MembershipCatalog? get catalog => cat;
  @override
  PlanAccess get planAccess => overview?.planAccess ?? PlanAccess.community;
  @override
  bool get isLoading => false;
  @override
  Future<MembershipCatalog?> fetchCatalog() async => cat;
  @override
  Future<MyMembershipOverview?> fetchMyMembership() async {
    fetches++;
    return overview;
  }

  /// What the socket / push path does on SUBSCRIPTION_ACTIVATED: a new overview from the server.
  void serverSays(MyMembershipOverview o) {
    overview = o;
    notifyListeners();
  }
}

final _money = RegExp(r'₹|\bINR\b|\d+\s*/\s*mo|per month', caseSensitive: false);
final _buying = RegExp(r'\b(buy|upgrade|renew|purchase|checkout|coupon|discount|payment|pay|price|pricing|website)\b', caseSensitive: false);

/// Every text on screen, joined.
String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 10, 9);
  final dec12 = DateTime(2026, 12, 12, 20).millisecondsSinceEpoch;

  group('PlanSummary (pure)', () {
    test('Community: free line, what it includes, managed line, no date', () {
      final s = PlanSummary.from(const PlanFacts(source: 'community', category: 'community', name: 'Community'), now: now);
      expect(s.planName, 'Community');
      expect(s.status, 'Free');
      expect(s.dateLine, isNull);
      expect(s.note, communityFreeLine);
      expect(s.note, 'Solo riding and every safety feature are free.');
      expect(s.managedLine, 'Your plan is managed in your CoRoute account.');
      expect(s.includes, contains('Join any group ride for free'));
    });

    test('Small Group: riders per group, group features, end date', () {
      final s = PlanSummary.from(PlanFacts(source: 'membership', category: 'group_small', name: 'Small Group (2–6)', seats: 6, validUntil: dec12), now: now);
      expect(s.planName, 'Small Group');
      expect(s.status, 'Active');
      expect(s.dateLine, 'Ends on 12 Dec');
      expect(s.includes.first, 'Host group rides of up to 6 riders (you included)');
      expect(s.includes, contains('Talk, messages, invite code and regroup in your rides'));
      expect(s.note, isNull);
    });

    test('an ended plan reads as Community and names the plan that ended', () {
      final ended = DateTime(2026, 11, 3, 10).millisecondsSinceEpoch;
      final s = PlanSummary.from(PlanFacts(source: 'membership', category: 'group_large', seats: 12, validUntil: ended), now: now);
      expect(s.planName, 'Community');
      expect(s.dateLine, 'Your Large Group plan ended on 3 Nov');
      expect(s.note, communityFreeLine);
    });

    test('server feature lines with prices or buying words are dropped', () {
      final s = PlanSummary.from(
        PlanFacts(source: 'membership', category: 'group_large', seats: 12, validUntil: dec12, serverFeatures: const [
          'Up to 12 riders',
          'Only ₹99 / month',
          'Upgrade anytime',
          'Renew on our website',
          'Live convoy map',
        ]),
        now: now,
      );
      expect(s.includes, containsAll(['Up to 12 riders', 'Live convoy map']));
      for (final t in s.allText) {
        expect(_money.hasMatch(t), isFalse, reason: t);
        expect(_buying.hasMatch(t), isFalse, reason: t);
      }
    });

    test('no plan text ever has money or buying words', () {
      for (final f in [
        const PlanFacts(source: 'none', seats: 0),
        const PlanFacts(source: 'community', category: 'community'),
        PlanFacts(source: 'legacy', category: 'group_large', name: 'Road Captain', seats: 12, validUntil: dec12),
        PlanFacts(source: 'membership', category: 'individual', name: 'Individual', seats: 1, validUntil: dec12),
        const PlanFacts(source: 'community', ridesOnFriendsPlan: true),
      ]) {
        for (final t in PlanSummary.from(f, now: now).allText) {
          expect(_money.hasMatch(t) || _buying.hasMatch(t), isFalse, reason: t);
        }
      }
    });
  });

  group('PlanGateMessages (pure)', () {
    test('plan and capacity refusals are neutral, whatever the server wrote', () {
      expect(PlanGateMessages.neutral('MEMBERSHIP_EXPIRED', null, 'Active membership required. Please renew.'), 'Hosting a group ride needs a group plan.');
      expect(PlanGateMessages.neutral('CONVOY_FULL', null, 'This convoy is full (6 riders). Upgrade for more.'), 'This ride is full.');
      expect(PlanGateMessages.neutral(null, 'MEMBERSHIP_CAPACITY_EXCEEDED', 'x'), 'This ride is full.');
      expect(PlanGateMessages.neutral('SOLO_RIDE', null, 'x'), PlanGateMessages.soloRideFeatures);
      expect(PlanGateMessages.neutral('SOLO_TRIP_ONLY', null, 'x'), "This is a solo ride. Others can't join it.");
      expect(PlanGateMessages.neutral('OTHER', null, 'Buy Small Group for ₹49'), PlanGateMessages.notAvailable);
      expect(PlanGateMessages.neutral('OTHER', null, 'Ride not found.'), 'Ride not found.');
      for (final m in [
        PlanGateMessages.groupRidesNeedHost,
        PlanGateMessages.hostingNeedsGroupPlan,
        PlanGateMessages.rideFull,
        PlanGateMessages.soloRideNoJoin,
        PlanGateMessages.soloRideFeatures,
        PlanGateMessages.notAvailable,
      ]) {
        expect(_money.hasMatch(m) || _buying.hasMatch(m), isFalse, reason: m);
      }
    });
  });

  group('"Your plan" screen', () {
    late _FakeMembership ms;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ms = _FakeMembership();
      ms.cat = const MembershipCatalog(categories: [
        MembershipCategory(id: 'community', name: 'Community', capacity: 1, offered: false),
        MembershipCategory(id: 'group_small', name: 'Small Group', capacity: 6, features: ['Live convoy map']),
        MembershipCategory(id: 'group_large', name: 'Large Group', capacity: 12),
      ]);
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthService>.value(value: AuthService(ApiClient())),
          ChangeNotifierProvider<MembershipService>.value(value: ms),
        ],
        child: MaterialApp(theme: AppTheme.darkTheme, home: const MembershipDashboardScreen()),
      ));
      await tester.pumpAndSettle();
    }

    void expectNoBuyingUi(WidgetTester tester) {
      final card = find.byKey(const Key('your_plan_card'));
      expect(card, findsOneWidget);
      for (final type in [ElevatedButton, TextButton, OutlinedButton, FilledButton, IconButton, InkWell, GestureDetector]) {
        expect(find.descendant(of: card, matching: find.byType(type)), findsNothing, reason: 'no $type in the plan card');
      }
      final text = _allText(tester);
      expect(_money.hasMatch(text), isFalse, reason: text);
      expect(_buying.hasMatch(text), isFalse, reason: text);
      expect(find.text('Your plan is managed in your CoRoute account.'), findsOneWidget);
    }

    testWidgets('Community: title "Your plan", the free line, no buttons, no price', (tester) async {
      ms.overview = const MyMembershipOverview(plan: PlanAccess.community);
      await pump(tester);
      expect(find.text('Your plan'), findsOneWidget, reason: 'screen title');
      expect(find.byKey(const Key('your_plan_name')), findsOneWidget);
      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Solo riding and every safety feature are free.'), findsOneWidget);
      expectNoBuyingUi(tester);
      expect(find.textContaining('Small Group'), findsNothing, reason: 'no list of other plans');
      expect(find.textContaining('Large Group'), findsNothing);
    });

    testWidgets('owner of an active group plan: name, riders, end date; members below; no buying UI', (tester) async {
      final until = DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch;
      ms.overview = MyMembershipOverview(
        ownedMembership: UserMembership(
          membershipId: 'm1', ownerUserId: 'u1', category: 'group_small', categoryName: 'Small Group (2–6)',
          capacity: 6, status: 'ACTIVE', validUntil: until,
          members: [MembershipMember(userId: 'u2', name: 'Arjun', status: 'ACCEPTED', invitedAt: 1)],
        ),
        plan: PlanAccess(source: 'membership', category: 'group_small', name: 'Small Group (2–6)', seats: 6, validUntil: until),
      );
      await pump(tester);
      expect(find.text('Small Group'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.textContaining('Ends on '), findsOneWidget);
      expect(find.text('Host group rides of up to 6 riders (you included)'), findsOneWidget);
      expect(find.text('Live convoy map'), findsOneWidget, reason: 'what the server says the plan includes');
      expect(find.text('Riders on your plan'), findsOneWidget);
      expect(find.text('Arjun'), findsOneWidget);
      expectNoBuyingUi(tester);
    });

    testWidgets('a plan activated in the account shows at once (SUBSCRIPTION_ACTIVATED re-read)', (tester) async {
      ms.overview = const MyMembershipOverview(plan: PlanAccess.community);
      await pump(tester);
      expect(find.text('Community'), findsOneWidget);
      expect(ms.fetches, greaterThanOrEqualTo(1), reason: 'the screen re-reads the plan on open');

      ms.serverSays(MyMembershipOverview(
        plan: PlanAccess(source: 'membership', category: 'group_large', name: 'Large Group', seats: 12, validUntil: DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Large Group'), findsOneWidget);
      expect(find.text('Host group rides of up to 12 riders (you included)'), findsOneWidget);
      expectNoBuyingUi(tester);
    });

    testWidgets('the card alone has no buttons and no price text', (tester) async {
      final summary = PlanSummary.from(PlanFacts(source: 'membership', category: 'group_small', seats: 6, validUntil: dec12), now: now);
      await tester.pumpWidget(MaterialApp(theme: AppTheme.darkTheme, home: Scaffold(body: YourPlanCard(summary: summary))));
      expect(find.byType(ButtonStyleButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(InkWell), findsNothing);
      final text = _allText(tester);
      expect(_money.hasMatch(text), isFalse);
      expect(_buying.hasMatch(text), isFalse);
    });
  });
}
