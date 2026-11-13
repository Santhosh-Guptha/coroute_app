// 3.55 RideMicHub: ONE microphone for the whole ride.
//
// Android lets only one app-level capture run reliably, so the siren detector and the
// intercom share a single `record` stream (16 kHz mono PCM16, re-cut into 20 ms frames) instead
// of each opening its own AudioRecord.
//
// Consumers:
//  * analysis (SirenAcousticDetector: sirens) gets every RAW frame, while detection is
//    wanted (ride active, setting + admin switch on, battery OK, no phone call, permission given,
//    app in front or the ride's foreground service running);
//  * the intercom ([claimIntercom] / [releaseIntercom]) gets the same frames and cleans them in
//    software (lib/domain/audio/voice_cleanup.dart) before sending.
//
// Why the PHONE's own mic: detection is for a rider who cannot hear outside sound (noise-cancelling
// earbuds, a helmet set, music). The phone on the mount / tank bag / pocket still hears the road.
// A headset mic does not: it sits inside the helmet or ear, and Bluetooth (SCO) headset mics are
// noise-suppressed, so they would miss sirens.
//
// Source choice (re-opened only when it must change; see [MicPlan.forNeeds]):
//  * detection wanted (alone, with hands-free talk, or with push-to-talk and no headset): the
//    BUILT-IN mic, picked explicitly (record's `device` = the InputDeviceType.builtIn device, so a
//    wired headset's in-line mic is never used either), AndroidAudioSource.mic with the OS effects
//    off (raw: OS noise suppression would erase a siren as "stationary noise"), no Bluetooth SCO
//    (music keeps A2DP quality). Hands-free talk with a headset then sends the phone mic's voice,
//    cleaned in software (wind, breath, engine): one capture only, and detection wins;
//  * push-to-talk pressed with a Bluetooth / wired headset: the headset mic (voiceCommunication,
//    OS effects, SCO) only while the button is held; those frames are flagged headset+processed
//    and the detector skips them. On release the hub goes back to the built-in mic;
//  * intercom only (detection not wanted): voiceCommunication with the OS effects and SCO, as
//    before 3.55.
//
// ==== Round 10 rescue beacon BEGIN (wide-band listeners)
// A rescue listener (lib/data/services/rescue_finder_service.dart: a responder's phone during an
// open SOS only) needs 17..20 kHz, which a 16 kHz capture cannot hold. While one is attached the
// SAME single capture opens at 48 kHz (raw built-in mic), the rescue listener gets the 48 kHz
// frames, and the siren detector and the intercom get the usual 16 kHz frames through a low-pass
// decimator (lib/domain/rescue/decimator.dart). Without a rescue listener nothing changes.
// ==== Round 10 rescue beacon END
//
// Privacy: frames live in memory for the time of one callback. Nothing is recorded, stored or
// sent by the hub; only the intercom sends voice, while the rider talks.
//
// Lifecycle: the mic opens only while some consumer needs it and closes at once otherwise
// (setting off, admin switch off, ride end, phone call, battery low, permission gone). In the
// background the hub keeps running only while the ride foreground service runs (Android needs the
// service with the microphone type for capture with the screen off; see BackgroundService).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:record/record.dart';

import '../../domain/rescue/decimator.dart'; // Round 10 rescue beacon
import 'background_service.dart';

/// Why the hub is (not) listening, for the settings screen and logs.
enum MicHubState { off, listening, pausedCall, pausedBattery, pausedBackground, noPermission, error }

/// One 20 ms frame (320 samples at 16 kHz).
typedef MicFrameListener = void Function(Int16List frame, MicFrameInfo info);

class MicFrameInfo {
  /// True when the frames come through the OS voice processing (voiceCommunication source with
  /// noise suppression / helmet headset mic): fine for talk, weaker for siren detection.
  final bool processed;

  /// A Bluetooth / wired headset is the input (best guess from the input device list).
  final bool headset;

  const MicFrameInfo({required this.processed, required this.headset});
}

class RideMicHub extends ChangeNotifier with WidgetsBindingObserver {
  static const int sampleRate = 16000;
  static const int frameSamples = 320;

  RideMicHub({AudioRecorder? recorder, bool observeLifecycle = true}) : _recorderInstance = recorder {
    if (observeLifecycle) {
      try {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      } catch (_) {}
    }
  }

  // ---- inputs (set in main.dart; all optional so tests can build the hub alone) ----

  /// A ride is running (group trip STARTED or an offline solo ride).
  bool Function() rideActive = () => false;

  /// Siren detection is switched on (rider setting AND admin switch).
  bool Function() detectionEnabled = () => false;

  /// Battery low (< 15 % and not charging), SOS battery reserve or battery saver: detection pauses.
  bool Function() batteryLow = () => false;

  /// Told once when detection is wanted but the microphone permission is missing.
  void Function(String message)? onNotice;

  // ---- state ----
  AudioRecorder? _recorderInstance;
  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final List<MicFrameListener> _analysis = [];
  MicFrameListener? _intercom;
  bool _intercomClaimed = false;
  bool _intercomHandsFree = false;
  bool _inCall = false;
  bool _foreground = true;
  bool _fgsRunning = false;
  bool _permission = false;
  bool _permissionChecked = false;
  DateTime? _permissionCheckedAt;
  bool _noticeGiven = false;
  bool _disposed = false;
  bool _observing = false;
  bool _open = false;
  MicPlan? _config;
  bool _headset = false;
  InputDevice? _builtIn;
  MicHubState _state = MicHubState.off;
  Future<void> _chain = Future.value();
  Timer? _deviceTimer;
  Timer? _retryTimer;
  int _errors = 0;
  final Int16List _frame = Int16List(frameSamples);
  int _fill = 0;
  int _oddByte = -1;
  // ==== Round 10 rescue beacon BEGIN: 48 kHz listeners (see the header)
  static const int wideSampleRate = 48000;
  static const int wideFrameSamples = 960; // 20 ms at 48 kHz
  final List<MicFrameListener> _wide = [];
  final Int16List _wideFrame = Int16List(wideFrameSamples);
  int _wideFill = 0;
  final Decimator3 _decimator = Decimator3();

  /// A rescue listener: raw 48 kHz frames from the phone's own mic. Never stored.
  void addWideBandListener(MicFrameListener l) {
    if (_wide.contains(l)) return;
    _wide.add(l);
    reevaluate();
  }

  void removeWideBandListener(MicFrameListener l) {
    if (_wide.remove(l)) reevaluate();
  }

  /// The capture runs at 48 kHz for a rescue listener now.
  bool get wideBandActive => _open && (_config?.wideBand ?? false);

  bool get _wantWide => _wide.isNotEmpty && !_inCall && (_foreground || _fgsRunning);
  // ==== Round 10 rescue beacon END

  MicHubState get state => _state;
  bool get isOpen => _open;
  bool get headsetConnected => _headset;

  /// The capture is OS-processed (push-to-talk held on a headset, or talk only): the detector
  /// skips headset frames, so detection effectively pauses until the hub is back on the phone mic.
  bool get analysisDegraded => _open && (_config?.processed ?? false);
  bool get detectionActive => _open && _wantDetection;

  /// Analysis consumers (siren detector). Raw frames, never stored.
  void addAnalysisListener(MicFrameListener l) {
    if (!_analysis.contains(l)) _analysis.add(l);
  }

  void removeAnalysisListener(MicFrameListener l) => _analysis.remove(l);

  bool get _wantDetection =>
      _analysis.isNotEmpty &&
      rideActive() &&
      detectionEnabled() &&
      !batteryLow() &&
      !_inCall &&
      (_foreground || _fgsRunning);

  bool get _wantIntercom => _intercomClaimed && !_inCall;

  /// The intercom needs the mic (push-to-talk pressed or hands-free armed). [listener] receives
  /// the frames. [requestPermission] may show the system dialog (only on a rider's tap).
  /// [handsFree]: hands-free (VOX) talk; with a headset and detection running it uses the
  /// built-in mic too (one capture), while push-to-talk uses the headset mic while held.
  Future<bool> claimIntercom(MicFrameListener listener, {bool requestPermission = true, bool handsFree = false}) async {
    _intercom = listener;
    _intercomClaimed = true;
    _intercomHandsFree = handsFree;
    if (!await _checkPermission(request: requestPermission)) {
      _intercomClaimed = false;
      _intercom = null;
      return false;
    }
    await reevaluate();
    return _open;
  }

  /// The intercom no longer needs the mic. The capture closes unless detection still wants it.
  Future<void> releaseIntercom() async {
    _intercomClaimed = false;
    _intercomHandsFree = false;
    _intercom = null;
    await reevaluate();
  }

  bool get intercomClaimed => _intercomClaimed;

  /// A phone call started / ended (PhoneCallService listener in main.dart): the mic is released
  /// during the call and re-opened after it, when still needed.
  void setPhoneCallActive(bool inCall) {
    if (_inCall == inCall) return;
    _inCall = inCall;
    reevaluate();
  }

  /// Settings, admin switch, ride or battery changed: open / close / re-open as needed.
  /// Serialised: calls never overlap.
  Future<void> reevaluate() {
    final next = _chain.then((_) => _apply()).catchError((Object e) {
      debugPrint('RideMicHub note: $e');
    });
    _chain = next;
    return next;
  }

  Future<bool> _checkPermission({required bool request}) async {
    try {
      _permission = await _recorder.hasPermission(request: request);
    } catch (_) {
      _permission = false;
    }
    _permissionChecked = true;
    return _permission;
  }

  Future<void> _apply() async {
    if (_disposed) return;
    final det = _wantDetection;
    final ic = _wantIntercom;
    final wide = _wantWide; // Round 10 rescue beacon
    if (!det && !ic && !wide) {
      await _close();
      _setState(_inCall
          ? MicHubState.pausedCall
          : (_analysis.isNotEmpty && rideActive() && detectionEnabled() && batteryLow())
              ? MicHubState.pausedBattery
              : (_analysis.isNotEmpty && rideActive() && detectionEnabled() && !_foreground && !_fgsRunning)
                  ? MicHubState.pausedBackground
                  : MicHubState.off);
      return;
    }
    if (!_permissionChecked || !_permission) {
      // Never pop the system dialog for detection in the middle of a ride: check only (at most
      // every 30 s while it is missing; a resume checks again at once).
      final now = DateTime.now();
      final recent = _permissionCheckedAt != null && now.difference(_permissionCheckedAt!).inSeconds < 30;
      if (!(_permissionChecked && recent && !_permission)) _permissionCheckedAt = now;
      if ((_permissionChecked && recent && !_permission) || !await _checkPermission(request: false)) {
        await _close();
        _setState(MicHubState.noPermission);
        if (det && !_noticeGiven) {
          _noticeGiven = true;
          onNotice?.call('Siren alerts need the microphone. Allow it for CoRoute in phone settings to use them.');
        }
        return;
      }
    }
    final want = MicPlan.forNeeds(detection: det, intercom: ic, intercomHandsFree: _intercomHandsFree, headset: _headset, wide: wide);
    if (_open && _config == want) return;
    await _close();
    await _openWith(want);
  }

  Future<void> _openWith(MicPlan cfg) async {
    // Android: capture with the screen off needs the ride service with the microphone type.
    // Only asked while the app is in front (Android 14 refuses to start it from the background).
    if (_foreground) BackgroundService.ensureMicrophoneType().ignore();
    try {
      // The phone's own mic for detection (never a headset / in-line mic). Unknown = default device,
      // which without SCO is the built-in mic unless a wired headset with a mic is plugged in.
      final InputDevice? device = cfg.builtInMic ? (_builtIn ?? await _findBuiltIn()) : null;
      final stream = await _recorder.startStream(RecordConfig(
        device: device,
        encoder: AudioEncoder.pcm16bits,
        sampleRate: cfg.wideBand ? wideSampleRate : sampleRate, // Round 10 rescue beacon
        numChannels: 1,
        autoGain: cfg.processed,
        echoCancel: cfg.processed,
        noiseSuppress: cfg.processed,
        audioInterruption: AudioInterruptionMode.pauseResume,
        androidConfig: AndroidRecordConfig(
          audioSource: cfg.processed ? AndroidAudioSource.voiceCommunication : AndroidAudioSource.mic,
          manageBluetooth: cfg.bluetooth,
        ),
      ));
      _fill = 0;
      _oddByte = -1;
      _wideFill = 0; // Round 10 rescue beacon
      _decimator.reset();
      _open = true;
      _config = cfg;
      _sub = stream.listen(_onBytes, onError: _onError, onDone: () {
        if (_open) {
          _open = false;
          _scheduleRetry();
        }
      });
      _errors = 0;
      _setState(MicHubState.listening);
      _startDeviceWatch();
    } catch (e) {
      debugPrint('RideMicHub open note: $e');
      _open = false;
      _config = null;
      _setState(MicHubState.error);
      _scheduleRetry();
    }
  }

  Future<void> _close() async {
    _deviceTimer?.cancel();
    _deviceTimer = null;
    final sub = _sub;
    _sub = null;
    final wasOpen = _open;
    _open = false;
    _config = null;
    await sub?.cancel();
    if (wasOpen) {
      try {
        if (await _recorder.isRecording()) await _recorder.stop();
      } catch (_) {}
    }
    _fill = 0;
  }

  void _onError(Object e) {
    debugPrint('RideMicHub stream note: $e');
    _open = false;
    _setState(MicHubState.error);
    _scheduleRetry();
  }

  /// The mic was taken (another app, an assistant) or failed: try again later, backing off.
  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();
    _errors++;
    if (_errors > 6) return; // give up until the next change (resume, setting, ride)
    _retryTimer = Timer(Duration(seconds: 3 * _errors), () {
      _config = null;
      reevaluate();
    });
  }

  /// Bluetooth / wired headset connect and disconnect: re-check the input devices every 15 s and
  /// re-open with the right source when it changed.
  void _startDeviceWatch() {
    _deviceTimer?.cancel();
    _deviceTimer = Timer.periodic(const Duration(seconds: 15), (_) => refreshInputDevices());
    refreshInputDevices();
  }

  /// Re-reads the input devices (also called by the app when an audio route changes).
  Future<void> refreshInputDevices() async {
    try {
      final devices = await _recorder.listInputDevices();
      _builtIn = pickBuiltIn(devices);
      final hs = devices.any(isHeadsetDevice);
      if (hs != _headset) {
        _headset = hs;
        notifyListeners();
        reevaluate();
      }
    } catch (_) {}
  }

  Future<InputDevice?> _findBuiltIn() async {
    try {
      return _builtIn = pickBuiltIn(await _recorder.listInputDevices());
    } catch (_) {
      return null;
    }
  }

  /// The phone's own microphone: by type (record 7 reports it), else by label, else null (default).
  @visibleForTesting
  static InputDevice? pickBuiltIn(List<InputDevice> devices) {
    for (final d in devices) {
      if (d.type == InputDeviceType.builtIn) return d;
    }
    for (final d in devices) {
      final l = d.label.toLowerCase();
      if ((l.contains('built') || l.contains('builtin')) && !isHeadsetLabel(l)) return d;
    }
    return null;
  }

  /// A Bluetooth / wired / USB headset mic is present.
  @visibleForTesting
  static bool isHeadsetDevice(InputDevice d) => switch (d.type) {
        InputDeviceType.bluetoothSco ||
        InputDeviceType.bluetoothA2dp ||
        InputDeviceType.bluetoothLe ||
        InputDeviceType.wiredHeadset ||
        InputDeviceType.usb =>
          true,
        InputDeviceType.builtIn => false,
        _ => isHeadsetLabel(d.label),
      };

  /// Best guess from the record plugin's device label (`name (type)` on Android).
  @visibleForTesting
  static bool isHeadsetLabel(String label) {
    final l = label.toLowerCase();
    return l.contains('bluetooth') || l.contains('sco') || l.contains('ble') || l.contains('headset') || l.contains('usb') || l.contains('wired');
  }

  void _onBytes(Uint8List bytes) {
    var i = 0;
    if (_oddByte >= 0 && bytes.isNotEmpty) {
      _push(((bytes[0] << 8) | _oddByte).toSigned(16));
      _oddByte = -1;
      i = 1;
    }
    for (; i + 1 < bytes.length; i += 2) {
      _push(((bytes[i + 1] << 8) | bytes[i]).toSigned(16));
    }
    if (i < bytes.length) _oddByte = bytes[i];
  }

  // Round 10 rescue beacon: 48 kHz samples go to the rescue listeners and, decimated, to the usual path.
  void _push(int sample) {
    if (!(_config?.wideBand ?? false)) return _push16(sample);
    _wideFrame[_wideFill++] = sample;
    if (_wideFill < wideFrameSamples) return;
    _wideFill = 0;
    final frame = Int16List.fromList(_wideFrame);
    const info = MicFrameInfo(processed: false, headset: false);
    for (final l in List<MicFrameListener>.from(_wide)) {
      try {
        l(frame, info);
      } catch (e) {
        debugPrint('RideMicHub rescue listener note: $e');
      }
    }
    for (final v in _decimator.process(frame)) {
      _push16(v);
    }
  }

  void _push16(int sample) {
    _frame[_fill++] = sample;
    if (_fill < frameSamples) return;
    _fill = 0;
    final cfg = _config;
    // headset = the frames come from a headset mic (not the phone's own mic).
    final info = MicFrameInfo(processed: cfg?.processed ?? false, headset: _headset && cfg != null && !cfg.builtInMic);
    final frame = Int16List.fromList(_frame);
    if (_wantDetection) {
      for (final l in List<MicFrameListener>.from(_analysis)) {
        try {
          l(frame, info);
        } catch (e) {
          debugPrint('RideMicHub analysis note: $e');
        }
      }
    }
    final ic = _intercom;
    if (_intercomClaimed && ic != null) {
      try {
        ic(frame, info);
      } catch (e) {
        debugPrint('RideMicHub intercom note: $e');
      }
    }
  }

  /// Test hook: feeds PCM16 bytes as if they came from the microphone.
  @visibleForTesting
  void debugFeed(Uint8List bytes, {bool processed = false}) {
    _config ??= MicPlan(processed: processed, bluetooth: false, builtInMic: !processed);
    _onBytes(bytes);
  }

  void _setState(MicHubState s) {
    if (_state == s) return;
    _state = s;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _errors = 0;
      _permissionCheckedAt = null;
      // Opened while in the background (e.g. the trip started with the screen locked): give the
      // ride service the microphone type now that Android allows it.
      if (_open) BackgroundService.ensureMicrophoneType().ignore();
      reevaluate();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      _foreground = false;
      // Keep listening only while the ride's foreground service runs (lock screen, screen off).
      BackgroundService.isRunning().then((running) {
        // 3.55: on Android a ride service WITHOUT the microphone type gets silence (or an error)
        // from the mic once the app is in the background, so it only counts with that type.
        _fgsRunning = running && (defaultTargetPlatform != TargetPlatform.android || BackgroundService.runningWithMic);
        reevaluate();
      }).ignore();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _deviceTimer?.cancel();
    if (_observing) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
    }
    _sub?.cancel();
    _sub = null;
    _open = false;
    try {
      _recorderInstance?.dispose().catchError((_) {});
    } catch (_) {}
    _recorderInstance = null;
    super.dispose();
  }
}

/// How the one ride capture is opened (pure decision, tested).
class MicPlan {
  /// voiceCommunication source with the OS echo cancel / noise suppress / auto gain.
  final bool processed;

  /// record's manageBluetooth (Bluetooth SCO: the headset mic, and call-quality headset audio).
  final bool bluetooth;

  /// Capture explicitly from the phone's own (built-in) mic.
  final bool builtInMic;

  /// Round 10 rescue beacon: 48 kHz (raw built-in mic) for a rescue listener; 16 kHz otherwise.
  final bool wideBand;

  const MicPlan({required this.processed, required this.bluetooth, required this.builtInMic, this.wideBand = false});

  static const MicPlan detection = MicPlan(processed: false, bluetooth: false, builtInMic: true);
  static const MicPlan headsetTalk = MicPlan(processed: true, bluetooth: true, builtInMic: false);

  static MicPlan forNeeds({
    required bool detection,
    required bool intercom,
    required bool intercomHandsFree,
    required bool headset,
    bool wide = false, // Round 10 rescue beacon
  }) {
    // Round 10: a rescue listener needs the raw phone mic at 48 kHz, except while push-to-talk is
    // held on a headset (the headset mic then, as before; the rescue listener pauses meanwhile).
    if (wide && !(intercom && headset && !intercomHandsFree)) {
      return const MicPlan(processed: false, bluetooth: false, builtInMic: true, wideBand: true);
    }
    // Talk alone: the voice path as before 3.55 (headset mic over SCO when there is one).
    if (intercom && !detection) return headsetTalk;
    // Push-to-talk held with a headset: the headset mic while the button is held only.
    if (intercom && headset && !intercomHandsFree) return headsetTalk;
    // Detection (alone, with hands-free talk, or with talk and no headset): the phone's own mic,
    // raw, no SCO. Hands-free voice is cleaned in software.
    return MicPlan.detection;
  }

  @override
  bool operator ==(Object other) =>
      other is MicPlan && other.processed == processed && other.bluetooth == bluetooth && other.builtInMic == builtInMic && other.wideBand == wideBand;

  @override
  int get hashCode => Object.hash(processed, bluetooth, builtInMic, wideBand);

  @override
  String toString() => 'MicPlan(processed: $processed, bluetooth: $bluetooth, builtInMic: $builtInMic${wideBand ? ', wideBand' : ''})';
}
