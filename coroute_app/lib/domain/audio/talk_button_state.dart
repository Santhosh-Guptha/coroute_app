/// v3.61: what the cockpit's compact talk button shows (pure, no Flutter).
///
/// One button, three easy ways to talk (owner, 15 Nov 2026):
/// * hold to talk (default): press and hold, let go to stop;
/// * hands-free: the mic opens by itself when the rider speaks (tap the button to stop);
/// * private: either of the above, heard by one rider only.
enum TalkButtonLook { idle, talking, hearing, handsFree, muted, off }

class TalkButtonState {
  const TalkButtonState({required this.look, required this.label, required this.hint, required this.private});

  final TalkButtonLook look;

  /// Short text on the button ("Talk", "Live", "Anu", "Muted").
  final String label;

  /// Screen reader text and the tap hint.
  final String hint;
  final bool private;

  /// [privateName] is the private listener's name (null: everyone hears).
  static TalkButtonState of({
    required bool transmitting,
    required bool receiving,
    required bool handsFree,
    required bool muted,
    required bool available,
    String? privateName,
    String? speakerName,
  }) {
    final first = privateName == null || privateName.trim().isEmpty ? null : privateName.trim().split(RegExp(r'\s+')).first;
    final private = first != null;
    final to = private ? 'only $first hears you' : 'the group hears you';
    if (!available) return const TalkButtonState(look: TalkButtonLook.off, label: 'Talk', hint: 'Talk is not available right now', private: false);
    if (muted) return const TalkButtonState(look: TalkButtonLook.muted, label: 'Muted', hint: 'Microphone muted. Tap to unmute', private: false);
    if (transmitting) {
      return TalkButtonState(look: TalkButtonLook.talking, label: private ? first : 'Live', hint: 'Talking, $to', private: private);
    }
    if (handsFree) {
      return TalkButtonState(look: TalkButtonLook.handsFree, label: private ? first : 'Free', hint: 'Hands-free on: just speak, $to. Tap to stop hands-free', private: private);
    }
    if (receiving) {
      final who = speakerName == null || speakerName.trim().isEmpty ? 'A rider' : speakerName.trim().split(RegExp(r'\s+')).first;
      return TalkButtonState(look: TalkButtonLook.hearing, label: who, hint: '$who is talking. Hold to talk', private: private);
    }
    return TalkButtonState(look: TalkButtonLook.idle, label: private ? first : 'Talk', hint: 'Hold to talk, $to', private: private);
  }
}
