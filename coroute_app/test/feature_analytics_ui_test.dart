import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/presentation/admin/feature_analytics_view.dart';

class FakeApi extends ApiClient {
  final pending = Completer<dynamic>();
  @override
  Future<dynamic> get(
    String path, {
    Duration timeout = const Duration(seconds: 10),
  }) => pending.future;
}

class FakeRealtime extends RealtimeService {
  final feed = StreamController<Map<String, dynamic>>.broadcast();
  bool online = true;
  @override
  Stream<Map<String, dynamic>> get events => feed.stream;
  @override
  bool get isConnected => online;
  void disconnectForTest() {
    online = false;
    notifyListeners();
  }

  @override
  void dispose() {
    feed.close();
    super.dispose();
  }
}

Map<String, dynamic> sample(int count) => {
  'generatedAt': DateTime.now().millisecondsSinceEpoch,
  'features': [
    {
      'feature': 'essentials',
      'measured': true,
      'requests': count,
      'succeeded': count,
      'failed': 0,
      'averageMs': 20,
    },
  ],
};
void main() {
  testWidgets(
    'live fleet wins over late REST, disconnect marks stale, and timers dispose',
    (tester) async {
      final api = FakeApi(), rt = FakeRealtime();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ApiClient>.value(value: api),
            ChangeNotifierProvider<RealtimeService>.value(value: rt),
          ],
          child: const MaterialApp(
            home: Scaffold(body: FeatureAnalyticsView()),
          ),
        ),
      );
      expect(find.text('Waiting for live ride data'), findsOneWidget);
      rt.feed.add({
        'type': 'FLEET',
        'featureAnalytics': sample(7),
        'convoys': [],
      });
      await tester.pump();
      expect(find.text('Live feature analytics'), findsOneWidget);
      api.pending.complete(sample(1));
      await tester.pump();
      expect(find.textContaining('7 operations'), findsOneWidget);
      expect(find.textContaining('1 operations'), findsNothing);
      rt.disconnectForTest();
      await tester.pump();
      expect(find.text('Analytics stale or offline'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      rt.feed.add({'type': 'FLEET', 'featureAnalytics': sample(8)});
      await tester.pump(const Duration(seconds: 20));
      expect(tester.takeException(), isNull);
      api.dispose();
      rt.dispose();
    },
  );
  testWidgets('permission failure has no false live or empty-fleet claim', (
    tester,
  ) async {
    final api = FakeApi();
    await tester.pumpWidget(
      ChangeNotifierProvider<ApiClient>.value(
        value: api,
        child: const MaterialApp(home: Scaffold(body: FeatureAnalyticsView())),
      ),
    );
    api.pending.completeError(const ApiException(403, 'Forbidden'));
    await tester.pump();
    expect(
      find.text('Analytics unavailable. Retry when connected.'),
      findsOneWidget,
    );
    expect(find.text('Live rides (0)'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });
}
