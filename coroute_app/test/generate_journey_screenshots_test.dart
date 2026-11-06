import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/membership_service.dart';
import 'package:coroute_app/presentation/subscription/membership_payment_screen.dart';
import 'package:coroute_app/presentation/subscription/payment_success_screen.dart';
import 'package:coroute_app/presentation/trip_planner/trip_review_sheet.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super();

  @override
  Future<dynamic> get(String path, {Duration timeout = const Duration(seconds: 10)}) async {
    if (path == '/membership/catalog') {
      return {
        'categories': {
          'individual': {'id': 'individual', 'name': 'Individual Membership', 'monthlyPriceInr': 9, 'capacity': 1},
          'group_small': {'id': 'group_small', 'name': 'Group Membership (2–6)', 'monthlyPriceInr': 49, 'capacity': 6},
        },
        'paymentsEnabled': true,
      };
    }
    if (path == '/membership/my') {
      return {
        'owned': null,
        'participating': [],
        'paymentsEnabled': true,
      };
    }
    return {};
  }

  @override
  Future<dynamic> post(String path, [Object? body, Duration timeout = const Duration(seconds: 12), bool auth = true]) async {
    if (path == '/membership/order') {
      return {
        'orderId': 'order_test_123',
        'keyId': 'rzp_test_dummy',
        'amountInPaise': 0,
        'isFree': true,
      };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('razorpay_flutter'), (call) async {
      return null;
    });
  });

  const outDir = r'C:\Users\santhosh\.gemini\antigravity\brain\1d66d0a6-c14d-4560-964a-508989130e9e';

  const testCategory = MembershipCategory(
    id: 'individual',
    name: 'Individual Membership',
    priceRupees: 9,
    capacity: 1,
  );

  final testMembership = UserMembership(
    membershipId: 'mem_12345',
    ownerUserId: 'user_tester',
    category: 'individual',
    categoryName: 'Individual Membership',
    capacity: 1,
    priceRupees: 9,
    status: 'ACTIVE',
    validUntil: DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
  );

  Future<void> saveScreenshot(GlobalKey key, String filename) async {
    final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();
    final file = File('$outDir\\$filename');
    await file.writeAsBytes(bytes);
    // ignore: avoid_print
    print('Saved screenshot: ${file.path} (${bytes.length} bytes)');
  }

  Widget wrapWithTheme(Widget child, {GlobalKey? key}) {
    AppTheme.use(AppPalette.dark);
    final api = _FakeApiClient();
    return RepaintBoundary(
      key: key,
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<MembershipService>(create: (_) => MembershipService(api)),
          ChangeNotifierProvider<AuthService>(create: (_) => AuthService(api)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeFor(AppPalette.dark),
          home: Scaffold(
            backgroundColor: const Color(0xFF0F172A),
            body: child,
          ),
        ),
      ),
    );
  }

  testWidgets('Generate Stage 2: Redesigned CoRoute Payment Screen Screenshot', (tester) async {
    tester.view.physicalSize = const Size(824, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final repaintKey = GlobalKey();

    await tester.pumpWidget(wrapWithTheme(
      const MembershipPaymentScreen(
        category: testCategory,
        isTripCreationFlow: true,
      ),
      key: repaintKey,
    ));
    await tester.pumpAndSettle();

    await tester.binding.runAsync(() async {
      await saveScreenshot(repaintKey, 'stage2_membership_payment_screen.png');
    });
  });

  testWidgets('Generate Stage 3: Payment Success Screen Screenshot', (tester) async {
    tester.view.physicalSize = const Size(824, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final repaintKey = GlobalKey();

    await tester.pumpWidget(wrapWithTheme(
      PaymentSuccessScreen(
        membership: testMembership,
        transactionReference: 'pay_test_9887766554',
        amountPaidInRupees: 0,
        isTripCreationFlow: true,
      ),
      key: repaintKey,
    ));
    await tester.pumpAndSettle();

    await tester.binding.runAsync(() async {
      await saveScreenshot(repaintKey, 'stage3_payment_success_screen.png');
    });
  });

  testWidgets('Generate Stage 4: Restored Trip Review Screen Screenshot', (tester) async {
    tester.view.physicalSize = const Size(824, 1800);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final repaintKey = GlobalKey();

    await tester.pumpWidget(wrapWithTheme(
      Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () {
              TripReviewSheet.show(
                context,
                name: 'Bengaluru Monsoon Expedition',
                startName: 'Indiranagar Metro Station',
                destinationName: 'Nandi Hills Sunrise Viewpoint',
                route: RouteModel(distanceM: 62000, durationS: 5400, polyline: ''),
                stops: 2,
                speedLimitKmh: 60,
                membershipActivated: true,
                confirmLabel: 'Confirm and Create Trip',
              );
            },
            child: const Text('Open Review'),
          ),
        ),
      ),
      key: repaintKey,
    ));

    await tester.tap(find.text('Open Review'));
    await tester.pumpAndSettle();

    await tester.binding.runAsync(() async {
      await saveScreenshot(repaintKey, 'stage4_restored_trip_review_screen.png');
    });
  });
}
