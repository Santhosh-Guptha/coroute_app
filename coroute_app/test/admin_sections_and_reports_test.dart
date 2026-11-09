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
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/presentation/admin/admin_ride_reports.dart';
import 'package:coroute_app/presentation/admin/admin_ui.dart';
import 'package:coroute_app/presentation/admin/master_admin_dashboard.dart';

/// Admin console simplification (B2): nine top-level sections (3.55: Features) with short plain names, and the
/// public ride reports under Safety (list, conversation, dismiss / warn / suspend) against a fake API.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => AppTheme.use(AppPalette.dark));

  group('Admin sections', () {
    testWidgets('nine sections with short plain names; plans and devices are merged away', (tester) async {
      late List<AdminNavItem> nav;
      late List<AdminNavItem> withSignOut;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          nav = adminNavItems(context, AdminSection.dashboard);
          withSignOut = adminNavItems(context, AdminSection.safety, onSignOut: () {});
          return const SizedBox();
        }),
      ));
      expect(nav.map((n) => n.label).toList(), ['Overview', 'Riders', 'Rides', 'Safety', 'Payments', 'Reviews', 'Insights', 'Features', 'Settings']);
      expect(AdminSection.values.length, lessThanOrEqualTo(9));
      expect(AdminSection.values.length, nav.length);
      for (final n in nav) {
        expect(n.label.split(' ').length, lessThanOrEqualTo(2), reason: 'short label: ${n.label}');
      }
      expect(nav.where((n) => n.selected).single.label, 'Overview');
      expect(withSignOut.last.label, 'Sign out');
      expect(withSignOut.where((n) => n.selected).single.label, 'Safety');
    });
  });

  group('Public ride reports (Safety)', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> report({String status = 'OPEN', int suspendedUntil = 0}) => {
          'reportId': 'RPT-0A1B2C3D4E5F',
          'at': now - 3600000,
          'reporterId': 'u-meena',
          'reportedId': 'u-ravi',
          'reporterName': 'Meena',
          'reportedName': 'Ravi',
          'ref': 'PRQ-000000000001',
          'reason': 'ABUSE',
          'note': 'Kept messaging',
          'status': status,
          'reportedSuspendedUntil': suspendedUntil,
          'transcript': [
            {'from': 'REPORTED', 'quick': 'WHERE_TO', 'text': 'Heading to the lake?', 'at': now - 3700000},
            {'from': 'REPORTER', 'quick': 'CANT_HELP', 'text': '', 'at': now - 3650000},
          ],
        };

    late List<http.Request> calls;
    late List<Map<String, dynamic>> reports;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final client = MockClient((req) async {
        calls.add(req);
        final p = req.url.path;
        if (p.endsWith('/admin/public-ride/reports') && req.method == 'GET') {
          final status = req.url.queryParameters['status'];
          final rows = status == null ? reports : reports.where((r) => r['status'] == status).toList();
          return http.Response(jsonEncode({'reports': rows}), 200, headers: {'content-type': 'application/json'});
        }
        if (p.contains('/admin/public-ride/reports/') && req.method == 'PATCH') {
          final body = jsonDecode(req.body) as Map;
          for (final r in reports) {
            if (p.endsWith(r['reportId'] as String)) {
              r['status'] = body['status'];
              r['action'] = body['action'];
            }
          }
          return http.Response(jsonEncode({'ok': true}), 200, headers: {'content-type': 'application/json'});
        }
        if (p.contains('/admin/public-ride/users/') && p.endsWith('/suspension')) {
          final days = (jsonDecode(req.body) as Map)['days'] as int;
          return http.Response(jsonEncode({'ok': true, 'suspendedUntil': days == 0 ? 0 : now + days * 86400000}), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{}', 404);
      });
      await tester.pumpWidget(ChangeNotifierProvider<ApiClient>.value(
        value: ApiClient(httpClient: client),
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: AdminRideReportsSection())),
        ),
      ));
      await tester.pumpAndSettle();
    }

    List<http.Request> sent(String method, String pathPart) =>
        calls.where((r) => r.method == method && r.url.path.contains(pathPart)).toList();

    setUp(() {
      calls = [];
      reports = [report()];
    });

    testWidgets('lists open reports with the reported rider, reason and reporter', (tester) async {
      await pump(tester);
      expect(sent('GET', '/admin/public-ride/reports').single.url.queryParameters['status'], 'OPEN');
      expect(find.text('Public ride reports, open (1)'), findsOneWidget);
      expect(find.text('Ravi'), findsOneWidget);
      expect(find.textContaining('Abuse · reported by Meena'), findsOneWidget);
      expect(find.text('"Kept messaging"'), findsOneWidget);
    });

    testWidgets('empty state when nothing is open', (tester) async {
      reports = [];
      await pump(tester);
      expect(find.text('No open reports.'), findsOneWidget);
    });

    testWidgets('the report shows the conversation, the actions and a link to the rider', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Ravi'));
      await tester.pumpAndSettle();
      expect(find.textContaining('[Where to] Heading to the lake?', findRichText: true), findsOneWidget);
      expect(find.textContaining("[Cant help]", findRichText: true), findsOneWidget);
      for (final label in ['Dismiss', 'Warn', 'Suspend 7 days', 'Suspend 30 days', 'Open rider details']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('dismiss marks the report reviewed and reloads the list', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Ravi'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Dismiss'));
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      final patch = sent('PATCH', '/admin/public-ride/reports/RPT-0A1B2C3D4E5F').single;
      expect(jsonDecode(patch.body), {'status': 'REVIEWED', 'action': 'DISMISS'});
      expect(sent('GET', '/admin/public-ride/reports').length, 2, reason: 'reloaded');
      expect(find.text('No open reports.'), findsOneWidget);
    });

    testWidgets('warn asks first, then records the warning', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Ravi'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Warn'));
      await tester.tap(find.text('Warn'));
      await tester.pumpAndSettle();
      expect(find.text('Warn Ravi'), findsOneWidget);
      expect(sent('PATCH', '/admin/public-ride/reports/'), isEmpty, reason: 'nothing before the confirmation');
      await tester.tap(find.byKey(const ValueKey('warnUseGuidelines')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('warnSend')));
      await tester.pumpAndSettle();
      expect(jsonDecode(sent('PATCH', '/admin/public-ride/reports/RPT-0A1B2C3D4E5F').single.body), {
        'status': 'ACTIONED',
        'action': 'WARN',
        'message': AdminWarnText.guidelines,
      });
    });

    testWidgets('suspend 7 days suspends public ride and closes the report', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Ravi'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Suspend 7 days'));
      await tester.tap(find.text('Suspend 7 days'));
      await tester.pumpAndSettle();
      expect(find.text('Suspend public ride for 7 days?'), findsOneWidget);
      await tester.tap(find.text('Suspend 7 days').last);
      await tester.pumpAndSettle();
      final post = sent('POST', '/admin/public-ride/users/u-ravi/suspension').single;
      expect(jsonDecode(post.body), {'days': 7});
      expect(jsonDecode(sent('PATCH', '/admin/public-ride/reports/RPT-0A1B2C3D4E5F').single.body), {'status': 'ACTIONED', 'action': 'SUSPEND', 'days': 7});
    });

    testWidgets('a handled report shows its outcome and can lift a suspension', (tester) async {
      reports = [report(status: 'ACTIONED', suspendedUntil: now + 5 * 86400000)..['action'] = 'SUSPEND'..['actionDays'] = 7];
      await pump(tester);
      // The open filter hides it; "All" shows it.
      expect(find.text('No open reports.'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All').last);
      await tester.pumpAndSettle();
      expect(sent('GET', '/admin/public-ride/reports').last.url.queryParameters.containsKey('status'), isFalse);
      expect(find.text('Ravi'), findsOneWidget);
      expect(find.textContaining('Suspended until'), findsOneWidget);
      await tester.tap(find.text('Ravi'));
      await tester.pumpAndSettle();
      expect(find.text('Suspended 7 days'), findsOneWidget);
      expect(find.text('Dismiss'), findsNothing, reason: 'no actions on a handled report');
      await tester.ensureVisible(find.text('Lift suspension'));
      await tester.tap(find.text('Lift suspension'));
      await tester.pumpAndSettle();
      expect(jsonDecode(sent('POST', '/admin/public-ride/users/u-ravi/suspension').single.body), {'days': 0});
    });

    test('labels: reasons, outcomes and conversation lines', () {
      expect(adminReportReason('UNSAFE'), 'Unsafe riding');
      expect(adminReportReason('weird'), 'Other');
      expect(adminReportOutcome({'status': 'OPEN'}), '');
      expect(adminReportOutcome({'status': 'ACTIONED', 'action': 'WARN'}), 'Warned');
      expect(adminReportOutcome({'status': 'REVIEWED', 'action': 'DISMISS'}), 'Dismissed');
      expect(adminReportOutcome({'status': 'ACTIONED', 'action': 'SUSPEND', 'actionDays': 30}), 'Suspended 30 days');
      expect(adminReportLine({'quick': 'RIDE_SAFE', 'text': ''}), '[Ride safe]');
      expect(adminReportLine({'quick': '', 'text': 'hello'}), 'hello');
      expect(adminReportLine({'quick': 'HI', 'text': 'there'}), '[Hi] there');
    });
  });
}
