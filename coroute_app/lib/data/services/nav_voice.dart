import '../../core/l10n/l10n.dart';
import '../../domain/navigation/nav_prompts.dart';
import 'voice_service.dart';

/// Says the short navigation lines ([NavPrompt]) in the rider's voice
/// language. The voice service applies the settings: with "Speak warnings"
/// off, or the group's voice switched off, nothing is said.
///
/// How often a line may be said is decided by [NavPromptGate]; the key
/// here only stops the same line twice within one minute.
class NavVoice {
  NavVoice(this.voice, {int Function()? clock}) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final VoiceService? voice;
  final int Function() _clock;

  /// Navigation lines are dropped if they could not be said within this long.
  static const Duration ttl = Duration(seconds: 20);

  /// The text for [p] in [lang].
  static String text(NavPrompt p, String lang) => L10n.t(p.l10nKey, const {}, lang);

  void say(NavPrompt p) {
    final v = voice;
    if (v == null) return;
    final minute = _clock() ~/ 60000;
    v.speak(text(p, v.speechLang), priority: VoicePriority.warning, key: 'NAV:${p.name}:$minute', ttl: ttl).ignore();
  }
}
