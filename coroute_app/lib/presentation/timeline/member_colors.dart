import 'package:flutter/material.dart';

/// A stable colour per rider, the same on the timeline, the replay map and
/// the report, so a rider is recognisable everywhere.
class MemberColors {
  MemberColors._();

  // Distinct on the dark theme and from the app's alert colours (red/amber).
  static const List<Color> palette = [
    Color(0xFF00E5FF), // cyan
    Color(0xFF7CFF6B), // green
    Color(0xFFFFD54F), // yellow
    Color(0xFFFF80AB), // pink
    Color(0xFF82B1FF), // blue
    Color(0xFFB388FF), // violet
    Color(0xFF64FFDA), // teal
    Color(0xFFFFAB91), // peach
    Color(0xFFE6EE9C), // lime
    Color(0xFF80DEEA), // aqua
  ];

  /// Assigns colours in the order of [userIds] (for example join order), so
  /// a small group always gets the most distinct colours.
  static Map<String, Color> assign(Iterable<String> userIds) {
    final out = <String, Color>{};
    var i = 0;
    for (final id in userIds) {
      if (id.isEmpty || out.containsKey(id)) continue;
      out[id] = palette[i % palette.length];
      i++;
    }
    return out;
  }

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}
