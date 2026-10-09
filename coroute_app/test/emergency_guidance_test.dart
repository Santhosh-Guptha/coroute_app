import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/emergency_nav_constants.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/route/threshold_announcer.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/ride/emergency_guidance.dart';

/// ConvoyService with a fixed convoy, network lists and a fix stream (no socket).
class _Convoys extends ConvoyService {
  _Convoys(ApiClient api) : super(api, RealtimeService(), TripStorageService(api));

  ConvoyModel? convoy;
  List<AssistRequest> requests = [];
  List<HazardWarning> hazardList = [];
  final StreamController<TrackPoint> fixes = StreamController<TrackPoint>.broadcast();

  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  Map<String, ConvoyModel> get allConvoys {
    final c = convoy;
    return c == null ? <String, ConvoyModel>{} : {c.groupId: c};
  }
  @override
  String? get activeGroupId => convoy?.groupId;
  @override
  String? get myUserId => 'u_me';
  @override
  bool get isOnline => true;
  @override
  Stream<TrackPoint> get myFixes => fixes.stream;
  @override
  List<AssistRequest> get assistRequests => requests;
  @override
  AssistRequest? get activeAssist => null;
  @override
  List<HazardWarning> get hazards => hazardList;

  void changed() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('ThresholdAnnouncer', () {
    test('first sample arms silently, each threshold once, nearest one on a jump', () {
      final a = ThresholdAnnouncer(const [5000, 2000, 1000, 500, 100]);
      expect(a.onDistance(7800), isNull, reason: 'first sample is silent');
      expect(a.onDistance(6000), isNull);
      expect(a.onDistance(4990), 5000);
      expect(a.onDistance(4000), isNull);
      // GPS jitter around 2 km says it once.
      expect(a.onDistance(1990), 2000);
      expect(a.onDistance(2030), isNull);
      expect(a.onDistance(1980), isNull);
      // A jump over 1 km and 500 m says only the nearest.
      expect(a.onDistance(420), 500);
      expect(a.onDistance(1200), isNull, reason: 'never again after it fired');
      expect(a.onDistance(900), isNull, reason: '1 km was skipped by the jump');
      expect(a.onDistance(90), 100);
      expect(a.finished, isTrue);
    });

    test('thresholds already passed (or within the hysteresis) at the start are never said', () {
      final a = ThresholdAnnouncer(const [5000, 2000, 1000, 500], hysteresisM: 50);
      expect(a.onDistance(1030), isNull);
      expect(a.onDistance(990), isNull, reason: '1 km was within 50 m of the start');
      expect(a.onDistance(499), 500);
      a.reset();
      expect(a.onDistance(400), isNull);
      expect(a.onDistance(100), isNull);
      expect(a.finished, isTrue);
    });

    test('non-finite distances are ignored', () {
      final a = ThresholdAnnouncer(const [1000]);
      expect(a.onDistance(double.nan), isNull);
      expect(a.onDistance(2000), isNull);
      expect(a.onDistance(double.infinity), isNull);
      expect(a.onDistance(800), 1000);
    });
  });

  group('spoken words', () {
    test('navigation and hazard texts', () {
      expect(EmergencyGuidance.navSpeech(5000), 'Emergency location 5 kilometers away.');
      expect(EmergencyGuidance.navSpeech(2000), 'Emergency location 2 kilometers away.');
      expect(EmergencyGuidance.navSpeech(1000), 'Emergency location 1 kilometer away.');
      expect(EmergencyGuidance.navSpeech(500), 'Emergency location 500 meters away.');
      expect(EmergencyGuidance.navSpeech(100), 'You are approaching the emergency location.');
      expect(EmergencyGuidance.hazardSpeech(2000), 'Caution. Rider accident reported 2 kilometers ahead.');
      expect(EmergencyGuidance.hazardSpeech(500), 'Caution. Rider accident 500 meters ahead. Slow down.');
      // 3.16: the same lines in the voice engine's language; digits and units stay.
      expect(EmergencyGuidance.navSpeech(2000, lang: 'hi'), L10n.t('speech.nav.away', {'dist': '2 kilometers'}, 'hi'));
      expect(EmergencyGuidance.navSpeech(100, lang: 'te'), L10n.t('speech.nav.near', const {}, 'te'));
      expect(EmergencyGuidance.hazardSpeech(500, lang: 'te'), contains('500 meters'));
      expect(EmergencyGuidance.hazardSpeech(500, lang: 'te'), isNot(contains('Caution')));
      expect(EmergencyGuidance.navSpeech(500, lang: 'xx'), 'Emergency location 500 meters away.', reason: 'unknown language falls back to English');
      for (final m in [...EmergencyNavConstants.navThresholdsM, ...EmergencyNavConstants.hazardThresholdsM]) {
        for (final t in [EmergencyGuidance.navSpeech(m), EmergencyGuidance.hazardSpeech(m)]) {
          expect(t.contains('\u2014') || t.contains('\u2013'), isFalse);
        }
      }
    });
  });

  // A highway along lng 78.0, lat 17.40 to 17.70 (northbound).
  const lng = 78.0;
  List<(double, double)> line(double from, double to) => [for (var la = from; la <= to + 1e-9; la += 0.005) (la, lng)];

  ConvoyModel convoyAt(double myLat, {bool withRoute = false, List<Map<String, dynamic>> alerts = const []}) {
    final pts = line(17.40, 17.70);
    return ConvoyModel.fromJson({
      'groupId': 'G1',
      'name': 'Hill run',
      'joinCode': '123456',
      'createdByUserId': 'u_lead',
      'tripStatus': 'STARTED',
      'riders': {
        'u_me': {'userId': 'u_me', 'name': 'Me', 'lat': myLat, 'lng': lng, 'lastSeenEpochMs': 1},
        'u_k': {'userId': 'u_k', 'name': 'Kiran', 'lat': 17.47, 'lng': lng, 'lastSeenEpochMs': 1},
      },
      'activeAlerts': alerts,
      if (withRoute)
        'route': {'distanceM': 33000, 'durationS': 2400, 'polyline': GeoMath.encodePolyline(pts), 'approximate': false},
    });
  }

  AssistRequest request({String id = 'NET-AAAAAAAAAAAA', double lat = 17.47}) => AssistRequest.fromJson({
        'incidentId': id,
        'lat': lat,
        'lng': lng,
        'distanceM': 7800,
        'aheadOnRoute': true,
        'routeDistanceM': 7800,
        'etaS': 600,
        'fasterThanGroup': true,
        'severity': 'HIGH',
        'kind': 'ACCIDENT',
        'reportedAt': 1,
        'lastUpdateAt': 1,
      }, receivedAt: 1)!;

  HazardWarning hazard({String id = 'HZ1', double lat = 17.50, double lngH = lng, bool onRoute = true}) => HazardWarning.fromJson({
        'hazardId': id,
        'lat': lat,
        'lng': lngH,
        'level': 'ACTIVE',
        'aheadM': 10000,
        'onRoute': onRoute,
        'reportedAt': 1,
      }, receivedAt: 1)!;

  ApiClient api() => ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  Future<void> fix(_Convoys c, double lat, {int ts = 0, double lngF = lng}) async {
    c.fixes.add(TrackPoint(ts: ts, lat: lat, lng: lngF, speedKmh: 60, accuracyM: 8));
    await flush();
  }

  test('navigation: route to the point, each distance spoken once, approaching at 100 m', () async {
    final c = _Convoys(api())..convoy = convoyAt(17.40);
    c.requests = [request()];
    final spoken = <(String, String)>[];
    final fetched = <List<(double, double)>>[];
    final g = EmergencyGuidance(
      c,
      null,
      null,
      fetchRoute: (wp) async {
        fetched.add(wp);
        return RouteModel(distanceM: 7800, durationS: 600, polyline: GeoMath.encodePolyline(line(17.40, 17.47)));
      },
      speak: (t, k) => spoken.add((t, k)),
    );
    expect(g.listening, isFalse, reason: 'nothing to follow yet');
    final ok = await g.start(const NavTarget(kind: NavTargetKind.assist, ref: 'NET-AAAAAAAAAAAA'));
    expect(ok, isTrue);
    expect(g.listening, isTrue);
    expect(fetched, hasLength(1));
    expect(fetched.single.first, (17.40, lng));
    expect(fetched.single.last, (17.47, lng));
    expect(g.route, isNotNull);
    expect(spoken, isEmpty, reason: 'the first distance arms silently');

    for (final la in [17.400, 17.430, 17.4295, 17.4305, 17.455, 17.462, 17.4665, 17.4695]) {
      await fix(c, la);
    }
    expect(spoken.map((s) => s.$1).toList(), [
      EmergencyGuidance.navSpeech(5000),
      EmergencyGuidance.navSpeech(2000),
      EmergencyGuidance.navSpeech(1000),
      EmergencyGuidance.navSpeech(500),
      EmergencyGuidance.navSpeech(100),
    ]);
    expect(spoken.first.$2, 'NAV:NET-AAAAAAAAAAAA:5000');
    expect(g.remainingM, lessThan(100));
    expect(g.statusLine, startsWith('Emergency'));

    // GPS jitter near the point says nothing more.
    await fix(c, 17.4685);
    await fix(c, 17.4697);
    expect(spoken, hasLength(5));
    g.dispose();
  });

  test('no route: straight distance and direction; the target closing stops the guidance', () async {
    final c = _Convoys(api())..convoy = convoyAt(17.40);
    c.requests = [request()];
    final g = EmergencyGuidance(c, null, null, fetchRoute: (_) async => null, speak: (_, _) {});
    await g.start(const NavTarget(kind: NavTargetKind.assist, ref: 'NET-AAAAAAAAAAAA'));
    await fix(c, 17.41);
    expect(g.route, isNull);
    expect(g.statusLine, 'Emergency 6.7 km north');
    expect(g.eta, isNotNull);

    c.requests = [];
    c.changed();
    expect(g.target, isNull, reason: 'the request closed');
    expect(g.statusLine, isNull);
    expect(g.listening, isFalse, reason: 'no target and no hazard: no fixes are followed');
    expect(c.fixes.hasListener, isFalse);
    g.dispose();
  });

  test('group emergency target: the alert position; resolved alert stops; unknown target is refused', () async {
    final alert = {
      'alertId': 'A1',
      'userId': 'u_k',
      'userName': 'Kiran',
      'lat': 17.47,
      'lng': lng,
      'alertType': 'CRASH',
      'timestamp': 1000,
      'resolved': false,
    };
    final c = _Convoys(api())..convoy = convoyAt(17.40, alerts: [alert]);
    final g = EmergencyGuidance(c, null, null, fetchRoute: (_) async => null, speak: (_, _) {});
    expect(await g.start(const NavTarget(kind: NavTargetKind.groupEmergency, ref: 'NOPE')), isFalse);
    expect(await g.start(const NavTarget(kind: NavTargetKind.groupEmergency, ref: 'A1', label: 'Kiran')), isTrue);
    expect(g.targetPoint, (17.47, lng));
    expect(g.isTarget(NavTargetKind.groupEmergency, 'A1'), isTrue);
    c.convoy = convoyAt(17.40, alerts: [
      {...alert, 'resolved': true},
    ]);
    c.changed();
    expect(g.target, isNull);
    g.dispose();
  });

  test('hazard along the group route: 5 km, 2 km, 1 km, 500 m once each; passed is removed and silent', () async {
    final c = _Convoys(api())..convoy = convoyAt(17.40, withRoute: true);
    final spoken = <String>[];
    final g = EmergencyGuidance(c, null, null, fetchRoute: (_) async => null, speak: (t, _) => spoken.add(t));
    expect(g.listening, isFalse);
    c.hazardList = [hazard()];
    c.changed();
    expect(g.listening, isTrue, reason: 'a hazard makes it follow my fixes');
    for (final la in [17.400, 17.460, 17.485, 17.492, 17.4965]) {
      await fix(c, la);
    }
    expect(spoken, [
      EmergencyGuidance.hazardSpeech(5000),
      EmergencyGuidance.hazardSpeech(2000),
      EmergencyGuidance.hazardSpeech(1000),
      EmergencyGuidance.hazardSpeech(500),
    ]);
    final view = g.hazards.single;
    expect(view.alongRoute, isTrue);
    expect(view.distanceM, lessThan(500));
    expect(view.label, startsWith('Accident reported'));

    await fix(c, 17.503);
    expect(g.hazards, isEmpty, reason: 'passed');
    await fix(c, 17.40);
    expect(spoken, hasLength(4), reason: 'never again after passing');

    c.hazardList = [];
    c.changed();
    expect(g.listening, isFalse);
    g.dispose();
  });

  test('navigating to the same accident a hazard warns about: only the navigation lines are spoken', () async {
    final c = _Convoys(api())..convoy = convoyAt(17.40, withRoute: true);
    c.requests = [request(id: 'NET-AAAAAAAAAAAA', lat: 17.50)];
    c.hazardList = [hazard(id: 'NET-AAAAAAAAAAAA', lat: 17.50)];
    final spoken = <String>[];
    final g = EmergencyGuidance(c, null, null, fetchRoute: (_) async => null, speak: (t, _) => spoken.add(t));
    await g.start(const NavTarget(kind: NavTargetKind.assist, ref: 'NET-AAAAAAAAAAAA'));
    for (final la in [17.400, 17.460, 17.485, 17.492, 17.4965]) {
      await fix(c, la);
    }
    expect(spoken.where((t) => t.startsWith('Caution')), isEmpty);
    expect(spoken.where((t) => t.startsWith('Emergency location')), isNotEmpty);
    g.dispose();
  });

  test('hazard off the route: straight distance toward it; passed after the distance grows', () async {
    final c = _Convoys(api())..convoy = convoyAt(17.40);
    final spoken = <String>[];
    final g = EmergencyGuidance(c, null, null, fetchRoute: (_) async => null, speak: (t, _) => spoken.add(t));
    c.hazardList = [hazard(onRoute: false)];
    c.changed();
    await fix(c, 17.400);
    await fix(c, 17.4002);
    await fix(c, 17.460);
    expect(spoken, [EmergencyGuidance.hazardSpeech(5000)]);
    expect(g.hazards.single.alongRoute, isFalse);
    for (final la in [17.4995, 17.5010, 17.503, 17.505]) {
      await fix(c, la);
    }
    expect(g.hazards, isEmpty, reason: 'distance grew three fixes in a row after being close');
    final before = spoken.length;
    await fix(c, 17.50);
    expect(spoken.length, before);
    g.dispose();
  });
}
