import 'dart:math' as math;

/// Map zoom rules for place markers.
class PoiZoom {
  PoiZoom._();
  static const double iconsFrom = 12;
  static const double labelsFrom = 14;

  /// Most markers drawn at once (fewer when zoomed out).
  static int maxVisible(double zoom) => zoom < 13 ? 25 : zoom < 15 ? 40 : 60;
}

/// A candidate marker already projected to screen pixels.
class DeclutterItem<T> {
  const DeclutterItem({required this.value, required this.x, required this.y, required this.distanceM,
      this.rank = 5, this.pinned = false, this.labelWidth = 0});
  final T value;
  final double x, y, distanceM;
  final int rank;

  /// Always considered first (emergency hospitals, the selected place).
  final bool pinned;

  /// Pixel width of the text label; 0 = no label.
  final double labelWidth;
}

class Placed<T> {
  const Placed(this.value, {required this.showLabel});
  final T value;
  final bool showLabel;
}

/// Rough label width in pixels for a short single-line name.
double estimateLabelWidth(String text, {double charPx = 6.6, double maxPx = 132}) =>
    text.isEmpty ? 0 : math.min(maxPx, 8 + text.length * charPx);

/// Nearest first (pinned, then distance, then rank); a marker is kept only when
/// its icon does not overlap one already kept. Its label is kept only when the
/// label box is also free; otherwise the icon is drawn alone. At most [max].
List<Placed<T>> declutter<T>(List<DeclutterItem<T>> items, {required int max, double iconPx = 26,
    double gapPx = 3, double labelGapPx = 4, double? viewW, double? viewH}) {
  final sorted = [...items]..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final d = a.distanceM.compareTo(b.distanceM);
      return d != 0 ? d : a.rank.compareTo(b.rank);
    });
  final boxes = <math.Rectangle<double>>[];
  final out = <Placed<T>>[];
  bool free(math.Rectangle<double> r) => !boxes.any((b) => b.intersects(r));
  final half = iconPx / 2 + gapPx / 2;
  for (final it in sorted) {
    if (out.length >= max) break;
    if (!it.x.isFinite || !it.y.isFinite) continue;
    if (viewW != null && viewH != null && (it.x < -half || it.y < -half || it.x > viewW + half || it.y > viewH + half)) continue;
    final icon = math.Rectangle<double>(it.x - half, it.y - half, half * 2, half * 2);
    if (!free(icon)) continue;
    var showLabel = false;
    if (it.labelWidth > 0) {
      final label = math.Rectangle<double>(it.x + half, it.y - half, labelGapPx + it.labelWidth, half * 2);
      if (free(label)) {
        boxes.add(label);
        showLabel = true;
      }
    }
    boxes.add(icon);
    out.add(Placed(it.value, showLabel: showLabel));
  }
  return out;
}
