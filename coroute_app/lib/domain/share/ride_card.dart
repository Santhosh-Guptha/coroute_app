import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// v3.63 the shareable ride card (pure Dart: no Flutter, unit-tested in `test/ride_card_363_test.dart`).
///
/// * Two sizes: [RideCardFormat.square] 1080 x 1080 for WhatsApp, [RideCardFormat.story] 1080 x 1920 for Instagram
///   Stories.
/// * Privacy: the drawn route never starts or ends at the rider's real start / end: the first and the last
///   [RideCard.trimM] metres are cut ([RideCard.trimEnds]); a ride shorter than that shows no route at all. The card
///   never prints the start place (only the destination name).
/// * Only real numbers: an unknown value is left off (never shown as 0 or guessed).
enum RideCardFormat {
  square(1080, 1080, 'WhatsApp'),
  story(1080, 1920, 'Instagram story');

  const RideCardFormat(this.widthPx, this.heightPx, this.label);
  final int widthPx;
  final int heightPx;
  final String label;

  /// Width / height.
  double get aspect => widthPx / heightPx;
}

class RideCard {
  RideCard._();

  /// Metres cut from both ends of the drawn route (the start is often home, the end often a friend's place).
  static const double trimM = 300;

  static double _metres(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1, math.sqrt(h)));
  }

  /// The route without its first and last [meters] (distance along the ridden line; jumps across a signal gap in
  /// [breaks] count as distance too, so a gap near home never shows the home end). [breaks] are re-indexed for the
  /// trimmed list. A route of [meters] x 2 + 100 m or less gives no points.
  /// v3.63 privacy zones: [points] without the ones [hidden] says are near a saved place (home, work). A removed span
  /// becomes a break, so the sketch never draws a line through the zone. Indexes in [breaks] (a break before point i)
  /// are carried over to the kept points.
  static ({List<LatLng> points, Set<int> breaks}) withoutZones(List<LatLng> points, Set<int> breaks, bool Function(LatLng) hidden) {
    final out = <LatLng>[];
    final outBreaks = <int>{};
    var gap = false;
    for (var i = 0; i < points.length; i++) {
      if (hidden(points[i])) {
        gap = true;
        continue;
      }
      if (out.isNotEmpty && (gap || breaks.contains(i))) outBreaks.add(out.length);
      gap = false;
      out.add(points[i]);
    }
    return (points: out, breaks: outBreaks);
  }

  static ({List<LatLng> points, Set<int> breaks}) trimEnds(List<LatLng> points, Set<int> breaks, {double meters = trimM}) {
    if (points.length < 2 || meters <= 0) return (points: List<LatLng>.of(points), breaks: Set<int>.of(breaks));
    final cum = List<double>.filled(points.length, 0);
    for (var i = 1; i < points.length; i++) {
      cum[i] = cum[i - 1] + _metres(points[i - 1], points[i]);
    }
    final total = cum.last;
    if (total <= meters * 2 + 100) return (points: const <LatLng>[], breaks: const <int>{});
    final out = <LatLng>[];
    final outBreaks = <int>{};
    for (var i = 0; i < points.length; i++) {
      if (cum[i] < meters || cum[i] > total - meters) continue;
      if (breaks.contains(i) && out.isNotEmpty) outBreaks.add(out.length);
      out.add(points[i]);
    }
    if (out.length < 2) return (points: const <LatLng>[], breaks: const <int>{});
    return (points: out, breaks: outBreaks);
  }

  /// "No SOS on this ride", "1 SOS on this ride" (null when not known).
  static String? safetyLine({int? sos}) {
    if (sos == null || sos < 0) return null;
    if (sos == 0) return 'No SOS on this ride';
    return '$sos SOS on this ride, everyone looked out for each other';
  }

  /// "3 hazards logged" (null when not known; 0 reads "No hazards logged").
  static String? hazardsText(int? hazards) {
    if (hazards == null || hazards < 0) return null;
    if (hazards == 0) return 'No hazards logged';
    return '$hazards ${hazards == 1 ? 'hazard' : 'hazards'} logged';
  }

  /// The rider's CoRoute score for the card ("87", level "Ace Rider"), or null when not ready.
  static ({String value, String label})? scoreOf(int? score, String? level) {
    if (score == null || score < 0) return null;
    final l = (level ?? '').trim();
    return (value: '$score', label: l.isEmpty ? 'Rider score' : 'Rider score · $l');
  }

  /// "Ride to Nandi Hills" (never the start place), or '' without a destination.
  static String routeLine(String destination) {
    final d = destination.trim();
    return d.isEmpty ? '' : 'Ride to $d';
  }
}
