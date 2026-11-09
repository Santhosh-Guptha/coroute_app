import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../domain/marketing/marketing_placeholders.dart';
import '../../../domain/marketing/marketing_template.dart';
import '../admin_ui.dart';

/// Applies one edit. Edits with the same [key] in a row are one undo step (a slider drag, typing in
/// one field). [refresh] rebuilds text fields (when the change did not come from typing).
typedef MkEdit = void Function(String key, VoidCallback change, {bool refresh});

// ------------------------------------------------------------------ small controls
class MkSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const MkSection(this.title, this.children, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title.toUpperCase(), style: AppText.overline.copyWith(color: AppTheme.muted)),
          const SizedBox(height: 6),
          ...children,
        ]),
      );
}

class MkTextField extends StatelessWidget {
  final String fieldKey;
  final String label;
  final String value;
  final int maxLength;
  final int maxLines;
  final ValueChanged<String> onChanged;
  final String? helper;
  const MkTextField({super.key, required this.fieldKey, required this.label, required this.value, required this.maxLength, required this.onChanged, this.maxLines = 1, this.helper});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextFormField(
          key: ValueKey(fieldKey),
          initialValue: value,
          maxLines: maxLines,
          minLines: 1,
          inputFormatters: [LengthLimitingTextInputFormatter(maxLength)],
          style: AppText.body.copyWith(color: AppTheme.text),
          decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 3, isDense: true, border: const OutlineInputBorder()),
          onChanged: onChanged,
        ),
      );
}

class MkSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String Function(double)? format;
  const MkSlider({super.key, required this.label, required this.value, required this.min, required this.max, required this.onChanged, this.format});

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(min, max);
    return Row(children: [
      SizedBox(width: 92, child: Text(label, style: AppText.caption.copyWith(color: AppTheme.text2))),
      Expanded(child: Slider(value: v, min: min, max: max, onChanged: onChanged)),
      SizedBox(width: 48, child: Text(format?.call(v) ?? v.toStringAsFixed(0), textAlign: TextAlign.right, style: AppText.caption.copyWith(color: AppTheme.text))),
    ]);
  }
}

class MkDropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  const MkDropdown({super.key, required this.label, required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          SizedBox(width: 92, child: Text(label, style: AppText.caption.copyWith(color: AppTheme.text2))),
          Expanded(
            child: DropdownButton<T>(
              isExpanded: true,
              value: items.containsKey(value) ? value : items.keys.first,
              items: [for (final e in items.entries) DropdownMenuItem<T>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ]),
      );
}

class MkSwitch extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const MkSwitch({super.key, required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: AppText.body.copyWith(color: AppTheme.text)),
        value: value,
        onChanged: onChanged,
      );
}

/// Brand swatches + a custom colour (hex and opacity).
class MkColorField extends StatelessWidget {
  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool allowNone;
  const MkColorField({super.key, required this.label, required this.value, required this.onChanged, this.allowNone = false});

  @override
  Widget build(BuildContext context) {
    Widget dot(int? c, {bool selected = false}) => GestureDetector(
          onTap: () => onChanged(c),
          child: Container(
            width: 26,
            height: 26,
            margin: const EdgeInsets.only(right: 6, bottom: 6),
            decoration: BoxDecoration(
              color: c == null ? Colors.transparent : Color(c),
              shape: BoxShape.circle,
              border: Border.all(color: selected ? AppTheme.brand : AppTheme.border2, width: selected ? 3 : 1),
            ),
            child: c == null ? Icon(Icons.block, size: 16, color: AppTheme.muted) : null,
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.caption.copyWith(color: AppTheme.text2)),
        const SizedBox(height: 4),
        Wrap(children: [
          if (allowNone) dot(null, selected: value == null),
          for (final c in MkBrand.swatches) dot(c, selected: value != null && (value! & 0xFFFFFF) == (c & 0xFFFFFF) && (value! >> 24) == (c >> 24)),
          GestureDetector(
            onTap: () async {
              final picked = await showDialog<int>(context: context, builder: (_) => _CustomColorDialog(initial: value ?? MkBrand.white));
              if (picked != null) onChanged(picked);
            },
            child: Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), border: Border.all(color: AppTheme.border2)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (value != null) Container(width: 14, height: 14, decoration: BoxDecoration(color: Color(value!), shape: BoxShape.circle)),
                const SizedBox(width: 4),
                Text(value == null ? 'None' : MkColor.format(value!), style: AppText.caption.copyWith(color: AppTheme.text)),
              ]),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _CustomColorDialog extends StatefulWidget {
  final int initial;
  const _CustomColorDialog({required this.initial});

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  late final TextEditingController _hex = TextEditingController(text: MkColor.format(widget.initial | 0xFF000000));
  late double _alpha = ((widget.initial >> 24) & 0xFF) / 255;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  int? get _value {
    final t = _hex.text.trim().startsWith('#') ? _hex.text.trim() : '#${_hex.text.trim()}';
    if (!MkColor.isValid(t) || t.length != 7) return null;
    return MkColor.withAlpha(MkColor.parse(t, 0), _alpha);
  }

  @override
  Widget build(BuildContext context) {
    final v = _value;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: const Text('Custom colour'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: _hex,
          decoration: const InputDecoration(labelText: 'Hex (#RRGGBB)', border: OutlineInputBorder()),
          inputFormatters: [LengthLimitingTextInputFormatter(7)],
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        MkSlider(label: 'Opacity', value: _alpha * 100, min: 0, max: 100, onChanged: (x) => setState(() => _alpha = x / 100), format: (x) => '${x.round()}%'),
        const SizedBox(height: 8),
        Container(height: 36, decoration: BoxDecoration(color: v == null ? Colors.transparent : Color(v), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border2))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: v == null ? null : () => Navigator.pop(context, v), child: const Text('Use')),
      ],
    );
  }
}

/// Tap to add a placeholder to the field.
class MkPlaceholderChips extends StatelessWidget {
  final ValueChanged<String> onInsert;
  const MkPlaceholderChips({super.key, required this.onInsert});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final p in MkPlaceholders.names)
            ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text('{$p}', style: AppText.caption.copyWith(color: AppTheme.text)),
              onPressed: () => onInsert('{$p}'),
            ),
        ]),
      );
}

const Map<String, String> _fontNames = {'Manrope': 'Manrope (brand)', 'sans': 'System sans', 'serif': 'Serif', 'monospace': 'Monospace'};
const Map<int, String> _weights = {300: 'Light', 400: 'Regular', 500: 'Medium', 600: 'Semibold', 700: 'Bold', 800: 'Extra bold'};

// ------------------------------------------------------------------ layer properties
class MkLayerInspector extends StatelessWidget {
  final MkLayer layer;
  final int epoch;
  final MkEdit edit;
  final VoidCallback onPickImage;
  const MkLayerInspector({super.key, required this.layer, required this.epoch, required this.edit, required this.onPickImage});

  String _k(String f) => '$epoch-${layer.id}-$f';

  @override
  Widget build(BuildContext context) {
    final l = layer;
    void set(String f, VoidCallback fn, {bool refresh = false}) => edit('${l.id}.$f', fn, refresh: refresh);
    final children = <Widget>[
      MkSection('Layer', [
        MkTextField(fieldKey: _k('name'), label: 'Name (only in the editor)', value: l.name, maxLength: MkLimits.layerNameMax, onChanged: (v) => set('name', () => l.name = v)),
        MkSlider(label: 'Rotation', value: l.rotation, min: -180, max: 180, onChanged: (v) => set('rotation', () => l.rotation = v), format: (v) => '${v.round()}°'),
        MkSlider(label: 'Opacity', value: l.opacity * 100, min: 0, max: 100, onChanged: (v) => set('opacity', () => l.opacity = v / 100), format: (v) => '${v.round()}%'),
        MkSlider(label: 'Width', value: l.w * 100, min: 1, max: 150, onChanged: (v) => set('w', () => l.w = v / 100), format: (v) => '${v.round()}%'),
        MkSlider(label: 'Height', value: l.h * 100, min: 1, max: 150, onChanged: (v) => set('h', () => l.h = v / 100), format: (v) => '${v.round()}%'),
        Row(children: [
          Expanded(child: MkSwitch(label: 'Hidden', value: l.hidden, onChanged: (v) => set('hidden', () => l.hidden = v))),
          const SizedBox(width: 8),
          Expanded(child: MkSwitch(label: 'Locked', value: l.locked, onChanged: (v) => set('locked', () => l.locked = v))),
        ]),
        Wrap(spacing: 6, children: [
          OutlinedButton(onPressed: () => set('centreX', () => l.x = 0.5), child: const Text('Centre across')),
          OutlinedButton(onPressed: () => set('centreY', () => l.y = 0.5), child: const Text('Centre down')),
        ]),
      ]),
    ];
    switch (l.type) {
      case MkLayerType.text:
        children.add(MkSection('Text', [
          MkTextField(fieldKey: _k('text'), label: 'Text', value: l.text, maxLength: MkLimits.textMax, maxLines: 4, onChanged: (v) => set('text', () => l.text = v)),
          MkPlaceholderChips(onInsert: (p) => set('text+', () => l.text = (l.text + p).length > MkLimits.textMax ? l.text : l.text + p, refresh: true)),
          MkDropdown<String>(label: 'Font', value: l.font, items: _fontNames, onChanged: (v) => set('font', () => l.font = v)),
          MkDropdown<int>(label: 'Weight', value: l.weight, items: {..._weights, if (!_weights.containsKey(l.weight)) l.weight: '${l.weight}'}, onChanged: (v) => set('weight', () => l.weight = v)),
          MkSlider(label: 'Size', value: l.size, min: 8, max: 300, onChanged: (v) => set('size', () => l.size = v)),
          MkSlider(label: 'Spacing', value: l.letterSpacing, min: -10, max: 40, onChanged: (v) => set('ls', () => l.letterSpacing = v)),
          MkSlider(label: 'Line height', value: l.lineHeight, min: 0.7, max: 2.5, onChanged: (v) => set('lh', () => l.lineHeight = v), format: (v) => v.toStringAsFixed(2)),
          MkDropdown<String>(label: 'Align', value: l.align, items: const {'left': 'Left', 'center': 'Centre', 'right': 'Right'}, onChanged: (v) => set('align', () => l.align = v)),
          MkColorField(label: 'Colour', value: l.color, onChanged: (v) => set('color', () => l.color = v ?? MkBrand.white)),
          MkSwitch(label: 'Upper case', value: l.uppercase, onChanged: (v) => set('upper', () => l.uppercase = v)),
          MkSwitch(label: 'Italic', value: l.italic, onChanged: (v) => set('italic', () => l.italic = v)),
          MkSwitch(label: 'Shrink to fit the box', value: l.textFit == 'shrink', onChanged: (v) => set('fit', () => l.textFit = v ? 'shrink' : 'none')),
          MkSwitch(label: 'Shadow', value: l.shadow != null, onChanged: (v) => set('shadow', () => l.shadow = v ? MkShadow() : null)),
          if (l.shadow != null) ...[
            MkSlider(label: 'Blur', value: l.shadow!.blur, min: 0, max: 60, onChanged: (v) => set('sblur', () => l.shadow!.blur = v)),
            MkSlider(label: 'Offset', value: l.shadow!.dy, min: -40, max: 40, onChanged: (v) => set('sdy', () => l.shadow!.dy = v)),
            MkColorField(label: 'Shadow colour', value: l.shadow!.color, onChanged: (v) => set('scolor', () => l.shadow!.color = v ?? 0x99000000)),
          ],
        ]));
      case MkLayerType.coupon:
        children.add(MkSection('Coupon block', [
          MkDropdown<String>(label: 'Style', value: l.style, items: const {'ticket': 'Ticket', 'pill': 'Pill (one row)', 'card': 'Card', 'stamp': 'Stamp'}, onChanged: (v) => set('style', () => l.style = v)),
          MkTextField(fieldKey: _k('headline'), label: 'Headline', value: l.headline, maxLength: MkLimits.couponLineMax, onChanged: (v) => set('headline', () => l.headline = v)),
          MkTextField(fieldKey: _k('codeLine'), label: 'Code line', value: l.codeLine, maxLength: MkLimits.couponLineMax, onChanged: (v) => set('codeLine', () => l.codeLine = v)),
          MkTextField(
            fieldKey: _k('footer'),
            label: 'Footer',
            value: l.footer,
            maxLength: MkLimits.couponLineMax,
            onChanged: (v) => set('footer', () => l.footer = v),
            helper: 'Placeholders: {discount} {code} {validUntil} {plan} {cap} {name}. They fill in from the bound coupon.',
          ),
          MkDropdown<String>(label: 'Font', value: l.font, items: _fontNames, onChanged: (v) => set('font', () => l.font = v)),
          MkColorField(label: 'Fill', value: l.fill, onChanged: (v) => set('fill', () => l.fill = v ?? MkBrand.white)),
          MkColorField(label: 'Text', value: l.textColor, onChanged: (v) => set('textColor', () => l.textColor = v ?? MkBrand.ink)),
          MkColorField(label: 'Accent', value: l.accent, onChanged: (v) => set('accent', () => l.accent = v ?? MkBrand.amber)),
        ]));
      case MkLayerType.logo:
        children.add(MkSection('Logo', [
          MkDropdown<String>(label: 'Variant', value: l.variant, items: const {'wordmark': 'Mark + CoRoute', 'mark': 'Mark only'}, onChanged: (v) => set('variant', () => l.variant = v)),
          if (l.variant == 'wordmark') MkColorField(label: 'Word colour', value: l.color, onChanged: (v) => set('color', () => l.color = v ?? MkBrand.paper)),
        ]));
      case MkLayerType.shape:
        children.add(MkSection('Shape / badge', [
          MkDropdown<String>(
            label: 'Shape',
            value: l.shape,
            items: const {'rect': 'Rectangle', 'pill': 'Pill', 'circle': 'Circle', 'ribbon': 'Ribbon', 'star': 'Star', 'burst': 'Burst badge'},
            onChanged: (v) => set('shape', () => l.shape = v),
          ),
          MkTextField(fieldKey: _k('label'), label: 'Label (e.g. LIMITED, NEW)', value: l.label, maxLength: MkLimits.shapeLabelMax, onChanged: (v) => set('label', () => l.label = v)),
          MkColorField(label: 'Fill', value: l.fill, onChanged: (v) => set('fill', () => l.fill = v ?? MkBrand.amber)),
          MkColorField(label: 'Label colour', value: l.labelColor, onChanged: (v) => set('labelColor', () => l.labelColor = v ?? MkBrand.ink)),
          MkSlider(label: 'Label size', value: l.labelSize, min: 8, max: 200, onChanged: (v) => set('labelSize', () => l.labelSize = v)),
          if (l.shape == 'rect') MkSlider(label: 'Corners', value: l.radius, min: 0, max: 200, onChanged: (v) => set('radius', () => l.radius = v)),
          MkColorField(label: 'Outline', value: l.stroke, allowNone: true, onChanged: (v) => set('stroke', () => l.stroke = v)),
          if (l.stroke != null) MkSlider(label: 'Outline width', value: l.strokeWidth, min: 0, max: 40, onChanged: (v) => set('strokeWidth', () => l.strokeWidth = v)),
        ]));
      case MkLayerType.image:
        children.add(MkSection('Image', [
          MkDropdown<String>(label: 'Fit', value: l.imageFit, items: const {'cover': 'Fill the box', 'contain': 'Show all'}, onChanged: (v) => set('fit', () => l.imageFit = v)),
          MkSlider(label: 'Corners', value: l.radius, min: 0, max: 300, onChanged: (v) => set('radius', () => l.radius = v)),
          OutlinedButton.icon(onPressed: onPickImage, icon: const Icon(Icons.image_outlined), label: const Text('Replace image')),
        ]));
      case MkLayerType.qr:
        children.add(MkSection('QR code', [
          MkTextField(
            fieldKey: _k('data'),
            label: 'QR content',
            value: l.data,
            maxLength: MkLimits.linkMax,
            onChanged: (v) => set('data', () => l.data = v),
            helper: '{link} is the template link (the app download link with the coupon code by default).',
          ),
          MkColorField(label: 'Modules', value: l.color, onChanged: (v) => set('color', () => l.color = v ?? MkBrand.ink)),
          MkColorField(label: 'Background', value: l.bgColor, onChanged: (v) => set('bg', () => l.bgColor = v ?? MkBrand.white)),
          StatusLine(icon: Icons.info_outline_rounded, text: 'Keep strong contrast (dark on light) so phones can scan it.', color: AppTheme.text2),
        ]));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

// ------------------------------------------------------------------ background
class MkBackgroundInspector extends StatelessWidget {
  final MarketingTemplate t;
  final MkEdit edit;
  final VoidCallback onPickImage;
  const MkBackgroundInspector({super.key, required this.t, required this.edit, required this.onPickImage});

  @override
  Widget build(BuildContext context) {
    final b = t.background;
    void set(String f, VoidCallback fn) => edit('bg.$f', fn);
    return MkSection('Background', [
      MkDropdown<String>(label: 'Kind', value: b.kind, items: const {'solid': 'Solid colour', 'gradient': 'Gradient', 'image': 'Uploaded image'}, onChanged: (v) {
        if (v == 'image' && b.imageId == null) {
          onPickImage();
          return;
        }
        set('kind', () => b.kind = v);
      }),
      if (b.kind != 'gradient') MkColorField(label: b.kind == 'image' ? 'Colour behind the image' : 'Colour', value: b.color, onChanged: (v) => set('color', () => b.color = v ?? MkBrand.ink)),
      if (b.kind == 'gradient') ...[
        for (var i = 0; i < b.colors.length; i++)
          MkColorField(label: 'Colour ${i + 1}', value: b.colors[i], onChanged: (v) => set('c$i', () => b.colors[i] = v ?? MkBrand.ink)),
        Wrap(spacing: 6, children: [
          if (b.colors.length < 4) OutlinedButton(onPressed: () => set('cadd', () => b.colors.add(MkBrand.amber)), child: const Text('Add colour')),
          if (b.colors.length > 2) OutlinedButton(onPressed: () => set('cdel', () => b.colors.removeLast()), child: const Text('Remove last')),
        ]),
        MkSlider(label: 'Direction', value: b.angle, min: 0, max: 360, onChanged: (v) => set('angle', () => b.angle = v), format: (v) => '${v.round()}°'),
      ],
      if (b.kind == 'image') ...[
        MkDropdown<String>(label: 'Fit', value: b.imageFit, items: const {'cover': 'Fill', 'contain': 'Show all'}, onChanged: (v) => set('fit', () => b.imageFit = v)),
        OutlinedButton.icon(onPressed: onPickImage, icon: const Icon(Icons.image_outlined), label: const Text('Replace image')),
      ],
      MkDropdown<String>(
        label: 'Pattern',
        value: b.pattern,
        items: const {'none': 'None', 'topo': 'Contour lines', 'road': 'Road', 'dots': 'Dots', 'stripes': 'Stripes', 'rings': 'Rings', 'chevrons': 'Chevrons'},
        onChanged: (v) => set('pattern', () => b.pattern = v),
      ),
      if (b.pattern != 'none') ...[
        MkColorField(label: 'Pattern colour', value: b.patternColor, onChanged: (v) => set('pcolor', () => b.patternColor = v ?? MkBrand.teal)),
        MkSlider(label: 'Strength', value: b.patternOpacity * 100, min: 0, max: 60, onChanged: (v) => set('popacity', () => b.patternOpacity = v / 100), format: (v) => '${v.round()}%'),
      ],
      MkColorField(label: 'Tint over the background', value: b.overlay, allowNone: true, onChanged: (v) => set('overlay', () => b.overlay = v)),
    ]);
  }
}

// ------------------------------------------------------------------ layers list
class MkLayersPanel extends StatelessWidget {
  final MarketingTemplate t;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final MkEdit edit;
  const MkLayersPanel({super.key, required this.t, required this.selectedId, required this.onSelect, required this.edit});

  static IconData iconOf(MkLayer l) => switch (l.type) {
        MkLayerType.text => Icons.title_rounded,
        MkLayerType.coupon => Icons.confirmation_number_outlined,
        MkLayerType.logo => Icons.hub_outlined,
        MkLayerType.shape => Icons.category_outlined,
        MkLayerType.image => Icons.image_outlined,
        MkLayerType.qr => Icons.qr_code_2_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final n = t.layers.length;
    if (n == 0) return Padding(padding: const EdgeInsets.all(16), child: Text('No layers yet. Use Add.', style: AppText.caption));
    // Shown top-most first; the list in the template is bottom-most first.
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: n,
      onReorder: (from, to) {
        if (to > from) to -= 1;
        final fromIdx = n - 1 - from;
        final toIdx = n - 1 - to;
        edit('reorder', () {
          final l = t.layers.removeAt(fromIdx);
          t.layers.insert(toIdx, l);
        });
      },
      itemBuilder: (context, i) {
        final l = t.layers[n - 1 - i];
        final selected = l.id == selectedId;
        return Material(
          key: ValueKey(l.id),
          color: selected ? AppTheme.tint : Colors.transparent,
          child: ListTile(
            dense: true,
            leading: Icon(iconOf(l), color: l.hidden ? AppTheme.muted : AppTheme.text),
            title: Text(l.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(color: l.hidden ? AppTheme.muted : AppTheme.text)),
            onTap: () => onSelect(l.id),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: l.hidden ? 'Show' : 'Hide',
                icon: Icon(l.hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                onPressed: () => edit('${l.id}.hidden', () => l.hidden = !l.hidden),
              ),
              IconButton(
                tooltip: l.locked ? 'Unlock' : 'Lock',
                icon: Icon(l.locked ? Icons.lock_outline_rounded : Icons.lock_open_rounded, size: 20),
                onPressed: () => edit('${l.id}.locked', () => l.locked = !l.locked),
              ),
              ReorderableDragStartListener(index: i, child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_indicator_rounded, size: 20))),
            ]),
          ),
        );
      },
    );
  }
}
