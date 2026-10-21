import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/data/services/intercom_network_resilience.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';

class _FakeRealtimeService extends RealtimeService {
  final List<Map<String, dynamic>> sentVoice = [];
  bool connected = true;
  String? testGroupId = 'mountain_group_1';

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
  void sendVoice(int kind, Map<String, dynamic> header, [Uint8List? payload]) {
    sentVoice.add({'kind': kind, 'header': header, 'payload': payload});
  }

  void emitVoice(VoicePacket p) => _voiceCtrl.add(p);

  void toggleConnection(bool isConn) {
    connected = isConn;
    notifyListeners();
  }
}

class _FakeVoiceEngine implements VoiceEngine {
  final List<String> spokenTexts = [];
  final List<String> spokenIds = [];
  bool running = false;

  @override
  Future<bool> init() async {
    running = true;
    return true;
  }

  @override
  Future<bool> speak(String text, {required bool interrupt, required String id}) async {
    spokenTexts.add(text);
    spokenIds.add(id);
    return true;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> release() async {
    running = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Packet Loss & Jitter Metrics Tracking', () {
    test('tracks expected packets, received packets, and calculates loss rate', () {
      final resilience = IntercomNetworkResilience();

      expect(resilience.totalPacketsExpected, equals(0));
      expect(resilience.totalPacketsReceived, equals(0));
      expect(resilience.currentLossRate, equals(0.0));

      // Packet 0 arrives
      resilience.recordPacketReceived(sequenceNumber: 0);
      expect(resilience.totalPacketsExpected, equals(1));
      expect(resilience.totalPacketsReceived, equals(1));
      expect(resilience.currentLossRate, equals(0.0));

      // Packet 1 arrives
      resilience.recordPacketReceived(sequenceNumber: 1);
      expect(resilience.totalPacketsExpected, equals(2));
      expect(resilience.totalPacketsReceived, equals(2));
      expect(resilience.currentLossRate, equals(0.0));

      // Packet 2, 3 lost! Packet 4 arrives
      resilience.recordPacketReceived(sequenceNumber: 4);
      // Expected: 2 + (4 - 1) = 5. Received: 3. Lost: 2 / 5 = 40% (0.40)
      expect(resilience.totalPacketsExpected, equals(5));
      expect(resilience.totalPacketsReceived, equals(3));
      expect(resilience.currentLossRate, closeTo(0.40, 0.01));
    });

    test('calculates arrival interval variance and smoothed jitter', () {
      final resilience = IntercomNetworkResilience();
      final baseTime = DateTime(2026, 10, 21, 12, 0, 0);

      // Packet arrivals with varying intervals
      resilience.recordPacketReceived(sequenceNumber: 0, arrivalTime: baseTime);
      resilience.recordPacketReceived(sequenceNumber: 1, arrivalTime: baseTime.add(const Duration(milliseconds: 40)));
      resilience.recordPacketReceived(sequenceNumber: 2, arrivalTime: baseTime.add(const Duration(milliseconds: 95))); // +55ms
      resilience.recordPacketReceived(sequenceNumber: 3, arrivalTime: baseTime.add(const Duration(milliseconds: 120))); // +25ms
      resilience.recordPacketReceived(sequenceNumber: 4, arrivalTime: baseTime.add(const Duration(milliseconds: 190))); // +70ms

      expect(resilience.jitterVariance, greaterThan(0.0));
      expect(resilience.packetJitter, greaterThan(0.0));
      expect(resilience.jitterMs, equals(resilience.packetJitter));
    });
  });

  group('Adaptive Jitter Buffer Delay', () {
    test('buffer delay is 60ms when loss < 10%', () {
      final resilience = IntercomNetworkResilience();

      resilience.setLossRateForTesting(0.0);
      expect(resilience.adaptiveBufferDelayMs, equals(60));

      resilience.setLossRateForTesting(0.05);
      expect(resilience.adaptiveBufferDelayMs, equals(60));

      resilience.setLossRateForTesting(0.09);
      expect(resilience.adaptiveBufferDelayMs, equals(60));
    });

    test('buffer delay smoothly expands from 200ms to 350ms between 10% and 40% loss', () {
      final resilience = IntercomNetworkResilience();

      // Exactly 10% loss -> 200ms
      resilience.setLossRateForTesting(0.10);
      expect(resilience.adaptiveBufferDelayMs, equals(200));

      // 25% loss (midpoint of 10% and 40%) -> 275ms
      resilience.setLossRateForTesting(0.25);
      expect(resilience.adaptiveBufferDelayMs, equals(275));

      // Exactly 40% loss -> 350ms
      resilience.setLossRateForTesting(0.40);
      expect(resilience.adaptiveBufferDelayMs, equals(350));
    });

    test('buffer delay expands above 350ms up to 500ms when loss > 40%', () {
      final resilience = IntercomNetworkResilience();

      resilience.setLossRateForTesting(0.60);
      expect(resilience.adaptiveBufferDelayMs, greaterThan(350));
      expect(resilience.adaptiveBufferDelayMs, lessThanOrEqualTo(500));
    });
  });

  group('Forward Error Correction (FEC) & Redundant Frame Reconstruction', () {
    test('sender encodes dual audio chunks when loss > 15%', () {
      final resilience = IntercomNetworkResilience();
      final frame1 = Uint8List.fromList([1, 2, 3, 4]);
      final frame2 = Uint8List.fromList([5, 6, 7, 8]);

      // At low loss (10%), FEC is disabled
      resilience.setLossRateForTesting(0.10);
      final p1 = resilience.encodeOutgoingFrame(frame1);
      expect(p1.hasFec, isFalse);
      expect(p1.redundantAudio, isNull);

      final p2 = resilience.encodeOutgoingFrame(frame2);
      expect(p2.hasFec, isFalse);
      expect(p2.redundantAudio, isNull);

      // In high loss mountain pass (30% loss > 15%), FEC is enabled
      resilience.setLossRateForTesting(0.30);
      final frame3 = Uint8List.fromList([9, 10, 11, 12]);
      final p3 = resilience.encodeOutgoingFrame(frame3);

      expect(p3.hasFec, isTrue);
      expect(p3.redundantSequenceNumber, equals(p2.sequenceNumber));
      expect(p3.redundantAudio, equals(frame2));
    });

    test('receiver extracts packet N redundant payload from packet N+1 without any gap', () {
      final resilience = IntercomNetworkResilience();

      final frame0 = Uint8List.fromList([10, 20]);
      final frame1 = Uint8List.fromList([30, 40]);
      final frame2 = Uint8List.fromList([50, 60]);

      // Packet 0 arrives normally
      final pkt0 = ResilientVoicePacket(sequenceNumber: 0, primaryAudio: frame0);
      final out0 = resilience.processIncomingPacket(pkt0);
      expect(out0.length, equals(1));
      expect(out0.first, equals(frame0));
      expect(resilience.totalFecRecoveries, equals(0));

      // Packet 1 is LOST over cellular!
      // Packet 2 arrives, containing redundant frame 1!
      final pkt2 = ResilientVoicePacket(
        sequenceNumber: 2,
        primaryAudio: frame2,
        hasFec: true,
        redundantSequenceNumber: 1,
        redundantAudio: frame1,
      );

      final out2 = resilience.processIncomingPacket(pkt2);

      // Must output BOTH reconstructed frame 1 and frame 2 in order!
      expect(out2.length, equals(2));
      expect(out2[0], equals(frame1)); // Gapless recovered frame!
      expect(out2[1], equals(frame2)); // Current frame!
      expect(resilience.totalFecRecoveries, equals(1));
    });
  });

  group('Packet Loss Concealment (PLC)', () {
    test('generates smooth comfort noise or pitch-decayed interpolation on unrecoverable loss', () {
      final resilience = IntercomNetworkResilience();

      final lastGood = Uint8List(1280); // 40ms 16kHz
      for (var i = 0; i < 640; i++) {
        final bd = ByteData.sublistView(lastGood);
        bd.setInt16(i * 2, 8000, Endian.little);
      }

      final plcFrame = resilience.generatePlcFrame(
        lastGoodFrame: lastGood,
        frameSizeBytes: 1280,
        consecutiveLostFrames: 1,
      );

      expect(plcFrame.length, equals(1280));
      final bdOut = ByteData.sublistView(plcFrame);
      final midSample = bdOut.getInt16(320 * 2, Endian.little);

      // Decayed amplitude: ~8000 * 0.78 ~= 6240 (+ subtle dither)
      expect(midSample, closeTo(6240, 200));

      // Comfort silence fallback when consecutive loss > 3
      final comfortNoise = resilience.generatePlcFrame(
        lastGoodFrame: lastGood,
        frameSizeBytes: 1280,
        consecutiveLostFrames: 5,
      );
      expect(comfortNoise.length, equals(1280));
    });
  });

  group('Voice Memo / Store-and-Forward Burst Mode', () {
    test('stores 3-5s burst locally when loss exceeds 50% or network disconnects', () async {
      final fakeRt = _FakeRealtimeService();
      final resilience = IntercomNetworkResilience(realtimeService: fakeRt);

      // Network loss exceeds 50%
      resilience.setLossRateForTesting(0.60);

      // Rider speaks a 3-second voice burst (96,000 bytes)
      final dummySpeech = Uint8List(96000);
      resilience.recordBurstChunk(dummySpeech);

      expect(resilience.isBurstModeActive, isTrue);
      expect(resilience.pendingBurstsCount, equals(1));
      expect(resilience.storedBursts.first.audioData.length, equals(96000));
      expect(resilience.storedBursts.first.isHighPriority, isTrue);

      // When network is restored, transmits burst via high priority binary burst
      fakeRt.toggleConnection(true);
      final transmittedCount = await resilience.onNetworkRestored();

      expect(transmittedCount, equals(1));
      expect(resilience.pendingBurstsCount, equals(0));
      expect(resilience.isBurstModeActive, isFalse);
      expect(fakeRt.sentVoice.length, equals(1));
      expect(fakeRt.sentVoice.first['header']['type'], equals('VOICE_BURST'));
      expect(fakeRt.sentVoice.first['header']['priority'], isTrue);
    });
  });

  group('1-Tap Zero-Bandwidth Tactical Canned Signals', () {
    test('encodes and decodes ultra-compact 12-byte packet correctly', () {
      for (final signal in TacticalSignal.values) {
        final packet = IntercomNetworkResilience.encodeTacticalSignalPacket(
          signal,
          senderId: 'rider_lead_01',
          timestamp: DateTime(2026, 10, 21, 12, 30, 0),
        );

        expect(packet.length, equals(12));
        expect(packet[0], equals(0x7E));

        final decoded = IntercomNetworkResilience.decodeTacticalSignalPacket(packet);
        expect(decoded, equals(signal));
      }
    });

    test('corrupted or modified tactical packets are rejected by checksum', () {
      final packet = IntercomNetworkResilience.encodeTacticalSignalPacket(TacticalSignal.hazardOnRoad);
      expect(packet.length, equals(12));

      // Corrupt a byte
      packet[3] ^= 0xFF;
      final decoded = IntercomNetworkResilience.decodeTacticalSignalPacket(packet);
      expect(decoded, isNull);
    });

    test('receiving tactical packet triggers local TTS into teammates helmet headsets', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();
      await settings.load();

      final fakeVoiceEngine = _FakeVoiceEngine();
      final voiceService = VoiceService(
        settings,
        engine: fakeVoiceEngine,
      );

      final resilience = IntercomNetworkResilience(voiceService: voiceService);

      final packet = IntercomNetworkResilience.encodeTacticalSignalPacket(TacticalSignal.regroupAhead);

      final success = await resilience.processIncomingTacticalPacket(packet, senderId: 'rider_07');
      expect(success, isTrue);

      // Verify TTS was triggered with tactical prompt
      expect(fakeVoiceEngine.spokenTexts.length, equals(1));
      expect(fakeVoiceEngine.spokenTexts.first, equals('Regroup ahead.'));
    });
  });
}
