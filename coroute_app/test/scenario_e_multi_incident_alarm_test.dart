import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/medical_info.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/notify/alert_priority.dart';
import 'package:coroute_app/presentation/ride/incident_banner.dart';
import 'package:coroute_app/presentation/ride/incident_view.dart';

class _MultiIncidentConvoyService extends ConvoyService {
  _MultiIncidentConvoyService(ApiClient api, this.convoy)
      : super(api, RealtimeService(), TripStorageService(api));

  ConvoyModel convoy;
  final String myId = 'u_me';
  final Map<String, SosResponseKind> myResponses = {};
  final List<String> resolvedAlertIds = [];

  @override
  Map<String, ConvoyModel> get allConvoys => {convoy.groupId: convoy};
  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get activeGroupId => convoy.groupId;
  @override
  String? get myUserId => myId;
  @override
  bool supports(String feature) => true;

  @override
  bool respondToSos(String alertId, SosResponseKind kind) {
    if (kind == SosResponseKind.cancel) {
      myResponses.remove(alertId);
    } else {
      myResponses[alertId] = kind;
    }
    // Update activeAlerts with responder
    final updatedAlerts = convoy.activeAlerts.map((a) {
      if (a.alertId != alertId) return a;
      final existing = a.responders.where((r) => r.userId != myId).toList();
      if (kind != SosResponseKind.cancel) {
        existing.add(SosResponder(userId: myId, name: 'Me', kind: kind, at: DateTime.now().millisecondsSinceEpoch));
      }
      return a.copyWith(responders: existing);
    }).toList();
    convoy = convoy.copyWith(activeAlerts: updatedAlerts);
    notifyListeners();
    return true;
  }

  @override
  SosResponseKind? myResponseTo(String alertId) => myResponses[alertId];

  @override
  void resolveSosAlert(String alertId, {ResolveReason reason = ResolveReason.resolved}) {
    resolvedAlertIds.add(alertId);
    final remaining = convoy.activeAlerts.where((a) => a.alertId != alertId).toList();
    convoy = convoy.copyWith(activeAlerts: remaining);
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    AppTheme.use(AppPalette.dark);
  });

  group('Scenario E: Concurrent Multi-Incident Alarm', () {
    const t0 = 1700000000000;

    final riderMe = RiderModel(userId: 'u_me', name: 'Me (Responder)', lat: 12.960, lng: 77.560, lastSeenEpochMs: t0);
    final riderArjun = RiderModel(userId: 'u_arjun', name: 'Arjun', lat: 12.950, lng: 77.550, lastSeenEpochMs: t0);
    final riderBala = RiderModel(userId: 'u_bala', name: 'Bala', lat: 12.980, lng: 77.580, lastSeenEpochMs: t0);
    final riderKiran = RiderModel(userId: 'u_kiran', name: 'Kiran', lat: 12.965, lng: 77.565, lastSeenEpochMs: t0);

    // Alert A: Arjun manual SOS
    final alertArjun = SosAlertModel(
      alertId: 'ALERT_ARJUN_SOS',
      userId: 'u_arjun',
      userName: 'Arjun',
      lat: 12.950,
      lng: 77.550,
      alertType: 'EMERGENCY',
      timestamp: t0,
      occurredAt: t0,
      auto: false,
      resolved: false,
      medical: const MedicalInfo(bloodGroup: 'B+', allergies: 'Pollen'),
    );

    // Alert B: Bala automatic crash alarm (6.8 g spike at 65 km/h)
    final alertBalaCrash = SosAlertModel(
      alertId: 'ALERT_BALA_CRASH',
      userId: 'u_bala',
      userName: 'Bala',
      lat: 12.980,
      lng: 77.580,
      alertType: 'CRASH',
      timestamp: t0 + 2000,
      occurredAt: t0 + 2000,
      auto: true,
      speedBeforeKmh: 65.0,
      impactG: 6.8,
      resolved: false,
      medical: const MedicalInfo(bloodGroup: 'O+', allergies: 'Penicillin'),
    );

    ConvoyModel makeConvoy({List<SosAlertModel>? alerts}) => ConvoyModel(
          groupId: 'GRP-MULTI-SOS',
          name: 'Weekend Ride',
          joinCode: '334455',
          createdByUserId: 'u_me',
          createdByUserName: 'Me',
          createdAtEpochMs: t0 - 3600000,
          riders: {
            'u_me': riderMe,
            'u_arjun': riderArjun,
            'u_bala': riderBala,
            'u_kiran': riderKiran,
          },
          activeAlerts: alerts ?? [alertArjun, alertBalaCrash],
        );

    test('Incident ranking and notification priority: Crash alarm prioritized over manual SOS', () {
      final convoy = makeConvoy();

      // Convert active alerts to IncidentView list
      final incidentList = incidentsFromEvents(convoy, const [], 'u_me', t0 + 5000);
      expect(incidentList, hasLength(2));

      // 1. Ranking check:
      // Bala's Crash (kind: crash, rank 0) MUST appear first before Arjun's SOS (kind: sos, rank 1),
      // even though Arjun triggered his alert first in time!
      expect(incidentList[0].kind, IncidentKind.crash);
      expect(incidentList[0].subjectUserId, 'u_bala');
      expect(incidentList[0].alertId, 'ALERT_BALA_CRASH');
      expect(incidentList[0].auto, isTrue);
      expect(incidentList[0].fromKmh, 65.0);
      expect(incidentList[0].title, 'Crash detected: Bala');

      expect(incidentList[1].kind, IncidentKind.sos);
      expect(incidentList[1].subjectUserId, 'u_arjun');
      expect(incidentList[1].alertId, 'ALERT_ARJUN_SOS');
      expect(incidentList[1].auto, isFalse);

      // 2. AlertArbiter priority: Both emergency alerts block social discovery
      expect(AlertArbiter.socialAllowed(anyEmergency: true, anyAssist: false, anyHazard: false), isFalse);

      // Crash alert key prioritized over generic safety warnings
      final keys = ['STALE:u_kiran', 'SOS:ALERT_ARJUN_SOS', 'SOS:ALERT_BALA_CRASH'];
      final sorted = AlertArbiter.arrange(keys, (k) => priorityForKey(k));
      expect(sorted.first, startsWith('SOS:'));
    });

    test('Independent responder tracking: responses to Alert B do not collide with Alert A', () {
      final api = ApiClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        storage: const FlutterSecureStorage(),
      );
      final service = _MultiIncidentConvoyService(api, makeConvoy());

      // 1. Initial state: neither alert has responders
      expect(service.myResponseTo('ALERT_BALA_CRASH'), isNull);
      expect(service.myResponseTo('ALERT_ARJUN_SOS'), isNull);

      // 2. Me responds to Bala's crash: "I'm going"
      service.respondToSos('ALERT_BALA_CRASH', SosResponseKind.going);
      expect(service.myResponseTo('ALERT_BALA_CRASH'), SosResponseKind.going);
      expect(service.myResponseTo('ALERT_ARJUN_SOS'), isNull, reason: 'No response recorded for Arjun');

      final balaAlert = service.activeConvoy!.activeAlerts.firstWhere((a) => a.alertId == 'ALERT_BALA_CRASH');
      expect(balaAlert.responders, hasLength(1));
      expect(balaAlert.responders.first.userId, 'u_me');
      expect(balaAlert.responders.first.kind, SosResponseKind.going);

      final arjunAlert = service.activeConvoy!.activeAlerts.firstWhere((a) => a.alertId == 'ALERT_ARJUN_SOS');
      expect(arjunAlert.responders, isEmpty, reason: 'Arjun alert responder list remains isolated');

      // 3. Another rider (Kiran) responds to Arjun's manual SOS: "With them"
      final updatedArjun = arjunAlert.copyWith(
        responders: [
          const SosResponder(userId: 'u_kiran', name: 'Kiran', kind: SosResponseKind.withThem, at: t0 + 4000),
        ],
      );
      service.convoy = service.convoy.copyWith(
        activeAlerts: [balaAlert, updatedArjun],
      );

      expect(service.activeConvoy!.activeAlerts.firstWhere((a) => a.alertId == 'ALERT_ARJUN_SOS').responders, hasLength(1));
      expect(service.activeConvoy!.activeAlerts.firstWhere((a) => a.alertId == 'ALERT_BALA_CRASH').responders, hasLength(1));
    });

    test('Independent resolution: resolving Alert A keeps Alert B active and preserved', () {
      final api = ApiClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        storage: const FlutterSecureStorage(),
      );
      final service = _MultiIncidentConvoyService(api, makeConvoy());
      service.respondToSos('ALERT_BALA_CRASH', SosResponseKind.going);

      expect(service.activeConvoy!.activeAlerts, hasLength(2));

      // 1. Arjun's situation is resolved first (e.g. false alarm or assistance arrived)
      service.resolveSosAlert('ALERT_ARJUN_SOS', reason: ResolveReason.resolved);
      expect(service.resolvedAlertIds, contains('ALERT_ARJUN_SOS'));

      // 2. Bala's crash alert MUST remain fully active
      expect(service.activeConvoy!.activeAlerts, hasLength(1));
      final remainingAlert = service.activeConvoy!.activeAlerts.single;
      expect(remainingAlert.alertId, 'ALERT_BALA_CRASH');
      expect(remainingAlert.isCrash, isTrue);
      expect(remainingAlert.medical?.bloodGroup, 'O+');
      expect(service.myResponseTo('ALERT_BALA_CRASH'), SosResponseKind.going, reason: 'My responder state is preserved');

      // 3. Finally Bala's crash is also resolved
      service.resolveSosAlert('ALERT_BALA_CRASH', reason: ResolveReason.resolved);
      expect(service.activeConvoy!.activeAlerts, isEmpty);
    });

    testWidgets('IncidentBanner widget prioritizes crash alarm over concurrent manual SOS', (tester) async {
      final convoy = makeConvoy();
      final incidents = incidentsFromEvents(convoy, const [], 'u_me', t0 + 5000);

      // Verify incident list ordering
      expect(incidents.first.alertId, 'ALERT_BALA_CRASH');

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: IncidentBanner(
              incident: incidents.first,
              onOpen: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // Incident banner renders highest priority crash alert for Bala:
      expect(find.text('EMERGENCY'), findsOneWidget);
      expect(find.text('Bala may have met with an accident'), findsOneWidget);
      expect(find.textContaining('Bala'), findsWidgets);
      // Arjun's lower-priority manual SOS is not shown on the primary crash banner
      expect(find.textContaining('Arjun'), findsNothing);
    });
  });
}
