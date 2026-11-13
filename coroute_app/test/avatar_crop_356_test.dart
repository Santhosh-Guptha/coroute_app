import 'package:coroute_app/domain/media/avatar_crop.dart';
import 'package:flutter_test/flutter_test.dart';

/// 3.56 "Adjust picture": the crop maths shared with the gateway and the website
/// (docs/features_355/profile_photo_adjust.md). Pure Dart, no device needed.
void main() {
  const w = 1600.0, h = 1200.0;

  group('transform -> source square', () {
    test('zoom 1 in the middle is the largest centred square', () {
      final s = AvatarCropMath.sourceSquare(w, h, AvatarCrop.initial);
      expect(s.side, 1200);
      expect(s.left, 200);
      expect(s.top, 0);
      expect(AvatarCropMath.outputSize(w, h, AvatarCrop.initial), 512);
    });

    test('zoom 2 at a chosen centre', () {
      final s = AvatarCropMath.sourceSquare(w, h, const AvatarCrop(cx: 0.25, cy: 0.5, zoom: 2));
      expect(s.side, 600);
      expect(s.left, closeTo(100, 1e-9));
      expect(s.top, closeTo(300, 1e-9));
    });

    test('portrait picture', () {
      final s = AvatarCropMath.sourceSquare(600, 1000, const AvatarCrop(cx: 0.5, cy: 0.3, zoom: 1));
      expect(s.side, 600);
      expect(s.left, 0);
      expect(s.top, closeTo(0, 1e-9)); // 0.3 * 1000 - 300 = 0
    });
  });

  group('rotation', () {
    test('rotated size swaps for odd turns', () {
      expect(AvatarCropMath.rotatedSize(w, h, 0), (1600.0, 1200.0));
      expect(AvatarCropMath.rotatedSize(w, h, 1), (1200.0, 1600.0));
      expect(AvatarCropMath.rotatedSize(w, h, 2), (1600.0, 1200.0));
      expect(AvatarCropMath.rotatedSize(w, h, 3), (1200.0, 1600.0));
      expect(AvatarCropMath.normRot(-1), 3);
      expect(AvatarCropMath.normRot(5), 1);
    });

    test('the square seen after a turn maps back to the right source pixels', () {
      // Rotated 90 degrees right the picture is 1200 x 1600. A square of 600 at the top left of
      // what the rider sees is the BOTTOM left of the file.
      const c = AvatarCrop(cx: 0.25, cy: 0.1875, zoom: 2, rot: 1);
      final seen = AvatarCropMath.rotatedSquare(w, h, c);
      expect(seen.left, closeTo(0, 1e-9));
      expect(seen.top, closeTo(0, 1e-9));
      expect(seen.side, 600);
      final src = AvatarCropMath.sourceSquare(w, h, c);
      expect(src.left, closeTo(0, 1e-9));
      expect(src.top, closeTo(600, 1e-9));
      expect(src.bottom, closeTo(1200, 1e-9));

      // 180: top left seen = bottom right of the file.
      final src2 = AvatarCropMath.sourceSquare(w, h, const AvatarCrop(cx: 0.1875, cy: 0.25, zoom: 2, rot: 2));
      expect(src2.left, closeTo(1000, 1e-9));
      expect(src2.top, closeTo(600, 1e-9));

      // 270 right (= 90 left): top left seen = top right of the file.
      final src3 = AvatarCropMath.sourceSquare(w, h, const AvatarCrop(cx: 0.25, cy: 0.1875, zoom: 2, rot: 3));
      expect(src3.left, closeTo(1000, 1e-9));
      expect(src3.top, closeTo(0, 1e-9));
    });

    test('turning keeps the same part of the picture and four turns come home', () {
      const start = AvatarCrop(cx: 0.3, cy: 0.6, zoom: 2.5);
      final a = AvatarCropMath.sourceSquare(w, h, start);
      var c = start;
      for (var i = 1; i <= 4; i++) {
        c = AvatarCropMath.rotate(w, h, c, 1);
        expect(c.rot, i % 4);
        final s = AvatarCropMath.sourceSquare(w, h, c);
        expect(s.left, closeTo(a.left, 1e-6), reason: 'turn $i');
        expect(s.top, closeTo(a.top, 1e-6), reason: 'turn $i');
        expect(s.side, closeTo(a.side, 1e-6));
      }
      expect(c, start);
      // Left then right is where we started.
      final back = AvatarCropMath.rotate(w, h, AvatarCropMath.rotate(w, h, start, -1), 1);
      expect(back, start);
      expect(AvatarCropMath.rotate(w, h, start, -1).rot, 3);
    });
  });

  group('bounds', () {
    test('the square never leaves the picture', () {
      for (final c in const [
        AvatarCrop(cx: 0, cy: 0, zoom: 3),
        AvatarCrop(cx: 1, cy: 1, zoom: 3),
        AvatarCrop(cx: -5, cy: 9, zoom: 1.5, rot: 1),
        AvatarCrop(cx: 0.9, cy: 0.05, zoom: 8, rot: 3),
        AvatarCrop(cx: double.nan, cy: double.infinity, zoom: double.nan, rot: 7),
      ]) {
        final s = AvatarCropMath.sourceSquare(w, h, c);
        expect(s.left, greaterThanOrEqualTo(-1e-9), reason: '$c');
        expect(s.top, greaterThanOrEqualTo(-1e-9), reason: '$c');
        expect(s.right, lessThanOrEqualTo(w + 1e-9), reason: '$c');
        expect(s.bottom, lessThanOrEqualTo(h + 1e-9), reason: '$c');
        final k = AvatarCropMath.clamp(w, h, c);
        expect(k.rot, inInclusiveRange(0, 3));
        expect(k.zoom, inInclusiveRange(1, 8));
      }
    });

    test('zoom limits: 1..8, less for a small picture', () {
      expect(AvatarCropMath.clamp(w, h, const AvatarCrop(zoom: 0.2)).zoom, 1);
      expect(AvatarCropMath.clamp(w, h, const AvatarCrop(zoom: 40)).zoom, 8);
      expect(AvatarCropMath.maxZoomFor(96, 96), 3); // 96 / 32
      expect(AvatarCropMath.maxZoomFor(20, 20), 1);
      expect(AvatarCropMath.clamp(0, 0, const AvatarCrop(zoom: 3)), AvatarCrop.initial);
    });

    test('dragging and pinching', () {
      // Preview 300 px wide showing 1200 source px: 1 preview px = 4 source px.
      var c = AvatarCropMath.pan(w, h, AvatarCrop.initial, -30, 0, 300);
      expect(AvatarCropMath.sourceSquare(w, h, c).left, closeTo(320, 1e-9), reason: 'dragging left shows more of the right');
      c = AvatarCropMath.pan(w, h, c, -10000, 500, 300);
      final s = AvatarCropMath.sourceSquare(w, h, c);
      expect(s.right, closeTo(1600, 1e-9), reason: 'stops at the edge');
      expect(s.top, closeTo(0, 1e-9));
      expect(AvatarCropMath.pan(w, h, AvatarCrop.initial, 5, 5, 0), AvatarCrop.initial);

      // Zooming about the middle keeps the centre; about a corner keeps that corner's pixel.
      final z = AvatarCropMath.zoomTo(w, h, AvatarCrop.initial, 2);
      expect(z.cx, closeTo(0.5, 1e-9));
      expect(z.zoom, 2);
      final before = AvatarCropMath.rotatedSquare(w, h, AvatarCrop.initial);
      final corner = AvatarCropMath.zoomTo(w, h, AvatarCrop.initial, 2, fx: 0, fy: 0);
      final after = AvatarCropMath.rotatedSquare(w, h, corner);
      expect(after.left, closeTo(before.left, 1e-9));
      expect(after.top, closeTo(before.top, 1e-9));
    });
  });

  group('output size and the kept original', () {
    test('512 px, never enlarged', () {
      expect(AvatarCropMath.outputSize(w, h, const AvatarCrop(zoom: 2)), 512); // 600 px square
      expect(AvatarCropMath.outputSize(w, h, const AvatarCrop(zoom: 4)), 300);
      expect(AvatarCropMath.outputSize(100, 80, AvatarCrop.initial), 80);
      expect(AvatarCropMath.outputSize(0, 0, AvatarCrop.initial), 1);
    });

    test('original capped at 2048 px on the long side', () {
      expect(AvatarCropMath.originalSize(4000, 3000), (2048, 1536));
      expect(AvatarCropMath.originalSize(3000, 4000), (1536, 2048));
      expect(AvatarCropMath.originalSize(800, 600), (800, 600));
      expect(AvatarCropMath.originalSize(9000, 10), (2048, 2));
      expect(AvatarCropMath.originalSize(0, 10), (0, 0));
    });
  });

  group('wire format (same as the gateway)', () {
    test('round trip and refusal of bad values', () {
      const c = AvatarCrop(cx: 0.123456, cy: 0.5, zoom: 2.00004, rot: 3);
      expect(c.toQuery(), 'cx=0.1235&cy=0.5&zoom=2.0&rot=3');
      expect(AvatarCrop.fromJson(c.toJson()), const AvatarCrop(cx: 0.1235, cy: 0.5, zoom: 2, rot: 3));
      for (final bad in <Object?>[
        null,
        'x',
        {'cx': 0.5},
        {'cx': 2, 'cy': 0, 'zoom': 1, 'rot': 0},
        {'cx': 0, 'cy': 0, 'zoom': 9, 'rot': 0},
        {'cx': 0, 'cy': 0, 'zoom': 1, 'rot': 4},
        {'cx': 0, 'cy': 0, 'zoom': 1, 'rot': 1.5},
        {'cx': '0', 'cy': 0, 'zoom': 1, 'rot': 0},
      ]) {
        expect(AvatarCrop.fromJson(bad), isNull, reason: '$bad');
      }
    });
  });
}
