import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/presentation/widgets/intercom_dock.dart';
import 'package:coroute_app/data/services/settings_service.dart';

class _TestRt extends RealtimeService {
  final List<Map<String, dynamic>> sent = [];
  final List<Map<String, dynamic>> sentVoice = [];
  bool connected = true;
  String? testGroupId = 'c1';
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<VoicePacket> _voiceCtrl = StreamController<VoicePacket>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  @override
  Stream<VoicePacket> get voice => _voiceCtrl.stream;
  @override
  bool get isConnected => connected;
  @override
  String? get groupId => testGroupId;
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
  @override
  void sendVoice(int kind, Map<String, dynamic> header, [Uint8List? payload]) {
    sentVoice.add({'kind': kind, 'header': header, 'payload': payload});
  }

  void emit(Map<String, dynamic> m) => _ctrl.add(m);
  void emitVoice(VoicePacket p) => _voiceCtrl.add(p);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureGates.forceAllUnlocked = true;
  });

  tearDown(() {
    FeatureGates.forceAllUnlocked = false;
  });

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


  group('Live Audio VU Meter & Hardware PTT Mapping', () {
    test('audioLevel ValueNotifier updates and resets', () async {
      final rt = _TestRt();
      final ic = IntercomService(rt);
      expect(ic.audioLevel.value, equals(0.0));

      ic.updateAudioLevelForTesting(0.75);
      expect(ic.audioLevel.value, equals(0.75));

      await ic.reset();
      expect(ic.audioLevel.value, equals(0.0));
      ic.dispose();
    });

    test('Hardware keyboard PTT event handling', () async {
      final rt = _TestRt();
      final settings = SettingsService();
      final ic = IntercomService(rt, settings: settings);

      // 1. When hardwarePtt is false, events are not handled
      const volumeDownEvent = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.audioVolumeDown,
        logicalKey: LogicalKeyboardKey.audioVolumeDown,
        timeStamp: Duration.zero,
      );
      expect(ic.handleKeyEvent(volumeDownEvent), isFalse);

      // 2. Enable hardwarePtt
      await settings.setHardwarePtt(true);
      expect(settings.hardwarePtt, isTrue);

      // 3. When in convoy, VolumeDown KeyDown starts transmission
      final handledDown = ic.handleKeyEvent(volumeDownEvent);
      expect(handledDown, isTrue);

      // Key repeat is consumed
      const repeatEvent = KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.audioVolumeDown,
        logicalKey: LogicalKeyboardKey.audioVolumeDown,
        timeStamp: Duration.zero,
      );
      expect(ic.handleKeyEvent(repeatEvent), isTrue);

      // KeyUp ends transmission
      const volumeUpEvent = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.audioVolumeDown,
        logicalKey: LogicalKeyboardKey.audioVolumeDown,
        timeStamp: Duration.zero,
      );
      expect(ic.handleKeyEvent(volumeUpEvent), isTrue);

      // 4. Non-PTT key (e.g. keyA) is not intercepted
      const keyAEvent = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      );
      expect(ic.handleKeyEvent(keyAEvent), isFalse);

      // 5. When disconnected from convoy, events pass through
      rt.testGroupId = null;
      expect(ic.handleKeyEvent(volumeDownEvent), isFalse);
      rt.testGroupId = 'c1';

      // 6. In VOX mode, KeyDown toggles VOX state
      ic.setMode(IntercomMode.vox);
      final handledVox = ic.handleKeyEvent(volumeDownEvent);
      expect(handledVox, isTrue);

      ic.dispose();
    });

    testWidgets('IntercomOptions renders Handlebar / Headset PTT switch', (tester) async {
      final rt = _TestRt();
      final settings = SettingsService();
      final ic = IntercomService(rt, settings: settings);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<IntercomService>.value(value: ic),
              ChangeNotifierProvider<SettingsService>.value(value: settings),
            ],
            child: const Scaffold(
              body: IntercomOptions(),
            ),
          ),
        ),
      );

      expect(find.text('Remote or headset button'), findsOneWidget);
      expect(find.text('Disabled. Use on-screen talk button.'), findsOneWidget);

      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(settings.hardwarePtt, isTrue);
      expect(find.text('Volume down or headset button talks.'), findsOneWidget);

      ic.dispose();
    });
  });
}
