import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:coroute_app/presentation/widgets/emergency_sos_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sos = PendingSos(clientId: 'usr_a-1700000000000', groupId: 'GRP-1', lat: 12.97, lng: 77.59, type: 'CRASH_OR_EMERGENCY', createdAt: 1700000000000);

  group('Pending SOS', () {
    test('round-trips through its stored form', () {
      final back = PendingSos.decode(sos.encode());
      expect(back, isNotNull);
      expect(back!.clientId, sos.clientId);
      expect(back.groupId, 'GRP-1');
      expect(back.lat, 12.97);
      expect(back.type, 'CRASH_OR_EMERGENCY');
      expect(back.toMessage()['clientId'], sos.clientId);
      expect(back.toMessage()['type'], 'SOS');
    });

    test('bad stored data is ignored', () {
      expect(PendingSos.decode(null), isNull);
      expect(PendingSos.decode('not json'), isNull);
      expect(PendingSos.decode('{"groupId":"GRP-1"}'), isNull);
    });

    test('only the echo with the same clientId confirms it', () {
      final echo = SosAlertModel.fromJson({'alertId': 'SOS-1', 'userId': 'usr_a', 'clientId': sos.clientId, 'timestamp': 1});
      final other = SosAlertModel.fromJson({'alertId': 'SOS-2', 'userId': 'usr_a', 'timestamp': 1});
      expect(sos.matches(echo.clientId), isTrue);
      expect(sos.matches(other.clientId), isFalse);
      expect(sos.matches(null), isFalse);
    });

    test('a newer position keeps the same clientId', () {
      final moved = sos.copyWith(lat: 13.0);
      expect(moved.clientId, sos.clientId);
      expect(moved.lat, 13.0);
    });

    test('the store saves, loads and clears it', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await PendingSosStore.load(), isNull);
      await PendingSosStore.save(sos);
      expect((await PendingSosStore.load())?.clientId, sos.clientId);
      await PendingSosStore.clear();
      expect(await PendingSosStore.load(), isNull);
    });
  });

  group('Connection banner lines', () {
    test('offline with points and an SOS waiting', () {
      final l = ConnectionBanner.lines(connecting: false, pendingPoints: 42, sosWaiting: true);
      expect(l.first, startsWith('Offline'));
      expect(l, contains('42 points waiting to upload'));
      expect(l, contains('SOS waiting to send'));
    });

    test('nothing waiting: only the state line', () {
      expect(ConnectionBanner.lines(connecting: true, pendingPoints: 0, sosWaiting: false).length, 1);
      expect(ConnectionBanner.lines(connecting: true, pendingPoints: 1, sosWaiting: false)[1], '1 point waiting to upload');
    });
  });

  group('SOS sheet status', () {
    test('never says delivered before the server confirmed it', () {
      expect(EmergencySosSheet.statusFor(hasService: true, pending: true, online: true, hasOpenAlert: false), SosSheetStatus.sending);
      expect(EmergencySosSheet.statusFor(hasService: true, pending: true, online: false, hasOpenAlert: false), SosSheetStatus.waitingForSignal);
      expect(EmergencySosSheet.statusFor(hasService: true, pending: true, online: true, hasOpenAlert: true), SosSheetStatus.sending);
      expect(EmergencySosSheet.statusFor(hasService: true, pending: false, online: true, hasOpenAlert: true), SosSheetStatus.delivered);
      expect(EmergencySosSheet.statusFor(hasService: false, pending: false, online: false, hasOpenAlert: true), SosSheetStatus.unknown);
    });
  });

  group('SOS kept across a restart', () {
    late ApiClient api;
    late AuthService auth;
    late RealtimeService rt;
    late ConvoyService convoys;

    Future<void> setUpServices(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({AppConstants.keyPendingSos: sos.encode()});
      FlutterSecureStorage.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/charging'),
        (call) async => null,
      );
      await tester.runAsync(() async {
        api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
        auth = AuthService(api);
        rt = RealtimeService();
        convoys = ConvoyService(api, rt, TripStorageService(api));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
    }

    Future<void> tearDownServices(WidgetTester tester) async {
      await tester.runAsync(() async {
        convoys.dispose();
        rt.dispose();
      });
    }

    testWidgets('an SOS stored before the app closed is loaded again; offline, the sheet says it is waiting', (tester) async {
      await setUpServices(tester);
      expect(convoys.pendingSos?.clientId, sos.clientId);

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthService>.value(value: auth),
          ChangeNotifierProvider<ConvoyService>.value(value: convoys),
        ],
        child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: EmergencySosSheet(lat: 12.97, lng: 77.59)))),
      ));
      await tester.pump();

      expect(find.text('No signal. SOS not sent yet'), findsOneWidget);
      expect(find.textContaining('sent as soon as the phone is back online'), findsOneWidget);
      expect(find.textContaining('Delivered'), findsNothing);
      expect(find.textContaining('delivered'), findsNothing);

      // "I am safe" drops the waiting SOS from the phone and from disk.
      await tester.runAsync(() async {
        convoys.cancelMySos();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(convoys.pendingSos, isNull);
      await tester.runAsync(() async {
        expect(await PendingSosStore.load(), isNull);
      });
      await tearDownServices(tester);
    });
  });
}
