/// Round 11 ride HUD: the pure rules behind the redesigned ride screen (no Flutter imports, so the
/// plain Dart VM can test them: test/hud_logic_test.dart).
///
///  * [HudTurnText]   turn card wording: live distance, instruction with the road, the "then" line.
///  * [HudGroupPill]  "5 riders · lead 1.2 km ahead" in the collapsed sheet.
///  * [HudSheet]      sheet snap points, the state for an extent, what each state shows.
///  * [HudSpeedRing]  the speed ring colour level against the effective limit.
///  * [HudSafetyStripRules] one advisory at a time, ordered like the round 7 warning scheduler.
///  * [HudFormat]     short numbers for the sheet (moving time, km, km/h).
library;

import '../../../domain/safety/warning_scheduler.dart';

// ------------------------------------------------------------------------------- turn card

/// Same values as `TurnDirection` in lib/domain/route/next_turn.dart (that file reaches Flutter
/// through the route model, so this pure file keeps its own copy; the widget maps by name).
enum HudTurnDir { straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn }

class HudTurnText {
  const HudTurnText._();

  /// Within this distance the card says "Now" instead of a number.
  static const double nowM = 20;

  /// The "then" line shows when the next manoeuvre is at most this far after the first one...
  static const double thenGapM = 300;

  /// ...and the first one is at most this far away (further out the second does not matter yet).
  static const double thenWithinM = 1500;

  /// Live countdown distance: finer steps as the turn comes closer, so the number moves every few
  /// seconds without flickering. "Now", "80 m", "350 m", "1.2 km", "14 km".
  static String distance(double m) {
    if (!m.isFinite || m < 0) return '';
    if (m <= nowM) return 'Now';
    if (m < 100) return '${(m / 10).round() * 10} m';
    if (m < 1000) {
      final r = (m / 50).round() * 50;
      return r >= 1000 ? '1.0 km' : '$r m';
    }
    if (m < 10000) return '${(m / 1000).toStringAsFixed(1)} km';
    return '${(m / 1000).round()} km';
  }

  /// "Turn left onto MG Road", "Keep right onto NH 44", "Continue on NH 44", "Turn left".
  static String instruction(HudTurnDir d, String road) {
    final verb = _verb(d);
    final r = road.trim();
    if (r.isEmpty) return verb;
    if (d == HudTurnDir.straight) return 'Continue on $r';
    if (d == HudTurnDir.uTurn) return '$verb to $r';
    return '$verb onto $r';
  }

  static String _verb(HudTurnDir d) => switch (d) {
        HudTurnDir.straight => 'Continue',
        HudTurnDir.slightLeft => 'Keep left',
        HudTurnDir.slightRight => 'Keep right',
        HudTurnDir.left => 'Turn left',
        HudTurnDir.right => 'Turn right',
        HudTurnDir.sharpLeft => 'Sharp left',
        HudTurnDir.sharpRight => 'Sharp right',
        HudTurnDir.uTurn => 'Make a U-turn',
      };

  /// "Then turn right onto Ring Rd" when the manoeuvre after [turns].first is close, else null.
  /// A "continue" (road name change without a bend) is not worth a then-line.
  static String? thenLine(List<({HudTurnDir direction, double distanceM, String road})> turns) {
    if (turns.length < 2) return null;
    final a = turns[0], b = turns[1];
    if (b.direction == HudTurnDir.straight) return null;
    if (a.distanceM > thenWithinM) return null;
    if (b.distanceM - a.distanceM > thenGapM || b.distanceM < a.distanceM) return null;
    final text = instruction(b.direction, b.road);
    return 'Then ${text[0].toLowerCase()}${text.substring(1)}';
  }

  /// The card's title when there is no route: the road I am on, or a plain "Free ride".
  static String freeRideTitle(String? roadName) {
    final r = roadName?.trim() ?? '';
    return r.isEmpty ? 'Free ride' : r;
  }
}

// ------------------------------------------------------------------------------- group pill

class HudGroupPill {
  const HudGroupPill._();

  /// The short group line of the collapsed sheet, most useful fact first:
  ///  * solo: "Solo ride";
  ///  * someone falling behind (lead / sweep only): "5 riders · Ravi falling behind" / "2 falling behind";
  ///  * I follow: "5 riders · lead 1.2 km ahead";
  ///  * I lead: "5 riders · last 800 m behind";
  ///  * otherwise "5 riders · 4 riding".
  static String text({
    required int riders,
    bool solo = false,
    int riding = -1,
    double? leadAheadM,
    double? lastBehindM,
    bool iAmLead = false,
    List<String> fallingBehind = const [],
    String? connection,
  }) {
    if (solo || riders <= 1) return connection == null ? 'Solo ride' : 'Solo ride · $connection';
    final head = '$riders riders';
    if (connection != null) return '$head · $connection';
    if (fallingBehind.length == 1) return '$head · ${_short(fallingBehind.first)} falling behind';
    if (fallingBehind.length > 1) return '$head · ${fallingBehind.length} falling behind';
    if (!iAmLead && leadAheadM != null && leadAheadM >= 0) return '$head · lead ${_dist(leadAheadM)} ahead';
    if (iAmLead && lastBehindM != null && lastBehindM >= 0) return '$head · last ${_dist(lastBehindM)} behind';
    if (riding >= 0) return '$head · $riding riding';
    return head;
  }

  /// A rider's row in the group list: "1.2 km ahead · 3 min" (the time is how long the gap takes
  /// at [speedKmh], shown only while moving at 10 km/h or more), '' when unknown.
  static String riderGap(double? fromMeM, {double speedKmh = 0}) {
    if (fromMeM == null || !fromMeM.isFinite) return '';
    final d = fromMeM.abs();
    if (d < 50) return 'With you';
    final where = '${_dist(d)} ${fromMeM > 0 ? 'ahead' : 'behind'}';
    if (speedKmh < 10) return where;
    final min = (d / (speedKmh / 3.6) / 60).round();
    return min < 1 ? where : '$where · $min min';
  }

  /// Which tone the pill takes: warn when someone falls behind or the link is down.
  static bool warn({List<String> fallingBehind = const [], String? connection}) => fallingBehind.isNotEmpty || connection != null;

  static String _short(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'A rider';
    final first = n.split(RegExp(r'\s+')).first;
    return first.length > 12 ? '${first.substring(0, 11)}…' : first;
  }

  static String _dist(double m) {
    if (m < 1000) return '${(m / 50).round() * 50} m';
    if (m < 10000) return '${(m / 1000).toStringAsFixed(1)} km';
    return '${(m / 1000).round()} km';
  }
}

// ------------------------------------------------------------------------------- sheet

enum HudSheetState { collapsed, half, full }

enum HudSection {
  speedRow,
  groupPill,
  talkBar,
  arcSpeedometer,
  etaRow,
  rideSoFar,
  speedBands,
  overLimit,
  groupList,
  intercom,
  chatPreview,
  tripChart,
  fuelNextStop,
  weather,
  manage,
  lifecycle,
}

class HudSheet {
  const HudSheet._();

  /// The three resting points as screen fractions: collapsed (measured header), half, full.
  /// Half sits halfway between when the screen is too short for a clear 0.5 (large text, small phones).
  static (double, double, double) snapPoints({required double screenH, required double collapsedPx, double maxFraction = 0.85}) {
    if (screenH <= 0) return (0.3, 0.55, 0.85);
    final min = (collapsedPx / screenH).clamp(0.05, 0.8).toDouble();
    final max = maxFraction < min + 0.25 ? (min + 0.25).clamp(min, 0.95).toDouble() : maxFraction.clamp(min, 1.0).toDouble();
    var half = 0.55;
    if (!(min + 0.08 < half && half < max - 0.08)) half = (min + max) / 2;
    return (min, half, max);
  }

  /// The state an extent is closest to.
  static HudSheetState stateFor(double extent, (double, double, double) snaps) {
    final (min, half, max) = snaps;
    final dMin = (extent - min).abs(), dHalf = (extent - half).abs(), dMax = (extent - max).abs();
    if (dMin <= dHalf && dMin <= dMax) return HudSheetState.collapsed;
    if (dHalf <= dMax) return HudSheetState.half;
    return HudSheetState.full;
  }

  /// A tap on the handle: collapsed -> half -> full -> collapsed.
  static HudSheetState next(HudSheetState s) => switch (s) {
        HudSheetState.collapsed => HudSheetState.half,
        HudSheetState.half => HudSheetState.full,
        HudSheetState.full => HudSheetState.collapsed,
      };

  /// What is on screen in a state (in order). Collapsed is always on top of the others, so the
  /// speed, ETA, End ride and talk controls never scroll away while the sheet is collapsed.
  static List<HudSection> sections(HudSheetState s, {required bool solo, required bool hasRoute, bool groupFeatures = true}) {
    final group = !solo && groupFeatures;
    final collapsed = <HudSection>[HudSection.speedRow, HudSection.groupPill, if (group) HudSection.talkBar];
    if (s == HudSheetState.collapsed) return collapsed;
    final half = <HudSection>[
      ...collapsed,
      HudSection.arcSpeedometer,
      HudSection.etaRow,
      HudSection.rideSoFar,
      HudSection.speedBands,
      HudSection.overLimit,
    ];
    if (s == HudSheetState.half) return half;
    return [
      ...half,
      if (group) HudSection.groupList,
      if (group) HudSection.intercom,
      if (group) HudSection.chatPreview,
      HudSection.tripChart,
      HudSection.fuelNextStop,
      HudSection.weather,
      HudSection.manage,
      HudSection.lifecycle,
    ];
  }

  /// Landscape handlebar mount: the sheet becomes a side panel when the window is wide and short.
  static bool sidePanel({required double width, required double height}) => width > height && width >= 560;

  /// Side panel width (landscape).
  static double sidePanelWidth(double width) => (width * 0.42).clamp(320.0, 420.0).toDouble();
}

// ------------------------------------------------------------------------------- speed ring

enum HudSpeedLevel { none, normal, over, strong }

class HudSpeedRing {
  const HudSpeedRing._();

  /// Round 9: the automatic overspeed margin (+10 %).
  static const double margin = 0.10;

  /// none: no limit known; normal: at or under; over (amber): above the limit but within the
  /// margin; strong (red): above the margin (where the voice warning speaks).
  static HudSpeedLevel level(double speedKmh, int limitKmh) {
    if (limitKmh <= 0) return HudSpeedLevel.none;
    if (!speedKmh.isFinite || speedKmh <= limitKmh) return HudSpeedLevel.normal;
    final strongAt = limitKmh * (1 + margin);
    return speedKmh > strongAt ? HudSpeedLevel.strong : HudSpeedLevel.over;
  }

  /// Dial scale top: 120 for bikes that rarely pass 100, else 160 / 200 (always above the limit).
  static int dialMax({required double peakKmh, required int limitKmh}) {
    final need = [peakKmh, limitKmh.toDouble()].reduce((a, b) => a > b ? a : b);
    if (need <= 100) return 120;
    if (need <= 140) return 160;
    return 200;
  }
}

// ------------------------------------------------------------------------------- safety strip

class HudAdvisory {
  const HudAdvisory({required this.kind, required this.key, required this.title, this.detail = ''});

  final WarnKind kind;
  final String key;

  /// "Sharp right bend", "Hazard ahead", "Ravi falling behind".
  final String title;

  /// "35 km/h · 300 m".
  final String detail;
}

class HudSafetyStripRules {
  const HudSafetyStripRules._();

  /// The one advisory to show: highest priority of the round 7 warning scheduler (hazard > curve >
  /// speed limit > falling behind > rough road > fatigue > twisty); ties keep the first given.
  /// Nothing while an emergency is open (SOS / crash banners own the screen then).
  static HudAdvisory? pick(List<HudAdvisory> items, {bool emergency = false}) {
    if (emergency || items.isEmpty) return null;
    HudAdvisory? best;
    var bestP = -1;
    for (final a in items) {
      final p = WarningScheduler.defaultRules[a.kind]?.priority ?? 0;
      if (p > bestP) {
        best = a;
        bestP = p;
      }
    }
    return best;
  }

  /// "35 km/h · 300 m" for a bend.
  static String curveDetail(int advisoryKmh, int distanceM) {
    final parts = <String>[
      if (advisoryKmh > 0) '$advisoryKmh km/h',
      if (distanceM > 0) HudTurnText.distance(distanceM.toDouble()),
    ];
    return parts.join(' · ');
  }
}

// ------------------------------------------------------------------------------- numbers

class HudFormat {
  const HudFormat._();

  /// "0:42", "1:05" (h:mm) for moving time; "-" before any.
  static String clock(int ms) {
    if (ms <= 0) return '0:00';
    final mins = ms ~/ 60000;
    return '${mins ~/ 60}:${(mins % 60).toString().padLeft(2, '0')}';
  }

  /// "0.0", "12.4", "386" (km, one decimal under 100).
  static String km(double m) {
    if (!m.isFinite || m <= 0) return '0.0';
    final km = m / 1000;
    return km < 100 ? km.toStringAsFixed(1) : km.round().toString();
  }

  /// Band distance: "350 m", "12.4 km".
  static String bandDistance(double m) {
    if (!m.isFinite || m <= 0) return '0 m';
    if (m < 1000) return '${(m / 10).round() * 10} m';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }

  /// "38 %" from a 0..1 share.
  static String percent(double share) => '${(share.clamp(0.0, 1.0) * 100).round()} %';

  /// Whole km/h ("0" when unknown).
  static String kmh(double v) => (!v.isFinite || v <= 0) ? '0' : v.round().toString();
}
