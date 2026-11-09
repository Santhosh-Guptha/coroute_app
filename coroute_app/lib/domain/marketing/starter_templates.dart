// 3.55 Marketing studio: brand-safe starter templates. Each one is an ordinary template (the admin
// edits a copy); text uses {placeholders} so a bound coupon fills it in.

import 'marketing_template.dart';

class MkStarter {
  final String id;
  final String title;
  final String description;
  final MarketingTemplate Function() build;
  const MkStarter(this.id, this.title, this.description, this.build);
}

class MkStarters {
  static final List<MkStarter> all = [
    MkStarter('festive', 'Festive offer', 'Instagram post with a coupon ticket and a LIMITED badge.', festive),
    MkStarter('group_plan', 'Group ride plan discount', 'Plan discount for ride groups, on the road pattern.', groupPlan),
    MkStarter('first_ride', 'First ride free', 'Story / status with a big headline and a QR code.', firstRideFree),
    MkStarter('referral', 'Referral', 'Light post: bring your riding crew.', referral),
    MkStarter('flash_sale', 'Weekend flash sale', 'Wide banner with a ribbon and the code.', flashSale),
  ];

  static MarketingTemplate blank(MkSize size) => MarketingTemplate(
        name: 'Untitled offer',
        size: size,
        background: MkBackground(kind: 'gradient', colors: [MkBrand.ink, MkBrand.deepTeal], pattern: 'topo', patternOpacity: 0.1),
        layers: [
          MkLayer.newText('title', text: 'Your headline here', y: 0.3),
          MkLayer.newCoupon('coupon'),
          MkLayer.newLogo('logo'),
        ],
      );

  static MarketingTemplate festive() => MarketingTemplate(
        name: 'Festive offer',
        size: MkSize.of(MkSizePreset.instagramPost),
        background: MkBackground(kind: 'gradient', colors: [MkBrand.plum, 0xFFB4233C, MkBrand.festive], angle: 120, pattern: 'rings', patternColor: MkBrand.amber, patternOpacity: 0.16),
        layers: [
          MkLayer(id: 'kicker', type: MkLayerType.text, text: 'Festive season', uppercase: true, letterSpacing: 10, size: 38, weight: 700, color: MkBrand.amber, x: 0.42, y: 0.1, w: 0.7, h: 0.06, align: 'left'),
          MkLayer(
            id: 'title',
            type: MkLayerType.text,
            text: 'Ride together,\nsave more',
            size: 104,
            weight: 800,
            color: MkBrand.white,
            align: 'left',
            lineHeight: 1.05,
            x: 0.42,
            y: 0.27,
            w: 0.76,
            h: 0.24,
            shadow: MkShadow(color: 0x66000000, blur: 20, dy: 6),
          ),
          MkLayer.newShape('badge', 'burst', label: 'LIMITED')
            ..x = 0.84
            ..y = 0.16
            ..w = 0.24
            ..h = 0.24
            ..rotation = 12
            ..labelSize = 40,
          MkLayer(id: 'coupon', type: MkLayerType.coupon, style: 'ticket', x: 0.5, y: 0.62, w: 0.84, h: 0.3, fill: MkBrand.white, textColor: MkBrand.ink, accent: MkBrand.festive),
          MkLayer.newLogo('logo')
            ..x = 0.27
            ..y = 0.91
            ..w = 0.38
            ..h = 0.07,
          MkLayer.newQr('qr')
            ..x = 0.88
            ..y = 0.89
            ..w = 0.15
            ..h = 0.15,
        ],
      );

  static MarketingTemplate groupPlan() => MarketingTemplate(
        name: 'Group ride plan discount',
        size: MkSize.of(MkSizePreset.instagramPost),
        background: MkBackground(kind: 'gradient', colors: [MkBrand.ink, MkBrand.deepTeal], angle: 90, pattern: 'road', patternColor: MkBrand.teal, patternOpacity: 0.16),
        layers: [
          MkLayer(id: 'kicker', type: MkLayerType.text, text: 'Group rides', uppercase: true, letterSpacing: 12, size: 36, weight: 700, color: MkBrand.teal, x: 0.5, y: 0.1, w: 0.8, h: 0.06),
          MkLayer(id: 'title', type: MkLayerType.text, text: '{discount} for your\nwhole ride group', size: 96, weight: 800, color: MkBrand.white, x: 0.5, y: 0.25, w: 0.88, h: 0.2, lineHeight: 1.05),
          MkLayer(id: 'sub', type: MkLayerType.text, text: 'On the {plan}: live tracking, intercom and SOS for everyone.', size: 38, weight: 500, color: MkBrand.paper, x: 0.5, y: 0.4, w: 0.8, h: 0.09),
          MkLayer(id: 'coupon', type: MkLayerType.coupon, style: 'card', x: 0.5, y: 0.64, w: 0.78, h: 0.27, fill: MkBrand.paper, textColor: MkBrand.ink, accent: MkBrand.teal),
          MkLayer.newShape('new', 'pill', label: 'NEW')
            ..x = 0.84
            ..y = 0.5
            ..w = 0.17
            ..h = 0.065
            ..fill = MkBrand.amber
            ..labelSize = 34
            ..rotation = -8,
          MkLayer.newLogo('logo')
            ..x = 0.5
            ..y = 0.91
            ..w = 0.36
            ..h = 0.065,
        ],
      );

  static MarketingTemplate firstRideFree() => MarketingTemplate(
        name: 'First ride free',
        size: MkSize.of(MkSizePreset.instagramStory),
        background: MkBackground(kind: 'solid', color: MkBrand.ink, pattern: 'topo', patternColor: MkBrand.teal, patternOpacity: 0.12),
        layers: [
          MkLayer.newLogo('logo')
            ..x = 0.5
            ..y = 0.07
            ..w = 0.42
            ..h = 0.045,
          MkLayer(
            id: 'title',
            type: MkLayerType.text,
            text: 'First ride\nfree',
            size: 170,
            weight: 800,
            color: MkBrand.white,
            x: 0.5,
            y: 0.27,
            w: 0.9,
            h: 0.2,
            lineHeight: 1.0,
            shadow: MkShadow(color: 0x803EE0EC, blur: 40, dy: 0),
          ),
          MkLayer(id: 'sub', type: MkLayerType.text, text: 'Plan your group ride, track everyone live, talk on the go.', size: 44, weight: 500, color: MkBrand.paper, x: 0.5, y: 0.42, w: 0.8, h: 0.08),
          MkLayer(id: 'coupon', type: MkLayerType.coupon, style: 'pill', x: 0.5, y: 0.56, w: 0.84, h: 0.11, fill: MkBrand.teal, textColor: MkBrand.ink, accent: MkBrand.ink, headline: '{discount}', codeLine: 'Use code {code}', footer: 'Till {validUntil}'),
          MkLayer.newQr('qr')
            ..x = 0.5
            ..y = 0.76
            ..w = 0.3
            ..h = 0.169,
          MkLayer(id: 'scan', type: MkLayerType.text, text: 'Scan to get the app', size: 40, weight: 700, color: MkBrand.teal, x: 0.5, y: 0.88, w: 0.7, h: 0.035),
        ],
      );

  static MarketingTemplate referral() => MarketingTemplate(
        name: 'Referral',
        size: MkSize.of(MkSizePreset.instagramPost),
        background: MkBackground(kind: 'solid', color: MkBrand.paper, pattern: 'dots', patternColor: MkBrand.ink, patternOpacity: 0.07),
        layers: [
          MkLayer.newShape('blob', 'circle')
            ..x = 0.9
            ..y = 0.08
            ..w = 0.5
            ..h = 0.5
            ..fill = 0x333EE0EC,
          MkLayer(id: 'title', type: MkLayerType.text, text: 'Bring your\nriding crew', size: 100, weight: 800, color: MkBrand.ink, align: 'left', x: 0.45, y: 0.23, w: 0.8, h: 0.24, lineHeight: 1.05),
          MkLayer(id: 'sub', type: MkLayerType.text, text: 'Share code {code}: your friends get {discount} on CoRoute.', size: 40, weight: 600, color: MkBrand.night, align: 'left', x: 0.45, y: 0.41, w: 0.8, h: 0.09),
          MkLayer(id: 'coupon', type: MkLayerType.coupon, style: 'stamp', x: 0.5, y: 0.66, w: 0.8, h: 0.27, fill: MkBrand.ink, textColor: MkBrand.paper, accent: MkBrand.teal),
          MkLayer.newLogo('logo')
            ..x = 0.27
            ..y = 0.91
            ..w = 0.36
            ..h = 0.065
            ..color = MkBrand.ink,
        ],
      );

  static MarketingTemplate flashSale() => MarketingTemplate(
        name: 'Weekend flash sale',
        size: MkSize.of(MkSizePreset.banner),
        background: MkBackground(kind: 'gradient', colors: [MkBrand.coral, MkBrand.amber], angle: 0, pattern: 'stripes', patternColor: MkBrand.white, patternOpacity: 0.12),
        layers: [
          MkLayer.newShape('ribbon', 'ribbon', label: 'FLASH SALE')
            ..x = 0.24
            ..y = 0.17
            ..w = 0.38
            ..h = 0.15
            ..fill = MkBrand.ink
            ..labelColor = MkBrand.amber
            ..labelSize = 44,
          MkLayer(id: 'title', type: MkLayerType.text, text: '{discount}\nthis weekend', size: 92, weight: 800, color: MkBrand.ink, align: 'left', x: 0.3, y: 0.5, w: 0.52, h: 0.42, lineHeight: 1.0),
          MkLayer(id: 'coupon', type: MkLayerType.coupon, style: 'ticket', x: 0.76, y: 0.47, w: 0.4, h: 0.56, fill: MkBrand.white, textColor: MkBrand.ink, accent: MkBrand.coral),
          MkLayer.newLogo('logo')
            ..x = 0.17
            ..y = 0.87
            ..w = 0.26
            ..h = 0.1
            ..color = MkBrand.ink,
        ],
      );
}
