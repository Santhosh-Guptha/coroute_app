import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../../domain/media/avatar_crop.dart';

/// Encoded picture bytes and their type.
class EncodedPicture {
  final Uint8List bytes;
  final String mime;
  final int width;
  final int height;
  const EncodedPicture(this.bytes, this.mime, this.width, this.height);
}

/// 3.56 "Adjust picture": decoding, drawing and encoding for the profile-picture cropper
/// (docs/features_355/profile_photo_adjust.md). No package: `dart:ui` decodes and draws, and the
/// Android side (ImageEncodeChannel.kt, channel "coroute/image") writes the JPEG; where that is not
/// available the picture is written as PNG by `dart:ui`.
///
/// Everything saved is drawn onto the app's own canvas first, so it carries no EXIF data (no GPS, no
/// camera model, no date); the gateway removes metadata again on its side.
class AvatarImageCodec {
  AvatarImageCodec._();

  static const MethodChannel _channel = MethodChannel('coroute/image');

  /// The public picture must stay under the gateway's 2 MB limit, the original too.
  static const int maxUploadBytes = 2 * 1024 * 1024;

  /// Decodes JPEG / PNG / WebP bytes (the EXIF orientation is applied by the decoder). When the
  /// picture is larger than [maxSide] it is decoded smaller (less memory, same proportions).
  static Future<ui.Image> decode(Uint8List bytes, {int maxSide = AvatarCropMath.originalMaxPx}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final (tw, th) = AvatarCropMath.originalSize(descriptor.width, descriptor.height, maxSide: maxSide);
        final shrink = tw > 0 && (tw != descriptor.width || th != descriptor.height);
        final codec = await descriptor.instantiateCodec(targetWidth: shrink ? tw : null, targetHeight: shrink ? th : null);
        try {
          return (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  /// Draws [image] cropped by [crop] onto [canvas] so the crop square fills [side] x [side].
  /// The cropper preview and the saved picture use this same drawing.
  static void paintCrop(ui.Canvas canvas, ui.Image image, AvatarCrop crop, double side, {ui.FilterQuality quality = ui.FilterQuality.high}) {
    final w = image.width.toDouble(), h = image.height.toDouble();
    final c = AvatarCropMath.clamp(w, h, crop);
    final sq = AvatarCropMath.rotatedSquare(w, h, c);
    final (rw, rh) = AvatarCropMath.rotatedSize(w, h, c.rot);
    final k = side / sq.side;
    canvas.save();
    canvas.clipRect(ui.Rect.fromLTWH(0, 0, side, side));
    canvas.scale(k);
    canvas.translate(-sq.left, -sq.top);
    canvas.translate(rw / 2, rh / 2);
    canvas.rotate(c.rot * math.pi / 2);
    canvas.translate(-w / 2, -h / 2);
    canvas.drawImage(image, ui.Offset.zero, ui.Paint()..filterQuality = quality);
    canvas.restore();
  }

  /// The cropped public picture ([AvatarCropMath.outputSize] px square, white behind transparency).
  static Future<EncodedPicture> renderCrop(ui.Image image, AvatarCrop crop) async {
    final out = AvatarCropMath.outputSize(image.width.toDouble(), image.height.toDouble(), crop);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, out.toDouble(), out.toDouble()), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
    paintCrop(canvas, image, crop, out.toDouble());
    final picture = recorder.endRecording();
    final ui.Image rendered;
    try {
      rendered = await picture.toImage(out, out);
    } finally {
      picture.dispose();
    }
    try {
      return await _encode(rendered, quality: 88);
    } finally {
      rendered.dispose();
    }
  }

  /// The original to keep for later adjusting: [image] as decoded (at most 2048 px), re-encoded so
  /// it has no metadata. Null when it can not be written under the upload limit.
  static Future<EncodedPicture?> encodeOriginal(ui.Image image) async {
    for (final quality in const [88, 75, 60]) {
      final e = await _encode(image, quality: quality);
      if (e.bytes.length <= maxUploadBytes) return e;
      if (e.mime == 'image/png') break; // PNG has no quality to lower
    }
    return null;
  }

  static Future<EncodedPicture> _encode(ui.Image image, {required int quality}) async {
    try {
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw != null) {
        final jpeg = await _channel.invokeMethod<Uint8List>('encodeJpeg', {
          'rgba': raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
          'width': image.width,
          'height': image.height,
          'quality': quality,
        });
        if (jpeg != null && jpeg.length > 3 && jpeg[0] == 0xFF && jpeg[1] == 0xD8) {
          return EncodedPicture(jpeg, 'image/jpeg', image.width, image.height);
        }
      }
    } on PlatformException {
      // PNG below.
    } on MissingPluginException {
      // Not Android (or an old engine): PNG below.
    }
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('picture could not be encoded');
    return EncodedPicture(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes), 'image/png', image.width, image.height);
  }
}
