/// Round 8 compact position frames, protocol 'pos2' (gateway/src/pos2.js is the reference). Pure Dart: tested with
/// the plain Dart VM in `test/rt8_pos2_codec_test.dart`.
///
/// Used only when the gateway lists 'pos2' in HELLO.features (older gateways: TELEMETRY JSON and RIDER_UPDATE(S), as
/// before). Phone -> gateway: `{"t":"P2","q":seq,"a":lat*1e5,"o":lng*1e5,"v":dm/s,"h":deg,"b":%,...}` (~65 bytes
/// instead of ~240). Gateway -> phone: `{"type":"RU2","ts":..,"r":[{"u":userId,"a","o","v","h","b",...,"t":last seen ms}]}`
/// with telemetry only (~85 bytes per rider instead of ~650): [RiderCache] merges each entry into the rider this
/// phone already knows from the SNAPSHOT / full rider updates, so every listener keeps getting full RIDER_UPDATE maps.
library;

class Pos2Codec {
  static const String feature = 'pos2';
  static const double e5 = 1e5;
  static const double kmhPerDms = 0.36;

  int _seq = 0;

  /// One full P2 frame (always a full fix: deltas save nothing in JSON once the values are integers).
  Map<String, dynamic> encode({
    required double lat,
    required double lng,
    required double speedKmh,
    required double heading,
    required int nowMs,
    int? batteryLevel,
    bool isCharging = false,
    String statusReason = '',
    String statusMessage = '',
    int stoppedSince = 0,
    Map<String, dynamic>? fuelEstimate,
    int? fatigueLevel,
  }) {
    _seq = (_seq + 1) & 0x7fffffff;
    final f = <String, dynamic>{
      't': 'P2',
      'q': _seq,
      'a': (lat * e5).round(),
      'o': (lng * e5).round(),
      'v': (speedKmh / kmhPerDms).round().clamp(0, 1000),
      'h': ((heading.round() % 360) + 360) % 360,
    };
    if (batteryLevel != null) f['b'] = batteryLevel.clamp(0, 100);
    if (isCharging) f['c'] = 1;
    if (statusReason.isNotEmpty) f['sr'] = statusReason.length > 24 ? statusReason.substring(0, 24) : statusReason;
    if (statusMessage.isNotEmpty) f['sm'] = statusMessage.length > 140 ? statusMessage.substring(0, 140) : statusMessage;
    if (stoppedSince > 0) f['ss'] = ((nowMs - stoppedSince) / 1000).round().clamp(0, 7 * 86400);
    final km = fuelEstimate?['usableKm'];
    final at = fuelEstimate?['confirmedAt'];
    if (km is num && at is num) f['fu'] = [km.floor(), (at / 1000).round()];
    if (fatigueLevel != null) f['fl'] = fatigueLevel;
    return f;
  }
}

/// The riders of the current room as full maps, so compact RU2 entries can be turned back into full riders.
class RiderCache {
  final Map<String, Map<String, dynamic>> _riders = {};

  int get length => _riders.length;
  bool knows(String userId) => _riders.containsKey(userId);
  Map<String, dynamic>? operator [](String userId) => _riders[userId];

  void clear() => _riders.clear();

  /// SNAPSHOT `convoy.riders` (a map keyed by userId, or a list).
  void putSnapshot(Object? riders) {
    _riders.clear();
    if (riders is Map) {
      for (final v in riders.values) {
        if (v is Map) put(v);
      }
    } else if (riders is List) {
      for (final v in riders) {
        if (v is Map) put(v);
      }
    }
  }

  /// A full rider (RIDER_UPDATE / RIDER_UPDATES entry).
  void put(Map<dynamic, dynamic> rider) {
    final id = rider['userId']?.toString();
    if (id == null || id.isEmpty) return;
    _riders[id] = Map<String, dynamic>.from(rider);
  }

  void remove(String userId) => _riders.remove(userId);

  /// An RU2 frame -> full rider maps (riders this phone does not know yet are skipped until the next SNAPSHOT).
  List<Map<String, dynamic>> applyRu2(Map<String, dynamic> frame) {
    final out = <Map<String, dynamic>>[];
    final list = frame['r'];
    final tsRaw = frame['ts'];
    final ts = tsRaw is num ? tsRaw.toInt() : DateTime.now().millisecondsSinceEpoch;
    if (list is! List) return out;
    for (final e in list) {
      if (e is! Map) continue;
      final id = e['u']?.toString();
      final known = id == null ? null : _riders[id];
      if (known == null) continue;
      final merged = applyEntry(known, e, ts);
      if (merged == null) continue;
      _riders[id!] = merged;
      out.add(merged);
    }
    return out;
  }

  /// One RU2 entry merged into a known rider (null for a malformed entry).
  static Map<String, dynamic>? applyEntry(Map<String, dynamic> known, Map<dynamic, dynamic> e, int ts) {
    final a = e['a'], o = e['o'], v = e['v'], h = e['h'];
    if (a is! num || o is! num) return null;
    final out = Map<String, dynamic>.from(known);
    out['lat'] = a / Pos2Codec.e5;
    out['lng'] = o / Pos2Codec.e5;
    out['speedKmh'] = v is num ? (v * Pos2Codec.kmhPerDms * 10).round() / 10 : 0.0;
    out['heading'] = h is num ? h.toDouble() : 0.0;
    if (e['b'] is num) out['batteryLevel'] = (e['b'] as num).toInt();
    out['isCharging'] = e['c'] == 1;
    out['statusReason'] = e['sr']?.toString() ?? '';
    out['statusMessage'] = e['sm']?.toString() ?? '';
    final ss = e['ss'];
    out['stoppedSince'] = ss is num && ss > 0 ? ts - (ss * 1000).round() : 0;
    // Last seen in server time (absolute, like RIDER_UPDATE.lastSeenEpochMs: an entry may go out in a later flush).
    final t = e['t'];
    final lastSeen = t is num ? t.toInt() : ts;
    out['lastSeenEpochMs'] = lastSeen;
    final fu = e['fu'];
    out['fuelEstimate'] = fu is List && fu.length == 2 && fu[0] is num && fu[1] is num
        ? <String, dynamic>{'usableKm': fu[0], 'confirmedAt': ((fu[1] as num) * 1000).round(), 'updatedAt': lastSeen}
        : null;
    out['fatigueLevel'] = e['fl'] is num ? (e['fl'] as num).toInt() : 0;
    return out;
  }
}
