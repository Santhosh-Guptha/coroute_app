import 'dart:collection';
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_format.dart';

/// A stable colour per rider, the same on the timeline, the replay map and
/// the report, so a rider is recognisable everywhere.
class MemberColors {
  MemberColors._();

  /// Distinct on the current theme and from the app's alert colours (red/amber).
  static List<Color> get palette => AppTheme.palette.members;

  /// Assigns colours in the order of [userIds] (for example join order), so
  /// a small group always gets the most distinct colours. The map remembers
  /// each rider's slot, not the colour, so it follows a light/dark switch.
  static Map<String, Color> assign(Iterable<String> userIds) {
    final slots = <String, int>{};
    for (final id in userIds) {
      if (id.isEmpty || slots.containsKey(id)) continue;
      slots[id] = slots.length;
    }
    return _MemberColorMap(slots);
  }

  /// Same as [initialsOf] in the UI kit (kept for existing callers).
  static String initials(String name) => initialsOf(name);
}

class _MemberColorMap extends MapBase<String, Color> {
  _MemberColorMap(this._slots);
  final Map<String, int> _slots;

  @override
  Color? operator [](Object? key) {
    final i = _slots[key];
    if (i == null) return null;
    final p = MemberColors.palette;
    return p[i % p.length];
  }

  @override
  void operator []=(String key, Color value) {
    final p = MemberColors.palette;
    final i = p.indexOf(value);
    _slots[key] = i < 0 ? _slots.length : i;
  }

  @override
  void clear() => _slots.clear();

  @override
  Iterable<String> get keys => _slots.keys;

  @override
  Color? remove(Object? key) {
    final c = this[key];
    _slots.remove(key);
    return c;
  }
}
