import '../../data/models/rider_model.dart';
import '../garage/bike_type.dart';
import '../tracking/geo_math.dart';

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

  /// 3.55 follow-up: the same once-per-bike plan for maps watched from outside the ride (the admin
  /// convoy inspector, the master admin fleet map, the trip report and replay): nobody is "me", a
  /// rider has a position when lat or lng is set. A seated pillion rides on their rider's marker
  /// (the two-rider bike), never as a marker of their own.
  static Map<String, BikeMarkerEntry> forViewer(Map<String, RiderModel> riders, {bool mergePillions = true, int staleMs = 20000}) =>
      of(riders, myUserId: '', hasPosition: (r) => r.lat != 0 || r.lng != 0, mergePillions: mergePillions, staleMs: staleMs);

  /// Seated pillions and their riders (pillion id -> rider id) of a ride snapshot: the replay
  /// tracks carry no pillion links, so the replay takes them from the ride the phone holds.
  static Map<String, String> seatedPairs(Map<String, RiderModel> riders) {
    final out = <String, String>{};
    final taken = <String>{};
    for (final p in riders.values) {
      final r = riderOf(p, riders);
      if (r == null || !taken.add(r.userId)) continue;
      out[p.userId] = r.userId;
    }
    return out;
  }

  /// The replay / report markers at one moment: [at] is every shown rider's position then
  /// (userId -> (lat, lng)). A seated pillion ([pillionOf]: pillion id -> rider id) within
  /// [togetherM] of their rider is drawn on the rider's two-up bike; when the rider has no position
  /// at that moment the pillion carries the bike. Further apart (the seat was taken later than this
  /// moment, the snapshot is newer than the ride) both keep their own marker. Returns
  /// userId -> twoUp for the markers to draw, in the order of [at].
  static Map<String, bool> replayBikes(Map<String, (double, double)> at, Map<String, String> pillionOf, {double togetherM = 150}) {
    final out = <String, bool>{for (final id in at.keys) id: false};
    pillionOf.forEach((p, r) {
      final pp = at[p];
      if (pp == null || p == r) return;
      final rp = at[r];
      if (rp == null) {
        out[p] = true; // the pillion's phone carries the bike
        return;
      }
      if (GeoMath.haversine(pp.$1, pp.$2, rp.$1, rp.$2) > togetherM) return;
      out.remove(p);
      out[r] = true;
    });
    return out;
  }

  /// "Arjun + Meera" for a two-up bike (the marker's name for screen readers and tooltips).
  static String nameOf(BikeMarkerEntry e) {
    String n(RiderModel r) => r.name.trim().isEmpty ? 'Rider' : r.name.trim();
    final p = e.pillion;
    return p == null ? n(e.bikeRider) : '${n(e.bikeRider)} + ${n(p)}';
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
/// the same size are drawn once and reused for every rider and every frame. [heading] is a heading
/// bucket ([headingBucket]): 0 when the bitmap is rotated at draw time (the ride maps: flutter_map
/// draws widgets, so the 3D bike is one cached image turned by a transform); set it only when a
/// bitmap is baked per direction.
class BikeMarkerKey {
  const BikeMarkerKey({
    required this.type,
    required this.argb,
    required this.twoUp,
    required this.cue,
    required this.size,
    this.me = false,
    this.selected = false,
    this.heading = 0,
  });

  final BikeType type;
  final int argb;
  final bool twoUp;
  final BikeMarkerCue cue;

  /// Logical width, rounded to 4 px steps so nearby sizes share one bitmap.
  final int size;
  final bool me;
  final bool selected;

  /// Heading bucket in degrees (a multiple of the bucket step, 0..359).
  final int heading;

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
    double? heading,
    int headingStep = 10,
  }) =>
      BikeMarkerKey(
        type: BikeType.parse(vehicleKind) ?? BikeType.commuter,
        argb: BikeColours.parse(vehicleColor) ?? fallbackArgb,
        twoUp: twoUp,
        cue: cue,
        size: bucket(size),
        me: me,
        selected: selected,
        heading: heading == null ? 0 : headingBucket(heading, step: headingStep),
      );

  String get id =>
      '${type.name}|${argb.toRadixString(16)}|${twoUp ? 2 : 1}|${cue.name}|$size|${me ? 'm' : ''}${selected ? 's' : ''}|h$heading';

  @override
  bool operator ==(Object other) => other is BikeMarkerKey && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => id;
}

/// [deg] (any value, any sign) as a bucket of [step] degrees, 0..359: 4° → 0, 6° → 10, 355° → 0,
/// -20° → 340 (step 10). Not finite → 0.
int headingBucket(double deg, {int step = 10}) {
  if (!deg.isFinite || step <= 0) return 0;
  final n = ((deg % 360) + 360) % 360;
  return ((n / step).round() * step) % 360;
}

/// 3.56 the direction a bike on the map faces. A phone's GPS course is noise while standing still
/// (and missing / negative / NaN on some phones), so below [minSpeedKmh] or without a valid course
/// the bike keeps the last good heading instead of spinning or snapping to north. One per map
/// (keyed by rider id); [forget] drops riders who left.
class HeadingHold {
  HeadingHold({this.minSpeedKmh = 3.0});
  final double minSpeedKmh;
  final Map<String, double> _last = <String, double>{};

  /// The heading to draw for [id]: [heading] when it is valid and the rider moves, else the last
  /// good one (or [heading] / 0 when there is none yet).
  double update(String id, double heading, double speedKmh) {
    final valid = heading.isFinite && heading >= 0;
    final moving = speedKmh.isFinite && speedKmh >= minSpeedKmh;
    final last = _last[id];
    if (valid && (moving || last == null)) {
      final h = heading % 360;
      _last[id] = h;
      return h;
    }
    return last ?? 0.0;
  }

  double? lastOf(String id) => _last[id];

  void forget(Iterable<String> keep) {
    final k = keep.toSet();
    _last.removeWhere((id, _) => !k.contains(id));
  }
}

/// 3.56 the rendered 3D bike images (tool/map_bikes: three.js, regenerated with
/// `node tool/map_bikes/generate.mjs`). Map markers are a top-down view in four layers drawn in
/// this order: [BikeLayer.shadow] (offset in screen space), [BikeLayer.base] (tyres, rider gear,
/// helmets, chrome, seat), [BikeLayer.paint] (the painted panels in white/grey shading, tinted with
/// the bike's colour: rgb × colour, BlendMode.modulate), [BikeLayer.gloss] (clear-coat
/// highlights). The garage shows a 3/4 side "hero" view (base, paint, gloss) with no rider or two.
enum BikeLayer { shadow, base, paint, gloss }

class BikeSprites {
  BikeSprites._();

  /// Logical size of a map image (square; 2.0x / 3.0x variants beside it).
  static const double mapBox = 64;

  /// Logical size of a garage hero image.
  static const double heroWidth = 128, heroHeight = 80;

  /// Screen-space shadow offset at [mapBox] size (light from the top left; scale with the box).
  static const double shadowDx = 0.8, shadowDy = 2.0;

  static int mapRiders(int people) => people >= 2 ? 2 : 1;
  static int heroRiders(int people) => people >= 2 ? 2 : 0;

  /// `assets/map_bikes/sport_2_paint.png`.
  static String map(BikeType type, int people, BikeLayer layer) => 'assets/map_bikes/${type.name}_${mapRiders(people)}_${layer.name}.png';

  /// `assets/garage_bikes/cruiser_0_base.png` (no shadow layer: it is baked into base).
  static String hero(BikeType type, int people, BikeLayer layer) =>
      'assets/garage_bikes/${type.name}_${heroRiders(people)}_${(layer == BikeLayer.shadow ? BikeLayer.base : layer).name}.png';

  /// All map images (for precaching).
  static List<String> allMap() => [
        for (final t in BikeType.values)
          for (final p in const [1, 2])
            for (final l in BikeLayer.values) map(t, p, l),
      ];

  /// The colour the paint layer is multiplied with: very dark paints are lifted a little (black
  /// 0x1B → 0x3D) so a black bike keeps its 3D shading instead of becoming a flat hole. Opaque.
  static int paintArgb(int argb) {
    int lift(int v) => (38 + v * (255 - 38) / 255).round();
    final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    return 0xFF000000 | (lift(r) << 16) | (lift(g) << 8) | lift(b);
  }
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
