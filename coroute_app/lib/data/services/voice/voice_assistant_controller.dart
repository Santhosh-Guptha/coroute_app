import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../models/rider_model.dart';
import '../convoy_service.dart';
import '../intercom_service.dart';
import '../safety_service.dart';
import '../voice_service.dart';
import '../helmet_voice_service.dart';
import 'intent_resolver.dart';
import 'localized_response_service.dart';
import 'recipient_resolver.dart';
import 'speech_recognition_adapter.dart';
import 'text_to_speech_adapter.dart';
import 'voice_action_executor.dart';
import 'voice_command_intent.dart';
import 'voice_safety_policy.dart';

/// Exhaustive session lifecycle states specified for the voice foundation.
enum VoiceSessionState {
  idle,
  starting,
  listening,
  processing,
  confirming,
  completed,
  failed,
  cancelled,
}

/// Microphone permission evaluation states.
enum MicPermissionState {
  granted,
  denied,
  permanentlyDenied,
  restricted,
}

/// Central coordinator for CoRoute Multilingual Voice Assistant (Phase 0 & 1 Foundation).
///
/// Manages:
/// - Push-to-Talk (PTT) session lifecycle.
/// - Single-active-session guard with monotonic session tokens.
/// - Invalidation of stale callbacks.
/// - Audio focus, Bluetooth headset SCO, and interruption handlers.
/// - Foreground/background and trip-end lifecycle transitions.
/// - Allowlisted First-Phase Commands (Volume, Language, Repeat Nav, Query Status).
/// - Microphone hardware arbitration with [IntercomService].
class VoiceAssistantController extends ChangeNotifier {
  final SpeechRecognitionAdapter speechAdapter;
  final VoiceActionExecutor actionExecutor;
  final TextToSpeechAdapter? ttsAdapter;
  final VoiceService? voiceService;
  final ConvoyService? convoyService;
  final SafetyService? safetyService;
  final IntercomService? intercomService;
  final HelmetVoiceService? helmetVoiceService;

  VoiceSessionState _state = VoiceSessionState.idle;
  MicPermissionState _permissionState = MicPermissionState.granted;
  String _currentTranscript = '';
  VoiceCommandIntent? _pendingIntent;
  String _statusFeedback = '';
  String _currentLocale = 'en-IN';
  int _sessionToken = 0;

  Timer? _silenceTimer;
  Timer? _maxSessionTimer;
  Timer? _confirmationTimeout;

  bool _intercomWasPaused = false;
  bool _isBackgrounded = false;

  final bool enforcePhase1Scope;
  final bool allowMessaging;
  final bool allowStopsAndAlerts;
  final bool allowIntercom;

  List<RiderModel> _disambiguationCandidates = [];

  VoiceAssistantController({
    required this.speechAdapter,
    required this.actionExecutor,
    this.ttsAdapter,
    this.voiceService,
    this.convoyService,
    this.safetyService,
    this.intercomService,
    this.helmetVoiceService,
    String initialLocale = 'en-IN',
    this.enforcePhase1Scope = true,
    this.allowMessaging = false,
    this.allowStopsAndAlerts = false,
    this.allowIntercom = false,
  }) : _currentLocale = initialLocale;

  // --- Getters ---
  VoiceSessionState get state => _state;
  MicPermissionState get permissionState => _permissionState;
  bool get isListening => _state == VoiceSessionState.listening;
  bool get isProcessing => _state == VoiceSessionState.processing;
  bool get isConfirming => _state == VoiceSessionState.confirming;
  bool get isSpeaking => _state == VoiceSessionState.completed && _statusFeedback.isNotEmpty;
  bool get isIdle => _state == VoiceSessionState.idle;
  String get currentTranscript => _currentTranscript;
  VoiceCommandIntent? get pendingIntent => _pendingIntent;
  String get statusFeedback => _statusFeedback;
  String get currentLocale => _currentLocale;
  int get activeSessionToken => _sessionToken;
  bool get isDisambiguating => _disambiguationCandidates.isNotEmpty;
  List<RiderModel> get disambiguationCandidates => _disambiguationCandidates;

  /// Changes the assistant's active listening and spoken language.
  void setLocale(String locale) {
    if (_currentLocale == locale) return;
    _currentLocale = locale;
    notifyListeners();
  }

  /// Sets microphone permission state explicitly (e.g. from permission handler or tests).
  void setPermissionState(MicPermissionState state) {
    _permissionState = state;
    if (state != MicPermissionState.granted && isListening) {
      cancelSession(reason: 'Microphone permission revoked');
    }
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  // LIFECYCLE & PTT SESSIONS
  // --------------------------------------------------------------------------

  /// Starts a Push-to-Talk (PTT) session. Enforces single-active-session guard.
  Future<bool> startListening() async {
    // 1. Single-active-session guard: If already starting or listening, ignore redundant call.
    if (_state == VoiceSessionState.listening || _state == VoiceSessionState.starting) {
      return true;
    }

    // 2. Permission check
    if (_permissionState != MicPermissionState.granted) {
      _state = VoiceSessionState.failed;
      _statusFeedback = 'Microphone permission needed';
      notifyListeners();
      return false;
    }

    // 3. Android 14+ Background Check: Do not initiate capture while app is in background
    if (_isBackgrounded) {
      _state = VoiceSessionState.failed;
      _statusFeedback = 'Voice commands require foreground app';
      notifyListeners();
      return false;
    }

    // 4. Increment session token to invalidate any previous in-flight callbacks
    final int currentToken = ++_sessionToken;

    _confirmationTimeout?.cancel();
    _silenceTimer?.cancel();
    _maxSessionTimer?.cancel();

    _currentTranscript = '';
    _statusFeedback = 'Listening...';
    _state = VoiceSessionState.starting;
    notifyListeners();

    // 5. Microphone Arbiter: Pause VOX in IntercomService to prevent mic collision
    if (intercomService != null && !intercomService!.isMicMuted) {
      _intercomWasPaused = true;
      intercomService!.setMicMuted(true);
    }

    try {
      final success = await speechAdapter.startListening(
        localeId: _currentLocale,
        onResult: (result) {
          // Token check: Discard stale result if session token changed
          if (currentToken != _sessionToken) return;

          _currentTranscript = result.transcript;
          _resetSilenceTimer(currentToken);
          notifyListeners();

          if (result.isFinal) {
            handleSpeechComplete(result.transcript, token: currentToken);
          }
        },
        onError: (err) {
          if (currentToken != _sessionToken) return;
          debugPrint('SpeechAdapter error (token $currentToken): $err');
          cancelSession(reason: 'Microphone error', token: currentToken);
        },
      );

      if (!success) {
        cancelSession(reason: 'Speech recognition unavailable', token: currentToken);
        return false;
      }

      _state = VoiceSessionState.listening;
      _resetSilenceTimer(currentToken);

      // Max total session timeout (15 seconds)
      _maxSessionTimer = Timer(const Duration(seconds: 15), () {
        if (_state == VoiceSessionState.listening && currentToken == _sessionToken) {
          stopListening(token: currentToken);
        }
      });

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('startListening exception: $e');
      cancelSession(reason: 'Could not start voice session', token: currentToken);
      return false;
    }
  }

  /// Stops capturing speech and transitions to processing.
  Future<void> stopListening({int? token}) async {
    final t = token ?? _sessionToken;
    if (t != _sessionToken) return; // Stale call
    if (_state != VoiceSessionState.listening && _state != VoiceSessionState.starting) return;

    _silenceTimer?.cancel();
    _maxSessionTimer?.cancel();

    _state = VoiceSessionState.processing;
    _statusFeedback = 'Processing...';
    notifyListeners();

    await speechAdapter.stopListening();
    if (_currentTranscript.isNotEmpty) {
      await handleSpeechComplete(_currentTranscript, token: t);
    } else {
      cancelSession(reason: 'No speech detected', token: t);
    }
  }

  /// Ingests completed transcript, resolves intent, and triggers execution.
  Future<void> handleSpeechComplete(String transcript, {int? token}) async {
    final t = token ?? _sessionToken;
    if (t != _sessionToken) return; // Stale callback ignored

    _silenceTimer?.cancel();
    _maxSessionTimer?.cancel();

    _currentTranscript = transcript;
    _state = VoiceSessionState.processing;
    notifyListeners();

    // Restore Intercom VOX after speech capture completes
    _restoreIntercomIfPaused();

    // Hands-free Helmet Voice Safety Hotwords integration (FEAT-07)
    if (helmetVoiceService != null && helmetVoiceService!.isEnabled) {
      final hotword = await helmetVoiceService!.processSpeech(transcript);
      if (hotword != null) {
        _state = VoiceSessionState.completed;
        _statusFeedback = hotword.confirmationSpeech;
        notifyListeners();
        return;
      }
    }

    var intent = IntentResolver.resolve(transcript, currentLocale: _currentLocale);

    // If currently confirming an earlier action or resolving disambiguation
    if (_pendingIntent != null) {
      if (_disambiguationCandidates.isNotEmpty) {
        final selected = _resolveCandidateFromSpeech(transcript, _disambiguationCandidates);
        if (selected != null) {
          _disambiguationCandidates = [];
          final resolvedIntent = _pendingIntent!.copyWith(
            slots: {
              ..._pendingIntent!.slots,
              'recipient': selected.name,
              'recipientId': selected.userId,
            },
          );
          _pendingIntent = resolvedIntent;
          _state = VoiceSessionState.confirming;
          final prompt = LocalizedResponseService.confirmationPrompt(
            resolvedIntent,
            _currentLocale,
          );
          _statusFeedback = prompt;
          notifyListeners();
          _startConfirmationTimeout(t);
          await _speakPrompt(prompt, token: t);
          return;
        } else if (intent.type == VoiceIntentType.cancelAction) {
          _pendingIntent = null;
          _disambiguationCandidates = [];
          _confirmationTimeout?.cancel();
          await _speakAndDismiss(LocalizedResponseService.actionCancelled(_currentLocale), token: t);
          return;
        }
      }

      if (intent.type == VoiceIntentType.confirmAction) {
        final toExecute = _pendingIntent!;
        _pendingIntent = null;
        _disambiguationCandidates = [];
        _confirmationTimeout?.cancel();
        if (!_isPermittedIntent(toExecute.type) && toExecute.riskTier != 4) {
          await _speakAndDismiss(
            'This feature will be enabled in the next release phase.',
            token: t,
          );
          return;
        }
        await _executeAuthorizedIntent(toExecute, token: t);
        return;
      } else if (intent.type == VoiceIntentType.cancelAction) {
        _pendingIntent = null;
        _disambiguationCandidates = [];
        _confirmationTimeout?.cancel();
        await _speakAndDismiss(LocalizedResponseService.actionCancelled(_currentLocale), token: t);
        return;
      }
    }

    // Fast-path safety commands (Tier 4)
    if (intent.type == VoiceIntentType.triggerSos ||
        intent.type == VoiceIntentType.cancelSos ||
        intent.type == VoiceIntentType.silenceSiren) {
      await _executeAuthorizedIntent(intent, token: t);
      return;
    }

    // Phase Scope Check: Reject commands outside authorized phase
    if (!_isPermittedIntent(intent.type)) {
      await _speakAndDismiss(
        'This feature will be enabled in the next release phase.',
        token: t,
      );
      return;
    }

    // Road Captain & Safety Policy validation
    if (convoyService != null) {
      final safetyRejection = VoiceSafetyPolicy.validateIntent(
        intent: intent,
        isRoadCaptain: convoyService!.canEditRoute,
        isConvoyActive: convoyService!.activeConvoy != null,
      );
      if (safetyRejection != null) {
        _state = VoiceSessionState.failed;
        _statusFeedback = safetyRejection;
        notifyListeners();
        await _speakAndDismiss(safetyRejection, token: t);
        return;
      }
    }

    // Stale GPS Telemetry Re-validation Guard for waypoint creation
    if (intent.type == VoiceIntentType.proposeStop && convoyService?.activeConvoy != null) {
      final myUid = convoyService?.myUserId;
      final me = myUid != null ? convoyService?.activeConvoy?.riders[myUid] : null;
      if (me != null && (DateTime.now().millisecondsSinceEpoch - me.lastSeenEpochMs > 60000)) {
        intent = intent.copyWith(slots: {
          ...intent.slots,
          'staleGpsWarning': true,
        });
      }
    }

    // Two-step confirmation gate for risk-bearing actions
    if (intent.requiresConfirmation) {
      // Recipient resolution and disambiguation for sendMessage and requestIntercom
      if (intent.type == VoiceIntentType.sendMessage || intent.type == VoiceIntentType.requestIntercom) {
        final rawRecipient = intent.slots['recipient']?.toString() ?? '';
        final riders = convoyService?.activeConvoy?.riders.values.toList() ?? [];

        if (riders.isNotEmpty) {
          final resolution = RecipientResolver.resolve(
            rawRecipient: rawRecipient,
            activeRiders: riders,
            locale: _currentLocale,
          );

          if (resolution.isAmbiguous) {
            _pendingIntent = intent;
            _disambiguationCandidates = resolution.candidates;
            _state = VoiceSessionState.confirming;
            _statusFeedback = resolution.clarificationPrompt ?? 'Which rider?';
            notifyListeners();
            _startConfirmationTimeout(t);
            await _speakPrompt(_statusFeedback, token: t);
            return;
          } else if (resolution.isNotFound) {
            _state = VoiceSessionState.failed;
            _statusFeedback = resolution.clarificationPrompt ?? 'Rider not found.';
            notifyListeners();
            await _speakAndDismiss(_statusFeedback, token: t);
            return;
          } else if (resolution.isExact && resolution.matchedRider != null) {
            intent = intent.copyWith(
              slots: {
                ...intent.slots,
                'recipient': resolution.matchedRider!.name,
                'recipientId': resolution.matchedRider!.userId,
              },
            );
          }
        }
      }

      _pendingIntent = intent;
      _state = VoiceSessionState.confirming;
      _statusFeedback = LocalizedResponseService.confirmationPrompt(intent, _currentLocale);
      notifyListeners();
      _startConfirmationTimeout(t);
      await _speakPrompt(_statusFeedback, token: t);
      return;
    }

    // Low-risk local actions execute immediately
    await _executeAuthorizedIntent(intent, token: t);
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  /// Cancels any active listening or confirmation session.
  Future<void> cancelSession({String? reason, int? token}) async {
    final t = token ?? _sessionToken;
    if (t != _sessionToken && token != null) return;

    _silenceTimer?.cancel();
    _maxSessionTimer?.cancel();
    _confirmationTimeout?.cancel();
    _pendingIntent = null;
    _disambiguationCandidates = [];

    _state = VoiceSessionState.cancelled;
    _statusFeedback = reason ?? 'Cancelled';
    await speechAdapter.cancel();
    _restoreIntercomIfPaused();
    notifyListeners();
  }

  /// Explicitly resets the controller back to idle.
  void resetToIdle() {
    _state = VoiceSessionState.idle;
    _statusFeedback = '';
    _currentTranscript = '';
    _pendingIntent = null;
    _disambiguationCandidates = [];
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  // PLATFORM & AUDIO LIFECYCLE EVENT HANDLERS
  // --------------------------------------------------------------------------

  /// Audio interruption handler (e.g. incoming cellular phone call or system alarm).
  void onAudioInterrupted({String reason = 'Audio interrupted'}) {
    if (isListening || isProcessing || isConfirming) {
      cancelSession(reason: reason);
    }
  }

  /// Bluetooth SCO headset connection or disconnection event.
  void onBluetoothDeviceChanged({required bool isConnected}) {
    if (!isConnected && isListening) {
      cancelSession(reason: 'Bluetooth headset disconnected');
    }
  }

  /// App transitioned to background state.
  void onAppBackgrounded() {
    _isBackgrounded = true;
    if (isListening) {
      // Android 14+ background microphone restriction enforcement
      cancelSession(reason: 'App backgrounded');
    }
  }

  /// App transitioned to foreground state.
  void onAppForegrounded() {
    _isBackgrounded = false;
  }

  /// Trip end lifecycle handler. Cleans up all resources.
  void onRideEnded() {
    _sessionToken++; // Invalidate any running operations
    _silenceTimer?.cancel();
    _maxSessionTimer?.cancel();
    _confirmationTimeout?.cancel();
    _pendingIntent = null;
    _disambiguationCandidates = [];
    _state = VoiceSessionState.idle;
    _statusFeedback = '';
    _currentTranscript = '';
    speechAdapter.cancel();
    _restoreIntercomIfPaused();
    notifyListeners();
  }

  /// Absolute emergency safety pre-emption. Crash detector or SOS halts voice instantly.
  void onEmergencyPreempt() {
    _sessionToken++; // Invalidate immediately
    _silenceTimer?.cancel();
    _maxSessionTimer?.cancel();
    _confirmationTimeout?.cancel();
    _pendingIntent = null;
    _disambiguationCandidates = [];
    _state = VoiceSessionState.idle;
    _statusFeedback = 'Preempted by Safety SOS';
    speechAdapter.cancel();
    voiceService?.stop();
    ttsAdapter?.stop();
    _restoreIntercomIfPaused();
    notifyListeners();
  }

  // --------------------------------------------------------------------------
  // PRIVATE HELPERS
  // --------------------------------------------------------------------------

  bool _isPermittedIntent(VoiceIntentType type) {
    if (type == VoiceIntentType.setVoiceVolume ||
        type == VoiceIntentType.switchLanguage ||
        type == VoiceIntentType.repeatDirections ||
        type == VoiceIntentType.queryTripStatus) {
      return true;
    }
    if (type == VoiceIntentType.sendMessage && (!enforcePhase1Scope || allowMessaging)) {
      return true;
    }
    if ((type == VoiceIntentType.findEssentials ||
            type == VoiceIntentType.requestRegroup ||
            type == VoiceIntentType.broadcastAlert ||
            type == VoiceIntentType.proposeStop) &&
        (!enforcePhase1Scope || allowStopsAndAlerts)) {
      return true;
    }
    if ((type == VoiceIntentType.requestIntercom ||
            type == VoiceIntentType.disconnectIntercom ||
            type == VoiceIntentType.muteMicrophone) &&
        (!enforcePhase1Scope || allowIntercom)) {
      return true;
    }
    return false;
  }

  void _startConfirmationTimeout(int token) {
    _confirmationTimeout?.cancel();
    _confirmationTimeout = Timer(const Duration(seconds: 10), () {
      if (_state == VoiceSessionState.confirming && token == _sessionToken) {
        cancelSession(reason: 'Confirmation timed out', token: token);
      }
    });
  }

  Future<void> _speakPrompt(String text, {required int token}) async {
    if (token != _sessionToken) return;

    if (ttsAdapter != null) {
      await ttsAdapter!.speak(text, locale: _currentLocale, volume: actionExecutor.currentVolume);
    } else if (voiceService != null) {
      await voiceService!.speak(text, priority: VoicePriority.critical);
    }
  }

  RiderModel? _resolveCandidateFromSpeech(String speech, List<RiderModel> candidates) {
    final lower = speech.toLowerCase().trim();
    // 1. Exact full name match
    for (final candidate in candidates) {
      if (candidate.name.toLowerCase() == lower) {
        return candidate;
      }
    }

    // 2. Distinguishing token match (e.g. unique surname like "Verma" or "Sharma")
    final speechTokens = lower.split(RegExp(r'\s+'));
    for (final candidate in candidates) {
      final candTokens = candidate.name.toLowerCase().split(RegExp(r'\s+'));
      for (final st in speechTokens) {
        if (st.length > 2 && candTokens.contains(st)) {
          final sharedWithOther = candidates.any(
            (c) => c != candidate && c.name.toLowerCase().split(RegExp(r'\s+')).contains(st),
          );
          if (!sharedWithOther) {
            return candidate;
          }
        }
      }
    }

    // 3. Fallback: candidate contains speech or speech contains full candidate name
    for (final candidate in candidates) {
      final nameLower = candidate.name.toLowerCase();
      if (nameLower.contains(lower) || lower.contains(nameLower)) {
        return candidate;
      }
    }
    return null;
  }

  Future<void> _executeAuthorizedIntent(VoiceCommandIntent intent, {required int token}) async {
    if (token != _sessionToken) return;

    _state = VoiceSessionState.completed;
    _statusFeedback = 'Executing...';
    notifyListeners();

    final result = await actionExecutor.execute(intent, locale: _currentLocale);
    _statusFeedback = result.visualNotification ?? result.spokenFeedback;
    notifyListeners();

    await _speakAndDismiss(result.spokenFeedback, token: token);
  }

  void _resetSilenceTimer(int token) {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(const Duration(seconds: 7), () {
      if (_state == VoiceSessionState.listening && token == _sessionToken) {
        stopListening(token: token);
      }
    });
  }

  Future<void> _speakAndDismiss(String text, {required int token}) async {
    if (token != _sessionToken) return;

    if (ttsAdapter != null) {
      await ttsAdapter!.speak(text, locale: _currentLocale, volume: actionExecutor.currentVolume);
    } else if (voiceService != null) {
      await voiceService!.speak(text, priority: VoicePriority.critical);
    }

    await Future.delayed(const Duration(milliseconds: 1200));
    if (token == _sessionToken) {
      _state = VoiceSessionState.idle;
      _statusFeedback = '';
      _currentTranscript = '';
      notifyListeners();
    }
  }

  void _restoreIntercomIfPaused() {
    if (_intercomWasPaused && intercomService != null) {
      _intercomWasPaused = false;
      intercomService!.setMicMuted(false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _silenceTimer?.cancel();
    _maxSessionTimer?.cancel();
    _confirmationTimeout?.cancel();
    speechAdapter.dispose();
    ttsAdapter?.release();
    super.dispose();
  }
}
