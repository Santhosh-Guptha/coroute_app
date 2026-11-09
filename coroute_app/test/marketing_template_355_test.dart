// 3.55 Marketing studio: pure tests of the template JSON, placeholders, layout scaling, the
// editor history / layer operations and the QR encoder (vectors from the Python qrcode reference).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/marketing/marketing_layout.dart';
import 'package:coroute_app/domain/marketing/marketing_placeholders.dart';
import 'package:coroute_app/domain/marketing/marketing_template.dart';
import 'package:coroute_app/domain/marketing/qr_encoder.dart';
import 'package:coroute_app/domain/marketing/starter_templates.dart';

// Reference matrices: python qrcode 8.x, ERROR_CORRECT_M, byte mode, fixed mask, border 0.
const _qrA = [
  '111111100111001111111',
  '100000101011101000001',
  '101110100010001011101',
  '101110100100001011101',
  '101110101100101011101',
  '100000100010101000001',
  '111111101010101111111',
  '000000000001100000000',
  '101010100011000010010',
  '100111000100001000110',
  '010000101110100010001',
  '101010000110001000100',
  '101001101010101010101',
  '000000001111010101010',
  '111111100001011101111',
  '100000100101110111000',
  '101110101101011101101',
  '101110100000001000110',
  '101110101100100010001',
  '100000100110001000110',
  '111111101000101010111',
];
const _qrLink = [
  '111111100110000010111111001111111',
  '100000100011100110100100001000001',
  '101110101010001010001100001011101',
  '101110101000100100100100001011101',
  '101110101000001111001101101011101',
  '100000101010101001010110101000001',
  '111111101010101010101010101111111',
  '000000001000101010111100000000000',
  '101111100111111001010010001111100',
  '110111010001111011011001001101101',
  '011011100011111111001010011010110',
  '010000011100110011110001010011111',
  '010001100111101010011111010011000',
  '001110011001000100100101100101011',
  '000111101001011111101110111111010',
  '010111000000000100000110011011100',
  '001111111011001101100000110111001',
  '101001000100010000111101001101101',
  '100100100111001110101100110110110',
  '111110011000111010010111101111111',
  '011101100100001100100100010111011',
  '110000011101010111001010000001101',
  '101101111100100001010010000011110',
  '100101010000111010111101111011110',
  '101111101000000001010010111111011',
  '000000001001110011111001100010111',
  '111111100100111101001011101010100',
  '100000101001001001101001100011100',
  '101110101001010110001110111111010',
  '101110101000000101100101010010101',
  '101110101110100111001111001100100',
  '100000100100100100000101110011100',
  '111111101110110111001011110100010',
];

List<String> _rows(QrCode q) => [for (var y = 0; y < q.size; y++) [for (var x = 0; x < q.size; x++) q.isDark(x, y) ? '1' : '0'].join()];

MkCouponInfo _coupon({String type = 'percentage', num value = 40, num? cap = 60, List<String> plans = const ['group_small'], Map<String, String>? server, int? expires}) => MkCouponInfo(
      code: 'FEST40',
      name: 'Festive 40',
      discountType: type,
      discountValue: value,
      maxDiscountCap: cap,
      expiresAt: expires ?? DateTime.utc(2030, 11, 30, 12).millisecondsSinceEpoch,
      plans: plans,
      placeholders: server,
    );

void main() {
  group('template JSON', () {
    test('every starter survives toJson -> fromJson -> toJson unchanged and is valid', () {
      for (final s in MkStarters.all) {
        final t = s.build();
        final a = jsonEncode(t.toJson());
        final b = jsonEncode(MarketingTemplate.fromJson(jsonDecode(a)).toJson());
        expect(b, a, reason: s.id);
        expect(t.validate(), isEmpty, reason: s.id);
        expect(t.layers.length, lessThanOrEqualTo(MkLimits.maxLayers));
        expect(t.toJson()['version'], 1);
      }
      expect(MkStarters.all.length, greaterThanOrEqualTo(4));
    });

    test('colours round-trip as #RRGGBB / #RRGGBBAA', () {
      expect(MkColor.parse('#3ee0ec', 0), 0xFF3EE0EC);
      expect(MkColor.parse('#00000080', 0), 0x80000000);
      expect(MkColor.parse('red', 7), 7);
      expect(MkColor.format(0xFF3EE0EC), '#3EE0EC');
      expect(MkColor.format(0x80000000), '#00000080');
      expect(MkColor.withAlpha(0xFF112233, 0.5), 0x80112233);
    });

    test('reading is lenient: clamps, defaults and unknown types', () {
      final t = MarketingTemplate.fromJson({
        'name': 'x',
        'size': {'preset': 'instagram_story', 'width': 5, 'height': 5},
        'couponCode': 'fest40',
        'layers': [
          {'id': 'a', 'type': 'text', 'x': 9, 'weight': 750, 'color': 'nope', 'shadow': {'blur': 500}},
          {'id': 'b', 'type': 'hologram'},
          {'id': 'c', 'type': 'shape', 'shape': 'burst', 'stroke': '#FFFFFF', 'label': 'NEW'},
        ],
        'coupon': {'code': 'FEST40', 'bindable': false, 'warning': 'This coupon is paused.', 'key': 'INTERNAL'},
      });
      expect(t.size.width, 1080);
      expect(t.size.height, 1920);
      expect(t.couponCode, 'FEST40');
      final a = t.layers[0];
      expect(a.x, 1.5);
      expect(a.weight, 800);
      expect(a.color, MkBrand.white);
      expect(a.shadow!.blur, 100);
      expect(t.layers[1].type, MkLayerType.text);
      expect(t.layers[2].stroke, 0xFFFFFFFF);
      expect(t.coupon!.warning, 'This coupon is paused.');
      expect(t.coupon!.bindable, isFalse);
      // The coupon view is never written back.
      expect(t.toJson().containsKey('coupon'), isFalse);
      expect(jsonEncode(t.toJson()).contains('INTERNAL'), isFalse);
    });

    test('only the fields of a layer type are written', () {
      final qr = MkLayer.newQr('q').toJson();
      expect(qr.containsKey('text'), isFalse);
      expect(qr['data'], '{link}');
      expect(qr['background'], '#FFFFFF');
      final coupon = MkLayer.newCoupon('c').toJson();
      expect(coupon['codeLine'], 'Use code {code}');
      expect(coupon.containsKey('shape'), isFalse);
    });

    test('validate refuses what the gateway refuses', () {
      final t = MkStarters.blank(MkSize.of(MkSizePreset.banner));
      for (var i = 0; i < 40; i++) {
        t.layers.add(MkLayer.newText('t$i'));
      }
      expect(t.validate().join(' '), contains('At most 40 layers'));
      final u = MkStarters.festive()..name = '  ';
      expect(u.validate(), contains('Give the template a name.'));
      final v = MkStarters.festive()..layers.add(MkLayer(id: 'img', type: MkLayerType.image));
      expect(v.validate().join(' '), contains('no image'));
      expect(MkSize.custom(50, 99999).width, MkLimits.minSide);
      expect(MkSize.custom(50, 99999).height, MkLimits.maxSide);
    });
  });

  group('placeholders', () {
    test('substitute known names, keep unknown braces', () {
      final v = {'code': 'FEST40', 'discount': '40% off'};
      expect(MkPlaceholders.substitute('Use {code} for {discount} {nope} {plan}', v), 'Use FEST40 for 40% off {nope} {plan}');
      expect(MkPlaceholders.usedIn('{code} and {link} and {x}'), {'code', 'link'});
    });

    test('values from the coupon match the gateway rules', () {
      final link = MkPlaceholders.resolveLink('', siteBase: 'https://coroute.duckdns.org/', code: 'FEST40');
      expect(link, 'https://coroute.duckdns.org/get?coupon=FEST40');
      final v = MkPlaceholders.forCoupon(_coupon(), link: link);
      expect(v['code'], 'FEST40');
      expect(v['discount'], '40% off');
      expect(v['validUntil'], '30 Nov 2030');
      expect(v['plan'], 'Small Group plan');
      expect(v['cap'], 'up to ₹60');
      expect(v['link'], link);
      expect(MkPlaceholders.forCoupon(_coupon(type: 'fixed', value: 1500, cap: null), link: '')['discount'], '₹1,500 off');
      expect(MkPlaceholders.forCoupon(_coupon(type: 'percentage', value: 100), link: '')['discount'], 'Free');
      expect(MkPlaceholders.forCoupon(_coupon(type: 'free'), link: '')['discount'], 'Free');
      expect(MkPlaceholders.forCoupon(_coupon(plans: ['all']), link: '')['plan'], 'all plans');
      expect(MkPlaceholders.planText(['group_small', 'group_large']), 'Small Group & Large Group plans');
      expect(MkPlaceholders.inr(123456), '₹1,23,456');
      // India time: 20:00 UTC on 31 Dec is already 1 Jan.
      expect(MkPlaceholders.formatDate(DateTime.utc(2026, 12, 31, 20).millisecondsSinceEpoch), '1 Jan 2027');
    });

    test("the gateway's values win; the link is always the template's", () {
      final v = MkPlaceholders.forCoupon(_coupon(server: {'plan': 'Small Group (2–6) plan', 'discount': '55% off'}), link: 'L');
      expect(v['plan'], 'Small Group (2–6) plan');
      expect(v['discount'], '55% off');
      expect(v['link'], 'L');
    });

    test('a template link may carry {code}; codes are URL-encoded', () {
      expect(MkPlaceholders.resolveLink('https://x.test/o?c={code}&s=ig', siteBase: 'https://y', code: 'A B'), 'https://x.test/o?c=A+B&s=ig');
      expect(MkPlaceholders.resolveLink('', siteBase: 'https://y'), 'https://y/get');
    });

    test('unbound templates show samples; the binding switches to real values', () {
      final t = MkStarters.festive();
      expect(MkPlaceholders.templateNeedsCoupon(t), isTrue);
      expect(MkPlaceholders.valuesFor(t, siteBase: 'https://s')['code'], MkPlaceholders.sample['code']);
      t
        ..couponCode = 'FEST40'
        ..coupon = _coupon();
      final v = MkPlaceholders.valuesFor(t, siteBase: 'https://s');
      expect(v['code'], 'FEST40');
      expect(v['link'], 'https://s/get?coupon=FEST40');
      final noCoupon = MarketingTemplate(name: 'logo only', layers: [MkLayer.newLogo('l'), MkLayer.newText('t', text: 'Ride with us')]);
      expect(MkPlaceholders.templateNeedsCoupon(noCoupon), isFalse);
    });

    test('auto caption carries the code, the offer and the link', () {
      final c = MkPlaceholders.autoCaption(MkPlaceholders.forCoupon(_coupon(), link: 'https://s/get?coupon=FEST40'));
      expect(c, contains('FEST40'));
      expect(c, contains('40% off (up to ₹60)'));
      expect(c, contains('https://s/get?coupon=FEST40'));
      expect(c, contains('30 Nov 2030'));
    });

    test('expiry by the clock', () {
      final past = _coupon(expires: 1000);
      expect(past.isExpiredAt(2000), isTrue);
      expect(_coupon().isExpiredAt(DateTime.utc(2026).millisecondsSinceEpoch), isFalse);
    });
  });

  group('layout', () {
    test('unit scale follows the short side', () {
      expect(mkUnitScale(1080, 1080), 1.0);
      expect(mkUnitScale(1080, 1920), 1.0);
      expect(mkUnitScale(1200, 628), closeTo(628 / 1080, 1e-9));
    });

    test('retarget keeps centres, aspect of logos / QR, width of text; input untouched', () {
      final t = MkStarters.festive();
      final before = jsonEncode(t.toJson());
      final banner = mkRetarget(t, MkSize.of(MkSizePreset.banner));
      expect(jsonEncode(t.toJson()), before);
      expect(banner.size.width, 1200);
      final q0 = t.layerById('qr')!, q1 = banner.layerById('qr')!;
      final px0 = q0.w * 1080 / (q0.h * 1080), px1 = q1.w * 1200 / (q1.h * 628);
      expect(px1, closeTo(px0, 1e-3), reason: 'QR stays square');
      const k = 628 / 1080;
      expect(q1.w * 1200, closeTo(q0.w * 1080 * k, 1e-3));
      final title0 = t.layerById('title')!, title1 = banner.layerById('title')!;
      expect(title1.w, title0.w);
      expect(title1.x, title0.x);
      for (final l in banner.layers) {
        if (l.w <= 1) expect(l.x - l.w / 2, greaterThanOrEqualTo(-1e-9), reason: l.id);
        if (l.h <= 1) expect(l.y + l.h / 2, lessThanOrEqualTo(1 + 1e-9), reason: l.id);
      }
      // Story: the same unit scale, so pixel sizes of aspect layers stay.
      final story = mkRetarget(t, MkSize.of(MkSizePreset.instagramStory));
      expect(story.layerById('qr')!.w * 1080, closeTo(q0.w * 1080, 1e-3));
      expect(story.layerById('qr')!.h * 1920, closeTo(q0.h * 1080, 1e-3));
    });

    test('hit test honours rotation and z-order', () {
      final t = MarketingTemplate(name: 'x', layers: [
        MkLayer(id: 'under', type: MkLayerType.shape, x: 0.5, y: 0.5, w: 0.5, h: 0.5),
        MkLayer(id: 'bar', type: MkLayerType.shape, x: 0.5, y: 0.5, w: 0.8, h: 0.05, rotation: 90),
      ]);
      // On the rotated bar (vertical now): the bar wins.
      expect(t.layers[mkHitTest(t, 540, 300)].id, 'bar');
      // Left of the bar but inside the square: the square.
      expect(t.layers[mkHitTest(t, 400, 540)].id, 'under');
      // Where the bar would be without rotation, outside the square: nothing.
      expect(mkHitTest(t, 100, 540), -1);
      t.layers[1].hidden = true;
      expect(t.layers[mkHitTest(t, 540, 300)].id, 'under');
    });

    test('snap to the centre guides and to 45 degree steps', () {
      final s = mkSnapCentre(0.505, 0.3, 1080, 1080, thresholdPx: 12);
      expect(s.x, 0.5);
      expect(s.vertical, isTrue);
      expect(s.horizontal, isFalse);
      expect(s.y, 0.3);
      expect(mkSnapRotation(43), 45);
      expect(mkSnapRotation(30), 30);
      expect(mkSnapRotation(358), 0);
      expect(mkSnapRotation(-92), -90);
    });

    test('undo / redo history', () {
      final h = MkHistory();
      var t = MkStarters.referral()..id = 'mt_1';
      h.record(t);
      t.name = 'Changed';
      h.record(t);
      t.layers.removeLast();
      expect(h.canUndo, isTrue);
      t = h.undo(t)!;
      expect(t.layers.length, MkStarters.referral().layers.length);
      expect(t.id, 'mt_1');
      t = h.undo(t)!;
      expect(t.name, 'Referral');
      expect(h.canUndo, isFalse);
      t = h.redo(t)!;
      expect(t.name, 'Changed');
      h.record(t);
      expect(h.canRedo, isFalse, reason: 'a new change clears redo');
    });

    test('z-order and duplicate', () {
      final t = MarketingTemplate(name: 'z', layers: [MkLayer.newText('a'), MkLayer.newText('b'), MkLayer.newText('c')]);
      MkLayerOps.toFront(t, 0);
      expect(t.layers.map((l) => l.id).join(), 'bca');
      MkLayerOps.toBack(t, 2);
      expect(t.layers.map((l) => l.id).join(), 'abc');
      MkLayerOps.bringForward(t, 0);
      expect(t.layers.map((l) => l.id).join(), 'bac');
      MkLayerOps.sendBackward(t, 2);
      expect(t.layers.map((l) => l.id).join(), 'bca');
      final d = MkLayerOps.duplicate(t, 0)!;
      expect(t.layers[1].id, d.id);
      expect(d.id, isNot('b'));
      expect(d.x, closeTo(t.layers[0].x + 0.03, 1e-9));
      while (t.layers.length < MkLimits.maxLayers) {
        t.layers.add(MkLayer.newText(t.nextLayerId('f')));
      }
      expect(MkLayerOps.duplicate(t, 0), isNull);
    });
  });

  group('QR encoder', () {
    test('matches the reference encoder module for module', () {
      final a = QrCode.encode('A', forceMask: 0);
      expect(a.version, 1);
      expect(_rows(a), _qrA);
      final link = QrCode.encode('https://coroute.duckdns.org/get?coupon=FEST40', forceMask: 2);
      expect(link.version, 4);
      expect(_rows(link), _qrLink);
    });

    test('picks the smallest version and refuses too much data', () {
      expect(QrCode.encode('x' * 14).version, 1);
      expect(QrCode.encode('x' * 15).version, 2);
      expect(QrCode.encode('x' * 213).version, 10);
      var threw = false;
      try {
        QrCode.encode('x' * 214);
      } on QrTooLongException {
        threw = true;
      }
      expect(threw, isTrue);
      final auto = QrCode.encode('https://coroute.duckdns.org/get?coupon=FEST40');
      expect(auto.mask, inInclusiveRange(0, 7));
      expect(auto.size, 33);
    });
  });
}
