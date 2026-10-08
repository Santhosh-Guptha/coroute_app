import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/outbox_item.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/ride/assist_banner.dart';
import 'package:coroute_app/presentation/ride/assist_sheet.dart';
import 'package:coroute_app/presentation/ride/hazard_marker.dart';
import 'package:coroute_app/presentation/ride/navigate_to.dart';

/// ConvoyService with assistance requests and recorded answers (no socket).
class _Convoys extends ConvoyService {
  _Convoys(ApiClient api) : super(api, RealtimeService(), TripStorageService(api));

  List<AssistRequest> requests = [];
  AssistRequest? accepted;
  List<AssistNotice> notices = [];
  final List<(String, AssistAnswer)> answers = [];
  final List<String> falseReports = [];

  @override
  ConvoyModel? get activeConvoy => ConvoyModel.fromJson({
        'groupId': 'G1',
        'name': 'Hill run',
        'joinCode': '123456',
        'createdByUserId': 'u_lead',
        'tripStatus': 'STARTED',
        'riders': {
          'u_me': {'userId': 'u_me', 'name': 'Me', 'lat': 17.40, 'lng': 78.0, 'lastSeenEpochMs': 1},
        },
      });
  @override
  String? get myUserId => 'u_me';
  @override
  bool get isOnline => true;
  @override
  bool supports(String feature) => true;
  @override
  List<AssistRequest> get assistRequests => requests;
  @override
  AssistRequest? get activeAssist => accepted;
  @override
  List<AssistNotice> get assistNotices => notices;
  @override
  List<OutboxItem> get outbox => const [];
  @override
  bool answerAssist(String incidentId, AssistAnswer answer) {
    answers.add((incidentId, answer));
    return true;
  }

  @override
  bool reportFalseAlert(String incidentId) {
    falseReports.add(incidentId);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    navigateLauncherOverride = (_) async => true;
  });
  tearDown(() {
    AppTheme.use(AppPalette.dark);
    navigateLauncherOverride = null;
  });

  const now = 1800000000000;
  const id = 'NET-0123456789AB';

  AssistRequest request({String? myStatus, bool arrivalCheck = false, bool withSubject = false}) => AssistRequest.fromJson({
        'incidentId': id,
        'lat': 17.4144,
        'lng': 78.0,
        'distanceM': 1600,
        'aheadOnRoute': true,
        'routeDistanceM': 1600,
        'etaS': 180,
        'fasterThanGroup': true,
        'severity': 'HIGH',
        'kind': 'ACCIDENT',
        'reportedAt': now - 30000,
        'lastUpdateAt': now - 8000,
        'myStatus': ?myStatus,
        if (arrivalCheck) 'arrivalCheck': true,
        if (withSubject) 'subject': {'firstName': 'Rahul', 'vehicleType': 'Motorcycle', 'vehicleColor': 'Black'},
        if (withSubject) 'medical': {'bloodGroup': 'B+', 'allergies': 'none'},
      }, receivedAt: now)!;

  Future<_Convoys> render(
    WidgetTester tester,
    Widget child, {
    required _Convoys convoys,
    Size size = const Size(320, 568),
    double scale = 1.3,
    AppPalette palette = AppPalette.dark,
  }) async {
    AppTheme.use(palette);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<ConvoyService>.value(
      value: convoys,
      child: MaterialApp(
        theme: AppTheme.themeFor(palette),
        builder: (context, w) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: w ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(12), child: child)),
      ),
    ));
    await tester.pump();
    return convoys;
  }

  _Convoys fake() => _Convoys(ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage()));

  for (final palette in [AppPalette.light, AppPalette.dark]) {
    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      final where = '${palette.isLight ? 'light' : 'dark'} ${size.width.round()}x${size.height.round()}';
      testWidgets('request banner at x1.3 ($where): minimum info, three big buttons, answers', (tester) async {
        final c = fake();
        final a = request(withSubject: true); // even if the server sent more, no names before I accept
        c.requests = [a];
        await render(tester, AssistBanner(request: a, nowMs: now), convoys: c, size: size, palette: palette);
        expect(tester.takeException(), isNull);
        expect(find.text(AssistTexts.requestTitle), findsOneWidget);
        expect(find.text('A rider from another group may have met with an accident.'), findsOneWidget);
        expect(find.textContaining('Rahul'), findsNothing);
        expect(find.textContaining('Black'), findsNothing);
        expect(find.textContaining('B+'), findsNothing);
        for (final label in ['I Can Help', 'Navigate', "Can't Assist"]) {
          final f = find.text(label);
          expect(f, findsOneWidget);
          final box = find.ancestor(of: f, matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first;
          expect(tester.getSize(box).height, greaterThanOrEqualTo(48));
        }
        await tester.ensureVisible(find.text("Can't Assist"));
        await tester.tap(find.text("Can't Assist"));
        await tester.pump();
        expect(c.answers.last, (id, AssistAnswer.decline));
        await tester.ensureVisible(find.text('I Can Help'));
        await tester.tap(find.text('I Can Help'));
        await tester.pump();
        expect(c.answers.last, (id, AssistAnswer.accept));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('accepted: "You are responding", ETA, Navigate / Unable to Assist / Arrived', (tester) async {
    final c = fake();
    final a = request(myStatus: 'ACCEPTED');
    c.accepted = a;
    await render(tester, AssistBanner(request: a, nowMs: now), convoys: c);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('RIDER EMERGENCY'), findsOneWidget);
    expect(find.text(AssistTexts.responding), findsOneWidget);
    expect(find.text('ETA 3 min'), findsOneWidget);
    expect(find.text('Navigate'), findsOneWidget);
    await tester.ensureVisible(find.text('Unable to Assist'));
    await tester.tap(find.text('Unable to Assist'));
    await tester.pump();
    expect(c.answers.last, (id, AssistAnswer.unable));
    await tester.ensureVisible(find.text('Arrived'));
    await tester.tap(find.text('Arrived'));
    await tester.pump();
    expect(c.answers.last, (id, AssistAnswer.arrived));
  });

  testWidgets('arrival check: "Have you reached the rider?" Yes, I Found Them / Unable to Locate', (tester) async {
    final c = fake();
    final a = request(myStatus: 'EN_ROUTE', arrivalCheck: true);
    c.accepted = a;
    await render(tester, AssistBanner(request: a, nowMs: now), convoys: c);
    expect(find.text(AssistTexts.arrivalQuestion), findsOneWidget);
    await tester.ensureVisible(find.text('Yes, I Found Them'));
    await tester.tap(find.text('Yes, I Found Them'));
    await tester.pump();
    expect(c.answers.last, (id, AssistAnswer.arrived));
    await tester.ensureVisible(find.text('Unable to Locate'));
    await tester.tap(find.text('Unable to Locate'));
    await tester.pump();
    expect(c.answers.last, (id, AssistAnswer.notFound));
  });

  test('stage from my status; the phone also asks within 100 m', () {
    expect(assistStageOf(request()), AssistStage.request);
    expect(assistStageOf(request(myStatus: 'DECLINED')), AssistStage.request);
    expect(assistStageOf(request(myStatus: 'ACCEPTED')), AssistStage.responding);
    expect(assistStageOf(request(myStatus: 'ARRIVING'), near: true), AssistStage.arrivalCheck);
    expect(assistStageOf(request(myStatus: 'ARRIVED')), AssistStage.onScene);
    expect(assistStageOf(request(myStatus: 'UNABLE_TO_REACH')), AssistStage.closed);
  });

  testWidgets('sheet after accepting: first name, vehicle, medical (shared), 112; report false alert asks first', (tester) async {
    final c = fake();
    final a = request(myStatus: 'ACCEPTED', withSubject: true);
    c.accepted = a;
    await render(tester, const AssistSheetBody(incidentId: id, nowMs: now), convoys: c, size: const Size(360, 1600), scale: 1.0);
    expect(tester.takeException(), isNull);
    expect(find.text('Rider: Rahul'), findsOneWidget);
    expect(find.text('Vehicle: Black Motorcycle'), findsOneWidget);
    expect(find.text('Blood group B+'), findsOneWidget);
    expect(find.text('Call emergency services 112'), findsOneWidget);
    expect(find.textContaining('Hill run'), findsNothing, reason: 'never a group name');

    await tester.tap(find.text('Report false alert'));
    await tester.pumpAndSettle();
    expect(find.text('Report a false alert?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.falseReports, isEmpty);
    await tester.tap(find.text('Report false alert'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    expect(c.falseReports, [id]);
  });

  testWidgets('sheet before accepting shows no name; closed request says another rider is responding', (tester) async {
    final c = fake();
    c.requests = [request(withSubject: true)];
    await render(tester, const AssistSheetBody(incidentId: id, nowMs: now), convoys: c, size: const Size(360, 1600), scale: 1.0);
    expect(find.textContaining('Rahul'), findsNothing);
    expect(find.text(AssistTexts.faster), findsOneWidget);

    final c2 = fake();
    c2.notices = [AssistNotice(incidentId: id, reason: AssistClosedReason.taken, at: now)];
    await render(tester, const AssistSheetBody(incidentId: id, nowMs: now), convoys: c2, size: const Size(360, 1600), scale: 1.0);
    expect(find.text(AssistTexts.takenTitle), findsOneWidget);
    expect(find.text(AssistTexts.takenBody), findsOneWidget);
  });

  testWidgets('screen reader hears the request without any name', (tester) async {
    final handle = tester.ensureSemantics();
    final c = fake();
    final a = request(withSubject: true);
    c.requests = [a];
    await render(tester, AssistBanner(request: a, nowMs: now), convoys: c, size: const Size(360, 740), scale: 1.0);
    expect(find.bySemanticsLabel(RegExp('RIDER EMERGENCY NEARBY')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Rahul')), findsNothing);
    handle.dispose();
  });

  testWidgets('hazard banner is amber with CAUTION and the distance, no identity', (tester) async {
    final c = fake();
    final h = HazardWarning.fromJson({
      'hazardId': 'HZ1',
      'lat': 17.42,
      'lng': 78.0,
      'level': 'RESPONDER_ARRIVING',
      'aheadM': 2000,
      'onRoute': true,
      'reportedAt': now,
    }, receivedAt: now)!;
    await render(tester, HazardBanner(hazard: h), convoys: c);
    expect(tester.takeException(), isNull);
    expect(find.text('CAUTION'), findsOneWidget);
    expect(find.text('Rider accident reported 2 km ahead on your route. Reduce speed and stay alert.'), findsOneWidget);
    expect(find.text('Responder arriving'), findsOneWidget);
  });
}
