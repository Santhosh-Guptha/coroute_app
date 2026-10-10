import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/presentation/ride/guardian_sheet.dart';

class SessionApi extends ApiClient {
  SessionApi(http.Client superClient) : super(httpClient: superClient);
  String session = 'one';
  @override
  String get token => session;
  void switchAccount() {
    session = 'two';
    notifyListeners();
  }
}

void main() {
  Future<void> open(
    WidgetTester tester,
    ApiClient api, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<ApiClient>.value(
        value: api,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: GuardianSheet(groupId: 'g')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  http.Response json(Object value, [int status = 200]) =>
      http.Response(jsonEncode(value), status);

  testWidgets(
    'narrow large-text sheet requires acknowledgement and validates PIN locally',
    (tester) async {
      var creates = 0;
      final api = ApiClient(
        httpClient: MockClient((r) async {
          if (r.method == 'POST') {
            creates++;
            return json({
              'url': 'https://example.test/watch#token=x',
              'grantId': 'x',
              'status': 'ACTIVE',
            });
          }
          return json(
            r.url.path.contains('/consent/')
                ? {'allowed': false}
                : {'links': []},
          );
        }),
      );
      await open(tester, api, scale: 2);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('guardianPin')));
      await tester.enterText(find.byKey(const ValueKey('guardianPin')), 'abc');
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.ensureVisible(find.text('Create Guardian link'));
      await tester.tap(find.text('Create Guardian link'));
      await tester.pumpAndSettle();
      expect(creates, 0);
      expect(find.text('Use a PIN of 4 to 8 digits.'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('guardianPin')), '1234');
      await tester.ensureVisible(find.text('Create Guardian link'));
      await tester.tap(find.text('Create Guardian link'));
      await tester.pumpAndSettle();
      expect(creates, 1);
      expect(find.text('Share link'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'load failure can retry and failed consent does not change sharing',
    (tester) async {
      var fail = true;
      final api = ApiClient(
        httpClient: MockClient((r) async {
          if (fail || r.method == 'PATCH') {
            return json({'error': 'Unavailable'}, 503);
          }
          return json(
            r.url.path.contains('/consent/')
                ? {'allowed': false}
                : {'links': []},
          );
        }),
      );
      await open(tester, api);
      expect(find.text('Unavailable'), findsOneWidget);
      fail = false;
      await tester.ensureVisible(find.text('Refresh links'));
      await tester.tap(find.text('Refresh links'));
      await tester.pumpAndSettle();
      expect(find.text('Unavailable'), findsNothing);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false,
      );
      expect(find.text('Unavailable'), findsOneWidget);
    },
  );

  testWidgets('pause resume and revoke update links only after success', (
    tester,
  ) async {
    final methods = <String>[];
    final api = ApiClient(
      httpClient: MockClient((r) async {
        methods.add(r.method);
        return json(
          r.url.path.contains('/consent/')
              ? {'allowed': true}
              : {
                  'links': [
                    {
                      'grantId': 'x',
                      'subject': 'PERSONAL',
                      'level': 'LIVE',
                      'status': 'ACTIVE',
                    },
                  ],
                },
        );
      }),
    );
    await open(tester, api);
    for (final label in ['Pause access', 'Resume access', 'Revoke link']) {
      await tester.ensureVisible(find.byType(PopupMenuButton<String>));
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(methods.where((m) => m == 'PATCH').length, 2);
    expect(methods, contains('DELETE'));
    expect(find.textContaining('REVOKED'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });

  testWidgets('account switch discards delayed old-account links', (
    tester,
  ) async {
    final old = Completer<http.Response>();
    var linkCalls = 0;
    final api = SessionApi(
      MockClient((r) async {
        if (r.url.path.contains('/consent/')) return json({'allowed': false});
        if (++linkCalls == 1) return old.future;
        return json({'links': []});
      }),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ApiClient>.value(
        value: api,
        child: const MaterialApp(
          home: Scaffold(body: GuardianSheet(groupId: 'g')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    api.switchAccount();
    await tester.pump();
    await tester.pump();
    old.complete(
      json({
        'links': [
          {
            'subject': 'SECRET OLD ACCOUNT',
            'level': 'LIVE',
            'status': 'ACTIVE',
          },
        ],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('SECRET OLD ACCOUNT'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
