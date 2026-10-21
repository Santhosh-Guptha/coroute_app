import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/audio_route_watchdog.dart';
import 'package:coroute_app/data/services/intercom_network_resilience.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';

class _FakeVoiceEngine implements VoiceEngine {
  final List<String> spoken = [];

  @override
  Future<bool> init() async => true;

  @override
  Future<bool> speak(String text, {required bool interrupt, required String id}) async {
    spoken.add(text);
    return true;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> release() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==========================================================================
  // Test Group 1: AudioRouteWatchdog Tests
  // ==========================================================================
  group('AudioRouteWatchdog Tests', () {
    test('Detects Bluetooth disconnection and sets isAudioRoutingIssue = true', () {
      final watchdog = AudioRouteWatchdog(
        initialBluetoothConnected: true,
        initialRoute: AudioRouteType.bluetooth,
      );

      expect(watchdog.isBluetoothConnected, isTrue);
      expect(watchdog.isAudioRoutingIssue, isFalse);
      expect(watchdog.currentRoute, equals(AudioRouteType.bluetooth));

      bool notified = false;
      watchdog.addListener(() => notified = true);

      // Simulate Bluetooth disconnection from helmet headset
      watchdog.onBluetoothStateChanged(false);

      expect(watchdog.isBluetoothConnected, isFalse);
      expect(watchdog.isAudioRoutingIssue, isTrue);
      expect(watchdog.currentRoute, equals(AudioRouteType.speaker));
      expect(notified, isTrue);
    });

    test('Detects 0% volume and flags isVolumeMuted = true', () {
      final watchdog = AudioRouteWatchdog(initialVolume: 0.75);

      expect(watchdog.currentVolume, equals(0.75));
      expect(watchdog.isVolumeMuted, isFalse);

      // Volume drops to 0%
      watchdog.onVolumeChanged(0.0);

      expect(watchdog.currentVolume, equals(0.0));
      expect(watchdog.isVolumeMuted, isTrue);

      // Volume increases to 50%
      watchdog.onVolumeChanged(0.50);

      expect(watchdog.currentVolume, equals(0.50));
      expect(watchdog.isVolumeMuted, isFalse);
    });

    test('boostIntercomVolume() restores volume to 100% and resets muted flag', () async {
      double? platformVolumeTarget;
      final watchdog = AudioRouteWatchdog(
        initialVolume: 0.0,
        onSetVolume: (vol) async {
          platformVolumeTarget = vol;
        },
      );

      expect(watchdog.isVolumeMuted, isTrue);
      expect(watchdog.currentVolume, equals(0.0));

      // Rider activates emergency intercom volume boost
      await watchdog.boostIntercomVolume();

      expect(watchdog.currentVolume, equals(1.0));
      expect(watchdog.isVolumeMuted, isFalse);
      expect(platformVolumeTarget, equals(1.0));
    });

    test('attemptReconnectBluetooth() resets routing issue flag', () async {
      bool reconnectCalled = false;
      final watchdog = AudioRouteWatchdog(
        initialBluetoothConnected: true,
        onReconnectBluetooth: () async {
          reconnectCalled = true;
          return true;
        },
      );

      // Trigger Bluetooth failure
      watchdog.onBluetoothStateChanged(false);
      expect(watchdog.isAudioRoutingIssue, isTrue);
      expect(watchdog.isBluetoothConnected, isFalse);

      // Attempt reconnection
      final success = await watchdog.attemptReconnectBluetooth();

      expect(success, isTrue);
      expect(reconnectCalled, isTrue);
      expect(watchdog.isAudioRoutingIssue, isFalse);
      expect(watchdog.isBluetoothConnected, isTrue);
      expect(watchdog.currentRoute, equals(AudioRouteType.bluetooth));
    });
  });

  // ==========================================================================
  // Test Group 2: Network Audio Resilience & FEC Tests
  // ==========================================================================
  group('Network Audio Resilience & FEC Tests', () {
    test(
        'Forward Error Correction (FEC): Verify that with 50% packet drops (packets 1, 3, 5 arrive, but 2, 4 are lost), the receiver reconstructs the lost packets from redundant payloads in arriving packets!',
        () {
      final txResilience = IntercomNetworkResilience();
      final rxResilience = IntercomNetworkResilience();

      // Create 5 distinct PCM audio frames
      final frame1 = Uint8List.fromList(List.filled(1280, 0x11));
      final frame2 = Uint8List.fromList(List.filled(1280, 0x22));
      final frame3 = Uint8List.fromList(List.filled(1280, 0x33));
      final frame4 = Uint8List.fromList(List.filled(1280, 0x44));
      final frame5 = Uint8List.fromList(List.filled(1280, 0x55));

      // Sender encodes outgoing packets with FEC redundancy (bundles previous packet)
      final pkt1 = txResilience.encodeOutgoingFrame(frame1, sequenceNumber: 1, forceFec: true);
      final pkt2 = txResilience.encodeOutgoingFrame(frame2, sequenceNumber: 2, forceFec: true);
      final pkt3 = txResilience.encodeOutgoingFrame(frame3, sequenceNumber: 3, forceFec: true);
      final pkt4 = txResilience.encodeOutgoingFrame(frame4, sequenceNumber: 4, forceFec: true);
      final pkt5 = txResilience.encodeOutgoingFrame(frame5, sequenceNumber: 5, forceFec: true);

      // Verify FEC payloads are bundled
      expect(pkt1.hasFec, isFalse); // No previous frame yet
      expect(pkt2.hasFec, isTrue);
      expect(pkt2.redundantSequenceNumber, equals(1));
      expect(pkt2.redundantAudio, equals(frame1));

      expect(pkt3.hasFec, isTrue);
      expect(pkt3.redundantSequenceNumber, equals(2));
      expect(pkt3.redundantAudio, equals(frame2));

      expect(pkt4.hasFec, isTrue);
      expect(pkt4.redundantSequenceNumber, equals(3));
      expect(pkt4.redundantAudio, equals(frame3));

      expect(pkt5.hasFec, isTrue);
      expect(pkt5.redundantSequenceNumber, equals(4));
      expect(pkt5.redundantAudio, equals(frame4));

      // 50% PACKET DROP HARSH MOUNTAIN PASS SIMULATION:
      // Packets 1, 3, 5 arrive safely at the receiver.
      // Packets 2 and 4 are completely dropped in transit!
      final allReceivedFrames = <Uint8List>[];

      // 1. Packet 1 arrives
      allReceivedFrames.addAll(rxResilience.processIncomingPacket(pkt1));

      // 2. Packet 3 arrives (Packet 2 dropped in transit!)
      allReceivedFrames.addAll(rxResilience.processIncomingPacket(pkt3));

      // 3. Packet 5 arrives (Packet 4 dropped in transit!)
      allReceivedFrames.addAll(rxResilience.processIncomingPacket(pkt5));

      // Verify that receiver reconstructed all 5 packets in chronological order
      expect(allReceivedFrames.length, equals(5));
      expect(allReceivedFrames[0], equals(frame1)); // Primary from pkt 1
      expect(allReceivedFrames[1], equals(frame2)); // Reconstructed from pkt 3's redundant FEC!
      expect(allReceivedFrames[2], equals(frame3)); // Primary from pkt 3
      expect(allReceivedFrames[3], equals(frame4)); // Reconstructed from pkt 5's redundant FEC!
      expect(allReceivedFrames[4], equals(frame5)); // Primary from pkt 5

      expect(rxResilience.totalFecRecoveries, equals(2));
      expect(rxResilience.totalPlcConcealments, equals(0));
    });

    test(
        'Packet Loss Concealment (PLC): Verify that when both primary and redundant packets are dropped, PLC inserts smooth comfort silence/interpolated samples instead of null crashes or screeching',
        () {
      final rxResilience = IntercomNetworkResilience();

      // Send initial frame with audible audio amplitude
      final frame1 = Uint8List(1280);
      final bd1 = ByteData.sublistView(frame1);
      for (int i = 0; i < 640; i++) {
        bd1.setInt16(i * 2, 10000, Endian.little);
      }
      final pkt1 = ResilientVoicePacket(sequenceNumber: 1, primaryAudio: frame1);
      final out1 = rxResilience.processIncomingPacket(pkt1);
      expect(out1.length, equals(1));

      // BURST DROP SIMULATION:
      // Both Packet 2 and Packet 3 are dropped.
      // Packet 4 arrives, but its redundant payload is only Packet 3.
      // Packet 2 has NEITHER primary nor redundant payload available!
      final pkt4 = ResilientVoicePacket(
        sequenceNumber: 4,
        primaryAudio: Uint8List(1280),
        hasFec: true,
        redundantSequenceNumber: 3,
        redundantAudio: Uint8List(1280),
      );

      final outFrames = rxResilience.processIncomingPacket(pkt4);

      // Output should contain:
      // - Packet 2: PLC comfort frame (no primary or redundant packet)
      // - Packet 3: FEC reconstructed frame (from pkt4.redundantAudio)
      // - Packet 4: Primary frame
      expect(outFrames.length, equals(3));
      expect(rxResilience.totalPlcConcealments, equals(1));
      expect(rxResilience.totalFecRecoveries, equals(1));

      final plcFrame = outFrames[0];
      expect(plcFrame, isNotNull);
      expect(plcFrame.length, equals(1280));

      // Verify PLC samples are smooth, non-null, and not screeching (amplitude decayed)
      final plcBd = ByteData.sublistView(plcFrame);
      final sample0 = plcBd.getInt16(0, Endian.little);
      expect(sample0.abs(), lessThan(10000)); // Faded smoothly below original 10000 amplitude

      // Standalone PLC comfort silence generation check
      final comfortSilence = rxResilience.generatePlcFrame(lastGoodFrame: null, frameSizeBytes: 1280);
      expect(comfortSilence.length, equals(1280));
    });

    test(
        'Adaptive Jitter Buffer: Verify that jitter buffer expands smoothly from 60ms under low loss to 250ms+ under high jitter',
        () {
      final resilience = IntercomNetworkResilience();

      // 1. Low loss and low jitter: minimum 60ms latency
      resilience.setLossRateForTesting(0.02);
      resilience.setJitterForTesting(2.0);
      expect(resilience.adaptiveBufferDelayMs, equals(60));

      final initialDelay = resilience.adaptiveBufferDelayMs;

      // 2. High jitter is introduced smoothly
      final recordedDelays = <int>[];
      final jitterSteps = [15.0, 35.0, 60.0, 85.0, 110.0];

      for (final jitter in jitterSteps) {
        resilience.setJitterForTesting(jitter);
        recordedDelays.add(resilience.adaptiveBufferDelayMs);
      }

      // Verify smooth expansion upwards
      for (int i = 1; i < recordedDelays.length; i++) {
        expect(recordedDelays[i], greaterThanOrEqualTo(recordedDelays[i - 1]));
      }

      // Verify expansion reaches 250ms+ under high jitter
      expect(resilience.adaptiveBufferDelayMs, greaterThan(initialDelay));
      expect(resilience.adaptiveBufferDelayMs, greaterThanOrEqualTo(250));
    });
  });

  // ==========================================================================
  // Test Group 3: Store-and-Forward Voice Burst Mode
  // ==========================================================================
  group('Store-and-Forward Voice Burst Mode', () {
    test(
        'When network drops mid-speech, voice burst is buffered locally; when network comes online, voice burst is dequeued and transmitted',
        () async {
      final transmittedBursts = <VoiceMemoBurst>[];
      final resilience = IntercomNetworkResilience(
        onTransmitBurst: (burst) async {
          transmittedBursts.add(burst);
          return true;
        },
      );

      expect(resilience.isBurstModeActive, isFalse);
      expect(resilience.pendingBurstsCount, equals(0));

      // Network drops mid-ride (mountain tunnel or dead zone)
      resilience.setNetworkConnectedForTesting(false);

      // Rider speaks voice chunks during disconnect
      final chunk1 = Uint8List.fromList(List.filled(1280, 0xAA));
      final chunk2 = Uint8List.fromList(List.filled(1280, 0xBB));
      final chunk3 = Uint8List.fromList(List.filled(1280, 0xCC));

      resilience.recordBurstChunk(chunk1, channel: 'ALL');
      resilience.recordBurstChunk(chunk2, channel: 'ALL');
      resilience.recordBurstChunk(chunk3, channel: 'ALL');
      resilience.commitActiveBurst(channel: 'ALL');

      // Voice burst is buffered locally and not yet transmitted
      expect(resilience.isBurstModeActive, isTrue);
      expect(resilience.pendingBurstsCount, equals(1));
      expect(transmittedBursts, isEmpty);

      final burst = resilience.storedBursts.first;
      expect(burst.audioData.length, equals(1280 * 3));
      expect(burst.channel, equals('ALL'));

      // Network connectivity is restored upon exiting the tunnel
      final sentCount = await resilience.onNetworkRestored();

      // Burst is dequeued and transmitted
      expect(sentCount, equals(1));
      expect(resilience.pendingBurstsCount, equals(0));
      expect(resilience.isBurstModeActive, isFalse);
      expect(transmittedBursts.length, equals(1));
      expect(transmittedBursts.first.id, equals(burst.id));
    });
  });

  // ==========================================================================
  // Test Group 4: Tactical Zero-Bandwidth Quick Signals
  // ==========================================================================
  group('Tactical Zero-Bandwidth Quick Signals', () {
    test(
        'Test encoding and dispatching compact tactical signals (hazardOnRoad, regroupAhead, loudAndClear)',
        () {
      final testSignals = [
        TacticalSignal.hazardOnRoad,
        TacticalSignal.regroupAhead,
        TacticalSignal.loudAndClear,
      ];

      for (final signal in testSignals) {
        // Encode to compact 12-byte zero-bandwidth micro-payload
        final packet = IntercomNetworkResilience.encodeTacticalSignalPacket(
          signal,
          senderId: 'rider_captain',
        );

        expect(packet.length, equals(IntercomNetworkResilience.tacticalPacketSize));
        expect(packet.length, equals(12)); // Exactly 12 bytes
        expect(packet[0], equals(IntercomNetworkResilience.tacticalMagicByte));

        // Decode back
        final decoded = IntercomNetworkResilience.decodeTacticalSignalPacket(packet);
        expect(decoded, equals(signal));
      }
    });

    test(
        'Test that receiver decodes signal and formats TTS string for immediate speech readout',
        () async {
      final fakeEngine = _FakeVoiceEngine();
      final settings = SettingsService();
      final voiceService = VoiceService(settings, engine: fakeEngine);

      final resilience = IntercomNetworkResilience(voiceService: voiceService);

      final receivedEvents = <TacticalSignalEvent>[];
      final sub = resilience.onTacticalSignalReceived.listen(receivedEvents.add);

      // 1. Dispatch hazardOnRoad
      final hazardPkt = IntercomNetworkResilience.encodeTacticalSignalPacket(
        TacticalSignal.hazardOnRoad,
        senderId: 'lead_rider',
      );
      final okHazard = await resilience.processIncomingTacticalPacket(hazardPkt, senderId: 'lead_rider');

      expect(okHazard, isTrue);
      expect(TacticalSignal.hazardOnRoad.spokenPhrase, contains('Hazard on road'));
      expect(fakeEngine.spoken.last, contains('Hazard on road'));

      // 2. Dispatch regroupAhead
      final regroupPkt = IntercomNetworkResilience.encodeTacticalSignalPacket(
        TacticalSignal.regroupAhead,
        senderId: 'sweeper',
      );
      final okRegroup = await resilience.processIncomingTacticalPacket(regroupPkt, senderId: 'sweeper');

      expect(okRegroup, isTrue);
      expect(TacticalSignal.regroupAhead.spokenPhrase, contains('Regroup ahead'));
      expect(fakeEngine.spoken.last, contains('Regroup ahead'));

      // 3. Dispatch loudAndClear
      final radioCheckPkt = IntercomNetworkResilience.encodeTacticalSignalPacket(
        TacticalSignal.loudAndClear,
        senderId: 'tail_gunner',
      );
      final okCheck = await resilience.processIncomingTacticalPacket(radioCheckPkt, senderId: 'tail_gunner');

      expect(okCheck, isTrue);
      expect(TacticalSignal.loudAndClear.spokenPhrase, contains('Loud and clear'));
      expect(fakeEngine.spoken.last, contains('Loud and clear'));

      await pumpEventQueue();
      expect(receivedEvents.length, equals(3));
      expect(receivedEvents[0].signal, equals(TacticalSignal.hazardOnRoad));
      expect(receivedEvents[1].signal, equals(TacticalSignal.regroupAhead));
      expect(receivedEvents[2].signal, equals(TacticalSignal.loudAndClear));

      await sub.cancel();
    });
  });
}
