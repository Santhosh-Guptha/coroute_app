// 3.55 Marketing studio: layout maths shared by the painter, the editor gestures and the
// "all sizes" export. Pure Dart.

import 'dart:convert';
import 'dart:math' as math;

import 'marketing_template.dart';

/// Lengths in a template are units: 1 unit = 1 px when the canvas's short side is 1080 px.
const double kMkReferenceSide = 1080;

double mkUnitScale(int width, int height) => math.min(width, height) / kMkReferenceSide;

/// A layer's box in canvas pixels (centre, size, rotation in radians).
class MkBox {
  final double cx, cy, w, h, angle;
  const MkBox(this.cx, this.cy, this.w, this.h, this.angle);

  double get left => cx - w / 2;
  double get top => cy - h / 2;

  /// True when the canvas point (px, py) is inside the (rotated) box, with [slop] px extra.
  bool contains(double px, double py, {double slop = 0}) {
    final dx = px - cx, dy = py - cy;
    final c = math.cos(-angle), s = math.sin(-angle);
    final lx = dx * c - dy * s, ly = dx * s + dy * c;
    return lx.abs() <= w / 2 + slop && ly.abs() <= h / 2 + slop;
  }

  /// A point given in box-local coordinates (origin at the centre) in canvas pixels.
  (double, double) toCanvas(double lx, double ly) {
    final c = math.cos(angle), s = math.sin(angle);
    return (cx + lx * c - ly * s, cy + lx * s + ly * c);
  }
}

MkBox mkBoxOf(MkLayer l, int width, int height) => MkBox(l.x * width, l.y * height, l.w * width, l.h * height, l.rotation * math.pi / 180);

/// Index of the topmost visible layer under the canvas point, or -1.
int mkHitTest(MarketingTemplate t, double px, double py, {double slop = 0}) {
  for (var i = t.layers.length - 1; i >= 0; i--) {
    final l = t.layers[i];
    if (l.hidden) continue;
    if (mkBoxOf(l, t.size.width, t.size.height).contains(px, py, slop: slop)) return i;
  }
  return -1;
}

/// Result of snapping a dragged layer centre to the canvas centre guides.
class MkSnap {
  final double x, y;
  final bool vertical; // snapped to the vertical centre line (x = 0.5)
  final bool horizontal; // snapped to the horizontal centre line (y = 0.5)
  const MkSnap(this.x, this.y, this.vertical, this.horizontal);
}

/// Snaps a centre (fractions) to x = 0.5 / y = 0.5 when within [thresholdPx] canvas pixels.
MkSnap mkSnapCentre(double x, double y, int width, int height, {double thresholdPx = 12}) {
  final sv = ((x - 0.5) * width).abs() <= thresholdPx;
  final sh = ((y - 0.5) * height).abs() <= thresholdPx;
  return MkSnap(sv ? 0.5 : x, sh ? 0.5 : y, sv, sh);
}

/// Rotation snapped to the nearest multiple of 45 degrees within [threshold] degrees, in -180..180.
double mkSnapRotation(double degrees, {double threshold = 4}) {
  var d = degrees % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  final nearest = (d / 45).round() * 45.0;
  return (d - nearest).abs() <= threshold ? (nearest == -180 ? 180 : nearest) : d;
}

/// [t] laid out for another canvas size by relative positions:
///  - every layer keeps its centre (fractions);
///  - layers that keep their aspect (logo, QR, image, circle / star / burst) keep their pixel shape
///    and scale with the unit scale;
///  - other layers (text, coupon, rect / pill / ribbon) keep their width fraction; their height
///    scales with the unit scale (text and coupon lines shrink to fit when needed);
///  - layers are then nudged back inside the canvas.
/// Lengths are units, so they follow the unit scale on their own. The input is not changed.
MarketingTemplate mkRetarget(MarketingTemplate t, MkSize size) {
  final out = t.copy()..size = size;
  final w0 = t.size.width.toDouble(), h0 = t.size.height.toDouble();
  final w1 = size.width.toDouble(), h1 = size.height.toDouble();
  final k = mkUnitScale(size.width, size.height) / mkUnitScale(t.size.width, t.size.height);
  for (final l in out.layers) {
    if (l.keepsAspect) {
      l.w = (l.w * w0 * k / w1).clamp(0.005, 3.0);
      l.h = (l.h * h0 * k / h1).clamp(0.005, 3.0);
    } else {
      l.h = (l.h * h0 * k / h1).clamp(0.005, 3.0);
    }
    // Keep inside the canvas when the box fits (a box bigger than the canvas is left centred).
    if (l.w <= 1) l.x = l.x.clamp(l.w / 2, 1 - l.w / 2);
    if (l.h <= 1) l.y = l.y.clamp(l.h / 2, 1 - l.h / 2);
  }
  return out;
}

/// Undo / redo of the editor: snapshots of the template JSON.
class MkHistory {
  final int max;
  final List<String> _undo = [];
  final List<String> _redo = [];
  MkHistory({this.max = 60});

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Call BEFORE a change with the current state.
  void record(MarketingTemplate current) {
    final s = jsonEncode(current.toJson());
    if (_undo.isNotEmpty && _undo.last == s) return;
    _undo.add(s);
    if (_undo.length > max) _undo.removeAt(0);
    _redo.clear();
  }

  /// The previous state (the current one goes to redo), or null.
  MarketingTemplate? undo(MarketingTemplate current) {
    if (_undo.isEmpty) return null;
    _redo.add(jsonEncode(current.toJson()));
    return _restore(_undo.removeLast(), current);
  }

  MarketingTemplate? redo(MarketingTemplate current) {
    if (_redo.isEmpty) return null;
    _undo.add(jsonEncode(current.toJson()));
    return _restore(_redo.removeLast(), current);
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }

  static MarketingTemplate _restore(String s, MarketingTemplate current) {
    final t = MarketingTemplate.fromJson(jsonDecode(s));
    t
      ..id = current.id
      ..coupon = current.coupon
      ..updatedAt = current.updatedAt
      ..updatedBy = current.updatedBy;
    return t;
  }
}

/// Z-order and list edits used by the editor (pure, testable).
class MkLayerOps {
  static void bringForward(MarketingTemplate t, int i) {
    if (i < 0 || i >= t.layers.length - 1) return;
    final l = t.layers.removeAt(i);
    t.layers.insert(i + 1, l);
  }

  static void sendBackward(MarketingTemplate t, int i) {
    if (i <= 0 || i >= t.layers.length) return;
    final l = t.layers.removeAt(i);
    t.layers.insert(i - 1, l);
  }

  static void toFront(MarketingTemplate t, int i) {
    if (i < 0 || i >= t.layers.length) return;
    t.layers.add(t.layers.removeAt(i));
  }

  static void toBack(MarketingTemplate t, int i) {
    if (i < 0 || i >= t.layers.length) return;
    t.layers.insert(0, t.layers.removeAt(i));
  }

  /// Copies layer [i] just above it, offset a little; returns the new layer or null at the limit.
  static MkLayer? duplicate(MarketingTemplate t, int i) {
    if (i < 0 || i >= t.layers.length || t.layers.length >= MkLimits.maxLayers) return null;
    final src = t.layers[i];
    final c = src.copy()
      ..id = t.nextLayerId(src.type.name)
      ..x = (src.x + 0.03).clamp(-0.5, 1.5)
      ..y = (src.y + 0.03).clamp(-0.5, 1.5)
      ..locked = false;
    t.layers.insert(i + 1, c);
    return c;
  }
}
