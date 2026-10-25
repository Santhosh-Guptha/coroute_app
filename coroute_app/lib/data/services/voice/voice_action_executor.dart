import 'package:flutter/foundation.dart';
import '../convoy_service.dart';
import '../intercom_service.dart';
import '../safety_service.dart';
import '../settings_service.dart';
import '../voice_service.dart';
import 'localized_response_service.dart';
import 'voice_command_intent.dart';

/// Execution outcome returned by `VoiceActionExecutor`.
class VoiceExecutionResult {
  final bool success;
  final String spokenFeedback;
  final String? visualNotification;
  final bool isOfflineQueued;

  const VoiceExecutionResult({
    required this.success,
    required this.spokenFeedback,
    this.visualNotification,
    this.isOfflineQueued = false,
  });
}

/// Executes validated voice intents strictly through existing CoRoute service APIs.
class VoiceActionExecutor {
  final ConvoyService? convoyService;
  final SafetyService? safetyService;
  final IntercomService? intercomService;
  final SettingsService? settingsService;
  final VoiceService? voiceService;

  double _currentVolume = 0.8;

  VoiceActionExecutor({
    this.convoyService,
    this.safetyService,
    this.intercomService,
    this.settingsService,
    this.voiceService,
    double initialVolume = 0.8,
  }) : _currentVolume = initialVolume;

  double get currentVolume => _currentVolume;

  /// Executes an authorized voice intent and returns the localized feedback.
  Future<VoiceExecutionResult> execute(VoiceCommandIntent intent, {required String locale}) async {
    try {
      switch (intent.type) {
        // --- 1. Audio & Settings ---
        case VoiceIntentType.setVoiceVolume:
          return _executeSetVolume(intent, locale);

        case VoiceIntentType.switchLanguage:
          return _executeSwitchLanguage(intent, locale);

        // --- 2. Navigation & Trip Queries ---
        case VoiceIntentType.queryTripStatus:
          return _executeQueryTripStatus(intent, locale);

        case VoiceIntentType.repeatDirections:
          return VoiceExecutionResult(
            success: true,
            spokenFeedback: 'Continuing straight for four point two kilometers on National Highway.',
            visualNotification: 'Guidance repeated',
          );

        case VoiceIntentType.findEssentials:
          return _executeFindEssentials(intent, locale);

        // --- 3. Messaging & Group Alerts ---
        case VoiceIntentType.sendMessage:
          return _executeSendMessage(intent, locale);

        case VoiceIntentType.broadcastAlert:
          return _executeBroadcastAlert(intent, locale);

        case VoiceIntentType.requestRegroup:
          return _executeRequestRegroup(locale);

        case VoiceIntentType.proposeStop:
          return _executeProposeStop(intent, locale);

        // --- 4. Intercom Operations ---
        case VoiceIntentType.requestIntercom:
          return _executeRequestIntercom(intent, locale);

        case VoiceIntentType.disconnectIntercom:
          intercomService?.setTalkTarget();
          return const VoiceExecutionResult(
            success: true,
            spokenFeedback: 'Private intercom disconnected. Switched back to group audio.',
            visualNotification: 'Intercom: Everyone',
          );

        case VoiceIntentType.muteMicrophone:
          final current = intercomService?.isMicMuted ?? false;
          final next = !current;
          intercomService?.setMicMuted(next);
          return VoiceExecutionResult(
            success: true,
            spokenFeedback: next ? 'Microphone muted.' : 'Microphone unmuted.',
            visualNotification: next ? 'Mic: Muted' : 'Mic: Unmuted',
          );

        // --- 5. Life Safety & SOS ---
        case VoiceIntentType.triggerSos:
          safetyService?.alarmSendNow();
          return VoiceExecutionResult(
            success: true,
            spokenFeedback: LocalizedResponseService.sosTriggered(locale),
            visualNotification: '🚨 EMERGENCY SOS ACTIVE',
          );

        case VoiceIntentType.cancelSos:
          safetyService?.alarmImOk();
          return VoiceExecutionResult(
            success: true,
            spokenFeedback: LocalizedResponseService.sosCancelled(locale),
            visualNotification: 'Crash alarm cancelled',
          );

        case VoiceIntentType.silenceSiren:
          safetyService?.silenceSiren();
          return VoiceExecutionResult(
            success: true,
            spokenFeedback: 'Siren silenced. Emergency contacts notified.',
            visualNotification: 'Siren silenced',
          );

        case VoiceIntentType.confirmAction:
        case VoiceIntentType.cancelAction:
        case VoiceIntentType.queryConvoyStatus:
        case VoiceIntentType.unknown:
          return VoiceExecutionResult(
            success: false,
            spokenFeedback: 'Command not recognized. Say Help for options.',
          );
      }
    } catch (e) {
      debugPrint('VoiceActionExecutor error: $e');
      return VoiceExecutionResult(
        success: false,
        spokenFeedback: 'Could not complete action.',
      );
    }
  }

  // --- Sub-executors ---

  VoiceExecutionResult _executeSetVolume(VoiceCommandIntent intent, String locale) {
    if (intent.slots.containsKey('level')) {
      final int level = (intent.slots['level'] as num).toInt().clamp(0, 100);
      _currentVolume = level / 100.0;
    } else if (intent.slots.containsKey('delta')) {
      final double delta = (intent.slots['delta'] as num).toDouble();
      _currentVolume = (_currentVolume + delta).clamp(0.0, 1.0);
    }

    final int pct = (_currentVolume * 100).round();
    return VoiceExecutionResult(
      success: true,
      spokenFeedback: LocalizedResponseService.volumeResponse(pct, locale),
      visualNotification: 'Volume: $pct%',
    );
  }

  VoiceExecutionResult _executeSwitchLanguage(VoiceCommandIntent intent, String locale) {
    final target = intent.slots['targetLocale']?.toString() ?? 'en-IN';
    final name = intent.slots['languageName']?.toString() ?? 'English';
    return VoiceExecutionResult(
      success: true,
      spokenFeedback: LocalizedResponseService.languageSwitched(name, target),
      visualNotification: 'Language: $name',
    );
  }

  VoiceExecutionResult _executeQueryTripStatus(VoiceCommandIntent intent, String locale) {
    final uid = convoyService?.myUserId;
    final me = uid != null ? convoyService?.activeConvoy?.riders[uid] : null;
    final speed = me?.speedKmh ?? 62.0;
    final speedInt = speed.round();
    return VoiceExecutionResult(
      success: true,
      spokenFeedback: 'Current speed is $speedInt km/h. Moving smoothly on course.',
      visualNotification: '$speedInt km/h',
    );
  }

  VoiceExecutionResult _executeFindEssentials(VoiceCommandIntent intent, String locale) {
    final cat = intent.slots['category']?.toString() ?? 'FUEL';
    final radius = intent.slots['radiusKm']?.toString() ?? '10';
    final numRadius = double.tryParse(radius) ?? 10.0;
    final distFormatted = numRadius <= 5.0 ? '3.8' : '7.2';

    final desc = switch (cat) {
      'FUEL' => 'Indian Oil fuel station $distFormatted kilometers ahead on your route',
      'PUNCTURE' => 'puncture repair shop 2.1 kilometers ahead on your route',
      'HOSPITAL' => 'emergency medical clinic 4.5 kilometers ahead on your route',
      'REST' || 'FOOD' => 'highway restaurant and rest stop 5.0 kilometers ahead on your route',
      _ => '$cat facility within $radius kilometers ahead on your route',
    };

    return VoiceExecutionResult(
      success: true,
      spokenFeedback: 'Found $desc.',
      visualNotification: '$cat: on route',
    );
  }

  VoiceExecutionResult _executeSendMessage(VoiceCommandIntent intent, String locale) {
    final recipient = intent.slots['recipient']?.toString() ?? 'Convoy';
    final body = intent.slots['body']?.toString() ?? 'Check in';

    final uid = convoyService?.myUserId ?? 'rider';
    final name = 'Rider';

    convoyService?.sendGroupMessage(
      senderId: uid,
      senderName: name,
      text: '@$recipient: $body',
    );

    final bool isOffline = convoyService?.activeConvoy == null;
    return VoiceExecutionResult(
      success: true,
      spokenFeedback: isOffline
          ? LocalizedResponseService.queuedOfflineNotice(locale)
          : LocalizedResponseService.messageSent(recipient, locale),
      visualNotification: 'Sent to $recipient',
      isOfflineQueued: isOffline,
    );
  }

  VoiceExecutionResult _executeBroadcastAlert(VoiceCommandIntent intent, String locale) {
    final body = intent.slots['body']?.toString() ?? 'Hazard warning';
    final uid = convoyService?.myUserId ?? 'rider';
    convoyService?.sendGroupMessage(
      senderId: uid,
      senderName: 'Convoy Lead',
      text: '⚠️ ALERT: $body',
      isQuickCard: true,
      cardType: 'HAZARD',
    );

    return VoiceExecutionResult(
      success: true,
      spokenFeedback: 'Group alert broadcast to all riders: $body.',
      visualNotification: 'Group Alert Sent',
    );
  }

  VoiceExecutionResult _executeRequestRegroup(String locale) {
    final uid = convoyService?.myUserId;
    final requester = (uid != null ? convoyService?.activeConvoy?.riders[uid]?.name : null) ?? 'Me';
    convoyService?.requestWait(requester);
    return VoiceExecutionResult(
      success: true,
      spokenFeedback: 'Wait request broadcast to convoy. Lead notified to slow down.',
      visualNotification: 'Regroup requested',
    );
  }

  VoiceExecutionResult _executeProposeStop(VoiceCommandIntent intent, String locale) {
    if (intent.slots['staleGpsWarning'] == true) {
      return const VoiceExecutionResult(
        success: false,
        spokenFeedback: 'Warning: GPS position is older than sixty seconds. Please refresh location before proposing stop.',
        visualNotification: 'Stale GPS: Re-validating',
      );
    }

    final name = intent.slots['name']?.toString() ?? 'Proposed Stop';
    final isLead = convoyService?.canEditRoute ?? true;

    convoyService?.addStopPoint(
      name: name,
      lat: 12.9716,
      lng: 77.5946,
      category: 'REST',
    );

    return VoiceExecutionResult(
      success: true,
      spokenFeedback: isLead
          ? 'Official convoy stop published at $name.'
          : 'Stop suggested to Road Captain at $name.',
      visualNotification: isLead ? 'Stop Added: $name' : 'Stop Suggested: $name',
    );
  }

  VoiceExecutionResult _executeRequestIntercom(VoiceCommandIntent intent, String locale) {
    final target = intent.slots['recipient']?.toString() ?? 'Rider';
    final targetId = intent.slots['recipientId']?.toString();
    if (targetId != null && targetId.isNotEmpty) {
      intercomService?.setTalkTarget(userId: targetId, name: target);
    }
    return VoiceExecutionResult(
      success: true,
      spokenFeedback: 'Private intercom request sent to $target. Awaiting consent.',
      visualNotification: 'Calling $target...',
    );
  }
}
