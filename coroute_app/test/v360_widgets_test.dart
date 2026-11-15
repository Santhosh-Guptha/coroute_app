import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/outbox_item.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/road_hazard_telemetry.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/chat_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/presentation/chat/chat_thread_screen.dart';
import 'package:coroute_app/presentation/home/join_waiting_screen.dart';
import 'package:coroute_app/presentation/rider/live_cockpit_map_screen.dart';
import 'package:coroute_app/presentation/rider/widgets/coroute_orbit_control.dart';
import 'package:coroute_app/presentation/rider/widgets/join_requests_card.dart';

class _MockWakelock extends WakelockPlusPlatformInterface {
  bool isEnabled = false;
  @override
  Future<void> toggle({required bool enable}) async => isEnabled = enable;
  @override
  Future<bool> get enabled async => isEnabled;
}

class _FakeAuthService extends ChangeNotifier implements AuthService {
  @override
  String? currentUserId = 'rider_me';
  @override
  String? currentUserName = 'Test Rider';
  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isGetter ? null : super.noSuchMethod(invocation);
}

class _FakeConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  String? activeGroupId = 'GRP-COCKPIT-1';
  @override
  ConvoyModel? activeConvoy;
  @override
  Map<String, ConvoyModel> allConvoys = {};
  @override
  String? myUserId = 'rider_me';
  @override
  bool canEditRoute = true;
  @override
  bool get canChangeGroupSettings => canEditRoute;
  @override
  bool get isSettingsOnlyTripHead => false;
  @override
  bool get canEndTrip => canEditRoute;
  @override
  bool isOnline = true;
  @override
  bool isRealGpsActive = true;
  @override
  String? lastError;
  @override
  double? get myFixAccuracyM => 5.0;
  @override
  bool get serverUnreachable => false;
  @override
  bool get serverBusy => false;
  @override
  bool get lastErrorIsServerBusy => false;
  @override
  bool get conservingBattery => false;
  @override
  bool get isLowBattery => false;
  @override
  bool get batterySaverActive => false;
  @override
  bool get leaveRequestedFromNotification => false;
  @override
  bool get sosRequestedFromNotification => false;
  @override
  int get p2pMeshPeerCount => 0;
  @override
  bool get pillionNeedsSeat => false;
  @override
  bool get supportsPillionSeat => false;
  @override
  bool Function()? rideMoving;
  @override
  int unreadChat(String gid) => 0;
  @override
  bool get supportsRideRoles => true;
  @override
  List<AssistRequest> get assistRequests => const [];
  @override
  List<AssistNotice> get assistNotices => const [];
  @override
  List<Encounter> get encounters => const [];
  @override
  List<HazardWarning> get hazards => const [];
  @override
  List<RoadHazardObservation> get roadHazards => const [];
  @override
  List<OutboxItem> get outbox => const [];
  @override
  AssistRequest? get activeAssist => null;
  @override
  PendingSos? get pendingSos => null;
  @override
  String? get sosOkNotice => null;
  @override
  String? get systemBroadcastMessage => null;
  @override
  bool supports(dynamic feature) => true;

  bool approved = false;
  ConvoyModel? joinedConvoy;
  @override
  PendingJoin? pendingJoin = const PendingJoin(groupId: 'grp_1', rideName: 'Weekend Ride');

  @override
  Future<ConvoyModel?> joinConvoyByCode({required String code, required RiderModel rider}) async {
    if (approved) {
      pendingJoin = null;
      return joinedConvoy;
    }
    return null;
  }

  @override
  void clearPendingJoin() {
    pendingJoin = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isGetter ? null : super.noSuchMethod(invocation);
}

class _FakeRealtimeService extends ChangeNotifier implements RealtimeService {
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  void emit(Map<String, dynamic> evt) => _ctrl.add(evt);
  @override
  void dispose() {
    _ctrl.close();
    super.dispose();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isGetter ? null : super.noSuchMethod(invocation);
}

class _FakeChatService extends ChangeNotifier implements ChatService {
  ChatMeta meta;
  List<ChatMessage> list = [];
  bool more = false;
  Completer<ChatMessage>? sendCompleter;

  _FakeChatService({required this.meta});

  final StreamController<ChatMessage> _inc = StreamController<ChatMessage>.broadcast();
  final StreamController<(String, String)> _del = StreamController<(String, String)>.broadcast();

  @override
  Stream<ChatMessage> get incoming => _inc.stream;
  @override
  Stream<(String, String)> get deleted => _del.stream;

  @override
  void setOpen(String? chatId) {}

  @override
  Future<(ChatMeta, List<ChatMessage>, bool)> messages(String chatId, {int? before}) async {
    return (meta, list, more);
  }

  @override
  String newClientId() => 'cid_test_1';

  @override
  Future<ChatMessage> send(String chatId, String text, {String? clientId}) {
    sendCompleter = Completer<ChatMessage>();
    return sendCompleter!.future;
  }

  @override
  void dispose() {
    _inc.close();
    _del.close();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => invocation.isGetter ? null : super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppTheme.use(AppPalette.dark);
    final mockWakelock = _MockWakelock();
    WakelockPlusPlatformInterface.instance = mockWakelock;
    wakelockPlusPlatformInstance = mockWakelock;
  });

  group('v3.60 widget tests', () {
    testWidgets('JoinWaitingScreen: pending -> approved pops true', (tester) async {
      final convoys = _FakeConvoyService();
      final realtime = _FakeRealtimeService();
      final rider = RiderModel(userId: 'u_me', name: 'Tester', lat: 12.9, lng: 77.5, speedKmh: 0, statusReason: '', lastSeenEpochMs: 0);
      final convoy = ConvoyModel(groupId: 'grp_1', name: 'Weekend Ride', joinCode: 'ABC123', tripStatus: 'STARTED', createdByUserId: 'u_host', createdByUserName: 'Host', createdAtEpochMs: 0, riders: {});
      convoys.joinedConvoy = convoy;

      bool? popResult;
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<ConvoyService>.value(value: convoys),
          ChangeNotifierProvider<RealtimeService?>.value(value: realtime),
        ],
        child: MaterialApp(
          home: Builder(builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                popResult = await JoinWaitingScreen.open(ctx, code: 'ABC123', rider: rider, rideName: 'Weekend Ride');
              },
              child: const Text('Open'),
            ),
          )),
        ),
      ));

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Waiting for the host'), findsOneWidget);
      expect(find.byKey(const Key('join_waiting_title')), findsOneWidget);

      // Approve and emit realtime event
      convoys.approved = true;
      realtime.emit({'type': 'JOIN_APPROVED'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(popResult, isTrue);
    });

    testWidgets('JoinRequestsCard: Let in calls approve', (tester) async {
      final decisions = <(String, bool)>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: JoinRequestsCard(
            pending: const {'u_anu': 'Anu', 'u_bob': 'Bob'},
            onDecide: (uid, approve) async => decisions.add((uid, approve)),
          ),
        ),
      ));

      expect(find.byKey(const Key('join_requests_card')), findsOneWidget);
      expect(find.text('2 riders want to join'), findsOneWidget);
      expect(find.text('Anu'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);

      await tester.tap(find.byKey(const Key('join_approve_u_anu')));
      await tester.pump();
      expect(decisions, [('u_anu', true)]);

      await tester.tap(find.byKey(const Key('join_decline_u_bob')));
      await tester.pump();
      expect(decisions, [('u_anu', true), ('u_bob', false)]);
    });

    testWidgets('ChatThreadScreen: send shows a pending bubble, then the sent one', (tester) async {
      final metaOpen = const ChatMeta(chatId: 'c_active', kind: 'dm', title: 'Anu', canSend: true);
      final chatService = _FakeChatService(meta: metaOpen);

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<ChatService?>.value(value: chatService),
          ChangeNotifierProvider<ApiClient>.value(value: ApiClient()),
        ],
        child: const MaterialApp(
          home: ChatThreadScreen(chatId: 'c_active', title: 'Anu'),
        ),
      ));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('chat_input')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('chat_input')), 'Heading to the start point');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat_send')));
      await tester.pump();

      expect(find.text('Heading to the start point'), findsOneWidget);
      expect(find.text('Sending…'), findsOneWidget);

      chatService.sendCompleter!.complete(ChatMessage(
        messageId: 'msg_101',
        chatId: 'c_active',
        text: 'Heading to the start point',
        at: 1700000000000,
        mine: true,
        clientId: 'cid_test_1',
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Sending…'), findsNothing);
    });

    testWidgets('ChatThreadScreen: closed chat shows the reason', (tester) async {
      final metaClosed = const ChatMeta(
        chatId: 'c_closed',
        kind: 'dm',
        title: 'Stranger',
        canSend: false,
        closedReason: 'NOT_FRIENDS',
      );
      final closedChatService = _FakeChatService(meta: metaClosed);

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<ChatService?>.value(value: closedChatService),
          ChangeNotifierProvider<ApiClient>.value(value: ApiClient()),
        ],
        child: const MaterialApp(
          home: ChatThreadScreen(key: Key('closed_thread'), chatId: 'c_closed', title: 'Stranger'),
        ),
      ));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('chat_closed')), findsOneWidget);
      expect(find.text('You can chat with friends only.'), findsOneWidget);
      expect(find.byKey(const Key('chat_input')), findsNothing);
    });

    testWidgets('cockpit map tap hides HUD and keeps the SOS button on screen', (tester) async {
      final auth = _FakeAuthService();
      final convoys = _FakeConvoyService();
      final me = RiderModel(userId: 'rider_me', name: 'Test Rider', lat: 17.4330, lng: 78.3782, speedKmh: 45.0, statusReason: '', lastSeenEpochMs: 0);
      final convoy = ConvoyModel(groupId: 'GRP-COCKPIT-1', name: 'Hyderabad Riders Club', joinCode: '456789', tripStatus: 'STARTED', createdByUserId: me.userId, createdByUserName: me.name, createdAtEpochMs: 0, riders: {me.userId: me});
      convoys.allConvoys[convoy.groupId] = convoy;
      convoys.activeConvoy = convoy;
      convoys.activeGroupId = convoy.groupId;

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<ApiClient>.value(value: ApiClient()),
          ChangeNotifierProvider<AuthService>.value(value: auth),
          ChangeNotifierProvider<ConvoyService>.value(value: convoys),
        ],
        child: const MaterialApp(
          home: LiveCockpitMapScreen(convoyId: 'GRP-COCKPIT-1'),
        ),
      ));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(RideSosButton), findsOneWidget);
      expect(find.byType(CorouteOrbitControl), findsOneWidget);

      // Tap on map: chrome is hidden, SOS stays
      await tester.tap(find.byType(FlutterMap));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(CorouteOrbitControl), findsNothing);
      expect(find.byType(RideSosButton), findsOneWidget);

      // Tap on map again: chrome is restored
      await tester.tap(find.byType(FlutterMap));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(CorouteOrbitControl), findsOneWidget);
      expect(find.byType(RideSosButton), findsOneWidget);
    });
  });
}
