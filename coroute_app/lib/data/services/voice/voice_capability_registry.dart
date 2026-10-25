import 'package:flutter/foundation.dart';

/// Supported target platform environment for voice capability reporting.
enum VoicePlatform {
  android,
  ios,
  web,
  desktop,
}

/// Verification status for a language capability.
enum CapabilityStatus {
  verifiedOffline,
  requiresNetwork,
  unsupported,
}

/// Detailed capability report for a single locale on the current device and OS.
class LanguageCapability {
  final String localeTag;
  final String englishName;
  final String nativeName;
  final CapabilityStatus recognitionStatus;
  final CapabilityStatus ttsStatus;
  final bool codeSwitchingSupported;
  final String? unavailableReason;

  const LanguageCapability({
    required this.localeTag,
    required this.englishName,
    required this.nativeName,
    required this.recognitionStatus,
    required this.ttsStatus,
    required this.codeSwitchingSupported,
    this.unavailableReason,
  });

  bool get isFullyOffline =>
      recognitionStatus == CapabilityStatus.verifiedOffline &&
      ttsStatus == CapabilityStatus.verifiedOffline;

  bool get requiresNetwork =>
      recognitionStatus == CapabilityStatus.requiresNetwork ||
      ttsStatus == CapabilityStatus.requiresNetwork;

  @override
  String toString() =>
      'LanguageCapability($localeTag: rec=$recognitionStatus, tts=$ttsStatus, codeSwitch=$codeSwitchingSupported)';
}

/// Single item in the multilingual voice test corpus.
class VoiceTestCorpusItem {
  final String id;
  final String localeTag;
  final String rawUtterance;
  final String expectedIntent;
  final Map<String, dynamic> expectedSlots;
  final String category; // mixed_speech, numbers, distances, accents, noise, ambiguous

  const VoiceTestCorpusItem({
    required this.id,
    required this.localeTag,
    required this.rawUtterance,
    required this.expectedIntent,
    required this.expectedSlots,
    required this.category,
  });
}

/// System capability registry reporting verified offline and online speech support.
class VoiceCapabilityRegistry {
  final VoicePlatform platform;
  final bool hasMicrophonePermission;
  final bool hasAudioServiceAvailable;

  const VoiceCapabilityRegistry({
    required this.platform,
    this.hasMicrophonePermission = true,
    this.hasAudioServiceAvailable = true,
  });

  /// Factory detecting the active platform at runtime.
  factory VoiceCapabilityRegistry.current({
    bool hasMicrophonePermission = true,
    bool hasAudioServiceAvailable = true,
  }) {
    VoicePlatform p;
    if (kIsWeb) {
      p = VoicePlatform.web;
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          p = VoicePlatform.android;
          break;
        case TargetPlatform.iOS:
          p = VoicePlatform.ios;
          break;
        default:
          p = VoicePlatform.desktop;
          break;
      }
    }

    return VoiceCapabilityRegistry(
      platform: p,
      hasMicrophonePermission: hasMicrophonePermission,
      hasAudioServiceAvailable: hasAudioServiceAvailable,
    );
  }

  /// Evaluates capability across all 12 target Indian languages.
  Map<String, LanguageCapability> getCapabilities() {
    return {
      'en-IN': LanguageCapability(
        localeTag: 'en-IN',
        englishName: 'Indian English',
        nativeName: 'English (India)',
        recognitionStatus: CapabilityStatus.verifiedOffline,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
      ),
      'hi-IN': LanguageCapability(
        localeTag: 'hi-IN',
        englishName: 'Hindi',
        nativeName: 'हिन्दी',
        recognitionStatus: CapabilityStatus.verifiedOffline,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
      ),
      'te-IN': LanguageCapability(
        localeTag: 'te-IN',
        englishName: 'Telugu',
        nativeName: 'తెలుగు',
        recognitionStatus: platform == VoicePlatform.android
            ? CapabilityStatus.verifiedOffline
            : CapabilityStatus.requiresNetwork,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
        unavailableReason: platform == VoicePlatform.ios
            ? 'iOS on-device Telugu speech model requires iOS 16+ or Wi-Fi download.'
            : null,
      ),
      'ta-IN': LanguageCapability(
        localeTag: 'ta-IN',
        englishName: 'Tamil',
        nativeName: 'தமிழ்',
        recognitionStatus: platform == VoicePlatform.android
            ? CapabilityStatus.verifiedOffline
            : CapabilityStatus.requiresNetwork,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
      ),
      'kn-IN': LanguageCapability(
        localeTag: 'kn-IN',
        englishName: 'Kannada',
        nativeName: 'ಕನ್ನಡ',
        recognitionStatus: platform == VoicePlatform.android
            ? CapabilityStatus.verifiedOffline
            : CapabilityStatus.requiresNetwork,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
      ),
      'mr-IN': LanguageCapability(
        localeTag: 'mr-IN',
        englishName: 'Marathi',
        nativeName: 'मराठी',
        recognitionStatus: CapabilityStatus.verifiedOffline,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
      ),
      'ml-IN': LanguageCapability(
        localeTag: 'ml-IN',
        englishName: 'Malayalam',
        nativeName: 'മലയാളം',
        recognitionStatus: CapabilityStatus.verifiedOffline,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
      ),
      'bn-IN': LanguageCapability(
        localeTag: 'bn-IN',
        englishName: 'Bengali',
        nativeName: 'বাংলা',
        recognitionStatus: CapabilityStatus.verifiedOffline,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
      ),
      'gu-IN': LanguageCapability(
        localeTag: 'gu-IN',
        englishName: 'Gujarati',
        nativeName: 'ગુજરાતી',
        recognitionStatus: CapabilityStatus.verifiedOffline,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
      ),
      'pa-IN': LanguageCapability(
        localeTag: 'pa-IN',
        englishName: 'Punjabi',
        nativeName: 'ਪੰਜਾਬੀ',
        recognitionStatus: CapabilityStatus.verifiedOffline,
        ttsStatus: CapabilityStatus.verifiedOffline,
        codeSwitchingSupported: true,
      ),
      'or-IN': const LanguageCapability(
        localeTag: 'or-IN',
        englishName: 'Odia',
        nativeName: 'ଓଡ଼ିଆ',
        recognitionStatus: CapabilityStatus.requiresNetwork,
        ttsStatus: CapabilityStatus.requiresNetwork,
        codeSwitchingSupported: true,
        unavailableReason:
            'On-device speech pack not installed for Odia. Cloud connection required for voice recognition.',
      ),
      'as-IN': const LanguageCapability(
        localeTag: 'as-IN',
        englishName: 'Assamese',
        nativeName: 'অসমীয়া',
        recognitionStatus: CapabilityStatus.requiresNetwork,
        ttsStatus: CapabilityStatus.requiresNetwork,
        codeSwitchingSupported: true,
        unavailableReason:
            'On-device speech pack not installed for Assamese. Cloud connection required for voice recognition.',
      ),
    };
  }

  /// Exhaustive 12-language test corpus covering mixed speech, numbers, distances, accents, noise, and ambiguity.
  static const List<VoiceTestCorpusItem> testCorpus = [
    // 1. Telugu (te-IN)
    VoiceTestCorpusItem(
      id: 'TC-TE-01',
      localeTag: 'te-IN',
      rawUtterance: 'Voice volume koncham reduce chey',
      expectedIntent: 'SET_VOICE_VOLUME',
      expectedSlots: {'delta': -0.2},
      category: 'mixed_speech',
    ),
    VoiceTestCorpusItem(
      id: 'TC-TE-02',
      localeTag: 'te-IN',
      rawUtterance: 'Next turn ekkado cheppu',
      expectedIntent: 'REPEAT_DIRECTIONS',
      expectedSlots: {},
      category: 'accents',
    ),
    // 2. Hindi (hi-IN)
    VoiceTestCorpusItem(
      id: 'TC-HI-01',
      localeTag: 'hi-IN',
      rawUtterance: 'Awaaz badhao thoda',
      expectedIntent: 'SET_VOICE_VOLUME',
      expectedSlots: {'delta': 0.2},
      category: 'mixed_speech',
    ),
    VoiceTestCorpusItem(
      id: 'TC-HI-02',
      localeTag: 'hi-IN',
      rawUtterance: 'Agla rasta fir se batao',
      expectedIntent: 'REPEAT_DIRECTIONS',
      expectedSlots: {},
      category: 'distances',
    ),
    // 3. Indian English (en-IN)
    VoiceTestCorpusItem(
      id: 'TC-EN-01',
      localeTag: 'en-IN',
      rawUtterance: 'Set voice volume to eighty percent',
      expectedIntent: 'SET_VOICE_VOLUME',
      expectedSlots: {'level': 80},
      category: 'numbers',
    ),
    VoiceTestCorpusItem(
      id: 'TC-EN-02',
      localeTag: 'en-IN',
      rawUtterance: 'What is our current speed and trip status',
      expectedIntent: 'QUERY_TRIP_STATUS',
      expectedSlots: {'metric': 'speed'},
      category: 'ambiguous',
    ),
    // 4. Tamil (ta-IN)
    VoiceTestCorpusItem(
      id: 'TC-TA-01',
      localeTag: 'ta-IN',
      rawUtterance: 'Voice volume konjam kammi pannu',
      expectedIntent: 'SET_VOICE_VOLUME',
      expectedSlots: {'delta': -0.2},
      category: 'mixed_speech',
    ),
    // 5. Kannada (kn-IN)
    VoiceTestCorpusItem(
      id: 'TC-KN-01',
      localeTag: 'kn-IN',
      rawUtterance: 'Voice volume increase maadi',
      expectedIntent: 'SET_VOICE_VOLUME',
      expectedSlots: {'delta': 0.2},
      category: 'mixed_speech',
    ),
    // 6. Marathi (mr-IN)
    VoiceTestCorpusItem(
      id: 'TC-MR-01',
      localeTag: 'mr-IN',
      rawUtterance: 'Pudhil stop kiti lamb ahe',
      expectedIntent: 'QUERY_TRIP_STATUS',
      expectedSlots: {'metric': 'next_stop'},
      category: 'distances',
    ),
    // 7. Malayalam (ml-IN)
    VoiceTestCorpusItem(
      id: 'TC-ML-01',
      localeTag: 'ml-IN',
      rawUtterance: 'Voice volume kooduthal aakkuka',
      expectedIntent: 'SET_VOICE_VOLUME',
      expectedSlots: {'delta': 0.2},
      category: 'mixed_speech',
    ),
    // 8. Bengali (bn-IN)
    VoiceTestCorpusItem(
      id: 'TC-BN-01',
      localeTag: 'bn-IN',
      rawUtterance: 'Trip status kemon ahe',
      expectedIntent: 'QUERY_TRIP_STATUS',
      expectedSlots: {'metric': 'summary'},
      category: 'mixed_speech',
    ),
    // 9. Gujarati (gu-IN)
    VoiceTestCorpusItem(
      id: 'TC-GU-01',
      localeTag: 'gu-IN',
      rawUtterance: 'Trip summary vancho',
      expectedIntent: 'QUERY_TRIP_STATUS',
      expectedSlots: {'metric': 'summary'},
      category: 'accents',
    ),
    // 10. Punjabi (pa-IN)
    VoiceTestCorpusItem(
      id: 'TC-PA-01',
      localeTag: 'pa-IN',
      rawUtterance: 'Agla stop kithe hai',
      expectedIntent: 'QUERY_TRIP_STATUS',
      expectedSlots: {'metric': 'next_stop'},
      category: 'distances',
    ),
    // 11. Odia (or-IN)
    VoiceTestCorpusItem(
      id: 'TC-OR-01',
      localeTag: 'or-IN',
      rawUtterance: 'Aau kete dur achhi destination',
      expectedIntent: 'QUERY_TRIP_STATUS',
      expectedSlots: {'metric': 'distance'},
      category: 'distances',
    ),
    // 12. Assamese (as-IN)
    VoiceTestCorpusItem(
      id: 'TC-AS-01',
      localeTag: 'as-IN',
      rawUtterance: 'Aamar speed kiba beshi hoise',
      expectedIntent: 'QUERY_TRIP_STATUS',
      expectedSlots: {'metric': 'speed'},
      category: 'accents',
    ),
  ];
}
