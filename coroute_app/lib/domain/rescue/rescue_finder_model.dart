// Round 10 rescue finder: one plain guide from every signal (pure Dart, tested).
//
// Signals and what they can honestly tell:
//  * last known GPS of the victim + my GPS: distance and compass bearing. Good to ~10..30 m, the
//    victim's last fix may be old, and forest canopy makes both fixes worse;
//  * BLE locator RSSI: proximity only (roughly 30..100 m range; a body, pocket or trunk takes
//    10..20 dB);
//  * near-ultrasonic locator SNR: proximity only (roughly 10..40 m; fades fast with distance and
//    foliage);
//  * the audible siren: the rescuer's own ears, the only signal that gives DIRECTION at short range.
// So the guide uses GPS for "which way" when far, and for the last metres says: walk, watch the
// meter rise, listen.
import 'dart:math' as math;

import 'proximity_trend.dart';

enum FinderCloseness { unknown, far, approaching, near, close, veryClose }

class FinderInputs {
  /// Victim's last known position (0, 0 = unknown), its age and accuracy.
  final double victimLat;
  final double victimLng;
  final int victimFixAgeMs;
  final double? victimAccuracyM;

  /// My position (0, 0 = unknown) and compass heading (degrees, null = unknown).
  final double myLat;
  final double myLng;
  final double? myHeadingDeg;

  /// BLE: smoothed RSSI (dBm) and trend, null when not heard recently.
  final double? bleRssi;
  final TrendDirection bleTrend;

  /// Locator beacon: confirmed, smoothed SNR (dB) and trend.
  final bool beaconConfirmed;
  final double? beaconSnrDb;
  final TrendDirection beaconTrend;

  /// The listeners run (mic allowed, Bluetooth on and allowed).
  final bool micListening;
  final bool bleScanning;

  const FinderInputs({
    this.victimLat = 0,
    this.victimLng = 0,
    this.victimFixAgeMs = 0,
    this.victimAccuracyM,
    this.myLat = 0,
    this.myLng = 0,
    this.myHeadingDeg,
    this.bleRssi,
    this.bleTrend = TrendDirection.unknown,
    this.beaconConfirmed = false,
    this.beaconSnrDb,
    this.beaconTrend = TrendDirection.unknown,
    this.micListening = false,
    this.bleScanning = false,
  });
}

class FinderGuide {
  final FinderCloseness closeness;

  /// The big status line ("Very close: within about 20 m. Look and listen.").
  final String status;

  /// Hotter / colder line, or null.
  final String? trendLine;

  /// GPS distance (m) and bearing (degrees from north), null when a position is unknown.
  final double? distanceM;
  final double? bearingDeg;

  /// Arrow angle relative to where I face (degrees, clockwise), null without a heading.
  final double? arrowDeg;

  /// "Listen: the siren should be audible now."
  final bool listenPrompt;

  /// "Last GPS 12 min ago (about 30 m)", or null.
  final String? gpsNote;

  const FinderGuide({
    required this.closeness,
    required this.status,
    this.trendLine,
    this.distanceM,
    this.bearingDeg,
    this.arrowDeg,
    this.listenPrompt = false,
    this.gpsNote,
  });
}

class RescueFinderModel {
  RescueFinderModel._();

  /// Always shown on the finder: what the meters can and cannot do.
  static const String honestyNote =
      'Sound and Bluetooth tell you how close you are, not which way. Walk 10 to 20 steps in one direction '
      'and watch the meter: if it rises, keep going; if it falls, turn around. Stop now and then, stay quiet and listen.';

  static double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371008.8;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
    final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a.toDouble())));
  }

  static double _bearing(double lat1, double lng1, double lat2, double lng2) {
    double rad(double d) => d * math.pi / 180;
    final y = math.sin(rad(lng2 - lng1)) * math.cos(rad(lat2));
    final x = math.cos(rad(lat1)) * math.sin(rad(lat2)) - math.sin(rad(lat1)) * math.cos(rad(lat2)) * math.cos(rad(lng2 - lng1));
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static String distanceWords(double m) {
    if (m < 1000) return '${(m / 10).round() * 10} m';
    return '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';
  }

  static String ageWords(int ms) {
    final s = ms ~/ 1000;
    if (s < 60) return 'just now';
    final m = s ~/ 60;
    if (m < 60) return '$m min ago';
    return '${m ~/ 60} h ${m % 60} min ago';
  }

  static FinderGuide guide(FinderInputs i, {String name = 'the rider'}) {
    final haveVictim = !(i.victimLat == 0 && i.victimLng == 0);
    final haveMe = !(i.myLat == 0 && i.myLng == 0);
    double? dist, bearing, arrow;
    if (haveVictim && haveMe) {
      dist = _haversine(i.myLat, i.myLng, i.victimLat, i.victimLng);
      bearing = _bearing(i.myLat, i.myLng, i.victimLat, i.victimLng);
      final h = i.myHeadingDeg;
      if (h != null && h.isFinite) arrow = (bearing - h + 360) % 360;
    }
    final rssi = i.bleRssi;
    final snr = i.beaconConfirmed ? i.beaconSnrDb : null;

    var c = FinderCloseness.unknown;
    String status;
    if ((rssi != null && rssi >= -70) || (snr != null && snr >= 22)) {
      c = FinderCloseness.veryClose;
      status = 'Very close: within about 20 m. Look and listen. Call out to $name.';
    } else if ((rssi != null && rssi >= -82) || snr != null) {
      c = FinderCloseness.close;
      status = 'Close: within about 50 m. Walk slowly and watch the meter rise.';
    } else if (rssi != null) {
      c = FinderCloseness.near;
      status = "In Bluetooth range (roughly 30 to 100 m). Walk and watch the meter.";
    } else if (dist != null && dist < 150) {
      c = FinderCloseness.near;
      status = 'About ${distanceWords(dist)} by GPS. Listen for the siren.';
    } else if (dist != null && dist < 2000) {
      c = FinderCloseness.approaching;
      status = '${distanceWords(dist)} away. Follow the arrow or the route.';
    } else if (dist != null) {
      c = FinderCloseness.far;
      status = '${distanceWords(dist)} away. Use the route to get close.';
    } else if (!haveVictim) {
      status = 'No position from $name yet. Listen, and watch the meters.';
    } else {
      status = 'Waiting for your GPS. Go outside or away from tall trees for a moment.';
    }

    // Trend: the beacon is the closer-range signal, prefer it when confirmed.
    final t = snr != null && i.beaconTrend != TrendDirection.unknown ? i.beaconTrend : (rssi != null ? i.bleTrend : TrendDirection.unknown);
    final trendLine = switch (t) {
      TrendDirection.hotter => 'Getting closer. Keep going this way.',
      TrendDirection.colder => 'Getting farther. Turn around or try another direction.',
      TrendDirection.steady => 'About the same. Try 20 steps in another direction.',
      TrendDirection.unknown => (rssi != null || snr != null) ? 'Hold steady for a few seconds to read the signal.' : null,
    };

    final listen = c == FinderCloseness.veryClose || c == FinderCloseness.close || (dist != null && dist < 150);
    String? gpsNote;
    if (haveVictim) {
      final acc = i.victimAccuracyM;
      gpsNote = 'Last GPS from $name ${ageWords(i.victimFixAgeMs)}${acc != null && acc > 0 ? ' (about ${acc.round()} m)' : ''}';
    }
    return FinderGuide(
      closeness: c,
      status: status,
      trendLine: trendLine,
      distanceM: dist,
      bearingDeg: bearing,
      arrowDeg: arrow,
      listenPrompt: listen,
      gpsNote: gpsNote,
    );
  }
}

/// When a responder's phone listens for the locator (mic at 48 kHz, BLE scan). Never otherwise.
class RescueListenGate {
  RescueListenGate._();

  /// Within this distance of the victim's last position the phone listens without the finder open.
  static const double nearM = 1000;

  static bool shouldListen({
    required bool openSosOfOther,
    required bool finderOpen,
    double? distanceToVictimM,
    bool offline = false,
  }) {
    if (!openSosOfOther) return false;
    if (finderOpen) return true;
    final d = distanceToVictimM;
    if (d == null) return false;
    return d <= nearM || (offline && d <= nearM * 2);
  }
}

/// "Ping the phone" on the responder's side: at most one press every [gap].
class RescuePingLimiter {
  RescuePingLimiter({this.gap = const Duration(seconds: 20)});

  final Duration gap;
  int _last = -(1 << 40);

  int secondsUntilNext(int nowMs) {
    final left = _last + gap.inMilliseconds - nowMs;
    return left <= 0 ? 0 : (left / 1000).ceil();
  }

  bool tryPress(int nowMs) {
    if (secondsUntilNext(nowMs) > 0) return false;
    _last = nowMs;
    return true;
  }
}
