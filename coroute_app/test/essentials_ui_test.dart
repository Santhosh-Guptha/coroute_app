import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/route_essentials_service.dart';
import 'package:coroute_app/data/models/route_essential.dart';
import 'package:coroute_app/presentation/ride/fuel_sheet.dart';
import 'package:coroute_app/presentation/ride/essentials_sheet.dart';

void main() {
  testWidgets('fuel profile sheet renders with large text on a narrow screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService(); await settings.load();
    tester.view.physicalSize = const Size(360, 740); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider.value(value: settings, child: MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
      home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showFuelSheet(context, configure: true), child: const Text('Open')))),
    )));
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    expect(find.text('Fuel profile'), findsOneWidget);
    expect(find.byKey(const ValueKey('shareFuelEstimate')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('shareFuelEstimate'))); await tester.pumpAndSettle();
    expect(settings.shareFuelEstimate, true);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('fuelLitresMode')), 150);
    expect(find.byKey(const ValueKey('fuelLitresMode')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink()); settings.dispose();
  });

  testWidgets('failed stop submission stays retryable; successful request disables it', (tester) async {
    final service = RouteEssentialsService(ApiClient(), load: () async => null, save: (_) async {});
    service.snapshot = EssentialsSnapshot(category: 'FUEL', routeKey: 'r', attribution: 'OpenStreetMap', fromM: 0, toM: 100000,
      fetchedAt: DateTime.now().millisecondsSinceEpoch, complete: true, stale: false, places: const [
        RouteEssential(placeId: 'p', visitId: 'v', name: 'Mapped pump', category: 'FUEL', source: 'OpenStreetMap', lat: 17, lng: 78,
          routePositionM: 12000, entryM: 11000, exitM: 13000, accessDistanceM: 1200, detourDistanceM: 400, detourDurationS: 120),
      ]);
    var accepted = false, attempts = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () =>
      showEssentialsSheet(context, service: service, leader: true, refresh: (_, _) async {}, addStop: (_) { attempts++; return accepted; }), child: const Text('Open'))))));
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add stop')); await tester.tap(find.text('Add stop')); await tester.pump();
    expect(attempts, 1); expect(find.text('Requested'), findsNothing);
    accepted = true; await tester.tap(find.text('Add stop')); await tester.pump();
    expect(attempts, 2); expect(find.text('Requested'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink()); service.dispose();
  });
}
