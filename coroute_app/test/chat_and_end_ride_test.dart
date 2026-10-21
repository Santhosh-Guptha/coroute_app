import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/ride/messages_sheet.dart';

class MockRt extends RealtimeService {
  MockRt({Set<String>? features}) : features = features ?? {'ack'};

  Set<String> features;
  bool _connected = true;
  final List<Map<String, dynamic>> sent = [];
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  @override
  bool get isConnected => _connected;
  @override
  RealtimeState get state => _connected ? RealtimeState.connected : RealtimeState.disconnected;
  @override
  Set<String> get serverFeatures => features;
  @override
  bool supports(String feature) => features.contains(feature);
  @override
  bool send(Map<String, dynamic> message) {
    if (!_connected) return false;
    sent.add(message);
    return true;
  }

  @override
  void connect(String token, {bool adminMode = false}) {}
  @override
  void disconnect() {}
  @override
  void joinRoom(String groupId, {String? prevExit, int? prevAliveAt}) {}
  @override
  void leaveRoom({bool leaveConvoy = false}) {}
  @override
  bool sendBye(String reason) => false;

  void emit(Map<String, dynamic> m) => _ctrl.add(m);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRt rt;
  late ConvoyService service;
  final me = RiderModel(userId: 'u1', name: 'Arjun', lat: 12.97, lng: 77.59, role: 'LEAD', lastSeenEpochMs: 1000000);
  final other = RiderModel(userId: 'u2', name: 'Rohan', lat: 12.98, lng: 77.60, role: 'PACK', lastSeenEpochMs: 1000000);

  final testConvoy = ConvoyModel(
    groupId: 'GRP-TEST',
    name: 'Bangalore Riders',
    joinCode: '123456',
    createdByUserId: 'u1',
    createdByUserName: 'Arjun',
    tripStatus: 'STARTED',
    createdAtEpochMs: 1000000,
    riders: {'u1': me, 'u2': other},
    messages: const [],
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    rt = MockRt();
    final client = MockClient((request) async {
      if (request.url.path.contains('/convoys/active')) {
        return http.Response(jsonEncode({'convoy': testConvoy.toJson()}), 200);
      }
      return http.Response('{}', 200);
    });
    final api = ApiClient(httpClient: client);
    final settings = SettingsService(prefs);
    final trips = TripStorageService(api);

    service = ConvoyService(
      api,
      rt,
      trips,
      settings: settings,
      clock: () => 1000000,
    );

    await service.startSession(token: 'test_token', userId: 'u1');
  });

  tearDown(() {
    service.dispose();
  });

  group('Chat Box and Group Messages', () {
    test('sendGroupMessage enqueues message with explicit groupId and sends via socket', () async {
      expect(service.activeGroupId, 'GRP-TEST');

      service.sendGroupMessage(
        groupId: 'GRP-TEST',
        senderId: 'u1',
        senderName: 'Arjun',
        text: 'Regroup at toll gate',
      );

      expect(rt.sent.any((m) => m['type'] == 'CHAT' && m['text'] == 'Regroup at toll gate'), isTrue);
    });

    testWidgets('MessagesView renders without overflow and allows typing and sending', (tester) async {
      AppTheme.use(AppPalette.dark);

      await tester.pumpWidget(
        ChangeNotifierProvider<ConvoyService>.value(
          value: service,
          child: MaterialApp(
            theme: AppTheme.themeFor(AppPalette.dark),
            home: Scaffold(
              body: MessagesView(convoyId: 'GRP-TEST', me: me),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('Messages'), findsNothing); // Sheet header is outside MessagesView
      expect(find.text('QUICK REPLIES'), findsOneWidget);
      expect(find.text('No messages yet.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      // Type a message into the chat box
      await tester.enterText(find.byType(TextField), 'Stopping for fuel ahead');
      await tester.pump();

      // Tap send button
      await tester.tap(find.byTooltip('Send message'));
      await tester.pump();

      // Text should be cleared
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, isEmpty);

      // Realtime service should have received the CHAT packet
      expect(rt.sent.any((m) => m['type'] == 'CHAT' && m['text'] == 'Stopping for fuel ahead'), isTrue);
    });
  });

  group('Admin Ending Ride Manually', () {
    test('When TRIP_STATUS with ENDED arrives, ConvoyService ends the ride and notifies listeners', () async {
      expect(service.activeGroupId, 'GRP-TEST');

      var notificationFired = false;
      service.addListener(() {
        notificationFired = true;
      });

      // Group admin ends ride manually -> server broadcasts TRIP_STATUS ENDED
      rt.emit({
        'type': 'TRIP_STATUS',
        'tripStatus': 'ENDED',
        'system': false,
        'ts': 1005000,
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(notificationFired, isTrue);
      expect(service.activeGroupId, isNull);
      expect(service.activeConvoy, isNull);
    });

    test('When DISSOLVED arrives, ConvoyService clears active convoy and notifies listeners', () async {
      expect(service.activeGroupId, 'GRP-TEST');

      var notificationFired = false;
      service.addListener(() {
        notificationFired = true;
      });

      rt.emit({
        'type': 'DISSOLVED',
        'reason': 'TRIP_ENDED',
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(notificationFired, isTrue);
      expect(service.activeGroupId, isNull);
      expect(service.activeConvoy, isNull);
    });
  });
}
