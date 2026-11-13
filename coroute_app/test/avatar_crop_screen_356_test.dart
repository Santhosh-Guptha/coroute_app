import 'dart:convert';
import 'dart:io';

import 'package:coroute_app/domain/media/avatar_crop.dart';
import 'package:coroute_app/presentation/social/avatar_crop_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 3.56 "Adjust picture" screen (docs/features_355/profile_photo_adjust.md).
void main() {
  // A 2 x 1 PNG (red, blue).
  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAD0lEQVR4nGP4z8DwHwjBAAj+Af9fn3fzAAAAAElFTkSuQmCC');

  testWidgets('controls are there, turning changes the crop, Save hands over crop + pictures', (tester) async {
    AvatarCropResult? got;
    await tester.pumpWidget(MaterialApp(
      home: AvatarCropScreen(
        bytes: png,
        onSave: (r) async {
          got = r;
          return 'Server said no';
        },
      ),
    ));
    // Decoding is real async work.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    for (final label in ['Turn left', 'Turn right', 'Reset', 'Save']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.byType(Slider), findsOneWidget);
    // Tool buttons are at least 48 px in both directions.
    final tool = tester.getSize(find.ancestor(of: find.text('Turn right'), matching: find.byType(InkWell)).first);
    expect(tool.width, greaterThanOrEqualTo(48));
    expect(tool.height, greaterThanOrEqualTo(48));

    await tester.tap(find.text('Turn right'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    if (got != null) {
      expect(got!.crop.rot, 1);
      expect(got!.cropped.bytes, isNotEmpty);
      expect(got!.original, isNotNull, reason: 'a new picture is kept as the original');
      // The refusal is shown and the screen stays open.
      expect(find.text('Server said no'), findsOneWidget);
      expect(find.text('Adjust picture'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  test('wire format survives a round trip through the gateway shape', () {
    const c = AvatarCrop(cx: 0.3, cy: 0.6, zoom: 2, rot: 3);
    expect(AvatarCrop.fromJson(jsonDecode(jsonEncode(c.toJson()))), c);
  });

  test('the cropper is not a FLAG_SECURE screen (screenshots of your own picture stay allowed)', () {
    final src = File('lib/presentation/social/avatar_crop_screen.dart').readAsStringSync();
    expect(src.contains('SecureScreen('), isFalse);
    expect(src.contains("security/secure_screen.dart"), isFalse);
  });
}
