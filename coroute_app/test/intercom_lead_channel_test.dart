import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/presentation/ride/riders_ladder.dart';
import 'package:coroute_app/presentation/widgets/intercom_dock.dart';

class _TestRt extends RealtimeService {
  final List<Map<String, dynamic>> sent = [];
  bool connected = true;
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<VoicePacket> _voiceCtrl = StreamController<VoicePacket>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  @override
  Stream<VoicePacket> get voice => _voiceCtrl.stream;
  @override
  bool get isConnected => connected;
  @override
  RealtimeState get state => connected ? RealtimeState.connected : RealtimeState.disconnected;
  @override
  bool supports(String feature) => true;
  @override
  bool send(Map<String, dynamic> message) {
    if (!connected) return false;
    sent.add(message);
    return true;
  }

  void emit(Map<String, dynamic> m) => _ctrl.add(m);
  void emitVoice(VoicePacket p) => _voiceCtrl.add(p);
}

void main() {
  group('RiderModel mic state & voice telemetry', () {
    test('serializes and deserializes micMuted and isSpeaking', () {
      final rider = RiderModel(
        userId: 'u1',
        name: 'Alex',
        lat: 12.9,
        lng: 77.5,
        lastSeenEpochMs: 1000,
        micMuted: true,
        isSpeaking: true,
      );

      final json = rider.toJson();
      expect(json['micMuted'], isTrue);
      expect(json['isSpeaking'], isTrue);

      final decoded = RiderModel.fromJson(json);
      expect(decoded.micMuted, isTrue);
      expect(decoded.isSpeaking, isTrue);

      final updated = decoded.copyWith(micMuted: false, isSpeaking: false);
      expect(updated.micMuted, isFalse);
      expect(updated.isSpeaking, isFalse);
    });
  });

  group('IntercomService Lead-Only Channel & Mic State', () {
    test('channel selection and mic muting signaling', () async {
      final rt = _TestRt();
      final ic = IntercomService(rt);
      expect(ic.channel, equals(IntercomChannel.all));

      // Switch to lead channel
      ic.setChannel(IntercomChannel.leadOnly);
      expect(ic.channel, equals(IntercomChannel.leadOnly));

      // Mute mic sends MIC_STATE
      ic.setMicMuted(true);
      expect(ic.isMicMuted, isTrue);
      expect(rt.sent.any((m) => m['type'] == 'MIC_STATE' && m['muted'] == true), isTrue);

      // Unmute sends MIC_STATE false
      ic.setMicMuted(false);
      expect(ic.isMicMuted, isFalse);
      expect(rt.sent.any((m) => m['type'] == 'MIC_STATE' && m['muted'] == false), isTrue);

      // Receiving MIC_STATUS updates per-rider state
      rt.emit({
        'type': 'MIC_STATUS',
        'userId': 'rider2',
        'micMuted': true,
        'isSpeaking': false,
      });
      await pumpEventQueue();
      expect(ic.isRiderMuted('rider2'), isTrue);
      expect(ic.isRiderSpeaking('rider2'), isFalse);

      rt.emit({
        'type': 'MIC_STATUS',
        'userId': 'rider2',
        'isSpeaking': true,
      });
      await pumpEventQueue();
      expect(ic.isRiderSpeaking('rider2'), isTrue);
    });

    test('receiving Lead-Only voice stream sets active channel', () async {
      final rt = _TestRt();
      final ic = IntercomService(rt);

      final startPacket = VoicePacket(
        VoiceKind.start,
        {
          'streamId': 'str123',
          'from': 'leader_1',
          'fromName': 'Lead Rider',
          'channel': 'LEAD_ONLY',
          'sampleRate': 16000,
        },
        Uint8List(0),
      );

      rt.emitVoice(startPacket);
      await pumpEventQueue();

      expect(ic.isReceiving, isTrue);
      expect(ic.activeSpeakerName, equals('Lead Rider'));
      expect(ic.activeChannel, equals(IntercomChannel.leadOnly));
      expect(ic.isReceivingLeadOnly, isTrue);
      expect(ic.isRiderSpeaking('leader_1'), isTrue);
    });
  });

  group('ConvoyService updates rider model on MIC_STATUS', () {
    test('updates rider micMuted and isSpeaking in convoy model', () async {
      final rt = _TestRt();
      final api = ApiClient();
      final trips = TripStorageService(api);
      final cs = ConvoyService(api, rt, trips);

      final initialConvoy = ConvoyModel(
        groupId: 'c1',
        name: 'Western Ghats Ride',
        joinCode: 'WG123',
        createdByUserId: 'r1',
        createdByUserName: 'Sam',
        createdAtEpochMs: 1000,
        riders: {
          'r1': RiderModel(
            userId: 'r1',
            name: 'Sam',
            lat: 12.9,
            lng: 77.5,
            lastSeenEpochMs: 1000,
            micMuted: false,
            isSpeaking: false,
          ),
        },
      );

      cs.setActiveConvoyForTesting(initialConvoy);

      final convoy = cs.allConvoys['c1'];
      expect(convoy, isNotNull);
      expect(convoy!.riders['r1']!.micMuted, isFalse);
      expect(convoy.riders['r1']!.isSpeaking, isFalse);

      // Send MIC_STATUS
      rt.emit({
        'type': 'MIC_STATUS',
        'userId': 'r1',
        'micMuted': true,
        'isSpeaking': true,
      });
      await pumpEventQueue();

      final updatedConvoy = cs.allConvoys['c1']!;
      expect(updatedConvoy.riders['r1']!.micMuted, isTrue);
      expect(updatedConvoy.riders['r1']!.isSpeaking, isTrue);
    });
  });

  group('UI: IntercomDock & RidersLadder widgets', () {
    testWidgets('IntercomDock renders Lead-Only channel selector for convoy lead', (tester) async {
      final rt = _TestRt();
      final ic = IntercomService(rt);

      final meLeader = RiderModel(
        userId: 'me',
        name: 'Lead Captain',
        lat: 12.9,
        lng: 77.5,
        lastSeenEpochMs: 1000,
        role: 'LEAD',
      );

      final otherRider = RiderModel(
        userId: 'u2',
        name: 'Bob',
        lat: 12.91,
        lng: 77.51,
        lastSeenEpochMs: 1000,
        role: 'PACK',
      );

      final convoy = ConvoyModel(
        groupId: 'c1',
        name: 'Ghats Ride',
        joinCode: '123456',
        createdByUserId: 'me',
        createdByUserName: 'Lead Captain',
        createdAtEpochMs: 1000,
        riders: {'me': meLeader, 'u2': otherRider},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: ChangeNotifierProvider<IntercomService>.value(
            value: ic,
            child: Scaffold(
              body: IntercomDock(convoy: convoy, me: meLeader),
            ),
          ),
        ),
      );

      // Verify channel segment selector is visible for LEAD
      expect(find.text('All Convoy'), findsOneWidget);
      expect(find.text('Lead & Sweeper'), findsOneWidget);

      // Tap Lead & Sweeper
      await tester.tap(find.text('Lead & Sweeper'));
      await tester.pumpAndSettle();
      expect(ic.channel, equals(IntercomChannel.leadOnly));
      expect(find.text('LEAD & SWEEPER TALK'), findsOneWidget);
    });

    testWidgets('RidersLadder shows SpeakingChip and MicMutedChip', (tester) async {
      final rt = _TestRt();
      final ic = IntercomService(rt);

      final speakingRider = RiderModel(
        userId: 'u1',
        name: 'Speaker Sam',
        lat: 12.9,
        lng: 77.5,
        lastSeenEpochMs: 1000,
        isSpeaking: true,
      );

      final mutedRider = RiderModel(
        userId: 'u2',
        name: 'Muted Max',
        lat: 12.91,
        lng: 77.51,
        lastSeenEpochMs: 1000,
        micMuted: true,
      );

      final rungs = [
        LadderRung(rider: speakingRider, isMe: false),
        LadderRung(rider: mutedRider, isMe: false),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: ChangeNotifierProvider<IntercomService>.value(
            value: ic,
            child: Scaffold(
              body: SingleChildScrollView(
                child: RidersLadder(
                  rungs: rungs,
                  colors: const {'u1': Colors.teal, 'u2': Colors.blue},
                  statuses: const {'u1': RiderStatus.riding, 'u2': RiderStatus.riding},
                  nowMs: 1000,
                  onTap: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SpeakingChip), findsOneWidget);
      expect(find.text('Talking'), findsOneWidget);
      expect(find.byType(MicMutedChip), findsOneWidget);
      expect(find.text('Muted'), findsOneWidget);
    });
  });
}
