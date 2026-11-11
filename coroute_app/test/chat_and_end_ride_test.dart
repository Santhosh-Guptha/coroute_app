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
  final bool _connected = true;
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

      expect(find.text('Chat'), findsNothing); // Sheet header is outside MessagesView
      expect(find.text('Fuel'), findsOneWidget); // one-tap quick actions
      expect(find.text('Regroup here'), findsOneWidget);
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

  group('3.55 ride chat', () {
    Map<String, dynamic> msg(String id, String from, String name, String text, {bool quick = false, String card = 'CUSTOM'}) => {
          'type': 'MESSAGE',
          'message': {'messageId': id, 'senderId': from, 'senderName': name, 'text': text, 'timestamp': 1000000, 'isQuickCard': quick, 'cardType': card},
        };

    Future<void> pumpView(WidgetTester tester, {bool? canType}) async {
      AppTheme.use(AppPalette.dark);
      await tester.pumpWidget(
        ChangeNotifierProvider<ConvoyService>.value(
          value: service,
          child: MaterialApp(
            theme: AppTheme.themeFor(AppPalette.dark),
            home: Scaffold(body: MessagesView(convoyId: 'GRP-TEST', me: me, canTypeOverride: canType)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('while moving: no text field, a short hint, quick actions send a quick card', (tester) async {
      await pumpView(tester, canType: false);
      expect(find.byType(TextField), findsNothing);
      expect(find.text(RideChatTexts.movingHint), findsOneWidget);
      await tester.tap(find.text('Fuel'));
      await tester.pump();
      final sent = rt.sent.where((m) => m['type'] == 'CHAT').toList();
      expect(sent, hasLength(1));
      expect(sent.single['text'], 'Fuel stop');
      expect(sent.single['isQuickCard'], isTrue);
      expect(sent.single['cardType'], 'FUEL');
      expect(find.text('Sent: Fuel'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('"Wait for me" is a wait request, not a chat line', (tester) async {
      await pumpView(tester, canType: false);
      await tester.tap(find.text('Wait for me'));
      await tester.pump();
      expect(rt.sent.any((m) => m['type'] == 'WAIT'), isTrue);
      expect(rt.sent.any((m) => m['type'] == 'CHAT'), isFalse);
      await tester.pump(const Duration(seconds: 5));
    });

    test('incoming quick card is spoken once ("Rohan: fuel stop"); unread counts until the chat is open', () async {
      final spoken = <String>[];
      service.speaker = (line, key) => spoken.add(line);
      rt.emit(msg('MSG-q1a', 'u2', 'Rohan', 'Fuel stop', quick: true, card: 'FUEL'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(spoken, ['Rohan: fuel stop']);
      expect(service.chatBanner, isNull, reason: 'quick cards are spoken, no banner');
      expect(service.unreadChat('GRP-TEST'), 1);
      service.setChatOpen('GRP-TEST');
      expect(service.unreadChat('GRP-TEST'), 0);
      service.setChatOpen(null);
      expect(service.unreadChat('GRP-TEST'), 0, reason: 'seen');
    });

    test('incoming text: banner and a short spoken line; my own lines are silent', () async {
      final spoken = <String>[];
      service.speaker = (line, key) => spoken.add(line);
      rt.emit(msg('MSG-t1b', 'u2', 'Rohan', 'Tea at the dhaba?'));
      rt.emit(msg('MSG-t1c', 'u1', 'Arjun', 'my own words'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(spoken, ['Rohan says: Tea at the dhaba?']);
      expect(service.chatBanner?.text, 'Tea at the dhaba?');
      service.dismissChatBanner();
      expect(service.chatBanner, isNull);
    });

    test('hidden rider: messages not shown, counted or spoken', () async {
      final spoken = <String>[];
      service.speaker = (line, key) => spoken.add(line);
      service.setChatHidden('u2', true);
      rt.emit(msg('MSG-h1d', 'u2', 'Rohan', 'spam spam'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(spoken, isEmpty);
      expect(service.visibleMessages('GRP-TEST'), isEmpty);
      expect(service.unreadChat('GRP-TEST'), 0);
      expect(service.allConvoys['GRP-TEST']!.messages, hasLength(1), reason: 'kept, only hidden here');
    });

    test('report sends CHAT_REPORT and hides the sender', () async {
      rt.emit(msg('MSG-r1e', 'u2', 'Rohan', 'bad words'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final m = service.allConvoys['GRP-TEST']!.messages.single;
      expect(service.reportChatMessage(m, hide: true), isTrue);
      expect(rt.sent.any((x) => x['type'] == 'CHAT_REPORT' && x['messageId'] == 'MSG-r1e'), isTrue);
      expect(service.chatHidden, contains('u2'));
    });

    test('quick action order is saved and applied', () {
      service.setQuickActionOrder(['arrived', 'fuel']);
      expect(service.quickActions.take(2).map((a) => a.id), ['arrived', 'fuel']);
      expect(service.quickActions, hasLength(8));
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
