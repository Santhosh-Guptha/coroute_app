import 'voice_command_intent.dart';

/// Enforcement engine for safety gates, risk tier classifications, and role validations.
class VoiceSafetyPolicy {
  /// Evaluates whether an intent is safe to execute.
  /// Returns null if valid, or a rejection explanation string if rejected.
  static String? validateIntent({
    required VoiceCommandIntent intent,
    required bool isRoadCaptain,
    required bool isConvoyActive,
  }) {
    // 1. Check forbidden voice actions
    if (_isForbiddenAction(intent)) {
      return 'Safety rule: Modifying core safety settings via voice is disabled while riding.';
    }

    // 2. Convoy requirement check
    if ((intent.type == VoiceIntentType.broadcastAlert ||
            intent.type == VoiceIntentType.requestRegroup ||
            intent.type == VoiceIntentType.proposeStop ||
            intent.type == VoiceIntentType.requestIntercom) &&
        !isConvoyActive) {
      return 'No active convoy found. Join a ride group first.';
    }

    // 3. Road Captain authorization gate for structural group mutations (Tier 3)
    if (intent.type == VoiceIntentType.proposeStop && !isRoadCaptain) {
      // Proposing a stop is permitted as a suggestion, but pushing direct waypoint requires lead
      if (intent.slots['forceWaypoint'] == true) {
        return 'Only the Road Captain may alter the official route polyline.';
      }
    }

    return null;
  }

  /// Whether an intent requires explicit verbal or PTT confirmation before execution.
  static bool requiresConfirmation(VoiceCommandIntent intent) {
    if (intent.riskTier >= 2) return true;
    return intent.requiresConfirmation;
  }

  /// Prohibits dangerous operations from being executed via voice.
  static bool _isForbiddenAction(VoiceCommandIntent intent) {
    final raw = intent.rawTranscript.toLowerCase();
    if (raw.contains('disable crash') ||
        raw.contains('turn off crash') ||
        raw.contains('stop crash detection') ||
        raw.contains('delete map') ||
        raw.contains('delete offline') ||
        raw.contains('reset telemetry') ||
        raw.contains('revoke guardian')) {
      return true;
    }
    return false;
  }
}
