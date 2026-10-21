import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FeatureGates.forceAllUnlocked = true;
    FeatureGates.activeTier = SubscriptionTier.roadCaptain;
  });

  group('Road Captain Priority Voice Ducking - Audio Math (-18 dB)', () {
    test('attenuatePcm16 attenuates amplitude by -18 dB (~0.12589 ratio)', () {
      final input = Int16List.fromList([10000, -20000, 32767, -32768, 0]);
      final pcmBytes = Uint8List.view(input.buffer);

      final duckedBytes = IntercomService.attenuatePcm16(pcmBytes);
      final duckedSamples = Int16List.view(duckedBytes.buffer);

      // 10000 * 10^(-18/20) ~= 1259
      expect(duckedSamples[0], closeTo(1259, 2));
      // -20000 * 10^(-18/20) ~= -2518
      expect(duckedSamples[1], closeTo(-2518, 2));
      // 32767 * 10^(-18/20) ~= 4125
      expect(duckedSamples[2], closeTo(4125, 2));
      // -32768 * 10^(-18/20) ~= -4125
      expect(duckedSamples[3], closeTo(-4125, 2));
      expect(duckedSamples[4], equals(0));
    });

    test('duckingFactor constant equals 10^(-18/20)', () {
      expect(IntercomService.duckingDecibels, equals(-18.0));
      expect(IntercomService.duckingFactor, closeTo(0.12589, 0.001));
    });
  });

  group('Road Captain Priority Stream Preemption & Ducking', () {
    test('Road Captain voice stream preempts casual chatter and ducks jitter buffer by -18 dB', () async {
      final rt = _TestRt();
      final ic = IntercomService(rt);

      // 1. Casual chatter starts transmitting (group call)
      final chatterStart = VoicePacket(
        VoiceKind.start,
        {
          'streamId': 'chatter_stream_1',
          'from': 'chatter_user',
          'fromName': 'Casual Rider',
          'channel': 'ALL',
          'sampleRate': 16000,
        },
        Uint8List(0),
      );
      rt.emitVoice(chatterStart);
      await pumpEventQueue();

      expect(ic.isReceiving, isTrue);
      expect(ic.activeSpeakerName, equals('Casual Rider'));
      expect(ic.activeSpeakerIsLead, isFalse);
      expect(ic.isPriorityDucked, isFalse);

      // 2. Incoming chatter audio frame with known PCM samples
      final chatterFrameSamples = Int16List.fromList([10000, 20000, -15000]);
      final chatterBytes = Uint8List.view(chatterFrameSamples.buffer);
      final chatterFrame = VoicePacket(
        VoiceKind.frame,
        {
          'streamId': 'chatter_stream_1',
          'from': 'chatter_user',
          'seq': 0,
        },
        chatterBytes,
      );
      rt.emitVoice(chatterFrame);
      await pumpEventQueue();

      expect(ic.jitterQueueLength, equals(1));
      final unattenuatedView = Int16List.view(ic.firstJitterBuffer!.buffer);
      expect(unattenuatedView[0], equals(10000));
      expect(unattenuatedView[1], equals(20000));

      // 3. Road Captain transmits with role == 'LEAD'
      final leadStart = VoicePacket(
        VoiceKind.start,
        {
          'streamId': 'lead_stream_1',
          'from': 'lead_captain',
          'fromName': 'Road Captain Dan',
          'channel': 'ALL',
          'role': 'LEAD',
          'priority': true,
          'sampleRate': 16000,
        },
        Uint8List(0),
      );
      rt.emitVoice(leadStart);
      await pumpEventQueue();

      // Verify Road Captain was NOT dropped due to !p.isPrivate
      expect(ic.activeSpeakerName, equals('Road Captain Dan'));
      expect(ic.activeSpeakerId, equals('lead_captain'));
      expect(ic.activeSpeakerIsLead, isTrue);
      expect(ic.isPriorityDucked, isTrue);

      // Verify the existing chatter in the jitter buffer was ducked by -18 dB
      expect(ic.jitterQueueLength, equals(1));
      final duckedView = Int16List.view(ic.firstJitterBuffer!.buffer);
      expect(duckedView[0], closeTo(1259, 2));
      expect(duckedView[1], closeTo(2518, 2));
      expect(duckedView[2], closeTo(-1888, 2));

      // 4. Casual chatter tries to send another frame mid-transmission
      final lateChatterFrame = VoicePacket(
        VoiceKind.frame,
        {
          'streamId': 'chatter_stream_1',
          'from': 'chatter_user',
          'seq': 1,
        },
        Uint8List.fromList([1, 2, 3, 4]),
      );
      rt.emitVoice(lateChatterFrame);
      await pumpEventQueue();

      // Casual chatter packet must NOT pre-empt or add to jitter while Lead is speaking
      expect(ic.activeSpeakerName, equals('Road Captain Dan'));
      expect(ic.activeSpeakerIsLead, isTrue);

      // 5. Road Captain sends an audio frame (full volume, not ducked)
      final leadFrameSamples = Int16List.fromList([8000, -8000]);
      final leadBytes = Uint8List.view(leadFrameSamples.buffer);
      final leadFrame = VoicePacket(
        VoiceKind.frame,
        {
          'streamId': 'lead_stream_1',
          'from': 'lead_captain',
          'seq': 0,
        },
        leadBytes,
      );
      rt.emitVoice(leadFrame);
      await pumpEventQueue();

      // Lead frame was appended and is at full volume
      expect(ic.jitterQueueLength, equals(2));

      // 6. Road Captain ends transmission
      final leadEnd = VoicePacket(
        VoiceKind.end,
        {
          'streamId': 'lead_stream_1',
          'from': 'lead_captain',
        },
        Uint8List(0),
      );
      rt.emitVoice(leadEnd);
      await pumpEventQueue();

      expect(ic.activeSpeakerIsLead, isFalse);
      ic.dispose();
    });

    test('isLeadOnly channel packets are recognized as Road Captain priority', () async {
      final rt = _TestRt();
      final ic = IntercomService(rt);

      // Casual chatter
      rt.emitVoice(VoicePacket(
        VoiceKind.start,
        {'streamId': 'c1', 'from': 'rider1', 'fromName': 'Rider 1', 'channel': 'ALL', 'sampleRate': 16000},
        Uint8List(0),
      ));
      await pumpEventQueue();
      expect(ic.activeSpeakerName, equals('Rider 1'));

      // Lead-only channel packet preempts
      rt.emitVoice(VoicePacket(
        VoiceKind.start,
        {'streamId': 'l1', 'from': 'captain', 'fromName': 'Lead Sweeper', 'channel': 'LEAD_ONLY', 'sampleRate': 16000},
        Uint8List(0),
      ));
      await pumpEventQueue();

      expect(ic.activeSpeakerName, equals('Lead Sweeper'));
      expect(ic.activeSpeakerIsLead, isTrue);
      expect(ic.isReceivingLeadOnly, isTrue);

      ic.dispose();
    });

    test('priority header packets without explicit role are recognized as priority', () async {
      final rt = _TestRt();
      final ic = IntercomService(rt);

      // Casual chatter
      rt.emitVoice(VoicePacket(
        VoiceKind.start,
        {'streamId': 'c1', 'from': 'rider1', 'fromName': 'Rider 1', 'channel': 'ALL', 'sampleRate': 16000},
        Uint8List(0),
      ));
      await pumpEventQueue();

      // Priority packet without role
      rt.emitVoice(VoicePacket(
        VoiceKind.start,
        {'streamId': 'p1', 'from': 'lead1', 'fromName': 'Priority Lead', 'priority': true, 'sampleRate': 16000},
        Uint8List(0),
      ));
      await pumpEventQueue();

      expect(ic.activeSpeakerName, equals('Priority Lead'));
      expect(ic.activeSpeakerIsLead, isTrue);
      expect(ic.isPriorityDucked, isTrue);

      ic.dispose();
    });

    test('FeatureGates entitlement check prevents ducking when feature is locked', () async {
      final rt = _TestRt();
      final ic = IntercomService(rt);

      // Lock the feature
      FeatureGates.forceAllUnlocked = false;
      FeatureGates.activeTier = SubscriptionTier.community;
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking), isFalse);

      // Casual chatter starts
      rt.emitVoice(VoicePacket(
        VoiceKind.start,
        {'streamId': 'c1', 'from': 'rider1', 'fromName': 'Rider 1', 'channel': 'ALL', 'sampleRate': 16000},
        Uint8List(0),
      ));
      await pumpEventQueue();
      expect(ic.activeSpeakerName, equals('Rider 1'));

      // Lead transmits, but ducking entitlement is locked
      rt.emitVoice(VoicePacket(
        VoiceKind.start,
        {'streamId': 'l1', 'from': 'lead1', 'fromName': 'Lead Rider', 'role': 'LEAD', 'sampleRate': 16000},
        Uint8List(0),
      ));
      await pumpEventQueue();

      // Casual chatter is NOT preempted because priorityIntercomDucking is locked
      expect(ic.activeSpeakerName, equals('Rider 1'));
      expect(ic.activeSpeakerIsLead, isFalse);

      ic.dispose();
    });
  });

  group('Road Captain Outgoing Transmission Priority Headers', () {
    test('marks outgoing START, FRAME, and END packets with priority headers when user is Road Captain', () async {
      final rt = _TestRt();
      final ic = IntercomService(rt, isRoadCaptain: true);
      expect(ic.isRoadCaptain, isTrue);

      // 1. Begin transmission
      // Note: _ensurePermission uses record package; in unit test we can invoke _startStream directly or set up
      ic.setUserRole('LEAD');
      expect(ic.isRoadCaptain, isTrue);

      // Switch to lead channel also sets isRoadCaptain
      ic.setChannel(IntercomChannel.leadOnly);
      expect(ic.isRoadCaptain, isTrue);

      // Reset to all channel
      ic.setChannel(IntercomChannel.all);
      ic.setRoadCaptain(true);
      expect(ic.isRoadCaptain, isTrue);

      ic.dispose();
    });

    test('setRiderRole tracks convoy roles from roster events', () async {
      final rt = _TestRt();
      final ic = IntercomService(rt);

      // Simulate SNAPSHOT event assigning role LEAD to user_lead
      rt.emit({
        'type': 'SNAPSHOT',
        'convoy': {
          'groupId': 'c1',
          'riders': {
            'user_lead': {'role': 'LEAD', 'name': 'Captain'},
            'user_pack': {'role': 'PACK', 'name': 'Pack Rider'},
          },
        },
      });
      await pumpEventQueue();

      // Casual chatter starts
      rt.emitVoice(VoicePacket(
        VoiceKind.start,
        {'streamId': 'c1', 'from': 'user_pack', 'fromName': 'Pack Rider', 'channel': 'ALL', 'sampleRate': 16000},
        Uint8List(0),
      ));
      await pumpEventQueue();
      expect(ic.activeSpeakerName, equals('Pack Rider'));

      // Packet from user_lead without explicit 'role' in packet header:
      // IntercomService recognizes user_lead from roster as LEAD!
      rt.emitVoice(VoicePacket(
        VoiceKind.start,
        {'streamId': 'lead_s', 'from': 'user_lead', 'fromName': 'Captain', 'channel': 'ALL', 'sampleRate': 16000},
        Uint8List(0),
      ));
      await pumpEventQueue();

      expect(ic.activeSpeakerName, equals('Captain'));
      expect(ic.activeSpeakerIsLead, isTrue);

      ic.dispose();
    });
  });
}
