import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/avatar_image_codec.dart';
import '../../domain/media/avatar_crop.dart';

/// What the cropper hands to its caller to upload.
class AvatarCropResult {
  final AvatarCrop crop;
  final EncodedPicture cropped;

  /// The picture to keep for later adjusting (a new picture, or the first adjust of an older one);
  /// null when the gateway already holds the original.
  final EncodedPicture? original;
  const AvatarCropResult({required this.crop, required this.cropped, this.original});
}

/// 3.56 "Adjust picture" (docs/features_355/profile_photo_adjust.md): the profile picture under a
/// round mask; drag to move, pinch (or the slider) to zoom, turn left / right, reset, Save.
///
/// No package: `dart:ui` draws, [AvatarCropMath] does the numbers (tested without a device).
/// Deliberately NOT a SecureScreen: this is the rider's own public picture, screenshots stay allowed
/// (only sign-in, 2-step, ride lock and Medical ID screens are FLAG_SECURE).
class AvatarCropScreen extends StatefulWidget {
  /// The picture to adjust (JPEG / PNG / WebP bytes).
  final Uint8List bytes;

  /// The crop saved before (re-adjust), or null to start centred.
  final AvatarCrop? initialCrop;

  /// True when [bytes] must also be stored as the original (new picture / first adjust).
  final bool keepOriginal;

  /// A line under the title, e.g. that an older picture is adjusted from its current version.
  final String? note;

  /// Uploads the result; returns null on success or the message to show (the screen stays open).
  final Future<String?> Function(AvatarCropResult result) onSave;

  const AvatarCropScreen({super.key, required this.bytes, required this.onSave, this.initialCrop, this.keepOriginal = true, this.note});

  /// True when the picture was saved.
  static Future<bool> open(
    BuildContext context, {
    required Uint8List bytes,
    required Future<String?> Function(AvatarCropResult result) onSave,
    AvatarCrop? initialCrop,
    bool keepOriginal = true,
    String? note,
  }) async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AvatarCropScreen(bytes: bytes, onSave: onSave, initialCrop: initialCrop, keepOriginal: keepOriginal, note: note),
      ),
    );
    return ok == true;
  }

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  ui.Image? _image;
  bool _failed = false;
  bool _saving = false;
  AvatarCrop _crop = AvatarCrop.initial;
  double _zoomAtStart = 1;

  double get _w => _image?.width.toDouble() ?? 0;
  double get _h => _image?.height.toDouble() ?? 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final img = await AvatarImageCodec.decode(widget.bytes);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _image = img;
        _crop = AvatarCropMath.clamp(img.width.toDouble(), img.height.toDouble(), widget.initialCrop ?? AvatarCrop.initial);
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _set(AvatarCrop c) {
    if (_saving || _image == null) return;
    setState(() => _crop = c);
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    final img = _image;
    if (img == null || _saving) return;
    setState(() => _saving = true);
    String? problem;
    try {
      final cropped = await AvatarImageCodec.renderCrop(img, _crop);
      EncodedPicture? original;
      if (widget.keepOriginal) {
        original = await AvatarImageCodec.encodeOriginal(img);
        if (original == null) problem = 'This picture is too large. Please choose a smaller one.';
      }
      problem ??= await widget.onSave(AvatarCropResult(crop: _crop, cropped: cropped, original: original));
    } catch (_) {
      problem = 'The picture could not be saved. Please try again.';
    }
    if (!mounted) return;
    if (problem == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() => _saving = false);
    _say(problem);
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final maxZoom = img == null ? 1.0 : AvatarCropMath.maxZoomFor(_w, _h);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: dsScreenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DsScreenHeader(title: 'Adjust picture', onBack: _saving ? () {} : () => Navigator.maybePop(context)),
                  const SizedBox(height: 8),
                  Text(
                    widget.note ?? 'Drag to move. Pinch or use the slider to zoom. Other riders see the part inside the circle.',
                    style: AppText.caption,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final side = box.biggest.shortestSide.clamp(120.0, 440.0).toDouble();
                        if (_failed) {
                          return Center(child: Text('This picture could not be opened. Please choose another one.', style: AppText.body, textAlign: TextAlign.center));
                        }
                        if (img == null) return const Center(child: CircularProgressIndicator());
                        return Center(
                          child: Semantics(
                            label: 'Picture preview. Drag to move, pinch to zoom, double tap to reset.',
                            image: true,
                            child: GestureDetector(
                              onScaleStart: (_) => _zoomAtStart = _crop.zoom,
                              onScaleUpdate: (d) {
                                var c = AvatarCropMath.pan(_w, _h, _crop, d.focalPointDelta.dx, d.focalPointDelta.dy, side);
                                if (d.pointerCount > 1 && d.scale != 1) {
                                  c = AvatarCropMath.zoomTo(_w, _h, c, _zoomAtStart * d.scale,
                                      fx: (d.localFocalPoint.dx / side).clamp(0.0, 1.0).toDouble(), fy: (d.localFocalPoint.dy / side).clamp(0.0, 1.0).toDouble());
                                }
                                _set(c);
                              },
                              onDoubleTap: () => _set(AvatarCropMath.clamp(_w, _h, AvatarCrop(rot: _crop.rot))),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(Radii.md),
                                child: SizedBox(
                                  width: side,
                                  height: side,
                                  child: RepaintBoundary(
                                    child: CustomPaint(
                                      painter: _CropPainter(img, _crop),
                                      foregroundPainter: _MaskPainter(ring: AppTheme.accentText),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.zoom_out_rounded, color: AppTheme.textSecondary, size: 22),
                      Expanded(
                        child: Slider(
                          value: _crop.zoom.clamp(1.0, maxZoom).toDouble(),
                          min: 1,
                          max: maxZoom <= 1 ? 1.0001 : maxZoom,
                          semanticFormatterCallback: (v) => 'Zoom ${v.toStringAsFixed(1)} times',
                          onChanged: img == null || _saving || maxZoom <= 1 ? null : (v) => _set(AvatarCropMath.zoomTo(_w, _h, _crop, v)),
                        ),
                      ),
                      Icon(Icons.zoom_in_rounded, color: AppTheme.textSecondary, size: 22),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ToolButton(
                        icon: Icons.rotate_left_rounded,
                        label: 'Turn left',
                        onTap: img == null || _saving ? null : () => _set(AvatarCropMath.rotate(_w, _h, _crop, -1)),
                      ),
                      _ToolButton(
                        icon: Icons.rotate_right_rounded,
                        label: 'Turn right',
                        onTap: img == null || _saving ? null : () => _set(AvatarCropMath.rotate(_w, _h, _crop, 1)),
                      ),
                      _ToolButton(
                        icon: Icons.restart_alt_rounded,
                        label: 'Reset',
                        onTap: img == null || _saving ? null : () => _set(AvatarCropMath.clamp(_w, _h, AvatarCrop.initial)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DsButton(
                    label: _saving ? 'Saving...' : 'Save',
                    icon: _saving ? Icons.hourglass_top_rounded : Icons.check_rounded,
                    onPressed: img == null || _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled tool button, at least 56 px tall (easy with gloves).
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _ToolButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = onTap == null ? AppTheme.textMuted : AppTheme.textPrimary;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        borderRadius: BorderRadius.circular(Radii.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 88, minHeight: 56),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 2),
              Text(label, style: AppText.caption.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final AvatarCrop crop;
  _CropPainter(this.image, this.crop);

  @override
  void paint(Canvas canvas, Size size) {
    // Medium quality while dragging (smooth); the saved picture is drawn at high quality.
    AvatarImageCodec.paintCrop(canvas, image, crop, size.shortestSide, quality: FilterQuality.medium);
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.image != image || old.crop != crop;
}

/// Dims everything outside the circle and draws its ring.
class _MaskPainter extends CustomPainter {
  final Color ring;
  _MaskPainter({required this.ring});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Rect.fromCircle(center: rect.center, radius: size.shortestSide / 2 - 2);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect)
      ..addOval(circle);
    canvas.drawPath(outside, Paint()..color = const Color(0xA6000000));
    canvas.drawOval(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = ring,
    );
  }

  @override
  bool shouldRepaint(_MaskPainter old) => old.ring != ring;
}
