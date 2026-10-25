/// Enumeration of all normalized voice intent types across supported domains.
enum VoiceIntentType {
  // Settings & Audio
  setVoiceVolume,
  switchLanguage,

  // Navigation & Status
  queryTripStatus,
  repeatDirections,
  findEssentials,
  proposeStop,

  // Messaging & Convoy Alerts
  sendMessage,
  broadcastAlert,
  queryConvoyStatus,
  requestRegroup,

  // Intercom Communication
  requestIntercom,
  disconnectIntercom,
  muteMicrophone,

  // Safety & Emergency
  triggerSos,
  cancelSos,
  silenceSiren,

  // Conversational Flow
  confirmAction,
  cancelAction,

  // Unrecognized
  unknown,
}

/// Normalized, language-independent intent schema produced by `IntentResolver`.
class VoiceCommandIntent {
  final VoiceIntentType type;
  final Map<String, dynamic> slots;
  final String sourceLocale;
  final double confidenceScore;
  final bool requiresConfirmation;
  final String rawTranscript;
  final int riskTier;

  const VoiceCommandIntent({
    required this.type,
    this.slots = const {},
    required this.sourceLocale,
    this.confidenceScore = 1.0,
    this.requiresConfirmation = false,
    required this.rawTranscript,
    this.riskTier = 1,
  });

  /// Factory helper for unknown or unparseable utterances.
  factory VoiceCommandIntent.unknown({
    required String rawTranscript,
    required String sourceLocale,
    double confidenceScore = 0.0,
  }) {
    return VoiceCommandIntent(
      type: VoiceIntentType.unknown,
      sourceLocale: sourceLocale,
      confidenceScore: confidenceScore,
      rawTranscript: rawTranscript,
      riskTier: 1,
    );
  }

  /// Convenience copyWith.
  VoiceCommandIntent copyWith({
    VoiceIntentType? type,
    Map<String, dynamic>? slots,
    String? sourceLocale,
    double? confidenceScore,
    bool? requiresConfirmation,
    String? rawTranscript,
    int? riskTier,
  }) {
    return VoiceCommandIntent(
      type: type ?? this.type,
      slots: slots ?? this.slots,
      sourceLocale: sourceLocale ?? this.sourceLocale,
      confidenceScore: confidenceScore ?? this.confidenceScore,
      requiresConfirmation: requiresConfirmation ?? this.requiresConfirmation,
      rawTranscript: rawTranscript ?? this.rawTranscript,
      riskTier: riskTier ?? this.riskTier,
    );
  }

  @override
  String toString() =>
      'VoiceCommandIntent(type: $type, slots: $slots, locale: $sourceLocale, conf: ${(confidenceScore * 100).round()}%, tier: $riskTier, raw: "$rawTranscript")';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VoiceCommandIntent &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          sourceLocale == other.sourceLocale &&
          rawTranscript == other.rawTranscript;

  @override
  int get hashCode => Object.hash(type, sourceLocale, rawTranscript);
}
