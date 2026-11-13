// Round 10 rescue beacon: the light pattern (camera torch, or a screen flash when the torch is not
// available). Pure Dart; the native side (RescueBeaconChannel.kt) enforces the same rate limit
// again before it switches the torch.
//
// Pattern: SOS in Morse ( . . .  - - -  . . . ), unit 250 ms: a dot is 250 ms on + 250 ms off,
// so the fastest part flashes at 2 per second.
//
// PHOTOSENSITIVITY: flashing between 3 and 60 per second can trigger seizures (WCAG 2.3.1 and the
// broadcast guidance it follows use "no more than three flashes in any one second"). This pattern
// never has more than [maxFlashesPerSecond] flash onsets in any 1 s window, every on + off cycle is
// at least [minCycleMs] long, and [RescueStrobe.validate] / the native code refuse anything faster.

class RescueStrobe {
  RescueStrobe._();

  /// The hard limit (flash onsets in any 1 s window).
  static const int maxFlashesPerSecond = 3;

  /// Shortest allowed on + off cycle (ms): 1000 / 3, rounded up.
  static const int minCycleMs = 334;

  static const int unitMs = 250;

  /// Alternating on / off durations in ms, starting with "on", for one SOS word (repeat it).
  static List<int> sosPattern({int unit = unitMs}) {
    final u = unit < 167 ? 167 : unit; // a dot cycle (2 units) never shorter than minCycleMs
    final out = <int>[];
    void letter(List<int> marks) {
      for (var i = 0; i < marks.length; i++) {
        out.add(marks[i] * u); // on
        out.add(i == marks.length - 1 ? 3 * u : u); // off: letter gap after the last mark
      }
    }

    letter(const [1, 1, 1]); // S
    letter(const [3, 3, 3]); // O
    letter(const [1, 1, 1]); // S
    out[out.length - 1] = 7 * u; // word gap before the repeat
    return out;
  }

  /// The most flash onsets in any 1000 ms window over [repeats] repetitions of [pattern].
  static int peakFlashesPerSecond(List<int> pattern, {int repeats = 3}) {
    final onsets = <int>[];
    var t = 0;
    for (var r = 0; r < repeats; r++) {
      for (var i = 0; i < pattern.length; i++) {
        if (i.isEven) onsets.add(t);
        t += pattern[i];
      }
    }
    var peak = 0;
    for (var i = 0; i < onsets.length; i++) {
      var n = 0;
      for (var j = i; j < onsets.length && onsets[j] < onsets[i] + 1000; j++) {
        n++;
      }
      if (n > peak) peak = n;
    }
    return peak;
  }

  /// True when [pattern] is safe: even length, all positive, every on + off cycle at least
  /// [minCycleMs] and never more than [maxFlashesPerSecond] onsets in any second.
  static bool validate(List<int> pattern) {
    if (pattern.isEmpty || pattern.length.isOdd) return false;
    for (final d in pattern) {
      if (d <= 0) return false;
    }
    for (var i = 0; i + 1 < pattern.length; i += 2) {
      if (pattern[i] + pattern[i + 1] < minCycleMs) return false;
    }
    return peakFlashesPerSecond(pattern) <= maxFlashesPerSecond;
  }

  /// Whether the light should flash: dark enough to be seen, and the phone not face-down or in
  /// a pocket (light sensor / proximity "near" means covered: flashing then only wastes battery).
  /// Unknown sensors: [lux] null counts as dark only at night ([isNight]); [covered] null = not.
  static bool shouldFlash({double? lux, bool? covered, bool? faceDown, required bool isNight}) {
    if (covered == true || faceDown == true) return false;
    if (lux != null) return lux < 40;
    return isNight;
  }
}
