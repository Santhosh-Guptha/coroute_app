import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/services/api_client.dart';
import '../../../domain/marketing/marketing_layout.dart';
import '../../../domain/marketing/marketing_placeholders.dart';
import '../../../domain/marketing/marketing_template.dart';
import '../admin_payments_widgets.dart';
import '../admin_ui.dart';
import 'marketing_api.dart';
import 'marketing_inspector.dart';
import 'marketing_painter.dart';

enum _DragMode { none, move, resize, rotate, pinch }

/// 3.55 Marketing studio editor: canvas (tap to select, drag to move, corner handle to resize,
/// top handle to rotate, pinch / twist on touch), snap to the centre guides, layers with z-order,
/// duplicate, delete, undo / redo, the coupon binding, save to the gateway and export to PNG
/// (one size or every size) shared with a ready caption.
class MarketingEditorScreen extends StatefulWidget {
  final MarketingTemplate initial;
  const MarketingEditorScreen({super.key, required this.initial});

  @override
  State<MarketingEditorScreen> createState() => _MarketingEditorScreenState();
}

class _MarketingEditorScreenState extends State<MarketingEditorScreen> with SingleTickerProviderStateMixin {
  late MarketingTemplate _t = widget.initial.copy();
  final MkHistory _history = MkHistory();
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final Map<String, ui.Image> _images = {};
  String? _selected;
  String? _lastEditKey;
  bool _dirty = false;
  bool _saving = false;
  bool _exporting = false;
  int _rev = 0;
  int _epoch = 0;

  // gesture state
  _DragMode _mode = _DragMode.none;
  MkLayer? _start;
  Offset _startFocal = Offset.zero;
  bool _guideV = false, _guideH = false;
  double _scale = 1; // screen px per canvas px

  MarketingApi get _api => MarketingApi(context.read<ApiClient>());
  String get _site => AppConfig.apiBaseUrl;
  Map<String, String> get _values => MkPlaceholders.valuesFor(_t, siteBase: _site);
  MkLayer? get _layer => _t.layerById(_selected);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadImages());
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final i in _images.values) {
      i.dispose();
    }
    super.dispose();
  }

  Future<void> _loadImages() async {
    for (final id in _t.imageIds) {
      if (_images.containsKey(id)) continue;
      final img = await _api.loadImage(id);
      if (!mounted) {
        img?.dispose();
        return;
      }
      if (img != null) setState(() => _images[id] = img);
    }
  }

  // ------------------------------------------------------------------ edits
  void _edit(String key, VoidCallback change, {bool refresh = false}) {
    if (key != _lastEditKey) _history.record(_t);
    _lastEditKey = key;
    setState(() {
      change();
      _dirty = true;
      _rev++;
      if (refresh) _epoch++;
    });
  }

  /// A one-off change (its own undo step).
  void _change(VoidCallback change) {
    _lastEditKey = null;
    _edit('op${DateTime.now().microsecondsSinceEpoch}', change, refresh: true);
    _lastEditKey = null;
  }

  void _undo() {
    final prev = _history.undo(_t);
    if (prev == null) return;
    setState(() {
      _t = prev;
      _lastEditKey = null;
      _dirty = true;
      _rev++;
      _epoch++;
      if (_t.layerById(_selected) == null) _selected = null;
    });
  }

  void _redo() {
    final next = _history.redo(_t);
    if (next == null) return;
    setState(() {
      _t = next;
      _lastEditKey = null;
      _dirty = true;
      _rev++;
      _epoch++;
      if (_t.layerById(_selected) == null) _selected = null;
    });
  }

  void _select(String? id) {
    setState(() {
      _selected = id;
      _lastEditKey = null;
      _epoch++;
    });
    if (id != null && _tabs.index != 0) _tabs.animateTo(0);
  }

  void _add(MkLayer l) {
    if (_t.layers.length >= MkLimits.maxLayers) {
      adminSnack(context, 'At most ${MkLimits.maxLayers} layers.', error: true);
      return;
    }
    _change(() => _t.layers.add(l));
    _select(l.id);
  }

  Future<void> _addMenu(String what) async {
    switch (what) {
      case 'text':
        _add(MkLayer.newText(_t.nextLayerId('text')));
      case 'coupon':
        _add(MkLayer.newCoupon(_t.nextLayerId('coupon')));
      case 'logo':
        _add(MkLayer.newLogo(_t.nextLayerId('logo')));
      case 'qr':
        _add(MkLayer.newQr(_t.nextLayerId('qr')));
      case 'limited':
        _add(MkLayer.newShape(_t.nextLayerId('badge'), 'burst', label: 'LIMITED'));
      case 'new':
        _add(MkLayer.newShape(_t.nextLayerId('badge'), 'pill', label: 'NEW')
          ..x = 0.82
          ..y = 0.1
          ..w = 0.2
          ..h = 0.07);
      case 'image':
        final id = await _pickAndUpload();
        if (id != null) {
          if (_t.layers.where((l) => l.type == MkLayerType.image).length >= MkLimits.maxImageLayers) {
            if (mounted) adminSnack(context, 'At most ${MkLimits.maxImageLayers} image layers.', error: true);
            return;
          }
          _add(MkLayer.newImage(_t.nextLayerId('image'), id));
        }
      default:
        if (what.startsWith('shape:')) _add(MkLayer.newShape(_t.nextLayerId('shape'), what.substring(6)));
    }
  }

  void _duplicate() {
    final i = _t.layers.indexWhere((l) => l.id == _selected);
    if (i < 0) return;
    MkLayer? c;
    _change(() => c = MkLayerOps.duplicate(_t, i));
    if (c == null) {
      adminSnack(context, 'At most ${MkLimits.maxLayers} layers.', error: true);
    } else {
      _select(c!.id);
    }
  }

  void _delete() {
    final i = _t.layers.indexWhere((l) => l.id == _selected);
    if (i < 0) return;
    _change(() => _t.layers.removeAt(i));
    _select(null);
  }

  void _zOrder(void Function(MarketingTemplate, int) op) {
    final i = _t.layers.indexWhere((l) => l.id == _selected);
    if (i < 0) return;
    _change(() => op(_t, i));
  }

  // ------------------------------------------------------------------ images
  Future<String?> _pickAndUpload() async {
    XFile? f;
    try {
      f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, maxHeight: 2000, imageQuality: 85, requestFullMetadata: false);
    } catch (_) {
      if (mounted) adminSnack(context, 'Could not open your photos.', error: true);
      return null;
    }
    if (f == null) return null;
    final Uint8List bytes = await f.readAsBytes();
    final type = MarketingApi.sniffType(bytes);
    if (!mounted) return null;
    if (type == null) {
      adminSnack(context, 'Pick a JPEG, PNG or WebP image.', error: true);
      return null;
    }
    if (bytes.length > 2 * 1024 * 1024) {
      adminSnack(context, 'This image is larger than 2 MB. Pick a smaller one.', error: true);
      return null;
    }
    try {
      final id = await _api.uploadImage(bytes, type);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return null;
      }
      setState(() => _images[id] = frame.image);
      return id;
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
      return null;
    }
  }

  Future<void> _pickForSelected() async {
    final l = _layer;
    if (l == null || l.type != MkLayerType.image) return;
    final id = await _pickAndUpload();
    if (id != null) _change(() => l.imageId = id);
  }

  Future<void> _pickBackground() async {
    final id = await _pickAndUpload();
    if (id != null) {
      _change(() {
        _t.background.kind = 'image';
        _t.background.imageId = id;
      });
    }
  }

  // ------------------------------------------------------------------ coupon
  Future<void> _bindCoupon() async {
    final picked = await showAppSheet<Object>(
      context,
      isScrollControlled: true,
      title: 'Bind a coupon',
      builder: (_) => _CouponPicker(api: _api, current: _t.couponCode),
    );
    if (!mounted || picked == null) return;
    if (picked is MkCouponInfo) {
      _change(() {
        _t.couponCode = picked.code;
        _t.coupon = picked;
      });
    } else if (picked == 'none') {
      _change(() {
        _t.couponCode = null;
        _t.coupon = null;
      });
    }
  }

  // ------------------------------------------------------------------ save / export
  Future<bool> _save() async {
    final problems = _t.validate();
    if (problems.isNotEmpty) {
      adminSnack(context, problems.first, error: true);
      return false;
    }
    setState(() => _saving = true);
    try {
      final saved = await _api.save(_t);
      if (!mounted) return false;
      setState(() {
        _t.id = saved.id;
        _t.updatedAt = saved.updatedAt;
        _t.updatedBy = saved.updatedBy;
        _t.coupon = saved.coupon;
        _t.couponCode = saved.couponCode;
        _dirty = false;
        _rev++;
      });
      adminSnack(context, 'Template saved.');
      return true;
    } catch (e) {
      if (!mounted) return false;
      final msg = e is ApiException && e.code == 'CONFLICT' ? 'Another admin saved this template meanwhile. Close it and open it again to see their version.' : adminErrorOf(e);
      adminSnack(context, msg, error: true);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _defaultCaption {
    final v = _values;
    if (_t.caption.trim().isNotEmpty) return MkPlaceholders.substitute(_t.caption, v);
    return MkPlaceholders.autoCaption(v, bound: _t.coupon != null && !_t.coupon!.missing);
  }

  /// Null when exporting is fine; otherwise asks / explains. Returns false to stop.
  Future<bool> _exportAllowed() async {
    final c = _t.coupon;
    if (MkPlaceholders.templateNeedsCoupon(_t) && (c == null || c.missing)) {
      adminSnack(context, c?.missing == true ? 'The bound coupon no longer exists. Bind another coupon first.' : 'Bind an active coupon first: the image would show sample values.', error: true);
      return false;
    }
    if (c != null && (c.warning != null || c.isExpiredAt(DateTime.now().millisecondsSinceEpoch)) && c.status != 'SCHEDULED') {
      return confirmAction(
        context,
        title: 'Coupon cannot be used',
        message: '${c.warning ?? 'This coupon has expired.'} Riders who see this image will not be able to redeem ${c.code}. Export anyway?',
        confirmLabel: 'Export anyway',
        destructive: true,
      );
    }
    return true;
  }

  Future<void> _export({required bool allSizes, required String caption}) async {
    if (_exporting) return;
    if (!await _exportAllowed()) return;
    if (!mounted) return;
    setState(() => _exporting = true);
    try {
      await _loadImages();
      final values = _values;
      final sizes = allSizes ? [MkSize.of(MkSizePreset.instagramPost), MkSize.of(MkSizePreset.instagramStory), MkSize.of(MkSizePreset.banner)] : [_t.size];
      final files = <XFile>[];
      final safe = _t.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
      for (final s in sizes) {
        final tpl = s.width == _t.size.width && s.height == _t.size.height ? _t : mkRetarget(_t, s);
        final png = await renderMarketingPng(tpl, values, images: _images);
        files.add(XFile.fromData(png, mimeType: 'image/png', name: '${safe.isEmpty ? 'coroute_offer' : safe}_${s.width}x${s.height}.png'));
      }
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(ShareParams(
        files: files,
        text: caption,
        subject: _t.name,
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (e) {
      if (mounted) adminSnack(context, 'Could not make the image: $e', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openExport() async {
    await showAppSheet<void>(
      context,
      isScrollControlled: true,
      title: 'Export and share',
      builder: (ctx) => _ExportSheet(
        caption: _defaultCaption,
        warning: _t.coupon?.warning,
        size: _t.size,
        busy: _exporting,
        onShare: (caption, all) {
          Navigator.pop(ctx);
          _export(allSizes: all, caption: caption);
        },
      ),
    );
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    return confirmAction(context, title: 'Leave without saving?', message: 'Your changes to "${_t.name}" are not saved.', confirmLabel: 'Leave', destructive: true);
  }

  // ------------------------------------------------------------------ canvas gestures
  Offset _toCanvas(Offset local) => local / _scale;

  void _onTapUp(TapUpDetails d) {
    final p = _toCanvas(d.localPosition);
    final i = mkHitTest(_t, p.dx, p.dy, slop: 6 / _scale);
    _select(i < 0 ? null : _t.layers[i].id);
  }

  void _onScaleStart(ScaleStartDetails d) {
    final p = _toCanvas(d.localFocalPoint);
    _startFocal = d.localFocalPoint;
    final sel = _layer;
    _mode = _DragMode.none;
    if (sel != null && !sel.locked && !sel.hidden) {
      final b = mkBoxOf(sel, _t.size.width, _t.size.height);
      final hs = MarketingPreviewPainter.handle / _scale;
      final (rx, ry) = b.toCanvas(b.w / 2, b.h / 2);
      final (tx, ty) = b.toCanvas(0, -b.h / 2 - hs * 1.4);
      if (d.pointerCount >= 2) {
        _mode = _DragMode.pinch;
      } else if ((Offset(rx, ry) - p).distance <= hs) {
        _mode = _DragMode.resize;
      } else if ((Offset(tx, ty) - p).distance <= hs) {
        _mode = _DragMode.rotate;
      } else if (b.contains(p.dx, p.dy, slop: 6 / _scale)) {
        _mode = _DragMode.move;
      }
    }
    if (_mode == _DragMode.none && d.pointerCount == 1) {
      final i = mkHitTest(_t, p.dx, p.dy, slop: 6 / _scale);
      if (i >= 0) {
        _select(_t.layers[i].id);
        if (!_t.layers[i].locked) _mode = _DragMode.move;
      }
    }
    if (_mode != _DragMode.none) {
      _history.record(_t);
      _lastEditKey = null;
      _start = _layer?.copy();
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final l = _layer, s = _start;
    if (l == null || s == null || _mode == _DragMode.none) return;
    final w = _t.size.width, h = _t.size.height;
    setState(() {
      _dirty = true;
      _rev++;
      switch (_mode) {
        case _DragMode.move:
          final delta = (d.localFocalPoint - _startFocal) / _scale;
          final snap = mkSnapCentre(s.x + delta.dx / w, s.y + delta.dy / h, w, h, thresholdPx: 10 / _scale);
          l.x = snap.x.clamp(-0.5, 1.5);
          l.y = snap.y.clamp(-0.5, 1.5);
          _guideV = snap.vertical;
          _guideH = snap.horizontal;
          if (d.pointerCount >= 2) {
            _mode = _DragMode.pinch;
          }
        case _DragMode.pinch:
          l.w = (s.w * d.scale).clamp(0.01, 3.0);
          l.h = (s.h * d.scale).clamp(0.01, 3.0);
          l.rotation = mkSnapRotation(s.rotation + d.rotation * 180 / math.pi);
        case _DragMode.resize:
          final p = _toCanvas(d.localFocalPoint);
          final b = mkBoxOf(s, w, h);
          final dx = p.dx - b.cx, dy = p.dy - b.cy;
          final c = math.cos(-b.angle), sn = math.sin(-b.angle);
          final lx = (dx * c - dy * sn).abs() * 2, ly = (dx * sn + dy * c).abs() * 2;
          if (l.keepsAspect) {
            final k = math.max(lx / b.w, ly / b.h);
            l.w = (s.w * k).clamp(0.01, 3.0);
            l.h = (s.h * k).clamp(0.01, 3.0);
          } else {
            l.w = (lx / w).clamp(0.01, 3.0);
            l.h = (ly / h).clamp(0.01, 3.0);
          }
        case _DragMode.rotate:
          final p = _toCanvas(d.localFocalPoint);
          final b = mkBoxOf(s, w, h);
          l.rotation = mkSnapRotation(math.atan2(p.dy - b.cy, p.dx - b.cx) * 180 / math.pi + 90);
        case _DragMode.none:
          break;
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    setState(() {
      _mode = _DragMode.none;
      _start = null;
      _guideV = _guideH = false;
      _epoch++;
    });
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final l = _layer;
    final c = _t.coupon;
    final needsCoupon = MkPlaceholders.templateNeedsCoupon(_t);
    final banner = c != null && c.warning != null
        ? c.warning!
        : (needsCoupon && (c == null || c.missing) ? 'No coupon bound: sample values are shown. Bind an active coupon before exporting.' : null);

    final toolbar = Wrap(spacing: 2, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      PopupMenuButton<String>(
        tooltip: 'Add a layer',
        onSelected: _addMenu,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'text', child: Text('Text')),
          PopupMenuItem(value: 'coupon', child: Text('Coupon block')),
          PopupMenuItem(value: 'logo', child: Text('CoRoute logo')),
          PopupMenuItem(value: 'qr', child: Text('QR code')),
          PopupMenuItem(value: 'image', child: Text('Image (upload)')),
          PopupMenuDivider(),
          PopupMenuItem(value: 'limited', child: Text('Badge: LIMITED')),
          PopupMenuItem(value: 'new', child: Text('Badge: NEW')),
          PopupMenuItem(value: 'shape:ribbon', child: Text('Ribbon')),
          PopupMenuItem(value: 'shape:pill', child: Text('Pill')),
          PopupMenuItem(value: 'shape:circle', child: Text('Circle')),
          PopupMenuItem(value: 'shape:rect', child: Text('Rectangle')),
          PopupMenuItem(value: 'shape:star', child: Text('Star')),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.add_box_outlined, color: AppTheme.accentText), const SizedBox(width: 4), Text('Add', style: AppText.label.copyWith(color: AppTheme.accentText))]),
        ),
      ),
      IconButton(tooltip: 'Undo', onPressed: _history.canUndo ? _undo : null, icon: const Icon(Icons.undo_rounded)),
      IconButton(tooltip: 'Redo', onPressed: _history.canRedo ? _redo : null, icon: const Icon(Icons.redo_rounded)),
      IconButton(tooltip: 'Duplicate layer', onPressed: l == null ? null : _duplicate, icon: const Icon(Icons.copy_all_outlined)),
      IconButton(tooltip: 'Delete layer', onPressed: l == null ? null : _delete, icon: const Icon(Icons.delete_outline_rounded)),
      IconButton(tooltip: 'Bring forward', onPressed: l == null ? null : () => _zOrder(MkLayerOps.bringForward), icon: const Icon(Icons.flip_to_front_outlined)),
      IconButton(tooltip: 'Send backward', onPressed: l == null ? null : () => _zOrder(MkLayerOps.sendBackward), icon: const Icon(Icons.flip_to_back_outlined)),
      IconButton(tooltip: 'Bind coupon', onPressed: _bindCoupon, icon: const Icon(Icons.confirmation_number_outlined)),
    ]);

    final canvas = LayoutBuilder(builder: (context, box) {
      final aspect = _t.size.width / _t.size.height;
      var w = box.maxWidth, h = w / aspect;
      if (h > box.maxHeight) {
        h = box.maxHeight;
        w = h * aspect;
      }
      _scale = w / _t.size.width;
      return Center(
        child: SizedBox(
          width: w,
          height: h,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: CustomPaint(
              size: Size(w, h),
              painter: MarketingPreviewPainter(template: _t, values: _values, images: _images, selectedId: _selected, guideV: _guideV, guideH: _guideH, revision: _rev),
            ),
          ),
        ),
      );
    });

    final panel = Column(children: [
      TabBar(controller: _tabs, tabs: const [Tab(text: 'Layer'), Tab(text: 'Layers'), Tab(text: 'Template')]),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          ListView(padding: const EdgeInsets.all(12), children: [
            if (l == null)
              Padding(padding: const EdgeInsets.all(8), child: Text('Tap a layer on the canvas or in Layers to edit it.', style: AppText.caption))
            else
              MkLayerInspector(key: ValueKey('insp-${l.id}'), layer: l, epoch: _epoch, edit: _edit, onPickImage: _pickForSelected),
          ]),
          ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
            MkLayersPanel(t: _t, selectedId: _selected, onSelect: _select, edit: _edit),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('${_t.layers.length} of ${MkLimits.maxLayers} layers. Top of the list is drawn on top.', style: AppText.caption),
            ),
          ]),
          ListView(padding: const EdgeInsets.all(12), children: [
            _templatePanel(),
            MkBackgroundInspector(t: _t, edit: _edit, onPickImage: _pickBackground),
          ]),
        ]),
      ),
    ]);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          setState(() => _dirty = false);
          Navigator.pop(context);
        }
      },
      child: AdminShell(
        title: _t.name.isEmpty ? 'Untitled' : _t.name,
        subtitle: '${_t.size.label} · ${_t.size.width}×${_t.size.height}${_dirty ? ' · not saved' : ''}',
        onBack: () => Navigator.maybePop(context),
        actions: [
          AdminIconAction(icon: _saving ? Icons.hourglass_top_rounded : Icons.save_outlined, label: 'Save', onTap: _saving ? () {} : () => _save()),
          AdminIconAction(icon: _exporting ? Icons.hourglass_top_rounded : Icons.ios_share_rounded, label: 'Export and share', onTap: _openExport),
        ],
        body: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 900;
          final top = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (banner != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: StatusLine(icon: Icons.warning_amber_rounded, text: banner, color: AppTheme.warnText),
              ),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: toolbar),
          ]);
          if (wide) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              top,
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: Padding(padding: const EdgeInsets.all(16), child: canvas)),
                  SizedBox(width: 400, child: DecoratedBox(decoration: BoxDecoration(color: AppTheme.card, border: Border(left: BorderSide(color: AppTheme.border))), child: panel)),
                ]),
              ),
            ]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            top,
            Expanded(flex: 5, child: Padding(padding: const EdgeInsets.all(8), child: canvas)),
            Expanded(flex: 6, child: DecoratedBox(decoration: BoxDecoration(color: AppTheme.card, border: Border(top: BorderSide(color: AppTheme.border))), child: panel)),
          ]);
        }),
      ),
    );
  }

  Widget _templatePanel() {
    final c = _t.coupon;
    final v = _values;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      MkSection('Template', [
        MkTextField(fieldKey: '$_epoch-tpl-name', label: 'Name', value: _t.name, maxLength: MkLimits.nameMax, onChanged: (x) => _edit('tpl.name', () => _t.name = x)),
        MkDropdown<String>(
          label: 'Size',
          value: _t.size.preset,
          items: {for (final p in MkSizePreset.all) p.id: '${p.label} ${p.width}×${p.height}', 'custom': _t.size.preset == 'custom' ? 'Custom ${_t.size.width}×${_t.size.height}' : 'Custom…'},
          onChanged: (id) async {
            final p = MkSizePreset.byId(id);
            if (p != null) {
              _change(() => _t = mkRetarget(_t, MkSize.of(p)));
              return;
            }
            final s = await showDialog<MkSize>(context: context, builder: (_) => _CustomSizeDialog(initial: _t.size));
            if (s != null) _change(() => _t = mkRetarget(_t, s));
          },
        ),
        Text('Changing the size re-lays the layers by their relative positions; check the result.', style: AppText.caption),
      ]),
      MkSection('Coupon', [
        if (c == null)
          Text('No coupon bound. Placeholders show sample values.', style: AppText.body.copyWith(color: AppTheme.text2))
        else ...[
          Text('${c.code} · ${v['discount']} · ${v['plan']}', style: AppText.label.copyWith(color: AppTheme.text)),
          if ((v['validUntil'] ?? '').isNotEmpty) Text('Valid till ${v['validUntil']}', style: AppText.caption),
          if (c.warning != null) StatusLine(icon: Icons.warning_amber_rounded, text: c.warning!, color: AppTheme.warnText),
        ],
        const SizedBox(height: 6),
        OutlinedButton.icon(onPressed: _bindCoupon, icon: const Icon(Icons.confirmation_number_outlined), label: Text(c == null ? 'Bind an active coupon' : 'Change coupon')),
      ]),
      MkSection('Link and caption', [
        MkTextField(
          fieldKey: '$_epoch-tpl-link',
          label: 'Link for {link} and the QR code',
          value: _t.link,
          maxLength: MkLimits.linkMax,
          onChanged: (x) => _edit('tpl.link', () => _t.link = x),
          helper: 'Empty: ${MkPlaceholders.resolveLink('', siteBase: _site, code: c?.code ?? 'CODE')}. {code} is replaced by the coupon code.',
        ),
        MkTextField(
          fieldKey: '$_epoch-tpl-caption',
          label: 'Caption (empty: written for you)',
          value: _t.caption,
          maxLength: MkLimits.captionMax,
          maxLines: 5,
          onChanged: (x) => _edit('tpl.caption', () => _t.caption = x),
        ),
        MkPlaceholderChips(onInsert: (p) => _edit('tpl.caption+', () => _t.caption = (_t.caption + p).length > MkLimits.captionMax ? _t.caption : _t.caption + p, refresh: true)),
      ]),
    ]);
  }
}

/// Active coupons from the gateway; pops an [MkCouponInfo], or 'none' to unbind.
class _CouponPicker extends StatefulWidget {
  final MarketingApi api;
  final String? current;
  const _CouponPicker({required this.api, this.current});

  @override
  State<_CouponPicker> createState() => _CouponPickerState();
}

class _CouponPickerState extends State<_CouponPicker> {
  List<MkCouponInfo>? _coupons;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.coupons().then((c) {
      if (mounted) setState(() => _coupons = c);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = adminErrorOf(e));
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = _coupons;
    if (_error != null) return Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: AppText.body.copyWith(color: AppTheme.sos)));
    if (list == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    return ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 16), children: [
      if (list.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('No active coupons. Create one in Payments > Coupons.', style: AppText.body.copyWith(color: AppTheme.text2))),
      for (final c in list)
        ListTile(
          leading: Icon(Icons.confirmation_number_outlined, color: c.code == widget.current ? AppTheme.brand : AppTheme.text2),
          title: Text('${c.code} · ${c.placeholders?['discount'] ?? MkPlaceholders.discountText(c.discountType, c.discountValue)}', style: AppText.label.copyWith(color: AppTheme.text)),
          subtitle: Text(
            [
              c.placeholders?['plan'] ?? MkPlaceholders.planText(c.plans),
              if (c.expiresAt != null) 'till ${MkPlaceholders.formatDate(c.expiresAt)}',
              if (c.status == 'SCHEDULED') 'starts later',
            ].join(' · '),
            style: AppText.caption,
          ),
          selected: c.code == widget.current,
          onTap: () => Navigator.pop(context, c),
        ),
      if (widget.current != null)
        ListTile(
          leading: Icon(Icons.link_off_rounded, color: AppTheme.text2),
          title: Text('Remove the coupon', style: AppText.label.copyWith(color: AppTheme.text)),
          onTap: () => Navigator.pop(context, 'none'),
        ),
    ]);
  }
}

class _ExportSheet extends StatefulWidget {
  final String caption;
  final String? warning;
  final MkSize size;
  final bool busy;
  final void Function(String caption, bool allSizes) onShare;
  const _ExportSheet({required this.caption, required this.warning, required this.size, required this.busy, required this.onShare});

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  late final TextEditingController _caption = TextEditingController(text: widget.caption);

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      if (widget.warning != null) ...[
        StatusLine(icon: Icons.warning_amber_rounded, text: widget.warning!, color: AppTheme.warnText),
        const SizedBox(height: 10),
      ],
      TextField(
        controller: _caption,
        minLines: 3,
        maxLines: 8,
        inputFormatters: [LengthLimitingTextInputFormatter(MkLimits.captionMax)],
        decoration: const InputDecoration(labelText: 'Caption', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _caption.text));
            if (context.mounted) adminSnack(context, 'Caption copied.');
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy caption'),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: widget.busy ? null : () => widget.onShare(_caption.text, false),
        icon: const Icon(Icons.ios_share_rounded),
        label: Text('Share PNG ${widget.size.width}×${widget.size.height}'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: widget.busy ? null : () => widget.onShare(_caption.text, true),
        icon: const Icon(Icons.collections_outlined),
        label: const Text('Share all sizes (post, story / status, banner)'),
      ),
      const SizedBox(height: 10),
      Text('To keep a copy on this device, pick "Save image" or "Save to Files" in the share sheet.', style: AppText.caption),
    ]);
  }
}

class _CustomSizeDialog extends StatefulWidget {
  final MkSize initial;
  const _CustomSizeDialog({required this.initial});

  @override
  State<_CustomSizeDialog> createState() => _CustomSizeDialogState();
}

class _CustomSizeDialogState extends State<_CustomSizeDialog> {
  late final TextEditingController _w = TextEditingController(text: '${widget.initial.width}');
  late final TextEditingController _h = TextEditingController(text: '${widget.initial.height}');

  @override
  void dispose() {
    _w.dispose();
    _h.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = int.tryParse(_w.text), h = int.tryParse(_h.text);
    bool ok(int? v) => v != null && v >= MkLimits.minSide && v <= MkLimits.maxSide;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: const Text('Custom size'),
      content: Row(children: [
        Expanded(child: TextField(controller: _w, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Width px'), onChanged: (_) => setState(() {}))),
        const SizedBox(width: 12),
        Expanded(child: TextField(controller: _h, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Height px'), onChanged: (_) => setState(() {}))),
      ]),
      actions: [
        Text('${MkLimits.minSide}–${MkLimits.maxSide} px', style: AppText.caption),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: ok(w) && ok(h) ? () => Navigator.pop(context, MkSize.custom(w!, h!)) : null, child: const Text('Use')),
      ],
    );
  }
}
