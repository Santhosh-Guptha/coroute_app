/// Pure maths behind the admin console charts: nice axis ticks, day buckets,
/// roll-ups, period-over-period change, peaks and the one-line summary a
/// screen reader announces. No Flutter, so every piece is unit tested.
library;

import 'dart:math' as math;

/// An axis from [min] to [max] in steps of [step] (all "nice" numbers: 1, 2, 2.5, 5 x 10^n).
class NiceScale {
  final double min;
  final double max;
  final double step;

  const NiceScale(this.min, this.max, this.step);

  /// The tick values from [min] to [max] inclusive.
  List<double> get ticks {
    if (step <= 0) return [min];
    final n = ((max - min) / step).round();
    return [for (var i = 0; i <= n; i++) _clean(min + step * i)];
  }

  /// Where [v] sits on the axis, 0 (at [min]) to 1 (at [max]).
  double fraction(num v) => max == min ? 0 : ((v - min) / (max - min)).clamp(0.0, 1.0).toDouble();

  @override
  String toString() => 'NiceScale($min..$max step $step)';
}

double _clean(double v) => double.parse(v.toStringAsFixed(6));

/// The "nice" number closest to [x] (rounded) or just above it (not rounded):
/// 1, 2, 2.5 (rounded only), 5 or 10 times a power of ten.
double niceNum(double x, {bool round = true}) {
  if (x <= 0 || !x.isFinite) return 1;
  final exp = (math.log(x) / math.ln10).floor();
  final pow10 = math.pow(10, exp).toDouble();
  final f = x / pow10;
  double nf;
  if (round) {
    nf = f < 1.5 ? 1 : (f < 2.25 ? 2 : (f < 3.5 ? 2.5 : (f < 7.5 ? 5 : 10)));
  } else {
    nf = f <= 1 ? 1 : (f <= 2 ? 2 : (f <= 5 ? 5 : 10));
  }
  return nf * pow10;
}

/// A scale from 0 (or [minValue]) that fits [maxValue] with about [ticks] steps.
/// Counts ([integers]) never get a fractional step; an all-zero series gets 0..[ticks].
NiceScale niceScale(num maxValue, {num minValue = 0, int ticks = 4, bool integers = true}) {
  final lo = minValue.toDouble();
  var hi = maxValue.toDouble();
  if (!hi.isFinite || hi <= lo) hi = lo + (integers ? ticks : 1);
  var step = niceNum((hi - lo) / math.max(1, ticks), round: true);
  if (integers && step < 1) step = 1;
  final niceMin = (lo / step).floor() * step;
  var niceMax = (hi / step).ceil() * step;
  if (niceMax <= niceMin) niceMax = niceMin + step;
  return NiceScale(_clean(niceMin), _clean(niceMax), _clean(step));
}

/// Sums [points] (time, value) into [days] calendar days ending on [end]'s day
/// (inclusive), oldest first. Points outside the window are ignored. Days are
/// local to [end] (a DateTime in UTC buckets by UTC days).
List<num> bucketByDay(Iterable<(DateTime, num)> points, {required DateTime end, required int days}) {
  final out = List<num>.filled(math.max(0, days), 0);
  if (days <= 0) return out;
  final last = DateTime.utc(end.year, end.month, end.day);
  for (final (t, v) in points) {
    final local = end.isUtc ? t.toUtc() : t.toLocal();
    final d = DateTime.utc(local.year, local.month, local.day);
    final i = days - 1 - last.difference(d).inDays;
    if (i >= 0 && i < days) out[i] += v;
  }
  return out;
}

/// Groups [values] into chunks of [size] (sum by default, or the mean with [average]),
/// aligned to the END so the newest chunk is always full: 90 days become 13 weeks with the
/// oldest, partial week first.
List<num> rollup(List<num> values, int size, {bool average = false}) {
  if (size <= 1) return List<num>.of(values);
  final out = <num>[];
  final rem = values.length % size;
  var i = 0;
  if (rem > 0) {
    out.add(_agg(values.sublist(0, rem), average));
    i = rem;
  }
  for (; i < values.length; i += size) {
    out.add(_agg(values.sublist(i, i + size), average));
  }
  return out;
}

num _agg(List<num> part, bool average) {
  final s = part.fold<num>(0, (a, b) => a + b);
  return average ? (part.isEmpty ? 0 : s / part.length) : s;
}

num sumOf(Iterable<num> values) => values.fold<num>(0, (a, b) => a + b);

/// Percent change from [previous] to [current]; null when there is nothing to compare
/// (previous is 0), so a screen never shows "+infinity %".
double? percentChange(num current, num previous) {
  if (previous == 0) return null;
  return (current - previous) / previous.abs() * 100;
}

/// Up, down or flat (under half a percent counts as flat).
enum Trend { up, down, flat }

Trend trendOf(double? pct) {
  if (pct == null || pct.abs() < 0.5) return Trend.flat;
  return pct > 0 ? Trend.up : Trend.down;
}

/// "▲ 12%", "▼ 5%", "No change" or, with nothing before, "New" (when [current] > 0) or "—".
String formatChange(num current, num previous) {
  final pct = percentChange(current, previous);
  if (pct == null) return current > 0 ? 'New' : '—';
  final t = trendOf(pct);
  if (t == Trend.flat) return 'No change';
  final n = pct.abs();
  final txt = n >= 10 ? n.round().toString() : n.toStringAsFixed(n < 1 ? 1 : 0);
  return '${t == Trend.up ? '▲' : '▼'} $txt%';
}

/// The highest value and its index (the latest one on a tie); null for an empty or all-zero list.
({int index, num value})? peakOf(List<num> values) {
  ({int index, num value})? best;
  for (var i = 0; i < values.length; i++) {
    if (values[i] > 0 && (best == null || values[i] >= best.value)) best = (index: i, value: values[i]);
  }
  return best;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "3 Nov" for an ISO day ("2026-11-03"); the input back when it is not a date.
String shortDay(String isoDay) {
  final d = DateTime.tryParse(isoDay);
  if (d == null) return isoDay;
  return '${d.day} ${_months[d.month - 1]}';
}

/// "1.2k", "34k", "1.5M"; whole numbers below 1000; one decimal for small fractions.
String compactNumber(num v) {
  final a = v.abs();
  String trim(String s) => s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  if (a >= 1e6) return '${v < 0 ? '-' : ''}${trim((a / 1e6).toStringAsFixed(a >= 1e7 ? 0 : 1))}M';
  if (a >= 1e3) return '${v < 0 ? '-' : ''}${trim((a / 1e3).toStringAsFixed(a >= 1e4 ? 0 : 1))}k';
  if (v is int || v == v.roundToDouble()) return v.round().toString();
  return trim(v.toStringAsFixed(1));
}

/// What a screen reader says for a chart: "Rides per day, last 30 days, peak 42 on 3 Nov",
/// or "..., no data yet" when every value is 0.
String chartSummary({required String title, required String period, required List<num> values, required List<String> labels, String unit = ''}) {
  final p = peakOf(values);
  if (p == null) return '$title, $period, no data yet';
  final when = p.index < labels.length ? ' on ${shortDay(labels[p.index])}' : '';
  final u = unit.isEmpty ? '' : ' $unit';
  return '$title, $period, peak ${compactNumber(p.value)}$u$when';
}

/// Index of the bar or point under [dx] in a plot [width] wide holding [count] slots.
int indexAt(double dx, double width, int count) {
  if (count <= 0 || width <= 0) return -1;
  return (dx / width * count).floor().clamp(0, count - 1);
}

/// Index of the line point nearest to [dx] when [count] points span [width] edge to edge.
int nearestPoint(double dx, double width, int count) {
  if (count <= 0 || width <= 0) return -1;
  if (count == 1) return 0;
  return (dx / width * (count - 1)).round().clamp(0, count - 1);
}
