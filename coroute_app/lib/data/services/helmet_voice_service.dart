import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../domain/voice/helmet_voice_hotword.dart';
import 'convoy_service.dart';
import 'intercom_service.dart';
import 'safety_service.dart';
import 'voice_service.dart';

/// Hands-free helmet intercom hotwords coordinator.
///
/// Enables motorcycle riders to execute critical safety and convoy actions
/// without removing hands from the handlebars:
/// - "CoRoute I'm OK" -> Clears crash countdown and confirms safety.
/// - "CoRoute SOS" -> Dispatches immediate SOS distress beacon via Gateway & P2P Mesh.
/// - "CoRoute Fuel" -> Requests a fuel stop to the convoy lead.
/// - "CoRoute Regroup" -> Dispatches a WAIT request to the group.
/// - "CoRoute Intercom" -> Toggles microphone mute.
class HelmetVoiceService extends ChangeNotifier {
  final ConvoyService convoyService;
  final SafetyService? safetyService;
  final IntercomService? intercomService;
  final VoiceService? voiceService;

  bool _isListening = false;
  bool _enabled = true;
  HotwordMatch? _lastMatch;
  String _lastSpoken = '';

  final StreamController<HotwordMatch> _matchStream = StreamController<HotwordMatch>.broadcast();

  HelmetVoiceService({
    required this.convoyService,
    this.safetyService,
    this.intercomService,
    this.voiceService,
  });

  bool get isListening => _isListening;
  bool get isEnabled => _enabled;
  HotwordMatch? get lastMatch => _lastMatch;
  String get lastSpoken => _lastSpoken;
  Stream<HotwordMatch> get onHotwordTriggered => _matchStream.stream;

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!_enabled && _isListening) {
      stopListening();
    }
    notifyListeners();
  }

  void startListening() {
    if (!_enabled || _isListening) return;
    _isListening = true;
    notifyListeners();
  }

  void stopListening() {
    if (!_isListening) return;
    _isListening = false;
    notifyListeners();
  }

  /// Ingests transcribed speech from helmet microphone or speech recognizer.
  Future<HotwordMatch?> processSpeech(String rawSpeech) async {
    if (!_enabled) return null;
    _lastSpoken = rawSpeech;
    notifyListeners();

    final match = HelmetVoiceMatcher.match(rawSpeech);
    if (match == null) return null;

    _lastMatch = match;
    _matchStream.add(match);
    notifyListeners();

    await _executeAction(match);
    return match;
  }

  /// Dispatches the appropriate action for the detected hotword.
  Future<void> _executeAction(HotwordMatch match) async {
    switch (match.hotword) {
      case HelmetVoiceHotword.imOk:
        safetyService?.alarmImOk();
        await _speak(match.confirmationSpeech, priority: VoicePriority.critical);
        break;

      case HelmetVoiceHotword.silenceSiren:
        safetyService?.silenceSiren();
        await _speak(match.confirmationSpeech, priority: VoicePriority.critical);
        break;

      case HelmetVoiceHotword.emergency:
        final uid = convoyService.myUserId ?? 'unknown';
        final me = convoyService.activeConvoy?.riders[uid];
        convoyService.triggerSosAlert(
          userId: uid,
          userName: me?.name ?? 'Rider',
          lat: me?.lat ?? 0.0,
          lng: me?.lng ?? 0.0,
          type: 'CRASH_OR_EMERGENCY',
        );
        await _speak(match.confirmationSpeech, priority: VoicePriority.critical);
        break;

      case HelmetVoiceHotword.fuel:
        final uid = convoyService.myUserId ?? 'unknown';
        final me = convoyService.activeConvoy?.riders[uid];
        convoyService.sendGroupMessage(
          senderId: uid,
          senderName: me?.name ?? 'Rider',
          text: 'Fuel stop requested at next petrol pump',
          isQuickCard: true,
          cardType: 'FUEL',
        );
        await _speak(match.confirmationSpeech, priority: VoicePriority.important);
        break;

      case HelmetVoiceHotword.regroup:
        final uid = convoyService.myUserId ?? 'unknown';
        final me = convoyService.activeConvoy?.riders[uid];
        convoyService.requestWait(me?.name ?? 'Rider');
        await _speak(match.confirmationSpeech, priority: VoicePriority.important);
        break;

      case HelmetVoiceHotword.intercom:
        if (intercomService != null) {
          final newMuted = !intercomService!.isMicMuted;
          intercomService!.setMicMuted(newMuted);
          final feedback = newMuted ? 'Intercom microphone muted.' : 'Intercom microphone active.';
          await _speak(feedback, priority: VoicePriority.important);
        }
        break;
    }
  }

  Future<void> _speak(String text, {required VoicePriority priority}) async {
    if (voiceService == null) return;
    try {
      await voiceService!.speak(
        text,
        priority: priority,
        key: 'hotword_${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _matchStream.close();
    super.dispose();
  }
}
