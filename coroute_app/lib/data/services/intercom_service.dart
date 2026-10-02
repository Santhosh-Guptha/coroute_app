import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';
import '../../core/config/app_config.dart';
import 'realtime_service.dart';

enum IntercomMode { ptt, vox }

/// Live voice intercom over the gateway WebSocket.
///
/// Sender: microphone → PCM16 16 kHz mono stream → 40 ms binary frames → gateway.
/// Receiver: gateway → jitter buffer → PCM playback.  End-to-end latency is the
/// network round trip plus ~100 ms of buffering, instead of the former
/// record-file → base64 → database → poll cycle that took several seconds.
///
/// * Group talk ("Everyone") or private 1:1 talk ([talkTargetUserId]).
/// * PTT (hold to talk) or VOX (open mic that only transmits while you speak,
///   so the radio stays idle — and the battery lasts — while you are quiet).
/// * Mute (don't transmit) and Deafen (don't play) switches.
class IntercomService extends ChangeNotifier {
  IntercomService(this._rt) {
    _voiceSub = _rt.voice.listen(_onVoicePacket);
    _eventSub = _rt.events.listen(_onEvent);
  }

  final RealtimeService _rt;
  AudioRecorder? _recorderInstance;
  // Created on first use so constructing the service never touches the platform (keeps tests and web safe).
  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();
  StreamSubscription<VoicePacket>? _voiceSub;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  StreamSubscription<Uint8List>? _micSub;

  // ---- transmit state ----
  bool _micMuted = false;
  bool _deafened = false;
  bool _transmitting = false; // a stream is open to the gateway
  bool _micOpen = false; // recorder is running (VOX keeps it open)
  IntercomMode _mode = IntercomMode.ptt;
  String? _talkTargetUserId; // null == everyone
  String? _talkTargetName;
  int _seq = 0;
  final BytesBuilder _pending = BytesBuilder(copy: false);
  Timer? _voxSilenceTimer;
  DateTime? _txStartedAt;
  String? _busyWith;
  Timer? _busyTimer;

  // ---- receive state ----
  bool _playerReady = false;
  String? _activeStreamId;
  String? _activeSpeakerId;
  String? _activeSpeakerName;
  bool _activeIsPrivate = false;
  DateTime _lastRxAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _rxIdleTimer;
  final Queue<Uint8List> _jitter = Queue<Uint8List>();
  int _queuedBytes = 0;
  bool _draining = false;

  // ---- public getters ----
  bool get isMicMuted => _micMuted;
  bool get isDeafened => _deafened;
  bool get isTransmitting => _transmitting;
  bool get isVoxArmed => _mode == IntercomMode.vox && _micOpen;
  IntercomMode get mode => _mode;
  String? get talkTargetUserId => _talkTargetUserId;
  String? get talkTargetName => _talkTargetName;
  bool get isPrivateTalk => _talkTargetUserId != null;
  String? get activeSpeakerName => _activeSpeakerName;
  String? get activeSpeakerId => _activeSpeakerId;
  bool get activeSpeakerIsPrivate => _activeIsPrivate;
  bool get isReceiving => _activeSpeakerName != null;
  String? get busyWith => _busyWith;
  bool get isOnline => _rt.isConnected;

  // ---------------------------------------------------------------- config
  void setMode(IntercomMode m) {
    if (_mode == m) return;
    if (_mode == IntercomMode.vox) stopVox();
    _mode = m;
    notifyListeners();
  }

  /// Choose who hears you: `null` for everyone, or a rider's userId.
  void setTalkTarget({String? userId, String? name}) {
    if (_transmitting) endTransmission();
    _talkTargetUserId = (userId == null || userId.isEmpty) ? null : userId;
    _talkTargetName = _talkTargetUserId == null ? null : name;
    notifyListeners();
  }

  void setMicMuted(bool v) {
    _micMuted = v;
    if (v) {
      if (_transmitting) endTransmission();
      if (_mode == IntercomMode.vox) stopVox();
    }
    notifyListeners();
  }

  void setDeafened(bool v) {
    _deafened = v;
    if (v) _resetPlayback(clearSpeaker: true);
    notifyListeners();
  }

  // ------------------------------------------------------------- transmit
  Future<bool> _ensurePermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// PTT: call on press. Opens the mic and a stream to the chosen target.
  Future<bool> beginTransmission() async {
    if (_micMuted || _transmitting || !_rt.isConnected) return false;
    if (!await _ensurePermission()) return false;
    if (!await _openMic()) return false;
    _startStream();
    return true;
  }

  /// PTT: call on release.
  Future<void> endTransmission() async {
    if (_transmitting) _endStream();
    if (_mode == IntercomMode.ptt) await _closeMic();
  }

  /// VOX: arm the open mic. Transmits only while sound exceeds the threshold.
  Future<bool> startVox() async {
    if (_micMuted || !_rt.isConnected) return false;
    if (!await _ensurePermission()) return false;
    _mode = IntercomMode.vox;
    final ok = await _openMic();
    notifyListeners();
    return ok;
  }

  Future<void> stopVox() async {
    _voxSilenceTimer?.cancel();
    if (_transmitting) _endStream();
    await _closeMic();
    notifyListeners();
  }

  Future<bool> _openMic() async {
    if (_micOpen) return true;
    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: AppConfig.audioSampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ));
      _micOpen = true;
      _micSub = stream.listen(_onMicData, onError: (e) => debugPrint('mic error: $e'), onDone: () => _micOpen = false);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Intercom mic open note: $e');
      _micOpen = false;
      return false;
    }
  }

  Future<void> _closeMic() async {
    _micSub?.cancel();
    _micSub = null;
    _micOpen = false;
    _pending.clear();
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
    notifyListeners();
  }

  void _startStream() {
    _seq = 0;
    _transmitting = true;
    _txStartedAt = DateTime.now();
    _rt.sendVoice(VoiceKind.start, {
      'to': _talkTargetUserId,
      'sampleRate': AppConfig.audioSampleRate,
      'codec': 'pcm16',
    });
    notifyListeners();
  }

  void _endStream() {
    _transmitting = false;
    _pending.clear();
    _rt.sendVoice(VoiceKind.end, {'to': _talkTargetUserId});
    notifyListeners();
  }

  // VOX tuning
  static const double _voxOpenRms = 0.045; // ~ -27 dBFS: normal speech into a helmet mic
  static const Duration _voxHangover = Duration(milliseconds: 900);
  static const int _txFrameBytes = AppConfig.audioFrameBytes * 2; // 40 ms

  void _onMicData(Uint8List chunk) {
    if (!_micOpen || _micMuted) return;

    if (_mode == IntercomMode.vox) {
      final rms = _rms(chunk);
      if (rms >= _voxOpenRms) {
        if (!_transmitting && _rt.isConnected) _startStream();
        _voxSilenceTimer?.cancel();
        _voxSilenceTimer = Timer(_voxHangover, () {
          if (_transmitting) _endStream();
        });
      }
      if (!_transmitting) return;
    } else if (!_transmitting) {
      return;
    }

    // Guard: streams longer than the gateway allows are cut off server-side.
    if (_txStartedAt != null && DateTime.now().difference(_txStartedAt!).inMilliseconds > 55000) {
      _endStream();
      return;
    }

    _pending.add(chunk);
    while (_pending.length >= _txFrameBytes) {
      final all = _pending.takeBytes();
      final frame = Uint8List.sublistView(all, 0, _txFrameBytes);
      if (all.length > _txFrameBytes) _pending.add(Uint8List.sublistView(all, _txFrameBytes));
      _rt.sendVoice(VoiceKind.frame, {'to': _talkTargetUserId, 'seq': _seq++}, frame);
    }
  }

  static double _rms(Uint8List pcm) {
    final n = pcm.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.sublistView(pcm, 0, n * 2);
    double acc = 0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
      acc += s * s;
    }
    return math.sqrt(acc / n);
  }

  // -------------------------------------------------------------- receive
  Future<void> _ensurePlayer(int sampleRate) async {
    if (_playerReady) return;
    try {
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
      // Ask for more data when < 60 ms is left; we top up from the jitter buffer.
      await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 16);
      FlutterPcmSound.setFeedCallback(_onFeed);
      _playerReady = true;
    } catch (e) {
      debugPrint('Intercom player setup note: $e');
    }
  }

  void _onFeed(int remainingFrames) {
    _drain();
  }

  Future<void> _drain() async {
    if (_draining || !_playerReady) return;
    _draining = true;
    try {
      // Feed up to ~200 ms at a time so the native buffer stays small (low latency).
      var budget = AppConfig.audioFrameBytes * 10;
      while (_jitter.isNotEmpty && budget > 0) {
        final bytes = _jitter.removeFirst();
        _queuedBytes -= bytes.length;
        budget -= bytes.length;
        final even = bytes.length & ~1;
        if (even == 0) continue;
        final copy = Uint8List.fromList(bytes.sublist(0, even)); // aligned copy
        await FlutterPcmSound.feed(PcmArrayInt16.fromList(Int16List.view(copy.buffer, 0, even ~/ 2)));
      }
    } catch (e) {
      debugPrint('Intercom feed note: $e');
    } finally {
      _draining = false;
    }
  }

  void _onVoicePacket(VoicePacket p) {
    if (_deafened) return;
    switch (p.kind) {
      case VoiceKind.start:
        // One speaker at a time: a newer group stream pre-empts; private calls win.
        if (_activeStreamId != null && _activeStreamId != p.streamId && !p.isPrivate && !_rxStale()) return;
        _activeStreamId = p.streamId;
        _activeSpeakerId = p.from;
        _activeSpeakerName = p.fromName;
        _activeIsPrivate = p.isPrivate;
        _jitter.clear();
        _queuedBytes = 0;
        _lastRxAt = DateTime.now();
        _ensurePlayer(p.sampleRate);
        notifyListeners();
        break;
      case VoiceKind.frame:
        if (p.streamId != _activeStreamId) {
          // Frames of a stream we never saw START for (e.g. joined mid-sentence).
          if (_activeStreamId != null && !_rxStale()) return;
          _activeStreamId = p.streamId;
          _activeSpeakerId = p.from;
          _activeSpeakerName = p.fromName;
          _activeIsPrivate = p.isPrivate;
          _ensurePlayer(p.sampleRate);
          notifyListeners();
        }
        _lastRxAt = DateTime.now();
        if (p.payload.isEmpty) return;
        // Cap the jitter buffer at ~600 ms; drop the oldest to keep latency bounded.
        _jitter.addLast(Uint8List.fromList(p.payload));
        _queuedBytes += p.payload.length;
        while (_queuedBytes > AppConfig.audioFrameBytes * 30 && _jitter.length > 1) {
          _queuedBytes -= _jitter.removeFirst().length;
        }
        if (_playerReady && _queuedBytes >= AppConfig.audioFrameBytes * 2) {
          _drain();
          try {
            FlutterPcmSound.start(); // primes the feed loop if it had drained
          } catch (_) {}
        }
        _rxIdleTimer?.cancel();
        _rxIdleTimer = Timer(const Duration(milliseconds: 1500), () => _resetPlayback(clearSpeaker: true));
        break;
      case VoiceKind.end:
        if (p.streamId == _activeStreamId) {
          _rxIdleTimer?.cancel();
          // Let the buffered tail play out, then clear the "speaking" badge.
          _rxIdleTimer = Timer(const Duration(milliseconds: 400), () => _resetPlayback(clearSpeaker: true));
        }
        break;
    }
  }

  bool _rxStale() => DateTime.now().difference(_lastRxAt).inMilliseconds > 1500;

  void _resetPlayback({required bool clearSpeaker}) {
    _jitter.clear();
    _queuedBytes = 0;
    if (clearSpeaker) {
      _activeStreamId = null;
      _activeSpeakerId = null;
      _activeSpeakerName = null;
      _activeIsPrivate = false;
      notifyListeners();
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    if (e['type'] == 'VOICE_BUSY') {
      _busyWith = e['speaker']?.toString() ?? 'another rider';
      if (_transmitting) _endStream();
      _busyTimer?.cancel();
      _busyTimer = Timer(const Duration(seconds: 2), () {
        _busyWith = null;
        notifyListeners();
      });
      notifyListeners();
    } else if (e['type'] == 'RIDER_LEFT' && e['userId'] == _talkTargetUserId) {
      setTalkTarget(); // our private partner left → back to everyone
    } else if (e['type'] == 'DISSOLVED' || e['type'] == 'LEFT') {
      reset();
    }
  }

  /// Called when leaving a convoy: nothing may carry over to the next group.
  Future<void> reset() async {
    _voxSilenceTimer?.cancel();
    if (_transmitting) _endStream();
    await _closeMic();
    _talkTargetUserId = null;
    _talkTargetName = null;
    _resetPlayback(clearSpeaker: true);
  }

  @override
  void dispose() {
    _voiceSub?.cancel();
    _eventSub?.cancel();
    _micSub?.cancel();
    _voxSilenceTimer?.cancel();
    _rxIdleTimer?.cancel();
    _busyTimer?.cancel();
    _recorderInstance?.dispose();
    if (_playerReady) FlutterPcmSound.release();
    super.dispose();
  }
}
