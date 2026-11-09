import '../../data/models/rider_model.dart';
import '../garage/bike_type.dart';

/// 3.55 bike markers on the ride map: each bike is one marker (its type's shape in the bike's
/// colour); a pillion seated on a bike has no separate marker, the bike carries two people.
/// Pure Dart (no Flutter): the plan, the colours and the cache key are unit tested; the widget
/// (presentation/rider/widgets/bike_rider_marker.dart) only draws what this decides.

/// One marker to draw.
class BikeMarkerEntry {
  const BikeMarkerEntry({required this.markerId, required this.bikeRider, this.pillion, this.meOnBoard = false});

  /// The rider whose position the marker uses (and whose id keys the marker).
  final String markerId;

  /// The rider of the bike (its colour, type and model); for a pillion alone, the pillion.
  final RiderModel bikeRider;

  /// The pillion on this bike, or null.
  final RiderModel? pillion;

  /// I am on this bike (as rider or pillion).
  final bool meOnBoard;

  bool get twoUp => pillion != null;
}

class BikeMarkerPlan {
  BikeMarkerPlan._();

  /// The seated pillion's rider when the link is valid (both in the ride, the rider is not a
  /// pillion), else null.
  static RiderModel? riderOf(RiderModel p, Map<String, RiderModel> riders) {
    if (!p.isCoRiding || p.ridingWithUserId.isEmpty || p.ridingWithUserId == p.userId) return null;
    final r = riders[p.ridingWithUserId];
    if (r == null || r.isCoRiding) return null;
    return r;
  }

  /// The markers for [riders], keyed by the rider whose position is drawn. A seated pillion is
  /// drawn on their rider's marker. The pair's marker uses the rider's position, except when
  /// the rider's last update is more than [staleMs] older than the pillion's (the rider's phone
  /// lost signal): then the pillion's fresher position carries the bike, so the pair never
  /// vanishes. On my own phone the pair always sits at my position (it follows my camera).
  /// Riders without a position ([hasPosition] false) are left out. [mergePillions] false (admin
  /// switch `pillionSeat` off): every rider has their own marker, as before.
  static Map<String, BikeMarkerEntry> of(
    Map<String, RiderModel> riders, {
    required String myUserId,
    required bool Function(RiderModel r) hasPosition,
    int staleMs = 20000,
    bool mergePillions = true,
  }) {
    final out = <String, BikeMarkerEntry>{};
    final pillionOf = <String, RiderModel>{};
    for (final p in mergePillions ? riders.values : const <RiderModel>[]) {
      final r = riderOf(p, riders);
      // One pillion per bike (the gateway enforces it; the first wins on an odd snapshot).
      if (r != null && !pillionOf.containsKey(r.userId)) pillionOf[r.userId] = p;
    }
    final seated = {for (final p in pillionOf.values) p.userId};
    for (final r in riders.values) {
      if (seated.contains(r.userId)) continue; // drawn with their rider
      final p = pillionOf[r.userId];
      if (p == null) {
        if (hasPosition(r)) out[r.userId] = BikeMarkerEntry(markerId: r.userId, bikeRider: r, meOnBoard: r.userId == myUserId);
        continue;
      }
      final meOn = r.userId == myUserId || p.userId == myUserId;
      String at;
      if (myUserId.isNotEmpty && p.userId == myUserId && hasPosition(p)) {
        at = p.userId;
      } else if (myUserId.isNotEmpty && r.userId == myUserId && hasPosition(r)) {
        at = r.userId;
      } else if (!hasPosition(r) || (hasPosition(p) && p.lastSeenEpochMs - r.lastSeenEpochMs > staleMs)) {
        at = p.userId;
      } else {
        at = r.userId;
      }
      final atRider = at == p.userId ? p : r;
      if (!hasPosition(atRider)) continue;
      out[at] = BikeMarkerEntry(markerId: at, bikeRider: r, pillion: p, meOnBoard: meOn);
    }
    return out;
  }

  /// Riders counted once per bike for group stats (spread, distances, speeds): seated pillions
  /// are left out, so a pair is never counted twice.
  static List<RiderModel> countedOncePerBike(Map<String, RiderModel> riders) =>
      [for (final r in riders.values) if (riderOf(r, riders) == null) r];

  /// The other person on [userId]'s bike: their rider when [userId] is a seated pillion, or the
  /// pillion seated on their bike. Null when riding alone.
  static RiderModel? partnerOf(String userId, Map<String, RiderModel> riders) {
    final me = riders[userId];
    if (me == null) return null;
    final r = riderOf(me, riders);
    if (r != null) return r;
    for (final p in riders.values) {
      if (p.userId != userId && riderOf(p, riders)?.userId == userId) return p;
    }
    return null;
  }

  /// 3.55 group-safety roster (missing-rider check, group spread, group break): one entry per bike,
  /// so a seated pillion is never checked or warned about apart from their rider. Each bike is
  /// its rider, carrying the pillion's position when the rider's update is more than [staleMs]
  /// older (the rider's phone lost signal, the pair still rides on). [meId] is always kept as
  /// themselves (a pillion keeps their own safety checks) and stands for their bike, so their
  /// bike partner is left out.
  static List<RiderModel> safetyRoster(Map<String, RiderModel> riders, {String? meId, int staleMs = 20000}) {
    bool hasPos(RiderModel r) => r.lat != 0 || r.lng != 0;
    final pillionOf = <String, RiderModel>{};
    for (final p in riders.values) {
      final r = riderOf(p, riders);
      if (r != null && !pillionOf.containsKey(r.userId)) pillionOf[r.userId] = p;
    }
    final out = <RiderModel>[];
    for (final r in riders.values) {
      if (riderOf(r, riders) != null) {
        // A seated pillion: counted with their rider, except on their own phone.
        if (r.userId == meId) out.add(r);
        continue;
      }
      final p = pillionOf[r.userId];
      if (p == null || r.userId == meId) {
        out.add(r);
      } else if (p.userId == meId) {
        continue; // my rider: I stand for our bike
      } else if (hasPos(p) && (!hasPos(r) || p.lastSeenEpochMs - r.lastSeenEpochMs > staleMs)) {
        out.add(r.copyWith(lat: p.lat, lng: p.lng, speedKmh: p.speedKmh, heading: p.heading, lastSeenEpochMs: p.lastSeenEpochMs));
      } else {
        out.add(r);
      }
    }
    return out;
  }
}

/// How urgent the marker looks (one cue at a time, most urgent first).
enum BikeMarkerCue {
  normal,
  stopped,
  warning, // behind / off route / low GPS / disconnected
  stale, // offline: faded
  sos;

  /// The most urgent of the signals.
  static BikeMarkerCue of({bool sos = false, bool warning = false, bool stale = false, bool stopped = false}) {
    if (sos) return BikeMarkerCue.sos;
    if (stale) return BikeMarkerCue.stale;
    if (warning) return BikeMarkerCue.warning;
    if (stopped) return BikeMarkerCue.stopped;
    return BikeMarkerCue.normal;
  }
}

/// The colour a bike shows, from the garage colour name or #RRGGBB the group sees (vehicleColor).
class BikeColours {
  BikeColours._();

  /// Colour words → ARGB. The last word that is known decides ("Gunmetal Grey" → grey,
  /// "Matte Black" → black, "Stealth Black" → black).
  static const Map<String, int> _named = {
    'black': 0xFF1B1B1B, 'white': 0xFFF4F4F4, 'red': 0xFFD32F2F, 'maroon': 0xFF7B1F2A, 'blue': 0xFF1E63D6,
    'navy': 0xFF1C2E5C, 'grey': 0xFF7A7A7A, 'gray': 0xFF7A7A7A, 'gunmetal': 0xFF4A4F55, 'silver': 0xFFC0C0C0,
    'green': 0xFF2E7D32, 'olive': 0xFF6B7A3A, 'yellow': 0xFFF9C80E, 'orange': 0xFFF57C00, 'brown': 0xFF6D4C41,
    'bronze': 0xFF9C6B30, 'gold': 0xFFC9A227, 'copper': 0xFFB5651D, 'purple': 0xFF6A1B9A, 'pink': 0xFFE91E63,
    'beige': 0xFFD8C8A8, 'cream': 0xFFF1E6C8, 'teal': 0xFF00897B, 'cyan': 0xFF00ACC1, 'sand': 0xFFC8B48A,
    'khaki': 0xFFA39A6B, 'desert': 0xFFC2A36B, 'camo': 0xFF5B6B3A, 'chrome': 0xFFD0D3D6,
  };

  /// ARGB for [raw], or null when unknown (the member colour is used then).
  static int? parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final hex = RegExp(r'^#([0-9A-Fa-f]{6})$').firstMatch(s);
    if (hex != null) return 0xFF000000 | int.parse(hex.group(1)!, radix: 16);
    int? found;
    for (final w in s.toLowerCase().split(RegExp(r'[^a-z]+'))) {
      final v = _named[w];
      if (v != null) found = v;
    }
    return found;
  }

  /// True for a light colour (the outline / plate turns dark for contrast).
  static bool isLight(int argb) {
    final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) > 170;
  }
}

/// The key under which a rendered bike glyph is cached: the same type, colour, people and cue at
/// the same size are drawn once and reused for every rider and every frame.
class BikeMarkerKey {
  const BikeMarkerKey({
    required this.type,
    required this.argb,
    required this.twoUp,
    required this.cue,
    required this.size,
    this.me = false,
    this.selected = false,
  });

  final BikeType type;
  final int argb;
  final bool twoUp;
  final BikeMarkerCue cue;

  /// Logical width, rounded to 4 px steps so nearby sizes share one bitmap.
  final int size;
  final bool me;
  final bool selected;

  static int bucket(double px) => ((px / 4).round() * 4).clamp(8, 256);

  static BikeMarkerKey of({
    required String vehicleKind,
    required String vehicleColor,
    required int fallbackArgb,
    required bool twoUp,
    required BikeMarkerCue cue,
    required double size,
    bool me = false,
    bool selected = false,
  }) =>
      BikeMarkerKey(
        type: BikeType.parse(vehicleKind) ?? BikeType.commuter,
        argb: BikeColours.parse(vehicleColor) ?? fallbackArgb,
        twoUp: twoUp,
        cue: cue,
        size: bucket(size),
        me: me,
        selected: selected,
      );

  String get id => '${type.name}|${argb.toRadixString(16)}|${twoUp ? 2 : 1}|${cue.name}|$size|${me ? 'm' : ''}${selected ? 's' : ''}';

  @override
  bool operator ==(Object other) => other is BikeMarkerKey && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => id;
}

/// A small least-recently-used cache (the glyph pictures; [max] entries).
class BikeGlyphLru<V> {
  BikeGlyphLru({this.max = 96, this.onEvict});
  final int max;
  final void Function(V value)? onEvict;
  final Map<BikeMarkerKey, V> _map = <BikeMarkerKey, V>{};
  int hits = 0, misses = 0;

  int get length => _map.length;

  V putIfAbsent(BikeMarkerKey key, V Function() build) {
    final v = _map.remove(key);
    if (v != null) {
      hits++;
      _map[key] = v; // most recent last
      return v;
    }
    misses++;
    final made = build();
    _map[key] = made;
    while (_map.length > max) {
      final oldest = _map.keys.first;
      final gone = _map.remove(oldest);
      if (gone != null) onEvict?.call(gone);
    }
    return made;
  }

  void clear() {
    for (final v in _map.values) {
      onEvict?.call(v);
    }
    _map.clear();
  }
}

/// The screen-reader line of a bike marker: "Asha, Royal Enfield Classic 350, red, with pillion
/// Kiran, 42 km/h, Riding".
String bikeMarkerLabel({
  required String riderName,
  required String model,
  required String colour,
  String? pillionName,
  required String speed,
  required String status,
  String reason = '',
  bool me = false,
  bool mePillion = false,
}) {
  final who = me ? (mePillion ? 'You, riding pillion with $riderName' : 'You') : riderName;
  final bike = [model.trim(), colour.trim().toLowerCase()].where((s) => s.isNotEmpty).join(', ');
  final pill = pillionName == null || mePillion ? '' : (me ? 'with pillion $pillionName' : 'with pillion ${pillionName.trim()}');
  return [who, if (bike.isNotEmpty) bike, if (pill.isNotEmpty) pill, speed, status, if (reason.isNotEmpty) reason].join(', ');
}
