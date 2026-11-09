import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/analytics/chart_math.dart';

/// Pure maths behind the admin console charts (lib/domain/analytics/chart_math.dart).
void main() {
  group('nice scale', () {
    test('niceNum rounds to 1, 2, 2.5, 5, 10 x 10^n', () {
      expect(niceNum(1.2), 1);
      expect(niceNum(1.8), 2);
      expect(niceNum(3), 2.5);
      expect(niceNum(4.2), 5);
      expect(niceNum(8), 10);
      expect(niceNum(42), 50);
      expect(niceNum(0.03), closeTo(0.025, 1e-9));
      expect(niceNum(3, round: false), 5);
      expect(niceNum(0), 1);
    });

    test('fits the peak with about four nice steps from zero', () {
      final s = niceScale(42);
      expect(s.min, 0);
      expect(s.step, 10);
      expect(s.max, 50);
      expect(s.ticks, [0, 10, 20, 30, 40, 50]);
      expect(s.fraction(25), 0.5);
      expect(s.fraction(99), 1);
    });

    test('counts never get fractional steps; an all-zero series still has an axis', () {
      expect(niceScale(2).step, 1);
      expect(niceScale(2).max, 2);
      final zero = niceScale(0);
      expect(zero.max, greaterThan(0));
      expect(zero.ticks.first, 0);
      final km = niceScale(3.2, integers: false);
      expect(km.step, 1);
      expect(km.max, 4);
      expect(niceScale(1234).ticks.last, greaterThanOrEqualTo(1234));
    });
  });

  group('buckets', () {
    test('bucketByDay sums per day, oldest first, ignores the outside', () {
      final end = DateTime.utc(2026, 11, 9, 18);
      final pts = [
        (DateTime.utc(2026, 11, 9, 1), 2),
        (DateTime.utc(2026, 11, 9, 23), 3),
        (DateTime.utc(2026, 11, 7, 12), 1),
        (DateTime.utc(2026, 11, 1), 9), // outside 3 days
        (DateTime.utc(2026, 11, 10), 9), // future
      ];
      expect(bucketByDay(pts, end: end, days: 3), [1, 0, 5]);
      expect(bucketByDay(const [], end: end, days: 0), isEmpty);
    });

    test('rollup aligns to the end: 90 days become 13 sums, newest full', () {
      final days = List<num>.generate(90, (i) => 1);
      final weeks = rollup(days, 7);
      expect(weeks.length, 13);
      expect(weeks.first, 6); // 90 % 7
      expect(weeks.last, 7);
      expect(rollup([1, 2, 3, 4], 2, average: true), [1.5, 3.5]);
      expect(rollup([1, 2], 1), [1, 2]);
      expect(sumOf([1, 2, 3.5]), 6.5);
    });
  });

  group('change', () {
    test('percent change, trend and arrow text', () {
      expect(percentChange(12, 10), closeTo(20, 1e-9));
      expect(percentChange(5, 0), isNull);
      expect(trendOf(20), Trend.up);
      expect(trendOf(-3), Trend.down);
      expect(trendOf(0.2), Trend.flat);
      expect(trendOf(null), Trend.flat);
      expect(formatChange(12, 10), '▲ 20%');
      expect(formatChange(9, 10), '▼ 10%');
      expect(formatChange(95, 100), '▼ 5%');
      expect(formatChange(10, 10), 'No change');
      expect(formatChange(3, 0), 'New');
      expect(formatChange(0, 0), '—');
    });
  });

  group('labels', () {
    test('peak, short day, compact numbers', () {
      expect(peakOf([1, 4, 2, 4]), (index: 3, value: 4));
      expect(peakOf([0, 0]), isNull);
      expect(peakOf(const []), isNull);
      expect(shortDay('2026-11-03'), '3 Nov');
      expect(shortDay('week 3'), 'week 3');
      expect(compactNumber(42), '42');
      expect(compactNumber(1234), '1.2k');
      expect(compactNumber(12345), '12k');
      expect(compactNumber(2000), '2k');
      expect(compactNumber(1500000), '1.5M');
      expect(compactNumber(3.25), '3.3');
      expect(compactNumber(4.0), '4');
    });

    test('screen reader summary names the peak and its date', () {
      final labels = ['2026-11-01', '2026-11-02', '2026-11-03'];
      expect(chartSummary(title: 'Rides per day', period: 'last 30 days', values: [3, 1, 42], labels: labels), 'Rides per day, last 30 days, peak 42 on 3 Nov');
      expect(chartSummary(title: 'Km per day', period: 'last 7 days', values: [0, 1200, 0], labels: labels, unit: 'km'), 'Km per day, last 7 days, peak 1.2k km on 2 Nov');
      expect(chartSummary(title: 'Rides per day', period: 'last 7 days', values: [0, 0, 0], labels: labels), 'Rides per day, last 7 days, no data yet');
    });

    test('hit testing: bar slot and nearest line point', () {
      expect(indexAt(0, 300, 30), 0);
      expect(indexAt(299.9, 300, 30), 29);
      expect(indexAt(155, 300, 30), 15);
      expect(indexAt(10, 0, 3), -1);
      expect(nearestPoint(0, 300, 31), 0);
      expect(nearestPoint(300, 300, 31), 30);
      expect(nearestPoint(149, 300, 31), 15);
      expect(nearestPoint(50, 300, 1), 0);
    });
  });
}
