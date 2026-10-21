import 'dart:async';
import 'dart:collection';
import 'dart:io' show gzip;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'realtime_service.dart';
import 'voice_service.dart';

/// Tactical canned signals designed for ultra-low or zero audio bandwidth environments
/// (such as deep mountain passes, canyons, and ghats).
enum TacticalSignal {
  loudAndClear,
  repeatLast,
  regroupAhead,
  slowingDown,
  hazardOnRoad;

  int get id => index;

  static TacticalSignal fromId(int id) {
    if (id < 0 || id >= TacticalSignal.values.length) {
      return TacticalSignal.loudAndClear;
    }
    return TacticalSignal.values[id];
  }

  /// Spoken TTS string announced directly into rider helmet headsets.
  String get spokenPhrase => switch (this) {
        TacticalSignal.loudAndClear => 'Loud and clear.',
        TacticalSignal.repeatLast => 'Say again, repeat last message.',
        TacticalSignal.regroupAhead => 'Regroup ahead.',
        TacticalSignal.slowingDown => 'Convoy slowing down.',
        TacticalSignal.hazardOnRoad => 'Caution: Hazard on road.',
      };

  String get label => switch (this) {
        TacticalSignal.loudAndClear => 'Loud & Clear',
        TacticalSignal.repeatLast => 'Repeat Last',
        TacticalSignal.regroupAhead => 'Regroup Ahead',
        TacticalSignal.slowingDown => 'Slowing Down',
        TacticalSignal.hazardOnRoad => 'Hazard Ahead',
      };
}

/// Helper extension on [VoiceService] for tactical voice prompts.
extension TacticalVoiceServiceExtension on VoiceService {
  Future<bool> speakVoicePrompt(String text) => speak(text, priority: VoicePriority.critical);
}

/// Represents a voice frame with optional Forward Error Correction (FEC) redundant payload.
class ResilientVoicePacket {
  ResilientVoicePacket({
    required this.sequenceNumber,
    required this.primaryAudio,
    this.hasFec = false,
    this.redundantSequenceNumber,
    this.redundantAudio,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final int sequenceNumber;
  final Uint8List primaryAudio;
  final bool hasFec;
  final int? redundantSequenceNumber;
  final Uint8List? redundantAudio;
  final DateTime timestamp;

  /// Magic identifier for binary FEC packets ('CR' in ASCII = 0x4352).
  static const int binaryMagic = 0x4352;

  /// Encodes this packet into a self-contained binary payload.
  Uint8List toBinary() {
    final hasRedundant = hasFec && redundantAudio != null && redundantAudio!.isNotEmpty;
    final primaryLen = primaryAudio.length;
    final redundantLen = hasRedundant ? redundantAudio!.length : 0;
    final totalLen = 9 + primaryLen + redundantLen;

    final data = Uint8List(totalLen);
    final bd = ByteData.sublistView(data);

    bd.setUint16(0, binaryMagic, Endian.big);
    bd.setUint16(2, sequenceNumber & 0xFFFF, Endian.big);
    bd.setUint8(4, hasRedundant ? 1 : 0);
    bd.setUint16(5, primaryLen, Endian.big);
    bd.setUint16(7, hasRedundant ? (redundantSequenceNumber ?? 0) & 0xFFFF : 0, Endian.big);

    data.setRange(9, 9 + primaryLen, primaryAudio);
    if (hasRedundant) {
      data.setRange(9 + primaryLen, totalLen, redundantAudio!);
    }

    return data;
  }

  /// Decodes a binary payload into a [ResilientVoicePacket].
  /// If the binary data does not start with [binaryMagic], it is treated as a raw primary audio frame.
  static ResilientVoicePacket fromBinary(Uint8List data, {int defaultSeq = 0}) {
    if (data.length < 9) {
      return ResilientVoicePacket(sequenceNumber: defaultSeq, primaryAudio: data);
    }

    final bd = ByteData.sublistView(data);
    final magic = bd.getUint16(0, Endian.big);
    if (magic != binaryMagic) {
      return ResilientVoicePacket(sequenceNumber: defaultSeq, primaryAudio: data);
    }

    final seq = bd.getUint16(2, Endian.big);
    final hasFec = bd.getUint8(4) == 1;
    final primaryLen = bd.getUint16(5, Endian.big);
    final redundantSeq = bd.getUint16(7, Endian.big);

    if (data.length < 9 + primaryLen) {
      return ResilientVoicePacket(sequenceNumber: seq, primaryAudio: data);
    }

    final primary = Uint8List.sublistView(data, 9, 9 + primaryLen);
    Uint8List? redundant;
    if (hasFec && data.length > 9 + primaryLen) {
      redundant = Uint8List.sublistView(data, 9 + primaryLen);
    }

    return ResilientVoicePacket(
      sequenceNumber: seq,
      primaryAudio: primary,
      hasFec: hasFec,
      redundantSequenceNumber: hasFec ? redundantSeq : null,
      redundantAudio: redundant,
    );
  }
}

/// Represents a stored local voice memo burst during severe packet loss or disconnection.
class VoiceMemoBurst {
  VoiceMemoBurst({
    required this.id,
    required this.recordedAt,
    required this.duration,
    required this.audioData,
    this.sampleRate = 16000,
    this.isHighPriority = true,
    this.channel = 'ALL',
    this.targetUserId,
  });

  final String id;
  final DateTime recordedAt;
  final Duration duration;
  final Uint8List audioData;
  final int sampleRate;
  final bool isHighPriority;
  final String channel;
  final String? targetUserId;
}

/// Event dispatched when a tactical canned signal is decoded from the network.
class TacticalSignalEvent {
  TacticalSignalEvent({
    required this.signal,
    required this.timestamp,
    this.senderId,
  });

  final TacticalSignal signal;
  final DateTime timestamp;
  final String? senderId;
}

/// Mountain Network Audio Resilience & Packet Loss Concealment (PLC) engine.
///
/// Designed specifically for weak cellular signal conditions (20% to 60% loss, high jitter)
/// in mountain passes, ghats, and canyons.
///
/// Features:
/// 1. Metric Tracking: Sequence numbers, loss rate, packet jitter variance.
/// 2. Adaptive Jitter Buffer: 60ms for <10% loss; expanding to 200ms-350ms for 10%-40% loss.
/// 3. Forward Error Correction (FEC): Dual audio chunk encoding when loss > 15%.
/// 4. Packet Loss Concealment (PLC): Smooth comfort silence and pitch-decayed interpolation.
/// 5. Voice Memo / Store-and-Forward Burst Mode: Stores 3-5s burst during >50% loss or dropouts,
///    then transmits immediately upon reconnection.
/// 6. 1-Tap Zero-Bandwidth Tactical Canned Signals: 12-byte compact packet triggered via TTS.
class IntercomNetworkResilience extends ChangeNotifier {
  IntercomNetworkResilience({
    RealtimeService? realtimeService,
    VoiceService? voiceService,
    this.onAudioFrameReady,
    this.onTransmitBurst,
  })  : _rt = realtimeService,
        _voice = voiceService {
    _initRealtimeListeners();
  }

  final RealtimeService? _rt;
  final VoiceService? _voice;

  /// Callback fired when an in-order or recovered audio frame is ready for playout.
  final void Function(Uint8List frame)? onAudioFrameReady;

  /// Callback fired when a pending voice burst is ready to transmit.
  final Future<bool> Function(VoiceMemoBurst burst)? onTransmitBurst;

  StreamSubscription<VoicePacket>? _rtVoiceSub;

  // ------------------------------------------------------------- Metrics State
  int _totalPacketsExpected = 0;
  int _totalPacketsReceived = 0;
  double _currentLossRate = 0.0;
  int? _lastReceivedSeq;

  int _totalFecRecoveries = 0;
  int _totalPlcConcealments = 0;

  // Jitter tracking (RFC 3550 standard + interval variance)
  DateTime? _lastPacketArrivalTime;
  final Queue<double> _arrivalIntervals = Queue<double>();
  static const int _maxIntervalHistory = 40;
  double _smoothedJitterMs = 0.0;
  double _jitterVariance = 0.0;

  int get totalPacketsExpected => _totalPacketsExpected;
  int get totalPacketsReceived => _totalPacketsReceived;
  double get currentLossRate => _currentLossRate;
  int get totalFecRecoveries => _totalFecRecoveries;
  int get totalPlcConcealments => _totalPlcConcealments;

  /// Inter-arrival interval variance in milliseconds squared (ms^2).
  double get jitterVariance => _jitterVariance;

  /// Standard packet jitter in milliseconds (RFC 3550 smoothed jitter).
  double get packetJitter => _smoothedJitterMs;
  double get jitterMs => _smoothedJitterMs;

  // --------------------------------------------------- Adaptive Jitter Buffer
  /// Playout buffer delay (in milliseconds) calculated adaptively based on current packet loss rate
  /// and observed packet arrival jitter:
  /// - < 10% loss and low jitter (<= 10ms): 60ms ultra-low latency.
  /// - Under high jitter (> 80ms) or high loss (10% - 40%): smoothly expands from 60ms to 250ms - 350ms to absorb jitter.
  /// - > 40% loss: expands smoothly up to 500ms to absorb severe mountain jitter spikes.
  int get adaptiveBufferDelayMs {
    final excessJitter = math.max(0.0, _smoothedJitterMs - 10.0);
    final jitterCompensation = (excessJitter * 2.5).round();

    int lossDelay;
    if (_currentLossRate < 0.10) {
      lossDelay = 60;
    } else if (_currentLossRate <= 0.40) {
      // Smooth linear interpolation from 200ms at 10% loss to 350ms at 40% loss
      final t = (_currentLossRate - 0.10) / (0.40 - 0.10);
      lossDelay = (200 + t * (350 - 200)).round();
    } else {
      final t = ((_currentLossRate - 0.40) / 0.60).clamp(0.0, 1.0);
      lossDelay = (350 + t * 150).round();
    }

    final calculated = math.max(lossDelay, 60 + jitterCompensation);
    return calculated.clamp(60, 500);
  }

  // ------------------------------------------------------------ Sender State
  int _outgoingSeq = 0;
  Uint8List? _lastOutgoingFrame;

  // ---------------------------------------------------------- Receiver State
  int? _expectedPlayoutSeq;
  Uint8List? _lastGoodPlayoutFrame;
  int _consecutiveLostPlayoutFrames = 0;

  // ------------------------------------ Voice Memo / Store-and-Forward State
  bool _isBurstModeActive = false;
  final List<VoiceMemoBurst> _storedBursts = [];
  final BytesBuilder _activeBurstBuffer = BytesBuilder(copy: false);
  DateTime? _activeBurstStartTime;
  bool _isNetworkConnected = true;

  bool get isBurstModeActive => _isBurstModeActive;
  List<VoiceMemoBurst> get storedBursts => List.unmodifiable(_storedBursts);
  int get pendingBurstsCount => _storedBursts.length;

  // --------------------------------- Tactical Canned Signals Stream Controller
  final StreamController<TacticalSignalEvent> _tacticalStreamController =
      StreamController<TacticalSignalEvent>.broadcast();

  Stream<TacticalSignalEvent> get onTacticalSignalReceived => _tacticalStreamController.stream;

  static const int tacticalPacketSize = 12;
  static const int tacticalMagicByte = 0x7E;
  static const int tacticalVersion = 1;

  void _initRealtimeListeners() {
    if (_rt != null) {
      _isNetworkConnected = _rt.isConnected;
      _rtVoiceSub = _rt.voice.listen(_handleIncomingVoicePacket);
      _rt.addListener(_onRealtimeStateChanged);
    }
  }

  void _onRealtimeStateChanged() {
    if (_rt == null) return;
    final connected = _rt.isConnected;
    if (connected != _isNetworkConnected) {
      _isNetworkConnected = connected;
      if (connected) {
        onNetworkRestored();
      }
      notifyListeners();
    }
  }

  // ------------------------------------------------------- Loss Tracking Logic
  /// Records receipt of a packet and recalculates loss rate and jitter metrics.
  void recordPacketReceived({required int sequenceNumber, DateTime? arrivalTime}) {
    final now = arrivalTime ?? DateTime.now();

    _totalPacketsReceived++;

    if (_lastReceivedSeq == null) {
      _lastReceivedSeq = sequenceNumber;
      _totalPacketsExpected = 1;
    } else {
      if (sequenceNumber > _lastReceivedSeq!) {
        final gap = sequenceNumber - _lastReceivedSeq!;
        _totalPacketsExpected += gap;
        _lastReceivedSeq = sequenceNumber;
      }
    }

    if (_totalPacketsExpected > 0) {
      final lost = _totalPacketsExpected - _totalPacketsReceived;
      _currentLossRate = (lost / _totalPacketsExpected).clamp(0.0, 1.0);
    }

    // Update arrival interval and jitter variance
    if (_lastPacketArrivalTime != null) {
      final intervalMs = now.difference(_lastPacketArrivalTime!).inMicroseconds / 1000.0;
      _addArrivalInterval(intervalMs);
    }
    _lastPacketArrivalTime = now;

    notifyListeners();
  }

  void _addArrivalInterval(double intervalMs) {
    _arrivalIntervals.addLast(intervalMs);
    while (_arrivalIntervals.length > _maxIntervalHistory) {
      _arrivalIntervals.removeFirst();
    }

    if (_arrivalIntervals.length >= 2) {
      // Calculate mean interval
      double sum = 0.0;
      for (final val in _arrivalIntervals) {
        sum += val;
      }
      final mean = sum / _arrivalIntervals.length;

      // Calculate variance
      double sumSq = 0.0;
      for (final val in _arrivalIntervals) {
        final diff = val - mean;
        sumSq += diff * diff;
      }
      _jitterVariance = sumSq / _arrivalIntervals.length;

      // RFC 3550 style smoothed deviation from expected step (~40ms audio frames)
      final d = (intervalMs - 40.0).abs();
      _smoothedJitterMs += (d - _smoothedJitterMs) / 16.0;
    }
  }

  /// Manually overrides loss rate for testing or simulation purposes.
  @visibleForTesting
  void setLossRateForTesting(double lossRate) {
    _currentLossRate = lossRate.clamp(0.0, 1.0);
    notifyListeners();
  }

  /// Manually overrides smoothed jitter metric for testing.
  @visibleForTesting
  void setJitterForTesting(double jitterMs) {
    _smoothedJitterMs = jitterMs.clamp(0.0, 500.0);
    notifyListeners();
  }

  /// Manually sets network connectivity status for testing.
  @visibleForTesting
  void setNetworkConnectedForTesting(bool connected) {
    final changed = _isNetworkConnected != connected;
    _isNetworkConnected = connected;
    if (changed && connected) {
      onNetworkRestored();
    }
    notifyListeners();
  }

  // ------------------------------------------------ Forward Error Correction (FEC)
  /// Encodes an outgoing audio chunk.
  /// If [forceFec] is true or [currentLossRate] > 0.15 (15%), dual audio chunks are encoded
  /// into the packet (current frame + previous frame redundant backup).
  ResilientVoicePacket encodeOutgoingFrame(
    Uint8List currentFrame, {
    int? sequenceNumber,
    bool? forceFec,
  }) {
    final seq = sequenceNumber ?? _outgoingSeq++;
    final enableFec = forceFec ?? (_currentLossRate > 0.15);

    final hasRedundant = enableFec && _lastOutgoingFrame != null;
    final packet = ResilientVoicePacket(
      sequenceNumber: seq,
      primaryAudio: currentFrame,
      hasFec: hasRedundant,
      redundantSequenceNumber: hasRedundant ? seq - 1 : null,
      redundantAudio: hasRedundant ? _lastOutgoingFrame : null,
    );

    _lastOutgoingFrame = currentFrame;
    return packet;
  }

  /// Receives and inspects sequence numbers of incoming packets:
  /// - If packet N is lost, but packet N+1 arrives, extracts packet N's redundant payload
  ///   and outputs it first without any gap!
  /// - If unrecoverable gap remains, generates PLC frames.
  /// - Returns the ordered list of audio frames to be queued or played immediately.
  List<Uint8List> processIncomingPacket(ResilientVoicePacket packet) {
    recordPacketReceived(sequenceNumber: packet.sequenceNumber, arrivalTime: packet.timestamp);

    final outputFrames = <Uint8List>[];

    _expectedPlayoutSeq ??= packet.sequenceNumber;

    if (packet.sequenceNumber == _expectedPlayoutSeq) {
      // In-order packet arrival
      outputFrames.add(packet.primaryAudio);
      _lastGoodPlayoutFrame = packet.primaryAudio;
      _expectedPlayoutSeq = packet.sequenceNumber + 1;
      _consecutiveLostPlayoutFrames = 0;
    } else if (packet.sequenceNumber > _expectedPlayoutSeq!) {
      // Packet gap detected: iterate missing sequence numbers
      while (_expectedPlayoutSeq! < packet.sequenceNumber) {
        final missingSeq = _expectedPlayoutSeq!;
        if (packet.hasFec &&
            packet.redundantSequenceNumber == missingSeq &&
            packet.redundantAudio != null &&
            packet.redundantAudio!.isNotEmpty) {
          // Reconstructed via Forward Error Correction (FEC)
          outputFrames.add(packet.redundantAudio!);
          _lastGoodPlayoutFrame = packet.redundantAudio!;
          _totalFecRecoveries++;
          _expectedPlayoutSeq = missingSeq + 1;
          _consecutiveLostPlayoutFrames = 0;
        } else {
          // Both primary and redundant packet were lost: apply Packet Loss Concealment (PLC)
          _consecutiveLostPlayoutFrames++;
          final plcFrame = generatePlcFrame(
            lastGoodFrame: _lastGoodPlayoutFrame,
            consecutiveLostFrames: _consecutiveLostPlayoutFrames,
          );
          outputFrames.add(plcFrame);
          _lastGoodPlayoutFrame = plcFrame;
          _totalPlcConcealments++;
          _expectedPlayoutSeq = missingSeq + 1;
        }
      }

      // Now append the current packet's primary audio
      outputFrames.add(packet.primaryAudio);
      _lastGoodPlayoutFrame = packet.primaryAudio;
      _expectedPlayoutSeq = packet.sequenceNumber + 1;
      _consecutiveLostPlayoutFrames = 0;
    } else {
      // Duplicate or late packet arrived after playout window; drop safely.
    }

    for (final frame in outputFrames) {
      onAudioFrameReady?.call(frame);
    }

    return outputFrames;
  }

  // ---------------------------------------- Packet Loss Concealment (PLC) Engine
  /// Generates smooth comfort silence or pitch-decayed interpolation when a packet
  /// is completely missing and cannot be recovered via FEC.
  ///
  /// Prevents loud digital screeching, edge clicks, or robotic buzzing.
  Uint8List generatePlcFrame({
    Uint8List? lastGoodFrame,
    int frameSizeBytes = 1280, // Default 40ms frame at 16kHz mono 16-bit PCM
    int consecutiveLostFrames = 1,
  }) {
    final frame = Uint8List(frameSizeBytes);
    final outData = ByteData.sublistView(frame);
    final sampleCount = frameSizeBytes ~/ 2;

    if (lastGoodFrame != null && lastGoodFrame.length >= frameSizeBytes && consecutiveLostFrames <= 3) {
      // Waveform extrapolation with pitch-decayed interpolation
      final inData = ByteData.sublistView(lastGoodFrame);
      final decay = math.pow(0.78, consecutiveLostFrames).toDouble();
      final crossfadeWindow = math.min(32, sampleCount ~/ 4);

      for (var i = 0; i < sampleCount; i++) {
        final rawSample = inData.getInt16(i * 2, Endian.little);
        double sample = rawSample * decay;

        // Apply smooth Hann window crossfade at boundary to avoid digital edge pop
        if (i < crossfadeWindow) {
          final factor = 0.5 * (1.0 - math.cos(math.pi * i / crossfadeWindow));
          sample *= factor;
        }

        // Add subtle low-level comfort dither (-55 dBFS)
        final dither = (math.Random().nextInt(15) - 7);
        final clamped = (sample + dither).round().clamp(-32768, 32767);
        outData.setInt16(i * 2, clamped, Endian.little);
      }
    } else {
      // Comfort silence generation: gentle room/wind background dither
      // Prevents dead-air pop and digital clipping
      double prevNoise = 0.0;
      final rampWindow = math.min(32, sampleCount ~/ 4);

      for (var i = 0; i < sampleCount; i++) {
        // Pseudo-random low-amplitude acoustic presence (-50 to -60 dBFS)
        final rawNoise = (math.Random().nextInt(31) - 15).toDouble();
        // 1-pole low-pass smoothing filter: y[n] = 0.85*y[n-1] + 0.15*x[n]
        prevNoise = 0.85 * prevNoise + 0.15 * rawNoise;

        double sample = prevNoise;
        if (i < rampWindow) {
          sample *= (i / rampWindow);
        }

        outData.setInt16(i * 2, sample.round().clamp(-32768, 32767), Endian.little);
      }
    }

    return frame;
  }

  // ------------------------------------ Voice Memo / Store-and-Forward Burst Mode
  /// Records a chunk of outgoing speech during transmission.
  /// If loss exceeds 50% or network disconnects during transmission:
  /// - Automatically stores the complete 3-5s voice burst locally.
  /// - Triggers transmission as soon as network signal is restored.
  void recordBurstChunk(Uint8List chunk, {String channel = 'ALL', String? targetUserId}) {
    _activeBurstStartTime ??= DateTime.now();
    _activeBurstBuffer.add(chunk);

    // Limit active buffer to ~5 seconds of 16kHz mono audio (160,000 bytes)
    const maxBurstBytes = 160000;
    if (_activeBurstBuffer.length > maxBurstBytes) {
      final all = _activeBurstBuffer.takeBytes();
      final trimmed = Uint8List.sublistView(all, all.length - maxBurstBytes);
      _activeBurstBuffer.add(trimmed);
    }

    // Condition: severe mountain packet loss (> 50%) or network disconnect
    if (_currentLossRate > 0.50 || !_isNetworkConnected) {
      _saveCurrentBurstLocally(channel: channel, targetUserId: targetUserId);
    }
  }

  void _saveCurrentBurstLocally({String channel = 'ALL', String? targetUserId, bool force = false}) {
    if (!force && _activeBurstBuffer.length < 6400) {
      // Less than 200ms of audio; wait for sufficient speech content
      return;
    }
    if (_activeBurstBuffer.isEmpty) return;

    final bytes = _activeBurstBuffer.takeBytes();
    final durationMs = (bytes.length / (16000 * 2)) * 1000;
    final burst = VoiceMemoBurst(
      id: 'burst_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(9999)}',
      recordedAt: _activeBurstStartTime ?? DateTime.now(),
      duration: Duration(milliseconds: durationMs.round()),
      audioData: bytes,
      isHighPriority: true,
      channel: channel,
      targetUserId: targetUserId,
    );

    _storedBursts.add(burst);
    _isBurstModeActive = true;
    _activeBurstStartTime = null;
    notifyListeners();
  }

  /// Manually commits and stores the current transmission as a burst.
  void commitActiveBurst({String channel = 'ALL', String? targetUserId}) {
    _saveCurrentBurstLocally(channel: channel, targetUserId: targetUserId, force: true);
  }

  /// Called as soon as network signal is restored.
  /// Transmits the compressed stored bursts via WebSocket or HTTP binary burst with high priority.
  Future<int> onNetworkRestored() async {
    if (_storedBursts.isEmpty) return 0;

    int deliveredCount = 0;
    final burstsToSend = List<VoiceMemoBurst>.from(_storedBursts);

    for (final burst in burstsToSend) {
      final success = await _transmitBurst(burst);
      if (success) {
        _storedBursts.remove(burst);
        deliveredCount++;
      }
    }

    if (_storedBursts.isEmpty) {
      _isBurstModeActive = false;
    }
    notifyListeners();
    return deliveredCount;
  }

  Future<bool> _transmitBurst(VoiceMemoBurst burst) async {
    // 1. External burst delivery callback
    if (onTransmitBurst != null) {
      try {
        final ok = await onTransmitBurst!(burst);
        if (ok) return true;
      } catch (e) {
        debugPrint('Custom burst transmit note: $e');
      }
    }

    // 2. Transmit via RealtimeService WebSocket binary burst
    if (_rt != null && _rt.isConnected) {
      try {
        // Compress the audio burst payload using gzip
        Uint8List compressed;
        if (!kIsWeb) {
          compressed = Uint8List.fromList(gzip.encode(burst.audioData));
        } else {
          compressed = burst.audioData;
        }

        final header = <String, dynamic>{
          'type': 'VOICE_BURST',
          'burstId': burst.id,
          'priority': true,
          'compressed': !kIsWeb,
          'durationMs': burst.duration.inMilliseconds,
          'sampleRate': burst.sampleRate,
          'channel': burst.channel,
          if (burst.targetUserId != null) 'to': burst.targetUserId,
        };

        _rt.sendVoice(VoiceKind.frame, header, compressed);
        return true;
      } catch (e) {
        debugPrint('Realtime burst transmit note: $e');
        return false;
      }
    }

    return false;
  }

  // ------------------------- 1-Tap Zero-Bandwidth Tactical Canned Signals
  /// Sends an ultra-compact 12-byte packet for instantaneous zero-bandwidth signalling.
  ///
  /// Packets:
  /// - Byte 0: Magic byte 0x7E
  /// - Byte 1: Version (4 bits) | Signal ID (4 bits)
  /// - Bytes 2-5: uint32 Unix timestamp (seconds)
  /// - Bytes 6-9: uint32 Sender Hash
  /// - Byte 10: Flags (0x01 = High Priority Tactical Command)
  /// - Byte 11: uint8 XOR Checksum
  ///
  /// Receivers trigger local text-to-speech ([VoiceService]) speaking the tactical command
  /// aloud directly into teammates' helmet headsets without requiring audio bandwidth!
  Future<bool> sendTacticalSignal(TacticalSignal signal, {String? senderId}) async {
    final packet = encodeTacticalSignalPacket(signal, senderId: senderId);

    if (_rt != null && _rt.isConnected) {
      final header = <String, dynamic>{
        'type': 'TACTICAL_SIGNAL',
        'signal': signal.name,
        'priority': true,
      };
      _rt.sendVoice(VoiceKind.frame, header, packet);
      return true;
    }

    return false;
  }

  /// Encodes a 12-byte tactical canned signal packet.
  static Uint8List encodeTacticalSignalPacket(
    TacticalSignal signal, {
    String? senderId,
    DateTime? timestamp,
  }) {
    final packet = Uint8List(tacticalPacketSize);
    final bd = ByteData.sublistView(packet);
    final timeSec = ((timestamp ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) & 0xFFFFFFFF;
    final senderHash = (senderId?.hashCode ?? 0) & 0xFFFFFFFF;

    packet[0] = tacticalMagicByte;
    packet[1] = ((tacticalVersion & 0x0F) << 4) | (signal.id & 0x0F);
    bd.setUint32(2, timeSec, Endian.big);
    bd.setUint32(6, senderHash, Endian.big);
    packet[10] = 0x01; // High priority flag

    // Calculate XOR checksum over bytes 0 through 10
    int checksum = 0;
    for (var i = 0; i < 11; i++) {
      checksum ^= packet[i];
    }
    packet[11] = checksum & 0xFF;

    return packet;
  }

  /// Decodes and validates a 12-byte tactical canned signal packet.
  /// Returns `null` if the packet is corrupted, wrong size, or fails checksum.
  static TacticalSignal? decodeTacticalSignalPacket(Uint8List packet) {
    if (packet.length != tacticalPacketSize) return null;
    if (packet[0] != tacticalMagicByte) return null;

    int checksum = 0;
    for (var i = 0; i < 11; i++) {
      checksum ^= packet[i];
    }
    if (packet[11] != (checksum & 0xFF)) return null;

    final signalId = packet[1] & 0x0F;
    return TacticalSignal.fromId(signalId);
  }

  /// Processes an incoming tactical packet: decodes the signal and immediately triggers
  /// local Text-To-Speech ([VoiceService]) into teammate helmet headsets.
  Future<bool> processIncomingTacticalPacket(Uint8List packet, {String? senderId}) async {
    final signal = decodeTacticalSignalPacket(packet);
    if (signal == null) return false;

    _tacticalStreamController.add(
      TacticalSignalEvent(
        signal: signal,
        timestamp: DateTime.now(),
        senderId: senderId,
      ),
    );

    if (_voice != null) {
      await _voice.speak(
        signal.spokenPhrase,
        priority: VoicePriority.critical,
        key: 'tactical_${signal.name}_${DateTime.now().millisecondsSinceEpoch ~/ 3000}',
      );
    }

    notifyListeners();
    return true;
  }

  void _handleIncomingVoicePacket(VoicePacket p) {
    // Check for tactical signal packet
    if (p.header['type'] == 'TACTICAL_SIGNAL' ||
        (p.payload.length == tacticalPacketSize && p.payload[0] == tacticalMagicByte)) {
      processIncomingTacticalPacket(p.payload, senderId: p.from);
      return;
    }

    // Process resilient voice packet
    if (p.kind == VoiceKind.frame && p.payload.isNotEmpty) {
      final resilientPacket = ResilientVoicePacket.fromBinary(
        p.payload,
        defaultSeq: (p.header['seq'] as num?)?.toInt() ?? 0,
      );
      processIncomingPacket(resilientPacket);
    }
  }

  /// Resets all metrics and buffers (e.g. at ride end or leaving convoy).
  void reset() {
    _totalPacketsExpected = 0;
    _totalPacketsReceived = 0;
    _currentLossRate = 0.0;
    _lastReceivedSeq = null;
    _totalFecRecoveries = 0;
    _totalPlcConcealments = 0;
    _smoothedJitterMs = 0.0;
    _jitterVariance = 0.0;
    _arrivalIntervals.clear();
    _lastPacketArrivalTime = null;

    _outgoingSeq = 0;
    _lastOutgoingFrame = null;
    _expectedPlayoutSeq = null;
    _lastGoodPlayoutFrame = null;
    _consecutiveLostPlayoutFrames = 0;

    _activeBurstBuffer.clear();
    _activeBurstStartTime = null;
    _storedBursts.clear();
    _isBurstModeActive = false;

    notifyListeners();
  }

  @override
  void dispose() {
    _rtVoiceSub?.cancel();
    if (_rt != null) {
      _rt.removeListener(_onRealtimeStateChanged);
    }
    _tacticalStreamController.close();
    super.dispose();
  }
}
