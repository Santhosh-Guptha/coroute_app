import 'dart:math' as math;

/// 3.56 "Adjust picture" crop numbers (docs/features_355/profile_photo_adjust.md). The same four
/// numbers are stored by the gateway (src/avatars.js normaliseCrop) and used by the website
/// (gateway/public/assets/account.js), so a picture adjusted on one can be re-adjusted on the other.
///
///  * [rot]   quarter turns clockwise, 0..3
///  * [zoom]  1..[AvatarCropMath.maxZoom]; 1 = the largest square that fits the (rotated) picture
///  * [cx],[cy] centre of the square, 0..1 of the picture AFTER rotation
///
/// Pure Dart (no Flutter import): the maths is tested without a device.
class AvatarCrop {
  final double cx;
  final double cy;
  final double zoom;
  final int rot;
  const AvatarCrop({this.cx = 0.5, this.cy = 0.5, this.zoom = 1, this.rot = 0});

  static const AvatarCrop initial = AvatarCrop();

  AvatarCrop copyWith({double? cx, double? cy, double? zoom, int? rot}) =>
      AvatarCrop(cx: cx ?? this.cx, cy: cy ?? this.cy, zoom: zoom ?? this.zoom, rot: rot ?? this.rot);

  /// From the gateway (`avatarCrop` of GET /me/profile, or the X-Avatar-Crop header). Null when the
  /// value is missing or not usable; out-of-range numbers are refused, not guessed.
  static AvatarCrop? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final cx = raw['cx'], cy = raw['cy'], zoom = raw['zoom'], rot = raw['rot'];
    if (cx is! num || cy is! num || zoom is! num || rot is! num) return null;
    if (!cx.isFinite || !cy.isFinite || !zoom.isFinite || !rot.isFinite) return null;
    if (cx < 0 || cx > 1 || cy < 0 || cy > 1 || zoom < 1 || zoom > AvatarCropMath.maxZoom) return null;
    if (rot != rot.roundToDouble() || rot < 0 || rot > 3) return null;
    return AvatarCrop(cx: cx.toDouble(), cy: cy.toDouble(), zoom: zoom.toDouble(), rot: rot.toInt());
  }

  Map<String, Object> toJson() => {'cx': _r4(cx), 'cy': _r4(cy), 'zoom': _r4(zoom), 'rot': rot};

  /// `cx=..&cy=..&zoom=..&rot=..` for POST /me/avatar/crop (4 decimals, as the gateway stores them).
  String toQuery() => 'cx=${_r4(cx)}&cy=${_r4(cy)}&zoom=${_r4(zoom)}&rot=$rot';

  static double _r4(double v) => v.isFinite ? (v * 10000).round() / 10000 : v;

  @override
  bool operator ==(Object other) =>
      other is AvatarCrop && other.rot == rot && (other.cx - cx).abs() < 1e-9 && (other.cy - cy).abs() < 1e-9 && (other.zoom - zoom).abs() < 1e-9;

  @override
  int get hashCode => Object.hash(_r4(cx), _r4(cy), _r4(zoom), rot);

  @override
  String toString() => 'AvatarCrop(cx: ${_r4(cx)}, cy: ${_r4(cy)}, zoom: ${_r4(zoom)}, rot: $rot)';
}

/// A square in pixel coordinates.
class CropSquare {
  final double left;
  final double top;
  final double side;
  const CropSquare(this.left, this.top, this.side);
  double get right => left + side;
  double get bottom => top + side;

  @override
  String toString() => 'CropSquare($left, $top, $side)';
}

class AvatarCropMath {
  AvatarCropMath._();

  static const double maxZoom = 8;

  /// Side of the saved public picture.
  static const int outputPx = 512;

  /// The square is never smaller than this many source pixels (a tiny picture can not be zoomed
  /// into a blur of four pixels).
  static const double minSidePx = 32;

  /// Longest side of the original kept for later adjusting.
  static const int originalMaxPx = 2048;

  static int normRot(int rot) => ((rot % 4) + 4) % 4;

  /// Size of the picture after [rot] quarter turns.
  static (double, double) rotatedSize(double w, double h, int rot) => normRot(rot).isOdd ? (h, w) : (w, h);

  /// The largest zoom allowed for a [w] x [h] picture (so the square keeps [minSidePx] pixels).
  static double maxZoomFor(double w, double h) {
    final short = math.min(w, h);
    if (!(short > 0)) return 1;
    return math.max(1.0, math.min(maxZoom, short / minSidePx));
  }

  /// Side of the crop square in source pixels.
  static double sideOf(double w, double h, AvatarCrop c) => math.min(w, h) / c.zoom;

  /// [c] with every number inside its limits and the square fully inside the picture.
  static AvatarCrop clamp(double w, double h, AvatarCrop c) {
    if (!(w > 0) || !(h > 0)) return AvatarCrop.initial;
    final rot = normRot(c.rot);
    final z = c.zoom.isFinite ? c.zoom.clamp(1.0, maxZoomFor(w, h)).toDouble() : 1.0;
    final (rw, rh) = rotatedSize(w, h, rot);
    final side = math.min(w, h) / z;
    double fit(double v, double extent) {
      final half = side / 2 / extent;
      if (half >= 0.5) return 0.5;
      return (v.isFinite ? v : 0.5).clamp(half, 1 - half).toDouble();
    }

    return AvatarCrop(cx: fit(c.cx, rw), cy: fit(c.cy, rh), zoom: z, rot: rot);
  }

  /// The crop square in the ROTATED picture's pixels (what the rider sees).
  static CropSquare rotatedSquare(double w, double h, AvatarCrop crop) {
    final c = clamp(w, h, crop);
    final (rw, rh) = rotatedSize(w, h, c.rot);
    final side = sideOf(w, h, c);
    return CropSquare(c.cx * rw - side / 2, c.cy * rh - side / 2, side);
  }

  /// The same square in the ORIGINAL (unrotated) picture's pixels: what is read from the file.
  static CropSquare sourceSquare(double w, double h, AvatarCrop crop) {
    final c = clamp(w, h, crop);
    final s = rotatedSquare(w, h, c);
    switch (c.rot) {
      case 1: // 90 degrees clockwise: rotated (X, Y) came from source (Y, h - X)
        return CropSquare(s.top, h - s.right, s.side);
      case 2:
        return CropSquare(w - s.right, h - s.bottom, s.side);
      case 3: // 270 degrees clockwise: rotated (X, Y) came from source (w - Y, X)
        return CropSquare(w - s.bottom, s.left, s.side);
      default:
        return s;
    }
  }

  /// Side of the saved picture: [outputPx], or smaller when the square holds fewer pixels (a small
  /// picture is not blown up), never below 1.
  static int outputSize(double w, double h, AvatarCrop crop) {
    final side = sideOf(w, h, clamp(w, h, crop));
    return math.max(1, math.min(outputPx, side.round()));
  }

  /// Drag by ([dxView], [dyView]) logical pixels on a preview [viewSide] wide: the picture follows
  /// the finger, so the square's centre moves the other way.
  static AvatarCrop pan(double w, double h, AvatarCrop crop, double dxView, double dyView, double viewSide) {
    if (!(viewSide > 0)) return clamp(w, h, crop);
    final c = clamp(w, h, crop);
    final (rw, rh) = rotatedSize(w, h, c.rot);
    final perView = sideOf(w, h, c) / viewSide; // source pixels per preview pixel
    return clamp(w, h, c.copyWith(cx: c.cx - dxView * perView / rw, cy: c.cy - dyView * perView / rh));
  }

  /// Zoom to [zoom], keeping the picture point under ([fx], [fy]) (0..1 of the preview; the middle
  /// by default) where it is.
  static AvatarCrop zoomTo(double w, double h, AvatarCrop crop, double zoom, {double fx = 0.5, double fy = 0.5}) {
    final c = clamp(w, h, crop);
    final z = (zoom.isFinite ? zoom : c.zoom).clamp(1.0, maxZoomFor(w, h)).toDouble();
    final (rw, rh) = rotatedSize(w, h, c.rot);
    final before = sideOf(w, h, c);
    final after = math.min(w, h) / z;
    // The focal picture point: centre + (f - 0.5) * side, before and after.
    final px = c.cx * rw + (fx - 0.5) * before;
    final py = c.cy * rh + (fy - 0.5) * before;
    return clamp(w, h, AvatarCrop(cx: (px - (fx - 0.5) * after) / rw, cy: (py - (fy - 0.5) * after) / rh, zoom: z, rot: c.rot));
  }

  /// Turn by [quarterTurns] (positive = clockwise, right) keeping the same part of the picture in
  /// the middle and the same zoom.
  static AvatarCrop rotate(double w, double h, AvatarCrop crop, int quarterTurns) {
    var c = clamp(w, h, crop);
    final n = normRot(quarterTurns);
    for (var i = 0; i < n; i++) {
      c = AvatarCrop(cx: 1 - c.cy, cy: c.cx, zoom: c.zoom, rot: normRot(c.rot + 1));
    }
    return clamp(w, h, c);
  }

  /// Target size (w, h) for the kept original: the longest side at most [originalMaxPx], never
  /// enlarged, at least 1 px.
  static (int, int) originalSize(int w, int h, {int maxSide = originalMaxPx}) {
    if (w <= 0 || h <= 0) return (0, 0);
    final long = math.max(w, h);
    if (long <= maxSide) return (w, h);
    final k = maxSide / long;
    return (math.max(1, (w * k).round()), math.max(1, (h * k).round()));
  }
}
