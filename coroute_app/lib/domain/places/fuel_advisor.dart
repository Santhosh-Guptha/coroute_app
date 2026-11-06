import 'dart:math' as math;

import 'fuel_ahead.dart';
import 'fuel_match.dart';

enum FuelWarningKind { none, low, urgent, critical, rangeRisk, longGap }

/// One plain-language fuel warning (or none). Pure data.
class FuelWarning {
  const FuelWarning(this.kind, {this.title = '', this.message = '', this.voice = '', this.stationId, this.nextKm});
  static const none = FuelWarning(FuelWarningKind.none);
  final FuelWarningKind kind;
  final String title, message, voice;

  /// The station this warning is about (long gap: the one to fill at).
  final String? stationId;
  final double? nextKm;
}

String _km(double km) => km < 10 ? '${km.toStringAsFixed(1).replaceAll('.0', '')} km' : '${km.round()} km';

/// Decides the fuel warning from the usable range and the stations ahead.
///
/// Order: cannot reach the next station even on reserve; critical (10 km);
/// urgent (20 km); fill here before a long gap; low (the larger of 50 km and a
/// fifth of a full tank). A group fuel stop within range is named instead of
/// the next station. The long-gap warning needs the stations ahead to be
/// loaded far enough to know the gap.
FuelWarning decideFuelWarning({required double? usableKm, required double marginKm, required double fullRangeKm,
    FuelAheadView? ahead, double nearKm = 5, double cautionKm = 20}) {
  if (usableKm == null || !usableKm.isFinite || usableKm < 0) return FuelWarning.none;
  final type = ahead?.type ?? BikeFuelType.petrol;
  final word = type.stationWord;
  final stops = ahead?.stops ?? const <FuelStop>[];
  final confirmed = stops.where((s) => s.confirmed).toList();
  final next = confirmed.isNotEmpty ? confirmed.first : (stops.isNotEmpty ? stops.first : null);
  final any = stops.isNotEmpty ? stops.first : null;
  final group = ahead?.groupStopKm;
  final groupOk = group != null && group.isFinite && group >= 0 && group <= usableKm + marginKm;
  final left = _km(usableKm);

  String nextText() {
    if (groupOk) return 'group fuel stop${ahead?.groupStopName == null ? '' : ' (${ahead!.groupStopName})'} in ${_km(group)}';
    if (next != null) return 'next ${next.confirmed ? word : '$word (type unknown)'} in ${_km(next.distanceKm)}';
    return 'no $word mapped ahead yet';
  }

  // 1. Even the nearest station of any kind is past the reserve.
  // Only when everything up to it is loaded: an unloaded stretch may hide a nearer one.
  if (any != null && !groupOk && any.distanceKm > usableKm + marginKm && any.distanceKm <= (ahead?.coverageKm ?? 0) + 1) {
    return FuelWarning(FuelWarningKind.rangeRisk,
        title: 'Fuel may not last',
        message: 'Next $word is ${_km(any.distanceKm)} away, about $left of fuel left. Ride gently or go back to the last station.',
        voice: 'Fuel may not last. Next $word is ${_km(any.distanceKm)} away.',
        stationId: any.poi.id, nextKm: any.distanceKm);
  }
  if (usableKm <= 10) {
    return FuelWarning(FuelWarningKind.critical, title: 'Fuel very low',
        message: 'About $left left — ${nextText()}. Stop for fuel now.',
        voice: 'Fuel very low. ${nextText()}.', stationId: next?.poi.id, nextKm: next?.distanceKm);
  }
  if (usableKm <= 20) {
    return FuelWarning(FuelWarningKind.urgent, title: 'Fuel low',
        message: 'About $left left — ${nextText()}.',
        voice: 'Fuel low. ${nextText()}.', stationId: next?.poi.id, nextKm: next?.distanceKm);
  }
  // 2. Long gap: the rider is about to pass the last station before a stretch
  // longer than the fuel left after it.
  if (next != null && next.confirmed && next.distanceKm <= nearKm && !groupOk) {
    final after = confirmed.where((s) => s.alongM > next.alongM + 1000).toList();
    final coverage = ahead?.coverageKm ?? 0;
    final leftAfter = usableKm - next.distanceKm;
    double? gapKm;
    if (after.isNotEmpty) {
      gapKm = after.first.distanceKm - next.distanceKm;
    } else if (coverage - next.distanceKm > leftAfter + cautionKm) {
      gapKm = coverage - next.distanceKm; // nothing mapped in everything loaded ahead
    }
    if (gapKm != null && gapKm + cautionKm > leftAfter && gapKm >= 40) {
      final gap = after.isNotEmpty ? 'Next fuel after this is ${_km(gapKm)} away' : 'No $word mapped in the next ${_km(gapKm)}';
      return FuelWarning(FuelWarningKind.longGap, title: 'Fill up here',
          message: '$gap — fill up at ${next.poi.displayName} (${_km(next.distanceKm)} ahead).',
          voice: '$gap. Fill up here.', stationId: next.poi.id, nextKm: next.distanceKm);
    }
  }
  final lowAt = math.max(50.0, fullRangeKm.isFinite ? fullRangeKm * 0.2 : 0);
  if (usableKm <= lowAt) {
    return FuelWarning(FuelWarningKind.low, title: 'Fuel low',
        message: 'Fuel low — ${nextText()}. About $left left.',
        voice: 'Fuel low. ${nextText()}.', stationId: next?.poi.id, nextKm: next?.distanceKm);
  }
  return FuelWarning.none;
}
