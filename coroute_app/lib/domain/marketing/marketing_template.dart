// 3.55 Marketing studio: the template JSON (schema version 1), shared by the editor, the painter
// and the gateway (gateway/src/marketing_templates.js validates the same shape and limits).
//
// Pure Dart (no Flutter imports) so the model, placeholders and layout maths are unit tested and
// can be dumped to JSON by a plain `dart run` script.
//
// Geometry is relative: [MkLayer.x] / [MkLayer.y] are the layer centre as a fraction of the canvas,
// [MkLayer.w] / [MkLayer.h] fractions of the canvas width / height. Lengths (font size, stroke,
// radius, shadow, letter spacing) are "units": 1 unit = 1 px on a canvas whose short side is
// 1080 px (see marketing_layout.dart), so one template renders at any size.
//
// Colours are ARGB ints in memory and '#RRGGBB' / '#RRGGBBAA' strings in JSON.

import 'dart:convert';

/// Server-side limits (the gateway refuses more; the editor stops earlier).
class MkLimits {
  static const int maxLayers = 40;
  static const int maxImageLayers = 10;
  static const int nameMax = 80;
  static const int layerNameMax = 40;
  static const int textMax = 500;
  static const int couponLineMax = 160;
  static const int shapeLabelMax = 40;
  static const int captionMax = 1000;
  static const int linkMax = 300;
  static const int minSide = 200;
  static const int maxSide = 4096;
}

/// Colour helpers: '#RRGGBB' / '#RRGGBBAA' <-> ARGB int.
class MkColor {
  static final RegExp _re = RegExp(r'^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$');

  static bool isValid(Object? s) => s is String && _re.hasMatch(s);

  /// ARGB int of [s], or [fallback] when it is not a colour string.
  static int parse(Object? s, int fallback) {
    if (s is! String) return fallback;
    final m = _re.firstMatch(s);
    if (m == null) return fallback;
    final rgb = int.parse(m.group(1)!, radix: 16);
    final a = m.group(2) == null ? 0xFF : int.parse(m.group(2)!, radix: 16);
    return (a << 24) | rgb;
  }

  /// '#RRGGBB' when opaque, otherwise '#RRGGBBAA' (upper case, like the gateway stores it).
  static String format(int argb) {
    final a = (argb >> 24) & 0xFF;
    final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
    return a == 0xFF ? '#$rgb' : '#$rgb${a.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }

  static int withAlpha(int argb, double opacity) => ((opacity.clamp(0.0, 1.0) * 255).round() << 24) | (argb & 0xFFFFFF);
}

/// The CoRoute brand palette (from the app icon): the editor's swatches and the starter templates.
class MkBrand {
  static const int ink = 0xFF0B0F14;
  static const int night = 0xFF141B24;
  static const int teal = 0xFF3EE0EC;
  static const int deepTeal = 0xFF0E5C63;
  static const int amber = 0xFFFFB347;
  static const int paper = 0xFFECF1F6;
  static const int white = 0xFFFFFFFF;
  static const int coral = 0xFFFF6B5A;
  static const int festive = 0xFFFF8A00;
  static const int plum = 0xFF3B1E54;
  static const List<int> swatches = [ink, night, deepTeal, teal, amber, festive, coral, plum, paper, white, 0xFF22C55E, 0xFF000000];
}

/// A canvas size preset.
class MkSizePreset {
  final String id;
  final String label;
  final int width;
  final int height;
  const MkSizePreset(this.id, this.label, this.width, this.height);

  static const instagramPost = MkSizePreset('instagram_post', 'Instagram post', 1080, 1080);
  static const instagramStory = MkSizePreset('instagram_story', 'Instagram story', 1080, 1920);
  static const whatsappStatus = MkSizePreset('whatsapp_status', 'WhatsApp status', 1080, 1920);
  static const banner = MkSizePreset('banner', 'Banner', 1200, 628);
  static const List<MkSizePreset> all = [instagramPost, instagramStory, whatsappStatus, banner];

  static MkSizePreset? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}

class MkSize {
  final String preset;
  final int width;
  final int height;
  const MkSize(this.preset, this.width, this.height);

  factory MkSize.of(MkSizePreset p) => MkSize(p.id, p.width, p.height);

  /// A custom size, clamped to the server's limits.
  factory MkSize.custom(int width, int height) =>
      MkSize('custom', width.clamp(MkLimits.minSide, MkLimits.maxSide), height.clamp(MkLimits.minSide, MkLimits.maxSide));

  factory MkSize.fromJson(Object? raw) {
    final m = raw is Map ? raw : const {};
    final preset = m['preset']?.toString() ?? 'instagram_post';
    final p = MkSizePreset.byId(preset);
    if (p != null) return MkSize.of(p);
    return MkSize.custom(_int(m['width'], 1080), _int(m['height'], 1080));
  }

  String get label => MkSizePreset.byId(preset)?.label ?? 'Custom $width×$height';
  Map<String, dynamic> toJson() => {'preset': preset, 'width': width, 'height': height};
}

class MkShadow {
  int color;
  double blur;
  double dx;
  double dy;
  MkShadow({this.color = 0x99000000, this.blur = 16, this.dx = 0, this.dy = 6});

  static MkShadow? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return MkShadow(
      color: MkColor.parse(raw['color'], 0x80000000),
      blur: _dbl(raw['blur'], 12, 0, 100),
      dx: _dbl(raw['dx'], 0, -100, 100),
      dy: _dbl(raw['dy'], 4, -100, 100),
    );
  }

  Map<String, dynamic> toJson() => {'color': MkColor.format(color), 'blur': blur, 'dx': dx, 'dy': dy};
}

/// Background kinds and built-in patterns (drawn in code, no image assets).
class MkBackground {
  static const kinds = ['solid', 'gradient', 'image'];
  static const patterns = ['none', 'topo', 'road', 'dots', 'stripes', 'rings', 'chevrons'];

  String kind;
  int color;
  List<int> colors;

  /// Gradient direction in degrees: 0 = left to right, 90 = top to bottom.
  double angle;
  String? imageId;
  String imageFit;
  String pattern;
  int patternColor;
  double patternOpacity;

  /// A tint drawn over everything in the background (e.g. darken a photo), or null.
  int? overlay;

  MkBackground({
    this.kind = 'solid',
    this.color = MkBrand.ink,
    List<int>? colors,
    this.angle = 135,
    this.imageId,
    this.imageFit = 'cover',
    this.pattern = 'none',
    this.patternColor = MkBrand.teal,
    this.patternOpacity = 0.12,
    this.overlay,
  }) : colors = colors ?? [MkBrand.ink, MkBrand.deepTeal];

  factory MkBackground.fromJson(Object? raw) {
    final m = raw is Map ? raw : const {};
    final cs = m['colors'] is List ? (m['colors'] as List).map((c) => MkColor.parse(c, MkBrand.ink)).toList() : <int>[];
    return MkBackground(
      kind: _oneOf(m['kind'], kinds, 'solid'),
      color: MkColor.parse(m['color'], MkBrand.ink),
      colors: cs.length >= 2 ? cs.take(4).toList() : null,
      angle: _dbl(m['angle'], 135, 0, 360),
      imageId: m['imageId'] is String && (m['imageId'] as String).isNotEmpty ? m['imageId'] as String : null,
      imageFit: _oneOf(m['imageFit'], const ['cover', 'contain'], 'cover'),
      pattern: _oneOf(m['pattern'], patterns, 'none'),
      patternColor: MkColor.parse(m['patternColor'], MkBrand.teal),
      patternOpacity: _dbl(m['patternOpacity'], 0.12, 0, 1),
      overlay: MkColor.isValid(m['overlay']) ? MkColor.parse(m['overlay'], 0) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'color': MkColor.format(color),
        if (kind == 'gradient') 'colors': colors.map(MkColor.format).toList(),
        'angle': angle,
        if (kind == 'image' && imageId != null) 'imageId': imageId,
        'imageFit': imageFit,
        'pattern': pattern,
        'patternColor': MkColor.format(patternColor),
        'patternOpacity': patternOpacity,
        if (overlay != null) 'overlay': MkColor.format(overlay!),
      };
}

enum MkLayerType {
  text('Text'),
  coupon('Coupon'),
  logo('Logo'),
  shape('Shape'),
  image('Image'),
  qr('QR code');

  const MkLayerType(this.label);
  final String label;

  static MkLayerType? byName(Object? s) {
    for (final t in values) {
      if (t.name == s) return t;
    }
    return null;
  }
}

/// One layer. A single mutable class for every type (the editor edits fields in place and keeps
/// undo snapshots as JSON); fields that do not belong to [type] are ignored and not written.
class MkLayer {
  static const fonts = ['Manrope', 'sans', 'serif', 'monospace'];
  static const shapes = ['rect', 'pill', 'circle', 'ribbon', 'star', 'burst'];
  static const couponStyles = ['ticket', 'pill', 'card', 'stamp'];
  static const aligns = ['left', 'center', 'right'];

  String id;
  MkLayerType type;
  String name;
  double x, y, w, h;
  double rotation;
  double opacity;
  bool hidden;
  bool locked;

  // text
  String text;
  String font;
  double size;
  int weight;
  int color;
  String align;
  double letterSpacing;
  double lineHeight;
  MkShadow? shadow;
  bool uppercase;
  bool italic;
  String textFit;

  // coupon
  String style;
  int fill;
  int textColor;
  int accent;
  String headline;
  String codeLine;
  String footer;

  // logo
  String variant;

  // shape
  String shape;
  int? stroke;
  double strokeWidth;
  double radius;
  String label;
  int labelColor;
  double labelSize;

  // image
  String? imageId;
  String imageFit;

  // qr
  String data;
  int bgColor;

  MkLayer({
    required this.id,
    required this.type,
    this.name = '',
    this.x = 0.5,
    this.y = 0.5,
    this.w = 0.5,
    this.h = 0.2,
    this.rotation = 0,
    this.opacity = 1,
    this.hidden = false,
    this.locked = false,
    this.text = '',
    this.font = 'Manrope',
    this.size = 64,
    this.weight = 700,
    this.color = MkBrand.white,
    this.align = 'center',
    this.letterSpacing = 0,
    this.lineHeight = 1.15,
    this.shadow,
    this.uppercase = false,
    this.italic = false,
    this.textFit = 'shrink',
    this.style = 'ticket',
    this.fill = MkBrand.white,
    this.textColor = MkBrand.ink,
    this.accent = MkBrand.amber,
    this.headline = '{discount}',
    this.codeLine = 'Use code {code}',
    this.footer = 'Valid till {validUntil} · {plan}',
    this.variant = 'wordmark',
    this.shape = 'rect',
    this.stroke,
    this.strokeWidth = 0,
    this.radius = 24,
    this.label = '',
    this.labelColor = MkBrand.ink,
    this.labelSize = 40,
    this.imageId,
    this.imageFit = 'cover',
    this.data = '{link}',
    this.bgColor = MkBrand.white,
  });

  // ---- defaults per type (brand-safe) ----
  factory MkLayer.newText(String id, {String text = 'Your headline', double y = 0.3}) =>
      MkLayer(id: id, type: MkLayerType.text, text: text, x: 0.5, y: y, w: 0.84, h: 0.14, size: 88, weight: 800, color: MkBrand.white);

  factory MkLayer.newCoupon(String id) =>
      MkLayer(id: id, type: MkLayerType.coupon, x: 0.5, y: 0.62, w: 0.8, h: 0.28, weight: 800, fill: MkBrand.white, textColor: MkBrand.ink, accent: MkBrand.amber);

  factory MkLayer.newLogo(String id) => MkLayer(id: id, type: MkLayerType.logo, x: 0.5, y: 0.92, w: 0.34, h: 0.07, color: MkBrand.paper);

  factory MkLayer.newShape(String id, String shape, {String label = ''}) {
    final round = shape == 'circle' || shape == 'star' || shape == 'burst';
    return MkLayer(
      id: id,
      type: MkLayerType.shape,
      shape: shape,
      label: label,
      x: round ? 0.82 : 0.5,
      y: round ? 0.14 : 0.5,
      w: round ? 0.24 : (shape == 'ribbon' ? 0.6 : 0.5),
      h: round ? 0.24 : (shape == 'ribbon' ? 0.09 : 0.12),
      fill: MkBrand.amber,
      labelColor: MkBrand.ink,
      labelSize: round ? 46 : 40,
      weight: 800,
      radius: shape == 'rect' ? 24 : 0,
    );
  }

  factory MkLayer.newImage(String id, String imageId) => MkLayer(id: id, type: MkLayerType.image, imageId: imageId, x: 0.5, y: 0.45, w: 0.6, h: 0.4, radius: 24);

  factory MkLayer.newQr(String id) => MkLayer(id: id, type: MkLayerType.qr, x: 0.86, y: 0.86, w: 0.18, h: 0.18, color: MkBrand.ink, bgColor: MkBrand.white);

  /// Layers whose pixel aspect ratio is kept when the canvas size changes (see retarget).
  bool get keepsAspect => switch (type) {
        MkLayerType.logo || MkLayerType.qr || MkLayerType.image => true,
        MkLayerType.shape => shape == 'circle' || shape == 'star' || shape == 'burst',
        _ => false,
      };

  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    switch (type) {
      case MkLayerType.text:
        final t = text.replaceAll('\n', ' ').trim();
        return t.isEmpty ? 'Text' : (t.length > 24 ? '${t.substring(0, 24)}…' : t);
      case MkLayerType.shape:
        return label.isNotEmpty ? '$label ($shape)' : 'Shape: $shape';
      default:
        return type.label;
    }
  }

  factory MkLayer.fromJson(Object? raw) {
    final m = raw is Map ? raw : const {};
    final type = MkLayerType.byName(m['type']) ?? MkLayerType.text;
    final l = MkLayer(
      id: (m['id']?.toString() ?? '').isEmpty ? 'l${DateTime.now().microsecondsSinceEpoch}' : m['id'].toString(),
      type: type,
      name: _str(m['name'], '', MkLimits.layerNameMax),
      x: _dbl(m['x'], 0.5, -0.5, 1.5),
      y: _dbl(m['y'], 0.5, -0.5, 1.5),
      w: _dbl(m['w'], 0.5, 0.005, 3),
      h: _dbl(m['h'], 0.2, 0.005, 3),
      rotation: _dbl(m['rotation'], 0, -360, 360),
      opacity: _dbl(m['opacity'], 1, 0, 1),
      hidden: m['hidden'] == true,
      locked: m['locked'] == true,
    );
    switch (type) {
      case MkLayerType.text:
        l
          ..text = _str(m['text'], '', MkLimits.textMax)
          ..font = _oneOf(m['font'], fonts, 'Manrope')
          ..size = _dbl(m['size'], 64, 4, 600)
          ..weight = _weight(m['weight'], 700)
          ..color = MkColor.parse(m['color'], MkBrand.white)
          ..align = _oneOf(m['align'], aligns, 'center')
          ..letterSpacing = _dbl(m['letterSpacing'], 0, -20, 100)
          ..lineHeight = _dbl(m['lineHeight'], 1.15, 0.7, 3)
          ..shadow = MkShadow.fromJson(m['shadow'])
          ..uppercase = m['uppercase'] == true
          ..italic = m['italic'] == true
          ..textFit = _oneOf(m['fit'], const ['none', 'shrink'], 'shrink');
      case MkLayerType.coupon:
        l
          ..style = _oneOf(m['style'], couponStyles, 'ticket')
          ..fill = MkColor.parse(m['fill'], MkBrand.white)
          ..textColor = MkColor.parse(m['textColor'], MkBrand.ink)
          ..accent = MkColor.parse(m['accent'], MkBrand.amber)
          ..font = _oneOf(m['font'], fonts, 'Manrope')
          ..headline = _str(m['headline'], '{discount}', MkLimits.couponLineMax)
          ..codeLine = _str(m['codeLine'], 'Use code {code}', MkLimits.couponLineMax)
          ..footer = _str(m['footer'], 'Valid till {validUntil} · {plan}', MkLimits.couponLineMax);
      case MkLayerType.logo:
        l
          ..variant = _oneOf(m['variant'], const ['mark', 'wordmark'], 'wordmark')
          ..color = MkColor.parse(m['color'], MkBrand.paper);
      case MkLayerType.shape:
        l
          ..shape = _oneOf(m['shape'], shapes, 'rect')
          ..fill = MkColor.parse(m['fill'], MkBrand.amber)
          ..stroke = MkColor.isValid(m['stroke']) ? MkColor.parse(m['stroke'], 0) : null
          ..strokeWidth = _dbl(m['strokeWidth'], 0, 0, 60)
          ..radius = _dbl(m['radius'], 24, 0, 500)
          ..label = _str(m['label'], '', MkLimits.shapeLabelMax)
          ..labelColor = MkColor.parse(m['labelColor'], MkBrand.ink)
          ..labelSize = _dbl(m['labelSize'], 40, 4, 300)
          ..font = _oneOf(m['font'], fonts, 'Manrope')
          ..weight = _weight(m['weight'], 800);
      case MkLayerType.image:
        l
          ..imageId = m['imageId'] is String ? m['imageId'] as String : null
          ..imageFit = _oneOf(m['fit'], const ['cover', 'contain'], 'cover')
          ..radius = _dbl(m['radius'], 0, 0, 500);
      case MkLayerType.qr:
        l
          ..data = _str(m['data'], '{link}', MkLimits.linkMax)
          ..color = MkColor.parse(m['color'], MkBrand.ink)
          ..bgColor = MkColor.parse(m['background'], MkBrand.white);
    }
    return l;
  }

  Map<String, dynamic> toJson() {
    final base = <String, dynamic>{
      'id': id,
      'type': type.name,
      if (name.isNotEmpty) 'name': name,
      'x': _r(x),
      'y': _r(y),
      'w': _r(w),
      'h': _r(h),
      'rotation': _r(rotation),
      'opacity': _r(opacity),
      'hidden': hidden,
      'locked': locked,
    };
    switch (type) {
      case MkLayerType.text:
        base.addAll({
          'text': text,
          'font': font,
          'size': _r(size),
          'weight': weight,
          'color': MkColor.format(color),
          'align': align,
          'letterSpacing': _r(letterSpacing),
          'lineHeight': _r(lineHeight),
          'shadow': shadow?.toJson(),
          'uppercase': uppercase,
          'italic': italic,
          'fit': textFit,
        });
      case MkLayerType.coupon:
        base.addAll({
          'style': style,
          'fill': MkColor.format(fill),
          'textColor': MkColor.format(textColor),
          'accent': MkColor.format(accent),
          'font': font,
          'headline': headline,
          'codeLine': codeLine,
          'footer': footer,
        });
      case MkLayerType.logo:
        base.addAll({'variant': variant, 'color': MkColor.format(color)});
      case MkLayerType.shape:
        base.addAll({
          'shape': shape,
          'fill': MkColor.format(fill),
          'stroke': stroke == null ? null : MkColor.format(stroke!),
          'strokeWidth': _r(strokeWidth),
          'radius': _r(radius),
          'label': label,
          'labelColor': MkColor.format(labelColor),
          'labelSize': _r(labelSize),
          'font': font,
          'weight': weight,
        });
      case MkLayerType.image:
        base.addAll({'imageId': imageId, 'fit': imageFit, 'radius': _r(radius)});
      case MkLayerType.qr:
        base.addAll({'data': data, 'color': MkColor.format(color), 'background': MkColor.format(bgColor)});
    }
    return base;
  }

  MkLayer copy() => MkLayer.fromJson(jsonDecode(jsonEncode(toJson())));
}

/// The public part of a coupon as the gateway sends it with a template (never an internal id).
class MkCouponInfo {
  final String code;
  final String name;
  final String discountType;
  final num discountValue;
  final num? maxDiscountCap;
  final int? validFrom;
  final int? expiresAt;
  final String status;
  final bool bindable;
  final bool missing;
  final String? warning;
  final List<String> plans;

  /// Values computed by the gateway ({code, discount, validUntil, plan, name, cap}), when sent.
  final Map<String, String>? placeholders;

  const MkCouponInfo({
    required this.code,
    this.name = '',
    this.discountType = 'percentage',
    this.discountValue = 0,
    this.maxDiscountCap,
    this.validFrom,
    this.expiresAt,
    this.status = 'ACTIVE',
    this.bindable = true,
    this.missing = false,
    this.warning,
    this.plans = const ['all'],
    this.placeholders,
  });

  static MkCouponInfo? fromJson(Object? raw) {
    if (raw is! Map || (raw['code']?.toString() ?? '').isEmpty) return null;
    final ph = raw['placeholders'];
    return MkCouponInfo(
      code: raw['code'].toString(),
      name: raw['name']?.toString() ?? '',
      discountType: raw['discountType']?.toString() ?? 'percentage',
      discountValue: raw['discountValue'] is num ? raw['discountValue'] as num : 0,
      maxDiscountCap: raw['maxDiscountCap'] is num ? raw['maxDiscountCap'] as num : null,
      validFrom: raw['validFrom'] is num ? (raw['validFrom'] as num).toInt() : null,
      expiresAt: raw['expiresAt'] is num ? (raw['expiresAt'] as num).toInt() : null,
      status: raw['status']?.toString() ?? 'ACTIVE',
      bindable: raw['bindable'] != false,
      missing: raw['missing'] == true,
      warning: (raw['warning']?.toString() ?? '').isEmpty ? null : raw['warning'].toString(),
      plans: raw['plans'] is List ? (raw['plans'] as List).map((e) => e.toString()).toList() : const ['all'],
      placeholders: ph is Map ? {for (final e in ph.entries) e.key.toString(): e.value?.toString() ?? ''} : null,
    );
  }

  /// Expired by the clock even if the server's view is older than that.
  bool isExpiredAt(int nowMs) => status == 'EXPIRED' || (expiresAt != null && expiresAt! < nowMs);
}

class MarketingTemplate {
  static const int schemaVersion = 1;

  String? id;
  String name;
  String status;
  MkSize size;
  MkBackground background;
  String? couponCode;

  /// Link template for {link} and the QR code ('' = the default download link); may hold {code}.
  String link;
  String caption;
  List<MkLayer> layers;
  int? updatedAt;
  String? updatedBy;

  /// The live coupon view from the gateway (not saved with the template).
  MkCouponInfo? coupon;

  MarketingTemplate({
    this.id,
    required this.name,
    this.status = 'active',
    this.size = const MkSize('instagram_post', 1080, 1080),
    MkBackground? background,
    this.couponCode,
    this.link = '',
    this.caption = '',
    List<MkLayer>? layers,
    this.updatedAt,
    this.updatedBy,
    this.coupon,
  })  : background = background ?? MkBackground(),
        layers = layers ?? <MkLayer>[];

  factory MarketingTemplate.fromJson(Object? raw) {
    final m = raw is Map ? raw : const {};
    final code = m['couponCode']?.toString() ?? '';
    return MarketingTemplate(
      id: (m['id']?.toString() ?? '').isEmpty ? null : m['id'].toString(),
      name: _str(m['name'], 'Untitled', MkLimits.nameMax),
      status: _oneOf(m['status'], const ['active', 'archived'], 'active'),
      size: MkSize.fromJson(m['size']),
      background: MkBackground.fromJson(m['background']),
      couponCode: code.isEmpty ? null : code.toUpperCase(),
      link: _str(m['link'], '', MkLimits.linkMax),
      caption: _str(m['caption'], '', MkLimits.captionMax),
      layers: (m['layers'] is List ? m['layers'] as List : const []).take(MkLimits.maxLayers).map(MkLayer.fromJson).toList(),
      updatedAt: m['updatedAt'] is num ? (m['updatedAt'] as num).toInt() : null,
      updatedBy: m['updatedBy']?.toString(),
      coupon: MkCouponInfo.fromJson(m['coupon']),
    );
  }

  /// What the gateway stores (no id, timestamps or coupon view).
  Map<String, dynamic> toJson() => {
        'version': schemaVersion,
        'name': name,
        'status': status,
        'size': size.toJson(),
        'background': background.toJson(),
        'couponCode': couponCode,
        'link': link,
        'caption': caption,
        'layers': layers.map((l) => l.toJson()).toList(),
      };

  /// A deep copy (keeps id, coupon view and timestamps).
  MarketingTemplate copy() {
    final t = MarketingTemplate.fromJson(jsonDecode(jsonEncode(toJson())));
    t
      ..id = id
      ..coupon = coupon
      ..updatedAt = updatedAt
      ..updatedBy = updatedBy;
    return t;
  }

  MkLayer? layerById(String? id) {
    if (id == null) return null;
    for (final l in layers) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// A layer id not used yet ("text3").
  String nextLayerId(String prefix) {
    var n = layers.length + 1;
    while (layers.any((l) => l.id == '$prefix$n')) {
      n++;
    }
    return '$prefix$n';
  }

  /// Every uploaded image the template needs.
  Set<String> get imageIds => {
        if (background.kind == 'image' && background.imageId != null) background.imageId!,
        for (final l in layers)
          if (l.type == MkLayerType.image && l.imageId != null) l.imageId!,
      };

  /// Problems the gateway would refuse, checked before saving (empty = fine).
  List<String> validate() {
    final out = <String>[];
    if (name.trim().isEmpty) out.add('Give the template a name.');
    if (name.length > MkLimits.nameMax) out.add('The name is longer than ${MkLimits.nameMax} characters.');
    if (layers.length > MkLimits.maxLayers) out.add('At most ${MkLimits.maxLayers} layers.');
    if (layers.where((l) => l.type == MkLayerType.image).length > MkLimits.maxImageLayers) out.add('At most ${MkLimits.maxImageLayers} image layers.');
    if (caption.length > MkLimits.captionMax) out.add('The caption is longer than ${MkLimits.captionMax} characters.');
    if (background.kind == 'image' && background.imageId == null) out.add('Pick a background image or another background.');
    final ids = <String>{};
    for (final l in layers) {
      if (!ids.add(l.id)) out.add('Two layers share the id ${l.id}.');
      if (l.type == MkLayerType.text && l.text.length > MkLimits.textMax) out.add('A text layer is longer than ${MkLimits.textMax} characters.');
      if (l.type == MkLayerType.image && l.imageId == null) out.add('An image layer has no image.');
    }
    return out;
  }
}

// ---------------------------------------------------------------- lenient readers
double _r(double v) => (v * 10000).roundToDouble() / 10000;

int _int(Object? v, int def) => v is num && v.isFinite ? v.toInt() : def;

double _dbl(Object? v, double def, double min, double max) {
  if (v is! num || !v.isFinite) return def;
  return v.toDouble().clamp(min, max);
}

int _weight(Object? v, int def) {
  if (v is! num) return def;
  final w = (v.toDouble() / 100).round() * 100;
  return w.clamp(100, 900);
}

String _str(Object? v, String def, int max) {
  if (v is! String) return def;
  return v.length > max ? v.substring(0, max) : v;
}

String _oneOf(Object? v, List<String> list, String def) => v is String && list.contains(v) ? v : def;
