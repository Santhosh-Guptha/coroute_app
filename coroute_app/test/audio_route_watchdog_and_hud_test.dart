import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';

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


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();


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

}
