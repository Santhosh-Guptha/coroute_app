import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/services/audio_route_watchdog.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_intercom_hud_pill.dart';

class FakeRealtimeService extends RealtimeService {
  final StreamController<VoicePacket> _voiceCtrl = StreamController<VoicePacket>.broadcast();
  final StreamController<Map<String, dynamic>> _eventCtrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<VoicePacket> get voice => _voiceCtrl.stream;

  @override
  Stream<Map<String, dynamic>> get events => _eventCtrl.stream;

  @override
  bool get isConnected => true;

  @override
  String? get groupId => 'test_group_123';

  void emitVoice(VoicePacket packet) {
    _voiceCtrl.add(packet);
  }

  void emitEvent(Map<String, dynamic> event) {
    _eventCtrl.add(event);
  }

  @override
  void dispose() {
    _voiceCtrl.close();
    _eventCtrl.close();
    super.dispose();
  }
}

class FakeConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  ConvoyModel? activeConvoy;

  void setActiveConvoyForTest(ConvoyModel? convoy) {
    activeConvoy = convoy;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioRouteWatchdog Unit Tests', () {
    test('Initial healthy state has no routing issues', () async {
      final watchdog = AudioRouteWatchdog(
        initialBluetoothConnected: true,
        initialVolume: 0.8,
        bluetoothExpected: true,
      );

      final state = watchdog.state;
      expect(state.isBluetoothConnected, isTrue);
      expect(state.volumeLevel, 0.8);
      expect(state.isVolumeMuted, isFalse);
      expect(state.isAudioRoutingIssue, isFalse);
      expect(watchdog.healthNotifier.value, equals(state));
    });

    test('Bluetooth disconnection flags audio routing issue when expected', () async {
      final watchdog = AudioRouteWatchdog(
        initialBluetoothConnected: true,
        bluetoothExpected: true,
      );

      watchdog.onBluetoothStateChanged(false);

      expect(watchdog.isBluetoothConnected, isFalse);
      expect(watchdog.isAudioRoutingIssue, isTrue);
      expect(watchdog.healthNotifier.value.statusDescription, equals('HELMET_BLUETOOTH_DISCONNECTED'));

      // Tapping reconnect recovers Bluetooth
      final ok = await watchdog.attemptReconnectBluetooth();
      expect(ok, isTrue);
      expect(watchdog.isBluetoothConnected, isTrue);
      expect(watchdog.isAudioRoutingIssue, isFalse);
    });

    test('reconnectBluetooth() alias works identically to attemptReconnectBluetooth()', () async {
      final watchdog = AudioRouteWatchdog(
        initialBluetoothConnected: false,
        bluetoothExpected: true,
      );
      expect(watchdog.isAudioRoutingIssue, isTrue);

      final ok = await watchdog.reconnectBluetooth();
      expect(ok, isTrue);
      expect(watchdog.isBluetoothConnected, isTrue);
      expect(watchdog.isAudioRoutingIssue, isFalse);
    });

    test('Volume muted during active convoy flags audio routing issue', () async {
      final fakeConvoy = FakeConvoyService();
      final watchdog = AudioRouteWatchdog(
        convoyService: fakeConvoy,
        initialVolume: 1.0,
      );

      // Outside of active convoy, muted volume does not trigger emergency audio issue
      watchdog.onVolumeChanged(0.0);
      expect(watchdog.isVolumeMuted, isTrue);
      expect(watchdog.isAudioRoutingIssue, isFalse);

      // Now join an active convoy using mock ConvoyModel
      fakeConvoy.setActiveConvoyForTest(ConvoyModel(
        groupId: 'grp_1',
        name: 'Western Ghats',
        joinCode: '1234',
        createdByUserId: 'u1',
        createdByUserName: 'Lead',
        createdAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      ));

      // Active convoy + 0% volume = audio routing issue!
      expect(watchdog.isConvoyActive, isTrue);
      expect(watchdog.isAudioRoutingIssue, isTrue);
      expect(watchdog.healthNotifier.value.statusDescription, equals('INTERCOM_VOLUME_MUTED'));

      // boostIntercomVolume() resets volume to 100% and clears issue
      await watchdog.boostIntercomVolume();
      expect(watchdog.volumeLevel, equals(1.0));
      expect(watchdog.isVolumeMuted, isFalse);
      expect(watchdog.isAudioRoutingIssue, isFalse);
    });
  });

  group('IntercomService activeSpeakerNotifier and Tactile Haptics', () {
    late FakeRealtimeService fakeRt;
    late IntercomService intercomService;
    final List<String> hapticCalls = [];

    setUp(() {
      fakeRt = FakeRealtimeService();
      intercomService = IntercomService(fakeRt);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(call.arguments.toString());
        }
        return null;
      });
      hapticCalls.clear();
    });

    tearDown(() {
      intercomService.dispose();
      fakeRt.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('Incoming voice stream triggers heavyImpact haptic pulse and sets activeSpeakerNotifier', () async {
      expect(intercomService.activeSpeakerNotifier.value, isNull);

      final startPacket = VoicePacket(
        VoiceKind.start,
        {
          'streamId': 'stream_1',
          'from': 'rider_kiran',
          'fromName': 'Kiran',
          'rate': 16000,
        },
        Uint8List(0),
      );

      fakeRt.emitVoice(startPacket);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final speaker = intercomService.activeSpeakerNotifier.value;
      expect(speaker, isNotNull);
      expect(speaker!.speakerName, equals('Kiran'));
      expect(speaker.speakerId, equals('rider_kiran'));
      expect(speaker.isLead, isFalse);
      expect(speaker.isEmergency, isFalse);

      expect(hapticCalls, contains('HapticFeedbackType.heavyImpact'));
    });

    test('Road Captain voice stream triggers double buzz tactile pulse and marks isLead = true', () async {
      final leadStartPacket = VoicePacket(
        VoiceKind.start,
        {
          'streamId': 'stream_lead',
          'from': 'rider_captain',
          'fromName': 'Captain Vikram',
          'role': 'LEAD',
          'priority': true,
          'rate': 16000,
        },
        Uint8List(0),
      );

      fakeRt.emitVoice(leadStartPacket);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final speaker = intercomService.activeSpeakerNotifier.value;
      expect(speaker, isNotNull);
      expect(speaker!.speakerName, equals('Captain Vikram'));
      expect(speaker.isLead, isTrue);

      // Verify double buzz (at least 2 heavy impact calls)
      final impactCount = hapticCalls.where((c) => c.contains('heavyImpact')).length;
      expect(impactCount, greaterThanOrEqualTo(2));
    });

    test('VoiceKind.end immediately clears activeSpeakerNotifier', () async {
      fakeRt.emitVoice(VoicePacket(
        VoiceKind.start,
        {'streamId': 'stream_2', 'from': 'rider_2', 'fromName': 'Deepak', 'rate': 16000},
        Uint8List(0),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(intercomService.activeSpeakerNotifier.value?.speakerName, equals('Deepak'));

      fakeRt.emitVoice(VoicePacket(
        VoiceKind.end,
        {'streamId': 'stream_2', 'from': 'rider_2', 'fromName': 'Deepak', 'rate': 16000},
        Uint8List(0),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(intercomService.activeSpeakerNotifier.value, isNull);
    });
  });

  group('CockpitIntercomHudPill Widget Tests', () {
    testWidgets('Renders animated waveform pill when speaker is active', (tester) async {
      final watchdog = AudioRouteWatchdog();
      watchdog.onSpeakerActive(
        speakerId: 'u1',
        speakerName: 'Kiran',
        isLead: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitIntercomHudPill(watchdog: watchdog),
          ),
        ),
      );

      expect(find.text('Kiran speaking...'), findsOneWidget);
      expect(find.textContaining('🎙️'), findsOneWidget);
      expect(find.textContaining('▰'), findsOneWidget);
    });

    testWidgets('Renders Helmet Audio Disconnected warning with 1-tap reconnect', (tester) async {
      final watchdog = AudioRouteWatchdog(initialBluetoothConnected: true);
      watchdog.onBluetoothStateChanged(false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitIntercomHudPill(
              watchdog: watchdog,
            ),
          ),
        ),
      );

      expect(find.textContaining('HELMET AUDIO DISCONNECTED'), findsOneWidget);
      expect(find.text('RECONNECT'), findsOneWidget);

      await tester.tap(find.text('RECONNECT'));
      await tester.pumpAndSettle();

      expect(watchdog.isBluetoothConnected, isTrue);
    });

    testWidgets('Renders Intercom Muted (0%) warning with 1-tap volume boost', (tester) async {
      final watchdog = AudioRouteWatchdog(initialVolume: 1.0);
      watchdog.setMockVolumeMuted(true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitIntercomHudPill(
              watchdog: watchdog,
            ),
          ),
        ),
      );

      expect(find.textContaining('INTERCOM MUTED (0%)'), findsOneWidget);
      expect(find.text('BOOST'), findsOneWidget);

      await tester.tap(find.text('BOOST'));
      await tester.pumpAndSettle();

      expect(watchdog.isVolumeMuted, isFalse);
      expect(watchdog.volumeLevel, equals(1.0));
    });

    testWidgets('Returns SizedBox.shrink() when idle and healthy', (tester) async {
      final watchdog = AudioRouteWatchdog(initialBluetoothConnected: true, initialVolume: 1.0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitIntercomHudPill(watchdog: watchdog),
          ),
        ),
      );

      expect(find.byType(CockpitIntercomHudPill), findsOneWidget);
      expect(find.textContaining('speaking...'), findsNothing);
      expect(find.textContaining('DISCONNECTED'), findsNothing);
      expect(find.textContaining('MUTED'), findsNothing);
    });
  });
}
