import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:coroute_app/domain/share/ride_card.dart';

/// v3.63 shareable ride card: sizes, privacy trim of both ends, only real numbers.
void main() {
  // ~111 m per 0.001 deg latitude.
  List<LatLng> line(int n) => [for (var i = 0; i < n; i++) LatLng(12.9 + i * 0.001, 77.6)];

  test('sizes for WhatsApp and Instagram Stories', () {
    expect(RideCardFormat.square.widthPx, 1080);
    expect(RideCardFormat.square.heightPx, 1080);
    expect(RideCardFormat.story.heightPx, 1920);
    expect(RideCardFormat.story.aspect, closeTo(0.5625, 1e-9));
  });

  test('the first and last 300 m are never drawn', () {
    final pts = line(50); // ~5.4 km
    final t = RideCard.trimEnds(pts, const {});
    expect(t.points.first.latitude, greaterThanOrEqualTo(12.9 + 0.0027 - 1e-9));
    expect(t.points.last.latitude, lessThanOrEqualTo(12.9 + 0.049 - 0.0027 + 1e-9));
    expect(t.points.contains(pts.first), isFalse);
    expect(t.points.contains(pts.last), isFalse);
  });

  test('a short ride shows no route at all', () {
    expect(RideCard.trimEnds(line(6), const {}).points, isEmpty); // ~555 m
    expect(RideCard.trimEnds(const [], const {}).points, isEmpty);
  });

  test('signal gaps are re-indexed after the trim', () {
    final pts = line(50);
    final t = RideCard.trimEnds(pts, {25});
    expect(t.breaks.length, 1);
    final b = t.breaks.first;
    expect(t.points[b], pts[25]);
  });

  test('only real numbers: unknown values are left out', () {
    expect(RideCard.safetyLine(sos: null), isNull);
    expect(RideCard.safetyLine(sos: 0), 'No SOS on this ride');
    expect(RideCard.hazardsText(null), isNull);
    expect(RideCard.hazardsText(0), 'No hazards logged');
    expect(RideCard.hazardsText(3), '3 hazards logged');
    expect(RideCard.hazardsText(1), '1 hazard logged');
    expect(RideCard.scoreOf(null, 'Ace Rider'), isNull);
    expect(RideCard.scoreOf(87, 'Ace Rider')!.label, 'Rider score · Ace Rider');
    expect(RideCard.routeLine('  '), '');
    expect(RideCard.routeLine('Nandi Hills'), 'Ride to Nandi Hills');
  });

  test('privacy zones: points near a saved place are removed and the gap is a break', () {
    final pts = [for (var i = 0; i < 10; i++) LatLng(12.0 + i * 0.001, 77.0)];
    final r = RideCard.withoutZones(pts, const {}, (p) => p.latitude > 12.0035 && p.latitude < 12.0065);
    expect(r.points.length, 7);
    expect(r.breaks, {4});
    expect(RideCard.withoutZones(pts, const {}, (_) => false).points.length, 10);
    expect(RideCard.withoutZones(pts, const {}, (_) => true).points, isEmpty);
  });
}
