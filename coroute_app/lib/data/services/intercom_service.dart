import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';
import '../../core/config/app_config.dart';
import '../../core/config/feature_gates.dart';
import '../../domain/audio/dsp_core.dart';
import '../../domain/audio/voice_clarity.dart';
import '../../domain/audio/voice_cleanup.dart';
import '../../domain/audio/voice_codec_policy.dart';
import '../../domain/audio/voice_jitter.dart';
import '../../domain/diag/diag_log.dart'; // 3.55 diagnostics log (no personal data)
import 'background_service.dart';
import 'realtime_service.dart';
import 'ride_mic_hub.dart';
import 'settings_service.dart';
import 'voice/voice_codec.dart';
import 'voice/voice_link.dart';
import 'voice/voice_native.dart';

enum IntercomMode { ptt, vox }

enum IntercomChannel { all, leadOnly }

/// Metadata describing an active incoming voice speaker.
class ActiveSpeakerInfo {
  final String speakerName;
  final String? speakerId;
  final bool isLead;
  final bool isEmergency;
  final DateTime timestamp;

  ActiveSpeakerInfo({
    required this.speakerName,
    this.speakerId,
    this.isLead = false,
    this.isEmergency = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActiveSpeakerInfo &&
          runtimeType == other.runtimeType &&
          speakerName == other.speakerName &&
          speakerId == other.speakerId &&
          isLead == other.isLead &&
          isEmergency == other.isEmergency &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(speakerName, speakerId, isLead, isEmergency, timestamp);

  @override
  String toString() =>
      'ActiveSpeakerInfo(id: $speakerId, name: $speakerName, isLead: $isLead, isEmergency: $isEmergency, at: $timestamp)';
}

/// Live voice intercom over the gateway WebSocket.
///
/// Sender: microphone → PCM16 mono stream (16 kHz, or 8 kHz in data saver mode, half the
/// data) → 40 ms binary frames → gateway. The START header carries the rate, so every
/// receiver plays every sender at the right speed.
/// Receiver: gateway → jitter buffer → PCM playback.  End-to-end latency is the
/// network round trip plus ~100 ms of buffering, instead of the former
/// record-file → base64 → database → poll cycle that took several seconds.
///
/// * Group talk ("Everyone") or private 1:1 talk ([talkTargetUserId]).
/// * PTT (hold to talk) or VOX (open mic that only transmits while you speak,
///   so the radio stays idle, and the battery lasts, while you are quiet).
/// * Mute (don't transmit) and Deafen (don't play) switches.
///
/// 3.55 sound awareness (docs/features_355/sound_awareness_and_intercom.md):
/// * With [micHub] set (main.dart) the intercom does not open its own recorder: it claims the
///   ride's one shared microphone ([RideMicHub]), which the siren detector also listens to.
/// * "Clean up my voice" (setting `voiceCleanup`, admin switch 'voiceCleanup', both default on):
///   every frame goes through [VoiceCleanup] before it is sent (high-pass, noise suppression,
///   breath and wind-gust suppression, AGC + limiter). In hands-free (VOX) the voice gate decides
///   when to send: it opens on voiced speech only (never on breath or wind) and holds 500 ms; the
///   first 40 ms before it opened are sent too (pre-roll). Nothing is sent while the gate is shut.
///   Off = raw frames and the old loudness VOX.
/// * Received voice goes through a light peak limiter, so one loud rider does not blast.
///
/// Round 8 voice clarity (docs/features_355/voice_clarity.md):
/// * Noise reduction (Intercom options: Strong default / Normal / Off): the native RNNoise stage
///   (libcoroute_voice via dart:ffi: 120 Hz high-pass, RNNoise, wind-gust ducker) runs before [VoiceCleanup],
///   which then keeps only the voice gate, breath cut, AGC and limiter ([VoiceChainPlan]). Without the native
///   library the 3.55 pure-Dart chain runs as before.
/// * Opus (MediaCodec, [OpusTx] / [OpusRx]) when the gateway says the whole group can receive it (VOICE_CODEC)
///   and this phone has the encoder; otherwise PCM16 as before. A refused Opus START restarts the talk in PCM.
/// * Receive: adaptive jitter buffer (40-120 ms), loss concealment and drift control ([VoiceJitterBuffer]).
/// * Process-mode gateway: voice goes over a separate socket ([VoiceLink]) when the gateway hands out a ticket.
///
/// Public actions for notification buttons / remotes (names are stable):
/// * [toggleHandsFreeTalk] - hands-free talk on / off (arms or disarms VOX);
/// * [toggleGroupMute] - stop / resume hearing the group (deafen);
/// * [setMicMuted], [beginTransmission] / [endTransmission], [startVox] / [stopVox] as before.
/// Both toggles work with the screen locked: the ride's foreground service runs with the
/// microphone type once the mic was allowed during the ride (BackgroundService).
class IntercomService extends ChangeNotifier with WidgetsBindingObserver {
  IntercomService(
    this._rt, {
    this.settings,
    bool isRoadCaptain = false,
    String? userRole,
    AudioRecorder? recorder,
  })  : _myRole = userRole,
        _recorderInstance = recorder,
        _isRoadCaptain = isRoadCaptain || userRole == 'LEAD' {
    _voiceSub = _rt.voice.listen(_onVoicePacket);
    _eventSub = _rt.events.listen(_onEvent);
    _setupHardwareKeyboard();
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    // 3.55 fix: Data saver changed mid-ride. The rate is picked when the mic opens, and hands-free
    // (VOX) keeps the mic open for the whole ride, so the change waited for the next ride.
    settings?.addListener(_onSettingsChanged);
  }

  /// 3.55 fix: re-opens a VOX mic that is idle (not sending) at the rate Data saver now asks for.
  /// A burst in progress finishes first; the hangover end re-checks (see [_onMicData]).
  void _onSettingsChanged() {
    if (_disposed) return;
    _applyMicRate();
  }

  void _applyMicRate() {
    if (_disposed || !_micOpen || _transmitting || _mode != IntercomMode.vox || _micRate == _rateFor(_txCodec)) return;
    if (micHub != null) {
      // The shared mic always records at 16 kHz; data saver only changes what is sent (Opus stays 16 kHz).
      _micRate = _rateFor(_txCodec);
      _decimator = null;
      return;
    }
    _closeMic().then((_) {
      if (!_disposed && _mode == IntercomMode.vox && !_micMuted && !_microphoneRevoked && _talkSwitchOn) _openMic();
    }).ignore();
  }

  /// 3.55 fix: the admin turned the 'intercom' switch off during a ride (FEATURE_FLAGS push). Before,
  /// only a new talk was refused: a PTT held down or an armed VOX mic kept sending. Called from
  /// main.dart as a FeatureFlagsService listener.
  void featureSwitchesChanged() {
    if (_disposed || _talkSwitchOn) return;
    if (_transmitting) _endStream();
    if (_micOpen) _closeMic().ignore();
    if (_mode == IntercomMode.vox) {
      _voxSilenceTimer?.cancel();
      _mode = IntercomMode.ptt;
    }
    notifyListeners();
  }

  final RealtimeService _rt;

  /// Data saver setting (optional so the service also works without it, as in tests).
  final SettingsService? settings;

  /// Microphone audio level [0.0 .. 1.0] for live VU metering.
  final ValueNotifier<double> audioLevel = ValueNotifier<double>(0.0);

  /// Active speaker notification stream for cockpit HUDs and visual fallbacks.
  final ValueNotifier<ActiveSpeakerInfo?> activeSpeakerNotifier =
      ValueNotifier<ActiveSpeakerInfo?>(null);

  /// Rate the next transmission uses.
  int get txSampleRate => AppConfig.sampleRateFor(settings?.lowData ?? false);
  AudioRecorder? _recorderInstance;
  // Created on first use so constructing the service never touches the platform (keeps tests and web safe).
  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();

  @visibleForTesting
  set recorder(AudioRecorder rec) {
    _recorderInstance = rec;
  }
  StreamSubscription<VoicePacket>? _voiceSub;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  StreamSubscription<Uint8List>? _micSub;

  /// Optional listener for raw microphone PCM chunks (e.g. for siren acoustic detection).
  /// Only invoked while microphone capture is legitimately active (PTT or VOX).
  void Function(Uint8List chunk)? onMicChunk;

  /// 3.55: the ride's one shared microphone (set in main.dart). Null = own recorder (tests, old path).
  RideMicHub? micHub;

  /// 3.55 voice cleanup for the frames this phone sends (see the class doc).
  final VoiceCleanup _cleanup = VoiceCleanup();
  Decimator2? _decimator;
  final List<Uint8List> _preRoll = [];
  final PeakLimiter _rxLimiter = PeakLimiter(ceiling: 0.8, releaseDbPerSecond: 6.0);
  bool _appInForeground = true;

  // ---- Round 8 voice clarity / codec / receive path
  /// The native cleanup stage (tests inject a fake or `() => null`). Null result = pure-Dart chain.
  VoiceDenoiser? Function() denoiserFactory = createNativeVoiceDenoiser;
  VoiceDenoiser? _native;
  bool _nativeTried = false;
  int? _nativeMode;
  bool? _nativeWind;
  OpusCaps _opus = OpusCaps.none;
  String? _groupCodec; // last VOICE_CODEC of this group; null = never told (PCM)
  String _txCodec = VoiceCodecs.pcm;
  OpusTx? _opusTx;
  final SerialVoiceSender _tx = SerialVoiceSender();
  final OpusRx _opusRx = OpusRx();
  VoiceJitterBuffer? _jb;
  final Concealer _concealer = Concealer();
  String? _rxCodec;
  int _lastRxSamples = 640;
  VoiceLink? _link;
  bool _txViaLink = false;
  final Stopwatch _clock = Stopwatch()..start();

  /// What the cleanup runs for the current settings (rider choice, admin switch, native library present).
  VoiceChainPlan get voiceChainPlan => VoiceChainPlan.forChoice(
        settings?.noiseReduction ?? NoiseReduction.strong,
        windNoiseMode: settings?.windNoiseMode ?? true,
        adminOn: featureOn?.call('voiceCleanup') ?? true,
        nativeAvailable: _nativeStage() != null,
      );

  /// Codec of the next talk.
  @visibleForTesting
  String get txCodec => _txCodec;
  @visibleForTesting
  String? get groupCodec => _groupCodec;

  VoiceDenoiser? _nativeStage() {
    if (!_nativeTried) {
      _nativeTried = true;
      try {
        _native = denoiserFactory();
      } catch (_) {
        _native = null;
      }
      DiagLog.info(DiagCat.intercom, 'voice_native', {'available': _native != null});
    }
    return _native;
  }

  /// Codec for a talk that starts now: Opus only on the shared mic (16 kHz), when the group allows it and
  /// this phone can encode.
  String _chooseCodec() => micHub == null ? VoiceCodecs.pcm : VoiceCodecs.sendCodec(groupCodec: _groupCodec, opusEncoder: _opus.encoder);

  /// Send rate for [codec]: Opus always encodes 16 kHz (16 kbit/s in data saver), PCM follows data saver.
  int _rateFor(String codec) => codec == VoiceCodecs.opus ? AppConfig.audioSampleRate : txSampleRate;

  /// Voice cleanup on: rider setting AND admin switch 'voiceCleanup' (unknown = on).
  bool get voiceCleanupOn => (settings?.voiceCleanup ?? true) && (featureOn?.call('voiceCleanup') ?? true);

  /// 3.55 admin feature switches (set in main.dart to FeatureFlagsService.on). Null = on. While
  /// 'intercom' is off no new talk starts (the gateway refuses a stream start too).
  bool Function(String id)? featureOn;
  bool get _talkSwitchOn => featureOn?.call('intercom') ?? true;

  // ---- transmit state ----
  bool _micMuted = false;
  bool _deafened = false;
  bool _transmitting = false; // a stream is open to the gateway
  bool _micOpen = false; // recorder is running (VOX keeps it open)
  bool _pausedByPhoneCall = false; // automatically paused when rider receives/makes a phone call
  bool _microphoneRevoked = false;
  bool get isMicrophoneRevoked => _microphoneRevoked;
  IntercomMode _mode = IntercomMode.ptt;
  IntercomChannel _channel = IntercomChannel.all;
  String? _talkTargetUserId; // null == everyone
  String? _talkTargetName;
  int _seq = 0;
  int _micRate = AppConfig.audioSampleRate; // rate the open microphone records at
  final BytesBuilder _pending = BytesBuilder(copy: false);
  Timer? _voxSilenceTimer;
  DateTime? _txStartedAt;
  String? _busyWith;
  Timer? _busyTimer;
  bool _isRoadCaptain = false;
  String? _myRole;

  // ---- receive state ----
  bool _playerReady = false;
  int? _playerRate; // rate the player was set up with
  Future<void>? _playerSetup;
  String? _activeStreamId;
  String? _activeSpeakerId;
  String? _activeSpeakerName;
  bool _activeIsPrivate = false;
  bool _activeIsLead = false;
  bool _isPriorityDucked = false;
  IntercomChannel _activeChannel = IntercomChannel.all;
  DateTime _lastRxAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _rxIdleTimer;
  final Queue<Uint8List> _jitter = Queue<Uint8List>();
  int _queuedBytes = 0;
  bool _draining = false;

  // ---- per-rider states ----
  final Map<String, bool> _speakingRiders = {};
  final Map<String, bool> _mutedRiders = {};
  final Map<String, String> _riderRoles = {};

  // ---- public getters ----
  bool get isMicMuted => _micMuted;
  bool get isDeafened => _deafened;
  bool get isTransmitting => _transmitting;
  bool get isPausedByPhoneCall => _pausedByPhoneCall;
  bool get isVoxArmed => _mode == IntercomMode.vox && _micOpen;
  IntercomMode get mode => _mode;
  IntercomChannel get channel => _channel;
  IntercomChannel get activeChannel => _activeChannel;
  bool get isReceivingLeadOnly => isReceiving && _activeChannel == IntercomChannel.leadOnly;
  String? get talkTargetUserId => _talkTargetUserId;
  String? get talkTargetName => _talkTargetName;
  bool get isPrivateTalk => _talkTargetUserId != null;
  String? get activeSpeakerName => _activeSpeakerName;
  String? get activeSpeakerId => _activeSpeakerId;
  bool get activeSpeakerIsPrivate => _activeIsPrivate;
  bool get activeSpeakerIsLead => _activeIsLead;
  bool get isPriorityDucked => _isPriorityDucked;
  bool get isReceiving => _activeSpeakerName != null;
  String? get busyWith => _busyWith;
  bool get isOnline => _rt.isConnected;
  bool get isRoadCaptain =>
      _isRoadCaptain ||
      _myRole?.toUpperCase() == 'LEAD' ||
      _channel == IntercomChannel.leadOnly;
  String? get myRole => _myRole;

  bool isRiderSpeaking(String uid) => _speakingRiders[uid] == true;
  bool isRiderMuted(String uid) => _mutedRiders[uid] == true;

  void setRoadCaptain(bool value) {
    if (_isRoadCaptain == value) return;
    _isRoadCaptain = value;
    notifyListeners();
  }

  void setIsRoadCaptain(bool value) => setRoadCaptain(value);

  void setUserRole(String? role) {
    if (_myRole == role) return;
    _myRole = role;
    if (role?.toUpperCase() == 'LEAD') {
      _isRoadCaptain = true;
    }
    notifyListeners();
  }

  void setRiderRole(String userId, String role) {
    _riderRoles[userId] = role;
  }

  // ---------------------------------------------------------------- config
  void setMode(IntercomMode m) {
    if (_mode == m) return;
    if (_mode == IntercomMode.vox) stopVox();
    _mode = m;
    notifyListeners();
  }

  void setChannel(IntercomChannel ch) {
    if (_channel == ch) return;
    if (_transmitting) endTransmission();
    _channel = ch;
    notifyListeners();
  }

  /// Choose who hears you: `null` for everyone, or a rider's userId.
  void setTalkTarget({String? userId, String? name}) {
    if (_transmitting) endTransmission();
    _talkTargetUserId = (userId == null || userId.isEmpty) ? null : userId;
    _talkTargetName = _talkTargetUserId == null ? null : name;
    notifyListeners();
  }

  /// 3.55 fix: hands-free was armed when the mic was muted; unmuting arms it again.
  bool _rearmVoxOnUnmute = false;

  /// 3.55: hands-free was armed when a phone call began; re-armed after it ([setPhoneCallActive]).
  bool _rearmVoxAfterCall = false;
  Timer? _rearmAfterCallTimer;

  void setMicMuted(bool v) {
    final wasMuted = _micMuted;
    _micMuted = v;
    if (v) {
      if (!wasMuted) _rearmVoxOnUnmute = isVoxArmed;
      if (_transmitting) endTransmission();
      if (_mode == IntercomMode.vox) stopVox();
      _closeMic();
    }
    _rt.send({'type': 'MIC_STATE', 'muted': v});
    notifyListeners();
    // 3.55 fix: muting (e.g. Quick settings > Voice off) disarmed hands-free and unmuting left it
    // off, so talk did not come back with the switch. It is re-armed when it was armed before.
    if (!v && wasMuted && _rearmVoxOnUnmute) {
      _rearmVoxOnUnmute = false;
      if (_mode == IntercomMode.vox && !_micOpen) startVox().ignore();
    }
  }

  void setDeafened(bool v) {
    _deafened = v;
    if (v) _resetPlayback(clearSpeaker: true);
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // Never maintain a continuous recording session in the background in PTT mode.
      if (_mode == IntercomMode.ptt && (_transmitting || _micOpen)) {
        endTransmission();
      }
    } else if (state == AppLifecycleState.resumed) {
      verifyPermission().ignore();
    }
  }

  // ------------------------------------------------------------- transmit
  Future<bool> _ensurePermission() async {
    try {
      final ok = await _recorder.hasPermission();
      // Allowed during the ride: give the background service the microphone type too.
      // 3.55: only while the app is in front. ensureMicrophoneType restarts the service, and
      // Android 14 refuses to start a microphone service from the background (the ride service
      // would be gone).
      if (ok && _appInForeground) BackgroundService.ensureMicrophoneType().ignore();
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Pauses or resumes the intercom transmission when a cellular or VoIP phone call occurs.
  ///
  /// 3.55: hands-free that was armed when the call began is armed again shortly after the call
  /// ends (unless the rider turned hands-free off, muted the mic or the ride ended meanwhile).
  /// Note on audio mode: neither the shared mic (record plugin, AndroidRecordConfig.audioManagerMode
  /// left at modeNormal) nor playback (flutter_pcm_sound) sets MODE_IN_COMMUNICATION, so the
  /// intercom never looks like a call to PhoneCallService. If a later change sets that mode, call
  /// PhoneCallService.setOwnCommunicationMode(true / false) around it.
  void setPhoneCallActive(bool inCall) {
    if (_pausedByPhoneCall == inCall) return;
    _pausedByPhoneCall = inCall;
    _rearmAfterCallTimer?.cancel();
    if (inCall) {
      _rearmVoxAfterCall = isVoxArmed;
    } else if (_rearmVoxAfterCall) {
      _rearmVoxAfterCall = false;
      // A short wait: the phone's audio leaves call mode first, else the mic may fail to open.
      _rearmAfterCallTimer = Timer(const Duration(milliseconds: 1500), () {
        if (_disposed || _pausedByPhoneCall || _micMuted || _mode != IntercomMode.vox || _micOpen) return;
        startVox().ignore();
      });
    }
    if (inCall) {
      if (_transmitting) _endStream();
      if (_micOpen) _closeMic();
      if (_playerReady) {
        FlutterPcmSound.release().catchError((_) {});
        _playerReady = false;
        _playerRate = null;
      }
    }
    notifyListeners();
  }

  /// Explicitly halts active audio capture, sets mode to PTT, mutes mic, and releases recording hardware when the ride/trip ends.
  Future<void> stopCaptureOnTripEnd() async {
    if (_transmitting) _endStream();
    if (_mode == IntercomMode.vox) {
      _voxSilenceTimer?.cancel();
    }
    await _closeMic();
    _micMuted = true;
    _mode = IntercomMode.ptt;
    _resetPlayback(clearSpeaker: true);
    notifyListeners();
  }

  /// Explicitly stops any open group intercom sessions (transmitting, receiving, or VOX open mic),
  /// mutes the microphone (microphone remains OFF by default), and clears active speaker.
  Future<void> stopGroupIntercomSession() async {
    _voxSilenceTimer?.cancel();
    _rxIdleTimer?.cancel();
    _busyTimer?.cancel();
    if (_transmitting) _endStream();
    await _closeMic();
    _micMuted = true;
    _mode = IntercomMode.ptt;
    audioLevel.value = 0.0;
    activeSpeakerNotifier.value = null;
    _talkTargetUserId = null;
    _talkTargetName = null;
    _channel = IntercomChannel.all;
    _speakingRiders.clear();
    _mutedRiders.clear();
    _riderRoles.clear();
    _activeIsLead = false;
    _isPriorityDucked = false;
    _resetPlayback(clearSpeaker: true);
    _rt.send({'type': 'MIC_STATE', 'muted': true});
    notifyListeners();
  }

  /// Explicitly disables hands-free (VOX) mode and returns to push-to-talk (PTT) mode,
  /// releasing all microphone capture resources immediately.
  Future<void> disableHandsFree() async {
    _mode = IntercomMode.ptt;
    await stopVox();
    notifyListeners();
  }

  /// 3.55: hands-free talk on / off in one call (notification action, remote, quick setting).
  /// Returns true when hands-free is armed afterwards.
  Future<bool> toggleHandsFreeTalk() async {
    if (isVoxArmed) {
      await disableHandsFree();
      return false;
    }
    if (_micMuted) setMicMuted(false);
    _mode = IntercomMode.vox;
    final ok = await startVox();
    if (!ok && !_micOpen) {
      _mode = IntercomMode.ptt;
      notifyListeners();
    }
    return isVoxArmed;
  }

  /// 3.55: stop / resume hearing the group in one call (notification action). Returns true when
  /// the group is muted (deafened) afterwards. My own talk is not affected.
  bool toggleGroupMute() {
    setDeafened(!_deafened);
    return _deafened;
  }

  /// Handles runtime microphone permission revocation during an active ride.
  /// Stops recording, terminates transmission, and resets VOX mode to PTT.
  Future<void> onMicrophoneRevoked() async {
    _microphoneRevoked = true;
    _micMuted = true;
    _voxSilenceTimer?.cancel();
    if (_transmitting) _endStream();
    if (_micOpen) await _closeMic();
    if (_mode == IntercomMode.vox) {
      _mode = IntercomMode.ptt;
    }
    notifyListeners();
  }

  /// Alias for test compliance and clarity.
  Future<void> handlePermissionRevoked() => onMicrophoneRevoked();

  /// Verifies whether microphone permission is granted. If revoked, stops capture immediately.
  Future<bool> verifyPermission() async {
    final granted = await _ensurePermission();
    if (!granted) {
      if (_micOpen || _transmitting || isVoxArmed) {
        await onMicrophoneRevoked();
      }
      return false;
    } else if (_microphoneRevoked) {
      onMicrophoneRestored();
    }
    return true;
  }

  /// Restores microphone availability when permission is re-granted.
  void onMicrophoneRestored() {
    if (!_microphoneRevoked) return;
    _microphoneRevoked = false;
    notifyListeners();
  }

  /// PTT: call on press. Opens the mic and a stream to the chosen target.
  Future<bool> beginTransmission() async {
    if (_micMuted || _transmitting || !_rt.isConnected || _pausedByPhoneCall || _microphoneRevoked || !_talkSwitchOn) return false;
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
    if (_micMuted || !_rt.isConnected || _pausedByPhoneCall || _microphoneRevoked || !_talkSwitchOn) return false;
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
    final hub = micHub;
    if (hub != null) {
      _cleanup.reset();
      _nativeStage()?.reset();
      _preRoll.clear();
      _txCodec = _chooseCodec();
      _micRate = _rateFor(_txCodec);
      _decimator = null;
      _micOpen = true; // set first: frames may arrive before claim returns
      // Hands-free talk shares the phone's own mic with siren detection; push-to-talk
      // with a headset uses the headset mic while held (RideMicHub / MicPlan).
      final ok = await hub.claimIntercom(_onHubFrame, handsFree: _mode == IntercomMode.vox);
      if (!ok) {
        DiagLog.warn(DiagCat.intercom, 'mic_claim_refused', {'mode': _mode});
        _micOpen = false;
        await hub.releaseIntercom();
        return false;
      }
      notifyListeners();
      return true;
    }
    try {
      final rate = txSampleRate;
      _txCodec = VoiceCodecs.pcm; // own recorder (no shared mic): PCM as 3.55
      final stream = await _recorder.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: rate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ));
      _micOpen = true;
      _micRate = rate;
      _micSub = stream.listen(
        _onMicData,
        onError: (e) {
          debugPrint('mic error: $e');
          DiagLog.warn(DiagCat.intercom, 'mic_error', {'type': e.runtimeType.toString()});
          onMicrophoneRevoked();
        },
        onDone: () => _micOpen = false,
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Intercom mic open note: $e');
      DiagLog.warn(DiagCat.intercom, 'mic_open_failed', {'type': e.runtimeType.toString()});
      _micOpen = false;
      return false;
    }
  }

  Future<void> _closeMic() async {
    _micSub?.cancel();
    _micSub = null;
    final wasOpen = _micOpen;
    _micOpen = false;
    audioLevel.value = 0.0;
    _pending.clear();
    _preRoll.clear();
    final hub = micHub;
    if (hub != null) {
      if (wasOpen || hub.intercomClaimed) await hub.releaseIntercom();
    } else {
      try {
        if (await _recorder.isRecording()) await _recorder.stop();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// 3.55: one 20 ms frame from the shared mic (16 kHz). Cleaned (when on), cut to the send rate
  /// (8 kHz in data saver), then the usual VOX / PTT path; the voice gate replaces the loudness
  /// threshold for hands-free when cleanup is on.
  void _onHubFrame(Int16List frame, MicFrameInfo info) {
    if (!_micOpen) return;
    Float64List x;
    bool? gate;
    if (voiceCleanupOn) {
      final plan = voiceChainPlan;
      var src = frame;
      final native = plan.nativeMode != null ? _nativeStage() : null;
      if (native != null) {
        // Round 8: RNNoise stage first (12.5 ms), then the Dart gate / breath / AGC / limiter.
        if (_nativeMode != plan.nativeMode || _nativeWind != plan.nativeWindDuck) {
          native.configure(mode: plan.nativeMode!, windDuck: plan.nativeWindDuck);
          _nativeMode = plan.nativeMode;
          _nativeWind = plan.nativeWindDuck;
        }
        if (frame.length % 160 == 0 && frame.length <= 960) src = native.process(frame);
      }
      _cleanup
        ..handsFree = _mode == IntercomMode.vox
        ..suppressNoise = plan.dartSuppressNoise
        ..spectralSuppression = native == null && plan.dartSuppressNoise
        ..windSuppression = native == null ? plan.dartWind : false;
      x = _cleanup.process(int16ToFloat(src));
      gate = _cleanup.gateOpen;
    } else {
      x = int16ToFloat(frame);
    }
    if (_micRate == AppConfig.audioSampleRateLowData) {
      x = (_decimator ??= Decimator2()).process(x);
    }
    _onMicData(floatToPcm16Bytes(x), voiceGate: gate);
  }

  @visibleForTesting
  void debugHubFrame(Int16List frame) => _onHubFrame(frame, const MicFrameInfo(processed: false, headset: false));

  void _startStream() {
    _seq = 0;
    _transmitting = true;
    _txStartedAt = DateTime.now();
    // Round 8: the codec is decided per talk (the group may have changed since the mic opened).
    final codec = _chooseCodec();
    if (codec != _txCodec) {
      _txCodec = codec;
      final rate = _rateFor(codec);
      if (rate != _micRate) {
        _micRate = rate;
        _decimator = null;
        _preRoll.clear(); // recorded at the other rate
      }
    }
    _txViaLink = _link?.isReady == true;
    DiagLog.info(DiagCat.intercom, 'talk_start', {'mode': _mode, 'channel': _channel, 'lead': isRoadCaptain, 'direct': _talkTargetUserId != null, 'rate': _micRate, 'codec': _txCodec, 'link': _txViaLink});
    final header = <String, dynamic>{
      'to': _talkTargetUserId,
      'sampleRate': _micRate,
      'codec': _txCodec,
      'channel': _channel == IntercomChannel.leadOnly ? 'LEAD_ONLY' : 'ALL',
    };
    if (isRoadCaptain) {
      header['role'] = 'LEAD';
      header['priority'] = true;
    }
    _sendVoice(VoiceKind.start, header);
    if (_txCodec == VoiceCodecs.opus) {
      final tx = OpusTx(
        sender: _tx,
        bitrate: VoiceCodecs.opusBitrate(lowData: settings?.lowData ?? false),
        onFrame: (payload) {
          if (!_transmitting) return;
          final h = <String, dynamic>{'to': _talkTargetUserId, 'seq': _seq++};
          if (isRoadCaptain) {
            h['role'] = 'LEAD';
            h['priority'] = true;
          }
          _sendVoiceNow(VoiceKind.frame, h, payload);
        },
      );
      tx.onFailure = () => _codecFallback('encoder');
      _opusTx = tx;
    }
    // 3.55: the frames just before the voice gate opened (the first syllable) go out first.
    if (_preRoll.isNotEmpty) {
      for (final b in _preRoll) {
        if (_opusTx != null) {
          _opusTx!.add(b);
        } else {
          _pending.add(b);
        }
      }
      _preRoll.clear();
    }
    notifyListeners();
  }

  /// Round 8: sends in order behind any Opus encode in flight ([SerialVoiceSender]).
  void _sendVoice(int kind, Map<String, dynamic> header, [Uint8List? payload]) => _tx.run(() => _sendVoiceNow(kind, header, payload));

  /// The voice socket of a process-mode gateway when this talk started on it, else the live socket.
  void _sendVoiceNow(int kind, Map<String, dynamic> header, [Uint8List? payload]) {
    final link = _link;
    if (_txViaLink && link != null && link.isReady && link.send(VoiceLink.encode(kind, header, payload))) return;
    _rt.sendVoice(kind, header, payload);
  }

  /// Round 8: back to PCM (the relay refused Opus, the group got an old build, or the encoder failed). A talk
  /// in progress restarts at once in PCM (about one round trip of audio is lost).
  void _codecFallback(String reason) {
    if (_txCodec != VoiceCodecs.opus) return;
    DiagLog.info(DiagCat.intercom, 'codec_fallback', {'reason': reason});
    if (reason == 'encoder') _opus = const OpusCaps(encoder: false, decoder: true);
    final wasTalking = _transmitting;
    final tx = _opusTx;
    _opusTx = null;
    tx?.abandon();
    if (wasTalking) {
      _transmitting = false;
      _pending.clear();
      _sendVoice(VoiceKind.end, <String, dynamic>{'to': _talkTargetUserId});
    }
    _txCodec = VoiceCodecs.pcm;
    _micRate = _rateFor(_txCodec);
    _decimator = null;
    if (wasTalking && _micOpen && !_micMuted && _rt.isConnected) _startStream();
  }

  void _endStream() {
    DiagLog.info(DiagCat.intercom, 'talk_end', {'ms': _txStartedAt == null ? -1 : DateTime.now().difference(_txStartedAt!).inMilliseconds, 'frames': _seq});
    _transmitting = false;
    audioLevel.value = 0.0;
    _pending.clear();
    final header = <String, dynamic>{'to': _talkTargetUserId};
    if (isRoadCaptain) {
      header['role'] = 'LEAD';
      header['priority'] = true;
    }
    final tx = _opusTx;
    _opusTx = null;
    if (tx != null) {
      // Round 8: the last Opus packet goes out first, then END (in order).
      tx.finish(() => _sendVoiceNow(VoiceKind.end, header));
    } else {
      _sendVoice(VoiceKind.end, header);
    }
    notifyListeners();
  }

  // VOX tuning
  static const double _voxOpenRms = 0.045; // ~ -27 dBFS: normal speech into a helmet mic
  static const Duration _voxHangover = Duration(milliseconds: 900);
  int get _txFrameBytes => AppConfig.frameBytesFor(_micRate) * 2; // 40 ms

  void _onMicData(Uint8List chunk, {bool? voiceGate}) {
    if (!_micOpen || _micMuted) {
      if (audioLevel.value != 0.0) audioLevel.value = 0.0;
      return;
    }

    onMicChunk?.call(chunk);

    final rms = _rms(chunk);
    if (_mode == IntercomMode.vox) {
      // 3.55: with voice cleanup the gate (voiced speech, 500 ms hold) decides; else loudness.
      final talk = voiceGate ?? (rms >= _voxOpenRms);
      if (voiceGate != null && !voiceGate && !_transmitting) {
        _preRoll.add(chunk);
        if (_preRoll.length > 2) _preRoll.removeAt(0);
      }
      if (talk) {
        // 3.55 fix: an armed VOX mic never starts a stream once the admin switched talk off.
        if (!_transmitting && _rt.isConnected && _talkSwitchOn) _startStream();
        _voxSilenceTimer?.cancel();
        // (the voice gate already holds 500 ms after the last voiced frame)
        _voxSilenceTimer = Timer(voiceGate != null ? const Duration(milliseconds: 120) : _voxHangover, () {
          if (_transmitting) _endStream();
          _applyMicRate(); // 3.55 fix: a Data saver change made during the burst applies now
        });
      }
      if (!_transmitting) {
        if (audioLevel.value != 0.0) audioLevel.value = 0.0;
        return;
      }
    } else if (!_transmitting) {
      if (audioLevel.value != 0.0) audioLevel.value = 0.0;
      return;
    }

    // Update live audio VU meter while transmitting
    // Speech RMS into helmet mic typically ranges 0.01 - 0.20
    final normalized = (rms * 5.0).clamp(0.0, 1.0);
    audioLevel.value = normalized;

    // Guard: streams longer than the gateway allows are cut off server-side.
    if (_txStartedAt != null && DateTime.now().difference(_txStartedAt!).inMilliseconds > 55000) {
      _endStream();
      return;
    }

    final opus = _opusTx;
    if (opus != null) {
      opus.add(chunk); // 20 ms packets, two per frame, sent by OpusTx.onFrame
      return;
    }
    _pending.add(chunk);
    final frameBytes = _txFrameBytes;
    while (_pending.length >= frameBytes) {
      final all = _pending.takeBytes();
      final frame = Uint8List.sublistView(all, 0, frameBytes);
      if (all.length > frameBytes) _pending.add(Uint8List.sublistView(all, frameBytes));
      final header = <String, dynamic>{'to': _talkTargetUserId, 'seq': _seq++};
      if (isRoadCaptain) {
        header['role'] = 'LEAD';
        header['priority'] = true;
      }
      _sendVoice(VoiceKind.frame, header, Uint8List.fromList(frame));
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
  /// True when the player must be (re)created for a stream at [incoming] Hz.
  @visibleForTesting
  static bool needsPlayerSetup({required bool ready, required int? currentRate, required int incoming}) =>
      !ready || currentRate != incoming;

  /// Bytes of 20 ms of audio at the rate being played.
  int get _rxFrameBytes => AppConfig.frameBytesFor(_playerRate ?? AppConfig.audioSampleRate);

  /// Sets the player up for [sampleRate]. A stream at another rate (a rider in data saver
  /// mode, or back to normal) re-creates it, so nobody plays at the wrong speed.
  Future<void> _ensurePlayer(int sampleRate) {
    final running = _playerSetup;
    if (running != null) return running.then((_) => _ensurePlayer(sampleRate));
    if (!needsPlayerSetup(ready: _playerReady, currentRate: _playerRate, incoming: sampleRate)) return Future.value();
    // Stop feeding the old player at once: frames of the new stream wait in the jitter buffer.
    final release = _playerReady;
    _playerReady = false;
    final f = _setupPlayer(sampleRate, release: release);
    _playerSetup = f;
    return f.whenComplete(() {
      if (identical(_playerSetup, f)) _playerSetup = null;
    });
  }

  Future<void> _setupPlayer(int sampleRate, {required bool release}) async {
    try {
      if (release) await FlutterPcmSound.release();
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
      // Ask for more data when < 60 ms is left; we top up from the jitter buffer.
      await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 16);
      FlutterPcmSound.setFeedCallback(_onFeed);
      _playerRate = sampleRate;
      _playerReady = true;
    } catch (e) {
      debugPrint('Intercom player setup note: $e');
      DiagLog.warn(DiagCat.intercom, 'player_setup_failed', {'type': e.runtimeType.toString(), 'rate': sampleRate});
    }
  }

  void _onFeed(int remainingFrames) {
    _drain();
  }

  Future<void> _drain() async {
    if (_draining || !_playerReady) return;
    _draining = true;
    // Round 8: the player found nothing to play while a stream is live: re-buffer to a raised target.
    if (_jitter.isEmpty && _activeStreamId != null) _jb?.starved(_clock.elapsedMilliseconds);
    try {
      // Feed up to ~200 ms at a time so the native buffer stays small (low latency).
      var budget = _rxFrameBytes * 10;
      while (_jitter.isNotEmpty && budget > 0) {
        var bytes = _jitter.removeFirst();
        _queuedBytes -= bytes.length;
        budget -= bytes.length;
        if (_isSirenDucked) {
          bytes = attenuatePcm16(bytes, sirenDuckingFactor);
        }
        // 3.55: light limiter so one loud rider does not blast (no added latency).
        bytes = _rxLimiter.processPcm16(bytes);
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

  // -------------------------------------------------------------- ducking & priority
  /// Attenuation for Road Captain priority ducking (-18 dB).
  /// Amplitude ratio: 10^(-18/20) ~= 0.12589254.
  static const double duckingDecibels = -18.0;
  static final double duckingFactor = math.pow(10.0, duckingDecibels / 20.0).toDouble();

  /// Attenuation for FEAT-03 emergency siren ducking (-20 dB).
  /// Amplitude ratio: 10^(-20/20) = 0.10.
  static const double sirenDuckingDecibels = -20.0;
  static final double sirenDuckingFactor = math.pow(10.0, sirenDuckingDecibels / 20.0).toDouble();

  bool _isSirenDucked = false;

  /// Whether intercom playback is currently ducked due to an emergency siren detection.
  bool get isSirenDucked => _isSirenDucked;

  /// Controls emergency siren ducking (-20 dB / 0.10 amplitude factor).
  void setSirenDucking(bool ducked) {
    if (_isSirenDucked == ducked) return;
    _isSirenDucked = ducked;
    if (ducked) {
      _applySirenDucking();
    }
    notifyListeners();
  }

  void _applySirenDucking() {
    if (_jitter.isEmpty) return;
    final count = _jitter.length;
    for (var i = 0; i < count; i++) {
      final chunk = _jitter.removeFirst();
      _jitter.addLast(attenuatePcm16(chunk, sirenDuckingFactor));
    }
  }

  /// Attenuates 16-bit little-endian PCM audio samples by [factor] (defaults to -18 dB ducking).
  @visibleForTesting
  static Uint8List attenuatePcm16(Uint8List pcm, [double? factor]) {
    final f = factor ?? duckingFactor;
    final len = pcm.length ~/ 2;
    if (len == 0) return pcm;
    final even = len * 2;
    final inData = ByteData.sublistView(pcm, 0, even);
    final outBytes = Uint8List.fromList(pcm);
    final outData = ByteData.sublistView(outBytes, 0, even);
    for (var i = 0; i < len; i++) {
      final sample = inData.getInt16(i * 2, Endian.little);
      final ducked = (sample * f).round().clamp(-32768, 32767);
      outData.setInt16(i * 2, ducked, Endian.little);
    }
    return outBytes;
  }

  void _duckExistingPlayback() {
    _isPriorityDucked = true;
    if (_jitter.isEmpty) return;
    // Cap existing ducked chatter buffer to ~100 ms so the Lead's broadcast cuts through promptly.
    final maxDuckedBytes = _rxFrameBytes * 5;
    while (_queuedBytes > maxDuckedBytes && _jitter.length > 1) {
      _queuedBytes -= _jitter.removeFirst().length;
    }
    final count = _jitter.length;
    for (var i = 0; i < count; i++) {
      final chunk = _jitter.removeFirst();
      _jitter.addLast(attenuatePcm16(chunk, duckingFactor));
    }
  }

  bool _isRoadCaptainPacket(VoicePacket p) {
    final role = p.header['role']?.toString().toUpperCase() ?? _riderRoles[p.from]?.toUpperCase();
    final priority = p.header['priority'] == true;
    return role == 'LEAD' || p.isLeadOnly || priority;
  }

  void _triggerIncomingHapticPulse({required bool isLead}) {
    try {
      HapticFeedback.heavyImpact();
      if (isLead) {
        Future.delayed(const Duration(milliseconds: 150), () {
          try {
            HapticFeedback.heavyImpact();
          } catch (_) {}
        });
      }
    } catch (_) {}
  }

  void _onVoicePacket(VoicePacket p) {
    if (_deafened) return;
    final isLead = _isRoadCaptainPacket(p);
    final duckingEnabled = FeatureGates.isUnlocked(Feature.priorityIntercomDucking);
    final isEmergency = p.header['emergency'] == true ||
        p.header['isEmergency'] == true ||
        p.header['type'] == 'SOS' ||
        p.header['sos'] == true;

    // Pause casual intercom during active phone call; emergency broadcasts cut through
    if (_pausedByPhoneCall && !isEmergency) return;

    switch (p.kind) {
      case VoiceKind.start:
        // One speaker at a time: a newer group stream normally does not pre-empt an active stream.
        // But if the Road Captain transmits, do NOT drop packets due to casual chatter (!p.isPrivate).
        // Instead, prioritize the Lead's audio stream!
        final shouldPreempt = p.isPrivate || (isLead && duckingEnabled && !_activeIsLead);
        if (_activeStreamId != null && _activeStreamId != p.streamId && !shouldPreempt && !_rxStale()) return;

        // If the Road Captain pre-empts casual chatter, duck existing incoming playback volume by -18 dB:
        if (isLead && duckingEnabled && _activeStreamId != null && _activeStreamId != p.streamId && !_activeIsLead) {
          _duckExistingPlayback();
        } else {
          _jitter.clear();
          _queuedBytes = 0;
          _isPriorityDucked = false;
        }

        _activeStreamId = p.streamId;
        _activeSpeakerId = p.from;
        _activeSpeakerName = p.fromName;
        _activeIsPrivate = p.isPrivate;
        _activeIsLead = isLead;
        _activeChannel = p.isLeadOnly ? IntercomChannel.leadOnly : IntercomChannel.all;
        if (p.from.isNotEmpty) _speakingRiders[p.from] = true;
        _lastRxAt = DateTime.now();
        _rxLimiter.reset();
        _rxStreamStarted(p);

        _triggerIncomingHapticPulse(isLead: isLead);
        final isEmergency = p.header['emergency'] == true ||
            p.header['isEmergency'] == true ||
            p.header['type'] == 'SOS' ||
            p.header['sos'] == true;
        activeSpeakerNotifier.value = ActiveSpeakerInfo(
          speakerName: p.fromName.isNotEmpty ? p.fromName : 'Rider',
          speakerId: p.from.isNotEmpty ? p.from : null,
          isLead: isLead,
          isEmergency: isEmergency,
          timestamp: DateTime.now(),
        );

        _ensurePlayer(p.sampleRate).ignore();
        notifyListeners();
        break;

      case VoiceKind.frame:
        if (p.streamId != _activeStreamId) {
          // Frames of a stream we never saw START for (e.g. joined mid-sentence).
          final shouldPreempt = p.isPrivate || (isLead && duckingEnabled && !_activeIsLead);
          if (_activeStreamId != null && !shouldPreempt && !_rxStale()) return;

          if (isLead && duckingEnabled && _activeStreamId != null && !_activeIsLead) {
            _duckExistingPlayback();
          } else {
            _jitter.clear();
            _queuedBytes = 0;
            _isPriorityDucked = false;
          }

          _activeStreamId = p.streamId;
          _activeSpeakerId = p.from;
          _activeSpeakerName = p.fromName;
          _activeIsPrivate = p.isPrivate;
          _activeIsLead = isLead;
          _activeChannel = p.isLeadOnly ? IntercomChannel.leadOnly : IntercomChannel.all;
          if (p.from.isNotEmpty) _speakingRiders[p.from] = true;

          _triggerIncomingHapticPulse(isLead: isLead);
          final isEmergency = p.header['emergency'] == true ||
              p.header['isEmergency'] == true ||
              p.header['type'] == 'SOS' ||
              p.header['sos'] == true;
          activeSpeakerNotifier.value = ActiveSpeakerInfo(
            speakerName: p.fromName.isNotEmpty ? p.fromName : 'Rider',
            speakerId: p.from.isNotEmpty ? p.from : null,
            isLead: isLead,
            isEmergency: isEmergency,
            timestamp: DateTime.now(),
          );

          _rxStreamStarted(p);
          _ensurePlayer(p.sampleRate).ignore();
          notifyListeners();
        }
        _lastRxAt = DateTime.now();
        if (p.payload.isEmpty) return;
        // Round 8: decode (Opus) / view (PCM) -> adaptive jitter buffer -> concealment -> playback queue.
        final codec = p.header['codec']?.toString() ?? _rxCodec ?? VoiceCodecs.pcm;
        final seq = (p.header['seq'] as num?)?.toInt();
        if (codec == VoiceCodecs.opus) {
          final sid = p.streamId;
          _opusRx.decode(sid, Uint8List.fromList(p.payload), (pcm) {
            if (sid != _activeStreamId || _deafened) return;
            _rxPush(seq, pcm);
          });
        } else {
          final even = p.payload.length & ~1;
          final copy = Uint8List.fromList(Uint8List.sublistView(p.payload, 0, even));
          _rxPush(seq, Int16List.view(copy.buffer, 0, even ~/ 2));
        }
        _rxIdleTimer?.cancel();
        _rxIdleTimer = Timer(const Duration(milliseconds: 1500), () => _resetPlayback(clearSpeaker: true));
        break;

      case VoiceKind.end:
        if (p.streamId == _activeStreamId) {
          // Round 8: the buffered tail plays out without waiting for the jitter target.
          final jb = _jb;
          if (jb != null) {
            jb.markEnded();
            _rxRelease(jb);
          }
          if (p.from.isNotEmpty) _speakingRiders[p.from] = false;
          _activeIsLead = false;
          activeSpeakerNotifier.value = null;
          _rxIdleTimer?.cancel();
          // Let the buffered tail play out, then clear the "speaking" badge.
          _rxIdleTimer = Timer(const Duration(milliseconds: 400), () => _resetPlayback(clearSpeaker: true));
        }
        break;
    }
  }

  /// Round 8: a new incoming stream gets a fresh jitter buffer (40 ms frames on the wire) and concealer.
  void _rxStreamStarted(VoicePacket p) {
    _rxCodec = p.header['codec']?.toString() ?? VoiceCodecs.pcm;
    _jb = VoiceJitterBuffer(frameMs: 40);
    _concealer.reset();
  }

  /// One decoded frame of the active stream (PCM16 at the stream's rate). Frames without a sequence number
  /// (never sent by CoRoute apps) skip the jitter buffer.
  void _rxPush(int? seq, Int16List pcm) {
    if (pcm.isEmpty) return;
    _lastRxSamples = pcm.length;
    final jb = _jb ??= VoiceJitterBuffer(frameMs: 40);
    if (seq == null) {
      _enqueuePlayback(pcm);
      return;
    }
    jb.push(seq, pcm, _clock.elapsedMilliseconds);
    _rxRelease(jb);
  }

  void _rxRelease(VoiceJitterBuffer jb) {
    for (final r in jb.release(_clock.elapsedMilliseconds)) {
      _enqueuePlayback(r.kind == JitterPullKind.frame ? _concealer.good(r.pcm!) : _concealer.lost(_lastRxSamples));
    }
  }

  /// The playback queue (ducking, limiter and the player feed work on it as in 3.55).
  void _enqueuePlayback(Int16List pcm) {
    final bytes = Uint8List.view(pcm.buffer, pcm.offsetInBytes, pcm.lengthInBytes);
    _jitter.addLast(Uint8List.fromList(bytes));
    _queuedBytes += bytes.length;
    // Cap at ~600 ms; drop the oldest to keep latency bounded.
    while (_queuedBytes > _rxFrameBytes * 30 && _jitter.length > 1) {
      _queuedBytes -= _jitter.removeFirst().length;
    }
    // Drift: a queue that stays well over the jitter target (sender clock faster than ours) loses a frame.
    final jb = _jb;
    final queuedMs = _queuedBytes * 10 ~/ (_rxFrameBytes > 0 ? _rxFrameBytes : 640) * 2;
    if (jb != null && _jitter.length > 1 && jb.driftDrop(queuedMs, _clock.elapsedMilliseconds)) {
      _queuedBytes -= _jitter.removeFirst().length;
    }
    if (_playerReady && _queuedBytes >= _rxFrameBytes * 2) {
      _drain();
      try {
        FlutterPcmSound.start(); // primes the feed loop if it had drained
      } catch (_) {}
    }
  }

  bool _rxStale() => DateTime.now().difference(_lastRxAt).inMilliseconds > 1500;

  void _resetPlayback({required bool clearSpeaker}) {
    _jitter.clear();
    _queuedBytes = 0;
    _jb?.reset();
    _concealer.reset();
    _isPriorityDucked = false;
    if (clearSpeaker) {
      if (_activeSpeakerId != null) _speakingRiders[_activeSpeakerId!] = false;
      _activeStreamId = null;
      _activeSpeakerId = null;
      _activeSpeakerName = null;
      _activeIsPrivate = false;
      _activeIsLead = false;
      _activeChannel = IntercomChannel.all;
      activeSpeakerNotifier.value = null;
      // Release PCM sound playback track when idle so other audio/music apps (Spotify, etc.) are unblocked
      if (_playerReady) {
        FlutterPcmSound.release().catchError((_) {});
        _playerReady = false;
        _playerRate = null;
      }
      notifyListeners();
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    if (e['type'] == 'VOICE_BUSY') {
      if (isRoadCaptain && FeatureGates.isUnlocked(Feature.priorityIntercomDucking)) {
        // Road Captain has priority override; do not abort emergency broadcast.
        return;
      }
      _busyWith = e['speaker']?.toString() ?? 'another rider';
      if (_transmitting) _endStream();
      _busyTimer?.cancel();
      _busyTimer = Timer(const Duration(seconds: 2), () {
        _busyWith = null;
        notifyListeners();
      });
      notifyListeners();
    } else if (e['type'] == 'MIC_STATUS') {
      final uid = e['userId']?.toString();
      if (uid != null && uid.isNotEmpty) {
        if (e.containsKey('isSpeaking')) {
          _speakingRiders[uid] = e['isSpeaking'] == true;
        }
        if (e.containsKey('micMuted')) {
          _mutedRiders[uid] = e['micMuted'] == true;
        }
        notifyListeners();
      }
    } else if (e['type'] == 'VOICE_CODEC') {
      _onVoiceCodec(e);
    } else if (e['type'] == 'SNAPSHOT' && e['convoy'] is Map) {
      _announceVoiceCaps(); // Round 8: after every JOIN (and re-JOIN after a reconnect)
      final riders = e['convoy']['riders'];
      if (riders is Map) {
        for (final entry in riders.entries) {
          final r = entry.value;
          if (r is Map && r['role'] != null) {
            _riderRoles[entry.key.toString()] = r['role'].toString();
          }
        }
      }
    } else if (e['type'] == 'ROSTER_CHANGED' || e['type'] == 'RIDER_UPDATE') {
      final rider = e['rider'];
      if (rider is Map && rider['userId'] != null && rider['role'] != null) {
        _riderRoles[rider['userId'].toString()] = rider['role'].toString();
      }
    } else if (e['type'] == 'RIDER_LEFT' && e['userId'] == _talkTargetUserId) {
      setTalkTarget(); // our private partner left → back to everyone
    } else if (e['type'] == 'TRIP_STATUS' &&
        (e['status']?.toString().toUpperCase() == 'ENDED' ||
            e['tripStatus']?.toString().toUpperCase() == 'ENDED')) {
      stopCaptureOnTripEnd();
    } else if (e['type'] == 'DISSOLVED' || e['type'] == 'LEFT') {
      _forgetGroupVoice();
      stopCaptureOnTripEnd();
    }
  }

  // ------------------------------------------------------------- Round 8 codec negotiation
  /// Tells a gateway with the Round 8 relay ('voice2') which codecs this phone can receive.
  Future<void> _announceVoiceCaps() async {
    if (_disposed || !_rt.supports(VoiceCodecs.serverFeature)) return;
    final caps = await VoiceCodecPlatform.instance.caps();
    if (_disposed) return;
    _opus = (_opus.decoder && !_opus.encoder && caps.encoder) ? _opus : caps; // keep an encoder marked broken
    _rt.send({'type': 'VOICE_CAPS', 'codecs': VoiceCodecs.receivable(opusDecoder: _opus.decoder)});
  }

  void _onVoiceCodec(Map<String, dynamic> e) {
    final gid = e['groupId']?.toString();
    if (gid != null && _rt.groupId != null && gid != _rt.groupId) return;
    final codec = e['codec']?.toString() == VoiceCodecs.opus ? VoiceCodecs.opus : VoiceCodecs.pcm;
    _groupCodec = codec;
    DiagLog.info(DiagCat.intercom, 'voice_codec', {'codec': codec, 'refused': e['refused'] == true});
    if (codec == VoiceCodecs.pcm || e['refused'] == true) _codecFallback(e['refused'] == true ? 'refused' : 'group');
    // Process-mode gateway: a ticket for the separate voice socket.
    final v = e['voice'];
    if (v is Map && v['ticket'] is String && v['path'] is String && gid != null) {
      final link = _link ??= _newLink();
      if (!link.isReady || link.groupId != gid) link.connect(path: v['path'] as String, ticket: v['ticket'] as String, groupId: gid);
    }
  }

  VoiceLink _newLink() {
    final link = VoiceLink();
    link.packets.listen(_onVoicePacket);
    link.onState = (ready) {
      if (_disposed) return;
      DiagLog.info(DiagCat.intercom, 'voice_link', {'ready': ready});
      if (!ready && _txViaLink && _transmitting) {
        // The voice socket dropped mid-talk: carry on over the live socket.
        _txViaLink = false;
        final tx = _opusTx;
        _opusTx = null;
        tx?.abandon();
        _transmitting = false;
        _pending.clear();
        if (_micOpen && !_micMuted && _rt.isConnected) _startStream();
      }
      if (!ready && !_disposed && _rt.groupId != null) {
        // Ask for a fresh ticket in a while (VOICE_CAPS is answered with VOICE_CODEC + ticket).
        Timer(const Duration(seconds: 5), () {
          if (!_disposed && _link?.isReady != true) _announceVoiceCaps();
        });
      }
    };
    return link;
  }

  void _forgetGroupVoice() {
    _groupCodec = null;
    _link?.close();
  }

  /// Called when leaving a convoy: nothing may carry over to the next group.
  Future<void> reset() async {
    _forgetGroupVoice();
    await stopCaptureOnTripEnd();
    audioLevel.value = 0.0;
    activeSpeakerNotifier.value = null;
    _talkTargetUserId = null;
    _talkTargetName = null;
    _channel = IntercomChannel.all;
    _speakingRiders.clear();
    _mutedRiders.clear();
    _riderRoles.clear();
    _activeIsLead = false;
    _isPriorityDucked = false;
  }

  void _setupHardwareKeyboard() {
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @visibleForTesting
  bool handleKeyEvent(KeyEvent event) => _handleKeyEvent(event);

  @visibleForTesting
  void updateAudioLevelForTesting(double level) {
    audioLevel.value = level.clamp(0.0, 1.0);
  }

  @visibleForTesting
  int get jitterQueueLength => _jitter.length;

  @visibleForTesting
  Uint8List? get firstJitterBuffer => _jitter.isEmpty ? null : _jitter.first;

  @visibleForTesting
  void addJitterChunkForTesting(Uint8List chunk) {
    _jitter.addLast(chunk);
    _queuedBytes += chunk.length;
  }

  static bool isPttKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.audioVolumeDown ||
        key == LogicalKeyboardKey.headsetHook ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (settings?.hardwarePtt != true) return false;
    if (!_rt.isConnected || _rt.groupId == null) return false;

    if (!isPttKey(event.logicalKey)) return false;

    if (_mode == IntercomMode.vox) {
      if (event is KeyDownEvent) {
        if (isVoxArmed) {
          stopVox();
        } else {
          startVox();
        }
      }
      return true;
    }

    if (event is KeyDownEvent) {
      if (!_transmitting && !_micMuted) {
        beginTransmission();
      }
      return true;
    } else if (event is KeyUpEvent) {
      if (_transmitting) {
        endTransmission();
      }
      return true;
    } else if (event is KeyRepeatEvent) {
      return true;
    }

    return false;
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _rearmAfterCallTimer?.cancel();
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    settings?.removeListener(_onSettingsChanged);
    audioLevel.dispose();
    activeSpeakerNotifier.dispose();
    _voiceSub?.cancel();
    _eventSub?.cancel();
    _micSub?.cancel();
    _voxSilenceTimer?.cancel();
    _rxIdleTimer?.cancel();
    _busyTimer?.cancel();
    if (_transmitting) {
      _transmitting = false;
      try {
        _rt.sendVoice(VoiceKind.end, {'to': _talkTargetUserId});
      } catch (_) {}
    }
    _closeMic().ignore();
    _opusTx?.abandon();
    _opusTx = null;
    _opusRx.dispose();
    _link?.dispose();
    _link = null;
    _native?.dispose();
    _native = null;
    try {
      _recorderInstance?.dispose().catchError((_) {});
    } catch (_) {}
    _recorderInstance = null;
    if (_playerReady) {
      try {
        FlutterPcmSound.release().catchError((_) {});
      } catch (_) {}
      _playerReady = false;
    }
    super.dispose();
  }
}
