import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/sun_helper.dart';

const double hydLat = 17.385;
const double hydLng = 78.4867;

/// 2026-10-05 in UTC; Hyderabad is UTC+5:30, so 12:35 UTC is about 6:05 PM IST.
DateTime utc(int h, [int m = 0]) => DateTime.utc(2026, 10, 5, h, m);

String fmt(DateTime t) {
  final u = t.toUtc();
  return '${u.hour}:${u.minute.toString().padLeft(2, '0')}Z';
}

void main() {
  test('Hyderabad sunset in early October is about 6:05 PM IST (12:35 UTC)', () {
    final sunset = DarkCheck.sunsetFor(utc(6), hydLat, hydLng)!.toUtc();
    final minutes = sunset.hour * 60 + sunset.minute;
    expect(minutes, inInclusiveRange(12 * 60 + 25, 12 * 60 + 50));
    final sunrise = DarkCheck.sunriseFor(utc(6), hydLat, hydLng)!.toUtc();
    expect(sunrise.hour, inInclusiveRange(0, 1), reason: 'about 6:05 AM IST');
  });

  test('isDark and untilDark', () {
    expect(DarkCheck.isDark(utc(6), hydLat, hydLng), isFalse, reason: '11:30 AM IST');
    expect(DarkCheck.isDark(utc(14), hydLat, hydLng), isTrue, reason: '7:30 PM IST');
    expect(DarkCheck.isDark(utc(0), hydLat, hydLng), isTrue, reason: '5:30 AM IST');
    final left = DarkCheck.untilDark(utc(12), hydLat, hydLng)!;
    expect(left.inMinutes, inInclusiveRange(25, 50));
    expect(DarkCheck.untilDark(utc(14), hydLat, hydLng), isNull, reason: 'already dark');
  });

  test('review line only when the ETA passes sunset', () {
    String? line(int depH, int depM, int etaMin) =>
        DarkCheck.reviewLine(departure: utc(depH, depM), eta: Duration(minutes: etaMin), lat: hydLat, lng: hydLng, fmtTime: fmt);
    expect(line(6, 0, 120), isNull, reason: 'arrives 1:30 PM IST');
    expect(line(11, 0, 60), isNull, reason: 'arrives 5:30 PM IST');
    final after = line(11, 0, 150)!;
    expect(after, startsWith('You will reach the destination after dark (sunset 12:'));
    expect(after, endsWith('Z).'));
    final dark = line(15, 0, 30)!;
    expect(dark, startsWith('It is dark now. Sunrise '));
    expect(DarkCheck.reviewLine(departure: utc(11), eta: const Duration(hours: 3), lat: 0, lng: 0, fmtTime: fmt), isNull, reason: 'no position');
  });

  test('ride line within 60 min of sunset, null by day and after dark', () {
    expect(DarkCheck.rideLine(now: utc(6), lat: hydLat, lng: hydLng), isNull);
    final soon = DarkCheck.rideLine(now: utc(12), lat: hydLat, lng: hydLng)!;
    expect(soon, startsWith('Dark in '));
    expect(soon, endsWith(' min'));
    final n = int.parse(soon.replaceAll(RegExp(r'[^0-9]'), ''));
    expect(n, inInclusiveRange(25, 50));
    expect(DarkCheck.rideLine(now: utc(14), lat: hydLat, lng: hydLng), isNull);
  });
}
